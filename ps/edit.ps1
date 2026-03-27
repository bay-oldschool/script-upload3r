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
    [string]$mediainfofile
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
    Write-Host "Loaded upload request from: $uploadreqfile"
    # Auto-detect companion description file if -d not specified
    if (-not $descfile) {
        $autoDesc = $uploadreqfile -replace '_upload_request\.txt$', '_torrent_description.bbcode'
        if ($autoDesc -ne $uploadreqfile -and (Test-Path -LiteralPath $autoDesc)) {
            $descfile = $autoDesc
            Write-Host "Auto-detected description file: $descfile"
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

# Read tracker credentials from config
$config     = (Get-Content -LiteralPath $configfile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json
$ApiKey     = $config.api_key
if (-not $ApiKey) { Write-Host "Skipping: 'api_key' not configured in $configfile" -ForegroundColor Yellow; exit 0 }
$TrackerUrl = $config.tracker_url
$Username   = $config.username
$Password   = $config.password

if (-not $Username -or -not $Password) {
    Write-Host "Error: 'username' and 'password' must be set in $configfile for editing" -ForegroundColor Red
    exit 1
}

# Web session helper
$cookieJar  = [System.IO.Path]::GetTempFileName()
$tempName   = [System.IO.Path]::GetTempFileName()
$tempDesc   = [System.IO.Path]::GetTempFileName()
$headerFile = [System.IO.Path]::GetTempFileName()
$webLoggedIn = $false
$webFallback = $false
$formToken   = ''

function Invoke-WebLogin {
    if ($script:webLoggedIn) { return }
    Write-Host "Logging in to ${TrackerUrl}..."
    $lp = (& curl.exe -s -c $script:cookieJar -b $script:cookieJar "${TrackerUrl}/login") -join "`n"
    $cs = ''; if ($lp -match 'name="_token"\s*value="([^"]+)"') { $cs = $matches[1] }
    $ca = ''; if ($lp -match 'name="_captcha"\s*value="([^"]+)"') { $ca = $matches[1] }
    $rn = ''; $rv = ''
    if ($lp -match 'name="([A-Za-z0-9]{16})"\s*value="(\d+)"') { $rn = $matches[1]; $rv = $matches[2] }
    if (-not $cs) { Write-Host "Error: could not get CSRF token from login page" -ForegroundColor Red; exit 1 }
    $rf = @(); if ($rn) { $rf = @('-d', "${rn}=${rv}") }
    $lhf = [System.IO.Path]::GetTempFileName()
    & curl.exe -s -D $lhf -o NUL -c $script:cookieJar -b $script:cookieJar `
        -d "_token=$cs" -d "_captcha=$ca" -d "_username=" `
        -d "username=$Username" --data-urlencode "password=$Password" `
        -d "remember=on" @rf "${TrackerUrl}/login"
    $ll = ''
    foreach ($h in Get-Content -LiteralPath $lhf) {
        if ($h -match '^Location:\s*(.+)') { $ll = $matches[1].Trim() }
    }
    Remove-Item -LiteralPath $lhf -ErrorAction SilentlyContinue
    if ($ll -match '/login') { Write-Host "Error: login failed. Check username/password in config." -ForegroundColor Red; exit 1 }
    Write-Host "Logged in."
    & curl.exe -s -o NUL -c $script:cookieJar -b $script:cookieJar --max-time 15 $ll
    $script:webLoggedIn = $true
}

# Fetch current torrent data via API
Write-Host "Fetching torrent #${torrent_id}..."
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
    $curSeason       = if ($attrs.season_number) { [string]$attrs.season_number } else { '0' }
    $curEpisode      = if ($attrs.episode_number) { [string]$attrs.episode_number } else { '0' }
    $curPersonal     = if ($attrs.personal_release -eq $true) { '1' } else { '0' }
    $curAnon         = if ($attrs.anon -eq 1 -or $attrs.anonymous -eq $true) { '1' } else { '0' }
    $curCategory     = $attrs.category
    $curType         = $attrs.type
    $curResolution   = $attrs.resolution
    if ($descfile) {
        $curDesc = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $descfile).Path, $utf8NoBom)
        Write-Host "Using description from: $descfile"
    } else {
        $curDesc = $attrs.description
        $curDesc = [regex]::Replace($curDesc, '\\([^\x00-\x7F])', '$1')
    }
    if ($mediainfofile) {
        $curMediainfo = (Get-Content -LiteralPath $mediainfofile -Encoding UTF8 | Where-Object { $_ -notmatch '^Encoding settings' }) -join "`n"
        Write-Host "Using mediainfo from: $mediainfofile"
    } else {
        $curMediainfo = ($attrs.media_info -split "`n" | Where-Object { $_ -notmatch '^Encoding settings' }) -join "`n"
    }
} else {
    # API failed - fall back to web edit page
    Write-Host "API fetch failed (HTTP $fetchCode), falling back to web..."
    Invoke-WebLogin
    Write-Host "Fetching edit page..."
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
        Write-Host "Using description from: $descfile"
    } else {
        $curDesc = Extract-LivewireDesc $editPage
        if (-not $curDesc) { $curDesc = '' }
    }
    # Extract mediainfo from textarea
    if ($mediainfofile) {
        $curMediainfo = (Get-Content -LiteralPath $mediainfofile -Encoding UTF8 | Where-Object { $_ -notmatch '^Encoding settings' }) -join "`n"
        Write-Host "Using mediainfo from: $mediainfofile"
    } else {
        $curMediainfo = ''
        if ($editPage -match 'name="mediainfo"[\s\S]*?>\s*([\s\S]*?)\s*</textarea') {
            $curMediainfo = ($matches[1] -split "`n" | Where-Object { $_ -notmatch '^Encoding settings' }) -join "`n"
        }
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
Write-Host "  season:        " -NoNewline; Write-Host "$curSeason" -ForegroundColor Green
Write-Host "  episode:       " -NoNewline; Write-Host "$curEpisode" -ForegroundColor Green
Write-Host "  personal:      " -NoNewline; Write-Host "$curPersonal" -ForegroundColor Green
Write-Host "  anonymous:     " -NoNewline; Write-Host "$curAnon" -ForegroundColor Green
Write-Host ""
Write-Host "  (enter 'c' at any prompt to cancel)" -ForegroundColor DarkGray
Write-Host ""

# Interactive editing - Name
if ($namefile) {
    $newName = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $namefile).Path, [System.Text.Encoding]::UTF8).Trim()
    Write-Host "Using name from: $namefile"
    Write-Host "  -> $newName"
} elseif ($upr.ContainsKey('name')) {
    $newName = $upr['name']
    Write-Host "Using name from upload request: $newName"
} else {
    Write-Host "Name:" -ForegroundColor Cyan
    Write-Host "  Current: $curName"
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

# Interactive description - offer to load from file if not already set via -d or -u
if (-not $descfile -and $upr.Count -eq 0) {
    Write-Host ""
    Write-Host "Description:" -ForegroundColor Cyan
    Write-Host "  Press Enter to keep current, or 'f' to load from file"
    $descInput = Read-Host "Description"
    if ($descInput -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
    if ($descInput -eq 'f') {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = 'Select description file'
        $dlg.Filter = 'BBCode files (*.bbcode)|*.bbcode|Text files (*.txt)|*.txt|All files (*.*)|*.*'
        if ($dlg.ShowDialog() -eq 'OK') {
            $curDesc = [System.IO.File]::ReadAllText($dlg.FileName, $utf8NoBom)
            Write-Host "Loaded description from: $($dlg.FileName)" -ForegroundColor Green
        } else {
            Write-Host "No file selected, keeping current description." -ForegroundColor Yellow
        }
    }
}

# Category picker (with type info)
$CategoriesFile = Join-Path $PSScriptRoot "shared\categories.jsonc"
$allCategories = ([System.IO.File]::ReadAllText($CategoriesFile, $utf8NoBom) -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json

if ($upr.ContainsKey('category_id')) {
    $newCategoryId = $upr['category_id']
    $catType = ($allCategories | Where-Object { [string]$_.id -eq $newCategoryId }).type
    if (-not $catType) { $catType = 'movie' }
    $catName = ($allCategories | Where-Object { [string]$_.id -eq $newCategoryId }).name
    Write-Host "Category from upload request: $catName (category_id=$newCategoryId, $catType)"
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

# Type picker
$TypesFile = Join-Path $PSScriptRoot "shared\types.jsonc"
$allTypes = ([System.IO.File]::ReadAllText($TypesFile, $utf8NoBom) -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json

if ($upr.ContainsKey('type_id')) {
    $newTypeId = $upr['type_id']
    $typeName = ($allTypes | Where-Object { [string]$_.id -eq $newTypeId }).name
    Write-Host "Type from upload request: $typeName (type_id=$newTypeId)"
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
    Write-Host "Resolution from upload request: $resName (resolution_id=$newResolutionId)"
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

if ($upr.Count -gt 0) {
    $newTmdb     = if ($upr.ContainsKey('tmdb'))           { $upr['tmdb'] }           else { $curTmdb }
    $newImdb     = if ($upr.ContainsKey('imdb'))           { $upr['imdb'] }           else { $curImdb }
    $newSeason   = if ($upr.ContainsKey('season_number'))  { $upr['season_number'] }  else { $curSeason }
    $newEpisode  = if ($upr.ContainsKey('episode_number')) { $upr['episode_number'] } else { $curEpisode }
    $newPersonal = if ($upr.ContainsKey('personal'))       { $upr['personal'] }       else { $curPersonal }
    $newAnon     = if ($upr.ContainsKey('anonymous'))      { $upr['anonymous'] }      else { $curAnon }
    Write-Host "TMDB=$newTmdb  IMDB=$newImdb  season=$newSeason  episode=$newEpisode  personal=$newPersonal  anonymous=$newAnon"
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
        Write-Host "Fetching edit page..."
        $editPage = (& curl.exe -s -c $cookieJar -b $cookieJar --max-time 30 "${TrackerUrl}/torrents/${torrent_id}/edit") -join "`n"
        if ($editPage -match 'name="_token"\s*value="([^"]+)"') {
            $formToken = $matches[1]
        }
        if (-not $formToken) {
            Write-Host "Error: could not get _token from edit page. You may not have permission to edit this torrent." -ForegroundColor Red
            exit 1
        }
        # If no explicit description provided, get from edit page (API may return incomplete version)
        if (-not $descfile) {
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

    # Step 3: POST torrent update with _method=PATCH
    Write-Host "Updating torrent #${torrent_id}..."

    $response = & curl.exe -s -w "`n%{http_code}" `
        -D $headerFile `
        -b $cookieJar `
        -X POST `
        -F "_token=$formToken" `
        -F "_method=PATCH" `
        -F "name=<$tempName" `
        -F "description=<$tempDesc" `
        -F "mediainfo=<$tempMediainfo" `
        -F "category_id=$newCategoryId" `
        -F "type_id=$newTypeId" `
        -F "resolution_id=$newResolutionId" `
        @extraFields `
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

    Write-Host "HTTP status: $httpCode"
    Write-Host "Redirect: $location"
    if ($httpCode -eq '302') {
        if ($location -match '/edit|/login') {
            Write-Host "Error: update failed. Fetching error details..." -ForegroundColor Red
            $errorPage = (& curl.exe -s -L -b $cookieJar $location) -join "`n"
            # Extract Laravel validation errors
            $errors = [regex]::Matches($errorPage, '<li>([^<]+)</li>') | ForEach-Object { $_.Groups[1].Value }
            if ($errors) {
                foreach ($err in $errors) { Write-Host "  - $err" }
            } else {
                Write-Host "(Could not extract specific error messages)"
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
    Remove-Item -LiteralPath $cookieJar, $tempName, $tempDesc, $tempMediainfo, $headerFile -ErrorAction SilentlyContinue
}
