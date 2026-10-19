import AppKit
import ImageIO
import SQLite3
import UniformTypeIdentifiers

/// Reads payloads on a separate executor, so drawing and changing tabs never decode a BLOB.
actor ClipResources {
    nonisolated static let dragIdentifier = "com.local.lightpaste.clip-id"
    private let fileURL: URL
    private var thumbnails: [UUID: CGImage] = [:]

    init(directory: URL) { fileURL = directory.appendingPathComponent("history.sqlite3") }

    nonisolated static func exportTypes(for kind: ClipKind) -> [String] {
        switch kind {
        case .text: return [UTType.utf8PlainText.identifier]
        case .link: return [UTType.url.identifier, UTType.utf8PlainText.identifier]
        case .image: return [UTType.png.identifier]
        case .files: return [UTType.fileURL.identifier]
        case .other: return []
        }
    }

    func thumbnail(id: UUID) -> CGImage? {
        if let cached = thumbnails[id] { return cached }
        guard !Task.isCancelled, let entries = try? payload(id: id) else { return nil }
        for rep in entries.flatMap(\.representations) where UTType(rep.type)?.conforms(to: .image) == true {
            guard let source = CGImageSourceCreateWithData(rep.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 480,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { continue }
            if thumbnails.count >= 60 { thumbnails.removeAll(keepingCapacity: true) }
            thumbnails[id] = image
            return image
        }
        return nil
    }

    /// A larger decode for on-device text recognition; not cached.
    func ocrImage(id: UUID) -> CGImage? {
        guard let entries = try? payload(id: id) else { return nil }
        for rep in entries.flatMap(\.representations) where UTType(rep.type)?.conforms(to: .image) == true {
            guard let source = CGImageSourceCreateWithData(rep.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2400,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { continue }
            return image
        }
        return nil
    }

    func exportData(id: UUID, type: String) throws -> Data {
        let entries = try payload(id: id)
        let reps = entries.flatMap(\.representations)
        if type == UTType.utf8PlainText.identifier {
            let text = entries.compactMap { entry -> String? in
                for name in [UTType.utf8PlainText.identifier, UTType.rtf.identifier, UTType.html.identifier,
                             UTType.url.identifier, UTType.fileURL.identifier] {
                    guard let data = entry.representations.first(where: { $0.type == name })?.data else { continue }
                    if name == UTType.rtf.identifier {
                        if let value = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) { return value.string }
                    } else if let value = String(data: data, encoding: .utf8) {
                        if name == UTType.html.identifier {
                            // Local extraction only: never import HTML through WebKit or fetch resources.
                            return value.replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1\\s*>", with: "", options: .regularExpression)
                                .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
                                .replacingOccurrences(of: "&nbsp;", with: " ")
                                .replacingOccurrences(of: "&lt;", with: "<")
                                .replacingOccurrences(of: "&gt;", with: ">")
                                .replacingOccurrences(of: "&amp;", with: "&")
                        }
                        return value
                    }
                }
                return nil
            }.joined(separator: "\n")
            guard !text.isEmpty else { throw ResourceError.unavailable }
            return Data(text.utf8)
        }
        if let rep = reps.first(where: { $0.type == type }) { return rep.data }
        if type == UTType.png.identifier {
            for rep in reps where UTType(rep.type)?.conforms(to: .image) == true {
                guard let source = CGImageSourceCreateWithData(rep.data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(destination, image, nil)
                if CGImageDestinationFinalize(destination) { return data as Data }
            }
        }
        if type == UTType.url.identifier,
           let text = reps.first(where: { $0.type == UTType.utf8PlainText.identifier }),
           let value = String(data: text.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return Data(url.absoluteString.utf8)
        }
        if type == UTType.fileURL.identifier,
           let legacy = reps.first(where: { $0.type == "NSFilenamesPboardType" }),
           let paths = (try? PropertyListSerialization.propertyList(from: legacy.data, options: [], format: nil)) as? [String],
           let first = paths.first { return Data(URL(fileURLWithPath: first).absoluteString.utf8) }
        throw ResourceError.unavailable
    }

    private func payload(id: UUID) throws -> [ClipboardEntry] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(fileURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw ResourceError.unavailable
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT payload FROM clips WHERE id = ?", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw ResourceError.unavailable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, id.uuidString, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else { throw ResourceError.unavailable }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        return try PropertyListDecoder().decode([ClipboardEntry].self, from: data)
    }

    private enum ResourceError: LocalizedError {
        case unavailable
        var errorDescription: String? { "这条内容已不存在或无法拖出。" }
    }
}
