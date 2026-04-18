# shared/web_login.ps1 - Shared web login with optional 2FA (TOTP) support
# Provides:
#   Get-CachedCookieJar  - returns a cookie jar path, reusing cached session if valid
#   Invoke-TrackerLogin   - performs a fresh login (called internally by Get-CachedCookieJar)

# Resolve totp.ps1 path at dot-source time (relative to this file)
$script:_WebLoginSharedDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Cookie cache: stored next to config in ps/output/.web_cookie_<host>
# Max age 90 minutes (server allows 120, keep margin)
$script:_CookieMaxAgeMins = 90

function Get-CachedCookieJar {
    param(
        [Parameter(Mandatory)][string]$TrackerUrl,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$Password,
        [string]$TwoFactorSecret,
        [Parameter(Mandatory)][string]$OutputDir
    )

    $host_ = ([System.Uri]$TrackerUrl).Host -replace '[^A-Za-z0-9]', '_'
    $cachePath = Join-Path $OutputDir ".web_cookie_${host_}"

    # Check if cached cookie exists and is fresh enough
    if (Test-Path -LiteralPath $cachePath) {
        $age = (Get-Date) - (Get-Item -LiteralPath $cachePath).LastWriteTime
        if ($age.TotalMinutes -lt $script:_CookieMaxAgeMins) {
            # Quick validation: GET a page and check we're not redirected to /login
            $checkResp = & curl.exe -s -w "`n%{http_code}" -o NUL -b $cachePath --max-time 10 "${TrackerUrl}/torrents"
            $checkCode = ($checkResp -split "`n")[-1].Trim()
            if ($checkCode -eq '200') {
                Write-Host "Using cached session ($([int]$age.TotalMinutes)m old)." -ForegroundColor DarkCyan
                # Return a temp COPY so scripts with -c don't corrupt the cache
                $tempCopy = [System.IO.Path]::GetTempFileName()
                Copy-Item -LiteralPath $cachePath -Destination $tempCopy -Force
                return $tempCopy
            }
            Write-Host "Cached session expired (HTTP $checkCode), re-logging in..." -ForegroundColor Yellow
        } else {
            Write-Host "Cached session too old ($([int]$age.TotalMinutes)m), re-logging in..." -ForegroundColor Yellow
        }
        Remove-Item -LiteralPath $cachePath -ErrorAction SilentlyContinue
    }

    # No valid cache - perform fresh login
    if (-not (Test-Path -LiteralPath $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }
    $tempJar = [System.IO.Path]::GetTempFileName()
    $loginOk = Invoke-TrackerLogin -TrackerUrl $TrackerUrl -Username $Username `
        -Password $Password -TwoFactorSecret $TwoFactorSecret -CookieJar $tempJar
    if (-not $loginOk) {
        Remove-Item -LiteralPath $tempJar -ErrorAction SilentlyContinue
        return $null
    }

    # Save to cache (original stays untouched), return the temp jar for use
    Copy-Item -LiteralPath $tempJar -Destination $cachePath -Force
    return $tempJar
}

function Invoke-TrackerLogin {
    param(
        [Parameter(Mandatory)][string]$TrackerUrl,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$Password,
        [string]$TwoFactorSecret,
        [Parameter(Mandatory)][string]$CookieJar
    )

    Write-Host "Logging in to ${TrackerUrl}..." -ForegroundColor Cyan

    # Step 1: GET /login for CSRF token, captcha, and anti-bot fields
    $loginResp = & curl.exe -s -w "`n%{http_code}" -c $CookieJar -b $CookieJar "${TrackerUrl}/login"
    $loginLines = $loginResp -split "`n"
    $loginCode  = $loginLines[-1].Trim()
    $loginPage  = ($loginLines[0..($loginLines.Count - 2)]) -join "`n"

    if ($loginCode -eq '429') {
        Write-Host "Rate limited by server. Waiting 60s..." -ForegroundColor Yellow
        Start-Sleep -Seconds 60
        $loginResp = & curl.exe -s -w "`n%{http_code}" -c $CookieJar -b $CookieJar "${TrackerUrl}/login"
        $loginLines = $loginResp -split "`n"
        $loginCode  = $loginLines[-1].Trim()
        $loginPage  = ($loginLines[0..($loginLines.Count - 2)]) -join "`n"
    }

    $csrfToken = ''
    if ($loginPage -match 'name="_token"\s*value="([^"]+)"') { $csrfToken = $matches[1] }
    $captcha = ''
    if ($loginPage -match 'name="_captcha"\s*value="([^"]+)"') { $captcha = $matches[1] }
    $randomName = ''; $randomValue = ''
    if ($loginPage -match 'name="([A-Za-z0-9]{16})"\s*value="(\d+)"') {
        $randomName = $matches[1]; $randomValue = $matches[2]
    }

    if (-not $csrfToken) {
        Write-Host "Error: could not get CSRF token from login page (HTTP $loginCode)" -ForegroundColor Red
        return $false
    }

    # Step 2: POST /login
    $headerFile = [System.IO.Path]::GetTempFileName()
    $randomField = @()
    if ($randomName) { $randomField = @('-d', "${randomName}=${randomValue}") }

    $postResp = & curl.exe -s -w "`n%{http_code}" -D $headerFile -c $CookieJar -b $CookieJar `
        -d "_token=$csrfToken" -d "_captcha=$captcha" -d "_username=" `
        -d "username=$Username" --data-urlencode "password=$Password" `
        -d "remember=on" @randomField "${TrackerUrl}/login"
    $postCode = ($postResp -split "`n")[-1].Trim()

    if ($postCode -eq '429') {
        Remove-Item -LiteralPath $headerFile -ErrorAction SilentlyContinue
        Write-Host "Rate limited by server. Waiting 60s..." -ForegroundColor Yellow
        Start-Sleep -Seconds 60
        return Invoke-TrackerLogin -TrackerUrl $TrackerUrl -Username $Username `
            -Password $Password -TwoFactorSecret $TwoFactorSecret -CookieJar $CookieJar
    }

    $loginLocation = ''
    foreach ($hline in Get-Content -LiteralPath $headerFile) {
        if ($hline -match '^Location:\s*(.+)') { $loginLocation = $matches[1].Trim() }
    }
    Remove-Item -LiteralPath $headerFile -ErrorAction SilentlyContinue

    # Check for login failure
    if ($loginLocation -match '/login$') {
        Write-Host "Error: login failed. Check username/password in config." -ForegroundColor Red
        return $false
    }

    # Check for 2FA challenge
    if ($loginLocation -match 'two-factor-challenge') {
        if (-not $TwoFactorSecret) {
            Write-Host "Error: 2FA is enabled but 'two_factor_secret' is not set in config." -ForegroundColor Red
            return $false
        }
        Write-Host "2FA challenge detected, submitting TOTP code..." -ForegroundColor Cyan

        $tfUrl = "${TrackerUrl}/two-factor-challenge"

        # GET the 2FA challenge page
        $tfResp = & curl.exe -s -w "`n%{http_code}" -L -c $CookieJar -b $CookieJar --max-time 15 $tfUrl
        $tfLines = $tfResp -split "`n"
        $tfCode  = $tfLines[-1].Trim()
        $tfPage  = ($tfLines[0..($tfLines.Count - 2)]) -join "`n"

        if ($tfCode -eq '429') {
            Write-Host "Rate limited by server. Waiting 60s..." -ForegroundColor Yellow
            Start-Sleep -Seconds 60
            $tfResp = & curl.exe -s -w "`n%{http_code}" -L -c $CookieJar -b $CookieJar --max-time 15 $tfUrl
            $tfLines = $tfResp -split "`n"
            $tfCode  = $tfLines[-1].Trim()
            $tfPage  = ($tfLines[0..($tfLines.Count - 2)]) -join "`n"
        }

        $tfToken = ''
        if ($tfPage -match 'name="_token"\s*value="([^"]+)"') { $tfToken = $matches[1] }
        if (-not $tfToken -and $tfPage -match '<meta\s+name="csrf-token"\s+content="([^"]+)"') { $tfToken = $matches[1] }
        if (-not $tfToken) {
            Write-Host "Error: could not get CSRF token from 2FA page (HTTP $tfCode)" -ForegroundColor Red
            return $false
        }

        # Generate TOTP code and submit (with one retry on rejection)
        . (Join-Path $script:_WebLoginSharedDir 'totp.ps1')

        $tfSuccess = $false
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            $totpCode = Get-TOTPCode -Secret $TwoFactorSecret

            $tfHeaderFile = [System.IO.Path]::GetTempFileName()
            $tfPostResp = & curl.exe -s -w "`n%{http_code}" -D $tfHeaderFile -c $CookieJar -b $CookieJar `
                -d "_token=$tfToken" -d "code=$totpCode" `
                "${TrackerUrl}/two-factor-challenge"
            $tfPostCode = ($tfPostResp -split "`n")[-1].Trim()

            if ($tfPostCode -eq '429') {
                Remove-Item -LiteralPath $tfHeaderFile -ErrorAction SilentlyContinue
                Write-Host "Rate limited by server. Waiting 60s..." -ForegroundColor Yellow
                Start-Sleep -Seconds 60
                $tfPage2 = (& curl.exe -s -L -c $CookieJar -b $CookieJar --max-time 15 $tfUrl) -join "`n"
                if ($tfPage2 -match 'name="_token"\s*value="([^"]+)"') { $tfToken = $matches[1] }
                elseif ($tfPage2 -match '<meta\s+name="csrf-token"\s+content="([^"]+)"') { $tfToken = $matches[1] }
                continue
            }

            $tfLocation = ''
            foreach ($hline in Get-Content -LiteralPath $tfHeaderFile) {
                if ($hline -match '^Location:\s*(.+)') { $tfLocation = $matches[1].Trim() }
            }
            Remove-Item -LiteralPath $tfHeaderFile -ErrorAction SilentlyContinue

            if ($tfLocation -match 'two-factor-challenge|/login') {
                if ($attempt -eq 1) {
                    Write-Host "2FA code rejected, waiting for next window..." -ForegroundColor Yellow
                    $remaining = 30 - ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() % 30)
                    Start-Sleep -Seconds ($remaining + 1)
                    $tfPage2 = (& curl.exe -s -L -c $CookieJar -b $CookieJar --max-time 15 $tfUrl) -join "`n"
                    if ($tfPage2 -match 'name="_token"\s*value="([^"]+)"') { $tfToken = $matches[1] }
                    elseif ($tfPage2 -match '<meta\s+name="csrf-token"\s+content="([^"]+)"') { $tfToken = $matches[1] }
                    continue
                }
                Write-Host "Error: 2FA code rejected. Check two_factor_secret in config." -ForegroundColor Red
                return $false
            }
            $tfSuccess = $true
            break
        }
        if (-not $tfSuccess) { return $false }

        # Follow final redirect to finalize session
        if ($tfLocation) {
            & curl.exe -s -o NUL -c $CookieJar -b $CookieJar --max-time 15 $tfLocation
        }
        Write-Host "Logged in (2FA)." -ForegroundColor Green
        return $true
    }

    # No 2FA - follow redirect to finalize session
    Write-Host "Logged in." -ForegroundColor Green
    if ($loginLocation) {
        & curl.exe -s -o NUL -c $CookieJar -b $CookieJar --max-time 15 $loginLocation
    }
    return $true
}
