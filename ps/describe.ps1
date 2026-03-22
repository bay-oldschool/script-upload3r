#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Generates a rich Bulgarian description for media using TMDB, MediaInfo, and Gemini AI.
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
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$directory = $directory.TrimEnd('"').Trim().TrimEnd('\')

if (Test-Path -LiteralPath $directory -PathType Leaf) {
    $singleFile = $directory
    $directory = Split-Path -Parent $directory
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($singleFile)
} else {
    $singleFile = $null
    $baseName = Split-Path -Path $directory -Leaf
}

if (-not $configfile) { $configfile = Join-Path "$PSScriptRoot/.." "config.jsonc" }

$config = (Get-Content -LiteralPath $configfile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json
$TmdbApiKey   = $config.tmdb_api_key
$GeminiApiKey = $config.gemini_api_key
$GeminiModel  = if ($config.gemini_model) { $config.gemini_model } else { "gemini-2.5-flash-lite" }
$OllamaModel  = $config.ollama_model
$OllamaUrl    = if ($config.ollama_url) { $config.ollama_url } else { "http://localhost:11434" }
$AiProviderCfg = $config.ai_provider

if (-not $TmdbApiKey) { Write-Host "Skipping: 'tmdb_api_key' not configured in $configfile" -ForegroundColor Yellow; exit 0 }

# Determine AI provider: ai_provider forces choice, else ollama_model set → Ollama, else gemini_api_key → Gemini
if ($AiProviderCfg -eq "gemini" -and $GeminiApiKey) {
    $AiProvider = "gemini"
    $AiModel = $GeminiModel
} elseif ($AiProviderCfg -eq "ollama" -and $OllamaModel) {
    $AiProvider = "ollama"
    $AiModel = $OllamaModel
} elseif ($OllamaModel) {
    $AiProvider = "ollama"
    $AiModel = $OllamaModel
} elseif ($GeminiApiKey) {
    $AiProvider = "gemini"
    $AiModel = $GeminiModel
} else {
    Write-Host "Skipping: neither 'ollama_model' nor 'gemini_api_key' configured in $configfile" -ForegroundColor Yellow
    exit 0
}

$MediaInfoExe = "$PSScriptRoot/../tools/MediaInfo.exe"
$OutDir = "$PSScriptRoot/../output"
New-Item -Path $OutDir -ItemType Directory -ErrorAction SilentlyContinue

$dirName = $baseName
$OutputFile = Join-Path -Path $OutDir -ChildPath "${dirName}_description.txt"

if ($query) {
    $cleanName = $query
    $yearMatch = [regex]::Match($query, '\b(19|20)\d{2}\b')
    $Year = $(if ($yearMatch.Success) { $yearMatch.Value } else { $null })
} else {
    $yearMatch = [regex]::Match($dirName, '\b(19|20)\d{2}\b')
    $Year = $(if ($yearMatch.Success) { $yearMatch.Value } else { $null })
    $cleanName = $dirName -replace '[._]', ' ' -replace ' - [Ss]\d{2}.*', '' -replace '\b[Ss]\d{2}.*', '' -replace '\b(19|20)\d{2}\b.*', '' -replace ' - WEBDL.*', '' -replace ' - WEB-DL.*', '' -replace '[\s([]+$', ''
}
$mediaType = $(if ($tv.IsPresent) { "tv" } else { "movie" })

# === Step 1: Searching TMDB ===
Write-Host "=== Step 1: Searching TMDB ($mediaType): $cleanName $($Year | ForEach-Object { "($_)" }) ==="
$yearParam = ""
if ($Year) {
    $yearParam = $(if ($mediaType -eq "movie") { "&year=$Year" } else { "&first_air_date_year=$Year" })
}

function Search-Tmdb($q, $yp, $mt) {
    if (-not $mt) { $mt = $mediaType }
    $eq = [uri]::EscapeDataString($q)
    $url = "https://api.themoviedb.org/3/search/$mt`?api_key=$TmdbApiKey&query=$eq$yp"
    try { return Invoke-RestMethod -Uri $url } catch { return @{ total_results = 0 } }
}

$tmdbResponse = Search-Tmdb $cleanName $yearParam

# Fallback 1: retry without year filter (year may be too restrictive)
if ($tmdbResponse.total_results -eq 0 -and $Year -and -not $query) {
    Write-Host "No results for '$cleanName' ($Year), retrying without year filter" -ForegroundColor Yellow
    $fallback = Search-Tmdb $cleanName ""
    if ($fallback.total_results -gt 0) {
        $tmdbResponse = $fallback
        $Year = $null
        $yearParam = ""
    }
}

# Fallback 2: try opposite media type (movie/tv)
if ($tmdbResponse.total_results -eq 0 -and -not $query) {
    $altType = if ($mediaType -eq "movie") { "tv" } else { "movie" }
    Write-Host "No results as '$mediaType', trying as '$altType'" -ForegroundColor Yellow
    $fallback = Search-Tmdb $cleanName "" $altType
    if ($fallback.total_results -gt 0) {
        $tmdbResponse = $fallback
        $mediaType = $altType
    }
}

# Fallback 3: try parent directory name (files only), with same title+year then title-only chain
if ($tmdbResponse.total_results -eq 0 -and -not $query -and $singleFile) {
    $parentDir = Split-Path -Leaf (Split-Path -Parent $singleFile)
    $parentClean = $parentDir -replace '[._]', ' ' -replace ' - [Ss]\d{2}.*', '' -replace '\b[Ss]\d{2}.*', '' -replace '\b(19|20)\d{2}\b.*', '' -replace ' - WEBDL.*', '' -replace ' - WEB-DL.*', '' -replace '[\s([]+$', ''
    $parentYearMatch = [regex]::Match($parentDir, '\b(19|20)\d{2}\b')
    $parentYear = $(if ($parentYearMatch.Success) { $parentYearMatch.Value } else { $null })
    if ($parentClean -and $parentClean -ne $cleanName) {
        $parentYearParam = ""
        if ($parentYear) { $parentYearParam = $(if ($mediaType -eq "movie") { "&year=$parentYear" } else { "&first_air_date_year=$parentYear" }) }
        $yrLabel = $(if ($parentYear) { " ($parentYear)" } else { "" })
        Write-Host "No results for '$cleanName', trying parent dir: '$parentClean'$yrLabel" -ForegroundColor Yellow
        $fallback = Search-Tmdb $parentClean $parentYearParam
        # Retry parent without year
        if ($fallback.total_results -eq 0 -and $parentYear) {
            Write-Host "Retrying parent dir without year filter" -ForegroundColor Yellow
            $fallback = Search-Tmdb $parentClean ""
            $parentYear = $null
        }
        if ($fallback.total_results -gt 0) {
            $tmdbResponse = $fallback
            $cleanName = $parentClean
            $Year = $parentYear
        }
    }
}

if ($tmdbResponse.total_results -eq 0) {
    Write-Host "Warning: No TMDB results found for '$cleanName'. Skipping." -ForegroundColor Yellow
    exit 0
}

# Pick best-matching result by title similarity
$q = ($cleanName -replace '[^a-zA-Z0-9]', '').ToLower()
$item = $tmdbResponse.results[0]
$bestScore = -1
foreach ($candidate in $tmdbResponse.results) {
    if ($null -eq $candidate) { continue }
    $t = if ($mediaType -eq 'movie') { $candidate.title } else { $candidate.name }
    $tn = ($t -replace '[^a-zA-Z0-9]', '').ToLower()
    $d = if ($mediaType -eq 'movie') { $candidate.release_date } else { $candidate.first_air_date }
    $titleScore = if ($tn -eq $q) { 3 } elseif ($tn.StartsWith($q) -or $q.StartsWith($tn)) { 2 } elseif ($tn.Contains($q) -or $q.Contains($tn)) { 1 } else { 0 }
    $yearBonus = if ($Year -and $d -and $d.StartsWith("$Year")) { 1 } else { 0 }
    $score = $titleScore * 2 + $yearBonus
    if ($score -gt $bestScore) { $bestScore = $score; $item = $candidate }
}
$imageBase = "https://image.tmdb.org/t/p"
$tmdbInfo = [PSCustomObject]@{
    Title    = $(if ($mediaType -eq 'movie') { $item.title } else { $item.name })
    Date     = $(if ($mediaType -eq 'movie') { $item.release_date } else { $item.first_air_date })
    ID       = $item.id
    Overview = $item.overview
    Poster   = "$imageBase/w500$($item.poster_path)"
    Banner   = "$imageBase/original$($item.backdrop_path)"
}
Write-Host "Title: $($tmdbInfo.Title)"
Write-Host "Date: $($tmdbInfo.Date)"

# Fetch season-specific metadata for TV shows
$seasonInfo = $null
$SeasonNum = $null
if ($mediaType -eq 'tv') {
    if ($dirName -match '(?i)S(\d{2})') { $SeasonNum = [int]$matches[1] }
}
if ($SeasonNum) {
    Write-Host "Fetching season $SeasonNum metadata..."
    try {
        $seasonUrl = "https://api.themoviedb.org/3/tv/$($item.id)/season/$SeasonNum`?api_key=$TmdbApiKey"
        $seasonData = Invoke-RestMethod -Uri $seasonUrl
        $seasonInfo = [PSCustomObject]@{
            Name     = $seasonData.name
            AirDate  = $seasonData.air_date
            Overview = $seasonData.overview
            Episodes = $(if ($seasonData.episodes) { $seasonData.episodes.Count } else { 0 })
            Poster   = $(if ($seasonData.poster_path) { "$imageBase/w500$($seasonData.poster_path)" } else { $null })
        }
        # Use season poster if available
        if ($seasonInfo.Poster) { $tmdbInfo.Poster = $seasonInfo.Poster }
        # Use season overview if show overview is empty or override with season-specific
        if ($seasonInfo.Overview) {
            Write-Host "Season $SeasonNum overview found"
        }
        Write-Host "Season ${SeasonNum}: $($seasonInfo.Name), $($seasonInfo.Episodes) episodes"
    } catch {
        Write-Host "Warning: Could not fetch season $SeasonNum details" -ForegroundColor Yellow
    }
}
Write-Host ""

# === Step 2: Extracting MediaInfo ===
Write-Host "=== Step 2: Extracting MediaInfo ==="
$mediaInfoText = ""
if (Test-Path -Path $MediaInfoExe) {
    if ($singleFile) {
        $videoFile = Get-Item -LiteralPath $singleFile
    } else {
        $videoExts = @('.mkv', '.mp4', '.avi', '.ts')
        $videoFile = Get-ChildItem -LiteralPath $directory -Recurse -File |
            Where-Object { ($videoExts -contains $_.Extension.ToLower()) -and ($_.FullName -notmatch 'sample|trailer|featurette') } |
            Sort-Object Name |
            Select-Object -First 1
    }

    if ($videoFile) {
        Write-Host "Parsing: $($videoFile.Name)"
        $mediaInfoText = & $MediaInfoExe $videoFile.FullName
    }
}
Write-Host ""

# === Step 3: Generating description with AI ===
Write-Host "=== Step 3: Generating description with $AiProvider ($AiModel) ==="

# Build concise MediaInfo summary
$mediaSummary = ""
if ($mediaInfoText) {
    $miLines = $mediaInfoText -split "`n"
    $miWidth = ($miLines | Where-Object { $_ -match '^\s*Width\s*:' } | Select-Object -First 1) -replace '.*:\s*', ''
    $miHeight = ($miLines | Where-Object { $_ -match '^\s*Height\s*:' } | Select-Object -First 1) -replace '.*:\s*', ''
    $miCodec = ($miLines | Where-Object { $_ -match '^\s*Format/Info\s*:' } | Select-Object -First 1) -replace '.*:\s*', ''
    $miDuration = ($miLines | Where-Object { $_ -match '^\s*Duration\s*:' } | Select-Object -First 1) -replace '.*:\s*', ''
    $miAudio = ($miLines | Where-Object { $_ -match '^\s*Language\s*:' } | ForEach-Object { ($_ -replace '.*:\s*', '').Trim() } | Sort-Object -Unique) -join ', '
    $mediaSummary = "Resolution: ${miWidth}x${miHeight}, Codec: ${miCodec}, Duration: ${miDuration}, Audio: ${miAudio}"
}

$releaseYear = $tmdbInfo.Date -replace '-.*', ''

# Load BG title from TMDB output file if available
$TmdbOutFile = Join-Path -Path $OutDir -ChildPath "${dirName}_tmdb.txt"
$bgTitle = ''
if (Test-Path -LiteralPath $TmdbOutFile) {
    $bgLine = Get-Content -LiteralPath $TmdbOutFile -Encoding UTF8 | Where-Object { $_ -match '^\s+BG Title:' } | Select-Object -First 1
    if ($bgLine) { $bgTitle = ($bgLine -replace '^\s+BG Title:\s*', '').Trim() }
}

# Load cast/credits from IMDB file if available
$ImdbFile = Join-Path -Path $OutDir -ChildPath "${dirName}_imdb.txt"
$imdbCast = ''
$imdbDirectors = ''
$imdbGenres = ''
$imdbRating = ''
$imdbRt = ''
if (Test-Path -LiteralPath $ImdbFile) {
    $imdbLines = Get-Content -LiteralPath $ImdbFile -Encoding UTF8
    $castLine = $imdbLines | Where-Object { $_ -match '^Cast:' } | Select-Object -First 1
    if ($castLine) { $imdbCast = ($castLine -replace '^Cast:\s*', '').Trim() }
    $dirLine = $imdbLines | Where-Object { $_ -match '^Director' } | Select-Object -First 1
    if ($dirLine) { $imdbDirectors = ($dirLine -replace '^Director\(s\):\s*', '').Trim() }
    $genreLine = $imdbLines | Where-Object { $_ -match '^Genres:' } | Select-Object -First 1
    if ($genreLine) { $imdbGenres = ($genreLine -replace '^Genres:\s*', '').Trim() }
    $ratingLine = $imdbLines | Where-Object { $_ -match '^Rating:' } | Select-Object -First 1
    if ($ratingLine) { $imdbRating = ($ratingLine -replace '^Rating:\s*', '').Trim() }
    $rtLine = $imdbLines | Where-Object { $_ -match '^RT Rating:' } | Select-Object -First 1
    if ($rtLine) { $imdbRt = ($rtLine -replace '^RT Rating:\s*', '').Trim() }
}

# Read system prompt from external UTF-8 file (avoids PS5.1 code page corruption)
$systemFile = "$PSScriptRoot/../shared/ai_system_prompt.txt"

# Write user prompt to temp file (plain text data)
$promptFile = [System.IO.Path]::GetTempFileName()
$mediaLine = $(if ($mediaSummary) { "`nTechnical: $mediaSummary" } else { "" })
$bgTitleLine = $(if ($bgTitle) { "`nBG Title: $bgTitle" } else { "" })
$castLine2 = $(if ($imdbCast) { "`nCast: $imdbCast" } else { "" })
$directorLine = $(if ($imdbDirectors) { "`nDirector(s): $imdbDirectors" } else { "" })
$genreLine2 = $(if ($imdbGenres) { "`nGenres: $imdbGenres" } else { "" })
$ratingLine2 = $(if ($imdbRating) { "`nRating: $imdbRating" } else { "" })
$rtLine2 = $(if ($imdbRt) { "`nRotten Tomatoes: $imdbRt" } else { "" })
$seasonLine = ''
if ($seasonInfo) {
    $seasonLine = "`nSeason: $($seasonInfo.Name) ($($seasonInfo.Episodes) episodes, air date: $($seasonInfo.AirDate))"
    if ($seasonInfo.Overview) { $seasonLine += "`nSeason Overview: $($seasonInfo.Overview)" }
}
$promptContent = @"
Title: $($tmdbInfo.Title)
Date: $($tmdbInfo.Date)
ID: $($tmdbInfo.ID)
Overview: $($tmdbInfo.Overview)
Poster: $($tmdbInfo.Poster)
Banner: $($tmdbInfo.Banner)$bgTitleLine
Release Year: $releaseYear
Directory: $dirName$seasonLine$castLine2$directorLine$genreLine2$ratingLine2$rtLine2$mediaLine
"@
[System.IO.File]::WriteAllText($promptFile, $promptContent, $utf8NoBom)

# Call ai_call.ps1
$callArgs = @{
    promptfile = $promptFile
    outputfile = $OutputFile
    provider   = $AiProvider
    model      = $AiModel
    systemfile = $systemFile
}
if ($GeminiApiKey) { $callArgs['apikey'] = $GeminiApiKey }
if ($AiProvider -eq 'ollama') { $callArgs['baseurl'] = $OllamaUrl }

try {
    & "$PSScriptRoot/../shared/ai_call.ps1" @callArgs
} catch {
    Write-Warning "AI description skipped: $($_.Exception.Message)"
}

Remove-Item -Path $promptFile -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Saved to: $OutputFile" -ForegroundColor Green