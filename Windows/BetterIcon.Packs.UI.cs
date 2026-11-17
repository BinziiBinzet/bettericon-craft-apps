using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace BetterIcon.Tray
{
    public sealed class PackEditor : Form
    {
        readonly TextBox packName = new TextBox();
        readonly TextBox packAuthor = new TextBox();
        readonly DataGridView grid = new DataGridView();
        readonly Dictionary<string, string> files = new Dictionary<string, string>();
        public ThemeEntry Saved { get; private set; }
        public PackEditor(PackLibrary library, ThemeEntry basis, bool edit)
        {
            Text = edit ? "Edit icon pack" : "Create icon pack"; Font = new Font("Segoe UI", 10F);
            StartPosition = FormStartPosition.CenterParent; ClientSize = new Size(730, 600); MinimumSize = new Size(660, 480); MinimizeBox = MaximizeBox = false;
            TableLayoutPanel layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(18), ColumnCount = 1, RowCount = 6 };
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 38)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 38)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 43)); layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 45)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 44));
            FlowLayoutPanel nameRow = new FlowLayoutPanel { Dock = DockStyle.Fill };
            nameRow.Controls.Add(new Label { Text = "Pack name", AutoSize = true, Margin = new Padding(0, 6, 12, 0) });
            packName.Width = 450; packName.MaxLength = 64; packName.AccessibleName = "Pack name";
            packName.Text = edit ? basis.Name : basis == null ? "My icon pack" : basis.Name + " custom"; nameRow.Controls.Add(packName);
            layout.Controls.Add(nameRow, 0, 0);
            FlowLayoutPanel authorRow = new FlowLayoutPanel { Dock = DockStyle.Fill };
            authorRow.Controls.Add(new Label { Text = "Author", Width = 79, Margin = new Padding(0, 6, 12, 0) });
            packAuthor.Width = 450; packAuthor.MaxLength = 64; packAuthor.AccessibleName = "Pack author"; packAuthor.Text = basis == null ? "" : basis.Author;
            authorRow.Controls.Add(packAuthor); layout.Controls.Add(authorRow, 0, 1);
            layout.Controls.Add(new Label { Text = "Choose an SVG, PNG or ICO for each app. Unassigned apps keep their existing shortcut icons. Saving adds the pack; Apply icons changes shortcuts.", Dock = DockStyle.Fill }, 0, 2);
            grid.Dock = DockStyle.Fill; grid.AllowUserToAddRows = grid.AllowUserToDeleteRows = grid.AllowUserToResizeRows = false; grid.RowHeadersVisible = false; grid.AutoGenerateColumns = false; grid.SelectionMode = DataGridViewSelectionMode.FullRowSelect; grid.MultiSelect = false;
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "App", HeaderText = "App", Width = 145, ReadOnly = true });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "Artwork", HeaderText = "Artwork", AutoSizeMode = DataGridViewAutoSizeColumnMode.Fill, ReadOnly = true });
            grid.Columns.Add(new DataGridViewButtonColumn { Name = "Choose", HeaderText = "", Text = "Choose...", UseColumnTextForButtonValue = true, Width = 90 });
            grid.Columns.Add(new DataGridViewButtonColumn { Name = "Clear", HeaderText = "", Text = "Clear", UseColumnTextForButtonValue = true, Width = 65 });
            if (basis != null) foreach (ThemeIcon icon in basis.Icons) files[icon.Application] = String.IsNullOrEmpty(icon.PreviewPath) ? icon.Path : icon.PreviewPath;
            foreach (string app in PackLibrary.Applications.OrderBy(a => a)) grid.Rows.Add(app, files.ContainsKey(app) ? Path.GetFileName(files[app]) : "Not assigned");
            grid.CellContentClick += delegate(object sender, DataGridViewCellEventArgs e) {
                if (e.RowIndex < 0) return;
                string app = (string)grid.Rows[e.RowIndex].Cells[0].Value;
                if (e.ColumnIndex == 2) using (OpenFileDialog picker = new OpenFileDialog { Title = "Icon for " + app, Filter = "Icon artwork (*.svg;*.png;*.ico)|*.svg;*.png;*.ico", CheckFileExists = true }) {
                    if (picker.ShowDialog(this) == DialogResult.OK) { files[app] = picker.FileName; grid.Rows[e.RowIndex].Cells[1].Value = Path.GetFileName(picker.FileName); }
                }
                if (e.ColumnIndex == 3) { files.Remove(app); grid.Rows[e.RowIndex].Cells[1].Value = "Not assigned"; }
            };
            layout.Controls.Add(grid, 0, 3);
            Label error = new Label { Dock = DockStyle.Fill, ForeColor = Color.Firebrick, Tag = "ErrorText" }; layout.Controls.Add(error, 0, 4);
            FlowLayoutPanel buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft };
            Button cancel = new Button { Text = "Cancel", Width = 100, Height = 32, DialogResult = DialogResult.Cancel };
            Button save = new Button { Text = "Save pack", Width = 120, Height = 32, Tag = "PrimaryAction" };
            save.Click += async delegate {
                save.Enabled = cancel.Enabled = grid.Enabled = packName.Enabled = packAuthor.Enabled = ControlBox = false;
                try {
                    string name = packName.Text, author = packAuthor.Text; Dictionary<string, string> chosen = new Dictionary<string, string>(files);
                    Saved = await Task.Run(() => library.Save(name, chosen, edit ? basis.LibraryId : null, author)); DialogResult = DialogResult.OK; Close();
                }
                catch (Exception failure) { error.Text = failure.Message; }
                finally { save.Enabled = cancel.Enabled = grid.Enabled = packName.Enabled = packAuthor.Enabled = ControlBox = true; }
            };
            buttons.Controls.Add(cancel); buttons.Controls.Add(save); layout.Controls.Add(buttons, 0, 5);
            Controls.Add(layout); AcceptButton = save; CancelButton = cancel;
        }
    }

    // OwnerDrawFixed customizes only the headers; the native tab control still
    // paints a light page frame. Paint its chrome while retaining its native
    // pages, selection, keyboard navigation, hit testing and accessibility.
    public sealed class ThemedTabControl : TabControl
    {
        public ThemedTabControl()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        }
        protected override void OnPaintBackground(PaintEventArgs e)
        {
            using (Brush brush = new SolidBrush(SelectedTab == null ? BackColor : SelectedTab.BackColor))
                e.Graphics.FillRectangle(brush, ClientRectangle);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            for (int index = 0; index < TabCount; index++) {
                Rectangle bounds = GetTabRect(index);
                if (!e.ClipRectangle.IntersectsWith(bounds)) continue;
                DrawItemState state = index == SelectedIndex ? DrawItemState.Selected : DrawItemState.None;
                if (Focused && ShowFocusCues && index == SelectedIndex) state |= DrawItemState.Focus;
                if (!Enabled) state |= DrawItemState.Disabled;
                OnDrawItem(new DrawItemEventArgs(e.Graphics, Font, bounds, index, state));
            }
        }
        protected override void OnSelectedIndexChanged(EventArgs e) { base.OnSelectedIndexChanged(e); Invalidate(); }
        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }
    }

    public sealed partial class LauncherForm
    {
        readonly TabControl pages = new ThemedTabControl();
        readonly TabPage launcherPage = new TabPage("Launcher"), settingsPage = new TabPage("Manage Icons");
        readonly IconGridView packPreview = new IconGridView();
        readonly List<Bitmap> packArtwork = new List<Bitmap>();
        readonly List<ArtworkSource> packSources = new List<ArtworkSource>();
        readonly Panel settingsScroll = new Panel();
        readonly TableLayoutPanel settingsContent = new TableLayoutPanel();
        readonly ContextMenuStrip importPackMenu = new ContextMenuStrip(), managePackMenu = new ContextMenuStrip();
        readonly Label packDetails = new Label();
        readonly TrackBar iconSizeSlider = new TrackBar();
        readonly Label iconSizeValue = new Label();
        readonly Button resetIconSize = new Button();
        readonly CheckBox showAppNames = new CheckBox();
        readonly Button removePackButton = new Button();
        readonly Label appVersion = new Label();
        bool arrangingManageIcons;
        readonly List<Button> packButtons = new List<Button>();
        int iconWheelDelta;
        PackLibrary library;
        ThemeEntry[] bundledThemes = new ThemeEntry[0];
        bool fillingThemes;

        void DrawPageTab(object sender, DrawItemEventArgs e)
        {
            bool selected = pages.SelectedIndex == e.Index;
            AppearancePalette palette = appearancePalette ?? AppAppearance.Resolve(preferences.AppearanceMode);
            Color background = selected ? palette.Surface : palette.InactiveTab, foreground = palette.Text;
            if (SystemInformation.HighContrast) { background = selected ? SystemColors.Highlight : SystemColors.Control; foreground = selected ? SystemColors.HighlightText : SystemColors.ControlText; }
            // Match the mockup's 32px upper corners and square page joins.
            // Top-only rounding can exceed half the tab's height.
            Rectangle bounds = e.Bounds;
            float radius = Math.Min(32f, Math.Min(bounds.Height, bounds.Width / 2f));
            using (GraphicsPath shape = new GraphicsPath()) using (Brush brush = new SolidBrush(background)) {
                shape.AddArc(bounds.Left, bounds.Top, radius * 2, radius * 2, 180, 90);
                shape.AddArc(bounds.Right - radius * 2, bounds.Top, radius * 2, radius * 2, 270, 90);
                shape.AddLine(bounds.Right, bounds.Top + radius, bounds.Right, bounds.Bottom);
                shape.AddLine(bounds.Right, bounds.Bottom, bounds.Left, bounds.Bottom);
                shape.CloseFigure();
                GraphicsState state = e.Graphics.Save();
                try { e.Graphics.SmoothingMode = SmoothingMode.AntiAlias; e.Graphics.FillPath(brush, shape); }
                finally { e.Graphics.Restore(state); }
            }
            using (Font font = new Font(Font, selected ? FontStyle.Bold : FontStyle.Regular))
                TextRenderer.DrawText(e.Graphics, pages.TabPages[e.Index].Text, font, e.Bounds, foreground, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            if (selected && (e.State & DrawItemState.Focus) != 0) ControlPaint.DrawFocusRectangle(e.Graphics, Rectangle.Inflate(e.Bounds, -5, -5), foreground, background);
        }
        void SizeTabs() { Size size = new Size(Math.Max(80, (pages.ClientSize.Width - 10) / 2), 38); if (pages.ItemSize != size) pages.ItemSize = size; }

        Button PackButton(string text, int width, Action action)
        {
            Button button = Button(text, width); button.Click += delegate { action(); }; packButtons.Add(button); return button;
        }
        void ChangeIconSize()
        {
            int previous = preferences.IconSize;
            preferences.IconSize = iconSizeSlider.Value;
            iconSizeValue.Text = preferences.IconSize + " px";
            try { ResizeAppIcons(); ResizePackIcons(); }
            catch (Exception error) {
                if (!(error is OutOfMemoryException) && !(error is System.Runtime.InteropServices.ExternalException)) throw;
                previous = Math.Min(previous, iconSizeSlider.Maximum);
                preferences.IconSize = previous; iconSizeSlider.Value = previous;
                status.Text = "Could not display that size. Try a smaller size."; return;
            }
            try { WritePreferences(); status.Text = "Icon size saved."; }
            catch (IOException) { status.Text = "Icon size changed for this session, but could not be saved."; }
            catch (UnauthorizedAccessException) { status.Text = "Icon size changed for this session, but could not be saved."; }
        }
        void ChangeAppNames()
        {
            preferences.ShowAppNames = showAppNames.Checked;
            apps.ShowAppNames = packPreview.ShowAppNames = preferences.ShowAppNames;
            LayoutManageIcons();
            try { WritePreferences(); status.Text = "App name visibility saved."; }
            catch (IOException) { status.Text = "App name visibility changed for this session, but could not be saved."; }
            catch (UnauthorizedAccessException) { status.Text = "App name visibility changed for this session, but could not be saved."; }
        }
        void ChangeIconSizeFromWheel(int delta)
        {
            if (busy || !CanFilter) { iconWheelDelta = 0; return; }
            // Fine-resolution wheels may send partial notches; retain the remainder until 120 units accumulate.
            iconWheelDelta += delta;
            int steps = iconWheelDelta / 120; iconWheelDelta %= 120;
            if (steps != 0) iconSizeSlider.Value = Math.Max(iconSizeSlider.Minimum, Math.Min(iconSizeSlider.Maximum, iconSizeSlider.Value + steps * iconSizeSlider.SmallChange));
        }
        static TableLayoutPanel SettingsTable(int columns)
        {
            return new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, ColumnCount = columns, Margin = Padding.Empty };
        }
        static void SettingsRow(TableLayoutPanel table, Control control)
        {
            int row = table.RowCount++;
            table.RowStyles.Add(new RowStyle(SizeType.AutoSize)); table.Controls.Add(control, 0, row);
        }
        TableLayoutPanel SettingsSection(string name, string title)
        {
            TableLayoutPanel section = SettingsTable(1); section.Name = name; section.BackColor = Color.White;
            section.Padding = new Padding(14); section.Margin = new Padding(0, 0, 0, 12);
            SettingsRow(section, new Label { Text = title, AutoSize = true, Font = new Font(Font, FontStyle.Bold), Margin = new Padding(0, 0, 0, 10) });
            SettingsRow(settingsContent, section); return section;
        }
        static void SettingsButton(Button button)
        {
            button.AutoSize = true; button.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            button.MinimumSize = new Size(0, 32); button.Padding = new Padding(10, 3, 10, 3);
            button.Dock = DockStyle.Fill; button.Margin = new Padding(4, 0, 4, 0);
        }
        void BuildSettingsPage(bool testing)
        {
            TableLayoutPanel root = SettingsTable(1); root.Dock = DockStyle.Fill; root.AutoSize = false;
            root.RowCount = 2; root.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            settingsPage.Controls.Add(root);
            settingsScroll.Dock = DockStyle.Fill; settingsScroll.AutoScroll = true; settingsScroll.Margin = Padding.Empty;
            settingsContent.Dock = DockStyle.Top; settingsContent.AutoSize = false;
            settingsContent.ColumnCount = 1; settingsContent.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            settingsContent.RowCount = 4;
            settingsContent.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            settingsContent.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            settingsContent.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            settingsContent.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            settingsContent.Padding = new Padding(32, 26, 32, 8); settingsContent.Margin = Padding.Empty;
            settingsScroll.Controls.Add(settingsContent); root.Controls.Add(settingsScroll, 0, 0);

            TableLayoutPanel packs = SettingsTable(1); packs.Name = "IconPackSection";
            SettingsRow(packs, new Label { Text = "Icon pack", AutoSize = true, Font = new Font(Font, FontStyle.Bold), Margin = new Padding(0, 0, 0, 8) });
            themes.DropDownStyle = ComboBoxStyle.DropDownList; themes.Dock = DockStyle.Top; themes.Margin = new Padding(0, 0, 0, 5); themes.AccessibleName = "Icon pack";
            themes.AccessibleDescription = "Select an icon pack. Right-click for pack editing and ZIP export, also available in the tray Pack actions menu.";
            themes.SelectedIndexChanged += delegate { SelectPack(); };
            SettingsRow(packs, themes);
            packDetails.AutoSize = true; packDetails.Dock = DockStyle.Top; packDetails.Margin = new Padding(0, 0, 0, 10);
            SettingsRow(packs, packDetails);
            TableLayoutPanel actions = SettingsTable(3); actions.Margin = new Padding(0, 0, 0, 10);
            for (int i = 0; i < 3; i++) actions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F / 3));
            Button import = PackButton("Import...", 120, delegate { });
            importPackMenu.Items.Add("From ZIP...", null, delegate { ImportPack(true); });
            importPackMenu.Items.Add("From folder...", null, delegate { ImportPack(false); });
            import.Click += delegate { importPackMenu.Show(import, new Point(0, import.Height)); };
            Button create = PackButton("New pack...", 120, delegate { EditPack(false, false); });
            managePackMenu.Items.Add("Customize...", null, delegate { EditPack(true, false); });
            managePackMenu.Items.Add("Edit pack...", null, delegate { EditPack(true, true); });
            managePackMenu.Items.Add("Export ZIP...", null, delegate { ExportPack(); });
            managePackMenu.Items.Add(new ToolStripSeparator());
            managePackMenu.Items.Add("Restore built-in packs", null, delegate { try { library.RestoreBundled(); ReloadLibrary(null); } catch (Exception error) { Report(error); } });
            managePackMenu.Opening += delegate { UpdatePackButtons(); };
            themes.ContextMenuStrip = managePackMenu;
            removePackButton.Text = "Remove pack"; removePackButton.AccessibleName = "Remove pack";
            removePackButton.Click += delegate { RemovePack(); };
            int column = 0; foreach (Button button in new[] { import, create, removePackButton }) { SettingsButton(button); actions.Controls.Add(button, column++, 0); }
            SettingsRow(packs, actions);
            settingsContent.Controls.Add(packs, 0, 0);
            packPreview.Dock = DockStyle.Fill; packPreview.Margin = new Padding(0, 0, 0, 16);
            packPreview.ShowAppNames = preferences.ShowAppNames; packPreview.SetIconSize(preferences.IconSize);
            packPreview.MultiSelect = false; packPreview.HideSelection = false; packPreview.ShowItemToolTips = true;
            packPreview.BorderStyle = BorderStyle.None; packPreview.BackColor = Color.White; packPreview.AccessibleName = "Icon pack preview";
            settingsContent.Controls.Add(packPreview, 0, 1);

            BuildAppearanceSettings();

            TableLayoutPanel launcher = SettingsTable(1); launcher.Name = "LauncherSection";
            showAppNames.Text = "Show app names"; showAppNames.AccessibleName = "Show app names";
            showAppNames.AutoSize = true; showAppNames.Dock = DockStyle.Top;
            showAppNames.Margin = new Padding(0, 0, 0, 14); showAppNames.Checked = preferences.ShowAppNames;
            showAppNames.CheckedChanged += delegate { ChangeAppNames(); };
            SettingsRow(launcher, showAppNames);
            TableLayoutPanel sizing = SettingsTable(4); sizing.Margin = new Padding(0, 0, 0, 10);
            sizing.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize)); sizing.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            sizing.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize)); sizing.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            sizing.Controls.Add(new Label { Text = "Icon size", AutoSize = true, Anchor = AnchorStyles.Left, Margin = new Padding(0, 0, 12, 0) }, 0, 0);
            iconSizeSlider.Minimum = Preferences.MinimumIconSize; iconSizeSlider.Maximum = Preferences.MaximumIconSize;
            iconSizeSlider.Value = preferences.IconSize; iconSizeSlider.SmallChange = 8; iconSizeSlider.LargeChange = 16; iconSizeSlider.TickStyle = TickStyle.None;
            iconSizeSlider.Dock = DockStyle.Fill; iconSizeSlider.AccessibleName = "Icon size"; iconSizeSlider.AccessibleDescription = "Size in pixels, based on available artwork. Updates both tabs.";
            iconSizeValue.Text = preferences.IconSize + " px"; iconSizeValue.AutoSize = true; iconSizeValue.MinimumSize = new Size(60, 0); iconSizeValue.Anchor = AnchorStyles.None; iconSizeValue.TextAlign = ContentAlignment.MiddleCenter;
            resetIconSize.Text = "Reset"; SettingsButton(resetIconSize); resetIconSize.AccessibleName = "Reset icon size";
            resetIconSize.Click += delegate { iconSizeSlider.Value = Preferences.DefaultIconSize; };
            iconSizeSlider.ValueChanged += delegate { ChangeIconSize(); };
            sizing.Controls.Add(iconSizeSlider, 1, 0); sizing.Controls.Add(iconSizeValue, 2, 0); sizing.Controls.Add(resetIconSize, 3, 0);
            SettingsRow(launcher, sizing);
            settingsContent.Controls.Add(launcher, 0, 2);

            TableLayoutPanel shortcuts = SettingsTable(1); shortcuts.Name = "ShortcutsSection";
            TableLayoutPanel applyRow = SettingsTable(2);
            applyRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50)); applyRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            apply.Text = "Apply icons..."; apply.Tag = "PrimaryAction"; SettingsButton(apply); apply.BackColor = accent; apply.ForeColor = Color.White; apply.FlatStyle = FlatStyle.Flat; apply.Click += async delegate { await ApplyTheme(); };
            restore.Text = "Restore all defaults..."; SettingsButton(restore); restore.Click += async delegate { await RestoreIcons(); };
            applyRow.Controls.Add(apply, 0, 0); applyRow.Controls.Add(restore, 1, 0); SettingsRow(shortcuts, applyRow);
            status.Text = testing ? "Test library and shortcuts only." : "Changes are reviewed before they are applied.";
            status.AutoSize = false; status.Height = Font.Height + 10; status.Dock = DockStyle.Top; status.AutoEllipsis = true;
            status.Margin = new Padding(4, 8, 4, 0); status.AccessibleName = "Status";
            SettingsRow(shortcuts, status); settingsContent.Controls.Add(shortcuts, 0, 3);

            TableLayoutPanel footer = SettingsTable(3); footer.Name = "ManageIconsFooter"; footer.Padding = new Padding(24, 6, 24, 12);
            footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize)); footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            appVersion.Text = "Better Icon for ArtCraft version " + typeof(LauncherForm).Assembly.GetName().Version.ToString(3);
            appVersion.AutoSize = true; appVersion.Dock = DockStyle.Fill; appVersion.TextAlign = ContentAlignment.MiddleRight;
            appVersion.Margin = new Padding(0, 0, 10, 0); appVersion.Tag = "SecondaryText";
            footer.Controls.Add(appVersion, 0, 0); footer.Controls.Add(appIconButton, 1, 0); footer.Controls.Add(appearanceModeButton, 2, 0);
            root.Controls.Add(footer, 0, 1);
            settingsScroll.ClientSizeChanged += delegate { LayoutManageIcons(); };
            settingsContent.Layout += delegate { LayoutManageIcons(); };
            settingsPage.VisibleChanged += delegate { if (settingsPage.Visible) LayoutManageIcons(); };
        }
        void LayoutManageIcons()
        {
            if (arrangingManageIcons || settingsContent.Controls.Count < 4 || settingsScroll.ClientSize.Width <= 0) return;
            arrangingManageIcons = true;
            try {
                int rowHeight = packPreview.GridCellSize.Height + 12;
                if (packPreview.MinimumSize.Height != rowHeight) packPreview.MinimumSize = new Size(0, rowHeight);
                int width = Math.Max(1, settingsScroll.ClientSize.Width - settingsContent.Padding.Horizontal - SystemInformation.VerticalScrollBarWidth);
                int minimum = settingsContent.Padding.Vertical + rowHeight + packPreview.Margin.Vertical;
                foreach (Control control in settingsContent.Controls) if (control != packPreview)
                    minimum += control.GetPreferredSize(new Size(width, 0)).Height + control.Margin.Vertical;
                int height = Math.Max(settingsScroll.ClientSize.Height, minimum);
                if (settingsContent.Height != height) settingsContent.Height = height;
                settingsScroll.AutoScrollMinSize = new Size(0, minimum);
            }
            finally { arrangingManageIcons = false; }
        }
        void ReloadLibrary(string selectId)
        {
            if (catalog == null) return;
            string chosen = selectId ?? (SelectedTheme == null ? preferences.Theme : SelectedTheme.Id);
            ThemeEntry defaults = new ThemeEntry { Id = ThemeEntry.DefaultThemeId, Name = "ArtCraft default", IsDefault = true, Icons = new ThemeIcon[0], IconCount = catalog.Apps.Select(a => a.Application).Distinct().Count() };
            catalog.Themes = new[] { defaults }.Concat(library.VisibleThemes(bundledThemes).Where(t => !t.IsDefault)).ToArray();
            fillingThemes = true;
            try { themes.Items.Clear(); themes.Items.AddRange(catalog.Themes); themes.SelectedItem = catalog.Themes.FirstOrDefault(t => t.Id == chosen) ?? catalog.Themes.FirstOrDefault(t => t.Name == "Cardboard") ?? catalog.Themes.FirstOrDefault(); }
            finally { fillingThemes = false; }
            RenderSelection(); SavePreferences(); BuildTrayMenu();
        }
        void RenderPack()
        {
            ThemeEntry theme = SelectedTheme;
            packDetails.Text = theme == null ? "No packs. Import or create one." : theme.IsDefault ? "Original icons for your installed apps. Restore defaults below to undo BetterIcon changes." : theme.IconCount + " icons / " + (theme.Managed ? "Personal pack" : "Built-in pack");
            packPreview.BeginUpdate();
            try {
                packPreview.Items.Clear(); ClearPackArtwork();
                if (theme != null && theme.IsDefault) foreach (AppEntry app in catalog.Apps.GroupBy(a => a.Application).Select(g => g.First()).OrderBy(a => a.Application)) {
                    AddArtwork(packArtwork, packSources, app.OriginalIconPath, app.OriginalIconIndex);
                    packPreview.Items.Add(new ListViewItem(app.Application, packArtwork.Count - 1) { Tag = app.Application, ToolTipText = app.Application + " - ArtCraft default" });
                }
                else if (theme != null) foreach (ThemeIcon icon in theme.Icons.OrderBy(i => i.Application)) {
                    AddArtwork(packArtwork, packSources, PreviewPath(icon), 0);
                    packPreview.Items.Add(new ListViewItem(icon.Application, packArtwork.Count - 1) { Tag = icon.Application, ToolTipText = icon.Application });
                }
                if (!renderingArtwork) { UpdateIconSizeLimit(); ResizePackIcons(); }
            }
            finally { packPreview.EndUpdate(); }
            UpdatePackButtons();
        }
        void ClearPackArtwork() { foreach (Bitmap image in packArtwork) image.Dispose(); packArtwork.Clear(); packSources.Clear(); }
        void ResizePackIcons()
        {
            packPreview.BeginUpdate();
            try {
                EnsureArtworkSize(packArtwork, packSources, preferences.IconSize);
                packPreview.SetArtwork(packArtwork, preferences.IconSize);
                // Leave room for at least one complete row, including names, at the largest size.
                LayoutManageIcons();
                if (packPreview.SelectedItems.Count == 1) packPreview.SelectedItems[0].EnsureVisible();
            }
            finally { packPreview.EndUpdate(); }
        }
        void UpdatePackButtons()
        {
            foreach (Button button in packButtons) button.Enabled = !busy;
            foreach (ToolStripItem item in importPackMenu.Items) item.Enabled = !busy;
            foreach (ToolStripItem item in managePackMenu.Items) {
                bool needsPersonal = item.Text == "Edit pack..." || item.Text == "Export ZIP...";
                item.Enabled = !busy && (item.Text == "Restore built-in packs" || (SelectedTheme != null && !SelectedTheme.IsDefault && (!needsPersonal || SelectedTheme.Managed)));
            }
            bool defaults = SelectedTheme != null && SelectedTheme.IsDefault;
            removePackButton.Enabled = !busy && SelectedTheme != null && !defaults;
            apply.Text = defaults ? "Restore ArtCraft defaults..." : "Apply icons...";
            restore.Visible = !defaults;
            TableLayoutPanel applyRow = apply.Parent as TableLayoutPanel;
            if (applyRow != null) applyRow.SetColumnSpan(apply, defaults ? 2 : 1);
            apply.Enabled = !busy && SelectedTheme != null;
        }
        async Task ChooseAppIcon(AppEntry target)
        {
            if (busy || !PackLibrary.Applications.Contains(target.Application)) return;
            using (OpenFileDialog picker = new OpenFileDialog { Title = "Choose icon for " + target.Application, Filter = "Icon artwork (*.svg;*.png;*.ico)|*.svg;*.png;*.ico", CheckFileExists = true, Multiselect = false, RestoreDirectory = true }) {
                if (picker.ShowDialog(this) != DialogResult.OK) return;
                try { await ChangeAppIcon(target, picker.FileName); }
                catch (Exception error) { Report(error); }
            }
        }
        async Task ChangeAppIcon(AppEntry target, string path)
        {
            if (busy) return;
            ThemeEntry basis = SelectedTheme;
            SetBusy(true, "Saving icon for " + target.Application + "...");
            try {
                ThemeEntry saved = await Task.Run(() => library.ReplaceAppIcon(basis, target.Application, path));
                // A freshly chosen image replaces this app's remembered default
                // preview, while unrelated apps and shortcut files stay intact.
                HashSet<string> shortcuts = new HashSet<string>(catalog.Apps.Where(app => app.Application == target.Application).Select(app => app.Shortcut), StringComparer.OrdinalIgnoreCase);
                preferences.DefaultShortcuts = (preferences.DefaultShortcuts ?? new string[0]).Where(shortcut => !shortcuts.Contains(shortcut)).ToArray();
                ReloadLibrary(saved.Id);
                status.Text = "Saved " + target.Application + " icon in " + saved.Name + ". Choose Apply icons to change Windows shortcuts.";
            }
            finally { SetBusy(false, null); }
        }
        async void ImportPack(bool zip)
        {
            if (busy) return;
            string source = null;
            if (zip) using (OpenFileDialog picker = new OpenFileDialog { Title = "Import one icon theme", Filter = "Icon pack ZIP (*.zip)|*.zip" }) { if (picker.ShowDialog(this) == DialogResult.OK) source = picker.FileName; }
            else using (FolderBrowserDialog picker = new FolderBrowserDialog { Description = "Choose one theme folder containing app-named SVG, PNG or ICO files.", ShowNewFolderButton = false }) { if (picker.ShowDialog(this) == DialogResult.OK) source = picker.SelectedPath; }
            if (source == null) return;
            SetBusy(true, "Importing icon pack...");
            try { ThemeEntry added = await Task.Run(() => library.Import(source)); ReloadLibrary(added.Id); status.Text = "Imported " + added.Name + ". Choose Apply icons to change shortcuts."; }
            catch (Exception error) { Report(error); }
            finally { SetBusy(false, null); }
        }
        async void ExportPack()
        {
            if (busy || SelectedTheme == null || !SelectedTheme.Managed) return;
            ThemeEntry selected = SelectedTheme; string destination;
            string filename = new string(selected.Name.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '_' : c).ToArray()).TrimEnd(' ', '.');
            using (SaveFileDialog picker = new SaveFileDialog { Title = "Export icon pack", Filter = "Icon pack ZIP (*.zip)|*.zip", DefaultExt = "zip", AddExtension = true, OverwritePrompt = true, FileName = filename + ".zip" }) {
                if (picker.ShowDialog(this) != DialogResult.OK) return; destination = picker.FileName;
            }
            SetBusy(true, "Exporting icon pack...");
            try { await Task.Run(() => library.Export(selected, destination, true)); status.Text = "Exported " + selected.Name + ". Share the ZIP; recipients can use Import ZIP."; }
            catch (Exception error) { Report(error); }
            finally { SetBusy(false, null); }
        }
        void EditPack(bool useSelected, bool edit)
        {
            if (busy || (useSelected && (SelectedTheme == null || SelectedTheme.IsDefault)) || (edit && !SelectedTheme.Managed)) return;
            SetBusy(true, "Editing icon pack...");
            try { using (PackEditor editor = new PackEditor(library, useSelected ? SelectedTheme : null, edit)) { ApplyDialogAppearance(editor); if (editor.ShowDialog(this) == DialogResult.OK) { ReloadLibrary(editor.Saved.Id); status.Text = "Saved " + editor.Saved.Name + ". Choose Apply icons to change shortcuts."; } } }
            finally { SetBusy(false, null); }
        }
        void RemovePack()
        {
            if (busy || SelectedTheme == null || SelectedTheme.IsDefault) return;
            ThemeEntry selected = SelectedTheme;
            string note = "Remove " + selected + " from your library? Applied shortcut icons will stay as they are." + (selected.Managed ? "" : " You can restore built-in packs later.");
            if (!AppAppearance.Message(this, "Remove icon pack", note, appearancePalette, true)) return;
            try { library.Remove(selected); ReloadLibrary(null); status.Text = "Pack removed from your library."; }
            catch (Exception error) { Report(error); }
        }
    }
}
