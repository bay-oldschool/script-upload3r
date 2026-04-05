#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Generates a Bulgarian software description using AI from directory name.
.PARAMETER directory
    Path to the content directory or file.
.PARAMETER configfile
    Path to the JSONC config file.
.PARAMETER query
    Override auto-detected software title.
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

# Clean software title from dirname
if ($query) {
    $cleanName = $query
} else {
    $cleanName = $baseName
    # Remove bracketed tags like [SKIDROW], (GOG), {PLAZA}
    $cleanName = $cleanName -replace '\s*[\[\(\{][^\]\)\}]+[\]\)\}]\s*', ' '
    # Normalize separators to dots for consistent regex matching
    $cleanName = $cleanName -replace '[\s_]', '.'
    # Remove repack/by author tags
    $cleanName = $cleanName -replace '(?i)[-\.]by[-\.].+$', ''
    $cleanName = $cleanName -replace '(?i)[-\.](RePack|Repack|Portable|Cracked|Patched|PreActivated|Activated|Keygen|Serial|Crack)[-\.]?', ''
    # Remove scene group tags
    $cleanName = $cleanName -replace '(?i)[-\.](XFORCE|P2P|TNT|AMPED|RECOiL|FOSI|CYGiSO|ECZ|MAGNiTUDE|SSQ|WinAll|Multilingual|x64|x86|Win64|Win32|macOS|Linux)$', ''
    # Remove version tags like v1.2.3 or 10.2.1
    $cleanName = $cleanName -replace '(?i)[-\.]v?\d+[\.\d]+[-\.\s]*$', ''
    # Replace dots/underscores with spaces
    $cleanName = $cleanName -replace '[._]', ' '
    # Remove year from end
    $cleanName = $cleanName -replace '\s*(19|20)\d{2}\s*$', ''
    $cleanName = ($cleanName -replace '\s+', ' ').Trim()
}

# Try to extract version from dirname (normalize spaces/underscores to dots for matching)
$version = ''
$baseNorm = $baseName -replace '[\s_]', '.'
if ($baseNorm -match '(?i)v?(\d+(?:\.\d+){1,5})') {
    $version = $matches[1]
}

Write-Host "Generating AI description for: $cleanName" -ForegroundColor Cyan
if ($version) { Write-Host "  Version: $version" }
Write-Host "Using AI: $AiProvider / $AiModel"

# Build prompt
$promptLines = @()
$promptLines += "Title: $cleanName"
if ($version) {
    $promptLines += "Version: $version"
} else {
    $promptLines += "Version: NONE"
}

$promptLines += "Cover: MISSING"
$promptLines += "Screenshots: MISSING"

$promptText = $promptLines -join "`n"

# Write prompt to temp file
$promptFile = [System.IO.Path]::GetTempFileName()
[System.IO.File]::WriteAllText($promptFile, $promptText, $utf8NoBom)

# Call AI
$systemFile = Join-Path "$PSScriptRoot/.." "shared/ai_system_prompt_software.txt"
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
    Write-Host "Software description saved to: $OutputFile" -ForegroundColor Green
} else {
    Write-Host "Error: AI did not produce output" -ForegroundColor Red
    exit 1
}
