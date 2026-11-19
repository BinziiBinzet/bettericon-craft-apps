using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Text;
using BetterIcon.Tray;

static class SvgTests
{
    const string Artwork = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 50\"><defs><linearGradient id=\"g\"><stop stop-color=\"#ff0000\"/><stop offset=\"1\" stop-color=\"#0000ff\"/></linearGradient><clipPath id=\"c\"><rect width=\"100\" height=\"50\" rx=\"10\"/></clipPath></defs><style>.art{fill:url(#g)}</style><g clip-path=\"url(#c)\"><path class=\"art\" d=\"M0 0H100V50H0Z\"/></g></svg>";
    static bool Rejects(Action action) { try { action(); return false; } catch (Exception) { return true; } }
    static byte[] Bytes(string svg) { return Encoding.UTF8.GetBytes(svg); }
    public static void Run(string root, string source, Action<bool, string> check)
    {
        string state = Path.Combine(root, "svg-tests-state"); Directory.CreateDirectory(state);
        PackLibrary library = new PackLibrary(Path.Combine(state, "packs"));
        byte[] original = Bytes(Artwork);
        string svg = Path.Combine(state, "arbitrary artwork.SVG"); File.WriteAllBytes(svg, original);
        using (Bitmap bitmap = SvgArtwork.Render(original, 512)) {
            Color left = bitmap.GetPixel(64, 256), right = bitmap.GetPixel(448, 256);
            check(bitmap.Size == new Size(512, 512) && bitmap.GetPixel(256, 10).A == 0 && bitmap.GetPixel(1, 129).A == 0 && left.R > left.B && right.B > right.R,
                "SVG rendering preserves viewBox aspect, transparency, paths, CSS, gradients and clipping at the requested size");
        }
        string clipped = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\"><defs><clipPath id=\"edge\"><path d=\"M 4 84 L 51 9 L 96 84 Z\"/></clipPath></defs><rect width=\"100\" height=\"100\" fill=\"#51d0e6\" clip-path=\"url(#edge)\"/></svg>";
        foreach (int size in new[] { 32, 128 }) {
            using (Bitmap bitmap = SvgArtwork.Render(Bytes(clipped), size)) {
                int partial = 0;
                for (int y = 0; y < size; y++)
                    for (int x = 0; x < size; x++) {
                        byte alpha = bitmap.GetPixel(x, y).A;
                        if (alpha > 0 && alpha < 255) partial++;
                    }
                check(partial > size / 2 && bitmap.GetPixel(size / 2, size / 2).A == 255 && bitmap.GetPixel(0, 0).A == 0,
                    "Clipped SVG artwork has smooth transparent edges at " + size + " pixels");
            }
        }
        string vector = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 32 32\"><rect x=\"15.5\" width=\"0.5\" height=\"32\" fill=\"#00ff00\"/></svg>";
        using (Bitmap bitmap = SvgArtwork.Render(Bytes(vector), 512))
            check(bitmap.GetPixel(251, 256).G == 255 && bitmap.GetPixel(251, 256).A > 240 && bitmap.GetPixel(244, 256).A == 0,
                "Large SVG previews rasterize fresh vector detail instead of enlarging a small thumbnail");
        string dtd = "<!DOCTYPE svg SYSTEM \"http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd\">" + Artwork;
        using (Bitmap bitmap = SvgArtwork.Render(Bytes(dtd), 32)) check(bitmap.Width == 32, "A harmless Illustrator-style doctype works without resolving its external DTD");
        using (Bitmap raster = new Bitmap(2, 2)) using (MemoryStream pngBytes = new MemoryStream()) {
            using (Graphics graphics = Graphics.FromImage(raster)) graphics.Clear(Color.Lime);
            raster.Save(pngBytes, System.Drawing.Imaging.ImageFormat.Png);
            string embedded = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 32 32\"><image width=\"32\" height=\"32\" href=\"data:image/png;base64," + Convert.ToBase64String(pngBytes.ToArray()) + "\"/></svg>";
            using (Bitmap bitmap = SvgArtwork.Render(Bytes(embedded), 64)) check(bitmap.GetPixel(32, 32).G == 255 && bitmap.GetPixel(32, 32).A == 255, "Self-contained SVGs can include embedded PNG artwork without outside file access");
        }
        ThemeEntry saved = library.Save("SVG custom", new Dictionary<string, string> { { "PhotoCraft", svg } }, null, "OmegaDarling");
        check(saved.Icons.Single().Path.EndsWith("PhotoCraft.svg") && File.ReadAllBytes(saved.Icons.Single().Path).SequenceEqual(original) && library.VisibleThemes(new ThemeEntry[0]).Single().Id == saved.Id,
            "Custom SVG assignments retain original vector bytes and reopen from the personal library");
        ThemeEntry replaced = library.ReplaceAppIcon(saved, "FilmCraft", svg);
        check(replaced.LibraryId == saved.LibraryId && replaced.IconCount == 2 && replaced.Icons.All(icon => icon.Path.EndsWith(".svg")),
            "Per-app SVG edits retain the personal pack identity and its other artwork");
        string mixed = Path.Combine(state, "Mixed formats"); Directory.CreateDirectory(mixed);
        string png = Path.Combine(mixed, "PhotoCraft.png"), ico = Path.Combine(mixed, "PhotoCraft.ico");
        using (Bitmap bitmap = new Bitmap(32, 32)) bitmap.Save(png, System.Drawing.Imaging.ImageFormat.Png);
        File.Copy(png, Path.Combine(mixed, "PhotoCraft alternate.png"));
        using (FileStream output = File.Create(ico)) SystemIcons.Application.Save(output);
        File.WriteAllBytes(Path.Combine(mixed, "PhotoCraft.svg"), original);
        ThemeEntry imported = library.Import(mixed);
        check(imported.IconCount == 1 && imported.Icons.Single().Path.EndsWith(".svg") && File.ReadAllBytes(imported.Icons.Single().Path).SequenceEqual(original),
            "Folder import prefers SVG over ICO and duplicate lower-priority PNG variants");
        int number = 0;
        foreach (bool svgFirst in new[] { false, true }) {
            string zipPath = Path.Combine(state, "Order " + (++number) + ".zip");
            using (ZipArchive zip = ZipFile.Open(zipPath, ZipArchiveMode.Create)) {
                string[] files = { png, ico, Path.Combine(mixed, "PhotoCraft.svg") };
                foreach (string file in svgFirst ? files.Reverse() : files) ZipFileExtensions.CreateEntryFromFile(zip, file, "Theme/" + Path.GetFileName(file));
            }
            check(library.Import(zipPath).Icons.Single().Path.EndsWith(".svg"), "ZIP import prefers SVG regardless of entry order " + number);
        }
        string manifest = Path.Combine(library.Root, "library.json"); byte[] baseline = File.ReadAllBytes(manifest);
        File.WriteAllBytes(Path.Combine(mixed, "PhotoCraft alternate.svg"), original);
        check(Rejects(() => library.Import(mixed)) && File.ReadAllBytes(manifest).SequenceEqual(baseline), "Multiple matching SVG variants remain ambiguous without publishing a pack");
        foreach (string invalid in new[] {
            "not XML", "<svg xmlns=\"http://www.w3.org/2000/svg\"", "<html/>",
            "<!DOCTYPE svg [<!ENTITY secret SYSTEM \"file:///C:/Windows/win.ini\">]><svg xmlns=\"http://www.w3.org/2000/svg\">&secret;</svg>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><image href=\"file:///C:/Windows/test.png\"/></svg>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><image href=\"https://example.invalid/image.png\"/></svg>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>@import url(https://example.invalid/style.css);</style></svg>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>"
        }) {
            string path = Path.Combine(state, "invalid.svg"); File.WriteAllText(path, invalid);
            check(Rejects(() => library.Save("Invalid vector", new Dictionary<string, string> { { "PhotoCraft", path } }, null)) && File.ReadAllBytes(manifest).SequenceEqual(baseline),
                "Invalid or externally linked SVG is rejected before library mutation " + (++number));
        }
        string shared = Path.Combine(state, "Shared vectors.zip"); library.Export(replaced, shared);
        PackLibrary recipient = new PackLibrary(Path.Combine(state, "recipient"));
        ThemeEntry received = recipient.Import(shared);
        check(received.Author == "OmegaDarling" && received.IconCount == 2 && received.Icons.All(icon => File.ReadAllBytes(icon.Path).SequenceEqual(original)),
            "Export and reimport share exact original SVG files and author metadata");
        using (ZipArchive zip = ZipFile.OpenRead(shared)) check(zip.Entries.Count == 3 && zip.GetEntry("PhotoCraft.svg") != null && zip.GetEntry("FilmCraft.svg") != null,
            "Shared SVG ZIPs contain portable vectors rather than flattened previews");
        MethodInfo thumbnail = typeof(LauncherForm).GetMethod("Thumbnail", BindingFlags.NonPublic | BindingFlags.Static);
        using (Bitmap bitmap = (Bitmap)thumbnail.Invoke(null, new object[] { svg, SystemIcons.Application, 512, 0 }))
            check(bitmap.Width == 512 && bitmap.GetPixel(64, 256).R > bitmap.GetPixel(64, 256).B && bitmap.GetPixel(256, 10).A == 0,
                "The actual launcher thumbnail path decodes SVG artwork at the requested zoom");
        object description = typeof(LauncherForm).GetMethod("DescribeArtwork", BindingFlags.NonPublic | BindingFlags.Static).Invoke(null, new object[] { svg, 0 });
        check((int)description.GetType().GetField("MaximumSize").GetValue(description) == Preferences.MaximumIconSize,
            "Vector artwork enables the existing 4096-pixel zoom range instead of imposing a raster source limit");
        string links = Path.Combine(state, "links"); Directory.CreateDirectory(links);
        string link = Path.Combine(links, "PhotoCraft.lnk"); File.Copy(Path.Combine(root, "PhotoCraft.lnk"), link); byte[] originalLink = File.ReadAllBytes(link);
        WorkerClient worker = new WorkerClient(source, new FixtureConfig { ShortcutDirectory = new[] { links }, StateDirectory = state });
        WorkerReply preview = worker.Run(new WorkerRequest { Action = "Preview", Theme = replaced.Id, Scope = "CurrentUser" }, false).GetAwaiter().GetResult();
        check(preview.Plan.Length == 1 && preview.Plan[0].Icon.EndsWith(".svg"), "The native Windows worker resolves an SVG-only personal pack for reviewed application");
        WorkerReply applied = worker.Run(new WorkerRequest { Action = "Apply", Theme = replaced.Id, Scope = "CurrentUser", ExpectedPlan = preview.Plan }, false).GetAwaiter().GetResult();
        WorkerReply catalog = worker.Run(new WorkerRequest { Action = "Catalog" }, false).GetAwaiter().GetResult();
        string iconPath = catalog.Catalog.Apps.Single().IconPath;
        using (BinaryReader reader = new BinaryReader(File.OpenRead(iconPath))) {
            bool frames = reader.ReadUInt16() == 0 && reader.ReadUInt16() == 1 && reader.ReadUInt16() == 7;
            foreach (int size in new[] { 16, 24, 32, 48, 64, 128, 256 }) { int dimension = reader.ReadByte(); reader.ReadBytes(15); frames &= (dimension == 0 ? 256 : dimension) == size; }
            check(applied.Results.Single().Status == "Applied" && frames, "SVG artwork converts into all seven native ICO frames when applying a disposable Windows shortcut (" + String.Join("; ", applied.Results.Select(result => result.Status + ": " + result.Message)) + ")");
        }
        WorkerReply restorePreview = worker.Run(new WorkerRequest { Action = "RestorePreview", Scope = "CurrentUser" }, false).GetAwaiter().GetResult();
        WorkerReply restored = worker.Run(new WorkerRequest { Action = "Restore", Scope = "CurrentUser", ExpectedStateHash = restorePreview.StateHash }, false).GetAwaiter().GetResult();
        check(restored.Results.Single().Status == "Restored" && File.ReadAllBytes(link).SequenceEqual(originalLink), "An SVG-applied shortcut restores byte-for-byte through the existing backup flow");
        IconRenderingTests.Run(check);
    }
}
