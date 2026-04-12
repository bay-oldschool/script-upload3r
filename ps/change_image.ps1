#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pick a poster/backdrop from the TMDB listing saved by tmdb.ps1 and apply
    the selection to the upload request file and the torrent description file.
#>
param(
    [Parameter(Mandatory = $true)][string]$TorrentName,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][ValidateSet('poster','banner')][string]$Type
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition

$TmdbFile    = Join-Path $OutDir ("${TorrentName}_tmdb.txt")
$RequestFile = Join-Path $OutDir ("${TorrentName}_upload_request.txt")
$DescFile    = Join-Path $OutDir ("${TorrentName}_torrent_description.bbcode")

if (-not (Test-Path -LiteralPath $TmdbFile)) {
    Write-Host "TMDB listing not found: $TmdbFile" -ForegroundColor Red
    Write-Host "Run the tmdb step first to generate the image list." -ForegroundColor Yellow
    exit 1
}

$section = if ($Type -eq 'poster') { 'POSTERS' } else { 'BACKDROPS' }
$label   = if ($Type -eq 'poster') { 'Cover' }   else { 'Banner' }
$key     = if ($Type -eq 'poster') { 'poster' }  else { 'banner' }

# Parse section entries from the TMDB listing file
$entries = @()
$inSection = $false
foreach ($l in (Get-Content -LiteralPath $TmdbFile -Encoding UTF8)) {
    if ($l -match "^$section") { $inSection = $true; continue }
    if ($inSection) {
        if ($l -match '^\s*\d+\)\s+(.+)$') {
            $entries += $matches[1].Trim()
        } elseif ($l -match '^\S') {
            break
        }
    }
}

if ($entries.Count -eq 0) {
    Write-Host "No $section entries found in $TmdbFile" -ForegroundColor Red
    Write-Host "Re-run the tmdb step to regenerate the listing." -ForegroundColor Yellow
    exit 1
}

# Extract URL from each entry (the http(s) token)
$urls = @()
foreach ($e in $entries) {
    if ($e -match '(https?://\S+)') { $urls += $matches[1] } else { $urls += '' }
}

# Current URL from request file (for display + later replacement in description)
$oldUrl = $null
if (Test-Path -LiteralPath $RequestFile) {
    foreach ($rl in (Get-Content -LiteralPath $RequestFile -Encoding UTF8)) {
        if ($rl -match "^$key=(.*)$") { $oldUrl = $matches[1]; break }
    }
}

Write-Host ""
Write-Host "$label options (from $section listing):" -ForegroundColor Cyan
if ($oldUrl) { Write-Host "Current: $oldUrl" -ForegroundColor DarkGray }
Write-Host ""
for ($i = 0; $i -lt $entries.Count; $i++) {
    $marker = if ($oldUrl -and $urls[$i] -eq $oldUrl) { ' *' } else { '' }
    Write-Host ("  {0,2}) {1}{2}" -f ($i + 1), $entries[$i], $marker)
}
Write-Host ""
Write-Host "  r<n>) Render choice <n> in terminal"
Write-Host "  Enter / c) Cancel (keep current)"
Write-Host ""

$newUrl = $null
while ($true) {
    $pick = Read-Host "Select"
    if (-not $pick -or $pick -eq 'c' -or $pick -eq 'C') {
        Write-Host "Cancelled." -ForegroundColor Yellow
        exit 0
    }
    if ($pick -match '^[rR]\s*(\d+)$') {
        $idx = [int]$matches[1] - 1
        if ($idx -ge 0 -and $idx -lt $urls.Count -and $urls[$idx]) {
            & (Join-Path $PSScriptRoot 'render_image.ps1') -Url $urls[$idx]
        } else {
            Write-Host "Out of range." -ForegroundColor Yellow
        }
        continue
    }
    if ($pick -match '^\d+$') {
        $idx = [int]$pick - 1
        if ($idx -lt 0 -or $idx -ge $urls.Count -or -not $urls[$idx]) {
            Write-Host "Out of range." -ForegroundColor Yellow
            continue
        }
        $newUrl = $urls[$idx]
        break
    }
    Write-Host "Invalid input." -ForegroundColor Yellow
}

if (-not $newUrl) { exit 0 }
if ($oldUrl -and $oldUrl -eq $newUrl) {
    Write-Host "Selection matches current $key. No changes applied." -ForegroundColor Yellow
    exit 0
}

$utf8NoBom = New-Object System.Text.UTF8Encoding $false

# Update upload request file
if (Test-Path -LiteralPath $RequestFile) {
    $lines = [System.IO.File]::ReadAllLines($RequestFile, [System.Text.Encoding]::UTF8)
    $updated = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^$key=(.*)$") {
            $lines[$i] = "$key=$newUrl"
            $updated = $true
        }
    }
    if (-not $updated) { $lines += "$key=$newUrl" }
    [System.IO.File]::WriteAllText($RequestFile, ($lines -join "`n") + "`n", $utf8NoBom)
    Write-Host "Updated $key in: $RequestFile" -ForegroundColor Green
} else {
    Write-Host "Request file not found: $RequestFile" -ForegroundColor Yellow
}

# Update description file (replace old URL occurrences with new)
if ($oldUrl -and (Test-Path -LiteralPath $DescFile)) {
    $desc = [System.IO.File]::ReadAllText($DescFile, [System.Text.Encoding]::UTF8)
    if ($desc.Contains($oldUrl)) {
        $desc = $desc.Replace($oldUrl, $newUrl)
        [System.IO.File]::WriteAllText($DescFile, $desc, $utf8NoBom)
        Write-Host "Updated $Type URL in: $DescFile" -ForegroundColor Green
    } else {
        Write-Host "Old $Type URL not present in description file (no change)." -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "New ${key}: $newUrl" -ForegroundColor Cyan
exit 0
