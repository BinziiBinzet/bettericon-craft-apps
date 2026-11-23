#Requires -Version 5.1
<#
Makes a lighter WebP twin of the PNG icons BetterIcon's pack catalog lists: same folder, same file name, .webp, at most
1024 px on its longer side (the largest size any platform's app icon needs). Each twin is lossy at quality 90, else 95
or 100, else lossless: the first that reaches 35 dB PSNR against the resized PNG, colors weighted by alpha, with alpha
kept exact. Downloads fetch one twin per icon: the WebP where the computer reads WebP, else the PNG.

A PNG under 32 KB gets no twin (it saves next to nothing), nor one whose twin would be more than 70% of its bytes.

Reads each source PNG at the catalog's pinned artwork revision (from the checkout when its bytes match the catalog's
SHA-256, else from git), and writes the twins under -OutputDirectory at their repository paths, with manifest.tsv
(source path and SHA-256, twin path and SHA-256, both sizes in bytes and pixels, quality, PSNR, settings) and
kept-png.tsv (PNGs left without a twin for quality). Copy the twins into the repository at the same paths, commit them,
then rebuild the catalog with Build-PackCatalog.ps1.
Windows PowerShell 5.1 (System.Drawing). -LibWebP names a libwebp.dll with the encoder, such as libwebp 1.6.0.
#>
param(
    [string]$Repository = (Split-Path -Parent $PSScriptRoot),
    [string]$Catalog = '',
    [string]$OutputDirectory = (Join-Path ([IO.Path]::GetTempPath()) 'bettericon-webp-twins'),
    [Parameter(Mandatory)][string]$LibWebP,
    [int]$Largest = 1024,
    [float[]]$Qualities = @(90, 95, 100, 0),
    [double]$Floor = 35,
    [int]$MinimumPng = 32KB,
    [double]$Keep = 0.70
)
$ErrorActionPreference = 'Stop'
if (-not $Catalog) { $Catalog = Join-Path $Repository 'Windows\PackCatalog.tsv' }
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
public static class WebPTwin {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadLibrary(string path);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool SetDllDirectory(string path);
    [DllImport("libwebp.dll")] static extern int WebPGetEncoderVersion();
    [DllImport("libwebp.dll")] static extern UIntPtr WebPEncodeBGRA(IntPtr bgra, int width, int height, int stride, float quality, out IntPtr output);
    [DllImport("libwebp.dll")] static extern UIntPtr WebPEncodeLosslessBGRA(IntPtr bgra, int width, int height, int stride, out IntPtr output);
    [DllImport("libwebp.dll")] static extern void WebPFree(IntPtr pointer);
    [DllImport("libwebp.dll")] static extern IntPtr WebPDecodeBGRA(byte[] data, UIntPtr size, out int width, out int height);
    // PSNR in dB of a twin against the resized source pixels, colors weighted by alpha; -1 when alpha differs or it cannot be read.
    public static double Psnr(byte[] webp, byte[] source) {
        int w, h; IntPtr decoded = WebPDecodeBGRA(webp, (UIntPtr)webp.Length, out w, out h);
        if (decoded == IntPtr.Zero || w * h * 4 != source.Length) { if (decoded != IntPtr.Zero) WebPFree(decoded); return -1; }
        byte[] twin = new byte[source.Length]; Marshal.Copy(decoded, twin, 0, twin.Length); WebPFree(decoded);
        double error = 0, weight = 0;
        for (int i = 0; i < source.Length; i += 4) {
            if (source[i + 3] != twin[i + 3]) return -1;
            double a = source[i + 3] / 255.0;
            for (int c = 0; c < 3; c++) { double d = (source[i + c] - twin[i + c]) * a; error += d * d; }
            weight += 3 * a;
        }
        double mse = weight > 0 ? error / weight : 0;
        return mse <= 0 ? 99 : 10 * Math.Log10(255.0 * 255.0 / mse);
    }
    public static string Load(string path) {
        SetDllDirectory(Path.GetDirectoryName(path));
        if (LoadLibrary(path) == IntPtr.Zero) throw new Exception("libwebp did not load: " + Marshal.GetLastWin32Error());
        int v = WebPGetEncoderVersion();
        return ((v >> 16) & 0xff) + "." + ((v >> 8) & 0xff) + "." + (v & 0xff);
    }
    // Returns the WebP bytes at the first of the qualities that reaches the PSNR floor, or null; with the sizes and PSNR.
    public static byte[] Make(byte[] png, int largest, float[] qualities, double floor, out Size source, out Size twin, out double psnr, out float used) {
        psnr = -1; used = 0;
        using (MemoryStream input = new MemoryStream(png))
        using (Bitmap loaded = new Bitmap(input)) {
            source = loaded.Size;
            double factor = Math.Min(1.0, (double)largest / Math.Max(loaded.Width, loaded.Height));
            int w = Math.Max(1, (int)Math.Round(loaded.Width * factor)), h = Math.Max(1, (int)Math.Round(loaded.Height * factor));
            twin = new Size(w, h);
            // Resample with premultiplied alpha, so transparent edges keep no halo, then hand libwebp straight alpha.
            using (Bitmap scaled = new Bitmap(w, h, PixelFormat.Format32bppPArgb)) {
                using (Graphics g = Graphics.FromImage(scaled)) {
                    g.Clear(Color.Transparent); g.CompositingMode = CompositingMode.SourceCopy;
                    g.InterpolationMode = factor < 1.0 ? InterpolationMode.HighQualityBicubic : InterpolationMode.NearestNeighbor;
                    g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    using (ImageAttributes wrap = new ImageAttributes()) {
                        wrap.SetWrapMode(WrapMode.TileFlipXY);
                        g.DrawImage(loaded, new Rectangle(0, 0, w, h), 0, 0, loaded.Width, loaded.Height, GraphicsUnit.Pixel, wrap);
                    }
                }
                using (Bitmap straight = scaled.Clone(new Rectangle(0, 0, w, h), PixelFormat.Format32bppArgb)) {
                    BitmapData data = straight.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                    try {
                        byte[] pixels = new byte[w * h * 4];
                        for (int y = 0; y < h; y++) Marshal.Copy(data.Scan0 + y * data.Stride, pixels, y * w * 4, w * 4);
                        // Lossy at each quality in turn, then lossless (quality 0 in the record), which always reaches the floor.
                        foreach (float quality in qualities) {
                            IntPtr output; UIntPtr size = quality > 0 ? WebPEncodeBGRA(data.Scan0, w, h, data.Stride, quality, out output) : WebPEncodeLosslessBGRA(data.Scan0, w, h, data.Stride, out output);
                            if (output == IntPtr.Zero || size == UIntPtr.Zero) throw new Exception("libwebp could not encode the image.");
                            byte[] bytes = new byte[(long)size.ToUInt64()]; Marshal.Copy(output, bytes, 0, bytes.Length); WebPFree(output);
                            psnr = Psnr(bytes, pixels); used = quality;
                            if (psnr >= floor) return bytes;
                        }
                        return null;
                    }
                    finally { straight.UnlockBits(data); }
                }
            }
        }
    }
}
'@
$encoder = [WebPTwin]::Load($LibWebP)
$lines = Get-Content -LiteralPath $Catalog -Encoding UTF8
# A blob's bytes from git, with the path passed as a UTF-16 argument rather than through a console code page.
function Get-GitBlob([string]$Spec) {
    $start = New-Object System.Diagnostics.ProcessStartInfo 'git.exe'
    $start.Arguments = '-C "' + $Repository + '" cat-file blob "' + $Spec + '"'
    $start.UseShellExecute = $false; $start.RedirectStandardOutput = $true; $start.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($start)
    $buffer = New-Object System.IO.MemoryStream
    $process.StandardOutput.BaseStream.CopyTo($buffer); $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "git could not read $Spec." }
    return $buffer.ToArray()
}
$revision = $lines[0].Trim()
$sources = @($lines | Select-Object -Skip 1 | ForEach-Object { $f = $_ -split "`t"; [pscustomobject]@{ Path = $f[2]; Sha256 = $f[3].ToLowerInvariant() } } |
    Where-Object { $_.Path -like '*.png' } | Sort-Object Path -Unique)
"libwebp encoder $encoder; artwork revision $revision; $($sources.Count) PNG icons in the catalog"
if (Test-Path -LiteralPath $OutputDirectory) { throw "$OutputDirectory already exists." }
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$sha = [Security.Cryptography.SHA256]::Create()
$hex = { param($bytes) ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
$manifest = New-Object System.Collections.Generic.List[string]
$manifest.Add("# source`tsource_sha256`ttwin`ttwin_sha256`tpng_bytes`ttwin_bytes`tsource_px`ttwin_px`tquality`tpsnr_db`tsettings")
$settings = "libwebp $encoder; longest side <= $Largest px; premultiplied high-quality bicubic; PNG >= $MinimumPng bytes, twin <= $($Keep * 100)% of it; the first of lossy quality $(($Qualities | Where-Object { $_ -gt 0 }) -join ', ') (alpha lossless) reaching $Floor dB PSNR$(if ($Qualities -contains 0) { ', else lossless' })"
$made = 0; $skipped = 0; $small = 0; $faint = 0; $pngTotal = 0L; $twinTotal = 0L; $keptPng = 0L
$faintRows = New-Object System.Collections.Generic.List[string]
$faintRows.Add("# source`tpng_bytes`tbest_psnr_db")
foreach ($source in $sources) {
    $local = Join-Path $Repository ($source.Path -replace '/', '\')
    $bytes = if (Test-Path -LiteralPath $local) { [IO.File]::ReadAllBytes($local) } else { $null }
    if (-not $bytes -or (& $hex $bytes) -ne $source.Sha256) {
        $bytes = Get-GitBlob ($revision + ':' + $source.Path)
        if ((& $hex $bytes) -ne $source.Sha256) { throw "$($source.Path) does not match the catalog's SHA-256 at $revision." }
    }
    $pngTotal += $bytes.Length
    if ($bytes.Length -lt $MinimumPng) { $small++; continue }
    $sourceSize = New-Object System.Drawing.Size; $twinSize = New-Object System.Drawing.Size; $psnr = 0.0; $used = [float]0
    $webp = [WebPTwin]::Make($bytes, $Largest, $Qualities, $Floor, [ref]$sourceSize, [ref]$twinSize, [ref]$psnr, [ref]$used)
    if (-not $webp) { $faint++; $faintRows.Add(($source.Path, $bytes.Length, [math]::Round($psnr, 1)) -join "`t"); continue }
    if ($webp.Length -gt $bytes.Length * $Keep) { $skipped++; continue }
    $twinPath = $source.Path.Substring(0, $source.Path.Length - 4) + '.webp'
    $target = Join-Path $OutputDirectory ($twinPath -replace '/', '\')
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
    [IO.File]::WriteAllBytes($target, $webp)
    $manifest.Add(($source.Path, $source.Sha256, $twinPath, (& $hex $webp), $bytes.Length, $webp.Length, "$($sourceSize.Width)x$($sourceSize.Height)", "$($twinSize.Width)x$($twinSize.Height)", $used, [math]::Round($psnr, 1), $settings) -join "`t")
    $made++; $twinTotal += $webp.Length; $keptPng += $bytes.Length
}
[IO.File]::WriteAllLines((Join-Path $OutputDirectory 'manifest.tsv'), $manifest, (New-Object System.Text.UTF8Encoding $false))
[IO.File]::WriteAllLines((Join-Path $OutputDirectory 'kept-png.tsv'), $faintRows, (New-Object System.Text.UTF8Encoding $false))
'twins {0}; kept PNG only: {1} under {2:N0} KB, {3} under the PSNR floor, {4} saving too little' -f $made, $small, ($MinimumPng / 1KB), $faint, $skipped
'PNG {0:N1} MB in all; the {1} twinned PNGs {2:N1} MB -> twins {3:N1} MB ({4:P1}); a WebP-capable download {5:N1} MB' -f ($pngTotal / 1MB), $made, ($keptPng / 1MB), ($twinTotal / 1MB), $(if ($keptPng) { $twinTotal / $keptPng } else { 0 }), (($pngTotal - $keptPng + $twinTotal) / 1MB)
