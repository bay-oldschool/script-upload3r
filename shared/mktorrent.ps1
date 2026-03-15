param(
    [Parameter(Mandatory)][string]$path,
    [Parameter(Mandatory)][string]$announceurl,
    [Parameter(Mandatory)][string]$outputfile,
    [int]$piecelength = 22,
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

$pieceSize = [Math]::Pow(2, $piecelength)
$sha1 = [System.Security.Cryptography.SHA1]::Create()

$resolvedPath = (Resolve-Path -LiteralPath $path).Path.TrimEnd('\')
$isDir = (Get-Item -LiteralPath $resolvedPath) -is [System.IO.DirectoryInfo]

if ($isDir) {
    $files = Get-ChildItem -LiteralPath $resolvedPath -Recurse -File | Sort-Object FullName
} else {
    $files = @(Get-Item -LiteralPath $resolvedPath)
    $resolvedPath = Split-Path $resolvedPath -Parent
}

# Build pieces by reading all files concatenated and hashing in piece-sized chunks
$allPieces = [System.IO.MemoryStream]::new()
$buffer = New-Object byte[] $pieceSize
$bufferOffset = 0

foreach ($file in $files) {
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

# Hash remaining bytes
if ($bufferOffset -gt 0) {
    $hash = $sha1.ComputeHash($buffer, 0, $bufferOffset)
    $allPieces.Write($hash, 0, $hash.Length)
}

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
