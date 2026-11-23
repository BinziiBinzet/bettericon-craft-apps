using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
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
        // Why the last save failed, or null.
        public Exception LastError { get; private set; }
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
            layout.Controls.Add(new Label { Text = "Choose artwork for apps and for the file types they open. You can apply each separately in Manage Icons.", Dock = DockStyle.Fill }, 0, 2);
            grid.Dock = DockStyle.Fill; grid.AllowUserToAddRows = grid.AllowUserToDeleteRows = grid.AllowUserToResizeRows = false; grid.RowHeadersVisible = false; grid.AutoGenerateColumns = false; grid.SelectionMode = DataGridViewSelectionMode.FullRowSelect; grid.MultiSelect = false;
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "App", HeaderText = "App or file type", Width = 250, ReadOnly = true });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "Artwork", HeaderText = "Artwork", AutoSizeMode = DataGridViewAutoSizeColumnMode.Fill, ReadOnly = true });
            grid.Columns.Add(new DataGridViewButtonColumn { Name = "Choose", HeaderText = "", Text = "Choose...", UseColumnTextForButtonValue = true, Width = 90 });
            grid.Columns.Add(new DataGridViewButtonColumn { Name = "Clear", HeaderText = "", Text = "Clear", UseColumnTextForButtonValue = true, Width = 65 });
            if (basis != null) foreach (ThemeIcon icon in basis.Icons) files[icon.Application] = String.IsNullOrEmpty(icon.PreviewPath) ? icon.Path : icon.PreviewPath;
            // A personal pack keeps one entry for each format, so every icon can be replaced on its own.
            if (basis != null) foreach (var icon in ProjectFormat.Artwork(basis).Expanded()) files[icon.Key] = icon.Value;
            // Art for the file types outside BetterIcon's list stays with the pack through every edit. The grid does not list it.
            if (basis != null) foreach (var icon in ProjectFormat.Artwork(basis).Unlisted) files[PackLibrary.UnlistedKey(icon.Key)] = icon.Value;
            foreach (string app in PackLibrary.Applications.OrderBy(a => a)) grid.Rows.Add(app, files.ContainsKey(app) ? Path.GetFileName(files[app]) : "Not assigned");
            foreach (var type in ProjectFormat.All) {
                int row = grid.Rows.Add(type.Label + " (" + type.Application + ")", files.ContainsKey(type.Key) ? Path.GetFileName(files[type.Key]) : "Not assigned");
                grid.Rows[row].Tag = type.Key;
                grid.Rows[row].Cells[0].ToolTipText = String.Join(", ", type.Extensions);
            }
            grid.CellContentClick += delegate(object sender, DataGridViewCellEventArgs e) {
                if (e.RowIndex < 0) return;
                string app = (string)(grid.Rows[e.RowIndex].Tag ?? grid.Rows[e.RowIndex].Cells[0].Value);
                if (e.ColumnIndex == 2) using (OpenFileDialog picker = new OpenFileDialog { Title = "Icon for " + app, Filter = "Icon artwork (*.svg;*.png;*.ico;*.webp)|*.svg;*.png;*.ico;*.webp", CheckFileExists = true }) {
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
                catch (Exception failure) { LastError = failure; error.Text = failure.Message; }
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

    // Consume editing commands before the popup's Escape/navigation handling.
    public sealed class IconSizeTextBox : TextBox
    {
        public event Action CommitRequested, CancelRequested;
        protected override bool ProcessCmdKey(ref Message message, Keys keyData)
        {
            if (keyData == Keys.Enter) { if (CommitRequested != null) CommitRequested(); return true; }
            if (keyData == Keys.Escape) { if (CancelRequested != null) CancelRequested(); return true; }
            return base.ProcessCmdKey(ref message, keyData);
        }
    }

    // Four buttons that share one row. They take equal shares while every label fits, then
    // shares in proportion to their labels, then less padding, and two rows of two before
    // any label is cut off.
    sealed class ButtonRow
    {
        const int Roomy = 10, Tight = 5;
        readonly TableLayoutPanel table;
        readonly Button[] row, grid;
        readonly int group;
        readonly HashSet<Button> hidden = new HashSet<Button>();
        string arrangement;

        // row lists the buttons left to right. grid lists them row by row for two rows of two.
        // group is 2 when each pair keeps half the width, or 4 when all four share it.
        public ButtonRow(TableLayoutPanel table, Button[] row, Button[] grid, int group)
        {
            this.table = table; this.row = row; this.grid = grid; this.group = group;
            foreach (Button button in row) table.Controls.Add(button);
            Arrange(1 << 20);
        }
        public void Show(Button button, bool visible)
        {
            if (visible) hidden.Remove(button); else hidden.Add(button);
            button.Visible = visible;
        }
        // Shares in proportion to each label within its group. False when a group does not fit.
        bool Proportional(int[] needed, int width, float[] share)
        {
            for (int start = 0; start < 4; start += group) {
                int total = 0;
                for (int i = start; i < start + group; i++) total += needed[i];
                if (total > width * group / 4) return false;
                for (int i = start; i < start + group; i++)
                    if (needed[i] > 0 && needed[i ^ 1] > 0) share[i] = 25F * group * needed[i] / total;
                    else if (needed[i] > 0) share[i] = share[i ^ 1] = 12.5F * group * needed[i] / total;
            }
            return true;
        }
        public void Arrange(int width)
        {
            // The width each button needs with its normal padding, margins included.
            int[] needed = row.Select(button => hidden.Contains(button) ? 0 : button.GetPreferredSize(Size.Empty).Width - button.Padding.Horizontal + 2 * Roomy + button.Margin.Horizontal).ToArray();
            float[] share = { 25, 25, 25, 25 };
            int padding = Roomy;
            bool equal = true, oneRow = true;
            for (int i = 0; i < 4; i++)
                // A button whose partner is hidden takes both of their places.
                if (needed[i] > (needed[i ^ 1] == 0 ? width / 2 : width / 4)) equal = false;
            if (!equal && !Proportional(needed, width, share)) {
                padding = Tight;
                if (!Proportional(needed.Select(value => value == 0 ? 0 : value - 2 * (Roomy - Tight)).ToArray(), width, share)) { oneRow = false; padding = Roomy; }
            }
            int columns = oneRow ? 4 : 2, rows = oneRow ? 1 : 2;
            if (!oneRow) share = new float[] { 50, 50 };
            string next = padding + " " + String.Join(" ", share.Select(value => value.ToString("0.##", CultureInfo.InvariantCulture))) + " " + String.Join("", needed.Select(value => value == 0 ? "0" : "1"));
            if (next == arrangement) return;
            arrangement = next;
            table.SuspendLayout();
            try {
                Button[] order = oneRow ? row : grid;
                foreach (Button button in order) table.SetColumnSpan(button, 1);
                table.ColumnCount = Math.Max(table.ColumnCount, columns); table.RowCount = Math.Max(table.RowCount, rows);
                for (int i = 0; i < order.Length; i++) {
                    table.SetCellPosition(order[i], new TableLayoutPanelCellPosition(i % columns, i / columns));
                    // A second row sits a little below the first.
                    order[i].Margin = new Padding(order[i].Margin.Left, i >= columns ? 6 : 0, order[i].Margin.Right, 0);
                    order[i].Padding = new Padding(padding, order[i].Padding.Top, padding, order[i].Padding.Bottom);
                }
                table.ColumnCount = columns; table.RowCount = rows;
                table.ColumnStyles.Clear(); table.RowStyles.Clear();
                foreach (float value in share) table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, value));
                for (int i = 0; i < rows; i++) table.RowStyles.Add(new RowStyle(SizeType.AutoSize));
                if (oneRow) for (int i = 0; i < 4; i++) if (needed[i] > 0 && needed[i ^ 1] == 0) table.SetColumnSpan(row[i], 2);
            }
            finally { table.ResumeLayout(); }
        }
    }

    public sealed partial class LauncherForm
    {
        readonly TabControl pages = new ThemedTabControl();
        readonly TabPage launcherPage = new TabPage("Launcher"), settingsPage = new TabPage("Manage Icons");
        readonly IconGridView packPreview = new IconGridView(), filePreview = new IconGridView();
        readonly List<Bitmap> packArtwork = new List<Bitmap>(), fileArtwork = new List<Bitmap>();
        readonly List<ArtworkSource> packSources = new List<ArtworkSource>(), fileSources = new List<ArtworkSource>();
        readonly Panel settingsScroll = new Panel();
        readonly TableLayoutPanel settingsContent = new TableLayoutPanel(), previews = new TableLayoutPanel();
        readonly ContextMenuStrip importPackMenu = new ContextMenuStrip(), managePackMenu = new ContextMenuStrip(), manageFilePackMenu = new ContextMenuStrip();
        readonly Label packDetails = new Label(), filePackDetails = new Label();
        readonly Button applyFiles = new Button(), restoreFiles = new Button();
        readonly TrackBar iconSizeSlider = new TrackBar();
        readonly TextBox iconSizeValue = new IconSizeTextBox();
        readonly Button resetIconSize = new Button();
        readonly CheckBox showAppNames = new CheckBox();
        readonly Button removePackButton = new Button(), removeFilePackButton = new Button();
        readonly Button refreshPacksButton = new Button();
        readonly LinkLabel appVersion = new LinkLabel();
        bool arrangingManageIcons;
        ButtonRow packActionRow, applyActionRow;
        int buttonRowWidth = 1 << 20;
        readonly List<Button> packButtons = new List<Button>();
        int iconWheelDelta;
        PackLibrary library;
        ThemeEntry[] bundledThemes = new ThemeEntry[0];
        bool fillingThemes, fillingFileThemes;
        const string OriginalFileIcons = "Original file icons";
        bool sliderAlignmentQueued;
        [StructLayout(LayoutKind.Sequential)] struct TrackbarRect { public int Left, Top, Right, Bottom; }
        [DllImport("user32.dll", EntryPoint = "SendMessageW")] static extern IntPtr SendTrackbarRect(IntPtr window, int message, IntPtr wParam, ref TrackbarRect rect);
        // The native channel sits above the middle of the trackbar and its pointed thumb hangs below it, at sizes that
        // follow the DPI. Once the row is laid out, the slider is placed from its own channel and thumb, so that their
        // shared middle is on the middle of the row's text at any DPI, not only at the one a fixed margin suits.
        void QueueSliderAlignment()
        {
            if (sliderAlignmentQueued || !IsHandleCreated || IsDisposed || Disposing) return;
            sliderAlignmentQueued = true;
            BeginInvoke(new Action(delegate { sliderAlignmentQueued = false; AlignIconSizeSlider(); }));
        }
        void AlignIconSizeSlider()
        {
            Control row = iconSizeSlider.Parent;
            if (row == null || !iconSizeSlider.IsHandleCreated || IsDisposed || Disposing) return;
            TrackbarRect channel = new TrackbarRect(), thumb = new TrackbarRect();
            SendTrackbarRect(iconSizeSlider.Handle, 0x041A, IntPtr.Zero, ref channel); // TBM_GETCHANNELRECT
            SendTrackbarRect(iconSizeSlider.Handle, 0x0419, IntPtr.Zero, ref thumb);   // TBM_GETTHUMBRECT
            if (channel.Bottom <= channel.Top || thumb.Bottom <= thumb.Top) return;
            // The middles of the label, the number and its unit, and Reset, as the row lays them out.
            var middles = new List<double>();
            foreach (Control peer in row.Controls) {
                if (peer == iconSizeSlider || !peer.Visible) continue;
                if (peer is TableLayoutPanel) foreach (Control inner in peer.Controls) middles.Add(peer.Top + inner.Top + inner.Height / 2.0);
                else middles.Add(peer.Top + peer.Height / 2.0);
            }
            if (middles.Count == 0) return;
            double inside = (channel.Top + channel.Bottom + thumb.Top + thumb.Bottom) / 4.0;
            int top = Math.Max(0, (int)Math.Round(middles.Average() - inside, MidpointRounding.AwayFromZero));
            if (iconSizeSlider.Margin.Top != top || iconSizeSlider.Margin.Bottom != 0) iconSizeSlider.Margin = new Padding(iconSizeSlider.Margin.Left, top, iconSizeSlider.Margin.Right, 0);
        }

        void DrawPageTab(object sender, DrawItemEventArgs e)
        {
            bool selected = pages.SelectedIndex == e.Index;
            AppearancePalette palette = appearancePalette ?? AppAppearance.Resolve(preferences.AppearanceMode, style: preferences.AppIconStyle);
            Color background = selected ? palette.Surface : palette.InactiveTab, foreground = selected ? palette.Text : palette.Muted;
            if (SystemInformation.HighContrast) { background = selected ? SystemColors.Highlight : SystemColors.Control; foreground = selected ? SystemColors.HighlightText : SystemColors.ControlText; }
            // Round the two outer corners; keep the shared center divider straight.
            // Top-only rounding can exceed half the tab's height.
            Rectangle bounds = e.Bounds;
            float radius = Math.Min(32f, Math.Min(bounds.Height, bounds.Width / 2f));
            float leftRadius = e.Index == 0 ? radius : 0, rightRadius = e.Index == pages.TabCount - 1 ? radius : 0;
            using (GraphicsPath shape = new GraphicsPath()) using (Brush brush = new SolidBrush(background)) {
                shape.AddLine(bounds.Left, bounds.Bottom, bounds.Left, bounds.Top + leftRadius);
                if (leftRadius > 0) shape.AddArc(bounds.Left, bounds.Top, leftRadius * 2, leftRadius * 2, 180, 90);
                shape.AddLine(bounds.Left + leftRadius, bounds.Top, bounds.Right - rightRadius, bounds.Top);
                if (rightRadius > 0) shape.AddArc(bounds.Right - rightRadius * 2, bounds.Top, rightRadius * 2, rightRadius * 2, 270, 90);
                shape.AddLine(bounds.Right, bounds.Top + rightRadius, bounds.Right, bounds.Bottom);
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
            SyncIconSizeValue();
            try { ResizeAppIcons(); ResizePackIcons(); ResizeFileIcons(); }
            catch (Exception error) {
                if (!(error is OutOfMemoryException) && !(error is System.Runtime.InteropServices.ExternalException)) throw;
                previous = Math.Min(previous, iconSizeSlider.Maximum);
                preferences.IconSize = previous; iconSizeSlider.Value = previous;
                status.Text = "Could not display that size. Try a smaller size."; return;
            }
            try { WritePreferences(); status.Text = "Launcher icon size saved."; }
            catch (IOException) { status.Text = "Launcher icon size changed for this session, but could not be saved."; }
            catch (UnauthorizedAccessException) { status.Text = "Launcher icon size changed for this session, but could not be saved."; }
        }
        void SyncIconSizeValue()
        {
            iconSizeValue.Text = iconSizeSlider.Value.ToString(CultureInfo.InvariantCulture);
            iconSizeValue.AccessibleDescription = "Enter a whole number from " + iconSizeSlider.Minimum + " to " + iconSizeSlider.Maximum + " pixels. Enter applies; Escape cancels. Updates both tabs.";
        }
        void CommitIconSizeValue()
        {
            if (busy || !iconSizeValue.Enabled) { SyncIconSizeValue(); return; }
            int requested;
            if (!Int32.TryParse(iconSizeValue.Text.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out requested)) {
                SyncIconSizeValue();
                status.Text = "Enter a whole number from " + iconSizeSlider.Minimum + " to " + iconSizeSlider.Maximum + " px.";
            }
            else {
                int value = Math.Max(iconSizeSlider.Minimum, Math.Min(iconSizeSlider.Maximum, requested));
                if (iconSizeSlider.Value != value) iconSizeSlider.Value = value;
                else { SyncIconSizeValue(); status.Text = "Launcher icon size: " + value + " px."; }
            }
            if (iconSizeValue.Focused) iconSizeValue.SelectAll();
        }
        void CancelIconSizeValue() { SyncIconSizeValue(); iconSizeValue.SelectAll(); }
        void ChangeAppNames()
        {
            preferences.ShowAppNames = showAppNames.Checked;
            apps.ShowAppNames = packPreview.ShowAppNames = filePreview.ShowAppNames = preferences.ShowAppNames;
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
        void DrawRefreshPacksButton(object sender, PaintEventArgs e)
        {
            Button button = (Button)sender;
            Color disabled = appearancePalette == null || appearancePalette.HighContrast ? SystemColors.GrayText : appearancePalette.Muted;
            Color color = button.Enabled ? button.ForeColor : disabled;
            float scale = Math.Min(button.ClientSize.Width, button.ClientSize.Height) / 32f;
            Graphics canvas = e.Graphics;
            GraphicsState saved = canvas.Save();
            try {
                canvas.SmoothingMode = SmoothingMode.AntiAlias;
                if (packUpdateCheck != null && packUpdateCheck.Count > 0) {
                    float diameter = Math.Max(5f, 7f * scale);
                    float inset = Math.Max(2f, 2.5f * scale);
                    var badge = new RectangleF(button.ClientSize.Width - inset - diameter, inset, diameter, diameter);
                    Color accentColor = appearancePalette == null ? SystemColors.Highlight : appearancePalette.Accent;
                    using (var fill = new SolidBrush(accentColor)) canvas.FillEllipse(fill, badge);
                    using (var edge = new Pen(button.ForeColor)) canvas.DrawEllipse(edge, badge);
                }
                canvas.TranslateTransform(button.ClientSize.Width / 2f - 12f * scale, button.ClientSize.Height / 2f - 12f * scale);
                canvas.ScaleTransform(scale, scale);
                using (Pen pen = new Pen(color, 2f) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round }) {
                    canvas.DrawLines(pen, new[] { new PointF(4.3f, 10.1f), new PointF(4.3f, 8.8f), new PointF(5f, 7.1f), new PointF(6.8f, 6.4f), new PointF(19.7f, 6.4f) });
                    canvas.DrawLines(pen, new[] { new PointF(15.8f, 3.3f), new PointF(19.7f, 6.4f), new PointF(15.8f, 9.5f) });
                    canvas.DrawLines(pen, new[] { new PointF(19.7f, 13.9f), new PointF(19.7f, 15.2f), new PointF(19f, 16.9f), new PointF(17.2f, 17.6f), new PointF(4.3f, 17.6f) });
                    canvas.DrawLines(pen, new[] { new PointF(8.2f, 14.5f), new PointF(4.3f, 17.6f), new PointF(8.2f, 20.7f) });
                }
            }
            finally { canvas.Restore(saved); }
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
            packs.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            // App packs and file type packs share one row, with a single refresh for both lists.
            TableLayoutPanel pickerRow = SettingsTable(3);
            pickerRow.Name = "PackPickers"; pickerRow.Margin = new Padding(0, 0, 0, 10);
            pickerRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            pickerRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            pickerRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            pickerRow.RowCount = 3;
            for (int i = 0; i < 3; i++) pickerRow.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            pickerRow.Controls.Add(new Label { Text = "App icon pack", AutoSize = true, Font = new Font(Font, FontStyle.Bold), Margin = new Padding(0, 0, 0, 8) }, 0, 0);
            pickerRow.Controls.Add(new Label { Text = "File type icon pack", AutoSize = true, Font = new Font(Font, FontStyle.Bold), Margin = new Padding(6, 0, 0, 8) }, 1, 0);
            themes.DropDownStyle = ComboBoxStyle.DropDownList; themes.Dock = DockStyle.Top; themes.Margin = new Padding(0, 0, 6, 5); themes.AccessibleName = "Icon pack";
            themes.AccessibleDescription = "Click a pack or press Enter to load it. Packs marked Download will be fetched. Right-click for pack actions.";
            themes.PackChosen += delegate { SelectPack(); };
            fileThemes.DropDownStyle = ComboBoxStyle.DropDownList; fileThemes.Dock = DockStyle.Top; fileThemes.Margin = new Padding(6, 0, 0, 5); fileThemes.AccessibleName = "File type icon pack";
            fileThemes.AccessibleDescription = "Click a pack or press Enter to load it. Packs marked Download will be fetched. Right-click for pack actions.";
            fileThemes.PackChosen += delegate { SelectFilePack(); };
            refreshPacksButton.Name = "RefreshPacksButton";
            refreshPacksButton.AccessibleName = "Refresh available icon packs";
            refreshPacksButton.Size = new Size(28, themes.Height);
            refreshPacksButton.MinimumSize = new Size(0, themes.Height);
            refreshPacksButton.Dock = DockStyle.Fill; refreshPacksButton.Margin = new Padding(6, 0, 0, 5);
            // The owner-drawn combo can grow when its native handle or font changes.
            themes.SizeChanged += delegate {
                if (refreshPacksButton.MinimumSize.Height != themes.Height)
                    refreshPacksButton.MinimumSize = new Size(0, themes.Height);
            };
            refreshPacksButton.Paint += DrawRefreshPacksButton;
            refreshPacksButton.Click += async delegate { await ReadCatalog(true); await RestoreChosenPacks(); };
            appearanceTips.SetToolTip(refreshPacksButton, refreshPacksButton.AccessibleName);
            packButtons.Add(refreshPacksButton);
            pickerRow.Controls.Add(themes, 0, 1);
            pickerRow.Controls.Add(fileThemes, 1, 1);
            pickerRow.Controls.Add(refreshPacksButton, 2, 1);
            foreach (Label details in new[] { packDetails, filePackDetails }) {
                details.AutoSize = false; details.AutoEllipsis = true; details.Height = Font.Height + 4; details.Dock = DockStyle.Top;
            }
            packDetails.Margin = new Padding(0, 0, 6, 0); packDetails.AccessibleName = "App icon pack details";
            filePackDetails.Margin = new Padding(6, 0, 0, 0); filePackDetails.AccessibleName = "File type icon pack details";
            pickerRow.Controls.Add(packDetails, 0, 2);
            pickerRow.Controls.Add(filePackDetails, 1, 2);
            SettingsRow(packs, pickerRow);
            TableLayoutPanel actions = SettingsTable(4); actions.Name = "PackActions"; actions.Margin = new Padding(0, 0, 0, 10);
            Button import = PackButton("Import...", 120, delegate { });
            importPackMenu.Items.Add("From ZIP...", null, delegate { ImportPack(true); });
            importPackMenu.Items.Add("From folder...", null, delegate { ImportPack(false); });
            import.Click += delegate { importPackMenu.Show(import, new Point(0, import.Height)); };
            Button create = PackButton("New pack...", 120, delegate { EditPack(false, false); });
            managePackMenu.Items.Add("Customize...", null, delegate { EditPack(true, false); });
            managePackMenu.Items.Add("Edit pack...", null, delegate { EditPack(true, true); });
            managePackMenu.Items.Add("Export ZIP...", null, delegate { ExportPack(SelectedTheme); });
            managePackMenu.Items.Add(new ToolStripSeparator());
            managePackMenu.Items.Add("Restore built-in packs", null, delegate { try { library.RestoreBundled(); ReloadLibrary(null); } catch (Exception error) { Report(error); } });
            managePackMenu.Opening += delegate { UpdatePackButtons(); };
            themes.ContextMenuStrip = managePackMenu;
            manageFilePackMenu.Items.Add("Customize...", null, delegate { EditFilePack(false); });
            manageFilePackMenu.Items.Add("Edit pack...", null, delegate { EditFilePack(true); });
            manageFilePackMenu.Items.Add("Export ZIP...", null, delegate { ExportPack(SelectedFileTheme); });
            manageFilePackMenu.Opening += delegate { UpdatePackButtons(); };
            fileThemes.ContextMenuStrip = manageFilePackMenu;
            // Each list has its own remove button, so it is clear which chosen pack goes.
            removePackButton.Text = "Remove app pack"; removePackButton.AccessibleName = "Remove app icon pack";
            removePackButton.Click += delegate { RemovePack(SelectedTheme); };
            removeFilePackButton.Text = "Remove file pack"; removeFilePackButton.AccessibleName = "Remove file type icon pack";
            removeFilePackButton.Click += delegate { RemovePack(SelectedFileTheme); };
            Button[] packActions = { import, create, removePackButton, removeFilePackButton };
            foreach (Button button in packActions) SettingsButton(button);
            packActionRow = new ButtonRow(actions, packActions, packActions, 4);
            SettingsRow(packs, actions);
            settingsContent.Controls.Add(packs, 0, 0);
            // The file type preview shares the row once a file type pack is chosen.
            previews.Name = "PackPreviews"; previews.Dock = DockStyle.Fill; previews.Margin = new Padding(0, 0, 0, 16);
            previews.ColumnCount = 2; previews.RowCount = 1;
            previews.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50)); previews.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            previews.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            foreach (IconGridView preview in new[] { packPreview, filePreview }) {
                preview.Dock = DockStyle.Fill; preview.ShowAppNames = preferences.ShowAppNames; preview.SetIconSize(preferences.IconSize);
                preview.MultiSelect = false; preview.HideSelection = false; preview.ShowItemToolTips = true;
                preview.BorderStyle = BorderStyle.None; preview.BackColor = Color.White;
            }
            packPreview.Margin = Padding.Empty; packPreview.AccessibleName = "Icon pack preview";
            filePreview.Margin = new Padding(12, 0, 0, 0); filePreview.AccessibleName = "File type icon pack preview"; filePreview.Visible = false;
            previews.Controls.Add(packPreview, 0, 0); previews.Controls.Add(filePreview, 1, 0); previews.SetColumnSpan(packPreview, 2);
            settingsContent.Controls.Add(previews, 0, 1);

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
            // This sizes BetterIcon's own grids. Windows keeps its own icon sizes.
            sizing.Controls.Add(new Label { Text = "Launcher icon size", AutoSize = true, Anchor = AnchorStyles.Left, Margin = new Padding(0, 0, 12, 0) }, 0, 0);
            iconSizeSlider.Minimum = Preferences.MinimumIconSize; iconSizeSlider.Maximum = Preferences.MaximumIconSize;
            iconSizeSlider.Value = preferences.IconSize; iconSizeSlider.SmallChange = 8; iconSizeSlider.LargeChange = 16; iconSizeSlider.TickStyle = TickStyle.None;
            // Native trackbars keep their channel near the top when stretched. A compact native control is placed
            // from its own channel and pointed thumb after each layout (AlignIconSizeSlider).
            iconSizeSlider.AutoSize = false; iconSizeSlider.Height = 28; iconSizeSlider.Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top;
            iconSizeSlider.Margin = new Padding(3, 7, 3, 0);
            iconSizeSlider.HandleCreated += delegate { QueueSliderAlignment(); };
            sizing.Layout += delegate { QueueSliderAlignment(); };
            iconSizeSlider.AccessibleName = "Launcher icon size"; iconSizeSlider.AccessibleDescription = "Size in pixels, based on available artwork. Updates both tabs.";
            TableLayoutPanel sizeValue = SettingsTable(2); sizeValue.Dock = DockStyle.None; sizeValue.Anchor = AnchorStyles.None; sizeValue.Margin = new Padding(6, 0, 8, 0);
            sizeValue.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize)); sizeValue.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            iconSizeValue.Width = 64; iconSizeValue.BorderStyle = BorderStyle.FixedSingle; iconSizeValue.TextAlign = HorizontalAlignment.Center;
            iconSizeValue.Anchor = AnchorStyles.None; iconSizeValue.Margin = new Padding(0, 0, 4, 0); iconSizeValue.AccessibleName = "Launcher icon size in pixels";
            SyncIconSizeValue();
            iconSizeValue.Enter += delegate { iconSizeValue.SelectAll(); }; iconSizeValue.Click += delegate { iconSizeValue.SelectAll(); };
            iconSizeValue.Leave += delegate { CommitIconSizeValue(); };
            ((IconSizeTextBox)iconSizeValue).CommitRequested += CommitIconSizeValue;
            ((IconSizeTextBox)iconSizeValue).CancelRequested += CancelIconSizeValue;
            sizeValue.Controls.Add(iconSizeValue, 0, 0);
            sizeValue.Controls.Add(new Label { Text = "px", AutoSize = true, Anchor = AnchorStyles.Left, Margin = Padding.Empty }, 1, 0);
            resetIconSize.Text = "Reset"; SettingsButton(resetIconSize); resetIconSize.AccessibleName = "Reset launcher icon size";
            resetIconSize.Click += delegate { iconSizeSlider.Value = Preferences.DefaultIconSize; };
            iconSizeSlider.ValueChanged += delegate { ChangeIconSize(); };
            sizing.Controls.Add(iconSizeSlider, 1, 0); sizing.Controls.Add(sizeValue, 2, 0); sizing.Controls.Add(resetIconSize, 3, 0);
            SettingsRow(launcher, sizing);
            settingsContent.Controls.Add(launcher, 0, 2);

            TableLayoutPanel shortcuts = SettingsTable(1); shortcuts.Name = "ShortcutsSection";
            // Share the available width equally, whatever each button's own text needs.
            shortcuts.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            // App shortcuts on the left and file types on the right, under their own pack.
            TableLayoutPanel applyRow = SettingsTable(4); applyRow.Name = "ApplyActions";
            apply.Text = "Apply icons..."; apply.Tag = "PrimaryAction"; SettingsButton(apply); apply.BackColor = accent; apply.ForeColor = Color.White; apply.FlatStyle = FlatStyle.Flat; apply.Click += async delegate { await ApplyTheme(); };
            restore.Text = "Restore app defaults..."; SettingsButton(restore); restore.Click += async delegate { await RestoreIcons(); };
            applyFiles.Text = "Apply file icons..."; applyFiles.Tag = "PrimaryAction"; SettingsButton(applyFiles); applyFiles.BackColor = accent; applyFiles.ForeColor = Color.White; applyFiles.FlatStyle = FlatStyle.Flat;
            applyFiles.Click += async delegate { await ChangeFileIcons(SelectedFileTheme == null); };
            restoreFiles.Text = "Restore file icons..."; SettingsButton(restoreFiles); restoreFiles.Click += async delegate { await ChangeFileIcons(true); };
            // In two rows, each pack keeps its own column: apply above restore.
            applyActionRow = new ButtonRow(applyRow, new[] { apply, restore, applyFiles, restoreFiles }, new[] { apply, applyFiles, restore, restoreFiles }, 2);
            SettingsRow(shortcuts, applyRow);
            status.Text = testing ? "Test library and shortcuts only." : ReviewedText;
            status.AutoSize = false; status.Height = Font.Height + 10; status.Dock = DockStyle.Top; status.AutoEllipsis = true;
            status.Margin = new Padding(4, 8, 4, 0); status.AccessibleName = "Status";
            status.TextChanged += delegate { StatusTextChanged(); };
            SettingsRow(shortcuts, status);
            // The row for shared shortcuts that wait for administrator access joins this section the first time it is needed.
            shortcutsSection = shortcuts;
            settingsContent.Controls.Add(shortcuts, 0, 3);

            TableLayoutPanel footer = SettingsTable(3); footer.Name = "ManageIconsFooter"; footer.Padding = new Padding(24, 6, 24, 12);
            footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize)); footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            appVersion.Text = "Better Icon for ArtCraft version " + typeof(LauncherForm).Assembly.GetName().Version.ToString(3);
            ConfigureFooterLink(appVersion, "Open the BetterIcon project on GitHub.");
            appVersion.Anchor = AnchorStyles.Right; appVersion.Margin = new Padding(0, 0, 10, 0);
            appVersion.Links[0].LinkData = "https://github.com/BinziiBinzet/bettericon-craft-apps";
            appVersion.LinkClicked += delegate(object sender, LinkLabelLinkClickedEventArgs e) {
                try {
                    ProcessStartInfo projectPage = new ProcessStartInfo((string)e.Link.LinkData) { UseShellExecute = true };
                    Process browser = Process.Start(projectPage);
                    if (browser != null) browser.Dispose();
                }
                catch (System.ComponentModel.Win32Exception error) { Report(error); }
            };
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
                if (previews.MinimumSize.Height != rowHeight) previews.MinimumSize = new Size(0, rowHeight);
                int width = Math.Max(1, settingsScroll.ClientSize.Width - settingsContent.Padding.Horizontal - SystemInformation.VerticalScrollBarWidth);
                // Decide from the width that remains beside a scroll bar, so the rows do not flip when one appears.
                buttonRowWidth = Math.Max(1, settingsScroll.Width - SystemInformation.VerticalScrollBarWidth - settingsContent.Padding.Horizontal);
                ArrangeButtonRows();
                int minimum = settingsContent.Padding.Vertical + rowHeight + previews.Margin.Vertical;
                foreach (Control control in settingsContent.Controls) if (control != previews)
                    minimum += control.GetPreferredSize(new Size(width, 0)).Height + control.Margin.Vertical;
                int height = Math.Max(settingsScroll.ClientSize.Height, minimum);
                if (settingsContent.Height != height) settingsContent.Height = height;
                settingsScroll.AutoScrollMinSize = new Size(0, minimum);
            }
            finally { arrangingManageIcons = false; }
        }
        void ArrangeButtonRows()
        {
            if (packActionRow != null) packActionRow.Arrange(buttonRowWidth);
            if (applyActionRow != null) applyActionRow.Arrange(buttonRowWidth);
        }
        void ReloadLibrary(string selectId) { ReloadPacks(selectId, null); }
        // A pack with app artwork is an app icon pack; one with file artwork is a file
        // type icon pack. A pack with both appears in each list.
        void ReloadPacks(string selectId, string selectFileId)
        {
            if (catalog == null) return;
            string chosen = catalog.CurrentPackId(selectId ?? wantedThemeId ?? (SelectedTheme == null ? preferences.Theme : SelectedTheme.Id));
            preferences.FileTheme = catalog.CurrentPackId(selectFileId ?? preferences.FileTheme);
            ThemeEntry defaults = new ThemeEntry { Id = ThemeEntry.DefaultThemeId, Name = "ArtCraft default", IsDefault = true, Icons = new ThemeIcon[0], IconCount = catalog.Apps.Select(a => a.Application).Distinct().Count() };
            ThemeEntry[] visible = library.VisibleThemes(bundledThemes).Where(t => !t.IsDefault)
                .OrderBy(t => t.ListAuthor, StringComparer.CurrentCultureIgnoreCase).ThenBy(t => t.Name, StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(t => t.Id, StringComparer.Ordinal).ToArray();
            // A pack whose app icons are all left out stays listed, so its reason and the WebP offer can be seen.
            catalog.Themes = new[] { defaults }.Concat(visible.Where(t => t.OffersAppIcons)).ToArray();
            // A build that carried every pack kept them beside the app. A pack chosen there is no longer on the
            // computer after an upgrade. It stays the saved choice until it has been downloaded again.
            ThemeEntry wanted = catalog.Themes.FirstOrDefault(t => t.Id == chosen && t.NeedsDownload);
            wantedThemeId = wanted != null && wanted.Id != ThemeEntry.OpeningThemeId ? wanted.Id : null;
            fillingThemes = true;
            try { themes.Items.Clear(); themes.Items.AddRange(catalog.Themes); themes.SelectedItem = catalog.Themes.FirstOrDefault(t => t.Id == chosen && !t.NeedsDownload) ?? catalog.Themes.FirstOrDefault(t => t.Name == "Cardboard" && !t.NeedsDownload) ?? defaults; }
            finally { fillingThemes = false; }
            fillingFileThemes = true;
            try {
                fileThemes.Items.Clear(); fileThemes.Items.Add(OriginalFileIcons);
                fileThemes.Items.AddRange(visible.Where(t => t.OffersFileIcons).ToArray());
                ThemeEntry file = fileThemes.Items.OfType<ThemeEntry>().FirstOrDefault(t => t.Id == preferences.FileTheme && !t.NeedsDownload);
                fileThemes.SelectedIndex = file == null ? 0 : fileThemes.Items.IndexOf(file);
            }
            finally { fillingFileThemes = false; }
            RenderSelection(); SavePreferences(); BuildTrayMenu();
            UpdateWebPOffer();
        }
        void ClearFileArtwork() { foreach (Bitmap image in fileArtwork) image.Dispose(); fileArtwork.Clear(); fileSources.Clear(); }
        void ShowFilePreview(bool visible)
        {
            if (filePreview.Visible == visible) return;
            previews.SuspendLayout();
            try { previews.SetColumnSpan(packPreview, visible ? 1 : 2); filePreview.Visible = visible; }
            finally { previews.ResumeLayout(); }
        }
        void RenderFilePack()
        {
            ThemeEntry theme = SelectedFileTheme;
            filePackDetails.Text = FilePackDetails(theme);
            filePreview.BeginUpdate();
            try {
                filePreview.Items.Clear(); ClearFileArtwork();
                foreach (ArtworkRequest tile in FileRequests(theme)) {
                    AddArtwork(fileArtwork, fileSources, tile.Path, 0);
                    filePreview.Items.Add(new ListViewItem(tile.Name, fileArtwork.Count - 1) { ToolTipText = tile.Tooltip });
                }
                if (!renderingArtwork) { UpdateIconSizeLimit(); ResizeFileIcons(); }
            }
            finally { filePreview.EndUpdate(); }
            ShowFilePreview(theme != null);
            UpdatePackButtons();
        }
        void DisplayFilePack(ThemeEntry theme, PreparedArtwork prepared)
        {
            filePreview.BeginUpdate();
            try {
                Display(filePreview, fileArtwork, fileSources, prepared);
                filePackDetails.Text = FilePackDetails(theme);
                UpdateIconSizeLimit(); ResizeAppIcons(); ResizePackIcons(); ResizeFileIcons();
            }
            finally { filePreview.EndUpdate(); }
            ShowFilePreview(theme != null);
            UpdatePackButtons();
        }
        void ResizeFileIcons()
        {
            filePreview.BeginUpdate();
            try {
                EnsureArtworkSize(fileArtwork, fileSources, preferences.IconSize);
                filePreview.SetArtwork(fileArtwork, preferences.IconSize);
            }
            finally { filePreview.EndUpdate(); }
        }
        void RenderPack()
        {
            ThemeEntry theme = SelectedTheme;
            packDetails.Text = PackDetails(theme);
            packPreview.BeginUpdate();
            try {
                packPreview.Items.Clear(); ClearPackArtwork();
                if (theme != null && theme.IsDefault) foreach (AppEntry app in catalog.Apps.GroupBy(a => a.Application).Select(g => g.First()).OrderBy(a => !AppOrder.Leads(a.Application)).ThenBy(a => a.Application)) {
                    AddArtwork(packArtwork, packSources, app.OriginalIconPath, app.OriginalIconIndex);
                    packPreview.Items.Add(new ListViewItem(app.Application, packArtwork.Count - 1) { Tag = app.Application, ToolTipText = app.Application + " - ArtCraft default" });
                }
                else if (theme != null) foreach (ThemeIcon icon in theme.Icons.OrderBy(i => !AppOrder.Leads(i.Application)).ThenBy(i => i.Application)) {
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
            if (applyActionRow != null) applyActionRow.Show(restore, !defaults);
            apply.Enabled = !busy && SelectedTheme != null;
            ThemeEntry files = SelectedFileTheme;
            foreach (ToolStripItem item in manageFilePackMenu.Items) {
                bool needsPersonal = item.Text == "Edit pack..." || item.Text == "Export ZIP...";
                item.Enabled = !busy && files != null && (!needsPersonal || files.Managed);
            }
            removeFilePackButton.Enabled = !busy && files != null;
            // With the original file icons chosen, the one action is to put them back.
            applyFiles.Text = files == null ? "Restore original file icons..." : "Apply file icons...";
            // Only applying a pack is the accented action; putting icons back is a plain button.
            string role = files == null ? null : "PrimaryAction";
            if (!Object.Equals(applyFiles.Tag, role)) {
                applyFiles.Tag = role;
                if (appearancePalette != null) AppAppearance.Apply(applyFiles, appearancePalette);
            }
            if (applyActionRow != null) applyActionRow.Show(restoreFiles, files != null);
            applyFiles.Enabled = !busy && (files == null || filePreview.Items.Count > 0);
            restoreFiles.Enabled = !busy;
            // A changed label or a hidden button can change which arrangement fits.
            ArrangeButtonRows();
        }
        async Task ChooseAppIcon(AppEntry target)
        {
            if (busy || !PackLibrary.Applications.Contains(target.Application)) return;
            using (OpenFileDialog picker = new OpenFileDialog { Title = "Choose icon for " + target.Application, Filter = "Icon artwork (*.svg;*.png;*.ico;*.webp)|*.svg;*.png;*.ico;*.webp", CheckFileExists = true, Multiselect = false, RestoreDirectory = true }) {
                if (picker.ShowDialog(this) != DialogResult.OK) return;
                try { await ChangeAppIcon(target, picker.FileName); }
                catch (Exception error) { NoteWebPFailure(error); Report(error); }
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
                bool filesUsePack = SelectedFileTheme != null && SelectedFileTheme.Managed && SelectedFileTheme.LibraryId == saved.LibraryId;
                ReloadPacks(saved.Id, filesUsePack ? saved.Id : null);
                status.Text = "Saved " + target.Application + " icon in " + saved.Name + ". Choose Apply icons to change Windows shortcuts.";
            }
            finally { SetBusy(false, null); }
        }
        async void ImportPack(bool zip)
        {
            if (busy) return;
            string source = null;
            if (zip) using (OpenFileDialog picker = new OpenFileDialog { Title = "Import one icon theme", Filter = "Icon pack ZIP (*.zip)|*.zip" }) { if (picker.ShowDialog(this) == DialogResult.OK) source = picker.FileName; }
            else using (FolderBrowserDialog picker = new FolderBrowserDialog { Description = "Choose one theme folder containing app-named SVG, PNG, ICO or WebP files.", ShowNewFolderButton = false }) { if (picker.ShowDialog(this) == DialogResult.OK) source = picker.SelectedPath; }
            if (source == null) return;
            await ImportPackFrom(source);
        }
        async Task ImportPackFrom(string source)
        {
            SetBusy(true, "Importing icon pack...");
            try { ThemeEntry added = await Task.Run(() => library.Import(source)); ShowSavedPack(added); }
            // A pack whose WebP this PC can't read offers WebP support beside the status line once the message closes.
            catch (Exception error) { NoteWebPFailure(error); Report(error); }
            finally { SetBusy(false, null); }
        }
        async void ExportPack(ThemeEntry selected)
        {
            if (busy || selected == null || !selected.Managed) return;
            string destination;
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
            try {
                using (PackEditor editor = new PackEditor(library, useSelected ? SelectedTheme : null, edit)) {
                    ApplyDialogAppearance(editor);
                    if (editor.ShowDialog(this) == DialogResult.OK) ShowSavedPack(editor.Saved);
                    // The editor named a WebP this PC can't read: WebP support is offered beside the status line.
                    else NoteWebPFailure(editor.LastError);
                }
            }
            finally { SetBusy(false, null); }
        }
        void RemovePack(ThemeEntry selected)
        {
            if (busy || selected == null || selected.IsDefault) return;
            string note = "Remove " + selected + " from your library? Applied icons will stay as they are."
                // One pack can hold both kinds of artwork; removing it takes it out of both lists.
                + (selected.IconCount > 0 && selected.OffersFileIcons ? " It leaves both the app and the file type list." : "")
                + (selected.Managed ? "" : " You can restore built-in packs later.");
            if (!AppAppearance.Message(this, "Remove icon pack", note, appearancePalette, true)) return;
            try {
                library.Remove(selected);
                if (preferences.FileTheme == selected.Id) preferences.FileTheme = null;
                ReloadLibrary(null); status.Text = "Pack removed from your library.";
            }
            catch (Exception error) { Report(error); }
        }
        void EditFilePack(bool edit)
        {
            ThemeEntry selected = SelectedFileTheme;
            if (busy || selected == null || (edit && !selected.Managed)) return;
            SetBusy(true, "Editing icon pack...");
            try { using (PackEditor editor = new PackEditor(library, selected, edit)) { ApplyDialogAppearance(editor); if (editor.ShowDialog(this) == DialogResult.OK) ShowSavedPack(editor.Saved, true); } }
            finally { SetBusy(false, null); }
        }
    }
}
