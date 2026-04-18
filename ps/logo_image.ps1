# logo_image.ps1 — Render shared/logo.png as ANSI color art using ImageMagick
# Usage: powershell -NoProfile -File ps\logo_image.ps1 [width]
# Requires: magick.exe (ImageMagick 7+) in PATH

param(
    [int]$Width = 80,
    [string]$Path = ''
)

$logoPath = if ($Path) { $Path } else { "$PSScriptRoot\..\shared\logo.png" }
if (-not (Test-Path $logoPath)) {
    Write-Host "Logo image not found: $logoPath" -ForegroundColor Yellow
    exit 1
}

# Check for ImageMagick
$magick = Get-Command magick.exe -ErrorAction SilentlyContinue
if (-not $magick) {
    Write-Host "ImageMagick (magick.exe) not found in PATH." -ForegroundColor Yellow
    exit 2
}

# Get original dimensions to calculate proportional height
$identify = & magick.exe identify -format "%w %h" $logoPath 2>$null
if (-not $identify) { exit 1 }
$parts = $identify.Split(' ')
$origW = [int]$parts[0]
$origH = [int]$parts[1]

# Terminal chars are ~2x taller than wide, so halve the height
$Height = [Math]::Max(1, [int]([Math]::Round($Width * $origH / $origW / 2)))
# Make height even for half-block pairing
if ($Height % 2 -ne 0) { $Height++ }

# Make white transparent, resize smoothly (alpha blends at edges), get RGBA pixel values
$pixels = & magick.exe "$logoPath" -fuzz "10%" -transparent white -resize "${Width}x${Height}!" -depth 8 txt:- 2>$null
if (-not $pixels) { exit 1 }

# Parse into a 2D array [y][x] = @(R,G,B,A)
$grid = New-Object 'object[]' $Height
for ($y = 0; $y -lt $Height; $y++) {
    $grid[$y] = New-Object 'object[]' $Width
}

foreach ($line in $pixels) {
    if ($line -match '^(\d+),(\d+):\s*\((\d+),(\d+),(\d+),(\d+)') {
        $x = [int]$Matches[1]
        $y = [int]$Matches[2]
        if ($x -lt $Width -and $y -lt $Height) {
            $grid[$y][$x] = @([int]$Matches[3], [int]$Matches[4], [int]$Matches[5], [int]$Matches[6])
        }
    }
}

$esc = [char]27
$sb = New-Object System.Text.StringBuilder 16384
$at = 128  # alpha threshold — below this is transparent

# Render using half-block technique: upper half block char with fg=top row, bg=bottom row
for ($y = 0; $y -lt $Height; $y += 2) {
    # Trim trailing transparent columns for this row pair
    $lastCol = $Width - 1
    while ($lastCol -ge 0) {
        $t = $grid[$y][$lastCol]
        $b = $grid[$y + 1][$lastCol]
        $tClear = (-not $t -or $t[3] -lt $at)
        $bClear = (-not $b -or $b[3] -lt $at)
        if ($tClear -and $bClear) { $lastCol-- } else { break }
    }

    for ($x = 0; $x -le $lastCol; $x++) {
        $top = $grid[$y][$x]
        $bot = $grid[$y + 1][$x]
        $topClear = (-not $top -or $top[3] -lt $at)
        $botClear = (-not $bot -or $bot[3] -lt $at)

        if ($topClear -and $botClear) {
            [void]$sb.Append(' ')
        } elseif ($topClear) {
            [void]$sb.Append("$esc[38;2;$($bot[0]);$($bot[1]);$($bot[2])m")
            [void]$sb.Append([char]0x2584)  # lower half block
            [void]$sb.Append("$esc[0m")
        } elseif ($botClear) {
            [void]$sb.Append("$esc[38;2;$($top[0]);$($top[1]);$($top[2])m")
            [void]$sb.Append([char]0x2580)  # upper half block
            [void]$sb.Append("$esc[0m")
        } else {
            [void]$sb.Append("$esc[38;2;$($top[0]);$($top[1]);$($top[2]);48;2;$($bot[0]);$($bot[1]);$($bot[2])m")
            [void]$sb.Append([char]0x2580)
            [void]$sb.Append("$esc[0m")
        }
    }
    [void]$sb.AppendLine()
}

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Host $sb.ToString()
