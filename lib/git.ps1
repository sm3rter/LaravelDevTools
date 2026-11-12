$script:GitLast = ''

function Test-GitInstalled { return [bool](Get-Command git -ErrorAction SilentlyContinue) }
function Test-GhInstalled  { return [bool](Get-Command gh  -ErrorAction SilentlyContinue) }
function Test-GitRepo($p)  { return (Test-Path -LiteralPath (Join-Path $p.Path '.git')) }

function Write-Eol {
    try { $r = [Console]::WindowWidth - [Console]::CursorLeft - 1; if ($r -gt 0) { Write-Host (' ' * $r) -NoNewline } } catch {}
    Write-Host ''
}

function Wait-GitKey {
    while ($true) {
        $k = Read-KeyWait
        if ($null -ne $k) { return $k }
    }
}

function Get-GitOfflineMsg([string]$What) {
    return "! OFFLINE - $What needs internet"
}

function Add-GitPendingJob($Job) {
    if (Get-Command Add-PendingJob -ErrorAction SilentlyContinue) { Add-PendingJob $Job }
}

function Invoke-Git($p, [string[]]$GitArgs) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $env:GIT_TERMINAL_PROMPT = '0'; $env:GIT_EDITOR = 'true'; $env:GIT_PAGER = 'cat'
    $all = @('-C', $p.Path, '-c', 'core.quotepath=off') + $GitArgs
    $out = $null
    try { $out = & git @all 2>&1 } catch { $out = @("$_") }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    $lines = @($out | ForEach-Object { "$_" })
    $cmd = 'git ' + ($GitArgs -join ' ')
    $script:GitLast = $cmd
    Write-Log "`$ $cmd -> exit $code" $p
    return [pscustomobject]@{ Ok = ($code -eq 0); Code = $code; Out = $lines; Text = ($lines -join "`n"); Cmd = $cmd }
}

function Invoke-GitLive($p, [string[]]$GitArgs) {
    $env:GIT_TERMINAL_PROMPT = '1'; $env:GIT_EDITOR = 'true'; $env:GIT_PAGER = 'cat'
    $cmd = 'git ' + ($GitArgs -join ' ')
    $script:GitLast = $cmd
    Write-Host ''
    Write-Host " $ $cmd" -ForegroundColor DarkCyan
    Write-Host ''
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & git -C $p.Path @GitArgs
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    Write-Log "`$ $cmd -> exit $code" $p
    return $code
}

function Complete-Git($r, [string]$OkMsg) {
    if ($r.Ok) { return "$OkMsg   [$($r.Cmd)]" }
    $lines = @("$ $($r.Cmd)", "exit code $($r.Code)", '') + $r.Out
    Show-Pager 'git reported a problem' $lines
    $first = ($r.Out | Where-Object { $_.Trim() } | Select-Object -First 1)
    return "! $($r.Cmd) failed: $first"
}

function Get-GitInfo($p) {
    $i = [ordered]@{ Repo = $false; Branch = ''; Upstream = ''; Ahead = 0; Behind = 0; Gone = $false; Staged = 0; Modified = 0; Untracked = 0
                     Conflicts = 0; Detached = $false; NoCommits = $false; Files = @(); State = ''; Remotes = @(); Remote = ''; Last = ''; Stashes = 0 }
    if (-not (Test-GitRepo $p)) { return [pscustomobject]$i }
    $i.Repo = $true
    $r = Invoke-Git $p @('status', '--porcelain=v1', '-b')
    $files = New-Object 'System.Collections.Generic.List[object]'
    $cset = @('DD', 'AU', 'UD', 'UA', 'DU', 'AA', 'UU')
    foreach ($l in $r.Out) {
        if ($l.StartsWith('## ')) {
            $h = $l.Substring(3)
            if ($h -match '^(?:No commits yet on|Initial commit on) (.+)$') { $i.Branch = $Matches[1]; $i.NoCommits = $true }
            elseif ($h -match '^HEAD \(no branch\)') { $i.Detached = $true }
            elseif ($h -match '^(.+?)\.\.\.(\S+)(?: \[(.*)\])?$') {
                $i.Branch = $Matches[1]; $i.Upstream = $Matches[2]
                $t = $Matches[3]
                if ($t -match 'ahead (\d+)')  { $i.Ahead  = [int]$Matches[1] }
                if ($t -match 'behind (\d+)') { $i.Behind = [int]$Matches[1] }
                if ($t -match 'gone')         { $i.Gone = $true }
            } else { $i.Branch = $h }
        } elseif ($l.Length -ge 4) {
            $x = [string]$l[0]; $y = [string]$l[1]; $xy = $x + $y
            $path = $l.Substring(3); $orig = ''
            if ($path -match '^(.*) -> (.*)$') { $orig = $Matches[1]; $path = $Matches[2] }
            $kind = 'change'
            if ($xy -eq '??') { $kind = 'untracked'; $i.Untracked++ }
            elseif ($cset -contains $xy) { $kind = 'conflict'; $i.Conflicts++ }
            else {
                if ($x -ne ' ') { $i.Staged++ }
                if ($y -ne ' ') { $i.Modified++ }
            }
            $files.Add([pscustomobject]@{ X = $x; Y = $y; Path = $path.Trim('"'); Orig = $orig; Kind = $kind })
        }
    }
    $fa = New-Object 'object[]' $files.Count
    for ($n = 0; $n -lt $files.Count; $n++) { $fa[$n] = $files[$n] }
    $i['Files'] = $fa
    if ($i.Detached) { $sh = Invoke-Git $p @('rev-parse', '--short', 'HEAD'); $i.Branch = '(detached @ ' + ($sh.Out | Select-Object -First 1) + ')' }

    $gd = Join-Path $p.Path '.git'
    if (-not (Test-Path -LiteralPath $gd -PathType Container)) {
        $g = Invoke-Git $p @('rev-parse', '--git-dir'); $gd = ($g.Out | Select-Object -First 1)
        if ($gd -and -not [IO.Path]::IsPathRooted($gd)) { $gd = Join-Path $p.Path $gd }
    }
    if ($gd -and (Test-Path -LiteralPath $gd)) {
        if (Test-Path -LiteralPath (Join-Path $gd 'MERGE_HEAD'))       { $i.State = 'merge' }
        elseif ((Test-Path -LiteralPath (Join-Path $gd 'rebase-merge')) -or (Test-Path -LiteralPath (Join-Path $gd 'rebase-apply'))) { $i.State = 'rebase' }
        elseif (Test-Path -LiteralPath (Join-Path $gd 'CHERRY_PICK_HEAD')) { $i.State = 'cherry-pick' }
        elseif (Test-Path -LiteralPath (Join-Path $gd 'REVERT_HEAD'))      { $i.State = 'revert' }
    }

    $rm = Invoke-Git $p @('remote')
    $i.Remotes = @($rm.Out | Where-Object { $_.Trim() })
    if ($i.Remotes.Count -gt 0) {
        $name = if ($i.Remotes -contains 'origin') { 'origin' } else { $i.Remotes[0] }
        $u = Invoke-Git $p @('remote', 'get-url', $name)
        if ($u.Ok) { $i.Remote = ($u.Out | Select-Object -First 1) }
    }
    if (-not $i.NoCommits) {
        $lc = Invoke-Git $p @('log', '-1', '--format=%h  %s')
        if ($lc.Ok) { $i.Last = ($lc.Out | Select-Object -First 1) }
    }
    $st = Invoke-Git $p @('stash', 'list')
    $i.Stashes = @($st.Out | Where-Object { $_.Trim() }).Count
    return [pscustomobject]$i
}

function Get-GitPanel($p, $i) {
    $ws = Get-WinSize
    $W = [Math]::Min(78, $ws.W - 6); if ($W -lt 40) { $W = 40 }
    $line = { param($t) '| ' + (Limit-Text $t ($W - 4)).PadRight($W - 4) + ' |' }
    $bar = '+' + ('-' * ($W - 2)) + '+'
    $out = @($bar)
    if (-not $i.Repo) {
        $out += (& $line 'NOT A GIT REPOSITORY yet - use "Initialize repository" below')
        $out += $bar
        return $out
    }
    $b = $i.Branch
    $track = ''
    if ($i.Upstream) {
        $track = "  ->  $($i.Upstream)"
        if ($i.Gone) { $track += '  (remote branch is gone)' }
        elseif (($i.Ahead -eq 0) -and ($i.Behind -eq 0)) { $track += '  (in sync)' }
        else { $track += "  (^$($i.Ahead) ahead, v$($i.Behind) behind)" }
    } elseif (-not $i.Detached) { $track = '  ->  (no upstream - push to publish)' }
    $out += (& $line "BRANCH  $b$track")
    $out += (& $line ("FILES   staged $($i.Staged) | modified $($i.Modified) | untracked $($i.Untracked) | conflicts $($i.Conflicts)"))
    $rem = if ($i.Remote) { $i.Remote } else { '(no remote)' }
    $out += (& $line "REMOTE  $rem        STASHES $($i.Stashes)")
    if ($i.Last) { $out += (& $line "HEAD    $($i.Last)") }
    if ($i.Ahead -gt 0) { $out += (& $line "UNPUSHED  $($i.Ahead) commit(s) not on the remote yet") }
    if (-not (Test-Online)) { $out += (& $line 'OFFLINE - commits stay local, pushed automatically when internet returns') }
    if ($i.State) { $out += (& $line "!! $($i.State.ToUpper()) IN PROGRESS - resolve conflicts, then Continue (or Abort) !!") }
    $out += $bar
    $g = Invoke-Git $p @('log', '--graph', '--all', '--decorate', '--oneline', '--date-order', '-n', '6')
    if ($g.Ok) { foreach ($l in $g.Out) { $out += ('  ' + (Limit-Text $l ($ws.W - 8))) } }
    return $out
}

function Show-GitOutput($p, [string]$Title, [string[]]$GitArgs) {
    $r = Invoke-Git $p $GitArgs
    $lines = @("$ $($r.Cmd)", '') + $r.Out
    Show-Pager $Title $lines
}

function Esc-Arg([string]$s) { return $s.Replace('"', '\"') }

function Test-GitRefName($p, [string]$Name) {
    if (-not $Name) { return $false }
    return (Invoke-Git $p @('check-ref-format', '--branch', $Name)).Ok
}

function Get-RemoteNames($p) {
    return @((Invoke-Git $p @('remote')).Out | Where-Object { $_.Trim() })
}

function Select-GitRemote($p, [string]$Title = 'Choose a remote') {
    $rem = @(Get-RemoteNames $p)
    if ($rem.Count -eq 0) { return $null }
    if ($rem.Count -eq 1) { return $rem[0] }
    $items = @(); foreach ($r in $rem) { $items += @{ label = $r; enabled = $true; color = 'DarkGray'; note = ((Invoke-Git $p @('remote', 'get-url', $r)).Out | Select-Object -First 1) } }
    $ix = Show-Choice -Title $Title -Items $items
    if ($null -eq $ix) { return $null }
    return $rem[$ix]
}

function Test-GitIdentity($p) {
    $n = ((Invoke-Git $p @('config', 'user.name')).Out | Select-Object -First 1)
    $e = ((Invoke-Git $p @('config', 'user.email')).Out | Select-Object -First 1)
    return [bool]($n -and $e)
}

function Edit-GitIdentity($p) {
    $curN = ((Invoke-Git $p @('config', 'user.name')).Out | Select-Object -First 1)
    $curE = ((Invoke-Git $p @('config', 'user.email')).Out | Select-Object -First 1)
    $n = Read-Input 'Git identity' 'your name' @("current: $curN <$curE>", 'This is the author name shown on your commits.')
    if (-not $n) { return '! identity unchanged' }
    $e = Read-Input 'Git identity' 'your email' @('Use the same email as your GitHub account so commits are linked to you.')
    if (-not $e) { return '! identity unchanged' }
    $items = @(
        @{ label = 'This repository only'; enabled = $true; color = 'DarkGray'; note = 'git config user.name / user.email' },
        @{ label = 'Everywhere (global)';  enabled = $true; color = 'DarkGray'; note = 'git config --global ...' })
    $sc = Show-Choice -Title 'Save identity for' -Items $items
    if ($null -eq $sc) { return '! identity unchanged' }
    $g = @(); if ($sc -eq 1) { $g = @('--global') }
    $r1 = Invoke-Git $p (@('config') + $g + @('user.name', $n))
    $r2 = Invoke-Git $p (@('config') + $g + @('user.email', $e))
    if ($r1.Ok -and $r2.Ok) { return "identity saved: $n <$e>" }
    return '! could not save identity'
}

$script:LanePalette = @('Cyan', 'Green', 'Yellow', 'Magenta', 'Red', 'Blue', 'DarkCyan', 'DarkYellow')

function Get-GitGraphRows($p, [string]$Ref, [string]$Path) {
    $a = @('log', '--graph', '--decorate', '--date-order', '-n', '400', '--format=format:%x01%h%x02%D%x02%an%x02%ar%x02%s')
    if ($Ref -eq '--all') { $a += '--all' } elseif ($Ref) { $a += $Ref }
    if ($Path) { $a += @('--', $Path) }
    $r = Invoke-Git $p $a
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($l in $r.Out) {
        $ix = $l.IndexOf([char]1)
        if ($ix -ge 0) {
            $f = $l.Substring($ix + 1).Split([char]2)
            $subj = ''; if ($f.Count -ge 5) { $subj = $f[4] }
            $rows.Add([pscustomobject]@{ Prefix = $l.Substring(0, $ix); Hash = $f[0]; Refs = $f[1]; Author = $f[2]; When = $f[3]; Subject = $subj; IsCommit = $true })
        } else {
            $rows.Add([pscustomobject]@{ Prefix = $l; Hash = ''; Refs = ''; Author = ''; When = ''; Subject = ''; IsCommit = $false })
        }
    }
    return , $rows.ToArray()
}

function Write-Seg([string]$t, [string]$c, [int]$b) {
    if ($b -le 0) { return 0 }
    if ($t.Length -gt $b) { $t = $t.Substring(0, $b) }
    Write-Host $t -NoNewline -ForegroundColor $c
    return ($b - $t.Length)
}

function Write-GraphRow($row, [bool]$Sel, [int]$Width, $Remotes) {
    $b = $Width
    if ($Sel) { Write-Host '>' -NoNewline -ForegroundColor White } else { Write-Host ' ' -NoNewline }
    $b--
    $pre = $row.Prefix
    for ($c = 0; ($c -lt $pre.Length) -and ($b -gt 0); $c++) {
        $ch = [string]$pre[$c]
        if ($ch -eq ' ') { Write-Host ' ' -NoNewline }
        else {
            $col = $script:LanePalette[[int][Math]::Floor($c / 2) % $script:LanePalette.Count]
            if ($ch -eq '*') { $ch = [string][char]0x25CF } elseif ($ch -eq '|') { $ch = [string][char]0x2502 } elseif ($ch -eq '_') { $ch = [string][char]0x2500 }
            Write-Host $ch -NoNewline -ForegroundColor $col
        }
        $b--
    }
    if (-not $row.IsCommit) { return }
    $b = Write-Seg (' ' + $row.Hash + ' ') 'Yellow' $b
    if ($row.Refs) {
        foreach ($rf in ($row.Refs -split ', ')) {
            $name = $rf.Trim(); if (-not $name) { continue }
            $col = 'Cyan'
            if ($name.StartsWith('HEAD')) { $col = 'Green' }
            elseif ($name.StartsWith('tag: ')) { $col = 'DarkYellow' }
            else { foreach ($rm in $Remotes) { if ($name.StartsWith("$rm/")) { $col = 'Red' } } }
            $b = Write-Seg "[$name] " $col $b
        }
    }
    $sc = 'Gray'; if ($Sel) { $sc = 'White' }
    $b = Write-Seg $row.Subject $sc $b
    $b = Write-Seg ("   - " + $row.Author + ', ' + $row.When) 'DarkGray' $b
}

function Show-GitGraph($p, [string]$Ref = '--all', [string]$Path = '') {
    $remotes = @(Get-RemoteNames $p)
    $rows = @(Get-GitGraphRows $p $Ref $Path)
    $commitIdx = @(); for ($n = 0; $n -lt $rows.Count; $n++) { if ($rows[$n].IsCommit) { $commitIdx += $n } }
    if ($commitIdx.Count -eq 0) { Show-Pager 'History' (@('No commits to show yet.') + @($rows | ForEach-Object { $_.Prefix })); return }
    $sel = 0; $off = 0; $flash = ''; $flashColor = 'Green'
    $scopeName = if ($Ref -eq '--all') { 'all branches' } elseif ($Ref) { $Ref } else { 'current branch' }
    try { [Console]::CursorVisible = $false } catch {}
    Clear-Host
    try {
        while ($true) {
            $ws = Get-WinSize
            $vis = $ws.H - 7; if ($vis -lt 4) { $vis = 4 }
            $cur = $commitIdx[$sel]
            if ($cur -lt $off) { $off = $cur }
            if ($cur -ge ($off + $vis)) { $off = $cur - $vis + 1 }
            try { [Console]::SetCursorPosition(0, 0) } catch { Clear-Host }
            Write-Host " History graph - $($p.Name)   [$scopeName]" -NoNewline -ForegroundColor Cyan; Write-Eol
            Write-Host ' Up/Down commit   PgUp/PgDn page   Enter actions   A all/current branch   R refresh   Backspace back   Esc exit' -NoNewline -ForegroundColor DarkGray; Write-Eol
            Write-Host (' ' + ('-' * [Math]::Max(1, $ws.W - 3))) -NoNewline -ForegroundColor DarkGray; Write-Eol
            for ($n = 0; $n -lt $vis; $n++) {
                $ix = $off + $n
                if ($ix -lt $rows.Count) { Write-GraphRow $rows[$ix] ($ix -eq $cur) ($ws.W - 2) $remotes }
                Write-Eol
            }
            Write-Host (' ' + ('-' * [Math]::Max(1, $ws.W - 3))) -NoNewline -ForegroundColor DarkGray; Write-Eol
            $r = $rows[$cur]
            Write-Host (Limit-Text (" $($r.Hash)  $($r.Author)  $($r.When)  $($r.Subject)") ($ws.W - 2)) -NoNewline -ForegroundColor White; Write-Eol
            if ($flash) { Write-Host (Limit-Text " $flash" ($ws.W - 2)) -NoNewline -ForegroundColor $flashColor }
            Write-Eol
            $k = Read-KeyWait
            if ($null -eq $k) { continue }
            $flash = ''
            $reload = $false
            switch ($k.Key) {
                'UpArrow'   { if ($sel -gt 0) { $sel-- } }
                'DownArrow' { if ($sel -lt ($commitIdx.Count - 1)) { $sel++ } }
                'PageUp'    { $sel = [Math]::Max(0, $sel - 10) }
                'PageDown'  { $sel = [Math]::Min($commitIdx.Count - 1, $sel + 10) }
                'Home'      { $sel = 0 }
                'End'       { $sel = $commitIdx.Count - 1 }
                'R'         { $reload = $true }
                'A'         { if ($Ref -eq '--all') { $Ref = '' ; $scopeName = 'current branch' } else { $Ref = '--all'; $scopeName = 'all branches' }; $reload = $true; $sel = 0; $off = 0 }
                'Enter'     {
                    $msg = Show-GitCommitActions $p $r.Hash
                    Clear-Host
                    if ($msg) { $flash = $msg.TrimStart('!').Trim(); if ($msg.StartsWith('!')) { $flashColor = 'Red' } else { $flashColor = 'Green' } }
                    $reload = $true
                }
                'Backspace' { return }
                'LeftArrow' { return }
                'Q'         { return }
                'Escape'    { [void](Exit-Tool) }
            }
            if ($reload) {
                $keep = $rows[$commitIdx[$sel]].Hash
                $rows = @(Get-GitGraphRows $p $Ref $Path)
                $commitIdx = @(); for ($n = 0; $n -lt $rows.Count; $n++) { if ($rows[$n].IsCommit) { $commitIdx += $n } }
                if ($commitIdx.Count -eq 0) { return }
                $sel = 0
                for ($n = 0; $n -lt $commitIdx.Count; $n++) { if ($rows[$commitIdx[$n]].Hash -eq $keep) { $sel = $n; break } }
                Clear-Host
            }
        }
    } finally {
        try { [Console]::CursorVisible = $true } catch {}
        Clear-Host
    }
}

function Show-GitCommitActions($p, [string]$Hash) {
    $info = ((Invoke-Git $p @('log', '-1', '--format=%h  %an, %ar  -  %s', $Hash)).Out | Select-Object -First 1)
    $defs = @(
        @('Show changes',                    'full diff of this commit',                     'show'),
        @('Checkout this commit',            'detached HEAD - look around, nothing changes', 'checkout'),
        @('New branch here',                 'start a branch at this commit',                'branch'),
        @('New tag here',                    'mark this commit (e.g. v1.0)',                 'tag'),
        @('Cherry-pick onto current branch', 'copy this commit to where you are now',        'pick'),
        @('Revert this commit',              'new commit that undoes it (safe)',             'revert'),
        @('Reset current branch to here',    'soft / mixed / hard',                          'reset'),
        @('Diff against working tree',       'what changed since this commit',               'diffwt'),
        @('Diff against HEAD',               'this commit vs where you are',                 'diffhead'),
        @('Copy full hash',                  'to clipboard',                                 'copy'))
    $items = @(); $acts = @()
    foreach ($d in $defs) { $items += @{ label = $d[0]; enabled = $true; color = 'DarkGray'; note = $d[1] }; $acts += $d[2] }
    $ix = Show-Choice -Title "Commit $Hash" -Subtitle $info -Items $items
    if ($null -eq $ix) { return '' }
    switch ($acts[$ix]) {
        'show'     { Show-GitOutput $p "commit $Hash" @('show', '--stat', '--patch', '--format=fuller', $Hash); return '' }
        'diffwt'   { Show-GitOutput $p "diff $Hash -> working tree" @('diff', $Hash); return '' }
        'diffhead' { Show-GitOutput $p "diff $Hash -> HEAD" @('diff', $Hash, 'HEAD'); return '' }
        'checkout' { return (Complete-Git (Invoke-Git $p @('checkout', $Hash)) "HEAD is now detached at $Hash") }
        'branch' {
            $n = Read-Input "New branch at $Hash" 'branch name' @('Example: feature/login   (no spaces)')
            if (-not $n) { return '' }
            if (-not (Test-GitRefName $p $n)) { return "! '$n' is not a valid branch name" }
            if (Read-Confirm "Switch to '$n' right away?") { return (Complete-Git (Invoke-Git $p @('checkout', '-b', $n, $Hash)) "created and switched to $n") }
            return (Complete-Git (Invoke-Git $p @('branch', $n, $Hash)) "created branch $n")
        }
        'tag' {
            $n = Read-Input "New tag at $Hash" 'tag name' @('Example: v1.2.0')
            if (-not $n) { return '' }
            $m = Read-Input "Tag $n" 'message (ENTER = lightweight tag)'
            if ($m) { return (Complete-Git (Invoke-Git $p @('tag', '-a', $n, '-m', (Esc-Arg $m), $Hash)) "tag $n created") }
            return (Complete-Git (Invoke-Git $p @('tag', $n, $Hash)) "tag $n created")
        }
        'pick'   { return (Complete-Git (Invoke-Git $p @('cherry-pick', $Hash)) "cherry-picked $Hash") }
        'revert' { return (Complete-Git (Invoke-Git $p @('revert', '--no-edit', $Hash)) "reverted $Hash") }
        'reset' {
            $mi = @(
                @{ label = 'Soft';  enabled = $true; color = 'DarkGray'; note = 'move the branch only - everything stays staged' },
                @{ label = 'Mixed'; enabled = $true; color = 'DarkGray'; note = 'move the branch, keep files, unstage' },
                @{ label = 'Hard';  enabled = $true; color = 'Red';      note = 'DISCARD all changes and go back to this commit' })
            $m = Show-Choice -Title "Reset current branch to $Hash" -Subtitle $info -Items $mi
            if ($null -eq $m) { return '' }
            $mode = @('--soft', '--mixed', '--hard')[$m]
            if ($m -eq 2) {
                Clear-Host
                Write-Host ' Hard reset throws away uncommitted work and later commits (reflog can still recover them).' -ForegroundColor Yellow
                if (-not (Read-TypedConfirm 'reset')) { return '! reset cancelled' }
            }
            return (Complete-Git (Invoke-Git $p @('reset', $mode, $Hash)) "branch reset ($mode) to $Hash")
        }
        'copy' {
            $full = ((Invoke-Git $p @('rev-parse', $Hash)).Out | Select-Object -First 1)
            try { Set-Clipboard -Value $full; return "copied $full" } catch { return "! clipboard not available - hash is $full" }
        }
    }
    return ''
}

function Get-GitBranchData($p, [bool]$Remote) {
    $cur = ''
    $c = Invoke-Git $p @('symbolic-ref', '--short', '-q', 'HEAD')
    if ($c.Ok) { $cur = ($c.Out | Select-Object -First 1) }
    $fmt = '--format=%(HEAD)%09%(refname:short)%09%(upstream:short)%09%(upstream:track)%09%(committerdate:relative)%09%(subject)%09%(objectname:short)%09%(refname)'
    $refs = @('refs/heads'); if ($Remote) { $refs += 'refs/remotes' }
    $r = Invoke-Git $p (@('for-each-ref', '--sort=refname', $fmt) + $refs)
    $merged = @{}
    if ($cur) { foreach ($l in (Invoke-Git $p @('branch', '--merged')).Out) { $merged[$l.Trim('* ').Trim()] = $true } }
    $list = New-Object 'System.Collections.Generic.List[object]'
    $n = 0
    foreach ($l in $r.Out) {
        $f = $l.Split("`t")
        if ($f.Count -lt 8) { continue }
        if ($f[7].EndsWith('/HEAD')) { continue }
        $isRemote = $f[7].StartsWith('refs/remotes/')
        $b = [pscustomobject]@{ Name = $f[1]; Remote = $isRemote; Current = ($f[0].Trim() -eq '*'); Upstream = $f[2]; Track = $f[3]; Date = $f[4]; Subject = $f[5]; Oid = $f[6]
                                Ahead = -1; Behind = -1; Merged = ($merged.ContainsKey($f[1]) -and ($f[1] -ne $cur)) }
        if ((-not $isRemote) -and $cur -and ($f[1] -ne $cur) -and ($n -lt 40)) {
            $n++
            $cnt = Invoke-Git $p @('rev-list', '--left-right', '--count', "$cur...$($f[1])")
            if ($cnt.Ok -and ($cnt.Out[0] -match '^(\d+)\s+(\d+)')) { $b.Behind = [int]$Matches[1]; $b.Ahead = [int]$Matches[2] }
        }
        $list.Add($b)
    }
    return @{ Current = $cur; Branches = $list.ToArray() }
}

function New-BranchTree($branches) {
    $root = @{ Kids = [ordered]@{}; Leaf = $null; Name = '' }
    foreach ($b in $branches) {
        $parts = $b.Name.Split('/'); $node = $root
        for ($i = 0; $i -lt $parts.Count; $i++) {
            $part = $parts[$i]
            if (-not $node.Kids.Contains($part)) { $node.Kids[$part] = @{ Kids = [ordered]@{}; Leaf = $null; Name = $part } }
            $node = $node.Kids[$part]
        }
        $node.Leaf = $b
    }
    return $root
}

function Add-BranchTreeRows($node, [string]$prefix, $rows) {
    $keys = @($node.Kids.Keys)
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $kid = $node.Kids[$keys[$i]]
        $last = ($i -eq ($keys.Count - 1))
        if ($last) { $conn = '\-- ' } else { $conn = '|-- ' }
        $label = $kid.Name; if (-not $kid.Leaf) { $label += '/' }
        $rows.Add([pscustomobject]@{ Art = ($prefix + $conn); Label = $label; Branch = $kid.Leaf })
        if ($kid.Kids.Count -gt 0) {
            if ($last) { $np = $prefix + '    ' } else { $np = $prefix + '|   ' }
            Add-BranchTreeRows $kid $np $rows
        }
    }
}

function Get-BranchRows($data, [bool]$Remote) {
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $loc = @($data.Branches | Where-Object { -not $_.Remote })
    $rows.Add([pscustomobject]@{ Art = ''; Label = 'LOCAL BRANCHES'; Branch = $null })
    Add-BranchTreeRows (New-BranchTree $loc) '' $rows
    if ($Remote) {
        $rem = @($data.Branches | Where-Object { $_.Remote })
        $rows.Add([pscustomobject]@{ Art = ''; Label = ''; Branch = $null })
        $rows.Add([pscustomobject]@{ Art = ''; Label = 'REMOTE BRANCHES'; Branch = $null })
        Add-BranchTreeRows (New-BranchTree $rem) '' $rows
    }
    return , $rows.ToArray()
}

function Write-BranchRow($row, [bool]$Sel, [int]$Width, [int]$LabelW, [string]$Cur) {
    $b = $Width
    if ($Sel) { Write-Host '>' -NoNewline -ForegroundColor White } else { Write-Host ' ' -NoNewline }
    $b--
    $br = $row.Branch
    if (-not $br) {
        $c = 'DarkGray'; if ($row.Label -match 'BRANCHES$') { $c = 'Cyan' }
        $b = Write-Seg ($row.Art + $row.Label) $c $b
        return
    }
    $b = Write-Seg $row.Art 'DarkGray' $b
    if ($br.Current) { $b = Write-Seg '* ' 'Green' $b } else { $b = Write-Seg '  ' 'Gray' $b }
    $nc = 'Gray'; if ($br.Current) { $nc = 'Green' } elseif ($Sel) { $nc = 'White' } elseif ($br.Remote) { $nc = 'Red' }
    $b = Write-Seg $row.Label.PadRight($LabelW) $nc $b
    if ($br.Upstream) {
        $t = " [$($br.Upstream)"
        $trk = $br.Track.Trim('[', ']')
        if ($trk) { $t += " $trk" }
        $t += ']'
        $col = 'DarkCyan'; if ($trk) { $col = 'Yellow' }
        $b = Write-Seg $t $col $b
    }
    if ((-not $br.Current) -and ($br.Ahead -ge 0)) {
        $t = " ^$($br.Ahead) v$($br.Behind)"
        $col = 'DarkGray'; if (($br.Ahead -eq 0) -and ($br.Behind -eq 0)) { $t = ' ='; $col = 'DarkGray' } elseif ($br.Ahead -gt 0) { $col = 'Green' }
        $b = Write-Seg $t $col $b
    }
    if ($br.Merged) { $b = Write-Seg ' merged' 'DarkGreen' $b }
    $b = Write-Seg ("   " + $br.Date + '  ' + $br.Subject) 'DarkGray' $b
}

function Invoke-GitMerge($p, [string]$Name) {
    $items = @(
        @{ label = 'Merge';                enabled = $true; color = 'DarkGray'; note = 'fast-forward when possible (git merge)' },
        @{ label = 'Merge --no-ff';        enabled = $true; color = 'DarkGray'; note = 'always create a merge commit' },
        @{ label = 'Squash merge';         enabled = $true; color = 'DarkGray'; note = 'bring the changes in as ONE staged commit (you commit after)' })
    $ix = Show-Choice -Title "Merge '$Name' into the current branch" -Items $items
    if ($null -eq $ix) { return '' }
    switch ($ix) {
        0 { return (Complete-Git (Invoke-Git $p @('merge', '--no-edit', $Name)) "merged $Name") }
        1 { return (Complete-Git (Invoke-Git $p @('merge', '--no-ff', '--no-edit', $Name)) "merged $Name (merge commit)") }
        2 { return (Complete-Git (Invoke-Git $p @('merge', '--squash', $Name)) "squashed $Name - review it in Changes and commit") }
    }
    return ''
}

function Switch-GitBranch($p, [string]$Name, [bool]$Remote) {
    if ($Remote) {
        $short = $Name -replace '^[^/]+/', ''
        if ((Invoke-Git $p @('show-ref', '--verify', '--quiet', "refs/heads/$short")).Ok) { $a = @('checkout', $short) }
        else { $a = @('checkout', '--track', $Name) }
    } else { $a = @('checkout', $Name) }
    $r = Invoke-Git $p $a
    if ($r.Ok) { return "switched to $Name   [$($r.Cmd)]" }
    if ($r.Text -match 'would be overwritten|local changes|commit your changes or stash') {
        Clear-Host
        foreach ($l in $r.Out) { Write-Host "  $l" -ForegroundColor Yellow }
        if (Read-Confirm 'Your local changes are in the way. Stash them (incl. untracked), switch, and keep the stash?') {
            $s = Invoke-Git $p @('stash', 'push', '-u', '-m', "auto-stash before switching to $Name")
            if (-not $s.Ok) { return (Complete-Git $s '') }
            return (Complete-Git (Invoke-Git $p $a) "switched to $Name (your changes are in the stash)")
        }
        return '! switch cancelled - local changes are in the way'
    }
    return (Complete-Git $r '')
}

function Get-GitPushRemote($info) {
    $rm = 'origin'
    if ($info.Upstream -and $info.Upstream.Contains('/')) { $rm = $info.Upstream.Substring(0, $info.Upstream.IndexOf('/')) }
    elseif (($info.Remotes.Count -gt 0) -and ($info.Remotes -notcontains 'origin')) { $rm = $info.Remotes[0] }
    return $rm
}

function Invoke-GitPush($p, [string[]]$Extra = @()) {
    $info = Get-GitInfo $p
    if ($info.NoCommits) { return '! no commits yet - commit something first' }
    if ($info.Detached)  { return '! detached HEAD - create a branch first' }
    if ($info.Remotes.Count -eq 0) { return '! no remote yet - add one in Remotes, or create a GitHub repository' }
    if (-not (Test-Online)) {
        if (@($Extra).Count -gt 0) { return (Get-GitOfflineMsg 'this kind of push') }
        Add-GitPendingJob @{ type = 'push'; path = $p.Path; remote = (Get-GitPushRemote $info); branch = $info.Branch }
        return 'OFFLINE - saved locally, will be pushed automatically when the tool opens with internet'
    }
    if ($info.Upstream -and (-not $info.Gone)) { $a = @('push') + $Extra }
    else {
        $rm = 'origin'
        if ($info.Remotes -notcontains 'origin') { $rm = Select-GitRemote $p 'Push to which remote?'; if (-not $rm) { return '! cancelled' } }
        $a = @('push', '-u') + $Extra + @($rm, $info.Branch)
    }
    Clear-Host
    $code = Invoke-GitLive $p $a
    Pause-Key
    if ($code -eq 0) { return "pushed   [git $($a -join ' ')]" }
    return "! push failed (exit $code) - if it was rejected, pull first"
}

function Invoke-GitPull($p, [string]$Mode = '') {
    if (-not (Test-Online)) { return (Get-GitOfflineMsg 'pull') }
    $a = @('pull', '--no-edit')
    if ($Mode -eq 'rebase') { $a = @('pull', '--rebase') }
    if ($Mode -eq 'ff-only') { $a = @('pull', '--ff-only') }
    Clear-Host
    $code = Invoke-GitLive $p $a
    Pause-Key
    if ($code -eq 0) { return "pulled   [git $($a -join ' ')]" }
    return "! pull failed (exit $code) - see Resolve conflicts if a merge stopped"
}

function Invoke-GitFetch($p) {
    if (-not (Test-Online)) { return (Get-GitOfflineMsg 'fetch') }
    Clear-Host
    $code = Invoke-GitLive $p @('fetch', '--all', '--prune')
    Pause-Key
    if ($code -eq 0) { return 'fetched all remotes (stale remote branches pruned)   [git fetch --all --prune]' }
    return "! fetch failed (exit $code)"
}

function Show-GitBranches($p) {
    $showRemote = $false
    $flash = ''; $flashColor = 'Green'
    $sel = 0; $off = 0
    $data = Get-GitBranchData $p $showRemote
    $rows = Get-BranchRows $data $showRemote
    try { [Console]::CursorVisible = $false } catch {}
    Clear-Host
    try {
        while ($true) {
            $selIdx = @(); for ($n = 0; $n -lt $rows.Count; $n++) { if ($rows[$n].Branch) { $selIdx += $n } }
            if ($selIdx.Count -eq 0) { Show-Pager 'Branches' @('No branches yet - make the first commit.'); return }
            if ($sel -ge $selIdx.Count) { $sel = $selIdx.Count - 1 }
            if ($sel -lt 0) { $sel = 0 }
            $cur = $selIdx[$sel]
            $curBr = $rows[$cur].Branch
            $labelW = 10
            foreach ($rw in $rows) { if ($rw.Branch) { $labelW = [Math]::Max($labelW, $rw.Label.Length) } }
            $ws = Get-WinSize
            $vis = $ws.H - 9; if ($vis -lt 4) { $vis = 4 }
            if ($cur -lt $off) { $off = $cur }
            if ($cur -ge ($off + $vis)) { $off = $cur - $vis + 1 }
            try { [Console]::SetCursorPosition(0, 0) } catch { Clear-Host }
            Write-Host " Branches - $($p.Name)    current: $($data.Current)" -NoNewline -ForegroundColor Cyan; Write-Eol
            Write-Host " ^N = commits the branch has that '$($data.Current)' lacks, vN = commits '$($data.Current)' has that it lacks, '=' same, merged = already in current" -NoNewline -ForegroundColor DarkGray; Write-Eol
            Write-Host (' ' + ('-' * [Math]::Max(1, $ws.W - 3))) -NoNewline -ForegroundColor DarkGray; Write-Eol
            for ($n = 0; $n -lt $vis; $n++) {
                $ix = $off + $n
                if ($ix -lt $rows.Count) { Write-BranchRow $rows[$ix] ($ix -eq $cur) ($ws.W - 2) $labelW $data.Current }
                Write-Eol
            }
            Write-Host (' ' + ('-' * [Math]::Max(1, $ws.W - 3))) -NoNewline -ForegroundColor DarkGray; Write-Eol
            Write-Host ' Enter switch   N new   D delete   M merge into current   B rebase current onto   R rename   P push   U set upstream' -NoNewline -ForegroundColor DarkGray; Write-Eol
            Write-Host ' C compare with current   G graph of branch   T show remote branches   F fetch   Backspace back   Esc exit' -NoNewline -ForegroundColor DarkGray; Write-Eol
            if ($flash) { Write-Host (Limit-Text " $flash" ($ws.W - 2)) -NoNewline -ForegroundColor $flashColor }
            Write-Eol
            $k = Read-KeyWait
            if ($null -eq $k) { continue }
            $flash = ''; $msg = ''; $reload = $false
            $name = $curBr.Name
            switch ($k.Key) {
                'UpArrow'   { if ($sel -gt 0) { $sel-- } }
                'DownArrow' { if ($sel -lt ($selIdx.Count - 1)) { $sel++ } }
                'PageUp'    { $sel = [Math]::Max(0, $sel - 10) }
                'PageDown'  { $sel = [Math]::Min($selIdx.Count - 1, $sel + 10) }
                'Home'      { $sel = 0 }
                'End'       { $sel = $selIdx.Count - 1 }
                'Enter'     { if ($curBr.Current) { $msg = 'already on this branch' } else { $msg = Switch-GitBranch $p $name $curBr.Remote; $reload = $true } }
                'T'         { $showRemote = -not $showRemote; $reload = $true; $msg = if ($showRemote) { 'showing remote branches (last fetch)' } else { 'hiding remote branches' } }
                'F'         { $msg = Invoke-GitFetch $p; $reload = $true }
                'N' {
                    $base = if ($curBr.Remote -or -not $curBr.Current) { $name } else { 'HEAD' }
                    $nn = Read-Input 'New branch' 'branch name' @("starts from: $base", 'Example: feature/login   (no spaces)')
                    if ($nn) {
                        if (-not (Test-GitRefName $p $nn)) { $msg = "! '$nn' is not a valid branch name" }
                        else { $msg = Complete-Git (Invoke-Git $p @('checkout', '-b', $nn, $base)) "created and switched to $nn" }
                        $reload = $true
                    }
                    Clear-Host
                }
                'D' {
                    Clear-Host
                    if ($curBr.Current) { $msg = '! you cannot delete the branch you are on - switch first' }
                    elseif ($curBr.Remote) {
                        if (-not (Test-Online)) { $msg = (Get-GitOfflineMsg 'deleting a remote branch') }
                        else {
                            $rm = $name.Split('/')[0]; $short = $name.Substring($rm.Length + 1)
                            Write-Host " Delete '$short' on remote '$rm'?" -ForegroundColor Yellow
                            if (Read-TypedConfirm 'delete') { $msg = Complete-Git (Invoke-Git $p @('push', $rm, '--delete', $short)) "deleted $name on the remote" }
                            $reload = $true
                        }
                    } else {
                        $r = Invoke-Git $p @('branch', '-d', $name)
                        if ($r.Ok) { $msg = "deleted $name   [$($r.Cmd)]" }
                        elseif ($r.Text -match 'not fully merged') {
                            Write-Host " '$name' has commits that are not merged anywhere else." -ForegroundColor Yellow
                            if (Read-Confirm 'Delete it anyway? (the commits stay reachable through the reflog for a while)') { $msg = Complete-Git (Invoke-Git $p @('branch', '-D', $name)) "force-deleted $name" }
                        } else { $msg = Complete-Git $r '' }
                        $reload = $true
                    }
                    Clear-Host
                }
                'M' {
                    if ($curBr.Current) { $msg = '! pick another branch to merge into the current one' }
                    else { $msg = Invoke-GitMerge $p $name; $reload = $true }
                    Clear-Host
                }
                'B' {
                    Clear-Host
                    if ($curBr.Current) { $msg = '! pick the branch to rebase onto' }
                    elseif (Read-Confirm "Rebase '$($data.Current)' onto '$name'? (rewrites the commits of the current branch)") { $msg = Complete-Git (Invoke-Git $p @('rebase', $name)) "rebased onto $name"; $reload = $true }
                    Clear-Host
                }
                'R' {
                    if ($curBr.Remote) { $msg = '! remote branches cannot be renamed here' }
                    else {
                        $nn = Read-Input 'Rename branch' 'new name' @("current name: $name")
                        if ($nn -and ($nn -ne $name)) {
                            if (-not (Test-GitRefName $p $nn)) { $msg = "! '$nn' is not a valid branch name" } else { $msg = Complete-Git (Invoke-Git $p @('branch', '-m', $name, $nn)) "renamed $name -> $nn" }
                            $reload = $true
                        }
                    }
                    Clear-Host
                }
                'P' {
                    if ($curBr.Remote) { $msg = '! select a local branch to push' }
                    else {
                        Clear-Host
                        $rm = Select-GitRemote $p 'Push to which remote?'
                        if (-not $rm) { $msg = '! no remote available' }
                        elseif (-not (Test-Online)) {
                            Add-GitPendingJob @{ type = 'push'; path = $p.Path; remote = $rm; branch = $name }
                            $msg = 'OFFLINE - saved locally, will be pushed automatically when the tool opens with internet'
                        }
                        else {
                            $code = Invoke-GitLive $p @('push', '-u', $rm, $name)
                            Pause-Key
                            if ($code -eq 0) { $msg = "pushed $name to $rm" } else { $msg = "! push failed (exit $code)" }
                            $reload = $true
                        }
                    }
                    Clear-Host
                }
                'U' {
                    if ($curBr.Remote) { $msg = '! select a local branch' }
                    else {
                        $rm = Select-GitRemote $p 'Track which remote?'
                        if ($rm) { $msg = Complete-Git (Invoke-Git $p @('branch', "--set-upstream-to=$rm/$name", $name)) "$name now tracks $rm/$name"; $reload = $true }
                    }
                    Clear-Host
                }
                'C' {
                    if ($curBr.Current) { $msg = '! pick another branch to compare with the current one' }
                    else {
                        $c = $data.Current
                        $l1 = (Invoke-Git $p @('log', '--left-right', '--oneline', '--boundary', "$c...$name")).Out
                        $l2 = (Invoke-Git $p @('diff', '--stat', "$c...$name")).Out
                        Show-Pager "Compare $c  <  >  $name" (@("== '<' only in $c        '>' only in $name ==") + $l1 + @('', "== files changed on $name since it left $c ==") + $l2)
                    }
                    Clear-Host
                }
                'G' { Show-GitGraph $p $name; Clear-Host }
                'Backspace' { return }
                'LeftArrow' { return }
                'Q'         { return }
                'Escape'    { [void](Exit-Tool) }
            }
            if ($msg) { $flash = $msg.TrimStart('!').Trim(); if ($msg.StartsWith('!')) { $flashColor = 'Red' } else { $flashColor = 'Green' } }
            if ($reload) {
                $keepName = $name
                $data = Get-GitBranchData $p $showRemote
                $rows = Get-BranchRows $data $showRemote
                $sel = 0; $ii = 0
                for ($n = 0; $n -lt $rows.Count; $n++) { if ($rows[$n].Branch) { if ($rows[$n].Branch.Name -eq $keepName) { $sel = $ii }; $ii++ } }
                Clear-Host
            }
        }
    } finally {
        try { [Console]::CursorVisible = $true } catch {}
        Clear-Host
    }
}

function Invoke-GitCommit($p) {
    $info = Get-GitInfo $p
    if ($info.Conflicts -gt 0) { return '! resolve the conflicts first (Resolve conflicts)' }
    if ($info.Staged -eq 0) {
        if (($info.Modified + $info.Untracked) -eq 0) { return '! nothing to commit - working tree clean' }
        Clear-Host
        Write-Host ' Nothing is staged yet.' -ForegroundColor Yellow
        if (-not (Read-Confirm 'Stage ALL changes (git add -A) and commit?')) { return '! cancelled - stage files in Changes first' }
        $a = Invoke-Git $p @('add', '-A')
        if (-not $a.Ok) { return (Complete-Git $a '') }
    }
    $names = (Invoke-Git $p @('diff', '--cached', '--name-only')).Out
    $risky = @($names | Where-Object { ($_ -match '(^|/)\.env(\.|$)') -and ($_ -notmatch '\.example$') })
    if ($risky.Count -gt 0) {
        Clear-Host
        Write-Host ' [!] These look like secret files:' -ForegroundColor Red
        foreach ($f in $risky) { Write-Host "     $f" -ForegroundColor Red }
        Write-Host '     Anything committed (and pushed) can leak. Add them to .gitignore instead.' -ForegroundColor Yellow
        if (-not (Read-Confirm 'Commit them anyway?')) { return '! cancelled - secret files are staged' }
    }
    if (-not (Test-GitIdentity $p)) {
        [void](Edit-GitIdentity $p)
        if (-not (Test-GitIdentity $p)) { return '! set your name and email first (Identity & config)' }
    }
    Clear-Host
    Write-Host " Commit - $($p.Name)" -ForegroundColor Cyan
    Write-Host ''
    $st = (Invoke-Git $p @('diff', '--cached', '--name-status')).Out
    foreach ($l in ($st | Select-Object -First 22)) {
        $c = 'Gray'
        if ($l.StartsWith('A')) { $c = 'Green' } elseif ($l.StartsWith('D')) { $c = 'Red' } elseif ($l.StartsWith('R')) { $c = 'Cyan' } elseif ($l.StartsWith('M')) { $c = 'Yellow' }
        Write-Host "   $l" -ForegroundColor $c
    }
    if ($st.Count -gt 22) { Write-Host "   ... and $($st.Count - 22) more" -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host '  ESC = cancel' -ForegroundColor DarkGray
    $subject = Read-LineEsc '  message> '
    if (($null -eq $subject) -or (-not $subject.Trim())) { return '! commit cancelled' }
    $body = Read-LineEsc '  description (optional, ENTER to skip)> '
    $a = @('commit', '-m', (Esc-Arg $subject.Trim()))
    if ($body -and $body.Trim()) { $a += @('-m', (Esc-Arg $body.Trim())) }
    return (Complete-Git (Invoke-Git $p $a) 'committed')
}

function Invoke-GitAmend($p) {
    $info = Get-GitInfo $p
    if ($info.NoCommits) { return '! no commit to amend yet' }
    $items = @(
        @{ label = 'Add staged changes, keep the message'; enabled = $true; color = 'DarkGray'; note = 'git commit --amend --no-edit' },
        @{ label = 'Change the message';                    enabled = $true; color = 'DarkGray'; note = 'git commit --amend -m ...' })
    $sub = ''
    if ($info.Upstream -and ($info.Ahead -eq 0)) { $sub = 'WARNING: the last commit is already pushed - amending needs a force push afterwards' }
    $ix = Show-Choice -Title 'Amend the last commit' -Subtitle $sub -Items $items
    if ($null -eq $ix) { return '' }
    if ($ix -eq 0) { return (Complete-Git (Invoke-Git $p @('commit', '--amend', '--no-edit')) 'last commit amended') }
    $m = Read-Input 'Amend message' 'new message'
    if (-not $m) { return '' }
    return (Complete-Git (Invoke-Git $p @('commit', '--amend', '-m', (Esc-Arg $m))) 'last commit message changed')
}

function Invoke-GitUndoCommit($p) {
    $info = Get-GitInfo $p
    if ($info.NoCommits) { return '! no commits yet' }
    Clear-Host
    Write-Host ' Undo the last commit but KEEP all its changes staged (git reset --soft HEAD~1).' -ForegroundColor Yellow
    if ($info.Upstream -and ($info.Ahead -eq 0)) { Write-Host ' [!] That commit is already pushed. Undoing it means a force push later.' -ForegroundColor Red }
    if (-not (Read-Confirm 'Undo the last commit?')) { return '' }
    return (Complete-Git (Invoke-Git $p @('reset', '--soft', 'HEAD~1')) 'last commit undone - changes are staged')
}

function Invoke-GitSquash($p) {
    $n = Read-Input 'Squash commits' 'how many of the latest commits?' @('They will be combined into one new commit.')
    if (-not $n) { return '' }
    if ($n -notmatch '^\d+$' -or [int]$n -lt 2) { return '! enter a number >= 2' }
    $m = Read-Input 'Squash commits' 'message for the combined commit'
    if (-not $m) { return '' }
    $r = Invoke-Git $p @('reset', '--soft', "HEAD~$n")
    if (-not $r.Ok) { return (Complete-Git $r '') }
    return (Complete-Git (Invoke-Git $p @('commit', '-m', (Esc-Arg $m))) "squashed the last $n commits")
}

function Get-FileDiffLines($p, $f) {
    if ($f.Kind -eq 'untracked') {
        $full = Join-Path $p.Path $f.Path
        if (Test-Path -LiteralPath $full -PathType Container) { return @("(untracked folder) $($f.Path)") + @(Get-ChildItem -LiteralPath $full -Recurse -File -Force | Select-Object -First 200 | ForEach-Object { '+ ' + $_.FullName.Substring($p.Path.Length + 1) }) }
        $lines = @(Get-Content -LiteralPath $full -TotalCount 3000 -ErrorAction SilentlyContinue | ForEach-Object { "+$_" })
        return @("== NEW FILE (untracked): $($f.Path) ==") + $lines
    }
    $out = @()
    if ($f.X -notin @(' ', '?')) { $out += '== STAGED (will be committed) =='; $out += (Invoke-Git $p @('diff', '--cached', '--', $f.Path)).Out }
    if ($f.Y -ne ' ')            { $out += ''; $out += '== NOT STAGED =='; $out += (Invoke-Git $p @('diff', '--', $f.Path)).Out }
    return $out
}

function Add-GitIgnoreLine($p, [string]$Pattern) {
    $gi = Join-Path $p.Path '.gitignore'
    $existing = @(); if (Test-Path -LiteralPath $gi) { $existing = @(Get-Content -LiteralPath $gi) }
    if ($existing -contains $Pattern) { return "already in .gitignore: $Pattern" }
    Add-Content -LiteralPath $gi -Value $Pattern
    return "added to .gitignore: $Pattern"
}

function Show-GitChanges($p) {
    $sel = 0; $off = 0; $flash = ''; $flashColor = 'Green'
    $info = Get-GitInfo $p
    try { [Console]::CursorVisible = $false } catch {}
    Clear-Host
    try {
        while ($true) {
            $files = @($info.Files)
            if ($sel -ge $files.Count) { $sel = [Math]::Max(0, $files.Count - 1) }
            $ws = Get-WinSize
            $vis = $ws.H - 9; if ($vis -lt 4) { $vis = 4 }
            if ($sel -lt $off) { $off = $sel }
            if ($sel -ge ($off + $vis)) { $off = $sel - $vis + 1 }
            try { [Console]::SetCursorPosition(0, 0) } catch { Clear-Host }
            Write-Host " Changes - $($p.Name)    branch: $($info.Branch)    staged $($info.Staged)  modified $($info.Modified)  untracked $($info.Untracked)  conflicts $($info.Conflicts)" -NoNewline -ForegroundColor Cyan; Write-Eol
            Write-Host ' two letters = [staged][not staged]   green = will be committed   red = not staged   ?? = new file   UU = conflict' -NoNewline -ForegroundColor DarkGray; Write-Eol
            Write-Host (' ' + ('-' * [Math]::Max(1, $ws.W - 3))) -NoNewline -ForegroundColor DarkGray; Write-Eol
            for ($n = 0; $n -lt $vis; $n++) {
                $ix = $off + $n
                if (($ix -lt $files.Count)) {
                    $f = $files[$ix]
                    $b = $ws.W - 2
                    if ($ix -eq $sel) { Write-Host '>' -NoNewline -ForegroundColor White } else { Write-Host ' ' -NoNewline }
                    Write-Host ' ' -NoNewline
                    if ($f.Kind -eq 'untracked') { Write-Host '??' -NoNewline -ForegroundColor Magenta }
                    elseif ($f.Kind -eq 'conflict') { Write-Host ($f.X + $f.Y) -NoNewline -ForegroundColor Yellow }
                    else {
                        $xc = 'DarkGray'; if ($f.X -ne ' ') { $xc = 'Green' }
                        $yc = 'DarkGray'; if ($f.Y -ne ' ') { $yc = 'Red' }
                        Write-Host $f.X -NoNewline -ForegroundColor $xc
                        Write-Host $f.Y -NoNewline -ForegroundColor $yc
                    }
                    $txt = $f.Path; if ($f.Orig) { $txt = "$($f.Orig) -> $($f.Path)" }
                    $c = 'Gray'; if ($ix -eq $sel) { $c = 'White' }
                    [void](Write-Seg ('  ' + $txt) $c ($b - 4))
                } elseif (($n -eq 0) -and ($files.Count -eq 0)) {
                    Write-Host '   working tree clean - nothing to commit' -NoNewline -ForegroundColor Green
                }
                Write-Eol
            }
            Write-Host (' ' + ('-' * [Math]::Max(1, $ws.W - 3))) -NoNewline -ForegroundColor DarkGray; Write-Eol
            Write-Host ' Space stage/unstage   A stage all   U unstage all   Enter/D diff   P pick hunks   X discard   C commit' -NoNewline -ForegroundColor DarkGray; Write-Eol
            Write-Host ' H file history   B blame   E open file   I ignore   R refresh   Backspace back   Esc exit' -NoNewline -ForegroundColor DarkGray; Write-Eol
            if ($flash) { Write-Host (Limit-Text " $flash" ($ws.W - 2)) -NoNewline -ForegroundColor $flashColor }
            Write-Eol
            $k = Read-KeyWait
            if ($null -eq $k) { continue }
            $flash = ''; $msg = ''; $reload = $false
            $f = $null; if ($files.Count -gt 0) { $f = $files[$sel] }
            switch ($k.Key) {
                'UpArrow'   { if ($sel -gt 0) { $sel-- } }
                'DownArrow' { if ($sel -lt ($files.Count - 1)) { $sel++ } }
                'PageUp'    { $sel = [Math]::Max(0, $sel - 10) }
                'PageDown'  { $sel = [Math]::Max(0, [Math]::Min($files.Count - 1, $sel + 10)) }
                'Home'      { $sel = 0 }
                'End'       { $sel = [Math]::Max(0, $files.Count - 1) }
                'R'         { $reload = $true }
                'Spacebar' {
                    if ($f) {
                        if (($f.Kind -eq 'untracked') -or ($f.Kind -eq 'conflict') -or ($f.Y -ne ' ')) { $r = Invoke-Git $p @('add', '--', $f.Path) }
                        else { $r = Invoke-Git $p @('reset', '-q', '--', $f.Path) }
                        if (-not $r.Ok) { $msg = Complete-Git $r '' }
                        $reload = $true
                    }
                }
                'A' { $r = Invoke-Git $p @('add', '-A'); $msg = Complete-Git $r 'staged everything'; $reload = $true }
                'U' { $r = Invoke-Git $p @('reset', '-q'); $msg = Complete-Git $r 'unstaged everything'; $reload = $true }
                'D' { if ($f) { Show-Pager "diff - $($f.Path)" (Get-FileDiffLines $p $f); Clear-Host } }
                'Enter' { if ($f) { Show-Pager "diff - $($f.Path)" (Get-FileDiffLines $p $f); Clear-Host } }
                'P' {
                    if ($f -and ($f.Kind -ne 'untracked')) { Clear-Host; [void](Invoke-GitLive $p @('add', '-p', '--', $f.Path)); $reload = $true; Clear-Host }
                    else { $msg = '! hunk picking works on tracked files - stage new files with Space' }
                }
                'X' {
                    if ($f) {
                        Clear-Host
                        Write-Host " Discard ALL local changes in '$($f.Path)'? This cannot be undone." -ForegroundColor Red
                        if (Read-Confirm 'Discard?') {
                            if ($f.Kind -eq 'untracked') { $r = Invoke-Git $p @('clean', '-fd', '--', $f.Path) }
                            else {
                                if ($f.X -notin @(' ', '?')) { [void](Invoke-Git $p @('reset', '-q', '--', $f.Path)) }
                                $r = Invoke-Git $p @('checkout', '--', $f.Path)
                            }
                            $msg = Complete-Git $r "discarded changes in $($f.Path)"
                            $reload = $true
                        }
                        Clear-Host
                    }
                }
                'C' { $msg = Invoke-GitCommit $p; $reload = $true; Clear-Host }
                'H' { if ($f) { Show-GitOutput $p "history of $($f.Path)" @('log', '--follow', '-p', '--date=short', '--format=commit %h  %ad  %an  %s', '--', $f.Path); Clear-Host } }
                'B' { if ($f -and ($f.Kind -ne 'untracked')) { Show-GitOutput $p "blame - $($f.Path)" @('blame', '-w', '--date=short', '--', $f.Path); Clear-Host } }
                'E' { if ($f) { try { Start-Process -FilePath (Join-Path $p.Path $f.Path) } catch { $msg = "! cannot open: $_" } } }
                'I' {
                    if ($f) {
                        $pat = '/' + $f.Path.Replace('\', '/')
                        $msg = Add-GitIgnoreLine $p $pat
                        if ($f.Kind -ne 'untracked') {
                            Clear-Host
                            if (Read-Confirm "'$($f.Path)' is already tracked - stop tracking it too (git rm --cached)?") { $msg = Complete-Git (Invoke-Git $p @('rm', '-r', '--cached', '--', $f.Path)) "ignored and untracked $($f.Path)" }
                            Clear-Host
                        }
                        $reload = $true
                    }
                }
                'Backspace' { return }
                'LeftArrow' { return }
                'Q'         { return }
                'Escape'    { [void](Exit-Tool) }
            }
            if ($msg) { $flash = $msg.TrimStart('!').Trim(); if ($msg.StartsWith('!')) { $flashColor = 'Red' } else { $flashColor = 'Green' } }
            if ($reload) { $info = Get-GitInfo $p; Clear-Host }
        }
    } finally {
        try { [Console]::CursorVisible = $true } catch {}
        Clear-Host
    }
}

function Show-GitStash($p) {
    $flash = ''; $last = -1
    while ($true) {
        $r = Invoke-Git $p @('stash', 'list', '--format=%gd|%cr|%gs')
        $entries = @($r.Out | Where-Object { $_ -match '\|' })
        $items = @(@{ label = 'New stash...'; enabled = $true; color = 'Green'; note = 'put your uncommitted work aside (git stash push)' })
        foreach ($e in $entries) {
            $f = $e.Split('|')
            $items += @{ label = $f[0]; enabled = $true; color = 'DarkGray'; note = ("$($f[1])  " + (@($f | Select-Object -Skip 2) -join '|')) }
        }
        $fc = if ($flash.StartsWith('!')) { 'Red' } else { 'Green' }
        $ix = Show-Choice -Title "Stash - $($p.Name)" -Items $items -Flash $flash.TrimStart('!').Trim() -FlashColor $fc -InitialIndex $last
        if ($null -eq $ix) { return $flash }
        $last = $ix; $flash = ''
        if ($ix -eq 0) {
            $m = Read-Input 'New stash' 'message (optional)'
            if ($null -eq $m) { continue }
            Clear-Host
            $a = @('stash', 'push')
            if (Read-Confirm 'Include untracked (new) files?') { $a += '-u' }
            if ($m) { $a += @('-m', (Esc-Arg $m)) }
            $flash = Complete-Git (Invoke-Git $p $a) 'changes stashed'
            continue
        }
        $name = $entries[$ix - 1].Split('|')[0]
        $acts = @(
            @{ label = 'Apply';  enabled = $true; color = 'DarkGray'; note = 'restore the changes, keep the stash' },
            @{ label = 'Pop';    enabled = $true; color = 'DarkGray'; note = 'restore the changes and drop the stash' },
            @{ label = 'Show';   enabled = $true; color = 'DarkGray'; note = 'see what is inside' },
            @{ label = 'Branch'; enabled = $true; color = 'DarkGray'; note = 'create a branch from it and apply' },
            @{ label = 'Drop';   enabled = $true; color = 'Red';      note = 'delete it' })
        $a = Show-Choice -Title "Stash $name" -Items $acts
        if ($null -eq $a) { continue }
        switch ($a) {
            0 { $flash = Complete-Git (Invoke-Git $p @('stash', 'apply', $name)) "applied $name" }
            1 { $flash = Complete-Git (Invoke-Git $p @('stash', 'pop', $name)) "popped $name" }
            2 { Show-GitOutput $p "stash $name" @('stash', 'show', '-p', '--stat', $name) }
            3 {
                $b = Read-Input 'Branch from stash' 'new branch name'
                if ($b) { $flash = Complete-Git (Invoke-Git $p @('stash', 'branch', $b, $name)) "created $b from $name" }
            }
            4 { Clear-Host; if (Read-Confirm "Drop $name for good?") { $flash = Complete-Git (Invoke-Git $p @('stash', 'drop', $name)) "dropped $name" } }
        }
    }
}

function Show-GitTags($p) {
    $flash = ''; $last = -1
    while ($true) {
        $r = Invoke-Git $p @('for-each-ref', '--sort=-creatordate', '--format=%(refname:short)|%(objectname:short)|%(creatordate:relative)|%(subject)', 'refs/tags')
        $tags = @($r.Out | Where-Object { $_ -match '\|' })
        $items = @(
            @{ label = 'New tag at HEAD...'; enabled = $true; color = 'Green'; note = 'mark the current commit' },
            @{ label = 'Push all tags';      enabled = $true; color = 'Green'; note = 'git push --tags' })
        foreach ($t in $tags) { $f = $t.Split('|'); $items += @{ label = $f[0]; enabled = $true; color = 'DarkGray'; note = "$($f[1])  $($f[2])  $($f[3])" } }
        $fc = if ($flash.StartsWith('!')) { 'Red' } else { 'Green' }
        $ix = Show-Choice -Title "Tags - $($p.Name)" -Items $items -Flash $flash.TrimStart('!').Trim() -FlashColor $fc -InitialIndex $last
        if ($null -eq $ix) { return $flash }
        $last = $ix; $flash = ''
        if ($ix -eq 0) {
            $n = Read-Input 'New tag' 'tag name' @('Example: v1.2.0')
            if (-not $n) { continue }
            $m = Read-Input "Tag $n" 'message (ENTER = lightweight tag)'
            if ($m) { $flash = Complete-Git (Invoke-Git $p @('tag', '-a', $n, '-m', (Esc-Arg $m))) "tag $n created" }
            else    { $flash = Complete-Git (Invoke-Git $p @('tag', $n)) "tag $n created" }
            continue
        }
        if ($ix -eq 1) {
            if (-not (Test-Online)) { $flash = Get-GitOfflineMsg 'pushing tags'; continue }
            Clear-Host
            $rm = Select-GitRemote $p 'Push tags to which remote?'
            if ($rm) { $code = Invoke-GitLive $p @('push', $rm, '--tags'); Pause-Key; $flash = if ($code -eq 0) { 'tags pushed' } else { "! push failed (exit $code)" } }
            continue
        }
        $name = $tags[$ix - 2].Split('|')[0]
        $acts = @(
            @{ label = 'Show';            enabled = $true; color = 'DarkGray'; note = 'details and diff' },
            @{ label = 'Checkout';        enabled = $true; color = 'DarkGray'; note = 'detached HEAD at the tag' },
            @{ label = 'Push';            enabled = $true; color = 'DarkGray'; note = 'publish this tag' },
            @{ label = 'Delete local';    enabled = $true; color = 'Red';      note = 'git tag -d' },
            @{ label = 'Delete on remote'; enabled = $true; color = 'Red';     note = 'git push --delete' })
        $a = Show-Choice -Title "Tag $name" -Items $acts
        if ($null -eq $a) { continue }
        switch ($a) {
            0 { Show-GitOutput $p "tag $name" @('show', '--stat', $name) }
            1 { $flash = Complete-Git (Invoke-Git $p @('checkout', $name)) "HEAD detached at $name" }
            2 {
                if (-not (Test-Online)) { $flash = Get-GitOfflineMsg 'pushing a tag' }
                else { Clear-Host; $rm = Select-GitRemote $p 'Push to which remote?'; if ($rm) { $code = Invoke-GitLive $p @('push', $rm, $name); Pause-Key; $flash = if ($code -eq 0) { "pushed $name" } else { "! push failed (exit $code)" } } }
            }
            3 { Clear-Host; if (Read-Confirm "Delete local tag $name?") { $flash = Complete-Git (Invoke-Git $p @('tag', '-d', $name)) "deleted tag $name" } }
            4 {
                if (-not (Test-Online)) { $flash = Get-GitOfflineMsg 'deleting a remote tag' }
                else { Clear-Host; $rm = Select-GitRemote $p 'Delete the tag on which remote?'; if ($rm -and (Read-Confirm "Delete $name on $rm?")) { $flash = Complete-Git (Invoke-Git $p @('push', $rm, '--delete', $name)) "deleted $name on $rm" } }
            }
        }
    }
}

function Show-GitRemotes($p) {
    $flash = ''; $last = -1
    while ($true) {
        $names = @(Get-RemoteNames $p)
        $items = @(@{ label = 'Add remote...'; enabled = $true; color = 'Green'; note = 'connect this project to GitHub / any git server' })
        foreach ($n in $names) { $items += @{ label = $n; enabled = $true; color = 'DarkGray'; note = ((Invoke-Git $p @('remote', 'get-url', $n)).Out | Select-Object -First 1) } }
        $fc = if ($flash.StartsWith('!')) { 'Red' } else { 'Green' }
        $ix = Show-Choice -Title "Remotes - $($p.Name)" -Items $items -Flash $flash.TrimStart('!').Trim() -FlashColor $fc -InitialIndex $last
        if ($null -eq $ix) { return $flash }
        $last = $ix; $flash = ''
        if ($ix -eq 0) {
            $n = Read-Input 'Add remote' 'name' @('Usually "origin".')
            if (-not $n) { continue }
            $u = Read-Input "Add remote $n" 'url' @('Example: https://github.com/you/your-repo.git')
            if (-not $u) { continue }
            $flash = Complete-Git (Invoke-Git $p @('remote', 'add', $n, $u)) "remote $n added"
            continue
        }
        $name = $names[$ix - 1]
        $acts = @(
            @{ label = 'Fetch';           enabled = $true; color = 'DarkGray'; note = 'download its branches' },
            @{ label = 'Test connection'; enabled = $true; color = 'DarkGray'; note = 'git ls-remote' },
            @{ label = 'Change URL';      enabled = $true; color = 'DarkGray'; note = 'git remote set-url' },
            @{ label = 'Rename';          enabled = $true; color = 'DarkGray'; note = 'git remote rename' },
            @{ label = 'Remove';          enabled = $true; color = 'Red';      note = 'git remote remove' })
        $a = Show-Choice -Title "Remote $name" -Items $acts
        if ($null -eq $a) { continue }
        switch ($a) {
            0 {
                if (-not (Test-Online)) { $flash = Get-GitOfflineMsg 'fetch' }
                else { Clear-Host; $code = Invoke-GitLive $p @('fetch', $name, '--prune'); Pause-Key; $flash = if ($code -eq 0) { "fetched $name" } else { "! fetch failed (exit $code)" } }
            }
            1 {
                if (-not (Test-Online)) { $flash = Get-GitOfflineMsg 'testing the connection' }
                else { $r = Invoke-Git $p @('ls-remote', '--heads', $name); if ($r.Ok) { $flash = "connection OK - $(@($r.Out).Count) branch(es) on $name" } else { $flash = Complete-Git $r '' } }
            }
            2 { $u = Read-Input "URL of $name" 'new url'; if ($u) { $flash = Complete-Git (Invoke-Git $p @('remote', 'set-url', $name, $u)) "url of $name updated" } }
            3 { $u = Read-Input "Rename $name" 'new name'; if ($u) { $flash = Complete-Git (Invoke-Git $p @('remote', 'rename', $name, $u)) "renamed to $u" } }
            4 { Clear-Host; if (Read-Confirm "Remove remote $name?") { $flash = Complete-Git (Invoke-Git $p @('remote', 'remove', $name)) "removed $name" } }
        }
    }
}

function Show-GitConflicts($p) {
    $flash = ''; $last = -1
    while ($true) {
        $info = Get-GitInfo $p
        $conf = @($info.Files | Where-Object { $_.Kind -eq 'conflict' })
        $items = @(); $acts = @()
        foreach ($f in $conf) {
            $cnt = 0
            try { $cnt = @(Select-String -LiteralPath (Join-Path $p.Path $f.Path) -Pattern '^<<<<<<< ' -ErrorAction SilentlyContinue).Count } catch {}
            $items += @{ label = $f.Path; enabled = $true; color = 'Yellow'; note = "$($f.X)$($f.Y)   $cnt conflict block(s)" }; $acts += "file:$($f.Path)"
        }
        if ($info.State) {
            $items += @{ label = "Continue the $($info.State)"; enabled = ($conf.Count -eq 0); color = 'Green'; note = if ($conf.Count -eq 0) { "git $($info.State) --continue" } else { 'resolve all files first' } }; $acts += 'continue'
            $items += @{ label = "Abort the $($info.State)";    enabled = $true; color = 'Red'; note = "git $($info.State) --abort  (go back to before it started)" }; $acts += 'abort'
        } elseif ($conf.Count -eq 0) {
            $items += @{ label = 'Nothing to resolve'; enabled = $false; color = 'DarkGray'; note = 'no conflicts and no merge/rebase in progress' }; $acts += 'none'
        } else {
            $items += @{ label = 'Commit the resolution'; enabled = $false; color = 'DarkGray'; note = 'after marking all files resolved, use Commit' }; $acts += 'none'
        }
        $sub = "state: $(if ($info.State) { $info.State } else { 'none' })   conflicted files: $($conf.Count)   (during a rebase OURS/THEIRS are swapped)"
        $fc = if ($flash.StartsWith('!')) { 'Red' } else { 'Green' }
        $ix = Show-Choice -Title "Resolve conflicts - $($p.Name)" -Subtitle $sub -Items $items -Flash $flash.TrimStart('!').Trim() -FlashColor $fc -InitialIndex $last
        if ($null -eq $ix) { return $flash }
        $last = $ix; $flash = ''
        $act = $acts[$ix]
        if ($act -eq 'continue') { $flash = Complete-Git (Invoke-Git $p @($info.State, '--continue')) "$($info.State) continued"; continue }
        if ($act -eq 'abort') { Clear-Host; if (Read-Confirm "Abort the $($info.State)?") { $flash = Complete-Git (Invoke-Git $p @($info.State, '--abort')) "$($info.State) aborted" }; continue }
        if ($act.StartsWith('file:')) {
            $path = $act.Substring(5)
            $fa = @(
                @{ label = 'Open in editor';       enabled = $true; color = 'DarkGray'; note = 'fix the <<<<<<< ======= >>>>>>> blocks by hand' },
                @{ label = 'Show the conflict';    enabled = $true; color = 'DarkGray'; note = 'git diff' },
                @{ label = 'Take OURS';            enabled = $true; color = 'DarkGray'; note = 'keep the current-branch version of the whole file' },
                @{ label = 'Take THEIRS';          enabled = $true; color = 'DarkGray'; note = 'keep the incoming version of the whole file' },
                @{ label = 'Mark as resolved';     enabled = $true; color = 'Green';    note = 'git add (after you edited it)' })
            $a = Show-Choice -Title "Conflict: $path" -Items $fa
            if ($null -eq $a) { continue }
            switch ($a) {
                0 { try { Start-Process -FilePath (Join-Path $p.Path $path); $flash = 'opened - save the file, then Mark as resolved' } catch { $flash = "! cannot open: $_" } }
                1 { Show-GitOutput $p "conflict - $path" @('diff', '--', $path) }
                2 { $r = Invoke-Git $p @('checkout', '--ours', '--', $path); if ($r.Ok) { $r = Invoke-Git $p @('add', '--', $path) }; $flash = Complete-Git $r "kept OURS for $path" }
                3 { $r = Invoke-Git $p @('checkout', '--theirs', '--', $path); if ($r.Ok) { $r = Invoke-Git $p @('add', '--', $path) }; $flash = Complete-Git $r "kept THEIRS for $path" }
                4 { $flash = Complete-Git (Invoke-Git $p @('add', '--', $path)) "$path marked as resolved" }
            }
        }
    }
}

$script:LaravelIgnore = @(
    '/vendor', '/node_modules', '/public/build', '/public/hot', '/public/storage', '/storage/*.key', '/storage/pail',
    '.env', '.env.backup', '.env.production', '.phpunit.result.cache', 'Homestead.json', 'Homestead.yaml', 'auth.json',
    'npm-debug.log', 'yarn-error.log', '/.fleet', '/.idea', '/.vscode', '/.nova', '/.zed')

function Show-GitIgnore($p) {
    $flash = ''; $last = -1
    while ($true) {
        $gi = Join-Path $p.Path '.gitignore'
        $has = Test-Path -LiteralPath $gi
        $items = @(
            @{ label = 'View .gitignore';              enabled = $has;  color = 'DarkGray'; note = if ($has) { "$(@(Get-Content -LiteralPath $gi).Count) lines" } else { 'file does not exist yet' } },
            @{ label = 'Add a pattern...';             enabled = $true; color = 'DarkGray'; note = 'e.g. /storage/app/backups   or   *.log' },
            @{ label = 'Create Laravel .gitignore';    enabled = (-not $has); color = 'Green'; note = 'vendor, node_modules, .env, build output ...' },
            @{ label = 'Stop tracking a path...';      enabled = $true; color = 'Yellow'; note = 'git rm --cached  (file stays on disk)' },
            @{ label = 'Check why a path is ignored...'; enabled = $true; color = 'DarkGray'; note = 'git check-ignore -v' })
        $fc = if ($flash.StartsWith('!')) { 'Red' } else { 'Green' }
        $ix = Show-Choice -Title ".gitignore - $($p.Name)" -Items $items -Flash $flash.TrimStart('!').Trim() -FlashColor $fc -InitialIndex $last
        if ($null -eq $ix) { return $flash }
        $last = $ix; $flash = ''
        switch ($ix) {
            0 { Show-Pager '.gitignore' @(Get-Content -LiteralPath $gi) }
            1 { $v = Read-Input 'Add to .gitignore' 'pattern'; if ($v) { $flash = Add-GitIgnoreLine $p $v } }
            2 { Set-Content -LiteralPath $gi -Value $script:LaravelIgnore -Encoding ASCII; $flash = 'Laravel .gitignore created' }
            3 {
                $v = Read-Input 'Stop tracking' 'path (relative to the project)' @('The file stays on disk but is removed from git. Add it to .gitignore too.')
                if ($v) { $flash = Complete-Git (Invoke-Git $p @('rm', '-r', '--cached', '--', $v)) "no longer tracking $v" }
            }
            4 {
                $v = Read-Input 'Why ignored?' 'path'
                if ($v) { $r = Invoke-Git $p @('check-ignore', '-v', '--', $v); if ($r.Ok) { $flash = ($r.Out | Select-Object -First 1) } else { $flash = "not ignored: $v" } }
            }
        }
    }
}

function Invoke-GitInit($p) {
    $r = Invoke-Git $p @('init', '-b', 'main')
    if (-not $r.Ok) {
        $r = Invoke-Git $p @('init')
        if ($r.Ok) { [void](Invoke-Git $p @('symbolic-ref', 'HEAD', 'refs/heads/main')) }
    }
    return $r
}

function Invoke-GitQuickStart($p) {
    Clear-Host
    Write-Host ' Quick start: git init -> .gitignore -> first commit -> (optional) GitHub repository' -ForegroundColor Cyan
    if (-not (Test-GitRepo $p)) {
        $r = Invoke-GitInit $p
        if (-not $r.Ok) { return (Complete-Git $r '') }
        Write-Host '  [ok] repository created' -ForegroundColor Green
    }
    $gi = Join-Path $p.Path '.gitignore'
    if (-not (Test-Path -LiteralPath $gi)) { Set-Content -LiteralPath $gi -Value $script:LaravelIgnore -Encoding ASCII; Write-Host '  [ok] Laravel .gitignore created' -ForegroundColor Green }
    if (-not (Test-GitIdentity $p)) { [void](Edit-GitIdentity $p); Clear-Host }
    if (-not (Test-GitIdentity $p)) { return '! set your name and email first' }
    $a = Invoke-Git $p @('add', '-A')
    if (-not $a.Ok) { return (Complete-Git $a '') }
    $c = Invoke-Git $p @('commit', '-m', 'Initial commit')
    if (-not $c.Ok -and $c.Text -notmatch 'nothing to commit') { return (Complete-Git $c '') }
    Write-Host '  [ok] first commit made' -ForegroundColor Green
    if ((Test-GhInstalled) -and (Read-Confirm 'Create a GitHub repository for it now?')) { return (New-GitHubRepo $p) }
    return 'repository ready - add a remote or create a GitHub repo, then Push'
}

function Show-GitDanger($p) {
    $flash = ''
    while ($true) {
        $items = @(
            @{ label = 'Discard ALL local changes';       enabled = $true; color = 'Red'; note = 'git reset --hard HEAD  (tracked files)' },
            @{ label = 'Remove ALL untracked files';      enabled = $true; color = 'Red'; note = 'git clean -fd  (you see a preview first)' },
            @{ label = 'Make branch identical to remote'; enabled = $true; color = 'Red'; note = 'fetch + git reset --hard @{u}' },
            @{ label = 'Force push (with lease)';         enabled = $true; color = 'Red'; note = 'git push --force-with-lease' },
            @{ label = 'Delete merged local branches';    enabled = $true; color = 'Yellow'; note = 'keeps main / master / develop / current' })
        $fc = if ($flash.StartsWith('!')) { 'Red' } else { 'Green' }
        $ix = Show-Choice -Title "Danger zone - $($p.Name)" -Subtitle 'These can lose work.' -Items $items -Flash $flash.TrimStart('!').Trim() -FlashColor $fc
        if ($null -eq $ix) { return $flash }
        $flash = ''
        switch ($ix) {
            0 { Clear-Host; Write-Host ' Every uncommitted change to tracked files will be lost.' -ForegroundColor Red; if (Read-TypedConfirm 'discard') { $flash = Complete-Git (Invoke-Git $p @('reset', '--hard', 'HEAD')) 'all local changes discarded' } }
            1 {
                $pv = Invoke-Git $p @('clean', '-nd')
                if (@($pv.Out | Where-Object { $_.Trim() }).Count -eq 0) { $flash = 'no untracked files' }
                else {
                    Show-Pager 'These untracked files/folders would be deleted' $pv.Out
                    Clear-Host; if (Read-TypedConfirm 'clean') { $flash = Complete-Git (Invoke-Git $p @('clean', '-fd')) 'untracked files removed' }
                }
            }
            2 {
                $info = Get-GitInfo $p
                if (-not $info.Upstream) { $flash = '! this branch has no upstream' }
                else {
                    Clear-Host; Write-Host " Local commits and changes will be replaced by $($info.Upstream)." -ForegroundColor Red
                    if (Read-TypedConfirm 'reset') {
                        if (Test-Online) { [void](Invoke-Git $p @('fetch', '--all', '--prune')) }
                        $flash = Complete-Git (Invoke-Git $p @('reset', '--hard', '@{u}')) "branch now equals $($info.Upstream)"
                    }
                }
            }
            3 { Clear-Host; Write-Host ' Overwrites the remote branch with yours (refuses if someone pushed meanwhile).' -ForegroundColor Red; if (Read-TypedConfirm 'force') { $flash = Invoke-GitPush $p @('--force-with-lease') } }
            4 {
                $cur = ((Invoke-Git $p @('symbolic-ref', '--short', '-q', 'HEAD')).Out | Select-Object -First 1)
                $m = @((Invoke-Git $p @('branch', '--merged')).Out | ForEach-Object { $_.Trim('* ').Trim() } | Where-Object { $_ -and ($_ -notin @($cur, 'main', 'master', 'develop')) -and ($_ -notmatch '^\(') })
                if ($m.Count -eq 0) { $flash = 'no merged branches to delete' }
                else {
                    Clear-Host; Write-Host ' Will delete:' -ForegroundColor Yellow; foreach ($b in $m) { Write-Host "   $b" -ForegroundColor Yellow }
                    if (Read-Confirm 'Delete these branches?') { foreach ($b in $m) { [void](Invoke-Git $p @('branch', '-d', $b)) }; $flash = "deleted $($m.Count) merged branch(es)" }
                }
            }
        }
    }
}

function Show-GitSync($p) {
    $flash = ''; $last = -1
    while ($true) {
        $net = ''
        if (-not (Test-Online)) { $net = 'OFFLINE - fetch/pull need internet, Push is queued' }
        $items = @(
            @{ label = 'Fetch';                       enabled = $true; color = 'DarkGray'; note = 'git fetch --all --prune' },
            @{ label = 'Pull (merge)';                enabled = $true; color = 'DarkGray'; note = 'git pull --no-edit' },
            @{ label = 'Pull (rebase)';               enabled = $true; color = 'DarkGray'; note = 'git pull --rebase - linear history' },
            @{ label = 'Pull (fast-forward only)';    enabled = $true; color = 'DarkGray'; note = 'git pull --ff-only - refuses to merge' },
            @{ label = 'Push';                        enabled = $true; color = 'DarkGray'; note = 'git push (sets upstream the first time)' },
            @{ label = 'Push tags';                   enabled = $true; color = 'DarkGray'; note = 'git push --tags' },
            @{ label = 'Delete a remote branch...';   enabled = $true; color = 'Red';      note = 'git push --delete' })
        $fc = if ($flash.StartsWith('!')) { 'Red' } else { 'Green' }
        $ix = Show-Choice -Title "Sync - $($p.Name)" -Subtitle $net -Items $items -Flash $flash.TrimStart('!').Trim() -FlashColor $fc -InitialIndex $last
        if ($null -eq $ix) { return $flash }
        $last = $ix
        switch ($ix) {
            0 { $flash = Invoke-GitFetch $p }
            1 { $flash = Invoke-GitPull $p '' }
            2 { $flash = Invoke-GitPull $p 'rebase' }
            3 { $flash = Invoke-GitPull $p 'ff-only' }
            4 { $flash = Invoke-GitPush $p }
            5 {
                if (-not (Test-Online)) { $flash = Get-GitOfflineMsg 'pushing tags' }
                else { Clear-Host; $rm = Select-GitRemote $p 'Push tags to which remote?'; if ($rm) { $code = Invoke-GitLive $p @('push', $rm, '--tags'); Pause-Key; $flash = if ($code -eq 0) { 'tags pushed' } else { "! push failed (exit $code)" } } }
            }
            6 {
                if (-not (Test-Online)) { $flash = Get-GitOfflineMsg 'deleting a remote branch' }
                else {
                    $rm = Select-GitRemote $p 'Delete a branch on which remote?'
                    if ($rm) {
                        $b = Read-Input 'Delete remote branch' 'branch name'
                        if ($b) { Clear-Host; if (Read-TypedConfirm 'delete') { $flash = Complete-Git (Invoke-Git $p @('push', $rm, '--delete', $b)) "deleted $b on $rm" } }
                    }
                }
            }
        }
    }
}

function Show-GitReflog($p) {
    $flash = ''; $last = -1
    while ($true) {
        $r = Invoke-Git $p @('reflog', '--format=%gd|%h|%gs|%cr', '-n', '80')
        $entries = @($r.Out | Where-Object { $_ -match '\|' })
        if ($entries.Count -eq 0) { Show-Pager 'Reflog' @('The reflog is empty.'); return $flash }
        $items = @()
        foreach ($e in $entries) { $f = $e.Split('|'); $items += @{ label = "$($f[0])  $($f[1])"; enabled = $true; color = 'DarkGray'; note = "$($f[3])   $($f[2])" } }
        $fc = if ($flash.StartsWith('!')) { 'Red' } else { 'Green' }
        $ix = Show-Choice -Title "Reflog - $($p.Name)" -Subtitle 'Every place HEAD has been. Pick one to go back to it (reset / checkout / branch).' -Items $items -Flash $flash.TrimStart('!').Trim() -FlashColor $fc -InitialIndex $last
        if ($null -eq $ix) { return $flash }
        $last = $ix
        $flash = Show-GitCommitActions $p $entries[$ix].Split('|')[1]
    }
}

function Show-GitConfig($p) {
    $flash = ''; $last = -1
    while ($true) {
        $n = ((Invoke-Git $p @('config', 'user.name')).Out | Select-Object -First 1)
        $e = ((Invoke-Git $p @('config', 'user.email')).Out | Select-Object -First 1)
        $items = @(
            @{ label = 'Identity (name / email)';  enabled = $true; color = 'DarkGray'; note = "$n <$e>" },
            @{ label = 'Pull behaviour';           enabled = $true; color = 'DarkGray'; note = 'merge / rebase / fast-forward only' },
            @{ label = 'Use Windows credential manager'; enabled = $true; color = 'DarkGray'; note = 'git config --global credential.helper manager' },
            @{ label = 'Default branch name = main'; enabled = $true; color = 'DarkGray'; note = 'git config --global init.defaultBranch main' },
            @{ label = 'Show all settings';        enabled = $true; color = 'DarkGray'; note = 'git config --list --show-origin' })
        $fc = if ($flash.StartsWith('!')) { 'Red' } else { 'Green' }
        $ix = Show-Choice -Title "Identity & config - $($p.Name)" -Items $items -Flash $flash.TrimStart('!').Trim() -FlashColor $fc -InitialIndex $last
        if ($null -eq $ix) { return $flash }
        $last = $ix
        switch ($ix) {
            0 { $flash = Edit-GitIdentity $p }
            1 {
                $pi = @(
                    @{ label = 'Merge';            enabled = $true; color = 'DarkGray'; note = 'git config pull.rebase false (default)' },
                    @{ label = 'Rebase';           enabled = $true; color = 'DarkGray'; note = 'git config pull.rebase true - linear history' },
                    @{ label = 'Fast-forward only'; enabled = $true; color = 'DarkGray'; note = 'git config pull.ff only - never creates merge commits' })
                $m = Show-Choice -Title 'Pull behaviour (this repository)' -Items $pi
                if ($null -ne $m) {
                    switch ($m) {
                        0 { $flash = Complete-Git (Invoke-Git $p @('config', 'pull.rebase', 'false')) 'pull = merge' }
                        1 { $flash = Complete-Git (Invoke-Git $p @('config', 'pull.rebase', 'true')) 'pull = rebase' }
                        2 { $flash = Complete-Git (Invoke-Git $p @('config', 'pull.ff', 'only')) 'pull = fast-forward only' }
                    }
                }
            }
            2 { $flash = Complete-Git (Invoke-Git $p @('config', '--global', 'credential.helper', 'manager')) 'credential manager enabled' }
            3 { $flash = Complete-Git (Invoke-Git $p @('config', '--global', 'init.defaultBranch', 'main')) 'new repositories start on main' }
            4 { Show-GitOutput $p 'git config' @('config', '--list', '--show-origin') }
        }
    }
}

function Invoke-Gh($p, [string[]]$GhArgs) {
    $env:NO_COLOR = '1'; $env:GH_PROMPT_DISABLED = '1'; $env:GH_PAGER = 'cat'
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = $null; $code = 1
    Push-Location -LiteralPath $p.Path
    try { $out = & gh @GhArgs 2>&1; $code = $LASTEXITCODE } catch { $out = @("$_") } finally { Pop-Location; $ErrorActionPreference = $old }
    $lines = @($out | ForEach-Object { "$_" })
    $cmd = 'gh ' + ($GhArgs -join ' ')
    $script:GitLast = $cmd
    Write-Log "`$ $cmd -> exit $code" $p
    return [pscustomobject]@{ Ok = ($code -eq 0); Code = $code; Out = $lines; Text = ($lines -join "`n"); Cmd = $cmd }
}

function Invoke-GhLive($p, [string[]]$GhArgs) {
    Remove-Item Env:GH_PROMPT_DISABLED -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host " $ gh $($GhArgs -join ' ')" -ForegroundColor DarkCyan
    Write-Host ''
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $code = 1
    Push-Location -LiteralPath $p.Path
    try { & gh @GhArgs; $code = $LASTEXITCODE } finally { Pop-Location; $ErrorActionPreference = $old }
    Write-Log "`$ gh $($GhArgs -join ' ') -> exit $code" $p
    return $code
}

function Complete-Gh($r, [string]$OkMsg) {
    if ($r.Ok) { return "$OkMsg   [$($r.Cmd)]" }
    Show-Pager 'GitHub CLI reported a problem' (@("$ $($r.Cmd)", "exit code $($r.Code)", '') + $r.Out)
    $first = ($r.Out | Where-Object { $_.Trim() } | Select-Object -First 1)
    return "! $($r.Cmd) failed: $first"
}

function Get-GitHubSlug($info) {
    if ($info.Remote -match 'github\.com[:/]+([^/]+)/([^/]+?)(?:\.git)?/?$') { return "$($Matches[1])/$($Matches[2])" }
    return ''
}

function Open-Url([string]$Url) { try { Start-Process $Url } catch {} }

function New-GitHubRepo($p) {
    $info = Get-GitInfo $p
    if ($info.NoCommits) { return '! make the first commit before creating the repository' }
    if ($info.Remotes -contains 'origin') { return '! this project already has a remote called origin (see Remotes)' }
    $n = Read-Input 'Create GitHub repository' "repository name (ENTER = $($p.Name))" @('Use owner/name to create it inside an organization.')
    if ($null -eq $n) { return '' }
    if (-not $n) { $n = $p.Name }
    $vi = @(
        @{ label = 'Private'; enabled = $true; color = 'DarkGray'; note = 'only you and people you invite' },
        @{ label = 'Public';  enabled = $true; color = 'Yellow';   note = 'anyone on the internet can see the code' })
    $v = Show-Choice -Title "Visibility of '$n'" -Items $vi
    if ($null -eq $v) { return '' }
    if (-not (Test-Online)) {
        $vis = 'private'; if ($v -eq 1) { $vis = 'public' }
        Add-GitPendingJob @{ type = 'create-repo'; path = $p.Path; name = $n; visibility = $vis }
        return "OFFLINE - '$n' ($vis) will be created on GitHub and pushed automatically when the tool opens with internet"
    }
    $d = Read-Input 'Create GitHub repository' 'description (optional)'
    $a = @('repo', 'create', $n, $(if ($v -eq 0) { '--private' } else { '--public' }), '--source=.', '--remote=origin')
    if ($d) { $a += @('--description', (Esc-Arg $d)) }
    Clear-Host
    $code = Invoke-GhLive $p $a
    if ($code -ne 0) { Pause-Key; return "! gh repo create failed (exit $code)" }

    $br = Get-CurrentBranchName $p
    if (-not $br) { $br = 'HEAD' }
    $code = Invoke-GitLive $p @('push', '--progress', '-u', 'origin', $br)
    Pause-Key
    if ($code -eq 0) { return "GitHub repository $n created and pushed" }
    return "! repository $n was created but the push failed (exit $code) - use Push in the Git menu to retry"
}

function New-GitHubPR($p) {
    if (-not (Test-Online)) { return (Get-GitOfflineMsg 'creating a pull request') }
    $info = Get-GitInfo $p
    if ($info.Detached -or $info.NoCommits) { return '! switch to a branch with commits first' }
    if ((-not $info.Upstream) -or ($info.Ahead -gt 0)) {
        Clear-Host
        if (-not (Read-Confirm "Branch '$($info.Branch)' is not fully pushed. Push it first?")) { return '! cancelled' }
        $m = Invoke-GitPush $p
        if ($m.StartsWith('!')) { return $m }
    }
    $t = Read-Input 'New pull request' 'title (ENTER = fill from commits)' @("branch: $($info.Branch)")
    if ($null -eq $t) { return '' }
    $b = ''
    if ($t) { $b = Read-Input 'New pull request' 'description (optional)' }
    $base = Read-Input 'New pull request' 'base branch (ENTER = repository default)'
    $a = @('pr', 'create')
    if ($t) { $a += @('--title', (Esc-Arg $t)) }
    if ($b) { $a += @('--body', (Esc-Arg $b)) }
    if ((-not $t) -or (-not $b)) { $a += '--fill' }
    if ($base) { $a += @('--base', $base) }
    Clear-Host
    if (Read-Confirm 'Open it as a DRAFT?') { $a += '--draft' }
    $r = Invoke-Gh $p $a
    if (-not $r.Ok) { return (Complete-Gh $r '') }
    $url = ($r.Out | Where-Object { $_ -match '^https://' } | Select-Object -Last 1)
    if ($url -and (Read-Confirm 'Pull request created. Open it in the browser?')) { Open-Url $url }
    return "pull request created: $url"
}

function Show-GitHubPRs($p) {
    if (-not (Test-Online)) { return (Get-GitOfflineMsg 'pull requests') }
    $state = 'open'; $flash = ''; $last = -1
    while ($true) {
        $r = Invoke-Gh $p @('pr', 'list', '--state', $state, '--limit', '30', '--json', 'number,title,headRefName,author,isDraft')
        if (-not $r.Ok) { return (Complete-Gh $r '') }
        $prs = @(); try { $prs = @($r.Text | ConvertFrom-Json) } catch {}
        $items = @(@{ label = "State: $state"; enabled = $true; color = 'Cyan'; note = 'ENTER to switch open / merged / closed / all' })
        foreach ($x in $prs) {
            $dr = ''; if ($x.isDraft) { $dr = '  [draft]' }
            $items += @{ label = "#$($x.number)  $($x.title)"; enabled = $true; color = 'DarkGray'; note = "$($x.headRefName)  by $($x.author.login)$dr" }
        }
        $fc = if ($flash.StartsWith('!')) { 'Red' } else { 'Green' }
        $ix = Show-Choice -Title "Pull requests - $($p.Name)" -Subtitle "$($prs.Count) $state" -Items $items -Flash $flash.TrimStart('!').Trim() -FlashColor $fc -InitialIndex $last
        if ($null -eq $ix) { return $flash }
        $last = $ix; $flash = ''
        if ($ix -eq 0) { $state = @{ open = 'merged'; merged = 'closed'; closed = 'all'; all = 'open' }[$state]; continue }
        $num = [string]$prs[$ix - 1].number
        $acts = @(
            @{ label = 'View';              enabled = $true; color = 'DarkGray'; note = 'description, status, comments' },
            @{ label = 'Diff';              enabled = $true; color = 'DarkGray'; note = 'files changed' },
            @{ label = 'Checks (CI)';       enabled = $true; color = 'DarkGray'; note = 'status of the workflows' },
            @{ label = 'Checkout locally';  enabled = $true; color = 'Green';    note = 'gh pr checkout' },
            @{ label = 'Merge...';          enabled = $true; color = 'Green';    note = 'merge / squash / rebase' },
            @{ label = 'Approve';           enabled = $true; color = 'DarkGray'; note = 'gh pr review --approve' },
            @{ label = 'Comment...';        enabled = $true; color = 'DarkGray'; note = 'gh pr comment' },
            @{ label = 'Close';             enabled = $true; color = 'Red';      note = 'gh pr close' },
            @{ label = 'Open in browser';   enabled = $true; color = 'DarkGray'; note = 'gh pr view --web' })
        $a = Show-Choice -Title "Pull request #$num" -Subtitle ([string]$prs[$ix - 1].title) -Items $acts
        if ($null -eq $a) { continue }
        switch ($a) {
            0 { Show-Pager "PR #$num" (Invoke-Gh $p @('pr', 'view', $num, '--comments')).Out }
            1 { Show-Pager "PR #$num diff" (Invoke-Gh $p @('pr', 'diff', $num)).Out }
            2 { Show-Pager "PR #$num checks" (Invoke-Gh $p @('pr', 'checks', $num)).Out }
            3 { $flash = Complete-Gh (Invoke-Gh $p @('pr', 'checkout', $num)) "checked out PR #$num" }
            4 {
                $mi = @(
                    @{ label = 'Merge commit'; enabled = $true; color = 'DarkGray'; note = '--merge' },
                    @{ label = 'Squash';       enabled = $true; color = 'DarkGray'; note = '--squash - one commit' },
                    @{ label = 'Rebase';       enabled = $true; color = 'DarkGray'; note = '--rebase' })
                $m = Show-Choice -Title "Merge PR #$num" -Items $mi
                if ($null -ne $m) {
                    $ma = @('pr', 'merge', $num, @('--merge', '--squash', '--rebase')[$m])
                    Clear-Host
                    if (Read-Confirm 'Delete the branch after merging?') { $ma += '--delete-branch' }
                    $flash = Complete-Gh (Invoke-Gh $p $ma) "merged PR #$num"
                }
            }
            5 { $flash = Complete-Gh (Invoke-Gh $p @('pr', 'review', $num, '--approve')) "approved PR #$num" }
            6 { $c = Read-Input "Comment on PR #$num" 'comment'; if ($c) { $flash = Complete-Gh (Invoke-Gh $p @('pr', 'comment', $num, '--body', (Esc-Arg $c))) 'comment added' } }
            7 { Clear-Host; if (Read-Confirm "Close PR #$num without merging?") { $flash = Complete-Gh (Invoke-Gh $p @('pr', 'close', $num)) "closed PR #$num" } }
            8 { [void](Invoke-Gh $p @('pr', 'view', $num, '--web')) }
        }
    }
}

function Show-GitHubIssues($p) {
    if (-not (Test-Online)) { return (Get-GitOfflineMsg 'issues') }
    $state = 'open'; $flash = ''; $last = -1
    while ($true) {
        $r = Invoke-Gh $p @('issue', 'list', '--state', $state, '--limit', '30', '--json', 'number,title,author,labels')
        if (-not $r.Ok) { return (Complete-Gh $r '') }
        $iss = @(); try { $iss = @($r.Text | ConvertFrom-Json) } catch {}
        $items = @(
            @{ label = 'New issue...';    enabled = $true; color = 'Green'; note = 'gh issue create' },
            @{ label = "State: $state"; enabled = $true; color = 'Cyan';  note = 'ENTER to switch open / closed / all' })
        foreach ($x in $iss) {
            $lb = ''; if ($x.labels) { $lb = '  [' + (($x.labels | ForEach-Object { $_.name }) -join ', ') + ']' }
            $items += @{ label = "#$($x.number)  $($x.title)"; enabled = $true; color = 'DarkGray'; note = "by $($x.author.login)$lb" }
        }
        $fc = if ($flash.StartsWith('!')) { 'Red' } else { 'Green' }
        $ix = Show-Choice -Title "Issues - $($p.Name)" -Subtitle "$($iss.Count) $state" -Items $items -Flash $flash.TrimStart('!').Trim() -FlashColor $fc -InitialIndex $last
        if ($null -eq $ix) { return $flash }
        $last = $ix; $flash = ''
        if ($ix -eq 0) {
            $t = Read-Input 'New issue' 'title'
            if ($t) {
                $b = Read-Input 'New issue' 'description (optional)'
                $a = @('issue', 'create', '--title', (Esc-Arg $t), '--body', $(if ($b) { Esc-Arg $b } else { 'Created from Dev' }))
                $flash = Complete-Gh (Invoke-Gh $p $a) 'issue created'
            }
            continue
        }
        if ($ix -eq 1) { $state = @{ open = 'closed'; closed = 'all'; all = 'open' }[$state]; continue }
        $num = [string]$iss[$ix - 2].number
        $acts = @(
            @{ label = 'View';            enabled = $true; color = 'DarkGray'; note = 'description and comments' },
            @{ label = 'Comment...';      enabled = $true; color = 'DarkGray'; note = 'gh issue comment' },
            @{ label = 'Close';           enabled = $true; color = 'Red';      note = 'gh issue close' },
            @{ label = 'Reopen';          enabled = $true; color = 'Green';    note = 'gh issue reopen' },
            @{ label = 'Open in browser'; enabled = $true; color = 'DarkGray'; note = 'gh issue view --web' })
        $a = Show-Choice -Title "Issue #$num" -Subtitle ([string]$iss[$ix - 2].title) -Items $acts
        if ($null -eq $a) { continue }
        switch ($a) {
            0 { Show-Pager "Issue #$num" (Invoke-Gh $p @('issue', 'view', $num, '--comments')).Out }
            1 { $c = Read-Input "Comment on #$num" 'comment'; if ($c) { $flash = Complete-Gh (Invoke-Gh $p @('issue', 'comment', $num, '--body', (Esc-Arg $c))) 'comment added' } }
            2 { $flash = Complete-Gh (Invoke-Gh $p @('issue', 'close', $num)) "closed #$num" }
            3 { $flash = Complete-Gh (Invoke-Gh $p @('issue', 'reopen', $num)) "reopened #$num" }
            4 { [void](Invoke-Gh $p @('issue', 'view', $num, '--web')) }
        }
    }
}

function Show-GitHubRuns($p) {
    if (-not (Test-Online)) { return (Get-GitOfflineMsg 'GitHub Actions') }
    $flash = ''; $last = -1
    while ($true) {
        $r = Invoke-Gh $p @('run', 'list', '--limit', '15', '--json', 'databaseId,displayTitle,status,conclusion,workflowName,headBranch')
        if (-not $r.Ok) { return (Complete-Gh $r '') }
        $runs = @(); try { $runs = @($r.Text | ConvertFrom-Json) } catch {}
        if ($runs.Count -eq 0) { Show-Pager 'GitHub Actions' @('No workflow runs found.'); return $flash }
        $items = @()
        foreach ($x in $runs) {
            $st = $x.status; if ($x.conclusion) { $st = $x.conclusion }
            $col = 'DarkGray'; if ($st -eq 'success') { $col = 'Green' } elseif ($st -in @('failure', 'timed_out', 'startup_failure')) { $col = 'Red' } elseif ($st -in @('in_progress', 'queued')) { $col = 'Yellow' }
            $items += @{ label = "$($x.workflowName)"; enabled = $true; color = $col; note = "$st   $($x.headBranch)   $($x.displayTitle)" }
        }
        $fc = if ($flash.StartsWith('!')) { 'Red' } else { 'Green' }
        $ix = Show-Choice -Title "GitHub Actions - $($p.Name)" -Subtitle 'latest runs' -Items $items -Flash $flash.TrimStart('!').Trim() -FlashColor $fc -InitialIndex $last
        if ($null -eq $ix) { return $flash }
        $last = $ix; $flash = ''
        $id = [string]$runs[$ix].databaseId
        $acts = @(
            @{ label = 'View';              enabled = $true; color = 'DarkGray'; note = 'jobs and steps' },
            @{ label = 'Failed logs';       enabled = $true; color = 'DarkGray'; note = 'gh run view --log-failed' },
            @{ label = 'Re-run failed jobs'; enabled = $true; color = 'Green';   note = 'gh run rerun --failed' },
            @{ label = 'Open in browser';   enabled = $true; color = 'DarkGray'; note = 'gh run view --web' })
        $a = Show-Choice -Title "Run $id" -Subtitle ([string]$runs[$ix].displayTitle) -Items $acts
        if ($null -eq $a) { continue }
        switch ($a) {
            0 { Show-Pager "run $id" (Invoke-Gh $p @('run', 'view', $id)).Out }
            1 { Show-Pager "run $id - failed logs" (Invoke-Gh $p @('run', 'view', $id, '--log-failed')).Out }
            2 { $flash = Complete-Gh (Invoke-Gh $p @('run', 'rerun', $id, '--failed')) "re-running $id" }
            3 { [void](Invoke-Gh $p @('run', 'view', $id, '--web')) }
        }
    }
}

function Show-GitHubReleases($p) {
    if (-not (Test-Online)) { return (Get-GitOfflineMsg 'releases') }
    $r = Invoke-Gh $p @('release', 'list', '--limit', '20')
    $lines = @('Releases (newest first):', '') + $r.Out + @('', 'Press Backspace, then choose "New release" in the GitHub menu to publish one.')
    Show-Pager 'Releases' $lines
    return ''
}

function New-GitHubRelease($p) {
    if (-not (Test-Online)) { return (Get-GitOfflineMsg 'publishing a release') }
    $t = Read-Input 'New release' 'tag (e.g. v1.2.0)'
    if (-not $t) { return '' }
    $title = Read-Input 'New release' "title (ENTER = $t)"
    $notes = Read-Input 'New release' 'notes (ENTER = generate automatically)'
    $a = @('release', 'create', $t)
    if ($title) { $a += @('--title', (Esc-Arg $title)) }
    if ($notes) { $a += @('--notes', (Esc-Arg $notes)) } else { $a += '--generate-notes' }
    Clear-Host
    if (Read-Confirm 'Mark as pre-release?') { $a += '--prerelease' }
    return (Complete-Gh (Invoke-Gh $p $a) "release $t published")
}

function Show-GitHub($p0) {
    $name = $p0.Name; $flash = ''; $last = -1
    while ($true) {
        $p = New-Project $name
        $info = Get-GitInfo $p
        $slug = Get-GitHubSlug $info
        $hasGh = Test-GhInstalled
        $online = Test-Online
        $authed = $false; $user = ''
        if ($hasGh -and $online) {
            $au = Invoke-Gh $p @('auth', 'status')
            $authed = $au.Ok
            if ($authed -and ($au.Text -match '(?:account|as)\s+(\S+)')) { $user = $Matches[1] }
        }
        $ghState = 'installed - not logged in'
        if (-not $hasGh) { $ghState = 'not installed' }
        elseif (-not $online) { $ghState = 'OFFLINE - only "Create repository" (queued) works' }
        elseif ($authed) { $ghState = "logged in as $user" }
        $repoState = '(no remote yet)'
        if ($slug) { $repoState = "github.com/$slug" } elseif ($info.Remote) { $repoState = $info.Remote }
        $panel = @(('+' + ('-' * 66) + '+'),
                   ('| ' + (Limit-Text ("GH CLI   " + $ghState) 64).PadRight(64) + ' |'),
                   ('| ' + (Limit-Text ("REPO     " + $repoState) 64).PadRight(64) + ' |'),
                   ('+' + ('-' * 66) + '+'))
        $items = @(); $acts = @()
        $ready = $hasGh -and $authed -and $online
        if (-not $hasGh)      { $items += @{ label = 'Install GitHub CLI'; enabled = $true; color = 'Green'; note = 'winget install GitHub.cli (restart the tool afterwards)' }; $acts += 'install' }
        elseif ($online -and (-not $authed)) { $items += @{ label = 'Log in to GitHub'; enabled = $true; color = 'Green'; note = 'browser sign-in, also lets git push without passwords' }; $acts += 'login' }
        $items += @{ label = 'Create repository from this project'; enabled = ($ready -or (-not $online)); color = 'DarkGray'; note = if ($online) { 'gh repo create --source=. --push' } else { 'offline: queued, created automatically later' } }; $acts += 'create'
        $items += @{ label = 'Pull requests';        enabled = $ready; color = 'DarkGray'; note = 'list, review, merge, checkout' }; $acts += 'prs'
        $items += @{ label = 'New pull request';     enabled = $ready; color = 'DarkGray'; note = 'from the current branch' }; $acts += 'newpr'
        $items += @{ label = 'Issues';               enabled = $ready; color = 'DarkGray'; note = 'list, create, comment, close' }; $acts += 'issues'
        $items += @{ label = 'Actions (CI runs)';    enabled = $ready; color = 'DarkGray'; note = 'status, failed logs, re-run' }; $acts += 'runs'
        $items += @{ label = 'Releases';             enabled = $ready; color = 'DarkGray'; note = 'list' }; $acts += 'releases'
        $items += @{ label = 'New release';          enabled = $ready; color = 'DarkGray'; note = 'tag + notes' }; $acts += 'newrelease'
        $items += @{ label = 'Open repository in browser'; enabled = ([bool]$slug -and $online); color = 'DarkGray'; note = if ($slug) { "https://github.com/$slug" } else { 'no GitHub remote' } }; $acts += 'web'
        $items += @{ label = 'Open "new pull request" page'; enabled = ([bool]$slug -and $online -and (-not $info.Detached)); color = 'DarkGray'; note = 'works without the CLI' }; $acts += 'webpr'
        if ($authed) { $items += @{ label = 'Log out'; enabled = $true; color = 'Red'; note = 'gh auth logout' }; $acts += 'logout' }
        $fc = if ($flash.StartsWith('!')) { 'Red' } else { 'Green' }
        $ix = Show-Choice -Title "GitHub - $name" -Subtitle $p.Path -Items $items -Flash $flash.TrimStart('!').Trim() -FlashColor $fc -InitialIndex $last -Panel $panel
        if ($null -eq $ix) { return $flash }
        $last = $ix; $flash = ''
        switch ($acts[$ix]) {
            'install' { Clear-Host; Write-Host ' $ winget install --id GitHub.cli -e --source winget' -ForegroundColor DarkCyan; & winget install --id GitHub.cli -e --source winget | Out-Host; Pause-Key; $flash = 'if the install finished, close and reopen the tool so gh is found' }
            'login'   { Clear-Host; $code = Invoke-GhLive $p @('auth', 'login', '--hostname', 'github.com', '--git-protocol', 'https', '--web'); if ($code -eq 0) { [void](Invoke-GhLive $p @('auth', 'setup-git')) }; Pause-Key; $flash = if ($code -eq 0) { 'logged in to GitHub' } else { "! login failed (exit $code)" } }
            'logout'  { Clear-Host; $code = Invoke-GhLive $p @('auth', 'logout', '--hostname', 'github.com'); Pause-Key; $flash = 'logged out' }
            'create'  { $flash = New-GitHubRepo $p }
            'prs'     { $flash = Show-GitHubPRs $p }
            'newpr'   { $flash = New-GitHubPR $p }
            'issues'  { $flash = Show-GitHubIssues $p }
            'runs'    { $flash = Show-GitHubRuns $p }
            'releases' { $flash = Show-GitHubReleases $p }
            'newrelease' { $flash = New-GitHubRelease $p }
            'web'     { Open-Url "https://github.com/$slug" }
            'webpr'   { Open-Url "https://github.com/$slug/compare/$($info.Branch)?expand=1" }
        }
    }
}

function Invoke-GitClone {
    if (-not (Test-Online)) { return (Get-GitOfflineMsg 'cloning') }
    $url = Read-Input 'Clone a repository' 'repository URL' @('https://github.com/user/repo.git', 'or  user/repo  (needs the GitHub CLI)')
    if (-not $url) { return '' }
    $name = ($url.TrimEnd('/') -split '[/:]')[-1] -replace '\.git$', ''
    $n = Read-Input 'Clone a repository' "folder name inside www (ENTER = $name)"
    if ($null -eq $n) { return '' }
    if ($n) { $name = $n }
    $target = Join-Path (Get-WwwDir) $name
    if (Test-Path -LiteralPath $target) { return "! '$name' already exists in www" }
    Clear-Host
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $env:GIT_TERMINAL_PROMPT = '1'
    if (($url -match '^[\w.-]+/[\w.-]+$') -and (Test-GhInstalled)) {
        Write-Host " $ gh repo clone $url `"$target`"" -ForegroundColor DarkCyan
        & gh repo clone $url $target 2>&1 | ForEach-Object { Write-Host "$_" }
    } else {
        Write-Host " $ git clone $url `"$target`"" -ForegroundColor DarkCyan
        & git clone $url $target 2>&1 | ForEach-Object { Write-Host "$_" }
    }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    Pause-Key
    if ($code -eq 0) { return "cloned into www\$name - run 'composer install' and create .env if needed" }
    return "! clone failed (exit $code)"
}

function Show-GitMore($p) {
    $info = Get-GitInfo $p
    $none = $info.NoCommits
    $items = @(
        @{ label = 'Amend last commit'; enabled = (-not $none); color = 'DarkGray'; note = '' },
        @{ label = 'Undo last commit'; enabled = (-not $none); color = 'DarkGray'; note = 'keeps the changes' },
        @{ label = 'Squash last commits'; enabled = (-not $none); color = 'DarkGray'; note = '' },
        @{ label = 'Reflog'; enabled = (-not $none); color = 'DarkGray'; note = 'go back to anywhere' },
        @{ label = 'Fetch'; enabled = ($info.Remotes.Count -gt 0); color = 'DarkGray'; note = '' },
        @{ label = 'Sync options'; enabled = $true; color = 'DarkGray'; note = '' },
        @{ label = 'Remotes'; enabled = $true; color = 'DarkGray'; note = '' },
        @{ label = '.gitignore'; enabled = $true; color = 'DarkGray'; note = '' },
        @{ label = 'Identity and config'; enabled = $true; color = 'DarkGray'; note = '' },
        @{ label = 'Danger zone'; enabled = $true; color = 'Red'; note = 'hard reset, clean, force push' })
    $flash = ''; $last = -1
    while ($true) {
        $fc = 'Green'; if ($flash.StartsWith('!')) { $fc = 'Red' }
        $ix = Show-Choice -Title 'More' -Subtitle $p.Name -Items $items -Flash $flash.TrimStart('!').Trim() -FlashColor $fc -InitialIndex $last
        if ($null -eq $ix) { return $flash }
        $last = $ix; $flash = ''
        switch ($ix) {
            0 { $flash = Invoke-GitAmend $p }
            1 { $flash = Invoke-GitUndoCommit $p }
            2 { $flash = Invoke-GitSquash $p }
            3 { $flash = Show-GitReflog $p }
            4 { $flash = Invoke-GitFetch $p }
            5 { $flash = Show-GitSync $p }
            6 { $flash = Show-GitRemotes $p }
            7 { $flash = Show-GitIgnore $p }
            8 { $flash = Show-GitConfig $p }
            9 { $flash = Show-GitDanger $p }
        }
    }
}

function Invoke-GitMenu($p0) {
    if (-not (Test-GitInstalled)) {
        Clear-Host
        Write-Host ' Git is not installed (or not on PATH).' -ForegroundColor Red
        Write-Host ' Install it with:  winget install --id Git.Git -e' -ForegroundColor Yellow
        Write-Host ' then close and reopen the tool.' -ForegroundColor Yellow
        Pause-Key
        return ''
    }
    $name = $p0.Name; $flash = ''; $last = -1
    while ($true) {
        $p = New-Project $name
        $info = Get-GitInfo $p
        $online = Test-Online
        $panel = Get-GitPanel $p $info
        $items = @(); $acts = @()
        if (-not $info.Repo) {
            $items += @{ label = 'Quick start'; enabled = $true; color = 'Green'; note = 'init + Laravel .gitignore + first commit (+ GitHub repo)' }; $acts += 'quick'
            $items += @{ label = 'Initialize repository'; enabled = $true; color = 'DarkGray'; note = 'git init -b main' }; $acts += 'init'
            $items += @{ label = 'GitHub'; enabled = $true; color = 'DarkGray'; note = 'login / create repository' }; $acts += 'github'
        } else {
            $dirty = $info.Staged + $info.Modified + $info.Untracked
            $items += @{ label = 'Changes'; enabled = $true; color = 'Yellow'; note = "$dirty files" }; $acts += 'changes'
            $items += @{ label = 'Commit'; enabled = $true; color = 'Green'; note = "$($info.Staged) staged" }; $acts += 'commit'
            $pushNote = ''
            if ($info.Ahead -gt 0) { if ($online) { $pushNote = "$($info.Ahead) to push" } else { $pushNote = "$($info.Ahead) queued (offline)" } }
            elseif (-not $online) { $pushNote = 'offline, queued' }
            $items += @{ label = 'Push'; enabled = ($info.Remotes.Count -gt 0); color = 'DarkGray'; note = $pushNote }; $acts += 'push'
            $pullNote = ''
            if ($info.Behind -gt 0) { $pullNote = "$($info.Behind) waiting" }
            $items += @{ label = 'Pull'; enabled = ($info.Remotes.Count -gt 0); color = 'DarkGray'; note = $pullNote }; $acts += 'pull'
            $items += @{ label = 'Experiments'; enabled = (-not $info.NoCommits); color = 'Green'; note = 'try, then merge or discard' }; $acts += 'experiments'
            $items += @{ label = 'Versions'; enabled = (-not $info.NoCommits); color = 'Green'; note = 'branches, switch, side by side' }; $acts += 'versions'
            $items += @{ label = 'History tree'; enabled = (-not $info.NoCommits); color = 'Cyan'; note = '' }; $acts += 'graph'
            $items += @{ label = 'Branches'; enabled = $true; color = 'Cyan'; note = 'advanced' }; $acts += 'branches'
            $items += @{ label = 'Stash'; enabled = $true; color = 'DarkGray'; note = "$($info.Stashes) saved" }; $acts += 'stash'
            $items += @{ label = 'Tags'; enabled = $true; color = 'DarkGray'; note = '' }; $acts += 'tags'
            $items += @{ label = 'GitHub'; enabled = $true; color = 'Cyan'; note = '' }; $acts += 'github'
            if (($info.Conflicts -gt 0) -or [bool]$info.State) { $items += @{ label = 'Resolve conflicts'; enabled = $true; color = 'Red'; note = "$($info.Conflicts) files" }; $acts += 'conflicts' }
            $items += @{ label = 'More'; enabled = $true; color = 'DarkGray'; note = 'amend, undo, reflog, remotes, config' }; $acts += 'more'
        }
        $fc = if ($flash.StartsWith('!')) { 'Red' } else { 'Green' }
        $ix = Show-Choice -Title "Git - $name" -Subtitle $p.Path -Items $items -Flash $flash.TrimStart('!').Trim() -FlashColor $fc -InitialIndex $last -Panel $panel
        if ($null -eq $ix) { return $flash }
        $last = $ix; $flash = ''
        switch ($acts[$ix]) {
            'quick'    { $flash = Invoke-GitQuickStart $p }
            'init'     { $flash = Complete-Git (Invoke-GitInit $p) 'repository initialized' }
            'changes'  { Show-GitChanges $p }
            'commit'   { $flash = Invoke-GitCommit $p }
            'amend'    { $flash = Invoke-GitAmend $p }
            'undo'     { $flash = Invoke-GitUndoCommit $p }
            'squash'   { $flash = Invoke-GitSquash $p }
            'experiments' { $flash = Show-GitExperiments $p }
            'versions' { $flash = Show-GitVersions $p }
            'branches' { Show-GitBranches $p }
            'graph'    { Show-GitGraph $p '--all' }
            'reflog'   { $flash = Show-GitReflog $p }
            'fetch'    { $flash = Invoke-GitFetch $p }
            'pull'     { $flash = Invoke-GitPull $p '' }
            'push'     { $flash = Invoke-GitPush $p }
            'sync'     { $flash = Show-GitSync $p }
            'stash'    { $flash = Show-GitStash $p }
            'tags'     { $flash = Show-GitTags $p }
            'remotes'  { $flash = Show-GitRemotes $p }
            'conflicts' { $flash = Show-GitConflicts $p }
            'github'   { $flash = Show-GitHub $p }
            'ignore'   { $flash = Show-GitIgnore $p }
            'config'   { $flash = Show-GitConfig $p }
            'more'     { $flash = Show-GitMore $p }
        }
    }
}
