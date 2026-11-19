import AppKit
import BetterIconArchive

private struct SharedPack: Codable {
    var Format = "BetterIcon.IconPack"
    var Version = 1
    var Name: String
    var Author: String?
}
private struct Personal: Codable {
    let uuid: UUID, revision: UUID
    let name: String, author: String
    let files: [String: String]
}
private struct LibraryIndex: Codable {
    var hidden = Set<String>()
    var personal = [Personal]()
}

final class PackLibrary {
    let root: URL
    var projectKeys = Set<String>()
    var projectApps = Set<String>()
    private var index: LibraryIndex
    init(_ root: URL) throws {
        self.root = root
        index = try saved(
            LibraryIndex.self, at: root.appendingPathComponent("library.json"), fallback: LibraryIndex())
    }
    private func persist(_ next: LibraryIndex) throws {
        try save(next, at: root.appendingPathComponent("library.json"))
        index = next
    }
    func visible(_ builtins: [Pack]) -> [Pack] {
        let personal = index.personal.map { p -> Pack in
            let dir = root.appendingPathComponent(p.uuid.uuidString).appendingPathComponent(p.revision.uuidString)
            let urls = p.files.compactMapValues { file -> URL? in
                guard file == (file as NSString).lastPathComponent else { return nil }
                return dir.appendingPathComponent(file)
            }
            return Pack(
                id: "User/" + p.uuid.uuidString, name: p.name, author: p.author, icons: urls.filter { !$0.key.hasPrefix(".") }, personal: true,
                documents: urls.filter { $0.key.hasPrefix(".") }, canApps: urls.keys.contains { !$0.hasPrefix(".") },
                canFiles: urls.keys.contains { projectKeys.contains($0) || projectApps.contains($0) })
        }
        return [.defaults]
            + (builtins.filter { !index.hidden.contains($0.id) } + personal).sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }
    func remove(_ pack: Pack) throws {
        guard !pack.isDefault else { throw Problem("Select a personal or built-in pack.") }
        var next = index
        if pack.personal {
            next.personal.removeAll { "User/" + $0.uuid.uuidString == pack.id }
        } else {
            next.hidden.insert(pack.id)
        }
        try persist(next)
    }
    func restoreBuiltins() throws {
        var next = index
        next.hidden.removeAll()
        try persist(next)
    }
    func copyName(_ pack: Pack) -> String {
        let base = pack.isDefault ? "My icon pack" : String(pack.name.prefix(56)) + " custom"
        var name = base
        var n = 2
        while index.personal.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = String(base.prefix(56)) + " (\(n))"
            n += 1
        }
        return name
    }
    private func label(_ s: String, required: Bool) throws -> String {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !required || !text.isEmpty, text.count <= 64, text.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            throw Problem("Use a pack name and author of up to 64 characters. A name is required.")
        }
        return text
    }
    func store(name: String, author: String, files: [String: URL], editing: Pack? = nil) throws -> String {
        var items = [String: (String, Data)]()
        for (craft, url) in files { items[craft] = (url.pathExtension.lowercased(), try Artwork.load(url)) }
        return try publish(name: name, author: author, items: items, editing: editing)
    }
    private func publish(name: String, author: String, items: [String: (String, Data)], editing: Pack?) throws
        -> String
    {
        let name = try label(name, required: true)
        let author = try label(author, required: false)
        guard !items.isEmpty, items.values.reduce(0, { $0 + $1.1.count }) <= 128 * 1024 * 1024 - 65536 else {
            throw Problem("A pack needs at least one icon and must fit within 128 MB including its description.")
        }
        let existing = index.personal.first { "User/" + $0.uuid.uuidString == editing?.id }
        guard editing == nil || existing != nil else {
            throw Problem("This personal pack is no longer in the library.")
        }
        guard
            !index.personal.contains(where: {
                $0.uuid != existing?.uuid && $0.name.caseInsensitiveCompare(name) == .orderedSame
            })
        else { throw Problem("A personal pack already has that name.") }
        let uuid = existing?.uuid ?? UUID()
        let revision = UUID()
        let dir = root.appendingPathComponent(uuid.uuidString).appendingPathComponent(revision.uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var published = false
        defer { if !published { try? fm.removeItem(at: dir) } }
        var files = [String: String]()
        for (craft, (ext, bytes)) in items {
            guard Craft.names.contains(craft) || projectKeys.contains(craft) else { throw Problem("Unknown ArtCraft app.") }
            try Artwork.validate(bytes, ext: ext)
            let file = (craft.hasPrefix(".") ? "project-" + String(craft.dropFirst()) : craft) + "." + ext
            try bytes.write(to: dir.appendingPathComponent(file), options: .atomic)
            files[craft] = file
        }
        var next = index
        next.personal.removeAll { $0.uuid == uuid }
        next.personal.append(Personal(uuid: uuid, revision: revision, name: name, author: author, files: files))
        try persist(next)
        published = true
        return "User/" + uuid.uuidString
    }
    func importPack(_ url: URL) throws -> String {
        var choices = [String: [(String, Data)]]()
        var metadata: SharedPack?
        var count = 0
        var size = 0
        func admit(_ path: String, _ length: Int, isDir: Bool, read: () throws -> Data) throws {
            count += 1
            size += length
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard count <= 1024, length >= 0, size <= 128 * 1024 * 1024,
                !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !parts.contains("..")
            else { throw Problem("The pack contains an unsafe path or exceeds the import limits.") }
            guard !isDir, !parts.contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) else { return }
            let base = (path as NSString).lastPathComponent
            if base.lowercased() == "bettericon-pack.json" {
                guard metadata == nil, length <= 64 * 1024 else {
                    throw Problem("The pack description is ambiguous or too large.")
                }
                let desc = try JSONDecoder().decode(SharedPack.self, from: read())
                guard desc.Format == "BetterIcon.IconPack", desc.Version == 1 else {
                    throw Problem("Unrecognized BetterIcon pack format.")
                }
                metadata = desc
                return
            }
            let ext = (base as NSString).pathExtension.lowercased()
            let stem = (base as NSString).deletingPathExtension
            let key = "." + stem.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            let doc = parts.dropLast().contains { $0.lowercased() == "filetypes" }
            guard Artwork.formats.contains(ext), let craft = doc ? (projectKeys.contains(key) ? key : nil) : Craft.canonical(stem)
            else { return }
            guard length <= Artwork.maxBytes else { throw Problem("One of the icons exceeds 16 MB.") }
            choices[craft, default: []].append((ext, try read()))
        }
        let src = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard src.isSymbolicLink != true else {
            throw Problem("Choose the original pack instead of a linked path.")
        }
        if src.isDirectory == true {
            var walkError: Error?
            guard
                let it = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [
                        .isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey,
                    ],
                    errorHandler: { _, error in
                        walkError = error
                        return false
                    })
            else { throw Problem("The folder could not be read.") }
            for case let file as URL in it {
                let v = try file.resourceValues(forKeys: [
                    .isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey,
                ])
                guard v.isSymbolicLink != true, v.isRegularFile == true || v.isDirectory == true else {
                    throw Problem("Linked and special files cannot be imported.")
                }
                let rel = String(file.path.dropFirst(url.path.count + 1))
                try admit(rel, v.isDirectory == true ? 0 : v.fileSize ?? 0, isDir: v.isDirectory == true) {
                    try Artwork.load(file)
                }
            }
            if let walkError { throw walkError }
        } else {
            try readZIP(url, visit: admit)
        }
        var items = [String: (String, Data)]()
        for (craft, candidates) in choices {
            for ext in Artwork.formats {
                let matches = candidates.filter { $0.0 == ext }
                guard matches.count <= 1 else {
                    throw Problem("Multiple \(ext.uppercased()) files match \(craft). Import one theme at a time.")
                }
                if let match = matches.first {
                    items[craft] = match
                    break
                }
            }
        }
        return try publish(
            name: metadata?.Name
                ?? (src.isDirectory == true
                    ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent),
            author: metadata?.Author ?? "", items: items, editing: nil)
    }
    private func readZIP(_ url: URL, visit: (String, Int, Bool, () throws -> Data) throws -> Void) throws {
        guard let archive = archive_read_new() else { throw Problem("Could not open ZIP.") }
        defer { archive_read_free(archive) }
        func failure() -> Problem {
            Problem(archive_error_string(archive).map { String(cString: $0) } ?? "Invalid ZIP archive.")
        }
        guard archive_read_support_format_zip(archive) == 0,
            archive_read_open_filename(archive, url.path, 65536) == 0
        else { throw failure() }
        var entry: OpaquePointer?
        while true {
            let status = archive_read_next_header(archive, &entry)
            if status == 1 { break }
            guard status == 0, let item = entry, let raw = archive_entry_pathname(item),
                let path = String(validatingUTF8: raw)
            else { throw failure() }
            let type = archive_entry_filetype(item)
            let size = archive_entry_size(item)
            guard type == S_IFDIR || type == S_IFREG, archive_entry_symlink(item) == nil,
                archive_entry_hardlink(item) == nil, archive_entry_is_encrypted(item) == 0,
                size >= 0, size <= 128 * 1024 * 1024
            else { throw Problem("The ZIP contains a linked, encrypted, or oversized entry.") }
            try visit(path, Int(size), type == S_IFDIR) {
                var result = Data()
                var buf = [UInt8](repeating: 0, count: 32768)
                while true {
                    let n = archive_read_data(archive, &buf, buf.count)
                    guard n >= 0, result.count + n <= Int(size) else { throw failure() }
                    if n == 0 { break }
                    result.append(contentsOf: buf.prefix(n))
                }
                guard result.count == size else { throw failure() }
                return result
            }
        }
    }
    func export(_ pack: Pack, to destination: URL) throws {
        guard pack.personal else { throw Problem("Customize a built-in pack before exporting it.") }
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let meta = "bettericon-pack.json"
        try save(SharedPack(Name: pack.name, Author: pack.author), at: dir.appendingPathComponent(meta))
        var names = [meta]
        var byteCount = try Data(contentsOf: dir.appendingPathComponent(meta)).count
        for (craft, file) in pack.icons.merging(pack.documents, uniquingKeysWith: { _, doc in doc }).sorted(by: { $0.key < $1.key }) {
            // Windows accepts PNG, ICO and SVG. Convert Mac-only sources on export.
            let icns = file.pathExtension == "icns"
            let name = (craft.hasPrefix(".") ? "FileTypes/" + String(craft.dropFirst()) : craft) + "." + (icns ? "png" : file.pathExtension)
            if craft.hasPrefix(".") {
                try fm.createDirectory(at: dir.appendingPathComponent("FileTypes"), withIntermediateDirectories: true)
            }
            if icns {
                guard let image = NSImage(contentsOf: file) else { throw Problem("Unreadable ICNS.") }
                let png = try Artwork.png(image, pixels: max(256, Artwork.dimension(file)))
                guard png.count <= Artwork.maxBytes else {
                    throw Problem("The exported PNG for \(craft) exceeds 16 MB.")
                }
                try png.write(to: dir.appendingPathComponent(name))
            } else {
                try fm.copyItem(at: file, to: dir.appendingPathComponent(name))
            }
            byteCount += try dir.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard byteCount <= 128 * 1024 * 1024 else { throw Problem("The exported pack exceeds 128 MB.") }
            names.append(name)
        }
        let tmp = destination.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString + ".zip")
        defer { try? fm.removeItem(at: tmp) }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.currentDirectoryURL = dir
        task.arguments = ["-q", "-X", tmp.path] + names
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0, rename(tmp.path, destination.path) == 0 else {
            throw Problem("Could not save the ZIP.")
        }
    }
}
