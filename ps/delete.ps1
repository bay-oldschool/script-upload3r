#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Delete a torrent from a UNIT3D tracker by its ID.
.DESCRIPTION
    Fetches torrent info via API, asks for confirmation, then deletes via web session.
    Requires "username" and "password" in config.jsonc.
.PARAMETER torrent_id
    Numeric torrent ID to delete.
.PARAMETER configfile
    Path to JSONC config file (default: ./config.jsonc).
#>
param(
    [Parameter(Position = 0)]
    [string]$torrent_id,

    [Parameter(Position = 1)]
    [string]$configfile,

    [Alias('f')]
    [switch]$force
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSScriptRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $MyInvocation.MyCommand.Definition)

if (-not $torrent_id) {
    Write-Host @"
Usage: delete.ps1 <torrent_id> [config.jsonc]

Delete a torrent from a UNIT3D tracker by its ID.
Fetches torrent info via API, asks for confirmation, then deletes via web session.

Requires "username" and "password" in config.jsonc.

Arguments:
  torrent_id       Numeric torrent ID to delete
  config.jsonc     Path to JSONC config file (default: ./config.jsonc)

Options:
  -f, -force     Skip API fetch and delete without confirmation
  -h, -help      Show this help message
"@
    exit 1
}

if ($torrent_id -notmatch '^\d+$') {
    Write-Host "Error: torrent_id must be a number" -ForegroundColor Red
    exit 1
}

if (-not $configfile) { $configfile = Join-Path $PSScriptRoot "config.jsonc" }

if (-not (Test-Path -LiteralPath $configfile)) {
    Write-Host "Error: config file '$configfile' not found. Run install.bat to create it from config.example.jsonc" -ForegroundColor Red
    exit 1
}

# Read tracker credentials from config
$config     = (Get-Content -LiteralPath $configfile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json
$ApiKey     = $config.api_key
if (-not $ApiKey) { Write-Host "Skipping: 'api_key' not configured in $configfile" -ForegroundColor Yellow; exit 0 }
$TrackerUrl = if ($config.tracker_url) { ([string]$config.tracker_url).TrimEnd('/') } else { '' }
$Username   = $config.username
$Password   = $config.password
$TwoFactorSecret = if ($config.two_factor_secret) { $config.two_factor_secret } else { '' }

if (-not $Username -or -not $Password) {
    Write-Host "Error: 'username' and 'password' must be set in $configfile for deleting" -ForegroundColor Red
    exit 1
}

. (Join-Path (Join-Path $PSScriptRoot 'shared') 'web_login.ps1')

$curName = "Torrent #${torrent_id}"
$deleteReason = "Deleted by uploader"
$webFallback = $false

if ($force) {
    Write-Host "Force mode: skipping fetch, deleting torrent #${torrent_id}..." -ForegroundColor Cyan
} else {
    # Fetch current torrent data via API
    Write-Host "Fetching torrent #${torrent_id}..." -ForegroundColor Cyan
    $apiUrl = "${TrackerUrl}/api/torrents/${torrent_id}?api_token=${ApiKey}"
    $fetchResp = & curl.exe -s --max-time 10 -w "`n%{http_code}" $apiUrl
    $fetchLines = $fetchResp -split "`n"
    $fetchCode  = $fetchLines[-1].Trim()
    $fetchBody  = ($fetchLines[0..($fetchLines.Count - 2)]) -join "`n"

    if ($fetchCode -eq '200') {
        $torrentData = $fetchBody | ConvertFrom-Json
        $attrs = $torrentData.attributes
        $curName       = $attrs.name
        $curCategory   = $attrs.category
        $curType       = $attrs.type
        $curResolution = $attrs.resolution
    } else {
        Write-Host "API fetch failed (HTTP $fetchCode), falling back to web..." -ForegroundColor Yellow
        $webFallback = $true
        $curCategory = ''; $curType = ''; $curResolution = ''
    }
}

# Web session login
$OutDir = Join-Path $PSScriptRoot 'output'
$headerFile = [System.IO.Path]::GetTempFileName()

try {
    Write-Host ""
    $cookieJar = Get-CachedCookieJar -TrackerUrl $TrackerUrl -Username $Username `
        -Password $Password -TwoFactorSecret $TwoFactorSecret -OutputDir $OutDir
    if (-not $cookieJar) {
        Write-Host "Login failed. Check credentials and two_factor_secret in config.jsonc." -ForegroundColor Red
        Write-Host "Press any key to continue ..." -ForegroundColor Yellow
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        exit 1
    }

    # GET torrent page to get _token for CSRF and details
    Write-Host "Fetching torrent page..." -ForegroundColor Cyan
    $torrentPage = (& curl.exe -s -c $cookieJar -b $cookieJar --max-time 30 "${TrackerUrl}/torrents/${torrent_id}") -join "`n"

    # If API failed, scrape torrent details from the web page
    if ($webFallback -and -not $force) {
        if ($torrentPage -match '<h1\s+class="torrent__name">\s*(.*?)\s*</h1>') {
            $curName = [System.Net.WebUtility]::HtmlDecode($matches[1]).Trim()
        }
        if ($torrentPage -match 'class="torrent__category-link"[^>]*>\s*([^<]+)') {
            $curCategory = $matches[1].Trim()
        }
        if ($torrentPage -match 'class="torrent__type-link"[^>]*>\s*([^<]+)') {
            $curType = $matches[1].Trim()
        }
        if ($torrentPage -match 'class="torrent__resolution-link"[^>]*>\s*([^<]+)') {
            $curResolution = $matches[1].Trim()
        }
    }

    if (-not $force) {
        Write-Host ""
        Write-Host "Torrent to delete:" -ForegroundColor Cyan
        Write-Host "  name:          " -NoNewline; Write-Host $curName -ForegroundColor Green
        if ($curCategory) { Write-Host "  category:      " -NoNewline; Write-Host $curCategory -ForegroundColor Green }
        if ($curType) { Write-Host "  type:          " -NoNewline; Write-Host $curType -ForegroundColor Green }
        if ($curResolution) { Write-Host "  resolution:    " -NoNewline; Write-Host $curResolution -ForegroundColor Green }
        Write-Host ""
        Write-Host "  (enter 'c' at any prompt to cancel)" -ForegroundColor DarkGray
        $confirm = Read-Host "Are you sure you want to DELETE this torrent? (y/n) [y]"
        if ($confirm -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
        if (-not $confirm) { $confirm = 'y' }
        if ($confirm -ne 'y' -and $confirm -ne 'yes') {
            Write-Host "Aborted." -ForegroundColor Yellow
            exit 0
        }
        $deleteReason = Read-Host "Reason for deletion"
        if ($deleteReason -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
        if (-not $deleteReason) { $deleteReason = "Deleted by uploader" }
    }

    $formToken = ''
    if ($torrentPage -match 'name="_token"\s*value="([^"]+)"') {
        $formToken = $matches[1]
    }

    if (-not $formToken) {
        Write-Host "Error: could not get _token from torrent page. You may not have permission to delete this torrent." -ForegroundColor Red
        exit 1
    }

    # Step 4: POST with _method=DELETE (requires type, id, title, message fields)
    Write-Host "Deleting torrent #${torrent_id}..." -ForegroundColor Cyan

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $tempName = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tempName, $curName, $utf8NoBom)

    $response = & curl.exe -s -w "`n%{http_code}" --max-time 30 `
        -D $headerFile `
        -b $cookieJar `
        -X POST `
        -F "_token=$formToken" `
        -F "_method=DELETE" `
        -F "type=Torrent" `
        -F "id=$torrent_id" `
        -F "title=<$tempName" `
        --form-string "message=$deleteReason" `
        "${TrackerUrl}/torrents/${torrent_id}"

    Remove-Item -LiteralPath $tempName -ErrorAction SilentlyContinue

    $lines    = $response -split "`n"
    $httpCode = $lines[-1].Trim()
    $body     = ($lines[0..($lines.Count - 2)]) -join "`n"
    $location = ''
    foreach ($hline in Get-Content -LiteralPath $headerFile) {
        if ($hline -match '^Location:\s*(.+)') {
            $location = $matches[1].Trim()
        }
    }

    Write-Host "HTTP status: $httpCode"
    if ($location) { Write-Host "Redirect: $location" }
    if ($httpCode -eq '302') {
        if ($location -match '/login') {
            Write-Host "Error: session expired. Please try again." -ForegroundColor Red
        } elseif ($location -match "/torrents/${torrent_id}") {
            Write-Host "Error: delete failed (redirected back to torrent page)." -ForegroundColor Red
        } else {
            Write-Host "Torrent deleted successfully." -ForegroundColor Green
        }
    } elseif ($httpCode -eq '200') {
        Write-Host "Torrent deleted successfully." -ForegroundColor Green
    } elseif ($httpCode -eq '403') {
        Write-Host "Error: no permission to delete this torrent." -ForegroundColor Red
        $errTitle = [regex]::Match($body, '<title>([^<]+)</title>').Groups[1].Value
        if ($errTitle) { Write-Host "  $errTitle" }
    } elseif ($httpCode -eq '419') {
        Write-Host "Error: CSRF token expired or invalid." -ForegroundColor Red
    } else {
        $errTitle = [regex]::Match($body, '<title>([^<]+)</title>').Groups[1].Value
        $errMsg = [regex]::Match($body, 'class="error__body">([^<]+)<').Groups[1].Value
        Write-Host "Error: $(if ($errTitle) { $errTitle } else { 'unexpected response' })" -ForegroundColor Red
        if ($errMsg) { Write-Host "  $errMsg" }
    }
} finally {
    $toRemove = @($headerFile) + @($cookieJar) | Where-Object { $_ }
    if ($toRemove) { Remove-Item -LiteralPath $toRemove -ErrorAction SilentlyContinue }
}
