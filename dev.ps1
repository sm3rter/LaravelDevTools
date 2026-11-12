param(
    [Parameter(Position = 0)][string]$Command = 'home',
    [Parameter(Position = 1)][string]$Name
)

$ErrorActionPreference = 'Continue'
try { $Host.UI.RawUI.WindowTitle = 'Dev' } catch { }

$script:LibDir = Join-Path $PSScriptRoot 'lib'
foreach ($f in @('core', 'ui', 'nav', 'laragon', 'services', 'projects', 'zip', 'backup', 'github', 'snapshots', 'git', 'gitflow', 'tools')) {
    . (Join-Path $script:LibDir ($f + '.ps1'))
}

function Show-HomeScreen {
    $online = Test-Online
    $running = @(Get-Tracked).Count
    $projCount = @(Get-Projects).Count
    $pending = Get-PendingCount

    $items = @()
    $items += @{ label = 'Projects'; note = "$projCount, $running running"; color = 'Green' }
    $items += @{ label = 'Git'; note = ''; color = 'Cyan' }
    $items += @{ label = 'Backup'; note = (Get-BackupDir); color = 'Cyan' }
    $items += @{ label = 'Zip project'; note = ''; color = 'DarkGray' }
    $items += @{ label = 'Apply patches'; note = ''; color = 'DarkGray' }
    $items += @{ label = 'Snapshots'; note = ''; color = 'DarkGray' }
    if ($pending -gt 0) { $items += @{ label = 'Sync'; note = "$pending waiting for internet"; color = 'Yellow' } }
    $items += @{ label = 'Tools'; note = ''; color = 'DarkGray' }
    $items += @{ label = 'Settings'; note = ''; color = 'DarkGray' }
    $items += @{ label = 'Quit'; note = ''; color = 'DarkGray' }

    $net = 'online'
    if (-not $online) { $net = 'offline: git works locally, pushes are sent when internet is back' }
    $flash = $script:HubFlash; $script:HubFlash = ''
    $fc = 'Green'; if ($flash.StartsWith('!')) { $fc = 'Red' }
    $key = 'home'
    $m = @{ Title = 'Dev'; Subtitle = $net; Items = $items; Start = (Get-LastSel $key); Flash = $flash.TrimStart('!').Trim(); FlashColor = $fc }
    $m += (Get-NavArgs $false)
    $i = Show-Menu @m
    if (Invoke-NavKey $i $null) { return }
    Set-LastSel $key $i

    $label = $items[$i].label
    if     ($label -eq 'Projects') { Open-Loc @{ type = 'projects'; name = $null } }
    elseif ($label -eq 'Git') { $p = Select-ProjectModal 'Git - pick a project'; if ($p) { Invoke-GitMenu $p } }
    elseif ($label -eq 'Backup') { Open-Loc @{ type = 'backup'; name = $null } }
    elseif ($label -eq 'Zip project') { $p = Select-ProjectModal 'Zip project - pick a project'; if ($p) { [void](Invoke-ZipProject $p); $script:HubFlash = $script:ZipResult } }
    elseif ($label -eq 'Apply patches') { $p = Select-ProjectModal 'Apply patches - pick a project'; if ($p) { [void](Invoke-ApplyPatches $p); Pause-Key } }
    elseif ($label -eq 'Snapshots') { Open-Loc @{ type = 'snaps'; name = $null } }
    elseif ($label -eq 'Sync') { Show-SyncScreen }
    elseif ($label -eq 'Tools') { Open-Loc @{ type = 'tools'; name = $null } }
    elseif ($label -eq 'Settings') { Open-Loc @{ type = 'settings'; name = $null } }
    elseif ($label -eq 'Quit') { [void](Exit-Tool) }
}

function Show-BackupLocScreen {
    $b = Show-BackupScreen
    $key = 'backup'
    $m = @{ Title = 'Backup'; Subtitle = $b.Subtitle; Items = $b.Items; Start = (Get-LastSel $key) }
    $m += (Get-NavArgs $true)
    $i = Show-Menu @m
    if (Invoke-NavKey $i @{ type = 'home' }) { return }
    Set-LastSel $key $i
    Invoke-BackupAction $i
}

function Invoke-Router {
    while ($true) {
        $loc = Get-CurrentLoc
        try {
            if     ($loc.type -eq 'home')     { Show-HomeScreen }
            elseif ($loc.type -eq 'projects') { Show-ProjectsScreen }
            elseif ($loc.type -eq 'project')  { Show-ProjectScreen $loc }
            elseif ($loc.type -eq 'repos')    { Show-ReposScreen }
            elseif ($loc.type -eq 'repo')     { Show-RepoScreen $loc }
            elseif ($loc.type -eq 'backup')   { Show-BackupLocScreen }
            elseif ($loc.type -eq 'snaps')    { Show-SnapsScreen }
            elseif ($loc.type -eq 'snap')     { Show-SnapScreen $loc }
            elseif ($loc.type -eq 'tools')    { Show-ToolsScreen }
            elseif ($loc.type -eq 'settings') { Show-SettingsScreen }
            else { $script:Pos = 0 }
        }
        catch {
            $msg = "$_"
            $where = ''
            try { $where = ($_.ScriptStackTrace -split "`r?`n" | Select-Object -First 3) -join ' | ' } catch { }
            Write-Log "ERROR on screen '$($loc.type)': $msg  [$where]"
            try { [Console]::CursorVisible = $true } catch { }
            Clear-Host
            Write-Host ''
            Write-Host '  Something went wrong on this screen:' -ForegroundColor Red
            Write-Host "  $msg" -ForegroundColor Red
            if ($where) { Write-Host "  $where" -ForegroundColor DarkGray }
            Write-Host "  (details were written to $script:LogFile)" -ForegroundColor DarkGray
            Wait-Key

            $script:Pos = 0
            while ($script:Hist.Count -gt 1) { $script:Hist.RemoveAt($script:Hist.Count - 1) }
        }
    }
}

function Resolve-ProjectArg([string]$ProjName, [string]$Title) {
    if ($ProjName) {
        $p = Find-ProjectByName $ProjName
        if (-not $p) { Write-Host "  [ERROR] no project named '$ProjName' in $(Get-WwwDir)" -ForegroundColor Red; return $null }
        return $p
    }
    return (Select-ProjectModal $Title)
}

function Invoke-StopCmd([string]$ProjName) {
    $running = @(Get-Tracked)
    if ($running.Count -eq 0) { Write-Host '  no running projects'; return }
    if ($ProjName -ieq 'all') { [void](Invoke-StopAll); Write-Host '  stopped everything'; return }
    if ($ProjName) {
        $p = $running | Where-Object { $_.Name -ieq $ProjName } | Select-Object -First 1
        if (-not $p) { Write-Host "  '$ProjName' is not running"; return }
        Stop-Project $p
        Write-Host "  stopped $($p.Name)"
        return
    }
    $items = @()
    if ($running.Count -gt 1) { $items += @{ label = '[ STOP ALL ]'; note = "$($running.Count) projects"; color = 'Red'; danger = $true } }
    $off = $items.Count
    foreach ($p in $running) { $s = Read-State $p; $items += @{ label = $p.Name; note = (Get-SvcSummary $p); color = 'Yellow' } }
    $i = Show-Menu -Title 'Dev - STOP' -Subtitle 'choose what to stop' -Items $items
    if ($i -lt 0) { return }
    if (($off -eq 1) -and ($i -eq 0)) { Show-Busy 'Stopping everything'; [void](Invoke-StopAll); return }
    Show-Busy 'Stopping the project'; Stop-Project $running[$i - $off]
}

$script:Quiet = $true
$cmd = $Command.ToLower()
$noSync = @('stop', 'stopall', 'ip', 'tray', 'sync', 'settings')
if (($noSync -notcontains $cmd) -and (Get-Command git -ErrorAction SilentlyContinue)) {
    try { Invoke-AutoSync } catch { Write-Log "auto sync error: $_" }
}

try {
    if     ($cmd -eq 'home')     { Invoke-Router }
    elseif ($cmd -eq 'start')    {
        if ($Name) {
            $p = Find-ProjectByName $Name
            if (-not $p) { Write-Host "  [ERROR] no project named '$Name' in $(Get-WwwDir)" -ForegroundColor Red; exit 1 }
            Open-Loc @{ type = 'projects'; name = $null }
            Open-Loc @{ type = 'project'; name = $p.Name }
        } else { Open-Loc @{ type = 'projects'; name = $null } }
        Invoke-Router
    }
    elseif ($cmd -eq 'stop')     { Invoke-StopCmd $Name }
    elseif ($cmd -eq 'stopall')  { [void](Invoke-StopAll); Write-Host '  stopped everything' }
    elseif ($cmd -eq 'git')      { $p = Resolve-ProjectArg $Name 'Git - pick a project'; if ($p) { Invoke-GitMenu $p } }
    elseif ($cmd -eq 'backup')   {
        $p = Resolve-ProjectArg $Name 'Backup - pick a project'
        if ($p) { Show-ProjectBackupMenu $p }
    }
    elseif ($cmd -eq 'restore')  { Invoke-RestoreBackup }
    elseif ($cmd -eq 'cleanup')  { Invoke-CleanupBackups }
    elseif ($cmd -eq 'zip')      { $p = Resolve-ProjectArg $Name 'Zip project - pick a project'; if ($p) { [void](Invoke-ZipProject $p); Start-Sleep -Seconds 2 } }
    elseif ($cmd -eq 'patches' -or $cmd -eq 'patch') { $p = Resolve-ProjectArg $Name 'Apply patches - pick a project'; if ($p) { [void](Invoke-ApplyPatches $p); Pause-Key } }
    elseif ($cmd -eq 'snaps')    { Open-Loc @{ type = 'snaps'; name = $null }; Invoke-Router }
    elseif ($cmd -eq 'sync')     { Show-SyncScreen }
    elseif ($cmd -eq 'clone')    { $m = Invoke-GitClone; if ($m) { Write-Host "  $m" } }
    elseif ($cmd -eq 'ip')       { Show-NetworkInfo }
    elseif ($cmd -eq 'settings') { Open-Loc @{ type = 'settings'; name = $null }; Invoke-Router }
    elseif ($cmd -eq 'tray')     { . (Join-Path $script:LibDir 'tray.ps1') }
    else { Write-Host 'usage: dev.bat [start|stop|git|backup|restore|cleanup|zip|patches|snaps|sync|clone|ip|settings|tray] [project]' }
}
catch {
    Write-Log "fatal: $_`n$($_.ScriptStackTrace)"
    Write-Host "  fatal: $_" -ForegroundColor Red
    exit 1
}
exit 0
