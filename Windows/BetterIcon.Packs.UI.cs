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
            if (basis != null) foreach (ThemeIcon icon in basis.Icons) files[icon.Application] = icon.Path;
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
        RowStyle packPreviewRow;
        readonly Label packDetails = new Label();
        readonly TrackBar iconSizeSlider = new TrackBar();
        readonly Label iconSizeValue = new Label();
        readonly Button resetIconSize = new Button();
        readonly List<Button> packButtons = new List<Button>();
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
            preferences.IconSize = iconSizeSlider.Value;
            iconSizeValue.Text = preferences.IconSize + " px";
            ResizeAppIcons(); ResizePackIcons();
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
        void BuildSettingsPage(bool testing)
        {
            TableLayoutPanel layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(18), ColumnCount = 1, RowCount = 10, AutoScroll = true };
            foreach (int height in new[] { 32, 42, 84, 170, 44, 44, 36, 48, 50, 60 }) layout.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
            packPreviewRow = layout.RowStyles[3];
            settingsPage.Controls.Add(layout);
            layout.Controls.Add(new Label { Text = "Icon packs", Font = new Font(Font, FontStyle.Bold), Dock = DockStyle.Fill }, 0, 0);
            TableLayoutPanel choice = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2 };
            choice.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 64)); choice.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 36));
            themes.DropDownStyle = ComboBoxStyle.DropDownList; themes.Dock = DockStyle.Fill; themes.AccessibleName = "Icon pack";
            themes.SelectedIndexChanged += delegate { if (!fillingThemes) { RenderApps(); RenderPack(); SavePreferences(); BuildTrayMenu(); } };
            packDetails.Dock = DockStyle.Fill; packDetails.TextAlign = ContentAlignment.MiddleLeft;
            choice.Controls.Add(themes, 0, 0); choice.Controls.Add(packDetails, 1, 0); layout.Controls.Add(choice, 0, 1);
            FlowLayoutPanel actions = new FlowLayoutPanel { Dock = DockStyle.Fill };
            actions.Controls.Add(PackButton("Import folder...", 132, delegate { ImportPack(false); }));
            actions.Controls.Add(PackButton("Import ZIP...", 116, delegate { ImportPack(true); }));
            actions.Controls.Add(PackButton("Export ZIP...", 116, ExportPack));
            actions.Controls.Add(PackButton("New pack...", 116, delegate { EditPack(false, false); }));
            actions.Controls.Add(PackButton("Customize...", 120, delegate { EditPack(true, false); }));
            actions.Controls.Add(PackButton("Edit pack...", 110, delegate { EditPack(true, true); }));
            actions.Controls.Add(PackButton("Remove pack", 125, RemovePack));
            actions.Controls.Add(PackButton("Restore built-in packs", 190, delegate { try { library.RestoreBundled(); ReloadLibrary(null); } catch (Exception error) { Report(error); } }));
            layout.Controls.Add(actions, 0, 2);
            packPictures.ImageSize = new Size(preferences.IconSize, preferences.IconSize); packPictures.ColorDepth = ColorDepth.Depth32Bit;
            if (packPictures.Handle == IntPtr.Zero) throw new InvalidOperationException("Could not create pack previews.");
            packPreview.Dock = DockStyle.Fill; packPreview.SetIconSize(preferences.IconSize); packPreview.LargeImageList = packPictures;
            packPreview.MultiSelect = false; packPreview.HideSelection = false; packPreview.ShowItemToolTips = true;
            packPreview.BorderStyle = BorderStyle.None; packPreview.BackColor = Color.White; packPreview.AccessibleName = "Icon pack preview";
            layout.Controls.Add(packPreview, 0, 3);
            FlowLayoutPanel locations = new FlowLayoutPanel { Dock = DockStyle.Fill };
            locations.Controls.Add(new Label { Text = "Apply icons to", AutoSize = true, Margin = new Padding(0, 9, 12, 0) });
            scopes.DropDownStyle = ComboBoxStyle.DropDownList; scopes.Width = 300; scopes.AccessibleName = "Shortcut locations";
            scopes.Items.AddRange(new object[] { "My Desktop and Start menu", "Shared shortcuts (administrator)" }); scopes.SelectedIndex = preferences.Scope == "AllUsers" ? 1 : 0; scopes.SelectedIndexChanged += delegate { SavePreferences(); };
            locations.Controls.Add(scopes); layout.Controls.Add(locations, 0, 4);
            FlowLayoutPanel applyRow = new FlowLayoutPanel { Dock = DockStyle.Fill };
            apply.Text = "Apply icons..."; apply.Width = 140; apply.Height = 34; apply.BackColor = accent; apply.ForeColor = Color.White; apply.FlatStyle = FlatStyle.Flat; apply.Click += async delegate { await ApplyTheme(); };
            restore.Text = "Restore original icons..."; restore.Width = 198; restore.Height = 34; restore.Click += async delegate { await RestoreIcons(); };
            previewLabel.Text = "Preview only until you apply."; previewLabel.AutoSize = true; previewLabel.Margin = new Padding(10, 8, 0, 0);
            applyRow.Controls.AddRange(new Control[] { apply, restore, previewLabel }); layout.Controls.Add(applyRow, 0, 5);
            layout.Controls.Add(new Label { Text = "Launcher", Font = new Font(Font, FontStyle.Bold), Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft }, 0, 6);
            TableLayoutPanel sizing = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 4 };
            sizing.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 86)); sizing.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            sizing.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 66)); sizing.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 90));
            sizing.Controls.Add(new Label { Text = "Icon size", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft }, 0, 0);
            iconSizeSlider.Minimum = Preferences.MinimumIconSize; iconSizeSlider.Maximum = Preferences.MaximumIconSize;
            iconSizeSlider.Value = preferences.IconSize; iconSizeSlider.SmallChange = 8; iconSizeSlider.LargeChange = 16; iconSizeSlider.TickStyle = TickStyle.None;
            iconSizeSlider.Dock = DockStyle.Fill; iconSizeSlider.AccessibleName = "Icon size"; iconSizeSlider.AccessibleDescription = "Size in pixels, from 24 to 128. Updates the Launcher and Settings preview immediately.";
            iconSizeValue.Text = preferences.IconSize + " px"; iconSizeValue.Dock = DockStyle.Fill; iconSizeValue.TextAlign = ContentAlignment.MiddleCenter;
            resetIconSize.Text = "Reset"; resetIconSize.Dock = DockStyle.Fill; resetIconSize.AccessibleName = "Reset icon size";
            resetIconSize.Click += delegate { iconSizeSlider.Value = Preferences.DefaultIconSize; };
            iconSizeSlider.ValueChanged += delegate { ChangeIconSize(); };
            sizing.Controls.Add(iconSizeSlider, 1, 0); sizing.Controls.Add(iconSizeValue, 2, 0); sizing.Controls.Add(resetIconSize, 3, 0); layout.Controls.Add(sizing, 0, 7);
            Panel keyboard = new Panel { Dock = DockStyle.Fill };
            settings.Text = "Configure hotkey..."; settings.Width = 170; settings.Dock = DockStyle.Right;
            settings.Click += delegate { if (hotkey != null) using (HotkeySettingsDialog dialog = new HotkeySettingsDialog(preferences.Hotkey, hotkey.IsRegistered, SaveHotkey)) dialog.ShowDialog(this); };
            subtitle.Dock = DockStyle.Fill; subtitle.TextAlign = ContentAlignment.MiddleLeft; subtitle.AutoEllipsis = true;
            keyboard.Controls.Add(subtitle); keyboard.Controls.Add(settings); layout.Controls.Add(keyboard, 0, 8);
            Panel footer = new Panel { Dock = DockStyle.Fill };
            FlowLayoutPanel buttons = new FlowLayoutPanel { Dock = DockStyle.Right, Width = 240 };
            Button refresh = Button("Refresh apps", 132); refresh.Click += async delegate { await RefreshCatalog(); }; packButtons.Add(refresh);
            exit.Text = "Exit"; exit.Width = 90; exit.Height = 34; exit.Click += delegate { ExitLauncher(); };
            buttons.Controls.Add(refresh); buttons.Controls.Add(exit); status.Dock = DockStyle.Fill; status.Text = testing ? "Test library and shortcuts only." : "Finding installed apps...";
            footer.Controls.Add(status); footer.Controls.Add(buttons); layout.Controls.Add(footer, 0, 9);
        }
        void ReloadLibrary(string selectId)
        {
            if (catalog == null) return;
            string chosen = selectId ?? (SelectedTheme == null ? preferences.Theme : SelectedTheme.Id);
            catalog.Themes = library.VisibleThemes(bundledThemes);
            fillingThemes = true;
            try { themes.Items.Clear(); themes.Items.AddRange(catalog.Themes); themes.SelectedItem = catalog.Themes.FirstOrDefault(t => t.Id == chosen) ?? catalog.Themes.FirstOrDefault(t => t.Name == "Cardboard") ?? catalog.Themes.FirstOrDefault(); }
            finally { fillingThemes = false; }
            RenderApps(); RenderPack(); SavePreferences(); BuildTrayMenu();
        }
        void RenderPack()
        {
            ThemeEntry theme = SelectedTheme;
            packDetails.Text = theme == null ? "No packs. Import or create one." : theme.IconCount + " icons / " + (theme.Managed ? "Personal pack" : "Built-in pack");
            packPreview.BeginUpdate();
            try {
                packPreview.Items.Clear(); packPictures.Images.Clear(); ClearPackArtwork();
                if (theme != null) foreach (ThemeIcon icon in theme.Icons.OrderBy(i => i.Application)) {
                    packArtwork.Add(Thumbnail(icon.Path, Icon, Preferences.MaximumIconSize));
                    packPreview.Items.Add(new ListViewItem(icon.Application, packArtwork.Count - 1) { ToolTipText = icon.Application });
                }
                ResizePackIcons();
            }
            finally { packPreview.EndUpdate(); }
            UpdatePackButtons();
        }
        void ClearPackArtwork() { foreach (Bitmap image in packArtwork) image.Dispose(); packArtwork.Clear(); }
        void ResizePackIcons()
        {
            packPreview.BeginUpdate();
            try {
                ResizeArtwork(packPictures, packArtwork, preferences.IconSize); packPreview.SetIconSize(preferences.IconSize);
                // Leave room for at least one complete row, including names, at the largest size.
                packPreviewRow.Height = Math.Max(170, packPreview.GridCellSize.Height + 12);
                if (packPreview.SelectedItems.Count == 1) packPreview.SelectedItems[0].EnsureVisible();
            }
            finally { packPreview.EndUpdate(); }
        }
        void UpdatePackButtons()
        {
            foreach (Button button in packButtons) button.Enabled = !busy;
            foreach (Button button in packButtons.Where(b => b.Text == "Customize..." || b.Text == "Remove pack")) button.Enabled = !busy && SelectedTheme != null;
            foreach (Button button in packButtons.Where(b => b.Text == "Edit pack..." || b.Text == "Export ZIP...")) button.Enabled = !busy && SelectedTheme != null && SelectedTheme.Managed;
            apply.Enabled = !busy && SelectedTheme != null;
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
            if (busy || (useSelected && SelectedTheme == null) || (edit && !SelectedTheme.Managed)) return;
            SetBusy(true, "Editing icon pack...");
            try { using (PackEditor editor = new PackEditor(library, useSelected ? SelectedTheme : null, edit)) if (editor.ShowDialog(this) == DialogResult.OK) { ReloadLibrary(editor.Saved.Id); status.Text = "Saved " + editor.Saved.Name + ". Choose Apply icons to change shortcuts."; } }
            finally { SetBusy(false, null); }
        }
        void RemovePack()
        {
            if (busy || SelectedTheme == null) return;
            ThemeEntry selected = SelectedTheme;
            string note = "Remove " + selected + " from your library? Applied shortcut icons will stay as they are." + (selected.Managed ? "" : " You can restore built-in packs later.");
            if (MessageBox.Show(this, note, "Remove icon pack", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
            try { library.Remove(selected); ReloadLibrary(null); status.Text = "Pack removed from your library."; }
            catch (Exception error) { Report(error); }
        }
    }
}
