param(
    [Parameter(Mandatory)][string]$path,
    [Parameter(Mandatory)][string]$announceurl,
    [Parameter(Mandatory)][string]$outputfile,
    [int]$piecelength = 0,
    [int]$private = 1
)

# Bencode helpers
function Bencode-String([string]$s) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($s)
    return [System.Text.Encoding]::UTF8.GetBytes("$($bytes.Length):") + $bytes
}

function Bencode-Int([long]$n) {
    return [System.Text.Encoding]::UTF8.GetBytes("i${n}e")
}

function Bencode-Bytes([byte[]]$b) {
    return [System.Text.Encoding]::UTF8.GetBytes("$($b.Length):") + $b
}

$sha1 = [System.Security.Cryptography.SHA1]::Create()

$resolvedPath = (Resolve-Path -LiteralPath $path).Path.TrimEnd('\')
$isDir = (Get-Item -LiteralPath $resolvedPath) -is [System.IO.DirectoryInfo]

if ($isDir) {
    $videoExts = @('.mkv','.mp4','.avi','.wmv','.mov','.m4v','.mpg','.mpeg','.ts','.m2ts')
    $files = Get-ChildItem -LiteralPath $resolvedPath -Recurse -File | Where-Object {
        $inTrailerDir = $_.FullName -match '(?i)[/\\]trailers?[/\\]'
        $isTrailerFile = $_.Name -match '(?i)(^|[\s._-])trailer' -and $videoExts -contains $_.Extension.ToLower()
        -not $inTrailerDir -and -not $isTrailerFile
    } | Sort-Object FullName
} else {
    $files = @(Get-Item -LiteralPath $resolvedPath)
    $resolvedPath = Split-Path $resolvedPath -Parent
}

# Auto-calculate optimal piece size if not specified
# Target: ~1500 pieces, clamped between 16 KiB (2^14) and 32 MiB (2^25)
if ($piecelength -eq 0) {
    $totalSize = ($files | Measure-Object -Property Length -Sum).Sum
    $raw = $totalSize / 1500
    # Round up to nearest power of 2
    $piecelength = [Math]::Max(14, [Math]::Min(25, [Math]::Ceiling([Math]::Log($raw, 2))))
}
$pieceSize = [long][Math]::Pow(2, $piecelength)

# Display piece size
$psLabel = if ($pieceSize -ge 1MB) { "$([Math]::Round($pieceSize / 1MB, 2)) MiB" } else { "$([Math]::Round($pieceSize / 1KB)) KiB" }
Write-Host "Piece size: $psLabel" -ForegroundColor DarkGray

# Build pieces by reading all files concatenated and hashing in piece-sized chunks
$allPieces = [System.IO.MemoryStream]::new()
$buffer = New-Object byte[] $pieceSize
$bufferOffset = 0

$totalBytes = ($files | Measure-Object -Property Length -Sum).Sum
$totalPieces = [Math]::Ceiling($totalBytes / $pieceSize)
$processedPieces = 0
$processedBytes = 0
$barWidth = 30
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# ANSI colors and Unicode block chars (built at runtime — safe for PS5.1)
$esc = [char]27
$cBar   = "$esc[96m"   # cyan — filled bar
$cDim   = "$esc[90m"   # dark gray — empty bar
$cPct   = "$esc[93m"   # yellow — percentage
$cInfo  = "$esc[37m"   # white — size/pieces
$cDone  = "$esc[92m"   # green — complete
$cReset = "$esc[0m"
$blockFull  = [char]0x2588  # full block
$blockEmpty = [char]0x2591  # light shade

foreach ($file in $files) {
    $stream = [System.IO.File]::OpenRead($file.FullName)
    while ($true) {
        $bytesRead = $stream.Read($buffer, $bufferOffset, $pieceSize - $bufferOffset)
        if ($bytesRead -eq 0) { break }
        $bufferOffset += $bytesRead
        $processedBytes += $bytesRead
        if ($bufferOffset -eq $pieceSize) {
            $hash = $sha1.ComputeHash($buffer, 0, $pieceSize)
            $allPieces.Write($hash, 0, $hash.Length)
            $bufferOffset = 0
            $processedPieces++
            # Update progress bar
            $pct = [Math]::Min(100, [Math]::Floor($processedPieces * 100 / $totalPieces))
            $filled = [Math]::Floor($pct * $barWidth / 100)
            $empty = $barWidth - $filled
            $barFill = "$blockFull" * $filled
            $barRest = "$blockEmpty" * $empty
            $sizeMB = [Math]::Round($processedBytes / 1MB, 1)
            $totalMB = [Math]::Round($totalBytes / 1MB, 1)
            $pctPad = "$pct".PadLeft(3)
            Write-Host "`r  ${cBar}${barFill}${cDim}${barRest}${cReset} ${cPct}${pctPad}%${cReset}  ${cInfo}${sizeMB}/${totalMB} MB${cReset}  ${cDim}($processedPieces/$totalPieces pieces)${cReset}" -NoNewline
        }
    }
    $stream.Close()
}

# Hash remaining bytes
if ($bufferOffset -gt 0) {
    $hash = $sha1.ComputeHash($buffer, 0, $bufferOffset)
    $allPieces.Write($hash, 0, $hash.Length)
    $processedPieces++
}

# Final progress
$barFull = "$blockFull" * $barWidth
$totalMB = [Math]::Round($totalBytes / 1MB, 1)
$elapsed = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
Write-Host "`r  ${cDone}${barFull}${cReset} ${cDone}100%${cReset}  ${cInfo}${totalMB} MB${cReset}  ${cDim}($totalPieces pieces)${cReset}  ${cDone}${elapsed}s${cReset}"

$piecesBytes = $allPieces.ToArray()
$allPieces.Close()

# Build the info dictionary
$info = [System.IO.MemoryStream]::new()
$info.Write([System.Text.Encoding]::UTF8.GetBytes("d"), 0, 1)

if ($isDir) {
    # files key
    $k = Bencode-String "files"
    $info.Write($k, 0, $k.Length)
    $info.Write([System.Text.Encoding]::UTF8.GetBytes("l"), 0, 1)
    foreach ($file in $files) {
        $info.Write([System.Text.Encoding]::UTF8.GetBytes("d"), 0, 1)
        # length
        $k = Bencode-String "length"
        $info.Write($k, 0, $k.Length)
        $v = Bencode-Int $file.Length
        $info.Write($v, 0, $v.Length)
        # path
        $k = Bencode-String "path"
        $info.Write($k, 0, $k.Length)
        $relativePath = $file.FullName.Substring($resolvedPath.Length + 1).Replace('\', '/')
        $parts = $relativePath.Split('/')
        $info.Write([System.Text.Encoding]::UTF8.GetBytes("l"), 0, 1)
        foreach ($part in $parts) {
            $v = Bencode-String $part
            $info.Write($v, 0, $v.Length)
        }
        $info.Write([System.Text.Encoding]::UTF8.GetBytes("e"), 0, 1)
        $info.Write([System.Text.Encoding]::UTF8.GetBytes("e"), 0, 1)
    }
    $info.Write([System.Text.Encoding]::UTF8.GetBytes("e"), 0, 1)

    # name
    $k = Bencode-String "name"
    $info.Write($k, 0, $k.Length)
    $v = Bencode-String (Split-Path $resolvedPath -Leaf)
    $info.Write($v, 0, $v.Length)
} else {
    # length
    $k = Bencode-String "length"
    $info.Write($k, 0, $k.Length)
    $v = Bencode-Int $files[0].Length
    $info.Write($v, 0, $v.Length)
    # name
    $k = Bencode-String "name"
    $info.Write($k, 0, $k.Length)
    $v = Bencode-String $files[0].Name
    $info.Write($v, 0, $v.Length)
}

# piece length
$k = Bencode-String "piece length"
$info.Write($k, 0, $k.Length)
$v = Bencode-Int ([long]$pieceSize)
$info.Write($v, 0, $v.Length)

# pieces
$k = Bencode-String "pieces"
$info.Write($k, 0, $k.Length)
$v = Bencode-Bytes $piecesBytes
$info.Write($v, 0, $v.Length)

# private flag (1 = private/no DHT, 0 = public/DHT enabled)
if ($private -eq 1) {
    $k = Bencode-String "private"
    $info.Write($k, 0, $k.Length)
    $v = Bencode-Int 1
    $info.Write($v, 0, $v.Length)
}

$info.Write([System.Text.Encoding]::UTF8.GetBytes("e"), 0, 1)

# Build the full torrent
$torrent = [System.IO.MemoryStream]::new()
$torrent.Write([System.Text.Encoding]::UTF8.GetBytes("d"), 0, 1)

# announce
$k = Bencode-String "announce"
$torrent.Write($k, 0, $k.Length)
$v = Bencode-String $announceurl
$torrent.Write($v, 0, $v.Length)

# created by
$k = Bencode-String "created by"
$torrent.Write($k, 0, $k.Length)
$v = Bencode-String "SCRIPT UPLOAD3R"
$torrent.Write($v, 0, $v.Length)

# info
$k = Bencode-String "info"
$torrent.Write($k, 0, $k.Length)
$infoBytes = $info.ToArray()
$torrent.Write($infoBytes, 0, $infoBytes.Length)

$torrent.Write([System.Text.Encoding]::UTF8.GetBytes("e"), 0, 1)

[System.IO.File]::WriteAllBytes($outputfile, $torrent.ToArray())
$info.Close()
$torrent.Close()

Write-Host "Torrent created: $outputfile" -ForegroundColor Green
