#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Prints the active category list (honoring config.jsonc's
    `categories_file` override, falling back to shared/categories.jsonc).
#>
param([string]$configfile)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$RootDir = Split-Path -Parent $PSScriptRoot

if (-not $configfile) { $configfile = Join-Path $RootDir 'config.jsonc' }
if (-not (Test-Path -LiteralPath $configfile)) {
    Write-Host "Config not found: $configfile" -ForegroundColor Red
    exit 1
}

$config = (Get-Content -LiteralPath $configfile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json
$TrackerUrl = if ($config.tracker_url) { ([string]$config.tracker_url).TrimEnd('/') } else { '' }

# Resolve categories file: config override -> tracker-host-based -> default
$CategoriesFile = if ($config.categories_file) { [string]$config.categories_file } else { '' }
$explicit = [bool]$CategoriesFile
if ($CategoriesFile -and -not [System.IO.Path]::IsPathRooted($CategoriesFile)) {
    $CategoriesFile = Join-Path $RootDir $CategoriesFile
}
if (-not $CategoriesFile -or -not (Test-Path -LiteralPath $CategoriesFile)) {
    if ($explicit) {
        Write-Host "categories_file not found: $CategoriesFile" -ForegroundColor Yellow
    }
    $CategoriesFile = ''
    if ($TrackerUrl) {
        try {
            $trackerHost = ([System.Uri]$TrackerUrl).Host -replace '[^A-Za-z0-9]', '_'
            $hostFile = Join-Path $RootDir "shared\categories_${trackerHost}.jsonc"
            if (Test-Path -LiteralPath $hostFile) {
                $CategoriesFile = $hostFile
                Write-Host "Using tracker-host file: $hostFile" -ForegroundColor DarkGray
            }
        } catch { }
    }
    if (-not $CategoriesFile) {
        $CategoriesFile = Join-Path $RootDir 'shared\categories.jsonc'
        Write-Host "Falling back to: $CategoriesFile" -ForegroundColor Yellow
    }
}

Write-Host "File: $CategoriesFile" -ForegroundColor Cyan
Write-Host ""

$cats = (Get-Content -LiteralPath $CategoriesFile -Encoding UTF8 | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json
if (-not $cats) {
    Write-Host "(empty)" -ForegroundColor DarkGray
    exit 0
}

$cats |
    Sort-Object @{Expression='type'}, @{Expression={[int]$_.id}} |
    Format-Table -AutoSize -Property `
        @{ n='id';   e={ $_.id };   a='right' }, `
        @{ n='type'; e={ $_.type } }, `
        @{ n='name'; e={ $_.name } }
