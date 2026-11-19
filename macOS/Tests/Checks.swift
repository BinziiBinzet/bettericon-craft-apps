import AppKit
import Carbon.HIToolbox
import WebKit

@main struct Checks {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try value() else { throw Problem("FAILED: " + name) }
        checks += 1
    }
    static func rejects(_ name: String, _ action: () throws -> Void) throws {
        do { try action() } catch {
            checks += 1
            return
        }
        throw Problem("FAILED: " + name)
    }
    static func run(_ exe: String, _ arguments: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
    static func fixtureApp(_ dir: URL, _ name: String, id: String, icon: URL) throws -> URL {
        let app = dir.appendingPathComponent(name + ".app", isDirectory: true)
        let c = app.appendingPathComponent("Contents")
        try fm.createDirectory(at: c.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: c.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: c.appendingPathComponent("MacOS/Example"))
        try fm.copyItem(at: icon, to: c.appendingPathComponent("Resources/Original.icns"))
        let plist = [
            "CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Example", "CFBundleIconFile": "Original", "CFBundleVersion": "1",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(
            to: c.appendingPathComponent("Info.plist"))
        try check(run("/usr/bin/codesign", ["-fs", "-", app.path]) == 0, "sign disposable fixture")
        return app
    }
    static func forkBytes(_ url: URL) throws -> Data {
        try Data(contentsOf: url.appendingPathComponent("Icon\r/..namedfork/rsrc"))
    }
    static func systemImage(_ url: URL) throws -> [UInt8] {
        let png = try Artwork.png(NSWorkspace.shared.icon(forFile: url.path), pixels: 128)
        guard let rep = NSBitmapImageRep(data: png), let bytes = rep.bitmapData else {
            throw Problem("Could not sample the system icon.")
        }
        return Array(UnsafeBufferPointer(start: bytes, count: rep.bytesPerRow * rep.pixelsHigh))
    }
    static func distance(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count else { return 1 }
        let total = zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(a.count * 255)
    }
    static func shortcuts() throws {
        let choice = Preferences().hotkey
        try check(choice.enabled && choice.text == "⌃⌥A" && choice.isVoiceOverReadAll, "fresh launcher shortcut")
        let old = Data(#"{"enabled":true,"control":true,"option":true,"shift":true,"command":false,"key":"A"}"#.utf8)
        let stored = try JSONDecoder().decode(KeyChoice.self, from: old)
        try check(stored.text == "⌃⌥⇧A" && !stored.isVoiceOverReadAll, "preserve a previously saved shortcut")
        var presses = 0
        let launcher = GlobalKey { presses += 1 }
        let disabled = KeyChoice(enabled: false)
        try check(try launcher.use(choice, voiceOverEnabled: true).contains("VoiceOver"), "VoiceOver gets Read All")
        try check(choice.displayText(registered: launcher.isRegistered) == "⌃⌥A (unavailable)", "VoiceOver-paused shortcut keeps its combination in the footer")
        try check(try launcher.use(disabled, voiceOverEnabled: true).contains("disabled"), "disabled stays disabled")
        try check(disabled.displayText(registered: launcher.isRegistered) == "Disabled", "disabled shortcut label")

        // Opt in on a Mac where the default is available. All events stay inside this test process.
        guard ProcessInfo.processInfo.environment["BETTERICON_TEST_HOTKEY"] == "1" else { return }
        guard !NSWorkspace.shared.isVoiceOverEnabled else { throw Problem("VoiceOver is using the test shortcut.") }
        let other = GlobalKey {}
        func deliver() throws {
            var event: EventRef?
            guard CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), GetCurrentEventTime(),
                0, &event) == noErr, let event else { throw Problem("Could not create a test hotkey event.") }
            defer { ReleaseEvent(event) }
            var id = EventHotKeyID(signature: 0x4249_434E, id: UInt32(kVK_ANSI_A) + choice.modifiers)
            guard SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                MemoryLayout<EventHotKeyID>.size, &id) == noErr else { throw Problem("Could not set test hotkey ID.") }
            SendEventToEventTarget(event, GetApplicationEventTarget())
        }
        _ = try launcher.use(choice, voiceOverEnabled: false)
        try deliver()
        try check(choice.displayText(registered: launcher.isRegistered) == "⌃⌥A", "registered shortcut label")
        try check(presses == 1, "registered hotkey dispatches to the launcher callback")
        try rejects("an occupied shortcut is refused") { _ = try other.use(choice, voiceOverEnabled: false) }
        _ = try launcher.use(choice, voiceOverEnabled: true)
        try deliver()
        try check(presses == 1, "a queued event cannot open the paused launcher")
        _ = try other.use(choice, voiceOverEnabled: false)
        try rejects("another owner can take the released shortcut") { _ = try launcher.use(choice, voiceOverEnabled: false) }
        _ = try other.use(disabled)
        _ = try launcher.use(choice, voiceOverEnabled: false)
        try rejects("an invalid edit preserves the working shortcut") {
            _ = try launcher.use(KeyChoice(control: false, option: false), voiceOverEnabled: false)
        }
        try deliver()
        try check(presses == 2, "launcher resumes after VoiceOver and keeps a working shortcut after an invalid edit")
    }
    static func core(resources: URL, root: URL) throws -> Installation {
        let user = root.appendingPathComponent("Applications")
        let all = root.appendingPathComponent("Shared")
        for folder in [user, all] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let icon = resources.appendingPathComponent("BetterIcon.icns")
        let photo = try fixtureApp(user, "PhotoCraft", id: "local.bettericon.test.photo", icon: icon)
        let film = try fixtureApp(all, "FilmCraft", id: "local.bettericon.test.film", icon: icon)
        _ = try fixtureApp(user, "Uninstall PhotoCraft", id: "local.bettericon.uninstall", icon: icon)
        _ = try fixtureApp(user, "PhotoCraftBackup", id: "local.bettericon.unrelated", icon: icon)
        let alias = user.appendingPathComponent("My film shortcut")
        let bookmark = try film.bookmarkData(
            options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: alias)
        let installed = try Installation(resources: resources, fixture: root)
        let apps = installed.catalog.discover()
        try check(
            apps.count == 3 && apps.contains(where: { $0.isAlias && $0.craft == "FilmCraft" }),
            "real bundles, aliases, and exclusion rules")
        let tiles: [[String: Any]] = [
            ["tile-data": ["file-data": ["_CFURLString": film.absoluteString]]],
            ["tile-data": ["file-data": ["_CFURLString": "https://example.invalid"]]],
        ]
        try check(AppCatalog.dockURLs(tiles) == [film], "only local Dock file references enter discovery")
        let published = try PublishedPacks(resources: resources, state: root.appendingPathComponent("test-pack-cache"))
        var packs = try published.list()
        let slim = packs.allSatisfy { $0.status == "Download" }
        try check(packs.count == 32 && packs.reduce(0) { $0 + $1.icons.count } == (slim ? 0 : 452), "edition artwork inventory")
        if slim {
            _ = try published.list("acquire", id: "Craft-Icons-Zach/Cardboard")
            packs = try published.list("acquire", id: "Craft-Icons-Zach/Edgework")
        }
        let cardboard = packs.first { $0.name == "Cardboard" }!
        let edge = packs.first { $0.name == "Edgework" }!
        let photoArt = cardboard.icons["PhotoCraft"]!
        let filmArt = cardboard.icons["FilmCraft"]!
        let lib = try PackLibrary(installed.state.appendingPathComponent("Packs"))
        lib.projectKeys = Set(published.formats.map(\.Key))
        lib.projectApps = Set(published.formats.map(\.Application))
        let docID = try lib.store(name: "Project only", author: "Fixture", files: [".pcraft": photoArt])
        let doc = lib.visible(packs).first { $0.id == docID }!
        let localPreview = try published.preview(doc)
        try check(localPreview.flatMap { NSImage(contentsOf: $0) } != nil, "personal file pack produces a local hover preview")
        let archive = root.appendingPathComponent("documents.zip")
        try lib.export(doc, to: archive)
        try lib.remove(doc)
        let roundID = try lib.importPack(archive)
        let round = lib.visible(packs).first { $0.id == roundID }!
        try check(!round.canApps && round.canFiles && round.documents[".pcraft"] != nil, "FileTypes ZIP round trip")
        let file = root.appendingPathComponent("example.pcraft"), contents = Data("project data".utf8)
        try contents.write(to: file)
        let entry = AppEntry(name: "example.pcraft", craft: ".pcraft", url: file, launchURL: file, bundleID: "", scope: .personal, isDocument: true)
        let storeFiles = AppIcons(installed.state.appendingPathComponent("File Test"))
        let filePack = Pack(id: doc.id, name: doc.name, author: doc.author, icons: published.fileArt(round))
        let originalFile = try systemImage(file)
        for restore in [false, true] {
            let plan = storeFiles.review(apps: [entry], pack: filePack, scope: .personal, restore: restore)
            let result = try storeFiles.perform(plan, apps: [entry], pack: filePack)
            try check(result.changed.count == 1 && result.errors.isEmpty, "apply and restore a Finder project icon: " + result.errors.joined())
            let difference = try distance(systemImage(file), originalFile)
            try check(restore ? difference < 0.02 : difference > 0.05, "Finder resolves project file artwork")
            try check(try Data(contentsOf: file) == contents, "project data is preserved")
        }
        let first = try lib.store(
            name: "Mixed", author: "Artist", files: ["PhotoCraft": photoArt, "FilmCraft": filmArt])
        let p = lib.visible(packs).first { $0.id == first }!
        let revision = p.icons["FilmCraft"]!
        let second = try lib.store(
            name: "Mixed", author: "Artist",
            files: ["PhotoCraft": edge.icons["PhotoCraft"]!, "FilmCraft": revision], editing: p)
        try check(
            first == second && fm.fileExists(atPath: revision.path),
            "personal edit retains identity and older revision")
        let edited = lib.visible(packs).first { $0.id == second }!
        try check(
            try Data(contentsOf: edited.icons["FilmCraft"]!) == Data(contentsOf: filmArt),
            "unaltered assignments preserved")
        let zip = root.appendingPathComponent("A renamed export.zip")
        try lib.export(edited, to: zip)
        try lib.remove(edited)
        let importedID = try lib.importPack(zip)
        let imported = lib.visible(packs).first { $0.id == importedID }!
        try check(
            imported.name == "Mixed" && imported.author == "Artist" && imported.icons.count == 2,
            "Windows ZIP metadata and images round trip")
        try check(
            try Data(contentsOf: imported.icons["PhotoCraft"]!) == Data(contentsOf: edge.icons["PhotoCraft"]!),
            "ZIP preserves original artwork")
        try lib.remove(edge)
        try check(!lib.visible(packs).contains { $0.id == edge.id }, "hidden built-in pack")
        try lib.restoreBuiltins()
        try check(lib.visible(packs).contains { $0.id == edge.id }, "restore built-ins")
        let folder = root.appendingPathComponent("Folder pack")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let svg = Data(
            #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><defs><linearGradient id="g"><stop stop-color="red"/></linearGradient></defs><rect width="16" height="16" fill="url(#g)"/></svg>"#
                .utf8)
        try svg.write(to: folder.appendingPathComponent("PhotoCraft.svg"))
        try fm.copyItem(at: photoArt, to: folder.appendingPathComponent("PhotoCraft.png"))
        let folderID = try lib.importPack(folder)
        try check(
            lib.visible(packs).first { $0.id == folderID }?.icons["PhotoCraft"]?.pathExtension == "svg",
            "SVG wins over PNG")
        try svg.write(to: folder.appendingPathComponent("PhotoCraft-copy.svg"))
        try rejects("ambiguous preferred artwork is refused") { _ = try lib.importPack(folder) }
        try rejects("invalid image cannot replace an assignment") {
            _ = try Artwork.validate(Data([1, 2, 3]), ext: "png")
        }
        let bad = Data(
            #"<svg xmlns="http://www.w3.org/2000/svg"><image href="https://example.invalid/image.png"/></svg>"#
                .utf8)
        try rejects("external SVG image is refused") { _ = try Artwork.validate(bad, ext: "svg") }
        try check(Artwork.validate(Data(contentsOf: icon), ext: "icns") >= 512, "native ICNS decode")
        let store = AppIcons(installed.state.appendingPathComponent("App Icons"))
        func apply(_ pack: Pack, _ scope: Scope, _ restore: Bool = false, _ only: String? = nil) throws
            -> IconResult
        {
            let plan = store.review(apps: apps, pack: pack, scope: scope, restore: restore, only: only)
            let result = try store.perform(plan, apps: apps, pack: pack)
            try check(result.errors.isEmpty, "apply/restore completed: " + result.errors.joined(separator: " / "))
            return result
        }
        let original = try systemImage(film)
        let plan = store.review(apps: apps, pack: cardboard, scope: .shared, restore: false)
        try check(
            plan.rows.count == 1 && plan.rows[0].change
                && !fm.fileExists(atPath: film.appendingPathComponent("Icon\r").path),
            "preview is read-only and respects scope")
        let originalOther = try systemImage(photo)
        try check(try apply(cardboard, .shared).changed.count == 1, "apply to actual shared bundle")
        try check(
            try distance(systemImage(film), original) > 0.05 && distance(systemImage(photo), originalOther) < 0.02,
            "macOS resolves replacement; personal app stays original")
        try check(
            run("/usr/bin/codesign", ["--verify", film.path]) == 0,
            "sealed executable/resources verify while themed")
        try check(try apply(edge, .shared).changed.count == 1, "switch theme without replacing backup")
        try check(try apply(.defaults, .shared, true, "FilmCraft").changed.count == 1, "selective restore")
        try check(
            try distance(systemImage(film), original) < 0.02
                && run("/usr/bin/codesign", ["--verify", "--strict", film.path]) == 0,
            "original system artwork and strict signature restored")
        let external = NSImage(
            contentsOf: resources.appendingPathComponent("Brand/betterIcon_icon_clay_dark.png"))!
        try check(
            NSWorkspace.shared.setIcon(external, forFile: photo.path, options: []), "seed pre-existing Finder icon"
        )
        let custom = try forkBytes(photo)
        let stale = store.review(apps: apps, pack: edge, scope: .personal, restore: false, only: "PhotoCraft")
        _ = try apply(cardboard, .personal, false, "PhotoCraft")
        try rejects("stale review cannot overwrite a newer operation") {
            _ = try store.perform(stale, apps: apps, pack: edge)
        }
        _ = try apply(.defaults, .personal, true, "PhotoCraft")
        try check(try forkBytes(photo) == custom, "restore exact pre-existing custom resource fork")
        _ = try apply(cardboard, .personal, false, "FilmCraft")
        try check(
            (try URL(resolvingAliasFileAt: alias, options: .withoutUI)).resolvingSymlinksInPath().path == film.resolvingSymlinksInPath().path
                && (try distance(systemImage(film), original)) < 0.02,
            "Finder alias keeps launch target and does not alter shared bundle")
        _ = try apply(.defaults, .personal, true, "FilmCraft")
        _ = try apply(cardboard, .personal, false, "PhotoCraft")
        try check(
            NSWorkspace.shared.setIcon(external, forFile: photo.path, options: []),
            "simulate user changing an icon after Apply")
        let conflict = store.review(
            apps: apps, pack: .defaults, scope: .personal, restore: true, only: "PhotoCraft")
        try check(
            !conflict.rows[0].change && conflict.rows[0].message.contains("outside BetterIcon"),
            "preserve external icon changes")
        let rect = PopupWindow.placed(
            size: NSSize(width: 900, height: 818), reserving: NSSize(width: 300, height: 240), around: NSPoint(x: 1310, y: 15),
            in: NSRect(x: 20, y: 20, width: 1200, height: 700), belowMenu: false)
        try check(rect.maxX == 1220 && rect.minY == 20 && rect.height == 700, "popup clamped to current display")
        return installed
    }
    @MainActor static func ui(_ install: Installation, out: URL) async throws {
        let flat = "Craft-Icons-VimiummuimiV/Modern Flat"
        let personal = try PackLibrary(install.state.appendingPathComponent("Packs")).visible([])
        guard let appPack = personal.first(where: { $0.personal && $0.canApps }),
              let filePack = personal.first(where: { $0.personal && !$0.documents.isEmpty }) else {
            throw Problem("Missing personal pack fixtures")
        }
        _ = try updatePreferences(install.state) {
            $0.selected = appPack.id
            $0.fileSelected = flat + " - Bolt - Sliders"
        }
        let migrated = try Application(install, hidden: true)
        try check(migrated.prefs.selected == appPack.id && migrated.prefs.fileSelected == flat,
                  "old file selection migrates independently of a personal app pack")
        _ = try updatePreferences(install.state) {
            $0.selected = flat + " - Spark - Knob"
            $0.fileSelected = filePack.id
        }
        var openedURLs = [URL]()
        let host = try Application(install, hidden: true, openProjectURL: { url in
            openedURLs.append(url)
            return true
        })
        let prefs = try saved(Preferences.self, at: install.state.appendingPathComponent("preferences.json"), fallback: Preferences())
        try check(prefs.selected == flat && prefs.fileSelected == filePack.id, "app selection migrates on disk and preserves personal file choice")
        host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        // Offscreen WebKit and AppKit surface; no input to the desktop.
        let web = host.web!
        func js(_ source: String) async throws -> Any? { try await web.evaluateJavaScript(source) }
        func until(_ source: String) async throws {
            for _ in 0..<600 {
                if let b = try? await js(source) as? Bool, b { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw Problem("Interface timed out: " + source)
        }
        try await until("typeof model !== 'undefined' && model && model.apps.length===3 && !working")
        try check(true, "actual app discovers fixture apps and creates its grids")
        try await until("model.packs.filter(p=>p.id.startsWith('\(flat)')).length===1 && model.packs.some(p=>p.id==='\(flat)' && p.canApps && p.canFiles) && model.filePack.id==='\(filePack.id)'")
        var trayImage = false
        var flatItems = 0
        host.statusMenu { menu, _ in
            guard let themes = menu.item(withTitle: "Change icon theme")?.submenu,
                  let row = themes.items.first(where: { ($0.representedObject as? Pack)?.name == "Mascots" }),
                  let preview = themes.delegate as? TrayPackPreview else { return }
            flatItems = themes.items.filter { $0.title.hasPrefix("Modern Flat") }.count
            preview.menu(themes, willHighlight: row)
            let until = Date().addingTimeInterval(15)
            while Date() < until && !trayImage {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                trayImage = NSApp.windows.contains { $0.identifier?.rawValue == "BetterIconPackPreview" && $0.isVisible }
            }
            preview.menuDidClose(themes)
        }
        try check(flatItems == 1, "one Modern Flat menu bar choice")
        try check(trayImage, "menu bar pack hover displays a non-activating preview")
        let footerStyle = """
            ['fontFamily','fontSize','fontWeight','lineHeight','color'].every(
              key => getComputedStyle(el('launcherShortcut'))[key] === getComputedStyle(el('version'))[key])
            """
        let stylesMatch = try await js(footerStyle)
        try check(stylesMatch as? Bool == true, "shortcut and version share theme color and type")
        let inCorner = try await js("""
            (() => {
              const link = el('launcherShortcut').getBoundingClientRect(), grid = el('apps').getBoundingClientRect();
              return el('launcherShortcut').textContent === 'Launcher shortcut · ⌃⌥A' &&
                Math.abs(link.left - grid.left) < 1 && link.top >= grid.bottom &&
                link.right < innerWidth / 2 && innerHeight - link.bottom < 32;
            })()
            """)
        try check(inCorner as? Bool == true, "shortcut is at the lower left outside the scrolling grid")
        let slim = (try String(contentsOf: install.resources.appendingPathComponent("Catalog/edition"), encoding: .utf8)).contains("OnDemand")
        let cache = install.state.appendingPathComponent("pack-cache")
        try check(!fm.fileExists(atPath: cache.appendingPathComponent("acquired").path), "opening never downloads a pack")
        host.statusMenu { menu, _ in
            let i = menu.indexOfItem(withTitle: "Refresh available icon packs")
            if i >= 0 { menu.performActionForItem(at: i) }
        }
        try await until("model.status==='Available icon packs refreshed.' && !working")
        try check(!fm.fileExists(atPath: cache.appendingPathComponent("acquired").path), "native tray refresh fetches metadata only")
        try await until("page==='manage'")
        _ = try await js("el('filePacks').click();true")
        try await until("!el('packOptions').hidden")
        let mouse = """
          (()=>{const row=[...el('packOptions').children].find(r=>r.dataset.id==='Craft-Icons-4NovemberKilo/Mascots');
          row.scrollIntoView({block:'nearest'});const r=row.getBoundingClientRect();
          row.dispatchEvent(new MouseEvent('pointerover',{bubbles:true,clientX:r.left+12,clientY:r.top+r.height/2}));return true})()
          """
        _ = try await js(mouse)
        try await until("!el('hoverPreview').hidden && el('hoverPreview').naturalWidth===204")
        try check(!fm.fileExists(atPath: cache.appendingPathComponent("acquired").path), "WebP hover renders without downloading full artwork")
        _ = try await js("hoverRow.click();true")
        try await until("model.filePack.id==='Craft-Icons-4NovemberKilo/Mascots' && !working")
        let independent = try await js("model.pack.id!==model.filePack.id") as? Bool
        try check(independent == true, "file pack and app pack are independent")
        _ = try await js("el('packs').click();[...el('packOptions').children].find(r=>r.dataset.id==='Craft-Icons-Zach/Cardboard').click();true")
        try await until("model.pack.id==='Craft-Icons-Zach/Cardboard' && !working")
        try await until("model.pack.status==='\(slim ? "Downloaded" : "Included")'")
        _ = try await js("el('launcherTab').click();true")
        try await until("model.pack.id==='Craft-Icons-Zach/Cardboard' && model.prefs.size===48")
        try check(true, "fresh launch matches the Windows Cardboard preview at 48 pixels")
        if let surface = host.window.contentView {
            let p = NSPoint(x: surface.bounds.width - 18, y: 18)
            try check(surface.hitTest(p) === surface, "rounded corner exposes a diagonal resize handle")
        }
        _ = try await js(
            "el('packs').value='ArtCraft/Default';el('packs').dispatchEvent(new Event('change'));true")
        try await until("model.pack.default && !working")
        try await until("[...el('apps').querySelectorAll('img')].every(i=>i.complete&&i.naturalWidth>0)")
        try check(true, "WebKit loads actual system icon images")
        _ = try await js("document.dispatchEvent(new KeyboardEvent('keydown',{key:'p',bubbles:true}));true")
        try await until(
            "el('apps').children.length===1 && el('apps').firstChild.getAttribute('aria-selected')==='true'")
        _ = try await js(
            "document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));el('manageTab').click();el('packs').value='Craft-Icons-Zach/Cardboard';el('packs').dispatchEvent(new Event('change'));true"
        )
        try await until(
            "model.pack.id==='Craft-Icons-Zach/Cardboard'&&!working&&el('preview').children.length===20")
        try await until("[...el('preview').querySelectorAll('img')].every(i=>i.complete&&i.naturalWidth>0)")
        try check(true, "pack selection, keyboard search, and full-resolution preview")
        _ = try await js("el('names').click();true")
        try await until("model.prefs.names===false&&document.body.classList.contains('iconOnly')")
        _ = try await js("el('names').click();el('exact').focus();el('exact').value='112';el('exact').blur();true")
        try await until("model.prefs.size===112&&model.prefs.names===true")
        _ = try await js("if(model.prefs.theme==='System')el('appearance').click();true")
        try await until("model.prefs.theme==='Dark'")
        let darkStylesMatch = try await js(footerStyle)
        try check(darkStylesMatch as? Bool == true, "both footer controls follow appearance changes")
        let project = "https://github.com/BinziiBinzet/bettericon-craft-apps"
        let versionLink = try await js("el('version').href === '\(project)' && el('version').textContent === 'Better Icon for ArtCraft version \(host.version)'")
        try check(versionLink as? Bool == true, "the complete version text links to the BetterIcon repository")
        let localPage = web.url
        _ = try await js("""
            (() => {
              const link = el('version'), original = link.href;
              link.href = 'https://example.invalid/'; link.click();
              link.href = original; link.click();
              return true;
            })()
            """)
        for _ in 0..<100 {
            if !openedURLs.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try check(openedURLs.map(\.absoluteString) == [project] && web.url == localPage,
            "WebKit sends only the project URL to the external opener and keeps the launcher page loaded")
        _ = try await js("el('brand').click();true")
        let allVariants = try await js("el('menu').children.length===17 && !el('menu').hidden")
        try check(allVariants as? Bool == true, "all 16 icon variants plus match")
        _ = try await js("el('menu').children[1].click();true")
        try await until("model.prefs.color==='clay'&&model.prefs.variant==='dark'")
        _ = try await js("el('new').click();true")
        try await until("el('editor').open&&el('assignments').children.length===33")
        _ = try await js("el('editor').close();true")
        try await until("!el('editor').open")
        try check(true, "personal editor lists all canonical ArtCraft apps")
        let snapshot = try await web.takeSnapshot(configuration: nil)
        try Artwork.pngWide(snapshot).write(to: out.appendingPathComponent("manage-icons.png"))
        _ = try await js("el('launcherTab').click();true")
        try await until("page==='launcher'")
        let launcher = try await web.takeSnapshot(configuration: nil)
        try Artwork.pngWide(launcher).write(to: out.appendingPathComponent("launcher.png"))
        _ = try await js("document.dispatchEvent(new KeyboardEvent('keydown',{key:'p',bubbles:true}));true")
        let footerKeys = try await js("""
            (() => {
              const b = el('launcherShortcut'); b.focus();
              return ['Enter', ' '].every(key => b.dispatchEvent(new KeyboardEvent('keydown', {key,bubbles:true,cancelable:true}))) &&
                selected.apps !== '' && prefix === 'p';
            })()
            """)
        try check(footerKeys as? Bool == true, "Return and Space on the focused shortcut keep their native button action")
        let openKey = "el('launcherShortcut').click();true"
        _ = try await js(openKey)
        try await until("el('hotkey').open && page==='launcher'")
        let defaultShown = try await js(
            "el('keyEnabled').checked && el('mod-Control').checked && el('mod-Option').checked && !el('mod-Shift').checked && !el('mod-Command').checked && el('key').value==='A'")
        try check(defaultShown as? Bool == true, "launcher footer opens the existing editor with the saved shortcut")
        _ = try await js("el('key').value='F8';el('hotkey').querySelector('button[value=cancel]').click();true")
        try await until("!el('hotkey').open && page==='launcher' && prefix==='p' && el('launcherShortcut').textContent.endsWith('⌃⌥A')")
        try check(host.prefs.hotkey.text == "⌃⌥A", "cancel preserves the shortcut, tab and current filter")
        _ = try await js(openKey)
        try await until("el('hotkey').open")
        let prefFile = install.state.appendingPathComponent("preferences.json")
        let previousBytes = try Data(contentsOf: prefFile)
        do {
            defer { try? previousBytes.write(to: prefFile, options: .atomic) }
            try Data("incomplete fixture preferences".utf8).write(to: prefFile, options: .atomic)
            _ = try await js("el('key').value='F8';el('saveKey').click();true")
            try await until("el('hotkey').open && el('keyError').textContent.length > 0 && el('launcherShortcut').textContent.endsWith('⌃⌥A')")
            try check(host.prefs.hotkey.text == "⌃⌥A", "a preferences write failure keeps the old shortcut and editor open")
        }
        _ = try await js("el('mod-Control').click();el('mod-Command').click();el('key').value='F8';el('saveKey').click();true")
        try await until("!el('hotkey').open && page==='launcher' && model.prefs.hotkey.key==='F8' && el('launcherShortcut').textContent.endsWith('⌥⌘F8')")
        try check(try Application(install, hidden: true).prefs.hotkey.text == "⌥⌘F8", "custom shortcut survives relaunch")
        _ = try await js(openKey)
        try await until("el('hotkey').open")
        _ = try await js("el('keyEnabled').click();el('saveKey').click();true")
        try await until("!el('hotkey').open && !model.prefs.hotkey.enabled && el('launcherShortcut').textContent.endsWith('Disabled')")
        _ = try await js(openKey)
        try await until("el('hotkey').open && !el('keyEnabled').checked")
        _ = try await js("el('hotkey').close();true")
        try check(true, "the disabled shortcut remains editable from Launcher")
        let reloaded = try Application(install, hidden: true)
        try check(!reloaded.prefs.hotkey.enabled && reloaded.prefs.hotkey.text == "⌥⌘F8", "disabled custom shortcut survives relaunch")
        try check(
            reloaded.prefs.color == "clay" && reloaded.prefs.theme == "Dark" && reloaded.prefs.size == 112,
            "settings survive relaunch")
    }
    @MainActor static func tabWindows(resources: URL, root: URL) async throws {
        let compact = NSSize(width: 301, height: 241), manage = NSSize(width: 836, height: 606)
        let wide = NSSize(width: 1024, height: 540), legacy = NSSize(width: 870, height: 809)
        for screen in [NSRect(x: -1440, y: -200, width: 1440, height: 850),
                       NSRect(x: 40, y: 60, width: 640, height: 440), NSRect(x: -1, y: -1, width: 1, height: 1)] {
            for edge in [screen.origin, NSPoint(x: screen.maxX, y: screen.maxY)] {
                let a = PopupWindow.placed(size: compact, reserving: manage, around: edge, in: screen, belowMenu: false)
                let divider = PopupWindow.divider(of: a)
                let b = PopupWindow.anchored(size: manage, reserving: compact, at: divider, in: screen)
                try check(screen.contains(a) && screen.contains(b) && PopupWindow.divider(of: b) == divider,
                    "both tabs fit around the same divider on screen \(screen) near \(edge)")
            }
        }
        for name in ["Applications", "Shared"] {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let install = try Installation(resources: resources, fixture: root)
        let file = install.state.appendingPathComponent("preferences.json")
        var old = Preferences()
        old.width = Int(legacy.width); old.height = Int(legacy.height); old.color = "copper"
        try save(old, at: file)
        for pass in 0..<2 {
            // Exercise both opening routes without activating a window on the user's desktop.
            let host = try Application(install, hidden: true, presentWindow: { window in
                window.alphaValue = 0; window.ignoresMouseEvents = true; window.orderBack(nil)
            })
            host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            let web = host.web!, window = host.window!
            defer { window.orderOut(nil) }
            func waitFor(_ condition: String) async throws {
                for _ in 0..<150 {
                    if (try? await web.evaluateJavaScript(condition) as? Bool) == true { return }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                throw Problem("Tab window timed out: \(condition). AppKit frame \(window.frame)")
            }
            func ready(_ tab: PopupTab, _ size: NSSize) async throws {
                try await waitFor("page === '\(tab.rawValue)' && innerWidth === \(Int(size.width)) && innerHeight === \(Int(size.height)) && el('manageTab').getBoundingClientRect().left === Math.floor(innerWidth / 2)")
                try check(window.frame.size == size && window.minSize == tab.minimum, "\(tab.rawValue) restores its size and minimum on pass \(pass)")
            }
            func clickTab(_ tab: PopupTab, _ size: NSSize) async throws {
                _ = try await web.evaluateJavaScript("el('\(tab.rawValue)Tab').click()")
                try await ready(tab, size)
            }
            func clickMenuBar() throws {
                try check(NSApp.sendAction(NSSelectorFromString("statusClick"), to: host, from: nil),
                    "AppKit delivers the menu bar button action")
            }
            func resize(_ size: NSSize) async throws {
                let grip = try await web.evaluateJavaScript(
                    "(()=>{const r=el('resizeGrip').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()")
                guard let xy = grip as? [Double], xy.count == 2 else { throw Problem("Missing window resize grip") }
                let local = NSPoint(x: xy[0], y: web.isFlipped ? xy[1] : web.bounds.height - xy[1])
                let start = window.convertPoint(toScreen: web.convert(local, to: nil))
                let delta = NSPoint(x: size.width - window.frame.width, y: window.frame.height - size.height)
                let events: [(NSEvent.EventType, CGFloat)] = [
                    (.leftMouseDown, 0), (.leftMouseDragged, 0.5), (.leftMouseDragged, 1), (.leftMouseUp, 1),
                ]
                for (type, fraction) in events {
                    let point = NSPoint(x: start.x + fraction * delta.x, y: start.y + fraction * delta.y)
                    guard let event = NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point),
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
                    else { throw Problem("Could not create the resize event") }
                    window.sendEvent(event)
                }
                try check(window.frame.size == size, "dragging the rendered grip resized the window to \(size)")
            }
            func dividerOnScreen() async throws -> NSPoint {
                guard let point = try await web.evaluateJavaScript(
                    "[el('manageTab').getBoundingClientRect().left, el('manageTab').getBoundingClientRect().top]") as? [Double], point.count == 2
                else { throw Problem("Could not read WebKit's tab divider.") }
                let local = NSPoint(x: point[0], y: web.isFlipped ? point[1] : web.bounds.height - point[1])
                return window.convertPoint(toScreen: web.convert(local, to: nil))
            }
            try await waitFor("!!model && !working")
            try clickMenuBar()
            try await ready(pass == 0 ? .launcher : .manage, pass == 0 ? legacy : manage)
            if pass == 0 {
                try await resize(compact)
                try await ready(.launcher, compact)
                let fits = try await web.evaluateJavaScript("""
                    (() => {
                      const link=el('launcherShortcut').getBoundingClientRect(), grid=el('apps').getBoundingClientRect();
                      return link.left >= 0 && link.right <= innerWidth && link.bottom <= innerHeight && grid.bottom <= link.top;
                    })()
                    """)
                try check(fits as? Bool == true, "the compact Launcher fits its shortcut and grid")
                _ = try await web.evaluateJavaScript("el('launcherShortcut').click()")
                try await waitFor("el('hotkey').open && el('hotkey').getBoundingClientRect().right <= innerWidth")
                _ = try await web.evaluateJavaScript("el('hotkey').close()")
                let join = try await dividerOnScreen()
                try await clickTab(.manage, legacy)
                let expanded = try await dividerOnScreen()
                try check(join == expanded, "switching from odd to even width preserves the rendered divider at \(join), observed \(expanded)")
                try await resize(manage)
            }
            try await ready(.manage, manage)
            let join = try await dividerOnScreen()
            for tab in [PopupTab.launcher, .manage, .launcher, .manage] {
                try await clickTab(tab, tab == .launcher ? compact : manage)
                let rendered = try await dividerOnScreen()
                try check(rendered == join, "tab click keeps the WebKit divider at \(join) in AppKit screen coordinates")
            }
            _ = try await web.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}))")
            try await ready(.launcher, compact)
            let escaped = try await dividerOnScreen()
            try check(escaped == join, "Escape switches back around the same divider")
            try clickMenuBar()
            try check(!window.isVisible, "a second menu bar click hides BetterIcon")
            try clickMenuBar()
            try await ready(.manage, manage)
            let menuTop = window.frame.maxY
            try check(window.screen.map { abs($0.visibleFrame.maxY - menuTop) <= 2 } == true,
                "the larger Manage Icons window opens at the menu bar")
            host.show(atCursor: true)
            try await ready(.launcher, compact)
            if pass == 0 {
                try await resize(wide)
                window.orderOut(nil); try clickMenuBar()
                try await ready(.launcher, wide)
                try await resize(compact)
            }
            let stored = try saved(Preferences.self, at: file, fallback: Preferences())
            try check(stored.launcherWindowSize == compact && stored.manageWindowSize == manage && stored.color == "copper",
                "resizing or opening one tab preserves the other tab and unrelated preferences")
        }
    }
    @MainActor static func runQuitMenuApp(resources: URL, fixture: URL) throws {
        let app = NSApplication.shared
        let host = try Application(Installation(resources: resources, fixture: fixture), hidden: true)
        app.delegate = host
        var key: GlobalKey?
        if ProcessInfo.processInfo.environment["BETTERICON_TEST_HOTKEY"] == "1" {
            key = GlobalKey {}
            _ = try key?.use(KeyChoice())
        }
        Task { @MainActor in
            do {
                let ready = "typeof model !== 'undefined' && !!model && !working"
                for _ in 0..<150 {
                    if let web = host.web, let loaded = try? await web.evaluateJavaScript(ready) as? Bool, loaded {
                        host.statusMenu { menu, _ in
                            let index = menu.indexOfItem(withTitle: "Exit BetterIcon")
                            guard index >= 0, menu.item(at: index)?.isEnabled == true else { return }
                            // Record AppKit's termination notification only after selecting the real command.
                            _ = NotificationCenter.default.addObserver(
                                forName: NSApplication.willTerminateNotification, object: app, queue: nil
                            ) { _ in
                                try? Data().write(to: fixture.appendingPathComponent("quit-complete"))
                            }
                            menu.performActionForItem(at: index)
                        }
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        throw Problem("The Exit BetterIcon menu command returned without terminating the app.")
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                throw Problem("The quit test app did not finish loading.")
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(1)
            }
        }
        withExtendedLifetime((host, key)) { app.run() }
    }
    @MainActor static func checkQuitMenu(resources: URL, fixture: URL) async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--quit-menu", resources.path, fixture.path]
        try child.run()
        for _ in 0..<250 {
            if !child.isRunning { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if child.isRunning { child.terminate(); throw Problem("Timed out waiting for the quit test app.") }
        try check(child.terminationReason == .exit && child.terminationStatus == 0 &&
            fm.fileExists(atPath: fixture.appendingPathComponent("quit-complete").path),
            "Exit BetterIcon terminates the menu bar process during menu tracking")
        if ProcessInfo.processInfo.environment["BETTERICON_TEST_HOTKEY"] == "1" {
            let next = GlobalKey {}
            _ = try next.use(KeyChoice())
            try check(next.isRegistered, "a new process can register the launcher's shortcut after Exit BetterIcon")
        }
    }
    @MainActor static func main() async {
        do {
            if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--quit-menu" {
                try runQuitMenuApp(resources: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true),
                    fixture: URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true))
                return
            }
            guard CommandLine.arguments.count == 3 else {
                throw Problem("Usage: Checks /path/to/BetterIcon.app empty-test-directory")
            }
            _ = NSApplication.shared
            try shortcuts()
            let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
                .appendingPathComponent("Contents/Resources")
            let out = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).resolvingSymlinksInPath()
            guard !fm.fileExists(atPath: out.path) else { throw Problem("Choose a new fixture directory.") }
            let install = try core(resources: resources, root: out)
            try await ui(install, out: out)
            try await tabWindows(resources: resources, root: out.appendingPathComponent("tab-sizes"))
            try await checkQuitMenu(resources: resources, fixture: out)
            print("\(checks) checks passed. \(out.path)")
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}

extension Artwork {
    fileprivate static func pngWide(_ image: NSImage) throws -> Data {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let data = rep.representation(using: .png, properties: [:])
        else { throw Problem("Could not capture the test window.") }
        return data
    }
}
