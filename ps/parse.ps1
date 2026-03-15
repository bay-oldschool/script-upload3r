#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Extracts full MediaInfo from the main video file in a directory.
.PARAMETER directory
    Path to the content directory containing the video file.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$directory
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

$MediaInfoExe = "$PSScriptRoot/../tools/MediaInfo.exe"
$OutDir = "$PSScriptRoot/../output"

if (-not (Test-Path -Path $MediaInfoExe)) {
    Write-Host "Warning: MediaInfo.exe not found at '$MediaInfoExe'. Run install.bat to download it. Skipping." -ForegroundColor Yellow
    exit 0
}

if ($singleFile) {
    $VideoFile = Get-Item -LiteralPath $singleFile
} else {
    $videoExts = @('.mkv', '.mp4', '.avi', '.ts', '.wmv', '.wmv', '.flv', '.m4v', '.mov')
    $VideoFile = Get-ChildItem -LiteralPath $directory -Recurse -File |
        Where-Object { ($videoExts -contains $_.Extension.ToLower()) -and ($_.FullName -notmatch 'sample|trailer|featurette') } |
        Sort-Object Name |
        Select-Object -First 1
}

if (-not $VideoFile) {
    Write-Host "Warning: no video file found in '$directory'. Skipping." -ForegroundColor Yellow
    exit 0
}

New-Item -Path $OutDir -ItemType Directory -ErrorAction SilentlyContinue
$OutputFile = Join-Path -Path $OutDir -ChildPath "${baseName}_mediainfo.txt"

Write-Host "Parsing: $($VideoFile.Name)"
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = (Resolve-Path $MediaInfoExe).Path
$psi.Arguments = "`"$($VideoFile.FullName)`""
$psi.RedirectStandardOutput = $true
$psi.UseShellExecute = $false
$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
$proc = [System.Diagnostics.Process]::Start($psi)
$miOutput = $proc.StandardOutput.ReadToEnd()
$proc.WaitForExit()
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutputFile, $miOutput, $utf8NoBom)

Write-Host "Saved to: $OutputFile" -ForegroundColor Green