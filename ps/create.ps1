#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Creates a .torrent file using mktorrent.ps1.
.PARAMETER directory
    The content directory to create the torrent from.
.PARAMETER configfile
    Path to the JSON config file.
.PARAMETER dht
    Switch to enable DHT.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$directory,

    [Parameter(Position = 1)]
    [string]$configfile,

    [switch]$dht
)

$ErrorActionPreference = 'Stop'
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$directory = $directory.TrimEnd('"').TrimEnd('\')
if (-not $configfile) { $configfile = Join-Path "$PSScriptRoot/.." "config.jsonc" }

if (Test-Path -LiteralPath $directory -PathType Leaf) {
    $singleFile = $directory
    $directory = Split-Path -Parent $directory
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($singleFile)
} else {
    $singleFile = $null
    $baseName = Split-Path -Path $directory -Leaf
}

$OutDir = "$PSScriptRoot/../output"
New-Item -Path $OutDir -ItemType Directory -ErrorAction SilentlyContinue

$config = (Get-Content -Path $configfile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json
$AnnounceUrl = $config.announce_url
if (-not $AnnounceUrl) {
    Write-Host "Skipping: 'announce_url' not configured in $configfile" -ForegroundColor Yellow
    exit 0
}

$TorrentName = "${baseName}.torrent"
$OutputFile = Join-Path -Path $OutDir -ChildPath $TorrentName
$Private = if ($dht.IsPresent) { 0 } else { 1 }
$torrentPath = if ($singleFile) { $singleFile } else { $directory }

Write-Host "Creating torrent for '$torrentPath'..."
& "$PSScriptRoot/../shared/mktorrent.ps1" -path $torrentPath -announceurl $AnnounceUrl -outputfile $OutputFile -private $Private
