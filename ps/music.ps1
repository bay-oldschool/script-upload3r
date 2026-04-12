#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Searches Deezer (primary) and MusicBrainz (fallback) for music metadata.
.PARAMETER directory
    Path to the content directory or file.
.PARAMETER configfile
    Path to the JSONC config file.
.PARAMETER query
    Override auto-detected album title for search.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$directory,

    [Parameter(Position = 1)]
    [string]$configfile,

    [string]$query
)

$ErrorActionPreference = 'Stop'
# PS5.1 defaults to TLS 1.0; modern APIs require TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
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
$DiscogsToken = $config.discogs_token
$LastfmApiKey = $config.lastfm_api_key
$AudioDbApiKey = if ($config.audiodb_api_key) { $config.audiodb_api_key } else { '523532' }
$MusicProviders = if ($config.music_providers) { @($config.music_providers -split '\s*,\s*' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }) } else { @('deezer','musicbrainz','discogs') }

$OutDir = "$PSScriptRoot/../output"
New-Item -Path $OutDir -ItemType Directory -ErrorAction SilentlyContinue
$OutputFile = Join-Path -Path $OutDir -ChildPath "${baseName}_music.txt"

# ─── Clean music title from dirname ────────────────────────────────────────
if ($query) {
    $cleanQuery = $query
} else {
    $cleanQuery = $baseName
    # Remove square-bracket tags like [FLAC 24-48], [WEB] — keep parentheses (part of title)
    $cleanQuery = $cleanQuery -replace '\s*\[[^\]]+\]\s*', ' '
    # Remove curly-brace tags like {2024}
    $cleanQuery = $cleanQuery -replace '\s*\{[^}]+\}\s*', ' '
    # Replace dots/underscores with spaces
    $cleanQuery = $cleanQuery -replace '[._]', ' '
    # Remove common music format/quality tags (standalone words)
    $cleanQuery = $cleanQuery -replace '(?i)\b(FLAC|MP3|AAC|OGG|OPUS|WEB|CD|VINYL|LP|Lossless|320|V0|V2|CBR|VBR|16bit|24bit|16-44|24-48|24-96|24-192|44\.1kHz|48kHz|96kHz|192kHz|Hi-?Res|320kbps|256kbps|192kbps|128kbps)\b', ' '
    # Remove scene group tags at end
    $cleanQuery = $cleanQuery -replace '(?i)\s*[-](PERFECT|FATHEAD|ENRiCH|YARD|WRE|dL|AMRAP|JLM|D2H|FiH|NBFLAC|DGN|TOSK|ERP)\s*$', ''
    # Remove year from end (4-digit year after the album name)
    $cleanQuery = $cleanQuery -replace '\s+(19|20)\d{2}\s*$', ''
    $cleanQuery = ($cleanQuery -replace '\s+', ' ').Trim()
}

# Split "Artist - Album" if present (handle hyphen, en-dash, em-dash)
$searchArtist = ''
$searchAlbum = $cleanQuery
$dashChars = '-' + [char]0x2013 + [char]0x2014
if ($cleanQuery -match "^(.+?)\s+[$dashChars]\s+(.+)$") {
    $searchArtist = $matches[1].Trim()
    $searchAlbum = $matches[2].Trim()
}
# Expand common abbreviations
if ($searchArtist -eq 'VA') { $searchArtist = 'Various Artists' }

# ─── Deezer API (primary) ──────────────────────────────────────────────────

function Invoke-Deezer([string]$url) {
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [System.Text.Encoding]::UTF8
        $json = $wc.DownloadString($url)
        $wc.Dispose()
        if (-not $json -or $json -eq '{}') { return $null }
        return ConvertFrom-Json $json
    } catch {
        Write-Host "Deezer request failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Test-DeezerResults($searchData) {
    if (-not $searchData) { return $false }
    if (-not $searchData.data) { return $false }
    if ($searchData.total -and $searchData.total -gt 0) { return $true }
    try { if ($searchData.data.Count -gt 0) { return $true } } catch {}
    return $false
}

function Search-Deezer {
    # Sanitize query parts: remove straight/curly single quotes that can break URL encoding
    $quoteChars = "'" + [char]0x2018 + [char]0x2019
    $safeArtist = $searchArtist -replace "[$quoteChars]", ''
    $safeAlbum = $searchAlbum -replace "[$quoteChars]", ''
    # Short album: strip parenthesized subtitle
    $shortAlbum = $safeAlbum -replace '\s*\([^)]+\)\s*', ''
    $shortAlbum = ($shortAlbum -replace '\s+', ' ').Trim()

    $searchData = $null

    # Strategy 1: artist + short album (most reliable — no special chars in parens)
    if ($safeArtist -and $shortAlbum) {
        $deezerQuery = "artist:`"$safeArtist`" album:`"$shortAlbum`""
        $encoded = [Uri]::EscapeDataString($deezerQuery)
        Write-Host "Searching Deezer: artist='$safeArtist' album='$shortAlbum'" -ForegroundColor Cyan
        $searchData = Invoke-Deezer "https://api.deezer.com/search/album?q=${encoded}&limit=10"
    }

    # Strategy 2: artist + full album name
    if (-not (Test-DeezerResults $searchData) -and $safeArtist -and $safeAlbum -ne $shortAlbum) {
        $deezerQuery = "artist:`"$safeArtist`" album:`"$safeAlbum`""
        $encoded = [Uri]::EscapeDataString($deezerQuery)
        Write-Host "Retrying Deezer: artist='$safeArtist' album='$safeAlbum'" -ForegroundColor Yellow
        $searchData = Invoke-Deezer "https://api.deezer.com/search/album?q=${encoded}&limit=10"
    }

    # Strategy 3: plain text search
    if (-not (Test-DeezerResults $searchData)) {
        $safeQuery = $cleanQuery -replace "[$quoteChars]", ''
        $encoded = [Uri]::EscapeDataString($safeQuery)
        Write-Host "Retrying Deezer: '$safeQuery'" -ForegroundColor Yellow
        $searchData = Invoke-Deezer "https://api.deezer.com/search/album?q=${encoded}&limit=10"
    }

    # Strategy 4: just artist name (skip for generic artists like "Various Artists")
    if (-not (Test-DeezerResults $searchData) -and $safeArtist -and $safeArtist -ne 'Various Artists') {
        $encoded = [Uri]::EscapeDataString($safeArtist)
        Write-Host "Retrying Deezer with artist only: '$safeArtist'" -ForegroundColor Yellow
        $searchData = Invoke-Deezer "https://api.deezer.com/search/album?q=${encoded}&limit=10"
    }

    if (-not (Test-DeezerResults $searchData)) {
        return $null
    }
    return $searchData.data
}

function Format-DeezerResults($results) {
    $output = @()
    for ($i = 0; $i -lt $results.Count; $i++) {
        $a = $results[$i]
        $title = $a.title
        $artist = if ($a.artist -and $a.artist.name) { $a.artist.name } else { '' }
        $releaseDate = if ($a.release_date) { $a.release_date } else { '' }
        $releaseYear = if ($releaseDate.Length -ge 4) { $releaseDate.Substring(0, 4) } else { '' }
        $genre = ''
        if ($a.genre_id -and $a.genre_id -ne 0) {
            # Genre name will be fetched with album details
        }
        $coverUrl = ''
        if ($a.cover_xl) { $coverUrl = $a.cover_xl }
        elseif ($a.cover_big) { $coverUrl = $a.cover_big }
        elseif ($a.cover_medium) { $coverUrl = $a.cover_medium }
        $nbTracks = if ($a.nb_tracks) { $a.nb_tracks } else { '' }
        $albumType = if ($a.record_type) { $a.record_type } else { '' }

        $yearDisplay = if ($releaseYear) { " ($releaseYear)" } else { "" }
        Write-Host ""
        $block = @()
        $block += "[$($i+1)] $artist - $title${yearDisplay}"
        $block += "    Deezer ID:    $($a.id)"
        $block += "    Deezer URL:   $($a.link)"
        if ($artist) { $block += "    Artist:       $artist" }
        if ($releaseDate) { $block += "    Released:     $releaseDate" }
        if ($albumType) { $block += "    Type:         $albumType" }
        if ($nbTracks) { $block += "    Tracks:       $nbTracks" }
        if ($coverUrl) { $block += "    Cover:        $coverUrl" }

        for ($li = 0; $li -lt $block.Count; $li++) { if ($li -eq 0) { Write-Host $block[$li] -ForegroundColor Cyan } else { Write-Host $block[$li] } }
        $output += $block
        $output += ""
    }
    return $output
}

function Get-DeezerDetails($albumId, $albumTitle, $albumArtist) {
    Write-Host ""
    Write-Host "Fetching album details from Deezer..." -ForegroundColor Cyan

    $albumData = Invoke-Deezer "https://api.deezer.com/album/${albumId}"
    $mediaBlock = @()
    if ($albumData) {
        $mediaBlock += "--- Details for: $albumTitle ---"

        # Release date
        if ($albumData.release_date) {
            $mediaBlock += "    Released:     $($albumData.release_date)"
        }

        # Label
        if ($albumData.label) {
            $mediaBlock += "    Label:        $($albumData.label)"
        }

        # Genres
        if ($albumData.genres -and $albumData.genres.data) {
            $genreNames = @($albumData.genres.data | ForEach-Object { $_.name })
            if ($genreNames.Count -gt 0) {
                $mediaBlock += "    Genres:       $($genreNames -join ', ')"
            }
        }

        # Duration
        if ($albumData.duration) {
            $totalMin = [math]::Floor($albumData.duration / 60)
            $totalSec = $albumData.duration % 60
            $mediaBlock += "    Duration:     ${totalMin}:$("{0:D2}" -f $totalSec)"
        }

        # Explicit
        if ($albumData.explicit_lyrics) {
            $mediaBlock += "    Explicit:     Yes"
        }

        # Contributors / Featured artists
        if ($albumData.contributors -and $albumData.contributors.Count -gt 1) {
            $contribs = @($albumData.contributors | ForEach-Object { $_.name }) | Select-Object -Unique
            if ($contribs.Count -gt 1) {
                $mediaBlock += "    Artists:      $($contribs -join ', ')"
            }
        }

        # Track listing
        if ($albumData.tracks -and $albumData.tracks.data) {
            $trackNum = 0
            foreach ($t in $albumData.tracks.data) {
                $trackNum++
                $tTitle = $t.title
                $tArtist = ''
                if ($t.artist -and $t.artist.name) {
                    $tArtist = "$($t.artist.name) - "
                }
                $tLength = ''
                if ($t.duration) {
                    $min = [int][math]::Floor($t.duration / 60)
                    $sec = [int]($t.duration % 60)
                    $tLength = " ({0}:{1:D2})" -f $min, $sec
                }
                $mediaBlock += "    Track:        $trackNum. ${tArtist}$tTitle$tLength"
            }
            $mediaBlock += "    Total Tracks: $trackNum"
        }

        # Cover (prefer XL from details)
        if ($albumData.cover_xl) {
            $mediaBlock += "    Cover:        $($albumData.cover_xl)"
        }
    }
    return $mediaBlock
}

# ─── MusicBrainz API (fallback) ────────────────────────────────────────────

$MbUserAgent = "ScriptUpload3r/5.0 ( https://github.com/script-upload3r )"

function Invoke-MusicBrainz([string]$url) {
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [System.Text.Encoding]::UTF8
        $wc.Headers.Add('User-Agent', $MbUserAgent)
        $wc.Headers.Add('Accept', 'application/json')
        $json = $wc.DownloadString($url)
        $wc.Dispose()
        if (-not $json -or $json -eq '{}') { return $null }
        return ConvertFrom-Json $json
    } catch {
        Write-Host "MusicBrainz request failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Search-MusicBrainz {
    Write-Host ""
    Write-Host "Trying MusicBrainz..." -ForegroundColor Yellow

    # Escape Lucene special characters: + - && || ! ( ) { } [ ] ^ " ~ * ? : \ /
    $luceneSpecial = '[+\-&|!(){}\[\]^"~*?:\\/]'

    $searchData = $null
    # Structured search if artist/album split available
    if ($searchArtist) {
        $safeArtist = [regex]::Replace($searchArtist, $luceneSpecial, '\$0')
        $safeAlbum = [regex]::Replace($searchAlbum, $luceneSpecial, '\$0')
        $encodedArtist = [Uri]::EscapeDataString($safeArtist)
        $encodedAlbum = [Uri]::EscapeDataString($safeAlbum)
        $searchUrl = "https://musicbrainz.org/ws/2/release-group/?query=artist:${encodedArtist}+AND+releasegroup:${encodedAlbum}&fmt=json&limit=10"
        Write-Host "Searching MusicBrainz: artist='$searchArtist' album='$searchAlbum'" -ForegroundColor Cyan
        $searchData = Invoke-MusicBrainz $searchUrl
    }

    # Fallback: generic full-text search
    if (-not $searchData -or -not $searchData.'release-groups' -or $searchData.'release-groups'.Count -eq 0) {
        $safeQuery = [regex]::Replace($cleanQuery, $luceneSpecial, '\$0')
        $encoded = [Uri]::EscapeDataString($safeQuery)
        $searchUrl = "https://musicbrainz.org/ws/2/release-group/?query=${encoded}&fmt=json&limit=10"
        Write-Host "Searching MusicBrainz: '$cleanQuery'" -ForegroundColor Cyan
        Start-Sleep -Seconds 1
        $searchData = Invoke-MusicBrainz $searchUrl
    }

    if (-not $searchData -or -not $searchData.'release-groups' -or $searchData.'release-groups'.Count -eq 0) {
        return $null
    }
    return $searchData.'release-groups'
}

function Format-MusicBrainzResults($results) {
    $output = @()
    for ($i = 0; $i -lt $results.Count; $i++) {
        $rg = $results[$i]
        $title = $rg.title
        $rgType = if ($rg.'primary-type') { $rg.'primary-type' } else { '' }
        $score = if ($rg.score) { $rg.score } else { '' }
        $artistNames = @()
        if ($rg.'artist-credit') {
            foreach ($ac in $rg.'artist-credit') {
                if ($ac.artist -and $ac.artist.name) { $artistNames += $ac.artist.name }
            }
        }
        $artist = $artistNames -join ', '
        $releaseDate = ''
        if ($rg.'first-release-date') { $releaseDate = $rg.'first-release-date' }
        $releaseYear = if ($releaseDate.Length -ge 4) { $releaseDate.Substring(0, 4) } else { '' }
        $tags = @()
        if ($rg.tags) {
            $tags = @($rg.tags | Sort-Object -Property count -Descending | Select-Object -First 5 | ForEach-Object { $_.name })
        }
        $yearDisplay = if ($releaseYear) { " ($releaseYear)" } else { "" }
        Write-Host ""
        $block = @()
        $block += "[$($i+1)] $artist - $title${yearDisplay}"
        $block += "    MBID:         $($rg.id)"
        $block += "    MB URL:       https://musicbrainz.org/release-group/$($rg.id)"
        if ($artist) { $block += "    Artist:       $artist" }
        if ($releaseDate) { $block += "    Released:     $releaseDate" }
        if ($rgType) { $block += "    Type:         $rgType" }
        if ($score) { $block += "    Score:        $score" }
        if ($tags.Count -gt 0) { $block += "    Tags:         $($tags -join ', ')" }

        for ($li = 0; $li -lt $block.Count; $li++) { if ($li -eq 0) { Write-Host $block[$li] -ForegroundColor Cyan } else { Write-Host $block[$li] } }
        $output += $block
        $output += ""
    }
    return $output
}

function Get-MusicBrainzDetails($rgId, $rgTitle, $rgArtist) {
    Write-Host ""
    Write-Host "Fetching release details from MusicBrainz..." -ForegroundColor Cyan
    Start-Sleep -Seconds 1

    $releasesUrl = "https://musicbrainz.org/ws/2/release?release-group=${rgId}&inc=recordings+artist-credits+labels+genres&fmt=json&limit=1"
    $releaseData = Invoke-MusicBrainz $releasesUrl

    $mediaBlock = @()
    if ($releaseData -and $releaseData.releases -and $releaseData.releases.Count -gt 0) {
        $rel = $releaseData.releases[0]
        $relId = $rel.id

        $mediaBlock += "--- Details for: $rgTitle ---"

        # Label
        if ($rel.'label-info' -and $rel.'label-info'.Count -gt 0) {
            $labels = @()
            foreach ($li in $rel.'label-info') {
                if ($li.label -and $li.label.name) { $labels += $li.label.name }
            }
            if ($labels.Count -gt 0) {
                $labelStr = ($labels | Select-Object -Unique) -join ', '
                $mediaBlock += "    Label:        $labelStr"
            }
        }

        # Genres
        if ($rel.genres -and $rel.genres.Count -gt 0) {
            $genreNames = @($rel.genres | Sort-Object -Property count -Descending | Select-Object -First 5 | ForEach-Object { $_.name })
            if ($genreNames.Count -gt 0) {
                $mediaBlock += "    Genres:       $($genreNames -join ', ')"
            }
        }

        # Track listing
        if ($rel.media -and $rel.media.Count -gt 0) {
            $trackNum = 0
            foreach ($medium in $rel.media) {
                $mediumTitle = if ($medium.title) { " - $($medium.title)" } else { "" }
                $discFormat = if ($medium.format) { $medium.format } else { "Disc" }
                if ($rel.media.Count -gt 1) {
                    $mediaBlock += "    --- $discFormat $($medium.position)${mediumTitle} ---"
                }
                if ($medium.tracks) {
                    foreach ($t in $medium.tracks) {
                        $trackNum++
                        $tTitle = $t.title
                        $tArtist = ''
                        if ($t.recording -and $t.recording.'artist-credit') {
                            $acNames = @($t.recording.'artist-credit' | ForEach-Object { $_.artist.name }) -join ', '
                            if ($acNames) { $tArtist = "$acNames - " }
                        }
                        $tLength = ''
                        if ($t.length) {
                            $totalSec = [int][math]::Floor($t.length / 1000)
                            $min = [int][math]::Floor($totalSec / 60)
                            $sec = [int]($totalSec % 60)
                            $tLength = " ({0}:{1:D2})" -f $min, $sec
                        }
                        $mediaBlock += "    Track:        $trackNum. ${tArtist}$tTitle$tLength"
                    }
                }
            }
            $mediaBlock += "    Total Tracks: $trackNum"
        }

        # Cover art from Cover Art Archive
        Start-Sleep -Seconds 1
        $coverFound = $false
        foreach ($coverId in @($relId, $rgId)) {
            $coverType = if ($coverId -eq $relId) { 'release' } else { 'release-group' }
            try {
                $coverUrl = "https://coverartarchive.org/${coverType}/${coverId}/front-500"
                $req = [System.Net.HttpWebRequest]::Create($coverUrl)
                $req.Method = 'HEAD'
                $req.Timeout = 5000
                $req.AllowAutoRedirect = $true
                $resp = $req.GetResponse()
                if ($resp.StatusCode -eq 'OK') {
                    $finalUrl = $resp.ResponseUri.ToString()
                    $mediaBlock += "    Cover:        $finalUrl"
                    $coverFound = $true
                }
                $resp.Close()
                if ($coverFound) { break }
            } catch { }
        }
        if (-not $coverFound) {
            Write-Host "No cover art found on Cover Art Archive" -ForegroundColor Yellow
        }
    }
    return $mediaBlock
}

# ─── Discogs API ──────────────────────────────────────────────────────────

function Invoke-Discogs([string]$url) {
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [System.Text.Encoding]::UTF8
        $wc.Headers.Add('User-Agent', 'ScriptUpload3r/5.0')
        if ($DiscogsToken) { $wc.Headers.Add('Authorization', "Discogs token=$DiscogsToken") }
        $json = $wc.DownloadString($url)
        $wc.Dispose()
        if (-not $json -or $json -eq '{}') { return $null }
        return ConvertFrom-Json $json
    } catch {
        Write-Host "Discogs request failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Search-Discogs {
    $tokenParam = if ($DiscogsToken) { "&token=$DiscogsToken" } else { '' }
    $searchData = $null

    # Short album: strip parenthesized subtitle (e.g. "(2018 Alt metal Rock)")
    $shortAlbum = $searchAlbum -replace '\s*\([^)]+\)\s*', ''
    $shortAlbum = ($shortAlbum -replace '\s+', ' ').Trim()

    # Strategy 1: artist + short album (most reliable — no parenthesized junk)
    if ($searchArtist -and $shortAlbum) {
        $eArtist = [Uri]::EscapeDataString($searchArtist)
        $eAlbum = [Uri]::EscapeDataString($shortAlbum)
        Write-Host "Searching Discogs: artist='$searchArtist' album='$shortAlbum'" -ForegroundColor Cyan
        $searchData = Invoke-Discogs "https://api.discogs.com/database/search?type=release&artist=${eArtist}&release_title=${eAlbum}&per_page=10${tokenParam}"
    }

    # Strategy 2: artist + full album name (in case subtitle is part of the real title)
    if ((-not $searchData -or -not $searchData.results -or $searchData.results.Count -eq 0) -and $searchArtist -and $searchAlbum -ne $shortAlbum) {
        $eArtist = [Uri]::EscapeDataString($searchArtist)
        $eAlbum = [Uri]::EscapeDataString($searchAlbum)
        Write-Host "Retrying Discogs: artist='$searchArtist' album='$searchAlbum'" -ForegroundColor Yellow
        $searchData = Invoke-Discogs "https://api.discogs.com/database/search?type=release&artist=${eArtist}&release_title=${eAlbum}&per_page=10${tokenParam}"
    }

    # Strategy 3: plain text
    if (-not $searchData -or -not $searchData.results -or $searchData.results.Count -eq 0) {
        $encoded = [Uri]::EscapeDataString($cleanQuery)
        Write-Host "Retrying Discogs: '$cleanQuery'" -ForegroundColor Yellow
        $searchData = Invoke-Discogs "https://api.discogs.com/database/search?q=${encoded}&type=release&per_page=10${tokenParam}"
    }

    if (-not $searchData -or -not $searchData.results -or $searchData.results.Count -eq 0) {
        return $null
    }
    return $searchData.results
}

function Format-DiscogsResults($results) {
    $output = @()
    for ($i = 0; $i -lt $results.Count; $i++) {
        $r = $results[$i]
        $title = $r.title
        $year = if ($r.year) { $r.year } else { '' }
        $genre = if ($r.genre) { $r.genre -join ', ' } else { '' }
        $style = if ($r.style) { $r.style -join ', ' } else { '' }
        $label = if ($r.label) { $r.label[0] } else { '' }
        $country = if ($r.country) { $r.country } else { '' }
        $coverUrl = if ($r.cover_image) { $r.cover_image } else { '' }
        $format = if ($r.format) { $r.format -join ', ' } else { '' }

        $yearDisplay = if ($year) { " ($year)" } else { '' }
        Write-Host ""
        $block = @()
        $block += "[$($i+1)] $title${yearDisplay}"
        $block += "    Discogs ID:   $($r.id)"
        if ($r.uri) { $block += "    Discogs URL:  https://www.discogs.com$($r.uri)" }
        if ($year) { $block += "    Released:     $year" }
        if ($genre) { $block += "    Genres:       $genre" }
        if ($style) { $block += "    Styles:       $style" }
        if ($label) { $block += "    Label:        $label" }
        if ($country) { $block += "    Country:      $country" }
        if ($format) { $block += "    Format:       $format" }
        if ($coverUrl) { $block += "    Cover:        $coverUrl" }

        for ($li = 0; $li -lt $block.Count; $li++) { if ($li -eq 0) { Write-Host $block[$li] -ForegroundColor Cyan } else { Write-Host $block[$li] } }
        $output += $block
        $output += ""
    }
    return $output
}

function Get-DiscogsDetails($releaseId, $releaseTitle, $releaseArtist) {
    Write-Host ""
    Write-Host "Fetching release details from Discogs..." -ForegroundColor Cyan
    Start-Sleep -Milliseconds 1100

    $rel = Invoke-Discogs "https://api.discogs.com/releases/${releaseId}"
    $mediaBlock = @()
    if ($rel) {
        $mediaBlock += "--- Details for: $releaseTitle ---"

        if ($rel.released) { $mediaBlock += "    Released:     $($rel.released)" }
        if ($rel.labels -and $rel.labels.Count -gt 0) {
            $labels = @($rel.labels | ForEach-Object { $_.name }) | Select-Object -Unique
            $mediaBlock += "    Label:        $($labels -join ', ')"
        }
        if ($rel.genres) { $mediaBlock += "    Genres:       $($rel.genres -join ', ')" }
        if ($rel.styles) { $mediaBlock += "    Styles:       $($rel.styles -join ', ')" }
        if ($rel.country) { $mediaBlock += "    Country:      $($rel.country)" }

        # Track listing
        if ($rel.tracklist -and $rel.tracklist.Count -gt 0) {
            $trackNum = 0
            foreach ($t in $rel.tracklist) {
                if ($t.type_ -ne 'track') { continue }
                $trackNum++
                $tTitle = $t.title
                $tArtist = ''
                if ($t.artists) {
                    $tArtist = "$(@($t.artists | ForEach-Object { $_.name }) -join ', ') - "
                }
                $tLength = if ($t.duration) { " ($($t.duration))" } else { '' }
                $mediaBlock += "    Track:        $trackNum. ${tArtist}$tTitle$tLength"
            }
            $mediaBlock += "    Total Tracks: $trackNum"
        }

        # Cover art (prefer primary image)
        if ($rel.images -and $rel.images.Count -gt 0) {
            $primary = $rel.images | Where-Object { $_.type -eq 'primary' } | Select-Object -First 1
            if (-not $primary) { $primary = $rel.images[0] }
            if ($primary.uri) { $mediaBlock += "    Cover:        $($primary.uri)" }
        }
    }
    return $mediaBlock
}

# ─── Last.fm API ──────────────────────────────────────────────────────────

function Invoke-Lastfm([string]$url) {
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [System.Text.Encoding]::UTF8
        $json = $wc.DownloadString($url)
        $wc.Dispose()
        if (-not $json -or $json -eq '{}') { return $null }
        return ConvertFrom-Json $json
    } catch {
        Write-Host "Last.fm request failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Search-Lastfm {
    Write-Host ""
    Write-Host "Trying Last.fm..." -ForegroundColor Yellow
    $baseUrl = "http://ws.audioscrobbler.com/2.0/?format=json&api_key=${LastfmApiKey}"

    # Try album search
    $encoded = [Uri]::EscapeDataString($cleanQuery)
    Write-Host "Searching Last.fm: '$cleanQuery'" -ForegroundColor Cyan
    $data = Invoke-Lastfm "${baseUrl}&method=album.search&album=${encoded}&limit=10"

    if (-not $data -or -not $data.results -or -not $data.results.albummatches -or -not $data.results.albummatches.album) {
        return $null
    }
    $albums = @($data.results.albummatches.album)
    if ($albums.Count -eq 0) { return $null }
    return $albums
}

function Format-LastfmResults($results) {
    $output = @()
    for ($i = 0; $i -lt $results.Count; $i++) {
        $a = $results[$i]
        $title = $a.name
        $artist = $a.artist
        $url = $a.url
        $imgArr = $a.image
        $coverUrl = ''
        if ($imgArr) {
            $xl = @($imgArr | Where-Object { $_.size -eq 'extralarge' })
            if ($xl.Count -gt 0 -and $xl[0].'#text') { $coverUrl = $xl[0].'#text' }
            elseif ($imgArr[-1].'#text') { $coverUrl = $imgArr[-1].'#text' }
        }

        Write-Host ""
        $block = @()
        $block += "[$($i+1)] $artist - $title"
        $block += "    Last.fm URL:  $url"
        if ($artist) { $block += "    Artist:       $artist" }
        if ($coverUrl) { $block += "    Cover:        $coverUrl" }

        for ($li = 0; $li -lt $block.Count; $li++) { if ($li -eq 0) { Write-Host $block[$li] -ForegroundColor Cyan } else { Write-Host $block[$li] } }
        $output += $block
        $output += ""
    }
    return $output
}

function Get-LastfmDetails($albumName, $artistName) {
    Write-Host ""
    Write-Host "Fetching album details from Last.fm..." -ForegroundColor Cyan
    $baseUrl = "http://ws.audioscrobbler.com/2.0/?format=json&api_key=${LastfmApiKey}"
    $eArtist = [Uri]::EscapeDataString($artistName)
    $eAlbum = [Uri]::EscapeDataString($albumName)
    $data = Invoke-Lastfm "${baseUrl}&method=album.getinfo&artist=${eArtist}&album=${eAlbum}"

    $mediaBlock = @()
    if ($data -and $data.album) {
        $alb = $data.album
        $mediaBlock += "--- Details for: $($alb.name) ---"

        if ($alb.artist) { $mediaBlock += "    Artist:       $($alb.artist)" }

        # Tags as genres
        if ($alb.tags -and $alb.tags.tag) {
            $tagNames = @($alb.tags.tag | ForEach-Object { $_.name })
            if ($tagNames.Count -gt 0) { $mediaBlock += "    Genres:       $($tagNames -join ', ')" }
        }

        # Listeners/playcount
        if ($alb.listeners) { $mediaBlock += "    Listeners:    $($alb.listeners)" }

        # Tracklist
        if ($alb.tracks -and $alb.tracks.track) {
            $trackList = @($alb.tracks.track)
            $trackNum = 0
            foreach ($t in $trackList) {
                $trackNum++
                $tTitle = $t.name
                $tArtist = ''
                if ($t.artist -and $t.artist.name) {
                    $tArtist = "$($t.artist.name) - "
                }
                $tLength = ''
                if ($t.duration -and [int]$t.duration -gt 0) {
                    $min = [int][math]::Floor([int]$t.duration / 60)
                    $sec = [int]([int]$t.duration % 60)
                    $tLength = " ({0}:{1:D2})" -f $min, $sec
                }
                $mediaBlock += "    Track:        $trackNum. ${tArtist}$tTitle$tLength"
            }
            $mediaBlock += "    Total Tracks: $trackNum"
        }

        # Cover
        $imgArr = $alb.image
        if ($imgArr) {
            $xl = @($imgArr | Where-Object { $_.size -eq 'extralarge' })
            if ($xl.Count -gt 0 -and $xl[0].'#text') { $mediaBlock += "    Cover:        $($xl[0].'#text')" }
        }
    }
    return $mediaBlock
}

# ─── TheAudioDB API ──────────────────────────────────────────────────────

function Invoke-AudioDb([string]$url) {
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [System.Text.Encoding]::UTF8
        $json = $wc.DownloadString($url)
        $wc.Dispose()
        if (-not $json -or $json -eq '{}' -or $json -eq 'null') { return $null }
        return ConvertFrom-Json $json
    } catch {
        Write-Host "TheAudioDB request failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Search-AudioDb {
    Write-Host ""
    Write-Host "Trying TheAudioDB..." -ForegroundColor Yellow
    $base = "https://www.theaudiodb.com/api/v1/json/${AudioDbApiKey}"
    $data = $null

    if ($searchArtist) {
        $eArtist = [Uri]::EscapeDataString($searchArtist)
        $eAlbum = [Uri]::EscapeDataString($searchAlbum)
        Write-Host "Searching TheAudioDB: artist='$searchArtist' album='$searchAlbum'" -ForegroundColor Cyan
        $data = Invoke-AudioDb "${base}/searchalbum.php?s=${eArtist}&a=${eAlbum}"
    }

    # Fallback: search by artist only (v1 doesn't support free-text album search)
    if (-not $data -or -not $data.album) {
        $safeArtist = if ($searchArtist) { $searchArtist } else { ($cleanQuery -split '\s*-\s*')[0].Trim() }
        if ($safeArtist) {
            $eArtist = [Uri]::EscapeDataString($safeArtist)
            Write-Host "Retrying TheAudioDB: artist='$safeArtist'" -ForegroundColor Yellow
            $data = Invoke-AudioDb "${base}/searchalbum.php?s=${eArtist}"
        }
    }

    if (-not $data -or -not $data.album) { return $null }
    return @($data.album)
}

function Format-AudioDbResults($results) {
    $output = @()
    for ($i = 0; $i -lt $results.Count; $i++) {
        $a = $results[$i]
        $title = $a.strAlbum
        $artist = $a.strArtist
        $year = if ($a.intYearReleased) { $a.intYearReleased } else { '' }
        $genre = if ($a.strGenre) { $a.strGenre } else { '' }
        $style = if ($a.strStyle) { $a.strStyle } else { '' }
        $label = if ($a.strLabel) { $a.strLabel } else { '' }
        $coverUrl = if ($a.strAlbumThumb) { $a.strAlbumThumb } else { '' }

        $yearDisplay = if ($year) { " ($year)" } else { '' }
        Write-Host ""
        $block = @()
        $block += "[$($i+1)] $artist - $title${yearDisplay}"
        $block += "    AudioDB ID:   $($a.idAlbum)"
        if ($artist) { $block += "    Artist:       $artist" }
        if ($year) { $block += "    Released:     $year" }
        if ($genre) { $block += "    Genres:       $genre" }
        if ($style) { $block += "    Styles:       $style" }
        if ($label) { $block += "    Label:        $label" }
        if ($coverUrl) { $block += "    Cover:        $coverUrl" }

        for ($li = 0; $li -lt $block.Count; $li++) { if ($li -eq 0) { Write-Host $block[$li] -ForegroundColor Cyan } else { Write-Host $block[$li] } }
        $output += $block
        $output += ""
    }
    return $output
}

function Get-AudioDbDetails($albumId, $albumTitle, $albumArtist) {
    Write-Host ""
    Write-Host "Fetching track listing from TheAudioDB..." -ForegroundColor Cyan
    $base = "https://www.theaudiodb.com/api/v1/json/${AudioDbApiKey}"
    $data = Invoke-AudioDb "${base}/track.php?m=${albumId}"

    $mediaBlock = @()
    $mediaBlock += "--- Details for: $albumTitle ---"

    if ($data -and $data.track) {
        $trackList = @($data.track | Sort-Object { [int]$_.intTrackNumber })
        $trackNum = 0
        foreach ($t in $trackList) {
            $trackNum++
            $tTitle = $t.strTrack
            $tArtist = ''
            if ($t.strArtist) { $tArtist = "$($t.strArtist) - " }
            $tLength = ''
            if ($t.intDuration -and [int]$t.intDuration -gt 0) {
                $totalSec = [int][math]::Floor([int]$t.intDuration / 1000)
                $min = [int][math]::Floor($totalSec / 60)
                $sec = [int]($totalSec % 60)
                $tLength = " ({0}:{1:D2})" -f $min, $sec
            }
            $mediaBlock += "    Track:        $trackNum. ${tArtist}$tTitle$tLength"
        }
        $mediaBlock += "    Total Tracks: $trackNum"
    }
    return $mediaBlock
}

# ─── iTunes Search API ────────────────────────────────────────────────────

function Invoke-ITunes([string]$url) {
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [System.Text.Encoding]::UTF8
        $json = $wc.DownloadString($url)
        $wc.Dispose()
        if (-not $json -or $json -eq '{}') { return $null }
        return ConvertFrom-Json $json
    } catch {
        Write-Host "iTunes request failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Search-ITunes {
    Write-Host ""
    Write-Host "Trying iTunes..." -ForegroundColor Yellow
    $encoded = [Uri]::EscapeDataString($cleanQuery)
    Write-Host "Searching iTunes: '$cleanQuery'" -ForegroundColor Cyan
    $data = Invoke-ITunes "https://itunes.apple.com/search?term=${encoded}&entity=album&limit=10"

    if (-not $data -or -not $data.results -or $data.results.Count -eq 0) { return $null }
    return @($data.results)
}

function Format-ITunesResults($results) {
    $output = @()
    for ($i = 0; $i -lt $results.Count; $i++) {
        $a = $results[$i]
        $title = $a.collectionName
        $artist = $a.artistName
        $year = ''
        if ($a.releaseDate) { $year = $a.releaseDate.Substring(0, 4) }
        $genre = if ($a.primaryGenreName) { $a.primaryGenreName } else { '' }
        $trackCount = if ($a.trackCount) { $a.trackCount } else { '' }
        $coverUrl = if ($a.artworkUrl100) { $a.artworkUrl100 -replace '100x100', '600x600' } else { '' }

        $yearDisplay = if ($year) { " ($year)" } else { '' }
        Write-Host ""
        $block = @()
        $block += "[$($i+1)] $artist - $title${yearDisplay}"
        $block += "    iTunes ID:    $($a.collectionId)"
        $block += "    iTunes URL:   $($a.collectionViewUrl)"
        if ($artist) { $block += "    Artist:       $artist" }
        if ($year) { $block += "    Released:     $($a.releaseDate.Substring(0, 10))" }
        if ($genre) { $block += "    Genres:       $genre" }
        if ($trackCount) { $block += "    Tracks:       $trackCount" }
        if ($coverUrl) { $block += "    Cover:        $coverUrl" }

        for ($li = 0; $li -lt $block.Count; $li++) { if ($li -eq 0) { Write-Host $block[$li] -ForegroundColor Cyan } else { Write-Host $block[$li] } }
        $output += $block
        $output += ""
    }
    return $output
}

function Get-ITunesDetails($collectionId, $albumTitle, $albumArtist) {
    Write-Host ""
    Write-Host "Fetching tracks from iTunes..." -ForegroundColor Cyan
    $data = Invoke-ITunes "https://itunes.apple.com/lookup?id=${collectionId}&entity=song"

    $mediaBlock = @()
    if ($data -and $data.results) {
        $albumInfo = $data.results | Where-Object { $_.wrapperType -eq 'collection' } | Select-Object -First 1
        $tracks = @($data.results | Where-Object { $_.wrapperType -eq 'track' })

        $mediaBlock += "--- Details for: $albumTitle ---"

        if ($albumInfo) {
            if ($albumInfo.releaseDate) { $mediaBlock += "    Released:     $($albumInfo.releaseDate.Substring(0, 10))" }
            if ($albumInfo.primaryGenreName) { $mediaBlock += "    Genres:       $($albumInfo.primaryGenreName)" }
            if ($albumInfo.copyright) { $mediaBlock += "    Label:        $($albumInfo.copyright)" }
        }

        if ($tracks.Count -gt 0) {
            $trackNum = 0
            foreach ($t in $tracks) {
                $trackNum++
                $tTitle = $t.trackName
                $tArtist = ''
                if ($t.artistName) { $tArtist = "$($t.artistName) - " }
                $tLength = ''
                if ($t.trackTimeMillis -and [long]$t.trackTimeMillis -gt 0) {
                    $totalSec = [int][math]::Floor([long]$t.trackTimeMillis / 1000)
                    $min = [int][math]::Floor($totalSec / 60)
                    $sec = [int]($totalSec % 60)
                    $tLength = " ({0}:{1:D2})" -f $min, $sec
                }
                $mediaBlock += "    Track:        $trackNum. ${tArtist}$tTitle$tLength"
            }
            $mediaBlock += "    Total Tracks: $trackNum"
        }

        # Cover (max res)
        if ($albumInfo -and $albumInfo.artworkUrl100) {
            $mediaBlock += "    Cover:        $($albumInfo.artworkUrl100 -replace '100x100', '600x600')"
        }
    }
    return $mediaBlock
}

# ─── Main search flow (provider order from config) ────────────────────────

$source = ''
$results = $null
$output = @()
$providerIdx = 0

# Helper: search a provider by name
function Search-Provider([string]$name) {
    switch ($name) {
        'deezer' {
            $r = Search-Deezer
            if ($r) { $r = @($r) }
            return $r
        }
        'musicbrainz' {
            $r = Search-MusicBrainz
            if ($r) { $r = @($r) }
            return $r
        }
        'discogs' {
            if (-not $DiscogsToken) {
                Write-Host "Skipping Discogs (no token configured)" -ForegroundColor DarkGray
                return $null
            }
            $r = Search-Discogs
            if ($r) { $r = @($r) }
            return $r
        }
        'lastfm' {
            if (-not $LastfmApiKey) {
                Write-Host "Skipping Last.fm (no API key configured)" -ForegroundColor DarkGray
                return $null
            }
            $r = Search-Lastfm
            if ($r) { $r = @($r) }
            return $r
        }
        'audiodb' {
            $r = Search-AudioDb
            if ($r) { $r = @($r) }
            return $r
        }
        'itunes' {
            $r = Search-ITunes
            if ($r) { $r = @($r) }
            return $r
        }
        default { return $null }
    }
}

function Format-Provider([string]$name, $resultData) {
    switch ($name) {
        'deezer'      { return Format-DeezerResults $resultData }
        'musicbrainz' { return Format-MusicBrainzResults $resultData }
        'discogs'     { return Format-DiscogsResults $resultData }
        'lastfm'      { return Format-LastfmResults $resultData }
        'audiodb'     { return Format-AudioDbResults $resultData }
        'itunes'      { return Format-ITunesResults $resultData }
        default       { return @() }
    }
}

# Try providers in configured order
Write-Host "Music providers: $($MusicProviders -join ' > ')" -ForegroundColor DarkGray
foreach ($provider in $MusicProviders) {
    $providerResults = Search-Provider $provider
    if ($providerResults) { $providerResults = @($providerResults) }
    if ($providerResults -and $providerResults.Count -gt 0) {
        $source = $provider
        $results = $providerResults
        Write-Host "Found $($results.Count) result(s) on ${source}:" -ForegroundColor Green
        $output = Format-Provider $source $results
        break
    }
    $providerIdx++
}

if (-not $results -or $results.Count -eq 0) {
    Write-Host "No results found on any provider." -ForegroundColor Yellow
    exit 0
}

# Remaining providers after the current one (for 'n' key) — only those that can run
$remainingProviders = @($MusicProviders | Select-Object -Skip ($providerIdx + 1) | Where-Object {
    if ($_ -eq 'discogs' -and -not $DiscogsToken) { return $false }
    if ($_ -eq 'lastfm' -and -not $LastfmApiKey) { return $false }
    return $true
})

# Ask user to pick — loop allows skipping through all providers with 'n'
$selectedIdx = 0
$picking = $results.Count -gt 1 -or $remainingProviders.Count -gt 0
while ($picking) {
    Write-Host ""
    $nextLabel = if ($remainingProviders.Count -gt 0) { ", n=try $($remainingProviders[0])" } else { '' }
    Write-Host "Enter number to select (default=1, c=cancel${nextLabel}): " -ForegroundColor Yellow -NoNewline
    $choice = Read-Host
    if ($choice -match '^[cC]$') {
        Write-Host "Cancelled." -ForegroundColor Yellow
        exit 2
    }
    if ($choice -match '^[nN]$' -and $remainingProviders.Count -gt 0) {
        $found = $false
        foreach ($nextProvider in $remainingProviders) {
            $nextResults = Search-Provider $nextProvider
            if ($nextResults) { $nextResults = @($nextResults) }
            if ($nextResults -and $nextResults.Count -gt 0) {
                $source = $nextProvider
                $results = $nextResults
                $selectedIdx = 0
                Write-Host "Found $($results.Count) result(s) on ${source}:" -ForegroundColor Green
                $output = Format-Provider $source $results
                # Update remaining providers (skip past the one we just used)
                $usedIdx = [array]::IndexOf($remainingProviders, $nextProvider)
                $remainingProviders = @($remainingProviders | Select-Object -Skip ($usedIdx + 1) | Where-Object {
                    if ($_ -eq 'discogs' -and -not $DiscogsToken) { return $false }
                    if ($_ -eq 'lastfm' -and -not $LastfmApiKey) { return $false }
                    return $true
                })
                $found = $true
                if ($results.Count -le 1 -and $remainingProviders.Count -eq 0) { $picking = $false }
                break
            }
        }
        if (-not $found) {
            Write-Host "No results on remaining providers." -ForegroundColor Yellow
            exit 0
        }
    } else {
        if ($choice -match '^\d+$') {
            $pick = [int]$choice
            if ($pick -ge 1 -and $pick -le $results.Count) { $selectedIdx = $pick - 1 }
        }
        $picking = $false
    }
}
$selTitle = $results[$selectedIdx].title
if (-not $selTitle) { $selTitle = $results[$selectedIdx].name }
if (-not $selTitle) { $selTitle = $results[$selectedIdx].strAlbum }
if (-not $selTitle) { $selTitle = $results[$selectedIdx].collectionName }
Write-Host "Selected: [$($selectedIdx+1)] $selTitle" -ForegroundColor Green

# Reorder output so selected result is first
if ($selectedIdx -ne 0) {
    $selectedResult = $results[$selectedIdx]
    $reordered = @($selectedResult) + @($results | Where-Object { $_.id -ne $selectedResult.id })
    $results = $reordered
    $output = Format-Provider $source $results
}

# Save initial results
[System.IO.File]::WriteAllText($OutputFile, ($output -join "`n") + "`n", $utf8NoBom)

# Fetch detailed info for selected result
$mediaBlock = @()
if ($source -eq 'deezer') {
    $bestId = $results[0].id
    $bestTitle = $results[0].title
    $bestArtist = if ($results[0].artist -and $results[0].artist.name) { $results[0].artist.name } else { $searchArtist }
    $mediaBlock = Get-DeezerDetails $bestId $bestTitle $bestArtist
} elseif ($source -eq 'musicbrainz') {
    $bestRgId = $results[0].id
    $bestTitle = $results[0].title
    $bestArtistNames = @()
    if ($results[0].'artist-credit') {
        $bestArtistNames = @($results[0].'artist-credit' | ForEach-Object { $_.artist.name })
    }
    $bestArtist = if ($bestArtistNames.Count -gt 0) { $bestArtistNames -join ', ' } else { $searchArtist }
    $mediaBlock = Get-MusicBrainzDetails $bestRgId $bestTitle $bestArtist
} elseif ($source -eq 'discogs') {
    $bestId = $results[0].id
    $bestTitle = $results[0].title
    $bestArtist = $searchArtist
    $mediaBlock = Get-DiscogsDetails $bestId $bestTitle $bestArtist
} elseif ($source -eq 'lastfm') {
    $bestTitle = $results[0].name
    $bestArtist = if ($results[0].artist) { $results[0].artist } else { $searchArtist }
    $mediaBlock = Get-LastfmDetails $bestTitle $bestArtist
} elseif ($source -eq 'audiodb') {
    $bestId = $results[0].idAlbum
    $bestTitle = $results[0].strAlbum
    $bestArtist = if ($results[0].strArtist) { $results[0].strArtist } else { $searchArtist }
    $mediaBlock = Get-AudioDbDetails $bestId $bestTitle $bestArtist
} elseif ($source -eq 'itunes') {
    $bestId = $results[0].collectionId
    $bestTitle = $results[0].collectionName
    $bestArtist = if ($results[0].artistName) { $results[0].artistName } else { $searchArtist }
    $mediaBlock = Get-ITunesDetails $bestId $bestTitle $bestArtist
}

if ($mediaBlock.Count -gt 0) {
    foreach ($line in $mediaBlock) { Write-Host $line }
    $existing = [System.IO.File]::ReadAllText($OutputFile, $utf8NoBom)
    [System.IO.File]::WriteAllText($OutputFile, $existing + ($mediaBlock -join "`n") + "`n", $utf8NoBom)
}

Write-Host ""
Write-Host "Music metadata saved to: $OutputFile" -ForegroundColor Green
