using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;

namespace BetterIcon.Tray
{
    // Only the worker thread owns window state and HICONs. Shell or window messages
    // to an app that has stopped responding must never stall the launcher UI.
    public sealed class RunningTaskbarIcons : IDisposable
    {
        const uint GetIcon = 0x007f, SetIcon = 0x0080;
        const uint AbortIfHung = 2, Block = 1, ErrorOnExit = 32;
        static readonly StringComparer Paths = StringComparer.OrdinalIgnoreCase;
        readonly object gate = new object();
        readonly Thread worker;
        readonly SecurityIdentifier user;
        readonly Dictionary<IntPtr, Window> windows = new Dictionary<IntPtr, Window>();
        Dictionary<string, string> desired = new Dictionary<string, string>(Paths);
        bool stopping;
        long revision;

        public RunningTaskbarIcons()
        {
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent()) user = identity.User;
            worker = new Thread(Watch) { IsBackground = true, Name = "BetterIcon running window icons" };
            worker.Start();
        }

        static string AppName(string value)
        {
            return value.Replace("-", "").Replace("_", "").Replace(" ", "");
        }

        public void Update(IEnumerable<AppEntry> apps)
        {
            var matches = new Dictionary<string, List<AppEntry>>(Paths);
            foreach (AppEntry app in apps) {
                // Application is the canonical ArtCraft name from shortcut discovery.
                // A renamed shortcut to a Python/command/browser host cannot identify its windows.
                if (String.IsNullOrEmpty(app.Application) || !File.Exists(app.Target) ||
                    !Paths.Equals(Path.GetExtension(app.Target), ".exe") ||
                    !Paths.Equals(AppName(Path.GetFileNameWithoutExtension(app.Target)), AppName(app.Application)) ||
                    !File.Exists(app.AppliedIconPath) || !Paths.Equals(Path.GetExtension(app.AppliedIconPath), ".ico")) continue;
                string target = Path.GetFullPath(app.Target);
                List<AppEntry> entries;
                if (!matches.TryGetValue(target, out entries)) matches.Add(target, entries = new List<AppEntry>());
                entries.Add(app);
            }
            var next = new Dictionary<string, string>(Paths);
            foreach (var match in matches) {
                // Two shortcuts can launch the identical executable. Prefer the user's
                // applied choice. If equally scoped shortcuts disagree, leave the app in control.
                var personal = match.Value.Where(app => (app.AppliedIconScope ?? app.Scope) == "CurrentUser");
                var icons = (personal.Any() ? personal : match.Value).Select(app => Path.GetFullPath(app.AppliedIconPath)).Distinct(Paths).ToArray();
                if (icons.Length == 1) next.Add(match.Key, icons[0]);
            }
            lock (gate) {
                if (stopping) return;
                desired = next;
                revision++;
                Monitor.Pulse(gate);
            }
        }

        public void Dispose()
        {
            lock (gate) {
                if (stopping) return;
                stopping = true;
                desired = new Dictionary<string, string>(Paths);
                Monitor.Pulse(gate);
            }
            worker.Join(2000);
        }

        void Watch()
        {
            for (;;) {
                Dictionary<string, string> targets;
                long observed;
                bool final;
                lock (gate) { targets = desired; observed = revision; final = stopping; }
                if (targets.Count > 0) Discover(targets);
                foreach (Window window in windows.Values.ToArray()) {
                    uint pid;
                    bool gone = GetWindowThreadProcessId(window.Handle, out pid) != window.ThreadId || pid != window.ProcessId;
                    string artwork;
                    targets.TryGetValue(window.Target, out artwork);
                    if (!gone) {
                        window.Small.Update(window.Handle, 0, artwork);
                        window.Large.Update(window.Handle, 1, artwork);
                        window.Group.Update(window.Handle, artwork);
                    }
                    if (gone || final || (artwork == null && !window.Small.HasIcons && !window.Large.HasIcons && !window.Group.Applied)) {
                        if (gone) { window.Small.Release(); window.Large.Release(); }
                        CloseHandle(window.Process);
                        windows.Remove(window.Handle);
                    }
                }
                if (final) return;
                lock (gate) {
                    if (!stopping && observed == revision)
                        Monitor.Wait(gate, targets.Count == 0 && windows.Count == 0 ? Timeout.Infinite : 2000);
                }
            }
        }

        void Discover(Dictionary<string, string> targets)
        {
            // EnumWindows enumerates the calling desktop. Test the resolved executable
            // and token owner before sending any messages; leave helper/owned/tool windows alone.
            EnumWindows(delegate(IntPtr hwnd, IntPtr unused) {
                if (windows.ContainsKey(hwnd) || !IsWindowVisible(hwnd) || GetWindow(hwnd, 4) != IntPtr.Zero ||
                    (GetWindowLong(hwnd, -20) & 0x80) != 0) return true;
                uint pid;
                uint thread = GetWindowThreadProcessId(hwnd, out pid);
                IntPtr process = OpenProcess(0x1000, false, pid); // PROCESS_QUERY_LIMITED_INFORMATION
                if (process == IntPtr.Zero) return true;
                try {
                    var image = new StringBuilder(512);
                    int size = image.Capacity;
                    if (!QueryFullProcessImageName(process, 0, image, ref size)) {
                        if (Marshal.GetLastWin32Error() != 122) return true; // ERROR_INSUFFICIENT_BUFFER
                        image.EnsureCapacity(32768);
                        size = image.Capacity;
                        if (!QueryFullProcessImageName(process, 0, image, ref size)) return true;
                    }
                    string path = image.ToString();
                    if (!targets.ContainsKey(path) || !IsSameUser(process)) return true;
                    // Keeping the process object alive prevents its PID from being recycled.
                    windows.Add(hwnd, new Window { Handle = hwnd, Process = process, ThreadId = thread, ProcessId = pid, Target = path });
                    process = IntPtr.Zero;
                }
                finally { if (process != IntPtr.Zero) CloseHandle(process); }
                return true;
            }, IntPtr.Zero);
        }

        bool IsSameUser(IntPtr process)
        {
            IntPtr token;
            if (!OpenProcessToken(process, 8, out token)) return false; // TOKEN_QUERY
            try {
                int elevated, bytes;
                if (!GetTokenInformation(token, 20, out elevated, sizeof(int), out bytes) || elevated != 0) return false;
                using (var identity = new WindowsIdentity(token)) return user.Equals(identity.User);
            }
            catch (System.Security.SecurityException) { return false; }
            catch (ArgumentException) { return false; }
            finally { CloseHandle(token); }
        }

        sealed class Window
        {
            internal IntPtr Handle, Process;
            internal uint ThreadId, ProcessId;
            internal string Target;
            internal readonly IconSlot Small = new IconSlot(), Large = new IconSlot();
            internal readonly GroupIcon Group = new GroupIcon();
        }

        // An explicit AppUserModelID window may publish a separate icon for its whole
        // taskbar group. Retain its identity and command. With no published resource
        // Windows already uses the matching shortcut; creating a new property on a
        // foreign window would require removing it before that app destroys the window.
        sealed class GroupIcon
        {
            string original, installed;
            internal bool Applied { get { return installed != null; } }

            internal void Update(IntPtr hwnd, string path)
            {
                if (path == null && !Applied) return;
                Guid iid = typeof(IPropertyStore).GUID;
                IPropertyStore store;
                if (SHGetPropertyStoreForWindow(hwnd, ref iid, out store) < 0 || store == null) return;
                try {
                    string appId, current;
                    if (!ReadString(store, 5, out appId) || !ReadString(store, 3, out current)) return;
                    if (current != installed) installed = null;
                    string next = path == null || String.IsNullOrEmpty(appId) ? null : path + ",0";
                    if (next == null) {
                        if (Applied && WriteIcon(store, original)) installed = null;
                    } else if (!String.IsNullOrEmpty(current) && current != next) {
                        if (!Applied) original = current;
                        if (WriteIcon(store, next)) installed = next;
                    }
                }
                finally { Marshal.ReleaseComObject(store); }
            }

            static bool ReadString(IPropertyStore store, uint id, out string text)
            {
                var key = new PropertyKey(id);
                PropVariant value;
                int hr = store.GetValue(ref key, out value);
                try {
                    text = value.Type == 31 && hr >= 0 ? Marshal.PtrToStringUni(value.Pointer) : null;
                    return hr >= 0 && (value.Type == 0 || value.Type == 31); // VT_EMPTY / VT_LPWSTR
                }
                finally { PropVariantClear(ref value); }
            }

            static bool WriteIcon(IPropertyStore store, string text)
            {
                var key = new PropertyKey(3);
                var value = new PropVariant { Type = 31, Pointer = Marshal.StringToCoTaskMemUni(text) };
                try { return store.SetValue(ref key, ref value) >= 0; }
                finally { PropVariantClear(ref value); }
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        struct PropertyKey
        {
            static readonly Guid AppUserModel = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
            Guid format;
            uint property;
            internal PropertyKey(uint id) { format = AppUserModel; property = id; }
        }

        [StructLayout(LayoutKind.Explicit, Size = 24)]
        struct PropVariant
        {
            [FieldOffset(0)] internal ushort Type;
            [FieldOffset(8)] internal IntPtr Pointer;
        }

        [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IPropertyStore
        {
            [PreserveSig] int GetCount(out uint count);
            [PreserveSig] int GetAt(uint index, out PropertyKey key);
            [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
            [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
            [PreserveSig] int Commit();
        }

        sealed class IconSlot
        {
            IntPtr original, installed, pending;
            string installedPath, pendingPath;
            Dictionary<string, IntPtr> delayed;
            internal bool HasIcons { get { return installed != IntPtr.Zero || pending != IntPtr.Zero || delayed != null; } }

            internal void Update(IntPtr hwnd, int size, string path)
            {
                IntPtr current;
                if (!Message(hwnd, GetIcon, size, IntPtr.Zero, out current)) return;
                Observe(current);
                if (Paths.Equals(installedPath, path)) return;

                IntPtr next = original;
                if (path != null) {
                    if (delayed == null || !delayed.TryGetValue(path, out next))
                        next = LoadImage(IntPtr.Zero, path, 1, GetSystemMetrics(size == 0 ? 49 : 11),
                            GetSystemMetrics(size == 0 ? 50 : 12), 0x10); // IMAGE_ICON, LR_LOADFROMFILE (private)
                    if (next == IntPtr.Zero) return;
                    pending = next;
                    pendingPath = path;
                    if (installed == IntPtr.Zero) original = current;
                }
                IntPtr previous;
                if (!Message(hwnd, SetIcon, size, next, out previous)) {
                    // A timeout can return while the target's window procedure still
                    // holds the message. Reuse this HICON for retries and keep it
                    // valid until the window is gone, even if another pack is applied.
                    if (path != null) {
                        if (delayed == null) delayed = new Dictionary<string, IntPtr>(Paths);
                        delayed[path] = next;
                    }
                    return;
                }
                if (path != null && previous != installed && previous != IntPtr.Zero) original = previous;
                // A window procedure can ignore WM_SETICON. Only free a handle
                // once the owner thread confirms which icon the window now uses.
                if (Message(hwnd, GetIcon, size, IntPtr.Zero, out current)) Observe(current);
            }

            void Observe(IntPtr current)
            {
                if (installed != IntPtr.Zero && current != installed) {
                    ReleaseConfirmed(installed);
                    installed = IntPtr.Zero;
                    installedPath = null;
                }
                if (pending != IntPtr.Zero) {
                    if (pending == current) {
                        installed = pending;
                        installedPath = pendingPath;
                    } else ReleaseConfirmed(pending);
                }
                pending = IntPtr.Zero;
                pendingPath = null;
                if (installed == IntPtr.Zero && current != IntPtr.Zero && delayed != null) {
                    foreach (var icon in delayed) {
                        if (icon.Value == current) { installed = current; installedPath = icon.Key; break; }
                    }
                }
            }

            void ReleaseConfirmed(IntPtr icon)
            {
                if (delayed == null || !delayed.ContainsValue(icon)) DestroyIcon(icon);
            }

            internal void Release()
            {
                if (installed != IntPtr.Zero) ReleaseConfirmed(installed);
                if (pending != IntPtr.Zero) ReleaseConfirmed(pending);
                if (delayed != null) foreach (IntPtr icon in delayed.Values) DestroyIcon(icon);
            }
        }

        static bool Message(IntPtr hwnd, uint message, int size, IntPtr value, out IntPtr result)
        {
            return SendMessageTimeout(hwnd, message, (IntPtr)size, value, AbortIfHung | Block | ErrorOnExit, 100, out result) != IntPtr.Zero;
        }

        delegate bool EnumProc(IntPtr window, IntPtr data);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr data);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window, uint command);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] static extern int GetWindowLong(IntPtr window, int index);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadImage(IntPtr module, string path, uint type, int width, int height, uint flags);
        [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
        [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);
        [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder path, ref int size);
        [DllImport("advapi32.dll")] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll")] static extern bool GetTokenInformation(IntPtr token, int informationClass, out int value, int size, out int returned);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr window, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);
        [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropVariant value);
    }
}
