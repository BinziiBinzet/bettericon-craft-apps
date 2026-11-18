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
            }
            return state;
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
            foreach (string path in documents.Values) { RegularPath(path); if (!File.Exists(path)) throw new IOException("File artwork is missing from " + pack.Name + "."); }
            return new ThemeEntry { Id = "User/" + pack.Id + "/" + pack.Revision, LibraryId = pack.Id, Managed = true, Name = pack.Name, Author = pack.Author, Pack = "Personal", IconCount = icons.Length, Icons = icons, FileIcons = documents };
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
                if (!Applications.Contains(entry.Key) && !ProjectFormat.IsKey(entry.Key)) throw new ArgumentException("Unsupported icon target: " + entry.Key);
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
            if (basis != null && basis.FileIcons != null) foreach (var file in basis.FileIcons) files.Add(file.Key, file.Value);
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
            if (images.Count == 0) throw new ArgumentException("Choose artwork for at least one app or project file type.");
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
                    bool project = ProjectFormat.IsKey(image.Key);
                    string directory = project ? Path.Combine(folder, "FileTypes") : folder;
                    string file = (project ? image.Key.Substring(1) : image.Key) + extensions[image.Key];
                    Directory.CreateDirectory(directory);
                    File.WriteAllBytes(Path.Combine(directory, file), image.Value);
                    (project ? pack.FileIcons : pack.Icons).Add(image.Key, file);
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
                else throw new IOException("Choose SVG, PNG or ICO artwork.");
            }
        }
        static string AppForFile(string file)
        {
            string name = Path.GetFileNameWithoutExtension(file);
            string parent = Path.GetDirectoryName(file) ?? "";
            if (parent.Split('\\', '/').Contains("FileTypes", StringComparer.OrdinalIgnoreCase)) {
                string key = "." + name.TrimStart('.').ToLowerInvariant();
                return ProjectFormat.IsKey(key) ? key : null;
            }
            return Applications.FirstOrDefault(app => Regex.IsMatch(name, "^" + (app == "CraftAnything" ? "Craft[ _-]*Anything" : app == "ArtCraftLauncher" ? "ArtCraft[ _-]*Launcher" : Regex.Escape(app)) + "(?:[ _.-].*)?$", RegexOptions.IgnoreCase));
        }
        static int FormatPriority(string extension) { return extension == ".svg" ? 3 : extension == ".ico" ? 2 : extension == ".png" ? 1 : 0; }
        static void AddImage(Dictionary<string, byte[]> images, Dictionary<string, string> extensions, HashSet<string> ambiguous, string file, Func<byte[]> read)
        {
            string extension = Path.GetExtension(file).ToLowerInvariant(), app = AppForFile(file);
            if (app == null || FormatPriority(extension) == 0) return;
            if (images.ContainsKey(app)) {
                if (extensions[app] == extension) { ambiguous.Add(app); return; }
                if (FormatPriority(extensions[app]) > FormatPriority(extension)) return;
            }
            images[app] = read(); extensions[app] = extension; ambiguous.Remove(app);
        }
        public ThemeEntry Import(string source)
        {
            RegularPath(source);
            Dictionary<string, byte[]> images = new Dictionary<string, byte[]>();
            Dictionary<string, string> extensions = new Dictionary<string, string>();
            HashSet<string> ambiguous = new HashSet<string>();
            string name; SharedPackMetadata metadata = null;
            if (Directory.Exists(source)) {
                source = Path.GetFullPath(source);
                name = new DirectoryInfo(source).Name;
                Stack<string> pending = new Stack<string>(); pending.Push(source); int count = 0;
                while (pending.Count > 0) foreach (string path in Directory.EnumerateFileSystemEntries(pending.Pop())) {
                    if (++count > 1024) throw new IOException("Import a single theme folder with fewer than 1024 entries.");
                    RegularPath(path);
                    if (Directory.Exists(path)) pending.Push(path);
                    else if (Path.GetFileName(path).Equals(MetadataFile, StringComparison.OrdinalIgnoreCase)) {
                        if (metadata != null) throw new IOException("Several pack descriptions found. Import one theme at a time.");
                        using (Stream input = File.OpenRead(path)) metadata = ReadMetadata(ReadLimited(input, MaxMetadataBytes));
                    }
                    else AddImage(images, extensions, ambiguous, path.Substring(Path.GetFullPath(source).TrimEnd('\\', '/').Length + 1), delegate { if (new FileInfo(path).Length > MaxImageBytes) throw new IOException("An icon exceeds 16 MB."); return File.ReadAllBytes(path); });
                }
            }
            else {
                if (!Path.GetExtension(source).Equals(".zip", StringComparison.OrdinalIgnoreCase)) throw new IOException("Choose a theme folder or ZIP file.");
                name = Path.GetFileNameWithoutExtension(source);
                using (ZipArchive zip = ZipFile.OpenRead(source)) {
                    if (zip.Entries.Count > 1024 || zip.Entries.Sum(e => e.Length) > MaxPackBytes) throw new IOException("Import a single theme ZIP smaller than 128 MB when expanded.");
                    foreach (ZipArchiveEntry entry in zip.Entries) {
                        string path = entry.FullName.Replace('\\', '/');
                        if (path.StartsWith("/") || path.Contains(":") || path.Split('/').Any(p => p == ".." || p == ".") || ((entry.ExternalAttributes >> 16) & 0xf000) == 0xa000) throw new IOException("The ZIP contains an unsafe path or link.");
                        if (Path.GetFileName(path).Equals(MetadataFile, StringComparison.OrdinalIgnoreCase)) {
                            if (metadata != null) throw new IOException("Several pack descriptions found. Import one theme at a time.");
                            using (Stream input = entry.Open()) metadata = ReadMetadata(ReadLimited(input, MaxMetadataBytes));
                            continue;
                        }
                        AddImage(images, extensions, ambiguous, path, delegate {
                            if (entry.Length > MaxImageBytes) throw new IOException("An icon exceeds 16 MB.");
                            using (Stream input = entry.Open()) return ReadLimited(input, MaxImageBytes);
                        });
                    }
                }
            }
            if (ambiguous.Count != 0) throw new IOException("Several icons match " + ambiguous.OrderBy(app => app).First() + ". Import one theme at a time.");
            if (images.Count == 0) throw new IOException("No matching icons found. Use app names or put project artwork in FileTypes, such as FileTypes/pcraft.png.");
            return SaveBytes(metadata == null ? name : metadata.Name, images, extensions, null, metadata == null ? "" : metadata.Author);
        }
        static byte[] ReadLimited(Stream input, int limit)
        {
            using (MemoryStream output = new MemoryStream()) {
                byte[] buffer = new byte[8192]; int read;
                while ((read = input.Read(buffer, 0, buffer.Length)) != 0) { if (output.Length + read > limit) throw new IOException("A pack file exceeds its size limit."); output.Write(buffer, 0, read); }
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
            foreach (var icon in theme.FileIcons) {
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
