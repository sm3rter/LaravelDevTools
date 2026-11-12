$script:Svc = @{}
$script:EditorWatch = @{}

function Read-State($p) {
    $o = Read-JsonFile $p.StateFile
    if (-not $o) { return $null }
    $pids = @{}
    if ($o.pids) { foreach ($x in $o.pids.PSObject.Properties) { $pids[$x.Name] = [int]$x.Value } }
    return @{ name = $o.name; launcher_pid = $o.launcher_pid; port = $o.port; reverb_port = $o.reverb_port; url = $o.url; reverb_url = $o.reverb_url; pids = $pids }
}
function Save-State($p, $st) {
    New-Item -ItemType Directory -Force -Path $p.Data | Out-Null
    Write-JsonFile $p.StateFile $st
}

function Test-Active($p) { return (Test-Path -LiteralPath $p.StateFile) }

function Register-Pid($p, [string]$ProcName, [int]$ProcId) {
    $st = Read-State $p
    if (-not $st) { return $false }
    $st.pids[$ProcName] = $ProcId
    Save-State $p $st
    Write-Log "[pid] $ProcName -> $ProcId" $p
    return $true
}

function Get-Status($p) {
    $st = Read-State $p
    if (-not $st) { return $null }
    if (Test-PidAlive $st.launcher_pid) { return 'running' }
    foreach ($v in $st.pids.Values) { if (Test-PidAlive $v) { return 'orphan' } }
    Remove-Item -LiteralPath $p.StateFile -Force -ErrorAction SilentlyContinue
    return $null
}

function Get-Tracked {
    $out = @()
    $root = Join-Path $script:DataDir 'projects'
    if (-not (Test-Path -LiteralPath $root)) { return $out }
    foreach ($d in Get-ChildItem -LiteralPath $root -Directory) {
        $sf = Join-Path $d.FullName 'state.json'
        if (Test-Path -LiteralPath $sf) {
            $o = Read-JsonFile $sf
            if ($o -and $o.name) {
                $p = New-Project ([string]$o.name)
                if (Get-Status $p) { $out += $p }
            }
        }
    }
    return $out
}

function Get-FreePort([int]$Start) {
    $used = @()
    foreach ($q in @(Get-Tracked)) {
        $s = Read-State $q
        if ($s -and $s.port)        { $used += [int]$s.port }
        if ($s -and $s.reverb_port) { $used += [int]$s.reverb_port }
    }
    $port = $Start
    while (($used -contains $port) -or (Test-PortOpen $port)) { $port++ }
    return $port
}

function Start-Hidden($p, [string]$File, [string[]]$ArgList, [string]$WorkDir, [string]$LogPath, [string]$RegName) {
    $params = @{ FilePath = $File; WindowStyle = 'Hidden'; PassThru = $true }
    if ($ArgList) { $params.ArgumentList = @($ArgList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) }
    if ($WorkDir) { $params.WorkingDirectory = $WorkDir }
    if ($LogPath) { $params.RedirectStandardOutput = $LogPath; $params.RedirectStandardError = "$LogPath.err" }
    $proc = Start-Process @params
    if ($RegName -and -not (Register-Pid $p $RegName $proc.Id)) {
        try { $proc.Kill() } catch { }
        return $null
    }
    return $proc
}

function Test-Svc($p, [string]$Id) {
    $st = Read-State $p
    if (-not $st) { return $false }
    if (-not $st.pids.ContainsKey($Id)) { return $false }
    return (Test-PidAlive $st.pids[$Id])
}
function Test-AnySvc($p, [string]$Pattern) {
    $st = Read-State $p
    if (-not $st) { return $false }
    foreach ($k in $st.pids.Keys) { if (($k -like $Pattern) -and (Test-PidAlive $st.pids[$k])) { return $true } }
    return $false
}

function Initialize-ProjectState($p) {
    $st = Read-State $p
    if ($st) {
        if (-not (Test-PidAlive $st.launcher_pid)) { $st.launcher_pid = $PID; Save-State $p $st }
        return
    }
    New-Item -ItemType Directory -Force -Path $p.Data | Out-Null
    Save-State $p @{ name = $p.Name; launcher_pid = $PID; port = $null; reverb_port = $null; url = $null; reverb_url = $null; pids = @{} }
}

function Stop-Svc($p, [string]$Pattern, [bool]$KeepState = $false) {
    foreach ($key in @($script:Svc.Keys)) {
        if (($script:Svc[$key].P.Name -eq $p.Name) -and ($script:Svc[$key].Id -like $Pattern)) { $script:Svc.Remove($key) }
    }
    $st = Read-State $p
    if (-not $st) { return }
    foreach ($k in @($st.pids.Keys)) {
        if ($k -like $Pattern) {
            Invoke-TaskKill $st.pids[$k]
            $st.pids.Remove($k)
            Write-Log "[kill] $k" $p
        }
    }
    if (($st.pids.Count -eq 0) -and (-not $KeepState)) {
        Remove-Item -LiteralPath $p.StateFile -Force -ErrorAction SilentlyContinue
        Stop-MysqlIfIdle
    } else { Save-State $p $st }
}

function Stop-Project($p, [bool]$StopMysql = $true) {
    $st = Read-State $p
    $script:EditorWatch.Remove($p.Name)
    if (-not $st) { Write-Log 'nothing tracked' $p; return }
    Remove-Item -LiteralPath $p.StateFile -Force -ErrorAction SilentlyContinue
    foreach ($key in @($script:Svc.Keys)) { if ($script:Svc[$key].P.Name -eq $p.Name) { $script:Svc.Remove($key) } }
    foreach ($k in @($st.pids.Keys)) {
        Invoke-TaskKill $st.pids[$k]
        Write-Log "[kill] $k (pid $($st.pids[$k])) -> terminated" $p
    }
    $lp = $st.launcher_pid
    if ($lp -and ($lp -ne $PID) -and (Test-PidAlive $lp)) {

        Write-Log "owner window pid $lp keeps running (it has nothing left to manage)" $p
    }

    if ((Test-Path -LiteralPath $p.EnvPath) -and ($st.url) -and ("$($st.url)" -ne (Get-ProjectUrl $p))) {
        try { Set-ProjectAppUrl $p (Get-ProjectUrl $p) } catch { }
    }
    if ($StopMysql) { Stop-MysqlIfIdle }
}

function Invoke-StopAll {
    $running = @(Get-Tracked)
    foreach ($p in $running) { Stop-Project $p $false }
    Stop-MysqlIfIdle
    Write-Log "stopped $($running.Count) project(s)"
    return 0
}

function Get-CloudflareUrl($p, [string]$LocalUrl, [string]$RegName = 'cloudflared', [string]$LogName = 'cf.log', [string[]]$ExtraArgs = @()) {
    $cfLog = Join-Path $p.Data $LogName
    $attempt = 0
    while ((Test-Active $p) -and ($attempt -lt 3)) {
        $attempt++
        Write-Log "[$RegName] attempt #$attempt ..." $p
        Remove-Item -LiteralPath $cfLog, "$cfLog.err" -Force -ErrorAction SilentlyContinue
        $proc = $null
        try {
            $proc = Start-Hidden $p 'cloudflared' (@('tunnel', '--url', $LocalUrl) + $ExtraArgs) $null $cfLog $RegName
        } catch {
            Write-Log "[$RegName] cloudflared NOT FOUND - install it (winget install Cloudflare.cloudflared). retry in 10s" $p
            Start-Sleep -Seconds 10
            continue
        }
        if (-not $proc) { return $null }
        $found = $null
        for ($i = 0; $i -lt 45; $i++) {
            Start-Sleep -Seconds 1
            if (-not (Test-Active $p)) { return $null }
            $txt = (Read-Shared $cfLog) + (Read-Shared "$cfLog.err")
            if ($txt -match 'https://[a-zA-Z0-9-]+\.trycloudflare\.com') { $found = $Matches[0]; break }
            if ($proc.HasExited) { Write-Log "[$RegName] exited early after $($i + 1)s" $p; break }
        }
        if ($found) { Write-Log "[$RegName] URL: $found" $p; return $found }
        try { $proc.Kill() } catch { }
        Write-Log "[$RegName] no URL - retrying in 3s ..." $p
        Start-Sleep -Seconds 3
    }
    return $null
}

$script:QrHelper = @'
import sys, qrcode
from PIL import Image, ImageDraw, ImageFont
url, out = sys.argv[1], sys.argv[2]
qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_H, box_size=12, border=4)
qr.add_data(url); qr.make(fit=True)
img = qr.make_image(fill_color="black", back_color="white").convert("RGB")
import os
fp = next((f for f in [r"C:\Windows\Fonts\segoeui.ttf", r"C:\Windows\Fonts\tahoma.ttf", r"C:\Windows\Fonts\arial.ttf"] if os.path.exists(f)), None)
def font(s):
    try: return ImageFont.truetype(fp, s) if fp else ImageFont.load_default()
    except Exception: return ImageFont.load_default()
canvas = Image.new("RGB", (img.width, img.height + 50), "white")
canvas.paste(img, (0, 0))
d = ImageDraw.Draw(canvas)
size, f = 20, font(20)
while size > 10:
    b = d.textbbox((0, 0), url, font=f)
    if b[2] - b[0] <= canvas.width - 20: break
    size -= 1; f = font(size)
b = d.textbbox((0, 0), url, font=f)
d.text(((canvas.width - (b[2] - b[0])) // 2, img.height + 8), url, font=f, fill=(60, 60, 60))
canvas.save(out)
'@

function Save-QrImage($p, [string]$Url) {
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) { Write-Log '[QR] python not found -> skipping QR image' $p; return }
    $helper = Join-Path $script:DataDir 'qr_helper.py'
    Set-Content -LiteralPath $helper -Value $script:QrHelper -Encoding UTF8
    $out = Join-Path (Get-Desktop) "$($p.Slug)-QR.png"
    & python $helper $Url $out 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Log '[QR] installing qrcode + pillow ...' $p
        & python -m pip install qrcode pillow --quiet 2>$null
        & python $helper $Url $out 2>$null
    }
    if ($LASTEXITCODE -eq 0) { Write-Log "QR saved -> $out" $p } else { Write-Log '[QR] failed (pip install qrcode pillow)' $p }
}

function Open-Browser([string]$Url) {
    $base = $script:DataBase
    $cands = @(
        'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe',
        'C:\Program Files (x86)\BraveSoftware\Brave-Browser\Application\brave.exe',
        (Join-Path $base 'BraveSoftware\Brave-Browser\Application\brave.exe'))
    $brave = $cands | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($brave) { Start-Process -FilePath $brave -ArgumentList $Url }
    else        { Start-Process $Url }
}

function Get-Label([string]$q) { if ($q) { return $q } else { return 'default' } }

function Start-Worker($p, [string]$q) {
    $a = @('artisan', 'queue:work')
    if ($q) { $a += "--queue=$q" }
    $a += '--timeout=300', '--tries=3', '--max-time=3600', '--memory=256', '--sleep=3'
    $label = Get-Label $q
    $proc = Start-Hidden $p (Get-PhpExe) $a $p.Path (Join-Path $p.Data ('worker_{0}.log' -f ($label -replace '-', '_'))) "worker_$label"
    if ($proc) { Write-Log "worker: $label (pid $($proc.Id))" $p }
    return $proc
}

function Start-Scheduler($p) {
    $proc = Start-Hidden $p (Get-PhpExe) @('artisan', 'schedule:work') $p.Path (Join-Path $p.Data 'scheduler.log') 'scheduler'
    if ($proc) { Write-Log "scheduler started (pid $($proc.Id))" $p }
    return $proc
}

function Start-Reverb($p, [int]$Port) {
    $a = @('artisan', 'reverb:start', '--host=127.0.0.1', "--port=$Port")
    $proc = Start-Hidden $p (Get-PhpExe) $a $p.Path (Join-Path $p.Data 'reverb.log') 'reverb'
    if ($proc) {
        Write-Log "reverb started on :$Port (pid $($proc.Id))" $p
        Start-Sleep -Seconds 2
        if ($proc.HasExited) { Write-Log "[WARN] reverb exited immediately - is laravel/reverb installed? see $($p.Data)\reverb.log.err" $p }
    }
    return $proc
}

function Start-Stripe($p) {
    $path = [string](Get-CfgValue $p 'stripe')
    if (-not $path.StartsWith('/')) { $path = '/' + $path }
    $target = (Get-ProjectUrl $p) + $path
    $proc = Start-Hidden $p 'stripe' @('listen', '--forward-to', $target) $p.Path (Join-Path $p.Data 'stripe.log') 'stripe'
    if ($proc) { Write-Log "stripe listen -> $target (pid $($proc.Id))" $p }
    return $proc
}

function Start-Ngrok($p) {
    $dom = [string](Get-CfgValue $p 'ngrok').domain
    $a = @('http')
    if ($dom) { $a += "--url=$dom" }
    $a += ('--host-header=' + (Get-ProjectHost $p)), [string][int](Get-Cfg 'webPort')
    $proc = Start-Hidden $p 'ngrok' $a $p.Path (Join-Path $p.Data 'ngrok.log') 'ngrok'
    if ($proc) { Write-Log "ngrok started (pid $($proc.Id))" $p }
    return $proc
}

function Test-NeedsReverb($p) {
    $prop = Get-CfgProp $p 'reverb'
    if ($prop) { return [bool]$prop[0].Value }
    foreach ($k in @('BROADCAST_CONNECTION', 'BROADCAST_DRIVER')) {
        $v = Get-EnvValue $p.EnvPath $k
        if ($v) { return ($v.ToLower() -eq 'reverb') }
    }
    return [bool](Get-EnvValue $p.EnvPath 'REVERB_APP_KEY')
}

function Get-ReverbPort($p) {
    $start = Get-CfgValue $p 'reverbPort'
    if (-not $start) { $start = Get-EnvValue $p.EnvPath 'REVERB_SERVER_PORT' }
    if (-not $start) { $start = 8080 }
    return (Get-FreePort ([int]$start))
}

function Get-ReverbEnvValues($p, [string]$HostName, [int]$Port, [string]$Scheme) {
    $v = [ordered]@{ REVERB_HOST = $HostName; REVERB_PORT = $Port; REVERB_SCHEME = $Scheme }
    $pairs = @(@('VITE_REVERB_HOST', $HostName), @('VITE_REVERB_PORT', $Port), @('VITE_REVERB_SCHEME', $Scheme), @('REVERB_CLIENT_HOST', $HostName))
    foreach ($pair in $pairs) {
        $cur = Get-EnvValue $p.EnvPath $pair[0]
        if (($null -ne $cur) -and ($cur -notmatch '^\$\{')) { $v[$pair[0]] = $pair[1] }
    }
    return $v
}

function Register-Svc($p, [string]$Id, [string]$Kind, $Arg, $Proc) {
    $script:Svc["$($p.Name)|$Id"] = @{ P = $p; Id = $Id; Kind = $Kind; Arg = $Arg; Proc = $Proc }
}

$script:HealthLast = @{}
$script:RestartLast = @{}
function Test-WorkersHealth($p) {
    if (-not (Test-AnySvc $p 'worker_*')) { return }
    $qc = Get-EnvValue $p.EnvPath 'QUEUE_CONNECTION'
    if ($qc -ne 'database') { return }
    $db = Get-ProjectDb $p
    if ((@('mysql', 'mariadb') -notcontains $db.Conn) -or (-not $db.Name)) { return }
    $mysql = Get-MysqlClientExe
    if (-not $mysql) { return }
    $limit = 15
    $cfgMin = Get-CfgValue $p 'workerStuckMinutes'
    if ($cfgMin) { $limit = [int]$cfgMin }
    $cnf = New-MysqlCnf $db
    $r = $null
    try {
        $sql = 'SELECT queue, SUM(reserved_at IS NULL), IFNULL(UNIX_TIMESTAMP()-MIN(CASE WHEN reserved_at IS NULL THEN available_at END),0), IFNULL(UNIX_TIMESTAMP()-MIN(reserved_at),0), SUM(reserved_at IS NOT NULL) FROM jobs GROUP BY queue'
        $r = Invoke-Native $mysql @("--defaults-extra-file=$cnf", '--connect-timeout=3', '-N', '-B', '-D', $db.Name, '-e', $sql)
    } finally { Remove-Item -LiteralPath $cnf -Force -ErrorAction SilentlyContinue }
    if ((-not $r) -or (-not $r.Ok)) { return }
    foreach ($line in $r.Out) {
        $f = $line.Split([char]9)
        if ($f.Count -lt 5) { continue }
        $q = $f[0]
        $waiting = [int][double]$f[1]; $waitAge = [double]$f[2]; $resAge = [double]$f[3]; $resCnt = [int][double]$f[4]
        $why = ''
        if (($resCnt -gt 0) -and ($resAge -gt ($limit * 60))) { $why = "a job has been running for $([int]($resAge / 60)) min" }
        elseif (($waiting -gt 0) -and ($resCnt -eq 0) -and ($waitAge -gt 180)) { $why = "$waiting job(s) waiting for $([int]($waitAge / 60)) min and nobody takes them" }
        if (-not $why) { continue }
        $id = 'worker_' + (Get-Label $q)
        if (-not (Test-Svc $p $id)) { continue }
        $key = $p.Name + '|' + $id
        if ($script:RestartLast.ContainsKey($key) -and (((Get-Date) - $script:RestartLast[$key]).TotalSeconds -lt 300)) { continue }
        $script:RestartLast[$key] = Get-Date
        Write-Log "[health] queue '$q' looks stuck ($why) -> restarting its worker" $p
        Stop-Svc $p $id $true
        [void](Start-WorkerSet $p @($q))
    }
}

function Invoke-Watchdog {
    foreach ($key in @($script:Svc.Keys)) {
        $e = $script:Svc[$key]
        if (-not $e) { continue }
        if (-not (Test-Active $e.P)) { $script:Svc.Remove($key); continue }
        if ((-not $e.Proc) -or $e.Proc.HasExited) {
            Write-Log "[watchdog] $($e.Id) is down -> restarting" $e.P
            try {
                if     ($e.Kind -eq 'worker')    { $e.Proc = Start-Worker $e.P $e.Arg }
                elseif ($e.Kind -eq 'reverb')    { $e.Proc = Start-Reverb $e.P $e.Arg }
                elseif ($e.Kind -eq 'scheduler') { $e.Proc = Start-Scheduler $e.P }
                elseif ($e.Kind -eq 'stripe')    { $e.Proc = Start-Stripe $e.P }
                elseif ($e.Kind -eq 'ngrok')     { $e.Proc = Start-Ngrok $e.P }
            } catch { Write-Log "[watchdog] restart failed: $_" $e.P }
        }
    }

    foreach ($tp in @(Get-Tracked)) {
        $k = $tp.Name
        if ($script:HealthLast.ContainsKey($k) -and (((Get-Date) - $script:HealthLast[$k]).TotalSeconds -lt 60)) { continue }
        $script:HealthLast[$k] = Get-Date
        try { Test-WorkersHealth $tp } catch { Write-Log "[health] check failed: $_" $tp }
    }

    foreach ($name in @($script:EditorWatch.Keys)) {
        $since = $script:EditorWatch[$name]
        if ((((Get-Date) - $since).TotalSeconds -gt 40) -and (-not (Get-Process -Name 'Code', 'Cursor' -ErrorAction SilentlyContinue))) {
            $pp = New-Project $name
            Write-Log 'editor closed -> stopping everything' $pp
            Stop-Project $pp
        }
    }
}
$script:GlobalTick = { Invoke-Watchdog }

function Confirm-Exit {
    $mine = @()
    foreach ($q in @(Get-Tracked)) {
        $s = Read-State $q
        if ($s -and ($s.launcher_pid -eq $PID)) { $mine += $q }
    }
    if ($mine.Count -eq 0) { return $true }
    Clear-Host
    Write-Host ''
    Write-Host '  Services are still running:' -ForegroundColor Yellow
    foreach ($q in $mine) { Write-Host ('    {0,-24} {1}' -f $q.Name, (Get-SvcSummary $q)) -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '    ENTER = stop everything and exit'
    Write-Host '    K     = keep them running and exit (no auto-restart any more; stop later with: dev.bat stop)'
    Write-Host '    Esc   = stay'
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Enter') {
            foreach ($q in $mine) { Stop-Project $q $false }
            Stop-MysqlIfIdle
            return $true
        }
        if ($k.Key -eq 'K') { return $true }
        if ($k.Key -eq 'Escape') { return $false }
    }
}

function Get-SvcSummary($p) {
    $st = Read-State $p
    if (-not $st) { return '' }
    $parts = @()
    $w = @($st.pids.Keys | Where-Object { ($_ -like 'worker_*') -and (Test-PidAlive $st.pids[$_]) }).Count
    if ($w -gt 0) { $parts += "workers($w)" }
    if (Test-Svc $p 'cloudflared')        { $parts += 'tunnel' }
    if (Test-Svc $p 'reverb')             { $parts += 'reverb' }
    if (Test-Svc $p 'cloudflared_reverb') { $parts += 'reverb-tunnel' }
    if (Test-Svc $p 'scheduler')          { $parts += 'scheduler' }
    if (Test-Svc $p 'stripe')             { $parts += 'stripe' }
    if (Test-Svc $p 'ngrok')              { $parts += 'ngrok' }
    return ($parts -join ', ')
}

function Get-QueueList($p) {
    $dir = Join-Path $p.Path 'app\Jobs'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $found = New-Object 'System.Collections.Generic.List[string]'
    $needDefault = $false
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.php' -File -Recurse -ErrorAction SilentlyContinue)) {
        $txt = ''
        try { $txt = [System.IO.File]::ReadAllText($f.FullName) } catch { continue }
        $hit = $false
        foreach ($m in [regex]::Matches($txt, 'onQueue\(\s*[''"]([^''"]+)[''"]\s*\)')) { $hit = $true; if (-not $found.Contains($m.Groups[1].Value)) { $found.Add($m.Groups[1].Value) } }
        foreach ($m in [regex]::Matches($txt, '\$queue\s*=\s*[''"]([^''"]+)[''"]')) { $hit = $true; if (-not $found.Contains($m.Groups[1].Value)) { $found.Add($m.Groups[1].Value) } }
        if ((-not $hit) -and ($txt -match 'ShouldQueue')) { $needDefault = $true }
    }
    if ($needDefault -and (-not $found.Contains('default'))) { $found.Add('default') }
    return @($found | Sort-Object)
}

function Save-ProjectConfig($p, $Updates) {
    $d = [ordered]@{}
    if ($p.Cfg) { foreach ($x in $p.Cfg.PSObject.Properties) { $d[$x.Name] = $x.Value } }
    foreach ($k in $Updates.Keys) { $d[$k] = $Updates[$k] }
    Write-JsonFile $p.CfgPath $d
    Write-Log "config saved: $($p.CfgPath)" $p
}

function Start-WorkerSet($p, $Queues) {
    $names = @()
    foreach ($q in $Queues) {
        $id = 'worker_' + (Get-Label $q)
        if (Test-Svc $p $id) { continue }
        $proc = Start-Worker $p $q
        if ($proc) { Register-Svc $p $id 'worker' $q $proc; $names += (Get-Label $q) }
    }
    return $names
}

function Restart-WorkersIfRunning($p) {
    if (-not (Test-AnySvc $p 'worker_*')) { return '' }
    Stop-Svc $p 'worker_*' $true
    [void](Start-WorkerSet $p (Get-QueueList $p))
    return ' (workers restarted to pick up the new .env)'
}

function Restart-WorkersHub($p) {
    if (-not (Test-Artisan $p)) { return '! artisan not found' }
    $r = Invoke-Native (Get-PhpExe) @('artisan', 'queue:restart') $p.Path
    if (-not $r.Ok) { return '! queue:restart failed: ' + (Get-FirstLine $r.Out) }
    return 'restart sent - workers reload after their current job'
}

function Start-WorkersHub($p) {
    if (-not (Test-Artisan $p)) { return '! artisan not found - cannot run workers' }
    $queues = @(Get-QueueList $p)
    if ($queues.Count -eq 0) { return '! no queues found in app\Jobs (no ->onQueue(...) there) - nothing started' }
    Initialize-ProjectState $p
    $names = @(Start-WorkerSet $p $queues)
    if ($names.Count -eq 0) { return 'workers were already running' }
    return "workers started: $($names -join ', ')"
}

function Start-SiteHub($p, [bool]$OpenBrowser = $true) {
    $m = Start-LaragonServices $true $true
    if ($m) { return $m }
    Initialize-ProjectState $p
    $url = Get-ProjectUrl $p
    $st = Read-State $p
    if ($st) { $st.port = [int](Get-Cfg 'webPort'); if (-not (Test-Svc $p 'cloudflared')) { $st.url = $url }; Save-State $p $st }
    if (-not (Test-Svc $p 'cloudflared')) { Set-ProjectAppUrl $p $url }
    $note = ''
    if (-not (Test-HostRegistered (Get-ProjectHost $p))) {
        $note = "  [!] '$(Get-ProjectHost $p)' is not in the hosts file yet: Laragon > Menu > Apache > Reload (or restart Laragon)"
    }
    if ($OpenBrowser) {
        $target = $url
        if ($st -and $st.url) { $target = [string]$st.url }
        try { Open-Browser $target } catch { }
    }
    return "site: $url" + $note
}

function Start-TunnelHub($p) {
    $m = Start-LaragonServices $true $true
    if ($m) { return $m }
    Initialize-ProjectState $p
    $local = 'http://127.0.0.1:' + [int](Get-Cfg 'webPort')
    Write-Host ' Starting Cloudflare tunnel (can take up to a minute) ...' -ForegroundColor Cyan
    $url = Get-CloudflareUrl $p $local 'cloudflared' 'cf.log' @('--http-host-header', (Get-ProjectHost $p))
    if (-not $url) { Stop-Svc $p 'cloudflared' $true; return '! tunnel failed - is cloudflared installed? (see dev.log)' }
    $st = Read-State $p
    if ($st) { $st.url = $url; Save-State $p $st }
    Set-ProjectAppUrl $p $url
    try { Save-QrImage $p $url } catch { }
    try { Open-Browser $url } catch { }
    return "tunnel: $url" + (Restart-WorkersIfRunning $p)
}

function Stop-TunnelHub($p) {
    Stop-Svc $p 'cloudflared' $true
    $local = Get-ProjectUrl $p
    Set-ProjectAppUrl $p $local
    $st = Read-State $p
    if ($st) { $st.url = $local; Save-State $p $st }
    return 'tunnel stopped - APP_URL is local again' + (Restart-WorkersIfRunning $p)
}

function Start-ReverbHub($p) {
    if (-not (Test-Artisan $p)) { return '! artisan not found - cannot run reverb' }
    Initialize-ProjectState $p
    $rport = [int](Get-ReverbPort $p)
    $proc = Start-Reverb $p $rport
    if (-not $proc) { return '! reverb failed to start' }
    $st = Read-State $p
    if ($st) { $st.reverb_port = $rport; $st.reverb_url = $null; Save-State $p $st }
    Register-Svc $p 'reverb' 'reverb' $rport $proc
    $vals = Get-ReverbEnvValues $p '127.0.0.1' $rport 'http'
    Update-ProjectEnv $p $vals @('REVERB_HOST', 'REVERB_PORT', 'REVERB_SCHEME')
    return "reverb on :$rport" + (Restart-WorkersIfRunning $p)
}

function Stop-ReverbHub($p) {
    Stop-Svc $p 'cloudflared_reverb' $true
    Stop-Svc $p 'reverb' $true
    return 'reverb stopped (and its tunnel)'
}

function Start-ReverbTunnelHub($p) {
    if (-not (Test-Svc $p 'reverb')) { $m = Start-ReverbHub $p; if ("$m".StartsWith('!')) { return $m } }
    $st = Read-State $p
    if (-not $st -or -not $st.reverb_port) { return '! reverb is not running' }
    Write-Host ' Starting Cloudflare tunnel for Reverb (can take up to a minute) ...' -ForegroundColor Cyan
    $url = Get-CloudflareUrl $p "http://127.0.0.1:$($st.reverb_port)" 'cloudflared_reverb' 'cf_reverb.log'
    if (-not $url) { Stop-Svc $p 'cloudflared_reverb' $true; return '! reverb tunnel failed - is cloudflared installed?' }
    $st = Read-State $p
    if ($st) { $st.reverb_url = $url; Save-State $p $st }
    $vals = Get-ReverbEnvValues $p ([uri]$url).Host 443 'https'
    Update-ProjectEnv $p $vals @('REVERB_HOST', 'REVERB_PORT', 'REVERB_SCHEME')
    $note = ''
    if (Get-EnvValue $p.EnvPath 'VITE_REVERB_HOST') { $note = ' - rebuild assets if VITE_REVERB_* are literal values' }
    return "reverb tunnel: $(([uri]$url).Host)" + (Restart-WorkersIfRunning $p) + $note
}

function Stop-ReverbTunnelHub($p) {
    Stop-Svc $p 'cloudflared_reverb' $true
    $st = Read-State $p
    $extra = ''
    if ($st -and $st.reverb_port) {
        $st.reverb_url = $null; Save-State $p $st
        $vals = Get-ReverbEnvValues $p '127.0.0.1' ([int]$st.reverb_port) 'http'
        Update-ProjectEnv $p $vals @('REVERB_HOST', 'REVERB_PORT', 'REVERB_SCHEME')
        $extra = Restart-WorkersIfRunning $p
    }
    return 'reverb tunnel stopped - reverb is local again' + $extra
}

function Start-SchedulerHub($p) {
    if (-not (Test-Artisan $p)) { return '! artisan not found' }
    Initialize-ProjectState $p
    $proc = Start-Scheduler $p
    if (-not $proc) { return '! scheduler failed to start' }
    Register-Svc $p 'scheduler' 'scheduler' $null $proc
    return 'scheduler started (php artisan schedule:work)'
}

function Start-StripeHub($p) {
    if (-not (Get-CfgValue $p 'stripe')) { return '! add  "stripe": "/api/webhook/stripe"  to the project json first' }
    Initialize-ProjectState $p
    try { $proc = Start-Stripe $p } catch { return '! stripe CLI not found (winget install Stripe.StripeCli)' }
    if (-not $proc) { return '! stripe failed to start' }
    Register-Svc $p 'stripe' 'stripe' $null $proc
    return 'stripe listen started'
}

function Start-NgrokHub($p) {
    if (-not (Get-CfgValue $p 'ngrok')) { return '! add  "ngrok": { "domain": "xxx.ngrok-free.dev" }  to the project json first' }
    $m = Start-LaragonServices $true $false
    if ($m) { return $m }
    Initialize-ProjectState $p
    try { $proc = Start-Ngrok $p } catch { return '! ngrok not found (winget install ngrok.ngrok)' }
    if (-not $proc) { return '! ngrok failed to start' }
    Register-Svc $p 'ngrok' 'ngrok' $null $proc
    return 'ngrok started'
}

function Stop-OneSvcHub($p, [string]$Id, [string]$Text) {
    Stop-Svc $p $Id $true
    return $Text
}

function Resolve-EditorLauncher([string]$Ed) {
    $c = Get-Command $Ed -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $c) { return $null }
    $src = [string]$c.Source
    if ($src -match '\.(cmd|bat)$') {
        $base = [IO.Path]::GetFileNameWithoutExtension($src)
        $exe = Join-Path (Split-Path -Parent (Split-Path -Parent $src)) ($base + '.exe')
        if (Test-Path -LiteralPath $exe) { return @{ File = $exe; Hidden = $false } }
        return @{ File = $src; Hidden = $true }
    }
    return @{ File = $src; Hidden = $false }
}

function Open-EditorHub($p) {
    $ed = [string](Get-Cfg 'editor')
    if (-not $ed) { $ed = 'code' }
    $l = Resolve-EditorLauncher $ed
    if (-not $l) { return "! could not find '$ed' - set the editor in Settings" }
    try {
        if ($l.Hidden) { Start-Process -FilePath $l.File -ArgumentList ('"' + $p.Path + '"') -WindowStyle Hidden }
        else { Start-Process -FilePath $l.File -ArgumentList ('"' + $p.Path + '"') }
    } catch { return "! could not start '$ed' - set the editor in Settings" }
    if (Test-CfgFlag $p 'stopWithEditor' $false) { $script:EditorWatch[$p.Name] = Get-Date }
    return 'editor opened'
}

function Invoke-ProjectCommand($p, [string]$Title, [string]$File, [string[]]$ArgList) {
    Clear-Host
    Write-Host ''
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ("  > " + $File + ' ' + ($ArgList -join ' ')) -ForegroundColor DarkGray
    Write-Host ''
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    Push-Location -LiteralPath $p.Path
    $code = 0
    try {
        & $File @ArgList 2>&1 | ForEach-Object { Write-Host "$_" }
        $code = $LASTEXITCODE
    } catch { Write-Host "  $_" -ForegroundColor Red; $code = -1 }
    finally { Pop-Location; $ErrorActionPreference = $old }
    Write-Log "$Title -> exit $code" $p
    return $code
}

function Invoke-BuildAssets($p) {
    $npm = Get-NpmCmd
    if (-not $npm) { return '! npm not found (install Node.js)' }
    $c = Invoke-ProjectCommand $p 'npm run build' $npm @('run', 'build')
    if ($c -eq 0) { return 'assets built' }
    return "! npm run build failed (exit $c)"
}

function Start-AllHub($p) {
    Clear-Host
    Write-Host ''
    Write-Host "  Starting $($p.Name)" -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 60)) -ForegroundColor DarkGray
    $problems = @()
    $step = { param($t) Write-Host "  - $t" -ForegroundColor White }

    & $step 'Laragon (web server + MySQL)'
    $m = Start-LaragonServices $true $true
    if ($m) { Write-Host "    $m" -ForegroundColor Red; Pause-Key; return $m }
    Initialize-ProjectState $p

    if (Test-CfgFlag $p 'openEditor' $true) { & $step 'editor'; [void](Open-EditorHub $p) }

    $queues = @(Get-QueueList $p)
    if ((Test-Artisan $p) -and (Test-NeedsReverb $p)) {
        & $step 'Reverb'
        $m = Start-ReverbHub $p
        if ($m.StartsWith('!')) { $problems += $m }
        if ((Test-CfgFlag $p 'reverbTunnel' $false) -and (-not $m.StartsWith('!'))) {
            & $step 'Reverb tunnel'
            $m = Start-ReverbTunnelHub $p
            if ($m.StartsWith('!')) { $problems += $m }
        }
    }
    if ($queues.Count -gt 0 -and (Test-Artisan $p)) {
        & $step ('queue workers: ' + ($queues -join ', '))
        $m = Start-WorkersHub $p
        if ($m.StartsWith('!')) { $problems += $m }
    }
    if (Test-CfgFlag $p 'schedule' $false) { & $step 'scheduler'; $m = Start-SchedulerHub $p; if ($m.StartsWith('!')) { $problems += $m } }
    if (Get-CfgValue $p 'stripe') { & $step 'stripe webhook'; $m = Start-StripeHub $p; if ($m.StartsWith('!')) { $problems += $m } }
    if (Get-CfgValue $p 'ngrok')  { & $step 'ngrok'; $m = Start-NgrokHub $p; if ($m.StartsWith('!')) { $problems += $m } }

    if ((Test-CfgFlag $p 'build' $false) -and (Test-Artisan $p)) {
        & $step 'artisan optimize:clear'
        [void](Invoke-ProjectCommand $p 'artisan optimize:clear' (Get-PhpExe) @('artisan', 'optimize:clear'))
        & $step 'npm run build'
        $m = Invoke-BuildAssets $p
        if ($m.StartsWith('!')) { $problems += $m }
    }

    if (Test-CfgFlag $p 'tunnel' $false) {
        & $step 'Cloudflare tunnel'
        $m = Start-TunnelHub $p
        if ($m.StartsWith('!')) { $problems += $m }
        return ("started" + $(if ($problems.Count -gt 0) { '  ' + ($problems -join ' | ') } else { '' }))
    }
    & $step 'site'
    $m = Start-SiteHub $p $true
    if ($m.StartsWith('!')) { $problems += $m }
    if ($problems.Count -gt 0) { return ('! ' + (($problems | ForEach-Object { $_.TrimStart('!').Trim() }) -join ' | ')) }
    return "started - $m"
}
