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

    [switch]$music,

    [string]$poster,

    [string]$year
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

# ── Torrent file parser (bencode) ──────────────────────────────────────────
function Bdecode-Desc([byte[]]$data, [ref]$pos) {
    $c = [char]$data[$pos.Value]
    if ($c -eq 'i') {
        $pos.Value++
        $s = $pos.Value
        while ([char]$data[$pos.Value] -ne 'e') { $pos.Value++ }
        $v = [System.Text.Encoding]::UTF8.GetString($data, $s, $pos.Value - $s)
        $pos.Value++
        return [long]$v
    } elseif ($c -eq 'l') {
        $pos.Value++
        $a = @()
        while ([char]$data[$pos.Value] -ne 'e') { $a += ,(Bdecode-Desc $data $pos) }
        $pos.Value++
        return ,$a
    } elseif ($c -eq 'd') {
        $pos.Value++
        $h = [ordered]@{}
        while ([char]$data[$pos.Value] -ne 'e') {
            $k = Bdecode-Desc $data $pos
            $v = Bdecode-Desc $data $pos
            $h[$k] = $v
        }
        $pos.Value++
        return $h
    } else {
        $s = $pos.Value
        while ([char]$data[$pos.Value] -ne ':') { $pos.Value++ }
        $len = [int][System.Text.Encoding]::UTF8.GetString($data, $s, $pos.Value - $s)
        $pos.Value++
        $str = [System.Text.Encoding]::UTF8.GetString($data, $pos.Value, $len)
        $pos.Value += $len
        return $str
    }
}

# ── Audio duration from file metadata ───────────────────────────────────────
# Reads the FLAC STREAMINFO block directly (fLaC magic -> block headers ->
# type 0 == STREAMINFO) and computes duration = totalSamples * 1000 / sampleRate.
# Returns duration in milliseconds or 0 if the format is unsupported / unreadable.
function Get-AudioDurationMs {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $br = New-Object System.IO.BinaryReader($fs)
            # FLAC files start with "fLaC"
            $magic = $br.ReadBytes(4)
            if ($magic.Length -lt 4 -or $magic[0] -ne 0x66 -or $magic[1] -ne 0x4C -or $magic[2] -ne 0x61 -or $magic[3] -ne 0x43) {
                return 0
            }
            while ($fs.Position -lt $fs.Length) {
                $header = $br.ReadBytes(4)
                if ($header.Length -lt 4) { return 0 }
                $isLast = ($header[0] -band 0x80) -ne 0
                $blockType = $header[0] -band 0x7F
                $blockLen = ([int]$header[1] -shl 16) -bor ([int]$header[2] -shl 8) -bor [int]$header[3]
                if ($blockType -eq 0) {
                    # STREAMINFO: skip 10 bytes (min/max block + min/max frame), read 8 bytes packed
                    if ($blockLen -lt 18) { return 0 }
                    $null = $br.ReadBytes(10)
                    $packed = $br.ReadBytes(8)
                    if ($packed.Length -lt 8) { return 0 }
                    # 20 bits sample rate | 3 bits channels | 5 bits bps | 36 bits total samples
                    $sampleRate = ([int]$packed[0] -shl 12) -bor ([int]$packed[1] -shl 4) -bor (([int]$packed[2] -shr 4) -band 0x0F)
                    $totalSamples = ([uint64]($packed[3] -band 0x0F) -shl 32) `
                                  -bor ([uint64]$packed[4] -shl 24) `
                                  -bor ([uint64]$packed[5] -shl 16) `
                                  -bor ([uint64]$packed[6] -shl 8) `
                                  -bor  [uint64]$packed[7]
                    if ($sampleRate -le 0 -or $totalSamples -eq 0) { return 0 }
                    return [long](($totalSamples * [uint64]1000) / [uint64]$sampleRate)
                }
                # Skip over this block
                $null = $br.ReadBytes($blockLen)
                if ($isLast) { break }
            }
            return 0
        } finally {
            $fs.Dispose()
        }
    } catch {
        return 0
    }
}

# Load config once (used throughout for templates, signature, hashtags, upload)
$cfg = $null
if (Test-Path -LiteralPath $configfile) {
    $cfg = (Get-Content -LiteralPath $configfile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json
}

# ── Template engine ─────────────────────────────────────────────────────────
# Supports {{VAR}} substitution and {{#VAR}}...{{/VAR}} conditional sections.
# Conditional sections are included only when VAR is non-empty.
function Expand-Template {
    param([string]$Template, [hashtable]$Vars)
    $result = $Template
    # Process conditional sections first: {{#VAR}}content{{/VAR}}
    foreach ($key in $Vars.Keys) {
        $open  = "{{#${key}}}"
        $close = "{{/${key}}}"
        while ($result.Contains($open)) {
            $s = $result.IndexOf($open)
            $e = $result.IndexOf($close, $s)
            if ($e -lt 0) { break }
            $inner = $result.Substring($s + $open.Length, $e - $s - $open.Length)
            if ($Vars[$key]) {
                $result = $result.Substring(0, $s) + $inner + $result.Substring($e + $close.Length)
            } else {
                $result = $result.Substring(0, $s) + $result.Substring($e + $close.Length)
            }
        }
    }
    # Replace simple {{VAR}} placeholders
    foreach ($key in $Vars.Keys) {
        $result = $result.Replace("{{${key}}}", [string]$Vars[$key])
    }
    # Collapse 3+ consecutive blank lines to 2
    $result = [regex]::Replace($result, '(\r?\n\s*){3,}', "`n`n")
    return $result.Trim()
}

function Get-TemplateContent {
    param([string]$ConfigKey, [string]$DefaultPath)
    $tmplPath = ''
    if ($cfg -and $cfg.PSObject.Properties.Match($ConfigKey).Count -gt 0) {
        $tmplPath = $cfg.$ConfigKey
    }
    if (-not $tmplPath) { $tmplPath = $DefaultPath }
    if (-not [System.IO.Path]::IsPathRooted($tmplPath)) {
        $tmplPath = Join-Path $RootDir $tmplPath
    }
    if (Test-Path -LiteralPath $tmplPath) {
        return [System.IO.File]::ReadAllText($tmplPath, [System.Text.Encoding]::UTF8)
    }
    return $null
}

# Pre-load all templates
$tmplLayoutPoster   = Get-TemplateContent 'template_layout_poster'    'templates/layout_poster.bbcode'
$tmplLayoutNoPoster = Get-TemplateContent 'template_layout_no_poster' 'templates/layout_no_poster.bbcode'
$tmplFallbackMovie  = Get-TemplateContent 'template_fallback_movie'   'templates/fallback_movie.bbcode'
$tmplScreenshots    = Get-TemplateContent 'template_screenshots'      'templates/screenshots.bbcode'

$TorrentName = $baseName
$GeminiFile      = Join-Path $OutDir "${TorrentName}_description.bbcode"
$ImdbFile        = Join-Path $OutDir "${TorrentName}_imdb.txt"
$TmdbFile        = Join-Path $OutDir "${TorrentName}_tmdb.txt"
$IgdbFile        = Join-Path $OutDir "${TorrentName}_igdb.txt"
$MbFile          = Join-Path $OutDir "${TorrentName}_music.txt"
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
# For music: year from metadata OVERRIDES dirname year (dirname year can be wrong)
# For other types: fallback only when no year detected
if (Test-Path -LiteralPath $MbFile) {
    $mbLines = Get-Content -LiteralPath $MbFile -Encoding UTF8 | ForEach-Object { $_ -replace '^\xEF\xBB\xBF', '' }
    $mbYear = $null
    # Try [1] header line first
    $mbFirst = $mbLines | Where-Object { $_ -match '^\[1\]' } | Select-Object -First 1
    if ($mbFirst -and $mbFirst -match '\((\d{4})\)') { $mbYear = $matches[1] }
    # Try Released: line from details section (Deezer doesn't include year in search results)
    if (-not $mbYear) {
        $relLine = $mbLines | Where-Object { $_ -match '^\s+Released:' } | Select-Object -First 1
        if ($relLine -and $relLine -match '(\d{4})') { $mbYear = $matches[1] }
    }
    if ($mbYear) {
        if ($music.IsPresent) { $Year = $mbYear }
        elseif (-not $Year) { $Year = $mbYear }
    }
}
# Fallback: extract year from AI-generated description
if (-not $Year -and (Test-Path -LiteralPath $GeminiFile)) {
    $descContent = Get-Content -LiteralPath $GeminiFile -Encoding UTF8 -TotalCount 10
    foreach ($dl in $descContent) {
        if ($dl -match '\((\d{4})\)') { $Year = $matches[1]; break }
    }
}
# User-provided year override (from -year parameter)
if ($year -and $year -match '^\d{4}$') { $Year = $year }
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

# Fallback: read title and cover from music metadata file (for music uploads)
if (-not $TmdbEnTitle -and (Test-Path -LiteralPath $MbFile)) {
    $musicContent2 = Get-Content -LiteralPath $MbFile -Encoding UTF8
    $musicFirstLine = $musicContent2 | Where-Object { $_ -match '^\[1\]' } | Select-Object -First 1
    if ($musicFirstLine -and $musicFirstLine -match '^\[1\]\s+(.+?)\s+\(\d{4}\)$') { $TmdbEnTitle = $matches[1] }
    if (-not $TmdbEnTitle -and $musicFirstLine -and $musicFirstLine -match '^\[1\]\s+(.+)$') { $TmdbEnTitle = $matches[1] }
    if (-not $PosterUrl) {
        $coverLine = $musicContent2 | Where-Object { $_ -match '^\s+Cover:' } | Select-Object -First 1
        if ($coverLine) { $PosterUrl = ($coverLine -replace '^\s+Cover:\s*', '').Trim() }
    }
}

# Override poster with user-provided value (URL or local file path)
if ($poster) {
    if ($poster -match '^https?://') {
        $PosterUrl = $poster
    } elseif (Test-Path -LiteralPath $poster -PathType Leaf) {
        # Upload local file to onlyimage.org
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

# Override header for games/software/music with clean name + version
if ($game.IsPresent -or $software.IsPresent -or $music.IsPresent) {
    $swName = $TorrentName
    if ($music.IsPresent) {
        # Music: strip square brackets [FLAC 24-44], curly braces, keep parentheses (part of title)
        $swName = $swName -replace '\s*\[[^\]]+\]\s*', ' '
        $swName = $swName -replace '\s*\{[^}]+\}\s*', ' '
        $swName = $swName -replace '[._]', ' '
        # Remove music format/quality tags
        $swName = $swName -replace '(?i)\b(FLAC|MP3|AAC|OGG|OPUS|WEB|CD|VINYL|LP|Lossless|320|V0|V2|CBR|VBR|16bit|24bit|16-44|24-48|24-96|24-192|Hi-?Res)\b', ' '
        # Remove scene group tags at end
        $swName = $swName -replace '(?i)\s*[-](PERFECT|FATHEAD|ENRiCH|YARD|WRE|dL|AMRAP|JLM|D2H|FiH|NBFLAC|DGN|TOSK|ERP)\s*$', ''
        # Remove year from end — bare or parenthesized (will be added back via $yearSuffix)
        $swName = $swName -replace '\s+\(?(19|20)\d{2}\)?\s*$', ''
    } else {
        # Games: use IGDB title if available
        if ($game.IsPresent -and $TmdbEnTitle) {
            $swName = $TmdbEnTitle
        } else {
            # Software (or game without IGDB): clean dirname
            $swName = $swName -replace '\s*[\[\(\{][^\]\)\}]+[\]\)\}]\s*', ' '
            $swName = $swName -replace '[\s_]', '.'
            $swName = $swName -replace '(?i)[-\.]by[-\.].+$', ''
            $swName = $swName -replace '(?i)[-\.](RePack|Repack|Portable|Cracked|Patched|PreActivated|Activated)[-\.]?', ''
            # Remove scene release group (trailing -GROUPNAME, any group)
            $swName = $swName -replace '-[A-Za-z][A-Za-z0-9]+$', ''
            $swName = $swName -replace '(?i)[-\.](WinAll|Multilingual|x64|x86|Win64|Win32|macOS|Linux)[-\.]?', ''
            $swName = $swName -replace '[._]', ' '
            $swName = [regex]::Replace($swName, '(?<=\d) (?=\d)', '.')
        }
    }
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
    # Strip empty year lines from AI music descriptions (year is inserted programmatically)
    if ($music.IsPresent) {
        $Description = ($Description -split "`n" | Where-Object { $_ -notmatch '^\s*.{0,4}\[b\].{0,20}(Year|Година)\S*:\[/b\]\s*$' }) -join "`n"
    }
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

    if ($tmplFallbackMovie) {
        $Description = Expand-Template $tmplFallbackMovie @{
            'GENRES'         = [string]$genres
            'RATING'         = [string]$rating
            'TITLE'          = [string]$title
            'TAGLINE'        = [string]$tagline
            'OVERVIEW'       = [string]$overview
            'BG_DESCRIPTION' = [string]$TmdbBgDesc
            'DIRECTOR'       = [string]$director
            'CAST'           = [string]$cast
        }
    } else {
        # Hardcoded fallback (PS5.1 encoding safety)
        $e_genre   = [char]::ConvertFromUtf32(0x1F3AD)
        $e_star    = [char]::ConvertFromUtf32(0x2B50)
        $e_plot    = [char]::ConvertFromUtf32(0x1F4D6)
        $e_people  = [char]::ConvertFromUtf32(0x1F465)
        $e_dir     = [char]::ConvertFromUtf32(0x1F3AC)
        $e_globe   = [char]::ConvertFromUtf32(0x1F30D)

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
    }
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

# Read music metadata from music file if available (for music uploads)
$MusicMetaId = ''
$MusicMetaUrl = ''
$MusicMetaSource = ''
$MusicLabel = ''
$MusicDuration = ''
$DiscogsId = ''
if (Test-Path -LiteralPath $MbFile) {
    $mbContent3 = Get-Content -LiteralPath $MbFile -Encoding UTF8
    # Always extract a Discogs ID if present (independent of the "primary" source),
    # so upload.ps1 can include it as a dedicated field on music uploads.
    $discogsIdAny = $mbContent3 | Where-Object { $_ -match '^\s+Discogs ID:' } | Select-Object -First 1
    if ($discogsIdAny) { $DiscogsId = ($discogsIdAny -replace '^\s+Discogs ID:\s*', '').Trim() }
    # Try Deezer first
    $deezerIdLine = $mbContent3 | Where-Object { $_ -match '^\s+Deezer ID:' } | Select-Object -First 1
    $deezerUrlLine = $mbContent3 | Where-Object { $_ -match '^\s+Deezer URL:' } | Select-Object -First 1
    if ($deezerIdLine) {
        $MusicMetaId = ($deezerIdLine -replace '^\s+Deezer ID:\s*', '').Trim()
        $MusicMetaSource = 'Deezer'
    }
    if ($deezerUrlLine) { $MusicMetaUrl = ($deezerUrlLine -replace '^\s+Deezer URL:\s*', '').Trim() }
    # Fallback to Discogs
    if (-not $MusicMetaId) {
        $discogsIdLine = $mbContent3 | Where-Object { $_ -match '^\s+Discogs ID:' } | Select-Object -First 1
        if ($discogsIdLine) {
            $MusicMetaId = ($discogsIdLine -replace '^\s+Discogs ID:\s*', '').Trim()
            $MusicMetaSource = 'Discogs'
        }
        $discogsUrlLine = $mbContent3 | Where-Object { $_ -match '^\s+Discogs URL:' } | Select-Object -First 1
        if ($discogsUrlLine) { $MusicMetaUrl = ($discogsUrlLine -replace '^\s+Discogs URL:\s*', '').Trim() }
    }
    # Fallback to MusicBrainz
    if (-not $MusicMetaId) {
        $mbIdLine = $mbContent3 | Where-Object { $_ -match '^\s+MBID:' } | Select-Object -First 1
        if ($mbIdLine) {
            $MusicMetaId = ($mbIdLine -replace '^\s+MBID:\s*', '').Trim()
            $MusicMetaSource = 'MusicBrainz'
        }
        $mbUrlLine = $mbContent3 | Where-Object { $_ -match '^\s+MB URL:' } | Select-Object -First 1
        if ($mbUrlLine) { $MusicMetaUrl = ($mbUrlLine -replace '^\s+MB URL:\s*', '').Trim() }
    }
    # Fallback to Last.fm
    if (-not $MusicMetaId) {
        $lastfmUrlLine = $mbContent3 | Where-Object { $_ -match '^\s+Last\.fm URL:' } | Select-Object -First 1
        if ($lastfmUrlLine) {
            $MusicMetaUrl = ($lastfmUrlLine -replace '^\s+Last\.fm URL:\s*', '').Trim()
            $MusicMetaSource = 'Last.fm'
            $MusicMetaId = ($MusicMetaUrl -split '/')[-1]
        }
    }
    # Fallback to AudioDB
    if (-not $MusicMetaId) {
        $adbIdLine = $mbContent3 | Where-Object { $_ -match '^\s+AudioDB ID:' } | Select-Object -First 1
        if ($adbIdLine) {
            $MusicMetaId = ($adbIdLine -replace '^\s+AudioDB ID:\s*', '').Trim()
            $MusicMetaSource = 'AudioDB'
            $MusicMetaUrl = "https://www.theaudiodb.com/album/${MusicMetaId}"
        }
    }
    # Fallback to iTunes
    if (-not $MusicMetaId) {
        $itunesIdLine = $mbContent3 | Where-Object { $_ -match '^\s+iTunes ID:' } | Select-Object -First 1
        if ($itunesIdLine) {
            $MusicMetaId = ($itunesIdLine -replace '^\s+iTunes ID:\s*', '').Trim()
            $MusicMetaSource = 'iTunes'
        }
        $itunesUrlLine = $mbContent3 | Where-Object { $_ -match '^\s+iTunes URL:' } | Select-Object -First 1
        if ($itunesUrlLine) { $MusicMetaUrl = ($itunesUrlLine -replace '^\s+iTunes URL:\s*', '').Trim() }
    }
    # Read label and duration
    $labelLine = $mbContent3 | Where-Object { $_ -match '^\s+Label:' } | Select-Object -First 1
    if ($labelLine) { $MusicLabel = ($labelLine -replace '^\s+Label:\s*', '').Trim() }
    $durationLine = $mbContent3 | Where-Object { $_ -match '^\s+Duration:' } | Select-Object -First 1
    if ($durationLine) { $MusicDuration = ($durationLine -replace '^\s+Duration:\s*', '').Trim() }
}

# Insert music metadata: Deezer/MB link above genre, year + label + duration below genre (for music uploads)
if ($MusicMetaUrl -or $MusicLabel -or $MusicDuration -or $music.IsPresent) {
    $e_link = [char]::ConvertFromUtf32(0x1F517)     # link
    $e_cal  = [char]::ConvertFromUtf32(0x1F4C5)     # calendar
    $e_bldg = [char]::ConvertFromUtf32(0x1F3E2)     # office building
    $e_clock = [char]::ConvertFromUtf32(0x23F0)     # alarm clock
    $descLines = $Description -split "`n"
    $bgGenreMb = [char]0x0416 + [char]0x0430 + [char]0x043D + [char]0x0440  # Жанр
    $musicInserted = $false
    $newLines = @()
    for ($k = 0; $k -lt $descLines.Count; $k++) {
        if (-not $musicInserted -and ($descLines[$k] -match '\[b\].{0,15}(Genres|Genre)' -or $descLines[$k].Contains($bgGenreMb))) {
            # Deezer/MusicBrainz link above genre
            if ($MusicMetaUrl -and $MusicMetaId) {
                $newLines += "${e_link} [b]${MusicMetaSource}:[/b] [url=${MusicMetaUrl}]${MusicMetaId}[/url]"
            }
            # Genre line itself
            $newLines += $descLines[$k]
            # Year, label, duration below genre
            if ($Year -and $Year -ne '????') { $newLines += "${e_cal} [b]Year:[/b] ${Year}" }
            if ($MusicLabel) { $newLines += "${e_bldg} [b]Label:[/b] ${MusicLabel}" }
            if ($MusicDuration) { $newLines += "${e_clock} [b]Duration:[/b] ${MusicDuration}" }
            $musicInserted = $true
            continue
        }
        $newLines += $descLines[$k]
    }
    if (-not $musicInserted) {
        # No genre line found - prepend all music metadata
        $prependLines = @()
        if ($MusicMetaUrl -and $MusicMetaId) {
            $prependLines += "${e_link} [b]${MusicMetaSource}:[/b] [url=${MusicMetaUrl}]${MusicMetaId}[/url]"
        }
        if ($Year -and $Year -ne '????') { $prependLines += "${e_cal} [b]Year:[/b] ${Year}" }
        if ($MusicLabel) { $prependLines += "${e_bldg} [b]Label:[/b] ${MusicLabel}" }
        if ($MusicDuration) { $prependLines += "${e_clock} [b]Duration:[/b] ${MusicDuration}" }
        $prependLines += ''
        $newLines = $prependLines + $newLines
    }
    $Description = $newLines -join "`n"
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

# ── Build all description building blocks before final assembly ──────────

# -- 1. Split description into metadata and content blocks --
$descLines = $Description -split "`n"
$metaEndIdx = -1
$lastMetaIdx = -1
for ($i = 0; $i -lt $descLines.Count; $i++) {
    $ln = $descLines[$i].Trim()
    if ($ln -eq '') { continue }
    if ($ln -match '^.+\[b\][^\[]*:\[/b\]') { $lastMetaIdx = $i }
    elseif ($lastMetaIdx -ge 0) { $metaEndIdx = $lastMetaIdx; break }
}
if ($metaEndIdx -lt 0 -and $lastMetaIdx -ge 0) { $metaEndIdx = $lastMetaIdx }

$metaBlock = ''
$contentBlock = ''
if ($metaEndIdx -ge 0) {
    $metaBlock = ($descLines[0..$metaEndIdx] -join "`n").TrimEnd()
    if ($metaEndIdx + 1 -lt $descLines.Count) {
        $contentBlock = ($descLines[($metaEndIdx + 1)..($descLines.Count - 1)] -join "`n").TrimStart("`n")
    }
}

# -- 2. Build torrent file list spoiler (from .torrent metadata, not directory scan) --
$fileListSpoiler = ''
$torrentFile = Join-Path $OutDir "$baseName.torrent"
$torrentFiles = $null
if (Test-Path -LiteralPath $torrentFile) {
    try {
        $torRaw = [System.IO.File]::ReadAllBytes($torrentFile)
        $torPos = 0
        $torDict = Bdecode-Desc $torRaw ([ref]$torPos)
        $torInfo = $torDict['info']
        if ($torInfo) {
            $torFileEntries = $torInfo['files']
            if ($torFileEntries) {
                $torrentFiles = @()
                foreach ($tf in $torFileEntries) {
                    $tfPath = ($tf['path']) -join '/'
                    $torrentFiles += @{ Path = $tfPath; Size = [long]$tf['length'] }
                }
            } else {
                $torrentFiles = @(@{ Path = $torInfo['name']; Size = [long]$torInfo['length'] })
            }
        }
    } catch {
        Write-Host "  Warning: could not parse torrent file, falling back to directory scan" -ForegroundColor Yellow
    }
}

$audioExts = @('.flac','.mp3','.ogg','.opus','.m4a','.aac','.wav','.wma','.ape','.wv','.alac','.dts','.ac3')
$withDuration = $music.IsPresent
$totalDurMs = [long]0
$audioTrackDurations = [System.Collections.Generic.List[string]]::new()

if ($torrentFiles) {
    $rows = @()
    $totalSize = [long]0
    $typeCounts = @{}
    foreach ($tf in $torrentFiles) {
        $rel = $tf.Path
        $fSize = $tf.Size
        $fSizeGB = [math]::Round($fSize / 1GB, 2)
        if ($fSizeGB -ge 1) { $fSizeLabel = "$fSizeGB GB" } elseif ($fSize -ge 1MB) { $fSizeLabel = "$([math]::Round($fSize / 1MB, 2)) MB" } else { $fSizeLabel = "$([math]::Round($fSize / 1KB, 2)) KB" }
        $durLabel = ''
        if ($withDuration) {
            $ext = [System.IO.Path]::GetExtension($rel).ToLower()
            if ($audioExts -contains $ext) {
                $diskPath = Join-Path $directory $rel
                if (Test-Path -LiteralPath $diskPath) {
                    $ms = Get-AudioDurationMs -Path $diskPath
                    if ($ms -gt 0) {
                        $totalDurMs += $ms
                        $totalSec = [int][math]::Floor($ms / 1000)
                        $mm = [int][math]::Floor($totalSec / 60)
                        $ss = $totalSec % 60
                        $durLabel = ('{0}:{1:D2}' -f $mm, $ss)
                    }
                }
                $audioTrackDurations.Add($durLabel) | Out-Null
            }
        }
        if ($withDuration) {
            $rows += "[tr][td]${rel}[/td][td]${durLabel}[/td][td]${fSizeLabel}[/td][/tr]"
        } else {
            $rows += "[tr][td]${rel}[/td][td]${fSizeLabel}[/td][/tr]"
        }
        $totalSize += $fSize
        $ext = [System.IO.Path]::GetExtension($rel).TrimStart('.').ToUpper()
        if (-not $ext) { $ext = 'OTHER' }
        if ($typeCounts.ContainsKey($ext)) { $typeCounts[$ext]++ } else { $typeCounts[$ext] = 1 }
    }
    $typeParts = ($typeCounts.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Value) $($_.Key)" })
    $totalGB = [math]::Round($totalSize / 1GB, 2)
    if ($totalGB -ge 1) { $totalLabel = "$totalGB GB" }
    elseif ($totalSize -ge 1MB) { $totalLabel = "$([math]::Round($totalSize / 1MB, 2)) MB" }
    else { $totalLabel = "$([math]::Round($totalSize / 1KB, 2)) KB" }
    $totalCount = $torrentFiles.Count
    $summary = "[b]Summary:[/b] $totalCount files: " + ($typeParts -join ', ') + " | Total: $totalLabel"
    if ($withDuration -and $totalDurMs -gt 0) {
        $totSec = [int][math]::Floor($totalDurMs / 1000)
        $tH = [int][math]::Floor($totSec / 3600)
        $tM = [int][math]::Floor(($totSec % 3600) / 60)
        $tS = $totSec % 60
        $playtimeLabel = if ($tH -gt 0) { ('{0}:{1:D2}:{2:D2}' -f $tH, $tM, $tS) } else { ('{0}:{1:D2}' -f $tM, $tS) }
        $summary += " | Playtime: $playtimeLabel"
    }
    if ($withDuration) {
        $fileTable = "[table]`n[tr][td][b]Name[/b][/td][td][b]Duration[/b][/td][td][b]Size[/b][/td][/tr]`n" + ($rows -join "`n") + "`n[/table]"
    } else {
        $fileTable = "[table]`n[tr][td][b]Name[/b][/td][td][b]Size[/b][/td][/tr]`n" + ($rows -join "`n") + "`n[/table]"
    }
    $fileListSpoiler = "`n`n[spoiler=Torrent files]`n${summary}`n`n${fileTable}`n[/spoiler]"
} elseif ($singleFile) {
    $fi = Get-Item -LiteralPath $singleFile
    $sizeGB = [math]::Round($fi.Length / 1GB, 2)
    if ($sizeGB -ge 1) { $sizeLabel = "$sizeGB GB" } elseif ($fi.Length -ge 1MB) { $sizeLabel = "$([math]::Round($fi.Length / 1MB, 2)) MB" } else { $sizeLabel = "$([math]::Round($fi.Length / 1KB, 2)) KB" }
    $ext = $fi.Extension.TrimStart('.').ToUpper()
    $summary = "[b]Summary:[/b] 1 file ($ext) | Total: $sizeLabel"
    $fileTable = "[table]`n[tr][td][b]Name[/b][/td][td][b]Size[/b][/td][/tr]`n[tr][td]${baseName}$($fi.Extension)[/td][td]${sizeLabel}[/td][/tr]`n[/table]"
    $fileListSpoiler = "`n`n[spoiler=Torrent files]`n${summary}`n`n${fileTable}`n[/spoiler]"
} elseif (Test-Path -LiteralPath $directory -PathType Container) {
    $videoExts = @('.mkv','.mp4','.avi','.wmv','.mov','.m4v','.mpg','.mpeg','.ts','.m2ts')
    $allFiles = Get-ChildItem -LiteralPath $directory -Recurse -File | Where-Object {
        $inTrailerDir = $_.FullName -match '(?i)[/\\]trailers?[/\\]'
        $isTrailerFile = $_.Name -match '(?i)(^|[\s._-])trailer' -and $videoExts -contains $_.Extension.ToLower()
        -not $inTrailerDir -and -not $isTrailerFile
    } | Sort-Object FullName
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
            $durLabel = ''
            if ($withDuration) {
                $ext = $f.Extension.ToLower()
                if ($audioExts -contains $ext) {
                    $ms = Get-AudioDurationMs -Path $f.FullName
                    if ($ms -gt 0) {
                        $totalDurMs += $ms
                        $totalSec = [int][math]::Floor($ms / 1000)
                        $mm = [int][math]::Floor($totalSec / 60)
                        $ss = $totalSec % 60
                        $durLabel = ('{0}:{1:D2}' -f $mm, $ss)
                    }
                    $audioTrackDurations.Add($durLabel) | Out-Null
                }
            }
            if ($withDuration) {
                $rows += "[tr][td]${rel}[/td][td]${durLabel}[/td][td]${fSizeLabel}[/td][/tr]"
            } else {
                $rows += "[tr][td]${rel}[/td][td]${fSizeLabel}[/td][/tr]"
            }
            $totalSize += $f.Length
            $ext = $f.Extension.TrimStart('.').ToUpper()
            if (-not $ext) { $ext = 'OTHER' }
            if ($typeCounts.ContainsKey($ext)) { $typeCounts[$ext]++ } else { $typeCounts[$ext] = 1 }
        }
        $typeParts = ($typeCounts.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Value) $($_.Key)" })
        $totalGB = [math]::Round($totalSize / 1GB, 2)
        if ($totalGB -ge 1) { $totalLabel = "$totalGB GB" }
        elseif ($totalSize -ge 1MB) { $totalLabel = "$([math]::Round($totalSize / 1MB, 2)) MB" }
        else { $totalLabel = "$([math]::Round($totalSize / 1KB, 2)) KB" }
        $totalCount = $allFiles.Count
        $summary = "[b]Summary:[/b] $totalCount files: " + ($typeParts -join ', ') + " | Total: $totalLabel"
        if ($withDuration -and $totalDurMs -gt 0) {
            $totSec = [int][math]::Floor($totalDurMs / 1000)
            $tH = [int][math]::Floor($totSec / 3600)
            $tM = [int][math]::Floor(($totSec % 3600) / 60)
            $tS = $totSec % 60
            $playtimeLabel = if ($tH -gt 0) { ('{0}:{1:D2}:{2:D2}' -f $tH, $tM, $tS) } else { ('{0}:{1:D2}' -f $tM, $tS) }
            $summary += " | Playtime: $playtimeLabel"
        }
        if ($withDuration) {
            $fileTable = "[table]`n[tr][td][b]Name[/b][/td][td][b]Duration[/b][/td][td][b]Size[/b][/td][/tr]`n" + ($rows -join "`n") + "`n[/table]"
        } else {
            $fileTable = "[table]`n[tr][td][b]Name[/b][/td][td][b]Size[/b][/td][/tr]`n" + ($rows -join "`n") + "`n[/table]"
        }
        $fileListSpoiler = "`n`n[spoiler=Torrent files]`n${summary}`n`n${fileTable}`n[/spoiler]"
    }
}

# -- 2b. Annotate the AI-generated tracklist with per-track durations --
# The AI prose lives in $contentBlock (computed above from $Description).
# Walk its numbered tracklist items and append (mm:ss) from the audio files
# we already probed (same sort order as the file list).
# The BG word is built from code points to keep this .ps1 file pure ASCII
# (PS5.1 otherwise reads the source using the system codepage).
if ($music.IsPresent -and $audioTrackDurations -and $audioTrackDurations.Count -gt 0 -and $contentBlock) {
    $bgTraklist = -join ([char[]]@(0x0422,0x0440,0x0430,0x043A,0x043B,0x0438,0x0441,0x0442))  # Traklist in Cyrillic
    $cbLines = $contentBlock -split "`n"
    $inTracklist = $false
    $trackIdx = 0
    for ($li = 0; $li -lt $cbLines.Count; $li++) {
        $ln = $cbLines[$li]
        if (-not $inTracklist) {
            if ($ln -match '(?i)\btracklist\b' -or $ln -match '(?i)\btrack\s*list\b' -or $ln.Contains($bgTraklist)) {
                $inTracklist = $true
            }
            continue
        }
        # Match "1. Title" or "1) Title" (possibly with extra whitespace)
        $m = [regex]::Match($ln, '^(?<pre>\s*)(?<num>\d+)[\.\)]\s*(?<title>.+?)\s*$')
        if ($m.Success) {
            if ($trackIdx -lt $audioTrackDurations.Count) {
                $dur = $audioTrackDurations[$trackIdx]
                $trackIdx++
                if ($dur -and $m.Groups['title'].Value -notmatch '\(\s*\d+:\d{2}\s*\)\s*$') {
                    $cbLines[$li] = "$($m.Groups['pre'].Value)$($m.Groups['num'].Value). $($m.Groups['title'].Value) ($dur)"
                }
            }
            continue
        }
        # First non-blank, non-numbered line after tracklist entries ends the section.
        # A single blank line inside the tracklist is tolerated.
        if ($trackIdx -gt 0 -and $ln -notmatch '^\s*$') { $inTracklist = $false }
    }
    $contentBlock = $cbLines -join "`n"
}

# -- 3. Build screenshots BBCode --
$screenUrls = @()
if (Test-Path -LiteralPath $ScreensFile) {
    $screenUrls = @(Get-Content -LiteralPath $ScreensFile -Encoding UTF8 | ForEach-Object { $_.Trim().TrimStart([char]0xFEFF) } | Where-Object { $_ })
}
if ($screenUrls.Count -eq 0 -and (Test-Path -LiteralPath $IgdbFile)) {
    $screenUrls = @(Get-Content -LiteralPath $IgdbFile -Encoding UTF8 | Where-Object { $_ -match '^\s+Screenshot:' } | ForEach-Object { ($_ -replace '^\s+Screenshot:\s*', '').Trim() } | Where-Object { $_ })
}
$aiScreenFile = Join-Path $OutDir "${TorrentName}_ai_screenshots.txt"
if ($screenUrls.Count -eq 0 -and (Test-Path -LiteralPath $aiScreenFile)) {
    $screenUrls = @(Get-Content -LiteralPath $aiScreenFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$screenshotsBBCode = ''
if ($screenUrls.Count -gt 0) {
    $validScreens = @()
    foreach ($url in $screenUrls) {
        if (Test-ImageUrl $url) { $validScreens += $url }
        else { Write-Host "Warning: Screenshot URL not reachable, skipping: $url" -ForegroundColor Yellow }
    }
    if ($validScreens.Count -gt 0) {
        if ($tmplScreenshots) {
            # Split on ---IMAGE--- to get wrapper and per-image templates
            $parts = $tmplScreenshots -split '---IMAGE---'
            $wrapperTmpl = $parts[0].Trim()
            $imageTmpl = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '[url={{URL}}][img=400]{{URL}}[/img][/url]' }
            $imgTags = ($validScreens | ForEach-Object { $imageTmpl.Replace('{{URL}}', $_) }) -join ''
            $screenshotsBBCode = Expand-Template $wrapperTmpl @{ 'SCREENSHOT_IMAGES' = $imgTags }
        } else {
            $screenshotsBBCode = "[center]"
            foreach ($url in $validScreens) { $screenshotsBBCode += "[url=${url}][img=400]${url}[/img][/url]" }
            $screenshotsBBCode += "[/center]"
        }
    }
}

# -- 4. Extract keywords (used for tracker keywords field + hashtags) --
$KeywordsText = ''
if (Test-Path -LiteralPath $ImdbFile) {
    $kwLine = Get-Content -LiteralPath $ImdbFile -Encoding UTF8 | Where-Object { $_ -match '^Keywords:' } | Select-Object -First 1
    if ($kwLine) { $KeywordsText = ($kwLine -replace '^Keywords:\s*', '').Trim() }
}
$KeywordsFile = Join-Path $OutDir "${TorrentName}_keywords.txt"
if ($KeywordsText) {
    [System.IO.File]::WriteAllText($KeywordsFile, $KeywordsText, $utf8NoBom)
    Write-Host "Keywords saved to: $KeywordsFile" -ForegroundColor Cyan
} else {
    $KeywordsFile = ''
}

$hashtagText = ''
if (-not (Test-Path -LiteralPath $GeminiFile) -and $KeywordsText) {
    $tags = ($KeywordsText -split ',') | ForEach-Object { $_.Trim() -replace '\s+', '' } | Where-Object { $_ }
    if ($tags) { $hashtagText = ($tags | ForEach-Object { "#$_" }) -join ' ' }
}

# -- 5. Build signature (hardcoded) --
$TrackerUrl = if ($cfg -and $cfg.tracker_url) { ([string]$cfg.tracker_url).TrimEnd('/') } else { '' }
$sigSearchUrl = "${TrackerUrl}/torrents?name=SCRIPT+UPLOAD3R"
$e_bolt = [char]::ConvertFromUtf32(0x26A1)
$signatureBBCode = "[center][url=${sigSearchUrl}][color=#7760de][size=16]${e_bolt} Uploaded using SCRIPT UPLOAD3R ${e_bolt}[/size][/color][/url]`n[size=9][color=#5f5f5f]Shell script torrent creator/uploader for Windows proudly developed by AI[/color][/size][/center]"

# Fallback banner: use cover/poster image for types without a native banner source (not games)
if (-not $BannerUrl -and $PosterUrl -and -not $game.IsPresent) {
    $BannerUrl = $PosterUrl
}
# No banner for games (tracker fetches from IGDB automatically)
if ($game.IsPresent) { $BannerUrl = '' }

# ── Final assembly via templates ────────────────────────────────────────────

# Hide banner from description if it's the same as poster (still uploaded separately)
$DescBannerUrl = if ($BannerUrl -eq $PosterUrl) { '' } else { $BannerUrl }

# Common template variables
$tmplVars = @{
    'BANNER'            = [string]$DescBannerUrl
    'BANNER_URL'        = [string]$DescBannerUrl
    'POSTER'            = [string]$PosterUrl
    'POSTER_URL'        = [string]$PosterUrl
    'HEADER'            = [string]$Header
    'EN_TITLE'          = [string]$enHeader
    'BG_TITLE'          = [string]$BgTitle
    'YEAR'              = [string]$Year
    'METADATA'          = [string]$metaBlock
    'CONTENT'           = [string]$contentBlock
    'DESCRIPTION'       = [string]$Description
    'FILE_LIST'         = [string]$fileListSpoiler
    'SCREENSHOTS'       = [string]$screenshotsBBCode
    'HASHTAGS'          = [string]$hashtagText
    'TRACKER_URL'       = [string]$TrackerUrl
    'TORRENT_NAME'      = [string]$TorrentName
}

if ($PosterUrl -and $metaEndIdx -ge 0 -and $tmplLayoutPoster) {
    $Description = Expand-Template $tmplLayoutPoster $tmplVars
} elseif ($tmplLayoutNoPoster) {
    $Description = Expand-Template $tmplLayoutNoPoster $tmplVars
} else {
    # Hardcoded fallback when templates are missing
    $bannerBBCode = if ($DescBannerUrl) { "[url=${DescBannerUrl}][img=1920]${DescBannerUrl}[/img][/url]" } else { '' }
    $posterBBCode = if ($PosterUrl) { "[url=${PosterUrl}][img=250]${PosterUrl}[/img][/url]" } else { '' }
    if ($PosterUrl -and $metaEndIdx -ge 0) {
        $Description = "[table]`n[tr]`n[td]${posterBBCode}[/td]`n[td]`n${Header}`n`n${metaBlock}${fileListSpoiler}`n[/td]`n[/tr]`n[/table]"
        if ($contentBlock) { $Description += "`n`n`n${contentBlock}" }
        if ($BannerUrl) { $Description = "[center]${bannerBBCode}[/center]`n`n${Description}" }
    } else {
        $Preamble = ''
        if ($BannerUrl) { $Preamble = "[center]${bannerBBCode}[/center]`n`n" }
        $Preamble += "${Header}`n`n"
        $Description = "${Preamble}${Description}"
    }
    if ($screenshotsBBCode) { $Description += "`n`n${screenshotsBBCode}" }
    if ($hashtagText) { $Description += "`n`n${hashtagText}" }
}

# Always append signature at the end
$Description += "`n`n${signatureBBCode}"

# Make hashtags linkable to tracker search
if ($TrackerUrl) {
    $urlRx = [regex]'\[url=[^\]]*\].*?\[/url\]'
    $urlRanges = @($urlRx.Matches($Description) | ForEach-Object { @{ Start = $_.Index; End = $_.Index + $_.Length } })
    $rx = [regex]'(?<![=\w])#([\w][\w.\-]*[\w]|[\w]+)'
    $tagMatches = $rx.Matches($Description)
    for ($i = $tagMatches.Count - 1; $i -ge 0; $i--) {
        $m = $tagMatches[$i]
        $insideUrl = $false
        foreach ($r in $urlRanges) { if ($m.Index -ge $r.Start -and $m.Index -lt $r.End) { $insideUrl = $true; break } }
        if ($insideUrl) { continue }
        $tag = $m.Groups[1].Value
        $encoded = [Uri]::EscapeDataString($tag)
        $link = "[url=${TrackerUrl}/torrents?description=${encoded}]#${tag}[/url]"
        $Description = $Description.Substring(0, $m.Index) + $link + $Description.Substring($m.Index + $m.Length)
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
$Internal     = if ($config.internal) { $config.internal } else { 0 }
$Featured     = if ($config.featured) { $config.featured } else { 0 }
$Free         = if ($config.free) { $config.free } else { 0 }
$FlUntil      = if ($config.fl_until) { $config.fl_until } else { 0 }
$DoubleUp     = if ($config.doubleup) { $config.doubleup } else { 0 }
$DuUntil      = if ($config.du_until) { $config.du_until } else { 0 }
$Sticky       = if ($config.sticky) { $config.sticky } else { 0 }
$ModQueue     = if ($config.mod_queue_opt_in) { $config.mod_queue_opt_in } else { 0 }

# Resolve categories file: config override -> tracker-host-based -> default
$CategoriesFile = if ($config.categories_file) { [string]$config.categories_file } else { '' }
if ($CategoriesFile -and -not [System.IO.Path]::IsPathRooted($CategoriesFile)) {
    $CategoriesFile = Join-Path $RootDir $CategoriesFile
}
if (-not $CategoriesFile -or -not (Test-Path -LiteralPath $CategoriesFile)) {
    $CategoriesFile = ''
    if ($TrackerUrl) {
        try {
            $trackerHost = ([System.Uri]$TrackerUrl).Host -replace '\.[^.]+$','' -replace '[^A-Za-z0-9]','_'
            $outFile = Join-Path $RootDir "output\categories_${trackerHost}.jsonc"
            $sharedFile = Join-Path $RootDir "shared\categories_${trackerHost}.jsonc"
            if (Test-Path -LiteralPath $outFile) { $CategoriesFile = $outFile }
            elseif (Test-Path -LiteralPath $sharedFile) { $CategoriesFile = $sharedFile }
        } catch { }
    }
}
if (-not $CategoriesFile) {
    $CategoriesFile = Join-Path $RootDir "shared\categories.jsonc"
}
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

# Override category for music uploads
if ($music.IsPresent) {
    # Always seed with a generic music category so a failed specific lookup
    # can't leave $CategoryId on the default movie id.
    $musicCat = $categories | Where-Object { $_.name -eq 'Music' } | Select-Object -First 1
    if (-not $musicCat) { $musicCat = $categories | Where-Object { $_.type -eq 'music' } | Select-Object -First 1 }
    if ($musicCat) { $CategoryId = $musicCat.id }

    $nl = $TorrentName.ToLower()
    $specific = $null
    if ($nl -match '24bit|hi-?res|vinyl') {
        $specific = $categories | Where-Object { $_.name -eq 'Music/Hi-Res/Vinyl' } | Select-Object -First 1
    } elseif ($nl -match 'flac|lossless|16bit|ape|wav|alac|dsd') {
        $specific = $categories | Where-Object { $_.name -eq 'Music/Lossless' } | Select-Object -First 1
    } elseif ($nl -match '\bdts\b') {
        $specific = $categories | Where-Object { $_.name -eq 'Music/DTS' } | Select-Object -First 1
    } elseif ($nl -match 'dvd-?r|dvdr\b|audio\s*dvd') {
        $specific = $categories | Where-Object { $_.name -eq 'Music/DVD-R' } | Select-Object -First 1
    }
    if ($specific) { $CategoryId = $specific.id }
    Write-Host "Music mode -> category_id=$CategoryId"
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

if ($game.IsPresent -or $software.IsPresent -or $music.IsPresent) {
    # Games/Software/Music: use raw torrent name, just replace dots/underscores
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
if (-not $game.IsPresent -and -not $software.IsPresent -and -not $music.IsPresent -and $BgTitle -and $BgTitle -ne $EnTitle -and $BgTitle -ne $TmdbEnTitle) {
    $UploadName = "$UploadName / $BgTitle ($Year)"
}

# Detect Bulgarian audio/subtitles from MediaInfo sections (skip for games)
$bgAudio = $false
$bgSubsInContainer = $false
$enSubsInContainer = $false
if (Test-Path -LiteralPath $MediainfoFile) {
    $section = ''
    foreach ($line in Get-Content -LiteralPath $MediainfoFile) {
        if ($line -match '^Audio')                    { $section = 'audio' }
        elseif ($line -match '^Text')                 { $section = 'text' }
        elseif ($line -match '^(Video|Menu|General)') { $section = 'other' }
        if ($line -match '(?i)Language\s*:\s*(.+)$') {
            $lang = $matches[1].Trim()
            if ($section -eq 'audio' -and $lang -match '(?i)Bulgarian') { $bgAudio = $true }
            if ($section -eq 'text') {
                if ($lang -match '(?i)Bulgarian') { $bgSubsInContainer = $true }
                elseif ($lang -match '(?i)English') { $enSubsInContainer = $true }
            }
        }
    }
}
# Check for external subtitle files in the torrent directory
$bgSubsInTorrent = $false
$enSubsInTorrent = $false
$bgSrtGt = $false
$subExts = @('.srt', '.ass', '.ssa', '.sub', '.sup', '.vtt', '.idx')
$subFiles = Get-ChildItem -LiteralPath $directory -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $subExts -contains $_.Extension.ToLower() }
foreach ($sf in $subFiles) {
    $isBg = ($sf.Name -match '(?i)\.bg\.|\.bul\.|bulgarian|\.bgforced\.' -or $sf.FullName -match '(?i)[/\\]bg[/\\]|[/\\]bul[/\\]')
    $isEn = ($sf.Name -match '(?i)\.en\.|\.eng\.|english' -or $sf.FullName -match '(?i)[/\\]en[/\\]|[/\\]eng[/\\]')
    if ($isBg) {
        $bgSubsInTorrent = $true
        if ($sf.Name -match '(?i)\.GT\.|\.ai\.|machinetranslated|googletranslate') { $bgSrtGt = $true }
    }
    if ($isEn -and -not $isBg) { $enSubsInTorrent = $true }
}
# Combined flag used by legacy tag logic below
$bgSubs = $bgSubsInContainer -or $bgSubsInTorrent

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

# Detect .nfo file in torrent content
$NfoFile = ''
if ($singleFile -and $singleFile -match '\.nfo$') {
    $NfoFile = $singleFile
} elseif (-not $singleFile -and (Test-Path -LiteralPath $directory -PathType Container)) {
    $nfoFound = Get-ChildItem -LiteralPath $directory -Recurse -File -Filter '*.nfo' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($nfoFound) { $NfoFile = $nfoFound.FullName }
}
if ($NfoFile) {
    Write-Host "NFO found: $NfoFile" -ForegroundColor Cyan
} else {
    # Fall back to a generated default NFO. Movie/TV and music use mediainfo;
    # games/software derive a minimal block from filesystem data.
    $defaultTmpl = Join-Path $RootDir 'shared/default.nfo'
        if (Test-Path -LiteralPath $defaultTmpl) {
            # Parse the mediainfo file into section dictionaries (one per track)
            $sections = New-Object System.Collections.Generic.List[object]
            $cur = $null
            if (Test-Path -LiteralPath $MediainfoFile) {
                foreach ($ln in [System.IO.File]::ReadAllLines($MediainfoFile, [System.Text.Encoding]::UTF8)) {
                    if ($ln -match '^(General|Video|Audio|Text|Menu)(?:\s|$)') {
                        $cur = @{ Section = $matches[1] }
                        $sections.Add($cur)
                        continue
                    }
                    if ($null -ne $cur -and $ln -match '^([^:]+?)\s*:\s*(.+)$') {
                        $key = $matches[1].Trim()
                        if (-not $cur.ContainsKey($key)) { $cur[$key] = $matches[2].Trim() }
                    }
                }
            }
            $general = $sections | Where-Object { $_.Section -eq 'General' } | Select-Object -First 1
            $videos  = @($sections | Where-Object { $_.Section -eq 'Video' })
            $audios  = @($sections | Where-Object { $_.Section -eq 'Audio' })
            $texts   = @($sections | Where-Object { $_.Section -eq 'Text'  })

            # Build the summary rows. Each row fits inside the RELEASE INFO box:
            # box inner width = 75 chars between the two box pipes.
            $innerWidth = 75
            $summaryRows = @()
            function Add-Row {
                param([string]$Label, [string]$Value)
                $script:summaryRows += ,@($Label, $Value)
            }
            # Add a blank separator row only if the previous row was not already blank
            function Add-Sep {
                if ($script:summaryRows.Count -eq 0) { return }
                $last = $script:summaryRows[$script:summaryRows.Count - 1]
                if ($last[0] -eq '__BLANK__') { return }
                $script:summaryRows += ,@('__BLANK__', '')
            }
            if ($software.IsPresent -or $game.IsPresent) {
                # --- Game/Software NFO: minimal filesystem summary (no mediainfo) ---
                # Title row (cleaned release name already in $swName via earlier block)
                $nfoTitle = if ($swName) { $swName } else { $TorrentName }
                if ($Year -and $Year -ne '????') { $nfoTitle = "$nfoTitle ($Year)" }
                Add-Row 'Title' $nfoTitle
                Add-Sep
                # Scan source path for size and file list
                $swItems = @()
                if ($singleFile -and (Test-Path -LiteralPath $singleFile)) {
                    $swItems = @(Get-Item -LiteralPath $singleFile)
                } elseif (Test-Path -LiteralPath $directory) {
                    $swItems = @(Get-ChildItem -LiteralPath $directory -Recurse -File -ErrorAction SilentlyContinue)
                }
                $swTotalBytes = 0
                foreach ($it in $swItems) { $swTotalBytes += [int64]$it.Length }
                # Pick a primary file: largest by size (usually the installer/archive/iso)
                $swPrimary = $swItems | Sort-Object -Property Length -Descending | Select-Object -First 1
                if ($swPrimary) {
                    Add-Row 'File' $swPrimary.Name
                    $ext = $swPrimary.Extension.TrimStart('.').ToUpper()
                    if ($ext) { Add-Row 'Format' $ext }
                }
                if ($swItems.Count -gt 1) { Add-Row 'Files' ("{0} files" -f $swItems.Count) }
                if ($swTotalBytes -gt 0) {
                    $sz = $swTotalBytes
                    $units = @('B','KB','MB','GB','TB')
                    $u = 0
                    while ($sz -ge 1024 -and $u -lt $units.Count - 1) { $sz = $sz / 1024; $u++ }
                    Add-Row 'Size' ("{0:N2} {1}" -f $sz, $units[$u])
                }
                # Type label derived from filename heuristics (tracker category
                # may not exist — e.g. nanoset has no Programs/*, so looking up
                # by $CategoryId would return the default movie category).
                $swNameLc = $TorrentName.ToLower()
                if ($game.IsPresent) {
                    $swType = 'Game'
                    if ($swNameLc -match 'mac|osx|macos') { $swType = 'Game (Mac)' }
                    elseif ($swNameLc -match 'linux') { $swType = 'Game (Linux)' }
                    elseif ($swNameLc -match 'switch|nsp|xci') { $swType = 'Game (Switch)' }
                    elseif ($swNameLc -match 'ps[2345]|playstation') { $swType = 'Game (PlayStation)' }
                    elseif ($swNameLc -match 'xbox') { $swType = 'Game (Xbox)' }
                } else {
                    $swType = 'Software'
                    if ($swNameLc -match 'mac|osx|macos') { $swType = 'Software (Mac)' }
                    elseif ($swNameLc -match '\.iso') { $swType = 'Software (PC ISO)' }
                    elseif ($swNameLc -match 'linux') { $swType = 'Software (Linux)' }
                }
                Add-Row 'Type' $swType
                Add-Sep
                if ($game.IsPresent -and $Igdb -and $Igdb -ne 0) {
                    Add-Row 'IGDB' "https://www.igdb.com/games/$Igdb"
                }
            } elseif ($music.IsPresent) {
                # --- Music NFO: album details, audio format, tracklist ---
                $nfoMusicLines = @()
                if (Test-Path -LiteralPath $MbFile) {
                    $nfoMusicLines = Get-Content -LiteralPath $MbFile -Encoding UTF8
                }
                # Album details from _music.txt (first details block)
                $nfoArtist = ''
                $nfoAlbum = ''
                $nfoReleased = ''
                $nfoGenres = ''
                $nfoLabel = ''
                $nfoCountry = ''
                $nfoDuration = ''
                $nfoTotalTracks = ''
                $nfoTracks = @()
                $firstHeader = $nfoMusicLines | Where-Object { $_ -match '^\[\d+\]' } | Select-Object -First 1
                if ($firstHeader -and $firstHeader -match '^\[\d+\]\s+(.+?)\s+-\s+(.+?)(?:\s+\(\d{4}\))?$') {
                    $nfoArtist = $matches[1]
                    $nfoAlbum = $matches[2]
                }
                $inDetails = $false
                foreach ($ml in $nfoMusicLines) {
                    if ($ml -match '^--- Details for:') { $inDetails = $true; continue }
                    if ($ml -match '^---' -and $inDetails) { break }
                    if (-not $inDetails) { continue }
                    if ($ml -match '^\s+Artist:\s+(.+)') { if (-not $nfoArtist) { $nfoArtist = $matches[1].Trim() } }
                    if ($ml -match '^\s+Released:\s+(.+)') { $nfoReleased = $matches[1].Trim() }
                    if ($ml -match '^\s+Genres:\s+(.+)') { $nfoGenres = $matches[1].Trim() }
                    if ($ml -match '^\s+Label:\s+(.+)') { $nfoLabel = $matches[1].Trim() }
                    if ($ml -match '^\s+Country:\s+(.+)') { $nfoCountry = $matches[1].Trim() }
                    if ($ml -match '^\s+Duration:\s+(.+)') { $nfoDuration = $matches[1].Trim() }
                    if ($ml -match '^\s+Total Tracks:\s+(.+)') { $nfoTotalTracks = $matches[1].Trim() }
                    if ($ml -match '^\s+Track:\s+(.+)') { $nfoTracks += $matches[1].Trim() }
                }
                if ($nfoArtist) { Add-Row 'Artist' $nfoArtist }
                if ($nfoAlbum) { Add-Row 'Album' $nfoAlbum }
                if ($nfoReleased -or ($Year -and $Year -ne '????')) {
                    Add-Row 'Released' $(if ($nfoReleased) { $nfoReleased } else { $Year })
                }
                if ($nfoGenres) { Add-Row 'Genres' $nfoGenres }
                if ($nfoLabel) { Add-Row 'Label' $nfoLabel }
                if ($nfoCountry) { Add-Row 'Country' $nfoCountry }
                if ($nfoDuration) { Add-Row 'Duration' $nfoDuration }
                Add-Sep
                # Audio format from MediaInfo (first audio track)
                $firstAudio = $audios | Select-Object -First 1
                if ($firstAudio) {
                    $aparts = @()
                    if ($firstAudio['Format'])           { $aparts += $firstAudio['Format'] }
                    if ($firstAudio['Bit rate mode'])    { $aparts += $firstAudio['Bit rate mode'] }
                    if ($firstAudio['Bit rate'])         { $aparts += $firstAudio['Bit rate'] }
                    if ($firstAudio['Sampling rate'])    { $aparts += $firstAudio['Sampling rate'] }
                    if ($firstAudio['Bit depth'])        { $aparts += $firstAudio['Bit depth'] }
                    if ($firstAudio['Channel(s)'])       { $aparts += ($firstAudio['Channel(s)'] -replace '\s*channels?', 'ch') }
                    if ($aparts.Count -gt 0) { Add-Row 'Format' ($aparts -join ', ') }
                }
                if ($general) {
                    if ($general['File size']) { Add-Row 'Size' $general['File size'] }
                }
                Add-Sep
                # Tracklist
                if ($nfoTracks.Count -gt 0) {
                    foreach ($trk in $nfoTracks) {
                        Add-Row 'Track' $trk
                    }
                    if ($nfoTotalTracks) { Add-Row 'Total' "$nfoTotalTracks tracks" }
                }
                Add-Sep
                if ($MusicMetaUrl) { Add-Row 'Source' $MusicMetaUrl }
            } else {
                # --- Movie/TV NFO: video/audio mediainfo ---
                # Titles from metadata (EN preferred from TMDB, fallback to parsed name)
                $nfoEnTitle = if ($TmdbEnTitle -and $TmdbEnTitle -notmatch '[\p{IsCyrillic}]') { $TmdbEnTitle } else { $EnTitle }
                if ($nfoEnTitle) {
                    $tval = $nfoEnTitle
                    if ($Year) { $tval = "$tval ($Year)" }
                    Add-Row 'Title' $tval
                }
                # BG Title intentionally omitted: NFO is CP437 and Cyrillic mojibakes.
                Add-Sep
                if ($general) {
                    $nameVal = ''
                    if ($general['Complete name']) { $nameVal = Split-Path -Leaf $general['Complete name'] }
                    if ($nameVal) { Add-Row 'File'      $nameVal }
                    if ($general['Format'])        { Add-Row 'Container' $general['Format'] }
                    if ($general['File size'])     { Add-Row 'Size'      $general['File size'] }
                    if ($general['Duration'])      { Add-Row 'Duration'  $general['Duration'] }
                    if ($general['Overall bit rate']) { Add-Row 'Bitrate'   $general['Overall bit rate'] }
                }
                Add-Sep
                foreach ($v in $videos) {
                    $vparts = @()
                    if ($v['Format'])         { $vparts += $v['Format'] }
                    if ($v['Width'] -and $v['Height']) {
                        $w = ($v['Width']  -replace '[^\d]', '')
                        $h = ($v['Height'] -replace '[^\d]', '')
                        if ($w -and $h) { $vparts += "${w}x${h}" }
                    }
                    if ($v['Frame rate'])     { $vparts += ($v['Frame rate'] -replace '\s*FPS.*$', ' fps') }
                    if ($v['Bit depth'])      { $vparts += $v['Bit depth'] }
                    if ($v['HDR format'])     { $vparts += 'HDR' }
                    if ($v['Bit rate'])       { $vparts += $v['Bit rate'] }
                    Add-Row 'Video' ($vparts -join ', ')
                }
                Add-Sep
                foreach ($a in $audios) {
                    $aparts = @()
                    if ($a['Format'])         { $aparts += $a['Format'] }
                    if ($a['Channel(s)'])     { $aparts += ($a['Channel(s)'] -replace '\s*channels?', 'ch') }
                    if ($a['Bit rate'])       { $aparts += $a['Bit rate'] }
                    $suffix = ''
                    $lang = if ($a['Language']) { $a['Language'] } else { 'Undetermined' }
                    $title = $a['Title']
                    if ($title) { $suffix = " [$lang - $title]" } else { $suffix = " [$lang]" }
                    Add-Row 'Audio' (($aparts -join ', ') + $suffix)
                }
                Add-Sep
                if ($texts.Count -gt 0) {
                    $subLangs = @()
                    foreach ($t in $texts) {
                        $lg = if ($t['Language']) { $t['Language'] } else { 'Undetermined' }
                        $fm = if ($t['Format']) { " ($($t['Format']))" } else { '' }
                        $subLangs += "$lg$fm"
                    }
                    Add-Row 'Subs' ($subLangs -join ', ')
                }
                Add-Sep
                # Metasource links (one row per source). TMDB path differs movie vs tv.
                if ($Imdb) {
                    $imdbId = if ($Imdb -match '^\d+$') { 'tt' + $Imdb.PadLeft(7, '0') } else { $Imdb }
                    Add-Row 'IMDB' "https://www.imdb.com/title/$imdbId/"
                }
                if ($Tmdb) {
                    $tmdbPath = if ($tv.IsPresent) { 'tv' } else { 'movie' }
                    Add-Row 'TMDB' "https://www.themoviedb.org/$tmdbPath/$Tmdb"
                }
            }

            # Render rows inside the box: "  │    Label : Value" + padding + "│"
            $bodyLines = New-Object System.Collections.Generic.List[string]
            $pipeL = [char]0x2502
            $emptyLine = '  ' + $pipeL + (' ' * $innerWidth) + $pipeL
            $bodyLines.Add($emptyLine)
            if ($summaryRows.Count -eq 0) {
                $msg = 'No MediaInfo available.'
                $inner = '    ' + $msg
                if ($inner.Length -lt $innerWidth) { $inner = $inner + (' ' * ($innerWidth - $inner.Length)) }
                $bodyLines.Add('  ' + $pipeL + $inner.Substring(0, $innerWidth) + $pipeL)
            } else {
                $labelWidth = 9
                # Leave a 1-char gutter on the right so content never touches
                # the vertical border; this makes over-width values legible.
                $rightGutter = 1
                # Trim a trailing blank separator (looks bad just before bottom border)
                while ($summaryRows.Count -gt 0 -and $summaryRows[$summaryRows.Count - 1][0] -eq '__BLANK__') {
                    if ($summaryRows.Count -eq 1) { $summaryRows = @(); break }
                    $summaryRows = @($summaryRows[0..($summaryRows.Count - 2)])
                }
                foreach ($row in $summaryRows) {
                    $label = $row[0]
                    $value = [string]$row[1]
                    if ($label -eq '__BLANK__') { $bodyLines.Add($emptyLine); continue }
                    if ($label.Length -lt $labelWidth) { $label = $label + (' ' * ($labelWidth - $label.Length)) }
                    $prefix = '    ' + $label + ': '
                    $contLead = ' ' * $prefix.Length
                    $avail = $innerWidth - $prefix.Length - $rightGutter
                    if ($avail -lt 10) { $avail = 10 }
                    # Break any single token longer than $avail into pieces. Prefer
                    # to split at natural filename separators ('.', '-', '_')
                    # rather than mid-character, so filenames stay readable.
                    $tokens = New-Object System.Collections.Generic.List[string]
                    foreach ($wd in ($value -split '\s+')) {
                        if (-not $wd) { continue }
                        while ($wd.Length -gt $avail) {
                            $cut = -1
                            for ($j = $avail; $j -ge [math]::Max(1, [int]($avail * 0.5)); $j--) {
                                $ch = $wd[$j - 1]
                                if ($ch -eq '.' -or $ch -eq '-' -or $ch -eq '_') { $cut = $j; break }
                            }
                            if ($cut -lt 1) { $cut = $avail }
                            [void]$tokens.Add($wd.Substring(0, $cut))
                            $wd = $wd.Substring($cut)
                        }
                        [void]$tokens.Add($wd)
                    }
                    $cur = ''
                    $firstLine = $true
                    function Emit-WrappedLine([string]$body, [bool]$first) {
                        $lineText = if ($first) { $prefix + $body } else { $contLead + $body }
                        if ($lineText.Length -lt $innerWidth) {
                            $lineText = $lineText + (' ' * ($innerWidth - $lineText.Length))
                        } elseif ($lineText.Length -gt $innerWidth) {
                            $lineText = $lineText.Substring(0, $innerWidth)
                        }
                        $bodyLines.Add('  ' + $pipeL + $lineText + $pipeL)
                    }
                    foreach ($tok in $tokens) {
                        $candidate = if ($cur) { "$cur $tok" } else { $tok }
                        if ($candidate.Length -le $avail) {
                            $cur = $candidate
                        } else {
                            Emit-WrappedLine $cur $firstLine
                            $firstLine = $false
                            $cur = $tok
                        }
                    }
                    if ($cur) { Emit-WrappedLine $cur $firstLine }
                }
            }
            $bodyLines.Add($emptyLine)

            $tmplText = [System.IO.File]::ReadAllText($defaultTmpl, [System.Text.Encoding]::UTF8)
            $tmplText = $tmplText.Replace('{{MEDIAINFO_SUMMARY}}', ($bodyLines -join "`n"))
            # Inject ASCII logo from configured file (relative to script dir or absolute).
            # Default: shared/logo_ascii.txt. Missing file = empty substitution.
            $nfoLogoCfg = if ($config.nfo_logo_path) { [string]$config.nfo_logo_path } else { 'shared/logo_ascii.txt' }
            if ([System.IO.Path]::IsPathRooted($nfoLogoCfg)) {
                $nfoLogoPath = $nfoLogoCfg
            } else {
                $nfoLogoPath = Join-Path $RootDir $nfoLogoCfg
            }
            $logoContent = ''
            if (Test-Path -LiteralPath $nfoLogoPath) {
                $logoContent = [System.IO.File]::ReadAllText($nfoLogoPath, [System.Text.Encoding]::UTF8).TrimEnd("`r","`n")
            }
            $tmplText = $tmplText.Replace('{{LOGO}}', $logoContent)
            # NFO viewers (incl. UNIT3D) read NFO bytes as CP437. UTF-8 mojibakes
            # (BOM EF BB BF renders as "∩╗┐"). Block/box chars (░▒▓█ ═┌─┐│└┘)
            # all map to single bytes in CP437. BG title is transliterated to
            # Latin upstream because CP437 has no Cyrillic.
            $tmplText = $tmplText -replace "`r`n", "`n" -replace "`n", "`r`n"
            $cp437 = [System.Text.Encoding]::GetEncoding(437)

            $generatedNfo = Join-Path $OutDir "${TorrentName}_default.nfo"
            [System.IO.File]::WriteAllText($generatedNfo, $tmplText, $cp437)
            $NfoFile = $generatedNfo
            Write-Host "NFO not found in torrent; generated default: $NfoFile" -ForegroundColor DarkGray
        }
}

# Build BDInfo bbcode file (subtitle announcements) for movie/tv only
$BdinfoFile = ''
if (-not ($game.IsPresent -or $software.IsPresent -or $music.IsPresent)) {
    $bdinfoLines = @()
    $stringsFile = Join-Path $RootDir 'shared/bdinfo_strings.txt'
    if (Test-Path -LiteralPath $stringsFile) {
        $bdStrings = @{}
        foreach ($sline in [System.IO.File]::ReadAllLines($stringsFile, [System.Text.Encoding]::UTF8)) {
            if ($sline -match '^([^=]+)=(.*)$') { $bdStrings[$matches[1].Trim()] = $matches[2] }
        }
        $flagBg = $bdStrings['flag_bg']
        $flagEn = $bdStrings['flag_en']
        if ($bgSubsInTorrent) {
            $key = if ($bgSrtGt) { 'bg_in_torrent_ai' } else { 'bg_in_torrent' }
            $bdinfoLines += "$flagBg $($bdStrings[$key])"
        }
        if ($enSubsInTorrent)   { $bdinfoLines += "$flagEn $($bdStrings['en_in_torrent'])" }
        if ($bgSubsInContainer) { $bdinfoLines += "$flagBg $($bdStrings['bg_in_container'])" }
        if ($enSubsInContainer) { $bdinfoLines += "$flagEn $($bdStrings['en_in_container'])" }
    }
    if ($bdinfoLines.Count -gt 0) {
        $BdinfoFile = Join-Path $OutDir "${TorrentName}_bdinfo.bbcode"
        [System.IO.File]::WriteAllText($BdinfoFile, (($bdinfoLines -join "`n") + "`n"), $utf8NoBom)
        Write-Host "BDInfo notes saved to: $BdinfoFile" -ForegroundColor Cyan
    }
}

# Write request file
$catTypeHint = if ($game.IsPresent) { 'game' }
    elseif ($software.IsPresent) { 'software' }
    elseif ($music.IsPresent) { 'music' }
    elseif ($tv.IsPresent) { 'tv' }
    else { 'movie' }
$requestLines = @(
    "torrent_name=$TorrentName"
    "name=$UploadName"
    "category_id=$CategoryId"
    "cat_type=$catTypeHint"
    "type_id=$TypeId"
)
if (-not ($game.IsPresent -or $software.IsPresent -or $music.IsPresent)) {
    $requestLines += "resolution_id=$ResolutionId"
}
$requestLines += @(
    "tmdb=$Tmdb"
    "imdb=$Imdb"
    "igdb=$Igdb"
    "discogs_id=$DiscogsId"
    "personal=$Personal"
    "anonymous=$Anonymous"
    "internal=$Internal"
    "featured=$Featured"
    "free=$Free"
    "fl_until=$FlUntil"
    "doubleup=$DoubleUp"
    "du_until=$DuUntil"
    "sticky=$Sticky"
    "mod_queue_opt_in=$ModQueue"
    "season_number=$SeasonNumber"
    "episode_number=$EpisodeNumber"
    "poster=$PosterUrl"
    "banner=$BannerUrl"
    "description_file=$TorrentDescFile"
    "mediainfo_file=$MediainfoFile"
    "bdinfo_file=$BdinfoFile"
    "nfo_file=$NfoFile"
    "keywords_file=$KeywordsFile"
)
[System.IO.File]::WriteAllText($RequestFile, ($requestLines -join "`n") + "`n", $utf8NoBom)
Write-Host "Upload request saved to: $RequestFile"
