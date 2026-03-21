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
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$directory,

    [Parameter(Position = 1)]
    [string]$configfile,

    [switch]$tv
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
$GeminiFile      = Join-Path $OutDir "${TorrentName}_description.txt"
$ImdbFile        = Join-Path $OutDir "${TorrentName}_imdb.txt"
$TmdbFile        = Join-Path $OutDir "${TorrentName}_tmdb.txt"
$ScreensFile     = Join-Path $OutDir "${TorrentName}_screens.txt"
$TorrentDescFile = Join-Path $OutDir "${TorrentName}_torrent_description.txt"
$MediainfoFile   = Join-Path $OutDir "${TorrentName}_mediainfo.txt"
$RequestFile     = Join-Path $OutDir "${TorrentName}_upload_request.txt"

# Build title header from directory name (avoids encoding issues with special chars)
$EnTitle = $TorrentName -replace '[._]', ' ' -replace ' - [Ss]\d{2}.*', '' -replace '\b[Ss]\d{2}.*', '' -replace '\b(19|20)\d{2}\b.*', '' -replace ' - WEBDL.*', '' -replace ' - WEB-DL.*', '' -replace '[\s([]+$', ''
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
if (-not $Year) { $Year = '????' }

# Get BG title, EN title, and banner from TMDB file
$BgTitle = ''
$TmdbEnTitle = ''
$BannerUrl = ''
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
}

$enHeader = if ($TmdbEnTitle) { $TmdbEnTitle } else { $EnTitle }
if ($BgTitle -and $BgTitle -ne $enHeader) {
    $Header = "[size=26][b]${enHeader} (${Year}) / ${BgTitle} (${Year})[/b][/size]"
} else {
    $Header = "[size=26][b]${enHeader} (${Year})[/b][/size]"
}

# Build description body
$Description = ''

$TmdbBgDesc = ''
if (Test-Path -LiteralPath $TmdbFile) {
    $tmdbLines = Get-Content -LiteralPath $TmdbFile -Encoding UTF8
    $bgDescLine = $tmdbLines | Where-Object { $_ -match '^\s+\(bg\):' } | Select-Object -First 1
    if ($bgDescLine) { $TmdbBgDesc = ($bgDescLine -replace '^\s+\(bg\):\s*', '').Trim() }
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
    # Find insertion point: last RT line, or IMDB rating line, or genre line
    $insertIdx = -1
    for ($i = 0; $i -lt $descLines.Count; $i++) {
        if ($descLines[$i] -match '\[b\].*RT\s|RT\s.*\[/b\]') { $insertIdx = $i }
    }
    if ($insertIdx -lt 0) {
        for ($i = 0; $i -lt $descLines.Count; $i++) {
            if ($descLines[$i] -match '\[b\].{0,15}:\[/b\].*\d+/10') { $insertIdx = $i; break }
        }
    }
    if ($insertIdx -lt 0) {
        $bgGenre2 = [char]0x0416 + [char]0x0430 + [char]0x043D + [char]0x0440  # Жанр
        for ($i = 0; $i -lt $descLines.Count; $i++) {
            if ($descLines[$i] -match '\[b\].{0,15}(Genres|Genre|Runtime|Countries)' -or $descLines[$i].Contains($bgGenre2)) { $insertIdx = $i }
            elseif ($insertIdx -ge 0) { break }
        }
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

# Prepend banner and header
$Preamble = ''
if ($BannerUrl) { $Preamble = "[center][img=1920]${BannerUrl}[/img][/center]`n`n" }
$Preamble += "${Header}`n`n"
$Description = "${Preamble}${Description}"

# Add screenshots
if (Test-Path -LiteralPath $ScreensFile) {
    $urls = Get-Content -LiteralPath $ScreensFile -Encoding UTF8
    $imgs = "[center]"
    foreach ($url in $urls) {
        $url = $url.Trim().TrimStart([char]0xFEFF)
        if ($url) { $imgs += "[url=${url}][img=400]${url}[/img][/url]" }
    }
    $imgs += "[/center]"
    $Description += "`n`n${imgs}"
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
        $rx = [regex]'(?<![=\w])#([\w][\w.\-]*[\w]|[\w]+)'
        $tagMatches = $rx.Matches($Description)
        for ($i = $tagMatches.Count - 1; $i -ge 0; $i--) {
            $m = $tagMatches[$i]
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

# Build upload name: append BG title if available
$UploadName = $TorrentName
if ($BgTitle) {
    $UploadName = "$TorrentName / $BgTitle ($Year)"
}

# Detect Bulgarian audio/subtitles from MediaInfo sections
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
    "personal=$Personal"
    "anonymous=$Anonymous"
    "season_number=$SeasonNumber"
    "episode_number=$EpisodeNumber"
)
[System.IO.File]::WriteAllText($RequestFile, ($requestLines -join "`n") + "`n", $utf8NoBom)
Write-Host "Upload request saved to: $RequestFile"
