// Native Windows tray UI. Build locally with the .NET Framework compiler.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace BetterIcon.Tray
{
    public sealed class AppEntry
    {
        public string Application { get; set; }
        public string Name { get; set; }
        public string Shortcut { get; set; }
        public string Scope { get; set; }
        public string IconPath { get; set; }
        public int IconIndex { get; set; }
        public string OriginalIconPath { get; set; }
        public int OriginalIconIndex { get; set; }
        public bool RestoreAvailable { get; set; }
    }
    public sealed class ThemeIcon { public string Application { get; set; } public string Path { get; set; } }
    public sealed class ThemeEntry
    {
        public const string DefaultThemeId = "ArtCraft/Default";
        public bool IsDefault { get; set; }
        public string Id { get; set; }
        public string Name { get; set; }
        public string Pack { get; set; }
        public string Author { get; set; }
        public int IconCount { get; set; }
        public bool Managed { get; set; }
        public string LibraryId { get; set; }
        public ThemeIcon[] Icons { get; set; }
        public override string ToString()
        {
            if (IsDefault) return "ArtCraft default";
            string author = Author ?? (Managed ? "" : (Pack ?? "").Replace("Craft-Icons-", ""));
            string title = Name == "Root" && !Managed ? author : Name + (String.IsNullOrWhiteSpace(author) ? "" : " / " + author);
            return title + (Managed ? " (personal)" : "");
        }
    }
    public sealed class Catalog { public string Version { get; set; } public AppEntry[] Apps { get; set; } public ThemeEntry[] Themes { get; set; } }
    public sealed class PlanItem
    {
        public string Application { get; set; }
        public string Shortcut { get; set; }
        public string Icon { get; set; }
        public string Theme { get; set; }
        public string Status { get; set; }
        public string Reason { get; set; }
        public string OriginalHash { get; set; }
    }
    public sealed class ResultItem { public string Shortcut { get; set; } public string Status { get; set; } public string Message { get; set; } }
    public sealed class WorkerRequest
    {
        public string Action { get; set; }
        public string Application { get; set; }
        public string Theme { get; set; }
        public string Scope { get; set; }
        public string[] ShortcutDirectory { get; set; }
        public string StateDirectory { get; set; }
        public PlanItem[] ExpectedPlan { get; set; }
        public string ExpectedStateHash { get; set; }
        public string PackDirectory { get; set; }
    }
    public sealed class WorkerReply
    {
        public bool Success { get; set; }
        public string Error { get; set; }
        public Catalog Catalog { get; set; }
        public PlanItem[] Plan { get; set; }
        public ResultItem[] Results { get; set; }
        public string StateHash { get; set; }
    }
    // Optional developer fixture configuration. Both fields are required so a
    // disposable test cannot accidentally fall back to the user's real folders.
    public sealed class FixtureConfig { public string[] ShortcutDirectory { get; set; } public string StateDirectory { get; set; } public bool KeepOpenForAutomation { get; set; } }
    public sealed class Preferences
    {
        public const int DefaultIconSize = 48, MinimumIconSize = 24, MaximumIconSize = 128;
        int iconSize = DefaultIconSize;
        public string Theme { get; set; }
        public string Scope { get; set; }
        public HotkeySettings Hotkey { get; set; }
        public string[] DefaultShortcuts { get; set; }
        public int IconSize { get { return iconSize; } set { iconSize = Math.Max(MinimumIconSize, Math.Min(MaximumIconSize, value)); } }
        public Preferences() { Hotkey = new HotkeySettings(); DefaultShortcuts = new string[0]; }
    }

    public sealed class WorkerClient
    {
        readonly string sourceFolder;
        readonly FixtureConfig fixture;
        public WorkerClient(string source, FixtureConfig config) { sourceFolder = source; fixture = config; }
        public static string Quote(string value)
        {
            if (value.IndexOf('"') >= 0) throw new ArgumentException("Invalid quote in a file path.");
            int slashCount = value.Length - value.TrimEnd('\\').Length;
            return "\"" + value + new string('\\', slashCount) + "\"";
        }
        public Task<WorkerReply> Run(WorkerRequest request, bool elevate)
        {
            if (fixture != null) { request.ShortcutDirectory = fixture.ShortcutDirectory; request.StateDirectory = fixture.StateDirectory; }
            request.PackDirectory = Path.Combine(fixture == null ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BetterIcon-Craft Apps") : fixture.StateDirectory, "packs");
            return Task.Run(delegate {
                string folder = Path.Combine(Path.GetTempPath(), "BetterIcon-Tray-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(folder);
                string input = Path.Combine(folder, "request.json"), output = Path.Combine(folder, "response.json");
                try {
                    JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = 16777216 };
                    File.WriteAllText(input, json.Serialize(request), new UTF8Encoding(false));
                    ProcessStartInfo start = new ProcessStartInfo {
                        FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"),
                        Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(Path.Combine(sourceFolder, "BetterIcon.TrayWorker.ps1")) + " -RequestPath " + Quote(input) + " -ResponsePath " + Quote(output),
                        UseShellExecute = elevate, CreateNoWindow = !elevate, WindowStyle = ProcessWindowStyle.Hidden
                    };
                    if (elevate) start.Verb = "runas";
                    else { start.RedirectStandardOutput = true; start.RedirectStandardError = true; }
                    using (Process process = Process.Start(start)) {
                        Task<string> stdout = elevate ? null : process.StandardOutput.ReadToEndAsync();
                        Task<string> stderr = elevate ? null : process.StandardError.ReadToEndAsync();
                        process.WaitForExit();
                        if (stdout != null) stdout.Wait();
                        if (stderr != null) stderr.Wait();
                        if (!File.Exists(output)) throw new InvalidOperationException("The Windows helper did not return a result. " + (stderr == null ? "" : stderr.Result));
                    }
                    WorkerReply reply = json.Deserialize<WorkerReply>(File.ReadAllText(output, Encoding.UTF8));
                    if (reply == null || !reply.Success) throw new InvalidOperationException(reply == null ? "Invalid helper response." : reply.Error);
                    return reply;
                }
                finally {
                    // Delete only this request's known files, never sweep a folder.
                    try { if (File.Exists(input)) File.Delete(input); if (File.Exists(output)) File.Delete(output); Directory.Delete(folder, false); }
                    catch (IOException) { }
                    catch (UnauthorizedAccessException) { }
                }
            });
        }
    }

    public static class PopupPlacement
    {
        public static Rectangle AboveTray(Size size, Point anchor, Rectangle work)
        {
            return Place(size, anchor, work, false);
        }
        public static Rectangle CenteredOnCursor(Size size, Point cursor, Rectangle work)
        {
            return Place(size, cursor, work, true);
        }
        static Rectangle Place(Size size, Point anchor, Rectangle work, bool centered)
        {
            if (work.Width < 1 || work.Height < 1) throw new ArgumentException("Invalid screen working area.");
            int gap = Math.Min(8, (Math.Min(work.Width, work.Height) - 1) / 2);
            int width = Math.Max(1, Math.Min(size.Width, work.Width - gap * 2));
            int height = Math.Max(1, Math.Min(size.Height, work.Height - gap * 2));
            int x = Math.Max(work.Left + gap, Math.Min(anchor.X - width / 2, work.Right - gap - width));
            int y = Math.Max(work.Top + gap, Math.Min(centered ? anchor.Y - height / 2 : anchor.Y - gap - height, work.Bottom - gap - height));
            return new Rectangle(x, y, width, height);
        }
    }

    // Keep native list selection, accessibility and keyboard navigation, with labels below the artwork.
    public sealed class IconGridView : ListView
    {
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
        int iconSize = Preferences.DefaultIconSize;
        public event Action<int> IconSizeWheel;
        public event Action<Point?> IconMenuRequested;
        public Size GridCellSize { get { return new Size(Math.Max(112, iconSize + 24), iconSize + Font.Height * 2 + 16); } }
        public IconGridView() { View = View.LargeIcon; AutoArrange = true; Alignment = ListViewAlignment.Top; LabelWrap = true; DoubleBuffered = true; }
        public void SetIconSize(int size) { iconSize = size; UpdateSpacing(); }
        protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); UpdateSpacing(); }
        protected override void OnFontChanged(EventArgs e) { base.OnFontChanged(e); UpdateSpacing(); }
        protected override void WndProc(ref Message message)
        {
            // WM_CONTEXTMENU covers right-click, Shift+F10 and the menu key.
            if (message.Msg == 0x007B && IconMenuRequested != null) {
                long position = message.LParam.ToInt64();
                IconMenuRequested(unchecked((int)position) == -1 ? (Point?)null : PointToClient(new Point(unchecked((short)position), unchecked((short)(position >> 16)))));
                message.Result = IntPtr.Zero; return;
            }
            // Consume Ctrl+wheel before the native list scrolls; ordinary wheel input still scrolls normally.
            if (message.Msg == 0x020A && (message.WParam.ToInt64() & 0x0008) != 0 && IconSizeWheel != null) {
                IconSizeWheel(unchecked((short)(message.WParam.ToInt64() >> 16)));
                message.Result = IntPtr.Zero; return;
            }
            base.WndProc(ref message);
        }
        void UpdateSpacing()
        {
            if (!IsHandleCreated) return;
            Size cell = GridCellSize;
            // LVM_SETICONSPACING includes the image itself plus room for two lines of text.
            SendMessage(Handle, 0x1035, IntPtr.Zero, new IntPtr((cell.Height << 16) | cell.Width));
            ArrangeIcons(ListViewAlignment.Top);
        }
    }

    public sealed partial class LauncherForm : Form
    {
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window, int command);
        readonly WorkerClient worker;
        readonly NotifyIcon tray;
        readonly ContextMenuStrip trayMenu = new ContextMenuStrip();
        readonly ContextMenuStrip iconMenu = new ContextMenuStrip();
        readonly ToolStripMenuItem restoreIconDefault = new ToolStripMenuItem("Restore ArtCraft default...");
        AppEntry iconMenuTarget;
        readonly ComboBox themes = new ComboBox();
        readonly ComboBox scopes = new ComboBox();
        readonly IconGridView apps = new IconGridView();
        readonly List<ListViewItem> appTiles = new List<ListViewItem>();
        readonly List<Bitmap> appArtwork = new List<Bitmap>();
        readonly Label filterHint = new Label();
        readonly Label status = new Label();
        readonly Label previewLabel = new Label();
        readonly Label subtitle = new Label();
        readonly Button apply = new Button(), restore = new Button(), exit = new Button(), settings = new Button();
        readonly ImageList pictures = new ImageList();
        readonly EventWaitHandle showEvent, stopEvent;
        readonly System.Windows.Forms.Timer signalTimer = new System.Windows.Forms.Timer();
        readonly System.Windows.Forms.Timer dismissTimer = new System.Windows.Forms.Timer();
        readonly string preferencesPath;
        readonly string fixtureLog;
        readonly bool startInTray;
        Catalog catalog;
        Preferences preferences = new Preferences();
        GlobalHotkey hotkey;
        bool busy, exiting, notified;
        Point? trayAnchor;
        string filterText = "";
        readonly Color ink = Color.FromArgb(26, 39, 58), accent = Color.FromArgb(41, 100, 208);

        public LauncherForm(string source, FixtureConfig fixture, bool hidden, EventWaitHandle show, EventWaitHandle stop)
        {
            worker = new WorkerClient(source, fixture); startInTray = hidden; showEvent = show; stopEvent = stop;
            string state = fixture == null ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BetterIcon-Craft Apps") : fixture.StateDirectory;
            preferencesPath = Path.Combine(state, "tray-preferences.json");
            library = new PackLibrary(Path.Combine(state, "packs"));
            if (fixture != null) fixtureLog = Path.Combine(state, "tray-events.jsonl");
            try { if (File.Exists(preferencesPath)) preferences = new JavaScriptSerializer().Deserialize<Preferences>(File.ReadAllText(preferencesPath)) ?? preferences; } catch (Exception) { }
            if (preferences.Hotkey == null) preferences.Hotkey = new HotkeySettings();
            Text = "BetterIcon for ArtCraft"; Name = "BetterIconLauncher";
            Font = new Font("Segoe UI", 10F); ForeColor = ink; BackColor = Color.FromArgb(244, 247, 251);
            AutoScaleMode = AutoScaleMode.Font; ClientSize = new Size(900, 690); MinimumSize = new Size(790, 570);
            StartPosition = FormStartPosition.Manual; MaximizeBox = false; MinimizeBox = false;
            KeyPreview = true; Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            BuildWindow(fixture != null);
            tray = new NotifyIcon { Icon = Icon, Text = "BetterIcon for ArtCraft", Visible = true, ContextMenuStrip = trayMenu };
            // MouseUp sees both releases of a double-click, just like two clicks.
            tray.MouseUp += delegate(object sender, MouseEventArgs e) {
                trayAnchor = Cursor.Position;
                if (e.Button == MouseButtons.Left) ToggleAboveTray(trayAnchor.Value);
            };
            // Focus changes on mouse-down. Wait for mouse-up so a second tray
            // click can hide the still-visible popup instead of reopening it.
            dismissTimer.Interval = 100;
            dismissTimer.Tick += delegate {
                if (ContainsFocus) { dismissTimer.Stop(); return; }
                if (fixture != null && fixture.KeepOpenForAutomation) { dismissTimer.Stop(); return; }
                if (Control.MouseButtons != MouseButtons.None || trayMenu.Visible || iconMenu.Visible || importPackMenu.Visible || managePackMenu.Visible || busy || !Enabled || themes.DroppedDown || scopes.DroppedDown || restoreAppPicker.DroppedDown) return;
                dismissTimer.Stop(); Hide();
            };
            Deactivate += delegate { TraceFixture("Deactivated"); if (Visible) dismissTimer.Start(); };
            Activated += delegate { dismissTimer.Stop(); TraceFixture("Activated"); };
            VisibleChanged += delegate { if (!Visible) dismissTimer.Stop(); TraceFixture(Visible ? "Shown" : "Hidden"); };
            signalTimer.Interval = 250;
            signalTimer.Tick += delegate { if (showEvent.WaitOne(0)) { TraceFixture("Show signal"); ShowManager(); } if (stopEvent.WaitOne(0)) ExitLauncher(); };
            signalTimer.Start();
            FormClosing += delegate(object sender, FormClosingEventArgs e) {
                if (!exiting && e.CloseReason == CloseReason.UserClosing) {
                    e.Cancel = true; Hide();
                    if (!notified) { tray.ShowBalloonTip(2500, "BetterIcon is in the tray", "Click its tray icon to return. Choose Exit to stop the launcher.", ToolTipIcon.Info); notified = true; }
                }
            };
            FormClosed += delegate { if (hotkey != null) hotkey.Dispose(); signalTimer.Stop(); signalTimer.Dispose(); dismissTimer.Stop(); dismissTimer.Dispose(); tray.Visible = false; tray.Dispose(); trayMenu.Dispose(); iconMenu.Dispose(); importPackMenu.Dispose(); managePackMenu.Dispose(); pictures.Dispose(); packPictures.Dispose(); };
            BuildTrayMenu();
        }

        public void Start()
        {
            // ApplicationContext keeps the message loop alive while the popup is
            // hidden; creating its handle also enables asynchronous UI callbacks.
            CreateHandle();
            hotkey = new GlobalHotkey(delegate { ShowAtCursor(Cursor.Position); });
            string error;
            hotkey.TrySet(preferences.Hotkey, out error);
            UpdateHotkeyHint();
            BeginInvoke(new Action(async delegate { if (!startInTray) ShowManager(); await RefreshCatalog(); }));
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) { if (hotkey != null) hotkey.Dispose(); ClearAppArtwork(); ClearPackArtwork(); }
            base.Dispose(disposing);
        }

        void TraceFixture(string action, Point? anchor = null)
        {
            if (fixtureLog == null) return;
            try {
                Directory.CreateDirectory(Path.GetDirectoryName(fixtureLog));
                File.AppendAllText(fixtureLog, new JavaScriptSerializer().Serialize(new { Event = action, Utc = DateTime.UtcNow.ToString("o"), Visible, ContainsFocus, Bounds = new { Left, Top, Width, Height }, Anchor = anchor, WorkingArea = anchor.HasValue ? (Rectangle?)Screen.FromPoint(anchor.Value).WorkingArea : null }) + Environment.NewLine);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        static Button Button(string text, int width) { return new Button { Text = text, Width = width, Height = 34, FlatStyle = FlatStyle.Flat, UseVisualStyleBackColor = true, Margin = new Padding(4) }; }
        void BuildWindow(bool testing)
        {
            pages.Dock = DockStyle.Fill; pages.SizeMode = TabSizeMode.Fixed; pages.ItemSize = new Size(420, 38);
            pages.DrawMode = TabDrawMode.OwnerDrawFixed; pages.DrawItem += DrawPageTab;
            // Updating ItemSize from TabControl.SizeChanged re-enters native layout.
            // Resize only once layout settles, after showing or a user resize.
            ResizeEnd += delegate { SizeTabs(); };
            launcherPage.BackColor = Color.White; launcherPage.Padding = new Padding(18);
            settingsPage.BackColor = BackColor;
            pages.TabPages.AddRange(new[] { launcherPage, settingsPage }); Controls.Add(pages);
            pictures.ImageSize = new Size(preferences.IconSize, preferences.IconSize); pictures.ColorDepth = ColorDepth.Depth32Bit;
            // Force native copies before temporary thumbnails are disposed at hidden startup.
            if (pictures.Handle == IntPtr.Zero) throw new InvalidOperationException("Could not create the app icon list.");
            apps.Dock = DockStyle.Fill; apps.SetIconSize(preferences.IconSize); apps.LargeImageList = pictures;
            apps.MultiSelect = false; apps.HideSelection = false;
            apps.BorderStyle = BorderStyle.None; apps.BackColor = Color.White; apps.ShowItemToolTips = true; apps.AccessibleName = "Installed ArtCraft apps";
            apps.ItemActivate += delegate { LaunchSelected(); };
            apps.IconSizeWheel += ChangeIconSizeFromWheel;
            filterHint.Dock = DockStyle.Top; filterHint.Height = 42; filterHint.Text = "Finding installed apps...";
            filterHint.TextAlign = ContentAlignment.MiddleLeft;
            launcherPage.Controls.Add(apps); launcherPage.Controls.Add(filterHint);
            BuildSettingsPage(testing);
            iconMenu.ShowItemToolTips = true; iconMenu.Items.Add(restoreIconDefault);
            restoreIconDefault.Click += async delegate {
                AppEntry target = iconMenuTarget;
                if (!busy && target != null && target.RestoreAvailable) await RestoreIcons(target.Application, target.Scope);
            };
            apps.IconMenuRequested += point => ShowIconMenu(apps, point);
            packPreview.IconMenuRequested += point => ShowIconMenu(packPreview, point);
            pages.SelectedIndexChanged += delegate { pages.Invalidate(); if (pages.SelectedTab == launcherPage) apps.Focus(); };
        }
        string Scope { get { return scopes.SelectedIndex == 1 ? "AllUsers" : "CurrentUser"; } }
        ThemeEntry SelectedTheme { get { return themes.SelectedItem as ThemeEntry; } }
        static bool IsAdministrator() { return new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator); }
        void SetBusy(bool value, string message)
        {
            busy = value; apply.Enabled = restore.Enabled = themes.Enabled = scopes.Enabled = exit.Enabled = settings.Enabled = !value;
            if (value) { iconMenu.Close(); iconMenuTarget = null; restoreIconDefault.Enabled = false; }
            iconSizeSlider.Enabled = resetIconSize.Enabled = !value;
            UpdatePackButtons();
            if (!String.IsNullOrEmpty(message)) status.Text = message;
            UseWaitCursor = value; BuildTrayMenu();
        }
        public void ToggleAboveTray(Point anchor)
        {
            TraceFixture("Tray click");
            dismissTimer.Stop(); trayAnchor = anchor;
            if (!Enabled) { ActivateDialog(); return; }
            if (Visible && WindowState != FormWindowState.Minimized) { Hide(); return; }
            ShowManager();
        }
        public void ShowManager()
        {
            Rectangle work = Screen.FromPoint(trayAnchor ?? Cursor.Position).WorkingArea;
            Point anchor = trayAnchor ?? new Point(work.Right, work.Bottom);
            ShowPopup(anchor, false);
        }
        public void ShowAtCursor(Point cursor) { ShowPopup(cursor, true); }
        void ActivateDialog() { foreach (Form dialog in OwnedForms) if (dialog.Visible) { dialog.Activate(); break; } }
        void ShowPopup(Point anchor, bool centered)
        {
            if (!Enabled) { ActivateDialog(); return; }
            if (!Visible) SetFilter("");
            pages.SelectedTab = launcherPage;
            dismissTimer.Stop();
            Rectangle work = Screen.FromPoint(anchor).WorkingArea;
            WindowState = FormWindowState.Normal;
            Rectangle bounds = centered ? PopupPlacement.CenteredOnCursor(Size, anchor, work) : PopupPlacement.AboveTray(Size, anchor, work);
            MinimumSize = new Size(Math.Min(790, bounds.Width), Math.Min(570, bounds.Height));
            Bounds = bounds; Show();
            // Also works when launched with STARTUPINFO's initial hidden state.
            ShowWindow(Handle, 1);
            Bounds = centered ? PopupPlacement.CenteredOnCursor(Size, anchor, work) : PopupPlacement.AboveTray(Size, anchor, work); SizeTabs(); Activate(); apps.Focus();
            TraceFixture(centered ? "Hotkey positioned" : "Positioned", anchor);
        }
        void ExitLauncher() { if (busy) { ShowManager(); MessageBox.Show(this, "Please wait for the current operation to finish.", Text); return; } exiting = true; Close(); }
        void UpdateHotkeyHint()
        {
            string hint = !preferences.Hotkey.Enabled ? "Global hotkey disabled." : hotkey != null && hotkey.IsRegistered ? preferences.Hotkey + " opens at your cursor." : "Hotkey unavailable. Choose another combination.";
            subtitle.Text = (fixtureLog == null ? "" : "Test shortcuts only. ") + hint;
        }
        void ShowSettings()
        {
            if (busy || hotkey == null) return;
            if (!Enabled) { ActivateDialog(); return; }
            if (!Visible) ShowManager();
            pages.SelectedTab = settingsPage;
        }
        string SaveHotkey(HotkeySettings requested)
        {
            HotkeySettings previous = preferences.Hotkey;
            HotkeySettings binding = hotkey.Current == null ? new HotkeySettings { Enabled = false } : hotkey.Current.Copy();
            string error;
            if (!hotkey.TrySet(requested, out error)) return error;
            preferences.Hotkey = requested.Copy();
            try { WritePreferences(); }
            catch (Exception failure) {
                if (!(failure is IOException) && !(failure is UnauthorizedAccessException)) throw;
                preferences.Hotkey = previous;
                bool restored = hotkey.TrySet(binding, out error);
                UpdateHotkeyHint();
                return "Could not save settings: " + failure.Message + (restored ? " The previous hotkey is unchanged." : " The previous hotkey could not be restored; choose another combination.");
            }
            UpdateHotkeyHint();
            return null;
        }
        void WritePreferences()
        {
            Directory.CreateDirectory(Path.GetDirectoryName(preferencesPath));
            string temporary = preferencesPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try {
                File.WriteAllText(temporary, new JavaScriptSerializer().Serialize(preferences), new UTF8Encoding(false));
                if (File.Exists(preferencesPath)) File.Replace(temporary, preferencesPath, null);
                else File.Move(temporary, preferencesPath);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        void SavePreferences()
        {
            if (SelectedTheme != null) preferences.Theme = SelectedTheme.Id;
            preferences.Scope = Scope;
            try { WritePreferences(); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        async Task RefreshCatalog()
        {
            if (busy) return;
            SetBusy(true, "Finding apps and themes...");
            try {
                WorkerReply reply = await worker.Run(new WorkerRequest { Action = "Catalog", Scope = Scope }, false);
                catalog = reply.Catalog;
                bundledThemes = catalog.Themes;
                ReloadLibrary(null);
                status.Text = catalog.Apps.Select(a => a.Application).Distinct().Count() + " installed apps / " + catalog.Apps.Length + " launch shortcuts. Enter or double-click to open.";
                if (catalog.Apps.Length == 0) status.Text = "No ArtCraft shortcuts found. Install an app, then refresh from the tray menu.";
                Text = "BetterIcon for ArtCraft  " + catalog.Version;
            }
            catch (Exception error) { Report(error); }
            finally { SetBusy(false, null); }
        }
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        static extern int SHDefExtractIconW(string file, int index, uint flags, out IntPtr large, IntPtr small, uint size);
        [DllImport("user32.dll")]
        static extern bool DestroyIcon(IntPtr icon);
        static Bitmap Thumbnail(string path, Icon fallback, int size = 48, int iconIndex = 0)
        {
            Bitmap image = new Bitmap(size, size);
            try {
                if (String.IsNullOrEmpty(path) || !File.Exists(path)) throw new IOException();
                Image loaded;
                // The Shell decodes compressed ICO frames as well as indexed EXE/DLL resources.
                if (new[] { ".ico", ".exe", ".dll", ".icl" }.Contains(Path.GetExtension(path).ToLowerInvariant())) {
                    IntPtr handle = IntPtr.Zero;
                    try {
                        if (SHDefExtractIconW(path, iconIndex, 0, out handle, IntPtr.Zero, (uint)size) != 0 || handle == IntPtr.Zero) throw new IOException("No native icon available.");
                        using (Icon icon = Icon.FromHandle(handle)) loaded = icon.ToBitmap();
                    }
                    finally { if (handle != IntPtr.Zero) DestroyIcon(handle); }
                }
                else loaded = Image.FromFile(path);
                using (Image source = loaded)
                using (Graphics canvas = Graphics.FromImage(image)) {
                    canvas.Clear(Color.Transparent); canvas.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    float ratio = Math.Min((float)size / source.Width, (float)size / source.Height);
                    float width = source.Width * ratio, height = source.Height * ratio;
                    canvas.DrawImage(source, (size-width)/2, (size-height)/2, width, height);
                }
            }
            catch (Exception) { using (Graphics canvas = Graphics.FromImage(image)) canvas.DrawIcon(fallback, new Rectangle(0, 0, size, size)); }
            return image;
        }
        void ClearAppArtwork() { foreach (Bitmap image in appArtwork) image.Dispose(); appArtwork.Clear(); }
        static void ResizeArtwork(ImageList images, IEnumerable<Bitmap> artwork, int size)
        {
            images.Images.Clear(); images.ImageSize = new Size(size, size);
            // ImageSize recreates the native list; materialize it before temporary bitmaps are disposed.
            if (images.Handle == IntPtr.Zero) throw new InvalidOperationException("Could not resize icons.");
            foreach (Bitmap source in artwork) using (Bitmap scaled = new Bitmap(size, size)) {
                using (Graphics canvas = Graphics.FromImage(scaled)) {
                    canvas.Clear(Color.Transparent); canvas.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    canvas.DrawImage(source, new Rectangle(0, 0, size, size));
                }
                images.Images.Add(scaled);
            }
        }
        void RenderApps()
        {
            if (catalog == null) return;
            apps.BeginUpdate();
            try {
                apps.Items.Clear(); appTiles.Clear(); pictures.Images.Clear();
                ClearAppArtwork();
                ThemeEntry theme = SelectedTheme;
                foreach (AppEntry entry in catalog.Apps) {
                    bool original = (theme != null && theme.IsDefault) || (preferences.DefaultShortcuts ?? new string[0]).Contains(entry.Shortcut, StringComparer.OrdinalIgnoreCase);
                    ThemeIcon artwork = original || theme == null ? null : theme.Icons.FirstOrDefault(i => i.Application == entry.Application);
                    // Cache at the maximum launcher size so dragging the slider never rereads artwork from disk.
                    appArtwork.Add(Thumbnail(artwork == null ? Environment.ExpandEnvironmentVariables((original ? entry.OriginalIconPath : entry.IconPath) ?? "") : artwork.Path, Icon, Preferences.MaximumIconSize, artwork != null ? 0 : original ? entry.OriginalIconIndex : entry.IconIndex));
                    ListViewItem item = new ListViewItem(entry.Name, appArtwork.Count-1) { Tag = entry, ToolTipText = entry.Name + Environment.NewLine + entry.Shortcut };
                    appTiles.Add(item);
                }
                ResizeAppIcons();
            }
            finally { apps.EndUpdate(); }
        }
        void ResizeAppIcons()
        {
            ListViewItem selected = apps.SelectedItems.Count == 1 ? apps.SelectedItems[0] : null;
            int size = preferences.IconSize;
            apps.BeginUpdate();
            try {
                ResizeArtwork(pictures, appArtwork, size); apps.SetIconSize(size);
                FilterApps();
                if (selected != null && apps.Items.Contains(selected)) {
                    foreach (ListViewItem item in appTiles) item.Selected = item.Focused = false;
                    selected.Selected = selected.Focused = true; selected.EnsureVisible();
                }
            }
            finally { apps.EndUpdate(); }
        }
        // Filter existing tiles, so each keystroke does not reload artwork from disk.
        void FilterApps()
        {
            apps.BeginUpdate();
            try {
                apps.Items.Clear();
                foreach (ListViewItem item in appTiles) {
                    item.Selected = item.Focused = false;
                    if (item.Text.StartsWith(filterText, StringComparison.OrdinalIgnoreCase)) apps.Items.Add(item);
                }
                if (apps.Items.Count > 0) {
                    apps.Items[0].Selected = apps.Items[0].Focused = true;
                    if (apps.IsHandleCreated) apps.Items[0].EnsureVisible();
                }
                filterHint.Text = catalog == null ? "Finding installed apps..." : filterText.Length == 0 ? "No ArtCraft apps found. Open Settings to refresh." : "No apps match '" + filterText + "'. Backspace edits; Esc clears.";
                filterHint.Visible = apps.Items.Count == 0;
                apps.AccessibleDescription = (filterText.Length == 0 ? "Type an app name to filter. Enter opens. Escape closes." : "Filter: " + filterText + ". " + apps.Items.Count + " matches. Escape clears.") + " Ctrl+mouse wheel changes icon size.";
            }
            finally { apps.EndUpdate(); }
        }
        void SetFilter(string value) { filterText = value; FilterApps(); }
        bool CanFilter { get { return Enabled && pages.SelectedTab == launcherPage && !themes.DroppedDown && !scopes.DroppedDown && !restoreAppPicker.DroppedDown && !trayMenu.Visible && !iconMenu.Visible && !importPackMenu.Visible && !managePackMenu.Visible; } }
        bool HandlePopupKey(Keys key)
        {
            if (key == Keys.Escape && Enabled && pages.SelectedTab == settingsPage && !themes.DroppedDown && !scopes.DroppedDown && !restoreAppPicker.DroppedDown && !iconMenu.Visible && !busy) { pages.SelectedTab = launcherPage; apps.Focus(); return true; }
            if (!CanFilter) return false;
            if (key == Keys.Escape) {
                if (filterText.Length > 0) { SetFilter(""); apps.Focus(); }
                else if (!busy) Hide();
                return true;
            }
            if (key == Keys.Back || key == (Keys.Control | Keys.Back)) {
                if (filterText.Length > 0) {
                    int[] elements = System.Globalization.StringInfo.ParseCombiningCharacters(filterText);
                    SetFilter(key == Keys.Back ? filterText.Substring(0, elements[elements.Length - 1]) : "");
                }
                apps.Focus(); return true;
            }
            if (key == Keys.Enter && apps.ContainsFocus) { LaunchSelected(); return true; }
            return false;
        }
        protected override bool ProcessCmdKey(ref Message message, Keys keyData)
        {
            return HandlePopupKey(keyData) || base.ProcessCmdKey(ref message, keyData);
        }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (HandlePopupKey(e.KeyData)) { e.Handled = e.SuppressKeyPress = true; return; }
            base.OnKeyDown(e);
        }
        protected override void OnKeyPress(KeyPressEventArgs e)
        {
            if (CanFilter && (ModifierKeys & (Keys.Control | Keys.Alt)) == Keys.None && !Char.IsControl(e.KeyChar)) {
                if (filterText.Length < 120 && (filterText.Length > 0 || !Char.IsWhiteSpace(e.KeyChar))) SetFilter(filterText + e.KeyChar);
                apps.Focus(); e.Handled = true; return;
            }
            base.OnKeyPress(e);
        }
        void LaunchSelected() { if (apps.SelectedItems.Count == 1) Launch((AppEntry)apps.SelectedItems[0].Tag); }
        void ShowIconMenu(IconGridView grid, Point? point)
        {
            iconMenu.Close(); iconMenuTarget = null;
            if (busy || !Enabled || catalog == null) return;
            ListViewItem item = point.HasValue ? grid.GetItemAt(point.Value.X, point.Value.Y) : grid.SelectedItems.Cast<ListViewItem>().FirstOrDefault();
            if (item == null) return;
            AppEntry target = item.Tag as AppEntry;
            if (target == null) {
                string application = item.Tag as string;
                if (String.IsNullOrEmpty(application)) return;
                target = new AppEntry { Application = application, Scope = Scope,
                    RestoreAvailable = catalog.Apps.Any(app => app.Application == application && app.Scope == Scope && app.RestoreAvailable) };
            }
            foreach (ListViewItem selected in grid.SelectedItems.Cast<ListViewItem>().ToArray()) selected.Selected = false;
            item.Selected = item.Focused = true; grid.Focus();
            if (!point.HasValue) item.EnsureVisible();
            iconMenuTarget = target;
            restoreIconDefault.Enabled = target.RestoreAvailable;
            restoreIconDefault.ToolTipText = target.RestoreAvailable ? "Restore only " + target.Application + " in " + (target.Scope == "AllUsers" ? "shared shortcut locations (administrator)" : "your shortcut locations") + "." : "No BetterIcon backup to restore for this app in these locations.";
            Point anchor = point ?? new Point(item.Bounds.Left + item.Bounds.Width / 2, item.Bounds.Bottom);
            iconMenu.Show(grid, anchor);
        }
        void Launch(AppEntry entry)
        {
            try {
                if (!File.Exists(entry.Shortcut)) throw new FileNotFoundException("This shortcut is no longer available. Choose Refresh installed apps in the tray menu.");
                Process.Start(new ProcessStartInfo(entry.Shortcut) { UseShellExecute = true });
                status.Text = "Opened " + entry.Name + ".";
            }
            catch (Exception error) { Report(error); }
        }
        void BuildTrayMenu()
        {
            foreach (ToolStripItem item in trayMenu.Items.Cast<ToolStripItem>().ToArray()) item.Dispose();
            trayMenu.Items.Clear();
            ToolStripMenuItem manager = new ToolStripMenuItem("Open BetterIcon"); manager.Click += delegate { ShowManager(); }; trayMenu.Items.Add(manager);
            ToolStripMenuItem launchMenu = new ToolStripMenuItem("Launch an ArtCraft app");
            if (catalog != null) foreach (AppEntry entry in catalog.Apps) {
                AppEntry captured = entry;
                ToolStripMenuItem item = new ToolStripMenuItem(entry.Name + (entry.Scope == "AllUsers" ? " (shared)" : ""));
                item.Click += delegate { Launch(captured); }; launchMenu.DropDownItems.Add(item);
            }
            if (launchMenu.DropDownItems.Count == 0) launchMenu.DropDownItems.Add(new ToolStripMenuItem("No app shortcuts found") { Enabled = false });
            trayMenu.Items.Add(launchMenu);
            ToolStripMenuItem themeMenu = new ToolStripMenuItem("Change icon theme") { Enabled = !busy };
            if (catalog != null) foreach (ThemeEntry theme in catalog.Themes) {
                ThemeEntry captured = theme;
                ToolStripMenuItem item = new ToolStripMenuItem(theme.ToString());
                item.Click += delegate { ShowSettings(); themes.SelectedItem = captured; status.Text = "Pack preview selected. Choose locations, then Apply icons."; }; themeMenu.DropDownItems.Add(item);
            }
            trayMenu.Items.Add(themeMenu); trayMenu.Items.Add(new ToolStripSeparator());
            ToolStripMenuItem reload = new ToolStripMenuItem("Refresh installed apps") { Enabled = !busy }; reload.Click += async delegate { await RefreshCatalog(); }; trayMenu.Items.Add(reload);
            ToolStripMenuItem restoreItem = new ToolStripMenuItem("Restore original icons...") { Enabled = !busy }; restoreItem.Click += async delegate { ShowSettings(); await RestoreIcons(); }; trayMenu.Items.Add(restoreItem);
            ToolStripMenuItem settingsItem = new ToolStripMenuItem("Settings...") { Enabled = !busy }; settingsItem.Click += delegate { ShowSettings(); }; trayMenu.Items.Add(settingsItem);
            trayMenu.Items.Add(new ToolStripSeparator());
            ToolStripMenuItem quit = new ToolStripMenuItem("Exit BetterIcon") { Enabled = !busy }; quit.Click += delegate { ExitLauncher(); }; trayMenu.Items.Add(quit);
        }
        bool Review(string title, string description, IEnumerable<string[]> rows, bool canApply, string accept)
        {
            using (Form dialog = new Form { Text = title, Font = Font, StartPosition = FormStartPosition.CenterParent, Size = new Size(850, 530), MinimumSize = new Size(720, 430), MinimizeBox = false, MaximizeBox = false }) {
                TableLayoutPanel panel = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(18), RowCount = 3, ColumnCount = 1 };
                panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 72)); panel.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
                panel.Controls.Add(new Label { Text = description, Dock = DockStyle.Fill }, 0, 0);
                ListView list = new ListView { View = View.Details, Dock = DockStyle.Fill, FullRowSelect = true, GridLines = true };
                list.Columns.Add("Status", 100); list.Columns.Add("Shortcut", 470); list.Columns.Add("Details", 210);
                foreach (string[] row in rows) list.Items.Add(new ListViewItem(row)); panel.Controls.Add(list, 0, 1);
                FlowLayoutPanel buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft };
                Button cancel = Button("Cancel", 100); cancel.DialogResult = DialogResult.Cancel;
                Button ok = Button(accept, 220); ok.DialogResult = DialogResult.OK; ok.Enabled = canApply;
                buttons.Controls.Add(cancel); buttons.Controls.Add(ok); panel.Controls.Add(buttons, 0, 2); dialog.Controls.Add(panel);
                dialog.CancelButton = cancel; dialog.AcceptButton = ok;
                return dialog.ShowDialog(this) == DialogResult.OK;
            }
        }
        async Task ApplyTheme()
        {
            if (busy || SelectedTheme == null) return;
            if (SelectedTheme.IsDefault) { await RestoreIcons(); return; }
            string theme = SelectedTheme.Id, scope = Scope;
            bool refresh = false;
            SetBusy(true, "Preparing a preview. No icons changed yet...");
            try {
                WorkerReply preview = await worker.Run(new WorkerRequest { Action = "Preview", Theme = theme, Scope = scope }, false);
                int count = preview.Plan.Count(p => p.Status == "Ready");
                string note = "Apply " + SelectedTheme + " to " + count + " shortcut(s) in " + (fixtureLog != null ? "the test shortcut folders" : scope == "AllUsers" ? "the shared Desktop and Start menu" : "your Desktop and Start menu") + ". Original shortcuts are backed up.\r\n" +
                    (scope == "AllUsers" ? "Windows will request administrator access. " : "") + "Missing or ambiguous artwork is skipped. Existing taskbar pins may need re-pinning.";
                if (!Review("Review icon changes", note, preview.Plan.Select(p => new[] { p.Status, p.Shortcut, p.Reason }), count > 0, "Apply theme")) { status.Text = "Cancelled. No icons changed."; return; }
                status.Text = "Applying theme...";
                WorkerReply result = await worker.Run(new WorkerRequest { Action = "Apply", Theme = theme, Scope = scope, ExpectedPlan = preview.Plan }, scope == "AllUsers" && !IsAdministrator());
                RememberRestoredShortcuts(result.Results, false); refresh = true;
                ShowResults(result.Results, "Theme applied");
            }
            catch (Exception error) { Report(error); }
            finally { SetBusy(false, null); }
            if (refresh) await RefreshAfterChange();
        }
        // Keep successful per-shortcut defaults visible in the launcher across restarts.
        // A later successful pack application replaces only the affected overrides.
        void RememberRestoredShortcuts(ResultItem[] results, bool restored)
        {
            HashSet<string> defaults = new HashSet<string>(preferences.DefaultShortcuts ?? new string[0], StringComparer.OrdinalIgnoreCase);
            foreach (ResultItem result in results) {
                if (String.IsNullOrEmpty(result.Shortcut)) continue;
                if (restored && result.Status == "Restored") defaults.Add(result.Shortcut);
                else if (!restored && (result.Status == "Applied" || result.Status == "Unchanged")) defaults.Remove(result.Shortcut);
            }
            preferences.DefaultShortcuts = defaults.OrderBy(s => s, StringComparer.OrdinalIgnoreCase).ToArray(); SavePreferences();
        }
        async Task RefreshAfterChange()
        {
            string message = status.Text;
            await RefreshCatalog();
            status.Text = message;
        }
        async Task RestoreIcons(string application = null, string scopeOverride = null)
        {
            if (busy) return;
            bool refresh = false;
            string scope = scopeOverride ?? Scope; SetBusy(true, "Checking original shortcut backups...");
            try {
                WorkerReply preview = await worker.Run(new WorkerRequest { Action = "RestorePreview", Scope = scope, Application = application }, false);
                if (preview.Results.Length == 0) { status.Text = "No BetterIcon changes to restore" + (application == null ? "" : " for " + application) + " in these locations."; return; }
                string note = "Restore " + (application == null ? "all original ArtCraft shortcuts" : "only " + application + " shortcuts") + " in " + (fixtureLog != null ? "the test shortcut folders." : scope == "AllUsers" ? "shared locations (administrator access required)." : "your locations.") + "\r\nLater user edits and app updates are preserved. Backups and icon files remain available for recovery.";
                if (!Review("Review restoration", note, preview.Results.Select(r => new[] { r.Status, r.Shortcut, r.Message }), true, "Restore original icons")) { status.Text = "Cancelled. No icons changed."; return; }
                status.Text = "Restoring original icons...";
                WorkerReply result = await worker.Run(new WorkerRequest { Action = "Restore", Scope = scope, Application = application, ExpectedStateHash = preview.StateHash }, scope == "AllUsers" && !IsAdministrator());
                RememberRestoredShortcuts(result.Results, true); refresh = true;
                ShowResults(result.Results, "Original icons restored");
            }
            catch (Exception error) { Report(error); }
            finally { SetBusy(false, null); }
            if (refresh) await RefreshAfterChange();
        }
        void ShowResults(ResultItem[] results, string success)
        {
            int failed = results.Count(r => r.Status != "Applied" && r.Status != "Unchanged" && r.Status != "Restored");
            status.Text = failed == 0 ? success + ". " + results.Length + " shortcut(s)." : "Finished with " + failed + " skipped or failed shortcut(s).";
            Review("Operation results", status.Text + "\r\nRunning app icons and existing taskbar pins can keep their own artwork.", results.Select(r => new[] { r.Status, r.Shortcut, r.Message }), true, "Done");
        }
        void Report(Exception error)
        {
            System.ComponentModel.Win32Exception native = error as System.ComponentModel.Win32Exception;
            string message = native != null && native.NativeErrorCode == 1223 ? "Administrator request cancelled. No icons changed." : error.Message;
            status.Text = message; if (!Visible) ShowManager(); pages.SelectedTab = settingsPage; MessageBox.Show(this, message, "BetterIcon", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
    }

    public sealed class LauncherContext : ApplicationContext
    {
        public LauncherContext(LauncherForm popup)
        {
            // Do not set MainForm: Application.Run would force it visible and
            // consume the first toggle after a --tray/hidden process launch.
            popup.FormClosed += delegate { ExitThread(); };
            popup.Start();
        }
    }

    static class Program
    {
        [STAThread]
        static int Main(string[] args)
        {
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
            try {
                string source = AppDomain.CurrentDomain.BaseDirectory, configPath = null;
                bool hidden = false, stop = false;
                for (int i=0; i<args.Length; i++) {
                    if (args[i] == "--tray") hidden = true;
                    else if (args[i] == "--stop") stop = true;
                    else if (args[i] == "--source-folder" && i+1<args.Length) source = Path.GetFullPath(args[++i]);
                    else if (args[i] == "--config" && i+1<args.Length) configPath = Path.GetFullPath(args[++i]);
                    else throw new ArgumentException("Unknown launcher option.");
                }
                FixtureConfig fixture = null;
                if (configPath != null) {
                    fixture = new JavaScriptSerializer().Deserialize<FixtureConfig>(File.ReadAllText(configPath));
                    if (fixture == null || fixture.ShortcutDirectory == null || fixture.ShortcutDirectory.Length == 0 || String.IsNullOrWhiteSpace(fixture.StateDirectory)) throw new ArgumentException("Fixture configuration requires both shortcut and state directories.");
                    if (!Path.IsPathRooted(fixture.StateDirectory) || fixture.ShortcutDirectory.Any(p => !Path.IsPathRooted(p) || !Directory.Exists(p))) throw new ArgumentException("Fixture paths must be absolute; shortcut directories must exist.");
                }
                string identity = WindowsIdentity.GetCurrent().User.Value + "|" + (configPath ?? "main");
                string hash; using (SHA256 sha = SHA256.Create()) hash = BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(identity))).Replace("-", "");
                string name = "Local\\BetterIcon.Tray." + hash;
                if (stop) { try { using (EventWaitHandle signal = EventWaitHandle.OpenExisting(name + ".Stop")) signal.Set(); } catch (WaitHandleCannotBeOpenedException) { } return 0; }
                bool first;
                using (Mutex singleton = new Mutex(true, name, out first)) {
                    if (!first) {
                        try { using (EventWaitHandle signal = EventWaitHandle.OpenExisting(name + ".Show")) signal.Set(); } catch (WaitHandleCannotBeOpenedException) { }
                        return 0;
                    }
                    try {
                        if (!File.Exists(Path.Combine(source, "BetterIcon.TrayWorker.ps1"))) throw new FileNotFoundException("Keep the tray application beside its Windows helper files, or launch it using Start-Tray.cmd.");
                        using (EventWaitHandle show = new EventWaitHandle(false, EventResetMode.AutoReset, name + ".Show"))
                        using (EventWaitHandle quit = new EventWaitHandle(false, EventResetMode.AutoReset, name + ".Stop"))
                        using (LauncherForm form = new LauncherForm(source, fixture, hidden, show, quit))
                        using (LauncherContext context = new LauncherContext(form)) Application.Run(context);
                    }
                    finally { singleton.ReleaseMutex(); }
                }
                return 0;
            }
            catch (Exception error) { MessageBox.Show(error.Message, "BetterIcon could not start", MessageBoxButtons.OK, MessageBoxIcon.Error); return 1; }
        }
    }
}
