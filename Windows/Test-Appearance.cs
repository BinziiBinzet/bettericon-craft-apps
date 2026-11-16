// Local native appearance tests. All writes stay in the existing disposable fixture.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;
using BetterIcon.Tray;

static class AppearanceTests
{
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
        ComboBox modePicker = (ComboBox)Field(form, "appearanceModePicker"), stylePicker = (ComboBox)Field(form, "appIconStylePicker"), variantPicker = (ComboBox)Field(form, "appIconVariantPicker");
        NotifyIcon tray = (NotifyIcon)Field(form, "tray");
        PictureBox preview = (PictureBox)Field(form, "appIconPreview");
        TabControl pages = (TabControl)Field(form, "pages");
        ContextMenuStrip[] menus = new[] { "trayMenu", "iconMenu", "importPackMenu", "managePackMenu" }.Select(name => (ContextMenuStrip)Field(form, name)).ToArray();
        try {
            form.ShowManager(); pages.SelectedIndex = 1;
            check(modePicker.Items.Cast<string>().SequenceEqual(new[] { "System", "Dark", "Light" }) && stylePicker.Items.Count == 8 && variantPicker.Items.Count == 3, "Settings exposes appearance mode, eight colors and automatic or explicit icon variants");
            modePicker.SelectedItem = "Dark";
            variantPicker.SelectedIndex = 0;
            check(((AppearancePalette)Field(form, "appearancePalette")).Dark && form.BackColor == AppAppearance.Resolve("Dark").Background && ((Control)Field(form, "apps")).BackColor == AppAppearance.Resolve("Dark").Surface && ((Control)Field(form, "packPreview")).ForeColor == AppAppearance.Resolve("Dark").Text && !((ListView)Field(form, "apps")).OwnerDraw, "Dark appearance reaches the window and both grids retain native icon and label rendering");
            check(menus.All(menu => menu.BackColor == AppAppearance.Resolve("Dark").Surface && menu.Items.Cast<ToolStripItem>().All(item => item.ForeColor == AppAppearance.Resolve("Dark").Text)), "Dark appearance reaches tray, icon, import and pack action menus including rebuilt items");
            HashSet<string> signatures = new HashSet<string>();
            foreach (string style in AppBranding.Styles) foreach (string variant in new[] { "dark", "light" }) {
                stylePicker.SelectedIndex = Array.IndexOf(AppBranding.Styles, style); variantPicker.SelectedIndex = variant == "dark" ? 1 : 2;
                using (Icon expected = AppBranding.Load(style, variant)) using (Icon small = AppBranding.Load(style, variant, SystemInformation.SmallIconSize.Width)) using (Bitmap expectedPreview = AppBranding.Preview(style, variant, 48)) {
                    string signature = IconPixels(expected); signatures.Add(signature);
                    Preferences written = json.Deserialize<Preferences>(File.ReadAllText(preferencesPath));
                    check(IconPixels(form.Icon) == signature && IconPixels(tray.Icon) == IconPixels(small) && Pixels(preview.Image) == Pixels(expectedPreview) && written.AppIconStyle == style && written.AppIconVariant == (variant == "dark" ? "Dark" : "Light"),
                        "Selecting " + AppBranding.Title(style) + " " + variant + " updates the window, tray, preview and saved preference together");
                }
            }
            check(signatures.Count == 16, "Every supplied color and variant produces distinct embedded artwork");
            using (Icon small = AppBranding.Load(pref.AppIconStyle, AppBranding.Variant(pref.AppIconVariant, AppAppearance.Resolve(pref.AppearanceMode).Dark), SystemInformation.SmallIconSize.Width))
                check(tray.Icon.Size == small.Size && tray.Icon.Width <= 32, "The notification-area icon explicitly uses a small frame rather than the large window icon handle");
            stylePicker.SelectedIndex = Array.IndexOf(AppBranding.Styles, "sage"); variantPicker.SelectedIndex = 0; modePicker.SelectedItem = "Dark";
            using (Icon sage = AppBranding.Load("sage", "dark")) check(IconPixels(form.Icon) == IconPixels(sage), "Sage Dark is the default icon for Dark appearance");
            modePicker.SelectedItem = "Light";
            using (Icon sage = AppBranding.Load("sage", "light")) check(IconPixels(form.Icon) == IconPixels(sage) && !((AppearancePalette)Field(form, "appearancePalette")).Dark && modePicker.BackColor == AppAppearance.Resolve("Light").Input, "Switching to Light immediately selects the matching light icon and control palette");
            variantPicker.SelectedIndex = 1;
            using (Icon sage = AppBranding.Load("sage", "dark")) check(IconPixels(form.Icon) == IconPixels(sage) && !((AppearancePalette)Field(form, "appearancePalette")).Dark, "A pinned Dark icon stays Dark in a Light app theme");
            variantPicker.SelectedIndex = 0; modePicker.SelectedItem = "System";
            Invoke(form, "OnSystemAppearanceChanged", null, new UserPreferenceChangedEventArgs(UserPreferenceCategory.General));
            Application.DoEvents();
            check(((AppearancePalette)Field(form, "appearancePalette")).Dark == AppAppearance.SystemIsDark() && (string)stylePicker.Tag == (AppAppearance.SystemIsDark() ? "dark" : "light"), "The Windows preference notification refreshes System appearance and its automatic pair");
            Preferences writtenFinal = json.Deserialize<Preferences>(File.ReadAllText(preferencesPath));
            check(json.Serialize(new { writtenFinal.Theme, writtenFinal.Scope, writtenFinal.IconSize, writtenFinal.Hotkey, writtenFinal.DefaultShortcuts }) == otherPreferences, "Appearance changes preserve all existing launcher, pack and shortcut preferences");
            Invoke(form, "SetBusy", true, null);
            check(!modePicker.Enabled && !stylePicker.Enabled && !variantPicker.Enabled, "Appearance controls cannot change during a shortcut operation");
            Invoke(form, "SetBusy", false, null);

            foreach (string mode in new[] { "Dark", "Light" }) {
                modePicker.SelectedItem = mode;
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
            modePicker.SelectedItem = savedMode; stylePicker.SelectedIndex = Array.IndexOf(AppBranding.Styles, savedStyle); variantPicker.SelectedIndex = savedVariant == "Dark" ? 1 : savedVariant == "Light" ? 2 : 0;
            // Preserve the explicit automated-test identity after cycling branding.
            tray.Icon = SystemIcons.Information; tray.Text = "BetterIcon automated tests";
        }
    }
    static IEnumerable<Control> Descendants(Control parent) { yield return parent; foreach (Control child in parent.Controls) foreach (Control nested in Descendants(child)) yield return nested; }
}
