$script:Hist = New-Object System.Collections.ArrayList
[void]$script:Hist.Add(@{ type = 'home'; name = $null })
$script:Pos = 0
$script:LastSel = @{}

function Get-LastSel([string]$Key) {
    if ($script:LastSel.ContainsKey($Key)) { return [int]$script:LastSel[$Key] }
    return 0
}
function Set-LastSel([string]$Key, [int]$Val) { $script:LastSel[$Key] = $Val }

function Get-CurrentLoc { return $script:Hist[$script:Pos] }

function Open-Loc($Loc) {
    $cur = $script:Hist[$script:Pos]
    if (($cur.type -eq $Loc.type) -and ($cur.name -eq $Loc.name)) { return }
    while ($script:Hist.Count -gt ($script:Pos + 1)) { $script:Hist.RemoveAt($script:Hist.Count - 1) }
    [void]$script:Hist.Add(@{ type = $Loc.type; name = $Loc.name })
    $script:Pos++
}

function Remove-HistLoc([string]$Type, [string]$Name) {
    for ($k = $script:Hist.Count - 1; $k -ge 0; $k--) {
        $e = $script:Hist[$k]
        if (($e.type -eq $Type) -and ($e.name -eq $Name)) {
            $script:Hist.RemoveAt($k)
            if (($k -le $script:Pos) -and ($script:Pos -gt 0)) { $script:Pos-- }
        }
    }
    if ($script:Pos -ge $script:Hist.Count) { $script:Pos = $script:Hist.Count - 1 }
    if ($script:Pos -lt 0) { $script:Pos = 0 }
}

function Get-NavArgs([bool]$CanUp) {
    return @{
        Nav     = $true
        CanBack = ($script:Pos -gt 0)
        CanFwd  = ($script:Pos -lt ($script:Hist.Count - 1))
        CanUp   = $CanUp
    }
}

function Invoke-NavKey([int]$i, $UpLoc) {
    if ($i -eq -2) { if ($script:Pos -gt 0) { $script:Pos-- }; return $true }
    if ($i -eq -3) { if ($script:Pos -lt ($script:Hist.Count - 1)) { $script:Pos++ }; return $true }
    if ($i -eq -1) { if ($UpLoc) { Open-Loc $UpLoc }; return $true }
    return $false
}
