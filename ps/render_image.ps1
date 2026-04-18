param(
    [Parameter(Mandatory)][string]$Url,
    [int]$Width = 0,
    [ValidateSet('auto','chafa','magick')][string]$Renderer = 'auto'
)

$magick = (Get-Command magick -ErrorAction SilentlyContinue).Source
if (-not $magick) {
    $d = Get-ChildItem 'C:\Program Files\ImageMagick-*' -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($d) {
        $c = Join-Path $d.FullName 'magick.exe'
        if (Test-Path -LiteralPath $c) { $magick = $c }
    }
}
if (-not $magick) {
    Write-Host 'ImageMagick not found - install it to render images in terminal.' -ForegroundColor Red
    exit 1
}

$tmp = [System.IO.Path]::GetTempFileName() + '.img'
try {
    Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing -ErrorAction Stop
} catch {
    Write-Host "Download failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$termWidth = 120
try { $termWidth = [Console]::WindowWidth } catch { }
if (-not $termWidth -or $termWidth -lt 40) { $termWidth = 120 }
$renderWidth = if ($Width -gt 0) { [math]::Min($Width, $termWidth) } else { $termWidth }

$chafa = (Get-Command chafa -ErrorAction SilentlyContinue).Source
if (-not $chafa) {
    $c = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)) 'tools\chafa.exe'
    if (Test-Path -LiteralPath $c) { $chafa = $c }
}
if (-not $chafa) {
    $wingetPkg = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\hpjansson.Chafa_*" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($wingetPkg) {
        $c = Get-ChildItem "$($wingetPkg.FullName)\chafa-*\Chafa.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { $chafa = $c.FullName }
    }
}

$useChafa = ($Renderer -eq 'chafa') -or ($Renderer -eq 'auto' -and $chafa)
$useMagick = ($Renderer -eq 'magick') -or ($Renderer -eq 'auto' -and -not $chafa -and $magick)

if ($useChafa -and -not $chafa) {
    Write-Host "chafa not found." -ForegroundColor Red
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    exit 1
}
if ($useMagick -and -not $magick) {
    Write-Host "ImageMagick not found." -ForegroundColor Red
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    exit 1
}

if ($useChafa) {
    & $chafa --format sixel -s "${renderWidth}x" $tmp
    Write-Host ""
} elseif ($useMagick) {
    $pxWidth = $renderWidth * 10
    $errFile = [System.IO.Path]::GetTempFileName()
    $sixel = & $magick $tmp -resize "${pxWidth}x>" sixel:- 2>$errFile
    $err = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue
    if ($sixel) {
        [Console]::Out.Write(($sixel -join "`n") + "`n")
        Write-Host ""
    } else {
        Write-Host "ImageMagick produced no output." -ForegroundColor Red
        if ($err) { Write-Host $err -ForegroundColor Red }
    }
} else {
    Write-Host "No image renderer available (install chafa or ImageMagick)." -ForegroundColor Yellow
}

Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
