@echo off
powershell -NoProfile -Command "$c='ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz','0123456789','!@#$%%^&*()'; $a=$c -join ''; $g=[Security.Cryptography.RandomNumberGenerator]::Create(); function Get-Rnd($n){$b=New-Object byte[] 4;$g.GetBytes($b);[BitConverter]::ToUInt32($b,0) %% $n}; $p=@(); foreach($s in $c){$p+=$s[(Get-Rnd $s.Length)]}; while($p.Count -lt 32){$p+=$a[(Get-Rnd $a.Length)]}; $p=($p | Sort-Object {Get-Rnd 1000000}) -join ''; Set-Clipboard $p;"
echo generated and copied
