using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.IO.Compression;
using System.Linq;
using BetterIcon.Tray;

static class PackTests
{
    static bool Rejects(Action action) { try { action(); return false; } catch (Exception) { return true; } }
    public static void Run(string root, string source, Catalog catalog, Action<bool, string> check)
    {
        string state = Path.Combine(root, "pack-tests-state"); Directory.CreateDirectory(state);
        PackLibrary library = new PackLibrary(Path.Combine(state, "packs"));
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
    }
}
