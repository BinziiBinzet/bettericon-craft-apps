using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace BetterIcon.Tray
{
    public sealed class ProjectFormat
    {
        public string Key { get; set; }
        public string Application { get; set; }
        public string ProgId { get; set; }
        public string[] Aliases { get; set; }
        public static readonly ProjectFormat[] All = Load();
        static ProjectFormat[] Load()
        {
            using (var stream = typeof(ProjectFormat).Assembly.GetManifestResourceStream("BetterIcon.ProjectFileTypes.json"))
            using (var reader = new StreamReader(stream))
                return new JavaScriptSerializer().Deserialize<ProjectFormat[]>(reader.ReadToEnd());
        }
        public static bool IsKey(string key) { return All.Any(f => f.Key == key); }
        public static Dictionary<string, string> Artwork(ThemeEntry pack)
        {
            if (pack.FileIcons != null && pack.FileIcons.Count != 0) return new Dictionary<string, string>(pack.FileIcons);
            var result = new Dictionary<string, string>();
            foreach (var type in All) {
                var art = (pack.Icons ?? new ThemeIcon[0]).FirstOrDefault(icon => icon.Application == type.Application);
                if (art != null) result.Add(type.Key, art.Path);
            }
            return result;
        }
    }

    // Only the unnamed DefaultIcon value in the user's Classes overlay is managed.
    public sealed class ProjectIconValue
    {
        public string Text { get; set; }
        public RegistryValueKind Kind { get; set; }
        public bool KeyExisted { get; set; }
        public bool ParentExisted { get; set; }
        public bool Matches(ProjectIconValue other) { return Text == other.Text && Kind == other.Kind; }
    }
    public sealed class ProjectIconBackup
    {
        public string Target { get; set; }
        public ProjectIconValue Original { get; set; }
        public string Applied { get; set; }
        public string Pending { get; set; }
    }
    public sealed class ProjectIconChange
    {
        public string Target { get; set; }
        public string Extensions { get; set; }
        public string Reason { get; set; }
        public ProjectIconValue Before { get; set; }
        public string Icon { get; set; }
        public bool CanChange { get; set; }
    }
    public sealed class ProjectIconStore
    {
        readonly string root;
        readonly RegistryKey source, user, choices;
        readonly bool desktop;
        static readonly StringComparer IgnoreCase = StringComparer.OrdinalIgnoreCase;
        readonly JavaScriptSerializer json = new JavaScriptSerializer();
        [DllImport("shell32.dll")] static extern void SHChangeNotify(uint action, uint flags, IntPtr a, IntPtr b);
        [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)] static extern int AssocQueryStringW(uint flags, uint kind, string ext, string extra, StringBuilder result, ref uint length);

        public ProjectIconStore(string directory, RegistryKey classes, RegistryKey userClasses, RegistryKey fileChoices, bool liveDesktop)
        { root = directory; source = classes; user = userClasses; choices = fileChoices; desktop = liveDesktop; }
        string BackupPath(string target) { return Path.Combine(root, target + ".json"); }
        static bool AllowedTarget(string target) { return ProjectFormat.All.Any(f => IgnoreCase.Equals(f.ProgId, target) || f.Key == target); }
        static string RegString(RegistryKey parent, string path, string name)
        {
            if (parent == null) return null;
            using (var k = parent.OpenSubKey(path)) return k == null ? null : k.GetValue(name) as string;
        }
        string Handler(string ext)
        {
            if (desktop) {
                uint n = 1024;
                var text = new StringBuilder((int)n);
                if (AssocQueryStringW(0, 20, ext, null, text, ref n) == 0 && text.Length != 0) return text.ToString();
            }
            return RegString(choices, ext + "\\UserChoice", "ProgId") ?? RegString(source, ext, "");
        }
        ProjectIconValue Current(string target)
        {
            using (var parent = user.OpenSubKey(target))
            using (var k = parent == null ? null : parent.OpenSubKey("DefaultIcon")) {
                var v = new ProjectIconValue { KeyExisted = k != null, ParentExisted = parent != null };
                if (k != null && k.GetValueNames().Contains("")) {
                    v.Kind = k.GetValueKind("");
                    if (v.Kind == RegistryValueKind.String || v.Kind == RegistryValueKind.ExpandString)
                        v.Text = (string)k.GetValue("", null, RegistryValueOptions.DoNotExpandEnvironmentNames);
                }
                return v;
            }
        }
        ProjectIconBackup Backup(string target)
        {
            string path = BackupPath(target);
            if (!File.Exists(path)) return null;
            PackLibrary.RegularPath(path);
            var b = json.Deserialize<ProjectIconBackup>(File.ReadAllText(path));
            if (b == null || !IgnoreCase.Equals(b.Target, target) || b.Original == null) throw new IOException("Invalid project icon backup for " + target);
            return b;
        }
        void Save(ProjectIconBackup b)
        {
            string file = BackupPath(b.Target), tmp = file + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try {
                File.WriteAllText(tmp, json.Serialize(b), new UTF8Encoding(false));
                if (File.Exists(file)) File.Replace(tmp, file, null); else File.Move(tmp, file);
            } finally { if (File.Exists(tmp)) File.Delete(tmp); }
        }
        static bool Ours(ProjectIconBackup b, ProjectIconValue v)
        {
            return v.Kind == RegistryValueKind.String && v.Text != null && (v.Text == b.Applied || v.Text == b.Pending);
        }
        Dictionary<string, List<string>> ClassExtensions()
        {
            var result = new Dictionary<string, List<string>>(IgnoreCase);
            var candidates = new HashSet<string>(source.GetSubKeyNames().Where(n => n.StartsWith(".")), IgnoreCase);
            if (choices != null) candidates.UnionWith(choices.GetSubKeyNames().Where(n => n.StartsWith(".")));
            var watched = new HashSet<string>(ProjectFormat.All.Select(f => f.ProgId), IgnoreCase);
            foreach (string ext in candidates) {
                var registered = RegString(source, ext, "");
                var chosen = RegString(choices, ext + "\\UserChoice", "ProgId");
                if (!watched.Contains(registered ?? "") && !watched.Contains(chosen ?? "")) continue;
                string id = Handler(ext);
                if (id == null || !watched.Contains(id)) continue;
                List<string> extensions;
                if (!result.TryGetValue(id, out extensions)) result[id] = extensions = new List<string>();
                extensions.Add(ext.ToLowerInvariant());
            }
            return result;
        }
        public List<ProjectIconChange> Review(IDictionary<string, string> icons, bool restore)
        {
            PackLibrary.RegularPath(root);
            var result = new List<ProjectIconChange>();
            var used = ClassExtensions();
            foreach (ProjectFormat f in ProjectFormat.All) {
                string icon = null;
                if (!restore && !icons.TryGetValue(f.Key, out icon)) continue;
                var allowed = new HashSet<string>(f.Aliases ?? new string[0], IgnoreCase) { f.Key };
                List<string> linked;
                if (!used.TryGetValue(f.ProgId, out linked)) linked = new List<string>();
                string handler = Handler(f.Key);
                bool ownClass = IgnoreCase.Equals(handler, f.ProgId);
                bool unassigned = String.IsNullOrEmpty(handler) || IgnoreCase.Equals(handler, "Unknown") || IgnoreCase.Equals(handler, f.Key);
                var targets = restore ? new[] { f.ProgId, f.Key } : new[] { ownClass ? f.ProgId : f.Key };
                foreach (string target in targets) {
                    var backup = Backup(target);
                    if (restore && backup == null) continue;
                    var before = Current(target);
                    var change = new ProjectIconChange { Target = target, Before = before, Icon = icon,
                        Extensions = IgnoreCase.Equals(target, f.ProgId) && linked.Count > 0 ? String.Join(", ", linked.OrderBy(n => n)) : f.Key };
                    if (!restore && !ownClass && !unassigned) change.Reason = "Uses another default application";
                    else if (!restore && ownClass && linked.Any(ext => !allowed.Contains(ext))) change.Reason = "Shares an icon with another file format";
                    else if (before.Kind != RegistryValueKind.Unknown && before.Kind != RegistryValueKind.String && before.Kind != RegistryValueKind.ExpandString) change.Reason = "Existing icon value has another registry type";
                    else if (backup != null && !Ours(backup, before) && !before.Matches(backup.Original)) change.Reason = "Icon changed outside BetterIcon";
                    else if (!restore && icon == before.Text && before.Kind == RegistryValueKind.String) change.Reason = "Already applied";
                    else { change.CanChange = true; change.Reason = restore ? "Restore" : "Apply"; }
                    result.Add(change);
                }
            }
            return result;
        }
        static void RemoveEmpty(RegistryKey parent, string name)
        {
            using (var child = parent.OpenSubKey(name)) {
                if (child == null || child.SubKeyCount != 0 || child.ValueCount != 0) return;
            }
            parent.DeleteSubKey(name, false);
        }
        void RestoreValue(ProjectIconBackup b)
        {
            if (b.Original.Text != null) {
                using (var k = user.CreateSubKey(b.Target + "\\DefaultIcon")) k.SetValue("", b.Original.Text, b.Original.Kind);
            } else {
                using (var parent = user.OpenSubKey(b.Target, true)) if (parent != null) {
                    using (var k = parent.OpenSubKey("DefaultIcon", true)) if (k != null) k.DeleteValue("", false);
                    if (!b.Original.KeyExisted) RemoveEmpty(parent, "DefaultIcon");
                }
                if (!b.Original.ParentExisted) RemoveEmpty(user, b.Target);
            }
        }
        public void Commit(IDictionary<string, string> icons, bool restore, List<ProjectIconChange> reviewed)
        {
            PackLibrary.RegularPath(root); Directory.CreateDirectory(root);
            using (var guard = File.Open(Path.Combine(root, "file-icons.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None)) {
                var fresh = Review(icons, restore);
                if (json.Serialize(fresh) != json.Serialize(reviewed)) throw new IOException("File icons changed after review. Review them again.");
                bool touched = false;
                try {
                    foreach (var row in fresh.Where(r => r.CanChange)) {
                        if (!AllowedTarget(row.Target) || !Current(row.Target).Matches(row.Before)) throw new IOException("File icons changed during the update.");
                        var b = Backup(row.Target);
                        if (restore) {
                            if (b == null) throw new IOException("The original icon backup is missing.");
                            touched = true; RestoreValue(b); File.Delete(BackupPath(row.Target));
                        } else {
                            if (b == null) b = new ProjectIconBackup { Target = row.Target, Original = row.Before };
                            else if (Ours(b, row.Before)) b.Applied = row.Before.Text;
                            b.Pending = row.Icon; Save(b);
                            touched = true;
                            using (var k = user.CreateSubKey(row.Target + "\\DefaultIcon")) k.SetValue("", row.Icon, RegistryValueKind.String);
                            b.Applied = b.Pending; b.Pending = null; Save(b);
                        }
                    }
                } finally { if (touched && desktop) SHChangeNotify(0x08000000, 0, IntPtr.Zero, IntPtr.Zero); }
            }
        }
    }
}
