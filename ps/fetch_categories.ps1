#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Logs in to the configured tracker and scrapes the live category list
    from the upload form, writing a JSONC file the pipeline can consume.
.PARAMETER configfile
    Path to config.jsonc (default: project root).
.PARAMETER out
    Output JSONC path (default: output/categories_<tracker_host>.jsonc).
#>
param(
    [string]$configfile,
    [string]$out
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$RootDir = Split-Path -Parent $PSScriptRoot

if (-not $configfile) { $configfile = Join-Path $RootDir 'config.jsonc' }
if (-not (Test-Path -LiteralPath $configfile)) {
    Write-Host "Config not found: $configfile" -ForegroundColor Red
    exit 1
}

$config = (Get-Content -LiteralPath $configfile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json
$TrackerUrl = if ($config.tracker_url) { ([string]$config.tracker_url).TrimEnd('/') } else { '' }
$webUser = $config.username
$webPass = $config.password
$webTfa  = if ($config.two_factor_secret) { $config.two_factor_secret } else { '' }
if (-not $TrackerUrl) { Write-Host "tracker_url not set in config" -ForegroundColor Red; exit 1 }
if (-not $webUser -or -not $webPass) { Write-Host "username/password not set in config" -ForegroundColor Red; exit 1 }

. (Join-Path (Join-Path $RootDir 'shared') 'web_login.ps1')

if (-not $out) {
    $trackerHost = ([System.Uri]$TrackerUrl).Host -replace '\.[^.]+$','' -replace '[^A-Za-z0-9]','_'
    $out = Join-Path $RootDir "output\categories_${trackerHost}.jsonc"
}

$fcOutDir = Join-Path $RootDir 'output'
$hf = [System.IO.Path]::GetTempFileName()
try {
    $cj = Get-CachedCookieJar -TrackerUrl $TrackerUrl -Username $webUser `
        -Password $webPass -TwoFactorSecret $webTfa -OutputDir $fcOutDir
    if (-not $cj) {
        Write-Host "Login failed. Check credentials and two_factor_secret in config.jsonc." -ForegroundColor Red
        Write-Host "Press any key to continue ..." -ForegroundColor Yellow
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        exit 1
    }

    Write-Host "Fetching upload form ..." -ForegroundColor Cyan
    $createPage = (& curl.exe -s -c $cj -b $cj --max-time 30 "${TrackerUrl}/torrents/create") -join "`n"
    if (-not $createPage -or $createPage.Length -lt 200) {
        Write-Host "Upload form returned empty/short response" -ForegroundColor Red
        exit 1
    }

    # Locate the category <select> block and extract its <option> list
    $selectMatch = [regex]::Match($createPage, '<select[^>]*name="category_id"[^>]*>([\s\S]*?)</select>', 'IgnoreCase')
    if (-not $selectMatch.Success) {
        # Fallback: look for category radio/button group (some UNIT3D forks)
        $selectMatch = [regex]::Match($createPage, 'name="category_id"[\s\S]{0,4000}?</(?:select|div)>', 'IgnoreCase')
    }
    if (-not $selectMatch.Success) {
        Write-Host "Could not find category_id <select> in upload form." -ForegroundColor Red
        $dumpPath = [System.IO.Path]::ChangeExtension($out, '.html')
        [System.IO.File]::WriteAllText($dumpPath, $createPage, (New-Object System.Text.UTF8Encoding $false))
        Write-Host "Saved the upload form HTML to $dumpPath for inspection." -ForegroundColor Yellow
        exit 1
    }

    $optRe = [regex]'<option[^>]*value="(?<id>\d+)"[^>]*>(?<name>[^<]+)</option>'
    $matches = $optRe.Matches($selectMatch.Value)
    if ($matches.Count -eq 0) {
        Write-Host "No <option> tags found in category select." -ForegroundColor Red
        exit 1
    }

    $entries = @()
    foreach ($m in $matches) {
        $id = [int]$m.Groups['id'].Value
        $name = [System.Net.WebUtility]::HtmlDecode($m.Groups['name'].Value).Trim()
        if ($id -le 0 -or -not $name) { continue }
        # Heuristic type from name. Cyrillic keywords are encoded as \uXXXX so this
        # file stays pure ASCII (PS5.1 reads .ps1 with the system code page, not UTF-8).
        # The .NET regex engine expands the escapes at match time, so patterns still hit
        # Bulgarian / Russian category labels like "Филми", "Сериали", "Игри".
        $nl = $name.ToLowerInvariant()
        $type = 'movie'
        if     ($nl -match 'music|flac|mp3|lossless|vinyl|dts|hi-?res|\u043C\u0443\u0437\u0438\u043A') { $type = 'music' }
        elseif ($nl -match 'tv|series|\banime\b|\bseason\b|\u0441\u0435\u0440\u0438\u0430\u043B|\u0430\u043D\u0438\u043C\u0435') { $type = 'tv' }
        elseif ($nl -match 'game|xbox|playstation|nintendo|console|\u0438\u0433\u0440\u0430|\u0438\u0433\u0440\u0438') { $type = 'game' }
        elseif ($nl -match 'software|program|app|mac|android|ios|gsm|mobile|\u0441\u043E\u0444\u0442|\u043F\u0440\u0438\u043B\u043E\u0436') { $type = 'software' }
        elseif ($nl -match 'xxx|adult|\u043F\u043E\u0440\u043D\u043E') { $type = 'other' }
        $entries += [pscustomobject]@{ name = $name; id = $id; type = $type }
    }

    Write-Host "Found $($entries.Count) categories:" -ForegroundColor Green
    foreach ($e in $entries) { Write-Host ("  {0,3}  {1,-10}  {2}" -f $e.id, $e.type, $e.name) }

    $outDir = Split-Path -Parent $out
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -Path $outDir -ItemType Directory -Force | Out-Null }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("// Auto-generated by ps/fetch_categories.ps1 from ${TrackerUrl}/torrents/create")
    $lines.Add("// WARNING: the ""type"" field is a best-guess from each category name and")
    $lines.Add("// WILL be wrong for trackers with non-English or custom category labels.")
    $lines.Add("// Review every row and correct any wrong type before uploading, otherwise")
    $lines.Add("// the pipeline may run the wrong flow (e.g. movie flow on a game category).")
    $lines.Add("// Valid types: movie, tv, music, game, software, other")
    $lines.Add("[")
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $e = $entries[$i]
        $sep = if ($i -lt $entries.Count - 1) { ',' } else { '' }
        $nameEsc = ($e.name -replace '\\', '\\' -replace '"', '\"')
        $lines.Add(("  {{ ""name"": ""{0}"", ""id"": {1}, ""type"": ""{2}"" }}{3}" -f $nameEsc, $e.id, $e.type, $sep))
    }
    $lines.Add("]")
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($out, ($lines -join "`r`n") + "`r`n", $utf8NoBom)
    Write-Host ""
    Write-Host "Wrote: $out" -ForegroundColor Green
    Write-Host "The pipeline will automatically use this file for uploads." -ForegroundColor Cyan
    Write-Host "To override, set `"categories_file`" in config.jsonc to a different path." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "WARNING: category 'type' values were auto-guessed from names and may be wrong." -ForegroundColor Yellow
    Write-Host "         Open the file above and correct any mismatches before uploading" -ForegroundColor Yellow
    Write-Host "         (valid types: movie, tv, music, game, software, other)." -ForegroundColor Yellow
} finally {
    $toRemove = @($hf) + @($cj) | Where-Object { $_ }
    if ($toRemove) { Remove-Item -LiteralPath $toRemove -ErrorAction SilentlyContinue }
}
