$script:ZipMaxFolderMB   = 30
$script:ZipExcludePaths  = @('storage', 'public/storage', 'vendor')
$script:ZipExcludeNames  = @('node_modules', '.git')
$script:ImageExt         = @('.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.tif', '.tiff', '.ico', '.svg', '.avif', '.heic')
$script:ArchiveExt       = @('.zip', '.rar', '.7z', '.tar', '.gz', '.tgz', '.bz2', '.xz')
$script:KeepImagePattern = 'logo|favicon'
$script:PatchKnownDirs   = @('app', 'bootstrap', 'config', 'database', 'public', 'resources', 'routes', 'storage', 'tests', 'lang', 'docs')

function Get-ZipPlan([IO.DirectoryInfo]$Dir, [string]$Rel, $Ctx) {
    $files = New-Object 'System.Collections.Generic.List[object]'
    $size = [long]0
    $inPublic = ($Rel -eq 'public') -or $Rel.StartsWith('public/')
    foreach ($e in $Dir.GetFileSystemInfos()) {
        if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { $Ctx.Links++; continue }
        if ($Rel) { $r = "$Rel/$($e.Name)" } else { $r = $e.Name }
        if ($e -is [IO.DirectoryInfo]) {
            if (($script:ZipExcludePaths -contains $r) -or ($script:ZipExcludeNames -contains $e.Name)) { $Ctx.Fixed.Add($r); continue }
            $sub = Get-ZipPlan $e $r $Ctx
            if ($sub.Size -gt $Ctx.Limit) { $Ctx.BigDirs.Add(('{0}  ({1})' -f $r, (Format-Size $sub.Size))); continue }
            if ($sub.Files.Count -gt 0) { $files.AddRange($sub.Files); $size += $sub.Size }
        } else {
            $ext = $e.Extension.ToLower()
            if ($script:ArchiveExt -contains $ext) { $Ctx.Archives++; continue }
            if ($inPublic -and ($script:ImageExt -contains $ext)) {
                $bn = [IO.Path]::GetFileNameWithoutExtension($e.Name)
                if ($bn -notmatch $script:KeepImagePattern) { $Ctx.Images++; continue }
            }
            $files.Add(@{ Full = $e.FullName; Entry = $r })
            $size += $e.Length
        }
    }
    return [pscustomobject]@{ Files = $files; Size = $size }
}

function Write-ZipFromPlan($Files, [string]$Out) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fs = $null; $za = $null; $n = 0; $failed = @()
    try {
        $fs = [IO.File]::Open($Out, [IO.FileMode]::Create)
        $za = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
        foreach ($f in $Files) {
            try {
                $in = [IO.File]::Open($f.Full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                try {
                    $en = $za.CreateEntry($f.Entry, [IO.Compression.CompressionLevel]::Optimal)
                    $es = $en.Open()
                    try { $in.CopyTo($es) } finally { $es.Dispose() }
                } finally { $in.Dispose() }
                $n++
            } catch { $failed += $f.Entry }
        }
    } catch {
        return @{ ok = $false; n = $n; failed = $failed; msg = "$_" }
    } finally {
        if ($za) { $za.Dispose() }
        if ($fs) { $fs.Dispose() }
    }
    return @{ ok = $true; n = $n; failed = $failed; msg = '' }
}

$script:ZipResult = ''
function Invoke-ZipProject($p) {
    $script:ZipResult = '! zip did not finish'
    Clear-Host
    Write-Host ''
    Write-Host " Zip project - $($p.Name)" -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $p.Path -PathType Container)) { Write-Host " [ERROR] folder not found: $($p.Path)" -ForegroundColor Red; $script:ZipResult = "! folder not found: $($p.Path)"; return 1 }

    $ctx = @{
        Limit    = [long]$script:ZipMaxFolderMB * 1MB
        BigDirs  = (New-Object 'System.Collections.Generic.List[string]')
        Fixed    = (New-Object 'System.Collections.Generic.List[string]')
        Images   = 0; Archives = 0; Links = 0
    }
    Write-Host ' Scanning project ...' -ForegroundColor DarkGray
    $plan = Get-ZipPlan (New-Object IO.DirectoryInfo($p.Path)) '' $ctx
    if ($plan.Files.Count -eq 0) { Write-Host ' [ERROR] nothing to zip' -ForegroundColor Red; $script:ZipResult = '! nothing to zip'; return 1 }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $out   = Join-Path (Get-Desktop) ('{0}_{1}.zip' -f $p.Name, $stamp)
    Write-Host " Compressing $($plan.Files.Count) files ($(Format-Size $plan.Size) before compression) ..." -ForegroundColor DarkGray
    $r = Write-ZipFromPlan $plan.Files $out
    if (-not $r.ok) { Write-Host " [ERROR] zip failed: $($r.msg)" -ForegroundColor Red; $script:ZipResult = "! zip failed: $($r.msg)"; return 1 }

    $zsize = (Get-Item -LiteralPath $out).Length
    Write-Host ''
    Write-Host " [OK] $out" -ForegroundColor Green
    Write-Host ("      {0} files, {1}" -f $r.n, (Format-Size $zsize)) -ForegroundColor Green
    Write-Host ''
    Write-Host ' Excluded:' -ForegroundColor DarkGray
    if ($ctx.Fixed.Count -gt 0) { Write-Host ('   folders (rules) : ' + (($ctx.Fixed | Sort-Object -Unique) -join ', ')) -ForegroundColor DarkGray }
    Write-Host "   public images   : $($ctx.Images) (logo / favicon kept)" -ForegroundColor DarkGray
    Write-Host "   archives        : $($ctx.Archives)" -ForegroundColor DarkGray
    if ($ctx.Links -gt 0) { Write-Host "   symlinks        : $($ctx.Links)" -ForegroundColor DarkGray }
    if ($ctx.BigDirs.Count -gt 0) {
        Write-Host "   folders > $script:ZipMaxFolderMB MB :" -ForegroundColor Yellow
        foreach ($b in $ctx.BigDirs) { Write-Host "     - $b" -ForegroundColor Yellow }
    }
    if ($r.failed.Count -gt 0) {
        Write-Host "   unreadable files: $($r.failed.Count)" -ForegroundColor Red
        foreach ($f in ($r.failed | Select-Object -First 10)) { Write-Host "     - $f" -ForegroundColor Red }
    }
    Write-Log "zipped project -> $out ($($r.n) files)" $p
    $script:ZipResult = "zip saved on the Desktop: $(Split-Path $out -Leaf)  ($($r.n) files, $(Format-Size $zsize))"
    if ($r.failed.Count -gt 0) { $script:ZipResult = '! ' + $script:ZipResult + " - $($r.failed.Count) unreadable file(s) skipped" }
    return 0
}

function Sort-PatchItems($Items, [string]$KeyName) {
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($i in $Items) { $list.Add($i) }
    if ($KeyName -eq 'NumKey')     { $list.Sort([Comparison[object]]{ param($a, $b) [string]::CompareOrdinal($a.NumKey, $b.NumKey) }) }
    elseif ($KeyName -eq 'LetKey') { $list.Sort([Comparison[object]]{ param($a, $b) [string]::CompareOrdinal($a.LetKey, $b.LetKey) }) }
    else                           { $list.Sort([Comparison[object]]{ param($a, $b) [string]::CompareOrdinal($a.DateKey, $b.DateKey) }) }
    return @($list | ForEach-Object { $_.File })
}

function Get-PatchOrder($Zips) {
    $items = @()
    foreach ($z in $Zips) {
        $base = [IO.Path]::GetFileNameWithoutExtension($z.Name)
        $nums = @([regex]::Matches($base, '\d+') | ForEach-Object { $_.Value.PadLeft(20, '0') })
        $lets = @([regex]::Matches($base, '(?<![A-Za-z])[A-Za-z](?![A-Za-z])') | ForEach-Object { $_.Value.ToLower() })
        $nk = $null; if ($nums.Count -gt 0) { $nk = $nums -join '-' }
        $lk = $null; if ($lets.Count -gt 0) { $lk = $lets -join '-' }
        $items += [pscustomobject]@{ File = $z; NumKey = $nk; LetKey = $lk; DateKey = $z.LastWriteTimeUtc.Ticks.ToString().PadLeft(20, '0') }
    }
    $n = $items.Count
    $withNum = @($items | Where-Object { $null -ne $_.NumKey })
    if (($withNum.Count -eq $n) -and (@($items | Select-Object -ExpandProperty NumKey -Unique).Count -eq $n)) {
        return @{ Method = 'number'; Files = (Sort-PatchItems $items 'NumKey') }
    }
    $withLet = @($items | Where-Object { $null -ne $_.LetKey })
    if (($withLet.Count -eq $n) -and (@($items | Select-Object -ExpandProperty LetKey -Unique).Count -eq $n)) {
        return @{ Method = 'letter'; Files = (Sort-PatchItems $items 'LetKey') }
    }
    if (@($items | Select-Object -ExpandProperty DateKey -Unique).Count -eq $n) {
        return @{ Method = 'date'; Files = (Sort-PatchItems $items 'DateKey') }
    }
    return @{ Method = 'none'; Files = @($Zips) }
}

function Invoke-ApplyPatch($p, $Zip) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('dev-patch-' + [guid]::NewGuid().ToString('N'))
    Write-Host ''
    Write-Host " ==== $($Zip.Name) ====" -ForegroundColor Cyan
    try {
        Write-Host ' [1/4] Extracting ...'
        try { Expand-Archive -LiteralPath $Zip.FullName -DestinationPath $tmp -Force -ErrorAction Stop }
        catch { Write-Host " [ERROR] extraction failed: $_" -ForegroundColor Red; return 'failed' }

        $root = $tmp
        $top = @(Get-ChildItem -LiteralPath $root -Force)
        if (($top.Count -eq 1) -and $top[0].PSIsContainer -and ($script:PatchKnownDirs -notcontains $top[0].Name.ToLower())) {
            Write-Host "       (unwrapped folder '$($top[0].Name)')" -ForegroundColor DarkGray
            $root = $top[0].FullName
            $top = @(Get-ChildItem -LiteralPath $root -Force)
        }
        if ($top.Count -eq 0) { Write-Host ' [ERROR] patch is empty' -ForegroundColor Red; return 'failed' }

        Write-Host ' [2/4] Checking structure ...'
        $known = @($top | Where-Object { ($_.PSIsContainer -and ($script:PatchKnownDirs -contains $_.Name.ToLower())) -or ((-not $_.PSIsContainer) -and ($_.Extension -ieq '.md')) })
        if ($known.Count -eq 0) {
            Write-Host ''
            Write-Host ' [!] WARNING: this does not look like a standard Laravel patch.' -ForegroundColor Yellow
            Write-Host '     No folders like app / config / routes ... and no .md files at its root.' -ForegroundColor Yellow
            foreach ($t in ($top | Select-Object -First 15)) { Write-Host "       - $($t.Name)" -ForegroundColor Yellow }
            if (-not (Read-EnterOrEsc '     Press ENTER to apply anyway, any other key to skip this patch.')) {
                Write-Host ' Skipped.' -ForegroundColor DarkGray
                return 'skipped'
            }
        }

        Write-Host " [3/4] Copying into $($p.Path) (overwriting existing files) ..."
        $count = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force).Count
        & robocopy $root $p.Path /E /IS /IT /R:3 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { Write-Host " [ERROR] copy failed (robocopy code $LASTEXITCODE). Zip kept." -ForegroundColor Red; return 'failed' }

        Write-Host ' [4/4] Moving the zip to the Recycle Bin ...'
        try { Send-ToRecycleBin $Zip.FullName } catch { Write-Host " [WARN] could not recycle the zip: $_" -ForegroundColor Yellow }
        Write-Host " [OK] applied $count file(s) from $($Zip.Name)" -ForegroundColor Green
        Write-Log "patch applied: $($Zip.Name) ($count files)" $p
        return 'ok'
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-ApplyPatches($p) {
    $how = Show-Menu -Title "Apply patches - $($p.Name)" -Subtitle $p.Path -Items @(
        @{ label = 'Pick the patch zip(s)'; note = 'File Explorer window'; color = 'DarkGray' },
        @{ label = 'All patch*.zip on the Desktop'; note = 'automatic'; color = 'DarkGray' })
    if ($how -lt 0) { return 0 }

    $zips = @()
    if ($how -eq 0) {
        $paths = @(Select-FilesDialog 'Select the patch zip file(s) to apply' 'Zip files (*.zip)|*.zip|All files (*.*)|*.*' (Get-Desktop) $true)
        $zips = @($paths | ForEach-Object { Get-Item -LiteralPath $_ })
    } else {
        $zips = @(Get-ChildItem -LiteralPath (Get-Desktop) -Filter 'patch*.zip' -File -ErrorAction SilentlyContinue)
    }
    Clear-Host
    Write-Host ''
    Write-Host " Apply patches - $($p.Name)" -ForegroundColor Cyan
    Write-Host " -> $($p.Path)" -ForegroundColor DarkGray
    if ($zips.Count -eq 0) { Write-Host ' Nothing to apply.' -ForegroundColor Yellow; return 0 }

    $order = Get-PatchOrder $zips
    if ($order.Method -ne 'none') {
        $how2 = 'by file date (oldest first)'
        if ($order.Method -eq 'number') { $how2 = 'by the numbers in their names' }
        if ($order.Method -eq 'letter') { $how2 = 'by the letters in their names' }
        if ($zips.Count -eq 1) { $how2 = 'single patch' }
        Write-Host " $($zips.Count) patch(es), applied $how2 :" -ForegroundColor Green
        $i = 1
        foreach ($z in $order.Files) { Write-Host ('   {0}. {1}' -f $i, $z.Name); $i++ }
        foreach ($z in $order.Files) {
            $r = @(Invoke-ApplyPatch $p $z)[-1]
            if ($r -ne 'ok') { Write-Host ' Stopped - the remaining patches were NOT applied (order matters).' -ForegroundColor Yellow; return 1 }
        }
        Write-Host ''
        Write-Host ' All patches applied.' -ForegroundColor Green
        return 0
    }

    Write-Host ''
    Write-Host ' [!] Cannot decide the order: no usable numbers/letters in the names and identical dates.' -ForegroundColor Yellow
    if (-not (Read-EnterOrEsc ' Press ENTER to choose the order yourself, any other key to cancel.')) { return 0 }
    while ($true) {
        $zips = @($zips | Where-Object { Test-Path -LiteralPath $_.FullName } | Sort-Object Name)
        if ($zips.Count -eq 0) { Write-Host ' No more patches.' -ForegroundColor Green; return 0 }
        $items = @()
        foreach ($z in $zips) {
            $items += @{ label = $z.Name; enabled = $true; color = 'DarkGray'; note = ('{0:yyyy-MM-dd HH:mm}  {1}' -f $z.LastWriteTime, (Format-Size $z.Length)) }
        }
        $idx = Show-Menu -Title 'Patches - manual order' -Subtitle "$($zips.Count) selected - pick the one to apply next" -Items $items
        if ($idx -lt 0) { return 0 }
        Clear-Host
        [void](Invoke-ApplyPatch $p $zips[$idx])
        Pause-Key
    }
}
