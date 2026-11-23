// Local native appearance tests. All writes stay in the existing disposable fixture.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;
using BetterIcon.Tray;

static class AppearanceTests
{
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr SetActiveWindow(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr GetActiveWindow();
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr window, int index);
    [DllImport("user32.dll")] static extern bool RedrawWindow(IntPtr window, IntPtr update, IntPtr region, uint flags);
    [DllImport("user32.dll", SetLastError = true)] static extern bool GetKeyboardState([Out] byte[] state);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetKeyboardState(byte[] state);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out uint value, int size);
    [DllImport("user32.dll")] static extern int GetWindowRgn(IntPtr window, IntPtr region);
    [DllImport("gdi32.dll")] static extern IntPtr CreateRectRgn(int left, int top, int right, int bottom);
    [DllImport("gdi32.dll")] static extern bool PtInRegion(IntPtr region, int x, int y);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr value);
    static readonly BindingFlags instance = BindingFlags.Instance | BindingFlags.NonPublic;
    static object Field(LauncherForm form, string name) { return typeof(LauncherForm).GetField(name, instance).GetValue(form); }
    static void Invoke(LauncherForm form, string name, params object[] args) { typeof(LauncherForm).GetMethod(name, instance).Invoke(form, args); }
    static string Pixels(Image image)
    {
        using (Bitmap bitmap = new Bitmap(image)) using (MemoryStream data = new MemoryStream()) {
            bitmap.Save(data, System.Drawing.Imaging.ImageFormat.Png);
            using (SHA256 hash = SHA256.Create()) return Convert.ToBase64String(hash.ComputeHash(data.ToArray()));
        }
    }
    static string IconPixels(Icon icon) { using (Bitmap image = icon.ToBitmap()) return Pixels(image); }
    static double Channel(byte c) { double n = c / 255.0; return n <= 0.04045 ? n / 12.92 : Math.Pow((n + 0.055) / 1.055, 2.4); }
    static double Light(Color c) { return Channel(c.R) * 0.2126 + Channel(c.G) * 0.7152 + Channel(c.B) * 0.0722; }
    static double Contrast(Color a, Color b) { double x = Light(a), y = Light(b); return (Math.Max(x, y) + 0.05) / (Math.Min(x, y) + 0.05); }
    static bool Same(Color a, Color b) { return a.ToArgb() == b.ToArgb(); }
    static bool Near(Color a, Color b, int levels) { return Math.Abs(a.R - b.R) <= levels && Math.Abs(a.G - b.G) <= levels && Math.Abs(a.B - b.B) <= levels; }
    // True when a color lies on the straight line from one color toward another, within rounding.
    static bool Along(Color from, Color to, Color color)
    {
        int[] a = { from.R, from.G, from.B }, b = { to.R, to.G, to.B }, c = { color.R, color.G, color.B };
        int channel = Enumerable.Range(0, 3).OrderByDescending(i => Math.Abs(b[i] - a[i])).First();
        if (b[channel] == a[channel]) return Enumerable.Range(0, 3).All(i => c[i] == a[i]);
        double t = (c[channel] - a[channel]) / (double)(b[channel] - a[channel]);
        return t >= 0 && t <= 1 && Enumerable.Range(0, 3).All(i => Math.Abs(c[i] - (a[i] + t * (b[i] - a[i]))) <= 1.5);
    }
    [StructLayout(LayoutKind.Sequential)] struct NativeRect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", EntryPoint = "SendMessageW")] static extern IntPtr SendRect(IntPtr window, int message, IntPtr wParam, ref NativeRect rect);
    [StructLayout(LayoutKind.Sequential)] struct BarInfo
    {
        public int Size; public NativeRect Bar; public int Button, ThumbTop, ThumbBottom, Reserved;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)] public int[] States;
    }
    [StructLayout(LayoutKind.Sequential)] struct ComboInfo { public int Size; public NativeRect Item, Button; public int ButtonState; public IntPtr Combo, Edit, List; }
    [DllImport("user32.dll")] static extern bool GetScrollBarInfo(IntPtr window, int id, ref BarInfo info);
    [DllImport("user32.dll")] static extern bool GetComboBoxInfo(IntPtr combo, ref ComboInfo info);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr window, IntPtr device, uint flags);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window, int command);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr window, int flags);
    // The scroll bar skin AppAppearance keeps for a control, or null.
    static ScrollSkin SkinOf(Control control)
    {
        object table = typeof(AppAppearance).GetField("hooks", BindingFlags.Static | BindingFlags.NonPublic).GetValue(null);
        object[] call = { control, null };
        if (!(bool)table.GetType().GetMethod("TryGetValue").Invoke(table, call) || call[1] == null) return null;
        return (ScrollSkin)call[1].GetType().GetField("Skin").GetValue(call[1]);
    }
    static Bitmap PrintHandle(IntPtr window, Size size)
    {
        Bitmap image = new Bitmap(Math.Max(1, size.Width), Math.Max(1, size.Height));
        using (Graphics canvas = Graphics.FromImage(image)) { IntPtr device = canvas.GetHdc(); try { PrintWindow(window, device, 0); } finally { canvas.ReleaseHdc(device); } }
        return image;
    }
    // Problems with the skin over one scroll bar of a window, or null: shown, exactly over the bar, above it, letting the
    // mouse through to it, and drawn with the theme's track and thumb.
    static string SkinProblems(Control owner, IntPtr target, int id, int slot, AppearancePalette p)
    {
        ScrollSkin skin = SkinOf(owner);
        if (skin == null || skin.Handle != target) return "no skin watches the window";
        BarInfo info = new BarInfo { States = new int[6] }; info.Size = Marshal.SizeOf(typeof(BarInfo));
        if (!GetScrollBarInfo(target, id, ref info) || (info.States[0] & 0x8000) != 0) return "the scroll bar is hidden";
        Rectangle bar = Rectangle.FromLTRB(info.Bar.Left, info.Bar.Top, info.Bar.Right, info.Bar.Bottom);
        IntPtr overlay = skin.SkinHandles()[slot]; Rectangle bounds = skin.SkinBounds()[slot];
        if (overlay == IntPtr.Zero || !IsWindowVisible(overlay)) return "the skin is not shown";
        if (bounds != bar) return "the skin covers " + bounds + " but the bar is at " + bar;
        // The skin lies above the window it covers: walking down from the skin (GW_HWNDNEXT) reaches it. A dropdown and its
        // popup skin are both windows of the desktop, so the same walk holds for them.
        bool above = false;
        for (IntPtr window = GetWindow(overlay, 2); window != IntPtr.Zero && !above; window = GetWindow(window, 2)) above = window == target;
        if (!above) return "the skin is not above the window it covers";
        if (SendMessage(overlay, 0x0084, IntPtr.Zero, new IntPtr(((bar.Y + 3) << 16) | ((bar.X + 3) & 0xFFFF))).ToInt64() != -1) return "the skin takes the mouse instead of the bar beneath";
        bool vertical = id == -5 || (id == -4 && bar.Height > bar.Width);
        int length = vertical ? bar.Height : bar.Width, thickness = vertical ? bar.Width : bar.Height;
        int trackAt = info.ThumbBottom + 6 < length - info.Button ? (info.ThumbBottom + length - info.Button) / 2 : info.Button + (info.ThumbTop - info.Button) / 2;
        Point track = vertical ? new Point(1, trackAt) : new Point(trackAt, 1);
        Point thumb = vertical ? new Point(thickness / 2, (info.ThumbTop + info.ThumbBottom) / 2) : new Point((info.ThumbTop + info.ThumbBottom) / 2, thickness / 2);
        using (Bitmap image = PrintHandle(overlay, bar.Size)) {
            Color t = image.GetPixel(track.X, track.Y), m = image.GetPixel(thumb.X, thumb.Y);
            if (!Same(t, p.ScrollTrack)) return "track pixel " + track + " was " + t + ", expected " + p.ScrollTrack;
            if (!Same(m, p.ScrollThumb) && !Same(m, p.ScrollThumbHot) && !Same(m, p.ScrollThumbPressed)) return "thumb pixel " + thumb + " was " + m + ", expected " + p.ScrollThumb;
        }
        return null;
    }
    // True when no skin of the control is shown, as in high contrast.
    static bool SkinsHidden(Control owner)
    {
        ScrollSkin skin = SkinOf(owner);
        return skin == null || skin.SkinHandles().All(handle => handle == IntPtr.Zero || !IsWindowVisible(handle));
    }
    static Bitmap Render(Control control)
    {
        Bitmap image = new Bitmap(control.Width, control.Height);
        control.Refresh(); control.DrawToBitmap(image, new Rectangle(Point.Empty, control.Size));
        return image;
    }
    // Problems with a list's dropdown button against the palette, or null. The geometry is WinForms' flat combo's.
    // With a picture, that picture is checked in place of a fresh print of the list: the one a list sent to the screen.
    static string ListButtonProblems(ComboBox list, AppearancePalette p, Bitmap picture = null)
    {
        int width = list.ClientSize.Width, height = list.ClientSize.Height;
        int button = SystemInformation.GetHorizontalScrollBarArrowWidthForDpi(list.DeviceDpi), left = width - button - 1;
        Point arrow = new Point(left + button / 2 + button % 2, 1 + (height - 2) / 2);
        Color glyph = list.Enabled ? p.ControlGlyph : Color.FromArgb((p.ControlGlyph.R + p.ControlFace.R) / 2, (p.ControlGlyph.G + p.ControlFace.G) / 2, (p.ControlGlyph.B + p.ControlFace.B) / 2);
        if (list.ClientSize != list.Size) return "the list has a nonclient frame";
        if (picture != null && picture.Size != list.ClientSize) return "the picture is " + picture.Width + "x" + picture.Height + ", the list " + width + "x" + height;
        using (Bitmap image = picture == null ? Render(list) : new Bitmap(picture)) {
            var expected = new[] {
                new { X = left + 3, Y = 3, Color = p.ControlFace, Part = "face" }, new { X = width - 3, Y = height - 4, Color = p.ControlFace, Part = "face" },
                new { X = left, Y = height / 2, Color = p.ControlLight, Part = "line beside the text" },
                new { X = width - 1, Y = height / 2, Color = p.ControlOutline, Part = "outline" }, new { X = left + 3, Y = 0, Color = p.ControlOutline, Part = "outline" }, new { X = left + 3, Y = height - 1, Color = p.ControlOutline, Part = "outline" },
                new { X = 0, Y = height / 2, Color = p.Border, Part = "border" }, new { X = left - 4, Y = 0, Color = p.Border, Part = "border" },
                new { X = 1, Y = height / 2, Color = p.Input, Part = "inner frame" }, new { X = 2, Y = height / 2, Color = p.Input, Part = "inner frame" }, new { X = left - 1, Y = height / 2, Color = p.Input, Part = "inner frame" } };
            foreach (var point in expected) if (!Same(image.GetPixel(point.X, point.Y), point.Color)) return point.Part + " pixel " + point.X + "," + point.Y + " was " + image.GetPixel(point.X, point.Y) + ", expected " + point.Color;
            if (!Near(image.GetPixel(arrow.X, arrow.Y), glyph, 1)) return "arrow pixel " + arrow.X + "," + arrow.Y + " was " + image.GetPixel(arrow.X, arrow.Y) + ", expected " + glyph;
        }
        return null;
    }
    // Problems with the slider's channel against the palette, or null.
    static string ChannelProblems(TrackBar slider, AppearancePalette p)
    {
        NativeRect channel = new NativeRect(), thumb = new NativeRect();
        SendRect(slider.Handle, 0x041A, IntPtr.Zero, ref channel); SendRect(slider.Handle, 0x0419, IntPtr.Zero, ref thumb); // TBM_GETCHANNELRECT, TBM_GETTHUMBRECT
        int middle = (channel.Top + channel.Bottom) / 2, early = channel.Left + 2, late = channel.Right - 3;
        // The thumb can stand at either end; sample each side that it leaves free.
        bool before = thumb.Left > early + 1, after = thumb.Right < late - 1;
        if (channel.Bottom - channel.Top < 3 || !(before || after)) return "the channel (" + channel.Left + "," + channel.Top + "," + channel.Right + "," + channel.Bottom + ") leaves no room to sample beside the thumb";
        using (Bitmap image = Render(slider)) {
            var expected = new[] {
                new { Check = before, X = early, Y = middle, Color = p.ControlFace, Part = "face before the thumb" }, new { Check = after, X = late, Y = middle, Color = p.ControlFace, Part = "face after the thumb" },
                new { Check = before, X = early, Y = channel.Top, Color = p.ChannelEdgeBefore, Part = "edge before the thumb" }, new { Check = before, X = early, Y = channel.Bottom - 1, Color = p.ChannelEdgeBefore, Part = "edge before the thumb" },
                new { Check = before, X = channel.Left, Y = middle, Color = p.ChannelEdgeBefore, Part = "start" },
                new { Check = after, X = late, Y = channel.Top, Color = p.ChannelEdge, Part = "edge after the thumb" }, new { Check = after, X = late, Y = channel.Bottom - 1, Color = p.ChannelEdge, Part = "edge after the thumb" },
                new { Check = after, X = channel.Right - 1, Y = middle, Color = p.ChannelEdge, Part = "end" } };
            foreach (var point in expected) if (point.Check && !Same(image.GetPixel(point.X, point.Y), point.Color)) return point.Part + " pixel " + point.X + "," + point.Y + " was " + image.GetPixel(point.X, point.Y) + ", expected " + point.Color;
        }
        return null;
    }
    static Color PaintedBackground(IconGridView grid)
    {
        using (Bitmap bitmap = new Bitmap(grid.Width, grid.Height)) {
            grid.Refresh(); grid.DrawToBitmap(bitmap, grid.ClientRectangle);
            Point[] empty = { new Point(grid.ClientSize.Width - 8, grid.ClientSize.Height - 8), new Point(8, grid.ClientSize.Height - 8), new Point(grid.ClientSize.Width - 8, 8) };
            foreach (Point point in empty) if (!grid.Items.Cast<ListViewItem>().Any(item => item.Bounds.Contains(point))) return bitmap.GetPixel(point.X, point.Y);
        }
        throw new Exception("No empty grid area available for native background verification.");
    }
    static string ChromePixels(TabControl pages, AppearancePalette palette)
    {
        using (Bitmap bitmap = new Bitmap(pages.Width, pages.Height)) {
            pages.Refresh(); pages.DrawToBitmap(bitmap, pages.ClientRectangle);
            Func<int, int, Color, string> pixel = (x, y, expected) => {
                Color actual = bitmap.GetPixel(x, y);
                return actual.ToArgb() == expected.ToArgb() ? null : "pixel " + x + "," + y + " was " + actual + ", expected " + expected;
            };
            Func<Color, Color, Color, bool> paletteBlend = (actual, inside, outside) => {
                int[] a = { actual.R, actual.G, actual.B }, first = { inside.R, inside.G, inside.B }, last = { outside.R, outside.G, outside.B };
                int channel = Enumerable.Range(0, 3).OrderByDescending(c => Math.Abs(first[c] - last[c])).First();
                // GDI+ coverage rounding can move a channel by one even when
                // painting the same solid color over itself. Allow two levels
                // only along the antialiased arc, never in flat regions.
                if (first[channel] == last[channel]) return actual.A == 255 && Enumerable.Range(0, 3).All(c => Math.Abs(a[c] - first[c]) <= 2);
                double mix = (a[channel] - last[channel]) / (double)(first[channel] - last[channel]);
                return actual.A == 255 && mix >= 0 && mix <= 1 && Enumerable.Range(0, 3).All(c => Math.Abs(a[c] - (last[c] + mix * (first[c] - last[c]))) <= 2);
            };
            int headerBottom = Enumerable.Range(0, pages.TabCount).Max(index => pages.GetTabRect(index).Bottom);
            // The page frame is empty chrome, not app content; inspect its real
            // rendered perimeter rather than a control BackColor property.
            for (int y = headerBottom + 2; y < bitmap.Height; y++) foreach (int x in new[] { 0, 1, bitmap.Width - 2, bitmap.Width - 1 }) {
                string problem = pixel(x, y, palette.Surface); if (problem != null) return "page border: " + problem;
            }
            for (int x = 0; x < bitmap.Width; x++) foreach (int y in new[] { bitmap.Height - 2, bitmap.Height - 1 }) {
                string problem = pixel(x, y, palette.Surface); if (problem != null) return "bottom border: " + problem;
            }
            for (int index = 0; index < pages.TabCount; index++) {
                Rectangle tab = pages.GetTabRect(index);
                Color expected = index == pages.SelectedIndex ? palette.HighContrast ? SystemColors.Highlight : palette.Surface : palette.HighContrast ? SystemColors.Control : palette.InactiveTab;
                // Outer upper corners remain 32px quarter circles; the two
                // inner corners stay square so the tabs meet along a straight
                // line. Use geometry independent of the production path.
                int radius = Math.Min(32, Math.Min(tab.Height, tab.Width / 2));
                Rectangle focus = Rectangle.Inflate(tab, -5, -5);
                foreach (bool right in new[] { false, true }) {
                    bool rounded = right ? index == pages.TabCount - 1 : index == 0;
                    int start = right ? tab.Right - radius : tab.Left;
                    double centerX = right ? tab.Right - radius : tab.Left + radius, centerY = tab.Top + radius;
                    for (int y = tab.Top + 1; y < tab.Top + radius; y++) for (int x = start + 1; x < start + radius - 1; x++) {
                        // Native keyboard focus is deliberately retained; it
                        // has its own tests and is not decorative tab chrome.
                        if (index == pages.SelectedIndex && ((Math.Abs(x - focus.Left) <= 1 || Math.Abs(x - (focus.Right - 1)) <= 1) && y >= focus.Top - 1 && y <= focus.Bottom ||
                            (Math.Abs(y - focus.Top) <= 1 || Math.Abs(y - (focus.Bottom - 1)) <= 1) && x >= focus.Left - 1 && x <= focus.Right)) continue;
                        double distance = Math.Sqrt(Math.Pow(x + 0.5 - centerX, 2) + Math.Pow(y + 0.5 - centerY, 2));
                        string problem;
                        if (!rounded) problem = pixel(x, y, expected);
                        else if (Math.Abs(distance - radius) <= 1.5) {
                            Color actual = bitmap.GetPixel(x, y);
                            problem = paletteBlend(actual, expected, palette.Surface) ? null : "arc pixel " + x + "," + y + " introduced a color outside the tab/page blend: " + actual;
                        }
                        else problem = pixel(x, y, distance < radius ? expected : palette.Surface);
                        if (problem != null) return "tab " + index + (right ? " upper-right" : " upper-left") + (rounded ? " 32px outer corner: " : " straight inner corner: ") + problem;
                    }
                }
                for (int x = tab.Left + radius + 1; x < tab.Right - radius - 1; x++) {
                    string problem = pixel(x, tab.Top + 1, expected); if (problem != null) return "tab " + index + " top edge: " + problem;
                }
                // Lower corners stay square and connect directly to the page.
                for (int x = tab.Left + 1; x < tab.Right - 1; x++) {
                    string problem = pixel(x, tab.Bottom - 2, expected); if (problem != null) return "tab " + index + " lower edge: " + problem;
                }
                for (int y = tab.Top + radius + 1; y < tab.Bottom - 1; y++) foreach (int x in new[] { tab.Left + 1, tab.Right - 2 }) {
                    string problem = pixel(x, y, expected); if (problem != null) return "tab " + index + ": " + problem;
                }
            }
        }
        return null;
    }
    static string WindowSurfacePixels(LauncherForm form, AppearancePalette palette)
    {
        IntPtr region = CreateRectRgn(0, 0, 0, 0);
        try {
            if (region == IntPtr.Zero || GetWindowRgn(form.Handle, region) == 0) return "Native rounded window region is unavailable.";
            using (Bitmap bitmap = new Bitmap(form.Width, form.Height)) {
                form.Refresh(); form.DrawToBitmap(bitmap, form.ClientRectangle);
                Color expected = palette.HighContrast ? palette.Background : palette.Surface;
                int width = form.ClientSize.Width, height = form.ClientSize.Height;
                int[] corners = new int[4]; int samples = 0;
                // DrawToBitmap itself does not enforce the native window region.
                // Sample only visible points in the real HWND's region, along
                // the exposed resize margin and all four curved corners.
                for (int y = 0; y < height; y++) for (int x = 0; x < width; x++) {
                    bool margin = x < form.Padding.Left || x >= width - form.Padding.Right || y < form.Padding.Top || y >= height - form.Padding.Bottom;
                    if (!margin || !PtInRegion(region, x, y)) continue;
                    samples++;
                    if (x < 32 && y < 32) corners[0]++;
                    if (x >= width - 32 && y < 32) corners[1]++;
                    if (x < 32 && y >= height - 32) corners[2]++;
                    if (x >= width - 32 && y >= height - 32) corners[3]++;
                    Color actual = bitmap.GetPixel(x, y);
                    if (actual.ToArgb() != expected.ToArgb()) return "window margin pixel " + x + "," + y + " was " + actual + ", expected " + expected;
                }
                if (samples == 0 || corners.Any(count => count == 0)) return "The native perimeter did not expose samples in all four rounded corners.";
            }
        }
        finally { if (region != IntPtr.Zero) DeleteObject(region); }
        return null;
    }
    static void CheckWindowBorder(LauncherForm form, Action<bool, string> check, string phase)
    {
        uint value;
        int result = DwmGetWindowAttribute(form.Handle, 34, out value, sizeof(uint));
        if (result == 0) check(value == (((AppearancePalette)Field(form, "appearancePalette")).HighContrast ? 0xFFFFFFFF : 0xFFFFFFFE), "Windows DWM uses the requested outer window border policy " + phase + " (value " + value.ToString("X8") + ")");
        else Console.WriteLine("SKIP: This Windows build does not expose DWM border-color readback " + phase + " (HRESULT " + result.ToString("X8") + ")");
    }
    static void CheckFrameTransitions(LauncherForm form, Action<bool, string> check, string mode)
    {
        // Exercise real same-thread activation, not a synthetic NCACTIVATE alone:
        // suppressing frame paint must not prevent another window from becoming active.
        using (Form other = new Form { ShowInTaskbar = false, StartPosition = FormStartPosition.Manual,
            Bounds = new Rectangle(form.Left + 80, form.Top + 80, 280, 120), Text = "BetterIcon disposable focus test" }) {
            other.Show(form);
            for (int i = 0; i < 3; i++) {
                SetActiveWindow(other.Handle); Application.DoEvents();
                bool deactivated = GetActiveWindow() == other.Handle;
                SetActiveWindow(form.Handle); Application.DoEvents();
                check(deactivated && GetActiveWindow() == form.Handle && form.Visible,
                    mode + " native activation round trip " + (i + 1) + " preserves popup availability");
                RedrawWindow(form.Handle, IntPtr.Zero, IntPtr.Zero, 0x0501); // INVALIDATE | UPDATENOW | FRAME.
            }
        }
        form.Hide(); form.Show(); SetActiveWindow(form.Handle); Application.DoEvents();
        form.WindowState = FormWindowState.Minimized; Application.DoEvents();
        bool minimized = form.WindowState == FormWindowState.Minimized;
        form.WindowState = FormWindowState.Normal; SetActiveWindow(form.Handle); Application.DoEvents();
        check(minimized && form.WindowState == FormWindowState.Normal && form.Visible,
            mode + " native minimize and restore remain functional");
        int style = GetWindowLong(form.Handle, -16);
        Point edge = form.PointToScreen(new Point(1, form.ClientSize.Height / 2));
        Point corner = form.PointToScreen(new Point(form.ClientSize.Width - 15, form.ClientSize.Height - 15));
        Func<Point, int> hit = point => SendMessage(form.Handle, 0x0084, IntPtr.Zero,
            new IntPtr(unchecked((point.X & 0xFFFF) | ((point.Y & 0xFFFF) << 16)))).ToInt32();
        check(form.ClientSize == form.Size && (style & 0x00040000) != 0 && (style & 0x00C00000) == 0
            && hit(edge) == 10 && hit(corner) == 17,
            mode + " redraw and reopen retain the full client area and native edge/corner resizing");
        string surface = WindowSurfacePixels(form, (AppearancePalette)Field(form, "appearancePalette"));
        check(surface == null, mode + " rendered window margins stay continuous after activation, frame redraw and reopen"
            + (surface == null ? "" : ": " + surface));
        // In-memory rendering checks the app surface, not a compositor flash;
        // the latter still requires an explicitly authorized visual inspection.
        CheckWindowBorder(form, check, "after " + mode + " activation and frame redraw");
    }
    public static void CheckChrome(LauncherForm form, Action<bool, string> check)
    {
        TabControl pages = (TabControl)Field(form, "pages");
        Preferences preferences = (Preferences)Field(form, "preferences");
        string savedMode = preferences.AppearanceMode; int savedPage = pages.SelectedIndex; Size savedSize = form.Size;
        try {
            foreach (string mode in new[] { "Dark", "Light", "System" }) {
                preferences.AppearanceMode = mode; Invoke(form, "ApplyAppearance");
                foreach (Size size in new[] { new Size(790, 570), new Size(900, 818), new Size(1100, 900) }) {
                    for (int page = 0; page < pages.TabCount; page++) {
                        pages.SelectedIndex = page;
                        form.Size = size;
                        typeof(Form).GetMethod("OnResizeEnd", instance).Invoke(form, new object[] { EventArgs.Empty });
                        form.PerformLayout(); pages.PerformLayout(); Application.DoEvents();
                        string problem = ChromePixels(pages, (AppearancePalette)Field(form, "appearancePalette"));
                        check(problem == null, mode + " native tabs have rounded outer corners, a straight center join and no outline at " + size.Width + "x" + size.Height + ", page " + page + (problem == null ? "" : ": " + problem));
                        string surface = WindowSurfacePixels(form, (AppearancePalette)Field(form, "appearancePalette"));
                        check(surface == null, mode + " window margins and all four rounded corners match the page at " + size.Width + "x" + size.Height + ", page " + page + (surface == null ? "" : ": " + surface));
                    }
                }
                typeof(Control).GetMethod("RecreateHandle", instance).Invoke(pages, null);
                Application.DoEvents();
                string recreated = ChromePixels(pages, (AppearancePalette)Field(form, "appearancePalette"));
                check(recreated == null, mode + " rounded outer corners and straight tab center stay outline-free after handle recreation" + (recreated == null ? "" : ": " + recreated));
                string surfaceRecreated = WindowSurfacePixels(form, (AppearancePalette)Field(form, "appearancePalette"));
                check(surfaceRecreated == null, mode + " all four window corners stay continuous after tab handle recreation" + (surfaceRecreated == null ? "" : ": " + surfaceRecreated));
                CheckFrameTransitions(form, check, mode);
            }
            pages.SelectedIndex = 0; pages.Focus();
            SendMessage(pages.Handle, 0x0100, new IntPtr((int)Keys.Right), IntPtr.Zero);
            SendMessage(pages.Handle, 0x0101, new IntPtr((int)Keys.Right), IntPtr.Zero);
            check(pages.SelectedIndex == 1, "The borderless tab control retains native keyboard navigation to Manage Icons");
            SendMessage(pages.Handle, 0x0100, new IntPtr((int)Keys.Left), IntPtr.Zero);
            SendMessage(pages.Handle, 0x0101, new IntPtr((int)Keys.Left), IntPtr.Zero);
            check(pages.SelectedIndex == 0, "Native keyboard navigation returns to Launcher after tab handle recreation");
            CheckWindowBorder(form, check, "after theme changes");
            typeof(Control).GetMethod("RecreateHandle", instance).Invoke(form, null); Application.DoEvents();
            CheckWindowBorder(form, check, "after native window recreation");
            string windowRecreated = WindowSurfacePixels(form, (AppearancePalette)Field(form, "appearancePalette"));
            check(windowRecreated == null, "The continuous window surface survives native window handle recreation" + (windowRecreated == null ? "" : ": " + windowRecreated));
            CheckFrameTransitions(form, check, "Recreated window");
            AppearancePalette contrast = AppAppearance.Resolve("Dark", false, true);
            typeof(LauncherForm).GetField("appearancePalette", instance).SetValue(form, contrast);
            AppAppearance.Apply(form, contrast); Application.DoEvents();
            string contrastSurface = WindowSurfacePixels(form, contrast);
            check(form.BackColor == contrast.Background && contrastSurface == null, "High contrast retains its system window-margin color" + (contrastSurface == null ? "" : ": " + contrastSurface));
            CheckFrameTransitions(form, check, "High contrast");
        }
        finally {
            form.Size = savedSize; preferences.AppearanceMode = savedMode; Invoke(form, "ApplyAppearance");
            typeof(Form).GetMethod("OnResizeEnd", instance).Invoke(form, new object[] { EventArgs.Empty });
            pages.SelectedIndex = savedPage; form.PerformLayout();
        }
    }
    static void SelectMode(LauncherForm form, string mode)
    {
        ((TabControl)Field(form, "pages")).SelectedIndex = 1;
        Preferences preferences = (Preferences)Field(form, "preferences");
        Button cycle = (Button)Field(form, "appearanceModeButton");
        for (int i = 0; preferences.AppearanceMode != mode && i < 3; i++) cycle.PerformClick();
        if (preferences.AppearanceMode != mode) throw new Exception("The theme cycle did not reach " + mode + ".");
    }
    static void CheckBusyThemes(LauncherForm form, Action<bool, string> check)
    {
        TabControl pages = (TabControl)Field(form, "pages");
        IconGridView[] grids = { (IconGridView)Field(form, "apps"), (IconGridView)Field(form, "packPreview") };
        foreach (string mode in new[] { "Dark", "Light", "System" }) {
            SelectMode(form, mode);
            AppearancePalette palette = (AppearancePalette)Field(form, "appearancePalette");
            Invoke(form, "SetBusy", true, "Saving test artwork...");
            try {
                for (int page = 0; page < grids.Length; page++) {
                    pages.SelectedIndex = page; form.PerformLayout(); Application.DoEvents();
                    IconGridView grid = grids[page]; Color painted = PaintedBackground(grid);
                    check(grid.InputBlocked && !grid.TabStop && IsWindowEnabled(grid.Handle)
                        && SendMessage(grid.Handle, 0x1000, IntPtr.Zero, IntPtr.Zero).ToInt32() == ColorTranslator.ToWin32(palette.Surface)
                        && SendMessage(grid.Handle, 0x1023, IntPtr.Zero, IntPtr.Zero).ToInt32() == ColorTranslator.ToWin32(palette.Text)
                        && painted.ToArgb() == palette.Surface.ToArgb(),
                        mode + " " + (page == 0 ? "Launcher" : "Settings") + " paints its actual theme background and text while saving (painted " + painted + ")");
                }
                Invoke(form, "OnSystemAppearanceChanged", null, new UserPreferenceChangedEventArgs(UserPreferenceCategory.General)); Application.DoEvents();
                check(grids.All(grid => grid.InputBlocked && grid.BackColor == ((AppearancePalette)Field(form, "appearancePalette")).Surface),
                    mode + " appearance notifications preserve the theme and input pause while saving");
            }
            finally { Invoke(form, "SetBusy", false, null); }
            check(grids.All(grid => !grid.InputBlocked && grid.Enabled && grid.TabStop), mode + " saving completion restores ordinary grid input and tab navigation");
        }
    }
    static void CheckGridInput(LauncherForm owner, Action<bool, string> check)
    {
        using (Form holder = new Form { Text = "[TEST] Themed busy grid", ClientSize = new Size(380, 230), ShowInTaskbar = false })
        using (ImageList images = new ImageList())
        using (IconGridView grid = new IconGridView { Dock = DockStyle.Fill }) {
            images.ImageSize = new Size(48, 48); images.Images.Add(SystemIcons.Application); grid.LargeImageList = images;
            foreach (string name in new[] { "Alpha", "Beta", "Gamma" }) grid.Items.Add(new ListViewItem(name, 0));
            holder.Controls.Add(grid); holder.Show(owner); grid.Focus();
            grid.Items[0].Selected = grid.Items[0].Focused = true;
            int activations = 0, menus = 0, zooms = 0;
            grid.ItemActivate += delegate { activations++; }; grid.IconMenuRequested += delegate { menus++; }; grid.IconSizeWheel += delegate { zooms++; };
            AppAppearance.Apply(grid, AppAppearance.Resolve("Dark", null, false));
            grid.InputBlocked = true;
            Rectangle target = grid.GetItemRect(1, ItemBoundsPortion.Icon);
            IntPtr point = new IntPtr(((target.Top + target.Height / 2) << 16) | (target.Left + target.Width / 2));
            foreach (int message in new[] { 0x0201, 0x0202, 0x0203, 0x0202 }) SendMessage(grid.Handle, message, IntPtr.Zero, point);
            SendMessage(grid.Handle, 0x0100, new IntPtr(39), IntPtr.Zero); SendMessage(grid.Handle, 0x0100, new IntPtr(13), IntPtr.Zero);
            SendMessage(grid.Handle, 0x0102, new IntPtr('B'), IntPtr.Zero);
            SendMessage(grid.Handle, 0x007B, grid.Handle, new IntPtr(-1));
            SendMessage(grid.Handle, 0x020A, new IntPtr((120 << 16) | 8), IntPtr.Zero);
            check(grid.SelectedIndices.Count == 1 && grid.SelectedIndices[0] == 0 && activations == 0 && menus == 0 && zooms == 0,
                "A themed busy grid blocks native mouse selection, keyboard launch/navigation, context actions and wheel zoom");
            typeof(Control).GetMethod("RecreateHandle", instance).Invoke(grid, null);
            check(grid.InputBlocked && !grid.TabStop && IsWindowEnabled(grid.Handle) && PaintedBackground(grid).ToArgb() == AppAppearance.Resolve("Dark", null, false).Surface.ToArgb(),
                "Native handle recreation retains paused input and dark painting without disabling the grid");
            AppAppearance.Apply(grid, AppAppearance.Resolve("System", false, false));
            check(grid.InputBlocked && PaintedBackground(grid).ToArgb() == AppAppearance.Resolve("Light", null, false).Surface.ToArgb(),
                "A paused grid repaints for a simulated System-to-Light change without enabling input");
            byte[] keyboard = new byte[256];
            if (!GetKeyboardState(keyboard)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Could not save the test thread's keyboard state.");
            try {
                // Native list navigation reads this thread's modifier state,
                // even for SendMessage. Isolate the unmodified-Right test from
                // a user holding Ctrl/Shift/Alt, without sending input or
                // changing another thread's keyboard state.
                byte[] unmodified = (byte[])keyboard.Clone();
                foreach (int key in new[] { 16, 17, 18, 160, 161, 162, 163, 164, 165 }) unmodified[key] &= 0x7F;
                if (!SetKeyboardState(unmodified)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Could not isolate the test thread's modifiers.");
                grid.InputBlocked = false; grid.Focus(); grid.Items[0].Selected = grid.Items[0].Focused = true;
                SendMessage(grid.Handle, 0x0100, new IntPtr(39), IntPtr.Zero);
                SendMessage(grid.Handle, 0x007B, grid.Handle, new IntPtr(-1)); SendMessage(grid.Handle, 0x020A, new IntPtr((120 << 16) | 8), IntPtr.Zero);
                bool restored = grid.TabStop && grid.SelectedIndices.Count == 1 && grid.SelectedIndices[0] == 1 && menus == 1 && zooms == 1;
                check(restored, "Finishing a save restores native keyboard selection, context actions and zoom" + (restored ? "" :
                    " (TabStop=" + grid.TabStop + ", selected=" + string.Join(",", grid.SelectedIndices.Cast<int>()) + ", menus=" + menus + ", zooms=" + zooms + ", focused=" + grid.Focused + ", modifiers=" + Control.ModifierKeys + ")"));
            }
            finally {
                if (!SetKeyboardState(keyboard)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Could not restore the test thread's keyboard state.");
            }
            holder.Close();
        }
    }
    // A list's dropdown button and the slider's channel take the theme's colors in Dark and Light, enabled and disabled,
    // and stay Windows' own in high contrast. A scrolling panel's scroll bar takes Windows' dark style in Dark.
    static void CheckControlChrome(LauncherForm owner, Action<bool, string> check)
    {
        foreach (string mode in new[] { "Dark", "Light", "High contrast" }) {
            bool contrast = mode == "High contrast";
            AppearancePalette p = contrast ? AppAppearance.Resolve("Dark", false, true) : AppAppearance.Resolve(mode, null, false, "stone");
            using (Form holder = new Form { Text = "[TEST] Themed list, slider and scroll bar", ClientSize = new Size(440, 250), ShowInTaskbar = false, StartPosition = FormStartPosition.Manual, Location = new Point(owner.Left + 40, owner.Top + 40) })
            using (AppearanceComboBox list = new AppearanceComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 300, Location = new Point(12, 12) })
            using (ThemedTrackBar slider = new ThemedTrackBar { Minimum = 0, Maximum = 100, Value = 25, TickStyle = TickStyle.None, AutoSize = false, Width = 400, Height = 28, Location = new Point(12, 60) })
            using (TrackBar plain = new TrackBar { Minimum = 0, Maximum = 100, Value = 25, TickStyle = TickStyle.None, AutoSize = false, Width = 400, Height = 28, Location = new Point(12, 100) })
            using (Panel scrolling = new Panel { AutoScroll = true, AutoScrollMinSize = new Size(0, 2000), Location = new Point(12, 140), Size = new Size(200, 100) })
            using (ComboBox flat = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, FlatStyle = FlatStyle.Flat, DrawMode = DrawMode.OwnerDrawFixed, ItemHeight = 24, Width = 300, Location = new Point(220, 140) }) {
                foreach (ComboBox each in new[] { list, flat }) { each.Items.AddRange(new object[] { "First", "Second" }); each.SelectedIndex = 0; }
                holder.Controls.AddRange(new Control[] { list, slider, plain, scrolling, flat });
                AppAppearance.Apply(holder, p); holder.Show(owner); Application.DoEvents();
                foreach (bool enabled in new[] { true, false }) {
                    list.Enabled = flat.Enabled = enabled; Application.DoEvents();
                    string state = enabled ? "" : " while the list is disabled";
                    if (contrast) {
                        // Inside the border, the themed list's button matches a plain flat list's, pixel for pixel.
                        int width = list.ClientSize.Width, height = list.ClientSize.Height, left = width - SystemInformation.GetHorizontalScrollBarArrowWidthForDpi(list.DeviceDpi) - 1;
                        using (Bitmap image = Render(list)) using (Bitmap native = Render(flat))
                            check(list.Size == flat.Size && Enumerable.Range(left, width - 1 - left).All(x => Enumerable.Range(1, height - 2).All(y => Same(image.GetPixel(x, y), native.GetPixel(x, y)))),
                                "High contrast leaves the list's dropdown button to Windows" + state);
                    }
                    else { string problem = ListButtonProblems(list, p); check(problem == null, mode + " draws the list's dropdown button in the theme's colors" + state + (problem == null ? "" : ": " + problem)); }
                }
                list.Enabled = flat.Enabled = true;
                if (contrast) {
                    NativeRect channel = new NativeRect(); SendRect(slider.Handle, 0x041A, IntPtr.Zero, ref channel);
                    using (Bitmap image = Render(slider)) using (Bitmap native = Render(plain)) {
                        bool same = channel.Right - channel.Left > 10 && Enumerable.Range(channel.Left, channel.Right - channel.Left).All(x => Enumerable.Range(channel.Top, channel.Bottom - channel.Top).All(y => Same(image.GetPixel(x, y), native.GetPixel(x, y))));
                        check(same, "High contrast leaves the slider's channel to Windows");
                    }
                }
                else { string problem = ChannelProblems(slider, p); check(problem == null, mode + " draws the slider's channel in the theme's colors, with its own edges before and after the thumb" + (problem == null ? "" : ": " + problem)); }
                using (Bitmap image = Render(scrolling)) {
                    double light = Light(image.GetPixel(scrolling.Width - SystemInformation.VerticalScrollBarWidth / 2 - 1, scrolling.Height - SystemInformation.VerticalScrollBarArrowHeight - 8));
                    check(scrolling.VerticalScroll.Visible && (p.Dark && !p.HighContrast ? light < 0.06 : light > 0.4), mode + " gives a scrolling panel's scroll bar Windows' " + (p.Dark && !p.HighContrast ? "dark" : "light") + " style (track luminance " + light.ToString("0.000") + ")");
                }
                holder.Close();
            }
        }
    }
    // The rest of the parts Windows draws in its own colors: check boxes, the slider's thumb, the loading bar, the borders of
    // text boxes, lists and tables, a details list's grid lines, a table's buttons, and every scroll bar, through skins.
    // High contrast leaves them all to Windows.
    static void CheckThemedParts(LauncherForm owner, Action<bool, string> check)
    {
        foreach (string mode in new[] { "Dark", "Light", "High contrast" }) {
            bool contrast = mode == "High contrast";
            AppearancePalette p = contrast ? AppAppearance.Resolve("Dark", false, true) : AppAppearance.Resolve(mode, null, false, "stone");
            using (Form holder = new Form { Text = "[TEST] Themed parts", ClientSize = new Size(940, 720), ShowInTaskbar = false, StartPosition = FormStartPosition.Manual, Location = new Point(owner.Left + 20, owner.Top + 20) })
            using (CheckBox on = new CheckBox { Text = "Checked", Checked = true, AutoSize = true, Location = new Point(12, 12) })
            using (CheckBox off = new CheckBox { Text = "Unchecked", AutoSize = true, Location = new Point(160, 12) })
            using (ThemedTrackBar slider = new ThemedTrackBar { Minimum = 0, Maximum = 100, Value = 50, TickStyle = TickStyle.None, AutoSize = false, Width = 300, Height = 28, Location = new Point(12, 44) })
            using (TrackBar plain = new TrackBar { Minimum = 0, Maximum = 100, Value = 50, TickStyle = TickStyle.None, AutoSize = false, Width = 300, Height = 28, Location = new Point(330, 44) })
            using (ThemedProgressBar progress = new ThemedProgressBar { Style = ProgressBarStyle.Marquee, MarqueeAnimationSpeed = 0, Location = new Point(12, 84), Size = new Size(400, 14) })
            using (TextBox single = new TextBox { BorderStyle = BorderStyle.FixedSingle, Text = "128", Location = new Point(12, 110), Width = 120 })
            using (TextBox sunken = new TextBox { Text = "Pack name", Location = new Point(150, 110), Width = 160 })
            using (ListView rows = new ListView { View = View.Details, GridLines = true, FullRowSelect = true, Location = new Point(12, 150), Size = new Size(440, 220) })
            using (DataGridView table = new DataGridView { Location = new Point(470, 150), Size = new Size(440, 220), RowHeadersVisible = false, AllowUserToAddRows = false })
            using (Panel scrolling = new Panel { AutoScroll = true, AutoScrollMinSize = new Size(0, 2000), Location = new Point(12, 390), Size = new Size(200, 200) })
            using (AppearanceComboBox list = new AppearanceComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 300, MaxDropDownItems = 8, Location = new Point(240, 390) }) {
                rows.Columns.Add("Status", 100); rows.Columns.Add("Shortcut", 300);
                for (int i = 0; i < 40; i++) rows.Items.Add(new ListViewItem(new[] { "Changes", "Shortcut " + i }));
                table.Columns.Add("App", "App"); table.Columns.Add(new DataGridViewButtonColumn { Name = "Choose", Text = "Choose...", UseColumnTextForButtonValue = true, Width = 90 });
                for (int i = 0; i < 60; i++) table.Rows.Add("App " + i);
                for (int i = 0; i < 60; i++) list.Items.Add("Pack " + i);
                list.SelectedIndex = 0;
                holder.Controls.AddRange(new Control[] { on, off, slider, plain, progress, single, sunken, rows, table, scrolling, list });
                AppAppearance.Apply(holder, p); holder.Show(owner);
                for (int i = 0; i < 10; i++) Application.DoEvents();
                // Check boxes: a rounded square in the accent once checked, in the input color with the border color around it otherwise.
                Size glyph; using (Graphics g = on.CreateGraphics()) glyph = CheckBoxRenderer.GetGlyphSize(g, System.Windows.Forms.VisualStyles.CheckBoxState.UncheckedNormal);
                Func<CheckBox, Point> inside = box => new Point(box.Padding.Left + glyph.Width * 3 / 10, (box.ClientSize.Height - glyph.Height) / 2 + glyph.Height * 3 / 10);
                using (Bitmap checkedImage = Render(on)) using (Bitmap uncheckedImage = Render(off)) {
                    Color a = checkedImage.GetPixel(inside(on).X, inside(on).Y), b = uncheckedImage.GetPixel(off.Padding.Left + glyph.Width / 2, (off.ClientSize.Height - glyph.Height) / 2 + glyph.Height / 2);
                    if (!contrast) check(Same(a, p.Accent) && Same(b, p.Input), mode + " draws check boxes in the theme's colors (checked " + a + ", unchecked " + b + ")");
                    else check(!Same(a, AppAppearance.Resolve("Dark", null, false, "stone").Accent), "High contrast leaves check boxes to Windows");
                }
                // The slider's thumb: the accent.
                NativeRect thumb = new NativeRect(); SendRect(slider.Handle, 0x0419, IntPtr.Zero, ref thumb);
                Point middle = new Point((thumb.Left + thumb.Right) / 2, (thumb.Top + thumb.Bottom) / 2);
                using (Bitmap image = Render(slider)) using (Bitmap native = Render(plain)) {
                    Color c = image.GetPixel(middle.X, middle.Y);
                    if (!contrast) check(Same(c, p.Accent) || Same(c, p.AccentHover), mode + " draws the slider's thumb in the theme's accent (" + c + ")");
                    else check(Same(c, native.GetPixel(middle.X, middle.Y)), "High contrast leaves the slider's thumb to Windows");
                }
                // The loading bar: the button's gray, with an accent chunk while it runs.
                progress.MarqueeAnimationSpeed = 30;
                bool chunk = false; int track = 0;
                for (int attempt = 0; attempt < 40 && !chunk; attempt++) {
                    for (int i = 0; i < 5; i++) { Application.DoEvents(); System.Threading.Thread.Sleep(10); }
                    using (Bitmap image = Render(progress)) {
                        int y = progress.Height / 2;
                        chunk = Enumerable.Range(0, progress.Width).Any(x => Same(image.GetPixel(x, y), p.Accent));
                        track = Enumerable.Range(0, progress.Width).Count(x => Same(image.GetPixel(x, y), p.ControlFace));
                    }
                }
                bool running = progress.MarqueeRunning;
                progress.MarqueeAnimationSpeed = 0; Application.DoEvents();
                bool stopped;
                using (Bitmap image = Render(progress)) stopped = !progress.MarqueeRunning && Enumerable.Range(0, progress.Width).All(x => Same(image.GetPixel(x, progress.Height / 2), p.ControlFace));
                check(running && chunk && track > 0 && stopped, mode + " gives the loading bar the button's gray and a moving accent chunk, which stops with the bar");
                // Borders of text boxes, the details list and the table: the border color, a sunken border's inner line the background.
                if (!contrast) {
                    using (Bitmap a = Render(single)) using (Bitmap b = Render(sunken)) using (Bitmap c = Render(rows)) using (Bitmap d = Render(table)) {
                        bool borders = Same(a.GetPixel(0, single.Height / 2), p.Border) && Same(b.GetPixel(0, sunken.Height / 2), p.Border) && Same(b.GetPixel(1, sunken.Height / 2), sunken.BackColor)
                            && Same(c.GetPixel(0, rows.Height / 2), p.Border) && Same(d.GetPixel(0, table.Height / 2), p.Border);
                        check(borders, mode + " draws the borders of text boxes, a list and a table in the theme's border color (" + a.GetPixel(0, single.Height / 2) + ", " + b.GetPixel(0, sunken.Height / 2) + ", " + c.GetPixel(0, rows.Height / 2) + ", " + d.GetPixel(0, table.Height / 2) + ")");
                        // Grid lines and a table's button cells.
                        Rectangle row = rows.GetItemRect(0);
                        Color gridLine = c.GetPixel(2 + rows.Columns[0].Width / 2, 2 + row.Bottom - 1);
                        Rectangle cell = table.GetCellDisplayRectangle(1, 0, false);
                        Color face = d.GetPixel(cell.Left + 4, cell.Top + cell.Height / 2), edge = d.GetPixel(cell.Left + 2, cell.Top + cell.Height / 2);
                        check(!rows.GridLines && Same(gridLine, p.Border) && table.ColumnHeadersBorderStyle == DataGridViewHeaderBorderStyle.Single && Same(face, p.Surface) && Same(edge, p.Border),
                            mode + " draws a details list's grid lines and a table's buttons in the theme's colors (line " + gridLine + ", button " + face + " in " + edge + ")");
                    }
                    CheckPartStates(holder, owner, rows, table, p, mode, check);
                }
                else check(rows.GridLines, "High contrast gives a details list Windows' own grid lines back");
                // Scroll bars: a skin over each, or none in high contrast.
                ScrollBar tableBar = table.Controls.OfType<VScrollBar>().First();
                list.DroppedDown = true;
                for (int i = 0; i < 20; i++) { Application.DoEvents(); System.Threading.Thread.Sleep(10); }
                ComboInfo combo = new ComboInfo { Size = Marshal.SizeOf(typeof(ComboInfo)) }; GetComboBoxInfo(list.Handle, ref combo);
                if (!contrast) {
                    var bars = new[] {
                        new { Name = "a scrolling panel", Problem = SkinProblems(scrolling, scrolling.Handle, -5, 0, p) },
                        new { Name = "a details list", Problem = SkinProblems(rows, rows.Handle, -5, 0, p) },
                        new { Name = "a table", Problem = SkinProblems(tableBar, tableBar.Handle, -4, 0, p) },
                        new { Name = "a list's open dropdown", Problem = SkinProblems(list, combo.List, -5, 0, p) } };
                    foreach (var bar in bars) check(bar.Problem == null, mode + " lays a themed skin over the scroll bar of " + bar.Name + (bar.Problem == null ? "" : ": " + bar.Problem));
                    CheckSkinFollows(scrolling, p, mode, check);
                }
                else check(SkinsHidden(scrolling) && SkinsHidden(rows) && SkinsHidden(tableBar) && SkinsHidden(list), "High contrast shows Windows' own scroll bars, with no skins");
                list.DroppedDown = false; Application.DoEvents();
                if (!contrast) check(SkinOf(list) != null && SkinOf(list).SkinHandles().All(handle => handle == IntPtr.Zero || !IsWindowVisible(handle)), mode + " hides the dropdown's skin when the dropdown closes");
                holder.Close();
            }
        }
    }
    // The states Windows' own drawing showed and the themed drawing must keep: the pointer over a table's button and a
    // press on it, the keyboard focus on a table's current button, and the focus rectangle around a details list's row.
    static void CheckPartStates(Form holder, Form other, ListView rows, DataGridView table, AppearancePalette p, string mode, Action<bool, string> check)
    {
        // WM_CHANGEUISTATE: UIS_CLEAR (2) or UIS_SET (1) of UISF_HIDEFOCUS. Windows hides focus marks until the keyboard is used.
        Action<bool> keyboard = inUse => { SendMessage(holder.Handle, 0x0127, (IntPtr)((1 << 16) | (inUse ? 2 : 1)), IntPtr.Zero); Application.DoEvents(); };
        Rectangle button = table.GetCellDisplayRectangle(1, 0, false);
        // Inside the button's face, clear of its text, its border and the focus rectangle.
        Point inside = new Point(button.Left + 8, button.Top + button.Height / 2);
        Func<Color> tone = () => { using (Bitmap image = Render(table)) return image.GetPixel(inside.X, inside.Y); };
        // The table's own handling of the mouse messages, which raises its cell events as a real pointer does.
        Action<string, EventArgs> mouse = (name, args) => typeof(DataGridView).GetMethod(name, instance, null, new[] { args.GetType() }, null).Invoke(table, new object[] { args });
        MouseEventArgs move = new MouseEventArgs(MouseButtons.None, 0, inside.X, inside.Y, 0), press = new MouseEventArgs(MouseButtons.Left, 1, inside.X, inside.Y, 0);
        keyboard(false);
        Color rest = tone();
        mouse("OnMouseMove", move); Color over = tone();
        mouse("OnMouseDown", press); Color held = tone();
        mouse("OnMouseUp", press); Color released = tone();
        mouse("OnMouseLeave", EventArgs.Empty); Color left = tone();
        check(Same(rest, p.Surface) && Same(over, p.Selection) && Same(held, p.Pressed) && Same(released, p.Selection) && Same(left, p.Surface),
            mode + " shows the pointer over a table's button and a press on it (" + rest + ", then " + over + ", " + held + ", " + released + ", " + left + ")");
        // The focus rectangle's left edge lies two pixels inside the button's face.
        Func<int> marks = () => {
            using (Bitmap image = Render(table)) {
                Color face = image.GetPixel(inside.X, inside.Y);
                return Enumerable.Range(button.Top + 5, Math.Max(0, button.Height - 12)).Count(y => !Same(image.GetPixel(button.Left + 4, y), face));
            }
        };
        SetActiveWindow(holder.Handle); table.Focus(); table.CurrentCell = table[1, 0]; Application.DoEvents();
        keyboard(true); int shown = marks();
        keyboard(false); int hidden = marks();
        table.CurrentCell = table[0, 0]; keyboard(true); int elsewhere = marks();
        check(table.Focused && shown >= 2 && hidden == 0 && elsewhere == 0,
            mode + " marks a table's current button with the keyboard focus once the keyboard is in use (" + shown + " dots; " + hidden + " while Windows hides the focus; " + elsewhere + " on another cell; focused " + table.Focused + ")");
        // Space holds the current button down. When another window takes the focus, Space's release goes there, so the
        // table lets go of the button then.
        table.CurrentCell = table[1, 0]; keyboard(false);
        mouse("OnKeyDown", new KeyEventArgs(Keys.Space)); Color down = tone();
        SetActiveWindow(other.Handle); Application.DoEvents();
        SetActiveWindow(holder.Handle); table.Focus(); Application.DoEvents();
        Color back = tone();
        mouse("OnKeyUp", new KeyEventArgs(Keys.Space));
        check(table.Focused && Same(down, p.Pressed) && Same(back, p.Surface),
            mode + " shows Space holding a table's button down, and lets go of it when another window takes the focus (" + down + ", then " + back + "; focused " + table.Focused + ")");
        // A details list: the rectangle runs along the top of the second column and down the row's right side too.
        rows.Focus(); rows.Items[1].Focused = true; Application.DoEvents();
        Rectangle row = rows.GetItemRect(1);
        Func<int[]> around = () => {
            using (Bitmap image = Render(rows)) {
                int first = 2 + rows.Columns[0].Width + 8, right = 2 + row.Right - 2;
                return new[] {
                    Enumerable.Range(first, Math.Min(200, right - 4 - first)).Count(x => !Same(image.GetPixel(x, 2 + row.Top), rows.BackColor)),
                    Enumerable.Range(2 + row.Top + 2, Math.Max(0, row.Height - 6)).Count(y => !Same(image.GetPixel(right, y), rows.BackColor)) };
            }
        };
        keyboard(true); int[] visible = around();
        keyboard(false); int[] none = around();
        check(rows.Focused && visible[0] >= 40 && visible[1] >= 2 && none[0] == 0 && none[1] == 0,
            mode + " draws a details list's focus rectangle around the whole row once the keyboard is in use (" + visible[0] + " dots along the second column's top, " + visible[1] + " down the right side; " + none[0] + " and " + none[1] + " while Windows hides the focus; focused " + rows.Focused + ")");
    }
    // Where a skin's picture shows its thumb along a vertical bar: the first and last row in a thumb color, or -1.
    static int[] DrawnThumb(Control owner, AppearancePalette p)
    {
        ScrollSkin skin = SkinOf(owner);
        BarInfo info = new BarInfo { States = new int[6] }; info.Size = Marshal.SizeOf(typeof(BarInfo));
        if (skin == null || !GetScrollBarInfo(owner.Handle, -5, ref info)) return new[] { -1, -1 };
        Size size = new Size(info.Bar.Right - info.Bar.Left, info.Bar.Bottom - info.Bar.Top);
        using (Bitmap image = PrintHandle(skin.SkinHandles()[0], size)) {
            int[] thumb = Enumerable.Range(0, size.Height).Where(y => { Color c = image.GetPixel(size.Width / 2, y); return Same(c, p.ScrollThumb) || Same(c, p.ScrollThumbHot) || Same(c, p.ScrollThumbPressed); }).ToArray();
            return thumb.Length == 0 ? new[] { -1, -1 } : new[] { thumb.First(), thumb.Last() };
        }
    }
    // A scrolling panel's bar changes without a message to the panel when the program gives it a new range or place:
    // Windows redraws the real bar itself, under the skin. The skin catches up when the thread runs out of messages.
    static void CheckSkinFollows(Panel scrolling, AppearancePalette p, string mode, Action<bool, string> check)
    {
        Func<int[]> real = () => { BarInfo info = new BarInfo { States = new int[6] }; info.Size = Marshal.SizeOf(typeof(BarInfo)); GetScrollBarInfo(scrolling.Handle, -5, ref info); return new[] { info.ThumbTop, info.ThumbBottom }; };
        // The thumb is drawn one pixel inside its place, with rounded ends.
        Func<int[], int[], bool> matches = (drawn, bar) => drawn[0] >= 0 && Math.Abs(drawn[0] - (bar[0] + 1)) <= 4 && Math.Abs(drawn[1] - (bar[1] - 2)) <= 4;
        scrolling.AutoScrollMinSize = new Size(0, 500);
        for (int i = 0; i < 5; i++) Application.DoEvents();
        Application.RaiseIdle(EventArgs.Empty);
        int[] large = real(), drawnLarge = DrawnThumb(scrolling, p);
        scrolling.AutoScrollMinSize = new Size(0, 5000);
        for (int i = 0; i < 5; i++) Application.DoEvents();
        int[] small = real(); bool stale = !matches(DrawnThumb(scrolling, p), small);
        Application.RaiseIdle(EventArgs.Empty);
        int[] drawnSmall = DrawnThumb(scrolling, p);
        scrolling.AutoScrollPosition = new Point(0, 2500);
        for (int i = 0; i < 5; i++) Application.DoEvents();
        Application.RaiseIdle(EventArgs.Empty);
        int[] moved = real(), drawnMoved = DrawnThumb(scrolling, p);
        scrolling.AutoScrollPosition = Point.Empty; scrolling.AutoScrollMinSize = new Size(0, 2000);
        for (int i = 0; i < 5; i++) Application.DoEvents();
        Application.RaiseIdle(EventArgs.Empty);
        bool shorter = small[1] - small[0] < large[1] - large[0] - 8, lower = moved[0] > small[0] + 8;
        check(matches(drawnLarge, large) && shorter && matches(drawnSmall, small) && lower && matches(drawnMoved, moved),
            mode + " keeps a scroll bar's skin in step when the program changes the bar's range or place without a message to its window (thumb " + large[0] + "-" + large[1] + " drawn " + drawnLarge[0] + "-" + drawnLarge[1]
            + "; then " + small[0] + "-" + small[1] + " drawn " + drawnSmall[0] + "-" + drawnSmall[1] + "; then " + moved[0] + "-" + moved[1] + " drawn " + drawnMoved[0] + "-" + drawnMoved[1] + "; out of step before the thread went idle: " + stale + ")");
    }
    // The same in a later message loop on one thread. WinForms keeps a thread's Idle handlers with its message loop and
    // drops them when Application.Run returns, so a skin made in a later loop has to ask for them again.
    public static void CheckSkinsInLaterLoop(Action<bool, string> check)
    {
        AppearancePalette p = AppAppearance.Resolve("Dark", null, false, "stone");
        using (Form holder = new Form { Text = "[TEST] Later loop", ClientSize = new Size(260, 260), ShowInTaskbar = false, StartPosition = FormStartPosition.Manual, Location = new Point(40, 40) })
        using (Panel scrolling = new Panel { AutoScroll = true, AutoScrollMinSize = new Size(0, 2000), Location = new Point(12, 12), Size = new Size(200, 200) }) {
            holder.Controls.Add(scrolling);
            AppAppearance.Apply(holder, p); holder.Show();
            for (int i = 0; i < 10; i++) Application.DoEvents();
            CheckSkinFollows(scrolling, p, "A later message loop on the same thread", check);
            holder.Close();
        }
    }
    [DllImport("gdi32.dll")] static extern int GetObjectType(IntPtr handle);
    [DllImport("gdi32.dll")] static extern int GetRgnBox(IntPtr region, out NativeRect box);
    [DllImport("user32.dll")] static extern bool GetUpdateRect(IntPtr window, out NativeRect area, bool erase);
    [DllImport("user32.dll")] static extern bool UpdateWindow(IntPtr window);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out NativeRect area);
    // Sees what a window is asked to paint after BetterIcon's own border drawing has had its say: attached to the window
    // before BetterIcon's drawing is, it stands between that and Windows.
    sealed class PaintSpy : NativeWindow
    {
        public bool SawFrame, SawPaint; public IntPtr FrameParameter; public NativeRect FrameRegion, ClientUpdate;
        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x0085) { SawFrame = true; FrameParameter = m.WParam; long region = m.WParam.ToInt64(); if (region != 0 && region != 1) GetRgnBox(m.WParam, out FrameRegion); } // WM_NCPAINT
            if (m.Msg == 0x000F && m.WParam == IntPtr.Zero) { SawPaint = true; GetUpdateRect(Handle, out ClientUpdate, false); }                   // WM_PAINT
            base.WndProc(ref m);
        }
    }
    // Each themed part reaches the screen in one step. Painted in two, Windows' own colors and then the theme's over them,
    // a part flickers whenever it repaints, as most do while the pointer moves over them.
    static void CheckSinglePaint(LauncherForm owner, Action<bool, string> check)
    {
        AppearancePalette p = AppAppearance.Resolve("Dark", null, false, "stone");
        using (Form holder = new Form { Text = "[TEST] Painted once", ClientSize = new Size(700, 420), ShowInTaskbar = false, StartPosition = FormStartPosition.Manual, Location = new Point(owner.Left + 20, owner.Top + 20) })
        using (AppearanceComboBox list = new AppearanceComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 300, Location = new Point(12, 12) })
        using (TextBox single = new TextBox { BorderStyle = BorderStyle.FixedSingle, Text = "128", Location = new Point(12, 60), Width = 120 })
        using (TextBox sunken = new TextBox { Text = "Pack name", Location = new Point(150, 60), Width = 160 })
        using (ListView rows = new ListView { View = View.Details, GridLines = true, Location = new Point(12, 100), Size = new Size(300, 160) })
        using (DataGridView table = new DataGridView { Location = new Point(330, 100), Size = new Size(300, 160) })
        using (ThemedTrackBar slider = new ThemedTrackBar { Minimum = 0, Maximum = 100, Value = 50, TickStyle = TickStyle.None, AutoSize = false, Width = 300, Height = 28, Location = new Point(12, 280) }) {
            list.Items.Add("Pack"); list.SelectedIndex = 0; rows.Columns.Add("Status", 100);
            holder.Controls.AddRange(new Control[] { list, single, sunken, rows, table, slider });
            holder.Show(owner);
            for (int i = 0; i < 5; i++) Application.DoEvents();
            PaintSpy singleSpy = new PaintSpy(), sunkenSpy = new PaintSpy();
            singleSpy.AssignHandle(single.Handle); sunkenSpy.AssignHandle(sunken.Handle);
            AppAppearance.Apply(holder, p);
            for (int i = 0; i < 10; i++) Application.DoEvents();
            try {
                // A pack list: its item is drawn to a memory device (OBJ_MEMDC), and nothing is erased on the screen first.
                int device = 0;
                list.DrawItem += delegate(object sender, DrawItemEventArgs e) { IntPtr hdc = e.Graphics.GetHdc(); try { device = GetObjectType(hdc); } finally { e.Graphics.ReleaseHdc(hdc); } };
                PropertyInfo keeps = typeof(AppearanceComboBox).GetProperty("KeepsPictures", BindingFlags.Static | BindingFlags.NonPublic);
                keeps.SetValue(null, true, null);
                string picture; Color itemColor;
                try {
                    list.Invalidate(); list.Update();
                    Bitmap sent = (Bitmap)typeof(AppearanceComboBox).GetProperty("Picture", instance).GetValue(list, null);
                    picture = sent == null ? "no picture was kept" : ListButtonProblems(list, p, sent);
                    // Well right of the item's text and left of the button: the item's own background, selected while the list has the focus.
                    itemColor = sent == null ? Color.Empty : sent.GetPixel(sent.Width - SystemInformation.GetHorizontalScrollBarArrowWidthForDpi(list.DeviceDpi) - 14, sent.Height / 2);
                }
                finally { keeps.SetValue(null, false, null); }
                IntPtr erased = SendMessage(list.Handle, 0x0014, IntPtr.Zero, IntPtr.Zero);
                check(device == 10 && erased == (IntPtr)1, "A pack list paints into a buffer and reaches the screen once, so its button does not flash Windows' light gray (device type " + device + ", erase " + erased + ")");
                check(picture == null && (Same(itemColor, p.Input) || Same(itemColor, p.Selection)), "The picture a pack list sends to the screen has the themed button, frames and item background" + (picture == null ? "" : ": " + picture) + " (item " + itemColor + ")");
                // A sunken text box: Windows is given the frame's inside to paint, never the frame.
                NativeRect window; GetWindowRect(sunken.Handle, out window);
                sunkenSpy.SawFrame = false;
                RedrawWindow(sunken.Handle, IntPtr.Zero, IntPtr.Zero, 0x0001 | 0x0400 | 0x0100); // RDW_INVALIDATE | RDW_FRAME | RDW_UPDATENOW
                NativeRect given = sunkenSpy.FrameRegion; IntPtr parameter = sunkenSpy.FrameParameter;
                bool inside = sunkenSpy.SawFrame && parameter.ToInt64() != 0 && parameter.ToInt64() != 1 && given.Left >= window.Left + 2 && given.Top >= window.Top + 2 && given.Right <= window.Right - 2 && given.Bottom <= window.Bottom - 2;
                check(inside, "A text box's frame is drawn once, in the theme's color: Windows paints only inside it (given " + given.Left + "," + given.Top + "," + given.Right + "," + given.Bottom + " of " + window.Left + "," + window.Top + "," + window.Right + "," + window.Bottom + ")");
                // A single-border text box draws its border in its client area: those four lines are kept from Windows.
                singleSpy.SawPaint = false;
                single.Invalidate(); single.Update();
                NativeRect left = singleSpy.ClientUpdate;
                bool kept = singleSpy.SawPaint && left.Left >= 1 && left.Top >= 1 && left.Right <= single.Width - 1 && left.Bottom <= single.Height - 1;
                check(kept, "A single-border text box's border is drawn once: Windows paints only inside it (" + left.Left + "," + left.Top + "," + left.Right + "," + left.Bottom + " of " + single.Width + "x" + single.Height + ")");
                // A details list and a table paint through a buffer (LVM_GETEXTENDEDLISTVIEWSTYLE, LVS_EX_DOUBLEBUFFER).
                bool listBuffered = (SendMessage(rows.Handle, 0x1037, IntPtr.Zero, IntPtr.Zero).ToInt64() & 0x10000) != 0;
                bool tableBuffered = (bool)typeof(Control).GetProperty("DoubleBuffered", instance).GetValue(table, null);
                check(listBuffered && tableBuffered, "A details list and a table paint through a buffer, so their rows do not flicker under the pointer");
                // The slider: the pointer reaching the thumb repaints the thumb alone, and erases nothing.
                for (int i = 0; i < 5; i++) Application.DoEvents();
                UpdateWindow(slider.Handle);
                NativeRect thumb = new NativeRect(); SendRect(slider.Handle, 0x0419, IntPtr.Zero, ref thumb);
                int x = (thumb.Left + thumb.Right) / 2, y = (thumb.Top + thumb.Bottom) / 2;
                SendMessage(slider.Handle, 0x0200, IntPtr.Zero, (IntPtr)((y << 16) | (x & 0xFFFF))); // WM_MOUSEMOVE
                NativeRect dirty; bool any = GetUpdateRect(slider.Handle, out dirty, false);
                bool onlyThumb = any && dirty.Left >= thumb.Left - 2 && dirty.Top >= thumb.Top - 2 && dirty.Right <= thumb.Right + 2 && dirty.Bottom <= thumb.Bottom + 2;
                check(onlyThumb, "The pointer reaching the slider's thumb repaints the thumb alone (" + dirty.Left + "," + dirty.Top + "," + dirty.Right + "," + dirty.Bottom + " for a thumb at " + thumb.Left + "," + thumb.Top + "," + thumb.Right + "," + thumb.Bottom + ")");
            }
            finally { singleSpy.ReleaseHandle(); sunkenSpy.ReleaseHandle(); }
            holder.Close();
        }
    }
    // The app's own lists and slider use those colors, also while an operation disables them.
    static void CheckFormControls(LauncherForm form, Action<bool, string> check)
    {
        TabControl pages = (TabControl)Field(form, "pages");
        ComboBox[] lists = { (ComboBox)Field(form, "themes"), (ComboBox)Field(form, "fileThemes") };
        TrackBar slider = (TrackBar)Field(form, "iconSizeSlider");
        Panel scroll = (Panel)Field(form, "settingsScroll");
        Size savedSize = form.Size;
        check(slider is ThemedTrackBar && lists.All(list => list is AppearanceComboBox) && Field(form, "loadingProgress") is ThemedProgressBar, "The icon size slider, both pack lists and the loading bar are the themed controls");
        // A small window gives Manage Icons a scroll bar; each theme switch must give it the new theme's style.
        form.Size = new Size(790, 420);
        typeof(Form).GetMethod("OnResizeEnd", instance).Invoke(form, new object[] { EventArgs.Empty });
        try {
            foreach (string mode in new[] { "Dark", "Light", "Dark" }) {
                SelectMode(form, mode); pages.SelectedIndex = 1; form.PerformLayout(); Application.DoEvents();
                AppearancePalette palette = (AppearancePalette)Field(form, "appearancePalette");
                if (!scroll.VerticalScroll.Visible) { Console.WriteLine("SKIP: Manage Icons needs no scroll bar at 790x420 on this display"); break; }
                using (Bitmap image = Render(scroll)) {
                    double light = Light(image.GetPixel(scroll.Width - SystemInformation.VerticalScrollBarWidth / 2 - 1, scroll.Height - SystemInformation.VerticalScrollBarArrowHeight - 8));
                    check(palette.Dark ? light < 0.06 : light > 0.4, "After switching to " + mode + ", Windows' Manage Icons scroll bar beneath the skin has its " + (palette.Dark ? "dark" : "light") + " style (track luminance " + light.ToString("0.000") + ")");
                }
                string skin = SkinProblems(scroll, scroll.Handle, -5, 0, palette);
                check(skin == null, "After switching to " + mode + ", the Manage Icons scroll bar has the theme's skin" + (skin == null ? "" : ": " + skin));
                foreach (IconGridView grid in new[] { (IconGridView)Field(form, "packPreview"), (IconGridView)Field(form, "filePreview") }) {
                    BarInfo info = new BarInfo { States = new int[6] }; info.Size = Marshal.SizeOf(typeof(BarInfo));
                    if (!grid.Visible || !GetScrollBarInfo(grid.Handle, -5, ref info) || (info.States[0] & 0x8000) != 0) continue;
                    string own = SkinProblems(grid, grid.Handle, -5, 0, palette);
                    check(own == null, "After switching to " + mode + ", " + grid.AccessibleName + " has the theme's scroll bar skin" + (own == null ? "" : ": " + own));
                }
            }
        }
        finally {
            form.Size = savedSize;
            typeof(Form).GetMethod("OnResizeEnd", instance).Invoke(form, new object[] { EventArgs.Empty });
            form.PerformLayout(); Application.DoEvents();
        }
        foreach (string mode in new[] { "Dark", "Light" }) {
            SelectMode(form, mode); pages.SelectedIndex = 1; form.PerformLayout(); Application.DoEvents();
            AppearancePalette p = (AppearancePalette)Field(form, "appearancePalette");
            string problem = lists.Select(list => ListButtonProblems(list, p)).FirstOrDefault(found => found != null) ?? ChannelProblems(slider, p);
            check(problem == null, mode + " draws both pack lists' dropdown buttons and the icon size slider's channel in the theme's colors" + (problem == null ? "" : ": " + problem));
            Invoke(form, "SetBusy", true, "Saving test artwork...");
            try {
                Application.DoEvents();
                string busy = lists.Select(list => ListButtonProblems(list, p)).FirstOrDefault(found => found != null) ?? ChannelProblems(slider, p);
                check(problem == null && busy == null && lists.All(list => !list.Enabled) && !slider.Enabled, mode + " keeps those colors while an operation disables the lists and the slider" + (busy == null ? "" : ": " + busy));
            }
            finally { Invoke(form, "SetBusy", false, null); }
        }
    }
    public static void Run(LauncherForm form, string preferencesPath, string sourceFolder, Action<bool, string> check)
    {
        JavaScriptSerializer json = new JavaScriptSerializer();
        Preferences old = json.Deserialize<Preferences>("{\"Theme\":\"Craft-Icons-Zach/Satin\",\"Scope\":\"AllUsers\",\"IconSize\":512,\"Hotkey\":{\"Enabled\":false},\"DefaultShortcuts\":[\"fixture.lnk\"]}");
        check(old.AppearanceMode == "System" && old.AppIconStyle == "sage" && old.AppIconVariant == "Auto" && old.IconSize == 512 && old.Theme == "Craft-Icons-Zach/Satin" && old.Scope == "AllUsers" && !old.Hotkey.Enabled && old.DefaultShortcuts.Single() == "fixture.lnk", "Old preferences gain System and Sage without changing packs, shortcut scope, zoom, hotkey or individual defaults");
        old.AppearanceMode = "unknown"; old.AppIconStyle = "unknown"; old.AppIconVariant = null;
        check(old.AppearanceMode == "System" && old.AppIconStyle == "sage" && old.AppIconVariant == "Auto", "Invalid appearance preferences safely fall back to the available defaults");
        check(AppAppearance.Resolve("System", true, false).Dark && !AppAppearance.Resolve("System", false, false).Dark && AppAppearance.Resolve("Dark", false, false).Dark && !AppAppearance.Resolve("Light", true, false).Dark, "System follows Windows while explicit Dark and Light override it");
        check(AppAppearance.Resolve("System", null, false).Dark == AppAppearance.SystemIsDark(), "System appearance reads the current Windows app theme without writing OS settings");
        // Each app icon supplies the app's own colors: its dark tone for Dark, its light tone for Light.
        foreach (string style in AppBranding.Styles) foreach (string mode in new[] { "Dark", "Light" }) {
            AppearancePalette p = AppAppearance.Resolve(mode, null, false, style);
            Color[] tones = AppBranding.Tones(style, mode.ToLowerInvariant());
            Color own = style == "contrast" ? (mode == "Dark" ? Color.Black : Color.White) : tones[mode == "Dark" ? 0 : 1];
            string name = AppBranding.Title(style) + " " + mode;
            check(p.Dark == (mode == "Dark") && !p.HighContrast && p.Surface.ToArgb() == own.ToArgb() && Contrast(tones[0], tones[1]) >= 3,
                name + " uses its icon's own " + mode.ToLowerInvariant() + " tone as the app background");
            double weakest = new[] { Contrast(p.Text, p.Input), Contrast(p.Text, p.Background), Contrast(p.Text, p.InactiveTab), Contrast(p.Text, p.Pressed),
                Contrast(p.Muted, p.Surface), Contrast(p.Muted, p.Background), Contrast(p.Muted, p.InactiveTab), Contrast(p.SelectionText, p.Selection),
                Contrast(p.AccentText, p.Accent), Contrast(p.AccentText, p.AccentHover), Contrast(p.AccentText, p.AccentPressed), Contrast(p.Error, p.Surface), Contrast(p.Error, p.Background) }.Min();
            check(Contrast(p.Text, p.Surface) >= 7 && weakest >= 4.5 && Contrast(p.Border, p.Surface) >= 1.5,
                name + " text, inputs, selected items, primary actions and errors meet normal-text contrast (text " + Contrast(p.Text, p.Surface).ToString("0.0") + ", weakest " + weakest.ToString("0.0") + ")");
        }
        check(AppAppearance.Resolve("Dark", null, false).Surface == AppAppearance.Resolve("Dark", null, false, "sage").Surface && AppAppearance.Resolve("Light", null, false, "unknown").Surface == AppAppearance.Resolve("Light", null, false, "sage").Surface
            && AppAppearance.Resolve("Dark", null, false, "slate").Surface != AppAppearance.Resolve("Dark", null, false, "clay").Surface,
            "An unnamed or unknown icon falls back to Sage, and different icons give different schemes");
        AppearancePalette high = AppAppearance.Resolve("Dark", false, true, "slate");
        check(high.HighContrast && high.Text == SystemColors.WindowText && high.Selection == SystemColors.Highlight && high.SelectionText == SystemColors.HighlightText && high.AccentText == SystemColors.HighlightText, "Windows high contrast colors take precedence over every icon scheme");
        check(high.ControlFace == SystemColors.Control && high.ControlLight == SystemColors.Window && high.ControlOutline == SystemColors.WindowText && high.ControlGlyph == SystemColors.ControlText
            && high.ChannelEdgeBefore == SystemColors.ControlDark && high.ChannelEdge == SystemColors.ControlDark, "High contrast gives the dropdown button and slider channel the system's colors");
        // Windows draws a list's dropdown button and the slider's channel light gray in every theme. Each scheme gives them
        // its background lightened (Dark) or darkened (Light), in that order, keeping the background's tint.
        foreach (string style in AppBranding.Styles) foreach (string mode in new[] { "Dark", "Light" }) {
            AppearancePalette p = AppAppearance.Resolve(mode, null, false, style);
            bool dark = mode == "Dark", strong = style == "contrast";
            Color[] parts = strong ? new[] { p.ControlFace } : dark ? new[] { p.ControlOutline, p.ControlFace, p.ControlLight, p.ChannelEdgeBefore, p.ChannelEdge } : new[] { p.ControlFace, p.ChannelEdgeBefore, p.ChannelEdge };
            bool ordered = new[] { p.Surface }.Concat(parts).Zip(parts, (before, after) => dark ? Light(after) > Light(before) : Light(after) < Light(before)).All(step => step);
            bool tinted = parts.All(part => Along(p.Surface, dark ? Color.White : Color.Black, part));
            bool framed = strong ? new[] { p.ControlOutline, p.ControlLight, p.ChannelEdgeBefore, p.ChannelEdge }.All(part => part == p.Border) : dark || (p.ControlOutline == p.Border && p.ControlLight == p.Input);
            check(ordered && tinted && framed && Contrast(p.ControlGlyph, p.ControlFace) >= 3,
                AppBranding.Title(style) + " " + mode + " gives the dropdown button and the slider channel its background's tint, with a readable arrow (" + Contrast(p.ControlGlyph, p.ControlFace).ToString("0.0") + ")");
        }
        // Scroll bars: the input color as the track and the background's tint in the thumb, stronger under the pointer and
        // while dragged. The black and white scheme draws its thumb in its border color.
        foreach (string style in AppBranding.Styles) foreach (string mode in new[] { "Dark", "Light" }) {
            AppearancePalette p = AppAppearance.Resolve(mode, null, false, style);
            bool dark = mode == "Dark";
            Color[] thumbs = { p.ScrollThumb, p.ScrollThumbHot, p.ScrollThumbPressed };
            bool shaded = style == "contrast" ? p.ScrollTrack == p.Surface && thumbs.All(thumb => thumb == p.Border)
                : p.ScrollTrack == p.Input && thumbs.All(thumb => Along(p.Surface, dark ? Color.White : Color.Black, thumb))
                    && (dark ? Light(p.ScrollThumb) < Light(p.ScrollThumbHot) && Light(p.ScrollThumbHot) < Light(p.ScrollThumbPressed)
                             : Light(p.ScrollThumb) > Light(p.ScrollThumbHot) && Light(p.ScrollThumbHot) > Light(p.ScrollThumbPressed));
            check(shaded && Contrast(p.ScrollThumb, p.ScrollTrack) >= 2,
                AppBranding.Title(style) + " " + mode + " gives its scroll bars a track in the input color and a thumb that stands out (" + Contrast(p.ScrollThumb, p.ScrollTrack).ToString("0.0") + ")");
        }
        check(high.ScrollTrack == SystemColors.Control && high.ScrollThumb == SystemColors.ControlDark && high.ScrollThumbHot == SystemColors.ControlDarkDark && high.ScrollThumbPressed == SystemColors.Highlight,
            "High contrast gives scroll bars the system's colors");
        AppearancePalette stone = AppAppearance.Resolve("Dark", null, false, "stone");
        Func<Color, int, bool> mockup = (color, rgb) => Near(color, Color.FromArgb((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255), 3);
        check(Same(stone.Surface, Color.FromArgb(0x36, 0x35, 0x31)) && mockup(stone.ControlFace, 0x72706D) && mockup(stone.ControlFace, 0x6F6F6B) && mockup(stone.ControlLight, 0x797874)
            && mockup(stone.ControlOutline, 0x65635D) && mockup(stone.ChannelEdgeBefore, 0x91908E) && mockup(stone.ChannelEdge, 0x9D9D9B) && Same(stone.ControlGlyph, Color.Black),
            "Stone Dark's dropdown button and slider channel match the user's color mock-up within three levels, with a black arrow");
        string[] resources = typeof(AppBranding).Assembly.GetManifestResourceNames();
        check(AppBranding.Styles.Length == 10 && resources.Count(name => name.StartsWith("BetterIcon.AppIcons.", StringComparison.Ordinal)) == 20 && AppBranding.Styles.All(style => new[] { "dark", "light" }.All(variant => resources.Contains(AppBranding.ResourceName(style, variant)))), "The built executable embeds all ten Dark and Light icon pairs, including Grayscale and High contrast");
        Func<string, string, bool> neutral = (style, variant) => AppBranding.Tones(style, variant).All(tone => Math.Abs(tone.R - tone.G) <= 1 && Math.Abs(tone.G - tone.B) <= 1);
        Color[] blackOnWhite = AppBranding.Tones("contrast", "light"), whiteOnBlack = AppBranding.Tones("contrast", "dark");
        check(neutral("grayscale", "dark") && neutral("grayscale", "light") && !neutral("slate", "dark")
            && blackOnWhite[0].R <= 8 && blackOnWhite[1].R >= 247 && whiteOnBlack[0].R <= 8 && whiteOnBlack[1].R >= 247 && Contrast(whiteOnBlack[0], whiteOnBlack[1]) >= 18,
            "The Grayscale icons hold no color and the High contrast icons are black and white");
        bool exactSmall = true;
        foreach (string style in AppBranding.Styles) foreach (string variant in new[] { "dark", "light" }) {
            using (Bitmap source = new Bitmap(Path.Combine(sourceFolder, "Assets", "AppIcons", "32px", "betterIcon_icon_" + style + "_" + variant + ".png")))
            using (Icon icon = AppBranding.Load(style, variant, 32)) using (Bitmap small = icon.ToBitmap()) {
                if (source.Size != new Size(32, 32) || small.Size != source.Size) { exactSmall = false; continue; }
                int opaque = 0;
                for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) if (source.GetPixel(x, y).A == 255) { opaque++; if (source.GetPixel(x, y) != small.GetPixel(x, y)) exactSmall = false; }
                if (opaque < 500) exactSmall = false;
            }
        }
        check(exactSmall, "Every embedded 32-pixel frame preserves the dedicated small artwork's opaque pixels exactly");

        Preferences pref = (Preferences)Field(form, "preferences");
        string savedMode = pref.AppearanceMode, savedStyle = pref.AppIconStyle, savedVariant = pref.AppIconVariant;
        string otherPreferences = json.Serialize(new { pref.Theme, pref.Scope, pref.IconSize, pref.Hotkey, pref.DefaultShortcuts });
        Button modeButton = (Button)Field(form, "appearanceModeButton"), iconButton = (Button)Field(form, "appIconButton");
        ContextMenuStrip iconChoices = (ContextMenuStrip)Field(form, "appIconMenu");
        Action<string> chooseIcon = text => iconChoices.Items.OfType<ToolStripMenuItem>().Single(item => item.Text == text).PerformClick();
        NotifyIcon tray = (NotifyIcon)Field(form, "tray");
        TabControl pages = (TabControl)Field(form, "pages");
        ContextMenuStrip[] menus = new[] { "trayMenu", "iconMenu", "importPackMenu", "managePackMenu", "appIconMenu" }.Select(name => (ContextMenuStrip)Field(form, name)).ToArray();
        try {
            form.ShowManager(); pages.SelectedIndex = 1;
            string[] expectedChoices = new[] { "Match app theme" }.Concat(AppBranding.Styles.SelectMany(style => new[] { AppBranding.Title(style) + " Dark", AppBranding.Title(style) + " Light" })).ToArray();
            check(iconChoices.Items.Cast<ToolStripItem>().Select(item => item.Text).SequenceEqual(expectedChoices) && iconChoices.Items.OfType<ToolStripMenuItem>().All(item => item.Image != null && item.DropDownItems.Count == 0), "The app-icon menu is one image-and-name list with all twenty variants and automatic pairing");
            check(!Descendants(form).OfType<ComboBox>().Any(control => control.AccessibleName == "App theme" || control.AccessibleName == "BetterIcon icon style" || control.AccessibleName == "BetterIcon icon variant"), "Appearance dropdowns are replaced by the two footer buttons");
            SelectMode(form, "Dark");
            foreach (string mode in new[] { "Light", "System", "Dark" }) {
                modeButton.PerformClick();
                check(pref.AppearanceMode == mode && json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).AppearanceMode == mode && modeButton.AccessibleName.Contains(mode), "The theme button immediately cycles to and saves " + mode);
            }
            chooseIcon("Match app theme");
            iconButton.PerformClick(); Application.DoEvents();
            check(iconChoices.Visible && (bool)typeof(LauncherForm).GetProperty("AppearanceMenuOpen", instance).GetValue(form, null) && Screen.FromControl(form).WorkingArea.Contains(iconChoices.Bounds), "The app-icon button opens its guarded menu entirely inside the monitor working area");
            check(iconChoices.Items.Cast<ToolStripItem>().Zip(iconChoices.Items.Cast<ToolStripItem>().Skip(1), (first, second) => first.Bounds.Bottom <= second.Bounds.Top && first.Bounds.Left == second.Bounds.Left).All(value => value), "App-icon choices form a nonoverlapping vertical list");
            iconChoices.Close();
            AppearancePalette darkPalette = AppAppearance.Resolve("Dark", style: pref.AppIconStyle);
            ListView launcherGrid = (ListView)Field(form, "apps"), packGrid = (ListView)Field(form, "packPreview");
            check(((AppearancePalette)Field(form, "appearancePalette")).Dark &&
                form.BackColor == (darkPalette.HighContrast ? darkPalette.Background : darkPalette.Surface) &&
                launcherGrid.BackColor == darkPalette.Surface && packGrid.ForeColor == darkPalette.Text &&
                launcherGrid.OwnerDraw && !packGrid.OwnerDraw,
                "Dark appearance reaches both grids with artwork highlighting confined to the launcher");
            check(menus.All(menu => menu.BackColor == darkPalette.Surface && menu.Items.Cast<ToolStripItem>().All(item => item.ForeColor == darkPalette.Text)), "Dark appearance reaches tray, icon, import and pack action menus including rebuilt items");
            HashSet<string> signatures = new HashSet<string>();
            Button applyButton = (Button)Field(form, "apply");
            foreach (string style in AppBranding.Styles) foreach (string variant in new[] { "dark", "light" }) {
                string shade = variant == "dark" ? "Dark" : "Light";
                chooseIcon(AppBranding.Title(style) + " " + shade);
                using (Icon expected = AppBranding.Load(style, variant)) using (Icon small = AppBranding.Load(style, variant, SystemInformation.SmallIconSize.Width)) using (Bitmap expectedPreview = AppBranding.Preview(style, variant, 32)) {
                    string signature = IconPixels(expected); signatures.Add(signature);
                    Preferences written = json.Deserialize<Preferences>(File.ReadAllText(preferencesPath));
                    check(IconPixels(form.Icon) == signature && IconPixels(tray.Icon) == IconPixels(small) && Pixels(iconButton.Image) == Pixels(expectedPreview) && written.AppIconStyle == style && written.AppIconVariant == shade && iconChoices.Items.OfType<ToolStripMenuItem>().Count(item => item.Checked) == 1,
                        "Selecting " + AppBranding.Title(style) + " " + variant + " updates the window, tray, preview and saved preference together");
                    AppearancePalette scheme = AppAppearance.Resolve(shade, style: style), applied = (AppearancePalette)Field(form, "appearancePalette");
                    check(written.AppearanceMode == shade && applied == scheme && form.BackColor == (scheme.HighContrast ? scheme.Background : scheme.Surface) && launcherGrid.BackColor == scheme.Surface && launcherGrid.ForeColor == scheme.Text
                        && applyButton.BackColor == scheme.Accent && applyButton.ForeColor == scheme.AccentText && menus.All(menu => menu.BackColor == scheme.Surface),
                        "Selecting " + AppBranding.Title(style) + " " + variant + " gives the app that icon's color scheme");
                }
            }
            check(signatures.Count == 20, "Every supplied color and variant produces distinct embedded artwork");
            using (Icon small = AppBranding.Load(pref.AppIconStyle, AppBranding.Variant(pref.AppIconVariant, AppAppearance.Resolve(pref.AppearanceMode).Dark), SystemInformation.SmallIconSize.Width))
                check(tray.Icon.Size == small.Size && tray.Icon.Width <= 32, "The notification-area icon explicitly uses a small frame rather than the large window icon handle");
            chooseIcon("Sage Dark"); chooseIcon("Match app theme"); SelectMode(form, "Dark");
            using (Icon sage = AppBranding.Load("sage", "dark")) check(IconPixels(form.Icon) == IconPixels(sage), "Sage Dark is the default icon for Dark appearance");
            SelectMode(form, "Light");
            AppearancePalette lightPalette = AppAppearance.Resolve("Light", style: "sage");
            using (Icon sage = AppBranding.Load("sage", "light")) check(IconPixels(form.Icon) == IconPixels(sage) && !((AppearancePalette)Field(form, "appearancePalette")).Dark && form.BackColor == (lightPalette.HighContrast ? lightPalette.Background : lightPalette.Surface), "Switching to Light immediately selects the matching light icon and control palette");
            chooseIcon("Sage Dark");
            using (Icon sage = AppBranding.Load("sage", "dark")) check(IconPixels(form.Icon) == IconPixels(sage) && ((AppearancePalette)Field(form, "appearancePalette")).Dark && pref.AppearanceMode == "Dark", "Choosing a Dark icon in a Light app switches the app to that icon's dark scheme");
            SelectMode(form, "Light");
            using (Icon sage = AppBranding.Load("sage", "dark")) check(IconPixels(form.Icon) == IconPixels(sage) && !((AppearancePalette)Field(form, "appearancePalette")).Dark, "A pinned Dark icon stays Dark when the theme button switches the app to Light");
            chooseIcon("Match app theme"); SelectMode(form, "System");
            Invoke(form, "OnSystemAppearanceChanged", null, new UserPreferenceChangedEventArgs(UserPreferenceCategory.General));
            Application.DoEvents();
            using (Icon expected = AppBranding.Load("sage", AppAppearance.SystemIsDark() ? "dark" : "light"))
                check(((AppearancePalette)Field(form, "appearancePalette")).Dark == AppAppearance.SystemIsDark() && IconPixels(form.Icon) == IconPixels(expected), "The Windows preference notification refreshes System appearance and its automatic pair");
            Preferences writtenFinal = json.Deserialize<Preferences>(File.ReadAllText(preferencesPath));
            check(json.Serialize(new { writtenFinal.Theme, writtenFinal.Scope, writtenFinal.IconSize, writtenFinal.Hotkey, writtenFinal.DefaultShortcuts }) == otherPreferences, "Appearance changes preserve all existing launcher, pack and shortcut preferences");
            iconButton.PerformClick(); Invoke(form, "SetBusy", true, null);
            check(!modeButton.Enabled && !iconButton.Enabled && !iconChoices.Visible, "Appearance controls and their open menu pause during a shortcut operation");
            LinkLabel shortcutLink = (LinkLabel)Field(form, "launcherShortcut"), versionLink = (LinkLabel)Field(form, "appVersion");
            check(!shortcutLink.Enabled, "The launcher shortcut editor pauses during an icon operation");
            Invoke(form, "SetBusy", false, null);
            check(shortcutLink.Enabled, "The launcher shortcut editor becomes available when the operation finishes");

            CheckChrome(form, check); CheckBusyThemes(form, check); CheckGridInput(form, check);
            CheckControlChrome(form, check); CheckThemedParts(form, check); CheckSinglePaint(form, check); CheckFormControls(form, check);
            foreach (string mode in new[] { "Dark", "Light" }) {
                SelectMode(form, mode);
                AppearancePalette p = (AppearancePalette)Field(form, "appearancePalette");
                check(new[] { shortcutLink, versionLink }.All(link => link.LinkColor == p.Muted &&
                    link.VisitedLinkColor == p.Muted && link.ActiveLinkColor == p.Text), mode + " keeps both footer links in the same muted text color");
                using (HotkeySettingsDialog dialog = new HotkeySettingsDialog(pref.Hotkey, false, value => null)) {
                    Invoke(form, "ApplyDialogAppearance", dialog); dialog.Show(form);
                    check(dialog.BackColor == p.Background && dialog.Controls.Cast<Control>().SelectMany(Descendants).Where(c => (c.Tag as string) == "ErrorText").All(c => c.ForeColor == p.Error), mode + " applies to the hotkey dialog and its error text");
                    dialog.Close();
                }
                using (PackEditor dialog = new PackEditor((PackLibrary)Field(form, "library"), null, false)) {
                    Invoke(form, "ApplyDialogAppearance", dialog); dialog.Show(form);
                    DataGridView grid = dialog.Controls.Cast<Control>().SelectMany(Descendants).OfType<DataGridView>().Single();
                    check(dialog.BackColor == p.Background && grid.DefaultCellStyle.BackColor == p.Input && grid.DefaultCellStyle.ForeColor == p.Text && !grid.EnableHeadersVisualStyles, mode + " applies to the pack editor and artwork assignment table");
                    dialog.Close();
                }
            }
        }
        finally {
            Invoke(form, "SetBusy", false, null);
            iconChoices.Close(); pref.AppearanceMode = savedMode; pref.AppIconStyle = savedStyle; pref.AppIconVariant = savedVariant; Invoke(form, "ChangeAppearance");
            // Preserve the explicit automated-test identity after cycling branding.
            tray.Icon = SystemIcons.Information; tray.Text = "BetterIcon automated tests";
        }
    }
    static IEnumerable<Control> Descendants(Control parent) { yield return parent; foreach (Control child in parent.Controls) foreach (Control nested in Descendants(child)) yield return nested; }
}
