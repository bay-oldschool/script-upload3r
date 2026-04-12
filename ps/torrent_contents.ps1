param(
    [Parameter(Mandatory)][string]$torrentfile,
    [Parameter(Mandatory)][string]$mediapath,
    [string]$configfile
)

$ErrorActionPreference = 'Stop'
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
if (-not $configfile) { $configfile = Join-Path "$PSScriptRoot/.." "config.jsonc" }

$esc = [char]27
$cCyan   = "$esc[96m"
$cYellow = "$esc[93m"
$cGreen  = "$esc[92m"
$cRed    = "$esc[91m"
$cDim    = "$esc[90m"
$cReset  = "$esc[0m"

function Format-Size([long]$bytes) {
    if ($bytes -ge 1GB) { return "{0:N2} GB" -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return "{0:N2} MB" -f ($bytes / 1MB) }
    if ($bytes -ge 1KB) { return "{0:N2} KB" -f ($bytes / 1KB) }
    return "$bytes B"
}

function Bdecode([byte[]]$data, [ref]$pos) {
    $c = [char]$data[$pos.Value]
    if ($c -eq 'i') {
        $pos.Value++
        $s = $pos.Value
        while ([char]$data[$pos.Value] -ne 'e') { $pos.Value++ }
        $v = [System.Text.Encoding]::UTF8.GetString($data, $s, $pos.Value - $s)
        $pos.Value++
        return [long]$v
    } elseif ($c -eq 'l') {
        $pos.Value++
        $a = @()
        while ([char]$data[$pos.Value] -ne 'e') { $a += ,(Bdecode $data $pos) }
        $pos.Value++
        return ,$a
    } elseif ($c -eq 'd') {
        $pos.Value++
        $h = [ordered]@{}
        while ([char]$data[$pos.Value] -ne 'e') {
            $k = Bdecode $data $pos
            $v = Bdecode $data $pos
            $h[$k] = $v
        }
        $pos.Value++
        return $h
    } else {
        $s = $pos.Value
        while ([char]$data[$pos.Value] -ne ':') { $pos.Value++ }
        $len = [int][System.Text.Encoding]::UTF8.GetString($data, $s, $pos.Value - $s)
        $pos.Value++
        $str = [System.Text.Encoding]::UTF8.GetString($data, $pos.Value, $len)
        $pos.Value += $len
        return $str
    }
}

function Parse-Torrent([string]$path) {
    $raw = [System.IO.File]::ReadAllBytes($path)
    $pos = 0
    return Bdecode $raw ([ref]$pos)
}

function Get-FileList($info) {
    $fileList = @()
    $fileEntries = $info['files']
    if ($fileEntries) {
        $idx = 1
        foreach ($f in $fileEntries) {
            $fp = ($f['path']) -join '/'
            $fileList += @{ Index = $idx; Path = $fp; Size = [long]$f['length'] }
            $idx++
        }
    } else {
        $fileList += @{ Index = 1; Path = $info['name']; Size = [long]$info['length']; Single = $true }
    }
    return $fileList
}

function Show-Contents($info) {
    Write-Host "${cCyan}=== Torrent Contents ===${cReset}"
    Write-Host ""
    Write-Host "${cYellow}$($info['name'])${cReset}"
    Write-Host ""
    $fileList = Get-FileList $info
    foreach ($f in $fileList) {
        $szFmt = Format-Size $f.Size
        Write-Host "  ${cDim}$($f.Index))${cReset} $($f.Path) ${cDim}[$szFmt]${cReset}"
    }
    Write-Host ""
    return $fileList
}

function Rebuild-Torrent($meta, [string[]]$keepPaths, [string]$mediapath, [string]$outfile) {
    $config = (Get-Content -Path $configfile | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json
    $announceUrl = $config.announce_url
    if (-not $announceUrl) {
        Write-Host "${cRed}Cannot rebuild: announce_url not configured.${cReset}"
        return $false
    }

    $resolvedMedia = (Resolve-Path -LiteralPath $mediapath).Path.TrimEnd('\')
    $isDir = (Get-Item -LiteralPath $resolvedMedia) -is [System.IO.DirectoryInfo]
    $baseDir = if ($isDir) { $resolvedMedia } else { Split-Path $resolvedMedia -Parent }

    $info = $meta['info']
    $torrentName = $info['name']

    $keepFiles = @()
    foreach ($p in $keepPaths) {
        $fullPath = Join-Path $baseDir $p
        if (-not (Test-Path -LiteralPath $fullPath)) {
            Write-Host "${cRed}File not found on disk: $p${cReset}"
            return $false
        }
        $keepFiles += Get-Item -LiteralPath $fullPath
    }
    $keepFiles = $keepFiles | Sort-Object FullName

    $totalSize = ($keepFiles | Measure-Object -Property Length -Sum).Sum
    $raw = $totalSize / 1500
    $pl = [Math]::Max(14, [Math]::Min(25, [Math]::Ceiling([Math]::Log($raw, 2))))
    $pieceSize = [long][Math]::Pow(2, $pl)

    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    $allPieces = [System.IO.MemoryStream]::new()
    $buffer = New-Object byte[] $pieceSize
    $bufferOffset = 0

    foreach ($file in $keepFiles) {
        $stream = [System.IO.File]::OpenRead($file.FullName)
        while ($true) {
            $bytesRead = $stream.Read($buffer, $bufferOffset, $pieceSize - $bufferOffset)
            if ($bytesRead -eq 0) { break }
            $bufferOffset += $bytesRead
            if ($bufferOffset -eq $pieceSize) {
                $hash = $sha1.ComputeHash($buffer, 0, $pieceSize)
                $allPieces.Write($hash, 0, $hash.Length)
                $bufferOffset = 0
            }
        }
        $stream.Close()
    }
    if ($bufferOffset -gt 0) {
        $hash = $sha1.ComputeHash($buffer, 0, $bufferOffset)
        $allPieces.Write($hash, 0, $hash.Length)
    }
    $piecesBytes = $allPieces.ToArray()
    $allPieces.Close()

    # Bencode helpers (local)
    function BStr([string]$s) {
        $b = [System.Text.Encoding]::UTF8.GetBytes($s)
        return [System.Text.Encoding]::UTF8.GetBytes("$($b.Length):") + $b
    }
    function BInt([long]$n) { return [System.Text.Encoding]::UTF8.GetBytes("i${n}e") }
    function BBytes([byte[]]$b) { return [System.Text.Encoding]::UTF8.GetBytes("$($b.Length):") + $b }

    $infoStream = [System.IO.MemoryStream]::new()
    $infoStream.Write([System.Text.Encoding]::UTF8.GetBytes("d"), 0, 1)

    # files
    $k = BStr "files"; $infoStream.Write($k, 0, $k.Length)
    $infoStream.Write([System.Text.Encoding]::UTF8.GetBytes("l"), 0, 1)
    foreach ($file in $keepFiles) {
        $infoStream.Write([System.Text.Encoding]::UTF8.GetBytes("d"), 0, 1)
        $k = BStr "length"; $infoStream.Write($k, 0, $k.Length)
        $v = BInt $file.Length; $infoStream.Write($v, 0, $v.Length)
        $k = BStr "path"; $infoStream.Write($k, 0, $k.Length)
        $rel = $file.FullName.Substring($baseDir.Length + 1).Replace('\', '/')
        $parts = $rel.Split('/')
        $infoStream.Write([System.Text.Encoding]::UTF8.GetBytes("l"), 0, 1)
        foreach ($part in $parts) { $v = BStr $part; $infoStream.Write($v, 0, $v.Length) }
        $infoStream.Write([System.Text.Encoding]::UTF8.GetBytes("e"), 0, 1)
        $infoStream.Write([System.Text.Encoding]::UTF8.GetBytes("e"), 0, 1)
    }
    $infoStream.Write([System.Text.Encoding]::UTF8.GetBytes("e"), 0, 1)

    # name
    $k = BStr "name"; $infoStream.Write($k, 0, $k.Length)
    $v = BStr $torrentName; $infoStream.Write($v, 0, $v.Length)

    # piece length
    $k = BStr "piece length"; $infoStream.Write($k, 0, $k.Length)
    $v = BInt $pieceSize; $infoStream.Write($v, 0, $v.Length)

    # pieces
    $k = BStr "pieces"; $infoStream.Write($k, 0, $k.Length)
    $v = BBytes $piecesBytes; $infoStream.Write($v, 0, $v.Length)

    # private
    $k = BStr "private"; $infoStream.Write($k, 0, $k.Length)
    $v = BInt 1; $infoStream.Write($v, 0, $v.Length)

    $infoStream.Write([System.Text.Encoding]::UTF8.GetBytes("e"), 0, 1)

    # Full torrent
    $torrent = [System.IO.MemoryStream]::new()
    $torrent.Write([System.Text.Encoding]::UTF8.GetBytes("d"), 0, 1)
    $k = BStr "announce"; $torrent.Write($k, 0, $k.Length)
    $v = BStr $announceUrl; $torrent.Write($v, 0, $v.Length)
    $k = BStr "created by"; $torrent.Write($k, 0, $k.Length)
    $v = BStr "SCRIPT UPLOAD3R"; $torrent.Write($v, 0, $v.Length)
    $k = BStr "info"; $torrent.Write($k, 0, $k.Length)
    $infoBytes = $infoStream.ToArray()
    $torrent.Write($infoBytes, 0, $infoBytes.Length)
    $torrent.Write([System.Text.Encoding]::UTF8.GetBytes("e"), 0, 1)

    [System.IO.File]::WriteAllBytes($outfile, $torrent.ToArray())
    $infoStream.Close()
    $torrent.Close()
    return $true
}

# --- Main loop ---
if (-not (Test-Path -LiteralPath $torrentfile)) {
    Write-Host "Torrent file not found: $torrentfile" -ForegroundColor Red
    exit 1
}

:menu while ($true) {
    [Console]::Clear()
    $meta = Parse-Torrent $torrentfile
    $info = $meta['info']
    if (-not $info) {
        Write-Host "Cannot parse torrent" -ForegroundColor Red
        exit 1
    }
    $files = Show-Contents $info

    Write-Host "  ${cCyan}1)${cReset} Remove items"
    Write-Host "  ${cCyan}0)${cReset} Back"
    Write-Host ""
    Write-Host "  Select: " -NoNewline
    $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown').Character
    Write-Host $key
    if ($key -eq '0') { exit 0 }
    if ($key -ne '1') { continue }

    if ($files.Count -eq 1) {
        Write-Host "${cRed}Cannot remove the only file from the torrent.${cReset}"
        Write-Host ""
        Write-Host "  Press any key to return..."
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        continue
    }

    Write-Host ""
    Write-Host "  Enter file numbers to remove (comma-separated, e.g. ${cYellow}1,3,5${cReset})"
    Write-Host "  or ${cYellow}0${cReset} to cancel"
    Write-Host ""
    $input_str = Read-Host "  Remove"
    if ($input_str -eq '0' -or $input_str -eq '') { continue }

    $indices = @()
    foreach ($part in ($input_str -split ',')) {
        $part = $part.Trim()
        if ($part -match '^\d+$') {
            $n = [int]$part
            if ($n -ge 1 -and $n -le $files.Count) { $indices += $n }
        }
    }
    if ($indices.Count -eq 0) {
        Write-Host "${cRed}No valid file numbers entered.${cReset}"
        Start-Sleep -Seconds 2
        continue
    }

    $keepFiles = $files | Where-Object { $indices -notcontains $_.Index }
    if ($keepFiles.Count -eq 0) {
        Write-Host "${cRed}Cannot remove all files from the torrent.${cReset}"
        Start-Sleep -Seconds 2
        continue
    }

    $toRemove = $files | Where-Object { $indices -contains $_.Index }
    Write-Host ""
    Write-Host "  ${cRed}Files to remove from torrent:${cReset}"
    foreach ($f in $toRemove) {
        Write-Host "    - $($f.Path) ${cDim}[$(Format-Size $f.Size)]${cReset}"
    }
    Write-Host ""
    Write-Host "  Confirm? (y/n) [n]: " -NoNewline
    $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown').Character
    Write-Host $key
    if ($key -ne 'y') { continue }

    Write-Host ""
    Write-Host "  Rebuilding torrent..." -ForegroundColor Cyan
    $keepPaths = @($keepFiles | ForEach-Object { $_.Path })
    $ok = Rebuild-Torrent $meta $keepPaths $mediapath $torrentfile
    if ($ok) {
        Write-Host "  ${cGreen}Torrent updated successfully.${cReset}"
    }
    Write-Host ""
    Write-Host "  Press any key to continue..."
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}
