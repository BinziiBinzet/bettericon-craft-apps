// Local native event tests. Launches only a disposable probe through its fixture shortcut.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
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
            Check(catalog.Success && catalog.Catalog.Themes.Length == 14 && catalog.Catalog.Apps.Length == 1 && catalog.Catalog.Apps[0].Application == "PhotoCraft", "Native process invokes the catalog worker with a real fixture shortcut");
            WorkerReply preview = client.Run(new WorkerRequest { Action = "RestorePreview", Scope = "CurrentUser" }, false).GetAwaiter().GetResult();
            Check(preview.Success && preview.StateHash.Length == 64 && preview.Results.Length == 0, "Native restore worker hashes an existing manifest with inherited module paths");

            string state = Path.Combine(root, "state"), preferencesPath = Path.Combine(state, "tray-preferences.json");
            Directory.CreateDirectory(state);
            File.WriteAllText(preferencesPath, json.Serialize(new Preferences { Theme = "Craft-Icons-Zach/Satin", Scope = "CurrentUser", Hotkey = new HotkeySettings { Enabled = false } }));
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
                        ((Button)typeof(LauncherForm).GetField("settings", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form)).Focus();
                        type("f");
                        Check(list.Items.Count == 2 && list.ContainsFocus && list.SelectedItems.Count == 1, "Typing from a button filters by app-name prefix and focuses the highlighted result");
                        int artworkCount = ((ImageList)typeof(LauncherForm).GetField("pictures", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form)).Images.Count;
                        type("iL");
                        Check(list.Items.Count == 1 && list.Items[0].Text == "FilmCraft" && filter.Text.Contains("fiL"), "Successive characters narrow results case-insensitively and show the query");
                        key(Keys.Back);
                        Check(list.Items.Count == 2 && filter.Text.Contains("Filter: fi "), "Backspace broadens the list by removing one character");
                        type("zzz");
                        Check(list.Items.Count == 0 && filter.Text.Contains("0 matches"), "Unmatched text produces an explicit empty result state");
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
                        Check(list.Items.Count == 3 && !filter.Text.StartsWith("Filter:"), "Reopening starts with all apps and no stale filter");
                        ComboBox themePicker = (ComboBox)typeof(LauncherForm).GetField("themes", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                        themePicker.DroppedDown = true;
                        KeyPressEventArgs dropdownKey = new KeyPressEventArgs('p'); character.Invoke(form, new object[] { dropdownKey });
                        Check(!dropdownKey.Handled && list.Items.Count == 3, "An open theme dropdown keeps its own typing behavior");
                        themePicker.DroppedDown = false;
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
                        Check(saved.Hotkey.Key == second.Key && saved.Hotkey.Enabled && saved.Theme == themeBefore && saved.Scope == "CurrentUser", "Custom hotkey persists without changing the selected theme or scope");
                        using (FileStream locked = File.Open(preferencesPath, FileMode.Open, FileAccess.Read, FileShare.None)) {
                            string saveError = (string)saveHotkey.Invoke(form, new object[] { first });
                            GlobalHotkey active = (GlobalHotkey)typeof(LauncherForm).GetField("hotkey", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                            Check(saveError != null && active.Current.Key == second.Key, "A settings write failure rolls back to the previous working shortcut");
                        }
                        HotkeySettings off = second.Copy(); off.Enabled = false;
                        Check(saveHotkey.Invoke(form, new object[] { off }) == null && !json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).Hotkey.Enabled, "Disabled hotkey is saved for subsequent launches");
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
