$script:SnapExclude = @('node_modules/', 'vendor/', '.idea/', '.vs/', '*.log', 'Thumbs.db')

function Get-SnapId([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $leaf = Split-Path $full -Leaf
    if (-not $leaf) { $leaf = 'root' }
    $leaf = $leaf -replace '[^A-Za-z0-9._-]', '_'
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($full.ToLowerInvariant()))
    $hex = ([System.BitConverter]::ToString($bytes) -replace '-', '').Substring(0, 8).ToLowerInvariant()
    return ($leaf + '-' + $hex)
}

function Get-SnapDir([string]$Folder) { return (Join-Path (Get-SnapRoot) (Get-SnapId $Folder)) }

function Invoke-SnapGit([string]$Folder, [string[]]$GitArgs) {
    $gd = Get-SnapDir $Folder
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & git "--git-dir=$gd" "--work-tree=$Folder" -c core.quotepath=off @GitArgs 2>&1
    $ok = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $old
    $lines = @()
    if ($null -ne $out) { $lines = @($out | ForEach-Object { "$_" }) }
    return @{ ok = $ok; out = $lines }
}

function Update-SnapExclude([string]$Folder) {
    $gd = Get-SnapDir $Folder
    $full = [System.IO.Path]::GetFullPath($Folder).TrimEnd('\', '/')
    $lines = @('# dev snapshots') + @($script:SnapExclude)

    foreach ($root in @((Get-SnapRoot), (Get-BackupDir), (Get-ExportRoot))) {
        if (-not $root) { continue }
        $r = [System.IO.Path]::GetFullPath($root).TrimEnd('\', '/')
        if ($r.StartsWith($full + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            $lines += ('/' + ($r.Substring($full.Length + 1) -replace '\\', '/') + '/')
        }
    }
    $infoDir = Join-Path $gd 'info'
    New-Item -ItemType Directory -Path $infoDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $infoDir 'exclude'), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

function Initialize-Snap([string]$Folder) {
    $gd = Get-SnapDir $Folder
    if (-not (Test-Path -LiteralPath (Join-Path $gd 'HEAD'))) {
        try { New-Item -ItemType Directory -Path $gd -Force -ErrorAction Stop | Out-Null } catch { return $false }
        git init -q --bare "$gd" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return $false }
        git "--git-dir=$gd" config core.autocrlf false 2>&1 | Out-Null
        git "--git-dir=$gd" config core.longpaths true 2>&1 | Out-Null
        git "--git-dir=$gd" config user.name 'Dev' 2>&1 | Out-Null
        git "--git-dir=$gd" config user.email 'snapshots@localhost' 2>&1 | Out-Null
        $full = [System.IO.Path]::GetFullPath($Folder).TrimEnd('\', '/')
        [System.IO.File]::WriteAllText((Join-Path $gd 'snap-path.txt'), $full, (New-Object System.Text.UTF8Encoding($false)))
    }
    Update-SnapExclude $Folder
    return $true
}

function Get-SnapFolders {
    $res = @()
    $root = Get-SnapRoot
    if (-not (Test-Path -LiteralPath $root)) { return $res }
    foreach ($d in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        $pf = Join-Path $d.FullName 'snap-path.txt'
        if (Test-Path -LiteralPath $pf) {
            $p = ([System.IO.File]::ReadAllText($pf)).Trim()
            if ($p) { $res += $p }
        }
    }
    return $res
}

function Save-Snap([string]$Folder, [string]$Message, [switch]$Force) {
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { return @{ ok = $false; msg = 'Folder not found' } }
    if (-not (Initialize-Snap $Folder)) { return @{ ok = $false; msg = 'Could not create snapshot storage (check the backup folder in Settings)' } }
    $a = Invoke-SnapGit $Folder @('add', '-A')
    if (-not $a.ok) { return @{ ok = $false; msg = ('git add failed: ' + (Get-FirstLine $a.out)) } }
    $s = Invoke-SnapGit $Folder @('status', '--porcelain')
    $changed = (@($s.out | Where-Object { $_ -match '^[ MADRCU?!]{2} ' }).Count -gt 0)
    if ((-not $changed) -and (-not $Force)) { return @{ ok = $true; changed = $false; stat = '' } }
    $mf = Join-Path ([System.IO.Path]::GetTempPath()) ('snapmsg_' + [guid]::NewGuid().ToString('N') + '.txt')
    [System.IO.File]::WriteAllText($mf, $Message, (New-Object System.Text.UTF8Encoding($false)))
    try { $c = Invoke-SnapGit $Folder @('-c', 'commit.gpgsign=false', 'commit', '-q', '--allow-empty', '-F', $mf) }
    finally { Remove-Item -LiteralPath $mf -Force -ErrorAction SilentlyContinue }
    if (-not $c.ok) { return @{ ok = $false; msg = ('git commit failed: ' + (Get-FirstLine $c.out)) } }
    $st = Invoke-SnapGit $Folder @('show', '--shortstat', '--format=', 'HEAD')
    return @{ ok = $true; changed = $true; stat = (Get-FirstLine $st.out) }
}

function Get-SnapLog([string]$Folder) {
    $gd = Get-SnapDir $Folder
    if (-not (Test-Path -LiteralPath (Join-Path $gd 'HEAD'))) { return @() }
    $r = Invoke-SnapGit $Folder @('log', '--date=format:%Y-%m-%d %H:%M', '--pretty=format:%h|%ad|%s', '-n', '300')
    if (-not $r.ok) { return @() }
    $res = @()
    foreach ($l in $r.out) {
        $p = $l.Split('|', 3)
        if ($p.Count -eq 3) { $res += @{ hash = $p[0]; date = $p[1]; msg = $p[2] } }
    }
    return $res
}

function Get-SnapEntries([string]$Folder, [string]$Hash) {
    $r = Invoke-SnapGit $Folder @('ls-tree', '-r', '-l', $Hash)
    $res = @()
    foreach ($l in $r.out) {
        if ($l -match '^\d+\s+(\w+)\s+[0-9a-f]+\s+(-|\d+)\t(.+)$') {
            $size = 0
            if ($Matches[2] -ne '-') { $size = [long]$Matches[2] }
            $res += @{ path = $Matches[3]; type = $Matches[1]; size = $size }
        }
    }
    return $res
}

function Restore-SnapVersion([string]$Folder, $Ver) {
    $s = Save-Snap $Folder ('Auto-save before restore to ' + $Ver.hash)
    if (-not $s.ok) { return @{ ok = $false; msg = ('Safety snapshot failed: ' + $s.msg) } }
    $r = Invoke-SnapGit $Folder @('read-tree', '--reset', '-u', $Ver.hash)
    if (-not $r.ok) { return @{ ok = $false; msg = ('Restore failed: ' + (Get-FirstLine $r.out)) } }
    $n = Save-Snap $Folder ('Restored version ' + $Ver.hash + ' (' + $Ver.date + ')') -Force
    if (-not $n.ok) { return @{ ok = $false; msg = $n.msg } }
    return @{ ok = $true; msg = '' }
}

function Export-SnapVersion([string]$Folder, $Ver) {
    $leaf = Split-Path ([System.IO.Path]::GetFullPath($Folder).TrimEnd('\', '/')) -Leaf
    if (-not $leaf) { $leaf = 'folder' }
    $dest = Join-Path (Get-ExportRoot) ($leaf + '-' + $Ver.hash)
    if (Test-Path -LiteralPath $dest) { $dest = $dest + '-' + (Get-Date -Format 'HHmmss') }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $idx = Join-Path ([System.IO.Path]::GetTempPath()) ('snapidx_' + [guid]::NewGuid().ToString('N'))
    $env:GIT_INDEX_FILE = $idx
    try {
        $r1 = Invoke-SnapGit $Folder @('read-tree', $Ver.hash)
        $prefix = ($dest -replace '\\', '/') + '/'
        $r2 = Invoke-SnapGit $Folder @('checkout-index', '-a', '-f', "--prefix=$prefix")
    }
    finally {
        Remove-Item Env:\GIT_INDEX_FILE -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $idx -Force -ErrorAction SilentlyContinue
    }
    if (-not ($r1.ok -and $r2.ok)) { return @{ ok = $false; dest = $dest; msg = (Get-FirstLine ($r1.out + $r2.out)) } }
    return @{ ok = $true; dest = $dest; msg = '' }
}

function Invoke-SnapSave([string]$Folder) {
    $msg = Read-Input 'Save snapshot' 'message (Enter = date/time)' @($Folder)
    if ($null -eq $msg) { return }
    if (-not $msg) { $msg = 'Snapshot ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') }
    Write-Header 'Save snapshot'
    Write-Host '  Saving... (the first snapshot of a big folder can take a while)' -ForegroundColor DarkGray
    $r = Save-Snap $Folder $msg
    if (-not $r.ok) { Show-Fail $r.msg; return }
    if (-not $r.changed) { Show-Ok 'Nothing changed since the last snapshot'; return }
    Write-Host ('  Saved: ' + $r.stat) -ForegroundColor Green
    Wait-Key
}

function Show-SnapChanges([string]$Folder) {
    Write-Header 'Changes since last snapshot'
    Write-Host '  Checking...' -ForegroundColor DarkGray
    if (-not (Initialize-Snap $Folder)) { Show-Fail 'Could not create snapshot storage'; return }
    $s = Invoke-SnapGit $Folder @('status', '--short', '-uall')
    $rows = @($s.out | Where-Object { $_ -match '^[ MADRCU?!]{2} ' })
    if ($rows.Count -eq 0) { Show-Ok 'No changes since the last snapshot'; return }
    $lines = New-Object System.Collections.ArrayList
    Add-Line $lines 'M = modified    D = deleted    ?? / A = new file' 'DarkGray'
    Add-Line $lines ''
    foreach ($row in $rows) {
        $color = 'Yellow'
        if ($row -match '^( D|D )') { $color = 'Red' } elseif ($row -match '^(\?\?|A )') { $color = 'Green' }
        Add-Line $lines $row $color
    }
    Show-Pager ('Changes since last snapshot (' + $rows.Count + ' files)') $lines
}

function Show-SnapText([string]$Title, $Result, [string]$EmptyText) {
    $rows = @($Result.out | Where-Object { $_ -and $_.Trim() })
    if ((-not $Result.ok) -or ($rows.Count -eq 0)) {
        if (-not $Result.ok) { Show-Fail ('git: ' + (Get-FirstLine $Result.out)) } else { Show-Ok $EmptyText }
        return
    }
    $lines = New-Object System.Collections.ArrayList
    foreach ($row in $rows) { Add-Line $lines $row 'Gray' }
    Show-Pager $Title $lines
}

function Show-SnapVersion([string]$Folder, $Ver) {
    $items = @('Files in this version (tree)', 'What changed in this version', 'Changes since this version (vs current files)',
               'Export to a new folder', 'Restore in place (overwrites current files)')
    $start = 0
    while ($true) {
        $i = Show-Menu -Title ('Version ' + $Ver.hash + '   ' + $Ver.date + '   ' + $Ver.msg) -Items $items -Danger @(4) -Start $start
        if ($i -lt 0) { return 'back' }
        $start = $i
        if ($i -eq 0) {
            Write-Header "Files in version $($Ver.hash)"
            Write-Host '  Loading...' -ForegroundColor DarkGray
            $entries = @(Get-SnapEntries $Folder $Ver.hash)
            if ($entries.Count -eq 0) { Show-Fail 'This version has no files' }
            else {
                $leaf = Split-Path ([System.IO.Path]::GetFullPath($Folder).TrimEnd('\', '/')) -Leaf
                $root = Build-PathNode $leaf $entries
                Show-Pager ('Version ' + $Ver.hash + ' - ' + $Ver.date) (Get-TreeLines $root 0)
            }
        }
        elseif ($i -eq 1) {
            $r = Invoke-SnapGit $Folder @('show', '--stat=110', '--format=', $Ver.hash)
            Show-SnapText ('What changed in ' + $Ver.hash) $r 'No file changes in this version'
        }
        elseif ($i -eq 2) {
            Write-Header 'Comparing...'
            [void](Invoke-SnapGit $Folder @('add', '-A'))
            $r = Invoke-SnapGit $Folder @('diff', '--cached', '--stat=110', $Ver.hash)
            Show-SnapText ('Current files vs ' + $Ver.hash) $r 'Current files are identical to this version'
        }
        elseif ($i -eq 3) {
            Write-Header 'Export version'
            $r = Export-SnapVersion $Folder $Ver
            if ($r.ok) {
                Write-Host '  Exported to a new folder (current files untouched):' -ForegroundColor Green
                Write-Host ('  ' + $r.dest) -ForegroundColor DarkGray
                Wait-Key
            }
            else { Show-Fail ('Export failed: ' + $r.msg) }
        }
        elseif ($i -eq 4) {
            if (Confirm-Action ('Restore version ' + $Ver.hash + '? Current files are saved first')) {
                Write-Header 'Restore'
                Write-Host '  Saving a safety snapshot, then restoring...' -ForegroundColor DarkGray
                $r = Restore-SnapVersion $Folder $Ver
                if ($r.ok) { Show-Ok 'Restored (a safety snapshot of the previous state was kept)'; return 'restored' }
                else { Show-Fail $r.msg }
            }
        }
    }
}

function Show-SnapVersions([string]$Folder) {
    $leaf = Split-Path ([System.IO.Path]::GetFullPath($Folder).TrimEnd('\', '/')) -Leaf
    $start = 0
    while ($true) {
        $log = @(Get-SnapLog $Folder)
        if ($log.Count -eq 0) { Write-Header 'Versions'; Show-Fail "No snapshots yet - use 'Save snapshot' first"; return }
        $items = @()
        foreach ($v in $log) { $items += ($v.hash + '   ' + $v.date + '   ' + $v.msg) }
        $i = Show-Menu -Title ('Versions - ' + $leaf + '   (' + $log.Count + ')') -Items $items -Start $start -Hint 'Up/Down    Enter: open version    Backspace/Left: back    Esc: exit'
        if ($i -lt 0) { return }
        $start = $i
        $res = Show-SnapVersion $Folder $log[$i]
        if ($res -eq 'restored') { return }
    }
}

function Invoke-SnapUntrack([string]$Folder) {
    if (-not (Confirm-Action 'Delete ALL snapshot history of this folder? (your files stay)')) { return $false }
    Remove-Dir (Get-SnapDir $Folder)
    Show-Ok 'Snapshot history deleted'
    return $true
}

$script:SnapActions = @(
    @{ id = 'save';     t = 'Save snapshot' },
    @{ id = 'changes';  t = 'Changes since last snapshot' },
    @{ id = 'versions'; t = 'Versions (browse / restore / export)' },
    @{ id = 'tree';     t = 'Folder tree' },
    @{ id = 'open';     t = 'Open folder in Explorer' },
    @{ id = 'untrack';  t = 'Stop tracking (delete snapshot history)'; danger = $true }
)

function Show-SnapsScreen {
    $tracked = @(Get-SnapFolders)
    $items = @()
    foreach ($t in $tracked) {
        if (Test-Path -LiteralPath $t -PathType Container) { $items += @{ label = $t; note = ((@(Get-SnapLog $t)).Count.ToString() + ' versions'); color = 'DarkGray' } }
        else { $items += @{ label = $t; note = '(missing)'; color = 'Red' } }
    }
    $items += @{ label = 'Choose another folder...'; note = ''; color = 'Green' }
    $key = 'snaps'
    $m = @{ Title = 'Local versions - pick a folder'; Subtitle = (Get-SnapRoot); Items = $items; Start = (Get-LastSel $key) }
    $m += (Get-NavArgs $true)
    $i = Show-Menu @m
    if (Invoke-NavKey $i @{ type = 'home' }) { return }
    Set-LastSel $key $i
    if ($i -eq $tracked.Count) {
        $f = Select-FolderMenu -Title 'Track which folder?' -StartDir '' -Initial (Get-WwwDir)
        if ($f) { Open-Loc @{ type = 'snap'; name = $f } }
        return
    }
    $p = $tracked[$i]
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { Clear-Host; Show-Fail "Folder not found: $p"; return }
    Open-Loc @{ type = 'snap'; name = $p }
}

function Show-SnapScreen($Loc) {
    $folder = $Loc.name
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { Remove-HistLoc 'snap' $folder; return }
    $nVer = @(Get-SnapLog $folder).Count
    $verText = "$nVer versions"
    if ($nVer -eq 1) { $verText = '1 version' }
    $items = @(); $danger = @()
    for ($k = 0; $k -lt $script:SnapActions.Count; $k++) {
        $items += $script:SnapActions[$k].t
        if ($script:SnapActions[$k].danger) { $danger += $k }
    }
    $key = 'snap:' + $folder
    $m = @{ Title = ($folder + '   (' + $verText + ')'); Items = $items; Danger = $danger; Start = (Get-LastSel $key) }
    $m += (Get-NavArgs $true)
    $i = Show-Menu @m
    if (Invoke-NavKey $i @{ type = 'snaps' }) { return }
    Set-LastSel $key $i
    $id = $script:SnapActions[$i].id
    if     ($id -eq 'save')     { Invoke-SnapSave $folder }
    elseif ($id -eq 'changes')  { Show-SnapChanges $folder }
    elseif ($id -eq 'versions') { Show-SnapVersions $folder }
    elseif ($id -eq 'tree')     { Show-LocalTree $folder }
    elseif ($id -eq 'open')     { Invoke-Item -LiteralPath $folder }
    elseif ($id -eq 'untrack')  { if (Invoke-SnapUntrack $folder) { Remove-HistLoc 'snap' $folder; Open-Loc @{ type = 'snaps' } } }
}
