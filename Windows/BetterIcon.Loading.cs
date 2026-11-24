using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace BetterIcon.Tray
{
    // A native combo changes its selected index while browsing, including on arrow keys.
    // Only activating a list row or confirming it with Enter may initiate a download.
    sealed class PackPicker : AppearanceComboBox
    {
        [StructLayout(LayoutKind.Sequential)]
        struct Rect { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)]
        struct ComboInfo { public int Size; public Rect Item, Button; public int ButtonState; public IntPtr Combo, Edit, List; }
        [StructLayout(LayoutKind.Sequential)]
        struct MouseTracking { public int Size, Flags; public IntPtr Window; public int HoverTime; }
        [DllImport("user32.dll")] static extern bool GetComboBoxInfo(IntPtr combo, ref ComboInfo info);
        [DllImport("user32.dll")] static extern bool TrackMouseEvent(ref MouseTracking tracking);
        [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr window, ref Point point);
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll", EntryPoint = "SendMessageW")] static extern IntPtr GetItemRect(IntPtr hwnd, int msg, IntPtr index, ref Rect rect);
        readonly Rows rows;
        PackHoverPreview hover;
        bool browsing, updating;
        object accepted;
        public event EventHandler PackChosen;
        public PackPicker() { rows = new Rows(this); }
        public void EnablePreviews(PackPreviewStore store, bool fileList = false) { hover = new PackHoverPreview(store, this, fileList); }
        sealed class Rows : NativeWindow
        {
            readonly PackPicker picker;
            IntPtr? pointer;
            public Rows(PackPicker owner) { picker = owner; }
            object Hit(IntPtr point, out Rectangle screen)
            {
                screen = Rectangle.Empty;
                int xy = unchecked((int)point.ToInt64()), x = (short)xy, y = (short)(xy >> 16);
                int hit = SendMessage(Handle, 0x01A9, IntPtr.Zero, point).ToInt32(); // LB_ITEMFROMPOINT
                int index = hit & 0xffff;
                var rect = new Rect();
                if ((hit >> 16) != 0 || index >= picker.Items.Count || GetItemRect(Handle, 0x0198, (IntPtr)index, ref rect).ToInt64() == -1 ||
                    x < rect.Left || x >= rect.Right || y < rect.Top || y >= rect.Bottom) return null;
                var top = new Point(rect.Left, rect.Top);
                if (!ClientToScreen(Handle, ref top)) return null;
                screen = new Rectangle(top.X, top.Y, rect.Right - rect.Left, rect.Bottom - rect.Top);
                return picker.Items[index];
            }
            public void ResetHover()
            {
                pointer = null;
                if (picker.hover != null) picker.hover.Clear();
            }
            public void RefreshHover()
            {
                if (!pointer.HasValue || !picker.browsing || picker.hover == null) return;
                Rectangle bounds;
                var theme = Hit(pointer.Value, out bounds) as ThemeEntry;
                picker.hover.Hover(theme, bounds);
            }
            protected override void WndProc(ref Message m)
            {
                object clicked = null;
                Rectangle bounds;
                if (m.Msg == 0x0202 && picker.browsing) clicked = Hit(m.LParam, out bounds);
                base.WndProc(ref m);
                if (clicked != null && !picker.IsDisposed) picker.ChooseItem(clicked);
                if (!picker.browsing || picker.hover == null) return;
                switch (m.Msg) {
                    case 0x0200: // WM_MOUSEMOVE
                        if (!pointer.HasValue) {
                            var track = new MouseTracking { Size = Marshal.SizeOf(typeof(MouseTracking)), Flags = 2, Window = Handle };
                            TrackMouseEvent(ref track);
                        }
                        pointer = m.LParam; RefreshHover(); break;
                    case 0x02A3: case 0x00A0: // WM_MOUSELEAVE, WM_NCMOUSEMOVE (scrollbar)
                        ResetHover(); break;
                    case 0x0115: case 0x020A: case 0x0197: // WM_VSCROLL, WM_MOUSEWHEEL, LB_SETTOPINDEX
                        RefreshHover(); break;
                }
            }
        }
        protected override void OnDropDown(EventArgs e)
        {
            browsing = true;
            // Two pickers share the row, so let the list grow to show each full pack name.
            int widest = Width;
            foreach (object item in Items) widest = Math.Max(widest, TextRenderer.MeasureText(item.ToString(), Font).Width + SystemInformation.VerticalScrollBarWidth + 12);
            if (DropDownWidth != widest) DropDownWidth = widest;
            var info = new ComboInfo { Size = Marshal.SizeOf(typeof(ComboInfo)) };
            if (GetComboBoxInfo(Handle, ref info) && info.List != rows.Handle) {
                if (rows.Handle != IntPtr.Zero) rows.ReleaseHandle();
                if (info.List != IntPtr.Zero) rows.AssignHandle(info.List);
            }
            base.OnDropDown(e);
        }
        protected override void OnDropDownClosed(EventArgs e)
        {
            browsing = false;
            rows.ResetHover();
            if (!updating) SetSilently(accepted);
            base.OnDropDownClosed(e);
        }
        void SetSilently(object item)
        {
            updating = true;
            try { SelectedItem = item; } finally { updating = false; }
        }
        public void ChooseItem(object item)
        {
            if (!Enabled || item == null || !Items.Contains(item)) return;
            bool changed = !Object.Equals(accepted, item);
            var pack = item as ThemeEntry;
            accepted = item;
            if (DroppedDown) DroppedDown = false;
            SetSilently(item);
            if (changed || (pack != null && pack.UpdateAvailable)) NotifyChoice();
        }
        protected override void OnSelectedIndexChanged(EventArgs e)
        {
            base.OnSelectedIndexChanged(e);
            if (browsing || updating) return;
            var pack = SelectedItem as ThemeEntry;
            if (pack != null && pack.NeedsDownload) { SetSilently(accepted); return; }
            if (Object.Equals(accepted, SelectedItem)) return;
            accepted = SelectedItem;
            // Restoring an installed pack can reveal an update. Only an explicit
            // row click, Enter or tray selection should start that update.
            if (pack == null || !pack.UpdateAvailable) NotifyChoice();
        }
        void NotifyChoice() { var chosen = PackChosen; if (chosen != null) chosen(this, EventArgs.Empty); }
        void ConfirmRow()
        {
            int index = rows.Handle == IntPtr.Zero ? -1 : SendMessage(rows.Handle, 0x0188, IntPtr.Zero, IntPtr.Zero).ToInt32(); // LB_GETCURSEL
            if (index >= 0 && index < Items.Count) ChooseItem(Items[index]);
        }
        protected override bool ProcessCmdKey(ref Message msg, Keys key)
        {
            if (browsing && key == Keys.Enter) { ConfirmRow(); return true; }
            if (!DroppedDown && (key == Keys.Up || key == Keys.Down || key == Keys.Home || key == Keys.End || key == Keys.PageUp || key == Keys.PageDown)) DroppedDown = true;
            return base.ProcessCmdKey(ref msg, key);
        }
        protected override void WndProc(ref Message m)
        {
            if (browsing && m.Msg == 0x0100 && m.WParam.ToInt32() == (int)Keys.Enter) { ConfirmRow(); return; }
            base.WndProc(ref m);
            if (browsing && (m.Msg == 0x020A || m.Msg == 0x0100 || m.Msg == 0x0115)) rows.RefreshHover();
        }
        public void RefreshLabels()
        {
            object selected = SelectedItem;
            updating = true;
            try { RefreshItems(); SelectedItem = selected; } finally { updating = false; }
            Invalidate();
        }
        protected override void OnHandleDestroyed(EventArgs e)
        {
            if (rows != null) rows.ResetHover();
            if (rows != null && rows.Handle != IntPtr.Zero) rows.ReleaseHandle();
            base.OnHandleDestroyed(e);
        }
        protected override void Dispose(bool disposing)
        {
            if (disposing && hover != null) { hover.Dispose(); hover = null; }
            base.Dispose(disposing);
        }
    }

    public sealed partial class LauncherForm
    {
        readonly TableLayoutPanel loadingPanel = new TableLayoutPanel();
        readonly Label loadingMessage = new Label();
        readonly ProgressBar loadingProgress = new ThemedProgressBar();
        Task packLoadTask = Task.FromResult(0);
        ThemeEntry loadingTheme;
        object loadingFileTheme;
        string renderedThemeId, renderedFileThemeId;
        // The chosen app pack while it is not on the computer. The list shows another pack until it is downloaded again.
        string wantedThemeId;

        void BuildLoadingIndicator()
        {
            ConfigureIndicator(loadingPanel, loadingMessage, loadingProgress);
            Controls.Add(loadingPanel);
        }
        static void ConfigureIndicator(TableLayoutPanel panel, Label label, ProgressBar bar)
        {
            panel.Name = "LoadingIndicator"; panel.Dock = DockStyle.Bottom;
            panel.Height = 52; panel.Padding = new Padding(16, 6, 16, 8);
            panel.ColumnCount = 1; panel.RowCount = 2;
            panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 24));
            panel.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            label.Dock = DockStyle.Fill; label.Margin = Padding.Empty;
            label.AutoEllipsis = true; label.TextAlign = ContentAlignment.MiddleLeft;
            bar.Dock = DockStyle.Fill; bar.Margin = Padding.Empty;
            bar.Style = ProgressBarStyle.Marquee; bar.MarqueeAnimationSpeed = 0;
            panel.Controls.Add(label, 0, 0); panel.Controls.Add(bar, 0, 1);
            panel.Visible = false;
        }
        static void UpdateIndicator(TableLayoutPanel panel, Label label, ProgressBar bar, bool visible, string message)
        {
            if (!String.IsNullOrEmpty(message)) label.Text = label.AccessibleName = bar.AccessibleName = message;
            bar.MarqueeAnimationSpeed = visible ? 30 : 0;
            panel.Visible = visible;
            if (visible) panel.Update();
        }
        void ShowLoading(bool value, string message)
        {
            UpdateIndicator(loadingPanel, loadingMessage, loadingProgress, value, message);
        }
        static string PackActivity(ThemeEntry theme)
        {
            if (theme == null) return "Loading original file icons...";
            return (theme.HasDownload ? "Downloading " : "Loading ") + theme.DisplayName + "...";
        }
        void SelectPack()
        {
            if (fillingThemes) return;
            if (busy) {
                fillingThemes = true;
                try { themes.SelectedItem = loadingTheme ?? (catalog == null ? null : catalog.Themes.FirstOrDefault(theme => theme.Id == renderedThemeId)); }
                finally { fillingThemes = false; }
                return;
            }
            packLoadTask = LoadSelectedPack();
        }

        sealed class ArtworkRequest
        {
            public string Path, Name, Tooltip;
            public int Index;
            public object Tag;
        }
        sealed class PreparedArtwork : IDisposable
        {
            public readonly List<ArtworkRequest> Items;
            public readonly List<Bitmap> Images = new List<Bitmap>();
            public readonly List<ArtworkSource> Sources = new List<ArtworkSource>();
            public PreparedArtwork(List<ArtworkRequest> requests) { Items = requests; }
            public void Dispose() { foreach (Bitmap image in Images) image.Dispose(); }
        }
        // Decode off the window thread so painting and the progress animation continue.
        static PreparedArtwork Prepare(List<ArtworkRequest> requests, int size, Icon fallback)
        {
            PreparedArtwork result = new PreparedArtwork(requests);
            try {
                int cacheSize = 128; while (cacheSize < size) cacheSize *= 2;
                foreach (ArtworkRequest request in requests) {
                    ArtworkSource source = DescribeArtwork(request.Path, request.Index);
                    result.Sources.Add(source); result.Images.Add(Thumbnail(source.Path, fallback, Math.Min(cacheSize, source.MaximumSize), source.Index));
                }
                return result;
            }
            catch { result.Dispose(); throw; }
        }
        static List<ArtworkRequest> PackRequests(ThemeEntry theme, AppEntry[] installed)
        {
            List<ArtworkRequest> result = new List<ArtworkRequest>();
            if (theme.IsDefault) foreach (AppEntry app in installed.GroupBy(app => app.Application).Select(group => group.First()).OrderBy(app => !AppOrder.Leads(app.Application)).ThenBy(app => app.Application))
                result.Add(new ArtworkRequest { Path = app.OriginalIconPath, Index = app.OriginalIconIndex, Name = app.Application, Tooltip = app.Application + " - ArtCraft default", Tag = app.Application });
            else foreach (ThemeIcon art in theme.Icons.OrderBy(icon => !AppOrder.Leads(icon.Application)).ThenBy(icon => icon.Application))
                result.Add(new ArtworkRequest { Path = PreviewPath(art), Name = art.Application, Tooltip = art.Application, Tag = art.Application });
            return result;
        }
        static List<ArtworkRequest> FileRequests(ThemeEntry theme)
        {
            return ProjectFormat.Artwork(theme).Tiles().Select(tile => new ArtworkRequest { Path = tile.Path, Name = tile.Name, Tooltip = tile.Tooltip }).ToList();
        }
        static void Display(IconGridView grid, List<Bitmap> artwork, List<ArtworkSource> sources, PreparedArtwork prepared)
        {
            foreach (Bitmap image in artwork) image.Dispose();
            artwork.Clear(); sources.Clear(); grid.Items.Clear();
            artwork.AddRange(prepared.Images); sources.AddRange(prepared.Sources); prepared.Images.Clear();
            for (int i = 0; i < prepared.Items.Count; i++) {
                ArtworkRequest request = prepared.Items[i];
                grid.Items.Add(new ListViewItem(request.Name, i) { Tag = request.Tag, ToolTipText = request.Tooltip });
            }
        }
        static string PackDetails(ThemeEntry theme)
        {
            return theme == null ? "No packs. Import or create one." : theme.IsDefault ? "Original icons for your installed apps." : theme.IconCount + " icons / " + (theme.Managed ? "Personal pack" : "Built-in pack");
        }
        static string FilePackDetails(ThemeEntry theme)
        {
            if (theme == null) return "Original file icons from your installed apps.";
            int count = ProjectFormat.Artwork(theme).Expanded().Count;
            return count + (count == 1 ? " file type / " : " file types / ") + (theme.Managed ? "Personal pack" : "Built-in pack");
        }
        // loadingFiles says which grid the caller draws next from the download: the file type grid (true) or the app pack
        // grid (false). Left out, the caller draws everything again.
        async Task DownloadTheme(ThemeEntry theme, bool? loadingFiles = null)
        {
            await PackSweepEnded();
            bool update = theme.UpdateAvailable;
            var reply = await worker.Run(new WorkerRequest { Action = "DownloadPack", Theme = theme.Id }, false);
            if (reply.DownloadedIcons == null || reply.DownloadedFileIcons == null) throw new IOException("Incomplete downloaded icon pack.");
            theme.Icons = reply.DownloadedIcons;
            theme.IconCount = theme.Icons.Length; theme.FileIcons = reply.DownloadedFileIcons;
            theme.AppFileIcons = reply.DownloadedAppFileIcons ?? new Dictionary<string, string>();
            // The download, an update or not, now answers as the catalog does.
            theme.UnlistedFileIconApps = reply.DownloadedUnlistedFileIconApps ?? new string[0];
            theme.LeftOut = reply.DownloadedLeftOut ?? new LeftOutItem[0];
            theme.NeedsDownload = false; theme.UpdateAvailable = false; theme.Downloaded = true;
            themes.RefreshLabels(); fileThemes.RefreshLabels(); BuildTrayMenu();
            // An update removes the copy the pack was drawn from. What else shows this pack is drawn again from the new
            // copy, before a larger icon size reads a file that is gone: the Launcher when this is the applied pack, and
            // the other list's grid when the pack is chosen there too.
            if (!update || loadingFiles == null || IsDisposed || Disposing) return;
            ThemeEntry applied = AppliedTheme();
            if (applied != null && applied.Id == theme.Id) RenderApps();
            if (loadingFiles.Value) { if (SelectedTheme == theme && renderedThemeId == theme.Id) RenderPack(); }
            else if (SelectedFileTheme == theme && renderedFileThemeId == theme.Id) RenderFilePack();
        }
        // Choosing a pack previews it in Manage Icons. The Launcher changes when it is applied.
        async Task LoadSelectedPack()
        {
            ThemeEntry selected = SelectedTheme;
            if (selected == null || catalog == null) return;
            string previous = renderedThemeId ?? preferences.Theme;
            AppEntry[] installed = catalog.Apps.ToArray();
            int size = preferences.IconSize;
            loadingTheme = selected; SetBusy(true, PackActivity(selected));
            PreparedArtwork prepared = null;
            try {
                // Show feedback immediately, then keep file I/O and decoding off the
                // window thread so painting and the progress animation can continue.
                await Task.Yield();
                if (selected.HasDownload) {
                    await DownloadTheme(selected, false);
                    if (IsDisposed || Disposing) return;
                    status.Text = PackActivity(selected);
                    ShowLoading(true, status.Text);
                }
                using (Icon fallback = (Icon)Icon.Clone())
                    prepared = await Task.Run(() => Prepare(PackRequests(selected, installed), size, fallback));
                if (IsDisposed || Disposing) return;
                packPreview.BeginUpdate();
                try {
                    Display(packPreview, packArtwork, packSources, prepared);
                    packDetails.Text = PackDetails(selected);
                    UpdateIconSizeLimit(); ResizeAppIcons(); ResizePackIcons(); ResizeFileIcons(); UpdatePackButtons();
                    renderedThemeId = selected.Id;
                }
                finally { packPreview.EndUpdate(); }
                // Choosing a pack replaces an earlier choice that was still waiting to be downloaded.
                wantedThemeId = null;
                SavePreferences(); BuildTrayMenu();
                // Items left out of the pack, with their cause, and the offer of WebP support when that would fix it.
                status.Text = selected.IsDefault ? "ArtCraft default preview loaded." : PackLoadedText(selected, false);
                KeepWebPDismissals(); UpdateWebPOffer();
            }
            catch (Exception error) {
                if (!IsDisposed && !Disposing) {
                    fillingThemes = true;
                    try { themes.SelectedItem = catalog.Themes.FirstOrDefault(theme => theme.Id == previous); }
                    finally { fillingThemes = false; }
                    ShowLoading(false, null); Report(error);
                }
            }
            finally {
                if (prepared != null) prepared.Dispose();
                loadingTheme = null;
                if (!IsDisposed && !Disposing) SetBusy(false, null);
            }
        }
        // After an upgrade from a build that carried every pack, the chosen packs are still saved but are no
        // longer on the computer. Download them once, so the app opens as it was left. A failure is not
        // reported in a dialog: the choices stay saved, and the next start or pack refresh tries again.
        async Task RestoreChosenPacks()
        {
            if (busy || catalog == null || IsDisposed || Disposing) return;
            var wanted = new List<ThemeEntry>();
            ThemeEntry app = wantedThemeId == null ? null : catalog.Themes.FirstOrDefault(theme => theme.Id == wantedThemeId && theme.NeedsDownload);
            if (app != null) wanted.Add(app);
            string fileId = preferences.FileTheme;
            ThemeEntry file = fileId == null ? null : fileThemes.Items.OfType<ThemeEntry>().FirstOrDefault(theme => theme.Id == fileId && theme.NeedsDownload);
            if (file != null && !wanted.Contains(file)) wanted.Add(file);
            if (wanted.Count == 0) return;
            bool failed = false;
            SetBusy(true, PackActivity(wanted[0]));
            try {
                foreach (ThemeEntry pack in wanted) {
                    status.Text = PackActivity(pack); ShowLoading(true, status.Text);
                    try { await DownloadTheme(pack); }
                    catch (Exception) { failed = true; }
                    if (IsDisposed || Disposing) return;
                }
                ReloadPacks(wantedThemeId, fileId);
                status.Text = failed ? "Couldn't download your chosen icon pack. BetterIcon will try again the next time it starts."
                    : LeftOutStatus() ?? ReviewedText;
            }
            finally {
                if (!IsDisposed && !Disposing) SetBusy(false, null);
            }
        }
        // Once per start, some time after the packs are read: the worker removes the copies of downloaded packs that an
        // update left on disk before BetterIcon removed them itself. That runs in the worker's own process. It is not asked
        // for while a pack loads or downloads, an Apply runs or the packs are read: the timer then asks again.
        System.Windows.Forms.Timer packSweepTimer;
        int packSweeps;
        void StartPackSweep()
        {
            if (packSweepTimer != null || packSweeps > 0 || IsDisposed || Disposing) return;
            // Fixture suites see no background work unless they ask for it.
            if (fixtureSettings != null && !fixtureSettings.PackSweepDelay.HasValue) return;
            packSweepTimer = new System.Windows.Forms.Timer { Interval = Math.Max(1, fixtureSettings == null ? 30000 : fixtureSettings.PackSweepDelay.Value) };
            packSweepTimer.Tick += async delegate { await SweepPacks(); };
            packSweepTimer.Start();
        }
        async Task SweepPacks()
        {
            if (packSweepTimer == null || busy || setupDownloading || IsDisposed || Disposing) return;
            // Once: the timer ends before the worker is asked, whatever its answer.
            packSweepTimer.Stop(); packSweepTimer.Dispose(); packSweepTimer = null;
            packSweeps++;
            try {
                Task<WorkerReply> asked = worker.Run(new WorkerRequest { Action = "RemoveSupersededPacks" }, false);
                packSweep = asked;
                WorkerReply reply;
                try { reply = await asked; } finally { packSweep = null; }
                if (IsDisposed || Disposing || reply.RemovedPackCopies == 0 || stateDirectory == null) return;
                // The Launcher may show artwork recorded at an Apply that was in a copy now removed. It is drawn again from
                // the pack as it is now, before a larger icon size reads a file that is gone.
                string downloads = Path.Combine(stateDirectory, "downloads") + Path.DirectorySeparatorChar;
                if (appSources.Any(source => !String.IsNullOrEmpty(source.Path) && source.Path.StartsWith(downloads, StringComparison.OrdinalIgnoreCase) && !File.Exists(source.Path))) RenderApps();
            }
            // A failure changes nothing for the user: every pack stays as it was, and the next start asks again.
            catch (Exception error) { System.Diagnostics.Trace.WriteLine("BetterIcon pack sweep: " + error.Message); }
        }
        // The removal's request to the worker, while that worker runs.
        Task packSweep;
        // A download asks its worker only once the removal's worker has ended. That worker goes by the copies it finds
        // when it starts: a download beside it would make its new copy look like one more earlier copy. The worker also
        // never removes the copy a pack's receipt names, which covers another BetterIcon process.
        async Task PackSweepEnded()
        {
            Task running = packSweep;
            if (running == null) return;
            try { await running; } catch (Exception error) { System.Diagnostics.Trace.WriteLine("BetterIcon pack sweep: " + error.Message); }
        }
        object FilePackRow(string id)
        {
            object row = id == null ? null : fileThemes.Items.OfType<ThemeEntry>().FirstOrDefault(theme => theme.Id == id);
            return row ?? (fileThemes.Items.Count == 0 ? null : fileThemes.Items[0]);
        }
        void SelectFilePack()
        {
            if (fillingFileThemes) return;
            if (busy) {
                fillingFileThemes = true;
                try { fileThemes.SelectedItem = loadingFileTheme ?? FilePackRow(renderedFileThemeId); }
                finally { fillingFileThemes = false; }
                return;
            }
            packLoadTask = LoadSelectedFilePack();
        }
        async Task LoadSelectedFilePack()
        {
            if (catalog == null) return;
            ThemeEntry selected = SelectedFileTheme;
            string previous = renderedFileThemeId;
            int size = preferences.IconSize;
            loadingFileTheme = fileThemes.SelectedItem; SetBusy(true, PackActivity(selected));
            PreparedArtwork prepared = null;
            try {
                await Task.Yield();
                if (selected != null && selected.HasDownload) {
                    await DownloadTheme(selected, true);
                    if (IsDisposed || Disposing) return;
                    status.Text = PackActivity(selected);
                    ShowLoading(true, status.Text);
                }
                using (Icon fallback = (Icon)Icon.Clone())
                    prepared = await Task.Run(() => Prepare(FileRequests(selected), size, fallback));
                if (IsDisposed || Disposing) return;
                DisplayFilePack(selected, prepared);
                renderedFileThemeId = selected == null ? null : selected.Id;
                preferences.FileTheme = renderedFileThemeId;
                SavePreferences();
                status.Text = selected == null ? "Original file icons selected. Choose Restore file icons to undo BetterIcon changes." : PackLoadedText(selected, true);
                KeepWebPDismissals(); UpdateWebPOffer();
            }
            catch (Exception error) {
                if (!IsDisposed && !Disposing) {
                    fillingFileThemes = true;
                    try { fileThemes.SelectedItem = FilePackRow(previous); }
                    finally { fillingFileThemes = false; }
                    ShowLoading(false, null); Report(error);
                }
            }
            finally {
                if (prepared != null) prepared.Dispose();
                loadingFileTheme = null;
                if (!IsDisposed && !Disposing) SetBusy(false, null);
            }
        }
    }
}
