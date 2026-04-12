param([Parameter(Mandatory)][string]$Url)

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
$pxWidth = $termWidth * 10

$errFile = [System.IO.Path]::GetTempFileName()
$sixel = & $magick $tmp -resize "${pxWidth}x>" sixel:- 2>$errFile
$err = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue

if ($sixel) {
    [Console]::Out.Write(($sixel -join "`n") + "`n")
    Write-Host ""
    Write-Host "(If you see no image, your terminal does not support sixel graphics.)" -ForegroundColor DarkGray
    Write-Host "Working terminals: Windows Terminal Preview/1.22+, mintty, WezTerm, foot, xterm -ti vt340" -ForegroundColor DarkGray
} else {
    Write-Host "ImageMagick produced no output." -ForegroundColor Red
    if ($err) { Write-Host $err -ForegroundColor Red }
}

Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
