#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Searches TMDB and optionally translates the description.
.PARAMETER directory
    Path to the content directory.
.PARAMETER configfile
    Path to the JSON config file.
.PARAMETER tv
    Switch to search for TV shows.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$directory,

    [Parameter(Position = 1)]
    [string]$configfile,

    [switch]$tv,

    [string]$query
)

$ErrorActionPreference = 'Stop'
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$directory = $directory.TrimEnd('"').Trim().TrimEnd('\')
if (-not $configfile) { $configfile = Join-Path "$PSScriptRoot/.." "config.jsonc" }

if (Test-Path -LiteralPath $directory -PathType Leaf) {
    $singleFile = $directory
    $directory = Split-Path -Parent $directory
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($singleFile)
} else {
    $singleFile = $null
    $baseName = Split-Path -Path $directory -Leaf
}

$config = (Get-Content -LiteralPath $configfile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json
$TmdbApiKey = $config.tmdb_api_key
$GoogleApiKey = $config.google_api_key
$TranslateLang = $config.translate_lang

if (-not $TmdbApiKey) {
    Write-Host "Skipping: 'tmdb_api_key' not configured in $configfile" -ForegroundColor Yellow
    exit 0
}

$OutDir = "$PSScriptRoot/../output"
New-Item -Path $OutDir -ItemType Directory -ErrorAction SilentlyContinue
$OutputFile = Join-Path -Path $OutDir -ChildPath "${baseName}_tmdb.txt"

if ($query) {
    $cleanQuery = $query
    $yearMatch = [regex]::Match($query, '\b(19|20)\d{2}\b')
    $Year = $(if ($yearMatch.Success) { $yearMatch.Value } else { $null })
} else {
    $yearMatch = [regex]::Match($baseName, '\b(19|20)\d{2}\b')
    $Year = $(if ($yearMatch.Success) { $yearMatch.Value } else { $null })
    $cleanQuery = $baseName -replace '[._]', ' ' -replace ' - [Ss]\d{2}.*', '' -replace '\b[Ss]\d{2}.*', '' -replace '\b(19|20)\d{2}\b.*', '' -replace ' - WEBDL.*', '' -replace ' - WEB-DL.*', '' -replace '[\s([]+$', ''
}

$mediaType = $(if ($tv.IsPresent) { "tv" } else { "movie" })
$yearParam = ""
if ($Year) {
    $yearParam = $(if ($mediaType -eq "movie") { "&year=$Year" } else { "&first_air_date_year=$Year" })
    Write-Host "Searching TMDB ($mediaType): $cleanQuery ($Year)"
}
else {
    Write-Host "Searching TMDB ($mediaType): $cleanQuery"
}

function Search-Tmdb($q, $yp, $mt) {
    if (-not $mt) { $mt = $mediaType }
    $eq = [uri]::EscapeDataString($q)
    $url = "https://api.themoviedb.org/3/search/$mt`?api_key=$TmdbApiKey&query=$eq$yp"
    try { return Invoke-RestMethod -Uri $url } catch { return @{ total_results = 0 } }
}

$response = Search-Tmdb $cleanQuery $yearParam

# Fallback 1: retry without year filter (year may be too restrictive)
if ($response.total_results -eq 0 -and $Year -and -not $query) {
    Write-Host "No results for '$cleanQuery' ($Year), retrying without year filter" -ForegroundColor Yellow
    $fallback = Search-Tmdb $cleanQuery ""
    if ($fallback.total_results -gt 0) {
        $response = $fallback
        $Year = $null
        $yearParam = ""
    }
}

# Fallback 2: try opposite media type (movie/tv)
if ($response.total_results -eq 0 -and -not $query) {
    $altType = if ($mediaType -eq "movie") { "tv" } else { "movie" }
    Write-Host "No results as '$mediaType', trying as '$altType'" -ForegroundColor Yellow
    $fallback = Search-Tmdb $cleanQuery "" $altType
    if ($fallback.total_results -gt 0) {
        $response = $fallback
        $mediaType = $altType
    }
}

# Fallback 3: try parent directory name (files only), with same title+year then title-only chain
if ($response.total_results -eq 0 -and -not $query -and $singleFile) {
    $parentDir = Split-Path -Leaf (Split-Path -Parent $singleFile)
    $parentClean = $parentDir -replace '[._]', ' ' -replace ' - [Ss]\d{2}.*', '' -replace '\b[Ss]\d{2}.*', '' -replace '\b(19|20)\d{2}\b.*', '' -replace ' - WEBDL.*', '' -replace ' - WEB-DL.*', '' -replace '[\s([]+$', ''
    $parentYearMatch = [regex]::Match($parentDir, '\b(19|20)\d{2}\b')
    $parentYear = $(if ($parentYearMatch.Success) { $parentYearMatch.Value } else { $null })
    if ($parentClean -and $parentClean -ne $cleanQuery) {
        $parentYearParam = ""
        if ($parentYear) { $parentYearParam = $(if ($mediaType -eq "movie") { "&year=$parentYear" } else { "&first_air_date_year=$parentYear" }) }
        $yrLabel = $(if ($parentYear) { " ($parentYear)" } else { "" })
        Write-Host "No results for '$cleanQuery', trying parent dir: '$parentClean'$yrLabel" -ForegroundColor Yellow
        $fallback = Search-Tmdb $parentClean $parentYearParam
        # Retry parent without year
        if ($fallback.total_results -eq 0 -and $parentYear) {
            Write-Host "Retrying parent dir without year filter" -ForegroundColor Yellow
            $fallback = Search-Tmdb $parentClean ""
            $parentYear = $null
        }
        if ($fallback.total_results -gt 0) {
            $response = $fallback
            $cleanQuery = $parentClean
            $Year = $parentYear
        }
    }
}

if ($response.total_results -eq 0) {
    Write-Host "Warning: No TMDB results found. Skipping." -ForegroundColor Yellow
    exit 0
}

$imageBase = "https://image.tmdb.org/t/p"
$outputLines = [System.Collections.Generic.List[string]]::new()

$i = 0
foreach ($item in $response.results[0..4]) {
    $i++
    $title = $(if ($mediaType -eq 'movie') { $item.title } else { $item.name })
    $date = $(if ($mediaType -eq 'movie') { $item.release_date } else { $item.first_air_date })
    $itemYear = $(if ($date) { $date.Substring(0, 4) } else { '????' })

    $outputLines.Add("[$i] $title ($itemYear)")
    $outputLines.Add("    TMDB ID:      $($item.id)")
    $outputLines.Add("    Description:  $($item.overview)")

    # Try TMDB native translation first, fall back to Google Translate
    if ($TranslateLang -and $item.overview) {
        $translated = $null
        try {
            $bgItem = Invoke-RestMethod -Uri "https://api.themoviedb.org/3/$mediaType/$($item.id)?api_key=$TmdbApiKey&language=$TranslateLang"
            $bgOverview = $bgItem.overview
            if ($bgOverview -and $bgOverview -ne $item.overview) {
                $translated = $bgOverview
            }
        } catch {}

        if (-not $translated -and $GoogleApiKey) {
            try {
                $transUrl = "https://translation.googleapis.com/language/translate/v2?key=$GoogleApiKey"
                $transBody = @{ q = $item.overview; target = $TranslateLang; source = 'en' } | ConvertTo-Json
                $transResp = Invoke-RestMethod -Uri $transUrl -Method POST -ContentType 'application/json' -Body $transBody
                $translated = $transResp.data.translations[0].translatedText
            } catch {}
        }

        if ($translated) {
            $outputLines.Add("    ($TranslateLang):  $translated")
        }
    }

    $poster = $(if ($item.poster_path) { "$imageBase/w500$($item.poster_path)" } else { '(none)' })
    $banner = $(if ($item.backdrop_path) { "$imageBase/original$($item.backdrop_path)" } else { '(none)' })
    $outputLines.Add("    Poster:       $poster")
    $outputLines.Add("    Banner:       $banner")
    $outputLines.Add("")
}

# Find best-match result and fetch BG title
$q = ($cleanQuery -replace '[^a-zA-Z0-9]', '').ToLower()
$bestItem = $response.results[0]
$bestScore = -1
foreach ($candidate in $response.results) {
    if ($null -eq $candidate) { continue }
    $t = if ($mediaType -eq 'movie') { $candidate.title } else { $candidate.name }
    $tn = ($t -replace '[^a-zA-Z0-9]', '').ToLower()
    $d = if ($mediaType -eq 'movie') { $candidate.release_date } else { $candidate.first_air_date }
    $titleScore = if ($tn -eq $q) { 3 } elseif ($tn.StartsWith($q) -or $q.StartsWith($tn)) { 2 } elseif ($tn.Contains($q) -or $q.Contains($tn)) { 1 } else { 0 }
    $yearBonus = if ($Year -and $d -and $d.StartsWith("$Year")) { 1 } else { 0 }
    $score = $titleScore * 2 + $yearBonus
    if ($score -gt $bestScore) { $bestScore = $score; $bestItem = $candidate }
}
$enTitle = if ($mediaType -eq 'movie') { $bestItem.title } else { $bestItem.name }
try {
    $bgResp = Invoke-RestMethod -Uri "https://api.themoviedb.org/3/$mediaType/$($bestItem.id)?api_key=$TmdbApiKey&language=bg"
    $bgTitle = if ($mediaType -eq 'movie') { $bgResp.title } else { $bgResp.name }
    if ($bgTitle -and $bgTitle -ne $enTitle) {
        Write-Host "BG Title: $bgTitle"
        $foundId = $false
        for ($i = 0; $i -lt $outputLines.Count; $i++) {
            if ($outputLines[$i] -match '^\s+TMDB ID:\s+(\d+)' -and $matches[1] -eq "$($bestItem.id)") {
                $foundId = $true
            }
            if ($foundId -and $outputLines[$i] -match '^\s+Banner:') {
                $outputLines.Insert($i + 1, "    BG Title:     $bgTitle")
                break
            }
        }
    }
} catch { }

# Fetch season-specific metadata for TV shows
$SeasonNum = $null
if ($mediaType -eq 'tv') {
    if ($baseName -match '(?i)S(\d{2})') { $SeasonNum = [int]$matches[1] }
}
if ($SeasonNum) {
    Write-Host "Fetching season $SeasonNum metadata for TV show ID $($bestItem.id)"
    try {
        $seasonUrl = "https://api.themoviedb.org/3/tv/$($bestItem.id)/season/$SeasonNum`?api_key=$TmdbApiKey"
        $seasonData = Invoke-RestMethod -Uri $seasonUrl
        $outputLines.Add("--- Season $SeasonNum ---")
        if ($seasonData.name) { $outputLines.Add("    Season Name:  $($seasonData.name)") }
        if ($seasonData.air_date) { $outputLines.Add("    Air Date:     $($seasonData.air_date)") }
        if ($seasonData.overview) { $outputLines.Add("    Overview:     $($seasonData.overview)") }
        $epCount = if ($seasonData.episodes) { $seasonData.episodes.Count } else { 0 }
        if ($epCount -gt 0) { $outputLines.Add("    Episodes:     $epCount") }
        $sPoster = if ($seasonData.poster_path) { "$imageBase/w500$($seasonData.poster_path)" } else { '(none)' }
        $outputLines.Add("    Poster:       $sPoster")

        # Season-specific BG translation
        if ($TranslateLang) {
            try {
                $seasonBgUrl = "https://api.themoviedb.org/3/tv/$($bestItem.id)/season/$SeasonNum`?api_key=$TmdbApiKey&language=$TranslateLang"
                $seasonBg = Invoke-RestMethod -Uri $seasonBgUrl
                if ($seasonBg.overview -and $seasonBg.overview -ne $seasonData.overview) {
                    $outputLines.Add("    ($TranslateLang):  $($seasonBg.overview)")
                } elseif ($seasonData.overview -and $GoogleApiKey) {
                    try {
                        $transUrl = "https://translation.googleapis.com/language/translate/v2?key=$GoogleApiKey"
                        $transBody = @{ q = $seasonData.overview; target = $TranslateLang; source = 'en' } | ConvertTo-Json
                        $transResp = Invoke-RestMethod -Uri $transUrl -Method POST -ContentType 'application/json' -Body $transBody
                        $translated = $transResp.data.translations[0].translatedText
                        if ($translated) { $outputLines.Add("    ($TranslateLang):  $translated") }
                    } catch {}
                }
            } catch {}
        }
        $outputLines.Add("")
        Write-Host "Season ${SeasonNum}: $($seasonData.name), $epCount episodes"
    } catch {
        Write-Host "Warning: Could not fetch season $SeasonNum details ($($_.Exception.Message))" -ForegroundColor Yellow
    }
}

$outputLines | Out-File -LiteralPath $OutputFile -Encoding utf8
$outputLines | Write-Host

Write-Host "Saved to: $OutputFile" -ForegroundColor Green