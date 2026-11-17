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
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out uint value, int size);
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
                // Stay outside both the centered label and the inset keyboard
                // focus rectangle, while checking all four header edges.
                for (int x = tab.Left + 1; x < tab.Right - 1; x++) foreach (int y in new[] { tab.Top + 1, tab.Bottom - 2 }) {
                    string problem = pixel(x, y, expected); if (problem != null) return "tab " + index + ": " + problem;
                }
                for (int y = tab.Top + 1; y < tab.Bottom - 1; y++) foreach (int x in new[] { tab.Left + 1, tab.Right - 2 }) {
                    string problem = pixel(x, y, expected); if (problem != null) return "tab " + index + ": " + problem;
                }
            }
        }
        return null;
    }
    static void CheckWindowBorder(LauncherForm form, Action<bool, string> check, string phase)
    {
        uint value;
        int result = DwmGetWindowAttribute(form.Handle, 34, out value, sizeof(uint));
        if (result == 0) check(value == (SystemInformation.HighContrast ? 0xFFFFFFFF : 0xFFFFFFFE), "Windows DWM uses the requested outer window border policy " + phase + " (value " + value.ToString("X8") + ")");
        else Console.WriteLine("SKIP: This Windows build does not expose DWM border-color readback " + phase + " (HRESULT " + result.ToString("X8") + ")");
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
                    form.Size = size;
                    typeof(Form).GetMethod("OnResizeEnd", instance).Invoke(form, new object[] { EventArgs.Empty });
                    for (int page = 0; page < pages.TabCount; page++) {
                        pages.SelectedIndex = page; form.PerformLayout(); pages.PerformLayout(); Application.DoEvents();
                        string problem = ChromePixels(pages, (AppearancePalette)Field(form, "appearancePalette"));
                        check(problem == null, mode + " native tab and page edges have no system outline at " + size.Width + "x" + size.Height + ", page " + page + (problem == null ? "" : ": " + problem));
                    }
                }
                typeof(Control).GetMethod("RecreateHandle", instance).Invoke(pages, null);
                Application.DoEvents();
                string recreated = ChromePixels(pages, (AppearancePalette)Field(form, "appearancePalette"));
                check(recreated == null, mode + " tab chrome remains flat after native handle recreation" + (recreated == null ? "" : ": " + recreated));
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
            grid.InputBlocked = false; grid.Focus(); grid.Items[0].Selected = grid.Items[0].Focused = true;
            SendMessage(grid.Handle, 0x0100, new IntPtr(39), IntPtr.Zero);
            SendMessage(grid.Handle, 0x007B, grid.Handle, new IntPtr(-1)); SendMessage(grid.Handle, 0x020A, new IntPtr((120 << 16) | 8), IntPtr.Zero);
            check(grid.TabStop && grid.SelectedIndices.Count == 1 && grid.SelectedIndices[0] == 1 && menus == 1 && zooms == 1,
                "Finishing a save restores native keyboard selection, context actions and zoom");
            holder.Close();
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
        foreach (string mode in new[] { "Dark", "Light" }) {
            AppearancePalette p = AppAppearance.Resolve(mode, null, false);
            check(Contrast(p.Text, p.Surface) >= 4.5 && Contrast(p.Text, p.Input) >= 4.5 && Contrast(p.Muted, p.Background) >= 4.5 && Contrast(p.SelectionText, p.Selection) >= 4.5 && Contrast(Color.White, p.Accent) >= 4.5 && Contrast(p.Error, p.Surface) >= 4.5,
                mode + " text, inputs, selected items, primary actions and errors meet normal-text contrast");
        }
        AppearancePalette high = AppAppearance.Resolve("Dark", false, true);
        check(high.HighContrast && high.Text == SystemColors.WindowText && high.Selection == SystemColors.Highlight && high.SelectionText == SystemColors.HighlightText, "Windows high contrast colors take precedence over appearance presets");
        string[] resources = typeof(AppBranding).Assembly.GetManifestResourceNames();
        check(resources.Count(name => name.StartsWith("BetterIcon.AppIcons.", StringComparison.Ordinal)) == 16 && AppBranding.Styles.All(style => new[] { "dark", "light" }.All(variant => resources.Contains(AppBranding.ResourceName(style, variant)))), "The built executable embeds all eight approved Dark and Light icon pairs");
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
        check(exactSmall, "All 16 embedded 32-pixel frames preserve the dedicated small artwork's opaque pixels exactly");

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
            check(iconChoices.Items.Cast<ToolStripItem>().Select(item => item.Text).SequenceEqual(expectedChoices) && iconChoices.Items.OfType<ToolStripMenuItem>().All(item => item.Image != null && item.DropDownItems.Count == 0), "The app-icon menu is one image-and-name list with all sixteen variants and automatic pairing");
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
            check(((AppearancePalette)Field(form, "appearancePalette")).Dark && form.BackColor == AppAppearance.Resolve("Dark").Background && ((Control)Field(form, "apps")).BackColor == AppAppearance.Resolve("Dark").Surface && ((Control)Field(form, "packPreview")).ForeColor == AppAppearance.Resolve("Dark").Text && !((ListView)Field(form, "apps")).OwnerDraw, "Dark appearance reaches the window and both grids retain native icon and label rendering");
            check(menus.All(menu => menu.BackColor == AppAppearance.Resolve("Dark").Surface && menu.Items.Cast<ToolStripItem>().All(item => item.ForeColor == AppAppearance.Resolve("Dark").Text)), "Dark appearance reaches tray, icon, import and pack action menus including rebuilt items");
            HashSet<string> signatures = new HashSet<string>();
            foreach (string style in AppBranding.Styles) foreach (string variant in new[] { "dark", "light" }) {
                chooseIcon(AppBranding.Title(style) + " " + (variant == "dark" ? "Dark" : "Light"));
                using (Icon expected = AppBranding.Load(style, variant)) using (Icon small = AppBranding.Load(style, variant, SystemInformation.SmallIconSize.Width)) using (Bitmap expectedPreview = AppBranding.Preview(style, variant, 32)) {
                    string signature = IconPixels(expected); signatures.Add(signature);
                    Preferences written = json.Deserialize<Preferences>(File.ReadAllText(preferencesPath));
                    check(IconPixels(form.Icon) == signature && IconPixels(tray.Icon) == IconPixels(small) && Pixels(iconButton.Image) == Pixels(expectedPreview) && written.AppIconStyle == style && written.AppIconVariant == (variant == "dark" ? "Dark" : "Light") && iconChoices.Items.OfType<ToolStripMenuItem>().Count(item => item.Checked) == 1,
                        "Selecting " + AppBranding.Title(style) + " " + variant + " updates the window, tray, preview and saved preference together");
                }
            }
            check(signatures.Count == 16, "Every supplied color and variant produces distinct embedded artwork");
            using (Icon small = AppBranding.Load(pref.AppIconStyle, AppBranding.Variant(pref.AppIconVariant, AppAppearance.Resolve(pref.AppearanceMode).Dark), SystemInformation.SmallIconSize.Width))
                check(tray.Icon.Size == small.Size && tray.Icon.Width <= 32, "The notification-area icon explicitly uses a small frame rather than the large window icon handle");
            chooseIcon("Sage Dark"); chooseIcon("Match app theme"); SelectMode(form, "Dark");
            using (Icon sage = AppBranding.Load("sage", "dark")) check(IconPixels(form.Icon) == IconPixels(sage), "Sage Dark is the default icon for Dark appearance");
            SelectMode(form, "Light");
            using (Icon sage = AppBranding.Load("sage", "light")) check(IconPixels(form.Icon) == IconPixels(sage) && !((AppearancePalette)Field(form, "appearancePalette")).Dark && form.BackColor == AppAppearance.Resolve("Light").Background, "Switching to Light immediately selects the matching light icon and control palette");
            chooseIcon("Sage Dark");
            using (Icon sage = AppBranding.Load("sage", "dark")) check(IconPixels(form.Icon) == IconPixels(sage) && !((AppearancePalette)Field(form, "appearancePalette")).Dark, "A pinned Dark icon stays Dark in a Light app theme");
            chooseIcon("Match app theme"); SelectMode(form, "System");
            Invoke(form, "OnSystemAppearanceChanged", null, new UserPreferenceChangedEventArgs(UserPreferenceCategory.General));
            Application.DoEvents();
            using (Icon expected = AppBranding.Load("sage", AppAppearance.SystemIsDark() ? "dark" : "light"))
                check(((AppearancePalette)Field(form, "appearancePalette")).Dark == AppAppearance.SystemIsDark() && IconPixels(form.Icon) == IconPixels(expected), "The Windows preference notification refreshes System appearance and its automatic pair");
            Preferences writtenFinal = json.Deserialize<Preferences>(File.ReadAllText(preferencesPath));
            check(json.Serialize(new { writtenFinal.Theme, writtenFinal.Scope, writtenFinal.IconSize, writtenFinal.Hotkey, writtenFinal.DefaultShortcuts }) == otherPreferences, "Appearance changes preserve all existing launcher, pack and shortcut preferences");
            iconButton.PerformClick(); Invoke(form, "SetBusy", true, null);
            check(!modeButton.Enabled && !iconButton.Enabled && !iconChoices.Visible, "Appearance controls and their open menu pause during a shortcut operation");
            Invoke(form, "SetBusy", false, null);

            CheckChrome(form, check); CheckBusyThemes(form, check); CheckGridInput(form, check);
            foreach (string mode in new[] { "Dark", "Light" }) {
                SelectMode(form, mode);
                AppearancePalette p = (AppearancePalette)Field(form, "appearancePalette");
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
