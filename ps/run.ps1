#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Run pipeline steps for a given media directory.
.PARAMETER directory
    Path to the content directory.
.PARAMETER configfile
    Path to JSONC config file (default: ./config.jsonc).
.PARAMETER tv
    Switch to search for TV shows instead of movies.
.PARAMETER dht
    Switch to enable DHT for torrent creation.
.PARAMETER steps
    Comma-separated list of steps to run (default: all).
    Steps: 1/parse, 2/create, 3/screens, 4/tmdb, 5/imdb, 6/describe, 7/upload, 8/description
.PARAMETER help
    Show help message with available options and examples.
.EXAMPLE
    .\run.ps1 "D:\media\Pacific.Rim.2013.1080p.BluRay"
.EXAMPLE
    .\run.ps1 -steps 4,5,8 "D:\media\Pacific.Rim.2013.1080p.BluRay"
.EXAMPLE
    .\run.ps1 -tv -steps tmdb,imdb,describe "D:\media\Dexter.Original.Sin.S01"
#>
param(
    [Parameter(Position = 0)]
    [string]$directory,

    [Parameter(Position = 1)]
    [string]$configfile,

    [switch]$tv,

    [switch]$dht,

    [string[]]$steps,

    [Alias('q')]
    [string]$query,

    [Alias('sn')]
    [int]$season = -1,

    [Alias('h')]
    [switch]$help
)

$ErrorActionPreference = 'Stop'
$PSScriptRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $MyInvocation.MyCommand.Definition)
if ($directory) { $directory = $directory.TrimEnd('"').Trim().TrimEnd('\') }

function Show-Help {
    Write-Host @"
Usage: .\run.ps1 [options] <directory> [config.jsonc]

Run pipeline steps for a given media directory.

Arguments:
  directory    Path to the content directory or file
  config.jsonc   Path to JSONC config file (default: ./config.jsonc)

Options:
  -tv                Search for TV shows instead of movies
  -dht               Enable DHT for torrent (disabled by default)
  -query QUERY       Override auto-detected title for TMDB/IMDB search
  -season N          Override season number (e.g. -season 1, -season 0 for all seasons)
  -steps STEPS       Comma-separated list of steps to run (default: all)
  -help              Show this help message

Available steps:
  1  parse       - Extract MediaInfo from video files
  2  create      - Create .torrent file
  3  screens     - Take screenshots at 15%, 50%, 85%
  4  tmdb        - Search TMDB for metadata and BG title
  5  imdb        - Fetch IMDB details (rating, cast, etc.)
  6  describe    - Generate AI description via Gemini
  7  upload      - Upload screenshots to onlyimage.org
  8  description - Build final BBCode torrent description

Examples:
  # Run all steps (default)
  .\run.ps1 "D:\media\Pacific.Rim.2013.1080p.BluRay"

  # Run only TMDB + IMDB + description steps
  .\run.ps1 -steps 4,5,8 "D:\media\Pacific.Rim.2013.1080p.BluRay"

  # Run steps 1 through 3
  .\run.ps1 -steps 1,2,3 "D:\media\Pacific.Rim.2013.1080p.BluRay"

  # TV show with specific steps
  .\run.ps1 -tv -steps 4,5,6 "D:\media\Dexter.Original.Sin.S01"

  # Override search query (e.g. Cyrillic title not found by Latin name)
  .\run.ps1 -tv -query "Mamnik BG" "D:\media\Mamnik.S01\Mamnik.s01e09.mp4"

  # Run by step name
  .\run.ps1 -steps parse,screens,description "D:\media\Pacific.Rim.2013.1080p.BluRay"

  # From cmd
  run.bat -steps 4,5,8 "D:\media\Pacific.Rim.2013.1080p.BluRay"
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

# Resolve relative paths
$directory = (Resolve-Path -LiteralPath $directory).Path
if ([string]::IsNullOrEmpty($configfile)) {
    $configfile = Join-Path $PSScriptRoot "config.jsonc"
}
if (-not (Test-Path -LiteralPath $configfile)) {
    Write-Host "Error: config file '$configfile' not found. Run install.bat to create it from config.example.jsonc" -ForegroundColor Red
    exit 1
}
$configfile = (Resolve-Path -LiteralPath $configfile).Path

# Resolve step names to numbers
function Resolve-Step($s) {
    switch ($s.Trim().ToLower()) {
        '1'           { return 1 }
        'parse'       { return 1 }
        '2'           { return 2 }
        'create'      { return 2 }
        '3'           { return 3 }
        'screens'     { return 3 }
        '4'           { return 4 }
        'tmdb'        { return 4 }
        '5'           { return 5 }
        'imdb'        { return 5 }
        '6'           { return 6 }
        'describe'    { return 6 }
        '7'           { return 7 }
        'upload'      { return 7 }
        '8'           { return 8 }
        'description' { return 8 }
        default { Write-Host "Error: unknown step: '$s'" -ForegroundColor Red; exit 1 }
    }
}

# Build list of steps to run
$runSteps = @(1,2,3,4,5,6,7,8)
if ($steps) {
    $runSteps = ($steps -join ',').Split(',') | ForEach-Object { Resolve-Step $_ }
}

$createArgs = @{ directory = $directory; configfile = $configfile }
if ($dht.IsPresent) { $createArgs['dht'] = $true }

$metaArgs = @{ configfile = $configfile }
if ($tv.IsPresent) { $metaArgs['tv'] = $true }
if ($query) { $metaArgs['query'] = $query }
if ($season -ge 0) { $metaArgs['season'] = $season }

$total = $runSteps.Count
$current = 0

function Show-Step($label) {
    $script:current++
    Write-Host "========================================" -ForegroundColor Blue
    Write-Host "  $($script:current)/$total  $label" -ForegroundColor Blue
    Write-Host "========================================" -ForegroundColor Blue
}

if ($runSteps -contains 1) {
    Show-Step "MediaInfo"
    & "$PSScriptRoot/ps/parse.ps1" $directory
    Write-Host ""
}

if ($runSteps -contains 2) {
    Show-Step "Create Torrent"
    & "$PSScriptRoot/ps/create.ps1" @createArgs
    Write-Host ""
}

if ($runSteps -contains 3) {
    Show-Step "Screenshots"
    & "$PSScriptRoot/ps/screens.ps1" $directory
    Write-Host ""
}

if ($runSteps -contains 4) {
    Show-Step "TMDB Search"
    $tmdbArgs = @{ directory = $directory } + $metaArgs
    & "$PSScriptRoot/ps/tmdb.ps1" @tmdbArgs
    Write-Host ""
}

if ($runSteps -contains 5) {
    Show-Step "IMDB Lookup"
    $imdbArgs = @{ directory = $directory } + $metaArgs
    & "$PSScriptRoot/ps/imdb.ps1" @imdbArgs
    Write-Host ""
}

if ($runSteps -contains 6) {
    Show-Step "AI Description"
    $descArgs = @{ directory = $directory } + $metaArgs
    & "$PSScriptRoot/ps/describe.ps1" @descArgs
    Write-Host ""
}

if ($runSteps -contains 7) {
    Show-Step "Upload Screenshots"
    & "$PSScriptRoot/ps/screens_upload.ps1" $directory $configfile
    Write-Host ""
}

if ($runSteps -contains 8) {
    Show-Step "Build Torrent Description"
    $descBuildArgs = @{ directory = $directory; configfile = $configfile }
    if ($tv.IsPresent) { $descBuildArgs['tv'] = $true }
    & "$PSScriptRoot/ps/description.ps1" @descBuildArgs
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
$escapedName = $outputName -replace '([\[\]\*\?])', '`$1'
Get-ChildItem -LiteralPath "$PSScriptRoot/output" | Where-Object { $_.Name -like "${escapedName}*" } | Select-Object -Property Name, Length
