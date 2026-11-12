function Get-LocalIPs {
    $res = @()
    try {
        $res = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notmatch '^(127|169)\.' } | ForEach-Object { [string]$_.IPAddress })
    } catch { }
    if ($res.Count -eq 0) {
        foreach ($l in @(ipconfig)) { if ($l -match 'IPv4.*:\s*([0-9.]+)\s*$') { $res += $Matches[1] } }
    }
    return $res
}

function Show-NetworkInfo {
    $flash = ''
    while ($true) {
        $ips = @(Get-LocalIPs)
        if ($ips.Count -eq 0) { Clear-Host; Show-Fail 'No IPv4 address found'; return }
        $items = @()
        foreach ($ip in $ips) { $items += @{ label = $ip; note = 'Enter = copy'; color = 'DarkGray' } }
        $on = 'OFFLINE'; if (Test-Online -Force) { $on = 'online' }
        $i = Show-Menu -Title 'Your local IP address' -Subtitle "internet: $on   (use http://<ip> from a phone on the same Wi-Fi)" -Items $items -Flash $flash
        if ($i -lt 0) { return }
        Set-Clipboard $ips[$i]
        $flash = 'copied ' + $ips[$i]
    }
}

function Copy-BackupName {
    $name = 'backup_' + (Get-Date).ToString('yyyy-MM-dd_ddd_HH-mm-ss', [System.Globalization.CultureInfo]::InvariantCulture)
    Set-Clipboard $name
    Clear-Host
    Write-Host ''
    Write-Host "  $name" -ForegroundColor Cyan
    Show-Ok 'copied to the clipboard'
}

function Show-LogFile {
    if (-not (Test-Path -LiteralPath $script:LogFile)) { Clear-Host; Show-Ok 'No log yet'; return }
    $lines = @(Get-Content -LiteralPath $script:LogFile -Tail 400 -ErrorAction SilentlyContinue)
    [array]::Reverse($lines)
    Show-Pager 'dev.log (newest first)' $lines
}

function Show-ToolsScreen {
    $items = @(
        @{ label = 'Local IP address';          note = 'copy it for phone testing'; color = 'DarkGray' },
        @{ label = 'Copy a backup name';        note = 'backup_YYYY-MM-DD_Day_HH-mm-ss -> clipboard'; color = 'DarkGray' },
        @{ label = 'Folder tree (local)';       note = 'any folder'; color = 'DarkGray' },
        @{ label = 'Open Laragon';              note = (Get-LaragonDir); color = 'DarkGray' },
        @{ label = 'Open the log';              note = $script:LogFile; color = 'DarkGray' },
        @{ label = 'Open the Dev folder';  note = $script:Root; color = 'DarkGray' }
    )
    $key = 'tools'
    $m = @{ Title = 'Tools'; Items = $items; Start = (Get-LastSel $key) }
    $m += (Get-NavArgs $true)
    $i = Show-Menu @m
    if (Invoke-NavKey $i @{ type = 'home' }) { return }
    Set-LastSel $key $i
    if     ($i -eq 0) { Show-NetworkInfo }
    elseif ($i -eq 1) { Copy-BackupName }
    elseif ($i -eq 2) { $f = Select-FolderMenu -Title 'Show tree of which folder?' -StartDir '' -Initial (Get-WwwDir); if ($f) { Show-LocalTree $f } }
    elseif ($i -eq 3) {
        $exe = Get-LaragonExe
        if ($exe) { Start-Process -FilePath $exe -WorkingDirectory (Get-LaragonDir) } else { Clear-Host; Show-Fail ('Laragon not found at ' + (Get-LaragonDir)) }
    }
    elseif ($i -eq 4) { Show-LogFile }
    elseif ($i -eq 5) { Invoke-Item -LiteralPath $script:Root }
}

$script:SettingDefs = @(
    @{ key = 'laragonDir';      label = 'Laragon folder';        type = 'folder' },
    @{ key = 'wwwDir';          label = 'Projects folder (empty = laragon\www)'; type = 'folder' },
    @{ key = 'backupDir';       label = 'Backup folder';         type = 'folder' },
    @{ key = 'githubBackupDir'; label = 'GitHub backups folder (empty = inside backup folder)'; type = 'folder' },
    @{ key = 'desktopDir';      label = 'Zip / patches folder (empty = Desktop)'; type = 'folder' },
    @{ key = 'githubUser';      label = 'GitHub user';           type = 'text' },
    @{ key = 'domainSuffix';    label = 'Virtual host suffix';   type = 'text' },
    @{ key = 'webPort';         label = 'Web server port';       type = 'int' },
    @{ key = 'mysqlPort';       label = 'MySQL port';            type = 'int' },
    @{ key = 'mysqlUser';       label = 'MySQL user';            type = 'text' },
    @{ key = 'mysqlPassword';   label = 'MySQL password';        type = 'secret' },
    @{ key = 'editor';          label = 'Editor command';        type = 'text' },
    @{ key = 'autoSyncOnStart'; label = 'Auto-upload offline work at start'; type = 'bool' },
    @{ key = 'snapshotsDir';    label = 'Snapshots folder (empty = inside backup folder)'; type = 'folder' },
    @{ key = 'restoredDir';     label = 'Exports folder (empty = inside backup folder)';   type = 'folder' }
)

function Show-SettingsScreen {
    $items = @()
    foreach ($d in $script:SettingDefs) {
        $v = Get-Cfg $d.key
        $txt = [string]$v
        if ($d.type -eq 'secret') { if ($txt) { $txt = '********' } else { $txt = '(empty)' } }
        elseif ($d.type -eq 'bool') { if ($v) { $txt = 'on' } else { $txt = 'off' } }
        elseif (-not $txt) { $txt = '(empty)' }
        $items += @{ label = $d.label; note = $txt; color = 'Yellow' }
    }
    $items += @{ label = 'Open config.json'; note = $script:ConfigPath; color = 'DarkGray' }
    $key = 'settings'
    $m = @{ Title = 'Settings'; Subtitle = 'saved in config.json'; Items = $items; Start = (Get-LastSel $key) }
    $m += (Get-NavArgs $true)
    $i = Show-Menu @m
    if (Invoke-NavKey $i @{ type = 'home' }) { return }
    Set-LastSel $key $i
    if ($i -ge $script:SettingDefs.Count) { Invoke-Item -LiteralPath $script:ConfigPath; return }
    $d = $script:SettingDefs[$i]
    $cur = Get-Cfg $d.key
    if ($d.type -eq 'bool') { Set-Cfg $d.key (-not [bool]$cur); return }
    if ($d.type -eq 'folder') {
        $c = Show-Menu -Title $d.label -Subtitle ([string]$cur) -Items @('Browse...', 'Type the path', 'Clear (use default)')
        if ($c -eq 0) { $f = Select-FolderDialog $d.label ([string]$cur); if ($f) { Set-Cfg $d.key $f } }
        elseif ($c -eq 1) { $v = Read-Input $d.label 'path' @('Current: ' + [string]$cur) ([string]$cur); if ($null -ne $v) { Set-Cfg $d.key $v.Trim('"') } }
        elseif ($c -eq 2) { Set-Cfg $d.key '' }
        return
    }
    $v = Read-Input $d.label 'value' @('Current: ' + [string]$cur) ([string]$cur)
    if ($null -eq $v) { return }
    if ($d.type -eq 'int') {
        $n = 0
        if ([int]::TryParse($v, [ref]$n) -and $n -gt 0) { Set-Cfg $d.key $n } else { Clear-Host; Show-Fail 'Not a valid number' }
        return
    }
    Set-Cfg $d.key $v
}
