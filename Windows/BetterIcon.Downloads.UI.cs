// Optional downloads: WebP support (Google's libwebp) where Windows cannot read WebP artwork, and the packs chosen on
// Setup's optional downloads page. Setup hands its choices to the installed app, which downloads them in the background.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace BetterIcon.Tray
{
    static class DownloadTexts
    {
        public const string WebPAction = "Install WebP support ({0})";
        public const string WebPActionTip = "Downloads Google's libwebp decoder from BetterIcon's release, checks it against its published checksum and installs it for your account. Microsoft's free WebP Image Extensions from the Microsoft Store work too.";
        public const string WebPMenu = "Install WebP support...";
        public const string WebPBusy = "Installing WebP support...";
        public const string WebPDone = "WebP support installed. Icons drawn in WebP now load and apply, without restarting BetterIcon.";
        public const string WebPWaiting = "WebP support installed. The left-out icons load when the current task finishes.";
        public const string WebPFailed = "Couldn't install WebP support. {0}";
        public const string NotNow = "Not now";
        public const string NotNowTip = "Hide this offer until another pack loads or BetterIcon starts again.";
        public const string SetupWebP = "Installing the WebP support you chose in Setup...";
        public const string SetupWebPFailed = "Couldn't install the WebP support you chose in Setup. {0}";
        public const string SetupPacks = "Downloading the icon packs you chose in Setup: {0} of {1}, {2}...";
        public const string SetupDone = "Downloaded the {0} icon packs you chose in Setup.";
        public const string SetupDoneOne = "Downloaded the icon pack you chose in Setup.";
        public const string SetupNothing = "The downloads you chose in Setup are already on this computer.";
        public const string SetupWebPDone = "Installed the WebP support you chose in Setup.";
        public const string SetupPacksFailed = "{0} of the icon packs you chose in Setup weren't downloaded. {1}";
        public const string SetupStopped = "Stopped downloading the icon packs you chose in Setup. {0} still to download.";
        public const string SetupRetry = "Download them";
        public const string SetupRetryWebP = "Try again";
        public const string SetupRetryTip = "Downloads what is still missing of what you chose in Setup.";
        public const string SetupDismissTip = "Forget what Setup still had to download. Each pack still downloads when you choose it.";
        public const string SetupStop = "Stop";
        public const string SetupStopTip = "Stops after the pack that is downloading now. BetterIcon offers the rest again.";
        public const string SetupMenu = "Download what you chose in Setup...";
    }

    // Setup's choices, kept in the state folder until they are downloaded or the user declines them.
    public sealed class SetupDownloadRequest
    {
        public bool WebP { get; set; }
        public bool AppPacks { get; set; }
        public bool FilePacks { get; set; }
        public string RequestedUtc { get; set; }
        // The last attempt's failure, offered again; empty before the first attempt.
        public string Failure { get; set; }
        public int Attempts { get; set; }
        // A balloon already told of this failure while BetterIcon was hidden in the tray.
        public bool Announced { get; set; }
        public bool Any { get { return WebP || AppPacks || FilePacks; } }
        public const string FileName = "setup-downloads.json";

        public static string PathIn(string state) { return System.IO.Path.Combine(state, FileName); }
        public static SetupDownloadRequest Read(string state)
        {
            try {
                string path = PathIn(state);
                if (!File.Exists(path) || new FileInfo(path).Length > 64 * 1024) return null;
                return new JavaScriptSerializer().Deserialize<SetupDownloadRequest>(File.ReadAllText(path, Encoding.UTF8));
            }
            catch (Exception) { return null; }
        }
        public void Write(string state)
        {
            string path = PathIn(state);
            if (!Any) { if (File.Exists(path)) File.Delete(path); return; }
            Directory.CreateDirectory(state);
            string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try {
                File.WriteAllText(temporary, new JavaScriptSerializer().Serialize(this), new UTF8Encoding(false));
                if (File.Exists(path)) File.Replace(temporary, path, null); else File.Move(temporary, path);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        // "webp,app-packs,file-packs" from Setup's command line. Unknown words are ignored; a new request adds to an old one.
        public static void Merge(string state, string list)
        {
            SetupDownloadRequest request = Read(state) ?? new SetupDownloadRequest();
            bool added = false;
            foreach (string word in (list ?? "").Split(new[] { ',', ';', ' ' }, StringSplitOptions.RemoveEmptyEntries)) {
                switch (word.Trim().ToLowerInvariant()) {
                    case "webp": request.WebP = added = true; break;
                    case "app-packs": request.AppPacks = added = true; break;
                    case "file-packs": request.FilePacks = added = true; break;
                }
            }
            if (!added) return;
            request.RequestedUtc = DateTime.UtcNow.ToString("o"); request.Failure = null; request.Attempts = 0; request.Announced = false;
            request.Write(state);
        }
    }

    // Answers for Setup, from hidden command-line switches of the installed program.
    static class SetupProbe
    {
        public static string StateFolder(FixtureConfig fixture)
        {
            return fixture == null ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BetterIcon-Craft Apps") : fixture.StateDirectory;
        }
        // --probe-webp. 0: Windows decodes WebP (fixture A4 through WIC). 1: it can't, and BetterIcon's WebP support is not
        // installed: Setup offers it. 2: it can't, and WebP support is installed and verified. 3: it can't, and there is
        // no WebP support build for this PC.
        public static int WebP(string source, FixtureConfig fixture)
        {
            LibWebP.Configure(Path.Combine(source, "LibWebP.ini"), StateFolder(fixture));
            if (WebpArtwork.SystemDecoderAvailable) return 0;
            LibWebP.PinSet pins = LibWebP.Pins;
            string[] needed = LibWebP.NeededArchitectures;
            if (pins == null || needed.Length == 0 || needed.Any(architecture => !pins.Packages.ContainsKey(architecture))) return 3;
            if ((Environment.GetEnvironmentVariable(WebpArtwork.DecoderSeam) ?? "").Trim().ToLowerInvariant() == "none") return 1;
            return needed.All(architecture => LibWebP.Installed(architecture)) ? 2 : 1;
        }
        // --setup-status <file>: an INI file Setup reads with GetIniString.
        public static int Status(string source, FixtureConfig fixture, string output)
        {
            int webp = WebP(source, fixture);
            StringBuilder text = new StringBuilder();
            text.AppendLine("; Written by BetterIcon-Tray.exe --setup-status for Setup's optional downloads page.");
            text.AppendLine("[WebP]");
            text.AppendLine("Probe=" + webp.ToString(CultureInfo.InvariantCulture));
            text.AppendLine("Offer=" + (webp == 1 ? "1" : "0"));
            text.AppendLine("Architectures=" + String.Join(",", LibWebP.NeededArchitectures));
            text.AppendLine("Bytes=" + LibWebP.DownloadBytes(LibWebP.NeededArchitectures).ToString(CultureInfo.InvariantCulture));
            int result = 0;
            try {
                WorkerReply reply = new WorkerClient(source, fixture).Run(new WorkerRequest { Action = "SetupStatus", Scope = "CurrentUser" }, false).GetAwaiter().GetResult();
                SetupStatus status = reply.SetupStatus ?? new SetupStatus();
                foreach (var list in new[] { new { Name = "AppPacks", Label = "All app icon packs", Packs = status.AppPacks, Bytes = status.AppBytes, Unknown = status.AppUnknown },
                    new { Name = "FilePacks", Label = "All file type icon packs", Packs = status.FilePacks, Bytes = status.FileBytes, Unknown = status.FileUnknown } }) {
                    int count = list.Packs == null ? 0 : list.Packs.Length;
                    text.AppendLine("[" + list.Name + "]");
                    text.AppendLine("Count=" + count.ToString(CultureInfo.InvariantCulture));
                    text.AppendLine("Bytes=" + list.Bytes.ToString(CultureInfo.InvariantCulture));
                    text.AppendLine("Unknown=" + list.Unknown.ToString(CultureInfo.InvariantCulture));
                    // The choice as Setup's page shows it.
                    text.AppendLine("Text=" + PackChoice(list.Label, count, list.Bytes, list.Unknown));
                }
            }
            catch (Exception error) {
                text.AppendLine("[AppPacks]"); text.AppendLine("Count=0");
                text.AppendLine("[FilePacks]"); text.AppendLine("Count=0");
                text.AppendLine("[Error]"); text.AppendLine("Message=" + (error.Message ?? "").Replace("\r", " ").Replace("\n", " "));
                result = 1;
            }
            File.WriteAllText(output, text.ToString(), Encoding.ASCII);
            return result;
        }
        // A pack choice on Setup's page, such as "All app icon packs (27 packs, 317.0 MB)". One pack is a pack, and when the
        // size of some packs is not known, the size shown is a lower bound, or says it is unknown.
        internal static string PackChoice(string label, int count, long bytes, int unknown)
        {
            string packs = count.ToString(CultureInfo.InvariantCulture) + (count == 1 ? " pack" : " packs");
            string size = unknown <= 0 ? LauncherForm.DownloadSize(bytes) : bytes > 0 ? "at least " + LauncherForm.DownloadSize(bytes) : "size unknown";
            return label + " (" + packs + ", " + size + ")";
        }
    }

    public sealed partial class LauncherForm
    {
        string stateDirectory;
        FlowLayoutPanel webpActions, setupActions;
        LinkLabel webpInstall, setupRetry, setupStop, setupDismiss;
        // The packs whose WebP offer the user put off with Not now, for as long as they stay chosen in this session.
        readonly HashSet<string> webpOfferDismissed = new HashSet<string>(StringComparer.Ordinal);
        // Artwork the user chose (an import, Choose icon... or a pack being edited) failed because this PC can't read
        // WebP. The offer stays until WebP support is installed or the user says Not now.
        bool webpOfferForArtwork;
        // Whether each offer is open, whether or not the window shows it now: the tray menu follows these, so it offers
        // them while BetterIcon waits hidden in the tray or shows the Launcher.
        bool webpOffered, setupOffered;
        bool webpInstalling, setupDownloading;
        // WebP support arrived while another operation ran: the packs are read again when it ends (SetBusy), and then the
        // status line shows reloadDoneText, when there is one.
        bool reloadPending;
        string reloadDoneText;
        CancellationTokenSource setupCancel;
        // The background run of Setup's downloads that the start began; tests wait for it.
        Task setupDownloadsTask = Task.FromResult(0);

        // ---- Left-out items and the WebP offer ---------------------------------------------------------------------
        // "Left out: PhotoCraft, .pcraft and 2 more. {cause}" for the items of one list, or null.
        internal static string LeftOutText(ThemeEntry theme, bool files)
        {
            if (theme == null || theme.LeftOut == null) return null;
            return LeftOutText(theme.LeftOut.Where(item => item.IsFile == files).ToArray());
        }
        internal static string LeftOutText(LeftOutItem[] items)
        {
            if (items == null || items.Length == 0) return null;
            string names = String.Join(", ", items.Take(3).Select(item => item.Item));
            if (items.Length > 3) names += " and " + (items.Length - 3).ToString(CultureInfo.InvariantCulture) + " more";
            return "Left out: " + names + ". " + items[0].Reason;
        }
        string PackLoadedText(ThemeEntry theme, bool files)
        {
            string leftOut = LeftOutText(theme, files);
            return theme + " loaded. " + (leftOut == null ? "" : leftOut + " ") + (files ? "Choose Apply file icons to change Windows file types." : "Choose Apply icons to change Windows shortcuts.");
        }
        // After the packs are read again: what the chosen app pack, then the chosen file type pack, leaves out and why.
        string LeftOutStatus() { return LeftOutText(SelectedTheme, false) ?? LeftOutText(SelectedFileTheme, true); }
        // The chosen packs that leave items out because this PC can't read WebP, and that the user has not put off.
        IEnumerable<ThemeEntry> WebPOfferPacks()
        {
            foreach (ThemeEntry theme in new[] { SelectedTheme, SelectedFileTheme }.Distinct()) {
                if (theme == null || theme.LeftOut == null || !theme.LeftOut.Any(item => item.Reason == WebpArtwork.NoDecoder)) continue;
                if (webpOfferDismissed.Contains(theme.Id)) continue;
                yield return theme;
            }
        }
        ThemeEntry WebPOfferPack() { return webpInstalling ? null : WebPOfferPacks().FirstOrDefault(); }
        // Not now lasts while the packs it put off stay chosen: choosing another pack that leaves WebP out offers again.
        void KeepWebPDismissals()
        {
            webpOfferDismissed.RemoveWhere(id => (SelectedTheme == null || SelectedTheme.Id != id) && (SelectedFileTheme == null || SelectedFileTheme.Id != id));
        }
        bool WebPSupportHelps()
        {
            if (WebpArtwork.DecoderAvailable) return false;
            // BetterIcon running as administrator (with UAC turned off) never loads it, so a download would change nothing.
            if (LibWebP.Elevated && LibWebP.CodeRefusal != null) return false;
            LibWebP.PinSet pins = LibWebP.Pins;
            string[] needed = LibWebP.NeededArchitectures;
            return pins != null && needed.Length > 0 && needed.All(architecture => pins.Packages.ContainsKey(architecture));
        }
        internal static string DownloadSize(long bytes)
        {
            if (bytes < 1024 * 1024) return Math.Max(1, (bytes + 512) / 1024).ToString(CultureInfo.InvariantCulture) + " KB";
            return (bytes / 1048576.0).ToString("0.0", CultureInfo.InvariantCulture) + " MB";
        }
        // Artwork the user chose could not be read because this PC has no WebP decoder: offer WebP support right there.
        void NoteWebPFailure(Exception error)
        {
            if (error == null || (error.Message ?? "").IndexOf(WebpArtwork.NoDecoder, StringComparison.Ordinal) < 0) return;
            webpOfferForArtwork = true;
            UpdateWebPOffer();
        }
        // Beside the status line that names the left-out items, and in the tray menu. Never a dialog.
        void UpdateWebPOffer()
        {
            bool offer = !webpInstalling && (WebPOfferPacks().Any() || webpOfferForArtwork) && WebPSupportHelps();
            webpOffered = offer;
            if (offer && webpActions == null && shortcutsSection != null) {
                webpInstall = OfferLink("WebPSupportLink", "", DownloadTexts.WebPActionTip, delegate { var ignored = InstallWebPSupport(false); });
                LinkLabel notNow = OfferLink("WebPSupportNotNow", DownloadTexts.NotNow, DownloadTexts.NotNowTip, delegate {
                    foreach (ThemeEntry pack in WebPOfferPacks().ToList()) webpOfferDismissed.Add(pack.Id);
                    webpOfferForArtwork = false;
                    UpdateWebPOffer();
                });
                webpActions = OfferRow("WebPSupportActions", webpInstall, notNow);
            }
            if (webpInstall != null) {
                webpInstall.Text = String.Format(DownloadTexts.WebPAction, DownloadSize(LibWebP.DownloadBytes(LibWebP.NeededArchitectures)));
                webpInstall.AccessibleName = webpInstall.Text;
                webpInstall.Enabled = !busy && !webpInstalling;
            }
            // Set every time: Visible reads false while the window is hidden, and an offer that ended then must not come back.
            if (webpActions != null) webpActions.Visible = offer;
            RebuildTrayMenu();
        }
        LinkLabel OfferLink(string name, string text, string tip, LinkLabelLinkClickedEventHandler click)
        {
            LinkLabel link = new LinkLabel { Name = name, Text = text, AutoSize = true, UseMnemonic = false, LinkBehavior = LinkBehavior.HoverUnderline,
                Margin = new Padding(0, 0, 18, 0), AccessibleName = text, AccessibleDescription = tip };
            appearanceTips.SetToolTip(link, tip);
            link.LinkClicked += click;
            return link;
        }
        // Joins the shortcuts section under the status line the first time it is needed, with the window's colors.
        FlowLayoutPanel OfferRow(string name, params Control[] controls)
        {
            FlowLayoutPanel row = new FlowLayoutPanel { Name = name, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, WrapContents = true,
                Dock = DockStyle.Top, Visible = false, Margin = new Padding(4, 4, 4, 0), Padding = Padding.Empty };
            row.Controls.AddRange(controls);
            shortcutsSection.SuspendLayout();
            try { SettingsRow(shortcutsSection, row); }
            finally { shortcutsSection.ResumeLayout(true); }
            if (appearancePalette != null) AppAppearance.Apply(row, appearancePalette);
            return row;
        }
        // From the offers' own state, also while the window is hidden or shows the Launcher.
        void AddDownloadItems()
        {
            if (webpOffered) {
                ToolStripMenuItem item = new ToolStripMenuItem(DownloadTexts.WebPMenu) { Name = "WebPSupportItem", Enabled = !busy && !webpInstalling, ToolTipText = DownloadTexts.WebPActionTip };
                item.Click += async delegate { ShowSettings(); await InstallWebPSupport(false); };
                trayMenu.Items.Add(item);
            }
            if (setupOffered) {
                ToolStripMenuItem item = new ToolStripMenuItem(DownloadTexts.SetupMenu) { Name = "SetupDownloadsItem", Enabled = !setupDownloading, ToolTipText = DownloadTexts.SetupRetryTip };
                item.Click += async delegate { ShowSettings(); await ProcessSetupDownloads(true); };
                trayMenu.Items.Add(item);
            }
        }
        async Task InstallNeededWebPSupport(CancellationToken token)
        {
            string[] needed = LibWebP.NeededArchitectures.Where(architecture => !LibWebP.Installed(architecture)).ToArray();
            await Task.Run(delegate { foreach (string architecture in needed) { token.ThrowIfCancellationRequested(); LibWebP.InstallFromRelease(architecture, token); } }, token);
        }
        // Downloads and checks the pinned libwebp build of each architecture this PC's BetterIcon runs, then reads the
        // packs again: the left-out WebP items load and apply at once, in this process and in every new worker.
        async Task InstallWebPSupport(bool quiet)
        {
            if (webpInstalling || busy || IsDisposed || Disposing) return;
            webpInstalling = true;
            UpdateWebPOffer();
            if (!quiet) status.Text = DownloadTexts.WebPBusy;
            bool installed = false;
            try {
                await InstallNeededWebPSupport(CancellationToken.None);
                installed = LibWebP.Available;
                if (!installed) throw new IOException(LibWebP.LastProblem ?? LibWebP.NotInstalled);
                TraceFixture("WebP support installed");
            }
            catch (Exception error) {
                TraceFixture("WebP support failed: " + error.Message);
                if (!IsDisposed && !Disposing) status.Text = String.Format(DownloadTexts.WebPFailed, error.Message);
            }
            finally { webpInstalling = false; }
            if (IsDisposed || Disposing) return;
            if (installed) {
                webpOfferForArtwork = false;
                await ReloadForWebP(DownloadTexts.WebPDone, DownloadTexts.WebPWaiting);
                if (IsDisposed || Disposing) return;
            }
            UpdateWebPOffer();
        }
        // WebP support arrived: the left-out WebP items load once the packs are read again. While another operation runs,
        // that waits until it ends (SetBusy), and the status line says so meanwhile. Done is shown after the reading.
        async Task ReloadForWebP(string done, string waiting)
        {
            if (busy) {
                reloadPending = true; reloadDoneText = done;
                if (waiting != null) status.Text = waiting;
                return;
            }
            if (await ReadCatalog(false) && done != null && !IsDisposed && !Disposing) status.Text = done;
        }
        async Task ReloadWhenIdle()
        {
            if (!reloadPending || busy || IsDisposed || Disposing) return;
            string done = reloadDoneText;
            reloadPending = false; reloadDoneText = null;
            if (await ReadCatalog(false) && done != null && !IsDisposed && !Disposing) status.Text = done;
            TraceFixture("Packs read again after WebP support arrived");
        }

        // ---- Setup's optional downloads ----------------------------------------------------------------------------
        // At start, and when Setup signals again: a request Setup just handed over runs at once. One that failed before
        // is offered, with Download them and Not now.
        async Task StartSetupDownloads()
        {
            if (catalog == null || setupDownloading || IsDisposed || Disposing) return;
            SetupDownloadRequest request = stateDirectory == null ? null : SetupDownloadRequest.Read(stateDirectory);
            if (request == null || !request.Any) return;
            if (request.Attempts == 0) await ProcessSetupDownloads(false);
            else ShowSetupOffer(request, null);
        }
        void EnsureSetupActions()
        {
            if (setupActions != null || shortcutsSection == null) return;
            setupStop = OfferLink("SetupDownloadsStop", DownloadTexts.SetupStop, DownloadTexts.SetupStopTip, delegate { if (setupCancel != null) setupCancel.Cancel(); });
            setupRetry = OfferLink("SetupDownloadsRetry", DownloadTexts.SetupRetry, DownloadTexts.SetupRetryTip, async delegate { await ProcessSetupDownloads(true); });
            setupDismiss = OfferLink("SetupDownloadsNotNow", DownloadTexts.NotNow, DownloadTexts.SetupDismissTip, delegate {
                SetupDownloadRequest request = SetupDownloadRequest.Read(stateDirectory) ?? new SetupDownloadRequest();
                request.WebP = request.AppPacks = request.FilePacks = false;
                try { request.Write(stateDirectory); } catch (IOException) { } catch (UnauthorizedAccessException) { }
                setupOffered = false; setupActions.Visible = false; RebuildTrayMenu();
            });
            setupActions = OfferRow("SetupDownloadActions", setupStop, setupRetry, setupDismiss);
        }
        void ShowSetupOffer(SetupDownloadRequest request, string text)
        {
            EnsureSetupActions();
            setupOffered = true;
            if (setupActions != null) {
                setupStop.Visible = false; setupRetry.Visible = setupDismiss.Visible = true;
                setupRetry.Text = setupRetry.AccessibleName = request.AppPacks || request.FilePacks ? DownloadTexts.SetupRetry : DownloadTexts.SetupRetryWebP;
                setupActions.Visible = true;
            }
            if (text != null) status.Text = text;
            else if (!busy && !String.IsNullOrEmpty(request.Failure)) status.Text = request.Failure;
            // A failure while the window is hidden, after a silent install or at login, is told once in a balloon, as for
            // shared shortcuts. So is one while the window shows the Launcher, as when Setup opens it: the status line and the
            // offer are in Manage Icons. The balloon's click opens Manage Icons, where the offer and the reason are.
            bool unseen = !Visible || (pages != null && pages.SelectedTab != settingsPage);
            if (unseen && !String.IsNullOrEmpty(request.Failure) && !request.Announced) {
                request.Announced = true;
                try { request.Write(stateDirectory); } catch (IOException) { } catch (UnauthorizedAccessException) { }
                if (fixtureLog == null) tray.ShowBalloonTip(6000, "BetterIcon", request.Failure, ToolTipIcon.Warning);
                else TraceFixture("Setup downloads balloon");
            }
            RebuildTrayMenu();
        }
        // Packs of the lists Setup named that are not on this computer yet, each once.
        List<string> SetupPackIds(SetupDownloadRequest request)
        {
            var ids = new List<string>();
            if (catalog == null) return ids;
            if (request.AppPacks) ids.AddRange(themes.Items.OfType<ThemeEntry>().Where(theme => !theme.IsDefault && !theme.Managed && theme.NeedsDownload).Select(theme => theme.Id));
            if (request.FilePacks) ids.AddRange(fileThemes.Items.OfType<ThemeEntry>().Where(theme => !theme.Managed && theme.NeedsDownload).Select(theme => theme.Id));
            return ids.Distinct().ToList();
        }
        ThemeEntry CurrentPack(string id)
        {
            return themes.Items.OfType<ThemeEntry>().Concat(fileThemes.Items.OfType<ThemeEntry>()).FirstOrDefault(theme => theme.Id == id);
        }
        async Task ProcessSetupDownloads(bool manual)
        {
            if (setupDownloading || stateDirectory == null || IsDisposed || Disposing) return;
            SetupDownloadRequest request = SetupDownloadRequest.Read(stateDirectory);
            if (request == null || !request.Any) { setupOffered = false; if (setupActions != null) setupActions.Visible = false; RebuildTrayMenu(); return; }
            setupDownloading = true; setupOffered = false;
            setupCancel = new CancellationTokenSource();
            request.Attempts++; request.Failure = null; request.Announced = false;
            try { request.Write(stateDirectory); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            EnsureSetupActions();
            if (setupActions != null) { setupStop.Visible = true; setupRetry.Visible = setupDismiss.Visible = false; setupActions.Visible = true; }
            RebuildTrayMenu();
            int done = 0, failed = 0, total = 0; string failure = null; bool webp = false, stopped = false;
            try {
                if (request.WebP) {
                    if (!WebPSupportHelps() || LibWebP.NeededArchitectures.All(architecture => LibWebP.Installed(architecture))) request.WebP = false;
                    else {
                        if (!busy) status.Text = DownloadTexts.SetupWebP;
                        try {
                            await InstallNeededWebPSupport(setupCancel.Token);
                            if (!LibWebP.Available) throw new IOException(LibWebP.LastProblem ?? LibWebP.NotInstalled);
                            request.WebP = false; webp = true;
                            TraceFixture("Setup downloads: WebP support installed");
                        }
                        catch (OperationCanceledException) { throw; }
                        catch (Exception error) { failure = String.Format(DownloadTexts.SetupWebPFailed, error.Message); TraceFixture("Setup downloads: WebP support failed: " + error.Message); }
                    }
                }
                List<string> ids = SetupPackIds(request);
                total = ids.Count;
                foreach (string id in ids) {
                    setupCancel.Token.ThrowIfCancellationRequested();
                    ThemeEntry pack = CurrentPack(id);
                    if (pack == null || !pack.NeedsDownload) { done++; continue; }
                    if (!busy) status.Text = String.Format(DownloadTexts.SetupPacks, done + failed + 1, total, pack.DisplayName);
                    try {
                        await PackSweepEnded();
                        WorkerReply reply = await worker.Run(new WorkerRequest { Action = "DownloadPack", Theme = id }, false);
                        if (IsDisposed || Disposing) return;
                        ThemeEntry current = CurrentPack(id) ?? pack;
                        if (reply.DownloadedIcons != null && reply.DownloadedFileIcons != null) {
                            current.Icons = reply.DownloadedIcons; current.IconCount = current.Icons.Length;
                            current.FileIcons = reply.DownloadedFileIcons; current.AppFileIcons = reply.DownloadedAppFileIcons ?? new Dictionary<string, string>();
                            current.UnlistedFileIconApps = reply.DownloadedUnlistedFileIconApps ?? new string[0];
                            current.LeftOut = reply.DownloadedLeftOut ?? new LeftOutItem[0];
                            current.NeedsDownload = false; current.UpdateAvailable = false; current.Downloaded = true;
                        }
                        done++;
                        themes.RefreshLabels(); fileThemes.RefreshLabels();
                    }
                    catch (Exception error) { failed++; if (failure == null) failure = error.Message; TraceFixture("Setup downloads: " + id + " failed: " + error.Message); }
                }
                if (failed == 0) request.AppPacks = request.FilePacks = false;
            }
            catch (OperationCanceledException) { stopped = true; }
            finally { setupDownloading = false; }
            if (IsDisposed || Disposing) return;
            string text;
            int remaining = SetupPackIds(request).Count;
            if (stopped) text = String.Format(DownloadTexts.SetupStopped, remaining + (request.WebP ? 1 : 0));
            else if (request.WebP && failed == 0) text = failure;
            else if (failed > 0) text = String.Format(DownloadTexts.SetupPacksFailed, failed, failure ?? "");
            else if (done > 0) text = (webp ? DownloadTexts.SetupWebPDone + " " : "") + (done == 1 ? DownloadTexts.SetupDoneOne : String.Format(DownloadTexts.SetupDone, done));
            else text = webp ? DownloadTexts.SetupWebPDone : DownloadTexts.SetupNothing;
            request.Failure = request.Any ? text : null;
            try { request.Write(stateDirectory); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            // While another operation runs, the packs are read again when it ends, and the result is shown then.
            if (webp) await ReloadForWebP(busy ? text : null, null);
            if (IsDisposed || Disposing) return;
            BuildTrayMenu();
            if (request.Any) ShowSetupOffer(request, text);
            else {
                setupOffered = false;
                if (setupActions != null) setupActions.Visible = false;
                if (!busy) status.Text = text;
                RebuildTrayMenu();
            }
            UpdateWebPOffer();
            // Last: the packs are read again and the status line shows the result.
            TraceFixture("Setup downloads finished: " + text);
        }
    }
}
