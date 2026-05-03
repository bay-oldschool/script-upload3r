#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Upload screenshots via the configured image provider and save URLs to output file.
.PARAMETER directory
    Path to the content directory (used to find matching screenshots).
.PARAMETER configfile
    Path to the JSON config file.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$directory,

    [Parameter(Position = 1)]
    [string]$configfile
)

$ErrorActionPreference = 'Stop'
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$directory = $directory.TrimEnd('"').Trim().TrimEnd('\')
$OutDir = "$PSScriptRoot/../output"

if (-not $configfile) { $configfile = "$PSScriptRoot/../config.jsonc" }

if (Test-Path -LiteralPath $directory -PathType Leaf) {
    $singleFile = $directory
    $directory = Split-Path -Parent $directory
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($singleFile)
} else {
    $singleFile = $null
    $baseName = Split-Path -Path $directory -Leaf
}

if (-not (Test-Path -LiteralPath $configfile)) {
    Write-Host "Warning: config file '$configfile' not found. Skipping." -ForegroundColor Yellow
    exit 0
}

$config = (Get-Content -LiteralPath $configfile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json

. (Join-Path (Join-Path $PSScriptRoot '..') 'shared/image_upload.ps1')

$provider = if ($config.image_provider) { ([string]$config.image_provider).ToLower() } else { 'onlyimage' }
$keyField = switch ($provider) {
    'onlyimage' { 'onlyimage_api_key' }
    'freeimage' { 'freeimage_api_key' }
    'imgbb'     { 'imgbb_api_key' }
    'pixhost'   { $null }
    default     { $null }
}
if ($keyField -and -not $config.$keyField) {
    Write-Host "Skipping: '$keyField' not configured in $configfile (image_provider=$provider)" -ForegroundColor Yellow
    exit 0
}

$Name = $baseName
$screens = @(
    (Join-Path $OutDir "${Name}_screen01.png"),
    (Join-Path $OutDir "${Name}_screen02.png"),
    (Join-Path $OutDir "${Name}_screen03.png")
)

$found = $screens | Where-Object { Test-Path -LiteralPath $_ }
if (-not $found) {
    Write-Host "Warning: no screenshots found in '$OutDir' for '$Name'. Run screens.ps1 first. Skipping." -ForegroundColor Yellow
    exit 0
}

Write-Host "Found $($found.Count) screenshot(s) to upload via $provider."
Write-Host ""

$OutputFile = Join-Path $OutDir "${Name}_screens.txt"
$success = 0
$fail = 0
$urls = [System.Collections.Generic.List[string]]::new()

foreach ($f in $found) {
    $filename = Split-Path -Path $f -Leaf
    Write-Host -NoNewline "Uploading: $filename ... "

    try {
        $r = Invoke-ImageUpload -Config $config -FilePath $f
        if ($r.Success) {
            Write-Host $r.Url
            $urls.Add($r.Url)
            $success++
        } else {
            Write-Host "FAILED ($($r.Error))" -ForegroundColor Yellow
            $fail++
        }
    } catch {
        Write-Host "FAILED ($($_.Exception.Message))" -ForegroundColor Yellow
        $fail++
    }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($OutputFile, $urls, $utf8NoBom)

Write-Host ""
$doneColor = if ($fail -gt 0) { 'Yellow' } else { 'Green' }
Write-Host "Done: $success uploaded, $fail failed -> $OutputFile" -ForegroundColor $doneColor
