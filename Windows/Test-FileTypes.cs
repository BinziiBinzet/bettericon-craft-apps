using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using BetterIcon.Tray;
using Microsoft.Win32;

// The file type picker, its preview and the reviewed apply and restore, against a disposable registry key.
static class FileTypeTests
{
    const BindingFlags Instance = BindingFlags.Instance | BindingFlags.NonPublic;
    static string Text(RegistryKey hive, string path)
    {
        using (RegistryKey key = hive.OpenSubKey(path)) return key == null ? null : key.GetValue("") as string;
    }
    static void Set(RegistryKey hive, string path, string value) { using (RegistryKey key = hive.CreateSubKey(path)) key.SetValue("", value); }
    static int[] Pixels(Bitmap image)
    {
        List<int> result = new List<int> { image.Width, image.Height };
        for (int y = 8; y < image.Height; y += 16) for (int x = 8; x < image.Width; x += 16) result.Add(image.GetPixel(x, y).ToArgb());
        return result.ToArray();
    }
    // Answer the one review dialog an operation opens, and report its rows.
    static void Operation(LauncherForm form, bool restoring, bool confirm, Action<Form, ListView> review)
    {
        Exception failure = null; int reviews = 0;
        DateTime deadline = DateTime.UtcNow.AddSeconds(60);
        // The review callback may pump messages, which can run this timer again while the same dialog is still closing.
        Form answered = null;
        // An operation starts only when nothing else is running, as a click would find it; a check after the last one may still be.
        while ((bool)typeof(LauncherForm).GetField("busy", Instance).GetValue(form) && DateTime.UtcNow < deadline) { Application.DoEvents(); Thread.Sleep(10); }
        using (System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 25 }) {
            timer.Tick += delegate {
                Form dialog = Application.OpenForms.Cast<Form>().FirstOrDefault(window => window != form && window.Owner == form && window.Visible);
                if (dialog == null || dialog == answered) return;
                answered = dialog;
                try {
                    if (dialog.Text != (restoring ? "Review file icon restoration" : "Review file icon changes")) throw new Exception("Unexpected dialog: " + dialog.Text);
                    reviews++;
                    if (review != null) review(dialog, dialog.Controls[0].Controls.OfType<ListView>().Single());
                    dialog.DialogResult = confirm ? DialogResult.OK : DialogResult.Cancel;
                }
                catch (Exception error) { failure = error; dialog.DialogResult = DialogResult.Cancel; }
            };
            timer.Start();
            Task task = (Task)typeof(LauncherForm).GetMethod("ChangeFileIcons", Instance).Invoke(form, new object[] { restoring });
            while (!task.IsCompleted && DateTime.UtcNow < deadline) { Application.DoEvents(); Thread.Sleep(10); }
            timer.Stop();
            if (failure != null) throw failure;
            if (!task.IsCompleted) throw new Exception("The file icon operation did not finish.");
            task.GetAwaiter().GetResult();
            if (review != null && reviews != 1) throw new Exception("A file icon operation must show one review.");
        }
    }
    public static void Run(string root, string source, JavaScriptSerializer json, Action<bool, string> check)
    {
        string links = Path.Combine(root, "file-type-links"), state = Path.Combine(root, "file-type-state");
        Directory.CreateDirectory(links); Directory.CreateDirectory(state);
        File.Copy(Path.Combine(root, "PhotoCraft.lnk"), Path.Combine(links, "PhotoCraft.lnk"));
        string preferencesPath = Path.Combine(state, "tray-preferences.json");
        File.WriteAllText(preferencesPath, json.Serialize(new Preferences { Theme = "Craft-Icons-Zach/HyGel", IconSize = 48, Hotkey = new HotkeySettings { Enabled = false } }));
        string registryPath;
        using (SHA256 sha = SHA256.Create())
            registryPath = @"Software\BetterIcon-Fixtures\" + BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(Path.Combine(state, "project-file-icons")))).Replace("-", "");
        Exception failure = null;
        try {
            using (RegistryKey classes = Registry.CurrentUser.CreateSubKey(registryPath + @"\Classes"))
            using (EventWaitHandle show = new EventWaitHandle(false, EventResetMode.AutoReset))
            using (EventWaitHandle stop = new EventWaitHandle(false, EventResetMode.AutoReset))
            using (LauncherForm form = new LauncherForm(source, new FixtureConfig { ShortcutDirectory = new[] { links }, StateDirectory = state, KeepOpenForAutomation = true }, true, show, stop))
            using (LauncherContext context = new LauncherContext(form))
            using (System.Windows.Forms.Timer ready = new System.Windows.Forms.Timer { Interval = 50 }) {
                Func<string, object> field = name => typeof(LauncherForm).GetField(name, Instance).GetValue(form);
                Func<Preferences> saved = () => json.Deserialize<Preferences>(File.ReadAllText(preferencesPath));
                // PhotoCraft, PdfCraft and WordCraft open their own files here. PNG opens elsewhere.
                Set(classes, ".pcraft", "Photocraft.Document"); Set(classes, ".pdf", "PdfCraft.Document");
                Set(classes, ".docx", "WordCraft.Document"); Set(classes, ".png", "Other.Image");
                // SVG was given to VectorCraft through Open with.
                Set(classes, ".svg", @"Applications\vectorcraft.exe");
                Set(classes, @"Photocraft.Document\DefaultIcon", "original.ico,0");
                ready.Tick += delegate {
                    if ((bool)field("busy") || field("catalog") == null) return;
                    ready.Stop();
                    try {
                        form.ShowManager(); ((TabControl)field("pages")).SelectedIndex = 1; Application.DoEvents();
                        ComboBox themes = (ComboBox)field("themes"), fileThemes = (ComboBox)field("fileThemes");
                        ListView apps = (ListView)field("apps"), preview = (ListView)field("packPreview"), filePreview = (ListView)field("filePreview");
                        Button applyFiles = (Button)field("applyFiles"), restoreFiles = (Button)field("restoreFiles"), refresh = (Button)field("refreshPacksButton");
                        Button removeApp = (Button)field("removePackButton"), removeFile = (Button)field("removeFilePackButton");
                        Label fileDetails = (Label)field("filePackDetails"), status = (Label)field("status");
                        List<Bitmap> appArtwork = (List<Bitmap>)field("appArtwork");
                        ThemeEntry[] appPacks = themes.Items.OfType<ThemeEntry>().ToArray(), filePacks = fileThemes.Items.OfType<ThemeEntry>().ToArray();
                        check(fileThemes.Items[0] is string && (string)fileThemes.Items[0] == "Original file icons" && fileThemes.SelectedIndex == 0 && filePacks.Length == 8 && filePacks.All(pack => pack.HasFileIcons),
                            "The file type list starts with the original icons and holds only packs with file artwork");
                        check(!appPacks.Any(pack => pack.Pack == "Craft-Icons-Komplett") && filePacks.Count(pack => pack.Pack == "Craft-Icons-Komplett") == 5 && appPacks.All(pack => pack.IsDefault || pack.IconCount > 0),
                            "Komplett's document packs moved from the app list to the file type list");
                        check(filePacks.Count(pack => pack.Pack == "Craft-Icons-Mike22") == 3 && filePacks.Where(pack => pack.Pack == "Craft-Icons-Mike22").All(pack => appPacks.Contains(pack)),
                            "A pack with both kinds of artwork is offered in each list");
                        check(themes.Parent == fileThemes.Parent && refresh.Parent == themes.Parent && themes.Top == fileThemes.Top && themes.Right <= fileThemes.Left && fileThemes.Right <= refresh.Left
                            && Math.Abs(themes.Width - fileThemes.Width) <= 2 && themes.Parent.Controls.OfType<Button>().Count() == 1,
                            "The two pack pickers sit side by side with one refresh button to their right");
                        check(!filePreview.Visible && applyFiles.Text == "Restore original file icons..." && applyFiles.Enabled && !restoreFiles.Visible && fileDetails.Text.StartsWith("Original file icons"),
                            "With the original file icons chosen, the preview stays hidden and the one action restores them");
                        check(removeApp.Enabled && !removeFile.Enabled, "The original file icons cannot be removed, while the chosen app pack can");

                        // Browsing packs leaves the Launcher alone.
                        ThemeEntry started = (ThemeEntry)themes.SelectedItem;
                        check(started.Id == "Craft-Icons-Zach/HyGel" && saved().AppliedTheme == started.Id, "An upgraded installation keeps showing the pack it had chosen");
                        int[] before = Pixels(appArtwork[0]); {
                            themes.SelectedItem = appPacks.First(pack => pack.Id == "Craft-Icons-Zach/Pop"); LoadingTests.Wait(form);
                            check(saved().Theme == "Craft-Icons-Zach/Pop" && saved().AppliedTheme == started.Id && Pixels(appArtwork[0]).SequenceEqual(before) && preview.Items.Count == 20,
                                "Choosing an app pack previews it and leaves the Launcher on the applied pack");
                            ThemeEntry documents = filePacks.First(pack => pack.Id == "Craft-Icons-Komplett/Standard");
                            fileThemes.SelectedItem = documents;
                            check((bool)field("busy") && ((Control)field("loadingPanel")).Visible, "Choosing a file type pack shows the loading indication");
                            LoadingTests.Wait(form);
                            check(filePreview.Visible && filePreview.Items.Count == 14 && filePreview.Items.Cast<ListViewItem>().Any(item => item.Text == "PdfCraft") && fileDetails.Text.Contains("file types")
                                && saved().FileTheme == documents.Id && saved().Theme == "Craft-Icons-Zach/Pop" && Pixels(appArtwork[0]).SequenceEqual(before),
                                "Choosing a file type pack previews its artwork and saves that choice on its own");
                            check(applyFiles.Text == "Apply file icons..." && applyFiles.Enabled && restoreFiles.Visible && restoreFiles.Enabled && Math.Abs(preview.Width - filePreview.Width) <= 16 && preview.Right <= filePreview.Left,
                                "The file type preview shares the row with the app preview and enables both file actions");
                            check(removeFile.Enabled && removeApp.Enabled, "Each chosen pack has its own enabled remove button");
                            string problem = (string)typeof(TrayTests).GetMethod("SettingsLayoutProblem", BindingFlags.Static | BindingFlags.NonPublic).Invoke(null, new object[] { (Control)field("settingsContent") });
                            foreach (Size size in new[] { new Size(790, 570), new Size(900, 818) }) {
                                form.Size = size; form.PerformLayout(); Application.DoEvents();
                                problem = problem ?? (string)typeof(TrayTests).GetMethod("SettingsLayoutProblem", BindingFlags.Static | BindingFlags.NonPublic).Invoke(null, new object[] { (Control)field("settingsContent") });
                            }
                            check(problem == null, "Both previews and all four actions fit Manage Icons" + (problem == null ? "" : ": " + problem));

                            // Apply through the review, to the disposable registry key only.
                            string[] changing = null, skipped = null, details = null; string note = null;
                            Operation(form, false, false, (dialog, rows) => { });
                            check(Text(classes, @"Photocraft.Document\DefaultIcon") == "original.ico,0" && Text(classes, @"PdfCraft.Document\DefaultIcon") == null && status.Text.Contains("Cancelled"),
                                "Canceling the file icon review changes nothing");
                            Operation(form, false, true, (dialog, rows) => {
                                changing = rows.Items.Cast<ListViewItem>().Where(item => item.Text == "Ready").Select(item => item.SubItems[1].Text).ToArray();
                                details = rows.Items.Cast<ListViewItem>().Where(item => item.Text == "Ready").Select(item => item.SubItems[2].Text).ToArray();
                                skipped = rows.Items.Cast<ListViewItem>().Where(item => item.Text == "Skipped").Select(item => item.SubItems[1].Text + "=" + item.SubItems[2].Text).ToArray();
                                Label description = dialog.Controls[0].Controls.OfType<Label>().First();
                                note = description.Text;
                                // The note has room for all of its text, wrapped lines included.
                                dialog.PerformLayout(); Application.DoEvents();
                                if (description.Height < TextRenderer.MeasureText(note, description.Font, new Size(description.Width, 0), TextFormatFlags.WordBreak).Height) throw new Exception("The review note is cut off.");
                            });
                            // Three classes follow their app, then the Open with entry. Eight ArtCraft formats that nothing opens yet take their icon directly.
                            check(changing.Length == 12 && changing.Take(4).SequenceEqual(new[] { ".pdf", ".pcraft", ".docx", ".svg" }) && changing.Contains(".fcproj") && !changing.Contains(".png")
                                && skipped.Contains(".png=Uses another default application") && skipped.Contains(".xlsx=No default application") && note.Contains("12 file type(s)") && note.Contains("Test registry only"),
                                "The review lists each file type that will change and why the others are skipped");
                            check(details[0] == "PdfCraft" && details[3] == "VectorCraft (Open with)" && note.Contains("Open with menus"),
                                "A file type given to an app through Open with is ready, and the review says what else that changes");
                            string photo = Text(classes, @"Photocraft.Document\DefaultIcon"), pdf = Text(classes, @"PdfCraft.Document\DefaultIcon"), word = Text(classes, @"WordCraft.Document\DefaultIcon");
                            Func<string, string> file = value => value == null ? null : value.Substring(1, value.LastIndexOf('"') - 1);
                            check(new[] { photo, pdf, word }.All(value => value != null && value.EndsWith("\",0") && File.Exists(file(value)) && file(value).StartsWith(Path.Combine(state, "project-file-icons"), StringComparison.OrdinalIgnoreCase))
                                && new[] { photo, pdf, word }.Distinct().Count() == 3 && Text(classes, @"Other.Image\DefaultIcon") == null && Text(classes, ".png") == "Other.Image" && Text(classes, ".pdf") == "PdfCraft.Document",
                                "Applying writes a converted icon for each ready file class and keeps every opener");
                            string vector = Text(classes, @"Applications\vectorcraft.exe\DefaultIcon");
                            check(vector != null && File.Exists(file(vector)) && vector != photo && Text(classes, ".svg") == @"Applications\vectorcraft.exe",
                                "Applying writes the Open with entry's icon and keeps the Open with choice");
                            check(status.Text.Contains("File icons applied") && !(bool)field("busy") && Pixels(appArtwork[0]).SequenceEqual(before), "Applying file icons reports the result and leaves the Launcher alone");
                            using (Icon written = new Icon(file(pdf), 32, 32)) check(written.Width == 32, "The written file icon is a readable Windows icon");

                            Operation(form, true, true, (dialog, rows) => {
                                changing = rows.Items.Cast<ListViewItem>().Where(item => item.Text == "Ready").Select(item => item.SubItems[1].Text).ToArray();
                            });
                            check(changing.Length == 12 && Text(classes, @"Photocraft.Document\DefaultIcon") == "original.ico,0" && classes.OpenSubKey("PdfCraft.Document") == null && classes.OpenSubKey("WordCraft.Document") == null && classes.OpenSubKey(".fcproj") == null
                                && classes.OpenSubKey("Applications") == null
                                && status.Text.Contains("Original file icons restored"),
                                "Restoring returns each file class to its earlier icon and removes the keys BetterIcon added");
                            Operation(form, true, false, null);
                            check(status.Text.Contains("No BetterIcon file icons to restore"), "Restoring again finds nothing left to change");

                            ThemeEntry mixed = filePacks.First(pack => pack.Id == "Craft-Icons-Mike22/CraftApps AIO November - Dark");
                            fileThemes.SelectedItem = mixed; LoadingTests.Wait(form);
                            check(filePreview.Items.Count == 14 && saved().FileTheme == mixed.Id && filePreview.Items.Cast<ListViewItem>().All(item => !String.IsNullOrEmpty(item.ToolTipText)),
                                "A pack with app and file artwork previews its file icons when chosen as the file type pack");
                            fileThemes.SelectedIndex = 0; LoadingTests.Wait(form);
                            check(!filePreview.Visible && saved().FileTheme == null && applyFiles.Text == "Restore original file icons..." && preview.Width > filePreview.Width,
                                "Choosing the original file icons clears the saved pack and returns the row to the app preview");

                            // Each remove button takes the pack chosen in its own list.
                            Func<Button, bool, string> remove = (button, confirm) => {
                                string message = null;
                                using (System.Windows.Forms.Timer answer = new System.Windows.Forms.Timer { Interval = 25 }) {
                                    answer.Tick += delegate {
                                        Form dialog = Application.OpenForms.Cast<Form>().FirstOrDefault(window => window != form && window.Visible && window.Text == "Remove icon pack");
                                        if (dialog == null) return;
                                        answer.Stop();
                                        message = String.Join(" ", dialog.Controls[0].Controls.OfType<Label>().Select(label => label.Text));
                                        dialog.DialogResult = confirm ? DialogResult.OK : DialogResult.Cancel;
                                    };
                                    answer.Start(); button.PerformClick(); answer.Stop();
                                }
                                LoadingTests.Wait(form);
                                return message;
                            };
                            Func<ComboBox, string, ThemeEntry> listed = (picker, id) => picker.Items.OfType<ThemeEntry>().FirstOrDefault(pack => pack.Id == id);
                            const string pop = "Craft-Icons-Zach/Pop";
                            fileThemes.SelectedItem = listed(fileThemes, documents.Id); LoadingTests.Wait(form);
                            string asked = remove(removeFile, false);
                            check(asked != null && asked.Contains(documents.ToString()) && !asked.Contains("both") && listed(fileThemes, documents.Id) != null && saved().FileTheme == documents.Id,
                                "Remove file pack names the chosen file type pack, and canceling keeps it");
                            int appCount = themes.Items.Count;
                            remove(removeFile, true);
                            check(listed(fileThemes, documents.Id) == null && fileThemes.SelectedIndex == 0 && saved().FileTheme == null && !removeFile.Enabled
                                && themes.Items.Count == appCount && ((ThemeEntry)themes.SelectedItem).Id == pop && status.Text.Contains("Pack removed"),
                                "Remove file pack removes the file type pack and leaves the app list and its chosen pack alone");
                            fileThemes.SelectedItem = listed(fileThemes, mixed.Id); LoadingTests.Wait(form);
                            asked = remove(removeFile, true);
                            check(asked != null && asked.Contains("both the app and the file type list") && listed(fileThemes, mixed.Id) == null && listed(themes, mixed.Id) == null
                                && themes.Items.Count == appCount - 1 && ((ThemeEntry)themes.SelectedItem).Id == pop,
                                "Removing a pack that holds both kinds of artwork says so and takes it out of both lists");
                            ThemeEntry kept = fileThemes.Items.OfType<ThemeEntry>().First();
                            fileThemes.SelectedItem = kept; LoadingTests.Wait(form);
                            int fileCount = fileThemes.Items.Count;
                            asked = remove(removeApp, true);
                            check(asked != null && asked.Contains("Pop") && !asked.Contains("both") && listed(themes, pop) == null && fileThemes.Items.Count == fileCount
                                && fileThemes.SelectedItem is ThemeEntry && ((ThemeEntry)fileThemes.SelectedItem).Id == kept.Id && saved().FileTheme == kept.Id,
                                "Remove app pack removes the chosen app pack and leaves the file type list and its chosen pack alone");

                            // Types outside the index whose class runs PhotoCraft take a personal pack's PhotoCraft-files art, and
                            // the review lists them with their app, marked.
                            string programs = Path.Combine(root, "file-type-programs", "PhotoCraft"); Directory.CreateDirectory(programs);
                            string photoExe = Path.Combine(programs, "photocraft.exe"); File.Copy(Path.Combine(root, "LaunchProbe.exe"), photoExe, true);
                            Set(classes, @"Photocraft.Document\shell\open\command", "\"" + photoExe + "\" \"%1\"");
                            Set(classes, @"BIFixture.Catch\shell\open\command", "\"" + photoExe + "\" \"%1\"");
                            Set(classes, ".bicatch", "BIFixture.Catch"); Set(classes, ".bicatch2", "BIFixture.Catch");
                            // A type outside the index given to PhotoCraft through Open with, whose entry runs PhotoCraft's program.
                            Set(classes, @"Applications\photocraft.exe\shell\open\command", "\"" + photoExe + "\" \"%1\""); Set(classes, ".bicatch3", @"Applications\photocraft.exe");
                            string artFolder = Path.Combine(root, "catch-all-pack"); Directory.CreateDirectory(Path.Combine(artFolder, "FileTypes"));
                            foreach (var art in new[] { Tuple.Create("PhotoCraft-files.png", Color.Purple), Tuple.Create("pcraft.png", Color.Red) })
                                using (Bitmap image = new Bitmap(32, 32)) { using (Graphics g = Graphics.FromImage(image)) g.Clear(art.Item2); image.Save(Path.Combine(artFolder, "FileTypes", art.Item1), System.Drawing.Imaging.ImageFormat.Png); }
                            ThemeEntry mine = ((PackLibrary)field("library")).Import(artFolder);
                            typeof(LauncherForm).GetMethod("ShowSavedPack", Instance, null, new[] { typeof(ThemeEntry), typeof(bool) }, null).Invoke(form, new object[] { mine, true });
                            LoadingTests.Wait(form);
                            bool tipped = filePreview.Items.Cast<ListViewItem>().Any(item => (item.ToolTipText ?? "").Contains("Also other file types PhotoCraft opens"));
                            string catchRow = null, catchNote = null, openRow = null; int detailsWidth = 0, openWidth = 0;
                            Operation(form, false, true, (dialog, rows) => {
                                catchRow = rows.Items.Cast<ListViewItem>().Where(item => item.SubItems[1].Text == ".bicatch, .bicatch2").Select(item => item.Text + "|" + item.SubItems[2].Text).FirstOrDefault();
                                ListViewItem open = rows.Items.Cast<ListViewItem>().FirstOrDefault(item => item.SubItems[1].Text == ".bicatch3");
                                if (open != null) { openRow = open.Text + "|" + open.SubItems[2].Text; openWidth = TextRenderer.MeasureText(open.SubItems[2].Text, rows.Font).Width; }
                                detailsWidth = rows.Columns[2].Width;
                                Label description = dialog.Controls[0].Controls.OfType<Label>().First();
                                catchNote = description.Text;
                                dialog.PerformLayout(); Application.DoEvents();
                                if (description.Height < TextRenderer.MeasureText(catchNote, description.Font, new Size(description.Width, 0), TextFormatFlags.WordBreak).Height) throw new Exception("The review note is cut off.");
                            });
                            string catchIcon = Text(classes, @"BIFixture.Catch\DefaultIcon");
                            check(((ThemeEntry)fileThemes.SelectedItem).Id == mine.Id && catchRow == "Ready|PhotoCraft (other file types)" && catchNote.Contains("(other file types)") && catchIcon != null && File.Exists(file(catchIcon))
                                && file(catchIcon).StartsWith(Path.Combine(state, "project-file-icons"), StringComparison.OrdinalIgnoreCase) && Text(classes, ".bicatch") == "BIFixture.Catch" && classes.OpenSubKey(@".bicatch\DefaultIcon") == null,
                                "The review lists the types outside BetterIcon's list that a class of PhotoCraft opens, marked (other file types), and Apply gives the class the pack's PhotoCraft-files art");
                            string openColor = IconColor(Text(classes, @"Applications\photocraft.exe\DefaultIcon"));
                            if (openRow != "Ready|PhotoCraft (Open with, other file types)" || openWidth == 0 || detailsWidth < openWidth + 8 || !catchNote.Contains("Open with menus") || openColor != "purple")
                                Console.WriteLine("  Open with row: " + (openRow ?? "(none)") + ", Details " + detailsWidth + " px for " + openWidth + " px of text, entry art " + openColor);
                            check(openRow == "Ready|PhotoCraft (Open with, other file types)" && openWidth > 0 && detailsWidth >= openWidth + 8 && catchNote.Contains("Open with menus")
                                && openColor == "purple",
                                "A type outside the list given to PhotoCraft through Open with is marked (Open with, other file types), shown whole, the note says Open with menus may change, and the entry takes the PhotoCraft-files art");
                            check(IconColor(catchIcon) == "purple" && IconColor(Text(classes, @"Photocraft.Document\DefaultIcon")) == "red",
                                "Apply gives the class itself the pack's PhotoCraft-files art, which draws purple, while PhotoCraft's own class draws the red pcraft art");
                            check(tipped, "The file type preview's tile for PhotoCraft's art says it also covers the other file types PhotoCraft opens");
                            // Applying the same pack again: the class's row is unchanged, still marked, and the note explains it.
                            string again = null, againNote = null;
                            Operation(form, false, false, (dialog, rows) => {
                                again = rows.Items.Cast<ListViewItem>().Where(item => item.SubItems[1].Text == ".bicatch, .bicatch2").Select(item => item.Text + "|" + item.SubItems[2].Text).FirstOrDefault();
                                againNote = dialog.Controls[0].Controls.OfType<Label>().First().Text;
                            });
                            check(again == "Unchanged|Already applied: PhotoCraft (other file types)" && againNote.Contains("(other file types) is not in BetterIcon's list"),
                                "Applying the same pack again lists the class as unchanged, still marked (other file types), with the note that explains the mark");
                            Operation(form, true, true, null);
                            check(catchIcon != null && classes.OpenSubKey(@"BIFixture.Catch\DefaultIcon") == null && Text(classes, @"BIFixture.Catch\shell\open\command") != null && status.Text.Contains("Original file icons restored"),
                                "Restoring the file icons takes that art off the class again");
                        }
                        stop.Set();
                    }
                    catch (Exception error) { failure = error; context.ExitThread(); }
                };
                ready.Start(); Application.Run(context);
            }
        }
        finally {
            Registry.CurrentUser.DeleteSubKeyTree(registryPath, false);
            // Leave no empty parent key behind when this was the only fixture.
            const string fixtures = @"Software\BetterIcon-Fixtures";
            bool empty;
            using (RegistryKey parent = Registry.CurrentUser.OpenSubKey(fixtures)) empty = parent != null && parent.SubKeyCount == 0 && parent.ValueCount == 0;
            if (empty) Registry.CurrentUser.DeleteSubKey(fixtures, false);
        }
        if (failure != null) throw failure;
        RunPublished(root, source, json, check);
    }

    // The colour at the centre of the icon a DefaultIcon value names: purple, red, other, or why there is none.
    static string IconColor(string value)
    {
        if (value == null || !value.StartsWith("\"") || value.LastIndexOf('"') < 1) return "none";
        string path = value.Substring(1, value.LastIndexOf('"') - 1);
        if (!File.Exists(path)) return "missing";
        using (Icon icon = new Icon(path, 32, 32))
        using (Bitmap image = icon.ToBitmap()) {
            Color c = image.GetPixel(image.Width / 2, image.Height / 2);
            return c.A < 200 ? "clear" : c.R > 90 && c.B > 90 && c.G < 60 ? "purple" : c.R > 180 && c.G < 60 && c.B < 60 ? "red" : "other";
        }
    }
    static void CopyFolder(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (string file in Directory.GetFiles(from)) File.Copy(file, Path.Combine(to, Path.GetFileName(file)));
        foreach (string folder in Directory.GetDirectories(from)) CopyFolder(folder, Path.Combine(to, Path.GetFileName(folder)));
    }
    const string OptinPack = "Craft-Icons-OptinFixture/Files";
    const string PublishedTitle = "A published pack whose list names PhotoCraft's art FileTypes/PhotoCraft-files, chosen and applied as the tray does, gives that art to a class outside the index that runs PhotoCraft, and its format art to PhotoCraft's own class";
    // A published pack the way the tray takes it: Test-TrayUI.ps1 leaves a downloaded pack in a state of its own, named by a
    // refreshed pack list, whose PhotoCraft art is FileTypes/PhotoCraft-files.png (purple) beside its pcraft art (red).
    public static void RunPublished(string root, string source, JavaScriptSerializer json, Action<bool, string> check)
    {
        string built = Path.Combine(root, "optin-packs-state");
        if (!Directory.Exists(built)) { Console.WriteLine("SKIP " + PublishedTitle + " (Test-TrayUI.ps1 made no published pack fixture)"); return; }
        string state = Path.Combine(root, "optin-packs-run"), links = Path.Combine(root, "optin-packs-links");
        CopyFolder(built, state); Directory.CreateDirectory(links);
        File.Copy(Path.Combine(root, "PhotoCraft.lnk"), Path.Combine(links, "PhotoCraft.lnk"));
        File.WriteAllText(Path.Combine(state, "tray-preferences.json"), json.Serialize(new Preferences { Theme = "Craft-Icons-Zach/HyGel", FileTheme = OptinPack, IconSize = 48, Hotkey = new HotkeySettings { Enabled = false } }));
        string programs = Path.Combine(root, "optin-programs", "PhotoCraft"); Directory.CreateDirectory(programs);
        string photoExe = Path.Combine(programs, "photocraft.exe"); File.Copy(Path.Combine(root, "LaunchProbe.exe"), photoExe, true);
        string registryPath;
        using (SHA256 sha = SHA256.Create())
            registryPath = @"Software\BetterIcon-Fixtures\" + BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(Path.Combine(state, "project-file-icons")))).Replace("-", "");
        Exception failure = null;
        try {
            using (RegistryKey classes = Registry.CurrentUser.CreateSubKey(registryPath + @"\Classes"))
            using (EventWaitHandle show = new EventWaitHandle(false, EventResetMode.AutoReset))
            using (EventWaitHandle stop = new EventWaitHandle(false, EventResetMode.AutoReset))
            using (LauncherForm form = new LauncherForm(source, new FixtureConfig { ShortcutDirectory = new[] { links }, StateDirectory = state, KeepOpenForAutomation = true }, true, show, stop))
            using (LauncherContext context = new LauncherContext(form))
            using (System.Windows.Forms.Timer ready = new System.Windows.Forms.Timer { Interval = 50 }) {
                Func<string, object> field = name => typeof(LauncherForm).GetField(name, Instance).GetValue(form);
                // PhotoCraft's class and a class outside the index, both run by PhotoCraft's program in PhotoCraft's folder.
                Set(classes, ".pcraft", "Photocraft.Document"); Set(classes, @"Photocraft.Document\shell\open\command", "\"" + photoExe + "\" \"%1\"");
                Set(classes, @"BIFixture.Catch\shell\open\command", "\"" + photoExe + "\" \"%1\""); Set(classes, ".bicatch", "BIFixture.Catch");
                ready.Tick += delegate {
                    if ((bool)field("busy") || field("catalog") == null) return;
                    ready.Stop();
                    try {
                        form.ShowManager(); ((TabControl)field("pages")).SelectedIndex = 1; Application.DoEvents();
                        ThemeEntry files = ((ComboBox)field("fileThemes")).SelectedItem as ThemeEntry;
                        Label status = (Label)field("status");
                        string row = null;
                        Operation(form, false, true, (dialog, rows) => {
                            row = rows.Items.Cast<ListViewItem>().Where(item => item.SubItems[1].Text == ".bicatch").Select(item => item.Text + "|" + item.SubItems[2].Text).FirstOrDefault();
                        });
                        string catchIcon = Text(classes, @"BIFixture.Catch\DefaultIcon"), photoIcon = Text(classes, @"Photocraft.Document\DefaultIcon");
                        // Read by name, so this check also runs against builds from before the field existed.
                        PropertyInfo optedField = typeof(ThemeEntry).GetProperty("UnlistedFileIconApps");
                        string[] opted = files == null || optedField == null ? null : optedField.GetValue(files, null) as string[];
                        check(files != null && files.Id == OptinPack && !files.Managed && opted != null && opted.SequenceEqual(new[] { "PhotoCraft" })
                            && row == "Ready|PhotoCraft (other file types)" && IconColor(catchIcon) == "purple" && IconColor(photoIcon) == "red" && status.Text.Contains("File icons applied"), PublishedTitle);
                        Operation(form, true, true, null);
                        stop.Set();
                    }
                    catch (Exception error) { failure = error; context.ExitThread(); }
                };
                ready.Start(); Application.Run(context);
            }
        }
        finally {
            Registry.CurrentUser.DeleteSubKeyTree(registryPath, false);
            const string fixtures = @"Software\BetterIcon-Fixtures";
            bool empty;
            using (RegistryKey parent = Registry.CurrentUser.OpenSubKey(fixtures)) empty = parent != null && parent.SubKeyCount == 0 && parent.ValueCount == 0;
            if (empty) Registry.CurrentUser.DeleteSubKey(fixtures, false);
        }
        if (failure != null) throw failure;
    }
}
