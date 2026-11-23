import AppKit
import Carbon.HIToolbox
import CryptoKit
import UniformTypeIdentifiers
import WebKit

@main struct Checks {
    static var checks = 0
    /// With --reapply-only and BETTERICON_TEST_SOFT=1, every check is reported and a failure does not stop the
    /// run. That shows which of the re-apply checks fail on another build.
    static var soft = false
    static var softFailures = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        if soft {
            let passed = (try? value()) ?? false
            print((passed ? "PASS: " : "FAIL: ") + name)
            if passed { checks += 1 } else { softFailures += 1 }
            return
        }
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
    static func fixtureApp(_ dir: URL, _ name: String, id: String, icon: URL, version: String = "1") throws -> URL {
        let app = dir.appendingPathComponent(name + ".app", isDirectory: true)
        let c = app.appendingPathComponent("Contents")
        try fm.createDirectory(at: c.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: c.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: c.appendingPathComponent("MacOS/Example"))
        try fm.copyItem(at: icon, to: c.appendingPathComponent("Resources/Original.icns"))
        let plist = [
            "CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Example", "CFBundleIconFile": "Original", "CFBundleVersion": version,
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
    /// A plain test image: a rounded square in one color.
    static func paint(_ url: URL, _ color: NSColor) throws -> URL {
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { throw Problem("Could not draw test artwork.") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 16, y: 16, width: 224, height: 224), xRadius: 48, yRadius: 48).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw Problem("Could not encode test artwork.") }
        try png.write(to: url)
        return url
    }
    /// What a release disk image holds: the app at another version, outside every apps folder.
    static func release(_ root: URL, _ name: String, id: String, icon: URL, version: String) throws -> URL {
        let folder = root.appendingPathComponent("Releases/\(name)-\(version)-" + UUID().uuidString.prefix(6))
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return try fixtureApp(folder, name, id: id, icon: icon, version: version)
    }
    /// Install a release the way ArtCraft Launcher and the apps' own updaters do: copy it without resource forks,
    /// extended attributes or ACLs into a hidden staging folder beside the app, rename the old copy into a hidden
    /// backup folder, rename the new copy into place and delete the backup. As with the Launcher, another
    /// process makes the changes. `pause` runs after each step.
    static func launcherUpdate(_ app: URL, with release: URL, pause: (String) throws -> Void = { _ in }) throws {
        let parent = app.deletingLastPathComponent()
        let tag = String(UUID().uuidString.prefix(6))
        let staging = parent.appendingPathComponent(".artcraft-launcher-staging-\(getpid())-" + tag)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        try Data().write(to: staging.appendingPathComponent(".artcraft-launcher-staging"))
        let staged = staging.appendingPathComponent(app.lastPathComponent)
        guard try run("/usr/bin/ditto", ["--norsrc", "--noextattr", "--noacl", release.path, staged.path]) == 0 else {
            throw Problem("ditto could not stage the release")
        }
        try pause("staged")
        let backup = parent.appendingPathComponent(".artcraft-launcher-backup-" + tag)
        try fm.createDirectory(at: backup, withIntermediateDirectories: false)
        guard try run("/bin/mv", [app.path, backup.appendingPathComponent("old").path]) == 0 else {
            throw Problem("could not move the old copy aside")
        }
        try pause("moved aside")
        guard try run("/bin/mv", [staged.path, app.path]) == 0 else { throw Problem("could not move the new copy in") }
        try pause("swapped")
        guard try run("/bin/rm", ["-rf", backup.path, staging.path]) == 0 else { throw Problem("could not clean up") }
    }
    /// No custom icon on the bundle: what a Launcher update leaves.
    static func clean(_ app: URL) -> Bool {
        (try? customFlag(app)) == false && !fm.fileExists(atPath: app.appendingPathComponent("Icon\r").path)
    }
    static func recordURL(_ store: URL, _ path: String) -> URL {
        store.appendingPathComponent("records/" + digest(Data(path.utf8)) + ".json")
    }
    static func record(_ store: URL, _ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: recordURL(store, path)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    /// Make a record look as BetterIcon 1.28.0 wrote it, without the fields added for re-applying.
    static func strip(_ store: URL, _ path: String) throws {
        let url = recordURL(store, path)
        guard var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw Problem("Unreadable fixture record.")
        }
        for key in ["path", "bundleID", "version", "art", "iconFile", "gaveWay", "intent"] { json.removeValue(forKey: key) }
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
    /// BetterIcon's identity of an app: device, inode, bundle ID and Info.plist digest.
    static func identity(of app: AppEntry) -> String {
        var st = stat()
        guard lstat(app.url.path, &st) == 0,
            let info = try? Data(contentsOf: app.launchURL.appendingPathComponent("Contents/Info.plist"))
        else { return "missing" }
        return "\(st.st_dev)/\(st.st_ino)/\(app.bundleID)/\(digest(info))"
    }
    /// Install a release where no copy is, as ArtCraft Launcher does after an uninstall: copy it into a hidden staging
    /// folder beside the path, rename it into place and remove the staging folder.
    static func launcherInstall(_ app: URL, with release: URL) throws {
        let parent = app.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".artcraft-launcher-staging-\(getpid())-" + UUID().uuidString.prefix(6))
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        let staged = staging.appendingPathComponent(app.lastPathComponent)
        guard try run("/usr/bin/ditto", ["--norsrc", "--noextattr", "--noacl", release.path, staged.path]) == 0,
            try run("/bin/mv", [staged.path, app.path]) == 0, try run("/bin/rm", ["-rf", staging.path]) == 0
        else { throw Problem("could not install the release") }
    }
    /// Change an app's icon from another process, as Finder's Get Info does. BetterIcon's watcher ignores the
    /// icon writes of its own process. Nil removes the custom icon.
    static func setIconElsewhere(_ art: URL?, _ target: URL) throws {
        let me = Bundle.main.executablePath ?? CommandLine.arguments[0]
        guard try run(me, ["--set-icon", art?.path ?? "none", target.path]) == 0 else {
            throw Problem("another process could not change the icon of " + target.lastPathComponent)
        }
    }
    /// An .icns file of test artwork, for a release whose own icon differs.
    static func icns(_ png: URL) throws -> URL {
        let out = png.deletingPathExtension().appendingPathExtension("icns")
        guard try run("/usr/bin/sips", ["-s", "format", "icns", png.path, "--out", out.path]) == 0 else {
            throw Problem("sips could not make an icns file")
        }
        return out
    }
    /// An image file drawn the way `systemImage` draws an app's icon, to compare the two.
    static func look(_ file: URL) throws -> [UInt8] {
        guard let image = NSImage(contentsOf: file), let rep = NSBitmapImageRep(data: try Artwork.png(image, pixels: 128)),
            let bytes = rep.bitmapData
        else { throw Problem("Could not sample " + file.lastPathComponent) }
        return Array(UnsafeBufferPointer(start: bytes, count: rep.bytesPerRow * rep.pixelsHigh))
    }
    /// The address the Launcher grid uses for an artwork file.
    static func artLink(_ file: URL) -> String { "bettericon-art://image/" + digest(Data(("file:" + file.path).utf8)) }
    /// Wait without holding the main thread, so the app's own main-queue work goes on.
    @MainActor static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > end { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }
    /// Icon Services can take a moment to show a change in a long-running process.
    static func eventually(_ seconds: Double = 3, _ condition: () throws -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while true {
            if (try? condition()) == true { return true }
            if Date() > end { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    /// A folder with personal and shared apps, its own BetterIcon state and its own releases.
    struct Scene {
        let root: URL, user: URL, all: URL, state: URL
        let store: AppIcons
        let catalog: AppCatalog
        func apps() -> [AppEntry] { catalog.discover() }
        func path(_ craft: String, _ scope: Scope? = nil) throws -> String {
            guard let app = apps().first(where: { $0.craft == craft && (scope == nil || $0.scope == scope) }) else {
                throw Problem(craft + " was not discovered")
            }
            return app.url.path
        }
        @discardableResult func apply(
            _ pack: Pack, scope: Scope? = nil, restore: Bool = false, only: String? = nil
        ) throws -> IconResult {
            let found = apps()
            let plan = store.review(apps: found, pack: pack, scope: scope, restore: restore, only: only)
            let result = try store.perform(plan, apps: found, pack: pack)
            guard result.errors.isEmpty else { throw Problem("fixture change failed: " + result.errors.joined(separator: " / ")) }
            return result
        }
    }
    static func scene(_ root: URL, _ name: String) throws -> Scene {
        let folder = root.appendingPathComponent(name)
        let user = folder.appendingPathComponent("Applications"), all = folder.appendingPathComponent("Shared")
        for apps in [user, all] { try fm.createDirectory(at: apps, withIntermediateDirectories: true) }
        let state = folder.appendingPathComponent("State/App Icons")
        return Scene(
            root: folder, user: user, all: all, state: state, store: AppIcons(state),
            catalog: AppCatalog(locations: [(user, .personal), (all, .shared)]))
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
        // ArtCraft Launcher leads the grid. The other apps follow by name.
        let leadFolder = root.appendingPathComponent("Lead order")
        try fm.createDirectory(at: leadFolder, withIntermediateDirectories: true)
        _ = try fixtureApp(leadFolder, "AniCraft", id: "local.bettericon.test.ani", icon: icon)
        _ = try fixtureApp(leadFolder, "ArtCraft Launcher", id: "local.bettericon.test.launcher", icon: icon)
        let ordered = installed.catalog.discover(extraFolders: [leadFolder]).map(\.craft)
        try check(
            ordered.count == 5 && Array(ordered.prefix(2)) == ["ArtCraftLauncher", "AniCraft"],
            "ArtCraft Launcher leads the app grid and the other apps follow by name")
        let tiles: [[String: Any]] = [
            ["tile-data": ["file-data": ["_CFURLString": film.absoluteString]]],
            ["tile-data": ["file-data": ["_CFURLString": "https://example.invalid"]]],
        ]
        try check(AppCatalog.dockURLs(tiles) == [film], "only local Dock file references enter discovery")
        let published = try PublishedPacks(resources: resources, state: root.appendingPathComponent("test-pack-cache"))
        var packs = try published.list()
        try check(
            packs.count == 41 && packs.allSatisfy { $0.status == "Download" && $0.icons.isEmpty && $0.appFiles.isEmpty }
                && !fm.fileExists(atPath: resources.appendingPathComponent("Packs").path),
            "the installer lists 41 packs and carries none of their artwork")
        let komplett = packs.filter { $0.id.hasPrefix("Craft-Icons-Komplett/") }
        let mike = packs.filter { $0.id.hasPrefix("Craft-Icons-Mike22/") }
        try check(komplett.count == 5 && komplett.allSatisfy { !$0.canApps && $0.canFiles && $0.icons.isEmpty }
            && mike.count == 3 && mike.allSatisfy { $0.canApps && $0.canFiles }
            && packs.filter(\.canFiles).count == 17 && packs.filter(\.canApps).count == 27,
            "Komplett's five packs and Mike22's three file type sets are file type packs")
        // Cardboard's PNG files serve as PNG art in the checks below, so it is fetched without its WebP twins. The others
        // come as the Mac fetches them: an icon's WebP twin alone.
        _ = try published.list("acquire", id: "Craft-Icons-Zach/Cardboard", readsWebP: false)
        _ = try published.list("acquire", id: "Craft-Icons-Komplett/Standard")
        _ = try published.list("acquire", id: "Craft-Icons-Mike22/CraftApps AIO November - Dark")
        packs = try published.list("acquire", id: "Craft-Icons-Zach/Edgework")
        let cardboard = packs.first { $0.name == "Cardboard" }!
        let edge = packs.first { $0.name == "Edgework" }!
        let photoArt = cardboard.icons["PhotoCraft"]!
        let filmArt = cardboard.icons["FilmCraft"]!
        let standard = packs.first { $0.id == "Craft-Icons-Komplett/Standard" }!
        let standardFiles = (fm.enumerator(at: root.appendingPathComponent("test-pack-cache/pack-cache/downloads"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []).filter { $0.path.contains("/Craft-Icons-Komplett/Standard/") && !$0.hasDirectoryPath }
        try check(
            Set(cardboard.icons.values.map(\.pathExtension)) == ["png"] && !standardFiles.isEmpty
                && Set(standardFiles.map(\.pathExtension)) == ["webp"] && Set(standard.appFiles.values.map(\.pathExtension)) == ["webp"],
            "a published pack downloads one file per icon: its WebP twins, or its PNG files when asked for those")
        let standardArt = published.fileArt(standard), standardTiles = published.fileTiles(standard)
        try check(!cardboard.canFiles && published.fileArt(cardboard).isEmpty && standard.appFiles.count == 14
            && standardArt.count == 27 && standardArt[".psd"] == standard.appFiles["PhotoCraft"] && standardArt[".anicraft"] == nil
            && standardTiles.count == 14 && standardTiles.contains { $0.name == "PhotoCraft" && $0.hint.contains(".png, .jpg +16") },
            "an app's file artwork covers every file type that app opens, and an app icon pack has none")
        let mixedPack = packs.first { $0.id == "Craft-Icons-Mike22/CraftApps AIO November - Dark" }!
        try check(
            mixedPack.status == "Downloaded" && mixedPack.icons.count == 15 && mixedPack.appFiles.count == 14
                && published.fileArt(mixedPack).count == 28,
            "a downloaded Mike22 pack carries both app icons and file type artwork")
        let lib = try PackLibrary(installed.state.appendingPathComponent("Packs"))
        lib.formats = published.formats
        let listed = lib.visible(packs)
        let authors = listed.dropFirst().map { $0.author.lowercased() }
        try check(
            listed.first?.isDefault == true && authors == authors.sorted()
                && zip(listed.dropFirst(), listed.dropFirst(2)).allSatisfy {
                    $0.author != $1.author || $0.name.lowercased() <= $1.name.lowercased()
                }
                && listed.firstIndex { $0.id == "Craft-Icons-Mains/Stained Glass" }! < listed.firstIndex { $0.id.hasPrefix("Craft-Icons-Mike22/") }!
                && listed.lastIndex { $0.id.hasPrefix("Craft-Icons-Mike22/") }! < listed.firstIndex { $0.id == "Craft-Icons-Zach/Cardboard" }!,
            "packs are listed by author, then by name, after the default")
        let sharedFolder = root.appendingPathComponent("Shared file art")
        try fm.createDirectory(at: sharedFolder.appendingPathComponent("FileTypes"), withIntermediateDirectories: true)
        try fm.copyItem(at: photoArt, to: sharedFolder.appendingPathComponent("FileTypes/PhotoCraft-PSD.png"))
        try fm.copyItem(at: filmArt, to: sharedFolder.appendingPathComponent("FileTypes/pcraft.png"))
        let sharedID = try lib.importPack(sharedFolder)
        let shared = lib.visible(packs).first { $0.id == sharedID }!
        try check(!shared.canApps && shared.canFiles && Set(shared.documents.keys) == [".pcraft", ".psd", ".png"]
            && (try Data(contentsOf: shared.documents[".pcraft"]!)) == (try Data(contentsOf: filmArt))
            && (try Data(contentsOf: shared.documents[".psd"]!)) == (try Data(contentsOf: photoArt)),
            "imported app-named file artwork is stored for each of the app's formats without replacing a format's own")
        try fm.copyItem(at: filmArt, to: sharedFolder.appendingPathComponent("FileTypes/PhotoCraft-PNG.png"))
        try rejects("two images for one app's files are refused") { _ = try lib.importPack(sharedFolder) }
        try lib.remove(shared)
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
        // WebP artwork is kept as PNG. The fixture is a 32 pixel square with transparent edges around a red center.
        let lossy = Data(base64Encoded: "UklGRoYAAABXRUJQVlA4WAoAAAAQAAAAHwAAHwAAQUxQSBQAAAABUNq2AZP/nw4sHCwiJoAZGv+td1ZQOCBMAAAA0AMAnQEqIAAgAADAEiWgAgAvwH4AfsB/gDK+UsIF+KQ22wf7OtcAAP7+ex//8gr//H8n//jjOf//azf//7eqPCwi1MICOKos6fgAAA==")!
        let lossless = Data(base64Encoded: "UklGRioAAABXRUJQVlA4TB0AAAAvH8AHEA8wPMM9KPMf8BDTEPqXdpsCEf2fAHq95QA=")!
        let webpFolder = root.appendingPathComponent("WebP pack")
        try fm.createDirectory(at: webpFolder.appendingPathComponent("FileTypes"), withIntermediateDirectories: true)
        try lossy.write(to: webpFolder.appendingPathComponent("PhotoCraft.webp"))
        try lossless.write(to: webpFolder.appendingPathComponent("FileTypes/pcraft.webp"))
        try lossless.write(to: webpFolder.appendingPathComponent("FilmCraft.webp"))
        try fm.copyItem(at: filmArt, to: webpFolder.appendingPathComponent("FilmCraft.png"))
        func square(_ file: URL?) -> Bool {
            guard let file, file.pathExtension == "png", let data = try? Data(contentsOf: file),
                let pixels = NSBitmapImageRep(data: data), pixels.pixelsWide == 32, pixels.pixelsHigh == 32,
                let corner = pixels.colorAt(x: 1, y: 1), let center = pixels.colorAt(x: 16, y: 16)
            else { return false }
            return corner.alphaComponent == 0 && center.alphaComponent == 1 && center.redComponent > 0.75
                && center.greenComponent < 0.4
        }
        let webpID = try lib.importPack(webpFolder)
        let webp = lib.visible(packs).first { $0.id == webpID }!
        // FilmCraft comes as a WebP and a PNG. The WebP, the 32 pixel square, wins.
        try check(
            square(webp.icons["PhotoCraft"]) && square(webp.documents[".pcraft"]) && square(webp.icons["FilmCraft"]),
            "WebP artwork is kept as PNG with its transparency, and WebP is preferred over a PNG of the same icon")
        let chosenWebP = root.appendingPathComponent("chosen.webp")
        try lossless.write(to: chosenWebP)
        let chosenID = try lib.store(name: "WebP choice", author: "", files: ["PhotoCraft": chosenWebP])
        try check(
            square(lib.visible(packs).first { $0.id == chosenID }?.icons["PhotoCraft"]),
            "a chosen WebP icon is stored as PNG")
        try rejects("a PNG named as WebP is refused") {
            _ = try Artwork.validate(Data(contentsOf: photoArt), ext: "webp")
        }
        // File icons for a whole folder: every matching file, new files, and only BetterIcon's own work undone.
        let projects = root.appendingPathComponent("Folder icons/Projects")
        try fm.createDirectory(at: projects.appendingPathComponent("Nested"), withIntermediateDirectories: true)
        let fileA = projects.appendingPathComponent("a.pcraft"), fileB = projects.appendingPathComponent("Nested/b.PCRAFT")
        let own = projects.appendingPathComponent("own.pcraft"), notes = projects.appendingPathComponent("notes.txt")
        let hidden = projects.appendingPathComponent(".hidden.pcraft")
        for file in [fileA, fileB, own, notes, hidden] { try Data("project".utf8).write(to: file) }
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: past], ofItemAtPath: fileA.path)
        try check(
            setFinderIcon(NSImage(contentsOf: icon), own.path),
            "a fixture file takes an icon of its own")
        let plainFile = try systemImage(fileA), ownIcon = try systemImage(own)
        let folderIcons = FolderIcons(formats: published.formats)
        func marked(_ file: URL) -> Bool { (try? attribute(FolderIcons.marker, file)) != nil }
        let covered = folderIcons.apply(projects, art: [".pcraft": photoArt])
        try check(
            covered.changed == 2 && covered.kept == 1 && covered.current == 0 && covered.errors.isEmpty
                && marked(fileA) && marked(fileB) && !marked(own) && !marked(notes) && !marked(hidden),
            "a folder's matching files take the pack's icon, and a file with its own icon is left alone: \(covered)")
        try check(
            try distance(systemImage(fileA), plainFile) > 0.05 && distance(systemImage(fileB), plainFile) > 0.05
                && distance(systemImage(own), ownIcon) < 0.02,
            "Finder shows the pack's icon on the covered files only")
        try check(
            try Data(contentsOf: fileA) == Data("project".utf8)
                && fileA.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == past,
            "a covered file keeps its contents and its modification date")
        let again = folderIcons.apply(projects, art: [".pcraft": photoArt])
        try check(again.changed == 0 && again.current == 2 && again.kept == 1, "a second pass changes nothing: \(again)")
        let fileC = projects.appendingPathComponent("Nested/c.pcraft")
        try Data("project".utf8).write(to: fileC)
        let later = folderIcons.apply(projects, art: [".pcraft": photoArt])
        try check(later.changed == 1 && later.current == 2 && marked(fileC), "a new file in the folder takes the icon: \(later)")
        let coveredIcon = try systemImage(fileA)
        let switched = folderIcons.apply(projects, art: [".pcraft": filmArt])
        try check(
            switched.changed == 3 && switched.kept == 1 && (try distance(systemImage(fileA), coveredIcon)) > 0.02,
            "another pack replaces the icons BetterIcon set: \(switched)")
        let reported = DispatchSemaphore(value: 0)
        let watcher = FolderWatcher { files in
            if files.contains(where: { $0.lastPathComponent == "d.pcraft" }) { reported.signal() }
        }
        watcher.watch([projects])
        Thread.sleep(forTimeInterval: 0.8)
        try Data("project".utf8).write(to: projects.appendingPathComponent("d.pcraft"))
        try check(reported.wait(timeout: .now() + 15) == .success, "a watched folder reports a new file")
        watcher.stop()
        let undone = folderIcons.restore(projects)
        try check(
            undone.restored == 3 && undone.errors.isEmpty && !marked(fileA) && !marked(fileB) && !marked(fileC)
                && (try distance(systemImage(fileA), plainFile)) < 0.02 && (try distance(systemImage(own), ownIcon)) < 0.02,
            "restoring a folder removes only the icons BetterIcon set: \(undone)")
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
        // An interrupted change can leave the custom-icon flag without its icon. Finder then draws a generic icon.
        let iconFile = film.appendingPathComponent("Icon\r")
        _ = try apply(cardboard, .shared)
        try fm.removeItem(at: iconFile)
        let halfway = store.review(apps: apps, pack: edge, scope: .shared, restore: false)
        try check(halfway.rows.count == 1 && halfway.rows[0].change, "a half-finished icon change is offered again instead of being left alone")
        try check(try apply(edge, .shared).changed.count == 1 && distance(systemImage(film), original) > 0.05,
            "applying a pack repairs an app left with a generic icon")
        try fm.removeItem(at: iconFile)
        try check(try apply(.defaults, .shared, true).changed.count == 1, "a half-finished icon change can be restored")
        try check(
            try distance(systemImage(film), original) < 0.02
                && run("/usr/bin/codesign", ["--verify", "--strict", film.path]) == 0,
            "restoring removes the leftover flag, so the app shows its own icon again")
        let external = NSImage(
            contentsOf: resources.appendingPathComponent("Brand/betterIcon_icon_clay_dark.png"))!
        try check(
            setFinderIcon(external, photo.path), "seed pre-existing Finder icon"
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
            setFinderIcon(external, photo.path),
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
        // A new installation has applied nothing. A pack that is only chosen there must not reach the Launcher.
        for upgraded in [false, true] {
            let folder = fm.temporaryDirectory.appendingPathComponent("bettericon-new-" + UUID().uuidString)
            defer { try? fm.removeItem(at: folder) }
            for name in ["Applications", "Shared"] {
                try fm.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            let new = try Installation(resources: install.resources, fixture: folder)
            if upgraded { _ = try updatePreferences(new.state) { $0.selected = "Craft-Icons-Zach/Ink" } }
            let applied = try Application(new, hidden: true).prefs.appliedPack
            try check(applied == (upgraded ? "Craft-Icons-Zach/Ink" : Pack.defaults.id), upgraded
                ? "an upgraded installation keeps showing the pack it had chosen"
                : "a new installation starts with the original icons as the applied pack")
        }
        _ = try updatePreferences(install.state) {
            $0.selected = appPack.id
            $0.fileSelected = flat + " - Bolt - Sliders"
        }
        let migrated = try Application(install, hidden: true)
        try check(migrated.prefs.selected == appPack.id && migrated.prefs.fileSelected == nil,
                  "an app icon pack saved as the file choice gives way to the original file icons, keeping the personal app pack")
        _ = try updatePreferences(install.state) {
            $0.selected = flat + " - Spark - Knob"
            $0.fileSelected = filePack.id
        }
        var openedURLs = [URL]()
        let allowPackCheck = DispatchSemaphore(value: 0)
        let host = try Application(install, hidden: true, openProjectURL: { url in
            openedURLs.append(url)
            return true
        }, checkPackUpdates: { previous in
            guard previous == nil, allowPackCheck.wait(timeout: .now() + 60) == .success else {
                throw Problem("Unexpected startup pack update check")
            }
            return PackUpdateCheck(revision: "published", baseline: "seed", count: 2)
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
        // In core, the user changed PhotoCraft's icon after Apply. The app notices at its start and leaves it alone.
        try await until("model.status.startsWith('PhotoCraft keeps the icon you gave it.')")
        try check(true, "at its start BetterIcon notices an icon the user gave an app after Apply, leaves it alone and says so")
        try await until("model.packs.filter(p=>p.id.startsWith('\(flat)')).length===1 && model.packs.some(p=>p.id==='\(flat)' && p.canApps && !p.canFiles) && model.filePack.id==='\(filePack.id)'")
        let lists = try await js("""
            (() => {
              const komplett = model.packs.filter(p => p.id.startsWith('Craft-Icons-Komplett/'));
              return komplett.length === 5 && komplett.every(p => !p.canApps && p.canFiles) &&
                model.packs.filter(p => p.canFiles && !p.default && !p.personal).length === 17 &&
                model.packs.find(p => p.default).canFiles;
            })()
            """)
        try check(lists as? Bool == true, "the file type list holds the seventeen file type packs and the original file icons")
        var trayImage = false
        var flatItems = 0, fileItems = 0
        host.statusMenu { menu, _ in
            guard let themes = menu.item(withTitle: "Change icon theme")?.submenu,
                  let row = themes.items.first(where: { ($0.representedObject as? Pack)?.name == "Mascots" }),
                  let preview = themes.delegate as? TrayPackPreview else { return }
            flatItems = themes.items.filter { $0.title.hasPrefix("Modern Flat") }.count
            fileItems = themes.items.filter { $0.title.contains("Komplett") }.count
            preview.menu(themes, willHighlight: row)
            let until = Date().addingTimeInterval(15)
            while Date() < until && !trayImage {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                trayImage = NSApp.windows.contains { $0.identifier?.rawValue == "BetterIconPackPreview" && $0.isVisible }
            }
            preview.menuDidClose(themes)
        }
        try check(flatItems == 1 && fileItems == 0, "one Modern Flat menu bar choice, and no file type pack among the app icon themes")
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
        let cache = install.state.appendingPathComponent("pack-cache")
        func acquired() -> Int { ((try? fm.contentsOfDirectory(atPath: cache.appendingPathComponent("acquired").path)) ?? []).count }
        try check(acquired() == 1 && host.prefs.selected == flat, "opening downloads nothing but the app pack that was chosen before")
        let shown = try await js("model.pack.id==='\(flat)' && model.pack.status==='Downloaded'") as? Bool
        try check(shown == true, "a chosen pack that was not on the computer is downloaded again and shown as the choice")
        let packsBeforeCheck = try await js("JSON.stringify(model.packs)") as? String
        let selectionsBeforeCheck = [host.prefs.selected, host.prefs.fileSelected]
        allowPackCheck.signal()
        try await until("model.packUpdateCount === 2 && el('refreshPacks').classList.contains('has-pack-updates')")
        let packBadge = try await js("""
            (() => {
                const button = el('refreshPacks'), dot = getComputedStyle(button, '::after');
                return page === 'launcher' && !working && !button.disabled && dot.width === '7px' &&
                    button.title === 'Refresh available icon packs' &&
                    button.getAttribute('aria-describedby') === 'packUpdateDescription' &&
                    el('packUpdateDescription').textContent === '2 new or updated icon packs available.';
            })()
            """)
        try check(packBadge as? Bool == true, "startup pack checks show an accessible badge without interrupting the launcher")
        let packsAfterCheck = try await js("JSON.stringify(model.packs)") as? String
        try check(packsBeforeCheck == packsAfterCheck && selectionsBeforeCheck == [host.prefs.selected, host.prefs.fileSelected] &&
                  acquired() == 1,
                  "startup pack checks preserve the displayed catalog and pack choices without downloading artwork")
        host.statusMenu { menu, _ in
            let i = menu.indexOfItem(withTitle: "Refresh available icon packs")
            if i >= 0 { menu.performActionForItem(at: i) }
        }
        try await until("model.status==='Available icon packs refreshed.' && !working")
        let badgeCleared = try await js("""
            model.packUpdateCount === 0 && !el('refreshPacks').classList.contains('has-pack-updates') &&
                !el('refreshPacks').hasAttribute('aria-describedby')
            """)
        try check(badgeCleared as? Bool == true, "successful manual refresh clears both the dot and its description")
        try check(acquired() == 1, "native tray refresh fetches metadata only")
        try await until("page==='manage'")
        let refreshLayout = try await js("""
            (() => {
                const apps = el('packs').getBoundingClientRect(), picker = el('filePacks'), button = el('refreshPacks');
                const a = picker.getBoundingClientRect(), b = button.getBoundingClientRect();
                return picker.nextElementSibling === button && b.left > a.right && a.left > apps.right &&
                    Math.abs(a.top - b.top) < 1 && Math.abs(a.height - b.height) < 1 &&
                    Math.abs(a.top - apps.top) < 1 && Math.abs(a.height - apps.height) < 1 &&
                    document.querySelectorAll('#refreshPacks').length === 1 &&
                    document.querySelector('label[for=packs]').textContent === 'App icon pack' &&
                    document.querySelector('label[for=filePacks]').textContent === 'File type icon pack' &&
                    button.title === 'Refresh available icon packs' &&
                    button.getAttribute('aria-label') === button.title &&
                    button.querySelector('svg path') !== null;
            })()
            """)
        try check(refreshLayout as? Bool == true, "the app and file type pickers share one row with a single refresh button at its right")
        let captions = try await js("""
            (() => {
                const shown = [...document.querySelectorAll('#manage .actions button')].filter(b => !b.hidden);
                return el('remove').textContent === 'Remove app pack' && el('removeFiles').textContent === 'Remove file pack' &&
                    el('restore').textContent === 'Restore app defaults…' &&
                    document.querySelector('label[for=slider]').textContent === 'Launcher icon size' &&
                    el('exact').getAttribute('aria-label') === 'Launcher icon size in pixels' &&
                    shown.every(b => b.scrollWidth <= b.clientWidth && b.getBoundingClientRect().height < 40);
            })()
            """)
        try check(captions as? Bool == true, "pack and apply buttons name the app or file pack they act on, and no caption is cut off")
        let refreshFrame = host.window.frame
        let selections = [host.prefs.selected, host.prefs.fileSelected]
        _ = try await js("""
            (() => {
                const button = el('refreshPacks');
                window.sawInlineRefresh = false;
                const observer = new MutationObserver(() => {
                    if (button.disabled) {
                        window.sawInlineRefresh = true;
                        observer.disconnect();
                    }
                });
                observer.observe(button, {attributes: true, attributeFilter: ['disabled']});
                button.click();
            })()
            """)
        try await until("window.sawInlineRefresh && !working && !el('refreshPacks').disabled && model.status==='Available icon packs refreshed.'")
        try check(acquired() == 1 &&
                  selections == [host.prefs.selected, host.prefs.fileSelected] && host.window.frame == refreshFrame,
                  "inline refresh fetches metadata and preserves pack choices and window position")
        let personalFiles = try await js("""
            !el('filePreview').hidden && el('filePreview').children.length === 1 &&
                el('fileDetail').textContent === '1 file type / Personal pack' &&
                el('applyFiles').textContent === 'Apply file icons…' && el('applyFiles').classList.contains('primary') &&
                !el('restoreFiles').hidden && !el('removeFiles').disabled
            """)
        try check(personalFiles as? Bool == true, "a personal file type pack previews its artwork beside the app pack")
        _ = try await js("el('filePacks').click();true")
        try await until("!el('packOptions').hidden")
        let fileChoices = try await js("""
            (() => {
              const rows = [...el('packOptions').children], ids = rows.map(r => r.dataset.id);
              return rows[0].dataset.id === 'ArtCraft/Default' && rows[0].firstChild.textContent === 'Original file icons' &&
                ids.includes('Craft-Icons-Komplett/Standard') && !ids.includes('Craft-Icons-Zach/Cardboard') &&
                !ids.includes('\(flat)') && el('packOptions').getAttribute('aria-label') === 'File type icon packs';
            })()
            """)
        try check(fileChoices as? Bool == true, "the file type list offers the original file icons and file type packs, without app icon packs")
        _ = try await js("el('packOptions').firstElementChild.click();true")
        try await until("model.filePack.default && !working")
        let originalFiles = try await js("""
            el('filePacks').textContent.startsWith('Original file icons') && el('filePreview').hidden &&
                el('fileDetail').textContent === 'Original file icons from your installed apps.' &&
                el('applyFiles').textContent === 'Restore original file icons…' && !el('applyFiles').classList.contains('primary') &&
                !el('applyFiles').disabled && el('restoreFiles').hidden && el('removeFiles').disabled
            """)
        try check(originalFiles as? Bool == true, "with the original file icons chosen, the one file action is to restore them")
        _ = try await js("el('filePacks').click();true")
        try await until("!el('packOptions').hidden")
        func hoverStrip(_ pack: String) async throws -> String {
            _ = try await js("""
              (()=>{clearPackHover();const row=[...el('packOptions').children].find(r=>r.dataset.id==='\(pack)');
              row.scrollIntoView({block:'nearest'});const r=row.getBoundingClientRect();
              row.dispatchEvent(new MouseEvent('pointerover',{bubbles:true,clientX:r.left+12,clientY:r.top+r.height/2}));return true})()
              """)
            try await until("!el('hoverPreview').hidden && el('hoverPreview').naturalWidth===204")
            return try await js("el('hoverPreview').src") as? String ?? ""
        }
        let both = "Craft-Icons-Mike22/CraftApps AIO November - Dark"
        let fileStrip = try await hoverStrip(both)
        _ = try await js("clearPackHover();true")
        let mouse = """
          (()=>{const row=[...el('packOptions').children].find(r=>r.dataset.id==='Craft-Icons-Komplett/Standard');
          row.scrollIntoView({block:'nearest'});const r=row.getBoundingClientRect();
          row.dispatchEvent(new MouseEvent('pointerover',{bubbles:true,clientX:r.left+12,clientY:r.top+r.height/2}));return true})()
          """
        _ = try await js(mouse)
        try await until("!el('hoverPreview').hidden && el('hoverPreview').naturalWidth===204")
        try check(acquired() == 1, "WebP hover renders without downloading full artwork")
        _ = try await js("hoverRow.click();true")
        try await until("model.filePack.id==='Craft-Icons-Komplett/Standard' && !working")
        let independent = try await js("model.pack.id!==model.filePack.id") as? Bool
        try check(independent == true, "file pack and app pack are independent")
        try await until("[...el('filePreview').querySelectorAll('img')].every(i=>i.complete&&i.naturalWidth>0)")
        let fileTypePack = try await js("""
            (() => {
              const tiles = [...el('filePreview').children], a = el('preview').getBoundingClientRect(), b = el('filePreview').getBoundingClientRect();
              return tiles.length === 14 && tiles.some(t => t.textContent === 'PhotoCraft' && t.title.includes('.psd, .psb')) &&
                model.fileCount === 27 && el('fileDetail').textContent === '27 file types / Built-in pack' &&
                b.left >= a.right && Math.abs(a.top - b.top) < 1 && Math.abs(a.width - b.width) <= 1 &&
                el('applyFiles').classList.contains('primary') && !el('restoreFiles').hidden && !el('removeFiles').disabled;
            })()
            """)
        try check(fileTypePack as? Bool == true, "Komplett's document artwork previews as file type icons for the apps it draws")
        _ = try await js("el('packs').click();true")
        try await until("!el('packOptions').hidden")
        let appChoices = try await js("""
            (() => {
              const ids = [...el('packOptions').children].map(r => r.dataset.id);
              return ids[0] === 'ArtCraft/Default' && el('packOptions').firstElementChild.firstChild.textContent === 'ArtCraft default' &&
                ids.includes('Craft-Icons-Zach/Cardboard') && !ids.some(id => id.startsWith('Craft-Icons-Komplett/'));
            })()
            """)
        try check(appChoices as? Bool == true, "the app icon list leaves out packs that only draw file types")
        let appStrip = try await hoverStrip(both)
        let strips = try PublishedPacks(resources: install.resources, state: install.state)
        guard let bothPack = try strips.list().first(where: { $0.id == both }),
              let fileArt = try strips.preview(bothPack, files: true), let appArt = try strips.preview(bothPack)
        else { throw Problem("the Mike22 preview strips are missing") }
        func addresses(_ file: URL) -> Set<String> {
            Set([file, file.resolvingSymlinksInPath(), file.standardizedFileURL].map {
                "bettericon-art://image/" + digest(Data(("file:" + $0.path).utf8))
            })
        }
        try check(fileStrip != appStrip && addresses(fileArt).contains(fileStrip) && addresses(appArt).contains(appStrip) &&
                  fileArt.lastPathComponent.hasSuffix("-FileTypes.webp"),
                  "a pack with app icons and file artwork previews each in its own list")
        _ = try await js("[...el('packOptions').children].find(r=>r.dataset.id==='Craft-Icons-Zach/Cardboard').click();true")
        try await until("model.pack.id==='Craft-Icons-Zach/Cardboard' && !working")
        try await until("model.pack.status==='Downloaded'")
        // Choosing a pack previews it in Manage Icons. The Launcher keeps the last applied pack until Apply.
        let browsing = "model.apps.every(a => !model.preview.some(p => p.image === a.image))"
        // PhotoCraft carries the icon the user gave it in core(). BetterIcon gave way there, so its tile shows that icon.
        let adopted = """
            model.apps.every(a => a.name === 'PhotoCraft' ? !model.preview.some(p => p.image === a.image)
                : a.image === model.preview.find(p => p.craft === a.craft).image)
            """
        let untouched = try await js("model.preview.length === 20 && " + browsing)
        try check(untouched as? Bool == true, "the Launcher does not show a pack that was only selected")
        let leading = try await js("model.preview.slice(0, 3).map(p => p.craft).join()") as? String
        try check(leading == "ArtCraftLauncher,AniCraft,CADCraft", "ArtCraft Launcher leads a pack's icons when the pack draws it")
        let grouped = try await js("""
            (() => {
              const ids = model.packs.map(p => p.id), at = id => ids.indexOf(id);
              const together = prefix => { const places = ids.map((id, i) => id.startsWith(prefix) ? i : -1).filter(i => i >= 0);
                return places.length > 0 && places[places.length - 1] - places[0] === places.length - 1; };
              return ids[0] === 'ArtCraft/Default' && together('Craft-Icons-Zach/') && together('Craft-Icons-Mike22/') &&
                at('Craft-Icons-Mains/Stained Glass') < at('Craft-Icons-Mike22/CraftApps AIO November - Dark') &&
                at('Craft-Icons-Mike22/CraftApps AIO November - Dark') < at('Craft-Icons-Zach/Cardboard') &&
                at('Craft-Icons-Zach/Cardboard') < at('Craft-Icons-Zach/Ink');
            })()
            """)
        try check(grouped as? Bool == true, "packs are listed by author, then by name")
        let iconStore = AppIcons(install.state.appendingPathComponent("App Icons"))
        let listed = try PublishedPacks(resources: install.resources, state: install.state).list()
        guard let cardboard = listed.first(where: { $0.id == "Craft-Icons-Zach/Cardboard" && !$0.icons.isEmpty }) else {
            throw Problem("Cardboard artwork is missing after selection")
        }
        func refreshApps() {
            host.statusMenu { menu, _ in
                let i = menu.indexOfItem(withTitle: "Refresh installed apps")
                if i >= 0 { menu.performActionForItem(at: i) }
            }
        }
        for restore in [false, true] {
            // The command line applies with the same store and record as the Apply button.
            let found = install.catalog.discover()
            let plan = iconStore.review(apps: found, pack: cardboard, scope: .shared, restore: restore)
            let result = try iconStore.perform(plan, apps: found, pack: cardboard)
            try check(result.changed.count == 1 && result.errors.isEmpty, "the shared fixture app changes: " + result.errors.joined())
            _ = try updatePreferences(install.state) {
                if restore { $0.defaultPaths.formUnion(result.defaults) } else { $0.defaultPaths.subtract(result.changed) }
                $0.noteApplied(plan, result, pack: cardboard)
            }
            refreshApps()
            try await until("!working && " + (restore ? browsing : adopted))
            try check(true, restore
                ? "restoring every default returns the Launcher to the original icons"
                : "the Launcher adopts a pack once it was applied, for every app the pack draws")
        }
        let stored = try saved(Preferences.self, at: install.state.appendingPathComponent("preferences.json"), fallback: Preferences())
        try check(stored.appliedPack == Pack.defaults.id && stored.appliedArt == nil, "the applied pack is remembered across restarts")
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
        let feedback = try await js("""
            (() => {
              const tile = el('apps').firstElementChild;
              tile.dispatchEvent(new PointerEvent('pointermove', {bubbles:true}));
              const hover = getComputedStyle(tile.firstChild).filter;
              const clear = getComputedStyle(tile).backgroundColor === 'rgba(0, 0, 0, 0)' &&
                getComputedStyle(tile).outlineStyle === 'none' && selected.apps === '';
              document.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true}));
              const chosen = el('apps').querySelector('[aria-selected=true]');
              return clear && hover !== 'none' && !el('apps').classList.contains('pointer') &&
                getComputedStyle(chosen.firstChild).filter === hover && getComputedStyle(chosen).outlineStyle === 'none';
            })()
            """)
        try check(feedback as? Bool == true, "hover and keyboard selection lighten the same artwork on a clear tile")
        let pressed = try await js("""
            (() => {
              const tile = el('apps').firstElementChild, art = tile.firstChild, look = () => getComputedStyle(art);
              tile.dispatchEvent(new PointerEvent('pointermove', {bubbles:true}));
              const hover = look().filter;
              tile.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true, button:0}));
              const down = look().transform === 'matrix(0.92, 0, 0, 0.92, 0, 0)' && look().filter === 'brightness(0.82)';
              window.dispatchEvent(new PointerEvent('pointerup'));
              const up = look().transform === 'none' && look().filter === hover && hover !== 'none';
              tile.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true, button:2}));
              const other = look().transform === 'none';
              tile.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true, button:0}));
              el('apps').lastElementChild.dispatchEvent(new PointerEvent('pointermove', {bubbles:true}));
              const moved = look().transform === 'none';
              el('apps').dispatchEvent(new PointerEvent('pointerleave'));
              return down && up && other && moved;
            })()
            """)
        try check(pressed as? Bool == true, "a held mouse button draws the Launcher artwork slightly smaller and darker until it is released")
        host.show()
        _ = try await js("el('apps').firstElementChild.click();true")
        for _ in 0..<100 where host.window.isVisible { try await Task.sleep(nanoseconds: 50_000_000) }
        try check(!host.window.isVisible, "one click opens the fixture application through Launch Services")
        host.show()
        try await until("page==='launcher' && !working")
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
        let allVariants = try await js("""
            el('menu').children.length===21 && !el('menu').hidden &&
                [...el('menu').children].slice(-4).map(b => b.textContent).join('|') ===
                    'Grayscale Dark|Grayscale Light|High contrast Dark|High contrast Light' &&
                [...el('menu').querySelectorAll('img')].length === 21
            """)
        try check(allVariants as? Bool == true, "all 20 icon variants plus match, including Grayscale and High contrast")
        // The app takes its colors from the chosen app icon, and each scheme stays readable.
        let scheme = """
            (() => {
              const css = getComputedStyle(document.documentElement), value = name => css.getPropertyValue('--' + name).trim();
              const rgb = color => color.match(/\\d+/g).slice(0, 3).map(Number);
              const light = hex => [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255)
                .map(v => v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4)
                .reduce((sum, v, i) => sum + v * [0.2126, 0.7152, 0.0722][i], 0);
              const ratio = (a, b) => (Math.max(light(a), light(b)) + 0.05) / (Math.min(light(a), light(b)) + 0.05);
              const hex = color => '#' + rgb(color).map(v => v.toString(16).padStart(2, '0')).join('');
              return {
                surface: value('surface'), body: hex(getComputedStyle(document.body).backgroundColor),
                primary: hex(getComputedStyle(el('apply')).backgroundColor), accent: value('accent'),
                text: ratio(value('ink'), value('surface')), muted: ratio(value('muted'), value('surface')),
                action: ratio(value('accent-ink'), value('accent')), tab: ratio(value('muted'), value('inactive')),
                dark: document.documentElement.dataset.dark,
              };
            })()
            """
        func schemeMatches(_ surface: String, dark: Bool) async throws -> Bool {
            guard let seen = try await js(scheme) as? [String: Any], let text = seen["text"] as? Double,
                  let muted = seen["muted"] as? Double, let action = seen["action"] as? Double, let tab = seen["tab"] as? Double
            else { return false }
            let native = host.window.contentView?.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
            let nativeHex = native.map { String(format: "#%02x%02x%02x", Int(round($0.redComponent * 255)), Int(round($0.greenComponent * 255)), Int(round($0.blueComponent * 255))) }
            return seen["surface"] as? String == surface && seen["body"] as? String == surface && nativeHex == surface
                && seen["primary"] as? String == seen["accent"] as? String && seen["dark"] as? String == String(dark)
                && text >= 7 && muted >= 4.5 && action >= 4.5 && tab >= 4.5
        }
        _ = try await js("[...el('menu').children].find(b => b.textContent === 'High contrast Light').click();true")
        try await until("model.prefs.color==='contrast'&&model.prefs.variant==='light'&&model.prefs.theme==='Light'&&model.dark===false")
        let strong = try await schemeMatches("#ffffff", dark: false)
        try check(strong, "High contrast Light draws the app in black on white")
        _ = try await js("el('brand').click();true")
        _ = try await js("el('menu').children[1].click();true")
        try await until("model.prefs.color==='clay'&&model.prefs.variant==='dark'&&model.prefs.theme==='Dark'&&model.dark===true")
        let clay = try await schemeMatches("#4b3832", dark: true)
        try check(clay, "choosing Clay Dark gives the app that icon's dark color scheme with readable text")
        // The loading bars, which the system would draw in its own colors, take the scheme's too, as on Windows: the
        // button gray with an accent chunk a quarter of the bar wide that moves across. With Reduce Motion on, the whole
        // bar takes the accent and fades instead. The chunk is the bar's own background picture, which shows only while
        // the page keeps WebKit's own inner bar transparent; a page loaded from a file can't read its style sheet back,
        // so that rule is looked for in the file. The scroll bars take the scheme's colors where this WebKit can color
        // them.
        let chrome = try await js("""
            (() => {
              const css = getComputedStyle(document.documentElement), value = name => css.getPropertyValue('--' + name).trim();
              const hex = color => '#' + color.match(/\\d+/g).slice(0, 3).map(v => Number(v).toString(16).padStart(2, '0')).join('');
              const stops = image => (image.match(/rgba?\\([^)]*\\)/g) || []).map(hex).join(' ');
              const bars = [el('busy').querySelector('progress'), el('offerBar')].map(bar => getComputedStyle(bar));
              return {
                face: value('control-face'), thumb: value('scroll-thumb'), track: value('scroll-track'), accent: value('accent'),
                bars: bars.map(look => hex(look.backgroundColor) + ' ' + look.animationName).join('|'),
                drawn: bars.map(look => stops(look.backgroundImage) + ' ' + look.backgroundSize + ' ' + look.backgroundRepeat).join('|'),
                still: String(matchMedia('(prefers-reduced-motion: reduce)').matches),
                scroll: CSS.supports('scrollbar-color', 'red blue')
                  ? (css.scrollbarColor.match(/rgba?\\([^)]*\\)/g) || []).map(hex).join(' ') : 'not colored',
              };
            })()
            """) as? [String: String]
        let accent = chrome?["accent"] ?? ""
        let (move, chunk) = chrome?["still"] == "true" ? ("loading-still", "100% 100%") : ("loading", "25% 100%")
        let drawn = "\(accent) \(accent) \(chunk) no-repeat"
        let sheet = try String(contentsOf: install.resources.appendingPathComponent("Web/popup.css"), encoding: .utf8)
        let inner = sheet.range(of: #"progress::-webkit-progress-bar \{\s*background: transparent;\s*\}"#, options: .regularExpression) != nil
        try check(
            chrome?["face"] == "#7f726d" && chrome?["thumb"] == "#7f726d" && chrome?["track"] == "#42312c"
                && chrome?["bars"] == "#7f726d \(move)|#7f726d \(move)" && accent.count == 7 && accent != "#7f726d"
                && chrome?["drawn"] == "\(drawn)|\(drawn)" && inner
                && ["#7f726d #42312c", "not colored"].contains(chrome?["scroll"] ?? ""),
            "the loading bars take Clay Dark's colors too, the button gray with an accent chunk that moves, or fades with Reduce Motion on, and the scroll bars take them where this WebKit can color them")
        _ = try await js("el('new').click();true")
        try await until("el('editor').open&&el('assignments').children.length===57")
        let fileRows = try await js("""
            [...el('assignments').children].some(r => r.firstChild.textContent === '.psd, .psb (PhotoCraft)') &&
                [...el('assignments').children].filter(r => r.firstChild.textContent.includes('(')).length === 37
            """)
        try check(fileRows as? Bool == true, "the pack editor lists 20 apps and 37 file type designs with their apps")
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
        // The real app puts icons back after updates by itself, on a fixture of its own.
        try await reapplyUI(resources: install.resources, root: out.appendingPathComponent("reapply-ui"))
    }
    /// BetterIcon puts its icons back after app updates. Each scenario has its own apps, state and releases, and
    /// uses its own artwork, so no network is needed.
    static func reapply(resources: URL, root: URL) throws {
        let icon = resources.appendingPathComponent("BetterIcon.icns")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let teal = try paint(root.appendingPathComponent("teal.png"), NSColor(srgbRed: 0.1, green: 0.6, blue: 0.6, alpha: 1))
        let orange = try paint(root.appendingPathComponent("orange.png"), NSColor(srgbRed: 0.95, green: 0.45, blue: 0.1, alpha: 1))
        let tealHash = digest(try Data(contentsOf: teal))
        let tealPack = Pack(id: "Checks/Teal", name: "Teal", author: "Checks", icons: ["FilmCraft": teal, "PhotoCraft": teal])
        let orangePack = Pack(
            id: "Checks/Orange", name: "Orange", author: "Checks", icons: ["FilmCraft": orange, "PhotoCraft": orange])
        let tealArt = ["FilmCraft": teal.path, "PhotoCraft": teal.path]
        // A release can bring an icon of its own.
        let orangeIcon = try icns(orange)
        let externalFile = resources.appendingPathComponent("Brand/betterIcon_icon_clay_dark.png")
        guard let external = NSImage(contentsOf: externalFile) else { throw Problem("Missing brand artwork") }
        func scenario(_ name: String, _ body: () throws -> Void) throws {
            guard soft else { return try body() }
            do { try body() } catch {
                print("FAIL: the \(name) scenario stopped: " + error.localizedDescription)
                softFailures += 1
            }
        }
        try scenario("update") {
            let s = try scene(root, "1-update")
            let film = try fixtureApp(s.all, "FilmCraft", id: "local.bettericon.keep.film1", icon: icon)
            // Version 2 brings an icon of its own, so a backup of the new copy differs from the old one.
            let version2 = try release(s.root, "FilmCraft", id: "local.bettericon.keep.film1", icon: orangeIcon, version: "2")
            let original = try systemImage(version2)
            try s.apply(tealPack)
            let path = try s.path("FilmCraft")
            let applied = record(s.state, path)
            let copy = s.state.appendingPathComponent("artwork/\(tealHash).png")
            try check(
                applied?["path"] as? String == path && applied?["bundleID"] as? String == "local.bettericon.keep.film1"
                    && applied?["version"] as? String == "1" && applied?["art"] as? String == tealHash
                    && (try? Data(contentsOf: copy)) == (try? Data(contentsOf: teal)),
                "an Apply records the app's path, bundle ID and version, and keeps its own copy of the artwork")
            let apps = s.apps()
            try launcherUpdate(film, with: version2)
            guard clean(film) else { throw Problem("the simulated update kept the custom icon") }
            let applyRow = s.store.review(apps: apps, pack: tealPack, scope: nil, restore: false).rows.first
            try check(
                applyRow?.change == true && applyRow?.message.hasPrefix("Change application icon") == true,
                "after a Launcher update the Apply review offers to put the icon back instead of refusing")
            let restoreRow = s.store.review(apps: apps, pack: .defaults, scope: nil, restore: true).rows.first
            try check(
                restoreRow?.alreadyDefault == true && restoreRow?.message.hasPrefix("Already at its original icon") == true,
                "after a Launcher update the Restore review finds the app at its new original")
            let kept = try s.store.reconcile(apps, appliedPack: tealPack.id, defaultPaths: [], appliedArt: nil)
            try check(
                kept.restored.map(\.url.path) == [path] && kept.errors.isEmpty && !clean(film)
                    && eventually { try distance(systemImage(film), original) > 0.05 },
                "after a Launcher update BetterIcon puts the app's own artwork back on the new copy")
            let rebased = record(s.state, path)
            let saved = ["original": "plist", "preview": "png"].allSatisfy { key, kind in
                (rebased?[key] as? String).map { fm.fileExists(atPath: s.state.appendingPathComponent("originals/\($0).\(kind)").path) } == true
            }
            // The preview of the new original shows the new copy's own icon, not the one the old copy had.
            let preview = (rebased?["preview"] as? String).flatMap { try? look(s.state.appendingPathComponent("originals/\($0).png")) }
            let newer = preview.map { distance($0, original) < distance($0, (try? look(teal)) ?? []) } == true
            try check(
                rebased?["identity"] as? String == identity(of: apps[0])
                    && rebased?["identity"] as? String != applied?["identity"] as? String
                    && rebased?["version"] as? String == "2" && rebased?["art"] as? String == tealHash && saved
                    && rebased?["preview"] as? String != applied?["preview"] as? String && newer,
                "the record follows the new copy and its version, with a backup of the new copy as its original")
            try s.apply(.defaults, restore: true)
            try check(
                eventually { try distance(systemImage(film), original) < 0.02 }
                    && run("/usr/bin/codesign", ["--verify", "--strict", film.path]) == 0 && record(s.state, path) == nil,
                "Restore after a re-apply gives the original pixels and passes the strict signature check")
        }
        try scenario("manual review") {
            let s = try scene(root, "2-manual")
            let film = try fixtureApp(s.all, "FilmCraft", id: "local.bettericon.keep.film2", icon: icon)
            let photo = try fixtureApp(s.user, "PhotoCraft", id: "local.bettericon.keep.photo2", icon: icon)
            let originalPhoto = try systemImage(photo)
            try s.apply(tealPack)
            let filmPath = try s.path("FilmCraft"), photoPath = try s.path("PhotoCraft")
            try launcherUpdate(film, with: release(s.root, "FilmCraft", id: "local.bettericon.keep.film2", icon: icon, version: "2"))
            try launcherUpdate(photo, with: release(s.root, "PhotoCraft", id: "local.bettericon.keep.photo2", icon: icon, version: "2"))
            let restored = try s.apply(.defaults, restore: true, only: "FilmCraft")
            try check(
                restored.defaults == [filmPath] && restored.changed.isEmpty && record(s.state, filmPath) == nil && clean(film),
                "Restore of an updated app forgets the old record and leaves the new copy as it is")
            let applied = try s.apply(tealPack, only: "PhotoCraft")
            try check(
                applied.changed == [photoPath] && !clean(photo)
                    && eventually { try distance(systemImage(photo), originalPhoto) > 0.05 }
                    && record(s.state, photoPath)?["version"] as? String == "2",
                "Apply on an updated app puts the icon on the new copy")
        }
        try scenario("reinstall") {
            let s = try scene(root, "3-reinstall")
            let film = try fixtureApp(s.all, "FilmCraft", id: "local.bettericon.keep.film3", icon: icon)
            let photo = try fixtureApp(s.user, "PhotoCraft", id: "local.bettericon.keep.photo3", icon: icon)
            let original = try systemImage(film)
            try s.apply(tealPack)
            let apps = s.apps()
            let filmPath = try s.path("FilmCraft"), photoPath = try s.path("PhotoCraft")
            let before = record(s.state, filmPath)?["identity"] as? String
            try launcherUpdate(film, with: release(s.root, "FilmCraft", id: "local.bettericon.keep.film3", icon: icon, version: "1"))
            try launcherUpdate(photo, with: release(s.root, "PhotoCraft", id: "local.bettericon.keep.photo3", icon: icon, version: "2"))
            guard setFinderIcon(external, photo.path) else {
                throw Problem("could not give the new copy another icon")
            }
            let other = try forkBytes(photo)
            let kept = try s.store.reconcile(apps, appliedPack: tealPack.id, defaultPaths: [], appliedArt: tealArt)
            let after = record(s.state, filmPath)?["identity"] as? String
            let now = apps.first(where: { $0.url.path == filmPath }).map(identity(of:))
            try check(
                kept.restored.map(\.url.path) == [filmPath] && kept.errors.isEmpty && after != before && after == now
                    && eventually { try distance(systemImage(film), original) > 0.05 }
                    && (try? forkBytes(photo)) == other && record(s.state, photoPath) != nil,
                "a reinstall of the same version gets its icon back, and a new copy that carries another custom icon is left alone")
        }
        try scenario("removed in Finder") {
            let s = try scene(root, "4-removed")
            let film = try fixtureApp(s.all, "FilmCraft", id: "local.bettericon.keep.film4", icon: icon)
            try s.apply(tealPack)
            let apps = s.apps()
            let path = try s.path("FilmCraft")
            guard setFinderIcon(nil, film.path), clean(film) else {
                throw Problem("could not remove the custom icon")
            }
            let restoreRow = s.store.review(apps: apps, pack: .defaults, scope: nil, restore: true).rows.first
            let applyRow = s.store.review(apps: apps, pack: tealPack, scope: nil, restore: false).rows.first
            try check(
                restoreRow?.alreadyDefault == true && restoreRow?.change == false && applyRow?.change == true,
                "after an icon is removed outside BetterIcon, Restore finds the app at its original and Apply offers a new icon")
            let kept = try s.store.reconcile(apps, appliedPack: tealPack.id, defaultPaths: [], appliedArt: tealArt)
            try check(
                kept.optedOut == [path] && kept.restored.isEmpty && kept.errors.isEmpty && record(s.state, path) == nil && clean(film),
                "an icon removed outside BetterIcon counts as a restore of that app")
            try launcherUpdate(film, with: release(s.root, "FilmCraft", id: "local.bettericon.keep.film4", icon: icon, version: "2"))
            let later = try s.store.reconcile(apps, appliedPack: tealPack.id, defaultPaths: [path], appliedArt: tealArt)
            try check(
                later.restored.isEmpty && later.errors.isEmpty && clean(film) && record(s.state, path) == nil,
                "an app whose icon was removed outside BetterIcon keeps its original icon after a later update")
        }
        try scenario("mid-update") {
            let s = try scene(root, "5-midway")
            let film = try fixtureApp(s.all, "FilmCraft", id: "local.bettericon.keep.film5", icon: icon)
            try s.apply(tealPack)
            // The apps as found before the update, as the running app knows them.
            let apps = s.apps()
            let path = try s.path("FilmCraft")
            var calm = true
            try launcherUpdate(film, with: release(s.root, "FilmCraft", id: "local.bettericon.keep.film5", icon: icon, version: "2")) {
                stage in
                let midway = try s.store.reconcile(apps, appliedPack: tealPack.id, defaultPaths: [], appliedArt: nil)
                let quiet = midway.errors.isEmpty && midway.restored.isEmpty && midway.optedOut.isEmpty
                calm = calm && quiet && (stage == "staged" ? !clean(film) : midway.waiting == [path])
            }
            try check(calm, "while an update is staged, moved aside or swapped in, BetterIcon waits without errors")
            let done = try s.store.reconcile(apps, appliedPack: tealPack.id, defaultPaths: [], appliedArt: nil)
            try check(
                done.restored.map(\.url.path) == [path] && done.waiting.isEmpty && !clean(film),
                "once the update is in place the app gets its icon back")
        }
        try scenario("both locations") {
            let s = try scene(root, "6-locations")
            let shared = try fixtureApp(s.all, "FilmCraft", id: "local.bettericon.keep.film6", icon: icon)
            let personal = try fixtureApp(s.user, "FilmCraft", id: "local.bettericon.keep.film6", icon: icon)
            try s.apply(tealPack, scope: .shared)
            try s.apply(orangePack, scope: .personal)
            let tealLook = try systemImage(shared), orangeLook = try systemImage(personal)
            guard distance(tealLook, orangeLook) > 0.05 else { throw Problem("the two fixture packs look alike") }
            let apps = s.apps()
            let version2 = try release(s.root, "FilmCraft", id: "local.bettericon.keep.film6", icon: icon, version: "2")
            try launcherUpdate(shared, with: version2)
            try launcherUpdate(personal, with: version2)
            // Orange was applied last. The copy in Shared still gets back the teal it carried.
            let kept = try s.store.reconcile(
                apps, appliedPack: orangePack.id, defaultPaths: [], appliedArt: ["FilmCraft": orange.path])
            try check(
                kept.restored.count == 2
                    && eventually {
                        try distance(systemImage(shared), tealLook) < 0.02 && distance(systemImage(personal), orangeLook) < 0.02
                    },
                "copies in both locations each get back the artwork that was applied to them")
        }
        try scenario("restore wins") {
            let s = try scene(root, "7-restore")
            let film = try fixtureApp(s.all, "FilmCraft", id: "local.bettericon.keep.film7", icon: icon)
            let photo = try fixtureApp(s.user, "PhotoCraft", id: "local.bettericon.keep.photo7", icon: icon)
            try s.apply(tealPack)
            let apps = s.apps()
            let filmPath = try s.path("FilmCraft"), photoPath = try s.path("PhotoCraft")
            let restored = try s.apply(.defaults, restore: true, only: "FilmCraft")
            try launcherUpdate(film, with: release(s.root, "FilmCraft", id: "local.bettericon.keep.film7", icon: icon, version: "2"))
            try launcherUpdate(photo, with: release(s.root, "PhotoCraft", id: "local.bettericon.keep.photo7", icon: icon, version: "2"))
            let kept = try s.store.reconcile(
                apps, appliedPack: tealPack.id, defaultPaths: Set(restored.defaults), appliedArt: tealArt)
            try check(
                restored.defaults == [filmPath] && clean(film) && record(s.state, filmPath) == nil
                    && kept.restored.map(\.url.path) == [photoPath] && !clean(photo),
                "after a per-app restore an update leaves that app alone while another app gets its icon back")
            try s.apply(.defaults, restore: true)
            try launcherUpdate(photo, with: release(s.root, "PhotoCraft", id: "local.bettericon.keep.photo7", icon: icon, version: "3"))
            let none = try s.store.reconcile(apps, appliedPack: Pack.defaults.id, defaultPaths: [], appliedArt: nil)
            let afterRestore = none.restored.isEmpty && clean(photo) && record(s.state, photoPath) == nil
            try s.apply(tealPack)
            try launcherUpdate(film, with: release(s.root, "FilmCraft", id: "local.bettericon.keep.film7", icon: icon, version: "3"))
            // A record left behind never brings an icon back while the original icons are the applied pack.
            let held = try s.store.reconcile(apps, appliedPack: Pack.defaults.id, defaultPaths: [], appliedArt: tealArt)
            let waited = held.restored.isEmpty && clean(film) && record(s.state, filmPath) != nil
            let resumed = try s.store.reconcile(apps, appliedPack: tealPack.id, defaultPaths: [], appliedArt: tealArt)
            try check(
                afterRestore && waited && resumed.restored.map(\.url.path) == [filmPath] && !clean(film),
                "after a full restore nothing is re-applied until a pack is applied again")
        }
        try scenario("operations lock") {
            let s = try scene(root, "8-lock")
            let film = try fixtureApp(s.all, "FilmCraft", id: "local.bettericon.keep.film8", icon: icon)
            try s.apply(tealPack)
            let apps = s.apps()
            let path = try s.path("FilmCraft")
            let identity = record(s.state, path)?["identity"] as? String
            try launcherUpdate(film, with: release(s.root, "FilmCraft", id: "local.bettericon.keep.film8", icon: icon, version: "2"))
            let lock = open(s.state.appendingPathComponent("operations.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lock >= 0, flock(lock, LOCK_EX) == 0 else { throw Problem("could not hold the operations lock") }
            var busy = false
            do { _ = try s.store.reconcile(apps, appliedPack: tealPack.id, defaultPaths: [], appliedArt: nil) } catch is LockBusy {
                busy = true
            }
            let untouched = clean(film) && record(s.state, path)?["identity"] as? String == identity
            flock(lock, LOCK_UN)
            close(lock)
            try check(busy && untouched, "while another operation holds the lock, a reconcile changes nothing and asks to try again")
            let later = try s.store.reconcile(apps, appliedPack: tealPack.id, defaultPaths: [], appliedArt: nil)
            try check(later.restored.map(\.url.path) == [path] && !clean(film), "once the lock is free the update is put back")
        }
        try scenario("older records") {
            let s = try scene(root, "9-older")
            let film = try fixtureApp(s.all, "FilmCraft", id: "local.bettericon.keep.film9", icon: icon)
            _ = try fixtureApp(s.user, "PhotoCraft", id: "local.bettericon.keep.photo9", icon: icon)
            try s.apply(tealPack)
            let apps = s.apps()
            let filmPath = try s.path("FilmCraft"), photoPath = try s.path("PhotoCraft")
            for app in apps { try strip(s.state, app.url.path) }
            try? fm.removeItem(at: s.state.appendingPathComponent("artwork"))
            let readable = s.store.review(apps: apps, pack: tealPack, scope: nil, restore: false).rows.allSatisfy(\.change)
            // FilmCraft is updated before BetterIcon looks again. PhotoCraft keeps its icon.
            try launcherUpdate(film, with: release(s.root, "FilmCraft", id: "local.bettericon.keep.film9", icon: icon, version: "2"))
            let kept = try s.store.reconcile(apps, appliedPack: tealPack.id, defaultPaths: [], appliedArt: tealArt)
            let filled = record(s.state, photoPath)
            try check(
                readable && kept.errors.isEmpty && filled?["path"] as? String == photoPath
                    && filled?["bundleID"] as? String == "local.bettericon.keep.photo9" && filled?["version"] as? String == "1"
                    && filled?["art"] as? String == tealHash
                    && fm.fileExists(atPath: s.state.appendingPathComponent("artwork/\(tealHash).png").path),
                "a record from before this version still reads, and the first look fills in its path, bundle ID, version and artwork")
            try check(
                kept.restored.map(\.url.path) == [filmPath] && !clean(film) && record(s.state, filmPath)?["art"] as? String == tealHash,
                "an app with a record from before this version gets its icon back after an update")
        }
        try scenario("refused") {
            let s = try scene(root, "11-refused")
            let film = try fixtureApp(s.all, "FilmCraft", id: "local.bettericon.keep.film11", icon: icon)
            try s.apply(tealPack)
            let apps = s.apps()
            let path = try s.path("FilmCraft")
            try launcherUpdate(film, with: release(s.root, "FilmCraft", id: "local.bettericon.keep.film11", icon: icon, version: "2"))
            // macOS refuses the change, as when BetterIcon is not allowed under App Management.
            let write = s.store.writeIcon
            s.store.writeIcon = { _, _ in false }
            let refused = try s.store.reconcile(apps, appliedPack: tealPack.id, defaultPaths: [], appliedArt: nil)
            s.store.writeIcon = write
            let again = try s.store.reconcile(
                apps, appliedPack: tealPack.id, defaultPaths: [], appliedArt: nil, refused: Set(refused.declined.values))
            try check(
                refused.declined[path] == apps.first.map(identity(of:)) && refused.restored.isEmpty && refused.errors.isEmpty
                    && again.restored.isEmpty && again.declined.isEmpty && again.errors.isEmpty && clean(film),
                "when macOS refuses to put an icon back, that copy is reported and not tried again")
            // A restart forgets the refusal.
            let restarted = try s.store.reconcile(apps, appliedPack: tealPack.id, defaultPaths: [], appliedArt: nil)
            try check(
                restarted.restored.map(\.url.path) == [path] && !clean(film),
                "after a restart a copy that macOS refused is tried again and gets its icon back")
        }
        try scenario("watcher") {
            let folder = root.appendingPathComponent("10-watch/Applications")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let film = try fixtureApp(folder, "FilmCraft", id: "local.bettericon.keep.film10", icon: icon)
            let version2 = try release(
                root.appendingPathComponent("10-watch"), "FilmCraft", id: "local.bettericon.keep.film10", icon: icon, version: "2")
            let lock = NSLock()
            var reports = [String]()
            func seen() -> [String] {
                lock.lock()
                defer { lock.unlock() }
                return reports
            }
            func waitFor(_ seconds: Double, _ condition: () -> Bool) -> Bool {
                let end = Date().addingTimeInterval(seconds)
                while !condition() {
                    if Date() > end { return false }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                return true
            }
            let watcher = AppsWatcher(changed: { paths in
                lock.lock()
                reports += paths
                lock.unlock()
            })
            defer { watcher.stop() }
            watcher.watch([(url: folder, topLevel: false)])
            Thread.sleep(forTimeInterval: 0.8)
            try launcherUpdate(film, with: version2)
            // The watcher names apps the way discovery does.
            let shown = film.standardizedFileURL.path
            let named = waitFor(15) { seen().contains(shown) }
            Thread.sleep(forTimeInterval: 1.5)
            try check(
                named && seen().allSatisfy { $0 == shown },
                "the apps folder watcher reports an app replaced by a directory rename, and no hidden install folders")
            lock.lock()
            reports.removeAll()
            lock.unlock()
            guard setFinderIcon(external, film.path) else {
                throw Problem("could not set a test icon")
            }
            let own = waitFor(3) { !seen().isEmpty }
            guard try run("/usr/bin/touch", [film.path]) == 0 else { throw Problem("could not touch the fixture app") }
            let foreign = waitFor(15) { seen().contains(shown) }
            try check(!own && foreign, "the watcher ignores BetterIcon's own icon writes and still reports other changes")
        }
        try scenario("own icon") {
            let s = try scene(root, "12-own-icon")
            let film = try fixtureApp(s.all, "FilmCraft", id: "local.bettericon.keep.film12", icon: icon)
            try s.apply(tealPack)
            let apps = s.apps()
            let path = try s.path("FilmCraft")
            // The user gives FilmCraft an icon of their own, as with a paste in Finder's Get Info.
            guard setFinderIcon(external, film.path) else {
                throw Problem("could not give the app another icon")
            }
            let own = try forkBytes(film)
            let noticed = try s.store.reconcile(apps, appliedPack: tealPack.id, defaultPaths: [], appliedArt: tealArt)
            let left = (try? forkBytes(film)) == own
            try launcherUpdate(film, with: release(s.root, "FilmCraft", id: "local.bettericon.keep.film12", icon: icon, version: "2"))
            let later = try s.store.reconcile(apps, appliedPack: tealPack.id, defaultPaths: [], appliedArt: tealArt)
            try check(
                noticed.yielded == [path] && noticed.restored.isEmpty && noticed.errors.isEmpty && left
                    && later.restored.isEmpty && later.optedOut == [path] && later.reasons[path] == .ownIcon
                    && later.errors.isEmpty && clean(film) && record(s.state, path) == nil,
                "an icon the user gives an app is left alone, and after the app's next update BetterIcon does not put the pack back")
        }
        try scenario("own icon kept through a Restore") {
            let s = try scene(root, "13-own-restore")
            let film = try fixtureApp(s.all, "FilmCraft", id: "local.bettericon.keep.film13", icon: icon)
            _ = try fixtureApp(s.user, "PhotoCraft", id: "local.bettericon.keep.photo13", icon: icon)
            var prefs = Preferences()
            func change(_ pack: Pack, scope: Scope?, restore: Bool) throws {
                let found = s.apps()
                let plan = s.store.review(apps: found, pack: pack, scope: scope, restore: restore)
                let result = try s.store.perform(plan, apps: found, pack: pack)
                if restore { prefs.defaultPaths.formUnion(result.defaults) } else { prefs.defaultPaths.subtract(result.changed) }
                prefs.noteApplied(plan, result, pack: pack)
            }
            try change(tealPack, scope: nil, restore: false)
            guard setFinderIcon(external, film.path) else {
                throw Problem("could not give the app another icon")
            }
            // Restore app defaults everywhere leaves FilmCraft's own icon in place. Then orange goes on the other
            // location only.
            try change(.defaults, scope: nil, restore: true)
            try change(orangePack, scope: .personal, restore: false)
            try launcherUpdate(film, with: release(s.root, "FilmCraft", id: "local.bettericon.keep.film13", icon: icon, version: "2"))
            let kept = try s.store.reconcile(
                s.apps(), appliedPack: prefs.appliedPack, defaultPaths: prefs.defaultPaths, appliedArt: prefs.appliedArt)
            try check(
                prefs.appliedPack == orangePack.id && kept.restored.isEmpty && kept.errors.isEmpty && clean(film),
                "an app left alone by a Restore because it carried the user's own icon does not get the old pack back after its update")
        }
        try scenario("declined restore") {
            let s = try scene(root, "14-declined")
            let film = try fixtureApp(s.all, "FilmCraft", id: "local.bettericon.keep.film14", icon: icon)
            let photo = try fixtureApp(s.user, "PhotoCraft", id: "local.bettericon.keep.photo14", icon: icon)
            let grid = try fixtureApp(s.all, "GridCraft", id: "local.bettericon.keep.grid14", icon: icon)
            let pack = Pack(
                id: tealPack.id, name: "Teal", author: "Checks", icons: ["FilmCraft": teal, "PhotoCraft": teal, "GridCraft": teal])
            try s.apply(pack)
            let apps = s.apps()
            let filmPath = try s.path("FilmCraft"), photoPath = try s.path("PhotoCraft"), gridPath = try s.path("GridCraft")
            // macOS declines Restore app defaults, as when BetterIcon is not allowed under App Management.
            var prefs = Preferences()
            prefs.appliedPack = pack.id
            prefs.appliedArt = pack.icons.mapValues(\.path)
            let write = s.store.writeIcon
            s.store.writeIcon = { _, _ in false }
            let plan = s.store.review(apps: apps, pack: .defaults, scope: nil, restore: true)
            let declined = try s.store.perform(plan, apps: apps, pack: .defaults)
            s.store.writeIcon = write
            prefs.noteApplied(plan, declined, pack: .defaults)
            // Writes work again. FilmCraft is updated, and the user removes PhotoCraft's and GridCraft's icons in Finder.
            try launcherUpdate(film, with: release(s.root, "FilmCraft", id: "local.bettericon.keep.film14", icon: icon, version: "2"))
            for app in [photo, grid] {
                guard setFinderIcon(nil, app.path), clean(app) else {
                    throw Problem("could not remove the custom icon")
                }
            }
            // A repeated Restore of GridCraft forgets the record the declined one left behind.
            let again = s.store.review(apps: apps, pack: .defaults, scope: nil, restore: true, only: "GridCraft")
            let repeated = try s.store.perform(again, apps: apps, pack: .defaults)
            prefs.defaultPaths.formUnion(repeated.defaults)
            try check(
                declined.declined.count == 3 && repeated.defaults == [gridPath] && repeated.errors.isEmpty
                    && record(s.state, gridPath) == nil,
                "a repeated Restore of an app at its original icon forgets the record a declined Restore left behind")
            let kept = try s.store.reconcile(apps, appliedPack: prefs.appliedPack, defaultPaths: prefs.defaultPaths, appliedArt: nil)
            prefs.defaultPaths.formUnion(kept.optedOut)
            try launcherUpdate(photo, with: release(s.root, "PhotoCraft", id: "local.bettericon.keep.photo14", icon: icon, version: "2"))
            let later = try s.store.reconcile(apps, appliedPack: prefs.appliedPack, defaultPaths: prefs.defaultPaths, appliedArt: nil)
            try check(
                prefs.appliedPack == pack.id && kept.restored.isEmpty && Set(kept.optedOut) == [filmPath, photoPath]
                    && kept.reasons[filmPath] == .restore && kept.reasons[photoPath] == .restore && later.restored.isEmpty
                    && clean(film) && clean(photo) && record(s.state, filmPath) == nil && record(s.state, photoPath) == nil,
                "a Restore that macOS declined still counts: after the app's update, or after its icon is removed in Finder, the pack is not put back")
        }
        try scenario("cut write") {
            let s = try scene(root, "15-cut")
            let film = try fixtureApp(s.all, "FilmCraft", id: "local.bettericon.keep.film15", icon: icon)
            let photo = try fixtureApp(s.user, "PhotoCraft", id: "local.bettericon.keep.photo15", icon: icon)
            try s.apply(tealPack, only: "FilmCraft")
            let apps = s.apps()
            let filmPath = try s.path("FilmCraft"), photoPath = try s.path("PhotoCraft")
            try launcherUpdate(film, with: release(s.root, "FilmCraft", id: "local.bettericon.keep.film15", icon: icon, version: "2"))
            // BetterIcon quits in the middle of putting the icon back: macOS has written the icon file and part of its
            // resource fork, and not yet the folder's custom-icon flag.
            let write = s.store.writeIcon
            s.store.writeIcon = { _, path in
                let file = URL(fileURLWithPath: path).appendingPathComponent("Icon\r")
                guard fm.createFile(atPath: file.path, contents: Data()) else { return false }
                try? putAttribute(resourceFork, Data(repeating: 0, count: 286), file)
                return false
            }
            _ = try s.store.reconcile(apps, appliedPack: tealPack.id, defaultPaths: [], appliedArt: tealArt)
            s.store.writeIcon = write
            let cut = fm.fileExists(atPath: film.appendingPathComponent("Icon\r").path) && (try? customFlag(film)) == false
            let applyRow = s.store.review(apps: apps, pack: tealPack, scope: nil, restore: false, only: "FilmCraft").rows.first
            let restoreRow = s.store.review(apps: apps, pack: .defaults, scope: nil, restore: true, only: "FilmCraft").rows.first
            // At the next start BetterIcon finishes it.
            let next = try s.store.reconcile(apps, appliedPack: tealPack.id, defaultPaths: [], appliedArt: tealArt)
            try check(
                cut && applyRow?.change == true && restoreRow?.change == true && next.restored.map(\.url.path) == [filmPath]
                    && (try? customFlag(film)) == true && record(s.state, filmPath)?["pending"] == nil,
                "an icon write cut short leaves an app that Apply and Restore can still change, and BetterIcon finishes it at the next look")
            // Cut after macOS wrote the whole icon, before BetterIcon recorded it: the record still names a pending change.
            s.store.writeIcon = { image, path in
                _ = write(image, path)
                return false
            }
            let plan = s.store.review(apps: apps, pack: tealPack, scope: nil, restore: false, only: "PhotoCraft")
            _ = try s.store.perform(plan, apps: apps, pack: tealPack)
            s.store.writeIcon = write
            let written = !clean(photo) && record(s.state, photoPath)?["pending"] != nil
            let settled = try s.store.reconcile(apps, appliedPack: tealPack.id, defaultPaths: [], appliedArt: tealArt)
            let recorded = record(s.state, photoPath)?["pending"] == nil
            guard setFinderIcon(nil, photo.path), clean(photo) else {
                throw Problem("could not remove the custom icon")
            }
            let removed = try s.store.reconcile(apps, appliedPack: tealPack.id, defaultPaths: [], appliedArt: tealArt)
            try check(
                written && settled.restored.isEmpty && settled.finished.isEmpty && recorded && removed.restored.isEmpty
                    && removed.finished.isEmpty && removed.optedOut == [photoPath] && clean(photo),
                "a change that reached the app before BetterIcon recorded it is settled, so removing that icon in Finder later is honoured")
        }
        try scenario("kept artwork") {
            let s = try scene(root, "16-artwork")
            let shared = try fixtureApp(s.all, "FilmCraft", id: "local.bettericon.keep.film16", icon: icon)
            let personal = try fixtureApp(s.user, "FilmCraft", id: "local.bettericon.keep.film16", icon: icon)
            // Orange went on the personal copy, then teal on the shared one, so teal was applied last.
            try s.apply(orangePack, scope: .personal)
            try s.apply(tealPack, scope: .shared)
            let tealLook = try systemImage(shared), orangeLook = try systemImage(personal)
            let apps = s.apps()
            let personalPath = try s.path("FilmCraft", .personal)
            let orangeHash = record(s.state, personalPath)?["art"] as? String ?? ""
            // The personal copy's kept artwork is lost.
            for name in (try? fm.contentsOfDirectory(atPath: s.state.appendingPathComponent("artwork").path)) ?? []
            where name.hasPrefix(orangeHash) {
                try fm.removeItem(at: s.state.appendingPathComponent("artwork/" + name))
            }
            let version2 = try release(s.root, "FilmCraft", id: "local.bettericon.keep.film16", icon: icon, version: "2")
            try launcherUpdate(personal, with: version2)
            let lost = try s.store.reconcile(
                apps, appliedPack: tealPack.id, defaultPaths: [], appliedArt: ["FilmCraft": teal.path])
            try check(
                !orangeHash.isEmpty && lost.restored.isEmpty && lost.failed[personalPath] != nil && clean(personal)
                    && record(s.state, personalPath)?["art"] as? String == orangeHash,
                "a copy whose own artwork is gone gets no other pack's artwork in its place")
            // Records from before this version name no artwork. Each copy takes the artwork it carries.
            try s.apply(orangePack, scope: .personal)
            for app in s.apps() { try strip(s.state, app.url.path) }
            try? fm.removeItem(at: s.state.appendingPathComponent("artwork"))
            _ = try s.store.reconcile(s.apps(), appliedPack: tealPack.id, defaultPaths: [], appliedArt: ["FilmCraft": teal.path])
            let personalArt = record(s.state, personalPath)?["art"] as? String
            try launcherUpdate(personal, with: version2)
            let back = try s.store.reconcile(
                s.apps(), appliedPack: tealPack.id, defaultPaths: [], appliedArt: ["FilmCraft": teal.path])
            try check(
                personalArt != nil && personalArt != tealHash && back.restored.map(\.url.path) == [personalPath]
                    && eventually { try distance(systemImage(personal), orangeLook) < 0.02 }
                    && (try distance(systemImage(shared), tealLook)) < 0.02,
                "a record from before this version takes the artwork its copy carries, so a copy that kept another pack gets that pack back")
        }
        try scenario("custom original") {
            let s = try scene(root, "17-custom-original")
            let film = try fixtureApp(s.all, "FilmCraft", id: "local.bettericon.keep.film17", icon: icon)
            // The app had an icon of the user's own before BetterIcon changed it.
            guard setFinderIcon(external, film.path) else {
                throw Problem("could not give the app its own icon")
            }
            let own = try forkBytes(film)
            try s.apply(tealPack)
            let apps = s.apps()
            let path = try s.path("FilmCraft")
            guard setFinderIcon(nil, film.path), clean(film) else {
                throw Problem("could not remove the custom icon")
            }
            let row = s.store.review(apps: apps, pack: .defaults, scope: nil, restore: true).rows.first
            let kept = try s.store.reconcile(apps, appliedPack: tealPack.id, defaultPaths: [], appliedArt: tealArt)
            try s.apply(.defaults, restore: true)
            try check(
                row?.change == true && row?.message == "Restore original icon" && kept.optedOut == [path]
                    && (try? forkBytes(film)) == own && record(s.state, path) == nil,
                "after the icon is removed in Finder, the icon an app had before BetterIcon can still be restored byte for byte")
        }
        try scenario("restore one location") {
            let s = try scene(root, "18-one-location")
            let film = try fixtureApp(s.all, "FilmCraft", id: "local.bettericon.keep.film18", icon: icon)
            let photo = try fixtureApp(s.user, "PhotoCraft", id: "local.bettericon.keep.photo18", icon: icon)
            let filmPath = try s.path("FilmCraft"), photoPath = try s.path("PhotoCraft")
            var prefs = Preferences()
            func change(_ pack: Pack, scope: Scope?, restore: Bool) throws -> IconResult {
                let found = s.apps()
                let plan = s.store.review(apps: found, pack: pack, scope: scope, restore: restore)
                let result = try s.store.perform(plan, apps: found, pack: pack)
                if restore { prefs.defaultPaths.formUnion(result.defaults) } else { prefs.defaultPaths.subtract(result.changed) }
                prefs.noteApplied(plan, result, pack: pack)
                return result
            }
            _ = try change(tealPack, scope: nil, restore: false)
            // Restore app defaults for the current user only, as the menu's Current user or --scope personal does.
            let restored = try change(.defaults, scope: .personal, restore: true)
            let stillApplied = prefs.appliedPack == tealPack.id && prefs.appliedArt?["FilmCraft"] == teal.path
            try launcherUpdate(film, with: release(s.root, "FilmCraft", id: "local.bettericon.keep.film18", icon: icon, version: "2"))
            let kept = try s.store.reconcile(
                s.apps(), appliedPack: prefs.appliedPack, defaultPaths: prefs.defaultPaths, appliedArt: prefs.appliedArt)
            // Restoring the other location too returns the Launcher to the original icons.
            _ = try change(.defaults, scope: .shared, restore: true)
            try check(
                restored.changed == [photoPath] && stillApplied && kept.restored.map(\.url.path) == [filmPath]
                    && clean(photo) && prefs.appliedPack == Pack.defaults.id && clean(film),
                "a Restore of one location keeps the pack applied for the other, whose apps still get their icons back after updates")
        }
        try scenario("apps folder inside the Desktop") {
            let desk = root.appendingPathComponent("19-desk/Desktop")
            let nested = desk.appendingPathComponent("Apps")
            try fm.createDirectory(at: nested, withIntermediateDirectories: true)
            let top = try fixtureApp(desk, "LightCraft", id: "local.bettericon.keep.light19", icon: icon)
            let inner = try fixtureApp(nested, "FilmCraft", id: "local.bettericon.keep.film19", icon: icon)
            let lock = NSLock()
            var reports = Set<String>()
            let watcher = AppsWatcher(changed: { paths in
                lock.lock()
                reports.formUnion(paths)
                lock.unlock()
            })
            defer { watcher.stop() }
            // Discovery lists the Desktop's top level before an apps folder added inside it.
            watcher.watch([(url: desk, topLevel: true), (url: nested, topLevel: false)])
            Thread.sleep(forTimeInterval: 0.8)
            try launcherUpdate(inner, with: release(root.appendingPathComponent("19-desk"), "FilmCraft", id: "local.bettericon.keep.film19", icon: icon, version: "2"))
            try launcherUpdate(top, with: release(root.appendingPathComponent("19-desk"), "LightCraft", id: "local.bettericon.keep.light19", icon: icon, version: "2"))
            let wanted: Set = [inner.standardizedFileURL.path, top.standardizedFileURL.path]
            let end = Date().addingTimeInterval(15)
            var seen = Set<String>()
            while Date() < end {
                lock.lock()
                seen = reports
                lock.unlock()
                if seen.isSuperset(of: wanted) { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            try check(seen.isSuperset(of: wanted), "an apps folder inside the Desktop is watched like any other apps folder")
        }
    }
    /// The queue that puts icons back: holding off, pausing for a review, quitting, and retrying apps in the middle of
    /// an update. It calls the app on the main thread, so these checks wait without holding it.
    @MainActor static func keeperChecks(resources: URL, root: URL) async throws {
        let icon = resources.appendingPathComponent("BetterIcon.icns")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let teal = try paint(root.appendingPathComponent("teal.png"), NSColor(srgbRed: 0.1, green: 0.6, blue: 0.6, alpha: 1))
        let s = try scene(root, "keeper")
        let film = try fixtureApp(s.all, "FilmCraft", id: "local.bettericon.keep.keeper-film", icon: icon)
        let grid = try fixtureApp(s.all, "GridCraft", id: "local.bettericon.keep.keeper-grid", icon: icon)
        let photo = try fixtureApp(s.user, "PhotoCraft", id: "local.bettericon.keep.keeper-photo", icon: icon)
        let pack = Pack(
            id: "Checks/Teal", name: "Teal", author: "Checks", icons: ["FilmCraft": teal, "GridCraft": teal, "PhotoCraft": teal])
        let art = pack.icons.mapValues(\.path)
        try s.apply(pack)
        let apps = s.apps()
        let filmPath = try s.path("FilmCraft")
        var version = 1
        func update(_ app: URL, _ name: String) throws {
            version += 1
            try launcherUpdate(
                app, with: release(s.root, name, id: "local.bettericon.keep.keeper-" + name.dropLast(5).lowercased(), icon: icon,
                    version: String(version)))
        }
        let context = IconKeeper.Context(apps: apps, appliedPack: pack.id, defaultPaths: [], appliedArt: art)
        let write = s.store.writeIcon

        // While the app holds the keeper off, as it does while an alert or panel is open, nothing is written.
        let keeper = IconKeeper(icons: s.store, catalog: s.catalog)
        var holding = true, asked = 0
        var reports = [Reconciled]()
        keeper.context = {
            asked += 1
            return holding ? nil : context
        }
        keeper.finished = { reports.append($0) }
        try update(film, "FilmCraft")
        keeper.request(nil)
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let held = asked >= 2 && clean(film) && reports.isEmpty
        holding = false
        let resumed = await waitUntil(10) { !clean(film) && reports.contains { $0.restored.map(\.url.path) == [filmPath] } }
        try check(held && resumed, "while the app holds it off, the keeper starts no pass and writes nothing, and it puts the icon back once it may")

        // A review pauses the keeper. The pause waits for a pass under way, and nothing runs until the review ends.
        try update(photo, "PhotoCraft")
        try update(grid, "GridCraft")
        s.store.writeIcon = { image, path in
            Thread.sleep(forTimeInterval: 0.6)
            return write(image, path)
        }
        keeper.request(nil)
        let started = await waitUntil(10) { !clean(photo) || !clean(grid) }
        let partway = clean(photo) || clean(grid)
        // The app pauses the keeper from the thread that computes the review.
        let pausing = Unchecked(keeper)
        let pausedAfterPass: Bool = await withCheckedContinuation { done in
            DispatchQueue.global().async {
                pausing.value.pause()
                done.resume(returning: !clean(photo) && !clean(grid))
            }
        }
        try update(film, "FilmCraft")
        keeper.request([filmPath])
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let quiet = clean(film)
        keeper.resume()
        let afterResume = await waitUntil(10) { !clean(film) }
        s.store.writeIcon = write
        try check(
            started && partway && pausedAfterPass && quiet && afterResume,
            "pausing the keeper waits for the pass under way, starts nothing while paused, and runs what was asked meanwhile on resume")

        // A quit during a pass lets the app being written finish. The other apps wait for the next start.
        let quitter = IconKeeper(icons: s.store, catalog: s.catalog)
        quitter.context = { context }
        try update(photo, "PhotoCraft")
        try update(grid, "GridCraft")
        let entered = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        let gate = NSLock()
        var first = true
        s.store.writeIcon = { image, path in
            gate.lock()
            let hold = first
            first = false
            gate.unlock()
            if hold {
                entered.signal()
                _ = proceed.wait(timeout: .now() + 20)
            }
            return write(image, path)
        }
        quitter.request(nil)
        let inWrite = await waitUntil(10) { entered.wait(timeout: .now()) == .success }
        let busy = quitter.beginQuitting()
        var idle = false
        quitter.whenIdle { idle = true }
        try await Task.sleep(nanoseconds: 500_000_000)
        let waited = !idle
        proceed.signal()
        let ended = await waitUntil(10) { idle }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let written = [photo, grid].filter { !clean($0) }.count
        s.store.writeIcon = write
        try check(
            inWrite && busy && waited && ended && written == 1,
            "a quit during a pass lets the app being written finish, and leaves the other apps for the next start")

        // Apps in the middle of an update are looked at again for as long as a hidden install folder beside them can
        // still mean an update under way.
        try check(
            IconKeeper.backoff.reduce(0, +) >= 15 * 60,
            "after its quick retries the keeper keeps looking at an app while a hidden install folder beside it can still mean an update")
        let backoff = IconKeeper.backoff
        IconKeeper.backoff = [0.3, 0.3]
        defer { IconKeeper.backoff = backoff }
        let retrier = IconKeeper(icons: s.store, catalog: s.catalog)
        var looks = 0
        retrier.context = {
            looks += 1
            return context
        }
        // An install that stopped part-way left its hidden folder beside FilmCraft, which is then updated.
        let leftover = s.all.appendingPathComponent(".artcraft-launcher-leftover")
        try fm.createDirectory(at: leftover, withIntermediateDirectories: false)
        try update(film, "FilmCraft")
        retrier.request([filmPath])
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let gaveUp = clean(film) && looks == 3
        // A new event on FilmCraft, such as another install there, starts its retries afresh.
        retrier.request([filmPath], fresh: true)
        let looked = await waitUntil(5) { looks >= 4 }
        try await Task.sleep(nanoseconds: 150_000_000)
        try fm.removeItem(at: leftover)
        let back = await waitUntil(5) { !clean(film) }
        try check(
            gaveUp && looked && back,
            "a new event on an app starts its retries afresh, so an install folder that lingered past them does not leave it without its icon")
    }
    /// The running app puts icons back by itself and says so on the status line, never in an alert.
    @MainActor static func reapplyUI(resources: URL, root: URL) async throws {
        let user = root.appendingPathComponent("Applications"), all = root.appendingPathComponent("Shared")
        for folder in [user, all] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let icon = resources.appendingPathComponent("BetterIcon.icns")
        let film = try fixtureApp(all, "FilmCraft", id: "local.bettericon.keep.window-film", icon: icon)
        let photo = try fixtureApp(user, "PhotoCraft", id: "local.bettericon.keep.window-photo", icon: icon)
        let grid = try fixtureApp(all, "GridCraft", id: "local.bettericon.keep.window-grid", icon: icon)
        let deck = try fixtureApp(all, "DeckCraft", id: "local.bettericon.keep.window-deck", icon: icon)
        let sound = try fixtureApp(all, "SoundCraft", id: "local.bettericon.keep.window-sound", icon: icon)
        let teal = try paint(root.appendingPathComponent("teal.png"), NSColor(srgbRed: 0.1, green: 0.6, blue: 0.6, alpha: 1))
        let pack = Pack(
            id: "Checks/Teal", name: "Teal", author: "Checks",
            icons: ["FilmCraft": teal, "PhotoCraft": teal, "GridCraft": teal, "DeckCraft": teal, "SoundCraft": teal])
        let install = try Installation(resources: resources, fixture: root)
        let store = AppIcons(install.state.appendingPathComponent("App Icons"))
        let found = install.catalog.discover()
        let plan = store.review(apps: found, pack: pack, scope: nil, restore: false)
        let result = try store.perform(plan, apps: found, pack: pack)
        guard result.changed.count == 5 else { throw Problem("the fixture apps did not take the pack: " + result.errors.joined()) }
        _ = try updatePreferences(install.state) {
            $0.defaultPaths.subtract(result.changed)
            $0.noteApplied(plan, result, pack: pack)
        }
        // The Launcher updates PhotoCraft while BetterIcon is closed.
        try launcherUpdate(photo, with: release(root, "PhotoCraft", id: "local.bettericon.keep.window-photo", icon: icon, version: "2"))
        guard clean(photo) else { throw Problem("the simulated update kept the custom icon") }
        let host = try Application(install, hidden: true, presentWindow: { window in
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderBack(nil)
        })
        host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { host.window.orderOut(nil) }
        let web = host.web!
        func statusLine() async -> String {
            (try? await web.evaluateJavaScript("el('status').textContent") as? String) ?? ""
        }
        // Apps put back within a short time are named together, as in "Put your icons back on 2 updated apps: …".
        // With `previous`, the line must differ from it: the icon is on the app a moment before the line names it.
        func back(_ app: URL, _ name: String, within seconds: Double, previous: String? = nil) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if !clean(app) {
                    let line = await statusLine()
                    if line.hasPrefix("Put your icon") && line.contains(name) && line != previous { return true }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return false
        }
        let started = await back(photo, "PhotoCraft", within: 30)
        try check(started, "an app updated while BetterIcon was closed gets its icon back when BetterIcon starts")
        // While BetterIcon runs, the Launcher updates FilmCraft as another operation holds the lock.
        let lock = open(install.state.appendingPathComponent("App Icons/operations.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX) == 0 else { throw Problem("could not hold the operations lock") }
        try launcherUpdate(film, with: release(root, "FilmCraft", id: "local.bettericon.keep.window-film", icon: icon, version: "2"))
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let held = clean(film)
        flock(lock, LOCK_UN)
        close(lock)
        let running = await back(film, "FilmCraft", within: 30)
        let together = await statusLine() == "Put your icons back on 2 updated apps: FilmCraft, PhotoCraft."
        try check(
            held && running && together && host.alertsShown == 0 && NSApp.modalWindow == nil,
            "an update while BetterIcon runs is put back once the lock is free and reported on the status line without an alert")
        // macOS refuses the change after the next update of PhotoCraft, as when App Management is not allowed.
        let write = host.icons.writeIcon
        host.icons.writeIcon = { _, _ in false }
        try launcherUpdate(photo, with: release(root, "PhotoCraft", id: "local.bettericon.keep.window-photo", icon: icon, version: "3"))
        var told = false
        for _ in 0..<300 where !told {
            told = await statusLine().contains("Privacy & Security > App Management")
            if !told { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        // Writes would work again now. A change from another process makes BetterIcon look at PhotoCraft again.
        host.icons.writeIcon = write
        guard try run("/usr/bin/touch", [photo.path]) == 0 else { throw Problem("could not touch the fixture app") }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        try check(
            told && clean(photo) && host.alertsShown == 0 && NSApp.modalWindow == nil,
            "a refusal is explained on the status line with the App Management setting, without an alert, and that copy is not tried again")
        // Discovery names apps by their standardized path, such as /tmp for /private/tmp.
        func shown(_ app: URL) -> String { app.standardizedFileURL.path }
        func tile(_ app: URL) async -> String {
            let image = try? await web.callAsyncJavaScript(
                "return (model.apps.find(a => a.id === id) || {}).image || ''", arguments: ["id": shown(app)],
                contentWorld: .page)
            return image as? String ?? ""
        }
        func says(_ text: String, within seconds: Double = 15) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if await statusLine().contains(text) { return true }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return false
        }
        let tealTile = artLink(teal)
        // FilmCraft is updated next and gets its icon back. The status line keeps naming PhotoCraft, which still lacks
        // its icon, and PhotoCraft's tile shows the icon it has.
        let earlier = await statusLine()
        try launcherUpdate(film, with: release(root, "FilmCraft", id: "local.bettericon.keep.window-film", icon: icon, version: "3"))
        let filmBack = await back(film, "FilmCraft", within: 30, previous: earlier)
        let line = await statusLine()
        let photoTile = await tile(photo), filmTile = await tile(film)
        try check(
            filmBack && line.hasPrefix("Put your icon back on FilmCraft after its update.")
                && line.contains("PhotoCraft still has its original icon") && line.contains("Privacy & Security > App Management")
                && !photoTile.isEmpty && photoTile != tealTile && filmTile == tealTile && host.alertsShown == 0,
            "after a refusal the status line keeps naming the app that still lacks its icon while other apps get theirs back, and its tile shows the icon it has")
        // The user gives FilmCraft an icon of their own in Finder, in another process. Its next update leaves it at its
        // original icon.
        let magenta = try paint(root.appendingPathComponent("magenta.png"), NSColor(srgbRed: 0.8, green: 0.1, blue: 0.6, alpha: 1))
        try setIconElsewhere(magenta, film)
        let own = try forkBytes(film)
        let noticed = await says("FilmCraft keeps the icon you gave it")
        let left = (try? forkBytes(film)) == own
        try launcherUpdate(film, with: release(root, "FilmCraft", id: "local.bettericon.keep.window-film", icon: icon, version: "4"))
        let honoured = await says("FilmCraft keeps its original icon after its update")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let preferences = install.state.appendingPathComponent("preferences.json")
        let afterUpdate = try saved(Preferences.self, at: preferences, fallback: Preferences())
        let filmOwn = await tile(film)
        try check(
            noticed && left && honoured && clean(film) && afterUpdate.defaultPaths.contains(shown(film))
                && filmOwn != tealTile && host.alertsShown == 0,
            "an icon the user gives an app while BetterIcon runs is left alone, also after the app's next update, and the status line says so")
        // The user removes GridCraft's icon in Finder.
        try setIconElsewhere(nil, grid)
        let removedNote = await says("GridCraft keeps its original icon, because its custom icon was removed outside BetterIcon")
        try await Task.sleep(nanoseconds: 500_000_000)
        let afterRemoval = try saved(Preferences.self, at: preferences, fallback: Preferences())
        let gridTile = await tile(grid)
        try check(
            removedNote && afterRemoval.defaultPaths.contains(shown(grid)) && gridTile != tealTile && clean(grid)
                && record(store.root, shown(grid)) == nil && host.alertsShown == 0,
            "an icon removed in Finder while BetterIcon runs counts as a restore of that app, in the preferences, on the status line and in its tile")
        // Quitting while BetterIcon puts icons back waits for the app being written. The others wait for the next start.
        let lock2 = open(install.state.appendingPathComponent("App Icons/operations.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock2 >= 0, flock(lock2, LOCK_EX) == 0 else { throw Problem("could not hold the operations lock") }
        try launcherUpdate(deck, with: release(root, "DeckCraft", id: "local.bettericon.keep.window-deck", icon: icon, version: "2"))
        try launcherUpdate(sound, with: release(root, "SoundCraft", id: "local.bettericon.keep.window-sound", icon: icon, version: "2"))
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let entered = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        let gate = NSLock()
        var first = true
        host.icons.writeIcon = { image, path in
            gate.lock()
            let hold = first
            first = false
            gate.unlock()
            if hold {
                entered.signal()
                _ = proceed.wait(timeout: .now() + 20)
            }
            return write(image, path)
        }
        var replied: Bool?
        host.terminateReply = { replied = $0 }
        flock(lock2, LOCK_UN)
        close(lock2)
        let inWrite = await waitUntil(15) { entered.wait(timeout: .now()) == .success }
        let answer = host.applicationShouldTerminate(NSApp)
        try await Task.sleep(nanoseconds: 500_000_000)
        let waited = replied == nil
        proceed.signal()
        let answered = await waitUntil(10) { replied != nil }
        try await Task.sleep(nanoseconds: 500_000_000)
        let finished = [deck, sound].filter { !clean($0) }
        let settled = finished.count == 1 && record(store.root, shown(finished[0])) != nil
            && record(store.root, shown(finished[0]))?["pending"] == nil
            && (try? customFlag(finished[0])) == true
        try check(
            inWrite && answer == .terminateLater && waited && answered && replied == true && settled,
            "quitting while BetterIcon puts icons back waits for the app being written, and leaves the other apps for the next start")
    }
    /// A fixture with the given apps, the teal pack applied to all of them, and the app that runs on it, offscreen.
    @MainActor static func reapplyHost(
        resources: URL, root: URL, shared: [String], personal: [String], tag: String,
        prepare: (Installation) throws -> Void = { _ in }
    ) throws -> (host: Application, apps: [String: URL], teal: URL, install: Installation) {
        let user = root.appendingPathComponent("Applications"), all = root.appendingPathComponent("Shared")
        for folder in [user, all] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let icon = resources.appendingPathComponent("BetterIcon.icns")
        let teal = try paint(root.appendingPathComponent("teal.png"), NSColor(srgbRed: 0.1, green: 0.6, blue: 0.6, alpha: 1))
        var apps = [String: URL]()
        for (folder, names) in [(all, shared), (user, personal)] {
            for name in names {
                apps[name] = try fixtureApp(folder, name, id: "local.bettericon.keep.\(tag)-" + name.lowercased(), icon: icon)
            }
        }
        let pack = Pack(id: "Checks/Teal", name: "Teal", author: "Checks", icons: apps.mapValues { _ in teal })
        let install = try Installation(resources: resources, fixture: root)
        let store = AppIcons(install.state.appendingPathComponent("App Icons"))
        let found = install.catalog.discover()
        let plan = store.review(apps: found, pack: pack, scope: nil, restore: false)
        let result = try store.perform(plan, apps: found, pack: pack)
        guard result.changed.count == apps.count else {
            throw Problem("the fixture apps did not take the pack: " + result.errors.joined())
        }
        _ = try updatePreferences(install.state) {
            $0.defaultPaths.subtract(result.changed)
            $0.noteApplied(plan, result, pack: pack)
        }
        try prepare(install)
        let host = try Application(install, hidden: true, presentWindow: { window in
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderBack(nil)
        })
        return (host, apps, teal, install)
    }
    /// A Restore chosen while BetterIcon is putting icons back waits for it, so the reviewed plan still holds.
    @MainActor static func reviewDuringPass(resources: URL, root: URL) async throws {
        let icon = resources.appendingPathComponent("BetterIcon.icns")
        let shared = ["FilmCraft", "GridCraft", "SoundCraft"]
        let fixture = try reapplyHost(resources: resources, root: root, shared: shared, personal: ["PhotoCraft"], tag: "pass")
        let host = fixture.host
        // The Launcher updates the three shared apps while BetterIcon is closed.
        for name in shared {
            try launcherUpdate(
                fixture.apps[name]!,
                with: release(root, name, id: "local.bettericon.keep.pass-" + name.lowercased(), icon: icon, version: "2"))
        }
        // Each icon write takes a moment, so the user's Restore arrives while BetterIcon is putting icons back.
        let write = host.icons.writeIcon
        host.icons.writeIcon = { image, path in
            Thread.sleep(forTimeInterval: 0.7)
            return write(image, path)
        }
        host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { host.window.orderOut(nil) }
        let updated = shared.map { fixture.apps[$0]! }
        let midway = await waitUntil(30) { updated.contains { !clean($0) } }
        let stillWriting = updated.contains(where: clean)
        var offered = [String](), errors = [String]()
        let driver = AlertDriver { alert in
            if alert.text.contains("Restore icons in which location?") { return alert.buttons.first { $0.hasPrefix("Everywhere") } }
            if alert.text.contains("Review original icons") {
                offered = alert.buttons
                return alert.buttons.first
            }
            if alert.buttons == ["OK"] {
                errors.append(alert.text)
                return "OK"
            }
            return nil
        }
        defer { driver.stop() }
        _ = try await host.web.evaluateJavaScript("send('review', {restore: true}); true")
        var line = ""
        let end = Date().addingTimeInterval(40)
        while Date() < end {
            line = (try? await host.web.evaluateJavaScript("el('status').textContent") as? String) ?? ""
            if line.contains("restored") || !errors.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let records = ((try? fm.contentsOfDirectory(atPath: fixture.install.state.appendingPathComponent("App Icons/records").path)) ?? [])
            .filter { $0.hasSuffix(".json") }
        try check(
            midway && stillWriting && errors.isEmpty && offered.first == "Restore 4 icons" && line == "4 icons restored."
                && fixture.apps.values.allSatisfy(clean) && records.isEmpty,
            "a Restore chosen while BetterIcon puts icons back waits for it, then restores every app without an error")
    }
    /// An app put back while the location alert is open does not drop the review the alert leads to, and icons keep
    /// coming back afterwards.
    @MainActor static func reviewDuringRefresh(resources: URL, root: URL) async throws {
        let icon = resources.appendingPathComponent("BetterIcon.icns")
        let holding = root.appendingPathComponent("Uninstalled")
        var photoHome: URL?
        let fixture = try reapplyHost(
            resources: resources, root: root, shared: ["FilmCraft"], personal: ["PhotoCraft"], tag: "refresh"
        ) { install in
            // PhotoCraft is uninstalled when BetterIcon starts. Its record stays.
            try fm.createDirectory(at: holding, withIntermediateDirectories: true)
            let photo = root.appendingPathComponent("Applications/PhotoCraft.app")
            guard try run("/bin/mv", [photo.path, holding.appendingPathComponent("PhotoCraft.app").path]) == 0 else {
                throw Problem("could not move PhotoCraft aside")
            }
            photoHome = photo
        }
        let host = fixture.host, film = fixture.apps["FilmCraft"]!
        guard let photo = photoHome else { throw Problem("PhotoCraft was not moved aside") }
        host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { host.window.orderOut(nil) }
        var ready = false
        for _ in 0..<300 where !ready {
            ready = (try? await host.web.evaluateJavaScript(
                "typeof model !== 'undefined' && !!model && model.apps.length === 1 && !working") as? Bool) == true
            if !ready { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        // From now on finding the installed apps takes a while, as it can with many apps or a slow disk.
        let discover = host.discoverApps
        host.discoverApps = { folders in
            Thread.sleep(forTimeInterval: 3)
            return discover(folders)
        }
        // The first icon write waits until the location alert is open.
        let entered = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        let write = host.icons.writeIcon
        let gate = NSLock()
        var first = true
        host.icons.writeIcon = { image, path in
            gate.lock()
            let hold = first
            first = false
            gate.unlock()
            if hold {
                entered.signal()
                _ = proceed.wait(timeout: .now() + 20)
            }
            return write(image, path)
        }
        // ArtCraft Launcher installs PhotoCraft again, and BetterIcon starts putting its icon back.
        try launcherInstall(photo, with: release(root, "PhotoCraft", id: "local.bettericon.keep.refresh-photocraft", icon: icon, version: "2"))
        let writing = await waitUntil(20) { entered.wait(timeout: .now()) == .success }
        var released = false, reviewed = false, backAt: Date?
        var errors = [String]()
        let driver = AlertDriver { alert in
            if alert.text.contains("Restore icons in which location?") {
                if !released {
                    released = true
                    proceed.signal()
                }
                // The user answers just after PhotoCraft has its icon back.
                if backAt == nil && !clean(photo) { backAt = Date() }
                guard let at = backAt, Date().timeIntervalSince(at) > 0.5 else { return nil }
                return alert.buttons.first { $0.hasPrefix("All users") }
            }
            if alert.text.contains("Review original icons") {
                reviewed = true
                return "Cancel"
            }
            if alert.buttons == ["OK"] {
                errors.append(alert.text)
                return "OK"
            }
            return nil
        }
        defer { driver.stop() }
        _ = try await host.web.evaluateJavaScript("send('review', {restore: true}); true")
        _ = await waitUntil(25) { reviewed }
        // Icons keep coming back afterwards.
        try launcherUpdate(film, with: release(root, "FilmCraft", id: "local.bettericon.keep.refresh-filmcraft", icon: icon, version: "2"))
        let filmBack = await waitUntil(25) { !clean(film) }
        try check(
            writing && released && reviewed && errors.isEmpty && filmBack && !clean(photo),
            "a review opened while BetterIcon puts an icon back is not lost, and icons keep coming back afterwards")
    }
    /// Right-click > Restore on an app that already shows its original icon, here because macOS refused to put its
    /// icon back after an update: the review offers to keep that icon, and the status line says the app is at it.
    @MainActor static func restoreLabel(resources: URL, root: URL) async throws {
        let icon = resources.appendingPathComponent("BetterIcon.icns")
        let fixture = try reapplyHost(resources: resources, root: root, shared: [], personal: ["PhotoCraft"], tag: "label")
        let host = fixture.host, photo = fixture.apps["PhotoCraft"]!
        host.icons.writeIcon = { _, _ in false }
        try launcherUpdate(photo, with: release(root, "PhotoCraft", id: "local.bettericon.keep.label-photocraft", icon: icon, version: "2"))
        host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { host.window.orderOut(nil) }
        func statusLine() async -> String {
            (try? await host.web.evaluateJavaScript("el('status').textContent") as? String) ?? ""
        }
        func says(_ text: String, within seconds: Double) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if await statusLine().contains(text) { return true }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return false
        }
        let refused = await says("PhotoCraft still has its original icon", within: 30)
        var offered = [String]()
        let driver = AlertDriver { alert in
            if alert.text.contains("Restore icons in which location?") { return alert.buttons.first { $0.hasPrefix("Current user") } }
            if alert.text.contains("Review original icons") {
                offered = alert.buttons
                return alert.buttons.first
            }
            return alert.buttons == ["OK"] ? "OK" : nil
        }
        defer { driver.stop() }
        _ = try await host.web.evaluateJavaScript("send('review', {restore: true, only: 'PhotoCraft'}); true")
        let kept = await says("PhotoCraft is at its original icon.", within: 30)
        let line = await statusLine()
        let store = fixture.install.state.appendingPathComponent("App Icons")
        try check(
            refused && kept && offered.first == "Keep original icon" && record(store, photo.standardizedFileURL.path) == nil
                && !line.contains("PhotoCraft still has") && clean(photo),
            "restoring an app that already shows its original icon offers to keep it and says so, instead of 0 icons restored")
    }
    /// An apps folder that appears after BetterIcon started, such as a first personal Applications folder, is watched
    /// from the next sweep on.
    @MainActor static func lateFolder(resources: URL, root: URL) async throws {
        let icon = resources.appendingPathComponent("BetterIcon.icns")
        let late = root.appendingPathComponent("Later apps")
        let fixture = try reapplyHost(resources: resources, root: root, shared: ["FilmCraft"], personal: [], tag: "late") { install in
            _ = try updatePreferences(install.state) { $0.folders = [late] }
        }
        let host = fixture.host
        let sweep = Application.sweepInterval
        Application.sweepInterval = 1.5
        host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        Application.sweepInterval = sweep
        defer { host.window.orderOut(nil) }
        var ready = false
        for _ in 0..<300 where !ready {
            ready = (try? await host.web.evaluateJavaScript(
                "typeof model !== 'undefined' && !!model && model.apps.length === 1 && !working") as? Bool) == true
            if !ready { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        // The folder appears with an app in it, which gets the pack.
        try fm.createDirectory(at: late, withIntermediateDirectories: true)
        let grid = try fixtureApp(late, "GridCraft", id: "local.bettericon.keep.late-gridcraft", icon: icon)
        let pack = Pack(id: "Checks/Teal", name: "Teal", author: "Checks", icons: ["GridCraft": fixture.teal])
        let found = fixture.install.catalog.discover(extraFolders: [late])
        let plan = host.icons.review(apps: found, pack: pack, scope: nil, restore: false, only: "GridCraft")
        guard try host.icons.perform(plan, apps: found, pack: pack).changed.count == 1 else {
            throw Problem("the app in the new folder did not take the pack")
        }
        try await Task.sleep(nanoseconds: 3_500_000_000)
        try launcherUpdate(grid, with: release(root, "GridCraft", id: "local.bettericon.keep.late-gridcraft", icon: icon, version: "2"))
        let back = await waitUntil(10) { !clean(grid) }
        try check(back, "an apps folder created after BetterIcon started is watched from the next sweep on")
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
    // MARK: Open at login, new apps, each copy's artwork in the Launcher, and the downloads a new installation offers

    /// A fixture with empty Applications and Shared folders and no saved preferences: a new installation.
    static func emptyFixture(_ resources: URL, _ root: URL, _ name: String) throws -> Installation {
        let folder = root.appendingPathComponent(name)
        for sub in ["Applications", "Shared"] {
            try fm.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        return try Installation(resources: resources, fixture: folder)
    }
    /// Start the app on a fixture, offscreen. `login` nil stands for a Mac without the Open at Login option. `presented`
    /// counts the times the app shows its window.
    @MainActor static func startHost(
        _ install: Installation, hidden: Bool = true, login: LoginItem? = nil,
        acquire: ((String) throws -> [Pack])? = nil, event: @escaping () -> NSAppleEventDescriptor? = { nil },
        presented: @escaping () -> Void = {}
    ) throws -> Application {
        let host = try Application(install, hidden: hidden, presentWindow: { window in
            presented()
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderBack(nil)
        }, loginItem: .some(login), acquirePack: acquire, currentEvent: event)
        host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        return host
    }
    /// Take the menu bar icons of apps a group of checks is done with out of the menu bar, and hide their windows. Every
    /// app started in this process adds an icon, and a full menu bar hides the icon a later check opens the window under.
    /// The hosts already taken out of the menu bar.
    static var retired = Set<ObjectIdentifier>()
    @MainActor static func retire(_ hosts: [Application]) {
        for host in hosts where retired.insert(ObjectIdentifier(host)).inserted {
            if let item = host.menuBarItem { NSStatusBar.system.removeStatusItem(item) }
            host.window?.orderOut(nil)
        }
    }
    @MainActor static func js(_ host: Application, _ source: String) async -> Any? {
        try? await host.web.evaluateJavaScript(source)
    }
    @MainActor static func jsUntil(_ host: Application, _ condition: String, _ seconds: Double = 30) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await js(host, condition) as? Bool == true { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
    /// The interface has its model and no work is under way.
    @MainActor static func settled(_ host: Application) async -> Bool {
        await jsUntil(host, "typeof model !== 'undefined' && !!model && !working")
    }
    @MainActor static func statusText(_ host: Application) async -> String {
        await js(host, "el('status').textContent") as? String ?? ""
    }
    @MainActor static func statusUntil(_ host: Application, _ text: String, _ seconds: Double = 30) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await statusText(host).contains(text) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
    static func storedPrefs(_ install: Installation) -> Preferences? {
        try? saved(Preferences.self, at: install.state.appendingPathComponent("preferences.json"), fallback: Preferences())
    }
    /// The saved choice about opening at login.
    static func loginChoice(_ install: Installation) -> Bool? { Choices.load(install.state)?.openAtLogin }
    /// The Open at Login item of the menu bar icon's menu as it is built now, and whether it is checked. With `choose`,
    /// it is also chosen.
    @MainActor static func loginMenu(_ host: Application, choose: Bool = false) -> (found: Bool, on: Bool) {
        var seen = (found: false, on: false)
        host.statusMenu { menu, _ in
            let index = menu.indexOfItem(withTitle: "Open at Login")
            guard index >= 0, let entry = menu.item(at: index) else { return }
            seen = (true, entry.state == .on)
            if choose { menu.performActionForItem(at: index) }
        }
        return seen
    }
    /// An Apple event that opens or reopens an app, with an optional keyAEPropData value such as a login item launch.
    static func launchEvent(reopen: Bool = false, as property: OSType? = nil) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(reopen ? kAEReopenApplication : kAEOpenApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let property {
            event.setParam(NSAppleEventDescriptor(enumCode: property), forKeyword: AEKeyword(keyAEPropData))
        }
        return event
    }
    /// Opening at login, through a stand-in for macOS's login items: the suite never registers a real one.
    @MainActor static func loginChecks(resources: URL, root: URL) async throws {
        let lgit = OSType(keyAELaunchedAsLogInItem)
        // The first start of this version registers once and saves the choice as on.
        let first = try emptyFixture(resources, root, "first")
        let item = FakeLoginItem()
        let host = try startHost(first, login: item)
        let ready = await settled(host)
        let plain = try Application(emptyFixture(resources, root, "plain"), hidden: true)
        try check(
            ready && item.registrations == 1 && item.state == .enabled && loginChoice(first) == true
                && plain.loginItem == nil,
            "the first start of this version opens BetterIcon at login once and saves that choice, and a fixture installation never uses the system's login items")
        let menuOn = loginMenu(host)
        let boxOn = await jsUntil(host, "!el('loginRow').hidden && el('openAtLogin').checked", 10)
        item.state = .requiresApproval
        let menuWaiting = loginMenu(host)
        host.show()
        let boxWaiting = await jsUntil(host, "!el('loginRow').hidden && !el('openAtLogin').checked", 10)
        item.state = .enabled
        let menuBack = loginMenu(host)
        try check(
            menuOn == (true, true) && boxOn && menuWaiting == (true, false) && boxWaiting && menuBack == (true, true)
                && item.registrations == 1,
            "the Open at Login menu item and the box in Manage Icons are checked only while macOS really opens BetterIcon at login")
        _ = loginMenu(host, choose: true)
        let turnedOff = item.unregistrations == 1 && item.state == .off && loginChoice(first) == false
        let saidOff = await statusUntil(host, "BetterIcon no longer opens at login.", 10)
        _ = loginMenu(host, choose: true)
        let turnedOn = item.registrations == 2 && item.state == .enabled && loginChoice(first) == true
        try check(
            turnedOff && saidOff && turnedOn && loginMenu(host) == (true, true),
            "choosing Open at Login in the menu turns it off, which unregisters it and saves off, and choosing it again registers it and saves on")
        _ = await js(host, "el('openAtLogin').click(); true")
        let boxOff = await waitUntil(10) { item.state == .off && loginChoice(first) == false }
        let unchecked = await jsUntil(host, "!el('openAtLogin').checked", 10)
        _ = await js(host, "el('openAtLogin').click(); true")
        let boxBack = await waitUntil(10) { item.state == .enabled && loginChoice(first) == true }
        try check(
            boxOff && unchecked && boxBack && item.unregistrations == 2 && item.registrations == 3,
            "the Open at login box in Manage Icons turns it off and on")
        // Turned off in BetterIcon, then BetterIcon starts again.
        _ = loginMenu(host, choose: true)
        let again = FakeLoginItem()
        let restarted = try startHost(first, login: again)
        let restartReady = await settled(restarted)
        let restartedMenu = loginMenu(restarted)
        try check(
            restartReady && item.state == .off && loginChoice(first) == false && again.registrations == 0
                && restartedMenu == (true, false),
            "after the user turns it off in BetterIcon, it never registers again by itself, also after a restart")
        // The user removed BetterIcon from the login items in System Settings while it was closed, and while it runs.
        let settings = try emptyFixture(resources, root, "settings")
        _ = try Choices.update(settings.state) { $0.openAtLogin = true }
        let removed = FakeLoginItem()
        let noticed = try startHost(settings, login: removed)
        let noticedReady = await settled(noticed)
        noticed.show()
        let menuRemoved = loginMenu(noticed)
        let later = FakeLoginItem()
        let third = try startHost(settings, login: later)
        let thirdReady = await settled(third)
        let live = try emptyFixture(resources, root, "settings-live")
        let liveItem = FakeLoginItem()
        let liveHost = try startHost(live, login: liveItem)
        let liveReady = await settled(liveHost)
        liveItem.state = .off
        let liveMenu = loginMenu(liveHost)
        try check(
            noticedReady && thirdReady && liveReady && removed.registrations == 0 && later.registrations == 0
                && loginChoice(settings) == false && menuRemoved == (true, false) && liveItem.registrations == 1
                && liveMenu == (true, false) && loginChoice(live) == false,
            "when the user turns it off in System Settings, BetterIcon notices, saves off and never registers it again")
        // macOS asks the user to allow the login item first.
        let approval = try emptyFixture(resources, root, "approval")
        let asking = FakeLoginItem()
        asking.registers = .requiresApproval
        let asked = try startHost(approval, login: asking)
        let askedReady = await settled(asked)
        let told = await statusUntil(asked, "allow it in System Settings > General > Login Items", 10)
        let menuAsked = loginMenu(asked)
        let pending = FakeLoginItem()
        pending.state = .requiresApproval
        let next = try startHost(approval, login: pending)
        let nextReady = await settled(next)
        let nextLine = await statusText(next)
        let quiet = !nextLine.contains("Login Items")
        try check(
            askedReady && told && asking.registrations == 1 && loginChoice(approval) == true
                && menuAsked == (true, false) && nextReady && quiet && pending.registrations == 0,
            "when macOS asks for approval, the status line says once where to allow it, and Open at Login stays unchecked until it is allowed")
        // macOS 12 has no option.
        let twelve = try startHost(emptyFixture(resources, root, "twelve"), login: nil)
        let twelveReady = await settled(twelve)
        let noBox = await jsUntil(twelve, "el('loginRow').hidden && model.loginItem === undefined", 10)
        try check(
            twelveReady && noBox && loginMenu(twelve) == (false, false) && loginMenu(host).found,
            "where macOS has no Open at Login option the menu item and the box are left out, and nothing is registered")
        // Opened from the disk image, then from the Applications folder.
        let image = try emptyFixture(resources, root, "disk-image")
        let mounted = FakeLoginItem()
        mounted.unavailable = "To open BetterIcon at login, drag it into your Applications folder and open it from there."
        let fromImage = try startHost(image, login: mounted)
        let imageReady = await settled(fromImage)
        let unset = loginChoice(image) == nil && mounted.registrations == 0
        _ = loginMenu(fromImage, choose: true)
        let explained = await statusUntil(fromImage, "drag it into your Applications folder", 10)
        let installed = FakeLoginItem()
        let moved = try startHost(image, login: installed)
        let movedReady = await settled(moved)
        try check(
            imageReady && unset && explained && mounted.registrations == 0 && movedReady && installed.registrations == 1
                && loginChoice(image) == true,
            "a copy opened from the disk image is not registered and says why when asked, and it registers once it runs from Applications")
        // Opened at login, and opened by the user.
        var shownAtLogin = 0, shownByUser = 0
        let atLogin = try startHost(
            emptyFixture(resources, root, "login-launch"), hidden: false, login: FakeLoginItem(),
            event: { launchEvent(as: lgit) }, presented: { shownAtLogin += 1 })
        let byUser = try startHost(
            emptyFixture(resources, root, "user-launch"), hidden: false, login: FakeLoginItem(),
            event: { launchEvent() }, presented: { shownByUser += 1 })
        let launched = await settled(atLogin)
        let opened = await settled(byUser)
        try check(
            launched && opened && atLogin.launchedAtLogin && shownAtLogin == 0 && !atLogin.window.isVisible
                && !byUser.launchedAtLogin && shownByUser == 1,
            "when macOS opens BetterIcon at login it starts in the menu bar without showing its window, while a start by the user shows it")
        var reopen: NSAppleEventDescriptor?
        var shownOnReopen = 0
        let running = try startHost(
            emptyFixture(resources, root, "reopen"), login: FakeLoginItem(), event: { reopen }, presented: { shownOnReopen += 1 })
        _ = await settled(running)
        reopen = launchEvent(reopen: true, as: lgit)
        _ = running.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        let quietReopen = shownOnReopen == 0
        reopen = launchEvent(reopen: true)
        _ = running.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        try check(
            quietReopen && shownOnReopen == 1,
            "macOS reopening the running app as a login item does not show the window, while a reopen by the user does")
        let document = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenDocuments), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        document.setParam(NSAppleEventDescriptor(enumCode: lgit), forKeyword: AEKeyword(keyAEPropData))
        try check(
            LoginLaunch.detected(launchEvent(as: lgit)) && LoginLaunch.detected(launchEvent(reopen: true, as: lgit))
                && !LoginLaunch.detected(launchEvent()) && !LoginLaunch.detected(launchEvent(as: OSType(keyAELaunchedAsServiceItem)))
                && !LoginLaunch.detected(nil) && !LoginLaunch.detected(document),
            "BetterIcon recognizes the Apple event with which macOS opens a login item, and no other launch")
        retire([host, restarted, noticed, third, liveHost, asked, next, twelve, fromImage, moved, atLogin, byUser, running])
    }
    /// The downloads a new installation offers once, through a stand-in for the helper's acquire, so no network is used.
    @MainActor static func offerChecks(resources: URL, root: URL) async throws {
        let sizes = PackSizes.load(resources)
        let table = (try? String(contentsOf: resources.appendingPathComponent("Catalog/pack-sizes.tsv"), encoding: .utf8)) ?? ""
        let catalog = try String(contentsOf: resources.appendingPathComponent("Catalog/packs.tsv"), encoding: .utf8)
        let seed = try PublishedPacks(resources: resources, state: root.appendingPathComponent("size-cache")).list()
        try check(
            !sizes.isEmpty && Set(sizes.keys) == Set(seed.map(\.id)) && sizes.values.allSatisfy { $0 > 0 }
                && table.contains("#catalog\t" + digest(Data(catalog.replacingOccurrences(of: "\r\n", with: "\n").utf8))),
            "the installer knows the download size of every pack in its catalog")
        func size(_ packs: [Pack]) -> String {
            let megabytes = Double(packs.compactMap { sizes[$0.id] }.reduce(0, +)) / 1e6
            return megabytes < 10 ? String(format: "%.1f MB", megabytes) : "\(Int(megabytes.rounded())) MB"
        }
        let apps = seed.filter(\.canApps), files = seed.filter(\.canFiles)
        let appsText = "All app icon packs · \(apps.count) packs · " + size(apps)
        let filesText = "All file type icon packs · \(files.count) packs · " + size(files)
        let lock = NSLock()
        var requested = [String]()
        let failing = "Craft-Icons-Mains/Holographic"
        var downloaded = Set<String>()
        let acquire: (String) throws -> [Pack] = { id in
            Thread.sleep(forTimeInterval: 0.05)
            lock.lock()
            requested.append(id)
            if id != failing { downloaded.insert(id) }
            let done = downloaded
            lock.unlock()
            if id == failing { throw Problem("The artwork service is unreachable.") }
            return seed.map { pack in
                var copy = pack
                if done.contains(pack.id) { copy.status = "Downloaded" }
                return copy
            }
        }
        func asked() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return requested
        }
        // A new installation shows the offer, and an upgraded one never does.
        let fresh = try emptyFixture(resources, root, "offer-new")
        let newHost = try startHost(fresh, acquire: acquire)
        let offered = await jsUntil(newHost, "!el('offer').hidden && !working")
        let labels = await js(newHost, """
            [el('offerAppsText').textContent, el('offerFilesText').textContent, el('offerDownload').textContent,
             el('offerApps').checked && el('offerFiles').checked]
            """) as? [Any]
        let upgraded = try emptyFixture(resources, root, "offer-upgraded")
        _ = try updatePreferences(upgraded.state) { $0.size = 64 }
        let oldHost = try startHost(upgraded, acquire: acquire)
        let oldReady = await settled(oldHost)
        let noOffer = await jsUntil(oldHost, "el('offer').hidden && model.downloadOffer === undefined", 5)
        try check(
            offered && labels?[0] as? String == appsText && labels?[1] as? String == filesText
                && labels?[2] as? String == "Download " + size(seed) && labels?[3] as? Bool == true
                && storedPrefs(fresh)?.offerPacks == true && oldReady && noOffer && storedPrefs(upgraded)?.offerPacks == nil
                && newHost.alertsShown == 0 && NSApp.modalWindow == nil,
            "a new installation offers once in its window to download all app icon packs and all file type icon packs, each with its size, and an upgraded one never does")
        _ = await js(newHost, "el('offerFiles').click(); true")
        let appsOnly = await js(newHost, "el('offerDownload').textContent") as? String == "Download " + size(apps)
        _ = await js(newHost, "el('offerLater').click(); true")
        let declined = await jsUntil(newHost, "el('offer').hidden", 10)
        let explained = await statusUntil(newHost, "Each icon pack downloads when you choose it in Manage Icons.", 10)
        let reopened = try startHost(fresh, acquire: acquire)
        let reopenedReady = await settled(reopened)
        let stillGone = await jsUntil(reopened, "el('offer').hidden && model.downloadOffer === undefined", 5)
        try check(
            appsOnly && declined && explained && storedPrefs(fresh)?.offerPacks == nil && reopenedReady && stillGone
                && asked().isEmpty,
            "unchecking a choice changes the download size, and Not now ends the offer for good without downloading anything")
        // Download both: every pack, one after another, past a pack that fails.
        let downloads = try emptyFixture(resources, root, "offer-download")
        let host = try startHost(downloads, acquire: acquire)
        _ = await jsUntil(host, "!el('offer').hidden && !working")
        _ = await js(host, "el('offerDownload').click(); true")
        var progress = Set<String>(), final = ""
        let end = Date().addingTimeInterval(60)
        while Date() < end {
            let line = await statusText(host)
            if let at = line.range(of: "Downloading icon pack ") { progress.insert(String(line[at.lowerBound...])) }
            if let at = line.range(of: "Downloaded ") {
                final = String(line[at.lowerBound...])
                break
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let title = seed.first { $0.id == failing }?.title ?? failing
        let statuses = await js(host, "JSON.stringify(model.packs.filter(p => !p.default).map(p => [p.id, p.status]))") as? String
        let rows = (try? JSONSerialization.jsonObject(with: Data((statuses ?? "").utf8))) as? [[String]] ?? []
        let marked = rows.count == seed.count && rows.allSatisfy { $0.count == 2 && $0[1] == ($0[0] == failing ? "Download" : "Downloaded") }
        try check(
            !progress.isEmpty && progress.allSatisfy { $0.contains(" of \(seed.count): ") }
                && final == "Downloaded \(seed.count - 1) of \(seed.count) icon packs. Couldn’t download \(title): the artwork service is unreachable. Choose a pack to try it again."
                && asked().count == seed.count && Set(asked()) == Set(seed.map(\.id)) && marked
                && storedPrefs(downloads)?.offerPacks == nil && host.alertsShown == 0 && NSApp.modalWindow == nil,
            "Download fetches every chosen pack in turn through the helper's acquire, shows its progress and the pack that failed on the status line, and keeps going after a failure")
        retire([newHost, oldHost, reopened, host])
    }
    /// The Launcher draws for each copy the artwork BetterIcon put on it, and the user's own icon where BetterIcon gave way.
    @MainActor static func gridChecks(resources: URL, root: URL) async throws {
        let icon = resources.appendingPathComponent("BetterIcon.icns")
        let user = root.appendingPathComponent("Applications"), all = root.appendingPathComponent("Shared")
        for folder in [user, all] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let teal = try paint(root.appendingPathComponent("teal.png"), NSColor(srgbRed: 0.1, green: 0.6, blue: 0.6, alpha: 1))
        let orange = try paint(root.appendingPathComponent("orange.png"), NSColor(srgbRed: 0.95, green: 0.45, blue: 0.1, alpha: 1))
        let magenta = try paint(root.appendingPathComponent("magenta.png"), NSColor(srgbRed: 0.8, green: 0.1, blue: 0.6, alpha: 1))
        let shared = try fixtureApp(all, "FilmCraft", id: "local.bettericon.grid.film", icon: icon)
        let personal = try fixtureApp(user, "FilmCraft", id: "local.bettericon.grid.film", icon: icon)
        let grid = try fixtureApp(all, "GridCraft", id: "local.bettericon.grid.grid", icon: icon)
        let install = try Installation(resources: resources, fixture: root)
        let store = AppIcons(install.state.appendingPathComponent("App Icons"))
        func apply(_ pack: Pack, _ scope: Scope) throws {
            let found = install.catalog.discover()
            let plan = store.review(apps: found, pack: pack, scope: scope, restore: false)
            let result = try store.perform(plan, apps: found, pack: pack)
            guard !result.changed.isEmpty, result.errors.isEmpty else { throw Problem("the grid fixture did not take a pack") }
            _ = try updatePreferences(install.state) {
                $0.defaultPaths.subtract(result.changed)
                $0.noteApplied(plan, result, pack: pack)
            }
        }
        // Teal goes on the apps in Shared, then orange on the copy in Applications, so orange was applied last.
        try apply(Pack(id: "Checks/Teal", name: "Teal", author: "Checks", icons: ["FilmCraft": teal, "GridCraft": teal]), .shared)
        try apply(Pack(id: "Checks/Orange", name: "Orange", author: "Checks", icons: ["FilmCraft": orange]), .personal)
        let host = try startHost(install)
        _ = await settled(host)
        func tile(_ app: URL) async -> String {
            let image = try? await host.web.callAsyncJavaScript(
                "return (model.apps.find(a => a.id === id) || {}).image || ''", arguments: ["id": app.standardizedFileURL.path],
                contentWorld: .page)
            return image as? String ?? ""
        }
        let keptTeal = artLink(install.state.appendingPathComponent("App Icons/artwork/\(digest(try Data(contentsOf: teal))).png"))
        let before = (await tile(shared), await tile(personal))
        try launcherUpdate(shared, with: release(root, "FilmCraft", id: "local.bettericon.grid.film", icon: icon, version: "2"))
        try launcherUpdate(personal, with: release(root, "FilmCraft", id: "local.bettericon.grid.film", icon: icon, version: "2"))
        let back = await waitUntil(30) { !clean(shared) && !clean(personal) }
        var after = ("", "")
        let end = Date().addingTimeInterval(15)
        while Date() < end {
            after = (await tile(shared), await tile(personal))
            if after == (keptTeal, artLink(orange)) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try check(
            before == (keptTeal, artLink(orange)) && back && after == (keptTeal, artLink(orange)),
            "each copy of an app shows in the Launcher the artwork BetterIcon put on it, before and after both copies are updated")
        // The user gives GridCraft an icon of their own in Finder.
        try setIconElsewhere(magenta, grid)
        let noticed = await statusUntil(host, "GridCraft keeps the icon you gave it")
        var own = false
        for _ in 0..<50 where !own {
            let drawn = await tile(grid)
            own = host.scheme.source(of: drawn).map { $0.app && $0.url.standardizedFileURL.path == grid.standardizedFileURL.path } == true
            if !own { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        try check(
            noticed && own && host.alertsShown == 0,
            "an app on which BetterIcon gave way to the user's own icon shows that icon in the Launcher, not the pack")
        retire([host])
    }
    /// A copy of a release put into place with its resource forks and extended attributes, as a Finder copy keeps a
    /// custom icon, by another process.
    static func copyInstall(_ app: URL, with release: URL) throws {
        let staging = app.deletingLastPathComponent().appendingPathComponent(".copy-staging-" + UUID().uuidString.prefix(6))
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        let staged = staging.appendingPathComponent(app.lastPathComponent)
        guard try run("/usr/bin/ditto", [release.path, staged.path]) == 0, try run("/bin/mv", [staged.path, app.path]) == 0,
            try run("/bin/rm", ["-rf", staging.path]) == 0
        else { throw Problem("could not copy the release into place") }
    }
    /// New ArtCraft apps get the applied pack by themselves, within the locations the last Apply covered.
    @MainActor static func newAppChecks(resources: URL, root: URL) async throws {
        let icon = resources.appendingPathComponent("BetterIcon.icns")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let teal = try paint(root.appendingPathComponent("teal.png"), NSColor(srgbRed: 0.1, green: 0.6, blue: 0.6, alpha: 1))
        let magenta = try paint(root.appendingPathComponent("magenta.png"), NSColor(srgbRed: 0.8, green: 0.1, blue: 0.6, alpha: 1))
        let tealHash = digest(try Data(contentsOf: teal))
        let pack = Pack(
            id: "Checks/Teal", name: "Teal", author: "Checks",
            icons: Dictionary(uniqueKeysWithValues: Craft.names.map { ($0, teal) }))
        struct Fixture {
            let install: Installation, user: URL, all: URL, folder: URL
            var store: URL { install.state.appendingPathComponent("App Icons") }
        }
        /// Apps in each location, the teal pack applied to the given location or everywhere, and its preferences.
        func setup(_ name: String, shared: [String], personal: [String], scope: Scope?) throws -> Fixture {
            let folder = root.appendingPathComponent(name)
            let user = folder.appendingPathComponent("Applications"), all = folder.appendingPathComponent("Shared")
            for apps in [user, all] { try fm.createDirectory(at: apps, withIntermediateDirectories: true) }
            for (apps, names) in [(all, shared), (user, personal)] {
                for app in names {
                    _ = try fixtureApp(apps, app, id: "local.bettericon.adopt.\(name)-\(app.lowercased())", icon: icon)
                }
            }
            let install = try Installation(resources: resources, fixture: folder)
            let store = AppIcons(install.state.appendingPathComponent("App Icons"))
            let found = install.catalog.discover()
            let plan = store.review(apps: found, pack: pack, scope: scope, restore: false)
            let result = try store.perform(plan, apps: found, pack: pack)
            guard !result.changed.isEmpty, result.errors.isEmpty else { throw Problem("the fixture did not take the pack") }
            _ = try updatePreferences(install.state) {
                $0.defaultPaths.subtract(result.changed)
                $0.noteApplied(plan, result, pack: pack)
            }
            return Fixture(install: install, user: user, all: all, folder: folder)
        }
        /// A release of an app, outside the apps folders.
        func build(_ f: Fixture, _ name: String, version: String = "1") throws -> URL {
            try release(f.folder, name, id: "local.bettericon.adopt.\(f.folder.lastPathComponent)-\(name.lowercased())", icon: icon, version: version)
        }
        /// ArtCraft Launcher installs an app where there was none.
        func arrive(_ f: Fixture, _ folder: URL, _ name: String) throws -> URL {
            let app = folder.appendingPathComponent(name + ".app")
            try launcherInstall(app, with: build(f, name))
            return app
        }
        func path(_ app: URL) -> String { app.standardizedFileURL.path }
        // Everywhere: SoundCraft arrives while BetterIcon is closed.
        let one = try setup("1-everywhere", shared: ["FilmCraft"], personal: ["PhotoCraft"], scope: nil)
        let sound = try arrive(one, one.all, "SoundCraft")
        let host = try startHost(one.install)
        let atStart = await statusUntil(host, "Gave your Teal icon to the new app SoundCraft.")
        let rec = record(one.store, path(sound))
        let original = (rec?["original"] as? String).map { one.store.appendingPathComponent("originals/\($0).plist").path }
        try check(
            atStart && !clean(sound) && rec?["art"] as? String == tealHash && rec?["pending"] == nil
                && fm.fileExists(atPath: one.store.appendingPathComponent("artwork/\(tealHash).png").path)
                && original.map { fm.fileExists(atPath: $0) } == true && host.alertsShown == 0,
            "an ArtCraft app installed while BetterIcon was closed gets the applied pack when BetterIcon starts, with a backup of its own icon and a record, and the status line names it")
        // GridCraft and LightCraft arrive while it runs, one in each location, one after the other as the Launcher installs
        // them. One status line names both.
        let gridRelease = try build(one, "GridCraft")
        let gridOriginal = try systemImage(gridRelease)
        let grid = one.all.appendingPathComponent("GridCraft.app")
        try launcherInstall(grid, with: gridRelease)
        let gridFirst = await waitUntil(30) { !clean(grid) }
        let light = try arrive(one, one.user, "LightCraft")
        var together = false
        let end = Date().addingTimeInterval(30)
        while Date() < end {
            let line = await statusText(host)
            together = line.contains("Gave your Teal icons to") && line.contains("GridCraft") && line.contains("LightCraft")
            if together && !clean(light) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try check(
            gridFirst && together && !clean(grid) && !clean(light) && record(one.store, path(light))?["art"] as? String == tealHash
                && host.alertsShown == 0 && NSApp.modalWindow == nil,
            "new ArtCraft apps that appear while BetterIcon runs get the applied pack by themselves in both covered locations, and the status line names them without an alert")
        // The user restores GridCraft on its own, as the right-click Restore does.
        let found = one.install.catalog.discover()
        let plan = host.icons.review(apps: found, pack: .defaults, scope: nil, restore: true, only: "GridCraft")
        let restored = try host.icons.perform(plan, apps: found, pack: .defaults, wait: 10)
        _ = try updatePreferences(one.install.state) { $0.defaultPaths.formUnion(restored.defaults) }
        try check(
            plan.rows.first?.message == "Restore original icon" && restored.changed == [path(grid)] && clean(grid)
                && eventually { try distance(systemImage(grid), gridOriginal) < 0.02 } && record(one.store, path(grid)) == nil,
            "Restore brings back the own icon of a new app that BetterIcon gave the pack")
        // DeckCraft arrives with a custom icon of its own, GridCraft is updated after its restore, and TextureCraft arrives.
        let deckRelease = try build(one, "DeckCraft")
        try setIconElsewhere(magenta, deckRelease)
        let deck = one.all.appendingPathComponent("DeckCraft.app")
        try copyInstall(deck, with: deckRelease)
        try launcherUpdate(grid, with: build(one, "GridCraft", version: "2"))
        let texture = try arrive(one, one.all, "TextureCraft")
        let textured = await waitUntil(30) { !clean(texture) }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try check(
            textured && (try? forkBytes(deck)) != nil && (try? forkBytes(deck)) == (try? forkBytes(deckRelease))
                && record(one.store, path(deck)) == nil,
            "a new app that already carries a custom icon of its own is left alone, while a plain new app beside it gets the pack")
        try check(
            textured && clean(grid) && record(one.store, path(grid)) == nil,
            "an app the user restored on its own keeps its original icon when it is installed again, while another new app gets the pack")
        // Shared only: the location the Apply did not cover is left alone.
        let two = try setup("2-shared", shared: ["FilmCraft"], personal: ["PhotoCraft"], scope: .shared)
        let second = try startHost(two.install)
        _ = await settled(second)
        let pdf = try arrive(two, two.user, "PdfCraft")
        let material = try arrive(two, two.all, "MaterialCraft")
        let covered = await waitUntil(30) { !clean(material) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try check(
            storedPrefs(two.install)?.appliedScopes == ["shared"] && covered && clean(pdf) && record(two.store, path(pdf)) == nil,
            "a new app in a location the last Apply did not cover is left alone, while one in the covered location gets the pack")
        // Restore app defaults, then a new app; then Apply again, then another new app.
        let everything = two.install.catalog.discover()
        let restore = second.icons.review(apps: everything, pack: .defaults, scope: nil, restore: true)
        let reverted = try second.icons.perform(restore, apps: everything, pack: .defaults, wait: 10)
        _ = try updatePreferences(two.install.state) {
            $0.defaultPaths.formUnion(reverted.defaults)
            $0.noteApplied(restore, reverted, pack: .defaults)
        }
        let defaults = storedPrefs(two.install)?.appliedPack == Pack.defaults.id
        let effect = try arrive(two, two.all, "EffectCraft")
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let untouched = clean(effect) && record(two.store, path(effect)) == nil
        let again = two.install.catalog.discover()
        let apply = second.icons.review(apps: again, pack: pack, scope: .shared, restore: false)
        let reapplied = try second.icons.perform(apply, apps: again, pack: pack, wait: 10)
        _ = try updatePreferences(two.install.state) {
            $0.defaultPaths.subtract(reapplied.changed)
            $0.noteApplied(apply, reapplied, pack: pack)
        }
        let fig = try arrive(two, two.all, "FigCraft")
        let figged = await waitUntil(30) { !clean(fig) }
        try check(
            defaults && untouched && figged && second.alertsShown == 0,
            "after Restore app defaults no new app gets a pack, until a pack is applied again")
        // An Apply made before BetterIcon recorded its locations: BetterIcon keeps icons in Shared only.
        let three = try setup("3-older", shared: ["FilmCraft"], personal: ["PhotoCraft"], scope: .shared)
        _ = try updatePreferences(three.install.state) { $0.appliedScopes = nil }
        let third = try startHost(three.install)
        _ = await settled(third)
        let solid = try arrive(three, three.user, "SolidCraft")
        let mail = try arrive(three, three.all, "MailCraft")
        let mailed = await waitUntil(30) { !clean(mail) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        // The locations are worked out once, at the first look for apps, and saved.
        try check(
            storedPrefs(three.install)?.appliedScopes == ["shared"] && mailed && clean(solid)
                && record(three.store, path(solid)) == nil,
            "after an Apply made before BetterIcon recorded its locations, new apps get the pack where BetterIcon keeps icons and nowhere else")
        retire([host, second, third])
        // The store itself: a bundle still being copied, and an app outside the apps folders.
        let s = try scene(root, "4-store")
        _ = try fixtureApp(s.all, "FilmCraft", id: "local.bettericon.adopt.store-film", icon: icon)
        try s.apply(pack)
        let copying = try fixtureApp(s.all, "GridCraft", id: "local.bettericon.adopt.store-grid", icon: icon)
        let builds = s.root.appendingPathComponent("Builds")
        try fm.createDirectory(at: builds, withIntermediateDirectories: true)
        let outside = try fixtureApp(builds, "PdfCraft", id: "local.bettericon.adopt.store-pdf", icon: icon)
        guard let outsideEntry = s.catalog.app(at: outside) else { throw Problem("the build folder app was not recognized") }
        // A Finder copy under way has not written every sealed resource yet, so the signature fails.
        let resource = copying.appendingPathComponent("Contents/Resources/Original.icns")
        let aside = s.root.appendingPathComponent("Original.icns")
        try fm.moveItem(at: resource, to: aside)
        let art = pack.icons.mapValues(\.path)
        let adopt = Adoption(pack: pack.id, art: pack.icons, scopes: [.personal, .shared], roots: s.catalog.roots())
        let partway = try s.store.reconcile(
            s.apps() + [outsideEntry], appliedPack: pack.id, defaultPaths: [], appliedArt: art, adopt: adopt)
        let waited = partway.waiting.contains(path(copying)) && partway.adopted.isEmpty && clean(copying)
        try fm.moveItem(at: aside, to: resource)
        let whole = try s.store.reconcile(
            s.apps() + [outsideEntry], appliedPack: pack.id, defaultPaths: [], appliedArt: art, adopt: adopt)
        try check(
            waited && whole.adopted.map(\.url.path) == [path(copying)] && !clean(copying) && clean(outside)
                && record(s.state, path(outside)) == nil,
            "a new app still being copied into its folder gets the pack once its bundle is whole, and an app outside the apps folders is left alone")
        // The locations an Apply covered are recorded with the pack it applied.
        var prefs = Preferences()
        let changed = IconResult(changed: ["/Applications/FilmCraft.app"])
        prefs.noteApplied(Review(rows: [], scope: nil, restore: false, only: nil), changed, pack: pack)
        let everywhere = prefs.appliedScopes
        prefs.noteApplied(
            Review(rows: [], scope: .personal, restore: true, only: nil), IconResult(changed: ["/x"], othersKept: true), pack: .defaults)
        let afterRestore = prefs.appliedScopes
        // An Apply of one app leaves the locations as they are.
        prefs.noteApplied(Review(rows: [], scope: .personal, restore: false, only: "PhotoCraft"), changed, pack: pack)
        let afterOne = prefs.appliedScopes
        prefs.noteApplied(Review(rows: [], scope: .personal, restore: false, only: nil), changed, pack: pack)
        let personalOnly = prefs.appliedScopes
        prefs.noteApplied(Review(rows: [], scope: nil, restore: true, only: nil), IconResult(defaults: ["/x"]), pack: .defaults)
        // Restore app defaults leaves no location: an empty list, which unlike a missing one is never worked out again.
        try check(
            everywhere == ["personal", "shared"] && afterRestore == ["shared"] && afterOne == ["shared"]
                && personalOnly == ["personal"] && prefs.appliedScopes == [] && prefs.appliedPack == Pack.defaults.id,
            "an Apply records the locations it covered, a Restore of one location removes that location, and Restore app defaults clears them")
    }

    // MARK: Fixes after the review of open at login, new apps and the first-start downloads

    /// Run a program in another process without holding the main thread, so the app's own main-queue work goes on.
    @MainActor static func runAside(_ exe: String, _ arguments: [String]) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        while process.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
        return process.terminationStatus
    }
    /// Save preferences.json the way an earlier version does: without the keys it does not know.
    static func rewriteAsOlder(_ state: URL) throws {
        let url = state.appendingPathComponent("preferences.json")
        guard var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw Problem("Unreadable fixture preferences.")
        }
        for key in ["openAtLogin", "appliedScopes", "appliedFolders", "restoredApps", "offerPacks", "pendingPacks"] {
            json.removeValue(forKey: key)
        }
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
    /// Whether an element of the interface is drawn: present, not hidden, with a box on the page.
    @MainActor static func drawn(_ host: Application, _ id: String) async -> Bool {
        await js(host, "(() => { const e = el('\(id)'); return !!e && e.getClientRects().length > 0; })()") as? Bool == true
    }
    /// The menu bar icon's Refresh installed apps.
    @MainActor static func refreshApps(_ host: Application) {
        host.statusMenu { menu, _ in
            let index = menu.indexOfItem(withTitle: "Refresh installed apps")
            if index >= 0 { menu.performActionForItem(at: index) }
        }
    }
    /// Whether the Launcher draws an app with the icon the app carries now.
    @MainActor static func tileShowsApp(_ host: Application, _ app: URL) async -> Bool {
        let id = app.standardizedFileURL.path
        for _ in 0..<80 {
            let image = try? await host.web.callAsyncJavaScript(
                "return (model.apps.find(a => a.id === id) || {}).image || ''", arguments: ["id": id], contentWorld: .page)
            if let link = image as? String, let source = host.scheme.source(of: link), source.app,
                source.url.standardizedFileURL.path == id
            {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
    /// Keep the calling thread busy, as long work on the app's main thread does.
    static func hold(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
    /// Wait until the status line holds all these texts at once.
    @MainActor static func statusHolds(_ host: Application, _ texts: [String], _ seconds: Double = 30) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            let line = await statusText(host)
            if texts.allSatisfy({ line.contains($0) }) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
    /// Open at login after the review: a choice an earlier version cannot drop, news the user can see where it is
    /// needed, the name of the System Settings pane, and a disk image told apart through the volume itself.
    @MainActor static func loginFixChecks(resources: URL, root: URL) async throws {
        var hosts = [Application]()
        defer { retire(hosts) }
        // The user turns Open at Login off. Then an earlier version saves preferences.json, dropping the keys it does not
        // know, and this version starts again.
        let older = try emptyFixture(resources, root, "older-version")
        let item = FakeLoginItem()
        let first = try startHost(older, login: item)
        hosts.append(first)
        _ = await settled(first)
        _ = loginMenu(first, choose: true)
        let off = item.registrations == 1 && item.unregistrations == 1 && item.state == .off
        try rewriteAsOlder(older.state)
        let later = FakeLoginItem()
        let second = try startHost(older, login: later)
        hosts.append(second)
        let ready = await settled(second)
        try check(
            off && ready && later.registrations == 0 && loginMenu(second) == (true, false),
            "after an earlier version saves the preferences, the user's Open at Login off stands and BetterIcon registers nothing by itself")
        retire([first, second])
        // macOS asks the user to allow BetterIcon first, at the first start. The window opens on the Launcher.
        let pane = LoginItems.pane
        let approval = try emptyFixture(resources, root, "approval-note")
        let asking = FakeLoginItem()
        asking.registers = .requiresApproval
        var shown = 0
        let asked = try startHost(approval, hidden: false, login: asking, presented: { shown += 1 })
        hosts.append(asked)
        _ = await settled(asked)
        let atStart = shown
        let noted = await jsUntil(asked, """
            page === 'launcher' && !!el('loginNotice') && !el('loginNotice').hidden
              && el('loginNotice').getClientRects().length > 0 && el('loginNoticeText').textContent.includes('\(pane)')
            """, 10)
        let said = await statusUntil(asked, "allow it in \(pane).", 10)
        // Other news comes and goes; the note stays until macOS opens BetterIcon at login.
        _ = await js(asked, "el('offerLater').click(); true")
        let news = await statusUntil(asked, "Each icon pack downloads when you choose it", 10)
        let stays = await drawn(asked, "loginNotice")
        _ = await js(asked, "el('loginSettings').click(); true")
        let opened = await waitUntil(5) { asking.settingsOpened == 1 }
        asking.state = .enabled
        asked.show()
        let gone = await jsUntil(asked, "el('loginNotice').hidden", 10)
        try check(
            atStart == 1 && noted && said && news && stays && opened && gone && asked.alertsShown == 0,
            "while macOS waits for the user to allow BetterIcon at login, a note both tabs show says where until it is allowed, and its button opens System Settings there")
        retire([asked])
        // The menu bar icon's Open at Login, with the window hidden: while macOS waits for approval, and in a copy opened
        // from the disk image.
        let waiting = try emptyFixture(resources, root, "approval-menu")
        let pending = FakeLoginItem()
        pending.registers = .requiresApproval
        var waitShown = 0
        let menuHost = try startHost(waiting, login: pending, presented: { waitShown += 1 })
        hosts.append(menuHost)
        _ = await settled(menuHost)
        let before = loginMenu(menuHost)
        _ = loginMenu(menuHost, choose: true)
        let revealed = await jsUntil(menuHost, """
            page === 'manage' && el('status').getClientRects().length > 0 && el('status').textContent.includes('\(pane)')
            """, 10)
        let image = try emptyFixture(resources, root, "image-menu")
        let mounted = FakeLoginItem()
        mounted.unavailable = "To open BetterIcon at login, drag it into your Applications folder and open it from there."
        var imageShown = 0
        let imageHost = try startHost(image, login: mounted, presented: { imageShown += 1 })
        hosts.append(imageHost)
        _ = await settled(imageHost)
        _ = loginMenu(imageHost, choose: true)
        let explained = await jsUntil(imageHost, """
            page === 'manage' && el('status').getClientRects().length > 0
              && el('status').textContent.includes('drag it into your Applications folder')
            """, 10)
        try check(
            before == (true, false) && waitShown == 1 && revealed && pending.registrations == 1 && pending.settingsOpened == 1
                && imageShown == 1 && explained && mounted.registrations == 0,
            "Open at Login chosen in the menu bar icon's menu shows its news in Manage Icons when it needs the user, and opens System Settings where macOS waits for approval")
        retire([menuHost, imageHost])
        // A real read-only disk image holding a copy of an app, and a copy in a writable folder. Only resource values are
        // read: nothing is registered.
        let folder = root.appendingPathComponent("disk-image")
        let content = folder.appendingPathComponent("content")
        try fm.createDirectory(at: content, withIntermediateDirectories: true)
        let bundle = try fixtureApp(
            content, "BetterIcon Copy", id: "local.bettericon.fix.disk-image", icon: resources.appendingPathComponent("BetterIcon.icns"))
        let dmg = folder.appendingPathComponent("BetterIcon-check.dmg"), mount = folder.appendingPathComponent("mount")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        guard
            try await runAside(
                "/usr/bin/hdiutil",
                ["create", "-quiet", "-srcfolder", content.path, "-format", "UDZO", "-volname", "BetterIconCheck", dmg.path]) == 0,
            try await runAside(
                "/usr/bin/hdiutil", ["attach", "-quiet", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, dmg.path])
                == 0
        else { throw Problem("could not make or attach the test disk image") }
        var fromImage: String?, fromFolder: String? = "no ServiceManagement"
        if #available(macOS 13, *) {
            fromImage = SystemLoginItem(bundle: mount.appendingPathComponent("BetterIcon Copy.app")).unavailable
            fromFolder = SystemLoginItem(bundle: bundle).unavailable
        }
        var detached = try await runAside("/usr/bin/hdiutil", ["detach", "-quiet", mount.path]) == 0
        if !detached { detached = try await runAside("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) == 0 }
        try check(
            fromImage?.contains("drag it into your Applications folder") == true && fromFolder == nil && detached,
            "a copy opened from a read-only disk image is asked to move to Applications before it opens at login, and a copy in a writable folder is not")
    }
    /// New apps after the review: a folder included after the Apply, copies of apps that keep their original icon, new
    /// apps with an icon of their own, locations no Apply covered, a copy written in listing order, an app only a sweep can
    /// find, an icon removed while a second look is on its way, the copy-finished test, and a pass that should end.
    @MainActor static func newAppFixChecks(resources: URL, root: URL) async throws {
        let icon = resources.appendingPathComponent("BetterIcon.icns")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let teal = try paint(root.appendingPathComponent("teal.png"), NSColor(srgbRed: 0.1, green: 0.6, blue: 0.6, alpha: 1))
        let magenta = try paint(root.appendingPathComponent("magenta.png"), NSColor(srgbRed: 0.8, green: 0.1, blue: 0.6, alpha: 1))
        let pack = Pack(
            id: "Checks/Teal", name: "Teal", author: "Checks",
            icons: Dictionary(uniqueKeysWithValues: Craft.names.map { ($0, teal) }))
        var hosts = [Application]()
        defer { retire(hosts) }
        struct Fixture {
            let install: Installation, user: URL, all: URL, folder: URL
            var store: URL { install.state.appendingPathComponent("App Icons") }
        }
        func appID(_ f: Fixture, _ name: String) -> String {
            "local.bettericon.fix.\(f.folder.lastPathComponent)-\(name.lowercased())"
        }
        /// Apply or restore as the app does: review, perform, then save the result with the preferences.
        @discardableResult func change(
            _ f: Fixture, _ chosen: Pack, scope: Scope?, restore: Bool = false, only: String? = nil, extra: [URL] = []
        ) throws -> IconResult {
            let store = AppIcons(f.store)
            let found = f.install.catalog.discover(extraFolders: extra)
            let plan = store.review(apps: found, pack: chosen, scope: scope, restore: restore, only: only)
            let result = try store.perform(plan, apps: found, pack: chosen, wait: 10)
            guard result.errors.isEmpty else { throw Problem("the fixture change failed: " + result.errors.joined(separator: " / ")) }
            _ = try updatePreferences(f.install.state) {
                if restore { $0.defaultPaths.formUnion(result.defaults) } else { $0.defaultPaths.subtract(result.changed) }
                $0.noteApplied(plan, result, pack: chosen)
            }
            return result
        }
        /// Apps in each location, with the teal pack applied everywhere. `folders` are included before the Apply.
        func setup(_ name: String, shared: [String], personal: [String] = [], folders: [URL] = []) throws -> Fixture {
            let folder = root.appendingPathComponent(name)
            let user = folder.appendingPathComponent("Applications"), all = folder.appendingPathComponent("Shared")
            for apps in [user, all] { try fm.createDirectory(at: apps, withIntermediateDirectories: true) }
            let f = Fixture(install: try Installation(resources: resources, fixture: folder), user: user, all: all, folder: folder)
            for (apps, names) in [(all, shared), (user, personal)] {
                for app in names { _ = try fixtureApp(apps, app, id: appID(f, app), icon: icon) }
            }
            if !folders.isEmpty { _ = try updatePreferences(f.install.state) { $0.folders = folders } }
            try change(f, pack, scope: nil)
            return f
        }
        func build(_ f: Fixture, _ name: String, version: String = "1") throws -> URL {
            try release(f.folder, name, id: appID(f, name), icon: icon, version: version)
        }
        /// A release that carries an icon the user gave it, as a Finder copy of a customised bundle does.
        func own(_ f: Fixture, _ name: String) throws -> URL {
            let made = try build(f, name)
            try setIconElsewhere(magenta, made)
            return made
        }
        func arrive(_ f: Fixture, _ folder: URL, _ name: String) throws -> URL {
            let app = folder.appendingPathComponent(name + ".app")
            try launcherInstall(app, with: build(f, name))
            return app
        }
        func path(_ app: URL) -> String { app.standardizedFileURL.path }
        func untouched(_ f: Fixture, _ apps: [URL]) -> Bool { apps.allSatisfy { clean($0) && record(f.store, path($0)) == nil } }

        // Apply Everywhere, then the user includes a folder that already holds ArtCraft apps, as the menu's Include another
        // apps folder… does: add it, save it, and look for apps again.
        let one = try setup("1-included", shared: ["FilmCraft"])
        let host = try startHost(one.install)
        hosts.append(host)
        _ = await settled(host)
        let work = one.folder.appendingPathComponent("Work Apps")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let grid = try fixtureApp(work, "GridCraft", id: appID(one, "GridCraft"), icon: icon)
        let light = try fixtureApp(work, "LightCraft", id: appID(one, "LightCraft"), icon: icon)
        host.prefs.folders.append(work)
        _ = try updatePreferences(one.install.state) { $0.folders.append(work) }
        refreshApps(host)
        let found = await jsUntil(host, "model.apps.some(a => a.name === 'GridCraft') && model.apps.some(a => a.name === 'LightCraft') && !working")
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let quiet = await statusText(host)
        let waited = untouched(one, [grid, light]) && !quiet.contains("Gave your")
        // The next Apply covers that folder: its apps take the pack, and an app installed there afterwards gets it too.
        try change(one, pack, scope: nil, extra: [work])
        refreshApps(host)
        _ = await settled(host)
        let texture = try arrive(one, work, "TextureCraft")
        let adopted = await waitUntil(30) { !clean(texture) }
        try check(
            found && waited && !clean(grid) && !clean(light) && adopted && host.alertsShown == 0,
            "apps already in a folder included after the last Apply wait for the next Apply, which covers that folder for new apps")
        retire([host])

        // The user restores GridCraft and LightCraft one at a time, as the right-click Restore does. Then they rename
        // GridCraft to keep two versions, duplicate it, and move LightCraft to the other Applications folder.
        let two = try setup("2-restored", shared: ["FilmCraft", "GridCraft", "LightCraft"])
        let second = try startHost(two.install)
        hosts.append(second)
        _ = await settled(second)
        let gridApp = two.all.appendingPathComponent("GridCraft.app"), lightApp = two.all.appendingPathComponent("LightCraft.app")
        try change(two, .defaults, scope: nil, restore: true, only: "GridCraft")
        try change(two, .defaults, scope: nil, restore: true, only: "LightCraft")
        let restored = clean(gridApp) && clean(lightApp)
        let renamed = two.all.appendingPathComponent("GridCraft 0.23.app"), copy = two.all.appendingPathComponent("GridCraft copy.app")
        let moved = two.user.appendingPathComponent("LightCraft.app")
        guard try await runAside("/bin/mv", [gridApp.path, renamed.path]) == 0,
            try await runAside("/usr/bin/ditto", [renamed.path, copy.path]) == 0,
            try await runAside("/bin/mv", [lightApp.path, moved.path]) == 0
        else { throw Problem("could not rename, duplicate or move the restored apps") }
        // A new app beside them still gets the pack.
        let beside = try arrive(two, two.all, "TextureCraft")
        let control = await waitUntil(30) { !clean(beside) }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try check(
            restored && control && untouched(two, [renamed, copy, moved]) && second.alertsShown == 0,
            "an app the user restored one at a time keeps its original icon when it is renamed, duplicated or moved to the other Applications folder")
        retire([second])

        // DeckCraft and GridCraft arrive with an icon of the user's own. Then ArtCraft Launcher updates DeckCraft, and the
        // user removes GridCraft's icon in Finder.
        let three = try setup("3-own-icon", shared: ["FilmCraft"])
        let third = try startHost(three.install)
        hosts.append(third)
        _ = await settled(third)
        let deck = three.all.appendingPathComponent("DeckCraft.app"), ownGrid = three.all.appendingPathComponent("GridCraft.app")
        try copyInstall(deck, with: own(three, "DeckCraft"))
        try copyInstall(ownGrid, with: own(three, "GridCraft"))
        let noted = await waitUntil(30) {
            (storedPrefs(three.install)?.defaultPaths ?? []).isSuperset(of: [path(deck), path(ownGrid)])
        }
        let drawnOwn = await tileShowsApp(third, deck)
        try launcherUpdate(deck, with: build(three, "DeckCraft", version: "2"))
        try setIconElsewhere(nil, ownGrid)
        let next = try arrive(three, three.all, "TextureCraft")
        let given = await waitUntil(30) { !clean(next) }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try check(
            noted && drawnOwn && given && untouched(three, [deck, ownGrid]) && third.alertsShown == 0,
            "a new app that arrived with an icon of the user's own keeps its original icon after its next update, or once that icon is removed, and the Launcher draws the icon it carries")
        retire([third])

        // Restore app defaults, then an Apply of one app, as `--apply … --app FilmCraft --scope shared` does. SoundCraft, in
        // the location no Apply covers, carries an icon of the user's own.
        let four = try setup("4-one-app", shared: ["FilmCraft"], personal: ["PhotoCraft"])
        try change(four, .defaults, scope: nil, restore: true)
        try change(four, pack, scope: .shared, only: "FilmCraft")
        let none = storedPrefs(four.install)?.appliedScopes == [] && storedPrefs(four.install)?.appliedPack == pack.id
        let sound = four.user.appendingPathComponent("SoundCraft.app")
        try copyInstall(sound, with: own(four, "SoundCraft"))
        let fourth = try startHost(four.install)
        hosts.append(fourth)
        _ = await settled(fourth)
        let lone = try arrive(four, four.all, "GridCraft")
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let drawnSound = await tileShowsApp(fourth, sound)
        try check(
            none && untouched(four, [lone]) && drawnSound && fourth.alertsShown == 0,
            "after Restore app defaults an Apply of one app gives no new app the pack, and the Launcher draws an icon of the user's own on an app outside the covered locations")
        retire([fourth])

        // An earlier version saves preferences.json without the recorded locations: BetterIcon does not guess them again.
        let five = try setup("5-dropped", shared: ["FilmCraft"], personal: ["PhotoCraft"])
        let fifth = try startHost(five.install)
        hosts.append(fifth)
        _ = await settled(fifth)
        try rewriteAsOlder(five.install.state)
        let after = try arrive(five, five.all, "GridCraft")
        try await Task.sleep(nanoseconds: 3_000_000_000)
        try check(
            untouched(five, [after]) && fifth.alertsShown == 0,
            "once an earlier version has dropped the recorded locations from the preferences, new apps wait for the next Apply instead of a guess")
        retire([fifth])

        // Another process copies GridCraft into place in the order an APFS folder lists a bundle, Info.plist last, after a
        // pause in which BetterIcon looks at the half-copied bundle.
        let six = try setup("6-listing-order", shared: ["FilmCraft"])
        let sixth = try startHost(six.install)
        hosts.append(sixth)
        _ = await settled(sixth)
        let source = try build(six, "GridCraft").appendingPathComponent("Contents").path
        let target = six.all.appendingPathComponent("GridCraft.app")
        let contents = target.appendingPathComponent("Contents").path
        let script = "mkdir -p '\(contents)' && ditto '\(source)/_CodeSignature' '\(contents)/_CodeSignature'"
            + " && ditto '\(source)/MacOS' '\(contents)/MacOS' && ditto '\(source)/Resources' '\(contents)/Resources'"
            + " && sleep 3 && cp '\(source)/Info.plist' '\(contents)/Info.plist'"
        let copied = try await runAside("/bin/sh", ["-c", script]) == 0
        let whole = await waitUntil(20) { !clean(target) }
        let tile = await jsUntil(sixth, "model.apps.some(a => a.name === 'GridCraft')", 10)
        try check(
            copied && whole && tile && record(six.store, path(target))?["art"] != nil,
            "a new app copied in with its Info.plist last gets the pack and joins the Launcher once the copy is whole")
        retire([sixth])

        // An included folder that is missing at the Apply appears later with an app already in it, before anything watches
        // it, as when ArtCraft Launcher creates a first personal Applications folder to install into.
        let late = root.appendingPathComponent("7-sweep/Later apps")
        let seven = try setup("7-sweep", shared: ["FilmCraft"], folders: [late])
        let interval = Application.sweepInterval
        Application.sweepInterval = 1.5
        let seventh = try startHost(seven.install)
        Application.sweepInterval = interval
        hosts.append(seventh)
        _ = await settled(seventh)
        let staging = seven.folder.appendingPathComponent("New folder")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try launcherInstall(staging.appendingPathComponent("GridCraft.app"), with: build(seven, "GridCraft"))
        guard try await runAside("/bin/mv", [staging.path, late.path]) == 0 else { throw Problem("could not move the folder in") }
        let swept = await waitUntil(20) { !clean(late.appendingPathComponent("GridCraft.app")) }
        let joined = await jsUntil(seventh, "model.apps.some(a => a.name === 'GridCraft')", 10)
        try check(
            swept && joined,
            "an app in an apps folder that appeared with the app already in it is found and given the pack by the next sweep")
        retire([seventh])

        // The user removes FilmCraft's icon in Finder while BetterIcon's main thread is busy for a moment, and another
        // change on the app arrives meanwhile, so a second look is on its way before the first is saved.
        let eight = try setup("8-race", shared: ["FilmCraft"])
        let eighth = try startHost(eight.install)
        hosts.append(eighth)
        _ = await settled(eighth)
        let film = eight.all.appendingPathComponent("FilmCraft.app")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try setIconElsewhere(nil, film)
        try await Task.sleep(nanoseconds: 800_000_000)
        let filmPath = film.path
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { _ = try? run("/usr/bin/touch", [filmPath]) }
        hold(2)
        let saved = await waitUntil(15) { storedPrefs(eight.install)?.defaultPaths.contains(path(film)) == true }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let line = await statusText(eighth)
        try check(
            saved && untouched(eight, [film]) && !line.contains("new app FilmCraft"),
            "an icon removed in Finder stays removed while a second look at the app is on its way")
        retire([eighth])

        // A bundle still being copied: its executable exists with no bytes yet, signed or not.
        let store = try scene(root, "9-complete")
        let signed = try fixtureApp(store.root, "GridCraft", id: "local.bettericon.fix.complete-grid", icon: icon)
        let signedExe = signed.appendingPathComponent("Contents/MacOS/Example")
        let unsigned = store.root.appendingPathComponent("PdfCraft.app")
        let unsignedExe = unsigned.appendingPathComponent("Contents/MacOS/Example")
        try fm.createDirectory(at: unsignedExe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: unsignedExe)
        guard try run("/usr/bin/codesign", ["--remove-signature", unsignedExe.path]) == 0 else {
            throw Problem("could not make an unsigned executable")
        }
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "local.bettericon.fix.complete-pdf", "CFBundleExecutable": "Example",
                "CFBundlePackageType": "APPL"], format: .xml, options: 0
        ).write(to: unsigned.appendingPathComponent("Contents/Info.plist"))
        func emptied(_ exe: URL, _ body: () -> Bool) throws -> Bool {
            let bytes = try Data(contentsOf: exe)
            let handle = try FileHandle(forWritingTo: exe)
            try handle.truncate(atOffset: 0)
            try handle.close()
            let answer = body()
            let back = try FileHandle(forWritingTo: exe)
            try back.write(contentsOf: bytes)
            try back.close()
            return answer
        }
        let wholeSigned = AppIcons.complete(signed), wholeUnsigned = AppIcons.complete(unsigned)
        let emptySigned = try emptied(signedExe) { AppIcons.complete(signed) }
        let emptyUnsigned = try emptied(unsignedExe) { AppIcons.complete(unsigned) }
        try check(
            wholeSigned && wholeUnsigned && !emptySigned && !emptyUnsigned && AppIcons.complete(signed),
            "a bundle still being copied, whose executable exists with no bytes yet, does not count as whole, signed or not")

        // A pass that should end, as when BetterIcon quits, looks at no further app, not even a new app's signature.
        let p = try scene(root, "10-stop")
        _ = try fixtureApp(p.all, "FilmCraft", id: "local.bettericon.fix.stop-film", icon: icon)
        try p.apply(pack)
        let copying = try fixtureApp(p.all, "GridCraft", id: "local.bettericon.fix.stop-grid", icon: icon)
        try fm.removeItem(at: copying.appendingPathComponent("Contents/Resources/Original.icns"))
        let adopt = Adoption(pack: pack.id, art: pack.icons, scopes: [.personal, .shared], roots: p.catalog.roots())
        let art = pack.icons.mapValues(\.path)
        let looked = try p.store.reconcile(p.apps(), appliedPack: pack.id, defaultPaths: [], appliedArt: art, adopt: adopt)
        let stopped = try p.store.reconcile(
            p.apps(), appliedPack: pack.id, defaultPaths: [], appliedArt: art, adopt: adopt, stop: { true })
        try check(
            looked.waiting == [path(copying)] && stopped.waiting.isEmpty && stopped.adopted.isEmpty && clean(copying),
            "a pass that should end, as when BetterIcon quits, looks at no further new app")
    }
    /// The first-start downloads after the review: an upgrade that never saved preferences, GitHub out of reach, progress
    /// where the offer was answered, a quit midway, news beside the progress, and the smallest Launcher.
    @MainActor static func offerFixChecks(resources: URL, root: URL) async throws {
        let icon = resources.appendingPathComponent("BetterIcon.icns")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let seed = try PublishedPacks(resources: resources, state: root.appendingPathComponent("size-cache")).list()
        let total = seed.filter { !$0.isDefault && !$0.personal }.count
        var hosts = [Application]()
        defer { retire(hosts) }
        /// The pack list the helper returns once these packs are downloaded.
        func marked(_ ids: [String]) -> [Pack] {
            seed.map { pack in
                var copy = pack
                if ids.contains(pack.id) { copy.status = "Downloaded" }
                return copy
            }
        }
        func paced(_ delay: TimeInterval, _ tally: Tally) -> (String) throws -> [Pack] {
            { id in
                Thread.sleep(forTimeInterval: delay)
                tally.add(id)
                return marked(tally.all)
            }
        }
        // An upgrade from a version that saved preferences only once something was changed: it left its lock file.
        let quiet = try emptyFixture(resources, root, "lock-only")
        try fm.createDirectory(at: quiet.state.appendingPathComponent("pack-cache"), withIntermediateDirectories: true)
        guard fm.createFile(atPath: quiet.state.appendingPathComponent("launcher.lock").path, contents: nil) else {
            throw Problem("could not create the lock file")
        }
        let quietHost = try startHost(quiet, acquire: { _ in throw Problem("no download expected") })
        hosts.append(quietHost)
        let quietReady = await settled(quietHost)
        let noOffer = await jsUntil(quietHost, "el('offer').hidden && model.downloadOffer === undefined", 5)
        try check(
            quietReady && noOffer && storedPrefs(quiet)?.offerPacks == nil,
            "an upgrade from a version that never saved preferences is not offered the downloads")
        retire([quietHost])
        // No connection to GitHub: the helper's own acquire, through a proxy on this Mac that refuses every connection, so
        // nothing leaves the Mac.
        let offline = try emptyFixture(resources, root, "offline")
        setenv("HTTPS_PROXY", "http://127.0.0.1:9", 1)
        setenv("https_proxy", "http://127.0.0.1:9", 1)
        let offHost = try startHost(offline)
        hosts.append(offHost)
        _ = await jsUntil(offHost, "!el('offer').hidden && !working")
        _ = await js(offHost, "el('offerDownload').click(); true")
        var line = ""
        let end = Date().addingTimeInterval(90)
        while Date() < end {
            line = await statusText(offHost)
            if line.contains("Couldn’t download") { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        unsetenv("HTTPS_PROXY")
        unsetenv("https_proxy")
        let banner = await js(offHost, "el('offerProgressText') ? el('offerProgressText').textContent : ''") as? String ?? ""
        try check(
            line.count < 250 && !line.lowercased().contains("http") && line.components(separatedBy: "reach GitHub").count == 2
                && banner == line && offHost.alertsShown == 0,
            "when GitHub cannot be reached, the downloads end at once with one short sentence that names no address")
        retire([offHost])
        // How failures read: the helper passes on Go's errors, which name whole addresses. The outcome groups packs by
        // cause, with up to three names for each.
        let request = DownloadFailure(
            Problem("Get \"https://raw.githubusercontent.com/o/r/f484f06a/Pack/GridCraft.png\": stream error: stream ID 3; INTERNAL_ERROR"))
        let status = DownloadFailure(Problem("Artwork service returned HTTP 404"))
        let checksum = DownloadFailure(Problem("Artwork checksum differs: Craft-Icons-Example/Pack/GridCraft.png"))
        let failed = (1...5).map { (title: "Pack \($0)", cause: status.cause) } + [(title: "Pack 6", cause: checksum.cause)]
        let outcome = DownloadFailure.summary(downloaded: 26, of: 32, failed: failed, unreachable: false)
        try check(
            request.unreachable && !status.unreachable && status.cause == "GitHub answered with HTTP 404"
                && !checksum.unreachable && checksum.cause == "its artwork didn’t match the published checksum"
                && outcome == "Downloaded 26 of 32 icon packs. Couldn’t download Pack 1, Pack 2, Pack 3 and 2 more: GitHub answered with HTTP 404. Couldn’t download Pack 6: its artwork didn’t match the published checksum. Choose a pack to try it again.",
            "a failed download is told in a few plain words by cause, with at most three pack names for each and no address")
        // Download on the Launcher tab; BetterIcon quits while the fourth pack downloads, then starts again.
        let resumed = try emptyFixture(resources, root, "resume")
        let gate = DispatchSemaphore(value: 0)
        let before = Tally(), after = Tally()
        let quitting: (String) throws -> [Pack] = { id in
            if before.all.count >= 3 {
                _ = gate.wait(timeout: .now() + 120)
                throw Problem("dial tcp: connection refused")
            }
            Thread.sleep(forTimeInterval: 0.3)
            before.add(id)
            return marked(before.all)
        }
        let first = try startHost(resumed, acquire: quitting)
        hosts.append(first)
        _ = await jsUntil(first, "!el('offer').hidden && !working")
        first.show()
        _ = await js(first, "el('offerDownload').click(); true")
        let progress = await jsUntil(first, """
            page === 'launcher' && !el('offerProgress').hidden && el('offerProgress').getClientRects().length > 0
              && el('offerProgressText').textContent.includes('Downloading icon pack')
            """, 10)
        let stuck = await waitUntil(20) { before.all.count == 3 }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let left = storedPrefs(resumed)?.pendingPacks ?? []
        let second = try startHost(resumed, acquire: paced(0.01, after))
        hosts.append(second)
        let finished = await statusUntil(second, "Downloaded \(total - 3) icon packs.", 60)
        try check(
            progress && stuck && left.count == total - 3 && finished && Set(after.all) == Set(left)
                && Set(after.all + before.all).count == total && storedPrefs(resumed)?.pendingPacks == nil,
            "the downloads show their progress on the tab where Download was chosen, and those a quit interrupted go on at the next start")
        retire([first, second])
        gate.signal()
        // A themed app, and an offer still open from an earlier start: the downloads' progress and other news share the
        // status line, and how the downloads ended stays until it is closed.
        let folder = root.appendingPathComponent("news")
        for name in ["Applications", "Shared"] {
            try fm.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let teal = try paint(root.appendingPathComponent("teal.png"), NSColor(srgbRed: 0.1, green: 0.6, blue: 0.6, alpha: 1))
        let film = try fixtureApp(folder.appendingPathComponent("Shared"), "FilmCraft", id: "local.bettericon.fix.news-film", icon: icon)
        let themed = try Installation(resources: resources, fixture: folder)
        let tealPack = Pack(id: "Checks/Teal", name: "Teal", author: "Checks", icons: ["FilmCraft": teal])
        let store = AppIcons(themed.state.appendingPathComponent("App Icons"))
        let found = themed.catalog.discover()
        let plan = store.review(apps: found, pack: tealPack, scope: nil, restore: false)
        let result = try store.perform(plan, apps: found, pack: tealPack)
        _ = try updatePreferences(themed.state) {
            $0.defaultPaths.subtract(result.changed)
            $0.noteApplied(plan, result, pack: tealPack)
            $0.offerPacks = true
        }
        let newsHost = try startHost(themed, acquire: paced(0.25, Tally()))
        hosts.append(newsHost)
        _ = await jsUntil(newsHost, "!el('offer').hidden && !working")
        _ = await js(newsHost, "el('offerDownload').click(); true")
        _ = await statusUntil(newsHost, "Downloading icon pack", 10)
        try launcherUpdate(film, with: release(folder, "FilmCraft", id: "local.bettericon.fix.news-film", icon: icon, version: "2"))
        let both = await statusHolds(newsHost, ["Put your icon back on FilmCraft", "Downloading icon pack"], 20)
        let ended = await statusUntil(newsHost, "Downloaded \(total) icon packs.", 60)
        try launcherUpdate(film, with: release(folder, "FilmCraft", id: "local.bettericon.fix.news-film", icon: icon, version: "3"))
        let kept = await statusHolds(newsHost, ["Put your icon back on FilmCraft", "Downloaded \(total) icon packs."], 20)
        _ = await js(newsHost, "el('offerClose').click(); true")
        let closed = await jsUntil(newsHost, "el('offer').hidden && !el('status').textContent.includes('Downloaded')", 10)
        try check(
            both && ended && kept && closed && newsHost.alertsShown == 0,
            "the downloads' progress and other news share the status line, and how the downloads ended stays until it is closed")
        retire([newsHost])
        // The offer at the Launcher's smallest size, with an app to launch.
        let small = try emptyFixture(resources, root, "small-launcher")
        _ = try fixtureApp(
            root.appendingPathComponent("small-launcher/Shared"), "FilmCraft", id: "local.bettericon.fix.small-film", icon: icon)
        let smallHost = try startHost(small, acquire: { _ in throw Problem("no download expected") })
        hosts.append(smallHost)
        _ = await jsUntil(smallHost, "!el('offer').hidden && model.apps.length === 1 && !working")
        smallHost.show()
        smallHost.window.setFrame(NSRect(origin: smallHost.window.frame.origin, size: PopupTab.launcher.minimum), display: true)
        let fits = await jsUntil(smallHost, """
            (() => {
              if (innerWidth !== 300 || innerHeight !== 240 || page !== 'launcher' || el('offer').hidden) return false;
              const tile = el('apps').querySelector('.tile'), grid = el('apps').getBoundingClientRect();
              if (!tile) return false;
              const r = tile.getBoundingClientRect();
              return r.height > 0 && r.top >= grid.top - 0.5 && r.bottom <= grid.bottom + 0.5 && r.bottom <= innerHeight;
            })()
            """, 10)
        let choose = await drawn(smallHost, "offerChoose")
        try check(
            fits && choose,
            "at the Launcher's smallest size the offer takes one line and the first row of apps stays in view")
    }
    // MARK: WebP pack artwork, and art for the file types outside BetterIcon's list

    /// The WebP fixtures of the spec (webp-spec.md, Appendix A). All are synthetic. A16 is a 16 pixel blue PNG.
    static let webpFixtures: [String: String] = [
        "A1": "UklGRoYAAABXRUJQVlA4WAoAAAAQAAAAHwAAHwAAQUxQSBQAAAABUNq2AZP/nw4sHCwiJoAZGv+td1ZQOCBMAAAA0AMAnQEqIAAgAADAEiWgAgAvwH4AfsB/gDK+UsIF+KQ22wf7OtcAAP7+ex//8gr//H8n//jjOf//azf//7eqPCwi1MICOKos6fgAAA==",
        "A2": "UklGRioAAABXRUJQVlA4TB0AAAAvH8AHEA8wPMM9KPMf8BDTEPqXdpsCEf2fAHq95QA=",
        "A3": "UklGRogAAABXRUJQVlA4WAoAAAACAAAADwAADwAAQU5JTQYAAAAAAAAAAABBTk1GKgAAAAAAAAAAAA8AAA8AAGQAAAJWUDhMEQAAAC8PwAMAB1Cechel/4GI6H8AAEFOTUYqAAAAAAAAAAAADwAADwAAZAAAAFZQOEwRAAAALw/AAwAHUK2ilLv/gYjofwAA",
        "A4": "UklGRiwAAABXRUJQVlA4TB8AAAAvD8ADECDStpl/00eF5/M//wKCwnTPm4DCiH/GTPwDAA==",
        "A5": "UklGRnQAAABXRUJQVlA4WAoAAAAQAAAADwAADwAAQUxQSBMAAAABINK2ufQ7Hxocj4gJQKc9V7QHAFZQOCA6AAAAcAEAnQEqEAAQAADAEiWgAnQBiEAA/vwu///q+H/8SS//7t1//3nrn/+6iv/q6L/+rnX//5Yh3wAAAA==",
        "A6": "UklGRkAAAABXRUJQVlA4IDQAAAAwAgCdASoQABAAAMASJaACdLoB+AH4AARoAAD++iGX/3easNN39a3/9aOfron+tHP/WVgA",
        "A7": "UklGRlIAAABXRUJQVlA4WAoAAAASAAAAAAAAAAAAQU5JTQYAAAD/////AABBTk1GJgAAAAAAAAAAAAAAAAAAAGQAAABWUDhMDQAAAC8AAAAQBxAREYiI/gcA",
        "A8": "UklGRiwAAABXRUJQVlA4TB8AAAAvD8ADECDStpl/00eF5w==",
        "A9": "UklGRiwAAABXRUJQ",
        "A10": "iVBORw0KGgoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "A11": "UklGRhgAAABXRUJQVlA4TAwAAAAvh9MAAChAAfrf/wA=",
        "A12": "UklGRioAAABXRUJQVlA4TB0AAAAvH8AHEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "A13": "UklGRhgAAABXRUJQVlA4TAwAAAAvH8AHAChAAfrf/wA=",
        "A14": "UklGRhgAAABXRUJQVlA4TAwAAAAvH8AHEOh/AQpQwAA=",
        "A15": "UklGRnwAAABXRUJQVlA4WAoAAAASAAAAHwAAHwAAQU5JTQYAAAAAAAAAAABBTk1GJAAAAAAAAAAAAB8AAB8AAGQAAABWUDhMDAAAAC8fwAcAKEAB+t//AEFOTUYkAAAAAAAAAAAAHwAAHwAAZAAAAFZQOEwMAAAALx/ABwAoQP8L0P8A",
        "A16": "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAHUlEQVR42mNkYPj/n4ECwMRAIRg1YNSAUQMGiwEAVm8CHr3k3X0AAAAASUVORK5CYII=",
    ]
    static func webp(_ id: String) -> Data { Data(base64Encoded: webpFixtures[id] ?? "") ?? Data() }
    /// Files under a folder, by path inside it.
    @discardableResult static func folder(_ dir: URL, _ files: [String: Data]) throws -> URL {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (path, data) in files {
            let url = dir.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return dir
    }
    static func contents(_ file: URL?) -> Data? { file.flatMap { try? Data(contentsOf: $0) } }
    /// The spec's 32 pixel test square kept as PNG: transparent edges around an opaque red centre.
    static func isSquare(_ file: URL?) -> Bool {
        guard let file, file.pathExtension == "png", let data = try? Data(contentsOf: file),
            let pixels = NSBitmapImageRep(data: data), pixels.pixelsWide == 32, pixels.pixelsHigh == 32,
            let corner = pixels.colorAt(x: 1, y: 1), let center = pixels.colorAt(x: 16, y: 16)
        else { return false }
        return corner.alphaComponent == 0 && center.alphaComponent == 1 && center.redComponent > 0.75
            && center.greenComponent < 0.4
    }
    /// The message of the error an action throws, or "" when it throws none.
    static func failure(_ action: () throws -> Void) -> String {
        do { try action() } catch { return error.localizedDescription }
        return ""
    }
    /// What a tool prints.
    static func output(_ exe: String, _ arguments: [String], in dir: URL? = nil) throws -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = arguments
        p.currentDirectoryURL = dir
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
    /// The names in a ZIP, sorted.
    static func zipNames(_ zip: URL) throws -> [String] {
        try output("/usr/bin/unzip", ["-Z1", zip.path]).split(separator: "\n").map(String.init).sorted()
    }
    static func marked(_ file: URL) -> Bool { (try? attribute(FolderIcons.marker, file)) != nil }
    static func markedUnlisted(_ file: URL) -> Bool { (try? attribute(FolderIcons.unlistedMarker, file)) != nil }
    /// Give a file another app the way Get Info's Open with does, or take that choice away with nil.
    static func openWith(_ file: URL, _ app: URL?, id: String = "") throws {
        guard let app else { return try putAttribute(FileOpeners.openWith, nil, file) }
        let plist: [String: Any] = ["version": 0, "path": app.path, "bundleidentifier": id]
        try putAttribute(
            FileOpeners.openWith, PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0), file)
    }

    /// WebP pack artwork: the byte rule, personal imports and exports, published packs through the helper's list, app
    /// icons and folder icons. No network.
    static func webpChecks(resources: URL, root: URL) throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let icon = resources.appendingPathComponent("BetterIcon.icns")
        let state = root.appendingPathComponent("State")
        let published = try PublishedPacks(resources: resources, state: state)
        let formats = published.formats
        let lib = try PackLibrary(state.appendingPathComponent("Packs"))
        lib.formats = formats
        let blue = try paint(root.appendingPathComponent("blue.png"), NSColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1))
        let bluePNG = try Data(contentsOf: blue)
        func imported(_ source: URL) throws -> Pack {
            let id = try lib.importPack(source)
            guard let pack = lib.visible([]).first(where: { $0.id == id }) else { throw Problem("the imported pack is missing") }
            return pack
        }
        let usable = ["A1", "A2", "A4", "A5", "A6", "A12", "A13", "A14"]
        let refused = [
            "A3": Artwork.webpAnimated, "A7": Artwork.webpAnimated, "A15": Artwork.webpAnimated, "A8": Artwork.webpDamaged,
            "A9": Artwork.webpDamaged, "A10": Artwork.webpMislabeled, "A11": Artwork.webpOversized,
        ]
        try check(
            usable.allSatisfy { Artwork.webpProblem(webp($0), length: webp($0).count) == nil }
                && refused.allSatisfy { Artwork.webpProblem(webp($0.key), length: webp($0.key).count) == $0.value },
            "the WebP byte rule passes the usable fixtures and gives each refused one its cause")
        let a12 = try folder(root.appendingPathComponent("A12"), ["damaged.webp": webp("A12")]).appendingPathComponent("damaged.webp")
        try check(
            Artwork.problem(a12) == nil && (try? Artwork.validate(webp("A12"), ext: "webp")) != nil,
            "on the Mac a WebP damaged behind a valid header is not detected: ImageIO reads fixture A12 without an error")
        let damagedTwin = try imported(folder(
            root.appendingPathComponent("Damaged twin"), ["PhotoCraft.webp": webp("A8"), "PhotoCraft.png": bluePNG]))
        try check(contents(damagedTwin.icons["PhotoCraft"]) == bluePNG, "A damaged WebP gives way to the PNG of the same icon")
        let alone = failure { _ = try lib.importPack(folder(root.appendingPathComponent("Damaged alone"), ["PhotoCraft.webp": webp("A8")])) }
        try check(alone.hasPrefix("PhotoCraft: The WebP file is damaged or incomplete."), "A damaged WebP alone is refused")
        let animated = failure { _ = try lib.importPack(folder(root.appendingPathComponent("Animated"), ["PhotoCraft.webp": webp("A15")])) }
        let oneFrame = failure { _ = try lib.importPack(folder(root.appendingPathComponent("One frame"), ["FilmCraft.webp": webp("A7")])) }
        let chosen = failure { _ = try Artwork.validate(webp("A7"), ext: "webp") }
        let animatedTwin = try imported(folder(
            root.appendingPathComponent("Animated twin"), ["PhotoCraft.webp": webp("A15"), "PhotoCraft.png": bluePNG]))
        try check(
            animated == "PhotoCraft: Animated WebP artwork is not supported. Choose a still image."
                && oneFrame == "FilmCraft: Animated WebP artwork is not supported. Choose a still image."
                && chosen == "Animated WebP artwork is not supported. Choose a still image."
                && contents(animatedTwin.icons["PhotoCraft"]) == bluePNG,
            "Animated WebP is refused, including a one-frame animation")
        try rejects("Two WebP files for one icon are refused") {
            _ = try lib.importPack(folder(
                root.appendingPathComponent("Two WebP"), ["PhotoCraft.webp": webp("A2"), "PhotoCraft-copy.webp": webp("A13")]))
        }
        let wide = try imported(folder(
            root.appendingPathComponent("App-wide WebP"), ["FileTypes/PhotoCraft-PSD.webp": webp("A2"), "FileTypes/pcraft.png": bluePNG]))
        try check(
            Set(wide.documents.keys) == [".pcraft", ".psd", ".png"] && isSquare(wide.documents[".psd"])
                && isSquare(wide.documents[".png"]) && contents(wide.documents[".pcraft"]) == bluePNG && wide.unlisted.isEmpty,
            "App-wide WebP file art expands to each format")
        let zipSource = try folder(
            root.appendingPathComponent("ZIP source"), ["PhotoCraft.webp": webp("A1"), "FileTypes/pcraft.webp": webp("A2")])
        let zip = root.appendingPathComponent("WebP pack.zip")
        guard try run("/bin/sh", ["-c", "cd \"$0\" && /usr/bin/zip -q -X -D -r \"$1\" PhotoCraft.webp FileTypes", zipSource.path, zip.path]) == 0
        else { throw Problem("zip could not build the WebP pack") }
        let zipped = try imported(zip)
        let exported = root.appendingPathComponent("WebP export.zip")
        try lib.export(zipped, to: exported)
        let names = try zipNames(exported)
        try check(
            isSquare(zipped.icons["PhotoCraft"]) && isSquare(zipped.documents[".pcraft"])
                && names == ["FileTypes/pcraft.png", "PhotoCraft.png", "bettericon-pack.json"],
            "A ZIP with WebP imports and exports PNG only")
        let oversized = failure { _ = try lib.importPack(folder(root.appendingPathComponent("Oversized"), ["PhotoCraft.webp": webp("A11")])) }
        try check(
            oversized == "PhotoCraft: WebP artwork must be at most 4096 pixels per side."
                && failure({ _ = try Artwork.validate(webp("A11"), ext: "webp") }) == Artwork.webpOversized,
            "Oversized WebP is refused")
        try check(
            Artwork.formats == ["svg", "ico", "webp", "png", "icns"]
                && Artwork.formats.allSatisfy { UTType(filenameExtension: $0) != nil },
            "Every accepted format has a type for the file panel")
        // A published pack, as the helper lists it: each item's files best first, with Fallbacks for the other formats.
        let pub = root.appendingPathComponent("Published")
        let solid = try folder(pub, [
            "PhotoCraft.webp": webp("A13"), "PhotoCraft.png": bluePNG, "FilmCraft.webp": webp("A8"), "FilmCraft.png": bluePNG,
            "GridCraft.webp": webp("A15"), "FileTypes/pcraft.webp": webp("A10"), "Strip/PhotoCraft.webp": webp("A13"),
        ])
        func path(_ name: String) -> String { solid.appendingPathComponent(name).path }
        func entry(_ icons: [String: String], files: [String: String] = [:], fallbacks: [String: [String]] = [:]) -> [String: Any] {
            [
                "ID": "Craft-Icons-Checks/WebP", "Name": "WebP", "Author": "Checks", "Status": "Downloaded", "Icons": icons,
                "FileIcons": files, "AppFileIcons": [String: String](), "CanApps": true, "CanFiles": !files.isEmpty,
                "HasPreview": false, "HasFilePreview": false, "Fallbacks": fallbacks,
            ]
        }
        let listed = try PublishedPacks.packs(from: JSONSerialization.data(withJSONObject: [entry(
            ["PhotoCraft": path("PhotoCraft.webp"), "FilmCraft": path("FilmCraft.webp"), "GridCraft": path("GridCraft.webp")],
            files: [".pcraft": path("FileTypes/pcraft.webp")],
            fallbacks: [path("PhotoCraft.webp"): [path("PhotoCraft.png")], path("FilmCraft.webp"): [path("FilmCraft.png")]])]))
        guard let pack = listed.first else { throw Problem("the published pack is missing") }
        try check(pack.icons["PhotoCraft"]?.path == path("PhotoCraft.webp"), "WebP wins over PNG in a published pack")
        try check(
            pack.icons["FilmCraft"]?.path == path("FilmCraft.png") && pack.leftOut["FilmCraft"] == nil,
            "A damaged WebP in a published pack gives way to its PNG")
        try check(
            pack.icons["GridCraft"] == nil && pack.leftOut["GridCraft"] == Artwork.webpAnimated && pack.documents.isEmpty
                && pack.leftOut[".pcraft"] == Artwork.webpMislabeled
                && pack.leftOutNote(files: false, formats: formats) == "Left out: GridCraft. Animated WebP artwork is not supported."
                && pack.leftOutNote(files: true, formats: formats) == "Left out: .pcraft. The file is named .webp but is not a WebP image.",
            "A WebP-only item that cannot be used is left out with its reason")
        let many = try PublishedPacks.packs(from: JSONSerialization.data(withJSONObject: [entry(
            ["VectorCraft": path("GridCraft.webp"), "ArtCraftLauncher": path("FilmCraft.webp"), "CADCraft": path("GridCraft.webp"),
             "FilmCraft": path("GridCraft.webp")])]))
        try check(
            many.first?.leftOutNote(files: false, formats: formats)
                == "Left out: ArtCraft Launcher, CADCraft, FilmCraft and 1 more. The WebP file is damaged or incomplete.",
            "the status line names at most three left-out items in the order the list draws them, with the first one's reason")
        let twins = try PublishedPacks.packs(from: JSONSerialization.data(withJSONObject: [entry(
            ["PhotoCraft": path("PhotoCraft.webp")], fallbacks: [path("PhotoCraft.webp"): [path("PhotoCraft.png")]])]))
        try check(twins.first?.icons.count == 1 && pack.icons.count == 2, "Twins do not raise the icon count")
        // Real downloads through the helper from a local pack source. macOS reads WebP, so a download fetches an icon's
        // WebP twin alone; a WebP twin the Mac can't read brings its PNG twin, fetched then.
        let twinRoot = root.appendingPathComponent("Twin downloads")
        let twinResources = twinRoot.appendingPathComponent("Resources")
        try fm.createDirectory(at: twinResources.appendingPathComponent("Catalog"), withIntermediateDirectories: true)
        try fm.createDirectory(at: twinRoot.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: twinRoot.appendingPathComponent("Helpers/packstore"),
            withDestinationURL: resources.deletingLastPathComponent().appendingPathComponent("Helpers/packstore"))
        for name in ["ProjectFileTypes.json", "previews.tsv"] {
            try fm.copyItem(
                at: resources.appendingPathComponent("Catalog/" + name), to: twinResources.appendingPathComponent("Catalog/" + name))
        }
        let twinFiles = [
            "Craft-Icons-Checks/Light/PhotoCraft.webp": webp("A13"), "Craft-Icons-Checks/Light/PhotoCraft.png": bluePNG,
            "Craft-Icons-Checks/Unreadable/PhotoCraft.webp": bluePNG, "Craft-Icons-Checks/Unreadable/PhotoCraft.png": bluePNG,
        ]
        let twinSource = try folder(twinRoot.appendingPathComponent("Source"), twinFiles)
        func blob(_ data: Data) -> String {
            Insecure.SHA1.hash(data: Data("blob \(data.count)\0".utf8) + data).map { String(format: "%02x", $0) }.joined()
        }
        let twinRows = twinFiles.keys.sorted().map { "\(blob(twinFiles[$0]!))\t\($0)\t\($0)\t\(digest(twinFiles[$0]!))" }
        try Data(([String(repeating: "1", count: 40)] + twinRows).joined(separator: "\n").utf8)
            .write(to: twinResources.appendingPathComponent("Catalog/packs.tsv"))
        setenv("BETTERICON_PACK_SOURCE", twinSource.path, 1)
        defer { unsetenv("BETTERICON_PACK_SOURCE") }
        let twinState = twinRoot.appendingPathComponent("State")
        let downloads = try PublishedPacks(resources: twinResources, state: twinState)
        func fetched(_ name: String) -> [String] {
            let all = fm.enumerator(at: twinState.appendingPathComponent("pack-cache/downloads"), includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL } ?? []
            return all.filter { $0.path.contains("/Craft-Icons-Checks/\(name)/") }.map(\.lastPathComponent).sorted()
        }
        let light = try downloads.list("acquire", id: "Craft-Icons-Checks/Light").first { $0.id == "Craft-Icons-Checks/Light" }
        let afterUnreadable = try downloads.list("acquire", id: "Craft-Icons-Checks/Unreadable")
        let unreadable = afterUnreadable.first { $0.id == "Craft-Icons-Checks/Unreadable" }
        let lightAfter = afterUnreadable.first { $0.id == "Craft-Icons-Checks/Light" }
        unsetenv("BETTERICON_PACK_SOURCE")
        try check(
            fetched("Light") == ["PhotoCraft.webp"] && light?.icons["PhotoCraft"]?.pathExtension == "webp"
                && fetched("Unreadable") == ["PhotoCraft.png", "PhotoCraft.webp"]
                && unreadable?.icons["PhotoCraft"]?.pathExtension == "png" && unreadable?.leftOut.isEmpty == true,
            "a download fetches an icon's WebP twin alone, and its PNG twin too when the Mac can't read the WebP")
        try check(
            light?.status == "Downloaded" && lightAfter?.status == "Downloaded" && lightAfter?.icons["PhotoCraft"]?.pathExtension == "webp",
            "after one pack's PNG files were fetched for a WebP the Mac can't read, a pack downloaded as WebP alone still counts as downloaded")
        let stripPack = try PublishedPacks.packs(from: JSONSerialization.data(withJSONObject: [entry(["PhotoCraft": path("Strip/PhotoCraft.webp")])]))
        let strip = try stripPack.first.flatMap { try published.preview($0) }
        let tile = strip.flatMap { NSBitmapImageRep(data: (try? Data(contentsOf: $0)) ?? Data()) }?.colorAt(x: 32, y: 32)?
            .usingColorSpace(.sRGB)
        try check(
            (tile?.blueComponent ?? 0) > 0.6 && (tile?.redComponent ?? 1) < 0.3 && (tile?.alphaComponent ?? 0) > 0.9,
            "The local strip draws WebP artwork")
        // An app icon from WebP art: applied, kept privately as <hash>.webp, and put back after an update.
        let s = try scene(root, "WebP app icon")
        let photo = try fixtureApp(s.user, "PhotoCraft", id: "local.bettericon.webp.photo", icon: icon)
        let version2 = try release(s.root, "PhotoCraft", id: "local.bettericon.webp.photo", icon: icon, version: "2")
        let original = try systemImage(photo)
        let art = solid.appendingPathComponent("Strip/PhotoCraft.webp")
        let webpPack = Pack(id: "Checks/WebP", name: "WebP", author: "Checks", icons: ["PhotoCraft": art])
        try s.apply(webpPack)
        let hash = digest(webp("A13"))
        let applied = eventually { try distance(systemImage(photo), original) > 0.05 }
        let photoPath = try s.path("PhotoCraft")
        let keptCopy = fm.fileExists(atPath: s.state.appendingPathComponent("artwork/\(hash).webp").path)
            && record(s.state, photoPath)?["art"] as? String == hash
        let apps = s.apps()
        try launcherUpdate(photo, with: version2)
        let dropped = clean(photo)
        let back = try s.store.reconcile(apps, appliedPack: webpPack.id, defaultPaths: [], appliedArt: nil)
        try check(
            applied && keptCopy && dropped && back.restored.count == 1 && back.errors.isEmpty
                && eventually { try distance(systemImage(photo), original) > 0.05 },
            "A WebP app icon applies, is kept as <hash>.webp and comes back after an update")
        let projects = try folder(root.appendingPathComponent("WebP folder"), ["a.pcraft": Data("project".utf8)])
        let fileA = projects.appendingPathComponent("a.pcraft")
        let plainFile = try systemImage(fileA)
        let engine = FolderIcons(formats: formats)
        let first = engine.apply(projects, art: [".pcraft": art]), second = engine.apply(projects, art: [".pcraft": art])
        try check(
            first.changed == 1 && first.errors.isEmpty && second.changed == 0 && second.current == 1 && marked(fileA)
                && eventually { try distance(systemImage(fileA), plainFile) > 0.05 },
            "Folder icons apply from WebP art and stay current")
    }
    /// The artwork scheme serves WebP artwork to a page, which WebKit decodes.
    @MainActor static func webpPage(root: URL) async throws {
        let art = try folder(root, ["page.webp": webp("A13")]).appendingPathComponent("page.webp")
        let scheme = ArtScheme()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(scheme, forURLScheme: "bettericon-art")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
        web.loadHTMLString("<img id='art' src='\(scheme.link(art))'>", baseURL: nil)
        var width = 0
        for _ in 0..<100 where width != 32 {
            try await Task.sleep(nanoseconds: 100_000_000)
            width = (try? await web.evaluateJavaScript("document.getElementById('art')?.naturalWidth ?? 0")) as? Int ?? 0
        }
        try check(width == 32, "The artwork scheme serves WebP to the page")
    }

    /// Art for the file types outside BetterIcon's list, through stand-ins for Launch Services: which app opens a file, and
    /// which ArtCraft app an app is. No network, and nothing is registered with Launch Services.
    @MainActor static func unlistedChecks(resources: URL, root: URL) async throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let state = root.appendingPathComponent("State")
        let published = try PublishedPacks(resources: resources, state: state)
        let formats = published.formats
        let lib = try PackLibrary(state.appendingPathComponent("Packs"))
        lib.formats = formats
        let orange = try paint(root.appendingPathComponent("orange.png"), NSColor(srgbRed: 0.95, green: 0.45, blue: 0.1, alpha: 1))
        let teal = try paint(root.appendingPathComponent("teal.png"), NSColor(srgbRed: 0.1, green: 0.6, blue: 0.6, alpha: 1))
        let plum = try paint(root.appendingPathComponent("plum.png"), NSColor(srgbRed: 0.5, green: 0.1, blue: 0.5, alpha: 1))
        let orangePNG = try Data(contentsOf: orange), tealPNG = try Data(contentsOf: teal), plumPNG = try Data(contentsOf: plum)
        func imported(_ source: URL, into library: PackLibrary? = nil) throws -> Pack {
            let library = library ?? lib
            let id = try library.importPack(source)
            guard let pack = library.visible([]).first(where: { $0.id == id }) else { throw Problem("the imported pack is missing") }
            return pack
        }
        // Stand-ins for Launch Services. The .xyzp files open with an app called PhotoCraft here, .xyzw files with one called
        // WordCraft, and .xyzo files with another app.
        let table = OpenerTable()
        let photoApp = URL(fileURLWithPath: "/Checks/Photo Opener.app"), wordApp = URL(fileURLWithPath: "/Checks/Word Opener.app")
        let otherApp = URL(fileURLWithPath: "/Checks/Other Opener.app")
        table.open("xyzp", with: photoApp)
        table.open("xyzw", with: wordApp)
        table.open("xyzo", with: otherApp)
        table.name(photoApp, "PhotoCraft")
        table.name(wordApp, "WordCraft")
        let savedLookup = FileOpeners.lookup, savedIdentify = FileOpeners.identify
        defer {
            FileOpeners.lookup = savedLookup
            FileOpeners.identify = savedIdentify
        }
        FileOpeners.lookup = { table.opener($0) }
        FileOpeners.identify = { table.craft($0) }
        func reopen(_ file: URL, _ app: URL?) throws {
            table.open(file, with: app)
            try openWith(file, app)
        }
        let named = [
            "PhotoCraft-files", "PhotoCraft files", "photocraft_FILES", "PhotoCraft.files", "ArtCraft Launcher-files",
            "ArtCraft_Launcher files", "ArtCraftLauncher-files", "Craft-Anything.files", "CraftAnything_files",
        ]
        let apps = [
            "PhotoCraft", "PhotoCraft", "PhotoCraft", "PhotoCraft", "ArtCraftLauncher", "ArtCraftLauncher", "ArtCraftLauncher",
            "CraftAnything", "CraftAnything",
        ]
        let unnamed = [
            "PhotoCraft-PSD", "PhotoCraft - files", "PhotoCraft\u{00A0}files", "PhotoCraft--files", "PhotoCraftfiles",
            "PhotoCraft-files-2", "PhotoCraft\tfiles", "My PhotoCraft-files", "PhotoCraft",
        ]
        try check(
            named.map(Craft.allFilesApp) == apps.map(Optional.some) && unnamed.allSatisfy { Craft.allFilesApp($0) == nil },
            "only art named FileTypes/<App>-files opts an app in to unlisted file types, by the pack helper's names with a literal ASCII space")
        // Personal packs.
        let explicitDir = try folder(
            root.appendingPathComponent("Explicit"), ["FileTypes/PhotoCraft-files.png": orangePNG, "FileTypes/pcraft.png": tealPNG])
        let explicit = try imported(explicitDir)
        try check(
            explicit.unlisted.keys.sorted() == ["PhotoCraft"] && contents(explicit.unlisted["PhotoCraft"]) == orangePNG
                && contents(explicit.documents[".psd"]) == orangePNG && contents(explicit.documents[".png"]) == orangePNG
                && contents(explicit.documents[".pcraft"]) == tealPNG && explicit.canFiles && !explicit.canApps,
            "a personal pack keeps art named FileTypes/<App>-files as that app's art for unlisted file types, besides its listed formats without art of their own")
        let labelled = try imported(folder(root.appendingPathComponent("Format-labelled"), ["FileTypes/PhotoCraft-PSD.png": orangePNG]))
        let mixed = try imported(folder(
            root.appendingPathComponent("Mixed"),
            ["FileTypes/PhotoCraft-files.webp": webp("A2"), "FileTypes/PhotoCraft-PSD.png": orangePNG]))
        let other = try imported(folder(root.appendingPathComponent("Other app"), ["FileTypes/WordCraft-files.png": plumPNG]))
        try check(
            labelled.unlisted.isEmpty && contents(labelled.documents[".psd"]) == orangePNG && mixed.unlisted.isEmpty
                && isSquare(mixed.documents[".psd"]) && other.unlisted.keys.sorted() == ["WordCraft"],
            "art named for a format, as in Mike22's packs, or mixed with art named FileTypes/<App>-files, does not opt a personal pack in")
        let twins = try imported(folder(
            root.appendingPathComponent("Explicit twins"),
            ["FileTypes/PhotoCraft-files.webp": webp("A2"), "FileTypes/PhotoCraft_files.png": orangePNG]))
        try check(
            twins.unlisted.keys.sorted() == ["PhotoCraft"] && isSquare(twins.unlisted["PhotoCraft"]),
            "twins that are all named FileTypes/<App>-files opt in together, with the WebP preferred and kept as PNG")
        let light = try? imported(folder(root.appendingPathComponent("No listed formats"), ["FileTypes/LightCraft-files.png": plumPNG]))
        try check(
            light.map { $0.canFiles && !$0.canApps && $0.documents.isEmpty && $0.unlisted["LightCraft"] != nil } == true
                && light.flatMap(published.fileSummary) == "Other LightCraft files"
                && published.fileSummary(explicit) == "3 file types, plus other PhotoCraft files" && published.fileSummary(labelled) == nil,
            "art for all of an app's files makes a file type pack even for an app without listed formats, and Manage Icons names the other files a pack draws")
        // Edit, export and reimport keep the opt-in. Clearing the art opts out.
        var edit = published.storedFiles(explicit)
        edit[".pcraft"] = plum
        let editedID = try lib.store(name: explicit.name, author: explicit.author, files: edit, editing: explicit)
        guard let edited = lib.visible([]).first(where: { $0.id == editedID }) else { throw Problem("the edited pack is missing") }
        try check(
            editedID == explicit.id && contents(edited.unlisted["PhotoCraft"]) == orangePNG
                && contents(edited.documents[".pcraft"]) == plumPNG && edit["*PhotoCraft"] != nil,
            "editing a personal pack keeps its art for unlisted file types")
        let exportedZip = root.appendingPathComponent("Explicit export.zip")
        try lib.export(edited, to: exportedZip)
        let exportedNames = try zipNames(exportedZip)
        try lib.remove(edited)
        let reimported = try imported(exportedZip)
        try check(
            exportedNames.contains("FileTypes/PhotoCraft-files.png") && exportedNames.contains("FileTypes/psd.png")
                && contents(reimported.unlisted["PhotoCraft"]) == orangePNG && contents(reimported.documents[".pcraft"]) == plumPNG,
            "export writes the art for unlisted file types as FileTypes/<App>-files.png, and a reimport opts the pack in again")
        var cleared = published.storedFiles(reimported)
        cleared["*PhotoCraft"] = nil
        let clearedID = try lib.store(name: reimported.name, author: reimported.author, files: cleared, editing: reimported)
        let afterClear = lib.visible([]).first { $0.id == clearedID }
        try check(
            afterClear?.unlisted.isEmpty == true && afterClear?.documents[".psd"] != nil,
            "clearing that art in the editor opts the personal pack out")
        // A pack stored by an earlier version: library.json without the key.
        let earlierRoot = root.appendingPathComponent("Earlier/Packs")
        let earlierLib = try PackLibrary(earlierRoot)
        earlierLib.formats = formats
        let earlierID = try earlierLib.importPack(explicitDir)
        let index = earlierRoot.appendingPathComponent("library.json")
        guard var json = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any],
            var personal = json["personal"] as? [[String: Any]]
        else { throw Problem("unreadable library.json") }
        let hadKey = personal.contains { $0["unlisted"] != nil }
        personal = personal.map { var p = $0; p["unlisted"] = nil; return p }
        json["personal"] = personal
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: index, options: .atomic)
        let reloaded = try PackLibrary(earlierRoot)
        reloaded.formats = formats
        let earlier = reloaded.visible([]).first { $0.id == earlierID }
        let quiet = try PackLibrary(root.appendingPathComponent("Quiet/Packs"))
        quiet.formats = formats
        _ = try quiet.importPack(root.appendingPathComponent("Format-labelled"))
        let quietIndex = try String(contentsOf: root.appendingPathComponent("Quiet/Packs/library.json"), encoding: .utf8)
        try check(
            hadKey && earlier?.unlisted.isEmpty == true && earlier?.documents.count == 3 && !quietIndex.contains("unlisted"),
            "a pack stored by an earlier version never starts drawing unlisted file types, and a pack without such art stores what earlier versions store")
        // Published packs, as the helper lists them.
        let pub = try folder(root.appendingPathComponent("Published"), [
            "FileTypes/PhotoCraft-files.png": orangePNG, "Damaged/PhotoCraft-files.webp": webp("A8"),
            "Damaged/PhotoCraft-files.png": tealPNG, "Mike22/FileTypes/PhotoCraft-files.png": plumPNG,
        ])
        func pubEntry(_ id: String, _ status: String, appFiles: [String: String], unlisted: [String]?, fallbacks: [String: [String]] = [:])
            -> [String: Any]
        {
            var entry: [String: Any] = [
                "ID": id, "Name": id, "Author": "Checks", "Status": status, "Icons": [String: String](),
                "FileIcons": [String: String](), "AppFileIcons": appFiles, "CanApps": false, "CanFiles": true,
                "HasPreview": false, "HasFilePreview": false, "Fallbacks": fallbacks,
            ]
            if let unlisted { entry["UnlistedFileIconApps"] = unlisted }
            return entry
        }
        let file = { (name: String) in pub.appendingPathComponent(name).path }
        let listedPacks = try PublishedPacks.packs(from: JSONSerialization.data(withJSONObject: [
            pubEntry("Checks/Explicit", "Downloaded", appFiles: ["PhotoCraft": file("FileTypes/PhotoCraft-files.png")], unlisted: ["PhotoCraft"]),
            pubEntry("Checks/Not here", "Download", appFiles: [:], unlisted: ["PhotoCraft"]),
            pubEntry(
                "Checks/Damaged", "Downloaded", appFiles: ["PhotoCraft": file("Damaged/PhotoCraft-files.webp")], unlisted: ["PhotoCraft"],
                fallbacks: [file("Damaged/PhotoCraft-files.webp"): [file("Damaged/PhotoCraft-files.png")]]),
            pubEntry("Checks/Labelled", "Downloaded", appFiles: ["PhotoCraft": file("Mike22/FileTypes/PhotoCraft-files.png")], unlisted: nil),
        ]))
        let byID = Dictionary(listedPacks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        try check(
            byID["Checks/Explicit"]?.unlisted["PhotoCraft"]?.path == file("FileTypes/PhotoCraft-files.png")
                && byID["Checks/Not here"]?.unlisted.isEmpty == true
                && byID["Checks/Damaged"]?.unlisted["PhotoCraft"]?.path == file("Damaged/PhotoCraft-files.png")
                && byID["Checks/Labelled"]?.unlisted.isEmpty == true
                && byID["Checks/Labelled"].map({ published.fileArt($0).count }) == 3,
            "a published pack's art draws unlisted file types only for the apps the helper lists, only with that art on this Mac, resolved like any other art")
        // A folder pass.
        let engine = FolderIcons(formats: formats)
        let dir = try folder(root.appendingPathComponent("Unlisted folder"), [
            "a.xyzp": Data("a".utf8), "own.xyzp": Data("own".utf8), "b.xyzw": Data("b".utf8), "c.xyzo": Data("c".utf8),
            "d.xyzp": Data("d".utf8), "e.psd": Data("e".utf8), "f.pcraft": Data("f".utf8), "g": Data("g".utf8),
            "Bundle.app/Contents/Resources/inner.xyzp": Data("inner".utf8), "Hidden/.secret/h.xyzp": Data("h".utf8),
            ".hidden.xyzp": Data("hidden".utf8),
        ])
        func at(_ name: String) -> URL { dir.appendingPathComponent(name) }
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: past], ofItemAtPath: at("a.xyzp").path)
        try fm.createSymbolicLink(at: at("link.xyzp"), withDestinationURL: at("a.xyzp"))
        try URL.writeBookmarkData(
            at("a.xyzp").bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil),
            to: at("alias.xyzp"))
        try check(setFinderIcon(NSImage(contentsOf: plum), at("own.xyzp").path), "an unlisted fixture file takes an icon of its own")
        try reopen(at("d.xyzp"), otherApp)
        let plain = try systemImage(at("a.xyzp")), ownIcon = try systemImage(at("own.xyzp"))
        let artwork = published.fileArt(explicit)
        let openers = FileOpeners()
        let passed = engine.apply(dir, art: artwork, unlisted: explicit.unlisted, openers: openers)
        if !passed.errors.isEmpty || !markedUnlisted(at("a.xyzp")) {
            // Reported only when the checks below are about to fail, to tell macOS refusing the icon from a wrong pass.
            let fork = (try? attribute(resourceFork, at("a.xyzp")))??.count ?? 0
            FileHandle.standardError.write(Data(
                "BetterIcon checks: the first pass gave \(passed); a.xyzp has a \(fork)-byte resource fork\n".utf8))
        }
        try check(
            marked(at("a.xyzp")) && markedUnlisted(at("a.xyzp")) && eventually { try distance(systemImage(at("a.xyzp")), plain) > 0.05 }
                && (try Data(contentsOf: at("a.xyzp"))) == Data("a".utf8)
                && (try at("a.xyzp").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) == past,
            "a file of a type outside the list takes the pack's art for the ArtCraft app that opens it by default, keeping its contents and date")
        try check(
            (try? attribute(FolderIcons.marker, at("e.psd"))) == Data(digest(orangePNG).utf8) && !markedUnlisted(at("e.psd"))
                && (try? attribute(FolderIcons.marker, at("f.pcraft"))) == Data(digest(tealPNG).utf8),
            "a listed format keeps its group art and never takes the art for unlisted file types")
        try check(
            !marked(at("b.xyzw")) && !marked(at("c.xyzo")) && !marked(at("d.xyzp")),
            "files another app opens, files an ArtCraft app opens that the pack has no art for, and a file given another app with Open with are left alone")
        try check(
            passed.changed == 3 && passed.kept == 1 && passed.restored == 0 && passed.errors.isEmpty && !marked(at("g"))
                && !marked(at("alias.xyzp")) && !marked(at("Bundle.app/Contents/Resources/inner.xyzp"))
                && !marked(at("Hidden/.secret/h.xyzp")) && !marked(at(".hidden.xyzp")) && !marked(at("own.xyzp"))
                && eventually { try distance(systemImage(at("own.xyzp")), ownIcon) < 0.02 },
            "files without an extension, links, Finder aliases, files in packages or hidden folders, and files with an icon of their own are left alone: \(passed.changed) changed, \(passed.kept) kept")
        try check(openers.lookups == 4, "one pass asks Launch Services once per extension, and once more for each file with an Open with choice of its own")
        let again = engine.apply(dir, art: artwork, unlisted: explicit.unlisted, openers: FileOpeners())
        try check(again.changed == 0 && again.current == 3 && again.kept == 1 && again.restored == 0, "a second pass over unlisted file types changes nothing")
        let switched = engine.apply(dir, art: published.fileArt(labelled), unlisted: labelled.unlisted, openers: FileOpeners())
        try check(
            switched.restored == 1 && !marked(at("a.xyzp")) && !markedUnlisted(at("a.xyzp"))
                && eventually { try distance(systemImage(at("a.xyzp")), plain) < 0.02 } && marked(at("e.psd")) && marked(at("f.pcraft")),
            "with a format-labelled pack, the next pass takes BetterIcon's icon off the file of an unlisted type, and listed formats keep today's rules")
        var gone = [Bool]()
        for pack in [mixed, other] {
            _ = engine.apply(dir, art: artwork, unlisted: explicit.unlisted, openers: FileOpeners())
            let stamped = markedUnlisted(at("a.xyzp"))
            let result = engine.apply(dir, art: published.fileArt(pack), unlisted: pack.unlisted, openers: FileOpeners())
            gone.append(stamped && result.restored == 1 && !marked(at("a.xyzp")))
        }
        try check(gone == [true, true], "a mixed pack and a pack without that app's art also take BetterIcon's icon off it")
        _ = engine.apply(dir, art: artwork, unlisted: explicit.unlisted, openers: FileOpeners())
        let restamped = markedUnlisted(at("a.xyzp"))
        try reopen(at("a.xyzp"), otherApp)
        let moved = engine.apply(dir, art: artwork, unlisted: explicit.unlisted, openers: FileOpeners())
        try check(
            restamped && moved.restored == 1 && !marked(at("a.xyzp"))
                && getxattr(at("a.xyzp").path, resourceFork, nil, 0, 0, XATTR_NOFOLLOW) < 0 && (try? customFlag(at("a.xyzp"))) == false
                && eventually { try distance(systemImage(at("a.xyzp")), plain) < 0.02 },
            "when a file's opener changes, the next pass takes BetterIcon's icon off it")
        try reopen(at("a.xyzp"), nil)
        _ = engine.apply(dir, art: artwork, unlisted: explicit.unlisted, openers: FileOpeners())
        guard setFinderIcon(NSImage(contentsOf: teal), at("a.xyzp").path) else {
            throw Problem("could not give the file an icon of the user's")
        }
        let users = try systemImage(at("a.xyzp"))
        try reopen(at("a.xyzp"), otherApp)
        let kept = engine.apply(dir, art: artwork, unlisted: explicit.unlisted, openers: FileOpeners())
        try reopen(at("a.xyzp"), nil)
        let later = engine.apply(dir, art: artwork, unlisted: explicit.unlisted, openers: FileOpeners())
        try check(
            kept.restored == 0 && !marked(at("a.xyzp")) && later.kept == 2 && !marked(at("a.xyzp"))
                && eventually { try distance(systemImage(at("a.xyzp")), users) < 0.02 },
            "an icon the user put over BetterIcon's stays when the opener changes, and BetterIcon leaves that file alone from then on")
        let restoreDir = try folder(
            root.appendingPathComponent("Restore folder"),
            ["r1.xyzp": Data("1".utf8), "r2.xyzp": Data("2".utf8), "r3.pcraft": Data("3".utf8)])
        let r1 = restoreDir.appendingPathComponent("r1.xyzp"), r2 = restoreDir.appendingPathComponent("r2.xyzp")
        let r3 = restoreDir.appendingPathComponent("r3.pcraft")
        let plainR = try systemImage(r1)
        _ = engine.apply(restoreDir, art: artwork, unlisted: explicit.unlisted, openers: FileOpeners())
        guard setFinderIcon(NSImage(contentsOf: plum), r2.path) else {
            throw Problem("could not give the file an icon of the user's")
        }
        let r2Icon = try systemImage(r2)
        let undone = engine.restore(restoreDir)
        try check(
            undone.restored == 2 && undone.kept == 1 && !marked(r1) && !marked(r2) && !marked(r3)
                && eventually { try distance(systemImage(r1), plainR) < 0.02 } && eventually { try distance(systemImage(r2), r2Icon) < 0.02 },
            "Restore of a folder removes the icons BetterIcon gave files of unlisted types, and keeps an icon the user put over one")
        let reapplied = engine.apply(restoreDir, art: artwork, unlisted: explicit.unlisted, openers: FileOpeners())
        try check(
            reapplied.changed == 2 && reapplied.kept == 1 && marked(r1) && marked(r3) && getxattr(r3.path, resourceFork, nil, 0, 0, XATTR_NOFOLLOW) > 0,
            "after a folder's icons are restored, the next Apply gives its files the pack's icons again: the empty resource fork setIcon leaves is removed")
        // Chosen files, through the file store.
        let store = AppIcons(state.appendingPathComponent("Project File Icons"))
        let chosen = try folder(root.appendingPathComponent("Chosen"), [
            "s1.xyzp": Data("s1".utf8), "s2.xyzw": Data("s2".utf8), "s3.psd": Data("s3".utf8), "s4": Data("s4".utf8),
        ])
        let s1 = chosen.appendingPathComponent("s1.xyzp")
        let plainS1 = try systemImage(s1)
        func plans(_ restore: Bool, _ urls: [URL]) -> (plans: [FilePlan], skipped: [(name: String, reason: String)]) {
            store.filePlans(urls, pack: explicit, artwork: artwork, formats: formats, restore: restore, unlisted: engine.unlisted, openers: FileOpeners())
        }
        func perform(_ found: (plans: [FilePlan], skipped: [(name: String, reason: String)])) throws -> (changed: Int, released: Int) {
            var changed = 0, released = 0
            for plan in found.plans {
                let result = try store.perform(plan.review, apps: plan.apps, pack: plan.pack)
                guard result.errors.isEmpty else { throw Problem(result.errors.joined(separator: " / ")) }
                if plan.releasing { released += result.changed.count } else { changed += result.changed.count }
            }
            return (changed, released)
        }
        let urls = ["s1.xyzp", "s2.xyzw", "s3.psd", "s4"].map(chosen.appendingPathComponent)
        let firstPlans = plans(false, urls)
        let applied = try perform(firstPlans)
        let identity = record(state.appendingPathComponent("Project File Icons"), s1.path)?["identity"] as? String
        try check(
            applied.changed == 2 && firstPlans.skipped.map(\.name) == ["s2.xyzw", "s4"] && firstPlans.plans.count == 2
                && identity?.hasSuffix("/.xyzp") == true && eventually { try distance(systemImage(s1), plainS1) > 0.05 },
            "chosen files of an unlisted type take their opener's art through the file store, recorded under their own extension, and others are named with the reason")
        try reopen(s1, otherApp)
        let restored = try perform(plans(true, [s1]))
        try check(
            restored.changed == 1 && record(state.appendingPathComponent("Project File Icons"), s1.path) == nil
                && eventually { try distance(systemImage(s1), plainS1) < 0.02 },
            "Restore of chosen files gives a file of an unlisted type its own icon back, whatever opens it now")
        try reopen(s1, nil)
        _ = try perform(plans(false, [s1]))
        try reopen(s1, otherApp)
        let releasing = plans(false, [s1])
        let released = try perform(releasing)
        try check(
            releasing.plans.count == 1 && releasing.plans[0].releasing && released.released == 1
                && eventually { try distance(systemImage(s1), plainS1) < 0.02 },
            "Apply on chosen files takes BetterIcon's icon off a file whose opener no longer gets art from the pack")
        // The app itself on a fixture: the catch-up at start, new files in a watched folder, an Open with change, and the
        // pack's art for unlisted types in Manage Icons and the editor.
        let install = try emptyFixture(resources, root, "watched")
        let hostLib = try PackLibrary(install.state.appendingPathComponent("Packs"))
        hostLib.formats = formats
        let hostPack = try hostLib.importPack(explicitDir)
        let watched = try folder(root.appendingPathComponent("watched/Watched"), ["w1.xyzp": Data("w1".utf8), "w0.xyzo": Data("w0".utf8)])
        let w1 = watched.appendingPathComponent("w1.xyzp"), w2 = watched.appendingPathComponent("w2.xyzp")
        let plainW = try systemImage(w1)
        _ = try updatePreferences(install.state) {
            $0.fileFolders = [watched.path: hostPack]
            $0.fileSelected = hostPack
        }
        let host = try startHost(install)
        defer { retire([host]) }
        let caught = await waitUntil(30) { markedUnlisted(w1) }
        try check(caught && !marked(watched.appendingPathComponent("w0.xyzo")), "at start BetterIcon brings a watched folder's files of unlisted types up to date")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try Data("w2".utf8).write(to: w2)
        let arrived = await waitUntil(30) { markedUnlisted(w2) }
        try check(arrived && eventually { try distance(systemImage(w2), plainW) > 0.05 }, "a new file of an unlisted type in a watched folder takes its opener's art while BetterIcon runs")
        try reopen(w1, otherApp)
        let left = await waitUntil(30) { !marked(w1) }
        try check(left && eventually { try distance(systemImage(w1), plainW) < 0.02 }, "an Open with change on a watched file takes BetterIcon's icon off it while BetterIcon runs")
        let summary = await jsUntil(host, """
            el('fileDetail').textContent === '3 file types, plus other PhotoCraft files / Personal pack · 1 folder kept up to date' &&
                !el('applyFiles').disabled
            """)
        _ = await settled(host)
        _ = await js(host, "send('editor', {mode: 'edit', group: 'files'}); true")
        let row = await jsUntil(host, """
            el('editor').open && el('assignments').children.length === 58 &&
                [...el('assignments').children].some(r => r.firstChild.textContent === 'Other PhotoCraft files' &&
                    r.children[1].textContent === 'PhotoCraft-files.png')
            """)
        _ = await js(host, "el('editor').close(); true")
        _ = await jsUntil(host, "!el('editor').open", 10)
        try check(summary && row, "Manage Icons names the other files the file type pack draws, and the editor shows that art in a row of its own")
    }

    /// End to end with Launch Services. Runs only when BETTERICON_TEST_OPENER names a private folder outside the temporary
    /// folders: Launch Services never names an app in a temporary folder as a file's opener ("launch-disabled
    /// in-temp-dir"). Two throwaway apps with made-up bundle IDs each own one made-up extension, and only a test seam calls
    /// the first one PhotoCraft. Both are unregistered and deleted at the end, also after a failure.
    @MainActor static func openerEndToEnd(resources: URL, root: URL) async throws {
        guard let given = ProcessInfo.processInfo.environment["BETTERICON_TEST_OPENER"], !given.isEmpty else { return }
        let openerFolder = URL(fileURLWithPath: given, isDirectory: true).resolvingSymlinksInPath()
        guard fm.fileExists(atPath: openerFolder.path),
            !["/private/tmp/", "/tmp/", "/private/var/", "/var/"].contains(where: openerFolder.path.hasPrefix)
        else { throw Problem("BETTERICON_TEST_OPENER must name an existing folder outside the temporary folders") }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        let tag = "m" + UUID().uuidString.prefix(8).lowercased()
        let extA = "bmt\(tag)a", extB = "bmt\(tag)b"
        let idA = "local.bettericon.roundm.opener.\(tag).a", idB = "local.bettericon.roundm.opener.\(tag).b"
        let appA = try openerApp(openerFolder, "BI Round M Opener A", id: idA, ext: extA)
        let appB = try openerApp(openerFolder, "BI Round M Opener B", id: idB, ext: extB)
        var registered = [appA, appB]
        defer {
            for app in registered { _ = try? run(lsregister, ["-u", app.path]) }
            try? fm.removeItem(at: appA)
            try? fm.removeItem(at: appB)
        }
        for app in registered { guard try run(lsregister, ["-f", app.path]) == 0 else { throw Problem("lsregister refused a throwaway app") } }
        let probe = try self.folder(root, ["probe.\(extA)": Data("probe".utf8)]).appendingPathComponent("probe.\(extA)")
        let pathA = appA.resolvingSymlinksInPath().standardizedFileURL.path
        let ready = eventually(15) { NSWorkspace.shared.urlForApplication(toOpen: probe)?.resolvingSymlinksInPath().standardizedFileURL.path == pathA }
        try check(ready, "end to end: Launch Services names the throwaway app as the opener of its made-up file type")
        let savedIdentify = FileOpeners.identify
        defer { FileOpeners.identify = savedIdentify }
        FileOpeners.identify = { app in app.resolvingSymlinksInPath().standardizedFileURL.path == pathA ? "PhotoCraft" : savedIdentify(app) }
        let formats = try PublishedPacks(resources: resources, state: root.appendingPathComponent("State")).formats
        let orange = try paint(root.appendingPathComponent("orange.png"), NSColor(srgbRed: 0.95, green: 0.45, blue: 0.1, alpha: 1))
        let explicitDir = try self.folder(
            root.appendingPathComponent("Explicit"), ["FileTypes/PhotoCraft-files.png": try Data(contentsOf: orange)])
        let install = try emptyFixture(resources, root, "host")
        let lib = try PackLibrary(install.state.appendingPathComponent("Packs"))
        lib.formats = formats
        let packID = try lib.importPack(explicitDir)
        let watched = try self.folder(root.appendingPathComponent("host/Watched"), [
            "a.\(extA)": Data("a".utf8), "b.\(extB)": Data("b".utf8), "c.\(extA)": Data("c".utf8), "d.pcraft": Data("d".utf8),
        ])
        func at(_ name: String) -> URL { watched.appendingPathComponent(name) }
        try openWith(at("c.\(extA)"), appB, id: idB)
        let plain = try systemImage(at("a.\(extA)"))
        _ = try updatePreferences(install.state) {
            $0.fileFolders = [watched.path: packID]
            $0.fileSelected = packID
        }
        let host = try startHost(install)
        defer { retire([host]) }
        let caught = await waitUntil(30) { markedUnlisted(at("a.\(extA)")) && marked(at("d.pcraft")) }
        try check(
            caught && !marked(at("b.\(extB)")) && !marked(at("c.\(extA)"))
                && eventually { try distance(systemImage(at("a.\(extA)")), plain) > 0.05 },
            "end to end: at start BetterIcon gives a watched file of the made-up type the pack's art for the app Launch Services opens it with, and leaves files other apps open alone")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try Data("e".utf8).write(to: at("e.\(extA)"))
        let arrived = await waitUntil(30) { markedUnlisted(at("e.\(extA)")) }
        try check(arrived, "end to end: a new file of that type in the watched folder takes the art while BetterIcon runs")
        try openWith(at("a.\(extA)"), appB, id: idB)
        let left = await waitUntil(30) { !marked(at("a.\(extA)")) }
        try check(
            left && eventually { try distance(systemImage(at("a.\(extA)")), plain) < 0.02 },
            "end to end: once Get Info's Open with gives that file another app, BetterIcon takes its icon off")
        // A folder the app does not watch, so nothing puts the icon back while this runs.
        guard let pack = lib.visible([]).first(where: { $0.id == packID }) else { throw Problem("the fixture pack is missing") }
        let engine = FolderIcons(formats: formats)
        let restoreDir = try self.folder(root.appendingPathComponent("Restore"), ["r.\(extA)": Data("r".utf8)])
        let given2 = engine.apply(restoreDir, art: [:], unlisted: pack.unlisted, openers: FileOpeners())
        let undone = engine.restore(restoreDir)
        let r = restoreDir.appendingPathComponent("r.\(extA)")
        try check(
            given2.changed == 1 && undone.restored == 1 && !marked(r) && eventually { try distance(systemImage(r), plain) < 0.02 },
            "end to end: Restore removes the icon BetterIcon gave a file of that type")
        let chosen = try self.folder(root.appendingPathComponent("Chosen"), ["f.\(extA)": Data("f".utf8)]).appendingPathComponent("f.\(extA)")
        let store = AppIcons(install.state.appendingPathComponent("Project File Icons"))
        func choose(_ restore: Bool) throws -> Int {
            let found = store.filePlans(
                [chosen], pack: pack, artwork: [:], formats: formats, restore: restore, unlisted: engine.unlisted, openers: FileOpeners())
            return try found.plans.reduce(0) { $0 + (try store.perform($1.review, apps: $1.apps, pack: $1.pack)).changed.count }
        }
        let applied = try choose(false)
        let changedLook = eventually { try distance(systemImage(chosen), plain) > 0.05 }
        let restored = try choose(true)
        try check(
            applied == 1 && changedLook && restored == 1 && eventually { try distance(systemImage(chosen), plain) < 0.02 },
            "end to end: a chosen file of that type takes the art through the file store, and Restore gives its own icon back")
        for app in registered { _ = try run(lsregister, ["-u", app.path]) }
        registered = []
        try fm.removeItem(at: appA)
        try fm.removeItem(at: appB)
        let unregistered = eventually(15) {
            NSWorkspace.shared.urlsForApplications(withBundleIdentifier: idA).isEmpty
                && NSWorkspace.shared.urlsForApplications(withBundleIdentifier: idB).isEmpty
        }
        let dump = try output(lsregister, ["-dump"])
        try check(
            unregistered && !dump.isEmpty && !dump.contains("local.bettericon.roundm.opener.\(tag)") && !dump.contains("bmt\(tag)"),
            "end to end: the throwaway apps are unregistered and Launch Services keeps no record of them")
    }
    /// A throwaway app that owns one made-up file type.
    static func openerApp(_ dir: URL, _ name: String, id: String, ext: String) throws -> URL {
        let app = dir.appendingPathComponent(name + ".app", isDirectory: true)
        let c = app.appendingPathComponent("Contents")
        try fm.createDirectory(at: c.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: c.appendingPathComponent("MacOS/Opener"))
        let type = id + ".document"
        let plist: [String: Any] = [
            "CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL", "CFBundleExecutable": "Opener",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0", "LSUIElement": true,
            "UTExportedTypeDeclarations": [[
                "UTTypeIdentifier": type, "UTTypeConformsTo": ["public.data", "public.content"],
                "UTTypeTagSpecification": ["public.filename-extension": [ext]],
            ]],
            "CFBundleDocumentTypes": [[
                "CFBundleTypeName": name + " Document", "CFBundleTypeRole": "Editor", "LSHandlerRank": "Owner",
                "LSItemContentTypes": [type],
            ]],
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(
            to: c.appendingPathComponent("Info.plist"))
        try check(run("/usr/bin/codesign", ["-fs", "-", app.path]) == 0, "sign disposable fixture")
        return app
    }
    /// Icon changes from several threads at once, as Apply, putting app icons back, folder passes and the folder watcher
    /// make them. NSWorkspace.setIcon is not thread-safe; BetterIcon makes them one at a time.
    static func iconChangesTogether(root: URL) throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let colors: [NSColor] = [.orange, .systemTeal, .purple, .systemGreen]
        let images = try colors.enumerated().map { index, color -> NSImage in
            guard let image = NSImage(contentsOf: try paint(root.appendingPathComponent("art\(index).png"), color)) else {
                throw Problem("could not read test artwork")
            }
            return image
        }
        let tally = Tally(), group = DispatchGroup()
        for (index, image) in images.enumerated() {
            let file = root.appendingPathComponent("file\(index).xyzp")
            try Data("x".utf8).write(to: file)
            let work = Unchecked(image)
            group.enter()
            Thread {
                for round in 0..<25 {
                    let set = setFinderIcon(work.value, file.path)
                    let shown = (try? customFlag(file)) == true && getxattr(file.path, resourceFork, nil, 0, 0, XATTR_NOFOLLOW) > 1000
                    let removed = setFinderIcon(nil, file.path)
                    let gone = (try? customFlag(file)) == false
                    if !(set && shown && removed && gone) { tally.add("\(file.lastPathComponent) round \(round)") }
                    removexattr(file.path, resourceFork, XATTR_NOFOLLOW)
                }
                group.leave()
            }.start()
        }
        group.wait()
        try check(tally.all.isEmpty, "icon changes from several threads at once go through one at a time, and each file gets and loses its icon")
    }
    /// A small image, much smaller as an icon than the one BetterIcon puts on a file: what an app writes as a document's own
    /// icon.
    static func tinyIcon(_ url: URL, _ color: NSColor) throws -> NSImage {
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { throw Problem("Could not draw a small icon.") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        color.setFill()
        NSRect(x: 2, y: 2, width: 12, height: 12).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw Problem("Could not encode a small icon.") }
        try png.write(to: url)
        guard let image = NSImage(data: png) else { throw Problem("Could not read a small icon.") }
        return image
    }
    /// The fixes after the review of the art for unlisted file types and of folders kept up to date, on the store and the
    /// folder engine without the app. Stand-ins for Launch Services, as in unlistedChecks: .xyzp files open with an app
    /// called PhotoCraft here, .xyzo files with another app, and other made-up types with none.
    @MainActor static func unlistedFixChecks(resources: URL, root: URL) async throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let state = root.appendingPathComponent("State")
        let published = try PublishedPacks(resources: resources, state: state)
        let formats = published.formats
        let lib = try PackLibrary(state.appendingPathComponent("Packs"))
        lib.formats = formats
        let orange = try paint(root.appendingPathComponent("orange.png"), NSColor(srgbRed: 0.95, green: 0.45, blue: 0.1, alpha: 1))
        let teal = try paint(root.appendingPathComponent("teal.png"), NSColor(srgbRed: 0.1, green: 0.6, blue: 0.6, alpha: 1))
        let plum = try paint(root.appendingPathComponent("plum.png"), NSColor(srgbRed: 0.5, green: 0.1, blue: 0.5, alpha: 1))
        let orangePNG = try Data(contentsOf: orange), tealPNG = try Data(contentsOf: teal), plumPNG = try Data(contentsOf: plum)
        let table = OpenerTable()
        let photoApp = URL(fileURLWithPath: "/Checks/Photo Opener.app"), otherApp = URL(fileURLWithPath: "/Checks/Other Opener.app")
        table.open("xyzp", with: photoApp)
        table.open("xyzo", with: otherApp)
        table.name(photoApp, "PhotoCraft")
        let savedLookup = FileOpeners.lookup, savedIdentify = FileOpeners.identify
        defer {
            FileOpeners.lookup = savedLookup
            FileOpeners.identify = savedIdentify
        }
        FileOpeners.lookup = { table.opener($0) }
        FileOpeners.identify = { table.craft($0) }
        func imported(_ name: String, _ files: [String: Data]) throws -> Pack {
            let id = try lib.importPack(folder(root.appendingPathComponent(name), files))
            guard let pack = lib.visible([]).first(where: { $0.id == id }) else { throw Problem("the imported pack is missing") }
            return pack
        }
        let pack = try imported("Explicit", ["FileTypes/PhotoCraft-files.png": orangePNG, "FileTypes/pcraft.png": tealPNG])
        let art = published.fileArt(pack)
        let engine = FolderIcons(formats: formats)
        let storeRoot = state.appendingPathComponent("Project File Icons")
        let store = AppIcons(storeRoot)
        func plans(_ urls: [URL], _ pack: Pack, restore: Bool) -> (plans: [FilePlan], skipped: [(name: String, reason: String)]) {
            store.filePlans(
                urls, pack: pack, artwork: published.fileArt(pack), formats: formats, restore: restore, unlisted: engine.unlisted,
                openers: FileOpeners())
        }
        func perform(_ found: (plans: [FilePlan], skipped: [(name: String, reason: String)])) throws -> (changed: Int, errors: [String]) {
            var changed = 0, errors = [String]()
            for plan in found.plans {
                let result = try store.perform(plan.review, apps: plan.apps, pack: plan.pack)
                changed += result.changed.count
                errors += result.errors
            }
            return (changed, errors)
        }
        // A chosen file with an icon of its own that is smaller than BetterIcon's: setxattr writes a resource fork over the
        // one in place without truncating it, so its Restore kept BetterIcon's tail and failed.
        let own = try folder(root.appendingPathComponent("Own icons"), ["mine.xyzp": Data("m".utf8), "mine.pcraft": Data("p".utf8)])
        let mine = ["mine.xyzp", "mine.pcraft"].map(own.appendingPathComponent)
        let small = try tinyIcon(root.appendingPathComponent("small.png"), .systemRed)
        for file in mine { guard setFinderIcon(small, file.path) else { throw Problem("could not give a file a small icon of its own") } }
        let forks = try mine.map { try attribute(resourceFork, $0) }
        let applied = try perform(plans(mine, pack, restore: false))
        let larger = try zip(mine, forks).allSatisfy { file, fork in (try attribute(resourceFork, file))?.count ?? 0 > fork?.count ?? 0 }
        let restored = try perform(plans(mine, pack, restore: true))
        let back = try mine.map { try attribute(resourceFork, $0) }
        if !restored.errors.isEmpty { FileHandle.standardError.write(Data("BetterIcon checks: \(restored.errors)\n".utf8)) }
        try check(
            applied.changed == 2 && applied.errors.isEmpty && larger && restored.changed == 2 && restored.errors.isEmpty
                && back == forks && forks.allSatisfy { $0 != nil } && mine.allSatisfy { (try? customFlag($0)) == true }
                && mine.allSatisfy { record(storeRoot, $0.path) == nil },
            "Restore of chosen files brings back an icon of their own that is smaller than BetterIcon's, byte for byte, for a listed format and for another type")
        // A file of another type renamed to a listed format in a kept folder, and a type that joins the list.
        let renamed = try folder(root.appendingPathComponent("Renamed"), ["logo.xyzp": Data("l".utf8), "plain.pcraft": Data("p".utf8)])
        let logo = renamed.appendingPathComponent("logo.xyzp"), logoListed = renamed.appendingPathComponent("logo.pcraft")
        _ = engine.apply(renamed, art: art, unlisted: pack.unlisted, openers: FileOpeners())
        let stamped = markedUnlisted(logo)
        try fm.moveItem(at: logo, to: logoListed)
        let afterRename = engine.apply(renamed, art: art, unlisted: pack.unlisted, openers: FileOpeners())
        let design = (try? attribute(FolderIcons.marker, logoListed)) == Data(digest(tealPNG).utf8) && !markedUnlisted(logoListed)
        let undone = engine.restore(renamed)
        try check(
            stamped && afterRename.changed == 1 && design && undone.restored == 2 && undone.kept == 0 && !marked(logoListed)
                && (try? customFlag(logoListed)) == false && getxattr(logoListed.path, resourceFork, nil, 0, 0, XATTR_NOFOLLOW) < 0,
            "a file of another type renamed to a listed format takes that format's design without its old mark, and a folder Restore takes BetterIcon's icon off it")
        let grown = FolderIcons(formats: formats + (try JSONDecoder().decode(
            [ProjectFormat].self, from: Data(#"[{"Key": ".xyzp", "Application": "PhotoCraft"}]"#.utf8))))
        let joined = try folder(root.appendingPathComponent("Joined"), ["later.xyzp": Data("j".utf8)])
        let later = joined.appendingPathComponent("later.xyzp")
        let plainLater = try systemImage(later)
        _ = engine.apply(joined, art: art, unlisted: pack.unlisted, openers: FileOpeners())
        let had = markedUnlisted(later)
        let taken = grown.apply(joined, art: art, unlisted: pack.unlisted, openers: FileOpeners())
        try check(
            had && taken.restored == 1 && !marked(later) && !markedUnlisted(later)
                && eventually { try distance(systemImage(later), plainLater) < 0.02 },
            "once a file's type joins the list, a pass takes off the icon BetterIcon gave it as a file of another type when the pack has no design for that type")
        // A file whose icon comes from a kept folder, chosen in Apply file icons… with another pack.
        let keptDir = try folder(root.appendingPathComponent("Kept"), ["poster.xyzp": Data("p".utf8), "sheet.pcraft": Data("s".utf8)])
        let poster = keptDir.appendingPathComponent("poster.xyzp"), sheet = keptDir.appendingPathComponent("sheet.pcraft")
        _ = engine.apply(keptDir, art: art, unlisted: pack.unlisted, openers: FileOpeners())
        let otherPack = try imported("Other pack", ["FileTypes/PhotoCraft-files.png": plumPNG, "FileTypes/pcraft.png": plumPNG])
        let offered = plans([poster, sheet], otherPack, restore: false)
        // As the app does once the user confirms, then the next pass over the folder, as the watcher runs it.
        let byStore = try perform(offered)
        let folderPass = engine.apply(keptDir, art: art, unlisted: pack.unlisted, openers: FileOpeners())
        let reason = "Its icon comes from a folder BetterIcon keeps up to date"
        try check(
            byStore.changed == 0 && offered.skipped.map(\.name) == ["poster.xyzp", "sheet.pcraft"]
                && offered.skipped.allSatisfy { $0.reason == reason } && marked(poster) && markedUnlisted(poster) && marked(sheet)
                && folderPass.current == 2 && folderPass.kept == 0,
            "Apply on chosen files leaves alone a file whose icon comes from a folder BetterIcon keeps up to date, with the reason, so the folder keeps its marks")
        // Every chosen file that gets nothing is named, with its reason.
        let assorted = try folder(root.appendingPathComponent("Assorted"), [
            "plan.dwg": Data("d".utf8), "README": Data("r".utf8), "notes.qqq": Data("q".utf8), "a.xyzp": Data("a".utf8),
            "other.xyzo": Data("o".utf8),
        ])
        try fm.createSymbolicLink(at: assorted.appendingPathComponent("link.xyzp"), withDestinationURL: assorted.appendingPathComponent("a.xyzp"))
        let offeredNames = ["plan.dwg", "README", "notes.qqq", "a.xyzp", "other.xyzo", "link.xyzp"]
        let named = plans(offeredNames.map(assorted.appendingPathComponent), pack, restore: false).skipped.map { $0.name + ": " + $0.reason }
        try check(
            named == [
                "plan.dwg: No artwork in this pack", "README: Files without an extension are left alone", "notes.qqq: No app opens it",
                "other.xyzo: Opens with an app this pack has no art for",
                "link.xyzp: Folders, packages, links, Finder aliases and apps are left alone",
            ],
            "the confirmation of Apply file icons… names each chosen file that gets nothing, with its reason")
        // The memory of a pass over a large folder of files of other types while no pack has art for them.
        let many = root.appendingPathComponent("Many")
        for group in 0..<150 {
            let sub = many.appendingPathComponent(String(format: "g%03d", group))
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
            for index in 0..<200 {
                guard fm.createFile(atPath: sub.appendingPathComponent("f\(index).xyzq").path, contents: nil) else {
                    throw Problem("could not create the files of a large folder")
                }
            }
        }
        var growth = [Int64]()
        for _ in 0..<2 { growth.append(footprintGrowth { _ = engine.apply(many, art: [".pcraft": teal]) }) }
        let grownMB = Double(growth.min() ?? 0) / 1_048_576
        if grownMB >= 8 {
            FileHandle.standardError.write(Data("BetterIcon checks: a pass over 30,000 files of other types grew the footprint by \(growth) bytes\n".utf8))
        }
        try check(
            grownMB < 8,
            "a pass over a large folder of files of other types, with no art for them, goes file by file and keeps its memory flat")
    }
    /// How far this process's physical footprint rose above its level before `body`, sampled every millisecond from
    /// another thread while `body` runs.
    static func footprintGrowth(_ body: () -> Void) -> Int64 {
        func footprint() -> Int64 {
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
            }
            return status == 0 ? Int64(info.ri_phys_footprint) : 0
        }
        let before = footprint()
        let sampler = FootprintPeak(before)
        let finished = DispatchSemaphore(value: 0)
        Thread {
            while sampler.running { sampler.note(footprint()); usleep(1000) }
            finished.signal()
        }.start()
        body()
        sampler.note(footprint())
        sampler.running = false
        finished.wait()
        return sampler.peak - before
    }

    /// The same fixes in the app itself, on fixtures, with the folder watcher running. The file panel and the alerts of
    /// Apply file icons… and Restore file icons… are answered by ModalStub. Stand-ins for Launch Services as above.
    @MainActor static func unlistedFixHostChecks(resources: URL, root: URL) async throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let icon = resources.appendingPathComponent("BetterIcon.icns")
        let formats = try PublishedPacks(resources: resources, state: root.appendingPathComponent("State")).formats
        let orange = try paint(root.appendingPathComponent("orange.png"), NSColor(srgbRed: 0.95, green: 0.45, blue: 0.1, alpha: 1))
        let teal = try paint(root.appendingPathComponent("teal.png"), NSColor(srgbRed: 0.1, green: 0.6, blue: 0.6, alpha: 1))
        let plum = try paint(root.appendingPathComponent("plum.png"), NSColor(srgbRed: 0.5, green: 0.1, blue: 0.5, alpha: 1))
        let orangePNG = try Data(contentsOf: orange), tealPNG = try Data(contentsOf: teal), plumPNG = try Data(contentsOf: plum)
        let table = OpenerTable()
        let photoApp = URL(fileURLWithPath: "/Checks/Photo Opener.app")
        table.open("xyzp", with: photoApp)
        table.name(photoApp, "PhotoCraft")
        let savedLookup = FileOpeners.lookup, savedIdentify = FileOpeners.identify
        ModalStub.install()
        defer {
            ModalStub.remove()
            FileOpeners.lookup = savedLookup
            FileOpeners.identify = savedIdentify
        }
        FileOpeners.lookup = { table.opener($0) }
        FileOpeners.identify = { table.craft($0) }
        /// A fixture app with its own library holding these packs, by folder name and files.
        func fixture(_ name: String, _ packs: [(String, [String: Data])]) throws -> (install: Installation, ids: [String]) {
            let install = try emptyFixture(resources, root, name)
            let lib = try PackLibrary(install.state.appendingPathComponent("Packs"))
            lib.formats = formats
            let ids = try packs.map { try lib.importPack(folder(root.appendingPathComponent(name + "/Pack sources/" + $0.0), $0.1)) }
            return (install, ids)
        }
        func flagged(_ file: URL) -> Bool { (try? customFlag(file)) == true }
        func mark(_ file: URL) -> Data? { (try? attribute(FolderIcons.marker, file)) ?? nil }
        func ctime(_ file: URL) -> String {
            var st = stat()
            guard lstat(file.path, &st) == 0 else { return "missing" }
            return "\(st.st_ctimespec.tv_sec).\(st.st_ctimespec.tv_nsec)"
        }
        /// Choose these items in the file panel of Apply file icons… or Restore file icons…, answer its confirmation with
        /// `button`, and wait for the status line the work ends with.
        func choose(_ host: Application, _ urls: [URL], restore: Bool, button: String, until text: String) async -> Bool {
            ModalStub.urls = urls
            ModalStub.response = .OK
            ModalStub.answer = { _, buttons in buttons.contains(button) ? button : buttons.first }
            _ = await settled(host)
            let before = await statusText(host)
            _ = await js(host, "send('reviewFiles', {restore: \(restore)}); true")
            let end = Date().addingTimeInterval(180)
            while Date() < end {
                let line = await statusText(host)
                if line != before && line.contains(text) { return await settled(host) }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return false
        }
        func admitted(_ item: URL, by types: [UTType]) -> Bool {
            guard let type = try? item.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
            return types.contains { type.conforms(to: $0) }
        }
        let explicitFiles = ["FileTypes/PhotoCraft-files.png": orangePNG, "FileTypes/pcraft.png": tealPNG]

        // The file panel, and an app bundle or a document package chosen with a folder.
        let shelfFixture = try fixture("packages", [("Explicit", explicitFiles)])
        let shelf = try folder(root.appendingPathComponent("packages/Shelf"), [
            "Notes.rtfd/TXT.rtf": Data("{\\rtf1}".utf8), "Notes.rtfd/inside.pcraft": Data("n".utf8), "loose.xyzp": Data("l".utf8),
            "Sub/x.pcraft": Data("x".utf8),
        ])
        let viewer = try fixtureApp(shelf, "Viewer", id: "local.bettericon.roundm.viewer", icon: icon)
        for name in ["badge.xyzp", "toolbar.pcraft"] {
            try Data(name.utf8).write(to: viewer.appendingPathComponent("Contents/Resources/" + name))
        }
        guard try run("/usr/bin/codesign", ["-fs", "-", viewer.path]) == 0 else { throw Problem("could not sign the fixture app") }
        let notes = shelf.appendingPathComponent("Notes.rtfd"), sub = shelf.appendingPathComponent("Sub")
        _ = try updatePreferences(shelfFixture.install.state) { $0.fileSelected = shelfFixture.ids[0] }
        let shelfHost = try startHost(shelfFixture.install)
        defer { retire([shelfHost]) }
        _ = await settled(shelfHost)
        ModalStub.response = .cancel
        let panelsBefore = ModalStub.panels.count
        _ = await js(shelfHost, "send('reviewFiles', {restore: false}); true")
        _ = await waitUntil(10) { ModalStub.panels.count == panelsBefore + 1 }
        _ = await js(shelfHost, "send('reviewFiles', {restore: true}); true")
        _ = await waitUntil(10) { ModalStub.panels.count == panelsBefore + 2 }
        let offered = Array(ModalStub.panels.dropFirst(panelsBefore))
        try check(
            offered.count == 2
                && offered.allSatisfy { types in
                    !admitted(viewer, by: types) && !admitted(notes, by: types) && admitted(shelf.appendingPathComponent("loose.xyzp"), by: types)
                        && admitted(sub, by: types)
                },
            "the file panel of Apply file icons… and Restore file icons… offers folders and files but no app or document package, also when the pack draws other file types")
        let alertsBefore = ModalStub.alerts.count
        let chosePackages = await choose(shelfHost, [viewer, notes, sub], restore: false, button: "Apply", until: "applied.")
        let asked = ModalStub.alerts.dropFirst(alertsBefore).map(\.info).joined(separator: "\n")
        let inside = ["Contents/Resources/badge.xyzp", "Contents/Resources/toolbar.pcraft"].map(viewer.appendingPathComponent)
            + [notes.appendingPathComponent("inside.pcraft")]
        let keptFolders = storedPrefs(shelfFixture.install)?.fileFolders ?? [:]
        try check(
            chosePackages && asked.contains("Packages and apps are left alone: Viewer.app, Notes.rtfd.")
                && inside.allSatisfy { !marked($0) && !flagged($0) } && marked(sub.appendingPathComponent("x.pcraft"))
                && keptFolders.keys.map(realFolderPath) == [realFolderPath(sub.path)]
                && (try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", viewer.path])) == 0,
            "an app or a document package chosen with a folder is left alone and named: nothing inside it changes, the app's signature still checks out, and only the folder is kept up to date")

        // A chosen file with BetterIcon's icon for other types, after the file type pack changed to one without such art.
        let released = try fixture("released", [("Explicit", explicitFiles), ("Listed only", ["FileTypes/pcraft.png": plumPNG])])
        let posterDir = try folder(root.appendingPathComponent("released/Chosen"), ["poster.xyzp": Data("p".utf8)])
        let poster = posterDir.appendingPathComponent("poster.xyzp")
        let releasedLib = try PackLibrary(released.install.state.appendingPathComponent("Packs"))
        releasedLib.formats = formats
        guard let explicitPack = releasedLib.visible([]).first(where: { $0.id == released.ids[0] }) else {
            throw Problem("the fixture pack is missing")
        }
        let fileStore = AppIcons(released.install.state.appendingPathComponent("Project File Icons"))
        let engine = FolderIcons(formats: formats)
        let earlier = fileStore.filePlans(
            [poster], pack: explicitPack, artwork: [:], formats: formats, restore: false, unlisted: engine.unlisted, openers: FileOpeners())
        for plan in earlier.plans { _ = try fileStore.perform(plan.review, apps: plan.apps, pack: plan.pack) }
        let given = flagged(poster) && fileStore.hasRecord(poster.path)
        _ = try updatePreferences(released.install.state) { $0.fileSelected = released.ids[1] }
        let releasedHost = try startHost(released.install)
        defer { retire([releasedHost]) }
        let panelsNow = ModalStub.panels.count
        let releasedDone = await choose(
            releasedHost, [poster], restore: false, button: "Apply", until: "removed from files that no app this pack has art for opens now.")
        let releasedTypes = ModalStub.panels.count > panelsNow ? ModalStub.panels[panelsNow] : []
        try check(
            given && admitted(poster, by: releasedTypes) && releasedDone && !flagged(poster)
                && getxattr(poster.path, resourceFork, nil, 0, 0, XATTR_NOFOLLOW) < 0 && !fileStore.hasRecord(poster.path),
            "after a change to a file type pack without art for other types, Apply file icons… still offers a chosen file of another type with BetterIcon's icon, and takes that icon off")

        // Restore of a kept folder while the folder watcher runs.
        let race = try fixture("restore-race", [("Explicit", explicitFiles)])
        var raceFiles = [String: Data]()
        for index in 0..<200 {
            raceFiles[String(format: "f%03d.pcraft", index)] = Data("f\(index)".utf8)
            raceFiles[String(format: "g%03d.xyzp", index)] = Data("g\(index)".utf8)
        }
        let raceDir = try folder(root.appendingPathComponent("restore-race/Watched"), raceFiles)
        let raceURLs = raceFiles.keys.sorted().map(raceDir.appendingPathComponent)
        _ = try updatePreferences(race.install.state) {
            $0.fileFolders = [raceDir.path: race.ids[0]]
            $0.fileSelected = race.ids[0]
        }
        let raceHost = try startHost(race.install)
        defer { retire([raceHost]) }
        let raceCaught = await waitUntil(180) { raceURLs.allSatisfy(marked) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let raceRestored = await choose(raceHost, [raceDir], restore: true, button: "Restore", until: "restored.")
        try await Task.sleep(nanoseconds: 5_000_000_000)
        let raceLeft = raceURLs.filter { marked($0) || flagged($0) }
        if !raceLeft.isEmpty { FileHandle.standardError.write(Data("BetterIcon checks: \(raceLeft.count) files kept an icon after Restore\n".utf8)) }
        try check(
            raceCaught && raceRestored && raceLeft.isEmpty && storedPrefs(race.install)?.fileFolders == nil,
            "Restore file icons… on a folder kept up to date takes every icon off while the folder watcher runs, and stops keeping the folder")

        // Apply with another pack on a kept folder while the folder watcher runs, and what its confirmation says.
        let switching = try fixture("reapply-race", [("Explicit", explicitFiles), ("Listed only", ["FileTypes/pcraft.png": plumPNG])])
        var switchFiles = [String: Data]()
        for index in 0..<150 {
            switchFiles[String(format: "f%03d.pcraft", index)] = Data("f\(index)".utf8)
            switchFiles[String(format: "g%03d.xyzp", index)] = Data("g\(index)".utf8)
        }
        let switchDir = try folder(root.appendingPathComponent("reapply-race/Watched"), switchFiles)
        let listedFiles = switchFiles.keys.filter { $0.hasSuffix(".pcraft") }.sorted().map(switchDir.appendingPathComponent)
        let otherFiles = switchFiles.keys.filter { $0.hasSuffix(".xyzp") }.sorted().map(switchDir.appendingPathComponent)
        _ = try updatePreferences(switching.install.state) {
            $0.fileFolders = [switchDir.path: switching.ids[0]]
            $0.fileSelected = switching.ids[0]
        }
        let switchHost = try startHost(switching.install)
        defer { retire([switchHost]) }
        let switchCaught = await waitUntil(180) { (listedFiles + otherFiles).allSatisfy(marked) && otherFiles.allSatisfy(markedUnlisted) }
        _ = await settled(switchHost)
        _ = await js(switchHost, "send('select', {id: '\(switching.ids[1])', group: 'files'}); true")
        let selected = await statusUntil(switchHost, "File type icon pack selected.")
        let switchAlerts = ModalStub.alerts.count
        let switched = await choose(switchHost, [switchDir], restore: false, button: "Apply", until: "applied.")
        try await Task.sleep(nanoseconds: 5_000_000_000)
        let confirmation = ModalStub.alerts.dropFirst(switchAlerts).first
        try check(
            confirmation?.title == "Apply icons to 150 files?"
                && confirmation?.info.contains("It also takes its icons off 150 files of other types that no app this pack has art for opens now.") == true,
            "the confirmation of a folder Apply says how many files lose the icons BetterIcon gave them as files of other types")
        let onNew = listedFiles.filter { mark($0) == Data(digest(plumPNG).utf8) }.count
        let stillOther = otherFiles.filter { marked($0) || markedUnlisted($0) || flagged($0) }.count
        if onNew != listedFiles.count || stillOther > 0 {
            FileHandle.standardError.write(Data("BetterIcon checks: \(onNew) of \(listedFiles.count) on the new pack, \(stillOther) files of other types keep an icon\n".utf8))
        }
        let keptNow = (storedPrefs(switching.install)?.fileFolders ?? [:]).map { (realFolderPath($0.key), $0.value) }
        try check(
            switchCaught && selected && switched && onNew == listedFiles.count && stillOther == 0
                && keptNow.count == 1 && keptNow.first?.0 == realFolderPath(switchDir.path) && keptNow.first?.1 == switching.ids[1],
            "Apply file icons… with another pack on a folder kept up to date leaves every file on the new pack while the folder watcher runs")

        // Restore during the catch-up at start.
        let catchUp = try fixture("catch-up", [("Explicit", explicitFiles)])
        var catchFiles = [String: Data]()
        for index in 0..<1200 { catchFiles[String(format: "c%04d.pcraft", index)] = Data("c\(index)".utf8) }
        let catchDir = try folder(root.appendingPathComponent("catch-up/Watched"), catchFiles)
        let catchURLs = catchFiles.keys.sorted().map(catchDir.appendingPathComponent)
        _ = try updatePreferences(catchUp.install.state) {
            $0.fileFolders = [catchDir.path: catchUp.ids[0]]
            $0.fileSelected = catchUp.ids[0]
        }
        let catchHost = try startHost(catchUp.install)
        defer { retire([catchHost]) }
        let begun = await waitUntil(60) { catchURLs.prefix(400).filter(marked).count >= 20 }
        let themedThen = catchURLs.filter(marked).count
        let catchRestored = await choose(catchHost, [catchDir], restore: true, button: "Restore", until: "restored.")
        var lastCount = -1
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let count = catchURLs.filter(marked).count
            if count == lastCount { break }
            lastCount = count
        }
        let catchLeft = catchURLs.filter { marked($0) || flagged($0) }.count
        if catchLeft > 0 { FileHandle.standardError.write(Data("BetterIcon checks: \(catchLeft) files kept an icon after a Restore during the catch-up\n".utf8)) }
        try check(
            begun && themedThen < catchURLs.count && catchRestored && catchLeft == 0 && storedPrefs(catchUp.install)?.fileFolders == nil,
            "Restore file icons… during the catch-up at start ends that pass: no file of the folder keeps BetterIcon's icon")

        // One kept folder inside another, on different packs, over two starts.
        let nested = try fixture("nested", [("Outer pack", ["FileTypes/pcraft.png": orangePNG]), ("Inner pack", ["FileTypes/PhotoCraft-files.png": tealPNG])])
        let outer = try folder(root.appendingPathComponent("nested/Outer"), [
            "o.pcraft": Data("o".utf8), "Inner/i.pcraft": Data("i".utf8), "Inner/j.xyzp": Data("j".utf8),
        ])
        let inner = outer.appendingPathComponent("Inner")
        let o = outer.appendingPathComponent("o.pcraft"), i = inner.appendingPathComponent("i.pcraft"), j = inner.appendingPathComponent("j.xyzp")
        let outerMark = Data(digest(orangePNG).utf8), innerMark = Data(digest(tealPNG).utf8)
        _ = try updatePreferences(nested.install.state) {
            $0.fileFolders = [outer.path: nested.ids[0], inner.path: nested.ids[1]]
            $0.fileSelected = nested.ids[1]
        }
        let firstStart = try startHost(nested.install)
        let nestedSettled = await waitUntil(60) {
            mark(o) == outerMark && mark(i) == innerMark && mark(j) == innerMark && markedUnlisted(j)
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let times = [i, j].map(ctime)
        retire([firstStart])
        let sentinel = outer.appendingPathComponent("new.pcraft")
        try Data("n".utf8).write(to: sentinel)
        let secondStart = try startHost(nested.install)
        defer { retire([secondStart]) }
        let reached = await waitUntil(60) { mark(sentinel) == outerMark }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        try check(
            nestedSettled && reached && mark(i) == innerMark && mark(j) == innerMark && markedUnlisted(j) && [i, j].map(ctime) == times,
            "with one kept folder inside another, each keeps its own pack: the catch-up at start leaves the inner folder's icons, those for other file types included, as they are")

        // Files of listed formats inside a package and a hidden folder of a kept folder.
        let tucked = try fixture("tucked", [("Explicit", explicitFiles)])
        let tuckedDir = try folder(root.appendingPathComponent("tucked/Watched"), [
            "Notes.rtfd/TXT.rtf": Data("{\\rtf1}".utf8), ".cache/keep.txt": Data("k".utf8),
        ])
        _ = try updatePreferences(tucked.install.state) {
            $0.fileFolders = [tuckedDir.path: tucked.ids[0]]
            $0.fileSelected = tucked.ids[0]
        }
        let tuckedHost = try startHost(tucked.install)
        defer { retire([tuckedHost]) }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let insides = [tuckedDir.appendingPathComponent("Notes.rtfd/inside.pcraft"), tuckedDir.appendingPathComponent(".cache/thumb.pcraft")]
        let visible = tuckedDir.appendingPathComponent("visible.pcraft")
        for file in insides + [visible] { try Data("t".utf8).write(to: file) }
        let seen = await waitUntil(30) { marked(visible) }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        try check(
            seen && insides.allSatisfy { !marked($0) && !flagged($0) },
            "the folder watcher leaves alone files of listed formats inside a package or a hidden folder of a kept folder, as the folder pass does")

        // The kept folder's pack, edited while BetterIcon runs.
        let edited = try fixture("edited", [("Explicit", explicitFiles)])
        let editedDir = try folder(root.appendingPathComponent("edited/Watched"), ["w1.xyzp": Data("w1".utf8)])
        let w1 = editedDir.appendingPathComponent("w1.xyzp"), w3 = editedDir.appendingPathComponent("w3.xyzp")
        let plainW = try systemImage(w1)
        _ = try updatePreferences(edited.install.state) {
            $0.fileFolders = [editedDir.path: edited.ids[0]]
            $0.fileSelected = edited.ids[0]
        }
        let editHost = try startHost(edited.install)
        defer { retire([editHost]) }
        let editCaught = await waitUntil(30) { markedUnlisted(w1) }
        _ = await settled(editHost)
        _ = await js(editHost, "send('editor', {mode: 'edit', group: 'files'}); true")
        let opened = await jsUntil(editHost, "el('editor').open")
        _ = await js(editHost, "send('clearAssignment', {craft: '*PhotoCraft'}); send('savePack', {name: 'Explicit', author: ''}); true")
        let saved = await statusUntil(editHost, "Icon pack saved.")
        let off = await waitUntil(30) { !marked(w1) && !markedUnlisted(w1) }
        try Data("w3".utf8).write(to: w3)
        try await Task.sleep(nanoseconds: 4_000_000_000)
        try check(
            editCaught && opened && saved && off && eventually { try distance(systemImage(w1), plainW) < 0.02 } && !marked(w3) && !flagged(w3),
            "after the kept folder's pack is edited to drop its art for other file types, BetterIcon takes that art off the folder's files and gives it to no new file while it runs")

        // The status line after a pack with items that cannot be used is chosen.
        let leftOutFixture = try fixture("left-out", [])
        let solid = try folder(root.appendingPathComponent("left-out/Published"), [
            "PhotoCraft.webp": webp("A13"), "GridCraft.webp": webp("A15"), "FileTypes/pcraft.webp": webp("A10"), "FileTypes/psd.png": tealPNG,
        ])
        let at = { (name: String) in solid.appendingPathComponent(name).path }
        let listed = try PublishedPacks.packs(from: JSONSerialization.data(withJSONObject: [[
            "ID": "Craft-Icons-Checks/Left out", "Name": "Left out", "Author": "Checks", "Status": "Downloaded",
            "Icons": ["PhotoCraft": at("PhotoCraft.webp"), "GridCraft": at("GridCraft.webp")],
            "FileIcons": [".pcraft": at("FileTypes/pcraft.webp"), ".psd": at("FileTypes/psd.png")], "AppFileIcons": [String: String](),
            "CanApps": true, "CanFiles": true, "HasPreview": false, "HasFilePreview": false,
        ] as [String: Any]]))
        let leftOutHost = try startHost(leftOutFixture.install)
        defer { retire([leftOutHost]) }
        _ = await settled(leftOutHost)
        leftOutHost.builtins = listed
        _ = await js(leftOutHost, "send('select', {id: 'Craft-Icons-Checks/Left out', group: 'apps'}); true")
        let appsNote = await statusUntil(leftOutHost, "App icon pack selected. Left out: GridCraft. Animated WebP artwork is not supported.")
        _ = await settled(leftOutHost)
        _ = await js(leftOutHost, "send('select', {id: 'Craft-Icons-Checks/Left out', group: 'files'}); true")
        let filesNote = await statusUntil(
            leftOutHost, "File type icon pack selected. Left out: .pcraft. The file is named .webp but is not a WebP image.")
        try check(
            appsNote && filesNote,
            "choosing a pack with items that cannot be used names them on the status line, in the app list and in the file type list")

        // A file type pack with art only for other file types.
        let lightFixture = try fixture("light-only", [("Light", ["FileTypes/LightCraft-files.png": plumPNG])])
        _ = try updatePreferences(lightFixture.install.state) { $0.fileSelected = lightFixture.ids[0] }
        let lightHost = try startHost(lightFixture.install)
        defer { retire([lightHost]) }
        let lightShown = await jsUntil(
            lightHost, "el('fileDetail').textContent === 'Other LightCraft files / Personal pack' && !el('applyFiles').disabled")
        try check(lightShown, "with a file type pack that draws only other file types, Manage Icons names them and Apply file icons… stays available")
    }
    /// This round's checks: WebP pack artwork and the art for unlisted file types. They need no network.
    @MainActor static func roundM(resources: URL, out: URL) async throws {
        try await part("webp") { try webpChecks(resources: resources, root: out.appendingPathComponent("webp")) }
        try await part("webp page") { try await webpPage(root: out.appendingPathComponent("webp-page")) }
        try await part("unlisted") { try await unlistedChecks(resources: resources, root: out.appendingPathComponent("unlisted")) }
        try await part("unlisted end to end") {
            try await openerEndToEnd(resources: resources, root: out.appendingPathComponent("unlisted-e2e"))
        }
        try await part("icon changes together") { try iconChangesTogether(root: out.appendingPathComponent("icon-changes")) }
        try await roundMFixes(resources: resources, out: out)
    }
    /// The fixes after the review of this round's file icon work.
    @MainActor static func roundMFixes(resources: URL, out: URL) async throws {
        try await part("unlisted fixes") {
            try await unlistedFixChecks(resources: resources, root: out.appendingPathComponent("unlisted-fixes"))
        }
        try await part("folder fixes in the app") {
            try await unlistedFixHostChecks(resources: resources, root: out.appendingPathComponent("folder-fixes"))
        }
    }
    /// The fixes after the review of this round's checks.
    @MainActor static func fixApps(resources: URL, out: URL) async throws {
        try await part("login fixes") { try await loginFixChecks(resources: resources, root: out.appendingPathComponent("fix-login")) }
        try await part("new app fixes") { try await newAppFixChecks(resources: resources, root: out.appendingPathComponent("fix-new-apps")) }
        try await part("download fixes") { try await offerFixChecks(resources: resources, root: out.appendingPathComponent("fix-offer")) }
    }
    /// The checks of this round: open at login, the first-start offer, each copy's artwork and new apps.
    @MainActor static func startupApps(resources: URL, out: URL) async throws {
        try await part("login item") { try await loginChecks(resources: resources, root: out.appendingPathComponent("login")) }
        try await part("download offer") { try await offerChecks(resources: resources, root: out.appendingPathComponent("offer")) }
        try await part("launcher artwork") { try await gridChecks(resources: resources, root: out.appendingPathComponent("grid")) }
        try await part("new apps") { try await newAppChecks(resources: resources, root: out.appendingPathComponent("new-apps")) }
    }
    /// Run one group of checks. In soft mode a group that stops early is reported and the run goes on. With
    /// BETTERICON_TEST_ONLY set, only the groups whose name contains it run.
    @MainActor static func part(_ name: String, _ body: () async throws -> Void) async throws {
        if let only = ProcessInfo.processInfo.environment["BETTERICON_TEST_ONLY"], !name.contains(only) { return }
        guard soft else { return try await body() }
        do { try await body() } catch {
            print("FAIL: the \(name) checks stopped: " + error.localizedDescription)
            softFailures += 1
        }
    }
    /// The checks that answer the app's modal alerts run in a process of their own around a real application run
    /// loop, as BetterIcon itself runs. This process has no such loop: a modal session ended inside it can end the
    /// whole run.
    @MainActor static func runAlertApp(resources: URL, out: URL) {
        let app = NSApplication.shared
        soft = true
        Task { @MainActor in
            try? await part("review during a pass") {
                try await reviewDuringPass(resources: resources, root: out.appendingPathComponent("review-pass"))
            }
            try? await part("review during a refresh") {
                try await reviewDuringRefresh(resources: resources, root: out.appendingPathComponent("review-refresh"))
            }
            try? await part("restore label") {
                try await restoreLabel(resources: resources, root: out.appendingPathComponent("restore-label"))
            }
            print("\(checks) checks passed, \(softFailures) failed.")
            exit(softFailures == 0 ? 0 : 1)
        }
        app.run()
    }
    /// Runs the alert checks in their own process and counts each of its results here, under the same title.
    @MainActor static func alertChecks(resources: URL, out: URL) async throws {
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let log = out.appendingPathComponent("alert-checks.txt")
        guard fm.createFile(atPath: log.path, contents: nil), let output = FileHandle(forWritingAtPath: log.path) else {
            throw Problem("could not create the alert check log")
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        child.arguments = ["--alerts", resources.path, out.path]
        child.standardOutput = output
        child.standardError = output
        try child.run()
        for _ in 0..<1200 where child.isRunning { try await Task.sleep(nanoseconds: 100_000_000) }
        if child.isRunning {
            child.terminate()
            throw Problem("Timed out waiting for the alert checks.")
        }
        try output.close()
        let lines = String(decoding: try Data(contentsOf: log), as: UTF8.self).split(separator: "\n").map(String.init)
        for line in lines where line.hasPrefix("PASS: ") || line.hasPrefix("FAIL: ") {
            try check(line.hasPrefix("PASS: "), String(line.dropFirst(6)))
        }
        try check(
            child.terminationReason == .exit && child.terminationStatus == 0 && lines.contains { $0.hasSuffix("0 failed.") },
            "the checks that answer the app's alerts ran to the end in their own process")
    }
    /// The checks of putting icons back after updates, after the store's own.
    @MainActor static func reapplyApps(resources: URL, out: URL) async throws {
        try await part("keeper") { try await keeperChecks(resources: resources, root: out.appendingPathComponent("keeper")) }
        try await part("alerts") { try await alertChecks(resources: resources, out: out.appendingPathComponent("alerts")) }
        try await part("late folder") { try await lateFolder(resources: resources, root: out.appendingPathComponent("late-folder")) }
    }
    /// The checks run in a task of their own while the main run loop runs here. This process has no application run loop,
    /// so AppKit can stop the main run loop, as when a modal session ends in it, and the asynchronous main's own loop then
    /// ends the whole process early. That happened in round M while someone used the Mac during a run. This loop runs again
    /// instead, until the checks end the run themselves, and CheckApplication notes what asked for the stop. The helper
    /// processes some checks start (--set-icon, --quit-menu and --alerts) run as before.
    @MainActor static func main() async {
        _ = CheckApplication.shared
        if CommandLine.arguments.count == 4, ["--set-icon", "--quit-menu", "--alerts"].contains(CommandLine.arguments[1]) {
            return await run()
        }
        Task { @MainActor in
            await run()
            exit(0)
        }
        keepRunning()
    }
    /// Run the main run loop for good: each time something stops it, it runs again.
    static func keepRunning() -> Never {
        while true {
            if !RunLoop.main.run(mode: .default, before: .distantFuture) { usleep(10_000) }
        }
    }
    @MainActor static func run() async {
        do {
            if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--set-icon" {
                // Another process changes an app's icon, as Finder's Get Info does. "none" removes the custom icon.
                _ = NSApplication.shared
                let art = CommandLine.arguments[2]
                let image = art == "none" ? nil : NSImage(contentsOfFile: art)
                guard art == "none" || image != nil else { exit(2) }
                exit(NSWorkspace.shared.setIcon(image, forFile: CommandLine.arguments[3], options: []) ? 0 : 1)
            }
            if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--quit-menu" {
                try runQuitMenuApp(resources: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true),
                    fixture: URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true))
                return
            }
            if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--alerts" {
                runAlertApp(resources: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true),
                    out: URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true))
                return
            }
            if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--reapply-only" {
                // Only the checks of putting icons back after updates. They need no network.
                soft = ProcessInfo.processInfo.environment["BETTERICON_TEST_SOFT"] == "1"
                _ = NSApplication.shared
                RunGuard.install()
                let resources = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
                    .appendingPathComponent("Contents/Resources")
                let out = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true).resolvingSymlinksInPath()
                guard !fm.fileExists(atPath: out.path) else { throw Problem("Choose a new fixture directory.") }
                try await part("store") { try reapply(resources: resources, root: out.appendingPathComponent("reapply")) }
                try await part("app on a fixture") {
                    try await reapplyUI(resources: resources, root: out.appendingPathComponent("reapply-ui"))
                }
                try await reapplyApps(resources: resources, out: out)
                print("\(checks) checks passed, \(softFailures) failed. \(out.path)")
                RunGuard.end(softFailures == 0 ? 0 : 1)
            }
            if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--new-only" {
                // Only this round's checks: open at login, the first-start offer, each copy's artwork and new apps.
                // They need no network.
                soft = ProcessInfo.processInfo.environment["BETTERICON_TEST_SOFT"] == "1"
                _ = NSApplication.shared
                RunGuard.install()
                let resources = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
                    .appendingPathComponent("Contents/Resources")
                let out = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true).resolvingSymlinksInPath()
                guard !fm.fileExists(atPath: out.path) else { throw Problem("Choose a new fixture directory.") }
                try await startupApps(resources: resources, out: out)
                print("\(checks) checks passed, \(softFailures) failed. \(out.path)")
                RunGuard.end(softFailures == 0 ? 0 : 1)
            }
            if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--round-m-only" {
                // Only the checks of WebP pack artwork and of the art for unlisted file types. They need no network.
                soft = ProcessInfo.processInfo.environment["BETTERICON_TEST_SOFT"] == "1"
                _ = NSApplication.shared
                RunGuard.install()
                let resources = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
                    .appendingPathComponent("Contents/Resources")
                let out = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true).resolvingSymlinksInPath()
                guard !fm.fileExists(atPath: out.path) else { throw Problem("Choose a new fixture directory.") }
                try await roundM(resources: resources, out: out)
                print("\(checks) checks passed, \(softFailures) failed. \(out.path)")
                RunGuard.end(softFailures == 0 ? 0 : 1)
            }
            if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--m-fix-only" {
                // Only the checks of the fixes after the review of this round's file icon work. They need no network.
                soft = ProcessInfo.processInfo.environment["BETTERICON_TEST_SOFT"] == "1"
                _ = NSApplication.shared
                RunGuard.install()
                let resources = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
                    .appendingPathComponent("Contents/Resources")
                let out = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true).resolvingSymlinksInPath()
                guard !fm.fileExists(atPath: out.path) else { throw Problem("Choose a new fixture directory.") }
                try await roundMFixes(resources: resources, out: out)
                print("\(checks) checks passed, \(softFailures) failed. \(out.path)")
                RunGuard.end(softFailures == 0 ? 0 : 1)
            }
            if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--core-only" {
                // Only the core checks, which download four packs.
                soft = ProcessInfo.processInfo.environment["BETTERICON_TEST_SOFT"] == "1"
                _ = NSApplication.shared
                RunGuard.install()
                let resources = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
                    .appendingPathComponent("Contents/Resources")
                let out = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true).resolvingSymlinksInPath()
                guard !fm.fileExists(atPath: out.path) else { throw Problem("Choose a new fixture directory.") }
                try await part("core") { _ = try core(resources: resources, root: out) }
                print("\(checks) checks passed, \(softFailures) failed. \(out.path)")
                RunGuard.end(softFailures == 0 ? 0 : 1)
            }
            if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--fix-only" {
                // Only the checks of the fixes after the review of this round. They need no network.
                soft = ProcessInfo.processInfo.environment["BETTERICON_TEST_SOFT"] == "1"
                _ = NSApplication.shared
                RunGuard.install()
                let resources = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
                    .appendingPathComponent("Contents/Resources")
                let out = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true).resolvingSymlinksInPath()
                guard !fm.fileExists(atPath: out.path) else { throw Problem("Choose a new fixture directory.") }
                try await fixApps(resources: resources, out: out)
                print("\(checks) checks passed, \(softFailures) failed. \(out.path)")
                RunGuard.end(softFailures == 0 ? 0 : 1)
            }
            guard CommandLine.arguments.count == 3 else {
                throw Problem("Usage: Checks /path/to/BetterIcon.app empty-test-directory")
            }
            _ = NSApplication.shared
            RunGuard.install()
            try shortcuts()
            let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
                .appendingPathComponent("Contents/Resources")
            let out = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).resolvingSymlinksInPath()
            guard !fm.fileExists(atPath: out.path) else { throw Problem("Choose a new fixture directory.") }
            let install = try core(resources: resources, root: out)
            try reapply(resources: resources, root: out.appendingPathComponent("reapply"))
            try await ui(install, out: out)
            try await reapplyApps(resources: resources, out: out)
            try await tabWindows(resources: resources, root: out.appendingPathComponent("tab-sizes"))
            try await checkQuitMenu(resources: resources, fixture: out)
            // Last, so the many apps they start leave the earlier checks' menu bar as it was.
            try await startupApps(resources: resources, out: out)
            try await fixApps(resources: resources, out: out)
            try await roundM(resources: resources, out: out)
            print("\(checks) checks passed. \(out.path)")
            RunGuard.finished = true
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            RunGuard.end(1)
        }
    }
}

/// Stands in for macOS's login items, so the suite never registers a real one. Its state is what macOS would report.
final class FakeLoginItem: LoginItem {
    var state = LoginItemState.off
    var unavailable: String?
    /// What a registration leaves: enabled, or waiting for the user's approval as when macOS asks first.
    var registers = LoginItemState.enabled
    private(set) var registrations = 0, unregistrations = 0
    /// How often BetterIcon opened System Settings at its Login Items.
    private(set) var settingsOpened = 0
    func register() throws {
        registrations += 1
        state = registers
    }
    func unregister() throws {
        unregistrations += 1
        state = .off
    }
    func openSettings() { settingsOpened += 1 }
}

/// Keeps a check run from ending early without a word. Every app the checks start puts its icon in the menu bar, and a
/// click there, such as on Exit BetterIcon in one of their menus, asks AppKit to quit this process. With no delegate AppKit
/// exits with status 0 before the summary is printed, which looks like a pass. The guard refuses the quit, and any other
/// early exit fails the run.
final class RunGuard: NSObject, NSApplicationDelegate {
    static let shared = RunGuard()
    /// Set just before the run ends on purpose.
    static var finished = false
    /// The modal window seen last, so each one is reported once.
    private static weak var modal: NSWindow?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        FileHandle.standardError.write(Data("BetterIcon checks: a request to quit the check run was refused.\n".utf8))
        return .terminateCancel
    }
    static func install() {
        NSApp.delegate = shared
        // No check in this process shows a modal window. One that appears, as when someone chooses an item in a test
        // app's menu bar menu, is reported with its text.
        let watch = Timer(timeInterval: 0.5, repeats: true) { _ in
            guard let window = NSApp.modalWindow, window !== modal else { return }
            modal = window
            var texts = [String]()
            func walk(_ view: NSView) {
                if let field = view as? NSTextField { texts.append(field.stringValue) }
                if let button = view as? NSButton, !button.title.isEmpty { texts.append("[" + button.title + "]") }
                view.subviews.forEach(walk)
            }
            window.contentView.map(walk)
            FileHandle.standardError.write(Data("BetterIcon checks: a modal window appeared at \(Date()): \(texts.joined(separator: " | "))\n".utf8))
        }
        RunLoop.main.add(watch, forMode: .common)
        atexit {
            guard !RunGuard.finished else { return }
            fflush(stdout)
            // The stack shows what ended the run.
            let message = "FAILED: the check run ended before its last check.\n"
                + Thread.callStackSymbols.joined(separator: "\n") + "\n"
            _ = message.withCString { write(2, $0, strlen($0)) }
            _exit(1)
        }
    }
    /// End the run on purpose with this status.
    static func end(_ status: Int32) -> Never {
        finished = true
        exit(status)
    }
}

/// The application object of the check process. It reports each request to stop the main run loop or a modal session,
/// with what asked for it, so a run that such a stop would have ended says why.
final class CheckApplication: NSApplication {
    static func note(_ what: String) {
        let text = "BetterIcon checks: \(what) at \(Date()).\n" + Thread.callStackSymbols.prefix(14).joined(separator: "\n") + "\n"
        FileHandle.standardError.write(Data(text.utf8))
    }
    override func stop(_ sender: Any?) {
        Self.note("NSApplication.stop")
        super.stop(sender)
    }
    override func stopModal() {
        Self.note("stopModal")
        super.stopModal()
    }
    override func stopModal(withCode returnCode: NSApplication.ModalResponse) {
        Self.note("stopModal(withCode:)")
        super.stopModal(withCode: returnCode)
    }
    override func abortModal() {
        Self.note("abortModal")
        super.abortModal()
    }
}

/// The pack IDs a stand-in for the helper's acquire was asked for, from any thread.
final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var items = [String]()
    func add(_ item: String) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }
    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// Stands in for Launch Services in the checks of the art for unlisted file types: the app that opens a file, by the
/// file's path or else its extension, and the ArtCraft app an app is. The watcher's queue reads it too.
final class OpenerTable: @unchecked Sendable {
    private let lock = NSLock()
    private var byExtension = [String: URL](), byFile = [String: URL](), crafts = [String: String]()
    func open(_ ext: String, with app: URL) {
        lock.lock()
        byExtension[ext] = app
        lock.unlock()
    }
    /// A choice of one file's own, as with Get Info's Open with. Nil takes it away.
    func open(_ file: URL, with app: URL?) {
        lock.lock()
        byFile[file.path] = app
        lock.unlock()
    }
    func name(_ app: URL, _ craft: String) {
        lock.lock()
        crafts[app.path] = craft
        lock.unlock()
    }
    func opener(_ file: URL) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return byFile[file.path] ?? byExtension[file.pathExtension.lowercased()]
    }
    func craft(_ app: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return crafts[app.path]
    }
}

/// Answers the file panel and the alerts of the apps in this process while it is installed: NSOpenPanel's runModal and
/// URLs and NSAlert's runModal are replaced, and put back by `remove`. No check in this process can run a modal session,
/// and the file panel and confirmations of Apply file icons… and Restore file icons… are modal. Each panel's allowed types
/// and each alert are kept. Used on the main thread only.
enum ModalStub {
    static var urls = [URL]()
    static var response = NSApplication.ModalResponse.cancel
    static var panels = [[UTType]]()
    static var alerts = [(title: String, info: String, buttons: [String])]()
    /// The title of the button to press, from the alert's title and buttons; nil presses the last one.
    static var answer: (String, [String]) -> String? = { _, _ in nil }
    private static var replaced = [(cls: AnyClass, selector: Selector, original: IMP)]()
    static func install() {
        guard replaced.isEmpty else { return }
        let run: @convention(block) (AnyObject) -> Int = { object in
            if let panel = object as? NSSavePanel { ModalStub.panels.append(panel.allowedContentTypes) }
            return ModalStub.response.rawValue
        }
        let chosen: @convention(block) (AnyObject) -> NSArray = { _ in ModalStub.urls.map { $0 as NSURL } as NSArray }
        let alert: @convention(block) (AnyObject) -> Int = { object in
            let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard let alert = object as? NSAlert else { return first }
            let buttons = alert.buttons.map(\.title)
            ModalStub.alerts.append((alert.messageText, alert.informativeText, buttons))
            let pick = ModalStub.answer(alert.messageText, buttons).flatMap { buttons.firstIndex(of: $0) } ?? max(0, buttons.count - 1)
            return first + pick
        }
        var targets = [(cls: AnyClass, selector: Selector, block: AnyObject)]()
        var panelClasses: [AnyClass] = [NSOpenPanel.self]
        if let actual = object_getClass(NSOpenPanel()), actual !== NSOpenPanel.self { panelClasses.append(actual) }
        for cls in panelClasses {
            targets.append((cls, #selector(NSSavePanel.runModal), unsafeBitCast(run, to: AnyObject.self)))
            targets.append((cls, #selector(getter: NSOpenPanel.urls), unsafeBitCast(chosen, to: AnyObject.self)))
        }
        var alertClasses: [AnyClass] = [NSAlert.self]
        if let actual = object_getClass(NSAlert()), actual !== NSAlert.self { alertClasses.append(actual) }
        for cls in alertClasses { targets.append((cls, #selector(NSAlert.runModal), unsafeBitCast(alert, to: AnyObject.self))) }
        // Every original first: a subclass that inherits a method would otherwise record the replacement as its original.
        let methods = targets.compactMap { target in
            class_getInstanceMethod(target.cls, target.selector).map { (target, $0, method_getImplementation($0)) }
        }
        for (target, method, original) in methods {
            class_replaceMethod(target.cls, target.selector, imp_implementationWithBlock(target.block), method_getTypeEncoding(method))
            replaced.append((target.cls, target.selector, original))
        }
    }
    static func remove() {
        for item in replaced.reversed() {
            if let method = class_getInstanceMethod(item.cls, item.selector) { method_setImplementation(method, item.original) }
        }
        replaced = []
    }
}

/// The largest footprint a sampler thread saw, and whether it should go on sampling.
final class FootprintPeak: @unchecked Sendable {
    private let lock = NSLock()
    private var highest: Int64
    private var going = true
    init(_ start: Int64) { highest = start }
    var running: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return going
        }
        set {
            lock.lock()
            going = newValue
            lock.unlock()
        }
    }
    func note(_ value: Int64) {
        lock.lock()
        highest = max(highest, value)
        lock.unlock()
    }
    var peak: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return highest
    }
}

/// Hands an object that guards its own state to another thread.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Answers the app's modal alerts from a timer, as a person would. `answer` gets each alert's text and buttons and
/// returns the button to press, or nil to leave the alert open for now. Every alert it sees is kept in `seen`.
final class AlertDriver: NSObject {
    struct Alert {
        let text: String
        let buttons: [String]
    }
    private(set) var seen = [Alert]()
    private let answer: (Alert) -> String?
    private var timer: Timer?
    private weak var current: NSWindow?
    private weak var answered: NSWindow?
    init(_ answer: @escaping (Alert) -> String?) {
        self.answer = answer
        super.init()
        let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        // Common modes include the one a modal alert runs in.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func stop() {
        timer?.invalidate()
        timer = nil
    }
    @objc private func tick() {
        guard let window = NSApp.modalWindow, window !== answered, let content = window.contentView else { return }
        var texts = [String](), buttons = [NSButton]()
        func walk(_ view: NSView) {
            if let button = view as? NSButton {
                if !button.title.isEmpty { buttons.append(button) }
            } else if let field = view as? NSTextField {
                texts.append(field.stringValue)
            } else if let text = view as? NSTextView {
                texts.append(text.string)
            }
            view.subviews.forEach(walk)
        }
        walk(content)
        let alert = Alert(text: texts.joined(separator: "\n"), buttons: buttons.map(\.title))
        if window !== current {
            current = window
            seen.append(alert)
        }
        guard let pick = answer(alert), let button = buttons.first(where: { $0.title == pick }) else { return }
        answered = window
        button.performClick(nil)
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
