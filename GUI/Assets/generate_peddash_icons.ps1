Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"

$assetDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$size = 1024

function New-Color([int]$a, [int]$r, [int]$g, [int]$b) {
    return [System.Drawing.Color]::FromArgb($a, $r, $g, $b)
}

function New-Bitmap {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $gfx.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $gfx.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $gfx.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $gfx.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    return @{ Bitmap = $bmp; Graphics = $gfx }
}

function Save-Canvas($canvas, [string]$fileName) {
    $path = Join-Path $assetDir $fileName
    $canvas.Bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $canvas.Graphics.Dispose()
    $canvas.Bitmap.Dispose()
}

function Fill-RoundedRect([System.Drawing.Graphics]$gfx, [System.Drawing.Brush]$brush, [float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $path.AddArc($x, $y, $d, $d, 180, 90)
    $path.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $path.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $path.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $gfx.FillPath($brush, $path)
    $path.Dispose()
}

function Draw-RoundedRect([System.Drawing.Graphics]$gfx, [System.Drawing.Pen]$pen, [float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $path.AddArc($x, $y, $d, $d, 180, 90)
    $path.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $path.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $path.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $gfx.DrawPath($pen, $path)
    $path.Dispose()
}

function Draw-GlowLine([System.Drawing.Graphics]$gfx, [System.Drawing.Color]$color, [float[]]$points, [float]$glowWidth, [float]$lineWidth) {
    $ptArray = New-Object System.Drawing.PointF[] ($points.Length / 2)
    for ($i = 0; $i -lt $ptArray.Length; $i++) {
        $ptArray[$i] = New-Object System.Drawing.PointF($points[$i * 2], $points[$i * 2 + 1])
    }

    $glowPen = New-Object System.Drawing.Pen (New-Color 70 $color.R $color.G $color.B), $glowWidth
    $glowPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $glowPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $glowPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $gfx.DrawLines($glowPen, $ptArray)
    $glowPen.Dispose()

    $linePen = New-Object System.Drawing.Pen $color, $lineWidth
    $linePen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $linePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $linePen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $gfx.DrawLines($linePen, $ptArray)
    $linePen.Dispose()
}

function Draw-TelemetryIcon {
    $canvas = New-Bitmap
    $gfx = $canvas.Graphics

    $gfx.Clear((New-Color 0 0 0 0))
    $bgBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush (
        [System.Drawing.PointF]::new(0, 0),
        [System.Drawing.PointF]::new($size, $size),
        (New-Color 255 15 17 25),
        (New-Color 255 31 35 52)
    )
    Fill-RoundedRect $gfx $bgBrush 64 64 896 896 220
    $bgBrush.Dispose()

    $panelBrush = New-Object System.Drawing.SolidBrush (New-Color 255 9 11 18)
    Fill-RoundedRect $gfx $panelBrush 124 124 776 776 170
    $panelBrush.Dispose()

    $framePen = New-Object System.Drawing.Pen (New-Color 255 76 88 116), 8
    Draw-RoundedRect $gfx $framePen 124 124 776 776 170
    $framePen.Dispose()

    $gridPen = New-Object System.Drawing.Pen (New-Color 65 120 130 160), 3
    for ($i = 0; $i -le 4; $i++) {
        $x = 200 + ($i * 140)
        $gfx.DrawLine($gridPen, $x, 210, $x, 770)
    }
    for ($i = 0; $i -le 4; $i++) {
        $y = 220 + ($i * 130)
        $gfx.DrawLine($gridPen, 190, $y, 820, $y)
    }
    $gridPen.Dispose()

    Draw-GlowLine $gfx (New-Color 255 0 243 255) @(196, 640, 270, 618, 330, 560, 400, 592, 485, 450, 560, 494, 640, 300, 720, 364, 810, 240) 26 10
    Draw-GlowLine $gfx (New-Color 255 58 255 103) @(196, 700, 270, 684, 350, 675, 420, 540, 492, 562, 570, 452, 652, 482, 732, 398, 810, 410) 22 8
    Draw-GlowLine $gfx (New-Color 255 255 86 86) @(196, 760, 255, 758, 340, 742, 430, 740, 510, 604, 585, 620, 676, 558, 754, 572, 810, 514) 20 8

    $dotBrush = New-Object System.Drawing.SolidBrush (New-Color 255 255 255 255)
    foreach ($pt in @(
        @(640, 300), @(420, 540), @(510, 604)
    )) {
        $gfx.FillEllipse($dotBrush, $pt[0] - 12, $pt[1] - 12, 24, 24)
    }
    $dotBrush.Dispose()

    Save-Canvas $canvas "PedDashIcon-Telemetry.png"
}

function Draw-MonogramIcon {
    $canvas = New-Bitmap
    $gfx = $canvas.Graphics

    $gfx.Clear((New-Color 0 0 0 0))
    $bgBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush (
        [System.Drawing.PointF]::new(70, 70),
        [System.Drawing.PointF]::new(954, 954),
        (New-Color 255 17 20 29),
        (New-Color 255 40 46 66)
    )
    Fill-RoundedRect $gfx $bgBrush 64 64 896 896 230
    $bgBrush.Dispose()

    $ringPen = New-Object System.Drawing.Pen (New-Color 255 0 243 255), 18
    $ringPen.Alignment = [System.Drawing.Drawing2D.PenAlignment]::Inset
    Draw-RoundedRect $gfx $ringPen 126 126 772 772 188
    $ringPen.Dispose()

    $barBrush = New-Object System.Drawing.SolidBrush (New-Color 255 7 10 18)
    Fill-RoundedRect $gfx $barBrush 178 178 668 668 155
    $barBrush.Dispose()

    $linePen = New-Object System.Drawing.Pen (New-Color 255 72 255 146), 22
    $linePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $linePen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $linePen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $gfx.DrawLine($linePen, 250, 738, 374, 596)
    $gfx.DrawLine($linePen, 374, 596, 498, 640)
    $gfx.DrawLine($linePen, 498, 640, 646, 378)
    $gfx.DrawLine($linePen, 646, 378, 780, 420)
    $linePen.Dispose()

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $family = New-Object System.Drawing.FontFamily("Segoe UI")
    $path.AddString("PD", $family, [int][System.Drawing.FontStyle]::Bold, 420, [System.Drawing.PointF]::new(188, 198), [System.Drawing.StringFormat]::GenericDefault)
    $family.Dispose()

    $shadowBrush = New-Object System.Drawing.SolidBrush (New-Color 90 0 0 0)
    $matrix = New-Object System.Drawing.Drawing2D.Matrix
    $matrix.Translate(10, 16)
    $shadowPath = $path.Clone()
    $shadowPath.Transform($matrix)
    $gfx.FillPath($shadowBrush, $shadowPath)
    $shadowBrush.Dispose()
    $shadowPath.Dispose()
    $matrix.Dispose()

    $fillBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush (
        [System.Drawing.PointF]::new(260, 220),
        [System.Drawing.PointF]::new(720, 720),
        (New-Color 255 235 245 255),
        (New-Color 255 131 220 255)
    )
    $gfx.FillPath($fillBrush, $path)
    $fillBrush.Dispose()

    $outlinePen = New-Object System.Drawing.Pen (New-Color 255 0 243 255), 8
    $gfx.DrawPath($outlinePen, $path)
    $outlinePen.Dispose()
    $path.Dispose()

    Save-Canvas $canvas "PedDashIcon-Monogram.png"
}

function Draw-PedalsIcon {
    $canvas = New-Bitmap
    $gfx = $canvas.Graphics

    $gfx.Clear((New-Color 0 0 0 0))
    $bgBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush (
        [System.Drawing.PointF]::new(110, 80),
        [System.Drawing.PointF]::new(904, 944),
        (New-Color 255 13 15 23),
        (New-Color 255 34 38 52)
    )
    Fill-RoundedRect $gfx $bgBrush 64 64 896 896 210
    $bgBrush.Dispose()

    $baseBrush = New-Object System.Drawing.SolidBrush (New-Color 255 20 24 34)
    Fill-RoundedRect $gfx $baseBrush 156 176 712 668 150
    $baseBrush.Dispose()

    $slotPen = New-Object System.Drawing.Pen (New-Color 255 85 95 122), 6
    for ($i = 0; $i -lt 3; $i++) {
        $x = 242 + ($i * 178)
        Draw-RoundedRect $gfx $slotPen $x 246 120 430 42
    }
    $slotPen.Dispose()

    $pedals = @(
        @{ X = 228; Y = 290; W = 146; H = 350; Accent = (New-Color 255 58 255 103) },
        @{ X = 438; Y = 240; W = 148; H = 420; Accent = (New-Color 255 255 200 71) },
        @{ X = 648; Y = 332; W = 148; H = 300; Accent = (New-Color 255 255 86 86) }
    )

    foreach ($pedal in $pedals) {
        $shadow = New-Object System.Drawing.SolidBrush (New-Color 60 0 0 0)
        Fill-RoundedRect $gfx $shadow ($pedal.X + 14) ($pedal.Y + 18) $pedal.W $pedal.H 58
        $shadow.Dispose()

        $metalBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush (
            [System.Drawing.PointF]::new($pedal.X, $pedal.Y),
            [System.Drawing.PointF]::new($pedal.X, $pedal.Y + $pedal.H),
            (New-Color 255 218 225 235),
            (New-Color 255 88 96 116)
        )
        Fill-RoundedRect $gfx $metalBrush $pedal.X $pedal.Y $pedal.W $pedal.H 58
        $metalBrush.Dispose()

        $accentPen = New-Object System.Drawing.Pen $pedal.Accent, 10
        Draw-RoundedRect $gfx $accentPen ($pedal.X + 6) ($pedal.Y + 6) ($pedal.W - 12) ($pedal.H - 12) 52
        $accentPen.Dispose()

        $holeBrush = New-Object System.Drawing.SolidBrush (New-Color 255 36 41 54)
        for ($row = 0; $row -lt 4; $row++) {
            for ($col = 0; $col -lt 2; $col++) {
                $cx = $pedal.X + 38 + ($col * 46)
                $cy = $pedal.Y + 52 + ($row * 70)
                $gfx.FillEllipse($holeBrush, $cx, $cy, 24, 24)
            }
        }
        $holeBrush.Dispose()
    }

    Draw-GlowLine $gfx (New-Color 255 0 243 255) @(194, 760, 322, 714, 462, 732, 590, 602, 710, 630, 826, 488) 24 9

    Save-Canvas $canvas "PedDashIcon-Pedals.png"
}

Draw-TelemetryIcon
Draw-MonogramIcon
Draw-PedalsIcon
