param(
    [string]$OutputDir = (Resolve-Path (Join-Path $PSScriptRoot "..\..\WorkoutApp\Assets.xcassets\AppIcon.appiconset")).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing

function Scale-Value {
    param(
        [double]$Value,
        [int]$CanvasSize
    )

    return [single]($Value * $CanvasSize / 1024.0)
}

function New-ArgbColor {
    param(
        [int]$A,
        [int]$R,
        [int]$G,
        [int]$B
    )

    return [System.Drawing.Color]::FromArgb($A, $R, $G, $B)
}

function New-RoundRectPath {
    param(
        [float]$X,
        [float]$Y,
        [float]$Width,
        [float]$Height,
        [float]$Radius
    )

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $diameter = $Radius * 2

    $path.AddArc($X, $Y, $diameter, $diameter, 180, 90)
    $path.AddArc($X + $Width - $diameter, $Y, $diameter, $diameter, 270, 90)
    $path.AddArc($X + $Width - $diameter, $Y + $Height - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($X, $Y + $Height - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()

    return $path
}

function Add-RadialGlow {
    param(
        [System.Drawing.Graphics]$Graphics,
        [float]$X,
        [float]$Y,
        [float]$Width,
        [float]$Height,
        [System.Drawing.Color]$CenterColor
    )

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddEllipse($X, $Y, $Width, $Height)
    $brush = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
    $brush.CenterColor = $CenterColor
    $brush.SurroundColors = [System.Drawing.Color[]]@(
        [System.Drawing.Color]::FromArgb(0, $CenterColor.R, $CenterColor.G, $CenterColor.B)
    )

    $Graphics.FillEllipse($brush, $X, $Y, $Width, $Height)

    $brush.Dispose()
    $path.Dispose()
}

function New-LinearGradientBrush {
    param(
        [System.Drawing.RectangleF]$Rect,
        [System.Drawing.Color[]]$Colors,
        [single[]]$Positions,
        [float]$Angle = 45
    )

    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $Rect,
        $Colors[0],
        $Colors[$Colors.Length - 1],
        $Angle
    )

    $blend = New-Object System.Drawing.Drawing2D.ColorBlend
    $blend.Colors = $Colors
    $blend.Positions = $Positions
    $brush.InterpolationColors = $blend

    return $brush
}

function Draw-MotionPlatesIcon {
    param(
        [System.Drawing.Graphics]$Graphics,
        [int]$CanvasSize
    )

    $graphicsRect = New-Object System.Drawing.RectangleF(0, 0, $CanvasSize, $CanvasSize)

    $backgroundBrush = New-LinearGradientBrush -Rect $graphicsRect -Angle 45 -Colors ([System.Drawing.Color[]]@(
        (New-ArgbColor 255 8 10 15),
        (New-ArgbColor 255 18 23 41),
        (New-ArgbColor 255 5 6 10)
    )) -Positions ([single[]](0.0, 0.46, 1.0))

    $Graphics.FillRectangle($backgroundBrush, $graphicsRect)
    $backgroundBrush.Dispose()

    Add-RadialGlow -Graphics $Graphics `
        -X (Scale-Value 24 $CanvasSize) `
        -Y (Scale-Value 528 $CanvasSize) `
        -Width (Scale-Value 460 $CanvasSize) `
        -Height (Scale-Value 388 $CanvasSize) `
        -CenterColor (New-ArgbColor 76 54 92 255)

    Add-RadialGlow -Graphics $Graphics `
        -X (Scale-Value 554 $CanvasSize) `
        -Y (Scale-Value 72 $CanvasSize) `
        -Width (Scale-Value 432 $CanvasSize) `
        -Height (Scale-Value 364 $CanvasSize) `
        -CenterColor (New-ArgbColor 88 56 224 245)

    $points = [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF((Scale-Value 190 $CanvasSize), (Scale-Value 710 $CanvasSize))),
        (New-Object System.Drawing.PointF((Scale-Value 276 $CanvasSize), (Scale-Value 710 $CanvasSize))),
        (New-Object System.Drawing.PointF((Scale-Value 390 $CanvasSize), (Scale-Value 590 $CanvasSize))),
        (New-Object System.Drawing.PointF((Scale-Value 520 $CanvasSize), (Scale-Value 500 $CanvasSize))),
        (New-Object System.Drawing.PointF((Scale-Value 640 $CanvasSize), (Scale-Value 422 $CanvasSize))),
        (New-Object System.Drawing.PointF((Scale-Value 820 $CanvasSize), (Scale-Value 292 $CanvasSize)))
    )

    $trackPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $trackPath.AddCurve($points, 0.48)

    $trackBrush = New-LinearGradientBrush -Rect $graphicsRect -Angle 35 -Colors ([System.Drawing.Color[]]@(
        (New-ArgbColor 255 140 51 255),
        (New-ArgbColor 255 54 92 255),
        (New-ArgbColor 255 56 224 245),
        (New-ArgbColor 255 186 255 64)
    )) -Positions ([single[]](0.0, 0.42, 0.78, 1.0))

    $glowBrush = New-LinearGradientBrush -Rect $graphicsRect -Angle 35 -Colors ([System.Drawing.Color[]]@(
        (New-ArgbColor 72 140 51 255),
        (New-ArgbColor 72 54 92 255),
        (New-ArgbColor 80 56 224 245),
        (New-ArgbColor 60 186 255 64)
    )) -Positions ([single[]](0.0, 0.42, 0.78, 1.0))

    $glowPenWide = New-Object System.Drawing.Pen($glowBrush, (Scale-Value 118 $CanvasSize))
    $glowPenWide.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $glowPenWide.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $glowPenWide.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round

    $glowPenTight = New-Object System.Drawing.Pen($glowBrush, (Scale-Value 94 $CanvasSize))
    $glowPenTight.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $glowPenTight.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $glowPenTight.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round

    $trackPen = New-Object System.Drawing.Pen($trackBrush, (Scale-Value 72 $CanvasSize))
    $trackPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $trackPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $trackPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round

    $highlightPen = New-Object System.Drawing.Pen((New-ArgbColor 34 255 255 255), (Scale-Value 10 $CanvasSize))
    $highlightPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $highlightPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $highlightPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round

    $Graphics.DrawPath($glowPenWide, $trackPath)
    $Graphics.DrawPath($glowPenTight, $trackPath)
    $Graphics.DrawPath($trackPen, $trackPath)
    $Graphics.DrawPath($highlightPen, $trackPath)

    $glowPenWide.Dispose()
    $glowPenTight.Dispose()
    $trackPen.Dispose()
    $highlightPen.Dispose()
    $trackBrush.Dispose()
    $glowBrush.Dispose()
    $trackPath.Dispose()

    $plateFillTop = New-ArgbColor 255 239 244 255
    $plateFillBottom = New-ArgbColor 255 154 168 189
    $plateStroke = New-ArgbColor 36 255 255 255
    $holeColor = New-ArgbColor 255 10 13 19

    $nodes = @(
        @{ X = 282; Y = 708; Radius = 88; Glow = (New-ArgbColor 44 140 51 255) },
        @{ X = 520; Y = 500; Radius = 104; Glow = (New-ArgbColor 54 54 92 255) },
        @{ X = 760; Y = 332; Radius = 118; Glow = (New-ArgbColor 62 56 224 245) }
    )

    foreach ($node in $nodes) {
        $cx = Scale-Value $node.X $CanvasSize
        $cy = Scale-Value $node.Y $CanvasSize
        $radius = Scale-Value $node.Radius $CanvasSize
        $diameter = $radius * 2
        $left = $cx - $radius
        $top = $cy - $radius

        Add-RadialGlow -Graphics $Graphics `
            -X ($left - $radius * 0.44) `
            -Y ($top - $radius * 0.44) `
            -Width ($diameter * 1.88) `
            -Height ($diameter * 1.88) `
            -CenterColor $node.Glow

        $nodeRect = New-Object System.Drawing.RectangleF($left, $top, $diameter, $diameter)
        $nodeBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($nodeRect, $plateFillTop, $plateFillBottom, 45.0)
        $Graphics.FillEllipse($nodeBrush, $nodeRect)
        $nodeBrush.Dispose()

        $nodePen = New-Object System.Drawing.Pen($plateStroke, (Scale-Value 2 $CanvasSize))
        $Graphics.DrawEllipse($nodePen, $left, $top, $diameter, $diameter)
        $nodePen.Dispose()

        $innerRadius = $radius * 0.32
        $innerDiameter = $innerRadius * 2
        $Graphics.FillEllipse(
            (New-Object System.Drawing.SolidBrush($holeColor)),
            $cx - $innerRadius,
            $cy - $innerRadius,
            $innerDiameter,
            $innerDiameter
        )

        $highlightBrush = New-Object System.Drawing.SolidBrush((New-ArgbColor 28 255 255 255))
        $Graphics.FillEllipse(
            $highlightBrush,
            $cx - ($radius * 0.46),
            $cy - ($radius * 0.5),
            $radius * 0.62,
            $radius * 0.28
        )
        $highlightBrush.Dispose()
    }

    $bottomPath = New-RoundRectPath `
        -X (Scale-Value 126 $CanvasSize) `
        -Y (Scale-Value 772 $CanvasSize) `
        -Width (Scale-Value 152 $CanvasSize) `
        -Height (Scale-Value 16 $CanvasSize) `
        -Radius (Scale-Value 8 $CanvasSize)

    $bottomBrush = New-Object System.Drawing.SolidBrush((New-ArgbColor 30 255 255 255))
    $Graphics.FillPath($bottomBrush, $bottomPath)
    $bottomBrush.Dispose()
    $bottomPath.Dispose()

    $accentPath = New-RoundRectPath `
        -X (Scale-Value 778 $CanvasSize) `
        -Y (Scale-Value 240 $CanvasSize) `
        -Width (Scale-Value 132 $CanvasSize) `
        -Height (Scale-Value 28 $CanvasSize) `
        -Radius (Scale-Value 14 $CanvasSize)

    $accentMatrix = New-Object System.Drawing.Drawing2D.Matrix
    $accentMatrix.RotateAt(
        -38,
        (New-Object System.Drawing.PointF((Scale-Value 844 $CanvasSize), (Scale-Value 254 $CanvasSize)))
    )
    $accentPath.Transform($accentMatrix)

    $accentBrush = New-Object System.Drawing.SolidBrush((New-ArgbColor 240 243 250 255))
    $Graphics.FillPath($accentBrush, $accentPath)
    $accentBrush.Dispose()
    $accentPath.Dispose()
    $accentMatrix.Dispose()
}

function New-MasterBitmap {
    param([int]$Size)

    $bitmap = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality

    Draw-MotionPlatesIcon -Graphics $graphics -CanvasSize $Size

    $graphics.Dispose()
    return $bitmap
}

function Save-ResizedPng {
    param(
        [System.Drawing.Bitmap]$Source,
        [int]$TargetSize,
        [string]$Path
    )

    $bitmap = New-Object System.Drawing.Bitmap($TargetSize, $TargetSize, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $graphics.DrawImage($Source, 0, 0, $TargetSize, $TargetSize)
    $graphics.Dispose()

    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
}

$null = New-Item -ItemType Directory -Force -Path $OutputDir
Get-ChildItem -Path $OutputDir -Filter "icon-*.png" -ErrorAction SilentlyContinue | Remove-Item -Force

$master = New-MasterBitmap -Size 1024

$slots = @(
    @{ Filename = "icon-20@2x.png"; Pixels = 40 },
    @{ Filename = "icon-20@3x.png"; Pixels = 60 },
    @{ Filename = "icon-29@2x.png"; Pixels = 58 },
    @{ Filename = "icon-29@3x.png"; Pixels = 87 },
    @{ Filename = "icon-40@2x.png"; Pixels = 80 },
    @{ Filename = "icon-40@3x.png"; Pixels = 120 },
    @{ Filename = "icon-60@2x.png"; Pixels = 120 },
    @{ Filename = "icon-60@3x.png"; Pixels = 180 },
    @{ Filename = "icon-1024.png"; Pixels = 1024 }
)

foreach ($slot in $slots) {
    Save-ResizedPng -Source $master -TargetSize $slot.Pixels -Path (Join-Path $OutputDir $slot.Filename)
}

$master.Dispose()
Write-Output "Generated Motion Plates app icons in $OutputDir"
