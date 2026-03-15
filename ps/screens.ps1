#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Takes 3 screenshots from the main video file in a directory.
.PARAMETER directory
    Path to the content directory containing the video.
.PARAMETER outputdir
    Optional output directory.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$directory,

    [Parameter(Position = 1)]
    [string]$outputdir
)

$ErrorActionPreference = 'Stop'
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$directory = $directory.TrimEnd('"').TrimEnd('\')

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

$durationString = (& $FFprobeExe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $VideoFile.FullName).Trim()
if (-not $durationString -or $durationString -eq 'N/A') {
    Write-Host "Warning: could not determine video duration. Skipping." -ForegroundColor Yellow
    exit 0
}
$duration = [int][double]::Parse($durationString, [System.Globalization.CultureInfo]::InvariantCulture)

if ($duration -eq 0) {
    Write-Host "Warning: could not determine video duration. Skipping." -ForegroundColor Yellow
    exit 0
}
Write-Host "Duration: ${duration}s"

$timestamps = @([int]($duration * 0.15)), @([int]($duration * 0.50)), @([int]($duration * 0.85))
$name = $baseName

New-Item -Path $outputdir -ItemType Directory -ErrorAction SilentlyContinue
Write-Host "Taking screenshots..."

for ($i = 0; $i -lt $timestamps.Length; $i++) {
    $screenNum = ($i + 1).ToString("00")
    $outputFile = Join-Path -Path $outputdir -ChildPath "${name}_screen${screenNum}.jpg"
    & $FFmpegExe -ss $timestamps[$i] -i $VideoFile.FullName -vframes 1 -q:v 2 -y $outputFile -v error
    Write-Host "Saved: $outputFile" -ForegroundColor Green
}

Write-Host "Done." -ForegroundColor Green