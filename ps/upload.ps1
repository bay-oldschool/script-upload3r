#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Upload a .torrent to a UNIT3D tracker using the pre-built upload request file.
.DESCRIPTION
    Expects the torrent file, _torrent_description.txt and _upload_request.txt to
    already exist in the output directory (run run.ps1 first).
.PARAMETER directory
    Path to the content directory.
.PARAMETER configfile
    Path to JSONC config file (default: ./config.jsonc).
#>
param(
    [Parameter(Position = 0)]
    [string]$directory,

    [Parameter(Position = 1)]
    [string]$configfile,

    [Alias('a')]
    [switch]$auto,

    [Alias('r')]
    [string]$requestfile,

    [Alias('t')]
    [string]$torrentfile,

    [Alias('d')]
    [string]$descriptionfile,

    [Alias('h')]
    [switch]$help
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$PSScriptRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $MyInvocation.MyCommand.Definition)

if ($help -or -not $directory) {
    Write-Host @"
Usage: upload.ps1 [-auto] <directory> [config.jsonc]

Upload a .torrent to a UNIT3D tracker using the pre-built upload request file.
Expects the torrent file, _torrent_description.txt and _upload_request.txt to
already exist in the output directory (run run.ps1 first).

Arguments:
  directory      Path to the content directory
  config.jsonc   Path to JSONC config file (default: ./config.jsonc)

Options:
  -a, -auto          Skip interactive prompts, use defaults
  -r <file>          Override upload request file
  -t <file>          Override torrent file
  -d <file>          Override description file
  -h, -help          Show this help message
"@
    exit 1
}
$directory = $directory.TrimEnd('"').Trim().TrimEnd('\')

if (-not $configfile) { $configfile = Join-Path $PSScriptRoot "config.jsonc" }

if (Test-Path -LiteralPath $directory -PathType Leaf) {
    $singleFile = $directory
    $directory = Split-Path -Parent $directory
    $TorrentName = [System.IO.Path]::GetFileNameWithoutExtension($singleFile)
} else {
    $singleFile = $null
    $TorrentName = Split-Path -Path $directory -Leaf
}
if (-not $singleFile -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
    Write-Host "Error: '$directory' is not a file or directory" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $configfile)) {
    Write-Host "Error: config file '$configfile' not found. Run install.bat to create it from config.example.jsonc" -ForegroundColor Red
    exit 1
}

# Read tracker credentials from config
$config    = (Get-Content -LiteralPath $configfile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json
$ApiKey    = $config.api_key
if (-not $ApiKey) { Write-Host "Skipping: 'api_key' not configured in $configfile" -ForegroundColor Yellow; exit 0 }
$TrackerUrl = if ($config.tracker_url) { ([string]$config.tracker_url).TrimEnd('/') } else { '' }
if (-not $TrackerUrl) { Write-Host "Skipping: 'tracker_url' not configured in $configfile" -ForegroundColor Yellow; exit 0 }
. (Join-Path (Join-Path $PSScriptRoot 'shared') 'web_login.ps1')

$OutDir          = Join-Path $PSScriptRoot "output"
$RequestFile     = if ($requestfile) { $requestfile } else { Join-Path $OutDir "${TorrentName}_upload_request.txt" }
$TorrentFile     = if ($torrentfile) { $torrentfile } else { Join-Path $OutDir "${TorrentName}.torrent" }
$TorrentDescFile = if ($descriptionfile) { $descriptionfile } else { Join-Path $OutDir "${TorrentName}_torrent_description.bbcode" }

if (-not (Test-Path -LiteralPath $RequestFile)) {
    Write-Host "Error: request file '$RequestFile' not found. Run the pipeline first." -ForegroundColor Red
    exit 1
}

# Read request file early to get file paths before validation
$reqData = @{}
foreach ($line in Get-Content -LiteralPath $RequestFile -Encoding UTF8) {
    if ($line -match '^([^=]+)=(.*)$') {
        $reqData[$matches[1]] = $matches[2]
    }
}

# Override description/mediainfo paths from request file if not explicitly provided
if (-not $descriptionfile -and $reqData['description_file'] -and (Test-Path -LiteralPath $reqData['description_file'])) {
    $TorrentDescFile = $reqData['description_file']
}

if (-not (Test-Path -LiteralPath $TorrentFile)) {
    Write-Host "Error: torrent file '$TorrentFile' not found. Run the pipeline first." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $TorrentDescFile)) {
    Write-Host "Error: description file '$TorrentDescFile' not found. Run the pipeline first." -ForegroundColor Red
    exit 1
}

$UploadName    = $reqData['name']
$CategoryId    = $reqData['category_id']
$TypeId        = $reqData['type_id']
$ResolutionId  = $reqData['resolution_id']
$Tmdb          = $reqData['tmdb']
$Imdb          = $reqData['imdb']
$Igdb          = $reqData['igdb']
$DiscogsId     = $reqData['discogs_id']
$Personal      = $reqData['personal']
$Anonymous     = $reqData['anonymous']
$Internal      = if ($reqData['internal']) { $reqData['internal'] } else { 0 }
$Featured      = if ($reqData['featured']) { $reqData['featured'] } else { 0 }
$Free          = if ($reqData['free']) { $reqData['free'] } else { 0 }
$FlUntil       = if ($reqData['fl_until']) { $reqData['fl_until'] } else { 0 }
$DoubleUp      = if ($reqData['doubleup']) { $reqData['doubleup'] } else { 0 }
$DuUntil       = if ($reqData['du_until']) { $reqData['du_until'] } else { 0 }
$Sticky        = if ($reqData['sticky']) { $reqData['sticky'] } else { 0 }
$ModQueue      = if ($reqData['mod_queue_opt_in']) { $reqData['mod_queue_opt_in'] } else { 0 }
$SeasonNumber  = $reqData['season_number']
$EpisodeNumber = $reqData['episode_number']
$PosterUrl     = $reqData['poster']
$BannerUrl     = $reqData['banner']
$NfoFile       = $reqData['nfo_file']
$BdinfoFile    = $reqData['bdinfo_file']

# Keywords from companion _imdb.txt (TMDB keywords) — resolved later when $OutDir is known

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

# Determine type filter: prefer explicit hint from description.ps1 (knows which
# -software/-game/-music/-tv switch the pipeline was invoked with), fall back to
# deriving from category_id when the hint is missing (older request files).
$catType = if ($reqData['cat_type']) { [string]$reqData['cat_type'] } else { '' }
if (-not $catType) {
    $catType = 'movie'
    foreach ($cat in $allCategories) {
        if ([string]$cat.id -eq $CategoryId) { $catType = $cat.type; break }
    }
}

# Filter categories by type; fall back to all categories if nothing matches
# (tracker may not have a type corresponding to the pipeline switch).
$categories = @($allCategories | Where-Object { $_.type -eq $catType })
if ($categories.Count -eq 0) {
    Write-Host "No '$catType' categories on this tracker; showing all." -ForegroundColor Yellow
    $categories = @($allCategories)
}

if (-not $auto.IsPresent) {
    Write-Host "  (enter 'c' at any prompt to cancel)" -ForegroundColor DarkGray

    # Torrent name override
    Write-Host ""
    Write-Host "Torrent name:" -ForegroundColor Cyan
    Write-Host "  $UploadName" -ForegroundColor Green
    $nameInput = Read-Host "Override name (Enter to keep)"
    if ($nameInput -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 2 }
    if ($nameInput) {
        $UploadName = $nameInput
        Write-Host "  -> $UploadName" -ForegroundColor Green
    }

    # Show category picker with default preselected
    Write-Host ""
    Write-Host "Select category ($catType):" -ForegroundColor Cyan
    $defaultIdx = 0
    for ($i = 0; $i -lt $categories.Count; $i++) {
        $marker = ''
        if ([string]$categories[$i].id -eq $CategoryId) {
            $marker = ' *'
            $defaultIdx = $i
        }
        Write-Host "  $($i+1)) $($categories[$i].name) (id=$($categories[$i].id))${marker}"
    }
    $catChoice = Read-Host "Category [$($defaultIdx + 1)]"
    if ($catChoice -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 2 }
    if (-not $catChoice) { $catChoice = $defaultIdx + 1 }
    $catIdx = [int]$catChoice - 1
    if ($catIdx -ge 0 -and $catIdx -lt $categories.Count) {
        $CategoryId = [string]$categories[$catIdx].id
        Write-Host "Selected: $($categories[$catIdx].name) (category_id=$CategoryId)" -ForegroundColor Green
    } else {
        Write-Host "Invalid choice, using default: $($categories[$defaultIdx].name)" -ForegroundColor Yellow
    }

    # Type picker — always shown
    $TypesFile = Join-Path $PSScriptRoot "shared\types.jsonc"
    $allTypes = ([System.IO.File]::ReadAllText($TypesFile, $utf8NoBom) -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json

    Write-Host ""
    Write-Host "Select type:" -ForegroundColor Cyan
    $defaultIdx = 0
    for ($i = 0; $i -lt $allTypes.Count; $i++) {
        $marker = ''
        if ([string]$allTypes[$i].id -eq $TypeId) {
            $marker = ' *'
            $defaultIdx = $i
        }
        Write-Host "  $($i+1)) $($allTypes[$i].name) (id=$($allTypes[$i].id))${marker}"
    }
    $typeChoice = Read-Host "Type [$($defaultIdx + 1)]"
    if ($typeChoice -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 2 }
    if (-not $typeChoice) { $typeChoice = $defaultIdx + 1 }
    $typeIdx = [int]$typeChoice - 1
    if ($typeIdx -ge 0 -and $typeIdx -lt $allTypes.Count) {
        $TypeId = [string]$allTypes[$typeIdx].id
        Write-Host "Selected: $($allTypes[$typeIdx].name) (type_id=$TypeId)" -ForegroundColor Green
    } else {
        Write-Host "Invalid choice, using default: $($allTypes[$defaultIdx].name)" -ForegroundColor Yellow
    }

    # Resolution picker — skip for games, software, and music
    if ($catType -ne 'game' -and $catType -ne 'software' -and $catType -ne 'music') {
        $ResFile = Join-Path $PSScriptRoot "shared\resolutions.jsonc"
        $allRes = ([System.IO.File]::ReadAllText($ResFile, $utf8NoBom) -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json

        Write-Host ""
        Write-Host "Select resolution:" -ForegroundColor Cyan
        $defaultIdx = 0
        for ($i = 0; $i -lt $allRes.Count; $i++) {
            $marker = ''
            if ([string]$allRes[$i].id -eq $ResolutionId) {
                $marker = ' *'
                $defaultIdx = $i
            }
            Write-Host "  $($i+1)) $($allRes[$i].name) (id=$($allRes[$i].id))${marker}"
        }
        $resChoice = Read-Host "Resolution [$($defaultIdx + 1)]"
        if ($resChoice -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 2 }
        if (-not $resChoice) { $resChoice = $defaultIdx + 1 }
        $resIdx = [int]$resChoice - 1
        if ($resIdx -ge 0 -and $resIdx -lt $allRes.Count) {
            $ResolutionId = [string]$allRes[$resIdx].id
            Write-Host "Selected: $($allRes[$resIdx].name) (resolution_id=$ResolutionId)" -ForegroundColor Green
        } else {
            Write-Host "Invalid choice, using default: $($allRes[$defaultIdx].name)" -ForegroundColor Yellow
        }
    }
    Write-Host ""

    # Personal release picker (default from config)
    $cfgPersonal = $config.personal
    $pChoice = Read-Host "Personal (0/1) [$cfgPersonal]"
    if ($pChoice -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 2 }
    if ($pChoice -match '^[01]$') { $Personal = $pChoice } else { $Personal = $cfgPersonal }
    Write-Host "  personal=$Personal" -ForegroundColor Green

    # Anonymous upload picker (default from config)
    $cfgAnonymous = $config.anonymous
    $aChoice = Read-Host "Anonymous (0/1) [$cfgAnonymous]"
    if ($aChoice -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 2 }
    if ($aChoice -match '^[01]$') { $Anonymous = $aChoice } else { $Anonymous = $cfgAnonymous }
    Write-Host "  anonymous=$Anonymous" -ForegroundColor Green

    # Staff-only fields (only prompt when config value is "ask")
    $staffFields = @(
        @{ name = 'internal';         label = 'Internal';              var = 'Internal'; type = 'bool' }
        @{ name = 'featured';         label = 'Featured';              var = 'Featured'; type = 'bool' }
        @{ name = 'free';             label = 'Free (0-100)';          var = 'Free';     type = 'int'  }
        @{ name = 'fl_until';         label = 'Freeleech days';        var = 'FlUntil';  type = 'int'  }
        @{ name = 'doubleup';         label = 'Double Upload';         var = 'DoubleUp'; type = 'bool' }
        @{ name = 'du_until';         label = 'Double Upload days';    var = 'DuUntil';  type = 'int'  }
        @{ name = 'sticky';           label = 'Sticky';                var = 'Sticky';   type = 'bool' }
        @{ name = 'mod_queue_opt_in'; label = 'Mod Queue';             var = 'ModQueue'; type = 'bool' }
    )
    foreach ($sf in $staffFields) {
        $cfgVal = $config.($sf.name)
        if ($cfgVal -eq 'ask') {
            $default = 0
            $prompt = "$($sf.label) ($( if ($sf.type -eq 'int') { '0-100' } else { '0/1' } )) [$default]"
            $input = Read-Host $prompt
            if ($input -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 2 }
            if ($sf.type -eq 'int' -and $input -match '^\d+$') {
                Set-Variable -Name $sf.var -Value $input
            } elseif ($sf.type -eq 'bool' -and $input -match '^[01]$') {
                Set-Variable -Name $sf.var -Value $input
            }
            Write-Host "  $($sf.name)=$(Get-Variable -Name $sf.var -ValueOnly)" -ForegroundColor Green
        }
    }
    Write-Host ""

    # Confirm season/episode for TV uploads
    if ($catType -eq 'tv') {
        Write-Host "Season/Episode:" -ForegroundColor Cyan
        $inputSeason = Read-Host "  Season number [$SeasonNumber]"
        if ($inputSeason -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 2 }
        if ($inputSeason -match '^\d+$') { $SeasonNumber = $inputSeason }
        $inputEpisode = Read-Host "  Episode number [$EpisodeNumber]"
        if ($inputEpisode -eq 'c') { Write-Host "Cancelled." -ForegroundColor Yellow; exit 2 }
        if ($inputEpisode -match '^\d+$') { $EpisodeNumber = $inputEpisode }
        Write-Host "  -> season=$SeasonNumber, episode=$EpisodeNumber" -ForegroundColor Green
    }
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "Using defaults: category_id=$CategoryId, type_id=$TypeId, resolution_id=$ResolutionId"
    if ($catType -eq 'tv') {
        Write-Host "  season=$SeasonNumber, episode=$EpisodeNumber"
    }
    Write-Host ""
}

# Extract MediaInfo: prefer pre-processed file from parse.ps1, fall back to running MediaInfo.exe
$Mediainfo = ''
$MediainfoFile = if ($reqData['mediainfo_file'] -and (Test-Path -LiteralPath $reqData['mediainfo_file'])) { $reqData['mediainfo_file'] } else { Join-Path $OutDir "${TorrentName}_mediainfo.txt" }

# Keywords from keywords_file recorded in upload request
$Keywords = ''
$KeywordsFile = $reqData['keywords_file']
if ($KeywordsFile -and (Test-Path -LiteralPath $KeywordsFile)) {
    $Keywords = [System.IO.File]::ReadAllText($KeywordsFile, [System.Text.Encoding]::UTF8).Trim()
    if ($Keywords) { Write-Host "Including keywords: $Keywords" -ForegroundColor Cyan }
}
if (Test-Path -LiteralPath $MediainfoFile) {
    $Mediainfo = ([System.IO.File]::ReadAllText($MediainfoFile, [System.Text.Encoding]::UTF8) -split "`n" | Where-Object { $_ -notmatch '^Encoding settings' }) -join "`n"
    Write-Host "Using pre-processed mediainfo from: $MediainfoFile"
} else {
    $MediaInfoExe = Join-Path $PSScriptRoot "tools\MediaInfo.exe"
    if (Test-Path -LiteralPath $MediaInfoExe) {
        if ($singleFile) {
            $videoFile = Get-Item -LiteralPath $singleFile
        } else {
            $videoExts = @('.mkv', '.mp4', '.avi', '.ts')
            $videoFile = Get-ChildItem -LiteralPath $directory -Recurse -File |
                Where-Object { ($videoExts -contains $_.Extension.ToLower()) -and ($_.FullName -notmatch 'sample|trailer|featurette') } |
                Sort-Object Name |
                Select-Object -First 1
        }
        if ($videoFile) {
            Write-Host "Running mediainfo on: $($videoFile.Name)"
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = (Resolve-Path $MediaInfoExe).Path
            $psi.Arguments = "`"$($videoFile.FullName)`""
            $psi.RedirectStandardOutput = $true
            $psi.UseShellExecute = $false
            $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
            $proc = [System.Diagnostics.Process]::Start($psi)
            $miRaw = $proc.StandardOutput.ReadToEnd()
            $proc.WaitForExit()
            $Mediainfo = ($miRaw -split "`n" | Where-Object { $_ -notmatch '^Encoding settings' }) -join "`n"
        }
    }
}

# Write name, description and mediainfo to temp files (preserves UTF-8 through curl)
$tempName      = [System.IO.Path]::GetTempFileName()
$tempTorrent   = [System.IO.Path]::GetTempFileName() + ".torrent"
$tempDesc      = [System.IO.Path]::GetTempFileName()
$tempMediainfo = [System.IO.Path]::GetTempFileName()

try {
    [System.IO.File]::WriteAllText($tempName, $UploadName, $utf8NoBom)
    Copy-Item -LiteralPath $TorrentFile -Destination $tempTorrent -Force
    Copy-Item -LiteralPath $TorrentDescFile -Destination $tempDesc -Force
    [System.IO.File]::WriteAllText($tempMediainfo, $Mediainfo, $utf8NoBom)

    # BDInfo field (optional) — sent as separate upload form attribute
    $tempBdinfo = $null
    $bdinfoFields = @()
    if ($BdinfoFile -and (Test-Path -LiteralPath $BdinfoFile)) {
        $bdinfoText = [System.IO.File]::ReadAllText($BdinfoFile, [System.Text.Encoding]::UTF8)
        if ($bdinfoText.Trim()) {
            $tempBdinfo = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllText($tempBdinfo, $bdinfoText, $utf8NoBom)
            $bdinfoFields = @('-F', "bdinfo=<$tempBdinfo")
            Write-Host "Including BDInfo from: $BdinfoFile" -ForegroundColor Cyan
        }
    }

    $UploadUrl = "${TrackerUrl}/api/torrents/upload?api_token=${ApiKey}"
    Write-Host "Uploading to ${TrackerUrl}..."

    $tvFields = @()
    if ($catType -eq 'tv') {
        $tvFields = @('-F', "season_number=$SeasonNumber", '-F', "episode_number=$EpisodeNumber")
    }

    # Download poster/cover image if available (only for no-meta categories: software, music, other)
    $posterFields = @()
    $tempPoster = $null
    $noMeta = $catType -eq 'software' -or $catType -eq 'music' -or $catType -eq 'other'
    if ($PosterUrl -and $noMeta) {
        try {
            $posterExt = if ($PosterUrl -match '\.(\w{3,4})(?:\?|$)') { ".$($matches[1])" } else { '.jpg' }
            $tempPoster = [System.IO.Path]::GetTempFileName() + $posterExt
            Write-Host -NoNewline "Downloading poster for upload... "
            & curl.exe -s -L -o $tempPoster "$PosterUrl"
            if ((Test-Path -LiteralPath $tempPoster) -and (Get-Item -LiteralPath $tempPoster).Length -gt 1000) {
                $posterFields = @('-F', "torrent-cover=@$tempPoster")
                Write-Host "OK ($([math]::Round((Get-Item -LiteralPath $tempPoster).Length/1024))KB)" -ForegroundColor Green
            } else {
                Write-Host "FAILED (empty or too small)" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "FAILED ($($_.Exception.Message))" -ForegroundColor Yellow
        }
    }

    # Download banner image if available (only for no-meta categories)
    $tempBanner = $null
    if ($BannerUrl -and $noMeta) {
        try {
            $bannerExt = if ($BannerUrl -match '\.(\w{3,4})(?:\?|$)') { ".$($matches[1])" } else { '.jpg' }
            $tempBanner = [System.IO.Path]::GetTempFileName() + $bannerExt
            Write-Host -NoNewline "Downloading banner for upload... "
            & curl.exe -s -L -o $tempBanner "$BannerUrl"
            if ((Test-Path -LiteralPath $tempBanner) -and (Get-Item -LiteralPath $tempBanner).Length -gt 1000) {
                Write-Host "OK ($([math]::Round((Get-Item -LiteralPath $tempBanner).Length/1024))KB)" -ForegroundColor Green
            } else {
                Write-Host "FAILED (empty or too small)" -ForegroundColor Yellow
                $tempBanner = $null
            }
        } catch {
            Write-Host "FAILED ($($_.Exception.Message))" -ForegroundColor Yellow
            $tempBanner = $null
        }
    }

    # Build staff-only fields (only include when non-zero)
    $staffCurlFields = @()
    # Resolve any remaining "ask" values to 0
    if ($Internal -match '\D') { $Internal = 0 }
    if ($Featured -match '\D') { $Featured = 0 }
    if ($Free -match '\D')     { $Free = 0 }
    if ($FlUntil -match '\D')  { $FlUntil = 0 }
    if ($DoubleUp -match '\D') { $DoubleUp = 0 }
    if ($DuUntil -match '\D')  { $DuUntil = 0 }
    if ($Sticky -match '\D')   { $Sticky = 0 }
    if ($ModQueue -match '\D') { $ModQueue = 0 }

    if ([int]$Internal -ne 0) { $staffCurlFields += '-F'; $staffCurlFields += "internal=$Internal" }
    if ([int]$Featured -ne 0) { $staffCurlFields += '-F'; $staffCurlFields += "featured=$Featured" }
    if ([int]$Free -ne 0)     { $staffCurlFields += '-F'; $staffCurlFields += "free=$Free" }
    if ([int]$FlUntil -ne 0)  { $staffCurlFields += '-F'; $staffCurlFields += "fl_until=$FlUntil" }
    if ([int]$DoubleUp -ne 0) { $staffCurlFields += '-F'; $staffCurlFields += "doubleup=$DoubleUp" }
    if ([int]$DuUntil -ne 0)  { $staffCurlFields += '-F'; $staffCurlFields += "du_until=$DuUntil" }
    if ([int]$Sticky -ne 0)   { $staffCurlFields += '-F'; $staffCurlFields += "sticky=$Sticky" }
    if ([int]$ModQueue -ne 0) { $staffCurlFields += '-F'; $staffCurlFields += "mod_queue_opt_in=$ModQueue" }

    # NFO file (optional)
    $nfoFields = @()
    if ($NfoFile -and (Test-Path -LiteralPath $NfoFile)) {
        $nfoFields = @('-F', "nfo=@$NfoFile")
        Write-Host "Including NFO: $NfoFile" -ForegroundColor Cyan
    }

    # Resolution field (skip for games, software, music)
    $resFields = @()
    if ($catType -ne 'game' -and $catType -ne 'software' -and $catType -ne 'music') {
        $resFields = @('-F', "resolution_id=$ResolutionId")
    }

    # Discogs id field (only send when present)
    $discogsFields = @()
    if ($DiscogsId) {
        $discogsFields = @('-F', "discogs_id_exists=1", '-F', "discogs_id=$DiscogsId")
        Write-Host "Including Discogs ID: $DiscogsId" -ForegroundColor Cyan
    }

    # Capture curl's trace (request headers + response status) to a temp file,
    # then fold it into the upload log below.
    $curlTrace = [System.IO.Path]::GetTempFileName()
    $response = & curl.exe -sS -w "`n%{http_code}" --trace-ascii $curlTrace `
        -F "torrent=@$tempTorrent" `
        -F "name=<$tempName" `
        -F "category_id=$CategoryId" `
        -F "type_id=$TypeId" `
        @resFields `
        -F "tmdb=$Tmdb" `
        -F "imdb=$Imdb" `
        -F "igdb=$Igdb" `
        @discogsFields `
        -F "keywords=$Keywords" `
        -F "personal_release=$Personal" `
        -F "anonymous=$Anonymous" `
        -F "description=<$tempDesc" `
        -F "mediainfo=<$tempMediainfo" `
        @bdinfoFields `
        @tvFields `
        @posterFields `
        @staffCurlFields `
        @nfoFields `
        $UploadUrl

    $lines    = $response -split "`n"
    $httpCode = $lines[-1].Trim()
    $body     = ($lines[0..($lines.Count - 2)]) -join "`n"

    if ($httpCode -match '^2') {
        Write-Host "Upload successful!" -ForegroundColor Green
        $torrentId = $null
        try {
            $respJson = $body | ConvertFrom-Json
            if ($respJson.data -match '/download/(\d+)') {
                $torrentId = $matches[1]
                Write-Host "View:     ${TrackerUrl}/torrents/${torrentId}" -ForegroundColor Cyan
            }
            if ($respJson.data) {
                Write-Host "Download: $($respJson.data)" -ForegroundColor Cyan
            }
        } catch {
            Write-Host $body
        }

        # Upload cover/banner images via web session
        $hasCover = $tempPoster -and (Test-Path -LiteralPath $tempPoster) -and (Get-Item -LiteralPath $tempPoster).Length -gt 1000
        $hasBanner = $tempBanner -and (Test-Path -LiteralPath $tempBanner) -and (Get-Item -LiteralPath $tempBanner).Length -gt 1000
        if ($torrentId -and ($hasCover -or $hasBanner)) {
            $uploadItems = @()
            if ($hasCover) { $uploadItems += 'cover' }
            if ($hasBanner) { $uploadItems += 'banner' }
            Write-Host -NoNewline "Uploading $($uploadItems -join ' + ') via web session... "
            try {
                $cfg = (Get-Content -LiteralPath $configfile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json
                $webUser = $cfg.username
                $webPass = $cfg.password
                $webTfa  = if ($cfg.two_factor_secret) { $cfg.two_factor_secret } else { '' }
                if ($webUser -and $webPass) {
                    $imgOutDir = Join-Path $PSScriptRoot 'output'
                    $hf = [System.IO.Path]::GetTempFileName()
                    $cj = Get-CachedCookieJar -TrackerUrl $TrackerUrl -Username $webUser `
                        -Password $webPass -TwoFactorSecret $webTfa -OutputDir $imgOutDir
                    if (-not $cj) {
                        Write-Host "FAILED (login failed)" -ForegroundColor Yellow
                    } else {
                        # Fetch edit page for CSRF token
                        $editPage = (& curl.exe -s -c $cj -b $cj --max-time 30 "${TrackerUrl}/torrents/${torrentId}/edit") -join "`n"
                        $editCsrf = [regex]::Match($editPage, 'name="_token"\s*value="([^"]+)"')
                        if (-not $editCsrf.Success) {
                            # Try Livewire token format
                            $editCsrf = [regex]::Match($editPage, '_token&quot;:&quot;([^&]+)&quot;')
                        }
                        if ($editCsrf.Success) {
                            $formToken = $editCsrf.Groups[1].Value
                            # Build image fields
                            $imageFields = @()
                            if ($hasCover) { $imageFields += @('-F', "torrent-cover=@$tempPoster") }
                            if ($hasBanner) { $imageFields += @('-F', "torrent-banner=@$tempBanner") }
                            # POST edit with cover/banner (include required fields to avoid clearing them)
                            $coverResp = & curl.exe -s -w "`n%{http_code}" -D $hf -b $cj -X POST `
                                -F "_token=$formToken" -F "_method=PATCH" `
                                -F "name=<$tempName" -F "description=<$tempDesc" -F "mediainfo=<$tempMediainfo" `
                                @bdinfoFields `
                                -F "keywords=$Keywords" `
                                -F "category_id=$CategoryId" -F "type_id=$TypeId" `
                                -F "anon=$Anonymous" -F "personal_release=$Personal" `
                                @imageFields `
                                "${TrackerUrl}/torrents/${torrentId}"
                            $coverCode = ($coverResp -split "`n")[-1].Trim()
                            if ($coverCode -eq '302') {
                                $coverLoc = ''
                                foreach ($h in Get-Content -LiteralPath $hf) {
                                    if ($h -match '^Location:\s*(.+)') { $coverLoc = $matches[1].Trim() }
                                }
                                if ($coverLoc -and $coverLoc -notmatch '/edit|/login') {
                                    Write-Host "OK" -ForegroundColor Green
                                } else {
                                    Write-Host "FAILED (redirect to $coverLoc)" -ForegroundColor Yellow
                                }
                            } else {
                                Write-Host "FAILED (HTTP $coverCode)" -ForegroundColor Yellow
                            }
                        } else {
                            Write-Host "FAILED (could not get edit page token)" -ForegroundColor Yellow
                        }
                    }
                    Remove-Item -LiteralPath $cj, $hf -ErrorAction SilentlyContinue
                } else {
                    Write-Host "SKIPPED (username/password not configured)" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "FAILED ($($_.Exception.Message))" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "Upload failed (HTTP $httpCode)" -ForegroundColor Red
        # Try to extract error message from JSON response
        $printedJson = $false
        try {
            $errJson = $body | ConvertFrom-Json -ErrorAction Stop
            if ($errJson.message) {
                Write-Host $errJson.message -ForegroundColor Red
                $printedJson = $true
            }
            if ($errJson.data) {
                if ($errJson.data -is [string]) {
                    Write-Host "Details: $($errJson.data)" -ForegroundColor Yellow
                } else {
                    foreach ($prop in $errJson.data.PSObject.Properties) {
                        foreach ($msg in $prop.Value) {
                            Write-Host "  $($prop.Name): $msg" -ForegroundColor Yellow
                        }
                    }
                }
            }
        } catch { }
        if (-not $printedJson) {
            if ($body -match '<!doctype|<html') {
                $titleMatch = [regex]::Match($body, '<title>([^<]+)')
                $pageTitle = if ($titleMatch.Success) { $titleMatch.Groups[1].Value.Trim() } else { 'unknown' }
                Write-Host "Server returned HTML page: $pageTitle" -ForegroundColor Red
                # Laravel's default error view exposes the exception message in <div class="error__body">...</div>
                $bodyMatch = [regex]::Match($body, '<div[^>]*class="[^"]*error__body[^"]*"[^>]*>([\s\S]*?)</div>')
                if (-not $bodyMatch.Success) {
                    # Symfony/Whoops fallback: <h1>...</h1> or <p class="message">...</p>
                    $bodyMatch = [regex]::Match($body, '<(?:h1|h2|p)[^>]*class="[^"]*(?:exception-message|message)[^"]*"[^>]*>([\s\S]*?)</(?:h1|h2|p)>')
                }
                if ($bodyMatch.Success) {
                    $msg = [regex]::Replace($bodyMatch.Groups[1].Value, '<[^>]+>', '').Trim()
                    $msg = [System.Net.WebUtility]::HtmlDecode($msg)
                    if ($msg) { Write-Host "Details: $msg" -ForegroundColor Yellow }
                }
            } else {
                Write-Host $body
            }
        }
        Write-Host "See raw request/response in upload log." -ForegroundColor DarkGray
    }

    # Write upload log
    $LogFile = Join-Path $OutDir "${TorrentName}_upload.log"
    $miLines = if ($Mediainfo) { ($Mediainfo -split "`n").Count } else { 0 }
    $log = @(
        "=== Upload Log ==="
        "Date:          $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Torrent:       $TorrentFile"
        ""
        "=== Request ==="
        "URL:           ${TrackerUrl}/api/torrents/upload"
        "name:          $UploadName"
        "category_id:   $CategoryId"
        "type_id:       $TypeId"
        "resolution_id: $ResolutionId"
        "tmdb:          $Tmdb"
        "imdb:          $Imdb"
        "igdb:          $Igdb"
        "discogs_id:    $DiscogsId"
        "personal:      $Personal"
        "anonymous:     $Anonymous"
        "internal:      $Internal"
        "featured:      $Featured"
        "free:          $Free"
        "fl_until:      $FlUntil"
        "doubleup:      $DoubleUp"
        "du_until:      $DuUntil"
        "sticky:        $Sticky"
        "mod_queue:     $ModQueue"
    )
    if ($catType -eq 'tv') {
        $log += "season_number: $SeasonNumber"
        $log += "episode_number: $EpisodeNumber"
    }
    if ($NfoFile) { $log += "nfo:           $NfoFile" }
    if ($PosterUrl) { $log += "poster:        $PosterUrl" }
    if ($BannerUrl) { $log += "banner:        $BannerUrl" }
    $log += "description:   (from $TorrentDescFile)"
    $log += "mediainfo:     ($miLines lines)"
    $log += ""
    $log += "=== Raw Request (curl trace) ==="
    if ($curlTrace -and (Test-Path -LiteralPath $curlTrace)) {
        $log += (Get-Content -LiteralPath $curlTrace -Raw -ErrorAction SilentlyContinue)
    } else {
        $log += "(trace unavailable)"
    }
    $log += ""
    $log += "=== Raw Response ==="
    $log += "HTTP status:   $httpCode"
    $log += $body
    [System.IO.File]::WriteAllLines($LogFile, $log, $utf8NoBom)
    Write-Host "Log saved to: $LogFile"
} finally {
    Remove-Item -LiteralPath $tempName, $tempTorrent, $tempDesc, $tempMediainfo -ErrorAction SilentlyContinue
    if ($tempBdinfo) { Remove-Item -LiteralPath $tempBdinfo -ErrorAction SilentlyContinue }
    if ($tempPoster) { Remove-Item -LiteralPath $tempPoster -ErrorAction SilentlyContinue }
    if ($tempBanner) { Remove-Item -LiteralPath $tempBanner -ErrorAction SilentlyContinue }
    if ($curlTrace) { Remove-Item -LiteralPath $curlTrace -ErrorAction SilentlyContinue }
}
