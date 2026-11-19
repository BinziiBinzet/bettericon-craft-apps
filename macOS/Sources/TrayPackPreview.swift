import AppKit

/// NSMenu tracks the pointer in its own run-loop mode. Keep the preview outside its hit targets.
final class TrayPackPreview: NSObject, NSMenuDelegate {
    private let store: PublishedPacks
    private let queue = OperationQueue()
    private var generation = 0
    private var panel: NSPanel?
    private var timer: Timer?
    init(_ store: PublishedPacks) {
        self.store = store
        super.init()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
    }
    func dismiss() {
        generation += 1
        timer?.invalidate()
        queue.cancelAllOperations()
        panel?.orderOut(nil)
    }
    func menuDidClose(_ menu: NSMenu) { dismiss() }
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        dismiss()
        guard let pack = item?.representedObject as? Pack else { return }
        let token = generation
        let delay = Timer(timeInterval: 0.18, repeats: false) { [weak self] _ in
            guard let self = self, self.generation == token else { return }
            self.queue.addOperation { [weak self] in
                guard let self = self else { return }
                guard let url = try? self.store.preview(pack) else { return }
                RunLoop.main.perform(inModes: [.common, .eventTracking]) { [weak self] in
                    guard let self = self, self.generation == token, let image = NSImage(contentsOf: url) else { return }
                    self.display(image)
                }
            }
        }
        timer = delay
        RunLoop.main.add(delay, forMode: .common)
    }
    private func display(_ image: NSImage) {
        let size = NSSize(width: 214, height: 74)
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(pointer) })
            ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let x = pointer.x + size.width + 18 <= area.maxX ? pointer.x + 18 : pointer.x - size.width - 18
        let y = max(area.minY, min(pointer.y - size.height - 10, area.maxY - size.height))
        let panel = self.panel ?? NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.panel = panel
        panel.identifier = NSUserInterfaceItemIdentifier("BetterIconPackPreview")
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.backgroundColor = .windowBackgroundColor
        let art = NSImageView(frame: NSRect(x: 5, y: 5, width: 204, height: 64))
        art.image = image
        art.imageScaling = .scaleProportionallyUpOrDown
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.addSubview(art)
        panel.contentView = content
        panel.setFrameOrigin(NSPoint(x: max(area.minX, x), y: y))
        panel.orderFrontRegardless()
    }
}
