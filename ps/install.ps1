# Download required tools if not present
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$PSScriptRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $MyInvocation.MyCommand.Definition)

$ToolsDir = Join-Path $PSScriptRoot "tools"
if (!(Test-Path $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir | Out-Null }

$FfmpegUrl    = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
$MediaInfoUrl = "https://mediaarea.net/download/binary/mediainfo/26.01/MediaInfo_CLI_26.01_Windows_x64.zip"

# --- config ---
$configPath = Join-Path $PSScriptRoot "config.jsonc"
$examplePath = Join-Path $PSScriptRoot "config.example.jsonc"
if (!(Test-Path $configPath)) {
    Copy-Item $examplePath $configPath
    Write-Host "Created config.jsonc from example. Edit it with your settings." -ForegroundColor Green
} else {
    Write-Host "config.jsonc already exists, skipping."
}

# --- ffmpeg & ffprobe ---
if (!(Test-Path "$ToolsDir\ffmpeg.exe") -or !(Test-Path "$ToolsDir\ffprobe.exe")) {
    Write-Host "Downloading ffmpeg..."
    $tmp = "$ToolsDir\ffmpeg.zip"
    & curl.exe -L -o "$tmp" "$FfmpegUrl"
    Write-Host "Extracting ffmpeg..."
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
    Write-Host "ffmpeg & ffprobe installed."
} else {
    Write-Host "ffmpeg & ffprobe already present, skipping."
}

# --- MediaInfo ---
if (!(Test-Path "$ToolsDir\MediaInfo.exe")) {
    Write-Host "Downloading MediaInfo..."
    $tmp = "$ToolsDir\mediainfo.zip"
    & curl.exe -L -o "$tmp" "$MediaInfoUrl"
    Write-Host "Extracting MediaInfo..."
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
    Write-Host "MediaInfo installed."
} else {
    Write-Host "MediaInfo already present, skipping."
}

$sw.Stop()
Write-Host "All tools ready. Took $([math]::Round($sw.Elapsed.TotalSeconds, 1))s" -ForegroundColor Green
