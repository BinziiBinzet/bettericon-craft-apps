using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace BetterIcon.Tray
{
    // One entry is one design. Windows shows a single icon for each file class, so
    // every extension an app registers under one class shares that entry's artwork.
    public sealed class ProjectFormat
    {
        static readonly StringComparer IgnoreCase = StringComparer.OrdinalIgnoreCase;
        public string Key { get; set; }
        public string Application { get; set; }
        public string[] ProgIds { get; set; }
        public string[] Aliases { get; set; }
        // An ArtCraft format can show its icon before any app is registered to open it.
        public bool Native { get; set; }
        // File classes of other ArtCraft apps that open the same extensions.
        public Dictionary<string, string> Shared { get; set; }
        public static readonly ProjectFormat[] All = Load();
        // Every extension the index lists, as a design's key or one of its aliases. Any other extension is unlisted.
        public static readonly HashSet<string> Listed = new HashSet<string>(All.SelectMany(f => f.Extensions), IgnoreCase);
        // Each Windows file class with the app that registers it, in table order.
        public static readonly string[] ClassNames;
        public static readonly Dictionary<string, string> Classes = new Dictionary<string, string>(IgnoreCase);
        static ProjectFormat()
        {
            var names = new List<string>();
            foreach (var format in All) foreach (string id in format.ProgIds)
                if (!Classes.ContainsKey(id)) { Classes.Add(id, format.Application); names.Add(id); }
            foreach (var format in All) foreach (var other in format.Shared)
                if (!Classes.ContainsKey(other.Key)) { Classes.Add(other.Key, other.Value); names.Add(other.Key); }
            ClassNames = names.ToArray();
        }
        static ProjectFormat[] Load()
        {
            using (var stream = typeof(ProjectFormat).Assembly.GetManifestResourceStream("BetterIcon.ProjectFileTypes.json"))
            using (var reader = new StreamReader(stream)) {
                var formats = new JavaScriptSerializer().Deserialize<ProjectFormat[]>(reader.ReadToEnd());
                foreach (var format in formats) {
                    format.ProgIds = format.ProgIds ?? new string[0]; format.Aliases = format.Aliases ?? new string[0];
                    format.Shared = format.Shared ?? new Dictionary<string, string>();
                }
                return formats;
            }
        }
        public IEnumerable<string> Extensions { get { return new[] { Key }.Concat(Aliases); } }
        public bool Has(string extension) { return Extensions.Contains(extension, IgnoreCase); }
        public bool Opens(string progId) { return ProgIds.Contains(progId, IgnoreCase) || Shared.Keys.Contains(progId, IgnoreCase); }
        public string Label { get { return Aliases.Length == 0 ? Key : Aliases.Length < 3 ? Key + ", " + String.Join(", ", Aliases) : Key + ", " + Aliases[0] + " +" + (Aliases.Length - 1); } }
        public static bool IsKey(string key) { return All.Any(f => f.Key == key); }
        public static bool IsListed(string extension) { return extension != null && Listed.Contains(extension); }
        public static FileArtwork Artwork(ThemeEntry pack)
        {
            var result = new FileArtwork();
            if (pack == null) return result;
            if (pack.FileIcons != null) foreach (var icon in pack.FileIcons) if (IsKey(icon.Key)) result.Formats[icon.Key] = icon.Value;
            if (pack.AppFileIcons != null) foreach (var icon in pack.AppFileIcons) result.Applications[icon.Key] = icon.Value;
            // Art for file types outside the index. A personal pack has it only as the item it stored for an app at import; a
            // published pack only where the catalog's source names say the author named the app's art <App>-files.
            if (pack.Managed) {
                if (pack.UnlistedFileIcons != null) foreach (var icon in pack.UnlistedFileIcons) if (PackLibrary.Applications.Contains(icon.Key)) result.Unlisted[icon.Key] = icon.Value;
            }
            else if (pack.UnlistedFileIconApps != null && pack.AppFileIcons != null) {
                foreach (string application in pack.UnlistedFileIconApps) {
                    string path;
                    if (application != null && pack.AppFileIcons.TryGetValue(application, out path)) result.Unlisted[application] = path;
                }
            }
            return result;
        }
    }

    // A pack can draw one icon for a format, or one for everything an app opens.
    public sealed class FileArtwork
    {
        public readonly Dictionary<string, string> Formats = new Dictionary<string, string>();
        public readonly Dictionary<string, string> Applications = new Dictionary<string, string>();
        // An app's art for the file types outside the index that only its own classes open (ProjectFormat.Artwork).
        public readonly Dictionary<string, string> Unlisted = new Dictionary<string, string>();
        public bool Any { get { return Formats.Count != 0 || Applications.Count != 0; } }
        public string For(ProjectFormat format)
        {
            string path;
            return Formats.TryGetValue(format.Key, out path) || Applications.TryGetValue(format.Application, out path) ? path : null;
        }
        // Every format drawn with its own entry, as a personal pack stores it.
        public Dictionary<string, string> Expanded()
        {
            var result = new Dictionary<string, string>();
            foreach (var format in ProjectFormat.All) { string path = For(format); if (path != null) result.Add(format.Key, path); }
            return result;
        }
        public sealed class Tile { public string Name, Tooltip, Path; }
        // The tooltip line of art that also draws the file types outside the index an app's own classes open.
        public const string UnlistedTip = "Also other file types {0} opens";
        public List<Tile> Tiles()
        {
            var result = new List<Tile>();
            var apps = Applications.Keys.Concat(Unlisted.Keys).Concat(ProjectFormat.All.Where(f => Formats.ContainsKey(f.Key)).Select(f => f.Application)).Distinct().OrderBy(a => a, StringComparer.OrdinalIgnoreCase);
            foreach (string app in apps) {
                var own = ProjectFormat.All.Where(f => f.Application == app).ToArray();
                string shared, other;
                bool opted = Unlisted.TryGetValue(app, out other);
                string also = opted ? Environment.NewLine + String.Format(UnlistedTip, AppNames.Display(app)) : "";
                if (Applications.TryGetValue(app, out shared)) {
                    var covered = own.Where(f => !Formats.ContainsKey(f.Key)).Select(f => f.Label).ToArray();
                    result.Add(new Tile { Name = app, Path = shared, Tooltip = app + " files" + Environment.NewLine + (covered.Length == 0 ? "No other file types on Windows" : String.Join(Environment.NewLine, covered))
                        + (opted && other == shared ? also : "") });
                    if (opted && other != shared) result.Add(new Tile { Name = app, Path = other, Tooltip = app + " files" + also });
                }
                // A personal pack keeps this art as an item of its own beside each format's copy.
                else if (opted) result.Add(new Tile { Name = app, Path = other, Tooltip = app + " files" + also });
                foreach (var format in own.Where(f => Formats.ContainsKey(f.Key)))
                    result.Add(new Tile { Name = format.Key, Path = Formats[format.Key], Tooltip = format.Label + Environment.NewLine + app });
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
        // Originals an app update replaced, oldest first. Restore returns the newest original.
        public List<ProjectIconValue> PreviousOriginals { get; set; }
        // The app that registers this file class was installed for this account only (its open command was in
        // the user's own classes) at some point while BetterIcon kept this backup. Only such an app's installer
        // writes or removes the value BetterIcon keeps, so only then does a change count as an app update.
        public bool? PerUser { get; set; }
        // Set when BetterIcon last gave this class an app's art for file types outside the index (a catch-all class), with
        // that app. Restore and the checks after app updates find a class outside the index's names by this record alone.
        // Earlier versions ignore both fields.
        public bool? Unlisted { get; set; }
        public string Application { get; set; }
        // The file types the class had when BetterIcon last changed it, which Restore shows for a class no file type opens with
        // any more. Earlier versions ignore it.
        public string Extensions { get; set; }
    }
    // One file class a background check looked at after app updates.
    public sealed class ProjectReconcileRow
    {
        public string Target { get; set; }
        public string Application { get; set; }
        // Reapplied, Rebased, Changed or IconMissing.
        public string Status { get; set; }
        public string Value { get; set; }
    }
    public sealed class ProjectIconChange
    {
        public string Target { get; set; }
        public string Extensions { get; set; }
        public string Reason { get; set; }
        public ProjectIconValue Before { get; set; }
        public string Icon { get; set; }
        public bool CanChange { get; set; }
        // The ArtCraft app whose class or format this is.
        public string Application { get; set; }
        // A class every extension of which is outside the index, so it takes only the pack's art for all of an app's files
        // that its author named <App>-files. The review marks it.
        public bool Unlisted { get; set; }
    }
    public sealed class ProjectIconStore
    {
        static readonly StringComparer IgnoreCase = StringComparer.OrdinalIgnoreCase;
        readonly string root;
        readonly RegistryKey source, user, choices;
        readonly bool desktop;
        // Tests only: programs to take for installed ArtCraft programs, by full path, beside those the registry names.
        readonly Dictionary<string, string> extraPrograms;
        // Read once per review: the program in each class's open command, and the ArtCraft programs the apps' own
        // registrations run, by full path.
        Dictionary<string, string> openers = new Dictionary<string, string>(IgnoreCase), programs;
        // Classes outside the index's own names that the current review, Restore or check after app updates found BetterIcon
        // may change. AllowedTarget takes these and nothing else beyond the index's classes, formats and Open with entries.
        HashSet<string> identified = new HashSet<string>(IgnoreCase);
        static readonly Dictionary<string, string> NoIcons = new Dictionary<string, string>();
        readonly JavaScriptSerializer json = new JavaScriptSerializer();
        [DllImport("shell32.dll")] static extern void SHChangeNotify(uint action, uint flags, IntPtr a, IntPtr b);
        [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)] static extern int AssocQueryStringW(uint flags, uint kind, string ext, string extra, StringBuilder result, ref uint length);

        public ProjectIconStore(string directory, RegistryKey classes, RegistryKey userClasses, RegistryKey fileChoices, bool liveDesktop)
            : this(directory, classes, userClasses, fileChoices, liveDesktop, null) { }
        // testPrograms: a fixture's opener programs, by full path, with the ArtCraft app each stands for. No caller in the app
        // passes it; a real program counts only as the registry's own ArtCraft registrations name it (FindPrograms).
        public ProjectIconStore(string directory, RegistryKey classes, RegistryKey userClasses, RegistryKey fileChoices, bool liveDesktop, IDictionary<string, string> testPrograms)
        {
            root = directory; source = classes; user = userClasses; choices = fileChoices; desktop = liveDesktop;
            if (testPrograms == null) return;
            extraPrograms = new Dictionary<string, string>(IgnoreCase);
            foreach (var program in testPrograms) {
                string full = FullPath(program.Key);
                if (full == null || !PackLibrary.Applications.Contains(program.Value)) throw new ArgumentException("Unknown test program.");
                extraPrograms[full] = program.Value;
            }
        }
        // One file for each target, and never one file for two. An Open with entry keeps the name earlier versions gave it,
        // Applications+<program>.exe.json. Any other name writes a plus sign as %2B, which no class name contains, so it can't
        // meet that form, and a name too long to keep readable is stored under its digest, a name no class can have. The
        // index's classes and the extensions keep the names earlier versions gave them.
        string BackupPath(string target)
        {
            string name = OpenWithApplication(target) != null ? target.Replace('\\', '+') : target.Replace("+", "%2B");
            if (name.IndexOfAny(new[] { '\\', '/', ':' }) >= 0) throw new ArgumentException("Invalid file class name.");
            if (name.Length > 120) {
                using (var sha = SHA256.Create())
                    name = "#" + BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(target.ToLowerInvariant()))).Replace("-", "").ToLowerInvariant();
            }
            return Path.Combine(root, name + ".json");
        }
        // The targets earlier versions already managed: the index's classes and formats, and ArtCraft Open with entries.
        static bool FixedTarget(string target) { return ProjectFormat.Classes.ContainsKey(target) || ProjectFormat.IsKey(target) || OpenWithApplication(target) != null; }
        bool AllowedTarget(string target) { return FixedTarget(target) || (identified.Contains(target) && AcceptedClass(target)); }
        static readonly Regex PlainClass = new Regex(@"^[A-Za-z0-9][A-Za-z0-9._+ -]{0,254}\z", RegexOptions.CultureInvariant);
        static readonly Regex DeviceName = new Regex(@"^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9]) *(\.|\z)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        static readonly HashSet<string> ShellClasses = new HashSet<string>(new[] { "*", "AllFilesystemObjects", "Directory", "Folder", "Drive", "SystemFileAssociations",
            "CLSID", "Unknown", "Applications", "Interface", "TypeLib", "AppID", "MIME", "WOW6432Node", "DesktopBackground", "Network", "Printers", "LibraryFolder" }, StringComparer.OrdinalIgnoreCase);
        // A class name read from the registry that BetterIcon may change beyond the index's own names: an ArtCraft program's
        // Open with entry (Applications\<app>.exe), or a plain ProgID: a letter or digit, then letters, digits, dots,
        // underscores, plus signs, hyphens or spaces, at most 255 characters in all, no "..", not ending in a dot or space,
        // and no device name such as CON, NUL, COM1 or LPT1. Never one of the shell's own classes, such as * or Directory.
        public static bool AcceptedClass(string name)
        {
            if (String.IsNullOrEmpty(name)) return false;
            if (OpenWithApplication(name) != null) return true;
            return PlainClass.IsMatch(name) && name.IndexOf("..", StringComparison.Ordinal) < 0 && !name.EndsWith(".", StringComparison.Ordinal) &&
                !name.EndsWith(" ", StringComparison.Ordinal) && !DeviceName.IsMatch(name) && !ShellClasses.Contains(name);
        }
        static string FullPath(string path)
        {
            try { return String.IsNullOrWhiteSpace(path) || !Path.IsPathRooted(path) ? null : Path.GetFullPath(path); }
            catch (ArgumentException) { return null; }
            catch (NotSupportedException) { return null; }
            catch (PathTooLongException) { return null; }
        }
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
            string id = Choice(ext) ?? RegString(source, ext, "");
            if (String.IsNullOrEmpty(id)) {
                // With no choice or default of its own, Windows opens an extension with the class its OpenWithProgids offers,
                // when that is the only one.
                var offered = OfferedClasses(ext);
                if (offered.Count == 1) return offered.First();
            }
            return id;
        }
        // The user's own choice for an extension. Newer Windows builds keep it in UserChoiceLatest.
        string Choice(string ext)
        {
            return RegString(choices, ext + "\\UserChoiceLatest\\ProgId", "ProgId") ?? RegString(choices, ext + "\\UserChoice", "ProgId");
        }
        static bool Unassigned(string handler, string ext)
        {
            return String.IsNullOrEmpty(handler) || IgnoreCase.Equals(handler, "Unknown") || IgnoreCase.Equals(handler, ext);
        }
        // "Open with" assigns a file type to a program by its file name, such as
        // Applications\filmcraft.exe. That entry is the file class for those files, and
        // Windows also shows its icon for the app in Open with menus.
        public static string OpenWithApplication(string handler)
        {
            const string prefix = "Applications\\";
            if (handler == null || !handler.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return null;
            string file = handler.Substring(prefix.Length);
            if (!file.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || file.IndexOf('\\') >= 0) return null;
            string name = file.Substring(0, file.Length - 4);
            return PackLibrary.Applications.FirstOrDefault(app => IgnoreCase.Equals(app, name));
        }
        // A file class belongs to an ArtCraft app when it is one of the index's classes, an ArtCraft program's Open with entry,
        // or another class whose open command runs an installed ArtCraft program (FindPrograms). Windows keys an Open with entry
        // by a program's file name alone, so for file types outside the index (strict) the entry counts only while it runs that
        // app's installed program; for listed formats it counts by its name, as before.
        bool Watched(string id) { return ClassApplication(id, false) != null; }
        string ClassApplication(string id, bool strict)
        {
            if (String.IsNullOrEmpty(id)) return null;
            string application;
            if (ProjectFormat.Classes.TryGetValue(id, out application)) return application;
            application = OpenWithApplication(id);
            if (application != null) return !strict || ProgramOwner(id) == application ? application : null;
            return AcceptedClass(id) ? ProgramOwner(id) : null;
        }
        // The app whose installed program the class's open command runs.
        string ProgramOwner(string id)
        {
            if (programs == null || programs.Count == 0) return null;
            string exe = Opener(id), application;
            return exe != null && programs.TryGetValue(exe, out application) ? application : null;
        }
        // Each class's opener is read once per review.
        string Opener(string id)
        {
            string exe;
            if (!openers.TryGetValue(id, out exe)) openers[id] = exe = OpenerExecutable(id);
            return exe;
        }
        void BeginReview()
        {
            identified = new HashSet<string>(IgnoreCase);
            FindPrograms();
        }
        // The installed ArtCraft programs, read once per review. The open command of each class the index names for an app runs
        // that app's program: those class names are the apps' own. Windows keys an Open with entry by a program's file name
        // alone, so the program an app's Open with entry runs counts only when something of the app's backs it: one of the
        // app's own classes runs that same program, or it sits in a folder named for the app, where installers put it
        // (C:\Program Files\PhotoCraft\photocraft.exe). Either way a program counts under its app's own file name alone, and
        // only while the file exists. So a tool named PhotoCraft Helper, or another vendor's photocraft.exe that an Open with
        // entry runs, never makes a class PhotoCraft's. Windows names the ArtCraft Launcher's Open with entry after its program,
        // artcraft-launcher.exe, which is not an ArtCraft app's name, so the launcher's program is never found this way.
        void FindPrograms()
        {
            openers = new Dictionary<string, string>(IgnoreCase);
            programs = new Dictionary<string, string>(IgnoreCase);
            foreach (string id in ProjectFormat.ClassNames) AddProgram(id, ProjectFormat.Classes[id], false);
            foreach (string app in PackLibrary.Applications) AddProgram("Applications\\" + app + ".exe", app, true);
            if (extraPrograms != null) foreach (var program in extraPrograms) programs[program.Key] = program.Value;
        }
        void AddProgram(string id, string application, bool openWith)
        {
            string exe = Opener(id), known;
            if (exe == null || ProgramApplication(exe) != application || !File.Exists(exe)) return;
            if (openWith && !(programs.TryGetValue(exe, out known) && known == application) && FolderApplication(exe) != application) return;
            programs[exe] = application;
        }
        // The ArtCraft app whose own program file this is: the app's name and nothing more, before .exe.
        public static string ProgramApplication(string exe)
        {
            if (String.IsNullOrEmpty(exe) || !exe.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) return null;
            return NamedApplication(Path.GetFileNameWithoutExtension(exe));
        }
        // The ArtCraft app the folder holding a program is named for, such as PhotoCraft for C:\Program Files\PhotoCraft.
        public static string FolderApplication(string exe)
        {
            string folder;
            try { folder = Path.GetFileName(Path.GetDirectoryName(exe)); }
            catch (ArgumentException) { return null; }
            catch (PathTooLongException) { return null; }
            return NamedApplication(folder);
        }
        // The app a name is exactly: the app's name in any case, with ArtCraft Launcher and Craft Anything also split by spaces,
        // underscores or hyphens.
        static string NamedApplication(string name)
        {
            if (String.IsNullOrEmpty(name)) return null;
            foreach (string app in PackLibrary.Applications) {
                string pattern = app == "CraftAnything" ? "Craft[ _-]*Anything" : app == "ArtCraftLauncher" ? "ArtCraft[ _-]*Launcher" : Regex.Escape(app);
                if (Regex.IsMatch(name, "^" + pattern + @"\z", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)) return app;
            }
            return null;
        }
        // The key names of the class root: its extensions and its classes. Windows' merged view of HKEY_CLASSES_ROOT lists its
        // keys slowly after a process first asks (about 3.5 s for 8,500 keys on the PC where this was measured, each time), so
        // the live root is read as the user's classes and the machine's, whose names together are exactly the merged view's.
        HashSet<string> ClassKeyNames()
        {
            var names = new HashSet<string>(IgnoreCase);
            if (!IgnoreCase.Equals(source.Name, Registry.ClassesRoot.Name)) { names.UnionWith(source.GetSubKeyNames()); return names; }
            foreach (RegistryKey hive in new[] { Registry.CurrentUser, Registry.LocalMachine })
                using (RegistryKey classes = hive.OpenSubKey(@"Software\Classes")) if (classes != null) names.UnionWith(classes.GetSubKeyNames());
            return names;
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
        // The extensions each watched class opens today: every extension whose real handler it is, since Windows changes
        // their icons together. Installers offer most common formats through OpenWithProgids, so ask Windows instead of
        // reading defaults.
        Dictionary<string, List<string>> ClassExtensions(Dictionary<string, string> handlers)
        {
            var result = new Dictionary<string, List<string>>(IgnoreCase);
            var candidates = new HashSet<string>(ProjectFormat.All.SelectMany(f => f.Extensions), IgnoreCase);
            var classNames = ClassKeyNames();
            // Also notice an unrelated extension that was pointed at one of these classes, by the user's choice or its default.
            var chosen = new HashSet<string>(IgnoreCase);
            string[] userExtensions = choices == null ? new string[0] : choices.GetSubKeyNames().Where(n => n.StartsWith(".")).ToArray();
            foreach (string ext in userExtensions) {
                string choice = Choice(ext);
                if (String.IsNullOrEmpty(choice)) continue;
                chosen.Add(ext);
                if (Watched(choice)) candidates.Add(ext);
            }
            // Windows opens an extension that has no choice of its own and no default naming an existing class with the class
            // its OpenWithProgids offers (in the class root or the user's FileExts), when that is the only one. Such extensions
            // whose offers name a watched class are candidates too.
            var offered = new HashSet<string>(IgnoreCase);
            foreach (string ext in classNames.Where(n => n.StartsWith("."))) {
                string id = RegString(source, ext, "");
                if (Watched(id)) candidates.Add(ext);
                else if (!chosen.Contains(ext) && (String.IsNullOrEmpty(id) || !ClassExists(id, classNames)) && OffersWatched(ext, classNames)) offered.Add(ext);
            }
            foreach (string ext in userExtensions)
                if (!chosen.Contains(ext) && !classNames.Contains(ext) && OffersWatched(ext, classNames)) offered.Add(ext);
            foreach (string ext in candidates) {
                string id = Handler(ext);
                handlers[ext] = id;
                if (!Watched(id)) continue;
                List<string> extensions;
                if (!result.TryGetValue(id, out extensions)) result[id] = extensions = new List<string>();
                extensions.Add(ext.ToLowerInvariant());
            }
            // Every listed extension is a candidate above, so these lie outside the index. They are counted only for a class that
            // opens no listed extension, which they leave a catch-all class: a class that opens a listed format keeps exactly the
            // index's rules, as before.
            foreach (string ext in offered) {
                if (candidates.Contains(ext)) continue;
                string id = Handler(ext);
                handlers[ext] = id;
                if (!Watched(id)) continue;
                List<string> extensions;
                if (!result.TryGetValue(id, out extensions)) result[id] = extensions = new List<string>();
                else if (extensions.Any(ProjectFormat.IsListed)) continue;
                extensions.Add(ext.ToLowerInvariant());
            }
            return result;
        }
        // A class an extension's default names is there: a key of the class root, or an Open with entry.
        static bool ClassExists(string id, HashSet<string> classNames)
        {
            return classNames.Contains(id) || id.StartsWith("Applications\\", StringComparison.OrdinalIgnoreCase);
        }
        // Whether an extension offers one class, and that a watched one: with two or more, Windows opens it with none. A name no
        // class key has is no class, and its opener is not read.
        bool OffersWatched(string ext, HashSet<string> classNames)
        {
            var offered = OfferedClasses(ext);
            if (offered.Count != 1) return false;
            string name = offered.First();
            return (ClassExists(name, classNames) || ProjectFormat.Classes.ContainsKey(name)) && Watched(name);
        }
        // The classes an extension's OpenWithProgids offers: in the class root (on the live desktop the user's classes and the
        // machine's, read one by one) and in the user's FileExts.
        HashSet<string> OfferedClasses(string ext)
        {
            var names = new HashSet<string>(IgnoreCase);
            if (IgnoreCase.Equals(source.Name, Registry.ClassesRoot.Name)) {
                foreach (RegistryKey hive in new[] { Registry.CurrentUser, Registry.LocalMachine }) ValueNames(hive, @"Software\Classes\" + ext + @"\OpenWithProgids", names);
            }
            else ValueNames(source, ext + @"\OpenWithProgids", names);
            if (choices != null) ValueNames(choices, ext + @"\OpenWithProgids", names);
            return names;
        }
        static void ValueNames(RegistryKey parent, string path, HashSet<string> names)
        {
            using (var k = parent.OpenSubKey(path)) if (k != null) foreach (string name in k.GetValueNames()) if (name.Length != 0) names.Add(name);
        }
        ProjectIconChange Check(ProjectIconChange change, ProjectIconBackup backup, bool restore)
        {
            var before = change.Before = Current(change.Target);
            if (change.Reason != null) return change;
            if (before.Kind != RegistryValueKind.Unknown && before.Kind != RegistryValueKind.String && before.Kind != RegistryValueKind.ExpandString) change.Reason = "Existing icon value has another registry type";
            else if (backup != null && !Ours(backup, before) && !before.Matches(backup.Original)) change.Reason = "Icon changed outside BetterIcon";
            else if (!restore && change.Icon == before.Text && before.Kind == RegistryValueKind.String) change.Reason = "Already applied";
            else { change.CanChange = true; change.Reason = restore ? "Restore" : "Apply"; }
            return change;
        }
        public List<ProjectIconChange> Review(IDictionary<string, string> icons, bool restore) { return Review(icons, null, null, restore); }
        public List<ProjectIconChange> Review(IDictionary<string, string> icons, IDictionary<string, string> applications, bool restore) { return Review(icons, applications, null, restore); }
        // icons holds artwork for one format; applications holds artwork for every file an app opens; unlisted holds an app's
        // artwork for the file types outside the index, which a pack has only where its author opted in (FileArtwork.Unlisted).
        public List<ProjectIconChange> Review(IDictionary<string, string> icons, IDictionary<string, string> applications, IDictionary<string, string> unlisted, bool restore)
        {
            PackLibrary.RegularPath(root);
            BeginReview();
            var result = new List<ProjectIconChange>();
            var handlers = new Dictionary<string, string>(IgnoreCase);
            var used = ClassExtensions(handlers);
            var openWith = PackLibrary.Applications.Select(app => "Applications\\" + app + ".exe");
            if (restore) {
                // Every backup BetterIcon wrote: the index's classes, Open with entries and formats, and each catch-all class.
                var seen = new HashSet<string>(IgnoreCase);
                foreach (string target in ProjectFormat.ClassNames.Concat(openWith).Concat(ProjectFormat.All.Select(f => f.Key)).Concat(BackupTargets())) {
                    if (!seen.Add(target)) continue;
                    var backup = Backup(target);
                    if (backup == null) continue;
                    if (!FixedTarget(backup.Target)) identified.Add(backup.Target);
                    List<string> linked;
                    // A class no extension opens with now shows the file types it had when BetterIcon changed it.
                    string extensions = used.TryGetValue(target, out linked) ? String.Join(", ", linked.OrderBy(n => n))
                        : ProjectFormat.All.Where(f => f.Key == target || f.Opens(target)).Select(f => f.Key).DefaultIfEmpty(String.IsNullOrEmpty(backup.Extensions) ? target : backup.Extensions).First();
                    // The backup names the key exactly as it was written.
                    result.Add(Check(new ProjectIconChange { Target = backup.Target, Extensions = extensions, Application = TargetApplication(backup.Target) ?? backup.Application,
                        Unlisted = backup.Unlisted == true }, backup, true));
                }
                return result;
            }
            icons = icons ?? NoIcons; applications = applications ?? NoIcons; unlisted = unlisted ?? NoIcons;
            var themed = new HashSet<string>(IgnoreCase);
            // The classes each app registers, then the other classes of ArtCraft apps that open files today.
            foreach (string id in ProjectFormat.ClassNames.Concat(used.Keys.Where(k => !ProjectFormat.Classes.ContainsKey(k)).OrderBy(k => k, IgnoreCase))) {
                List<string> linked;
                if (!used.TryGetValue(id, out linked)) continue;
                string application = ClassApplication(id, false), icon = null;
                ProjectFormat chosen = null;
                ProjectFormat[] formats = null;
                // Windows changes the icon of every extension of the class together. When none of them is listed, it is a
                // catch-all class: only art its author named <App>-files reaches it, and never a format's own art.
                bool catchAll = !linked.Any(ProjectFormat.IsListed);
                if (!catchAll) {
                    // A class that opens a listed format keeps the index's rules for all its extensions. Any class other than
                    // the index's own and an Open with entry is left alone, as before.
                    string picked = ProjectFormat.Classes.ContainsKey(id) ? null : OpenWithApplication(id);
                    if (picked == null && !ProjectFormat.Classes.ContainsKey(id)) continue;
                    // An Open with entry has no formats of its own: any format it opens counts.
                    formats = ProjectFormat.All.Where(f => (picked != null || f.Opens(id)) && linked.Any(f.Has)).ToArray();
                    // Windows shows one icon for the class: use its first format drawn by this pack.
                    chosen = formats.FirstOrDefault(f => icons.ContainsKey(f.Key));
                    if (chosen != null) icon = icons[chosen.Key];
                    else applications.TryGetValue(picked ?? ProjectFormat.Classes[id], out icon);
                }
                // An Open with entry counts here only while it runs the app's installed program.
                else if (ClassApplication(id, true) != null) unlisted.TryGetValue(application, out icon);
                if (icon == null) continue;
                if (catchAll) identified.Add(id);
                foreach (string ext in linked) themed.Add(ext);
                var change = new ProjectIconChange { Target = id, Icon = icon, Extensions = String.Join(", ", linked.OrderBy(n => n)), Application = application, Unlisted = catchAll };
                if (chosen != null && linked.Any(ext => !formats.Any(f => f.Has(ext)))) change.Reason = "Shares an icon with another file format";
                result.Add(Check(change, Backup(id), false));
            }
            // Only a listed format ever writes an extension's own key.
            foreach (ProjectFormat f in ProjectFormat.All) {
                string icon;
                if (!icons.TryGetValue(f.Key, out icon) && !applications.TryGetValue(f.Application, out icon)) continue;
                if (themed.Contains(f.Key)) continue;
                bool free = f.Native && Unassigned(handlers[f.Key], f.Key);
                // Part of this format already follows its class; the rest opens elsewhere.
                if (!free && f.Extensions.Any(themed.Contains)) continue;
                var change = new ProjectIconChange { Target = f.Key, Icon = icon, Extensions = f.Key, Application = f.Application };
                if (!free) change.Reason = f.Extensions.All(ext => Unassigned(handlers[ext], ext)) ? "No default application" : "Uses another default application";
                result.Add(Check(change, Backup(f.Key), false));
            }
            return result;
        }
        // The targets of the backups in the folder that name a class BetterIcon may change, each under exactly its own file
        // name. Any other file is not one of BetterIcon's backups and is left alone.
        IEnumerable<string> BackupTargets()
        {
            if (!Directory.Exists(root)) yield break;
            foreach (string file in Directory.EnumerateFiles(root, "*.json")) {
                string target = null;
                try {
                    if (new FileInfo(file).Length > 1024 * 1024) continue;
                    var b = json.Deserialize<ProjectIconBackup>(File.ReadAllText(file));
                    if (b != null && b.Target != null && (FixedTarget(b.Target) || AcceptedClass(b.Target)) &&
                        IgnoreCase.Equals(Path.GetFileName(BackupPath(b.Target)), Path.GetFileName(file))) target = b.Target;
                }
                catch (ArgumentException) { }
                catch (InvalidOperationException) { }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
                if (target != null) yield return target;
            }
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
                if (!b.Original.ParentExisted) {
                    RemoveEmpty(user, b.Target);
                    // An Open with entry sits inside Applications; leave no empty folder key behind.
                    int folder = b.Target.LastIndexOf('\\');
                    if (folder > 0) RemoveEmpty(user, b.Target.Substring(0, folder));
                }
            }
        }
        public void Commit(IDictionary<string, string> icons, bool restore, List<ProjectIconChange> reviewed) { Commit(icons, null, null, restore, reviewed); }
        public void Commit(IDictionary<string, string> icons, IDictionary<string, string> applications, bool restore, List<ProjectIconChange> reviewed) { Commit(icons, applications, null, restore, reviewed); }
        public void Commit(IDictionary<string, string> icons, IDictionary<string, string> applications, IDictionary<string, string> unlisted, bool restore, List<ProjectIconChange> reviewed)
        {
            PackLibrary.RegularPath(root); Directory.CreateDirectory(root);
            using (var guard = File.Open(Path.Combine(root, "file-icons.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None)) {
                var fresh = Review(icons, applications, unlisted, restore);
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
                            if (RegisteredForUser(row.Target)) b.PerUser = true;
                            if (row.Unlisted) { b.Unlisted = true; b.Application = row.Application; } else b.Unlisted = null;
                            b.Extensions = row.Extensions;
                            b.Pending = row.Icon; Save(b);
                            touched = true;
                            using (var k = user.CreateSubKey(row.Target + "\\DefaultIcon")) k.SetValue("", row.Icon, RegistryValueKind.String);
                            b.Applied = b.Pending; b.Pending = null; Save(b);
                        }
                    }
                } finally { if (touched && desktop) SHChangeNotify(0x08000000, 0, IntPtr.Zero, IntPtr.Zero); }
            }
        }
        // After app updates. An app installed for this account only writes its file class icon in the same
        // HKCU place as BetterIcon, so its update puts the app's own icon back, or removes the key when the app
        // moves to an install for all users. Such a value is adopted as the new original and the pack icon goes
        // back on. An app installed for all users writes only the machine's classes, and an Open with entry or a
        // bare extension belongs to no installer, so a change there was made by a person or another tool: it is
        // reported and left alone, as is a value anyone else wrote. A class BetterIcon gave an app's art for other file
        // types follows the same rule, but only while a review would still give it that art (StillCatchAll).
        public List<ProjectReconcileRow> Reconcile()
        {
            var rows = new List<ProjectReconcileRow>();
            PackLibrary.RegularPath(root);
            if (!Directory.Exists(root)) return rows;
            using (var guard = File.Open(Path.Combine(root, "file-icons.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None)) {
                bool touched = false;
                identified = new HashSet<string>(IgnoreCase);
                // The installed programs and the extensions each class opens, read as a review reads them, and only when a
                // class with art for other file types is about to get it back.
                Dictionary<string, List<string>> used = null;
                try {
                    var openWith = PackLibrary.Applications.Select(app => "Applications\\" + app + ".exe");
                    foreach (string name in ProjectFormat.ClassNames.Concat(openWith).Concat(ProjectFormat.All.Select(f => f.Key)).Concat(BackupTargets()).Distinct(IgnoreCase)) {
                        var b = Backup(name);
                        if (b == null || String.IsNullOrEmpty(b.Applied)) continue;
                        // A class outside the index's names counts only as BetterIcon recorded it, as a catch-all class.
                        bool catchAll = !FixedTarget(b.Target) && b.Unlisted == true && AcceptedClass(b.Target);
                        if (catchAll) identified.Add(b.Target);
                        if (!AllowedTarget(b.Target)) continue;
                        // Remember an install for this account, so a later move to an install for all users, which
                        // removes the user's class key, is still known as the app's own doing.
                        bool perUser = (ProjectFormat.Classes.ContainsKey(b.Target) || catchAll) && (b.PerUser == true || RegisteredForUser(b.Target));
                        if (perUser && b.PerUser != true) { b.PerUser = true; Save(b); }
                        var now = Current(b.Target);
                        if (Ours(b, now)) continue;
                        if (now.Kind != RegistryValueKind.Unknown && now.Kind != RegistryValueKind.String && now.Kind != RegistryValueKind.ExpandString) continue;
                        var row = new ProjectReconcileRow { Target = b.Target, Application = TargetApplication(b.Target) ?? b.Application, Value = now.Text };
                        bool rebase = false;
                        if (!perUser) { row.Status = "Changed"; rows.Add(row); continue; }
                        // A class another program took over, one that now also opens a listed format, or one whose app was
                        // uninstalled would get no art for other file types from a review: it is reported and left alone.
                        bool others = b.Unlisted == true;
                        if (others) {
                            if (used == null) { FindPrograms(); used = ClassExtensions(new Dictionary<string, string>(IgnoreCase)); }
                            if (!StillCatchAll(b, used)) { row.Status = "Changed"; rows.Add(row); continue; }
                        }
                        if (now.Matches(b.Original)) row.Status = "Reapplied";
                        else if (AppOwned(b.Target, now, b.Application, others)) { row.Status = "Rebased"; rebase = true; }
                        else { row.Status = "Changed"; rows.Add(row); continue; }
                        if (!IconUsable(b.Applied)) { row.Status = "IconMissing"; rows.Add(row); continue; }
                        // Changed again while it was read: the next check sees the newer value.
                        if (!Current(b.Target).Matches(now)) continue;
                        if (rebase) {
                            if (b.PreviousOriginals == null) b.PreviousOriginals = new List<ProjectIconValue>();
                            b.PreviousOriginals.Add(b.Original);
                            b.Original = now;
                        }
                        b.Pending = b.Applied; Save(b);
                        touched = true;
                        using (var k = user.CreateSubKey(b.Target + "\\DefaultIcon")) k.SetValue("", b.Applied, RegistryValueKind.String);
                        b.Pending = null; Save(b);
                        rows.Add(row);
                    }
                } finally { if (touched && desktop) SHChangeNotify(0x08000000, 0, IntPtr.Zero, IntPtr.Zero); }
            }
            return rows;
        }
        // Whether a review would still give this class the app's art for other file types: the class's open command runs that
        // app's installed program (so the class still exists), and it is the real default of a type outside the list and of no
        // listed one.
        bool StillCatchAll(ProjectIconBackup b, Dictionary<string, List<string>> used)
        {
            List<string> linked;
            return b.Application != null && IgnoreCase.Equals(ClassApplication(b.Target, true), b.Application) &&
                used.TryGetValue(b.Target, out linked) && linked.Count != 0 && !linked.Any(ProjectFormat.IsListed);
        }
        // The app that registers this class was installed for this account only: its open command is in the
        // user's own classes, where only a per-user installer puts it. That holds for the index's classes and for a
        // catch-all class, never for an Open with entry.
        bool RegisteredForUser(string target)
        {
            bool own = ProjectFormat.Classes.ContainsKey(target) || (identified.Contains(target) && OpenWithApplication(target) == null && AcceptedClass(target));
            if (!own) return false;
            using (var command = user.OpenSubKey(target + @"\shell\open\command")) return command != null;
        }
        public static string TargetApplication(string target)
        {
            string application;
            if (ProjectFormat.Classes.TryGetValue(target, out application)) return application;
            application = OpenWithApplication(target);
            if (application != null) return application;
            ProjectFormat format = ProjectFormat.All.FirstOrDefault(f => IgnoreCase.Equals(f.Key, target));
            return format == null ? null : format.Application;
        }
        // The value an app's own installer writes: none at all, an icon in a Windows Installer cache, or the app's
        // program or a file beside it, where the class's open command names that same ArtCraft program. For a class with
        // art for other file types (strict) that program must be the installed program of the app its backup names, as a
        // review requires (FindPrograms); a name such as PhotoCraft Helper, or a photocraft.exe elsewhere, is not.
        bool AppOwned(string target, ProjectIconValue value, string application, bool strict)
        {
            if (value.Text == null) return true;
            // An extension's own key has no opener of its own.
            if (target.StartsWith(".", StringComparison.Ordinal)) return false;
            string icon = IconFile(value.Text);
            if (icon == null) return false;
            if (InInstallerCache(icon)) return true;
            string exe = OpenerExecutable(target), expected;
            if (exe == null) return false;
            if (strict) {
                if (programs == null || !programs.TryGetValue(exe, out expected) || !IgnoreCase.Equals(expected, application)) return false;
            }
            else {
                if (!ProjectFormat.Classes.TryGetValue(target, out expected)) expected = OpenWithApplication(target);
                if (expected == null || !IgnoreCase.Equals(AppNames.Match(Path.GetFileNameWithoutExtension(exe)), expected)) return false;
            }
            return IgnoreCase.Equals(icon, exe) || IgnoreCase.Equals(Path.GetDirectoryName(icon), Path.GetDirectoryName(exe));
        }
        // The file an icon value names, without quotes or its index, with variables expanded.
        static string IconFile(string text)
        {
            if (String.IsNullOrWhiteSpace(text)) return null;
            string value = Environment.ExpandEnvironmentVariables(text).Trim();
            if (value.StartsWith("\"", StringComparison.Ordinal)) {
                int end = value.IndexOf('"', 1);
                if (end < 0) return null;
                value = value.Substring(1, end - 1);
            }
            else {
                int comma = value.LastIndexOf(',');
                if (comma > 0 && value.Substring(comma + 1).Trim().TrimStart('-').All(Char.IsDigit)) value = value.Substring(0, comma);
            }
            value = value.Trim();
            try { return Path.IsPathRooted(value) ? Path.GetFullPath(value) : null; }
            catch (ArgumentException) { return null; }
            catch (NotSupportedException) { return null; }
            catch (PathTooLongException) { return null; }
        }
        static bool InInstallerCache(string icon)
        {
            string folder = Path.GetDirectoryName(icon);
            if (folder == null || !Regex.IsMatch(Path.GetFileName(folder), @"^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$")) return false;
            string parent = Path.GetDirectoryName(folder);
            return IgnoreCase.Equals(parent, Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Microsoft", "Installer")) ||
                IgnoreCase.Equals(parent, Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Installer"));
        }
        // The program in the class's open command: the quoted first word, or everything up to ".exe".
        string OpenerExecutable(string target)
        {
            string command = RegString(source, target + @"\shell\open\command", "");
            if (String.IsNullOrWhiteSpace(command)) return null;
            command = Environment.ExpandEnvironmentVariables(command).Trim();
            string exe;
            if (command.StartsWith("\"", StringComparison.Ordinal)) {
                int end = command.IndexOf('"', 1);
                if (end < 0) return null;
                exe = command.Substring(1, end - 1);
            }
            else {
                int at = command.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
                if (at < 0) return null;
                exe = command.Substring(0, at + 4);
            }
            try { return Path.IsPathRooted(exe) ? Path.GetFullPath(exe) : null; }
            catch (ArgumentException) { return null; }
            catch (NotSupportedException) { return null; }
            catch (PathTooLongException) { return null; }
        }
        // Artwork BetterIcon cached itself must still be the file it wrote. A value elsewhere is used as recorded.
        bool IconUsable(string applied)
        {
            string file = IconFile(applied);
            if (file == null) return true;
            string images = Path.GetFullPath(Path.Combine(root, "images"));
            if (!IgnoreCase.Equals(Path.GetDirectoryName(file), images)) return true;
            if (!File.Exists(file)) return false;
            using (var sha = SHA256.Create())
            using (var stream = File.OpenRead(file))
                return IgnoreCase.Equals(Path.GetFileNameWithoutExtension(file), BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", ""));
        }
    }
}
