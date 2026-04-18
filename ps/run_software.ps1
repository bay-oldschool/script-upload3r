#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Run pipeline steps for a software directory.
.PARAMETER directory
    Path to the content directory.
.PARAMETER configfile
    Path to JSONC config file (default: ./config.jsonc).
.PARAMETER dht
    Switch to enable DHT for torrent creation.
.PARAMETER steps
    Comma-separated list of steps to run (default: all).
    Steps: 1/create, 2/describe, 3/description
.PARAMETER query
    Override auto-detected software title.
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
Usage: .\run_software.ps1 [options] <directory> [config.jsonc]

Run pipeline steps for a software directory.

Arguments:
  directory      Path to the software content directory or file
  config.jsonc   Path to JSONC config file (default: ./config.jsonc)

Options:
  -dht               Enable DHT for torrent (disabled by default)
  -query QUERY       Override auto-detected software title
  -steps STEPS       Comma-separated list of steps to run (default: all)
  -help              Show this help message

Available steps:
  1  create      - Create .torrent file
  2  describe    - Generate AI software description
  3  description - Build final BBCode torrent description

Examples:
  .\run_software.ps1 "D:\software\Adobe.Photoshop.2024"
  .\run_software.ps1 -query "Adobe Photoshop" "D:\software\Adobe.Photoshop.2024"
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
        'describe'    { return 2 }
        '3'           { return 3 }
        'description' { return 3 }
        default { Write-Host "Error: unknown step: '$s'" -ForegroundColor Red; exit 1 }
    }
}

$runSteps = @(1,2,3)
if ($steps) {
    $runSteps = ($steps -join ',').Split(',') | ForEach-Object { Resolve-Step $_ }
}

$createArgs = @{ directory = $directory; configfile = $configfile }
if ($dht.IsPresent) { $createArgs['dht'] = $true }

$describeArgs = @{ directory = $directory; configfile = $configfile }
if ($query) { $describeArgs['query'] = $query }

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
    Show-Step "AI Software Description"
    & "$PSScriptRoot/ps/describe_software.ps1" @describeArgs
    Write-Host ""
}

if ($runSteps -contains 3) {
    Show-Step "Build Torrent Description"
    $descArgs = @{ directory = $directory; configfile = $configfile; software = $true }
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
