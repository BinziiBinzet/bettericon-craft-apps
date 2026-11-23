using System;
using System.Collections.Generic;
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
        void ShowSavedPack(ThemeEntry pack) { ShowSavedPack(pack, false); }
        // Select a saved pack where its artwork applies. An edited pack keeps its place in both lists.
        void ShowSavedPack(ThemeEntry pack, bool fromFiles)
        {
            bool appUsesPack = SelectedTheme != null && SelectedTheme.Managed && SelectedTheme.LibraryId == pack.LibraryId;
            bool filesUsePack = SelectedFileTheme != null && SelectedFileTheme.Managed && SelectedFileTheme.LibraryId == pack.LibraryId;
            string app = pack.IconCount > 0 && (!fromFiles || appUsesPack) ? pack.Id : null;
            string files = pack.HasFileIcons && (fromFiles || filesUsePack || pack.IconCount == 0) ? pack.Id : null;
            if (files == null && filesUsePack) preferences.FileTheme = null;
            ReloadPacks(app, files);
            status.Text = "Saved " + pack.Name + ".";
        }
        // File types keep their opener. Only the current user's icon for each file class changes,
        // and the earlier value is kept so it can be restored exactly.
        async Task ChangeFileIcons(bool restoring)
        {
            ThemeEntry pack = SelectedFileTheme;
            if (busy || (!restoring && pack == null)) return;
            FileArtwork artwork = restoring ? new FileArtwork() : ProjectFormat.Artwork(pack);
            Dictionary<string, string> formats = artwork.Formats, applications = artwork.Applications, unlisted = artwork.Unlisted;
            SetBusy(true, "Reviewing file icons. No icons changed yet...");
            try {
                await WaitForReconcile();
                // Artwork that could not be converted leaves only its own item out; the review lists it with the reason.
                LeftOutItem[] failures = new LeftOutItem[0];
                if (!restoring) {
                    // A published pack's art for other file types is its art for all of an app's files: converted once.
                    Dictionary<string, string> sources = applications;
                    Dictionary<string, string> own = unlisted.Where(art => { string shared; return !sources.TryGetValue(art.Key, out shared) || shared != art.Value; }).ToDictionary(art => art.Key, art => art.Value);
                    WorkerReply reply = await worker.Run(new WorkerRequest { Action = "PrepareProjectIcons", ProjectArtwork = formats, AppArtwork = applications, UnlistedArtwork = own }, false);
                    formats = reply.CachedProjectIcons ?? new Dictionary<string, string>();
                    applications = reply.CachedAppIcons ?? new Dictionary<string, string>();
                    Dictionary<string, string> cachedOwn = reply.CachedUnlistedIcons ?? new Dictionary<string, string>(), converted = new Dictionary<string, string>();
                    foreach (var art in unlisted) {
                        string value;
                        if ((own.ContainsKey(art.Key) ? cachedOwn : applications).TryGetValue(art.Key, out value)) converted[art.Key] = value;
                    }
                    unlisted = converted;
                    failures = reply.ProjectIconFailures ?? new LeftOutItem[0];
                }
                string directory = FileIconDirectory();
                bool live = fixtureLog == null;
                string key = FileIconClassesKey(directory, live);
                using (RegistryKey overlay = live ? Registry.CurrentUser.OpenSubKey(key, true) : Registry.CurrentUser.CreateSubKey(key))
                using (RegistryKey choices = live ? Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts") : null) {
                    ProjectIconStore store = new ProjectIconStore(directory, live ? Registry.ClassesRoot : overlay, overlay, choices, live);
                    List<ProjectIconChange> plan = await Task.Run(() => store.Review(formats, applications, unlisted, restoring));
                    int count = plan.Count(row => row.CanChange);
                    if (plan.Count == 0) {
                        status.Text = restoring ? "No BetterIcon file icons to restore." : failures.Length > 0 ? "No file icons changed. " + LeftOutText(failures) : "This pack has no artwork for file types on this PC.";
                        return;
                    }
                    string note = restoring
                        ? "Restore the original icon for " + count + " file type(s) in your account." + (live ? "" : " Test registry only.") + "\r\nAn icon changed outside BetterIcon is left as it is."
                        : "Apply " + pack + " to " + count + " file type(s) in your account." + (live ? "" : " Test registry only.") + " Original icons are backed up.\r\nEach file type keeps its app. A type that opens with another app is skipped."
                            + (plan.Any(row => row.CanChange && ProjectIconStore.OpenWithApplication(row.Target) != null) ? "\r\nA type set through Open with may also change that app's icon in Open with menus." : "")
                            + (plan.Any(row => row.Unlisted) ? "\r\n" + OtherTypesNote : "");
                    // A row for file types outside the list keeps its mark beside the reason when it is not ready.
                    var rows = plan.OrderBy(row => row.CanChange ? 0 : 1).Select(row => new[] { row.CanChange ? "Ready" : row.Reason == "Already applied" ? "Unchanged" : "Skipped", row.Extensions,
                        row.CanChange ? FileClassName(row) : row.Unlisted ? row.Reason + ": " + FileClassName(row) : row.Reason })
                        .Concat(failures.Select(failure => new[] { "Skipped", failure.Item, failure.Reason }));
                    if (!Review(restoring ? "Review file icon restoration" : "Review file icon changes", note, rows, count > 0, restoring ? "Restore file icons" : "Apply file icons", "File types")) { status.Text = "Cancelled. No file icons changed."; return; }
                    status.Text = restoring ? "Restoring file icons..." : "Applying file icons...";
                    await Task.Run(() => store.Commit(formats, applications, unlisted, restoring, plan));
                    status.Text = (restoring ? "Original file icons restored. " : "File icons applied. ") + count + " file type(s)." + (failures.Length > 0 ? " " + LeftOutText(failures) : "");
                }
            }
            catch (Exception error) { Report(error); }
            finally { SetBusy(false, null); }
        }
        string FileIconDirectory() { return Path.Combine(Path.GetDirectoryName(preferencesPath), "project-file-icons"); }
        // The user's Classes overlay, or a disposable hive of its own for each fixture.
        static string FileIconClassesKey(string directory, bool live)
        {
            if (live) return @"Software\Classes";
            using (SHA256 sha = SHA256.Create())
                return @"Software\BetterIcon-Fixtures\" + BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(directory))).Replace("-", "") + @"\Classes";
        }
        // File icons after app updates, in the background, with the same store and hive as ChangeFileIcons.
        // It runs only when file icons were applied, and returns its notices for the status line.
        async Task<List<Notice>> ReconcileFileIcons()
        {
            string directory = FileIconDirectory();
            try {
                if (!Directory.Exists(directory) || !Directory.EnumerateFiles(directory, "*.json").Any()) return new List<Notice>();
                bool live = fixtureLog == null;
                string key = FileIconClassesKey(directory, live);
                List<ProjectReconcileRow> rows = await Task.Run(() => {
                    using (RegistryKey overlay = live ? Registry.CurrentUser.OpenSubKey(key, true) : Registry.CurrentUser.CreateSubKey(key))
                    using (RegistryKey choices = live ? Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts") : null) {
                        if (overlay == null) return new List<ProjectReconcileRow>();
                        return new ProjectIconStore(directory, live ? Registry.ClassesRoot : overlay, overlay, choices, live).Reconcile();
                    }
                });
                if (IsDisposed || Disposing) return new List<Notice>();
                return FileIconNotices(rows);
            }
            catch (Exception error) { System.Diagnostics.Trace.WriteLine("BetterIcon file icons after app updates: " + error.Message); return new List<Notice>(); }
        }
        // A file type outside BetterIcon's list changes only through a pack's art for all of an app's files: its row says so.
        internal const string OtherTypes = " (other file types)", OtherTypesOpenWith = " (Open with, other file types)";
        internal const string OtherTypesNote = "A type marked (other file types) is not in BetterIcon's list. It changes because that app opens it and this pack has artwork for all of the app's files.";
        static string FileClassName(ProjectIconChange row)
        {
            if (!row.Unlisted) return FileClassName(row.Target);
            string application = AppNames.Display(row.Application ?? ProjectIconStore.TargetApplication(row.Target) ?? "");
            return application + (ProjectIconStore.OpenWithApplication(row.Target) != null ? OtherTypesOpenWith : OtherTypes);
        }
        static string FileClassName(string target)
        {
            string application;
            if (ProjectFormat.Classes.TryGetValue(target, out application)) return application;
            // A file type the user gave to the app through Open with.
            application = ProjectIconStore.OpenWithApplication(target);
            if (application != null) return application + " (Open with)";
            ProjectFormat format = ProjectFormat.All.FirstOrDefault(f => f.Key == target);
            return format == null ? "" : format.Application;
        }
    }
}
