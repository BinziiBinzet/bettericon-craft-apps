import AppKit
import WebKit

enum PopupTab: String {
    case launcher, manage
    var minimum: NSSize { self == .launcher ? NSSize(width: 300, height: 240) : NSSize(width: 790, height: 570) }
    var other: PopupTab { self == .launcher ? .manage : .launcher }
}

final class PopupWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    static func placed(size: NSSize, reserving other: NSSize, around anchor: NSPoint, in bounds: NSRect, belowMenu: Bool) -> NSRect {
        let top = belowMenu ? anchor.y : anchor.y + min(size.height, bounds.height) / 2
        return anchored(size: size, reserving: other, at: NSPoint(x: anchor.x, y: top), in: bounds)
    }
    // AppKit places windows on whole points. The first WebKit tab uses the same rounding at odd widths.
    static func divider(of frame: NSRect) -> NSPoint {
        NSPoint(x: frame.minX + floor(frame.width / 2), y: frame.maxY)
    }
    static func anchored(size: NSSize, reserving other: NSSize, at divider: NSPoint, in bounds: NSRect) -> NSRect {
        let width = min(floor(size.width), bounds.width), height = min(floor(size.height), bounds.height)
        let widest = min(max(width, floor(other.width)), bounds.width)
        let tallest = min(max(height, floor(other.height)), bounds.height)
        let left = floor(widest / 2)
        let x = min(max(bounds.minX + left, floor(divider.x)), bounds.maxX - (widest - left))
        let top = min(max(bounds.minY + tallest, floor(divider.y)), bounds.maxY)
        return NSRect(x: x - floor(width / 2), y: top - height, width: width, height: height)
    }
}

final class PopupSurface: NSView {
    var resized: (() -> Void)?
    private let edge: CGFloat = 8
    private func edges(_ p: NSPoint) -> (left: Bool, right: Bool, bottom: Bool, top: Bool) {
        let corner: CGFloat = 32
        let endX = p.x < corner || p.x > bounds.width - corner
        let endY = p.y < corner || p.y > bounds.height - corner
        let span = endX && endY ? corner : edge
        return (p.x <= span, p.x >= bounds.width - span, p.y <= span, p.y >= bounds.height - span)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        let e = edges(p)
        if bounds.contains(p) && (e.left || e.right || e.top || e.bottom) { return self }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        let mouse = NSEvent.mouseLocation
        let start = win.frame
        let p = convert(event.locationInWindow, from: nil)
        let (left, right, bottom, top) = edges(p)
        while let next = win.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let pos = NSEvent.mouseLocation
            let dx = pos.x - mouse.x
            let dy = pos.y - mouse.y
            var frame = start
            if left || right {
                frame.size.width = max(win.minSize.width, start.width + (left ? -dx : dx))
                if left { frame.origin.x = start.maxX - frame.width }
            }
            if bottom || top {
                frame.size.height = max(win.minSize.height, start.height + (bottom ? -dy : dy))
                if bottom { frame.origin.y = start.maxY - frame.height }
            }
            win.setFrame(frame, display: true)
        }
        resized?()
    }
}

final class ArtScheme: NSObject, WKURLSchemeHandler {
    enum Source {
        case file(URL)
        case app(URL)
    }
    private var sources = [String: Source]()
    private let cache = NSCache<NSString, NSData>()
    override init() {
        super.init()
        cache.totalCostLimit = 64 * 1024 * 1024
    }
    func reset() {
        sources.removeAll()
        cache.removeAllObjects()
    }
    func link(_ url: URL, system: Bool = false) -> String {
        let key = digest(Data(((system ? "app:" : "file:") + url.path).utf8))
        sources[key] = system ? .app(url) : .file(url)
        return "bettericon-art://image/" + key
    }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let source = sources[url.lastPathComponent] else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: {
            $0.name == "size"
        })?.value
        let pixels = min(4096, max(32, Int(raw ?? "") ?? 128))
        do {
            let mime: String
            let bytes: Data
            switch source {
            case .file(let file) where file.pathExtension.lowercased() == "png":
                bytes = try Artwork.load(file)
                mime = "image/png"
            default:
                let key = "\(url.lastPathComponent)-\(pixels)" as NSString
                if let hit = cache.object(forKey: key) {
                    bytes = hit as Data
                } else {
                    let image: NSImage?
                    switch source {
                    case .file(let file): image = NSImage(contentsOf: file)
                    case .app(let app): image = NSWorkspace.shared.icon(forFile: app.path)
                    }
                    guard let image else { throw Problem("Unreadable artwork.") }
                    bytes = try Artwork.png(image, pixels: pixels)
                    cache.setObject(bytes as NSData, forKey: key, cost: bytes.count)
                }
                mime = "image/png"
            }
            task.didReceive(
                URLResponse(url: url, mimeType: mime, expectedContentLength: bytes.count, textEncodingName: nil))
            task.didReceive(bytes)
            task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
