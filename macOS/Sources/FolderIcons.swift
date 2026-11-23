import AppKit
import CoreServices
import Darwin

/// File icons for whole folders.
///
/// macOS takes a file type's icon from the app that opens it, so a pack cannot set one icon for a type.
/// Instead BetterIcon puts the pack's icon on every matching file in the folders the user picks, and on
/// new files as they appear there. Each file it changes carries a marker, so its own work can be told
/// from an icon the user gave a file, and undone without a record of every file.
struct FolderIconResult {
    var changed = 0
    /// Files that already show this artwork.
    var current = 0
    /// Files with an icon or resource data of their own, which are left alone.
    var kept = 0
    var restored = 0
    var errors = [String]()
    static func + (a: FolderIconResult, b: FolderIconResult) -> FolderIconResult {
        FolderIconResult(
            changed: a.changed + b.changed, current: a.current + b.current, kept: a.kept + b.kept,
            restored: a.restored + b.restored, errors: a.errors + b.errors)
    }
}

final class FolderIcons {
    /// On each file BetterIcon changed: the checksum of the artwork the file shows.
    static let marker = "com.omegadarling.bettericon.file-icon"
    /// Also on a file of a type outside BetterIcon's list that took its opener's art: a checksum of the icon BetterIcon
    /// put in its resource fork. The icon is still BetterIcon's while the two match.
    static let unlistedMarker = "com.omegadarling.bettericon.file-icon.unlisted"
    /// Extension, lowercased with its dot, to the design that draws it.
    private let designs: [String: String]
    private var images = [String: NSImage]()
    private var checksums = [String: String]()
    private let lock = NSLock()
    /// Held while a pass changes one file. Apply, Restore, the catch-up at start and the folder watcher change files in
    /// turn, and a pass asks its gate under this lock: once a folder's job changes, no pass starts on one of its files with
    /// the old job, and `exclusively {}` waits for the file another pass is changing.
    private let passLock = NSLock()

    /// What a pass started for a watched folder may do with its next file: change it, leave it to another job (the user's
    /// own Apply or Restore, or a watched folder inside this one), or stop because its job is over.
    enum Gate { case go, skip, stop }

    /// Run `body` while no pass changes a file.
    func exclusively<T>(_ body: () throws -> T) rethrows -> T {
        passLock.lock()
        defer { passLock.unlock() }
        return try body()
    }

    init(formats: [ProjectFormat]) {
        var map = [String: String]()
        for format in formats {
            for ext in format.extensions { map[ext.lowercased()] = format.Key }
        }
        designs = map
    }

    /// The design for a file, when the pack draws one for its extension.
    func artwork(for file: URL, in art: [String: URL]) -> URL? {
        designs["." + file.pathExtension.lowercased()].flatMap { art[$0] }
    }

    /// Whether a file's name has an extension the list does not name. Reads nothing from the disk.
    func isUnlistedType(_ file: URL) -> Bool {
        let ext = file.pathExtension.lowercased()
        return !ext.isEmpty && designs["." + ext] == nil
    }

    /// Whether a file can take art for a type outside the list: a regular file with such an extension that is no link,
    /// Finder alias or application. Folders and packages are no regular files.
    func unlisted(_ file: URL) -> Bool {
        guard isUnlistedType(file),
            let v = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey, .isApplicationKey])
        else { return false }
        return v.isRegularFile == true && v.isSymbolicLink != true && v.isAliasFile != true && v.isApplication != true
    }

    /// Whether a file is out of a folder pass's reach below a watched folder: hidden itself, or in a hidden folder or
    /// inside a package, which a folder pass does not look into. The watcher reports such files too.
    static func tucked(_ file: URL, below prefix: String) -> Bool {
        if (try? file.resourceValues(forKeys: [.isHiddenKey]).isHidden) == true { return true }
        var folder = file.deletingLastPathComponent()
        while folder.path.hasPrefix(prefix + "/") {
            let values = try? folder.resourceValues(forKeys: [.isPackageKey, .isHiddenKey])
            if folder.lastPathComponent.hasPrefix(".") || values?.isPackage == true || values?.isHidden == true {
                return true
            }
            folder = folder.deletingLastPathComponent()
        }
        return false
    }

    /// Whether a file carries BetterIcon's mark of art for a type outside the list. One read, of an extended attribute.
    func carriesUnlisted(_ file: URL) -> Bool { getxattr(file.path, Self.unlistedMarker, nil, 0, 0, XATTR_NOFOLLOW) >= 0 }

    /// Each regular file below a folder that `wanted` takes, as the walk comes to it, or the folder itself when it is a
    /// file that `wanted` takes. Hidden files, the insides of packages and the folders in `skipping` (full paths, as the
    /// walk names them) are passed over. `wanted` sees each item before anything else is read from the disk. `visit`
    /// returns false to end the walk. A large folder is walked file by file, so memory stays flat.
    private func walk(_ folder: URL, skipping: Set<String> = [], _ wanted: (URL) -> Bool, _ visit: (URL) -> Bool) {
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isFolder) else { return }
        if !isFolder.boolValue {
            if wanted(folder) { _ = visit(folder) }
            return
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard
            let walker = fm.enumerator(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return }
        var going = true
        while going {
            going = autoreleasepool {
                guard let file = walker.nextObject() as? URL else { return false }
                if !skipping.isEmpty, skipping.contains(file.path) {
                    walker.skipDescendants()
                    return true
                }
                guard wanted(file), let values = try? file.resourceValues(forKeys: Set(keys)),
                    values.isRegularFile == true, values.isSymbolicLink != true
                else { return true }
                return visit(file)
            }
        }
    }

    /// Every regular file below a folder that the artwork covers. Hidden files and the insides of packages are skipped.
    func files(in folder: URL, art: [String: URL]) -> [URL] {
        var found = [URL]()
        walk(folder, { artwork(for: $0, in: art) != nil }) { file in
            found.append(file)
            return true
        }
        return found
    }

    /// Whether a pass with this art looks at a file at all: a listed format it has a design for, a file of another type
    /// while it has art for other types, and any file that still carries BetterIcon's icon for other types, which may
    /// have to come off. Of any other file it reads one extended attribute and nothing else.
    private func inScope(_ file: URL, art: [String: URL], unlisted: [String: URL]) -> Bool {
        artwork(for: file, in: art) != nil || (!unlisted.isEmpty && isUnlistedType(file)) || carriesUnlisted(file)
    }

    /// What a pass over a folder would do now, for the confirmation: how many files it gives the pack's icons, those that
    /// show them already included, and how many lose the icon BetterIcon gave them as files of other types.
    func preview(
        _ folder: URL, art: [String: URL], unlisted: [String: URL], openers: FileOpeners, skipping: Set<String> = []
    ) -> (covered: Int, removed: Int) {
        var covered = 0, removed = 0
        walk(folder, skipping: skipping, { inScope($0, art: art, unlisted: unlisted) }) { file in
            if artwork(for: file, in: art) != nil {
                covered += 1
                return true
            }
            if !unlisted.isEmpty, isUnlistedType(file) {
                guard self.unlisted(file) else { return true }
                if let craft = openers.craft(for: file), unlisted[craft] != nil {
                    covered += 1
                    return true
                }
            }
            if (try? ownsUnlistedIcon(file)) == true { removed += 1 }
            return true
        }
        return (covered, removed)
    }

    /// Files below a folder that carry BetterIcon's marker, whatever their type.
    func marked(in folder: URL) -> [URL] {
        var found = [URL]()
        walk(folder, { getxattr($0.path, Self.marker, nil, 0, 0, XATTR_NOFOLLOW) >= 0 }) { file in
            found.append(file)
            return true
        }
        return found
    }

    /// Put the pack's icons on the matching files in a folder, or on one file. A file of a type outside the list takes
    /// the pack's art for the ArtCraft app that opens it by default (`unlisted`, by app), and loses BetterIcon's icon once
    /// its opener gets no art; such removals count as restored. One `openers` serves the whole pass. The folders in
    /// `skipping` (watched folders inside this one, which keep their own pack) are left out. `gate`, asked before each
    /// file, lets a pass for a watched folder give way to the user's own Apply or Restore and stop once its job is over.
    func apply(
        _ folder: URL, art: [String: URL], unlisted: [String: URL] = [:], openers: FileOpeners = FileOpeners(),
        skipping: Set<String> = [], gate: ((URL) -> Gate)? = nil
    ) -> FolderIconResult {
        var result = FolderIconResult()
        walk(folder, skipping: skipping, { inScope($0, art: art, unlisted: unlisted) }) { file in
            exclusively {
                switch gate?(file) ?? .go {
                case .stop: return false
                case .skip: return true
                case .go: break
                }
                do {
                    switch try pass(file, art: art, unlisted: unlisted, openers: openers) {
                    case .changed?: result.changed += 1
                    case .current?: result.current += 1
                    case .kept?: result.kept += 1
                    case .removed?: result.restored += 1
                    case nil: break
                    }
                } catch { result.errors.append(file.lastPathComponent + " — " + error.localizedDescription) }
                return true
            }
        }
        return result
    }

    /// Take BetterIcon's icons off the files in a folder again. Files it never changed are left alone, and so is an icon
    /// the user put over the one BetterIcon gave a file of a type outside the list.
    func restore(_ folder: URL) -> FolderIconResult {
        var result = FolderIconResult()
        walk(folder, { getxattr($0.path, Self.marker, nil, 0, 0, XATTR_NOFOLLOW) >= 0 }) { file in
            exclusively {
                do {
                    // The mark of art for other types tells the user's icon from BetterIcon's only on a file of such a type.
                    // A file renamed to a listed format since shows the design of that format.
                    var print: String?
                    if isUnlistedType(file) {
                        print = try attribute(Self.unlistedMarker, file).map { String(decoding: $0, as: UTF8.self) }
                    }
                    if let print, try hasIcon(file), print != iconPrint(file) {
                        try forget(file)
                        result.kept += 1
                        return true
                    }
                    try keepingDate(file) {
                        guard setFinderIcon(nil, file.path) else {
                            throw Problem("macOS declined to remove the icon.")
                        }
                        try dropEmptyFork(file)
                        try putAttribute(Self.marker, nil, file)
                        if carriesUnlisted(file) { try putAttribute(Self.unlistedMarker, nil, file) }
                    }
                    result.restored += 1
                } catch { result.errors.append(file.lastPathComponent + " — " + error.localizedDescription) }
                return true
            }
        }
        return result
    }

    /// What a pass did to a file. `removed`: BetterIcon took its own icon off a file of a type outside the list.
    enum Outcome { case changed, current, kept, removed }

    /// One file of a pass: Apply, the watcher or the catch-up at start. A listed format takes its design, as always. A
    /// file of another type takes the pack's art for the ArtCraft app that opens it by default. Once that no longer holds
    /// (its opener changed, or the pack has no such art now), BetterIcon takes its icon off again, while it is still
    /// BetterIcon's. Nil when there is nothing to do.
    func pass(_ file: URL, art: [String: URL], unlisted: [String: URL], openers: FileOpeners) throws -> Outcome? {
        if let design = artwork(for: file, in: art) { return try stamp(file, with: design) }
        // A listed format the pack has no design for, and a file without an extension, never take art for other types:
        // such an icon from BetterIcon, given before a rename or before the type joined the list, comes off.
        guard isUnlistedType(file) else { return try release(file) ? .removed : nil }
        // Without such art the opener does not matter: only an icon BetterIcon set for it may have to go.
        guard !unlisted.isEmpty else { return try release(file) ? .removed : nil }
        guard self.unlisted(file) else { return nil }
        if let craft = openers.craft(for: file), let design = unlisted[craft] { return try stampUnlisted(file, with: design) }
        return try release(file) ? .removed : nil
    }

    /// Give a file of a type outside the list its opener's art. As for a listed format, a file with an icon or resource
    /// data of its own and no marker is left alone. An icon put over BetterIcon's since is the user's: BetterIcon forgets
    /// the file and leaves it alone from then on.
    func stampUnlisted(_ file: URL, with art: URL) throws -> Outcome {
        let checksum = try self.checksum(art)
        let mark = try attribute(Self.marker, file).map { String(decoding: $0, as: UTF8.self) }
        let print = try attribute(Self.unlistedMarker, file).map { String(decoding: $0, as: UTF8.self) }
        let iconHere = try hasIcon(file)
        if mark == nil, iconHere { return .kept }
        if mark != nil, let print, iconHere, print != iconPrint(file) {
            try forget(file)
            return .kept
        }
        if mark == checksum, print != nil, try customFlag(file), hasFork(file) { return .current }
        let image = try self.image(art)
        try keepingDate(file) {
            try setIcon(image, file)
            try putAttribute(Self.marker, Data(checksum.utf8), file)
            try putAttribute(Self.unlistedMarker, Data(iconPrint(file).utf8), file)
        }
        return .changed
    }

    /// Whether a file carries the icon BetterIcon gave it as a file of a type outside the list, still as it was set.
    private func ownsUnlistedIcon(_ file: URL) throws -> Bool {
        guard carriesUnlisted(file) else { return false }
        let print = try attribute(Self.unlistedMarker, file).map { String(decoding: $0, as: UTF8.self) }
        return try attribute(Self.marker, file) != nil && hasIcon(file) && print == iconPrint(file)
    }

    /// Take BetterIcon's icon off a file of a type outside the list when it is still the icon BetterIcon set there. An
    /// icon the user put over it stays, and BetterIcon forgets the file. True when BetterIcon's icon came off.
    func release(_ file: URL) throws -> Bool {
        guard carriesUnlisted(file) else { return false }
        let ours = try ownsUnlistedIcon(file)
        try keepingDate(file) {
            if ours {
                guard setFinderIcon(nil, file.path) else {
                    throw Problem("macOS declined to remove the icon.")
                }
                try dropEmptyFork(file)
            }
            try putAttribute(Self.marker, nil, file)
            try putAttribute(Self.unlistedMarker, nil, file)
        }
        return ours
    }

    /// What remains of BetterIcon's icon once setIcon(nil) is done. It leaves an empty resource fork behind, and under load
    /// the icon data itself without the custom-icon flag was seen once: either would make the file look as if it had
    /// resource data of its own, so a later pass would leave it alone. BetterIcon changes only files that had no resource
    /// fork before, so a fork that holds nothing but an icon on a file it restores is its own leftover. A fork with other
    /// resources is left, and so is the flag of anything but BetterIcon's icon.
    private func dropEmptyFork(_ file: URL) throws {
        if let fork = try attribute(resourceFork, file), iconOnlyResourceFork(fork) { try putAttribute(resourceFork, nil, file) }
        guard try customFlag(file), getxattr(file.path, resourceFork, nil, 0, 0, XATTR_NOFOLLOW) < 0,
            var info = try attribute("com.apple.FinderInfo", file), info.count == 32
        else { return }
        info[8] &= ~4
        try putAttribute("com.apple.FinderInfo", info.allSatisfy { $0 == 0 } ? nil : info, file)
    }

    /// Drop BetterIcon's marks from a file, leaving its icon as it is.
    private func forget(_ file: URL) throws {
        try keepingDate(file) {
            try putAttribute(Self.marker, nil, file)
            try putAttribute(Self.unlistedMarker, nil, file)
        }
    }

    private func hasFork(_ file: URL) -> Bool { getxattr(file.path, resourceFork, nil, 0, 0, XATTR_NOFOLLOW) >= 0 }
    /// Whether the file shows a custom icon or carries resource data, as a custom icon leaves.
    private func hasIcon(_ file: URL) throws -> Bool { try customFlag(file) || hasFork(file) }
    /// What the icon in a file's resource fork looks like: a checksum of its icon family, or "none".
    private func iconPrint(_ file: URL) -> String {
        guard let fork = try? attribute(resourceFork, file) else { return "none" }
        return digest(iconFamily(inFork: fork) ?? fork)
    }

    /// Give one file the artwork. A file with its own icon or resource data, and no marker, is left alone. A file BetterIcon
    /// gave art for other types before it was renamed to a listed format loses that mark, so a Restore later reads the
    /// design of its format as BetterIcon's; an icon the user put over that art before the rename stays theirs.
    func stamp(_ file: URL, with art: URL) throws -> Outcome {
        let checksum = try self.checksum(art)
        let mark = try attribute(Self.marker, file).map { String(decoding: $0, as: UTF8.self) }
        let hasIcon = try customFlag(file)
        let hasFork = getxattr(file.path, resourceFork, nil, 0, 0, XATTR_NOFOLLOW) >= 0
        if mark == nil, hasIcon || hasFork { return .kept }
        let stale = carriesUnlisted(file)
        if mark == checksum, hasIcon, hasFork {
            if stale { try keepingDate(file) { try putAttribute(Self.unlistedMarker, nil, file) } }
            return .current
        }
        if stale, hasIcon || hasFork, try !ownsUnlistedIcon(file) {
            try forget(file)
            return .kept
        }
        let image = try self.image(art)
        try keepingDate(file) {
            try setIcon(image, file)
            try putAttribute(Self.marker, Data(checksum.utf8), file)
            if stale { try putAttribute(Self.unlistedMarker, nil, file) }
        }
        return .changed
    }

    /// Put an icon on a file. When macOS declines, a resource fork it left empty is taken off again: BetterIcon puts icons
    /// only on files without resource data or with its own icon, so an empty one is that attempt's, and it would make the
    /// file look as if it had resource data of its own at the next pass.
    private func setIcon(_ image: NSImage, _ file: URL) throws {
        guard setFinderIcon(image, file.path) else {
            if let fork = try? attribute(resourceFork, file), iconOnlyResourceFork(fork), iconFamily(inFork: fork) == nil {
                try? putAttribute(resourceFork, nil, file)
            }
            throw Problem("macOS declined the icon change. Check that the file can be changed.")
        }
    }

    /// Changing an icon is not an edit of the document. Its modification date stays as it was.
    private func keepingDate(_ file: URL, _ change: () throws -> Void) throws {
        let date = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        defer { if let date { try? fm.setAttributes([.modificationDate: date], ofItemAtPath: file.path) } }
        try change()
    }

    private func checksum(_ art: URL) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let known = checksums[art.path] { return known }
        let value = digest(try Artwork.load(art))
        checksums[art.path] = value
        return value
    }

    private func image(_ art: URL) throws -> NSImage {
        lock.lock()
        defer { lock.unlock() }
        if let known = images[art.path] { return known }
        let data = try Artwork.load(art)
        try Artwork.validate(data, ext: art.pathExtension.lowercased())
        guard let source = NSImage(data: data), source.isValid else { throw Problem("The artwork could not be read.") }
        // One bitmap large enough for every size the Finder draws.
        let pixels = min(1024, max(256, Artwork.dimension(art)))
        guard let image = NSImage(data: try Artwork.png(source, pixels: pixels)) else {
            throw Problem("The artwork could not be drawn.")
        }
        images[art.path] = image
        return image
    }
}

/// A folder's path as FSEvents names the files in it: every link resolved, and /private kept, which Foundation's
/// standardized paths drop (/tmp/x is /private/tmp/x). A path that cannot be resolved stays as it is.
func realFolderPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Watches the chosen folders and reports each file that is created, renamed or changed in them.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let changed: ([URL]) -> Void
    private let queue = DispatchQueue(label: "com.omegadarling.bettericon.folder-icons")

    init(changed: @escaping ([URL]) -> Void) { self.changed = changed }
    deinit { stop() }

    func watch(_ folders: [URL]) {
        stop()
        guard !folders.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info, let list = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            var files = [URL]()
            for index in 0..<count where Int(flags[index]) & kFSEventStreamEventFlagItemIsFile != 0 {
                files.append(URL(fileURLWithPath: list[index]))
            }
            if !files.isEmpty { watcher.changed(files) }
        }
        let options = UInt32(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard
            let created = FSEventStreamCreate(
                nil, callback, &context, folders.map(\.path) as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, options)
        else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
