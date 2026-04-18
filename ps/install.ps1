# Download required tools if not present (interactive selection)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$PSScriptRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $MyInvocation.MyCommand.Definition)

# ── TLS 1.2 check — required for all HTTPS downloads ────────────────
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$build = [System.Environment]::OSVersion.Version.Build
if ($build -lt 17063) {
    # Older Windows may need registry keys for .NET to use TLS 1.2 reliably
    $needsFix = $false
    $scPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client'
    if (Test-Path $scPath) {
        $enabled = (Get-ItemProperty -Path $scPath -Name 'Enabled' -ErrorAction SilentlyContinue).Enabled
        if ($null -ne $enabled -and $enabled -ne 1) { $needsFix = $true }
    }
    $dotnetPaths = @(
        'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319'
    )
    foreach ($dp in $dotnetPaths) {
        if (Test-Path $dp) {
            $val = (Get-ItemProperty -Path $dp -Name 'SchUseStrongCrypto' -ErrorAction SilentlyContinue).SchUseStrongCrypto
            if ($null -eq $val -or $val -ne 1) { $needsFix = $true }
        } else { $needsFix = $true }
    }
    if ($needsFix) {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($isAdmin) {
            Write-Host "  Applying TLS 1.2 fix for older Windows..." -ForegroundColor Cyan
            if (-not (Test-Path $scPath)) { New-Item -Path $scPath -Force | Out-Null }
            Set-ItemProperty -Path $scPath -Name 'Enabled' -Value 1 -Type DWord
            Set-ItemProperty -Path $scPath -Name 'DisabledByDefault' -Value 0 -Type DWord
            foreach ($dp in $dotnetPaths) {
                if (-not (Test-Path $dp)) { New-Item -Path $dp -Force | Out-Null }
                Set-ItemProperty -Path $dp -Name 'SchUseStrongCrypto' -Value 1 -Type DWord
            }
            Write-Host "  TLS 1.2 registry keys set." -ForegroundColor Green
        } else {
            Write-Host "  WARNING: TLS 1.2 registry fix needed but not running as Administrator." -ForegroundColor Yellow
            Write-Host "  If downloads fail, run as Administrator or use Maintenance > Fix TLS 1.2." -ForegroundColor Yellow
        }
    }
}

$ToolsDir = Join-Path $PSScriptRoot "tools"
if (!(Test-Path $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir | Out-Null }

$FfmpegUrlModern = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
# BtbN's latest requires Win10 1809+ (build 17763). Older Windows uses Gyan's 4.4 build.
$FfmpegUrlLegacy = "https://github.com/GyanD/codexffmpeg/releases/download/4.4/ffmpeg-4.4-essentials_build.zip"
$isLegacyWin     = ($build -lt 17763)
$FfmpegUrl       = if ($isLegacyWin) { $FfmpegUrlLegacy } else { $FfmpegUrlModern }
$FfmpegMarker    = Join-Path (Join-Path $PSScriptRoot "tools") ".ffmpeg_target"
$FfmpegTarget    = if ($isLegacyWin) { "legacy" } else { "modern" }
$MediaInfoUrl = "https://mediaarea.net/download/binary/mediainfo/26.01/MediaInfo_CLI_26.01_Windows_x64.zip"
$CurlUrl      = "https://curl.se/windows/dl-8.19.0_6/curl-8.19.0_6-win64-mingw.zip"
$MagickUrl    = "https://github.com/ImageMagick/ImageMagick/releases/download/7.1.2-19/ImageMagick-7.1.2-19-Q16-HDRI-x64-dll.exe"
$ChafaUrl     = "https://hpjansson.org/chafa/releases/static/chafa-1.18.1-1-x86_64-windows.zip"

# .NET download helper — works on every PS 5.1 system (no curl.exe dependency)
function Download-File([string]$Url, [string]$OutFile) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    try { $wc.DownloadFile($Url, $OutFile) }
    finally { $wc.Dispose() }
}

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

# curl.exe is not bundled with Windows before build 17063 (Win10 1803).
# If missing from both system PATH and tools dir, download it silently first.
$hasCurl = [bool](Get-Command curl.exe -ErrorAction SilentlyContinue)
if (-not $hasCurl) {
    Write-Host "  curl.exe not found - downloading..." -ForegroundColor Cyan
    $tmp = "$ToolsDir\curl.zip"
    try {
        Download-File $CurlUrl $tmp
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($tmp)
        foreach ($entry in $zip.Entries) {
            if ($entry.Name -eq "curl.exe" -or $entry.Name -eq "curl-ca-bundle.crt") {
                $dest = Join-Path $ToolsDir $entry.Name
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
            }
        }
        $zip.Dispose()
        Remove-Item $tmp -Force
        # Add tools dir to PATH for the rest of this session
        $env:PATH = "$ToolsDir;$env:PATH"
        Write-Host "  curl.exe installed to tools/" -ForegroundColor Green
    } catch {
        if (Test-Path $tmp) { Remove-Item $tmp -Force }
        Write-Host "  Failed to download curl.exe: $_" -ForegroundColor Red
        Write-Host "  Download manually from https://curl.se/windows/ and place curl.exe in tools/" -ForegroundColor Yellow
    }
}

$hasFfmpeg = (Test-Path "$ToolsDir\ffmpeg.exe") -and (Test-Path "$ToolsDir\ffprobe.exe")
# If installed binaries target a different OS class (e.g. modern build on Win10 1607),
# force re-install so the right URL gets used.
if ($hasFfmpeg -and (Test-Path $FfmpegMarker)) {
    $installedTarget = (Get-Content -LiteralPath $FfmpegMarker -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($installedTarget -and $installedTarget -ne $FfmpegTarget) {
        Write-Host "  ffmpeg binaries in tools/ target '$installedTarget' but this OS needs '$FfmpegTarget' - will reinstall." -ForegroundColor Yellow
        Remove-Item "$ToolsDir\ffmpeg.exe", "$ToolsDir\ffprobe.exe" -Force -ErrorAction SilentlyContinue
        $hasFfmpeg = $false
    }
} elseif ($hasFfmpeg -and -not (Test-Path $FfmpegMarker) -and $isLegacyWin) {
    # Legacy Windows with no marker means binaries came from the old modern-only install flow - likely broken.
    Write-Host "  ffmpeg binaries in tools/ predate legacy-Windows support - will reinstall." -ForegroundColor Yellow
    Remove-Item "$ToolsDir\ffmpeg.exe", "$ToolsDir\ffprobe.exe" -Force -ErrorAction SilentlyContinue
    $hasFfmpeg = $false
}
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
    if ($isLegacyWin) { Write-Host "  Using legacy Windows build (Gyan 4.4) for build $build" -ForegroundColor DarkGray }
    $tmp = "$ToolsDir\ffmpeg.zip"
    Download-File $FfmpegUrl $tmp
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
    Set-Content -LiteralPath $FfmpegMarker -Value $FfmpegTarget -Encoding ASCII
    Write-Host $S.OkFfmpeg -ForegroundColor Green
}

if ($tags -contains "mediainfo") {
    Write-Host $S.DlMediaInfo -ForegroundColor Cyan
    $tmp = "$ToolsDir\mediainfo.zip"
    Download-File $MediaInfoUrl $tmp
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
        Write-Host $S.DlMagick -ForegroundColor Cyan
        $tmp = "$ToolsDir\magick_setup.exe"
        try {
            Download-File $MagickUrl $tmp
            Write-Host "  Running ImageMagick installer (silent)..." -ForegroundColor Cyan
            $p = Start-Process -FilePath $tmp -ArgumentList "/VERYSILENT /NORESTART" -Wait -PassThru
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            if ($p.ExitCode -eq 0) {
                Write-Host $S.OkMagick -ForegroundColor Green
                $needRestart = $true
            } else {
                Write-Host "  Installer exited with code $($p.ExitCode)" -ForegroundColor Yellow
            }
        } catch {
            if (Test-Path $tmp) { Remove-Item $tmp -Force }
            Write-Host "  Download failed: $_" -ForegroundColor Red
            Write-Host "  Install manually: https://imagemagick.org/script/download.php" -ForegroundColor Yellow
        }
    }
}

if ($tags -contains "chafa") {
    if ($wingetCmd) {
        Write-Host $S.DlChafa -ForegroundColor Cyan
        & winget install hpjansson.chafa --accept-source-agreements --accept-package-agreements
        Write-Host $S.OkChafa -ForegroundColor Green
        $needRestart = $true
    } else {
        Write-Host $S.DlChafa -ForegroundColor Cyan
        $tmp = "$ToolsDir\chafa.zip"
        try {
            Download-File $ChafaUrl $tmp
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [System.IO.Compression.ZipFile]::OpenRead($tmp)
            foreach ($entry in $zip.Entries) {
                if ($entry.Name -eq "chafa.exe") {
                    $dest = Join-Path $ToolsDir $entry.Name
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
                }
            }
            $zip.Dispose()
            Remove-Item $tmp -Force
            Write-Host $S.OkChafa -ForegroundColor Green
        } catch {
            if (Test-Path $tmp) { Remove-Item $tmp -Force }
            Write-Host "  Download failed: $_" -ForegroundColor Red
            Write-Host "  Install manually: https://hpjansson.org/chafa/download/" -ForegroundColor Yellow
        }
    }
}

if ($needRestart) {
    Write-Host $S.RestartTerm -ForegroundColor Yellow
}

$sw.Stop()
Write-Host ""
Write-Host "$($S.Done) $([math]::Round($sw.Elapsed.TotalSeconds, 1))s" -ForegroundColor Green
