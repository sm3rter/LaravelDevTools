Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:TrayMain = Join-Path $script:Root 'dev.ps1'

function Start-DevWindow([string]$Cmd, [string]$Project = '') {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:TrayMain + '"'), $Cmd)
    if ($Project) { $a += ('"' + $Project + '"') }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $a -WorkingDirectory $script:Root
}

function Get-TrayIpLabel {
    try {
        $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^(127|169)\.' } | Select-Object -First 1).IPAddress
        if ($ip) { return [string]$ip }
        return 'IP not found'
    } catch { return 'IP unavailable' }
}

function Get-TrayBackupLabel {
    try {
        $dir = Get-BackupDir
        if (-not (Test-Path -LiteralPath $dir)) { return 'No backup folder yet' }
        $latest = Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Extension -eq '.zip' -or $_.Extension -eq '.sql' } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) { return 'No backup found' }
        return ('Last backup: ' + (Format-Ago $latest.LastWriteTime))
    } catch { return 'Backup: unknown' }
}

function New-TrayIcon {
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(0x0E, 0x9F, 0xBC))
    $g.FillEllipse($brush, 0, 0, 15, 15)
    $font = New-Object System.Drawing.Font('Arial', 8, [System.Drawing.FontStyle]::Bold)
    $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString('D', $font, $white, (New-Object System.Drawing.RectangleF(0, 0, 15, 15)), $sf)
    $sf.Dispose(); $font.Dispose(); $white.Dispose(); $brush.Dispose(); $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

function Add-TrayItem($Menu, [string]$Text, [scriptblock]$OnClick) {
    $it = New-Object System.Windows.Forms.ToolStripMenuItem
    $it.Text = $Text
    $it.Add_Click($OnClick)
    [void]$Menu.Items.Add($it)
    return $it
}

function Add-TrayProjectMenu($Menu, [string]$Text, [string]$Cmd) {
    $sub = New-Object System.Windows.Forms.ToolStripMenuItem
    $sub.Text = $Text
    $www = Get-WwwDir
    $names = @()
    if (Test-Path -LiteralPath $www) { $names = @(Get-ChildItem -LiteralPath $www -Directory | Where-Object { -not $_.Name.StartsWith('.') } | Sort-Object Name | ForEach-Object { $_.Name }) }
    foreach ($n in $names) {
        $child = New-Object System.Windows.Forms.ToolStripMenuItem
        $child.Text = $n
        $c = $Cmd; $pn = $n
        $child.Add_Click({ Start-DevWindow $c $pn }.GetNewClosure())
        [void]$sub.DropDownItems.Add($child)
    }
    if ($names.Count -eq 0) { $e = New-Object System.Windows.Forms.ToolStripMenuItem; $e.Text = '(no projects)'; $e.Enabled = $false; [void]$sub.DropDownItems.Add($e) }
    [void]$Menu.Items.Add($sub)
}

function New-TrayMenu {
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $h = New-Object System.Windows.Forms.ToolStripMenuItem
    $h.Text = Get-TrayIpLabel
    $h.Enabled = $false
    $h.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    [void]$menu.Items.Add($h)
    $b = New-Object System.Windows.Forms.ToolStripMenuItem
    $b.Text = Get-TrayBackupLabel
    $b.Enabled = $false
    [void]$menu.Items.Add($b)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    [void](Add-TrayItem $menu 'Open Dev' { Start-DevWindow 'home' })
    Add-TrayProjectMenu $menu 'Start project' 'start'
    Add-TrayProjectMenu $menu 'Backup project' 'backup'
    Add-TrayProjectMenu $menu 'Zip project' 'zip'
    Add-TrayProjectMenu $menu 'Apply patches' 'patches'
    [void](Add-TrayItem $menu 'Restore a backup' { Start-DevWindow 'restore' })
    [void](Add-TrayItem $menu 'Clean up backups' { Start-DevWindow 'cleanup' })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void](Add-TrayItem $menu 'Sync offline work' { Start-DevWindow 'sync' })
    [void](Add-TrayItem $menu 'Stop everything' { Start-DevWindow 'stopall' })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void](Add-TrayItem $menu 'Exit' {
        $script:Tray.Visible = $false
        $script:Tray.Dispose()
        [System.Windows.Forms.Application]::Exit()
    })
    return $menu
}

$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = New-TrayIcon
$script:Tray.Text = 'Dev'
$script:Tray.Visible = $true
$script:Tray.ContextMenuStrip = New-TrayMenu
$script:Tray.Add_MouseClick({
    param($s, $e)
    $script:Tray.ContextMenuStrip = New-TrayMenu
})
$script:Tray.ShowBalloonTip(2000, 'Dev', 'Tray is running. Right-click the icon.', [System.Windows.Forms.ToolTipIcon]::Info)
[System.Windows.Forms.Application]::Run()
