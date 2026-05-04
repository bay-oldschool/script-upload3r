#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Takes screenshots from the main video file in a directory.
.PARAMETER directory
    Path to the content directory containing the video.
.PARAMETER outputdir
    Optional output directory.
.PARAMETER count
    Override the number of screenshots to take (default: read screen_count from
    config.jsonc, falling back to 3).
.PARAMETER configfile
    Path to JSONC config file (default: ../config.jsonc relative to this script).
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$directory,

    [Parameter(Position = 1)]
    [string]$outputdir,

    [int]$count = 0,

    [string]$configfile
)

$ErrorActionPreference = 'Stop'
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$directory = $directory.TrimEnd('"').Trim().TrimEnd('\')

if (Test-Path -LiteralPath $directory -PathType Leaf) {
    $singleFile = $directory
    $directory = Split-Path -Parent $directory
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($singleFile)
} else {
    $singleFile = $null
    $baseName = Split-Path -Path $directory -Leaf
}

$FFmpegExe = "$PSScriptRoot/../tools/ffmpeg.exe"
$FFprobeExe = "$PSScriptRoot/../tools/ffprobe.exe"

if (-not $outputdir) {
    $outputdir = "$PSScriptRoot/../output"
}

if (-not (Test-Path -Path $FFmpegExe -PathType Leaf) -or -not (Test-Path -Path $FFprobeExe -PathType Leaf)) {
    Write-Host "Warning: ffmpeg.exe or ffprobe.exe not found in ../tools/. Run install.bat to download them. Skipping." -ForegroundColor Yellow
    exit 0
}

if ($singleFile) {
    $VideoFile = Get-Item -LiteralPath $singleFile
} else {
    $videoExts = @('.mkv', '.mp4', '.avi', '.ts', '.wmv', '.mov')
    $VideoFile = Get-ChildItem -LiteralPath $directory -Recurse -File |
        Where-Object { ($videoExts -contains $_.Extension.ToLower()) -and ($_.FullName -notmatch 'sample|trailer|featurette') } |
        Sort-Object Name |
        Select-Object -First 1
}

if (-not $VideoFile) {
    Write-Host "Warning: no video file found in '$directory'. Skipping." -ForegroundColor Yellow
    exit 0
}

Write-Host "Found video: $($VideoFile.Name)"

$durationRaw = & $FFprobeExe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $VideoFile.FullName 2>&1
$durationString = "$durationRaw".Trim()
if (-not $durationString -or $durationString -eq 'N/A') {
    Write-Host "Warning: could not determine video duration. Skipping." -ForegroundColor Yellow
    exit 0
}
$duration = 0
[double]$durationDouble = 0.0
if ([double]::TryParse($durationString, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$durationDouble)) {
    $duration = [int]$durationDouble
} else {
    Write-Host "Warning: ffprobe returned unparseable duration: '$durationString'. Skipping." -ForegroundColor Yellow
    exit 0
}

if ($duration -eq 0) {
    Write-Host "Warning: could not determine video duration. Skipping." -ForegroundColor Yellow
    exit 0
}
Write-Host "Duration: ${duration}s"

# Resolve screenshot count: explicit -count parameter wins, otherwise read
# screen_count from config.jsonc, falling back to 3.
$screenCount = $count
if ($screenCount -le 0) {
    if (-not $configfile) { $configfile = "$PSScriptRoot/../config.jsonc" }
    if (Test-Path -LiteralPath $configfile) {
        try {
            $cfg = (Get-Content -LiteralPath $configfile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json
            if ($cfg.screen_count) { $screenCount = [int]$cfg.screen_count }
        } catch { }
    }
}
if ($screenCount -le 0) { $screenCount = 3 }
if ($screenCount -gt 30) { $screenCount = 30 }

# Spread N timestamps across [10%, 90%] of duration with per-slot jitter so the
# captures are evenly distributed and never overlap each other.
$rng = New-Object System.Random
$timestamps = @()
$slot = 80.0 / $screenCount
for ($i = 0; $i -lt $screenCount; $i++) {
    $low  = 10.0 + $i * $slot
    $high = 10.0 + ($i + 1) * $slot
    $lowI  = [int][Math]::Floor($low)
    $highI = [int][Math]::Ceiling($high)
    if ($highI -le $lowI) { $highI = $lowI + 1 }
    $pct = $rng.Next($lowI, $highI + 1)
    $timestamps += [int]($duration * ($pct / 100.0))
}
$name = $baseName

New-Item -Path $outputdir -ItemType Directory -ErrorAction SilentlyContinue
Write-Host "Taking $screenCount screenshot(s)..."

for ($i = 0; $i -lt $timestamps.Length; $i++) {
    $screenNum = ($i + 1).ToString("00")
    $outputFile = Join-Path -Path $outputdir -ChildPath "${name}_screen${screenNum}.png"
    & $FFmpegExe -ss $timestamps[$i] -i $VideoFile.FullName -vframes 1 -y $outputFile -v error
    Write-Host "Saved: $outputFile" -ForegroundColor Green
}

Write-Host "Done." -ForegroundColor Green