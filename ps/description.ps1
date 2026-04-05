#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Build the final BBCode torrent description from output files.
    Also builds an upload request file with all form fields.
.PARAMETER directory
    Path to the content directory.
.PARAMETER configfile
    Path to JSONC config file (default: ./config.jsonc).
.PARAMETER tv
    Switch to upload as TV show (category_id=12).
.PARAMETER game
    Switch to upload as game.
.PARAMETER software
    Switch to upload as software.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$directory,

    [Parameter(Position = 1)]
    [string]$configfile,

    [switch]$tv,

    [switch]$game,

    [switch]$software,

    [string]$poster
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$directory = $directory.TrimEnd('"').Trim().TrimEnd('\')
$RootDir = "$PSScriptRoot/.."
$OutDir = "$RootDir/output"

if (Test-Path -LiteralPath $directory -PathType Leaf) {
    $singleFile = $directory
    $directory = Split-Path -Parent $directory
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($singleFile)
} else {
    $singleFile = $null
    $baseName = Split-Path -Path $directory -Leaf
}

if (-not $configfile) { $configfile = Join-Path $RootDir "config.jsonc" }

$TorrentName = $baseName
$GeminiFile      = Join-Path $OutDir "${TorrentName}_description.bbcode"
$ImdbFile        = Join-Path $OutDir "${TorrentName}_imdb.txt"
$TmdbFile        = Join-Path $OutDir "${TorrentName}_tmdb.txt"
$IgdbFile        = Join-Path $OutDir "${TorrentName}_igdb.txt"
$ScreensFile     = Join-Path $OutDir "${TorrentName}_screens.txt"
$TorrentDescFile = Join-Path $OutDir "${TorrentName}_torrent_description.bbcode"
$MediainfoFile   = Join-Path $OutDir "${TorrentName}_mediainfo.txt"
$RequestFile     = Join-Path $OutDir "${TorrentName}_upload_request.txt"

# Build title header from directory name (avoids encoding issues with special chars)
$EnTitle = $TorrentName -replace '[._]', ' ' -replace '(?i)\bSEASON\s+\d+\b', '' -replace ' - [Ss]\d{2}.*', '' -replace '\b[Ss]\d{2}.*', '' -replace '\b(19|20)\d{2}\b.*', '' -replace '(?i)\b(2160|1080|720|480|360)[pi]\b.*', '' -replace '(?i)\b(WEBRip|WEB-DL|WEBDL|BluRay|BDRip|BRRip|HDRip|HDTV|DVDRip|REMUX|WEB)\b.*', '' -replace '[\s([]+$', ''
$yearMatch = [regex]::Match($TorrentName, '\b(19|20)\d{2}\b')
$Year = if ($yearMatch.Success) { $yearMatch.Value } else { $null }

# Fallback: get year from IMDB file header
if (-not $Year -and (Test-Path -LiteralPath $ImdbFile)) {
    $firstSection = Get-Content -LiteralPath $ImdbFile -Encoding UTF8 |
        ForEach-Object { $_ -replace '^\xEF\xBB\xBF', '' } |
        Where-Object { $_ -match '^===' } | Select-Object -First 1
    if ($firstSection -and $firstSection -match '\((\d{4})\)') { $Year = $matches[1] }
}
# Fallback: get year from TMDB file first result
if (-not $Year -and (Test-Path -LiteralPath $TmdbFile)) {
    $tmdbFirst = Get-Content -LiteralPath $TmdbFile -Encoding UTF8 |
        ForEach-Object { $_ -replace '^\xEF\xBB\xBF', '' } |
        Where-Object { $_ -match '^\[1\]' } | Select-Object -First 1
    if ($tmdbFirst -and $tmdbFirst -match '\((\d{4})\)') { $Year = $matches[1] }
}
# Fallback: get year from IGDB file first result
if (-not $Year -and (Test-Path -LiteralPath $IgdbFile)) {
    $igdbFirst = Get-Content -LiteralPath $IgdbFile -Encoding UTF8 |
        ForEach-Object { $_ -replace '^\xEF\xBB\xBF', '' } |
        Where-Object { $_ -match '^\[1\]' } | Select-Object -First 1
    if ($igdbFirst -and $igdbFirst -match '\((\d{4})\)') { $Year = $matches[1] }
}
# Fallback: extract year from AI-generated description
if (-not $Year -and (Test-Path -LiteralPath $GeminiFile)) {
    $descContent = Get-Content -LiteralPath $GeminiFile -Encoding UTF8 -TotalCount 10
    foreach ($dl in $descContent) {
        if ($dl -match '\((\d{4})\)') { $Year = $matches[1]; break }
    }
}
if (-not $Year) { $Year = '????' }

# Get BG title, EN title, banner and poster from TMDB file
$BgTitle = ''
$TmdbEnTitle = ''
$BannerUrl = ''
$PosterUrl = ''
if (Test-Path -LiteralPath $TmdbFile) {
    $tmdbContent = Get-Content -LiteralPath $TmdbFile -Encoding UTF8
    $bgLine = $tmdbContent | Where-Object { $_ -match '^\s+BG Title:' } | Select-Object -First 1
    if ($bgLine) { $BgTitle = ($bgLine -replace '^\s+BG Title:\s*', '').Trim() }
    # Extract English title and banner from the best-matched result (the one with BG Title)
    if ($BgTitle) {
        for ($i = 0; $i -lt $tmdbContent.Count; $i++) {
            if ($tmdbContent[$i] -match '^\s+BG Title:') {
                # Walk back to find the result header line [N] Title (year)
                for ($j = $i - 1; $j -ge 0; $j--) {
                    if ($tmdbContent[$j] -match '^\[\d+\]\s+(.+?)\s+\(\d{4}\)$') {
                        $TmdbEnTitle = $matches[1]
                        break
                    }
                }
                # Walk back to find the Banner line
                if ($i -gt 0 -and $tmdbContent[$i-1] -match '^\s+Banner:') {
                    $BannerUrl = ($tmdbContent[$i-1] -replace '^\s+Banner:\s*', '').Trim()
                    if ($BannerUrl -eq '(none)') { $BannerUrl = '' }
                }
                if ($TmdbEnTitle) { break }
            }
        }
    }
    # Fallback: English title from first result
    if (-not $TmdbEnTitle) {
        $tmdbFirstLine = $tmdbContent | Where-Object { $_ -match '^\[1\]' } | Select-Object -First 1
        if ($tmdbFirstLine -and $tmdbFirstLine -match '^\[1\]\s+(.+?)\s+\(\d{4}\)$') { $TmdbEnTitle = $matches[1] }
    }
    # Fallback: first non-empty banner from any result
    if (-not $BannerUrl) {
        $bannerLine = $tmdbContent | Where-Object { $_ -match '^\s+Banner:' -and $_ -notmatch '\(none\)' } | Select-Object -First 1
        if ($bannerLine) {
            $BannerUrl = ($bannerLine -replace '^\s+Banner:\s*', '').Trim()
        }
    }
    # Extract poster URL from best-matched result (the one with BG Title)
    if ($BgTitle) {
        for ($i = 0; $i -lt $tmdbContent.Count; $i++) {
            if ($tmdbContent[$i] -match '^\s+BG Title:') {
                # Walk back to find the Poster line for this result
                for ($j = $i - 1; $j -ge 0; $j--) {
                    if ($tmdbContent[$j] -match '^\s+Poster:' -and $tmdbContent[$j] -notmatch '\(none\)') {
                        $PosterUrl = ($tmdbContent[$j] -replace '^\s+Poster:\s*', '').Trim()
                        break
                    }
                    if ($tmdbContent[$j] -match '^\[\d+\]') { break }
                }
                break
            }
        }
    }
    # Fallback: poster from first result
    if (-not $PosterUrl) {
        # Find poster between [1] and [2] markers
        $inFirst = $false
        foreach ($tl in $tmdbContent) {
            if ($tl -match '^\[1\]') { $inFirst = $true; continue }
            if ($tl -match '^\[2\]') { break }
            if ($inFirst -and $tl -match '^\s+Poster:' -and $tl -notmatch '\(none\)') {
                $PosterUrl = ($tl -replace '^\s+Poster:\s*', '').Trim()
                break
            }
        }
    }
    # Override with season poster if available (skip for multi-season packs like S01-S05)
    $isSeasonPack = $TorrentName -match '(?i)S\d{2}\s*-\s*S\d{2}'
    if (-not $isSeasonPack) {
        foreach ($tl in $tmdbContent) {
            if ($tl -match '^--- Season \d+') { $inSeason = $true; continue }
            if ($inSeason -and $tl -match '^\s+Poster:' -and $tl -notmatch '\(none\)') {
                $PosterUrl = ($tl -replace '^\s+Poster:\s*', '').Trim()
                break
            }
        }
    }
}

# Fallback: read title and cover from IGDB file (for game uploads)
if (-not $TmdbEnTitle -and (Test-Path -LiteralPath $IgdbFile)) {
    $igdbContent = Get-Content -LiteralPath $IgdbFile -Encoding UTF8
    $igdbFirstLine = $igdbContent | Where-Object { $_ -match '^\[1\]' } | Select-Object -First 1
    if ($igdbFirstLine -and $igdbFirstLine -match '^\[1\]\s+(.+?)\s+\(\d{4}\)$') { $TmdbEnTitle = $matches[1] }
    if (-not $PosterUrl) {
        $coverLine = $igdbContent | Where-Object { $_ -match '^\s+Cover:' } | Select-Object -First 1
        if ($coverLine) { $PosterUrl = ($coverLine -replace '^\s+Cover:\s*', '').Trim() }
    }
}

# Override poster with user-provided value (URL or local file path)
if ($poster) {
    if ($poster -match '^https?://') {
        $PosterUrl = $poster
    } elseif (Test-Path -LiteralPath $poster -PathType Leaf) {
        # Upload local file to onlyimage.org
        $cfg = (Get-Content -LiteralPath $configfile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json
        $imgKey = $cfg.onlyimage_api_key
        if ($imgKey) {
            Write-Host -NoNewline "Uploading poster: $(Split-Path -Leaf $poster) ... "
            try {
                $tmpPoster = [System.IO.Path]::GetTempFileName() + [System.IO.Path]::GetExtension($poster)
                Copy-Item -LiteralPath $poster -Destination $tmpPoster -Force
                $result = & curl.exe -s -X POST "https://onlyimage.org/api/1/upload" `
                    -H "X-API-Key: $imgKey" `
                    -F "source=@$tmpPoster" `
                    -F "format=json"
                Remove-Item -LiteralPath $tmpPoster -ErrorAction SilentlyContinue
                $json = $result | ConvertFrom-Json
                $imgUrl = if ($json.image -and $json.image.url) { $json.image.url } elseif ($json.url) { $json.url } else { $null }
                if ($json.status_code -eq 200 -and $imgUrl) {
                    Write-Host $imgUrl
                    $PosterUrl = $imgUrl
                } else {
                    $errTxt = if ($json.status_txt) { $json.status_txt } else { 'unknown error' }
                    Write-Host "FAILED ($errTxt)" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "FAILED ($($_.Exception.Message))" -ForegroundColor Yellow
            }
        } else {
            Write-Host "Warning: 'onlyimage_api_key' not configured, cannot upload poster." -ForegroundColor Yellow
        }
    } else {
        Write-Host "Warning: poster file not found: $poster" -ForegroundColor Yellow
    }
}

# Fallback: read AI-suggested poster URL if no poster set yet
if (-not $PosterUrl) {
    $aiPosterFile = Join-Path -Path $OutDir -ChildPath "${baseName}_poster_url.txt"
    if (Test-Path -LiteralPath $aiPosterFile) {
        $PosterUrl = ([System.IO.File]::ReadAllText($aiPosterFile, [System.Text.Encoding]::UTF8)).Trim()
        if ($PosterUrl) { Write-Host "Using AI-suggested poster: $PosterUrl" -ForegroundColor Cyan }
    }
}

$enHeader = if ($TmdbEnTitle -and $TmdbEnTitle -notmatch '[\p{IsCyrillic}]') { $TmdbEnTitle } else { $EnTitle }
$yearSuffix = if ($Year -and $Year -ne '????') { " (${Year})" } else { '' }
if ($BgTitle -and $BgTitle -ne $enHeader) {
    $Header = "[size=26][b]${enHeader}${yearSuffix} / ${BgTitle}${yearSuffix}[/b][/size]"
} else {
    $Header = "[size=26][b]${enHeader}${yearSuffix}[/b][/size]"
}

# Override header for games/software with clean name + version
if ($game.IsPresent -or $software.IsPresent) {
    $swName = $TorrentName
    # Remove bracketed tags like [SKIDROW], (GOG), {PLAZA}
    $swName = $swName -replace '\s*[\[\(\{][^\]\)\}]+[\]\)\}]\s*', ' '
    $swName = $swName -replace '[\s_]', '.'
    $swName = $swName -replace '(?i)[-\.]by[-\.].+$', ''
    $swName = $swName -replace '(?i)[-\.](RePack|Repack|Portable|Cracked|Patched|PreActivated|Activated)[-\.]?', ''
    $swName = $swName -replace '(?i)[-\.](CODEX|PLAZA|GOG|FLT|SKIDROW|RELOADED|RUNE|DARKSiDERS|TiNYiSO|EMPRESS|SiMPLEX|DOGE|Razor1911|HI2U|ANOMALY|P2P|KaOs|FitGirl|DODI|XFORCE|TNT|AMPED|RECOiL|FOSI|CYGiSO|ECZ|MAGNiTUDE|SSQ)$', ''
    $swName = $swName -replace '(?i)[-\.](WinAll|Multilingual|x64|x86|Win64|Win32|macOS|Linux)[-\.]?', ''
    $swName = $swName -replace '[._]', ' '
    $swName = [regex]::Replace($swName, '(?<=\d) (?=\d)', '.')
    $swName = ($swName -replace '\s+', ' ').Trim()
    $swHeader = if ($yearSuffix) { "${swName}${yearSuffix}" } else { $swName }
    $Header = "[size=26][b]${swHeader}[/b][/size]"
}

# Build description body
$Description = ''

$TmdbBgDesc = ''
$SeasonBgDesc = ''
if (Test-Path -LiteralPath $TmdbFile) {
    $tmdbLines = Get-Content -LiteralPath $TmdbFile -Encoding UTF8
    $bgDescLine = $tmdbLines | Where-Object { $_ -match '^\s+\(bg\):' } | Select-Object -First 1
    if ($bgDescLine) { $TmdbBgDesc = ($bgDescLine -replace '^\s+\(bg\):\s*', '').Trim() }

    # Check for season-specific data
    $inSeason = $false
    foreach ($tl in $tmdbLines) {
        if ($tl -match '^--- Season \d+') { $inSeason = $true; continue }
        if ($inSeason) {
            if ($tl -match '^\s+\(bg\):') {
                $SeasonBgDesc = ($tl -replace '^\s+\(bg\):\s*', '').Trim()
            }
            if ($tl.Trim() -eq '' -and $SeasonBgDesc) { break }
        }
    }
    # Prefer season BG description over show-level one if available
    if ($SeasonBgDesc) { $TmdbBgDesc = $SeasonBgDesc }
}

if (Test-Path -LiteralPath $GeminiFile) {
    $Description = (Get-Content -LiteralPath $GeminiFile -Encoding UTF8 -Raw).TrimEnd()
} elseif (Test-Path -LiteralPath $ImdbFile) {
    $imdbContent = Get-Content -LiteralPath $ImdbFile -Encoding UTF8
    $title    = ($imdbContent | Where-Object { $_ -match '^===' } | Select-Object -First 1) -replace '^=== (.*) ===$', '$1'
    $rating   = ($imdbContent | Where-Object { $_ -match '^Rating:' }   | Select-Object -First 1) -replace '^Rating:\s*', ''
    $genres   = ($imdbContent | Where-Object { $_ -match '^Genres:' }   | Select-Object -First 1) -replace '^Genres:\s*', ''
    $runtime  = ($imdbContent | Where-Object { $_ -match '^Runtime:' }  | Select-Object -First 1) -replace '^Runtime:\s*', ''
    $tagline  = ($imdbContent | Where-Object { $_ -match '^Tagline:' }  | Select-Object -First 1) -replace '^Tagline:\s*', ''
    $director = ($imdbContent | Where-Object { $_ -match '^Director' }  | Select-Object -First 1) -replace '^Director[^:]*:\s*', ''
    $cast     = ($imdbContent | Where-Object { $_ -match '^Cast:' }     | Select-Object -First 1) -replace '^Cast:\s*', ''

    # Extract overview (lines after "Overview:" until next labeled section)
    $inOverview = $false
    $overviewLines = @()
    foreach ($line in $imdbContent) {
        if ($line -match '^Overview:') { $inOverview = $true; continue }
        if ($inOverview -and $line -match '^[A-Za-z][A-Za-z ()]*:\s*$|^[A-Za-z][A-Za-z ()]*:\s') { break }
        if ($inOverview -and $line.Trim()) { $overviewLines += $line }
    }
    $overview = $overviewLines -join "`n"

    # Extract trailers (lines after "Trailers:" with URL pattern)
    $trailerLinks = @()
    $inTrailers = $false
    foreach ($line in $imdbContent) {
        if ($line -match '^Trailers:') { $inTrailers = $true; continue }
        if ($inTrailers -and $line.Trim() -eq '') { break }
        if ($inTrailers -and $line -match '^\s+(.+?):\s+(https://\S+)') {
            $trailerLinks += @{ name = $matches[1]; url = $matches[2] }
        }
    }

    # Build emojis from code points (PS5.1 encoding safety)
    $e_genre   = [char]::ConvertFromUtf32(0x1F3AD)  # theater masks
    $e_star    = [char]::ConvertFromUtf32(0x2B50)    # star
    $e_trailer = [char]::ConvertFromUtf32(0x1F4FA)   # film projector
    $e_plot    = [char]::ConvertFromUtf32(0x1F4D6)   # open book
    $e_people  = [char]::ConvertFromUtf32(0x1F465)   # people
    $e_dir     = [char]::ConvertFromUtf32(0x1F3AC)   # clapperboard
    $e_clock   = [char]::ConvertFromUtf32(0x23F0)    # alarm clock
    $e_globe   = [char]::ConvertFromUtf32(0x1F30D)   # globe

    $Description = ""
    if ($genres)   { $Description += "${e_genre} [b]Genres:[/b] ${genres}`n`n" }
    if ($rating)   { $Description += "${e_star} [b]Rating:[/b] ${rating}`n`n" }
    $Description += "[b]${title}[/b]"
    if ($tagline) { $Description += " [i]- ${tagline}[/i]" }
    $Description += "`n"

    if ($overview) { $Description += "`n${e_plot} [b]Plot:[/b]`n${overview}`n" }
    if ($TmdbBgDesc) { $Description += "`n${e_globe} [b]BG:[/b]`n${TmdbBgDesc}`n" }
    if ($director) { $Description += "`n${e_dir} [b]Director:[/b] ${director}`n" }
    if ($cast)     { $Description += "`n${e_people} [b]Cast:[/b] ${cast}`n" }
} elseif ($TmdbBgDesc) {
    $e_globe = [char]::ConvertFromUtf32(0x1F30D)
    $Description = "${e_globe} [b]BG:[/b]`n${TmdbBgDesc}"
}

# Extract RT ratings, runtime, countries and trailers from IMDB file
$RtCritics = ''
$RtAudience = ''
$imdbRuntime = ''
$imdbCountries = ''
$imdbTrailers = @()
if (Test-Path -LiteralPath $ImdbFile) {
    $imdbLines = Get-Content -LiteralPath $ImdbFile -Encoding UTF8
    $criticsLine = $imdbLines | Where-Object { $_ -match '^RT Critics:' } | Select-Object -First 1
    if ($criticsLine) { $RtCritics = ($criticsLine -replace '^RT Critics:\s*', '').Trim() }
    $audienceLine = $imdbLines | Where-Object { $_ -match '^RT Audience:' } | Select-Object -First 1
    if ($audienceLine) { $RtAudience = ($audienceLine -replace '^RT Audience:\s*', '').Trim() }
    $runtimeLine = $imdbLines | Where-Object { $_ -match '^Runtime:' } | Select-Object -First 1
    if ($runtimeLine) { $imdbRuntime = ($runtimeLine -replace '^Runtime:\s*', '').Trim() }
    $countriesLine = $imdbLines | Where-Object { $_ -match '^Countries:' } | Select-Object -First 1
    if ($countriesLine) { $imdbCountries = ($countriesLine -replace '^Countries:\s*', '').Trim() }
    # Extract trailers
    $inTrailers = $false
    foreach ($tl in $imdbLines) {
        if ($tl -match '^Trailers:') { $inTrailers = $true; continue }
        if ($inTrailers -and $tl.Trim() -eq '') { break }
        if ($inTrailers -and $tl -match '^\s+(.+?):\s+(https://\S+)') {
            $imdbTrailers += @{ name = $matches[1]; url = $matches[2] }
        }
    }
}

# Read IGDB ID and URL from IGDB file if available (for game uploads)
$Igdb = 0
$IgdbUrl = ''
if (Test-Path -LiteralPath $IgdbFile) {
    $igdbContent3 = Get-Content -LiteralPath $IgdbFile -Encoding UTF8
    $igdbIdLine = $igdbContent3 | Where-Object { $_ -match '^\s+IGDB ID:' } | Select-Object -First 1
    if ($igdbIdLine) { $Igdb = ($igdbIdLine -replace '^\s+IGDB ID:\s*', '').Trim() }
    $igdbUrlLine = $igdbContent3 | Where-Object { $_ -match '^\s+IGDB URL:' } | Select-Object -First 1
    if ($igdbUrlLine) { $IgdbUrl = ($igdbUrlLine -replace '^\s+IGDB URL:\s*', '').Trim() }
}

# Fallback: extract trailers from IGDB file (for game uploads)
if ($imdbTrailers.Count -eq 0 -and (Test-Path -LiteralPath $IgdbFile)) {
    $igdbTrailerLines = Get-Content -LiteralPath $IgdbFile -Encoding UTF8 | Where-Object { $_ -match '^\s+Trailer:' }
    foreach ($tl in $igdbTrailerLines) {
        if ($tl -match '^\s+Trailer:\s+(.+?):\s+(https://\S+)') {
            $imdbTrailers += @{ name = $matches[1]; url = $matches[2] }
        }
    }
}

# Insert runtime and countries after genre line
if ($imdbRuntime -or $imdbCountries) {
    $e_clock = [char]::ConvertFromUtf32(0x23F0)    # alarm clock
    $e_globe = [char]::ConvertFromUtf32(0x1F30D)   # globe
    $descLines = $Description -split "`n"
    $newLines = @()
    $inserted = $false
    foreach ($dl in $descLines) {
        $newLines += $dl
        # Match genre line: English "Genres"/"Genre" or Bulgarian char codes for "Жанр"
        $bgGenre = [char]0x0416 + [char]0x0430 + [char]0x043D + [char]0x0440  # Жанр
        if (-not $inserted -and ($dl -match '\[b\].{0,15}(Genres|Genre)' -or $dl.Contains($bgGenre))) {
            $newLines += ''
            if ($imdbRuntime) { $newLines += "${e_clock} [b]Runtime:[/b] ${imdbRuntime}" }
            if ($imdbCountries) { $newLines += "${e_globe} [b]Countries:[/b] ${imdbCountries}" }
            $newLines += ''
            $inserted = $true
        }
    }
    $Description = $newLines -join "`n"
}

# Insert RT ratings after IMDB rating line in description
if ($RtCritics -or $RtAudience) {
    $tomato = [char]::ConvertFromUtf32(0x1F345)
    $popcorn = [char]::ConvertFromUtf32(0x1F37F)
    # "RT Критици" / "RT Публика" as char arrays to avoid PS5.1 encoding issues
    $lblCritics = "RT " + [char]0x041A + [char]0x0440 + [char]0x0438 + [char]0x0442 + [char]0x0438 + [char]0x0446 + [char]0x0438
    $lblAudience = "RT " + [char]0x041F + [char]0x0443 + [char]0x0431 + [char]0x043B + [char]0x0438 + [char]0x043A + [char]0x0430
    $descLines = $Description -split "`n"
    $newLines = @()
    $inserted = $false
    foreach ($dl in $descLines) {
        $newLines += $dl
        if (-not $inserted -and $dl -match '\[b\].{0,15}:\[/b\].*\d+/10') {
            if ($RtCritics) { $newLines += "${tomato} [b]${lblCritics}:[/b] ${RtCritics}" }
            if ($RtAudience) { $newLines += "${popcorn} [b]${lblAudience}:[/b] ${RtAudience}" }
            $inserted = $true
        }
    }
    $Description = $newLines -join "`n"
}

# Insert trailer links after: RT ratings > IMDB rating > genre (first found)
if ($imdbTrailers.Count -gt 0) {
    $e_trailer = [char]::ConvertFromUtf32(0x1F4FA)
    $tLinks = ($imdbTrailers | ForEach-Object { "[url=$($_.url)]$($_.name)[/url]" }) -join ' | '
    $trailerLine = "${e_trailer} [b]Trailer:[/b] ${tLinks}"
    $descLines = $Description -split "`n"
    # Find insertion point: last of RT line, rating line (/10 or /100), or genre line
    $insertIdx = -1
    $bgGenre2 = [char]0x0416 + [char]0x0430 + [char]0x043D + [char]0x0440  # Жанр
    $bgRating = [char]0x0420 + [char]0x0435 + [char]0x0439 + [char]0x0442 + [char]0x0438 + [char]0x043D + [char]0x0433  # Рейтинг
    for ($i = 0; $i -lt $descLines.Count; $i++) {
        $dl = $descLines[$i]
        if ($dl -match '\[b\].*RT\s|RT\s.*\[/b\]') { $insertIdx = $i }
        elseif ($dl -match '\[b\].{0,15}:\[/b\].*\d+/\d+' -or $dl.Contains($bgRating)) { $insertIdx = $i }
        elseif ($dl -match '\[b\].{0,15}(Genres|Genre|Runtime|Countries)' -or $dl.Contains($bgGenre2)) { if ($insertIdx -lt 0) { $insertIdx = $i } }
    }
    if ($insertIdx -ge 0) {
        $newLines = @()
        for ($k = 0; $k -lt $descLines.Count; $k++) {
            $newLines += $descLines[$k]
            if ($k -eq $insertIdx) {
                $newLines += ''
                $newLines += $trailerLine
            }
        }
        $Description = $newLines -join "`n"
    } else {
        $Description = $trailerLine + "`n`n" + $Description
    }
}

# Insert IGDB link above genre line (for game uploads)
if ($IgdbUrl -and $Igdb) {
    $e_link = [char]::ConvertFromUtf32(0x1F517)
    $igdbLine = "${e_link} [b]IGDB:[/b] [url=${IgdbUrl}]${Igdb}[/url]"
    $descLines = $Description -split "`n"
    $bgGenre3 = [char]0x0416 + [char]0x0430 + [char]0x043D + [char]0x0440  # Жанр
    $igdbInserted = $false
    $newLines = @()
    for ($k = 0; $k -lt $descLines.Count; $k++) {
        if (-not $igdbInserted -and ($descLines[$k] -match '\[b\].{0,15}(Genres|Genre)' -or $descLines[$k].Contains($bgGenre3))) {
            $newLines += $igdbLine
            $igdbInserted = $true
        }
        $newLines += $descLines[$k]
    }
    if (-not $igdbInserted) { $newLines = @($igdbLine, '') + $newLines }
    $Description = $newLines -join "`n"
}

# Validate image URLs: must be http(s) and return a valid response
function Test-ImageUrl($url) {
    if (-not $url -or $url -notmatch '^https?://') { return $false }
    # Reject incomplete TMDB URLs (no image path after base)
    if ($url -match 'image\.tmdb\.org/t/p/[^/]+/?$') { return $false }
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Method = 'HEAD'
        $req.Timeout = 5000
        $req.AllowAutoRedirect = $false
        $resp = $req.GetResponse()
        $ok = $resp.StatusCode -eq 'OK'
        $resp.Close()
        return $ok
    } catch { return $false }
}

if ($PosterUrl -and -not (Test-ImageUrl $PosterUrl)) {
    Write-Host "Warning: Poster URL not reachable, skipping: $PosterUrl" -ForegroundColor Yellow
    $PosterUrl = ''
}
if ($BannerUrl -and -not (Test-ImageUrl $BannerUrl)) {
    Write-Host "Warning: Banner URL not reachable, skipping: $BannerUrl" -ForegroundColor Yellow
    $BannerUrl = ''
}

# Build BBCode image tags, wrapping in [url] if TMDB page URL is available
$bannerBBCode = if ($BannerUrl) { "[url=${BannerUrl}][img=1920]${BannerUrl}[/img][/url]" } else { '' }
$posterBBCode = if ($PosterUrl) { "[url=${PosterUrl}][img=250]${PosterUrl}[/img][/url]" } else { '' }

# Wrap metadata block in a table with poster (poster in left column, metadata in right)
if ($PosterUrl) {
    $descLines = $Description -split "`n"
    # Find where the metadata block ends: metadata lines start with emoji + [b] or are blank lines between them
    # Content starts at lines like [b]Title[/b], emoji+[b]Plot/Сюжет, emoji+title line (the bold title summary)
    $metaEndIdx = -1
    $lastMetaIdx = -1
    for ($i = 0; $i -lt $descLines.Count; $i++) {
        $ln = $descLines[$i].Trim()
        if ($ln -eq '') { continue }
        # Metadata lines: any line with emoji(s) followed by [b]...:[/b] pattern
        # Use .+ to match multi-byte emoji characters (surrogate pairs)
        if ($ln -match '^.+\[b\][^\[]*:\[/b\]') {
            $lastMetaIdx = $i
        }
        # Stop at content lines: bold title line, plot section, or narrative text
        elseif ($lastMetaIdx -ge 0) {
            $metaEndIdx = $lastMetaIdx
            break
        }
    }
    if ($metaEndIdx -lt 0 -and $lastMetaIdx -ge 0) { $metaEndIdx = $lastMetaIdx }
    if ($metaEndIdx -ge 0) {
        $metaBlock = ($descLines[0..$metaEndIdx] -join "`n").TrimEnd()
        $contentBlock = ''
        if ($metaEndIdx + 1 -lt $descLines.Count) {
            $contentBlock = ($descLines[($metaEndIdx + 1)..($descLines.Count - 1)] -join "`n").TrimStart("`n")
        }
        # Build torrent file list spoiler for the table
        $fileListSpoiler = ''
        if ($singleFile) {
            $fi = Get-Item -LiteralPath $singleFile
            $sizeGB = [math]::Round($fi.Length / 1GB, 2)
            if ($sizeGB -ge 1) { $sizeLabel = "$sizeGB GB" } elseif ($fi.Length -ge 1MB) { $sizeLabel = "$([math]::Round($fi.Length / 1MB, 2)) MB" } else { $sizeLabel = "$([math]::Round($fi.Length / 1KB, 2)) KB" }
            $ext = $fi.Extension.TrimStart('.').ToUpper()
            $summary = "[b]Summary:[/b] 1 file ($ext) | Total: $sizeLabel"
            $fileTable = "[table]`n[tr][td][b]Name[/b][/td][td][b]Size[/b][/td][/tr]`n[tr][td]${baseName}$($fi.Extension)[/td][td]${sizeLabel}[/td][/tr]`n[/table]"
            $fileListSpoiler = "`n`n[spoiler=Torrent files]`n${summary}`n`n${fileTable}`n[/spoiler]"
        } elseif (Test-Path -LiteralPath $directory -PathType Container) {
            $allFiles = Get-ChildItem -LiteralPath $directory -Recurse -File | Sort-Object FullName
            if ($allFiles.Count -gt 0) {
                $dirPrefix = $directory.TrimEnd('\') + '\'
                $rows = @()
                $totalSize = [long]0
                $typeCounts = @{}
                foreach ($f in $allFiles) {
                    $rel = $f.FullName
                    if ($rel.StartsWith($dirPrefix)) { $rel = $rel.Substring($dirPrefix.Length) }
                    $fSizeGB = [math]::Round($f.Length / 1GB, 2)
                    if ($fSizeGB -ge 1) { $fSizeLabel = "$fSizeGB GB" } elseif ($f.Length -ge 1MB) { $fSizeLabel = "$([math]::Round($f.Length / 1MB, 2)) MB" } else { $fSizeLabel = "$([math]::Round($f.Length / 1KB, 2)) KB" }
                    $rows += "[tr][td]${rel}[/td][td]${fSizeLabel}[/td][/tr]"
                    $totalSize += $f.Length
                    $ext = $f.Extension.TrimStart('.').ToUpper()
                    if (-not $ext) { $ext = 'OTHER' }
                    if ($typeCounts.ContainsKey($ext)) { $typeCounts[$ext]++ } else { $typeCounts[$ext] = 1 }
                }
                # Build summary: count by type and total size
                $typeParts = ($typeCounts.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Value) $($_.Key)" })
                $totalGB = [math]::Round($totalSize / 1GB, 2)
                if ($totalGB -ge 1) {
                    $totalLabel = "$totalGB GB"
                } elseif ($totalSize -ge 1MB) {
                    $totalLabel = "$([math]::Round($totalSize / 1MB, 2)) MB"
                } else {
                    $totalLabel = "$([math]::Round($totalSize / 1KB, 2)) KB"
                }
                $totalCount = $allFiles.Count
                $summary = "[b]Summary:[/b] $totalCount files: " + ($typeParts -join ', ') + " | Total: $totalLabel"
                $fileTable = "[table]`n[tr][td][b]Name[/b][/td][td][b]Size[/b][/td][/tr]`n" + ($rows -join "`n") + "`n[/table]"
                $fileListSpoiler = "`n`n[spoiler=Torrent files]`n${summary}`n`n${fileTable}`n[/spoiler]"
            }
        }
        $Description = "[table]`n[tr]`n[td]${posterBBCode}[/td]`n[td]`n${Header}`n`n${metaBlock}${fileListSpoiler}`n[/td]`n[/tr]`n[/table]"
        if ($contentBlock) { $Description += "`n`n`n${contentBlock}" }
        # Banner goes above the table, header is already inside it
        if ($BannerUrl) { $Description = "[center]${bannerBBCode}[/center]`n`n${Description}" }
    } else {
        # Poster available but no metadata found — fall back to normal layout
        $Preamble = ''
        if ($BannerUrl) { $Preamble = "[center]${bannerBBCode}[/center]`n`n" }
        $Preamble += "${Header}`n`n"
        $Description = "${Preamble}${Description}"
    }
} else {
    # No poster — prepend banner and header normally
    $Preamble = ''
    if ($BannerUrl) { $Preamble = "[center]${bannerBBCode}[/center]`n`n" }
    $Preamble += "${Header}`n`n"
    $Description = "${Preamble}${Description}"
}

# Add screenshots
$screenUrls = @()
if (Test-Path -LiteralPath $ScreensFile) {
    $screenUrls = @(Get-Content -LiteralPath $ScreensFile -Encoding UTF8 | ForEach-Object { $_.Trim().TrimStart([char]0xFEFF) } | Where-Object { $_ })
}
# Fallback: use IGDB screenshots for game uploads
if ($screenUrls.Count -eq 0 -and (Test-Path -LiteralPath $IgdbFile)) {
    $screenUrls = @(Get-Content -LiteralPath $IgdbFile -Encoding UTF8 | Where-Object { $_ -match '^\s+Screenshot:' } | ForEach-Object { ($_ -replace '^\s+Screenshot:\s*', '').Trim() } | Where-Object { $_ })
}
# Fallback: use AI-suggested screenshots
$aiScreenFile = Join-Path $OutDir "${TorrentName}_ai_screenshots.txt"
if ($screenUrls.Count -eq 0 -and (Test-Path -LiteralPath $aiScreenFile)) {
    $screenUrls = @(Get-Content -LiteralPath $aiScreenFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if ($screenUrls.Count -gt 0) {
    $validScreens = @()
    foreach ($url in $screenUrls) {
        if (Test-ImageUrl $url) { $validScreens += $url }
        else { Write-Host "Warning: Screenshot URL not reachable, skipping: $url" -ForegroundColor Yellow }
    }
    if ($validScreens.Count -gt 0) {
        $imgs = "[center]"
        foreach ($url in $validScreens) {
            $imgs += "[url=${url}][img=400]${url}[/img][/url]"
        }
        $imgs += "[/center]"
        $Description += "`n`n${imgs}"
    }
}

# Add keyword hashtags when no AI description (AI descriptions already contain hashtags)
if (-not (Test-Path -LiteralPath $GeminiFile) -and (Test-Path -LiteralPath $ImdbFile)) {
    $kwLine = Get-Content -LiteralPath $ImdbFile -Encoding UTF8 | Where-Object { $_ -match '^Keywords:' } | Select-Object -First 1
    if ($kwLine) {
        $kwText = ($kwLine -replace '^Keywords:\s*', '').Trim()
        $tags = ($kwText -split ',') | ForEach-Object { $_.Trim() -replace '\s+', '' } | Where-Object { $_ }
        if ($tags) {
            $hashtags = ($tags | ForEach-Object { "#$_" }) -join ' '
            $Description += "`n`n$hashtags"
        }
    }
}

# Add signature (build emoji from code point to avoid script file encoding issues)
$e_bolt = [char]::ConvertFromUtf32(0x26A1)  # lightning bolt
$sigCfg = (Get-Content -LiteralPath $configfile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json
$sigUrl = "$($sigCfg.tracker_url)/torrents?name=SCRIPT+UPLOAD3R"
$Description += "`n`n[center][url=${sigUrl}][color=#7760de][size=16]${e_bolt} Uploaded using SCRIPT UPLOAD3R ${e_bolt}[/size][/color][/url]`n[size=9][color=#5f5f5f]Shell script torrent creator/uploader for Windows proudly developed by AI[/color][/size][/center]"

# Make hashtags linkable to tracker search
if (Test-Path -LiteralPath $configfile) {
    $cfgForTracker = (Get-Content -LiteralPath $configfile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json
    $TrackerUrl = $cfgForTracker.tracker_url
    if ($TrackerUrl) {
        # Build set of ranges covered by existing [url=...]...[/url] tags
        $urlRx = [regex]'\[url=[^\]]*\].*?\[/url\]'
        $urlRanges = @($urlRx.Matches($Description) | ForEach-Object { @{ Start = $_.Index; End = $_.Index + $_.Length } })
        $rx = [regex]'(?<![=\w])#([\w][\w.\-]*[\w]|[\w]+)'
        $tagMatches = $rx.Matches($Description)
        for ($i = $tagMatches.Count - 1; $i -ge 0; $i--) {
            $m = $tagMatches[$i]
            # Skip matches inside existing [url] BBCode tags
            $insideUrl = $false
            foreach ($r in $urlRanges) { if ($m.Index -ge $r.Start -and $m.Index -lt $r.End) { $insideUrl = $true; break } }
            if ($insideUrl) { continue }
            $tag = $m.Groups[1].Value
            $encoded = [Uri]::EscapeDataString($tag)
            $link = "[url=${TrackerUrl}/torrents?description=${encoded}]#${tag}[/url]"
            $Description = $Description.Substring(0, $m.Index) + $link + $Description.Substring($m.Index + $m.Length)
        }
    }
}

[System.IO.File]::WriteAllText($TorrentDescFile, $Description + "`n", $utf8NoBom)
Write-Host "Torrent description saved to: $TorrentDescFile"

# == Build upload request file =============================================

if (-not (Test-Path -LiteralPath $configfile)) {
    Write-Host "Warning: config file '$configfile' not found, skipping request file" -ForegroundColor Yellow
    exit 0
}

$config       = (Get-Content -LiteralPath $configfile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json
$TypeId       = $config.type_id
$ResolutionId = $config.resolution_id
$Tmdb         = $config.tmdb
$Imdb         = $config.imdb
$Personal     = $config.personal
$Anonymous    = $config.anonymous

# Read categories from categories.jsonc
$CategoriesFile = Join-Path $RootDir "shared\categories.jsonc"
$categories = ([System.IO.File]::ReadAllText($CategoriesFile, $utf8NoBom) -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json

# Default: first "movie" category
$CategoryId = ($categories | Where-Object { $_.type -eq 'movie' } | Select-Object -First 1).id
if (-not $CategoryId) { $CategoryId = $categories[0].id }

# Override category and extract season/episode for TV uploads
$SeasonNumber = 0
$EpisodeNumber = 0
if ($tv.IsPresent) {
    $tvCat = $categories | Where-Object { $_.type -eq 'tv' } | Select-Object -First 1
    if ($tvCat) { $CategoryId = $tvCat.id }
    if ($TorrentName -match '(?i)S(\d{2})E(\d{2})') {
        $SeasonNumber = [int]$matches[1]
        $EpisodeNumber = [int]$matches[2]
    } elseif ($TorrentName -match '(?i)S(\d{2})') {
        $SeasonNumber = [int]$matches[1]
    }
    Write-Host "TV mode -> category_id=$CategoryId, season=$SeasonNumber, episode=$EpisodeNumber"
}

# Override category for game uploads
if ($game.IsPresent) {
    $gameCat = $categories | Where-Object { $_.type -eq 'game' } | Select-Object -First 1
    if ($gameCat) { $CategoryId = $gameCat.id }
    # Auto-detect platform from dirname
    $nl = $TorrentName.ToLower()
    if ($nl -match 'mac|osx|macos') {
        $macCat = $categories | Where-Object { $_.name -eq 'Games/Mac' }
        if ($macCat) { $CategoryId = $macCat.id }
    } elseif ($nl -match '\.iso|pc\.iso') {
        $isoCat = $categories | Where-Object { $_.name -eq 'Games/PC ISO' }
        if ($isoCat) { $CategoryId = $isoCat.id }
    } elseif ($nl -match 'ps[345]|playstation') {
        $psCat = $categories | Where-Object { $_.name -eq 'Games/PS' }
        if ($psCat) { $CategoryId = $psCat.id }
    } elseif ($nl -match 'xbox') {
        $xbCat = $categories | Where-Object { $_.name -eq 'Games/Xbox' }
        if ($xbCat) { $CategoryId = $xbCat.id }
    } elseif ($nl -match 'switch|nsw|wii|3ds|console') {
        $conCat = $categories | Where-Object { $_.name -eq 'Games/Console' }
        if ($conCat) { $CategoryId = $conCat.id }
    } else {
        # Default: PC Rip for most scene releases
        $pcCat = $categories | Where-Object { $_.name -eq 'Games/PC Rip' }
        if ($pcCat) { $CategoryId = $pcCat.id }
    }
    Write-Host "Game mode -> category_id=$CategoryId"
}

# Override category for software uploads
if ($software.IsPresent) {
    $nl = $TorrentName.ToLower()
    if ($nl -match 'mac|osx|macos') {
        $macCat = $categories | Where-Object { $_.name -eq 'Programs/Mac' }
        if ($macCat) { $CategoryId = $macCat.id }
    } elseif ($nl -match '\.iso') {
        $isoCat = $categories | Where-Object { $_.name -eq 'Programs/PC ISO' }
        if ($isoCat) { $CategoryId = $isoCat.id }
    } else {
        $otherCat = $categories | Where-Object { $_.name -eq 'Programs/Other' }
        if ($otherCat) { $CategoryId = $otherCat.id }
    }
    Write-Host "Software mode -> category_id=$CategoryId"
}

# Detect resolution from directory name
# IDs: 1=4320p 2=2160p 3=1080p 4=1080i 5=720p 6=576p 7=576i 8=480p 9=480i 10=Other
$resDetected = $false
$n = $TorrentName.ToLower()
if     ($n -match '4320p|8k')     { $ResolutionId = 1; $resDetected = $true }
elseif ($n -match '2160p|4k|uhd') { $ResolutionId = 2; $resDetected = $true }
elseif ($n -match '1080i')        { $ResolutionId = 4; $resDetected = $true }
elseif ($n -match '1080p')        { $ResolutionId = 3; $resDetected = $true }
elseif ($n -match '720p')         { $ResolutionId = 5; $resDetected = $true }
elseif ($n -match '576i')         { $ResolutionId = 7; $resDetected = $true }
elseif ($n -match '576p')         { $ResolutionId = 6; $resDetected = $true }
elseif ($n -match '480i')         { $ResolutionId = 9; $resDetected = $true }
elseif ($n -match '480p')         { $ResolutionId = 8; $resDetected = $true }

# Map width to resolution_id
function Get-ResolutionFromMediaInfo($miText) {
    $w = 0; $h = 0
    if ($miText -match '(?m)^Width\s*:\s*([\d\s]+)') {
        $w = [int](($matches[1] -replace '\s', '').Trim())
    }
    if ($miText -match '(?m)^Height\s*:\s*([\d\s]+)') {
        $h = [int](($matches[1] -replace '\s', '').Trim())
    }
    if ($w -eq 0 -and $h -eq 0) { return $null }
    if ($w -ge 7000) { return @{ id = 1; label = "${w}x${h} -> 4320p" } }
    if ($w -ge 3000) { return @{ id = 2; label = "${w}x${h} -> 2160p" } }
    if ($w -ge 1800) { return @{ id = 3; label = "${w}x${h} -> 1080p" } }
    if ($w -ge 1200) { return @{ id = 5; label = "${w}x${h} -> 720p" } }
    if ($w -ge 700)  { if ($h -ge 560) { return @{ id = 6; label = "${w}x${h} -> 576p" } } else { return @{ id = 8; label = "${w}x${h} -> 480p" } } }
    return @{ id = 10; label = "${w}x${h} -> Other" }
}

# Fallback: detect from MediaInfo file
if (-not $resDetected -and (Test-Path -LiteralPath $MediainfoFile)) {
    $miContent = Get-Content -LiteralPath $MediainfoFile -Raw
    $res = Get-ResolutionFromMediaInfo $miContent
    if ($res) {
        $ResolutionId = $res.id; $resDetected = $true
        Write-Host "Detected resolution from MediaInfo file: $($res.label) -> resolution_id=$ResolutionId"
    }
}

# Fallback: run MediaInfo.exe directly
if (-not $resDetected) {
    $MediaInfoExe = Join-Path $RootDir "tools\MediaInfo.exe"
    if (Test-Path -LiteralPath $MediaInfoExe) {
        if ($singleFile) {
            $vf = Get-Item -LiteralPath $singleFile
        } else {
            $videoExts = @('.mkv', '.mp4', '.avi', '.ts')
            $vf = Get-ChildItem -LiteralPath $directory -Recurse -File |
                Where-Object { ($videoExts -contains $_.Extension.ToLower()) -and ($_.FullName -notmatch 'sample|trailer|featurette') } |
                Select-Object -First 1
        }
        if ($vf) {
            $miOut = (& $MediaInfoExe $vf.FullName) -join "`n"
            $res = Get-ResolutionFromMediaInfo $miOut
            if ($res) {
                $ResolutionId = $res.id; $resDetected = $true
                Write-Host "Detected resolution from video file: $($res.label) -> resolution_id=$ResolutionId"
            }
        }
    }
}

if ($resDetected) { Write-Host "Resolution: resolution_id=$ResolutionId" }

# Detect type from directory/file name
# IDs: 1=Full Disc 2=Remux 3=Encode 4=WEB-DL 5=WEBRip 6=HDTV
$typeDetected = $false
if     ($n -match 'remux')              { $TypeId = 2; $typeDetected = $true }
elseif ($n -match 'web-dl|webdl')       { $TypeId = 4; $typeDetected = $true }
elseif ($n -match 'webrip|web\.rip')    { $TypeId = 5; $typeDetected = $true }
elseif ($n -match '\bweb\b')            { $TypeId = 5; $typeDetected = $true }
elseif ($n -match 'hdtv')              { $TypeId = 6; $typeDetected = $true }
elseif ($n -match 'bdmv|disc|\.iso')   { $TypeId = 1; $typeDetected = $true }
if ($typeDetected) { Write-Host "Detected type: type_id=$TypeId" }

# For TV: upgrade to Series/HD (category_id=12) if resolution > 700p
if ($tv.IsPresent -and $resDetected -and $ResolutionId -ge 1 -and $ResolutionId -le 5) {
    $CategoryId = 12
    Write-Host "TV HD detected -> category_id=$CategoryId (Series/HD)"
}

# Override TMDB/IMDB IDs from output file if available
if (Test-Path -LiteralPath $ImdbFile) {
    $imdbContent2 = Get-Content -LiteralPath $ImdbFile -Encoding UTF8
    $tmdbLine = $imdbContent2 | Where-Object { $_ -match '^TMDB ID:' } | Select-Object -First 1
    $imdbLine = $imdbContent2 | Where-Object { $_ -match '^IMDB ID:' } | Select-Object -First 1
    if ($tmdbLine) { $Tmdb = ($tmdbLine -replace '^TMDB ID:\s*', '').Trim() }
    if ($imdbLine) { $Imdb = ($imdbLine -replace '^IMDB ID:\s*tt', '').Trim() }
}

# IGDB ID and URL already read earlier

# Build upload name: UNIT3D convention or raw torrent name based on config
$cfgForName = (Get-Content -LiteralPath $configfile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json
$nameConvention = if ($cfgForName.PSObject.Properties['name_convention']) { $cfgForName.name_convention } else { 1 }

if ($game.IsPresent -or $software.IsPresent) {
    # Games/Software: use raw torrent name, just replace dots/underscores
    $UploadName = $TorrentName -replace '[._]', ' ' -replace '\s+', ' ' -replace '--+', '-'
    $UploadName = $UploadName.Trim()
} elseif ($nameConvention -eq 1) {
    # UNIT3D format: "Title Year Edition Resolution Source Codec Audio-Group"
    # Preserve channel notation (e.g. DDP5.1, 7.1, 5.1) and codec versions (H.264, H.265) before replacing dots
    $placeholder = [string][char]0x00B7
    $n_up = $TorrentName -replace '(\d)\.(1|2|264|265)\b', "`$1${placeholder}`$2"
    $n_up = $n_up -replace '[._]', ' '
    $n_up = $n_up -replace [char]0x00B7, '.'
    # Extract technical part: everything after year (or season tag for TV)
    $techPart = ''
    if ($n_up -match '(?i)\b(19|20)\d{2}\b[)\]]?\s*(.+)$') {
        $techPart = $matches[2].Trim()
    } elseif ($n_up -match '(?i)\b[Ss]\d{2}(?:\s*-\s*[Ss]\d{2}|[Ee]\d+)?\s+(.+)$') {
        $techPart = $matches[1].Trim()
    } elseif ($n_up -match '(?i)\b((2160|1080|720|480|360)[pi]\b.+)$') {
        $techPart = $matches[1].Trim()
    } elseif ($n_up -match '(?i)\b(WEBRip|WEB-DL|WEBDL|BluRay|BDRip|BRRip|HDRip|HDTV|DVDRip|REMUX)\b(.*)$') {
        $techPart = ($matches[1] + $matches[2]).Trim()
    }
    # Strip brackets/parentheses attached to text (scene tags like -iKA[EtHD]) — remove entirely
    $techPart = $techPart -replace '(?<=\w)\[([^\]]+)\]', ''
    $techPart = $techPart -replace '(?<=\w)\(([^)]+)\)', ''
    # Normalize malformed bracket/paren mixing: )[  ](  ){  }( etc. → space
    $techPart = $techPart -replace '[)\]}]\s*[(\[{]', ' '
    # Strip stray braces
    $techPart = $techPart -replace '[{}]', ''
    # Strip standalone brackets/parentheses: [1080p] -> 1080p, (1080p ...) -> 1080p ...
    $techPart = $techPart -replace '\[([^\]]+)\]', '$1'
    $techPart = $techPart -replace '\(([^)]+)\)', '$1'
    # Strip remaining unmatched brackets/parens
    $techPart = $techPart -replace '[()\[\]]', ''
    # Remove redundant "Season N" text (already covered by S## tag)
    $techPart = $techPart -replace '(?i)\bSeason\s+\d+\b', ''
    # Normalize common source names (before group detection to avoid double-hyphen issues)
    $techPart = $techPart -replace '(?i)\bBluRay\b', 'Blu-ray'
    $techPart = $techPart -replace '(?i)\bBRRip\b', 'BRRip'
    $techPart = $techPart -replace '(?i)\bWEB[-\s]?DL\b', 'WEB-DL'
    $techPart = $techPart -replace '(?i)\bWEBRip\b', 'WEBRip'
    $techPart = $techPart -replace '(?i)\bHDTV\b', 'HDTV'
    # Normalize audio codecs
    $techPart = $techPart -replace '(?i)\bDDP\b', 'DDP'
    $techPart = $techPart -replace '(?i)\bDD\b', 'DD'
    $techPart = $techPart -replace '(?i)\bAAC\b', 'AAC'
    $techPart = $techPart -replace '(?i)\bEAC3\b', 'EAC3'
    $techPart = $techPart -replace '(?i)\bAC3\b', 'AC3'
    $techPart = $techPart -replace '(?i)\bDTS\b', 'DTS'
    $techPart = $techPart -replace '(?i)\bFLAC\b', 'FLAC'
    # Fix resolution with spaces: "1080 p" -> "1080p", "720 P" -> "720p"
    $techPart = $techPart -replace '(?i)\b(480|720|1080|2160)\s+p\b', '$1p'
    # Fix channel notation with spaces: "5 1" -> "5.1", "7 1" -> "7.1"
    $techPart = $techPart -replace '(\d) (\d)\b', '$1.$2'
    # Fix codec notation with spaces: "H 264" -> "H264", "H 265" -> "H265"
    $techPart = $techPart -replace '(?i)\bH\s+(264|265)\b', 'H$1'
    # Fix bit depth: "10 bit" -> "10bit", "8 bit" -> "8bit"
    $techPart = $techPart -replace '(?i)\b(\d+)\s+bit\b', '$1bit'
    # Convert last word to release group if no hyphen-group present
    if ($techPart -notmatch '-\S+$') {
        # Multi-word groups like YTS MX
        $techPart = $techPart -replace '\s+(YTS\s+\w+)\s*$', '-$1'
        $techPart = $techPart -replace '(?<=-YTS)\s+', '.'
        # Single-word group: last token becomes -GROUP (skip known codecs/formats)
        if ($techPart -notmatch '-\S+$' -and $techPart -match '\s+(\S+)\s*$') {
            $lastToken = $matches[1]
            $knownTags = 'x264|x265|H264|H265|H\.264|H\.265|HEVC|AVC|AAC|AC3|EAC3|DTS|FLAC|HDTV|WEBRip|WEB-DL|Blu-ray|BDRip|BRRip|DDP5\.1|DDP2\.0|10bit|8bit|HDR|DV|MULTI|REMASTERED|PROPER|REMUX|720p|1080p|2160p|480p'
            if ($lastToken -notmatch "^(?i)($knownTags)$") {
                $techPart = $techPart -replace '\s+(\S+)\s*$', '-$1'
            }
        }
    }
    $techPart = ($techPart -replace '\s+', ' ').Trim()
    # Build title part — strip colons from TMDB title (not used in torrent naming)
    # If TMDB title contains non-Latin chars (e.g. Cyrillic), use Latin name from filename instead
    if ($TmdbEnTitle -and $TmdbEnTitle -notmatch '[\p{IsCyrillic}]') {
        $titlePart = $TmdbEnTitle -replace ':\s*', ' - ' -replace '/', '-'
    } else {
        $titlePart = $EnTitle -replace ':\s*', ' - ' -replace '/', '-'
    }
    # Extract season/episode tag for TV
    $seasonTag = ''
    if ($TorrentName -match '(?i)(S\d{2}(?:\s*-\s*S\d{2}|E\d{2})?)') {
        $seasonTag = $matches[1].ToUpper()
        # Remove season tag from techPart to avoid duplication
        $techPart = ($techPart -replace '(?i)\bS\d{2}(?:\s*-\s*S\d{2}|E\d{2})?\b', '').Trim()
        # Clean up orphaned leading hyphen left after season tag removal (e.g. "-S01 tech" → "- tech")
        $techPart = $techPart -replace '^-\s*', ''
    }
    # Assemble: Title Year [Season] TechPart
    $nameParts = @($titlePart)
    if ($Year -and $Year -ne '????') { $nameParts += $Year }
    if ($seasonTag) { $nameParts += $seasonTag }
    if ($techPart) { $nameParts += $techPart }
    $UploadName = ($nameParts -join ' ') -replace '\s+', ' ' -replace '--+', '-'
} else {
    # Raw torrent name (no formatting)
    $UploadName = $TorrentName -replace '--+', '-'
}
if (-not $game.IsPresent -and -not $software.IsPresent -and $BgTitle -and $BgTitle -ne $EnTitle -and $BgTitle -ne $TmdbEnTitle) {
    $UploadName = "$UploadName / $BgTitle ($Year)"
}

# Detect Bulgarian audio/subtitles from MediaInfo sections (skip for games)
$bgAudio = $false
$bgSubs = $false
if (Test-Path -LiteralPath $MediainfoFile) {
    $section = ''
    foreach ($line in Get-Content -LiteralPath $MediainfoFile) {
        if ($line -match '^Audio')                    { $section = 'audio' }
        elseif ($line -match '^Text')                 { $section = 'text' }
        elseif ($line -match '^(Video|Menu|General)') { $section = 'other' }
        if ($line -match '(?i)Language\s*:.*Bulgarian') {
            if ($section -eq 'audio') { $bgAudio = $true }
            if ($section -eq 'text')  { $bgSubs = $true }
        }
    }
}
# Check for external Bulgarian subtitle files if not found in MediaInfo
$bgSrtGt = $false
if (-not $bgSubs) {
    $srtFiles = Get-ChildItem -LiteralPath $directory -Recurse -File -Filter '*.srt' -ErrorAction SilentlyContinue
    foreach ($srt in $srtFiles) {
        if ($srt.Name -match '(?i)\.bg\.|\.bul\.|bulgarian|\.bgforced\.' -or $srt.FullName -match '(?i)[/\\]bg[/\\]|[/\\]bul[/\\]') {
            $bgSubs = $true
            if ($srt.Name -match '\.GT') { $bgSrtGt = $true }
            break
        }
    }
}

$bgFlag = [char]::ConvertFromUtf32(0x1F1E7) + [char]::ConvertFromUtf32(0x1F1EC)
$bgTags = ''
if ($bgSubs) {
    $abcd = [char]::ConvertFromUtf32(0x1F524)
    $robot = ''
    if ($bgSrtGt) {
        $robot = [char]::ConvertFromUtf32(0x1F916)
    }
    $bgTags = "${robot}${bgFlag}${abcd}"
    Write-Host "Bulgarian subtitles detected"
}
if ($bgAudio) {
    $speaker = [char]::ConvertFromUtf32(0x1F50A)
    $bgTags = "${bgTags}${bgFlag}${speaker}"
    Write-Host "Bulgarian audio detected"
}
if ($bgTags) { $UploadName = "${UploadName} ${bgTags}" }
Write-Host "Upload name: $UploadName"

# Write request file
$requestLines = @(
    "torrent_name=$TorrentName"
    "name=$UploadName"
    "category_id=$CategoryId"
    "type_id=$TypeId"
    "resolution_id=$ResolutionId"
    "tmdb=$Tmdb"
    "imdb=$Imdb"
    "igdb=$Igdb"
    "personal=$Personal"
    "anonymous=$Anonymous"
    "season_number=$SeasonNumber"
    "episode_number=$EpisodeNumber"
    "poster=$PosterUrl"
    "description_file=$TorrentDescFile"
    "mediainfo_file=$MediainfoFile"
)
[System.IO.File]::WriteAllText($RequestFile, ($requestLines -join "`n") + "`n", $utf8NoBom)
Write-Host "Upload request saved to: $RequestFile"
