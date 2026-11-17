using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using BetterIcon.Tray;

static class IconRenderingTests
{
    [StructLayout(LayoutKind.Sequential)] struct Header { public uint Size; public int Width, Height; public ushort Planes, Bits; public uint Compression, ImageSize; public int Xppm, Yppm; public uint Colors, Important; }
    [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr dc, ref Header info, uint usage, out IntPtr bits, IntPtr section, uint offset);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr bitmap);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr bitmap);
    [DllImport("comctl32.dll")] static extern bool ImageList_Draw(IntPtr list, int index, IntPtr dc, int x, int y, uint flags);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern int GetGuiResources(IntPtr process, int flag);
    static Bitmap Scale(Bitmap source, int size)
    {
        Bitmap scaled = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using (Graphics graphics = Graphics.FromImage(scaled)) {
            graphics.Clear(Color.Transparent); graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            graphics.DrawImage(source, new Rectangle(0, 0, size, size));
        }
        return scaled;
    }
    static byte[] Pixels(Bitmap image)
    {
        BitmapData data = image.LockBits(new Rectangle(0, 0, image.Width, image.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            int row = image.Width * 4; byte[] pixels = new byte[row * image.Height];
            for (int y = 0; y < image.Height; y++) Marshal.Copy(IntPtr.Add(data.Scan0, y * data.Stride), pixels, y * row, row);
            return pixels;
        }
        finally { image.UnlockBits(data); }
    }
    static byte[] Draw(IntPtr list, int size, Color background)
    {
        Header header = new Header { Size = 40, Width = size, Height = -size, Planes = 1, Bits = 32, ImageSize = (uint)(size * size * 4) };
        IntPtr bits, bitmap = CreateDIBSection(IntPtr.Zero, ref header, 0, out bits, IntPtr.Zero, 0);
        IntPtr dc = IntPtr.Zero, previous = IntPtr.Zero;
        if (bitmap == IntPtr.Zero) throw new Exception("Test destination allocation failed.");
        try {
            dc = CreateCompatibleDC(IntPtr.Zero); if (dc == IntPtr.Zero) throw new Exception("Test DC allocation failed.");
            previous = SelectObject(dc, bitmap);
            byte[] pixels = new byte[size * size * 4];
            for (int i = 0; i < pixels.Length; i += 4) { pixels[i] = background.B; pixels[i + 1] = background.G; pixels[i + 2] = background.R; pixels[i + 3] = 255; }
            Marshal.Copy(pixels, 0, bits, pixels.Length);
            // A real initialized native DIB/DC avoids GDI+'s GetHdc sentinel
            // surface, which can fabricate alpha errors in an offscreen test.
            if (!ImageList_Draw(list, 0, dc, 0, 0, 1)) throw new Exception("Test native drawing failed.");
            Marshal.Copy(bits, pixels, 0, pixels.Length); return pixels;
        }
        finally { if (previous != IntPtr.Zero) SelectObject(dc, previous); if (dc != IntPtr.Zero) DeleteDC(dc); DeleteObject(bitmap); }
    }
    static int BlendError(byte[] source, byte[] actual, Color background)
    {
        int worst = 0; int[] back = { background.B, background.G, background.R };
        for (int pixel = 0; pixel < source.Length; pixel += 4) for (int channel = 0; channel < 3; channel++) {
            int alpha = source[pixel + 3];
            int expected = (source[pixel + channel] * alpha + back[channel] * (255 - alpha) + 127) / 255;
            worst = Math.Max(worst, Math.Abs(actual[pixel + channel] - expected));
        }
        return worst;
    }
    public static void Run(Action<bool, string> check)
    {
        using (Bitmap original = new Bitmap(64, 64, PixelFormat.Format32bppArgb)) {
            int[] alphas = { 0, 1, 17, 64, 128, 200, 254, 255 };
            Color[] inks = { Color.Black, Color.White, Color.FromArgb(91, 184, 229) };
            for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) original.SetPixel(x, y, Color.FromArgb(alphas[x / 8], inks[(y / 8) % inks.Length]));
            foreach (bool premultiplied in new[] { false, true }) using (Bitmap source = new Bitmap(64, 64, premultiplied ? PixelFormat.Format32bppPArgb : PixelFormat.Format32bppArgb)) {
                using (Graphics graphics = Graphics.FromImage(source)) { graphics.CompositingMode = CompositingMode.SourceCopy; graphics.DrawImageUnscaled(original, 0, 0); }
                foreach (int size in new[] { 24, 136, 512 }) using (Bitmap expected = Scale(source, size)) using (IconGridView grid = new IconGridView()) {
                    grid.SetArtwork(new[] { source }, size);
                    IntPtr list = SendMessage(grid.Handle, 0x1002, IntPtr.Zero, IntPtr.Zero);
                    byte[] pixels = Pixels(expected); int worst = 0;
                    foreach (Color background in new[] { Color.Black, Color.White, Color.FromArgb(31, 39, 48), Color.FromArgb(48, 76, 117) })
                        worst = Math.Max(worst, BlendError(pixels, Draw(list, size, background), background));
                    check(worst <= 1, "The actual icon grid preserves " + (premultiplied ? "PArgb" : "RGBA") + " edge colors at " + size + "px on four backgrounds (maximum channel error " + worst + ")");
                }
            }
            using (IconGridView warmup = new IconGridView()) warmup.SetArtwork(new[] { original }, 136);
            int before = GetGuiResources(Process.GetCurrentProcess().Handle, 0);
            for (int i = 0; i < 30; i++) using (IconGridView grid = new IconGridView()) { grid.SetArtwork(new[] { original }, 136); grid.SetArtwork(new[] { original }, 48); grid.SetArtwork(new Bitmap[0], 48); }
            int after = GetGuiResources(Process.GetCurrentProcess().Handle, 0);
            check(after <= before + 1, "Repeated icon-grid replacement, clearing and disposal release native GDI resources (" + before + " to " + after + ")");
        }
    }
}
