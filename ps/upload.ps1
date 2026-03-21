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
    [switch]$auto
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$PSScriptRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $MyInvocation.MyCommand.Definition)

if (-not $directory) {
    Write-Host @"
Usage: upload.ps1 [-auto] <directory> [config.jsonc]

Upload a .torrent to a UNIT3D tracker using the pre-built upload request file.
Expects the torrent file, _torrent_description.txt and _upload_request.txt to
already exist in the output directory (run run.ps1 first).

Arguments:
  directory      Path to the content directory
  config.jsonc   Path to JSONC config file (default: ./config.jsonc)

Options:
  -a, -auto    Skip interactive prompts, use defaults
  -h, -help    Show this help message
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
$TrackerUrl = $config.tracker_url

$OutDir          = Join-Path $PSScriptRoot "output"
$RequestFile     = Join-Path $OutDir "${TorrentName}_upload_request.txt"
$TorrentFile     = Join-Path $OutDir "${TorrentName}.torrent"
$TorrentDescFile = Join-Path $OutDir "${TorrentName}_torrent_description.txt"

if (-not (Test-Path -LiteralPath $RequestFile)) {
    Write-Host "Error: request file '$RequestFile' not found. Run the pipeline first." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $TorrentFile)) {
    Write-Host "Error: torrent file '$TorrentFile' not found. Run the pipeline first." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $TorrentDescFile)) {
    Write-Host "Error: description file '$TorrentDescFile' not found. Run the pipeline first." -ForegroundColor Red
    exit 1
}

# Read request file (key=value format)
$reqData = @{}
foreach ($line in Get-Content -LiteralPath $RequestFile -Encoding UTF8) {
    if ($line -match '^([^=]+)=(.*)$') {
        $reqData[$matches[1]] = $matches[2]
    }
}

$UploadName    = $reqData['name']
$CategoryId    = $reqData['category_id']
$TypeId        = $reqData['type_id']
$ResolutionId  = $reqData['resolution_id']
$Tmdb          = $reqData['tmdb']
$Imdb          = $reqData['imdb']
$Personal      = $reqData['personal']
$Anonymous     = $reqData['anonymous']
$SeasonNumber  = $reqData['season_number']
$EpisodeNumber = $reqData['episode_number']

# Read categories from categories.jsonc
$CategoriesFile = Join-Path $PSScriptRoot "shared\categories.jsonc"
$allCategories = ([System.IO.File]::ReadAllText($CategoriesFile, $utf8NoBom) -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json

# Determine type filter from default category_id
$catType = 'movie'
foreach ($cat in $allCategories) {
    if ([string]$cat.id -eq $CategoryId) { $catType = $cat.type; break }
}

# Filter categories by type
$categories = @($allCategories | Where-Object { $_.type -eq $catType })

if (-not $auto.IsPresent) {
    # Show category picker with default preselected
    Write-Host ""
    Write-Host "Select category ($catType):"
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
    if (-not $catChoice) { $catChoice = $defaultIdx + 1 }
    $catIdx = [int]$catChoice - 1
    if ($catIdx -ge 0 -and $catIdx -lt $categories.Count) {
        $CategoryId = [string]$categories[$catIdx].id
        Write-Host "Selected: $($categories[$catIdx].name) (category_id=$CategoryId)"
    } else {
        Write-Host "Invalid choice, using default: $($categories[$defaultIdx].name)"
    }

    # Read types from types.jsonc and show picker
    $TypesFile = Join-Path $PSScriptRoot "shared\types.jsonc"
    $allTypes = ([System.IO.File]::ReadAllText($TypesFile, $utf8NoBom) -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json

    Write-Host ""
    Write-Host "Select type:"
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
    if (-not $typeChoice) { $typeChoice = $defaultIdx + 1 }
    $typeIdx = [int]$typeChoice - 1
    if ($typeIdx -ge 0 -and $typeIdx -lt $allTypes.Count) {
        $TypeId = [string]$allTypes[$typeIdx].id
        Write-Host "Selected: $($allTypes[$typeIdx].name) (type_id=$TypeId)"
    } else {
        Write-Host "Invalid choice, using default: $($allTypes[$defaultIdx].name)"
    }

    # Read resolutions from resolutions.jsonc and show picker
    $ResFile = Join-Path $PSScriptRoot "shared\resolutions.jsonc"
    $allRes = ([System.IO.File]::ReadAllText($ResFile, $utf8NoBom) -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json

    Write-Host ""
    Write-Host "Select resolution:"
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
    if (-not $resChoice) { $resChoice = $defaultIdx + 1 }
    $resIdx = [int]$resChoice - 1
    if ($resIdx -ge 0 -and $resIdx -lt $allRes.Count) {
        $ResolutionId = [string]$allRes[$resIdx].id
        Write-Host "Selected: $($allRes[$resIdx].name) (resolution_id=$ResolutionId)"
    } else {
        Write-Host "Invalid choice, using default: $($allRes[$defaultIdx].name)"
    }
    Write-Host ""

    # Personal release picker (default from config)
    $cfgPersonal = $config.personal
    $pChoice = Read-Host "Personal (0/1) [$cfgPersonal]"
    if ($pChoice -match '^[01]$') { $Personal = $pChoice } else { $Personal = $cfgPersonal }
    Write-Host "  personal=$Personal"

    # Anonymous upload picker (default from config)
    $cfgAnonymous = $config.anonymous
    $aChoice = Read-Host "Anonymous (0/1) [$cfgAnonymous]"
    if ($aChoice -match '^[01]$') { $Anonymous = $aChoice } else { $Anonymous = $cfgAnonymous }
    Write-Host "  anonymous=$Anonymous"
    Write-Host ""

    # Confirm season/episode for TV uploads
    if ($catType -eq 'tv') {
        Write-Host "Season/Episode:"
        $inputSeason = Read-Host "  Season number [$SeasonNumber]"
        if ($inputSeason -match '^\d+$') { $SeasonNumber = $inputSeason }
        $inputEpisode = Read-Host "  Episode number [$EpisodeNumber]"
        if ($inputEpisode -match '^\d+$') { $EpisodeNumber = $inputEpisode }
        Write-Host "  -> season=$SeasonNumber, episode=$EpisodeNumber"
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

Write-Host "Upload name: $UploadName"

# Extract MediaInfo from video file (optional)
$Mediainfo = ''
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

    $UploadUrl = "${TrackerUrl}/api/torrents/upload?api_token=${ApiKey}"
    Write-Host "Uploading to ${TrackerUrl}..."

    $tvFields = @()
    if ($catType -eq 'tv') {
        $tvFields = @('-F', "season_number=$SeasonNumber", '-F', "episode_number=$EpisodeNumber")
    }

    $response = & curl.exe -s -w "`n%{http_code}" `
        -F "torrent=@$tempTorrent" `
        -F "name=<$tempName" `
        -F "category_id=$CategoryId" `
        -F "type_id=$TypeId" `
        -F "resolution_id=$ResolutionId" `
        -F "tmdb=$Tmdb" `
        -F "imdb=$Imdb" `
        -F "personal_release=$Personal" `
        -F "anonymous=$Anonymous" `
        -F "description=<$tempDesc" `
        -F "mediainfo=<$tempMediainfo" `
        @tvFields `
        $UploadUrl

    $lines    = $response -split "`n"
    $httpCode = $lines[-1].Trim()
    $body     = ($lines[0..($lines.Count - 2)]) -join "`n"

    if ($httpCode -match '^2') {
        Write-Host "Upload successful!" -ForegroundColor Green
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
    } else {
        Write-Host "Upload failed (HTTP $httpCode)" -ForegroundColor Red
        # Try to extract error message from JSON response
        if ($body -match '"message"\s*:\s*"([^"]+)"') {
            Write-Host $matches[1] -ForegroundColor Red
            # Show validation details from data field
            if ($body -match '"data"\s*:\s*"([^"]+)"') {
                Write-Host "Details: $($matches[1])" -ForegroundColor Yellow
            } elseif ($body -match '"data"\s*:\s*\{') {
                try {
                    $errJson = $body | ConvertFrom-Json
                    foreach ($prop in $errJson.data.PSObject.Properties) {
                        foreach ($msg in $prop.Value) {
                            Write-Host "  $($prop.Name): $msg" -ForegroundColor Yellow
                        }
                    }
                } catch {}
            }
        } elseif ($body -match '<!doctype|<html') {
            $titleMatch = [regex]::Match($body, '<title>([^<]+)')
            $pageTitle = if ($titleMatch.Success) { $titleMatch.Groups[1].Value } else { 'unknown' }
            Write-Host "Server returned HTML page: $pageTitle. Check tracker_url in config." -ForegroundColor Red
        } else {
            Write-Host $body
        }
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
        "personal:      $Personal"
        "anonymous:     $Anonymous"
    )
    if ($catType -eq 'tv') {
        $log += "season_number: $SeasonNumber"
        $log += "episode_number: $EpisodeNumber"
    }
    $log += "description:   (from $TorrentDescFile)"
    $log += "mediainfo:     ($miLines lines)"
    $log += ""
    $log += "=== Response ==="
    $log += "HTTP status:   $httpCode"
    $log += $body
    [System.IO.File]::WriteAllLines($LogFile, $log, $utf8NoBom)
    Write-Host "Log saved to: $LogFile"
} finally {
    Remove-Item -LiteralPath $tempName, $tempTorrent, $tempDesc, $tempMediainfo -ErrorAction SilentlyContinue
}
