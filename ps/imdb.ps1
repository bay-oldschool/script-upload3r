#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Gets detailed IMDB info (rating, cast, etc.) via the TMDB API.
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
$directory = $directory.TrimEnd('"').TrimEnd('\')
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
if (-not $TmdbApiKey) {
    Write-Host "Skipping: 'tmdb_api_key' not configured in $configfile" -ForegroundColor Yellow
    exit 0
}
$OmdbApiKey = $config.omdb_api_key

$OutDir = "$PSScriptRoot/../output"
New-Item -Path $OutDir -ItemType Directory -ErrorAction SilentlyContinue
$OutputFile = Join-Path -Path $OutDir -ChildPath "${baseName}_imdb.txt"

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
    Write-Host "Searching ($mediaType): $cleanQuery ($Year)"
}
else {
    Write-Host "Searching ($mediaType): $cleanQuery"
}

function Search-Tmdb($q, $yp, $mt) {
    if (-not $mt) { $mt = $mediaType }
    $eq = [uri]::EscapeDataString($q)
    $url = "https://api.themoviedb.org/3/search/$mt`?api_key=$TmdbApiKey&query=$eq$yp"
    try { return Invoke-RestMethod -Uri $url } catch { return @{ total_results = 0 } }
}

$searchResponse = Search-Tmdb $cleanQuery $yearParam

# Fallback 1: retry without year filter (year may be too restrictive)
if ($searchResponse.total_results -eq 0 -and $Year -and -not $query) {
    Write-Host "No results for '$cleanQuery' ($Year), retrying without year filter" -ForegroundColor Yellow
    $fallback = Search-Tmdb $cleanQuery ""
    if ($fallback.total_results -gt 0) {
        $searchResponse = $fallback
        $Year = $null
        $yearParam = ""
    }
}

# Fallback 2: try opposite media type (movie/tv)
if ($searchResponse.total_results -eq 0 -and -not $query) {
    $altType = if ($mediaType -eq "movie") { "tv" } else { "movie" }
    Write-Host "No results as '$mediaType', trying as '$altType'" -ForegroundColor Yellow
    $fallback = Search-Tmdb $cleanQuery "" $altType
    if ($fallback.total_results -gt 0) {
        $searchResponse = $fallback
        $mediaType = $altType
    }
}

# Fallback 3: try parent directory name (files only), with same title+year then title-only chain
if ($searchResponse.total_results -eq 0 -and -not $query -and $singleFile) {
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
            $searchResponse = $fallback
            $cleanQuery = $parentClean
            $Year = $parentYear
        }
    }
}

if ($searchResponse.total_results -eq 0) {
    Write-Host "Warning: No TMDB results found. Skipping." -ForegroundColor Yellow
    exit 0
}

# Pick best-matching result by title similarity
$q = ($cleanQuery -replace '[^a-zA-Z0-9]', '').ToLower()
$bestResult = $searchResponse.results[0]
$bestScore = -1
foreach ($candidate in $searchResponse.results) {
    if ($null -eq $candidate) { continue }
    $t = if ($mediaType -eq 'movie') { $candidate.title } else { $candidate.name }
    $tn = ($t -replace '[^a-zA-Z0-9]', '').ToLower()
    $d = if ($mediaType -eq 'movie') { $candidate.release_date } else { $candidate.first_air_date }
    $titleScore = if ($tn -eq $q) { 3 } elseif ($tn.StartsWith($q) -or $q.StartsWith($tn)) { 2 } elseif ($tn.Contains($q) -or $q.Contains($tn)) { 1 } else { 0 }
    $yearBonus = if ($Year -and $d -and $d.StartsWith("$Year")) { 1 } else { 0 }
    $score = $titleScore * 2 + $yearBonus
    if ($score -gt $bestScore) { $bestScore = $score; $bestResult = $candidate }
}
$tmdbId = $bestResult.id

$detailsUrl = "https://api.themoviedb.org/3/$mediaType/$tmdbId`?api_key=$TmdbApiKey"
$creditsUrl = "https://api.themoviedb.org/3/$mediaType/$tmdbId/credits`?api_key=$TmdbApiKey"

try {
    $details = Invoke-RestMethod -Uri $detailsUrl
    $credits = Invoke-RestMethod -Uri $creditsUrl
} catch {
    Write-Host "Warning: TMDB details fetch failed ($($_.Exception.Message)). Skipping." -ForegroundColor Yellow
    exit 0
}

if ($mediaType -eq 'movie') {
    $title = $details.title
    $date = $details.release_date
    $imdbId = $details.imdb_id
    $runtime = "$($details.runtime) min"
}
else { # TV
    $title = $details.name
    $date = $details.first_air_date
    try {
        $extUrl = "https://api.themoviedb.org/3/tv/$tmdbId/external_ids`?api_key=$TmdbApiKey"
        $ext = Invoke-RestMethod -Uri $extUrl
        $imdbId = $ext.imdb_id
    } catch {
        Write-Host "Warning: external IDs fetch failed, IMDB ID may be missing." -ForegroundColor Yellow
        $imdbId = ''
    }
    $runtime = "$($details.number_of_seasons) season(s), $($details.number_of_episodes) episode(s)"
}

$itemYear = $(if ($date) { $date.Substring(0, 4) } else { '????' })
$rating = [math]::Round($details.vote_average, 1)
$genres = ($details.genres.name) -join ', '
$directors = ($credits.crew | Where-Object { $_.job -eq 'Director' }).name -join ', '
if (-not $directors) { $directors = '(n/a)' }
$cast = ($credits.cast[0..4] | ForEach-Object { "$($_.name) ($($_.character))" }) -join ', '
$imdbUrl = $(if ($imdbId) { "https://www.imdb.com/title/$imdbId/" } else { '(not available)' })

# Fetch Rotten Tomatoes rating via OMDB
$rtRating = ''
if ($OmdbApiKey -and $imdbId) {
    try {
        $omdb = Invoke-RestMethod -Uri "http://www.omdbapi.com/?i=$imdbId&apikey=$OmdbApiKey"
        if ($omdb.Ratings) {
            $rt = $omdb.Ratings | Where-Object { $_.Source -eq 'Rotten Tomatoes' }
            if ($rt) { $rtRating = $rt.Value }
        }
    } catch { }
}

$lines = @(
    "=== $title ($itemYear) ===",
    "",
    "IMDB ID:      $imdbId",
    "IMDB URL:     $imdbUrl",
    "TMDB ID:      $($details.id)",
    "Rating:       $rating/10 ($($details.vote_count) votes)"
)
if ($rtRating) { $lines += "RT Rating:    $rtRating" }
$lines += @(
    "Genres:       $genres",
    "Runtime:      $runtime",
    "Status:       $($details.status)"
)
if ($details.tagline) { $lines += "Tagline:      $($details.tagline)" }
$lines += @(
    "",
    "Director(s):  $directors",
    "Cast:         $cast",
    "",
    "Overview:",
    $details.overview,
    ""
)

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($OutputFile, $lines, $utf8NoBom)
$lines | Write-Host

Write-Host "Saved to: $OutputFile" -ForegroundColor Green