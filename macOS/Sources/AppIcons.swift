import AppKit
import Darwin

private func fileError(_ url: URL) -> Problem {
    Problem("\(url.path): \(String(cString: strerror(errno)))")
}
private let finder = "com.apple.FinderInfo"
private let resourceFork = "com.apple.ResourceFork"
private func attribute(_ name: String, _ file: URL) throws -> Data? {
    let n = getxattr(file.path, name, nil, 0, 0, XATTR_NOFOLLOW)
    if n < 0 && errno == ENOATTR { return nil }
    guard n >= 0 else { throw fileError(file) }
    guard n <= 64 * 1024 * 1024 else { throw Problem("Existing icon metadata exceeds 64 MB at \(file.path).") }
    var bytes = Data(count: n)
    let actual = bytes.withUnsafeMutableBytes { getxattr(file.path, name, $0.baseAddress, n, 0, XATTR_NOFOLLOW) }
    guard actual == n else { throw Problem("Icon metadata changed while reading \(file.lastPathComponent).") }
    return bytes
}
private func putAttribute(_ name: String, _ data: Data?, _ file: URL) throws {
    if let data {
        let status = data.withUnsafeBytes {
            setxattr(file.path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW)
        }
        guard status == 0 else { throw fileError(file) }
    } else if removexattr(file.path, name, XATTR_NOFOLLOW) != 0 && errno != ENOATTR {
        throw fileError(file)
    }
}
private func customFlag(_ file: URL) throws -> Bool {
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

// A folder's custom icon lives outside Contents. Finder aliases store it in
// their own resource fork, which can also contain alias information.
private struct FinderIcon: Codable, Equatable {
    let custom: Bool
    let file: Data?
    let fork: Data?
    let flags: Data?
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
            try putAttribute(resourceFork, fork, target)
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

struct ReviewRow: Equatable {
    let app: AppEntry
    var message: String
    var identity = "", before = "", record = "", artHash = ""
    var art: URL?
    var change = false
    var alreadyDefault = false
}
private struct IconRecord: Codable {
    let identity: String
    let original: String
    var current: String
    var pending: String?
    var intermediate: String?
    let preview: String
}
struct Review {
    let rows: [ReviewRow]
    let scope: Scope
    let restore: Bool
    let only: String?
}
struct IconResult { var changed = [String](), defaults = [String](), errors = [String]() }

final class AppIcons {
    let root: URL
    init(_ root: URL) { self.root = root }
    private func key(_ app: AppEntry) -> String { digest(Data(app.url.path.utf8)) }
    private func recordURL(_ app: AppEntry) -> URL { root.appendingPathComponent("records/\(key(app)).json") }
    private func previewURL(_ id: String) -> URL { root.appendingPathComponent("originals/\(id).png") }
    private func stateURL(_ id: String) -> URL { root.appendingPathComponent("originals/\(id).plist") }
    private func readRecord(_ app: AppEntry) throws -> IconRecord? {
        let url = recordURL(app)
        guard fm.fileExists(atPath: url.path) else { return nil }
        let r = try JSONDecoder().decode(IconRecord.self, from: Data(contentsOf: url))
        let hashes = [r.original, r.current, r.preview] + [r.pending, r.intermediate].compactMap { $0 }
        guard hashes.allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) else {
            throw Problem("Invalid BetterIcon backup record.")
        }
        return r
    }
    private func original(_ rec: IconRecord) throws -> FinderIcon {
        let snapshot = try PropertyListDecoder().decode(
            FinderIcon.self, from: Data(contentsOf: stateURL(rec.original)))
        guard snapshot.signature == rec.original else {
            throw Problem("The original icon backup failed verification.")
        }
        return snapshot
    }
    func defaultPreview(_ app: AppEntry) -> URL? {
        guard let r = try? readRecord(app), (try? identity(app)) == r.identity else { return nil }
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
        guard let info = try? Data(contentsOf: app.launchURL.appendingPathComponent("Contents/Info.plist")),
            let plist = try? PropertyListSerialization.propertyList(from: info, options: [], format: nil)
                as? [String: Any],
            plist["CFBundleIdentifier"] as? String == app.bundleID
        else { throw Problem("The app identity changed.") }
        return "\(st.st_dev)/\(st.st_ino)/\(app.bundleID)/\(digest(info))"
    }
    func review(apps: [AppEntry], pack: Pack, scope: Scope, restore: Bool, only: String? = nil) -> Review {
        let rows = apps.filter { $0.scope == scope && (only == nil || $0.craft == only) }.map { app -> ReviewRow in
            var row = ReviewRow(app: app, message: "")
            do {
                row.identity = try identity(app)
                let snapshot = try FinderIcon.capture(app.url, alias: app.usesFileFork)
                row.before = snapshot.signature
                let rec = try readRecord(app)
                if let rec {
                    row.record = [rec.identity, rec.original, rec.current, rec.pending ?? ""].joined(
                        separator: "/")
                    let interrupted =
                        rec.pending != nil && [rec.pending, rec.intermediate].contains(snapshot.artworkSignature)
                    guard rec.identity == row.identity, rec.current == row.before || interrupted else {
                        throw Problem("App or icon changed outside BetterIcon. Preserved.")
                    }
                    _ = try original(rec)
                }
                if restore {
                    guard let rec, row.before != rec.original else {
                        row.alreadyDefault = rec != nil || !snapshot.custom
                        row.message =
                            row.alreadyDefault
                            ? "Already at its original icon" : "Existing custom icon • no BetterIcon backup"
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
                row.message =
                    restore
                    ? "Restore original icon"
                    : (app.isDocument ? "Change project file icon" : (app.isAlias ? "Change Finder alias icon" : "Change application icon"))
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
        guard NSWorkspace.shared.setIcon(image, forFile: stage.path, options: []) else {
            throw Problem("macOS could not prepare this custom icon.")
        }
        return (image, try FinderIcon.capture(stage, alias: app.usesFileFork))
    }
    func perform(_ plan: Review, apps: [AppEntry], pack: Pack) throws -> IconResult {
        try withStateLock(root.appendingPathComponent("operations.lock"), blocking: false) {
            try performLocked(plan, apps: apps, pack: pack)
        }
    }
    private func performLocked(_ plan: Review, apps: [AppEntry], pack: Pack) throws -> IconResult {
        let fresh = review(apps: apps, pack: pack, scope: plan.scope, restore: plan.restore, only: plan.only)
        guard fresh.rows == plan.rows else {
            throw Problem("The apps, icons, or backups changed since review. Review the operation again.")
        }
        var result = IconResult()
        for row in plan.rows {
            if row.alreadyDefault { result.defaults.append(row.app.url.path) }
            guard row.change else { continue }
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
                var rec = try readRecord(app) ?? backup(before, app, row.identity)
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
                }
                // Durably record both sides before touching the application. A
                // restart can recognize a completed or unapplied write.
                rec.current = before.signature
                rec.pending = desired.artworkSignature
                try save(rec, at: recordURL(app))
                guard try identity(app) == row.identity,
                    try FinderIcon.capture(app.url, alias: app.usesFileFork) == before
                else { throw Problem("App changed during preparation.") }
                guard ws.setIcon(image, forFile: path, options: []) else {
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
                    try save(rec, at: recordURL(app))
                }
                result.changed.append(path)
            } catch { result.errors.append("\(row.app.name) — \(error.localizedDescription)") }
        }
        return result
    }
}
