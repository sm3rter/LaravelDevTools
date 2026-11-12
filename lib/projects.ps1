$script:HubFlash = ''

function Get-GitBranchQuick($p) {
    $head = Join-Path $p.Path '.git\HEAD'
    if (-not (Test-Path -LiteralPath $head)) { return '' }
    $t = (Read-Shared $head).Trim()
    if ($t -match '^ref: refs/heads/(.+)$') { return $Matches[1] }
    if ($t.Length -gt 7) { return ('detached ' + $t.Substring(0, 7)) }
    return $t
}

function Show-ProjectsScreen {
    $projects = @(Get-Projects)
    $items = @()
    foreach ($q in $projects) {
        $miss = @(Get-Missing $q)
        $st = Get-Status $q
        if ($st) {
            $sum = Get-SvcSummary $q
            if (-not $sum) { $sum = 'idle' }
            $items += @{ label = $q.Name; note = "* $sum"; color = 'Yellow' }
        }
        elseif ($miss.Count -gt 0) { $items += @{ label = $q.Name; note = ('folder (missing: ' + ($miss -join ', ') + ')'); color = 'DarkYellow' } }
        else { $items += @{ label = $q.Name; note = ('Laravel   ' + (Get-ProjectHost $q)); color = 'Green' } }
    }
    $items += @{ label = '+ Clone a repository...'; note = 'git clone into www'; color = 'Cyan' }

    $ls = Get-LaragonStatus
    $web = 'stopped'; if ($ls.Web) { $web = 'running' }
    $db = 'stopped'; if ($ls.Mysql) { $db = 'running' }
    $app = 'closed'; if ($ls.App) { $app = 'open' }
    $panel = @("Laragon: $app    web server: $web (port $(Get-Cfg 'webPort'))    MySQL: $db (port $(Get-Cfg 'mysqlPort'))")

    $key = 'projects'
    $m = @{ Title = 'Projects - Laragon'; Subtitle = (Get-WwwDir); Items = $items; Panel = $panel; Start = (Get-LastSel $key) }
    $m += (Get-NavArgs $true)
    $i = Show-Menu @m
    if (Invoke-NavKey $i @{ type = 'home' }) { return }
    Set-LastSel $key $i
    if ($i -lt $projects.Count) { Open-Loc @{ type = 'project'; name = $projects[$i].Name }; return }
    $msg = Invoke-GitClone
    if ($msg) { $script:HubFlash = $msg }
}

function Show-ProjectCommands($p) {
    $start = 0
    while ($true) {
        $art = Test-Artisan $p
        $items = @(
            @{ label = 'artisan optimize:clear';       note = 'clear all caches';           enabled = $art },
            @{ label = 'artisan migrate';              note = '';                           enabled = $art },
            @{ label = 'artisan migrate:fresh --seed'; note = 'DELETES all tables';         enabled = $art; danger = $true },
            @{ label = 'artisan storage:link';         note = '';                           enabled = $art },
            @{ label = 'artisan queue:restart';        note = 'workers pick up new code';   enabled = $art },
            @{ label = 'artisan ...';                  note = 'type your own command';      enabled = $art },
            @{ label = 'composer install';             note = '' },
            @{ label = 'npm install';                  note = '' },
            @{ label = 'npm run build';                note = 'compile assets' }
        )
        $i = Show-Menu -Title "Commands - $($p.Name)" -Subtitle $p.Path -Items $items -Start $start
        if ($i -lt 0) { return }
        $start = $i
        $php = Get-PhpExe
        $code = $null
        if     ($i -eq 0) { $code = Invoke-ProjectCommand $p 'artisan optimize:clear' $php @('artisan', 'optimize:clear') }
        elseif ($i -eq 1) { $code = Invoke-ProjectCommand $p 'artisan migrate' $php @('artisan', 'migrate') }
        elseif ($i -eq 2) {
            if (Confirm-Action "migrate:fresh --seed DELETES every table of '$($p.Name)'. Continue?") {
                $code = Invoke-ProjectCommand $p 'artisan migrate:fresh --seed' $php @('artisan', 'migrate:fresh', '--seed')
            }
        }
        elseif ($i -eq 3) { $code = Invoke-ProjectCommand $p 'artisan storage:link' $php @('artisan', 'storage:link') }
        elseif ($i -eq 4) { $code = Invoke-ProjectCommand $p 'artisan queue:restart' $php @('artisan', 'queue:restart') }
        elseif ($i -eq 5) {
            $c = Read-Input 'artisan' 'php artisan' @('Example:  make:model Post -m')
            if ($c) { $code = Invoke-ProjectCommand $p ('artisan ' + $c) $php (@('artisan') + @($c -split '\s+')) }
        }
        elseif ($i -eq 6) {
            $cmp = Get-ComposerCmd
            if ($cmp) { $code = Invoke-ProjectCommand $p 'composer install' $cmp @('install') }
            else { Clear-Host; Show-Fail 'composer not found (not in PATH and not in Laragon\bin\composer)' }
        }
        elseif ($i -eq 7) {
            $npm = Get-NpmCmd
            if ($npm) { $code = Invoke-ProjectCommand $p 'npm install' $npm @('install') }
            else { Clear-Host; Show-Fail 'npm not found (install Node.js)' }
        }
        elseif ($i -eq 8) {
            $npm = Get-NpmCmd
            if ($npm) { $code = Invoke-ProjectCommand $p 'npm run build' $npm @('run', 'build') }
            else { Clear-Host; Show-Fail 'npm not found (install Node.js)' }
        }
        if ($null -ne $code) {
            Write-Host ''
            if ($code -eq 0) { Write-Host '  Done.' -ForegroundColor Green } else { Write-Host "  Finished with exit code $code" -ForegroundColor Yellow }
            Pause-Key
        }
    }
}

function Show-ProjectScreen($Loc) {
    $name = $Loc.name
    $p = New-Project $name
    if (-not (Test-Path -LiteralPath $p.Path -PathType Container)) { Remove-HistLoc 'project' $name; return }

    $miss = @(Get-Missing $p)
    $valid = ($miss.Count -eq 0)
    $st = Get-Status $p
    $foreign = $false
    if ($st) { $s = Read-State $p; if ($s -and ($s.launcher_pid -ne $PID) -and (Test-PidAlive $s.launcher_pid)) { $foreign = $true } }
    $can = $valid -and (-not $foreign)
    $why = ''
    if ($foreign) { $why = 'running in another window' } elseif (-not $valid) { $why = 'missing: ' + ($miss -join ', ') }
    $reverbOk = $can -and (Test-NeedsReverb $p)
    $queues = @(Get-QueueList $p)
    $qtxt = 'no queues in app\Jobs'
    if ($queues.Count -gt 0) { $qtxt = $queues -join ', ' }
    $any = [bool](Get-SvcSummary $p)
    $url = Get-ProjectUrl $p
    $stNow = Read-State $p

    $items = @(); $acts = @()
    $startNote = ''
    if (-not $can) { $startNote = $why }
    $items += @{ label = 'Start everything'; note = $startNote; color = 'Green'; enabled = $can }; $acts += 'all'

    $siteNote = $url
    if ($stNow -and $stNow.url -and ("$($stNow.url)" -ne $url)) { $siteNote = "$($stNow.url)  (tunnel)" }
    $items += @{ label = 'Open site'; note = $siteNote; color = 'Cyan'; enabled = $can }; $acts += 'site'
    $items += @{ label = 'Open in editor'; note = ''; color = 'DarkGray' }; $acts += 'editor'

    if (Test-AnySvc $p 'worker_*') {
        $items += @{ label = 'Restart workers'; note = 'queue:restart'; color = 'DarkGray'; enabled = $can }; $acts += 'workers_re'
        $items += @{ label = 'Stop workers'; note = "on: $qtxt"; color = 'Green'; enabled = $can }; $acts += 'workers_off'
    } else {
        $n = $qtxt; if (-not $can) { $n = $why }
        $items += @{ label = 'Start workers'; note = $n; color = 'DarkGray'; enabled = $can }; $acts += 'workers_on'
    }

    if (Test-Svc $p 'cloudflared') { $items += @{ label = 'Stop tunnel'; note = "on: $($stNow.url)"; color = 'Green'; enabled = $can }; $acts += 'cf_off' }
    else { $items += @{ label = 'Start tunnel'; note = $(if ($can) { 'Cloudflare' } else { $why }); color = 'DarkGray'; enabled = $can }; $acts += 'cf_on' }

    if (Test-Svc $p 'reverb') { $items += @{ label = 'Stop Reverb'; note = "on: port $($stNow.reverb_port)"; color = 'Green'; enabled = $can }; $acts += 'rv_off' }
    elseif ($reverbOk) { $items += @{ label = 'Start Reverb'; note = ''; color = 'DarkGray'; enabled = $true }; $acts += 'rv_on' }

    if (Test-Svc $p 'cloudflared_reverb') { $items += @{ label = 'Stop Reverb tunnel'; note = "on: $($stNow.reverb_url)"; color = 'Green'; enabled = $can }; $acts += 'rt_off' }
    elseif ($reverbOk) { $items += @{ label = 'Start Reverb tunnel'; note = ''; color = 'DarkGray'; enabled = $true }; $acts += 'rt_on' }

    $art = $can -and (Test-Artisan $p)
    if (Test-Svc $p 'scheduler') { $items += @{ label = 'Stop scheduler'; note = 'on'; color = 'Green'; enabled = $can }; $acts += 'sc_off' }
    else { $items += @{ label = 'Start scheduler'; note = ''; color = 'DarkGray'; enabled = $art }; $acts += 'sc_on' }

    $hasStripe = [bool](Get-CfgValue $p 'stripe')
    if (Test-Svc $p 'stripe') { $items += @{ label = 'Stop Stripe webhook'; note = 'on'; color = 'Green'; enabled = $can }; $acts += 'st_off' }
    elseif ($hasStripe) { $items += @{ label = 'Start Stripe webhook'; note = ''; color = 'DarkGray'; enabled = $can }; $acts += 'st_on' }

    $hasNgrok = [bool](Get-CfgValue $p 'ngrok')
    if (Test-Svc $p 'ngrok') { $items += @{ label = 'Stop ngrok'; note = 'on'; color = 'Green'; enabled = $can }; $acts += 'ng_off' }
    elseif ($hasNgrok) { $items += @{ label = 'Start ngrok'; note = ''; color = 'DarkGray'; enabled = $can }; $acts += 'ng_on' }

    $items += @{ label = 'Commands'; note = 'artisan, composer, npm'; color = 'DarkGray' }; $acts += 'commands'

    $br = Get-GitBranchQuick $p
    $gitNote = 'no repository'
    if ($br) { $gitNote = $br }
    $items += @{ label = 'Git'; note = $gitNote; color = 'Cyan' }; $acts += 'git'
    $items += @{ label = 'Backup'; note = (Get-LastBackupText $name); color = 'Cyan' }; $acts += 'backup'
    $items += @{ label = 'Zip project'; note = ''; color = 'Cyan' }; $acts += 'zip'
    $items += @{ label = 'Apply patches'; note = ''; color = 'Cyan' }; $acts += 'patches'
    if ($any) { $items += @{ label = 'Stop everything'; note = (Get-SvcSummary $p); color = 'Red'; enabled = (-not $foreign); danger = $true }; $acts += 'stopall' }

    $flash = $script:HubFlash; $script:HubFlash = ''
    $fc = 'Green'
    if ($flash.StartsWith('!')) { $fc = 'Red' }
    $key = 'project:' + $name
    $m = @{ Title = $name; Subtitle = $p.Path; Items = $items; Start = (Get-LastSel $key); Flash = $flash.TrimStart('!').Trim(); FlashColor = $fc }
    $m += (Get-NavArgs $true)
    $i = Show-Menu @m
    if (Invoke-NavKey $i @{ type = 'projects' }) { return }
    Set-LastSel $key $i

    $a = $acts[$i]
    $msg = ''
    $busyText = @{ all = 'Starting everything'; site = 'Starting the site'; editor = 'Opening the editor'; workers_on = 'Starting the queue workers'; workers_re = 'Restarting the queue workers'; workers_off = 'Stopping the queue workers'
                   cf_on = 'Starting the tunnel'; cf_off = 'Stopping the tunnel'; rv_on = 'Starting Reverb'; rv_off = 'Stopping Reverb'; rt_on = 'Starting the Reverb tunnel'; rt_off = 'Stopping the Reverb tunnel'
                   sc_on = 'Starting the scheduler'; sc_off = 'Stopping the scheduler'; st_on = 'Starting the Stripe webhook'; st_off = 'Stopping the Stripe webhook'
                   ng_on = 'Starting ngrok'; ng_off = 'Stopping ngrok'; stopall = 'Stopping everything' }
    if ($busyText.ContainsKey($a)) { Show-Busy $busyText[$a] }

    if     ($a -eq 'all')         { $msg = @(Start-AllHub $p)[-1] }
    elseif ($a -eq 'site')        { $msg = @(Start-SiteHub $p $true)[-1] }
    elseif ($a -eq 'editor')      { $msg = @(Open-EditorHub $p)[-1] }
    elseif ($a -eq 'workers_on')  { $msg = @(Start-WorkersHub $p)[-1] }
    elseif ($a -eq 'workers_re')  { $msg = @(Restart-WorkersHub $p)[-1] }
    elseif ($a -eq 'workers_off') { Stop-Svc $p 'worker_*' $true; $msg = 'workers stopped' }
    elseif ($a -eq 'cf_on')       { $msg = @(Start-TunnelHub $p)[-1] }
    elseif ($a -eq 'cf_off')      { $msg = @(Stop-TunnelHub $p)[-1] }
    elseif ($a -eq 'rv_on')       { $msg = @(Start-ReverbHub $p)[-1] }
    elseif ($a -eq 'rv_off')      { $msg = @(Stop-ReverbHub $p)[-1] }
    elseif ($a -eq 'rt_on')       { $msg = @(Start-ReverbTunnelHub $p)[-1] }
    elseif ($a -eq 'rt_off')      { $msg = @(Stop-ReverbTunnelHub $p)[-1] }
    elseif ($a -eq 'sc_on')       { $msg = @(Start-SchedulerHub $p)[-1] }
    elseif ($a -eq 'sc_off')      { Stop-Svc $p 'scheduler' $true; $msg = 'scheduler stopped' }
    elseif ($a -eq 'st_on')       { $msg = @(Start-StripeHub $p)[-1] }
    elseif ($a -eq 'st_off')      { Stop-Svc $p 'stripe' $true; $msg = 'stripe webhook stopped' }
    elseif ($a -eq 'ng_on')       { $msg = @(Start-NgrokHub $p)[-1] }
    elseif ($a -eq 'ng_off')      { Stop-Svc $p 'ngrok' $true; $msg = 'ngrok stopped' }
    elseif ($a -eq 'commands')    { Show-ProjectCommands $p }
    elseif ($a -eq 'git')         { Invoke-GitMenu $p }
    elseif ($a -eq 'backup')      { Show-ProjectBackupMenu $p }
    elseif ($a -eq 'zip')         { [void](Invoke-ZipProject $p); $msg = $script:ZipResult }
    elseif ($a -eq 'patches')     { [void](Invoke-ApplyPatches $p); Pause-Key }
    elseif ($a -eq 'stopall')     { Stop-Project $p; $msg = 'everything stopped' }
    $script:HubFlash = [string]$msg
}

function Show-ProjectBackupMenu($p) {
    $i = Show-Menu -Title "Backup - $($p.Name)" -Subtitle (Get-BackupDir) -Items @(
        @{ label = 'Files + database'; note = (Get-LastBackupText $p.Name); color = 'Green' },
        @{ label = 'Files only'; note = ''; color = 'DarkGray' },
        @{ label = 'Database only'; note = ''; color = 'DarkGray' })
    if ($i -lt 0) { return }
    $mode = @('both', 'files', 'db')[$i]
    Invoke-BackupRun $p $p.Path $p.Name $mode
}
