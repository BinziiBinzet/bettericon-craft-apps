#Requires -Version 5.1
<# .SYNOPSIS
Derive the Grayscale and High contrast app icons from the approved Slate artwork.
Run locally after the Slate artwork changes. The Slate sources are only read.
#>
[CmdletBinding()]
param([string]$Directory)
$ErrorActionPreference = 'Stop'
if (!$Directory) { $Directory = Split-Path -Parent $MyInvocation.MyCommand.Path }
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class DerivedAppIcon
{
    static byte[] Read(string path, out int width, out int height)
    {
        using (Bitmap source = new Bitmap(path))
        using (Bitmap image = source.Clone(new Rectangle(0, 0, source.Width, source.Height), PixelFormat.Format32bppArgb)) {
            width = image.Width; height = image.Height;
            BitmapData data = image.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try {
                byte[] pixels = new byte[width * height * 4];
                for (int y = 0; y < height; y++) Marshal.Copy(IntPtr.Add(data.Scan0, y * data.Stride), pixels, y * width * 4, width * 4);
                return pixels;
            }
            finally { image.UnlockBits(data); }
        }
    }
    static void Write(byte[] pixels, int width, int height, string path)
    {
        using (Bitmap image = new Bitmap(width, height, PixelFormat.Format32bppArgb)) {
            BitmapData data = image.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
            try { for (int y = 0; y < height; y++) Marshal.Copy(pixels, y * width * 4, IntPtr.Add(data.Scan0, y * data.Stride), width * 4); }
            finally { image.UnlockBits(data); }
            image.Save(path, ImageFormat.Png);
        }
    }
    static double Luma(byte[] p, int i) { return 0.2126 * p[i + 2] + 0.7152 * p[i + 1] + 0.0722 * p[i]; }
    // Every pixel keeps its alpha and takes the gray of its own brightness.
    public static void Grayscale(string source, string destination)
    {
        int width, height; byte[] p = Read(source, out width, out height);
        for (int i = 0; i < p.Length; i += 4) { byte gray = (byte)Math.Round(Luma(p, i)); p[i] = p[i + 1] = p[i + 2] = gray; }
        Write(p, width, height, destination);
    }
    // The darker of the artwork's two tones becomes black and the lighter becomes white.
    // Flat areas turn pure; only the antialiased edges keep intermediate grays.
    public static void TwoTone(string source, string destination)
    {
        int width, height; byte[] p = Read(source, out width, out height);
        double low = 255, high = 0;
        for (int i = 0; i < p.Length; i += 4) if (p[i + 3] >= 250) { double v = Luma(p, i); if (v < low) low = v; if (v > high) high = v; }
        double middle = (low + high) / 2, dark = 0, light = 0; long darkCount = 0, lightCount = 0;
        for (int i = 0; i < p.Length; i += 4) if (p[i + 3] >= 250) { double v = Luma(p, i); if (v < middle) { dark += v; darkCount++; } else { light += v; lightCount++; } }
        dark /= Math.Max(1, darkCount); light /= Math.Max(1, lightCount);
        for (int i = 0; i < p.Length; i += 4) {
            double t = (Luma(p, i) - dark) / (light - dark);
            t = Math.Max(0, Math.Min(1, (t - 0.25) / 0.5));
            byte value = (byte)Math.Round(255 * t); p[i] = p[i + 1] = p[i + 2] = value;
        }
        Write(p, width, height, destination);
    }
}
'@
foreach ($folder in $Directory, (Join-Path $Directory '32px')) {
    foreach ($mode in 'dark', 'light') {
        $source = Join-Path $folder "betterIcon_icon_slate_$mode.png"
        [DerivedAppIcon]::Grayscale($source, (Join-Path $folder "betterIcon_icon_grayscale_$mode.png"))
        [DerivedAppIcon]::TwoTone($source, (Join-Path $folder "betterIcon_icon_contrast_$mode.png"))
    }
}
Get-ChildItem -LiteralPath $Directory -Recurse -File | Where-Object Name -match '_(grayscale|contrast)_' | Select-Object @{ n = 'File'; e = { $_.FullName.Substring($Directory.Length + 1) } }, Length
