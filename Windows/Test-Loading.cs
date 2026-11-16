using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using BetterIcon.Tray;

static class LoadingTests
{
    static readonly BindingFlags instance = BindingFlags.Instance | BindingFlags.NonPublic;
    static object Field(LauncherForm form, string name) { return typeof(LauncherForm).GetField(name, instance).GetValue(form); }
    public static void Wait(LauncherForm form)
    {
        Task task = (Task)Field(form, "packLoadTask"); Stopwatch timeout = Stopwatch.StartNew();
        while (!task.IsCompleted) {
            if (timeout.ElapsedMilliseconds > 30000) throw new Exception("Icon pack loading did not complete within 30 seconds.");
            Application.DoEvents(); Thread.Sleep(5);
        }
        task.GetAwaiter().GetResult();
    }
    public static void Run(LauncherForm form, string preferencesPath, Action<bool, string> check)
    {
        ComboBox themes = (ComboBox)Field(form, "themes");
        ThemeEntry previous = (ThemeEntry)themes.SelectedItem;
        ThemeEntry target = themes.Items.Cast<ThemeEntry>().First(theme => !theme.IsDefault && theme.IconCount >= 14 && theme.Id != previous.Id);
        TabControl pages = (TabControl)Field(form, "pages");
        ListView apps = (ListView)Field(form, "apps"), preview = (ListView)Field(form, "packPreview");
        Control indicator = (Control)Field(form, "loadingPanel");
        ProgressBar progress = (ProgressBar)Field(form, "loadingProgress");
        Label message = (Label)Field(form, "loadingMessage");
        JavaScriptSerializer json = new JavaScriptSerializer();
        Preferences before = json.Deserialize<Preferences>(File.ReadAllText(preferencesPath));
        int oldAppCount = apps.Items.Count, oldPreviewCount = preview.Items.Count, pulses = 0;
        bool observedBusy = false;
        bool threadChecks = Control.CheckForIllegalCrossThreadCalls;
        Control.CheckForIllegalCrossThreadCalls = true;
        using (System.Windows.Forms.Timer heartbeat = new System.Windows.Forms.Timer { Interval = 10 }) {
            heartbeat.Tick += delegate { pulses++; observedBusy |= (bool)Field(form, "busy") && indicator.Visible; };
            try {
                form.ShowManager(); pages.SelectedIndex = 1; heartbeat.Start();
                themes.SelectedItem = target;
                check((bool)Field(form, "busy") && indicator.Visible && progress.Visible && progress.Style == ProgressBarStyle.Marquee && progress.MarqueeAnimationSpeed > 0 && message.Text.Contains(target.ToString()),
                    "Selecting a pack immediately shows its name and an animated loading indication");
                check(!themes.Enabled && !apps.Enabled && !preview.Enabled && !((Control)Field(form, "apply")).Enabled && !((Control)Field(form, "iconSizeSlider")).Enabled,
                    "Loading disables conflicting pack, launch, apply and zoom actions");
                check(apps.Items.Count == oldAppCount && preview.Items.Count == oldPreviewCount && json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).Theme == before.Theme,
                    "Existing artwork and the saved pack remain intact while new previews load");
                Rectangle overlap = Rectangle.Intersect(pages.Bounds, indicator.Bounds);
                check((overlap.Width == 0 || overlap.Height == 0) && form.ClientRectangle.Contains(indicator.Bounds),
                    "The loading indicator has its own space below both tabs without overlapping the popup");
                Task pending = (Task)Field(form, "packLoadTask");
                themes.SelectedItem = previous;
                check(ReferenceEquals(themes.SelectedItem, target) && ReferenceEquals(pending, Field(form, "packLoadTask")),
                    "A second selection cannot replace the in-flight pack or start overlapping work");
                Wait(form); heartbeat.Stop();
                check(pulses > 0 && observedBusy, "The native window continues processing timer messages while pack images are decoded");
                check(!(bool)Field(form, "busy") && !indicator.Visible && progress.MarqueeAnimationSpeed == 0 && themes.Enabled && apps.Enabled && preview.Enabled,
                    "Loading stops and normal controls return after both preview grids are ready");
                check(preview.Items.Count == target.IconCount && ((Label)Field(form, "status")).Text.Contains("loaded") && json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).Theme == target.Id,
                    "The completed pack updates its artwork, ready status and saved selection together");
                Preferences after = json.Deserialize<Preferences>(File.ReadAllText(preferencesPath));
                check(after.Scope == before.Scope && after.AppearanceMode == before.AppearanceMode && after.AppIconStyle == before.AppIconStyle && after.AppIconVariant == before.AppIconVariant && json.Serialize(after.Hotkey) == json.Serialize(before.Hotkey) && after.DefaultShortcuts.SequenceEqual(before.DefaultShortcuts),
                    "Asynchronous pack changes preserve shortcut scope, app appearance, hotkey and individual defaults");

                // An invalid in-memory fixture exercises cleanup without changing any pack files.
                ThemeIcon[] originalIcons = previous.Icons;
                Exception dialogFailure = null; bool errorSeen = false;
                using (System.Windows.Forms.Timer dismiss = new System.Windows.Forms.Timer { Interval = 20 }) {
                    dismiss.Tick += delegate {
                        foreach (Form dialog in form.OwnedForms) if (dialog.Text == "BetterIcon") {
                            try { errorSeen = true; dialog.DialogResult = DialogResult.OK; dialog.Close(); }
                            catch (Exception error) { dialogFailure = error; }
                        }
                    };
                    try {
                        // previous is a personal fixture pack in the main integration sequence.
                        ThemeEntry broken = previous.IsDefault ? themes.Items.Cast<ThemeEntry>().First(theme => !theme.IsDefault && theme.Id != target.Id) : previous;
                        originalIcons = broken.Icons; broken.Icons = null; dismiss.Start();
                        try { themes.SelectedItem = broken; Wait(form); }
                        finally { broken.Icons = originalIcons; }
                    }
                    finally { dismiss.Stop(); }
                }
                if (dialogFailure != null) throw dialogFailure;
                check(errorSeen && !(bool)Field(form, "busy") && !indicator.Visible && themes.Enabled && ReferenceEquals(themes.SelectedItem, target) && json.Deserialize<Preferences>(File.ReadAllText(preferencesPath)).Theme == target.Id,
                    "A failed preview load clears loading and restores the last successful selection without saving the failed pack");
            }
            finally {
                heartbeat.Stop(); Control.CheckForIllegalCrossThreadCalls = threadChecks;
                typeof(LauncherForm).GetMethod("ReloadLibrary", instance).Invoke(form, new object[] { previous.Id });
            }
        }
    }
}
