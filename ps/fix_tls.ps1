#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Check and fix TLS 1.2 settings for .NET / PowerShell on older Windows builds.
    Needed on Windows 10 1607 (build 14393) and earlier where TLS 1.2 may be
    disabled by default for .NET Framework applications.
#>
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$esc  = [char]27
$b    = "$esc[1m"
$r    = "$esc[0m"
$cyan = "$esc[96m"
$grn  = "$esc[92m"
$ylw  = "$esc[93m"
$red  = "$esc[91m"
$blue = "$esc[94m"

Write-Host ''
Write-Host ($b + $cyan + '========================================' + $r)
Write-Host ($b + $cyan + '   TLS 1.2 Diagnostics & Fix' + $r)
Write-Host ($b + $cyan + '========================================' + $r)
Write-Host ''

# ── 1. Show OS build ────────────────────────────────────────────────
$build = [System.Environment]::OSVersion.Version
Write-Host ($b + $blue + 'OS version: ' + $r + "$build")
Write-Host ''

# ── 2. Check current .NET SecurityProtocol ──────────────────────────
$current = [Net.ServicePointManager]::SecurityProtocol
Write-Host ($b + $blue + 'Current .NET SecurityProtocol: ' + $r + "$current")

$hasTls12 = ($current -band [Net.SecurityProtocolType]::Tls12) -ne 0
$isSystemDefault = "$current" -eq 'SystemDefault'
if ($hasTls12) {
    Write-Host ($grn + '  TLS 1.2 is explicitly enabled.' + $r)
} elseif ($isSystemDefault) {
    Write-Host ($grn + '  SystemDefault (TLS 1.2 included on modern Windows).' + $r)
} else {
    Write-Host ($ylw + '  TLS 1.2 is NOT enabled for this session.' + $r)
}
Write-Host ''

# ── 3. Check SChannel registry keys ────────────────────────────────
Write-Host ($b + $blue + 'SChannel registry (TLS 1.2 Client):' + $r)

$regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client'
$needsFix = $false

if (Test-Path $regPath) {
    $enabled    = (Get-ItemProperty -Path $regPath -Name 'Enabled'           -ErrorAction SilentlyContinue).Enabled
    $disabled   = (Get-ItemProperty -Path $regPath -Name 'DisabledByDefault' -ErrorAction SilentlyContinue).DisabledByDefault

    if ($null -eq $enabled) {
        Write-Host ($ylw + "  Enabled           = (not set, defaults to OS behavior)" + $r)
    } elseif ($enabled -eq 1) {
        Write-Host ($grn + "  Enabled           = 1  (OK)" + $r)
    } else {
        Write-Host ($red + "  Enabled           = $enabled  (should be 1)" + $r)
        $needsFix = $true
    }

    if ($null -eq $disabled) {
        Write-Host ($ylw + "  DisabledByDefault = (not set, defaults to OS behavior)" + $r)
    } elseif ($disabled -eq 0) {
        Write-Host ($grn + "  DisabledByDefault = 0  (OK)" + $r)
    } else {
        Write-Host ($red + "  DisabledByDefault = $disabled  (should be 0)" + $r)
        $needsFix = $true
    }
} else {
    Write-Host ($ylw + "  Registry key does not exist (OS defaults apply)." + $r)
}
Write-Host ''

# ── 4. Check .NET Framework strong-crypto keys ─────────────────────
Write-Host ($b + $blue + '.NET Framework strong-crypto registry:' + $r)

$dotnetPaths = @(
    'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319'
)
$strongCryptoOk = $true

foreach ($dp in $dotnetPaths) {
    $label = $dp -replace 'HKLM:\\SOFTWARE\\', ''
    if (Test-Path $dp) {
        $val = (Get-ItemProperty -Path $dp -Name 'SchUseStrongCrypto' -ErrorAction SilentlyContinue).SchUseStrongCrypto
        if ($null -eq $val) {
            Write-Host ($ylw + "  $label  SchUseStrongCrypto = (not set)" + $r)
            $strongCryptoOk = $false
        } elseif ($val -eq 1) {
            Write-Host ($grn + "  $label  SchUseStrongCrypto = 1  (OK)" + $r)
        } else {
            Write-Host ($red + "  $label  SchUseStrongCrypto = $val  (should be 1)" + $r)
            $strongCryptoOk = $false
        }
    } else {
        Write-Host ($ylw + "  $label  (key not present)" + $r)
        $strongCryptoOk = $false
    }
}
Write-Host ''

# ── 5. Quick connection test ────────────────────────────────────────
Write-Host ($b + $blue + 'TLS 1.2 connection test:' + $r)
$connectionOk = $false
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $req = [Net.HttpWebRequest]::Create('https://www.howsmyssl.com/a/check')
    $req.Timeout = 10000
    $resp = $req.GetResponse()
    $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
    $body = $reader.ReadToEnd()
    $reader.Close(); $resp.Close()

    if ($body -match '"tls_version"\s*:\s*"([^"]+)"') {
        $tlsVer = $matches[1]
        Write-Host ($grn + "  Connected with $tlsVer  (OK)" + $r)
    } else {
        Write-Host ($grn + '  Connection successful.' + $r)
    }
    $connectionOk = $true
} catch {
    Write-Host ($red + "  Connection FAILED: $_" + $r)
    $needsFix = $true
}
Write-Host ''

# ── 6. Offer to apply fix ──────────────────────────────────────────
if ($connectionOk -and ($hasTls12 -or $isSystemDefault) -and -not $needsFix) {
    Write-Host ($grn + 'Everything looks good. No fix needed.' + $r)
    Write-Host ''
    return
}
if ($connectionOk -and $isSystemDefault) {
    Write-Host ($grn + 'TLS 1.2 works via SystemDefault. No fix needed.' + $r)
    Write-Host ''
    return
}

Write-Host ($ylw + 'Recommended fix: set SChannel + .NET strong-crypto registry keys.' + $r)
Write-Host ($ylw + 'This requires Administrator privileges and a reboot to take effect.' + $r)
Write-Host ''

$answer = Read-Host '  Apply fix now? (y/n) [n]'
if ($answer -ne 'y') {
    Write-Host ''
    Write-Host '  Skipped. No changes were made.'
    Write-Host ''
    return
}

# ── 7. Apply registry fixes ────────────────────────────────────────
Write-Host ''

# Check if running as admin
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host ($red + '  ERROR: Must run as Administrator to write HKLM registry keys.' + $r)
    Write-Host ($ylw + '  Right-click run.bat and choose "Run as administrator", then retry.' + $r)
    Write-Host ''
    return
}

try {
    # SChannel TLS 1.2 Client
    $scPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client'
    if (-not (Test-Path $scPath)) {
        New-Item -Path $scPath -Force | Out-Null
    }
    Set-ItemProperty -Path $scPath -Name 'Enabled'           -Value 1 -Type DWord
    Set-ItemProperty -Path $scPath -Name 'DisabledByDefault' -Value 0 -Type DWord
    Write-Host ($grn + '  SChannel TLS 1.2 Client keys set.' + $r)

    # .NET strong crypto (64-bit + WOW64)
    foreach ($dp in $dotnetPaths) {
        if (-not (Test-Path $dp)) {
            New-Item -Path $dp -Force | Out-Null
        }
        Set-ItemProperty -Path $dp -Name 'SchUseStrongCrypto' -Value 1 -Type DWord
    }
    Write-Host ($grn + '  .NET SchUseStrongCrypto keys set.' + $r)

    Write-Host ''
    Write-Host ($grn + 'Fix applied successfully.' + $r)
    Write-Host ($ylw + 'A reboot is recommended for the changes to take full effect.' + $r)
} catch {
    Write-Host ($red + "  Failed to apply fix: $_" + $r)
}
Write-Host ''
