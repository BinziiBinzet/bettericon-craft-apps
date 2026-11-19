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
        var list = OpenRows(combo);
        foreach (var pack in combo.Items.OfType<ThemeEntry>().Where(t => t.NeedsDownload)) {
            var point = RowPoint(list, combo.Items.IndexOf(pack));
            SendMessage(list, 0x0200, IntPtr.Zero, point); // hover
            SendMessage(combo.Handle, 0x0100, (IntPtr)Keys.Down, IntPtr.Zero);
        }
        combo.DroppedDown = false; combo.SelectedItem = target; Application.DoEvents();
        Check(Object.Equals(active, combo.SelectedItem) && target.NeedsDownload && !Directory.Exists(cache),
            "Opening, hovering, arrowing across the list, canceling and programmatic selection never download a pack");
    }
    static string MenuLabel(LauncherForm form, ThemeEntry pack)
    {
        var menu = Field<ContextMenuStrip>(form, "trayMenu").Items.OfType<ToolStripMenuItem>().Single(i => i.Text == "Change icon theme");
        return menu.DropDownItems.Cast<ToolStripMenuItem>().Single(i => i.Text.StartsWith(pack.DisplayName + " (")).Text;
    }
    static void SelectPack(Form form, string id, bool file, bool download, bool fails)
    {
        var combo = Field<ComboBox>(form, file ? "packs" : "themes");
        var label = Field<Label>(form, file ? "phase" : "loadingMessage");
        var bar = Field<ProgressBar>(form, file ? "progress" : "loadingProgress");
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
            if (file) Wait(() => !Field<bool>(form, "working"));
            else {
                var work = Field<System.Threading.Tasks.Task>(form, "packLoadTask");
                Wait(() => work.IsCompleted);
                work.GetAwaiter().GetResult();
            }
            var expected = download && !fails ? new[] { first, "Loading " + name } : new[] { first };
            Check(changes.SequenceEqual(expected) && !bar.Visible && bar.MarqueeAnimationSpeed == 0,
                "Bottom bar shows the actual phases in order and stops: " + String.Join(" then ", changes) +
                " (visible=" + bar.Visible + ", speed=" + bar.MarqueeAnimationSpeed + ")");
            if (fails) {
                Check(combo.SelectedItem != target && Field<Label>(form, "message").Text.Length > 0 && target.ToString().EndsWith(" (Download)"), "Failed fetch returns to the previous pack and keeps the Download label");
            } else {
                var list = Field<ListView>(form, file ? "files" : "packPreview");
                Check(list.Items.Count > 0 && !target.NeedsDownload, "The selected artwork is ready");
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
        if (args.Length > 2 && args[2] == "refresh") { CheckRefresh(args[0], state, fixture); return; }
        CheckCurrentPackUpdate();
        if (!lean) Offline();
        const string first = "Craft-Icons-circleb/Root", second = "Craft-Icons-Komplett/Standard", third = "Craft-Icons-Zach/Ink";
        using (var show = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (var stop = new EventWaitHandle(false, EventResetMode.AutoReset)) {
            for (int pass = 0; pass < 2; pass++) using (var form = new LauncherForm(args[0], fixture, true, show, stop)) {
                form.Start();
                form.ShowManager();
                Wait(() => !Field<bool>(form, "busy") && Field<Catalog>(form, "catalog") != null);
                Field<TabControl>(form, "pages").SelectedIndex = 1;
                var combo = Field<ComboBox>(form, "themes");
                if (pass == 1) {
                    HoverPack(combo, Find(combo, third), state, args[0], lean);
                    Check(((ThemeEntry)combo.SelectedItem).Id == first && !Find(combo, second).NeedsDownload, "Restart offline remembers the app pack and the downloaded file pack");
                    SelectPack(form, second, false, false, false);
                    Check(json.Deserialize<Preferences>(File.ReadAllText(prefs)).FileTheme == first, "App pack switches preserve the file pack preference");
                    typeof(LauncherForm).GetMethod("ExitLauncher", Fields).Invoke(form, null);
                    continue;
                }
                var packs = combo.Items.OfType<ThemeEntry>().Where(t => !t.IsDefault).ToArray();
                Check(packs.Length == 32 && packs.Sum(t => t.IconCount) == 452 && packs.All(t => t.NeedsDownload == lean), "First launch lists all 32 packs and 452 icons with the correct availability");
                Check(packs.Single(t => t.Author == "VimiummuimiV").Id == flat && Find(combo, flat).IconCount == 13, "Modern Flat has one entry with all 13 app icons");
                Check((lean || ((ThemeEntry)combo.SelectedItem).Id == flat) && json.Deserialize<Preferences>(File.ReadAllText(prefs)).FileTheme == flat, "Saved variant selections resolve to Modern Flat without downloading");
                var cache = Path.Combine(state, "downloads");
                Check(!Directory.Exists(cache), "Listing the catalog creates no download cache");
                Check(packs.All(t => t.ToString().EndsWith(lean ? " (Download)" : " (Included)") && MenuLabel(form, t) == t.ToString()), "Picker and tray labels identify each pack's availability at installation");
                if (lean) Browse(combo, Find(combo, third), cache);
                Check(!Directory.Exists(Path.Combine(state, "pack-previews")), "Opening and quickly browsing the catalog fetched no previews");
                HoverPack(combo, Find(combo, third), state, args[0], lean, true);
                HoverPack(combo, Find(combo, flat), state, args[0], lean);
                HoverRaces(form, Find(combo, third), Find(combo, second), state, args[0], lean);
                PersonalHover(form, state);
                TrayHover(form, Find(combo, third));
                Check(!Directory.Exists(cache), "Hover previews keep the full-pack cache empty");
                SelectPack(form, first, false, lean, false);
                Check(MenuLabel(form, Find(combo, first)).EndsWith(lean ? " (Downloaded)" : " (Included)"), "The clicked pack has the correct local status in the tray");
                var dialogType = typeof(LauncherForm).GetNestedType("ProjectFileDialog", BindingFlags.NonPublic);
                using (var files = (Form)Activator.CreateInstance(dialogType, new object[] { form, null })) {
                    files.Show(form);
                    Wait(() => files.Visible && !Field<bool>(files, "working"));
                    HoverPack(Field<ComboBox>(files, "packs"), Find(combo, third), state, args[0], lean);
                    SelectPack(files, second, true, lean, false);
                    Check(MenuLabel(form, Find(combo, second)).EndsWith(lean ? " (Downloaded)" : " (Included)"), "Choosing a file pack updates its availability in the other menus");
                    Offline();
                    SelectPack(files, first, true, false, false);
                    if (lean) SelectPack(files, third, true, true, true);
                    Check(Field<ListView>(files, "files").Items.Cast<ListViewItem>().Any(row => row.Text == ".pcraft"), "File picker previews native PhotoCraft documents");
                    files.Close();
                }
                var saved = json.Deserialize<Preferences>(File.ReadAllText(prefs));
                Check(saved.Theme == first && saved.FileTheme == first, "Successful app and file choices are persisted independently");
                if (lean) {
                    Check(Directory.GetFiles(cache, ".complete", SearchOption.AllDirectories).Length == 2 &&
                          Directory.GetDirectories(cache, ".loading-*", SearchOption.AllDirectories).Length == 0,
                          "Only selected packs were cached and a failed download published no partial files");
                } else Check(!Directory.Exists(cache), "The bundled edition loads both pack types entirely offline");
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
            var tray = Field<NotifyIcon>(form, "tray").ContextMenuStrip;
            var combo = Field<ComboBox>(form, "themes");
            Func<ToolStripMenuItem> command = () => tray.Items.OfType<ToolStripMenuItem>().Single(i => i.Text == "Refresh available icon packs");
            const string id = "Craft-Icons-Cryogenn/ArtCraft iconPackage - Dark";
            string snapshot = Path.Combine(state, "pack-catalog", "latest.tsv");
            int before = combo.Items.OfType<ThemeEntry>().Count(t => !t.IsDefault);
            byte[] prefs = File.ReadAllBytes(Path.Combine(state, "tray-preferences.json"));
            if (pass == 1) {
                Check(before >= 32 && Find(combo, id) != null, "The refreshed list survives an offline restart");
                byte[] saved = File.ReadAllBytes(snapshot);
                command().PerformClick();
                Wait(() => !Field<bool>(form, "busy"));
                Check(Field<Label>(form, "status").Text.Contains("Couldn't refresh") && saved.SequenceEqual(File.ReadAllBytes(snapshot)) &&
                    combo.Items.OfType<ThemeEntry>().Count(t => !t.IsDefault) == before, "An offline retry reports failure and retains the complete last-known list");
            } else {
                Check(!File.Exists(snapshot), "Launching and opening the tray menu use the installer catalog offline");
                tray.Show(form, new Point(15, 15)); Application.DoEvents();
                Check(command().Enabled, "The real tray context menu offers Refresh available icon packs");
                command().PerformClick(); tray.Close();
                Check(Field<bool>(form, "busy") && !command().Enabled, "A refresh cannot be started twice while the status bar is checking");
                Wait(() => !Field<bool>(form, "busy"));
                int after = combo.Items.OfType<ThemeEntry>().Count(t => !t.IsDefault);
                Check(File.Exists(snapshot) && after >= 32 && Find(combo, id) != null, "The command reads the public catalog and refreshes the app dropdown (" + before + " to " + after + ")");
                Check(MenuLabel(form, Find(combo, id)) == Find(combo, id).ToString(), "The tray theme menu shows the refreshed entry and its availability");
                var dialog = typeof(LauncherForm).GetNestedType("ProjectFileDialog", BindingFlags.NonPublic);
                using (var files = (Form)Activator.CreateInstance(dialog, new object[] { form, null })) {
                    Check(Find(Field<ComboBox>(files, "packs"), id) != null, "The File icons dropdown includes the refreshed pack");
                }
                Check(!Directory.Exists(Path.Combine(state, "downloads")) && !Directory.Exists(Path.Combine(state, "pack-previews")), "Refreshing requests metadata without downloading packs or WebP artwork");
                Check(prefs.SequenceEqual(File.ReadAllBytes(Path.Combine(state, "tray-preferences.json"))), "Refreshing preserves the app and file pack preferences");
                Offline();
            }
            typeof(LauncherForm).GetMethod("ExitLauncher", Fields).Invoke(form, null);
        }
    }
}
