$script:ZipNameRx = '^(\d{4}-\d{2}-\d{2})_(\d{2}-\d{2}-\d{2})_(.+)\.zip$'
$script:SqlNameRx = '^(.+)_backup_(\d{4}-\d{2}-\d{2})_(\d{2}-\d{2}-\d{2})\.sql$'

function Get-BackupStamp { return (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss') }

function Initialize-BackupDir {
    $dir = Get-BackupDir
    if (-not $dir) { return $false }
    try { New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null; return $true } catch { return $false }
}

function Get-FilePlan([IO.DirectoryInfo]$Dir, [string]$Rel, [string[]]$Names, [string[]]$Paths) {
    $files = New-Object 'System.Collections.Generic.List[object]'
    foreach ($e in $Dir.GetFileSystemInfos()) {
        if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($Rel) { $r = "$Rel/$($e.Name)" } else { $r = $e.Name }
        if ($e -is [IO.DirectoryInfo]) {
            if ($Names -contains $e.Name) { continue }
            if ($Paths -contains $r) { continue }
            $files.AddRange((Get-FilePlan $e $r $Names $Paths))
        } else {
            $files.Add(@{ Full = $e.FullName; Entry = $r })
        }
    }
    return $files
}

function Compress-Folder([string]$Src, [string]$Out, [string[]]$ExcludeNames, [string[]]$ExcludePaths) {
    $names = @($ExcludeNames | Where-Object { $_ })
    $paths = @($ExcludePaths | Where-Object { $_ } | ForEach-Object { ([string]$_).Replace('\', '/').Trim('/') })
    $seven = Find-7Zip
    if ($seven) {
        $a = @('a', '-tzip', '-mx5', '-bso0', '-bsp0', $Out, (Join-Path $Src '*'))
        foreach ($n in $names) { $a += ('-xr!' + $n) }
        foreach ($x in $paths) { $a += ('-x!' + $x.Replace('/', '\') + '\*') }
        $r = Invoke-Native $seven $a

        if (($r.Code -eq 0) -or ($r.Code -eq 1)) {
            $msg = ''
            if ($r.Code -eq 1) { $msg = 'some files could not be read (locked) and were skipped' }
            return @{ ok = $true; msg = $msg; tool = '7-Zip' }
        }
        return @{ ok = $false; msg = ('7-Zip failed: ' + (Get-FirstLine $r.Out)); tool = '7-Zip' }
    }
    $plan = Get-FilePlan (New-Object IO.DirectoryInfo($Src)) '' $names $paths
    if ($plan.Count -eq 0) { return @{ ok = $false; msg = 'nothing to zip'; tool = '.NET' } }
    $w = Write-ZipFromPlan $plan $Out
    if (-not $w.ok) { return @{ ok = $false; msg = $w.msg; tool = '.NET' } }
    $msg = ''
    if ($w.failed.Count -gt 0) { $msg = "$($w.failed.Count) unreadable file(s) skipped" }
    return @{ ok = $true; msg = $msg; tool = '.NET zip (install 7-Zip for faster backups)' }
}

function Get-ProjectDb($p) {
    $conn = Get-EnvValue $p.EnvPath 'DB_CONNECTION'
    if (-not $conn) { $conn = 'mysql' }
    $h = Get-EnvValue $p.EnvPath 'DB_HOST';     if (-not $h) { $h = '127.0.0.1' }
    $po = Get-EnvValue $p.EnvPath 'DB_PORT';    if (-not $po) { $po = [string](Get-Cfg 'mysqlPort') }
    $u = Get-EnvValue $p.EnvPath 'DB_USERNAME'; if (-not $u) { $u = [string](Get-Cfg 'mysqlUser') }
    $pw = Get-EnvValue $p.EnvPath 'DB_PASSWORD'
    if ($null -eq $pw) { $pw = [string](Get-Cfg 'mysqlPassword') }
    return [pscustomobject]@{
        Conn = $conn.ToLower(); Host = $h; Port = $po; User = $u; Pass = $pw
        Name = (Get-EnvValue $p.EnvPath 'DB_DATABASE')
    }
}

function New-MysqlCnf($Db) {
    $f = Join-Path ([IO.Path]::GetTempPath()) ('dt_' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '.cnf')
    $pw = ([string]$Db.Pass).Replace('\', '\\').Replace('"', '\"')
    $txt = "[client]`r`nuser=$($Db.User)`r`npassword=`"$pw`"`r`nhost=$($Db.Host)`r`nport=$($Db.Port)`r`n"
    [IO.File]::WriteAllText($f, $txt, (New-Object Text.UTF8Encoding($false)))
    return $f
}

function Invoke-DbDump($p, [string]$Stamp) {
    $db = Get-ProjectDb $p
    if (-not $db.Name) { return @{ ok = $false; msg = 'DB_DATABASE is empty in the .env' } }
    $dir = Get-BackupDir

    if ($db.Conn -eq 'sqlite') {
        $src = [string]$db.Name
        if (-not [IO.Path]::IsPathRooted($src)) {
            $src = Join-Path $p.Path ('database\' + $db.Name)
            if (-not (Test-Path -LiteralPath $src)) { $src = Join-Path $p.Path $db.Name }
        }
        if (-not (Test-Path -LiteralPath $src)) { return @{ ok = $false; msg = "sqlite file not found: $src" } }
        $out = Join-Path $dir ((Split-Path $src -Leaf) + "_backup_$Stamp.sqlite")
        Copy-Item -LiteralPath $src -Destination $out -Force
        return @{ ok = $true; file = $out; size = (Get-Item -LiteralPath $out).Length; msg = '' }
    }

    $dump = Get-MysqlDumpExe
    if (-not $dump) { return @{ ok = $false; msg = 'mysqldump.exe not found under Laragon\bin\mysql' } }
    $m = Start-LaragonServices $false $true
    if ($m) { return @{ ok = $false; msg = $m.TrimStart('!').Trim() } }

    $out = Join-Path $dir ("$($db.Name)_backup_$Stamp.sql")
    $cnf = New-MysqlCnf $db
    try {
        $a = @("--defaults-extra-file=$cnf", '--single-transaction', '--routines', '--triggers', '--events',
               '--default-character-set=utf8mb4', "--result-file=$out", $db.Name)
        $r = Invoke-Native $dump $a
    } finally { Remove-Item -LiteralPath $cnf -Force -ErrorAction SilentlyContinue }
    $ok = $r.Ok -and (Test-Path -LiteralPath $out) -and ((Get-Item -LiteralPath $out).Length -gt 100)
    if (-not $ok) {
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
        return @{ ok = $false; msg = ('mysqldump failed: ' + (Get-FirstLine $r.Out)) }
    }
    return @{ ok = $true; file = $out; size = (Get-Item -LiteralPath $out).Length; msg = '' }
}

function Invoke-BackupRun($p, [string]$Path, [string]$Name, [string]$Mode) {
    Clear-Host
    Write-Host ''
    Write-Host "  Backup - $Name" -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 60)) -ForegroundColor DarkGray
    if (-not (Initialize-BackupDir)) {
        Write-Host "  [ERROR] cannot use the backup folder: $(Get-BackupDir)" -ForegroundColor Red
        Write-Host '          Set it in Settings (or config.json > backupDir).' -ForegroundColor Yellow
        Pause-Key
        return
    }
    $stamp = Get-BackupStamp
    $dir = Get-BackupDir
    $good = 0; $bad = 0

    if (($Mode -eq 'both') -or ($Mode -eq 'files')) {
        $out = Join-Path $dir ("${stamp}_$Name.zip")
        Write-Host '  [files] compressing ...' -ForegroundColor White
        $r = Compress-Folder $Path $out @(Get-Cfg 'backupExcludeNames') @(Get-Cfg 'backupExcludePaths')
        if ($r.ok -and (Test-Path -LiteralPath $out)) {
            Write-Host ("  [files] OK  " + (Format-Size (Get-Item -LiteralPath $out).Length) + "  ($($r.tool))") -ForegroundColor Green
            Write-Host "          $out" -ForegroundColor DarkGray
            if ($r.msg) { Write-Host "          note: $($r.msg)" -ForegroundColor Yellow }
            $good++
        } else {
            Write-Host "  [files] FAILED  $($r.msg)" -ForegroundColor Red
            Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
            $bad++
        }
    }
    if (($Mode -eq 'both') -or ($Mode -eq 'db')) {
        if (-not $p) {
            Write-Host '  [database] skipped (a plain folder has no .env)' -ForegroundColor DarkGray
        } elseif (-not (Test-Path -LiteralPath $p.EnvPath)) {
            Write-Host '  [database] skipped - no .env in the project' -ForegroundColor Yellow
        } else {
            Write-Host '  [database] dumping ...' -ForegroundColor White
            $d = Invoke-DbDump $p $stamp
            if ($d.ok) {
                Write-Host ("  [database] OK  " + (Format-Size $d.size)) -ForegroundColor Green
                Write-Host "             $($d.file)" -ForegroundColor DarkGray
                $good++
            } else {
                Write-Host "  [database] FAILED  $($d.msg)" -ForegroundColor Red
                $bad++
            }
        }
    }
    Write-Log "backup $Name mode=$Mode ok=$good failed=$bad"
    Write-Host ''
    if ($bad -eq 0) { Write-Host '  Backup completed.' -ForegroundColor Green } else { Write-Host "  Finished with $bad problem(s)." -ForegroundColor Yellow }
    Wait-Key
}

function Select-ProjectModal([string]$Title = 'Pick a project', [bool]$OnlyLaravel = $false) {
    $projects = @(Get-Projects)
    if ($projects.Count -eq 0) {
        Clear-Host
        Show-Fail ('No folders inside ' + (Get-WwwDir) + '  (set the Laragon path in Settings)')
        return $null
    }
    $items = @()
    foreach ($q in $projects) {
        $miss = @(Get-Missing $q)
        $note = ''; $col = 'DarkGray'
        if (Get-Status $q) { $note = '* running'; $col = 'Yellow' }
        elseif ($miss.Count -eq 0) { $note = 'Laravel'; $col = 'Green' }
        else { $note = 'folder' }
        $items += @{ label = $q.Name; note = $note; color = $col }
    }
    $i = Show-Menu -Title $Title -Items $items -Subtitle (Get-WwwDir)
    if ($i -lt 0) { return $null }
    return $projects[$i]
}

function Invoke-BackupProject([string]$Mode) {
    $p = Select-ProjectModal 'Backup - pick the project'
    if (-not $p) { return }
    Invoke-BackupRun $p $p.Path $p.Name $Mode
}

function Invoke-BackupFolder {
    $f = Select-FolderMenu -Title 'Backup - pick any folder' -StartDir '' -Initial (Get-WwwDir)
    if (-not $f) { return }
    $name = Split-Path $f -Leaf
    if (-not $name) { $name = 'folder' }
    Invoke-BackupRun $null $f (ConvertTo-SafeName $name) 'files'
}

function Get-BackupFiles {
    $dir = Get-BackupDir
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return @() }
    $res = @()
    foreach ($f in (Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue)) {
        $kind = ''; $key = ''; $when = $null
        $m = [regex]::Match($f.Name, $script:ZipNameRx)
        if ($m.Success) { $kind = 'zip'; $key = $m.Groups[3].Value; $when = [datetime]::ParseExact($m.Groups[1].Value + ' ' + $m.Groups[2].Value.Replace('-', ':'), 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) }
        else {
            $m = [regex]::Match($f.Name, $script:SqlNameRx)
            if ($m.Success) { $kind = 'sql'; $key = $m.Groups[1].Value; $when = [datetime]::ParseExact($m.Groups[2].Value + ' ' + $m.Groups[3].Value.Replace('-', ':'), 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) }
        }
        if ($kind) { $res += [pscustomobject]@{ File = $f; Kind = $kind; Key = $key; When = $when; Day = $when.ToString('yyyy-MM-dd') } }
    }
    return $res
}

function Get-LastBackupText([string]$Name) {
    $all = @(Get-BackupFiles | Where-Object { ($_.Kind -eq 'zip') -and ($_.Key -ieq $Name) } | Sort-Object When -Descending)
    if ($all.Count -eq 0) { return 'no backup yet' }
    return ('last: ' + (Format-Ago $all[0].When))
}

function Invoke-DbImport($Db, [string]$SqlFile) {
    $mysql = Get-MysqlClientExe
    if (-not $mysql) { return @{ ok = $false; msg = 'mysql.exe not found under Laragon\bin\mysql' } }
    $m = Start-LaragonServices $false $true
    if ($m) { return @{ ok = $false; msg = $m.TrimStart('!').Trim() } }
    $cnf = New-MysqlCnf $Db
    $err = Join-Path ([IO.Path]::GetTempPath()) ('dt_err_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
    try {
        $q = 'CREATE DATABASE IF NOT EXISTS `' + $Db.Name + '` CHARACTER SET utf8mb4'
        $c = Invoke-Native $mysql @("--defaults-extra-file=$cnf", '-e', $q)
        if (-not $c.Ok) { return @{ ok = $false; msg = ('create database failed: ' + (Get-FirstLine $c.Out)) } }
        $argStr = '--defaults-extra-file="' + $cnf + '" --default-character-set=utf8mb4 ' + $Db.Name
        $proc = Start-Process -FilePath $mysql -ArgumentList $argStr -RedirectStandardInput $SqlFile -RedirectStandardError $err -NoNewWindow -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            return @{ ok = $false; msg = ('import failed: ' + (Get-FirstLine (Read-Shared $err))) }
        }
        return @{ ok = $true; msg = '' }
    } finally {
        Remove-Item -LiteralPath $cnf, $err -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-RestoreBackup {
    $zips = @(Get-BackupFiles | Where-Object { $_.Kind -eq 'zip' } | Sort-Object When -Descending)
    if ($zips.Count -eq 0) { Clear-Host; Show-Fail ('No project backups in ' + (Get-BackupDir)); return }
    $items = @()
    foreach ($z in $zips) {
        $items += @{ label = $z.Key; note = ($z.When.ToString('yyyy-MM-dd HH:mm') + '   ' + (Format-Size $z.File.Length)); color = 'DarkGray' }
    }
    $i = Show-Menu -Title 'Restore - pick a backup (newest first)' -Items $items -Subtitle (Get-BackupDir)
    if ($i -lt 0) { return }
    $z = $zips[$i]
    $name = $z.Key
    $target = Join-Path (Get-WwwDir) $name

    $ask = Read-Input 'Restore' 'restore into (ENTER = default)' @("backup : $($z.File.Name)", "default: $target", 'The current folder (if any) is MOVED to a safe place first, not deleted.') $target
    if (-not $ask) { return }
    $target = $ask.Trim('"')

    if (-not (Confirm-Action ("Restore '$name' into $target ?"))) { return }

    Clear-Host
    Write-Host ''
    Write-Host "  Restore - $name" -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 60)) -ForegroundColor DarkGray

    $proj = Find-ProjectByName (Split-Path $target -Leaf)
    if ($proj -and (Get-Status $proj)) { Write-Host '  stopping the running services of this project ...' -ForegroundColor DarkGray; Stop-Project $proj }

    if (Test-Path -LiteralPath $target) {
        $safeRoot = Join-Path (Get-BackupDir) '_before-restore'
        New-Item -ItemType Directory -Force -Path $safeRoot | Out-Null
        $safe = Join-Path $safeRoot ((Split-Path $target -Leaf) + '_' + (Get-BackupStamp))
        Write-Host "  moving the current folder to: $safe" -ForegroundColor DarkGray
        try { Move-Item -LiteralPath $target -Destination $safe -ErrorAction Stop }
        catch {
            Write-Host "  [ERROR] could not move the current folder (a file is locked - close the editor / terminals): $_" -ForegroundColor Red
            Wait-Key
            return
        }
    }
    New-Item -ItemType Directory -Force -Path $target | Out-Null

    Write-Host '  extracting ...' -ForegroundColor White
    $seven = Find-7Zip
    $okx = $false
    if ($seven) {
        $r = Invoke-Native $seven @('x', '-y', '-bso0', '-bsp0', "-o$target", $z.File.FullName)
        $okx = ($r.Code -le 1)
        if (-not $okx) { Write-Host ('  [ERROR] ' + (Get-FirstLine $r.Out)) -ForegroundColor Red }
    } else {
        try { Expand-Archive -LiteralPath $z.File.FullName -DestinationPath $target -Force -ErrorAction Stop; $okx = $true }
        catch { Write-Host "  [ERROR] $_" -ForegroundColor Red }
    }
    if (-not $okx) { Wait-Key; return }
    Write-Host '  [OK] files restored' -ForegroundColor Green

    $link = Join-Path $target 'public\storage'
    if (Test-Path -LiteralPath $link) { cmd /c "rmdir `"$link`" 2>nul" | Out-Null; if (Test-Path -LiteralPath $link) { Remove-Dir $link } }
    if (Test-Path -LiteralPath (Join-Path $target 'artisan')) {
        $a = Invoke-Native (Get-PhpExe) @('artisan', 'storage:link') $target
        if ($a.Ok) { Write-Host '  [OK] storage:link created' -ForegroundColor Green }
        else { Write-Host ('  [WARN] storage:link failed: ' + (Get-FirstLine $a.Out)) -ForegroundColor Yellow }
    }

    $np = New-Project (Split-Path $target -Leaf)
    $db = $null
    if (Test-Path -LiteralPath $np.EnvPath) { $db = Get-ProjectDb $np }
    if ($db -and $db.Name -and ($db.Conn -ne 'sqlite')) {
        $dumps = @(Get-BackupFiles | Where-Object { ($_.Kind -eq 'sql') -and ($_.Key -ieq $db.Name) } | Sort-Object When -Descending)
        if ($dumps.Count -gt 0) {
            Write-Host ''
            Write-Host ("  newest database dump for '$($db.Name)': " + $dumps[0].File.Name) -ForegroundColor White
            if (Read-Confirm 'Import it into MySQL now? (replaces the current data of that database)') {
                $imp = Invoke-DbImport $db $dumps[0].File.FullName
                if ($imp.ok) { Write-Host '  [OK] database restored' -ForegroundColor Green }
                else { Write-Host "  [ERROR] $($imp.msg)" -ForegroundColor Red }
            }
        }
    }
    Write-Log "restored $name -> $target"
    Write-Host ''
    Write-Host '  Restore completed.' -ForegroundColor Green
    Wait-Key
}

function Invoke-CleanupBackups {
    $all = @(Get-BackupFiles)
    if ($all.Count -eq 0) { Clear-Host; Show-Fail ('No backups in ' + (Get-BackupDir)); return }
    $keep = @(); $del = @()
    $groups = $all | Group-Object { $_.Kind + '|' + $_.Key.ToLower() + '|' + $_.Day }
    foreach ($g in $groups) {
        $sorted = @($g.Group | Sort-Object When -Descending)
        $keep += $sorted[0]
        if ($sorted.Count -gt 1) { $del += $sorted[1..($sorted.Count - 1)] }
    }
    if ($del.Count -eq 0) { Clear-Host; Show-Ok 'Nothing to clean - one backup per day already'; return }
    $lines = New-Object System.Collections.ArrayList
    Add-Line $lines ("DELETE  ($($del.Count) files, " + (Format-Size (($del | ForEach-Object { $_.File.Length } | Measure-Object -Sum).Sum)) + ')') 'Red'
    foreach ($d in ($del | Sort-Object When)) { Add-Line $lines ('  ' + $d.File.Name) 'Red' }
    Add-Line $lines ''
    Add-Line $lines "KEEP  ($($keep.Count) files)" 'Green'
    foreach ($k in ($keep | Sort-Object When)) { Add-Line $lines ('  ' + $k.File.Name) 'Green' }
    Show-Pager 'Clean up backups - preview (nothing deleted yet)' $lines
    if (-not (Confirm-Action ("Delete the $($del.Count) older backups listed in red?"))) { return }
    $n = 0; $bad = 0
    foreach ($d in $del) {
        try { Remove-Item -LiteralPath $d.File.FullName -Force -ErrorAction Stop; $n++ } catch { $bad++ }
    }
    Clear-Host
    Show-Ok "Deleted $n file(s), $bad failed"
}

function Show-BackupScreen {
    $dir = Get-BackupDir
    $dirOk = Test-Path -LiteralPath $dir
    $dirNote = $dir; if (-not $dirOk) { $dirNote = "$dir   (does not exist yet - created on first backup)" }
    $all = @(Get-BackupFiles)
    $summary = "$($all.Count) backup file(s)"
    $items = @(
        @{ label = 'Backup a project';              note = 'files + database';  color = 'Green' },
        @{ label = 'Backup a project - files only'; note = '';                  color = 'DarkGray' },
        @{ label = 'Backup a project - database only'; note = '';               color = 'DarkGray' },
        @{ label = 'Backup any folder';             note = 'browse';            color = 'DarkGray' },
        @{ label = 'Restore a backup';              note = 'files + optional database'; color = 'Cyan' },
        @{ label = 'Clean up old backups';          note = 'keep the newest of each day'; color = 'DarkGray' },
        @{ label = 'Open the backup folder';        note = $summary;            color = 'DarkGray'; enabled = $dirOk }
    )
    return @{ Items = $items; Subtitle = $dirNote }
}

function Invoke-BackupAction([int]$Index) {
    if     ($Index -eq 0) { Invoke-BackupProject 'both' }
    elseif ($Index -eq 1) { Invoke-BackupProject 'files' }
    elseif ($Index -eq 2) { Invoke-BackupProject 'db' }
    elseif ($Index -eq 3) { Invoke-BackupFolder }
    elseif ($Index -eq 4) { Invoke-RestoreBackup }
    elseif ($Index -eq 5) { Invoke-CleanupBackups }
    elseif ($Index -eq 6) { Invoke-Item -LiteralPath (Get-BackupDir) }
}
