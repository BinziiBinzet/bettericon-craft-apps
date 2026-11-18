using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
#if !FIXTURE_WINDOW
using BetterIcon.Tray;
using System.Web.Script.Serialization;
#endif

static class FixtureProperties
{
    [StructLayout(LayoutKind.Sequential)]
    struct Key { public Guid Format; public uint Id; }
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    struct Value { [FieldOffset(0)] public ushort Type; [FieldOffset(8)] public IntPtr Text; }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        void GetCount(out uint count);
        void GetAt(uint index, out Key key);
        void GetValue(ref Key key, out Value value);
        void SetValue(ref Key key, ref Value value);
        void Commit();
    }
    [DllImport("shell32.dll", PreserveSig = false)]
    static extern void SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);
    [DllImport("ole32.dll")] static extern int PropVariantClear(ref Value value);
    public const uint RelaunchIcon = 3, AppId = 5;
    public static string Access(IntPtr window, uint property, bool write, string text = null)
    {
        Key key = new Key { Format = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), Id = property };
        Guid iid = typeof(IPropertyStore).GUID;
        IPropertyStore store;
        SHGetPropertyStoreForWindow(window, ref iid, out store);
        Value value = new Value();
        try {
            if (write) {
                if (text != null) { value.Type = 31; value.Text = Marshal.StringToCoTaskMemUni(text); }
                store.SetValue(ref key, ref value);
                return text;
            }
            store.GetValue(ref key, out value);
            return value.Type == 31 ? Marshal.PtrToStringUni(value.Text) : null;
        }
        finally { PropVariantClear(ref value); Marshal.ReleaseComObject(store); }
    }
}

// The driver reads actual HICONs across processes. Only private copies of the
// fixture executable are included in the monitor's test catalog.
#if FIXTURE_WINDOW
sealed class TaskbarFixtureForm : Form
{
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hwnd, uint message, IntPtr kind, IntPtr icon);
    readonly string channel;
    readonly Icon originalSmall, originalLarge, replacement;
    readonly System.Windows.Forms.Timer pulse = new System.Windows.Forms.Timer { Interval = 80 };
    readonly Stopwatch lifetime = Stopwatch.StartNew();
    protected override bool ShowWithoutActivation { get { return true; } }

    TaskbarFixtureForm(string channelDirectory, string artwork, string mode)
    {
        channel = channelDirectory;
        Text = "BetterIcon disposable taskbar test";
        StartPosition = FormStartPosition.Manual;
        Location = new Point(-31000, -31000);
        Size = new Size(160, 100);
        if (mode == "preview") {
            Text = "BetterIcon taskbar preview";
            Size = new Size(420, 150); StartPosition = FormStartPosition.CenterScreen;
            Controls.Add(new Label { Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, Text = "The taskbar icon for this test window changes with the pack." });
        }
        originalSmall = new Icon(Path.Combine(artwork, "original-small.ico"));
        originalLarge = new Icon(Path.Combine(artwork, "original-large.ico"));
        replacement = new Icon(Path.Combine(artwork, "app-changed.ico"));
        if (mode == "group" || mode == "group-empty") {
            if (mode == "group") FixtureProperties.Access(Handle, FixtureProperties.RelaunchIcon, true, Path.Combine(artwork, "original-large.ico") + ",0");
            FixtureProperties.Access(Handle, FixtureProperties.AppId, true, "BetterIcon.Test." + Guid.NewGuid().ToString("N"));
            FormClosing += delegate {
                FixtureProperties.Access(Handle, FixtureProperties.AppId, true);
                FixtureProperties.Access(Handle, FixtureProperties.RelaunchIcon, true);
            };
        }
        Shown += delegate {
            if (mode == "empty") SetIcons(null, null);
            else SetIcons(originalSmall, originalLarge);
            File.WriteAllText(Path.Combine(channel, "ready"), Handle.ToInt64().ToString(CultureInfo.InvariantCulture));
            pulse.Start();
        };
        pulse.Tick += delegate {
            if (File.Exists(Path.Combine(channel, "close")) || lifetime.Elapsed.TotalMinutes > 3) Close();
            else if (File.Exists(Path.Combine(channel, "change")) && !File.Exists(Path.Combine(channel, "changed"))) {
                SetIcons(replacement, originalLarge);
                if (mode == "group") FixtureProperties.Access(Handle, FixtureProperties.RelaunchIcon, true, Path.Combine(artwork, "app-changed.ico") + ",0");
                File.WriteAllText(Path.Combine(channel, "changed"), "");
            }
        };
    }
    void SetIcons(Icon small, Icon large)
    {
        SendMessage(Handle, 0x80 /* WM_SETICON */, IntPtr.Zero, small == null ? IntPtr.Zero : small.Handle);
        SendMessage(Handle, 0x80, new IntPtr(1), large == null ? IntPtr.Zero : large.Handle);
    }
    [STAThread] static void Main(string[] args)
    {
        using (TaskbarFixtureForm form = new TaskbarFixtureForm(args[0], args[1], args.Length > 2 ? args[2] : "")) {
            Application.Run(form);
            form.pulse.Dispose();
            form.originalSmall.Dispose(); form.originalLarge.Dispose(); form.replacement.Dispose();
        }
    }
}
#else
static class TaskbarWindowTests
{
    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, IntPtr kind, IntPtr data, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint process);
    static readonly Color Small = Color.FromArgb(30, 210, 65), Large = Color.FromArgb(25, 140, 155),
                          PackA = Color.FromArgb(255, 92, 51), PackB = Color.FromArgb(58, 105, 235),
                          Changed = Color.FromArgb(241, 194, 59);
    static readonly List<object> checks = new List<object>();
    static string root;

    // A single opaque 32px DIB frame makes the expected center pixel independent
    // of DPI, interpolation, desktop theme and the shell's icon cache.
    static void WriteIcon(string name, Color color)
    {
        using (BinaryWriter w = new BinaryWriter(File.Create(Path.Combine(root, name + ".ico")))) {
            w.Write((ushort)0); w.Write((ushort)1); w.Write((ushort)1);
            w.Write(new byte[] { 32, 32, 0, 0 }); w.Write((ushort)1); w.Write((ushort)32);
            const int pixels = 32 * 32 * 4, mask = 32 * 4;
            w.Write(40 + pixels + mask); w.Write(22);
            w.Write(40); w.Write(32); w.Write(64); w.Write((ushort)1); w.Write((ushort)32);
            w.Write(0); w.Write(pixels); w.Write(new byte[16]);
            for (int i = 0; i < 1024; i++) w.Write(color.ToArgb());
            w.Write(new byte[mask]);
        }
    }
    static void WaitFor(Func<bool> test, string name)
    {
        Stopwatch watch = Stopwatch.StartNew();
        while (!test()) {
            if (watch.Elapsed.TotalSeconds > 15) throw new TimeoutException(name);
            Application.DoEvents(); Thread.Sleep(50);
        }
    }
    static void Check(bool passed, string name)
    {
        checks.Add(new { Test = name, Passed = passed });
        if (!passed) throw new Exception(name);
        Console.WriteLine("PASS: " + name);
    }
    sealed class Fixture : IDisposable
    {
        public readonly string Channel;
        readonly Process child;
        readonly IntPtr window;
        public bool HasExited { get { return child.HasExited; } }
        public string Resource { get { return FixtureProperties.Access(window, FixtureProperties.RelaunchIcon, false); } }
        public string AppId { get { return FixtureProperties.Access(window, FixtureProperties.AppId, false); } }
        public Fixture(string executable, string mode = "plain")
        {
            Channel = Directory.CreateDirectory(Path.Combine(root, Guid.NewGuid().ToString("N"))).FullName;
            ProcessStartInfo start = new ProcessStartInfo(executable, "\"" + Channel + "\" \"" + root + "\" " + mode) {
                UseShellExecute = false, CreateNoWindow = true, WindowStyle = mode == "preview" ? ProcessWindowStyle.Normal : ProcessWindowStyle.Hidden
            };
            child = Process.Start(start);
            try {
                string ready = Path.Combine(Channel, "ready"); long value = 0;
                WaitFor(delegate {
                    if (child.HasExited) throw new Exception("The disposable window exited before it was ready.");
                    try { return File.Exists(ready) && Int64.TryParse(File.ReadAllText(ready), out value) && value != 0; }
                    catch (IOException) { return false; }
                }, "Fixture did not publish its HWND");
                window = new IntPtr(value);
                uint pid; GetWindowThreadProcessId(window, out pid);
                if (pid != child.Id) throw new Exception("The HWND does not belong to the newly launched fixture.");
            }
            catch { Dispose(); throw; }
        }
        int ReadColor(int slot)
        {
            IntPtr handle;
            if (SendMessageTimeout(window, 0x7f /* WM_GETICON */, new IntPtr(slot), IntPtr.Zero, 2, 2000, out handle) == IntPtr.Zero)
                throw new InvalidOperationException("The fixture window did not answer WM_GETICON.");
            if (handle == IntPtr.Zero) return 0;
            // Ownership stays with the fixture or monitor. FromHandle does not
            // own the source HICON, and ToBitmap supplies a local snapshot.
            using (Icon icon = Icon.FromHandle(handle))
            using (Bitmap image = icon.ToBitmap()) return image.GetPixel(image.Width / 2, image.Height / 2).ToArgb();
        }
        public bool Shows(Color small, Color large) { return ReadColor(0) == small.ToArgb() && ReadColor(1) == large.ToArgb(); }
        public void Expect(Color small, Color large, string name)
        {
            WaitFor(delegate { return Shows(small, large); }, name);
            Check(true, name);
        }
        public void Dispose()
        {
            File.WriteAllText(Path.Combine(Channel, "close"), "");
            if (!child.WaitForExit(3000)) { child.Kill(); child.WaitForExit(); }
            child.Dispose();
        }
    }
    static string MakeExecutable(string folder, string name)
    {
        string path = Path.Combine(Directory.CreateDirectory(Path.Combine(root, folder)).FullName, name);
        File.Copy(Path.Combine(root, "FixtureWindow.exe"), path);
        return path;
    }
    static AppEntry Entry(string name, string target, string artwork)
    {
        return new AppEntry { Application = name, Name = name, Target = target, AppliedIconPath = artwork };
    }
    static void Run()
    {
        WriteIcon("original-small", Small); WriteIcon("original-large", Large); WriteIcon("app-changed", Changed);
        WriteIcon("pack-a", PackA); WriteIcon("pack-b", PackB);
        string photo = MakeExecutable("installed", "PhotoCraft.exe");
        string otherPhoto = MakeExecutable("unrelated", "PhotoCraft.exe"), generic = MakeExecutable("generic", "pythonw.exe");
        string a = Path.Combine(root, "pack-a.ico"), b = Path.Combine(root, "pack-b.ico");
        using (Fixture first = new Fixture(photo, "group"))
        using (Fixture unrelated = new Fixture(otherPhoto))
        using (Fixture python = new Fixture(generic)) {
            first.Expect(Small, Large, "Each window icon slot has distinct original artwork in a separate process");
            string appId = first.AppId, originalResource = first.Resource;
            Check(appId.StartsWith("BetterIcon.Test.") && originalResource == Path.Combine(root, "original-large.ico") + ",0",
                "The fixture supplies an explicit group identity and a separate taskbar group icon");
            using (RunningTaskbarIcons monitor = new RunningTaskbarIcons()) {
                monitor.Update(new[] { Entry("PhotoCraft", photo, a), Entry("PhotoCraft", generic, a) });
                first.Expect(PackA, PackA, "Applying a pack updates both icon slots on an already-running app");
                WaitFor(delegate { return first.Resource == a + ",0"; }, "The explicit taskbar group did not adopt pack A");
                Check(first.AppId == appId, "A group with an explicit icon adopts the pack and keeps its identity");
                Check(unrelated.Shows(Small, Large), "A same-name executable in another directory retains its own icons");
                Check(python.Shows(Small, Large), "A generic host in a shortcut retains its own icons");
                using (Fixture second = new Fixture(photo, "group-empty")) {
                    second.Expect(PackA, PackA, "A newly launched instance receives the selected artwork");
                    monitor.Update(new[] { Entry("PhotoCraft", photo, b) });
                    first.Expect(PackB, PackB, "Changing packs updates the first running instance");
                    second.Expect(PackB, PackB, "Changing packs updates the second running instance");
                    WaitFor(delegate { return first.Resource == b + ",0"; }, "The explicit taskbar group did not adopt pack B");
                    Check(second.Resource == null, "An explicit identity without a relaunch icon keeps its shortcut association");
                    File.WriteAllText(Path.Combine(first.Channel, "change"), "");
                    WaitFor(delegate { return File.Exists(Path.Combine(first.Channel, "changed")); }, "The app did not reset its own icon");
                    first.Expect(PackB, PackB, "The selected pack survives an app replacing its own running icon");
                    WaitFor(delegate { return first.Resource == b + ",0"; }, "The group icon did not recover from an app-side change");
                    monitor.Update(new[] { Entry("PhotoCraft", photo, null) });
                    first.Expect(Changed, Large, "Restore recovers the app's most recent native icons");
                    second.Expect(Small, Large, "Each running window recovers its own original icons");
                    originalResource = Path.Combine(root, "app-changed.ico") + ",0";
                    WaitFor(delegate { return first.Resource == originalResource; }, "Restore did not recover the group's new app-owned resource");
                    Check(first.AppId == appId, "Restore recovers the app's latest group icon and preserves its identity");
                }
                monitor.Update(new[] { Entry("PhotoCraft", photo, a) });
                first.Expect(PackA, PackA, "A fresh apply works after a restore and process exit");
                AppEntry personalPin = Entry("PhotoCraft", photo, a), personalShortcut = Entry("PhotoCraft", photo, b);
                personalPin.Scope = "AllUsers"; personalPin.AppliedIconScope = "CurrentUser";
                personalShortcut.Scope = "CurrentUser"; personalShortcut.AppliedIconScope = "CurrentUser";
                monitor.Update(new[] { personalPin, personalShortcut });
                first.Expect(Changed, Large, "Conflicting current-user shortcut and pin choices for one executable leave its native icon in control");
                monitor.Update(new[] { personalPin });
                first.Expect(PackA, PackA, "Removing the conflicting shortcut choice restores the unambiguous personal pin artwork");
            }
            first.Expect(Changed, Large, "Closing the monitor restores the running application");
            Check(first.Resource == originalResource, "Closing the monitor restores the taskbar group's own resource");
        }
        using (RunningTaskbarIcons monitor = new RunningTaskbarIcons()) {
            monitor.Update(new[] { Entry("PhotoCraft", photo, a) });
            using (Fixture original = new Fixture(photo, "empty"))
                original.Expect(PackA, PackA, "A running app with no explicit window icons receives the selected pack");
            using (Fixture relaunched = new Fixture(photo, "empty")) {
                relaunched.Expect(PackA, PackA, "Quitting every instance and relaunching still picks up the selected pack");
                monitor.Update(new AppEntry[0]);
                relaunched.Expect(Color.Empty, Color.Empty, "Removing the applied icon restores Windows' class-icon fallback");
            }
        }
    }
    static void Preview()
    {
        // Optional human-visible inspection after the automatic fixture run.
        string photo = MakeExecutable("preview-" + Guid.NewGuid().ToString("N"), "PhotoCraft.exe");
        using (Fixture window = new Fixture(photo, "preview"))
        using (RunningTaskbarIcons monitor = new RunningTaskbarIcons()) {
            string pack = null;
            string selector = Path.Combine(window.Channel, "pack");
            File.WriteAllText(selector, "a");
            File.WriteAllText(Path.Combine(root, "preview-channel.txt"), window.Channel);
            while (!window.HasExited) {
                string requested;
                try { requested = File.ReadAllText(selector).Trim(); }
                catch (IOException) { Thread.Sleep(100); continue; }
                if (requested != pack) {
                    string icon = requested == "a" || requested == "b" ? Path.Combine(root, "pack-" + requested + ".ico") : null;
                    monitor.Update(new[] { Entry("PhotoCraft", photo, icon) }); pack = requested;
                }
                Application.DoEvents(); Thread.Sleep(100);
            }
        }
    }
    [STAThread] static int Main(string[] args)
    {
        root = args[0];
        if (args.Length > 1 && args[1] == "--preview") { Preview(); return 0; }
        string error = null;
        try { Run(); }
        catch (Exception e) { error = e.ToString(); Console.Error.WriteLine(error); }
        File.WriteAllText(Path.Combine(root, "results.json"), new JavaScriptSerializer().Serialize(new { Checks = checks, Error = error }));
        return error == null ? 0 : 1;
    }
}
#endif
