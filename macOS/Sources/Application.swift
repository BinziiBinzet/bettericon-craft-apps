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
    /// The published packs. A download, an update or a refresh can give a watched folder's pack other art, or bring the
    /// pack of a folder kept up to date to this Mac: its files follow at once.
    var builtins: [Pack] {
        didSet { if watchedFolders != nil { keepFoldersUpToDate(rescan: .changed) } }
    }
    private let checkPackUpdates: ((PackUpdateCheck?) throws -> PackUpdateCheck)?
    private var packUpdateTimer: Timer?
    private var checkingPackUpdates = false
    private var triedChosenPacks = false
    private var packRefreshGeneration = 0
    private var packUpdates: PackUpdateCheck?
    private lazy var trayPreview = TrayPackPreview(published)
    private lazy var folderIcons = FolderIcons(formats: published.formats)
    private lazy var folderWatcher = FolderWatcher { [weak self] files in self?.keepUpToDate(files) }
    private let folderQueue = DispatchQueue(label: "com.omegadarling.bettericon.folder-scan", qos: .utility)
    /// Guards folderArt, heldFolders and folderTokens, which the watcher's queue and the folder passes read.
    private let folderLock = NSLock()
    /// A watched folder, by its real path as FSEvents reports the files in it, with the artwork it keeps: the art for the
    /// listed formats, and the art by app for the files of other types that those apps open by default. Its token changes
    /// whenever its job does, and a pass started for an earlier job stops at its next file.
    private struct FolderJob {
        let prefix: String
        let art: [String: URL]
        let unlisted: [String: URL]
        let token: Int
    }
    /// The watched folders, innermost first: a file belongs to the innermost one that holds it.
    private var folderArt = [FolderJob]()
    private var folderTokens = 0
    /// Folders, by real path, that the user's own Restore works on now. No other pass and no watcher event touches a file
    /// in them meanwhile, so nothing puts back an icon the Restore has just taken off.
    private var heldFolders = Set<String>()
    /// Folders the user's own Apply works on now, with the pack it applies: they keep that pack's art from the start.
    private var applyingFolders = [String: String]()
    /// The folders the watcher watches, nil before BetterIcon starts keeping folders up to date.
    private var watchedFolders: [String]?
    /// Puts app icons back after updates. The apps folder watcher feeds it from its own queue.
    private let keeper: IconKeeper
    private lazy var appsWatcher: AppsWatcher = {
        let keeper = self.keeper
        // A new event on an app starts its retries afresh. When the system dropped events, the apps are looked for again.
        return AppsWatcher(
            changed: { keeper.request($0, fresh: true) },
            rescan: { [weak self] in DispatchQueue.main.async { self?.sweep() } })
    }()
    private var keepTimer: Timer?
    /// How often every app is looked at again, and the apps folders watched anew. The checks shorten it.
    static var sweepInterval: TimeInterval = 30 * 60
    /// From the start of an Apply or Restore review until it is applied or cancelled. The automatic
    /// re-apply is paused meanwhile, so the reviewed plan stays current.
    private var reviewing = false
    private var reportedKeepErrors = Set<String>()
    /// Copies that should carry BetterIcon's icon and do not: path to the reason, empty when macOS refused the change.
    /// They stay on the status line until they get their icon or are restored, or BetterIcon restarts.
    private var outstanding = [String: String]()
    /// A refresh asked for while a review, alert or panel was open. It runs once they are closed.
    private var refreshQueued = false
    /// Apps that got their icons back in the last two minutes. The Launcher updates apps one after another,
    /// and the status line names them together.
    private var recentlyKept = [(path: String, name: String, at: Date)]()
    /// New apps that got the applied pack in the last two minutes, named together in the same way.
    private var recentlyAdopted = [(path: String, name: String, at: Date)]()
    /// A look for apps without the busy overlay is under way: the sweep, or after the watcher missed events.
    private var sweeping = false
    /// Native alerts shown so far. The checks confirm with it that putting icons back never interrupts.
    private(set) var alertsShown = 0
    /// Finds the installed apps. The checks slow it down to widen a race.
    var discoverApps: ([URL]) -> [AppEntry]
    /// Answers a quit that waited for BetterIcon to finish putting an icon back. The checks replace it.
    var terminateReply: (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }
    /// Opens BetterIcon at login, or nil where there is no such option: macOS 12 and fixture installations.
    let loginItem: LoginItem?
    /// What macOS last said about the login item.
    private var loginState: LoginItemState?
    /// What the user chose about opening at login, kept in choices.json, or nil before the first start of a version with
    /// the option.
    private var openAtLogin: Bool?
    /// The Apple event AppKit is handling, which says whether macOS opened BetterIcon at login.
    private let currentEvent: () -> NSAppleEventDescriptor?
    /// Whether macOS opened BetterIcon at login. It then starts in the menu bar without showing its window.
    private(set) var launchedAtLogin = false
    /// Downloads one pack and returns the pack list. The checks replace it, so no test needs the network.
    private let acquirePack: (String) throws -> [Pack]
    /// No saved preferences: a new installation, which offers once to download every pack.
    private let newInstallation: Bool
    private var downloadingPacks = false
    /// The progress of the downloads chosen in the offer, shown beside the latest news while they run.
    private var downloadProgress: String?
    /// How those downloads ended, shown until the user closes it.
    private var downloadSummary: String?
    /// The download size of each published pack, from the installer's catalog.
    private lazy var packSizes = PackSizes.load(install.resources)
    /// SHA-256 of artwork files the Launcher compares, remembered while each file stays the same.
    private var artDigests = [String: (stamp: String, digest: String)]()
    private let previewQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private var fileSelection: Pack {
        packs.first { $0.id == prefs.fileSelected && $0.status != "Download" && $0.canFiles } ?? .defaults
    }
    let themes: Themes
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
    /// The menu bar icon. The checks take the icons of the apps they start out of the menu bar once they are done.
    var menuBarItem: NSStatusItem? { item }
    private var ready = false, working = false, modal = false, nativePanel = false
    private var trackingStatusMenu = false
    private var activeTab = PopupTab.launcher
    /// The status line before there is any news.
    private static let idleStatus = "Changes are reviewed before they are applied."
    private var status = Application.idleStatus, keyStatus = ""
    private var editing: Pack?, editingGroup = "apps", files = [String: URL]()
    private var appearanceObserver: NSKeyValueObservation?
    private var voiceOverObserver: NSKeyValueObservation?
    private var displayedSize = NSSize.zero
    private let startHidden: Bool
    private static let projectURL = URL(string: "https://github.com/BinziiBinzet/bettericon-craft-apps")!
    private let openProjectURL: (URL) -> Bool
    private let presentWindow: (NSWindow) -> Void
    private var menuBlocks = [() -> Void]()
    let version: String
    /// `loginItem` nil picks the login item for the installation: the system's on macOS 13 and later, and none on macOS
    /// 12 or for a fixture. `.some(nil)` stands for a Mac without the option. `startedBefore` says whether an earlier
    /// start left its lock file, which main.swift creates before this runs; nil looks for that file now.
    init(_ install: Installation, hidden: Bool = false, presentWindow: @escaping (NSWindow) -> Void = {
        NSApp.activate(ignoringOtherApps: true)
        $0.makeKeyAndOrderFront(nil)
    }, openProjectURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        checkPackUpdates: ((PackUpdateCheck?) throws -> PackUpdateCheck)? = nil,
        loginItem: LoginItem?? = nil, acquirePack: ((String) throws -> [Pack])? = nil,
        currentEvent: @escaping () -> NSAppleEventDescriptor? = { NSAppleEventManager.shared().currentAppleEvent },
        startedBefore: Bool? = nil
    ) throws {
        self.install = install
        self.presentWindow = presentWindow
        self.openProjectURL = openProjectURL
        self.currentEvent = currentEvent
        startHidden = hidden
        if let loginItem {
            self.loginItem = loginItem
        } else if !install.fixture, #available(macOS 13, *) {
            self.loginItem = SystemLoginItem()
        } else {
            self.loginItem = nil
        }
        let info = try Data(
            contentsOf: install.resources.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        let metadata = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any]
        guard let release = metadata?["CFBundleShortVersionString"] as? String else {
            throw Problem("Missing BetterIcon release version.")
        }
        version = release
        let preferencesFile = install.state.appendingPathComponent("preferences.json")
        // Saved preferences, or the lock file an earlier start left, mark an installation that an earlier version set up.
        // Versions before 1.28.0 saved preferences only once something was changed.
        let upgraded = fm.fileExists(atPath: preferencesFile.path)
            || (startedBefore ?? fm.fileExists(atPath: install.state.appendingPathComponent("launcher.lock").path))
        prefs = try saved(Preferences.self, at: preferencesFile, fallback: Preferences())
        openAtLogin = Choices.load(install.state)?.openAtLogin
        library = try PackLibrary(install.state.appendingPathComponent("Packs"))
        icons = AppIcons(install.state.appendingPathComponent("App Icons"))
        keeper = IconKeeper(icons: icons, catalog: install.catalog)
        let catalog = install.catalog
        discoverApps = { catalog.discover(extraFolders: $0) }
        published = try PublishedPacks(resources: install.resources, state: install.state)
        themes = try Themes(resources: install.resources)
        builtins = try published.list()
        self.checkPackUpdates = checkPackUpdates ?? (install.fixture ? nil : published.checkUpdates)
        self.acquirePack = acquirePack ?? { [published] id in try published.list("acquire", id: id) }
        library.formats = published.formats
        // Earlier versions showed the chosen pack in the Launcher. Keep that look after an upgrade.
        // A new installation has applied nothing, so its Launcher starts from the original icons.
        if prefs.appliedPack == nil { prefs.appliedPack = upgraded ? prefs.selected : Pack.defaults.id }
        // A new installation offers once to download every pack. An upgraded one never does.
        newInstallation = !upgraded
        if newInstallation { prefs.offerPacks = true }
        super.init()
        migratePackSelections()
    }

    deinit {
        packUpdateTimer?.invalidate()
        keepTimer?.invalidate()
    }

    private func migratePackSelections() {
        let renamed = builtins.filter { !$0.previousIDs.isEmpty }
        func current(_ id: String?) -> String? {
            id.flatMap { old in renamed.first { $0.previousIDs.contains(old) }?.id } ?? id
        }
        let before = [prefs.selected, prefs.appliedPack, prefs.fileSelected]
        prefs.selected = current(prefs.selected) ?? prefs.selected
        prefs.appliedPack = current(prefs.appliedPack)
        prefs.fileSelected = current(prefs.fileSelected)
        // An app icon pack saved as the file choice by an earlier version gives way to the original file icons.
        if let id = prefs.fileSelected, packs.contains(where: { $0.id == id && !$0.canFiles }) {
            prefs.fileSelected = nil
        }
        if before != [prefs.selected, prefs.appliedPack, prefs.fileSelected] {
            savePrefs(applied: { $0.appliedPack = current($0.appliedPack) })
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // AppKit calls this while it handles the Apple event that opened BetterIcon.
        launchedAtLogin = LoginLaunch.detected(currentEvent())
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
        // The offer of a new installation waits in the window until it is answered.
        if newInstallation { savePrefs() }
        startOpenAtLogin()
        // Opened at login, BetterIcon waits in the menu bar.
        if !startHidden && !launchedAtLogin { show() }
        keepFoldersUpToDate(rescan: .all)
        startKeepingIcons()
        if checkPackUpdates != nil {
            let timer = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in self?.checkForPackUpdates() }
            packUpdateTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            checkForPackUpdates()
        }
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
        // macOS opening the login item while BetterIcon already runs is no request to show the window.
        if !LoginLaunch.detected(currentEvent()) { show() }
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if working || modal || nativePanel {
            show()
            return .terminateCancel
        }
        // While BetterIcon puts an icon back, it finishes the app it is working on first, so no app is left with a
        // half-written icon. The other apps wait for the next start. A few seconds at most.
        guard keeper.beginQuitting() else { return .terminateNow }
        var answered = false
        let reply = terminateReply
        let answer = {
            guard !answered else { return }
            answered = true
            reply(true)
        }
        keeper.whenIdle(answer)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: answer)
        return .terminateLater
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
    private func savePrefs(
        adding: [String] = [], removing: [String] = [], applied: ((inout Preferences) -> Void)? = nil
    ) {
        do {
            let ui = prefs
            prefs = try updatePreferences(install.state) { stored in
                let defaults = stored.defaultPaths.union(adding).subtracting(removing)
                // The command line also applies icons. The stored record of the applied pack is the current one.
                var record = stored
                if record.appliedPack == nil { record.appliedPack = ui.appliedPack }
                applied?(&record)
                stored = ui
                stored.defaultPaths = defaults
                stored.appliedPack = record.appliedPack
                stored.appliedArt = record.appliedArt
                stored.appliedScopes = record.appliedScopes
                stored.appliedFolders = record.appliedFolders
                stored.restoredApps = record.restoredApps
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
        // The app takes its colors from the chosen app icon.
        let surface = Themes.color(themes.colors(prefs.color, dark: dark)["surface"]) ?? .windowBackgroundColor
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
        // The login item can be changed in System Settings while BetterIcon runs.
        followLoginItem()
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
            "showError": ["id", "message"], "packPreview": ["id", "token", "url"], "packUpdateCount": ["count"],
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
        // The Launcher shows the pack that was last applied, never the one being browsed.
        // The artwork recorded at Apply stays in use after the pack is edited, updated or removed.
        let appliedDefault = prefs.appliedPack == Pack.defaults.id
        let applied = (packs + builtins).first { $0.id == prefs.appliedPack && $0.status != "Download" }
        func appliedFile(_ craft: String) -> URL? {
            if let path = prefs.appliedArt?[craft], fm.isReadableFile(atPath: path) { return URL(fileURLWithPath: path) }
            return applied?.icons[craft]
        }
        func current(_ app: AppEntry) -> String {
            if appliedDefault || prefs.defaultPaths.contains(app.url.path) { return original(app) }
            switch icons.launcherArt(app) {
            case .own?:
                // A copy still waiting for its icon, because an update dropped it or macOS refused the change, shows the
                // icon it has, and so does a copy that carries an icon of the user's own.
                return scheme.link(app.url, system: true)
            case .kept(let id, let file)?:
                // Each copy shows the artwork BetterIcon put on it. The artwork applied last keeps the pack's own file,
                // as Manage Icons shows it.
                if let art = appliedFile(app.craft), artDigest(art) == id { return scheme.link(art) }
                return scheme.link(file ?? app.url, system: file == nil)
            case nil:
                // A custom icon BetterIcon holds no record of, such as one a new app arrived with, is the user's.
                if icons.carriesOwnIcon(app) { return scheme.link(app.url, system: true) }
            }
            return appliedFile(app.craft).map { scheme.link($0) } ?? original(app)
        }
        let tiles: [[String: String]] = apps.map { app in
            [
                "id": app.url.path, "name": app.name, "craft": app.craft, "hint": app.name + "\n" + app.url.path,
                "image": current(app),
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
        for color in Themes.styles {
            for v in ["dark", "light"] {
                let key = color + "_" + v
                brandURLs[key] = scheme.link(
                    install.resources.appendingPathComponent("Brand/32px/betterIcon_icon_" + key + ".png"))
            }
        }
        let settings = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(prefs))) ?? [:]
        let filePack = fileSelection
        let filePreview = published.fileTiles(filePack).map {
            ["name": $0.name, "hint": $0.hint, "image": scheme.link($0.art)]
        }
        var state: [String: Any] = [
            // ArtCraft Launcher leads the pack's icons when the pack draws it.
            "apps": tiles, "preview": preview.sorted {
                let a = $0["name"] ?? "", b = $1["name"] ?? ""
                return (a == Pack.lead) != (b == Pack.lead) ? a == Pack.lead : a < b
            },
            "packs": packs.map(\.model), "filePack": filePack.model,
            "fileCount": published.fileArt(filePack).count, "filePreview": filePreview,
            "fileFolders": (prefs.fileFolders ?? [:]).keys.sorted(),
            "pack": pack.model, "theme": themes.colors(prefs.color, dark: dark),
            "prefs": settings, "maxSize": maxSize, "dark": dark, "brands": brandURLs, "version": version,
            "status": shownStatus, "shortcut": shortcutText, "projectURL": Self.projectURL.absoluteString,
            "packUpdateCount": packUpdates?.count ?? 0,
        ]
        // The Open at login box shows what macOS says, and is left out where there is no such option. While macOS waits
        // for the user to allow it, a note under the tabs, which both tabs show, says where.
        if loginItem != nil {
            state["loginItem"] = [
                "on": loginState == .enabled, "waiting": loginState == .requiresApproval, "pane": LoginItems.pane,
            ]
        }
        // The count line when the file type pack also draws file types outside the list. The page shows it when present.
        if let summary = published.fileSummary(filePack) { state["fileSummary"] = summary }
        if let offer = downloadOffer() { state["downloadOffer"] = offer }
        // The downloads chosen in the offer: their progress, then how they ended, until the user closes it.
        if let line = downloadProgress ?? downloadSummary {
            state["downloads"] = ["line": line, "done": downloadProgress == nil]
        }
        call("update", ["next": state])
    }
    /// The offer a new installation makes once in the window: every app icon pack and every file type icon pack that is
    /// not on this Mac yet, each with its download size. Nil when there is nothing to offer.
    private func downloadOffer() -> [String: Any]? {
        guard prefs.offerPacks == true, !downloadingPacks, downloadSummary == nil else { return nil }
        let missing = offeredPacks(apps: true, files: true)
        guard !missing.isEmpty else {
            // Nothing to download: the offer is spent.
            prefs.offerPacks = nil
            savePrefs()
            return nil
        }
        func group(_ list: [Pack]) -> [String: Any] {
            let sizes = list.compactMap { packSizes[$0.id] }
            return ["count": list.count, "bytes": sizes.reduce(0, +), "known": sizes.count == list.count]
        }
        return [
            "apps": group(missing.filter(\.canApps)), "files": group(missing.filter(\.canFiles)), "both": group(missing),
        ]
    }
    /// The published packs that are not on this Mac yet: those with app icons, those with file type artwork, or both.
    private func offeredPacks(apps: Bool, files: Bool) -> [Pack] {
        packs.filter { pack in
            !pack.personal && !pack.isDefault && ["Download", "Update available"].contains(pack.status)
                && ((apps && pack.canApps) || (files && pack.canFiles))
        }
    }
    /// SHA-256 of an artwork file, computed once while the file stays the same.
    private func artDigest(_ file: URL) -> String? {
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        let stamp = "\(values.fileSize ?? -1)/\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if let known = artDigests[file.path], known.stamp == stamp { return known.digest }
        guard let data = try? Artwork.load(file) else { return nil }
        let value = digest(data)
        artDigests[file.path] = (stamp, value)
        return value
    }
    /// Run work off the main thread while the interface shows it as busy. Returns false, and runs nothing, while
    /// other work is under way.
    @discardableResult private func background<T>(
        _ message: String, work: @escaping () throws -> T, done: @escaping (T) -> Void,
        onError: ((Error) -> Void)? = nil
    ) -> Bool {
        guard !working else { return false }
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
        return true
    }
    private func refresh() {
        let folders = prefs.folders
        let discover = discoverApps
        background("Finding installed apps…", work: { discover(folders) }) {
            apps in
            if let stored = try? saved(
                Preferences.self, at: self.install.state.appendingPathComponent("preferences.json"),
                fallback: self.prefs)
            {
                self.prefs.defaultPaths = stored.defaultPaths
                self.prefs.restoredApps = stored.restoredApps
                if stored.appliedPack != nil {
                    self.prefs.appliedPack = stored.appliedPack
                    self.prefs.appliedArt = stored.appliedArt
                    self.prefs.appliedScopes = stored.appliedScopes
                    self.prefs.appliedFolders = stored.appliedFolders
                }
            }
            self.apps = apps
            self.scheme.reset()
            self.rangeForSelection()
            self.resolveLocations()
            // Apps updated while BetterIcon was closed, or since the last look, get their icons back.
            self.watchAppFolders()
            self.keeper.request(nil)
            self.restoreChosenPacks()
            self.resumeDownloads()
        }
    }
    /// Look for apps again without the busy overlay, and check them all: every 30 minutes, and when the folder watcher
    /// missed events. An app that arrived in a folder no one watched yet, such as a first personal Applications folder
    /// that ArtCraft Launcher created to install into, is found this way.
    private func sweep() {
        guard !sweeping else { return }
        guard !working else {
            // An Apply, Restore or refresh under way keeps its own list. Look once it is done.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.sweep() }
            return
        }
        sweeping = true
        let folders = prefs.folders, discover = discoverApps
        DispatchQueue.global(qos: .utility).async {
            let found = discover(folders)
            DispatchQueue.main.async {
                self.sweeping = false
                guard !self.working else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.sweep() }
                    return
                }
                if found != self.apps {
                    self.apps = found
                    self.scheme.reset()
                    self.rangeForSelection()
                    self.render()
                }
                // An apps folder that appeared since the last look is watched from now on.
                self.watchAppFolders()
                self.keeper.request(nil)
            }
        }
    }
    /// An Apply made before BetterIcon recorded the locations it covered: the locations where BetterIcon keeps icons now
    /// count as covered for new apps, with the folders included now. They are worked out once and saved. From then on
    /// preferences without locations mean none, as after an earlier version dropped them from preferences.json.
    private func resolveLocations() {
        let known = Choices.load(install.state)?.locationsKnown == true
        if prefs.appliedScopes != nil {
            if !known { _ = try? Choices.update(install.state) { $0.locationsKnown = true } }
            return
        }
        guard !known, let pack = prefs.appliedPack, pack != Pack.defaults.id, prefs.appliedArt != nil, !apps.isEmpty
        else { return }
        let scopes = Set(apps.filter { icons.keepsIcon($0) }.map(\.scope)).map(\.rawValue).sorted()
        let folders = prefs.folders.map(\.path)
        savePrefs(applied: { record in
            guard record.appliedScopes == nil else { return }
            record.appliedScopes = scopes
            record.appliedFolders = folders
        })
        _ = try? Choices.update(install.state) { $0.locationsKnown = true }
    }
    /// An app update installs a fresh copy, which drops the custom icon. BetterIcon puts its icons back after
    /// the first discovery and each later refresh, when an app is replaced in a watched folder, and every 30 minutes.
    private func startKeepingIcons() {
        keeper.context = { [weak self] in self?.keepContext() }
        keeper.finished = { [weak self] result in self?.keptIcons(result) }
        watchAppFolders()
        let timer = Timer(timeInterval: Self.sweepInterval, repeats: true) { [weak self] _ in self?.sweep() }
        keepTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    /// Watch the folders apps are found in. Watching the same folders again changes nothing.
    private func watchAppFolders() {
        guard keeper.context != nil else { return }
        appsWatcher.watch(install.catalog.roots(extraFolders: prefs.folders))
    }
    /// What the next pass works with, or nil to hold it off while a native panel or alert is open. An Apply or
    /// Restore review pauses the keeper itself.
    private func keepContext() -> IconKeeper.Context? {
        guard !nativePanel else { return nil }
        // The command line changes the same preferences.
        let stored = try? saved(
            Preferences.self, at: install.state.appendingPathComponent("preferences.json"), fallback: prefs)
        let appliedPack = stored?.appliedPack ?? prefs.appliedPack
        let appliedArt = stored?.appliedArt ?? prefs.appliedArt
        return IconKeeper.Context(
            apps: apps, appliedPack: appliedPack, defaultPaths: stored?.defaultPaths ?? prefs.defaultPaths,
            appliedArt: appliedArt, adoption: adoption(appliedPack, appliedArt, stored ?? prefs))
    }
    /// New ArtCraft apps get the applied pack's artwork, in the locations the last Apply covered: the standard apps
    /// folders of those locations, and the folders included at that Apply. The apps in a folder included since are not
    /// new; they wait for the next Apply. Nothing is given while the original icons are applied, while the locations are
    /// not known (an Apply made before BetterIcon recorded them, until it works them out after its first look for apps),
    /// or when the applied artwork is no longer on this Mac.
    private func adoption(_ pack: String?, _ art: [String: String]?, _ recorded: Preferences) -> Adoption? {
        guard let pack, pack != Pack.defaults.id, let art, let scopes = recorded.coveredScopes, !scopes.isEmpty else {
            return nil
        }
        let files = art.compactMapValues { fm.isReadableFile(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
        guard !files.isEmpty else { return nil }
        let covered = Set(recorded.appliedFolders ?? [])
        let folders = recorded.folders.filter { covered.contains($0.path) }
        return Adoption(
            pack: pack, art: files, scopes: scopes, roots: install.catalog.roots(extraFolders: folders),
            kept: recorded.restoredApps ?? [])
    }
    /// The name the status line uses for an app.
    private func appName(_ path: String) -> String {
        apps.first { $0.url.path == path }?.name ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
    /// App names for the status line, in order. Copies of one app in both locations are named once.
    private func named(_ names: [String]) -> String {
        var counts = [String: Int]()
        for name in names { counts[name, default: 0] += 1 }
        return counts.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { name in
            counts[name, default: 0] > 1 ? "\(name) (\(counts[name, default: 0]) copies)" : name
        }.joined(separator: ", ")
    }
    /// The status line as shown: the latest news, the progress or the outcome of the downloads chosen in the offer, then
    /// a standing note while copies still lack their icon. News of other work never hides the downloads, nor they it.
    private var shownStatus: String {
        [status, downloadProgress ?? downloadSummary ?? "", standingNote()].filter { !$0.isEmpty }.joined(separator: " ")
    }
    /// Copies that should carry BetterIcon's icon and do not, with what to do about it. It stays until they get it.
    private func standingNote() -> String {
        let present = outstanding.filter { fm.fileExists(atPath: $0.key) }
        var parts = [String]()
        let refused = present.filter { $0.value.isEmpty }.map { appName($0.key) }
        if !refused.isEmpty {
            parts.append(
                (refused.count == 1
                    ? "\(named(refused)) still has its original icon, because macOS didn’t let BetterIcon change it."
                    : "\(named(refused)) still have their original icons, because macOS didn’t let BetterIcon change them.")
                    + " To allow it, turn on BetterIcon in System Settings > Privacy & Security > App Management, then quit and reopen BetterIcon.")
        }
        let failed = present.filter { !$0.value.isEmpty }.sorted {
            appName($0.key).localizedCaseInsensitiveCompare(appName($1.key)) == .orderedAscending
        }
        if failed.count == 1, let only = failed.first {
            parts.append("Couldn’t give \(appName(only.key)) its icon: \(only.value)")
        } else if !failed.isEmpty {
            parts.append(
                "Couldn’t give \(failed.count) apps their icons. "
                    + failed.map { "\(appName($0.key)) — \($0.value)" }.joined(separator: " "))
        }
        return parts.joined(separator: " ")
    }
    /// Report what a pass did on the status line. Putting icons back never opens an alert.
    private func keptIcons(_ result: Reconciled) {
        // Copies that keep their original icon from now on, also as a renamed, moved or duplicated copy. New apps that
        // keep an icon of their own join them quietly.
        let original = result.optedOut + result.leftAlone
        if !original.isEmpty {
            savePrefs(adding: original, applied: { $0.remember(result.forgotten) })
        }
        func list(_ paths: [String]) -> (text: String, one: Bool) {
            (named(paths.map(appName)), paths.count == 1)
        }
        // Copies that got their icon, or keep another icon from now on, leave the standing note. Copies that macOS
        // refused, or that could not get their icon, join it.
        for path in result.restored.map(\.url.path) + result.finished.map(\.url.path) + result.adopted.map(\.url.path)
            + original + result.yielded
        {
            outstanding[path] = nil
        }
        for path in result.declined.keys { outstanding[path] = "" }
        for (path, message) in result.failed { outstanding[path] = message }
        var lines = [String]()
        let now = Date()
        // Apps put back, and new apps given the pack, in the last two minutes are named together, unless they have lost
        // that icon since. The Launcher installs and updates apps one after another.
        let lost = Set(result.optedOut + result.yielded)
        func recent(_ list: inout [(path: String, name: String, at: Date)], _ apps: [AppEntry]) {
            list.removeAll { now.timeIntervalSince($0.at) > 120 || outstanding[$0.path] != nil || lost.contains($0.path) }
            for app in apps {
                list.removeAll { $0.path == app.url.path }
                list.append((app.url.path, app.name, now))
            }
        }
        recent(&recentlyKept, result.restored)
        recent(&recentlyAdopted, result.adopted)
        let news = !result.restored.isEmpty || !result.adopted.isEmpty
        if news && !recentlyKept.isEmpty {
            let restored = named(recentlyKept.map(\.name))
            lines.append(
                recentlyKept.count == 1
                    ? "Put your icon back on \(restored) after its update."
                    : "Put your icons back on \(recentlyKept.count) updated apps: \(restored).")
        }
        if !result.finished.isEmpty {
            let done = list(result.finished.map(\.url.path))
            lines.append("Finished applying your \(done.one ? "icon" : "icons") to \(done.text).")
        }
        if news && !recentlyAdopted.isEmpty {
            // New apps in a location the last Apply covered get the applied pack.
            let names = named(recentlyAdopted.map(\.name)), count = recentlyAdopted.count
            lines.append(
                count == 1
                    ? "Gave your \(appliedTitle) icon to the new app \(names)."
                    : "Gave your \(appliedTitle) icons to \(count) new apps: \(names).")
        }
        if !result.yielded.isEmpty {
            let kept = list(result.yielded)
            lines.append(
                kept.one
                    ? "\(kept.text) keeps the icon you gave it. BetterIcon leaves it alone after updates."
                    : "\(kept.text) keep the icons you gave them. BetterIcon leaves them alone after updates.")
        }
        let why = Dictionary(grouping: result.optedOut, by: { result.reasons[$0] ?? .removed })
        if let paths = why[.removed] {
            let kept = list(paths)
            lines.append(
                kept.one
                    ? "\(kept.text) keeps its original icon, because its custom icon was removed outside BetterIcon."
                    : "\(kept.text) keep their original icons, because their custom icons were removed outside BetterIcon.")
        }
        if let paths = why[.ownIcon] {
            let kept = list(paths)
            lines.append(
                kept.one
                    ? "\(kept.text) keeps its original icon after its update, because you had given it an icon of your own."
                    : "\(kept.text) keep their original icons after their updates, because you had given them icons of your own.")
        }
        if let paths = why[.restore] {
            let kept = list(paths)
            lines.append(
                kept.one
                    ? "\(kept.text) keeps its original icon, as you asked when you restored it."
                    : "\(kept.text) keep their original icons, as you asked when you restored them.")
        }
        // An error that names no app is shown once.
        if result.failed.isEmpty {
            let fresh = result.errors.filter { reportedKeepErrors.insert($0).inserted }
            if !fresh.isEmpty { lines.append("Couldn’t put an icon back. " + fresh.joined(separator: " ")) }
        }
        if !lines.isEmpty { status = lines.joined(separator: " ") }
        // New addresses make WebKit draw the apps' icons as they are now.
        scheme.reset()
        if working {
            call("showError", ["id": "status", "message": shownStatus])
        } else {
            render()
        }
        // An app that arrived after the last discovery joins the Launcher, once no review, alert or panel is open.
        let arrived = (result.restored + result.adopted).map(\.url.path) + result.leftAlone
        if arrived.contains(where: { path in !apps.contains { $0.url.path == path } }) {
            refreshWhenIdle()
        }
    }
    /// The name of the applied pack, for the status line.
    private var appliedTitle: String {
        let id = prefs.appliedPack ?? ""
        return (packs + builtins).first { $0.id == id }?.title ?? id.split(separator: "/").last.map(String.init) ?? id
    }
    /// Refresh the installed apps now, or once no review, alert, panel or other work is under way. A refresh during an
    /// alert would make the review the alert leads to find BetterIcon busy.
    private func refreshWhenIdle() {
        guard !refreshQueued else { return }
        guard working || modal || nativePanel || reviewing || trackingStatusMenu else {
            refresh()
            return
        }
        refreshQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refreshWhenIdle()
        }
    }
    /// A build that carried every pack kept them inside the app. After an upgrade the chosen packs are still
    /// saved but are no longer on the computer, so they are downloaded once and the app opens as it was left.
    /// A failure is not reported in an alert: the choices stay saved, and the next start or pack refresh tries again.
    private func restoreChosenPacks() {
        guard !triedChosenPacks else { return }
        triedChosenPacks = true
        let wanted = packs.filter { pack in
            pack.status == "Download"
                && ((pack.id == prefs.selected && pack.canApps && pack.id != Preferences.openingPack)
                    || (pack.id == prefs.fileSelected && pack.canFiles))
        }
        guard let first = wanted.first else { return }
        let ids = wanted.map(\.id)
        background(
            "Downloading " + first.title + "…",
            work: { () -> ([Pack]?, Bool) in
                var rows: [Pack]?
                var failed = false
                for id in ids {
                    do { rows = try self.published.list("acquire", id: id) } catch { failed = true }
                }
                return (rows, failed)
            },
            done: { result in
                if let rows = result.0 {
                    self.builtins = rows
                    self.rangeForSelection()
                }
                if result.1 {
                    self.status = "Couldn’t download your chosen icon pack. BetterIcon will try again the next time it starts."
                }
            })
    }
    /// Download the packs the user chose in the offer of a new installation, one after another, without blocking the
    /// window. The chosen packs are saved until each has downloaded, so a quit midway leaves the rest for the next start.
    private func downloadPacks(apps: Bool, files: Bool) {
        guard prefs.offerPacks == true, !downloadingPacks else { return }
        let wanted = offeredPacks(apps: apps, files: files).map(\.id)
        prefs.offerPacks = nil
        prefs.pendingPacks = wanted.isEmpty ? nil : wanted
        savePrefs()
        guard !wanted.isEmpty else {
            render()
            return
        }
        runDownloads(wanted)
    }
    /// Downloads chosen in the offer that a quit interrupted go on at the next start.
    private func resumeDownloads() {
        guard !downloadingPacks, let pending = prefs.pendingPacks else { return }
        guard !working else {
            // One helper at a time: chosen packs an upgrade downloads again come first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.resumeDownloads() }
            return
        }
        let still = pending.filter { id in packs.contains { $0.id == id && ["Download", "Update available"].contains($0.status) } }
        guard !still.isEmpty else {
            prefs.pendingPacks = nil
            savePrefs()
            return
        }
        runDownloads(still)
    }
    /// Show the downloads' progress, which the status line shows beside the latest news, and the banner under the tabs.
    private func showDownloads() {
        if working {
            call("showError", ["id": "status", "message": shownStatus])
        } else {
            render()
        }
    }
    /// Download these packs one after another through the helper's acquire. A pack that fails is skipped and downloads
    /// when it is chosen later. When GitHub cannot be reached at all, the downloads end at once with one plain sentence.
    private func runDownloads(_ ids: [String]) {
        downloadingPacks = true
        downloadSummary = nil
        let titles = Dictionary(packs.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let acquire = acquirePack, total = ids.count
        if status == Self.idleStatus { status = "" }
        downloadProgress = "Downloading \(total) icon \(total == 1 ? "pack" : "packs")…"
        showDownloads()
        func finished(_ id: String) {
            prefs.pendingPacks?.removeAll { $0 == id }
            if prefs.pendingPacks?.isEmpty == true { prefs.pendingPacks = nil }
            savePrefs()
        }
        DispatchQueue.global(qos: .utility).async {
            var done = 0
            var failed = [(title: String, cause: String)]()
            var unreachable = false
            for (index, id) in ids.enumerated() {
                let title = titles[id] ?? id
                DispatchQueue.main.async {
                    self.downloadProgress = "Downloading icon pack \(index + 1) of \(total): \(title)…"
                    self.showDownloads()
                }
                do {
                    let rows = try acquire(id)
                    done += 1
                    DispatchQueue.main.async {
                        self.builtins = rows
                        finished(id)
                        if !self.working { self.render() }
                    }
                } catch {
                    let failure = DownloadFailure(error)
                    if failure.unreachable {
                        unreachable = true
                        break
                    }
                    failed.append((title, failure.cause))
                    DispatchQueue.main.async { finished(id) }
                }
            }
            DispatchQueue.main.async {
                self.downloadingPacks = false
                self.downloadProgress = nil
                // Also after GitHub could not be reached: each pack still downloads when it is chosen.
                self.prefs.pendingPacks = nil
                self.savePrefs()
                self.downloadSummary = DownloadFailure.summary(
                    downloaded: done, of: total, failed: failed, unreachable: unreachable)
                self.rangeForSelection()
                self.showDownloads()
            }
        }
    }
    private static var loginApproval: String { "To open BetterIcon at login, allow it in \(LoginItems.pane)." }
    /// BetterIcon opens at login by default: the first start of a version with the option registers it once, and saves
    /// the choice. From then on BetterIcon follows the user's choice, made here or in System Settings, and never
    /// registers again by itself. The choice is kept in choices.json: an earlier version that saves preferences.json
    /// drops the keys it does not know, and a choice lost that way must not lead to a registration.
    private func startOpenAtLogin() {
        guard let item = loginItem else { return }
        defer { followLoginItem() }
        guard openAtLogin == nil else { return }
        if item.state == .off {
            // A copy on the disk image, or one macOS runs from a temporary folder, tries again from Applications.
            guard item.unavailable == nil else { return }
            do { try item.register() } catch {
                NSLog("BetterIcon could not add its login item: %@", error.localizedDescription)
                return
            }
            guard item.state != .off else { return }
            if item.state == .requiresApproval { status = Self.loginApproval }
        }
        chooseOpenAtLogin(true)
    }
    /// Save the choice about opening at login.
    private func chooseOpenAtLogin(_ on: Bool) {
        openAtLogin = on
        do { try Choices.update(install.state) { $0.openAtLogin = on } } catch {
            status = "Could not save preferences: " + error.localizedDescription
        }
    }
    /// Read what macOS says about the login item, and show it in Manage Icons when it changed. When the user turned it
    /// off in System Settings, the saved choice becomes off, so BetterIcon never registers it again; when they turned it
    /// on there, it becomes on.
    private func followLoginItem() {
        guard let item = loginItem else { return }
        let state = item.state
        if openAtLogin == true && state == .off {
            chooseOpenAtLogin(false)
        } else if openAtLogin == false && state == .enabled {
            chooseOpenAtLogin(true)
        }
        guard state != loginState else { return }
        loginState = state
        render()
    }
    /// Turn opening at login on or off, from the menu bar icon's menu or the box in Manage Icons. News that asks
    /// something of the user shows Manage Icons, whose status line the menu bar icon's menu cannot show otherwise.
    private func setOpenAtLogin(_ on: Bool) {
        guard let item = loginItem else { return }
        followLoginItem()
        var reveal = true
        if on, let why = item.unavailable {
            status = why
        } else if on && item.state == .requiresApproval {
            // Already registered, and waiting for the user: System Settings opens where they allow it.
            chooseOpenAtLogin(true)
            item.openSettings()
            status = Self.loginApproval
        } else if on {
            do {
                try item.register()
                if item.state == .off {
                    status = "Couldn’t open BetterIcon at login."
                } else {
                    chooseOpenAtLogin(true)
                    reveal = item.state == .requiresApproval
                    status = reveal ? Self.loginApproval : "BetterIcon opens at login."
                }
            } catch { status = "Couldn’t open BetterIcon at login: " + error.localizedDescription }
        } else {
            var problem: Error?
            do { try item.unregister() } catch { problem = error }
            // macOS reports an error when nothing was registered. Only a login item that stays on is a failure.
            if item.state == .off {
                chooseOpenAtLogin(false)
                reveal = false
                status = "BetterIcon no longer opens at login."
            } else {
                status = "Couldn’t stop BetterIcon opening at login" + (problem.map { ": " + $0.localizedDescription } ?? ".")
            }
        }
        followLoginItem()
        if reveal && !(window.isVisible && activeTab == .manage) { show(tab: .manage) }
        render()
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
        alertsShown += 1
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
        _ id: String, message: String = "App icon pack selected.", group: String = "apps"
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
            self.status = group != "files" ? message
                : pack.isDefault ? "Original file icons selected." : "File type icon pack selected."
            // Items of this list whose files cannot be used, such as an animated WebP, are named with the reason.
            if let note = pack.leftOutNote(files: group == "files", formats: self.published.formats) {
                self.status += " " + note
            }
            self.savePrefs()
        })
    }
    private func checkForPackUpdates() {
        guard let checkPackUpdates, !checkingPackUpdates else { return }
        checkingPackUpdates = true
        let generation = packRefreshGeneration, previous = packUpdates
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try checkPackUpdates(previous) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.checkingPackUpdates = false
                // A manual refresh may have acknowledged the changes while this check was running.
                guard generation == self.packRefreshGeneration, case .success(let updates) = result else { return }
                self.packUpdates = updates
                self.call("packUpdateCount", ["count": updates.count])
            }
        }
    }
    private func refreshPacks(revealManage: Bool = true) {
        if revealManage { show(tab: .manage) }
        background("Refreshing available icon packs…", work: { try self.published.list("refresh") }) { rows in
            self.packRefreshGeneration += 1
            self.packUpdates = nil
            self.builtins = rows
            self.status = "Available icon packs refreshed."
            self.migratePackSelections()
            self.triedChosenPacks = false
            self.restoreChosenPacks()
        }
    }
    private func preview(_ id: String, token: Int, files: Bool) {
        guard let pack = packs.first(where: { $0.id == id && (files ? $0.canFilePreview : $0.canPreview) }) else { return }
        previewQueue.cancelAllOperations()
        previewQueue.addOperation {
            guard let url = try? self.published.preview(pack, files: files) else { return }
            DispatchQueue.main.async {
                self.call("packPreview", ["id": id, "token": token, "url": self.scheme.link(url)])
            }
        }
    }
    private func reviewFiles(restore: Bool) {
        let pack = fileSelection
        let artwork = published.fileArt(pack)
        let formats = published.formats.filter { restore || artwork[$0.Key] != nil }
        // The pack's art for the files of types outside the list, by the ArtCraft app that opens them by default.
        let others = restore ? [:] : pack.unlisted
        guard !formats.isEmpty || !others.isEmpty else { return }
        // macOS keeps a custom icon on each file, so the user chooses files, or folders to cover completely.
        let panel = NSOpenPanel()
        panel.title = restore ? "Choose files or folders to restore" : "Choose files or folders to change"
        panel.message =
            restore
            ? "Choose the files that should show their original icons again. Choose a folder to restore every file in it."
            : "macOS keeps a custom icon on each file. Choose files, or choose a folder to cover every file in it, now and as new ones appear."
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        let store = AppIcons(install.state.appendingPathComponent("Project File Icons"))
        // A file of any type may take its opener's art, or have such an icon taken off or restored. Apps and other
        // packages are never offered.
        let all = published.formats
        panel.allowedContentTypes = filePanelTypes(
            restore: restore, formats: formats,
            catchAll: !others.isEmpty || store.holdsRecords(outside: Set(all.map(\.Key))))
        nativePanel = true
        let response = panel.runModal()
        nativePanel = false
        guard response == .OK else { return }
        // A package or an app is one item to Finder: BetterIcon never walks into it or keeps it up to date.
        let packages = panel.urls.filter { (try? $0.resourceValues(forKeys: [.isPackageKey]).isPackage) == true }
        let chosen = panel.urls.filter { !packages.contains($0) }
        let left = packages.map(\.lastPathComponent)
        let folders = chosen.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        if !folders.isEmpty {
            reviewFolders(chosen, folders: folders, pack: pack, artwork: artwork, restore: restore, packages: left)
            return
        }
        let engine = folderIcons, urls = chosen
        let plan = { () -> (plans: [FilePlan], skipped: [(name: String, reason: String)]) in
            var found = store.filePlans(
                urls, pack: pack, artwork: artwork, formats: all, restore: restore, unlisted: engine.unlisted,
                openers: FileOpeners())
            found.skipped += left.map { ($0, "Packages and apps are left alone") }
            return found
        }
        // Launch Services is asked which app opens each file of another type off the main thread.
        if !others.isEmpty && urls.contains(where: engine.isUnlistedType) {
            background("Looking at the chosen files…", work: plan) { self.confirmFiles($0, store: store, restore: restore) }
        } else {
            confirmFiles(plan(), store: store, restore: restore)
        }
    }
    /// Show what Apply or Restore file icons does to the chosen files, and do it once the user confirms.
    private func confirmFiles(
        _ found: (plans: [FilePlan], skipped: [(name: String, reason: String)]), store: AppIcons, restore: Bool
    ) {
        let lines = found.plans.flatMap { plan in
            plan.review.rows.map { row in
                row.app.name + " — "
                    + (plan.releasing && row.change ? "Restore original icon • no app this pack has art for opens it now" : row.message)
            }
        } + found.skipped.map { $0.name + " — " + $0.reason }
        let count = found.plans.reduce(0) { $0 + $1.review.rows.filter(\.change).count }
        let details = lines.joined(separator: "\n")
        guard count > 0 else { report(details.isEmpty ? "None of the chosen files is a supported file type." : details); return }
        let verb = restore ? "Restore" : "Apply"
        guard alert(verb + " icons for these files?", details, buttons: [verb, "Cancel"]) == 0 else { return }
        let plans = found.plans
        background("Updating file icons…", work: { () -> (changed: Int, released: Int, errors: [String]) in
            var changed = 0, released = 0, errors = [String]()
            for plan in plans {
                do {
                    let result = try store.perform(plan.review, apps: plan.apps, pack: plan.pack)
                    if plan.releasing { released += result.changed.count } else { changed += result.changed.count }
                    errors += result.errors
                } catch { errors.append(error.localizedDescription) }
            }
            return (changed, released, errors)
        }) { result in
            let noun = result.changed == 1 ? "file icon" : "file icons"
            self.status = "\(result.changed) \(noun) \(restore ? "restored" : "applied")."
            if result.released > 0 {
                self.status += " \(result.released) \(result.released == 1 ? "icon" : "icons") removed from files that no app this pack has art for opens now."
            }
            if !result.errors.isEmpty { self.report(result.errors.joined(separator: "\n")) }
        }
    }
    /// Cover every matching file in the chosen folders, and keep those folders up to date afterwards. Packages chosen with
    /// them are named in the confirmation and left alone.
    private func reviewFolders(
        _ chosen: [URL], folders: [URL], pack: Pack, artwork: [String: URL], restore: Bool, packages: [String] = []
    ) {
        let engine = folderIcons
        let others = pack.unlisted
        let names = folders.map(\.lastPathComponent).joined(separator: ", ")
        let these = folders.count == 1 ? "this folder" : "these folders"
        // The chosen items as FSEvents names the files in them, so the passes, the watcher and the kept list agree.
        let items = chosen.map { URL(fileURLWithPath: realFolderPath($0.path)) }
        // Watched folders inside a chosen one keep their own pack, and Apply leaves them to it. Restore covers them too.
        func inner(_ item: URL, _ watched: [String]) -> Set<String> {
            restore ? [] : Set(watched.filter { $0.hasPrefix(item.path + "/") })
        }
        let watched = watchedPrefixes()
        let leftAlone = packages.isEmpty ? "" : "\n\nPackages and apps are left alone: " + packages.joined(separator: ", ") + "."
        background(
            "Looking through \(names)…",
            work: { () -> (covered: Int, removed: Int) in
                let openers = FileOpeners()
                return items.reduce((covered: 0, removed: 0)) { sum, item in
                    if restore { return (sum.covered + engine.marked(in: item).count, 0) }
                    let found = engine.preview(item, art: artwork, unlisted: others, openers: openers, skipping: inner(item, watched))
                    return (sum.covered + found.covered, sum.removed + found.removed)
                }
            }
        ) { count in
            let noun = count.covered == 1 ? "file" : "files"
            let gone = "\(count.removed) \(count.removed == 1 ? "file" : "files")"
            let question =
                restore
                ? "Restore the icons of \(count.covered) \(noun)?"
                : count.covered > 0 ? "Apply icons to \(count.covered) \(noun)?"
                : count.removed > 0 ? "Take BetterIcon’s icons off \(gone)?" : "Keep \(these) up to date?"
            var details =
                restore
                ? "BetterIcon removes the icons it put on the files in \(names), and stops keeping \(these) up to date."
                : "BetterIcon puts this pack’s icons on the matching files in \(names), and on new files in \(these) while it is running. Files that already have an icon of their own are left alone."
            if !restore && count.removed > 0 {
                details += " It also takes its icons off \(gone) of other types that no app this pack has art for opens now."
            }
            guard self.alert(question, details + leftAlone, buttons: [restore ? "Restore" : "Apply", "Cancel"]) == 0 else {
                return
            }
            // Before the pass touches a file, the watcher and the other passes stop working on these items: Restore holds
            // them still, and Apply gives the chosen folders this pack's art at once.
            if restore {
                self.hold(items.map(\.path), true)
            } else {
                for folder in folders { self.applyingFolders[folder.standardizedFileURL.path] = pack.id }
                self.keepFoldersUpToDate(rescan: .none)
            }
            let watchedNow = self.watchedPrefixes()
            let started = self.background(
                "Updating file icons…",
                work: { () -> FolderIconResult in
                    // A file another pass is changing now is done before this pass starts.
                    engine.exclusively {}
                    let openers = FileOpeners()
                    return items.reduce(FolderIconResult()) { sum, item in
                        sum + (restore ? engine.restore(item)
                            : engine.apply(item, art: artwork, unlisted: others, openers: openers, skipping: inner(item, watchedNow)))
                    }
                }
            ) { result in
                var kept = self.prefs.fileFolders ?? [:]
                for folder in folders {
                    // An earlier version, or a link, may have named the same folder another way.
                    let path = folder.standardizedFileURL.path, real = realFolderPath(folder.path)
                    if restore {
                        kept = kept.filter {
                            let key = realFolderPath($0.key)
                            return key != real && !key.hasPrefix(real + "/")
                        }
                    } else {
                        kept = kept.filter { realFolderPath($0.key) != real }
                        kept[path] = pack.id
                    }
                }
                self.prefs.fileFolders = kept.isEmpty ? nil : kept
                self.savePrefs()
                self.applyingFolders = [:]
                self.keepFoldersUpToDate(rescan: .none)
                // A restored folder is no longer watched now, so letting go of it puts nothing back.
                if restore { self.hold(items.map(\.path), false) }
                let done = restore ? result.restored : result.changed
                self.status =
                    "\(done) \(done == 1 ? "file icon" : "file icons") \(restore ? "restored" : "applied")."
                    + (result.kept > 0 ? " \(result.kept) kept their own icon." : "")
                    + (!restore && result.restored > 0
                        ? " \(result.restored) \(result.restored == 1 ? "icon" : "icons") removed from files that no app this pack has art for opens now."
                        : "")
                if !result.errors.isEmpty { self.report(result.errors.prefix(12).joined(separator: "\n")) }
            }
            if !started {
                if restore { self.hold(items.map(\.path), false) }
                self.applyingFolders = [:]
                self.keepFoldersUpToDate(rescan: .none)
            }
        }
    }
    /// The watched folders now, by real path.
    private func watchedPrefixes() -> [String] {
        folderLock.lock()
        defer { folderLock.unlock() }
        return folderArt.map(\.prefix)
    }
    /// Hold items still while the user's own Restore works on them, or let go of them.
    private func hold(_ paths: [String], _ on: Bool) {
        folderLock.lock()
        if on { heldFolders.formUnion(paths) } else { heldFolders.subtract(paths) }
        folderLock.unlock()
    }
    private enum FolderScan { case none, changed, all }
    /// Watch the folders kept up to date: those in the preferences, and those the user's own Apply works on now, each with
    /// its pack's art while the pack is on this Mac. A package is never kept. `.all` also brings the files of every folder
    /// up to date now, as at start; `.changed` those of the folders whose pack has other art now or came to this Mac, as
    /// after an edit, a download, an update or a refresh.
    private func keepFoldersUpToDate(rescan: FolderScan) {
        let engine = folderIcons
        var wanted = [String: (art: [String: URL], unlisted: [String: URL])]()
        func want(_ path: String, _ id: String) {
            guard fm.fileExists(atPath: path), (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) != true,
                let pack = packs.first(where: { $0.id == id && $0.status != "Download" })
            else { return }
            // A pack without art for the listed formats still gets passes: they take BetterIcon's icons off files of
            // other types whose opener no longer gets art.
            wanted[realFolderPath(path)] = (published.fileArt(pack), pack.unlisted)
        }
        for (path, id) in prefs.fileFolders ?? [:] { want(path, id) }
        for (path, id) in applyingFolders { want(path, id) }
        folderLock.lock()
        var jobs = [FolderJob](), fresh = [FolderJob]()
        for (prefix, keeps) in wanted {
            if let same = folderArt.first(where: { $0.prefix == prefix && $0.art == keeps.art && $0.unlisted == keeps.unlisted }) {
                jobs.append(same)
            } else {
                folderTokens += 1
                let job = FolderJob(prefix: prefix, art: keeps.art, unlisted: keeps.unlisted, token: folderTokens)
                jobs.append(job)
                fresh.append(job)
            }
        }
        // A file belongs to the innermost watched folder that holds it.
        jobs.sort { $0.prefix.count > $1.prefix.count || ($0.prefix.count == $1.prefix.count && $0.prefix < $1.prefix) }
        folderArt = jobs
        folderLock.unlock()
        let prefixes = jobs.map(\.prefix)
        if watchedFolders != prefixes {
            watchedFolders = prefixes
            folderWatcher.watch(prefixes.map { URL(fileURLWithPath: $0) })
        }
        let scan = rescan == .all ? jobs : rescan == .changed ? fresh : []
        guard !scan.isEmpty else { return }
        folderQueue.async { [weak self] in
            for job in scan {
                // Watched folders inside this one keep their own pack. The gate leaves each file to the folder that holds
                // it and to the user's own Restore, and stops this pass once its job is over.
                let inner = Set(prefixes.filter { $0.hasPrefix(job.prefix + "/") })
                _ = engine.apply(
                    URL(fileURLWithPath: job.prefix), art: job.art, unlisted: job.unlisted, openers: FileOpeners(), skipping: inner
                ) { file in self?.folderGate(file, token: job.token) ?? .stop }
            }
        }
    }
    /// Whether a pass started for the watched folder with this token may change a file now. It stops once the folder's job
    /// is over, because the folder was restored or its pack changed, and leaves a file to the user's own Restore that works
    /// on it and to a watched folder inside its own that holds it.
    private func folderGate(_ file: URL, token: Int) -> FolderIcons.Gate {
        folderLock.lock()
        defer { folderLock.unlock() }
        guard folderArt.contains(where: { $0.token == token }) else { return .stop }
        let path = file.path
        if heldFolders.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return .skip }
        return folderArt.first(where: { path.hasPrefix($0.prefix + "/") })?.token == token ? .go : .skip
    }
    /// Called as files appear or change in a watched folder, on the watcher's own queue. Each file is handled as a folder
    /// pass handles it, with the art of the innermost watched folder that holds it. Files a pass does not reach (hidden, or
    /// in a hidden folder or a package), files the user's own Restore works on, and files no art of the folder concerns
    /// are left alone.
    private func keepUpToDate(_ files: [URL]) {
        // One batch asks Launch Services once per extension.
        let openers = FileOpeners()
        let engine = folderIcons
        for file in files where !file.lastPathComponent.hasPrefix(".") {
            engine.exclusively {
                folderLock.lock()
                let path = file.path
                let held = heldFolders.contains { path == $0 || path.hasPrefix($0 + "/") }
                let job = held ? nil : folderArt.first { path.hasPrefix($0.prefix + "/") }
                folderLock.unlock()
                guard let job else { return }
                let design = engine.artwork(for: file, in: job.art)
                // Without art for other types, a file of such a type, or of a listed format without a design here, matters
                // only while it carries BetterIcon's icon for one.
                guard design != nil || (!job.unlisted.isEmpty && engine.isUnlistedType(file)) || engine.carriesUnlisted(file),
                    !FolderIcons.tucked(file, below: job.prefix)
                else { return }
                if design != nil, (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true { return }
                _ = try? engine.pass(file, art: job.art, unlisted: job.unlisted, openers: openers)
            }
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
        // With apps in both locations, one Apply covers them all unless a single location is chosen.
        let both = nUser > 0 && nShared > 0
        let scopeButtons =
            (both ? ["Everywhere (\(nUser + nShared))"] : []) + ["All users (\(nShared))", "Current user (\(nUser))", "Cancel"]
        let choice = alert(
            restore ? "Restore icons in which location?" : "Apply icons in which location?",
            (both ? "Everywhere covers both locations. " : "")
                + "All users includes the apps in /Applications. Current user includes your personal Applications folder and Desktop. The review lists the exact apps and Finder aliases.",
            buttons: scopeButtons)
        let picked = both ? choice : choice + 1
        guard (0...2).contains(picked) else { return }
        let scope: Scope? = picked == 0 ? nil : (picked == 1 ? .shared : .personal)
        let pack = selected
        let folders = prefs.folders
        let discover = discoverApps
        // Putting icons back after updates pauses until this review is applied or cancelled. The pause first waits
        // for a pass under way, so the review shows the apps as that pass left them and nothing changes them before
        // the reviewed plan is applied.
        reviewing = true
        let keeper = self.keeper
        let finish = {
            self.reviewing = false
            keeper.resume()
        }
        let failed: (Error) -> Void = { error in
            finish()
            self.report(error.localizedDescription)
        }
        let started = background(
            "Reviewing installed apps…",
            work: { () -> Review in
                keeper.pause()
                return self.icons.review(apps: discover(folders), pack: pack, scope: scope, restore: restore, only: only)
            }, done: { plan in
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
            // Apps already at their original icon, with an old record to forget, such as an app updated since
            // BetterIcon changed it.
            let forgetting = plan.rows.filter { $0.alreadyDefault && !$0.record.isEmpty }.count
            let confirm =
                count > 0
                ? (restore ? "Restore \(count) \(noun)" : "Apply \(count) \(noun)")
                : restore && forgetting > 0 ? (forgetting == 1 ? "Keep original icon" : "Keep original icons")
                : "Use original preview"
            let ok = self.alert(
                restore ? "Review original icons" : "Review " + pack.title, explanation,
                buttons: canRun ? [confirm, "Cancel"] : ["Done"], accessory: scroll)
            guard canRun, ok == 0 else {
                finish()
                return
            }
            let applying = self.background(
                restore ? "Restoring original icons…" : "Applying icons to installed apps…",
                work: { try self.icons.perform(plan, apps: discover(folders), pack: pack) },
                done: { result in
                finish()
                self.apps = discover(folders)
                self.scheme.reset()
                if restore && result.changed.isEmpty && !result.defaults.isEmpty {
                    // Nothing needed changing: the apps already show their original icons.
                    let names = self.named(result.defaults.map(self.appName))
                    self.status =
                        result.defaults.count == 1
                        ? "\(names) is at its original icon." : "\(names) are at their original icons."
                } else {
                    self.status =
                        "\(result.changed.count) \(result.changed.count == 1 ? "icon" : "icons") \(restore ? "restored" : "applied")."
                }
                // Only now does the Launcher adopt the pack.
                self.savePrefs(
                    adding: restore ? result.defaults : [], removing: restore ? [] : result.changed,
                    applied: { $0.noteApplied(plan, result, pack: pack) })
                // Apps folders that appeared since BetterIcon started are watched from now on.
                self.watchAppFolders()
                if restore {
                    for path in result.changed + result.defaults { self.outstanding[path] = nil }
                } else {
                    // A manual Apply tries again the apps on which macOS refused to put an icon back, now.
                    self.outstanding.removeAll()
                    self.reportedKeepErrors.removeAll()
                    self.keeper.forgetRefusals()
                    self.keeper.request(nil)
                }
                if !result.errors.isEmpty {
                    self.report(self.status + "\n\n" + result.errors.joined(separator: "\n"))
                }
            }, onError: failed)
            if !applying {
                finish()
                self.status = "BetterIcon was busy. Try again in a moment."
            }
        }, onError: failed)
        if !started {
            finish()
            status = "BetterIcon was busy. Try again in a moment."
            call("showError", ["id": "status", "message": shownStatus])
        }
    }
    private func editor(_ mode: String, group: String = "apps") {
        let pack = group == "files" ? fileSelection : selected
        guard mode == "new" || (!pack.isDefault && (mode != "edit" || pack.personal)) else { return }
        editing = mode == "edit" ? pack : nil
        editingGroup = group
        // A personal pack stores one image per format, so each can be replaced on its own.
        files = mode == "new" ? [:] : storedFiles(pack)
        modal = true
        let name = mode == "edit" ? pack.name : library.copyName(mode == "new" ? .defaults : pack)
        var labels = [String: String](), hints = [String: String]()
        for format in published.formats {
            labels[format.Key] = "\(format.label) (\(format.Application))"
            hints[format.Key] = format.extensions.joined(separator: ", ")
        }
        // An app's art for the file types outside the list has a row of its own while the pack has such art.
        let others = files.keys.filter { $0.hasPrefix(sharedFileArt) }.sorted()
        for key in others {
            let app = Craft.displayName(String(key.dropFirst()))
            labels[key] = "Other \(app) files"
            hints[key] = "File types outside BetterIcon’s list that open in \(app) by default"
        }
        call(
            "editor",
            [
                "info": [
                    "apps": Craft.names + published.formats.map(\.Key) + others, "edit": editing != nil, "files": files.mapValues(\.lastPathComponent),
                    "labels": labels, "hints": hints, "name": name, "author": mode == "new" ? "" : pack.author,
                ] as [String: Any]
            ])
    }
    private func importPack(zip: Bool) {
        guard let source = chooseFile(folder: !zip, zip: zip) else { return }
        background("Importing icon pack…", work: { try self.library.importPack(source) }) { id in
            self.selectSaved(id, "Icon pack imported.")
        }
    }
    // A saved pack becomes the choice in the list it was made from, when it has artwork for that list.
    private func selectSaved(_ id: String, _ message: String, group: String = "apps") {
        let pack = packs.first { $0.id == id }
        if let pack, group == "files" ? pack.canFiles : !pack.canApps {
            prefs.fileSelected = id
        } else { prefs.selected = id }
        rangeForSelection()
        status = message
        savePrefs()
        // An edited pack's folders follow its new art at once.
        keepFoldersUpToDate(rescan: .changed)
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
    private func storedFiles(_ pack: Pack) -> [String: URL] { published.storedFiles(pack) }
    private func chooseIcon(_ craft: String) {
        guard Craft.names.contains(craft), let url = chooseFile() else { return }
        let pack = selected
        let name = pack.personal ? pack.name : library.copyName(pack)
        var assignments = storedFiles(pack)
        assignments[craft] = url
        let newFiles = assignments
        background(
            "Saving " + craft + " artwork…",
            work: {
                try self.library.store(
                    name: name, author: pack.author, files: newFiles, editing: pack.personal ? pack : nil)
            }
        ) { id in
            self.selectSaved(id, craft + " artwork saved. Apply icons to change the installed app.")
        }
    }
    private func unhide() {
        do {
            try library.restoreBuiltins()
            status = "Built-in packs restored."
            keepFoldersUpToDate(rescan: .changed)
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
        case "previewPack":
            preview(data["id"] as? String ?? "", token: data["token"] as? Int ?? 0, files: data["group"] as? String == "files")
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
            guard let c = data["color"] as? String, Themes.styles.contains(c), let v = data["variant"] as? String,
                ["auto", "dark", "light"].contains(v)
            else { return }
            prefs.color = c
            prefs.variant = v
            // A named Dark or Light icon brings its own color scheme. Match app theme follows the theme button.
            if v != "auto" { prefs.theme = v == "dark" ? "Dark" : "Light" }
            style()
            savePrefs()
            render()
        case "editor": editor(data["mode"] as? String ?? "new", group: data["group"] as? String ?? "apps")
        case "pickAssignment":
            let other = craft.hasPrefix(sharedFileArt) && Craft.names.contains(String(craft.dropFirst()))
            if modal, Craft.names.contains(craft) || library.projectKeys.contains(craft) || other, let file = chooseFile() {
                files[craft] = file
                call("assignment", ["craft": craft, "name": file.lastPathComponent])
            }
        case "clearAssignment": if modal { files.removeValue(forKey: craft) }
        case "savePack":
            guard modal, let name = data["name"] as? String, let author = data["author"] as? String else { return }
            let files = self.files
            let edit = editing, group = editingGroup
            background(
                "Saving icon pack…",
                work: { try self.library.store(name: name, author: author, files: files, editing: edit) },
                done: { id in
                    self.call("doneDialog", ["id": "editor"])
                    self.selectSaved(id, "Icon pack saved.", group: group)
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
                    (p.personal
                        ? "Remove this personal pack from your library. Applied icons keep their artwork."
                        : "Hide this built-in pack. Restore built-in packs brings it back.")
                        + (p.canApps && p.canFiles ? " It leaves both the app and the file type list." : ""),
                    buttons: ["Remove pack", "Cancel"]) == 0
            {
                do {
                    try library.remove(p)
                    if p.id == prefs.fileSelected { prefs.fileSelected = nil }
                    if p.id == prefs.selected { prefs.selected = fallback.id }
                    status = "Pack removed."
                    rangeForSelection()
                    savePrefs()
                    // The folders it kept are no longer watched, as when their pack is not on this Mac.
                    keepFoldersUpToDate(rescan: .changed)
                    render()
                } catch { report(error.localizedDescription) }
            }
        case "unhide": unhide()
        case "openAtLogin": setOpenAtLogin(data["value"] as? Bool ?? false)
        case "openLoginSettings": loginItem?.openSettings()
        case "downloadPacks": downloadPacks(apps: data["apps"] as? Bool ?? false, files: data["files"] as? Bool ?? false)
        case "closeDownloads":
            guard downloadSummary != nil else { return }
            downloadSummary = nil
            if status.isEmpty { status = Self.idleStatus }
            render()
        case "skipPacks":
            guard prefs.offerPacks == true else { return }
            prefs.offerPacks = nil
            status = "Each icon pack downloads when you choose it in Manage Icons."
            savePrefs()
            render()
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
        if loginItem != nil {
            // Checked only while macOS really opens BetterIcon at login.
            followLoginItem()
            let on = loginState == .enabled
            add("Open at Login", to: menu) { self.setOpenAtLogin(!on) }.state = on ? .on : .off
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
