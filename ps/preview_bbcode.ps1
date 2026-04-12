#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Render a BBCode file with ANSI terminal colors.
.PARAMETER file
    Path to the BBCode file to preview.
#>
param(
    [Parameter(Position = 0)]
    [string]$file,
    [switch]$images
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not $file -or -not (Test-Path -LiteralPath $file)) {
    Write-Host "Usage: preview_bbcode.ps1 <file.bbcode>" -ForegroundColor Red
    exit 1
}

$text = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $file).Path, [System.Text.Encoding]::UTF8)
$text = $text -replace "`r", ''

# ANSI escape codes
$esc = [char]27
$bold      = "${esc}[1m"
$italic    = "${esc}[3m"
$underline = "${esc}[4m"
$reset     = "${esc}[0m"
$dimGray   = "${esc}[90m"
$cyan      = "${esc}[96m"
$green     = "${esc}[92m"
$yellow    = "${esc}[93m"
$blue      = "${esc}[94m"
$magenta   = "${esc}[95m"

# Terminal width for table rendering and sixel image sizing
$termWidth = 120
try { $termWidth = [Console]::WindowWidth } catch { }
if (-not $termWidth -or $termWidth -lt 40) {
    try { $termWidth = $Host.UI.RawUI.WindowSize.Width } catch { }
}
if (-not $termWidth -or $termWidth -lt 40) { $termWidth = 120 }

# Find ImageMagick for sixel image rendering
$magickExe = $null
$bannerUrls = @()
$posterUrls = @()
$screenUrls = @()
$termPixelWidth = 0
if ($images) {
    $magickExe = (Get-Command magick -ErrorAction SilentlyContinue).Source
    if (-not $magickExe) {
        $imDir = Get-ChildItem 'C:\Program Files\ImageMagick-*' -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($imDir) {
            $candidate = Join-Path $imDir.FullName 'magick.exe'
            if (Test-Path $candidate) { $magickExe = $candidate }
        }
    }
    if ($magickExe) {
        # Terminal pixel width — query via Win32 API, fallback to estimate
        try {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class ConsolePixel {
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int h);
    [DllImport("kernel32.dll")] static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CSBI i);
    [StructLayout(LayoutKind.Sequential)] public struct COORD { public short X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct SMALL_RECT { public short L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct CSBI { public COORD S; public COORD P; public short A; public SMALL_RECT W; public COORD M; }
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    public static int GetWidth() {
        RECT r; if (GetClientRect(GetConsoleWindow(), out r)) return r.R - r.L; return 0;
    }
}
'@ -ErrorAction Stop
            $termPixelWidth = [ConsolePixel]::GetWidth()
        } catch { }
        if (-not $termPixelWidth -or $termPixelWidth -lt 100) {
            $termPixelWidth = $termWidth * 10
        }
    }
}

# Replace [img] tags — collect URLs when rendering images, always show [IMG] placeholder
$text = [regex]::Replace($text, '\[img(?:=(\d+))?\](.*?)\[/img\]', {
    param($m)
    $size = $m.Groups[1].Value
    $url = $m.Groups[2].Value
    if ($magickExe -and $url -match '^https?://') {
        if ($size -eq '250') { $script:posterUrls += $url }
        elseif ($size -eq '1920') { $script:bannerUrls += $url }
        else { $script:screenUrls += $url }
    }
    "${dimGray}[IMG]${reset}"
})

# OSC 8 hyperlink helpers
$oscOpen  = "${esc}]8;;"
$oscClose = "${esc}\"

# URLs with text: [url=link]text[/url] - clickable text via OSC 8
$text = [regex]::Replace($text, '\[url=([^\]]+)\](.*?)\[/url\]', {
    param($m)
    $url  = $m.Groups[1].Value
    $label = $m.Groups[2].Value
    "${oscOpen}${url}${oscClose}${underline}${blue}${label}${reset}${oscOpen}${oscClose}"
})

# URLs without text: [url]link[/url] - clickable link via OSC 8
$text = [regex]::Replace($text, '\[url\](.*?)\[/url\]', {
    param($m)
    $url = $m.Groups[1].Value
    "${oscOpen}${url}${oscClose}${underline}${blue}${url}${reset}${oscOpen}${oscClose}"
})

# Bold
$text = $text -replace '\[b\]', $bold -replace '\[/b\]', $reset

# Italic
$text = $text -replace '\[i\]', $italic -replace '\[/i\]', $reset

# Underline
$text = $text -replace '\[u\]', $underline -replace '\[/u\]', $reset

# Size - large sizes get bold, small sizes get dim
$text = [regex]::Replace($text, '\[size=(\d+)\]', {
    param($m)
    $s = [int]$m.Groups[1].Value
    if ($s -ge 20) { $bold }
    elseif ($s -le 10) { $dimGray }
    else { '' }
})
$text = $text -replace '\[/size\]', $reset

# Color tags
$text = [regex]::Replace($text, '\[color=([^\]]+)\]', {
    param($m)
    $c = $m.Groups[1].Value.ToLower()
    switch -Wildcard ($c) {
        '#7760de' { $magenta }
        '#5f5f5f' { $dimGray }
        'red'     { "${esc}[91m" }
        'green'   { $green }
        'blue'    { $blue }
        'yellow'  { $yellow }
        'cyan'    { $cyan }
        default   { '' }
    }
})
$text = $text -replace '\[/color\]', $reset

# Center - just remove tags
$text = $text -replace '\[/?center\]', ''

# Spoiler
$text = [regex]::Replace($text, '\[spoiler=([^\]]+)\]', {
    param($m)
    "`n${yellow}--- $($m.Groups[1].Value) ---${reset}`n"
})
$text = $text -replace '\[spoiler\]', "`n${yellow}--- Spoiler ---${reset}`n"
$text = $text -replace '\[/spoiler\]', "${yellow}--- /Spoiler ---${reset}`n"

# Table rendering - parse tables and render with aligned columns
function Get-VisualLength([string]$s) {
    # Strip ANSI escape sequences and OSC 8 hyperlinks to get display width
    $stripped = [regex]::Replace($s, "${esc}\[[0-9;]*m", '')
    $stripped = [regex]::Replace($stripped, "${esc}\]8;;[^${esc}]*${esc}\\", '')
    # Count emoji/wide chars as 2 display columns each
    $len = 0
    for ($i = 0; $i -lt $stripped.Length; $i++) {
        $cp = [int][char]$stripped[$i]
        # Surrogate pairs (emoji above U+FFFF)
        if ($cp -ge 0xD800 -and $cp -le 0xDBFF -and ($i + 1) -lt $stripped.Length) {
            $len += 2
            $i++
        }
        # Zero-width characters
        elseif ($cp -ge 0xFE00 -and $cp -le 0xFE0F) { }  # variation selectors
        elseif ($cp -eq 0x200D) { }  # ZWJ
        elseif ($cp -eq 0x20E3) { }  # combining enclosing keycap
        # Wide emoji/symbol BMP ranges
        elseif ($cp -ge 0x2300 -and $cp -le 0x23FF) { $len += 2 }  # misc technical (⏰⌚⌛ etc)
        elseif ($cp -ge 0x25A0 -and $cp -le 0x25FF) { $len += 2 }  # geometric shapes
        elseif ($cp -ge 0x2600 -and $cp -le 0x27BF) { $len += 2 }  # misc symbols, dingbats
        elseif ($cp -ge 0x2900 -and $cp -le 0x297F) { $len += 2 }  # supplemental arrows
        elseif ($cp -ge 0x2B00 -and $cp -le 0x2BFF) { $len += 2 }  # misc symbols and arrows
        elseif ($cp -ge 0x3000 -and $cp -le 0x303F) { $len += 2 }  # CJK symbols
        elseif ($cp -ge 0x3040 -and $cp -le 0x9FFF) { $len += 2 }  # CJK unified
        elseif ($cp -ge 0xAC00 -and $cp -le 0xD7AF) { $len += 2 }  # Hangul
        elseif ($cp -ge 0xF900 -and $cp -le 0xFAFF) { $len += 2 }  # CJK compat
        else { $len += 1 }
    }
    $len
}

# Process tables from innermost to outermost (handles nesting)
function Render-Table([string]$tableHtml) {
    # Parse rows
    $rowMatches = [regex]::Matches($tableHtml, '\[tr\](.*?)\[/tr\]', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $rows = @()
    foreach ($rm in $rowMatches) {
        $cellMatches = [regex]::Matches($rm.Groups[1].Value, '\[td\](.*?)\[/td\]', [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $cells = @()
        foreach ($cm in $cellMatches) { $cells += $cm.Groups[1].Value.Trim() }
        if ($cells.Count -gt 0) { $rows += ,@($cells) }
    }
    if ($rows.Count -eq 0) { return '' }

    # Calculate column widths based on visible text length
    $colCount = ($rows | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum

    # Check if any cell has multi-line content
    $hasMultiLine = $false
    foreach ($row in $rows) {
        foreach ($cell in $row) {
            if ($cell -match "`n") { $hasMultiLine = $true; break }
        }
        if ($hasMultiLine) { break }
    }

    # Calculate minimum table width: borders + 4 chars per col minimum
    $minTableWidth = $colCount + 1 + ($colCount * 6)  # borders + min 4 chars + 2 padding per col
    # If terminal too narrow for bordered tables, render as plain content
    if ($termWidth -lt $minTableWidth) {
        $out = "`n"
        foreach ($row in $rows) {
            foreach ($cell in $row) {
                if ($cell.Trim()) { $out += $cell.Trim() + "`n" }
            }
            $out += "`n"
        }
        return $out
    }

    if ($hasMultiLine) {
        # Multi-line table: render cells side by side with borders
        # Calculate column widths from the longest visible line in each column
        $colWidths = @()
        for ($c = 0; $c -lt $colCount; $c++) {
            $maxW = 0
            foreach ($row in $rows) {
                if ($c -lt $row.Count) {
                    $cellLines = $row[$c] -split "`n"
                    foreach ($cl in $cellLines) {
                        $vl = Get-VisualLength $cl
                        if ($vl -gt $maxW) { $maxW = $vl }
                    }
                }
            }
            $colWidths += [Math]::Max($maxW, 2)
        }

        # Check if table fits terminal; if not, stack cells vertically without borders
        $totalWidth = $colCount + 1  # borders
        foreach ($w in $colWidths) { $totalWidth += $w + 2 }  # cell padding
        if ($totalWidth -gt $termWidth) {
            $out = "`n"
            foreach ($row in $rows) {
                foreach ($cell in $row) {
                    if ($cell.Trim()) { $out += $cell.Trim() + "`n" }
                }
                $out += "`n"
            }
            return $out
        }

        $border = $dimGray + '+' + (($colWidths | ForEach-Object { '-' * ($_ + 2) }) -join '+') + '+' + $reset
        $outLines = @($border)

        foreach ($row in $rows) {
            # Split each cell into lines and pad to same height
            $cellLineArrays = @()
            $maxHeight = 0
            for ($c = 0; $c -lt $colCount; $c++) {
                $cell = if ($c -lt $row.Count) { $row[$c] } else { '' }
                $cLines = @($cell -split "`n")
                if ($cLines.Count -gt $maxHeight) { $maxHeight = $cLines.Count }
                $cellLineArrays += ,@($cLines)
            }

            # Render line by line
            for ($ln = 0; $ln -lt $maxHeight; $ln++) {
                $parts = @()
                for ($c = 0; $c -lt $colCount; $c++) {
                    $lineText = if ($ln -lt $cellLineArrays[$c].Count) { $cellLineArrays[$c][$ln] } else { '' }
                    $vl = Get-VisualLength $lineText
                    $pad = $colWidths[$c] - $vl
                    if ($pad -lt 0) { $pad = 0 }
                    $parts += ' ' + $lineText + (' ' * ($pad + 1))
                }
                $outLines += $dimGray + '|' + $reset + ($parts -join ($dimGray + '|' + $reset)) + $dimGray + '|' + $reset
            }
            $outLines += $border
        }
        return "`n" + ($outLines -join "`n") + "`n"
    }

    # Single-line table: simple bordered rendering
    # Calculate natural column widths
    $colWidths = @()
    for ($c = 0; $c -lt $colCount; $c++) {
        $maxW = 0
        foreach ($row in $rows) {
            if ($c -lt $row.Count) {
                $vl = Get-VisualLength $row[$c]
                if ($vl -gt $maxW) { $maxW = $vl }
            }
        }
        $colWidths += $maxW
    }
    # Cap first column to fit terminal width
    # Reserve 16 chars for potential outer table nesting (poster col + borders + padding)
    $availWidth = $termWidth - 16
    $overhead = $colCount + 1 + ($colCount * 2)  # borders + cell padding
    $otherColsWidth = 0
    for ($c = 1; $c -lt $colCount; $c++) { $otherColsWidth += $colWidths[$c] }
    $maxFirstCol = $availWidth - $overhead - $otherColsWidth
    if ($maxFirstCol -lt 20) { $maxFirstCol = 20 }
    $colWidths[0] = [Math]::Min($colWidths[0], $maxFirstCol)

    $border = $dimGray + '+' + (($colWidths | ForEach-Object { '-' * ($_ + 2) }) -join '+') + '+' + $reset
    $lines = @($border)
    $isFirst = $true
    foreach ($row in $rows) {
        $parts = @()
        for ($c = 0; $c -lt $colCount; $c++) {
            $cell = if ($c -lt $row.Count) { $row[$c] } else { '' }
            $vl = Get-VisualLength $cell
            # Truncate cell content if it exceeds column width
            if ($vl -gt $colWidths[$c]) {
                $cell = $cell.Substring(0, [Math]::Min($cell.Length, $colWidths[$c] - 3)) + '...'
                $vl = Get-VisualLength $cell
            }
            $pad = $colWidths[$c] - $vl
            if ($pad -lt 0) { $pad = 0 }
            $parts += ' ' + $cell + (' ' * ($pad + 1))
        }
        $lines += $dimGray + '|' + $reset + ($parts -join ($dimGray + '|' + $reset)) + $dimGray + '|' + $reset
        if ($isFirst) {
            $lines += $border
            $isFirst = $false
        }
    }
    $lines += $border
    "`n" + ($lines -join "`n") + "`n"
}

# Render banner sixel at the top of text (native resolution, no resize — terminal clips to fit)
if ($magickExe -and $bannerUrls.Count -gt 0) {
    $tmpBanner = Join-Path $env:TEMP "bbcode_banner.jpg"
    try {
        Invoke-WebRequest -Uri $bannerUrls[0] -OutFile $tmpBanner -ErrorAction Stop
        $sixelData = & $magickExe $tmpBanner -resize "${termPixelWidth}x" sixel:- 2>$null
        if ($sixelData) {
            $text = ($sixelData -join "`n") + "`n" + $text
        }
    } catch { }
    finally { Remove-Item $tmpBanner -Force -ErrorAction SilentlyContinue }
}

# Render poster sixel before table (removed from table cell to avoid breaking layout)
if ($magickExe -and $posterUrls.Count -gt 0) {
    $posterSixel = ''
    foreach ($pUrl in $posterUrls) {
        $tmpPoster = Join-Path $env:TEMP "bbcode_poster_preview.jpg"
        try {
            Invoke-WebRequest -Uri $pUrl -OutFile $tmpPoster -ErrorAction Stop
            $sixelData = & $magickExe $tmpPoster -geometry 150x sixel:- 2>$null
            if ($sixelData) { $posterSixel += ($sixelData -join "`n") + "`n" }
        } catch { }
        finally { Remove-Item $tmpPoster -Force -ErrorAction SilentlyContinue }
    }
    if ($posterSixel) {
        if ($text -match '\[table\]') {
            $tableIdx = $text.IndexOf('[table]')
            $text = $text.Substring(0, $tableIdx) + $posterSixel + $text.Substring($tableIdx)
        } else {
            $text += "`n" + $posterSixel
        }
    }
}

# Repeatedly process innermost tables (those without nested [table]) until none remain
$safety = 0
while ($text -match '\[table\]' -and $safety -lt 10) {
    $text = [regex]::Replace($text, '\[table\]((?:(?!\[table\]).)*?)\[/table\]', {
        param($m)
        Render-Table $m.Groups[1].Value
    }, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $safety++
}

# Quote
$text = [regex]::Replace($text, '\[quote=([^\]]+)\]', {
    param($m)
    "`n${dimGray}--- Quote: $($m.Groups[1].Value) ---${reset}`n${dimGray}"
})
$text = $text -replace '\[quote\]', "`n${dimGray}--- Quote ---${reset}`n${dimGray}"
$text = $text -replace '\[/quote\]', "${reset}`n${dimGray}--- /Quote ---${reset}`n"

# Code — dim content with indentation
$text = [regex]::Replace($text, '\[code\](.*?)\[/code\]', {
    param($m)
    $codeBody = $m.Groups[1].Value.Trim("`n").Trim("`r")
    $indented = ($codeBody -split "`n" | ForEach-Object { "  ${dimGray}$_${reset}" }) -join "`n"
    "`n$indented`n"
}, [System.Text.RegularExpressions.RegexOptions]::Singleline)

# Lists — bullet points with indentation
$text = [regex]::Replace($text, '\[list(?:=(\d+))?\](.*?)\[/list\]', {
    param($m)
    $ordered = $m.Groups[1].Value
    $body = $m.Groups[2].Value
    $items = [regex]::Matches($body, '\[\*\](.*?)(?=\[\*\]|\z)', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $idx = 0
    $lines = @()
    foreach ($item in $items) {
        $idx++
        $content = $item.Groups[1].Value.Trim()
        if ($ordered) {
            $lines += "  ${yellow}${idx}.${reset} $content"
        } else {
            $lines += "  ${yellow}*${reset} $content"
        }
    }
    "`n" + ($lines -join "`n") + "`n"
}, [System.Text.RegularExpressions.RegexOptions]::Singleline)

# Mediainfo block
$text = $text -replace '\[mediainfo\]', "`n${cyan}--- MediaInfo ---${reset}`n"
$text = $text -replace '\[/mediainfo\]', "${cyan}--- /MediaInfo ---${reset}`n"

# Clean up excessive blank lines (more than 2 consecutive)
$text = [regex]::Replace($text, '(\r?\n){4,}', "`n`n`n")

# Render screenshot sixel — merge side by side, insert above all screenshot links
if ($magickExe -and $screenUrls.Count -gt 0) {
    $tmpFiles = @()
    try {
        foreach ($sUrl in $screenUrls) {
            $tmpFile = Join-Path $env:TEMP "bbcode_screen_$($tmpFiles.Count).jpg"
            Invoke-WebRequest -Uri $sUrl -OutFile $tmpFile -ErrorAction Stop
            $tmpFiles += $tmpFile
        }
        $sixelData = & $magickExe @tmpFiles -resize x200 +append -resize "${termPixelWidth}x>" sixel:- 2>$null
        if ($sixelData) {
            $screenSixel = ($sixelData -join "`n") + "`n"
            # Find the first screenshot link line and insert sixel above all of them
            $lines = $text -split "`n"
            $firstScreenIdx = -1
            foreach ($sUrl in $screenUrls) {
                $escaped = [regex]::Escape($sUrl)
                for ($li = 0; $li -lt $lines.Count; $li++) {
                    if ($lines[$li] -match $escaped) {
                        if ($firstScreenIdx -lt 0 -or $li -lt $firstScreenIdx) { $firstScreenIdx = $li }
                        break
                    }
                }
            }
            if ($firstScreenIdx -ge 0) {
                $before = ($lines[0..($firstScreenIdx - 1)] -join "`n")
                $after = ($lines[$firstScreenIdx..($lines.Count - 1)] -join "`n")
                $text = $before + "`n" + $screenSixel + $after
            } else {
                $text += "`n" + $screenSixel
            }
        }
    } catch { }
    finally {
        foreach ($f in $tmpFiles) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }
}

# Output
Write-Host $text

# Exit code 2 = ImageMagick available (caller can offer image rendering)
# Exit code 0 = no ImageMagick or already rendered with images
if (-not $images) {
    $hasIM = (Get-Command magick -ErrorAction SilentlyContinue) -or
             (Get-ChildItem 'C:\Program Files\ImageMagick-*\magick.exe' -ErrorAction SilentlyContinue)
    if ($hasIM) { exit 2 }
}
exit 0
