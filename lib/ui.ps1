try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Get-WinSize {
    $w = 120; $h = 40
    try { $w = [Console]::WindowWidth; $h = [Console]::WindowHeight } catch { }
    return @{ W = $w; H = $h }
}

function Write-Row {
    param([string]$Text, [string]$Fg = 'Gray', [string]$Bg = '')
    $w = (Get-WinSize).W - 1
    if ($w -lt 1) { $w = 1 }
    if ($Text.Length -gt $w) { $Text = $Text.Substring(0, $w) }
    $Text = $Text.PadRight($w)
    if ($Bg) { Write-Host $Text -ForegroundColor $Fg -BackgroundColor $Bg }
    else     { Write-Host $Text -ForegroundColor $Fg }
}

function Write-Cols {
    param([string]$A, [string]$FgA = 'Gray', [string]$B = '', [string]$FgB = 'DarkGray', [string]$Bg = '')
    $w = (Get-WinSize).W - 1
    if ($w -lt 1) { $w = 1 }
    if ($A.Length -gt $w) { $A = $A.Substring(0, $w) }
    $room = $w - $A.Length
    if ($B.Length -gt $room) {
        if ($room -gt 3) { $B = $B.Substring(0, $room - 3) + '...' } else { $B = '' }
    }
    $pad = [Math]::Max(0, $w - $A.Length - $B.Length)
    if ($Bg) {
        Write-Host $A -NoNewline -ForegroundColor $FgA -BackgroundColor $Bg
        if ($B) { Write-Host $B -NoNewline -ForegroundColor $FgB -BackgroundColor $Bg }
        Write-Host (' ' * $pad) -ForegroundColor $FgA -BackgroundColor $Bg
    }
    else {
        Write-Host $A -NoNewline -ForegroundColor $FgA
        if ($B) { Write-Host $B -NoNewline -ForegroundColor $FgB }
        Write-Host (' ' * $pad)
    }
}

function Exit-Tool {
    $go = $true
    if (Get-Command Confirm-Exit -ErrorAction SilentlyContinue) { $go = [bool](Confirm-Exit) }
    if (-not $go) { try { Clear-Host } catch { }; return $false }
    try { Clear-Host } catch { }
    try { [Console]::CursorVisible = $true } catch { }
    exit 0
}

function Read-KeyWait($OnTick = $null) {
    if (-not $OnTick) { $OnTick = $script:GlobalTick }
    $w = 0; $h = 0
    try { $w = [Console]::WindowWidth; $h = [Console]::WindowHeight } catch { }
    $last = Get-Date
    while ($true) {
        if ([Console]::KeyAvailable) { return [Console]::ReadKey($true) }
        Start-Sleep -Milliseconds 100
        if ($OnTick -and (((Get-Date) - $last).TotalSeconds -ge $script:TickSeconds)) {
            $last = Get-Date
            try { & $OnTick } catch { }
        }
        $w2 = $w; $h2 = $h
        try { $w2 = [Console]::WindowWidth; $h2 = [Console]::WindowHeight } catch { }
        if (($w2 -ne $w) -or ($h2 -ne $h)) { try { Clear-Host } catch { }; return $null }
    }
}

function Wait-Key {
    Write-Host ''
    Write-Host '  Press any key...' -ForegroundColor DarkGray
    try { [void][Console]::ReadKey($true) } catch { }
}
function Pause-Key([string]$Msg = '  Press any key to continue...') {
    Write-Host ''
    Write-Host $Msg -ForegroundColor DarkGray
    try { [void][Console]::ReadKey($true) } catch { }
}

function Step-MenuSel($Rows, [int]$From, [int]$Dir) {
    $n = $Rows.Count
    for ($i = 1; $i -le $n; $i++) {
        $j = ((($From + $Dir * $i) % $n) + $n) % $n
        if ($Rows[$j].Enabled) { return $j }
    }
    return $From
}

function Show-Menu {
    param(
        [string]$Title,
        $Items,
        [string]$Subtitle = '',
        [string[]]$Panel = @(),
        [int]$Start = 0,
        [string]$Hint = '',
        [string]$Flash = '',
        [string]$FlashColor = 'Green',
        [switch]$Nav,
        [bool]$CanBack = $false,
        [bool]$CanFwd = $false,
        [bool]$CanUp = $false,
        $OnTick = $null,
        [int[]]$Danger = @()
    )

    $list = New-Object System.Collections.ArrayList
    $n = 0
    foreach ($it in @($Items)) {
        $r = [pscustomobject]@{ Label = ''; Note = ''; Color = 'DarkGray'; Enabled = $true; Danger = $false }
        if (($it -is [hashtable]) -or ($it -is [System.Collections.Specialized.OrderedDictionary])) {
            if ($it.Contains('label'))   { $r.Label   = [string]$it['label'] }
            if ($it.Contains('note'))    { $r.Note    = [string]$it['note'] }
            if ($it.Contains('color') -and $it['color']) { $r.Color = [string]$it['color'] }
            if ($it.Contains('enabled')) { $r.Enabled = [bool]$it['enabled'] }
            if ($it.Contains('danger'))  { $r.Danger  = [bool]$it['danger'] }
        }
        else { $r.Label = [string]$it }
        if ($Danger -contains $n) { $r.Danger = $true }
        [void]$list.Add($r)
        $n++
    }
    $rows = $list.ToArray()
    $count = $rows.Count
    if ($count -eq 0) { return -1 }

    if (-not $Hint) {
        if ($Nav) {
            if ($CanUp) { $Hint = 'Up/Down    Enter    Left/Right: history    Backspace: up    Esc: exit' }
            else        { $Hint = 'Up/Down    Enter    Left/Right: history    Esc: exit' }
        }
        else { $Hint = 'Up/Down    Enter    Backspace/Left: back    Esc: exit' }
    }

    $lw = 0
    foreach ($r in $rows) { if ($r.Label.Length -gt $lw) { $lw = $r.Label.Length } }

    $sel = [Math]::Min([Math]::Max($Start, 0), $count - 1)
    if (-not $rows[$sel].Enabled) { $sel = Step-MenuSel $rows $sel 1 }
    $top = 0
    $prevLines = 0
    $subLines = 0
    if ($Subtitle) { $subLines = 1 }

    try { [Console]::CursorVisible = $false } catch { }
    Clear-Host
    try {
        while ($true) {
            $ws = Get-WinSize
            $visible = [Math]::Max(3, $ws.H - 9 - $subLines - $Panel.Count)
            if ($visible -gt $count) { $visible = $count }
            if ($sel -lt $top) { $top = $sel }
            if ($sel -ge ($top + $visible)) { $top = $sel - $visible + 1 }
            if ($top -lt 0) { $top = 0 }
            $shown = [Math]::Min($visible, $count - $top)
            $lines = 0

            try { [Console]::SetCursorPosition(0, 0) } catch { Clear-Host }
            Write-Row ''
            Write-Row ('  ' + $Title) 'Cyan'
            if ($Subtitle) { Write-Row ('  ' + $Subtitle) 'DarkGray'; $lines++ }
            Write-Row ('  ' + ('-' * [Math]::Min(60, [Math]::Max(10, $ws.W - 4)))) 'DarkGray'
            foreach ($pl in $Panel) { Write-Row ('  ' + $pl) 'DarkCyan'; $lines++ }
            if ($Flash) { Write-Row ('  ' + $Flash) $FlashColor } else { Write-Row '' }
            if ($top -gt 0) { Write-Row ('    ... ' + $top + ' more above') 'DarkGray' } else { Write-Row '' }
            $lines += 5

            for ($k = 0; $k -lt $shown; $k++) {
                $idx = $top + $k
                $r = $rows[$idx]
                $isSel = ($idx -eq $sel)
                $prefix = '    '
                if ($isSel) { $prefix = '  > ' }
                $a = $prefix + $r.Label.PadRight($lw)
                $b = ''
                if ($r.Note) { $b = '   ' + $r.Note }
                if ($isSel) {
                    if ($r.Danger) { Write-Cols $a 'White' $b 'White' 'DarkRed' }
                    else           { Write-Cols $a 'Black' $b 'Black' 'Cyan' }
                }
                else {
                    $fa = 'Gray'
                    if (-not $r.Enabled) { $fa = 'DarkGray' }
                    elseif ($r.Danger)   { $fa = 'Red' }
                    $fb = $r.Color
                    if (-not $fb) { $fb = 'DarkGray' }
                    Write-Cols $a $fa $b $fb
                }
            }
            $lines += $shown

            $below = $count - $top - $shown
            if ($below -gt 0) { Write-Row ('    ... ' + $below + ' more below') 'DarkGray' } else { Write-Row '' }
            Write-Row ''
            Write-Row ('  ' + $Hint) 'DarkGray'
            $lines += 3
            for ($x = $lines; $x -lt $prevLines; $x++) { Write-Row '' }
            $prevLines = $lines

            $k = Read-KeyWait $OnTick
            if ($null -eq $k) { $prevLines = 0; continue }

            if     ($k.Key -eq 'UpArrow')   { $sel = Step-MenuSel $rows $sel -1 }
            elseif ($k.Key -eq 'DownArrow') { $sel = Step-MenuSel $rows $sel 1 }
            elseif ($k.Key -eq 'PageUp') {
                $sel = [Math]::Max(0, $sel - $visible)
                if (-not $rows[$sel].Enabled) { $sel = Step-MenuSel $rows $sel 1 }
            }
            elseif ($k.Key -eq 'PageDown') {
                $sel = [Math]::Min($count - 1, $sel + $visible)
                if (-not $rows[$sel].Enabled) { $sel = Step-MenuSel $rows $sel -1 }
            }
            elseif ($k.Key -eq 'Home') { $sel = 0; if (-not $rows[$sel].Enabled) { $sel = Step-MenuSel $rows $sel 1 } }
            elseif ($k.Key -eq 'End')  { $sel = $count - 1; if (-not $rows[$sel].Enabled) { $sel = Step-MenuSel $rows $sel -1 } }
            elseif ($k.Key -eq 'Enter') { if ($rows[$sel].Enabled) { return $sel } }
            elseif ($k.Key -eq 'Backspace') {
                if ($Nav) { if ($CanUp) { return -1 } } else { return -1 }
            }
            elseif ($k.Key -eq 'LeftArrow') {
                if ($Nav) { if ($CanBack) { return -2 } } else { return -1 }
            }
            elseif ($k.Key -eq 'RightArrow') {
                if ($Nav -and $CanFwd) { return -3 }
            }
            elseif ($k.Key -eq 'Escape') {
                if (-not (Exit-Tool)) { $prevLines = 0 }
            }
        }
    }
    finally {
        try { [Console]::CursorVisible = $true } catch { }
    }
}

function Show-Choice {
    param(
        [string]$Title, [string]$Subtitle = '', $Items, [string]$Hint = '', $OnTick = $null,
        [string]$Flash = '', [string]$FlashColor = 'Green', [int]$InitialIndex = -1, [string[]]$Panel = @()
    )
    $start = 0
    if ($InitialIndex -ge 0) { $start = $InitialIndex }
    $i = Show-Menu -Title $Title -Items $Items -Subtitle $Subtitle -Panel $Panel -Start $start -Hint $Hint -Flash $Flash -FlashColor $FlashColor -OnTick $OnTick
    if ($i -lt 0) { return $null }
    return $i
}

function Get-LineColor([string]$l) {
    if ($l.StartsWith('diff ') -or $l.StartsWith('commit ')) { return 'Yellow' }
    if ($l.StartsWith('+++') -or $l.StartsWith('---') -or $l.StartsWith('index ')) { return 'DarkGray' }
    if ($l.StartsWith('@@')) { return 'Cyan' }
    if ($l.StartsWith('+') -or $l.StartsWith('>')) { return 'Green' }
    if ($l.StartsWith('-') -or $l.StartsWith('<')) { return 'Red' }
    if ($l.StartsWith('$ ') -or $l.StartsWith('==')) { return 'Cyan' }
    return 'Gray'
}

function Show-Pager {
    param([string]$Title, $Lines, [string]$Hint = '')
    if (-not $Hint) { $Hint = 'Up/Down  PgUp/PgDn  Home/End    Backspace/Left: back    Esc: exit' }
    $all = New-Object System.Collections.ArrayList
    foreach ($row in @($Lines)) {
        if ($row -is [string]) { [void]$all.Add(@{ t = $row.Replace("`t", '    ').TrimEnd(); c = (Get-LineColor $row) }) }
        elseif ($null -ne $row) {
            $c = 'Gray'
            if ($row.c) { $c = [string]$row.c }
            [void]$all.Add(@{ t = ([string]$row.t).Replace("`t", '    ').TrimEnd(); c = $c })
        }
    }
    if ($all.Count -eq 0) { [void]$all.Add(@{ t = '(nothing to show)'; c = 'DarkGray' }) }
    $count = $all.Count
    $top = 0
    $prevLines = 0
    try { [Console]::CursorVisible = $false } catch { }
    Clear-Host
    try {
        while ($true) {
            $ws = Get-WinSize
            $visible = [Math]::Max(3, $ws.H - 6)
            $maxTop = [Math]::Max(0, $count - $visible)
            if ($top -gt $maxTop) { $top = $maxTop }
            if ($top -lt 0) { $top = 0 }

            try { [Console]::SetCursorPosition(0, 0) } catch { Clear-Host }
            Write-Row ''
            Write-Row ('  ' + $Title) 'Cyan'
            Write-Row ('  ' + ('-' * [Math]::Min(60, [Math]::Max(10, $ws.W - 4)))) 'DarkGray'
            for ($k = 0; $k -lt $visible; $k++) {
                $idx = $top + $k
                if ($idx -lt $count) { Write-Row ('  ' + $all[$idx].t) $all[$idx].c } else { Write-Row '' }
            }
            Write-Row ''
            $last = [Math]::Min($count, $top + $visible)
            Write-Row ('  ' + ($top + 1) + '-' + $last + ' of ' + $count + '    ' + $Hint) 'DarkGray'

            $k = Read-KeyWait
            if ($null -eq $k) { continue }
            if     ($k.Key -eq 'UpArrow')   { $top-- }
            elseif ($k.Key -eq 'DownArrow') { $top++ }
            elseif ($k.Key -eq 'PageUp')    { $top -= $visible }
            elseif ($k.Key -eq 'PageDown')  { $top += $visible }
            elseif ($k.Key -eq 'Home')      { $top = 0 }
            elseif ($k.Key -eq 'End')       { $top = $maxTop }
            elseif (($k.Key -eq 'Backspace') -or ($k.Key -eq 'LeftArrow') -or ($k.Key -eq 'Q')) { return }
            elseif ($k.Key -eq 'Escape')    { [void](Exit-Tool) }
        }
    }
    finally {
        try { [Console]::CursorVisible = $true } catch { }
        Clear-Host
    }
}

function Write-Header([string]$Text) {
    Clear-Host
    Write-Host ''
    Write-Host ('  ' + $Text) -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 60)) -ForegroundColor DarkGray
    Write-Host ''
}

function Show-Busy([string]$Text) {
    try { [Console]::CursorVisible = $false } catch { }
    Clear-Host
    Write-Host ''
    Write-Host ('  >>  ' + $Text + ' ...') -ForegroundColor Cyan
    Write-Host ''
    Write-Host '      Please wait - the tool is working, it is NOT frozen.' -ForegroundColor DarkGray
    Write-Host '      You come back to the menu by itself when it is done.' -ForegroundColor DarkGray
}

function Show-Ok([string]$Text) {
    Write-Host ('  ' + $Text) -ForegroundColor Green
    Start-Sleep -Milliseconds 700
}

function Show-Fail([string]$Text) {
    Write-Host ('  ' + $Text) -ForegroundColor Red
    Wait-Key
}

function Confirm-Action([string]$Message) {
    $i = Show-Menu -Title $Message -Items @('No, cancel', 'Yes, do it') -Start 0 -Hint 'Up/Down: move    Enter: select    Backspace/Left: cancel    Esc: exit'
    return ($i -eq 1)
}

function Read-EnterOrEsc([string]$Msg) {
    Write-Host $Msg -ForegroundColor Yellow
    try { $k = [Console]::ReadKey($true); return ($k.Key -eq 'Enter') } catch { return $false }
}

function Read-Confirm([string]$Msg) {
    Write-Host ''
    return (Read-EnterOrEsc "  $Msg  [ENTER = yes, any other key = no]")
}

function Read-LineEsc([string]$Prompt, [string]$Default = '') {
    Write-Host $Prompt -NoNewline -ForegroundColor Cyan
    $sb = New-Object System.Text.StringBuilder
    if ($Default) { [void]$sb.Append($Default); Write-Host $Default -NoNewline }
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Enter')  { Write-Host ''; return $sb.ToString() }
        if ($k.Key -eq 'Escape') { Write-Host ''; return $null }
        if ($k.Key -eq 'Backspace') {
            if ($sb.Length -gt 0) { [void]$sb.Remove($sb.Length - 1, 1); Write-Host "`b `b" -NoNewline }
            continue
        }
        if ($k.KeyChar -and -not [char]::IsControl($k.KeyChar)) { [void]$sb.Append($k.KeyChar); Write-Host $k.KeyChar -NoNewline }
    }
}

function Read-TypedConfirm([string]$Word) {
    $in = Read-LineEsc "  type '$Word' to confirm> "
    return (($null -ne $in) -and ($in.Trim() -ceq $Word))
}

function Read-Input([string]$Title, [string]$Label, [string[]]$Help = @(), [string]$Default = '') {
    Clear-Host
    Write-Host ''
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host ''
    foreach ($h in $Help) { Write-Host "  $h" -ForegroundColor DarkGray }
    if ($Help.Count -gt 0) { Write-Host '' }
    Write-Host '  (ESC = cancel)' -ForegroundColor DarkGray
    $v = Read-LineEsc "  $Label> " $Default
    if ($null -eq $v) { return $null }
    return $v.Trim()
}

function ConvertTo-PathList([string]$Text) {
    $res = @()
    if (-not $Text) { return $res }
    foreach ($p in ($Text -split ';')) {
        $t = $p.Trim().Trim('"').Trim("'").Trim()
        if ($t) { $res += $t }
    }
    return $res
}

function New-DialogOwner {
    Add-Type -AssemblyName System.Windows.Forms
    $o = New-Object System.Windows.Forms.Form
    $o.TopMost = $true
    $o.ShowInTaskbar = $false
    $o.Opacity = 0
    $o.Show()
    [void]$o.Activate()
    return $o
}

function Select-FolderDialog([string]$Title = 'Select a folder', [string]$Initial = '') {
    $owner = New-DialogOwner
    try {
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = $Title
        if ($Initial -and (Test-Path -LiteralPath $Initial)) { $d.SelectedPath = $Initial }
        if ($d.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { return $d.SelectedPath }
        return $null
    }
    finally { $owner.Close() }
}

function Select-FilesDialog([string]$Title = 'Select files', [string]$Filter = 'All files (*.*)|*.*', [string]$Initial = '', [bool]$Multi = $true) {
    $owner = New-DialogOwner
    try {
        $d = New-Object System.Windows.Forms.OpenFileDialog
        $d.Title = $Title
        $d.Filter = $Filter
        $d.Multiselect = $Multi
        $d.RestoreDirectory = $true
        if ($Initial -and (Test-Path -LiteralPath $Initial)) { $d.InitialDirectory = $Initial }
        $files = @()
        if ($d.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { $files = @($d.FileNames) }
        return $files
    }
    finally { $owner.Close() }
}

function Select-FolderMenu {
    param([string]$Title = 'Pick a folder', [string]$StartDir = '', [string]$Initial = '')
    $items = @()
    if ($StartDir) { $items += ('This folder  (' + $StartDir + ')') }
    $items += 'Browse...'
    $items += 'Type path'
    $i = Show-Menu -Title $Title -Items $items
    if ($i -lt 0) { return $null }
    $off = 0
    if ($StartDir) { $off = 1; if ($i -eq 0) { return $StartDir } }
    if ($i -eq $off) {
        $init = $Initial
        if (-not $init) { $init = $StartDir }
        return (Select-FolderDialog $Title $init)
    }
    $p = Read-Input $Title 'folder path' @('Paste or type the full path') ''
    if ($p) {
        $p = $p.Trim('"')
        if (Test-Path -LiteralPath $p -PathType Container) { return (Resolve-Path -LiteralPath $p).Path }
        Show-Fail "Not a folder: $p"
    }
    return $null
}
