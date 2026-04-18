#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Edit a torrent on a UNIT3D tracker by its ID.
.DESCRIPTION
    Fetches current values via API, lets you change fields interactively,
    then submits the update via web session.
    Requires "username" and "password" in config.jsonc.
.PARAMETER torrent_id
    Numeric torrent ID to edit.
.PARAMETER configfile
    Path to JSONC config file (default: ./config.jsonc).
#>
param(
    [Parameter(Position = 0)]
    [string]$torrent_id,

    [Parameter(Position = 1)]
    [string]$configfile,

    [Alias('u')]
    [string]$uploadreqfile,

    [Alias('n')]
    [string]$namefile,

    [Alias('d')]
    [string]$descfile,

    [Alias('m')]
    [string]$mediainfofile,

    [Alias('k')]
    [string]$keywordsfile
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$PSScriptRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $MyInvocation.MyCommand.Definition)

function Extract-LivewireDesc($html) {
    # Extract BBCode description from Livewire wire:initial-data (HTML-encoded JSON)
    # The regex allows \&quot; (escaped quotes) inside the JSON string value
    if ($html -match 'contentBbcode&quot;:&quot;((?:\\&quot;|(?!&quot;)[^&]|&(?!quot;))*)&quot;') {
        $raw = $matches[1]
        $raw = $raw -replace '&amp;', '&'
        $raw = $raw -replace '&quot;', '"'
        $raw = $raw -replace '\\/', '/'
        # Decode surrogate pairs for emoji
        $raw = [regex]::Replace($raw, '\\u([Dd][89AaBb][0-9a-fA-F]{2})\\u([Dd][CcDdEeFf][0-9a-fA-F]{2})', {
            param($m)
            $hi = [Convert]::ToInt32($m.Groups[1].Value, 16)
            $lo = [Convert]::ToInt32($m.Groups[2].Value, 16)
            [char]::ConvertFromUtf32(0x10000 + (($hi - 0xD800) -shl 10) + ($lo - 0xDC00))
        })
        # Decode BMP unicode escapes
        $raw = [regex]::Replace($raw, '\\u([0-9a-fA-F]{4})', { param($m) [char]([Convert]::ToInt32($m.Groups[1].Value, 16)) })
        # Decode JSON string escapes
        $raw = $raw -replace '\\n', "`n" -replace '\\r', '' -replace '\\t', "`t" -replace '\\"', '"' -replace '\\\\', '\'
        return $raw
    }
    return ''
}

if (-not $torrent_id) {
    Write-Host @"
Usage: edit.ps1 <torrent_id> [config.jsonc] [-u upload_request.txt] [-n name.txt] [-d description.txt] [-m mediainfo.txt]

Edit a torrent on a UNIT3D tracker by its ID.
Fetches current values via API, lets you change fields interactively,
then submits the update via web session.

Requires "username" and "password" in config.jsonc.

Arguments:
  torrent_id       Numeric torrent ID to edit
  config.jsonc     Path to JSONC config file (default: ./config.jsonc)

Options:
  -u <file>      Load name/category/type/resolution/tmdb/imdb/personal/anonymous from _upload_request.txt
  -n <file>      Use torrent name from file (preserves emoji from clipboard)
  -d <file>      Use description from file instead of current one
  -m <file>      Use mediainfo from file instead of current one
  -h, -help      Show this help message
"@
    exit 1
}

if ($torrent_id -notmatch '^\d+$') {
    Write-Host "Error: torrent_id must be a number" -ForegroundColor Red
    exit 1
}

# Ensure console uses UTF-8 for emoji support
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not $configfile) { $configfile = Join-Path $PSScriptRoot "config.jsonc" }

if (-not (Test-Path -LiteralPath $configfile)) {
    Write-Host "Error: config file '$configfile' not found. Run install.bat to create it from config.example.jsonc" -ForegroundColor Red
    exit 1
}

$script:posterUrl = ''
if ($uploadreqfile -and -not (Test-Path -LiteralPath $uploadreqfile)) {
    Write-Host "Error: upload request file '$uploadreqfile' not found" -ForegroundColor Red
    exit 1
}

# Parse upload_request.txt if provided
$upr = @{}
if ($uploadreqfile) {
    foreach ($line in [System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath $uploadreqfile).Path, [System.Text.Encoding]::UTF8)) {
        if ($line -match '^(\w+)=(.*)$') {
            $upr[$matches[1]] = $matches[2]
        }
    }
    Write-Host "Loaded upload request from: $uploadreqfile" -ForegroundColor Cyan
    # Auto-detect companion description file if -d not specified
    if (-not $descfile -and $upr.ContainsKey('description_file') -and $upr['description_file'] -and (Test-Path -LiteralPath $upr['description_file'])) {
        $descfile = $upr['description_file']
        Write-Host "Using description file: " -NoNewline; Write-Host "$descfile" -ForegroundColor Cyan
    } elseif (-not $descfile) {
        $autoDesc = $uploadreqfile -replace '_upload_request\.txt$', '_torrent_description.bbcode'
        if ($autoDesc -ne $uploadreqfile -and (Test-Path -LiteralPath $autoDesc)) {
            $descfile = $autoDesc
            Write-Host "Auto-detected description file: $descfile" -ForegroundColor Cyan
        }
    }
    # Auto-detect companion mediainfo file if -m not specified
    if (-not $mediainfofile -and $upr.ContainsKey('mediainfo_file') -and $upr['mediainfo_file'] -and (Test-Path -LiteralPath $upr['mediainfo_file'])) {
        $mediainfofile = $upr['mediainfo_file']
        Write-Host "Using mediainfo file: " -NoNewline; Write-Host "$mediainfofile" -ForegroundColor Cyan
    } elseif (-not $mediainfofile) {
        $autoMi = $uploadreqfile -replace '_upload_request\.txt$', '_mediainfo.txt'
        if ($autoMi -ne $uploadreqfile -and (Test-Path -LiteralPath $autoMi)) {
            $mediainfofile = $autoMi
            Write-Host "Auto-detected mediainfo file: $autoMi" -ForegroundColor Cyan
        }
    }
}

if ($namefile -and -not (Test-Path -LiteralPath $namefile)) {
    Write-Host "Error: name file '$namefile' not found" -ForegroundColor Red
    exit 1
}

if ($descfile -and -not (Test-Path -LiteralPath $descfile)) {
    Write-Host "Error: description file '$descfile' not found" -ForegroundColor Red
    exit 1
}

if ($mediainfofile -and -not (Test-Path -LiteralPath $mediainfofile)) {
    Write-Host "Error: mediainfo file '$mediainfofile' not found" -ForegroundColor Red
    exit 1
}

if ($keywordsfile -and -not (Test-Path -LiteralPath $keywordsfile)) {
    Write-Host "Error: keywords file '$keywordsfile' not found" -ForegroundColor Red
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
    Write-Host "Error: 'username' and 'password' must be set in $configfile for editing" -ForegroundColor Red
    exit 1
}

. (Join-Path (Join-Path $PSScriptRoot 'shared') 'web_login.ps1')

# Web session helper
$OutDir = Join-Path $PSScriptRoot 'output'
$cookieJar  = $null
$tempName   = [System.IO.Path]::GetTempFileName()
$tempDesc   = [System.IO.Path]::GetTempFileName()
$headerFile = [System.IO.Path]::GetTempFileName()
$webLoggedIn = $false
$webFallback = $false
$formToken   = ''

function Invoke-WebLogin {
    if ($script:webLoggedIn) { return }
    $script:cookieJar = Get-CachedCookieJar -TrackerUrl $TrackerUrl -Username $Username `
        -Password $Password -TwoFactorSecret $TwoFactorSecret -OutputDir $script:OutDir
    if (-not $script:cookieJar) {
        Write-Host "Login failed. Check credentials and two_factor_secret in config.jsonc." -ForegroundColor Red
        Write-Host "Press any key to continue ..." -ForegroundColor Yellow
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        exit 1
    }
    $script:webLoggedIn = $true
}

# Fetch current torrent data via API
Write-Host "Fetching torrent #${torrent_id}..." -ForegroundColor Cyan
$apiUrl = "${TrackerUrl}/api/torrents/${torrent_id}?api_token=${ApiKey}"
$fetchResp = & curl.exe -s -w "`n%{http_code}" $apiUrl
$fetchLines = $fetchResp -split "`n"
$fetchCode  = $fetchLines[-1].Trim()
$fetchBody  = ($fetchLines[0..($fetchLines.Count - 2)]) -join "`n"

if ($fetchCode -eq '200') {
    $torrentData = $fetchBody | ConvertFrom-Json
    $attrs = $torrentData.attributes

    $curName         = $attrs.name
    $curCategoryId   = [string]$attrs.category_id
    $curTypeId       = [string]$attrs.type_id
    $curResolutionId = [string]$attrs.resolution_id
    $curTmdb         = [string]$attrs.tmdb_id
    $curImdb         = [string]$attrs.imdb_id
    $curDiscogs      = if ($attrs.discogs) { [string]$attrs.discogs } else { '0' }
    $curSeason       = if ($attrs.season_number) { [string]$attrs.season_number } else { '0' }
    $curEpisode      = if ($attrs.episode_number) { [string]$attrs.episode_number } else { '0' }
    $curPersonal     = if ($attrs.personal_release -eq $true) { '1' } else { '0' }
    $curAnon         = if ($attrs.anon -eq 1 -or $attrs.anonymous -eq $true) { '1' } else { '0' }
    $curCategory     = $attrs.category
    $curType         = $attrs.type
    $curResolution   = $attrs.resolution
    $curKeywords     = if ($attrs.keywords) { [string]$attrs.keywords } else { '' }
    if (-not $curKeywords) {
        # API doesn't expose keywords — fetch edit page just to read them
        try {
            Invoke-WebLogin
            $kwPage = (& curl.exe -s -c $cookieJar -b $cookieJar --max-time 30 "${TrackerUrl}/torrents/${torrent_id}/edit") -join "`n"
            if ($kwPage -match '(?s)id="keywords"[^>]*?value="([^"]*)"') {
                $curKeywords = [System.Net.WebUtility]::HtmlDecode($matches[1])
            }
        } catch { }
    }
    if ($descfile) {
        $curDesc = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $descfile).Path, $utf8NoBom)
        Write-Host "Using description from: $descfile" -ForegroundColor Cyan
    } else {
        $curDesc = $attrs.description
        $curDesc = [regex]::Replace($curDesc, '\\([^\x00-\x7F])', '$1')
    }
    if ($mediainfofile) {
        $curMediainfo = (Get-Content -LiteralPath $mediainfofile -Encoding UTF8 | Where-Object { $_ -notmatch '^Encoding settings' }) -join "`n"
        Write-Host "Using mediainfo from: $mediainfofile" -ForegroundColor Cyan
    } else {
        $curMediainfo = ($attrs.media_info -split "`n" | Where-Object { $_ -notmatch '^Encoding settings' }) -join "`n"
    }
} else {
    # API failed - fall back to web edit page
    Write-Host "API fetch failed (HTTP $fetchCode), falling back to web..." -ForegroundColor Yellow
    Invoke-WebLogin
    Write-Host "Fetching edit page..." -ForegroundColor Cyan
    $editPage = (& curl.exe -s -c $cookieJar -b $cookieJar --max-time 30 "${TrackerUrl}/torrents/${torrent_id}/edit") -join "`n"
    if ($editPage -match 'name="_token"\s*value="([^"]+)"') {
        $formToken = $matches[1]
    }
    if (-not $formToken) {
        Write-Host "Error: could not access edit page. Torrent may not exist or you lack permission." -ForegroundColor Red
        exit 1
    }
    $webFallback = $true
    # Extract name
    $curName = ''
    if ($editPage -match 'name="name"\s+value="([^"]*)"') {
        $curName = $matches[1]
        $curName = [System.Net.WebUtility]::HtmlDecode($curName)
    }
    # Extract selected IDs
    $curCategoryId = ''
    if ($editPage -match 'name="category_id"[\s\S]*?<option\s+value="(\d+)"\s+selected') { $curCategoryId = $matches[1] }
    $curTypeId = ''
    if ($editPage -match 'name="type_id"[\s\S]*?<option\s+value="(\d+)"\s+selected') { $curTypeId = $matches[1] }
    $curResolutionId = ''
    if ($editPage -match 'name="resolution_id"[\s\S]*?value="(\d+)"\s+selected') { $curResolutionId = $matches[1] }
    # Extract TMDB/IMDB (id= input has value on a later line, skip hidden inputs with value="0")
    $curTmdb = '0'
    # Use [^>]* to stay within the same HTML tag (skip hidden inputs with value="0")
    if ($editPage -match 'id="tmdb_movie_id"[^>]*value="(\d+)"') { $curTmdb = $matches[1] }
    if ($curTmdb -eq '0' -and $editPage -match 'id="tmdb_tv_id"[^>]*value="(\d+)"') { $curTmdb = $matches[1] }
    $curImdb = '0'
    if ($editPage -match 'id="imdb"[^>]*value="(\d+)"') { $curImdb = $matches[1] }
    $curDiscogs = '0'
    if ($editPage -match 'id="discogs"[^>]*value="(\d+)"') { $curDiscogs = $matches[1] }
    $curSeason = '0'
    if ($editPage -match 'name="season_number"[\s\S]*?value="(\d+)"') { $curSeason = $matches[1] }
    $curEpisode = '0'
    if ($editPage -match 'name="episode_number"[\s\S]*?value="(\d+)"') { $curEpisode = $matches[1] }
    # Extract personal/anonymous checkboxes (checked attribute between id= and />)
    $curPersonal = '0'
    if ($editPage -match 'id="personal_release"[^/]*checked') { $curPersonal = '1' }
    $curAnon = '0'
    if ($editPage -match 'id="anon"[^/]*checked') { $curAnon = '1' }
    $curCategory = ''; $curType = ''; $curResolution = ''
    # Extract description from Livewire contentBbcode
    if ($descfile) {
        $curDesc = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $descfile).Path, $utf8NoBom)
        Write-Host "Using description from: $descfile" -ForegroundColor Cyan
    } else {
        $curDesc = Extract-LivewireDesc $editPage
        if (-not $curDesc) { $curDesc = '' }
    }
    # Extract mediainfo from textarea
    if ($mediainfofile) {
        $curMediainfo = (Get-Content -LiteralPath $mediainfofile -Encoding UTF8 | Where-Object { $_ -notmatch '^Encoding settings' }) -join "`n"
        Write-Host "Using mediainfo from: $mediainfofile" -ForegroundColor Cyan
    } else {
        $curMediainfo = ''
        if ($editPage -match 'name="mediainfo"[\s\S]*?>\s*([\s\S]*?)\s*</textarea') {
            $curMediainfo = ($matches[1] -split "`n" | Where-Object { $_ -notmatch '^Encoding settings' }) -join "`n"
        }
    }
    $curKeywords = ''
    if ($editPage -match '(?s)id="keywords"[^>]*?value="([^"]*)"') {
        $curKeywords = [System.Net.WebUtility]::HtmlDecode($matches[1])
    }
}

Write-Host ""
Write-Host "Current values:" -ForegroundColor Cyan
Write-Host "  name:          " -NoNewline; Write-Host "$curName" -ForegroundColor Green
Write-Host "  category:      " -NoNewline; Write-Host "$curCategory (id=$curCategoryId)" -ForegroundColor Green
Write-Host "  type:          " -NoNewline; Write-Host "$curType (id=$curTypeId)" -ForegroundColor Green
Write-Host "  resolution:    " -NoNewline; Write-Host "$curResolution (id=$curResolutionId)" -ForegroundColor Green
Write-Host "  tmdb_id:       " -NoNewline; Write-Host "$curTmdb" -ForegroundColor Green
Write-Host "  imdb_id:       " -NoNewline; Write-Host "$curImdb" -ForegroundColor Green
Write-Host "  discogs_id:    " -NoNewline; Write-Host "$curDiscogs" -ForegroundColor Green
Write-Host "  season:        " -NoNewline; Write-Host "$curSeason" -ForegroundColor Green
Write-Host "  episode:       " -NoNewline; Write-Host "$curEpisode" -ForegroundColor Green
Write-Host "  personal:      " -NoNewline; Write-Host "$curPersonal" -ForegroundColor Green
Write-Host "  anonymous:     " -NoNewline; Write-Host "$curAnon" -ForegroundColor Green
Write-Host "  keywords:      " -NoNewline; Write-Host "$curKeywords" -ForegroundColor Green
Write-Host ""
Write-Host "  (enter 'c' at any prompt to cancel)" -ForegroundColor DarkGray
Write-Host ""

# Offer to load upload request file interactively (if not already provided via -u)
if (-not $uploadreqfile) {
    $outDir = Join-Path $PSScriptRoot "output"
    $icoLoad = [char]::ConvertFromUtf32(0x1F4C4)
    $icoBrowse = [char]::ConvertFromUtf32(0x1F4C2)
    $icoSkip = [char]::ConvertFromUtf32(0x23ED)
    $urDone = $false
    while (-not $urDone) {
        Write-Host "Load upload request file:" -ForegroundColor Cyan
        Write-Host "  1) $icoLoad Select from output dir"
        Write-Host "  2) $icoBrowse Browse for file"
        Write-Host "  3) $icoSkip  Skip (enter values manually)"
        Write-Host ""
        Write-Host "Upload request (1-3) [3]: " -NoNewline
        $urKey = [Console]::ReadKey($true).KeyChar
        Write-Host $urKey
        if ($urKey -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
        $urChoice = [string]$urKey
        if ($urChoice -eq "`r" -or $urChoice -eq "`n" -or $urChoice -eq ' ') { $urChoice = '3' }
        $urFile = $null
        if ($urChoice -eq '1') {
            $absOut = if (Test-Path $outDir) { (Resolve-Path $outDir).Path } else { $PSScriptRoot }
            Add-Type -AssemblyName PresentationFramework
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Title = 'Select upload request file from output'
            $dlg.Filter = 'Upload request (*.txt)|*.txt|All files (*.*)|*.*'
            $dlg.InitialDirectory = $absOut
            if ($dlg.ShowDialog()) { $urFile = $dlg.FileName }
        } elseif ($urChoice -eq '2') {
            Add-Type -AssemblyName System.Windows.Forms
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = 'Select upload request file'
            $dlg.Filter = 'Upload request (*.txt)|*.txt|All files (*.*)|*.*'
            if ($dlg.ShowDialog() -eq 'OK') { $urFile = $dlg.FileName }
        } elseif ($urChoice -eq '3') {
            $urDone = $true
        } else {
            Write-Host "Invalid choice." -ForegroundColor Yellow
            Write-Host ""
            continue
        }
        if (-not $urDone -and $urFile -and (Test-Path -LiteralPath $urFile)) {
            foreach ($line in [System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath $urFile).Path, [System.Text.Encoding]::UTF8)) {
                if ($line -match '^(\w+)=(.*)$') {
                    $upr[$matches[1]] = $matches[2]
                }
            }
            Write-Host "Loaded upload request from: $urFile" -ForegroundColor Green
            # Auto-detect companion description file
            if (-not $descfile -and $upr.ContainsKey('description_file') -and $upr['description_file'] -and (Test-Path -LiteralPath $upr['description_file'])) {
                $descfile = $upr['description_file']
                Write-Host "Using description file: " -NoNewline; Write-Host "$descfile" -ForegroundColor Cyan
            } elseif (-not $descfile) {
                $autoDesc = $urFile -replace '_upload_request\.txt$', '_torrent_description.bbcode'
                if ($autoDesc -ne $urFile -and (Test-Path -LiteralPath $autoDesc)) {
                    $descfile = $autoDesc
                    Write-Host "Auto-detected description file: $descfile" -ForegroundColor Cyan
                }
            }
            # Auto-detect companion mediainfo file
            if (-not $mediainfofile -and $upr.ContainsKey('mediainfo_file') -and $upr['mediainfo_file'] -and (Test-Path -LiteralPath $upr['mediainfo_file'])) {
                $mediainfofile = $upr['mediainfo_file']
                Write-Host "Using mediainfo file: " -NoNewline; Write-Host "$mediainfofile" -ForegroundColor Cyan
            } elseif (-not $mediainfofile) {
                $autoMi = $urFile -replace '_upload_request\.txt$', '_mediainfo.txt'
                if ($autoMi -ne $urFile -and (Test-Path -LiteralPath $autoMi)) {
                    $mediainfofile = $autoMi
                    Write-Host "Auto-detected mediainfo file: $autoMi" -ForegroundColor Cyan
                }
            }
            # Re-read description and mediainfo from the detected files
            if ($descfile) {
                $curDesc = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $descfile).Path, $utf8NoBom)
            }
            if ($mediainfofile) {
                $curMediainfo = (Get-Content -LiteralPath $mediainfofile -Encoding UTF8 | Where-Object { $_ -notmatch '^Encoding settings' }) -join "`n"
            }
            $urDone = $true
        } elseif (-not $urDone) {
            Write-Host "No file selected." -ForegroundColor Yellow
            Write-Host ""
        }
    }
    Write-Host ""
}

# Interactive editing - Name
if ($namefile) {
    $newName = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $namefile).Path, [System.Text.Encoding]::UTF8).Trim()
    Write-Host "Using name from: $namefile" -ForegroundColor Cyan
    Write-Host "  -> $newName" -ForegroundColor Green
} elseif ($upr.ContainsKey('name')) {
    $newName = $upr['name']
    Write-Host "Using name from upload request: " -NoNewline; Write-Host "$newName" -ForegroundColor Cyan
} else {
    Write-Host "Name:" -ForegroundColor Cyan
    Write-Host "  Current: " -NoNewline; Write-Host "$curName" -ForegroundColor Green
    Write-Host "  Enter new name, 'f' to load from file, or press Enter to keep current"
    $nameInput = Read-Host "Name"
    if ($nameInput -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
    if ($nameInput -eq 'f') {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = 'Select name file'
        $dlg.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
        if ($dlg.ShowDialog() -eq 'OK') {
            $newName = [System.IO.File]::ReadAllText($dlg.FileName, [System.Text.Encoding]::UTF8).Trim()
            Write-Host "Loaded name from: $($dlg.FileName)" -ForegroundColor Green
            Write-Host "  -> $newName" -ForegroundColor Green
        } else {
            $newName = $curName
            Write-Host "No file selected, keeping current name." -ForegroundColor Yellow
        }
    } elseif ($nameInput) {
        $newName = $nameInput
    } else {
        $newName = $curName
    }
}

# Interactive editing - Keywords
if ($keywordsfile) {
    $newKeywords = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $keywordsfile).Path, [System.Text.Encoding]::UTF8).Trim()
    Write-Host "Using keywords from: $keywordsfile" -ForegroundColor Cyan
    Write-Host "  -> $newKeywords" -ForegroundColor Green
} elseif ($upr.ContainsKey('keywords_file') -and $upr['keywords_file'] -and (Test-Path -LiteralPath $upr['keywords_file'])) {
    $newKeywords = [System.IO.File]::ReadAllText($upr['keywords_file'], [System.Text.Encoding]::UTF8).Trim()
    Write-Host "Using keywords from: $($upr['keywords_file'])" -ForegroundColor Cyan
    Write-Host "  -> $newKeywords" -ForegroundColor Green
} elseif ($upr.ContainsKey('keywords')) {
    $newKeywords = $upr['keywords']
    Write-Host "Using keywords from upload request: " -NoNewline; Write-Host "$newKeywords" -ForegroundColor Cyan
} elseif ($upr.Count -gt 0) {
    $newKeywords = $curKeywords
} else {
    Write-Host "Keywords:" -ForegroundColor Cyan
    Write-Host "  Current: " -NoNewline; Write-Host "$curKeywords" -ForegroundColor Green
    Write-Host "  Enter new keywords, 'f' to load from file, or press Enter to keep current"
    $kwInput = Read-Host "Keywords"
    if ($kwInput -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
    if ($kwInput -eq 'f') {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = 'Select keywords file'
        $dlg.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
        if ($dlg.ShowDialog() -eq 'OK') {
            $newKeywords = [System.IO.File]::ReadAllText($dlg.FileName, [System.Text.Encoding]::UTF8).Trim()
            Write-Host "Loaded keywords from: $($dlg.FileName)" -ForegroundColor Green
            Write-Host "  -> $newKeywords" -ForegroundColor Green
        } else {
            $newKeywords = $curKeywords
            Write-Host "No file selected, keeping current keywords." -ForegroundColor Yellow
        }
    } elseif ($kwInput) {
        $newKeywords = $kwInput
    } else {
        $newKeywords = $curKeywords
    }
}

# Interactive description - offer to load from file if not already set via -d or -u
$descOverridden = $false
if (-not $descfile -and $upr.Count -eq 0) {
    $outDir = Join-Path $PSScriptRoot "output"
    $icoLoad = [char]::ConvertFromUtf32(0x1F4C4)
    $icoBrowse = [char]::ConvertFromUtf32(0x1F4C2)
    $icoPath = [char]0x270F
    $icoSkip = [char]::ConvertFromUtf32(0x23ED)
    $descDone = $false
    while (-not $descDone) {
        Write-Host ""
        Write-Host "Description:" -ForegroundColor Cyan
        Write-Host "  1) $icoLoad Select from output dir"
        Write-Host "  2) $icoBrowse Browse for file"
        Write-Host "  3) $icoPath  Enter path"
        Write-Host "  4) $icoSkip  Skip (keep current)"
        Write-Host ""
        Write-Host "Description (1-4) [4]: " -NoNewline
        $descKey = [Console]::ReadKey($true).KeyChar
        Write-Host $descKey
        if ($descKey -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
        $descChoice = [string]$descKey
        if ($descChoice -eq "`r" -or $descChoice -eq "`n" -or $descChoice -eq ' ') { $descChoice = '4' }
        if ($descChoice -eq '1') {
            $absOut = if (Test-Path $outDir) { (Resolve-Path $outDir).Path } else { $PSScriptRoot }
            Add-Type -AssemblyName PresentationFramework
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Title = 'Select description file from output'
            $dlg.Filter = 'BBCode files (*.bbcode)|*.bbcode|Text files (*.txt)|*.txt|All files (*.*)|*.*'
            $dlg.InitialDirectory = $absOut
            if ($dlg.ShowDialog()) {
                $curDesc = [System.IO.File]::ReadAllText($dlg.FileName, $utf8NoBom)
                $descOverridden = $true
                Write-Host "Loaded description from: $($dlg.FileName)" -ForegroundColor Green
                $descDone = $true
            } else {
                Write-Host "No file selected." -ForegroundColor Yellow
            }
        } elseif ($descChoice -eq '2') {
            Add-Type -AssemblyName System.Windows.Forms
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = 'Select description file'
            $dlg.Filter = 'BBCode files (*.bbcode)|*.bbcode|Text files (*.txt)|*.txt|All files (*.*)|*.*'
            if ($dlg.ShowDialog() -eq 'OK') {
                $curDesc = [System.IO.File]::ReadAllText($dlg.FileName, $utf8NoBom)
                $descOverridden = $true
                Write-Host "Loaded description from: $($dlg.FileName)" -ForegroundColor Green
                $descDone = $true
            } else {
                Write-Host "No file selected." -ForegroundColor Yellow
            }
        } elseif ($descChoice -eq '3') {
            $descPath = Read-Host "Enter path"
            if ($descPath -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
            if ($descPath -and (Test-Path -LiteralPath $descPath)) {
                $curDesc = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $descPath).Path, $utf8NoBom)
                $descOverridden = $true
                Write-Host "Loaded description from: $descPath" -ForegroundColor Green
                $descDone = $true
            } elseif ($descPath) {
                Write-Host "File not found: $descPath" -ForegroundColor Yellow
            }
        } elseif ($descChoice -eq '4') {
            $descDone = $true
        } else {
            Write-Host "Invalid choice." -ForegroundColor Yellow
        }
    }
}

# Interactive MediaInfo - offer to load from file if not already set via -m
if (-not $mediainfofile -and $upr.Count -eq 0) {
    $outDir = Join-Path $PSScriptRoot "output"
    $icoLoad = [char]::ConvertFromUtf32(0x1F4C4)
    $icoBrowse = [char]::ConvertFromUtf32(0x1F4C2)
    $icoPath = [char]0x270F
    $icoSkip = [char]::ConvertFromUtf32(0x23ED)
    $miDone = $false
    while (-not $miDone) {
        Write-Host ""
        Write-Host "MediaInfo:" -ForegroundColor Cyan
        Write-Host "  1) $icoLoad Select from output dir"
        Write-Host "  2) $icoBrowse Browse for file"
        Write-Host "  3) $icoPath  Enter path"
        Write-Host "  4) $icoSkip  Skip (keep current)"
        Write-Host ""
        Write-Host "MediaInfo (1-4) [4]: " -NoNewline
        $miKey = [Console]::ReadKey($true).KeyChar
        Write-Host $miKey
        if ($miKey -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
        $miChoice = [string]$miKey
        if ($miChoice -eq "`r" -or $miChoice -eq "`n" -or $miChoice -eq ' ') { $miChoice = '4' }
        if ($miChoice -eq '1') {
            $absOut = if (Test-Path $outDir) { (Resolve-Path $outDir).Path } else { $PSScriptRoot }
            Add-Type -AssemblyName PresentationFramework
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Title = 'Select MediaInfo file from output'
            $dlg.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
            $dlg.InitialDirectory = $absOut
            if ($dlg.ShowDialog()) {
                $curMediainfo = (Get-Content -LiteralPath $dlg.FileName -Encoding UTF8 | Where-Object { $_ -notmatch '^Encoding settings' }) -join "`n"
                Write-Host "Loaded mediainfo from: $($dlg.FileName)" -ForegroundColor Green
                $miDone = $true
            } else {
                Write-Host "No file selected." -ForegroundColor Yellow
            }
        } elseif ($miChoice -eq '2') {
            Add-Type -AssemblyName System.Windows.Forms
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = 'Select MediaInfo file'
            $dlg.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
            if ($dlg.ShowDialog() -eq 'OK') {
                $curMediainfo = (Get-Content -LiteralPath $dlg.FileName -Encoding UTF8 | Where-Object { $_ -notmatch '^Encoding settings' }) -join "`n"
                Write-Host "Loaded mediainfo from: $($dlg.FileName)" -ForegroundColor Green
                $miDone = $true
            } else {
                Write-Host "No file selected." -ForegroundColor Yellow
            }
        } elseif ($miChoice -eq '3') {
            $miPath = Read-Host "Enter path"
            if ($miPath -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
            if ($miPath -and (Test-Path -LiteralPath $miPath)) {
                $curMediainfo = (Get-Content -LiteralPath $miPath -Encoding UTF8 | Where-Object { $_ -notmatch '^Encoding settings' }) -join "`n"
                Write-Host "Loaded mediainfo from: $miPath" -ForegroundColor Green
                $miDone = $true
            } elseif ($miPath) {
                Write-Host "File not found: $miPath" -ForegroundColor Yellow
            }
        } elseif ($miChoice -eq '4') {
            $miDone = $true
        } else {
            Write-Host "Invalid choice." -ForegroundColor Yellow
        }
    }
}

# Interactive BDInfo - offer to load file (sent as bdinfo text field)
$curBdinfo = $null
if ($upr.ContainsKey('bdinfo_file') -and $upr['bdinfo_file'] -and (Test-Path -LiteralPath $upr['bdinfo_file'])) {
    $curBdinfo = [System.IO.File]::ReadAllText($upr['bdinfo_file'], [System.Text.Encoding]::UTF8)
    Write-Host "Using BDInfo file: " -NoNewline; Write-Host "$($upr['bdinfo_file'])" -ForegroundColor Cyan
} elseif ($upr.Count -eq 0) {
    $outDir = Join-Path $PSScriptRoot "output"
    $icoLoad = [char]::ConvertFromUtf32(0x1F4C4)
    $icoBrowse = [char]::ConvertFromUtf32(0x1F4C2)
    $icoPath = [char]0x270F
    $icoSkip = [char]::ConvertFromUtf32(0x23ED)
    $bdDone = $false
    while (-not $bdDone) {
        Write-Host ""
        Write-Host "BDInfo:" -ForegroundColor Cyan
        Write-Host "  1) $icoLoad Select from output dir"
        Write-Host "  2) $icoBrowse Browse for file"
        Write-Host "  3) $icoPath  Enter path"
        Write-Host "  4) $icoSkip  Skip (keep current)"
        Write-Host ""
        Write-Host "BDInfo (1-4) [4]: " -NoNewline
        $bdKey = [Console]::ReadKey($true).KeyChar
        Write-Host $bdKey
        if ($bdKey -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
        $bdChoice = [string]$bdKey
        if ($bdChoice -eq "`r" -or $bdChoice -eq "`n" -or $bdChoice -eq ' ') { $bdChoice = '4' }
        if ($bdChoice -eq '1') {
            $absOut = if (Test-Path $outDir) { (Resolve-Path $outDir).Path } else { $PSScriptRoot }
            Add-Type -AssemblyName PresentationFramework
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Title = 'Select BDInfo file from output'
            $dlg.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
            $dlg.InitialDirectory = $absOut
            if ($dlg.ShowDialog()) {
                $curBdinfo = [System.IO.File]::ReadAllText($dlg.FileName, [System.Text.Encoding]::UTF8)
                Write-Host "Loaded BDInfo from: $($dlg.FileName)" -ForegroundColor Green
                $bdDone = $true
            } else {
                Write-Host "No file selected." -ForegroundColor Yellow
            }
        } elseif ($bdChoice -eq '2') {
            Add-Type -AssemblyName System.Windows.Forms
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = 'Select BDInfo file'
            $dlg.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
            if ($dlg.ShowDialog() -eq 'OK') {
                $curBdinfo = [System.IO.File]::ReadAllText($dlg.FileName, [System.Text.Encoding]::UTF8)
                Write-Host "Loaded BDInfo from: $($dlg.FileName)" -ForegroundColor Green
                $bdDone = $true
            } else {
                Write-Host "No file selected." -ForegroundColor Yellow
            }
        } elseif ($bdChoice -eq '3') {
            $bdPath = Read-Host "Enter path"
            if ($bdPath -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
            if ($bdPath -and (Test-Path -LiteralPath $bdPath)) {
                $curBdinfo = [System.IO.File]::ReadAllText($bdPath, [System.Text.Encoding]::UTF8)
                Write-Host "Loaded BDInfo from: $bdPath" -ForegroundColor Green
                $bdDone = $true
            } elseif ($bdPath) {
                Write-Host "File not found: $bdPath" -ForegroundColor Yellow
            }
        } elseif ($bdChoice -eq '4') {
            $bdDone = $true
        } else {
            Write-Host "Invalid choice." -ForegroundColor Yellow
        }
    }
}

# Interactive Cover - offer to load image (sent as torrent-cover=@file)
$curCoverFile = $null
if ($upr.Count -eq 0) {
    $outDir = Join-Path $PSScriptRoot "output"
    $icoLoad = [char]::ConvertFromUtf32(0x1F4C4)
    $icoBrowse = [char]::ConvertFromUtf32(0x1F4C2)
    $icoPath = [char]0x270F
    $icoSkip = [char]::ConvertFromUtf32(0x23ED)
    $covDone = $false
    while (-not $covDone) {
        Write-Host ""
        Write-Host "Cover image:" -ForegroundColor Cyan
        $icoUrl = [char]::ConvertFromUtf32(0x1F310)
        Write-Host "  1) $icoLoad Select from output dir"
        Write-Host "  2) $icoBrowse Browse for file"
        Write-Host "  3) $icoPath  Enter path"
        Write-Host "  4) $icoUrl  Enter URL (download)"
        Write-Host "  5) $icoSkip  Skip (keep current)"
        Write-Host ""
        Write-Host "Cover (1-5) [5]: " -NoNewline
        $covKey = [Console]::ReadKey($true).KeyChar
        Write-Host $covKey
        if ($covKey -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
        $covChoice = [string]$covKey
        if ($covChoice -eq "`r" -or $covChoice -eq "`n" -or $covChoice -eq ' ') { $covChoice = '5' }
        if ($covChoice -eq '1') {
            $absOut = if (Test-Path $outDir) { (Resolve-Path $outDir).Path } else { $PSScriptRoot }
            Add-Type -AssemblyName PresentationFramework
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Title = 'Select cover image from output'
            $dlg.Filter = 'Image files (*.jpg;*.jpeg;*.png;*.webp)|*.jpg;*.jpeg;*.png;*.webp|All files (*.*)|*.*'
            $dlg.InitialDirectory = $absOut
            if ($dlg.ShowDialog()) {
                $curCoverFile = $dlg.FileName
                Write-Host "Loaded cover from: $curCoverFile" -ForegroundColor Green
                $covDone = $true
            } else {
                Write-Host "No file selected." -ForegroundColor Yellow
            }
        } elseif ($covChoice -eq '2') {
            Add-Type -AssemblyName System.Windows.Forms
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = 'Select cover image'
            $dlg.Filter = 'Image files (*.jpg;*.jpeg;*.png;*.webp)|*.jpg;*.jpeg;*.png;*.webp|All files (*.*)|*.*'
            if ($dlg.ShowDialog() -eq 'OK') {
                $curCoverFile = $dlg.FileName
                Write-Host "Loaded cover from: $curCoverFile" -ForegroundColor Green
                $covDone = $true
            } else {
                Write-Host "No file selected." -ForegroundColor Yellow
            }
        } elseif ($covChoice -eq '3') {
            $covPath = Read-Host "Enter path"
            if ($covPath -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
            if ($covPath -and (Test-Path -LiteralPath $covPath)) {
                $curCoverFile = $covPath
                Write-Host "Loaded cover from: $covPath" -ForegroundColor Green
                $covDone = $true
            } elseif ($covPath) {
                Write-Host "File not found: $covPath" -ForegroundColor Yellow
            }
        } elseif ($covChoice -eq '4') {
            $covUrl = Read-Host "Enter URL"
            if ($covUrl -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
            if ($covUrl -and $covUrl -match '^https?://') {
                $covExt = if ($covUrl -match '\.(\w{3,4})(?:\?|$)') { ".$($matches[1])" } else { '.jpg' }
                $covTmp = [System.IO.Path]::GetTempFileName() + $covExt
                Write-Host -NoNewline "Downloading... "
                try {
                    & curl.exe -s -L -o $covTmp $covUrl
                    if ((Test-Path -LiteralPath $covTmp) -and (Get-Item -LiteralPath $covTmp).Length -gt 1000) {
                        $curCoverFile = $covTmp
                        Write-Host "OK ($([math]::Round((Get-Item -LiteralPath $covTmp).Length/1024))KB)" -ForegroundColor Green
                        $covDone = $true
                    } else {
                        Write-Host "FAILED (empty or too small)" -ForegroundColor Yellow
                        Remove-Item -LiteralPath $covTmp -ErrorAction SilentlyContinue
                    }
                } catch {
                    Write-Host "FAILED ($($_.Exception.Message))" -ForegroundColor Yellow
                }
            } elseif ($covUrl) {
                Write-Host "Invalid URL (must start with http:// or https://)" -ForegroundColor Yellow
            }
        } elseif ($covChoice -eq '5') {
            $covDone = $true
        } else {
            Write-Host "Invalid choice." -ForegroundColor Yellow
        }
    }
}

# Interactive Banner - offer to load image (sent as torrent-banner=@file)
$curBannerFile = $null
if ($upr.Count -eq 0) {
    $outDir = Join-Path $PSScriptRoot "output"
    $icoLoad = [char]::ConvertFromUtf32(0x1F4C4)
    $icoBrowse = [char]::ConvertFromUtf32(0x1F4C2)
    $icoPath = [char]0x270F
    $icoSkip = [char]::ConvertFromUtf32(0x23ED)
    $banDone = $false
    while (-not $banDone) {
        Write-Host ""
        Write-Host "Banner image:" -ForegroundColor Cyan
        $icoUrl = [char]::ConvertFromUtf32(0x1F310)
        Write-Host "  1) $icoLoad Select from output dir"
        Write-Host "  2) $icoBrowse Browse for file"
        Write-Host "  3) $icoPath  Enter path"
        Write-Host "  4) $icoUrl  Enter URL (download)"
        Write-Host "  5) $icoSkip  Skip (keep current)"
        Write-Host ""
        Write-Host "Banner (1-5) [5]: " -NoNewline
        $banKey = [Console]::ReadKey($true).KeyChar
        Write-Host $banKey
        if ($banKey -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
        $banChoice = [string]$banKey
        if ($banChoice -eq "`r" -or $banChoice -eq "`n" -or $banChoice -eq ' ') { $banChoice = '5' }
        if ($banChoice -eq '1') {
            $absOut = if (Test-Path $outDir) { (Resolve-Path $outDir).Path } else { $PSScriptRoot }
            Add-Type -AssemblyName PresentationFramework
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Title = 'Select banner image from output'
            $dlg.Filter = 'Image files (*.jpg;*.jpeg;*.png;*.webp)|*.jpg;*.jpeg;*.png;*.webp|All files (*.*)|*.*'
            $dlg.InitialDirectory = $absOut
            if ($dlg.ShowDialog()) {
                $curBannerFile = $dlg.FileName
                Write-Host "Loaded banner from: $curBannerFile" -ForegroundColor Green
                $banDone = $true
            } else {
                Write-Host "No file selected." -ForegroundColor Yellow
            }
        } elseif ($banChoice -eq '2') {
            Add-Type -AssemblyName System.Windows.Forms
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = 'Select banner image'
            $dlg.Filter = 'Image files (*.jpg;*.jpeg;*.png;*.webp)|*.jpg;*.jpeg;*.png;*.webp|All files (*.*)|*.*'
            if ($dlg.ShowDialog() -eq 'OK') {
                $curBannerFile = $dlg.FileName
                Write-Host "Loaded banner from: $curBannerFile" -ForegroundColor Green
                $banDone = $true
            } else {
                Write-Host "No file selected." -ForegroundColor Yellow
            }
        } elseif ($banChoice -eq '3') {
            $banPath = Read-Host "Enter path"
            if ($banPath -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
            if ($banPath -and (Test-Path -LiteralPath $banPath)) {
                $curBannerFile = $banPath
                Write-Host "Loaded banner from: $banPath" -ForegroundColor Green
                $banDone = $true
            } elseif ($banPath) {
                Write-Host "File not found: $banPath" -ForegroundColor Yellow
            }
        } elseif ($banChoice -eq '4') {
            $banUrl = Read-Host "Enter URL"
            if ($banUrl -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
            if ($banUrl -and $banUrl -match '^https?://') {
                $banExt = if ($banUrl -match '\.(\w{3,4})(?:\?|$)') { ".$($matches[1])" } else { '.jpg' }
                $banTmp = [System.IO.Path]::GetTempFileName() + $banExt
                Write-Host -NoNewline "Downloading... "
                try {
                    & curl.exe -s -L -o $banTmp $banUrl
                    if ((Test-Path -LiteralPath $banTmp) -and (Get-Item -LiteralPath $banTmp).Length -gt 1000) {
                        $curBannerFile = $banTmp
                        Write-Host "OK ($([math]::Round((Get-Item -LiteralPath $banTmp).Length/1024))KB)" -ForegroundColor Green
                        $banDone = $true
                    } else {
                        Write-Host "FAILED (empty or too small)" -ForegroundColor Yellow
                        Remove-Item -LiteralPath $banTmp -ErrorAction SilentlyContinue
                    }
                } catch {
                    Write-Host "FAILED ($($_.Exception.Message))" -ForegroundColor Yellow
                }
            } elseif ($banUrl) {
                Write-Host "Invalid URL (must start with http:// or https://)" -ForegroundColor Yellow
            }
        } elseif ($banChoice -eq '5') {
            $banDone = $true
        } else {
            Write-Host "Invalid choice." -ForegroundColor Yellow
        }
    }
}

# Category picker (with type info)
# Resolve categories file: config override -> tracker-host-based -> default
$CategoriesFile = if ($config.categories_file) { [string]$config.categories_file } else { '' }
if ($CategoriesFile -and -not [System.IO.Path]::IsPathRooted($CategoriesFile)) {
    $CategoriesFile = Join-Path $PSScriptRoot $CategoriesFile
}
if (-not $CategoriesFile -or -not (Test-Path -LiteralPath $CategoriesFile)) {
    $CategoriesFile = ''
    if ($TrackerUrl) {
        try {
            $trackerHost = ([System.Uri]$TrackerUrl).Host -replace '\.[^.]+$','' -replace '[^A-Za-z0-9]','_'
            $outFile = Join-Path $PSScriptRoot "output\categories_${trackerHost}.jsonc"
            $sharedFile = Join-Path $PSScriptRoot "shared\categories_${trackerHost}.jsonc"
            if (Test-Path -LiteralPath $outFile) { $CategoriesFile = $outFile }
            elseif (Test-Path -LiteralPath $sharedFile) { $CategoriesFile = $sharedFile }
        } catch { }
    }
}
if (-not $CategoriesFile) {
    $CategoriesFile = Join-Path $PSScriptRoot "shared\categories.jsonc"
}
$allCategories = ([System.IO.File]::ReadAllText($CategoriesFile, $utf8NoBom) -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json

if ($upr.ContainsKey('category_id')) {
    $newCategoryId = $upr['category_id']
    # Prefer explicit cat_type hint from description.ps1 over id-based lookup,
    # so edits honor the original -software/-game/-music intent even when the
    # tracker has no matching category type.
    $catType = if ($upr['cat_type']) { [string]$upr['cat_type'] } else { '' }
    if (-not $catType) {
        $catType = ($allCategories | Where-Object { [string]$_.id -eq $newCategoryId }).type
        if (-not $catType) { $catType = 'movie' }
    }
    $catName = ($allCategories | Where-Object { [string]$_.id -eq $newCategoryId }).name
    Write-Host "Category from upload request: " -NoNewline; Write-Host "$catName (category_id=$newCategoryId, $catType)" -ForegroundColor Cyan
} else {
    Write-Host ""
    Write-Host "Select category:" -ForegroundColor Cyan
    $defaultIdx = 0
    for ($i = 0; $i -lt $allCategories.Count; $i++) {
        $marker = ''
        if ([string]$allCategories[$i].id -eq $curCategoryId) {
            $marker = ' *'
            $defaultIdx = $i
        }
        Write-Host "  $($i+1)) $($allCategories[$i].name) (id=$($allCategories[$i].id), $($allCategories[$i].type))${marker}"
    }
    $catChoice = Read-Host "Category [$($defaultIdx + 1)]"
    if ($catChoice -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
    if (-not $catChoice) { $catChoice = $defaultIdx + 1 }
    $catIdx = [int]$catChoice - 1
    if ($catIdx -ge 0 -and $catIdx -lt $allCategories.Count) {
        $newCategoryId = [string]$allCategories[$catIdx].id
        $catType = $allCategories[$catIdx].type
        Write-Host "Selected: $($allCategories[$catIdx].name) (category_id=$newCategoryId, $catType)" -ForegroundColor Green
    } else {
        $newCategoryId = $curCategoryId
        $catType = ($allCategories | Where-Object { [string]$_.id -eq $curCategoryId }).type
        if (-not $catType) { $catType = 'movie' }
        Write-Host "Invalid choice, keeping: $curCategory" -ForegroundColor Yellow
    }
}

# Type and resolution pickers — skip for games, software and music
if ($catType -eq 'game' -or $catType -eq 'software' -or $catType -eq 'music') {
    $newTypeId = $curTypeId
    $newResolutionId = $curResolutionId
} else {
    # Type picker
    $TypesFile = Join-Path $PSScriptRoot "shared\types.jsonc"
    $allTypes = ([System.IO.File]::ReadAllText($TypesFile, $utf8NoBom) -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json

    if ($upr.ContainsKey('type_id')) {
        $newTypeId = $upr['type_id']
        $typeName = ($allTypes | Where-Object { [string]$_.id -eq $newTypeId }).name
        Write-Host "Type from upload request: " -NoNewline; Write-Host "$typeName (type_id=$newTypeId)" -ForegroundColor Cyan
    } else {
        Write-Host ""
        Write-Host "Select type:" -ForegroundColor Cyan
        $defaultIdx = 0
        for ($i = 0; $i -lt $allTypes.Count; $i++) {
            $marker = ''
            if ([string]$allTypes[$i].id -eq $curTypeId) {
                $marker = ' *'
                $defaultIdx = $i
            }
            Write-Host "  $($i+1)) $($allTypes[$i].name) (id=$($allTypes[$i].id))${marker}"
        }
        $typeChoice = Read-Host "Type [$($defaultIdx + 1)]"
        if ($typeChoice -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
        if (-not $typeChoice) { $typeChoice = $defaultIdx + 1 }
        $typeIdx = [int]$typeChoice - 1
        if ($typeIdx -ge 0 -and $typeIdx -lt $allTypes.Count) {
            $newTypeId = [string]$allTypes[$typeIdx].id
            Write-Host "Selected: $($allTypes[$typeIdx].name) (type_id=$newTypeId)" -ForegroundColor Green
        } else {
            $newTypeId = $curTypeId
            Write-Host "Invalid choice, keeping: $curType" -ForegroundColor Yellow
        }
    }

    # Resolution picker
    $ResFile = Join-Path $PSScriptRoot "shared\resolutions.jsonc"
    $allRes = ([System.IO.File]::ReadAllText($ResFile, $utf8NoBom) -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json

    if ($upr.ContainsKey('resolution_id')) {
        $newResolutionId = $upr['resolution_id']
        $resName = ($allRes | Where-Object { [string]$_.id -eq $newResolutionId }).name
        Write-Host "Resolution from upload request: " -NoNewline; Write-Host "$resName (resolution_id=$newResolutionId)" -ForegroundColor Cyan
    } else {
        Write-Host ""
        Write-Host "Select resolution:" -ForegroundColor Cyan
        $defaultIdx = 0
        for ($i = 0; $i -lt $allRes.Count; $i++) {
            $marker = ''
            if ([string]$allRes[$i].id -eq $curResolutionId) {
                $marker = ' *'
                $defaultIdx = $i
            }
            Write-Host "  $($i+1)) $($allRes[$i].name) (id=$($allRes[$i].id))${marker}"
        }
        $resChoice = Read-Host "Resolution [$($defaultIdx + 1)]"
        if ($resChoice -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
        if (-not $resChoice) { $resChoice = $defaultIdx + 1 }
        $resIdx = [int]$resChoice - 1
        if ($resIdx -ge 0 -and $resIdx -lt $allRes.Count) {
            $newResolutionId = [string]$allRes[$resIdx].id
            Write-Host "Selected: $($allRes[$resIdx].name) (resolution_id=$newResolutionId)" -ForegroundColor Green
        } else {
            $newResolutionId = $curResolutionId
            Write-Host "Invalid choice, keeping: $curResolution" -ForegroundColor Yellow
        }
    }
}

if ($upr.Count -gt 0) {
    $newTmdb     = if ($upr.ContainsKey('tmdb'))           { $upr['tmdb'] }           else { $curTmdb }
    $newImdb     = if ($upr.ContainsKey('imdb'))           { $upr['imdb'] }           else { $curImdb }
    $newDiscogs  = if ($upr.ContainsKey('discogs_id'))     { $upr['discogs_id'] }     else { $curDiscogs }
    $newSeason   = if ($upr.ContainsKey('season_number'))  { $upr['season_number'] }  else { $curSeason }
    $newEpisode  = if ($upr.ContainsKey('episode_number')) { $upr['episode_number'] } else { $curEpisode }
    $newPersonal = if ($upr.ContainsKey('personal'))       { $upr['personal'] }       else { $curPersonal }
    $newAnon     = if ($upr.ContainsKey('anonymous'))      { $upr['anonymous'] }      else { $curAnon }
    $script:posterUrl = if ($upr.ContainsKey('poster') -and $upr['poster']) { $upr['poster'] } else { '' }
    Write-Host "TMDB=" -NoNewline; Write-Host "$newTmdb" -ForegroundColor Cyan -NoNewline
    Write-Host "  IMDB=" -NoNewline; Write-Host "$newImdb" -ForegroundColor Cyan -NoNewline
    Write-Host "  Discogs=" -NoNewline; Write-Host "$newDiscogs" -ForegroundColor Cyan -NoNewline
    Write-Host "  season=" -NoNewline; Write-Host "$newSeason" -ForegroundColor Cyan -NoNewline
    Write-Host "  episode=" -NoNewline; Write-Host "$newEpisode" -ForegroundColor Cyan -NoNewline
    Write-Host "  personal=" -NoNewline; Write-Host "$newPersonal" -ForegroundColor Cyan -NoNewline
    Write-Host "  anonymous=" -NoNewline; Write-Host "$newAnon" -ForegroundColor Cyan
} else {
    Write-Host ""
    $newTmdb = Read-Host "TMDB ID [$curTmdb]"
    if ($newTmdb -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
    if (-not $newTmdb) { $newTmdb = $curTmdb }
    Write-Host "  tmdb=$newTmdb" -ForegroundColor Green
    $newImdb = Read-Host "IMDB ID [$curImdb]"
    if ($newImdb -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
    if (-not $newImdb) { $newImdb = $curImdb }
    Write-Host "  imdb=$newImdb" -ForegroundColor Green
    if ($catType -eq 'music') {
        $newDiscogs = Read-Host "Discogs ID [$curDiscogs]"
        if ($newDiscogs -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
        if (-not $newDiscogs) { $newDiscogs = $curDiscogs }
        Write-Host "  discogs=$newDiscogs" -ForegroundColor Green
    } else {
        $newDiscogs = $curDiscogs
    }
    if ($catType -eq 'tv') {
        Write-Host ""
        Write-Host "Season/Episode:" -ForegroundColor Cyan
        $newSeason = Read-Host "Season [$curSeason]"
        if ($newSeason -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
        if (-not $newSeason) { $newSeason = $curSeason }
        $newEpisode = Read-Host "Episode [$curEpisode]"
        if ($newEpisode -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
        if (-not $newEpisode) { $newEpisode = $curEpisode }
        Write-Host "  -> season=$newSeason, episode=$newEpisode" -ForegroundColor Green
    } else {
        $newSeason = $curSeason
        $newEpisode = $curEpisode
    }
    $newPersonal = Read-Host "Personal release (0/1) [$curPersonal]"
    if ($newPersonal -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
    if (-not $newPersonal) { $newPersonal = $curPersonal }
    Write-Host "  personal=$newPersonal" -ForegroundColor Green
    $newAnon = Read-Host "Anonymous (0/1) [$curAnon]"
    if ($newAnon -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
    if (-not $newAnon) { $newAnon = $curAnon }
    Write-Host "  anonymous=$newAnon" -ForegroundColor Green
}
Write-Host ""

try {
    # Login and get CSRF token from edit page
    Invoke-WebLogin

    if (-not $webFallback) {
        Write-Host "Fetching edit page..." -ForegroundColor Cyan
        $editPage = (& curl.exe -s -c $cookieJar -b $cookieJar --max-time 30 "${TrackerUrl}/torrents/${torrent_id}/edit") -join "`n"
        if ($editPage -match 'name="_token"\s*value="([^"]+)"') {
            $formToken = $matches[1]
        }
        if (-not $formToken) {
            Write-Host "Error: could not get _token from edit page. You may not have permission to edit this torrent." -ForegroundColor Red
            exit 1
        }
        # If no explicit description provided, get from edit page (API may return incomplete version)
        if (-not $descfile -and -not $descOverridden) {
            $lvDesc = Extract-LivewireDesc $editPage
            if ($lvDesc) {
                $curDesc = $lvDesc
            }
        }
    }
    # formToken is already set when webFallback=$true

    # Write fields to temp files to preserve special characters
    [System.IO.File]::WriteAllText($tempName, $newName, $utf8NoBom)
    [System.IO.File]::WriteAllText($tempDesc, $curDesc, $utf8NoBom)
    $tempMediainfo = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tempMediainfo, $curMediainfo, $utf8NoBom)

    $tempKeywords = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tempKeywords, [string]$newKeywords, $utf8NoBom)

    # BDInfo (optional) — sent as text field
    $tempBdinfo = $null
    $bdinfoFields = @()
    if ($curBdinfo -and $curBdinfo.Trim()) {
        $tempBdinfo = [System.IO.Path]::GetTempFileName()
        [System.IO.File]::WriteAllText($tempBdinfo, $curBdinfo, $utf8NoBom)
        $bdinfoFields = @('-F', "bdinfo=<$tempBdinfo")
        Write-Host "Including BDInfo" -ForegroundColor Cyan
    }

    # Build TMDB/IMDB fields based on category type
    # Only send *_exists_on_*=1 checkboxes when ID is non-zero (Laravel required_with validation)
    $extraFields = @()
    if ($catType -eq 'movie') {
        if ($newTmdb -and $newTmdb -ne '0') {
            $extraFields = @('-F', "movie_exists_on_tmdb=1", '-F', "tmdb_movie_id=$newTmdb")
        }
    } elseif ($catType -eq 'tv') {
        if ($newTmdb -and $newTmdb -ne '0') {
            $extraFields = @('-F', "tv_exists_on_tmdb=1", '-F', "tmdb_tv_id=$newTmdb")
        }
        $extraFields += @('-F', "season_number=$newSeason", '-F', "episode_number=$newEpisode")
    }
    if ($newImdb -and $newImdb -ne '0') {
        $extraFields += @('-F', "title_exists_on_imdb=1", '-F', "imdb=$newImdb")
    }
    if ($newDiscogs -and $newDiscogs -ne '0') {
        $extraFields += @('-F', "discogs_id_exists=1", '-F', "discogs_id=$newDiscogs")
    }

    # Step 3: POST torrent update with _method=PATCH
    Write-Host "Updating torrent #${torrent_id}..." -ForegroundColor Cyan

    # Cover image (optional) — only sent if user selected a file
    $coverFields = @()
    $tempCover = $null
    if ($curCoverFile -and (Test-Path -LiteralPath $curCoverFile)) {
        $coverFields = @('-F', "torrent-cover=@$curCoverFile")
        Write-Host "Including cover: $curCoverFile" -ForegroundColor Cyan
    }

    # Banner image (optional)
    $bannerFields = @()
    if ($curBannerFile -and (Test-Path -LiteralPath $curBannerFile)) {
        $bannerFields = @('-F', "torrent-banner=@$curBannerFile")
        Write-Host "Including banner: $curBannerFile" -ForegroundColor Cyan
    }

    $response = & curl.exe -s -w "`n%{http_code}" `
        -D $headerFile `
        -b $cookieJar `
        -X POST `
        -F "_token=$formToken" `
        -F "_method=PATCH" `
        -F "name=<$tempName" `
        -F "description=<$tempDesc" `
        -F "mediainfo=<$tempMediainfo" `
        -F "keywords=<$tempKeywords" `
        @bdinfoFields `
        -F "category_id=$newCategoryId" `
        -F "type_id=$newTypeId" `
        -F "resolution_id=$newResolutionId" `
        @extraFields `
        @coverFields `
        @bannerFields `
        -F "anon=$newAnon" `
        -F "personal_release=$newPersonal" `
        "${TrackerUrl}/torrents/${torrent_id}"

    $lines    = $response -split "`n"
    $httpCode = $lines[-1].Trim()
    $body     = ($lines[0..($lines.Count - 2)]) -join "`n"
    $location = ''
    foreach ($hline in Get-Content -LiteralPath $headerFile) {
        if ($hline -match '^Location:\s*(.+)') {
            $location = $matches[1].Trim()
        }
    }

    Write-Host "HTTP status: " -NoNewline; Write-Host "$httpCode" -ForegroundColor Green
    Write-Host "Redirect: " -NoNewline; Write-Host "$location" -ForegroundColor Green
    if ($httpCode -eq '302') {
        if ($location -match '/edit|/login') {
            Write-Host "Error: update failed. Fetching error details..." -ForegroundColor Red
            $errorPage = (& curl.exe -s -L -b $cookieJar $location) -join "`n"
            # Extract Laravel validation errors from multiple common HTML patterns
            $errors = @()
            # Pattern 1: <li>error text</li> (standard Laravel error bag)
            $errors += @([regex]::Matches($errorPage, '<li>([^<]+)</li>') | ForEach-Object { $_.Groups[1].Value })
            # Pattern 2: alert-danger div with text
            if ($errors.Count -eq 0) {
                $errors += @([regex]::Matches($errorPage, 'alert-danger[^>]*>([^<]+)<') | ForEach-Object { $_.Groups[1].Value.Trim() } | Where-Object { $_ })
            }
            # Pattern 3: Livewire validation errors (wire:dirty spans)
            if ($errors.Count -eq 0) {
                $errors += @([regex]::Matches($errorPage, 'class="[^"]*text-danger[^"]*"[^>]*>([^<]+)<') | ForEach-Object { $_.Groups[1].Value.Trim() } | Where-Object { $_ })
            }
            if ($errors.Count -gt 0) {
                foreach ($err in $errors) { Write-Host "  - $err" -ForegroundColor Red }
            } else {
                Write-Host "(Could not extract specific error messages)" -ForegroundColor Yellow
                $errDump = Join-Path "$PSScriptRoot\..\output" "edit_error_page.html"
                New-Item -Path (Split-Path -Parent $errDump) -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
                [System.IO.File]::WriteAllText($errDump, $errorPage, $utf8NoBom)
                Write-Host "Full error page saved to: $errDump" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "Torrent updated successfully." -ForegroundColor Green
        }
    } elseif ($httpCode -eq '200') {
        Write-Host "Torrent updated successfully." -ForegroundColor Green
    } elseif ($httpCode -eq '403') {
        Write-Host "Error: no permission to edit this torrent." -ForegroundColor Red
        Write-Host "You can only edit your own torrents within 24h of upload, or be a moderator/editor."
    } elseif ($httpCode -eq '419') {
        Write-Host "Error: CSRF token expired or invalid." -ForegroundColor Red
    } else {
        Write-Host "Response:"
        Write-Host ($body.Substring(0, [Math]::Min($body.Length, 2000)))
    }
} finally {
    $toRemove = @($cookieJar, $tempName, $tempDesc, $tempMediainfo, $tempKeywords, $headerFile) | Where-Object { $_ }
    if ($toRemove) { Remove-Item -LiteralPath $toRemove -ErrorAction SilentlyContinue }
    if ($tempBdinfo) { Remove-Item -LiteralPath $tempBdinfo -ErrorAction SilentlyContinue }
    if ($tempCover) { Remove-Item -LiteralPath $tempCover -ErrorAction SilentlyContinue }
}
