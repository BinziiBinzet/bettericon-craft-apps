using System;
using System.Collections.Generic;
using System.Drawing;
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
            layout.Controls.Add(new Label { Text = "Choose a PNG or ICO for each app. Unassigned apps keep their existing shortcut icons. Saving adds the pack; Apply icons changes shortcuts.", Dock = DockStyle.Fill }, 0, 2);
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
                if (e.ColumnIndex == 2) using (OpenFileDialog picker = new OpenFileDialog { Title = "Icon for " + app, Filter = "Icon artwork (*.png;*.ico)|*.png;*.ico", CheckFileExists = true }) {
                    if (picker.ShowDialog(this) == DialogResult.OK) { files[app] = picker.FileName; grid.Rows[e.RowIndex].Cells[1].Value = Path.GetFileName(picker.FileName); }
                }
                if (e.ColumnIndex == 3) { files.Remove(app); grid.Rows[e.RowIndex].Cells[1].Value = "Not assigned"; }
            };
            layout.Controls.Add(grid, 0, 3);
            Label error = new Label { Dock = DockStyle.Fill, ForeColor = Color.Firebrick }; layout.Controls.Add(error, 0, 4);
            FlowLayoutPanel buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft };
            Button cancel = new Button { Text = "Cancel", Width = 100, Height = 32, DialogResult = DialogResult.Cancel };
            Button save = new Button { Text = "Save pack", Width = 120, Height = 32 };
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

    public sealed partial class LauncherForm
    {
        readonly TabControl pages = new TabControl();
        readonly TabPage launcherPage = new TabPage("Launcher"), settingsPage = new TabPage("Settings");
        readonly IconGridView packPreview = new IconGridView();
        readonly ImageList packPictures = new ImageList();
        readonly List<Bitmap> packArtwork = new List<Bitmap>();
        readonly List<ArtworkSource> packSources = new List<ArtworkSource>();
        readonly Panel settingsScroll = new Panel();
        readonly TableLayoutPanel settingsContent = new TableLayoutPanel();
        readonly ContextMenuStrip importPackMenu = new ContextMenuStrip(), managePackMenu = new ContextMenuStrip();
        readonly Label packDetails = new Label();
        readonly TrackBar iconSizeSlider = new TrackBar();
        readonly Label iconSizeValue = new Label();
        readonly Button resetIconSize = new Button();
        readonly List<Button> packButtons = new List<Button>();
        readonly ComboBox restoreAppPicker = new ComboBox();
        readonly Button restoreApp = new Button();
        readonly Label restoreAppHint = new Label();
        int iconWheelDelta;
        PackLibrary library;
        ThemeEntry[] bundledThemes = new ThemeEntry[0];
        bool fillingThemes;

        void DrawPageTab(object sender, DrawItemEventArgs e)
        {
            bool selected = pages.SelectedIndex == e.Index;
            Color background = selected ? accent : Color.FromArgb(205, 216, 232), foreground = selected ? Color.White : ink;
            if (SystemInformation.HighContrast) { background = selected ? SystemColors.Highlight : SystemColors.Control; foreground = selected ? SystemColors.HighlightText : SystemColors.ControlText; }
            using (Brush brush = new SolidBrush(background)) e.Graphics.FillRectangle(brush, e.Bounds);
            using (Font font = new Font(Font, selected ? FontStyle.Bold : FontStyle.Regular))
                TextRenderer.DrawText(e.Graphics, pages.TabPages[e.Index].Text, font, e.Bounds, foreground, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            if (selected && pages.Focused) ControlPaint.DrawFocusRectangle(e.Graphics, Rectangle.Inflate(e.Bounds, -5, -5), foreground, background);
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
            settingsContent.Dock = DockStyle.Top; settingsContent.AutoSize = true; settingsContent.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            settingsContent.ColumnCount = 1; settingsContent.Padding = new Padding(16, 14, 16, 2); settingsContent.Margin = Padding.Empty;
            settingsScroll.Controls.Add(settingsContent); root.Controls.Add(settingsScroll, 0, 0);

            TableLayoutPanel packs = SettingsSection("IconPackSection", "Icon pack");
            themes.DropDownStyle = ComboBoxStyle.DropDownList; themes.Dock = DockStyle.Top; themes.Margin = new Padding(0, 0, 0, 5); themes.AccessibleName = "Icon pack";
            themes.SelectedIndexChanged += delegate { if (!fillingThemes) { RenderSelection(); SavePreferences(); BuildTrayMenu(); } };
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
            Button manage = PackButton("Pack actions...", 140, delegate { });
            managePackMenu.Items.Add("Customize...", null, delegate { EditPack(true, false); });
            managePackMenu.Items.Add("Edit pack...", null, delegate { EditPack(true, true); });
            managePackMenu.Items.Add("Export ZIP...", null, delegate { ExportPack(); });
            managePackMenu.Items.Add(new ToolStripSeparator());
            managePackMenu.Items.Add("Remove pack", null, delegate { RemovePack(); });
            managePackMenu.Items.Add("Restore built-in packs", null, delegate { try { library.RestoreBundled(); ReloadLibrary(null); } catch (Exception error) { Report(error); } });
            manage.Click += delegate { UpdatePackButtons(); managePackMenu.Show(manage, new Point(0, manage.Height)); };
            int column = 0; foreach (Button button in new[] { import, create, manage }) { SettingsButton(button); actions.Controls.Add(button, column++, 0); }
            SettingsRow(packs, actions);
            packPictures.ImageSize = new Size(Math.Min(256, preferences.IconSize), Math.Min(256, preferences.IconSize)); packPictures.ColorDepth = ColorDepth.Depth32Bit;
            if (packPictures.Handle == IntPtr.Zero) throw new InvalidOperationException("Could not create pack previews.");
            packPreview.Dock = DockStyle.Top; packPreview.Height = 128; packPreview.Margin = Padding.Empty;
            packPreview.SetIconSize(preferences.IconSize); packPreview.LargeImageList = packPictures;
            packPreview.MultiSelect = false; packPreview.HideSelection = false; packPreview.ShowItemToolTips = true;
            packPreview.BorderStyle = BorderStyle.None; packPreview.BackColor = Color.White; packPreview.AccessibleName = "Icon pack preview";
            SettingsRow(packs, packPreview);

            TableLayoutPanel launcher = SettingsSection("LauncherSection", "Launcher");
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
            TableLayoutPanel keyboard = SettingsTable(2);
            keyboard.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); keyboard.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            subtitle.AutoSize = true; subtitle.Dock = DockStyle.Fill; subtitle.TextAlign = ContentAlignment.MiddleLeft; subtitle.Margin = new Padding(0, 0, 12, 0);
            settings.Text = "Change hotkey..."; SettingsButton(settings);
            settings.Click += delegate { if (hotkey != null) using (HotkeySettingsDialog dialog = new HotkeySettingsDialog(preferences.Hotkey, hotkey.IsRegistered, SaveHotkey)) dialog.ShowDialog(this); };
            keyboard.Controls.Add(subtitle, 0, 0); keyboard.Controls.Add(settings, 1, 0); SettingsRow(launcher, keyboard);

            TableLayoutPanel shortcuts = SettingsSection("ShortcutsSection", "Windows shortcuts");
            scopes.DropDownStyle = ComboBoxStyle.DropDownList; scopes.Dock = DockStyle.Top; scopes.Margin = new Padding(0, 0, 0, 10); scopes.AccessibleName = "Shortcut locations";
            scopes.Items.AddRange(new object[] { "My Desktop and Start menu", "Shared shortcuts (administrator)" }); scopes.SelectedIndex = preferences.Scope == "AllUsers" ? 1 : 0; scopes.SelectedIndexChanged += delegate { SavePreferences(); UpdateRestoreApps(); };
            SettingsRow(shortcuts, scopes);
            TableLayoutPanel applyRow = SettingsTable(2);
            applyRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50)); applyRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            apply.Text = "Apply icons..."; SettingsButton(apply); apply.BackColor = accent; apply.ForeColor = Color.White; apply.FlatStyle = FlatStyle.Flat; apply.Click += async delegate { await ApplyTheme(); };
            restore.Text = "Restore all defaults..."; SettingsButton(restore); restore.Click += async delegate { await RestoreIcons(); };
            applyRow.Controls.Add(apply, 0, 0); applyRow.Controls.Add(restore, 1, 0); SettingsRow(shortcuts, applyRow);
            SettingsRow(shortcuts, new Label { Text = "Restore one app", AutoSize = true, Margin = new Padding(0, 14, 0, 6) });
            TableLayoutPanel individual = SettingsTable(2);
            individual.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); individual.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            restoreAppPicker.DropDownStyle = ComboBoxStyle.DropDownList; restoreAppPicker.Dock = DockStyle.Fill; restoreAppPicker.Anchor = AnchorStyles.Left | AnchorStyles.Right;
            restoreAppPicker.AccessibleName = "App to restore"; restoreAppPicker.Margin = new Padding(0, 4, 10, 0);
            restoreAppPicker.SelectedIndexChanged += delegate { UpdateRestoreAppButton(); };
            restoreApp.Text = "Restore app default..."; SettingsButton(restoreApp);
            restoreApp.Click += async delegate { string app = restoreAppPicker.SelectedItem as string; if (!String.IsNullOrEmpty(app)) await RestoreIcons(app); };
            individual.Controls.Add(restoreAppPicker, 0, 0); individual.Controls.Add(restoreApp, 1, 0); SettingsRow(shortcuts, individual);
            restoreAppHint.AutoSize = true; restoreAppHint.Dock = DockStyle.Top; restoreAppHint.Margin = new Padding(0, 6, 0, 0); SettingsRow(shortcuts, restoreAppHint);
            previewLabel.Text = "Changes are reviewed before they are applied."; previewLabel.AutoSize = true; previewLabel.Dock = DockStyle.Top; previewLabel.Margin = new Padding(0, 8, 0, 0); SettingsRow(shortcuts, previewLabel);

            TableLayoutPanel footer = SettingsTable(3); footer.Padding = new Padding(16, 8, 16, 12);
            footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize)); footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            status.AutoSize = true; status.Dock = DockStyle.Fill; status.Margin = new Padding(0, 0, 0, 8);
            status.Text = testing ? "Test library and shortcuts only." : "Finding installed apps...";
            footer.Controls.Add(status, 0, 0); footer.SetColumnSpan(status, 3);
            Button refresh = PackButton("Refresh apps", 132, async delegate { await RefreshCatalog(); }); SettingsButton(refresh);
            exit.Text = "Exit"; SettingsButton(exit); exit.Click += delegate { ExitLauncher(); };
            footer.Controls.Add(refresh, 1, 1); footer.Controls.Add(exit, 2, 1); root.Controls.Add(footer, 0, 1);
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
            RenderSelection(); UpdateRestoreApps(); SavePreferences(); BuildTrayMenu();
        }
        void RenderPack()
        {
            ThemeEntry theme = SelectedTheme;
            packDetails.Text = theme == null ? "No packs. Import or create one." : theme.IsDefault ? "Original icons for your installed apps. Restore defaults below to undo BetterIcon changes." : theme.IconCount + " icons / " + (theme.Managed ? "Personal pack" : "Built-in pack");
            packPreview.BeginUpdate();
            try {
                packPreview.Items.Clear(); packPictures.Images.Clear(); ClearPackArtwork();
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
                ResizeArtwork(packPictures, packArtwork, preferences.IconSize); packPreview.SetArtwork(packArtwork, preferences.IconSize);
                // Leave room for at least one complete row, including names, at the largest size.
                packPreview.Height = Math.Max(128, packPreview.GridCellSize.Height + 12);
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
            apply.Text = defaults ? "Restore ArtCraft defaults..." : "Apply icons...";
            restore.Visible = !defaults;
            TableLayoutPanel applyRow = apply.Parent as TableLayoutPanel;
            if (applyRow != null) applyRow.SetColumnSpan(apply, defaults ? 2 : 1);
            apply.Enabled = !busy && SelectedTheme != null;
            UpdateRestoreAppButton();
        }
        void UpdateRestoreApps()
        {
            string selected = restoreAppPicker.SelectedItem as string;
            restoreAppPicker.BeginUpdate();
            try {
                restoreAppPicker.Items.Clear();
                if (catalog != null) restoreAppPicker.Items.AddRange(catalog.Apps.Where(a => a.Scope == Scope).Select(a => a.Application).Distinct().OrderBy(a => a).ToArray());
                if (selected != null && restoreAppPicker.Items.Contains(selected)) restoreAppPicker.SelectedItem = selected;
                else if (restoreAppPicker.Items.Count != 0) restoreAppPicker.SelectedIndex = 0;
            }
            finally { restoreAppPicker.EndUpdate(); }
            UpdateRestoreAppButton();
        }
        void UpdateRestoreAppButton()
        {
            string selected = restoreAppPicker.SelectedItem as string;
            bool available = selected != null && catalog != null && catalog.Apps.Any(a => a.Application == selected && a.Scope == Scope && a.RestoreAvailable);
            restoreAppPicker.Enabled = !busy && restoreAppPicker.Items.Count != 0;
            restoreApp.Enabled = !busy && available;
            restoreAppHint.Text = selected == null ? "No installed apps in these shortcut locations." : available ? "Restores only this app in the selected locations. Other apps keep their icons." : "No BetterIcon backup to restore for this app in these locations.";
        }
        async void ImportPack(bool zip)
        {
            if (busy) return;
            string source = null;
            if (zip) using (OpenFileDialog picker = new OpenFileDialog { Title = "Import one icon theme", Filter = "Icon pack ZIP (*.zip)|*.zip" }) { if (picker.ShowDialog(this) == DialogResult.OK) source = picker.FileName; }
            else using (FolderBrowserDialog picker = new FolderBrowserDialog { Description = "Choose one theme folder containing app-named PNG or ICO files.", ShowNewFolderButton = false }) { if (picker.ShowDialog(this) == DialogResult.OK) source = picker.SelectedPath; }
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
            try { using (PackEditor editor = new PackEditor(library, useSelected ? SelectedTheme : null, edit)) if (editor.ShowDialog(this) == DialogResult.OK) { ReloadLibrary(editor.Saved.Id); status.Text = "Saved " + editor.Saved.Name + ". Choose Apply icons to change shortcuts."; } }
            finally { SetBusy(false, null); }
        }
        void RemovePack()
        {
            if (busy || SelectedTheme == null || SelectedTheme.IsDefault) return;
            ThemeEntry selected = SelectedTheme;
            string note = "Remove " + selected + " from your library? Applied shortcut icons will stay as they are." + (selected.Managed ? "" : " You can restore built-in packs later.");
            if (MessageBox.Show(this, note, "Remove icon pack", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
            try { library.Remove(selected); ReloadLibrary(null); status.Text = "Pack removed from your library."; }
            catch (Exception error) { Report(error); }
        }
    }
}
