#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Upload screenshots to onlyimage.org and save URLs to output file.
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
$directory = $directory.TrimEnd('"').TrimEnd('\')
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
$ApiKey = $config.onlyimage_api_key
if (-not $ApiKey) {
    Write-Host "Skipping: 'onlyimage_api_key' not configured in $configfile" -ForegroundColor Yellow
    exit 0
}

$Name = $baseName
$screens = @(
    (Join-Path $OutDir "${Name}_screen01.jpg"),
    (Join-Path $OutDir "${Name}_screen02.jpg"),
    (Join-Path $OutDir "${Name}_screen03.jpg")
)

$found = $screens | Where-Object { Test-Path -LiteralPath $_ }
if (-not $found) {
    Write-Host "Warning: no screenshots found in '$OutDir' for '$Name'. Run screens.ps1 first. Skipping." -ForegroundColor Yellow
    exit 0
}

Write-Host "Found $($found.Count) screenshot(s) to upload."
Write-Host ""

$OutputFile = Join-Path $OutDir "${Name}_screens.txt"
$success = 0
$fail = 0
$urls = [System.Collections.Generic.List[string]]::new()

foreach ($f in $found) {
    $filename = Split-Path -Path $f -Leaf
    Write-Host -NoNewline "Uploading: $filename ... "

    try {
        $tmpFile = [System.IO.Path]::GetTempFileName() + ".jpg"
        Copy-Item -LiteralPath $f -Destination $tmpFile -Force
        $result = & curl.exe -s -X POST "https://onlyimage.org/api/1/upload" `
            -H "X-API-Key: $ApiKey" `
            -F "source=@$tmpFile" `
            -F "format=json"
        Remove-Item -LiteralPath $tmpFile -ErrorAction SilentlyContinue

        $json = $result | ConvertFrom-Json
        $url = if ($json.image -and $json.image.url) { $json.image.url } elseif ($json.url) { $json.url } else { $null }

        if ($json.status_code -eq 200 -and $url) {
            Write-Host $url
            $urls.Add($url)
            $success++
        } else {
            $errTxt = if ($json.status_txt) { $json.status_txt } else { "unknown error" }
            Write-Host "FAILED ($errTxt)" -ForegroundColor Yellow
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
