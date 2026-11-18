import AppKit
import ImageIO

enum Artwork {
    static let maxBytes = 16 * 1024 * 1024
    static let formats = ["svg", "ico", "png", "icns"]
    static func load(_ file: URL) throws -> Data {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
            size > 0, size <= maxBytes
        else { throw Problem("Choose a regular image file up to 16 MB.") }
        let data = try Data(contentsOf: file)
        guard data.count <= maxBytes else { throw Problem("The image exceeds 16 MB.") }
        return data
    }
    @discardableResult static func validate(_ data: Data, ext: String) throws -> Int {
        guard data.count > 0, data.count <= maxBytes, formats.contains(ext) else {
            throw Problem("Choose SVG, ICO, PNG or ICNS artwork up to 16 MB.")
        }
        if ext == "svg" {
            guard let xml = String(data: data, encoding: .utf8),
                !xml.contains("\0"),
                xml.range(of: #"<!\s*(DOCTYPE|ENTITY)"#, options: [.regularExpression, .caseInsensitive]) == nil
            else { throw Problem("Use a self-contained UTF-8 SVG.") }
            let parser = XMLParser(data: data)
            let checks = StaticSVG()
            parser.delegate = checks
            parser.shouldResolveExternalEntities = false
            guard parser.parse(), checks.valid, checks.sawRoot, let image = NSImage(data: data), image.isValid
            else { throw Problem("The SVG must be a self-contained, static image.") }
            return 4096
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let type = CGImageSourceGetType(source) as String?,
            type == ["png": "public.png", "ico": "com.microsoft.ico", "icns": "com.apple.icns"][ext]
        else { throw Problem("The file contents do not match the image extension.") }
        var maximum = 0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let p = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
                let w = p[kCGImagePropertyPixelWidth as String] as? Int,
                let h = p[kCGImagePropertyPixelHeight as String] as? Int,
                (1...4096).contains(w), (1...4096).contains(h)
            else { throw Problem("Artwork must be at most 4096 pixels per side.") }
            maximum = max(maximum, w, h)
        }
        guard maximum > 0,
            CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 32,
                ] as CFDictionary) != nil
        else { throw Problem("The image could not be decoded.") }
        return maximum
    }
    static func dimension(_ url: URL) -> Int {
        if url.pathExtension.lowercased() == "svg" { return 4096 }
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        return (0..<CGImageSourceGetCount(s)).compactMap { i -> Int? in
            let p = CGImageSourceCopyPropertiesAtIndex(s, i, nil) as? [String: Any]
            return max(
                p?[kCGImagePropertyPixelWidth as String] as? Int ?? 0,
                p?[kCGImagePropertyPixelHeight as String] as? Int ?? 0)
        }.max() ?? 0
    }
    static func png(_ image: NSImage, pixels: Int) throws -> Data {
        let size = min(4096, max(16, pixels))
        guard image.size.width > 0, image.size.height > 0,
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                bitsPerPixel: 0),
            let ctx = NSGraphicsContext(bitmapImageRep: bitmap)
        else { throw Problem("Could not render artwork.") }
        let scale = min(CGFloat(size) / image.size.width, CGFloat(size) / image.size.height)
        let w = image.size.width * scale
        let h = image.size.height * scale
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill(using: .copy)
        ctx.imageInterpolation = .high
        image.draw(
            in: NSRect(x: (CGFloat(size) - w) / 2, y: (CGFloat(size) - h) / 2, width: w, height: h),
            from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw Problem("Could not encode artwork.")
        }
        return data
    }
}

private final class StaticSVG: NSObject, XMLParserDelegate {
    var valid = true, sawRoot = false
    private var style: String?
    private let externalCSS = try! NSRegularExpression(
        pattern: #"url\s*\(\s*['"]?\s*(?!\s*#)[^)]*\)"#, options: .caseInsensitive)
    private func safeCSS(_ text: String) -> Bool {
        let clean = text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        if clean.contains("\\") || clean.contains("@") { return false }
        // Remove local fragment references first, then any remaining url() is external.
        let localRemoved = clean.replacingOccurrences(
            of: #"(?i)url\s*\(\s*['"]?#[\w:.-]+['"]?\s*\)"#, with: "", options: .regularExpression)
        return externalCSS.firstMatch(
            in: localRemoved, range: NSRange(localRemoved.startIndex..., in: localRemoved)) == nil
    }
    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String]
    ) {
        let tag = elementName.lowercased().components(separatedBy: ":").last ?? ""
        if !sawRoot {
            valid = tag == "svg"
            sawRoot = true
        }
        if [
            "script", "foreignobject", "iframe", "object", "embed", "audio", "video", "animate",
            "animatetransform", "animatemotion", "set",
        ].contains(tag) {
            valid = false
        }
        if tag == "style" { style = "" }
        for (key, value) in attributes {
            let attr = key.lowercased()
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if attr.hasPrefix("on") || attr == "xml:base" { valid = false }
            if attr == "href" || attr.hasSuffix(":href") || attr == "src" {
                if !v.hasPrefix("#")
                    && !(tag == "image"
                        && ["data:image/png;base64,", "data:image/jpeg;base64,"].contains(where: {
                            v.lowercased().hasPrefix($0)
                        }))
                {
                    valid = false
                }
            } else if !safeCSS(value) {
                valid = false
            }
        }
        if !valid { parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if style != nil { style?.append(string) } }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if style != nil { style?.append(String(decoding: data, as: UTF8.self)) }
    }
    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?
    ) {
        if elementName.lowercased() == "style", let text = style {
            if !safeCSS(text) {
                valid = false
                parser.abortParsing()
            }
            style = nil
        }
    }
    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        valid = false
        parser.abortParsing()
    }
}
