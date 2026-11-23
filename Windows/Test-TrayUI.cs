// Local native event tests. Launches only a disposable probe through its fixture shortcut.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using BetterIcon.Tray;

static class TrayTests
{
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] struct NativeRect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", EntryPoint = "SendMessageW")] static extern IntPtr SendMessageRect(IntPtr window, int message, IntPtr wParam, out NativeRect rectangle);
    [DllImport("user32.dll")] static extern bool GetKeyboardState(byte[] state);
    [DllImport("user32.dll")] static extern bool SetKeyboardState(byte[] state);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr window, int index);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point point);
    [DllImport("user32.dll")] static extern int GetWindowRgn(IntPtr window, IntPtr region);
    [DllImport("gdi32.dll")] static extern IntPtr CreateRectRgn(int left, int top, int right, int bottom);
    [DllImport("gdi32.dll")] static extern bool PtInRegion(IntPtr region, int x, int y);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr value);
    [DllImport("comctl32.dll")] static extern bool ImageList_GetIconSize(IntPtr list, out int width, out int height);
    [DllImport("comctl32.dll")] static extern int ImageList_GetImageCount(IntPtr list);
    [DllImport("comctl32.dll")] static extern bool ImageList_Draw(IntPtr list, int index, IntPtr dc, int x, int y, uint flags);
    static readonly List<object> checks = new List<object>();
    static void PlainText(LauncherForm form, string text)
    {
        // Reflected character events represent plain typing. Isolate them from
        // stale modifier state in this test thread when another app takes focus.
        // This changes no global state and injects no keyboard input.
        byte[] previous = new byte[256];
        if (!GetKeyboardState(previous)) throw new Exception("Cannot read the test thread's keyboard state.");
        byte[] plain = (byte[])previous.Clone();
        foreach (int key in new[] { 0x11, 0x12, 0xA2, 0xA3, 0xA4, 0xA5 }) plain[key] = 0;
        if (!SetKeyboardState(plain)) throw new Exception("Cannot initialize the test thread's modifiers.");
        try { foreach (char character in text) typeof(LauncherForm).GetMethod("OnKeyPress", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(form, new object[] { new KeyPressEventArgs(character) }); }
        finally { SetKeyboardState(previous); }
    }
    static void Check(bool ok, string name)
    {
        checks.Add(new { Test = name, Passed = ok });
        if (!ok) throw new Exception(name);
        Console.WriteLine("PASS: " + name);
    }
    static Point TabDivider(TabControl tabs) { return tabs.PointToScreen(tabs.GetTabRect(1).Location); }
    static IntPtr MousePoint(Rectangle rect)
    {
        return new IntPtr(((rect.Top + rect.Height / 2) << 16) | ((rect.Left + rect.Width / 2) & 0xffff));
    }
    static Bitmap PaintGrid(ListView grid)
    {
        Bitmap frame = new Bitmap(grid.Width, grid.Height);
        grid.Refresh();
        grid.DrawToBitmap(frame, grid.ClientRectangle);
        return frame;
    }
    static void CheckLauncherFeedback(ListView grid, string root)
    {
        Rectangle tile = grid.Items[0].Bounds;
        IntPtr point = MousePoint(grid.GetItemRect(0, ItemBoundsPortion.Icon));
        SendMessage(grid.Handle, 0x02A3, IntPtr.Zero, IntPtr.Zero); // WM_MOUSELEAVE
        using (Bitmap idle = PaintGrid(grid)) {
            SendMessage(grid.Handle, 0x0200, IntPtr.Zero, point);
            using (Bitmap hover = PaintGrid(grid)) {
                Check(grid.SelectedItems.Count == 0, "Hover brightens artwork without committing a selection");
                SendMessage(grid.Handle, 0x02A3, IntPtr.Zero, IntPtr.Zero);
                grid.Items[0].Selected = grid.Items[0].Focused = true;
                using (Bitmap selected = PaintGrid(grid)) {
                    int brighter = 0, changedBackground = 0, different = 0;
                    Rectangle icon = grid.GetItemRect(0, ItemBoundsPortion.Icon);
                    for (int y = tile.Top; y < tile.Bottom; y++)
                        for (int x = tile.Left; x < tile.Right; x++) {
                            Color before = idle.GetPixel(x, y), after = hover.GetPixel(x, y);
                            // Inside the image, antialiased artwork may round to the background RGB.
                            if (!icon.Contains(x, y) && before != after) changedBackground++;
                            if (after.R > before.R + 8 || after.G > before.G + 8 || after.B > before.B + 8) brighter++;
                            if (after != selected.GetPixel(x, y)) different++;
                        }
                    Check(brighter > 50 && changedBackground == 0 && different == 0,
                        "Mouse and keyboard brighten the same artwork with clear padding (" + brighter + " brighter pixels, " +
                        changedBackground + " changed background pixels, " + different + " mouse/keyboard differences)");
                }
            }
        }
        // The receiving shortcut writes one unique receipt per launched process.
        int initial = Directory.GetFiles(root, "launches.txt.*.launched").Length;
        point = MousePoint(grid.GetItemRect(2, ItemBoundsPortion.Label));
        Rectangle cell = grid.GetItemRect(2, ItemBoundsPortion.Icon);
        IntPtr window = grid.Handle;
        // Deliver anything the hover checks left queued before the press begins.
        Application.DoEvents();
        Rectangle restBox, heldBox, backBox; double restLight, heldLight, backLight;
        using (Bitmap resting = PaintGrid(grid)) {
            Artwork(resting, cell, grid.BackColor, out restBox, out restLight);
            // The native list waits in its own loop while the button is down. Look at the grid from inside that loop.
            Bitmap held = null; bool done = false;
            using (System.Windows.Forms.Timer whileDown = new System.Windows.Forms.Timer { Interval = 40 }) {
                whileDown.Tick += delegate { whileDown.Stop(); held = PaintGrid(grid); PostMessage(window, 0x0202, IntPtr.Zero, point); };
                // Release the button anyway if that loop never runs the timer, so a failure cannot hang the suite.
                ThreadPool.QueueUserWorkItem(delegate { Thread.Sleep(3000); if (!done && held == null) PostMessage(window, 0x0202, IntPtr.Zero, point); });
                whileDown.Start();
                SendMessage(window, 0x0201, new IntPtr(1), point);
                done = true;
            }
            Check(held != null, "The grid can be seen while the mouse button is held on an app");
            using (held) Artwork(held, cell, grid.BackColor, out heldBox, out heldLight);
            using (Bitmap released = PaintGrid(grid)) Artwork(released, cell, grid.BackColor, out backBox, out backLight);
        }
        Check(restBox.Width > 12 && heldBox.Width <= restBox.Width - 2 && heldBox.Height <= restBox.Height - 2
            && Math.Abs(heldBox.Left + heldBox.Right - restBox.Left - restBox.Right) <= 2 && Math.Abs(heldBox.Top + heldBox.Bottom - restBox.Top - restBox.Bottom) <= 2
            && heldLight < restLight * 0.95,
            "Holding the mouse button on an app draws its artwork slightly smaller, centered and darker (" + restBox.Size + " to " + heldBox.Size + ", brightness " + (int)restLight + " to " + (int)heldLight + ")");
        Check(backBox.Width >= restBox.Width - 1 && backBox.Height >= restBox.Height - 1 && backLight >= restLight,
            "Releasing the button returns the artwork to full size (" + backBox.Size + ", brightness " + (int)backLight + ")");
        Application.DoEvents();
        for (int retry = 0; retry < 100 && Directory.GetFiles(root, "launches.txt.*.launched").Length == initial; retry++) {
            Application.DoEvents();
            Thread.Sleep(20);
        }
        Check(Directory.GetFiles(root, "launches.txt.*.launched").Length == initial + 1,
            "One left click on the app label opens the fixture shortcut exactly once");
        PostMessage(grid.Handle, 0x0203, new IntPtr(1), point); // second press of a double-click
        PostMessage(grid.Handle, 0x0202, IntPtr.Zero, point);
        Application.DoEvents();
        for (int elapsed = 0; elapsed < SystemInformation.DoubleClickTime + 100; elapsed += 20) {
            Application.DoEvents();
            Thread.Sleep(20);
        }
        Check(Directory.GetFiles(root, "launches.txt.*.launched").Length == initial + 1,
            "The second press of a double-click does not open a duplicate app");

        // A press that turns into a drag pops back at once and opens nothing.
        IntPtr away = MousePoint(grid.GetItemRect(0, ItemBoundsPortion.Icon));
        bool moved = false;
        using (System.Windows.Forms.Timer whileDown = new System.Windows.Forms.Timer { Interval = 40 }) {
            whileDown.Tick += delegate { whileDown.Stop(); moved = true; PostMessage(window, 0x0200, new IntPtr(1), away); };
            ThreadPool.QueueUserWorkItem(delegate { Thread.Sleep(3000); if (!moved) PostMessage(window, 0x0202, IntPtr.Zero, point); });
            whileDown.Start();
            SendMessage(window, 0x0201, new IntPtr(1), point);
        }
        Rectangle draggedBox; double draggedLight;
        using (Bitmap dragged = PaintGrid(grid)) Artwork(dragged, cell, grid.BackColor, out draggedBox, out draggedLight);
        PostMessage(window, 0x0202, IntPtr.Zero, away);
        for (int elapsed = 0; elapsed < 300; elapsed += 20) { Application.DoEvents(); Thread.Sleep(20); }
        Check(moved && draggedBox.Width >= restBox.Width - 1 && draggedBox.Height >= restBox.Height - 1
            && Directory.GetFiles(root, "launches.txt.*.launched").Length == initial + 1,
            "Dragging off a pressed app returns its artwork to full size and opens nothing (" + draggedBox.Size + ")");
    }
    // The extent and average brightness of the artwork drawn inside one icon cell.
    static void Artwork(Bitmap frame, Rectangle cell, Color background, out Rectangle box, out double brightness)
    {
        cell.Intersect(new Rectangle(Point.Empty, frame.Size));
        int left = Int32.MaxValue, top = Int32.MaxValue, right = -1, bottom = -1, count = 0; long sum = 0;
        for (int y = cell.Top; y < cell.Bottom; y++)
            for (int x = cell.Left; x < cell.Right; x++) {
                Color pixel = frame.GetPixel(x, y);
                if (Math.Abs(pixel.R - background.R) + Math.Abs(pixel.G - background.G) + Math.Abs(pixel.B - background.B) < 24) continue;
                left = Math.Min(left, x); top = Math.Min(top, y); right = Math.Max(right, x); bottom = Math.Max(bottom, y);
                sum += pixel.R + pixel.G + pixel.B; count++;
            }
        box = count == 0 ? Rectangle.Empty : Rectangle.FromLTRB(left, top, right + 1, bottom + 1);
        brightness = count == 0 ? 0 : (double)sum / count;
    }
    static void ClickTab(TabControl tabs, int index)
    {
        Rectangle tab = tabs.GetTabRect(index);
        IntPtr point = new IntPtr(((tab.Top + tab.Height / 2) << 16) | (tab.Left + tab.Width / 2));
        SendMessage(tabs.Handle, 0x0201, new IntPtr(1), point);
        SendMessage(tabs.Handle, 0x0202, IntPtr.Zero, point);
    }
    static void ResizePopup(LauncherForm form, Size size)
    {
        SendMessage(form.Handle, 0x0231, IntPtr.Zero, IntPtr.Zero); // WM_ENTERSIZEMOVE
        form.Size = size;
        SendMessage(form.Handle, 0x0232, IntPtr.Zero, IntPtr.Zero); // WM_EXITSIZEMOVE
    }
    static void CheckTabWindowSizes(string root, string source)
    {
        Size compact = new Size(301, 241), manage = new Size(836, 606);
        foreach (Rectangle area in new[] { new Rectangle(-1440, -180, 1440, 850), new Rectangle(40, 60, 640, 480), new Rectangle(-1, -1, 1, 1) }) {
            foreach (Point edge in new[] { area.Location, new Point(area.Right, area.Bottom) }) {
                Rectangle a = PopupPlacement.AtTabDivider(compact, manage, edge, area);
                Point join = new Point(a.Left + a.Width / 2, a.Top);
                Rectangle b = PopupPlacement.AtTabDivider(manage, compact, join, area);
                Check(area.Contains(a) && area.Contains(b) && b.Left + b.Width / 2 == join.X && b.Top == join.Y,
                    "Both tab sizes fit around one divider on work area " + area + " near " + edge);
            }
        }
        string state = Path.Combine(root, "tab-sizes"), path = Path.Combine(state, "tray-preferences.json");
        Directory.CreateDirectory(state);
        File.WriteAllText(path, "{\"Scope\":\"AllUsers\",\"IconSize\":72}");
        FixtureConfig fixture = new FixtureConfig { ShortcutDirectory = new[] { root }, StateDirectory = state, KeepOpenForAutomation = true };
        BindingFlags instance = BindingFlags.Instance | BindingFlags.NonPublic;
        Rectangle work = Screen.PrimaryScreen.WorkingArea;
        Point middle = new Point(work.Left + work.Width / 2, work.Top + work.Height / 2);
        using (EventWaitHandle show = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (EventWaitHandle stop = new EventWaitHandle(false, EventResetMode.AutoReset)) {
            for (int pass = 0; pass < 2; pass++) using (LauncherForm form = new LauncherForm(source, fixture, true, show, stop)) {
                try {
                    form.ShowAtCursor(middle);
                    TabControl tabs = (TabControl)typeof(LauncherForm).GetField("pages", instance).GetValue(form);
                    if (pass == 0) {
                        Check(form.Bounds == PopupPlacement.CenteredOnCursor(new Size(900, 818), middle, work), "Existing preferences open at the original default size");
                        form.Hide(); form.ToggleAboveTray(middle);
                        Check(tabs.SelectedIndex == 0, "Equal saved sizes open Launcher from the tray");
                        typeof(LauncherForm).GetMethod("UpdateHotkeyHint", instance).Invoke(form, null);
                        ResizePopup(form, new Size(110, 90));
                        LinkLabel shortcut = (LinkLabel)typeof(LauncherForm).GetField("launcherShortcut", instance).GetValue(form);
                        ListView grid = (ListView)typeof(LauncherForm).GetField("apps", instance).GetValue(form);
                        Check(form.Size == new Size(300, 240) && tabs.GetTabRect(1).Right <= tabs.ClientSize.Width &&
                            shortcut.Visible && shortcut.Text.Contains("unavailable") && shortcut.Parent.ClientRectangle.Contains(shortcut.Bounds) &&
                            shortcut.Height >= shortcut.GetPreferredSize(new Size(shortcut.Width, 0)).Height && grid.Height >= 48,
                            "Compact Launcher fits both tab headers, the unavailable-shortcut link and the app grid");
                        ResizePopup(form, compact);
                    }
                    Check(form.Size == compact, "Launcher restores its own odd-sized window, pass " + pass);
                    Point join = TabDivider(tabs);
                    ClickTab(tabs, 1);
                    Check(tabs.SelectedIndex == 1 && TabDivider(tabs) == join && form.MinimumSize == new Size(790, 570),
                        "Clicking Manage Icons keeps the native tab divider fixed and applies its own minimum, pass " + pass);
                    if (pass == 0) {
                        ResizePopup(form, new Size(110, 90));
                        Check(form.Size == new Size(790, 570), "Manage Icons retains its larger minimum after a compact Launcher resize");
                        ResizePopup(form, manage);
                    }
                    Check(form.Size == manage, "Manage Icons restores its own dimensions, pass " + pass);
                    join = TabDivider(tabs);
                    for (int i = 0; i < 4; i++) {
                        int page = i % 2;
                        ClickTab(tabs, page);
                        Check(tabs.SelectedIndex == page && form.Size == (page == 0 ? compact : manage) && TabDivider(tabs) == join,
                            "Repeated tab clicks preserve both sizes and the divider pixel, pass " + pass + ", switch " + i);
                    }
                    form.Hide();
                    form.ToggleAboveTray(new Point(work.Right - 1, work.Bottom - 1));
                    join = TabDivider(tabs);
                    Check(tabs.SelectedIndex == 1 && form.Size == manage && work.Contains(form.Bounds) && work.Bottom - form.Bottom <= 9,
                        "A tray click opens the larger Manage Icons tab adjacent to the taskbar");
                    ClickTab(tabs, 0);
                    Check(TabDivider(tabs) == join && form.Size == compact && work.Contains(form.Bounds), "Launcher fits at the tray edge without moving the divider");
                    ClickTab(tabs, 1); form.ShowAtCursor(middle);
                    Check(tabs.SelectedIndex == 0 && form.Size == compact, "The keyboard shortcut opens Launcher even when Manage Icons is larger and visible");
                    if (pass == 0) {
                        Size wide = new Size(1024, 540);
                        ResizePopup(form, wide); form.Hide(); form.ToggleAboveTray(middle);
                        Check(tabs.SelectedIndex == 0 && form.Size == wide, "The tray chooses Launcher when it has more area but less height than Manage Icons");
                        ResizePopup(form, compact);
                    }
                    Preferences saved = new JavaScriptSerializer().Deserialize<Preferences>(File.ReadAllText(path));
                    Check(saved.LauncherWindowSize == compact && saved.ManageWindowSize == manage && saved.IconSize == 72 && saved.Scope == "AllUsers",
                        "Only resized tabs update their saved dimensions and other preferences survive");
                }
                finally { typeof(LauncherForm).GetMethod("RequestExternalStop", instance).Invoke(form, null); }
            }
        }
    }
    static void CheckProjectLink(LinkLabel link, string root)
    {
        string target = (string)link.Links[0].LinkData;
        Check(target == "https://github.com/BinziiBinzet/bettericon-craft-apps" &&
            link.Text == "Better Icon for ArtCraft version " + typeof(LauncherForm).Assembly.GetName().Version.ToString(3),
            "The full version label links to the BetterIcon repository");
        // Use the same shell action with a disposable shortcut so the check cannot open the user's browser.
        int before = Directory.GetFiles(root, "launches.txt.*.launched").Length;
        try {
            link.Links[0].LinkData = Path.Combine(root, "PhotoCraft.lnk");
            ((IButtonControl)link).PerformClick();
            Check(SpinWait.SpinUntil(() => Directory.GetFiles(root, "launches.txt.*.launched").Length == before + 1, 5000),
                "Activating the version link hands its destination to the Windows shell");
        }
        finally { link.Links[0].LinkData = target; }
    }
    static void CheckWindowResizing(LauncherForm form)
    {
        int style = GetWindowLong(form.Handle, -16);
        Check((style & 0x00040000) != 0 && (style & (0x00C00000 | 0x00080000)) == 0,
            "The popup supports native resizing without a caption or window buttons");
        Check(form.ClientSize == form.Size, "The resize frame adds no nonclient inset or title bar");
        int lastX = form.ClientSize.Width - 2, lastY = form.ClientSize.Height - 2;
        Point[] points = { new Point(1, lastY / 2), new Point(lastX, lastY / 2), new Point(lastX / 2, 1), new Point(lastX / 2, lastY),
            new Point(14, 14), new Point(lastX - 13, 14), new Point(14, lastY - 13), new Point(lastX - 13, lastY - 13) };
        int[] expected = { 10, 11, 12, 15, 13, 14, 16, 17 };
        for (int i = 0; i < points.Length; i++) {
            Point screen = form.PointToScreen(points[i]);
            IntPtr position = new IntPtr(unchecked((screen.X & 0xFFFF) | ((screen.Y & 0xFFFF) << 16)));
            int actual = SendMessage(form.Handle, 0x0084, IntPtr.Zero, position).ToInt32(); IntPtr window = WindowFromPoint(screen);
            Check(actual == expected[i] && window == form.Handle,
                "Native resize direction " + expected[i] + " remains reachable along the outline and through child controls (hit=" + actual + ", window=" + window + ", form=" + form.Handle + ", point=" + screen + ", bounds=" + form.Bounds + ", region=" + (form.Region != null && form.Region.IsVisible(points[i])) + ")");
        }
        Point center = form.PointToScreen(new Point(form.ClientSize.Width / 2, form.ClientSize.Height / 2));
        Check(SendMessage(form.Handle, 0x0084, IntPtr.Zero, new IntPtr(unchecked((center.X & 0xFFFF) | ((center.Y & 0xFFFF) << 16)))).ToInt32() == 1,
            "The popup interior stays client content rather than a draggable title bar");
    }
    static bool NativeRoundedOutline(LauncherForm form)
    {
        IntPtr region = CreateRectRgn(0, 0, 0, 0);
        try {
            return GetWindowRgn(form.Handle, region) == 3 && !PtInRegion(region, 0, 0) && !PtInRegion(region, 8, 8) && PtInRegion(region, 16, 6)
                && PtInRegion(region, 32, 1) && PtInRegion(region, form.Width / 2, form.Height / 2)
                && !PtInRegion(region, form.Width - 1, 0) && !PtInRegion(region, 0, form.Height - 1) && !PtInRegion(region, form.Width - 1, form.Height - 1)
                && PtInRegion(region, form.Width - 17, form.Height - 7);
        }
        finally { DeleteObject(region); }
    }
    static void CheckRoundedWindow(LauncherForm form)
    {
        BindingFlags instance = BindingFlags.Instance | BindingFlags.NonPublic;
        TabControl pages = (TabControl)typeof(LauncherForm).GetField("pages", instance).GetValue(form);
        Size previous = form.Size;
        Check(NativeRoundedOutline(form), "The real native outline has the selected 32-pixel radius and transparent outer corners");
        foreach (Size size in new[] { new Size(790, 570), new Size(1100, 800) }) {
            form.Size = size; Application.DoEvents();
            Check(NativeRoundedOutline(form), "Resizing to " + size + " rebuilds all rounded edges without leaving the old outline");
        }
        form.Size = previous;
        for (int page = 0; page < 2; page++) {
            pages.SelectedIndex = page; Application.DoEvents();
            Point corner = form.PointToScreen(new Point(14, form.Height - 15));
            Check(WindowFromPoint(corner) == form.Handle, "The " + (page == 0 ? "Launcher" : "Settings") + " corner passes child-control hits to native resizing");
        }
        typeof(Control).GetMethod("RecreateHandle", instance).Invoke(pages, null);
        Point top = form.PointToScreen(new Point(14, 14));
        Check(NativeRoundedOutline(form) && WindowFromPoint(top) == form.Handle, "Recreated child handles retain the rounded-corner resize target");
        pages.SelectedIndex = 0;
    }
    static IEnumerable<Control> Descendants(Control parent)
    {
        foreach (Control child in parent.Controls) { yield return child; foreach (Control nested in Descendants(child)) yield return nested; }
    }
    static void CheckAppIconEditing(LauncherForm form, string root, string preferencesPath, JavaScriptSerializer json)
    {
        BindingFlags instance = BindingFlags.Instance | BindingFlags.NonPublic;
        Func<string, object> field = name => typeof(LauncherForm).GetField(name, instance).GetValue(form);
        ComboBox themes = (ComboBox)field("themes"); Catalog catalog = (Catalog)field("catalog");
        Preferences preferences = (Preferences)field("preferences"); PackLibrary library = (PackLibrary)field("library");
        ThemeEntry basis = themes.Items.Cast<ThemeEntry>().First(theme => theme.Id == "Craft-Icons-Zach/HyGel");
        string previousTheme = preferences.Theme; string[] previousDefaults = preferences.DefaultShortcuts;
        string previousApplied = preferences.AppliedTheme; Dictionary<string, string> previousAppliedArtwork = preferences.AppliedArtwork;
        MethodInfo reload = typeof(LauncherForm).GetMethod("ReloadLibrary", instance), change = typeof(LauncherForm).GetMethod("ChangeAppIcon", instance);
        MethodInfo remember = typeof(LauncherForm).GetMethod("RememberAppliedTheme", instance), render = typeof(LauncherForm).GetMethod("RenderSelection", instance);
        string png = Path.Combine(root, "context-choice.png"), other = Path.Combine(root, "context-other.png");
        using (Bitmap bitmap = new Bitmap(128, 128)) {
            using (Graphics canvas = Graphics.FromImage(bitmap)) canvas.Clear(Color.Lime);
            bitmap.Save(png, System.Drawing.Imaging.ImageFormat.Png);
            using (Graphics canvas = Graphics.FromImage(bitmap)) canvas.Clear(Color.Magenta);
            bitmap.Save(other, System.Drawing.Imaging.ImageFormat.Png);
        }
        AppEntry photo = catalog.Apps.First(app => app.Application == "PhotoCraft"), film = catalog.Apps.First(app => app.Application == "FilmCraft");
        Dictionary<string, byte[]> bundled = basis.Icons.ToDictionary(icon => icon.Application, icon => File.ReadAllBytes(String.IsNullOrEmpty(icon.PreviewPath) ? icon.Path : icon.PreviewPath));
        byte[] shortcut = File.ReadAllBytes(Path.Combine(root, "PhotoCraft.lnk"));
        try {
            Check(!Descendants(form).Any(control => control.Text == "Restore one app" || control.Text == "Restore app default..." || control.AccessibleName == "App to restore"),
                "Settings removes the redundant individual restore section");
            reload.Invoke(form, new object[] { basis.Id });
            preferences.DefaultShortcuts = new[] { photo.Shortcut, film.Shortcut };
            string unchangedPreferences = json.Serialize(new { preferences.Scope, preferences.IconSize, preferences.Hotkey, preferences.ShowAppNames, preferences.AppearanceMode, preferences.AppIconStyle, preferences.AppIconVariant });
            int count = library.VisibleThemes(new ThemeEntry[0]).Length;
            Task saving = (Task)change.Invoke(form, new object[] { photo, png });
            Check((bool)field("busy") && ((Control)field("loadingPanel")).Visible && !((ToolStripMenuItem)field("chooseAppIcon")).Enabled,
                "Choosing artwork shows loading and disables further icon edits while saving");
            LoadingTests.Wait(saving);
            ThemeEntry saved = (ThemeEntry)themes.SelectedItem;
            Check(saved.Managed && saved.Author == basis.Author && saved.IconCount == basis.IconCount && library.VisibleThemes(new ThemeEntry[0]).Length == count + 1,
                "Editing a built-in icon creates one complete personal pack with the existing author credit");
            Check(saved.Icons.All(icon => File.ReadAllBytes(icon.Path).SequenceEqual(icon.Application == photo.Application ? File.ReadAllBytes(png) : bundled[icon.Application]))
                && basis.Icons.All(icon => File.ReadAllBytes(String.IsNullOrEmpty(icon.PreviewPath) ? icon.Path : icon.PreviewPath).SequenceEqual(bundled[icon.Application])),
                "A context edit replaces only the chosen assignment and leaves bundled source artwork intact");
            List<Bitmap> appImages = (List<Bitmap>)field("appArtwork"), packImages = (List<Bitmap>)field("packArtwork");
            int appIndex = Array.IndexOf(catalog.Apps, photo), packIndex = saved.Icons.OrderBy(icon => icon.Application).ToList().FindIndex(icon => icon.Application == photo.Application);
            Check(appImages[appIndex].GetPixel(64, 64).ToArgb() != Color.Lime.ToArgb() && packImages[packIndex].GetPixel(64, 64).ToArgb() == Color.Lime.ToArgb(),
                "The selected image immediately appears in the Settings preview while the Launcher waits for Apply");
            remember.Invoke(form, new object[] { saved }); render.Invoke(form, null);
            Check(appImages[appIndex].GetPixel(64, 64).ToArgb() == Color.Lime.ToArgb() && preferences.AppliedTheme == saved.Id && preferences.AppliedArtwork[photo.Application] == saved.Icons.Single(icon => icon.Application == photo.Application).Path,
                "Applying the edited pack brings its image to the Launcher");
            Preferences written = json.Deserialize<Preferences>(File.ReadAllText(preferencesPath));
            Check(written.Theme == saved.Id && written.DefaultShortcuts.SequenceEqual(new[] { film.Shortcut }) && unchangedPreferences == json.Serialize(new { preferences.Scope, preferences.IconSize, preferences.Hotkey, preferences.ShowAppNames, preferences.AppearanceMode, preferences.AppIconStyle, preferences.AppIconVariant }),
                "The edited pack persists, replaces only the edited app's remembered defaults and retains other settings");
            Check(File.ReadAllBytes(Path.Combine(root, "PhotoCraft.lnk")).SequenceEqual(shortcut) && ((Label)field("status")).Text.Contains("Apply icons"),
                "Choosing artwork leaves Windows shortcuts unchanged and explains the separate Apply action");
            LoadingTests.Wait((Task)change.Invoke(form, new object[] { film, other }));
            ThemeEntry edited = (ThemeEntry)themes.SelectedItem;
            Check(edited.LibraryId == saved.LibraryId && edited.Id != saved.Id && edited.Name == saved.Name && library.VisibleThemes(new ThemeEntry[0]).Length == count + 1
                && File.ReadAllBytes(edited.Icons.Single(icon => icon.Application == photo.Application).Path).SequenceEqual(File.ReadAllBytes(png))
                && File.ReadAllBytes(saved.Icons.Single(icon => icon.Application == film.Application).Path).SequenceEqual(bundled[film.Application]),
                "A second edit updates the same personal pack while retaining other choices and immutable earlier revisions");
            int filmIndex = Array.IndexOf(catalog.Apps, film);
            Check(appImages[appIndex].GetPixel(64, 64).ToArgb() == Color.Lime.ToArgb() && appImages[filmIndex].GetPixel(64, 64).ToArgb() != Color.Magenta.ToArgb() && preferences.AppliedTheme == saved.Id,
                "A later edit to an applied pack stays out of the Launcher until it is applied again");
            string manifest = Path.Combine(library.Root, "library.json"), invalid = Path.Combine(root, "bad-context-icon.png");
            byte[] beforeManifest = File.ReadAllBytes(manifest), beforePreferences = File.ReadAllBytes(preferencesPath);
            File.WriteAllText(invalid, "Invalid image"); bool rejected = false;
            try { LoadingTests.Wait((Task)change.Invoke(form, new object[] { photo, invalid })); } catch (IOException) { rejected = true; }
            Check(rejected && File.ReadAllBytes(manifest).SequenceEqual(beforeManifest) && File.ReadAllBytes(preferencesPath).SequenceEqual(beforePreferences)
                && ((ThemeEntry)themes.SelectedItem).Id == edited.Id && !(bool)field("busy") && !((Control)field("loadingPanel")).Visible,
                "Invalid artwork leaves the pack and preferences intact and clears loading");
            ThemeEntry duplicate = library.ReplaceAppIcon(basis, photo.Application, png);
            Check(duplicate.LibraryId != saved.LibraryId && duplicate.Name != saved.Name && library.VisibleThemes(new ThemeEntry[0]).Any(theme => theme.Id == edited.Id),
                "Another edit from the same built-in gets a unique name without overwriting a personal pack");
            ThemeEntry defaults = themes.Items.Cast<ThemeEntry>().First(theme => theme.IsDefault);
            ThemeEntry fromDefault = library.ReplaceAppIcon(defaults, photo.Application, png);
            Check(fromDefault.Managed && fromDefault.Icons.Single().Application == photo.Application && defaults.Icons.Length == 0,
                "Choosing artwork from ArtCraft default creates a personal pack without modifying the virtual default");
        }
        finally {
            preferences.DefaultShortcuts = previousDefaults; preferences.AppliedTheme = previousApplied; preferences.AppliedArtwork = previousAppliedArtwork;
            reload.Invoke(form, new object[] { previousTheme });
        }
    }
    static string SettingsLayoutProblem(Control parent)
    {
        // Native list items/scrollbars are not independent layout controls.
        if (parent is ListView) return null;
        Control[] children = parent.Controls.Cast<Control>().Where(c => c.Visible).ToArray();
        for (int i = 0; i < children.Length; i++) {
            Control child = children[i];
            string name = String.IsNullOrEmpty(child.Name) ? child.GetType().Name + " " + child.Text : child.Name;
            if (child.Width <= 0 || child.Height <= 0) return name + " has no usable area";
            ScrollableControl scroll = parent as ScrollableControl;
            if (scroll == null || !scroll.AutoScroll) {
                Rectangle allowed = parent.ClientRectangle; allowed.Inflate(1, 1);
                if (!allowed.Contains(child.Bounds)) return name + " is clipped by " + parent.GetType().Name + ": " + child.Bounds + " outside " + parent.ClientRectangle;
            }
            for (int j = i + 1; j < children.Length; j++) {
                Rectangle overlap = Rectangle.Intersect(child.Bounds, children[j].Bounds);
                if (overlap.Width > 1 && overlap.Height > 1) return name + " overlaps " + children[j].GetType().Name + " " + children[j].Text;
            }
            Button button = child as Button;
            // One pixel of rounding in a shared row does not reach the text.
            if (button != null && button.Text.Length > 0 && button.Width + 1 < button.GetPreferredSize(Size.Empty).Width)
                return name + " cuts off its label: " + button.Width + " of " + button.GetPreferredSize(Size.Empty).Width + " pixels";
            string nested = SettingsLayoutProblem(child);
            if (nested != null) return nested;
        }
        return null;
    }
    // The shared button rows, apart from any window.
    static void CheckButtonRows()
    {
        Type type = typeof(LauncherForm).Assembly.GetType("BetterIcon.Tray.ButtonRow", true);
        using (Font font = new Font("Segoe UI", 10F))
        using (TableLayoutPanel table = new TableLayoutPanel { Font = font }) {
            Button[] row = new[] { "Apply icons...", "Restore app defaults...", "Apply file icons...", "Restore file icons..." }
                .Select(text => new Button { Text = text, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = new Padding(10, 3, 10, 3), Margin = new Padding(4, 0, 4, 0) }).ToArray();
            object rows = Activator.CreateInstance(type, new object[] { table, row, new[] { row[0], row[2], row[1], row[3] }, 2 });
            Func<Button, int> needs = button => button.GetPreferredSize(Size.Empty).Width + button.Margin.Horizontal;
            int widest = row.Max(needs), pair = Math.Max(needs(row[0]) + needs(row[1]), needs(row[2]) + needs(row[3]));
            Action<int> arrange = width => type.GetMethod("Arrange").Invoke(rows, new object[] { width });
            Func<Button, Point> cell = button => new Point(table.GetCellPosition(button).Column, table.GetCellPosition(button).Row);
            Func<int, float> share = column => table.ColumnStyles[column].Width;
            arrange(widest * 4);
            Check(table.ColumnCount == 4 && table.RowCount == 1 && Enumerable.Range(0, 4).All(i => cell(row[i]) == new Point(i, 0) && Math.Abs(share(i) - 25) < 0.01),
                "Four buttons share one row equally while every label fits");
            arrange(pair * 2);
            Check(table.ColumnCount == 4 && Enumerable.Range(0, 4).All(i => cell(row[i]) == new Point(i, 0)) && share(1) > share(0) + 1
                && Math.Abs(share(0) + share(1) - 50) < 0.01 && Math.Abs(share(2) + share(3) - 50) < 0.01,
                "A longer label takes a larger share of its half before the row wraps");
            arrange(pair * 2 - 2);
            Check(table.ColumnCount == 4 && table.RowCount == 1 && row.All(button => button.Padding.Left == 5 && button.Padding.Right == 5 && button.Padding.Top == 3),
                "The buttons give up some padding before the row wraps");
            // Each pair saves ten pixels a button with the smaller padding.
            arrange((pair - 20) * 2 - 2);
            Check(table.ColumnCount == 2 && table.RowCount == 2 && cell(row[0]) == new Point(0, 0) && cell(row[2]) == new Point(1, 0) && cell(row[1]) == new Point(0, 1) && cell(row[3]) == new Point(1, 1)
                && row[1].Margin.Top > 0 && row[0].Margin.Top == 0 && row.All(button => button.Padding.Left == 10),
                "Buttons take two rows of two before a label is cut off, each pair in its own column");
            arrange(widest * 4);
            Check(table.ColumnCount == 4 && table.RowCount == 1 && Enumerable.Range(0, 4).All(i => cell(row[i]) == new Point(i, 0) && row[i].Margin.Top == 0 && row[i].Padding.Left == 10), "The buttons return to one row when the width allows");
            type.GetMethod("Show").Invoke(rows, new object[] { row[1], false }); arrange(widest * 4);
            Check(table.GetColumnSpan(row[0]) == 2 && table.GetColumnSpan(row[2]) == 1 && table.GetColumnSpan(row[3]) == 1, "A button whose partner is hidden takes both places");
            type.GetMethod("Show").Invoke(rows, new object[] { row[1], true }); arrange(widest * 4);
            Check(table.GetColumnSpan(row[0]) == 1, "Showing the partner again returns each button to its own place");
        }
    }
    static bool SamePixels(Bitmap first, Bitmap second)
    {
        if (first.Size != second.Size) return false;
        for (int y = 0; y < first.Height; y++)
            for (int x = 0; x < first.Width; x++)
                if (first.GetPixel(x, y) != second.GetPixel(x, y)) return false;
        return true;
    }
    static IntPtr GridImages(ListView grid) { return SendMessage(grid.Handle, 0x1002, IntPtr.Zero, IntPtr.Zero); }
    static Size GridImageSize(ListView grid)
    {
        int width, height;
        if (!ImageList_GetIconSize(GridImages(grid), out width, out height)) throw new Exception("No native icon list attached.");
        return new Size(width, height);
    }
    static Bitmap GridImage(ListView grid, int index)
    {
        IntPtr list = SendMessage(grid.Handle, 0x1002, IntPtr.Zero, IntPtr.Zero);
        int width, height;
        if (!ImageList_GetIconSize(list, out width, out height)) throw new Exception("No native icon list attached.");
        Bitmap output = new Bitmap(width, height);
        using (Graphics canvas = Graphics.FromImage(output)) {
            canvas.Clear(Color.Lime); IntPtr dc = canvas.GetHdc();
            try { if (!ImageList_Draw(list, index, dc, 0, 0, 1)) throw new Exception("Native icon drawing failed."); }
            finally { canvas.ReleaseHdc(dc); }
        }
        return output;
    }
    static void CheckLargeArtwork(LauncherForm form, string root, string preferencesPath, JavaScriptSerializer json)
    {
        BindingFlags instance = BindingFlags.Instance | BindingFlags.NonPublic;
        Func<string, object> field = name => typeof(LauncherForm).GetField(name, instance).GetValue(form);
        PackLibrary library = (PackLibrary)field("library");
        TrackBar slider = (TrackBar)field("iconSizeSlider");
        ListView launcher = (ListView)field("apps"), preview = (ListView)field("packPreview");
        List<Bitmap> cached = (List<Bitmap>)field("appArtwork");
        ComboBox themes = (ComboBox)field("themes");
        TabControl pages = (TabControl)field("pages");
        string file = Path.Combine(root, "high-detail.png");
        using (Bitmap bitmap = new Bitmap(1024, 1024)) {
            using (Graphics canvas = Graphics.FromImage(bitmap)) {
                canvas.Clear(Color.Transparent);
                for (int x = 32; x < 992; x++) canvas.FillRectangle(x % 2 == 0 ? Brushes.Red : Brushes.Blue, x, 32, 1, 960);
            }
            bitmap.Save(file, System.Drawing.Imaging.ImageFormat.Png);
        }
        ThemeEntry high = library.Save("High detail fixture", new Dictionary<string, string> { { "PhotoCraft", file } }, null);
        // The Launcher shows the applied pack, so apply the fixture before measuring both grids.
        MethodInfo rememberApplied = typeof(LauncherForm).GetMethod("RememberAppliedTheme", instance), renderAll = typeof(LauncherForm).GetMethod("RenderSelection", instance);
        rememberApplied.Invoke(form, new object[] { high });
        typeof(LauncherForm).GetMethod("ReloadLibrary", instance).Invoke(form, new object[] { high.Id });
        Check(slider.Maximum == 1024 && cached.All(image => image.Width == 128), "The size limit follows available PNG resolution while compact startup keeps small caches");
        slider.Value = 512;
        using (Bitmap app = GridImage(launcher, 0)) using (Bitmap pack = GridImage(preview, 0))
            Check(app.Size == new Size(512, 512) && pack.Size == app.Size, "Both native icon grids display actual 512-pixel images beyond the WinForms ImageList limit");
        pages.SelectedIndex = 0;
        Check(launcher.GetItemRect(0, ItemBoundsPortion.Icon).Width >= 512 && launcher.GetItemRect(0, ItemBoundsPortion.Label).Top >= launcher.GetItemRect(0, ItemBoundsPortion.Icon).Bottom,
            "Large native icons keep their complete hit area and app names underneath");
        slider.Value = 1024;
        using (Bitmap app = GridImage(launcher, 0)) using (Bitmap pack = GridImage(preview, 0)) {
            Check(app.Size == new Size(1024, 1024) && pack.Size == app.Size && cached[0].Width == 1024,
                "Zooming loads full-resolution artwork into both grids");
            Check(new[] { 258, 259, 610, 611 }.All(x => app.GetPixel(x, 200).ToArgb() == (x % 2 == 0 ? Color.Red : Color.Blue).ToArgb()
                && pack.GetPixel(x, 200).ToArgb() == app.GetPixel(x, 200).ToArgb()) && app.GetPixel(0, 0).ToArgb() == Color.Lime.ToArgb(),
                "Native 1024-pixel rendering preserves one-pixel source detail and transparency instead of enlarging a small thumbnail");
        }
        IntPtr before = SendMessage(launcher.Handle, 0x1002, IntPtr.Zero, IntPtr.Zero);
        typeof(Control).GetMethod("RecreateHandle", instance).Invoke(launcher, null);
        using (Bitmap app = GridImage(launcher, 0)) Check(SendMessage(launcher.Handle, 0x1002, IntPtr.Zero, IntPtr.Zero) == before && app.Width == 1024,
            "Recreating a native grid handle retains ownership and full-size artwork");
        Check(json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).IconSize == 1024, "Larger icon sizes persist without the former 128-pixel clamp");
        Bitmap[] sources = cached.ToArray(); slider.Value = 512; slider.Value = 520;
        Check(cached.SequenceEqual(sources), "Nearby zoom steps reuse the larger artwork cache");
        RequestIconMenu(launcher, launcher.Items[0]);
        ContextMenuStrip menu = (ContextMenuStrip)field("iconMenu");
        Check(menu.Visible && ((AppEntry)field("iconMenuTarget")).Application == "PhotoCraft", "Right-click targeting remains correct above 256 pixels");
        menu.Close();
        pages.SelectedIndex = 1;
        Panel scroll = (Panel)field("settingsScroll");
        TableLayoutPanel content = (TableLayoutPanel)field("settingsContent");
        form.PerformLayout(); content.PerformLayout();
        Check(SettingsLayoutProblem(content) == null && content.Width <= scroll.ClientSize.Width && preview.Height >= 520,
            "Larger previews grow within the scrolling Settings layout without overlapping controls");
        themes.SelectedIndex = 0;
        LoadingTests.Wait(form);
        Check(slider.Maximum == 1024 && slider.Value == 520 && GridImageSize(launcher) == new Size(520, 520),
            "Previewing smaller artwork keeps the range that the applied Launcher artwork needs");
        rememberApplied.Invoke(form, new object[] { themes.Items[0] }); renderAll.Invoke(form, null);
        Check(slider.Maximum == 128 && slider.Value == 128 && json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).IconSize == 128 && GridImageSize(launcher) == new Size(128, 128) && GridImageSize(preview) == new Size(128, 128),
            "Switching to smaller artwork adjusts the range and replaces oversized artwork in both native grids");
        rememberApplied.Invoke(form, new object[] { high });
        typeof(LauncherForm).GetMethod("ReloadLibrary", instance).Invoke(form, new object[] { high.Id }); slider.Value = 512;
    }
    static void CheckIconSizeEditing(LauncherForm form, string preferencesPath, JavaScriptSerializer json)
    {
        BindingFlags instance = BindingFlags.Instance | BindingFlags.NonPublic;
        Func<string, object> field = name => typeof(LauncherForm).GetField(name, instance).GetValue(form);
        TrackBar slider = (TrackBar)field("iconSizeSlider");
        TextBox editor = (TextBox)field("iconSizeValue");
        Button reset = (Button)field("resetIconSize");
        ListView launcher = (ListView)field("apps"), preview = (ListView)field("packPreview");
        ComboBox themes = (ComboBox)field("themes");
        TabControl pages = (TabControl)field("pages");
        Panel scroll = (Panel)field("settingsScroll");
        TableLayoutPanel content = (TableLayoutPanel)field("settingsContent");
        Preferences preferences = (Preferences)field("preferences");
        string previousTheme = ((ThemeEntry)themes.SelectedItem).Id, previousAppearance = preferences.AppearanceMode;
        Size previousWindowSize = form.Size; int previousIconSize = slider.Value, previousPage = pages.SelectedIndex;
        MethodInfo appearance = typeof(LauncherForm).GetMethod("ApplyAppearance", instance);
        Func<Keys, bool> command = key => {
            byte[] previous = new byte[256];
            if (!GetKeyboardState(previous)) throw new Exception("Cannot read the test thread's keyboard state.");
            byte[] plain = (byte[])previous.Clone();
            foreach (int modifier in new[] { 0x10, 0x11, 0x12, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5 }) plain[modifier] = 0;
            if (!SetKeyboardState(plain)) throw new Exception("Cannot initialize the test thread's modifiers.");
            try {
                Message message = Message.Create(editor.Handle, 0x0100, new IntPtr((int)key), IntPtr.Zero);
                return editor.PreProcessMessage(ref message);
            }
            finally { if (!SetKeyboardState(previous)) throw new Exception("Cannot restore the test thread's keyboard state."); }
        };
        Func<int, bool> synchronized = size => slider.Value == size && editor.Text == size.ToString()
            && GridImageSize(launcher) == new Size(size, size) && GridImageSize(preview) == new Size(size, size)
            && json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).IconSize == size;
        try {
            form.ShowManager(); pages.SelectedIndex = 1;
            IntPtr launcherImages = GridImages(launcher), previewImages = GridImages(preview);
            editor.Text = "83";
            Check(!editor.ReadOnly && editor.TabStop && slider.Value == previousIconSize
                && GridImages(launcher) == launcherImages && GridImages(preview) == previewImages
                && json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).IconSize == previousIconSize,
                "The size number is editable without resizing or saving incomplete typing");
            Check(command(Keys.Enter) && synchronized(83) && pages.SelectedIndex == 1 && form.Visible,
                "Enter commits an exact pixel size to the slider, both native grids, and saved preferences");
            editor.Text = "91";
            typeof(Control).GetMethod("OnLeave", instance).Invoke(editor, new object[] { EventArgs.Empty });
            Check(synchronized(91), "Leaving the size editor commits its exact value to both grids and preferences");
            launcherImages = GridImages(launcher); previewImages = GridImages(preview);
            editor.Text = " 91 "; command(Keys.Enter);
            Check(synchronized(91) && GridImages(launcher) == launcherImages && GridImages(preview) == previewImages,
                "Committing the unchanged size normalizes the number without rebuilding artwork");
            editor.Text = "121";
            Check(command(Keys.Escape) && synchronized(91) && form.Visible && pages.SelectedIndex == 1
                && GridImages(launcher) == launcherImages && GridImages(preview) == previewImages,
                "Escape cancels size editing without changing artwork, leaving Manage Icons, or closing the popup");
            bool invalidUnchanged = true;
            foreach (string invalid in new[] { "", "not a size", "999999999999999999999" }) {
                editor.Text = invalid;
                invalidUnchanged &= command(Keys.Enter) && synchronized(91)
                    && GridImages(launcher) == launcherImages && GridImages(preview) == previewImages;
            }
            Check(invalidUnchanged, "Empty, invalid, and overflowing size input revert safely without changing saved size or artwork");
            editor.Text = "0"; command(Keys.Enter);
            Check(synchronized(slider.Minimum), "Typed sizes below the available range clamp to the minimum");
            editor.Text = (slider.Maximum + 100).ToString(); command(Keys.Enter);
            Check(slider.Maximum == 1024 && synchronized(1024), "Typed sizes use the available artwork limit and remain supported above 128 pixels");
            slider.Value = 83;
            Check(synchronized(83), "Moving the slider synchronizes the editable size number");
            reset.PerformClick();
            Check(synchronized(Preferences.DefaultIconSize), "Reset synchronizes the editable number and both icon grids");
            pages.SelectedIndex = 0;
            SendMessage(launcher.Handle, 0x020A, new IntPtr((120 << 16) | 8), IntPtr.Zero);
            Check(synchronized(Preferences.DefaultIconSize + slider.SmallChange), "Ctrl+wheel synchronizes the editable size number with both grids");
            pages.SelectedIndex = 1;
            typeof(LauncherForm).GetMethod("SetBusy", instance).Invoke(form, new object[] { true, null });
            bool disabled = !editor.Enabled;
            typeof(LauncherForm).GetMethod("SetBusy", instance).Invoke(form, new object[] { false, null });
            Check(disabled && editor.Enabled, "The numeric editor follows the other size controls while an operation is busy");
            // Both grids must hold smaller artwork for the range to shrink, so apply the default too.
            string appliedTheme = preferences.AppliedTheme; Dictionary<string, string> appliedArtwork = preferences.AppliedArtwork;
            slider.Value = 512; preferences.AppliedTheme = ThemeEntry.DefaultThemeId; preferences.AppliedArtwork = null;
            themes.SelectedIndex = 0; LoadingTests.Wait(form);
            typeof(LauncherForm).GetMethod("RenderSelection", instance).Invoke(form, null);
            Check(slider.Maximum == 128 && synchronized(128), "Changing to smaller artwork updates the numeric editor and clamps the saved size");

            preferences.AppliedTheme = appliedTheme; preferences.AppliedArtwork = appliedArtwork;
            typeof(LauncherForm).GetMethod("ReloadLibrary", instance).Invoke(form, new object[] { previousTheme });
            slider.Value = 83;
            Label label = slider.Parent.Controls.OfType<Label>().Single(control => control.Text == "Launcher icon size");
            Check(slider.AccessibleName == "Launcher icon size", "The size slider is named for the Launcher icons it changes");
            Label unit = Descendants(slider.Parent).OfType<Label>().Single(control => control.Text == "px");
            Func<Control, double> center = control => control.PointToScreen(Point.Empty).Y + control.Height / 2.0;
            foreach (string mode in new[] { "Dark", "Light", "System" }) foreach (Size window in new[] { new Size(790, 570), new Size(900, 818), new Size(1100, 900) }) {
                preferences.AppearanceMode = mode; appearance.Invoke(form, null); form.Size = window;
                typeof(Form).GetMethod("OnResizeEnd", instance).Invoke(form, new object[] { EventArgs.Empty });
                scroll.AutoScrollPosition = Point.Empty; form.PerformLayout(); content.PerformLayout(); Application.DoEvents();
                NativeRect channel, thumb;
                SendMessageRect(slider.Handle, 0x041A, IntPtr.Zero, out channel);
                SendMessageRect(slider.Handle, 0x0419, IntPtr.Zero, out thumb);
                double origin = slider.PointToScreen(Point.Empty).Y;
                double channelCenter = origin + (channel.Top + channel.Bottom) / 2.0;
                double thumbCenter = origin + (thumb.Top + thumb.Bottom) / 2.0;
                Control[] peers = { label, editor, unit, reset };
                double channelOffset = peers.Max(control => Math.Abs(center(control) - channelCenter));
                double thumbOffset = peers.Max(control => Math.Abs(center(control) - thumbCenter));
                string layoutProblem = SettingsLayoutProblem(content);
                Check(channel.Right > channel.Left && thumb.Bottom > thumb.Top && channelOffset <= 1.5 && thumbOffset <= 2.5
                    && layoutProblem == null,
                    "The native slider channel and thumb align with the label, editable number, px unit, and Reset in " + mode + " at " + window.Width + "x" + window.Height
                    + " (channel " + channelOffset + " px, thumb " + thumbOffset + " px)" + (layoutProblem == null ? "" : ": " + layoutProblem));
            }
            // The slider is placed from its own native channel and thumb, whatever this PC's DPI. Larger text in the row
            // stands in for a larger scale: the slider follows it too.
            float dpi;
            using (Graphics g = form.CreateGraphics()) dpi = g.DpiY;
            Control[] rowPeers = { label, editor, unit, reset };
            Func<double[]> placement = () => {
                scroll.AutoScrollPosition = Point.Empty; form.PerformLayout(); content.PerformLayout(); Application.DoEvents();
                NativeRect channelNow, thumbNow;
                SendMessageRect(slider.Handle, 0x041A, IntPtr.Zero, out channelNow);
                SendMessageRect(slider.Handle, 0x0419, IntPtr.Zero, out thumbNow);
                double top = slider.PointToScreen(Point.Empty).Y;
                double channelMiddle = top + (channelNow.Top + channelNow.Bottom) / 2.0, thumbMiddle = top + (thumbNow.Top + thumbNow.Bottom) / 2.0;
                return new[] { Math.Abs((channelMiddle + thumbMiddle) / 2 - rowPeers.Average(center)), rowPeers.Max(control => Math.Abs(center(control) - channelMiddle)), rowPeers.Max(control => Math.Abs(center(control) - thumbMiddle)) };
            };
            double[] here = placement(), larger;
            Control sliderRow = slider.Parent;
            sliderRow.Font = new Font(sliderRow.Font.FontFamily, sliderRow.Font.Size * 1.2f);
            try { larger = placement(); }
            finally { sliderRow.ResetFont(); placement(); }
            Check(here[0] <= 1.0 && here[1] <= 1.5 && here[2] <= 2.5 && larger[0] <= 1.0 && larger[1] <= 1.5 && larger[2] <= 2.5,
                "The size slider stays on the middle of its row's text at this PC's DPI and when that text grows by a fifth (" + dpi + " DPI: middle " + here[0] + " px, channel " + here[1]
                + " px, thumb " + here[2] + " px; larger text: middle " + larger[0] + " px, channel " + larger[1] + " px, thumb " + larger[2] + " px)");
        }
        finally {
            preferences.AppearanceMode = previousAppearance; appearance.Invoke(form, null);
            typeof(LauncherForm).GetMethod("ReloadLibrary", instance).Invoke(form, new object[] { previousTheme });
            slider.Value = previousIconSize; form.Size = previousWindowSize; pages.SelectedIndex = previousPage;
            scroll.AutoScrollPosition = Point.Empty; form.PerformLayout();
        }
    }
    static void CheckLargeStartup(string root, string source, HotkeySettings unavailable)
    {
        using (EventWaitHandle show = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (EventWaitHandle stop = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (LauncherForm form = new LauncherForm(source, new FixtureConfig { ShortcutDirectory = new[] { root }, StateDirectory = Path.Combine(root, "state"), KeepOpenForAutomation = true }, true, show, stop))
        using (LauncherContext context = new LauncherContext(form))
        using (System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 50 }) {
            Exception failure = null; int ticks = 0;
            timer.Tick += delegate {
                try {
                    BindingFlags instance = BindingFlags.Instance | BindingFlags.NonPublic;
                    if (++ticks > 600) throw new Exception("Large-icon startup did not finish.");
                    if ((bool)typeof(LauncherForm).GetField("busy", instance).GetValue(form) || typeof(LauncherForm).GetField("catalog", instance).GetValue(form) == null) return;
                    timer.Stop();
                    TrackBar slider = (TrackBar)typeof(LauncherForm).GetField("iconSizeSlider", instance).GetValue(form);
                    ListView launcher = (ListView)typeof(LauncherForm).GetField("apps", instance).GetValue(form), preview = (ListView)typeof(LauncherForm).GetField("packPreview", instance).GetValue(form);
                    using (Bitmap app = GridImage(launcher, 0)) using (Bitmap pack = GridImage(preview, 0))
                        Check(!form.Visible && slider.Value == 512 && slider.Maximum == 1024 && app.Width == 512 && pack.Width == 512, "Hidden startup restores large saved icons in both native grids without a 256-pixel initialization error");
                    Check(!((IconGridView)launcher).ShowAppNames && !((IconGridView)preview).ShowAppNames && !((CheckBox)typeof(LauncherForm).GetField("showAppNames", instance).GetValue(form)).Checked && HiddenLabels(launcher) && HiddenLabels(preview), "A fresh message-loop startup restores icon-only mode in both large-image grids and Settings");
                    LinkLabel shortcutLink = (LinkLabel)typeof(LauncherForm).GetField("launcherShortcut", instance).GetValue(form);
                    Check(shortcutLink.Enabled && shortcutLink.Text.EndsWith(unavailable + " (unavailable)"),
                        "Startup identifies a saved shortcut held by another window and keeps the editor accessible");
                    stop.Set();
                }
                catch (Exception error) { failure = error; timer.Stop(); context.ExitThread(); }
            };
            timer.Start(); Application.Run(context); if (failure != null) throw failure;
        }
    }
    static bool HiddenLabels(ListView list) { return (SendMessage(list.Handle, 0x1037, IntPtr.Zero, IntPtr.Zero).ToInt64() & 0x00020000) != 0; }
    static void CheckAppNames(LauncherForm form, string preferencesPath, JavaScriptSerializer json)
    {
        BindingFlags instance = BindingFlags.Instance | BindingFlags.NonPublic;
        Func<string, object> field = name => typeof(LauncherForm).GetField(name, instance).GetValue(form);
        CheckBox names = (CheckBox)field("showAppNames");
        IconGridView launcher = (IconGridView)field("apps"), preview = (IconGridView)field("packPreview");
        TrackBar slider = (TrackBar)field("iconSizeSlider"); int previousSize = slider.Value;
        // Start with a fresh, unfiltered popup before choosing a name to type.
        form.Hide(); form.ShowManager();
        ThemeEntry previousTheme = (ThemeEntry)((ComboBox)field("themes")).SelectedItem;
        Check(json.Deserialize<Preferences>("{\"Theme\":\"Satin\"}").ShowAppNames && names.Checked && launcher.ShowAppNames && preview.ShowAppNames, "Existing preferences retain visible app names by default");
        slider.Value = 48;
        Size namedCell = launcher.GridCellSize;
        string[] titles = launcher.Items.Cast<ListViewItem>().Select(item => item.Text).ToArray();
        Check(titles.Length > 0, "The icon-only keyboard test starts with installed fixture apps");
        Bitmap[] artwork = ((List<Bitmap>)field("appArtwork")).ToArray();
        names.Checked = false;
        Check(!launcher.ShowAppNames && !preview.ShowAppNames && HiddenLabels(launcher) && HiddenLabels(preview), "Show app names switches native visual labels off in both grids");
        Check(launcher.GridCellSize.Width < namedCell.Width && launcher.GridCellSize.Height < namedCell.Height && launcher.GridCellSize == preview.GridCellSize, "Icon-only mode removes unused name space and packs both grids more tightly");
        Check(launcher.Items.Cast<ListViewItem>().Select(item => item.Text).SequenceEqual(titles) && launcher.Items.Cast<ListViewItem>().All(item => !String.IsNullOrWhiteSpace(item.ToolTipText)) && ((List<Bitmap>)field("appArtwork")).SequenceEqual(artwork), "Hiding labels retains accessible item names, hover tooltips and the existing artwork cache");
        Check(!json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).ShowAppNames, "The icon-only choice is saved for subsequent launches");
        string query = titles[0].Substring(0, Math.Min(2, titles[0].Length));
        PlainText(form, query);
        Check(launcher.Items.Count > 0 && launcher.Items.Cast<ListViewItem>().All(item => item.Text.StartsWith(query, StringComparison.OrdinalIgnoreCase)), "Typing still filters real app names when their visual labels are hidden");
        typeof(LauncherForm).GetMethod("OnKeyDown", instance).Invoke(form, new object[] { new KeyEventArgs(Keys.Escape) });
        ListViewItem first = launcher.Items[0];
        RequestIconMenu(launcher, first);
        Check(((ContextMenuStrip)field("iconMenu")).Visible && ((AppEntry)field("iconMenuTarget")).Shortcut == ((AppEntry)first.Tag).Shortcut, "An icon-only tile retains the correct per-app context-menu target");
        ((ContextMenuStrip)field("iconMenu")).Close();
        foreach (IconGridView grid in new[] { launcher, preview }) typeof(Control).GetMethod("RecreateHandle", instance).Invoke(grid, null);
        Check(HiddenLabels(launcher) && HiddenLabels(preview), "Native handle recreation preserves hidden labels and native image-list ownership");
        names.Checked = true;
        Check(!HiddenLabels(launcher) && !HiddenLabels(preview) && launcher.GridCellSize == namedCell && json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).ShowAppNames, "Re-enabling names restores native labels, spacing and the saved preference");
        names.Checked = false;
        ComboBox themes = (ComboBox)field("themes");
        themes.SelectedItem = themes.Items.Cast<ThemeEntry>().First(theme => theme.Id != previousTheme.Id && !theme.IsDefault);
        LoadingTests.Wait(form);
        Check(HiddenLabels(launcher) && HiddenLabels(preview) && !json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).ShowAppNames, "Background pack switching preserves icon-only mode");
        typeof(LauncherForm).GetMethod("ReloadLibrary", instance).Invoke(form, new object[] { previousTheme.Id });
        slider.Value = previousSize;
        // Leave the fixture saved without names so CheckLargeStartup verifies a real restart.
    }
    static void CheckExistingLauncherDefault(LauncherForm form, string root, JavaScriptSerializer json)
    {
        BindingFlags instance = BindingFlags.Instance | BindingFlags.NonPublic;
        Func<string, object> field = name => typeof(LauncherForm).GetField(name, instance).GetValue(form);
        Action<string, object[]> call = (name, arguments) => typeof(LauncherForm).GetMethod(name, instance).Invoke(form, arguments);
        Catalog catalog = (Catalog)field("catalog"); AppEntry[] previousApps = catalog.Apps;
        Preferences preferences = (Preferences)field("preferences"); string[] defaults = preferences.DefaultShortcuts;
        string applied = preferences.AppliedTheme; Dictionary<string, string> appliedArtwork = preferences.AppliedArtwork;
        string theme = ((ThemeEntry)((ComboBox)field("themes")).SelectedItem).Id;
        TrackBar slider = (TrackBar)field("iconSizeSlider"); int previousSize = slider.Value;
        string shortcut = Path.Combine(root, "PhotoCraft.lnk"); byte[] bytes = File.ReadAllBytes(shortcut);
        List<Bitmap> artwork = (List<Bitmap>)field("appArtwork"), previewArtwork = (List<Bitmap>)field("packArtwork");
        TabControl pages = (TabControl)field("pages");
        try {
            catalog.Apps = new[] { new AppEntry { Application = "ArtCraftLauncher", Name = "ArtCraft Launcher", Shortcut = shortcut, Scope = "CurrentUser", IconPath = "", OriginalIconPath = Path.Combine(root, "original-red.png"), UsingDefaultIcon = true } };
            preferences.DefaultShortcuts = new string[0]; preferences.AppliedTheme = null; preferences.AppliedArtwork = null; call("RenderSelection", null);
            Check(artwork[0].GetPixel(64, 64).ToArgb() == Color.Red.ToArgb(), "A launcher without an explicit icon path displays its own original instead of BetterIcon's fallback");
            PackLibrary library = (PackLibrary)field("library");
            ThemeEntry custom = library.Save("Launcher preview fixture", new Dictionary<string, string> { { "ArtCraftLauncher", Path.Combine(root, "current-blue.png") } }, null);
            call("ReloadLibrary", new object[] { custom.Id });
            Check(artwork[0].GetPixel(64, 64).ToArgb() == Color.Red.ToArgb() && previewArtwork[0].GetPixel(64, 64).ToArgb() == Color.Blue.ToArgb(),
                "A custom launcher pack previews its artwork in Manage Icons and leaves the Launcher alone");
            call("RememberAppliedTheme", new object[] { custom }); call("RenderSelection", null);
            Check(artwork[0].GetPixel(64, 64).ToArgb() == Color.Blue.ToArgb(), "An applied launcher pack shows its artwork in the Launcher");
            pages.SelectedIndex = 0;
            ListView grid = (ListView)field("apps"); RequestIconMenu(grid, grid.Items[0]);
            ToolStripMenuItem restore = (ToolStripMenuItem)field("restoreIconDefault");
            Check(restore.Enabled && ((AppEntry)field("iconMenuTarget")).Scope == "CurrentUser", "The launcher default action is available without a backup and targets its own locations");
            ShortcutScopeTests.SelectScope(() => restore.PerformClick(), "CurrentUser"); ((ContextMenuStrip)field("iconMenu")).Close();
            DateTime restoreDeadline = DateTime.UtcNow.AddSeconds(30);
            while ((bool)field("busy") && DateTime.UtcNow < restoreDeadline) { Application.DoEvents(); System.Threading.Thread.Sleep(10); }
            Check(artwork[0].GetPixel(64, 64).ToArgb() == Color.Red.ToArgb() && preferences.DefaultShortcuts.Contains(shortcut) && File.ReadAllBytes(shortcut).SequenceEqual(bytes) && ((Label)field("status")).Text.Contains("already at the default"), "Restoring an already-default launcher resets its preview and reports success without rewriting the shortcut");
            pages.SelectedIndex = 1;
            ListView preview = (ListView)field("packPreview"); RequestIconMenu(preview, preview.Items[0]);
            Check(restore.Enabled, "The Settings context menu also allows selecting a launcher's existing default without a backup");
        }
        finally {
            ((ContextMenuStrip)field("iconMenu")).Close(); catalog.Apps = previousApps; preferences.DefaultShortcuts = defaults;
            preferences.AppliedTheme = applied; preferences.AppliedArtwork = appliedArtwork;
            call("ReloadLibrary", new object[] { theme }); slider.Value = Math.Min(previousSize, slider.Maximum);
        }
    }
    static void RequestIconMenu(ListView grid, ListViewItem item)
    {
        item.EnsureVisible();
        Rectangle icon = item.GetBounds(ItemBoundsPortion.Icon);
        Point screen = grid.PointToScreen(new Point(icon.Left + icon.Width / 2, icon.Top + icon.Height / 2));
        SendMessage(grid.Handle, 0x007B, grid.Handle, new IntPtr(unchecked((screen.Y << 16) | (screen.X & 0xffff))));
    }
    static void CheckIconContextMenus(LauncherForm form)
    {
        BindingFlags instance = BindingFlags.Instance | BindingFlags.NonPublic;
        Func<string, object> field = name => typeof(LauncherForm).GetField(name, instance).GetValue(form);
        ListView launcher = (ListView)field("apps"), preview = (ListView)field("packPreview");
        ComboBox themes = (ComboBox)field("themes");
        ContextMenuStrip menu = (ContextMenuStrip)field("iconMenu");
        ToolStripMenuItem restore = (ToolStripMenuItem)field("restoreIconDefault");
        ToolStripMenuItem choose = (ToolStripMenuItem)field("chooseAppIcon");
        TabControl pages = (TabControl)field("pages");
        pages.SelectedIndex = 0;
        launcher.Items[0].Selected = true;
        RequestIconMenu(launcher, launcher.Items[3]);
        AppEntry target = (AppEntry)field("iconMenuTarget");
        Check(menu.Visible && restore.Enabled && target.Application == "FigCraft" && target.Scope == "AllUsers" && launcher.Items[3].Selected,
            "Right-click selects the clicked launcher app before asking where to restore it");
        string filter = (string)field("filterText");
        typeof(LauncherForm).GetMethod("OnKeyPress", instance).Invoke(form, new object[] { new KeyPressEventArgs('p') });
        KeyEventArgs escape = new KeyEventArgs(Keys.Escape);
        typeof(LauncherForm).GetMethod("OnKeyDown", instance).Invoke(form, new object[] { escape });
        Check((string)field("filterText") == filter && !escape.Handled && pages.SelectedIndex == 0 && form.Visible,
            "An open icon menu owns keyboard input without filtering or closing the launcher");
        menu.Close();
        Point blank = launcher.PointToScreen(new Point(launcher.ClientSize.Width - 5, launcher.ClientSize.Height - 5));
        SendMessage(launcher.Handle, 0x007B, launcher.Handle, new IntPtr(unchecked((blank.Y << 16) | (blank.X & 0xffff))));
        Check(!menu.Visible && !choose.Enabled && field("iconMenuTarget") == null, "Right-clicking empty launcher space cannot edit or restore a stale selected app");
        RequestIconMenu(launcher, launcher.Items[2]);
        Check(menu.Visible && choose.Enabled && !restore.Enabled && ((AppEntry)field("iconMenuTarget")).Application == "FilmCraft",
            "An app without a restore backup still offers Choose icon in its context menu");
        menu.Close();
        RequestIconMenu(launcher, launcher.Items[0]);
        menu.Close();
        SendMessage(launcher.Handle, 0x007B, launcher.Handle, new IntPtr(-1));
        Check(menu.Visible && restore.Enabled && ((AppEntry)field("iconMenuTarget")).Application == "PhotoCraft",
            "The keyboard context-menu request targets the selected app");
        typeof(LauncherForm).GetMethod("SetBusy", instance).Invoke(form, new object[] { true, null });
        Check(!menu.Visible && !choose.Enabled && !restore.Enabled && field("iconMenuTarget") == null, "Starting an operation closes the icon menu and clears both icon actions");
        RequestIconMenu(launcher, launcher.Items[0]);
        Check(!menu.Visible && field("iconMenuTarget") == null, "Busy operations cannot open a new icon restoration menu");
        typeof(LauncherForm).GetMethod("SetBusy", instance).Invoke(form, new object[] { false, null });
        pages.SelectedIndex = 1;
        RequestIconMenu(preview, preview.Items.Cast<ListViewItem>().First(item => item.Text == "FigCraft"));
        Check(menu.Visible && restore.Enabled && ((AppEntry)field("iconMenuTarget")).Application == "FigCraft",
            "Settings previews find shared restore backups before the operation's location choice");
        escape = new KeyEventArgs(Keys.Escape);
        typeof(LauncherForm).GetMethod("OnKeyDown", instance).Invoke(form, new object[] { escape });
        Check(!escape.Handled && pages.SelectedIndex == 1, "Escape in the icon menu stays in Settings");
        menu.Close();
        RequestIconMenu(preview, preview.Items.Cast<ListViewItem>().First(item => item.Text == "PhotoCraft"));
        Check(menu.Visible && restore.Enabled && ((AppEntry)field("iconMenuTarget")).Application == "PhotoCraft",
            "Settings previews find current-user restore backups without a persistent location selector");
        menu.Close(); themes.SelectedIndex = 0; LoadingTests.Wait(form);
        RequestIconMenu(preview, preview.Items.Cast<ListViewItem>().First(item => item.Text == "PhotoCraft"));
        Check(menu.Visible && restore.Enabled && ((AppEntry)field("iconMenuTarget")).Application == "PhotoCraft",
            "ArtCraft default previews retain the same per-app context action");
        menu.Close();
    }
    static void CheckDefaultAndIndividualRestore(LauncherForm form, string root, string preferencesPath, JavaScriptSerializer json)
    {
        // This runs after the existing launcher checks. Only the isolated catalog,
        // library and preferences change; no restore/apply dialog is accepted.
        BindingFlags instance = BindingFlags.Instance | BindingFlags.NonPublic;
        Func<string, object> field = name => typeof(LauncherForm).GetField(name, instance).GetValue(form);
        Action<string, object[]> call = (name, arguments) => typeof(LauncherForm).GetMethod(name, instance).Invoke(form, arguments);
        ComboBox themes = (ComboBox)field("themes");
        Button apply = (Button)field("apply");
        TabControl pages = (TabControl)field("pages");
        Catalog catalog = (Catalog)field("catalog");
        Preferences preferences = (Preferences)field("preferences");
        List<Bitmap> appArtwork = (List<Bitmap>)field("appArtwork"), packArtwork = (List<Bitmap>)field("packArtwork");
        ListView packPreview = (ListView)field("packPreview");
        ContextMenuStrip menu = (ContextMenuStrip)field("managePackMenu");
        PackLibrary library = (PackLibrary)field("library");
        ThemeEntry[] bundled = (ThemeEntry[])field("bundledThemes");
        ThemeEntry themed = themes.Items.Cast<ThemeEntry>().First(t => t.Id == "Craft-Icons-Zach/HyGel");
        string original = Path.Combine(root, "original-red.png"), current = Path.Combine(root, "current-blue.png");
        using (Bitmap image = new Bitmap(32, 32)) {
            using (Graphics canvas = Graphics.FromImage(image)) canvas.Clear(Color.Red);
            image.Save(original, System.Drawing.Imaging.ImageFormat.Png);
            using (Graphics canvas = Graphics.FromImage(image)) canvas.Clear(Color.Blue);
            image.Save(current, System.Drawing.Imaging.ImageFormat.Png);
        }
        string photo = Path.Combine(root, "Photo primary.lnk"), variant = Path.Combine(root, "Photo alternate.lnk");
        string film = Path.Combine(root, "Film user.lnk"), fig = Path.Combine(root, "Fig shared.lnk");
        catalog.Apps = new[] {
            new AppEntry { Application = "PhotoCraft", Name = "My photo workspace", Shortcut = photo, Scope = "CurrentUser", IconPath = current, OriginalIconPath = original, RestoreAvailable = true },
            new AppEntry { Application = "PhotoCraft", Name = "Photo alternate workspace", Shortcut = variant, Scope = "CurrentUser", IconPath = current, OriginalIconPath = original, RestoreAvailable = true },
            new AppEntry { Application = "FilmCraft", Name = "Custom film workspace", Shortcut = film, Scope = "CurrentUser", IconPath = current, OriginalIconPath = original, RestoreAvailable = false },
            new AppEntry { Application = "FigCraft", Name = "Shared drawing workspace", Shortcut = fig, Scope = "AllUsers", IconPath = current, OriginalIconPath = original, RestoreAvailable = true }
        };
        pages.SelectedIndex = 1;
        // The Launcher follows the pack that was applied, here HyGel, not the one being browsed.
        Action<string> markApplied = id => { preferences.AppliedTheme = id; preferences.AppliedArtwork = null; };
        markApplied(themed.Id);
        call("ReloadLibrary", new object[] { ThemeEntry.DefaultThemeId });
        Check(((ThemeEntry)themes.Items[0]).IsDefault && ((ThemeEntry)themes.Items[0]).Id == ThemeEntry.DefaultThemeId && themes.SelectedIndex == 0,
            "ArtCraft default is the first selectable pack and uses a stable identity");
        Check(json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).Theme == ThemeEntry.DefaultThemeId,
            "The ArtCraft default choice persists in preferences");
        call("ReloadLibrary", new object[] { null });
        Check(themes.SelectedIndex == 0 && ((ThemeEntry)themes.SelectedItem).IsDefault,
            "Refreshing the pack library preserves the default selection");
        Check(new[] { "Customize...", "Edit pack...", "Export ZIP..." }.All(name => !menu.Items.Cast<ToolStripItem>().First(item => item.Text == name).Enabled)
            && !((Button)field("removePackButton")).Enabled
            && menu.Items.Cast<ToolStripItem>().First(item => item.Text == "Restore built-in packs").Enabled,
            "The virtual default cannot be customized, edited, exported or removed");
        Check(apply.Enabled && apply.Text == "Restore ArtCraft defaults...", "Choosing the default presents the restore-all action");
        Check(appArtwork.Count == 4 && !appArtwork.Any(image => image.GetPixel(64, 64).ToArgb() == Color.Red.ToArgb()),
            "Choosing ArtCraft default leaves the Launcher on the applied pack");
        markApplied(ThemeEntry.DefaultThemeId); call("RenderSelection", null);
        Check(appArtwork.Count == 4 && appArtwork.All(image => image.GetPixel(64, 64).ToArgb() == Color.Red.ToArgb()),
            "Default launcher thumbnails use original artwork instead of current shortcut or pack artwork");
        Check(packPreview.Items.Count == 3 && packPreview.Items.Cast<ListViewItem>().Select(item => item.Text).SequenceEqual(new[] { "FigCraft", "FilmCraft", "PhotoCraft" })
            && packArtwork.All(image => image.GetPixel(64, 64).ToArgb() == Color.Red.ToArgb()),
            "Default preview shows original artwork once per canonical installed app");
        foreach (ThemeEntry pack in bundled) library.Remove(pack);
        call("ReloadLibrary", new object[] { null });
        Check(themes.Items.Count > 0 && ((ThemeEntry)themes.Items[0]).IsDefault && themes.Items.Cast<ThemeEntry>().Count(t => t.IsDefault) == 1
            && !themes.Items.Cast<ThemeEntry>().Any(t => !t.Managed && !t.IsDefault),
            "ArtCraft default stays first and available when all bundled packs are hidden");
        library.RestoreBundled();
        call("ReloadLibrary", new object[] { "Craft-Icons-Zach/Cardboard" });
        {
            // Lists show each author's packs together, by name. ArtCraft Launcher leads every grid of app icons.
            string[] listOrder = themes.Items.Cast<ThemeEntry>().Select(t => t.Id).ToArray();
            Func<string, int> placeOf = id => Array.IndexOf(listOrder, id);
            Func<string, bool> groupedBy = prefix => {
                int[] places = Enumerable.Range(0, listOrder.Length).Where(i => listOrder[i].StartsWith(prefix)).ToArray();
                return places.Length > 0 && places.Last() - places[0] == places.Length - 1;
            };
            const string mikeDark = "Craft-Icons-Mike22/CraftApps AIO November - Dark";
            Check(listOrder[0] == ThemeEntry.DefaultThemeId && groupedBy("Craft-Icons-Zach/") && groupedBy("Craft-Icons-Mike22/")
                && placeOf("Craft-Icons-Mains/Stained Glass") < placeOf(mikeDark) && placeOf(mikeDark) < placeOf("Craft-Icons-Zach/Cardboard")
                && placeOf("Craft-Icons-Zach/Cardboard") < placeOf("Craft-Icons-Zach/Ink"), "Packs are listed by author, then by name");
            Check(((ThemeEntry)themes.SelectedItem).Id == "Craft-Icons-Zach/Cardboard" && packPreview.Items.Count == 20
                && packPreview.Items.Cast<ListViewItem>().Take(3).Select(item => item.Text).SequenceEqual(new[] { "ArtCraftLauncher", "AniCraft", "CADCraft" }),
                "ArtCraft Launcher leads a pack's icons when the pack draws it");
            Catalog leadCatalog = new Catalog { Apps = new[] { "AniCraft", "PhotoCraft", "ArtCraftLauncher", "FilmCraft" }.Select(name => new AppEntry { Application = name, Name = name }).ToArray() };
            Check(leadCatalog.Apps.Select(app => app.Application).SequenceEqual(new[] { "ArtCraftLauncher", "AniCraft", "PhotoCraft", "FilmCraft" }),
                "ArtCraft Launcher leads the app grid and the other apps keep their order");
        }
        call("ReloadLibrary", new object[] { themed.Id });
        Check(appArtwork.All(image => image.GetPixel(64, 64).ToArgb() == Color.Red.ToArgb()) && packPreview.Items.Count == themed.Icons.Length,
            "Selecting an icon pack shows its full preview and leaves the Launcher unchanged");
        call("RememberAppliedTheme", new object[] { themed }); call("RenderSelection", null);
        Check(!appArtwork.Any(image => image.GetPixel(64, 64).ToArgb() == Color.Red.ToArgb()) && preferences.AppliedTheme == themed.Id && preferences.AppliedArtwork.Count == themed.Icons.Length,
            "Applying an icon pack gives the Launcher its themed thumbnails");

        // Exercise the real native extractor with different resource indices,
        // independently of whatever artwork is currently selected in the app.
        MethodInfo thumbnail = typeof(LauncherForm).GetMethod("Thumbnail", BindingFlags.Static | BindingFlags.NonPublic);
        string shellLibrary = Path.Combine(Environment.SystemDirectory, "shell32.dll");
        string explorer = Path.Combine(Environment.GetEnvironmentVariable("WINDIR"), "explorer.exe");
        string compressedIcon = Path.Combine(root, "original-compressed.ico");
        using (Bitmap image = new Bitmap(128, 128))
        using (MemoryStream png = new MemoryStream()) {
            using (Graphics canvas = Graphics.FromImage(image)) canvas.Clear(Color.Red);
            image.Save(png, System.Drawing.Imaging.ImageFormat.Png);
            byte[] payload = png.ToArray();
            using (BinaryWriter writer = new BinaryWriter(File.Create(compressedIcon))) {
                writer.Write((ushort)0); writer.Write((ushort)1); writer.Write((ushort)1);
                writer.Write((byte)128); writer.Write((byte)128); writer.Write((byte)0); writer.Write((byte)0);
                writer.Write((ushort)1); writer.Write((ushort)32); writer.Write((uint)payload.Length); writer.Write((uint)22);
                writer.Write(payload);
            }
        }
        using (Bitmap fallback = (Bitmap)thumbnail.Invoke(null, new object[] { "", SystemIcons.Error, 128, 0 }))
        using (Bitmap first = (Bitmap)thumbnail.Invoke(null, new object[] { shellLibrary, SystemIcons.Error, 128, 0 }))
        using (Bitmap second = (Bitmap)thumbnail.Invoke(null, new object[] { shellLibrary, SystemIcons.Error, 128, 1 }))
        using (Bitmap executable = (Bitmap)thumbnail.Invoke(null, new object[] { explorer, SystemIcons.Error, 128, 0 }))
        using (Bitmap compressed = (Bitmap)thumbnail.Invoke(null, new object[] { compressedIcon, SystemIcons.Error, 128, 0 })) {
            Check(!SamePixels(first, fallback) && !SamePixels(second, fallback) && !SamePixels(first, second),
                "Native DLL thumbnails extract distinct indexed resources instead of the fallback");
            Check(!SamePixels(executable, fallback), "Native EXE thumbnails extract application artwork instead of the fallback");
            Check(new[] { 16, 32, 64, 96, 112 }.All(x => new[] { 16, 32, 64, 96, 112 }.All(y => compressed.GetPixel(x, y).ToArgb() == Color.Red.ToArgb())),
                "PNG-compressed ICO thumbnails retain their artwork instead of gray noise or a fallback");
            catalog.Apps[3].OriginalIconPath = shellLibrary; catalog.Apps[3].OriginalIconIndex = 1;
            markApplied(ThemeEntry.DefaultThemeId);
            call("ReloadLibrary", new object[] { ThemeEntry.DefaultThemeId });
            Check(SamePixels(appArtwork[3], second) && SamePixels(packArtwork[0], second),
                "Default launcher and preview both honor the original native icon resource index");
            catalog.Apps[3].OriginalIconPath = original; catalog.Apps[3].OriginalIconIndex = 0;
            markApplied(themed.Id);
            call("ReloadLibrary", new object[] { themed.Id });
            ThemeIcon themedPhoto = ((ThemeEntry)themes.SelectedItem).Icons.First(icon => icon.Application == "PhotoCraft");
            string previousArtwork = themedPhoto.Path, previousPreview = themedPhoto.PreviewPath, previousCurrentIcon = catalog.Apps[0].IconPath;
            int previousIndex = catalog.Apps[0].IconIndex;
            try {
                themedPhoto.Path = compressedIcon; themedPhoto.PreviewPath = null;
                catalog.Apps[0].IconPath = shellLibrary; catalog.Apps[0].IconIndex = 2;
                call("RenderApps", null); call("RenderPack", null);
                int photoPreview = packPreview.Items.Cast<ListViewItem>().ToList().FindIndex(item => item.Text == "PhotoCraft");
                Check(SamePixels(appArtwork[0], compressed) && SamePixels(packArtwork[photoPreview], compressed),
                    "Pack ICO artwork ignores the current shortcut's native resource index in both grids");
            }
            finally {
                themedPhoto.Path = previousArtwork; themedPhoto.PreviewPath = previousPreview;
                catalog.Apps[0].IconPath = previousCurrentIcon; catalog.Apps[0].IconIndex = previousIndex;
                call("RenderApps", null); call("RenderPack", null);
            }
        }

        Check(json.Deserialize<Preferences>("{\"Theme\":\"Craft-Icons-Zach/Satin\"}").DefaultShortcuts.Length == 0,
            "Older preferences migrate without inventing per-shortcut default overrides");
        call("RememberRestoredShortcuts", new object[] { new[] {
            new ResultItem { Shortcut = photo, Status = "Restored" },
            new ResultItem { Shortcut = photo.ToUpperInvariant(), Status = "Restored" },
            new ResultItem { Shortcut = variant, Status = "Conflict" },
            new ResultItem { Shortcut = film, Status = "Skipped" },
            new ResultItem { Shortcut = fig, Status = "Restored" }
        }, true });
        Preferences restored = json.Deserialize<Preferences>(File.ReadAllText(preferencesPath));
        Check(restored.DefaultShortcuts.Length == 2 && restored.DefaultShortcuts.Contains(photo, StringComparer.OrdinalIgnoreCase)
            && restored.DefaultShortcuts.Contains(fig, StringComparer.OrdinalIgnoreCase) && restored.Theme == themed.Id,
            "Only successful restorations persist unique per-shortcut defaults without replacing the selected pack");
        call("RenderApps", null);
        Check(appArtwork[0].GetPixel(64, 64).ToArgb() == Color.Red.ToArgb() && appArtwork[3].GetPixel(64, 64).ToArgb() == Color.Red.ToArgb()
            && appArtwork[1].GetPixel(64, 64).ToArgb() != Color.Red.ToArgb() && SamePixels(appArtwork[1], packArtwork[themed.Icons.OrderBy(icon => icon.Application).ToList().FindIndex(icon => icon.Application == "PhotoCraft")]),
            "Restored shortcuts show their originals while other shortcuts and pack previews keep the selected theme");
        call("RememberRestoredShortcuts", new object[] { new[] {
            new ResultItem { Shortcut = photo.ToUpperInvariant(), Status = "Applied" },
            new ResultItem { Shortcut = fig, Status = "Conflict" }
        }, false });
        Check(preferences.DefaultShortcuts.SequenceEqual(new[] { fig }) && json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).DefaultShortcuts.SequenceEqual(new[] { fig }),
            "Applying a pack clears only successful shortcut overrides and preserves failed ones");
        call("RememberRestoredShortcuts", new object[] { new[] { new ResultItem { Shortcut = fig, Status = "Unchanged" } }, false });
        Check(preferences.DefaultShortcuts.Length == 0 && json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).DefaultShortcuts.Length == 0,
            "An unchanged successful pack application also clears its default override");
        call("RenderApps", null);
        Check(!appArtwork.Any(image => image.GetPixel(64, 64).ToArgb() == Color.Red.ToArgb()),
            "Themed launcher artwork returns after successful applications clear the overrides");
        CheckIconContextMenus(form);
    }
    static void CheckContextRestore(string root, string source, JavaScriptSerializer json)
    {
        string links = Path.Combine(root, "context-links"), state = Path.Combine(root, "context-state");
        Directory.CreateDirectory(links); Directory.CreateDirectory(state);
        string photo = Path.Combine(links, "PhotoCraft.lnk"), film = Path.Combine(links, "FilmCraft.lnk");
        File.Copy(Path.Combine(root, "PhotoCraft.lnk"), photo); File.Copy(photo, film);
        byte[] originalPhoto = File.ReadAllBytes(photo), originalFilm = File.ReadAllBytes(film);
        FixtureConfig fixture = new FixtureConfig { ShortcutDirectory = new[] { links }, StateDirectory = state, KeepOpenForAutomation = true };
        WorkerClient worker = new WorkerClient(source, fixture);
        WorkerReply plan = worker.Run(new WorkerRequest { Action = "Preview", Scope = "CurrentUser", Theme = "Craft-Icons-Zach/HyGel" }, false).GetAwaiter().GetResult();
        WorkerReply applied = worker.Run(new WorkerRequest { Action = "Apply", Scope = "CurrentUser", Theme = "Craft-Icons-Zach/HyGel", ExpectedPlan = plan.Plan }, false).GetAwaiter().GetResult();
        Check(applied.Results.Length == 2 && applied.Results.All(result => result.Status == "Applied"), "Context-menu integration prepares two isolated themed shortcuts");
        byte[] themedFilm = File.ReadAllBytes(film);
        string preferencesPath = Path.Combine(state, "tray-preferences.json");
        File.WriteAllText(preferencesPath, json.Serialize(new Preferences { Theme = "Craft-Icons-Zach/HyGel", Scope = "AllUsers", Hotkey = new HotkeySettings { Enabled = false } }));
        using (EventWaitHandle show = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (EventWaitHandle stop = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (LauncherForm form = new LauncherForm(source, fixture, true, show, stop))
        using (LauncherContext context = new LauncherContext(form))
        using (System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 50 }) {
            BindingFlags instance = BindingFlags.Instance | BindingFlags.NonPublic;
            Func<string, object> field = name => typeof(LauncherForm).GetField(name, instance).GetValue(form);
            Exception failure = null; int ticks = 0, phase = 0;
            timer.Tick += delegate {
                try {
                    if (++ticks > 600) throw new Exception("Context restore did not finish within 30 seconds.");
                    if (phase == 0 && !(bool)field("busy") && field("catalog") != null) {
                        phase = 1; form.ShowManager();
                        ListView launcher = (ListView)field("apps");
                        RequestIconMenu(launcher, launcher.Items.Cast<ListViewItem>().First(item => ((AppEntry)item.Tag).Application == "PhotoCraft"));
                        ((ToolStripMenuItem)field("restoreIconDefault")).PerformClick();
                    }
                    else if (phase == 1) {
                        ShortcutScopeDialog scope = Application.OpenForms.OfType<ShortcutScopeDialog>().FirstOrDefault();
                        if (scope != null) {
                            Check(scope.Text == "Restore icon locations", "Right-click restoration asks for current user or all users before reviewing the clicked app");
                            scope.Controls.Find("CurrentUserChoice", true).OfType<Button>().Single().PerformClick();
                            return;
                        }
                        Form review = Application.OpenForms.Cast<Form>().FirstOrDefault(dialog => dialog.Text == "Review restoration");
                        if (review == null) return;
                        ListView rows = review.Controls[0].Controls.OfType<ListView>().Single();
                        Check(rows.Items.Count == 1 && rows.Items[0].SubItems[1].Text == photo,
                            "Clicking Restore ArtCraft default reviews only the clicked app in its scope despite different Settings locations");
                        phase = 2; review.DialogResult = DialogResult.OK;
                    }
                    else if (phase == 2) {
                        Form results = Application.OpenForms.Cast<Form>().FirstOrDefault(dialog => dialog.Text == "Operation results");
                        if (results == null) return;
                        ListView rows = results.Controls[0].Controls.OfType<ListView>().Single();
                        Check(rows.Items.Count == 1 && rows.Items[0].Text == "Restored", "The icon context action completes its reviewed restore successfully");
                        phase = 3; results.DialogResult = DialogResult.OK;
                    }
                    else if (phase == 3 && !(bool)field("busy")) {
                        Catalog updated = (Catalog)field("catalog");
                        Preferences preferences = json.Deserialize<Preferences>(File.ReadAllText(preferencesPath));
                        Check(File.ReadAllBytes(photo).SequenceEqual(originalPhoto) && File.ReadAllBytes(film).SequenceEqual(themedFilm) && !themedFilm.SequenceEqual(originalFilm),
                            "Right-click restore returns only the selected app to its exact original bytes");
                        Check(!updated.Apps.Single(app => app.Application == "PhotoCraft").RestoreAvailable && updated.Apps.Single(app => app.Application == "FilmCraft").RestoreAvailable
                            && preferences.DefaultShortcuts.SequenceEqual(new[] { photo }) && preferences.Scope == "AllUsers",
                            "The completed context restore remembers the chosen app's default while preserving legacy preferences and other backups");
                        timer.Stop(); stop.Set();
                    }
                }
                catch (Exception error) { failure = error; timer.Stop(); context.ExitThread(); }
            };
            timer.Start(); Application.Run(context);
            if (failure != null) throw failure;
        }
    }
    [STAThread]
    static int Main(string[] args)
    {
        string failure = null, root = args[0];
        Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.ThrowException);
        // The WebP checks run their packs in a process of their own (WebPTests.RunPacks): a process loads WebP support once.
        if (args.Length > 2 && args[2] == "--webp-packs") return WebPTests.RunPacksChild(args[0], args[1]);
        try {
            Rectangle work = new Rectangle(0, 0, 1920, 1040);
            Rectangle bottom = PopupPlacement.AboveTray(new Size(900, 690), new Point(1850, 1060), work);
            Check(work.Contains(bottom) && bottom.Bottom <= 1040 && bottom.Right <= 1920, "Bottom taskbar placement remains above the taskbar");
            work = new Rectangle(-1920, -200, 1920, 1040);
            Rectangle left = PopupPlacement.AboveTray(new Size(900, 690), new Point(-1900, 800), work);
            Check(work.Contains(left), "Negative monitor coordinates stay on the selected screen");
            work = new Rectangle(64, 0, 1280, 800);
            Check(work.Contains(PopupPlacement.AboveTray(new Size(900, 690), new Point(20, 760), work)), "Side taskbar placement stays inside the work area");
            work = new Rectangle(0, 60, 1024, 708);
            Check(work.Contains(PopupPlacement.AboveTray(new Size(900, 690), new Point(1000, 20), work)), "Top taskbar placement stays inside the work area");
            work = new Rectangle(0, 0, 640, 480);
            Check(work.Contains(PopupPlacement.AboveTray(new Size(2000, 1500), new Point(630, 490), work)), "Oversized popup fits a small display");
            work = new Rectangle(0, 0, 1, 1);
            Check(PopupPlacement.AboveTray(new Size(900, 690), Point.Empty, work) == work, "Tiny work area remains valid");

            work = new Rectangle(0, 0, 1920, 1040);
            Check(PopupPlacement.CenteredOnCursor(new Size(900, 690), new Point(960, 520), work) == new Rectangle(510, 175, 900, 690), "Hotkey popup is centered on the cursor away from screen edges");
            foreach (Point corner in new[] { new Point(0, 0), new Point(1919, 0), new Point(0, 1039), new Point(1919, 1039) })
                Check(work.Contains(PopupPlacement.CenteredOnCursor(new Size(900, 690), corner, work)), "Cursor placement clamps corner " + corner);
            work = new Rectangle(-1920, -200, 1920, 1040);
            Check(PopupPlacement.CenteredOnCursor(new Size(900, 690), new Point(-960, 320), work) == new Rectangle(-1410, -25, 900, 690), "Cursor centering supports negative monitor coordinates");
            work = new Rectangle(0, 40, 640, 440);
            Check(work.Contains(PopupPlacement.CenteredOnCursor(new Size(2000, 1500), new Point(638, 478), work)), "Cursor popup shrinks to fit a small working area");
            CheckTabWindowSizes(root, args[1]);
            JavaScriptSerializer json = new JavaScriptSerializer();
            Preferences migrated = json.Deserialize<Preferences>("{\"Theme\":\"Satin\",\"Scope\":\"AllUsers\"}");
            Check(migrated.Hotkey.Enabled && migrated.Hotkey.ToString() == "Ctrl+Alt+Shift+A" && migrated.Theme == "Satin" && migrated.Scope == "AllUsers", "Old theme and scope preferences acquire the chosen default hotkey");
            Check(migrated.IconSize == 48 && json.Deserialize<Preferences>("{\"IconSize\":1}").IconSize == 24 && json.Deserialize<Preferences>("{\"IconSize\":99999}").IconSize == 4096 && json.Deserialize<Preferences>("{\"IconSize\":1024}").IconSize == 1024, "Older preferences keep 48-pixel icons while larger saved sizes remain supported and invalid sizes are bounded");
            HotkeySettings first = new HotkeySettings { Key = (int)Keys.F23 }, second = new HotkeySettings { Key = (int)Keys.F22 };
            string hotkeyError;
            int received = 0;
            using (GlobalHotkey binding = new GlobalHotkey(delegate { received++; }))
            using (GlobalHotkey other = new GlobalHotkey(delegate { })) {
                Check(binding.TrySet(first, out hotkeyError) && binding.IsRegistered, "Windows registers a system-wide hotkey on a message-only window");
                int id = (int)typeof(GlobalHotkey).GetField("activeId", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(binding);
                SendMessage(binding.Handle, 0x0312, new IntPtr(id), new IntPtr((first.Key << 16) | (int)first.Modifiers()));
                Check(received == 1, "Registered WM_HOTKEY dispatches its callback");
                Check(other.TrySet(second, out hotkeyError) && !binding.TrySet(second, out hotkeyError) && hotkeyError.Contains("already in use") && binding.Current.Key == first.Key, "A conflicting shortcut reports failure and preserves the previous binding");
                HotkeySettings disabled = second.Copy(); disabled.Enabled = false;
                Check(other.TrySet(disabled, out hotkeyError) && !other.IsRegistered && binding.TrySet(second, out hotkeyError), "Disabling releases the shortcut immediately for another registration");
                SendMessage(binding.Handle, 0x0312, new IntPtr(id), new IntPtr((first.Key << 16) | (int)first.Modifiers()));
                Check(received == 1, "Queued messages for the replaced shortcut are ignored");
                Check(other.TrySet(first, out hotkeyError), "Changing the shortcut releases the old combination");
                Check(!binding.TrySet(new HotkeySettings { Key = (int)Keys.F12 }, out hotkeyError) && binding.Current.Key == second.Key, "Reserved F12 cannot replace a working hotkey");
                Check(!binding.TrySet(new HotkeySettings { Control = false, Alt = false }, out hotkeyError), "A bare typing key cannot become a global shortcut");
            }
            using (GlobalHotkey released = new GlobalHotkey(delegate { }))
                Check(released.TrySet(second, out hotkeyError), "Disposal releases the registered shortcut");

            string workerState = Path.Combine(root, "worker-state");
            Directory.CreateDirectory(workerState);
            File.WriteAllText(Path.Combine(workerState, "manifest.json"), "{\"Product\":\"BetterIcon-Craft Apps Windows\",\"SchemaVersion\":1,\"Version\":\"1.1.0\",\"Scope\":\"CurrentUser\",\"Entries\":[]}");
            WorkerClient client = new WorkerClient(args[1], new FixtureConfig { ShortcutDirectory = new[] { root }, StateDirectory = workerState });
            WorkerReply catalog = client.Run(new WorkerRequest { Action = "Catalog", Scope = "CurrentUser" }, false).GetAwaiter().GetResult();
            Check(catalog.Success && catalog.Catalog.Themes.Length == 32 && catalog.Catalog.Apps.Length == 1 && catalog.Catalog.Apps[0].Application == "PhotoCraft", "Native process invokes the catalog worker with a real fixture shortcut");
            WorkerReply preview = client.Run(new WorkerRequest { Action = "RestorePreview", Scope = "CurrentUser" }, false).GetAwaiter().GetResult();
            Check(preview.Success && preview.StateHash.Length == 64 && preview.Results.Length == 0, "Native restore worker hashes an existing manifest with inherited module paths");
            PackTests.Run(root, args[1], catalog.Catalog, Check);

            string state = Path.Combine(root, "state"), preferencesPath = Path.Combine(state, "tray-preferences.json");
            Directory.CreateDirectory(state);
            File.WriteAllText(preferencesPath, json.Serialize(new Preferences { Theme = "Craft-Icons-Zach/HyGel", Scope = "CurrentUser", IconSize = 72, Hotkey = new HotkeySettings { Enabled = false } }));
            using (EventWaitHandle show = new EventWaitHandle(false, EventResetMode.AutoReset))
            using (EventWaitHandle stop = new EventWaitHandle(false, EventResetMode.AutoReset))
            using (LauncherForm form = new LauncherForm(args[1], new FixtureConfig { ShortcutDirectory = new[] { root }, StateDirectory = Path.Combine(root, "state"), KeepOpenForAutomation = true }, true, show, stop))
            using (LauncherContext context = new LauncherContext(form))
            using (System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 50 }) {
                // Exercise the actual NotifyIcon MouseUp subscription. This is an
                // event-level check, not a claim of a physical taskbar click.
                NotifyIcon tray = (NotifyIcon)typeof(LauncherForm).GetField("tray", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                tray.Icon = SystemIcons.Information; tray.Text = "BetterIcon automated tests";
                MethodInfo mouseUp = typeof(NotifyIcon).GetMethod("OnMouseUp", BindingFlags.Instance | BindingFlags.NonPublic);
                Action click = delegate { mouseUp.Invoke(tray, new object[] { new MouseEventArgs(MouseButtons.Left, 1, 0, 0, 0) }); };
                Exception eventFailure = null;
                int ticks = 0;
                timer.Tick += delegate {
                    try {
                        if (++ticks > 600) throw new Exception("Tray startup did not finish within 30 seconds.");
                        if ((bool)typeof(LauncherForm).GetField("busy", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form)) return;
                        timer.Stop();
                        form.Text = "[TEST] BetterIcon native checks";
                        ListView openingGrid = (ListView)typeof(LauncherForm).GetField("apps", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        Check(!form.Visible, "Tray-only startup stays hidden after the real message loop initializes");
                        Check(openingGrid.Items.Count > 0 && openingGrid.SelectedItems.Count == 0, "The initial asynchronous catalog load leaves every launcher icon unselected");
                        click();
                        Check(form.Visible && Screen.FromPoint(Cursor.Position).WorkingArea.Contains(form.Bounds) && openingGrid.SelectedItems.Count == 0, "First tray release shows the popup on the clicked screen without selecting an icon");
                        click(); Check(!form.Visible, "Second tray release hides the popup");
                        click(); click(); Check(!form.Visible, "Rapid double release ends hidden without reopening");
                        mouseUp.Invoke(tray, new object[] { new MouseEventArgs(MouseButtons.Right, 1, 0, 0, 0) });
                        Check(!form.Visible, "Right tray release does not toggle the popup");
                        openingGrid.Items[0].Selected = true;
                        form.ShowManager(); Check(form.Visible && openingGrid.SelectedItems.Count == 0, "Explicit open reopens the existing popup without its previous selection");
                        // Desktop-wide hit tests need an unobscured test window,
                        // independent of other apps or the current cursor monitor.
                        bool wasTopMost = form.TopMost; Point previousLocation = form.Location;
                        try {
                            form.Location = Screen.PrimaryScreen.WorkingArea.Location + new Size(60, 60);
                            form.TopMost = true; form.BringToFront(); Application.DoEvents();
                            CheckWindowResizing(form); CheckRoundedWindow(form);
                        }
                        finally { form.TopMost = wasTopMost; form.Location = previousLocation; }
                        openingGrid.Items[0].Selected = true;
                        form.Hide(); Check(!form.Visible, "Hide retains the launcher for another tray click");
                        Point center = new Point(Screen.PrimaryScreen.WorkingArea.Left + Screen.PrimaryScreen.WorkingArea.Width / 2, Screen.PrimaryScreen.WorkingArea.Top + Screen.PrimaryScreen.WorkingArea.Height / 2);
                        form.ShowAtCursor(center);
                        Check(form.Visible && form.Bounds == PopupPlacement.CenteredOnCursor(form.Size, center, Screen.FromPoint(center).WorkingArea) && openingGrid.SelectedItems.Count == 0, "The real hidden form opens at the cursor position without its previous selection");
                        Point edge = Screen.PrimaryScreen.WorkingArea.Location;
                        openingGrid.Items[0].Selected = true;
                        form.ShowAtCursor(edge);
                        Check(Screen.PrimaryScreen.WorkingArea.Contains(form.Bounds) && openingGrid.SelectedItems.Count == 1, "Repositioning the visible popup by hotkey clamps it on screen and retains an intentional selection");
                        // Exercise the actual form keyboard handlers and ListView with
                        // distinct app names; the only launch target is our local probe.
                        FieldInfo catalogField = typeof(LauncherForm).GetField("catalog", BindingFlags.Instance | BindingFlags.NonPublic);
                        Catalog fixtureCatalog = (Catalog)catalogField.GetValue(form);
                        AppEntry photo = fixtureCatalog.Apps[0];
                        fixtureCatalog.Apps = new[] { new AppEntry { Application = "FigCraft", Name = "FigCraft", Shortcut = photo.Shortcut }, new AppEntry { Application = "FilmCraft", Name = "FilmCraft", Shortcut = photo.Shortcut }, photo };
                        typeof(LauncherForm).GetMethod("RenderApps", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(form, null);
                        ListView list = (ListView)typeof(LauncherForm).GetField("apps", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        Label filter = (Label)typeof(LauncherForm).GetField("filterHint", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        MethodInfo character = typeof(LauncherForm).GetMethod("OnKeyPress", BindingFlags.Instance | BindingFlags.NonPublic);
                        MethodInfo keyDown = typeof(LauncherForm).GetMethod("OnKeyDown", BindingFlags.Instance | BindingFlags.NonPublic);
                        Action<string> type = value => PlainText(form, value);
                        Action<Keys> key = delegate(Keys value) { keyDown.Invoke(form, new object[] { new KeyEventArgs(value) }); };
                        Check(list.Items.Count == 3 && list.SelectedItems.Count == 0, "Refreshing blank-filter artwork leaves all launcher icons unselected");
                        key(Keys.Enter);
                        Check(Directory.GetFiles(root, "launches.txt.*.launched").Length == 0 && form.Visible, "Enter before choosing or filtering an app launches nothing");
                        byte[] previousKeyboard = new byte[256];
                        if (!GetKeyboardState(previousKeyboard)) throw new Exception("Cannot read the navigation test thread's keyboard state.");
                        byte[] plainKeyboard = (byte[])previousKeyboard.Clone();
                        foreach (int modifier in new[] { 0x10, 0x11, 0x12, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5 }) plainKeyboard[modifier] = 0;
                        if (!SetKeyboardState(plainKeyboard)) throw new Exception("Cannot initialize the navigation test thread's modifiers.");
                        try { list.Focus(); SendMessage(list.Handle, 0x0100, new IntPtr((int)Keys.Right), IntPtr.Zero); }
                        finally { if (!SetKeyboardState(previousKeyboard)) throw new Exception("Cannot restore the navigation test thread's keyboard state."); }
                        Check(list.SelectedItems.Count == 1, "Native arrow navigation deliberately selects an icon from an unselected launcher");
                        form.Hide(); show.Set();
                        for (int retry = 0; retry < 100 && !form.Visible; retry++) { Thread.Sleep(20); Application.DoEvents(); }
                        Check(form.Visible && list.SelectedItems.Count == 0, "The existing-instance show signal reopens the launcher without its previous selection");
                        TabControl pages = (TabControl)typeof(LauncherForm).GetField("pages", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        Check(pages.TabPages.Count == 2 && pages.TabPages[0].Text == "Launcher" && pages.TabPages[1].Text == "Manage Icons", "Launcher and Manage Icons occupy the left and right tabs");
                        TabPage launcherPage = pages.TabPages[0];
                        LinkLabel shortcutLink = Descendants(launcherPage).OfType<LinkLabel>().Single();
                        LinkLabel versionLink = Descendants(pages.TabPages[1]).OfType<LinkLabel>().Single();
                        Rectangle linkBounds = launcherPage.RectangleToClient(shortcutLink.RectangleToScreen(shortcutLink.ClientRectangle));
                        Check(!filter.Visible && shortcutLink.Visible && linkBounds.Left == list.Left && linkBounds.Top >= list.Bottom &&
                            launcherPage.ClientSize.Height - linkBounds.Bottom <= launcherPage.Padding.Bottom + 2 &&
                            linkBounds.Right < launcherPage.ClientSize.Width / 2,
                            "The shortcut sits at the lower left of the populated Launcher, below the grid");
                        Check(shortcutLink.Text.EndsWith("Disabled") && shortcutLink.Enabled && shortcutLink.TabStop &&
                            versionLink.TabStop && shortcutLink.Font.Equals(versionLink.Font) && shortcutLink.LinkBehavior == LinkBehavior.HoverUnderline &&
                            versionLink.LinkBehavior == shortcutLink.LinkBehavior, "The disabled shortcut remains editable and uses the version link's typography and hover style");
                        TrackBar slider = (TrackBar)typeof(LauncherForm).GetField("iconSizeSlider", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        List<Bitmap> cached = (List<Bitmap>)typeof(LauncherForm).GetField("appArtwork", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        ListView previewGrid = (ListView)typeof(LauncherForm).GetField("packPreview", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        List<Bitmap> previewCached = (List<Bitmap>)typeof(LauncherForm).GetField("packArtwork", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        Check(slider.Value == 72 && GridImageSize(list) == new Size(72, 72) && GridImageSize(previewGrid) == GridImageSize(list), "Hidden startup restores the same saved icon size in both grids and the Settings slider");
                        slider.Value = 80; slider.Value = 72;
                        Check(list.SelectedItems.Count == 0, "Resizing a launcher with no selection does not select its first icon");
                        ComboBox openingThemes = (ComboBox)typeof(LauncherForm).GetField("themes", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        ThemeEntry openingTheme = (ThemeEntry)openingThemes.SelectedItem;
                        openingThemes.SelectedItem = openingThemes.Items.Cast<ThemeEntry>().First(theme => !theme.IsDefault && theme.Id != openingTheme.Id);
                        LoadingTests.Wait(form);
                        bool unselectedAfterPackChange = list.SelectedItems.Count == 0;
                        openingThemes.SelectedItem = openingTheme; LoadingTests.Wait(form);
                        Check(unselectedAfterPackChange && list.SelectedItems.Count == 0, "Asynchronous pack changes keep a blank-filter launcher unselected");
                        Rectangle firstIcon = list.GetItemRect(0, ItemBoundsPortion.Icon), firstLabel = list.GetItemRect(0, ItemBoundsPortion.Label);
                        Check(list.View == View.LargeIcon && firstLabel.Top >= firstIcon.Bottom && list.Items[1].Bounds.Left > list.Items[0].Bounds.Left && list.Items[1].Bounds.Top == list.Items[0].Bounds.Top, "Native launcher lays out a compact row of icons with names underneath");
                        form.ShowManager(); pages.Focus();
                        type("f");
                        Check(list.Items.Count == 2 && list.ContainsFocus && list.SelectedItems.Count == 1, "Typing from the launcher tab filters and focuses the highlighted result (matches=" + list.Items.Count + ", focused=" + list.ContainsFocus + ", visible=" + form.Visible + ")");
                        form.ShowAtCursor(center);
                        Check(list.Items.Count == 2 && list.AccessibleDescription.Contains("Filter: f.") && list.SelectedItems.Count == 1, "Hotkey repositioning preserves the visible popup's active filter and highlighted result");
                        IntPtr typingImages = GridImages(list); int artworkCount = ImageList_GetImageCount(typingImages);
                        type("iL");
                        Check(list.Items.Count == 1 && list.Items[0].Text == "FilmCraft" && list.AccessibleDescription.Contains("fiL"), "Successive characters narrow results and expose the query accessibly");
                        key(Keys.Back);
                        Check(list.Items.Count == 2 && list.AccessibleDescription.Contains("Filter: fi."), "Backspace broadens the list by removing one character");
                        type("zzz");
                        Check(list.Items.Count == 0 && filter.Visible && filter.Text.Contains("No apps match"), "Unmatched text produces an explicit empty result state");
                        key(Keys.Enter);
                        Check(Directory.GetFiles(root, "launches.txt.*.launched").Length == 0, "Enter with no results launches nothing");
                        key(Keys.Escape);
                        Check(form.Visible && list.Items.Count == 3 && list.SelectedItems.Count == 0, "First Escape clears the active filter and selection without closing the popup");
                        type("PH");
                        Check(list.Items.Count == 1 && list.SelectedItems[0].Text == "PhotoCraft", "Typing a new query highlights its matching app");
                        key(Keys.Enter);
                        string[] launchReceipts = new string[0];
                        for (int retry = 0; retry < 100 && launchReceipts.Length == 0; retry++) { Thread.Sleep(20); launchReceipts = Directory.GetFiles(root, "launches.txt.*.launched"); }
                        Check(launchReceipts.Length == 1 && File.ReadAllText(launchReceipts[0]) == "PhotoCraft", "Enter launches the highlighted original fixture shortcut exactly once");
                        Check(GridImages(list) == typingImages && ImageList_GetImageCount(GridImages(list)) == artworkCount, "Typing reuses the loaded artwork instead of rebuilding image lists");
                        form.Hide(); form.ShowManager();
                        Check(list.Items.Count == 3 && !filter.Visible && list.SelectedItems.Count == 0, "Reopening starts with all apps, no stale filter, and no selected icon");
                        CheckLauncherFeedback(list, root);
                        pages.SelectedIndex = 1; type("fil");
                        Check(list.Items.Count == 3 && pages.SelectedIndex == 1, "Settings keyboard input does not filter the launcher");
                        CheckProjectLink(versionLink, root);
                        Bitmap[] sources = cached.ToArray(), previewSources = previewCached.ToArray();
                        previewGrid.Items[1].Selected = true;
                        foreach (int size in new[] { 24, 128, 32, 96 }) slider.Value = size;
                        Check(GridImageSize(list) == new Size(96, 96) && ImageList_GetImageCount(GridImages(list)) == 3 && cached.SequenceEqual(sources) && list.GetItemRect(0, ItemBoundsPortion.Label).Top >= list.GetItemRect(0, ItemBoundsPortion.Icon).Bottom, "Resizing through compact sizes retains cached launcher artwork and labels below icons");
                        Check(GridImageSize(previewGrid) == GridImageSize(list) && ImageList_GetImageCount(GridImages(previewGrid)) == previewGrid.Items.Count && previewCached.SequenceEqual(previewSources) && previewGrid.SelectedItems.Count == 1 && previewGrid.SelectedItems[0].Index == 1 && previewGrid.GetItemRect(0, ItemBoundsPortion.Label).Top >= previewGrid.GetItemRect(0, ItemBoundsPortion.Icon).Bottom, "The Settings preview resizes immediately from cached artwork while retaining its selection and labels below icons");
                        pages.SelectedIndex = 0; type("f"); list.Items[0].Selected = false; list.Items[1].Selected = true;
                        pages.SelectedIndex = 1; slider.Value = 64;
                        Check(list.Items.Count == 2 && list.AccessibleDescription.Contains("Filter: f.") && list.SelectedItems.Count == 1 && list.SelectedItems[0].Text == "FilmCraft", "Icon resizing preserves the active filter and selected app");
                        Preferences sized = json.Deserialize<Preferences>(File.ReadAllText(preferencesPath));
                        Check(sized.IconSize == 64 && sized.Theme == "Craft-Icons-Zach/HyGel" && sized.Scope == "CurrentUser" && !sized.Hotkey.Enabled, "Icon size persists without changing theme, scope, or hotkey preferences");
                        ((Button)typeof(LauncherForm).GetField("resetIconSize", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form)).PerformClick();
                        Check(GridImageSize(list) == new Size(48, 48) && GridImageSize(previewGrid) == GridImageSize(list) && list.Items[1].Bounds.Left - list.Items[0].Bounds.Left < 200 && json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).IconSize == 48, "Reset restores and saves compact 48-pixel icons in both grids");
                        pages.SelectedIndex = 0;
                        Action<int, bool> wheel = delegate(int delta, bool control) { SendMessage(list.Handle, 0x020A, new IntPtr((delta << 16) | (control ? 8 : 0)), IntPtr.Zero); };
                        wheel(120, true);
                        Check(slider.Value == 56 && GridImageSize(list) == new Size(56, 56) && GridImageSize(previewGrid) == GridImageSize(list) && json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).IconSize == 56 && list.SelectedItems[0].Text == "FilmCraft" && list.AccessibleDescription.Contains("Filter: f."), "Native Ctrl+wheel enlarges both grids, updates the slider, saves the size, and retains filter/selection");
                        wheel(-240, true); wheel(60, true);
                        Check(slider.Value == 40, "Ctrl+wheel zooms out and waits for a complete fine-resolution wheel step");
                        wheel(60, true); wheel(120, false);
                        Check(slider.Value == 48, "Partial Ctrl+wheel steps accumulate while ordinary scrolling leaves size unchanged");
                        wheel(32760, true); bool reachedMaximum = slider.Value == slider.Maximum && slider.Maximum > 256;
                        wheel(-32760, true); bool reachedMinimum = slider.Value == 24;
                        typeof(LauncherForm).GetMethod("SetBusy", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(form, new object[] { true, null });
                        wheel(120, true);
                        Check(reachedMaximum && reachedMinimum && slider.Value == 24, "Ctrl+wheel respects size bounds and cannot resize during a busy operation");
                        typeof(LauncherForm).GetMethod("SetBusy", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(form, new object[] { false, null });
                        pages.SelectedIndex = 0; key(Keys.Control | Keys.Back); pages.SelectedIndex = 1; slider.Value = 80;
                        ComboBox themePicker = (ComboBox)typeof(LauncherForm).GetField("themes", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        Panel settingsScroll = (Panel)typeof(LauncherForm).GetField("settingsScroll", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        TableLayoutPanel settingsContent = (TableLayoutPanel)typeof(LauncherForm).GetField("settingsContent", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        Button removePack = (Button)typeof(LauncherForm).GetField("removePackButton", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        Button removeFilePack = (Button)typeof(LauncherForm).GetField("removeFilePackButton", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        Button restoreApps = (Button)typeof(LauncherForm).GetField("restore", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        Check(removePack.Visible && removePack.Text == "Remove app pack" && removePack.Enabled && removePack.ContextMenuStrip == null
                            && removeFilePack.Visible && removeFilePack.Text == "Remove file pack" && !removeFilePack.Enabled
                            && removePack.Parent == removeFilePack.Parent && removePack.Top == removeFilePack.Top && removePack.Right <= removeFilePack.Left
                            && !Descendants(pages.TabPages[1]).OfType<Button>().Any(button => button.Text == "Remove pack" || button.Text == "Pack actions..." || button.Text == "Change hotkey..." || button.Text == "Exit" || button.Text == "Refresh apps"),
                            "Manage Icons has one remove button for each pack list and no old pack-actions, hotkey or utility buttons");
                        Check(restoreApps.Visible && restoreApps.Text == "Restore app defaults...", "The restore action beside Apply icons says that it restores app icons");
                        Control previewRow = previewGrid.Parent;
                        ListView filePreviewGrid = (ListView)typeof(LauncherForm).GetField("filePreview", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        Check(previewGrid.Dock == DockStyle.Fill && previewRow.Dock == DockStyle.Fill && previewRow.Parent == settingsContent && filePreviewGrid.Parent == previewRow,
                            "The pack preview occupies the flexible middle row of Manage Icons");
                        Check(!filePreviewGrid.Visible && previewGrid.Width >= previewRow.ClientSize.Width - previewGrid.Margin.Horizontal - 1,
                            "The app preview uses the whole row while the original file icons are chosen");
                        Size previousSize = form.Size; int previousIconSize = slider.Value;
                        try {
                            foreach (Size windowSize in new[] { new Size(790, 570), new Size(900, 690), new Size(900, 900) }) foreach (int iconSize in new[] { 24, 128, 184 }) {
                                form.Size = windowSize; slider.Value = iconSize; settingsScroll.AutoScrollPosition = Point.Empty;
                                form.PerformLayout(); settingsContent.PerformLayout(); Application.DoEvents();
                                string layoutProblem = SettingsLayoutProblem(settingsContent);
                                Check(layoutProblem == null && settingsContent.Width <= settingsScroll.ClientSize.Width && !settingsScroll.HorizontalScroll.Visible && previewGrid.Height >= ((IconGridView)previewGrid).GridCellSize.Height,
                                    "Manage Icons fits its controls and at least one complete icon row at " + windowSize.Width + "x" + windowSize.Height + ", " + iconSize + "-pixel icons" + (layoutProblem == null ? "" : ": " + layoutProblem));
                            }
                            slider.Value = 64; form.Size = new Size(900, 690); form.PerformLayout(); Application.DoEvents();
                            int compactPreview = previewGrid.Height;
                            form.Size = new Size(900, 900); form.PerformLayout(); Application.DoEvents();
                            Check(previewGrid.Height >= compactPreview + 190,
                                "Increasing window height gives the pack preview additional visible rows instead of adding empty space");
                        }
                        finally { form.Size = previousSize; slider.Value = previousIconSize; settingsScroll.AutoScrollPosition = Point.Empty; form.PerformLayout(); }
                        ContextMenuStrip importMenu = (ContextMenuStrip)typeof(LauncherForm).GetField("importPackMenu", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        ContextMenuStrip manageMenu = (ContextMenuStrip)typeof(LauncherForm).GetField("managePackMenu", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        ContextMenuStrip trayCommands = (ContextMenuStrip)typeof(LauncherForm).GetField("trayMenu", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        ToolStripMenuItem packCommands = trayCommands.Items.OfType<ToolStripMenuItem>().Single(item => item.Text == "Pack actions");
                        Check(new[] { "Customize...", "Edit pack...", "Export ZIP...", "Restore built-in packs" }.All(text => packCommands.DropDownItems.Cast<ToolStripItem>().Any(item => item.Text == text)) && themePicker.ContextMenuStrip == manageMenu,
                            "Pack editing, customization, ZIP sharing and built-in recovery remain reachable from the tray and pack selector");
                        ToolStripItem[] manageItems = manageMenu.Items.Cast<ToolStripItem>().ToArray();
                        Check(new[] { "Edit pack...", "Export ZIP..." }.All(text => manageItems.Single(item => item.Text == text).Enabled == false) && manageItems.Single(item => item.Text == "Customize...").Enabled,
                            "Built-in packs offer Customize while personal-only Edit and Export actions stay disabled");
                        ThemeEntry beforeCustomize = (ThemeEntry)themePicker.SelectedItem;
                        byte[] beforeCustomizePreferences = File.ReadAllBytes(preferencesPath);
                        string[] beforeCustomizeThemes = themePicker.Items.Cast<ThemeEntry>().Select(theme => theme.Id).ToArray();
                        PackLibrary fixtureLibrary = (PackLibrary)typeof(LauncherForm).GetField("library", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        Func<string[]> libraryFiles = () => Directory.Exists(fixtureLibrary.Root) ? Directory.GetFileSystemEntries(fixtureLibrary.Root, "*", SearchOption.AllDirectories).OrderBy(path => path).ToArray() : new string[0];
                        string[] beforeCustomizeFiles = libraryFiles();
                        string libraryManifest = Path.Combine(fixtureLibrary.Root, "library.json");
                        Func<string> manifestBytes = () => File.Exists(libraryManifest) ? Convert.ToBase64String(File.ReadAllBytes(libraryManifest)) : null;
                        string beforeCustomizeManifest = manifestBytes();
                        bool customizeSeen = false, customizeTrayDisabled = false, customizeHasBasis = false;
                        Exception customizeFailure = null;
                        DateTime customizeDeadline = DateTime.UtcNow.AddSeconds(10);
                        using (System.Windows.Forms.Timer closeCustomize = new System.Windows.Forms.Timer { Interval = 25 }) {
                            closeCustomize.Tick += delegate {
                                if (DateTime.UtcNow > customizeDeadline) {
                                    customizeFailure = new Exception("The tray Customize command did not open the pack editor within ten seconds.");
                                    foreach (Form dialog in form.OwnedForms) { dialog.DialogResult = DialogResult.Cancel; dialog.Close(); }
                                    closeCustomize.Stop(); return;
                                }
                                PackEditor editor = form.OwnedForms.OfType<PackEditor>().FirstOrDefault();
                                if (editor == null) return;
                                customizeSeen = true;
                                customizeTrayDisabled = !((ContextMenuStrip)typeof(LauncherForm).GetField("trayMenu", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form)).Enabled;
                                customizeHasBasis = Descendants(editor).OfType<TextBox>().Single(box => box.AccessibleName == "Pack name").Text == beforeCustomize.Name + " custom";
                                closeCustomize.Stop(); ((Button)editor.CancelButton).PerformClick();
                            };
                            closeCustomize.Start();
                            packCommands.DropDownItems.OfType<ToolStripMenuItem>().Single(item => item.Text == "Customize...").PerformClick();
                            closeCustomize.Stop();
                        }
                        if (customizeFailure != null) throw customizeFailure;
                        trayCommands = (ContextMenuStrip)typeof(LauncherForm).GetField("trayMenu", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        Check(customizeSeen && customizeHasBasis, "The tray Customize command opens the existing editor with the selected pack as its basis");
                        Check(customizeTrayDisabled && trayCommands.Enabled, "The pack editor pauses tray commands and restores them after cancellation");
                        Check(((ThemeEntry)themePicker.SelectedItem).Id == beforeCustomize.Id && themePicker.Items.Cast<ThemeEntry>().Select(theme => theme.Id).SequenceEqual(beforeCustomizeThemes)
                            && File.ReadAllBytes(preferencesPath).SequenceEqual(beforeCustomizePreferences) && libraryFiles().SequenceEqual(beforeCustomizeFiles) && manifestBytes() == beforeCustomizeManifest,
                            "Canceling tray customization preserves pack selection, library files and preferences without creating a pack");
                        pages.SelectedIndex = 0;
                        PropertyInfo canFilter = typeof(LauncherForm).GetProperty("CanFilter", BindingFlags.Instance | BindingFlags.NonPublic);
                        ContextMenuStrip brandingMenu = (ContextMenuStrip)typeof(LauncherForm).GetField("appIconMenu", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        foreach (ContextMenuStrip menu in new[] { importMenu, manageMenu, brandingMenu }) {
                            try {
                                menu.Show(list, new Point(8, 8));
                                bool filteringBlocked = !(bool)canFilter.GetValue(form, null);
                                type("zzz");
                                Check(menu.Visible && filteringBlocked && list.Items.Count == 3, (menu == importMenu ? "Import" : menu == manageMenu ? "Pack actions" : "App icon") + " menu keeps keyboard input out of launcher filtering");
                            }
                            finally { menu.Close(); }
                        }
                        pages.SelectedIndex = 1;
                        themePicker.DroppedDown = true;
                        KeyPressEventArgs dropdownKey = new KeyPressEventArgs('p'); character.Invoke(form, new object[] { dropdownKey });
                        Check(!dropdownKey.Handled && list.Items.Count == 3, "An open theme dropdown keeps its own typing behavior");
                        themePicker.DroppedDown = false;
                        // A tray click during the preceding DoEvents layout checks can hide
                        // the fixture. Establish this keyboard test's own starting state.
                        form.ShowManager(); pages.SelectedIndex = 1;
                        key(Keys.Escape); Check(pages.SelectedIndex == 0 && form.Visible, "Escape from Settings returns to the launcher");
                        form.Enabled = false; type("p"); form.Enabled = true;
                        Check(list.Items.Count == 3, "Modal dialog input cannot alter the app filter");
                        type("pho"); key(Keys.Control | Keys.Back);
                        Check(list.Items.Count == 3 && list.SelectedItems.Count == 0, "Ctrl+Backspace clears the entire filter and selection");
                        key(Keys.Escape); Check(!form.Visible, "Escape with no filter closes the popup");
                        form.ShowManager();
                        bool hotkeyDialogSeen = false, hotkeyTrayDisabled = false;
                        using (System.Windows.Forms.Timer closeHotkey = new System.Windows.Forms.Timer { Interval = 25 }) {
                            closeHotkey.Tick += delegate {
                                HotkeySettingsDialog dialog = form.OwnedForms.OfType<HotkeySettingsDialog>().FirstOrDefault();
                                if (dialog == null) return;
                                hotkeyDialogSeen = true; hotkeyTrayDisabled = !trayCommands.Enabled;
                                dialog.DialogResult = DialogResult.Cancel; dialog.Close();
                            };
                            closeHotkey.Start();
                            trayCommands.Items.OfType<ToolStripMenuItem>().Single(item => item.Text == "Change hotkey...").PerformClick();
                            closeHotkey.Stop();
                        }
                        Check(hotkeyDialogSeen, "The tray Change hotkey command opens the existing configuration and disable dialog");
                        Check(hotkeyTrayDisabled && trayCommands.Enabled, "The hotkey dialog pauses tray commands and restores them after cancellation");
                        MethodInfo saveHotkey = typeof(LauncherForm).GetMethod("SaveHotkey", BindingFlags.Instance | BindingFlags.NonPublic);
                        string themeBefore = json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).Theme;
                        using (System.Windows.Forms.Timer editShortcut = new System.Windows.Forms.Timer { Interval = 25 }) {
                            editShortcut.Tick += delegate {
                                HotkeySettingsDialog dialog = form.OwnedForms.OfType<HotkeySettingsDialog>().FirstOrDefault();
                                if (dialog == null) return;
                                editShortcut.Stop();
                                Descendants(dialog).OfType<CheckBox>().Single(box => box.Text == "Enable system-wide hotkey").Checked = true;
                                ComboBox keys = Descendants(dialog).OfType<ComboBox>().Single();
                                keys.SelectedIndex = keys.FindStringExact(HotkeySettings.KeyName(second.Key));
                                ((Button)dialog.AcceptButton).PerformClick();
                                if (dialog.Visible) dialog.Close();
                            };
                            editShortcut.Start();
                            Check(shortcutLink.Focus(), "The Launcher shortcut can receive keyboard focus");
                            Message enter = Message.Create(shortcutLink.Handle, 0x0100, new IntPtr((int)Keys.Enter), IntPtr.Zero);
                            if (!shortcutLink.PreProcessMessage(ref enter)) SendMessage(enter.HWnd, enter.Msg, enter.WParam, enter.LParam);
                        }
                        Check(pages.SelectedTab == launcherPage && shortcutLink.Text.EndsWith(second.ToString()),
                            "The launcher footer opens the real shortcut editor and shows the saved combination immediately");
                        Preferences saved = json.Deserialize<Preferences>(File.ReadAllText(preferencesPath));
                        Check(saved.Hotkey.Key == second.Key && saved.Hotkey.Enabled && saved.Theme == themeBefore && saved.Scope == "CurrentUser" && saved.IconSize == 80, "Custom hotkey persists without changing theme, scope, or icon size");
                        using (FileStream locked = File.Open(preferencesPath, FileMode.Open, FileAccess.Read, FileShare.None)) {
                            string saveError = (string)saveHotkey.Invoke(form, new object[] { first });
                            GlobalHotkey active = (GlobalHotkey)typeof(LauncherForm).GetField("hotkey", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                            Check(saveError != null && active.Current.Key == second.Key && shortcutLink.Text.EndsWith(second.ToString()), "A settings write failure restores the previous working shortcut and its footer text");
                        }
                        HotkeySettings off = second.Copy(); off.Enabled = false;
                        Check(saveHotkey.Invoke(form, new object[] { off }) == null && !json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).Hotkey.Enabled &&
                            shortcutLink.Text.EndsWith("Disabled") && shortcutLink.Enabled, "Disabling the shortcut persists and leaves its footer available for editing");
                        CheckDefaultAndIndividualRestore(form, root, preferencesPath, json);
                        CheckAppIconEditing(form, root, preferencesPath, json);
                        CheckLargeArtwork(form, root, preferencesPath, json);
                        CheckIconSizeEditing(form, preferencesPath, json);
                        CheckExistingLauncherDefault(form, root, json);
                        AppearanceTests.Run(form, preferencesPath, args[1], Check);
                        LoadingTests.Run(form, preferencesPath, Check);
                        CheckAppNames(form, preferencesPath, json);
                        stop.Set(); // Exercise normal shutdown through the same message loop.
                    }
                    catch (Exception error) { eventFailure = error; timer.Stop(); context.ExitThread(); }
                };
                timer.Start(); Application.Run(context);
                if (eventFailure != null) throw eventFailure;
            }
            using (GlobalHotkey occupied = new GlobalHotkey(delegate { })) {
                Check(occupied.TrySet(first, out hotkeyError), "The restart fixture reserves the saved shortcut before opening the launcher");
                Preferences restart = json.Deserialize<Preferences>(File.ReadAllText(preferencesPath));
                restart.Hotkey = first; File.WriteAllText(preferencesPath, json.Serialize(restart));
                CheckLargeStartup(root, args[1], first);
            }
            CheckContextRestore(root, args[1], json);
            ShortcutScopeTests.Run(root, args[1], json, Check);
            CheckButtonRows();
            FileTypeTests.Run(root, args[1], json, Check);
            ReapplyTests.Run(root, args[1], json, Check);
            LoginItemTests.Run(root, args[1], json, Check);
            ReapplyFixTests.Run(root, args[1], json, Check);
            WebPTests.Run(root, args[1], json, Check);
        }
        catch (Exception error) { failure = error.ToString(); Console.Error.WriteLine(failure); }
        finally { File.WriteAllText(Path.Combine(root, "results.json"), new JavaScriptSerializer().Serialize(new { Passed = failure == null, Error = failure, Checks = checks, ArtifactDirectory = root })); }
        return failure == null ? 0 : 1;
    }
}
