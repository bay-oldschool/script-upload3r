#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Shared image upload helper.
.DESCRIPTION
    Uploads a single image via the provider configured in config (`image_provider`).
    Supported providers:
      - onlyimage  (Chevereto API; requires `onlyimage_api_key`)
      - freeimage  (Chevereto API on freeimage.host; requires `freeimage_api_key`)
      - imgbb      (api.imgbb.com; requires `imgbb_api_key`)
      - pixhost    (api.pixhost.to; no key required)
    Returns a PSCustomObject with: Success [bool], Url [string], Error [string].
#>

function Invoke-ImageUpload {
    param(
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $true)] [string] $FilePath
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        return [pscustomobject]@{ Success = $false; Url = $null; Error = "file not found: $FilePath" }
    }

    $provider = if ($Config.image_provider) { ([string]$Config.image_provider).ToLower() } else { 'onlyimage' }

    # Some hosts care about the file extension. Preserve the original.
    $ext = [System.IO.Path]::GetExtension($FilePath)
    if (-not $ext) { $ext = '.png' }
    $tmpFile = [System.IO.Path]::GetTempFileName() + $ext
    Copy-Item -LiteralPath $FilePath -Destination $tmpFile -Force

    try {
        switch ($provider) {
            'onlyimage' {
                $key = $Config.onlyimage_api_key
                if (-not $key) {
                    return [pscustomobject]@{ Success = $false; Url = $null; Error = "'onlyimage_api_key' not configured" }
                }
                $res = & curl.exe -sS -w "`n%{http_code}" -X POST "https://onlyimage.org/api/1/upload" `
                    -H "X-API-Key: $key" `
                    -F "source=@$tmpFile" `
                    -F "format=json"
                return Read-CheveretoResponse -Result $res -ExitCode $LASTEXITCODE
            }
            'freeimage' {
                $key = $Config.freeimage_api_key
                if (-not $key) {
                    return [pscustomobject]@{ Success = $false; Url = $null; Error = "'freeimage_api_key' not configured" }
                }
                $res = & curl.exe -sS -w "`n%{http_code}" -X POST "https://freeimage.host/api/1/upload" `
                    -F "key=$key" `
                    -F "source=@$tmpFile" `
                    -F "format=json"
                return Read-CheveretoResponse -Result $res -ExitCode $LASTEXITCODE
            }
            'imgbb' {
                $key = $Config.imgbb_api_key
                if (-not $key) {
                    return [pscustomobject]@{ Success = $false; Url = $null; Error = "'imgbb_api_key' not configured" }
                }
                $res = & curl.exe -sS -w "`n%{http_code}" -X POST "https://api.imgbb.com/1/upload?key=$key" `
                    -F "image=@$tmpFile"
                return Read-ImgbbResponse -Result $res -ExitCode $LASTEXITCODE
            }
            'pixhost' {
                $res = & curl.exe -sS -w "`n%{http_code}" -X POST "https://api.pixhost.to/images" `
                    -H "Accept: application/json" `
                    -F "img=@$tmpFile" `
                    -F "content_type=0"
                return Read-PixhostResponse -Result $res -ExitCode $LASTEXITCODE
            }
            default {
                return [pscustomobject]@{
                    Success = $false; Url = $null
                    Error   = "unknown image_provider '$provider' (supported: onlyimage, freeimage, imgbb, pixhost)"
                }
            }
        }
    } finally {
        Remove-Item -LiteralPath $tmpFile -ErrorAction SilentlyContinue
    }
}

function Split-CurlResult {
    param([string] $Text)
    $nl = $Text.LastIndexOf("`n")
    if ($nl -ge 0) {
        return @{ HttpCode = $Text.Substring($nl + 1).Trim(); Body = $Text.Substring(0, $nl).Trim() }
    }
    return @{ HttpCode = ''; Body = $Text }
}

function Format-NonJsonError {
    param([string] $Body, [string] $HttpCode)
    $statusPart = if ($HttpCode) { "HTTP $HttpCode" } else { 'no HTTP status' }
    $trimmed = $Body.TrimStart()
    if (-not $trimmed) { return "$statusPart, empty response" }
    if ($trimmed -match '^(?i)(<!doctype|<html|<head|<body)') {
        $msg = $null
        if ($Body -match '(?is)<h1[^>]*>\s*(.*?)\s*</h1>') { $msg = $matches[1] }
        if (-not $msg -and $Body -match '(?is)<p[^>]*>\s*(.*?)\s*</p>') { $msg = $matches[1] }
        if (-not $msg -and $Body -match '(?is)<title[^>]*>\s*(.*?)\s*</title>') { $msg = $matches[1] }
        if ($msg) {
            $msg = ($msg -replace '<[^>]+>', '')
            $msg = [System.Net.WebUtility]::HtmlDecode($msg) -replace '\s+', ' '
            if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + '...' }
            return "${statusPart}, server returned HTML page: $msg"
        }
        return "${statusPart}, server returned HTML page (site likely down or auth rejected)"
    }
    $snippet = if ($Body.Length -gt 200) { $Body.Substring(0, 200) + '...' } else { $Body }
    return "non-JSON response, ${statusPart}: $snippet"
}

function Read-CheveretoResponse {
    param($Result, [int] $ExitCode)
    $resultText = ($Result | Out-String).Trim()
    if ($ExitCode -ne 0) {
        return [pscustomobject]@{ Success = $false; Url = $null; Error = "curl exit ${ExitCode}: $resultText" }
    }
    $split = Split-CurlResult $resultText
    $json = $null
    try { $json = $split.Body | ConvertFrom-Json } catch { $json = $null }
    if ($null -eq $json) {
        return [pscustomobject]@{ Success = $false; Url = $null; Error = (Format-NonJsonError -Body $split.Body -HttpCode $split.HttpCode) }
    }
    $url = if ($json.image -and $json.image.url) { $json.image.url }
           elseif ($json.url) { $json.url }
           else { $null }
    if ($json.status_code -eq 200 -and $url) {
        return [pscustomobject]@{ Success = $true; Url = $url; Error = $null }
    }
    $errTxt = if ($json.error -and $json.error.message) { $json.error.message }
              elseif ($json.status_txt) { $json.status_txt }
              else { 'unknown error' }
    $code = if ($json.status_code) { $json.status_code } else { $split.HttpCode }
    $codePart = if ($code) { "[$code] " } else { '' }
    return [pscustomobject]@{ Success = $false; Url = $null; Error = "$codePart$errTxt" }
}

function Read-ImgbbResponse {
    param($Result, [int] $ExitCode)
    $resultText = ($Result | Out-String).Trim()
    if ($ExitCode -ne 0) {
        return [pscustomobject]@{ Success = $false; Url = $null; Error = "curl exit ${ExitCode}: $resultText" }
    }
    $split = Split-CurlResult $resultText
    $json = $null
    try { $json = $split.Body | ConvertFrom-Json } catch { $json = $null }
    if ($null -eq $json) {
        return [pscustomobject]@{ Success = $false; Url = $null; Error = (Format-NonJsonError -Body $split.Body -HttpCode $split.HttpCode) }
    }
    if ($json.success -and $json.data -and $json.data.url) {
        return [pscustomobject]@{ Success = $true; Url = $json.data.url; Error = $null }
    }
    $errTxt = if ($json.error -and $json.error.message) { $json.error.message }
              elseif ($json.status_txt) { $json.status_txt }
              else { 'unknown error' }
    $code = if ($json.status_code) { $json.status_code } else { $split.HttpCode }
    $codePart = if ($code) { "[$code] " } else { '' }
    return [pscustomobject]@{ Success = $false; Url = $null; Error = "$codePart$errTxt" }
}

function Read-PixhostResponse {
    param($Result, [int] $ExitCode)
    $resultText = ($Result | Out-String).Trim()
    if ($ExitCode -ne 0) {
        return [pscustomobject]@{ Success = $false; Url = $null; Error = "curl exit ${ExitCode}: $resultText" }
    }
    $split = Split-CurlResult $resultText
    $json = $null
    try { $json = $split.Body | ConvertFrom-Json } catch { $json = $null }
    if ($null -eq $json) {
        return [pscustomobject]@{ Success = $false; Url = $null; Error = (Format-NonJsonError -Body $split.Body -HttpCode $split.HttpCode) }
    }
    if ($json.th_url) {
        # pixhost returns a thumbnail URL like https://t<N>.pixhost.to/thumbs/<path>.
        # The full-size image lives at https://img<N>.pixhost.to/images/<path>.
        $direct = $json.th_url -replace '^https?://t(\d+)\.pixhost\.to/thumbs/', 'https://img$1.pixhost.to/images/'
        return [pscustomobject]@{ Success = $true; Url = $direct; Error = $null }
    }
    $snippet = if ($split.Body.Length -gt 200) { $split.Body.Substring(0, 200) + '...' } else { $split.Body }
    return [pscustomobject]@{ Success = $false; Url = $null; Error = "unexpected response: $snippet" }
}
