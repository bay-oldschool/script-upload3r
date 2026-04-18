#!/usr/bin/env pwsh
<#
.SYNOPSIS
    List the last N uploads by the current user from a UNIT3D tracker via web scraping.
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
$TrackerUrl = if ($config.tracker_url) { ([string]$config.tracker_url).TrimEnd('/') } else { '' }
$Username   = $config.username
$Password   = $config.password
$TwoFactorSecret = if ($config.two_factor_secret) { $config.two_factor_secret } else { '' }

if (-not $Username -or -not $Password) {
    Write-Host "Error: 'username' and 'password' must be set in config for web login." -ForegroundColor Red
    exit 1
}

. (Join-Path (Join-Path $RootDir 'shared') 'web_login.ps1')

$OutDir = Join-Path $RootDir 'output'

try {
    $cookieJar = Get-CachedCookieJar -TrackerUrl $TrackerUrl -Username $Username `
        -Password $Password -TwoFactorSecret $TwoFactorSecret -OutputDir $OutDir
    if (-not $cookieJar) {
        Write-Host "Login failed. Check credentials and two_factor_secret in config.jsonc." -ForegroundColor Red
        Write-Host "Press any key to continue ..." -ForegroundColor Yellow
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        exit 1
    }

    function HtmlDecode($s) {
        $s -replace '<[^>]+>', '' -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>' -replace '&#039;', "'" -replace '&quot;', '"' -replace '&nbsp;', ' '
    }

    function ParsePage($pageHtml, [hashtable]$seen) {
        $rowMatches = [regex]::Matches($pageHtml, '<tr[^>]*>.*?</tr>', ([System.Text.RegularExpressions.RegexOptions]::Singleline))
        $results = @()
        foreach ($row in $rowMatches) {
            $html = $row.Value
            if ($html -notmatch 'href="[^"]*?/torrents/(\d+)"') { continue }
            $id = $matches[1]
            if ($seen.ContainsKey($id)) { continue }
            $seen[$id] = $true

            $name = ''
            if ($html -match '<a[^>]*href="[^"]*?/torrents/' + $id + '"[^>]*>\s*(.*?)\s*</a>') {
                $name = (HtmlDecode $matches[1]).Trim()
            }
            if (-not $name) { continue }

            $date = ''
            if ($html -match '<time[^>]*datetime="([^"]+)"') {
                $dt = $matches[1]
                if ($dt.Length -ge 10) { $date = $dt.Substring(0, 10) }
            }

            $size = ''
            if ($html -match 'user-uploads__size[^>]*>\s*([\d.]+\s*(?:TiB|GiB|MiB|KiB|B))\s*<') {
                $size = $matches[1]
            }

            $isPersonal = $false
            $perMatch = [regex]::Match($html, 'user-uploads__personal-release[\s\S]*?title="([^"]+)"')
            if ($perMatch.Success) {
                $isPersonal = ($perMatch.Groups[1].Value -eq 'Personal release')
            }

            $approvedStatus = 'unknown'
            $statusMatch = [regex]::Match($html, 'user-uploads__status[\s\S]*?title="([^"]+)"')
            if ($statusMatch.Success) {
                $statusTitle = $statusMatch.Groups[1].Value.Trim()
                $approvedStatus = switch -Wildcard ($statusTitle) {
                    'Approved'  { 'approved' }
                    'Pending'   { 'pending' }
                    'Rejected'  { 'rejected' }
                    'Postponed' { 'postponed' }
                    default     { 'unknown' }
                }
            }

            $results += @{ id = $id; name = $name; date = $date; size = $size; isPersonal = $isPersonal; approvedStatus = $approvedStatus }
        }
        $results
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
    # Fixed cols: ID(6) + sp(1) + NAME + sp(1) + SIZE(10) + sp(1) + DATE(10) + sp(1) + PR(2) + 2sp + AP(2) + 2sp + ED(2) + 2sp + DL(2) + 2sp + SB(2) = 48
    $tw = 120
    try { $tw = [Console]::WindowWidth } catch { }
    if (-not $tw -or $tw -lt 60) { try { $tw = $Host.UI.RawUI.WindowSize.Width } catch { } }
    if (-not $tw -or $tw -lt 60) { $tw = 120 }
    $nameW = $tw - 48
    if ($nameW -lt 20) { $nameW = 20 }
    $nameDash = '-' * $nameW

    $cmdDir = Join-Path ([System.IO.Path]::GetTempPath()) "upload3r_actions"

    $hasOsc8 = $false
    if (Get-Process WindowsTerminal -ErrorAction SilentlyContinue) { $hasOsc8 = $true }
    if ($env:WT_SESSION) { $hasOsc8 = $true }
    if ($env:TERM_PROGRAM -match 'vscode|iTerm') { $hasOsc8 = $true }

    function Show-TorrentRows($list) {
        # Create/refresh temp .cmd wrappers
        if (Test-Path $cmdDir) { Remove-Item -LiteralPath $cmdDir -Recurse -Force }
        New-Item -ItemType Directory -Path $cmdDir -Force | Out-Null
        foreach ($t in $list) {
            $tid = $t.id
            foreach ($act in @('edit','delete','subtitle')) {
                $cmdFile = Join-Path $cmdDir "${act}_${tid}.cmd"
                $line = "@powershell -ExecutionPolicy Bypass -File `"$RootDir\ps\${act}.ps1`" $tid -configfile `"$configfile`""
                [System.IO.File]::WriteAllText($cmdFile, "${line}`r`npause`r`n", [System.Text.Encoding]::ASCII)
            }
        }

        Write-Host ""
        Write-Host ("{0,-6} {1,-$nameW} {2,-10} {3,-10} {4}  {5}  {6}  {7}  {8}" -f "ID", "NAME", "SIZE", "DATE", "PR", "AP", "ED", "DL", "SB") -ForegroundColor DarkGray
        Write-Host ("{0,-6} {1,-$nameW} {2,-10} {3,-10} {4}  {5}  {6}  {7}  {8}" -f "------", $nameDash, "----------", "----------", "--", "--", "--", "--", "--") -ForegroundColor DarkGray

        foreach ($t in $list) {
            $id   = $t.id
            $name = Truncate-Name $t.name $nameW
            $size = $t.size
            $date = $t.date
            $per  = if ($t.isPersonal) { $icons.personal_yes } else { $icons.personal_no }
            $appr = switch ($t.approvedStatus) {
                'approved'  { $icons.approved }
                'pending'   { $icons.pending }
                'rejected'  { $icons.rejected }
                'postponed' { $icons.postponed }
                default     { '' }
            }
            $vl = Get-VLen $name
            $namePad = $name + (' ' * ($nameW - $vl))
            $idPad  = ("{0,-6}" -f $id)
            $idCell = "${esc}]8;;${TrackerUrl}/torrents/${id}${esc}\${idPad}${esc}]8;;${esc}\"
            $editCmd   = "file:///" + ((Join-Path $cmdDir "edit_${id}.cmd") -replace '\\', '/')
            $delCmd    = "file:///" + ((Join-Path $cmdDir "delete_${id}.cmd") -replace '\\', '/')
            $subCmd    = "file:///" + ((Join-Path $cmdDir "subtitle_${id}.cmd") -replace '\\', '/')
            $editIcon  = "${esc}]8;;${editCmd}${esc}\$($icons.edit)${esc}]8;;${esc}\"
            $delIcon   = "${esc}]8;;${delCmd}${esc}\$($icons.delete)${esc}]8;;${esc}\"
            $subIcon   = "${esc}]8;;${subCmd}${esc}\$($icons.subtitle)${esc}]8;;${esc}\"
            Write-Host ("${idCell} ${namePad} {0,-10} {1,-10} {2}  {3}  ${editIcon}  ${delIcon}  ${subIcon}" -f $size, $date, $per, $appr)
        }

        Write-Host ""
        Write-Host "Total: $($list.Count) torrent(s)" -ForegroundColor Cyan
    }

    # Pagination loop — fetch page by page, show "load more" / "back"
    $uploadsUrl = "${TrackerUrl}/users/${Username}/uploads"
    $page = 1
    $allTorrents = @()
    $seen = @{}
    $hasMore = $true

    while ($true) {
        Write-Host "Fetching page $page..." -ForegroundColor Cyan
        $pageUrl = "${uploadsUrl}?page=${page}"
        $uploadsPage = (& curl.exe -s -b $cookieJar --max-time 30 $pageUrl) -join "`n"

        $pageTorrents = @(ParsePage $uploadsPage $seen)
        if ($pageTorrents.Count -eq 0) {
            $hasMore = $false
            if ($allTorrents.Count -eq 0) {
                Write-Host "No uploads found." -ForegroundColor Yellow
                break
            }
            Write-Host "No more uploads." -ForegroundColor Yellow
        } else {
            $allTorrents += $pageTorrents
        }

        Show-TorrentRows $allTorrents

        Write-Host ""
        Write-Host "All uploads: " -NoNewline
        Write-Host $uploadsUrl -ForegroundColor Blue
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

} finally {
    if ($cookieJar) { Remove-Item -LiteralPath $cookieJar -ErrorAction SilentlyContinue }
}
