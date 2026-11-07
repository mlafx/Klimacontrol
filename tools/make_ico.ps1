# Erzeugt windows\KlimacontrolTray\Klimacontrol.ico aus tools\AppIcon.icns (dasselbe Symbol wie am Mac).
# Aufruf im Projektordner:  powershell -ExecutionPolicy Bypass -File tools\make_ico.ps1
# Das .icns enthaelt PNG-Bilder; fehlende Windows-Groessen (20, 24, 40, 48) werden mit System.Drawing verkleinert.
# Die ICO-Datei enthaelt PNG-Eintraege (ab Windows Vista ueberall lesbar).
# Nur ASCII: Windows PowerShell 5.1 liest die Datei als ANSI.
$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)
Add-Type -AssemblyName System.Drawing

$bytes = [IO.File]::ReadAllBytes((Resolve-Path "tools\AppIcon.icns"))
function BE32([byte[]]$b, [int]$o) { ([int]$b[$o] -shl 24) -bor ([int]$b[$o+1] -shl 16) -bor ([int]$b[$o+2] -shl 8) -bor [int]$b[$o+3] }
if ([Text.Encoding]::ASCII.GetString($bytes, 0, 4) -ne "icns") { Write-Host "Abbruch: keine icns-Datei"; exit 1 }

# Groesstes PNG je Kantenlaenge sammeln.
$images = @{}
$pos = 8
while ($pos + 8 -le $bytes.Length) {
    $len = BE32 $bytes ($pos + 4)
    if ($len -lt 8) { break }
    $data = New-Object byte[] ($len - 8)
    [Array]::Copy($bytes, $pos + 8, $data, 0, $len - 8)
    if ($data.Length -gt 8 -and $data[0] -eq 0x89 -and $data[1] -eq 0x50) {
        $ms = New-Object IO.MemoryStream(, $data)
        $img = [Drawing.Image]::FromStream($ms)
        $images[$img.Width] = $img
    }
    $pos += $len
}
if (-not $images.ContainsKey(256)) { Write-Host "Abbruch: kein 256er Bild im icns"; exit 1 }

function Png-Of($size) {
    $src = $images.Keys | Where-Object { $_ -ge $size } | Sort-Object | Select-Object -First 1
    $bmp = New-Object Drawing.Bitmap $size, $size
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($images[$src], 0, 0, $size, $size)
    $g.Dispose()
    $ms = New-Object IO.MemoryStream
    $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    , $ms.ToArray()
}

$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$pngs = foreach ($s in $sizes) { , (Png-Of $s) }
$out = New-Object IO.MemoryStream
$w = New-Object IO.BinaryWriter($out)
$w.Write([UInt16]0); $w.Write([UInt16]1); $w.Write([UInt16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $d = $pngs[$i]
    $w.Write([byte]($s % 256)); $w.Write([byte]($s % 256)); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([UInt16]1); $w.Write([UInt16]32); $w.Write([UInt32]$d.Length); $w.Write([UInt32]$offset)
    $offset += $d.Length
}
foreach ($d in $pngs) { $w.Write($d) }
$w.Flush()
$target = "windows\KlimacontrolTray\Klimacontrol.ico"
[IO.File]::WriteAllBytes((Join-Path (Get-Location) $target), $out.ToArray())
Write-Host "Geschrieben: $target ($([int]($out.Length / 1KB)) KB, Groessen $($sizes -join ', '))"
