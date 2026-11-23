using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using BetterIcon.Tray;

static partial class PackEditionTests
{
    const BindingFlags Fields = BindingFlags.Instance | BindingFlags.NonPublic;
    static T Field<T>(object obj, string name) { return (T)obj.GetType().GetField(name, Fields).GetValue(obj); }
    static void Check(bool ok, string label) { if (!ok) throw new Exception(label); Console.WriteLine("PASS " + label); }
    static void Wait(Func<bool> ready)
    {
        var elapsed = Stopwatch.StartNew();
        do {
            Application.DoEvents();
            if (ready()) return;
            if (elapsed.Elapsed.TotalMinutes > 3) throw new TimeoutException("Window did not finish loading the pack.");
            Thread.Sleep(8);
        } while (true);
    }
    static void Offline()
    {
        // Only this test process and its own workers inherit these settings.
        Environment.SetEnvironmentVariable("HTTPS_PROXY", "http://127.0.0.1:9");
        Environment.SetEnvironmentVariable("ALL_PROXY", "http://127.0.0.1:9");
        Environment.SetEnvironmentVariable("NO_PROXY", null);
    }
    static ThemeEntry Find(ComboBox combo, string id) { return combo.Items.OfType<ThemeEntry>().Single(t => t.Id == id); }
    static int Cached(string cache) { return Directory.Exists(cache) ? Directory.GetFiles(cache, ".complete", SearchOption.AllDirectories).Length : 0; }
    // The start reads the catalog and then downloads a chosen pack that is not on the computer.
    static void WaitStarted(LauncherForm form)
    {
        Wait(() => !Field<bool>(form, "busy") && Field<Catalog>(form, "catalog") != null);
        Application.DoEvents();
        Wait(() => !Field<bool>(form, "busy"));
    }
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct Info { public int Size; public Rect Item, Button; public int State; public IntPtr Combo, Edit, List; }
    [DllImport("user32.dll")] static extern bool GetComboBoxInfo(IntPtr hwnd, ref Info info);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll", EntryPoint = "SendMessageW")] static extern IntPtr GetRect(IntPtr hwnd, int msg, IntPtr w, ref Rect r);
    static IntPtr OpenRows(ComboBox combo)
    {
        combo.Focus(); combo.DroppedDown = true;
        var info = new Info { Size = Marshal.SizeOf(typeof(Info)) };
        if (!GetComboBoxInfo(combo.Handle, ref info) || info.List == IntPtr.Zero) throw new Exception("No native list");
        return info.List;
    }
    static IntPtr RowPoint(IntPtr list, int index)
    {
        SendMessage(list, 0x0197, (IntPtr)index, IntPtr.Zero); // LB_SETTOPINDEX
        var rect = new Rect();
        if (GetRect(list, 0x0198, (IntPtr)index, ref rect).ToInt64() == -1) throw new Exception("No native row");
        return (IntPtr)(((rect.Top + rect.Bottom) / 2 << 16) | (rect.Left + 8));
    }
    static void Browse(ComboBox combo, ThemeEntry target, string cache)
    {
        var active = combo.SelectedItem;
        int before = Cached(cache);
        var list = OpenRows(combo);
        foreach (var pack in combo.Items.OfType<ThemeEntry>().Where(t => t.NeedsDownload)) {
            var point = RowPoint(list, combo.Items.IndexOf(pack));
            SendMessage(list, 0x0200, IntPtr.Zero, point); // hover
            SendMessage(combo.Handle, 0x0100, (IntPtr)Keys.Down, IntPtr.Zero);
        }
        combo.DroppedDown = false; combo.SelectedItem = target; Application.DoEvents();
        Check(Object.Equals(active, combo.SelectedItem) && target.NeedsDownload && Cached(cache) == before,
            "Opening, hovering, arrowing across the list, canceling and programmatic selection never download a pack");
    }
    static string MenuLabel(LauncherForm form, ThemeEntry pack)
    {
        var menu = Field<ContextMenuStrip>(form, "trayMenu").Items.OfType<ToolStripMenuItem>().Single(i => i.Text == "Change icon theme");
        return menu.DropDownItems.Cast<ToolStripMenuItem>().Single(i => i.Text.StartsWith(pack.DisplayName + " (")).Text;
    }
    static void SelectPack(Form form, string id, bool file, bool download, bool fails)
    {
        var combo = Field<ComboBox>(form, file ? "fileThemes" : "themes");
        var label = Field<Label>(form, "loadingMessage");
        var bar = Field<ProgressBar>(form, "loadingProgress");
        var target = Find(combo, id);
        var changes = new List<string>();
        EventHandler changed = delegate { changes.Add(label.Text); };
        label.TextChanged += changed;
        try {
            IntPtr listWindow = OpenRows(combo);
            int index = combo.Items.IndexOf(target);
            IntPtr point = RowPoint(listWindow, index);
            if (file && target.Name == "Standard") {
                SendMessage(listWindow, 0x0186, (IntPtr)index, IntPtr.Zero); // LB_SETCURSEL
                SendMessage(combo.Handle, 0x0100, (IntPtr)Keys.Enter, IntPtr.Zero);
            } else {
                SendMessage(listWindow, 0x0201, (IntPtr)1, point);
                SendMessage(listWindow, 0x0202, IntPtr.Zero, point);
            }
            string name = target.DisplayName + "...";
            string first = (download ? "Downloading " : "Loading ") + name;
            Check(changes.FirstOrDefault() == first && bar.Visible && bar.MarqueeAnimationSpeed > 0 && bar.AccessibleName == first,
                (file ? "File" : "App") + " picker immediately shows " + first);
            // A failed download reports once in a dialog. Close it so the load can finish.
            bool reported = false;
            using (var dismiss = new System.Windows.Forms.Timer { Interval = 20 }) {
                dismiss.Tick += delegate {
                    foreach (Form dialog in form.OwnedForms) if (dialog.Visible && dialog.Text == "BetterIcon") { reported = true; dialog.DialogResult = DialogResult.OK; dialog.Close(); }
                };
                dismiss.Start();
                var work = Field<System.Threading.Tasks.Task>(form, "packLoadTask");
                Wait(() => work.IsCompleted);
                work.GetAwaiter().GetResult();
            }
            var expected = download && !fails ? new[] { first, "Loading " + name } : new[] { first };
            Check(changes.SequenceEqual(expected) && !bar.Visible && bar.MarqueeAnimationSpeed == 0,
                "Bottom bar shows the actual phases in order and stops: " + String.Join(" then ", changes) +
                " (visible=" + bar.Visible + ", speed=" + bar.MarqueeAnimationSpeed + ")");
            if (fails) {
                Check(reported && combo.SelectedItem != target && Field<Label>(form, "status").Text.Length > 0 && target.ToString().EndsWith(" (Download)"), "Failed fetch returns to the previous pack and keeps the Download label");
            } else {
                var list = Field<ListView>(form, file ? "filePreview" : "packPreview");
                Check(!reported && list.Items.Count > 0 && !target.NeedsDownload, "The selected artwork is ready");
            }
        } finally { label.TextChanged -= changed; }
    }
    [STAThread]
    static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        Control.CheckForIllegalCrossThreadCalls = true;
        int result = 0;
        using (var context = new ApplicationContext()) {
            EventHandler run = null;
            run = delegate {
                Application.Idle -= run;
                try { Run(args); } catch (Exception error) { Console.Error.WriteLine(error); result = 1; }
                finally { context.ExitThread(); }
            };
            Application.Idle += run; Application.Run(context);
        }
        return result;
    }
    static void Run(string[] args)
    {
        var state = Path.Combine(args[1], "state");
        Directory.CreateDirectory(state);
        var prefs = Path.Combine(state, "tray-preferences.json");
        var json = new JavaScriptSerializer();
        const string flat = "Craft-Icons-VimiummuimiV/Modern Flat";
        File.WriteAllText(prefs, json.Serialize(new Preferences { Theme = flat + " - Bolt - Knob", FileTheme = flat + " - Spark - Sliders", Hotkey = new HotkeySettings { Enabled = false } }));
        var fixture = new FixtureConfig { StateDirectory = state, ShortcutDirectory = new[] { args[1] }, KeepOpenForAutomation = true };
        bool lean = File.Exists(Path.Combine(args[0], "OnDemand.tsv"));
        if (args.Length > 2 && args[2] == "refresh") {
            // These checks are about pack metadata. Without a chosen app pack nothing is downloaded at the start.
            File.WriteAllText(prefs, json.Serialize(new Preferences { FileTheme = flat + " - Spark - Sliders", Hotkey = new HotkeySettings { Enabled = false } }));
            CheckRefresh(args[0], state, fixture); return;
        }
        CheckCurrentPackUpdate();
        if (lean) { CheckChosenPacksKept(args[0], args[1]); CheckChosenPackNotApplied(args[0], args[1]); CheckGainedFileArtwork(args[0], args[1]); }
        if (!lean) Offline();
        // second draws documents only. mixed carries app icons and file type artwork.
        const string first = "Craft-Icons-circleb/Root", second = "Craft-Icons-Komplett/Standard", third = "Craft-Icons-Zach/Ink", mixed = "Craft-Icons-Mike22/CraftApps AIO November - Dark";
        using (var show = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (var stop = new EventWaitHandle(false, EventResetMode.AutoReset)) {
            for (int pass = 0; pass < 2; pass++) using (var form = new LauncherForm(args[0], fixture, true, show, stop)) {
                form.Start();
                form.ShowManager();
                WaitStarted(form);
                Field<TabControl>(form, "pages").SelectedIndex = 1;
                var combo = Field<ComboBox>(form, "themes");
                var fileCombo = Field<ComboBox>(form, "fileThemes");
                if (pass == 1) {
                    HoverPack(combo, Find(combo, third), state, args[0], lean);
                    Check(((ThemeEntry)combo.SelectedItem).Id == first && fileCombo.SelectedItem == Find(fileCombo, second) && !Find(combo, mixed).NeedsDownload, "Restart offline remembers the app pack and the downloaded file pack");
                    SelectPack(form, mixed, false, false, false);
                    Check(json.Deserialize<Preferences>(File.ReadAllText(prefs)).FileTheme == second, "App pack switches preserve the file pack preference");
                    typeof(LauncherForm).GetMethod("ExitLauncher", Fields).Invoke(form, null);
                    continue;
                }
                var packs = combo.Items.OfType<ThemeEntry>().Where(t => !t.IsDefault).ToArray();
                // The saved choice is an earlier name of Modern Flat. The download edition fetches that one pack again.
                Check(packs.Length == 27 && packs.Sum(t => t.IconCount) == 382 && packs.All(t => t.NeedsDownload == (lean && t.Id != flat)), "First launch lists all 27 app packs and 382 icons with the correct availability");
                ThemeEntry[] incomplete = packs.Where(t => !t.NeedsDownload && t.Icons.Length != t.IconCount).ToArray();
                Check(incomplete.Length == 0, "Every pack already on this computer holds an icon for each app it lists" + (incomplete.Length == 0 ? "" : ": " + String.Join(", ", incomplete.Select(t => t.Id + " " + t.Icons.Length + "/" + t.IconCount))));
                var filePacks = fileCombo.Items.OfType<ThemeEntry>().ToArray();
                // Komplett's five and Mike22's three packs (14 file icons each), and OmegaDarling's nine file type packs (37 each).
                Check(fileCombo.SelectedIndex == 0 && filePacks.Length == 17 && filePacks.Sum(t => t.FileIconCount) == 445 && filePacks.All(t => t.HasFileIcons && t.NeedsDownload == lean) && !packs.Any(t => t.Pack == "Craft-Icons-Komplett")
                    && filePacks.All(t => t.ToString().EndsWith(lean ? " (Download)" : " (Included)")),
                    "First launch lists the seventeen file type packs separately, starting from the original file icons" +
                    (filePacks.Length == 17 ? "" : ": " + filePacks.Length + " packs, " + filePacks.Sum(t => t.FileIconCount) + " file icons"));
                Check(packs.Single(t => t.Author == "VimiummuimiV").Id == flat && Find(combo, flat).IconCount == 13, "Modern Flat has one entry with all 13 app icons");
                var restored = json.Deserialize<Preferences>(File.ReadAllText(prefs));
                Check(((ThemeEntry)combo.SelectedItem).Id == flat && restored.Theme == flat && restored.FileTheme == flat && Field<string>(form, "wantedThemeId") == null,
                    "Saved variant selections resolve to Modern Flat, and the chosen app pack is shown again");
                var cache = Path.Combine(state, "downloads");
                int chosen = lean ? 1 : 0;
                Check(Cached(cache) == chosen, "Listing the catalog downloads nothing but the pack that was chosen before");
                Check(packs.All(t => t.ToString().EndsWith(!lean ? " (Included)" : t.Id == flat ? " (Downloaded)" : " (Download)") && MenuLabel(form, t) == t.ToString()), "Picker and tray labels identify each pack's availability at installation");
                if (lean) Browse(combo, Find(combo, third), cache);
                Check(!Directory.Exists(Path.Combine(state, "pack-previews")), "Opening and quickly browsing the catalog fetched no previews");
                HoverPack(combo, Find(combo, third), state, args[0], lean, true);
                HoverPack(combo, Find(combo, flat), state, args[0], lean);
                HoverRaces(form, Find(combo, third), Find(fileCombo, second), state, args[0], lean);
                PersonalHover(form, state);
                TrayHover(form, Find(combo, third));
                Check(Cached(cache) == chosen, "Hover previews download no pack");
                SelectPack(form, first, false, lean, false);
                Check(MenuLabel(form, Find(combo, first)).EndsWith(lean ? " (Downloaded)" : " (Included)"), "The clicked pack has the correct local status in the tray");
                string fileStrip = HoverPack(fileCombo, Find(fileCombo, mixed), state, args[0], lean, false, mixed + "/FileTypes");
                Check(fileStrip != null && fileStrip != HoverPack(combo, Find(combo, mixed), state, args[0], lean),
                    "The file type list previews a pack's file artwork, not its app icons");
                SelectPack(form, mixed, true, lean, false);
                Check(MenuLabel(form, Find(combo, mixed)).EndsWith(lean ? " (Downloaded)" : " (Included)") && !Find(combo, mixed).NeedsDownload, "Choosing a file pack updates its availability in the other menus");
                SelectPack(form, second, true, lean, false);
                Check(Find(fileCombo, second).ToString().EndsWith(lean ? " (Downloaded)" : " (Included)"), "A document pack shows its own availability once chosen");
                Offline();
                SelectPack(form, mixed, true, false, false);
                if (lean) SelectPack(form, "Craft-Icons-Komplett/Dunkel", true, true, true);
                SelectPack(form, second, true, false, false);
                Check(Field<ListView>(form, "filePreview").Items.Cast<ListViewItem>().Any(row => row.Text == "PhotoCraft") && Field<ListView>(form, "filePreview").Visible, "File picker previews PhotoCraft document artwork");
                var saved = json.Deserialize<Preferences>(File.ReadAllText(prefs));
                Check(saved.Theme == first && saved.FileTheme == second, "Successful app and file choices are persisted independently");
                if (lean) {
                    Check(Cached(cache) == 4 &&
                          Directory.GetDirectories(cache, ".loading-*", SearchOption.AllDirectories).Length == 0,
                          "Only chosen packs were cached and a failed download published no partial files");
                } else Check(!Directory.Exists(cache), "The bundled edition loads both pack types entirely offline");
                typeof(LauncherForm).GetMethod("ExitLauncher", Fields).Invoke(form, null);
            }
        }
    }
    // A build that carried every pack kept them beside the app. After an upgrade a chosen pack is saved but not on the computer.
    static void CheckChosenPacksKept(string windows, string root)
    {
        const string app = "Craft-Icons-Zach/Ink", file = "Craft-Icons-Komplett/Dunkel";
        string state = Path.Combine(root, "chosen-state"), prefs = Path.Combine(state, "tray-preferences.json"), cache = Path.Combine(state, "downloads");
        Directory.CreateDirectory(state);
        var json = new JavaScriptSerializer();
        File.WriteAllText(prefs, json.Serialize(new Preferences { Theme = app, FileTheme = file, Hotkey = new HotkeySettings { Enabled = false } }));
        var fixture = new FixtureConfig { StateDirectory = state, ShortcutDirectory = new[] { root }, KeepOpenForAutomation = true };
        string[] proxyNames = { "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY" };
        var proxies = proxyNames.ToDictionary(name => name, Environment.GetEnvironmentVariable);
        using (var show = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (var stop = new EventWaitHandle(false, EventResetMode.AutoReset)) {
            try {
                Offline();
                using (var form = new LauncherForm(windows, fixture, true, show, stop)) {
                    form.Start();
                    WaitStarted(form);
                    var saved = json.Deserialize<Preferences>(File.ReadAllText(prefs));
                    Check(((ThemeEntry)Field<ComboBox>(form, "themes").SelectedItem).IsDefault && Field<ComboBox>(form, "fileThemes").SelectedIndex == 0 &&
                          saved.Theme == app && saved.FileTheme == file && Cached(cache) == 0,
                          "A chosen pack that cannot be downloaded stays the saved choice");
                    Check(!form.Visible && !form.OwnedForms.Any(dialog => dialog.Visible) && Field<Label>(form, "status").Text.Contains("try again"),
                          "The failed download is noted in the status line without opening the window or a dialog");
                    typeof(LauncherForm).GetMethod("ExitLauncher", Fields).Invoke(form, null);
                }
            } finally {
                foreach (var proxy in proxies) Environment.SetEnvironmentVariable(proxy.Key, proxy.Value);
            }
            using (var form = new LauncherForm(windows, fixture, true, show, stop)) {
                form.Start();
                WaitStarted(form);
                var combo = Field<ComboBox>(form, "themes");
                var fileCombo = Field<ComboBox>(form, "fileThemes");
                var saved = json.Deserialize<Preferences>(File.ReadAllText(prefs));
                Check(((ThemeEntry)combo.SelectedItem).Id == app && fileCombo.SelectedItem == Find(fileCombo, file) && saved.Theme == app && saved.FileTheme == file,
                      "The next start downloads the chosen packs again and shows them in both lists");
                Check(Cached(cache) == 2 && !Find(combo, app).NeedsDownload && !Find(fileCombo, file).NeedsDownload && !form.Visible &&
                      Field<ListView>(form, "packPreview").Items.Count > 0 && Field<ListView>(form, "filePreview").Items.Count > 0,
                      "Only the two chosen packs were downloaded, and their artwork is ready");
                typeof(LauncherForm).GetMethod("ExitLauncher", Fields).Invoke(form, null);
            }
        }
    }
    // A new installation has applied nothing. A pack that is only chosen never becomes the Launcher's pack at the next start.
    static void CheckChosenPackNotApplied(string windows, string root)
    {
        const string pack = "Craft-Icons-Zach/Ink";
        string state = Path.Combine(root, "browsed-state"), prefs = Path.Combine(state, "tray-preferences.json");
        Directory.CreateDirectory(state);
        var json = new JavaScriptSerializer();
        File.WriteAllText(prefs, json.Serialize(new Preferences { Hotkey = new HotkeySettings { Enabled = false } }));
        var fixture = new FixtureConfig { StateDirectory = state, ShortcutDirectory = new[] { root }, KeepOpenForAutomation = true };
        var applied = typeof(LauncherForm).GetMethod("AppliedTheme", Fields);
        using (var show = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (var stop = new EventWaitHandle(false, EventResetMode.AutoReset))
        for (int pass = 0; pass < 2; pass++) using (var form = new LauncherForm(windows, fixture, true, show, stop)) {
            form.Start();
            form.ShowManager();
            WaitStarted(form);
            Field<TabControl>(form, "pages").SelectedIndex = 1;
            if (pass == 0) SelectPack(form, pack, false, true, false);
            var saved = json.Deserialize<Preferences>(File.ReadAllText(prefs));
            Check(saved.Theme == pack && saved.AppliedTheme == "" && applied.Invoke(form, null) == null &&
                  ((ThemeEntry)Field<ComboBox>(form, "themes").SelectedItem).Id == pack,
                  pass == 0 ? "Choosing a pack on a new installation applies nothing"
                            : "After a restart the Launcher still shows no pack that was only chosen");
            typeof(LauncherForm).GetMethod("ExitLauncher", Fields).Invoke(form, null);
        }
    }
    // A pack that was downloaded before it gained file artwork is still offered as a file type pack.
    static void CheckGainedFileArtwork(string windows, string root)
    {
        const string pack = "Craft-Icons-Mike22/CraftApps AIO November - Dark";
        string older = Path.Combine(root, "older", "Windows"), state = Path.Combine(root, "gained-state");
        Directory.CreateDirectory(state);
        Directory.CreateDirectory(older);
        foreach (string folder in Directory.GetDirectories(windows, "*", SearchOption.AllDirectories)) Directory.CreateDirectory(Path.Combine(older, folder.Substring(windows.Length + 1)));
        foreach (string source in Directory.GetFiles(windows, "*", SearchOption.AllDirectories)) File.Copy(source, Path.Combine(older, source.Substring(windows.Length + 1)));
        // The earlier pack list has this pack's app icons and none of its file artwork.
        string seed = Path.Combine(older, "OnDemand.tsv");
        string[] rows = File.ReadAllLines(seed);
        string[] kept = rows.Where(row => !row.Contains("\t" + pack + "/FileTypes/")).ToArray();
        Check(rows.Length - kept.Length == 14, "The earlier pack list leaves out the pack's 14 file type icons");
        File.WriteAllLines(seed, kept);
        var json = new JavaScriptSerializer();
        File.WriteAllText(Path.Combine(state, "tray-preferences.json"), json.Serialize(new Preferences { Hotkey = new HotkeySettings { Enabled = false } }));
        var fixture = new FixtureConfig { StateDirectory = state, ShortcutDirectory = new[] { root }, KeepOpenForAutomation = true };
        using (var show = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (var stop = new EventWaitHandle(false, EventResetMode.AutoReset)) {
            using (var form = new LauncherForm(older, fixture, true, show, stop)) {
                form.Start(); form.ShowManager();
                WaitStarted(form);
                Field<TabControl>(form, "pages").SelectedIndex = 1;
                Check(!Field<ComboBox>(form, "fileThemes").Items.OfType<ThemeEntry>().Any(t => t.Id == pack), "With the earlier pack list the pack is an app icon pack only");
                SelectPack(form, pack, false, true, false);
                typeof(LauncherForm).GetMethod("ExitLauncher", Fields).Invoke(form, null);
            }
            using (var form = new LauncherForm(windows, fixture, true, show, stop)) {
                form.Start(); form.ShowManager();
                WaitStarted(form);
                Field<TabControl>(form, "pages").SelectedIndex = 1;
                var combo = Field<ComboBox>(form, "themes");
                var fileCombo = Field<ComboBox>(form, "fileThemes");
                ThemeEntry local = Find(combo, pack);
                Check(((ThemeEntry)combo.SelectedItem).Id == pack && local.UpdateAvailable && !local.HasFileIcons && local.PublishedFileIconCount == 14,
                      "The copy on the computer has no file artwork, and its update brings 14 file type icons");
                Check(fileCombo.Items.OfType<ThemeEntry>().Count(t => t.Id == pack) == 1 && Find(fileCombo, pack).ToString().EndsWith(" (Update available)") && fileCombo.SelectedIndex == 0,
                      "The file type list offers the pack before its update is downloaded");
                SelectPack(form, pack, true, true, false);
                var saved = json.Deserialize<Preferences>(File.ReadAllText(Path.Combine(state, "tray-preferences.json")));
                Check(local.HasFileIcons && !local.UpdateAvailable && saved.FileTheme == pack && fileCombo.SelectedItem == Find(fileCombo, pack) &&
                      Find(combo, pack).ToString().EndsWith(" (Downloaded)"),
                      "Choosing it there downloads the update and selects its file artwork");
                typeof(LauncherForm).GetMethod("ExitLauncher", Fields).Invoke(form, null);
            }
        }
    }
    static void CheckCurrentPackUpdate()
    {
        var type = typeof(LauncherForm).Assembly.GetType("BetterIcon.Tray.PackPicker", true);
        using (var host = new Form())
        using (var picker = (ComboBox)Activator.CreateInstance(type, true)) {
            picker.DropDownStyle = ComboBoxStyle.DropDownList; host.Controls.Add(picker);
            var current = new ThemeEntry { Name = "First" };
            var update = new ThemeEntry { Name = "Second", UpdateAvailable = true };
            picker.Items.AddRange(new[] { current, update }); host.Show(); picker.SelectedItem = current;
            int choices = 0;
            type.GetEvent("PackChosen").AddEventHandler(picker, new EventHandler(delegate { choices++; }));
            picker.SelectedItem = update;
            Check(choices == 0 && picker.SelectedItem == update, "Restoring the current pack leaves its available update pending");
            var list = OpenRows(picker);
            IntPtr point = RowPoint(list, 1);
            SendMessage(list, 0x0201, (IntPtr)1, point); SendMessage(list, 0x0202, IntPtr.Zero, point);
            Check(choices == 1, "Clicking an already-selected row can download its update");
            list = OpenRows(picker); SendMessage(list, 0x0186, (IntPtr)1, IntPtr.Zero);
            SendMessage(picker.Handle, 0x0100, (IntPtr)Keys.Enter, IntPtr.Zero);
            Check(choices == 2, "Enter also accepts an update to the current pack");
            type.GetMethod("ChooseItem").Invoke(picker, new object[] { update });
            Check(choices == 3, "The tray selection can update the currently selected pack");
        }
    }
    static void CheckRefresh(string windows, string state, FixtureConfig fixture)
    {
        using (var show = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (var stop = new EventWaitHandle(false, EventResetMode.AutoReset))
        for (int pass = 0; pass < 2; pass++) using (var form = new LauncherForm(windows, fixture, true, show, stop)) {
            form.Start(); form.ShowManager();
            Wait(() => !Field<bool>(form, "busy") && Field<Catalog>(form, "catalog") != null);
            Field<TabControl>(form, "pages").SelectedIndex = 1;
            var tray = Field<NotifyIcon>(form, "tray").ContextMenuStrip;
            var combo = Field<ComboBox>(form, "themes");
            var refresh = Field<Button>(form, "refreshPacksButton");
            const string refreshLabel = "Refresh available icon packs";
            Func<ToolStripMenuItem> command = () => tray.Items.OfType<ToolStripMenuItem>().Single(i => i.Text == refreshLabel);
            const string id = "Craft-Icons-Cryogenn/ArtCraft iconPackage - Dark";
            string snapshot = Path.Combine(state, "pack-catalog", "latest.tsv");
            int before = combo.Items.OfType<ThemeEntry>().Count(t => !t.IsDefault);
            byte[] prefs = File.ReadAllBytes(Path.Combine(state, "tray-preferences.json"));
            if (pass == 1) {
                // The app list holds the 27 app packs. The five packs with file type artwork only are in the other list.
                Check(before >= 27 && Find(combo, id) != null, "The refreshed list survives an offline restart");
                byte[] saved = File.ReadAllBytes(snapshot);
                command().PerformClick();
                Wait(() => !Field<bool>(form, "busy"));
                Check(Field<Label>(form, "status").Text.Contains("Couldn't refresh") && saved.SequenceEqual(File.ReadAllBytes(snapshot)) &&
                    combo.Items.OfType<ThemeEntry>().Count(t => !t.IsDefault) == before, "An offline retry reports failure and retains the complete last-known list");
            } else {
                Check(!File.Exists(snapshot), "Launching and opening the tray menu use the installer catalog offline");
                Check(refresh.Visible && refresh.Enabled && refresh.Parent == combo.Parent && combo.Right < refresh.Left &&
                    combo.Top == refresh.Top && Math.Abs(combo.Height - refresh.Height) <= 1 &&
                    combo.Bottom <= combo.Parent.ClientSize.Height && combo.Width > refresh.Width,
                    "The refresh button is visible directly to the right of the icon pack picker");
                Check(refresh.AccessibleName == refreshLabel && Field<ToolTip>(form, "appearanceTips").GetToolTip(refresh) == refreshLabel,
                    "The icon-only refresh button has a descriptive hover tooltip and accessible name");
                tray.Show(form, new Point(15, 15)); Application.DoEvents();
                Check(command().Enabled, "The real tray context menu offers Refresh available icon packs");
                tray.Close(); refresh.PerformClick();
                Check(Field<bool>(form, "busy") && !refresh.Enabled && !command().Enabled, "Both refresh controls are disabled while the status bar is checking");
                Wait(() => !Field<bool>(form, "busy"));
                int after = combo.Items.OfType<ThemeEntry>().Count(t => !t.IsDefault);
                Check(refresh.Enabled && File.Exists(snapshot) && after >= 27 && after >= before && Find(combo, id) != null,
                    "The button reads the public catalog, refreshes the app dropdown (" + before + " to " + after + ") and is ready to use again. " + Field<Label>(form, "status").Text);
                Check(MenuLabel(form, Find(combo, id)) == Find(combo, id).ToString(), "The tray theme menu shows the refreshed entry and its availability");
                var fileCombo = Field<ComboBox>(form, "fileThemes");
                Check(fileCombo.Items.OfType<ThemeEntry>().Count(t => t.Pack == "Craft-Icons-Komplett") == 5 && fileCombo.Items.OfType<ThemeEntry>().All(t => t.HasFileIcons), "The file type dropdown lists the refreshed file type packs");
                Check(!Directory.Exists(Path.Combine(state, "downloads")) && !Directory.Exists(Path.Combine(state, "pack-previews")), "Refreshing requests metadata without downloading packs or WebP artwork");
                Check(prefs.SequenceEqual(File.ReadAllBytes(Path.Combine(state, "tray-preferences.json"))), "Refreshing preserves the app and file pack preferences");
                string newPackLabel = Find(combo, id).ToString();
                string updatedPackLabel = Find(fileCombo, "Craft-Icons-Komplett/Standard").ToString();
                typeof(LauncherForm).GetMethod("ExitLauncher", Fields).Invoke(form, null);
                CheckUpdateBadge(windows, state, fixture, snapshot, newPackLabel, updatedPackLabel);
                Offline();
                continue;
            }
            typeof(LauncherForm).GetMethod("ExitLauncher", Fields).Invoke(form, null);
        }
    }

    static int PackUpdateCount(LauncherForm form)
    {
        var check = Field<PackUpdateCheck>(form, "packUpdateCheck");
        return check == null ? 0 : check.Count;
    }

    static void RunBackgroundPackCheck(LauncherForm form)
    {
        var check = (System.Threading.Tasks.Task)typeof(LauncherForm).GetMethod("CheckForPackUpdates", Fields).Invoke(form, null);
        Check(!Field<bool>(form, "busy"), "The background pack check leaves the rest of BetterIcon available");
        Wait(() => check.IsCompleted);
        check.GetAwaiter().GetResult();
    }

    static int[] RefreshButtonCorner(Button refresh)
    {
        using (var bitmap = new Bitmap(refresh.Width, refresh.Height)) {
            refresh.DrawToBitmap(bitmap, refresh.ClientRectangle);
            var pixels = new List<int>();
            for (int y = 1; y < bitmap.Height / 3; y++)
                for (int x = bitmap.Width * 2 / 3; x < bitmap.Width - 1; x++)
                    pixels.Add(bitmap.GetPixel(x, y).ToArgb());
            return pixels.ToArray();
        }
    }

    static void CheckUpdateBadge(string windows, string state, FixtureConfig fixture, string snapshot, string omittedLabel, string changedLabel)
    {
        const string omitted = "Craft-Icons-Cryogenn/ArtCraft iconPackage - Dark";
        const string changed = "Craft-Icons-Komplett/Standard";
        var lines = File.ReadAllLines(snapshot);
        var header = lines[0].Split('\t');
        header[0] = new string('0', 40);
        var assets = lines.Skip(1).Select(line => line.Split('\t')).ToArray();
        var oldAsset = assets.First(row => row[2].StartsWith(changed + "/", StringComparison.Ordinal));
        oldAsset[0] = new string('0', 40);
        File.WriteAllLines(snapshot, new[] { String.Join("\t", header) }.Concat(assets
            .Where(row => !row[2].StartsWith(omitted + "/", StringComparison.Ordinal))
            .Select(row => String.Join("\t", row))));

        byte[] staleSnapshot = File.ReadAllBytes(snapshot);
        string preferences = Path.Combine(state, "tray-preferences.json");
        byte[] savedPreferences = File.ReadAllBytes(preferences);
        var automatic = new FixtureConfig {
            StateDirectory = state, ShortcutDirectory = fixture.ShortcutDirectory,
            KeepOpenForAutomation = true, AutomaticPackChecks = true
        };
        using (var show = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (var stop = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (var form = new LauncherForm(windows, automatic, true, show, stop)) {
            var refresh = Field<Button>(form, "refreshPacksButton");
            string initialDescription = refresh.AccessibleDescription;
            form.Start();
            Wait(() => !Field<bool>(form, "busy") && Field<Catalog>(form, "catalog") != null);
            var combo = Field<ComboBox>(form, "themes");
            var selected = combo.SelectedItem;
            var status = Field<Label>(form, "status");
            string initialStatus = status.Text;
            Wait(() => PackUpdateCount(form) != 0);
            Check(!form.Visible && PackUpdateCount(form) == 2 && status.Text == initialStatus &&
                  Object.ReferenceEquals(combo.SelectedItem, selected),
                  "The hidden launcher quietly detects one new pack and one artwork update at startup");
            Check(staleSnapshot.SequenceEqual(File.ReadAllBytes(snapshot)) && savedPreferences.SequenceEqual(File.ReadAllBytes(preferences)) &&
                  !Directory.Exists(Path.Combine(state, "downloads")) && !Directory.Exists(Path.Combine(state, "pack-previews")),
                  "Automatic checking only reads metadata and preserves the current catalog and artwork caches");

            string[] proxyNames = { "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY" };
            var proxies = proxyNames.ToDictionary(name => name, Environment.GetEnvironmentVariable);
            try {
                Offline();
                RunBackgroundPackCheck(form);
                Check(PackUpdateCount(form) == 2 && !form.Visible,
                      "An offline background check keeps the prior badge and leaves the launcher hidden");
            } finally {
                foreach (var proxy in proxies) Environment.SetEnvironmentVariable(proxy.Key, proxy.Value);
            }

            form.ShowManager();
            Field<TabControl>(form, "pages").SelectedIndex = 1;
            combo.Focus();
            Application.DoEvents();
            Check(refresh.Visible && refresh.Enabled && (refresh.AccessibleDescription ?? "").Contains("2"),
                  "The refresh button is available and exposes the pending count to screen readers");
            var marked = RefreshButtonCorner(refresh);
            refresh.PerformClick();
            Check(Field<bool>(form, "busy"), "The badged refresh button starts a manual refresh");
            Wait(() => !Field<bool>(form, "busy"));
            combo.Focus();
            Application.DoEvents();
            Check(!staleSnapshot.SequenceEqual(File.ReadAllBytes(snapshot)),
                  "The manual refresh replaces the older catalog (" + status.Text + ")");
            Check(PackUpdateCount(form) == 0 && refresh.AccessibleDescription == initialDescription &&
                  !marked.SequenceEqual(RefreshButtonCorner(refresh)),
                  "Refreshing manually acknowledges the changes and removes the visible badge");
            Check(Find(combo, omitted).ToString() == omittedLabel && Find(Field<ComboBox>(form, "fileThemes"), changed).ToString() == changedLabel &&
                  savedPreferences.SequenceEqual(File.ReadAllBytes(preferences)) &&
                  !Directory.Exists(Path.Combine(state, "downloads")) && !Directory.Exists(Path.Combine(state, "pack-previews")),
                  "Acknowledging the badge preserves pack availability and leaves artwork downloads to the user");
            typeof(LauncherForm).GetMethod("ExitLauncher", Fields).Invoke(form, null);
        }
    }
}
