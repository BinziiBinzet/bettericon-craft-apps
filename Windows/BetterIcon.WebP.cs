// WebP pack artwork on Windows. Every WebP file passes the byte rule first. Windows' own decoder (WIC, from Microsoft's
// WebP Image Extensions) decodes it where it exists; on a PC without it, Google's libwebp decoder DLL does, once the user
// installs BetterIcon's WebP support. No ImageSharp and no WPF.
// The tray program compiles this file in. The PowerShell worker compiles its own copy with BETTERICON_WORKER, so an older
// cached tray program never stands in for it, and the two copies never share a type name.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

#if BETTERICON_WORKER
namespace BetterIcon.Worker
#else
namespace BetterIcon.Tray
#endif
{
    public static class WebpArtwork
    {
        public const int MaxSide = 4096;
        public const int MaxBytes = 16 * 1024 * 1024;
        // The causes of the WebP spec (section 4). C5 offers BetterIcon's own WebP support first.
        public const string Animated = "Animated WebP artwork is not supported.";
        public const string Damaged = "The WebP file is damaged or incomplete.";
        public const string NotWebP = "The file is named .webp but is not a WebP image.";
        public const string TooLarge = "WebP artwork must be at most 4096 pixels per side.";
        public const string NoDecoder = "This PC can't read WebP artwork. Install WebP support from BetterIcon, or the free WebP Image Extensions from the Microsoft Store.";
        public const string StillImage = " Choose a still image.";
        // Test seam, read on every check: "none" behaves as if this PC had no WebP decoder at all, and "libwebp" hides
        // Windows' decoder so that BetterIcon's libwebp is used. Unset in normal use, and never honored in a process that
        // is really elevated.
        public const string DecoderSeam = "BETTERICON_WEBP_DECODER";
        // Fixture A4 of the spec: 16x16 lossless, (0,0) opaque red and (15,15) opaque blue.
        const string ProbeImage = "UklGRiwAAABXRUJQVlA4TB8AAAAvD8ADECDStpl/00eF5/M//wKCwnTPm4DCiH/GTPwDAA==";
        // Windows' own decoder, decided by decoding fixture A4: 1 yes, -1 no, 0 not asked yet. A yes holds for the life of
        // the process. A no holds until ForgetMissingWindowsDecoder, which the tray calls when it reads the packs again, so
        // the Store's WebP Image Extensions installed meanwhile are found without a restart.
        static readonly object probeSync = new object();
        static int windowsDecoder;

        static string Seam() { return LibWebP.ReallyElevated ? "" : (Environment.GetEnvironmentVariable(DecoderSeam) ?? "").Trim().ToLowerInvariant(); }
        static bool WindowsDecoder
        {
            get {
                lock (probeSync) {
                    if (windowsDecoder == 0) windowsDecoder = ProbeWindowsDecoder() ? 1 : -1;
                    return windowsDecoder > 0;
                }
            }
        }
        public static void ForgetMissingWindowsDecoder() { lock (probeSync) if (windowsDecoder < 0) windowsDecoder = 0; }

        // The spec's byte rule. It needs the first 30 bytes and the file length; it returns null or a cause.
        public static string HeaderProblem(byte[] head, long length, out int width, out int height)
        {
            width = 0; height = 0;
            if (head == null || length < 30 || length > MaxBytes || head.Length < 30) return Damaged;
            if (head[0] != 'R' || head[1] != 'I' || head[2] != 'F' || head[3] != 'F' || head[8] != 'W' || head[9] != 'E' || head[10] != 'B' || head[11] != 'P') return NotWebP;
            if ((long)BitConverter.ToUInt32(head, 4) + 8 > length) return Damaged;
            string chunk = Encoding.ASCII.GetString(head, 12, 4);
            if (chunk == "VP8 ") {
                if (head[23] != 0x9D || head[24] != 0x01 || head[25] != 0x2A) return Damaged;
                width = BitConverter.ToUInt16(head, 26) & 0x3FFF; height = BitConverter.ToUInt16(head, 28) & 0x3FFF;
            }
            else if (chunk == "VP8L") {
                if (head[20] != 0x2F) return Damaged;
                uint bits = BitConverter.ToUInt32(head, 21);
                width = (int)(bits & 0x3FFF) + 1; height = (int)((bits >> 14) & 0x3FFF) + 1;
            }
            else if (chunk == "VP8X") {
                if ((head[20] & 0x02) != 0) return Animated;
                width = (head[24] | head[25] << 8 | head[26] << 16) + 1; height = (head[27] | head[28] << 8 | head[29] << 16) + 1;
            }
            else return Damaged;
            if (width < 1 || height < 1 || width > MaxSide || height > MaxSide) return TooLarge;
            return null;
        }

        // Windows' own WebP decoder, found by decoding fixture A4, never from registry keys: the Store's WebP Image
        // Extensions register their codec as packaged COM.
        public static bool SystemDecoderAvailable { get { string seam = Seam(); return seam != "none" && seam != "libwebp" && WindowsDecoder; } }
        // "WIC", "libwebp", or null when this process cannot read WebP artwork now.
        public static string Decoder
        {
            get {
                string seam = Seam();
                if (seam == "none") return null;
                if (seam != "libwebp" && WindowsDecoder) return "WIC";
                return LibWebP.Available ? "libwebp" : null;
            }
        }
        public static bool DecoderAvailable { get { return Decoder != null; } }
        // The decoder BetterIcon running as administrator would use now, as it does for shared shortcuts: Windows' own, or
        // libwebp only where the elevated rule lets it load (LibWebP.SharedProblem). It loads nothing, so a preview without
        // elevation and the elevated pass that follows it choose the same artwork.
        public static string SharedDecoder
        {
            get {
                string seam = Seam();
                if (seam == "none") return null;
                if (seam != "libwebp" && WindowsDecoder) return "WIC";
                return LibWebP.SharedProblem == null ? "libwebp" : null;
            }
        }

        // Why a WebP file cannot be used, or null. With decode, a full decode runs too.
        public static string Problem(string path, bool decode) { return Problem(path, decode, false); }
        // With shared, as BetterIcon running as administrator would judge it for shared shortcuts (SharedDecoder).
        public static string Problem(string path, bool decode, bool shared)
        {
            try {
                FileInfo file = new FileInfo(path);
                if (!file.Exists || file.Length < 1 || file.Length > MaxBytes) return Damaged;
                byte[] head = new byte[30];
                int read = 0;
                using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                    int count;
                    while (read < head.Length && (count = stream.Read(head, read, head.Length - read)) > 0) read += count;
                }
                if (read < head.Length) return Damaged;
                int width, height;
                string cause = HeaderProblem(head, file.Length, out width, out height);
                if (cause != null) return cause;
                string decoder = shared ? SharedDecoder : Decoder;
                if (decoder == null) return MissingDecoderCause(shared);
                if (decode) using (Bitmap image = DecodeWith(decoder, File.ReadAllBytes(path))) { }
                return null;
            }
            catch (IOException error) { return Cause(error); }
            catch (UnauthorizedAccessException) { return Damaged; }
            catch (ArgumentException) { return Damaged; }
        }
        // A cause text from an exception this class threw, or C2 for anything else.
        static string Cause(Exception error)
        {
            string message = error == null ? null : error.Message;
            return message == Animated || message == Damaged || message == NotWebP || message == TooLarge || message == NoDecoder || message == LibWebP.ElevatedUntrusted ? message : Damaged;
        }
        // Whether a cause says the file itself can't be used, which no decoder would change: C1 to C4.
        public static bool FileCause(string cause) { return cause == Animated || cause == Damaged || cause == NotWebP || cause == TooLarge; }
        // Why WebP can't be read now: C5, which offers WebP support, or, where an elevated BetterIcon may not load the
        // WebP support installed for the account, that reason instead: a download would change nothing there.
        static string MissingDecoderCause(bool shared)
        {
            if (Seam() == "none" || (!shared && !LibWebP.Elevated)) return NoDecoder;
            string reason = shared ? LibWebP.SharedProblem : LibWebP.LastProblem;
            return reason == null || reason == LibWebP.NotInstalled || reason == LibWebP.NoBuild || reason == LibWebP.Unconfigured ? NoDecoder : reason;
        }

        // A still WebP image as a 32-bit bitmap with straight alpha. Throws IOException with a cause text.
        public static Bitmap Decode(byte[] bytes)
        {
            if (bytes == null) throw new IOException(Damaged);
            int width, height;
            string cause = HeaderProblem(bytes, bytes.LongLength, out width, out height);
            if (cause != null) throw new IOException(cause);
            string decoder = Decoder;
            if (decoder == null) throw new IOException(MissingDecoderCause(false));
            return DecodeWith(decoder, bytes);
        }
        static Bitmap DecodeWith(string decoder, byte[] bytes)
        {
            if (bytes == null) throw new IOException(Damaged);
            int width, height;
            string cause = HeaderProblem(bytes, bytes.LongLength, out width, out height);
            if (cause != null) throw new IOException(cause);
            try {
                if (decoder == "WIC") return DecodeWithWindows(bytes, width, height);
                string reason;
                if (!LibWebP.TryLoad(out reason)) throw new IOException(NoDecoder);
                return LibWebP.Decode(bytes, width, height);
            }
            catch (IOException) { throw; }
            catch (OutOfMemoryException) { throw new IOException(Damaged); }
            catch (ExternalException) { throw new IOException(Damaged); }
            catch (InvalidCastException) { throw new IOException(Damaged); }
            catch (ArgumentException) { throw new IOException(Damaged); }
        }
        public static byte[] ToPng(byte[] bytes)
        {
            using (Bitmap image = Decode(bytes))
            using (MemoryStream png = new MemoryStream()) {
                image.Save(png, ImageFormat.Png);
                return png.ToArray();
            }
        }
        // The larger side from the header, or 0.
        public static int Side(string path)
        {
            try {
                byte[] head = new byte[30]; int read = 0; long length;
                using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                    length = stream.Length;
                    int count;
                    while (read < head.Length && (count = stream.Read(head, read, head.Length - read)) > 0) read += count;
                }
                int width, height;
                return read == head.Length && HeaderProblem(head, length, out width, out height) == null ? Math.Max(width, height) : 0;
            }
            catch (IOException) { return 0; }
            catch (UnauthorizedAccessException) { return 0; }
            catch (ArgumentException) { return 0; }
        }

        static bool ProbeWindowsDecoder()
        {
            try {
                using (Bitmap image = DecodeWithWindows(Convert.FromBase64String(ProbeImage), 16, 16)) {
                    Color first = image.GetPixel(0, 0), last = image.GetPixel(15, 15);
                    return first.A == 255 && first.R == 255 && first.G == 0 && first.B == 0 && last.A == 255 && last.R == 0 && last.G == 0 && last.B == 255;
                }
            }
            catch (Exception) { return false; }
        }

        // ---- WIC through COM, without WPF (spec, Appendix B) ----------------------------------------------------------
        static readonly Guid ImagingFactoryClass = new Guid("cacaf262-9370-4615-a13b-9f5539da4c0a");
        static readonly Guid WebpContainer = new Guid("e094b0e2-67f2-45b3-b0ea-115337ca7cf3");
        static readonly Guid Bgra32 = new Guid("6fddc324-4e03-4bfe-b185-3d77768dc90f");
        const int ComponentNotFound = unchecked((int)0x88982F50);
        [DllImport("shlwapi.dll")] static extern IntPtr SHCreateMemStream(byte[] initial, uint size);
        [ComImport, Guid("ec5ec8a9-c395-4314-9c77-54d7a935ff70"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IWICImagingFactory
        {
            [PreserveSig] int CreateDecoderFromFilename([MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr vendor, uint access, int options, out IWICBitmapDecoder decoder);
            [PreserveSig] int CreateDecoderFromStream(IntPtr stream, IntPtr vendor, int options, out IWICBitmapDecoder decoder);
            void CreateDecoderFromFileHandle(); void CreateComponentInfo(); void CreateDecoder(); void CreateEncoder(); void CreatePalette();
            [PreserveSig] int CreateFormatConverter(out IWICFormatConverter converter);
        }
        [ComImport, Guid("9edde9e7-8dee-47ea-99df-e6faf2ed44bf"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IWICBitmapDecoder
        {
            void QueryCapability(); void Initialize();
            [PreserveSig] int GetContainerFormat(out Guid format);
            void GetDecoderInfo(); void CopyPalette(); void GetMetadataQueryReader(); void GetPreview(); void GetColorContexts(); void GetThumbnail();
            [PreserveSig] int GetFrameCount(out uint count);
            [PreserveSig] int GetFrame(uint index, out IntPtr frame);
        }
        [ComImport, Guid("00000301-a8f2-4877-ba0a-fd2b6645fb94"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IWICFormatConverter
        {
            [PreserveSig] int GetSize(out uint width, out uint height);
            void GetPixelFormat(); void GetResolution(); void CopyPalette();
            [PreserveSig] int CopyPixels(IntPtr rect, uint stride, uint size, IntPtr buffer);
            [PreserveSig] int Initialize(IntPtr source, ref Guid format, int dither, IntPtr palette, double alpha, int paletteType);
        }
        static Bitmap DecodeWithWindows(byte[] bytes, int width, int height)
        {
            IWICImagingFactory factory = null; IWICBitmapDecoder decoder = null; IWICFormatConverter converter = null;
            IntPtr stream = IntPtr.Zero, frame = IntPtr.Zero;
            Bitmap result = null;
            try {
                try { factory = (IWICImagingFactory)Activator.CreateInstance(Type.GetTypeFromCLSID(ImagingFactoryClass, true)); }
                catch (Exception) { throw new IOException(NoDecoder); }
                stream = SHCreateMemStream(bytes, (uint)bytes.Length);
                if (stream == IntPtr.Zero) throw new IOException(Damaged);
                int status = factory.CreateDecoderFromStream(stream, IntPtr.Zero, 1, out decoder);
                // The buffer passed the byte rule, so a missing component means the codec is missing.
                if (status == ComponentNotFound) throw new IOException(NoDecoder);
                if (status < 0 || decoder == null) throw new IOException(Damaged);
                Guid container;
                if (decoder.GetContainerFormat(out container) < 0) throw new IOException(Damaged);
                if (container != WebpContainer) throw new IOException(NotWebP);
                uint frames;
                if (decoder.GetFrameCount(out frames) < 0 || frames == 0) throw new IOException(Damaged);
                if (frames > 1) throw new IOException(Animated);
                if (decoder.GetFrame(0, out frame) < 0 || frame == IntPtr.Zero) throw new IOException(Damaged);
                if (factory.CreateFormatConverter(out converter) < 0 || converter == null) throw new IOException(Damaged);
                Guid format = Bgra32;
                if (converter.Initialize(frame, ref format, 0, IntPtr.Zero, 0.0, 0) < 0) throw new IOException(Damaged);
                uint decodedWidth, decodedHeight;
                if (converter.GetSize(out decodedWidth, out decodedHeight) < 0 || decodedWidth == 0 || decodedHeight == 0) throw new IOException(Damaged);
                if (decodedWidth > MaxSide || decodedHeight > MaxSide) throw new IOException(TooLarge);
                if (decodedWidth != width || decodedHeight != height) throw new IOException(Damaged);
                result = new Bitmap(width, height, PixelFormat.Format32bppArgb);
                BitmapData data = result.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
                try { status = converter.CopyPixels(IntPtr.Zero, (uint)data.Stride, (uint)(data.Stride * height), data.Scan0); }
                finally { result.UnlockBits(data); }
                if (status < 0) throw new IOException(Damaged);
                Bitmap done = result; result = null;
                return done;
            }
            finally {
                if (result != null) result.Dispose();
                if (converter != null) Marshal.ReleaseComObject(converter);
                if (frame != IntPtr.Zero) Marshal.Release(frame);
                if (decoder != null) Marshal.ReleaseComObject(decoder);
                if (stream != IntPtr.Zero) Marshal.Release(stream);
                if (factory != null) Marshal.ReleaseComObject(factory);
            }
        }
    }

    // Google's libwebp decoder, for PCs where Windows has no WebP decoder. It is an optional download (Setup's optional
    // downloads page, or the offer beside a left-out icon), pinned in LibWebP.ini, which Setup reads too. Each process
    // loads the build of its own architecture, by full path only, after checking its size and SHA-256 against the pin.
    // An elevated process never loads a DLL that a standard user could have changed. It loads one only when BetterIcon
    // itself, its pins and its code, can be changed by administrators alone (an installation in Program Files, say), and
    // then only a copy in BetterIcon's administrators-only shared folder, made from the verified per-user DLL alone.
    // Otherwise it goes without, and the PNG twin is used. BetterIcon's Setup installs for one account, so its elevated
    // passes use Windows' own decoder only.
    public static class LibWebP
    {
        // Test seams. None of them is honored in a process that is really elevated, except ElevatedSeam, which only adds
        // the elevated rules.
        public const string ArchitectureSeam = "BETTERICON_LIBWEBP_ARCH";
        public const string ElevatedSeam = "BETTERICON_WEBP_ELEVATED";
        public const string SourceSeam = "BETTERICON_LIBWEBP_SOURCE";
        public const string SharedSeam = "BETTERICON_LIBWEBP_SHARED";
        public const string TrustSeam = "BETTERICON_LIBWEBP_TRUST";
        public const string NotInstalled = "WebP support is not installed.";
        public const string Tampered = "WebP support was changed after it was installed, so BetterIcon won't load it. Install WebP support again.";
        public const string ElevatedRefused = "An elevated BetterIcon loads WebP support only from its administrators-only folder.";
        public const string ElevatedUntrusted = "BetterIcon running as administrator, as it does for shared shortcuts, can't use the WebP support installed for your account. Install the free WebP Image Extensions from the Microsoft Store.";
        public const string SharedUnprotected = "BetterIcon's shared folder can be changed by other users, so an elevated BetterIcon won't load WebP support from it.";
        public const string NoBuild = "BetterIcon's WebP support has no build for this PC's processor.";
        public const string Unconfigured = "BetterIcon's WebP support is not configured.";
        public const string Mismatch = "The downloaded WebP support did not match its published checksum. Try again.";
        public const string DownloadFailed = "Couldn't download WebP support. Check your connection and try again.";
        public const string OtherCopy = "Windows has another copy of the WebP library loaded, so BetterIcon won't use it.";
        static readonly string[] Notices = { "COPYING", "PATENTS", "AUTHORS", "README.txt" };
        static readonly string[] AdministratorSids = { "S-1-5-18", "S-1-5-32-544", "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464" };
        // Write, delete, permission and ownership rights, plus GENERIC_ALL and GENERIC_WRITE.
        const int WriteRights = 0x2 | 0x4 | 0x10 | 0x40 | 0x100 | 0x10000 | 0x40000 | 0x80000 | 0x10000000 | 0x40000000;
        // What lets an account rename a folder away under its parent: delete-child, permissions, ownership, GENERIC_ALL.
        const int ParentRights = 0x40 | 0x40000 | 0x80000 | 0x10000000;
        const int AbiVersion = 0x0210;
        const uint SearchSystem32 = 0x00000800;
        static readonly object sync = new object();
        static string pinsPath, stateDirectory, codeFile, problem, loadedFrom;
        static PinSet pins;
        static IntPtr module;
        static FeaturesFunction getFeatures;
        static DecodeFunction decodeInto;

        public sealed class Package
        {
            public string Architecture { get; set; }
            public string Zip { get; set; }
            public long ZipBytes { get; set; }
            public string ZipSha256 { get; set; }
            public long DllBytes { get; set; }
            public string DllSha256 { get; set; }
        }
        public sealed class PinSet
        {
            public string Version { get; set; }
            public string Dll { get; set; }
            public string Release { get; set; }
            public int DecoderVersion { get; set; }
            public Dictionary<string, Package> Packages { get; set; }
        }

        // Where the pins are, and BetterIcon's per-user state folder, which holds the per-user copy under libwebp\. The
        // code is this program itself.
        public static void Configure(string pinsFile, string state) { Configure(pinsFile, state, OwnFile()); }
        // The PowerShell worker names the BetterIcon.WebP.cs it compiled, since its compiled copy has no file of its own.
        public static void Configure(string pinsFile, string state, string code)
        {
            lock (sync) {
                if (!String.Equals(pinsFile, pinsPath, StringComparison.OrdinalIgnoreCase)) pins = null;
                pinsPath = pinsFile; stateDirectory = state; codeFile = code;
            }
        }
        static string OwnFile()
        {
            try { string location = typeof(LibWebP).Assembly.Location; return String.IsNullOrEmpty(location) ? null : location; }
            catch (NotSupportedException) { return null; }
        }
        // An elevated BetterIcon follows these pins and runs this code. Where a standard user can change either, it loads no
        // WebP support at all: whatever it checked, its checks could have been rewritten. Null when only administrators can
        // change both, as for an installation in Program Files.
        public static string CodeRefusal
        {
            get {
                string pinsFile, code;
                lock (sync) { pinsFile = pinsPath; code = codeFile; }
                if (String.IsNullOrEmpty(pinsFile) || String.IsNullOrEmpty(code)) return ElevatedUntrusted;
                try {
                    return AdministratorsOnly(pinsFile, Path.GetDirectoryName(Path.GetFullPath(pinsFile))) && AdministratorsOnly(code, Path.GetDirectoryName(Path.GetFullPath(code))) ? null : ElevatedUntrusted;
                }
                catch (ArgumentException) { return ElevatedUntrusted; }
                catch (NotSupportedException) { return ElevatedUntrusted; }
                catch (PathTooLongException) { return ElevatedUntrusted; }
            }
        }
        public static PinSet Pins
        {
            get {
                lock (sync) {
                    if (pins == null && pinsPath != null && File.Exists(pinsPath)) {
                        try { pins = ReadPins(pinsPath); } catch (InvalidDataException) { } catch (IOException) { }
                    }
                    return pins;
                }
            }
        }
        public static PinSet ReadPins(string path)
        {
            var sections = new Dictionary<string, Dictionary<string, string>>(StringComparer.OrdinalIgnoreCase);
            Dictionary<string, string> current = null;
            foreach (string raw in File.ReadAllLines(path)) {
                string line = raw.Trim();
                if (line.Length == 0 || line[0] == ';' || line[0] == '#') continue;
                if (line[0] == '[' && line[line.Length - 1] == ']') {
                    current = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                    sections[line.Substring(1, line.Length - 2).Trim()] = current;
                    continue;
                }
                int equals = line.IndexOf('=');
                if (current == null || equals <= 0) throw new InvalidDataException("Invalid WebP support pins.");
                current[line.Substring(0, equals).Trim()] = line.Substring(equals + 1).Trim();
            }
            Dictionary<string, string> main;
            if (!sections.TryGetValue("LibWebP", out main)) throw new InvalidDataException("Invalid WebP support pins.");
            Func<Dictionary<string, string>, string, string> value = (section, key) => { string text; return section.TryGetValue(key, out text) ? text : ""; };
            PinSet result = new PinSet { Version = value(main, "Version"), Dll = value(main, "Dll"), Release = value(main, "Release"), Packages = new Dictionary<string, Package>(StringComparer.Ordinal) };
            int decoder;
            string decoderText = value(main, "DecoderVersion");
            if (!Regex.IsMatch(result.Version, @"\A\d+\.\d+\.\d+\z") || result.Dll != "libwebpdecoder.dll" || !result.Release.StartsWith("https://", StringComparison.Ordinal) || !result.Release.EndsWith("/", StringComparison.Ordinal)
                || !decoderText.StartsWith("0x", StringComparison.OrdinalIgnoreCase) || !Int32.TryParse(decoderText.Substring(2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out decoder))
                throw new InvalidDataException("Invalid WebP support pins.");
            result.DecoderVersion = decoder;
            foreach (string architecture in new[] { "x86", "x64", "arm64" }) {
                Dictionary<string, string> section;
                if (!sections.TryGetValue(architecture, out section)) continue;
                long zipBytes, dllBytes;
                Package package = new Package { Architecture = architecture, Zip = value(section, "Zip"), ZipSha256 = value(section, "ZipSha256").ToLowerInvariant(), DllSha256 = value(section, "DllSha256").ToLowerInvariant() };
                if (package.Zip != "BetterIcon-libwebp-" + result.Version + "-" + architecture + ".zip" || !Regex.IsMatch(package.ZipSha256, @"\A[0-9a-f]{64}\z") || !Regex.IsMatch(package.DllSha256, @"\A[0-9a-f]{64}\z")
                    || !Int64.TryParse(value(section, "ZipBytes"), NumberStyles.None, CultureInfo.InvariantCulture, out zipBytes) || !Int64.TryParse(value(section, "DllBytes"), NumberStyles.None, CultureInfo.InvariantCulture, out dllBytes)
                    || zipBytes < 1 || zipBytes > 16 * 1024 * 1024 || dllBytes < 1 || dllBytes > 16 * 1024 * 1024)
                    throw new InvalidDataException("Invalid WebP support pins for " + architecture + ".");
                package.ZipBytes = zipBytes; package.DllBytes = dllBytes;
                result.Packages[architecture] = package;
            }
            return result;
        }

        // ---- Processes and folders -------------------------------------------------------------------------------
        [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetTokenInformation(IntPtr token, int informationClass, out int information, int length, out int returned);
        [StructLayout(LayoutKind.Sequential)] struct MachineInformation { public ushort ProcessMachine; public ushort Reserved; public uint Attributes; }
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessInformation(IntPtr process, int informationClass, out MachineInformation information, int size);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();

        // Elevated, or an administrator's full token where UAC is off. When unsure, the stricter answer. A process keeps its
        // token, so this is asked once.
        static readonly Lazy<bool> reallyElevated = new Lazy<bool>(delegate {
            try {
                using (WindowsIdentity identity = WindowsIdentity.GetCurrent()) {
                    if (new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator)) return true;
                    int elevated, size;
                    return GetTokenInformation(identity.Token, 20, out elevated, 4, out size) && elevated != 0;
                }
            }
            catch (Exception) { return true; }
        }, LazyThreadSafetyMode.ExecutionAndPublication);
        public static bool ReallyElevated { get { return reallyElevated.Value; } }
        public static bool Elevated { get { return ReallyElevated || Environment.GetEnvironmentVariable(ElevatedSeam) == "1"; } }
        static string ForcedArchitecture()
        {
            if (ReallyElevated) return null;
            string forced = (Environment.GetEnvironmentVariable(ArchitectureSeam) ?? "").Trim().ToLowerInvariant();
            return forced == "x86" || forced == "x64" || forced == "arm64" ? forced : null;
        }
        static string MachineName(ushort machine) { return machine == 0x014C ? "x86" : machine == 0x8664 ? "x64" : machine == 0xAA64 ? "arm64" : null; }
        // The processor this process runs as: x86, x64 or arm64.
        public static string ProcessArchitecture
        {
            get {
                string forced = ForcedArchitecture();
                if (forced != null) return forced;
                if (IntPtr.Size == 4) return "x86";
                // Windows 11 tells a process its own machine, also an x64 process on ARM64. Windows 10 on ARM runs no x64.
                try {
                    MachineInformation information;
                    if (GetProcessInformation(GetCurrentProcess(), 9, out information, Marshal.SizeOf(typeof(MachineInformation)))) {
                        string name = MachineName(information.ProcessMachine);
                        if (name != null) return name;
                    }
                }
                catch (EntryPointNotFoundException) { }
                return NativeArchitecture() == "arm64" ? "arm64" : "x64";
            }
        }
        static string NativeArchitecture()
        {
            try {
                ushort process, native;
                if (IsWow64Process2(GetCurrentProcess(), out process, out native)) return MachineName(native);
            }
            catch (EntryPointNotFoundException) { }
            return Environment.Is64BitOperatingSystem ? "x64" : "x86";
        }
        // The builds this PC's BetterIcon needs: the tray program's own, and the PowerShell worker's, which on Windows on
        // ARM is ARM64 even when the tray program runs as x64.
        public static string[] NeededArchitectures
        {
            get {
                string own = ProcessArchitecture;
                if (own == null) return new string[0];
                if (ForcedArchitecture() != null) return new[] { own };
                string worker = IntPtr.Size == 4 ? "x86" : NativeArchitecture();
                return worker == null || worker == own ? new[] { own } : new[] { own, worker };
            }
        }
        public static string UserRoot
        {
            get {
                PinSet set = Pins;
                string state;
                lock (sync) state = stateDirectory;
                return set == null || String.IsNullOrEmpty(state) ? null : Path.Combine(state, "libwebp", set.Version);
            }
        }
        public static string UserFolder(string architecture) { string root = UserRoot; return root == null ? null : Path.Combine(root, architecture); }
        // BetterIcon's shared folder, which elevated operations protect so that only SYSTEM and Administrators can change it.
        public static string SharedBase
        {
            get {
                if (!ReallyElevated) {
                    string seam = Environment.GetEnvironmentVariable(SharedSeam);
                    if (!String.IsNullOrWhiteSpace(seam) && Path.IsPathRooted(seam)) return Path.GetFullPath(seam.Trim());
                }
                return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "BetterIcon-Craft Apps");
            }
        }
        public static string SharedFolder(string architecture)
        {
            PinSet set = Pins;
            return set == null ? null : Path.Combine(SharedBase, "libwebp", set.Version, architecture);
        }
        static HashSet<string> TrustedSids()
        {
            var trusted = new HashSet<string>(AdministratorSids, StringComparer.OrdinalIgnoreCase);
            if (!ReallyElevated) {
                foreach (string sid in (Environment.GetEnvironmentVariable(TrustSeam) ?? "").Split(new[] { ',', ';' }, StringSplitOptions.RemoveEmptyEntries))
                    if (Regex.IsMatch(sid.Trim(), @"\AS-1-[0-9-]+\z")) trusted.Add(sid.Trim());
            }
            return trusted;
        }
        static bool OnlyTrusted(FileSystemSecurity security, HashSet<string> trusted, int rights, bool checkOwner)
        {
            if (checkOwner) {
                SecurityIdentifier owner = security.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
                if (owner == null || !trusted.Contains(owner.Value)) return false;
            }
            foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier))) {
                if (rule.AccessControlType != AccessControlType.Allow || (rule.PropagationFlags & PropagationFlags.InheritOnly) != 0) continue;
                if (trusted.Contains(rule.IdentityReference.Value)) continue;
                if (((int)rule.FileSystemRights & rights) != 0) return false;
            }
            return true;
        }
        // True when only SYSTEM, Administrators and TrustedInstaller own and can change the item and every folder up to and
        // including root, nothing on that way is a link, and nobody else can rename root away under its parent.
        public static bool AdministratorsOnly(string path, string root)
        {
            try {
                string full = Path.GetFullPath(path).TrimEnd('\\'), top = Path.GetFullPath(root).TrimEnd('\\');
                if (!full.Equals(top, StringComparison.OrdinalIgnoreCase) && !full.StartsWith(top + "\\", StringComparison.OrdinalIgnoreCase)) return false;
                HashSet<string> trusted = TrustedSids();
                for (string current = full; ; current = Path.GetDirectoryName(current)) {
                    bool folder = Directory.Exists(current);
                    if (!folder && !File.Exists(current)) return false;
                    if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) return false;
                    FileSystemSecurity security = folder ? (FileSystemSecurity)Directory.GetAccessControl(current, AccessControlSections.Access | AccessControlSections.Owner)
                        : File.GetAccessControl(current, AccessControlSections.Access | AccessControlSections.Owner);
                    if (!OnlyTrusted(security, trusted, WriteRights, true)) return false;
                    if (current.Equals(top, StringComparison.OrdinalIgnoreCase)) break;
                }
                string parent = Path.GetDirectoryName(top);
                return parent == null || OnlyTrusted(Directory.GetAccessControl(parent, AccessControlSections.Access | AccessControlSections.Owner), trusted, ParentRights, true);
            }
            catch (IOException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
            catch (ArgumentException) { return false; }
            catch (NotSupportedException) { return false; }
            catch (InvalidOperationException) { return false; }
            catch (SystemException) { return false; }
        }

        // ---- Verification -------------------------------------------------------------------------------------------
        static string Hex(byte[] hash) { return BitConverter.ToString(hash).Replace("-", "").ToLowerInvariant(); }
        static string Sha256(Stream stream) { using (SHA256 sha = SHA256.Create()) return Hex(sha.ComputeHash(stream)); }
        static string Sha256(byte[] bytes) { using (SHA256 sha = SHA256.Create()) return Hex(sha.ComputeHash(bytes)); }
        // The PE machine of a DLL image, or 0.
        public static ushort Machine(byte[] image)
        {
            if (image == null || image.Length < 0x40) return 0;
            int header = BitConverter.ToInt32(image, 0x3C);
            if (header < 0 || header + 6 > image.Length || image[header] != 'P' || image[header + 1] != 'E' || image[header + 2] != 0 || image[header + 3] != 0) return 0;
            return BitConverter.ToUInt16(image, header + 4);
        }
        static bool Linked(string path)
        {
            for (string current = Path.GetFullPath(path); !String.IsNullOrEmpty(current); current = Path.GetDirectoryName(current))
                if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) return true;
            return false;
        }
        // The DLL held open so that it cannot change until the caller closes it, when it matches the pin. Otherwise null.
        static FileStream OpenVerified(string path, Package package, out string reason)
        {
            reason = null;
            FileStream stream = null;
            try {
                if (String.IsNullOrEmpty(path) || !File.Exists(path)) { reason = NotInstalled; return null; }
                if (Linked(path)) { reason = Tampered; return null; }
                stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
                if (stream.Length != package.DllBytes) { reason = Tampered; return null; }
                byte[] image = new byte[stream.Length];
                int read = 0, count;
                while (read < image.Length && (count = stream.Read(image, read, image.Length - read)) > 0) read += count;
                if (read != image.Length || Sha256(image) != package.DllSha256 || MachineName(Machine(image)) != package.Architecture) { reason = Tampered; return null; }
                FileStream verified = stream; stream = null;
                return verified;
            }
            catch (IOException error) { reason = "Couldn't read WebP support: " + error.Message; return null; }
            catch (UnauthorizedAccessException error) { reason = "Couldn't read WebP support: " + error.Message; return null; }
            finally { if (stream != null) stream.Dispose(); }
        }
        // The per-user copy for an architecture is in place and matches its pin.
        public static bool Installed(string architecture, out string reason)
        {
            PinSet set = Pins;
            Package package;
            if (set == null) { reason = Unconfigured; return false; }
            if (!set.Packages.TryGetValue(architecture ?? "", out package)) { reason = NoBuild; return false; }
            string folder = UserFolder(architecture);
            using (FileStream stream = OpenVerified(folder == null ? null : Path.Combine(folder, set.Dll), package, out reason)) return stream != null;
        }
        public static bool Installed(string architecture) { string reason; return Installed(architecture, out reason); }

        // ---- Loading ------------------------------------------------------------------------------------------------
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)] static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, ExactSpelling = true, BestFitMapping = false)] static extern IntPtr GetProcAddress(IntPtr module, string name);
        [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr module);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)] static extern uint GetModuleFileNameW(IntPtr module, StringBuilder path, uint size);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int VersionFunction();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FeaturesFunction(IntPtr data, UIntPtr size, ref Features features, int version);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr DecodeFunction(IntPtr data, UIntPtr size, IntPtr output, UIntPtr outputSize, int stride);
        // struct WebPBitstreamFeatures from src/webp/decode.h in libwebp 1.6.0: 40 bytes.
        [StructLayout(LayoutKind.Sequential)] struct Features { public int Width, Height, HasAlpha, HasAnimation, Format; public uint Pad0, Pad1, Pad2, Pad3, Pad4; }

        // The decoder is loaded on first use. A failure is not remembered, so an install takes effect at once.
        public static bool Available { get { string reason; return TryLoad(out reason); } }
        public static bool TryLoad(out string reason)
        {
            lock (sync) {
                if (module != IntPtr.Zero) { reason = null; return true; }
                reason = problem = Load();
                return module != IntPtr.Zero;
            }
        }
        // The DLL this process loaded, or null.
        public static string LoadedFrom { get { lock (sync) return loadedFrom; } }
        public static string LastProblem { get { lock (sync) return problem; } }
        static T Bind<T>(IntPtr library, string name) where T : class
        {
            IntPtr address = GetProcAddress(library, name);
            return address == IntPtr.Zero ? null : Marshal.GetDelegateForFunctionPointer(address, typeof(T)) as T;
        }
        static string Load()
        {
            PinSet set = Pins;
            if (set == null) return Unconfigured;
            string architecture = ProcessArchitecture;
            Package package;
            if (architecture == null || !set.Packages.TryGetValue(architecture, out package)) return NoBuild;
            string folder, reason;
            bool elevated = Elevated;
            if (elevated) {
                reason = CodeRefusal;
                if (reason != null) return reason;
                reason = PrepareSharedCopy(set, package, architecture, out folder);
                if (reason != null) return reason;
            }
            else folder = UserFolder(architecture);
            if (folder == null) return NotInstalled;
            string path = Path.GetFullPath(Path.Combine(folder, set.Dll));
            IntPtr loaded;
            using (FileStream held = OpenVerified(path, package, out reason)) {
                if (held == null) return reason;
                if (elevated && !AdministratorsOnly(path, SharedBase)) return ElevatedRefused;
                // By full path. The DLL imports only KERNEL32, which comes from System32 like every dependency here.
                loaded = LoadLibraryExW(path, IntPtr.Zero, SearchSystem32);
                if (loaded == IntPtr.Zero) return "Windows could not load WebP support (error " + Marshal.GetLastWin32Error().ToString(CultureInfo.InvariantCulture) + ").";
            }
            try {
                StringBuilder name = new StringBuilder(32768);
                uint length = GetModuleFileNameW(loaded, name, (uint)name.Capacity);
                if (length == 0 || !String.Equals(Path.GetFullPath(name.ToString(0, (int)length)), path, StringComparison.OrdinalIgnoreCase)) { FreeLibrary(loaded); return OtherCopy; }
                VersionFunction version = Bind<VersionFunction>(loaded, "WebPGetDecoderVersion");
                FeaturesFunction features = Bind<FeaturesFunction>(loaded, "WebPGetFeaturesInternal");
                DecodeFunction decode = Bind<DecodeFunction>(loaded, "WebPDecodeRGBAInto");
                if (version == null || features == null || decode == null || version() != set.DecoderVersion) { FreeLibrary(loaded); return Tampered; }
                module = loaded; getFeatures = features; decodeInto = decode; loadedFrom = path;
                return null;
            }
            catch (Exception error) { FreeLibrary(loaded); return "Windows could not load WebP support: " + error.Message; }
        }
        // Why BetterIcon running as administrator could not load WebP support now, or null. It changes and loads nothing, so
        // a preview without elevation and the elevated pass that follows it decide alike: the elevated pass makes its copy
        // from the per-user one (PrepareSharedCopy) on these same conditions.
        public static string SharedProblem
        {
            get {
                PinSet set = Pins;
                if (set == null) return Unconfigured;
                string architecture = ProcessArchitecture;
                Package package;
                if (architecture == null || !set.Packages.TryGetValue(architecture, out package)) return NoBuild;
                string refusal = CodeRefusal;
                if (refusal != null) return refusal;
                string shared = SharedBase, reason, path = Path.Combine(SharedFolder(architecture), set.Dll);
                if (!Directory.Exists(shared) || !AdministratorsOnly(shared, shared)) return SharedUnprotected;
                using (FileStream existing = OpenVerified(path, package, out reason))
                    if (existing != null && AdministratorsOnly(path, shared)) return null;
                string user = UserFolder(architecture);
                using (FileStream copy = OpenVerified(user == null ? null : Path.Combine(user, set.Dll), package, out reason))
                    return copy != null ? null : reason ?? NotInstalled;
            }
        }
        // An elevated process: the copy in the administrators-only shared folder, made from the per-user copy when needed.
        // The per-user bytes are read once and checked against the pin before they are written. Only the DLL is copied:
        // a licence file in the per-user folder is the user's to change, and could be a link to a file only administrators
        // may read. The licences stay beside the per-user copy and in THIRD-PARTY-NOTICES.md.
        static string PrepareSharedCopy(PinSet set, Package package, string architecture, out string folder)
        {
            folder = null;
            string shared = SharedBase, target = SharedFolder(architecture), path = Path.Combine(target, set.Dll), reason;
            if (!Directory.Exists(shared) || !AdministratorsOnly(shared, shared)) return SharedUnprotected;
            using (FileStream existing = OpenVerified(path, package, out reason))
                if (existing != null && AdministratorsOnly(path, shared)) { folder = target; return null; }
            string user = UserFolder(architecture);
            byte[] bytes = null;
            using (FileStream source = OpenVerified(user == null ? null : Path.Combine(user, set.Dll), package, out reason)) {
                if (source == null) return reason ?? NotInstalled;
                bytes = new byte[source.Length];
                source.Position = 0;
                int read = 0, count;
                while (read < bytes.Length && (count = source.Read(bytes, read, bytes.Length - read)) > 0) read += count;
                if (read != bytes.Length || Sha256(bytes) != package.DllSha256) return Tampered;
            }
            try {
                Directory.CreateDirectory(target);
                if (!AdministratorsOnly(target, shared)) return SharedUnprotected;
                string temporary = Path.Combine(target, "." + Guid.NewGuid().ToString("N") + ".tmp");
                try {
                    File.WriteAllBytes(temporary, bytes);
                    if (File.Exists(path)) File.Replace(temporary, path, null); else File.Move(temporary, path);
                }
                finally { if (File.Exists(temporary)) File.Delete(temporary); }
            }
            catch (IOException error) { return "Couldn't copy WebP support to BetterIcon's shared folder: " + error.Message; }
            catch (UnauthorizedAccessException error) { return "Couldn't copy WebP support to BetterIcon's shared folder: " + error.Message; }
            if (!AdministratorsOnly(path, shared)) return SharedUnprotected;
            folder = target;
            return null;
        }

        // ---- Decoding -----------------------------------------------------------------------------------------------
        // WebPGetInfo also answers 1 for animated and some damaged files, so the features and the decode result decide.
        internal static Bitmap Decode(byte[] bytes, int width, int height)
        {
            FeaturesFunction features; DecodeFunction decode;
            lock (sync) { features = getFeatures; decode = decodeInto; }
            if (features == null || decode == null) throw new IOException(WebpArtwork.NoDecoder);
            GCHandle input = GCHandle.Alloc(bytes, GCHandleType.Pinned);
            try {
                Features info = new Features();
                if (features(input.AddrOfPinnedObject(), new UIntPtr((uint)bytes.Length), ref info, AbiVersion) != 0) throw new IOException(WebpArtwork.Damaged);
                if (info.HasAnimation != 0) throw new IOException(WebpArtwork.Animated);
                if (info.Width < 1 || info.Height < 1) throw new IOException(WebpArtwork.Damaged);
                if (info.Width > WebpArtwork.MaxSide || info.Height > WebpArtwork.MaxSide) throw new IOException(WebpArtwork.TooLarge);
                if (info.Width != width || info.Height != height) throw new IOException(WebpArtwork.Damaged);
                int stride = width * 4;
                byte[] pixels = new byte[stride * height];
                GCHandle output = GCHandle.Alloc(pixels, GCHandleType.Pinned);
                try {
                    IntPtr written = decode(input.AddrOfPinnedObject(), new UIntPtr((uint)bytes.Length), output.AddrOfPinnedObject(), new UIntPtr((uint)pixels.Length), stride);
                    if (written != output.AddrOfPinnedObject()) throw new IOException(WebpArtwork.Damaged);
                }
                finally { output.Free(); }
                // RGBA to the BGRA order of a 32-bit GDI+ bitmap. Both keep straight alpha.
                for (int i = 0; i < pixels.Length; i += 4) { byte red = pixels[i]; pixels[i] = pixels[i + 2]; pixels[i + 2] = red; }
                Bitmap result = new Bitmap(width, height, PixelFormat.Format32bppArgb);
                try {
                    BitmapData data = result.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
                    try { for (int y = 0; y < height; y++) Marshal.Copy(pixels, y * stride, IntPtr.Add(data.Scan0, y * data.Stride), stride); }
                    finally { result.UnlockBits(data); }
                    Bitmap done = result; result = null;
                    return done;
                }
                finally { if (result != null) result.Dispose(); }
            }
            finally { input.Free(); }
        }

        // ---- Download and install -----------------------------------------------------------------------------------
        // Copies the release zip of one architecture to destination and checks it against its pin.
        public static void Download(string architecture, string destination, CancellationToken token)
        {
            PinSet set = Pins;
            if (set == null) throw new IOException(Unconfigured);
            Package package;
            if (!set.Packages.TryGetValue(architecture ?? "", out package)) throw new IOException(NoBuild);
            string source = ReallyElevated ? null : Environment.GetEnvironmentVariable(SourceSeam);
            if (!String.IsNullOrWhiteSpace(source)) {
                // Tests use a local folder that holds the release files.
                string local = Path.Combine(source.Trim(), package.Zip);
                if (!File.Exists(local)) throw new IOException(DownloadFailed);
                File.Copy(local, destination, true);
            }
            else {
                Uri uri = new Uri(set.Release + package.Zip);
                string curl = Path.Combine(Environment.SystemDirectory, "curl.exe");
                if (File.Exists(curl)) {
                    ProcessStartInfo start = new ProcessStartInfo(curl, "--disable --fail --silent --location --proto =https --proto-redir =https --connect-timeout 10 --max-time 120 --max-filesize " +
                        package.ZipBytes.ToString(CultureInfo.InvariantCulture) + " --output \"" + destination + "\" \"" + uri.AbsoluteUri + "\"") { CreateNoWindow = true, UseShellExecute = false };
                    using (Process process = Process.Start(start))
                    using (token.Register(delegate { try { if (!process.HasExited) process.Kill(); } catch (InvalidOperationException) { } catch (System.ComponentModel.Win32Exception) { } })) {
                        process.WaitForExit();
                        token.ThrowIfCancellationRequested();
                        if (process.ExitCode != 0) throw new IOException(DownloadFailed);
                    }
                }
                else {
                    HttpWebRequest request = (HttpWebRequest)WebRequest.Create(uri);
                    request.Timeout = request.ReadWriteTimeout = 30000;
                    try {
                        using (token.Register(request.Abort))
                        using (WebResponse response = request.GetResponse())
                        using (Stream input = response.GetResponseStream())
                        using (FileStream output = File.Create(destination)) {
                            if (response.ResponseUri.Scheme != Uri.UriSchemeHttps) throw new IOException(DownloadFailed);
                            byte[] buffer = new byte[16384]; int read;
                            while ((read = input.Read(buffer, 0, buffer.Length)) != 0) {
                                if (output.Length + read > package.ZipBytes) throw new IOException(Mismatch);
                                output.Write(buffer, 0, read);
                            }
                        }
                    }
                    catch (WebException) { token.ThrowIfCancellationRequested(); throw new IOException(DownloadFailed); }
                }
            }
            CheckZip(destination, package);
        }
        static void CheckZip(string path, Package package)
        {
            FileInfo file = new FileInfo(path);
            if (!file.Exists || file.Length != package.ZipBytes) throw new IOException(Mismatch);
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
                if (Sha256(stream) != package.ZipSha256) throw new IOException(Mismatch);
        }
        // Installs one architecture's DLL and licence files from its release zip into the per-user folder, which BetterIcon
        // updates keep. Nothing changes unless the zip and the DLL in it match their pins.
        public static void Install(string zipPath, string architecture)
        {
            PinSet set = Pins;
            if (set == null) throw new IOException(Unconfigured);
            Package package;
            if (!set.Packages.TryGetValue(architecture ?? "", out package)) throw new IOException(NoBuild);
            string root = UserRoot;
            if (root == null) throw new IOException(Unconfigured);
            CheckZip(zipPath, package);
            Directory.CreateDirectory(root);
            if (Linked(root)) throw new IOException("Linked files or folders are not supported: " + root);
            string stage = Path.Combine(root, ".stage-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(stage);
            try {
                using (FileStream file = new FileStream(zipPath, FileMode.Open, FileAccess.Read, FileShare.Read))
                using (ZipArchive archive = new ZipArchive(file, ZipArchiveMode.Read)) {
                    foreach (string name in new[] { set.Dll }.Concat(Notices)) {
                        ZipArchiveEntry entry = archive.GetEntry(name);
                        if (entry == null) { if (name == set.Dll) throw new IOException(Mismatch); continue; }
                        if (entry.Length > 16 * 1024 * 1024) throw new IOException(Mismatch);
                        using (Stream input = entry.Open())
                        using (FileStream output = new FileStream(Path.Combine(stage, name), FileMode.CreateNew, FileAccess.Write)) input.CopyTo(output);
                    }
                }
                string reason;
                using (FileStream check = OpenVerified(Path.Combine(stage, set.Dll), package, out reason)) if (check == null) throw new IOException(reason == NotInstalled ? Mismatch : reason);
                string target = Path.Combine(root, architecture), old = null;
                if (Directory.Exists(target)) { old = Path.Combine(root, ".old-" + Guid.NewGuid().ToString("N")); Directory.Move(target, old); }
                try { Directory.Move(stage, target); stage = null; }
                catch { if (old != null && !Directory.Exists(target)) Directory.Move(old, target); throw; }
                if (old != null) {
                    try { Directory.Delete(old, true); }
                    catch (IOException) { }
                    catch (UnauthorizedAccessException) { }
                }
            }
            finally {
                if (stage != null && Directory.Exists(stage)) {
                    try { Directory.Delete(stage, true); }
                    catch (IOException) { }
                    catch (UnauthorizedAccessException) { }
                }
            }
        }
        // Downloads and installs one architecture.
        public static void InstallFromRelease(string architecture, CancellationToken token)
        {
            string root = UserRoot;
            if (root == null) throw new IOException(Unconfigured);
            Directory.CreateDirectory(root);
            string zip = Path.Combine(root, "." + Guid.NewGuid().ToString("N") + ".zip");
            try {
                Download(architecture, zip, token);
                token.ThrowIfCancellationRequested();
                Install(zip, architecture);
            }
            finally { if (File.Exists(zip)) File.Delete(zip); }
        }
        // The release zips this PC needs and their total size, for the offers.
        public static long DownloadBytes(IEnumerable<string> architectures)
        {
            PinSet set = Pins;
            if (set == null) return 0;
            long total = 0;
            foreach (string architecture in architectures) { Package package; if (set.Packages.TryGetValue(architecture, out package)) total += package.ZipBytes; }
            return total;
        }
    }
}
