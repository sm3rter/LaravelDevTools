function Get-SafeSlug([string]$s) {
    $t = ($s.Trim().ToLower() -replace '[^a-z0-9._-]+', '-').Trim('-')
    return $t
}

function Get-LocalBranchList($p) {
    $r = Invoke-Git $p @('for-each-ref', 'refs/heads', '--sort=-committerdate', '--format=%(refname:short)|%(objectname:short)|%(committerdate:relative)|%(upstream:short)|%(subject)')
    $list = @()
    foreach ($l in $r.Out) {
        $f = $l.Split('|')
        if ($f.Count -lt 5) { continue }
        $subj = ($f[4..($f.Count - 1)] -join '|')
        $list += [pscustomobject]@{ Name = $f[0]; Hash = $f[1]; When = $f[2]; Upstream = $f[3]; Subject = $subj }
    }
    return , @($list)
}

function Get-CurrentBranchName($p) {
    $r = Invoke-Git $p @('symbolic-ref', '--short', '-q', 'HEAD')
    if ($r.Ok -and $r.Out.Count -gt 0) { return [string]$r.Out[0] }
    return ''
}

function Get-DevBase($p, [string]$Branch) {
    $r = Invoke-Git $p @('config', '--get', "branch.$Branch.devbase")
    if ($r.Ok -and $r.Out.Count -gt 0) { return [string]$r.Out[0] }
    return ''
}

function Test-TreeDirty($p) {
    $r = Invoke-Git $p @('status', '--porcelain')
    return (@($r.Out | Where-Object { $_.Trim() }).Count -gt 0)
}

function Get-AheadCount($p, [string]$Base, [string]$Branch) {
    $r = Invoke-Git $p @('rev-list', '--count', "$Base..$Branch")
    if ($r.Ok -and $r.Out.Count -gt 0) { return [int]$r.Out[0] }
    return 0
}

function Start-GitExperiment($p) {
    $cur = Get-CurrentBranchName $p
    if (-not $cur) { return '! you are not on a branch (detached HEAD) - switch to a branch first' }
    $name = Read-Input 'New experiment' 'name' @('A restore point to try something on.', "You can merge it into '$cur' later, or throw it away.") ''
    if ($null -eq $name) { return '' }
    $slug = Get-SafeSlug $name
    if (-not $slug) { return '! empty name' }
    $br = "try/$slug"
    if (-not (Test-GitRefName $p $br)) { return "! '$br' is not a valid branch name" }
    if ((Invoke-Git $p @('show-ref', '--verify', '--quiet', "refs/heads/$br")).Ok) { return "! experiment '$slug' already exists" }

    $note = ''
    if (Test-TreeDirty $p) {
        $items = @(
            @{ label = 'Carry my uncommitted changes into the experiment'; color = 'Cyan'; note = "'$cur' stays as it was at the last commit" },
            @{ label = "Save them on '$cur' first (WIP commit)"; color = 'DarkGray'; note = 'the experiment starts from a clean state' })
        $ix = Show-Choice -Title 'You have uncommitted changes' -Subtitle $br -Items $items
        if ($null -eq $ix) { return '' }
        if ($ix -eq 1) {
            [void](Invoke-Git $p @('add', '-A'))
            $c = Invoke-Git $p @('commit', '-m', "WIP before experiment $slug")
            if (-not $c.Ok) { return (Complete-Git $c '') }
            $note = " (WIP commit made on $cur)"
        }
    }
    $r = Invoke-Git $p @('checkout', '-b', $br)
    if (-not $r.Ok) { return (Complete-Git $r '') }
    [void](Invoke-Git $p @('config', "branch.$br.devbase", $cur))
    return "experiment '$slug' started from $cur$note - work as usual, commit when you like"
}

function Get-ExperimentList($p) {
    $res = @()
    foreach ($b in (Get-LocalBranchList $p)) {
        if (-not $b.Name.StartsWith('try/')) { continue }
        $base = Get-DevBase $p $b.Name
        if (-not $base) { $base = 'main' }
        $res += [pscustomobject]@{ Name = $b.Name; Slug = $b.Name.Substring(4); Base = $base; When = $b.When; Subject = $b.Subject }
    }
    return , @($res)
}

function Remove-ExperimentBranch($p, $e, [bool]$Force) {
    $flag = '-d'; if ($Force) { $flag = '-D' }
    $r = Invoke-Git $p @('branch', $flag, $e.Name)
    if ($r.Ok) { [void](Invoke-Git $p @('config', '--unset', "branch.$($e.Name).devbase")) }
    return $r
}

function Invoke-ExperimentMerge($p, $e) {
    $items = @(
        @{ label = 'Merge, keep every commit'; color = 'Green'; note = "into $($e.Base)" },
        @{ label = 'Merge as ONE commit (squash)'; color = 'Cyan'; note = 'a single tidy commit on ' + $e.Base })
    $ix = Show-Choice -Title "Merge '$($e.Slug)' into $($e.Base)" -Items $items
    if ($null -eq $ix) { return '' }
    $s = Switch-GitBranch $p $e.Base $false
    if ($s.StartsWith('!')) { return $s }
    if ($ix -eq 0) { $r = Invoke-Git $p @('merge', '--no-ff', '--no-edit', $e.Name) }
    else {
        $r = Invoke-Git $p @('merge', '--squash', $e.Name)
        if ($r.Ok) {
            $r = Invoke-Git $p @('commit', '-m', "Experiment: $($e.Slug)")
            if ((-not $r.Ok) -and ($r.Text -match 'nothing to commit')) { $r = [pscustomobject]@{ Ok = $true; Out = @(); Text = ''; Cmd = 'git commit'; Code = 0 } }
        }
    }
    if (-not $r.Ok) { return ((Complete-Git $r '') + '  (fix conflicts in Resolve conflicts, the experiment is kept)') }
    $d = Remove-ExperimentBranch $p $e $true
    if ($d.Ok) { return "experiment '$($e.Slug)' merged into $($e.Base) and removed" }
    return "merged into $($e.Base) (could not remove the experiment branch)"
}

function Show-ExperimentActions($p, $e) {
    $cur = Get-CurrentBranchName $p
    $ahead = Get-AheadCount $p $e.Base $e.Name
    $items = @(
        @{ label = 'Continue working on it'; color = 'Green'; note = 'switch to this experiment' },
        @{ label = "Merge into $($e.Base)"; color = 'Cyan'; note = "$ahead commit(s) - then the experiment disappears" },
        @{ label = 'Discard it'; color = 'Red'; note = "delete the experiment, $($e.Base) is untouched"; danger = $true },
        @{ label = 'Go back to its start'; color = 'DarkGray'; note = 'undo everything done in it, keep the experiment' },
        @{ label = 'What changed'; color = 'DarkGray'; note = "files changed vs $($e.Base)" },
        @{ label = 'Show it in the tree'; color = 'DarkGray'; note = 'graph' })
    $ix = Show-Choice -Title "Experiment: $($e.Slug)" -Subtitle "from $($e.Base) - $ahead commit(s) - $($e.When)" -Items $items
    if ($null -eq $ix) { return '' }
    switch ($ix) {
        0 { return (Switch-GitBranch $p $e.Name $false) }
        1 { return (Invoke-ExperimentMerge $p $e) }
        2 {
            if (-not (Read-Confirm "Throw away experiment '$($e.Slug)' and its $ahead commit(s)? This cannot be undone easily.")) { return '' }
            if ($cur -eq $e.Name) { $s = Switch-GitBranch $p $e.Base $false; if ($s.StartsWith('!')) { return $s } }
            $d = Remove-ExperimentBranch $p $e $true
            if ($d.Ok) { return "experiment '$($e.Slug)' discarded" }
            return (Complete-Git $d '')
        }
        3 {
            if ($cur -ne $e.Name) { return '! switch to the experiment first (Continue working on it)' }
            $mb = Invoke-Git $p @('merge-base', $e.Base, $e.Name)
            if (-not ($mb.Ok -and $mb.Out.Count -gt 0)) { return (Complete-Git $mb '') }
            if (-not (Read-Confirm 'Reset the experiment to where it started? Uncommitted work in it is lost.')) { return '' }
            return (Complete-Git (Invoke-Git $p @('reset', '--hard', [string]$mb.Out[0])) 'experiment is back at its start')
        }
        4 { $r = Invoke-Git $p @('diff', '--stat', "$($e.Base)...$($e.Name)"); Show-Pager "Changed in $($e.Slug) vs $($e.Base)" $r.Out; return '' }
        5 { Show-GitGraph $p $e.Name; return '' }
    }
    return ''
}

function Show-GitExperiments($p) {
    $flash = ''; $last = -1
    while ($true) {
        $cur = Get-CurrentBranchName $p
        $exps = @(Get-ExperimentList $p)
        $items = @(@{ label = '+ Start a new experiment'; color = 'Green'; note = "a restore point on '$cur' you can merge back or discard" })
        foreach ($e in $exps) {
            $mark = ''; if ($e.Name -eq $cur) { $mark = '  <- you are here' }
            $items += @{ label = $e.Slug + $mark; color = 'Yellow'; note = "from $($e.Base) - $(Get-AheadCount $p $e.Base $e.Name) commit(s) - $($e.When)" }
        }
        $fc = 'Green'; if ($flash.StartsWith('!')) { $fc = 'Red' }
        $ix = Show-Choice -Title "Experiments - $($p.Name)" -Subtitle "on branch: $cur   (works offline)" -Items $items -Flash $flash.TrimStart('!').Trim() -FlashColor $fc -InitialIndex $last
        if ($null -eq $ix) { return $flash }
        $last = $ix
        if ($ix -eq 0) { $flash = Start-GitExperiment $p }
        else { $flash = Show-ExperimentActions $p $exps[$ix - 1] }
    }
}

function Select-StartPoint($p) {
    $items = @(
        @{ label = 'Where I am now'; color = 'Green'; note = 'the current commit' },
        @{ label = 'Pick a commit from the history'; color = 'Cyan'; note = 'last 40 commits' },
        @{ label = 'A tag'; color = 'DarkGray'; note = 'for example a release' },
        @{ label = 'Another version (branch)'; color = 'DarkGray'; note = 'its latest commit' })
    $ix = Show-Choice -Title 'Start the new version from ...' -Items $items
    if ($null -eq $ix) { return $null }
    if ($ix -eq 0) { return 'HEAD' }
    if ($ix -eq 1) {
        $r = Invoke-Git $p @('log', '--all', '-n', '40', '--format=%h|%ar|%s')
        $its = @(); $hs = @()
        foreach ($l in $r.Out) { $f = $l.Split('|'); if ($f.Count -ge 3) { $its += @{ label = $f[0]; color = 'Yellow'; note = $f[1] + ' - ' + ($f[2..($f.Count - 1)] -join '|') }; $hs += $f[0] } }
        if ($its.Count -eq 0) { return $null }
        $k = Show-Choice -Title 'Pick the commit' -Items $its
        if ($null -eq $k) { return $null }
        return $hs[$k]
    }
    if ($ix -eq 2) {
        $r = Invoke-Git $p @('tag', '--sort=-creatordate')
        $tags = @($r.Out | Where-Object { $_.Trim() })
        if ($tags.Count -eq 0) { Clear-Host; Show-Fail 'No tags in this repository'; return $null }
        $its = @(); foreach ($t in $tags) { $its += @{ label = $t; color = 'DarkYellow' } }
        $k = Show-Choice -Title 'Pick the tag' -Items $its
        if ($null -eq $k) { return $null }
        return $tags[$k]
    }
    $bl = @(Get-LocalBranchList $p)
    $its = @(); foreach ($b in $bl) { $its += @{ label = $b.Name; color = 'Cyan'; note = $b.When + ' - ' + $b.Subject } }
    if ($its.Count -eq 0) { return $null }
    $k = Show-Choice -Title 'Pick the version' -Items $its
    if ($null -eq $k) { return $null }
    return $bl[$k].Name
}

function New-GitVersion($p) {
    $name = Read-Input 'New version' 'name' @('A full, independent line of work (a Git branch).', 'Example: v2, shop-module, redesign') ''
    if ($null -eq $name) { return '' }
    $slug = Get-SafeSlug $name
    if (-not $slug) { return '! empty name' }
    if (-not (Test-GitRefName $p $slug)) { return "! '$slug' is not a valid branch name" }
    if ((Invoke-Git $p @('show-ref', '--verify', '--quiet', "refs/heads/$slug")).Ok) { return "! version '$slug' already exists" }
    $start = Select-StartPoint $p
    if ($null -eq $start) { return '' }
    $r = Invoke-Git $p @('branch', $slug, $start)
    if (-not $r.Ok) { return (Complete-Git $r '') }
    $s = Switch-GitBranch $p $slug $false
    if ($s.StartsWith('!')) { return $s }
    return "new version '$slug' created from $start and you are on it - the old one is untouched"
}

function Open-VersionFolder($p, [string]$Branch) {
    $cur = Get-CurrentBranchName $p
    if ($cur -eq $Branch) { return '! that version is the one open in the project folder - switch the project to another version first' }
    $slug = Get-SafeSlug ($Branch -replace '/', '-')
    $dir = Join-Path (Split-Path -Parent $p.Path) ($p.Name + '-' + $slug)
    if (Test-Path -LiteralPath $dir) { return "! the folder already exists: $dir" }
    $r = Invoke-Git $p @('worktree', 'add', $dir, $Branch)
    if (-not $r.Ok) { return (Complete-Git $r '') }
    return "opened '$Branch' side by side in $dir  (copy .env, run composer install / npm install there; Laragon serves it as $($p.Name)-$slug$(Get-Cfg 'domainSuffix') after Reload)"
}

function Show-VersionActions($p, $b) {
    $cur = Get-CurrentBranchName $p
    $isCur = ($b.Name -eq $cur)
    $items = @(
        @{ label = 'Switch to it'; enabled = (-not $isCur); color = 'Green'; note = 'your files change to that version (unsaved work is stashed safely)' },
        @{ label = "Merge it into $cur"; enabled = (-not $isCur); color = 'Cyan'; note = 'bring its work into the version you are on' },
        @{ label = 'Open side by side (separate folder)'; enabled = (-not $isCur); color = 'DarkGray'; note = 'work on two versions at the same time' },
        @{ label = 'Show it in the tree'; enabled = $true; color = 'DarkGray'; note = 'graph' },
        @{ label = 'Delete it'; enabled = (-not $isCur); color = 'Red'; note = 'only if it is fully merged, otherwise it asks'; danger = $true })
    $ix = Show-Choice -Title "Version: $($b.Name)" -Subtitle "$($b.When) - $($b.Subject)" -Items $items
    if ($null -eq $ix) { return '' }
    switch ($ix) {
        0 { return (Switch-GitBranch $p $b.Name $false) }
        1 { return (Invoke-GitMerge $p $b.Name) }
        2 { return (Open-VersionFolder $p $b.Name) }
        3 { Show-GitGraph $p $b.Name; return '' }
        4 {
            $r = Invoke-Git $p @('branch', '-d', $b.Name)
            if ($r.Ok) { return "version '$($b.Name)' deleted" }
            if (Read-Confirm "'$($b.Name)' has work that is NOT merged anywhere. Delete it anyway?") { return (Complete-Git (Invoke-Git $p @('branch', '-D', $b.Name)) "version '$($b.Name)' deleted") }
            return ''
        }
    }
    return ''
}

function Show-GitVersions($p) {
    $flash = ''; $last = -1
    while ($true) {
        $cur = Get-CurrentBranchName $p
        $all = @(Get-LocalBranchList $p | Where-Object { -not $_.Name.StartsWith('try/') })
        $items = @(
            @{ label = '+ New version'; color = 'Green'; note = 'branch off from now, a commit, a tag or another version' },
            @{ label = 'The whole tree'; color = 'Cyan'; note = 'all versions, merges and tags drawn as a graph' })
        foreach ($b in $all) {
            $mark = ''; if ($b.Name -eq $cur) { $mark = '  <- you are here' }
            $items += @{ label = $b.Name + $mark; color = 'Yellow'; note = $b.When + ' - ' + $b.Subject }
        }
        $fc = 'Green'; if ($flash.StartsWith('!')) { $fc = 'Red' }
        $ix = Show-Choice -Title "Versions - $($p.Name)" -Subtitle "on: $cur   (works offline, uploads wait for internet)" -Items $items -Flash $flash.TrimStart('!').Trim() -FlashColor $fc -InitialIndex $last
        if ($null -eq $ix) { return $flash }
        $last = $ix
        if ($ix -eq 0) { $flash = New-GitVersion $p }
        elseif ($ix -eq 1) { Show-GitGraph $p '--all'; $flash = '' }
        else { $flash = Show-VersionActions $p $all[$ix - 2] }
    }
}
