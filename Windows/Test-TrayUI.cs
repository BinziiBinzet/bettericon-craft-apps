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
        ThemeEntry basis = themes.Items.Cast<ThemeEntry>().First(theme => theme.Id == "Craft-Icons-Zach/Satin");
        string previousTheme = preferences.Theme; string[] previousDefaults = preferences.DefaultShortcuts;
        MethodInfo reload = typeof(LauncherForm).GetMethod("ReloadLibrary", instance), change = typeof(LauncherForm).GetMethod("ChangeAppIcon", instance);
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
            Check(appImages[appIndex].GetPixel(64, 64).ToArgb() == Color.Lime.ToArgb() && packImages[packIndex].GetPixel(64, 64).ToArgb() == Color.Lime.ToArgb(),
                "The selected image immediately appears in both launcher and Settings grids");
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
        finally { preferences.DefaultShortcuts = previousDefaults; reload.Invoke(form, new object[] { previousTheme }); }
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
            string nested = SettingsLayoutProblem(child);
            if (nested != null) return nested;
        }
        return null;
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
        Check(slider.Maximum == 128 && slider.Value == 128 && json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).IconSize == 128 && GridImageSize(launcher) == new Size(128, 128) && GridImageSize(preview) == new Size(128, 128),
            "Switching to smaller artwork adjusts the range and replaces oversized artwork in both native grids");
        typeof(LauncherForm).GetMethod("ReloadLibrary", instance).Invoke(form, new object[] { high.Id }); slider.Value = 512;
    }
    static void CheckLargeStartup(string root, string source)
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
        TabControl pages = (TabControl)field("pages");
        ThemeEntry previousTheme = (ThemeEntry)((ComboBox)field("themes")).SelectedItem;
        Check(json.Deserialize<Preferences>("{\"Theme\":\"Satin\"}").ShowAppNames && names.Checked && launcher.ShowAppNames && preview.ShowAppNames, "Existing preferences retain visible app names by default");
        slider.Value = 48;
        Size namedCell = launcher.GridCellSize;
        string[] titles = launcher.Items.Cast<ListViewItem>().Select(item => item.Text).ToArray();
        Bitmap[] artwork = ((List<Bitmap>)field("appArtwork")).ToArray();
        names.Checked = false;
        Check(!launcher.ShowAppNames && !preview.ShowAppNames && HiddenLabels(launcher) && HiddenLabels(preview), "Show app names switches native visual labels off in both grids");
        Check(launcher.GridCellSize.Width < namedCell.Width && launcher.GridCellSize.Height < namedCell.Height && launcher.GridCellSize == preview.GridCellSize, "Icon-only mode removes unused name space and packs both grids more tightly");
        Check(launcher.Items.Cast<ListViewItem>().Select(item => item.Text).SequenceEqual(titles) && launcher.Items.Cast<ListViewItem>().All(item => !String.IsNullOrWhiteSpace(item.ToolTipText)) && ((List<Bitmap>)field("appArtwork")).SequenceEqual(artwork), "Hiding labels retains accessible item names, hover tooltips and the existing artwork cache");
        Check(!json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).ShowAppNames, "The icon-only choice is saved for subsequent launches");
        form.ShowManager(); pages.SelectedIndex = 0;
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
        string theme = ((ThemeEntry)((ComboBox)field("themes")).SelectedItem).Id;
        TrackBar slider = (TrackBar)field("iconSizeSlider"); int previousSize = slider.Value;
        string shortcut = Path.Combine(root, "PhotoCraft.lnk"); byte[] bytes = File.ReadAllBytes(shortcut);
        List<Bitmap> artwork = (List<Bitmap>)field("appArtwork");
        TabControl pages = (TabControl)field("pages");
        try {
            catalog.Apps = new[] { new AppEntry { Application = "ArtCraftLauncher", Name = "ArtCraft Launcher", Shortcut = shortcut, Scope = "CurrentUser", IconPath = "", OriginalIconPath = Path.Combine(root, "original-red.png"), UsingDefaultIcon = true } };
            preferences.DefaultShortcuts = new string[0]; call("RenderSelection", null);
            Check(artwork[0].GetPixel(64, 64).ToArgb() == Color.Red.ToArgb(), "A launcher without an explicit icon path displays its own original instead of BetterIcon's fallback");
            PackLibrary library = (PackLibrary)field("library");
            ThemeEntry custom = library.Save("Launcher preview fixture", new Dictionary<string, string> { { "ArtCraftLauncher", Path.Combine(root, "current-blue.png") } }, null);
            call("ReloadLibrary", new object[] { custom.Id });
            Check(artwork[0].GetPixel(64, 64).ToArgb() == Color.Blue.ToArgb(), "A custom launcher pack can preview artwork before any shortcut change");
            pages.SelectedIndex = 0;
            ListView grid = (ListView)field("apps"); RequestIconMenu(grid, grid.Items[0]);
            ToolStripMenuItem restore = (ToolStripMenuItem)field("restoreIconDefault");
            Check(restore.Enabled && ((AppEntry)field("iconMenuTarget")).Scope == "CurrentUser", "The launcher default action is available without a backup and targets its own locations");
            ShortcutScopeTests.SelectScope(() => restore.PerformClick(), "CurrentUser"); ((ContextMenuStrip)field("iconMenu")).Close();
            Check(artwork[0].GetPixel(64, 64).ToArgb() == Color.Red.ToArgb() && preferences.DefaultShortcuts.Contains(shortcut) && File.ReadAllBytes(shortcut).SequenceEqual(bytes) && ((Label)field("status")).Text.Contains("already at the default"), "Restoring an already-default launcher resets its preview and reports success without rewriting the shortcut");
            pages.SelectedIndex = 1;
            ListView preview = (ListView)field("packPreview"); RequestIconMenu(preview, preview.Items[0]);
            Check(restore.Enabled, "The Settings context menu also allows selecting a launcher's existing default without a backup");
        }
        finally {
            ((ContextMenuStrip)field("iconMenu")).Close(); catalog.Apps = previousApps; preferences.DefaultShortcuts = defaults;
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
        ThemeEntry themed = themes.Items.Cast<ThemeEntry>().First(t => t.Id == "Craft-Icons-Zach/Satin");
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
        call("ReloadLibrary", new object[] { themed.Id });
        Check(!appArtwork.Any(image => image.GetPixel(64, 64).ToArgb() == Color.Red.ToArgb()) && packPreview.Items.Count == themed.Icons.Length,
            "Selecting an icon pack restores themed thumbnails and its full preview");

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
            call("ReloadLibrary", new object[] { ThemeEntry.DefaultThemeId });
            Check(SamePixels(appArtwork[3], second) && SamePixels(packArtwork[0], second),
                "Default launcher and preview both honor the original native icon resource index");
            catalog.Apps[3].OriginalIconPath = original; catalog.Apps[3].OriginalIconIndex = 0;
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
        WorkerReply plan = worker.Run(new WorkerRequest { Action = "Preview", Scope = "CurrentUser", Theme = "Craft-Icons-Zach/Satin" }, false).GetAwaiter().GetResult();
        WorkerReply applied = worker.Run(new WorkerRequest { Action = "Apply", Scope = "CurrentUser", Theme = "Craft-Icons-Zach/Satin", ExpectedPlan = plan.Plan }, false).GetAwaiter().GetResult();
        Check(applied.Results.Length == 2 && applied.Results.All(result => result.Status == "Applied"), "Context-menu integration prepares two isolated themed shortcuts");
        byte[] themedFilm = File.ReadAllBytes(film);
        string preferencesPath = Path.Combine(state, "tray-preferences.json");
        File.WriteAllText(preferencesPath, json.Serialize(new Preferences { Theme = "Craft-Icons-Zach/Satin", Scope = "AllUsers", Hotkey = new HotkeySettings { Enabled = false } }));
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
            Check(catalog.Success && catalog.Catalog.Themes.Length == 13 && catalog.Catalog.Apps.Length == 1 && catalog.Catalog.Apps[0].Application == "PhotoCraft", "Native process invokes the catalog worker with a real fixture shortcut");
            WorkerReply preview = client.Run(new WorkerRequest { Action = "RestorePreview", Scope = "CurrentUser" }, false).GetAwaiter().GetResult();
            Check(preview.Success && preview.StateHash.Length == 64 && preview.Results.Length == 0, "Native restore worker hashes an existing manifest with inherited module paths");
            PackTests.Run(root, args[1], catalog.Catalog, Check);

            string state = Path.Combine(root, "state"), preferencesPath = Path.Combine(state, "tray-preferences.json");
            Directory.CreateDirectory(state);
            File.WriteAllText(preferencesPath, json.Serialize(new Preferences { Theme = "Craft-Icons-Zach/Satin", Scope = "CurrentUser", IconSize = 72, Hotkey = new HotkeySettings { Enabled = false } }));
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
                        Check(!form.Visible, "Tray-only startup stays hidden after the real message loop initializes");
                        click();
                        Check(form.Visible && Screen.FromPoint(Cursor.Position).WorkingArea.Contains(form.Bounds), "First tray release shows the popup on the clicked screen");
                        click(); Check(!form.Visible, "Second tray release hides the popup");
                        click(); click(); Check(!form.Visible, "Rapid double release ends hidden without reopening");
                        mouseUp.Invoke(tray, new object[] { new MouseEventArgs(MouseButtons.Right, 1, 0, 0, 0) });
                        Check(!form.Visible, "Right tray release does not toggle the popup");
                        form.ShowManager(); Check(form.Visible, "Explicit open reopens the existing popup");
                        // Desktop-wide hit tests need an unobscured test window,
                        // independent of other apps or the current cursor monitor.
                        bool wasTopMost = form.TopMost; Point previousLocation = form.Location;
                        try {
                            form.Location = Screen.PrimaryScreen.WorkingArea.Location + new Size(60, 60);
                            form.TopMost = true; form.BringToFront(); Application.DoEvents();
                            CheckWindowResizing(form); CheckRoundedWindow(form);
                        }
                        finally { form.TopMost = wasTopMost; form.Location = previousLocation; }
                        form.Hide(); Check(!form.Visible, "Hide retains the launcher for another tray click");
                        Point center = new Point(Screen.PrimaryScreen.WorkingArea.Left + Screen.PrimaryScreen.WorkingArea.Width / 2, Screen.PrimaryScreen.WorkingArea.Top + Screen.PrimaryScreen.WorkingArea.Height / 2);
                        form.ShowAtCursor(center);
                        Check(form.Visible && form.Bounds == PopupPlacement.CenteredOnCursor(form.Size, center, Screen.FromPoint(center).WorkingArea), "The real hidden form opens at the cursor position");
                        Point edge = Screen.PrimaryScreen.WorkingArea.Location;
                        form.ShowAtCursor(edge);
                        Check(Screen.PrimaryScreen.WorkingArea.Contains(form.Bounds), "Reopening by hotkey moves the existing popup and clamps it on screen");
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
                        TabControl pages = (TabControl)typeof(LauncherForm).GetField("pages", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        Check(pages.TabPages.Count == 2 && pages.TabPages[0].Text == "Launcher" && pages.TabPages[1].Text == "Manage Icons", "Launcher and Manage Icons occupy the left and right tabs");
                        Check(pages.TabPages[0].Controls.Count == 2 && !filter.Visible, "The populated Launcher page contains only the app grid");
                        TrackBar slider = (TrackBar)typeof(LauncherForm).GetField("iconSizeSlider", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        List<Bitmap> cached = (List<Bitmap>)typeof(LauncherForm).GetField("appArtwork", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        ListView previewGrid = (ListView)typeof(LauncherForm).GetField("packPreview", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        List<Bitmap> previewCached = (List<Bitmap>)typeof(LauncherForm).GetField("packArtwork", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        Check(slider.Value == 72 && GridImageSize(list) == new Size(72, 72) && GridImageSize(previewGrid) == GridImageSize(list), "Hidden startup restores the same saved icon size in both grids and the Settings slider");
                        Rectangle firstIcon = list.GetItemRect(0, ItemBoundsPortion.Icon), firstLabel = list.GetItemRect(0, ItemBoundsPortion.Label);
                        Check(list.View == View.LargeIcon && firstLabel.Top >= firstIcon.Bottom && list.Items[1].Bounds.Left > list.Items[0].Bounds.Left && list.Items[1].Bounds.Top == list.Items[0].Bounds.Top, "Native launcher lays out a compact row of icons with names underneath");
                        form.ShowManager(); pages.Focus();
                        type("f");
                        Check(list.Items.Count == 2 && list.ContainsFocus && list.SelectedItems.Count == 1, "Typing from the launcher tab filters and focuses the highlighted result (matches=" + list.Items.Count + ", focused=" + list.ContainsFocus + ", visible=" + form.Visible + ")");
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
                        Check(form.Visible && list.Items.Count == 3, "First Escape clears the active filter without closing the popup");
                        type("PH");
                        Check(list.Items.Count == 1 && list.SelectedItems[0].Text == "PhotoCraft", "Typing a new query highlights its matching app");
                        key(Keys.Enter);
                        string[] launchReceipts = new string[0];
                        for (int retry = 0; retry < 100 && launchReceipts.Length == 0; retry++) { Thread.Sleep(20); launchReceipts = Directory.GetFiles(root, "launches.txt.*.launched"); }
                        Check(launchReceipts.Length == 1 && File.ReadAllText(launchReceipts[0]) == "PhotoCraft", "Enter launches the highlighted original fixture shortcut exactly once");
                        Check(GridImages(list) == typingImages && ImageList_GetImageCount(GridImages(list)) == artworkCount, "Typing reuses the loaded artwork instead of rebuilding image lists");
                        form.Hide(); form.ShowManager();
                        Check(list.Items.Count == 3 && !filter.Visible, "Reopening starts with all apps and no stale filter");
                        pages.SelectedIndex = 1; type("fil");
                        Check(list.Items.Count == 3 && pages.SelectedIndex == 1, "Settings keyboard input does not filter the launcher");
                        Bitmap[] sources = cached.ToArray(), previewSources = previewCached.ToArray();
                        previewGrid.Items[1].Selected = true;
                        foreach (int size in new[] { 24, 128, 32, 96 }) slider.Value = size;
                        Check(GridImageSize(list) == new Size(96, 96) && ImageList_GetImageCount(GridImages(list)) == 3 && cached.SequenceEqual(sources) && list.GetItemRect(0, ItemBoundsPortion.Label).Top >= list.GetItemRect(0, ItemBoundsPortion.Icon).Bottom, "Resizing through compact sizes retains cached launcher artwork and labels below icons");
                        Check(GridImageSize(previewGrid) == GridImageSize(list) && ImageList_GetImageCount(GridImages(previewGrid)) == previewGrid.Items.Count && previewCached.SequenceEqual(previewSources) && previewGrid.SelectedItems.Count == 1 && previewGrid.SelectedItems[0].Index == 1 && previewGrid.GetItemRect(0, ItemBoundsPortion.Label).Top >= previewGrid.GetItemRect(0, ItemBoundsPortion.Icon).Bottom, "The Settings preview resizes immediately from cached artwork while retaining its selection and labels below icons");
                        pages.SelectedIndex = 0; type("f"); list.Items[0].Selected = false; list.Items[1].Selected = true;
                        pages.SelectedIndex = 1; slider.Value = 64;
                        Check(list.Items.Count == 2 && list.AccessibleDescription.Contains("Filter: f.") && list.SelectedItems.Count == 1 && list.SelectedItems[0].Text == "FilmCraft", "Icon resizing preserves the active filter and selected app");
                        Preferences sized = json.Deserialize<Preferences>(File.ReadAllText(preferencesPath));
                        Check(sized.IconSize == 64 && sized.Theme == "Craft-Icons-Zach/Satin" && sized.Scope == "CurrentUser" && !sized.Hotkey.Enabled, "Icon size persists without changing theme, scope, or hotkey preferences");
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
                        Check(removePack.Visible && removePack.Text == "Remove pack" && removePack.ContextMenuStrip == null
                            && !Descendants(pages.TabPages[1]).OfType<Button>().Any(button => button.Text == "Pack actions..." || button.Text == "Change hotkey..." || button.Text == "Exit" || button.Text == "Refresh apps"),
                            "Manage Icons has a direct Remove pack button and no old pack-actions, hotkey or utility buttons");
                        Check(previewGrid.Dock == DockStyle.Fill && previewGrid.Parent == settingsContent,
                            "The pack preview occupies the flexible middle row of Manage Icons");
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
                        Check(list.Items.Count == 3, "Ctrl+Backspace clears the entire filter");
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
                        Check(saveHotkey.Invoke(form, new object[] { second }) == null, "Settings apply a custom combination without restarting");
                        Preferences saved = json.Deserialize<Preferences>(File.ReadAllText(preferencesPath));
                        Check(saved.Hotkey.Key == second.Key && saved.Hotkey.Enabled && saved.Theme == themeBefore && saved.Scope == "CurrentUser" && saved.IconSize == 80, "Custom hotkey persists without changing theme, scope, or icon size");
                        using (FileStream locked = File.Open(preferencesPath, FileMode.Open, FileAccess.Read, FileShare.None)) {
                            string saveError = (string)saveHotkey.Invoke(form, new object[] { first });
                            GlobalHotkey active = (GlobalHotkey)typeof(LauncherForm).GetField("hotkey", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                            Check(saveError != null && active.Current.Key == second.Key, "A settings write failure rolls back to the previous working shortcut");
                        }
                        HotkeySettings off = second.Copy(); off.Enabled = false;
                        Check(saveHotkey.Invoke(form, new object[] { off }) == null && !json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).Hotkey.Enabled, "Disabled hotkey is saved for subsequent launches");
                        CheckDefaultAndIndividualRestore(form, root, preferencesPath, json);
                        CheckAppIconEditing(form, root, preferencesPath, json);
                        CheckLargeArtwork(form, root, preferencesPath, json);
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
            CheckLargeStartup(root, args[1]);
            CheckContextRestore(root, args[1], json);
            ShortcutScopeTests.Run(root, args[1], json, Check);
        }
        catch (Exception error) { failure = error.ToString(); Console.Error.WriteLine(failure); }
        finally { File.WriteAllText(Path.Combine(root, "results.json"), new JavaScriptSerializer().Serialize(new { Passed = failure == null, Error = failure, Checks = checks, ArtifactDirectory = root })); }
        return failure == null ? 0 : 1;
    }
}
