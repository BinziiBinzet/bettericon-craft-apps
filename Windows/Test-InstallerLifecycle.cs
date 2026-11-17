// Isolated native installer protocol checks. All names/configuration are disposable.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using BetterIcon.Tray;

static class InstallerLifecycleTests
{
    [DllImport("user32.dll")] static extern bool EnableWindow(IntPtr window, bool enable);
    [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr window);
    static readonly List<object> checks = new List<object>();
    static void Check(bool value, string name)
    {
        checks.Add(new { Test = name, Passed = value });
        if (!value) throw new Exception(name);
        Console.WriteLine("PASS: " + name);
    }
    static string InstanceName(string config)
    {
        string identity = WindowsIdentity.GetCurrent().User.Value + "|" + Path.GetFullPath(config);
        using (SHA256 sha = SHA256.Create()) return "Local\\BetterIcon.Tray." + BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(identity))).Replace("-", "");
    }
    static Process Start(string executable, string arguments)
    {
        return Process.Start(new ProcessStartInfo(executable, arguments) { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden });
    }
    static int Stop(string executable, string config, out long elapsed, string extra = "")
    {
        Stopwatch watch = Stopwatch.StartNew();
        using (Process child = Start(executable, "--stop-and-wait --config \"" + config + "\" " + extra)) {
            if (!child.WaitForExit(15000)) {
                // Only the helper process just created by this test is eligible.
                child.Kill(); child.WaitForExit(); throw new Exception("The isolated stop helper exceeded its bounded timeout.");
            }
            elapsed = watch.ElapsedMilliseconds; return child.ExitCode;
        }
    }
    sealed class Instance : IDisposable
    {
        readonly Thread thread;
        readonly ManualResetEvent ready = new ManualResetEvent(false), release = new ManualResetEvent(false);
        public readonly ManualResetEvent StopReceived = new ManualResetEvent(false);
        Exception failure;
        public Instance(string config, bool busy, int eventDelay)
        {
            thread = new Thread(delegate() {
                try {
                    bool first;
                    using (Mutex mutex = new Mutex(true, InstanceName(config), out first)) {
                        if (!first) throw new Exception("Fixture singleton collision.");
                        try {
                            ready.Set();
                            if (eventDelay > 0) Thread.Sleep(eventDelay);
                            using (EventWaitHandle stop = new EventWaitHandle(false, EventResetMode.AutoReset, InstanceName(config) + ".InstallStop")) {
                                if (WaitHandle.WaitAny(new WaitHandle[] { stop, release }) == 0) {
                                    StopReceived.Set();
                                    if (busy) release.WaitOne();
                                    else Thread.Sleep(250);
                                }
                            }
                        }
                        finally { mutex.ReleaseMutex(); }
                    }
                }
                catch (Exception error) { failure = error; ready.Set(); }
            });
            thread.IsBackground = true; thread.Start();
            if (!ready.WaitOne(3000)) throw new Exception("Fixture singleton did not start.");
            if (failure != null) throw failure;
        }
        public void Dispose()
        {
            release.Set();
            if (!thread.Join(3000)) throw new Exception("Fixture singleton did not finish.");
            ready.Dispose(); release.Dispose(); StopReceived.Dispose();
            if (failure != null) throw failure;
        }
    }
    static void Pump(int milliseconds)
    {
        Stopwatch watch = Stopwatch.StartNew();
        while (watch.ElapsedMilliseconds < milliseconds) { Application.DoEvents(); Thread.Sleep(5); }
    }
    static void CheckExternalRequests(string root, string source)
    {
        string links = Path.Combine(root, "dialog-links"), state = Path.Combine(root, "dialog-state");
        Directory.CreateDirectory(links); Directory.CreateDirectory(state);
        File.WriteAllText(Path.Combine(state, "tray-preferences.json"), new JavaScriptSerializer().Serialize(new Preferences { Hotkey = new HotkeySettings { Enabled = false } }));
        FixtureConfig fixture = new FixtureConfig { ShortcutDirectory = new[] { links }, StateDirectory = state, KeepOpenForAutomation = true };
        BindingFlags flags = BindingFlags.NonPublic | BindingFlags.Instance;
        using (EventWaitHandle show = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (EventWaitHandle ordinaryStop = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (EventWaitHandle stop = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (LauncherForm form = new LauncherForm(source, fixture, true, show, ordinaryStop, stop)) {
            form.ShowInTaskbar = false; form.Location = new Point(-32000, -32000); form.Show();
            FieldInfo busy = typeof(LauncherForm).GetField("busy", flags);
            FieldInfo exiting = typeof(LauncherForm).GetField("exiting", flags);
            bool unexpectedDialog = false;
            using (System.Windows.Forms.Timer closeUnexpected = new System.Windows.Forms.Timer { Interval = 50 }) {
                closeUnexpected.Tick += delegate {
                    foreach (Form dialog in form.OwnedForms.Where(item => item.Visible && item.Modal).ToArray()) {
                        unexpectedDialog = true; dialog.DialogResult = DialogResult.Cancel;
                    }
                };
                busy.SetValue(form, true); closeUnexpected.Start(); stop.Set(); Pump(400); closeUnexpected.Stop();
                Check(!form.IsDisposed && !(bool)exiting.GetValue(form) && !unexpectedDialog, "An external stop silently refuses an active icon operation");
                busy.SetValue(form, false);
            }
            form.Enabled = false; stop.Set(); Pump(400);
            Check(!form.IsDisposed && !(bool)exiting.GetValue(form), "An external stop preserves a disabled common-dialog owner");
            form.Enabled = true;
            EnableWindow(form.Handle, false);
            try {
                Check(form.Enabled && !IsWindowEnabled(form.Handle), "The common-dialog fixture disables only its native owner window");
                stop.Set(); Pump(400);
                Check(!form.IsDisposed && !(bool)exiting.GetValue(form), "An external stop preserves a native common-dialog owner even when Control.Enabled stays true");
            }
            finally { if (!form.IsDisposed) EnableWindow(form.Handle, true); }
            using (Form editor = new Form { Text = "Disposable unsaved editor", ShowInTaskbar = false, StartPosition = FormStartPosition.Manual, Location = new Point(-32000, -32000) })
            using (TextBox draft = new TextBox { Text = "Unsaved fixture content" })
            using (System.Windows.Forms.Timer inspect = new System.Windows.Forms.Timer { Interval = 50 }) {
                editor.Controls.Add(draft); int ticks = 0; bool retained = false;
                inspect.Tick += delegate {
                    ticks++;
                    if (ticks == 1) stop.Set();
                    if (ticks >= 9) {
                        retained = !form.IsDisposed && !(bool)exiting.GetValue(form) && editor.Visible && editor.Modal && draft.Text == "Unsaved fixture content";
                        inspect.Stop(); editor.DialogResult = DialogResult.Cancel;
                    }
                };
                inspect.Start(); editor.ShowDialog(form); inspect.Stop();
                Check(retained, "An external stop preserves an open modal editor and its unsaved content");
            }
            Pump(300);
            Check(!form.IsDisposed && !(bool)exiting.GetValue(form), "A refused modal stop is not queued to close the app later");
            stop.Set(); Pump(400);
            Check(form.IsDisposed, "A fresh external stop closes an idle launcher gracefully");
        }
    }
    static void CheckLegacy(string root, string source, string helper, string legacy)
    {
        if (String.IsNullOrWhiteSpace(legacy)) return;
        string links = Path.Combine(root, "legacy-links"), state = Path.Combine(root, "legacy-state"), config = Path.Combine(root, "legacy.json");
        Directory.CreateDirectory(links); Directory.CreateDirectory(state);
        JavaScriptSerializer json = new JavaScriptSerializer();
        string preferencesPath = Path.Combine(state, "tray-preferences.json");
        const string pendingTheme = "InstallerFixtureAwaitingCatalog";
        File.WriteAllText(preferencesPath, json.Serialize(new Preferences { Theme = pendingTheme, Hotkey = new HotkeySettings { Enabled = false } }));
        File.WriteAllText(config, json.Serialize(new FixtureConfig { ShortcutDirectory = new[] { links }, StateDirectory = state, KeepOpenForAutomation = true }));
        using (Process child = Start(legacy, "--tray --source-folder \"" + source + "\" --config \"" + config + "\"")) {
            try {
                Stopwatch startup = Stopwatch.StartNew(); bool ready = false, discovered = false;
                while (!child.HasExited && startup.ElapsedMilliseconds < 30000) {
                    try { using (EventWaitHandle signal = EventWaitHandle.OpenExisting(InstanceName(config) + ".Stop")) ready = true; }
                    catch (WaitHandleCannotBeOpenedException) { }
                    try { discovered = json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).Theme != pendingTheme; }
                    catch (IOException) { }
                    if (ready && discovered) break;
                    Thread.Sleep(100);
                }
                Check(ready && discovered && !child.HasExited, "The previous-release launcher finishes discovery under an isolated fixture identity");
                // ReloadLibrary saves the selected theme at the end of discovery;
                // let the final SetBusy(false) complete before testing old shutdown.
                Thread.Sleep(100);
                long elapsed; int result = Stop(helper, config, out elapsed);
                Check(result == 2 && !child.HasExited && elapsed >= 9900 && elapsed < 14000,
                    "The installer refuses an older launcher without the safe event and leaves it running");
                // This disposable legacy fixture has no editors or active work.
                // Explicit ordinary stop is test cleanup, never installer fallback.
                using (Process cleanup = Start(legacy, "--stop --config \"" + config + "\"")) {
                    Check(cleanup.WaitForExit(3000) && cleanup.ExitCode == 0 && child.WaitForExit(3000),
                        "Explicit legacy stop still shuts down the idle disposable fixture");
                }
            }
            finally { if (!child.HasExited) { child.Kill(); child.WaitForExit(); } }
        }
    }
    [STAThread]
    static int Main(string[] args)
    {
        Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
        string root = args[0], source = args[1], failure = null;
        try {
            string helperDirectory = Path.Combine(root, "standalone-helper"); Directory.CreateDirectory(helperDirectory);
            string helper = Path.Combine(helperDirectory, "BetterIcon-InstallerHelper.exe");
            File.Copy(Path.Combine(root, "BetterIcon-Tray.exe"), helper);
            string config = Path.Combine(root, "identity-only-no-config-file.json"); long elapsed;
            Check(Stop(helper, config, out elapsed) == 0 && elapsed < 3000 && !File.Exists(config), "A standalone renamed helper succeeds with no instance or configuration file");
            using (Instance instance = new Instance(config, false, 0)) {
                Check(Stop(helper, config, out elapsed) == 0 && instance.StopReceived.WaitOne(0) && elapsed >= 200, "The helper signals the safe installer event and waits for mutex release");
            }
            using (Instance instance = new Instance(config, false, 600)) {
                Check(Stop(helper, config, out elapsed) == 0 && instance.StopReceived.WaitOne(0) && elapsed >= 600, "The helper handles startup between mutex creation and stop-event creation");
            }
            using (Instance instance = new Instance(config, true, 0)) {
                Check(Stop(helper, Path.Combine(root, "other-identity.json"), out elapsed) == 0 && !instance.StopReceived.WaitOne(0), "Fixture identity prevents a helper from signaling another instance");
                Check(Stop(helper, config, out elapsed) == 2 && instance.StopReceived.WaitOne(0) && elapsed >= 9900 && elapsed < 14000, "A busy owner returns timeout code two without being terminated");
            }
            Check(Stop(helper, config, out elapsed, "--invalid-option") == 1 && elapsed < 3000, "Invalid installer arguments return code one without a blocking error dialog");
            Check(Directory.GetFiles(helperDirectory).Length == 1, "Stopping needs only the executable and writes no helper state");
            CheckExternalRequests(root, source);
            CheckLegacy(root, source, helper, args.Length > 2 ? args[2] : null);
        }
        catch (Exception error) { failure = error.ToString(); Console.Error.WriteLine(failure); }
        File.WriteAllText(Path.Combine(root, "results.json"), new JavaScriptSerializer().Serialize(new { Success = failure == null, Checks = checks, Error = failure }));
        return failure == null ? 0 : 1;
    }
}
