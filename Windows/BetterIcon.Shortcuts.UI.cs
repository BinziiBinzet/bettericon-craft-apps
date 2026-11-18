using System;
using System.Drawing;
using System.Windows.Forms;

namespace BetterIcon.Tray
{
    public sealed class ShortcutScopeDialog : Form
    {
        public string SelectedScope { get; private set; }
        public ShortcutScopeDialog(bool restoring, string application)
        {
            Text = restoring ? "Restore icon locations" : "Apply icon locations";
            Name = "ShortcutScopeDialog"; Font = new Font("Segoe UI", 10F);
            StartPosition = FormStartPosition.CenterParent; FormBorderStyle = FormBorderStyle.FixedDialog;
            MinimizeBox = MaximizeBox = false; ShowInTaskbar = false;
            ClientSize = new Size(620, 250); MinimumSize = new Size(620, 250);
            AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink;
            string app = application == "ArtCraftLauncher" ? "ArtCraft Launcher" : application;
            string action = restoring ? "restore" : "apply";
            TableLayoutPanel layout = new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, ColumnCount = 1, RowCount = 4, Padding = new Padding(20) };
            for (int row = 0; row < 4; row++) layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            Label question = new Label { Text = "Where would you like to " + action + (String.IsNullOrEmpty(app) ? " icons?" : " " + app + " icons?"), AutoSize = true, Dock = DockStyle.Top, Margin = new Padding(0, 0, 0, 16) };
            layout.Controls.Add(question, 0, 0);
            TableLayoutPanel choices = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 2, RowCount = 1, Margin = Padding.Empty };
            choices.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50)); choices.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            Button current = Choice("Current user", "Desktop, Start menu and taskbar pins", "CurrentUser");
            Button all = Choice("All users", "Shared Desktop and Start menu", "AllUsers");
            current.Margin = new Padding(0, 0, 8, 0); all.Margin = new Padding(8, 0, 0, 0);
            choices.Controls.Add(current, 0, 0); choices.Controls.Add(all, 1, 0); layout.Controls.Add(choices, 0, 1);
            Label admin = new Label { Name = "AdministratorNotice", Text = "All users requires administrator privileges.", AutoSize = true, Dock = DockStyle.Top, Margin = new Padding(0, 14, 0, 16) };
            layout.Controls.Add(admin, 0, 2);
            FlowLayoutPanel buttons = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top, FlowDirection = FlowDirection.RightToLeft, Margin = Padding.Empty };
            Button cancel = new Button { Text = "Cancel", Name = "CancelScope", DialogResult = DialogResult.Cancel, AutoSize = true, MinimumSize = new Size(100, 34), Margin = Padding.Empty };
            buttons.Controls.Add(cancel); layout.Controls.Add(buttons, 0, 3); Controls.Add(layout);
            CancelButton = cancel; AcceptButton = current;
        }
        Button Choice(string title, string detail, string scope)
        {
            Button button = new Button { Text = title + "\r\n" + detail, Name = scope + "Choice", AccessibleName = title,
                AutoSize = true, Dock = DockStyle.Fill, MinimumSize = new Size(0, 78), Padding = new Padding(10), DialogResult = DialogResult.OK };
            if (scope == "AllUsers") button.AccessibleDescription = "Shared shortcuts for everyone on this computer. Requires administrator privileges.";
            button.Click += delegate { SelectedScope = scope; };
            return button;
        }
    }
    public sealed partial class LauncherForm
    {
        string ChooseShortcutScope(bool restoring, string application = null)
        {
            iconMenu.Close();
            bool wasEnabled = trayMenu.Enabled; trayMenu.Enabled = false;
            try {
                using (ShortcutScopeDialog dialog = new ShortcutScopeDialog(restoring, application)) {
                    dialog.Icon = Icon; ApplyDialogAppearance(dialog);
                    return dialog.ShowDialog(this) == DialogResult.OK ? dialog.SelectedScope : null;
                }
            }
            finally { trayMenu.Enabled = wasEnabled; }
        }
    }
}
