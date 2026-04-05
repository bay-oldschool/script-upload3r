$e = [char]27

Write-Host ""
Write-Host "=== 16 Standard Colors ==="
foreach ($code in 30,31,32,33,34,35,36,37,90,91,92,93,94,95,96,97) {
    $names = @{30='Black';31='Red';32='Green';33='Dark Yellow';34='Blue';35='Magenta';36='Cyan';37='White';90='Bright Black';91='Bright Red';92='Bright Green';93='Bright Yellow';94='Bright Blue';95='Bright Magenta';96='Bright Cyan';97='Bright White'}
    $n = $names[$code].PadRight(18)
    Write-Host "$e[$($code)m  $code  $n ####..::::++**##@@ $e[0m"
}

Write-Host ""
Write-Host "=== 256 Extended Colors ==="
for ($i = 0; $i -lt 256; $i++) {
    $label = "$i".PadLeft(4)
    Write-Host -NoNewline "$e[38;5;$($i)m$label ## $e[0m"
    if (($i -eq 7) -or ($i -eq 15) -or (($i -gt 15) -and (($i - 15) % 12 -eq 0)) -or ($i -eq 255)) {
        Write-Host ""
    }
}

Write-Host ""
