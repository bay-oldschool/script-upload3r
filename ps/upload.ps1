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
$TrackerUrl = $config.tracker_url

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
$Personal      = $reqData['personal']
$Anonymous     = $reqData['anonymous']
$SeasonNumber  = $reqData['season_number']
$EpisodeNumber = $reqData['episode_number']
$PosterUrl     = $reqData['poster']

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

    # Type and resolution pickers — skip for games and software
    if ($catType -ne 'game' -and $catType -ne 'software') {
        # Read types from types.jsonc and show picker
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

        # Read resolutions from resolutions.jsonc and show picker
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

    $UploadUrl = "${TrackerUrl}/api/torrents/upload?api_token=${ApiKey}"
    Write-Host "Uploading to ${TrackerUrl}..."

    $tvFields = @()
    if ($catType -eq 'tv') {
        $tvFields = @('-F', "season_number=$SeasonNumber", '-F', "episode_number=$EpisodeNumber")
    }

    $posterFields = @()
    $tempPoster = $null
    if ($PosterUrl -and $catType -eq 'software') {
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

    $response = & curl.exe -s -w "`n%{http_code}" `
        -F "torrent=@$tempTorrent" `
        -F "name=<$tempName" `
        -F "category_id=$CategoryId" `
        -F "type_id=$TypeId" `
        -F "resolution_id=$ResolutionId" `
        -F "tmdb=$Tmdb" `
        -F "imdb=$Imdb" `
        -F "igdb=$Igdb" `
        -F "personal_release=$Personal" `
        -F "anonymous=$Anonymous" `
        -F "description=<$tempDesc" `
        -F "mediainfo=<$tempMediainfo" `
        @tvFields `
        @posterFields `
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

        # Upload cover image via web session (only for software; movie/tv/game covers come from TMDB/IGDB)
        if ($torrentId -and $catType -eq 'software' -and $PosterUrl -and $tempPoster -and (Test-Path -LiteralPath $tempPoster) -and (Get-Item -LiteralPath $tempPoster).Length -gt 1000) {
            Write-Host -NoNewline "Uploading cover via web session... "
            try {
                $cfg = (Get-Content -LiteralPath $configfile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json
                $webUser = $cfg.username
                $webPass = $cfg.password
                if ($webUser -and $webPass) {
                    $cj = [System.IO.Path]::GetTempFileName()
                    $hf = [System.IO.Path]::GetTempFileName()
                    # Get login page with CSRF, captcha, and honeypot fields
                    $loginPage = (& curl.exe -s -c $cj -b $cj "${TrackerUrl}/login") -join "`n"
                    $cs = ''; if ($loginPage -match 'name="_token"\s*value="([^"]+)"') { $cs = $matches[1] }
                    $ca = ''; if ($loginPage -match 'name="_captcha"\s*value="([^"]+)"') { $ca = $matches[1] }
                    $rn = ''; $rv = ''
                    if ($loginPage -match 'name="([A-Za-z0-9]{16})"\s*value="(\d+)"') { $rn = $matches[1]; $rv = $matches[2] }
                    if ($cs) {
                        $rf = @(); if ($rn) { $rf = @('-d', "${rn}=${rv}") }
                        # Login using URL-encoded form (same as edit.ps1)
                        & curl.exe -s -D $hf -o NUL -c $cj -b $cj `
                            -d "_token=$cs" -d "_captcha=$ca" -d "_username=" `
                            -d "username=$webUser" --data-urlencode "password=$webPass" `
                            -d "remember=on" @rf "${TrackerUrl}/login"
                        $ll = ''
                        foreach ($h in Get-Content -LiteralPath $hf) {
                            if ($h -match '^Location:\s*(.+)') { $ll = $matches[1].Trim() }
                        }
                        if ($ll -match '/login') {
                            Write-Host "FAILED (login failed)" -ForegroundColor Yellow
                        } else {
                            if ($ll) { & curl.exe -s -o NUL -c $cj -b $cj --max-time 15 $ll | Out-Null }
                            # Fetch edit page for CSRF token
                            $editPage = (& curl.exe -s -c $cj -b $cj --max-time 30 "${TrackerUrl}/torrents/${torrentId}/edit") -join "`n"
                            $editCsrf = [regex]::Match($editPage, 'name="_token"\s*value="([^"]+)"')
                            if (-not $editCsrf.Success) {
                                # Try Livewire token format
                                $editCsrf = [regex]::Match($editPage, '_token&quot;:&quot;([^&]+)&quot;')
                            }
                            if ($editCsrf.Success) {
                                $formToken = $editCsrf.Groups[1].Value
                                # POST edit with cover (include required fields to avoid clearing them)
                                $coverResp = & curl.exe -s -w "`n%{http_code}" -D $hf -b $cj -X POST `
                                    -F "_token=$formToken" -F "_method=PATCH" `
                                    -F "name=<$tempName" -F "description=<$tempDesc" -F "mediainfo=<$tempMediainfo" `
                                    -F "category_id=$CategoryId" -F "type_id=$TypeId" -F "resolution_id=$ResolutionId" `
                                    -F "anon=$Anonymous" -F "personal_release=$Personal" `
                                    -F "torrent-cover=@$tempPoster" `
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
                    } else {
                        Write-Host "FAILED (could not get login token)" -ForegroundColor Yellow
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
        "igdb:          $Igdb"
        "personal:      $Personal"
        "anonymous:     $Anonymous"
    )
    if ($catType -eq 'tv') {
        $log += "season_number: $SeasonNumber"
        $log += "episode_number: $EpisodeNumber"
    }
    if ($PosterUrl) { $log += "poster:        $PosterUrl" }
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
    if ($tempPoster) { Remove-Item -LiteralPath $tempPoster -ErrorAction SilentlyContinue }
}
