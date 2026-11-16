// Local native event tests. Launches only a disposable probe through its fixture shortcut.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using BetterIcon.Tray;

static class TrayTests
{
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
    static readonly List<object> checks = new List<object>();
    static void Check(bool ok, string name)
    {
        checks.Add(new { Test = name, Passed = ok });
        if (!ok) throw new Exception(name);
        Console.WriteLine("PASS: " + name);
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
    static void CheckDefaultAndIndividualRestore(LauncherForm form, string root, string preferencesPath, JavaScriptSerializer json)
    {
        // This runs after the existing launcher checks. Only the isolated catalog,
        // library and preferences change; no restore/apply dialog is accepted.
        BindingFlags instance = BindingFlags.Instance | BindingFlags.NonPublic;
        Func<string, object> field = name => typeof(LauncherForm).GetField(name, instance).GetValue(form);
        Action<string, object[]> call = (name, arguments) => typeof(LauncherForm).GetMethod(name, instance).Invoke(form, arguments);
        ComboBox themes = (ComboBox)field("themes"), scopes = (ComboBox)field("scopes"), picker = (ComboBox)field("restoreAppPicker");
        Button restoreApp = (Button)field("restoreApp"), apply = (Button)field("apply");
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
        scopes.SelectedIndex = 0;
        call("ReloadLibrary", new object[] { ThemeEntry.DefaultThemeId });
        Check(((ThemeEntry)themes.Items[0]).IsDefault && ((ThemeEntry)themes.Items[0]).Id == ThemeEntry.DefaultThemeId && themes.SelectedIndex == 0,
            "ArtCraft default is the first selectable pack and uses a stable identity");
        Check(json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).Theme == ThemeEntry.DefaultThemeId,
            "The ArtCraft default choice persists in preferences");
        call("ReloadLibrary", new object[] { null });
        Check(themes.SelectedIndex == 0 && ((ThemeEntry)themes.SelectedItem).IsDefault,
            "Refreshing the pack library preserves the default selection");
        Check(new[] { "Customize...", "Edit pack...", "Export ZIP...", "Remove pack" }.All(name => !menu.Items.Cast<ToolStripItem>().First(item => item.Text == name).Enabled)
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
            string previousArtwork = themedPhoto.Path, previousCurrentIcon = catalog.Apps[0].IconPath;
            int previousIndex = catalog.Apps[0].IconIndex;
            try {
                themedPhoto.Path = compressedIcon;
                catalog.Apps[0].IconPath = shellLibrary; catalog.Apps[0].IconIndex = 2;
                call("RenderApps", null); call("RenderPack", null);
                int photoPreview = packPreview.Items.Cast<ListViewItem>().ToList().FindIndex(item => item.Text == "PhotoCraft");
                Check(SamePixels(appArtwork[0], compressed) && SamePixels(packArtwork[photoPreview], compressed),
                    "Pack ICO artwork ignores the current shortcut's native resource index in both grids");
            }
            finally {
                themedPhoto.Path = previousArtwork;
                catalog.Apps[0].IconPath = previousCurrentIcon; catalog.Apps[0].IconIndex = previousIndex;
                call("RenderApps", null); call("RenderPack", null);
            }
        }

        Check(picker.Items.Cast<string>().SequenceEqual(new[] { "FilmCraft", "PhotoCraft" }),
            "Individual restore lists unique canonical app names in the chosen shortcut scope");
        try {
            picker.DroppedDown = true;
            bool dropdownOpened = picker.DroppedDown;
            KeyEventArgs escape = new KeyEventArgs(Keys.Escape);
            call("OnKeyDown", new object[] { escape });
            Check(dropdownOpened && pages.SelectedIndex == 1 && !escape.Handled,
                "Escape in the open individual restore dropdown stays in Settings and belongs to the dropdown");
        }
        finally { picker.DroppedDown = false; }
        picker.SelectedItem = "FilmCraft";
        Check(picker.Enabled && !restoreApp.Enabled, "Individual restore is disabled when the selected app has no verified backup");
        picker.SelectedItem = "PhotoCraft";
        call("UpdateRestoreApps", null);
        Check((string)picker.SelectedItem == "PhotoCraft" && restoreApp.Enabled,
            "Refreshing individual restore preserves an eligible app selection");
        scopes.SelectedIndex = 1;
        Check(picker.Items.Cast<string>().SequenceEqual(new[] { "FigCraft" }) && restoreApp.Enabled,
            "Changing shortcut scope replaces the individual restore choices and availability");
        call("SetBusy", new object[] { true, null });
        Check(!picker.Enabled && !restoreApp.Enabled, "Busy operations disable both individual restore controls");
        call("SetBusy", new object[] { false, null });
        Check(picker.Enabled && restoreApp.Enabled, "Individual restore controls recover after a busy operation");
        AppEntry[] installed = catalog.Apps;
        catalog.Apps = installed.Where(app => app.Scope == "CurrentUser").ToArray();
        call("UpdateRestoreApps", null);
        Check(picker.Items.Count == 0 && !picker.Enabled && !restoreApp.Enabled,
            "An empty shortcut scope cannot restore a stale app selection");
        catalog.Apps = installed; scopes.SelectedIndex = 0;

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
            Check(migrated.IconSize == 48 && json.Deserialize<Preferences>("{\"IconSize\":1}").IconSize == 24 && json.Deserialize<Preferences>("{\"IconSize\":999}").IconSize == 128, "Older preferences keep 48-pixel icons and invalid saved sizes are bounded safely");
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
            using (LauncherForm form = new LauncherForm(args[1], new FixtureConfig { ShortcutDirectory = new[] { root }, StateDirectory = Path.Combine(root, "state") }, true, show, stop))
            using (LauncherContext context = new LauncherContext(form))
            using (System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 50 }) {
                // Exercise the actual NotifyIcon MouseUp subscription. This is an
                // event-level check, not a claim of a physical taskbar click.
                NotifyIcon tray = (NotifyIcon)typeof(LauncherForm).GetField("tray", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                MethodInfo mouseUp = typeof(NotifyIcon).GetMethod("OnMouseUp", BindingFlags.Instance | BindingFlags.NonPublic);
                Action click = delegate { mouseUp.Invoke(tray, new object[] { new MouseEventArgs(MouseButtons.Left, 1, 0, 0, 0) }); };
                Exception eventFailure = null;
                int ticks = 0;
                timer.Tick += delegate {
                    try {
                        if (++ticks > 600) throw new Exception("Tray startup did not finish within 30 seconds.");
                        if ((bool)typeof(LauncherForm).GetField("busy", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form)) return;
                        timer.Stop();
                        Check(!form.Visible, "Tray-only startup stays hidden after the real message loop initializes");
                        click();
                        Check(form.Visible && Screen.FromPoint(Cursor.Position).WorkingArea.Contains(form.Bounds), "First tray release shows the popup on the clicked screen");
                        click(); Check(!form.Visible, "Second tray release hides the popup");
                        click(); click(); Check(!form.Visible, "Rapid double release ends hidden without reopening");
                        mouseUp.Invoke(tray, new object[] { new MouseEventArgs(MouseButtons.Right, 1, 0, 0, 0) });
                        Check(!form.Visible, "Right tray release does not toggle the popup");
                        form.ShowManager(); Check(form.Visible, "Explicit open reopens the existing popup");
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
                        Action<string> type = delegate(string value) { foreach (char c in value) character.Invoke(form, new object[] { new KeyPressEventArgs(c) }); };
                        Action<Keys> key = delegate(Keys value) { keyDown.Invoke(form, new object[] { new KeyEventArgs(value) }); };
                        TabControl pages = (TabControl)typeof(LauncherForm).GetField("pages", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        Check(pages.TabPages.Count == 2 && pages.TabPages[0].Text == "Launcher" && pages.TabPages[1].Text == "Settings", "Launcher and Settings occupy the left and right tabs");
                        Check(pages.TabPages[0].Controls.Count == 2 && !filter.Visible, "The populated Launcher page contains only the app grid");
                        TrackBar slider = (TrackBar)typeof(LauncherForm).GetField("iconSizeSlider", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        ImageList launcherImages = (ImageList)typeof(LauncherForm).GetField("pictures", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        List<Bitmap> cached = (List<Bitmap>)typeof(LauncherForm).GetField("appArtwork", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        ListView previewGrid = (ListView)typeof(LauncherForm).GetField("packPreview", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        ImageList previewImages = (ImageList)typeof(LauncherForm).GetField("packPictures", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        List<Bitmap> previewCached = (List<Bitmap>)typeof(LauncherForm).GetField("packArtwork", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        Check(slider.Value == 72 && launcherImages.ImageSize == new Size(72, 72) && previewImages.ImageSize == launcherImages.ImageSize, "Hidden startup restores the same saved icon size in both grids and the Settings slider");
                        Rectangle firstIcon = list.GetItemRect(0, ItemBoundsPortion.Icon), firstLabel = list.GetItemRect(0, ItemBoundsPortion.Label);
                        Check(list.View == View.LargeIcon && firstLabel.Top >= firstIcon.Bottom && list.Items[1].Bounds.Left > list.Items[0].Bounds.Left && list.Items[1].Bounds.Top == list.Items[0].Bounds.Top, "Native launcher lays out a compact row of icons with names underneath");
                        pages.Focus();
                        type("f");
                        Check(list.Items.Count == 2 && list.ContainsFocus && list.SelectedItems.Count == 1, "Typing from the launcher tab filters and focuses the highlighted result");
                        int artworkCount = ((ImageList)typeof(LauncherForm).GetField("pictures", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form)).Images.Count;
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
                        Check(((ImageList)typeof(LauncherForm).GetField("pictures", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form)).Images.Count == artworkCount, "Typing reuses the loaded artwork instead of rebuilding image lists");
                        form.Hide(); form.ShowManager();
                        Check(list.Items.Count == 3 && !filter.Visible, "Reopening starts with all apps and no stale filter");
                        pages.SelectedIndex = 1; type("fil");
                        Check(list.Items.Count == 3 && pages.SelectedIndex == 1, "Settings keyboard input does not filter the launcher");
                        Bitmap[] sources = cached.ToArray(), previewSources = previewCached.ToArray();
                        previewGrid.Items[1].Selected = true;
                        foreach (int size in new[] { 24, 128, 32, 96 }) slider.Value = size;
                        Check(launcherImages.ImageSize == new Size(96, 96) && launcherImages.Images.Count == 3 && cached.SequenceEqual(sources) && list.GetItemRect(0, ItemBoundsPortion.Label).Top >= list.GetItemRect(0, ItemBoundsPortion.Icon).Bottom, "Resizing through the full range retains valid cached launcher artwork and labels below icons");
                        Check(previewImages.ImageSize == launcherImages.ImageSize && previewImages.Images.Count == previewGrid.Items.Count && previewCached.SequenceEqual(previewSources) && previewGrid.SelectedItems.Count == 1 && previewGrid.SelectedItems[0].Index == 1 && previewGrid.GetItemRect(0, ItemBoundsPortion.Label).Top >= previewGrid.GetItemRect(0, ItemBoundsPortion.Icon).Bottom, "The Settings preview resizes immediately from cached artwork while retaining its selection and labels below icons");
                        pages.SelectedIndex = 0; type("f"); list.Items[0].Selected = false; list.Items[1].Selected = true;
                        pages.SelectedIndex = 1; slider.Value = 64;
                        Check(list.Items.Count == 2 && list.AccessibleDescription.Contains("Filter: f.") && list.SelectedItems.Count == 1 && list.SelectedItems[0].Text == "FilmCraft", "Icon resizing preserves the active filter and selected app");
                        Preferences sized = json.Deserialize<Preferences>(File.ReadAllText(preferencesPath));
                        Check(sized.IconSize == 64 && sized.Theme == "Craft-Icons-Zach/Satin" && sized.Scope == "CurrentUser" && !sized.Hotkey.Enabled, "Icon size persists without changing theme, scope, or hotkey preferences");
                        ((Button)typeof(LauncherForm).GetField("resetIconSize", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form)).PerformClick();
                        Check(launcherImages.ImageSize == new Size(48, 48) && previewImages.ImageSize == launcherImages.ImageSize && list.Items[1].Bounds.Left - list.Items[0].Bounds.Left < 200 && json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).IconSize == 48, "Reset restores and saves compact 48-pixel icons in both grids");
                        pages.SelectedIndex = 0;
                        Action<int, bool> wheel = delegate(int delta, bool control) { SendMessage(list.Handle, 0x020A, new IntPtr((delta << 16) | (control ? 8 : 0)), IntPtr.Zero); };
                        wheel(120, true);
                        Check(slider.Value == 56 && launcherImages.ImageSize == new Size(56, 56) && previewImages.ImageSize == launcherImages.ImageSize && json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).IconSize == 56 && list.SelectedItems[0].Text == "FilmCraft" && list.AccessibleDescription.Contains("Filter: f."), "Native Ctrl+wheel enlarges both grids, updates the slider, saves the size, and retains filter/selection");
                        wheel(-240, true); wheel(60, true);
                        Check(slider.Value == 40, "Ctrl+wheel zooms out and waits for a complete fine-resolution wheel step");
                        wheel(60, true); wheel(120, false);
                        Check(slider.Value == 48, "Partial Ctrl+wheel steps accumulate while ordinary scrolling leaves size unchanged");
                        wheel(2400, true); bool reachedMaximum = slider.Value == 128;
                        wheel(-2400, true); bool reachedMinimum = slider.Value == 24;
                        typeof(LauncherForm).GetMethod("SetBusy", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(form, new object[] { true, null });
                        wheel(120, true);
                        Check(reachedMaximum && reachedMinimum && slider.Value == 24, "Ctrl+wheel respects size bounds and cannot resize during a busy operation");
                        typeof(LauncherForm).GetMethod("SetBusy", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(form, new object[] { false, null });
                        pages.SelectedIndex = 0; key(Keys.Control | Keys.Back); pages.SelectedIndex = 1; slider.Value = 80;
                        ComboBox themePicker = (ComboBox)typeof(LauncherForm).GetField("themes", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        Panel settingsScroll = (Panel)typeof(LauncherForm).GetField("settingsScroll", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        TableLayoutPanel settingsContent = (TableLayoutPanel)typeof(LauncherForm).GetField("settingsContent", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        Check(new[] { "IconPackSection", "LauncherSection", "ShortcutsSection" }.All(name => settingsContent.Controls.Find(name, true).Length == 1), "Settings groups pack management, launcher preferences, and Windows shortcuts into separate sections");
                        Size previousSize = form.Size; int previousIconSize = slider.Value;
                        try {
                            foreach (Size windowSize in new[] { new Size(790, 570), new Size(900, 690) }) foreach (int iconSize in new[] { 24, 128 }) {
                                form.Size = windowSize; slider.Value = iconSize; settingsScroll.AutoScrollPosition = Point.Empty;
                                form.PerformLayout(); settingsContent.PerformLayout(); Application.DoEvents();
                                string layoutProblem = SettingsLayoutProblem(settingsContent);
                                Check(layoutProblem == null && settingsContent.Width <= settingsScroll.ClientSize.Width && !settingsScroll.HorizontalScroll.Visible,
                                    "Settings controls remain separated and fit horizontally at " + windowSize.Width + "x" + windowSize.Height + ", " + iconSize + "-pixel icons" + (layoutProblem == null ? "" : ": " + layoutProblem));
                            }
                        }
                        finally { form.Size = previousSize; slider.Value = previousIconSize; settingsScroll.AutoScrollPosition = Point.Empty; form.PerformLayout(); }
                        ContextMenuStrip importMenu = (ContextMenuStrip)typeof(LauncherForm).GetField("importPackMenu", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        ContextMenuStrip manageMenu = (ContextMenuStrip)typeof(LauncherForm).GetField("managePackMenu", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        ToolStripItem[] manageItems = manageMenu.Items.Cast<ToolStripItem>().ToArray();
                        Check(new[] { "Edit pack...", "Export ZIP..." }.All(text => manageItems.Single(item => item.Text == text).Enabled == false) && manageItems.Single(item => item.Text == "Customize...").Enabled,
                            "Built-in packs offer Customize while personal-only Edit and Export actions stay disabled");
                        pages.SelectedIndex = 0;
                        PropertyInfo canFilter = typeof(LauncherForm).GetProperty("CanFilter", BindingFlags.Instance | BindingFlags.NonPublic);
                        foreach (ContextMenuStrip menu in new[] { importMenu, manageMenu }) {
                            try {
                                menu.Show(list, new Point(8, 8));
                                bool filteringBlocked = !(bool)canFilter.GetValue(form, null);
                                type("zzz");
                                Check(menu.Visible && filteringBlocked && list.Items.Count == 3, (menu == importMenu ? "Import" : "Pack actions") + " menu keeps keyboard input out of launcher filtering");
                            }
                            finally { menu.Close(); }
                        }
                        pages.SelectedIndex = 1;
                        themePicker.DroppedDown = true;
                        KeyPressEventArgs dropdownKey = new KeyPressEventArgs('p'); character.Invoke(form, new object[] { dropdownKey });
                        Check(!dropdownKey.Handled && list.Items.Count == 3, "An open theme dropdown keeps its own typing behavior");
                        themePicker.DroppedDown = false;
                        key(Keys.Escape); Check(pages.SelectedIndex == 0 && form.Visible, "Escape from Settings returns to the launcher");
                        form.Enabled = false; type("p"); form.Enabled = true;
                        Check(list.Items.Count == 3, "Modal dialog input cannot alter the app filter");
                        type("pho"); key(Keys.Control | Keys.Back);
                        Check(list.Items.Count == 3, "Ctrl+Backspace clears the entire filter");
                        key(Keys.Escape); Check(!form.Visible, "Escape with no filter closes the popup");
                        form.ShowManager();
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
                        stop.Set(); // Exercise normal shutdown through the same message loop.
                    }
                    catch (Exception error) { eventFailure = error; timer.Stop(); context.ExitThread(); }
                };
                timer.Start(); Application.Run(context);
                if (eventFailure != null) throw eventFailure;
            }
        }
        catch (Exception error) { failure = error.ToString(); Console.Error.WriteLine(failure); }
        finally { File.WriteAllText(Path.Combine(root, "results.json"), new JavaScriptSerializer().Serialize(new { Passed = failure == null, Error = failure, Checks = checks, ArtifactDirectory = root })); }
        return failure == null ? 0 : 1;
    }
}
