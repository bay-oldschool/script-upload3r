#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pick TMDB backdrops to use as screenshots, write the chosen URLs to
    <name>_screens.txt, and rebuild the torrent description.
.DESCRIPTION
    Reads the BACKDROPS section produced by tmdb.ps1 (with use_tmdb_screens=1
    that section contains every available backdrop). Renders the list as a
    grid of thumbnails in the terminal (perRow x rows per page) using
    ImageMagick + chafa for sixel output. The user picks numbers from the
    grid; the chosen URLs are written to <name>_screens.txt and description.ps1
    is invoked to rebuild the final BBCode description.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$directory,

    [Parameter(Position = 1)]
    [string]$configfile,

    [switch]$tv
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$RootDir = Split-Path -Parent $PSScriptRoot
$directory = $directory.TrimEnd('"').Trim().TrimEnd('\')
if (-not $configfile) { $configfile = Join-Path $RootDir 'config.jsonc' }

if (Test-Path -LiteralPath $directory -PathType Leaf) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($directory)
} else {
    $baseName = Split-Path -Path $directory -Leaf
}

$OutDir = Join-Path $RootDir 'output'
$TmdbFile    = Join-Path $OutDir "${baseName}_tmdb.txt"
$ScreensFile = Join-Path $OutDir "${baseName}_screens.txt"

if (-not (Test-Path -LiteralPath $TmdbFile)) {
    Write-Host "TMDB listing not found: $TmdbFile" -ForegroundColor Red
    Write-Host "Run the tmdb step first to generate the image list." -ForegroundColor Yellow
    exit 1
}

$config = (Get-Content -LiteralPath $configfile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json
$perRow = if ($config.tmdb_screens_per_row) { [int]$config.tmdb_screens_per_row } else { 4 }
$rowsPerPage = if ($config.tmdb_screens_rows) { [int]$config.tmdb_screens_rows } else { 2 }
if ($perRow -lt 1) { $perRow = 1 }
if ($perRow -gt 6) { $perRow = 6 }
if ($rowsPerPage -lt 1) { $rowsPerPage = 1 }
if ($rowsPerPage -gt 4) { $rowsPerPage = 4 }
$pageSize = $perRow * $rowsPerPage

# Parse BACKDROPS section
$entries = @()
$inSection = $false
foreach ($l in (Get-Content -LiteralPath $TmdbFile -Encoding UTF8)) {
    if ($l -match '^BACKDROPS') { $inSection = $true; continue }
    if ($inSection) {
        if ($l -match '^\s*\d+\)\s+(.+)$') {
            $line = $matches[1].Trim()
            if ($line -match '(https?://\S+)') { $entries += @{ Label = $line; Url = $matches[1] } }
        } elseif ($l -match '^\S') {
            break
        }
    }
}

if ($entries.Count -eq 0) {
    Write-Host "No backdrops found in $TmdbFile" -ForegroundColor Red
    Write-Host "Re-run the tmdb step (with use_tmdb_screens=1) to populate the list." -ForegroundColor Yellow
    exit 1
}

# Locate magick + chafa for sixel rendering
$magick = (Get-Command magick -ErrorAction SilentlyContinue).Source
if (-not $magick) {
    $d = Get-ChildItem 'C:\Program Files\ImageMagick-*' -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($d) {
        $c = Join-Path $d.FullName 'magick.exe'
        if (Test-Path -LiteralPath $c) { $magick = $c }
    }
}
$chafa = (Get-Command chafa -ErrorAction SilentlyContinue).Source
if (-not $chafa) {
    $c = Join-Path $RootDir 'tools\chafa.exe'
    if (Test-Path -LiteralPath $c) { $chafa = $c }
}
if (-not $chafa) {
    $wingetPkg = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\hpjansson.Chafa_*" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($wingetPkg) {
        $cf = Get-ChildItem "$($wingetPkg.FullName)\chafa-*\Chafa.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cf) { $chafa = $cf.FullName }
    }
}
$canRender = ($magick -and $chafa)
if (-not $canRender) {
    Write-Host "Image rendering disabled (chafa or ImageMagick missing). Showing text-only list." -ForegroundColor Yellow
}

$termWidth = 120
try { $termWidth = [Console]::WindowWidth } catch { }
if (-not $termWidth -or $termWidth -lt 40) { $termWidth = 120 }

function Render-Page {
    param([int]$Start, [int]$Count)
    if (-not $canRender) { return }
    $end = [Math]::Min($Start + $Count, $entries.Count) - 1
    $tmpFiles = @()
    try {
        # Download all images for the page
        for ($i = $Start; $i -le $end; $i++) {
            $tmp = [System.IO.Path]::GetTempFileName() + '.img'
            Write-Host -NoNewline ("Downloading {0}/{1}... " -f ($i - $Start + 1), ($end - $Start + 1))
            & curl.exe -sS -L --max-time 60 -o $tmp $entries[$i].Url 2>$null
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $tmp) -and (Get-Item -LiteralPath $tmp).Length -gt 0) {
                Write-Host "ok" -ForegroundColor Green
                $tmpFiles += $tmp
            } else {
                Write-Host "fail" -ForegroundColor Yellow
                $tmpFiles += $null
            }
        }
        # Render row by row
        $rowCount = [int][Math]::Ceiling(($end - $Start + 1) / [double]$perRow)
        for ($r = 0; $r -lt $rowCount; $r++) {
            $rowStart = $r * $perRow
            $rowEnd   = [Math]::Min($rowStart + $perRow - 1, $end - $Start)
            $rowFiles = @()
            for ($k = $rowStart; $k -le $rowEnd; $k++) {
                if ($tmpFiles[$k]) { $rowFiles += $tmpFiles[$k] }
            }
            if ($rowFiles.Count -eq 0) { continue }
            $merged = [System.IO.Path]::GetTempFileName() + '.jpg'
            try {
                & $magick @rowFiles -resize x180 +append $merged 2>$null
                if (Test-Path -LiteralPath $merged) {
                    & $chafa --format sixel -s "${termWidth}x" $merged 2>$null
                    Write-Host ""
                }
            } finally {
                Remove-Item -LiteralPath $merged -ErrorAction SilentlyContinue
            }
            # Caption row with global indices
            $caption = ''
            for ($k = $rowStart; $k -le $rowEnd; $k++) {
                $globalIdx = $Start + $k + 1
                $cell = (' [{0}] ' -f $globalIdx)
                $cellWidth = [Math]::Floor($termWidth / [double]$perRow)
                $pad = [Math]::Max(0, $cellWidth - $cell.Length)
                $caption += $cell + (' ' * $pad)
            }
            Write-Host $caption -ForegroundColor Cyan
        }
    } finally {
        foreach ($t in $tmpFiles) { if ($t) { Remove-Item -LiteralPath $t -ErrorAction SilentlyContinue } }
    }
}

function Show-PageList {
    param([int]$Start, [int]$Count)
    $end = [Math]::Min($Start + $Count, $entries.Count) - 1
    Write-Host ""
    for ($i = $Start; $i -le $end; $i++) {
        Write-Host ("  {0,3}) {1}" -f ($i + 1), $entries[$i].Label)
    }
}

# Show current screen URLs (if any) for context
$currentScreens = @()
if (Test-Path -LiteralPath $ScreensFile) {
    $currentScreens = @(Get-Content -LiteralPath $ScreensFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if ($currentScreens.Count -gt 0) {
    Write-Host ""
    Write-Host "Currently saved screens:" -ForegroundColor DarkGray
    $cs = 0
    foreach ($u in $currentScreens) { $cs++; Write-Host ("  {0}) {1}" -f $cs, $u) -ForegroundColor DarkGray }
}

$totalPages = [int][Math]::Ceiling($entries.Count / [double]$pageSize)
$page = 0
$renderedPage = -1
$picked = @()

while ($true) {
    $pageStart = $page * $pageSize
    if ($renderedPage -ne $page) {
        Write-Host ""
        Write-Host ("Backdrops page {0}/{1} (showing {2}-{3} of {4})" -f ($page + 1), $totalPages, ($pageStart + 1), ([Math]::Min($pageStart + $pageSize, $entries.Count)), $entries.Count) -ForegroundColor Cyan
        Render-Page -Start $pageStart -Count $pageSize
        Show-PageList -Start $pageStart -Count $pageSize
        Write-Host ""
        Write-Host "Commands:" -ForegroundColor DarkGray
        Write-Host "  <numbers>   Pick by global number (e.g. '1 4 7' or '1,4,7') and finish" -ForegroundColor DarkGray
        Write-Host "  n / Enter   Next page" -ForegroundColor DarkGray
        Write-Host "  p           Previous page" -ForegroundColor DarkGray
        Write-Host "  c           Cancel (no changes)" -ForegroundColor DarkGray
        Write-Host ""
        $renderedPage = $page
    }
    $reply = Read-Host "Select"
    if (-not $reply -or $reply -eq 'n' -or $reply -eq 'N') {
        if ($page + 1 -lt $totalPages) { $page++ }
        else { Write-Host "Last page reached, looping to first." -ForegroundColor Yellow; $page = 0 }
        continue
    }
    if ($reply -eq 'p' -or $reply -eq 'P') {
        if ($page -gt 0) { $page-- }
        else { Write-Host "Already on first page." -ForegroundColor Yellow }
        continue
    }
    if ($reply -eq 'c' -or $reply -eq 'C') {
        Write-Host "Cancelled. Screens not modified." -ForegroundColor Yellow
        exit 0
    }
    $tokens = $reply -split '[\s,]+' | Where-Object { $_ }
    $picked = @()
    $bad = $false
    foreach ($t in $tokens) {
        if ($t -notmatch '^\d+$') { $bad = $true; break }
        $idx = [int]$t - 1
        if ($idx -lt 0 -or $idx -ge $entries.Count) { $bad = $true; break }
        $picked += $entries[$idx].Url
    }
    if ($bad -or $picked.Count -eq 0) {
        Write-Host "Invalid selection. Use numbers from the list." -ForegroundColor Yellow
        $picked = @()
        continue
    }
    break
}

# Write chosen URLs to screens file
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($ScreensFile, $picked, $utf8NoBom)
Write-Host ""
Write-Host ("Saved {0} screen URL(s) to: {1}" -f $picked.Count, $ScreensFile) -ForegroundColor Green
foreach ($u in $picked) { Write-Host "  $u" }

# Rebuild description
Write-Host ""
Write-Host "Rebuilding torrent description..." -ForegroundColor Cyan
$descArgs = @{ directory = $directory; configfile = $configfile }
if ($tv.IsPresent) { $descArgs['tv'] = $true }
& (Join-Path $PSScriptRoot 'description.ps1') @descArgs
