import AppKit

func startBetterIcon() throws {
    var args = Array(CommandLine.arguments.dropFirst())
    func parameter(_ flag: String) throws -> String? {
        guard let index = args.firstIndex(of: flag) else { return nil }
        guard args.indices.contains(index + 1), !args[index + 1].hasPrefix("--") else {
            throw Problem("Missing value for " + flag)
        }
        let value = args[index + 1]
        args.removeSubrange(index...index + 1)
        return value
    }
    func flag(_ name: String) -> Bool {
        guard let index = args.firstIndex(of: name) else { return false }
        args.remove(at: index)
        return true
    }
    if flag("--help") {
        print(
            """
            BetterIcon [--menu-bar-only]
            BetterIcon --list-apps | --list-packs
            BetterIcon --apply PACK | --restore [--app PhotoCraft] [--scope personal|shared|all] [--yes]
            Apply and restore print a review. Add --yes to perform the reviewed operation.
            --fixture DIRECTORY uses its Applications, Shared and State folders for local testing.
            """)
        return
    }
    let fixture = try parameter("--fixture").map { URL(fileURLWithPath: $0, isDirectory: true) }
    let scopeName = try parameter("--scope") ?? "shared"
    let scope = Scope(rawValue: scopeName)
    guard scope != nil || scopeName == "all" else { throw Problem("Use --scope personal, --scope shared or --scope all.") }
    let packName = try parameter("--apply")
    let only = try parameter("--app")
    let restore = flag("--restore")
    let listApps = flag("--list-apps")
    let listPacks = flag("--list-packs")
    let yes = flag("--yes")
    let hidden = flag("--menu-bar-only")
    // Launch Services can supply this annotation on first launch.
    args.removeAll { $0.hasPrefix("-psn_") }
    guard args.isEmpty, !(restore && packName != nil), only.map(Craft.names.contains) ?? true else {
        throw Problem("Unrecognized option or app. Use --help.")
    }
    guard let resources = Bundle.main.resourceURL else {
        throw Problem("Run BetterIcon inside its application bundle.")
    }
    let install = try Installation(resources: resources, fixture: fixture)
    if listApps || listPacks || restore || packName != nil {
        let p = try saved(
            Preferences.self, at: install.state.appendingPathComponent("preferences.json"), fallback: Preferences()
        )
        let folders = fixture == nil ? p.folders : []
        if listApps {
            for app in install.catalog.discover(extraFolders: folders) {
                print([app.scope.rawValue, app.name, app.url.path].joined(separator: "\t"))
            }
            return
        }
        let lib = try PackLibrary(install.state.appendingPathComponent("Packs"))
        let published = try PublishedPacks(resources: resources, state: install.state)
        lib.formats = published.formats
        let packs = lib.visible(try published.list())
        if listPacks {
            for pack in packs { print([pack.id, pack.title, String(pack.icons.count)].joined(separator: "\t")) }
            return
        }
        let apps = install.catalog.discover(extraFolders: folders)
        let matches = packs.filter { pack in
            guard let packName else { return false }
            return pack.id == packName || pack.title == packName || pack.name == packName
                || pack.previousIDs.contains { $0 == packName || ($0 as NSString).lastPathComponent == packName }
        }
        guard restore || matches.count == 1 else { throw Problem("Specify a pack ID from --list-packs.") }
        let pack = matches.first ?? .defaults
        if !restore && pack.status == "Download" { throw Problem("Select this pack in Manage Icons to download it first.") }
        let backend = AppIcons(install.state.appendingPathComponent("App Icons"))
        // A running BetterIcon may be putting an icon back after an update. The review shows the apps as it leaves them.
        try backend.waitUntilIdle(timeout: 30)
        let plan = backend.review(
            apps: apps, pack: pack, scope: scope, restore: restore || pack.isDefault, only: only)
        for row in plan.rows { print(row.message + "\t" + row.app.url.path) }
        if yes {
            let found = install.catalog.discover(extraFolders: fixture == nil ? p.folders : [])
            let result = try backend.perform(plan, apps: found, pack: pack, wait: 10)
            if !result.changed.isEmpty || !result.defaults.isEmpty {
                try updatePreferences(install.state) { value in
                    if plan.restore {
                        value.defaultPaths.formUnion(result.defaults)
                    } else {
                        value.defaultPaths.subtract(result.changed)
                    }
                    value.noteApplied(plan, result, pack: pack)
                }
                DistributedNotificationCenter.default().postNotificationName(
                    install.notificationName, object: "refresh", userInfo: nil, deliverImmediately: true)
            }
            print("\(result.changed.count) changed.")
            if !result.errors.isEmpty { throw Problem(result.errors.joined(separator: "\n")) }
        }
        return
    }
    try fm.createDirectory(at: install.state, withIntermediateDirectories: true)
    let lockPath = install.state.appendingPathComponent("launcher.lock").path
    // Every earlier version leaves its lock file behind at its first start, also when it never saved preferences.
    let startedBefore = fm.fileExists(atPath: lockPath)
    let lock = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lock >= 0 else { throw Problem("Could not open the launcher lock.") }
    defer { close(lock) }
    if flock(lock, LOCK_EX | LOCK_NB) != 0 {
        DistributedNotificationCenter.default().postNotificationName(
            install.notificationName, object: "show", userInfo: nil, deliverImmediately: true)
        return
    }
    let ns = NSApplication.shared
    let delegate = try Application(install, hidden: hidden, startedBefore: startedBefore)
    ns.delegate = delegate
    withExtendedLifetime(delegate) { ns.run() }
}
do { try startBetterIcon() } catch {
    FileHandle.standardError.write(Data(("BetterIcon: " + error.localizedDescription + "\n").utf8))
    exit(1)
}
