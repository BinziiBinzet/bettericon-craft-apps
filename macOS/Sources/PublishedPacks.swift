import AppKit

struct ProjectFormat: Decodable {
    let Key: String
    let Application: String
    let Aliases: [String]?
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
        let Icons, FileIcons: [String: String]
        let CanApps, CanFiles, HasPreview: Bool
    }
    func list(_ action: String = "list", id: String? = nil) throws -> [Pack] {
        let data = try run([action] + (id.map { [$0] } ?? []))
        return try JSONDecoder().decode([Entry].self, from: data).map { item in
            Pack(id: item.ID, name: item.Name, author: item.Author,
                 icons: item.Icons.mapValues { URL(fileURLWithPath: $0) },
                 documents: item.FileIcons.mapValues { URL(fileURLWithPath: $0) },
                 status: item.Status, canApps: item.CanApps, canFiles: item.CanFiles, hasPreview: item.HasPreview)
        }
    }
    func preview(_ pack: Pack) throws -> URL? {
        if pack.hasPreview {
            let path = try JSONDecoder().decode(String.self, from: run(["preview", pack.id]))
            return path.isEmpty ? nil : URL(fileURLWithPath: path)
        }
        let art = pack.icons.isEmpty ? pack.documents : pack.icons
        let keys = art.keys.sorted { ($0 == "ArtCraftLauncher" ? "" : $0) < ($1 == "ArtCraftLauncher" ? "" : $1) }
        let files = keys.prefix(3).compactMap { art[$0] }
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
    func fileArt(_ pack: Pack) -> [String: URL] {
        if !pack.documents.isEmpty { return pack.documents }
        return Dictionary(uniqueKeysWithValues: formats.compactMap { format in
            pack.icons[format.Application].map { (format.Key, $0) }
        })
    }
}
