#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Generates a Bulgarian music description using MusicBrainz metadata and AI.
.PARAMETER directory
    Path to the content directory or file.
.PARAMETER configfile
    Path to the JSONC config file.
.PARAMETER query
    Override auto-detected album title for MusicBrainz search.
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

$GeminiApiKey = $config.gemini_api_key
$GeminiModel  = if ($config.gemini_model) { $config.gemini_model } else { "gemini-2.5-flash-lite" }
$OllamaModel  = $config.ollama_model
$OllamaUrl    = if ($config.ollama_url) { $config.ollama_url } else { "http://localhost:11434" }
$GroqApiKey   = $config.groq_api_key
$GroqModel    = if ($config.groq_model) { $config.groq_model } else { "qwen/qwen3-32b" }
$GrokApiKey   = $config.grok_api_key
$GrokModel    = if ($config.grok_model) { $config.grok_model } else { "grok-3-mini" }
$CerebrasApiKey = $config.cerebras_api_key
$CerebrasModel  = if ($config.cerebras_model) { $config.cerebras_model } else { "llama-3.3-70b" }
$SambaNovaApiKey = $config.sambanova_api_key
$SambaNovaModel  = if ($config.sambanova_model) { $config.sambanova_model } else { "Meta-Llama-3.1-70B-Instruct" }
$OpenRouterApiKey = $config.openrouter_api_key
$OpenRouterModel  = if ($config.openrouter_model) { $config.openrouter_model } else { "qwen/qwen3-32b:free" }
$HuggingFaceApiKey = $config.huggingface_api_key
$HuggingFaceModel  = if ($config.huggingface_model) { $config.huggingface_model } else { "Qwen/Qwen2.5-72B-Instruct" }
$AiProviderCfg = $config.ai_provider

# Determine AI provider
if ($AiProviderCfg -eq "gemini" -and $GeminiApiKey) {
    $AiProvider = "gemini"; $AiModel = $GeminiModel
} elseif ($AiProviderCfg -eq "groq" -and $GroqApiKey) {
    $AiProvider = "groq"; $AiModel = $GroqModel
} elseif ($AiProviderCfg -eq "grok" -and $GrokApiKey) {
    $AiProvider = "grok"; $AiModel = $GrokModel
} elseif ($AiProviderCfg -eq "cerebras" -and $CerebrasApiKey) {
    $AiProvider = "cerebras"; $AiModel = $CerebrasModel
} elseif ($AiProviderCfg -eq "sambanova" -and $SambaNovaApiKey) {
    $AiProvider = "sambanova"; $AiModel = $SambaNovaModel
} elseif ($AiProviderCfg -eq "openrouter" -and $OpenRouterApiKey) {
    $AiProvider = "openrouter"; $AiModel = $OpenRouterModel
} elseif ($AiProviderCfg -eq "huggingface" -and $HuggingFaceApiKey) {
    $AiProvider = "huggingface"; $AiModel = $HuggingFaceModel
} elseif ($AiProviderCfg -eq "ollama" -and $OllamaModel) {
    $AiProvider = "ollama"; $AiModel = $OllamaModel
} elseif ($OllamaModel) {
    $AiProvider = "ollama"; $AiModel = $OllamaModel
} elseif ($GroqApiKey) {
    $AiProvider = "groq"; $AiModel = $GroqModel
} elseif ($GrokApiKey) {
    $AiProvider = "grok"; $AiModel = $GrokModel
} elseif ($CerebrasApiKey) {
    $AiProvider = "cerebras"; $AiModel = $CerebrasModel
} elseif ($SambaNovaApiKey) {
    $AiProvider = "sambanova"; $AiModel = $SambaNovaModel
} elseif ($OpenRouterApiKey) {
    $AiProvider = "openrouter"; $AiModel = $OpenRouterModel
} elseif ($HuggingFaceApiKey) {
    $AiProvider = "huggingface"; $AiModel = $HuggingFaceModel
} elseif ($GeminiApiKey) {
    $AiProvider = "gemini"; $AiModel = $GeminiModel
} else {
    Write-Host "Skipping: no AI provider configured" -ForegroundColor Yellow
    exit 0
}

$OutDir = "$PSScriptRoot/../output"
New-Item -Path $OutDir -ItemType Directory -ErrorAction SilentlyContinue
$OutputFile = Join-Path -Path $OutDir -ChildPath "${baseName}_description.bbcode"

# Read music metadata if available (from Deezer or MusicBrainz)
$MusicFile = Join-Path -Path $OutDir -ChildPath "${baseName}_music.txt"
$hasMusicData = $false
if (-not (Test-Path -LiteralPath $MusicFile)) {
    Write-Host "Music metadata file not found, running music.ps1 first..." -ForegroundColor Yellow
    $mbArgs = @{ directory = $directory; configfile = $configfile }
    if ($query) { $mbArgs['query'] = $query }
    & "$PSScriptRoot/music.ps1" @mbArgs
}
if (Test-Path -LiteralPath $MusicFile) { $hasMusicData = $true }

# Parse music metadata (works with both Deezer and MusicBrainz output format)
$musicId = ''; $musicUrl = ''; $albumName = ''; $artistName = ''; $releaseDate = ''; $releaseYear = ''
$albumType = ''; $genres = ''; $label = ''; $coverUrl = ''
$tracks = @()

if ($hasMusicData) {
    $musicContent = Get-Content -LiteralPath $MusicFile -Encoding UTF8
    $inFirstResult = $false
    foreach ($line in $musicContent) {
        if ($line -match '^\[1\]\s+(.+?)\s+-\s+(.+?)\s+\((\d{4})\)') {
            $artistName = $matches[1]; $albumName = $matches[2]; $releaseYear = $matches[3]
            $inFirstResult = $true
        } elseif ($line -match '^\[1\]\s+(.+?)\s+-\s+(.+)$' -and -not $albumName) {
            $artistName = $matches[1]; $albumName = $matches[2]
            $inFirstResult = $true
        }
        # Stop reading [1] header fields at [2], but continue scanning for details/tracks
        if ($line -match '^\[2\]') { $inFirstResult = $false }
        if ($inFirstResult) {
            # Deezer fields
            if ($line -match '^\s+Deezer ID:\s+(.+)') { $musicId = $matches[1].Trim() }
            if ($line -match '^\s+Deezer URL:\s+(.+)') { $musicUrl = $matches[1].Trim() }
            # Discogs fields
            if ($line -match '^\s+Discogs ID:\s+(.+)') { $musicId = $matches[1].Trim() }
            if ($line -match '^\s+Discogs URL:\s+(.+)') { $musicUrl = $matches[1].Trim() }
            # MusicBrainz fields
            if ($line -match '^\s+MBID:\s+(.+)') { $musicId = $matches[1].Trim() }
            if ($line -match '^\s+MB URL:\s+(.+)') { $musicUrl = $matches[1].Trim() }
            # Common fields
            if ($line -match '^\s+Artist:\s+(.+)') { $artistName = $matches[1].Trim() }
            if ($line -match '^\s+Released:\s+(.+)') { $releaseDate = $matches[1].Trim() }
            if ($line -match '^\s+Type:\s+(.+)') { $albumType = $matches[1].Trim() }
        }
        # Fields that appear in both [1] header and --- Details --- section
        if ($line -match '^\s+Label:\s+(.+)') { $label = $matches[1].Trim() }
        if ($line -match '^\s+Genres:\s+(.+)') { $genres = $matches[1].Trim() }
        if ($line -match '^\s+Cover:\s+(.+)') { $coverUrl = $matches[1].Trim() }
        if ($line -match '^\s+Track:\s+(.+)') { $tracks += $matches[1].Trim() }
    }
}

# Fallback: parse artist/album/year from dirname if no MusicBrainz data
if (-not $albumName) {
    if ($query) {
        $albumName = $query
    } else {
        $raw = $baseName
        # Remove square-bracket tags like [FLAC 24-48] — keep parentheses (part of title)
        $raw = $raw -replace '\s*\[[^\]]+\]\s*', ' '
        $raw = $raw -replace '\s*\{[^}]+\}\s*', ' '
        $raw = $raw -replace '[._]', ' '
        # Remove format/quality words
        $raw = $raw -replace '(?i)\b(FLAC|MP3|AAC|OGG|OPUS|WEB|CD|VINYL|LP|Lossless|320|V0|V2|CBR|VBR|16bit|24bit|16-44|24-48|24-96|24-192|Hi-?Res)\b', ' '
        # Remove scene group tags at end
        $raw = $raw -replace '(?i)\s*[-](PERFECT|FATHEAD|ENRiCH|YARD|WRE|dL|AMRAP|JLM|D2H|FiH|NBFLAC|DGN|TOSK|ERP)\s*$', ''
        # Extract year from end
        if ($raw -match '\s+((?:19|20)\d{2})\s*$') {
            if (-not $releaseYear) { $releaseYear = $matches[1] }
            $raw = $raw -replace '\s+(19|20)\d{2}\s*$', ''
        }
        $raw = ($raw -replace '\s+', ' ').Trim()
        # Try to split "Artist - Album"
        if ($raw -match '^(.+?)\s+-\s+(.+)$') {
            if (-not $artistName) { $artistName = $matches[1].Trim() }
            $albumName = $matches[2].Trim()
        } else {
            $albumName = $raw
        }
    }
}

Write-Host "Generating AI description for: $artistName - $albumName" -NoNewline
if ($releaseYear) { Write-Host " ($releaseYear)" -NoNewline }
Write-Host "" -ForegroundColor Cyan
Write-Host "Using AI: $AiProvider / $AiModel"

# Build prompt
$promptLines = @()
if ($artistName) { $promptLines += "Artist: $artistName" }
$promptLines += "Album: $albumName"
if ($releaseDate) { $promptLines += "Release Date: $releaseDate" }
if ($releaseYear) {
    $promptLines += "Release Year: $releaseYear"
} else {
    $promptLines += "Release Year: (not provided, write title WITHOUT year in parentheses)"
}
if ($musicId) { $promptLines += "Music ID: $musicId" }
if ($albumType) { $promptLines += "Type: $albumType" }
if ($genres) { $promptLines += "Genres: $genres" }
if ($label) { $promptLines += "Label: $label" }
if ($coverUrl) { $promptLines += "Cover: $coverUrl" } else { $promptLines += "Cover: MISSING" }
    # Track listing is injected programmatically after AI output — not sent to AI

$promptText = $promptLines -join "`n"

# Write prompt to temp file
$promptFile = [System.IO.Path]::GetTempFileName()
[System.IO.File]::WriteAllText($promptFile, $promptText, $utf8NoBom)

# Call AI
$systemFile = Join-Path "$PSScriptRoot/.." "shared/ai_system_prompt_music.txt"
$aiArgs = @{
    promptfile = $promptFile
    outputfile = $OutputFile
    provider   = $AiProvider
    model      = $AiModel
    systemfile = $systemFile
}
if ($AiProvider -eq 'gemini') { $aiArgs['apikey'] = $GeminiApiKey }
if ($AiProvider -eq 'groq') { $aiArgs['apikey'] = $GroqApiKey }
if ($AiProvider -eq 'grok') { $aiArgs['apikey'] = $GrokApiKey }
if ($AiProvider -eq 'cerebras') { $aiArgs['apikey'] = $CerebrasApiKey }
if ($AiProvider -eq 'sambanova') { $aiArgs['apikey'] = $SambaNovaApiKey }
if ($AiProvider -eq 'openrouter') { $aiArgs['apikey'] = $OpenRouterApiKey }
if ($AiProvider -eq 'huggingface') { $aiArgs['apikey'] = $HuggingFaceApiKey }
if ($AiProvider -eq 'ollama') { $aiArgs['baseurl'] = $OllamaUrl }

& "$PSScriptRoot/../shared/ai_call.ps1" @aiArgs

Remove-Item -LiteralPath $promptFile -ErrorAction SilentlyContinue

if (Test-Path -LiteralPath $OutputFile) {
    $descText = [System.IO.File]::ReadAllText($OutputFile, [System.Text.Encoding]::UTF8)
    # Extract POSTER_URL line from AI output if present
    if ($descText -match '(?m)(?:^|\s)POSTER_URL:\s*(\S+)') {
        $aiPosterUrl = $matches[1].Trim()
        $descText = ($descText -replace '(?m)\s*POSTER_URL:\s*\S+', '').TrimEnd()
        $posterFile = Join-Path -Path $OutDir -ChildPath "${baseName}_poster_url.txt"
        [System.IO.File]::WriteAllText($posterFile, $aiPosterUrl, $utf8NoBom)
        Write-Host "AI suggested poster: $aiPosterUrl" -ForegroundColor Cyan
    }
    # Extract SCREENSHOT_URL lines from AI output if present
    $aiScreenshots = @()
    $screenMatches = [regex]::Matches($descText, '(?m)^SCREENSHOT_URL:\s*(.+?)\s*$')
    foreach ($m in $screenMatches) {
        $aiScreenshots += $m.Groups[1].Value.Trim()
    }
    if ($aiScreenshots.Count -gt 0) {
        $descText = ($descText -replace '(?m)\r?\nSCREENSHOT_URL:\s*.+\s*$', '').TrimEnd()
        $screenFile = Join-Path -Path $OutDir -ChildPath "${baseName}_ai_screenshots.txt"
        [System.IO.File]::WriteAllText($screenFile, ($aiScreenshots -join "`n") + "`n", $utf8NoBom)
        Write-Host "AI suggested $($aiScreenshots.Count) screenshot(s)" -ForegroundColor Cyan
    }
    # Inject tracklist programmatically (AI can't be trusted with this)
    if ($tracks.Count -gt 0) {
        $e_headphones = [char]::ConvertFromUtf32(0x1F3A7)
        # Build Cyrillic "Траклист" at runtime (PS5.1 encoding safety)
        $bgTracklist = [char]0x0422 + [char]0x0440 + [char]0x0430 + [char]0x043A + [char]0x043B + [char]0x0438 + [char]0x0441 + [char]0x0442
        $trackBlock = "${e_headphones} [b]${bgTracklist}:[/b]"
        foreach ($t in $tracks) { $trackBlock += "`n$t" }

        # Remove AI-generated tracklist section if present
        $tracklistPattern = '(?m)^.{0,4}\[b\].{0,30}(Tracklist|' + $bgTracklist + ')\S*:\[/b\][\s\S]*?(?=\n.{0,4}\[b\]|\n.{0,4}#|\n\[center\]|\z)'
        $descText = [regex]::Replace($descText, $tracklistPattern, '')
        $descText = $descText.TrimEnd()

        # Insert before hashtags line, or append at end
        $e_label = [char]::ConvertFromUtf32(0x1F3F7)
        $hashtagPattern = '(?m)(^[^\n]{0,10}#[A-Za-z\p{L}])'
        if ($descText -match $hashtagPattern) {
            $descText = [regex]::Replace($descText, $hashtagPattern, "`n${trackBlock}`n`n`$1")
        } else {
            $descText += "`n`n${trackBlock}"
        }
    }

    [System.IO.File]::WriteAllText($OutputFile, $descText, $utf8NoBom)
    Write-Host "Music description saved to: $OutputFile" -ForegroundColor Green
} else {
    Write-Host "Error: AI did not produce output" -ForegroundColor Red
    exit 1
}
