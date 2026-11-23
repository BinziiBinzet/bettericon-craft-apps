import AppKit
import UniformTypeIdentifiers

/// Which ArtCraft app opens a file by default, for the files of types outside BetterIcon's list (ProjectFileTypes.json).
/// Such a file takes the file type pack's art for that app, when the pack has art for all of that app's files that its
/// artist named FileTypes/<App>-files.
///
/// Launch Services is asked about the file itself, so a file given another app with Get Info's "Open with" counts. A
/// file without such a choice of its own (the com.apple.LaunchServices.OpenWith extended attribute) opens with the
/// default app of its type, which one pass asks once per extension. Each pass makes its own instance, so a default the
/// user changes is seen at the next pass.
final class FileOpeners {
    /// The app Launch Services opens a file with. The checks replace it.
    static var lookup: (URL) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    /// The ArtCraft app an app bundle is, told the way BetterIcon tells the apps it finds. The checks replace it.
    static var identify: (URL) -> String? = { AppCatalog.identify($0)?.craft }
    static let openWith = "com.apple.LaunchServices.OpenWith"
    /// The app that opens a file by default, if any, and the ArtCraft app it is, if it is one.
    struct Opener {
        let app: URL?
        let craft: String?
    }
    private let lock = NSLock()
    private var byExtension = [String: Opener]()
    private var byApp = [String: String?]()
    private var asked = 0
    /// How often this pass asked Launch Services.
    var lookups: Int {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }
    init() {}
    /// The ArtCraft app that opens this file by default, or nil.
    func craft(for file: URL) -> String? { opener(for: file).craft }
    /// The app that opens this file by default, and which ArtCraft app it is.
    func opener(for file: URL) -> Opener {
        let ext = file.pathExtension.lowercased()
        let own = getxattr(file.path, Self.openWith, nil, 0, 0, XATTR_NOFOLLOW) >= 0
        lock.lock()
        let known = own ? nil : byExtension[ext]
        lock.unlock()
        if let known { return known }
        lock.lock()
        asked += 1
        lock.unlock()
        let found = Self.lookup(file).map { Opener(app: $0, craft: app($0)) } ?? Opener(app: nil, craft: nil)
        if !own {
            lock.lock()
            byExtension[ext] = found
            lock.unlock()
        }
        return found
    }
    private func app(_ bundle: URL) -> String? {
        let key = bundle.standardizedFileURL.path
        lock.lock()
        let known = byApp[key]
        lock.unlock()
        if let known { return known }
        let craft = Self.identify(bundle)
        lock.lock()
        byApp[key] = .some(craft)
        lock.unlock()
        return craft
    }
}

/// One review of files chosen in Apply file icons… or Restore file icons…, with the pack it applies.
struct FilePlan {
    let review: Review
    let apps: [AppEntry]
    let pack: Pack
    /// Files of types outside the list whose opener no longer gets art from the pack: BetterIcon restores their icons.
    var releasing = false
}

/// The kinds of items the file panel of Apply file icons… and Restore file icons… offers. Folders and regular files, and
/// never an app or a document package: its insides belong to the app or document, and changing them breaks an app's
/// signature. Apply offers the listed formats the pack draws, and every file while the pack draws other file types too
/// (`catchAll`) or chosen files carry such an icon from BetterIcon, which the next Apply may take off again.
func filePanelTypes(restore: Bool, formats: [ProjectFormat], catchAll: Bool) -> [UTType] {
    guard !restore && !catchAll else { return [.folder, .data] }
    return [.folder] + formats.flatMap(\.extensions).compactMap { UTType(filenameExtension: String($0.dropFirst())) }
}

extension AppIcons {
    /// The reviews for files the user chose, and the chosen files that get nothing, each with a reason. A listed format
    /// takes the artwork for its design, as always. With Apply, a file of a type outside the list takes the pack's art for
    /// the ArtCraft app that opens it by default, asked file by file; a file whose icon BetterIcon set that way, and whose
    /// opener no longer gets art, has its saved icon back. With Restore, every chosen file has its saved icon back. Such a
    /// file is recorded under its own extension, so Restore finds it whatever opens it now. A file whose icon comes from a
    /// folder BetterIcon keeps up to date is that folder's: two owners of one icon would undo each other's work.
    func filePlans(
        _ urls: [URL], pack: Pack, artwork: [String: URL], formats: [ProjectFormat], restore: Bool,
        unlisted: (URL) -> Bool, openers: FileOpeners
    ) -> (plans: [FilePlan], skipped: [(name: String, reason: String)]) {
        let covered = restore ? formats : formats.filter { artwork[$0.Key] != nil }
        func entry(_ file: URL, _ craft: String) -> AppEntry {
            AppEntry(name: file.lastPathComponent, craft: craft, url: file, launchURL: file, bundleID: "", scope: .personal,
                isDocument: true)
        }
        var listed = [AppEntry](), releasing = [AppEntry]()
        var groups = [(art: URL, apps: [AppEntry])]()
        var skipped = [(name: String, reason: String)]()
        for file in urls {
            let ext = "." + file.pathExtension.lowercased()
            if getxattr(file.path, FolderIcons.marker, nil, 0, 0, XATTR_NOFOLLOW) >= 0, !(restore && hasRecord(file.path)) {
                skipped.append((file.lastPathComponent,
                    "Its icon comes from a folder BetterIcon keeps up to date" + (restore ? ". Restore that folder to remove it" : "")))
                continue
            }
            if formats.contains(where: { $0.extensions.contains(ext) }) {
                if let format = covered.first(where: { $0.extensions.contains(ext) }) {
                    listed.append(entry(file, format.Key))
                } else {
                    skipped.append((file.lastPathComponent, "No artwork in this pack"))
                }
                continue
            }
            guard unlisted(file) else {
                skipped.append((file.lastPathComponent,
                    file.pathExtension.isEmpty ? "Files without an extension are left alone"
                        : "Folders, packages, links, Finder aliases and apps are left alone"))
                continue
            }
            let target = entry(file, ext)
            if restore {
                listed.append(target)
            } else if !pack.unlisted.isEmpty, let craft = openers.craft(for: file), let art = pack.unlisted[craft] {
                if let index = groups.firstIndex(where: { $0.art == art }) { groups[index].apps.append(target) }
                else { groups.append((art, [target])) }
            } else if hasRecord(file.path) {
                releasing.append(target)
            } else {
                skipped.append((file.lastPathComponent,
                    openers.opener(for: file).app == nil ? "No app opens it" : "Opens with an app this pack has no art for"))
            }
        }
        var plans = [FilePlan]()
        if !listed.isEmpty {
            let filePack = Pack(id: pack.id, name: pack.name, author: pack.author, icons: artwork)
            plans.append(FilePlan(review: review(apps: listed, pack: filePack, scope: .personal, restore: restore),
                apps: listed, pack: filePack))
        }
        for group in groups {
            // The files of one app's art, under their own extensions.
            let art = Dictionary(group.apps.map { ($0.craft, group.art) }, uniquingKeysWith: { first, _ in first })
            let filePack = Pack(id: pack.id, name: pack.name, author: pack.author, icons: art)
            plans.append(FilePlan(review: review(apps: group.apps, pack: filePack, scope: .personal, restore: false),
                apps: group.apps, pack: filePack))
        }
        if !releasing.isEmpty {
            plans.append(FilePlan(review: review(apps: releasing, pack: .defaults, scope: .personal, restore: true),
                apps: releasing, pack: .defaults, releasing: true))
        }
        return (plans, skipped)
    }
}
