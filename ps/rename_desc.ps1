#!/usr/bin/env pwsh
# Rename *_description.txt files to *_description.bbcode in the output directory
$PSScriptRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $MyInvocation.MyCommand.Definition)
$outDir = Join-Path $PSScriptRoot "output"

$files = Get-ChildItem -Path $outDir -Recurse -Filter '*_description.txt' -ErrorAction SilentlyContinue
if (-not $files -or $files.Count -eq 0) {
    Write-Host "No _description.txt files found in output." -ForegroundColor Yellow
    exit 0
}
foreach ($f in $files) {
    $newName = $f.Name -replace '\.txt$', '.bbcode'
    Rename-Item -LiteralPath $f.FullName $newName
    Write-Host "  $($f.Name)  →  $newName"
}
Write-Host ""
Write-Host "Renamed $($files.Count) file(s)." -ForegroundColor Green
