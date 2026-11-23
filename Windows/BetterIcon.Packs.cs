using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace BetterIcon.Tray
{
    public sealed class StoredPack
    {
        public string Id { get; set; }
        public string Revision { get; set; }
        public string Name { get; set; }
        public string Author { get; set; }
        public bool Removed { get; set; }
        public Dictionary<string, string> Icons { get; set; }
        public Dictionary<string, string> FileIcons { get; set; }
        // An app's art for file types outside BetterIcon's list, kept at import from FileTypes/<App>-files art, by app:
        // "<App>-files.<ext>" in the revision's FileTypes folder. Earlier versions ignore it, and a pack they stored has none.
        public Dictionary<string, string> UnlistedFileIcons { get; set; }
    }
    public sealed class SharedPackMetadata
    {
        public string Format { get; set; }
        public int Version { get; set; }
        public string Name { get; set; }
        public string Author { get; set; }
    }
    public sealed class PackLibraryState
    {
        public int Schema { get; set; }
        public List<StoredPack> Packs { get; set; }
        // Older versions can still read the app packs when this library also contains file-only packs.
        public List<StoredPack> FileOnlyPacks { get; set; }
        public List<string> HiddenBundled { get; set; }
        public PackLibraryState() { Schema = 1; Packs = new List<StoredPack>(); FileOnlyPacks = new List<StoredPack>(); HiddenBundled = new List<string>(); }
        public IEnumerable<StoredPack> AllPacks() { return Packs.Concat(FileOnlyPacks); }
    }
    // Personal artwork never enters the repository or a distributable build.
    // Revisions are immutable: a preview can still apply the exact files it showed.
    public sealed class PackLibrary
    {
        public static readonly string[] Applications = { "PhotoCraft", "VectorCraft", "FilmCraft", "LightCraft", "PdfCraft", "EffectCraft", "AniCraft", "DesignCraft", "FigCraft", "TextureCraft", "MaterialCraft", "SoundCraft", "WordCraft", "DeckCraft", "CADCraft", "GridCraft", "CraftAnything", "SolidCraft", "MailCraft", "ArtCraftLauncher" };
        const int MaxImageBytes = 16 * 1024 * 1024;
        const long MaxPackBytes = 128L * 1024 * 1024;
        const int MaxMetadataBytes = 16 * 1024;
        const string MetadataFile = "bettericon-pack.json";
        public string Root { get; private set; }
        string Manifest { get { return Path.Combine(Root, "library.json"); } }
        public PackLibrary(string root) { Root = Path.GetFullPath(root); }
        static bool GuidName(string value) { return value != null && Regex.IsMatch(value, "^[a-f0-9]{32}$"); }
        public static void RegularPath(string path)
        {
            string current = Path.GetFullPath(path);
            while (!String.IsNullOrEmpty(current)) {
                if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0 && BetterIcon.Windows.ShellLink.IsRedirectedPath(current))
                    throw new IOException("Linked files or folders are not supported: " + current);
                current = Path.GetDirectoryName(current);
            }
        }
        PackLibraryState Read()
        {
            RegularPath(Manifest);
            if (!File.Exists(Manifest)) return new PackLibraryState();
            if (new FileInfo(Manifest).Length > 2 * 1024 * 1024) throw new IOException("The icon library is too large to read.");
            PackLibraryState state = new JavaScriptSerializer().Deserialize<PackLibraryState>(File.ReadAllText(Manifest, Encoding.UTF8));
            if (state == null || state.Schema != 1 || state.Packs == null || state.FileOnlyPacks == null || state.HiddenBundled == null) throw new IOException("Unrecognized icon library. Its contents have been preserved.");
            HashSet<string> ids = new HashSet<string>();
            foreach (StoredPack pack in state.AllPacks()) {
                if (!GuidName(pack.Id) || !GuidName(pack.Revision) || !ids.Add(pack.Id) || String.IsNullOrWhiteSpace(pack.Name) || pack.Icons == null || (pack.Icons.Count == 0 && (pack.FileIcons == null || pack.FileIcons.Count == 0)))
                    throw new IOException("Invalid icon pack record. Its contents have been preserved.");
                foreach (var icon in pack.Icons) if (!Applications.Contains(icon.Key) || (icon.Value != icon.Key + ".png" && icon.Value != icon.Key + ".ico" && icon.Value != icon.Key + ".svg")) throw new IOException("Invalid icon filename in the library.");
                if (pack.FileIcons != null) foreach (var icon in pack.FileIcons)
                    if (!ProjectFormat.IsKey(icon.Key) || !new[] { ".png", ".ico", ".svg" }.Any(ext => icon.Value == icon.Key.Substring(1) + ext))
                        throw new IOException("Invalid project file icon in the library.");
                if (pack.UnlistedFileIcons != null) foreach (var icon in pack.UnlistedFileIcons)
                    if (!Applications.Contains(icon.Key) || !new[] { ".png", ".ico", ".svg" }.Any(ext => icon.Value == icon.Key + UnlistedStem + ext))
                        throw new IOException("Invalid project file icon in the library.");
            }
            return state;
        }
        const string UnlistedStem = "-files";
        // In the files given to Save: an app's art for file types outside BetterIcon's list, beside its app icon and formats.
        public static string UnlistedKey(string application) { return SharedFileArt + application; }
        static string UnlistedApp(string key) { return key != null && key.StartsWith(SharedFileArt, StringComparison.Ordinal) && Applications.Contains(key.Substring(SharedFileArt.Length)) ? key.Substring(SharedFileArt.Length) : null; }
        // Whether FileTypes art for an app opts in to file types outside BetterIcon's list: the stem of its file name is the
        // app's name, then exactly one ASCII space, underscore, dot or hyphen, then "files". Letters match in any case, as the
        // shared helper's allFilesNames and the catalog's Test-UnlistedFileArtName match them (Go's case folding, which also
        // takes the Kelvin sign for k and the long s for s). ArtCraft Launcher and Craft Anything may be split by spaces,
        // underscores or hyphens. A Unicode space, a format label (PhotoCraft-PSD) or more text (PhotoCraft-files-v2) never
        // counts.
        public static bool UnlistedFileArtName(string stem, string application)
        {
            if (String.IsNullOrEmpty(stem) || !Applications.Contains(application)) return false;
            string spelling = application == "ArtCraftLauncher" ? "artcraft[ _-]*launcher" : application == "CraftAnything" ? "craft[ _-]*anything" : Regex.Escape(application.ToLowerInvariant());
            return Regex.IsMatch(AppNames.Fold(stem), "^" + spelling + @"[ _.-]files\z", RegexOptions.CultureInvariant);
        }
        FileStream Lock()
        {
            RegularPath(Root); Directory.CreateDirectory(Root);
            string path = Path.Combine(Root, "library.lock"); RegularPath(path);
            return File.Open(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        }
        void Write(PackLibraryState state)
        {
            string temporary = Path.Combine(Root, ".library-" + Guid.NewGuid().ToString("N") + ".tmp");
            try {
                File.WriteAllText(temporary, new JavaScriptSerializer().Serialize(state), new UTF8Encoding(false));
                if (File.Exists(Manifest)) File.Replace(temporary, Manifest, null); else File.Move(temporary, Manifest);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        ThemeEntry Theme(StoredPack pack)
        {
            string directory = Path.Combine(Root, pack.Id, pack.Revision);
            ThemeIcon[] icons = pack.Icons.Select(p => new ThemeIcon { Application = p.Key, Path = Path.Combine(directory, p.Value) }).ToArray();
            foreach (ThemeIcon icon in icons) { RegularPath(icon.Path); if (!File.Exists(icon.Path)) throw new IOException("Artwork is missing from " + pack.Name + "."); }
            var documents = (pack.FileIcons ?? new Dictionary<string, string>()).ToDictionary(p => p.Key, p => Path.Combine(directory, "FileTypes", p.Value));
            var unlisted = (pack.UnlistedFileIcons ?? new Dictionary<string, string>()).ToDictionary(p => p.Key, p => Path.Combine(directory, "FileTypes", p.Value));
            foreach (string path in documents.Values.Concat(unlisted.Values)) { RegularPath(path); if (!File.Exists(path)) throw new IOException("File artwork is missing from " + pack.Name + "."); }
            return new ThemeEntry { Id = "User/" + pack.Id + "/" + pack.Revision, LibraryId = pack.Id, Managed = true, Name = pack.Name, Author = pack.Author, Pack = "Personal", IconCount = icons.Length, Icons = icons, FileIcons = documents,
                UnlistedFileIcons = unlisted };
        }
        public ThemeEntry[] VisibleThemes(IEnumerable<ThemeEntry> bundled)
        {
            PackLibraryState state = Read();
            return bundled.Where(t => !state.HiddenBundled.Contains(t.Id)).Concat(state.AllPacks().Where(p => !p.Removed).Select(Theme)).ToArray();
        }
        public ThemeEntry Save(string name, IDictionary<string, string> files, string editId, string author = null)
        {
            Dictionary<string, byte[]> images = new Dictionary<string, byte[]>();
            Dictionary<string, string> extensions = new Dictionary<string, string>();
            foreach (var entry in files) {
                if (!Applications.Contains(entry.Key) && !ProjectFormat.IsKey(entry.Key) && UnlistedApp(entry.Key) == null) throw new ArgumentException("Unsupported icon target: " + entry.Key);
                RegularPath(entry.Value);
                if (new FileInfo(entry.Value).Length > MaxImageBytes) throw new IOException("Each icon must be smaller than 16 MB.");
                images.Add(entry.Key, File.ReadAllBytes(entry.Value)); extensions.Add(entry.Key, Path.GetExtension(entry.Value).ToLowerInvariant());
            }
            return SaveBytes(name, images, extensions, editId, author);
        }
        static string Label(string value, string field, bool required)
        {
            value = (value ?? "").Trim();
            if ((required && value.Length == 0) || value.Length > 64 || value.Any(Char.IsControl)) throw new ArgumentException(field + " must be " + (required ? "between 1 and 64" : "at most 64") + " characters without control characters.");
            return value;
        }
        public ThemeEntry ReplaceAppIcon(ThemeEntry basis, string application, string path)
        {
            if (!Applications.Contains(application)) throw new ArgumentException("Unsupported app: " + application);
            Dictionary<string, string> files = basis == null || basis.IsDefault ? new Dictionary<string, string>() : basis.Icons.ToDictionary(icon => icon.Application, icon => String.IsNullOrEmpty(icon.PreviewPath) ? icon.Path : icon.PreviewPath);
            if (basis != null) foreach (var file in ProjectFormat.Artwork(basis).Expanded()) files.Add(file.Key, file.Value);
            // The art for file types outside BetterIcon's list stays: a personal pack's item, or a pack's opted-in art.
            if (basis != null) foreach (var file in ProjectFormat.Artwork(basis).Unlisted) files[UnlistedKey(file.Key)] = file.Value;
            files[application] = path;
            if (basis != null && basis.Managed) return Save(basis.Name, files, basis.LibraryId, basis.Author);
            string stem = basis == null || basis.IsDefault ? "My icon pack" : basis.Name + " custom";
            string name = stem.Substring(0, Math.Min(64, stem.Length));
            HashSet<string> names = new HashSet<string>(Read().AllPacks().Where(pack => !pack.Removed).Select(pack => pack.Name), StringComparer.OrdinalIgnoreCase);
            for (int number = 2; names.Contains(name); number++) {
                string suffix = " (" + number + ")";
                name = stem.Substring(0, Math.Min(64 - suffix.Length, stem.Length)) + suffix;
            }
            return Save(name, files, null, basis == null ? null : basis.Author);
        }
        ThemeEntry SaveBytes(string name, Dictionary<string, byte[]> images, Dictionary<string, string> extensions, string editId, string author)
        {
            name = Label(name, "Pack name", true);
            author = Label(author, "Author", false);
            // Art for other file types alone is no pack: earlier versions read a pack by its app icons and listed formats.
            if (!images.Keys.Any(key => UnlistedApp(key) == null)) throw new ArgumentException("Choose artwork for at least one app or file type.");
            // WebP artwork is kept as PNG, which every part of the app, earlier versions and the other platforms read.
            // Windows' own decoder converts it, or BetterIcon's libwebp where Windows has none.
            foreach (string key in extensions.Where(e => e.Value == ".webp").Select(e => e.Key).ToArray()) {
                if (images[key].Length == 0 || images[key].Length > MaxImageBytes) throw new IOException("Each icon must be between 1 byte and 16 MB.");
                images[key] = ConvertWebP(images[key]); extensions[key] = ".png";
            }
            if (images.Values.Sum(b => (long)b.Length) > MaxPackBytes - MaxMetadataBytes) throw new IOException("A pack must be smaller than 128 MB to share as a ZIP.");
            foreach (var image in images) ValidateImage(image.Value, extensions[image.Key]);
            using (Lock()) {
                PackLibraryState state = Read();
                StoredPack old = editId == null ? null : state.AllPacks().SingleOrDefault(p => p.Id == editId && !p.Removed);
                if (editId != null && old == null) throw new IOException("This pack was removed. Create a new pack instead.");
                if (state.AllPacks().Any(p => !p.Removed && p.Id != editId && p.Name.Equals(name, StringComparison.OrdinalIgnoreCase))) throw new ArgumentException("A personal pack already has that name.");
                StoredPack pack = new StoredPack { Id = old == null ? Guid.NewGuid().ToString("N") : old.Id, Revision = Guid.NewGuid().ToString("N"), Name = name, Author = author, Icons = new Dictionary<string, string>() };
                string folder = Path.Combine(Root, pack.Id, pack.Revision); RegularPath(folder); Directory.CreateDirectory(folder);
                pack.FileIcons = new Dictionary<string, string>();
                foreach (var image in images) {
                    string unlisted = UnlistedApp(image.Key);
                    bool project = unlisted != null || ProjectFormat.IsKey(image.Key);
                    string directory = project ? Path.Combine(folder, "FileTypes") : folder;
                    string file = (unlisted != null ? unlisted + UnlistedStem : project ? image.Key.Substring(1) : image.Key) + extensions[image.Key];
                    Directory.CreateDirectory(directory);
                    File.WriteAllBytes(Path.Combine(directory, file), image.Value);
                    if (unlisted != null) {
                        if (pack.UnlistedFileIcons == null) pack.UnlistedFileIcons = new Dictionary<string, string>();
                        pack.UnlistedFileIcons.Add(unlisted, file);
                    }
                    else (project ? pack.FileIcons : pack.Icons).Add(image.Key, file);
                }
                if (old != null) { state.Packs.Remove(old); state.FileOnlyPacks.Remove(old); }
                (pack.Icons.Count == 0 ? state.FileOnlyPacks : state.Packs).Add(pack);
                Write(state); return Theme(pack);
            }
        }
        static void ValidateImage(byte[] bytes, string extension)
        {
            if (bytes.Length == 0 || bytes.Length > MaxImageBytes) throw new IOException("Each icon must be between 1 byte and 16 MB.");
            using (MemoryStream stream = new MemoryStream(bytes, false)) {
                if (extension == ".svg") { using (Bitmap bitmap = SvgArtwork.Render(bytes, 256)) { } }
                else if (extension == ".ico") { using (Icon icon = new Icon(stream)) using (Bitmap bitmap = icon.ToBitmap()) { if (bitmap.Width > 4096 || bitmap.Height > 4096) throw new IOException("Icon dimensions exceed 4096 pixels."); } }
                else if (extension == ".png") {
                    byte[] signature = { 137, 80, 78, 71, 13, 10, 26, 10 };
                    if (bytes.Length < 24 || !bytes.Take(8).SequenceEqual(signature)) throw new IOException("The selected file is not a PNG image.");
                    long width = 0, height = 0;
                    for (int i = 0; i < 4; i++) { width = width * 256 + bytes[16 + i]; height = height * 256 + bytes[20 + i]; }
                    if (width < 1 || height < 1 || width > 4096 || height > 4096) throw new IOException("PNG dimensions must be between 1 and 4096 pixels.");
                    using (Image image = Image.FromStream(stream, false, true)) using (Bitmap bitmap = new Bitmap(image)) { }
                }
                else throw new IOException("Choose SVG, PNG, ICO or WebP artwork.");
            }
        }
        static string AppForFile(string file)
        {
            string name = Path.GetFileNameWithoutExtension(file);
            string parent = Path.GetDirectoryName(file) ?? "";
            string named = Applications.FirstOrDefault(app => Regex.IsMatch(name, "^" + (app == "CraftAnything" ? "Craft[ _-]*Anything" : app == "ArtCraftLauncher" ? "ArtCraft[ _-]*Launcher" : Regex.Escape(app)) + "(?:[ _.-].*)?$", RegexOptions.IgnoreCase));
            if (parent.Split('\\', '/').Contains("FileTypes", StringComparer.OrdinalIgnoreCase)) {
                // An extension names one format. A name that starts with an app, such as
                // PhotoCraft-PSD, is that app's icon for every file type it opens.
                string key = "." + name.TrimStart('.').ToLowerInvariant();
                return ProjectFormat.IsKey(key) ? key : named == null ? null : SharedFileArt + named;
            }
            return named;
        }
        const string SharedFileArt = "*";
        // A personal pack stores one image per format, so each can later be replaced on its own.
        static void ExpandSharedFileArt(Dictionary<string, byte[]> images, Dictionary<string, string> extensions)
        {
            foreach (string shared in images.Keys.Where(key => key.StartsWith(SharedFileArt)).ToArray()) {
                foreach (ProjectFormat format in ProjectFormat.All.Where(f => f.Application == shared.Substring(SharedFileArt.Length)))
                    if (!images.ContainsKey(format.Key)) { images[format.Key] = images[shared]; extensions[format.Key] = extensions[shared]; }
                images.Remove(shared); extensions.Remove(shared);
            }
        }
        // SVG, then ICO, WebP and PNG, as in pack folders and the catalog.
        static int FormatPriority(string extension) { return extension == ".svg" ? 5 : extension == ".ico" ? 4 : extension == ".webp" ? 3 : extension == ".png" ? 2 : 0; }
        // Every candidate of each item, one per extension, as a way to read it: nothing is read until ChooseImages tries
        // that candidate, so an import holds only the artwork it keeps. A second file of an extension is remembered in
        // duplicates: it makes the item ambiguous only when that extension is the one the item ends up using.
        // named records, for each app's FileTypes art, whether every candidate file is named <App>-files, duplicates included.
        static void AddImage(Dictionary<string, Dictionary<string, Func<byte[]>>> candidates, HashSet<string> duplicates, Dictionary<string, bool> named, string file, Func<byte[]> read)
        {
            string extension = Path.GetExtension(file).ToLowerInvariant(), app = AppForFile(file);
            if (app == null || FormatPriority(extension) == 0) return;
            if (app.StartsWith(SharedFileArt, StringComparison.Ordinal)) {
                bool all, opted = UnlistedFileArtName(Path.GetFileNameWithoutExtension(file), app.Substring(SharedFileArt.Length));
                named[app] = opted && (!named.TryGetValue(app, out all) || all);
            }
            Dictionary<string, Func<byte[]>> formats;
            if (!candidates.TryGetValue(app, out formats)) candidates[app] = formats = new Dictionary<string, Func<byte[]>>();
            if (formats.ContainsKey(extension)) { duplicates.Add(app + "|" + extension); return; }
            formats[extension] = read;
        }
        // The bytes one import may read in all. A ZIP entry can claim a smaller size than it inflates to, so what counts
        // is what was actually read.
        sealed class ImportBudget
        {
            public long Remaining = MaxPackBytes;
            public string Exceeded;
        }
        static string ItemName(string key) { return key.StartsWith(SharedFileArt) ? key.Substring(SharedFileArt.Length) + " files" : key; }
        // A single chosen WebP: the cause alone, with a hint for animation.
        static byte[] ConvertWebP(byte[] bytes)
        {
            try { return WebpArtwork.ToPng(bytes); }
            catch (IOException error) { throw new IOException(error.Message + (error.Message == WebpArtwork.Animated ? WebpArtwork.StillImage : ""), error); }
        }
        // For each item, its formats in precedence order: SVG, ICO, WebP, PNG. The first one is used, as before, and two
        // files of it leave the item ambiguous. A WebP that can't be read gives way to the next format and is otherwise
        // stored as PNG; SVG, ICO and PNG are checked when the pack is saved, as before. When an item is ambiguous, or
        // nothing is left of it, the import stops with the first such item by name and the library is unchanged.
        static void ChooseImages(Dictionary<string, Dictionary<string, Func<byte[]>>> candidates, HashSet<string> duplicates, Dictionary<string, byte[]> images, Dictionary<string, string> extensions)
        {
            List<string> ambiguous = new List<string>();
            SortedDictionary<string, string> unusable = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var item in candidates) {
                string cause = null;
                bool chosen = false;
                foreach (var candidate in item.Value.OrderByDescending(c => FormatPriority(c.Key))) {
                    if (duplicates.Contains(item.Key + "|" + candidate.Key)) { ambiguous.Add(item.Key); chosen = true; break; }
                    // A file that can't be read, or that goes past a size limit, stops the import whatever its format.
                    byte[] bytes = candidate.Value();
                    if (candidate.Key != ".webp") { images[item.Key] = bytes; extensions[item.Key] = candidate.Key; chosen = true; break; }
                    try { images[item.Key] = WebpArtwork.ToPng(bytes); extensions[item.Key] = ".png"; chosen = true; break; }
                    catch (IOException error) { if (cause == null) cause = error.Message; }
                }
                if (!chosen) unusable[ItemName(item.Key)] = cause + (cause == WebpArtwork.Animated ? WebpArtwork.StillImage : "");
            }
            if (ambiguous.Count != 0) throw new IOException("Several icons match " + ambiguous.Select(app => app.TrimStart('*')).OrderBy(app => app).First() + ". Import one theme at a time.");
            if (unusable.Count != 0) throw new IOException(unusable.First().Key + ": " + unusable.First().Value);
        }
        public ThemeEntry Import(string source)
        {
            RegularPath(source);
            Dictionary<string, byte[]> images = new Dictionary<string, byte[]>();
            Dictionary<string, string> extensions = new Dictionary<string, string>();
            Dictionary<string, Dictionary<string, Func<byte[]>>> candidates = new Dictionary<string, Dictionary<string, Func<byte[]>>>();
            HashSet<string> duplicates = new HashSet<string>();
            Dictionary<string, bool> named = new Dictionary<string, bool>();
            string name; SharedPackMetadata metadata = null;
            if (Directory.Exists(source)) {
                source = Path.GetFullPath(source);
                name = new DirectoryInfo(source).Name;
                ImportBudget budget = new ImportBudget { Exceeded = "Import a single theme folder smaller than 128 MB." };
                Stack<string> pending = new Stack<string>(); pending.Push(source); int count = 0;
                while (pending.Count > 0) foreach (string path in Directory.EnumerateFileSystemEntries(pending.Pop())) {
                    if (++count > 1024) throw new IOException("Import a single theme folder with fewer than 1024 entries.");
                    RegularPath(path);
                    if (Directory.Exists(path)) pending.Push(path);
                    else if (Path.GetFileName(path).Equals(MetadataFile, StringComparison.OrdinalIgnoreCase)) {
                        if (metadata != null) throw new IOException("Several pack descriptions found. Import one theme at a time.");
                        using (Stream input = File.OpenRead(path)) metadata = ReadMetadata(ReadLimited(input, MaxMetadataBytes));
                    }
                    else AddImage(candidates, duplicates, named, path.Substring(Path.GetFullPath(source).TrimEnd('\\', '/').Length + 1), delegate {
                        // Read when chosen, so the path is checked again then.
                        RegularPath(path);
                        if (new FileInfo(path).Length > MaxImageBytes) throw new IOException("An icon exceeds 16 MB.");
                        using (Stream input = File.OpenRead(path)) return ReadLimited(input, MaxImageBytes, budget);
                    });
                }
                ChooseImages(candidates, duplicates, images, extensions);
            }
            else {
                if (!Path.GetExtension(source).Equals(".zip", StringComparison.OrdinalIgnoreCase)) throw new IOException("Choose a theme folder or ZIP file.");
                name = Path.GetFileNameWithoutExtension(source);
                const string tooLarge = "Import a single theme ZIP smaller than 128 MB when expanded.";
                ImportBudget budget = new ImportBudget { Exceeded = tooLarge };
                using (ZipArchive zip = ZipFile.OpenRead(source)) {
                    // The sizes the entries claim, then, as each is read, the bytes it actually inflates to.
                    if (zip.Entries.Count > 1024 || zip.Entries.Sum(e => e.Length) > MaxPackBytes) throw new IOException(tooLarge);
                    foreach (ZipArchiveEntry entry in zip.Entries) {
                        string path = entry.FullName.Replace('\\', '/');
                        if (path.StartsWith("/") || path.Contains(":") || path.Split('/').Any(p => p == ".." || p == ".") || ((entry.ExternalAttributes >> 16) & 0xf000) == 0xa000) throw new IOException("The ZIP contains an unsafe path or link.");
                        if (Path.GetFileName(path).Equals(MetadataFile, StringComparison.OrdinalIgnoreCase)) {
                            if (metadata != null) throw new IOException("Several pack descriptions found. Import one theme at a time.");
                            using (Stream input = entry.Open()) metadata = ReadMetadata(ReadLimited(input, MaxMetadataBytes));
                            continue;
                        }
                        ZipArchiveEntry captured = entry;
                        AddImage(candidates, duplicates, named, path, delegate {
                            if (captured.Length > MaxImageBytes) throw new IOException("An icon exceeds 16 MB.");
                            using (Stream input = captured.Open()) return ReadLimited(input, MaxImageBytes, budget);
                        });
                    }
                    // The archive stays open while the chosen candidates are read.
                    ChooseImages(candidates, duplicates, images, extensions);
                }
            }
            // App art in FileTypes named <App>-files in every candidate is also kept as an item of its own: that app's art for
            // file types outside BetterIcon's list. Each listed format still gets its copy, as before.
            var items = images.Where(image => { bool all; return image.Key.StartsWith(SharedFileArt, StringComparison.Ordinal) && named.TryGetValue(image.Key, out all) && all; })
                .ToDictionary(image => image.Key, image => image.Value);
            var itemExtensions = items.Keys.ToDictionary(key => key, key => extensions[key]);
            ExpandSharedFileArt(images, extensions);
            if (images.Count == 0) throw new IOException("No matching icons found. Use app names, or put file type artwork in FileTypes, such as FileTypes/pdf.png.");
            foreach (var item in items) { images[item.Key] = item.Value; extensions[item.Key] = itemExtensions[item.Key]; }
            return SaveBytes(metadata == null ? name : metadata.Name, images, extensions, null, metadata == null ? "" : metadata.Author);
        }
        static byte[] ReadLimited(Stream input, int limit) { return ReadLimited(input, limit, null); }
        // At most limit bytes from one file, and no more in all than the import's budget allows.
        static byte[] ReadLimited(Stream input, int limit, ImportBudget budget)
        {
            using (MemoryStream output = new MemoryStream()) {
                byte[] buffer = new byte[8192]; int read;
                while ((read = input.Read(buffer, 0, buffer.Length)) != 0) {
                    if (output.Length + read > limit) throw new IOException("A pack file exceeds its size limit.");
                    if (budget != null) {
                        budget.Remaining -= read;
                        if (budget.Remaining < 0) throw new IOException(budget.Exceeded);
                    }
                    output.Write(buffer, 0, read);
                }
                return output.ToArray();
            }
        }
        static SharedPackMetadata ReadMetadata(byte[] bytes)
        {
            SharedPackMetadata metadata = new JavaScriptSerializer().Deserialize<SharedPackMetadata>(Encoding.UTF8.GetString(bytes).TrimStart('\uFEFF'));
            if (metadata == null || metadata.Format != "BetterIcon.IconPack" || metadata.Version != 1) throw new IOException("Unrecognized icon pack description.");
            metadata.Name = Label(metadata.Name, "Pack name", true); metadata.Author = Label(metadata.Author, "Author", false);
            return metadata;
        }
        public void Export(ThemeEntry selected, string destination, bool overwrite = false)
        {
            if (selected == null || !selected.Managed) throw new ArgumentException("Select a personal pack to export. Use Customize to copy a built-in pack first.");
            destination = Path.GetFullPath(destination); RegularPath(destination);
            if (!Path.GetExtension(destination).Equals(".zip", StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Save the pack as a ZIP file.");
            if (File.Exists(destination) && !overwrite) throw new IOException("The ZIP already exists. Choose a new filename.");
            ThemeEntry theme;
            using (Lock()) {
                StoredPack pack = Read().AllPacks().SingleOrDefault(p => p.Id == selected.LibraryId && !p.Removed);
                if (pack == null || selected.Id != "User/" + pack.Id + "/" + pack.Revision) throw new IOException("This pack changed. Select it again before exporting.");
                theme = Theme(pack);
            }
            Dictionary<string, byte[]> files = new Dictionary<string, byte[]>();
            foreach (ThemeIcon icon in theme.Icons) {
                byte[] bytes; using (Stream input = File.OpenRead(icon.Path)) bytes = ReadLimited(input, MaxImageBytes);
                ValidateImage(bytes, Path.GetExtension(icon.Path)); files.Add(Path.GetFileName(icon.Path), bytes);
            }
            // An app's art for other file types travels as FileTypes/<App>-files.<ext>, so a reimport keeps it too.
            foreach (var icon in theme.FileIcons.Concat(theme.UnlistedFileIcons ?? new Dictionary<string, string>())) {
                byte[] bytes; using (Stream input = File.OpenRead(icon.Value)) bytes = ReadLimited(input, MaxImageBytes);
                ValidateImage(bytes, Path.GetExtension(icon.Value)); files.Add("FileTypes/" + Path.GetFileName(icon.Value), bytes);
            }
            // Share only portable display metadata and app artwork, never local paths, IDs or preferences.
            SharedPackMetadata metadata = new SharedPackMetadata { Format = "BetterIcon.IconPack", Version = 1, Name = Label(theme.Name, "Pack name", true), Author = Label(theme.Author, "Author", false) };
            files.Add(MetadataFile, Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(metadata)));
            if (files.Values.Sum(b => (long)b.Length) > MaxPackBytes) throw new IOException("A shared pack must be smaller than 128 MB.");
            string temporary = Path.Combine(Path.GetDirectoryName(destination), ".bettericon-export-" + Guid.NewGuid().ToString("N") + ".tmp");
            try {
                using (ZipArchive zip = ZipFile.Open(temporary, ZipArchiveMode.Create)) foreach (var file in files.OrderBy(f => f.Key)) {
                    using (Stream output = zip.CreateEntry(file.Key, CompressionLevel.Optimal).Open()) output.Write(file.Value, 0, file.Value.Length);
                }
                RegularPath(destination);
                if (overwrite && File.Exists(destination)) File.Replace(temporary, destination, null); else File.Move(temporary, destination);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        public void Remove(ThemeEntry theme)
        {
            using (Lock()) {
                PackLibraryState state = Read();
                if (theme.Managed) { StoredPack pack = state.AllPacks().SingleOrDefault(p => p.Id == theme.LibraryId); if (pack == null) throw new IOException("Pack not found."); pack.Removed = true; }
                else if (!state.HiddenBundled.Contains(theme.Id)) state.HiddenBundled.Add(theme.Id);
                // Retain immutable artwork so existing previews and applied icons remain valid.
                Write(state);
            }
        }
        public void RestoreBundled() { using (Lock()) { PackLibraryState state = Read(); state.HiddenBundled.Clear(); Write(state); } }
    }
}
