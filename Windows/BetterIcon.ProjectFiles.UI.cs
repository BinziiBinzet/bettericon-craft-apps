using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

namespace BetterIcon.Tray
{
    public sealed partial class LauncherForm
    {
        void ShowSavedPack(ThemeEntry pack)
        {
            ReloadLibrary(pack.IconCount == 0 ? null : pack.Id);
            status.Text = "Saved " + pack.Name + ".";
            if (pack.IconCount == 0) OpenProjectIcons(pack.Id);
        }
        void OpenProjectIcons(string id)
        {
            using (var dialog = new ProjectFileDialog(this, id)) {
                ApplyDialogAppearance(dialog);
                dialog.ShowDialog(this);
            }
        }
        sealed class ProjectFileDialog : Form
        {
            readonly LauncherForm owner;
            readonly PackPicker packs = new PackPicker();
            readonly ListView files = new ListView();
            readonly ImageList images = new ImageList();
            readonly Label message = new Label();
            readonly TableLayoutPanel progressPanel = new TableLayoutPanel();
            readonly Label phase = new Label();
            readonly ProgressBar progress = new ProgressBar();
            readonly Button apply = new Button(), restore = new Button(), edit = new Button(), export = new Button(), remove = new Button();
            bool filling, working;
            ThemeEntry Selected { get { return packs.SelectedItem as ThemeEntry; } }
            public ProjectFileDialog(LauncherForm parent, string id)
            {
                owner = parent; Text = "ArtCraft project file icons"; Font = parent.Font;
                packs.EnablePreviews(parent.previewStore);
                StartPosition = FormStartPosition.CenterParent; MinimizeBox = MaximizeBox = false;
                ClientSize = new Size(620, 540); MinimumSize = new Size(570, 435);
                var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(16), ColumnCount = 1, RowCount = 6 };
                layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
                layout.RowStyles.Add(new RowStyle(SizeType.AutoSize)); layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
                layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
                layout.RowStyles.Add(new RowStyle(SizeType.AutoSize)); layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
                layout.Controls.Add(new Label { Text = "File icon pack", AutoSize = true }, 0, 0);
                packs.Dock = DockStyle.Top; packs.DropDownStyle = ComboBoxStyle.DropDownList; packs.AccessibleName = "File icon pack";
                layout.Controls.Add(packs, 0, 1);
                files.Dock = DockStyle.Fill; files.View = View.Details; files.FullRowSelect = true; files.AccessibleName = "Project file icons";
                files.Columns.Add("File type", 150); files.Columns.Add("ArtCraft app", 185); files.Columns.Add("Artwork", 170);
                images.ColorDepth = ColorDepth.Depth32Bit; images.ImageSize = new Size(32, 32); files.SmallImageList = images;
                layout.Controls.Add(files, 0, 2);
                var tools = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top };
                edit.Text = "Customize..."; export.Text = "Export ZIP..."; remove.Text = "Remove pack";
                foreach (var button in new[] { edit, export, remove }) { button.AutoSize = true; tools.Controls.Add(button); }
                layout.Controls.Add(tools, 0, 3);
                message.AutoEllipsis = true; message.Dock = DockStyle.Top; message.Height = 40; message.AccessibleName = "File icon status";
                message.Text = "Choose a pack to preview its artwork for native ArtCraft project files."; layout.Controls.Add(message, 0, 4);
                var actions = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true };
                apply.Text = "Apply file icons..."; restore.Text = "Restore file icons..."; apply.Tag = "PrimaryAction";
                foreach (var button in new[] { apply, restore }) { button.AutoSize = true; actions.Controls.Add(button); }
                var close = new Button { Text = "Close", AutoSize = true, DialogResult = DialogResult.Cancel }; actions.Controls.Add(close);
                CancelButton = close; layout.Controls.Add(actions, 0, 5); Controls.Add(layout);
                ConfigureIndicator(progressPanel, phase, progress); Controls.Add(progressPanel);
                packs.AccessibleDescription = "Click a pack or press Enter to load it. Packs marked Download will be fetched.";
                packs.PackChosen += async delegate { if (!filling && !working) await Choose(true); };
                edit.Click += async delegate { await Edit(); }; export.Click += delegate { Export(); }; remove.Click += async delegate { await Remove(); };
                apply.Click += async delegate { await Change(false); }; restore.Click += async delegate { await Change(true); };
                FormClosing += delegate(object s, FormClosingEventArgs e) { if (working) e.Cancel = true; };
                Reload(id ?? parent.preferences.FileTheme);
                Load += async delegate { await Choose(false); };
            }
            void Reload(string id)
            {
                filling = true;
                try {
                    packs.Items.Clear(); packs.Items.Add("Original file icons");
                    var choices = owner.library.VisibleThemes(owner.bundledThemes);
                    packs.Items.AddRange(choices.Where(p => !p.IsDefault).ToArray());
                    var choice = choices.FirstOrDefault(p => p.Id == id && !p.NeedsDownload);
                    packs.SelectedIndex = choice == null ? 0 : packs.Items.IndexOf(choice);
                } finally { filling = false; }
            }
            static Dictionary<string, Bitmap> PrepareFilePreviews(Dictionary<string, string> artwork)
            {
                var previews = new Dictionary<string, Bitmap>();
                try {
                    foreach (var entry in artwork) previews.Add(entry.Key, Thumbnail(entry.Value, SystemIcons.Application, 32));
                    return previews;
                } catch { foreach (var image in previews.Values) image.Dispose(); throw; }
            }
            void Render(ThemeEntry pack, Dictionary<string, Bitmap> previews)
            {
                files.BeginUpdate();
                try {
                    files.Items.Clear(); images.Images.Clear();
                    // With a native handle, ImageList copies each bitmap as it is added.
                    var handle = images.Handle;
                    foreach (var f in ProjectFormat.All) {
                        Bitmap preview;
                        bool hasPreview = previews.TryGetValue(f.Key, out preview);
                        if (pack != null && !hasPreview) continue;
                        var item = new ListViewItem(f.Key); item.SubItems.Add(f.Application);
                        item.SubItems.Add(pack == null ? "Original" : pack.FileIcons != null && pack.FileIcons.Count > 0 ? "File icon" : "From app artwork");
                        if (hasPreview) {
                            images.Images.Add(preview);
                            item.ImageIndex = images.Images.Count - 1;
                        }
                        files.Items.Add(item);
                    }
                } finally { files.EndUpdate(); }
            }
            void Busy(bool value)
            {
                if (value) working = true;
                packs.Enabled = !value;
                var pack = Selected;
                apply.Enabled = !value && pack != null && files.Items.Count > 0;
                restore.Enabled = !value; edit.Enabled = !value && pack != null;
                export.Enabled = remove.Enabled = !value && pack != null && pack.Managed;
                edit.Text = pack != null && pack.Managed ? "Edit pack..." : "Customize...";
                if (!value) { UpdateIndicator(progressPanel, phase, progress, false, null); working = false; }
            }
            async Task Choose(bool persist)
            {
                var choice = Selected;
                Busy(true); UpdateIndicator(progressPanel, phase, progress, true, PackActivity(choice));
                try {
                    await Task.Yield();
                    if (choice != null && choice.NeedsDownload) {
                        await owner.DownloadTheme(choice);
                        if (IsDisposed || Disposing) return;
                        packs.RefreshLabels();
                        UpdateIndicator(progressPanel, phase, progress, true, PackActivity(choice));
                    }
                    var artwork = choice == null ? new Dictionary<string, string>() : ProjectFormat.Artwork(choice);
                    var previews = await Task.Run(() => PrepareFilePreviews(artwork));
                    try { if (IsDisposed || Disposing) return; Render(choice, previews); }
                    finally { foreach (var image in previews.Values) image.Dispose(); }
                    if (persist) {
                        owner.preferences.FileTheme = choice == null ? null : choice.Id;
                        owner.WritePreferences();
                    }
                    message.Text = "Review the file types before applying their icons.";
                } catch (Exception e) {
                    if (!IsDisposed && !Disposing) { Reload(owner.preferences.FileTheme); message.Text = e.Message; }
                } finally { if (!IsDisposed && !Disposing) Busy(false); }
            }
            async Task Edit()
            {
                if (Selected == null) return;
                try {
                    using (var dlg = new PackEditor(owner.library, Selected, Selected.Managed)) {
                        owner.ApplyDialogAppearance(dlg);
                        if (dlg.ShowDialog(this) != DialogResult.OK) return;
                        bool appUsesPack = owner.SelectedTheme != null && dlg.Saved.Managed && owner.SelectedTheme.LibraryId == dlg.Saved.LibraryId;
                        owner.ReloadLibrary(appUsesPack ? dlg.Saved.Id : null); Reload(dlg.Saved.Id); await Choose(true);
                    }
                } catch (Exception e) { message.Text = e.Message; }
            }
            void Export()
            {
                if (Selected == null || !Selected.Managed) return;
                using (var dlg = new SaveFileDialog { Filter = "BetterIcon pack (*.zip)|*.zip", DefaultExt = "zip", AddExtension = true }) {
                    if (dlg.ShowDialog(this) != DialogResult.OK) return;
                    try { owner.library.Export(Selected, dlg.FileName, true); message.Text = "Icon pack exported."; }
                    catch (Exception e) { message.Text = e.Message; }
                }
            }
            async Task Remove()
            {
                if (Selected == null || !Selected.Managed || !AppAppearance.Message(this, "Remove icon pack", "Remove " + Selected + " from your library?", owner.appearancePalette, true)) return;
                try { owner.library.Remove(Selected); owner.ReloadLibrary(null); Reload(null); await Choose(true); }
                catch (Exception e) { message.Text = e.Message; }
            }
            async Task Change(bool restoring)
            {
                if (working || (!restoring && Selected == null)) return;
                var artwork = restoring ? new Dictionary<string, string>() : ProjectFormat.Artwork(Selected);
                Busy(true); message.Text = "Reviewing file icons...";
                try {
                    if (!restoring) {
                        var reply = await owner.worker.Run(new WorkerRequest { Action = "PrepareProjectIcons", ProjectArtwork = artwork }, false);
                        artwork = reply.CachedProjectIcons;
                    }
                    string dir = Path.Combine(Path.GetDirectoryName(owner.preferencesPath), "project-file-icons");
                    bool live = owner.fixtureLog == null;
                    string key = @"Software\Classes";
                    if (!live) using (var sha = SHA256.Create())
                        key = @"Software\BetterIcon-Fixtures\" + BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(dir))).Replace("-", "") + @"\Classes";
                    using (var overlay = live ? Registry.CurrentUser.OpenSubKey(key, true) : Registry.CurrentUser.CreateSubKey(key))
                    using (var choices = live ? Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts") : null) {
                        var store = new ProjectIconStore(dir, live ? Registry.ClassesRoot : overlay, overlay, choices, live);
                        var plan = await Task.Run(() => store.Review(artwork, restoring));
                        var applicable = plan.Where(row => row.CanChange).ToArray();
                        string details = String.Join("\r\n", plan.Select(row => row.Extensions + "   " + row.Reason));
                        if (applicable.Length == 0) {
                            AppAppearance.Message(this, "Project file icons", plan.Count == 0 ? "There are no managed file icons to restore." : details, owner.appearancePalette, false);
                            message.Text = "No file icon changes."; return;
                        }
                        string title = restoring ? "Restore project file icons" : "Apply project file icons";
                        if (!AppAppearance.Message(this, title, details, owner.appearancePalette, true)) { message.Text = "Review canceled."; return; }
                        await Task.Run(() => store.Commit(artwork, restoring, plan)); message.Text = restoring ? "Original file icons restored." : "Project file icons applied.";
                    }
                } catch (Exception e) { message.Text = e.Message; }
                finally { Busy(false); }
            }
            protected override void Dispose(bool disposing) { if (disposing) images.Dispose(); base.Dispose(disposing); }
        }
    }
}
