#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Run pipeline steps for a music directory.
.PARAMETER directory
    Path to the content directory.
.PARAMETER configfile
    Path to JSONC config file (default: ./config.jsonc).
.PARAMETER dht
    Switch to enable DHT for torrent creation.
.PARAMETER steps
    Comma-separated list of steps to run (default: all).
    Steps: 1/parse, 2/create, 3/musicbrainz, 4/describe, 5/description
.PARAMETER query
    Override auto-detected album title for search.
.PARAMETER help
    Show help message.
#>
param(
    [Parameter(Position = 0)]
    [string]$directory,

    [Parameter(Position = 1)]
    [string]$configfile,

    [switch]$dht,

    [string[]]$steps,

    [Alias('q')]
    [string]$query,

    [string]$poster,

    [string]$year,

    [Alias('h')]
    [switch]$help
)

$ErrorActionPreference = 'Stop'
$PSScriptRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $MyInvocation.MyCommand.Definition)
if ($directory) { $directory = $directory.TrimEnd('"').Trim().TrimEnd('\') }

function Show-Help {
    Write-Host @"
Usage: .\run_music.ps1 [options] <directory> [config.jsonc]

Run pipeline steps for a music directory.

Arguments:
  directory      Path to the music content directory or file
  config.jsonc   Path to JSONC config file (default: ./config.jsonc)

Options:
  -dht               Enable DHT for torrent (disabled by default)
  -query QUERY       Override auto-detected title for Deezer/MusicBrainz search
  -steps STEPS       Comma-separated list of steps to run (default: all)
  -help              Show this help message

Available steps:
  1  parse       - Extract MediaInfo from audio file
  2  create      - Create .torrent file
  3  musicbrainz - Search Deezer/MusicBrainz for album metadata
  4  describe    - Generate AI music description
  5  description - Build final BBCode torrent description

Examples:
  # Run all steps (default)
  .\run_music.ps1 "D:\music\Metallica-Master.of.Puppets-1986-FLAC"

  # Run only metadata + description steps
  .\run_music.ps1 -steps 3,4,5 "D:\music\Metallica-Master.of.Puppets-1986-FLAC"

  # Override search query
  .\run_music.ps1 -query "Metallica Master of Puppets" "D:\music\Metallica-Master.of.Puppets-1986-FLAC"
"@
    exit 0
}

if ($help -or -not $directory) {
    if (-not $directory) { Write-Host "Error: directory argument required" -ForegroundColor Red }
    Show-Help
}

if (-not (Test-Path -LiteralPath $directory)) {
    Write-Host "Error: '$directory' is not a file or directory." -ForegroundColor Red
    exit 1
}

$directory = (Resolve-Path -LiteralPath $directory).Path
if ([string]::IsNullOrEmpty($configfile)) {
    $configfile = Join-Path $PSScriptRoot "config.jsonc"
}
if (-not (Test-Path -LiteralPath $configfile)) {
    Write-Host "Error: config file '$configfile' not found." -ForegroundColor Red
    exit 1
}
$configfile = (Resolve-Path -LiteralPath $configfile).Path

function Resolve-Step($s) {
    switch ($s.Trim().ToLower()) {
        '1'            { return 1 }
        'parse'        { return 1 }
        '2'            { return 2 }
        'create'       { return 2 }
        '3'            { return 3 }
        'musicbrainz'  { return 3 }
        '4'            { return 4 }
        'describe'     { return 4 }
        '5'            { return 5 }
        'description'  { return 5 }
        default { Write-Host "Error: unknown step: '$s'" -ForegroundColor Red; exit 1 }
    }
}

$runSteps = @(1,2,3,4,5)
if ($steps) {
    $runSteps = ($steps -join ',').Split(',') | ForEach-Object { Resolve-Step $_ }
}

$createArgs = @{ directory = $directory; configfile = $configfile }
if ($dht.IsPresent) { $createArgs['dht'] = $true }

$mbArgs = @{ directory = $directory; configfile = $configfile }
if ($query) { $mbArgs['query'] = $query }

$total = $runSteps.Count
$current = 0

function Show-Step($label) {
    $script:current++
    Write-Host "========================================" -ForegroundColor Blue
    Write-Host "  $($script:current)/$total  $label" -ForegroundColor Blue
    Write-Host "========================================" -ForegroundColor Blue
}

if ($runSteps -contains 1) {
    Show-Step "Extract MediaInfo"
    & "$PSScriptRoot/ps/parse.ps1" $directory
    Write-Host ""
}

if ($runSteps -contains 2) {
    Show-Step "Create Torrent"
    & "$PSScriptRoot/ps/create.ps1" @createArgs
    Write-Host ""
}

if ($runSteps -contains 3) {
    Show-Step "Music Metadata"
    & "$PSScriptRoot/ps/music.ps1" @mbArgs
    if ($LASTEXITCODE -eq 2) {
        Write-Host "Pipeline cancelled by user." -ForegroundColor Yellow
        exit 0
    }
    Write-Host ""
}

if ($runSteps -contains 4) {
    Show-Step "AI Music Description"
    & "$PSScriptRoot/ps/describe_music.ps1" @mbArgs
    Write-Host ""
}

if ($runSteps -contains 5) {
    Show-Step "Build Torrent Description"
    $descArgs = @{ directory = $directory; configfile = $configfile; music = $true }
    if ($poster) { $descArgs['poster'] = $poster }
    if ($year) { $descArgs['year'] = $year }
    & "$PSScriptRoot/ps/description.ps1" @descArgs
    Write-Host ""
}

if (Test-Path -LiteralPath $directory -PathType Leaf) {
    $outputName = [System.IO.Path]::GetFileNameWithoutExtension($directory)
} else {
    $outputName = Split-Path -Path $directory -Leaf
}

Write-Host "========================================" -ForegroundColor Green
Write-Host "  Done! Files for: $outputName" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
$escapedName = [WildcardPattern]::Escape($outputName)
Get-ChildItem -LiteralPath "$PSScriptRoot/output" | Where-Object { $_.Name -like "${escapedName}*" } | Select-Object -Property Name, Length
