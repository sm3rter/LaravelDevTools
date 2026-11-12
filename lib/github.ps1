$script:StartDir       = (Get-Location).Path
$script:PendingFile    = Join-Path $script:DataDir 'pending.json'
$script:OutboxDir      = Join-Path $script:DataDir 'outbox'
$script:ReposCacheFile = Join-Path $script:DataDir 'repos-cache.json'
$script:GhAuthOk       = $false
$script:Repos          = @()
$script:ReposReload    = $true
$script:ReposCached    = $false
$script:AheadCache     = @{ t = [datetime]::MinValue; v = @() }

function Get-GhUser { return [string](Get-Cfg 'githubUser') }
function Get-RepoUrl([string]$Name) { return ('https://github.com/' + (Get-GhUser) + '/' + $Name + '.git') }

function Test-GhReady([bool]$Quiet = $false) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { if (-not $Quiet) { Clear-Host; Show-Fail 'git is not installed.  winget install Git.Git' }; return $false }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { if (-not $Quiet) { Clear-Host; Show-Fail 'GitHub CLI (gh) is not installed.  winget install GitHub.cli' }; return $false }
    if (-not (Test-Online)) { return $false }
    if ($script:GhAuthOk) { return $true }
    gh auth status *> $null
    if ($LASTEXITCODE -ne 0) {
        if ($Quiet) { return $false }
        Clear-Host
        Write-Host ''
        Write-Host '  You are not logged in to GitHub. Starting login...' -ForegroundColor Yellow
        gh auth login
        if ($LASTEXITCODE -ne 0) { return $false }
    }
    $script:GhAuthOk = $true
    return $true
}

function Get-PendingJobs {
    $o = Read-JsonFile $script:PendingFile
    if (-not $o) { return @() }
    return @($o)
}

function Save-PendingJobs($Jobs) {
    Write-JsonFile $script:PendingFile @($Jobs)
}

function Add-PendingJob([hashtable]$Job) {
    $Job['created'] = (Get-Date).ToString('s')
    $keep = @()
    foreach ($j in (Get-PendingJobs)) {
        $same = ($j.type -eq $Job['type']) -and ($j.path -eq $Job['path']) -and ($j.branch -eq $Job['branch']) -and ($j.name -eq $Job['name'])
        if (($Job['type'] -ne 'upload') -and $same) { continue }
        $keep += $j
    }
    $keep += [pscustomobject]$Job
    Save-PendingJobs $keep
    Write-Log ("queued offline job: " + $Job['type'])
}

function Get-JobText($j) {
    if ($j.type -eq 'push')        { return ('push ' + $j.branch + '  (' + (Split-Path $j.path -Leaf) + ')') }
    if ($j.type -eq 'create-repo') { return ('create GitHub repo ' + $j.name + ' and push  (' + (Split-Path $j.path -Leaf) + ')') }
    if ($j.type -eq 'newrepo')     { return ('create GitHub repo ' + $j.name) }
    if ($j.type -eq 'upload')      { return ('upload to ' + $j.repo + '  ' + $j.message) }
    return [string]$j.type
}

function Get-AheadBranches([string]$Path) {
    $res = @()
    $old = $env:GIT_TERMINAL_PROMPT; $env:GIT_TERMINAL_PROMPT = '0'
    $r = Invoke-Native 'git' @('-C', $Path, 'for-each-ref', '--format=%(refname:short)|%(upstream:short)|%(upstream:track)', 'refs/heads')
    $env:GIT_TERMINAL_PROMPT = $old
    if (-not $r.Ok) { return $res }
    foreach ($l in $r.Out) {
        $p = $l.Split('|')
        if ($p.Count -lt 3) { continue }
        if (-not $p[1]) { continue }
        if ($p[2] -match 'ahead') {
            $rem = ($p[1] -split '/')[0]
            $res += [pscustomobject]@{ Branch = $p[0]; Remote = $rem; Behind = ($p[2] -match 'behind') }
        }
    }
    return $res
}

function Get-UnpushedRepos([bool]$Force = $false) {
    if ((-not $Force) -and (((Get-Date) - $script:AheadCache.t).TotalSeconds -lt 30)) { return @($script:AheadCache.v) }
    $res = @()
    if (Get-Command git -ErrorAction SilentlyContinue) {
        foreach ($p in @(Get-Projects)) {
            if (-not (Test-Path -LiteralPath (Join-Path $p.Path '.git'))) { continue }
            $b = @(Get-AheadBranches $p.Path)
            if ($b.Count -gt 0) { $res += [pscustomobject]@{ Project = $p; Branches = $b } }
        }
    }
    $script:AheadCache.t = Get-Date
    $script:AheadCache.v = $res
    return $res
}

function Get-PendingCount {
    $n = @(Get-PendingJobs).Count
    foreach ($u in @(Get-UnpushedRepos)) { $n += $u.Branches.Count }
    return $n
}

function Push-OneBranch([string]$Path, [string]$Remote, [string]$Branch, [bool]$SetUpstream) {
    $a = @('-C', $Path, 'push')
    if ($SetUpstream) { $a += '-u' }
    $a += $Remote, $Branch
    $env:GIT_TERMINAL_PROMPT = '0'
    return (Invoke-Native 'git' $a)
}

function Invoke-SyncPending {
    $out = New-Object System.Collections.ArrayList
    if (-not (Test-Online -Force)) { Add-Line $out 'Still offline - nothing was sent.' 'Yellow'; return $out }
    if (-not (Test-GhReady $true)) { Add-Line $out 'GitHub CLI is missing or not logged in - open GitHub once and log in.' 'Yellow' }
    $remaining = @()
    foreach ($j in (Get-PendingJobs)) {
        $done = $false
        $name = Get-JobText $j
        if ($j.type -eq 'push') {
            if (-not (Test-Path -LiteralPath (Join-Path $j.path '.git'))) { Add-Line $out ("[skip] $name - folder is gone") 'DarkGray'; continue }
            $has = Invoke-Native 'git' @('-C', $j.path, 'rev-parse', '--abbrev-ref', ($j.branch + '@{upstream}'))
            $r = Push-OneBranch $j.path ([string]$j.remote) ([string]$j.branch) (-not $has.Ok)
            if ($r.Ok) { Add-Line $out "[ok]   $name" 'Green'; $done = $true } else { Add-Line $out ("[fail] $name : " + (Get-FirstLine $r.Out)) 'Red' }
        }
        elseif ($j.type -eq 'create-repo') {
            if (-not (Test-Path -LiteralPath (Join-Path $j.path '.git'))) { Add-Line $out ("[skip] $name - folder is gone") 'DarkGray'; continue }
            $hasRemote = Invoke-Native 'git' @('-C', $j.path, 'remote', 'get-url', 'origin')
            if ($hasRemote.Ok) {
                $br = Invoke-Native 'git' @('-C', $j.path, 'rev-parse', '--abbrev-ref', 'HEAD')
                $r = Push-OneBranch $j.path 'origin' (Get-FirstLine $br.Out) $true
            } else {
                $vis = '--private'; if ($j.visibility -eq 'public') { $vis = '--public' }
                $r = Invoke-Native 'gh' @('repo', 'create', ((Get-GhUser) + '/' + $j.name), $vis, '--source=.', '--remote=origin', '--push') $j.path
            }
            if ($r.Ok) { Add-Line $out "[ok]   $name" 'Green'; $done = $true } else { Add-Line $out ("[fail] $name : " + (Get-FirstLine $r.Out)) 'Red' }
        }
        elseif ($j.type -eq 'newrepo') {
            $vis = '--private'; if ($j.visibility -eq 'public') { $vis = '--public' }
            $r = Invoke-Native 'gh' @('repo', 'create', ((Get-GhUser) + '/' + $j.name), $vis)
            if ($r.Ok) { Add-Line $out "[ok]   $name" 'Green'; $done = $true } else { Add-Line $out ("[fail] $name : " + (Get-FirstLine $r.Out)) 'Red' }
        }
        elseif ($j.type -eq 'upload') {
            if (-not (Test-Path -LiteralPath $j.dir)) { Add-Line $out ("[skip] $name - saved files are gone") 'DarkGray'; continue }
            $s = Send-ToRepo ([string]$j.repo) @(@{ path = [string]$j.dir; kind = 'contents' }) ([string]$j.sub) ([string]$j.message)
            if ($s.ok) { Add-Line $out "[ok]   $name" 'Green'; $done = $true; Remove-Dir ([string]$j.dir) } else { Add-Line $out ("[fail] $name : " + $s.msg) 'Red' }
        }
        if (-not $done) { $remaining += $j }
    }
    Save-PendingJobs $remaining

    foreach ($u in @(Get-UnpushedRepos $true)) {
        foreach ($b in $u.Branches) {
            $label = $u.Project.Name + ' : ' + $b.Branch
            if ($b.Behind) { Add-Line $out "[skip] $label - diverged from the remote, pull / merge first" 'Yellow'; continue }
            $r = Push-OneBranch $u.Project.Path $b.Remote $b.Branch $false
            if ($r.Ok) { Add-Line $out "[ok]   pushed $label" 'Green' } else { Add-Line $out ("[fail] $label : " + (Get-FirstLine $r.Out)) 'Red' }
        }
    }
    $script:AheadCache.t = [datetime]::MinValue
    $script:ReposReload = $true
    if ($out.Count -eq 0) { Add-Line $out 'Everything is already up to date.' 'Green' }
    return $out
}

function Invoke-AutoSync {
    if (-not (Get-Cfg 'autoSyncOnStart')) { return }
    if (-not (Test-Online -Force)) { return }
    if ((Get-PendingCount) -eq 0) { return }
    Clear-Host
    Write-Host ''
    Write-Host '  Internet is back - uploading the work saved offline ...' -ForegroundColor Cyan
    $lines = Invoke-SyncPending
    Show-Pager 'Sync - uploaded offline work' $lines
}

function Show-SyncScreen {
    Clear-Host
    $jobs = @(Get-PendingJobs)
    $un = @(Get-UnpushedRepos $true)
    $lines = New-Object System.Collections.ArrayList
    if (Test-Online -Force) { Add-Line $lines 'Online' 'Green' } else { Add-Line $lines 'OFFLINE - nothing can be sent right now' 'Yellow' }
    Add-Line $lines ''
    Add-Line $lines "Queued jobs: $($jobs.Count)" 'Cyan'
    foreach ($j in $jobs) { Add-Line $lines ('  ' + (Get-JobText $j)) 'Gray' }
    Add-Line $lines ''
    Add-Line $lines 'Unpushed commits:' 'Cyan'
    if ($un.Count -eq 0) { Add-Line $lines '  none' 'DarkGray' }
    foreach ($u in $un) { foreach ($b in $u.Branches) { Add-Line $lines ('  ' + $u.Project.Name + ' : ' + $b.Branch) 'Gray' } }
    Show-Pager 'Sync status' $lines
    if (-not (Test-Online -Force)) { return }
    if ($jobs.Count -eq 0 -and $un.Count -eq 0) { return }
    if (Confirm-Action 'Upload everything now?') {
        Clear-Host
        Write-Host '  Uploading ...' -ForegroundColor Cyan
        Show-Pager 'Sync result' (Invoke-SyncPending)
    }
}

function Get-Repos {
    $cached = $false
    $list = @()
    if ((Test-GhReady $true)) {
        $json = gh repo list (Get-GhUser) --limit 200 --json name,visibility 2>$null
        if ($LASTEXITCODE -eq 0 -and $json) {
            $list = @((($json -join "`n") | ConvertFrom-Json))
            Write-JsonFile $script:ReposCacheFile @($list)
        } else { $cached = $true }
    } else { $cached = $true }
    if ($cached) {
        $c = Read-JsonFile $script:ReposCacheFile
        if ($c) { $list = @($c) }
    }
    $script:ReposCached = $cached
    return @($list)
}

function Copy-Tree([string]$Src, [string]$Dest) {
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    if (Get-Command robocopy -ErrorAction SilentlyContinue) {
        $srcClean = $Src
        if ($srcClean.Length -gt 3) { $srcClean = $srcClean.TrimEnd('\') }
        robocopy $srcClean $Dest /E /XD .git node_modules /NFL /NDL /NJH /NJS /NP | Out-Null
        return ($LASTEXITCODE -lt 8)
    }
    foreach ($it in (Get-ChildItem -LiteralPath $Src -Force)) {
        if ($it.PSIsContainer) {
            if ($it.Name -eq '.git' -or $it.Name -eq 'node_modules') { continue }
            if (-not (Copy-Tree $it.FullName (Join-Path $Dest $it.Name))) { return $false }
        }
        else { Copy-Item -LiteralPath $it.FullName -Destination $Dest -Force }
    }
    return $true
}

function ConvertTo-RepoPath([string]$Text) {
    if (-not $Text) { return '' }
    $t = $Text.Trim().Trim('"').Trim("'").Replace('\', '/').Trim('/')
    if (-not $t) { return '' }
    foreach ($seg in ($t -split '/')) {
        if ($seg -eq '' -or $seg -eq '.' -or $seg -eq '..' -or $seg -match '[:*?"<>|]') { return $null }
    }
    return $t
}

function Expand-ArchiveTo([string]$Archive, [string]$Dest) {
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    $lower = $Archive.ToLowerInvariant()
    $isZip = $lower.EndsWith('.zip')
    $isTar = ($lower -match '\.(tar|tgz|tar\.gz|tbz2|tar\.bz2|txz|tar\.xz)$')
    $isSev = ($lower -match '\.(7z|rar)$')
    if (-not ($isZip -or $isTar -or $isSev)) {
        return @{ ok = $false; msg = 'Unsupported type (supported: zip, 7z, rar, tar, tar.gz, tar.bz2, tar.xz)' }
    }
    if ($isZip) {
        try { Expand-Archive -LiteralPath $Archive -DestinationPath $Dest -Force -ErrorAction Stop; return @{ ok = $true; msg = '' } }
        catch { }
    }
    if ($isSev) {
        $seven = Find-7Zip
        if ($seven) {
            & $seven x "-o$Dest" -y $Archive 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { return @{ ok = $true; msg = '' } }
        }
    }
    if (Get-Command tar -ErrorAction SilentlyContinue) {
        tar -xf $Archive -C $Dest 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return @{ ok = $true; msg = '' } }
    }
    if ($isSev) { return @{ ok = $false; msg = 'Could not extract - install 7-Zip (winget install 7zip.7zip) and try again' } }
    return @{ ok = $false; msg = 'Could not extract this archive (corrupted or unsupported)' }
}

function Select-Files {
    $i = Show-Menu -Title 'Pick files' -Items @('Browse...  (select one or more files)', 'Type path(s)  (separate with ;  - files or folders)')
    $res = @()
    if ($i -eq 0) { $res = @(Select-FilesDialog 'Select files to upload' 'All files (*.*)|*.*' $script:StartDir $true) }
    elseif ($i -eq 1) {
        $v = Read-Input 'Path(s)' 'paths' @('Files or folders, separated with ;')
        foreach ($p in @(ConvertTo-PathList $v)) {
            if (-not (Test-Path -LiteralPath $p)) { Clear-Host; Show-Fail "Not found: $p"; return @() }
            $res += (Resolve-Path -LiteralPath $p).Path
        }
    }
    return $res
}

function Select-Archive {
    $i = Show-Menu -Title 'Pick the archive' -Items @('Browse...', 'Type path')
    if ($i -eq 0) {
        $f = @(Select-FilesDialog 'Select an archive' 'Archives|*.zip;*.7z;*.rar;*.tar;*.tgz;*.tbz2;*.txz;*.gz;*.bz2;*.xz|All files|*.*' $script:StartDir $false)
        if ($f.Count -gt 0) { return $f[0] }
        return $null
    }
    if ($i -eq 1) {
        $v = Read-Input 'Archive path' 'path'
        $p = @(ConvertTo-PathList $v) | Select-Object -First 1
        if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return (Resolve-Path -LiteralPath $p).Path }
        if ($p) { Clear-Host; Show-Fail "Not found: $p" }
    }
    return $null
}

function Send-ToRepo([string]$Name, $Sources, [string]$SubPath, [string]$Message) {
    $Message = $Message -replace '"', "'"
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('ghm_' + $Name)
    Remove-Dir $work
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $dest = Join-Path $work $Name
        git clone -q (Get-RepoUrl $Name) $dest 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return @{ ok = $false; msg = 'Clone failed' } }

        $target = $dest
        if ($SubPath) {
            $target = Join-Path $dest ($SubPath -replace '/', [string][System.IO.Path]::DirectorySeparatorChar)
            New-Item -ItemType Directory -Path $target -Force | Out-Null
        }
        foreach ($s in $Sources) {
            if ($s.kind -eq 'contents') {
                if (-not (Copy-Tree $s.path $target)) { return @{ ok = $false; msg = 'Copy failed' } }
            }
            else {
                $item = Get-Item -LiteralPath $s.path -Force
                if ($item.PSIsContainer) {
                    if (-not (Copy-Tree $item.FullName (Join-Path $target $item.Name))) { return @{ ok = $false; msg = 'Copy failed' } }
                }
                else { Copy-Item -LiteralPath $item.FullName -Destination $target -Force }
            }
        }

        $big = @(Get-ChildItem -LiteralPath $dest -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt 100MB -and $_.FullName -notmatch '[\\/]\.git[\\/]' })
        if ($big.Count -gt 0) { return @{ ok = $false; msg = ('Too big for GitHub (100 MB limit): ' + $big[0].Name + ' - nothing was uploaded') } }

        git -C $dest add -A 2>&1 | Out-Null
        $pending = git -C $dest status --porcelain 2>&1
        if (-not $pending) { return @{ ok = $true; changed = $false; stat = '' } }

        $o = git -C $dest commit -q -m $Message 2>&1
        if ($LASTEXITCODE -ne 0) { return @{ ok = $false; msg = ('Commit failed: ' + (Get-FirstLine $o)) } }
        $stat = Get-FirstLine (git -C $dest show --shortstat --format= HEAD 2>&1)

        $o = git -C $dest push -q -u origin HEAD 2>&1
        if ($LASTEXITCODE -ne 0) { return @{ ok = $false; msg = ('Push failed: ' + (Get-FirstLine $o)) } }
        return @{ ok = $true; changed = $true; stat = $stat }
    }
    finally { Remove-Dir $work }
}

$script:GhOk = $true
$script:GhError = ''
function Invoke-GhJson([string[]]$GhArgs) {
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $out = & gh @GhArgs 2>$errFile
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            $script:GhOk = $false
            $msg = ''
            if (Test-Path -LiteralPath $errFile) { $msg = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue }
            if (-not $msg) { $msg = "gh exited with code $code" }
            $script:GhError = ($msg.Trim() -split "`r?`n")[0]
            return $null
        }
        $script:GhOk = $true
        if ($null -eq $out) { return $null }
        $text = (@($out) | ForEach-Object { "$_" }) -join "`n"
        if (-not $text.Trim()) { return $null }
        return ($text | ConvertFrom-Json)
    }
    catch { $script:GhOk = $false; $script:GhError = $_.Exception.Message; return $null }
    finally { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
}

function Select-CloneTarget {
    $www = Get-WwwDir
    $i = Show-Menu -Title 'Clone into ...' -Items @(
        @{ label = 'Laragon www'; note = $www; color = 'DarkGray' },
        @{ label = 'This folder'; note = $script:StartDir; color = 'DarkGray' },
        @{ label = 'Browse...'; note = ''; color = 'DarkGray' })
    if ($i -eq 0) { return $www }
    if ($i -eq 1) { return $script:StartDir }
    if ($i -eq 2) { return (Select-FolderDialog 'Clone into which folder?' $www) }
    return $null
}

function Invoke-RepoClone([string]$Name) {
    $base = Select-CloneTarget
    if (-not $base) { return }
    Write-Header "Clone $Name"
    $dest = Join-Path $base $Name
    if (Test-Path -LiteralPath $dest) { Show-Fail "Already exists: $dest"; return }
    git clone -q (Get-RepoUrl $Name) $dest
    if ($LASTEXITCODE -eq 0) { Show-Ok "Cloned to $dest" } else { Show-Fail 'Clone failed' }
}

function Invoke-RepoClear([string]$Name) {
    Write-Header "Clear $Name"
    $work = Join-Path $env:TEMP ('ghm_' + $Name)
    Remove-Dir $work
    New-Item -ItemType Directory -Path $work | Out-Null
    Push-Location $work
    try {
        git clone -q (Get-RepoUrl $Name) 2>$null
        if ($LASTEXITCODE -ne 0) { Show-Fail 'Clone failed'; return }
        Set-Location $Name
        git rm -r -q . 2>$null
        if ($LASTEXITCODE -ne 0) { Show-Ok 'Already empty'; return }
        git commit -q -m 'Remove all files'
        git push -q 2>$null
        if ($LASTEXITCODE -eq 0) { Show-Ok 'Cleared' } else { Show-Fail 'Push failed' }
    }
    finally { Pop-Location; Remove-Dir $work }
}

function Invoke-RepoUpload([string]$Name) {
    $mode = Show-Menu -Title "Upload to $Name" -Items @(
        'Folder    (its contents go into the repo)',
        'Files     (pick one or more files)',
        'Archive   (upload and extract: zip, 7z, rar, tar.gz ...)')
    if ($mode -lt 0) { return }

    $extractDir = $null
    try {
        $sources = @()
        $message = 'Upload files'
        $what = ''
        if ($mode -eq 0) {
            $f = Select-FolderMenu -Title 'Upload which folder?' -StartDir $script:StartDir
            if (-not $f) { return }
            $sources = @(@{ path = $f; kind = 'contents' })
            $leaf = Split-Path $f -Leaf
            if (-not $leaf) { $leaf = $f }
            $what = $f
            $message = 'Upload ' + $leaf
        }
        elseif ($mode -eq 1) {
            $files = @(Select-Files)
            if ($files.Count -eq 0) { return }
            foreach ($p in $files) { $sources += @{ path = $p; kind = 'item' } }
            if ($files.Count -eq 1) { $what = $files[0]; $message = 'Upload ' + (Split-Path $files[0] -Leaf) }
            else { $what = '' + $files.Count + ' items'; $message = 'Upload ' + $files.Count + ' items' }
        }
        else {
            $arc = Select-Archive
            if (-not $arc) { return }
            $arcName = Split-Path $arc -Leaf
            $extractDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ghm_extract_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            Write-Header 'Extracting'
            Write-Host ('  ' + $arcName) -ForegroundColor DarkGray
            $x = Expand-ArchiveTo $arc $extractDir
            if (-not $x.ok) { Show-Fail $x.msg; return }
            Get-ChildItem -LiteralPath $extractDir -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq '__MACOSX' -or $_.Name -eq '.DS_Store' } |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            $top = @(Get-ChildItem -LiteralPath $extractDir -Force)
            if ($top.Count -eq 0) { Show-Fail 'The archive is empty'; return }
            $root = $extractDir
            if ($top.Count -eq 1 -and $top[0].PSIsContainer) {
                $n = $top[0].Name
                $i = Show-Menu -Title ('The archive contains one folder: ' + $n) -Items @(
                    ("Upload its contents (without the '" + $n + "' folder)"), ("Keep the folder '" + $n + "'"))
                if ($i -lt 0) { return }
                if ($i -eq 0) { $root = $top[0].FullName }
            }
            $cnt = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue).Count
            $sources = @(@{ path = $root; kind = 'contents' })
            $what = $arcName + '  (extracted: ' + (Format-Files $cnt) + ')'
            $message = 'Upload ' + $arcName + ' (extracted)'
        }

        Write-Header "Upload to $Name"
        Write-Host ('  From: ' + $what) -ForegroundColor DarkGray
        Write-Host ''
        $subIn = Read-LineEsc '  Folder inside the repo (Enter = repo root)> '
        if ($null -eq $subIn) { return }
        $sub = ConvertTo-RepoPath $subIn
        if ($null -eq $sub) { Show-Fail 'Invalid folder path'; return }

        if (-not (Test-Online -Force) -or -not (Test-GhReady $true)) {

            Write-Host '  OFFLINE - saving a copy to send later ...' -ForegroundColor Yellow
            $box = Join-Path $script:OutboxDir ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $box | Out-Null
            foreach ($s in $sources) {
                if ($s.kind -eq 'contents') { [void](Copy-Tree $s.path $box) }
                else {
                    $item = Get-Item -LiteralPath $s.path -Force
                    if ($item.PSIsContainer) { [void](Copy-Tree $item.FullName (Join-Path $box $item.Name)) }
                    else { Copy-Item -LiteralPath $item.FullName -Destination $box -Force }
                }
            }
            Add-PendingJob @{ type = 'upload'; repo = $Name; sub = $sub; message = $message; dir = $box }
            Write-Host '  Saved. It will be uploaded automatically the next time the tool opens with internet.' -ForegroundColor Green
            Wait-Key
            return
        }

        Write-Host '  Cloning, copying and pushing...' -ForegroundColor DarkGray
        $r = Send-ToRepo $Name $sources $sub $message
        if (-not $r.ok) { Show-Fail $r.msg; return }
        if (-not $r.changed) { Show-Ok 'Nothing new - everything is already in the repo'; return }
        Write-Host ('  Uploaded: ' + $r.stat) -ForegroundColor Green
        Wait-Key
    }
    finally { if ($extractDir) { Remove-Dir $extractDir } }
}

function Invoke-RepoDelete([string]$Name) {
    Write-Header "Delete $Name"
    gh repo delete ((Get-GhUser) + "/$Name") --yes 2>$null
    if ($LASTEXITCODE -ne 0) {
        gh auth refresh -h github.com -s delete_repo
        gh repo delete ((Get-GhUser) + "/$Name") --yes 2>$null
    }
    if ($LASTEXITCODE -eq 0) { Show-Ok 'Deleted'; return $true }
    Show-Fail 'Delete failed'
    return $false
}

function Invoke-RepoVisibility([string]$Name, [string]$Current) {
    if ($Current -eq 'PUBLIC') { $new = 'private' } else { $new = 'public' }
    Write-Header "$Name -> $new"
    gh repo edit ((Get-GhUser) + "/$Name") --visibility $new --accept-visibility-change-consequences 2>$null
    if ($LASTEXITCODE -eq 0) { Show-Ok "Now $new"; return $true }
    Show-Fail 'Failed'
    return $false
}

function Invoke-RepoRename([string]$Name) {
    $new = Read-Input "Rename $Name" 'new name'
    if (-not $new) { return $false }
    gh repo rename $new --repo ((Get-GhUser) + "/$Name") --yes 2>$null
    if ($LASTEXITCODE -eq 0) { Show-Ok 'Renamed'; return $true }
    Show-Fail 'Failed'
    return $false
}

function Invoke-NewRepo {
    $name = Read-Input 'New repo' 'name'
    if (-not $name) { return }
    $i = Show-Menu -Title $name -Items @('Private', 'Public') -Hint 'Enter: select    Backspace/Left: cancel    Esc: exit'
    if ($i -lt 0) { return }
    $vis = 'private'; $flag = '--private'
    if ($i -eq 1) { $vis = 'public'; $flag = '--public' }
    if (-not (Test-GhReady $true)) {
        Add-PendingJob @{ type = 'newrepo'; name = $name; visibility = $vis }
        Clear-Host
        Show-Ok 'OFFLINE - the repo will be created automatically when internet is back'
        return
    }
    gh repo create ((Get-GhUser) + "/$name") $flag 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Show-Ok 'Created' } else { Show-Fail 'Failed' }
}

if ($script:TreeMid -eq $null) {
    $h = [string][char]0x2500
    $script:TreeMid  = [string][char]0x251C + $h + $h + ' '
    $script:TreeLast = [string][char]0x2514 + $h + $h + ' '
    $script:TreePipe = [string][char]0x2502 + '   '
    $script:BarFull  = [string][char]0x2588
    $script:BarEmpty = [string][char]0x2591
    $script:TreeBlank = '    '
}

function New-Node([string]$Name, [bool]$Dir) {
    return @{ name = $Name; dir = $Dir; size = [long]0; total = [long]0; files = 0; note = ''; kids = (New-Object System.Collections.ArrayList) }
}

function Build-PathNode([string]$Name, $Entries) {
    $root = New-Node $Name $true
    $map = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    $map[''] = $root
    foreach ($e in $Entries) {
        $parts = ("$($e.path)") -split '/'
        $cur = $root
        $acc = ''
        for ($k = 0; $k -lt $parts.Count - 1; $k++) {
            if ($acc) { $acc = $acc + '/' + $parts[$k] } else { $acc = $parts[$k] }
            if ($map.ContainsKey($acc)) { $cur = $map[$acc] }
            else {
                $d = New-Node $parts[$k] $true
                [void]$cur.kids.Add($d)
                $map[$acc] = $d
                $cur = $d
            }
        }
        $leaf = $parts[$parts.Count - 1]
        if ($e.type -eq 'tree') {
            if (-not $map.ContainsKey("$($e.path)")) {
                $d = New-Node $leaf $true
                [void]$cur.kids.Add($d)
                $map["$($e.path)"] = $d
            }
        }
        else {
            $f = New-Node $leaf $false
            $f.size = [long]$e.size
            if ($e.type -eq 'commit') { $f.note = 'submodule' }
            [void]$cur.kids.Add($f)
        }
    }
    return $root
}

function Build-LocalNode([string]$Path, [string]$Name, [string[]]$Skip) {
    $node = New-Node $Name $true
    foreach ($it in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        if ($it.PSIsContainer) {
            if ($Skip -contains $it.Name) { $s = New-Node $it.Name $true; $s.note = 'skipped'; [void]$node.kids.Add($s) }
            elseif (($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $s = New-Node $it.Name $true; $s.note = 'link'; [void]$node.kids.Add($s) }
            else { [void]$node.kids.Add((Build-LocalNode $it.FullName $it.Name $Skip)) }
        }
        else {
            $f = New-Node $it.Name $false
            $f.size = [long]$it.Length
            [void]$node.kids.Add($f)
        }
    }
    return $node
}

function Measure-Node($Node) {
    if (-not $Node.dir) { $Node.total = [long]$Node.size; $Node.files = 1; return }
    $t = [long]0; $f = 0
    foreach ($k in $Node.kids) { Measure-Node $k; $t += $k.total; $f += $k.files }
    $Node.total = $t
    $Node.files = $f
}

function Add-TreeLines($Node, [string]$Prefix, $Out, [int]$Depth, [int]$MaxDepth) {
    if ($MaxDepth -gt 0 -and $Depth -ge $MaxDepth) { return }
    $kids = @($Node.kids | Sort-Object @{ Expression = { if ($_.dir) { 0 } else { 1 } } }, @{ Expression = { $_.name } })
    for ($k = 0; $k -lt $kids.Count; $k++) {
        $n = $kids[$k]
        if ($k -eq $kids.Count - 1) { $conn = $script:TreeLast; $ext = $script:TreeBlank }
        else { $conn = $script:TreeMid; $ext = $script:TreePipe }
        if ($n.dir) {
            if ($n.note) { $info = '(' + $n.note + ')' }
            else { $info = '(' + (Format-Files $n.files) + ', ' + (Format-Size $n.total) + ')' }
            [void]$Out.Add(@{ t = ($Prefix + $conn + $n.name + '/  ' + $info); c = 'Cyan' })
            if (-not $n.note) { Add-TreeLines $n ($Prefix + $ext) $Out ($Depth + 1) $MaxDepth }
        }
        else {
            $info = Format-Size $n.size
            if ($n.note) { $info = $info + ', ' + $n.note }
            [void]$Out.Add(@{ t = ($Prefix + $conn + $n.name + '  (' + $info + ')'); c = 'Gray' })
        }
    }
}

function Get-TreeLines($Root, [int]$MaxDepth) {
    Measure-Node $Root
    $out = New-Object System.Collections.ArrayList
    Add-Line $out ($Root.name + '/  (' + (Format-Files $Root.files) + ', ' + (Format-Size $Root.total) + ')') 'Yellow'
    Add-TreeLines $Root '' $out 0 $MaxDepth
    return ,$out
}

$script:TreeSkipDirs = @('.git', 'node_modules', 'vendor', '.idea', '.vs')

function Show-RepoTree([string]$Name) {
    $i = Show-Menu -Title "File tree - $Name" -Items @('Full tree', 'Up to 3 levels', 'Top level only')
    if ($i -lt 0) { return }
    $depth = @(0, 3, 1)[$i]
    Write-Header "File tree - $Name"
    Write-Host '  Loading...' -ForegroundColor DarkGray
    $meta = Invoke-GhJson @('api', ('repos/' + (Get-GhUser) + "/$Name"))
    if (-not $script:GhOk) { Show-Fail ('Failed: ' + $script:GhError); return }
    $branch = 'HEAD'
    if ($meta -and $meta.default_branch) { $branch = $meta.default_branch }
    $tree = Invoke-GhJson @('api', ('repos/' + (Get-GhUser) + "/$Name/git/trees/$($branch)?recursive=1"))
    if (-not $script:GhOk) { Show-Fail ('Failed: ' + $script:GhError); return }
    $entries = @()
    if ($tree -and $tree.tree) { $entries = @($tree.tree) }
    if ($entries.Count -eq 0) { Show-Fail 'Nothing to show - the repo is empty'; return }
    $root = Build-PathNode $Name $entries
    $lines = Get-TreeLines $root $depth
    if ($tree.truncated) { Add-Line $lines ''; Add-Line $lines 'Note: GitHub truncated this listing (very large repo).' 'Red' }
    Show-Pager "File tree - $Name   [$branch]" $lines
}

function Show-RepoInfo([string]$Name) {
    Write-Header "Info - $Name"
    Write-Host '  Loading...' -ForegroundColor DarkGray
    $u = Get-GhUser
    $meta = Invoke-GhJson @('api', "repos/$u/$Name")
    if (-not $script:GhOk -or -not $meta) { Show-Fail ('Failed: ' + $script:GhError); return }
    $langs = Invoke-GhJson @('api', "repos/$u/$Name/languages")
    $langOk = $script:GhOk
    $br = Invoke-GhJson @('api', "repos/$u/$Name/branches?per_page=100")
    $brCount = 0
    if ($script:GhOk -and $null -ne $br) { $brCount = @($br).Count }
    $brText = "$brCount"
    if ($brCount -ge 100) { $brText = '100+' }

    $vis = $meta.visibility
    if (-not $vis) { if ($meta.private) { $vis = 'private' } else { $vis = 'public' } }
    if ($meta.archived) { $vis = $vis + ', archived' }
    $license = '-'
    if ($meta.license -and $meta.license.spdx_id) { $license = $meta.license.spdx_id }

    $lines = New-Object System.Collections.ArrayList
    Add-Line $lines $Name 'Yellow'
    if ($meta.description) { Add-Line $lines ('' + $meta.description) 'Gray' }
    Add-Line $lines ''
    Add-Line $lines ('Visibility'.PadRight(16) + $vis)
    Add-Line $lines ('Default branch'.PadRight(16) + $meta.default_branch + '   (' + $brText + ' branches)')
    Add-Line $lines ('Size'.PadRight(16) + (Format-Size ([double]$meta.size * 1024)))
    Add-Line $lines ('Created'.PadRight(16) + (Format-Date $meta.created_at))
    Add-Line $lines ('Last push'.PadRight(16) + (Format-Date $meta.pushed_at))
    Add-Line $lines ('Stars / Forks'.PadRight(16) + $meta.stargazers_count + ' / ' + $meta.forks_count)
    Add-Line $lines ('Open issues+PRs'.PadRight(16) + $meta.open_issues_count)
    Add-Line $lines ('License'.PadRight(16) + $license)
    Add-Line $lines ('URL'.PadRight(16) + $meta.html_url)
    Add-Line $lines ''
    Add-Line $lines 'Languages' 'Cyan'

    $props = @()
    if ($langOk -and $langs) { $props = @($langs.PSObject.Properties | Sort-Object Value -Descending) }
    if ($props.Count -eq 0) { Add-Line $lines '  (no language data)' 'DarkGray' }
    else {
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $total = [double]0
        foreach ($p in $props) { $total += [double]$p.Value }
        $colors = @('Cyan', 'Yellow', 'Green', 'Magenta', 'Blue', 'Red', 'DarkCyan', 'DarkYellow')
        $ci = 0
        foreach ($p in $props) {
            $pct = [double]0
            if ($total -gt 0) { $pct = [double]$p.Value / $total * 100 }
            $w = [int][Math]::Round($pct / 100 * 30)
            if ($w -lt 1) { $w = 1 }
            if ($w -gt 30) { $w = 30 }
            $bar = ($script:BarFull * $w) + ($script:BarEmpty * (30 - $w))
            $pctText = $pct.ToString('0.0', $inv).PadLeft(5)
            Add-Line $lines ('  ' + ('' + $p.Name).PadRight(14) + ' ' + $bar + ' ' + $pctText + '%  ' + (Format-Size $p.Value)) $colors[$ci % $colors.Count]
            $ci++
        }
    }
    Show-Pager "Info - $Name" $lines
}

function Show-RepoCommits([string]$Name) {
    Write-Header "Commits - $Name"
    Write-Host '  Loading...' -ForegroundColor DarkGray
    $c = Invoke-GhJson @('api', ('repos/' + (Get-GhUser) + "/$Name/commits?per_page=60"))
    if (-not $script:GhOk) { Show-Fail ('Failed: ' + $script:GhError); return }
    $commits = @()
    if ($null -ne $c) { $commits = @($c) }
    if ($commits.Count -eq 0) { Show-Fail 'No commits yet'; return }
    $lines = New-Object System.Collections.ArrayList
    foreach ($x in $commits) {
        $sha = "$($x.sha)"
        if ($sha.Length -gt 7) { $sha = $sha.Substring(0, 7) }
        $msg = ("$($x.commit.message)" -split "`r?`n")[0]
        $who = "$($x.commit.author.name)"
        if ($who.Length -gt 18) { $who = $who.Substring(0, 18) }
        $mark = '*'; $color = 'Gray'
        if (@($x.parents).Count -gt 1) { $mark = 'M'; $color = 'Magenta' }
        Add-Line $lines ($mark + ' ' + $sha + '  ' + (Format-Date $x.commit.author.date) + '  ' + $who.PadRight(18) + '  ' + $msg) $color
    }
    Show-Pager ("Commits - $Name   (latest " + $commits.Count + ')') $lines
}

function Show-LocalTree([string]$Path) {
    $leaf = Split-Path $Path -Leaf
    if (-not $leaf) { $leaf = $Path }
    $i = Show-Menu -Title ('Folder tree - ' + $leaf) -Items @(
        'Up to 3 levels (skip .git, node_modules, vendor)', 'Full tree (skip .git, node_modules, vendor)',
        'Top level only', 'Full tree (include everything)')
    if ($i -lt 0) { return }
    $depth = @(3, 0, 1, 0)[$i]
    $skip = $script:TreeSkipDirs
    if ($i -eq 3) { $skip = @() }
    Write-Header ('Folder tree - ' + $leaf)
    Write-Host '  Scanning...' -ForegroundColor DarkGray
    $root = Build-LocalNode $Path $leaf $skip
    Show-Pager ('Folder tree - ' + $Path) (Get-TreeLines $root $depth)
}

function New-RepoBackup([string]$Name) {
    $dir = Join-Path (Get-GitHubBackupRoot) $Name
    try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null } catch { return @{ ok = $false; msg = "Cannot create $dir - set the backup folder in Settings" } }
    $file = Join-Path $dir ($Name + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bundle')
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('ghb_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        git clone -q --bare (Get-RepoUrl $Name) $tmp 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return @{ ok = $false; msg = 'Clone failed' } }
        git -C $tmp bundle create $file --all 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $file)) { return @{ ok = $false; msg = 'Nothing to back up (empty repo?)' } }
        git -C $tmp bundle verify $file 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue; return @{ ok = $false; msg = 'Backup failed verification' } }
        return @{ ok = $true; file = $file; size = (Get-Item -LiteralPath $file).Length }
    }
    finally { if (Test-Path -LiteralPath $tmp) { Remove-Dir $tmp } }
}

function Invoke-RepoBackup([string]$Name) {
    Write-Header "Backup $Name"
    Write-Host '  Downloading and bundling...' -ForegroundColor DarkGray
    $r = New-RepoBackup $Name
    if (-not $r.ok) { Show-Fail $r.msg; return }
    Write-Host ('  Backup saved and verified (' + (Format-Size $r.size) + ')') -ForegroundColor Green
    Write-Host ('  ' + $r.file) -ForegroundColor DarkGray
    Wait-Key
}

function Invoke-RepoBackupAll($Repos) {
    Write-Header 'Backup all repos'
    $n = 0; $okN = 0; $bad = 0
    foreach ($r in $Repos) {
        $n++
        Write-Host ('  [' + $n + '/' + @($Repos).Count + '] ' + $r.name + ' ... ') -NoNewline
        $res = New-RepoBackup $r.name
        if ($res.ok) { Write-Host ('ok (' + (Format-Size $res.size) + ')') -ForegroundColor Green; $okN++ }
        else { Write-Host $res.msg -ForegroundColor Yellow; $bad++ }
    }
    Write-Host ''
    Write-Host ('  Done: ' + $okN + ' backed up, ' + $bad + ' skipped/failed') -ForegroundColor Cyan
    Write-Host ('  ' + (Get-GitHubBackupRoot)) -ForegroundColor DarkGray
    Wait-Key
}

function Invoke-RepoRestore([string]$Name) {
    $dir = Join-Path (Get-GitHubBackupRoot) $Name
    $files = @()
    if (Test-Path -LiteralPath $dir) { $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.bundle' -File | Sort-Object LastWriteTime -Descending) }
    if ($files.Count -eq 0) { Write-Header "Restore $Name"; Show-Fail "No backups yet - use 'Backup' first"; return }
    $items = @()
    foreach ($f in $files) { $items += ($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm') + '   ' + (Format-Size $f.Length).PadLeft(9) + '   ' + $f.Name) }
    $items += 'Open backup folder'
    $i = Show-Menu -Title "Restore $Name from backup" -Items $items -Hint 'Up/Down    Enter: restore as a new folder    Backspace/Left: back    Esc: exit'
    if ($i -lt 0) { return }
    if ($i -eq $files.Count) { Invoke-Item -LiteralPath $dir; return }
    $f = $files[$i]
    Write-Header "Restore $Name"
    $base = Select-CloneTarget
    if (-not $base) { return }
    $dest = Join-Path $base ($Name + '-restored-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    git clone -q $f.FullName $dest 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Show-Fail 'Restore failed'; return }
    git -C $dest remote set-url origin (Get-RepoUrl $Name) 2>$null | Out-Null
    Write-Host '  Restored as a new folder (GitHub was not touched):' -ForegroundColor Green
    Write-Host ('  ' + $dest) -ForegroundColor DarkGray
    Wait-Key
}

$script:RepoActions = @(
    @{ id = 'clone';   t = 'Clone';                needs = $true },
    @{ id = 'upload';  t = 'Upload';               needs = $false },
    @{ id = 'open';    t = 'Open in browser';      needs = $true },
    @{ id = 'url';     t = 'Copy URL';             needs = $false },
    @{ id = 'backup';  t = 'Backup (local bundle)'; needs = $true },
    @{ id = 'restore'; t = 'Restore from backup';  needs = $false },
    @{ id = 'vis';     t = 'Public / Private';     needs = $true },
    @{ id = 'rename';  t = 'Rename';               needs = $true },
    @{ id = 'commits'; t = 'History';              needs = $true },
    @{ id = 'clear';   t = 'Clear';                needs = $true; danger = $true },
    @{ id = 'delete';  t = 'Delete';               needs = $true; danger = $true }
)

function Show-ReposScreen {
    if ($script:ReposReload) {
        Clear-Host
        Write-Host ''
        Write-Host '  Loading repos...' -ForegroundColor Yellow
        $script:Repos = @(Get-Repos)
        $script:RepoView = @{}
        $script:ReposReload = $false
    }
    $repos = @($script:Repos)
    $maxLen = 10
    foreach ($r in $repos) { if ($r.name.Length -gt $maxLen) { $maxLen = $r.name.Length } }
    $items = @()
    foreach ($r in $repos) { $items += @{ label = $r.name; note = $r.visibility.ToLower(); color = 'DarkGray' } }
    $items += @{ label = '+ New repo';              note = ''; color = 'Green' }
    $items += @{ label = 'Backup all repos (local)'; note = ''; color = 'DarkGray' }
    $items += @{ label = 'Refresh';                 note = ''; color = 'DarkGray' }

    $sub = ''
    $flash = ''; $fc = 'Yellow'
    if ($script:ReposCached) { $flash = 'OFFLINE - showing the saved list. Upload and New repo are queued until internet is back.' }
    $key = 'repos'
    $m = @{ Title = ('GitHub - ' + (Get-GhUser) + '   (' + $repos.Count + ' repos)'); Items = $items; Start = (Get-LastSel $key); Flash = $flash; FlashColor = $fc }
    $m += (Get-NavArgs $true)
    $i = Show-Menu @m
    if (Invoke-NavKey $i @{ type = 'home' }) { return }
    Set-LastSel $key $i
    if ($i -lt $repos.Count) { Open-Loc @{ type = 'repo'; name = $repos[$i].name }; return }
    $x = $i - $repos.Count
    if ($x -eq 0) { Invoke-NewRepo; $script:ReposReload = $true }
    elseif ($x -eq 1) {
        if (-not (Test-GhReady)) { Clear-Host; Show-Fail 'Needs internet'; return }
        if ($repos.Count -gt 0 -and (Confirm-Action ('Back up all ' + $repos.Count + ' repos? (downloads everything)'))) { Invoke-RepoBackupAll $repos }
    }
    elseif ($x -eq 2) { $script:ReposReload = $true }
}

$script:RepoView = @{}

function Get-RepoView([string]$Name) {
    if ($script:RepoView.ContainsKey($Name)) { return $script:RepoView[$Name] }
    $v = @{ tree = @(@{ t = '(no data)'; c = 'DarkGray' }); info = ''; bar = @(); leg = @() }
    $u = Get-GhUser
    $meta = Invoke-GhJson @('api', "repos/$u/$Name")
    if ($script:GhOk -and $meta) {
        $vis = $meta.visibility; if (-not $vis) { $vis = 'public' }
        $lic = '-'; if ($meta.license -and $meta.license.spdx_id) { $lic = $meta.license.spdx_id }
        $v.info = "$vis | $($meta.default_branch) | $(Format-Size ([double]$meta.size * 1024)) | push $(Format-Date $meta.pushed_at) | $($meta.stargazers_count) stars, $($meta.forks_count) forks | $lic"
        $tr = Invoke-GhJson @('api', "repos/$u/$Name/git/trees/$($meta.default_branch)?recursive=1")
        if ($script:GhOk -and $tr -and $tr.tree) { $tl = Get-TreeLines (Build-PathNode $Name @($tr.tree)) 0; $v.tree = @($tl) }
        $langs = Invoke-GhJson @('api', "repos/$u/$Name/languages")
        if ($script:GhOk -and $langs) {
            $inv = [System.Globalization.CultureInfo]::InvariantCulture
            $props = @($langs.PSObject.Properties | Sort-Object Value -Descending)
            $total = [double]0; foreach ($q in $props) { $total += [double]$q.Value }
            $cols = @('Cyan', 'Yellow', 'Green', 'Magenta', 'Blue', 'Red', 'DarkCyan', 'DarkYellow')
            $ci = 0; $bar = @(); $leg = @()
            foreach ($q in $props) {
                $pct = 0; if ($total -gt 0) { $pct = [double]$q.Value / $total * 100 }
                $w = [Math]::Max(1, [int][Math]::Round($pct / 100 * 60))
                $c = $cols[$ci % $cols.Count]
                $bar += @{ t = ($script:BarFull * $w); c = $c }
                $leg += @{ t = ('' + $q.Name + ' ' + $pct.ToString('0.0', $inv) + '%   '); c = $c }
                $ci++
            }
            $v.bar = $bar; $v.leg = $leg
        }
    }
    $script:RepoView[$Name] = $v
    return $v
}

function Write-Segs($Segs, [int]$W) {
    $left = $W
    foreach ($s in @($Segs)) {
        if ($left -le 0) { break }
        $t = [string]$s.t
        if ($t.Length -gt $left) { $t = $t.Substring(0, $left) }
        Write-Host $t -NoNewline -ForegroundColor $s.c
        $left -= $t.Length
    }
    Write-Host (' ' * [Math]::Max(0, $left))
}

function Show-RepoSplit([string]$Name, $Items, [int]$Start, [bool]$Online, [bool]$CanBack, [bool]$CanFwd) {
    if ($Online) { $v = Get-RepoView $Name }
    else { $v = @{ tree = @(@{ t = '(needs internet)'; c = 'DarkGray' }); info = ''; bar = @(); leg = @() } }
    $count = $Items.Count
    $sel = [Math]::Min([Math]::Max($Start, 0), $count - 1)
    if (-not $Items[$sel].enabled) { $sel = Step-MenuSel $Items $sel 1 }
    $tt = 0
    try { [Console]::CursorVisible = $false } catch { }
    Clear-Host
    try {
        while ($true) {
            $ws = Get-WinSize
            $L = 28
            $R = [Math]::Max(10, $ws.W - $L - 9)
            $body = [Math]::Max(5, $ws.H - 9)
            $maxTop = [Math]::Max(0, $v.tree.Count - $body)
            if ($tt -gt $maxTop) { $tt = $maxTop }
            if ($tt -lt 0) { $tt = 0 }
            $top = 0
            if ($sel -ge $body) { $top = $sel - $body + 1 }
            try { [Console]::SetCursorPosition(0, 0) } catch { Clear-Host }
            Write-Row ''
            Write-Row ('  ' + $Name) 'Cyan'
            Write-Row ('  ' + ('-' * [Math]::Max(10, $ws.W - 4))) 'DarkGray'
            for ($k = 0; $k -lt $body; $k++) {
                $ix = $top + $k
                $a = ''.PadRight($L + 4)
                $fg = 'Gray'; $bg = ''
                if ($ix -lt $count) {
                    $it = $Items[$ix]
                    $lab = [string]$it.label
                    if ($lab.Length -gt $L) { $lab = $lab.Substring(0, $L) }
                    $pre = '    '; if ($ix -eq $sel) { $pre = '  > ' }
                    $a = ($pre + $lab).PadRight($L + 4)
                    if ($ix -eq $sel) {
                        if ($it.danger) { $fg = 'White'; $bg = 'DarkRed' } else { $fg = 'Black'; $bg = 'Cyan' }
                    }
                    elseif (-not $it.enabled) { $fg = 'DarkGray' }
                    elseif ($it.danger) { $fg = 'Red' }
                }
                if ($bg) { Write-Host $a -NoNewline -ForegroundColor $fg -BackgroundColor $bg } else { Write-Host $a -NoNewline -ForegroundColor $fg }
                Write-Host ' | ' -NoNewline -ForegroundColor DarkGray
                $ti = $tt + $k
                if ($ti -lt $v.tree.Count) {
                    $tl = $v.tree[$ti]
                    $tx = [string]$tl.t
                    if ($tx.Length -gt $R) { $tx = $tx.Substring(0, $R) }
                    Write-Host $tx.PadRight($R) -ForegroundColor $tl.c
                } else { Write-Host (' ' * $R) }
            }
            Write-Row ('  ' + ('-' * [Math]::Max(10, $ws.W - 4))) 'DarkGray'
            Write-Segs @(@{ t = ('  ' + $v.info); c = 'Gray' }) ($ws.W - 1)
            Write-Segs (@(@{ t = '  '; c = 'Gray' }) + @($v.bar)) ($ws.W - 1)
            Write-Segs (@(@{ t = '  '; c = 'Gray' }) + @($v.leg)) ($ws.W - 1)
            Write-Row '  Up/Down    Enter    PgUp/PgDn: scroll tree    Left/Right: history    Backspace: up    Esc: exit' 'DarkGray'

            $k = Read-KeyWait
            if ($null -eq $k) { continue }
            if     ($k.Key -eq 'UpArrow')   { $sel = Step-MenuSel $Items $sel -1 }
            elseif ($k.Key -eq 'DownArrow') { $sel = Step-MenuSel $Items $sel 1 }
            elseif ($k.Key -eq 'PageUp')    { $tt -= $body }
            elseif ($k.Key -eq 'PageDown')  { $tt += $body }
            elseif ($k.Key -eq 'Home')      { $tt = 0 }
            elseif ($k.Key -eq 'End')       { $tt = $maxTop }
            elseif ($k.Key -eq 'Enter')     { if ($Items[$sel].enabled) { return $sel } }
            elseif ($k.Key -eq 'Backspace') { return -1 }
            elseif ($k.Key -eq 'LeftArrow') { if ($CanBack) { return -2 } }
            elseif ($k.Key -eq 'RightArrow') { if ($CanFwd) { return -3 } }
            elseif ($k.Key -eq 'Escape')    { if (-not (Exit-Tool)) { Clear-Host } }
        }
    }
    finally { try { [Console]::CursorVisible = $true } catch { } }
}

function Show-RepoScreen($Loc) {
    $name = $Loc.name
    $repo = @($script:Repos) | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if (-not $repo) { Remove-HistLoc 'repo' $name; return }
    $vis = [string]$repo.visibility
    $online = (-not $script:ReposCached) -and (Test-Online)
    $items = @(); $danger = @()
    for ($k = 0; $k -lt $script:RepoActions.Count; $k++) {
        $a = $script:RepoActions[$k]
        $en = $true; $note = ''
        if ($a.needs -and -not $online) { $en = $false; $note = 'needs internet' }
        if ($a.id -eq 'upload' -and -not $online) { $en = $true; $note = 'queued until internet is back' }
        $items += @{ label = $a.t; note = $note; color = 'Yellow'; enabled = $en }
        if ($a.danger) { $danger += $k }
    }
    $key = 'repo:' + $name
    foreach ($d in $danger) { $items[$d].danger = $true }
    if ($online -and -not $script:RepoView.ContainsKey($name)) { Clear-Host; Write-Host '  Loading...' -ForegroundColor DarkGray }
    $na = Get-NavArgs $true
    $i = Show-RepoSplit $name $items (Get-LastSel $key) $online $na.CanBack $na.CanFwd
    if (Invoke-NavKey $i @{ type = 'repos' }) { return }
    Set-LastSel $key $i
    $id = $script:RepoActions[$i].id
    if ($id -eq 'clone')   { Invoke-RepoClone $name }
    elseif ($id -eq 'upload')  { Invoke-RepoUpload $name }
    elseif ($id -eq 'open')    { gh repo view ((Get-GhUser) + "/$name") --web }
    elseif ($id -eq 'url')     { Set-Clipboard (Get-RepoUrl $name); Write-Header 'Copy URL'; Show-Ok 'Copied' }
    elseif ($id -eq 'commits') { Show-RepoCommits $name }
    elseif ($id -eq 'backup')  { Invoke-RepoBackup $name }
    elseif ($id -eq 'restore') { Invoke-RepoRestore $name }
    elseif ($id -eq 'vis')     { if (Invoke-RepoVisibility $name $vis) { $script:ReposReload = $true; Open-Loc @{ type = 'repos' } } }
    elseif ($id -eq 'rename')  { if (Invoke-RepoRename $name) { Remove-HistLoc 'repo' $name; $script:ReposReload = $true; Open-Loc @{ type = 'repos' } } }
    elseif ($id -eq 'clear')   { if (Confirm-Action "Remove ALL files from '$name' on GitHub?") { Invoke-RepoClear $name } }
    elseif ($id -eq 'delete')  { if (Confirm-Action "DELETE the repo '$name' from GitHub?") { if (Invoke-RepoDelete $name) { Remove-HistLoc 'repo' $name; $script:ReposReload = $true; Open-Loc @{ type = 'repos' } } } }
    if ($id -in @('upload', 'vis', 'rename', 'clear', 'delete')) { $script:RepoView.Remove($name) }
}
