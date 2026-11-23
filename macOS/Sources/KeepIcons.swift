import AppKit
import CoreServices
import Darwin

/// Watches the folders apps are found in and reports app bundles that are replaced, added, removed or given
/// another icon there.
///
/// ArtCraft Launcher and the apps' own updaters copy a new version into a hidden folder beside the app, then
/// rename the old copy away and the new one into place. FSEvents reports the second rename as an event on the
/// bundle path that carries the new copy's file ID. Hidden items, such as the staging and backup folders, are
/// ignored, and so are BetterIcon's own icon writes, which the system marks as this process's own. An app is
/// reported once it has been quiet for a moment and the item at its path is the one the last event named.
final class AppsWatcher {
    private struct Root {
        let shown: String
        let real: String
        let topLevel: Bool
    }
    private struct Pending {
        var fileID: UInt64?
        var generation = 0
        var checks = 0
    }
    /// How long an app must be quiet before it is reported.
    static var quiet: TimeInterval = 0.75
    private let changed: (Set<String>) -> Void
    private let rescan: () -> Void
    private let queue = DispatchQueue(label: "com.omegadarling.bettericon.app-folders")
    private var stream: FSEventStreamRef?
    private var roots = [Root]()
    private var watching = [String]()
    private var pending = [String: Pending]()

    /// `changed` receives app paths standardized as discovery gives them, such as /tmp for /private/tmp.
    /// `rescan` is called when the system dropped events, so every app should be looked at. Both are called on
    /// the watcher's own queue.
    init(changed: @escaping (Set<String>) -> Void, rescan: @escaping () -> Void = {}) {
        self.changed = changed
        self.rescan = rescan
    }
    deinit { stopStream() }

    /// Watch these folders. A top-level folder, such as the Desktop, reports only the apps directly inside it. A
    /// folder that does not exist yet is left out until it is watched again after it appears.
    func watch(_ folders: [(url: URL, topLevel: Bool)]) {
        var list = [Root]()
        for (url, topLevel) in folders {
            let shown = url.standardizedFileURL.path
            var isFolder: ObjCBool = false
            guard fm.fileExists(atPath: shown, isDirectory: &isFolder), isFolder.boolValue,
                !list.contains(where: { $0.shown == shown })
            else { continue }
            // FSEvents reports paths with symbolic links resolved, such as /private/tmp for /tmp.
            var real = shown
            if let resolved = realpath(shown, nil) {
                real = String(cString: resolved)
                free(resolved)
            }
            list.append(Root(shown: shown, real: real, topLevel: topLevel))
        }
        // The most specific folder decides, so an apps folder inside the Desktop counts as an apps folder.
        list.sort { $0.real.count > $1.real.count }
        queue.sync {
            let key = list.map { $0.shown + ($0.topLevel ? " (top level)" : "") }
            guard key != watching || (stream == nil && !list.isEmpty) else { return }
            stopStream()
            roots = list
            watching = key
            pending.removeAll()
            guard !list.isEmpty else { return }
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
                copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                guard let info else { return }
                Unmanaged<AppsWatcher>.fromOpaque(info).takeUnretainedValue().received(count, paths, flags)
            }
            let options = UInt32(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagUseExtendedData
                    | kFSEventStreamCreateFlagMarkSelf)
            var paths = [String]()
            for root in list where !paths.contains(root.real) { paths.append(root.real) }
            guard
                let created = FSEventStreamCreate(
                    nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
                    options)
            else { return }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                return
            }
            stream = created
        }
    }

    func stop() {
        queue.sync {
            stopStream()
            watching = []
            pending.removeAll()
        }
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func received(
        _ count: Int, _ paths: UnsafeMutableRawPointer, _ flags: UnsafePointer<FSEventStreamEventFlags>
    ) {
        let list = unsafeBitCast(paths, to: NSArray.self)
        var sweep = false
        for index in 0..<count {
            let flag = Int(flags[index])
            let dropped =
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
            if flag & dropped != 0 {
                sweep = true
                continue
            }
            if flag & kFSEventStreamEventFlagOwnEvent != 0 { continue }
            var fileID: UInt64?
            let path: String
            if let entry = list[index] as? NSDictionary {
                guard let text = entry["path"] as? String else { continue }
                path = text
                fileID = (entry["fileID"] as? NSNumber)?.uint64Value
            } else if let text = list[index] as? String {
                path = text
            } else {
                continue
            }
            guard let found = candidate(path) else { continue }
            // An event on the icon file inside the bundle carries that file's ID, not the bundle's.
            note(found.app, fileID: found.isBundle ? fileID : nil)
        }
        if sweep { rescan() }
    }

    /// The app an event concerns: an .app item in a watched folder, or the custom icon file directly inside one.
    private func candidate(_ reported: String) -> (app: String, isBundle: Bool)? {
        let data = "/System/Volumes/Data"
        let path = reported.hasPrefix(data + "/") ? String(reported.dropFirst(data.count)) : reported
        for root in roots {
            for base in [root.real, root.shown] where path.hasPrefix(base + "/") {
                let parts = path.dropFirst(base.count + 1).split(separator: "/").map(String.init)
                // Hidden items, such as the Launcher's staging and backup folders, are never apps in use.
                guard !parts.isEmpty, !parts.contains(where: { $0.hasPrefix(".") }),
                    let index = parts.firstIndex(where: { $0.lowercased().hasSuffix(".app") })
                else { return nil }
                // A top-level folder counts only the apps directly inside it. A deeper app can still belong to an
                // apps folder of its own further down the list.
                guard !root.topLevel || index == 0 else { break }
                let app = ([root.shown] + parts[...index]).joined(separator: "/")
                if index == parts.count - 1 { return (app, true) }
                let inside = Array(parts[(index + 1)...])
                if inside == ["Icon\r"] { return (app, false) }
                // A copy into the folder writes the bundle file by file, often with Info.plist last. Its Info.plist,
                // executable and signature count as activity on the app, so it is reported once the copy is quiet.
                if inside.count >= 2, inside[0] == "Contents", ["Info.plist", "MacOS", "_CodeSignature"].contains(inside[1]) {
                    return (app, false)
                }
                // Other changes deeper inside a bundle leave its icon alone.
                return nil
            }
        }
        return nil
    }

    private func note(_ app: String, fileID: UInt64?) {
        var entry = pending[app] ?? Pending()
        if let fileID { entry.fileID = fileID }
        entry.generation += 1
        entry.checks = 0
        pending[app] = entry
        settle(app, after: entry.generation)
    }

    private func settle(_ app: String, after generation: Int) {
        queue.asyncAfter(deadline: .now() + Self.quiet) { [weak self] in self?.report(app, generation) }
    }

    /// Report an app that stayed quiet, once the item at its path is the one the last event named.
    private func report(_ app: String, _ generation: Int) {
        guard var entry = pending[app], entry.generation == generation else { return }
        var st = stat()
        if lstat(app, &st) == 0, let fileID = entry.fileID, UInt64(st.st_ino) != fileID, entry.checks < 3 {
            // The item in place is not the one the last event named: another rename is on its way.
            entry.checks += 1
            entry.generation += 1
            pending[app] = entry
            settle(app, after: entry.generation)
            return
        }
        pending[app] = nil
        changed([app])
    }
}

/// Puts BetterIcon's icons back on apps after updates, and gives new apps the applied pack.
///
/// Every trigger feeds this one serial queue: the folder watcher names apps, while the start, each refresh of the
/// installed apps and a 30-minute timer ask for all of them. Requests that arrive while a pass runs are kept for
/// the next one, so none is lost. A pass waits while the user reviews an Apply or Restore, tries again shortly
/// when another operation holds the lock, and looks again at apps that are in the middle of an update.
final class IconKeeper {
    struct Context {
        let apps: [AppEntry]
        let appliedPack: String?
        let defaultPaths: Set<String>
        let appliedArt: [String: String]?
        /// New apps that get the applied pack, or nil when none do.
        var adoption: Adoption? = nil
    }
    /// Called on the main thread before each pass. Nil holds the pass off for a moment.
    var context: (() -> Context?)?
    /// Called on the main thread after a pass that changed or found something to report.
    var finished: ((Reconciled) -> Void)?
    private let icons: AppIcons
    private let catalog: AppCatalog
    private let queue = DispatchQueue(label: "com.omegadarling.bettericon.keep-icons", qos: .utility)
    private var all = false
    private var named = Set<String>()
    private var armed = false
    /// While the user reviews an Apply or Restore no pass starts. Only touched on the queue.
    private var paused = false
    private let flags = NSLock()
    /// Whether a pass is under way, and whether BetterIcon is quitting. Read from the main thread too.
    private var running = false, stopping = false
    /// Identities of copies on which macOS refused the change. They wait for a restart or a manual Apply.
    private var refused = Set<String>()
    private var tries = [String: Int]()
    /// Apps that were missing at the last look. One that comes back starts its retries afresh.
    private var gone = Set<String>()
    /// Copies a pass found keeping their original icon from now on, until the preferences list them in defaultPaths,
    /// which the app saves on the main thread a moment later. Meanwhile a pass whose context was taken earlier must not
    /// mistake such a copy, whose record is gone, for a new app. Only touched on the queue.
    private var keptOriginal = Set<String>()
    /// Delays before an app in the middle of an update is looked at again: quickly at first, then every two minutes
    /// for as long as a hidden install folder beside it can still mean an update under way (15 minutes). Then the
    /// next event or sweep decides.
    static var backoff: [TimeInterval] = [1, 2, 4, 8, 15, 30, 60] + Array(repeating: 120, count: 8)

    init(icons: AppIcons, catalog: AppCatalog) {
        self.icons = icons
        self.catalog = catalog
    }

    /// Whether a pass is under way.
    var busy: Bool {
        flags.lock()
        defer { flags.unlock() }
        return running
    }
    private var quitting: Bool {
        flags.lock()
        defer { flags.unlock() }
        return stopping
    }

    /// Check these apps, or every app when nil, after a short pause that gathers related requests. A fresh request
    /// comes from a new event on the apps, which starts their retries anew.
    func request(_ paths: Set<String>?, after delay: TimeInterval = 0.25, fresh: Bool = false) {
        queue.async {
            if let paths {
                self.named.formUnion(paths)
                if fresh { for path in paths { self.tries[path] = nil } }
            } else {
                self.all = true
            }
            self.arm(delay)
        }
    }

    /// After a manual Apply, the apps macOS refused are tried again, and copies noted as keeping their original icon
    /// follow the preferences again: the Apply may have given them the pack.
    func forgetRefusals() {
        queue.async {
            self.refused.removeAll()
            self.keptOriginal.removeAll()
        }
    }

    /// Hold new passes off, and wait for a pass under way to end, so a review shows the apps as that pass leaves
    /// them. It blocks, so call it off the main thread.
    func pause() { queue.sync { paused = true } }

    /// Let passes run again, starting with the requests that arrived meanwhile.
    func resume() {
        queue.async {
            self.paused = false
            if self.all || !self.named.isEmpty { self.arm(0.25) }
        }
    }

    /// BetterIcon is quitting: no new pass starts, and a pass under way stops after the app it is working on.
    /// Returns whether a pass is under way.
    func beginQuitting() -> Bool {
        flags.lock()
        defer { flags.unlock() }
        stopping = true
        return running
    }

    /// Runs `done` on the main thread once no pass is under way.
    func whenIdle(_ done: @escaping () -> Void) { queue.async { DispatchQueue.main.async(execute: done) } }

    private func arm(_ delay: TimeInterval) {
        guard !armed else { return }
        armed = true
        queue.asyncAfter(deadline: .now() + delay) {
            self.armed = false
            self.fire()
        }
    }

    private func putBack(_ everything: Bool, _ paths: Set<String>) {
        if everything { all = true }
        named.formUnion(paths)
    }

    private func fire() {
        guard !paused, !quitting, all || !named.isEmpty else { return }
        let everything = all, paths = named
        all = false
        named.removeAll()
        DispatchQueue.main.async {
            guard let provide = self.context else { return }
            guard let context = provide() else {
                self.queue.async {
                    self.putBack(everything, paths)
                    self.arm(1)
                }
                return
            }
            self.queue.async { self.pass(everything, paths, context) }
        }
    }

    private func pass(_ everything: Bool, _ paths: Set<String>, _ context: Context) {
        flags.lock()
        if stopping || paused {
            let quit = stopping
            flags.unlock()
            if !quit { putBack(everything, paths) }
            return
        }
        running = true
        flags.unlock()
        defer {
            flags.lock()
            running = false
            flags.unlock()
        }
        var apps = everything ? context.apps : []
        var missing = [String]()
        for path in paths.sorted() where !apps.contains(where: { $0.url.path == path }) {
            let url = URL(fileURLWithPath: path)
            if let app = context.apps.first(where: { $0.url.path == path }) ?? catalog.app(at: url) {
                apps.append(app)
            } else if icons.hasRecord(path) || catalog.unfinished(at: url) {
                // Moved aside for a moment by an update, or still being copied into place: its Info.plist or executable
                // has not arrived yet.
                missing.append(path)
            }
        }
        keptOriginal.subtract(context.defaultPaths)
        var result: Reconciled
        do {
            result = try icons.reconcile(
                apps, appliedPack: context.appliedPack, defaultPaths: context.defaultPaths.union(keptOriginal),
                appliedArt: context.appliedArt, refused: refused, adopt: context.adoption,
                stop: { [unowned self] in self.quitting })
        } catch is LockBusy {
            putBack(everything, paths)
            arm(2)
            return
        } catch {
            result = Reconciled()
            result.errors.append(error.localizedDescription)
        }
        result.waiting += missing
        keptOriginal.formUnion(result.optedOut + result.leftAlone)
        for identity in result.declined.values { refused.insert(identity) }
        let waiting = Set(result.waiting)
        // An app that was missing and is back again starts its retries anew.
        for path in apps.map(\.url.path) where gone.remove(path) != nil { tries[path] = nil }
        gone.formUnion(missing)
        for path in Set(apps.map(\.url.path)).union(paths) where !waiting.contains(path) { tries[path] = nil }
        for path in waiting {
            let attempt = tries[path, default: 0]
            guard attempt < Self.backoff.count else { continue }
            tries[path] = attempt + 1
            queue.asyncAfter(deadline: .now() + Self.backoff[attempt]) {
                self.named.insert(path)
                self.arm(0)
            }
        }
        guard
            !result.restored.isEmpty || !result.finished.isEmpty || !result.optedOut.isEmpty
                || !result.yielded.isEmpty || !result.declined.isEmpty || !result.errors.isEmpty
                || !result.adopted.isEmpty || !result.leftAlone.isEmpty
        else { return }
        DispatchQueue.main.async { self.finished?(result) }
    }
}
