#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Generate a grayscale ASCII-art version of shared/logo.png using ffmpeg.
    Writes the result to shared/logo_ascii.txt (UTF-8).
#>
param(
    [int]$Width    = 78,
    [int]$Height   = 21,
    [switch]$Invert,
    [int]$Contrast = 30,  # Percent - shadow/highlight push in ffmpeg eq filter
    [int]$Floor    = 40,  # Grayscale values <= Floor are forced to 0 (empty)
    [string]$InputPath,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$RootDir = Split-Path -Parent -Path $PSScriptRoot
$logoPng = if ($InputPath)  { $InputPath }  else { Join-Path $RootDir 'shared/logo.png' }
$outTxt  = if ($OutputPath) { $OutputPath } else { Join-Path $RootDir 'shared/logo_ascii.txt' }
$ffmpeg  = Join-Path $RootDir 'tools/ffmpeg.exe'
$tmpRaw  = [System.IO.Path]::GetTempFileName()

if (-not (Test-Path -LiteralPath $logoPng)) { Write-Host "logo.png not found" -ForegroundColor Red; exit 1 }
if (-not (Test-Path -LiteralPath $ffmpeg))  { Write-Host "ffmpeg.exe not found" -ForegroundColor Red; exit 1 }

# logo.png has an alpha channel, so we must first composite it onto a
# solid white background (otherwise transparent pixels leak into the
# luminance calc). After flattening: logo strokes are dark, background is
# white. Negate so logo->bright on black, then boost contrast and scale.
$c = [math]::Max(1, [math]::Min(100, $Contrast)) / 100.0
$lavfi = "color=c=white:s=${Width}x${Height}[bg];" +
         "[0:v]scale=${Width}:${Height}:flags=lanczos[fg];" +
         "[bg][fg]overlay=format=auto,negate,eq=contrast=$(1 + $c):saturation=0,format=gray"
& $ffmpeg -y -loglevel error -i $logoPng -filter_complex $lavfi -frames:v 1 -f rawvideo -pix_fmt gray $tmpRaw
if ($LASTEXITCODE -ne 0) { Write-Host "ffmpeg failed" -ForegroundColor Red; exit 1 }

$bytes = [System.IO.File]::ReadAllBytes($tmpRaw)
Remove-Item -LiteralPath $tmpRaw -ErrorAction SilentlyContinue

# Normalize: zero out anything below the floor, then stretch the remaining
# range so the brightest pixel maps to 255. This clears speckle out of the
# background and pushes solid logo strokes to full-block brightness.
for ($i = 0; $i -lt $bytes.Length; $i++) {
    if ($bytes[$i] -le $Floor) { $bytes[$i] = 0 }
}
$maxV = 0
foreach ($b in $bytes) { if ($b -gt $maxV) { $maxV = $b } }
if ($maxV -gt 0 -and $maxV -lt 255) {
    $scale = 255.0 / $maxV
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $nv = [int]([math]::Round($bytes[$i] * $scale))
        if ($nv -gt 255) { $nv = 255 }
        $bytes[$i] = [byte]$nv
    }
}

# Gradient: darkest -> lightest (chars via Unicode codepoints to keep this
# source file ASCII — PS5.1 does not read .ps1 as UTF-8).
$chars = @(
    ' ',
    [char]0x2591,  # light shade
    [char]0x2592,  # medium shade
    [char]0x2593,  # dark shade
    [char]0x2588   # full block
)
if ($Invert) { [Array]::Reverse($chars) }

$sb = New-Object System.Text.StringBuilder
for ($y = 0; $y -lt $Height; $y++) {
    $line = New-Object System.Text.StringBuilder
    for ($x = 0; $x -lt $Width; $x++) {
        $v = $bytes[$y * $Width + $x]
        $idx = [int][math]::Floor($v / 51.2)
        if ($idx -gt 4) { $idx = 4 }
        [void]$line.Append($chars[$idx])
    }
    [void]$sb.AppendLine($line.ToString().TrimEnd())
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($outTxt, $sb.ToString(), $utf8NoBom)
Write-Host "Wrote $outTxt ($Width x $Height)" -ForegroundColor Green
Write-Host ''
Write-Host $sb.ToString()
