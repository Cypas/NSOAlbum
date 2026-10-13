$ErrorActionPreference = 'Stop'

if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [Runtime.InteropServices.OSPlatform]::Windows
)) {
    throw 'Generate these checked-in PNG assets on Windows with System.Drawing.'
}

Add-Type -AssemblyName System.Drawing
$projectRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $projectRoot 'assets/tray/app_icon.png'
$resourceRoot = Join-Path $projectRoot 'android/app/src/main/res'
$source = [System.Drawing.Image]::FromFile($sourcePath)

function Save-LauncherImage {
    param(
        [string]$Path,
        [int]$CanvasSize,
        [int]$ArtworkSize
    )
    $bitmap = [System.Drawing.Bitmap]::new(
        $CanvasSize, $CanvasSize,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    )
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $attributes = [System.Drawing.Imaging.ImageAttributes]::new()
    try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $attributes.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
        $margin = ($CanvasSize - $ArtworkSize) / 2.0
        $rectangle = [System.Drawing.Rectangle]::new(
            [int][Math]::Round($margin), [int][Math]::Round($margin),
            $ArtworkSize, $ArtworkSize
        )
        $graphics.DrawImage(
            $source, $rectangle,
            [single]0, [single]0, [single]$source.Width, [single]$source.Height,
            [System.Drawing.GraphicsUnit]::Pixel, $attributes
        )
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $attributes.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

try {
    $densities = [ordered]@{
        mdpi = 1.0
        hdpi = 1.5
        xhdpi = 2.0
        xxhdpi = 3.0
        xxxhdpi = 4.0
    }
    foreach ($density in $densities.GetEnumerator()) {
        $directory = Join-Path $resourceRoot "mipmap-$($density.Key)"
        $null = New-Item -ItemType Directory -Path $directory -Force
        $legacySize = [int](48 * $density.Value)
        Save-LauncherImage -Path (Join-Path $directory 'ic_launcher.png') `
            -CanvasSize $legacySize -ArtworkSize $legacySize
        # Android adaptive layers are 108dp; keep the desktop artwork centered
        # within 66dp so launcher masks retain the main illustration.
        Save-LauncherImage -Path (Join-Path $directory 'ic_launcher_foreground.png') `
            -CanvasSize ([int](108 * $density.Value)) `
            -ArtworkSize ([int](66 * $density.Value))
    }
} finally {
    $source.Dispose()
}

Write-Host 'Generated Android launcher resources from the shared PC brand PNG.'
