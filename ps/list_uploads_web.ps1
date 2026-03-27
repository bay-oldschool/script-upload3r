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
$PSScriptRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $MyInvocation.MyCommand.Definition)

if (-not $configfile) { $configfile = Join-Path $PSScriptRoot "config.jsonc" }

if (-not (Test-Path -LiteralPath $configfile)) {
    Write-Host "Error: config file '$configfile' not found." -ForegroundColor Red
    exit 1
}

$config     = (Get-Content -LiteralPath $configfile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json
$TrackerUrl = $config.tracker_url
$Username   = $config.username
$Password   = $config.password

if (-not $Username -or -not $Password) {
    Write-Host "Error: 'username' and 'password' must be set in config for web login." -ForegroundColor Red
    exit 1
}

Write-Host "Logging in to ${TrackerUrl}..." -ForegroundColor Cyan

$cookieJar = [System.IO.Path]::GetTempFileName()

try {
    # Step 1: Get login page for CSRF token
    $loginPage = (& curl.exe -s -c $cookieJar -b $cookieJar "${TrackerUrl}/login") -join "`n"

    $csrfToken = ''
    if ($loginPage -match 'name="_token"\s*value="([^"]+)"') { $csrfToken = $matches[1] }
    $captcha = ''
    if ($loginPage -match 'name="_captcha"\s*value="([^"]+)"') { $captcha = $matches[1] }
    $randomName = ''; $randomValue = ''
    if ($loginPage -match 'name="([A-Za-z0-9]{16})"\s*value="(\d+)"') {
        $randomName = $matches[1]; $randomValue = $matches[2]
    }

    if (-not $csrfToken) {
        Write-Host "Error: could not get CSRF token from login page." -ForegroundColor Red
        exit 1
    }

    # Step 2: Login
    $loginHeaderFile = [System.IO.Path]::GetTempFileName()
    $randomField = @()
    if ($randomName) { $randomField = @('-d', "${randomName}=${randomValue}") }

    & curl.exe -s -D $loginHeaderFile -o NUL -c $cookieJar -b $cookieJar `
        -d "_token=$csrfToken" -d "_captcha=$captcha" -d "_username=" `
        -d "username=$Username" --data-urlencode "password=$Password" `
        -d "remember=on" @randomField "${TrackerUrl}/login"

    $loginLocation = ''
    foreach ($hline in Get-Content -LiteralPath $loginHeaderFile) {
        if ($hline -match '^Location:\s*(.+)') { $loginLocation = $matches[1].Trim() }
    }
    Remove-Item -LiteralPath $loginHeaderFile -ErrorAction SilentlyContinue

    if ($loginLocation -match '/login') {
        Write-Host "Error: login failed. Check username/password in config." -ForegroundColor Red
        exit 1
    }

    # Follow redirect to finalize session
    & curl.exe -s -o NUL -c $cookieJar -b $cookieJar --max-time 15 $loginLocation

    Write-Host "Logged in." -ForegroundColor Green

    # Step 3: Fetch uploads page
    Write-Host "Fetching last $count uploads by '$Username'..." -ForegroundColor Cyan
    $uploadsUrl = "${TrackerUrl}/users/${Username}/uploads"
    $uploadsPage = (& curl.exe -s -b $cookieJar --max-time 30 $uploadsUrl) -join "`n"

    # Step 4: Parse torrent rows from HTML
    # UNIT3D uses <tr> rows in the uploads table, each containing torrent data
    $rowMatches = [regex]::Matches($uploadsPage, '<tr[^>]*>.*?</tr>', ([System.Text.RegularExpressions.RegexOptions]::Singleline))

    function HtmlDecode($s) {
        $s -replace '<[^>]+>', '' -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>' -replace '&#039;', "'" -replace '&quot;', '"' -replace '&nbsp;', ' '
    }

    $seen = @{}
    $torrents = @()
    foreach ($row in $rowMatches) {
        $html = $row.Value

        # Must contain a torrent link
        if ($html -notmatch 'href="[^"]*?/torrents/(\d+)"') { continue }
        $id = $matches[1]
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id] = $true

        # Name from torrent link
        $name = ''
        if ($html -match '<a[^>]*href="[^"]*?/torrents/' + $id + '"[^>]*>\s*(.*?)\s*</a>') {
            $name = (HtmlDecode $matches[1]).Trim()
        }
        if (-not $name) { continue }

        # Date from <time> tag
        $date = ''
        if ($html -match '<time[^>]*datetime="([^"]+)"') {
            $dt = $matches[1]
            if ($dt.Length -ge 10) { $date = $dt.Substring(0, 10) }
        }

        # Size from user-uploads__size td (e.g. "6.13 GiB", "456.78 MiB")
        $size = ''
        if ($html -match 'user-uploads__size[^>]*>\s*([\d.]+\s*(?:TiB|GiB|MiB|KiB|B))\s*<') {
            $size = $matches[1]
        }

        # Personal release from user-uploads__personal-release td
        $isPersonal = $false
        $perMatch = [regex]::Match($html, 'user-uploads__personal-release[\s\S]*?title="([^"]+)"')
        if ($perMatch.Success) {
            $isPersonal = ($perMatch.Groups[1].Value -eq 'Personal release')
        }

        # Approved status from user-uploads__status td
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

        $torrents += @{ id = $id; name = $name; date = $date; size = $size; isPersonal = $isPersonal; approvedStatus = $approvedStatus }
        if ($torrents.Count -ge $count) { break }
    }

    if ($torrents.Count -eq 0) {
        Write-Host "No uploads found." -ForegroundColor Yellow
        exit 0
    }

    # Load icons from external UTF-8 file
    $iconsFile = Join-Path $PSScriptRoot "shared\icons.jsonc"
    $icons = ([System.IO.File]::ReadAllText($iconsFile, [System.Text.Encoding]::UTF8) -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json

    $esc = [char]27

    # Visual width: emoji/surrogates = 2 cols, flag pairs = 2 cols, variation selectors/ZWJ = 0
    function IsRegionalIndicator([string]$s, [int]$i) {
        # Regional indicator: surrogate pair U+D83C + U+DDE6..U+DDFF
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
            # Flag emoji: two regional indicator pairs = 1 flag = 2 display cols
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
    # Fixed cols: ID(6) + sp(1) + NAME + sp(1) + SIZE(10) + sp(1) + DATE(10) + sp(1) + PER(5) + APPROVED(8) = 43
    $tw = 120
    try { $tw = [Console]::WindowWidth } catch { }
    if (-not $tw -or $tw -lt 60) { try { $tw = $Host.UI.RawUI.WindowSize.Width } catch { } }
    if (-not $tw -or $tw -lt 60) { $tw = 120 }
    $nameW = $tw - 43
    if ($nameW -lt 20) { $nameW = 20 }
    $nameDash = '-' * $nameW

    Write-Host ""
    Write-Host ("{0,-6} {1,-$nameW} {2,-10} {3,-10} {4,-4} {5}" -f "ID", "NAME", "SIZE", "DATE", "PER", "APPROVED") -ForegroundColor DarkGray
    Write-Host ("{0,-6} {1,-$nameW} {2,-10} {3,-10} {4,-4} {5}" -f "------", $nameDash, "----------", "----------", "----", "--------") -ForegroundColor DarkGray

    foreach ($t in $torrents) {
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
        # Pad name manually using visual width
        $vl = Get-VLen $name
        $namePad = $name + (' ' * ($nameW - $vl))
        $idPad  = ("{0,-6}" -f $id)
        $idCell = "${esc}]8;;${TrackerUrl}/torrents/${id}${esc}\${idPad}${esc}]8;;${esc}\"
        # Emoji takes 2 display columns but PS counts 1; pad with 3 spaces
        $perCell = "$per   "
        Write-Host ("${idCell} ${namePad} {0,-10} {1,-10} ${perCell}{2}" -f $size, $date, $appr)
    }

    Write-Host ""
    Write-Host "Total: $($torrents.Count) torrent(s)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "All uploads: " -NoNewline
    Write-Host $uploadsUrl -ForegroundColor Blue

} finally {
    Remove-Item -LiteralPath $cookieJar -ErrorAction SilentlyContinue
}
