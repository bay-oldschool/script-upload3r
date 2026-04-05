# Remove tools installed by install.ps1 (interactive selection)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$PSScriptRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $MyInvocation.MyCommand.Definition)

$ToolsDir = Join-Path $PSScriptRoot "tools"

# Load emoji strings from external UTF-8 file (PS5.1 cannot embed emoji in .ps1)
$stringsFile = Join-Path $PSScriptRoot "shared\uninstall_strings.txt"
$lines = [System.IO.File]::ReadAllLines($stringsFile, [System.Text.Encoding]::UTF8)
$S = @{}
$S.Title       = $lines[0]   # Uninstall Tools
$S.Installed   = $lines[1]   # Installed tools:
$S.Ffmpeg      = $lines[2]   # ffmpeg + ffprobe
$S.MediaInfo   = $lines[3]   # MediaInfo
$S.Magick      = $lines[4]   # ImageMagick
$S.Chafa       = $lines[5]   # chafa
$S.All         = $lines[6]   # All
$S.Exit        = $lines[7]   # Exit
$S.RmFfmpeg    = $lines[8]   # Removing ffmpeg...
$S.RmMediaInfo = $lines[9]   # Removing MediaInfo...
$S.RmMagick    = $lines[10]  # Removing ImageMagick...
$S.RmChafa     = $lines[11]  # Removing chafa...
$S.OkFfmpeg    = $lines[12]  # Removed ffmpeg
$S.OkMediaInfo = $lines[13]  # Removed MediaInfo
$S.OkMagick    = $lines[14]  # Removed ImageMagick
$S.OkChafa     = $lines[15]  # Removed chafa
$S.NoWinget    = $lines[16]  # winget not found
$S.Nothing     = $lines[17]  # Nothing to uninstall
$S.Bye         = $lines[18]  # Exiting
$S.Done        = $lines[19]  # Done in
$S.Prompt      = $lines[20]  # Select tools...
$S.Invalid     = $lines[21]  # Invalid selection

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Detect installed tools ---
$tools = @()

$hasFfmpeg = (Test-Path "$ToolsDir\ffmpeg.exe") -or (Test-Path "$ToolsDir\ffprobe.exe")
if ($hasFfmpeg) { $tools += @{ Name = $S.Ffmpeg; Tag = "ffmpeg" } }

$hasMediaInfo = Test-Path "$ToolsDir\MediaInfo.exe"
if ($hasMediaInfo) { $tools += @{ Name = $S.MediaInfo; Tag = "mediainfo" } }

$hasMagick = $false
if (Get-Command magick -ErrorAction SilentlyContinue) { $hasMagick = $true }
elseif (Get-ChildItem 'C:\Program Files\ImageMagick-*' -Directory -ErrorAction SilentlyContinue) { $hasMagick = $true }
if ($hasMagick) { $tools += @{ Name = $S.Magick; Tag = "magick" } }

$hasChafa = [bool](Get-Command chafa -ErrorAction SilentlyContinue)
if ($hasChafa) { $tools += @{ Name = $S.Chafa; Tag = "chafa" } }

if ($tools.Count -eq 0) {
    Write-Host $S.Nothing -ForegroundColor DarkGray
    exit
}

# --- Show menu ---
Write-Host ""
Write-Host $S.Title -ForegroundColor Red
Write-Host ""
Write-Host $S.Installed -ForegroundColor Cyan
for ($i = 0; $i -lt $tools.Count; $i++) {
    Write-Host "  [$($i + 1)] $($tools[$i].Name)" -ForegroundColor White
}
Write-Host "  [0] $($S.Exit)" -ForegroundColor DarkGray
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

# --- Uninstall selected ---
if ($tags -contains "ffmpeg") {
    Write-Host $S.RmFfmpeg -ForegroundColor Yellow
    foreach ($exe in @("ffmpeg.exe", "ffprobe.exe")) {
        $path = Join-Path $ToolsDir $exe
        if (Test-Path $path) { Remove-Item $path -Force }
    }
    Write-Host $S.OkFfmpeg -ForegroundColor Green
}

if ($tags -contains "mediainfo") {
    Write-Host $S.RmMediaInfo -ForegroundColor Yellow
    $path = Join-Path $ToolsDir "MediaInfo.exe"
    if (Test-Path $path) { Remove-Item $path -Force }
    Write-Host $S.OkMediaInfo -ForegroundColor Green
}

$wingetCmd = Get-Command winget -ErrorAction SilentlyContinue

if ($tags -contains "magick") {
    if ($wingetCmd) {
        Write-Host $S.RmMagick -ForegroundColor Yellow
        & winget uninstall ImageMagick.ImageMagick --accept-source-agreements
        Write-Host $S.OkMagick -ForegroundColor Green
    } else {
        Write-Host $S.NoWinget -ForegroundColor Yellow
    }
}

if ($tags -contains "chafa") {
    if ($wingetCmd) {
        Write-Host $S.RmChafa -ForegroundColor Yellow
        & winget uninstall hpjansson.chafa --accept-source-agreements
        Write-Host $S.OkChafa -ForegroundColor Green
    } else {
        Write-Host $S.NoWinget -ForegroundColor Yellow
    }
}

$sw.Stop()
Write-Host ""
Write-Host "$($S.Done) $([math]::Round($sw.Elapsed.TotalSeconds, 1))s" -ForegroundColor Green
