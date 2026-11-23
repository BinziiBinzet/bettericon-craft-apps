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
    private struct Handle {
        let area: NSRect
        let x: Int
        let y: Int

        var cursor: NSCursor {
            if #available(macOS 15, *) {
                let position: NSCursor.FrameResizePosition
                switch (x, y) {
                case (-1, -1): position = .bottomLeft
                case (1, -1): position = .bottomRight
                case (-1, 1): position = .topLeft
                case (1, 1): position = .topRight
                case (-1, 0): position = .left
                case (1, 0): position = .right
                case (0, -1): position = .bottom
                default: position = .top
                }
                return .frameResize(position: position, directions: .all)
            }
            if x == 0 { return .resizeUpDown }
            if y == 0 { return .resizeLeftRight }
            let symbol = x == y ? "arrow.down.left.and.arrow.up.right" : "arrow.up.left.and.arrow.down.right"
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return .crosshair }
            return NSCursor(image: image, hotSpot: NSPoint(x: image.size.width / 2, y: image.size.height / 2))
        }
    }
    private var drag: (handle: Handle, frame: NSRect, pointer: NSPoint)?
    private var handles: [Handle] {
        let w = bounds.width, h = bounds.height
        let e: CGFloat = 8, c: CGFloat = 28
        return [
            Handle(area: NSMakeRect(0, c, e, h - 2*c), x: -1, y: 0),
            Handle(area: NSMakeRect(w-e, c, e, h - 2*c), x: 1, y: 0),
            Handle(area: NSMakeRect(c, 0, w - 2*c, e), x: 0, y: -1),
            Handle(area: NSMakeRect(c, h-e, w - 2*c, e), x: 0, y: 1),
            Handle(area: NSMakeRect(0, 0, c, c), x: -1, y: -1),
            Handle(area: NSMakeRect(w-c, 0, c, c), x: 1, y: -1),
            Handle(area: NSMakeRect(0, h-c, c, c), x: -1, y: 1),
            Handle(area: NSMakeRect(w-c, h-c, c, c), x: 1, y: 1),
        ]
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        for handle in handles { addCursorRect(handle.area, cursor: handle.cursor) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if handles.contains(where: { $0.area.contains(local) }) { return self }
        return super.hitTest(point)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard let win = window, let handle = handles.first(where: { $0.area.contains(local) }) else {
            super.mouseDown(with: event)
            return
        }
        drag = (handle, win.frame, win.convertPoint(toScreen: event.locationInWindow))
    }
    override func mouseDragged(with event: NSEvent) {
        guard let win = window, let drag else { return }
        let current = win.convertPoint(toScreen: event.locationInWindow)
        var frame = drag.frame
        let x = drag.handle.x, y = drag.handle.y
        frame.size.width = max(win.minSize.width, frame.width + CGFloat(x) * (current.x - drag.pointer.x))
        frame.size.height = max(win.minSize.height, frame.height + CGFloat(y) * (current.y - drag.pointer.y))
        if x < 0 { frame.origin.x = drag.frame.maxX - frame.width }
        if y < 0 { frame.origin.y = drag.frame.maxY - frame.height }
        if frame != win.frame { win.setFrame(frame, display: true) }
    }
    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        mouseDragged(with: event)
        drag = nil
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
    private var generation = 0
    override init() {
        super.init()
        cache.totalCostLimit = 64 * 1024 * 1024
    }
    func reset() {
        sources.removeAll()
        cache.removeAllObjects()
        generation += 1
    }
    func link(_ url: URL, system: Bool = false) -> String {
        // An app's icon can change in place. A new address after each reset keeps WebKit from reusing the old image.
        let key = digest(Data(((system ? "app:\(generation):" : "file:") + url.path).utf8))
        sources[key] = system ? .app(url) : .file(url)
        return "bettericon-art://image/" + key
    }
    /// What an address draws: an artwork file, or the icon an app has now.
    func source(of link: String) -> (url: URL, app: Bool)? {
        guard let key = URL(string: link)?.lastPathComponent, let source = sources[key] else { return nil }
        switch source {
        case .file(let url): return (url, false)
        case .app(let url): return (url, true)
        }
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
            case .file(let file) where file.pathExtension.lowercased() == "webp":
                bytes = try Data(contentsOf: file)
                mime = "image/webp"
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
