import AppKit
import CryptoKit

struct Problem: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

let fm = FileManager.default
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func saved<T: Decodable>(_ type: T.Type, at url: URL, fallback: T) throws -> T {
    guard fm.fileExists(atPath: url.path) else { return fallback }
    return try JSONDecoder().decode(type, from: Data(contentsOf: url))
}
func save<T: Encodable>(_ value: T, at url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
}

enum Craft {
    static let names = [
        "AniCraft", "ArtCraftLauncher", "CADCraft", "CraftAnything", "DeckCraft", "DesignCraft",
        "EffectCraft", "FigCraft", "FilmCraft", "GridCraft", "LightCraft", "MailCraft", "MaterialCraft",
        "PdfCraft", "PhotoCraft", "SolidCraft", "SoundCraft", "TextureCraft", "VectorCraft", "WordCraft",
    ]
    static let matches: [(String, NSRegularExpression)] = names.map { name in
        let pattern =
            ["CraftAnything": "Craft[\\s_-]*Anything", "ArtCraftLauncher": "ArtCraft[\\s_-]*Launcher"][name]
            ?? name
        return (
            name, try! NSRegularExpression(pattern: "^" + pattern + "(?:[\\s_.-].*)?$", options: .caseInsensitive)
        )
    }
    static func canonical(_ name: String) -> String? {
        if name.range(
            of: #"(?:^|[\W_])(uninstall|uninstaller|remove|setup|help|documentation)(?:[\W_]|$)"#,
            options: [.regularExpression, .caseInsensitive]) != nil
        {
            return nil
        }
        let range = NSRange(name.startIndex..., in: name)
        return matches.first { $0.1.firstMatch(in: name, range: range) != nil }?.0
    }
    /// Each app's pattern for the name, without its extension, of FileTypes art that draws every file type the app opens,
    /// listed or not: ignoring case, ^<App>[ _.-]files$, with ArtCraft[ _-]*Launcher and Craft[ _-]*Anything for the two
    /// names artists may split. It is the pack helper's rule (allFilesNames in Shared/packstore/catalog.go). The space is a
    /// literal ASCII space: \s would also match the Unicode spaces the helper refuses.
    static let allFiles: [(String, NSRegularExpression)] = names.map { name in
        let pattern = ["CraftAnything": "Craft[ _-]*Anything", "ArtCraftLauncher": "ArtCraft[ _-]*Launcher"][name] ?? name
        return (name, try! NSRegularExpression(pattern: "^" + pattern + "[ _.-]files$", options: .caseInsensitive))
    }
    /// The app whose art for all of its files a FileTypes file name (without its extension) names explicitly, such as
    /// PhotoCraft-files, or nil. Only such art also draws the file types outside BetterIcon's list: art named for a
    /// format, such as PhotoCraft-PSD, stays with the app's listed formats.
    static func allFilesApp(_ stem: String) -> String? {
        let range = NSRange(stem.startIndex..., in: stem)
        return allFiles.first { $0.1.firstMatch(in: stem, range: range) != nil }?.0
    }
    /// How lists name an app: ArtCraft Launcher and Craft Anything with their space, the others by their key.
    static func displayName(_ craft: String) -> String {
        ["ArtCraftLauncher": "ArtCraft Launcher", "CraftAnything": "Craft Anything"][craft] ?? craft
    }
}

enum Scope: String, Codable { case personal, shared }
struct AppEntry: Hashable {
    let name: String
    let craft: String
    let url: URL
    let launchURL: URL
    let bundleID: String
    let scope: Scope
    var isDocument = false
    var isAlias: Bool { url != launchURL }
    var usesFileFork: Bool { isDocument || isAlias }
}

struct AppCatalog {
    let locations: [(URL, Scope)]
    let includeSystemReferences: Bool
    init(locations: [(URL, Scope)]? = nil) {
        includeSystemReferences = locations == nil
        self.locations =
            locations ?? [
                (fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"), .personal),
                (fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"), .personal),
                (URL(fileURLWithPath: "/Applications"), .shared),
            ]
    }
    private func entry(_ item: URL, scope: Scope) -> AppEntry? {
        guard let values = try? item.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey]),
            values.isSymbolicLink != true
        else { return nil }
        let url = item.standardizedFileURL
        let target: URL
        if values.isAliasFile == true {
            guard let resolved = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]),
                resolved.pathExtension.lowercased() == "app"
            else { return nil }
            target = resolved.standardizedFileURL
        } else {
            guard item.pathExtension.lowercased() == "app" else { return nil }
            target = url
        }
        let basename = url.deletingPathExtension().lastPathComponent
        guard let found = Self.identify(target) else { return nil }
        return AppEntry(name: basename, craft: found.craft, url: url, launchURL: target, bundleID: found.bundleID, scope: scope)
    }
    /// The ArtCraft app an app bundle is, and its bundle ID: by a Storyteller bundle ID, or else by the bundle's name.
    /// The bundle needs a bundle ID and its main executable.
    static func identify(_ bundle: URL) -> (craft: String, bundleID: String)? {
        // Read from the files. Bundle keeps what it read first for the life of the process, so a copy looked at before
        // its Info.plist arrived would never be recognized.
        guard let info = bundleInfo(bundle), let id = info["CFBundleIdentifier"] as? String, !id.isEmpty,
            let exe = executable(bundle, info), fm.isExecutableFile(atPath: exe.path)
        else { return nil }
        let official =
            id.lowercased().hasPrefix("ai.storyteller.")
            ? Craft.canonical(String(id.dropFirst("ai.storyteller.".count))) : nil
        guard let craft = official ?? Craft.canonical(bundle.deletingPathExtension().lastPathComponent) else {
            return nil
        }
        return (craft, id)
    }
    /// An app bundle's Info.plist, read from the file.
    static func bundleInfo(_ bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }
    /// The main executable an app bundle's Info.plist names.
    static func executable(_ bundle: URL, _ info: [String: Any]) -> URL? {
        guard let name = info["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/") else { return nil }
        return bundle.appendingPathComponent("Contents/MacOS/" + name)
    }
    /// Whether an .app folder is not whole yet, as while it is copied into place file by file: its Info.plist or its main
    /// executable is not there yet. A whole bundle of another app is not unfinished.
    func unfinished(at url: URL) -> Bool {
        var isFolder: ObjCBool = false
        guard url.pathExtension.lowercased() == "app", fm.fileExists(atPath: url.path, isDirectory: &isFolder),
            isFolder.boolValue
        else { return false }
        guard let info = Self.bundleInfo(url), let exe = Self.executable(url, info) else { return true }
        return !fm.isExecutableFile(atPath: exe.path)
    }
    /// The entry for one app outside a full discovery, such as a copy the folder watcher saw arrive.
    func app(at url: URL) -> AppEntry? {
        let path = url.standardizedFileURL.path
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path + "/"
        let scope =
            locations.first { path.hasPrefix($0.0.standardizedFileURL.path + "/") }?.1
            ?? (path.hasPrefix(home) ? .personal : .shared)
        return entry(url, scope: scope)
    }
    /// The folders discovery looks in. Discovery reads only the top level of the Desktop.
    func roots(extraFolders: [URL] = []) -> [(url: URL, topLevel: Bool)] {
        let desktop = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path
        return locations.map { (url: $0.0, topLevel: includeSystemReferences && $0.0.path == desktop) }
            + extraFolders.map { (url: $0, topLevel: false) }
    }
    static func dockURLs(_ tiles: [[String: Any]]) -> [URL] {
        tiles.compactMap { tile in
            guard let data = tile["tile-data"] as? [String: Any], let file = data["file-data"] as? [String: Any],
                let string = file["_CFURLString"] as? String, let url = URL(string: string), url.isFileURL
            else { return nil }
            return url
        }
    }
    /// The apps the Launcher and the menu bar's launch menu show: one per app copy that opens. An alias, such as one on
    /// the Desktop, shares the entry of the app it opens when that app is listed too; the app itself is then the entry.
    /// Apply and Restore still work on every entry. The order is kept.
    static func launchEntries(_ apps: [AppEntry]) -> [AppEntry] {
        var best = [String: Int]()
        for (index, app) in apps.enumerated() {
            let key = app.launchURL.standardizedFileURL.path
            guard let held = best[key] else { best[key] = index; continue }
            let current = apps[held]
            func rank(_ entry: AppEntry) -> Int { (entry.isAlias ? 2 : 0) + (entry.scope == .shared ? 1 : 0) }
            if rank(app) < rank(current) { best[key] = index }
        }
        let kept = Set(best.values)
        return apps.enumerated().filter { kept.contains($0.offset) }.map(\.element)
    }
    func discover(extraFolders: [URL] = []) -> [AppEntry] {
        var entries = [String: AppEntry]()
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path + "/"
        let extra: [(URL, Scope)] = extraFolders.map {
            ($0, $0.standardizedFileURL.path.hasPrefix(home) ? .personal : .shared)
        }
        for (root, scope) in locations + extra {
            let keys: [URLResourceKey] = [.isAliasFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
            var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
            if includeSystemReferences
                && root.path == fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path
            {
                options.insert(.skipsSubdirectoryDescendants)
            }
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: options) else {
                continue
            }
            for case let item as URL in walker {
                guard let values = try? item.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isSymbolicLink == true {
                    walker.skipDescendants()
                    continue
                }
                let alias = values.isAliasFile == true
                guard alias || item.pathExtension.lowercased() == "app" else { continue }
                walker.skipDescendants()
                if let app = entry(item, scope: scope) { entries[app.url.path] = app }
            }
        }
        if includeSystemReferences {
            let tiles =
                CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString)
                as? [[String: Any]] ?? []
            let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
            let aliased = entries.values.filter(\.isAlias).map(\.launchURL)
            for url in Self.dockURLs(tiles) + running + aliased {
                let url = url.standardizedFileURL
                if entries[url.path] != nil || url.path.contains("/AppTranslocation/") { continue }
                if let app = entry(url, scope: url.path.hasPrefix(home) ? .personal : .shared) {
                    entries[app.url.path] = app
                }
            }
        }
        return entries.values.sorted {
            // ArtCraft Launcher leads the grid. The other apps follow by name.
            if ($0.craft == Pack.lead) != ($1.craft == Pack.lead) { return $0.craft == Pack.lead }
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.url.path < $1.url.path : order == .orderedAscending
        }
    }
}

struct Pack {
    let id: String
    let name: String
    let author: String
    let icons: [String: URL]
    var personal = false
    // documents draws one file format. appFiles draws every file type an app opens.
    var documents = [String: URL]()
    var appFiles = [String: URL]()
    var status = "Local"
    var canApps = true
    var canFiles = false
    var hasPreview = false
    // The artwork in a published pack's FileTypes folder has a strip of its own.
    var hasFilePreview = false
    var previousIDs = [String]()
    /// Art for files of the types outside BetterIcon's list, by the ArtCraft app that opens them by default: a published
    /// pack's art for all of an app's files when the helper says the app opts in (its art is named FileTypes/<App>-files),
    /// or a personal pack's stored art of that kind. Listed formats never take it.
    var unlisted = [String: URL]()
    /// Items none of whose files can be used, so they are left out: how lists name the item, and why.
    var leftOut = [String: String]()
    var canPreview: Bool { hasPreview || !icons.isEmpty || !documents.isEmpty || !appFiles.isEmpty }
    /// The file type list shows a pack's file artwork. A pack of file artwork alone has one published strip.
    var canFilePreview: Bool {
        hasFilePreview || (hasPreview && !canApps) || !documents.isEmpty || !appFiles.isEmpty || !unlisted.isEmpty
    }
    var model: [String: Any] {
        ["id": id, "title": title, "status": isDefault ? "Default" : status, "default": isDefault,
         "personal": personal, "canApps": canApps, "canFiles": canFiles || isDefault, "hasPreview": canPreview,
         "hasFilePreview": canFilePreview]
    }
    var isDefault: Bool { id == "ArtCraft/Default" }
    var title: String {
        if isDefault { return name }
        let credit = name == "Root" && !personal ? author : name + (author.isEmpty ? "" : " / " + author)
        return credit + (personal ? " (personal)" : "")
    }
    static let defaults = Pack(id: "ArtCraft/Default", name: "ArtCraft default", author: "", icons: [:])
    /// The app whose icon leads every grid of app icons.
    static let lead = "ArtCraftLauncher"
    /// Lists show each author's packs together, by name.
    static func listed(_ a: Pack, _ b: Pack) -> Bool {
        let byAuthor = a.author.localizedCaseInsensitiveCompare(b.author)
        if byAuthor != .orderedSame { return byAuthor == .orderedAscending }
        let byName = a.name.localizedCaseInsensitiveCompare(b.name)
        return byName == .orderedSame ? a.id < b.id : byName == .orderedAscending
    }
    /// What the status line adds after the pack is chosen in the app list or the file type list, when items of that list
    /// were left out: "Left out: {names}. {cause}", with at most three names in the order the list draws them, and the
    /// cause of the first. File items are formats, such as .pcraft, and art for all of an app's files, such as
    /// "PhotoCraft files". Nil when nothing of that list was left out.
    func leftOutNote(files: Bool, formats: [ProjectFormat] = []) -> String? {
        let isFile = { (name: String) in name.hasPrefix(".") || name.hasSuffix(" files") }
        let names = leftOut.keys.filter { isFile($0) == files }
        guard !names.isEmpty else { return nil }
        let order = Dictionary(formats.enumerated().map { ($1.Key, $0) }, uniquingKeysWith: { first, _ in first })
        let owner = Dictionary(formats.map { ($0.Key, $0.Application) }, uniquingKeysWith: { first, _ in first })
        let app = { (name: String) in name.replacingOccurrences(of: " ", with: "") }
        let sorted: [String]
        if files {
            // As the file list draws them: by app, the art for all of an app's files first, then each format.
            let key = { (name: String) -> (String, Int, Int) in
                name.hasPrefix(".")
                    ? ((owner[name] ?? "").lowercased(), 1, order[name] ?? Int.max)
                    : (app(String(name.dropLast(" files".count))).lowercased(), 0, 0)
            }
            sorted = names.sorted { key($0) < key($1) || (key($0) == key($1) && $0 < $1) }
        } else {
            // As the grids draw them: ArtCraft Launcher first, then the other apps.
            let key = { (name: String) -> (Int, String) in (app(name) == Pack.lead ? 0 : 1, app(name)) }
            sorted = names.sorted { key($0) < key($1) }
        }
        let shown: String
        switch sorted.count {
        case 1: shown = sorted[0]
        case 2: shown = sorted[0] + " and " + sorted[1]
        case 3: shown = sorted[0] + ", " + sorted[1] + " and " + sorted[2]
        default: shown = sorted.prefix(3).joined(separator: ", ") + " and \(sorted.count - 3) more"
        }
        return "Left out: \(shown). \(leftOut[sorted[0]] ?? "")"
    }
}

/// One color scheme per BetterIcon app icon, exported from the Windows app.
struct Themes {
    static let styles = ["clay", "copper", "mauve", "ochre", "sage", "slate", "stone", "teal", "grayscale", "contrast"]
    private let schemes: [String: [String: [String: String]]]
    init(resources: URL) throws {
        schemes = try JSONDecoder().decode(
            [String: [String: [String: String]]].self,
            from: Data(contentsOf: resources.appendingPathComponent("Catalog/themes.json")))
        guard Themes.styles.allSatisfy({ style in ["dark", "light"].allSatisfy { Themes.color(schemes[style]?[$0]?["surface"]) != nil } })
        else { throw Problem("The app icon color schemes are incomplete.") }
    }
    func colors(_ style: String, dark: Bool) -> [String: String] {
        let mode = dark ? "dark" : "light"
        return schemes[style]?[mode] ?? schemes["sage"]?[mode] ?? [:]
    }
    static func color(_ hex: String?) -> NSColor? {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat(value >> 16 & 255) / 255, green: CGFloat(value >> 8 & 255) / 255,
            blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

/// A copy of an app that keeps its original icon: the user restored it, removed BetterIcon's icon from it, or it carries
/// an icon of the user's own. BetterIcon does not give it the applied pack by itself after a rename or a move, which
/// defaultPaths, a list of paths, cannot follow: both keep the copy's file ID. An app the user restored on its own also
/// keeps its original icon as a duplicate, which keeps its bundle ID.
struct RestoredApp: Codable, Hashable {
    let path: String
    let bundleID: String
    /// The bundle's device and file ID ("st_dev/st_ino") when it was noted.
    let copy: String?
    /// The user restored this app on its own, which covers its duplicates too.
    var chosen: Bool?
}
/// The device and file ID of the item at a path ("st_dev/st_ino"), or nil when nothing is there.
func fileCopy(_ path: String) -> String? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    return "\(st.st_dev)/\(st.st_ino)"
}

struct Preferences: Codable {
    var fileSelected: String?
    // The Launcher shows the pack that was last applied, with the artwork it had then.
    var appliedPack: String?
    var appliedArt: [String: String]?
    /// The locations the last Apply covered ("personal", "shared"), less a location restored since. A new ArtCraft app
    /// there gets the applied pack by itself. Empty when no location is covered, as after Restore app defaults. Nil for an
    /// Apply made before BetterIcon recorded it, until BetterIcon works the locations out once.
    var appliedScopes: [String]?
    /// The folders besides the standard apps folders ("Include another apps folder…") that the last Apply covered, as
    /// paths. A folder included later waits for the next Apply: the apps already in it are not new.
    var appliedFolders: [String]?
    /// Copies that keep their original icon wherever they go.
    var restoredApps: [RestoredApp]?
    /// A new installation offers once to download every pack. True until the offer is answered.
    var offerPacks: Bool?
    /// Packs chosen in that offer that have not downloaded yet. A quit midway leaves the rest for the next start.
    var pendingPacks: [String]?
    // Folders whose files keep a file type pack's icons: folder path to pack ID.
    var fileFolders: [String: String]?
    /// The pack a build that carried every pack opened with. A saved choice of it may never have been made by the user.
    static let openingPack = "Craft-Icons-Zach/Cardboard"
    var selected = Preferences.openingPack
    var size = 48
    var names = true
    var theme = "System"
    var color = "sage"
    var variant = "auto"
    var hotkey = KeyChoice()
    var defaultPaths = Set<String>()
    var folders = [URL]()
    var width = 900
    var height = 818
    var launcherWindowSize: NSSize?
    var manageWindowSize: NSSize?

    func windowSize(for tab: PopupTab) -> NSSize {
        // On upgrade each tab starts at the user's last shared window size.
        let legacy = NSSize(width: width > 0 ? width : 900, height: height > 0 ? height : 818)
        let saved = (tab == .launcher ? launcherWindowSize : manageWindowSize) ?? legacy
        let size = saved.width > 0 && saved.height > 0 ? saved : legacy
        return NSSize(width: max(tab.minimum.width, size.width), height: max(tab.minimum.height, size.height))
    }
    mutating func setWindowSize(_ size: NSSize, for tab: PopupTab) {
        if tab == .launcher { launcherWindowSize = size } else { manageWindowSize = size }
    }
    // The Launcher adopts a pack once macOS has accepted it for at least one app, and returns to the
    // original icons once every default was asked for. Apps restored one at a time are in defaultPaths.
    // A Restore of one location, while apps elsewhere still carry icons BetterIcon keeps up, keeps the pack
    // applied for them: the restored apps are in defaultPaths, and the others still get their icons back
    // after updates.
    mutating func noteApplied(_ plan: Review, _ result: IconResult, pack: Pack) {
        let every: Set<Scope> = [.personal, .shared]
        if plan.restore {
            guard !result.changed.isEmpty || !result.defaults.isEmpty else { return }
            guard plan.only == nil else {
                // An app restored on its own keeps its original icon, also as a renamed, moved or duplicated copy. A Restore
                // of a location takes that location out of the covered ones instead.
                remember(plan.rows.filter { result.defaults.contains($0.app.url.path) })
                return
            }
            if !result.othersKept {
                appliedPack = Pack.defaults.id
                appliedArt = nil
                // No location gets new apps the pack until the next Apply records its own.
                appliedScopes = []
                appliedFolders = []
            } else if let scope = plan.scope {
                // The restored location no longer gets the pack. New apps elsewhere still do.
                let covered = appliedScopes.map { Set($0.compactMap(Scope.init(rawValue:))) } ?? every
                appliedScopes = covered.subtracting([scope]).map(\.rawValue).sorted()
            }
        } else if !result.changed.isEmpty {
            appliedPack = pack.id
            // Keep the artwork as applied: the pack can later be edited, updated or removed.
            appliedArt = pack.icons.mapValues(\.path)
            if plan.only == nil {
                appliedScopes = (plan.scope.map { [$0] } ?? every).map(\.rawValue).sorted()
                // As saved, not standardized: standardizing drops /private only from a path that exists, and a folder can
                // be missing at the Apply and appear later.
                appliedFolders = folders.map(\.path)
            } else if appliedScopes == nil {
                // An Apply of one app leaves the locations as they were, and where none were recorded it covers none.
                appliedScopes = []
                appliedFolders = []
            }
            // The apps an Apply gave the pack are BetterIcon's to keep up again, and so are new copies of them.
            let changed = plan.rows.filter { result.changed.contains($0.app.url.path) }
            let ids = Set(changed.map(\.app.bundleID)), paths = Set(result.changed)
            let kept = (restoredApps ?? []).filter { !ids.contains($0.bundleID) && !paths.contains($0.path) }
            restoredApps = kept.isEmpty ? nil : kept
        }
    }
    /// Note apps the user restored on their own, with what identifies each copy.
    mutating func remember(_ rows: [ReviewRow]) {
        remember(rows.filter { !$0.app.isDocument && !$0.app.isAlias }.map { row in
            // The identity is "st_dev/st_ino/bundle ID/Info.plist digest".
            let parts = row.identity.split(separator: "/", omittingEmptySubsequences: false)
            return RestoredApp(
                path: row.app.url.path, bundleID: row.app.bundleID,
                copy: parts.count == 4 ? String(parts[0]) + "/" + String(parts[1]) : nil, chosen: true)
        })
    }
    mutating func remember(_ apps: [RestoredApp]) {
        guard !apps.isEmpty else { return }
        var kept = restoredApps ?? []
        for app in apps {
            kept.removeAll { $0.path == app.path }
            kept.append(app)
        }
        restoredApps = kept
    }
    /// The locations where new ArtCraft apps get the applied pack, when they are known.
    var coveredScopes: Set<Scope>? { appliedScopes.map { Set($0.compactMap(Scope.init(rawValue:))) } }
    var largerTab: PopupTab {
        let launcher = windowSize(for: .launcher), manage = windowSize(for: .manage)
        return manage.width * manage.height > launcher.width * launcher.height ? .manage : .launcher
    }
}

/// What this version keeps beside preferences.json. Earlier versions rewrite preferences.json without the keys they do
/// not know, and never touch this file, so a choice kept here survives a run of an earlier version.
struct Choices: Codable {
    /// Whether macOS opens BetterIcon at login, as the user last chose it, or as the first start of a version with the
    /// option set it. Nil until then: only then does BetterIcon register by itself.
    var openAtLogin: Bool?
    /// Set once BetterIcon knows the locations the last Apply covered for new apps. From then on preferences without them
    /// mean that no location is covered: an earlier version dropped them, and BetterIcon does not guess them again.
    var locationsKnown: Bool?
    static func url(_ state: URL) -> URL { state.appendingPathComponent("choices.json") }
    /// The saved choices, or nil when none were saved. A file that cannot be read counts as choices made, with opening at
    /// login off, so it never leads to a registration.
    static func load(_ state: URL) -> Choices? {
        let file = url(state)
        guard fm.fileExists(atPath: file.path) else { return nil }
        guard let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(Choices.self, from: data) else {
            return Choices(openAtLogin: false, locationsKnown: true)
        }
        return value
    }
    @discardableResult static func update(_ state: URL, _ change: (inout Choices) -> Void) throws -> Choices {
        try withStateLock(state.appendingPathComponent("preferences.lock")) {
            var value = load(state) ?? Choices()
            change(&value)
            try save(value, at: url(state))
            return value
        }
    }
}
/// Another BetterIcon operation holds a state lock: this app, another account's copy or the command line.
struct LockBusy: LocalizedError {
    var errorDescription: String? { "Another BetterIcon operation is in progress." }
}
func withStateLock<T>(_ url: URL, blocking: Bool = true, _ operation: () throws -> T) throws -> T {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw Problem("Could not open \(url.lastPathComponent).") }
    defer { close(fd) }
    guard flock(fd, blocking ? LOCK_EX : LOCK_EX | LOCK_NB) == 0 else { throw LockBusy() }
    return try operation()
}
@discardableResult func updatePreferences(_ state: URL, _ update: (inout Preferences) -> Void) throws
    -> Preferences
{
    try withStateLock(state.appendingPathComponent("preferences.lock")) {
        let url = state.appendingPathComponent("preferences.json")
        var prefs = try saved(Preferences.self, at: url, fallback: Preferences())
        update(&prefs)
        try save(prefs, at: url)
        return prefs
    }
}
