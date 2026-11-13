$script:Root       = Split-Path -Parent $PSScriptRoot
$script:ConfigPath = Join-Path $script:Root 'config.json'
$script:ProjCfgDir = Join-Path $script:Root 'projects'
$script:Quiet      = $true
$script:TickSeconds = 20
$script:GlobalTick = $null

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Write-JsonFile([string]$Path, $Object) {
    $dir = Split-Path -Parent $Path
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = ConvertTo-Json -InputObject $Object -Depth 8
    $tmp = $Path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Get-DefaultConfig {
    return [ordered]@{
        laragonDir         = 'C:\laragon'
        wwwDir             = ''
        backupDir          = 'C:\Dev\Backups'
        githubBackupDir    = ''
        snapshotsDir       = ''
        restoredDir        = ''
        desktopDir         = ''
        dataDir            = ''
        githubUser         = ''
        domainSuffix       = '.test'
        webPort            = 80
        mysqlPort          = 3306
        mysqlUser          = 'root'
        mysqlPassword      = ''
        editor             = 'code'
        autoSyncOnStart    = $true
        backupExcludeNames = @('node_modules')
        backupExcludePaths = @('storage\logs', 'storage\framework\cache', 'storage\framework\sessions', 'storage\framework\views')
    }
}

function Save-Config { Write-JsonFile $script:ConfigPath $script:Cfg }

function Import-Config {
    $cfg = Get-DefaultConfig
    $loaded = Read-JsonFile $script:ConfigPath
    if (-not $loaded) { $loaded = Read-JsonFile (Join-Path $script:Root 'config.example.json') }
    if ($loaded) {
        foreach ($prop in $loaded.PSObject.Properties) { $cfg[$prop.Name] = $prop.Value }
    }
    $script:Cfg = $cfg
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { try { Save-Config } catch { } }
}

function Get-Cfg([string]$Key) { return $script:Cfg[$Key] }
function Set-Cfg([string]$Key, $Value) { $script:Cfg[$Key] = $Value; Save-Config }

Import-Config

$script:DataDir = [string](Get-Cfg 'dataDir')
if (-not $script:DataDir) {
    $dataBase = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $HOME }
    $script:DataDir = Join-Path $dataBase 'Dev'
}
New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
$script:LogFile = Join-Path $script:DataDir 'dev.log'

function Get-LaragonDir {
    if ($env:LARAGON_DIR) { return $env:LARAGON_DIR }
    return [string](Get-Cfg 'laragonDir')
}
function Get-WwwDir {
    $v = [string](Get-Cfg 'wwwDir')
    if ($v) { return $v }
    return (Join-Path (Get-LaragonDir) 'www')
}
function Get-BackupDir     { return [string](Get-Cfg 'backupDir') }
function Get-GitHubBackupRoot {
    $v = [string](Get-Cfg 'githubBackupDir')
    if ($v) { return $v }
    return (Join-Path (Get-BackupDir) 'GitHub')
}
function Get-SnapRoot {
    $v = [string](Get-Cfg 'snapshotsDir')
    if ($v) { return $v }
    return (Join-Path (Get-BackupDir) 'Snapshots')
}
function Get-ExportRoot {
    $v = [string](Get-Cfg 'restoredDir')
    if ($v) { return $v }
    return (Join-Path (Get-BackupDir) 'Restored')
}
function Get-Desktop {
    $v = [string](Get-Cfg 'desktopDir')
    if ($v) { return $v }
    return [Environment]::GetFolderPath('Desktop')
}

function Write-Log([string]$Msg, $P = $null) {
    $pre  = if ($P) { "[$($P.Name)] " } else { '' }
    $line = '[{0}] {1}{2}' -f (Get-Date -Format 'HH:mm:ss'), $pre, $Msg
    if (-not $script:Quiet) { Write-Host $line }
    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
}

function Limit-Text([string]$s, [int]$n) {
    if ($n -lt 1) { return '' }
    if ($s.Length -gt $n) {
        if ($n -le 3) { return $s.Substring(0, $n) }
        return $s.Substring(0, $n - 3) + '...'
    }
    return $s
}

function Format-Size([double]$Bytes) {
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 1GB) { return ([Math]::Round($Bytes / 1GB, 2).ToString($inv) + ' GB') }
    if ($Bytes -ge 1MB) { return ([Math]::Round($Bytes / 1MB, 1).ToString($inv) + ' MB') }
    if ($Bytes -ge 1KB) { return ([Math]::Round($Bytes / 1KB, 0).ToString($inv) + ' KB') }
    return ([Math]::Round($Bytes, 0).ToString($inv) + ' B')
}

function Format-Date($Value) {
    if (-not $Value) { return '-' }
    try { return ([datetime]$Value).ToLocalTime().ToString('yyyy-MM-dd HH:mm') }
    catch { return "$Value" }
}

function Format-Files([int]$Count) {
    if ($Count -eq 1) { return '1 file' }
    return ($Count.ToString() + ' files')
}

function Format-Ago([datetime]$When) {
    $d = (Get-Date) - $When
    if ($d.TotalMinutes -lt 1)  { return 'just now' }
    if ($d.TotalMinutes -lt 60) { return ('{0}m ago' -f [int]$d.TotalMinutes) }
    if ($d.TotalHours   -lt 24) { return ('{0}h ago' -f [int]$d.TotalHours) }
    return ('{0}d ago' -f [int]$d.TotalDays)
}

function Get-FirstLine($Lines) {
    foreach ($l in @($Lines)) {
        $t = "$l".Trim()
        if ($t) { return $t }
    }
    return ''
}

function Add-Line($List, [string]$Text, [string]$Color = 'Gray') {
    [void]$List.Add(@{ t = $Text; c = $Color })
}

function ConvertTo-SafeName([string]$Name) {
    return ($Name -replace '[^A-Za-z0-9._-]', '_')
}

function Remove-Dir([string]$Path) {
    if (Test-Path -LiteralPath $Path) { cmd /c "rmdir /s /q `"$Path`"" 2>&1 | Out-Null }
}

function Send-ToRecycleBin([string]$Path) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path,
        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
}

function Read-Shared([string]$Path) {
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try { return (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { return '' }
}

function Test-PortOpen([int]$Port) {
    $c = New-Object Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
        return ($iar.AsyncWaitHandle.WaitOne(500) -and $c.Connected)
    } catch { return $false } finally { $c.Close() }
}

function Test-PidAlive($ProcId) {
    if (-not $ProcId) { return $false }
    return [bool](Get-Process -Id ([int]$ProcId) -ErrorAction SilentlyContinue)
}

$script:OwnProcNames = @('php', 'cloudflared', 'stripe', 'ngrok', 'mysqld', 'node', 'npm', 'cmd', 'powershell', 'pwsh', 'conhost')
function Test-SvcPid($ProcId) {
    if (-not $ProcId) { return $false }
    $pr = Get-Process -Id ([int]$ProcId) -ErrorAction SilentlyContinue
    if (-not $pr) { return $false }
    return ($script:OwnProcNames -contains $pr.ProcessName.ToLower())
}

function Invoke-TaskKill($ProcId) {
    if (-not (Test-SvcPid $ProcId)) { Write-Log "[kill] skipped pid $ProcId (not one of our processes)"; return }
    try { Start-Process -FilePath 'taskkill.exe' -ArgumentList '/F', '/T', '/PID', "$ProcId" -WindowStyle Hidden -Wait } catch { }
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

function Invoke-Native {
    param([string]$File, [string[]]$ArgList = @(), [string]$WorkDir = '')
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $pushed = $false
    $out = @()
    $code = 0
    try {
        if ($WorkDir) { Push-Location -LiteralPath $WorkDir; $pushed = $true }
        $out = @(& $File @ArgList 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } catch {
        $out = @("$_")
        $code = -1
    } finally {
        if ($pushed) { Pop-Location }
        $ErrorActionPreference = $old
    }
    return [pscustomobject]@{ Ok = ($code -eq 0); Code = $code; Out = $out }
}

$script:OnlineCache = @{ t = [datetime]::MinValue; v = $true }
function Test-Online([switch]$Force) {
    if ((-not $Force) -and (((Get-Date) - $script:OnlineCache.t).TotalSeconds -lt 8)) { return $script:OnlineCache.v }
    $ok = $false
    $c = New-Object Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect('github.com', 443, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(2500) -and $c.Connected) { $ok = $true }
    } catch { $ok = $false } finally { try { $c.Close() } catch { } }
    $script:OnlineCache.t = Get-Date
    $script:OnlineCache.v = $ok
    return $ok
}
