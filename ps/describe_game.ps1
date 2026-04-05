#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Generates a Bulgarian game description using IGDB metadata and AI.
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

$hasIgdb = $TwitchClientId -and $TwitchClientSecret

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

# Read IGDB data if available
$IgdbFile = Join-Path -Path $OutDir -ChildPath "${baseName}_igdb.txt"
$hasIgdbData = $false
if ($hasIgdb) {
    if (-not (Test-Path -LiteralPath $IgdbFile)) {
        Write-Host "IGDB file not found, running igdb.ps1 first..." -ForegroundColor Yellow
        $igdbArgs = @{ directory = $directory; configfile = $configfile }
        if ($query) { $igdbArgs['query'] = $query }
        & "$PSScriptRoot/igdb.ps1" @igdbArgs
    }
    if (Test-Path -LiteralPath $IgdbFile) { $hasIgdbData = $true }
} else {
    Write-Host "IGDB not configured, generating description from directory name only." -ForegroundColor Yellow
    if (Test-Path -LiteralPath $IgdbFile) { $hasIgdbData = $true }
}

# Parse IGDB data if available
$igdbId = ''; $gameName = ''; $releaseDate = ''; $releaseYear = ''; $genres = ''; $platforms = ''
$developers = ''; $publishers = ''; $gameModes = ''; $themes = ''
$userRating = ''; $metaRating = ''; $coverUrl = ''; $summary = ''; $igdbUrl = ''

if ($hasIgdbData) {
    $igdbContent = Get-Content -LiteralPath $IgdbFile -Encoding UTF8
    foreach ($line in $igdbContent) {
        if ($line -match '^\[1\]\s+(.+)\s+\((\d{4})\)') { $gameName = $matches[1]; $releaseYear = $matches[2] }
        if ($line -match '^\s+IGDB ID:\s+(.+)') { $igdbId = $matches[1].Trim() }
        if ($line -match '^\s+IGDB URL:\s+(.+)') { $igdbUrl = $matches[1].Trim() }
        if ($line -match '^\s+Released:\s+(.+)') { $releaseDate = $matches[1].Trim() }
        if ($line -match '^\s+Genres:\s+(.+)') { $genres = $matches[1].Trim() }
        if ($line -match '^\s+Platforms:\s+(.+)') { $platforms = $matches[1].Trim() }
        if ($line -match '^\s+Game Modes:\s+(.+)') { $gameModes = $matches[1].Trim() }
        if ($line -match '^\s+Themes:\s+(.+)') { $themes = $matches[1].Trim() }
        if ($line -match '^\s+Developer\(s\):\s+(.+)') { $developers = $matches[1].Trim() }
        if ($line -match '^\s+Publisher\(s\):\s+(.+)') { $publishers = $matches[1].Trim() }
        if ($line -match '^\s+User Rating:\s+(.+)') { $userRating = $matches[1].Trim() }
        if ($line -match '^\s+Meta Rating:\s+(.+)') { $metaRating = $matches[1].Trim() }
        if ($line -match '^\s+Cover:\s+(.+)') { $coverUrl = $matches[1].Trim() }
        if ($line -match '^\s+Summary:\s+(.+)') { $summary = $matches[1].Trim() }
        if ($line -match '^\[2\]') { break }
    }
}

# Fallback: clean game title from dirname if no IGDB data
if (-not $gameName) {
    if ($query) {
        $gameName = $query
    } else {
        $gameName = $baseName
        # Remove bracketed tags like [SKIDROW], (GOG), {PLAZA}
        $gameName = $gameName -replace '\s*[\[\(\{][^\]\)\}]+[\]\)\}]\s*', ' '
        $gameName = $gameName -replace '(?i)[-\.](CODEX|PLAZA|GOG|FLT|SKIDROW|RELOADED|RUNE|DARKSiDERS|TiNYiSO|EMPRESS|SiMPLEX|DOGE|Razor1911|HI2U|ANOMALY|P2P|KaOs|FitGirl|DODI)$', ''
        $gameName = $gameName -replace '(?i)[-\.]v?\d+[\.\d]+\s*$', ''
        $gameName = $gameName -replace '(?i)[-\.](PC|MAC|Linux|PS[345]?|Xbox|Switch|NSW|GOG|Steam|Repack|Portable|Deluxe|Ultimate|Gold|GOTY|Premium|Complete|Edition|Collection|Update|DLC|Incl|MULTi\d*)[-\.]?', ' '
        $gameName = $gameName -replace '[._]', ' '
        $gameName = $gameName -replace '\s*(19|20)\d{2}\s*$', ''
        $gameName = ($gameName -replace '\s+', ' ').Trim()
    }
}

Write-Host "Generating AI description for: $gameName" -NoNewline
if ($releaseYear) { Write-Host " ($releaseYear)" -NoNewline }
Write-Host "" -ForegroundColor Cyan
Write-Host "Using AI: $AiProvider / $AiModel"

# Build prompt
$promptLines = @()
$promptLines += "Title: $gameName"
if ($releaseDate) { $promptLines += "Release Date: $releaseDate" }
if ($releaseYear) {
    $promptLines += "Release Year: $releaseYear"
} else {
    $promptLines += "Release Year: (not provided, write title WITHOUT year in parentheses)"
}
if ($igdbId) { $promptLines += "IGDB ID: $igdbId" }
if ($genres) { $promptLines += "Genres: $genres" }
if ($platforms) { $promptLines += "Platforms: $platforms" }
if ($gameModes) { $promptLines += "Game Modes: $gameModes" }
if ($themes) { $promptLines += "Themes: $themes" }
if ($developers) { $promptLines += "Developer(s): $developers" }
if ($publishers) { $promptLines += "Publisher(s): $publishers" }
if ($userRating) { $promptLines += "User Rating: $userRating" }
if ($metaRating) { $promptLines += "Meta Rating: $metaRating" }
if ($coverUrl) { $promptLines += "Cover: $coverUrl" } else { $promptLines += "Cover: MISSING" }
if ($summary) { $promptLines += "Summary: $summary" }
# Check if IGDB screenshots exist
$hasIgdbScreenshots = $false
if ($hasIgdbData) {
    $screenshotLines = Get-Content -LiteralPath $IgdbFile -Encoding UTF8 | Where-Object { $_ -match '^\s+Screenshot:' }
    if ($screenshotLines) { $hasIgdbScreenshots = $true }
}
if (-not $hasIgdbScreenshots) { $promptLines += "Screenshots: MISSING" }

$promptText = $promptLines -join "`n"

# Write prompt to temp file
$promptFile = [System.IO.Path]::GetTempFileName()
[System.IO.File]::WriteAllText($promptFile, $promptText, $utf8NoBom)

# Call AI
$systemFile = Join-Path "$PSScriptRoot/.." "shared/ai_system_prompt_game.txt"
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
    if ($descText -match '(?m)^POSTER_URL:\s*(.+?)\s*$') {
        $aiPosterUrl = $matches[1].Trim()
        $descText = ($descText -replace '(?m)\r?\nPOSTER_URL:\s*.+\s*$', '').TrimEnd()
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
    [System.IO.File]::WriteAllText($OutputFile, $descText, $utf8NoBom)
    Write-Host "Game description saved to: $OutputFile" -ForegroundColor Green
} else {
    Write-Host "Error: AI did not produce output" -ForegroundColor Red
    exit 1
}
