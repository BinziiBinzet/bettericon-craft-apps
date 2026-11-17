using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

namespace BetterIcon.Tray
{
    // ComboBox's Framework preferred size omits owner-drawn item height.
    // TableLayoutPanel must reserve the same height that the native control uses.
    public sealed class AppearanceComboBox : ComboBox
    {
        public AppearanceComboBox() { DrawMode = DrawMode.OwnerDrawFixed; FlatStyle = FlatStyle.Flat; ItemHeight = 24; }
        protected override void OnFontChanged(EventArgs e) { base.OnFontChanged(e); ItemHeight = Math.Max(24, Font.Height + 6); }
        public override Size GetPreferredSize(Size proposedSize)
        {
            Size size = base.GetPreferredSize(proposedSize);
            if (DrawMode != DrawMode.Normal) size.Height = Math.Max(size.Height, Math.Max(Height, ItemHeight + 8));
            return size;
        }
    }
    public static class AppBranding
    {
        public static readonly string[] Styles = { "clay", "copper", "mauve", "ochre", "sage", "slate", "stone", "teal" };
        public static string Variant(string preference, bool dark) { return preference == "Dark" ? "dark" : preference == "Light" ? "light" : dark ? "dark" : "light"; }
        public static string ResourceName(string style, string variant) { return "BetterIcon.AppIcons." + style + "." + variant + ".ico"; }
        public static Icon Load(string style, string variant, int size = 256)
        {
            if (!Styles.Contains(style) || (variant != "dark" && variant != "light")) throw new ArgumentException("Unknown BetterIcon app icon.");
            using (Stream stream = typeof(AppBranding).Assembly.GetManifestResourceStream(ResourceName(style, variant))) {
                if (stream == null) throw new IOException("The BetterIcon app icon resource is missing.");
                using (Icon icon = new Icon(stream, size, size)) return (Icon)icon.Clone();
            }
        }
        public static Bitmap Preview(string style, string variant, int size)
        {
            Bitmap output = new Bitmap(size, size);
            using (Icon icon = Load(style, variant, size)) using (Graphics canvas = Graphics.FromImage(output)) {
                canvas.Clear(Color.Transparent); canvas.DrawIcon(icon, new Rectangle(0, 0, size, size));
            }
            return output;
        }
        public static string Title(string style) { return Char.ToUpperInvariant(style[0]) + style.Substring(1); }
    }

    public sealed class AppearancePalette
    {
        public bool Dark, HighContrast;
        public Color Background, Surface, Input, Text, Muted, Border, Accent, Selection, SelectionText, InactiveTab, Error;
    }

    public static class AppAppearance
    {
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr window, string application, string idList);
        sealed class Hook { public AppearancePalette Palette; }
        static readonly ConditionalWeakTable<Control, Hook> hooks = new ConditionalWeakTable<Control, Hook>();
        public static bool SystemIsDark()
        {
            try { using (RegistryKey key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")) return key != null && Convert.ToInt32(key.GetValue("AppsUseLightTheme", 1)) == 0; }
            catch (System.Security.SecurityException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
            catch (IOException) { return false; }
        }
        public static AppearancePalette Resolve(string mode, bool? systemDark = null, bool? highContrast = null)
        {
            bool contrast = highContrast ?? SystemInformation.HighContrast;
            bool dark = mode == "Dark" || (mode != "Light" && (systemDark ?? SystemIsDark()));
            if (contrast) return new AppearancePalette { HighContrast = true, Dark = SystemColors.Window.GetBrightness() < 0.5F,
                Background = SystemColors.Control, Surface = SystemColors.Window, Input = SystemColors.Window, Text = SystemColors.WindowText,
                Muted = SystemColors.WindowText, Border = SystemColors.WindowText, Accent = SystemColors.Highlight,
                Selection = SystemColors.Highlight, SelectionText = SystemColors.HighlightText, InactiveTab = SystemColors.Control, Error = SystemColors.WindowText };
            return dark ? new AppearancePalette { Dark = true, Background = Color.FromArgb(21, 26, 32), Surface = Color.FromArgb(31, 39, 48),
                Input = Color.FromArgb(24, 30, 38), Text = Color.FromArgb(234, 240, 248), Muted = Color.FromArgb(177, 192, 209),
                Border = Color.FromArgb(78, 94, 113), Accent = Color.FromArgb(49, 100, 186), Selection = Color.FromArgb(48, 76, 117),
                SelectionText = Color.White, InactiveTab = Color.FromArgb(57, 69, 85), Error = Color.FromArgb(255, 161, 154) }
                : new AppearancePalette { Background = Color.FromArgb(244, 247, 251), Surface = Color.White, Input = Color.White,
                    Text = Color.FromArgb(26, 39, 58), Muted = Color.FromArgb(75, 91, 112), Border = Color.FromArgb(138, 154, 174),
                    Accent = Color.FromArgb(41, 100, 208), Selection = Color.FromArgb(213, 229, 250), SelectionText = Color.FromArgb(20, 45, 80),
                    InactiveTab = Color.FromArgb(205, 216, 232), Error = Color.Firebrick };
        }
        public static void Apply(Control control, AppearancePalette palette)
        {
            Hook hook;
            if (!hooks.TryGetValue(control, out hook)) {
                hook = new Hook(); hooks.Add(control, hook);
                ComboBox combo = control as ComboBox;
                if (combo != null) {
                    combo.DrawItem += delegate(object sender, DrawItemEventArgs e) { DrawCombo((ComboBox)sender, e); };
                }
                ListView list = control as ListView;
                if (list != null && !(list is IconGridView)) {
                    list.OwnerDraw = true;
                    list.DrawItem += delegate(object sender, DrawListViewItemEventArgs e) { e.DrawDefault = true; };
                    list.DrawSubItem += delegate(object sender, DrawListViewSubItemEventArgs e) { e.DrawDefault = true; };
                    list.DrawColumnHeader += delegate(object sender, DrawListViewColumnHeaderEventArgs e) {
                        ListView current = (ListView)sender;
                        using (Brush brush = new SolidBrush(current.BackColor)) e.Graphics.FillRectangle(brush, e.Bounds);
                        TextRenderer.DrawText(e.Graphics, e.Header.Text, current.Font, Rectangle.Inflate(e.Bounds, -5, 0), current.ForeColor, TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
                    };
                }
                control.HandleCreated += delegate { ApplyNative(control); };
            }
            hook.Palette = palette;
            string role = control.Tag as string;
            Color parent = control.Parent == null ? palette.Background : control.Parent.BackColor;
            // The popup's resize margin and pages share one surface. A contrasting
            // rectangular inner panel otherwise appears to cut through its curves.
            control.BackColor = control is LauncherForm && !palette.HighContrast ? palette.Surface : control is Form ? palette.Background : control is TabPage || control is ListView || control.Name.EndsWith("Section", StringComparison.Ordinal) ? palette.Surface : parent;
            control.ForeColor = role == "ErrorText" ? palette.Error : role == "SecondaryText" ? palette.Muted : palette.Text;
            Button button = control as Button;
            if (button != null) {
                button.FlatStyle = FlatStyle.Flat; button.UseVisualStyleBackColor = false;
                button.BackColor = role == "PrimaryAction" ? palette.Accent : palette.Surface;
                button.ForeColor = role == "PrimaryAction" ? palette.HighContrast ? SystemColors.HighlightText : Color.White : palette.Text;
                button.FlatAppearance.BorderColor = palette.Border; button.FlatAppearance.MouseOverBackColor = palette.Selection;
                button.FlatAppearance.MouseDownBackColor = palette.Accent;
            }
            if (control is ComboBox || control is TextBoxBase || control is NumericUpDown) control.BackColor = palette.Input;
            CheckBox check = control as CheckBox; if (check != null) check.UseVisualStyleBackColor = false;
            DataGridView grid = control as DataGridView;
            if (grid != null) {
                grid.EnableHeadersVisualStyles = false; grid.BackgroundColor = palette.Input; grid.GridColor = palette.Border;
                grid.DefaultCellStyle.BackColor = palette.Input; grid.DefaultCellStyle.ForeColor = palette.Text;
                grid.DefaultCellStyle.SelectionBackColor = palette.Selection; grid.DefaultCellStyle.SelectionForeColor = palette.SelectionText;
                grid.ColumnHeadersDefaultCellStyle.BackColor = palette.Surface; grid.ColumnHeadersDefaultCellStyle.ForeColor = palette.Text;
                grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = palette.Surface;
                foreach (DataGridViewColumn column in grid.Columns) { DataGridViewButtonColumn action = column as DataGridViewButtonColumn; if (action != null) action.FlatStyle = FlatStyle.Flat; }
            }
            if (control.IsHandleCreated) ApplyNative(control);
            foreach (Control child in control.Controls) Apply(child, palette);
            control.Invalidate();
        }
        static void ApplyNative(Control control)
        {
            Hook hook; if (!hooks.TryGetValue(control, out hook) || hook.Palette == null || !control.IsHandleCreated) return;
            AppearancePalette p = hook.Palette;
            if (control is Form) {
                try {
                    int dark = p.Dark && !p.HighContrast ? 1 : 0;
                    DwmSetWindowAttribute(control.Handle, 20, ref dark, 4);
                    int caption = ColorTranslator.ToWin32(p.Background), text = ColorTranslator.ToWin32(p.Text);
                    DwmSetWindowAttribute(control.Handle, 35, ref caption, 4); DwmSetWindowAttribute(control.Handle, 36, ref text, 4);
                    if (control is LauncherForm) {
                        // Keep the resize frame and rounded region, without DWM's
                        // decorative outline. Restore OS borders in high contrast.
                        int border = p.HighContrast ? -1 : -2; // COLOR_DEFAULT / COLOR_NONE.
                        DwmSetWindowAttribute(control.Handle, 34, ref border, 4);
                    }
                }
                catch (DllNotFoundException) { }
                catch (EntryPointNotFoundException) { }
            }
            else if (control is ListView || control is TextBoxBase || control is DataGridView) {
                // Older Windows builds may ignore this style; explicit control colors still apply.
                SetWindowTheme(control.Handle, p.Dark && !p.HighContrast ? "DarkMode_Explorer" : "Explorer", null);
            }
        }
        static void DrawCombo(ComboBox combo, DrawItemEventArgs e)
        {
            Hook hook; if (!hooks.TryGetValue(combo, out hook) || hook.Palette == null || e.Bounds.Width < 1) return;
            AppearancePalette p = hook.Palette; bool selected = (e.State & DrawItemState.Selected) != 0;
            using (Brush brush = new SolidBrush(selected ? p.Selection : p.Input)) e.Graphics.FillRectangle(brush, e.Bounds);
            string text = e.Index >= 0 && e.Index < combo.Items.Count ? combo.Items[e.Index].ToString() : combo.Text;
            Rectangle textBounds = Rectangle.Inflate(e.Bounds, -5, 0);
            if (combo.Name == "AppIconStyle" && e.Index >= 0 && e.Index < AppBranding.Styles.Length) {
                using (Bitmap icon = AppBranding.Preview(AppBranding.Styles[e.Index], combo.Tag as string ?? (p.Dark ? "dark" : "light"), 22))
                    e.Graphics.DrawImage(icon, e.Bounds.Left + 3, e.Bounds.Top + (e.Bounds.Height - 22) / 2);
                textBounds.X += 26; textBounds.Width -= 26;
            }
            TextRenderer.DrawText(e.Graphics, text, combo.Font, textBounds, combo.Enabled ? selected ? p.SelectionText : p.Text : p.Muted, TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
            if ((e.State & DrawItemState.Focus) != 0) e.DrawFocusRectangle();
        }
        sealed class MenuColors : ProfessionalColorTable
        {
            readonly AppearancePalette p; public MenuColors(AppearancePalette palette) { p = palette; UseSystemColors = false; }
            public override Color ToolStripDropDownBackground { get { return p.Surface; } }
            public override Color ImageMarginGradientBegin { get { return p.Surface; } }
            public override Color ImageMarginGradientMiddle { get { return p.Surface; } }
            public override Color ImageMarginGradientEnd { get { return p.Surface; } }
            public override Color MenuItemSelected { get { return p.Selection; } }
            public override Color MenuItemBorder { get { return p.Border; } }
            public override Color MenuBorder { get { return p.Border; } }
            public override Color MenuItemPressedGradientBegin { get { return p.Selection; } }
            public override Color MenuItemPressedGradientEnd { get { return p.Selection; } }
            public override Color SeparatorDark { get { return p.Border; } }
            public override Color SeparatorLight { get { return p.Surface; } }
        }
        sealed class MenuRenderer : ToolStripProfessionalRenderer
        {
            readonly AppearancePalette p; public MenuRenderer(AppearancePalette palette) : base(new MenuColors(palette)) { p = palette; RoundedEdges = false; }
            protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e) { e.ArrowColor = p.Text; base.OnRenderArrow(e); }
            protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) { e.TextColor = e.Item.Enabled ? p.Text : p.Muted; base.OnRenderItemText(e); }
        }
        public static void ApplyMenu(ToolStrip menu, AppearancePalette palette)
        {
            menu.BackColor = palette.Surface; menu.ForeColor = palette.Text; menu.Renderer = new MenuRenderer(palette);
            foreach (ToolStripItem item in menu.Items) {
                item.ForeColor = palette.Text;
                ToolStripDropDownItem sub = item as ToolStripDropDownItem; if (sub != null && sub.HasDropDownItems) ApplyMenu(sub.DropDown, palette);
            }
        }
        public static bool Message(Form owner, string title, string message, AppearancePalette palette, bool cancel)
        {
            using (Form dialog = new Form { Text = title, Font = owner.Font, StartPosition = FormStartPosition.CenterParent, ClientSize = new Size(480, 190), MinimumSize = new Size(400, 200), MinimizeBox = false, MaximizeBox = false, Icon = owner.Icon }) {
                TableLayoutPanel layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(20), ColumnCount = 1, RowCount = 2 };
                layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
                layout.Controls.Add(new Label { Text = message, Dock = DockStyle.Fill }, 0, 0);
                FlowLayoutPanel buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft, AutoSize = true };
                Button ok = new Button { Text = cancel ? "Continue" : "OK", DialogResult = DialogResult.OK, AutoSize = true, MinimumSize = new Size(100, 32), Tag = "PrimaryAction" };
                if (cancel) { Button no = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, AutoSize = true, MinimumSize = new Size(100, 32) }; buttons.Controls.Add(no); dialog.CancelButton = no; }
                buttons.Controls.Add(ok); layout.Controls.Add(buttons, 0, 1); dialog.Controls.Add(layout); dialog.AcceptButton = ok;
                Apply(dialog, palette); return dialog.ShowDialog(owner) == DialogResult.OK;
            }
        }
    }

    public sealed partial class LauncherForm
    {
        readonly Button appIconButton = new Button(), appearanceModeButton = new Button();
        readonly ContextMenuStrip appIconMenu = new ContextMenuStrip();
        readonly ToolTip appearanceTips = new ToolTip();
        AppearancePalette appearancePalette;
        Icon ownedAppIcon, ownedTrayIcon;
        string activeAppIconKey;
        bool appearanceQueued, appearanceSubscribed, suppressAppIconClick;

        sealed class AppIconMenuColors : ProfessionalColorTable
        {
            readonly AppearancePalette palette;
            public AppIconMenuColors(AppearancePalette value) { palette = value; UseSystemColors = false; }
            public override Color ToolStripDropDownBackground { get { return palette.Surface; } }
            public override Color ImageMarginGradientBegin { get { return palette.Surface; } }
            public override Color ImageMarginGradientMiddle { get { return palette.Surface; } }
            public override Color ImageMarginGradientEnd { get { return palette.Surface; } }
            public override Color MenuItemSelected { get { return palette.Selection; } }
            public override Color MenuItemBorder { get { return palette.Selection; } }
            public override Color MenuBorder { get { return palette.Border; } }
        }
        sealed class AppIconMenuRenderer : ToolStripProfessionalRenderer
        {
            readonly AppearancePalette palette;
            public AppIconMenuRenderer(AppearancePalette value) : base(new AppIconMenuColors(value)) { palette = value; RoundedEdges = false; }
            protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
            {
                ToolStripMenuItem item = e.Item as ToolStripMenuItem;
                using (Brush brush = new SolidBrush(e.Item.Selected || (item != null && item.Checked) ? palette.Selection : palette.Surface))
                    e.Graphics.FillRectangle(brush, new Rectangle(Point.Empty, e.Item.Size));
            }
            // Highlight the selected row without a checkmark column or overlay.
            protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e) { }
            protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) { e.TextColor = e.Item.Enabled ? palette.Text : palette.Muted; base.OnRenderItemText(e); }
        }
        void BuildAppearanceSettings()
        {
            foreach (Button button in new[] { appIconButton, appearanceModeButton }) {
                button.Size = new Size(44, 44); button.Margin = new Padding(4, 0, 0, 0);
                button.FlatStyle = FlatStyle.Flat; button.FlatAppearance.BorderSize = 0;
                button.ImageAlign = ContentAlignment.MiddleCenter;
            }
            appIconButton.Name = "AppIconButton"; appIconButton.AccessibleName = "Choose Better Icon app icon";
            appearanceModeButton.Name = "AppearanceModeButton";
            appIconMenu.Name = "AppIconMenu"; appIconMenu.Font = Font;
            appIconMenu.ShowCheckMargin = false; appIconMenu.ShowImageMargin = true;
            appIconMenu.ImageScalingSize = new Size(32, 32); appIconMenu.Padding = new Padding(4);
            ToolStripMenuItem automatic = new ToolStripMenuItem("Match app theme") { Tag = "Auto", ImageScaling = ToolStripItemImageScaling.None };
            automatic.Click += delegate { if (!busy) { preferences.AppIconVariant = "Auto"; ChangeAppearance(); } };
            appIconMenu.Items.Add(automatic);
            foreach (string color in AppBranding.Styles) foreach (string shade in new[] { "Dark", "Light" }) {
                string style = color, variant = shade;
                ToolStripMenuItem item = new ToolStripMenuItem(AppBranding.Title(style) + " " + variant) {
                    Tag = style + "/" + variant, Image = AppBranding.Preview(style, variant.ToLowerInvariant(), 32),
                    ImageScaling = ToolStripItemImageScaling.None
                };
                item.Click += delegate { if (!busy) { preferences.AppIconStyle = style; preferences.AppIconVariant = variant; ChangeAppearance(); } };
                appIconMenu.Items.Add(item);
            }
            foreach (ToolStripItem item in appIconMenu.Items) item.Padding = new Padding(4, 3, 8, 3);
            appIconMenu.Closing += delegate(object sender, ToolStripDropDownClosingEventArgs e) {
                suppressAppIconClick = e.CloseReason == ToolStripDropDownCloseReason.AppClicked && appIconButton.RectangleToScreen(appIconButton.ClientRectangle).Contains(Cursor.Position);
            };
            appIconButton.Click += delegate {
                if (suppressAppIconClick) { suppressAppIconClick = false; return; }
                ShowAppIconMenu();
            };
            appearanceModeButton.Click += delegate {
                if (busy) return;
                preferences.AppearanceMode = preferences.AppearanceMode == "Dark" ? "Light" : preferences.AppearanceMode == "Light" ? "System" : "Dark";
                ChangeAppearance();
            };
        }
        bool AppearanceMenuOpen { get { return appIconMenu.Visible; } }
        void ShowAppIconMenu()
        {
            if (busy || !Enabled) return;
            if (appIconMenu.Visible) { appIconMenu.Close(); return; }
            Rectangle anchor = appIconButton.RectangleToScreen(appIconButton.ClientRectangle), work = Screen.FromControl(appIconButton).WorkingArea;
            int above = anchor.Top - work.Top - 8, below = work.Bottom - anchor.Bottom - 8;
            bool upward = above >= 120 || above >= below;
            int available = Math.Max(80, Math.Min(work.Height - 16, upward ? above : below));
            // ToolStripDropDownMenu supplies native scroll arrows when constrained.
            appIconMenu.MaximumSize = new Size(Math.Max(1, work.Width - 16), available);
            Size size = appIconMenu.GetPreferredSize(Size.Empty);
            int x = Math.Max(work.Left + 4, Math.Min(work.Right - size.Width - 4, anchor.Right - size.Width));
            int y = upward ? anchor.Top - size.Height - 6 : anchor.Bottom + 6;
            y = Math.Max(work.Top + 4, Math.Min(work.Bottom - size.Height - 4, y));
            appIconMenu.Show(appIconButton, appIconButton.PointToClient(new Point(x, y)));
        }
        void SetAppearanceBusy(bool value)
        {
            appIconButton.Enabled = appearanceModeButton.Enabled = !value;
            if (value) appIconMenu.Close();
            foreach (ToolStripItem item in appIconMenu.Items) item.Enabled = !value;
        }
        void InitializeAppearance()
        {
            ApplyAppearance();
            SystemEvents.UserPreferenceChanged += OnSystemAppearanceChanged; appearanceSubscribed = true;
        }
        void OnSystemAppearanceChanged(object sender, UserPreferenceChangedEventArgs e)
        {
            if (IsDisposed || Disposing || !IsHandleCreated || appearanceQueued) return;
            appearanceQueued = true;
            try { BeginInvoke(new Action(delegate { try { if (!IsDisposed && !Disposing) ApplyAppearance(); } finally { appearanceQueued = false; } })); }
            catch (InvalidOperationException) { appearanceQueued = false; }
        }
        void ChangeAppearance()
        {
            if (busy) return;
            ApplyAppearance();
            try { WritePreferences(); status.Text = "Appearance saved."; }
            catch (IOException) { status.Text = "Appearance changed for this session, but could not be saved."; }
            catch (UnauthorizedAccessException) { status.Text = "Appearance changed for this session, but could not be saved."; }
        }
        void ApplyAppearance()
        {
            appearancePalette = AppAppearance.Resolve(preferences.AppearanceMode);
            string variant = AppBranding.Variant(preferences.AppIconVariant, appearancePalette.Dark), key = preferences.AppIconStyle + "." + variant;
            if (activeAppIconKey != key) {
                Icon replacement = AppBranding.Load(preferences.AppIconStyle, variant), previous = ownedAppIcon ?? Icon;
                Icon small = AppBranding.Load(preferences.AppIconStyle, variant, SystemInformation.SmallIconSize.Width), previousSmall = ownedTrayIcon;
                Icon = replacement; tray.Icon = small; ownedAppIcon = replacement; ownedTrayIcon = small; activeAppIconKey = key;
                foreach (Form dialog in OwnedForms) dialog.Icon = replacement;
                if (previous != null) previous.Dispose();
                if (previousSmall != null) previousSmall.Dispose();
                Image old = appIconButton.Image; appIconButton.Image = AppBranding.Preview(preferences.AppIconStyle, variant, 32); if (old != null) old.Dispose();
            }
            string description = AppBranding.Title(preferences.AppIconStyle) + " " + (variant == "dark" ? "Dark" : "Light");
            appIconButton.AccessibleDescription = description + (preferences.AppIconVariant == "Auto" ? "; matches the app theme." : "; fixed icon variant.");
            appearanceTips.SetToolTip(appIconButton, "Choose app icon: " + description);
            foreach (ToolStripMenuItem item in appIconMenu.Items) item.Checked = (string)item.Tag == (preferences.AppIconVariant == "Auto" ? "Auto" : preferences.AppIconStyle + "/" + preferences.AppIconVariant);
            if (appIconMenu.Items.Count > 0) {
                ToolStripItem automatic = appIconMenu.Items[0]; Image old = automatic.Image;
                automatic.Image = AppBranding.Preview(preferences.AppIconStyle, appearancePalette.Dark ? "dark" : "light", 32);
                if (old != null) old.Dispose();
            }
            AppAppearance.Apply(this, appearancePalette);
            foreach (ContextMenuStrip menu in new[] { trayMenu, iconMenu, importPackMenu, managePackMenu }) AppAppearance.ApplyMenu(menu, appearancePalette);
            appIconMenu.BackColor = appearancePalette.Surface; appIconMenu.ForeColor = appearancePalette.Text;
            appIconMenu.Renderer = new AppIconMenuRenderer(appearancePalette);
            foreach (ToolStripItem item in appIconMenu.Items) item.ForeColor = appearancePalette.Text;
            foreach (Form dialog in OwnedForms) AppAppearance.Apply(dialog, appearancePalette);
            string next = preferences.AppearanceMode == "Dark" ? "Light" : preferences.AppearanceMode == "Light" ? "System" : "Dark";
            appearanceModeButton.AccessibleName = "App theme: " + preferences.AppearanceMode;
            appearanceModeButton.AccessibleDescription = "Click to switch to " + next + ". Cycles Dark, Light and System.";
            appearanceTips.SetToolTip(appearanceModeButton, preferences.AppearanceMode + " theme; click for " + next);
            Image oldGlyph = appearanceModeButton.Image;
            appearanceModeButton.Image = AppThemeGlyph(preferences.AppearanceMode, appearancePalette.Text);
            if (oldGlyph != null) oldGlyph.Dispose();
            pages.Invalidate();
        }
        static Bitmap AppThemeGlyph(string mode, Color color)
        {
            Bitmap image = new Bitmap(32, 32);
            using (Graphics canvas = Graphics.FromImage(image)) using (Pen pen = new Pen(color, 2F)) using (Brush brush = new SolidBrush(color)) {
                canvas.Clear(Color.Transparent); canvas.SmoothingMode = SmoothingMode.AntiAlias;
                if (mode == "Dark") {
                    using (GraphicsPath outer = new GraphicsPath()) using (GraphicsPath cutout = new GraphicsPath()) {
                        outer.AddEllipse(5, 4, 23, 24); cutout.AddEllipse(12, 0, 22, 24);
                        using (Region crescent = new Region(outer)) { crescent.Exclude(cutout); canvas.FillRegion(brush, crescent); }
                    }
                }
                else if (mode == "Light") {
                    canvas.DrawEllipse(pen, 10, 10, 12, 12);
                    for (int i = 0; i < 8; i++) {
                        double angle = i * Math.PI / 4;
                        canvas.DrawLine(pen, 16 + (float)Math.Cos(angle) * 10, 16 + (float)Math.Sin(angle) * 10, 16 + (float)Math.Cos(angle) * 14, 16 + (float)Math.Sin(angle) * 14);
                    }
                }
                else {
                    canvas.DrawRectangle(pen, 3, 6, 26, 18); canvas.DrawLine(pen, 16, 24, 16, 28); canvas.DrawLine(pen, 10, 29, 22, 29);
                    canvas.FillRectangle(brush, 6, 9, 10, 12);
                }
            }
            return image;
        }
        void ApplyDialogAppearance(Form dialog) { dialog.Icon = Icon; AppAppearance.Apply(dialog, appearancePalette ?? AppAppearance.Resolve(preferences.AppearanceMode)); }
        void DisposeAppearance()
        {
            if (appearanceSubscribed) { SystemEvents.UserPreferenceChanged -= OnSystemAppearanceChanged; appearanceSubscribed = false; }
            if (ownedAppIcon != null) { ownedAppIcon.Dispose(); ownedAppIcon = null; }
            if (ownedTrayIcon != null) { ownedTrayIcon.Dispose(); ownedTrayIcon = null; }
            if (appIconButton.Image != null) { appIconButton.Image.Dispose(); appIconButton.Image = null; }
            if (appearanceModeButton.Image != null) { appearanceModeButton.Image.Dispose(); appearanceModeButton.Image = null; }
            if (!appIconMenu.IsDisposed) {
                foreach (ToolStripItem item in appIconMenu.Items) if (item.Image != null) { item.Image.Dispose(); item.Image = null; }
                appIconMenu.Dispose();
            }
            appearanceTips.Dispose();
        }
    }
}
