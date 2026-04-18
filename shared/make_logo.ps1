<#
.SYNOPSIS
    Render a text logo to PNG with optional flat / linear / radial gradient fill
    and a soft glow. Uses GDI+ (System.Drawing). Transparent background.

.EXAMPLE
    # Simple flat white text
    .\make_logo.ps1 -Text "MYSITE" -Output out.png -Colors '#ffffff'

.EXAMPLE
    # Nanoset: radial gradient cyan->lilac->purple with tiny cyan shadow
    .\make_logo.ps1 -Text NANOSET -Output nanoset/logo.png `
        -Style radial `
        -Colors '#15e1ed','#af63e4','#8d00ff','#8d00ff' `
        -Stops 1.0,0.56,0.14,0.0 `
        -Shadow '#8c34a0e6' -ShadowWidth 2 `
        -FontFamily 'Helvetica' -FontSize 160

.NOTES
    -Stops for Style=radial are GDI+ ColorBlend positions, where 0 = boundary
    and 1 = center (i.e. reversed from CSS radial-gradient). For Style=linear
    0 = start color, 1 = end color.
#>
param(
    [Parameter(Mandatory)][string]$Text,
    [Parameter(Mandatory)][string]$Output,
    [string[]]$FontFamily = @('Helvetica Neue','Helvetica','Arial','Segoe UI'),
    [int]$FontSize = 160,
    [switch]$Bold,
    [int]$LetterSpacing = 0,
    [int]$PadX = 64,
    [int]$PadY = 16,
    [ValidateSet('flat','linear','radial')]
    [string]$Style = 'flat',
    [string[]]$Colors = @('#ffffff'),
    [string[]]$Stops,
    [double]$Angle = 45,
    [string]$Shadow,
    [int]$ShadowWidth = 0
)

Add-Type -AssemblyName System.Drawing

function ConvertFrom-HexColor([string]$hex) {
    if (-not $hex) { return [System.Drawing.Color]::Transparent }
    $h = $hex.TrimStart('#')
    switch ($h.Length) {
        6 { return [System.Drawing.Color]::FromArgb(255,
                [Convert]::ToInt32($h.Substring(0,2),16),
                [Convert]::ToInt32($h.Substring(2,2),16),
                [Convert]::ToInt32($h.Substring(4,2),16)) }
        8 { return [System.Drawing.Color]::FromArgb(
                [Convert]::ToInt32($h.Substring(0,2),16),
                [Convert]::ToInt32($h.Substring(2,2),16),
                [Convert]::ToInt32($h.Substring(4,2),16),
                [Convert]::ToInt32($h.Substring(6,2),16)) }
        default { throw "Color must be #RRGGBB or #AARRGGBB, got: $hex" }
    }
}

# When invoked via `powershell -File`, comma-separated args arrive as a single
# string instead of being split — normalize both here.
$colorList = @($Colors | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$fillColors = @($colorList | ForEach-Object { ConvertFrom-HexColor $_.Trim() })
if ($fillColors.Count -lt 1) { throw "Provide at least one color via -Colors" }

$parsedStops = $null
if ($Stops) {
    $stopList = @($Stops | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
    $parsedStops = @($stopList | ForEach-Object {
        [double]::Parse($_.Trim(), [System.Globalization.CultureInfo]::InvariantCulture)
    })
}

# Resolve font (also normalize comma-joined single-string invocation form)
$fontList = @($FontFamily | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$ff = $null
foreach ($name in $fontList) {
    try { $ff = New-Object System.Drawing.FontFamily($name.Trim()); break } catch {}
}
if (-not $ff) { throw "None of the requested font families available: $($FontFamily -join ', ')" }
Write-Host "Using font: $($ff.Name)"

$fontStyle = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
$font = New-Object System.Drawing.Font($ff, [single]$FontSize, $fontStyle, [System.Drawing.GraphicsUnit]::Pixel)

# Measure per-character widths using GenericTypographic for tight layout
$tmp = New-Object System.Drawing.Bitmap 10,10
$tg = [System.Drawing.Graphics]::FromImage($tmp)
$tg.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
$fmt = [System.Drawing.StringFormat]::GenericTypographic
$chars = $Text.ToCharArray()
$sizes = @()
foreach ($c in $chars) {
    $sizes += $tg.MeasureString([string]$c, $font, [System.Drawing.PointF]::Empty, $fmt)
}
$tg.Dispose(); $tmp.Dispose()

# Build glyph path at origin, then reposition to padded bitmap
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$x = [single]0
for ($i = 0; $i -lt $chars.Length; $i++) {
    $path.AddString([string]$chars[$i], $ff, [int]$fontStyle, [single]$FontSize,
        (New-Object System.Drawing.PointF($x, [single]0)), $fmt)
    $x += $sizes[$i].Width + $LetterSpacing
}
$raw = $path.GetBounds()
$mat = New-Object System.Drawing.Drawing2D.Matrix
$mat.Translate([single]($PadX - $raw.X), [single]($PadY - $raw.Y))
$path.Transform($mat)
$mat.Dispose()
$width = [int]([math]::Ceiling($raw.Width))  + $PadX * 2
$height = [int]([math]::Ceiling($raw.Height)) + $PadY * 2

$bmp = New-Object System.Drawing.Bitmap $width, $height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::Transparent)
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

# Soft glow via stroked path
if ($Shadow -and $ShadowWidth -gt 0) {
    $shadowColor = ConvertFrom-HexColor $Shadow
    $pen = New-Object System.Drawing.Pen $shadowColor, ([single]$ShadowWidth)
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawPath($pen, $path)
    $pen.Dispose()
}

# Fill path according to style
$bounds = $path.GetBounds()
$brush = $null
$extra = @()
switch ($Style) {
    'flat' {
        $brush = New-Object System.Drawing.SolidBrush $fillColors[0]
    }
    'linear' {
        if ($fillColors.Count -lt 2) { throw "-Style linear needs at least 2 -Colors" }
        $lgb = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            $bounds, $fillColors[0], $fillColors[-1], [single]$Angle)
        if ($fillColors.Count -gt 2 -or $Stops) {
            $cb = New-Object System.Drawing.Drawing2D.ColorBlend $fillColors.Count
            $cb.Colors = $fillColors
            if ($Stops -and $Stops.Count -eq $fillColors.Count) {
                $cb.Positions = @($Stops | ForEach-Object { [single]$_ })
            } else {
                $step = 1.0 / ($fillColors.Count - 1)
                $cb.Positions = @(0..($fillColors.Count - 1) | ForEach-Object { [single]($_ * $step) })
            }
            $lgb.InterpolationColors = $cb
        }
        $brush = $lgb
    }
    'radial' {
        if ($fillColors.Count -lt 2) { throw "-Style radial needs at least 2 -Colors" }
        $cx = $bounds.X + $bounds.Width / 2
        $cy = $bounds.Y + $bounds.Height / 2
        $radius = [math]::Sqrt(($bounds.Width/2)*($bounds.Width/2) + ($bounds.Height/2)*($bounds.Height/2))
        $circle = New-Object System.Drawing.Drawing2D.GraphicsPath
        $circle.AddEllipse([single]($cx - $radius), [single]($cy - $radius), [single]($radius*2), [single]($radius*2))
        $pgb = New-Object System.Drawing.Drawing2D.PathGradientBrush $circle
        $pgb.CenterPoint = New-Object System.Drawing.PointF($cx, $cy)
        $cb = New-Object System.Drawing.Drawing2D.ColorBlend $fillColors.Count
        $cb.Colors = $fillColors
        if ($parsedStops -and $parsedStops.Count -eq $fillColors.Count) {
            $cb.Positions = @($parsedStops | ForEach-Object { [single]$_ })
        } else {
            # Default: evenly spaced, boundary(0) -> center(1)
            $step = 1.0 / ($fillColors.Count - 1)
            $cb.Positions = @(0..($fillColors.Count - 1) | ForEach-Object { [single]($_ * $step) })
        }
        $pgb.InterpolationColors = $cb
        $brush = $pgb
        $extra += $circle
    }
}
$g.FillPath($brush, $path)
$brush.Dispose()
foreach ($e in $extra) { $e.Dispose() }
$path.Dispose()

# Resolve output path (relative paths become relative to caller's cwd)
$outFull = if ([System.IO.Path]::IsPathRooted($Output)) { $Output } else { Join-Path (Get-Location).Path $Output }
$outDir = Split-Path -Parent $outFull
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
$bmp.Save($outFull, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Host "Saved: $outFull  ($width x $height)"
