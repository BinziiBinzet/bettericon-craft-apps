import AppKit
import Darwin
import Security

private func fileError(_ url: URL) -> Problem {
    Problem("\(url.path): \(String(cString: strerror(errno)))")
}
private let finder = "com.apple.FinderInfo"
let resourceFork = "com.apple.ResourceFork"
/// NSWorkspace.setIcon writes through the Carbon Resource Manager, which is not thread-safe: calls from two threads at once
/// corrupt its state, which crashed a probe on macOS 27 and left files without the icon they were given. BetterIcon changes
/// icons from several queues (Apply and Restore, putting app icons back, folder passes and the folder watcher), so every
/// icon change goes through here, one at a time.
private let iconChanges = NSLock()
func setFinderIcon(_ image: NSImage?, _ path: String) -> Bool {
    iconChanges.lock()
    defer { iconChanges.unlock() }
    return NSWorkspace.shared.setIcon(image, forFile: path, options: [])
}
func attribute(_ name: String, _ file: URL) throws -> Data? {
    let n = getxattr(file.path, name, nil, 0, 0, XATTR_NOFOLLOW)
    if n < 0 && errno == ENOATTR { return nil }
    guard n >= 0 else { throw fileError(file) }
    guard n <= 64 * 1024 * 1024 else { throw Problem("Existing icon metadata exceeds 64 MB at \(file.path).") }
    var bytes = Data(count: n)
    let actual = bytes.withUnsafeMutableBytes { getxattr(file.path, name, $0.baseAddress, n, 0, XATTR_NOFOLLOW) }
    guard actual == n else { throw Problem("Icon metadata changed while reading \(file.lastPathComponent).") }
    return bytes
}
func putAttribute(_ name: String, _ data: Data?, _ file: URL) throws {
    if let data {
        let status = data.withUnsafeBytes {
            setxattr(file.path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW)
        }
        guard status == 0 else { throw fileError(file) }
    } else if removexattr(file.path, name, XATTR_NOFOLLOW) != 0 && errno != ENOATTR {
        throw fileError(file)
    }
}
/// Write a file's whole resource fork, or remove it. setxattr writes a resource fork over the one in place without
/// truncating it, so a shorter fork would keep the tail of the longer one: the old fork goes first.
func putResourceFork(_ fork: Data?, _ file: URL) throws {
    if let fork, getxattr(file.path, resourceFork, nil, 0, 0, XATTR_NOFOLLOW) <= fork.count {
        return try putAttribute(resourceFork, fork, file)
    }
    try putAttribute(resourceFork, nil, file)
    if let fork { try putAttribute(resourceFork, fork, file) }
}
func customFlag(_ file: URL) throws -> Bool {
    guard let info = try attribute(finder, file) else { return false }
    guard info.count == 32 else { throw Problem("Unrecognized Finder metadata at \(file.path).") }
    return info[8] & 4 != 0
}
private func setFlag(_ value: Bool, _ file: URL) throws {
    var info = try attribute(finder, file) ?? Data(count: 32)
    guard info.count == 32 else { throw Problem("Unrecognized Finder metadata.") }
    if value { info[8] |= 4 } else { info[8] &= ~4 }
    try putAttribute(finder, info.allSatisfy { $0 == 0 } ? nil : info, file)
}
/// Whether a resource fork holds nothing but a custom icon: no resources at all, as setIcon leaves one after it removes a
/// custom icon, or only 'icns' resources.
func iconOnlyResourceFork(_ fork: Data) -> Bool {
    let data = [UInt8](fork)
    guard data.count >= 16 else { return data.isEmpty }
    func word(_ p: Int) -> Int { Int(data[p]) << 8 | Int(data[p + 1]) }
    func long(_ p: Int) -> Int { word(p) << 16 | word(p + 2) }
    let map = long(4), length = long(12)
    guard length >= 30, map >= 16, map <= data.count - length else { return false }
    let end = map + length
    let types = map + word(map + 24)
    guard types >= map + 28, types <= end - 2 else { return false }
    // The type list holds the number of types less one, so no type at all reads as 0xFFFF.
    if word(types) == 0xFFFF { return true }
    let count = word(types) + 1
    guard count <= (end - types - 2) / 8 else { return false }
    return (0..<count).allSatisfy { i in
        let type = types + 2 + i * 8
        return Array(data[type..<type + 4]) == Array("icns".utf8)
    }
}
/// The icon family in a resource fork: the data of its first 'icns' resource, as setIcon and Finder store it.
func iconFamily(inFork fork: Data) -> Data? {
    let data = [UInt8](fork)
    guard data.count >= 16 else { return nil }
    func word(_ p: Int) -> Int { Int(data[p]) << 8 | Int(data[p + 1]) }
    func long(_ p: Int) -> Int { word(p) << 16 | word(p + 2) }
    let start = long(0), map = long(4), length = long(12)
    guard start >= 16, length >= 30, map >= 16, map <= data.count - length else { return nil }
    let end = map + length
    let types = map + word(map + 24)
    guard types >= map + 28, types <= end - 2 else { return nil }
    let count = word(types) + 1
    guard count <= (end - types - 2) / 8 else { return nil }
    for i in 0..<count {
        let type = types + 2 + i * 8
        guard Array(data[type..<type + 4]) == Array("icns".utf8) else { continue }
        let refs = types + word(type + 6)
        guard refs >= types, refs <= end - 12 else { return nil }
        let at = start + (Int(data[refs + 5]) << 16 | Int(data[refs + 6]) << 8 | Int(data[refs + 7]))
        guard at <= data.count - 4 else { return nil }
        let size = long(at)
        guard size > 0, size <= data.count - at - 4 else { return nil }
        return Data(data[at + 4..<at + 4 + size])
    }
    return nil
}

// A folder's custom icon lives outside Contents. Finder aliases store it in
// their own resource fork, which can also contain alias information.
private struct FinderIcon: Codable, Equatable {
    let custom: Bool
    let file: Data?
    let fork: Data?
    let flags: Data?
    /// No custom icon at all.
    static let none = FinderIcon(custom: false, file: nil, fork: nil, flags: nil)
    static func capture(_ target: URL, alias: Bool) throws -> FinderIcon {
        let flag = try customFlag(target)
        if alias {
            return FinderIcon(custom: flag, file: nil, fork: try attribute(resourceFork, target), flags: nil)
        }
        let child = target.appendingPathComponent("Icon\r")
        var st = stat()
        if lstat(child.path, &st) != 0 {
            guard errno == ENOENT else { throw fileError(child) }
            return FinderIcon(custom: flag, file: nil, fork: nil, flags: nil)
        }
        guard st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1, st.st_size <= 64 * 1024 * 1024 else {
            throw Problem("The existing icon file at \(target.path) cannot be safely changed.")
        }
        return FinderIcon(
            custom: flag, file: try Data(contentsOf: child), fork: try attribute(resourceFork, child),
            flags: try attribute(finder, child))
    }
    // A custom-icon flag with no icon data is a half-finished change. Finder then draws a
    // generic icon, and there is no artwork left to preserve.
    var unfinished: Bool { custom && file == nil && fork == nil }
    /// No custom icon at all, the state in which an update delivers a fresh copy of an app.
    var clean: Bool { !custom && file == nil }
    /// The icon artwork itself, without the bookkeeping around it.
    var family: Data? { fork.flatMap(iconFamily(inFork:)) }
    private func fingerprint(_ resource: Data?) -> String {
        digest(
            Data(
                ([custom ? "1" : "0"] + [file, resource, flags].map { $0.map(digest) ?? "-" }).joined(
                    separator: "/"
                ).utf8))
    }
    var signature: String { fingerprint(fork) }
    var artworkSignature: String {
        // Resource Manager writes process-local handles and file reference
        // numbers into the map. Artwork and every resource payload must match.
        // Originals and post-write conflict checks still use all original bytes.
        guard var data = fork, data.count >= 16 else { return signature }
        func word(_ p: Int) -> Int { Int(data[p]) << 8 | Int(data[p + 1]) }
        func long(_ p: Int) -> Int { word(p) << 16 | word(p + 2) }
        let map = long(4)
        let length = long(12)
        guard length >= 30, map >= 16, map <= data.count - length else { return signature }
        let end = map + length
        let types = map + word(map + 24)
        guard types >= map + 28, types <= end - 2 else { return signature }
        let count = word(types) + 1
        guard count <= (end - types - 2) / 8 else { return signature }
        data.resetBytes(in: map + 16..<map + 22)
        for i in 0..<count {
            let type = types + 2 + i * 8
            let n = word(type + 4) + 1
            let refs = types + word(type + 6)
            guard refs >= types, refs <= end, n <= (end - refs) / 12 else { return signature }
            for k in 0..<n {
                let p = refs + 12 * k + 8
                data.resetBytes(in: p..<p + 4)
            }
        }
        return fingerprint(data)
    }
    func write(_ target: URL, alias: Bool) throws {
        if alias {
            // A document's or a Finder alias's own icon is often smaller than the one BetterIcon put there.
            try putResourceFork(fork, target)
        } else {
            let child = target.appendingPathComponent("Icon\r")
            if let file {
                try file.write(to: child, options: .atomic)
                try putAttribute(resourceFork, fork, child)
                try putAttribute(finder, flags, child)
            } else if fm.fileExists(atPath: child.path) {
                try fm.removeItem(at: child)
            }
        }
        try setFlag(custom, target)
    }
}

/// A record that no longer describes its app: an update replaced the copy it was made for, or the custom
/// icon was removed outside BetterIcon. Apply starts afresh and Restore has nothing left to undo.
enum StaleRecord: Equatable { case updated, removed }
struct ReviewRow: Equatable {
    let app: AppEntry
    var message: String
    var identity = "", before = "", record = "", artHash = ""
    var art: URL?
    var change = false
    var alreadyDefault = false
    var stale: StaleRecord?
    /// Another icon is in place, so BetterIcon leaves the app alone, now and after its updates.
    var preserved = false
}
private struct IconRecord: Codable {
    var identity: String
    let original: String
    var current: String
    var pending: String?
    var intermediate: String?
    let preview: String
    // Where the record belongs and what it applied, so an icon can come back after an update. A record
    // written before these existed has none of them until the first check fills them in.
    var path: String?
    var bundleID: String?
    /// CFBundleVersion, read from the Info.plist file.
    var version: String?
    /// SHA-256 of the artwork BetterIcon put on this copy. A private copy is kept in the artwork folder.
    var art: String?
    /// The icon file as BetterIcon last saw it: inode, size, change times and resource fork length. While the file
    /// is as BetterIcon left it, a check reads no icon data. Another icon, even one pasted over BetterIcon's, changes it.
    var iconFile: String?
    /// BetterIcon gave way on this copy, and why: "icon" when the user gave it another icon, "restore" when they asked
    /// for its original icon and the Restore could not happen. Its icon is never put back by itself, now or after an
    /// update.
    var gaveWay: String?
    /// What the pending change does: apply, reapply (after an update) or restore.
    var intent: String?
}
/// Why an app that had BetterIcon's icon keeps its original icon from now on.
enum KeptOriginal: Hashable {
    /// Its custom icon was removed outside BetterIcon, for example in Finder.
    case removed
    /// An update dropped the icon the user had given it in place of BetterIcon's.
    case ownIcon
    /// The user asked for the original icon in a Restore that macOS declined or that could not finish.
    case restore
}
/// What one pass of `AppIcons.reconcile` did.
struct Reconciled {
    /// Apps an update had replaced, now carrying their artwork again.
    var restored = [AppEntry]()
    /// Apps on which a change BetterIcon had prepared never arrived, for example because macOS refused it. They now
    /// carry the icon.
    var finished = [AppEntry]()
    /// Apps that keep their original icon from now on, like an app restored on its own: the caller adds them to the
    /// preferences' defaultPaths. `reasons` says why for each.
    var optedOut = [String]()
    var reasons = [String: KeptOriginal]()
    /// Apps that now carry another custom icon. BetterIcon leaves them alone, also after their updates.
    var yielded = [String]()
    /// Apps in the middle of an update, or missing for the moment. Check them again shortly.
    var waiting = [String]()
    /// macOS refused the icon change: the app's path and the identity of the copy that refused.
    var declined = [String: String]()
    var errors = [String]()
    /// The apps among `errors`, with the message for each.
    var failed = [String: String]()
    /// Those of `declined` and `failed` whose change was an Apply that never reached the app, not an update.
    var applying = Set<String>()
    /// New apps that got the applied pack by themselves.
    var adopted = [AppEntry]()
    /// New apps that keep their own icon from now on: they arrived with a custom icon BetterIcon did not set, or they are
    /// a renamed, moved or duplicated copy of an app that keeps its original icon. The caller adds them to the
    /// preferences' defaultPaths, as it does `optedOut`, without a word on the status line.
    var leftAlone = [String]()
    /// The copies among `optedOut` and `leftAlone`, with what identifies each, for the preferences' restoredApps.
    var forgotten = [RestoredApp]()
}
/// New ArtCraft apps get the applied pack by themselves, the way Apply gives it: an app with no record, in a location
/// the last Apply covered, that carries no custom icon of its own.
struct Adoption {
    /// The applied pack and its artwork, by app.
    let pack: String
    let art: [String: URL]
    /// The locations the last Apply covered.
    let scopes: Set<Scope>
    /// The apps folders the last Apply covered: the standard ones and the folders included then. An app elsewhere, such
    /// as one running from a build folder or one in a folder included since, is left alone.
    let roots: [(url: URL, topLevel: Bool)]
    /// Copies that keep their original icon wherever they go.
    var kept = [RestoredApp]()
    /// Whether the app lies in a covered location, directly inside a top-level folder such as the Desktop.
    func covers(_ app: AppEntry) -> Bool {
        guard !app.isDocument, !app.isAlias, scopes.contains(app.scope), art[app.craft] != nil else { return false }
        let path = app.url.standardizedFileURL.path
        return roots.contains { root in
            let base = root.url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { return false }
            return !root.topLevel || !path.dropFirst(base.count + 1).contains("/")
        }
    }
    /// Whether the app is a copy of one that keeps its original icon, as long as no Apply has given that app the pack
    /// since: the same bundle, renamed or moved, or a duplicate of an app the user restored on its own.
    func keepsOriginal(_ app: AppEntry) -> Bool {
        let copy = fileCopy(app.url.path)
        return kept.contains { (copy != nil && $0.copy == copy) || ($0.chosen == true && $0.bundleID == app.bundleID) }
    }
}
/// What the Launcher draws for a copy BetterIcon holds a record of.
enum LauncherArt: Equatable {
    /// The icon the copy has now: BetterIcon means it to carry an icon it does not have yet, or gave way to another icon
    /// on it, or the user asked for its original icon.
    case own
    /// The artwork BetterIcon put on the copy: its SHA-256, and BetterIcon's private copy of it when that is present.
    case kept(String, URL?)
}
struct Review {
    let rows: [ReviewRow]
    /// One location, or every location when nil.
    let scope: Scope?
    let restore: Bool
    let only: String?
}
struct IconResult {
    var changed = [String](), defaults = [String](), errors = [String]()
    /// Apps on which macOS declined the change, usually for lack of App Management permission.
    var declined = [String]()
    /// After a Restore of one location: apps elsewhere still carry icons BetterIcon keeps up, so the applied pack
    /// stays in place for them.
    var othersKept = false
}
/// What happened to an app since BetterIcon last changed it.
private enum Drift: Equatable {
    /// BetterIcon's record still describes the app, possibly with an interrupted write.
    case intact
    /// Another copy of the same app still carries BetterIcon's icon, as when a Finder alias's app was updated.
    case moved
    /// A fresh copy of the same app without any custom icon: an update dropped the icon.
    case updated
    /// The same copy with its custom icon removed outside BetterIcon.
    case removed
    /// Another icon is in place now. It is preserved.
    case changed
}
/// What a change BetterIcon prepares does. A record keeps it until the change has arrived.
private enum Intent: String {
    case apply, reapply, restore
}

final class AppIcons {
    let root: URL
    /// Writes an icon on the app itself. The checks replace it to stand in for macOS refusing the change, as
    /// it does when BetterIcon is not allowed under App Management.
    var writeIcon: (NSImage?, String) -> Bool = { setFinderIcon($0, $1) }
    init(_ root: URL) { self.root = root }
    private var lockURL: URL { root.appendingPathComponent("operations.lock") }
    private func key(_ app: AppEntry) -> String { digest(Data(app.url.path.utf8)) }
    private func recordURL(_ app: AppEntry) -> URL { root.appendingPathComponent("records/\(key(app)).json") }
    private func previewURL(_ id: String) -> URL { root.appendingPathComponent("originals/\(id).png") }
    private func stateURL(_ id: String) -> URL { root.appendingPathComponent("originals/\(id).plist") }
    private func readRecord(_ app: AppEntry) throws -> IconRecord? {
        let url = recordURL(app)
        guard fm.fileExists(atPath: url.path) else { return nil }
        var r = try JSONDecoder().decode(IconRecord.self, from: Data(contentsOf: url))
        func valid(_ hash: String) -> Bool { hash.count == 64 && hash.allSatisfy(\.isHexDigit) }
        let hashes = [r.original, r.current, r.preview] + [r.pending, r.intermediate].compactMap { $0 }
        guard hashes.allSatisfy(valid) else {
            throw Problem("Invalid BetterIcon backup record.")
        }
        // The artwork reference only helps after an update. A damaged one is dropped, never fatal.
        if let art = r.art, !valid(art) { r.art = nil }
        if let intent = r.intent, Intent(rawValue: intent) == nil { r.intent = nil }
        if let reason = r.gaveWay, reason != "restore" { r.gaveWay = "icon" }
        return r
    }
    /// Whether BetterIcon holds a record for the app at this path, present or not.
    func hasRecord(_ path: String) -> Bool {
        fm.fileExists(atPath: root.appendingPathComponent("records/\(digest(Data(path.utf8))).json").path)
    }
    /// Whether this store of chosen files holds a record of a file of a type outside these designs: an icon BetterIcon gave
    /// it as a file of another type. A document's record names its design, or the file's own extension for such a file.
    func holdsRecords(outside designs: Set<String>) -> Bool {
        let records = root.appendingPathComponent("records")
        for name in (try? fm.contentsOfDirectory(atPath: records.path)) ?? [] where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: records.appendingPathComponent(name)),
                let rec = try? JSONDecoder().decode(IconRecord.self, from: data),
                let design = rec.identity.split(separator: "/").last
            else { continue }
            if design.hasPrefix("."), !designs.contains(String(design)) { return true }
        }
        return false
    }
    /// Whether BetterIcon keeps its icon on this copy: it holds a readable record, has not given way on it and has no
    /// Restore of it pending.
    func keepsIcon(_ app: AppEntry) -> Bool {
        guard !app.isDocument, let rec = try? readRecord(app) else { return false }
        return rec.gaveWay == nil && !restoring(rec)
    }
    /// What the Launcher draws for this copy, or nil when BetterIcon holds no record of the artwork on it.
    func launcherArt(_ app: AppEntry) -> LauncherArt? {
        guard !app.isDocument, let rec = try? readRecord(app) else { return nil }
        if rec.gaveWay != nil || restoring(rec) || !hasCustomIcon(app) { return .own }
        guard let id = rec.art else { return nil }
        // The private copy is named by its checksum and written whole, so the Launcher reads no artwork to find it.
        let file = Artwork.formats.lazy.map { self.artworkFolder.appendingPathComponent(id + "." + $0) }
            .first { fm.isReadableFile(atPath: $0.path) }
        return .kept(id, file)
    }
    /// Whether an app bundle is whole: its code signature checks out, as it does once an install or a copy into the
    /// folder has finished. A Finder copy writes the bundle file by file, so a copy under way fails the check. Its main
    /// executable can exist with no bytes yet, which reads as unsigned: a bundle with a signature folder must check out.
    /// A truly unsigned app is whole once its executable holds a Mach-O header or a script's first line.
    static func complete(_ bundle: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let status = SecStaticCodeCheckValidity(code, [], nil)
        if status == OSStatus(errSecSuccess) { return true }
        guard status == OSStatus(errSecCSUnsigned),
            !fm.fileExists(atPath: bundle.appendingPathComponent("Contents/_CodeSignature").path),
            let info = AppCatalog.bundleInfo(bundle), let exe = AppCatalog.executable(bundle, info),
            let file = FileHandle(forReadingAtPath: exe.path)
        else { return false }
        defer { try? file.close() }
        let head = [UInt8]((try? file.read(upToCount: 4)) ?? Data())
        guard head.count == 4 else { return false }
        let magic = UInt32(head[0]) << 24 | UInt32(head[1]) << 16 | UInt32(head[2]) << 8 | UInt32(head[3])
        let machO: Set<UInt32> = [0xfeed_face, 0xcefa_edfe, 0xfeed_facf, 0xcffa_edfe, 0xcafe_babe, 0xbeba_feca, 0xcafe_babf]
        return machO.contains(magic) || head.starts(with: Array("#!".utf8))
    }
    /// Whether the app carries a custom icon BetterIcon holds no record of: the user's own, or another tool's.
    func carriesOwnIcon(_ app: AppEntry) -> Bool {
        !app.isDocument && !hasRecord(app.url.path) && hasCustomIcon(app)
    }
    /// The bundle ID a record was made for. Records from before the bundleID field carry it in their identity.
    private static func bundleID(of rec: IconRecord) -> String? {
        if let id = rec.bundleID { return id }
        let parts = rec.identity.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 4 ? String(parts[2]) : nil
    }
    /// The app's Info.plist, read from the file. Bundle caches what it read first, even after an update.
    private func bundleInfo(_ app: AppEntry) -> (data: Data, plist: [String: Any])? {
        guard let data = try? Data(contentsOf: app.launchURL.appendingPathComponent("Contents/Info.plist")),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any]
        else { return nil }
        return (data, plist)
    }
    private func bundleVersion(_ app: AppEntry) -> String {
        bundleInfo(app)?.plist["CFBundleVersion"] as? String ?? ""
    }
    /// ArtCraft Launcher and the apps' own updaters copy a new version into a hidden .artcraft-launcher-…
    /// folder beside the app, move the old copy into a hidden backup folder, move the new one in and delete
    /// the backup. Such a folder younger than 15 minutes means an update may still be under way. An older one
    /// is a leftover from an update that failed and is ignored.
    static func installing(beside app: URL, now: Date = Date()) -> Bool {
        let folder = app.deletingLastPathComponent()
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return false }
        for name in names where name.hasPrefix(".artcraft-launcher-") {
            var st = stat()
            guard lstat(folder.appendingPathComponent(name).path, &st) == 0 else { continue }
            let changed = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            if abs(now.timeIntervalSince(changed)) < 15 * 60 { return true }
        }
        return false
    }
    private var artworkFolder: URL { root.appendingPathComponent("artwork") }
    /// Keep a private copy of artwork applied to an app, so the icon can come back after the pack changes.
    private func keepArtwork(_ data: Data, ext: String) throws -> String {
        let id = digest(data)
        let kind = Artwork.formats.contains(ext.lowercased()) ? ext.lowercased() : "png"
        let url = artworkFolder.appendingPathComponent(id + "." + kind)
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: artworkFolder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        return id
    }
    /// The private copy of artwork, when it is present and intact.
    private func keptArtwork(_ id: String) -> URL? {
        for kind in Artwork.formats {
            let url = artworkFolder.appendingPathComponent(id + "." + kind)
            if let data = try? Artwork.load(url), digest(data) == id { return url }
        }
        return nil
    }
    /// Remove private artwork copies that no record uses any more. Runs under the operations lock.
    private func pruneArtwork() {
        guard let files = try? fm.contentsOfDirectory(atPath: artworkFolder.path), !files.isEmpty else { return }
        let records = root.appendingPathComponent("records")
        var used = Set<String>()
        for name in (try? fm.contentsOfDirectory(atPath: records.path)) ?? [] where name.hasSuffix(".json") {
            // An unreadable record could still need its artwork. Then nothing is removed.
            guard let data = try? Data(contentsOf: records.appendingPathComponent(name)),
                let rec = try? JSONDecoder().decode(IconRecord.self, from: data)
            else { return }
            if let art = rec.art { used.insert(art) }
        }
        for name in files where !used.contains(String(name.prefix(64))) {
            try? fm.removeItem(at: artworkFolder.appendingPathComponent(name))
        }
    }
    /// The icon file as it is now, to tell cheaply whether it changed: an app's Icon\r, or a Finder alias itself.
    private func iconFileStamp(_ app: AppEntry) -> String? {
        let target = app.usesFileFork ? app.url : app.url.appendingPathComponent("Icon\r")
        var st = stat()
        guard lstat(target.path, &st) == 0 else { return nil }
        let fork = getxattr(target.path, resourceFork, nil, 0, 0, XATTR_NOFOLLOW)
        return "\(st.st_ino)/\(st.st_size)/\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)/"
            + "\(st.st_ctimespec.tv_sec).\(st.st_ctimespec.tv_nsec)/\(fork)"
    }
    /// Whether Finder draws a custom icon for the app: its custom-icon flag is set.
    private func hasCustomIcon(_ app: AppEntry) -> Bool { (try? customFlag(app.url)) == true }
    /// Compare an app with BetterIcon's record of it. Documents keep the stricter rule that any difference is
    /// preserved, because a project file is often saved as a new file.
    private func drift(_ app: AppEntry, _ rec: IconRecord, identity: String, snapshot: FinderIcon) -> Drift {
        let interrupted =
            rec.pending != nil && [rec.pending, rec.intermediate].contains(snapshot.artworkSignature)
        let ours = rec.current == snapshot.signature || interrupted
        if rec.identity == identity {
            // A write cut short leaves the icon file without the folder's custom-icon flag, and an interrupted change
            // can also leave the flag without its icon. Both can be finished or undone.
            let cut = rec.pending != nil && !app.usesFileFork && !snapshot.custom && snapshot.file != nil
            if ours || cut || snapshot.unfinished { return .intact }
            // Neither BetterIcon's icon, nor the state before or after a change it prepared: the icon was removed.
            return !app.isDocument && snapshot.clean ? .removed : .changed
        }
        guard !app.isDocument, Self.bundleID(of: rec) == app.bundleID else { return .changed }
        if snapshot.clean { return .updated }
        return ours ? .moved : .changed
    }
    private func original(_ rec: IconRecord) throws -> FinderIcon {
        let snapshot = try PropertyListDecoder().decode(
            FinderIcon.self, from: Data(contentsOf: stateURL(rec.original)))
        guard snapshot.signature == rec.original else {
            throw Problem("The original icon backup failed verification.")
        }
        return snapshot
    }
    /// Whether the record's pending change is a Restore. A record from before the intent field compares the change
    /// with the original icon.
    private func restoring(_ rec: IconRecord) -> Bool {
        guard let pending = rec.pending else { return false }
        if let intent = rec.intent { return intent == Intent.restore.rawValue }
        return (try? original(rec))?.artworkSignature == pending
    }
    func defaultPreview(_ app: AppEntry) -> URL? {
        // An app without a custom icon shows its own icon, whatever the backup holds.
        guard let r = try? readRecord(app), (try? identity(app)) == r.identity, hasCustomIcon(app) else { return nil }
        let url = previewURL(r.preview)
        return fm.fileExists(atPath: url.path) ? url : nil
    }
    private func identity(_ app: AppEntry) throws -> String {
        var st = stat()
        guard lstat(app.url.path, &st) == 0, st.st_mode & S_IFMT == (app.usesFileFork ? S_IFREG : S_IFDIR) else {
            throw Problem("App removed or moved.")
        }
        if app.isDocument {
            guard st.st_nlink == 1 else { throw Problem("This document has multiple hard links.") }
            return "\(st.st_dev)/\(st.st_ino)/\(app.craft)"
        }
        if app.isAlias {
            guard let resolved = try? URL(resolvingAliasFileAt: app.url, options: [.withoutUI, .withoutMounting]),
                resolved.standardizedFileURL == app.launchURL
            else { throw Problem("The Finder alias now points to a different app.") }
        }
        guard let info = bundleInfo(app), info.plist["CFBundleIdentifier"] as? String == app.bundleID
        else { throw Problem("The app identity changed.") }
        return "\(st.st_dev)/\(st.st_ino)/\(app.bundleID)/\(digest(info.data))"
    }
    func review(apps: [AppEntry], pack: Pack, scope: Scope?, restore: Bool, only: String? = nil) -> Review {
        let rows = apps.filter { (scope == nil || $0.scope == scope) && (only == nil || $0.craft == only) }.map { app -> ReviewRow in
            var row = ReviewRow(app: app, message: "")
            do {
                row.identity = try identity(app)
                let snapshot = try FinderIcon.capture(app.url, alias: app.usesFileFork)
                row.before = snapshot.signature
                var rec = try readRecord(app)
                if let found = rec {
                    row.record = [found.identity, found.original, found.current, found.pending ?? ""].joined(
                        separator: "/")
                    let state = drift(app, found, identity: row.identity, snapshot: snapshot)
                    switch state {
                    case .intact, .moved:
                        _ = try original(found)
                    case .changed:
                        row.preserved = true
                        throw Problem("App or icon changed outside BetterIcon. Preserved.")
                    case .updated, .removed:
                        guard !Self.installing(beside: app.url) else {
                            throw Problem("This app is being updated. Try again in a moment.")
                        }
                        // A custom icon the app had before BetterIcon is still backed up: Restore brings it back.
                        if state == .removed, (try? original(found))?.custom == true { break }
                        row.stale = state == .updated ? .updated : .removed
                        rec = nil
                    }
                }
                let note: String
                switch row.stale {
                case .updated?: note = " • updated since BetterIcon changed it"
                case .removed?: note = " • its custom icon was removed outside BetterIcon"
                case nil: note = ""
                }
                if restore {
                    guard let rec, row.before != rec.original else {
                        row.alreadyDefault = rec != nil || !snapshot.custom
                        row.message =
                            row.alreadyDefault
                            ? "Already at its original icon" + note : "Existing custom icon • no BetterIcon backup"
                        return row
                    }
                } else {
                    guard let art = pack.icons[app.craft] else {
                        row.message = "No artwork in this pack"
                        return row
                    }
                    row.art = art
                    row.artHash = try digest(Artwork.load(art))
                }
                guard fm.isWritableFile(atPath: app.url.path) else {
                    throw Problem("Read-only • this account needs write access to the app.")
                }
                row.change = true
                if restore {
                    row.message = "Restore original icon"
                } else {
                    row.message =
                        (app.isDocument ? "Change file icon" : (app.isAlias ? "Change Finder alias icon" : "Change application icon"))
                        + note
                }
            } catch { row.message = error.localizedDescription }
            return row
        }
        return Review(rows: rows, scope: scope, restore: restore, only: only)
    }
    private func backup(_ snapshot: FinderIcon, _ app: AppEntry, _ identity: String) throws -> IconRecord {
        let url = stateURL(snapshot.signature)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(snapshot).write(to: url, options: .atomic)
        let png = try Artwork.png(NSWorkspace.shared.icon(forFile: app.url.path), pixels: 1024)
        let preview = digest(png)
        try png.write(to: previewURL(preview), options: .atomic)
        return IconRecord(
            identity: identity, original: snapshot.signature, current: snapshot.signature, preview: preview)
    }
    private func stagedIcon(_ data: Data, before: FinderIcon, app: AppEntry) throws -> (NSImage, FinderIcon) {
        guard let source = NSImage(data: data), let image = try NSImage(data: Artwork.png(source, pixels: 1024))
        else { throw Problem("Could not render the chosen artwork.") }
        let stage = fm.temporaryDirectory.appendingPathComponent("BetterIcon-" + UUID().uuidString)
        if app.isDocument {
            guard fm.createFile(atPath: stage.path, contents: nil) else { throw Problem("Could not prepare a document icon.") }
            try before.write(stage, alias: true)
        } else if app.isAlias {
            try fm.copyItem(at: app.url, to: stage)
        } else {
            try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        }
        defer { try? fm.removeItem(at: stage) }
        if !app.usesFileFork && (before.file != nil || before.custom) { try before.write(stage, alias: false) }
        guard setFinderIcon(image, stage.path) else {
            throw Problem("macOS could not prepare this custom icon.")
        }
        return (image, try FinderIcon.capture(stage, alias: app.usesFileFork))
    }
    /// Apply or restore what was reviewed. With `wait`, another operation that holds the lock, such as BetterIcon
    /// putting an icon back after an update, may finish first.
    func perform(_ plan: Review, apps: [AppEntry], pack: Pack, wait: TimeInterval = 0) throws -> IconResult {
        try withOperationsLock(wait: wait) { try performLocked(plan, apps: apps, pack: pack) }
    }
    /// Wait until no other BetterIcon operation holds the lock, for at most `timeout` seconds.
    func waitUntilIdle(timeout: TimeInterval) throws { try withOperationsLock(wait: timeout) {} }
    private func withOperationsLock<T>(wait: TimeInterval, _ body: () throws -> T) throws -> T {
        let deadline = Date().addingTimeInterval(wait)
        while true {
            do { return try withStateLock(lockURL, blocking: false, body) } catch is LockBusy where Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }
    private func performLocked(
        _ plan: Review, apps: [AppEntry], pack: Pack, intent chosen: Intent? = nil
    ) throws -> IconResult {
        let fresh = review(apps: apps, pack: pack, scope: plan.scope, restore: plan.restore, only: plan.only)
        guard fresh.rows == plan.rows else {
            throw Problem("The apps, icons, or backups changed since review. Review the operation again.")
        }
        let intent = plan.restore ? Intent.restore : chosen ?? .apply
        var result = IconResult()
        var forgot = false
        for row in plan.rows {
            // Another icon is in place: BetterIcon leaves it, also after the app's updates.
            if row.preserved { giveWay(row.app, "icon") }
            if plan.restore && row.alreadyDefault && !row.record.isEmpty {
                // An update, someone outside BetterIcon, or a change that never reached the app already left the app
                // at its original icon. Restoring it only forgets the record that no longer describes it.
                do {
                    let app = row.app
                    let targetLock = open(app.url.path, O_RDONLY | O_NOFOLLOW)
                    guard targetLock >= 0 else { throw Problem("Could not open this app for an icon change.") }
                    defer { close(targetLock) }
                    guard flock(targetLock, LOCK_EX | LOCK_NB) == 0 else {
                        throw Problem("Another account is changing this app’s icon.")
                    }
                    guard try FinderIcon.capture(app.url, alias: app.usesFileFork).signature == row.before,
                        try identity(app) == row.identity
                    else { throw Problem("App changed after review.") }
                    if fm.fileExists(atPath: recordURL(app).path) { try fm.removeItem(at: recordURL(app)) }
                    forgot = true
                    result.defaults.append(app.url.path)
                } catch { result.errors.append("\(row.app.name) — \(error.localizedDescription)") }
                continue
            }
            if row.alreadyDefault { result.defaults.append(row.app.url.path) }
            guard row.change else {
                // The original icon was asked for and cannot come back now. The app keeps it after its next update.
                if plan.restore && !row.record.isEmpty && !row.preserved { giveWay(row.app, "restore") }
                continue
            }
            do {
                let app = row.app
                let path = app.url.path
                let ws = NSWorkspace.shared
                let targetLock = open(path, O_RDONLY | O_NOFOLLOW)
                guard targetLock >= 0 else { throw Problem("Could not open this app for an icon change.") }
                defer { close(targetLock) }
                guard flock(targetLock, LOCK_EX | LOCK_NB) == 0 else {
                    throw Problem("Another account is changing this app’s icon.")
                }
                let before = try FinderIcon.capture(app.url, alias: app.usesFileFork)
                guard before.signature == row.before, try identity(app) == row.identity else {
                    throw Problem("App changed after review.")
                }
                // A stale record describes a copy that is gone or a change that was undone. The app as it is
                // now becomes the original, with a new preview of its own icon.
                var rec = try (row.stale == nil ? readRecord(app) : nil) ?? backup(before, app, row.identity)
                // Another copy of the same app may still carry BetterIcon's icon. The record follows it.
                rec.identity = row.identity
                let desired: FinderIcon
                let image: NSImage?
                if plan.restore {
                    desired = try original(rec)
                    if desired.custom {
                        let bytes = try Data(contentsOf: previewURL(rec.preview))
                        guard digest(bytes) == rec.preview else {
                            throw Problem("The saved original preview failed verification.")
                        }
                        let staging = try stagedIcon(bytes, before: before, app: app)
                        image = staging.0
                        rec.intermediate = staging.1.artworkSignature
                    } else {
                        image = nil
                    }
                } else {
                    guard let art = row.art else { throw Problem("Missing reviewed artwork.") }
                    let data = try Artwork.load(art)
                    guard digest(data) == row.artHash else { throw Problem("Artwork changed after review.") }
                    (image, desired) = try stagedIcon(data, before: before, app: app)
                    // The app keeps this artwork after an update, whatever happens to the pack.
                    if !app.isDocument { _ = try keepArtwork(data, ext: art.pathExtension) }
                }
                // Durably record both sides before touching the application. A
                // restart can recognize a completed or unapplied write.
                rec.current = before.signature
                rec.pending = desired.artworkSignature
                rec.intent = intent.rawValue
                if !app.isDocument {
                    rec.path = path
                    rec.bundleID = app.bundleID
                    rec.version = bundleVersion(app)
                    if !plan.restore {
                        // Recorded with the prepared write, so a change macOS refuses can be tried again later.
                        rec.art = row.artHash
                        // An icon applied on purpose is BetterIcon's to keep up again.
                        rec.gaveWay = nil
                    }
                }
                try save(rec, at: recordURL(app))
                guard try identity(app) == row.identity,
                    try FinderIcon.capture(app.url, alias: app.usesFileFork) == before
                else { throw Problem("App changed during preparation.") }
                // With only the flag left there may be nothing for macOS to remove. The original bytes are written below.
                guard writeIcon(image, path) || (plan.restore && before.unfinished) else {
                    result.declined.append(path)
                    throw Problem(
                        "macOS declined the icon change. Check write access and App Management in System Settings."
                    )
                }
                if plan.restore, try FinderIcon.capture(app.url, alias: app.usesFileFork) != desired {
                    // setIcon notifies Icon Services; restore original resource
                    // bytes as well (including older Finder formats/aliases).
                    try desired.write(app.url, alias: app.usesFileFork)
                    ws.noteFileSystemChanged(path)
                }
                let actual = try FinderIcon.capture(app.url, alias: app.usesFileFork)
                guard plan.restore ? actual == desired : actual.artworkSignature == desired.artworkSignature else {
                    try before.write(app.url, alias: app.usesFileFork)
                    ws.noteFileSystemChanged(path)
                    throw Problem("macOS wrote unexpected icon data. The prior icon was restored.")
                }
                if plan.restore {
                    try fm.removeItem(at: recordURL(app))
                    result.defaults.append(path)
                } else {
                    rec.current = actual.signature
                    rec.pending = nil
                    rec.intermediate = nil
                    rec.intent = nil
                    if !app.isDocument { rec.iconFile = iconFileStamp(app) }
                    try save(rec, at: recordURL(app))
                }
                result.changed.append(path)
            } catch {
                result.errors.append("\(row.app.name) — \(error.localizedDescription)")
                // The original icon was asked for: it is not put back over by itself after the app's next update.
                if plan.restore { giveWay(row.app, "restore") }
            }
        }
        if forgot || !result.changed.isEmpty { pruneArtwork() }
        // A Restore of one location leaves the apps elsewhere as they are. While they carry icons BetterIcon keeps
        // up, the applied pack stays in place for them.
        if plan.restore, plan.only == nil, let scope = plan.scope {
            result.othersKept = keepsIcons(outside: scope, among: apps)
        }
        return result
    }
    /// BetterIcon gives way on this copy: its icon is not put back by itself, now or after an update. The reason is
    /// "icon" (another icon is in place) or "restore" (the original icon was asked for). Runs under the operations lock.
    private func giveWay(_ app: AppEntry, _ reason: String) {
        guard !app.isDocument, var rec = try? readRecord(app), rec.gaveWay == nil else { return }
        rec.gaveWay = reason
        rec.iconFile = iconFileStamp(app)
        try? save(rec, at: recordURL(app))
    }

    /// What an app with a record needs now.
    private enum Need {
        case none, waiting
        /// The app keeps its original icon from now on. With keep, the record stays, because it holds the backup of a
        /// custom icon the app had before BetterIcon, which Restore can still bring back.
        case optOut(keep: Bool, reason: KeptOriginal)
        /// Another custom icon is in place: BetterIcon gives way. The identity is the app's identity now.
        case yield(String)
        case missing(String)
        /// Record-only work: fill in the fields a record from an earlier version lacks, follow another copy of the
        /// app that still carries BetterIcon's icon, or note the icon file as it is now. The identity is the app's
        /// identity now, and the snapshot the icon it carries when that is BetterIcon's.
        case complete(String, FinderIcon?)
        /// A change that reached the app before BetterIcon could record it: the identity and the icon's signature.
        case settle(String, String)
        /// An update replaced the app: put this artwork on the new copy.
        case reapply(URL)
        /// A change BetterIcon prepared never reached the app, or was cut short: finish it with this artwork.
        case finish(URL)
    }
    private static let lostArtwork = "Its artwork is no longer on this Mac. Apply icons to give it one again."
    private func incomplete(_ rec: IconRecord, _ app: AppEntry) -> Bool {
        rec.path != app.url.path || rec.bundleID == nil || rec.version == nil
    }
    private func need(_ app: AppEntry, _ rec: IconRecord, appliedArt: [String: String]?, refused: Set<String>) -> Need {
        let id: String
        do { id = try identity(app) } catch { return .waiting }
        // macOS refused this copy before. It is tried again after a restart or a manual Apply.
        if refused.contains(id) { return .none }
        // Cheap first: the same copy, with its custom-icon flag set and its icon file as BetterIcon last saw it. Only
        // otherwise is the icon data read. A pasted icon replaces the file, so it is never mistaken for BetterIcon's.
        if !app.isAlias, id == rec.identity, rec.pending == nil, let seen = rec.iconFile, hasCustomIcon(app),
            iconFileStamp(app) == seen
        {
            if !incomplete(rec, app) { return .none }
            // A record that names no artwork reads the icon below, so the artwork the copy carries can be kept.
            if rec.art != nil || rec.gaveWay != nil { return .complete(id, nil) }
        }
        guard let snapshot = try? FinderIcon.capture(app.url, alias: app.usesFileFork) else { return .waiting }
        let state = drift(app, rec, identity: id, snapshot: snapshot)
        switch state {
        case .intact:
            if let pending = rec.pending {
                if restoring(rec) {
                    // A Restore that macOS declined or that was cut short. Once the app shows its original icon, by
                    // whatever means, it keeps it.
                    return snapshot.artworkSignature == pending ? .optOut(keep: false, reason: .restore) : .none
                }
                // The change reached the app before BetterIcon could record it.
                if snapshot.artworkSignature == pending { return .settle(id, snapshot.signature) }
                // A change that was prepared but never reached the app, or was cut short: macOS refused it, or
                // BetterIcon stopped first. It is tried again, unless macOS refused this copy since the last start or
                // manual Apply.
                if snapshot.clean && rec.current == snapshot.signature || !snapshot.custom && snapshot.file != nil {
                    guard let art = artwork(rec, app, appliedArt) else { return .missing(Self.lostArtwork) }
                    return rec.intent == Intent.apply.rawValue ? .finish(art) : .reapply(art)
                }
                return .none
            }
            let ours = rec.current == snapshot.signature
            if incomplete(rec, app) || ours && rec.iconFile != iconFileStamp(app) {
                return .complete(id, ours ? snapshot : nil)
            }
            return .none
        case .moved: return .complete(id, snapshot)
        case .changed:
            // Another icon is in place, chosen by the user or another tool. BetterIcon gives way, and keeps doing so
            // after the app's updates.
            guard rec.gaveWay != nil else { return .yield(id) }
            return rec.identity != id || rec.iconFile != iconFileStamp(app) ? .complete(id, nil) : .none
        case .updated, .removed:
            if Self.installing(beside: app.url) { return .waiting }
            if state == .removed {
                // A custom icon the app had before BetterIcon stays backed up, so Restore can still bring it back.
                let custom = (try? original(rec))?.custom == true
                return custom && rec.gaveWay != nil ? .none : .optOut(keep: custom, reason: .removed)
            }
            // BetterIcon gave way on the copy the update replaced, or its original icon was asked for.
            if rec.gaveWay == "icon" { return .optOut(keep: false, reason: .ownIcon) }
            if rec.gaveWay != nil || restoring(rec) { return .optOut(keep: false, reason: .restore) }
            guard let art = artwork(rec, app, appliedArt) else { return .missing(Self.lostArtwork) }
            return .reapply(art)
        }
    }
    /// The artwork an app should carry: its private copy. A record from an earlier version names no artwork, and
    /// then the artwork applied last is the best guess. A record that names artwork takes the artwork applied last
    /// only when it is that very artwork.
    private func artwork(_ rec: IconRecord, _ app: AppEntry, _ appliedArt: [String: String]?) -> URL? {
        if let id = rec.art, let kept = keptArtwork(id) { return kept }
        guard let path = appliedArt?[app.craft], fm.isReadableFile(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        if let id = rec.art, (try? digest(Artwork.load(url))) != id { return nil }
        return url
    }
    private func complete(
        _ rec: inout IconRecord, _ app: AppEntry, identity: String, snapshot: FinderIcon?, appliedArt: [String: String]?
    ) {
        rec.identity = identity
        rec.path = app.url.path
        rec.bundleID = app.bundleID
        rec.version = bundleVersion(app)
        rec.iconFile = iconFileStamp(app)
        // A record from an earlier version names no artwork. It takes the artwork its copy carries: the artwork applied
        // last when the copy shows exactly that, and otherwise the copy's own icon, so a copy that kept an older pack
        // gets that pack back after an update.
        guard rec.art == nil, let snapshot, let family = snapshot.family else { return }
        if let path = appliedArt?[app.craft], let data = try? Artwork.load(URL(fileURLWithPath: path)),
            (try? stagedIcon(data, before: .none, app: app))?.1.family == family
        {
            rec.art = try? keepArtwork(data, ext: URL(fileURLWithPath: path).pathExtension)
        } else {
            rec.art = try? keepArtwork(family, ext: "icns")
        }
    }

    /// Bring app icons back in line with BetterIcon's records after app updates.
    ///
    /// An update installs a fresh copy of an app, which drops its custom icon. For each app with a record that
    /// is not restored (the applied pack is not the original icons and the app is not in defaultPaths):
    /// - updated (another copy of the same app, without any custom icon): the record is rebuilt for the new
    ///   copy, with its own clean icon as the original, and the record's artwork goes back on through the same
    ///   review and perform as an Apply. A copy on which BetterIcon gave way, or whose original icon was asked
    ///   for, keeps its original icon instead and is reported in `optedOut`;
    /// - its custom icon removed outside BetterIcon: reported in `optedOut`, so it stays at its original icon like
    ///   an app restored on its own. The record is dropped, unless it backs up a custom icon from before BetterIcon;
    /// - another custom icon in place: left alone, and BetterIcon gives way after later updates too;
    /// - a change BetterIcon prepared that never arrived or was cut short: finished, or recorded as done;
    /// - missing, unreadable or being updated: reported in `waiting`.
    /// With `adopt`, a new app that BetterIcon holds no record of gets the applied pack's artwork the way Apply gives
    /// it, with a backup of its own icon and a record, so Restore works on it. It is reported in `adopted`. Only an app
    /// in a location the last Apply covered counts. An app that carries a custom icon of its own, or that is a copy of an
    /// app that keeps its original icon, is left alone from now on and reported in `leftAlone`. An app in the middle of
    /// an install or a copy is reported in `waiting`.
    /// A pass that finds every icon of a recorded app as BetterIcon last saw it reads no icon data for it and takes no
    /// lock; a new app that may get the pack costs a look at its icon and its signature. Otherwise the pass takes the
    /// operations lock without waiting and throws `LockBusy` when another operation holds it. `stop` is asked before each
    /// app: a pass that should end leaves the remaining apps for the next one.
    func reconcile(
        _ apps: [AppEntry], appliedPack: String?, defaultPaths: Set<String>, appliedArt: [String: String]?,
        refused: Set<String> = [], adopt: Adoption? = nil, stop: () -> Bool = { false }
    ) throws -> Reconciled {
        var result = Reconciled()
        // Restore wins: after Restore app defaults nothing comes back, nor for an app restored on its own.
        guard let appliedPack, appliedPack != Pack.defaults.id else { return result }
        var seen = Set<String>()
        let candidates = apps.filter {
            !$0.isDocument && !defaultPaths.contains($0.url.path) && seen.insert($0.url.path).inserted
        }
        var work = [AppEntry]()
        var newcomers = [(app: AppEntry, art: URL)]()
        for app in candidates {
            if stop() { break }
            if let adopt, adopt.pack == appliedPack, adopt.covers(app), !hasRecord(app.url.path),
                let art = adopt.art[app.craft]
            {
                switch arrival(app, adopt) {
                case .ready: newcomers.append((app, art))
                case .waiting: result.waiting.append(app.url.path)
                case .own:
                    // Remembered, so the app keeps its own icon after its next update, or once that icon is removed.
                    result.leftAlone.append(app.url.path)
                    result.forgotten.append(
                        RestoredApp(path: app.url.path, bundleID: app.bundleID, copy: fileCopy(app.url.path)))
                case .leave: break
                }
                continue
            }
            // A record that cannot be read is left for Apply or Restore to report.
            guard let rec = try? readRecord(app) else { continue }
            switch need(app, rec, appliedArt: appliedArt, refused: refused) {
            case .none: continue
            case .waiting: result.waiting.append(app.url.path)
            case .missing(let message):
                result.errors.append("\(app.name) — \(message)")
                result.failed[app.url.path] = message
            default: work.append(app)
            }
        }
        guard !work.isEmpty || !newcomers.isEmpty else { return result }
        try withStateLock(lockURL, blocking: false) {
            for app in work {
                if stop() { break }
                let path = app.url.path
                // Look again under the lock. The app, or its record, may have changed meanwhile.
                guard var rec = try? readRecord(app) else { continue }
                func store(_ record: IconRecord) -> Bool {
                    do {
                        try save(record, at: recordURL(app))
                        return true
                    } catch {
                        result.errors.append("\(app.name) — \(error.localizedDescription)")
                        result.failed[path] = error.localizedDescription
                        return false
                    }
                }
                switch need(app, rec, appliedArt: appliedArt, refused: refused) {
                case .none: continue
                case .waiting: result.waiting.append(path)
                case .missing(let message):
                    result.errors.append("\(app.name) — \(message)")
                    result.failed[path] = message
                case .complete(let identity, let snapshot):
                    complete(&rec, app, identity: identity, snapshot: snapshot, appliedArt: appliedArt)
                    _ = store(rec)
                case .settle(let identity, let current):
                    rec.identity = identity
                    rec.current = current
                    rec.pending = nil
                    rec.intermediate = nil
                    rec.intent = nil
                    rec.iconFile = iconFileStamp(app)
                    _ = store(rec)
                case .yield(let identity):
                    rec.identity = identity
                    rec.gaveWay = "icon"
                    rec.iconFile = iconFileStamp(app)
                    if store(rec) { result.yielded.append(path) }
                case .optOut(let keep, let reason):
                    do {
                        if keep {
                            rec.gaveWay = "restore"
                            rec.iconFile = iconFileStamp(app)
                            try save(rec, at: recordURL(app))
                        } else {
                            try fm.removeItem(at: recordURL(app))
                        }
                        result.optedOut.append(path)
                        result.reasons[path] = reason
                        result.forgotten.append(RestoredApp(path: path, bundleID: app.bundleID, copy: fileCopy(path)))
                    } catch {
                        result.errors.append("\(app.name) — \(error.localizedDescription)")
                        result.failed[path] = error.localizedDescription
                    }
                case .reapply(let art):
                    reapply(app, art, intent: .reapply, into: &result)
                case .finish(let art):
                    reapply(app, art, intent: .apply, into: &result)
                }
            }
            for (app, art) in newcomers {
                if stop() { break }
                // Look again under the lock: another operation may have changed the app meanwhile.
                guard !hasRecord(app.url.path), (try? FinderIcon.capture(app.url, alias: false))?.clean == true else {
                    continue
                }
                adoptNew(app, art, pack: appliedPack, into: &result)
            }
            pruneArtwork()
        }
        return result
    }
    /// Whether a new app can take the applied pack now. `own`: it keeps its own icon from now on. `leave`: not now, as
    /// with a read-only app.
    private enum Arrival { case ready, waiting, own, leave }
    private func arrival(_ app: AppEntry, _ adopt: Adoption) -> Arrival {
        // A renamed, moved or duplicated copy of an app the user restored, or that keeps its original icon otherwise.
        if adopt.keepsOriginal(app) { return .own }
        guard let snapshot = try? FinderIcon.capture(app.url, alias: false) else { return .waiting }
        // A custom icon BetterIcon did not set is the user's, or another tool's. A custom-icon flag without any icon is a
        // change someone left unfinished, and is looked at again later.
        if !snapshot.clean { return snapshot.unfinished ? .leave : .own }
        // A read-only app could not take an icon.
        guard fm.isWritableFile(atPath: app.url.path) else { return .leave }
        // Still being installed, or still being copied into the folder.
        if Self.installing(beside: app.url) || !Self.complete(app.launchURL) { return .waiting }
        return .ready
    }
    /// Give a new app the applied pack's artwork, through the same review and perform as an Apply.
    private func adoptNew(_ app: AppEntry, _ art: URL, pack id: String, into result: inout Reconciled) {
        let path = app.url.path
        let pack = Pack(id: id, name: "Applied pack", author: "", icons: [app.craft: art])
        let plan = review(apps: [app], pack: pack, scope: nil, restore: false)
        guard let row = plan.rows.first, row.change, row.stale == nil else {
            // Gone or replaced for a moment. Anything else, such as a read-only app, is left alone.
            if (try? identity(app)) == nil || Self.installing(beside: app.url) { result.waiting.append(path) }
            return
        }
        do {
            let done = try performLocked(plan, apps: [app], pack: pack, intent: .apply)
            if done.changed.contains(path) {
                result.adopted.append(app)
            } else if done.declined.contains(path) {
                result.declined[path] = row.identity
                result.applying.insert(path)
            } else if (try? identity(app)) != row.identity {
                result.waiting.append(path)
            } else {
                result.errors += done.errors
                result.failed[path] = done.errors.first.map { String($0.dropFirst(app.name.count + 3)) }
                    ?? "The pack’s icon could not be applied."
                result.applying.insert(path)
            }
        } catch {
            result.errors.append("\(app.name) — \(error.localizedDescription)")
            result.failed[path] = error.localizedDescription
        }
    }
    /// Put artwork back on an updated app, or finish a change that never reached it, through the same review
    /// and perform as an Apply.
    private func reapply(_ app: AppEntry, _ art: URL, intent: Intent, into result: inout Reconciled) {
        let path = app.url.path
        if intent == .apply { result.applying.insert(path) }
        let kept = Pack(id: "BetterIcon/Kept", name: "Kept icons", author: "", icons: [app.craft: art])
        let plan = review(apps: [app], pack: kept, scope: nil, restore: false)
        guard let row = plan.rows.first, row.change, row.stale != .removed else {
            if Self.installing(beside: app.url) || (try? identity(app)) == nil {
                result.waiting.append(path)
            } else {
                let message = plan.rows.first?.message ?? "App removed or moved."
                result.errors.append("\(app.name) — " + message)
                result.failed[path] = message
            }
            return
        }
        do {
            let done = try performLocked(plan, apps: [app], pack: kept, intent: intent)
            if done.changed.contains(path) {
                // A second swap during the write could have taken the icon away with it. Check the copy in place.
                if (try? identity(app)) == row.identity, (try? readRecord(app))?.identity == row.identity {
                    if intent == .reapply { result.restored.append(app) } else { result.finished.append(app) }
                } else {
                    result.waiting.append(path)
                }
            } else if done.declined.contains(path) {
                result.declined[path] = row.identity
            } else if (try? identity(app)) != row.identity {
                // The app was replaced again while BetterIcon worked on it.
                result.waiting.append(path)
            } else {
                result.errors += done.errors
                result.failed[path] = done.errors.first ?? "The icon could not be put back."
            }
        } catch {
            result.errors.append("\(app.name) — \(error.localizedDescription)")
            result.failed[path] = error.localizedDescription
        }
    }

    /// Whether an app outside this location still has an icon BetterIcon keeps up: a record BetterIcon has not given
    /// way on, for a copy that carries BetterIcon's icon, is waiting for it, or is being updated. A Restore of one
    /// location then leaves the applied pack in place for the others.
    private func keepsIcons(outside scope: Scope, among apps: [AppEntry]) -> Bool {
        apps.contains { app in
            guard app.scope != scope, !app.isDocument, let rec = try? readRecord(app), rec.gaveWay == nil,
                !restoring(rec)
            else { return false }
            // Moved aside for a moment by an update: it comes back.
            guard let id = try? identity(app) else { return true }
            // BetterIcon's icon as it was left, read without the icon data.
            if !app.isAlias, id == rec.identity, rec.pending == nil, let seen = rec.iconFile, hasCustomIcon(app),
                iconFileStamp(app) == seen
            {
                return true
            }
            guard let snapshot = try? FinderIcon.capture(app.url, alias: app.usesFileFork) else { return true }
            switch drift(app, rec, identity: id, snapshot: snapshot) {
            case .changed, .removed: return false
            case .intact, .moved, .updated: return true
            }
        }
    }
    /// Whether BetterIcon means this copy to carry its icon while it has none: an update dropped it, macOS refused
    /// it, or a change was cut short. The Launcher then draws the icon the app has, not the pack's.
    func awaitsIcon(_ app: AppEntry) -> Bool {
        guard !app.isDocument, let rec = try? readRecord(app), rec.gaveWay == nil, !restoring(rec) else { return false }
        return !hasCustomIcon(app)
    }
}
