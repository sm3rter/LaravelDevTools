$script:RequiredDirs  = @('app', 'bootstrap', 'vendor')
$script:RequiredFiles = @('.env')
$script:MysqlFile     = Join-Path $script:DataDir 'mysql.json'

function Find-Latest([string]$Pattern) {
    $hit = Get-ChildItem -Path (Join-Path (Get-LaragonDir) $Pattern) -ErrorAction SilentlyContinue |
        Sort-Object FullName | Select-Object -Last 1
    if ($hit) { return $hit.FullName }
    return $null
}
function Get-PhpExe {
    $p = Find-Latest 'bin\php\php-*\php.exe'
    if ($p) { return $p }
    return 'php'
}
function Get-MysqldExe      { return (Find-Latest 'bin\mysql\*\bin\mysqld.exe') }
function Get-MysqlAdminExe  { return (Find-Latest 'bin\mysql\*\bin\mysqladmin.exe') }
function Get-MysqlDumpExe   { return (Find-Latest 'bin\mysql\*\bin\mysqldump.exe') }
function Get-MysqlClientExe { return (Find-Latest 'bin\mysql\*\bin\mysql.exe') }
function Get-MysqlIni       { return (Find-Latest 'bin\mysql\*\my.ini') }
function Get-LaragonExe {
    $e = Join-Path (Get-LaragonDir) 'laragon.exe'
    if (Test-Path -LiteralPath $e) { return $e }
    return $null
}

function Get-NpmCmd {
    $c = Get-Command npm -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return (Find-Latest 'bin\nodejs\*\npm.cmd')
}
function Get-ComposerCmd {
    $c = Get-Command composer -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return (Find-Latest 'bin\composer\composer.bat')
}

function New-Project([string]$ProjName) {
    $slug = ConvertTo-SafeName $ProjName
    $path = Join-Path (Get-WwwDir) $ProjName
    $data = Join-Path (Join-Path $script:DataDir 'projects') $slug
    $cfg  = $null
    $cf   = Join-Path $script:ProjCfgDir "$ProjName.json"
    $alt  = Join-Path $script:Root "$ProjName.json"
    if ((-not (Test-Path -LiteralPath $cf)) -and (Test-Path -LiteralPath $alt)) { $cf = $alt }
    $cfg = Read-JsonFile $cf
    $hostName = $ProjName.ToLower() + [string](Get-Cfg 'domainSuffix')
    [pscustomobject]@{
        Name = $ProjName; Path = $path; Slug = $slug; Data = $data
        StateFile = (Join-Path $data 'state.json')
        EnvPath   = (Join-Path $path '.env')
        Cfg       = $cfg
        CfgPath   = $cf
        Host      = $hostName
    }
}

function Get-CfgProp($p, [string]$Key) {
    if ($p.Cfg) {
        $prop = $p.Cfg.PSObject.Properties[$Key]
        if ($prop) { return , $prop }
    }
    return $null
}
function Get-CfgValue($p, [string]$Key) {
    $prop = Get-CfgProp $p $Key
    if ($prop) { return $prop[0].Value }
    return $null
}
function Test-CfgFlag($p, [string]$Key, [bool]$Default = $false) {
    $prop = Get-CfgProp $p $Key
    if ($prop) { return [bool]$prop[0].Value }
    return $Default
}

function Get-ProjectHost($p) {
    $h = Get-CfgValue $p 'host'
    if ($h) { return [string]$h }
    return $p.Host
}

function Get-ProjectUrl($p) {
    $u = Get-CfgValue $p 'url'
    if ($u) { return ([string]$u).TrimEnd('/') }
    $scheme = 'http'
    if (Test-CfgFlag $p 'https' $false) { $scheme = 'https' }
    $port = [int](Get-Cfg 'webPort')
    $suffix = ''
    if (($scheme -eq 'http') -and ($port -ne 80)) { $suffix = ":$port" }
    return ($scheme + '://' + (Get-ProjectHost $p) + $suffix)
}

function Test-HostRegistered([string]$HostName) {
    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $txt = Read-Shared $hosts
    if (-not $txt) { return $true }
    $rx = '(?im)^\s*[0-9a-f.:]+\s+.*(?<![\w.-])' + [regex]::Escape($HostName) + '(?![\w.-])'
    return [regex]::IsMatch($txt, $rx)
}

function Get-Missing($p) {
    $m = @()
    foreach ($d in $script:RequiredDirs)  { if (-not (Test-Path -LiteralPath (Join-Path $p.Path $d) -PathType Container)) { $m += $d } }
    foreach ($f in $script:RequiredFiles) { if (-not (Test-Path -LiteralPath (Join-Path $p.Path $f) -PathType Leaf))      { $m += $f } }
    return $m
}
function Test-Artisan($p) { return (Test-Path -LiteralPath (Join-Path $p.Path 'artisan') -PathType Leaf) }

function Get-Projects {
    $www = Get-WwwDir
    if (-not (Test-Path -LiteralPath $www)) { return @() }
    return @(Get-ChildItem -LiteralPath $www -Directory -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Name.StartsWith('.') } |
        Sort-Object Name | ForEach-Object { New-Project $_.Name })
}

function Find-ProjectByName([string]$ProjName) {
    return (@(Get-Projects) | Where-Object { $_.Name -ieq $ProjName } | Select-Object -First 1)
}

function Get-EnvValue([string]$Path, [string]$Key) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $rx = '^\s*' + [regex]::Escape($Key) + '\s*=\s*(.*?)\s*$'
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ($line -match $rx) { return $Matches[1].Trim([char]39, [char]34) }
    }
    return $null
}

function Update-ProjectEnv($p, $Values, [string[]]$AddIfMissing = @()) {
    if (-not (Test-Path -LiteralPath $p.EnvPath)) { return }
    $lines = [IO.File]::ReadAllLines($p.EnvPath)
    $out = New-Object 'System.Collections.Generic.List[string]'
    $seen = @{}
    foreach ($l in $lines) {
        $done = $false
        if ($l -match '^\s*([A-Za-z0-9_]+)\s*=') {
            $k = $Matches[1]
            if ($Values.Contains($k)) { $out.Add("$k=$($Values[$k])"); $seen[$k] = $true; $done = $true }
        }
        if (-not $done) { $out.Add($l) }
    }
    foreach ($k in $AddIfMissing) {
        if ($Values.Contains($k) -and -not $seen.ContainsKey($k)) { $out.Add("$k=$($Values[$k])") }
    }
    [IO.File]::WriteAllLines($p.EnvPath, $out, (New-Object Text.UTF8Encoding($false)))
    Write-Log ('.env updated: ' + (($Values.Keys | ForEach-Object { $_ }) -join ', ')) $p
    if (Test-Artisan $p) {
        try {
            $r = Start-Process -FilePath (Get-PhpExe) -ArgumentList 'artisan', 'config:clear' -WorkingDirectory $p.Path -WindowStyle Hidden -PassThru
            if (-not $r.WaitForExit(60000)) { try { $r.Kill() } catch { } }
            Write-Log 'artisan config:clear done' $p
        } catch { Write-Log "config:clear error: $_" $p }
    }
}

function Set-ProjectAppUrl($p, [string]$Url) {
    $cur = Get-EnvValue $p.EnvPath 'APP_URL'
    if ($cur -eq $Url) { return }
    Update-ProjectEnv $p ([ordered]@{ APP_URL = $Url }) @('APP_URL')
}

function Stop-MysqlGraceful {
    $adm = Get-MysqlAdminExe
    if (-not $adm) { return $false }
    $a = @('-u', ([string](Get-Cfg 'mysqlUser')))
    $pw = [string](Get-Cfg 'mysqlPassword')
    if ($pw) { $a += "-p$pw" }
    $a += ('--port=' + [int](Get-Cfg 'mysqlPort')), 'shutdown'
    try {
        $r = Start-Process -FilePath $adm -ArgumentList $a -WindowStyle Hidden -PassThru
        if (-not $r.WaitForExit(30000)) { try { $r.Kill() } catch { }; return $false }
        if ($r.ExitCode -eq 0) { Write-Log '[mysql] graceful shutdown OK'; return $true }
        Write-Log "[mysql] mysqladmin exit code $($r.ExitCode)"
    } catch { Write-Log "[mysql] mysqladmin error: $_" }
    return $false
}

function Start-MysqlDirect {
    $port = [int](Get-Cfg 'mysqlPort')
    if (Test-PortOpen $port) { return $true }
    $exe = Get-MysqldExe
    if (-not $exe) { Write-Log "[WARN] mysqld.exe not found under $(Get-LaragonDir)\bin\mysql"; return $false }
    $ini = Get-MysqlIni
    $a = @(); if ($ini) { $a += "--defaults-file=$ini" }
    $params = @{ FilePath = $exe; WindowStyle = 'Hidden'; PassThru = $true
                 WorkingDirectory = (Split-Path -Parent $exe)
                 RedirectStandardOutput = (Join-Path $script:DataDir 'mysql.log')
                 RedirectStandardError  = (Join-Path $script:DataDir 'mysql.log.err') }
    if ($a.Count -gt 0) { $params.ArgumentList = @($a | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) }
    $proc = Start-Process @params
    Write-JsonFile $script:MysqlFile @{ pid = $proc.Id }
    Write-Log "started mysqld.exe directly (pid $($proc.Id))"
    for ($i = 0; $i -lt 30; $i++) {
        if (Test-PortOpen $port) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Stop-MysqlIfIdle {
    if (-not (Test-Path -LiteralPath $script:MysqlFile)) { return }
    if (Get-Command Get-Tracked -ErrorAction SilentlyContinue) {
        if (@(Get-Tracked).Count -gt 0) { Write-Log '[mysql] other projects still running -> keeping MySQL'; return }
    }
    $o = Read-JsonFile $script:MysqlFile
    $mpid = $null
    if ($o) { $mpid = $o.pid }
    if (Test-PortOpen ([int](Get-Cfg 'mysqlPort'))) {
        if (Stop-MysqlGraceful) { Start-Sleep -Seconds 2 }
        elseif ($mpid -and (Test-PidAlive $mpid)) { Invoke-TaskKill $mpid; Write-Log '[mysql] force killed' }
    }
    Remove-Item -LiteralPath $script:MysqlFile -Force -ErrorAction SilentlyContinue
}

function Test-LaragonRunning { return [bool](Get-Process -Name 'laragon' -ErrorAction SilentlyContinue) }

function Get-LaragonStatus {
    return @{
        App   = (Test-LaragonRunning)
        Web   = (Test-PortOpen ([int](Get-Cfg 'webPort')))
        Mysql = (Test-PortOpen ([int](Get-Cfg 'mysqlPort')))
    }
}

function Start-LaragonServices([bool]$NeedWeb = $true, [bool]$NeedDb = $true) {
    $webPort = [int](Get-Cfg 'webPort')
    $dbPort  = [int](Get-Cfg 'mysqlPort')
    $webOk = (-not $NeedWeb) -or (Test-PortOpen $webPort)
    $dbOk  = (-not $NeedDb) -or (Test-PortOpen $dbPort)
    if ($webOk -and $dbOk) { return '' }

    if (-not (Test-LaragonRunning)) {
        $exe = Get-LaragonExe
        if (-not $exe) { return ('! Laragon not found at ' + (Get-LaragonDir) + ' - fix the path in Settings') }
        Write-Host '  Starting Laragon ...' -ForegroundColor DarkGray
        try { Start-Process -FilePath $exe -WorkingDirectory (Get-LaragonDir) } catch { return "! could not start Laragon: $_" }
        Write-Log 'started laragon.exe'
    }
    Write-Host '  Waiting for the web server and MySQL (Laragon > Start All if it does not start by itself) ...' -ForegroundColor DarkGray
    for ($i = 0; $i -lt 60; $i++) {
        $webOk = (-not $NeedWeb) -or (Test-PortOpen $webPort)
        $dbOk  = (-not $NeedDb) -or (Test-PortOpen $dbPort)
        if ($webOk -and $dbOk) { return '' }
        if ((-not $dbOk) -and ($i -eq 20)) { [void](Start-MysqlDirect) }
        Start-Sleep -Seconds 1
    }
    if (-not $webOk) { return '! the web server is not running - in Laragon press "Start All"' }
    return '! MySQL is not running - in Laragon press "Start All"'
}
