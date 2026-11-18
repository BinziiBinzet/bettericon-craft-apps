using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace BetterIcon.Tray
{
    sealed class PackPreviewStore
    {
        const int Cell = 64, Gap = 6, MaxBytes = 64 * 1024;
        sealed class Entry { public string File, Hash, Revision; public int Length, Count; public bool Online; }
        readonly string source, directory, cache, refreshedIndex;
        volatile Lazy<Dictionary<string, Entry>> catalog;
        readonly Action<Uri, string, int, CancellationToken> fetch;

        public PackPreviewStore(string windows, string state, Action<Uri, string, int, CancellationToken> download = null)
        {
            source = windows;
            directory = Path.GetFullPath(Path.Combine(windows, "..", "PackPreviews"));
            cache = Path.Combine(state, "pack-previews");
            refreshedIndex = Path.Combine(state, "pack-catalog", "previews.tsv");
            Refresh();
            fetch = download ?? Download;
        }
        public void Refresh() { catalog = new Lazy<Dictionary<string, Entry>>(ReadCatalog); }
        Dictionary<string, Entry> ReadCatalog()
        {
            var result = new Dictionary<string, Entry>(StringComparer.OrdinalIgnoreCase);
            var seed = File.ReadAllText(Path.Combine(source, "PreviewArtworkRevision.txt")).Trim();
            AddEntries(result, File.ReadAllLines(Path.Combine(directory, "catalog.tsv")), seed, false);
            if (File.Exists(refreshedIndex)) {
                try {
                    var lines = File.ReadAllLines(refreshedIndex);
                    if (lines.Length > 1) {
                        var merged = new Dictionary<string, Entry>(result, StringComparer.OrdinalIgnoreCase);
                        AddEntries(merged, lines.Skip(1), lines[0], true);
                        return merged;
                    }
                } catch (IOException) {} catch (InvalidDataException) {}
            }
            return result;
        }
        static void AddEntries(Dictionary<string, Entry> result, IEnumerable<string> lines, string revision, bool online)
        {
            if (!Regex.IsMatch(revision, @"\A[0-9a-f]{40}\z")) throw new InvalidDataException("Invalid preview revision.");
            foreach (string line in lines) {
                string[] f = line.Split('\t');
                int length;
                if (f.Length != 5 || !Regex.IsMatch(f[1], @"\A[A-Za-z0-9-]+\.webp\z") ||
                    !Regex.IsMatch(f[2], @"\A[0-9a-f]{64}\z") || !Int32.TryParse(f[3], out length) || length <= 0 || length > MaxBytes)
                    throw new InvalidDataException("Invalid hover preview catalog.");
                int count = f[4].Split(',').Length;
                if (count > 3 || f[4].Length == 0) throw new InvalidDataException("Invalid preview icon count.");
                result[f[0]] = new Entry { File = f[1], Hash = f[2], Length = length, Count = count, Revision = revision, Online = online };
            }
        }
        static byte[] Verified(string path, Entry entry)
        {
            var file = new FileInfo(path);
            if (!file.Exists || file.Length != entry.Length) return null;
            byte[] bytes = File.ReadAllBytes(path);
            using (var sha = SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").Equals(entry.Hash, StringComparison.OrdinalIgnoreCase) ? bytes : null;
        }
        public Bitmap Load(ThemeEntry theme, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            if (theme == null || theme.IsDefault) return null;
            if (theme.Managed) return LocalPreview(theme, token);
            Entry entry;
            if (!catalog.Value.TryGetValue(theme.Id, out entry)) return theme.NeedsDownload ? null : LocalPreview(theme, token);
            string bundled = Path.Combine(directory, entry.File), cached = Path.Combine(cache, entry.Hash + ".webp");
            byte[] bytes = Verified(bundled, entry) ?? Verified(cached, entry);
            if (bytes == null) {
                if (!entry.Online && !File.Exists(Path.Combine(source, "OnDemand.tsv"))) return null;
                const string raw = "https://raw.githubusercontent.com/BinziiBinzet/bettericon-craft-apps/";
                string relative = "/PackPreviews/" + entry.File;
                var uri = new Uri(raw + entry.Revision + relative);
                PackLibrary.RegularPath(cache); Directory.CreateDirectory(cache);
                string part = Path.Combine(cache, Guid.NewGuid().ToString("N") + ".part");
                try {
                    try { fetch(uri, part, entry.Length, token); }
                    catch (FileNotFoundException) {
                        if (entry.Online) throw;
                        // Artwork can be published between the local build and its release.
                        token.ThrowIfCancellationRequested();
                        fetch(new Uri(raw + "refs/heads/artwork/pack-hover-previews-v1" + relative), part, entry.Length, token);
                    }
                    token.ThrowIfCancellationRequested();
                    bytes = Verified(part, entry);
                    if (bytes == null) throw new InvalidDataException("Incomplete hover preview.");
                    try {
                        if (File.Exists(cached)) File.Replace(part, cached, null);
                        else File.Move(part, cached);
                    } catch (IOException) { if (Verified(cached, entry) == null) throw; }
                } finally { if (File.Exists(part)) File.Delete(part); }
            }
            token.ThrowIfCancellationRequested();
            SvgArtwork.RegisterEmbeddedAssemblies();
            return DecodeWebP(bytes, entry.Count * (Cell + Gap) - Gap);
        }
        static void Download(Uri uri, string destination, int length, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            string curl = Path.Combine(Environment.SystemDirectory, "curl.exe");
            if (File.Exists(curl)) {
                var start = new ProcessStartInfo(curl, "--disable --fail --silent --proto =https --connect-timeout 5 --max-time 12 --max-filesize " +
                    length.ToString(CultureInfo.InvariantCulture) + " --write-out %{http_code} --output \"" + destination + "\" \"" + uri.AbsoluteUri + "\"") {
                    CreateNoWindow = true, UseShellExecute = false, RedirectStandardOutput = true
                };
                using (var process = Process.Start(start))
                using (token.Register(delegate { try { if (!process.HasExited) process.Kill(); } catch (InvalidOperationException) {} catch (System.ComponentModel.Win32Exception) {} })) {
                    string status = process.StandardOutput.ReadToEnd();
                    process.WaitForExit();
                    token.ThrowIfCancellationRequested();
                    if (status == "404") throw new FileNotFoundException("This preview has not been published at this revision.");
                    if (process.ExitCode != 0) throw new IOException("Preview download unavailable.");
                }
            } else {
                var request = (HttpWebRequest)WebRequest.Create(uri);
                request.Timeout = request.ReadWriteTimeout = 12000; request.AllowAutoRedirect = false;
                using (token.Register(request.Abort))
                using (var response = OpenPreview(request))
                using (var input = response.GetResponseStream())
                using (var output = File.Create(destination)) {
                    var buffer = new byte[4096]; int read;
                    while ((read = input.Read(buffer, 0, buffer.Length)) != 0) {
                        token.ThrowIfCancellationRequested();
                        if (output.Length + read > length) throw new InvalidDataException("Oversized preview.");
                        output.Write(buffer, 0, read);
                    }
                }
            }
        }
        static HttpWebResponse OpenPreview(HttpWebRequest request)
        {
            try { return (HttpWebResponse)request.GetResponse(); }
            catch (WebException e) {
                var response = e.Response as HttpWebResponse;
                if (response != null) using (response) {
                    if (response.StatusCode == HttpStatusCode.NotFound) throw new FileNotFoundException("Preview not found.", e);
                }
                throw;
            }
        }
        // The embedded assembly resolver is registered before the JIT enters this method.
        [MethodImpl(MethodImplOptions.NoInlining)]
        static Bitmap DecodeWebP(byte[] bytes, int width)
        {
            using (var input = new MemoryStream(bytes, false))
            using (var decoded = new SixLabors.ImageSharp.Formats.Webp.WebpDecoder().Decode(SixLabors.ImageSharp.Configuration.Default, input, CancellationToken.None))
            using (var png = new MemoryStream()) {
                if (decoded.Width != width || decoded.Height != Cell || decoded.Frames.Count != 1) throw new InvalidDataException("Unexpected preview dimensions.");
                decoded.Save(png, new SixLabors.ImageSharp.Formats.Png.PngEncoder());
                png.Position = 0;
                using (var image = new Bitmap(png)) return new Bitmap(image);
            }
        }
        static Bitmap LocalPreview(ThemeEntry theme, CancellationToken token)
        {
            var paths = (theme.Icons ?? new ThemeIcon[0])
                .OrderBy(icon => !String.Equals(icon.Application, "ArtCraftLauncher", StringComparison.OrdinalIgnoreCase))
                .ThenBy(icon => icon.Application, StringComparer.OrdinalIgnoreCase)
                .Select(icon => String.IsNullOrEmpty(icon.PreviewPath) ? icon.Path : icon.PreviewPath).Take(3).ToArray();
            if (paths.Length == 0 && theme.FileIcons != null)
                paths = theme.FileIcons.OrderBy(p => p.Key, StringComparer.OrdinalIgnoreCase).Select(p => p.Value).Take(3).ToArray();
            if (paths.Length == 0) return null;
            var result = new Bitmap(paths.Length * (Cell + Gap) - Gap, Cell);
            try {
                using (Graphics g = Graphics.FromImage(result)) for (int i = 0; i < paths.Length; i++) {
                    token.ThrowIfCancellationRequested();
                    using (var icon = LauncherForm.Thumbnail(paths[i], SystemIcons.Application, Cell)) g.DrawImageUnscaled(icon, i * (Cell + Gap), 0);
                }
                return result;
            } catch { result.Dispose(); throw; }
        }
    }

    sealed class PackHoverPreview : IDisposable
    {
        readonly PackPreviewStore store;
        readonly Control owner;
        CancellationTokenSource request;
        ThemeEntry current;
        Rectangle row;
        PreviewWindow popup;
        public PackHoverPreview(PackPreviewStore source, Control control) { store = source; owner = control; }
        public void Hover(ThemeEntry theme, Rectangle bounds)
        {
            if (theme == null || theme.IsDefault || bounds.IsEmpty) { Clear(); return; }
            bool moved = bounds != row;
            row = bounds;
            if (Object.ReferenceEquals(current, theme)) {
                if (moved && popup != null && popup.IsShowing) popup.Place(row);
                return;
            }
            Clear(); current = theme; row = bounds;
            request = new CancellationTokenSource();
            DisplayAfterHover(theme, request);
        }
        async void DisplayAfterHover(ThemeEntry theme, CancellationTokenSource pending)
        {
            Bitmap image = null;
            var token = pending.Token;
            try {
                await Task.Delay(175, token);
                image = await Task.Run(() => store.Load(theme, token), token);
                if (image == null || token.IsCancellationRequested || request != pending || owner.IsDisposed || owner.Disposing) return;
                if (popup == null) popup = new PreviewWindow();
                popup.Display(image, row, owner, theme.DisplayName); image = null;
            } catch (OperationCanceledException) {
            } catch (Exception error) {
                // Hover failure leaves the menu usable. A later rollover can retry.
                System.Diagnostics.Trace.WriteLine("BetterIcon hover preview: " + error.Message);
            } finally {
                if (image != null) image.Dispose();
                if (request == pending) request = null;
                pending.Dispose();
            }
        }
        public void Clear()
        {
            var old = request; request = null; current = null;
            if (old != null) old.Cancel();
            if (popup != null) popup.ClearImage();
        }
        public void Dispose() { Clear(); if (popup != null) { popup.Dispose(); popup = null; } }

        sealed class PreviewWindow : Form
        {
            [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
            [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
            [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window, int command);
            public bool IsShowing { get { return IsHandleCreated && IsWindowVisible(Handle); } }
            Bitmap art;
            Rectangle content;
            public PreviewWindow()
            {
                FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false;
                StartPosition = FormStartPosition.Manual; AutoScaleMode = AutoScaleMode.None; DoubleBuffered = true;
                AccessibleRole = AccessibleRole.ToolTip;
            }
            protected override bool ShowWithoutActivation { get { return true; } }
            protected override CreateParams CreateParams {
                get { var p = base.CreateParams; p.ExStyle |= 0x08000000 | 0x0080 | 0x0020; return p; } // WS_EX_NOACTIVATE | TOOLWINDOW | TRANSPARENT
            }
            protected override void WndProc(ref Message m)
            {
                if (m.Msg == 0x0084) { m.Result = (IntPtr)(-1); return; } // HTTRANSPARENT
                base.WndProc(ref m);
            }
            public void Display(Bitmap image, Rectangle anchor, Control owner, string title)
            {
                ClearImage(); art = image; AccessibleName = title + " preview";
                BackColor = SystemInformation.HighContrast ? SystemColors.Window : owner.BackColor;
                float scale;
                using (var g = owner.CreateGraphics()) scale = g.DpiX / 96f;
                int pad = Math.Max(4, (int)Math.Round(6 * scale));
                content = new Rectangle(pad, pad, (int)Math.Round(art.Width * scale), (int)Math.Round(art.Height * scale));
                ClientSize = new Size(content.Right + pad, content.Bottom + pad);
                // Form.Show enters WinForms activation handling and dismisses an open
                // native combo. Show this input-transparent HWND without activating it.
                Place(anchor); Invalidate(); Update();
            }
            public void Place(Rectangle anchor)
            {
                Rectangle work = Screen.FromRectangle(anchor).WorkingArea;
                int x = anchor.Right + 6;
                int y = anchor.Top + (anchor.Height - Height) / 2;
                if (x + Width > work.Right) {
                    x = anchor.Left - Width - 6;
                    if (x < work.Left) {
                        x = anchor.Left + (anchor.Width - Width) / 2;
                        y = anchor.Bottom + 6;
                        if (y + Height > work.Bottom) y = anchor.Top - Height - 6;
                    }
                }
                SetWindowPos(Handle, (IntPtr)(-1), Math.Max(work.Left, Math.Min(x, work.Right - Width)),
                    Math.Max(work.Top, Math.Min(y, work.Bottom - Height)), Width, Height, 0x0010 | 0x0040); // NOACTIVATE | SHOWWINDOW
            }
            protected override void OnPaint(PaintEventArgs e)
            {
                base.OnPaint(e);
                if (art == null) return;
                e.Graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                e.Graphics.DrawImage(art, content);
                ControlPaint.DrawBorder(e.Graphics, ClientRectangle, SystemInformation.HighContrast ? SystemColors.WindowText : SystemColors.ControlDark, ButtonBorderStyle.Solid);
            }
            public void ClearImage() { if (IsShowing) ShowWindow(Handle, 0); if (art != null) { art.Dispose(); art = null; } }
        }
    }
}
