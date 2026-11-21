# The Zubair Khata mark: a light open khata on a dark green square. Dot-source
# this file (". tool/logo.ps1") to draw it at any size. tool/brand.ps1 writes
# the Windows icon and the Android launcher PNGs with it, and
# tool/build_msix.ps1 the MSIX logos, so every icon is the same picture.
# The same geometry is drawn by KhataLogo in lib/ui/components.dart and by the
# Android vectors in android/app/src/main/res/drawable.
Add-Type -AssemblyName System.Drawing

$KhataInk = [System.Drawing.ColorTranslator]::FromHtml('#183E37')
$KhataLight = [System.Drawing.ColorTranslator]::FromHtml('#D8E9B8')

# Returns a System.Drawing.Bitmap (dispose it). The book is drawn on a
# 256-unit square: centred, as large as the shorter side times -Mark.
# -Rounded rounds the background's corners (a quarter of the shorter side);
# otherwise it fills the whole bitmap, as a tile does.
function New-KhataLogo {
    param(
        [Parameter(Mandatory)][int]$Width,
        [int]$Height = 0,
        [double]$Mark = 1.0,
        [switch]$Rounded
    )
    if ($Height -le 0) { $Height = $Width }
    $bitmap = New-Object System.Drawing.Bitmap($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $background = New-Object System.Drawing.SolidBrush $KhataInk
    $page = New-Object System.Drawing.SolidBrush $KhataLight
    $pen = New-Object System.Drawing.Pen $KhataInk, 7
    try {
        if ($Rounded) {
            $radius = [Math]::Min($Width, $Height) * 0.25
            $d = $radius * 2
            $path = New-Object System.Drawing.Drawing2D.GraphicsPath
            $path.AddArc(0, 0, $d, $d, 180, 90)
            $path.AddArc($Width - $d, 0, $d, $d, 270, 90)
            $path.AddArc($Width - $d, $Height - $d, $d, $d, 0, 90)
            $path.AddArc(0, $Height - $d, $d, $d, 90, 90)
            $path.CloseFigure()
            $graphics.FillPath($background, $path)
            $path.Dispose()
        } else {
            $graphics.FillRectangle($background, 0, 0, $Width, $Height)
        }
        $side = [Math]::Min($Width, $Height) * $Mark
        $graphics.TranslateTransform(($Width - $side) / 2, ($Height - $side) / 2)
        $graphics.ScaleTransform($side / 256, $side / 256)
        $points = [System.Drawing.PointF[]]@(
            (New-Object System.Drawing.PointF 56, 63), (New-Object System.Drawing.PointF 117, 63),
            (New-Object System.Drawing.PointF 128, 74), (New-Object System.Drawing.PointF 139, 63),
            (New-Object System.Drawing.PointF 200, 63), (New-Object System.Drawing.PointF 200, 193),
            (New-Object System.Drawing.PointF 139, 193), (New-Object System.Drawing.PointF 128, 203),
            (New-Object System.Drawing.PointF 117, 193), (New-Object System.Drawing.PointF 56, 193))
        $graphics.FillPolygon($page, $points)
        $graphics.DrawLine($pen, 128, 82, 128, 183)
        # The written lines only blur a very small icon.
        if ($side -ge 30) {
            foreach ($y in @(96, 120, 144)) {
                $graphics.DrawLine($pen, 75, $y, 108, $y)
                $graphics.DrawLine($pen, 149, $y, 182, $y)
            }
        }
    } finally {
        $pen.Dispose(); $page.Dispose(); $background.Dispose(); $graphics.Dispose()
    }
    return $bitmap
}

function Save-KhataPng {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][int]$Width, [int]$Height = 0,
        [double]$Mark = 1.0, [switch]$Rounded)
    $directory = Split-Path -Parent $Path
    if ($directory) { New-Item -ItemType Directory -Force $directory | Out-Null }
    $bitmap = New-KhataLogo -Width $Width -Height $Height -Mark $Mark -Rounded:$Rounded
    try { $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }
}

# A Windows .ico holding one PNG image for each size, so the title bar,
# taskbar, Alt+Tab and Explorer each get a sharp picture.
function Save-KhataIco {
    param([Parameter(Mandatory)][string]$Path,
        [int[]]$Sizes = @(16, 20, 24, 32, 40, 48, 64, 96, 128, 256))
    $images = foreach ($size in $Sizes) {
        $bitmap = New-KhataLogo -Width $size -Rounded
        $memory = New-Object System.IO.MemoryStream
        try {
            $bitmap.Save($memory, [System.Drawing.Imaging.ImageFormat]::Png)
            , $memory.ToArray()
        } finally { $memory.Dispose(); $bitmap.Dispose() }
    }
    $stream = [System.IO.File]::Create($Path)
    $writer = New-Object System.IO.BinaryWriter $stream
    try {
        $writer.Write([UInt16]0); $writer.Write([UInt16]1); $writer.Write([UInt16]$Sizes.Count)
        $offset = 6 + 16 * $Sizes.Count
        for ($i = 0; $i -lt $Sizes.Count; $i++) {
            $side = if ($Sizes[$i] -ge 256) { 0 } else { $Sizes[$i] }
            $writer.Write([byte]$side); $writer.Write([byte]$side)
            $writer.Write([byte]0); $writer.Write([byte]0)
            $writer.Write([UInt16]1); $writer.Write([UInt16]32)
            $writer.Write([UInt32]$images[$i].Length); $writer.Write([UInt32]$offset)
            $offset += $images[$i].Length
        }
        foreach ($image in $images) { $writer.Write($image) }
    } finally { $writer.Dispose(); $stream.Dispose() }
}
