using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
using BetterIcon.Tray;

static partial class PackEditionTests
{
    // The probe sends native row messages directly. Ignore queued physical mouse
    // messages for this disposable list so it can run without moving the user's mouse.
    sealed class FixturePointer : IMessageFilter
    {
        public IntPtr List;
        public bool PreFilterMessage(ref Message m)
        {
            return m.HWnd == List && (m.Msg == 0x0200 || m.Msg == 0x02A3 || m.Msg == 0x00A0);
        }
    }
    static bool VisiblePreview(object hover)
    {
        var popup = Field<Form>(hover, "popup");
        return popup != null && (bool)popup.GetType().GetProperty("IsShowing").GetValue(popup, null);
    }
    static void AwaitPreview(Func<bool> condition, string description)
    {
        var watch = Stopwatch.StartNew();
        while (!condition()) {
            Application.DoEvents(); Thread.Sleep(8);
            if (watch.Elapsed.TotalSeconds > 22) throw new Exception("Timed out: " + description);
        }
    }
    // Rolls over one row and returns a description of the strip it showed. key names the strip's row in the preview index.
    static string HoverPack(ComboBox combo, ThemeEntry target, string state, string source, bool lean, bool scroll = false, string key = null)
    {
        string shown = null;
        var before = File.ReadAllBytes(Path.Combine(state, "tray-preferences.json"));
        var previous = combo.SelectedItem;
        bool needed = target.NeedsDownload;
        int oldHeight = combo.DropDownHeight;
        bool integral = combo.IntegralHeight;
        if (scroll) combo.DropDownHeight = combo.ItemHeight * 4 + 2;
        var pointer = new FixturePointer { List = OpenRows(combo) };
        Application.AddMessageFilter(pointer);
        try {
            var hover = Field<object>(combo, "hover");
            IntPtr point = RowPoint(pointer.List, combo.Items.IndexOf(target));
            SendMessage(pointer.List, 0x0200, IntPtr.Zero, point);
            Check(Object.ReferenceEquals(Field<ThemeEntry>(hover, "current"), target) && !VisiblePreview(hover), "Native rollover waits before displaying the hovered row");
            AwaitPreview(() => VisiblePreview(hover), "decoded " + target.Name + " preview");
            var popup = Field<Form>(hover, "popup");
            var art = Field<Bitmap>(popup, "art");
            Check(art != null, "The preview retains its decoded artwork while the native dropdown is open");
            shown = String.Join(",", Enumerable.Range(0, 51).Select(i => art.GetPixel(i * 4, 32).ToArgb().ToString("x8")));
            Check(art.Size == new Size(204, 64) && popup.AccessibleName == target.DisplayName + " preview" &&
                  combo.DroppedDown && !popup.ContainsFocus, "The correct three-icon preview appears beside the open dropdown without taking focus");
            using (var shot = new Bitmap(popup.Width, popup.Height)) {
                popup.DrawToBitmap(shot, new Rectangle(Point.Empty, shot.Size));
                shot.Save(Path.Combine(state, "hover-window.png"));
            }
            var entry = File.ReadLines(Path.Combine(source, "..", "PackPreviews", "catalog.tsv")).Select(l => l.Split('\t')).Single(f => f[0] == (key ?? target.Id));
            var cache = Path.Combine(state, "pack-previews", entry[2] + ".webp");
            Check(File.Exists(Path.Combine(source, "..", "PackPreviews", entry[1])) && !File.Exists(cache), "A rollover reads the strip that ships with the app and downloads nothing");
            if (scroll) {
                int top = SendMessage(pointer.List, 0x018E, IntPtr.Zero, IntPtr.Zero).ToInt32();
                SendMessage(pointer.List, 0x0197, (IntPtr)(top > 1 ? top - 1 : top + 1), IntPtr.Zero);
                int hit = SendMessage(pointer.List, 0x01A9, IntPtr.Zero, point).ToInt32() & 0xffff;
                var next = (ThemeEntry)combo.Items[hit];
                Check(next != target && !next.IsDefault && Object.ReferenceEquals(Field<ThemeEntry>(hover, "current"), next) && !VisiblePreview(hover),
                    "Scrolling beneath a stationary pointer immediately hides the previous row's artwork");
                AwaitPreview(() => VisiblePreview(hover), "new row under the stationary pointer");
                Check(popup.AccessibleName == next.DisplayName + " preview", "The row scrolled under the pointer gets its own completed preview");
            }
            SendMessage(pointer.List, 0x02A3, IntPtr.Zero, IntPtr.Zero);
            Check(!VisiblePreview(hover) && Field<ThemeEntry>(hover, "current") == null, "Leaving the list immediately clears the preview");
            combo.DroppedDown = false;
            Check(Object.Equals(combo.SelectedItem, previous) && target.NeedsDownload == needed &&
                  File.ReadAllBytes(Path.Combine(state, "tray-preferences.json")).SequenceEqual(before), "Browsing preserves both selections and the full-pack download status");
        } finally {
            Application.RemoveMessageFilter(pointer); combo.DroppedDown = false;
            if (scroll) { combo.DropDownHeight = oldHeight; combo.IntegralHeight = integral; }
        }
        return shown;
    }
    static void TrayHover(LauncherForm form, ThemeEntry target)
    {
        var tray = Field<ContextMenuStrip>(form, "trayMenu");
        var menu = tray.Items.OfType<ToolStripMenuItem>().Single(i => i.Text == "Change icon theme");
        var item = menu.DropDownItems.Cast<ToolStripMenuItem>().Single(i => i.Text == target.ToString());
        var hover = Field<object>(form, "trayHover");
        var menuPointer = new FixturePointer();
        try {
            tray.Show(form, new Point(20, 40)); menu.ShowDropDown();
            menuPointer.List = menu.DropDown.Handle; Application.AddMessageFilter(menuPointer);
            item.Select();
            var point = new Point(item.Bounds.Left + 8, item.Bounds.Top + item.Bounds.Height / 2);
            SendMessage(menu.DropDown.Handle, 0x0200, IntPtr.Zero, (IntPtr)((point.Y << 16) | point.X));
            Check(Object.ReferenceEquals(Field<ThemeEntry>(hover, "current"), target), "The open tray submenu recognizes the hovered item");
            AwaitPreview(() => VisiblePreview(hover), "tray menu preview");
            Check(Field<Form>(hover, "popup").AccessibleName == target.DisplayName + " preview", "The tray pack submenu shows the same hovered artwork");
        } finally { Application.RemoveMessageFilter(menuPointer); menu.HideDropDown(); tray.Close(); }
        Check(!VisiblePreview(hover), "Closing the tray menu also dismisses its preview");
    }
    static void PersonalHover(LauncherForm form, string state)
    {
        object store = Field<object>(form, "previewStore");
        Func<string, Color, ThemeIcon> icon = (name, color) => {
            string path = Path.Combine(state, name + ".png");
            using (var bmp = new Bitmap(32, 32)) using (var g = Graphics.FromImage(bmp)) {
                g.Clear(color); bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
            }
            return new ThemeIcon { Application = name, Path = path };
        };
        var film = icon("FilmCraft", Color.Blue);
        var pack = new ThemeEntry { Managed = true, Icons = new[] { film, icon("CADCraft", Color.Red), icon("ArtCraftLauncher", Color.Lime), icon("AniCraft", Color.Yellow) } };
        Func<Bitmap> load = () => (Bitmap)store.GetType().GetMethod("Load").Invoke(store, new object[] { pack, CancellationToken.None });
        using (var preview = load()) {
            Check(preview.Width == 204 && preview.GetPixel(32, 32).ToArgb() == Color.Lime.ToArgb() &&
                preview.GetPixel(102, 32).ToArgb() == Color.Yellow.ToArgb() && preview.GetPixel(172, 32).ToArgb() == Color.Red.ToArgb(),
                "Personal previews select exactly three apps with ArtCraft Launcher first and the remaining apps alphabetically");
        }
        pack.Icons = new ThemeIcon[0]; pack.FileIcons = new Dictionary<string, string> { { ".fcproj", film.Path } };
        using (var preview = load()) Check(preview.Width == 64 && preview.GetPixel(32, 32).ToArgb() == Color.Blue.ToArgb(), "A file-only personal pack previews its own local artwork");
        // The file type list previews a pack's file artwork, never its app icons.
        pack.Icons = new[] { icon("CADCraft", Color.Red) };
        Func<Bitmap> loadFiles = () => (Bitmap)store.GetType().GetMethod("LoadFiles").Invoke(store, new object[] { pack, CancellationToken.None });
        using (var apps = load()) using (var files = loadFiles())
            Check(apps.Width == 64 && apps.GetPixel(32, 32).ToArgb() == Color.Red.ToArgb() && files.Width == 64 && files.GetPixel(32, 32).ToArgb() == Color.Blue.ToArgb(),
                "A personal pack previews its app icons in the app list and its file artwork in the file type list");
        // A pack the preview index does not list draws its own artwork, WebP included (fixture A1: an opaque red centre).
        if (!WebpArtwork.SystemDecoderAvailable) { Console.WriteLine("SKIP A local preview draws WebP artwork (no system WebP decoder)"); return; }
        string webp = Path.Combine(state, "PhotoCraft.webp");
        File.WriteAllBytes(webp, Convert.FromBase64String("UklGRoYAAABXRUJQVlA4WAoAAAAQAAAAHwAAHwAAQUxQSBQAAAABUNq2AZP/nw4sHCwiJoAZGv+td1ZQOCBMAAAA0AMAnQEqIAAgAADAEiWgAgAvwH4AfsB/gDK+UsIF+KQ22wf7OtcAAP7+ex//8gr//H8n//jjOf//azf//7eqPCwi1MICOKos6fgAAA=="));
        var unlisted = new ThemeEntry { Id = "Craft-Icons-Fixture/Unlisted WebP", Name = "Unlisted WebP", Pack = "Craft-Icons-Fixture", Icons = new[] { new ThemeIcon { Application = "PhotoCraft", Path = webp, PreviewPath = webp } } };
        using (var preview = (Bitmap)store.GetType().GetMethod("Load").Invoke(store, new object[] { unlisted, CancellationToken.None })) {
            Color centre = preview.GetPixel(32, 32);
            Check(preview.Width == 64 && centre.A == 255 && centre.R > 200 && centre.G < 90 && centre.B < 70, "A local preview draws WebP artwork");
        }
    }
    static void HoverRaces(LauncherForm form, ThemeEntry target, ThemeEntry other, string state, string source, bool lean)
    {
        var tmp = Path.Combine(state, "delayed-preview");
        var win = Directory.CreateDirectory(Path.Combine(tmp, "Windows")).FullName;
        File.WriteAllText(Path.Combine(win, "OnDemand.tsv"), "");
        File.Copy(Path.Combine(source, "PreviewArtworkRevision.txt"), Path.Combine(win, "PreviewArtworkRevision.txt"));
        string catalog = Path.GetFullPath(Path.Combine(source, "..", "PackPreviews", "catalog.tsv"));
        Directory.CreateDirectory(Path.Combine(tmp, "PackPreviews"));
        File.Copy(catalog, Path.Combine(tmp, "PackPreviews", "catalog.tsv"));
        string[] entry = File.ReadLines(catalog).Select(l => l.Split('\t')).Single(f => f[0] == target.Id);
        // The strip that ships with the app stands in for the server's answer.
        string good = Path.Combine(Path.GetDirectoryName(catalog), entry[1]);
        string isolated = Path.Combine(tmp, "state"), cache = Path.Combine(isolated, "pack-previews");
        var asm = typeof(LauncherForm).Assembly;
        using (var began = new ManualResetEventSlim()) using (var release = new ManualResetEventSlim()) {
            Action<Uri,string,int,CancellationToken> fetch = (uri, part, length, cancel) => {
                if (uri.AbsolutePath.EndsWith(entry[1])) {
                    began.Set(); if (!release.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException();
                    File.Copy(good, part); // Simulate a late response from a transfer that has already been canceled.
                } else File.WriteAllBytes(part, new byte[length]); // Correct size, wrong digest.
            };
            var store = Activator.CreateInstance(asm.GetType("BetterIcon.Tray.PackPreviewStore"), new object[] { win, isolated, fetch });
            using (var hover = (IDisposable)Activator.CreateInstance(asm.GetType("BetterIcon.Tray.PackHoverPreview"), new object[] { store, form })) {
                Action<ThemeEntry> over = t => hover.GetType().GetMethod("Hover").Invoke(hover, new object[] { t, new Rectangle(30, 30, 100, 20) });
                try {
                    over(target); AwaitPreview(() => began.IsSet, "delayed response");
                    Check(!VisiblePreview(hover), "No popup appears while a WebP is still downloading");
                    over(other); release.Set();
                    AwaitPreview(() => Field<CancellationTokenSource>(hover, "request") == null, "failed second response");
                    Check(!VisiblePreview(hover) && Directory.GetFiles(cache).Length == 0, "Late and corrupt responses leave no visible preview or partial cache");
                    over(target); AwaitPreview(() => VisiblePreview(hover), "retry after returning to the pack");
                    Check(Directory.GetFiles(cache, "*.webp").Length == 1, "Returning to a row retries and caches the completed preview");
                } finally { release.Set(); }
            }
        }
    }
}
