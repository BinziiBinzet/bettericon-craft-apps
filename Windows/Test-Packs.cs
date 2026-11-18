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
        check(omega.Length == 7 && omega.All(t => t.Author == "OmegaDarling" && t.ToString().Contains("OmegaDarling") && t.Id.StartsWith("Craft-Icons-Zach/")), "OmegaDarling credits are public while existing pack IDs stay stable");
        check(catalog.Themes.Length == 13 && catalog.Themes.Sum(t => t.IconCount) == 218 && !catalog.Themes.Any(t => t.Name == "OilSlick"), "Oil Slick is retired from the 13-theme, 218-icon catalog");
        check(catalog.Themes.SelectMany(t => t.Icons).All(icon => !String.IsNullOrEmpty(icon.PreviewPath) && Path.GetExtension(icon.PreviewPath).Equals(".png", StringComparison.OrdinalIgnoreCase) && File.Exists(icon.PreviewPath))
            && catalog.Themes.All(theme => { using (Image image = Image.FromFile(theme.Icons[0].PreviewPath)) return Math.Max(image.Width, image.Height) > 256; }),
            "The catalog retains original high-resolution PNG previews alongside native shortcut artwork");
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
        SvgTests.Run(root, source, check);
    }
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
