using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;
using BetterIcon.Tray;

static class PackTests
{
    static bool Rejects(Action action) { try { action(); return false; } catch (Exception) { return true; } }
    public static void Run(string root, string source, Catalog catalog, Action<bool, string> check)
    {
        string state = Path.Combine(root, "pack-tests-state"); Directory.CreateDirectory(state);
        PackLibrary library = new PackLibrary(Path.Combine(state, "packs"));
        ThemeEntry[] omega = catalog.Themes.Where(t => t.Pack == "Craft-Icons-Zach").ToArray();
        check(omega.Length == 9 && omega.All(t => t.Author == "OmegaDarling" && t.ToString().Contains("OmegaDarling") && t.Id.StartsWith("Craft-Icons-Zach/")), "OmegaDarling credits are public while existing pack IDs stay stable");
        check(catalog.Themes.Length == 32 && catalog.Themes.Sum(t => t.IconCount) == 382 && !catalog.Themes.Any(t => t.Name == "OilSlick"), "Nine OmegaDarling packs are present in the 32-theme catalog with 382 app icons");
        ThemeEntry[] komplett = catalog.Themes.Where(t => t.Pack == "Craft-Icons-Komplett").ToArray(), mike = catalog.Themes.Where(t => t.Pack == "Craft-Icons-Mike22").ToArray();
        check(komplett.Length == 5 && komplett.All(t => t.IconCount == 0 && t.Icons.Length == 0 && t.FileIconCount == 14 && t.AppFileIcons.Count == 14 && t.AppFileIcons.Values.All(File.Exists)),
            "Komplett's document artwork is file type artwork for the apps it draws");
        check(mike.Length == 3 && mike.All(t => t.IconCount == 15 && t.AppFileIcons.Count == 14 && t.AppFileIcons.ContainsKey("PhotoCraft") && t.AppFileIcons.Values.All(File.Exists))
            && catalog.Themes.Count(t => t.HasFileIcons) == 8 && catalog.Themes.Sum(t => t.FileIconCount) == 112,
            "A pack can carry app icons and file type artwork together");
        FileArtwork documents = ProjectFormat.Artwork(komplett[0]);
        check(documents.Tiles().Count == 14 && documents.Expanded().ContainsKey(".pdf") && documents.Expanded().ContainsKey(".docx") && documents.Expanded().ContainsKey(".pcraft") && !documents.Formats.Any(),
            "Artwork drawn per app covers each file type that app opens");
        check(catalog.Themes.SelectMany(t => t.Icons).All(icon => !String.IsNullOrEmpty(icon.PreviewPath) && File.Exists(icon.PreviewPath)
                && new[] { ".png", ".svg", ".webp" }.Contains(Path.GetExtension(icon.PreviewPath), StringComparer.OrdinalIgnoreCase))
            && catalog.Themes.Where(theme => theme.Icons.Length > 0).All(theme => {
                string path = theme.Icons[0].PreviewPath;
                if (Path.GetExtension(path).Equals(".svg", StringComparison.OrdinalIgnoreCase)) {
                    using (Bitmap image = SvgArtwork.Render(File.ReadAllBytes(path), 128)) return image.Width == 128 && image.Height == 128;
                }
                // A WebP preview is the artwork itself; its header gives its size.
                if (Path.GetExtension(path).Equals(".webp", StringComparison.OrdinalIgnoreCase)) return WebpArtwork.Side(path) >= 120;
                using (Image image = Image.FromFile(path)) return Math.Max(image.Width, image.Height) >= 120;
            }),
            "The catalog retains source-sized PNG or renderable SVG previews alongside shortcut artwork");
        check(library.VisibleThemes(catalog.Themes).Length == catalog.Themes.Length, "An empty personal library preserves all bundled packs");
        string input = Path.Combine(state, "Imported sample"); Directory.CreateDirectory(input);
        string png = Path.Combine(input, "PhotoCraft.png");
        using (Bitmap bitmap = new Bitmap(32, 32)) { using (Graphics g = Graphics.FromImage(bitmap)) g.Clear(Color.CornflowerBlue); bitmap.Save(png, ImageFormat.Png); }
        byte[] originalPng = File.ReadAllBytes(png);
        ThemeEntry created = library.Save("My mix", new Dictionary<string, string> { { "PhotoCraft", png } }, null);
        string oldIcon = created.Icons[0].Path;
        check(created.Managed && created.IconCount == 1 && created.Id.StartsWith("User/") && oldIcon != png && File.ReadAllBytes(oldIcon).SequenceEqual(originalPng), "Creating a custom pack copies its chosen artwork into the personal library");
        check(new PackLibrary(library.Root).VisibleThemes(catalog.Themes).Any(t => t.Id == created.Id && t.Name == "My mix"), "Custom pack metadata survives reopening the library");
        WorkerClient worker = new WorkerClient(source, new FixtureConfig { ShortcutDirectory = new[] { root }, StateDirectory = state });
        byte[] originalShortcut = File.ReadAllBytes(Path.Combine(root, "PhotoCraft.lnk"));
        WorkerReply preview = worker.Run(new WorkerRequest { Action = "Preview", Scope = "CurrentUser", Theme = created.Id }, false).GetAwaiter().GetResult();
        WorkerReply legacyName = worker.Run(new WorkerRequest { Action = "Preview", Scope = "CurrentUser", Theme = "Craft-Icons-Zach/HyGel" }, false).GetAwaiter().GetResult();
        WorkerReply publicName = worker.Run(new WorkerRequest { Action = "Preview", Scope = "CurrentUser", Theme = "Craft-Icons-OmegaDarling/HyGel" }, false).GetAwaiter().GetResult();
        check(legacyName.Plan.Length == 1 && publicName.Plan.Length == 1 && legacyName.Plan[0].Icon == publicName.Plan[0].Icon && legacyName.Plan[0].Status == publicName.Plan[0].Status,
            "The public OmegaDarling folder name and saved legacy IDs resolve to the same artwork");
        check(preview.Plan.Length == 1 && preview.Plan[0].Status == "Ready" && preview.Plan[0].Icon == oldIcon, "The native worker previews a personal pack through the existing installer");
        using (Bitmap bitmap = new Bitmap(32, 32)) { using (Graphics g = Graphics.FromImage(bitmap)) g.Clear(Color.Coral); bitmap.Save(png, ImageFormat.Png); }
        ThemeEntry edited = library.Save("My edited mix", new Dictionary<string, string> { { "PhotoCraft", png } }, created.LibraryId);
        check(edited.LibraryId == created.LibraryId && edited.Id != created.Id && File.ReadAllBytes(oldIcon).SequenceEqual(originalPng), "Editing creates an immutable revision without changing previously reviewed artwork");
        WorkerReply applied = worker.Run(new WorkerRequest { Action = "Apply", Scope = "CurrentUser", Theme = created.Id, ExpectedPlan = preview.Plan }, false).GetAwaiter().GetResult();
        check(applied.Results.Length == 1 && applied.Results[0].Status == "Applied", "A reviewed personal pack still applies after its library entry is edited");
        string installedIcon = BetterIcon.Windows.ShellLink.Read(Path.Combine(root, "PhotoCraft.lnk")).IconPath;
        library.Remove(edited);
        check(!library.VisibleThemes(catalog.Themes).Any(t => t.Managed) && File.Exists(installedIcon) && File.Exists(oldIcon), "Removing a personal pack leaves applied icons and reviewed artwork intact");
        WorkerReply restore = worker.Run(new WorkerRequest { Action = "RestorePreview", Scope = "CurrentUser" }, false).GetAwaiter().GetResult();
        worker.Run(new WorkerRequest { Action = "Restore", Scope = "CurrentUser", ExpectedStateHash = restore.StateHash }, false).GetAwaiter().GetResult();
        check(File.ReadAllBytes(Path.Combine(root, "PhotoCraft.lnk")).SequenceEqual(originalShortcut), "Original shortcuts restore exactly after the custom pack is removed");
        ThemeEntry bundled = catalog.Themes[0]; byte[] bundleBytes = File.ReadAllBytes(bundled.Icons[0].Path);
        library.Remove(bundled);
        check(!library.VisibleThemes(catalog.Themes).Any(t => t.Id == bundled.Id) && File.ReadAllBytes(bundled.Icons[0].Path).SequenceEqual(bundleBytes), "Removing a bundled pack hides it without touching repository artwork");
        library.RestoreBundled(); check(library.VisibleThemes(catalog.Themes).Length == catalog.Themes.Length, "Restore built-in packs makes hidden bundled packs available again");
        ThemeEntry imported = library.Import(input);
        check(imported.IconCount == 1 && File.Exists(imported.Icons[0].Path), "Folder import recognizes app-named PNG artwork");
        string zipPath = Path.Combine(state, "ZIP sample.zip");
        using (ZipArchive zip = ZipFile.Open(zipPath, ZipArchiveMode.Create)) ZipFileExtensions.CreateEntryFromFile(zip, png, "One theme/PhotoCraft.png");
        ThemeEntry zipped = library.Import(zipPath);
        check(zipped.IconCount == 1 && zipped.Name == "ZIP sample", "ZIP import copies recognized artwork without extracting archive paths");
        string manifest = Path.Combine(library.Root, "library.json"); byte[] beforeInvalid = File.ReadAllBytes(manifest);
        check(Rejects(() => library.Import(zipPath)) && File.ReadAllBytes(manifest).SequenceEqual(beforeInvalid), "Duplicate personal names fail without changing the library");
        File.Copy(png, Path.Combine(input, "PhotoCraft alternate.png"));
        check(Rejects(() => library.Import(input)), "Ambiguous imports reject multiple variants for the same app");
        string unsafeZip = Path.Combine(state, "Unsafe.zip");
        using (ZipArchive zip = ZipFile.Open(unsafeZip, ZipArchiveMode.Create)) ZipFileExtensions.CreateEntryFromFile(zip, png, "../PhotoCraft.png");
        check(Rejects(() => library.Import(unsafeZip)) && File.ReadAllBytes(manifest).SequenceEqual(beforeInvalid), "Traversal entries in a ZIP are rejected without publishing a pack");
        string invalid = Path.Combine(state, "invalid.png"); File.WriteAllText(invalid, "This is not an image.");
        check(Rejects(() => library.Save("Invalid", new Dictionary<string, string> { { "PhotoCraft", invalid } }, null)) && File.ReadAllBytes(manifest).SequenceEqual(beforeInvalid), "Invalid images cannot leave a partially published pack");
        check(Rejects(() => library.Save("Empty", new Dictionary<string, string>(), null)), "Custom packs require at least one assigned icon");
        check(Rejects(() => library.Save("Invalid app", new Dictionary<string, string> { { "../escape", png } }, null)), "Custom mappings reject unsupported app identifiers");
        check(Rejects(() => library.Save("Removed", new Dictionary<string, string> { { "PhotoCraft", png } }, edited.LibraryId)), "An editor cannot overwrite a pack removed since it opened");
        byte[] oversized = (byte[])originalPng.Clone(); oversized[16] = 0; oversized[17] = 0; oversized[18] = 16; oversized[19] = 1; File.WriteAllBytes(invalid, oversized);
        check(Rejects(() => library.Save("Oversized", new Dictionary<string, string> { { "PhotoCraft", invalid } }, null)), "Oversized PNG dimensions are rejected before decoding");
        Sharing(state, png, catalog.Themes[0], check);
        // Keep this link outside root so the main launcher fixtures remain unchanged.
        string launcherLinks = Path.Combine(Path.GetDirectoryName(root), "bettericon-launcher-pack-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(launcherLinks);
        string launcherPath = Path.Combine(launcherLinks, "ArtCraft Launcher.lnk");
        File.Copy(Path.Combine(root, "PhotoCraft.lnk"), launcherPath);
        byte[] launcherOriginal = File.ReadAllBytes(launcherPath);
        ThemeEntry launcherPack = library.Save("Launcher custom", new Dictionary<string, string> { { "ArtCraftLauncher", png } }, null);
        check(launcherPack.Icons.Single().Application == "ArtCraftLauncher", "Personal packs accept ArtCraft Launcher artwork");
        WorkerClient launcherWorker = new WorkerClient(source, new FixtureConfig { ShortcutDirectory = new[] { launcherLinks }, StateDirectory = state });
        WorkerReply launcherCatalog = launcherWorker.Run(new WorkerRequest { Action = "Catalog" }, false).GetAwaiter().GetResult();
        AppEntry launcher = launcherCatalog.Catalog.Apps.Single();
        check(launcher.Application == "ArtCraftLauncher" && launcher.UsingDefaultIcon && launcher.CanRestoreDefault && !launcher.RestoreAvailable && !String.IsNullOrEmpty(launcher.IconPath), "The native worker resolves a launcher's implicit default without claiming a backup");
        WorkerReply launcherPlan = launcherWorker.Run(new WorkerRequest { Action = "Preview", Theme = launcherPack.Id, Scope = "CurrentUser" }, false).GetAwaiter().GetResult();
        WorkerReply launcherApply = launcherWorker.Run(new WorkerRequest { Action = "Apply", Theme = launcherPack.Id, Scope = "CurrentUser", ExpectedPlan = launcherPlan.Plan }, false).GetAwaiter().GetResult();
        check(launcherApply.Results.Length == 1 && launcherApply.Results[0].Status == "Applied", "A personal launcher icon applies through the native worker with a recoverable backup");
        WorkerReply launcherPreview = launcherWorker.Run(new WorkerRequest { Action = "RestorePreview", Application = "ArtCraftLauncher", Scope = "CurrentUser" }, false).GetAwaiter().GetResult();
        WorkerReply launcherRestore = launcherWorker.Run(new WorkerRequest { Action = "Restore", Application = "ArtCraftLauncher", Scope = "CurrentUser", ExpectedStateHash = launcherPreview.StateHash }, false).GetAwaiter().GetResult();
        check(launcherPreview.Results.Length == 1 && launcherRestore.Results.Single().Status == "Restored" && File.ReadAllBytes(launcherPath).SequenceEqual(launcherOriginal), "ArtCraft Launcher restores byte-for-byte through the reviewed native worker path");
        string launcherImport = Path.Combine(state, "Launcher import"); Directory.CreateDirectory(launcherImport); File.Copy(png, Path.Combine(launcherImport, "ArtCraft Launcher.png"));
        check(library.Import(launcherImport).Icons.Single().Application == "ArtCraftLauncher", "Launcher artwork imports with its spaced official app name");
        WebP(state, png, check);
        ZipLimits(state, check);
        SvgTests.Run(root, source, check);
    }
    // A ZIP import holds only the artwork it keeps, and counts the bytes its entries really inflate to, whatever sizes
    // they claim: .NET Framework does not hold an entry to its claimed size.
    static void ZipLimits(string state, Action<bool, string> check)
    {
        PackLibrary library = new PackLibrary(Path.Combine(state, "zip-limits"));
        string manifest = Path.Combine(library.Root, "library.json");
        // An SVG beside a PNG of the same icon whose compressed data is damaged: the SVG is kept, so the PNG is never read.
        string lazy = Path.Combine(state, "Lazy ZIP.zip");
        using (ZipArchive archive = ZipFile.Open(lazy, ZipArchiveMode.Create)) {
            byte[] svg = Encoding.UTF8.GetBytes("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 32 32\"><rect width=\"32\" height=\"32\" fill=\"#22aa77\"/></svg>");
            using (Stream entry = archive.CreateEntry("Theme/PhotoCraft.svg").Open()) entry.Write(svg, 0, svg.Length);
            byte[] png = new byte[64 * 1024];
            using (Stream entry = archive.CreateEntry("Theme/PhotoCraft.png").Open()) entry.Write(png, 0, png.Length);
        }
        ZipPatch(lazy, "Theme/PhotoCraft.png", -1, true);
        ThemeEntry kept = null;
        try { kept = library.Import(lazy); } catch (Exception error) { Console.WriteLine("  The import failed: " + error.Message); }
        check(kept != null && kept.IconCount == 1 && Path.GetExtension(kept.Icons[0].Path) == ".svg",
            "A ZIP import reads only the artwork it keeps: a damaged PNG beside an SVG of the same icon is never read");

        // Nine PNG entries that each claim 7 bytes and inflate to 16 MiB less one: 144 MiB in all, more than a pack may hold.
        string lying = Path.Combine(state, "Lying ZIP.zip");
        string[] apps = { "PhotoCraft", "VectorCraft", "FilmCraft", "LightCraft", "PdfCraft", "EffectCraft", "AniCraft", "DesignCraft", "FigCraft" };
        byte[] filler = new byte[16 * 1024 * 1024 - 1];
        using (ZipArchive archive = ZipFile.Open(lying, ZipArchiveMode.Create))
            foreach (string app in apps) using (Stream entry = archive.CreateEntry("Theme/" + app + ".png", CompressionLevel.Fastest).Open()) entry.Write(filler, 0, filler.Length);
        filler = null;
        ZipPatch(lying, null, 7, false);
        byte[] before = File.Exists(manifest) ? File.ReadAllBytes(manifest) : null;
        string message = null;
        try { library.Import(lying); } catch (IOException error) { message = error.Message; }
        check(message == "Import a single theme ZIP smaller than 128 MB when expanded." && (before == null ? !File.Exists(manifest) : File.ReadAllBytes(manifest).SequenceEqual(before)),
            "A ZIP whose entries claim less than they hold stops once 128 MB has been read, and the library is unchanged");
        GC.Collect();
    }
    // Rewrites a ZIP file in place: the uncompressed size each entry claims (claim >= 0), or the compressed data of one
    // entry, filled with bytes no deflate stream starts with (damage).
    static void ZipPatch(string path, string name, long claim, bool damage)
    {
        byte[] zip = File.ReadAllBytes(path);
        int end = zip.Length - 22;
        while (end >= 0 && BitConverter.ToUInt32(zip, end) != 0x06054b50) end--;
        if (end < 0) throw new InvalidDataException("No end of central directory.");
        int count = BitConverter.ToUInt16(zip, end + 10), at = (int)BitConverter.ToUInt32(zip, end + 16);
        for (int i = 0; i < count; i++) {
            if (BitConverter.ToUInt32(zip, at) != 0x02014b50) throw new InvalidDataException("No central directory header.");
            int nameLength = BitConverter.ToUInt16(zip, at + 28), extra = BitConverter.ToUInt16(zip, at + 30), comment = BitConverter.ToUInt16(zip, at + 32);
            string entry = Encoding.UTF8.GetString(zip, at + 46, nameLength);
            int local = (int)BitConverter.ToUInt32(zip, at + 42), compressed = (int)BitConverter.ToUInt32(zip, at + 20);
            if (claim >= 0) {
                BitConverter.GetBytes((uint)claim).CopyTo(zip, at + 24);
                BitConverter.GetBytes((uint)claim).CopyTo(zip, local + 22);
            }
            if (damage && entry == name) {
                int data = local + 30 + BitConverter.ToUInt16(zip, local + 26) + BitConverter.ToUInt16(zip, local + 28);
                for (int j = 0; j < compressed; j++) zip[data + j] = 0xFF;
            }
            at += 46 + nameLength + extra + comment;
        }
        File.WriteAllBytes(path, zip);
    }
    // A 32 pixel square: transparent edges around an opaque red center, stored lossy and lossless. Then two frames.
    const string LossyWebP = "UklGRoYAAABXRUJQVlA4WAoAAAAQAAAAHwAAHwAAQUxQSBQAAAABUNq2AZP/nw4sHCwiJoAZGv+td1ZQOCBMAAAA0AMAnQEqIAAgAADAEiWgAgAvwH4AfsB/gDK+UsIF+KQ22wf7OtcAAP7+ex//8gr//H8n//jjOf//azf//7eqPCwi1MICOKos6fgAAA==";
    const string LosslessWebP = "UklGRioAAABXRUJQVlA4TB0AAAAvH8AHEA8wPMM9KPMf8BDTEPqXdpsCEf2fAHq95QA=";
    const string AnimatedWebP = "UklGRogAAABXRUJQVlA4WAoAAAACAAAADwAADwAAQU5JTQYAAAAAAAAAAABBTk1GKgAAAAAAAAAAAA8AAA8AAGQAAAJWUDhMEQAAAC8PwAMAB1Cechel/4GI6H8AAEFOTUYqAAAAAAAAAAAADwAADwAAZAAAAFZQOEwRAAAALw/AAwAHUK2ilLv/gYjofwAA";
    static readonly string[] WebPTitles = {
        "WebP artwork is kept as PNG with its transparency, for apps and for file types", "A folder import prefers WebP over a PNG of the same icon",
        "Animated and mislabeled WebP files are refused without changing the library", "Lossy WebP with palette-coded alpha keeps its transparency",
        "A damaged WebP gives way to the PNG of the same icon in an import", "A damaged WebP alone stops the import and leaves the library unchanged",
        "A ZIP import prefers WebP", "FileTypes WebP wins over the PNG of the same format", "Oversized WebP is refused before decoding",
        "One-frame animated WebP is refused", "A WebP-imported pack exports PNG files only" };
    static void WebP(string state, string png, Action<bool, string> check)
    {
        // These need Windows' own WebP decoder, which this PC may lack (LTSC, Server, a removed Store package).
        if (!WebpArtwork.SystemDecoderAvailable) { foreach (string title in WebPTitles) Console.WriteLine("SKIP " + title + " (no system WebP decoder)"); return; }
        PackLibrary library = new PackLibrary(Path.Combine(state, "webp-packs"));
        string folder = Path.Combine(state, "webp"); Directory.CreateDirectory(folder);
        Func<string, string, string> write = (name, data) => { string path = Path.Combine(folder, name); File.WriteAllBytes(path, Convert.FromBase64String(data)); return path; };
        string lossy = write("lossy.webp", LossyWebP), lossless = write("lossless.webp", LosslessWebP), animated = write("animated.webp", AnimatedWebP);
        ThemeEntry saved = library.Save("WebP mix", new Dictionary<string, string> { { "PhotoCraft", lossy }, { "FilmCraft", lossless }, { ".pcraft", lossy } }, null);
        Func<string, bool> square = path => {
            using (Bitmap art = new Bitmap(path)) {
                Color center = art.GetPixel(16, 16);
                return art.Width == 32 && art.Height == 32 && art.GetPixel(1, 1).A == 0 && center.A == 255 && center.R > 200 && center.G < 90 && center.B < 70;
            }
        };
        check(saved.IconCount == 2 && saved.Icons.All(icon => Path.GetExtension(icon.Path) == ".png" && square(icon.Path))
            && saved.FileIcons.Count == 1 && Path.GetExtension(saved.FileIcons[".pcraft"]) == ".png" && square(saved.FileIcons[".pcraft"]),
            "WebP artwork is kept as PNG with its transparency, for apps and for file types");
        string import = Path.Combine(state, "WebP import"); Directory.CreateDirectory(Path.Combine(import, "FileTypes"));
        File.Copy(lossy, Path.Combine(import, "PhotoCraft.webp")); File.Copy(png, Path.Combine(import, "FilmCraft.png")); File.Copy(lossless, Path.Combine(import, "FilmCraft.webp"));
        File.Copy(lossless, Path.Combine(import, "FileTypes", "pcraft.webp"));
        ThemeEntry imported = library.Import(import);
        // WebP goes directly ahead of PNG: FilmCraft is now the red square from FilmCraft.webp.
        check(imported.IconCount == 2 && square(imported.Icons.Single(icon => icon.Application == "PhotoCraft").Path)
            && square(imported.Icons.Single(icon => icon.Application == "FilmCraft").Path) && square(imported.FileIcons[".pcraft"]),
            "A folder import prefers WebP over a PNG of the same icon");
        string manifest = Path.Combine(library.Root, "library.json"); byte[] before = File.ReadAllBytes(manifest);
        string message = null;
        try { library.Save("Moving", new Dictionary<string, string> { { "PhotoCraft", animated } }, null); } catch (IOException error) { message = error.Message; }
        string disguised = Path.Combine(folder, "disguised.webp"); File.Copy(png, disguised);
        check(message != null && message.Contains("Animated WebP") && Rejects(() => library.Save("Disguised", new Dictionary<string, string> { { "PhotoCraft", disguised } }, null))
            && File.ReadAllBytes(manifest).SequenceEqual(before), "Animated and mislabeled WebP files are refused without changing the library");

        // A17: a lossy ring whose alpha is palette-coded, which the previous decoder drew with 902 visible pixels.
        ThemeEntry ring = library.Save("Ring", new Dictionary<string, string> { { "PhotoCraft", write("ring.webp", A17) } }, null);
        int visible = 0;
        using (Bitmap art = new Bitmap(ring.Icons[0].Path)) for (int y = 0; y < art.Height; y++) for (int x = 0; x < art.Width; x++) if (art.GetPixel(x, y).A > 0) visible++;
        bool ringKept = Path.GetExtension(ring.Icons[0].Path) == ".png" && Math.Abs(visible - 5753) <= 58;
        if (!ringKept) Console.WriteLine("  The ring kept " + visible + " of 9216 pixels visible; 5753 +/- 58 expected.");
        check(ringKept, "Lossy WebP with palette-coded alpha keeps its transparency");

        string damagedTwin = Path.Combine(state, "WebP damaged twin"); Directory.CreateDirectory(damagedTwin);
        File.WriteAllBytes(Path.Combine(damagedTwin, "PhotoCraft.webp"), Convert.FromBase64String(A12)); File.Copy(png, Path.Combine(damagedTwin, "PhotoCraft.png"));
        ThemeEntry twin = library.Import(damagedTwin);
        check(twin.IconCount == 1 && File.ReadAllBytes(twin.Icons[0].Path).SequenceEqual(File.ReadAllBytes(png)), "A damaged WebP gives way to the PNG of the same icon in an import");

        string damagedAlone = Path.Combine(state, "WebP damaged alone"); Directory.CreateDirectory(damagedAlone);
        File.WriteAllBytes(Path.Combine(damagedAlone, "PhotoCraft.webp"), Convert.FromBase64String(A8));
        before = File.ReadAllBytes(manifest); message = null;
        try { library.Import(damagedAlone); } catch (IOException error) { message = error.Message; }
        check(message != null && message.StartsWith("PhotoCraft: " + WebpArtwork.Damaged) && File.ReadAllBytes(manifest).SequenceEqual(before),
            "A damaged WebP alone stops the import and leaves the library unchanged");

        string zip = Path.Combine(state, "WebP ZIP.zip");
        using (ZipArchive archive = ZipFile.Open(zip, ZipArchiveMode.Create)) {
            ZipFileExtensions.CreateEntryFromFile(archive, png, "Theme/PhotoCraft.png");
            ZipFileExtensions.CreateEntryFromFile(archive, lossless, "Theme/PhotoCraft.webp");
        }
        ThemeEntry zipped = library.Import(zip);
        check(zipped.IconCount == 1 && square(zipped.Icons[0].Path), "A ZIP import prefers WebP");

        string formats = Path.Combine(state, "WebP file types"); Directory.CreateDirectory(Path.Combine(formats, "FileTypes"));
        File.Copy(png, Path.Combine(formats, "FileTypes", "pcraft.png")); File.Copy(lossless, Path.Combine(formats, "FileTypes", "pcraft.webp"));
        ThemeEntry documents = library.Import(formats);
        check(documents.FileIcons.Count == 1 && square(documents.FileIcons[".pcraft"]), "FileTypes WebP wins over the PNG of the same format");

        before = File.ReadAllBytes(manifest); message = null;
        try { library.Save("Wide", new Dictionary<string, string> { { "PhotoCraft", write("wide.webp", A11) } }, null); } catch (IOException error) { message = error.Message; }
        check(message == WebpArtwork.TooLarge && File.ReadAllBytes(manifest).SequenceEqual(before), "Oversized WebP is refused before decoding");
        message = null;
        try { library.Save("One frame", new Dictionary<string, string> { { "PhotoCraft", write("one-frame.webp", A7) } }, null); } catch (IOException error) { message = error.Message; }
        check(message != null && message.StartsWith(WebpArtwork.Animated), "One-frame animated WebP is refused");

        string exported = Path.Combine(state, "WebP export.zip");
        library.Export(imported, exported);
        using (ZipArchive archive = ZipFile.OpenRead(exported)) {
            string[] names = archive.Entries.Select(entry => entry.FullName).Where(name => name != "bettericon-pack.json").ToArray();
            check(names.Length == 3 && names.All(name => name.EndsWith(".png", StringComparison.Ordinal)), "A WebP-imported pack exports PNG files only");
        }

        before = File.ReadAllBytes(manifest); message = null;
        Environment.SetEnvironmentVariable(WebpArtwork.DecoderSeam, "none");
        try { library.Save("No decoder", new Dictionary<string, string> { { "PhotoCraft", lossless } }, null); } catch (IOException error) { message = error.Message; }
        finally { Environment.SetEnvironmentVariable(WebpArtwork.DecoderSeam, null); }
        check(message == WebpArtwork.NoDecoder && File.ReadAllBytes(manifest).SequenceEqual(before), "Without a system WebP decoder, WebP import is refused with the WebP Image Extensions message");
    }
    // Appendix A of the WebP spec: A7 a one-frame animation, A8 truncated, A11 5000x4 pixels, A12 with its image data zeroed,
    // A17 a lossy 96x96 ring with palette-coded alpha.
    const string A7 = "UklGRlIAAABXRUJQVlA4WAoAAAASAAAAAAAAAAAAQU5JTQYAAAD/////AABBTk1GJgAAAAAAAAAAAAAAAAAAAGQAAABWUDhMDQAAAC8AAAAQBxAREYiI/gcA";
    const string A8 = "UklGRiwAAABXRUJQVlA4TB8AAAAvD8ADECDStpl/00eF5w==";
    const string A11 = "UklGRhgAAABXRUJQVlA4TAwAAAAvh9MAAChAAfrf/wA=";
    const string A12 = "UklGRioAAABXRUJQVlA4TB0AAAAvH8AHEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    internal const string A17 = "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";
    static void Sharing(string state, string png, ThemeEntry bundled, Action<bool, string> check)
    {
        PackLibrary sender = new PackLibrary(Path.Combine(state, "sender")), recipient = new PackLibrary(Path.Combine(state, "recipient"));
        string ico = Path.Combine(state, "arbitrary artwork.ico");
        using (FileStream output = File.Create(ico)) SystemIcons.Application.Save(output);
        var files = new Dictionary<string, string> { { "PhotoCraft", png }, { "FilmCraft", ico } };
        ThemeEntry pack = sender.Save("Studio \u03a9", files, null, "OmegaDarling");
        string destination = Path.Combine(state, "renamed shared pack.zip");
        sender.Export(pack, destination);
        byte[] exported = File.ReadAllBytes(destination);
        using (ZipArchive zip = ZipFile.OpenRead(destination)) {
            string[] names = zip.Entries.Select(e => e.FullName).OrderBy(n => n).ToArray();
            string metadata; using (StreamReader reader = new StreamReader(zip.GetEntry("bettericon-pack.json").Open(), Encoding.UTF8)) metadata = reader.ReadToEnd();
            var data = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(metadata);
            check(names.SequenceEqual(new[] { "bettericon-pack.json", "FilmCraft.ico", "PhotoCraft.png" }.OrderBy(n => n)) && data.Count == 4 && !metadata.Contains(state) && !metadata.Contains(pack.LibraryId), "Export contains only portable name/author metadata and canonical PNG/ICO artwork");
        }
        ThemeEntry imported = recipient.Import(destination);
        check(imported.Name == pack.Name && imported.Author == "OmegaDarling" && imported.Id != pack.Id && imported.IconCount == 2 && imported.ToString().Contains("OmegaDarling"), "Import on another library preserves Unicode name and author even when the ZIP was renamed");
        check(imported.Icons.All(i => File.ReadAllBytes(i.Path).SequenceEqual(File.ReadAllBytes(files[i.Application]))), "PNG and ICO artwork survives export/import byte-for-byte");
        check(new PackLibrary(recipient.Root).VisibleThemes(new ThemeEntry[0])[0].Author == "OmegaDarling", "Imported author survives reopening the app library");
        check(Rejects(() => sender.Export(pack, destination)) && File.ReadAllBytes(destination).SequenceEqual(exported), "Export refuses an existing ZIP without explicit overwrite");
        check(Rejects(() => sender.Export(bundled, Path.Combine(state, "builtin.zip"))) && !File.Exists(Path.Combine(state, "builtin.zip")), "Built-in packs must be customized before export");
        string extracted = Path.Combine(state, "renamed extracted folder"); ZipFile.ExtractToDirectory(destination, extracted);
        ThemeEntry folder = new PackLibrary(Path.Combine(state, "folder-recipient")).Import(extracted);
        check(folder.Name == pack.Name && folder.Author == pack.Author, "An extracted export imports with the same portable metadata");
        ThemeEntry edited = sender.Save("Studio revised", files, pack.LibraryId, "OmegaDarling and friends");
        check(Rejects(() => sender.Export(pack, destination, true)) && File.ReadAllBytes(destination).SequenceEqual(exported), "A stale selection cannot export a different revision or overwrite an existing ZIP");
        sender.Export(edited, destination, true);
        ThemeEntry updated = new PackLibrary(Path.Combine(state, "updated-recipient")).Import(destination);
        check(updated.Name == edited.Name && updated.Author == edited.Author, "Confirmed overwrite publishes a complete ZIP with edited name and author");
        byte[] complete = File.ReadAllBytes(destination); File.WriteAllText(edited.Icons[0].Path, "invalid image");
        check(Rejects(() => sender.Export(edited, destination, true)) && File.ReadAllBytes(destination).SequenceEqual(complete), "Failed export preserves a previous valid ZIP");
        string bad = Path.Combine(state, "bad description.zip");
        using (ZipArchive zip = ZipFile.Open(bad, ZipArchiveMode.Create)) {
            ZipFileExtensions.CreateEntryFromFile(zip, png, "PhotoCraft.png");
            using (StreamWriter writer = new StreamWriter(zip.CreateEntry("bettericon-pack.json").Open())) writer.Write("{\"Format\":\"BetterIcon.IconPack\",\"Version\":99,\"Name\":\"Bad\"}");
        }
        byte[] before = File.ReadAllBytes(Path.Combine(recipient.Root, "library.json"));
        check(Rejects(() => recipient.Import(bad)) && File.ReadAllBytes(Path.Combine(recipient.Root, "library.json")).SequenceEqual(before), "Unrecognized share metadata is rejected without changing the recipient library");
        string manifest = Path.Combine(recipient.Root, "library.json");
        File.WriteAllText(manifest, File.ReadAllText(manifest).Replace("\"Author\":\"OmegaDarling\",", ""));
        check(new PackLibrary(recipient.Root).VisibleThemes(new ThemeEntry[0]).Length == 1, "Existing personal libraries without author fields remain readable");
    }
}
