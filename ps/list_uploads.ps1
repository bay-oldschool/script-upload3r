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
$RootDir = Split-Path -Parent -Path (Split-Path -Parent -Path $MyInvocation.MyCommand.Definition)

if (-not $configfile) { $configfile = Join-Path $RootDir "config.jsonc" }

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

$perPage = 25

function Fetch-Page([int]$pageNum) {
    $apiUrl = "${TrackerUrl}/api/torrents/filter?api_token=${ApiKey}&uploader=${Username}&perPage=${perPage}&page=${pageNum}&sortField=created_at&sortDirection=desc"
    $response = & curl.exe -s -w "`n%{http_code}" $apiUrl
    $lines = $response -split "`n"
    $httpCode = $lines[-1].Trim()
    $body = ($lines[0..($lines.Count - 2)]) -join "`n"

    if ($httpCode -ne '200') {
        Write-Host "Error: API returned HTTP $httpCode" -ForegroundColor Red
        if ($body.Length -gt 0) {
            Write-Host ($body.Substring(0, [Math]::Min($body.Length, 500)))
        }
        return @()
    }

    $data = $body | ConvertFrom-Json
    $results = @()
    if ($data.data) { $results = $data.data }
    elseif ($data -is [array]) { $results = $data }
    $results
}

function Format-Size([long]$bytes) {
    if ($bytes -ge 1073741824) { return "{0:N2} GB" -f ($bytes / 1073741824) }
    if ($bytes -ge 1048576)    { return "{0:N2} MB" -f ($bytes / 1048576) }
    if ($bytes -ge 1024)       { return "{0:N2} KB" -f ($bytes / 1024) }
    return "$bytes B"
}

# Load icons from external UTF-8 file
$iconsFile = Join-Path $RootDir "shared\icons.jsonc"
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
# Fixed cols: ID(6) + sp(1) + NAME + sp(1) + CATEGORY(12) + sp(1) + SIZE(10) + sp(1) + DATE(10) + sp(1) + PR(2) + 2sp + EDT(2) + 2sp + DEL(2) + 2sp + SUB(2) = 57
$tw = 120
try { $tw = [Console]::WindowWidth } catch { }
if (-not $tw -or $tw -lt 60) { try { $tw = $Host.UI.RawUI.WindowSize.Width } catch { } }
if (-not $tw -or $tw -lt 60) { $tw = 120 }
$nameW = $tw - 57
if ($nameW -lt 20) { $nameW = 20 }
$nameDash = '-' * $nameW

$cmdDir = Join-Path ([System.IO.Path]::GetTempPath()) "upload3r_actions"

$hasOsc8 = $false
if (Get-Process WindowsTerminal -ErrorAction SilentlyContinue) { $hasOsc8 = $true }
if ($env:WT_SESSION) { $hasOsc8 = $true }
if ($env:TERM_PROGRAM -match 'vscode|iTerm') { $hasOsc8 = $true }

function Show-TorrentRows($list) {
    if (Test-Path $cmdDir) { Remove-Item -LiteralPath $cmdDir -Recurse -Force }
    New-Item -ItemType Directory -Path $cmdDir -Force | Out-Null
    foreach ($t in $list) {
        $attrs = if ($t.attributes) { $t.attributes } else { $t }
        $tid   = if ($attrs.id) { $attrs.id } else { $t.id }
        foreach ($act in @('edit','delete','subtitle')) {
            $cmdFile = Join-Path $cmdDir "${act}_${tid}.cmd"
            $line = "@powershell -ExecutionPolicy Bypass -File `"$RootDir\ps\${act}.ps1`" $tid -configfile `"$configfile`""
            [System.IO.File]::WriteAllText($cmdFile, "${line}`r`npause`r`n", [System.Text.Encoding]::ASCII)
        }
    }

    Write-Host ""
    Write-Host ("{0,-6} {1,-$nameW} {2,-12} {3,-10} {4,-10} {5}  {6}  {7}  {8}" -f "ID", "NAME", "CATEGORY", "SIZE", "DATE", "PR", "ED", "DL", "SB") -ForegroundColor DarkGray
    Write-Host ("{0,-6} {1,-$nameW} {2,-12} {3,-10} {4,-10} {5}  {6}  {7}  {8}" -f "------", $nameDash, "------------", "----------", "----------", "--", "--", "--", "--") -ForegroundColor DarkGray

    foreach ($t in $list) {
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
        $vl = Get-VLen $name
        $namePad = $name + (' ' * ($nameW - $vl))
        $idPad  = ("{0,-6}" -f $id)
        $idCell  = "${esc}]8;;${TrackerUrl}/torrents/${id}${esc}\${idPad}${esc}]8;;${esc}\"
        $editCmd   = "file:///" + ((Join-Path $cmdDir "edit_${id}.cmd") -replace '\\', '/')
        $delCmd    = "file:///" + ((Join-Path $cmdDir "delete_${id}.cmd") -replace '\\', '/')
        $subCmd    = "file:///" + ((Join-Path $cmdDir "subtitle_${id}.cmd") -replace '\\', '/')
        $editIcon  = "${esc}]8;;${editCmd}${esc}\$($icons.edit)${esc}]8;;${esc}\"
        $delIcon   = "${esc}]8;;${delCmd}${esc}\$($icons.delete)${esc}]8;;${esc}\"
        $subIcon   = "${esc}]8;;${subCmd}${esc}\$($icons.subtitle)${esc}]8;;${esc}\"
        Write-Host ("${idCell} ${namePad} {0,-12} {1,-10} {2,-10} {3}  ${editIcon}  ${delIcon}  ${subIcon}" -f $category, $size, $created, $personal)
    }

    Write-Host ""
    Write-Host "Total: $($list.Count) torrent(s)" -ForegroundColor Cyan
}

# Pagination loop
$page = 1
$allTorrents = @()
$hasMore = $true

while ($true) {
    Write-Host "Fetching page $page..." -ForegroundColor Cyan
    $pageTorrents = @(Fetch-Page $page)
    if ($pageTorrents.Count -eq 0) {
        $hasMore = $false
        if ($allTorrents.Count -eq 0) {
            Write-Host "No uploads found." -ForegroundColor Yellow
            break
        }
        Write-Host "No more uploads." -ForegroundColor Yellow
    } else {
        $allTorrents += $pageTorrents
        if ($pageTorrents.Count -lt $perPage) { $hasMore = $false }
    }

    Show-TorrentRows $allTorrents

    Write-Host ""
    Write-Host "All uploads: " -NoNewline
    Write-Host "${TrackerUrl}/users/${Username}/uploads" -ForegroundColor Blue
    Write-Host ""

    if ($hasMore) {
        Write-Host "  1) Load more    0) Back" -ForegroundColor DarkGray
    } else {
        Write-Host "  0) Back" -ForegroundColor DarkGray
    }
    $key = [Console]::ReadKey($true).KeyChar
    if ($key -eq '0') { break }
    if ($key -eq '1' -and $hasMore) {
        $page++
        continue
    }
}
