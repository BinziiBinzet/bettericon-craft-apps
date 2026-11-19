import AppKit
import UniformTypeIdentifiers
import WebKit

struct Installation {
    let resources: URL
    let state: URL
    let catalog: AppCatalog
    let fixture: Bool
    var notificationName: Notification.Name {
        .init("com.omegadarling.bettericon." + digest(Data(state.standardizedFileURL.path.utf8)))
    }
    init(resources: URL, fixture: URL? = nil) throws {
        self.resources = resources
        if let fixture {
            let user = fixture.appendingPathComponent("Applications")
            let all = fixture.appendingPathComponent("Shared")
            for folder in [user, all] {
                var dir: ObjCBool = false
                guard fm.fileExists(atPath: folder.path, isDirectory: &dir), dir.boolValue else {
                    throw Problem("A fixture requires both Applications and Shared directories.")
                }
            }
            state = fixture.appendingPathComponent("State")
            catalog = AppCatalog(locations: [(user, .personal), (all, .shared)])
        } else {
            state = try fm.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("BetterIcon")
            catalog = AppCatalog()
        }
        self.fixture = fixture != nil
    }
}

final class Application: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler,
    WKNavigationDelegate
{
    let install: Installation
    let library: PackLibrary, icons: AppIcons
    let published: PublishedPacks
    var builtins: [Pack]
    private lazy var trayPreview = TrayPackPreview(published)
    private let previewQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private var fileSelection: Pack {
        packs.first { $0.id == prefs.fileSelected && $0.status != "Download" } ?? .defaults
    }
    var prefs: Preferences
    private var packs: [Pack] { library.visible(builtins) }
    private var fallback: Pack { packs.first { $0.id == "Craft-Icons-Zach/Cardboard" && $0.status != "Download" } ?? .defaults }
    private var selected: Pack { packs.first { $0.id == prefs.selected && $0.status != "Download" && $0.canApps } ?? fallback }
    private var apps = [AppEntry](), maxSize = 1024
    private var brandURLs = [String: String]()
    let scheme = ArtScheme()
    private(set) var web: WKWebView!
    private(set) var window: PopupWindow!
    private var item: NSStatusItem!, globalKey: GlobalKey?
    private var ready = false, working = false, modal = false, nativePanel = false
    private var trackingStatusMenu = false
    private var activeTab = PopupTab.launcher
    private var status = "Changes are reviewed before they are applied.", keyStatus = ""
    private var editing: Pack?, files = [String: URL]()
    private var appearanceObserver: NSKeyValueObservation?
    private var voiceOverObserver: NSKeyValueObservation?
    private var displayedSize = NSSize.zero
    private let startHidden: Bool
    private static let projectURL = URL(string: "https://github.com/BinziiBinzet/bettericon-craft-apps")!
    private let openProjectURL: (URL) -> Bool
    private let presentWindow: (NSWindow) -> Void
    private var menuBlocks = [() -> Void]()
    let version: String
    init(_ install: Installation, hidden: Bool = false, presentWindow: @escaping (NSWindow) -> Void = {
        NSApp.activate(ignoringOtherApps: true)
        $0.makeKeyAndOrderFront(nil)
    }, openProjectURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) throws {
        self.install = install
        self.presentWindow = presentWindow
        self.openProjectURL = openProjectURL
        startHidden = hidden
        let info = try Data(
            contentsOf: install.resources.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        let metadata = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any]
        guard let release = metadata?["CFBundleShortVersionString"] as? String else {
            throw Problem("Missing BetterIcon release version.")
        }
        version = release
        prefs = try saved(
            Preferences.self, at: install.state.appendingPathComponent("preferences.json"), fallback: Preferences()
        )
        library = try PackLibrary(install.state.appendingPathComponent("Packs"))
        icons = AppIcons(install.state.appendingPathComponent("App Icons"))
        published = try PublishedPacks(resources: install.resources, state: install.state)
        builtins = try published.list()
        library.projectKeys = Set(published.formats.map(\.Key))
        library.projectApps = Set(published.formats.map(\.Application))
        super.init()
        migratePackSelections()
    }

    private func migratePackSelections() {
        var changed = false
        for pack in builtins where !pack.previousIDs.isEmpty {
            if pack.previousIDs.contains(prefs.selected) {
                prefs.selected = pack.id
                changed = true
            }
            if let id = prefs.fileSelected, pack.previousIDs.contains(id) {
                prefs.fileSelected = pack.id
                changed = true
            }
        }
        if changed { savePrefs() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(scheme, forURLScheme: "bettericon-art")
        configuration.userContentController.add(self, name: "betterIcon")
        web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.underPageBackgroundColor = .clear
        let preferred = prefs.windowSize(for: .launcher)
        let available = NSScreen.main?.visibleFrame.size ?? preferred
        let size = NSSize(width: min(preferred.width, available.width), height: min(preferred.height, available.height))
        window = PopupWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .resizable],
            backing: .buffered, defer: false)
        window.title = "BetterIcon for ArtCraft"
        window.identifier = .init("BetterIcon")
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        let surface = PopupSurface(frame: NSRect(origin: .zero, size: size))
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 32
        surface.layer?.masksToBounds = true
        surface.resized = { [weak self] in self?.rememberSize() }
        web.frame = surface.bounds
        web.autoresizingMask = [.width, .height]
        surface.addSubview(web)
        window.contentView = surface
        displayedSize = window.frame.size
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "BetterIcon for ArtCraft"
            button.setAccessibilityLabel("BetterIcon for ArtCraft")
        }
        if !install.fixture {
            globalKey = GlobalKey { [weak self] in self?.show(atCursor: true) }
            voiceOverObserver = NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.registerKey() }
            }
            registerKey()
        }
        style()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(otherInstance(_:)), name: install.notificationName, object: nil)
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.style()
                if self?.working == false { self?.render() }
            }
        }
        let html = install.resources.appendingPathComponent("Web/index.html")
        web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        if !startHidden { show() }
    }
    @objc private func otherInstance(_ note: Notification) {
        if note.object as? String == "show" {
            show()
            return
        }
        if !working && !modal && !nativePanel && !trackingStatusMenu { refresh() }
    }
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .linkActivated,
            navigationAction.sourceFrame.isMainFrame, navigationAction.targetFrame?.isMainFrame == true,
            navigationAction.request.url == Self.projectURL
        {
            decisionHandler(.cancel)
            if !working && !modal && !nativePanel && !openProjectURL(Self.projectURL) {
                report("Could not open the BetterIcon project in your browser.")
            }
            return
        }
        let page = install.resources.appendingPathComponent("Web/index.html").standardizedFileURL
        decisionHandler(
            navigationAction.request.url?.standardizedFileURL == page
                && navigationAction.targetFrame?.isMainFrame == true ? .allow : .cancel)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if working || modal || nativePanel {
            show()
            return .terminateCancel
        }
        return .terminateNow
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !modal && !working { sender.orderOut(nil) }
        return false
    }
    func applicationDidResignActive(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, !NSApp.isActive, !self.modal, !self.nativePanel, !self.trackingStatusMenu, !self.working,
                self.item.button?.window?.frame.contains(NSEvent.mouseLocation) != true
            else { return }
            self.window.orderOut(nil)
        }
    }
    func windowDidEndLiveResize(_ notification: Notification) { rememberSize() }
    private func rememberSize() {
        let size = window.frame.size
        guard window.isVisible, size != displayedSize else { return }
        prefs.setWindowSize(size, for: activeTab)
        fitAtDivider(activeTab)
        do { try updatePreferences(install.state) { $0.setWindowSize(size, for: activeTab) } }
        catch {
            status = "Could not save window size: " + error.localizedDescription
            call("showError", ["id": "status", "message": status])
        }
    }
    private var shortcutText: String { prefs.hotkey.displayText(registered: globalKey?.isRegistered ?? true) }
    private func registerKey() {
        guard let globalKey else { return }
        do {
            keyStatus = try globalKey.use(prefs.hotkey)
        } catch { keyStatus = error.localizedDescription }
        call("keyStatus", ["message": keyStatus, "shortcut": shortcutText])
    }
    private func savePrefs(adding: [String] = [], removing: [String] = []) {
        do {
            let ui = prefs
            prefs = try updatePreferences(install.state) { stored in
                let defaults = stored.defaultPaths.union(adding).subtracting(removing)
                stored = ui
                stored.defaultPaths = defaults
            }
        } catch {
            status = "Could not save preferences: " + error.localizedDescription
            call("showError", ["id": "status", "message": status])
        }
    }
    private var dark: Bool {
        prefs.theme == "Dark"
            || (prefs.theme == "System"
                && NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }
    private let colors = ["clay", "copper", "mauve", "ochre", "sage", "slate", "stone", "teal"]
    private func style() {
        window.appearance = prefs.theme == "System" ? nil : NSAppearance(named: dark ? .darkAqua : .aqua)
        let variant = prefs.variant == "auto" ? (dark ? "dark" : "light") : prefs.variant
        let folder = install.resources.appendingPathComponent("Brand")
        let name = "betterIcon_icon_\(prefs.color)_\(variant).png"
        if let image = NSImage(contentsOf: folder.appendingPathComponent("32px/" + name)) {
            image.size = NSSize(width: 19, height: 19)
            image.isTemplate = false
            item.button?.image = image
        }
        NSApp.applicationIconImage = NSImage(contentsOf: folder.appendingPathComponent(name))
        let surface = dark ? NSColor(red: 31 / 255, green: 39 / 255, blue: 48 / 255, alpha: 1) : .white
        window.contentView?.layer?.backgroundColor = surface.cgColor
    }
    private func apply(_ frame: NSRect, for tab: PopupTab) {
        activeTab = tab
        window.minSize = NSSize(width: min(tab.minimum.width, frame.width), height: min(tab.minimum.height, frame.height))
        window.setFrame(frame, display: true)
        displayedSize = window.frame.size
    }
    private func fitAtDivider(_ tab: PopupTab) {
        let divider = PopupWindow.divider(of: window.frame)
        let inside = NSPoint(x: divider.x, y: divider.y - 0.5)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(inside) }) ?? window.screen ?? NSScreen.main else { return }
        apply(PopupWindow.anchored(size: prefs.windowSize(for: tab), reserving: prefs.windowSize(for: tab.other),
            at: divider, in: screen.visibleFrame), for: tab)
    }
    func show(atCursor: Bool = false, tab: PopupTab = .launcher) {
        guard window != nil else { return }
        if modal || nativePanel {
            presentWindow(window)
            return
        }
        let mouse = NSEvent.mouseLocation
        let buttonFrame = item.button?.window?.frame
        let screen =
            (atCursor ? NSScreen.screens.first { $0.frame.contains(mouse) } : item.button?.window?.screen)
            ?? NSScreen.main
        guard let bounds = screen?.visibleFrame else { return }
        let point =
            atCursor
            ? mouse
            : NSPoint(x: buttonFrame?.midX ?? bounds.midX, y: min(buttonFrame?.minY ?? bounds.maxY, bounds.maxY))
        if window.isVisible && !atCursor && tab != activeTab {
            fitAtDivider(tab)
        } else {
            apply(PopupWindow.placed(size: prefs.windowSize(for: tab), reserving: prefs.windowSize(for: tab.other),
                around: point, in: bounds, belowMenu: !atCursor), for: tab)
        }
        presentWindow(window)
        window.makeFirstResponder(web)
        call("reset", ["pageName": tab.rawValue])
    }
    @objc private func statusClick() {
        if NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        {
            statusMenu()
            return
        }
        if window.isVisible && !working && !modal && !nativePanel { window.orderOut(nil) }
        else { show(tab: prefs.largerTab) }
    }
    private func call(_ fn: String, _ args: [String: Any] = [:]) {
        guard ready else { return }
        let order: [String: [String]] = [
            "update": ["next"], "reset": ["pageName"], "tab": ["name"], "busy": ["message"], "editor": ["info"],
            "assignment": ["craft", "name"], "hotkey": ["info"], "keyStatus": ["message", "shortcut"], "doneDialog": ["id"],
            "showError": ["id", "message"], "packPreview": ["id", "token", "url"],
        ]
        guard let keys = order[fn] else { return }
        web.callAsyncJavaScript(
            "window.betterIcon." + fn + "(" + keys.joined(separator: ",") + ")", arguments: args, in: nil,
            in: .page
        ) { result in
            if case .failure(let e) = result { NSLog("BetterIcon interface: %@", e.localizedDescription) }
        }
    }
    private func rangeForSelection() {
        let largest = selected.icons.values.map(Artwork.dimension).max() ?? 0
        let originals =
            apps.map { app -> Int in
                if let file = icons.defaultPreview(app) { return Artwork.dimension(file) }
                return NSWorkspace.shared.icon(forFile: app.url.path).representations.map(\.pixelsWide).filter {
                    $0 > 0
                }.max() ?? 0
            }.max() ?? 0
        maxSize = min(4096, max(48, largest, originals))
        prefs.size = min(maxSize, max(24, prefs.size))
    }
    private func render() {
        guard ready else { return }
        let pack = selected
        func original(_ app: AppEntry) -> String {
            if let saved = icons.defaultPreview(app) { return scheme.link(saved) }
            return scheme.link(app.url, system: true)
        }
        let tiles: [[String: String]] = apps.map { app in
            let image =
                prefs.defaultPaths.contains(app.url.path)
                ? original(app) : (pack.icons[app.craft].map { scheme.link($0) } ?? original(app))
            return [
                "id": app.url.path, "name": app.name, "craft": app.craft, "hint": app.name + "\n" + app.url.path,
                "image": image,
            ]
        }
        var preview: [[String: String]] = []
        if pack.isDefault {
            var seen = Set<String>()
            for app in apps where seen.insert(app.craft).inserted {
                preview.append(["id": app.craft, "name": app.craft, "craft": app.craft, "image": original(app)])
            }
        } else {
            preview = pack.icons.map {
                ["id": $0.key, "name": $0.key, "craft": $0.key, "image": scheme.link($0.value)]
            }
        }
        for color in colors {
            for v in ["dark", "light"] {
                let key = color + "_" + v
                brandURLs[key] = scheme.link(
                    install.resources.appendingPathComponent("Brand/32px/betterIcon_icon_" + key + ".png"))
            }
        }
        let settings = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(prefs))) ?? [:]
        let fileArt = published.fileArt(fileSelection)
        let fileSamples = fileArt.sorted { $0.key < $1.key }.map { ["name": $0.key, "image": scheme.link($0.value)] }
        let state: [String: Any] = [
            "apps": tiles, "preview": preview.sorted { ($0["name"] ?? "") < ($1["name"] ?? "") },
            "packs": packs.map(\.model), "filePack": fileSelection.model,
            "fileCount": fileArt.count, "fileSamples": fileSamples, "fileAction": "Choose project files…",
            "pack": pack.model,
            "prefs": settings, "maxSize": maxSize, "dark": dark, "brands": brandURLs, "version": version,
            "status": status, "shortcut": shortcutText, "projectURL": Self.projectURL.absoluteString,
        ]
        call("update", ["next": state])
    }
    private func background<T>(
        _ message: String, work: @escaping () throws -> T, done: @escaping (T) -> Void,
        onError: ((Error) -> Void)? = nil
    ) {
        guard !working else { return }
        working = true
        call("busy", ["message": message])
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work() }
            DispatchQueue.main.async {
                self.working = false
                switch result {
                case .success(let value): done(value)
                case .failure(let error):
                    if let onError { onError(error) } else { self.report(error.localizedDescription) }
                }
                if !self.working {
                    self.call("busy", ["message": ""])
                    self.render()
                }
            }
        }
    }
    private func refresh() {
        let folders = prefs.folders
        background("Finding installed apps…", work: { self.install.catalog.discover(extraFolders: folders) }) {
            apps in
            if let stored = try? saved(
                Preferences.self, at: self.install.state.appendingPathComponent("preferences.json"),
                fallback: self.prefs)
            {
                self.prefs.defaultPaths = stored.defaultPaths
            }
            self.apps = apps
            self.scheme.reset()
            self.rangeForSelection()
        }
    }
    private func report(_ message: String) {
        status = message
        _ = alert("BetterIcon", message, buttons: ["OK"])
    }
    @discardableResult private func alert(
        _ title: String, _ info: String, buttons: [String], accessory: NSView? = nil
    ) -> Int {
        nativePanel = true
        defer { nativePanel = false }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.icon = NSApp.applicationIconImage
        for label in buttons { a.addButton(withTitle: label) }
        if buttons.last == "Cancel" { a.buttons.last?.keyEquivalent = "\u{1b}" }
        a.accessoryView = accessory
        a.window.appearance = window.appearance
        return a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }
    private func chooseFile(folder: Bool = false, zip: Bool = false) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folder
        panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = false
        if !folder {
            panel.allowedContentTypes = (zip ? ["zip"] : Artwork.formats).compactMap {
                UTType(filenameExtension: $0)
            }
        }
        nativePanel = true
        defer { nativePanel = false }
        return panel.runModal() == .OK ? panel.url : nil
    }
    private func changeSelection(
        _ id: String, message: String = "Icon pack selected.", group: String = "apps"
    ) {
        guard let pack = packs.first(where: { $0.id == id }),
              group == "files" ? (pack.canFiles || pack.isDefault) : pack.canApps else { return }
        let needsDownload = ["Download", "Update available"].contains(pack.status)
        if needsDownload {
            background("Downloading " + pack.title + "…", work: { try self.published.list("acquire", id: id) }) { rows in
                self.builtins = rows
                self.changeSelection(id, message: message, group: group)
            }
            return
        }
        let artwork = group == "files" ? published.fileArt(pack) : pack.icons
        background("Loading " + pack.title + "…", work: {
            for file in artwork.values {
                guard file.isFileURL, fm.isReadableFile(atPath: file.path), Artwork.dimension(file) > 0 else {
                    throw Problem("Pack artwork could not be loaded.")
                }
            }
        }, done: { _ in
            if group == "files" { self.prefs.fileSelected = id }
            else { self.prefs.selected = id; self.rangeForSelection() }
            self.status = message
            self.savePrefs()
        })
    }
    private func refreshPacks(revealManage: Bool = true) {
        if revealManage { show(tab: .manage) }
        background("Refreshing available icon packs…", work: { try self.published.list("refresh") }) { rows in
            self.builtins = rows
            self.status = "Available icon packs refreshed."
            self.migratePackSelections()
        }
    }
    private func preview(_ id: String, token: Int) {
        guard let pack = packs.first(where: { $0.id == id && $0.canPreview }) else { return }
        previewQueue.cancelAllOperations()
        previewQueue.addOperation {
            guard let url = try? self.published.preview(pack) else { return }
            DispatchQueue.main.async {
                self.call("packPreview", ["id": id, "token": token, "url": self.scheme.link(url)])
            }
        }
    }
    private func reviewFiles(restore: Bool) {
        let pack = fileSelection
        let artwork = published.fileArt(pack)
        let formats = published.formats.filter { restore || artwork[$0.Key] != nil }
        guard !formats.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = restore ? "Choose project files to restore" : "Choose project files to change"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = formats.flatMap { [$0.Key] + ($0.Aliases ?? []) }.compactMap { UTType(filenameExtension: String($0.dropFirst())) }
        nativePanel = true
        let response = panel.runModal()
        nativePanel = false
        guard response == .OK else { return }
        let targets = panel.urls.compactMap { file -> AppEntry? in
            let ext = "." + file.pathExtension.lowercased()
            guard let format = formats.first(where: { $0.Key == ext || ($0.Aliases ?? []).contains(ext) }) else { return nil }
            return AppEntry(name: file.lastPathComponent, craft: format.Key, url: file, launchURL: file,
                            bundleID: "", scope: .personal, isDocument: true)
        }
        let store = AppIcons(install.state.appendingPathComponent("Project File Icons"))
        let filePack = Pack(id: pack.id, name: pack.name, author: pack.author, icons: artwork)
        let plan = store.review(apps: targets, pack: filePack, scope: .personal, restore: restore)
        let count = plan.rows.filter(\.change).count
        let details = plan.rows.map { $0.app.name + " — " + $0.message }.joined(separator: "\n")
        guard count > 0 else { report(details); return }
        let verb = restore ? "Restore" : "Apply"
        guard alert(verb + " icons for these project files?", details, buttons: [verb, "Cancel"]) == 0 else { return }
        background("Updating project file icons…", work: { try store.perform(plan, apps: targets, pack: filePack) }) { result in
            self.status = "\(result.changed.count) project file icons updated."
            if !result.errors.isEmpty { self.report(result.errors.joined(separator: "\n")) }
        }
    }
    private func launch(_ app: AppEntry) {
        guard fm.fileExists(atPath: app.launchURL.path) else {
            report("App moved or removed. Refresh installed apps.")
            return
        }
        NSWorkspace.shared.openApplication(at: app.launchURL, configuration: NSWorkspace.OpenConfiguration()) {
            _, error in
            DispatchQueue.main.async {
                if let error { self.report(error.localizedDescription) } else { self.window.orderOut(nil) }
            }
        }
    }
    private func review(restore: Bool, only: String?) {
        guard !working else { return }
        let nUser = apps.filter { $0.scope == .personal && (only == nil || $0.craft == only) }.count
        let nShared = apps.filter { $0.scope == .shared && (only == nil || $0.craft == only) }.count
        let scopeButtons = ["All users (\(nShared))", "Current user (\(nUser))", "Cancel"]
        let choice = alert(
            restore ? "Restore icons in which location?" : "Apply icons in which location?",
            "All users includes the apps in /Applications. Current user includes your personal Applications folder and Desktop. The review lists the exact apps and Finder aliases.",
            buttons: scopeButtons)
        guard choice == 0 || choice == 1 else { return }
        let scope: Scope = choice == 0 ? .shared : .personal
        let pack = selected
        let folders = prefs.folders
        background(
            "Reviewing installed apps…",
            work: {
                self.icons.review(
                    apps: self.install.catalog.discover(extraFolders: folders), pack: pack, scope: scope,
                    restore: restore, only: only)
            }
        ) { plan in
            let count = plan.rows.filter(\.change).count
            let text = plan.rows.map { $0.app.name + "  —  " + $0.message + "\n" + $0.app.url.path }.joined(
                separator: "\n\n")
            let scroll = NSScrollView(
                frame: NSRect(x: 0, y: 0, width: 520, height: min(285, max(74, plan.rows.count * 46))))
            let view = NSTextView(frame: scroll.bounds)
            view.isEditable = false
            view.isSelectable = true
            view.font = NSFont.systemFont(ofSize: 12)
            view.autoresizingMask = [.width]
            view.string = text.isEmpty ? "No matching ArtCraft apps in this location." : text
            scroll.documentView = view
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let noun = count == 1 ? "icon" : "icons"
            let explanation =
                restore
                ? "Restore the artwork saved before BetterIcon first changed each item."
                : "macOS reads an app’s Finder custom icon across system views. A running app can supply its own Dock icon. Strict signature checks can flag Finder metadata while a custom icon is applied."
            let canRun = count > 0 || (restore && plan.rows.contains(where: \.alreadyDefault))
            let confirm =
                count == 0
                ? "Use original preview" : (restore ? "Restore \(count) \(noun)" : "Apply \(count) \(noun)")
            let ok = self.alert(
                restore ? "Review original icons" : "Review " + pack.title, explanation,
                buttons: canRun ? [confirm, "Cancel"] : ["Done"], accessory: scroll)
            guard canRun, ok == 0 else { return }
            self.background(
                restore ? "Restoring original icons…" : "Applying icons to installed apps…",
                work: {
                    try self.icons.perform(
                        plan, apps: self.install.catalog.discover(extraFolders: folders), pack: pack)
                }
            ) { result in
                self.apps = self.install.catalog.discover(extraFolders: folders)
                self.scheme.reset()
                self.status =
                    "\(result.changed.count) \(result.changed.count == 1 ? "icon" : "icons") \(restore ? "restored" : "applied")."
                self.savePrefs(adding: restore ? result.defaults : [], removing: restore ? [] : result.changed)
                if !result.errors.isEmpty {
                    self.report(self.status + "\n\n" + result.errors.joined(separator: "\n"))
                }
            }
        }
    }
    private func editor(_ mode: String, group: String = "apps") {
        let pack = group == "files" ? fileSelection : selected
        guard mode == "new" || (!pack.isDefault && (mode != "edit" || pack.personal)) else { return }
        editing = mode == "edit" ? pack : nil
        files = mode == "new" ? [:] : pack.icons.merging(pack.documents) { _, doc in doc }
        modal = true
        let name = mode == "edit" ? pack.name : library.copyName(mode == "new" ? .defaults : pack)
        call(
            "editor",
            [
                "info": [
                    "apps": Craft.names + published.formats.map(\.Key), "edit": editing != nil, "files": files.mapValues(\.lastPathComponent),
                    "name": name, "author": mode == "new" ? "" : pack.author,
                ] as [String: Any]
            ])
    }
    private func importPack(zip: Bool) {
        guard let source = chooseFile(folder: !zip, zip: zip) else { return }
        background("Importing icon pack…", work: { try self.library.importPack(source) }) { id in
            self.selectSaved(id, "Icon pack imported.")
        }
    }
    private func selectSaved(_ id: String, _ message: String, clearing: [String] = []) {
        if let pack = packs.first(where: { $0.id == id }), !pack.canApps {
            prefs.fileSelected = id
        } else { prefs.selected = id }
        rangeForSelection()
        status = message
        savePrefs(removing: clearing)
    }
    private func exportPack(group: String = "apps") {
        let pack = group == "files" ? fileSelection : selected
        guard pack.personal else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = pack.name + ".zip"
        nativePanel = true
        let ok = panel.runModal() == .OK
        nativePanel = false
        guard ok, let url = panel.url else { return }
        background("Exporting " + pack.name + "…", work: { try self.library.export(pack, to: url) }) { _ in
            self.status = "Exported " + url.lastPathComponent + "."
        }
    }
    private func chooseIcon(_ craft: String) {
        guard Craft.names.contains(craft), let url = chooseFile() else { return }
        let pack = selected
        let name = pack.personal ? pack.name : library.copyName(pack)
        var assignments = pack.icons.merging(pack.documents) { _, doc in doc }
        assignments[craft] = url
        let newFiles = assignments
        background(
            "Saving " + craft + " artwork…",
            work: {
                try self.library.store(
                    name: name, author: pack.author, files: newFiles, editing: pack.personal ? pack : nil)
            }
        ) { id in
            self.selectSaved(
                id, craft + " artwork saved. Apply icons to change the installed app.",
                clearing: self.apps.filter { $0.craft == craft }.map(\.url.path))
        }
    }
    private func unhide() {
        do {
            try library.restoreBuiltins()
            status = "Built-in packs restored."
            render()
        } catch { report(error.localizedDescription) }
    }
    private func openHotkey() {
        guard !working && !modal && !nativePanel else { return }
        modal = true
        call(
            "hotkey",
            [
                "info": [
                    "status": keyStatus,
                    "keys": KeyChoice.keys.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                ] as [String: Any]
            ])
    }
    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard message.frameInfo.isMainFrame, let data = message.body as? [String: Any],
            let action = data["action"] as? String
        else { return }
        if action == "ready" {
            ready = true
            render()
            call("reset", ["pageName": activeTab.rawValue])
            refresh()
            return
        }
        if action == "dialogClosed" {
            modal = false
            editing = nil
            files.removeAll()
            return
        }
        guard !working, !nativePanel else { return }
        let craft = data["craft"] as? String ?? ""
        switch action {
        case "tab":
            guard !modal, let name = data["name"] as? String, let tab = PopupTab(rawValue: name) else { return }
            if tab != activeTab { fitAtDivider(tab) }
            call("tab", ["name": activeTab.rawValue])
        case "hide": if !modal { window.orderOut(nil) }
        case "changeHotkey": openHotkey()
        case "launch": if let app = apps.first(where: { $0.url.path == data["id"] as? String }) { launch(app) }
        case "select": changeSelection(data["id"] as? String ?? "", group: data["group"] as? String ?? "apps")
        case "refreshPacks": if !modal { refreshPacks(revealManage: false) }
        case "previewPack": preview(data["id"] as? String ?? "", token: data["token"] as? Int ?? 0)
        case "reviewFiles": reviewFiles(restore: data["restore"] as? Bool ?? false)
        case "names":
            prefs.names = data["value"] as? Bool ?? true
            savePrefs()
            render()
        case "size":
            prefs.size = min(maxSize, max(24, data["value"] as? Int ?? 48))
            savePrefs()
            render()
        case "appearance":
            let order = ["Dark", "Light", "System"]
            prefs.theme = order[((order.firstIndex(of: prefs.theme) ?? 2) + 1) % 3]
            style()
            savePrefs()
            render()
        case "brand":
            guard let c = data["color"] as? String, colors.contains(c), let v = data["variant"] as? String,
                ["auto", "dark", "light"].contains(v)
            else { return }
            prefs.color = c
            prefs.variant = v
            style()
            savePrefs()
            render()
        case "editor": editor(data["mode"] as? String ?? "new", group: data["group"] as? String ?? "apps")
        case "pickAssignment":
            if modal, Craft.names.contains(craft) || library.projectKeys.contains(craft), let file = chooseFile() {
                files[craft] = file
                call("assignment", ["craft": craft, "name": file.lastPathComponent])
            }
        case "clearAssignment": if modal { files.removeValue(forKey: craft) }
        case "savePack":
            guard modal, let name = data["name"] as? String, let author = data["author"] as? String else { return }
            let files = self.files
            let edit = editing
            background(
                "Saving icon pack…",
                work: { try self.library.store(name: name, author: author, files: files, editing: edit) },
                done: { id in
                    self.call("doneDialog", ["id": "editor"])
                    self.selectSaved(id, "Icon pack saved.")
                },
                onError: { self.call("showError", ["id": "editorError", "message": $0.localizedDescription]) })
        case "saveKey":
            guard modal else { return }
            do {
                let choice = try JSONDecoder().decode(
                    KeyChoice.self, from: JSONSerialization.data(withJSONObject: data))
                guard KeyChoice.keys[choice.key] != nil else { throw Problem("Select a supported key.") }
                let registrationStatus = try globalKey?.use(choice)
                do {
                    _ = try updatePreferences(install.state) { $0.hotkey = choice }
                } catch {
                    if let globalKey, choice != prefs.hotkey {
                        _ = try? globalKey.use(KeyChoice(enabled: false))
                        registerKey()
                    }
                    throw error
                }
                prefs.hotkey = choice
                if let registrationStatus { keyStatus = registrationStatus }
                render()
                call("doneDialog", ["id": "hotkey"])
            } catch { call("showError", ["id": "keyError", "message": error.localizedDescription]) }
        case "import": importPack(zip: data["zip"] as? Bool ?? true)
        case "export": exportPack(group: data["group"] as? String ?? "apps")
        case "remove":
            let p = data["group"] as? String == "files" ? fileSelection : selected
            if !p.isDefault
                && alert(
                    "Remove " + p.name + "?",
                    p.personal
                        ? "Remove this personal pack from your library. Applied app icons keep their artwork."
                        : "Hide this built-in pack. Restore built-in packs brings it back.",
                    buttons: ["Remove pack", "Cancel"]) == 0
            {
                do {
                    try library.remove(p)
                    if p.id == prefs.fileSelected { prefs.fileSelected = nil }
                    if p.id == prefs.selected { prefs.selected = fallback.id }
                    status = "Pack removed."
                    rangeForSelection()
                    savePrefs()
                    render()
                } catch { report(error.localizedDescription) }
            }
        case "unhide": unhide()
        case "chooseIcon": chooseIcon(craft)
        case "review": review(restore: data["restore"] as? Bool ?? false, only: data["only"] as? String)
        default: break
        }
    }
    @objc private func menuAction(_ sender: NSMenuItem) {
        if menuBlocks.indices.contains(sender.tag) { menuBlocks[sender.tag]() }
    }
    func statusMenu(present: (NSMenu, NSStatusBarButton) -> Void = { menu, button in
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 3), in: button)
    }) {
        guard !trackingStatusMenu, let button = item?.button else { return }
        guard !modal && !nativePanel else {
            show()
            return
        }
        if working {
            show(tab: activeTab)
            return
        }
        menuBlocks.removeAll()
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, to parent: NSMenu, enabled: Bool = true, action: @escaping () -> Void)
            -> NSMenuItem
        {
            let entry = NSMenuItem(title: title, action: #selector(menuAction), keyEquivalent: "")
            entry.target = self
            entry.tag = menuBlocks.count
            menuBlocks.append(action)
            entry.isEnabled = enabled
            parent.addItem(entry)
            return entry
        }
        func sub(_ name: String) -> NSMenu {
            let entry = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            let child = NSMenu()
            child.autoenablesItems = false
            entry.submenu = child
            menu.addItem(entry)
            return child
        }
        _ = add("Open BetterIcon", to: menu) { self.show() }
        let launchMenu = sub("Launch an ArtCraft app")
        for app in apps {
            _ = add(app.name + (app.scope == .shared ? " (shared)" : ""), to: launchMenu) { self.launch(app) }
        }
        if apps.isEmpty { _ = add("No ArtCraft apps found", to: launchMenu, enabled: false) {} }
        _ = add("Refresh available icon packs", to: menu) { self.refreshPacks() }
        let themes = sub("Change icon theme")
        themes.delegate = trayPreview
        for p in packs where p.canApps {
            let e = add(p.title + "  ·  " + (p.isDefault ? "Default" : p.status), to: themes, enabled: !working) {
                self.show(tab: .manage)
                self.changeSelection(p.id)
            }
            if p.canPreview { e.representedObject = p }
            e.state = p.id == selected.id ? .on : .off
        }
        menu.addItem(.separator())
        let packMenu = sub("Pack actions")
        _ = add("Customize…", to: packMenu, enabled: !working && !selected.isDefault) {
            self.show(tab: .manage)
            self.editor("customize")
        }
        _ = add("Edit pack…", to: packMenu, enabled: !working && selected.personal) {
            self.show(tab: .manage)
            self.editor("edit")
        }
        _ = add("Export ZIP…", to: packMenu, enabled: !working && selected.personal) {
            self.show(tab: .manage)
            self.exportPack()
        }
        packMenu.addItem(.separator())
        _ = add("Restore built-in packs", to: packMenu, enabled: !working) {
            self.show(tab: .manage)
            self.unhide()
        }
        _ = add("Refresh installed apps", to: menu, enabled: !working) { self.refresh() }
        _ = add("Include another apps folder…", to: menu, enabled: !working && !install.fixture) {
            self.show(tab: .manage)
            if let url = self.chooseFile(folder: true), !self.prefs.folders.contains(url) {
                self.prefs.folders.append(url)
                self.savePrefs()
                self.refresh()
            }
        }
        _ = add("Restore original icons…", to: menu, enabled: !working) {
            self.show(tab: .manage)
            self.review(restore: true, only: nil)
        }
        _ = add("Manage Icons…", to: menu, enabled: !working) { self.show(tab: .manage) }
        _ = add("Change hotkey…", to: menu, enabled: !working) {
            self.show(tab: .manage)
            self.openHotkey()
        }
        menu.addItem(.separator())
        _ = add("Exit BetterIcon", to: menu, enabled: !working) { NSApp.terminate(nil) }
        // AppKit can send a selected item's action before menu tracking returns.
        trackingStatusMenu = true
        defer { trackingStatusMenu = false }
        present(menu, button)
        trayPreview.dismiss()
    }
}
