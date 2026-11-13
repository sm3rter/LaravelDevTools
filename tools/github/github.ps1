$ErrorActionPreference = 'Continue'
$User     = 'sm3rter'
$StartDir = (Get-Location).Path
$Host.UI.RawUI.WindowTitle = "GitHub Manager"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ---------------------------------------------------------------- Settings
$BackupRoot   = Join-Path $PSScriptRoot 'Backups'           # repo backups (.bundle files)
$SnapRoot     = Join-Path $PSScriptRoot 'Snapshots'         # local version history (hidden git repos)
$ExportRoot   = Join-Path $PSScriptRoot 'Restored'          # versions exported to a new folder
$KeepBackups  = 0       # 0 = keep every backup, N = keep only the newest N per repo
$AsciiTree    = $false  # set to $true if the tree characters look broken in your console
$TreeSkipDirs = @('.git', 'node_modules', 'vendor', '.idea', '.vs')
$SnapExclude  = @('node_modules/', 'vendor/', '.idea/', '.vs/', '*.log', 'Thumbs.db')   # never put in snapshots

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host "GitHub CLI (gh) is not installed. Run: winget install GitHub.cli" -ForegroundColor Red
    exit 1
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "git is not installed." -ForegroundColor Red
    exit 1
}
gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "You are not logged in. Starting login..." -ForegroundColor Yellow
    gh auth login
    if ($LASTEXITCODE -ne 0) { exit 1 }
}

# ---------------------------------------------------------------- UI helpers

function Write-Row {
    param([string]$Text, [string]$Fg = 'Gray', [string]$Bg = '')
    $w = [Console]::WindowWidth - 1
    if ($Text.Length -gt $w) { $Text = $Text.Substring(0, $w) }
    $Text = $Text.PadRight($w)
    if ($Bg) { Write-Host $Text -ForegroundColor $Fg -BackgroundColor $Bg }
    else     { Write-Host $Text -ForegroundColor $Fg }
}

function Show-Menu {
    param(
        [string]$Title,
        [string[]]$Items,
        [int[]]$Danger = @(),
        [int]$Start = 0,
        [string]$Hint = "Up/Down    Enter    Backspace/Left: back    Esc: exit",
        [switch]$Nav,
        [bool]$CanBack = $false,
        [bool]$CanFwd = $false,
        [bool]$CanUp = $false
    )
    $count = $Items.Count
    if ($count -eq 0) { return -1 }
    $sel = [Math]::Min([Math]::Max($Start, 0), $count - 1)
    $top = 0
    [Console]::CursorVisible = $false
    Clear-Host
    try {
        while ($true) {
            $visible = [Math]::Max(3, [Console]::WindowHeight - 8)
            if ($sel -lt $top) { $top = $sel }
            if ($sel -ge $top + $visible) { $top = $sel - $visible + 1 }
            $shown = [Math]::Min($visible, $count - $top)

            [Console]::SetCursorPosition(0, 0)
            Write-Row ""
            Write-Row ("  " + $Title) 'Cyan'
            Write-Row ("  " + ("-" * 60)) 'DarkGray'
            if ($top -gt 0) { Write-Row ("    ... " + $top + " more above") 'DarkGray' } else { Write-Row "" }

            for ($n = 0; $n -lt $shown; $n++) {
                $idx = $top + $n
                $isDanger = $Danger -contains $idx
                if ($idx -eq $sel) {
                    if ($isDanger) { Write-Row ("  > " + $Items[$idx]) 'White' 'DarkRed' }
                    else           { Write-Row ("  > " + $Items[$idx]) 'Black' 'Cyan' }
                } else {
                    if ($isDanger) { Write-Row ("    " + $Items[$idx]) 'Red' }
                    else           { Write-Row ("    " + $Items[$idx]) 'Gray' }
                }
            }
            $below = $count - $top - $shown
            if ($below -gt 0) { Write-Row ("    ... " + $below + " more below") 'DarkGray' } else { Write-Row "" }
            Write-Row ""
            Write-Row ("  " + $Hint) 'DarkGray'

            $k = [Console]::ReadKey($true)
            switch ($k.Key) {
                'UpArrow'   { if ($sel -gt 0) { $sel-- } else { $sel = $count - 1 } }
                'DownArrow' { if ($sel -lt $count - 1) { $sel++ } else { $sel = 0 } }
                'PageUp'    { $sel = [Math]::Max(0, $sel - $visible) }
                'PageDown'  { $sel = [Math]::Min($count - 1, $sel + $visible) }
                'Home'      { $sel = 0 }
                'End'       { $sel = $count - 1 }
                'Enter'     { return $sel }
                'Backspace' {
                    if ($Nav) { if ($CanUp) { return -1 } } else { return -1 }
                }
                'LeftArrow' {
                    if ($Nav) { if ($CanBack) { return -2 } } else { return -1 }
                }
                'RightArrow' {
                    if ($Nav -and $CanFwd) { return -3 }
                }
                'Escape'    { Clear-Host; exit }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $true
    }
}

function Wait-Key {
    Write-Host ""
    Write-Host "  Press any key..." -ForegroundColor DarkGray
    [void][Console]::ReadKey($true)
}

function Show-Ok {
    param([string]$Text)
    Write-Host ("  " + $Text) -ForegroundColor Green
    Start-Sleep -Milliseconds 700
}

function Show-Fail {
    param([string]$Text)
    Write-Host ("  " + $Text) -ForegroundColor Red
    Wait-Key
}

function Confirm-Action {
    param([string]$Message)
    $i = Show-Menu -Title $Message -Items @("No, cancel", "Yes, do it") -Start 0 -Hint "Up/Down: move    Enter: select    Backspace/Left: cancel    Esc: exit"
    return ($i -eq 1)
}

function Remove-Dir {
    param([string]$Path)
    if (Test-Path $Path) { cmd /c "rmdir /s /q `"$Path`"" | Out-Null }
}

function Write-Header {
    param([string]$Text)
    Clear-Host
    Write-Host ""
    Write-Host ("  " + $Text) -ForegroundColor Cyan
    Write-Host ("  " + ("-" * 60)) -ForegroundColor DarkGray
    Write-Host ""
}

# ---------------------------------------------------------------- GitHub data

function Get-Repos {
    $json = gh repo list $User --limit 200 --json name,visibility 2>$null
    if (-not $json) { return @() }
    $text = ($json -join "`n")
    $list = $text | ConvertFrom-Json
    return @($list)
}

# ---------------------------------------------------------------- Actions

function Invoke-Clone {
    param([string]$Name)
    Write-Header "Clone $Name"
    $dest = Join-Path $StartDir $Name
    if (Test-Path -LiteralPath $dest) { Show-Fail "Already exists: $dest"; return }
    Write-Host ("  Cloning into " + $StartDir) -ForegroundColor DarkGray
    git clone -q (Get-RepoUrl $Name) $dest
    if ($LASTEXITCODE -eq 0) { Show-Ok "Cloned to $dest" } else { Show-Fail "Clone failed" }
}

function Invoke-Clear {
    param([string]$Name)
    Write-Header "Clear $Name"
    $work = Join-Path $env:TEMP ("ghm_" + $Name)
    Remove-Dir $work
    New-Item -ItemType Directory -Path $work | Out-Null
    Push-Location $work
    try {
        git clone -q "https://github.com/$User/$Name.git" 2>$null
        if ($LASTEXITCODE -ne 0) { Show-Fail "Clone failed"; return }
        Set-Location $Name
        git rm -r -q . 2>$null
        if ($LASTEXITCODE -ne 0) { Show-Ok "Already empty"; return }
        git commit -q -m "Remove all files"
        git push -q 2>$null
        if ($LASTEXITCODE -eq 0) { Show-Ok "Cleared" } else { Show-Fail "Push failed" }
    }
    finally {
        Pop-Location
        Remove-Dir $work
    }
}

function Select-Folder {
    param([string]$Title = "Upload from")
    $i = Show-Menu -Title $Title -Items @(
        "This folder  ($StartDir)",
        "Browse...",
        "Type path"
    )
    switch ($i) {
        0 { return $StartDir }
        1 {
            Add-Type -AssemblyName System.Windows.Forms
            $d = New-Object System.Windows.Forms.FolderBrowserDialog
            $d.SelectedPath = $StartDir
            if ($d.ShowDialog() -eq 'OK') { return $d.SelectedPath }
            return $null
        }
        2 {
            Write-Header "Path"
            $p = Read-Host "  "
            if ($p -and (Test-Path $p -PathType Container)) { return (Resolve-Path $p).Path }
            return $null
        }
        default { return $null }
    }
}

function Get-RepoUrl {
    param([string]$Name)
    return "https://github.com/$User/$Name.git"
}

# Copies the CONTENTS of $Src into $Dest (skips .git and node_modules).
function Copy-Tree {
    param([string]$Src, [string]$Dest)
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
        else {
            Copy-Item -LiteralPath $it.FullName -Destination $Dest -Force
        }
    }
    return $true
}

# "C:\a b\x.txt";"C:\y" -> list of clean paths (drag & drop adds quotes)
function ConvertTo-PathList {
    param([string]$Text)
    $res = @()
    if (-not $Text) { return $res }
    foreach ($p in ($Text -split ';')) {
        $t = $p.Trim().Trim('"').Trim("'").Trim()
        if ($t) { $res += $t }
    }
    return $res
}

# Cleans a folder path typed for "inside the repo". '' = repo root, $null = invalid.
function ConvertTo-RepoPath {
    param([string]$Text)
    if (-not $Text) { return '' }
    $t = $Text.Trim().Trim('"').Trim("'").Replace('\', '/').Trim('/')
    if (-not $t) { return '' }
    foreach ($seg in ($t -split '/')) {
        if ($seg -eq '' -or $seg -eq '.' -or $seg -eq '..' -or $seg -match '[:*?"<>|]') { return $null }
    }
    return $t
}

function Find-7Zip {
    foreach ($n in @('7z', '7zz', '7za')) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) {
            $p = Join-Path $base '7-Zip\7z.exe'
            if (Test-Path -LiteralPath $p) { return $p }
        }
    }
    return $null
}

# Extracts an archive on THIS machine (GitHub cannot extract archives on its side).
function Expand-ArchiveTo {
    param([string]$Archive, [string]$Dest)
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    $lower = $Archive.ToLowerInvariant()
    $isZip = $lower.EndsWith('.zip')
    $isTar = ($lower -match '\.(tar|tgz|tar\.gz|tbz2|tar\.bz2|txz|tar\.xz)$')
    $isSev = ($lower -match '\.(7z|rar)$')
    if (-not ($isZip -or $isTar -or $isSev)) {
        return @{ ok = $false; msg = 'Unsupported type (supported: zip, 7z, rar, tar, tar.gz, tar.bz2, tar.xz)' }
    }
    if ($isZip) {
        try {
            Expand-Archive -LiteralPath $Archive -DestinationPath $Dest -Force -ErrorAction Stop
            return @{ ok = $true; msg = '' }
        }
        catch { }   # fall back to tar below
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
    $i = Show-Menu -Title "Pick files" -Items @(
        "Browse...  (select one or more files)",
        "Type path(s)  (separate with ;  - files or folders)"
    ) -Start 0
    $res = @()
    switch ($i) {
        0 {
            Add-Type -AssemblyName System.Windows.Forms
            $d = New-Object System.Windows.Forms.OpenFileDialog
            $d.Multiselect = $true
            $d.InitialDirectory = $StartDir
            $d.Title = "Select files to upload"
            if ($d.ShowDialog() -eq 'OK') { $res = @($d.FileNames) }
        }
        1 {
            Write-Header "Path(s)"
            Write-Host "  Files or folders, separated with ;" -ForegroundColor DarkGray
            $list = @(ConvertTo-PathList (Read-Host "  "))
            foreach ($p in $list) {
                if (-not (Test-Path -LiteralPath $p)) { Show-Fail "Not found: $p"; return @() }
                $res += (Resolve-Path -LiteralPath $p).Path
            }
        }
    }
    return $res
}

function Select-Archive {
    $i = Show-Menu -Title "Pick the archive" -Items @("Browse...", "Type path") -Start 0
    switch ($i) {
        0 {
            Add-Type -AssemblyName System.Windows.Forms
            $d = New-Object System.Windows.Forms.OpenFileDialog
            $d.InitialDirectory = $StartDir
            $d.Filter = "Archives|*.zip;*.7z;*.rar;*.tar;*.tgz;*.tbz2;*.txz;*.gz;*.bz2;*.xz|All files|*.*"
            $d.Title = "Select an archive"
            if ($d.ShowDialog() -eq 'OK') { return $d.FileName }
            return $null
        }
        1 {
            Write-Header "Archive path"
            $p = @(ConvertTo-PathList (Read-Host "  ")) | Select-Object -First 1
            if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return (Resolve-Path -LiteralPath $p).Path }
            if ($p) { Show-Fail "Not found: $p" }
            return $null
        }
        default { return $null }
    }
}

# Clones the repo to a temp folder, copies the sources in, commits and pushes.
# Sources: @{ path; kind = 'contents' (folder contents) | 'item' (a file, or a folder kept as a folder) }
# Returns @{ ok; changed; stat; msg }
function Send-ToRepo {
    param([string]$Name, $Sources, [string]$SubPath, [string]$Message)
    $Message = $Message -replace '"', "'"
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("ghm_" + $Name)
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
                else {
                    Copy-Item -LiteralPath $item.FullName -Destination $target -Force
                }
            }
        }

        # GitHub rejects any file over 100 MB
        $big = @(Get-ChildItem -LiteralPath $dest -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt 100MB -and $_.FullName -notmatch '[\\/]\.git[\\/]' })
        if ($big.Count -gt 0) {
            return @{ ok = $false; msg = ("Too big for GitHub (100 MB limit): " + $big[0].Name + " - nothing was uploaded") }
        }

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
    finally {
        Remove-Dir $work
    }
}

function Invoke-Upload {
    param([string]$Name)
    $mode = Show-Menu -Title "Upload to $Name" -Items @(
        "Folder    (its contents go into the repo)",
        "Files     (pick one or more files)",
        "Archive   (upload and extract: zip, 7z, rar, tar.gz ...)"
    ) -Start 0
    if ($mode -lt 0) { return }

    $extractDir = $null
    try {
        $sources = @()
        $message = 'Upload files'
        $what = ''
        switch ($mode) {
            0 {
                $f = Select-Folder -Title "Upload which folder?"
                if (-not $f) { return }
                $sources = @(@{ path = $f; kind = 'contents' })
                $leaf = Split-Path $f -Leaf
                if (-not $leaf) { $leaf = $f }
                $what = $f
                $message = "Upload " + $leaf
            }
            1 {
                $files = @(Select-Files)
                if ($files.Count -eq 0) { return }
                foreach ($p in $files) { $sources += @{ path = $p; kind = 'item' } }
                if ($files.Count -eq 1) {
                    $what = $files[0]
                    $message = "Upload " + (Split-Path $files[0] -Leaf)
                }
                else {
                    $what = "" + $files.Count + " items"
                    $message = "Upload " + $files.Count + " items"
                }
            }
            2 {
                $arc = Select-Archive
                if (-not $arc) { return }
                $arcName = Split-Path $arc -Leaf
                $extractDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ghm_extract_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
                Write-Header "Extracting"
                Write-Host ("  " + $arcName) -ForegroundColor DarkGray
                $x = Expand-ArchiveTo $arc $extractDir
                if (-not $x.ok) { Show-Fail $x.msg; return }
                Get-ChildItem -LiteralPath $extractDir -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -eq '__MACOSX' -or $_.Name -eq '.DS_Store' } |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                $top = @(Get-ChildItem -LiteralPath $extractDir -Force)
                if ($top.Count -eq 0) { Show-Fail "The archive is empty"; return }
                $root = $extractDir
                if ($top.Count -eq 1 -and $top[0].PSIsContainer) {
                    $n = $top[0].Name
                    $i = Show-Menu -Title ("The archive contains one folder: " + $n) -Items @(
                        ("Upload its contents (without the '" + $n + "' folder)"),
                        ("Keep the folder '" + $n + "'")
                    ) -Start 0
                    if ($i -lt 0) { return }
                    if ($i -eq 0) { $root = $top[0].FullName }
                }
                $cnt = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue).Count
                $sources = @(@{ path = $root; kind = 'contents' })
                $what = $arcName + "  (extracted: " + (Format-Files $cnt) + ")"
                $message = "Upload " + $arcName + " (extracted)"
            }
        }

        Write-Header "Upload to $Name"
        Write-Host ("  From: " + $what) -ForegroundColor DarkGray
        Write-Host ""
        $subIn = Read-Host "  Folder inside the repo (Enter = repo root)"
        $sub = ConvertTo-RepoPath $subIn
        if ($null -eq $sub) { Show-Fail "Invalid folder path"; return }

        Write-Host "  Cloning, copying and pushing..." -ForegroundColor DarkGray
        $r = Send-ToRepo $Name $sources $sub $message
        if (-not $r.ok) { Show-Fail $r.msg; return }
        if (-not $r.changed) { Show-Ok "Nothing new - everything is already in the repo"; return }
        Write-Host ("  Uploaded: " + $r.stat) -ForegroundColor Green
        Wait-Key
    }
    finally {
        if ($extractDir) { Remove-Dir $extractDir }
    }
}

function Invoke-Delete {
    param([string]$Name)
    Write-Header "Delete $Name"
    gh repo delete "$User/$Name" --yes 2>$null
    if ($LASTEXITCODE -ne 0) {
        gh auth refresh -h github.com -s delete_repo
        gh repo delete "$User/$Name" --yes 2>$null
    }
    if ($LASTEXITCODE -eq 0) { Show-Ok "Deleted"; return $true }
    Show-Fail "Delete failed"
    return $false
}

function Invoke-Visibility {
    param([string]$Name, [string]$Current)
    if ($Current -eq 'PUBLIC') { $new = 'private' } else { $new = 'public' }
    Write-Header "$Name -> $new"
    gh repo edit "$User/$Name" --visibility $new --accept-visibility-change-consequences 2>$null
    if ($LASTEXITCODE -eq 0) { Show-Ok "Now $new"; return $true }
    Show-Fail "Failed"
    return $false
}

function Invoke-Rename {
    param([string]$Name)
    Write-Header "Rename $Name"
    $new = Read-Host "  New name"
    if (-not $new) { return $false }
    gh repo rename $new --repo "$User/$Name" --yes 2>$null
    if ($LASTEXITCODE -eq 0) { Show-Ok "Renamed"; return $true }
    Show-Fail "Failed"
    return $false
}

function Invoke-NewRepo {
    Write-Header "New repo"
    $name = Read-Host "  Name"
    if (-not $name) { return }
    $i = Show-Menu -Title $name -Items @("Private", "Public") -Start 0 -Hint "Enter: select    Backspace/Left: cancel    Esc: exit"
    if ($i -eq -1) { return }
    if ($i -eq 0) { $flag = '--private' } else { $flag = '--public' }
    gh repo create "$User/$name" $flag 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Show-Ok "Created" } else { Show-Fail "Failed" }
}

# ---------------------------------------------------------------- Generic helpers

function Format-Size {
    param([double]$Bytes)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 1GB) { return ([Math]::Round($Bytes / 1GB, 2).ToString($inv) + ' GB') }
    if ($Bytes -ge 1MB) { return ([Math]::Round($Bytes / 1MB, 1).ToString($inv) + ' MB') }
    if ($Bytes -ge 1KB) { return ([Math]::Round($Bytes / 1KB, 0).ToString($inv) + ' KB') }
    return ([Math]::Round($Bytes, 0).ToString($inv) + ' B')
}

function Format-Date {
    param($Value)
    if (-not $Value) { return '-' }
    try { return ([datetime]$Value).ToLocalTime().ToString('yyyy-MM-dd HH:mm') }
    catch { return "$Value" }
}

function Format-Files {
    param([int]$Count)
    if ($Count -eq 1) { return '1 file' }
    return ($Count.ToString() + ' files')
}

function Get-FirstLine {
    param($Lines)
    foreach ($l in @($Lines)) {
        $t = "$l".Trim()
        if ($t) { return $t }
    }
    return ''
}

function Add-Line {
    param($List, [string]$Text, [string]$Color = 'Gray')
    [void]$List.Add(@{ t = $Text; c = $Color })
}

# Runs `gh ...` and parses its JSON output. Sets $script:GhOk / $script:GhError.
$script:GhOk = $true
$script:GhError = ''
function Invoke-GhJson {
    param([string[]]$GhArgs)
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
    catch {
        $script:GhOk = $false
        $script:GhError = $_.Exception.Message
        return $null
    }
    finally {
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- Scrollable viewer

function Show-Pager {
    param([string]$Title, $Lines)
    $all = @($Lines)
    $count = $all.Count
    if ($count -eq 0) { return }
    $top = 0
    [Console]::CursorVisible = $false
    Clear-Host
    try {
        while ($true) {
            $visible = [Math]::Max(3, [Console]::WindowHeight - 6)
            $maxTop = [Math]::Max(0, $count - $visible)
            if ($top -gt $maxTop) { $top = $maxTop }
            if ($top -lt 0) { $top = 0 }

            [Console]::SetCursorPosition(0, 0)
            Write-Row ""
            Write-Row ("  " + $Title) 'Cyan'
            Write-Row ("  " + ("-" * 60)) 'DarkGray'
            for ($n = 0; $n -lt $visible; $n++) {
                $idx = $top + $n
                if ($idx -lt $count) {
                    $row = $all[$idx]
                    if ($row -is [string]) {
                        Write-Row ("  " + $row) 'Gray'
                    }
                    else {
                        $fg = $row.c
                        if (-not $fg) { $fg = 'Gray' }
                        Write-Row ("  " + $row.t) $fg
                    }
                }
                else { Write-Row "" }
            }
            Write-Row ""
            $last = [Math]::Min($count, $top + $visible)
            Write-Row ("  " + ($top + 1) + "-" + $last + " of " + $count + "    Up/Down  PgUp/PgDn  Home/End    Backspace/Left: back    Esc: exit") 'DarkGray'

            $k = [Console]::ReadKey($true)
            switch ($k.Key) {
                'UpArrow'    { $top-- }
                'DownArrow'  { $top++ }
                'PageUp'     { $top -= $visible }
                'PageDown'   { $top += $visible }
                'Home'       { $top = 0 }
                'End'        { $top = $maxTop }
                'Backspace'  { return }
                'LeftArrow'  { return }
                'Escape'     { Clear-Host; exit }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $true
    }
}

# ---------------------------------------------------------------- Tree builder / renderer

if ($AsciiTree) {
    $script:TreeMid = '|-- '; $script:TreeLast = '`-- '; $script:TreePipe = '|   '
    $script:BarFull = '#'; $script:BarEmpty = '.'
}
else {
    $h = [string][char]0x2500
    $script:TreeMid  = [string][char]0x251C + $h + $h + ' '
    $script:TreeLast = [string][char]0x2514 + $h + $h + ' '
    $script:TreePipe = [string][char]0x2502 + '   '
    $script:BarFull  = [string][char]0x2588
    $script:BarEmpty = [string][char]0x2591
}
$script:TreeBlank = '    '

function New-Node {
    param([string]$Name, [bool]$Dir)
    return @{
        name  = $Name
        dir   = $Dir
        size  = [long]0
        total = [long]0
        files = 0
        note  = ''
        kids  = (New-Object System.Collections.ArrayList)
    }
}

# Builds a node tree from a flat list of entries: @{ path; type (blob|tree|commit); size }
function Build-PathNode {
    param([string]$Name, $Entries)
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

# Builds a node tree from a folder on disk.
function Build-LocalNode {
    param([string]$Path, [string]$Name, [string[]]$Skip)
    $node = New-Node $Name $true
    $items = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    foreach ($it in $items) {
        if ($it.PSIsContainer) {
            if ($Skip -contains $it.Name) {
                $s = New-Node $it.Name $true
                $s.note = 'skipped'
                [void]$node.kids.Add($s)
            }
            elseif (($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                $s = New-Node $it.Name $true
                $s.note = 'link'
                [void]$node.kids.Add($s)
            }
            else {
                [void]$node.kids.Add((Build-LocalNode $it.FullName $it.Name $Skip))
            }
        }
        else {
            $f = New-Node $it.Name $false
            $f.size = [long]$it.Length
            [void]$node.kids.Add($f)
        }
    }
    return $node
}

function Measure-Node {
    param($Node)
    if (-not $Node.dir) {
        $Node.total = [long]$Node.size
        $Node.files = 1
        return
    }
    $t = [long]0
    $f = 0
    foreach ($k in $Node.kids) {
        Measure-Node $k
        $t += $k.total
        $f += $k.files
    }
    $Node.total = $t
    $Node.files = $f
}

function Add-TreeLines {
    param($Node, [string]$Prefix, $Out, [int]$Depth, [int]$MaxDepth)
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

# Renders a finished node tree as lines for Show-Pager.
function Get-TreeLines {
    param($Root, [int]$MaxDepth)
    Measure-Node $Root
    $out = New-Object System.Collections.ArrayList
    Add-Line $out ($Root.name + '/  (' + (Format-Files $Root.files) + ', ' + (Format-Size $Root.total) + ')') 'Yellow'
    Add-TreeLines $Root '' $out 0 $MaxDepth
    return ,$out
}

# ---------------------------------------------------------------- Viewers (GitHub)

function Invoke-Pages {
    param([string]$Name)
    Write-Header "Publish - $Name"
    Write-Host "  Loading branches..." -ForegroundColor DarkGray
    $meta = Invoke-GhJson @('api', "repos/$User/$Name")
    if (-not $script:GhOk -or -not $meta) { Show-Fail ("Failed: " + $script:GhError); return }
    $br = Invoke-GhJson @('api', "repos/$User/$Name/branches?per_page=100")
    if (-not $script:GhOk -or -not $br) { Show-Fail "No branches (empty repo?)"; return }
    $names = @(@($br) | ForEach-Object { "" + $_.name })
    $def = "" + $meta.default_branch
    $pick = 'main'
    if ($names -notcontains 'main') { $pick = $def }
    $ordered = @($pick) + @($names | Where-Object { $_ -ne $pick })
    $i = Show-Menu -Title "Publish $Name - pick branch" -Items $ordered -Start 0 -Hint "Up/Down    Enter    Backspace/Left: back    Esc: exit"
    if ($i -lt 0) { return }
    $branch = $ordered[$i]
    $j = Show-Menu -Title "Publish $Name ($branch) - pick folder" -Items @("/  (root)", "/docs") -Start 0 -Hint "Up/Down    Enter    Backspace/Left: back    Esc: exit"
    if ($j -lt 0) { return }
    $path = @('/', '/docs')[$j]
    Write-Header "Publish - $Name"
    Write-Host "  Publishing $branch $path ..." -ForegroundColor DarkGray
    $null = Invoke-GhJson @('api', "repos/$User/$Name/pages")
    if ($script:GhOk) { $verb = 'PUT' } else { $verb = 'POST' }
    $null = Invoke-GhJson @('api', '-X', $verb, "repos/$User/$Name/pages", '-f', "source[branch]=$branch", '-f', "source[path]=$path")
    if (-not $script:GhOk) { Show-Fail ("Failed: " + $script:GhError); return }
    if ($Name -ieq "$User.github.io") { $url = "https://$User.github.io/" } else { $url = "https://$User.github.io/$Name/" }
    try { Set-Clipboard $url } catch { }
    Show-Ok "Published ($branch $path)"
    Write-Host ""
    Write-Host ("  " + $url) -ForegroundColor Cyan
    Write-Host "  (URL copied. First build takes 1-2 minutes)" -ForegroundColor DarkGray
    Wait-Key
}

function Show-RepoTree {
    param([string]$Name)
    $i = Show-Menu -Title "File tree - $Name" -Items @("Full tree", "Up to 3 levels", "Top level only") -Start 0 -Hint "Up/Down    Enter    Backspace/Left: back    Esc: exit"
    if ($i -lt 0) { return }
    $depth = @(0, 3, 1)[$i]
    Write-Header "File tree - $Name"
    Write-Host "  Loading..." -ForegroundColor DarkGray
    $meta = Invoke-GhJson @('api', "repos/$User/$Name")
    if (-not $script:GhOk) { Show-Fail ("Failed: " + $script:GhError); return }
    $branch = 'HEAD'
    if ($meta -and $meta.default_branch) { $branch = $meta.default_branch }
    $tree = Invoke-GhJson @('api', "repos/$User/$Name/git/trees/$($branch)?recursive=1")
    if (-not $script:GhOk) { Show-Fail ("Failed: " + $script:GhError); return }
    $entries = @()
    if ($tree -and $tree.tree) { $entries = @($tree.tree) }
    if ($entries.Count -eq 0) { Show-Fail "Nothing to show - the repo is empty"; return }
    $root = Build-PathNode $Name $entries
    $lines = Get-TreeLines $root $depth
    if ($tree.truncated) {
        Add-Line $lines ''
        Add-Line $lines 'Note: GitHub truncated this listing (very large repo).' 'Red'
    }
    Show-Pager "File tree - $Name   [$branch]" $lines
}

function Show-RepoInfo {
    param([string]$Name)
    Write-Header "Info - $Name"
    Write-Host "  Loading..." -ForegroundColor DarkGray
    $meta = Invoke-GhJson @('api', "repos/$User/$Name")
    if (-not $script:GhOk -or -not $meta) { Show-Fail ("Failed: " + $script:GhError); return }
    $langs = Invoke-GhJson @('api', "repos/$User/$Name/languages")
    $langOk = $script:GhOk
    $br = Invoke-GhJson @('api', "repos/$User/$Name/branches?per_page=100")
    $brCount = 0
    if ($script:GhOk -and $null -ne $br) { $brCount = @($br).Count }
    $brText = "$brCount"
    if ($brCount -ge 100) { $brText = '100+' }

    $vis = $meta.visibility
    if (-not $vis) { if ($meta.private) { $vis = 'private' } else { $vis = 'public' } }
    if ($meta.archived) { $vis = $vis + ', archived' }
    $license = '-'
    if ($meta.license -and $meta.license.spdx_id) { $license = $meta.license.spdx_id }
    $sizeText = Format-Size ([double]$meta.size * 1024)

    $lines = New-Object System.Collections.ArrayList
    Add-Line $lines $Name 'Yellow'
    if ($meta.description) { Add-Line $lines ("" + $meta.description) 'Gray' }
    Add-Line $lines ''
    Add-Line $lines ('Visibility'.PadRight(16) + $vis)
    Add-Line $lines ('Default branch'.PadRight(16) + $meta.default_branch + '   (' + $brText + ' branches)')
    Add-Line $lines ('Size'.PadRight(16) + $sizeText)
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
            $line = '  ' + ("" + $p.Name).PadRight(14) + ' ' + $bar + ' ' + $pctText + '%  ' + (Format-Size $p.Value)
            Add-Line $lines $line $colors[$ci % $colors.Count]
            $ci++
        }
    }
    Show-Pager "Info - $Name" $lines
}

function Show-RepoCommits {
    param([string]$Name)
    Write-Header "Commits - $Name"
    Write-Host "  Loading..." -ForegroundColor DarkGray
    $c = Invoke-GhJson @('api', "repos/$User/$Name/commits?per_page=60")
    if (-not $script:GhOk) { Show-Fail ("Failed: " + $script:GhError); return }
    $commits = @()
    if ($null -ne $c) { $commits = @($c) }
    if ($commits.Count -eq 0) { Show-Fail "No commits yet"; return }
    $lines = New-Object System.Collections.ArrayList
    foreach ($x in $commits) {
        $sha = "$($x.sha)"
        if ($sha.Length -gt 7) { $sha = $sha.Substring(0, 7) }
        $msg = ("$($x.commit.message)" -split "`r?`n")[0]
        $who = "$($x.commit.author.name)"
        if ($who.Length -gt 18) { $who = $who.Substring(0, 18) }
        $when = Format-Date $x.commit.author.date
        $mark = '*'
        $color = 'Gray'
        if (@($x.parents).Count -gt 1) { $mark = 'M'; $color = 'Magenta' }
        Add-Line $lines ($mark + ' ' + $sha + '  ' + $when + '  ' + $who.PadRight(18) + '  ' + $msg) $color
    }
    Show-Pager ("Commits - $Name   (latest " + $commits.Count + ")") $lines
}

function Show-LocalTree {
    param([string]$Path)
    $leaf = Split-Path $Path -Leaf
    if (-not $leaf) { $leaf = $Path }
    $i = Show-Menu -Title ("Folder tree - " + $leaf) -Items @(
        "Up to 3 levels (skip .git, node_modules, vendor)",
        "Full tree (skip .git, node_modules, vendor)",
        "Top level only",
        "Full tree (include everything)"
    ) -Start 0 -Hint "Up/Down    Enter    Backspace/Left: back    Esc: exit"
    if ($i -lt 0) { return }
    $depth = @(3, 0, 1, 0)[$i]
    $skip = $TreeSkipDirs
    if ($i -eq 3) { $skip = @() }
    Write-Header ("Folder tree - " + $leaf)
    Write-Host "  Scanning..." -ForegroundColor DarkGray
    $root = Build-LocalNode $Path $leaf $skip
    $lines = Get-TreeLines $root $depth
    Show-Pager ("Folder tree - " + $Path) $lines
}

# ---------------------------------------------------------------- Backups (git bundles)
# One .bundle file = a full copy of the repo (all branches + tags + history).
# Restore with: git clone file.bundle  (the tool does it for you)

function New-RepoBackup {
    param([string]$Name)
    $dir = Join-Path $BackupRoot $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $file = Join-Path $dir ($Name + '-' + $stamp + '.bundle')
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('ghb_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        git clone -q --bare "https://github.com/$User/$Name.git" $tmp 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return @{ ok = $false; msg = 'Clone failed' } }
        git -C $tmp bundle create $file --all 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $file)) {
            return @{ ok = $false; msg = 'Nothing to back up (empty repo?)' }
        }
        git -C $tmp bundle verify $file 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            return @{ ok = $false; msg = 'Backup failed verification' }
        }
        if ($KeepBackups -gt 0) {
            Get-ChildItem -LiteralPath $dir -Filter '*.bundle' -File |
                Sort-Object LastWriteTime -Descending |
                Select-Object -Skip $KeepBackups |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
        return @{ ok = $true; file = $file; size = (Get-Item -LiteralPath $file).Length }
    }
    finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Dir $tmp }
    }
}

function Invoke-Backup {
    param([string]$Name)
    Write-Header "Backup $Name"
    Write-Host "  Downloading and bundling..." -ForegroundColor DarkGray
    $r = New-RepoBackup $Name
    if (-not $r.ok) { Show-Fail $r.msg; return }
    Write-Host ("  Backup saved and verified (" + (Format-Size $r.size) + ")") -ForegroundColor Green
    Write-Host ("  " + $r.file) -ForegroundColor DarkGray
    Wait-Key
}

function Invoke-BackupAll {
    param($Repos)
    Write-Header "Backup all repos"
    $n = 0
    $okN = 0
    $bad = 0
    foreach ($r in $Repos) {
        $n++
        Write-Host ("  [" + $n + "/" + @($Repos).Count + "] " + $r.name + " ... ") -NoNewline
        $res = New-RepoBackup $r.name
        if ($res.ok) {
            Write-Host ("ok (" + (Format-Size $res.size) + ")") -ForegroundColor Green
            $okN++
        }
        else {
            Write-Host $res.msg -ForegroundColor Yellow
            $bad++
        }
    }
    Write-Host ""
    Write-Host ("  Done: " + $okN + " backed up, " + $bad + " skipped/failed") -ForegroundColor Cyan
    Write-Host ("  " + $BackupRoot) -ForegroundColor DarkGray
    Wait-Key
}

function Invoke-Restore {
    param([string]$Name)
    $dir = Join-Path $BackupRoot $Name
    $files = @()
    if (Test-Path -LiteralPath $dir) {
        $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.bundle' -File | Sort-Object LastWriteTime -Descending)
    }
    if ($files.Count -eq 0) {
        Write-Header "Restore $Name"
        Show-Fail "No backups yet - use 'Backup' first"
        return
    }
    $items = @()
    foreach ($f in $files) {
        $items += ($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm') + "   " + (Format-Size $f.Length).PadLeft(9) + "   " + $f.Name)
    }
    $items += "Open backup folder"
    $i = Show-Menu -Title "Restore $Name from backup" -Items $items -Start 0 -Hint "Up/Down    Enter: restore as a new folder    Backspace/Left: back    Esc: exit"
    if ($i -lt 0) { return }
    if ($i -eq $files.Count) { Invoke-Item -LiteralPath $dir; return }
    $f = $files[$i]
    Write-Header "Restore $Name"
    $dest = Join-Path $StartDir ($Name + '-restored-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    git clone -q $f.FullName $dest 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Show-Fail "Restore failed"; return }
    git -C $dest remote set-url origin "https://github.com/$User/$Name.git" 2>$null | Out-Null
    Write-Host "  Restored as a new folder here (GitHub was not touched):" -ForegroundColor Green
    Write-Host ("  " + $dest) -ForegroundColor DarkGray
    Wait-Key
}

# ---------------------------------------------------------------- Local snapshots (version control for any folder)
# Uses a hidden "shadow" git repo stored in Snapshots\<folder>-<hash>, so the folder's
# own .git (if any) is never touched and folders without git work too.

function Get-SnapId {
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $leaf = Split-Path $full -Leaf
    if (-not $leaf) { $leaf = 'root' }
    $leaf = $leaf -replace '[^A-Za-z0-9._-]', '_'
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($full.ToLowerInvariant()))
    $hex = ([System.BitConverter]::ToString($bytes) -replace '-', '').Substring(0, 8).ToLowerInvariant()
    return ($leaf + '-' + $hex)
}

function Get-SnapDir {
    param([string]$Folder)
    return (Join-Path $SnapRoot (Get-SnapId $Folder))
}

function Invoke-SnapGit {
    param([string]$Folder, [string[]]$GitArgs)
    $gd = Get-SnapDir $Folder
    $out = & git "--git-dir=$gd" "--work-tree=$Folder" -c core.quotepath=off @GitArgs 2>&1
    $ok = ($LASTEXITCODE -eq 0)
    $lines = @()
    if ($null -ne $out) { $lines = @($out | ForEach-Object { "$_" }) }
    return @{ ok = $ok; out = $lines }
}

function Update-SnapExclude {
    param([string]$Folder)
    $gd = Get-SnapDir $Folder
    $full = [System.IO.Path]::GetFullPath($Folder).TrimEnd('\', '/')
    $lines = @('# generated by GitHub Manager') + @($SnapExclude)
    # never snapshot the tool's own storage folders if they live inside the tracked folder
    foreach ($root in @($SnapRoot, $BackupRoot, $ExportRoot)) {
        $r = [System.IO.Path]::GetFullPath($root).TrimEnd('\', '/')
        if ($r.StartsWith($full + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = $r.Substring($full.Length + 1) -replace '\\', '/'
            $lines += ('/' + $rel + '/')
        }
    }
    $infoDir = Join-Path $gd 'info'
    New-Item -ItemType Directory -Path $infoDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $infoDir 'exclude'), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

function Initialize-Snap {
    param([string]$Folder)
    $gd = Get-SnapDir $Folder
    if (-not (Test-Path -LiteralPath (Join-Path $gd 'HEAD'))) {
        New-Item -ItemType Directory -Path $gd -Force | Out-Null
        git init -q --bare "$gd" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return $false }
        git "--git-dir=$gd" config core.autocrlf false 2>&1 | Out-Null
        git "--git-dir=$gd" config core.longpaths true 2>&1 | Out-Null
        git "--git-dir=$gd" config user.name "GitHub Manager" 2>&1 | Out-Null
        git "--git-dir=$gd" config user.email "snapshots@localhost" 2>&1 | Out-Null
        $full = [System.IO.Path]::GetFullPath($Folder).TrimEnd('\', '/')
        [System.IO.File]::WriteAllText((Join-Path $gd 'snap-path.txt'), $full, (New-Object System.Text.UTF8Encoding($false)))
    }
    Update-SnapExclude $Folder
    return $true
}

function Get-SnapFolders {
    $res = @()
    if (-not (Test-Path -LiteralPath $SnapRoot)) { return $res }
    foreach ($d in (Get-ChildItem -LiteralPath $SnapRoot -Directory -ErrorAction SilentlyContinue)) {
        $pf = Join-Path $d.FullName 'snap-path.txt'
        if (Test-Path -LiteralPath $pf) {
            $p = ([System.IO.File]::ReadAllText($pf)).Trim()
            if ($p) { $res += $p }
        }
    }
    return $res
}

# Saves a snapshot of the folder's current state. Returns @{ ok; changed; stat; msg }
function Save-Snap {
    param([string]$Folder, [string]$Message, [switch]$Force)
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { return @{ ok = $false; msg = 'Folder not found' } }
    if (-not (Initialize-Snap $Folder)) { return @{ ok = $false; msg = 'Could not create snapshot storage' } }
    $a = Invoke-SnapGit $Folder @('add', '-A')
    if (-not $a.ok) { return @{ ok = $false; msg = ('git add failed: ' + (Get-FirstLine $a.out)) } }
    $s = Invoke-SnapGit $Folder @('status', '--porcelain')
    $changed = (@($s.out | Where-Object { $_ -match '^[ MADRCU?!]{2} ' }).Count -gt 0)
    if (-not $changed -and -not $Force) { return @{ ok = $true; changed = $false; stat = '' } }
    $mf = Join-Path ([System.IO.Path]::GetTempPath()) ('snapmsg_' + [guid]::NewGuid().ToString('N') + '.txt')
    [System.IO.File]::WriteAllText($mf, $Message, (New-Object System.Text.UTF8Encoding($false)))
    try { $c = Invoke-SnapGit $Folder @('-c', 'commit.gpgsign=false', 'commit', '-q', '--allow-empty', '-F', $mf) }
    finally { Remove-Item -LiteralPath $mf -Force -ErrorAction SilentlyContinue }
    if (-not $c.ok) { return @{ ok = $false; msg = ('git commit failed: ' + (Get-FirstLine $c.out)) } }
    $st = Invoke-SnapGit $Folder @('show', '--shortstat', '--format=', 'HEAD')
    return @{ ok = $true; changed = $true; stat = (Get-FirstLine $st.out) }
}

function Get-SnapLog {
    param([string]$Folder)
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

function Get-SnapEntries {
    param([string]$Folder, [string]$Hash)
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

# Puts the folder back to the given version. A safety snapshot is taken first,
# and the restore itself is recorded as a new snapshot, so nothing is ever lost.
function Restore-SnapVersion {
    param([string]$Folder, $Ver)
    $s = Save-Snap $Folder ("Auto-save before restore to " + $Ver.hash)
    if (-not $s.ok) { return @{ ok = $false; msg = ('Safety snapshot failed: ' + $s.msg) } }
    $r = Invoke-SnapGit $Folder @('read-tree', '--reset', '-u', $Ver.hash)
    if (-not $r.ok) { return @{ ok = $false; msg = ('Restore failed: ' + (Get-FirstLine $r.out)) } }
    $n = Save-Snap $Folder ("Restored version " + $Ver.hash + " (" + $Ver.date + ")") -Force
    if (-not $n.ok) { return @{ ok = $false; msg = $n.msg } }
    return @{ ok = $true; msg = '' }
}

# Writes the given version into a new folder (current files are not touched).
function Export-SnapVersion {
    param([string]$Folder, $Ver)
    $leaf = Split-Path ([System.IO.Path]::GetFullPath($Folder).TrimEnd('\', '/')) -Leaf
    if (-not $leaf) { $leaf = 'folder' }
    $dest = Join-Path $ExportRoot ($leaf + '-' + $Ver.hash)
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

# ---------------------------------------------------------------- Snapshot screens

function Invoke-SnapSave {
    param([string]$Folder)
    Write-Header "Save snapshot"
    Write-Host ("  " + $Folder) -ForegroundColor DarkGray
    $msg = Read-Host "  Message (Enter = date/time)"
    if (-not $msg) { $msg = "Snapshot " + (Get-Date -Format 'yyyy-MM-dd HH:mm') }
    Write-Host "  Saving... (the first snapshot of a big folder can take a while)" -ForegroundColor DarkGray
    $r = Save-Snap $Folder $msg
    if (-not $r.ok) { Show-Fail $r.msg; return }
    if (-not $r.changed) { Show-Ok "Nothing changed since the last snapshot"; return }
    Write-Host ("  Saved: " + $r.stat) -ForegroundColor Green
    Wait-Key
}

function Show-SnapChanges {
    param([string]$Folder)
    Write-Header "Changes since last snapshot"
    Write-Host "  Checking..." -ForegroundColor DarkGray
    if (-not (Initialize-Snap $Folder)) { Show-Fail "Could not create snapshot storage"; return }
    $s = Invoke-SnapGit $Folder @('status', '--short', '-uall')
    $rows = @($s.out | Where-Object { $_ -match '^[ MADRCU?!]{2} ' })
    if ($rows.Count -eq 0) { Show-Ok "No changes since the last snapshot"; return }
    $lines = New-Object System.Collections.ArrayList
    Add-Line $lines 'M = modified    D = deleted    ?? / A = new file' 'DarkGray'
    Add-Line $lines ''
    foreach ($row in $rows) {
        $color = 'Yellow'
        if ($row -match '^( D|D )') { $color = 'Red' }
        elseif ($row -match '^(\?\?|A )') { $color = 'Green' }
        Add-Line $lines $row $color
    }
    Show-Pager ("Changes since last snapshot (" + $rows.Count + " files)") $lines
}

function Show-SnapText {
    param([string]$Title, $Result, [string]$EmptyText)
    $rows = @($Result.out | Where-Object { $_ -and $_.Trim() })
    if (-not $Result.ok -or $rows.Count -eq 0) {
        if (-not $Result.ok) { Show-Fail ("git: " + (Get-FirstLine $Result.out)) } else { Show-Ok $EmptyText }
        return
    }
    $lines = New-Object System.Collections.ArrayList
    foreach ($row in $rows) { Add-Line $lines $row 'Gray' }
    Show-Pager $Title $lines
}

function Show-SnapVersion {
    param([string]$Folder, $Ver)
    $items = @(
        "Files in this version (tree)",
        "What changed in this version",
        "Changes since this version (vs current files)",
        "Export to a new folder",
        "Restore in place (overwrites current files)"
    )
    $start = 0
    while ($true) {
        $i = Show-Menu -Title ("Version " + $Ver.hash + "   " + $Ver.date + "   " + $Ver.msg) -Items $items -Danger @(4) -Start $start `
            -Hint "Up/Down    Enter    Backspace/Left: back    Esc: exit"
        if ($i -lt 0) { return 'back' }
        $start = $i
        switch ($i) {
            0 {
                Write-Header "Files in version $($Ver.hash)"
                Write-Host "  Loading..." -ForegroundColor DarkGray
                $entries = @(Get-SnapEntries $Folder $Ver.hash)
                if ($entries.Count -eq 0) { Show-Fail "This version has no files" }
                else {
                    $leaf = Split-Path ([System.IO.Path]::GetFullPath($Folder).TrimEnd('\', '/')) -Leaf
                    $root = Build-PathNode $leaf $entries
                    Show-Pager ("Version " + $Ver.hash + " - " + $Ver.date) (Get-TreeLines $root 0)
                }
            }
            1 {
                $r = Invoke-SnapGit $Folder @('show', '--stat=110', '--format=', $Ver.hash)
                Show-SnapText ("What changed in " + $Ver.hash) $r "No file changes in this version"
            }
            2 {
                Write-Header "Comparing..."
                [void](Invoke-SnapGit $Folder @('add', '-A'))
                $r = Invoke-SnapGit $Folder @('diff', '--cached', '--stat=110', $Ver.hash)
                Show-SnapText ("Current files vs " + $Ver.hash) $r "Current files are identical to this version"
            }
            3 {
                Write-Header "Export version"
                $r = Export-SnapVersion $Folder $Ver
                if ($r.ok) {
                    Write-Host "  Exported to a new folder (current files untouched):" -ForegroundColor Green
                    Write-Host ("  " + $r.dest) -ForegroundColor DarkGray
                    Wait-Key
                }
                else { Show-Fail ("Export failed: " + $r.msg) }
            }
            4 {
                if (Confirm-Action ("Restore version " + $Ver.hash + "? Current files are saved first")) {
                    Write-Header "Restore"
                    Write-Host "  Saving a safety snapshot, then restoring..." -ForegroundColor DarkGray
                    $r = Restore-SnapVersion $Folder $Ver
                    if ($r.ok) { Show-Ok "Restored (a safety snapshot of the previous state was kept)"; return 'restored' }
                    else { Show-Fail $r.msg }
                }
            }
        }
    }
}

function Show-SnapVersions {
    param([string]$Folder)
    $leaf = Split-Path ([System.IO.Path]::GetFullPath($Folder).TrimEnd('\', '/')) -Leaf
    $start = 0
    while ($true) {
        $log = @(Get-SnapLog $Folder)
        if ($log.Count -eq 0) {
            Write-Header "Versions"
            Show-Fail "No snapshots yet - use 'Save snapshot' first"
            return
        }
        $items = @()
        foreach ($v in $log) { $items += ($v.hash + "   " + $v.date + "   " + $v.msg) }
        $i = Show-Menu -Title ("Versions - " + $leaf + "   (" + $log.Count + ")") -Items $items -Start $start `
            -Hint "Up/Down    Enter: open version    Backspace/Left: back    Esc: exit"
        if ($i -lt 0) { return }
        $start = $i
        $res = Show-SnapVersion $Folder $log[$i]
        if ($res -eq 'restored') { return }
    }
}

function Invoke-SnapUntrack {
    param([string]$Folder)
    if (-not (Confirm-Action "Delete ALL snapshot history of this folder? (your files stay)")) { return $false }
    Remove-Dir (Get-SnapDir $Folder)
    Show-Ok "Snapshot history deleted"
    return $true
}

function Select-SnapFolder {
    $tracked = @(Get-SnapFolders)
    $items = @()
    foreach ($t in $tracked) {
        if (Test-Path -LiteralPath $t -PathType Container) { $items += $t } else { $items += ($t + "   (missing)") }
    }
    $items += "Choose another folder..."
    $i = Show-Menu -Title "Local versions - pick a folder" -Items $items -Start 0 -Hint "Up/Down    Enter    Backspace/Left: back    Esc: exit"
    if ($i -lt 0) { return $null }
    if ($i -eq $tracked.Count) { return (Select-Folder -Title "Track which folder?") }
    $p = $tracked[$i]
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { Show-Fail "Folder not found: $p"; return $null }
    return $p
}

# ---------------------------------------------------------------- Navigation (history like File Explorer)
# Left = back in history, Right = forward, Backspace = up one level, Esc = exit

$script:hist = New-Object System.Collections.ArrayList
[void]$script:hist.Add(@{ type = 'main'; name = $null })
$script:pos = 0

function Open-Loc {
    param($Loc)
    $cur = $script:hist[$script:pos]
    if ($cur.type -eq $Loc.type -and $cur.name -eq $Loc.name) { return }
    while ($script:hist.Count -gt $script:pos + 1) {
        $script:hist.RemoveAt($script:hist.Count - 1)
    }
    [void]$script:hist.Add($Loc)
    $script:pos++
}

function Remove-HistName {
    param([string]$Name, [string]$Type = 'repo')
    for ($k = $script:hist.Count - 1; $k -ge 0; $k--) {
        $e = $script:hist[$k]
        if ($e.type -eq $Type -and $e.name -eq $Name) {
            $script:hist.RemoveAt($k)
            if ($k -le $script:pos -and $script:pos -gt 0) { $script:pos-- }
        }
    }
    if ($script:pos -ge $script:hist.Count) { $script:pos = $script:hist.Count - 1 }
}

# ---------------------------------------------------------------- Menu definitions
# Actions are looked up by id (not by position), so the list order can change safely.

$repoActions = @(
    @{ id = 'clone';   t = 'Clone' },
    @{ id = 'upload';  t = 'Upload' },
    @{ id = 'open';    t = 'Open in browser' },
    @{ id = 'url';     t = 'Copy URL' },
    @{ id = 'pages';   t = 'Publish (GitHub Pages)' },
    @{ id = 'backup';  t = 'Backup (local bundle)' },
    @{ id = 'restore'; t = 'Restore from backup' },
    @{ id = 'vis';     t = 'Public / Private' },
    @{ id = 'rename';  t = 'Rename' },
    @{ id = 'commits'; t = 'History' },
    @{ id = 'clear';   t = 'Clear';  danger = $true },
    @{ id = 'delete';  t = 'Delete'; danger = $true }
)

$snapActions = @(
    @{ id = 'save';     t = 'Save snapshot' },
    @{ id = 'changes';  t = 'Changes since last snapshot' },
    @{ id = 'versions'; t = 'Versions (browse / restore / export)' },
    @{ id = 'tree';     t = 'Folder tree' },
    @{ id = 'open';     t = 'Open folder in Explorer' },
    @{ id = 'untrack';  t = 'Stop tracking (delete snapshot history)'; danger = $true }
)

$mainExtras = @(
    @{ id = 'new';       t = '+ New repo' },
    @{ id = 'backupall'; t = 'Backup all repos (local)' },
    @{ id = 'snaps';     t = 'Local versions (snapshots)' },
    @{ id = 'ltree';     t = 'Folder tree (local)' },
    @{ id = 'refresh';   t = 'Refresh' },
    @{ id = 'quit';      t = 'Quit' }
)

function Get-ActionLabels { param($Actions) return @($Actions | ForEach-Object { $_.t }) }
function Get-ActionDanger {
    param($Actions)
    $d = @()
    for ($k = 0; $k -lt $Actions.Count; $k++) { if ($Actions[$k].danger) { $d += $k } }
    return $d
}

$script:RepoView = @{}

function Get-RepoView {
    param([string]$Name)
    if ($script:RepoView.ContainsKey($Name)) { return $script:RepoView[$Name] }
    $v = @{ tree = @(@{ t = '(no data)'; c = 'DarkGray' }); info = ''; bar = @(); leg = @() }
    $meta = Invoke-GhJson @('api', "repos/$User/$Name")
    if ($script:GhOk -and $meta) {
        $vis = $meta.visibility
        if (-not $vis) { $vis = 'public' }
        $lic = '-'
        if ($meta.license -and $meta.license.spdx_id) { $lic = $meta.license.spdx_id }
        $v.info = "$vis | $($meta.default_branch) | $(Format-Size ([double]$meta.size * 1024)) | push $(Format-Date $meta.pushed_at) | $($meta.stargazers_count) stars, $($meta.forks_count) forks | $lic"
        $tr = Invoke-GhJson @('api', "repos/$User/$Name/git/trees/$($meta.default_branch)?recursive=1")
        if ($script:GhOk -and $tr -and $tr.tree) {
            $tl = Get-TreeLines (Build-PathNode $Name @($tr.tree)) 0
            $v.tree = @($tl)
        }
        $langs = Invoke-GhJson @('api', "repos/$User/$Name/languages")
        if ($script:GhOk -and $langs) {
            $inv = [System.Globalization.CultureInfo]::InvariantCulture
            $props = @($langs.PSObject.Properties | Sort-Object Value -Descending)
            $total = [double]0
            foreach ($q in $props) { $total += [double]$q.Value }
            $cols = @('Cyan', 'Yellow', 'Green', 'Magenta', 'Blue', 'Red', 'DarkCyan', 'DarkYellow')
            $ci = 0; $bar = @(); $leg = @()
            foreach ($q in $props) {
                $pct = [double]0
                if ($total -gt 0) { $pct = [double]$q.Value / $total * 100 }
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

function Write-Segs {
    param($Segs, [int]$W)
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

function Show-RepoSplit {
    param([string]$Name, [string]$Title, [string[]]$Items, [int[]]$Danger = @(), [int]$Start = 0, [bool]$CanBack = $false, [bool]$CanFwd = $false)
    $v = Get-RepoView $Name
    $count = $Items.Count
    $sel = [Math]::Min([Math]::Max($Start, 0), $count - 1)
    $tt = 0
    [Console]::CursorVisible = $false
    Clear-Host
    try {
        while ($true) {
            $W = [Console]::WindowWidth
            $H = [Console]::WindowHeight
            $R = [int](($W - 4) * 0.65)
            $LW = $W - 4 - $R
            if ($LW -lt 30) { $LW = 30; $R = [Math]::Max(10, $W - 4 - 30) }
            $body = [Math]::Max(5, $H - 9)
            $maxTop = [Math]::Max(0, $v.tree.Count - $body)
            if ($tt -gt $maxTop) { $tt = $maxTop }
            if ($tt -lt 0) { $tt = 0 }
            $top = 0
            if ($sel -ge $body) { $top = $sel - $body + 1 }

            [Console]::SetCursorPosition(0, 0)
            Write-Row ''
            Write-Row ('  ' + $Title) 'Cyan'
            Write-Row ('  ' + ('-' * [Math]::Max(10, $W - 5))) 'DarkGray'
            for ($n = 0; $n -lt $body; $n++) {
                $ix = $top + $n
                $cell = ''.PadRight($LW)
                $fg = 'Gray'; $bg = ''
                if ($ix -lt $count) {
                    $lab = [string]$Items[$ix]
                    $pre = '    '
                    if ($ix -eq $sel) { $pre = '  > ' }
                    $cell = ($pre + $lab)
                    if ($cell.Length -gt $LW) { $cell = $cell.Substring(0, $LW) }
                    $cell = $cell.PadRight($LW)
                    $isDanger = $Danger -contains $ix
                    if ($ix -eq $sel) {
                        if ($isDanger) { $fg = 'White'; $bg = 'DarkRed' } else { $fg = 'Black'; $bg = 'Cyan' }
                    }
                    elseif ($isDanger) { $fg = 'Red' }
                }
                if ($bg) { Write-Host $cell -NoNewline -ForegroundColor $fg -BackgroundColor $bg }
                else { Write-Host $cell -NoNewline -ForegroundColor $fg }
                Write-Host ' | ' -NoNewline -ForegroundColor DarkGray
                $ti = $tt + $n
                if ($ti -lt $v.tree.Count) {
                    $tl = $v.tree[$ti]
                    $tx = [string]$tl.t
                    if ($tx.Length -gt $R) { $tx = $tx.Substring(0, $R) }
                    Write-Host $tx.PadRight($R) -ForegroundColor $tl.c
                }
                else { Write-Host (' ' * $R) }
            }
            Write-Row ('  ' + ('-' * [Math]::Max(10, $W - 5))) 'DarkGray'
            Write-Segs @(@{ t = ('  ' + $v.info); c = 'Gray' }) ($W - 1)
            Write-Segs (@(@{ t = '  '; c = 'Gray' }) + @($v.bar)) ($W - 1)
            Write-Segs (@(@{ t = '  '; c = 'Gray' }) + @($v.leg)) ($W - 1)
            Write-Row '  Up/Down    Enter    PgUp/PgDn: scroll tree    Left/Right: history    Backspace: up    Esc: exit' 'DarkGray'

            $k = [Console]::ReadKey($true)
            switch ($k.Key) {
                'UpArrow'    { if ($sel -gt 0) { $sel-- } else { $sel = $count - 1 } }
                'DownArrow'  { if ($sel -lt $count - 1) { $sel++ } else { $sel = 0 } }
                'PageUp'     { $tt -= $body }
                'PageDown'   { $tt += $body }
                'Home'       { $tt = 0 }
                'End'        { $tt = $maxTop }
                'Enter'      { return $sel }
                'Backspace'  { return -1 }
                'LeftArrow'  { if ($CanBack) { return -2 } }
                'RightArrow' { if ($CanFwd) { return -3 } }
                'Escape'     { Clear-Host; exit }
            }
        }
    }
    finally { [Console]::CursorVisible = $true }
}

$repoLabels = Get-ActionLabels $repoActions
$repoDanger = Get-ActionDanger $repoActions
$snapLabels = Get-ActionLabels $snapActions
$snapDanger = Get-ActionDanger $snapActions

# ---------------------------------------------------------------- Main loop

$lastSel = @{}
$repos   = @()
$reload  = $true
$mainLoc    = @{ type = 'main'; name = $null }

while ($true) {
    if ($reload) {
        Clear-Host
        Write-Host ""
        Write-Host "  Loading repos..." -ForegroundColor Yellow
        $repos  = @(Get-Repos)
        $script:RepoView = @{}
        $reload = $false
    }

    $loc     = $script:hist[$script:pos]
    $canBack = ($script:pos -gt 0)
    $canFwd  = ($script:pos -lt $script:hist.Count - 1)

    if ($loc.type -eq 'repo') {
        # ---------------- repo menu
        $repo = $repos | Where-Object { $_.name -eq $loc.name } | Select-Object -First 1
        if (-not $repo) {
            Remove-HistName $loc.name
            continue
        }
        $name  = $repo.name
        $vis   = $repo.visibility
        $key   = 'repo:' + $name
        $start = 0
        if ($lastSel.ContainsKey($key)) { $start = $lastSel[$key] }

        if (-not $script:RepoView.ContainsKey($name)) { Clear-Host; Write-Host "  Loading..." -ForegroundColor DarkGray }
        $i = Show-RepoSplit -Name $name -Title ("$name   [" + $vis.ToLower() + "]") -Items $repoLabels -Danger $repoDanger -Start $start -CanBack $canBack -CanFwd $canFwd

        if ($i -eq -2) { $script:pos--; continue }
        if ($i -eq -3) { $script:pos++; continue }
        if ($i -eq -1) { Open-Loc $mainLoc; continue }

        $lastSel[$key] = $i
        $script:RepoView.Remove($name)
        switch ($repoActions[$i].id) {
            'clone'   { Invoke-Clone $name }
            'upload'  { Invoke-Upload $name }
            'open'    { gh repo view "$User/$name" --web }
            'url'     {
                Set-Clipboard "https://github.com/$User/$name.git"
                Write-Header "Copy URL"
                Show-Ok "Copied"
            }
            'pages'   { Invoke-Pages $name }
            'commits' { Show-RepoCommits $name }
            'backup'  { Invoke-Backup $name }
            'restore' { Invoke-Restore $name }
            'vis'     {
                if (Invoke-Visibility $name $vis) {
                    $reload = $true
                    Open-Loc $mainLoc
                }
            }
            'rename'  {
                if (Invoke-Rename $name) {
                    Remove-HistName $name
                    $reload = $true
                    Open-Loc $mainLoc
                }
            }
            'clear'   { Invoke-Clear $name }
            'delete'  {
                if (Invoke-Delete $name) {
                    Remove-HistName $name
                    $reload = $true
                    Open-Loc $mainLoc
                }
            }
        }
        continue
    }

    if ($loc.type -eq 'snap') {
        # ---------------- snapshot menu for a local folder
        $folder = $loc.name
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
            Remove-HistName $folder 'snap'
            continue
        }
        $key   = 'snap:' + $folder
        $start = 0
        if ($lastSel.ContainsKey($key)) { $start = $lastSel[$key] }
        $nVer  = @(Get-SnapLog $folder).Count

        $verText = "$nVer versions"
        if ($nVer -eq 1) { $verText = "1 version" }
        $i = Show-Menu -Title ($folder + "   (" + $verText + ")") -Items $snapLabels -Danger $snapDanger -Start $start `
            -Nav -CanBack $canBack -CanFwd $canFwd -CanUp $true `
            -Hint "Up/Down    Enter    Left/Right: history    Backspace: up    Esc: exit"

        if ($i -eq -2) { $script:pos--; continue }
        if ($i -eq -3) { $script:pos++; continue }
        if ($i -eq -1) { Open-Loc $mainLoc; continue }

        $lastSel[$key] = $i
        switch ($snapActions[$i].id) {
            'save'     { Invoke-SnapSave $folder }
            'changes'  { Show-SnapChanges $folder }
            'versions' { Show-SnapVersions $folder }
            'tree'     { Show-LocalTree $folder }
            'open'     { Invoke-Item -LiteralPath $folder }
            'untrack'  {
                if (Invoke-SnapUntrack $folder) {
                    Remove-HistName $folder 'snap'
                    Open-Loc $mainLoc
                }
            }
        }
        continue
    }

    # ---------------- main menu (repo list + tools)
    $maxLen = 10
    foreach ($r in $repos) { if ($r.name.Length -gt $maxLen) { $maxLen = $r.name.Length } }

    $items = @()
    foreach ($r in $repos) {
        $items += ($r.name.PadRight($maxLen) + "   " + $r.visibility.ToLower())
    }
    foreach ($x in $mainExtras) { $items += $x.t }

    $key   = 'main'
    $start = 0
    if ($lastSel.ContainsKey($key)) { $start = $lastSel[$key] }

    $i = Show-Menu -Title ("GitHub Manager - " + $User + "   (" + $repos.Count + " repos)") -Items $items -Start $start `
        -Nav -CanBack $canBack -CanFwd $canFwd -CanUp $false `
        -Hint "Up/Down    Enter    Left/Right: history    Esc: exit"

    if ($i -eq -2) { $script:pos--; continue }
    if ($i -eq -3) { $script:pos++; continue }
    if ($i -lt 0)  { continue }

    $lastSel[$key] = $i

    if ($i -lt $repos.Count) {
        Open-Loc @{ type = 'repo'; name = $repos[$i].name }
        continue
    }

    $id = $mainExtras[$i - $repos.Count].id
    if ($id -eq 'quit') { break }

    switch ($id) {
        'new'       { Invoke-NewRepo; $reload = $true }
        'backupall' {
            if ($repos.Count -gt 0 -and (Confirm-Action ("Back up all " + $repos.Count + " repos? (downloads everything)"))) {
                Invoke-BackupAll $repos
            }
        }
        'snaps'     {
            $f = Select-SnapFolder
            if ($f) { Open-Loc @{ type = 'snap'; name = $f } }
        }
        'ltree'     {
            $f = Select-Folder -Title "Show tree of which folder?"
            if ($f) { Show-LocalTree $f }
        }
        'refresh'   { $reload = $true }
    }
}

Clear-Host
[Console]::CursorVisible = $true
