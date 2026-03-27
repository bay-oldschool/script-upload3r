#!/usr/bin/env pwsh
<#
.SYNOPSIS
    List the last N uploads by the current user from a UNIT3D tracker.
.PARAMETER count
    Number of uploads to show (default: 10).
.PARAMETER configfile
    Path to JSONC config file (default: ./config.jsonc).
#>
param(
    [Parameter(Position = 0)]
    [int]$count = 10,

    [Parameter(Position = 1)]
    [string]$configfile
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSScriptRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $MyInvocation.MyCommand.Definition)

if (-not $configfile) { $configfile = Join-Path $PSScriptRoot "config.jsonc" }

if (-not (Test-Path -LiteralPath $configfile)) {
    Write-Host "Error: config file '$configfile' not found." -ForegroundColor Red
    exit 1
}

$config     = (Get-Content -LiteralPath $configfile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json
$ApiKey     = $config.api_key
$TrackerUrl = $config.tracker_url
$Username   = $config.username

if (-not $ApiKey) {
    Write-Host "Error: 'api_key' not configured." -ForegroundColor Red
    exit 1
}

if (-not $Username) {
    Write-Host "Error: 'username' not configured." -ForegroundColor Red
    exit 1
}

Write-Host "Fetching last $count uploads by '$Username'..." -ForegroundColor Cyan

$apiUrl = "${TrackerUrl}/api/torrents/filter?api_token=${ApiKey}&uploader=${Username}&perPage=${count}&sortField=created_at&sortDirection=desc"
$response = & curl.exe -s -w "`n%{http_code}" $apiUrl
$lines = $response -split "`n"
$httpCode = $lines[-1].Trim()
$body = ($lines[0..($lines.Count - 2)]) -join "`n"

if ($httpCode -ne '200') {
    Write-Host "Error: API returned HTTP $httpCode" -ForegroundColor Red
    if ($body.Length -gt 0) {
        Write-Host ($body.Substring(0, [Math]::Min($body.Length, 500)))
    }
    exit 1
}

$data = $body | ConvertFrom-Json

$torrents = @()
if ($data.data) {
    $torrents = $data.data
} elseif ($data -is [array]) {
    $torrents = $data
}

if ($torrents.Count -eq 0) {
    Write-Host "No uploads found." -ForegroundColor Yellow
    exit 0
}

function Format-Size([long]$bytes) {
    if ($bytes -ge 1073741824) { return "{0:N2} GB" -f ($bytes / 1073741824) }
    if ($bytes -ge 1048576)    { return "{0:N2} MB" -f ($bytes / 1048576) }
    if ($bytes -ge 1024)       { return "{0:N2} KB" -f ($bytes / 1024) }
    return "$bytes B"
}

# Load icons from external UTF-8 file
$iconsFile = Join-Path $PSScriptRoot "shared\icons.jsonc"
$icons = ([System.IO.File]::ReadAllText($iconsFile, [System.Text.Encoding]::UTF8) -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json

$esc = [char]27

# Visual width: emoji/surrogates = 2 cols, flag pairs = 2 cols, variation selectors/ZWJ = 0
function IsRegionalIndicator([string]$s, [int]$i) {
    if (($i + 1) -lt $s.Length -and [int][char]$s[$i] -eq 0xD83C) {
        $lo = [int][char]$s[$i + 1]
        return ($lo -ge 0xDDE6 -and $lo -le 0xDDFF)
    }
    return $false
}

function Get-VLen([string]$s) {
    $len = 0
    for ($i = 0; $i -lt $s.Length; $i++) {
        $cp = [int][char]$s[$i]
        if ((IsRegionalIndicator $s $i) -and ($i + 3) -lt $s.Length -and (IsRegionalIndicator $s ($i + 2))) {
            $len += 2; $i += 3; continue
        }
        if ($cp -ge 0xD800 -and $cp -le 0xDBFF -and ($i + 1) -lt $s.Length) { $len += 2; $i++ }
        elseif ($cp -ge 0xFE00 -and $cp -le 0xFE0F) { }
        elseif ($cp -eq 0x200D) { }
        elseif ($cp -ge 0x2300 -and $cp -le 0x23FF) { $len += 2 }
        elseif ($cp -ge 0x25A0 -and $cp -le 0x25FF) { $len += 2 }
        elseif ($cp -ge 0x2600 -and $cp -le 0x27BF) { $len += 2 }
        elseif ($cp -ge 0x2B00 -and $cp -le 0x2BFF) { $len += 2 }
        else { $len += 1 }
    }
    $len
}

function Truncate-Name([string]$s, [int]$maxVis) {
    $vl = Get-VLen $s
    if ($vl -le $maxVis) { return $s }
    $target = $maxVis - 3
    $len = 0; $cut = 0
    for ($i = 0; $i -lt $s.Length; $i++) {
        $cp = [int][char]$s[$i]
        if ((IsRegionalIndicator $s $i) -and ($i + 3) -lt $s.Length -and (IsRegionalIndicator $s ($i + 2))) {
            $w = 2; $skip = 3
        } elseif ($cp -ge 0xD800 -and $cp -le 0xDBFF -and ($i + 1) -lt $s.Length) { $w = 2; $skip = 1 }
        elseif ($cp -ge 0xFE00 -and $cp -le 0xFE0F) { $w = 0; $skip = 0 }
        elseif ($cp -eq 0x200D) { $w = 0; $skip = 0 }
        elseif ($cp -ge 0x2300 -and $cp -le 0x23FF) { $w = 2; $skip = 0 }
        elseif ($cp -ge 0x25A0 -and $cp -le 0x25FF) { $w = 2; $skip = 0 }
        elseif ($cp -ge 0x2600 -and $cp -le 0x27BF) { $w = 2; $skip = 0 }
        elseif ($cp -ge 0x2B00 -and $cp -le 0x2BFF) { $w = 2; $skip = 0 }
        else { $w = 1; $skip = 0 }
        if (($len + $w) -gt $target) { $cut = $i; break }
        $len += $w; $i += $skip; $cut = $i + 1
    }
    $s.Substring(0, $cut) + '...'
}

# Calculate NAME column width from terminal width
# Fixed cols: ID(6) + sp(1) + NAME + sp(1) + CATEGORY(12) + sp(1) + SIZE(10) + sp(1) + DATE(10) + sp(1) + PER(4) = 47
$tw = 120
try { $tw = [Console]::WindowWidth } catch { }
if (-not $tw -or $tw -lt 60) { try { $tw = $Host.UI.RawUI.WindowSize.Width } catch { } }
if (-not $tw -or $tw -lt 60) { $tw = 120 }
$nameW = $tw - 47
if ($nameW -lt 20) { $nameW = 20 }
$nameDash = '-' * $nameW

Write-Host ""
Write-Host ("{0,-6} {1,-$nameW} {2,-12} {3,-10} {4,-10} {5}" -f "ID", "NAME", "CATEGORY", "SIZE", "DATE", "PER") -ForegroundColor DarkGray
Write-Host ("{0,-6} {1,-$nameW} {2,-12} {3,-10} {4,-10} {5}" -f "------", $nameDash, "------------", "----------", "----------", "----") -ForegroundColor DarkGray

foreach ($t in $torrents) {
    $attrs = if ($t.attributes) { $t.attributes } else { $t }
    $id       = if ($attrs.id) { $attrs.id } else { $t.id }
    $name     = Truncate-Name $attrs.name $nameW
    $category = $attrs.category
    $created  = $attrs.created_at
    $size     = if ($attrs.size) { Format-Size ([long]$attrs.size) } else { '' }
    $personal = if ($attrs.personal_release -eq $true -or $attrs.personal_release -eq 1) { $icons.personal_yes } else { $icons.personal_no }
    if ($created -and $created.Length -ge 10) { $created = $created.Substring(0, 10) }
    if (-not $category) { $category = '' }
    if ($category.Length -gt 12) { $category = $category.Substring(0, 12) }
    # Pad name manually using visual width
    $vl = Get-VLen $name
    $namePad = $name + (' ' * ($nameW - $vl))
    $idPad  = ("{0,-6}" -f $id)
    $idCell = "${esc}]8;;${TrackerUrl}/torrents/${id}${esc}\${idPad}${esc}]8;;${esc}\"
    Write-Host ("${idCell} ${namePad} {0,-12} {1,-10} {2,-10} {3}" -f $category, $size, $created, $personal)
}

Write-Host ""
Write-Host "Total: $($torrents.Count) torrent(s)" -ForegroundColor Cyan
Write-Host ""
Write-Host "All uploads: " -NoNewline
Write-Host "${TrackerUrl}/users/${Username}/uploads" -ForegroundColor Blue
