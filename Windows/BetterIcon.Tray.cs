// Native Windows tray UI. Build locally with the .NET Framework compiler.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
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
        public string Target { get; set; }
        public string AppliedIconPath { get; set; }
        public string AppliedIconScope { get; set; }
        public string Scope { get; set; }
        public string IconPath { get; set; }
        public int IconIndex { get; set; }
        public string OriginalIconPath { get; set; }
        public int OriginalIconIndex { get; set; }
        public bool RestoreAvailable { get; set; }
        public bool UsingDefaultIcon { get; set; }
        // How the shortcut changed since BetterIcon themed it: empty, Updated, Reverted, Edited, Custom, Replaced, Stale,
        // InFlux, or Damaged (empty or unreadable while Windows Installer is idle).
        public string Change { get; set; }
        public bool CanRestoreDefault { get { return RestoreAvailable || UsingDefaultIcon; } }
    }
    public sealed class ThemeIcon { public string Application { get; set; } public string Path { get; set; } public string PreviewPath { get; set; } }
    // An item of a pack on this computer that is not shown or applied, because its only artwork is WebP that cannot be
    // used here. Item is a display name (PhotoCraft, .pcraft, PhotoCraft files); Kind is App or File.
    public sealed class LeftOutItem
    {
        public string Item { get; set; }
        public string Reason { get; set; }
        public string Kind { get; set; }
        public bool IsFile { get { return Kind == "File"; } }
    }
    static class AppOrder
    {
        // The app whose icon leads every grid of app icons.
        public const string Lead = "ArtCraftLauncher";
        public static bool Leads(string application) { return String.Equals(application, Lead, StringComparison.OrdinalIgnoreCase); }
    }

    public sealed class ThemeEntry
    {
        public const string DefaultThemeId = "ArtCraft/Default";
        // The pack a build that carried every pack opened with. A saved choice of it may never have been made by the user.
        public const string OpeningThemeId = "Craft-Icons-Zach/Cardboard";
        public bool IsDefault { get; set; }
        public string Id { get; set; }
        public string Name { get; set; }
        public string Pack { get; set; }
        public string Author { get; set; }
        public int IconCount { get; set; }
        public bool Managed { get; set; }
        public bool NeedsDownload { get; set; }
        public bool Downloaded { get; set; }
        public bool UpdateAvailable { get; set; }
        public bool HasDownload { get { return NeedsDownload || UpdateAvailable; } }
        public string LibraryId { get; set; }
        public ThemeIcon[] Icons { get; set; }
        // FileIcons draws one file format. AppFileIcons draws every file type an app opens.
        public Dictionary<string, string> FileIcons { get; set; }
        public Dictionary<string, string> AppFileIcons { get; set; }
        // File types outside the index take only art an author named <App>-files. A published pack lists the apps whose
        // AppFileIcons art is so named, as its catalog's source names say. A personal pack keeps such art as items of its own,
        // one per app, beside the copies it stores for each listed format.
        public string[] UnlistedFileIconApps { get; set; }
        public Dictionary<string, string> UnlistedFileIcons { get; set; }
        public int FileIconCount { get; set; }
        public bool HasFileIcons { get { return FileIconCount > 0 || (FileIcons != null && FileIcons.Count > 0) || (AppFileIcons != null && AppFileIcons.Count > 0); } }
        // A pack downloaded before it gained file artwork is still a file type pack: choosing it downloads the update.
        public int PublishedFileIconCount { get; set; }
        // Items left out because their only artwork is WebP that cannot be used here.
        public LeftOutItem[] LeftOut { get; set; }
        // A pack stays in its list while every item is left out, so its reason and the WebP offer can be seen.
        public bool OffersFileIcons { get { return HasFileIcons || (UpdateAvailable && PublishedFileIconCount > 0) || (LeftOut != null && LeftOut.Any(item => item.IsFile)); } }
        public bool OffersAppIcons { get { return IconCount > 0 || (LeftOut != null && LeftOut.Any(item => !item.IsFile)); } }
        // Lists show each author's packs together, by name.
        public string ListAuthor { get { return Author ?? (Managed ? "" : (Pack ?? "").Replace("Craft-Icons-", "")); } }
        public string DisplayName
        {
            get {
                if (IsDefault) return "ArtCraft default";
                string author = ListAuthor;
                string title = Name == "Root" && !Managed ? author : Name + (String.IsNullOrWhiteSpace(author) ? "" : " / " + author);
                return title + (Managed ? " (personal)" : "");
            }
        }
        public override string ToString()
        {
            return IsDefault || Managed ? DisplayName : DisplayName + " (" + (UpdateAvailable ? "Update available" : NeedsDownload ? "Download" : Downloaded ? "Downloaded" : "Included") + ")";
        }
    }
    public sealed class Catalog
    {
        public string Version { get; set; }
        AppEntry[] apps;
        // ArtCraft Launcher leads the grid. The other apps keep the order they arrive in, by name.
        public AppEntry[] Apps
        {
            get { return apps; }
            set { apps = value == null ? null : value.OrderBy(app => !AppOrder.Leads(app.Application)).ToArray(); }
        }
        public ThemeEntry[] Themes { get; set; }
        public Dictionary<string, string> PackAliases { get; set; }

        public string CurrentPackId(string id)
        {
            string replacement;
            return id != null && PackAliases != null && PackAliases.TryGetValue(id, out replacement) &&
                Themes.Any(t => t.Id == replacement) ? replacement : id;
        }
    }
    public sealed class PlanItem
    {
        public string Application { get; set; }
        public string Shortcut { get; set; }
        public string Icon { get; set; }
        public string Theme { get; set; }
        public string Status { get; set; }
        public string Reason { get; set; }
        public string OriginalHash { get; set; }
        public string Change { get; set; }
    }
    public sealed class ResultItem
    {
        public string Shortcut { get; set; }
        public string Status { get; set; }
        public string Message { get; set; }
        // Filled in by re-apply passes after app updates.
        public string Application { get; set; }
        public string Scope { get; set; }
        public string Change { get; set; }
        public string Hash { get; set; }
        public string Detail { get; set; }
    }
    // A shortcut a re-apply pass leaves alone. An empty hash means whatever its contents.
    public sealed class SkipItem { public string Path { get; set; } public string Hash { get; set; } }
    public sealed class PackUpdateCheck
    {
        public string Revision { get; set; }
        public string Baseline { get; set; }
        public int Count { get; set; }
    }
    public sealed class WorkerRequest
    {
        public Dictionary<string, string> ProjectArtwork { get; set; }
        public Dictionary<string, string> AppArtwork { get; set; }
        // A personal pack's own art for file types outside the index, by app.
        public Dictionary<string, string> UnlistedArtwork { get; set; }
        public string Action { get; set; }
        public string Application { get; set; }
        public string Theme { get; set; }
        public string Scope { get; set; }
        public string[] ShortcutDirectory { get; set; }
        public string StateDirectory { get; set; }
        public PlanItem[] ExpectedPlan { get; set; }
        public string ExpectedStateHash { get; set; }
        public string PackDirectory { get; set; }
        public PackUpdateCheck PreviousPackCheck { get; set; }
        // Re-apply passes: shortcuts and apps to leave alone, and whether shortcuts installed later get the applied pack.
        public SkipItem[] Skip { get; set; }
        public string[] SkipApps { get; set; }
        public bool ThemeNew { get; set; }
        // Fixture mode only: files that stand for a running installer and for the installer's log.
        public string InstallerBusyFile { get; set; }
        public string InstallerLogFile { get; set; }
    }
    // What Setup's optional downloads page offers from the pack lists: packs not on this computer yet, and their sizes.
    public sealed class SetupStatus
    {
        public string[] AppPacks { get; set; }
        public string[] FilePacks { get; set; }
        public long AppBytes { get; set; }
        public long FileBytes { get; set; }
        public int AppUnknown { get; set; }
        public int FileUnknown { get; set; }
    }
    public sealed class WorkerReply
    {
        public Dictionary<string, string> CachedProjectIcons { get; set; }
        public Dictionary<string, string> CachedAppIcons { get; set; }
        public Dictionary<string, string> CachedUnlistedIcons { get; set; }
        // After a download: the apps whose art the downloaded pack opts in for file types outside the index.
        public string[] DownloadedUnlistedFileIconApps { get; set; }
        // File artwork PrepareProjectIcons could not convert: only these items are left out, each with its reason.
        public LeftOutItem[] ProjectIconFailures { get; set; }
        public ThemeIcon[] DownloadedIcons { get; set; }
        public Dictionary<string,string> DownloadedFileIcons { get; set; }
        public Dictionary<string,string> DownloadedAppFileIcons { get; set; }
        public LeftOutItem[] DownloadedLeftOut { get; set; }
        public SetupStatus SetupStatus { get; set; }
        public bool Success { get; set; }
        public string Error { get; set; }
        public Catalog Catalog { get; set; }
        public PlanItem[] Plan { get; set; }
        public ResultItem[] Results { get; set; }
        public string StateHash { get; set; }
        public PackUpdateCheck PackCheck { get; set; }
        public AppEntry[] Apps { get; set; }
    }
    // Optional developer fixture configuration. Both fields are required so a
    // disposable test cannot accidentally fall back to the user's real folders.
    public sealed class FixtureConfig
    {
        public string[] ShortcutDirectory { get; set; }
        public string StateDirectory { get; set; }
        public bool KeepOpenForAutomation { get; set; }
        public bool AutomaticPackChecks { get; set; }
        // Background checks after app updates run in fixture mode only when this is set.
        public bool AutomaticReconcile { get; set; }
        public string InstallerBusyFile { get; set; }
        public string InstallerLogFile { get; set; }
        // Fixture mode never starts an elevated helper: "Cancel" (the default) or "Allow" stands in for Windows' answer.
        public string ElevationProbe { get; set; }
        public bool? SilentElevation { get; set; }
        public bool? InstalledCopy { get; set; }
        // HKCU subkeys that stand in for the Run and StartupApproved\Run keys. Without them Open at login is off.
        public string LoginRunKey { get; set; }
        public string LoginApprovedKey { get; set; }
        // Set by the program from --config, so the login entry starts the same fixture.
        public string ConfigPath { get; set; }
    }
    public sealed class Preferences
    {
        public const int DefaultIconSize = 48, MinimumIconSize = 24, MaximumIconSize = 4096;
        int iconSize = DefaultIconSize;
        public string Theme { get; set; }
        // The Launcher keeps the pack that was last applied. Choosing a pack only previews it.
        public string AppliedTheme { get; set; }
        public Dictionary<string, string> AppliedArtwork { get; set; }
        public string Scope { get; set; }
        public HotkeySettings Hotkey { get; set; }
        public string FileTheme { get; set; }
        public string[] DefaultShortcuts { get; set; }
        public bool ShowAppNames { get; set; }
        public Size LauncherWindowSize { get; set; }
        public Size ManageWindowSize { get; set; }
        // Null until Setup's copy first starts; then the user's choice, which BetterIcon never overrides.
        public bool? OpenAtLogin { get; set; }
        // Null means on where Windows elevates without asking.
        public bool? AutoReapplyShared { get; set; }
        string appearanceMode = "System", appIconStyle = "sage", appIconVariant = "Auto";
        public string AppearanceMode { get { return appearanceMode; } set { appearanceMode = value == "Dark" || value == "Light" ? value : "System"; } }
        public string AppIconStyle { get { return appIconStyle; } set { appIconStyle = AppBranding.Styles.Contains(value) ? value : "sage"; } }
        public string AppIconVariant { get { return appIconVariant; } set { appIconVariant = value == "Dark" || value == "Light" ? value : "Auto"; } }
        public int IconSize { get { return iconSize; } set { iconSize = Math.Max(MinimumIconSize, Math.Min(MaximumIconSize, value)); } }
        public Preferences() { Hotkey = new HotkeySettings(); DefaultShortcuts = new string[0]; ShowAppNames = true; }
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
            if (fixture != null) {
                request.ShortcutDirectory = fixture.ShortcutDirectory; request.StateDirectory = fixture.StateDirectory;
                request.InstallerBusyFile = fixture.InstallerBusyFile; request.InstallerLogFile = fixture.InstallerLogFile;
            }
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
            return Place(size, size, anchor, work, false);
        }
        public static Rectangle CenteredOnCursor(Size size, Point cursor, Rectangle work)
        {
            return Place(size, size, cursor, work, true);
        }
        static Rectangle UsableArea(Rectangle work)
        {
            if (work.Width < 1 || work.Height < 1) throw new ArgumentException("Invalid screen working area.");
            int gap = Math.Min(8, (Math.Min(work.Width, work.Height) - 1) / 2);
            return Rectangle.Inflate(work, -gap, -gap);
        }
        internal static Rectangle Place(Size page, Size otherPage, Point anchor, Rectangle work, bool centered)
        {
            Rectangle area = UsableArea(work);
            int height = Math.Max(1, Math.Min(page.Height, area.Height));
            int top = centered ? anchor.Y - height / 2 : anchor.Y - (area.Top - work.Top) - height;
            return FitTabs(page, otherPage, new Point(anchor.X, top), area);
        }
        public static Rectangle AtTabDivider(Size page, Size otherPage, Point topCenter, Rectangle work)
        {
            return FitTabs(page, otherPage, topCenter, UsableArea(work));
        }
        static Rectangle FitTabs(Size page, Size otherPage, Point topCenter, Rectangle area)
        {
            int width = Math.Max(1, Math.Min(page.Width, area.Width));
            int height = Math.Max(1, Math.Min(page.Height, area.Height));
            int widest = Math.Max(width, Math.Min(otherPage.Width, area.Width));
            int tallest = Math.Max(height, Math.Min(otherPage.Height, area.Height));
            // Equal-width tab headers keep their join at a fixed offset from the top center.
            // Leave room for both pages now, so neither edge forces the join to move on a switch.
            int center = Math.Max(area.Left + widest / 2, Math.Min(topCenter.X, area.Right - (widest - widest / 2)));
            int top = Math.Max(area.Top, Math.Min(topCenter.Y, area.Bottom - tallest));
            return new Rectangle(center - width / 2, top, width, height);
        }
    }

    // Keep native list selection, accessibility and keyboard navigation, with labels below the artwork.
    public class IconGridView : ListView
    {
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
        [DllImport("comctl32.dll")] static extern bool ImageList_Destroy(IntPtr list);
        IntPtr largeArtwork;
        int iconSize = Preferences.DefaultIconSize;
        protected int IconSize { get { return iconSize; } }
        bool showAppNames = true, inputBlocked, savedTabStop;
        public event Action<int> IconSizeWheel;
        public event Action<Point?> IconMenuRequested;
        public bool ShowAppNames { get { return showAppNames; } set { if (showAppNames == value) return; showAppNames = value; UpdateSpacing(); Invalidate(); } }
        public bool InputBlocked
        {
            get { return inputBlocked; }
            set {
                if (inputBlocked == value) return;
                inputBlocked = value;
                if (value) {
                    savedTabStop = TabStop; TabStop = false;
                    // Cancel an in-progress mouse/scroll interaction without
                    // entering the native disabled state, which loses our colors.
                    if (IsHandleCreated) SendMessage(Handle, 0x001F, IntPtr.Zero, IntPtr.Zero);
                }
                else TabStop = savedTabStop;
            }
        }
        public Size GridCellSize { get { return new Size(showAppNames ? Math.Max(112, iconSize + 24) : iconSize + 24, iconSize + (showAppNames ? Font.Height * 2 : 0) + 16); } }
        public IconGridView() { View = View.LargeIcon; AutoArrange = true; Alignment = ListViewAlignment.Top; LabelWrap = true; DoubleBuffered = true; }
        public void SetIconSize(int size) { iconSize = size; UpdateSpacing(); }
        protected override CreateParams CreateParams { get { CreateParams value = base.CreateParams; value.Style |= 0x0040; return value; } }
        protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); if (largeArtwork != IntPtr.Zero) SendMessage(Handle, 0x1003, IntPtr.Zero, largeArtwork); UpdateSpacing(); }
        protected override void OnFontChanged(EventArgs e) { base.OnFontChanged(e); UpdateSpacing(); }
        protected override void Dispose(bool disposing)
        {
            if (disposing && largeArtwork != IntPtr.Zero) {
                if (IsHandleCreated) SendMessage(Handle, 0x1003, IntPtr.Zero, IntPtr.Zero);
                ImageList_Destroy(largeArtwork); largeArtwork = IntPtr.Zero;
            }
            base.Dispose(disposing);
        }
        public void SetArtwork(IList<Bitmap> artwork, int size)
        {
            // Upload straight BGRA directly at every size. Managed ImageList and
            // GetHicon conversion alter translucent edge colors in different ways.
            IntPtr replacement = IntPtr.Zero;
            try {
                replacement = NativeArtwork.Create(artwork, size);
                IntPtr previous = largeArtwork; largeArtwork = replacement; replacement = IntPtr.Zero;
                if (IsHandleCreated) SendMessage(Handle, 0x1003, IntPtr.Zero, largeArtwork);
                if (previous != IntPtr.Zero) ImageList_Destroy(previous);
                SetIconSize(size);
            }
            finally { if (replacement != IntPtr.Zero) ImageList_Destroy(replacement); }
        }
        protected override void WndProc(ref Message message)
        {
            if (inputBlocked && (message.Msg == 0x007B || message.Msg == 0x0114 || message.Msg == 0x0115 ||
                (message.Msg >= 0x0100 && message.Msg <= 0x0109) ||
                (message.Msg >= 0x0200 && message.Msg <= 0x020E) ||
                (message.Msg >= 0x00A0 && message.Msg <= 0x00AD))) {
                message.Result = IntPtr.Zero; return;
            }
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
            // Preserve native item text for filtering, tooltips and accessibility.
            // LVS_EX_HIDELABELS hides only its visual label in icon view.
            SendMessage(Handle, 0x1036, new IntPtr(0x00020000), new IntPtr(showAppNames ? 0 : 0x00020000));
            Size cell = GridCellSize;
            // LVM_SETICONSPACING includes the image itself plus room for two lines of text.
            SendMessage(Handle, 0x1035, IntPtr.Zero, new IntPtr((cell.Height << 16) | cell.Width));
            ArrangeIcons(ListViewAlignment.Top);
        }
    }

    sealed class LauncherGridView : IconGridView
    {
        readonly IList<Bitmap> artwork;
        readonly ImageAttributes lighter = new ImageAttributes(), darker = new ImageAttributes();
        ListViewItem hovered, pressed;

        public LauncherGridView(IList<Bitmap> artwork)
        {
            this.artwork = artwork;
            Activation = ItemActivation.OneClick;
            OwnerDraw = true;
            // Blend each color toward white, keeping the original alpha (including SVG cutouts).
            const float lift = 0.30F;
            lighter.SetColorMatrix(new ColorMatrix {
                Matrix00 = 1 - lift, Matrix11 = 1 - lift, Matrix22 = 1 - lift,
                Matrix40 = lift, Matrix41 = lift, Matrix42 = lift
            });
            // A pressed icon keeps its alpha and loses some brightness.
            const float dim = 0.82F;
            darker.SetColorMatrix(new ColorMatrix { Matrix00 = dim, Matrix11 = dim, Matrix22 = dim });
        }
        protected override void Dispose(bool disposing)
        {
            if (disposing) { lighter.Dispose(); darker.Dispose(); }
            base.Dispose(disposing);
        }
        // While the left button is down on an app, its artwork is a little smaller and darker.
        void SetPressed(ListViewItem item)
        {
            if (pressed == item) return;
            ListViewItem old = pressed;
            pressed = item;
            if (old != null && old.ListView == this) Invalidate(old.Bounds);
            if (item != null) Invalidate(item.Bounds);
            // The native list waits in its own loop until the button comes up. Paint the change now.
            if (IsHandleCreated) Update();
        }
        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left && !InputBlocked) SetPressed(GetItemAt(e.X, e.Y));
            base.OnMouseDown(e);
        }
        protected override void OnMouseUp(MouseEventArgs e) { SetPressed(null); base.OnMouseUp(e); }
        protected override void WndProc(ref Message message)
        {
            // The native list handles a left press in its own loop. It returns once the button
            // is up or the press became a drag, so the press is over either way.
            if (message.Msg == 0x0201 || message.Msg == 0x0203) {
                try { base.WndProc(ref message); }
                finally { SetPressed(null); }
                return;
            }
            base.WndProc(ref message);
        }
        void SetHovered(ListViewItem item)
        {
            if (hovered == item) return;
            ListViewItem old = hovered;
            hovered = item;
            if (old != null && old.ListView == this) Invalidate(old.Bounds);
            if (item != null) Invalidate(item.Bounds);
            if (SelectedItems.Count == 1) Invalidate(SelectedItems[0].Bounds);
        }
        public void ClearHover() { SetHovered(null); }
        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            SetHovered(GetItemAt(e.X, e.Y));
        }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); ClearHover(); }
        protected override void OnKeyDown(KeyEventArgs e) { ClearHover(); base.OnKeyDown(e); }
        protected override void OnDrawItem(DrawListViewItemEventArgs e)
        {
            bool down = !InputBlocked && pressed == e.Item;
            bool active = !down && !InputBlocked && (hovered == null ? e.Item.Selected : hovered == e.Item);
            Rectangle icon = GetItemRect(e.ItemIndex, ItemBoundsPortion.Icon);
            int index = e.Item.ImageIndex;
            if (index >= 0 && index < artwork.Count) {
                Bitmap image = artwork[index];
                // Shrink by the same whole number of pixels on every side so the artwork stays centered.
                int inset = down ? Math.Max(1, (int)Math.Round(IconSize * 0.04)) : 0, size = IconSize - inset * 2;
                Rectangle destination = new Rectangle(icon.Left + (icon.Width - IconSize) / 2 + inset,
                    icon.Top + (icon.Height - IconSize) / 2 + inset, size, size);
                e.Graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                e.Graphics.DrawImage(image, destination, 0, 0, image.Width, image.Height, GraphicsUnit.Pixel, down ? darker : active ? lighter : null);
            }
            if (ShowAppNames) {
                Rectangle label = GetItemRect(e.ItemIndex, ItemBoundsPortion.Label);
                TextRenderer.DrawText(e.Graphics, e.Item.Text, Font, label, ForeColor,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.WordBreak | TextFormatFlags.EndEllipsis |
                    TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding | TextFormatFlags.PreserveGraphicsClipping);
            }
        }
    }

    public sealed partial class LauncherForm : Form
    {
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window, int command);
        [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr window);
        readonly WorkerClient worker;
        readonly NotifyIcon tray;
        readonly ContextMenuStrip trayMenu = new ContextMenuStrip();
        readonly ContextMenuStrip iconMenu = new ContextMenuStrip();
        readonly ToolStripMenuItem chooseAppIcon = new ToolStripMenuItem("Choose icon...");
        readonly ToolStripMenuItem restoreIconDefault = new ToolStripMenuItem("Restore ArtCraft default...");
        AppEntry iconMenuTarget;
        readonly PackPicker themes = new PackPicker(), fileThemes = new PackPicker();
        readonly PackPreviewStore previewStore;
        readonly PackHoverPreview trayHover;
        readonly LauncherGridView apps;
        readonly List<ListViewItem> appTiles = new List<ListViewItem>();
        readonly List<Bitmap> appArtwork = new List<Bitmap>();
        sealed class ArtworkSource { public string Path; public int Index, MaximumSize; }
        readonly List<ArtworkSource> appSources = new List<ArtworkSource>();
        bool renderingArtwork;
        readonly Label filterHint = new Label();
        readonly LinkLabel launcherShortcut = new LinkLabel();
        readonly Label status = new Label();
        readonly Label subtitle = new Label();
        readonly Button apply = new Button(), restore = new Button();
        readonly EventWaitHandle showEvent, stopEvent, installStopEvent;
        readonly System.Windows.Forms.Timer signalTimer = new System.Windows.Forms.Timer();
        readonly System.Windows.Forms.Timer dismissTimer = new System.Windows.Forms.Timer();
        readonly System.Windows.Forms.Timer packCheckTimer = new System.Windows.Forms.Timer { Interval = 60000 };
        readonly string preferencesPath;
        readonly string fixtureLog;
        RunningTaskbarIcons runningTaskbarIcons;
        readonly bool startInTray;
        readonly bool automaticPackChecks;
        Catalog catalog;
        Preferences preferences = new Preferences();
        GlobalHotkey hotkey;
        bool busy, exiting, notified;
        bool checkingPackUpdates;
        int packCheckGeneration;
        DateTime nextPackCheck;
        PackUpdateCheck packUpdateCheck;
        static readonly Size DefaultWindowSize = new Size(900, 818);
        static readonly Size LauncherMinimum = new Size(300, 240), ManageMinimum = new Size(790, 570);
        Size displayedPageSize;
        bool openingPopup;
        Point? trayAnchor;
        string filterText = "";
        readonly Color ink = Color.FromArgb(26, 39, 58), accent = Color.FromArgb(41, 100, 208);

        public LauncherForm(string source, FixtureConfig fixture, bool hidden, EventWaitHandle show, EventWaitHandle stop)
            : this(source, fixture, hidden, show, stop, null) { }

        public LauncherForm(string source, FixtureConfig fixture, bool hidden, EventWaitHandle show, EventWaitHandle stop, EventWaitHandle installStop)
        {
            apps = new LauncherGridView(appArtwork);
            worker = new WorkerClient(source, fixture); startInTray = hidden; showEvent = show; stopEvent = stop; installStopEvent = installStop;
            fixtureSettings = fixture; sourceDirectory = source;
            automaticPackChecks = fixture == null || fixture.AutomaticPackChecks;
            string state = fixture == null ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BetterIcon-Craft Apps") : fixture.StateDirectory;
            // WebP support, where Windows has no WebP decoder, is installed under the state folder, which updates keep.
            LibWebP.Configure(Path.Combine(source, "LibWebP.ini"), state);
            stateDirectory = state;
            preferencesPath = Path.Combine(state, "tray-preferences.json");
            previewStore = new PackPreviewStore(source, state);
            themes.EnablePreviews(previewStore); fileThemes.EnablePreviews(previewStore, true);
            trayHover = new PackHoverPreview(previewStore, this);
            trayMenu.Closed += delegate { trayHover.Clear(); };
            library = new PackLibrary(Path.Combine(state, "packs"));
            if (fixture != null) fixtureLog = Path.Combine(state, "tray-events.jsonl");
            try { if (File.Exists(preferencesPath)) preferences = new JavaScriptSerializer().Deserialize<Preferences>(File.ReadAllText(preferencesPath)) ?? preferences; } catch (Exception) { }
            if (preferences.Hotkey == null) preferences.Hotkey = new HotkeySettings();
            // Earlier versions showed the chosen pack in the Launcher. Keep that look after an upgrade.
            // With no chosen pack nothing was applied. The empty name records that, so a pack that is
            // only chosen later does not become the Launcher's pack at the next start.
            if (preferences.AppliedTheme == null) preferences.AppliedTheme = preferences.Theme ?? "";
            Text = "BetterIcon for ArtCraft"; Name = "BetterIconLauncher";
            Font = new Font("Segoe UI", 10F); ForeColor = ink; BackColor = Color.FromArgb(244, 247, 251);
            AutoScaleMode = AutoScaleMode.Font; FormBorderStyle = FormBorderStyle.None;
            ClientSize = DefaultWindowSize; MinimumSize = LauncherMinimum;
            // Keep a small exposed client margin so child controls cannot consume
            // the native edge hit tests. Font autoscaling scales this margin too.
            Padding = new Padding(8);
            StartPosition = FormStartPosition.Manual; ControlBox = false; MaximizeBox = false; MinimizeBox = false;
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
                if (Control.MouseButtons != MouseButtons.None || trayMenu.Visible || iconMenu.Visible || importPackMenu.Visible || managePackMenu.Visible || manageFilePackMenu.Visible || busy || !Enabled || PackListOpen || AppearanceMenuOpen) return;
                dismissTimer.Stop(); Hide();
            };
            // Any balloon of BetterIcon's opens Manage Icons, where its message is on the status line.
            tray.BalloonTipClicked += delegate { ShowSettings(); };
            Deactivate += delegate { TraceFixture("Deactivated"); if (Visible) dismissTimer.Start(); };
            Activated += delegate { dismissTimer.Stop(); TraceFixture("Activated"); };
            VisibleChanged += delegate { if (!Visible) dismissTimer.Stop(); TraceFixture(Visible ? "Shown" : "Hidden"); };
            signalTimer.Interval = 250;
            signalTimer.Tick += delegate {
                if (showEvent.WaitOne(0)) {
                    TraceFixture("Show signal"); ShowManager();
                    // A later Setup may have handed over new downloads.
                    if (!setupDownloading) setupDownloadsTask = StartSetupDownloads();
                }
                if (stopEvent.WaitOne(0)) ExitLauncher();
                if (installStopEvent != null && installStopEvent.WaitOne(0)) RequestExternalStop();
            };
            signalTimer.Start();
            FormClosing += delegate(object sender, FormClosingEventArgs e) {
                if (!exiting && e.CloseReason == CloseReason.UserClosing) {
                    e.Cancel = true; Hide();
                    if (!notified) { tray.ShowBalloonTip(2500, "BetterIcon is in the tray", "Click its tray icon to return. Choose Exit to stop the launcher.", ToolTipIcon.Info); notified = true; }
                }
            };
            FormClosed += delegate { if (hotkey != null) hotkey.Dispose(); signalTimer.Stop(); signalTimer.Dispose(); dismissTimer.Stop(); dismissTimer.Dispose(); tray.Visible = false; tray.Dispose(); trayMenu.Dispose(); iconMenu.Dispose(); importPackMenu.Dispose(); managePackMenu.Dispose(); manageFilePackMenu.Dispose(); };
            BuildTrayMenu(); InitializeAppearance(); InitializeRoundedWindow();
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
            InitializeLoginItem();
            BeginInvoke(new Action(async delegate {
                if (!startInTray) ShowManager();
                await RefreshCatalog();
                await RestoreChosenPacks();
                // What was chosen on Setup's optional downloads page downloads now, in the background.
                setupDownloadsTask = StartSetupDownloads();
                // Checks for app updates run whether or not pack checks do.
                StartUpdateWatch();
                if (!automaticPackChecks || IsDisposed || Disposing) return;
                packCheckTimer.Tick += async delegate {
                    if (DateTime.UtcNow >= nextPackCheck) await CheckForPackUpdates();
                };
                packCheckTimer.Start();
                await CheckForPackUpdates();
            }));
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing && trayHover != null) trayHover.Dispose();
            if (disposing && runningTaskbarIcons != null) runningTaskbarIcons.Dispose();
            if (disposing) { packCheckTimer.Dispose(); StopUpdateWatch(); DisposeRoundedWindow(); if (hotkey != null) hotkey.Dispose(); DisposeAppearance(); ClearAppArtwork(); ClearPackArtwork(); ClearFileArtwork(); }
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
        void ConfigureFooterLink(LinkLabel link, string description)
        {
            link.AutoSize = true; link.TabStop = true; link.UseMnemonic = false;
            link.LinkBehavior = LinkBehavior.HoverUnderline; link.Tag = "SecondaryText";
            link.AccessibleDescription = description; appearanceTips.SetToolTip(link, description);
        }
        void BuildWindow(bool testing)
        {
            pages.Dock = DockStyle.Fill; pages.SizeMode = TabSizeMode.Fixed; pages.ItemSize = new Size(420, 38);
            pages.DrawMode = TabDrawMode.OwnerDrawFixed; pages.DrawItem += DrawPageTab;
            // Updating ItemSize from TabControl.SizeChanged re-enters native layout.
            // Resize only once layout settles, after showing or a user resize.
            ResizeEnd += delegate { FinishWindowResize(); TraceFixture("Resized"); };
            launcherPage.BackColor = Color.White; launcherPage.Padding = new Padding(18);
            settingsPage.BackColor = BackColor;
            pages.TabPages.AddRange(new[] { launcherPage, settingsPage }); Controls.Add(pages);
            apps.Dock = DockStyle.Fill; apps.ShowAppNames = preferences.ShowAppNames; apps.SetIconSize(preferences.IconSize);
            apps.MultiSelect = false; apps.HideSelection = false;
            apps.BorderStyle = BorderStyle.None; apps.BackColor = Color.White; apps.ShowItemToolTips = true; apps.AccessibleName = "Installed ArtCraft apps";
            apps.ItemActivate += delegate { LaunchSelected(); };
            apps.IconSizeWheel += ChangeIconSizeFromWheel;
            filterHint.Dock = DockStyle.Top; filterHint.Height = 42; filterHint.Text = "Finding installed apps...";
            filterHint.TextAlign = ContentAlignment.MiddleLeft;
            ConfigureFooterLink(launcherShortcut, "Change the keyboard shortcut that opens the launcher.");
            launcherShortcut.Margin = Padding.Empty;
            launcherShortcut.LinkClicked += delegate { ChangeHotkey(); };
            FlowLayoutPanel launcherFooter = new FlowLayoutPanel {
                Dock = DockStyle.Bottom, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                WrapContents = false, Padding = new Padding(0, 6, 0, 0)
            };
            launcherFooter.ClientSizeChanged += delegate {
                launcherShortcut.MaximumSize = new Size(Math.Max(1, launcherFooter.ClientSize.Width), 0);
            };
            launcherFooter.Controls.Add(launcherShortcut);
            launcherPage.Controls.Add(apps); launcherPage.Controls.Add(filterHint); launcherPage.Controls.Add(launcherFooter);
            BuildSettingsPage(testing);
            BuildLoadingIndicator();
            iconMenu.ShowItemToolTips = true; iconMenu.Items.Add(chooseAppIcon); iconMenu.Items.Add(restoreIconDefault);
            chooseAppIcon.Click += async delegate { AppEntry target = iconMenuTarget; if (!busy && target != null) await ChooseAppIcon(target); };
            restoreIconDefault.Click += async delegate {
                AppEntry target = iconMenuTarget;
                if (!busy && target != null) await RestoreIcons(target.Application);
            };
            apps.IconMenuRequested += point => ShowIconMenu(apps, point);
            packPreview.IconMenuRequested += point => ShowIconMenu(packPreview, point);
            pages.SelectedIndexChanged += delegate {
                if (Visible && !openingPopup && WindowState == FormWindowState.Normal) RestorePageAtDivider();
                pages.Invalidate();
                if (pages.SelectedTab == launcherPage) apps.Focus();
            };
        }
        // Retain old preference values for compatibility; every write operation
        // gets a fresh scope from its dialog instead of this legacy setting.
        string Scope { get { return preferences.Scope == "AllUsers" ? "AllUsers" : "CurrentUser"; } }
        ThemeEntry SelectedTheme { get { return themes.SelectedItem as ThemeEntry; } }
        // Null is the first row, the original file icons.
        ThemeEntry SelectedFileTheme { get { return fileThemes.SelectedItem as ThemeEntry; } }
        bool PackListOpen { get { return themes.DroppedDown || fileThemes.DroppedDown; } }
        static bool IsAdministrator() { return new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator); }
        void SetBusy(bool value, string message)
        {
            busy = value; apply.Enabled = restore.Enabled = themes.Enabled = fileThemes.Enabled = !value;
            if (value) { iconMenu.Close(); iconMenuTarget = null; chooseAppIcon.Enabled = restoreIconDefault.Enabled = false; }
            iconSizeSlider.Enabled = iconSizeValue.Enabled = resetIconSize.Enabled = !value;
            showAppNames.Enabled = !value;
            launcherShortcut.Enabled = !value && hotkey != null;
            // Shortcuts that changed during this operation are looked at now, except those BetterIcon wrote itself.
            if (!value) { ownWritesUntil = DateTime.UtcNow.AddSeconds(10); FlushShortcutEvents(); }
            SetAppearanceBusy(value);
            UpdatePackButtons();
            // The offer's link follows the window: an operation that showed the offer while it ran leaves it usable.
            if (webpInstall != null) webpInstall.Enabled = !value && !webpInstalling;
            if (!String.IsNullOrEmpty(message)) status.Text = message;
            UseWaitCursor = value; BuildTrayMenu();
            // WS_DISABLED paints native list views in system colors. Pause input
            // instead so artwork, labels and theme updates keep their normal paint.
            apps.InputBlocked = packPreview.InputBlocked = filePreview.InputBlocked = value;
            ShowLoading(value, message);
            // WebP support that arrived during this operation: the packs are read again now that it is over.
            if (!value && reloadPending && IsHandleCreated && !IsDisposed) BeginInvoke(new Action(async delegate { await ReloadWhenIdle(); }));
        }
        public void ToggleAboveTray(Point anchor)
        {
            TraceFixture("Tray click");
            dismissTimer.Stop(); trayAnchor = anchor;
            if (!Enabled) { ActivateDialog(); return; }
            if (Visible && WindowState != FormWindowState.Minimized) { Hide(); return; }
            ShowPopup(anchor, false, preferLargerPage: true);
        }
        public void ShowManager()
        {
            Rectangle work = Screen.FromPoint(trayAnchor ?? Cursor.Position).WorkingArea;
            Point anchor = trayAnchor ?? new Point(work.Right, work.Bottom);
            ShowPopup(anchor, false);
        }
        public void ShowAtCursor(Point cursor) { ShowPopup(cursor, true); }
        Size PreferredPageSize(bool launcher)
        {
            Size size = launcher ? preferences.LauncherWindowSize : preferences.ManageWindowSize;
            if (size.Width <= 0 || size.Height <= 0) size = DefaultWindowSize;
            Size minimum = launcher ? LauncherMinimum : ManageMinimum;
            return new Size(Math.Max(size.Width, minimum.Width), Math.Max(size.Height, minimum.Height));
        }
        void ApplyPageBounds(Rectangle bounds)
        {
            Size minimum = pages.SelectedTab == launcherPage ? LauncherMinimum : ManageMinimum;
            MinimumSize = new Size(Math.Min(minimum.Width, bounds.Width), Math.Min(minimum.Height, bounds.Height));
            Bounds = bounds;
            SizeTabs();
            displayedPageSize = Size;
        }
        void RestorePageAtDivider()
        {
            bool launcher = pages.SelectedTab == launcherPage;
            Point topCenter = new Point(Left + Width / 2, Top);
            ApplyPageBounds(PopupPlacement.AtTabDivider(PreferredPageSize(launcher), PreferredPageSize(!launcher),
                topCenter, Screen.FromPoint(topCenter).WorkingArea));
        }
        void FinishWindowResize()
        {
            if (!Visible || WindowState != FormWindowState.Normal) return;
            if (Size != displayedPageSize) {
                if (pages.SelectedTab == launcherPage) preferences.LauncherWindowSize = Size;
                else preferences.ManageWindowSize = Size;
                try { WritePreferences(); }
                catch (IOException) { status.Text = "Window size changed for this session, but could not be saved."; }
                catch (UnauthorizedAccessException) { status.Text = "Window size changed for this session, but could not be saved."; }
            }
            RestorePageAtDivider();
        }
        void ActivateDialog() { foreach (Form dialog in OwnedForms) if (dialog.Visible) { dialog.Activate(); break; } }
        void ShowPopup(Point anchor, bool centered, bool preferLargerPage = false)
        {
            if (!Enabled) { ActivateDialog(); return; }
            if (!Visible) SetFilter("");
            dismissTimer.Stop();
            Rectangle work = Screen.FromPoint(anchor).WorkingArea;
            Size launcher = PreferredPageSize(true), manage = PreferredPageSize(false);
            bool openManage = preferLargerPage && (long)manage.Width * manage.Height > (long)launcher.Width * launcher.Height;
            Rectangle bounds = PopupPlacement.Place(openManage ? manage : launcher, openManage ? launcher : manage, anchor, work, centered);
            openingPopup = true;
            try {
                pages.SelectedTab = openManage ? settingsPage : launcherPage;
                WindowState = FormWindowState.Normal;
                ApplyPageBounds(bounds); Show();
                // Also works when launched with STARTUPINFO's initial hidden state.
                ShowWindow(Handle, 1);
                ApplyPageBounds(bounds);
            }
            finally { openingPopup = false; }
            Activate();
            if (openManage) themes.Focus(); else apps.Focus();
            TraceFixture(centered ? "Hotkey positioned" : "Positioned", anchor);
        }
        void ExitLauncher() { if (busy) { ShowManager(); AppAppearance.Message(this, Text, "Please wait for the current operation to finish.", appearancePalette, false); return; } exiting = true; Close(); }
        void RequestExternalStop()
        {
            // Setup must not interrupt an icon operation or discard an editor.
            // Common file dialogs disable their owner without joining OwnedForms.
            // Refuse this request silently; the caller has its own bounded wait.
            if (busy || !Enabled || (IsHandleCreated && !IsWindowEnabled(Handle)) || OwnedForms.Any(form => form.Visible && form.Modal)) return;
            ExitLauncher();
        }
        void UpdateHotkeyHint()
        {
            bool registered = hotkey != null && hotkey.IsRegistered;
            string shortcut = preferences.Hotkey.Enabled ? preferences.Hotkey.ToString() : "Disabled";
            if (preferences.Hotkey.Enabled && !registered) shortcut += " (unavailable)";
            launcherShortcut.Text = "Launcher shortcut \u00b7 " + shortcut;
            string hint = !preferences.Hotkey.Enabled ? "Global hotkey disabled." : registered ? preferences.Hotkey + " opens at your cursor." : "Hotkey unavailable. Choose another combination.";
            subtitle.Text = (fixtureLog == null ? "" : "Test shortcuts only. ") + hint;
            BuildTrayMenu();
        }
        void ShowSettings()
        {
            if (busy || hotkey == null) return;
            if (!Enabled) { ActivateDialog(); return; }
            if (!Visible) ShowManager();
            pages.SelectedTab = settingsPage;
        }
        void ChangeHotkey()
        {
            if (busy || hotkey == null) return;
            if (!Enabled || OwnedForms.Any(dialog => dialog.Visible)) { ActivateDialog(); return; }
            if (!Visible) ShowManager();
            bool trayEnabled = trayMenu.Enabled;
            trayMenu.Enabled = false;
            try {
                using (HotkeySettingsDialog dialog = new HotkeySettingsDialog(preferences.Hotkey, hotkey.IsRegistered, SaveHotkey)) {
                    ApplyDialogAppearance(dialog); dialog.ShowDialog(this);
                }
            }
            finally { trayMenu.Enabled = trayEnabled; }
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
            // A chosen pack that is waiting to be downloaded again stays the saved choice.
            if (SelectedTheme != null) preferences.Theme = wantedThemeId ?? SelectedTheme.Id;
            preferences.Scope = Scope;
            try { WritePreferences(); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        Task RefreshCatalog() { return ReadCatalog(false); }
        async Task CheckForPackUpdates()
        {
            if (busy || checkingPackUpdates || IsDisposed || Disposing) return;
            checkingPackUpdates = true;
            nextPackCheck = DateTime.UtcNow.AddMinutes(30);
            int generation = packCheckGeneration;
            try {
                var request = new WorkerRequest { Action = "CheckPackUpdates", Scope = Scope, PreviousPackCheck = packUpdateCheck };
                WorkerReply reply = await worker.Run(request, false);
                // A manual refresh may have acknowledged the same changes while we were checking.
                if (!IsDisposed && !Disposing && generation == packCheckGeneration) SetPackUpdateCheck(reply.PackCheck);
            }
            catch (Exception error) { Trace.WriteLine("BetterIcon pack update check: " + error.Message); }
            finally { checkingPackUpdates = false; }
        }
        void SetPackUpdateCheck(PackUpdateCheck check)
        {
            packUpdateCheck = check;
            int count = check == null ? 0 : check.Count;
            refreshPacksButton.AccessibleDescription = count > 0
                ? count + (count == 1 ? " new or updated icon pack available." : " new or updated icon packs available.")
                : null;
            refreshPacksButton.Invalidate();
        }
        // True when the packs and apps were read.
        async Task<bool> ReadCatalog(bool online)
        {
            if (busy) return false;
            if (online && !Enabled) { ActivateDialog(); return false; }
            var previous = new HashSet<string>(bundledThemes.Select(t => t.Id), StringComparer.OrdinalIgnoreCase);
            // A WebP decoder Windows lacked until now, such as the Store's WebP Image Extensions, is looked for again.
            WebpArtwork.ForgetMissingWindowsDecoder();
            SetBusy(true, online ? "Checking for the latest icon packs..." : "Finding apps and themes...");
            try {
                WorkerReply reply = await worker.Run(new WorkerRequest { Action = online ? "RefreshPackCatalog" : "Catalog", Scope = Scope }, false);
                if (IsDisposed || Disposing) return false;
                catalog = reply.Catalog;
                if (fixtureLog == null && !IsDisposed) {
                    if (runningTaskbarIcons == null) runningTaskbarIcons = new RunningTaskbarIcons();
                    runningTaskbarIcons.Update(catalog.Apps);
                }
                bundledThemes = catalog.Themes;
                ReloadLibrary(null);
                // What the chosen packs leave out, and why, comes first: the WebP offer beside it may be the way to fix it.
                string leftOut = LeftOutStatus();
                status.Text = leftOut ?? (catalog.Apps.Length == 0 ? "No ArtCraft shortcuts found. Install an app, then refresh from the tray menu." : ReviewedText);
                Text = "BetterIcon for ArtCraft  " + catalog.Version;
                if (online) {
                    packCheckGeneration++;
                    SetPackUpdateCheck(null);
                    previewStore.Refresh();
                    int added = bundledThemes.Count(t => !previous.Contains(t.Id));
                    int updated = bundledThemes.Count(t => t.UpdateAvailable);
                    string result = added == 0 ? "Pack list is up to date." : added + (added == 1 ? " new pack found." : " new packs found.");
                    result += " " + bundledThemes.Length + " packs available.";
                    if (updated > 0) result += " Artwork updates available for " + updated + ".";
                    PackRefreshResult(result, ToolTipIcon.Info, leftOut);
                }
                return true;
            }
            catch (Exception error) {
                if (!IsDisposed && !Disposing) {
                    if (online) PackRefreshResult("Couldn't refresh icon packs. " + error.Message, ToolTipIcon.Warning);
                    else Report(error);
                }
                return false;
            }
            finally {
                if (!IsDisposed && !Disposing) SetBusy(false, null);
            }
        }
        // The status line also names what the chosen packs leave out; the balloon keeps to the pack list.
        void PackRefreshResult(string message, ToolTipIcon icon, string detail = null)
        {
            status.Text = detail == null ? message : message + " " + detail;
            if (fixtureLog == null && (!Visible || pages.SelectedTab != settingsPage))
                tray.ShowBalloonTip(3500, "BetterIcon pack list", message, icon);
        }
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        static extern int SHDefExtractIconW(string file, int index, uint flags, out IntPtr large, IntPtr small, uint size);
        [DllImport("user32.dll")]
        static extern bool DestroyIcon(IntPtr icon);
        internal static Bitmap Thumbnail(string path, Icon fallback, int size = 48, int iconIndex = 0)
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
                else if (Path.GetExtension(path).Equals(".svg", StringComparison.OrdinalIgnoreCase)) loaded = SvgArtwork.Render(File.ReadAllBytes(path), size);
                else if (Path.GetExtension(path).Equals(".webp", StringComparison.OrdinalIgnoreCase)) {
                    if (new FileInfo(path).Length > WebpArtwork.MaxBytes) throw new IOException(WebpArtwork.Damaged);
                    loaded = WebpArtwork.Decode(File.ReadAllBytes(path));
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
        static string PreviewPath(ThemeIcon artwork) { return String.IsNullOrEmpty(artwork.PreviewPath) ? artwork.Path : artwork.PreviewPath; }
        static ArtworkSource DescribeArtwork(string path, int index)
        {
            path = path ?? "";
            int maximum = 128;
            try {
                string extension = Path.GetExtension(path).ToLowerInvariant();
                if (extension == ".svg") maximum = Preferences.MaximumIconSize;
                else if (extension == ".png") using (Image source = Image.FromFile(path)) maximum = Math.Max(source.Width, source.Height);
                else if (extension == ".webp") { int side = WebpArtwork.Side(path); maximum = side > 0 ? side : 128; }
                else if (extension == ".ico") using (BinaryReader reader = new BinaryReader(File.OpenRead(path))) {
                    if (reader.ReadUInt16() == 0 && reader.ReadUInt16() == 1) {
                        int count = reader.ReadUInt16();
                        if (count > 1024) throw new IOException("Invalid icon directory.");
                        for (int i = 0; i < count; i++) {
                            int width = reader.ReadByte(), height = reader.ReadByte(); reader.ReadBytes(14);
                            maximum = Math.Max(maximum, Math.Max(width == 0 ? 256 : width, height == 0 ? 256 : height));
                        }
                    }
                }
                else if (extension == ".exe" || extension == ".dll" || extension == ".icl") maximum = 256;
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            catch (ArgumentException) { }
            catch (OutOfMemoryException) { }
            catch (ExternalException) { }
            return new ArtworkSource { Path = path, Index = index, MaximumSize = Math.Max(128, Math.Min(Preferences.MaximumIconSize, maximum)) };
        }
        void AddArtwork(List<Bitmap> images, List<ArtworkSource> sources, string path, int index)
        {
            sources.Add(DescribeArtwork(path, index)); images.Add(Thumbnail(path, Icon, 128, index));
        }
        void EnsureArtworkSize(List<Bitmap> images, List<ArtworkSource> sources, int size)
        {
            int requested = 128; while (requested < size) requested *= 2;
            for (int i = 0; i < images.Count; i++) {
                int needed = Math.Min(requested, sources[i].MaximumSize);
                if (images[i].Width >= needed) continue;
                Bitmap replacement = Thumbnail(sources[i].Path, Icon, needed, sources[i].Index);
                images[i].Dispose(); images[i] = replacement;
            }
        }
        void RenderSelection()
        {
            renderingArtwork = true;
            try { RenderApps(); RenderPack(); RenderFilePack(); }
            finally { renderingArtwork = false; }
            UpdateIconSizeLimit(); ResizeAppIcons(); ResizePackIcons(); ResizeFileIcons();
            renderedThemeId = SelectedTheme == null ? null : SelectedTheme.Id;
            renderedFileThemeId = SelectedFileTheme == null ? null : SelectedFileTheme.Id;
        }
        void UpdateIconSizeLimit()
        {
            int maximum = appSources.Concat(packSources).Concat(fileSources).Select(source => source.MaximumSize).DefaultIfEmpty(128).Max();
            int previous = preferences.IconSize;
            int requested = Math.Min(preferences.IconSize, maximum);
            iconSizeSlider.Maximum = maximum; iconSizeSlider.Value = requested;
            // TrackBar.Maximum can clamp Value without raising ValueChanged.
            preferences.IconSize = iconSizeSlider.Value; SyncIconSizeValue();
            if (previous != preferences.IconSize) SavePreferences();
            iconSizeSlider.AccessibleDescription = "Size in pixels, from 24 to " + maximum + ", based on available artwork. Updates both tabs.";
        }
        void ClearAppArtwork() { foreach (Bitmap image in appArtwork) image.Dispose(); appArtwork.Clear(); appSources.Clear(); }
        // The Launcher shows the pack that was last applied, never the one being browsed.
        ThemeEntry AppliedTheme()
        {
            if (catalog == null || String.IsNullOrEmpty(preferences.AppliedTheme)) return null;
            string id = catalog.CurrentPackId(preferences.AppliedTheme);
            return catalog.Themes.Concat(bundledThemes).FirstOrDefault(theme => theme.Id == id && !theme.NeedsDownload);
        }
        // The artwork recorded when the pack was applied stays in use after the pack is
        // edited, updated or removed. Without it, show the shortcut's own icon.
        string AppliedArtwork(ThemeEntry applied, AppEntry entry)
        {
            string path;
            if (preferences.AppliedArtwork != null && preferences.AppliedArtwork.TryGetValue(entry.Application, out path) && File.Exists(path)) return path;
            ThemeIcon artwork = applied == null ? null : applied.Icons.FirstOrDefault(icon => icon.Application == entry.Application);
            return artwork == null ? null : PreviewPath(artwork);
        }
        void RememberAppliedTheme(ThemeEntry theme)
        {
            preferences.AppliedTheme = theme == null ? ThemeEntry.DefaultThemeId : theme.Id;
            preferences.AppliedArtwork = theme == null || theme.IsDefault ? null : theme.Icons.ToDictionary(icon => icon.Application, icon => PreviewPath(icon));
        }
        void RenderApps()
        {
            if (catalog == null) return;
            apps.BeginUpdate();
            try {
                apps.Items.Clear(); appTiles.Clear();
                ClearAppArtwork();
                ThemeEntry theme = AppliedTheme();
                bool defaults = preferences.AppliedTheme == ThemeEntry.DefaultThemeId;
                foreach (AppEntry entry in catalog.Apps) {
                    bool original = defaults || (preferences.DefaultShortcuts ?? new string[0]).Contains(entry.Shortcut, StringComparer.OrdinalIgnoreCase);
                    // A shortcut someone changed outside BetterIcon shows the icon it has now.
                    bool ownIcon = entry.Change == "Custom" || entry.Change == "Replaced" || entry.Change == "Reverted";
                    string artwork = original || ownIcon ? null : AppliedArtwork(theme, entry);
                    bool originalSource = original || String.IsNullOrWhiteSpace(entry.IconPath);
                    AddArtwork(appArtwork, appSources, artwork ?? Environment.ExpandEnvironmentVariables((originalSource ? entry.OriginalIconPath : entry.IconPath) ?? ""), artwork != null ? 0 : originalSource ? entry.OriginalIconIndex : entry.IconIndex);
                    ListViewItem item = new ListViewItem(entry.Name, appArtwork.Count-1) { Tag = entry, ToolTipText = entry.Name + Environment.NewLine + entry.Shortcut };
                    appTiles.Add(item);
                }
                if (!renderingArtwork) { UpdateIconSizeLimit(); ResizeAppIcons(); }
            }
            finally { apps.EndUpdate(); }
        }
        void ResizeAppIcons()
        {
            ListViewItem selected = apps.SelectedItems.Count == 1 ? apps.SelectedItems[0] : null;
            int size = preferences.IconSize;
            apps.BeginUpdate();
            try {
                EnsureArtworkSize(appArtwork, appSources, size);
                apps.SetArtwork(appArtwork, size);
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
            apps.ClearHover();
            apps.BeginUpdate();
            try {
                apps.Items.Clear();
                foreach (ListViewItem item in appTiles) {
                    item.Selected = item.Focused = false;
                    if (item.Text.StartsWith(filterText, StringComparison.OrdinalIgnoreCase)) apps.Items.Add(item);
                }
                // A fresh popup stays unselected; typing still readies its first match for Enter.
                if (filterText.Length > 0 && apps.Items.Count > 0) {
                    apps.Items[0].Selected = apps.Items[0].Focused = true;
                    if (apps.IsHandleCreated) apps.Items[0].EnsureVisible();
                }
                filterHint.Text = catalog == null ? "Finding installed apps..." : filterText.Length == 0 ? "No ArtCraft apps found. Right-click the tray icon to refresh." : "No apps match '" + filterText + "'. Backspace edits; Esc clears.";
                filterHint.Visible = apps.Items.Count == 0;
                apps.AccessibleDescription = (filterText.Length == 0 ? "Type an app name to filter. Click or press Enter to open. Escape closes." : "Filter: " + filterText + ". " + apps.Items.Count + " matches. Escape clears.") + " Ctrl+mouse wheel changes icon size.";
            }
            finally { apps.EndUpdate(); }
        }
        void SetFilter(string value) { filterText = value; FilterApps(); }
        bool CanFilter { get { return Enabled && !busy && pages.SelectedTab == launcherPage && !PackListOpen && !AppearanceMenuOpen && !trayMenu.Visible && !iconMenu.Visible && !importPackMenu.Visible && !managePackMenu.Visible && !manageFilePackMenu.Visible; } }
        bool HandlePopupKey(Keys key)
        {
            if (key == Keys.Escape && Enabled && pages.SelectedTab == settingsPage && !PackListOpen && !AppearanceMenuOpen && !iconMenu.Visible && !busy) { pages.SelectedTab = launcherPage; apps.Focus(); return true; }
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
            if (key == Keys.Enter && apps.ContainsFocus) { apps.ClearHover(); LaunchSelected(); return true; }
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
            chooseAppIcon.Enabled = restoreIconDefault.Enabled = false;
            if (busy || !Enabled || catalog == null) return;
            ListViewItem item = point.HasValue ? grid.GetItemAt(point.Value.X, point.Value.Y) : grid.SelectedItems.Cast<ListViewItem>().FirstOrDefault();
            if (item == null) return;
            AppEntry target = item.Tag as AppEntry;
            if (target == null) {
                string application = item.Tag as string;
                if (String.IsNullOrEmpty(application)) return;
                AppEntry[] matches = catalog.Apps.Where(app => app.Application == application).ToArray();
                target = new AppEntry { Application = application,
                    RestoreAvailable = matches.Any(app => app.RestoreAvailable), UsingDefaultIcon = matches.Any(app => app.UsingDefaultIcon) };
            }
            foreach (ListViewItem selected in grid.SelectedItems.Cast<ListViewItem>().ToArray()) selected.Selected = false;
            item.Selected = item.Focused = true; grid.Focus();
            if (!point.HasValue) item.EnsureVisible();
            iconMenuTarget = target;
            chooseAppIcon.Enabled = PackLibrary.Applications.Contains(target.Application);
            chooseAppIcon.ToolTipText = "Choose an SVG, PNG or ICO for " + target.Application + ". Built-in packs are saved as a personal copy.";
            restoreIconDefault.Enabled = catalog.Apps.Any(app => app.Application == target.Application && app.CanRestoreDefault);
            restoreIconDefault.ToolTipText = restoreIconDefault.Enabled ? "Restore only " + target.Application + ". Choose current user or all users before reviewing the shortcuts." : "No BetterIcon backup or existing default to restore for this app.";
            Point anchor = point ?? new Point(item.Bounds.Left + item.Bounds.Width / 2, item.Bounds.Bottom);
            iconMenu.Show(grid, anchor);
        }
        void Launch(AppEntry entry)
        {
            if (busy) return;
            try {
                if (!File.Exists(entry.Shortcut)) throw new FileNotFoundException("This shortcut is no longer available. Choose Refresh installed apps in the tray menu.");
                Process.Start(new ProcessStartInfo(entry.Shortcut) { UseShellExecute = true });
                status.Text = "Opened " + entry.Name + ".";
            }
            catch (Exception error) { Report(error); }
        }
        void BuildTrayMenu()
        {
            trayHover.Clear();
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
            themeMenu.DropDownClosed += delegate { trayHover.Clear(); };
            if (catalog != null) foreach (ThemeEntry theme in catalog.Themes) {
                ThemeEntry captured = theme;
                ToolStripMenuItem item = new ToolStripMenuItem(theme.ToString());
                MouseEventHandler hoverRow = delegate {
                    if (item.Owner != null && item.Owner.Visible) trayHover.Hover(captured, item.Owner.RectangleToScreen(item.Bounds));
                };
                item.MouseEnter += delegate { hoverRow(item, null); };
                item.MouseMove += hoverRow;
                item.MouseLeave += delegate { trayHover.Clear(); };
                item.Click += delegate { ShowSettings(); themes.ChooseItem(captured); }; themeMenu.DropDownItems.Add(item);
            }
            trayMenu.Items.Add(themeMenu); trayMenu.Items.Add(new ToolStripSeparator());
            ToolStripMenuItem packActions = new ToolStripMenuItem("Pack actions") { Enabled = !busy };
            foreach (ToolStripItem command in managePackMenu.Items) {
                ToolStripMenuItem source = command as ToolStripMenuItem;
                if (source == null) { packActions.DropDownItems.Add(new ToolStripSeparator()); continue; }
                ToolStripMenuItem copy = new ToolStripMenuItem(source.Text) { Enabled = source.Enabled };
                copy.Click += delegate {
                    if (OwnedForms.Any(dialog => dialog.Visible)) { ActivateDialog(); return; }
                    ShowSettings();
                    bool trayEnabled = trayMenu.Enabled; trayMenu.Enabled = false;
                    try { source.PerformClick(); }
                    finally { trayMenu.Enabled = trayEnabled; }
                };
                packActions.DropDownItems.Add(copy);
            }
            trayMenu.Items.Add(packActions);
            ToolStripMenuItem reload = new ToolStripMenuItem("Refresh installed apps") { Enabled = !busy }; reload.Click += async delegate { await RefreshInstalledApps(); }; trayMenu.Items.Add(reload);
            var refreshPacks = new ToolStripMenuItem("Refresh available icon packs") { Enabled = !busy };
            refreshPacks.Click += async delegate { await ReadCatalog(true); await RestoreChosenPacks(); }; trayMenu.Items.Add(refreshPacks);
            ToolStripMenuItem restoreItem = new ToolStripMenuItem("Restore original icons...") { Enabled = !busy }; restoreItem.Click += async delegate { ShowSettings(); await RestoreIcons(); }; trayMenu.Items.Add(restoreItem);
            AddSharedReapplyItems();
            AddDownloadItems();
            ToolStripMenuItem settingsItem = new ToolStripMenuItem("Manage Icons...") { Enabled = !busy }; settingsItem.Click += delegate { ShowSettings(); }; trayMenu.Items.Add(settingsItem);
            ToolStripMenuItem hotkeyItem = new ToolStripMenuItem("Change hotkey...") { Enabled = !busy && hotkey != null, ToolTipText = subtitle.Text };
            hotkeyItem.Click += delegate { ChangeHotkey(); }; trayMenu.Items.Add(hotkeyItem);
            trayMenu.Items.Add(new ToolStripSeparator());
            AddLoginItem();
            ToolStripMenuItem quit = new ToolStripMenuItem("Exit BetterIcon") { Enabled = !busy }; quit.Click += delegate { ExitLauncher(); }; trayMenu.Items.Add(quit);
            if (appearancePalette != null) AppAppearance.ApplyMenu(trayMenu, appearancePalette);
        }
        bool Review(string title, string description, IEnumerable<string[]> rows, bool canApply, string accept, string subject = "Shortcut")
        {
            using (Form dialog = new Form { Text = title, Font = Font, StartPosition = FormStartPosition.CenterParent, Size = new Size(850, 530), MinimumSize = new Size(720, 430), MinimizeBox = false, MaximizeBox = false }) {
                TableLayoutPanel panel = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(18), RowCount = 3, ColumnCount = 1 };
                panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 72)); panel.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
                Label note = new Label { Text = description, Dock = DockStyle.Fill };
                panel.Controls.Add(note, 0, 0);
                // A long pack name or an extra line wraps: give the note the height its text needs at this width.
                panel.ClientSizeChanged += delegate {
                    int width = Math.Max(100, panel.ClientSize.Width - panel.Padding.Horizontal - note.Margin.Horizontal);
                    int needed = TextRenderer.MeasureText(description, note.Font, new Size(width, 0), TextFormatFlags.WordBreak).Height + note.Margin.Vertical + 6;
                    if (panel.RowStyles[0].Height != Math.Max(72, needed)) panel.RowStyles[0].Height = Math.Max(72, needed);
                };
                ListView list = new ListView { View = View.Details, Dock = DockStyle.Fill, FullRowSelect = true, GridLines = true };
                list.Columns.Add("Status", 100); list.Columns.Add(subject, 470); list.Columns.Add("Details", 210);
                foreach (string[] row in rows) list.Items.Add(new ListViewItem(row)); panel.Controls.Add(list, 0, 1);
                // A longer detail, such as "PhotoCraft (Open with, other file types)", widens its column and takes that room
                // from the middle column, which keeps at least two fifths. It is measured in the font the dialog shows, which
                // Windows may scale for the display when the dialog appears.
                dialog.Shown += delegate {
                    int widest = 0;
                    foreach (ListViewItem item in list.Items) if (item.SubItems.Count > 2) widest = Math.Max(widest, TextRenderer.MeasureText(item.SubItems[2].Text, list.Font).Width);
                    int room = list.Columns[1].Width + list.Columns[2].Width, details = Math.Min(room - room * 2 / 5, widest + 18);
                    if (details > list.Columns[2].Width) { list.Columns[2].Width = details; list.Columns[1].Width = room - details; }
                };
                FlowLayoutPanel buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft };
                Button cancel = Button("Cancel", 100); cancel.DialogResult = DialogResult.Cancel;
                Button ok = Button(accept, 220); ok.DialogResult = DialogResult.OK; ok.Enabled = canApply; ok.Tag = "PrimaryAction";
                buttons.Controls.Add(cancel); buttons.Controls.Add(ok); panel.Controls.Add(buttons, 0, 2); dialog.Controls.Add(panel);
                dialog.CancelButton = cancel; dialog.AcceptButton = ok;
                ApplyDialogAppearance(dialog);
                return dialog.ShowDialog(this) == DialogResult.OK;
            }
        }
        async Task ApplyTheme()
        {
            if (busy || SelectedTheme == null) return;
            if (SelectedTheme.IsDefault) { await RestoreIcons(); return; }
            ThemeEntry selected = SelectedTheme;
            string theme = selected.Id, scope = ChooseShortcutScope(false);
            if (scope == null) { status.Text = "Cancelled. No icons changed."; return; }
            bool refresh = false;
            SetBusy(true, "Preparing a preview. No icons changed yet...");
            try {
                await WaitForReconcile();
                WorkerReply preview = await worker.Run(new WorkerRequest { Action = "Preview", Theme = theme, Scope = scope }, false);
                // A shortcut someone changed outside BetterIcon is listed as Changed and left as it is.
                int count = preview.Plan.Count(p => p.Status == "Ready" && !ChangedOutside(p.Change));
                string note = "Apply " + selected + " to " + count + " shortcut(s) in " + (scope == "AllUsers" ? "the shared Desktop and Start menu" : "your Desktop and Start menu, including matching taskbar pins") + (fixtureLog != null ? " (test shortcuts only)" : "") + ". Original shortcuts are backed up.\r\n" +
                    (scope == "AllUsers" ? "Windows will request administrator access. " : "") + "Missing or ambiguous artwork is skipped.";
                if (!Review("Review icon changes", note, preview.Plan.Select(p => new[] { p.Status == "Ready" && ChangedOutside(p.Change) ? "Changed" : p.Status, p.Shortcut, p.Reason }), count > 0, "Apply theme")) { status.Text = "Cancelled. No icons changed."; return; }
                status.Text = "Applying theme...";
                WorkerReply result = await worker.Run(new WorkerRequest { Action = "Apply", Theme = theme, Scope = scope, ExpectedPlan = preview.Plan }, scope == "AllUsers" && !IsAdministrator());
                // The Launcher adopts a pack once Windows has accepted it for at least one shortcut.
                if (result.Results.Any(r => r.Status == "Applied" || r.Status == "Unchanged")) RememberAppliedTheme(selected);
                ForgetReapplyItems(scope, result.Results, "Applied", "Unchanged");
                RememberOwnWrites(result.Results, false);
                if (scope == "AllUsers") SharedScopeChanged();
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
        async Task RestoreIcons(string application = null)
        {
            if (busy) return;
            bool refresh = false;
            string scope = ChooseShortcutScope(true, application);
            if (scope == null) { status.Text = "Cancelled. No icons changed."; return; }
            SetBusy(true, "Checking original shortcut backups...");
            try {
                await WaitForReconcile();
                WorkerReply preview = await worker.Run(new WorkerRequest { Action = "RestorePreview", Scope = scope, Application = application }, false);
                if (preview.Results.Length == 0) {
                    // A pin can have its own backup even if the Start shortcut is already at the default.
                    if (application != null && catalog != null) {
                        AppEntry[] matches = catalog.Apps.Where(app => app.Application == application && app.Scope == scope).ToArray();
                        if (!matches.Any(app => app.RestoreAvailable) && matches.Any(app => app.UsingDefaultIcon)) {
                            RememberRestoredShortcuts(matches.Where(app => app.UsingDefaultIcon).Select(app => new ResultItem { Shortcut = app.Shortcut, Status = "Restored" }).ToArray(), true);
                            RenderSelection();
                            status.Text = (application == "ArtCraftLauncher" ? "ArtCraft Launcher" : application) + " is using its ArtCraft default icon. Its Windows shortcut was already at the default.";
                            return;
                        }
                    }
                    // Asking for every default returns the Launcher to the original icons as well.
                    if (application == null && preferences.AppliedTheme != ThemeEntry.DefaultThemeId) { RememberAppliedTheme(null); SavePreferences(); RenderSelection(); }
                    status.Text = "No BetterIcon changes to restore" + (application == null ? "" : " for " + application) + " in these locations.";
                    return;
                }
                string note = "Restore " + (application == null ? "all original ArtCraft shortcuts" : "only " + application + " shortcuts") + " in " + (scope == "AllUsers" ? "shared locations (administrator access required)." : "your locations.") + (fixtureLog != null ? " Test shortcuts only." : "") + "\r\nLater user edits and app updates are preserved. Backups and icon files remain available for recovery.";
                if (!Review("Review restoration", note, preview.Results.Select(r => new[] { r.Status, r.Shortcut, r.Message }), true, "Restore original icons")) { status.Text = "Cancelled. No icons changed."; return; }
                status.Text = "Restoring original icons...";
                WorkerReply result = await worker.Run(new WorkerRequest { Action = "Restore", Scope = scope, Application = application, ExpectedStateHash = preview.StateHash }, scope == "AllUsers" && !IsAdministrator());
                if (application == null && result.Results.Any(r => r.Status == "Restored")) RememberAppliedTheme(null);
                ForgetReapplyItems(scope, result.Results, "Restored");
                RememberOwnWrites(result.Results, false);
                if (scope == "AllUsers") SharedScopeChanged();
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
            Review("Operation results", status.Text, results.Select(r => new[] { r.Status, r.Shortcut, r.Message }), true, "Done");
        }
        void Report(Exception error)
        {
            System.ComponentModel.Win32Exception native = error as System.ComponentModel.Win32Exception;
            string message = native != null && native.NativeErrorCode == 1223 ? "Administrator request cancelled. No icons changed." : error.Message;
            status.Text = message; if (!Visible) ShowManager(); pages.SelectedTab = settingsPage; AppAppearance.Message(this, "BetterIcon", message, appearancePalette, false);
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
        static int StopAndWait(string name)
        {
            Mutex running;
            try { running = Mutex.OpenExisting(name); }
            catch (WaitHandleCannotBeOpenedException) { return 0; }
            using (running) {
                Stopwatch timeout = Stopwatch.StartNew();
                bool signaled = false;
                while (true) {
                    bool acquired = false;
                    try {
                        try { acquired = running.WaitOne(0); }
                        catch (AbandonedMutexException) { acquired = true; }
                        if (acquired) return 0;
                    }
                    finally { if (acquired) running.ReleaseMutex(); }
                    if (timeout.ElapsedMilliseconds >= 10000) return 2;
                    if (!signaled) {
                        try { using (EventWaitHandle signal = EventWaitHandle.OpenExisting(name + ".InstallStop")) signaled = signal.Set(); }
                        catch (WaitHandleCannotBeOpenedException) { }
                    }
                    // Retry the startup race before the installer event exists.
                    // Older releases expose only .Stop, whose handler can close
                    // unsaved dialogs. Never fall back to that unsafe protocol.
                    Thread.Sleep(50);
                }
            }
        }

        [STAThread]
        static int Main(string[] args)
        {
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
            // Setup's own switches never show a message box: Setup reads their exit codes and files.
            bool stopAndWait = false, quietErrors = args.Contains("--stop-and-wait") || args.Contains("--probe-webp") || args.Contains("--setup-status");
            try {
                string source = AppDomain.CurrentDomain.BaseDirectory, configPath = null, statusPath = null, setupDownloads = null;
                bool hidden = false, stop = false, probeWebP = false;
                for (int i=0; i<args.Length; i++) {
                    if (args[i] == "--tray") hidden = true;
                    else if (args[i] == "--stop") stop = true;
                    else if (args[i] == "--stop-and-wait") stopAndWait = true;
                    else if (args[i] == "--source-folder" && i+1<args.Length) source = Path.GetFullPath(args[++i]);
                    else if (args[i] == "--config" && i+1<args.Length) configPath = Path.GetFullPath(args[++i]);
                    // Hidden switches for Setup: whether Windows decodes WebP (exit code), what the optional downloads
                    // page offers (an INI file), and the downloads chosen there, which this program then fetches.
                    else if (args[i] == "--probe-webp") probeWebP = true;
                    else if (args[i] == "--setup-status" && i+1<args.Length) statusPath = Path.GetFullPath(args[++i]);
                    else if (args[i] == "--setup-downloads" && i+1<args.Length) setupDownloads = args[++i];
                    else throw new ArgumentException("Unknown launcher option.");
                }
                string identity = WindowsIdentity.GetCurrent().User.Value + "|" + (configPath ?? "main");
                string hash; using (SHA256 sha = SHA256.Create()) hash = BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(identity))).Replace("-", "");
                string name = "Local\\BetterIcon.Tray." + hash;
                // Setup extracts this EXE alone. Stopping does not need helper
                // scripts, artwork, or even an extant fixture configuration file.
                if (stopAndWait) return StopAndWait(name);
                FixtureConfig fixture = null;
                if (configPath != null) {
                    fixture = new JavaScriptSerializer().Deserialize<FixtureConfig>(File.ReadAllText(configPath));
                    if (fixture == null || fixture.ShortcutDirectory == null || fixture.ShortcutDirectory.Length == 0 || String.IsNullOrWhiteSpace(fixture.StateDirectory)) throw new ArgumentException("Fixture configuration requires both shortcut and state directories.");
                    if (!Path.IsPathRooted(fixture.StateDirectory) || fixture.ShortcutDirectory.Any(p => !Path.IsPathRooted(p) || !Directory.Exists(p))) throw new ArgumentException("Fixture paths must be absolute; shortcut directories must exist.");
                    fixture.ConfigPath = configPath;
                }
                if (probeWebP) {
                    try { return SetupProbe.WebP(source, fixture); }
                    catch (Exception error) { Console.Error.WriteLine(error.Message); return 10; }
                }
                if (statusPath != null) return SetupProbe.Status(source, fixture, statusPath);
                // Setup's choices wait in the state folder until the running copy has fetched them or the user declines.
                if (setupDownloads != null) SetupDownloadRequest.Merge(SetupProbe.StateFolder(fixture), setupDownloads);
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
                        using (EventWaitHandle installQuit = new EventWaitHandle(false, EventResetMode.AutoReset, name + ".InstallStop"))
                        using (LauncherForm form = new LauncherForm(source, fixture, hidden, show, quit, installQuit))
                        using (LauncherContext context = new LauncherContext(form)) Application.Run(context);
                    }
                    finally { singleton.ReleaseMutex(); }
                }
                return 0;
            }
            catch (Exception error) {
                if (quietErrors) Console.Error.WriteLine(error.Message);
                else MessageBox.Show(error.Message, "BetterIcon could not start", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
        }
    }
}
