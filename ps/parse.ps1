#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Extracts full MediaInfo from the main video file in a directory.
.PARAMETER directory
    Path to the content directory containing the video file.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$directory
)

$ErrorActionPreference = 'Stop'
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$directory = $directory.TrimEnd('"').Trim().TrimEnd('\')

if (Test-Path -LiteralPath $directory -PathType Leaf) {
    $singleFile = $directory
    $directory = Split-Path -Parent $directory
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($singleFile)
} else {
    $singleFile = $null
    $baseName = Split-Path -Path $directory -Leaf
}

$MediaInfoExe = "$PSScriptRoot/../tools/MediaInfo.exe"
$OutDir = "$PSScriptRoot/../output"

if (-not (Test-Path -Path $MediaInfoExe)) {
    Write-Host "Warning: MediaInfo.exe not found at '$MediaInfoExe'. Run install.bat to download it. Skipping." -ForegroundColor Yellow
    exit 0
}

if ($singleFile) {
    $VideoFile = Get-Item -LiteralPath $singleFile
} else {
    $videoExts = @('.mkv', '.mp4', '.avi', '.ts', '.wmv', '.wmv', '.flv', '.m4v', '.mov')
    $audioExts = @('.flac', '.mp3', '.ogg', '.opus', '.m4a', '.aac', '.wav', '.wma', '.ape', '.wv', '.alac')
    $mediaExts = $videoExts + $audioExts
    $VideoFile = Get-ChildItem -LiteralPath $directory -Recurse -File |
        Where-Object {
            $ext = $_.Extension.ToLower()
            if ($audioExts -contains $ext) { return $true }
            ($videoExts -contains $ext) -and ($_.FullName -notmatch 'sample|trailer|featurette')
        } |
        Sort-Object Name |
        Select-Object -First 1
}

if (-not $VideoFile) {
    Write-Host "Warning: no media file found in '$directory'. Skipping." -ForegroundColor Yellow
    exit 0
}

New-Item -Path $OutDir -ItemType Directory -ErrorAction SilentlyContinue
$OutputFile = Join-Path -Path $OutDir -ChildPath "${baseName}_mediainfo.txt"

Write-Host "Parsing: $($VideoFile.Name)"
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = (Resolve-Path $MediaInfoExe).Path
$psi.Arguments = "`"$($VideoFile.FullName)`""
$psi.RedirectStandardOutput = $true
$psi.UseShellExecute = $false
$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
$proc = [System.Diagnostics.Process]::Start($psi)
$miOutput = $proc.StandardOutput.ReadToEnd()
$proc.WaitForExit()
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutputFile, $miOutput, $utf8NoBom)

# Normalize audio Language field: missing or unknown/und/zxx -> English
$miLines = [System.IO.File]::ReadAllLines($OutputFile, [System.Text.Encoding]::UTF8)
$result = New-Object System.Collections.Generic.List[string]
$inAudio = $false
$hasLanguage = $false
$unknownLangRe = '^Language(\s+):\s*(unknown|und|undetermined|zxx|mul|mis|)\s*$'
for ($i = 0; $i -lt $miLines.Count; $i++) {
    $line = $miLines[$i]
    # Detect section headers (lines like "Audio", "Audio #2", "Video", "Text", etc.)
    # In MediaInfo output the blank line comes BEFORE the header, not after
    if ($line -match '^(Audio|Video|Text|Menu|General|Image|Other)\b' -and $i -gt 0 -and $miLines[$i - 1] -eq '') {
        # Before starting new section, patch previous audio block if needed
        if ($inAudio -and -not $hasLanguage) {
            # Insert "Language: English" before the blank line that ends the audio block
            $insertAt = $result.Count - 1
            while ($insertAt -ge 0 -and $result[$insertAt] -eq '') { $insertAt-- }
            $result.Insert($insertAt + 1, 'Language                                 : English')
        }
        $inAudio = $line -match '^Audio'
        $hasLanguage = $false
    }
    if ($inAudio -and $line -match '^Language\s+:') {
        if ($line -imatch $unknownLangRe) {
            # Overwrite placeholder/unknown language with English, preserving column alignment
            $line = ($line -replace ':.*$', ': English')
        }
        $hasLanguage = $true
    }
    $result.Add($line)
}
# Patch last audio block if it was the final section
if ($inAudio -and -not $hasLanguage) {
    $insertAt = $result.Count - 1
    while ($insertAt -ge 0 -and $result[$insertAt] -eq '') { $insertAt-- }
    $result.Insert($insertAt + 1, 'Language                                 : English')
}
[System.IO.File]::WriteAllLines($OutputFile, $result.ToArray(), $utf8NoBom)

Write-Host "Saved to: $OutputFile" -ForegroundColor Green