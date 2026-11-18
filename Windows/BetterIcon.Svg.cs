using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
using System.Xml;

namespace BetterIcon.Tray
{
    // Shared by native previews, pack validation and the PowerShell ICO bridge.
    // Third-party assemblies stay embedded so the installed launcher is one EXE.
    public static class SvgArtwork
    {
        const int MaxBytes = 16 * 1024 * 1024;
        static readonly object Gate = new object();
        static bool initialized;
        static void Initialize()
        {
            lock (Gate) {
                if (initialized) return;
                AppDomain.CurrentDomain.AssemblyResolve += ResolveAssembly;
                initialized = true;
            }
        }
        static Assembly ResolveAssembly(object sender, ResolveEventArgs args)
        {
            string name = new AssemblyName(args.Name).Name;
            using (Stream resource = typeof(SvgArtwork).Assembly.GetManifestResourceStream("BetterIcon.Dependencies." + name + ".dll")) {
                if (resource == null) return null;
                using (MemoryStream bytes = new MemoryStream()) { resource.CopyTo(bytes); return Assembly.Load(bytes.ToArray()); }
            }
        }
        public static Bitmap Render(byte[] bytes, int size)
        {
            if (bytes == null || bytes.Length == 0 || bytes.Length > MaxBytes) throw new IOException("Each SVG must be between 1 byte and 16 MB.");
            if (size < 1 || size > 4096) throw new ArgumentOutOfRangeException("size");
            Initialize();
            try { return SvgRenderer.Render(ReadDocument(bytes), size); }
            catch (IOException) { throw; }
            catch (Exception error) { throw new IOException("The selected SVG could not be rendered. " + error.Message, error); }
        }
        static XmlDocument ReadDocument(byte[] bytes)
        {
            XmlDocument document = new XmlDocument { XmlResolver = null };
            XmlReaderSettings settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Ignore, XmlResolver = null, MaxCharactersInDocument = MaxBytes, MaxCharactersFromEntities = 1024 };
            using (MemoryStream stream = new MemoryStream(bytes, false))
            using (XmlReader reader = XmlReader.Create(stream, settings)) document.Load(reader);
            if (document.DocumentElement == null || document.DocumentElement.LocalName != "svg" || document.DocumentElement.NamespaceURI != "http://www.w3.org/2000/svg")
                throw new IOException("The selected file is not an SVG image.");
            // Keep packs portable: local fragment references and embedded raster
            // images work, while linked files, stylesheets and network URLs do not.
            foreach (XmlNode node in document.SelectNodes("//*")) {
                if (node.LocalName == "script" || node.LocalName == "foreignObject") throw new IOException("Use a static SVG without scripts or embedded HTML.");
                foreach (XmlAttribute attribute in node.Attributes) {
                    if ((attribute.LocalName == "href" || attribute.LocalName == "src") && !LocalReference(attribute.Value)) throw new IOException("Embed linked images in the SVG before importing it.");
                    CheckCss(attribute.Value);
                }
                if (node.LocalName == "style") CheckCss(node.InnerText);
            }
            return document;
        }
        static bool LocalReference(string reference)
        {
            reference = reference.Trim();
            return reference.Length == 0 || reference.StartsWith("#", StringComparison.Ordinal) || Regex.IsMatch(reference, "^data:image/(png|jpeg|jpg);base64,", RegexOptions.IgnoreCase);
        }
        static void CheckCss(string css)
        {
            if (Regex.IsMatch(css, "@import", RegexOptions.IgnoreCase)) throw new IOException("Embed styles in the SVG before importing it.");
            foreach (Match match in Regex.Matches(css, "url\\(\\s*['\"]?([^)'\"]*)['\"]?\\s*\\)", RegexOptions.IgnoreCase))
                if (!LocalReference(match.Groups[1].Value)) throw new IOException("Embed linked images in the SVG before importing it.");
        }
    }
    static class SvgRenderer
    {
        // Delay JIT binding to Svg until SvgArtwork has registered its resolver.
        [MethodImpl(MethodImplOptions.NoInlining)]
        public static Bitmap Render(XmlDocument xml, int size)
        {
            Svg.SvgDocument.DisableDtdProcessing = true;
            Svg.SvgDocument.ResolveExternalXmlEntites = Svg.ExternalType.None;
            Svg.SvgDocument.ResolveExternalImages = Svg.ExternalType.None;
            Svg.SvgDocument.ResolveExternalElements = Svg.ExternalType.None;
            Svg.SvgDocument document = Svg.SvgDocument.Open(xml);
            document.Ppi = 96;
            SizeF dimensions = document.GetDimensions();
            if (dimensions.Width <= 0 || dimensions.Height <= 0 || Single.IsInfinity(dimensions.Width) || Single.IsInfinity(dimensions.Height) || Single.IsNaN(dimensions.Width) || Single.IsNaN(dimensions.Height))
                throw new IOException("The SVG needs a positive viewBox or canvas size.");
            float scale = size / Math.Max(dimensions.Width, dimensions.Height);
            int width = Math.Max(1, (int)Math.Round(dimensions.Width * scale));
            int height = Math.Max(1, (int)Math.Round(dimensions.Height * scale));
            using (Bitmap artwork = document.Draw(width, height)) {
                if (artwork == null) throw new IOException("The SVG has no renderable canvas.");
                Bitmap output = new Bitmap(size, size);
                using (Graphics graphics = Graphics.FromImage(output)) {
                    graphics.Clear(Color.Transparent);
                    graphics.CompositingMode = CompositingMode.SourceCopy;
                    graphics.DrawImageUnscaled(artwork, (size - width) / 2, (size - height) / 2);
                }
                return output;
            }
        }
    }
}
