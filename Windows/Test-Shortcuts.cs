using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using BetterIcon.Tray;

static class ShortcutScopeTests
{
    const BindingFlags Instance = BindingFlags.Instance | BindingFlags.NonPublic;
    [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr window);
    static IEnumerable<Control> Children(Control parent)
    {
        foreach (Control child in parent.Controls) { yield return child; foreach (Control nested in Children(child)) yield return nested; }
    }
    public static void SelectScope(Action show, string scope)
    {
        bool selected = false;
        using (System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 25 }) {
            timer.Tick += delegate {
                ShortcutScopeDialog dialog = Application.OpenForms.OfType<ShortcutScopeDialog>().FirstOrDefault();
                if (dialog == null) return;
                selected = true; timer.Stop();
                dialog.Controls.Find(scope == null ? "CancelScope" : scope + "Choice", true).OfType<Button>().Single().PerformClick();
            };
            timer.Start(); show();
        }
        if (!selected) throw new Exception("The shortcut-location dialog did not open.");
    }
    static void Operation(LauncherForm form, string action, string scope, bool confirm, Action<ShortcutScopeDialog> inspect, Action<Form> review)
    {
        Exception failure = null; int prompts = 0;
        DateTime deadline = DateTime.UtcNow.AddSeconds(45);
        using (System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 25 }) {
            timer.Tick += delegate {
                Form dialog = Application.OpenForms.Cast<Form>().FirstOrDefault(window => window != form && window.Owner == form && window.Visible);
                try {
                    if (DateTime.UtcNow > deadline) throw new Exception("Timed out in " + action + ".");
                    if (dialog == null) return;
                    ShortcutScopeDialog choice = dialog as ShortcutScopeDialog;
                    if (choice != null) {
                        prompts++; if (prompts != 1) throw new Exception("One operation opened multiple location prompts.");
                        if (inspect != null) inspect(choice);
                        choice.Controls.Find(scope == null ? "CancelScope" : scope + "Choice", true).OfType<Button>().Single().PerformClick();
                    }
                    else if (dialog.Text == "Review icon changes" || dialog.Text == "Review restoration") {
                        if (review != null) review(dialog);
                        dialog.DialogResult = confirm ? DialogResult.OK : DialogResult.Cancel;
                    }
                    else if (dialog.Text == "Operation results") dialog.DialogResult = DialogResult.OK;
                    else throw new Exception("Unexpected dialog: " + dialog.Text + " " + String.Join(" ", Children(dialog).OfType<Label>().Select(label => label.Text)));
                }
                catch (Exception error) { failure = error; if (dialog != null) dialog.DialogResult = DialogResult.Cancel; }
            };
            timer.Start();
            Task task = (Task)typeof(LauncherForm).GetMethod(action, Instance).Invoke(form, action == "RestoreIcons" ? new object[] { null } : null);
            while (!task.IsCompleted && DateTime.UtcNow < deadline.AddSeconds(2)) { Application.DoEvents(); Thread.Sleep(10); }
            timer.Stop(); if (failure != null) throw failure;
            if (!task.IsCompleted) throw new Exception("Shortcut operation did not finish.");
            task.GetAwaiter().GetResult();
            if (prompts != 1) throw new Exception("Each shortcut operation must ask for locations.");
        }
    }
    public static void Run(string root, string source, JavaScriptSerializer json, Action<bool, string> check)
    {
        string links = Path.Combine(root, "scope-choice-links"), state = Path.Combine(root, "scope-choice-state");
        Directory.CreateDirectory(links); Directory.CreateDirectory(state);
        string photo = Path.Combine(links, "PhotoCraft.lnk"), film = Path.Combine(links, "FilmCraft.lnk");
        File.Copy(Path.Combine(root, "PhotoCraft.lnk"), photo); File.Copy(Path.Combine(root, "PhotoCraft.lnk"), film);
        byte[] originalPhoto = File.ReadAllBytes(photo), originalFilm = File.ReadAllBytes(film);
        string preferencesPath = Path.Combine(state, "tray-preferences.json");
        File.WriteAllText(preferencesPath, json.Serialize(new Preferences { Theme = "Craft-Icons-Zach/Satin", Scope = "AllUsers", IconSize = 48, Hotkey = new HotkeySettings { Enabled = false } }));
        Exception failure = null;
        using (EventWaitHandle show = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (EventWaitHandle stop = new EventWaitHandle(false, EventResetMode.AutoReset))
        using (LauncherForm form = new LauncherForm(source, new FixtureConfig { ShortcutDirectory = new[] { links }, StateDirectory = state, KeepOpenForAutomation = true }, true, show, stop))
        using (LauncherContext context = new LauncherContext(form))
        using (System.Windows.Forms.Timer ready = new System.Windows.Forms.Timer { Interval = 50 }) {
            Func<string, object> field = name => typeof(LauncherForm).GetField(name, Instance).GetValue(form);
            ready.Tick += delegate {
                if ((bool)field("busy") || field("catalog") == null) return;
                ready.Stop();
                try {
                    form.ShowManager();
                    foreach (Size size in new[] { new Size(790, 570), new Size(900, 690) }) {
                        form.Size = size; ((TabControl)field("pages")).SelectedIndex = 1;
                        form.PerformLayout(); Application.DoEvents();
                        string problem = (string)typeof(TrayTests).GetMethod("SettingsLayoutProblem", BindingFlags.Static | BindingFlags.NonPublic).Invoke(null, new object[] { (Control)field("settingsContent") });
                        check(problem == null, "Simplified Settings remains contained at " + size.Width + "x" + size.Height + (problem == null ? "" : ": " + problem));
                    }
                    check(!Children(form).Any(control => control.AccessibleName == "Shortcut locations") && typeof(LauncherForm).GetField("scopes", Instance) == null,
                        "Settings no longer contains a shortcut-location dropdown");
                    byte[] before = File.ReadAllBytes(preferencesPath);
                    int inspected = 0;
                    Action<ShortcutScopeDialog> inspect = dialog => {
                        inspected++;
                        Label notice = dialog.Controls.Find("AdministratorNotice", true).OfType<Label>().Single();
                        Button all = dialog.Controls.Find("AllUsersChoice", true).OfType<Button>().Single();
                        check(dialog.SelectedScope == null && dialog.CancelButton != null && notice.Text.Contains("requires administrator privileges") && all.AccessibleDescription.Contains("administrator privileges"),
                            "The " + (inspected == 1 ? "Apply" : "Restore") + " prompt starts unchosen and clearly explains administrator privileges for all users");
                        string problem = (string)typeof(TrayTests).GetMethod("SettingsLayoutProblem", BindingFlags.Static | BindingFlags.NonPublic).Invoke(null, new object[] { dialog });
                        check(problem == null, "The location prompt fits its native controls at the shipping display DPI" + (problem == null ? "" : ": " + problem));
                        check(!((ContextMenuStrip)field("trayMenu")).Enabled && !IsWindowEnabled(form.Handle), "The location prompt owns input while its native parent and tray commands are unavailable");
                    };
                    Operation(form, "ApplyTheme", null, false, inspect, null);
                    Operation(form, "RestoreIcons", null, false, inspect, null);
                    ((TabControl)field("pages")).SelectedIndex = 1;
                    SelectScope(() => ((Button)field("apply")).PerformClick(), null);
                    SelectScope(() => ((Button)field("restore")).PerformClick(), null);
                    SelectScope(() => ((ContextMenuStrip)field("trayMenu")).Items.OfType<ToolStripMenuItem>().Single(item => item.Text == "Restore original icons...").PerformClick(), null);
                    check(true, "Settings Apply, Settings Restore and tray Restore all open a fresh location prompt");
                    check(File.ReadAllBytes(preferencesPath).SequenceEqual(before) && !File.Exists(Path.Combine(state, "manifest.json")) && File.ReadAllBytes(photo).SequenceEqual(originalPhoto) && File.ReadAllBytes(film).SequenceEqual(originalFilm),
                        "Canceling either location prompt leaves preferences, shortcuts and backup state unchanged");
                    int applyReviews = 0;
                    Operation(form, "ApplyTheme", "CurrentUser", true, null, dialog => {
                        string text = String.Join(" ", Children(dialog).OfType<Label>().Select(label => label.Text));
                        applyReviews++; check(text.Contains("your Desktop and Start menu") && !text.Contains("administrator access"), "Current-user application reviews the selected locations before writing fixture shortcuts");
                    });
                    check(applyReviews == 1 && !File.ReadAllBytes(photo).SequenceEqual(originalPhoto) && !File.ReadAllBytes(film).SequenceEqual(originalFilm) && json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).Scope == "AllUsers",
                        "The current-user choice applies successfully despite an opposite legacy preference");
                    byte[] appliedPhoto = File.ReadAllBytes(photo), manifest = File.ReadAllBytes(Path.Combine(state, "manifest.json"));
                    int sharedReviews = 0;
                    Operation(form, "ApplyTheme", "AllUsers", false, null, dialog => {
                        string text = String.Join(" ", Children(dialog).OfType<Label>().Select(label => label.Text));
                        sharedReviews++; check(text.Contains("shared Desktop and Start menu") && text.Contains("administrator access"), "All-users application previews shared locations and the administrator requirement before confirmation");
                    });
                    check(sharedReviews == 1 && File.ReadAllBytes(photo).SequenceEqual(appliedPhoto) && File.ReadAllBytes(Path.Combine(state, "manifest.json")).SequenceEqual(manifest),
                        "Canceling an all-users apply review avoids elevation and leaves the prior installation intact");
                    // Give the read-only all-users restore preview its own matching
                    // manifest. Confirming it would require elevation, so cancel.
                    var sharedManifest = json.Deserialize<Dictionary<string, object>>(EncodingText(manifest));
                    sharedManifest["Scope"] = "AllUsers";
                    File.WriteAllText(Path.Combine(state, "manifest.json"), json.Serialize(sharedManifest));
                    byte[] sharedBytes = File.ReadAllBytes(Path.Combine(state, "manifest.json")); int restoreReviews = 0;
                    Operation(form, "RestoreIcons", "AllUsers", false, null, dialog => {
                        restoreReviews++;
                        string text = String.Join(" ", Children(dialog).OfType<Label>().Select(label => label.Text));
                        check(text.Contains("shared locations") && text.Contains("administrator access required"), "All-users restoration reviews the shared backups and administrator requirement");
                    });
                    check(restoreReviews == 1 && File.ReadAllBytes(photo).SequenceEqual(appliedPhoto) && File.ReadAllBytes(Path.Combine(state, "manifest.json")).SequenceEqual(sharedBytes), "Canceling an all-users restore review preserves shortcuts and backups without elevation");
                    File.WriteAllBytes(Path.Combine(state, "manifest.json"), manifest);
                    Operation(form, "RestoreIcons", "CurrentUser", true, null, dialog => {
                        string text = String.Join(" ", Children(dialog).OfType<Label>().Select(label => label.Text));
                        check(text.Contains("your locations") && !text.Contains("administrator access required"), "Current-user restoration uses the newly chosen locations instead of the legacy preference");
                    });
                    check(File.ReadAllBytes(photo).SequenceEqual(originalPhoto) && File.ReadAllBytes(film).SequenceEqual(originalFilm), "Current-user restoration returns both disposable shortcuts byte-for-byte");
                    check(!((bool)field("busy")) && ((ContextMenuStrip)field("trayMenu")).Enabled && IsWindowEnabled(form.Handle), "Completed and canceled scope operations restore normal launcher and tray input");
                    ComboBox themes = (ComboBox)field("themes"); themes.SelectedIndex = 0; LoadingTests.Wait(form);
                    byte[] defaultBefore = File.ReadAllBytes(preferencesPath);
                    SelectScope(() => ((Button)field("apply")).PerformClick(), null);
                    check(File.ReadAllBytes(preferencesPath).SequenceEqual(defaultBefore) && File.ReadAllBytes(photo).SequenceEqual(originalPhoto), "Applying the virtual ArtCraft default also asks for locations and can be canceled without changes");
                    stop.Set();
                }
                catch (Exception error) { failure = error; context.ExitThread(); }
            };
            ready.Start(); Application.Run(context); if (failure != null) throw failure;
        }
    }
    static string EncodingText(byte[] bytes) { return System.Text.Encoding.UTF8.GetString(bytes).TrimStart('\uFEFF'); }
}
