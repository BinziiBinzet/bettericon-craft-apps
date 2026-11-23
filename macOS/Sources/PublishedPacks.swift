import AppKit

// One entry is one design: a file format with the other extensions that share its artwork.
struct ProjectFormat: Decodable {
    let Key: String
    let Application: String
    let Aliases: [String]?
    var extensions: [String] { [Key] + (Aliases ?? []) }
    var label: String {
        let aliases = Aliases ?? []
        if aliases.isEmpty { return Key }
        if aliases.count < 3 { return ([Key] + aliases).joined(separator: ", ") }
        return Key + ", " + aliases[0] + " +\(aliases.count - 1)"
    }
}

struct FileTile {
    let name, hint: String
    let art: URL
}

struct PackUpdateCheck: Decodable {
    let revision, baseline: String
    let count: Int
}

/// The download size of each published pack, from `Catalog/pack-sizes.tsv`. `macOS/pack-sizes.py` writes that table
/// from the pack artwork for the installer's catalog, whose SHA-256 it records on its `#catalog` line. The helper's
/// catalog has no sizes. A pack the table does not list has no known size.
enum PackSizes {
    static func load(_ resources: URL) -> [String: Int] {
        guard let text = try? String(contentsOf: resources.appendingPathComponent("Catalog/pack-sizes.tsv"), encoding: .utf8)
        else { return [:] }
        var sizes = [String: Int]()
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2, let bytes = Int(fields[1]), bytes >= 0 else { continue }
            sizes[String(fields[0])] = bytes
        }
        return sizes
    }
}

/// Why a pack download failed, in a few plain words for the status line. The helper passes on the network library's own
/// errors, which name the whole address of a file, such as: Get "https://raw.githubusercontent.com/…": dial tcp …
struct DownloadFailure {
    /// GitHub could not be reached at all: no connection, a name that does not resolve, a proxy, a firewall or a
    /// certificate in the way, or no answer in time. The other packs would fail the same way.
    let unreachable: Bool
    let cause: String
    init(_ error: Error) {
        var message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = false
        // Go names the request by its method with a capital first letter: Get "https://…": …
        if let range = message.range(of: #"^[A-Z][A-Za-z]* "[^"]*": "#, options: .regularExpression) {
            message.removeSubrange(range)
            request = true
        }
        let network = #"dial tcp|no such host|connection refused|network is unreachable|no route to host|host is down|"#
            + #"timeout|deadline exceeded|tls|x509|certificate|proxyconnect|connection reset|broken pipe|\beof\b"#
        unreachable = request || message.range(of: network, options: [.regularExpression, .caseInsensitive]) != nil
        if unreachable {
            cause = "BetterIcon couldn’t reach GitHub"
        } else if let code = message.range(of: #"HTTP \d{3}"#, options: .regularExpression) {
            cause = "GitHub answered with " + message[code]
        } else if message.lowercased().hasPrefix("artwork checksum differs") {
            cause = "its artwork didn’t match the published checksum"
        } else {
            // Anything else, without addresses, as one short phrase.
            var text = message.replacingOccurrences(of: #"[a-z]+://\S+"#, with: "", options: .regularExpression)
            text = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            while let last = text.last, ".:;,".contains(last) { text.removeLast() }
            if text.count > 100 { text = String(text.prefix(99)) + "…" }
            if text.isEmpty { text = "the download failed" }
            // A sentence continues after a colon: "The service…" becomes "the service…", "HTTP…" stays.
            if let first = text.first, first.isUppercase, text.dropFirst().first?.isLowercase == true {
                text = first.lowercased() + text.dropFirst()
            }
            cause = text
        }
    }
    /// How the downloads ended, in a few short sentences: the packs that failed are grouped by cause, with up to three
    /// names for each.
    static func summary(downloaded done: Int, of total: Int, failed: [(title: String, cause: String)], unreachable: Bool)
        -> String
    {
        var parts = [String]()
        if unreachable {
            parts.append(
                done == 0 && failed.isEmpty
                    ? "Couldn’t download the icon packs, because BetterIcon couldn’t reach GitHub."
                    : "Downloaded \(done) of \(total) icon packs, then BetterIcon couldn’t reach GitHub.")
        } else {
            parts.append(
                failed.isEmpty
                    ? "Downloaded \(done) icon \(done == 1 ? "pack" : "packs")." : "Downloaded \(done) of \(total) icon packs.")
        }
        var causes = [String](), titles = [String: [String]]()
        for (title, cause) in failed {
            if titles[cause] == nil { causes.append(cause) }
            titles[cause, default: []].append(title)
        }
        func names(_ list: [String]) -> String {
            switch list.count {
            case 1: return list[0]
            case 2: return list[0] + " and " + list[1]
            case 3: return list[0] + ", " + list[1] + " and " + list[2]
            default: return list.prefix(3).joined(separator: ", ") + " and \(list.count - 3) more"
            }
        }
        for cause in causes.prefix(3) { parts.append("Couldn’t download \(names(titles[cause] ?? [])): \(cause).") }
        let rest = causes.dropFirst(3).reduce(0) { $0 + (titles[$1]?.count ?? 0) }
        if rest > 0 { parts.append("\(rest) more \(rest == 1 ? "pack" : "packs") couldn’t be downloaded.") }
        if unreachable || !failed.isEmpty { parts.append("Choose a pack to try it again.") }
        return parts.joined(separator: " ")
    }
}

struct PublishedPacks {
    let resources: URL
    let state: URL
    let formats: [ProjectFormat]
    init(resources: URL, state: URL) throws {
        self.resources = resources
        self.state = state.appendingPathComponent("pack-cache")
        formats = try JSONDecoder().decode([ProjectFormat].self, from: Data(contentsOf:
            resources.appendingPathComponent("Catalog/ProjectFileTypes.json")))
    }
    private func run(_ args: [String]) throws -> Data {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = resources.deletingLastPathComponent().appendingPathComponent("Helpers/packstore")
        process.arguments = [resources.path, state.path] + args
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Problem(String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }
    private struct Entry: Decodable {
        let ID, Name, Author, Status: String
        let Icons, FileIcons, AppFileIcons: [String: String]
        let CanApps, CanFiles, HasPreview: Bool
        let HasFilePreview: Bool?
        let PreviousIDs: [String]?
        /// A chosen file of Icons, FileIcons or AppFileIcons, mapped to the other formats of its item, best first.
        let Fallbacks: [String: [String]]?
        /// The apps whose AppFileIcons art also draws file types outside the list (round S2 of the helper).
        let UnlistedFileIconApps: [String]?
    }
    func list(_ action: String = "list", id: String? = nil) throws -> [Pack] {
        try Self.packs(from: run([action] + (id.map { [$0] } ?? [])))
    }
    /// The packs in the helper's list. The helper names each item's files best first: WebP, PNG, SVG, ICO. An item takes
    /// the first one that can be used, so a damaged or animated WebP gives way to its PNG. An item with no usable file
    /// is left out, with the reason. The apps that opt in to the file types outside the list take their resolved art for
    /// all of their files as that art too.
    static func packs(from data: Data) throws -> [Pack] {
        try JSONDecoder().decode([Entry].self, from: data).map { item in
            var leftOut = [String: String]()
            func resolve(_ files: [String: String], _ name: (String) -> String) -> [String: URL] {
                var chosen = [String: URL]()
                for (key, path) in files {
                    var cause: String?
                    for candidate in [path] + (item.Fallbacks?[path] ?? []) {
                        let url = URL(fileURLWithPath: candidate)
                        guard let problem = Artwork.problem(url) else {
                            chosen[key] = url
                            break
                        }
                        if cause == nil { cause = problem }
                    }
                    if chosen[key] == nil, let cause { leftOut[name(key)] = cause }
                }
                return chosen
            }
            let icons = resolve(item.Icons, Craft.displayName)
            let documents = resolve(item.FileIcons) { $0 }
            let appFiles = resolve(item.AppFileIcons) { Craft.displayName($0) + " files" }
            // The helper may list an app while the pack is not on the computer. Only art that is here counts.
            let opted = Set(item.UnlistedFileIconApps ?? [])
            return Pack(id: item.ID, name: item.Name, author: item.Author, icons: icons, documents: documents,
                 appFiles: appFiles, status: item.Status, canApps: item.CanApps, canFiles: item.CanFiles,
                 hasPreview: item.HasPreview, hasFilePreview: item.HasFilePreview ?? false,
                 previousIDs: item.PreviousIDs ?? [], unlisted: appFiles.filter { opted.contains($0.key) }, leftOut: leftOut)
        }
    }
    func checkUpdates(_ previous: PackUpdateCheck?) throws -> PackUpdateCheck {
        var args = ["check-updates"]
        if let previous { args += [previous.revision, previous.baseline, String(previous.count)] }
        return try JSONDecoder().decode(PackUpdateCheck.self, from: run(args))
    }
    /// The hover strip for a pack: its app icons, or in the file type list its file artwork.
    func preview(_ pack: Pack, files fileList: Bool = false) throws -> URL? {
        func published(_ kind: [String]) throws -> URL? {
            let path = try JSONDecoder().decode(String.self, from: run(["preview", pack.id] + kind))
            return path.isEmpty ? nil : URL(fileURLWithPath: path)
        }
        let files: [URL]
        if fileList {
            // A pack of file artwork alone has one published strip. A mixed pack has one for its FileTypes folder.
            if pack.hasFilePreview || (pack.hasPreview && !pack.canApps) {
                do { return try published(pack.hasFilePreview ? ["files"] : []) } catch {
                    // A strip that cannot be fetched gives way to the pack's own artwork when it is here.
                    if pack.documents.isEmpty && pack.appFiles.isEmpty { throw error }
                }
            }
            files = fileTiles(pack).prefix(3).map(\.art)
        } else if pack.hasPreview {
            return try published([])
        } else {
            let art = !pack.icons.isEmpty ? pack.icons : !pack.documents.isEmpty ? pack.documents : pack.appFiles
            let keys = art.keys.sorted { ($0 == Pack.lead ? "" : $0) < ($1 == Pack.lead ? "" : $1) }
            files = keys.prefix(3).compactMap { art[$0] }
        }
        guard !files.isEmpty else { return nil }
        let signature = files.map { file in
            let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return file.path + String(date?.timeIntervalSince1970 ?? 0)
        }.joined(separator: "\n")
        let directory = state.appendingPathComponent("local-previews")
        let dest = directory.appendingPathComponent(digest(Data(signature.utf8)) + ".png")
        if fm.fileExists(atPath: dest.path) { return dest }
        let width = files.count * 70 - 6
        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 64,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: canvas)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        for (idx, path) in files.enumerated() {
            guard let image = NSImage(contentsOf: path), image.size.width > 0, image.size.height > 0 else { return nil }
            let scale = 64 / max(image.size.width, image.size.height)
            let w = image.size.width * scale, h = image.size.height * scale
            image.draw(in: NSRect(x: CGFloat(idx * 70) + (64-w)/2, y: (64-h)/2, width: w, height: h))
        }
        context.flushGraphics()
        guard let bytes = canvas.representation(using: .png, properties: [:]) else { return nil }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: dest, options: .atomic)
        return dest
    }
    /// Everything a pack stores, for an edit or a personal copy: its app icons, the art for each listed format, and each
    /// app's art for the file types outside the list, under "*" and the app's name.
    func storedFiles(_ pack: Pack) -> [String: URL] {
        var stored = pack.icons.merging(fileArt(pack)) { _, doc in doc }
        for (app, art) in pack.unlisted { stored[sharedFileArt + app] = art }
        return stored
    }
    /// The file type pack's count for Manage Icons when the pack also draws file types outside the list, such as
    /// "27 file types, plus other PhotoCraft files", or nil when it draws none.
    func fileSummary(_ pack: Pack) -> String? {
        let apps = pack.unlisted.keys.map(Craft.displayName).sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
        guard !apps.isEmpty else { return nil }
        let others = apps.count > 2 ? "other files of \(apps.count) apps" : "other " + apps.joined(separator: " and ") + " files"
        let count = fileArt(pack).count
        if count == 0 { return others.prefix(1).uppercased() + others.dropFirst() }
        return "\(count) file \(count == 1 ? "type" : "types"), plus " + others
    }
    // The artwork for every format a pack draws: its own design, or the one for all its app's files.
    func fileArt(_ pack: Pack) -> [String: URL] {
        Dictionary(uniqueKeysWithValues: formats.compactMap { format in
            (pack.documents[format.Key] ?? pack.appFiles[format.Application]).map { (format.Key, $0) }
        })
    }
    // The designs in a file type pack, by app: the one for all of an app's files, then each format's own.
    func fileTiles(_ pack: Pack) -> [FileTile] {
        let drawn = formats.filter { pack.documents[$0.Key] != nil }
        let apps = Set(pack.appFiles.keys).union(pack.unlisted.keys).union(drawn.map(\.Application)).sorted {
            $0.caseInsensitiveCompare($1) == .orderedAscending
        }
        return apps.flatMap { app -> [FileTile] in
            var tiles = [FileTile]()
            if let shared = pack.appFiles[app] ?? pack.unlisted[app] {
                // A personal pack keeps its art for each format, so only a published pack's art covers formats.
                let covered = pack.appFiles[app] == nil ? []
                    : formats.filter { $0.Application == app && pack.documents[$0.Key] == nil }.map(\.label)
                let others = pack.unlisted[app] == nil ? [] : ["Other file types " + Craft.displayName(app) + " opens"]
                tiles.append(FileTile(name: app, hint: ([app + " files"] + covered + others).joined(separator: "\n"), art: shared))
            }
            for format in drawn where format.Application == app {
                tiles.append(FileTile(name: format.Key, hint: format.label + "\n" + app, art: pack.documents[format.Key]!))
            }
            return tiles
        }
    }
}
