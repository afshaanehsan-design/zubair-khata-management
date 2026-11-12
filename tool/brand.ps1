# Generate the native Windows book mark from simple vector geometry.
Add-Type -AssemblyName System.Drawing
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$bitmap = New-Object System.Drawing.Bitmap 256,256
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$inkColor = [System.Drawing.ColorTranslator]::FromHtml('#183E37')
$lightColor = [System.Drawing.ColorTranslator]::FromHtml('#D8E9B8')
$graphics.Clear($inkColor)
$brush = New-Object System.Drawing.SolidBrush $lightColor
$pen = New-Object System.Drawing.Pen $inkColor,7
$points = [System.Drawing.Point[]]@((New-Object System.Drawing.Point 56,63),(New-Object System.Drawing.Point 117,63),(New-Object System.Drawing.Point 128,74),(New-Object System.Drawing.Point 139,63),(New-Object System.Drawing.Point 200,63),(New-Object System.Drawing.Point 200,193),(New-Object System.Drawing.Point 139,193),(New-Object System.Drawing.Point 128,203),(New-Object System.Drawing.Point 117,193),(New-Object System.Drawing.Point 56,193))
$graphics.FillPolygon($brush,$points)
$graphics.DrawLine($pen,128,82,128,183)
foreach($y in @(96,120,144)){$graphics.DrawLine($pen,75,$y,108,$y);$graphics.DrawLine($pen,149,$y,182,$y)}
$memory = New-Object System.IO.MemoryStream
$bitmap.Save($memory,[System.Drawing.Imaging.ImageFormat]::Png)
$bytes = $memory.ToArray()
$target = Join-Path $projectRoot 'windows/runner/resources/app_icon.ico'
$stream = [System.IO.File]::Create($target)
$writer = New-Object System.IO.BinaryWriter $stream
$writer.Write([UInt16]0);$writer.Write([UInt16]1);$writer.Write([UInt16]1)
$writer.Write([byte]0);$writer.Write([byte]0);$writer.Write([byte]0);$writer.Write([byte]0)
$writer.Write([UInt16]1);$writer.Write([UInt16]32);$writer.Write([UInt32]$bytes.Length);$writer.Write([UInt32]22);$writer.Write($bytes)
$writer.Dispose();$stream.Dispose();$memory.Dispose();$pen.Dispose();$brush.Dispose();$graphics.Dispose();$bitmap.Dispose()
