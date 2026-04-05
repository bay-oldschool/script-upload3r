#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Searches IGDB for game metadata using Twitch OAuth + IGDB API.
.PARAMETER directory
    Path to the content directory or file.
.PARAMETER configfile
    Path to the JSONC config file.
.PARAMETER query
    Override auto-detected game title for IGDB search.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$directory,

    [Parameter(Position = 1)]
    [string]$configfile,

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
$TwitchClientId     = $config.twitch_client_id
$TwitchClientSecret = $config.twitch_client_secret

if (-not $TwitchClientId -or -not $TwitchClientSecret) {
    Write-Host "Skipping: 'twitch_client_id' and 'twitch_client_secret' not configured in $configfile" -ForegroundColor Yellow
    exit 0
}

$OutDir = "$PSScriptRoot/../output"
New-Item -Path $OutDir -ItemType Directory -ErrorAction SilentlyContinue
$OutputFile = Join-Path -Path $OutDir -ChildPath "${baseName}_igdb.txt"

# Clean game title from dirname
if ($query) {
    $cleanQuery = $query
} else {
    $cleanQuery = $baseName
    # Remove bracketed tags like [SKIDROW], (GOG), {PLAZA}
    $cleanQuery = $cleanQuery -replace '\s*[\[\(\{][^\]\)\}]+[\]\)\}]\s*', ' '
    # Remove common scene tags
    $cleanQuery = $cleanQuery -replace '(?i)[-\.](CODEX|PLAZA|GOG|FLT|SKIDROW|RELOADED|RUNE|DARKSiDERS|TiNYiSO|EMPRESS|SiMPLEX|DOGE|Razor1911|HI2U|ANOMALY|P2P|KaOs|FitGirl|DODI)$', ''
    # Remove version tags like v1.2.3
    $cleanQuery = $cleanQuery -replace '(?i)[-\.]v?\d+[\.\d]+\s*$', ''
    # Remove platform tags
    $cleanQuery = $cleanQuery -replace '(?i)[-\.](PC|MAC|Linux|PS[345]?|Xbox|Switch|NSW|GOG|Steam)[-\.]?', ' '
    # Remove edition/extra tags
    $cleanQuery = $cleanQuery -replace '(?i)[-\.](Repack|Portable|Deluxe|Ultimate|Gold|GOTY|Premium|Complete|Edition|Collection|Update|DLC|Incl|MULTi\d*)[-\.]?', ' '
    # Replace dots/underscores with spaces
    $cleanQuery = $cleanQuery -replace '[._]', ' '
    # Remove year from end (games often have year in dirname)
    $cleanQuery = $cleanQuery -replace '\s*(19|20)\d{2}\s*$', ''
    $cleanQuery = ($cleanQuery -replace '\s+', ' ').Trim()
}

Write-Host "Searching IGDB for: '$cleanQuery'" -ForegroundColor Cyan

# Step 1: Get Twitch OAuth token
$tokenResp = & curl.exe -s -X POST "https://id.twitch.tv/oauth2/token?client_id=${TwitchClientId}&client_secret=${TwitchClientSecret}&grant_type=client_credentials"
$tokenData = $tokenResp | ConvertFrom-Json
$AccessToken = $tokenData.access_token

if (-not $AccessToken) {
    Write-Host "Error: failed to get Twitch OAuth token" -ForegroundColor Red
    Write-Host $tokenResp
    exit 1
}

# Step 2: Search IGDB
function Invoke-IGDB([string]$endpoint, [string]$body) {
    $resp = & curl.exe -s -X POST "https://api.igdb.com/v4/${endpoint}" `
        -H "Client-ID: ${TwitchClientId}" `
        -H "Authorization: Bearer ${AccessToken}" `
        -H "Accept: application/json" `
        --data-raw $body
    $json = $resp -join ''
    if (-not $json -or $json -eq '[]') { return ,@() }
    $parsed = ConvertFrom-Json $json
    # Return as proper array (PS5.1 pipeline flattening workaround)
    return ,$parsed
}

$igdbFields = "fields id,name,summary,storyline,rating,aggregated_rating,first_release_date,genres.name,platforms.name,involved_companies.company.name,involved_companies.developer,involved_companies.publisher,cover.url,game_modes.name,themes.name,url; limit 10;"
$searchBody = "search \`"${cleanQuery}\`"; $igdbFields"
$results = Invoke-IGDB "games" $searchBody

if ($results.Count -eq 0) {
    # Try shorter query (first 2-3 words)
    $words = $cleanQuery -split '\s+'
    if ($words.Count -gt 2) {
        $shortQuery = ($words[0..1]) -join ' '
        Write-Host "No results, retrying with: '$shortQuery'" -ForegroundColor Yellow
        $searchBody = "search \`"${shortQuery}\`"; $igdbFields"
        $results = Invoke-IGDB "games" $searchBody
    }
}

if ($results.Count -eq 0) {
    Write-Host "No games found on IGDB." -ForegroundColor Yellow
    exit 0
}

# Sort results: prioritize PC platform, then by rating
$pcNames = @('PC (Microsoft Windows)', 'PC', 'Windows', 'DOS')
$sorted = @($results | Sort-Object -Property @{
    Expression = {
        $hasPc = $false
        if ($_.platforms) { $hasPc = ($_.platforms | ForEach-Object { $_.name } | Where-Object { $pcNames -contains $_ }).Count -gt 0 }
        if ($hasPc) { 0 } else { 1 }
    }
}, @{
    Expression = { if ($_.rating) { $_.rating } else { 0 } }
    Descending = $true
})
$results = $sorted

Write-Host "Found $($results.Count) result(s):" -ForegroundColor Green

$output = @()

for ($i = 0; $i -lt $results.Count; $i++) {
    $g = $results[$i]
    $releaseDate = ''
    if ($g.first_release_date) {
        $releaseDate = ([DateTimeOffset]::FromUnixTimeSeconds($g.first_release_date)).ToString('yyyy-MM-dd')
    }
    $releaseYear = if ($releaseDate.Length -ge 4) { $releaseDate.Substring(0, 4) } else { '' }

    $genres = ''
    if ($g.genres) { $genres = ($g.genres | ForEach-Object { $_.name }) -join ', ' }

    $platforms = ''
    if ($g.platforms) { $platforms = ($g.platforms | ForEach-Object { $_.name }) -join ', ' }

    $developers = @()
    $publishers = @()
    if ($g.involved_companies) {
        foreach ($ic in $g.involved_companies) {
            if ($ic.developer -eq $true -and $ic.company.name) { $developers += $ic.company.name }
            if ($ic.publisher -eq $true -and $ic.company.name) { $publishers += $ic.company.name }
        }
    }

    $gameModes = ''
    if ($g.game_modes) { $gameModes = ($g.game_modes | ForEach-Object { $_.name }) -join ', ' }

    $themes = ''
    if ($g.themes) { $themes = ($g.themes | ForEach-Object { $_.name }) -join ', ' }

    $coverUrl = ''
    if ($g.cover -and $g.cover.url) {
        $coverUrl = $g.cover.url -replace '//images', 'https://images' -replace 't_thumb', 't_cover_big'
    }

    $rating = ''
    if ($g.rating) { $rating = "{0:N1}" -f $g.rating }
    $metaRating = ''
    if ($g.aggregated_rating) { $metaRating = "{0:N1}" -f $g.aggregated_rating }

    $platShort = if ($platforms) { " [$platforms]" } else { "" }
    Write-Host ""
    Write-Host "[$($i+1)] $($g.name) ($releaseYear)${platShort}" -ForegroundColor Cyan

    $block = @()
    $block += "[$($i+1)] $($g.name) ($releaseYear)"
    $block += "    IGDB ID:      $($g.id)"
    if ($g.url) { $block += "    IGDB URL:     $($g.url)" }
    if ($releaseDate) { $block += "    Released:     $releaseDate" }
    if ($genres) { $block += "    Genres:       $genres" }
    if ($platforms) { $block += "    Platforms:    $platforms" }
    if ($gameModes) { $block += "    Game Modes:   $gameModes" }
    if ($themes) { $block += "    Themes:       $themes" }
    if ($developers.Count -gt 0) { $block += "    Developer(s): $($developers -join ', ')" }
    if ($publishers.Count -gt 0) { $block += "    Publisher(s): $($publishers -join ', ')" }
    if ($rating) { $block += "    User Rating:  $rating/100" }
    if ($metaRating) { $block += "    Meta Rating:  $metaRating/100" }
    if ($coverUrl) { $block += "    Cover:        $coverUrl" }
    if ($g.summary) { $block += "    Summary:      $($g.summary)" }

    foreach ($line in $block) { Write-Host $line }
    $output += $block
    $output += ""
}

# Ask user to pick if multiple results
$selectedIdx = 0
if ($results.Count -gt 1) {
    Write-Host ""
    Write-Host "Multiple results found. Enter number to select (default=1): " -ForegroundColor Yellow -NoNewline
    $choice = Read-Host
    if ($choice -match '^\d+$') {
        $pick = [int]$choice
        if ($pick -ge 1 -and $pick -le $results.Count) {
            $selectedIdx = $pick - 1
        }
    }
    Write-Host "Selected: [$($selectedIdx+1)] $($results[$selectedIdx].name)" -ForegroundColor Green
}

# Reorder output so selected result is first
if ($selectedIdx -ne 0) {
    $selectedResult = $results[$selectedIdx]
    $reordered = @($selectedResult) + @($results | Where-Object { $_.id -ne $selectedResult.id })
    $results = $reordered

    # Rebuild output with new ordering
    $output = @()
    for ($i = 0; $i -lt $results.Count; $i++) {
        $g = $results[$i]
        $releaseDate = ''
        if ($g.first_release_date) {
            $releaseDate = ([DateTimeOffset]::FromUnixTimeSeconds($g.first_release_date)).ToString('yyyy-MM-dd')
        }
        $releaseYear = if ($releaseDate.Length -ge 4) { $releaseDate.Substring(0, 4) } else { '' }
        $genres = ''
        if ($g.genres) { $genres = ($g.genres | ForEach-Object { $_.name }) -join ', ' }
        $platforms = ''
        if ($g.platforms) { $platforms = ($g.platforms | ForEach-Object { $_.name }) -join ', ' }
        $developers = @()
        $publishers = @()
        if ($g.involved_companies) {
            foreach ($ic in $g.involved_companies) {
                if ($ic.developer -eq $true -and $ic.company.name) { $developers += $ic.company.name }
                if ($ic.publisher -eq $true -and $ic.company.name) { $publishers += $ic.company.name }
            }
        }
        $gameModes = ''
        if ($g.game_modes) { $gameModes = ($g.game_modes | ForEach-Object { $_.name }) -join ', ' }
        $themes = ''
        if ($g.themes) { $themes = ($g.themes | ForEach-Object { $_.name }) -join ', ' }
        $coverUrl = ''
        if ($g.cover -and $g.cover.url) {
            $coverUrl = $g.cover.url -replace '//images', 'https://images' -replace 't_thumb', 't_cover_big'
        }
        $rating = ''
        if ($g.rating) { $rating = "{0:N1}" -f $g.rating }
        $metaRating = ''
        if ($g.aggregated_rating) { $metaRating = "{0:N1}" -f $g.aggregated_rating }

        $block = @()
        $block += "[$($i+1)] $($g.name) ($releaseYear)"
        $block += "    IGDB ID:      $($g.id)"
        if ($g.url) { $block += "    IGDB URL:     $($g.url)" }
        if ($releaseDate) { $block += "    Released:     $releaseDate" }
        if ($genres) { $block += "    Genres:       $genres" }
        if ($platforms) { $block += "    Platforms:    $platforms" }
        if ($gameModes) { $block += "    Game Modes:   $gameModes" }
        if ($themes) { $block += "    Themes:       $themes" }
        if ($developers.Count -gt 0) { $block += "    Developer(s): $($developers -join ', ')" }
        if ($publishers.Count -gt 0) { $block += "    Publisher(s): $($publishers -join ', ')" }
        if ($rating) { $block += "    User Rating:  $rating/100" }
        if ($metaRating) { $block += "    Meta Rating:  $metaRating/100" }
        if ($coverUrl) { $block += "    Cover:        $coverUrl" }
        if ($g.summary) { $block += "    Summary:      $($g.summary)" }
        $output += $block
        $output += ""
    }
}

# Save to file
[System.IO.File]::WriteAllText($OutputFile, ($output -join "`n") + "`n", $utf8NoBom)
Write-Host ""
Write-Host "IGDB results saved to: $OutputFile" -ForegroundColor Green

# Fetch screenshots/artworks for the selected result
$bestId = $results[0].id
$artworks = Invoke-IGDB "artworks" "fields url; where game = ${bestId}; limit 5;"
$screenshots = Invoke-IGDB "screenshots" "fields url; where game = ${bestId}; limit 5;"
$videos = Invoke-IGDB "game_videos" "fields name,video_id; where game = ${bestId}; limit 5;"

$mediaBlock = @()
if ($artworks.Count -gt 0 -or $screenshots.Count -gt 0 -or $videos.Count -gt 0) {
    $mediaBlock += "--- Media for: $($results[0].name) ---"
    foreach ($a in $artworks) {
        if ($a.url) {
            $url = $a.url -replace '//images', 'https://images' -replace 't_thumb', 't_screenshot_big'
            $mediaBlock += "    Artwork:      $url"
        }
    }
    foreach ($s in $screenshots) {
        if ($s.url) {
            $url = $s.url -replace '//images', 'https://images' -replace 't_thumb', 't_screenshot_big'
            $mediaBlock += "    Screenshot:   $url"
        }
    }
    foreach ($v in $videos) {
        if ($v.video_id) {
            $vName = if ($v.name) { $v.name } else { "Trailer" }
            $mediaBlock += "    Trailer:      $vName`: https://www.youtube.com/watch?v=$($v.video_id)"
        }
    }
    foreach ($line in $mediaBlock) { Write-Host $line }
    $existing = [System.IO.File]::ReadAllText($OutputFile, $utf8NoBom)
    [System.IO.File]::WriteAllText($OutputFile, $existing + ($mediaBlock -join "`n") + "`n", $utf8NoBom)
}
