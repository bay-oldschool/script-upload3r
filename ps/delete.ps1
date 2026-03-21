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
$TrackerUrl = $config.tracker_url
$Username   = $config.username
$Password   = $config.password

if (-not $Username -or -not $Password) {
    Write-Host "Error: 'username' and 'password' must be set in $configfile for deleting" -ForegroundColor Red
    exit 1
}

$curName = "Torrent #${torrent_id}"
$deleteReason = "Deleted by uploader"

if ($force) {
    Write-Host "Force mode: skipping fetch, deleting torrent #${torrent_id}..."
} else {
    # Fetch current torrent data via API
    Write-Host "Fetching torrent #${torrent_id}..."
    $apiUrl = "${TrackerUrl}/api/torrents/${torrent_id}?api_token=${ApiKey}"
    $fetchResp = & curl.exe -s -w "`n%{http_code}" $apiUrl
    $fetchLines = $fetchResp -split "`n"
    $fetchCode  = $fetchLines[-1].Trim()
    $fetchBody  = ($fetchLines[0..($fetchLines.Count - 2)]) -join "`n"

    if ($fetchCode -eq '404') {
        Write-Host "Error: torrent #${torrent_id} not found." -ForegroundColor Red
        exit 1
    } elseif ($fetchCode -ne '200') {
        Write-Host "Error: failed to fetch torrent (HTTP $fetchCode)" -ForegroundColor Red
        exit 1
    }

    $torrentData = $fetchBody | ConvertFrom-Json
    $attrs = $torrentData.attributes

    $curName       = $attrs.name
    $curCategory   = $attrs.category
    $curType       = $attrs.type
    $curResolution = $attrs.resolution

    Write-Host ""
    Write-Host "Torrent to delete:"
    Write-Host "  name:          $curName"
    Write-Host "  category:      $curCategory"
    Write-Host "  type:          $curType"
    Write-Host "  resolution:    $curResolution"
    Write-Host ""
    $confirm = Read-Host "Are you sure you want to DELETE this torrent? (y/n) [y]"
    if (-not $confirm) { $confirm = 'y' }
    if ($confirm -ne 'y' -and $confirm -ne 'yes') {
        Write-Host "Aborted."
        exit 0
    }
    $deleteReason = Read-Host "Reason for deletion"
    if (-not $deleteReason) { $deleteReason = "Deleted by uploader" }
}

# Web session login
$cookieJar  = [System.IO.Path]::GetTempFileName()
$headerFile = [System.IO.Path]::GetTempFileName()

try {
    Write-Host ""
    Write-Host "Logging in to ${TrackerUrl}..."

    # Step 1: GET /login to get CSRF token, captcha, and hidden anti-bot fields
    $loginPage = (& curl.exe -s -c $cookieJar -b $cookieJar "${TrackerUrl}/login") -join "`n"

    $csrfToken = ''
    if ($loginPage -match 'name="_token"\s*value="([^"]+)"') {
        $csrfToken = $matches[1]
    }
    $captcha = ''
    if ($loginPage -match 'name="_captcha"\s*value="([^"]+)"') {
        $captcha = $matches[1]
    }
    # Extract random-named hidden timestamp field (16-char alphanumeric name, numeric value)
    $randomName = ''
    $randomValue = ''
    if ($loginPage -match 'name="([A-Za-z0-9]{16})"\s*value="(\d+)"') {
        $randomName = $matches[1]
        $randomValue = $matches[2]
    }

    if (-not $csrfToken) {
        Write-Host "Error: could not get CSRF token from login page" -ForegroundColor Red
        exit 1
    }

    # Step 2: POST /login with all anti-bot fields
    $loginHeaderFile = [System.IO.Path]::GetTempFileName()
    $randomField = @()
    if ($randomName) { $randomField = @('-d', "${randomName}=${randomValue}") }

    & curl.exe -s -D $loginHeaderFile -o NUL -c $cookieJar -b $cookieJar `
        -d "_token=$csrfToken" `
        -d "_captcha=$captcha" `
        -d "_username=" `
        -d "username=$Username" `
        --data-urlencode "password=$Password" `
        -d "remember=on" `
        @randomField `
        "${TrackerUrl}/login"

    $loginLocation = ''
    foreach ($hline in Get-Content -LiteralPath $loginHeaderFile) {
        if ($hline -match '^Location:\s*(.+)') {
            $loginLocation = $matches[1].Trim()
        }
    }
    Remove-Item -LiteralPath $loginHeaderFile -ErrorAction SilentlyContinue

    if ($loginLocation -match '/login') {
        Write-Host "Error: login failed. Check username/password in config." -ForegroundColor Red
        exit 1
    }
    Write-Host "Logged in. Redirect: $loginLocation"

    # Follow the redirect to finalize session
    & curl.exe -s -o NUL -c $cookieJar -b $cookieJar --max-time 15 $loginLocation

    # Step 3: GET torrent page to get _token for CSRF
    Write-Host "Fetching CSRF token..."
    $torrentPage = (& curl.exe -s -c $cookieJar -b $cookieJar --max-time 30 "${TrackerUrl}/torrents/${torrent_id}") -join "`n"

    $formToken = ''
    if ($torrentPage -match 'name="_token"\s*value="([^"]+)"') {
        $formToken = $matches[1]
    }

    if (-not $formToken) {
        Write-Host "Error: could not get _token from torrent page. You may not have permission to delete this torrent." -ForegroundColor Red
        exit 1
    }

    # Step 4: POST with _method=DELETE (requires type, id, title, message fields)
    Write-Host "Deleting torrent #${torrent_id}..."

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
    Remove-Item -LiteralPath $cookieJar, $headerFile -ErrorAction SilentlyContinue
}
