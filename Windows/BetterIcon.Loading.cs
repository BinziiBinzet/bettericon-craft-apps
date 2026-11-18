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
        public void EnablePreviews(PackPreviewStore store) { hover = new PackHoverPreview(store, this); }
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
        readonly ProgressBar loadingProgress = new ProgressBar();
        Task packLoadTask = Task.FromResult(0);
        ThemeEntry loadingTheme;
        string renderedThemeId;

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
        sealed class PreparedPack : IDisposable
        {
            public readonly List<ArtworkRequest> Apps = new List<ArtworkRequest>(), Pack = new List<ArtworkRequest>();
            public readonly List<Bitmap> AppImages = new List<Bitmap>(), PackImages = new List<Bitmap>();
            public readonly List<ArtworkSource> AppSources = new List<ArtworkSource>(), PackSources = new List<ArtworkSource>();
            public void Dispose() { foreach (Bitmap image in AppImages.Concat(PackImages)) image.Dispose(); }
        }
        static void PrepareImages(List<ArtworkRequest> requests, List<Bitmap> images, List<ArtworkSource> sources, int size, Icon fallback)
        {
            int cacheSize = 128; while (cacheSize < size) cacheSize *= 2;
            foreach (ArtworkRequest request in requests) {
                ArtworkSource source = DescribeArtwork(request.Path, request.Index);
                sources.Add(source); images.Add(Thumbnail(source.Path, fallback, Math.Min(cacheSize, source.MaximumSize), source.Index));
            }
        }
        static PreparedPack PreparePack(ThemeEntry theme, AppEntry[] installed, string[] defaults, int size, Icon fallback)
        {
            PreparedPack result = new PreparedPack();
            try {
                foreach (AppEntry app in installed) {
                    bool original = theme.IsDefault || defaults.Contains(app.Shortcut, StringComparer.OrdinalIgnoreCase);
                    ThemeIcon art = original ? null : theme.Icons.FirstOrDefault(icon => icon.Application == app.Application);
                    bool originalSource = original || String.IsNullOrWhiteSpace(app.IconPath);
                    result.Apps.Add(new ArtworkRequest {
                        Path = art == null ? Environment.ExpandEnvironmentVariables((originalSource ? app.OriginalIconPath : app.IconPath) ?? "") : PreviewPath(art),
                        Index = art != null ? 0 : originalSource ? app.OriginalIconIndex : app.IconIndex,
                        Name = app.Name, Tooltip = app.Name + Environment.NewLine + app.Shortcut, Tag = app
                    });
                }
                if (theme.IsDefault) foreach (AppEntry app in installed.GroupBy(app => app.Application).Select(group => group.First()).OrderBy(app => app.Application))
                    result.Pack.Add(new ArtworkRequest { Path = app.OriginalIconPath, Index = app.OriginalIconIndex, Name = app.Application, Tooltip = app.Application + " - ArtCraft default", Tag = app.Application });
                else foreach (ThemeIcon art in theme.Icons.OrderBy(icon => icon.Application))
                    result.Pack.Add(new ArtworkRequest { Path = PreviewPath(art), Name = art.Application, Tooltip = art.Application, Tag = art.Application });
                PrepareImages(result.Apps, result.AppImages, result.AppSources, size, fallback);
                PrepareImages(result.Pack, result.PackImages, result.PackSources, size, fallback);
                return result;
            }
            catch { result.Dispose(); throw; }
        }
        void DisplayPreparedPack(ThemeEntry theme, PreparedPack prepared)
        {
            apps.BeginUpdate(); packPreview.BeginUpdate();
            try {
                apps.Items.Clear(); appTiles.Clear();
                packPreview.Items.Clear(); ClearAppArtwork(); ClearPackArtwork();
                appArtwork.AddRange(prepared.AppImages); appSources.AddRange(prepared.AppSources); prepared.AppImages.Clear();
                packArtwork.AddRange(prepared.PackImages); packSources.AddRange(prepared.PackSources); prepared.PackImages.Clear();
                for (int i = 0; i < prepared.Apps.Count; i++) {
                    ArtworkRequest request = prepared.Apps[i];
                    appTiles.Add(new ListViewItem(request.Name, i) { Tag = request.Tag, ToolTipText = request.Tooltip });
                }
                for (int i = 0; i < prepared.Pack.Count; i++) {
                    ArtworkRequest request = prepared.Pack[i];
                    packPreview.Items.Add(new ListViewItem(request.Name, i) { Tag = request.Tag, ToolTipText = request.Tooltip });
                }
                packDetails.Text = theme.IsDefault ? "Original icons for your installed apps. Restore defaults below to undo BetterIcon changes." : theme.IconCount + " icons / " + (theme.Managed ? "Personal pack" : "Built-in pack");
                UpdateIconSizeLimit(); ResizeAppIcons(); ResizePackIcons(); UpdatePackButtons();
                renderedThemeId = theme.Id;
            }
            finally { packPreview.EndUpdate(); apps.EndUpdate(); }
        }
        async Task DownloadTheme(ThemeEntry theme)
        {
            var reply = await worker.Run(new WorkerRequest { Action = "DownloadPack", Theme = theme.Id }, false);
            if (reply.DownloadedIcons == null || reply.DownloadedFileIcons == null) throw new IOException("Incomplete downloaded icon pack.");
            theme.Icons = reply.DownloadedIcons;
            theme.IconCount = theme.Icons.Length; theme.FileIcons = reply.DownloadedFileIcons;
            theme.NeedsDownload = false; theme.UpdateAvailable = false; theme.Downloaded = true;
            themes.RefreshLabels(); BuildTrayMenu();
        }
        async Task LoadSelectedPack()
        {
            ThemeEntry selected = SelectedTheme;
            if (selected == null || catalog == null) return;
            string previous = renderedThemeId ?? preferences.Theme;
            AppEntry[] installed = catalog.Apps.ToArray();
            string[] defaults = (preferences.DefaultShortcuts ?? new string[0]).ToArray();
            int size = preferences.IconSize;
            loadingTheme = selected; SetBusy(true, PackActivity(selected));
            PreparedPack prepared = null;
            try {
                // Show feedback immediately, then keep file I/O and decoding off the
                // window thread so painting and the progress animation can continue.
                await Task.Yield();
                if (selected.HasDownload) {
                    await DownloadTheme(selected);
                    if (IsDisposed || Disposing) return;
                    status.Text = PackActivity(selected);
                    ShowLoading(true, status.Text);
                }
                using (Icon fallback = (Icon)Icon.Clone())
                    prepared = await Task.Run(() => PreparePack(selected, installed, defaults, size, fallback));
                if (IsDisposed || Disposing) return;
                DisplayPreparedPack(selected, prepared); SavePreferences(); BuildTrayMenu();
                status.Text = selected.IsDefault ? "ArtCraft default preview loaded." : selected + " loaded. Choose Apply icons to change Windows shortcuts.";
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
    }
}
