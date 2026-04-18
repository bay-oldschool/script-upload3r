# shared/totp.ps1 - RFC 6238 TOTP generator for PowerShell 5.1
# Usage: . shared/totp.ps1; $code = Get-TOTPCode -Secret "BASE32SECRET"

function ConvertFrom-Base32 {
    param([string]$Base32)
    $Base32 = $Base32.ToUpper().TrimEnd('=')
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    $bits = ''
    foreach ($c in $Base32.ToCharArray()) {
        $val = $alphabet.IndexOf($c)
        if ($val -lt 0) { continue }
        $bits += [Convert]::ToString($val, 2).PadLeft(5, '0')
    }
    $bytes = New-Object byte[] ([Math]::Floor($bits.Length / 8))
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($bits.Substring($i * 8, 8), 2)
    }
    return ,$bytes
}

function Get-TOTPCode {
    param(
        [Parameter(Mandatory)][string]$Secret,
        [int]$Digits = 6,
        [int]$Period = 30,
        [int]$MinRemaining = 5
    )
    $keyBytes = ConvertFrom-Base32 -Base32 $Secret
    # Wait for a fresh TOTP window if too close to the boundary
    $epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $remaining = $Period - ($epoch % $Period)
    if ($remaining -lt $MinRemaining) {
        Start-Sleep -Seconds $remaining
        $epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
    # Time counter (RFC 6238): floor(unixTime / period) as big-endian 8-byte int
    $counter = [Math]::Floor($epoch / $Period)
    $counterBytes = [BitConverter]::GetBytes([long]$counter)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($counterBytes) }
    # HMAC-SHA1
    $hmac = New-Object System.Security.Cryptography.HMACSHA1 @(,$keyBytes)
    $hash = $hmac.ComputeHash($counterBytes)
    $hmac.Dispose()
    # Dynamic truncation (RFC 4226)
    $offset = $hash[$hash.Length - 1] -band 0x0F
    $binary = (($hash[$offset] -band 0x7F) -shl 24) -bor `
              (($hash[$offset + 1] -band 0xFF) -shl 16) -bor `
              (($hash[$offset + 2] -band 0xFF) -shl 8) -bor `
               ($hash[$offset + 3] -band 0xFF)
    $otp = $binary % [Math]::Pow(10, $Digits)
    return ([string][int]$otp).PadLeft($Digits, '0')
}
