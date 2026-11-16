using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace BetterIcon.Tray
{
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
            loadingPanel.Name = "LoadingIndicator"; loadingPanel.Dock = DockStyle.Bottom;
            loadingPanel.Height = 52; loadingPanel.Padding = new Padding(16, 6, 16, 8);
            loadingPanel.ColumnCount = 1; loadingPanel.RowCount = 2;
            loadingPanel.RowStyles.Add(new RowStyle(SizeType.Absolute, 24));
            loadingPanel.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            loadingMessage.Dock = DockStyle.Fill; loadingMessage.Margin = Padding.Empty;
            loadingMessage.AutoEllipsis = true; loadingMessage.TextAlign = ContentAlignment.MiddleLeft;
            loadingMessage.AccessibleName = "Loading status";
            loadingProgress.Dock = DockStyle.Fill; loadingProgress.Margin = Padding.Empty;
            loadingProgress.Style = ProgressBarStyle.Marquee; loadingProgress.MarqueeAnimationSpeed = 0;
            loadingProgress.AccessibleName = "BetterIcon is working";
            loadingPanel.Controls.Add(loadingMessage, 0, 0); loadingPanel.Controls.Add(loadingProgress, 0, 1);
            loadingPanel.Visible = false; Controls.Add(loadingPanel);
        }
        void ShowLoading(bool value, string message)
        {
            if (!String.IsNullOrEmpty(message)) { loadingMessage.Text = message; loadingMessage.AccessibleName = message; }
            loadingProgress.MarqueeAnimationSpeed = value ? 30 : 0;
            loadingPanel.Visible = value;
            if (value) loadingPanel.Update();
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
                apps.Items.Clear(); appTiles.Clear(); pictures.Images.Clear();
                packPreview.Items.Clear(); packPictures.Images.Clear(); ClearAppArtwork(); ClearPackArtwork();
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
        async Task LoadSelectedPack()
        {
            ThemeEntry selected = SelectedTheme;
            if (selected == null || catalog == null) return;
            string previous = renderedThemeId ?? preferences.Theme;
            AppEntry[] installed = catalog.Apps.ToArray();
            string[] defaults = (preferences.DefaultShortcuts ?? new string[0]).ToArray();
            int size = preferences.IconSize;
            loadingTheme = selected; SetBusy(true, "Loading " + selected + "...");
            PreparedPack prepared = null;
            try {
                // Show feedback immediately, then keep file I/O and decoding off the
                // window thread so painting and the progress animation can continue.
                await Task.Yield();
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
                    Report(error);
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
