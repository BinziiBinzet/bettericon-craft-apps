using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
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
using Microsoft.Win32;

static class ShortcutScopeTests
{
    const BindingFlags Instance = BindingFlags.Instance | BindingFlags.NonPublic;
    [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr window);
    static IEnumerable<Control> Children(Control parent)
    {
        foreach (Control child in parent.Controls) { yield return child; foreach (Control nested in Children(child)) yield return nested; }
    }
    public static void SelectScope(Action show, string scope)
    {
        bool selected = false;
        using (System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 25 }) {
            timer.Tick += delegate {
                ShortcutScopeDialog dialog = Application.OpenForms.OfType<ShortcutScopeDialog>().FirstOrDefault();
                if (dialog == null) return;
                selected = true; timer.Stop();
                dialog.Controls.Find(scope == null ? "CancelScope" : scope + "Choice", true).OfType<Button>().Single().PerformClick();
            };
            timer.Start(); show();
        }
        if (!selected) throw new Exception("The shortcut-location dialog did not open.");
    }
    static void Operation(LauncherForm form, string action, string scope, bool confirm, Action<ShortcutScopeDialog> inspect, Action<Form> review)
    {
        Exception failure = null; int prompts = 0;
        DateTime deadline = DateTime.UtcNow.AddSeconds(45);
        using (System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 25 }) {
            timer.Tick += delegate {
                Form dialog = Application.OpenForms.Cast<Form>().FirstOrDefault(window => window != form && window.Owner == form && window.Visible);
                try {
                    if (DateTime.UtcNow > deadline) throw new Exception("Timed out in " + action + ".");
                    if (dialog == null) return;
                    ShortcutScopeDialog choice = dialog as ShortcutScopeDialog;
                    if (choice != null) {
                        prompts++; if (prompts != 1) throw new Exception("One operation opened multiple location prompts.");
                        if (inspect != null) inspect(choice);
                        choice.Controls.Find(scope == null ? "CancelScope" : scope + "Choice", true).OfType<Button>().Single().PerformClick();
                    }
                    else if (dialog.Text == "Review icon changes" || dialog.Text == "Review restoration") {
                        if (review != null) review(dialog);
                        dialog.DialogResult = confirm ? DialogResult.OK : DialogResult.Cancel;
                    }
                    else if (dialog.Text == "Operation results") dialog.DialogResult = DialogResult.OK;
                    else throw new Exception("Unexpected dialog: " + dialog.Text + " " + String.Join(" ", Children(dialog).OfType<Label>().Select(label => label.Text)));
                }
                catch (Exception error) { failure = error; if (dialog != null) dialog.DialogResult = DialogResult.Cancel; }
            };
            timer.Start();
            Task task = (Task)typeof(LauncherForm).GetMethod(action, Instance).Invoke(form, action == "RestoreIcons" ? new object[] { null } : null);
            while (!task.IsCompleted && DateTime.UtcNow < deadline.AddSeconds(2)) { Application.DoEvents(); Thread.Sleep(10); }
            timer.Stop(); if (failure != null) throw failure;
            if (!task.IsCompleted) throw new Exception("Shortcut operation did not finish.");
            task.GetAwaiter().GetResult();
            if (prompts != 1) throw new Exception("Each shortcut operation must ask for locations.");
        }
    }
    public static void Run(string root, string source, JavaScriptSerializer json, Action<bool, string> check)
    {
        string links = Path.Combine(root, "scope-choice-links"), state = Path.Combine(root, "scope-choice-state");
        Directory.CreateDirectory(links); Directory.CreateDirectory(state);
        string photo = Path.Combine(links, "PhotoCraft.lnk"), film = Path.Combine(links, "FilmCraft.lnk");
        File.Copy(Path.Combine(root, "PhotoCraft.lnk"), photo); File.Copy(Path.Combine(root, "PhotoCraft.lnk"), film);
        byte[] originalPhoto = File.ReadAllBytes(photo), originalFilm = File.ReadAllBytes(film);
        string preferencesPath = Path.Combine(state, "tray-preferences.json");
        File.WriteAllText(preferencesPath, json.Serialize(new Preferences { Theme = "Craft-Icons-Zach/Satin", Scope = "AllUsers", IconSize = 48, Hotkey = new HotkeySettings { Enabled = false } }));
        Exception failure = null;
        using (EventWaitHandle show = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (EventWaitHandle stop = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (LauncherForm form = new LauncherForm(source, new FixtureConfig { ShortcutDirectory = new[] { links }, StateDirectory = state, KeepOpenForAutomation = true }, true, show, stop))
        using (LauncherContext context = new LauncherContext(form))
        using (System.Windows.Forms.Timer ready = new System.Windows.Forms.Timer { Interval = 50 }) {
            Func<string, object> field = name => typeof(LauncherForm).GetField(name, Instance).GetValue(form);
            ready.Tick += delegate {
                if ((bool)field("busy") || field("catalog") == null) return;
                ready.Stop();
                try {
                    form.ShowManager();
                    foreach (Size size in new[] { new Size(790, 570), new Size(900, 690) }) {
                        form.Size = size; ((TabControl)field("pages")).SelectedIndex = 1;
                        form.PerformLayout(); Application.DoEvents();
                        string problem = (string)typeof(TrayTests).GetMethod("SettingsLayoutProblem", BindingFlags.Static | BindingFlags.NonPublic).Invoke(null, new object[] { (Control)field("settingsContent") });
                        check(problem == null, "Simplified Settings remains contained at " + size.Width + "x" + size.Height + (problem == null ? "" : ": " + problem));
                    }
                    check(!Children(form).Any(control => control.AccessibleName == "Shortcut locations") && typeof(LauncherForm).GetField("scopes", Instance) == null,
                        "Settings no longer contains a shortcut-location dropdown");
                    byte[] before = File.ReadAllBytes(preferencesPath);
                    int inspected = 0;
                    Action<ShortcutScopeDialog> inspect = dialog => {
                        inspected++;
                        Label notice = dialog.Controls.Find("AdministratorNotice", true).OfType<Label>().Single();
                        Button all = dialog.Controls.Find("AllUsersChoice", true).OfType<Button>().Single();
                        check(dialog.SelectedScope == null && dialog.CancelButton != null && notice.Text.Contains("requires administrator privileges") && all.AccessibleDescription.Contains("administrator privileges"),
                            "The " + (inspected == 1 ? "Apply" : "Restore") + " prompt starts unchosen and clearly explains administrator privileges for all users");
                        string problem = (string)typeof(TrayTests).GetMethod("SettingsLayoutProblem", BindingFlags.Static | BindingFlags.NonPublic).Invoke(null, new object[] { dialog });
                        check(problem == null, "The location prompt fits its native controls at the shipping display DPI" + (problem == null ? "" : ": " + problem));
                        check(!((ContextMenuStrip)field("trayMenu")).Enabled && !IsWindowEnabled(form.Handle), "The location prompt owns input while its native parent and tray commands are unavailable");
                    };
                    Operation(form, "ApplyTheme", null, false, inspect, null);
                    Operation(form, "RestoreIcons", null, false, inspect, null);
                    ((TabControl)field("pages")).SelectedIndex = 1;
                    SelectScope(() => ((Button)field("apply")).PerformClick(), null);
                    SelectScope(() => ((Button)field("restore")).PerformClick(), null);
                    SelectScope(() => ((ContextMenuStrip)field("trayMenu")).Items.OfType<ToolStripMenuItem>().Single(item => item.Text == "Restore original icons...").PerformClick(), null);
                    check(true, "Settings Apply, Settings Restore and tray Restore all open a fresh location prompt");
                    check(File.ReadAllBytes(preferencesPath).SequenceEqual(before) && !File.Exists(Path.Combine(state, "manifest.json")) && File.ReadAllBytes(photo).SequenceEqual(originalPhoto) && File.ReadAllBytes(film).SequenceEqual(originalFilm),
                        "Canceling either location prompt leaves preferences, shortcuts and backup state unchanged");
                    int applyReviews = 0;
                    Operation(form, "ApplyTheme", "CurrentUser", true, null, dialog => {
                        string text = String.Join(" ", Children(dialog).OfType<Label>().Select(label => label.Text));
                        applyReviews++; check(text.Contains("your Desktop and Start menu") && !text.Contains("administrator access"), "Current-user application reviews the selected locations before writing fixture shortcuts");
                    });
                    check(applyReviews == 1 && !File.ReadAllBytes(photo).SequenceEqual(originalPhoto) && !File.ReadAllBytes(film).SequenceEqual(originalFilm) && json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).Scope == "AllUsers",
                        "The current-user choice applies successfully despite an opposite legacy preference");
                    Preferences afterApply = json.Deserialize<Preferences>(File.ReadAllText(preferencesPath));
                    check(afterApply.AppliedTheme == ((ThemeEntry)((ComboBox)field("themes")).SelectedItem).Id && afterApply.AppliedArtwork != null && File.Exists(afterApply.AppliedArtwork["PhotoCraft"]),
                        "A confirmed application becomes the pack the Launcher shows");
                    byte[] appliedPhoto = File.ReadAllBytes(photo), manifest = File.ReadAllBytes(Path.Combine(state, "manifest.json"));
                    int sharedReviews = 0;
                    Operation(form, "ApplyTheme", "AllUsers", false, null, dialog => {
                        string text = String.Join(" ", Children(dialog).OfType<Label>().Select(label => label.Text));
                        sharedReviews++; check(text.Contains("shared Desktop and Start menu") && text.Contains("administrator access"), "All-users application previews shared locations and the administrator requirement before confirmation");
                    });
                    check(sharedReviews == 1 && File.ReadAllBytes(photo).SequenceEqual(appliedPhoto) && File.ReadAllBytes(Path.Combine(state, "manifest.json")).SequenceEqual(manifest),
                        "Canceling an all-users apply review avoids elevation and leaves the prior installation intact");
                    // Give the read-only all-users restore preview its own matching
                    // manifest. Confirming it would require elevation, so cancel.
                    var sharedManifest = json.Deserialize<Dictionary<string, object>>(EncodingText(manifest));
                    sharedManifest["Scope"] = "AllUsers";
                    File.WriteAllText(Path.Combine(state, "manifest.json"), json.Serialize(sharedManifest));
                    byte[] sharedBytes = File.ReadAllBytes(Path.Combine(state, "manifest.json")); int restoreReviews = 0;
                    Operation(form, "RestoreIcons", "AllUsers", false, null, dialog => {
                        restoreReviews++;
                        string text = String.Join(" ", Children(dialog).OfType<Label>().Select(label => label.Text));
                        check(text.Contains("shared locations") && text.Contains("administrator access required"), "All-users restoration reviews the shared backups and administrator requirement");
                    });
                    check(restoreReviews == 1 && File.ReadAllBytes(photo).SequenceEqual(appliedPhoto) && File.ReadAllBytes(Path.Combine(state, "manifest.json")).SequenceEqual(sharedBytes), "Canceling an all-users restore review preserves shortcuts and backups without elevation");
                    File.WriteAllBytes(Path.Combine(state, "manifest.json"), manifest);
                    Operation(form, "RestoreIcons", "CurrentUser", true, null, dialog => {
                        string text = String.Join(" ", Children(dialog).OfType<Label>().Select(label => label.Text));
                        check(text.Contains("your locations") && !text.Contains("administrator access required"), "Current-user restoration uses the newly chosen locations instead of the legacy preference");
                    });
                    check(File.ReadAllBytes(photo).SequenceEqual(originalPhoto) && File.ReadAllBytes(film).SequenceEqual(originalFilm), "Current-user restoration returns both disposable shortcuts byte-for-byte");
                    Preferences afterRestore = json.Deserialize<Preferences>(File.ReadAllText(preferencesPath));
                    check(afterRestore.AppliedTheme == ThemeEntry.DefaultThemeId && afterRestore.AppliedArtwork == null, "Restoring every default returns the Launcher to the original icons");
                    check(!((bool)field("busy")) && ((ContextMenuStrip)field("trayMenu")).Enabled && IsWindowEnabled(form.Handle), "Completed and canceled scope operations restore normal launcher and tray input");
                    ComboBox themes = (ComboBox)field("themes"); themes.SelectedIndex = 0; LoadingTests.Wait(form);
                    byte[] defaultBefore = File.ReadAllBytes(preferencesPath);
                    SelectScope(() => ((Button)field("apply")).PerformClick(), null);
                    check(File.ReadAllBytes(preferencesPath).SequenceEqual(defaultBefore) && File.ReadAllBytes(photo).SequenceEqual(originalPhoto), "Applying the virtual ArtCraft default also asks for locations and can be canceled without changes");
                    stop.Set();
                }
                catch (Exception error) { failure = error; context.ExitThread(); }
            };
            ready.Start(); Application.Run(context); if (failure != null) throw failure;
        }
    }
    static string EncodingText(byte[] bytes) { return System.Text.Encoding.UTF8.GetString(bytes).TrimStart('\uFEFF'); }
}

// Checks after app updates in the running tray: disposable shortcuts, a fake installer, and no real elevation.
static class ReapplyTests
{
    const BindingFlags Instance = BindingFlags.Instance | BindingFlags.NonPublic;
    const string Pack = "Craft-Icons-Zach/Cardboard", Started = "Reapply started", Finished = "Reapply finished";
    public sealed class Bench { public string Links, State, Photo, Busy, Sessions; public FixtureConfig Fixture; }
    public static object Field(LauncherForm form, string name) { return typeof(LauncherForm).GetField(name, Instance).GetValue(form); }
    public static object Call(LauncherForm form, string name, params object[] arguments) { return typeof(LauncherForm).GetMethod(name, Instance).Invoke(form, arguments); }
    public static bool WaitFor(Func<bool> condition, double seconds)
    {
        DateTime deadline = DateTime.UtcNow.AddSeconds(seconds);
        while (!condition()) {
            if (DateTime.UtcNow > deadline) return false;
            Application.DoEvents(); Thread.Sleep(25);
        }
        return true;
    }
    public static void Pump(double seconds) { WaitFor(() => false, seconds); }
    // Trace events whose name starts with the given text.
    public static int Events(string state, string name)
    {
        string log = Path.Combine(state, "tray-events.jsonl"), marker = "\"Event\":\"" + name;
        for (int attempt = 0; ; attempt++) {
            try { return File.Exists(log) ? File.ReadAllLines(log).Count(line => line.Contains(marker)) : 0; }
            catch (IOException) { if (attempt > 40) throw; Thread.Sleep(25); }
        }
    }
    public static int ExactEvents(string state, string name) { return Events(state, name + "\""); }
    static object Com(object target, string member, BindingFlags kind, params object[] arguments) { return target.GetType().InvokeMember(member, kind, null, target, arguments); }
    public static void WriteShortcut(string path, string target, string arguments, string description, string icon)
    {
        object shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
        try {
            object link = Com(shell, "CreateShortcut", BindingFlags.InvokeMethod, path);
            try {
                Com(link, "TargetPath", BindingFlags.SetProperty, target);
                Com(link, "Arguments", BindingFlags.SetProperty, arguments ?? "");
                if (description != null) Com(link, "Description", BindingFlags.SetProperty, description);
                if (icon != null) Com(link, "IconLocation", BindingFlags.SetProperty, icon);
                Com(link, "Save", BindingFlags.InvokeMethod);
            }
            finally { Marshal.FinalReleaseComObject(link); }
        }
        finally { Marshal.FinalReleaseComObject(shell); }
    }
    static string[] ReadShortcut(string path)
    {
        object shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
        try {
            object link = Com(shell, "CreateShortcut", BindingFlags.InvokeMethod, path);
            try { return new[] { (string)Com(link, "TargetPath", BindingFlags.GetProperty), (string)Com(link, "Arguments", BindingFlags.GetProperty) }; }
            finally { Marshal.FinalReleaseComObject(link); }
        }
        finally { Marshal.FinalReleaseComObject(shell); }
    }
    // As an MSI update does it: the shortcut is deleted and written again with the app's own icon.
    public static void FakeMsiUpdate(string path)
    {
        string[] launch = ReadShortcut(path);
        File.SetAttributes(path, FileAttributes.Normal);
        File.Delete(path);
        WriteShortcut(path, launch[0], launch[1], "Updated by a fake installer", null);
        File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddMinutes(-1));
    }
    public static string IconOf(string path)
    {
        try { return BetterIcon.Windows.ShellLink.Read(path).IconPath ?? ""; }
        catch (Exception) { return ""; }
    }
    public static bool Themed(Bench bench, string path) { return IconOf(path).StartsWith(Path.Combine(bench.State, "icons"), StringComparison.OrdinalIgnoreCase); }
    public static void Apply(string source, FixtureConfig fixture)
    {
        WorkerClient client = new WorkerClient(source, fixture);
        WorkerReply preview = client.Run(new WorkerRequest { Action = "Preview", Theme = Pack, Scope = "CurrentUser" }, false).Result;
        WorkerReply result = client.Run(new WorkerRequest { Action = "Apply", Theme = Pack, Scope = "CurrentUser", ExpectedPlan = preview.Plan }, false).Result;
        if (!result.Results.Any(row => row.Status == "Applied")) throw new Exception("The re-apply fixture did not apply " + Pack + ".");
    }
    // Disposable shortcuts with Cardboard applied, and a tray that checks for app updates by itself.
    public static Bench Prepare(string root, string source, string name, JavaScriptSerializer json, bool shared)
    {
        Bench bench = new Bench { Links = Path.Combine(root, name + "-links"), State = Path.Combine(root, name + "-state") };
        Directory.CreateDirectory(bench.Links); Directory.CreateDirectory(bench.State);
        bench.Photo = Path.Combine(bench.Links, "PhotoCraft.lnk");
        File.Copy(Path.Combine(root, "PhotoCraft.lnk"), bench.Photo);
        bench.Busy = Path.Combine(root, name + "-installer-busy");
        bench.Sessions = Path.Combine(root, name + "-installer-sessions.json");
        bench.Fixture = new FixtureConfig { ShortcutDirectory = new[] { bench.Links }, StateDirectory = bench.State, KeepOpenForAutomation = true,
            AutomaticReconcile = true, InstallerBusyFile = bench.Busy, InstallerLogFile = bench.Sessions };
        Apply(source, bench.Fixture);
        File.WriteAllText(Path.Combine(bench.State, "tray-preferences.json"), json.Serialize(new Preferences { Theme = Pack, AppliedTheme = Pack, IconSize = 48, Hotkey = new HotkeySettings { Enabled = false } }));
        if (shared) {
            // The shared scope's records, kept in the fixture's own folder, as the scope tests do.
            string manifest = Path.Combine(bench.State, "manifest.json");
            var record = json.Deserialize<Dictionary<string, object>>(System.Text.Encoding.UTF8.GetString(File.ReadAllBytes(manifest)).TrimStart('\uFEFF'));
            record["Scope"] = "AllUsers";
            File.WriteAllText(manifest, json.Serialize(record));
        }
        return bench;
    }
    // A shortcut MailCraft's own install adds while it runs, as the installer's log records it.
    public static string NewMailCraftShortcut(string root, Bench bench, JavaScriptSerializer json)
    {
        string exe = Path.Combine(root, "reapply-apps", "MailCraft", "mailcraft.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(exe));
        if (!File.Exists(exe)) File.Copy(Path.Combine(root, "LaunchProbe.exe"), exe);
        DateTime now = DateTime.UtcNow;
        File.WriteAllText(bench.Sessions, json.Serialize(new[] { new { Start = now.AddMinutes(-2).ToString("o"), End = now.AddMinutes(3).ToString("o"), Names = new[] { @"C:\Fixture\mailcraft-0.42.0-windows-x64.msi" } } }));
        string path = Path.Combine(bench.Links, "MailCraft.lnk");
        WriteShortcut(path, exe, "", null, null);
        File.SetCreationTimeUtc(path, now.AddSeconds(-10)); File.SetLastWriteTimeUtc(path, now.AddSeconds(-10));
        return path;
    }
    public static bool Running(LauncherForm form)
    {
        Task task = (Task)Field(form, "reapplyTask");
        return (bool)Field(form, "busy") || (bool)Field(form, "sharedRunning") || (task != null && !task.IsCompleted);
    }
    // Shortcut events from BetterIcon's own writes are ignored for ten seconds after a check.
    public static void WaitQuiet(LauncherForm form) { WaitFor(() => !Running(form) && DateTime.UtcNow > (DateTime)Field(form, "ownWritesUntil"), 40); }
    public static void Overflow(LauncherForm form) { Call(form, "OnWatcherError", null, new ErrorEventArgs(new InternalBufferOverflowException())); }
    public static void WithForm(string source, FixtureConfig fixture, Action<LauncherForm> body)
    {
        Exception failure = null;
        using (EventWaitHandle show = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (EventWaitHandle stop = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (LauncherForm form = new LauncherForm(source, fixture, true, show, stop))
        using (LauncherContext context = new LauncherContext(form))
        using (System.Windows.Forms.Timer ready = new System.Windows.Forms.Timer { Interval = 50 }) {
            ready.Tick += delegate {
                if ((bool)Field(form, "busy") || Field(form, "catalog") == null) return;
                ready.Stop();
                try {
                    body(form);
                    // Let a running check finish, so no helper writes after the window closes.
                    WaitFor(() => !Running(form), 60);
                    stop.Set();
                }
                catch (Exception error) { failure = error; context.ExitThread(); }
            };
            ready.Start(); Application.Run(context);
            if (failure != null) throw failure;
        }
    }
    static ToolStripMenuItem MenuItem(LauncherForm form, string name)
    {
        return ((ContextMenuStrip)Field(form, "trayMenu")).Items.OfType<ToolStripMenuItem>().FirstOrDefault(item => item.Name == name || item.Text == name);
    }
    static void ClickLink(LinkLabel link) { typeof(LinkLabel).GetMethod("OnLinkClicked", Instance).Invoke(link, new object[] { new LinkLabelLinkClickedEventArgs(link.Links[0]) }); }
    // Apply icons with the current user's locations, answering each dialog, while noting whether Apply waited for a check.
    static bool ApplyDuringCheck(LauncherForm form)
    {
        Exception failure = null; bool waited = false;
        Label status = (Label)Field(form, "status");
        DateTime deadline = DateTime.UtcNow.AddSeconds(90);
        using (System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 25 }) {
            timer.Tick += delegate {
                if (status.Text == "Finishing a check for app updates...") waited = true;
                Form dialog = Application.OpenForms.Cast<Form>().FirstOrDefault(window => window != form && window.Owner == form && window.Visible);
                try {
                    if (DateTime.UtcNow > deadline) throw new Exception("Timed out applying during a background check.");
                    if (dialog == null) return;
                    ShortcutScopeDialog choice = dialog as ShortcutScopeDialog;
                    if (choice != null) choice.Controls.Find("CurrentUserChoice", true).OfType<Button>().Single().PerformClick();
                    else if (dialog.Text == "Review icon changes" || dialog.Text == "Operation results") dialog.DialogResult = DialogResult.OK;
                    else throw new Exception("Unexpected dialog: " + dialog.Text);
                }
                catch (Exception error) { failure = error; if (dialog != null) dialog.DialogResult = DialogResult.Cancel; }
            };
            timer.Start();
            Task task = (Task)Call(form, "ApplyTheme");
            while (!task.IsCompleted && DateTime.UtcNow < deadline.AddSeconds(2)) { if (status.Text == "Finishing a check for app updates...") waited = true; Application.DoEvents(); Thread.Sleep(10); }
            timer.Stop();
            if (failure != null) throw failure;
            if (!task.IsCompleted) throw new Exception("Apply did not finish.");
            task.GetAwaiter().GetResult();
        }
        return waited;
    }
    public static void Run(string root, string source, JavaScriptSerializer json, Action<bool, string> check)
    {
        string scopeTrace = Path.Combine(root, "scope-choice-state");
        check(Events(scopeTrace, "Shown") + Events(scopeTrace, "Activated") > 0 && Events(scopeTrace, Started) == 0, "Without the fixture switch no background check runs");

        // The status line's wording: the verb follows the number of apps, "shortcut" the number of shortcuts,
        // and "put back" is said only of shortcuts an update replaced, never of new ones.
        Func<string, object[], string> text = (name, arguments) => (string)typeof(LauncherForm).GetMethod(name, BindingFlags.Static | BindingFlags.NonPublic).Invoke(null, arguments);
        Func<string, string, string, ResultItem> pending = (app, change, path) => new ResultItem { Shortcut = path, Application = app, Change = change, Scope = "AllUsers", Status = "NeedsAdministrator" };
        ResultItem[] twoNew = { pending("MailCraft", "New", @"C:\Fixture\Start\MailCraft.lnk"), pending("MailCraft", "New", @"C:\Fixture\Desktop\MailCraft.lnk") };
        ResultItem[] twoUpdated = { pending("PhotoCraft", "Updated", @"C:\Fixture\Start\PhotoCraft.lnk"), pending("PhotoCraft", "Updated", @"C:\Fixture\Desktop\PhotoCraft.lnk") };
        ResultItem[] both = { pending("PhotoCraft", "Updated", @"C:\Fixture\Start\PhotoCraft.lnk"), pending("MailCraft", "New", @"C:\Fixture\Start\MailCraft.lnk") };
        check(text("NewShortcutText", new object[] { twoNew }) == "MailCraft has new shortcuts. BetterIcon gave them your pack's icon." &&
            text("NewShortcutText", new object[] { new[] { twoNew[0] } }) == "MailCraft has a new shortcut. BetterIcon gave it your pack's icon." &&
            text("SharedWaitingText", new object[] { twoNew }) == "MailCraft has new shared shortcuts. They need administrator access to show your icon." &&
            text("SharedWaitingText", new object[] { twoUpdated }) == "PhotoCraft was updated. Its shared shortcuts need administrator access to show your icon again." &&
            text("SharedWaitingText", new object[] { both }) == "Shared shortcuts of PhotoCraft and MailCraft need administrator access to show your icons." &&
            text("SharedDoneText", new object[] { 2, false }) == "Icons put back on 2 shared shortcuts." && text("SharedDoneText", new object[] { 2, true }) == "Your icons are now on 2 shared shortcuts.",
            "Notices count apps and shortcuts apart, and say put back only of shortcuts an update replaced");

        Bench a = Prepare(root, source, "reapply-a", json, false);
        FakeMsiUpdate(a.Photo);
        WithForm(source, a.Fixture, form => {
            Label status = (Label)Field(form, "status");
            bool done = WaitFor(() => Events(a.State, Finished) >= 1 && !Running(form), 90);
            check(done && Themed(a, a.Photo) && !form.Visible && form.OwnedForms.Length == 0 && status.Text == "PhotoCraft was updated. BetterIcon put its icon back." && Events(a.State, "Elevation requested") == 0,
                "At start an updated shortcut gets its icon back with no window, dialog or prompt");
            WaitQuiet(form);
            int finished = Events(a.State, Finished);
            FakeMsiUpdate(a.Photo);
            check(WaitFor(() => Events(a.State, Finished) > finished && !Running(form) && Themed(a, a.Photo), 30), "A shortcut replaced while BetterIcon runs gets its icon back after the quiet period");
            WaitQuiet(form);
            int starts = Events(a.State, Started); finished = Events(a.State, Finished);
            for (int i = 0; i < 5; i++) { FakeMsiUpdate(a.Photo); Pump(0.35); }
            bool settled = WaitFor(() => Events(a.State, Finished) > finished && !Running(form), 40);
            Pump(7);
            check(settled && Events(a.State, Started) - starts == 1 && Themed(a, a.Photo), "A burst of shortcut changes leads to one check");
            WaitQuiet(form);
            starts = Events(a.State, Started);
            Overflow(form);
            check(WaitFor(() => Events(a.State, Started) > starts, 15) && Events(a.State, "Shortcut watcher error") >= 1, "A watcher overflow schedules a full check");
            WaitFor(() => !Running(form), 60); WaitQuiet(form);
            File.WriteAllText(a.Busy, "Windows Installer is running");
            starts = Events(a.State, Started);
            FakeMsiUpdate(a.Photo);
            Pump(15);
            bool waited = Events(a.State, Started) == starts;
            File.Delete(a.Busy);
            bool resumed = WaitFor(() => Events(a.State, Started) > starts, 20);
            WaitFor(() => !Running(form), 60);
            check(waited && resumed, "No check runs while an installer is busy, and one runs when it finishes");
            // Three re-applies in a day are already behind this shortcut: the fourth is not made.
            check(!Themed(a, a.Photo) && status.Text == "PhotoCraft's shortcut keeps changing back. BetterIcon stopped putting its icon back; choose Apply icons to try again.",
                "After three re-applies in a day a shortcut that keeps changing back is left alone, and the status says so");
            WaitQuiet(form);
            // A day later those three tries are no longer recent. The notice said BetterIcon stopped, so it still does.
            bool stillAlone = false;
            try {
                object store = Field(form, "reapplyStore");
                ReapplyStateData data = (ReapplyStateData)store.GetType().GetField("Data").GetValue(store);
                ReapplyItem tried = data.Items["CurrentUser|" + a.Photo.ToLowerInvariant()];
                tried.Attempts = tried.Attempts.Select(attempt => DateTime.Parse(attempt, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.RoundtripKind).ToUniversalTime().AddHours(-25).ToString("o")).ToList();
                int seen = Events(a.State, Finished);
                FakeMsiUpdate(a.Photo);
                stillAlone = WaitFor(() => Events(a.State, Finished) > seen && !Running(form), 40) && !Themed(a, a.Photo);
            }
            catch (Exception error) { Console.WriteLine("The next day's check failed: " + error.GetBaseException().Message); }
            check(stillAlone, "A shortcut that kept changing back stays alone the next day too, until Apply icons");
            WaitQuiet(form);
            finished = Events(a.State, Finished);
            string mail = NewMailCraftShortcut(root, a, json);
            check(WaitFor(() => Events(a.State, Finished) > finished && !Running(form) && Themed(a, mail), 40) && !form.Visible && form.OwnedForms.Length == 0 &&
                status.Text == "MailCraft has a new shortcut. BetterIcon gave it your pack's icon.", "A new ArtCraft shortcut that its app's own install adds gets the applied pack's icon with no window or prompt");
        });

        Bench b = Prepare(root, source, "reapply-b", json, false);
        string preferences = Path.Combine(b.State, "tray-preferences.json");
        WithForm(source, b.Fixture, form => {
            WaitFor(() => Events(b.State, Started) >= 1, 60);
            byte[] before = File.ReadAllBytes(preferences);
            bool done = WaitFor(() => Events(b.State, Finished) >= 1 && !Running(form), 60);
            check(done && File.ReadAllBytes(preferences).SequenceEqual(before) && !File.Exists(Path.Combine(b.State, "reapply-state.json")), "A background check that finds nothing writes no preferences");
            // BetterIcon changes shortcuts after updates without a review, so the line speaks only of the buttons.
            check(((Label)Field(form, "status")).Text == "Apply and Restore show each change first.", "The status line under the buttons says only what Apply and Restore do");
            WaitQuiet(form);
            string imageres = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "imageres.dll");
            int finished = Events(b.State, Finished);
            BetterIcon.Windows.ShellLink.SetIcon(b.Photo, imageres);
            File.SetLastWriteTimeUtc(b.Photo, DateTime.UtcNow.AddMinutes(-1));
            bool seen = WaitFor(() => Events(b.State, Finished) > finished && !Running(form), 40);
            AppEntry[] entries = ((Catalog)Field(form, "catalog")).Apps;
            int index = Array.FindIndex(entries, entry => String.Equals(entry.Shortcut, b.Photo, StringComparison.OrdinalIgnoreCase));
            IList sources = (IList)Field(form, "appSources");
            string shown = index < 0 || index >= sources.Count ? "" : (string)sources[index].GetType().GetField("Path").GetValue(sources[index]);
            check(seen && index >= 0 && entries[index].Change == "Custom" && String.Equals(shown, imageres, StringComparison.OrdinalIgnoreCase), "Changed and custom shortcuts show their own icon in the Launcher");
            check(((Label)Field(form, "status")).Text == "PhotoCraft's shortcut was changed outside BetterIcon. BetterIcon left it as it is.", "A shortcut given another icon is reported on the status line");
        });

        Bench c = Prepare(root, source, "reapply-c", json, false);
        FakeMsiUpdate(c.Photo);
        bool stoppedDuringCheck = false; double stopSeconds = -1;
        using (EventWaitHandle show = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (EventWaitHandle stop = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (EventWaitHandle installStop = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (LauncherForm form = new LauncherForm(source, c.Fixture, true, show, stop, installStop))
        using (LauncherContext context = new LauncherContext(form))
        using (System.Windows.Forms.Timer ready = new System.Windows.Forms.Timer { Interval = 25 }) {
            Stopwatch clock = null;
            DateTime giveUp = DateTime.UtcNow.AddSeconds(120);
            ready.Tick += delegate {
                Task task = (Task)Field(form, "reapplyTask");
                if (DateTime.UtcNow > giveUp) { ready.Stop(); context.ExitThread(); return; }
                if (task == null || task.IsCompleted || Events(c.State, Started) < 1) return;
                ready.Stop();
                stoppedDuringCheck = true;
                clock = Stopwatch.StartNew();
                installStop.Set();
            };
            ready.Start(); Application.Run(context);
            if (clock != null) stopSeconds = clock.Elapsed.TotalSeconds;
        }
        check(stoppedDuringCheck && stopSeconds >= 0 && stopSeconds < 5, "Setup can stop BetterIcon during a background check");

        Bench g = Prepare(root, source, "reapply-g", json, false);
        FakeMsiUpdate(g.Photo);
        File.SetAttributes(g.Photo, FileAttributes.ReadOnly);
        bool refusedOnce = false;
        WithForm(source, g.Fixture, form => {
            Label status = (Label)Field(form, "status");
            bool done = WaitFor(() => Events(g.State, Finished) >= 1 && !Running(form), 90);
            bool told = status.Text == "Windows refused to let BetterIcon change PhotoCraft's shortcut, so it keeps the app's icon. BetterIcon won't try again until that shortcut changes.";
            status.Text = "Marker";
            WaitQuiet(form);
            int finished = Events(g.State, Finished);
            Overflow(form);
            refusedOnce = done && told && WaitFor(() => Events(g.State, Finished) > finished && !Running(form), 30) && status.Text == "Marker" && !Themed(g, g.Photo);
        });
        WithForm(source, g.Fixture, form => {
            bool skipped = WaitFor(() => Events(g.State, Finished) >= 3 && !Running(form), 90) && Events(g.State, "Reapply started (skip 1)") >= 2 && !Themed(g, g.Photo);
            WaitQuiet(form);
            int finished = Events(g.State, Finished);
            File.SetAttributes(g.Photo, FileAttributes.Normal);
            FakeMsiUpdate(g.Photo);
            check(refusedOnce && skipped && WaitFor(() => Events(g.State, Finished) > finished && !Running(form) && Themed(g, g.Photo), 40), "A refused shortcut is reported once and not retried until it changes");
            WaitQuiet(form);
            int starts = Events(g.State, Started);
            FakeMsiUpdate(g.Photo);
            bool checking = WaitFor(() => Events(g.State, Started) > starts && Running(form), 30);
            bool waited = ApplyDuringCheck(form);
            Label status = (Label)Field(form, "status");
            check(checking && waited && status.Text.StartsWith("Theme applied") && Themed(g, g.Photo), "Apply waits for a running background check instead of failing on the state lock");
        });

        // BetterIcon's saved icon is gone: the record follows the update, the user is told once, and later checks
        // skip that shortcut until it changes, so a shared one would not start an administrator pass every time.
        Bench h = Prepare(root, source, "reapply-h", json, false);
        foreach (string icon in Directory.GetFiles(Path.Combine(h.State, "icons"))) File.Delete(icon);
        FakeMsiUpdate(h.Photo);
        WithForm(source, h.Fixture, form => {
            Label status = (Label)Field(form, "status");
            bool done = WaitFor(() => Events(h.State, Finished) >= 1 && !Running(form), 90);
            bool told = status.Text == "BetterIcon's saved icon for PhotoCraft is missing. Choose Apply icons to pick it again.";
            status.Text = "Marker";
            WaitQuiet(form);
            int finished = Events(h.State, Finished);
            Overflow(form);
            bool skipped = WaitFor(() => Events(h.State, Finished) > finished && !Running(form), 30) && Events(h.State, "Reapply started (skip 1)") >= 1;
            check(done && told && skipped && status.Text == "Marker" && !Themed(h, h.Photo), "A missing saved icon is reported once and not tried again until that shortcut changes");
        });

        Bench d = Prepare(root, source, "reapply-d", json, true);
        FakeMsiUpdate(d.Photo);
        WithForm(source, d.Fixture, form => {
            Label status = (Label)Field(form, "status");
            bool found = WaitFor(() => Events(d.State, Finished) >= 1 && !Running(form), 90);
            form.ShowManager(); ((TabControl)Field(form, "pages")).SelectedIndex = 1; Pump(0.5);
            Control row = (Control)Field(form, "sharedActions");
            check(found && row.Visible && MenuItem(form, "SharedReapplyItem") != null && Events(d.State, "Elevation requested") == 0 &&
                status.Text == "PhotoCraft was updated. Its shared shortcut needs administrator access to show your icon again.",
                "Shared shortcuts that need administrator access show one action and nothing asks for elevation by itself");
            bool offeredNot = MenuItem(form, "AutomaticSharedItem") == null;
            d.Fixture.SilentElevation = true; Call(form, "BuildTrayMenu");
            ToolStripMenuItem automatic = MenuItem(form, "AutomaticSharedItem");
            bool offered = automatic != null && automatic.Checked && automatic.Text == "Apply icons to shared shortcuts automatically";
            d.Fixture.SilentElevation = false; Call(form, "UpdateSharedActions"); Pump(0.3);
            check(offeredNot && offered && MenuItem(form, "AutomaticSharedItem") == null && row.Visible, "The automatic shared option is offered only where Windows elevates without asking");
            int asks = ExactEvents(d.State, "Elevation requested");
            MenuItem(form, "SharedReapplyItem").PerformClick();
            bool asked = WaitFor(() => ExactEvents(d.State, "Elevation requested") > asks && !Running(form), 20);
            check(asked && ExactEvents(d.State, "Elevation requested") == asks + 1 && status.Text == "Administrator request cancelled. The shared shortcuts keep the apps' own icons for now." &&
                row.Visible && form.OwnedForms.Length == 0, "The shared action asks for elevation once and reports a cancel on the status line");
            LinkLabel notNow = row.Controls.OfType<LinkLabel>().First(link => link.Name == "SharedReapplyNotNow");
            ClickLink(notNow);
            bool hidden = !row.Visible && MenuItem(form, "SharedReapplyItem") == null;
            WaitQuiet(form);
            int finished = Events(d.State, Finished);
            Overflow(form);
            bool stillHidden = WaitFor(() => Events(d.State, Finished) > finished && !Running(form), 30) && !row.Visible;
            WaitQuiet(form);
            finished = Events(d.State, Finished);
            FakeMsiUpdate(d.Photo);
            bool back = WaitFor(() => Events(d.State, Finished) > finished && !Running(form), 30) && row.Visible && MenuItem(form, "SharedReapplyItem") != null;
            check(hidden && stillHidden && back, "Not now hides the shared action until those shortcuts change");
            ClickLink(notNow);
            WaitQuiet(form);
            finished = Events(d.State, Finished);
            NewMailCraftShortcut(root, d, json);
            check(WaitFor(() => Events(d.State, Finished) > finished && !Running(form) && row.Visible, 40) && MenuItem(form, "SharedReapplyItem") != null &&
                status.Text == "MailCraft has a new shared shortcut. It needs administrator access to show your icon.", "A new shared shortcut is offered by the same action, and the notice says it is new");
        });

        Bench e = Prepare(root, source, "reapply-e", json, true);
        e.Fixture.SilentElevation = true; e.Fixture.ElevationProbe = "Allow";
        FakeMsiUpdate(e.Photo);
        WithForm(source, e.Fixture, form => {
            Label status = (Label)Field(form, "status");
            bool handled = WaitFor(() => ExactEvents(e.State, "Elevation requested (automatic)") >= 1 && !Running(form), 90);
            Pump(2);
            check(handled && ExactEvents(e.State, "Elevation requested (automatic)") == 1 && ExactEvents(e.State, "Elevation requested") == 0 && status.Text == "Icon put back on 1 shared shortcut." &&
                form.OwnedForms.Length == 0 && !form.Visible && MenuItem(form, "SharedReapplyItem") == null, "With the automatic shared option on, shared updates are handled without a click or a dialog");
        });
    }
}

// Open at login, with HKCU keys of the fixture's own in place of the Run and StartupApproved\Run keys.
static class LoginItemTests
{
    const string RealRun = @"Software\Microsoft\Windows\CurrentVersion\Run", RealApproved = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
    static object Value(string key, string name)
    {
        using (RegistryKey opened = Registry.CurrentUser.OpenSubKey(key)) return opened == null ? null : opened.GetValue(name);
    }
    // Read only: the user's own login entry for BetterIcon and Windows' Startup apps state for it.
    static string Real()
    {
        return String.Join("|", new[] { RealRun, RealApproved }.Select(key => {
            object value = Value(key, "BetterIcon");
            byte[] bytes = value as byte[];
            return value == null ? "missing" : bytes != null ? BitConverter.ToString(bytes) : value.ToString();
        }));
    }
    static ToolStripMenuItem LoginMenu(LauncherForm form)
    {
        return ((ContextMenuStrip)ReapplyTests.Field(form, "trayMenu")).Items.OfType<ToolStripMenuItem>().FirstOrDefault(item => item.Text == "Open at login");
    }
    static FixtureConfig Fixture(string root, string source, string name, JavaScriptSerializer json, string run, string approved, bool? installed)
    {
        string links = Path.Combine(root, name + "-links"), state = Path.Combine(root, name + "-state");
        Directory.CreateDirectory(links); Directory.CreateDirectory(state);
        if (!File.Exists(Path.Combine(links, "PhotoCraft.lnk"))) File.Copy(Path.Combine(root, "PhotoCraft.lnk"), Path.Combine(links, "PhotoCraft.lnk"));
        string preferences = Path.Combine(state, "tray-preferences.json");
        if (!File.Exists(preferences)) File.WriteAllText(preferences, json.Serialize(new Preferences { Theme = "Craft-Icons-Zach/Cardboard", IconSize = 48, Hotkey = new HotkeySettings { Enabled = false } }));
        return new FixtureConfig { ShortcutDirectory = new[] { links }, StateDirectory = state, KeepOpenForAutomation = true, InstalledCopy = installed,
            LoginRunKey = run, LoginApprovedKey = approved, ConfigPath = Path.Combine(root, name + "-fixture.json") };
    }
    static Preferences Saved(FixtureConfig fixture, JavaScriptSerializer json) { return json.Deserialize<Preferences>(File.ReadAllText(Path.Combine(fixture.StateDirectory, "tray-preferences.json"))); }
    public static void Run(string root, string source, JavaScriptSerializer json, Action<bool, string> check)
    {
        string real = Real();
        string key = @"Software\BetterIcon-Fixtures\login-" + Guid.NewGuid().ToString("N");
        string run = key + @"\Run", approved = key + @"\StartupApproved\Run";
        byte[] disabled = { 3, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8 };
        try {
            FixtureConfig installed = Fixture(root, source, "login-installed", json, run, approved, true);
            string expected = "\"" + Application.ExecutablePath + "\" --tray --source-folder \"" + source + "\" --config \"" + installed.ConfigPath + "\"";
            bool turnedOff = false;
            ReapplyTests.WithForm(source, installed, form => {
                check(expected.Equals(Value(run, "BetterIcon") as string, StringComparison.OrdinalIgnoreCase) && Saved(installed, json).OpenAtLogin == true &&
                    ReapplyTests.ExactEvents(installed.StateDirectory, "Login entry written") == 1 && LoginMenu(form) != null && LoginMenu(form).Checked && !form.Visible,
                    "A Setup install with no saved choice opens at login, hidden in the tray");
                using (RegistryKey state = Registry.CurrentUser.CreateSubKey(approved)) state.SetValue("BetterIcon", disabled, RegistryValueKind.Binary);
                ReapplyTests.Call(form, "BuildTrayMenu");
                bool off = !LoginMenu(form).Checked;
                using (RegistryKey state = Registry.CurrentUser.OpenSubKey(approved, true)) state.DeleteValue("BetterIcon", false);
                ReapplyTests.Call(form, "BuildTrayMenu");
                check(off && LoginMenu(form).Checked, "Open at login in the tray menu shows a choice made in Windows Startup apps");
                LoginMenu(form).PerformClick();
                Label status = (Label)ReapplyTests.Field(form, "status");
                turnedOff = Value(run, "BetterIcon") == null && Saved(installed, json).OpenAtLogin == false && status.Text == "BetterIcon won't open at login." && !LoginMenu(form).Checked;
            });
            ReapplyTests.WithForm(source, installed, form => {
                check(turnedOff && Value(run, "BetterIcon") == null && !LoginMenu(form).Checked && ReapplyTests.ExactEvents(installed.StateDirectory, "Login entry written") == 1,
                    "Turning Open at login off removes the entry, and the next start does not add it back");
                using (RegistryKey state = Registry.CurrentUser.CreateSubKey(approved)) state.SetValue("BetterIcon", disabled, RegistryValueKind.Binary);
                LoginMenu(form).PerformClick();
                Label status = (Label)ReapplyTests.Field(form, "status");
                check(expected.Equals(Value(run, "BetterIcon") as string, StringComparison.OrdinalIgnoreCase) && Value(approved, "BetterIcon") == null && LoginMenu(form).Checked &&
                    Saved(installed, json).OpenAtLogin == true && status.Text == "BetterIcon will open at login, in the tray.", "Turning Open at login on clears a Windows-disabled state");
            });
            FixtureConfig copied = Fixture(root, source, "login-copy", json, key + @"\CopyRun", key + @"\CopyApproved", false);
            ReapplyTests.WithForm(source, copied, form => {
                check(Value(key + @"\CopyRun", "BetterIcon") == null && Saved(copied, json).OpenAtLogin == null && LoginMenu(form) != null && !LoginMenu(form).Checked,
                    "A copy that Setup did not install does not add a login entry by itself");
            });
            FixtureConfig plain = Fixture(root, source, "login-none", json, null, null, true);
            ReapplyTests.WithForm(source, plain, form => {
                check(LoginMenu(form) == null && Saved(plain, json).OpenAtLogin == null && Real() == real, "Fixture mode without a login key leaves the real login entries untouched");
            });
            // An entry left by a copy of BetterIcon that is gone, such as a ZIP folder deleted after Setup installed BetterIcon.
            string goneFolder = Path.Combine(root, "gone-copy");
            string gone = "\"" + Path.Combine(goneFolder, "BetterIcon-Tray.exe") + "\" --tray --source-folder \"" + goneFolder + "\"";
            FixtureConfig zip = Fixture(root, source, "login-gone", json, key + @"\GoneRun", key + @"\GoneApproved", false);
            string zipExpected = "\"" + Application.ExecutablePath + "\" --tray --source-folder \"" + source + "\" --config \"" + zip.ConfigPath + "\"";
            using (RegistryKey entry = Registry.CurrentUser.CreateSubKey(key + @"\GoneRun")) entry.SetValue("BetterIcon", gone, RegistryValueKind.String);
            ReapplyTests.WithForm(source, zip, form => {
                bool shownOff = LoginMenu(form) != null && !LoginMenu(form).Checked;
                if (LoginMenu(form) != null) LoginMenu(form).PerformClick();
                check(shownOff && zipExpected.Equals(Value(key + @"\GoneRun", "BetterIcon") as string, StringComparison.OrdinalIgnoreCase) && LoginMenu(form) != null && LoginMenu(form).Checked,
                    "Open at login shows off when its entry starts a copy of BetterIcon that is gone, and one click points it at this copy");
            });
            FixtureConfig takeover = Fixture(root, source, "login-takeover", json, key + @"\TakeoverRun", key + @"\TakeoverApproved", true);
            // This account chose Open at login in that copy, which keeps its preferences where this one does.
            Preferences chosen = Saved(takeover, json); chosen.OpenAtLogin = true;
            File.WriteAllText(Path.Combine(takeover.StateDirectory, "tray-preferences.json"), json.Serialize(chosen));
            using (RegistryKey entry = Registry.CurrentUser.CreateSubKey(key + @"\TakeoverRun")) entry.SetValue("BetterIcon", gone, RegistryValueKind.String);
            string takeoverExpected = "\"" + Application.ExecutablePath + "\" --tray --source-folder \"" + source + "\" --config \"" + takeover.ConfigPath + "\"";
            ReapplyTests.WithForm(source, takeover, form => {
                check(takeoverExpected.Equals(Value(key + @"\TakeoverRun", "BetterIcon") as string, StringComparison.OrdinalIgnoreCase) && LoginMenu(form) != null && LoginMenu(form).Checked &&
                    ReapplyTests.ExactEvents(takeover.StateDirectory, "Login entry written") == 0, "Setup's copy points a login entry that starts a copy of BetterIcon that is gone at itself");
            });
            check(Real() == real, "The login checks leave the real login entries untouched");
        }
        finally {
            Registry.CurrentUser.DeleteSubKeyTree(key, false);
            // Leave no empty parent key behind when this was the only fixture.
            const string fixtures = @"Software\BetterIcon-Fixtures";
            bool empty;
            using (RegistryKey parent = Registry.CurrentUser.OpenSubKey(fixtures)) empty = parent != null && parent.SubKeyCount == 0 && parent.ValueCount == 0;
            if (empty) Registry.CurrentUser.DeleteSubKey(fixtures, false);
        }
    }
}

// Background behavior the review of the checks after app updates found wrong or untested: shortcut events while
// BetterIcon is busy, retries that wait longer, the shared action's last word, the automatic option's menu item,
// notices of one check, the status tooltip and file icon notices. Each check catches its own failure, so a run
// against an earlier build reports every one of them.
static class ReapplyFixTests
{
    const BindingFlags Instance = BindingFlags.Instance | BindingFlags.NonPublic;
    const string Finished = "Reapply finished", SharedBusy = "Putting your icons back on shared shortcuts...";
    const string Refused = "Windows refused to let BetterIcon change PhotoCraft's shortcut, so it keeps the app's icon. BetterIcon won't try again until that shortcut changes.";
    const string FilesChanged = "The icon for PhotoCraft files was changed outside BetterIcon. BetterIcon left it as it is.";
    static object Field(LauncherForm form, string name) { return ReapplyTests.Field(form, name); }
    static object Call(LauncherForm form, string name, params object[] arguments) { return ReapplyTests.Call(form, name, arguments); }
    static void SetField(LauncherForm form, string name, object value) { typeof(LauncherForm).GetField(name, Instance).SetValue(form, value); }
    static ToolStripMenuItem MenuItem(LauncherForm form, string name)
    {
        return ((ContextMenuStrip)Field(form, "trayMenu")).Items.OfType<ToolStripMenuItem>().FirstOrDefault(item => item.Name == name || item.Text == name);
    }
    static void ClickLink(LinkLabel link) { typeof(LinkLabel).GetMethod("OnLinkClicked", Instance).Invoke(link, new object[] { new LinkLabelLinkClickedEventArgs(link.Links[0]) }); }
    // Seconds until the next check is due, on the wall clock an earlier build used or on the steady clock; null when none is.
    static double? DueIn(LauncherForm form)
    {
        object due = Field(form, "reconcileDue");
        if (due == null) return null;
        if (due is DateTime) return ((DateTime)due - DateTime.UtcNow).TotalSeconds;
        Stopwatch clock = (Stopwatch)typeof(LauncherForm).GetField("reapplyClock", BindingFlags.Static | BindingFlags.NonPublic).GetValue(null);
        return ((TimeSpan)due - clock.Elapsed).TotalSeconds;
    }
    static bool Near(double? value, double seconds) { return value.HasValue && value.Value > seconds - 10 && value.Value <= seconds + 1; }
    // A reply handled the way a check handles it: the notices it returns go on the status line.
    static void Reply(LauncherForm form, params ResultItem[] rows)
    {
        object notices = Call(form, "HandleReapplyReply", new WorkerReply { Success = true, Results = rows });
        if (notices != null) Call(form, "ShowNotices", notices);
    }
    static ResultItem Row(string shortcut, string status, string scope, string hash, string message)
    {
        return new ResultItem { Shortcut = shortcut, Status = status, Scope = scope, Application = "PhotoCraft", Change = "", Hash = hash, Message = message, Detail = "" };
    }
    static void Try(Action<bool, string> check, string name, Func<bool> body)
    {
        bool ok;
        try { ok = body(); }
        catch (Exception error) { Console.WriteLine("Error in '" + name + "': " + error.GetBaseException().Message); ok = false; }
        check(ok, name);
    }
    // Every text the status line showed while the action ran.
    static List<string> Watch(Label status, Action action)
    {
        var texts = new List<string>();
        EventHandler record = delegate { texts.Add(status.Text); };
        status.TextChanged += record;
        try { action(); }
        finally { status.TextChanged -= record; }
        return texts;
    }
    // A fresh check, after which the shared action is offered again. The tray item shows the offer whether or not
    // the window is open; the row under the status line counts as visible only in an open window.
    static bool Offer(LauncherForm form, ReapplyTests.Bench bench, Control row)
    {
        int finished = ReapplyTests.Events(bench.State, Finished);
        ReapplyTests.Overflow(form);
        return ReapplyTests.WaitFor(() => ReapplyTests.Events(bench.State, Finished) > finished && !ReapplyTests.Running(form) && MenuItem(form, "SharedReapplyItem") != null &&
            (!form.Visible || row.Visible), 40);
    }
    static void ClickShared(LauncherForm form)
    {
        MenuItem(form, "SharedReapplyItem").PerformClick();
        ReapplyTests.WaitFor(() => !ReapplyTests.Running(form), 20);
    }
    // The fixture's own file icon store: the tray keeps it beside its state and uses a disposable hive for it.
    static string FileIconHive(string state)
    {
        string directory = Path.Combine(state, "project-file-icons");
        using (System.Security.Cryptography.SHA256 sha = System.Security.Cryptography.SHA256.Create())
            return @"Software\BetterIcon-Fixtures\" + BitConverter.ToString(sha.ComputeHash(System.Text.Encoding.UTF8.GetBytes(directory))).Replace("-", "");
    }
    static void SetHive(string hive, string path, string value)
    {
        using (RegistryKey key = Registry.CurrentUser.CreateSubKey(hive + @"\Classes\" + path)) key.SetValue("", value, RegistryValueKind.String);
    }
    static string GetHive(string hive, string path)
    {
        using (RegistryKey key = Registry.CurrentUser.OpenSubKey(hive + @"\Classes\" + path)) return key == null ? null : key.GetValue("") as string;
    }
    static void RemoveHive(string hive)
    {
        Registry.CurrentUser.DeleteSubKeyTree(hive, false);
        const string fixtures = @"Software\BetterIcon-Fixtures";
        bool empty;
        using (RegistryKey parent = Registry.CurrentUser.OpenSubKey(fixtures)) empty = parent != null && parent.SubKeyCount == 0 && parent.ValueCount == 0;
        if (empty) Registry.CurrentUser.DeleteSubKey(fixtures, false);
    }
    static void WriteFileIconBackup(string state, string target, string applied, ProjectIconValue original, JavaScriptSerializer json)
    {
        string directory = Path.Combine(state, "project-file-icons");
        Directory.CreateDirectory(directory);
        File.WriteAllText(Path.Combine(directory, target.Replace('\\', '+') + ".json"), json.Serialize(new ProjectIconBackup { Target = target, Original = original, Applied = applied }));
    }

    public static void Run(string root, string source, JavaScriptSerializer json, Action<bool, string> check)
    {
        Events(root, source, json, check);
        Shared(root, source, json, check);
        Automatic(root, source, json, check);
        Notices(root, source, json, check);
        FileIcons(root, source, json, check);
    }

    static void Events(string root, string source, JavaScriptSerializer json, Action<bool, string> check)
    {
        ReapplyTests.Bench a = ReapplyTests.Prepare(root, source, "fix-events", json, false);
        ReapplyTests.WithForm(source, a.Fixture, form => {
            Label status = (Label)Field(form, "status");
            ReapplyTests.WaitFor(() => ReapplyTests.Events(a.State, Finished) >= 1 && !ReapplyTests.Running(form), 90);
            // An earlier build ignored shortcut events for ten seconds after every check.
            Try(check, "An app update that lands just after a check is still checked", () => {
                ReapplyTests.FakeMsiUpdate(a.Photo);
                return ReapplyTests.WaitFor(() => ReapplyTests.Themed(a, a.Photo) && !ReapplyTests.Running(form), 30);
            });
            ReapplyTests.WaitQuiet(form);
            Try(check, "An app update that lands while BetterIcon is busy is checked once it is done", () => {
                Call(form, "SetBusy", true, "Fixture operation...");
                try { ReapplyTests.FakeMsiUpdate(a.Photo); ReapplyTests.Pump(1.5); }
                finally { Call(form, "SetBusy", false, null); }
                return ReapplyTests.WaitFor(() => ReapplyTests.Themed(a, a.Photo) && !ReapplyTests.Running(form), 30);
            });
            ReapplyTests.WaitQuiet(form);
            Try(check, "A shortcut that stays in flux is checked less and less often, then left to its next change", () => {
                ResultItem stuck = Row(a.Photo, "InFlux", "CurrentUser", "0123", "Being updated. BetterIcon tries again later.");
                var due = new List<double?>();
                for (int i = 0; i < 5; i++) { SetField(form, "reconcileDue", null); Reply(form, stuck); due.Add(DueIn(form)); }
                SetField(form, "reconcileDue", null);
                Console.WriteLine("Retries after answers of in flux, in seconds: " + String.Join(", ", due.Select(value => value.HasValue ? value.Value.ToString("0") : "none")));
                return Near(due[0], 60) && Near(due[1], 120) && Near(due[2], 300) && Near(due[3], 900) && !due[4].HasValue;
            });
            Try(check, "A damaged record is reported even after another kind of read error was", () => {
                Reply(form, Row("", "Unreadable", "CurrentUser", "", "Cannot lock state directory 'fixture'. Another operation may be running, or the directory is not writable."));
                status.Text = "Marker";
                Reply(form, Row("", "Unreadable", "CurrentUser", "", "Cannot read the backup manifest. Nothing was changed. Invalid file digest."));
                return status.Text == "BetterIcon couldn't read its record of changed shortcuts. Nothing was changed.";
            });
            Try(check, "A shared shortcut set back by hand is written down once, not at every check", () => {
                string preferences = Path.Combine(a.State, "tray-preferences.json");
                string shared = Path.Combine(a.Links, "Shared", "PhotoCraft.lnk");
                ResultItem reverted = Row(shared, "Reverted", "AllUsers", "abcd", "Shows the app's own icon again. BetterIcon releases its record at the next administrator pass.");
                Reply(form, reverted);
                Preferences saved = json.Deserialize<Preferences>(File.ReadAllText(preferences));
                bool remembered = (saved.DefaultShortcuts ?? new string[0]).Contains(shared, StringComparer.OrdinalIgnoreCase);
                File.Delete(preferences);
                Reply(form, reverted);
                return remembered && !File.Exists(preferences);
            });
        });
    }

    static void Shared(string root, string source, JavaScriptSerializer json, Action<bool, string> check)
    {
        ReapplyTests.Bench d = ReapplyTests.Prepare(root, source, "fix-shared", json, true);
        ReapplyTests.FakeMsiUpdate(d.Photo);
        ReapplyTests.WithForm(source, d.Fixture, form => {
            Label status = (Label)Field(form, "status");
            bool found = ReapplyTests.WaitFor(() => ReapplyTests.Events(d.State, Finished) >= 1 && !ReapplyTests.Running(form), 90);
            Control row = (Control)Field(form, "sharedActions");
            Try(check, "A hidden BetterIcon shows one balloon for each new set of shared shortcuts", () => {
                int first = ReapplyTests.Events(d.State, "Shared balloon");
                ReapplyTests.WaitQuiet(form);
                bool again = Offer(form, d, row);
                return found && first == 1 && again && ReapplyTests.Events(d.State, "Shared balloon") == 1;
            });
            Try(check, "Clicking a BetterIcon balloon opens Manage Icons", () => {
                typeof(NotifyIcon).GetMethod("OnBalloonTipClicked", Instance).Invoke(Field(form, "tray"), null);
                ReapplyTests.Pump(0.5);
                return form.Visible && ((TabControl)Field(form, "pages")).SelectedIndex == 1;
            });
            Try(check, "A shared pass that finds the shortcuts still being written says so and offers them again soon", () => {
                d.Fixture.ElevationProbe = "InFlux";
                if (!row.Visible && !Offer(form, d, row)) return false;
                List<string> texts = Watch(status, () => ClickShared(form));
                double? due = DueIn(form);
                return texts.Contains(SharedBusy) && status.Text == "The shared shortcuts are still being updated. BetterIcon will offer them again in a minute." && !row.Visible &&
                    due.HasValue && due.Value > 30 && due.Value <= 61;
            });
            Try(check, "A shared pass with nothing to write ends with a word on the status line", () => {
                d.Fixture.ElevationProbe = "None";
                if (!Offer(form, d, row)) return false;
                ClickShared(form);
                return status.Text == "The shared shortcuts need no change." && !row.Visible;
            });
            Try(check, "The shared action shows its busy text while it runs, then how many shortcuts got their icon", () => {
                d.Fixture.ElevationProbe = "Allow";
                if (!Offer(form, d, row)) return false;
                List<string> texts = Watch(status, () => ClickShared(form));
                return texts.Contains(SharedBusy) && status.Text == "Icon put back on 1 shared shortcut." && !row.Visible && MenuItem(form, "SharedReapplyItem") == null;
            });
            Try(check, "Refresh installed apps brings back the shared action that Not now hid", () => {
                if (!Offer(form, d, row)) return false;
                ClickLink(row.Controls.OfType<LinkLabel>().First(link => link.Name == "SharedReapplyNotNow"));
                bool hidden = !row.Visible;
                int finished = ReapplyTests.Events(d.State, Finished);
                Task refresh = (Task)Call(form, "RefreshInstalledApps");
                bool back = ReapplyTests.WaitFor(() => refresh.IsCompleted && ReapplyTests.Events(d.State, Finished) > finished && !ReapplyTests.Running(form) && row.Visible, 60);
                return hidden && back && MenuItem(form, "SharedReapplyItem") != null;
            });
            Try(check, "Apply icons or Restore app defaults for all users takes the shared offer away until a check looks again", () => {
                if (!row.Visible && !Offer(form, d, row)) return false;
                SetField(form, "reconcileDue", null);
                Call(form, "SharedScopeChanged");
                double? due = DueIn(form);
                return !row.Visible && MenuItem(form, "SharedReapplyItem") == null && due.HasValue && due.Value <= 1;
            });
        });
    }

    static void Automatic(string root, string source, JavaScriptSerializer json, Action<bool, string> check)
    {
        ReapplyTests.Bench e = ReapplyTests.Prepare(root, source, "fix-automatic", json, true);
        // Windows elevates without asking, and this time it refuses: the probe is left at its default.
        e.Fixture.SilentElevation = true;
        ReapplyTests.FakeMsiUpdate(e.Photo);
        string preferences = Path.Combine(e.State, "tray-preferences.json");
        ReapplyTests.WithForm(source, e.Fixture, form => {
            Label status = (Label)Field(form, "status");
            bool refused = ReapplyTests.WaitFor(() => ReapplyTests.ExactEvents(e.State, "Elevation requested (automatic)") >= 1 && !ReapplyTests.Running(form), 90);
            Try(check, "After Windows refuses the automatic shared pass, its menu item shows it off for this session", () => {
                ToolStripMenuItem automatic = MenuItem(form, "AutomaticSharedItem");
                bool told = status.Text == "Windows didn't let BetterIcon put the shared icons back by itself. Choose Apply your icons to shared shortcuts... to try again.";
                bool shownOff = automatic != null && !automatic.Checked;
                int asks = ReapplyTests.ExactEvents(e.State, "Elevation requested (automatic)");
                ReapplyTests.WaitQuiet(form);
                int finished = ReapplyTests.Events(e.State, Finished);
                ReapplyTests.Overflow(form);
                bool again = ReapplyTests.WaitFor(() => ReapplyTests.Events(e.State, Finished) > finished && !ReapplyTests.Running(form), 30);
                return refused && told && shownOff && MenuItem(form, "SharedReapplyItem") != null && again && ReapplyTests.ExactEvents(e.State, "Elevation requested (automatic)") == asks;
            });
            ReapplyTests.WaitQuiet(form);
            // From here on another BetterIcon operation holds the shared records whenever the pass runs.
            e.Fixture.ElevationProbe = "Locked";
            int automaticAsks = ReapplyTests.ExactEvents(e.State, "Elevation requested (automatic)");
            Try(check, "One click on the automatic shared option turns it back on", () => {
                ToolStripMenuItem automatic = MenuItem(form, "AutomaticSharedItem");
                if (automatic == null) return false;
                automatic.PerformClick();
                Preferences saved = json.Deserialize<Preferences>(File.ReadAllText(preferences));
                ToolStripMenuItem after = MenuItem(form, "AutomaticSharedItem");
                return saved.AutoReapplyShared == true && !(bool)Field(form, "autoSharedOff") && after != null && after.Checked;
            });
            Try(check, "Another BetterIcon operation holding the shared records does not turn the automatic option off", () => {
                status.Text = "Marker";
                bool tried = ReapplyTests.WaitFor(() => ReapplyTests.ExactEvents(e.State, "Elevation requested (automatic)") > automaticAsks && !ReapplyTests.Running(form), 40);
                double? due = DueIn(form);
                return tried && !(bool)Field(form, "autoSharedOff") && status.Text == "Marker" && due.HasValue && due.Value > 30 && due.Value <= 61;
            });
        });
    }

    static void Notices(string root, string source, JavaScriptSerializer json, Action<bool, string> check)
    {
        ReapplyTests.Bench n = ReapplyTests.Prepare(root, source, "fix-notices", json, false);
        string hive = FileIconHive(n.State);
        try {
            // A file icon someone else changed, and a read-only shortcut an update replaced, found by one check.
            WriteFileIconBackup(n.State, "Photocraft.Document", "\"C:\\fixture\\pack.ico\",0", new ProjectIconValue(), json);
            SetHive(hive, @"Photocraft.Document\DefaultIcon", @"C:\elsewhere\x.ico,0");
            ReapplyTests.FakeMsiUpdate(n.Photo);
            File.SetAttributes(n.Photo, FileAttributes.ReadOnly);
            ReapplyTests.WithForm(source, n.Fixture, form => {
                Label status = (Label)Field(form, "status");
                Try(check, "Notices of one check are shown together, so a refusal is not lost behind a file icon notice", () => {
                    bool done = ReapplyTests.WaitFor(() => ReapplyTests.Events(n.State, Finished) >= 1 && !ReapplyTests.Running(form), 90);
                    string tip = ((ToolTip)Field(form, "appearanceTips")).GetToolTip(status) ?? "";
                    return done && status.Text == Refused && tip.Contains(Refused) && tip.Contains(FilesChanged);
                });
            });
        }
        finally {
            if (File.Exists(n.Photo)) File.SetAttributes(n.Photo, FileAttributes.Normal);
            RemoveHive(hive);
        }
    }

    static void FileIcons(string root, string source, JavaScriptSerializer json, Action<bool, string> check)
    {
        ReapplyTests.Bench f = ReapplyTests.Prepare(root, source, "fix-files", json, false);
        string hive = FileIconHive(f.State);
        const string applied = "\"C:\\fixture\\pack.ico\",0", own = @"C:\fixture\PhotoCraft\photocraft.exe,1";
        try {
            // An app installed for this account only registers its class in the user's own classes. Its update wrote
            // the app's own icon back, the value BetterIcon saved as the original.
            SetHive(hive, @"Photocraft.Document\shell\open\command", "\"C:\\fixture\\PhotoCraft\\photocraft.exe\" \"%1\"");
            SetHive(hive, @"Photocraft.Document\DefaultIcon", own);
            WriteFileIconBackup(f.State, "Photocraft.Document", applied, new ProjectIconValue { Text = own, Kind = RegistryValueKind.String, KeyExisted = true, ParentExisted = true }, json);
            ReapplyTests.WithForm(source, f.Fixture, form => {
                Label status = (Label)Field(form, "status");
                Try(check, "File icons that an update of an app installed for this account set back get the pack's icon again, and the status line says so", () => {
                    bool done = ReapplyTests.WaitFor(() => ReapplyTests.Events(f.State, Finished) >= 1 && !ReapplyTests.Running(form), 90);
                    return done && status.Text == "PhotoCraft files got their icons back after an update." && GetHive(hive, @"Photocraft.Document\DefaultIcon") == applied;
                });
                Try(check, "The status line's tooltip goes away with the notice it belongs to", () => {
                    ToolTip tips = (ToolTip)Field(form, "appearanceTips");
                    string details = "Fixture notice" + Environment.NewLine + "Second line";
                    Call(form, "ShowNotice", "Fixture notice", details);
                    bool shown = tips.GetToolTip(status) == details;
                    Call(form, "SetBusy", true, "Fixture operation...");
                    string during = tips.GetToolTip(status);
                    Call(form, "SetBusy", false, null);
                    return shown && String.IsNullOrEmpty(during);
                });
                ReapplyTests.WaitQuiet(form);
                Try(check, "A shortcut set back to the app's own icon by hand is reported on the status line", () => {
                    int seen = ReapplyTests.Events(f.State, Finished);
                    BetterIcon.Windows.ShellLink.SetIcon(f.Photo, Path.Combine(root, "LaunchProbe.exe"));
                    File.SetLastWriteTimeUtc(f.Photo, DateTime.UtcNow.AddMinutes(-1));
                    bool done = ReapplyTests.WaitFor(() => ReapplyTests.Events(f.State, Finished) > seen && !ReapplyTests.Running(form), 40);
                    return done && status.Text == "PhotoCraft's shortcut shows its own icon again. BetterIcon now treats it as restored.";
                });
            });
        }
        finally { RemoveHive(hive); }
    }
}
