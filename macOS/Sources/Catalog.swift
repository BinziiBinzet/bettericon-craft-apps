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
        guard let bundle = Bundle(url: target), let id = bundle.bundleIdentifier,
            let exe = bundle.executableURL, fm.isExecutableFile(atPath: exe.path)
        else { return nil }
        let official =
            id.lowercased().hasPrefix("ai.storyteller.")
            ? Craft.canonical(String(id.dropFirst("ai.storyteller.".count))) : nil
        guard let craft = official ?? Craft.canonical(target.deletingPathExtension().lastPathComponent) else {
            return nil
        }
        return AppEntry(name: basename, craft: craft, url: url, launchURL: target, bundleID: id, scope: scope)
    }
    static func dockURLs(_ tiles: [[String: Any]]) -> [URL] {
        tiles.compactMap { tile in
            guard let data = tile["tile-data"] as? [String: Any], let file = data["file-data"] as? [String: Any],
                let string = file["_CFURLString"] as? String, let url = URL(string: string), url.isFileURL
            else { return nil }
            return url
        }
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
    var documents = [String: URL]()
    var status = "Local"
    var canApps = true
    var canFiles = false
    var hasPreview = false
    var previousIDs = [String]()
    var canPreview: Bool { hasPreview || !icons.isEmpty || !documents.isEmpty }
    var model: [String: Any] {
        ["id": id, "title": title, "status": isDefault ? "Default" : status, "default": isDefault,
         "personal": personal, "canApps": canApps, "canFiles": canFiles || isDefault, "hasPreview": canPreview]
    }
    var isDefault: Bool { id == "ArtCraft/Default" }
    var title: String {
        if isDefault { return name }
        let credit = name == "Root" && !personal ? author : name + (author.isEmpty ? "" : " / " + author)
        return credit + (personal ? " (personal)" : "")
    }
    static let defaults = Pack(id: "ArtCraft/Default", name: "ArtCraft default", author: "", icons: [:])

}

struct Preferences: Codable {
    var fileSelected: String?
    var selected = "Craft-Icons-Zach/Cardboard"
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
    var largerTab: PopupTab {
        let launcher = windowSize(for: .launcher), manage = windowSize(for: .manage)
        return manage.width * manage.height > launcher.width * launcher.height ? .manage : .launcher
    }
}

func withStateLock<T>(_ url: URL, blocking: Bool = true, _ operation: () throws -> T) throws -> T {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw Problem("Could not open \(url.lastPathComponent).") }
    defer { close(fd) }
    guard flock(fd, blocking ? LOCK_EX : LOCK_EX | LOCK_NB) == 0 else {
        throw Problem("Another BetterIcon operation is in progress.")
    }
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
