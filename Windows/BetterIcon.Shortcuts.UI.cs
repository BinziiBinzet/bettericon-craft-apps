using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

namespace BetterIcon.Tray
{
    public sealed class ShortcutScopeDialog : Form
    {
        public string SelectedScope { get; private set; }
        public ShortcutScopeDialog(bool restoring, string application)
        {
            Text = restoring ? "Restore icon locations" : "Apply icon locations";
            Name = "ShortcutScopeDialog"; Font = new Font("Segoe UI", 10F);
            StartPosition = FormStartPosition.CenterParent; FormBorderStyle = FormBorderStyle.FixedDialog;
            MinimizeBox = MaximizeBox = false; ShowInTaskbar = false;
            ClientSize = new Size(620, 250); MinimumSize = new Size(620, 250);
            AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink;
            string app = application == "ArtCraftLauncher" ? "ArtCraft Launcher" : application;
            string action = restoring ? "restore" : "apply";
            TableLayoutPanel layout = new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, ColumnCount = 1, RowCount = 4, Padding = new Padding(20) };
            for (int row = 0; row < 4; row++) layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            Label question = new Label { Text = "Where would you like to " + action + (String.IsNullOrEmpty(app) ? " icons?" : " " + app + " icons?"), AutoSize = true, Dock = DockStyle.Top, Margin = new Padding(0, 0, 0, 16) };
            layout.Controls.Add(question, 0, 0);
            TableLayoutPanel choices = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 2, RowCount = 1, Margin = Padding.Empty };
            choices.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50)); choices.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            Button current = Choice("Current user", "Desktop, Start menu and taskbar pins", "CurrentUser");
            Button all = Choice("All users", "Shared Desktop and Start menu", "AllUsers");
            current.Margin = new Padding(0, 0, 8, 0); all.Margin = new Padding(8, 0, 0, 0);
            choices.Controls.Add(current, 0, 0); choices.Controls.Add(all, 1, 0); layout.Controls.Add(choices, 0, 1);
            Label admin = new Label { Name = "AdministratorNotice", Text = "All users requires administrator privileges.", AutoSize = true, Dock = DockStyle.Top, Margin = new Padding(0, 14, 0, 16) };
            layout.Controls.Add(admin, 0, 2);
            FlowLayoutPanel buttons = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top, FlowDirection = FlowDirection.RightToLeft, Margin = Padding.Empty };
            Button cancel = new Button { Text = "Cancel", Name = "CancelScope", DialogResult = DialogResult.Cancel, AutoSize = true, MinimumSize = new Size(100, 34), Margin = Padding.Empty };
            buttons.Controls.Add(cancel); layout.Controls.Add(buttons, 0, 3); Controls.Add(layout);
            ToolTip tips = new ToolTip(); Disposed += delegate { tips.Dispose(); };
            tips.SetToolTip(current, "Only your own shortcuts: your Desktop, Start menu and taskbar pins. You see the list next.");
            tips.SetToolTip(all, "The shortcuts everyone on this PC shares. Windows asks for administrator access. You see the list next.");
            tips.SetToolTip(cancel, "Close without changing any icons.");
            CancelButton = cancel; AcceptButton = current;
        }
        Button Choice(string title, string detail, string scope)
        {
            Button button = new Button { Text = title + "\r\n" + detail, Name = scope + "Choice", AccessibleName = title,
                AutoSize = true, Dock = DockStyle.Fill, MinimumSize = new Size(0, 78), Padding = new Padding(10), DialogResult = DialogResult.OK };
            if (scope == "AllUsers") button.AccessibleDescription = "Shared shortcuts for everyone on this computer. Requires administrator privileges.";
            button.Click += delegate { SelectedScope = scope; };
            return button;
        }
    }

    // The C# twin of the module's Get-AppName, for the shortcut names the tray watches. Like it and the shared helper, it
    // separates words by a literal ASCII space, underscore, dot or hyphen, never a Unicode space, and matches letters as Go
    // folds them (Fold).
    public static class AppNames
    {
        static readonly Regex Excluded = new Regex(@"(^|[^0-9a-z])(uninstall|uninstaller|remove|setup|help|documentation)([^0-9a-z]|\z)", RegexOptions.CultureInvariant);
        // A-Z as a-z, the Kelvin sign as k and the long s as s: the letters Go's case folding pairs with ASCII letters.
        public static string Fold(string name)
        {
            StringBuilder folded = new StringBuilder(name.Length);
            foreach (char c in name) folded.Append(c >= 'A' && c <= 'Z' ? (char)(c + 32) : c == 'K' ? 'k' : c == 'ſ' ? 's' : c);
            return folded.ToString();
        }
        public static string Match(string name)
        {
            if (String.IsNullOrEmpty(name)) return null;
            string folded = Fold(name);
            if (Excluded.IsMatch(folded)) return null;
            foreach (string app in PackLibrary.Applications) {
                string pattern = app == "CraftAnything" ? "craft[ _-]*anything" : app == "ArtCraftLauncher" ? "artcraft[ _-]*launcher" : Regex.Escape(app.ToLowerInvariant());
                if (Regex.IsMatch(folded, "^" + pattern + @"(?:[ _.-].*)?\z", RegexOptions.CultureInvariant)) return app;
            }
            return null;
        }
        public static string Display(string application)
        {
            return application == "ArtCraftLauncher" ? "ArtCraft Launcher" : application == "CraftAnything" ? "Craft Anything" : application;
        }
        // "A", "A and B", "A, B and C", or for four or more "A, B and N more".
        public static string Join(IList<string> names)
        {
            if (names.Count == 0) return "";
            if (names.Count == 1) return names[0];
            if (names.Count == 2) return names[0] + " and " + names[1];
            if (names.Count == 3) return names[0] + ", " + names[1] + " and " + names[2];
            return names[0] + ", " + names[1] + " and " + (names.Count - 2) + " more";
        }
    }

    // Open at login: one per-user Run value. Windows' Startup apps page keeps its own on and off beside it.
    public sealed class LoginItem
    {
        public const string ValueName = "BetterIcon";
        readonly string runKey, approvedKey, program;
        public bool Available { get; private set; }
        // The program is this executable's file name, which a test harness hosting the tray changes.
        public LoginItem(FixtureConfig fixture, string programName)
        {
            program = String.IsNullOrEmpty(programName) ? "BetterIcon-Tray.exe" : programName;
            if (fixture == null) {
                runKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
                approvedKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
                Available = true;
            }
            else if (!String.IsNullOrWhiteSpace(fixture.LoginRunKey)) {
                runKey = fixture.LoginRunKey; approvedKey = fixture.LoginApprovedKey; Available = true;
            }
        }
        public string Command()
        {
            if (!Available) return null;
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(runKey)) return key == null ? null : key.GetValue(ValueName) as string;
        }
        bool NamesTray(string command)
        {
            return command != null && (command.IndexOf("BetterIcon-Tray.exe", StringComparison.OrdinalIgnoreCase) >= 0 || command.IndexOf(program, StringComparison.OrdinalIgnoreCase) >= 0);
        }
        // The program an entry starts: its quoted first word, or everything up to ".exe".
        public static string Program(string command)
        {
            if (String.IsNullOrWhiteSpace(command)) return null;
            string text = command.Trim(), exe;
            if (text.StartsWith("\"", StringComparison.Ordinal)) {
                int end = text.IndexOf('"', 1);
                if (end < 0) return null;
                exe = text.Substring(1, end - 1);
            }
            else {
                int at = text.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
                if (at < 0) return null;
                exe = text.Substring(0, at + 4);
            }
            try { return Path.GetFullPath(Environment.ExpandEnvironmentVariables(exe)); }
            catch (ArgumentException) { return null; }
            catch (NotSupportedException) { return null; }
            catch (PathTooLongException) { return null; }
            catch (System.Security.SecurityException) { return null; }
        }
        // An entry that names a copy of BetterIcon that no longer exists starts nothing at login.
        bool StartsTray(string command)
        {
            string exe = Program(command);
            return NamesTray(command) && exe != null && File.Exists(exe);
        }
        // Windows writes 03 and the time it was turned off. An odd first byte means off.
        public bool DisabledInWindows()
        {
            if (!Available || String.IsNullOrWhiteSpace(approvedKey)) return false;
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(approvedKey)) {
                byte[] state = key == null ? null : key.GetValue(ValueName) as byte[];
                return state != null && state.Length > 0 && (state[0] & 1) == 1;
            }
        }
        // Shown off when the entry starts a copy that is gone, so one click points it at this copy.
        public bool IsEnabled() { return Available && StartsTray(Command()) && !DisabledInWindows(); }
        public void Write(string command)
        {
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey(runKey)) key.SetValue(ValueName, command, RegistryValueKind.String);
        }
        // Turning it on here also clears an earlier "off" in Windows' Startup apps.
        public void Enable(string command)
        {
            Write(command);
            if (String.IsNullOrWhiteSpace(approvedKey)) return;
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(approvedKey, true)) if (key != null) key.DeleteValue(ValueName, false);
        }
        public void Disable()
        {
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(runKey, true)) if (key != null) key.DeleteValue(ValueName, false);
        }
        // After an upgrade the entry may still start an earlier version of this installation. It never
        // creates the entry and never takes over one that starts another copy of BetterIcon. An entry for a copy
        // that no longer exists, such as a ZIP folder deleted after Setup installed BetterIcon, starts nothing:
        // when the user wants BetterIcon at login, this copy takes it over.
        public bool Refresh(string command, string root, bool wanted)
        {
            string current = Command();
            if (current == null || String.Equals(current, command, StringComparison.OrdinalIgnoreCase)) return false;
            if (wanted && NamesTray(current) && !StartsTray(current)) { Write(command); return true; }
            if (String.IsNullOrEmpty(root)) return false;
            string lower = current.ToLowerInvariant();
            if (lower.IndexOf(root.TrimEnd('\\').ToLowerInvariant() + "\\versions\\", StringComparison.Ordinal) < 0 || lower.IndexOf("\\bettericon-tray.exe", StringComparison.Ordinal) < 0) return false;
            Write(command);
            return true;
        }
    }

    // Per-user bookkeeping of the checks after app updates, kept apart from the preferences.
    public sealed class ReapplyItem
    {
        public List<string> Attempts { get; set; }
        public string RefusedHash { get; set; }
        public bool HandsOff { get; set; }
        public List<string> Notified { get; set; }
        public string DismissedHash { get; set; }
    }
    public sealed class ReapplyStateData
    {
        public int Schema { get; set; }
        public Dictionary<string, ReapplyItem> Items { get; set; }
        public string SharedBalloon { get; set; }
    }
    sealed class ReapplyStore
    {
        readonly string path;
        string saved;
        public readonly ReapplyStateData Data;
        public ReapplyStore(string file)
        {
            path = file;
            ReapplyStateData data = null;
            // A damaged or unreadable file is an empty state, never a failure.
            try { if (File.Exists(path)) data = new JavaScriptSerializer().Deserialize<ReapplyStateData>(File.ReadAllText(path, Encoding.UTF8)); }
            catch (Exception) { data = null; }
            if (data == null || data.Schema != 1) data = new ReapplyStateData { Schema = 1 };
            data.Items = new Dictionary<string, ReapplyItem>(data.Items ?? new Dictionary<string, ReapplyItem>(), StringComparer.Ordinal);
            Data = data;
            saved = Serialize();
        }
        string Serialize()
        {
            foreach (string key in Data.Items.Keys.ToArray()) {
                ReapplyItem item = Data.Items[key];
                if (item == null || ((item.Attempts == null || item.Attempts.Count == 0) && String.IsNullOrEmpty(item.RefusedHash) && !item.HandsOff &&
                    (item.Notified == null || item.Notified.Count == 0) && String.IsNullOrEmpty(item.DismissedHash))) Data.Items.Remove(key);
            }
            return new JavaScriptSerializer().Serialize(Data);
        }
        // Written only when the content changes, so a check that finds nothing writes nothing.
        public void Save()
        {
            string text = Serialize();
            if (text == saved) return;
            string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try {
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                File.WriteAllText(temporary, text, new UTF8Encoding(false));
                if (File.Exists(path)) File.Replace(temporary, path, null); else File.Move(temporary, path);
                saved = text;
            }
            catch (IOException error) { Trace.WriteLine("BetterIcon re-apply state: " + error.Message); }
            catch (UnauthorizedAccessException error) { Trace.WriteLine("BetterIcon re-apply state: " + error.Message); }
            finally { try { if (File.Exists(temporary)) File.Delete(temporary); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
        }
        public static string Key(string scope, string shortcut) { return (scope == "AllUsers" ? "AllUsers" : "CurrentUser") + "|" + (shortcut ?? "").ToLowerInvariant(); }
        public ReapplyItem Item(string scope, string shortcut, bool create)
        {
            ReapplyItem item;
            string key = Key(scope, shortcut);
            if (!Data.Items.TryGetValue(key, out item) && create) Data.Items[key] = item = new ReapplyItem();
            if (item != null) { if (item.Attempts == null) item.Attempts = new List<string>(); if (item.Notified == null) item.Notified = new List<string>(); }
            return item;
        }
        public void Forget(string scope, string shortcut) { Data.Items.Remove(Key(scope, shortcut)); }
    }

    // Section 12 of the design. Where a text speaks of one app or several, the verb follows the number of
    // apps and "shortcut" the number of shortcuts. Texts about shortcuts that appear after the last Apply,
    // and the shared action that also covers them, were added when new shortcuts became themed too.
    static class ReapplyTexts
    {
        public const string Updated = "{0} was updated. BetterIcon put its icon back.";
        public const string UpdatedMany = "{0} were updated. BetterIcon put their icons back.";
        public const string Renamed = "{0}'s shortcut was renamed by an update. BetterIcon moved its icon to the new name.";
        public const string NewShortcut = "{0} has a new shortcut. BetterIcon gave it your pack's icon.";
        public const string NewShortcutsOneApp = "{0} has new shortcuts. BetterIcon gave them your pack's icon.";
        public const string NewShortcuts = "{0} have new shortcuts. BetterIcon gave them your pack's icons.";
        public const string SharedUpdated = "{0} was updated. Its shared shortcut needs administrator access to show your icon again.";
        public const string SharedUpdatedOneApp = "{0} was updated. Its shared shortcuts need administrator access to show your icon again.";
        public const string SharedUpdatedMany = "{0} were updated. Their shared shortcuts need administrator access to show your icons again.";
        public const string SharedNew = "{0} has a new shared shortcut. It needs administrator access to show your icon.";
        public const string SharedNewOneApp = "{0} has new shared shortcuts. They need administrator access to show your icon.";
        public const string SharedNewMany = "{0} have new shared shortcuts. They need administrator access to show your icons.";
        public const string SharedMixedOneApp = "{0}'s shared shortcuts need administrator access to show your icon.";
        public const string SharedMixed = "Shared shortcuts of {0} need administrator access to show your icons.";
        public const string SharedDone = "Icon put back on 1 shared shortcut.";
        public const string SharedDoneMany = "Icons put back on {0} shared shortcuts.";
        public const string SharedDoneNew = "Your icon is now on 1 shared shortcut.";
        public const string SharedDoneNewMany = "Your icons are now on {0} shared shortcuts.";
        public const string SharedCancelled = "Administrator request cancelled. The shared shortcuts keep the apps' own icons for now.";
        // The end of a pass a person started, when it wrote nothing: still being updated, or nothing to do.
        public const string SharedStillUpdating = "The shared shortcuts are still being updated. BetterIcon will offer them again in a minute.";
        public const string SharedNothing = "The shared shortcuts need no change.";
        public const string SharedFailed = "Couldn't put the shared icons back. {0}";
        public const string SharedFailedNew = "Couldn't apply your icons to the shared shortcuts. {0}";
        public const string Refused = "Windows refused to let BetterIcon change {0}'s shortcut, so it keeps the app's icon. BetterIcon won't try again until that shortcut changes.";
        public const string RateLimited = "{0}'s shortcut keeps changing back. BetterIcon stopped putting its icon back; choose Apply icons to try again.";
        public const string Reverted = "{0}'s shortcut shows its own icon again. BetterIcon now treats it as restored.";
        public const string ChangedOutside = "{0}'s shortcut was changed outside BetterIcon. BetterIcon left it as it is.";
        public const string MovedShared = "{0}'s shortcut moved to the shared shortcuts after an update. Choose Apply icons, then All users, to theme it.";
        public const string MovedPersonal = "{0}'s shortcut moved to your own shortcuts after an update. Choose Apply icons, then Current user, to theme it.";
        public const string Stale = "{0}'s shortcut points to a program that is not installed now.";
        public const string StalePin = "Your taskbar pin for {0} points to an earlier install. Unpin it and pin {0} again from Start.";
        public const string IconMissing = "BetterIcon's saved icon for {0} is missing. Choose Apply icons to pick it again.";
        public const string Unreadable = "BetterIcon couldn't read its record of changed shortcuts. Nothing was changed.";
        public const string AutomaticFailed = "Windows didn't let BetterIcon put the shared icons back by itself. Choose Apply your icons to shared shortcuts... to try again.";
        public const string AutomaticFailedNew = "Windows didn't let BetterIcon update the shared shortcuts by itself. Choose Apply your icons to shared shortcuts... to try again.";
        public const string FilesBack = "{0} files got their icons back after an update.";
        public const string FilesBackMany = "File icons came back for {0} after their updates.";
        public const string FilesChanged = "The icon for {0} files was changed outside BetterIcon. BetterIcon left it as it is.";
        public const string Waiting = "Finishing a check for app updates...";
        public const string SharedBusy = "Putting your icons back on shared shortcuts...";
        public const string SharedBusyNew = "Applying your icons to shared shortcuts...";
        // One action for shared shortcuts an update replaced and for new ones, so it no longer says "Re-apply".
        // Three dots, as every other menu item and button of the app writes them.
        public const string SharedAction = "Apply your icons to shared shortcuts...";
        public const string SharedActionTip = "Windows asks for administrator approval once for all of them.";
        public const string NotNow = "Not now";
        public const string NotNowTip = "Hide this until those shortcuts change.";
        public const string Automatic = "Apply icons to shared shortcuts automatically";
        public const string AutomaticPaused = "Off until BetterIcon starts again, after Windows refused. Click to turn it back on.";
        public const string BalloonOne = "An app update replaced a shared shortcut. Open BetterIcon to put your icon back.";
        public const string BalloonMany = "App updates replaced {0} shared shortcuts. Open BetterIcon to put your icons back.";
        public const string BalloonOneNew = "An app install or update changed a shared shortcut. Open BetterIcon to give it your icon.";
        public const string BalloonManyNew = "App installs or updates changed {0} shared shortcuts. Open BetterIcon to give them your icons.";
        public const string LoginOn = "BetterIcon will open at login, in the tray.";
        public const string LoginOff = "BetterIcon won't open at login.";
        public const string LoginFailed = "Couldn't change Open at login. {0}";
    }

    public sealed partial class LauncherForm
    {
        [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetTokenInformation(IntPtr token, int informationClass, out int information, int length, out int returned);
        sealed class Notice { public int Rank; public string Text; public bool TooltipOnly; }
        // The status line under the buttons when nothing else needs saying. Checks after app updates change
        // shortcuts without a review, so it speaks only of what the buttons do.
        const string ReviewedText = "Apply and Restore show each change first.";
        readonly FixtureConfig fixtureSettings;
        readonly string sourceDirectory;
        readonly List<FileSystemWatcher> shortcutWatchers = new List<FileSystemWatcher>();
        System.Windows.Forms.Timer reapplyTimer;
        // Due times run on a clock that setting the system time does not move.
        static readonly Stopwatch reapplyClock = Stopwatch.StartNew();
        TimeSpan? reconcileDue, installerWaitStarted;
        TimeSpan nextSweep;
        // Until then, shortcut events may still come from BetterIcon's own last writes. Events are never dropped
        // for it: they are told apart by the contents BetterIcon wrote (ownWrites).
        DateTime ownWritesUntil;
        // Shortcuts that changed while BetterIcon itself was busy or checking, looked at once it is done.
        readonly HashSet<string> eventPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        // The contents BetterIcon itself last wrote to each shortcut, so its own writes are not taken for updates.
        readonly Dictionary<string, string> ownWrites = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        // Answers "still being updated" in a row for each shortcut and contents: the retry waits longer each time.
        readonly Dictionary<string, KeyValuePair<string, int>> inFlux = new Dictionary<string, KeyValuePair<string, int>>(StringComparer.OrdinalIgnoreCase);
        static readonly int[] InFluxRetrySeconds = { 60, 120, 300, 900 };
        // The text ShowNotice put on the status line, which keeps its tooltip.
        string noticeText;
        Task reapplyTask;
        bool reconciling, sharedRunning, autoSharedOff, trayMenuStale;
        bool? silentElevation;
        ReapplyStore reapplyStore;
        ResultItem[] pendingShared = new ResultItem[0];
        LoginItem loginItem;
        TableLayoutPanel shortcutsSection;
        FlowLayoutPanel sharedActions;
        static Bitmap shieldImage;

        string ChooseShortcutScope(bool restoring, string application = null)
        {
            iconMenu.Close();
            bool wasEnabled = trayMenu.Enabled; trayMenu.Enabled = false;
            try {
                using (ShortcutScopeDialog dialog = new ShortcutScopeDialog(restoring, application)) {
                    dialog.Icon = Icon; ApplyDialogAppearance(dialog);
                    return dialog.ShowDialog(this) == DialogResult.OK ? dialog.SelectedScope : null;
                }
            }
            finally { trayMenu.Enabled = wasEnabled; }
        }

        // ---- Open at login -----------------------------------------------------------------
        // <root>\versions\<version>\Windows, the layout Setup installs.
        string InstallRoot()
        {
            try {
                DirectoryInfo windows = new DirectoryInfo(sourceDirectory);
                if (windows.Parent == null || windows.Parent.Parent == null || windows.Parent.Parent.Parent == null) return null;
                if (!windows.Name.Equals("Windows", StringComparison.OrdinalIgnoreCase) || !windows.Parent.Parent.Name.Equals("versions", StringComparison.OrdinalIgnoreCase)) return null;
                return windows.Parent.Parent.Parent.FullName.TrimEnd('\\');
            }
            catch (ArgumentException) { return null; }
            catch (IOException) { return null; }
            catch (System.Security.SecurityException) { return null; }
        }
        bool InstalledBySetup()
        {
            if (fixtureSettings != null && fixtureSettings.InstalledCopy.HasValue) return fixtureSettings.InstalledCopy.Value;
            string root = InstallRoot();
            return root != null && File.Exists(Path.Combine(root, "unins000.exe")) && Application.ExecutablePath.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase);
        }
        string LoginCommand()
        {
            string command = WorkerClient.Quote(Application.ExecutablePath) + " --tray --source-folder " + WorkerClient.Quote(sourceDirectory);
            if (fixtureSettings != null && !String.IsNullOrEmpty(fixtureSettings.ConfigPath)) command += " --config " + WorkerClient.Quote(fixtureSettings.ConfigPath);
            return command;
        }
        void InitializeLoginItem()
        {
            loginItem = new LoginItem(fixtureSettings, Path.GetFileName(Application.ExecutablePath));
            if (!loginItem.Available) return;
            try {
                // A ZIP or source copy adds nothing by itself. Setup's copy turns this on once, and later
                // starts only point an existing entry at this version. An earlier "off" in Windows' Startup
                // apps stays as it is.
                if (InstalledBySetup()) {
                    if (preferences.OpenAtLogin == null) {
                        loginItem.Write(LoginCommand());
                        preferences.OpenAtLogin = true;
                        WritePreferences();
                        TraceFixture("Login entry written");
                    }
                    else loginItem.Refresh(LoginCommand(), InstallRoot(), preferences.OpenAtLogin == true);
                }
            }
            catch (Exception error) { Trace.WriteLine("BetterIcon open at login: " + error.Message); }
            BuildTrayMenu();
        }
        void AddLoginItem()
        {
            if (loginItem == null || !loginItem.Available) return;
            ToolStripMenuItem item = new ToolStripMenuItem("Open at login") { Enabled = !busy };
            try { item.Checked = loginItem.IsEnabled(); }
            catch (Exception) { item.Checked = false; }
            item.Click += delegate { ToggleOpenAtLogin(); };
            trayMenu.Items.Add(item);
        }
        void ToggleOpenAtLogin()
        {
            try {
                bool on = loginItem.IsEnabled();
                if (on) loginItem.Disable(); else loginItem.Enable(LoginCommand());
                preferences.OpenAtLogin = !on;
                WritePreferences();
                ShowNotice(on ? ReapplyTexts.LoginOff : ReapplyTexts.LoginOn);
            }
            catch (Exception error) { ShowNotice(String.Format(ReapplyTexts.LoginFailed, error.Message)); }
            BuildTrayMenu();
        }

        // ---- Checks after app updates --------------------------------------------------------
        void StartUpdateWatch()
        {
            if (reapplyTimer != null || IsDisposed || Disposing) return;
            // Fixture suites see no background work unless they ask for it.
            if (fixtureSettings != null && !fixtureSettings.AutomaticReconcile) return;
            reapplyStore = new ReapplyStore(Path.Combine(Path.GetDirectoryName(preferencesPath), "reapply-state.json"));
            foreach (string root in WatchRoots()) AddWatcher(root);
            trayMenu.Closed += delegate { if (trayMenuStale && !IsDisposed && IsHandleCreated) { trayMenuStale = false; BeginInvoke(new Action(BuildTrayMenu)); } };
            reapplyTimer = new System.Windows.Forms.Timer { Interval = 1000 };
            reapplyTimer.Tick += delegate { ReapplyTick(); };
            nextSweep = reapplyClock.Elapsed + TimeSpan.FromMinutes(30);
            reconcileDue = reapplyClock.Elapsed;
            reapplyTimer.Start();
        }
        void StopUpdateWatch()
        {
            if (reapplyTimer != null) { reapplyTimer.Stop(); reapplyTimer.Dispose(); reapplyTimer = null; }
            foreach (FileSystemWatcher watcher in shortcutWatchers) { watcher.EnableRaisingEvents = false; watcher.Dispose(); }
            shortcutWatchers.Clear();
        }
        IEnumerable<string> WatchRoots()
        {
            if (fixtureSettings != null) return fixtureSettings.ShortcutDirectory ?? new string[0];
            return new[] { Environment.SpecialFolder.DesktopDirectory, Environment.SpecialFolder.Programs, Environment.SpecialFolder.CommonDesktopDirectory, Environment.SpecialFolder.CommonPrograms }
                .Select(folder => Environment.GetFolderPath(folder)).Where(folder => !String.IsNullOrEmpty(folder)).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        }
        void AddWatcher(string root)
        {
            if (!Directory.Exists(root)) return;
            FileSystemWatcher watcher = null;
            try {
                watcher = new FileSystemWatcher(root, "*.lnk") { IncludeSubdirectories = true, InternalBufferSize = 65536,
                    NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size, SynchronizingObject = this };
                watcher.Created += OnShortcutEvent; watcher.Changed += OnShortcutEvent; watcher.Deleted += OnShortcutEvent;
                watcher.Renamed += OnShortcutRenamed; watcher.Error += OnWatcherError;
                watcher.EnableRaisingEvents = true;
                shortcutWatchers.Add(watcher); watcher = null;
            }
            catch (Exception error) { Trace.WriteLine("BetterIcon shortcut watcher for " + root + ": " + error.Message); }
            finally { if (watcher != null) watcher.Dispose(); }
        }
        void OnShortcutEvent(object sender, FileSystemEventArgs e) { ShortcutChanged(e.FullPath); }
        void OnShortcutRenamed(object sender, RenamedEventArgs e) { if (!ShortcutChanged(e.FullPath)) ShortcutChanged(e.OldFullPath); }
        bool ShortcutChanged(string path)
        {
            // Only shortcuts named for ArtCraft apps matter. The watcher's "*.lnk" also lets through names such as
            // "PhotoCraft.lnk~RF1a2b3c.TMP", which Windows makes for a moment while it replaces a file.
            if (String.IsNullOrEmpty(path) || !String.Equals(Path.GetExtension(path), ".lnk", StringComparison.OrdinalIgnoreCase) ||
                AppNames.Match(Path.GetFileNameWithoutExtension(path)) == null) return false;
            // An app update can land while BetterIcon is busy or checking. It is kept, never dropped, and looked
            // at once BetterIcon is done (FlushShortcutEvents).
            if (busy || reconciling || sharedRunning) { eventPaths.Add(path); return true; }
            // BetterIcon's own writes are not app updates: the shortcut holds exactly what BetterIcon wrote.
            if (OwnWrite(path)) return true;
            // Each event restarts a quiet period of five seconds.
            ScheduleReconcile(TimeSpan.FromSeconds(5), true);
            return true;
        }
        // After BetterIcon's own work: a check follows for every shortcut that changed meanwhile and does not hold
        // exactly what BetterIcon wrote there.
        void FlushShortcutEvents()
        {
            if (eventPaths.Count == 0) return;
            bool changed = eventPaths.Any(path => !OwnWrite(path));
            eventPaths.Clear();
            if (changed) ScheduleReconcile(TimeSpan.FromSeconds(5), true);
        }
        bool OwnWrite(string path)
        {
            string written;
            if (!ownWrites.TryGetValue(path, out written)) return false;
            string now = FileDigest(path);
            return now != null && String.Equals(now, written, StringComparison.OrdinalIgnoreCase);
        }
        static string FileDigest(string path)
        {
            try {
                using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (SHA256 sha = SHA256.Create())
                    return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
            }
            catch (IOException) { return null; }
            catch (UnauthorizedAccessException) { return null; }
            catch (ArgumentException) { return null; }
            catch (NotSupportedException) { return null; }
        }
        // What BetterIcon just wrote: from a pass, the contents it reports; from Apply or Restore, the file as it is now.
        void RememberOwnWrites(IEnumerable<ResultItem> rows, bool fromPass)
        {
            if (rows == null) return;
            foreach (ResultItem row in rows) {
                if (String.IsNullOrEmpty(row.Shortcut)) continue;
                bool wrote = fromPass ? row.Status == "Reapplied" || row.Status == "Applied" : row.Status == "Applied" || row.Status == "Unchanged" || row.Status == "Restored";
                if (!wrote) continue;
                string hash = fromPass ? row.Hash : FileDigest(row.Shortcut);
                if (String.IsNullOrEmpty(hash)) ownWrites.Remove(row.Shortcut); else ownWrites[row.Shortcut] = hash;
            }
        }
        void OnWatcherError(object sender, ErrorEventArgs e)
        {
            // An overflowing buffer or a lost folder: start that watcher again and check everything soon.
            TraceFixture("Shortcut watcher error");
            FileSystemWatcher failed = sender as FileSystemWatcher;
            if (failed != null && shortcutWatchers.Remove(failed)) {
                string root = failed.Path;
                failed.EnableRaisingEvents = false; failed.Dispose();
                AddWatcher(root);
            }
            ScheduleReconcile(TimeSpan.FromSeconds(5), false);
        }
        void ScheduleReconcile(TimeSpan delay, bool restart)
        {
            if (reapplyTimer == null) return;
            TimeSpan due = reapplyClock.Elapsed + delay;
            if (restart || !reconcileDue.HasValue || due < reconcileDue.Value) reconcileDue = due;
        }
        void ReapplyTick()
        {
            if (IsDisposed || Disposing || reapplyTimer == null) return;
            TimeSpan now = reapplyClock.Elapsed;
            if (now >= nextSweep) { nextSweep = now + TimeSpan.FromMinutes(30); ScheduleReconcile(TimeSpan.Zero, false); }
            if (!reconcileDue.HasValue || now < reconcileDue.Value || !CanReconcileNow()) return;
            if (InstallerRunning()) {
                // Wait for Windows Installer, looking again every ten seconds, and check anyway after five minutes.
                if (!installerWaitStarted.HasValue) installerWaitStarted = now;
                if (now - installerWaitStarted.Value < TimeSpan.FromMinutes(5)) { reconcileDue = now + TimeSpan.FromSeconds(10); return; }
            }
            installerWaitStarted = null;
            reconcileDue = null;
            reapplyTask = ReconcileUpdates();
        }
        // The test Setup's stop request uses, so a check neither waits behind nor interrupts the user.
        bool CanReconcileNow()
        {
            return !busy && !reconciling && !sharedRunning && (reapplyTask == null || reapplyTask.IsCompleted) && catalog != null && Enabled &&
                (!IsHandleCreated || IsWindowEnabled(Handle)) && !OwnedForms.Any(form => form.Visible && form.Modal);
        }
        bool InstallerRunning()
        {
            if (fixtureSettings != null) return !String.IsNullOrEmpty(fixtureSettings.InstallerBusyFile) && File.Exists(fixtureSettings.InstallerBusyFile);
            Mutex installer = null;
            try { return Mutex.TryOpenExisting(@"Global\_MSIExecute", out installer); }
            catch (UnauthorizedAccessException) { return true; }
            catch (Exception) { return false; }
            finally { if (installer != null) installer.Dispose(); }
        }
        async Task ReconcileUpdates()
        {
            reconciling = true;
            // Everything one check has to say, from its shortcuts, the automatic shared pass and the file icons,
            // goes on the status line together, so no notice replaces another.
            var notices = new List<Notice>();
            try {
                WorkerRequest request = new WorkerRequest { Action = "Reapply", Scope = "CurrentUser", Skip = SkipList(), SkipApps = KeptApps(), ThemeNew = ThemesNewShortcuts() };
                TraceFixture("Reapply started (skip " + request.Skip.Length + ")");
                WorkerReply reply = await worker.Run(request, false);
                if (IsDisposed || Disposing) return;
                notices.AddRange(HandleReapplyReply(reply));
                TraceFixture("Reapply finished");
            }
            catch (Exception error) { Trace.WriteLine("BetterIcon check for app updates: " + error.Message); TraceFixture("Reapply failed"); }
            finally {
                reconciling = false; ownWritesUntil = DateTime.UtcNow.AddSeconds(10);
                if (!IsDisposed && !Disposing) FlushShortcutEvents();
            }
            if (IsDisposed || Disposing) return;
            if (pendingShared.Length > 0 && AutomaticSharedReapply(true)) notices.AddRange(await ReapplySharedIcons(true));
            if (IsDisposed || Disposing) return;
            notices.AddRange(await ReconcileFileIcons());
            if (IsDisposed || Disposing) return;
            ShowNotices(notices);
        }
        // A user operation lets a running check finish instead of failing on the state lock.
        async Task WaitForReconcile()
        {
            Task running = reapplyTask;
            if (running == null || running.IsCompleted) return;
            status.Text = ReapplyTexts.Waiting;
            try { await running; }
            catch (Exception error) { Trace.WriteLine("BetterIcon check for app updates: " + error.Message); }
        }
        SkipItem[] SkipList()
        {
            var skip = new List<SkipItem>();
            if (reapplyStore == null) return skip.ToArray();
            DateTime now = DateTime.UtcNow;
            foreach (KeyValuePair<string, ReapplyItem> pair in reapplyStore.Data.Items) {
                int bar = pair.Key.IndexOf('|');
                if (bar < 0 || bar == pair.Key.Length - 1) continue;
                string scope = pair.Key.Substring(0, bar), path = pair.Key.Substring(bar + 1);
                if (!path.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase) || !Path.IsPathRooted(path)) continue;
                ReapplyItem item = pair.Value;
                if (item.HandsOff || RecentAttempts(item, now) >= 3) skip.Add(new SkipItem { Path = path, Hash = "" });
                else if (!String.IsNullOrEmpty(item.RefusedHash)) skip.Add(new SkipItem { Path = path, Hash = item.RefusedHash });
                if (scope == "AllUsers" && !String.IsNullOrEmpty(item.DismissedHash)) skip.Add(new SkipItem { Path = path, Hash = item.DismissedHash });
            }
            return skip.ToArray();
        }
        static int RecentAttempts(ReapplyItem item, DateTime now)
        {
            if (item.Attempts == null) return 0;
            int count = 0;
            foreach (string text in item.Attempts) {
                DateTime when;
                if (DateTime.TryParse(text, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.RoundtripKind, out when) && when.ToUniversalTime() > now.AddHours(-24)) count++;
            }
            return count;
        }
        // Apps the user set back to their own icon one at a time in the tray keep it on new shortcuts too.
        string[] KeptApps()
        {
            return (preferences.DefaultShortcuts ?? new string[0]).Select(path => AppNames.Match(Path.GetFileNameWithoutExtension(path ?? ""))).Where(app => app != null).Distinct().OrderBy(app => app, StringComparer.Ordinal).ToArray();
        }
        // New shortcuts get the applied pack only while a pack is applied, not the original icons.
        bool ThemesNewShortcuts() { return !String.IsNullOrEmpty(preferences.AppliedTheme) && preferences.AppliedTheme != ThemeEntry.DefaultThemeId; }
        static bool ChangedOutside(string change) { return change == "Edited" || change == "Custom" || change == "Replaced" || change == "Stale" || change == "InFlux" || change == "Damaged"; }
        ReapplyItem Item(ResultItem row, bool create) { return reapplyStore == null ? null : reapplyStore.Item(row.Scope, String.IsNullOrEmpty(row.Shortcut) ? "<record>" : row.Shortcut, create); }
        // Each kind of notice appears once for a shortcut's contents.
        bool Once(ResultItem row, string kind)
        {
            ReapplyItem item = Item(row, true);
            if (item == null) return true;
            string key = kind + ":" + (row.Hash ?? "");
            if (item.Notified.Contains(key)) return false;
            item.Notified.Add(key);
            return true;
        }
        void RecordAttempt(ResultItem row, DateTime now)
        {
            ReapplyItem item = Item(row, true);
            if (item == null) return;
            item.Attempts = item.Attempts.Where(text => { DateTime when; return DateTime.TryParse(text, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.RoundtripKind, out when) && when.ToUniversalTime() > now.AddHours(-24); }).ToList();
            item.Attempts.Add(now.ToString("o"));
            item.RefusedHash = null;
        }
        void ForgetReapplyItems(string scope, IEnumerable<ResultItem> results, params string[] statuses)
        {
            if (reapplyStore == null || results == null) return;
            foreach (ResultItem result in results) if (!String.IsNullOrEmpty(result.Shortcut) && statuses.Contains(result.Status)) reapplyStore.Forget(scope, result.Shortcut);
            reapplyStore.Save();
        }
        static string AppOf(ResultItem row)
        {
            string application = String.IsNullOrEmpty(row.Application) ? AppNames.Match(Path.GetFileNameWithoutExtension(row.Shortcut ?? "")) : row.Application;
            return AppNames.Display(application ?? "");
        }
        static List<string> AppList(IEnumerable<ResultItem> rows) { return rows.Select(AppOf).Where(name => name.Length > 0).Distinct().ToList(); }
        static Notice Note(int rank, string text) { return new Notice { Rank = rank, Text = text }; }
        bool IsDefaultShortcut(string shortcut) { return (preferences.DefaultShortcuts ?? new string[0]).Contains(shortcut ?? "", StringComparer.OrdinalIgnoreCase); }
        // Shortcuts that now show the app's own icon count as restored in the Launcher. Only shortcuts it does not
        // know yet are written down, so a shared one that waits for an administrator costs nothing at each check.
        void RememberRestoredRows(IEnumerable<ResultItem> rows)
        {
            ResultItem[] fresh = rows.Where(r => (r.Status == "Restored" || r.Status == "Reverted") && !String.IsNullOrEmpty(r.Shortcut) && !IsDefaultShortcut(r.Shortcut)).ToArray();
            if (fresh.Length == 0) return;
            RememberRestoredShortcuts(fresh.Select(r => new ResultItem { Shortcut = r.Shortcut, Status = "Restored" }).ToArray(), true);
            RenderApps();
        }
        static string MessageDigest(string message)
        {
            using (SHA256 sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(message ?? ""))).Replace("-", "").ToLowerInvariant();
        }
        // "Still being updated" answers: the next check comes after 1, 2, 5 and 15 minutes for the same shortcut
        // and contents, then only with the next change or the half-hourly check. Counts are kept for the scopes
        // this reply covers and dropped for shortcuts that settled.
        void ScheduleInFluxRetry(IEnumerable<ResultItem> rows, params string[] scopes)
        {
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            int retry = int.MaxValue;
            foreach (ResultItem row in rows.Where(r => r.Status == "InFlux")) {
                string key = ReapplyStore.Key(row.Scope, String.IsNullOrEmpty(row.Shortcut) ? "<record>" : row.Shortcut), hash = row.Hash ?? "";
                KeyValuePair<string, int> before;
                int count = inFlux.TryGetValue(key, out before) && before.Key == hash ? before.Value + 1 : 1;
                inFlux[key] = new KeyValuePair<string, int>(hash, count);
                seen.Add(key);
                if (count <= InFluxRetrySeconds.Length) retry = Math.Min(retry, InFluxRetrySeconds[count - 1]);
            }
            foreach (string key in inFlux.Keys.ToArray())
                if (!seen.Contains(key) && scopes.Any(scope => key.StartsWith(scope + "|", StringComparison.Ordinal))) inFlux.Remove(key);
            if (retry != int.MaxValue) ScheduleReconcile(TimeSpan.FromSeconds(retry), false);
        }
        List<Notice> HandleReapplyReply(WorkerReply reply)
        {
            UpdateAppsFromReply(reply.Apps);
            ResultItem[] rows = reply.Results ?? new ResultItem[0];
            var notices = new List<Notice>();
            DateTime now = DateTime.UtcNow;
            RememberOwnWrites(rows, true);
            // Shortcuts set back to the app's own icon count as restored, here and in the Launcher.
            RememberRestoredRows(rows);
            string pins = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), @"Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar");
            foreach (ResultItem row in rows) {
                string app = AppOf(row);
                ReapplyItem item;
                switch (row.Status) {
                    case "Reapplied": case "Applied": RecordAttempt(row, now); break;
                    case "Restored": case "Reverted":
                        if (row.Scope == "AllUsers") { item = Item(row, true); if (item != null) item.HandsOff = true; }
                        // A record let go because the user had already chosen the app's own icon needs no notice.
                        if (row.Detail != "Released" && Once(row, "Reverted")) notices.Add(Note(6, String.Format(ReapplyTexts.Reverted, app)));
                        break;
                    case "Refused":
                        item = Item(row, true); if (item != null) item.RefusedHash = row.Hash;
                        if (Once(row, "Refused")) notices.Add(Note(2, String.Format(ReapplyTexts.Refused, app)));
                        break;
                    case "Skipped":
                        item = Item(row, false);
                        if (item != null && RecentAttempts(item, now) >= 3) {
                            // Stopped, as the notice says, until Apply icons picks the icon again: later checks leave it alone.
                            item.HandsOff = true;
                            if (Once(row, "RateLimited")) notices.Add(Note(3, String.Format(ReapplyTexts.RateLimited, app)));
                        }
                        break;
                    case "Changed":
                        // Another icon or another program: hands off from now on.
                        if (row.Detail == "Custom" || row.Detail == "Replaced") { item = Item(row, true); if (item != null) item.HandsOff = true; }
                        if (Once(row, "Changed")) notices.Add(Note(7, String.Format(ReapplyTexts.ChangedOutside, app)));
                        break;
                    case "Moved":
                        if (Once(row, "Moved")) notices.Add(Note(8, String.Format(row.Scope == "AllUsers" ? ReapplyTexts.MovedPersonal : ReapplyTexts.MovedShared, app)));
                        break;
                    case "Stale":
                        if (Once(row, "Stale")) notices.Add(Note(9, String.Format(String.Equals(Path.GetDirectoryName(row.Shortcut ?? ""), pins, StringComparison.OrdinalIgnoreCase) ? ReapplyTexts.StalePin : ReapplyTexts.Stale, app)));
                        break;
                    case "IconMissing":
                        // Like a refusal: not tried again until that shortcut changes or Apply picks an icon again,
                        // so a shared shortcut does not start an administrator pass at every check.
                        item = Item(row, true); if (item != null) item.RefusedHash = row.Hash;
                        if (Once(row, "IconMissing")) notices.Add(Note(10, String.Format(ReapplyTexts.IconMissing, app)));
                        break;
                    case "Unreadable":
                        // Once for each reason, so damage found after another kind of read error is still reported.
                        if (Once(new ResultItem { Scope = row.Scope, Shortcut = "", Hash = MessageDigest(row.Message) }, "Unreadable")) notices.Add(Note(11, ReapplyTexts.Unreadable));
                        break;
                }
            }
            // A scope that read cleanly this time is reported again if its records ever become unreadable.
            if (reapplyStore != null)
                foreach (string scope in new[] { "CurrentUser", "AllUsers" })
                    if (!rows.Any(r => r.Status == "Unreadable" && (r.Scope ?? "CurrentUser") == scope)) reapplyStore.Forget(scope, "<record>");
            ScheduleInFluxRetry(rows, "CurrentUser", "AllUsers");
            ResultItem[] reapplied = rows.Where(r => r.Status == "Reapplied" && r.Scope != "AllUsers").ToArray();
            if (reapplied.Length > 0) {
                List<string> names = AppList(reapplied);
                notices.Add(Note(4, String.Format(names.Count == 1 ? ReapplyTexts.Updated : ReapplyTexts.UpdatedMany, AppNames.Join(names))));
                foreach (ResultItem row in reapplied.Where(r => (r.Detail ?? "").StartsWith("Renamed from", StringComparison.Ordinal)))
                    notices.Add(new Notice { Rank = 50, Text = String.Format(ReapplyTexts.Renamed, AppOf(row)), TooltipOnly = true });
            }
            ResultItem[] added = rows.Where(r => r.Status == "Applied" && r.Change == "New" && r.Scope != "AllUsers").ToArray();
            if (added.Length > 0) notices.Add(Note(5, NewShortcutText(added)));
            // Shared shortcuts wait for an administrator, unless the user chose Not now for them.
            pendingShared = rows.Where(r => r.Scope == "AllUsers" && (r.Status == "NeedsAdministrator" || r.Status == "Ready")).ToArray();
            if (pendingShared.Length > 0 && !AutomaticSharedReapply(false)) notices.Add(Note(1, SharedWaitingText(pendingShared)));
            UpdateSharedActions();
            if (reapplyStore != null) reapplyStore.Save();
            return notices;
        }
        static bool AnyNew(IEnumerable<ResultItem> rows) { return rows.Any(r => r.Change == "New"); }
        // Personal shortcuts that appeared after the last Apply and now carry the pack's icon.
        static string NewShortcutText(ResultItem[] added)
        {
            List<string> names = AppList(added);
            string joined = AppNames.Join(names);
            if (names.Count > 1) return String.Format(ReapplyTexts.NewShortcuts, joined);
            return String.Format(added.Length == 1 ? ReapplyTexts.NewShortcut : ReapplyTexts.NewShortcutsOneApp, joined);
        }
        // Shared shortcuts that wait for an administrator: replaced by updates (N2), new, or both.
        static string SharedWaitingText(ResultItem[] rows)
        {
            List<string> names = AppList(rows);
            bool updated = rows.Any(r => r.Change != "New"), added = AnyNew(rows);
            string joined = AppNames.Join(names);
            bool oneApp = names.Count <= 1, oneShortcut = rows.Length == 1;
            if (updated && added) return String.Format(oneApp ? ReapplyTexts.SharedMixedOneApp : ReapplyTexts.SharedMixed, joined);
            if (added) return String.Format(!oneApp ? ReapplyTexts.SharedNewMany : oneShortcut ? ReapplyTexts.SharedNew : ReapplyTexts.SharedNewOneApp, joined);
            return String.Format(!oneApp ? ReapplyTexts.SharedUpdatedMany : oneShortcut ? ReapplyTexts.SharedUpdated : ReapplyTexts.SharedUpdatedOneApp, joined);
        }
        // N3. "Put back" is said only when every shortcut was one an update had replaced.
        static string SharedDoneText(int done, bool anyNew)
        {
            if (anyNew) return done == 1 ? ReapplyTexts.SharedDoneNew : String.Format(ReapplyTexts.SharedDoneNewMany, done);
            return done == 1 ? ReapplyTexts.SharedDone : String.Format(ReapplyTexts.SharedDoneMany, done);
        }
        void ShowNotices(List<Notice> notices)
        {
            Notice first = notices.Where(n => !n.TooltipOnly).OrderBy(n => n.Rank).FirstOrDefault();
            if (first == null) return;
            ShowNotice(first.Text, String.Join(Environment.NewLine, notices.OrderBy(n => n.Rank).Select(n => n.Text).Distinct()));
        }
        // The status line stays one line; its tooltip lists every notice of the check.
        void ShowNotice(string text, string details = null)
        {
            noticeText = text;
            status.Text = text;
            appearanceTips.SetToolTip(status, details ?? text);
        }
        // Any other text on the status line takes the tooltip of a notice away with it.
        void StatusTextChanged()
        {
            if (status.Text == noticeText) return;
            noticeText = null;
            appearanceTips.SetToolTip(status, null);
        }
        void UpdateAppsFromReply(AppEntry[] fresh)
        {
            if (fresh == null || catalog == null) return;
            string before = AppsSignature(catalog.Apps);
            catalog.Apps = fresh;
            if (fixtureLog == null && !IsDisposed) {
                if (runningTaskbarIcons == null) runningTaskbarIcons = new RunningTaskbarIcons();
                runningTaskbarIcons.Update(catalog.Apps);
            }
            if (AppsSignature(catalog.Apps) != before) RenderApps();
            RebuildTrayMenu();
        }
        string AppsSignature(IEnumerable<AppEntry> entries)
        {
            return String.Join("\n", (entries ?? new AppEntry[0]).Select(a => String.Join("|", a.Shortcut, a.Target, a.IconPath, a.IconIndex, a.AppliedIconPath, a.Change))) +
                "\n" + String.Join("|", preferences.DefaultShortcuts ?? new string[0]);
        }
        void RebuildTrayMenu()
        {
            if (trayMenu.Visible) { trayMenuStale = true; return; }
            BuildTrayMenu();
        }
        async Task RefreshInstalledApps()
        {
            await RefreshCatalog();
            // Not now lasts until the shortcuts change, or until the user asks to look again.
            if (reapplyStore != null) {
                foreach (ReapplyItem item in reapplyStore.Data.Items.Values) item.DismissedHash = null;
                reapplyStore.Save();
            }
            ScheduleReconcile(TimeSpan.Zero, false);
        }

        // ---- Shared shortcuts -----------------------------------------------------------------
        // Windows elevates without asking: this process is elevated, or UAC is on and set to elevate administrators without a prompt.
        bool WindowsElevatesWithoutAsking(bool fresh)
        {
            if (fixtureSettings != null) return fixtureSettings.SilentElevation ?? false;
            if (silentElevation.HasValue && !fresh) return silentElevation.Value;
            bool silent = false;
            try {
                if (IsAdministrator()) silent = true;
                else {
                    int type, size;
                    using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
                        if (!GetTokenInformation(identity.Token, 18, out type, 4, out size)) type = 0;
                    if (type == 2) silent = true;
                    else if (type == 3)
                        using (RegistryKey policy = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System")) {
                            object lua = policy == null ? null : policy.GetValue("EnableLUA"), consent = policy == null ? null : policy.GetValue("ConsentPromptBehaviorAdmin");
                            silent = lua is int && (int)lua == 1 && consent is int && (int)consent == 0;
                        }
                }
            }
            catch (Exception error) { Trace.WriteLine("BetterIcon elevation check: " + error.Message); silent = false; }
            silentElevation = silent;
            return silent;
        }
        // On by default where Windows elevates without asking. Never anywhere else, so the background never prompts.
        bool AutomaticSharedReapply(bool fresh) { return !autoSharedOff && (preferences.AutoReapplyShared ?? true) && WindowsElevatesWithoutAsking(fresh); }
        Control BuildSharedActions()
        {
            sharedActions = new FlowLayoutPanel { Name = "SharedReapplyActions", AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, WrapContents = true,
                Dock = DockStyle.Top, Visible = false, Margin = new Padding(4, 4, 4, 0), Padding = Padding.Empty };
            LinkLabel action = new LinkLabel { Name = "SharedReapplyLink", Text = ReapplyTexts.SharedAction, AutoSize = true, UseMnemonic = false, LinkBehavior = LinkBehavior.HoverUnderline,
                Margin = new Padding(0, 0, 18, 0), AccessibleName = "Apply your icons to shared shortcuts", AccessibleDescription = ReapplyTexts.SharedActionTip };
            appearanceTips.SetToolTip(action, ReapplyTexts.SharedActionTip);
            action.LinkClicked += async delegate { await ReapplySharedIcons(false); };
            LinkLabel notNow = new LinkLabel { Name = "SharedReapplyNotNow", Text = ReapplyTexts.NotNow, AutoSize = true, UseMnemonic = false, LinkBehavior = LinkBehavior.HoverUnderline,
                Margin = Padding.Empty, AccessibleName = ReapplyTexts.NotNow, AccessibleDescription = ReapplyTexts.NotNowTip };
            appearanceTips.SetToolTip(notNow, ReapplyTexts.NotNowTip);
            notNow.LinkClicked += delegate { DismissShared(); };
            sharedActions.Controls.Add(action); sharedActions.Controls.Add(notNow);
            return sharedActions;
        }
        void AddSharedReapplyItems()
        {
            if (pendingShared.Length > 0 && !AutomaticSharedReapply(false)) {
                if (shieldImage == null) shieldImage = SystemIcons.Shield.ToBitmap();
                ToolStripMenuItem item = new ToolStripMenuItem(ReapplyTexts.SharedAction) { Name = "SharedReapplyItem", Enabled = !busy && !sharedRunning, Image = shieldImage, ToolTipText = ReapplyTexts.SharedActionTip };
                item.Click += async delegate { await ReapplySharedIcons(false); };
                trayMenu.Items.Add(item);
            }
            if (WindowsElevatesWithoutAsking(false)) {
                // The checkmark shows whether it is on now: after Windows refused, it is off for this session.
                ToolStripMenuItem automatic = new ToolStripMenuItem(ReapplyTexts.Automatic) { Name = "AutomaticSharedItem", Checked = AutomaticSharedReapply(false), Enabled = !busy };
                if (autoSharedOff && (preferences.AutoReapplyShared ?? true)) automatic.ToolTipText = ReapplyTexts.AutomaticPaused;
                automatic.Click += delegate { ToggleAutomaticShared(); };
                trayMenu.Items.Add(automatic);
            }
        }
        void ToggleAutomaticShared()
        {
            // A click turns over what the menu shows, and is a fresh choice either way.
            bool on = !AutomaticSharedReapply(false);
            preferences.AutoReapplyShared = on;
            autoSharedOff = false;
            try { WritePreferences(); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            UpdateSharedActions();
            if (on && pendingShared.Length > 0) ScheduleReconcile(TimeSpan.Zero, false);
        }
        // Added under the status line the first time shared shortcuts wait, with the window's colors.
        void EnsureSharedActions()
        {
            if (sharedActions != null || shortcutsSection == null) return;
            Control row = BuildSharedActions();
            shortcutsSection.SuspendLayout();
            try { SettingsRow(shortcutsSection, row); }
            finally { shortcutsSection.ResumeLayout(true); }
            if (appearancePalette != null) AppAppearance.Apply(row, appearancePalette);
        }
        void UpdateSharedActions()
        {
            bool offer = pendingShared.Length > 0 && !AutomaticSharedReapply(false);
            if (offer) EnsureSharedActions();
            // Set every time: Visible reads false while the window is hidden, and a row that ended then must not come back.
            if (sharedActions != null) sharedActions.Visible = offer;
            RebuildTrayMenu();
            if (!offer || reapplyStore == null) return;
            // One balloon for each new set, and only while the window is hidden.
            string digest;
            using (SHA256 sha = SHA256.Create())
                digest = BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(String.Join("\n", pendingShared.Select(r => (r.Shortcut ?? "").ToLowerInvariant() + "|" + r.Hash).OrderBy(s => s, StringComparer.Ordinal))))).Replace("-", "");
            if (digest == reapplyStore.Data.SharedBalloon) return;
            reapplyStore.Data.SharedBalloon = digest;
            if (Visible) return;
            bool anyNew = AnyNew(pendingShared);
            string text = pendingShared.Length == 1 ? (anyNew ? ReapplyTexts.BalloonOneNew : ReapplyTexts.BalloonOne) : String.Format(anyNew ? ReapplyTexts.BalloonManyNew : ReapplyTexts.BalloonMany, pendingShared.Length);
            if (fixtureLog == null) tray.ShowBalloonTip(6000, "BetterIcon", text, ToolTipIcon.Info);
            else TraceFixture("Shared balloon");
        }
        void DismissShared()
        {
            foreach (ResultItem row in pendingShared) { ReapplyItem item = Item(row, true); if (item != null) item.DismissedHash = row.Hash; }
            pendingShared = new ResultItem[0];
            if (reapplyStore != null) reapplyStore.Save();
            UpdateSharedActions();
        }
        // Apply icons or Restore app defaults for all users just changed the shared shortcuts: what waits for an
        // administrator is looked at again, instead of offering a pass that would find nothing to do.
        void SharedScopeChanged()
        {
            pendingShared = new ResultItem[0];
            UpdateSharedActions();
            ScheduleReconcile(TimeSpan.Zero, false);
        }
        // Another BetterIcon operation held the shared records longer than the pass waits: try again later.
        static bool LockedOut(Exception error) { return error != null && (error.Message ?? "").StartsWith("Cannot lock state directory", StringComparison.Ordinal); }
        // One elevated pass for every shared shortcut that waits: re-applied, new and set back by hand. A pass a
        // person started ends with a word on the status line; an automatic one returns its notices to its check.
        async Task<List<Notice>> ReapplySharedIcons(bool automatic)
        {
            var notices = new List<Notice>();
            if (sharedRunning || (!automatic && busy) || IsDisposed || Disposing) return notices;
            sharedRunning = true;
            // What the pass covers decides its wording: put back after updates, or applied to new shortcuts too.
            bool anyNew = AnyNew(pendingShared);
            if (!automatic) SetBusy(true, anyNew ? ReapplyTexts.SharedBusyNew : ReapplyTexts.SharedBusy);
            try {
                if (!automatic) await WaitForReconcile();
                ResultItem[] rows;
                if (fixtureSettings != null) rows = FixtureElevation(automatic);
                else {
                    WorkerRequest request = new WorkerRequest { Action = "ReapplyShared", Scope = "AllUsers", Skip = SkipList(), SkipApps = KeptApps(), ThemeNew = ThemesNewShortcuts() };
                    WorkerReply reply = await worker.Run(request, !IsAdministrator());
                    if (IsDisposed || Disposing) return notices;
                    UpdateAppsFromReply(reply.Apps);
                    rows = reply.Results ?? new ResultItem[0];
                }
                notices = HandleSharedRows(rows, !automatic);
            }
            catch (Exception error) {
                if (IsDisposed || Disposing) return notices;
                Win32Exception native = error as Win32Exception;
                if (automatic && LockedOut(error)) {
                    // Not a refusal: the option stays on and the pass comes again with the next check.
                    ScheduleReconcile(TimeSpan.FromSeconds(InFluxRetrySeconds[0]), false);
                }
                else if (automatic) {
                    // Off for this session. The click stays offered, and the background never asks.
                    autoSharedOff = true;
                    notices.Add(Note(1, anyNew ? ReapplyTexts.AutomaticFailedNew : ReapplyTexts.AutomaticFailed));
                }
                else notices.Add(Note(1, native != null && native.NativeErrorCode == 1223 ? ReapplyTexts.SharedCancelled : String.Format(anyNew ? ReapplyTexts.SharedFailedNew : ReapplyTexts.SharedFailed, error.Message)));
                UpdateSharedActions();
            }
            finally {
                sharedRunning = false; ownWritesUntil = DateTime.UtcNow.AddSeconds(10);
                if (!IsDisposed && !Disposing) {
                    if (!automatic) { ShowNotices(notices); notices = new List<Notice>(); SetBusy(false, null); }
                    else FlushShortcutEvents();
                }
            }
            return notices;
        }
        // Fixture mode never starts an elevated helper. The probe stands in for Windows' answer: "Cancel" (the
        // default), "Allow", "InFlux" (still being updated), "None" (nothing to write) or "Locked".
        ResultItem[] FixtureElevation(bool automatic)
        {
            TraceFixture(automatic ? "Elevation requested (automatic)" : "Elevation requested");
            switch (fixtureSettings.ElevationProbe) {
                case "Allow":
                    return pendingShared.Select(r => new ResultItem { Shortcut = r.Shortcut, Status = r.Change == "New" ? "Applied" : "Reapplied", Message = "", Application = r.Application, Scope = "AllUsers", Change = r.Change, Hash = r.Hash, Detail = r.Detail }).ToArray();
                case "InFlux":
                    return pendingShared.Select(r => new ResultItem { Shortcut = r.Shortcut, Status = "InFlux", Message = "Being updated. BetterIcon tries again later.", Application = r.Application, Scope = "AllUsers", Change = r.Change, Hash = r.Hash, Detail = r.Detail }).ToArray();
                case "None": return new ResultItem[0];
                case "Locked": throw new InvalidOperationException("Cannot lock state directory 'fixture'. Another operation may be running, or the directory is not writable.");
                default: throw new Win32Exception(1223);
            }
        }
        List<Notice> HandleSharedRows(ResultItem[] rows, bool manual)
        {
            var notices = new List<Notice>();
            DateTime now = DateTime.UtcNow;
            int done = 0;
            foreach (ResultItem row in rows) {
                if (String.IsNullOrEmpty(row.Scope)) row.Scope = "AllUsers";
                string app = AppOf(row);
                ReapplyItem item;
                if (row.Status == "Reapplied" || row.Status == "Applied") { done++; RecordAttempt(row, now); }
                else if (row.Status == "Refused") {
                    item = Item(row, true); if (item != null) item.RefusedHash = row.Hash;
                    if (Once(row, "Refused")) notices.Add(Note(2, String.Format(ReapplyTexts.Refused, app)));
                }
                else if (row.Status == "Restored") { item = Item(row, true); if (item != null) item.HandsOff = true; }
                else if (row.Status == "IconMissing") {
                    item = Item(row, true); if (item != null) item.RefusedHash = row.Hash;
                    if (Once(row, "IconMissing")) notices.Add(Note(10, String.Format(ReapplyTexts.IconMissing, app)));
                }
                else if (row.Status == "Changed" && Once(row, "Changed")) notices.Add(Note(7, String.Format(ReapplyTexts.ChangedOutside, app)));
            }
            RememberOwnWrites(rows, true);
            RememberRestoredRows(rows.Where(r => r.Status == "Restored"));
            if (done > 0) notices.Add(Note(4, SharedDoneText(done, rows.Any(r => (r.Status == "Reapplied" || r.Status == "Applied") && r.Change == "New"))));
            // Shortcuts still being written are offered again after a short wait, which grows if they stay that way.
            bool waiting = rows.Any(r => r.Status == "InFlux");
            ScheduleInFluxRetry(rows, "AllUsers");
            if (manual && waiting) notices.Add(Note(9, ReapplyTexts.SharedStillUpdating));
            // A pass a person started always ends with a word, never with its busy text.
            if (manual && !notices.Any(n => !n.TooltipOnly)) notices.Add(Note(12, ReapplyTexts.SharedNothing));
            pendingShared = new ResultItem[0];
            UpdateSharedActions();
            if (reapplyStore != null) reapplyStore.Save();
            return notices;
        }
        List<Notice> FileIconNotices(List<ProjectReconcileRow> rows)
        {
            var notices = new List<Notice>();
            List<string> back = rows.Where(r => r.Status == "Reapplied" || r.Status == "Rebased").Select(r => AppNames.Display(r.Application ?? r.Target)).Distinct().ToList();
            if (back.Count > 0) notices.Add(Note(4, String.Format(back.Count == 1 ? ReapplyTexts.FilesBack : ReapplyTexts.FilesBackMany, AppNames.Join(back))));
            foreach (ProjectReconcileRow row in rows.Where(r => r.Status == "Changed")) {
                ResultItem key = new ResultItem { Scope = "CurrentUser", Shortcut = "files\\" + row.Target, Hash = row.Value ?? "" };
                if (reapplyStore == null || Once(key, "FilesChanged")) notices.Add(Note(7, String.Format(ReapplyTexts.FilesChanged, AppNames.Display(row.Application ?? row.Target))));
            }
            if (reapplyStore != null) reapplyStore.Save();
            return notices;
        }
    }
}
