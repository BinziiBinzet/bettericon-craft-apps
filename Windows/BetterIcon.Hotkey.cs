using System;
using System.Drawing;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace BetterIcon.Tray
{
    public sealed class HotkeySettings
    {
        public bool Enabled { get; set; }
        public bool Control { get; set; }
        public bool Alt { get; set; }
        public bool Shift { get; set; }
        public int Key { get; set; }
        public HotkeySettings() { Enabled = Control = Alt = Shift = true; Key = (int)Keys.A; }
        public HotkeySettings Copy() { return (HotkeySettings)MemberwiseClone(); }
        public uint Modifiers() { return (Control ? 2U : 0U) | (Alt ? 1U : 0U) | (Shift ? 4U : 0U); }
        public static Keys[] AllowedKeys()
        {
            // F12 belongs to the debugger; Windows-key shortcuts belong to the OS.
            return Enumerable.Range((int)Keys.A, 26).Concat(Enumerable.Range((int)Keys.D0, 10))
                .Concat(Enumerable.Range((int)Keys.F1, 24).Where(k => k != (int)Keys.F12))
                .Concat(new[] { (int)Keys.Space }).Select(k => (Keys)k).ToArray();
        }
        public static string KeyName(int key) { return key >= (int)Keys.D0 && key <= (int)Keys.D9 ? ((char)key).ToString() : ((Keys)key).ToString(); }
        public string Validate()
        {
            if (!Enabled) return null;
            if (!Control && !Alt) return "Choose Ctrl or Alt, optionally with Shift.";
            return AllowedKeys().Contains((Keys)Key) ? null : "Choose a letter, number, function key, or Space.";
        }
        public override string ToString() { return (Control ? "Ctrl+" : "") + (Alt ? "Alt+" : "") + (Shift ? "Shift+" : "") + KeyName(Key); }
    }

    // A message-only window receives WM_HOTKEY even while the popup is hidden.
    // RegisterHotKey is scoped to this running process; no keyboard hook or OS
    // configuration is installed. Failed changes leave the old binding intact.
    public sealed class GlobalHotkey : NativeWindow, IDisposable
    {
        [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
        [DllImport("user32.dll", SetLastError = true)] static extern bool UnregisterHotKey(IntPtr window, int id);
        readonly Action pressed;
        int activeId;
        bool disposed;
        public HotkeySettings Current { get; private set; }
        public bool IsRegistered { get { return activeId != 0; } }
        public GlobalHotkey(Action callback)
        {
            pressed = callback;
            CreateHandle(new CreateParams { Caption = "BetterIcon hotkey", Parent = new IntPtr(-3) });
        }
        public bool TrySet(HotkeySettings requested, out string error)
        {
            if (disposed) throw new ObjectDisposedException("GlobalHotkey");
            error = requested.Validate();
            if (error != null) return false;
            if (!requested.Enabled) {
                if (activeId != 0 && !UnregisterHotKey(Handle, activeId)) { error = "Windows could not release the current hotkey. Try again."; return false; }
                activeId = 0; Current = requested.Copy(); return true;
            }
            if (activeId != 0 && Current.Key == requested.Key && Current.Modifiers() == requested.Modifiers()) { Current = requested.Copy(); return true; }
            int nextId = activeId == 1 ? 2 : 1;
            if (!RegisterHotKey(Handle, nextId, requested.Modifiers() | 0x4000U, (uint)requested.Key)) {
                int code = Marshal.GetLastWin32Error();
                error = code == 1409 ? "That hotkey is already in use by another app. Choose another combination." : "Windows could not register that hotkey (error " + code + "). Choose another combination.";
                return false;
            }
            if (activeId != 0 && !UnregisterHotKey(Handle, activeId)) {
                UnregisterHotKey(Handle, nextId); error = "Windows could not replace the current hotkey. Try again."; return false;
            }
            activeId = nextId; Current = requested.Copy(); return true;
        }
        protected override void WndProc(ref Message message)
        {
            long keys = message.LParam.ToInt64();
            if (message.Msg == 0x0312 && activeId != 0 && message.WParam.ToInt32() == activeId &&
                (keys & 15) == Current.Modifiers() && ((keys >> 16) & 0xffff) == Current.Key) { pressed(); return; }
            base.WndProc(ref message);
        }
        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            if (activeId != 0) UnregisterHotKey(Handle, activeId);
            activeId = 0; DestroyHandle();
        }
    }

    public sealed class HotkeySettingsDialog : Form
    {
        sealed class KeyChoice
        {
            public int Value;
            public override string ToString() { return HotkeySettings.KeyName(Value); }
        }
        public HotkeySettingsDialog(HotkeySettings current, bool registered, Func<HotkeySettings, string> save)
        {
            Text = "BetterIcon settings"; Font = new Font("Segoe UI", 10F);
            StartPosition = FormStartPosition.CenterParent; ClientSize = new Size(560, 290);
            FormBorderStyle = FormBorderStyle.FixedDialog; MinimizeBox = MaximizeBox = false; ShowInTaskbar = false;
            TableLayoutPanel layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(18), ColumnCount = 1, RowCount = 6 };
            foreach (int height in new[] { 36, 38, 38, 52, 44, 46 }) layout.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
            CheckBox enabled = new CheckBox { Text = "Enable system-wide hotkey", Checked = current.Enabled, AutoSize = true };
            CheckBox control = new CheckBox { Text = "Ctrl", Checked = current.Control, AutoSize = true };
            CheckBox alt = new CheckBox { Text = "Alt", Checked = current.Alt, AutoSize = true };
            CheckBox shift = new CheckBox { Text = "Shift", Checked = current.Shift, AutoSize = true };
            FlowLayoutPanel modifiers = new FlowLayoutPanel { Dock = DockStyle.Fill }; modifiers.Controls.AddRange(new Control[] { control, alt, shift });
            ComboBox key = new AppearanceComboBox { Width = 100, DropDownStyle = ComboBoxStyle.DropDownList, AccessibleName = "Hotkey key" };
            key.Items.AddRange(HotkeySettings.AllowedKeys().Select(k => new KeyChoice { Value = (int)k }).ToArray());
            key.SelectedItem = key.Items.Cast<KeyChoice>().FirstOrDefault(k => k.Value == current.Key) ?? key.Items[0];
            Label combination = new Label { AutoSize = true, Margin = new Padding(15, 5, 0, 0) };
            FlowLayoutPanel keyRow = new FlowLayoutPanel { Dock = DockStyle.Fill };
            keyRow.Controls.Add(new Label { Text = "Key", AutoSize = true, Margin = new Padding(0, 5, 12, 0) }); keyRow.Controls.Add(key); keyRow.Controls.Add(combination);
            Label description = new Label { Text = "Opens the popup centered on your mouse cursor and keeps it on screen. Use Ctrl or Alt, optionally with Shift.", Dock = DockStyle.Fill };
            Label error = new Label { ForeColor = Color.Firebrick, Tag = "ErrorText", Dock = DockStyle.Fill, Text = current.Enabled && !registered ? "The saved hotkey is unavailable. Choose another combination or disable it." : "" };
            Func<HotkeySettings> selection = delegate { return new HotkeySettings { Enabled = enabled.Checked, Control = control.Checked, Alt = alt.Checked, Shift = shift.Checked, Key = ((KeyChoice)key.SelectedItem).Value }; };
            Action update = delegate { control.Enabled = alt.Enabled = shift.Enabled = key.Enabled = enabled.Checked; combination.Text = enabled.Checked ? selection().ToString() : "Disabled"; };
            enabled.CheckedChanged += delegate { update(); }; control.CheckedChanged += delegate { update(); }; alt.CheckedChanged += delegate { update(); }; shift.CheckedChanged += delegate { update(); }; key.SelectedIndexChanged += delegate { update(); };
            FlowLayoutPanel buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft };
            Button cancel = new Button { Text = "Cancel", Width = 95, Height = 32, DialogResult = DialogResult.Cancel };
            Button accept = new Button { Text = "Save", Width = 95, Height = 32, Tag = "PrimaryAction" };
            accept.Click += delegate { string failure = save(selection()); if (failure == null) { DialogResult = DialogResult.OK; Close(); } else error.Text = failure; };
            buttons.Controls.Add(cancel); buttons.Controls.Add(accept);
            layout.Controls.Add(enabled, 0, 0); layout.Controls.Add(modifiers, 0, 1); layout.Controls.Add(keyRow, 0, 2); layout.Controls.Add(description, 0, 3); layout.Controls.Add(error, 0, 4); layout.Controls.Add(buttons, 0, 5);
            Controls.Add(layout); AcceptButton = accept; CancelButton = cancel; update();
        }
    }
}
