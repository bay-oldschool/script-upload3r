#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Run pipeline steps for a game directory.
.PARAMETER directory
    Path to the content directory.
.PARAMETER configfile
    Path to JSONC config file (default: ./config.jsonc).
.PARAMETER dht
    Switch to enable DHT for torrent creation.
.PARAMETER steps
    Comma-separated list of steps to run (default: all).
    Steps: 1/create, 2/igdb, 3/describe, 4/description
.PARAMETER query
    Override auto-detected game title for IGDB search.
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

    [Alias('h')]
    [switch]$help
)

$ErrorActionPreference = 'Stop'
$PSScriptRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $MyInvocation.MyCommand.Definition)
if ($directory) { $directory = $directory.TrimEnd('"').Trim().TrimEnd('\') }

function Show-Help {
    Write-Host @"
Usage: .\run_game.ps1 [options] <directory> [config.jsonc]

Run pipeline steps for a game directory.

Arguments:
  directory      Path to the game content directory or file
  config.jsonc   Path to JSONC config file (default: ./config.jsonc)

Options:
  -dht               Enable DHT for torrent (disabled by default)
  -query QUERY       Override auto-detected title for IGDB search
  -steps STEPS       Comma-separated list of steps to run (default: all)
  -help              Show this help message

Available steps:
  1  create      - Create .torrent file
  2  igdb        - Search IGDB for game metadata
  3  describe    - Generate AI game description
  4  description - Build final BBCode torrent description

Examples:
  # Run all steps (default)
  .\run_game.ps1 "D:\games\Elden.Ring-CODEX"

  # Run only IGDB + description steps
  .\run_game.ps1 -steps 2,3,4 "D:\games\Elden.Ring-CODEX"

  # Override search query
  .\run_game.ps1 -query "Elden Ring" "D:\games\Elden.Ring-CODEX"
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
        '1'           { return 1 }
        'create'      { return 1 }
        '2'           { return 2 }
        'igdb'        { return 2 }
        '3'           { return 3 }
        'describe'    { return 3 }
        '4'           { return 4 }
        'description' { return 4 }
        default { Write-Host "Error: unknown step: '$s'" -ForegroundColor Red; exit 1 }
    }
}

$runSteps = @(1,2,3,4)
if ($steps) {
    $runSteps = ($steps -join ',').Split(',') | ForEach-Object { Resolve-Step $_ }
}

$createArgs = @{ directory = $directory; configfile = $configfile }
if ($dht.IsPresent) { $createArgs['dht'] = $true }

$igdbArgs = @{ directory = $directory; configfile = $configfile }
if ($query) { $igdbArgs['query'] = $query }

$total = $runSteps.Count
$current = 0

function Show-Step($label) {
    $script:current++
    Write-Host "========================================" -ForegroundColor Blue
    Write-Host "  $($script:current)/$total  $label" -ForegroundColor Blue
    Write-Host "========================================" -ForegroundColor Blue
}

if ($runSteps -contains 1) {
    Show-Step "Create Torrent"
    & "$PSScriptRoot/ps/create.ps1" @createArgs
    Write-Host ""
}

if ($runSteps -contains 2) {
    Show-Step "IGDB Search"
    & "$PSScriptRoot/ps/igdb.ps1" @igdbArgs
    Write-Host ""
}

if ($runSteps -contains 3) {
    Show-Step "AI Game Description"
    & "$PSScriptRoot/ps/describe_game.ps1" @igdbArgs
    Write-Host ""
}

if ($runSteps -contains 4) {
    Show-Step "Build Torrent Description"
    $descArgs = @{ directory = $directory; configfile = $configfile; game = $true }
    if ($poster) { $descArgs['poster'] = $poster }
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
$escapedName = $outputName -replace '([\[\]\*\?])', '`$1'
Get-ChildItem -LiteralPath "$PSScriptRoot/output" | Where-Object { $_.Name -like "${escapedName}*" } | Select-Object -Property Name, Length
