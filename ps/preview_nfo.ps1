#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Render an NFO file in the terminal using the same display style as UNIT3D.
.DESCRIPTION
    UNIT3D renders NFO/BDInfo blocks as a bordered monospace <pre><code> panel.
    This script mirrors that look in the console: a cyan-bordered panel header,
    then the raw NFO content printed verbatim in monospace.

    NFO files are traditionally encoded in CP437 (DOS) so that box-drawing and
    block characters render correctly. We read bytes and decode as CP437 by
    default; pass -utf8 to read the file as UTF-8 instead.
.PARAMETER file
    Path to the NFO file to preview.
.PARAMETER utf8
    Read the file as UTF-8 rather than CP437.
#>
param(
    [Parameter(Position = 0)]
    [string]$file,
    [switch]$utf8
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not $file -or -not (Test-Path -LiteralPath $file)) {
    Write-Host "Usage: preview_nfo.ps1 <file.nfo> [-utf8]" -ForegroundColor Red
    exit 1
}

$resolved = (Resolve-Path -LiteralPath $file).Path

# Read raw bytes, then decode. Forced UTF-8 via -utf8; otherwise auto-detect:
# try strict UTF-8 first, fall back to CP437 (classic DOS NFO) on any error.
$bytes = [System.IO.File]::ReadAllBytes($resolved)
$text = $null
if (-not $utf8) {
    try {
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $text = $strictUtf8.GetString($bytes)
    } catch {
        $text = $null
    }
}
if ($null -eq $text) {
    if ($utf8) {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    } else {
        try {
            $cp437 = [System.Text.Encoding]::GetEncoding(437)
        } catch {
            $cp437 = [System.Text.Encoding]::GetEncoding('IBM437')
        }
        $text = $cp437.GetString($bytes)
    }
}
# Strip BOM and normalize line endings
$text = $text.TrimStart([char]0xFEFF) -replace "`r`n", "`n" -replace "`r", "`n"

# Terminal width
$termWidth = 120
try { $termWidth = [Console]::WindowWidth } catch { }
if (-not $termWidth -or $termWidth -lt 40) {
    try { $termWidth = $Host.UI.RawUI.WindowSize.Width } catch { }
}
if (-not $termWidth -or $termWidth -lt 40) { $termWidth = 120 }
# Leave 1 column so the last cell doesn't wrap in legacy consoles
$panelWidth = [Math]::Max(20, $termWidth - 1)

# ANSI colors (match preview_bbcode.ps1 palette + UNIT3D panel look)
$esc    = [char]27
$reset  = "${esc}[0m"
$bold   = "${esc}[1m"
$cyan   = "${esc}[96m"
$dim    = "${esc}[90m"

foreach ($line in ($text -split "`n")) {
    Write-Host $line
}
