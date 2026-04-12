#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Logs in to the configured tracker and scrapes the live category list
    from the upload form, writing a JSONC file the pipeline can consume.
.PARAMETER configfile
    Path to config.jsonc (default: project root).
.PARAMETER out
    Output JSONC path (default: shared/categories_<tracker_host>.jsonc).
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
if (-not $TrackerUrl) { Write-Host "tracker_url not set in config" -ForegroundColor Red; exit 1 }
if (-not $webUser -or -not $webPass) { Write-Host "username/password not set in config" -ForegroundColor Red; exit 1 }

if (-not $out) {
    $trackerHost = ([System.Uri]$TrackerUrl).Host -replace '[^A-Za-z0-9]', '_'
    $out = Join-Path $RootDir "shared\categories_${trackerHost}.jsonc"
}

$cj = [System.IO.Path]::GetTempFileName()
$hf = [System.IO.Path]::GetTempFileName()
try {
    Write-Host "Logging in to $TrackerUrl ..." -ForegroundColor Cyan
    $loginPage = (& curl.exe -s -c $cj -b $cj "${TrackerUrl}/login") -join "`n"
    $cs = ''; if ($loginPage -match 'name="_token"\s*value="([^"]+)"') { $cs = $matches[1] }
    $ca = ''; if ($loginPage -match 'name="_captcha"\s*value="([^"]+)"') { $ca = $matches[1] }
    $rn = ''; $rv = ''
    if ($loginPage -match 'name="([A-Za-z0-9]{16})"\s*value="(\d+)"') { $rn = $matches[1]; $rv = $matches[2] }
    if (-not $cs) { Write-Host "Could not extract _token from /login" -ForegroundColor Red; exit 1 }
    $rf = @(); if ($rn) { $rf = @('-d', "${rn}=${rv}") }
    & curl.exe -s -D $hf -o NUL -c $cj -b $cj `
        -d "_token=$cs" -d "_captcha=$ca" -d "_username=" `
        -d "username=$webUser" --data-urlencode "password=$webPass" `
        -d "remember=on" @rf "${TrackerUrl}/login"
    $ll = ''
    foreach ($h in Get-Content -LiteralPath $hf) {
        if ($h -match '^Location:\s*(.+)') { $ll = $matches[1].Trim() }
    }
    if ($ll -match '/login') { Write-Host "Login failed (redirected back to /login)" -ForegroundColor Red; exit 1 }
    if ($ll) { & curl.exe -s -o NUL -c $cj -b $cj --max-time 15 $ll | Out-Null }

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
        # Heuristic type from name
        $nl = $name.ToLower()
        $type = 'movie'
        if     ($nl -match 'music|flac|mp3|lossless|vinyl|dts|hi-?res') { $type = 'music' }
        elseif ($nl -match 'tv|series|\banime\b|\bseason\b') { $type = 'tv' }
        elseif ($nl -match 'game|xbox|playstation|nintendo|console') { $type = 'game' }
        elseif ($nl -match 'software|program|app|mac|android|ios|gsm|mobile') { $type = 'software' }
        elseif ($nl -match 'xxx|adult') { $type = 'other' }
        $entries += [pscustomobject]@{ name = $name; id = $id; type = $type }
    }

    Write-Host "Found $($entries.Count) categories:" -ForegroundColor Green
    foreach ($e in $entries) { Write-Host ("  {0,3}  {1,-10}  {2}" -f $e.id, $e.type, $e.name) }

    $outDir = Split-Path -Parent $out
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -Path $outDir -ItemType Directory -Force | Out-Null }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("// Auto-generated by ps/fetch_categories.ps1 from ${TrackerUrl}/torrents/create")
    $lines.Add("// Types are guessed from names - edit by hand if needed.")
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
    Write-Host "Point 'categories_file' in config.jsonc at this path to use it." -ForegroundColor Cyan
} finally {
    Remove-Item -LiteralPath $cj, $hf -ErrorAction SilentlyContinue
}
