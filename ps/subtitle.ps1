#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Upload a subtitle file to a UNIT3D tracker torrent.
.DESCRIPTION
    Logs in via web session, fetches the subtitle create form,
    then uploads the subtitle file with language selection.
    Requires "username" and "password" in config.jsonc.
.PARAMETER torrent_id
    Numeric torrent ID to attach the subtitle to.
.PARAMETER subtitle_file
    Path to the subtitle file (.srt, .ass, .sub, .zip, etc).
.PARAMETER configfile
    Path to JSONC config file (default: ./config.jsonc).
#>
param(
    [Parameter(Position = 0)]
    [string]$torrent_id,

    [Parameter(Position = 1)]
    [string]$subtitle_file,

    [Parameter(Position = 2)]
    [string]$configfile,

    [Alias('l')]
    [string]$language,

    [Alias('n')]
    [string]$note,

    [Alias('a')]
    [switch]$anon
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$PSScriptRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $MyInvocation.MyCommand.Definition)

if (-not $torrent_id -or -not $subtitle_file) {
    Write-Host @"
Usage: subtitle.ps1 <torrent_id> <subtitle_file> [config.jsonc] [-l language_id] [-a]

Upload a subtitle file to a UNIT3D tracker torrent.
Logs in via web session, fetches the subtitle create form,
then uploads the subtitle file with language selection.

Requires "username" and "password" in config.jsonc.

Arguments:
  torrent_id       Numeric torrent ID to attach the subtitle to
  subtitle_file    Path to the subtitle file (.srt, .ass, .sub, .zip, etc)
  config.jsonc     Path to JSONC config file (default: ./config.jsonc)

Options:
  -l <id>        Language ID (skips interactive selection)
  -n <text>      Note (required, e.g. "Google Translated")
  -a             Upload anonymously
  -h, -help      Show this help message

Example:
  subtitle.ps1 3643 "movie.bg.srt"
  subtitle.ps1 3643 "movie.bg.srt" -l 15 -n "Google Translated" -a
"@
    exit 1
}

if ($torrent_id -notmatch '^\d+$') {
    Write-Host "Error: torrent_id must be a number" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $subtitle_file)) {
    Write-Host "Error: subtitle file '$subtitle_file' not found" -ForegroundColor Red
    exit 1
}

# Resolve to absolute path for curl
$subtitle_file = (Resolve-Path -LiteralPath $subtitle_file).Path

# Ensure console uses UTF-8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not $configfile) { $configfile = Join-Path $PSScriptRoot "config.jsonc" }

if (-not (Test-Path -LiteralPath $configfile)) {
    Write-Host "Error: config file '$configfile' not found. Run install.bat to create it from config.example.jsonc" -ForegroundColor Red
    exit 1
}

# Read tracker credentials from config
$config     = (Get-Content -LiteralPath $configfile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json
$TrackerUrl = $config.tracker_url
$Username   = $config.username
$Password   = $config.password
$DefaultAnon = if ($config.anonymous) { [int]$config.anonymous } else { 0 }
$DefaultLang = if ($config.subtitle_language_id) { [string]$config.subtitle_language_id } else { '' }

if (-not $Username -or -not $Password) {
    Write-Host "Error: 'username' and 'password' must be set in $configfile for subtitle upload" -ForegroundColor Red
    exit 1
}

# Web session
$cookieJar  = [System.IO.Path]::GetTempFileName()
$headerFile = [System.IO.Path]::GetTempFileName()

try {
    # Step 1: Login
    Write-Host "Logging in to ${TrackerUrl}..."
    $loginPage = (& curl.exe -s -c $cookieJar -b $cookieJar "${TrackerUrl}/login") -join "`n"

    $csrfToken = ''
    if ($loginPage -match 'name="_token"\s*value="([^"]+)"') { $csrfToken = $matches[1] }
    $captcha = ''
    if ($loginPage -match 'name="_captcha"\s*value="([^"]+)"') { $captcha = $matches[1] }
    $randomName = ''; $randomValue = ''
    if ($loginPage -match 'name="([A-Za-z0-9]{16})"\s*value="(\d+)"') {
        $randomName = $matches[1]; $randomValue = $matches[2]
    }

    if (-not $csrfToken) {
        Write-Host "Error: could not get CSRF token from login page" -ForegroundColor Red
        exit 1
    }

    $loginHeaderFile = [System.IO.Path]::GetTempFileName()
    $randomField = @()
    if ($randomName) { $randomField = @('-d', "${randomName}=${randomValue}") }

    & curl.exe -s -D $loginHeaderFile -o NUL -c $cookieJar -b $cookieJar `
        -d "_token=$csrfToken" -d "_captcha=$captcha" -d "_username=" `
        -d "username=$Username" --data-urlencode "password=$Password" `
        -d "remember=on" @randomField "${TrackerUrl}/login"

    $loginLocation = ''
    foreach ($hline in Get-Content -LiteralPath $loginHeaderFile) {
        if ($hline -match '^Location:\s*(.+)') { $loginLocation = $matches[1].Trim() }
    }
    Remove-Item -LiteralPath $loginHeaderFile -ErrorAction SilentlyContinue

    if ($loginLocation -match '/login') {
        Write-Host "Error: login failed. Check username/password in config." -ForegroundColor Red
        exit 1
    }
    Write-Host "Logged in."

    # Follow redirect to finalize session
    & curl.exe -s -o NUL -c $cookieJar -b $cookieJar --max-time 15 $loginLocation

    # Step 2: Fetch subtitle create page to get CSRF token and language list
    Write-Host "Fetching subtitle form for torrent #${torrent_id}..."
    $createPage = (& curl.exe -s -c $cookieJar -b $cookieJar --max-time 30 `
        "${TrackerUrl}/subtitles/create?torrent_id=${torrent_id}") -join "`n"

    $formToken = ''
    if ($createPage -match 'name="_token"\s*value="([^"]+)"') {
        $formToken = $matches[1]
    }

    if (-not $formToken) {
        Write-Host "Error: could not get _token from subtitle create page." -ForegroundColor Red
        Write-Host "Torrent may not exist or you may not have permission." -ForegroundColor Red
        exit 1
    }

    # Extract language options from the form
    $languages = [regex]::Matches($createPage, '<option\s+value="(\d+)"[^>]*>\s*([^<]+)\s*</option>')
    $langList = @()
    foreach ($m in $languages) {
        $langId   = $m.Groups[1].Value
        $langName = $m.Groups[2].Value.Trim()
        # Skip placeholder/empty options
        if ($langId -ne '0' -and $langName) {
            $langList += [PSCustomObject]@{ id = $langId; name = $langName }
        }
    }

    if ($langList.Count -eq 0) {
        Write-Host "Warning: could not parse language list from form. You may need to specify -l manually." -ForegroundColor Yellow
    }

    # Language selection (from -l param, or config default, or interactive)
    $selectedLang = $language
    if (-not $selectedLang -and $DefaultLang) {
        $selectedLang = $DefaultLang
    }
    if (-not $selectedLang) {
        if ($langList.Count -gt 0) {
            Write-Host ""
            Write-Host "Available languages:"
            for ($i = 0; $i -lt $langList.Count; $i++) {
                Write-Host "  $($i+1)) $($langList[$i].name) (id=$($langList[$i].id))"
            }
            Write-Host ""
            $langChoice = Read-Host "Select language"
            if ($langChoice -match '^\d+$') {
                $idx = [int]$langChoice - 1
                if ($idx -ge 0 -and $idx -lt $langList.Count) {
                    $selectedLang = $langList[$idx].id
                    Write-Host "Selected: $($langList[$idx].name) (id=$selectedLang)"
                }
            }
        }
        if (-not $selectedLang) {
            $selectedLang = Read-Host "Enter language ID manually"
        }
    } else {
        # Show language list with default marked, allow override
        if ($langList.Count -gt 0) {
            Write-Host ""
            Write-Host "Available languages:"
            $defaultIdx = 0
            for ($i = 0; $i -lt $langList.Count; $i++) {
                $marker = ''
                if ($langList[$i].id -eq $selectedLang) {
                    $marker = ' *'
                    $defaultIdx = $i
                }
                Write-Host "  $($i+1)) $($langList[$i].name) (id=$($langList[$i].id))${marker}"
            }
            Write-Host ""
            $defaultName = $langList[$defaultIdx].name
            $defaultId = $langList[$defaultIdx].id
            $langChoice = Read-Host "Select language [$($defaultIdx + 1) - $defaultName (id=$defaultId)]"
            if ($langChoice -match '^\d+$') {
                $idx = [int]$langChoice - 1
                if ($idx -ge 0 -and $idx -lt $langList.Count) {
                    $selectedLang = $langList[$idx].id
                }
            }
        }
        $langMatch = $langList | Where-Object { $_.id -eq $selectedLang }
        if ($langMatch) {
            Write-Host "Language: $($langMatch.name) (id=$selectedLang)"
        } else {
            Write-Host "Language ID: $selectedLang"
        }
    }

    if (-not $selectedLang) {
        Write-Host "Error: no language selected" -ForegroundColor Red
        exit 1
    }

    # Anonymous flag (from -a switch, or interactive with config default)
    if ($anon) {
        $anonValue = '1'
    } else {
        $defaultAnonLabel = if ($DefaultAnon -eq 1) { 'y' } else { 'n' }
        $anonChoice = Read-Host "Upload anonymously? (y/n) [$defaultAnonLabel]"
        if (-not $anonChoice) {
            $anonValue = [string]$DefaultAnon
        } else {
            $anonValue = if ($anonChoice -match '^[yY]') { '1' } else { '0' }
        }
    }

    # Note field (required)
    $noteValue = $note
    if (-not $noteValue) {
        $noteValue = Read-Host "Note"
    }
    if (-not $noteValue) {
        Write-Host "Error: note is required" -ForegroundColor Red
        exit 1
    }
    $tempNote = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tempNote, $noteValue, $utf8NoBom)
    $noteField = @('-F', "note=<$tempNote")

    # Step 3: Upload subtitle
    Write-Host ""
    Write-Host "Uploading subtitle to torrent #${torrent_id}..."
    Write-Host "  File: $(Split-Path -Leaf $subtitle_file)"
    if ($noteValue) { Write-Host "  Note: $noteValue" }

    $response = & curl.exe -s -w "`n%{http_code}" --max-time 60 `
        -D $headerFile `
        -b $cookieJar `
        -X POST `
        -F "_token=$formToken" `
        -F "torrent_id=$torrent_id" `
        -F "subtitle_file=@$subtitle_file" `
        -F "language_id=$selectedLang" `
        -F "anon=$anonValue" `
        @noteField `
        "${TrackerUrl}/subtitles"

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
        } elseif ($location -match '/subtitles/create') {
            Write-Host "Error: subtitle upload failed (redirected back to form)." -ForegroundColor Red
            # Try to fetch error messages
            $errorPage = (& curl.exe -s -L -b $cookieJar $location) -join "`n"
            $errors = [regex]::Matches($errorPage, '<li>([^<]+)</li>') | ForEach-Object { $_.Groups[1].Value }
            if ($errors) {
                foreach ($err in $errors) { Write-Host "  - $err" -ForegroundColor Red }
            }
        } else {
            Write-Host "Subtitle uploaded successfully." -ForegroundColor Green
        }
    } elseif ($httpCode -eq '200') {
        Write-Host "Subtitle uploaded successfully." -ForegroundColor Green
    } elseif ($httpCode -eq '403') {
        Write-Host "Error: no permission to upload subtitles." -ForegroundColor Red
    } elseif ($httpCode -eq '419') {
        Write-Host "Error: CSRF token expired or invalid." -ForegroundColor Red
    } elseif ($httpCode -eq '422') {
        Write-Host "Error: validation failed." -ForegroundColor Red
        $errors = [regex]::Matches($body, '<li>([^<]+)</li>') | ForEach-Object { $_.Groups[1].Value }
        if ($errors) {
            foreach ($err in $errors) { Write-Host "  - $err" -ForegroundColor Red }
        } else {
            Write-Host ($body.Substring(0, [Math]::Min($body.Length, 2000)))
        }
    } else {
        Write-Host "Unexpected response." -ForegroundColor Red
        $errTitle = [regex]::Match($body, '<title>([^<]+)</title>').Groups[1].Value
        if ($errTitle) { Write-Host "  $errTitle" }
    }
} finally {
    Remove-Item -LiteralPath $cookieJar, $headerFile -ErrorAction SilentlyContinue
    if ($tempNote) { Remove-Item -LiteralPath $tempNote -ErrorAction SilentlyContinue }
}
