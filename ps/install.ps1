# Download required tools if not present (interactive selection)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$PSScriptRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $MyInvocation.MyCommand.Definition)

$ToolsDir = Join-Path $PSScriptRoot "tools"
if (!(Test-Path $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir | Out-Null }

$FfmpegUrl    = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
$MediaInfoUrl = "https://mediaarea.net/download/binary/mediainfo/26.01/MediaInfo_CLI_26.01_Windows_x64.zip"

# Load emoji strings from external UTF-8 file (PS5.1 cannot embed emoji in .ps1)
$stringsFile = Join-Path $PSScriptRoot "shared\install_strings.txt"
$lines = [System.IO.File]::ReadAllLines($stringsFile, [System.Text.Encoding]::UTF8)
$S = @{}
$S.Title         = $lines[0]   # Install Tools
$S.Checking      = $lines[1]   # Checking tools:
$S.Ffmpeg        = $lines[2]   # ffmpeg + ffprobe
$S.MediaInfo     = $lines[3]   # MediaInfo
$S.Magick        = $lines[4]   # ImageMagick
$S.Chafa         = $lines[5]   # chafa
$S.All           = $lines[6]   # All
$S.Exit          = $lines[7]   # Exit
$S.DlFfmpeg      = $lines[8]   # Downloading ffmpeg...
$S.ExFfmpeg      = $lines[9]   # Extracting ffmpeg...
$S.OkFfmpeg      = $lines[10]  # ffmpeg installed
$S.DlMediaInfo   = $lines[11]  # Downloading MediaInfo...
$S.ExMediaInfo   = $lines[12]  # Extracting MediaInfo...
$S.OkMediaInfo   = $lines[13]  # MediaInfo installed
$S.DlMagick      = $lines[14]  # Installing ImageMagick...
$S.OkMagick      = $lines[15]  # ImageMagick installed
$S.DlChafa       = $lines[16]  # Installing chafa...
$S.OkChafa       = $lines[17]  # chafa installed
$S.SkipFfmpeg    = $lines[18]  # ffmpeg already present
$S.SkipMediaInfo = $lines[19]  # MediaInfo already present
$S.SkipMagick    = $lines[20]  # ImageMagick already present
$S.SkipChafa     = $lines[21]  # chafa already present
$S.NoWinget      = $lines[22]  # winget not found
$S.Invalid       = $lines[23]  # Invalid selection
$S.Bye           = $lines[24]  # Exiting
$S.Done          = $lines[25]  # All tools ready. Took
$S.Prompt        = $lines[26]  # Select tools to install
$S.ConfigCreated = $lines[27]  # Created config.jsonc
$S.ConfigExists  = $lines[28]  # config.jsonc already exists
$S.RestartTerm   = $lines[29]  # Restart terminal

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- config ---
$configPath = Join-Path $PSScriptRoot "config.jsonc"
$examplePath = Join-Path $PSScriptRoot "config.example.jsonc"
if (!(Test-Path $configPath)) {
    Copy-Item $examplePath $configPath
    Write-Host $S.ConfigCreated -ForegroundColor Green
} else {
    Write-Host $S.ConfigExists -ForegroundColor DarkGray
}

# --- Detect missing tools ---
$tools = @()

$hasFfmpeg = (Test-Path "$ToolsDir\ffmpeg.exe") -and (Test-Path "$ToolsDir\ffprobe.exe")
if (-not $hasFfmpeg) { $tools += @{ Name = $S.Ffmpeg; Tag = "ffmpeg"; Size = "~150 MB" } }

$hasMediaInfo = Test-Path "$ToolsDir\MediaInfo.exe"
if (-not $hasMediaInfo) { $tools += @{ Name = $S.MediaInfo; Tag = "mediainfo"; Size = "~5 MB" } }

$hasMagick = $false
if (Get-Command magick -ErrorAction SilentlyContinue) { $hasMagick = $true }
elseif (Get-ChildItem 'C:\Program Files\ImageMagick-*' -Directory -ErrorAction SilentlyContinue) { $hasMagick = $true }
if (-not $hasMagick) { $tools += @{ Name = $S.Magick; Tag = "magick"; Size = "~35 MB" } }

$hasChafa = [bool](Get-Command chafa -ErrorAction SilentlyContinue)
if (-not $hasChafa) { $tools += @{ Name = $S.Chafa; Tag = "chafa"; Size = "~3 MB" } }

# Show already-present tools
if ($hasFfmpeg) { Write-Host $S.SkipFfmpeg -ForegroundColor DarkGray }
if ($hasMediaInfo) { Write-Host $S.SkipMediaInfo -ForegroundColor DarkGray }
if ($hasMagick) { Write-Host $S.SkipMagick -ForegroundColor DarkGray }
if ($hasChafa) { Write-Host $S.SkipChafa -ForegroundColor DarkGray }

if ($tools.Count -eq 0) {
    $sw.Stop()
    Write-Host ""
    Write-Host "$($S.Done) $([math]::Round($sw.Elapsed.TotalSeconds, 1))s" -ForegroundColor Green
    exit
}

# --- Show menu ---
Write-Host ""
Write-Host $S.Title -ForegroundColor Cyan
Write-Host ""
Write-Host $S.Checking -ForegroundColor Cyan
$totalSize = 0
for ($i = 0; $i -lt $tools.Count; $i++) {
    Write-Host "  [$($i + 1)] $($tools[$i].Name)" -ForegroundColor White -NoNewline
    Write-Host "  ($($tools[$i].Size))" -ForegroundColor DarkGray
    $totalSize += [int]($tools[$i].Size -replace '[^\d]', '')
}
Write-Host "  [0] $($S.Exit)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Total: ~$totalSize MB" -ForegroundColor DarkYellow
Write-Host ""
Write-Host "$($S.Prompt): " -NoNewline
$key = [Console]::ReadKey($false)
Write-Host ""

if ($key.KeyChar -eq '0') {
    Write-Host $S.Bye -ForegroundColor DarkGray
    exit
}

# --- Parse selection ---
$selected = @()
$first = $key.KeyChar
if ($key.Key -eq 'Enter') {
    $selected = $tools
} elseif ($first -match '^\d+$') {
    $idx = [int]"$first" - 1
    if ($idx -ge 0 -and $idx -lt $tools.Count) {
        $selected += $tools[$idx]
    }
}

if ($selected.Count -eq 0) {
    Write-Host $S.Invalid -ForegroundColor Yellow
    exit
}

Write-Host ""
$tags = $selected | ForEach-Object { $_.Tag }
$needRestart = $false

# --- Install selected ---
if ($tags -contains "ffmpeg") {
    Write-Host $S.DlFfmpeg -ForegroundColor Cyan
    $tmp = "$ToolsDir\ffmpeg.zip"
    & curl.exe -L -o "$tmp" "$FfmpegUrl"
    Write-Host $S.ExFfmpeg -ForegroundColor Cyan
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($tmp)
    foreach ($entry in $zip.Entries) {
        if ($entry.Name -eq "ffmpeg.exe" -or $entry.Name -eq "ffprobe.exe") {
            $dest = Join-Path $ToolsDir $entry.Name
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
        }
    }
    $zip.Dispose()
    Remove-Item $tmp -Force
    Write-Host $S.OkFfmpeg -ForegroundColor Green
}

if ($tags -contains "mediainfo") {
    Write-Host $S.DlMediaInfo -ForegroundColor Cyan
    $tmp = "$ToolsDir\mediainfo.zip"
    & curl.exe -L -o "$tmp" "$MediaInfoUrl"
    Write-Host $S.ExMediaInfo -ForegroundColor Cyan
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($tmp)
    foreach ($entry in $zip.Entries) {
        if ($entry.Name -eq "MediaInfo.exe") {
            $dest = Join-Path $ToolsDir $entry.Name
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
        }
    }
    $zip.Dispose()
    Remove-Item $tmp -Force
    Write-Host $S.OkMediaInfo -ForegroundColor Green
}

$wingetCmd = Get-Command winget -ErrorAction SilentlyContinue

if ($tags -contains "magick") {
    if ($wingetCmd) {
        Write-Host $S.DlMagick -ForegroundColor Cyan
        & winget install ImageMagick.ImageMagick --accept-source-agreements --accept-package-agreements
        Write-Host $S.OkMagick -ForegroundColor Green
        $needRestart = $true
    } else {
        Write-Host "$($S.NoWinget)" -ForegroundColor Yellow
        Write-Host "  ImageMagick: https://imagemagick.org" -ForegroundColor Yellow
    }
}

if ($tags -contains "chafa") {
    if ($wingetCmd) {
        Write-Host $S.DlChafa -ForegroundColor Cyan
        & winget install hpjansson.chafa --accept-source-agreements --accept-package-agreements
        Write-Host $S.OkChafa -ForegroundColor Green
        $needRestart = $true
    } else {
        Write-Host "$($S.NoWinget)" -ForegroundColor Yellow
        Write-Host "  chafa: https://hpjansson.org/chafa/" -ForegroundColor Yellow
    }
}

if ($needRestart) {
    Write-Host $S.RestartTerm -ForegroundColor Yellow
}

$sw.Stop()
Write-Host ""
Write-Host "$($S.Done) $([math]::Round($sw.Elapsed.TotalSeconds, 1))s" -ForegroundColor Green
