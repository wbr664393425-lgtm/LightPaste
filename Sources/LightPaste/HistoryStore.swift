import Foundation
import Combine
import CryptoKit
import SQLite3

private enum HistoryError: LocalizedError {
    case database(String)
    case missingItem
    case invalidPayload
    case missingBoard
    case invalidBoardName
    case duplicateBoardName
    case invalidBackup
    case newerBackup

    var errorDescription: String? {
        switch self {
        case .database(let message): return "本地历史记录保存失败：\(message)"
        case .missingItem: return "这条历史记录已不存在。"
        case .invalidPayload: return "剪贴板记录没有可保存的内容。"
        case .missingBoard: return "这个收藏分类已不存在。"
        case .invalidBoardName: return "请输入收藏分类名称。"
        case .duplicateBoardName: return "已有同名收藏分类，请换个名称。"
        case .invalidBackup: return "这不是轻贴的收藏备份文件，或文件已损坏。"
        case .newerBackup: return "这份备份来自更新版本的轻贴，请先升级后再导入。"
        }
    }
}

/// Owns a private, local SQLite database. Large pasteboard payloads are loaded only on demand.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var boards: [FavoriteBoard] = []
    @Published private(set) var boardMembership: [UUID: UUID] = [:]
    @Published var errorMessage: String?

    private var searchHaystacks: [UUID: String] = [:]
    /// Rows loaded at launch whose search text is still being folded off the main thread.
    private var unindexedIDs = Set<UUID>()
    private nonisolated static let searchLocale = Locale(identifier: "en_US_POSIX")

    private var database: OpaquePointer?
    private let fileURL: URL
    /// Writes newly copied clips from the clipboard monitor's queue; see `adoptCapture(_:)`.
    nonisolated let captureWriter: CaptureWriter
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    var maximumItems = 1_000
    /// How long a detected secret stays; nil keeps it like ordinary history.
    var sensitiveLifetime: TimeInterval? = 10 * 60

    init(directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        fileURL = directory.appendingPathComponent("history.sqlite3", isDirectory: false)
        captureWriter = CaptureWriter(fileURL: fileURL)
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(fileURL.path, &connection,
                                    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let connection { sqlite3_close(connection) }
            throw HistoryError.database(message)
        }
        database = connection
        do {
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            sqlite3_busy_timeout(connection, 5_000)
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try execute("PRAGMA foreign_keys = ON")
            try execute("""
                CREATE TABLE IF NOT EXISTS clips (
                    id TEXT PRIMARY KEY NOT NULL,
                    fingerprint TEXT UNIQUE NOT NULL,
                    kind TEXT NOT NULL,
                    title TEXT NOT NULL,
                    text TEXT NOT NULL,
                    source_name TEXT NOT NULL,
                    source_bundle_id TEXT,
                    created_at REAL NOT NULL,
                    last_copied_at REAL NOT NULL,
                    is_favorite INTEGER NOT NULL DEFAULT 0,
                    payload BLOB NOT NULL
                )
                """)
            try execute("CREATE INDEX IF NOT EXISTS clips_last_copied ON clips(last_copied_at DESC)")
            // Additive migration: existing clip rows and payloads are never rewritten.
            try transaction {
                try execute("""
                    CREATE TABLE IF NOT EXISTS boards (
                        id TEXT PRIMARY KEY NOT NULL,
                        name TEXT NOT NULL,
                        created_at REAL NOT NULL
                    )
                    """)
                try execute("""
                    CREATE TABLE IF NOT EXISTS board_membership (
                        clip_id TEXT PRIMARY KEY NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
                        board_id TEXT NOT NULL REFERENCES boards(id) ON DELETE CASCADE
                    )
                    """)
                try execute("CREATE INDEX IF NOT EXISTS board_membership_board ON board_membership(board_id)")
            }
            // Additive migration for 0.4: detection, expiry, OCR and link previews.
            try transaction {
                let existing = try columnNames()
                for (column, type) in [("detail_kind", "TEXT"), ("expires_at", "REAL"), ("ocr_text", "TEXT"), ("link_title", "TEXT")]
                where !existing.contains(column) {
                    try execute("ALTER TABLE clips ADD COLUMN \(column) \(type)")
                }
                try execute("""
                    CREATE TABLE IF NOT EXISTS link_icons (
                        clip_id TEXT PRIMARY KEY NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
                        png BLOB NOT NULL
                    )
                    """)
            }
            // Folding every row's text was most of launch time; it now runs in the background.
            publishItems(try loadMetadata(), deferIndexing: true)
            boards = try loadBoards()
            boardMembership = try loadBoardMembership()
            try secureSidecars()
            indexInBackground()
        } catch {
            sqlite3_close(connection)
            database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
    }

    /// The CPU-heavy part of a capture: hashing, classification and payload encoding. Pure, so the
    /// clipboard monitor runs it off the main thread; `capture(_:)` then only touches the database.
    struct PreparedCapture {
        let clip: CapturedClip
        let fingerprint: String
        let detail: ClipDetail?
        let payload: Data
    }

    nonisolated static func prepare(_ clip: CapturedClip) throws -> PreparedCapture {
        guard !clip.entries.isEmpty,
              clip.entries.contains(where: { !$0.representations.isEmpty }) else {
            throw HistoryError.invalidPayload
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return PreparedCapture(clip: clip, fingerprint: fingerprint(clip.entries),
                               detail: clip.containsSecret ? .sensitive : ContentDetector.detect(kind: clip.kind, text: clip.text),
                               payload: try encoder.encode(clip.entries))
    }

    @discardableResult
    func capture(_ clip: CapturedClip) throws -> ClipItem {
        let prepared = try reportingErrors { try Self.prepare(clip) }
        return try capture(prepared)
    }

    @discardableResult
    func capture(_ prepared: PreparedCapture) throws -> ClipItem {
        try reportingErrors {
            let clip = prepared.clip
            let fingerprint = prepared.fingerprint
            let now = Date()
            let existingID = try findID(fingerprint: fingerprint)
            var result: ClipItem
            var next = items
            if let existingID, let index = next.firstIndex(where: { $0.id == existingID }) {
                result = next[index]
                result.lastCopiedAt = now
                result.sourceName = clip.sourceName
                result.sourceBundleID = clip.sourceBundleID
                // Copying a secret again restarts its countdown.
                if !result.isFavorite, let detail = result.detail { result.expiresAt = expiry(for: detail, from: now) }
                next[index] = result
            } else {
                let detail = prepared.detail
                result = ClipItem(id: UUID(), kind: clip.kind, title: clip.title, text: clip.text,
                                  sourceName: clip.sourceName, sourceBundleID: clip.sourceBundleID,
                                  createdAt: now, lastCopiedAt: now, isFavorite: false,
                                  detail: detail, expiresAt: detail.flatMap { expiry(for: $0, from: now) })
                next.append(result)
            }
            next.sort(by: Self.newestFirst)
            let kept = retainedItems(next, olderThan: .distantPast, maxItems: maximumItems)
            let keepIDs = Set(kept.map(\.id))
            let removed = next.filter { !keepIDs.contains($0.id) }
            try transaction {
                if existingID != nil {
                    // Do not replace the title: it may have been renamed by the user.
                    try execute("UPDATE clips SET last_copied_at = ?, source_name = ?, source_bundle_id = ?, expires_at = ? WHERE id = ?",
                                [.double(now.timeIntervalSince1970), .text(clip.sourceName),
                                 clip.sourceBundleID.map(SQLValue.text) ?? .null,
                                 result.expiresAt.map { .double($0.timeIntervalSince1970) } ?? .null, .text(result.id.uuidString)])
                } else {
                    try execute("""
                        INSERT INTO clips
                        (id, fingerprint, kind, title, text, source_name, source_bundle_id,
                         created_at, last_copied_at, is_favorite, payload, detail_kind, expires_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
                        """, [.text(result.id.uuidString), .text(fingerprint), .text(clip.kind.rawValue),
                              .text(clip.title), .text(clip.text), .text(clip.sourceName),
                              clip.sourceBundleID.map(SQLValue.text) ?? .null,
                              .double(now.timeIntervalSince1970), .double(now.timeIntervalSince1970), .data(prepared.payload),
                              .text(result.detail?.rawValue ?? ""),
                              result.expiresAt.map { .double($0.timeIntervalSince1970) } ?? .null])
                }
                for item in removed {
                    try execute("DELETE FROM clips WHERE id = ?", [.text(item.id.uuidString)])
                }
            }
            publishItems(kept)
            retainMembership(for: keepIDs)
            return result
        }
    }

    /// Adds a clip the capture writer already stored off the main thread. Returns nil when the row is
    /// gone (history was cleared in between), so nothing deleted reappears in the list.
    @discardableResult
    func adoptCapture(_ written: CaptureWriter.Written) throws -> ClipItem? {
        try reportingErrors {
            let item = written.item
            guard !items.contains(where: { $0.id == item.id }) else { return nil }
            let statement = try prepare("SELECT 1 FROM clips WHERE id = ?", [.text(item.id.uuidString)])
            let present = sqlite3_step(statement) == SQLITE_ROW
            sqlite3_finalize(statement)
            guard present else { return nil }
            var next = items
            next.append(item)
            next.sort(by: Self.newestFirst)
            let kept = retainedItems(next, olderThan: .distantPast, maxItems: maximumItems)
            let keepIDs = Set(kept.map(\.id))
            let removed = next.filter { !keepIDs.contains($0.id) }
            if !removed.isEmpty {
                try transaction {
                    for old in removed { try execute("DELETE FROM clips WHERE id = ?", [.text(old.id.uuidString)]) }
                }
            }
            publishItems(kept, precomputed: [item.id: written.haystack])
            retainMembership(for: keepIDs)
            return keepIDs.contains(item.id) ? item : nil
        }
    }

    func payload(for id: UUID) throws -> [ClipboardEntry] {
        try reportingErrors {
            let statement = try prepare("SELECT payload FROM clips WHERE id = ?", [.text(id.uuidString)])
            defer { sqlite3_finalize(statement) }
            let status = sqlite3_step(statement)
            guard status == SQLITE_ROW else {
                if status == SQLITE_DONE { throw HistoryError.missingItem }
                throw databaseError()
            }
            let size = Int(sqlite3_column_bytes(statement, 0))
            guard size > 0, let bytes = sqlite3_column_blob(statement, 0) else { throw HistoryError.invalidPayload }
            return try PropertyListDecoder().decode([ClipboardEntry].self, from: Data(bytes: bytes, count: size))
        }
    }

    func toggleFavorite(_ id: UUID) throws {
        try reportingErrors {
            guard let index = items.firstIndex(where: { $0.id == id }) else { throw HistoryError.missingItem }
            let value = !items[index].isFavorite
            // Unfavoriting a secret starts a fresh countdown instead of deleting it at once.
            let expiresAt = value ? items[index].expiresAt : items[index].detail.flatMap { expiry(for: $0, from: Date()) }
            try transaction {
                try execute("UPDATE clips SET is_favorite = ?, expires_at = ? WHERE id = ?",
                            [.integer(value ? 1 : 0), expiresAt.map { .double($0.timeIntervalSince1970) } ?? .null, .text(id.uuidString)])
                if !value {
                    try execute("DELETE FROM board_membership WHERE clip_id = ?", [.text(id.uuidString)])
                }
            }
            var next = items
            next[index].isFavorite = value
            next[index].expiresAt = expiresAt
            publishItems(next)
            if !value, boardMembership[id] != nil {
                var membership = boardMembership
                membership.removeValue(forKey: id)
                publishMembership(membership)
            }
        }
    }

    func rename(_ id: UUID, title: String) throws {
        try reportingErrors {
            guard let index = items.firstIndex(where: { $0.id == id }) else { throw HistoryError.missingItem }
            let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            guard !title.isEmpty, title != items[index].title else { return }
            try transaction {
                try execute("UPDATE clips SET title = ? WHERE id = ?", [.text(title), .text(id.uuidString)])
            }
            var next = items
            next[index].title = title
            publishItems(next)
        }
    }

    /// Replaces an item's content after it was edited in 轻贴. Its id, dates, favorite and board stay;
    /// an untouched automatic title follows the new first line, a renamed one is kept.
    func updateContent(_ id: UUID, entries: [ClipboardEntry], text: String) throws {
        try reportingErrors {
            guard let index = items.firstIndex(where: { $0.id == id }) else { throw HistoryError.missingItem }
            guard entries.contains(where: { !$0.representations.isEmpty }) else { throw HistoryError.invalidPayload }
            let old = items[index]
            var fingerprint = Self.fingerprint(entries)
            // Edited to match another clip: keep both rows rather than merging them silently.
            if let other = try findID(fingerprint: fingerprint), other != id { fingerprint += "#edit-\(id.uuidString)" }
            var updated = old
            updated.text = text
            if old.title == Self.automaticTitle(old.text), !text.isEmpty { updated.title = Self.automaticTitle(text) }
            updated.detail = ContentDetector.detect(kind: old.kind, text: text)
            if updated.detail != old.detail {
                updated.expiresAt = old.isFavorite ? nil : updated.detail.flatMap { expiry(for: $0, from: Date()) }
            }
            // An edited link fetches its title and icon again.
            if old.kind == .link, old.text != text { updated.linkTitle = nil }
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let payload = try encoder.encode(entries)
            try transaction {
                try execute("""
                    UPDATE clips SET fingerprint = ?, title = ?, text = ?, payload = ?, detail_kind = ?, expires_at = ?, link_title = ?
                    WHERE id = ?
                    """, [.text(fingerprint), .text(updated.title), .text(text), .data(payload),
                          .text(updated.detail?.rawValue ?? ""),
                          updated.expiresAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                          updated.linkTitle.map(SQLValue.text) ?? .null, .text(id.uuidString)])
                if updated.linkTitle == nil && old.linkTitle != nil {
                    try execute("DELETE FROM link_icons WHERE clip_id = ?", [.text(id.uuidString)])
                }
            }
            var next = items
            next[index] = updated
            publishItems(next)
        }
    }

    /// A separate copy at the front of history, so it can be edited without changing the original.
    @discardableResult
    func duplicate(_ id: UUID) throws -> ClipItem {
        let entries = try payload(for: id)
        return try reportingErrors {
            guard let original = items.first(where: { $0.id == id }) else { throw HistoryError.missingItem }
            let now = Date()
            var copy = original
            copy.id = UUID()
            copy.title = String((original.title + " 副本").prefix(200))
            copy.createdAt = now; copy.lastCopiedAt = now
            copy.isFavorite = false
            copy.expiresAt = copy.detail.flatMap { expiry(for: $0, from: now) }
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let payload = try encoder.encode(entries)
            // Same bytes as the original: a distinct fingerprint keeps the unique index satisfied,
            // and copying this content again still refreshes the original.
            let fingerprint = Self.fingerprint(entries) + "#copy-\(copy.id.uuidString)"
            try transaction {
                try execute("""
                    INSERT INTO clips
                    (id, fingerprint, kind, title, text, source_name, source_bundle_id,
                     created_at, last_copied_at, is_favorite, payload, detail_kind, expires_at, ocr_text, link_title)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?)
                    """, [.text(copy.id.uuidString), .text(fingerprint), .text(copy.kind.rawValue),
                          .text(copy.title), .text(copy.text), .text(copy.sourceName),
                          copy.sourceBundleID.map(SQLValue.text) ?? .null,
                          .double(now.timeIntervalSince1970), .double(now.timeIntervalSince1970), .data(payload),
                          .text(copy.detail?.rawValue ?? ""),
                          copy.expiresAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                          copy.ocrText.map(SQLValue.text) ?? .null, copy.linkTitle.map(SQLValue.text) ?? .null])
                if let icon = linkIcon(for: id) {
                    try execute("INSERT OR REPLACE INTO link_icons (clip_id, png) VALUES (?, ?)", [.text(copy.id.uuidString), .data(icon)])
                }
            }
            var next = items
            next.append(copy)
            next.sort(by: Self.newestFirst)
            publishItems(next)
            return copy
        }
    }

    /// The title a text clip gets when captured: its first non-empty line.
    static func automaticTitle(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.components(separatedBy: .newlines).first(where: { !$0.isEmpty }) ?? trimmed).prefix(160))
    }

    @discardableResult
    func createBoard(name: String) throws -> FavoriteBoard {
        try reportingErrors {
            let name = try validatedBoardName(name)
            let board = FavoriteBoard(id: UUID(), name: name)
            try transaction {
                try execute("INSERT INTO boards (id, name, created_at) VALUES (?, ?, ?)",
                            [.text(board.id.uuidString), .text(name), .double(Date().timeIntervalSince1970)])
            }
            boards.append(board)
            return board
        }
    }

    func renameBoard(_ id: UUID, name: String) throws {
        try reportingErrors {
            guard let index = boards.firstIndex(where: { $0.id == id }) else { throw HistoryError.missingBoard }
            let name = try validatedBoardName(name, excluding: id)
            guard boards[index].name != name else { return }
            try transaction {
                try execute("UPDATE boards SET name = ? WHERE id = ?", [.text(name), .text(id.uuidString)])
            }
            var next = boards
            next[index].name = name
            if next != boards { boards = next }
        }
    }

    func removeBoard(_ id: UUID) throws {
        try reportingErrors {
            guard boards.contains(where: { $0.id == id }) else { return }
            try transaction {
                // Explicitly delete memberships as well as using FK cascade for older SQLite clients.
                try execute("DELETE FROM board_membership WHERE board_id = ?", [.text(id.uuidString)])
                try execute("DELETE FROM boards WHERE id = ?", [.text(id.uuidString)])
            }
            let next = boards.filter { $0.id != id }
            if next != boards { boards = next }
            publishMembership(boardMembership.filter { $0.value != id })
        }
    }

    /// A clip belongs to at most one board. nil moves it back to uncategorized favorites.
    func assignToBoard(_ clipID: UUID, boardID: UUID?) throws {
        try reportingErrors {
            guard let index = items.firstIndex(where: { $0.id == clipID }) else { throw HistoryError.missingItem }
            if let boardID, !boards.contains(where: { $0.id == boardID }) { throw HistoryError.missingBoard }
            let shouldFavorite = boardID != nil && !items[index].isFavorite
            guard boardMembership[clipID] != boardID || shouldFavorite else { return }
            try transaction {
                if let boardID {
                    try execute("""
                        INSERT INTO board_membership (clip_id, board_id) VALUES (?, ?)
                        ON CONFLICT(clip_id) DO UPDATE SET board_id = excluded.board_id
                        """, [.text(clipID.uuidString), .text(boardID.uuidString)])
                    if shouldFavorite {
                        try execute("UPDATE clips SET is_favorite = 1 WHERE id = ?", [.text(clipID.uuidString)])
                    }
                } else {
                    try execute("DELETE FROM board_membership WHERE clip_id = ?", [.text(clipID.uuidString)])
                }
            }
            if shouldFavorite {
                var next = items
                next[index].isFavorite = true
                publishItems(next)
            }
            var membership = boardMembership
            membership[clipID] = boardID
            publishMembership(membership)
        }
    }

    /// Removes several clips in one transaction.
    func remove(_ ids: Set<UUID>) throws {
        try reportingErrors {
            let present = ids.filter { id in items.contains(where: { $0.id == id }) }
            guard !present.isEmpty else { return }
            try transaction {
                for id in present { try execute("DELETE FROM clips WHERE id = ?", [.text(id.uuidString)]) }
            }
            publishItems(items.filter { !present.contains($0.id) })
            retainMembership(for: Set(items.map(\.id)))
        }
    }

    /// Favorites several clips into one board (nil = uncategorized favorites) in one transaction.
    func favorite(_ ids: [UUID], boardID: UUID?) throws {
        try reportingErrors {
            if let boardID, !boards.contains(where: { $0.id == boardID }) { throw HistoryError.missingBoard }
            let present = ids.filter { id in items.contains(where: { $0.id == id }) }
            guard !present.isEmpty else { return }
            try transaction {
                for id in present {
                    try execute("UPDATE clips SET is_favorite = 1 WHERE id = ?", [.text(id.uuidString)])
                    if let boardID {
                        try execute("""
                            INSERT INTO board_membership (clip_id, board_id) VALUES (?, ?)
                            ON CONFLICT(clip_id) DO UPDATE SET board_id = excluded.board_id
                            """, [.text(id.uuidString), .text(boardID.uuidString)])
                    } else {
                        try execute("DELETE FROM board_membership WHERE clip_id = ?", [.text(id.uuidString)])
                    }
                }
            }
            let set = Set(present)
            publishItems(items.map { item in
                guard set.contains(item.id) else { return item }
                var copy = item; copy.isFavorite = true; return copy
            })
            var membership = boardMembership
            for id in present { membership[id] = boardID }
            publishMembership(membership)
        }
    }

    /// Stores recognized text for an image; an empty string records that recognition ran.
    /// A secret in the recognized text makes the image a sensitive clip with the same countdown.
    func setOCRText(_ id: UUID, text: String, now: Date = Date()) throws {
        try reportingErrors {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            var item = items[index]
            item.ocrText = text
            if item.detail != .sensitive, !text.isEmpty, ContentDetector.isSensitive(text) {
                item.detail = .sensitive
                item.expiresAt = item.isFavorite ? nil : expiry(for: .sensitive, from: now)
            }
            try execute("UPDATE clips SET ocr_text = ?, detail_kind = ?, expires_at = ? WHERE id = ?",
                        [.text(text), .text(item.detail?.rawValue ?? ""),
                         item.expiresAt.map { .double($0.timeIntervalSince1970) } ?? .null, .text(id.uuidString)])
            var next = items
            next[index] = item
            publishItems(next)
        }
    }

    /// Stores a fetched page title and icon; an empty title records a failed fetch so it is not retried.
    func setLinkPreview(_ id: UUID, title: String, iconPNG: Data?) throws {
        try reportingErrors {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            try transaction {
                try execute("UPDATE clips SET link_title = ? WHERE id = ?", [.text(title), .text(id.uuidString)])
                if let iconPNG {
                    try execute("INSERT OR REPLACE INTO link_icons (clip_id, png) VALUES (?, ?)", [.text(id.uuidString), .data(iconPNG)])
                }
            }
            var next = items
            next[index].linkTitle = title
            publishItems(next)
        }
    }

    // MARK: Favorites backup

    /// Every favorite with its stored payload and board. Not encrypted; the caller warns before saving.
    struct FavoritesArchive: Codable {
        struct Board: Codable { var id: UUID; var name: String }
        struct Item: Codable {
            var id: UUID
            var kind: String
            var title: String
            var text: String
            var sourceName: String
            var sourceBundleID: String?
            var createdAt: Date
            var lastCopiedAt: Date
            var detail: String?
            var ocrText: String?
            var linkTitle: String?
            var boardID: UUID?
            /// The stored payload as is: a binary property list of [ClipboardEntry].
            var payload: Data
        }
        static let formatName = "com.local.lightpaste.favorites"
        var format = Self.formatName
        var version = 1
        var exportedAt: Date
        var boards: [Board]
        var items: [Item]
    }

    struct ImportResult: Equatable { var added: Int; var updated: Int; var boardsCreated: Int }

    func exportFavorites(now: Date = Date()) throws -> (data: Data, count: Int, sensitive: Int) {
        try reportingErrors {
            let favorites = items.filter(\.isFavorite)
            let archive = FavoritesArchive(
                exportedAt: now,
                boards: boards.map { FavoritesArchive.Board(id: $0.id, name: $0.name) },
                items: try favorites.map { item in
                    FavoritesArchive.Item(id: item.id, kind: item.kind.rawValue, title: item.title, text: item.text,
                                          sourceName: item.sourceName, sourceBundleID: item.sourceBundleID,
                                          createdAt: item.createdAt, lastCopiedAt: item.lastCopiedAt,
                                          detail: item.detail?.rawValue, ocrText: item.ocrText, linkTitle: item.linkTitle,
                                          boardID: boardMembership[item.id], payload: try rawPayload(for: item.id))
                })
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            return (try encoder.encode(archive), favorites.count, favorites.filter { $0.detail == .sensitive }.count)
        }
    }

    /// Adds the archive's favorites. Content already in history is favorited (and filed) instead of
    /// duplicated; boards are matched by name. Importing the same file twice changes nothing more.
    @discardableResult
    func importFavorites(_ data: Data) throws -> ImportResult {
        try reportingErrors {
            guard let archive = try? PropertyListDecoder().decode(FavoritesArchive.self, from: data),
                  archive.format == FavoritesArchive.formatName else {
                throw HistoryError.invalidBackup
            }
            guard archive.version <= 1 else { throw HistoryError.newerBackup }
            var result = ImportResult(added: 0, updated: 0, boardsCreated: 0)
            var boardIDs: [UUID: UUID] = [:]
            let now = Date()
            try transaction {
                var known = boards
                for board in archive.boards {
                    let name = String(board.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
                    guard !name.isEmpty else { continue }
                    if let local = known.first(where: { Self.normalized($0.name) == Self.normalized(name) }) {
                        boardIDs[board.id] = local.id
                    } else {
                        let local = FavoriteBoard(id: UUID(), name: name)
                        try execute("INSERT INTO boards (id, name, created_at) VALUES (?, ?, ?)",
                                    [.text(local.id.uuidString), .text(name), .double(now.timeIntervalSince1970)])
                        known.append(local); boardIDs[board.id] = local.id; result.boardsCreated += 1
                    }
                }
                for entry in archive.items {
                    guard let kind = ClipKind(rawValue: entry.kind),
                          let entries = try? PropertyListDecoder().decode([ClipboardEntry].self, from: entry.payload),
                          entries.contains(where: { !$0.representations.isEmpty }) else { continue }
                    let fingerprint = Self.fingerprint(entries)
                    let id: UUID
                    if let existing = try findID(fingerprint: fingerprint) {
                        id = existing
                        // A favorite never expires.
                        try execute("UPDATE clips SET is_favorite = 1, expires_at = NULL WHERE id = ?", [.text(id.uuidString)])
                        result.updated += 1
                    } else {
                        id = items.contains(where: { $0.id == entry.id }) ? UUID() : entry.id
                        let detail = entry.detail.flatMap(ClipDetail.init(rawValue:))
                        try execute("""
                            INSERT INTO clips
                            (id, fingerprint, kind, title, text, source_name, source_bundle_id,
                             created_at, last_copied_at, is_favorite, payload, detail_kind, expires_at, ocr_text, link_title)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, NULL, ?, ?)
                            """, [.text(id.uuidString), .text(fingerprint), .text(kind.rawValue),
                                  .text(String(entry.title.prefix(200))), .text(entry.text), .text(entry.sourceName),
                                  entry.sourceBundleID.map(SQLValue.text) ?? .null,
                                  .double(entry.createdAt.timeIntervalSince1970), .double(entry.lastCopiedAt.timeIntervalSince1970),
                                  .data(entry.payload), .text(detail?.rawValue ?? ""),
                                  entry.ocrText.map(SQLValue.text) ?? .null, entry.linkTitle.map(SQLValue.text) ?? .null])
                        result.added += 1
                    }
                    if let board = entry.boardID.flatMap({ boardIDs[$0] }) {
                        try execute("""
                            INSERT INTO board_membership (clip_id, board_id) VALUES (?, ?)
                            ON CONFLICT(clip_id) DO UPDATE SET board_id = excluded.board_id
                            """, [.text(id.uuidString), .text(board.uuidString)])
                    }
                }
            }
            publishItems(try loadMetadata())
            boards = try loadBoards()
            publishMembership(try loadBoardMembership())
            return result
        }
    }

    private func rawPayload(for id: UUID) throws -> Data {
        let statement = try prepare("SELECT payload FROM clips WHERE id = ?", [.text(id.uuidString)])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw HistoryError.missingItem }
        let size = Int(sqlite3_column_bytes(statement, 0))
        guard size > 0, let bytes = sqlite3_column_blob(statement, 0) else { throw HistoryError.invalidPayload }
        return Data(bytes: bytes, count: size)
    }

    func linkIcon(for id: UUID) -> Data? {
        guard let statement = try? prepare("SELECT png FROM link_icons WHERE clip_id = ?", [.text(id.uuidString)]) else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let size = Int(sqlite3_column_bytes(statement, 0))
        guard size > 0, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return Data(bytes: bytes, count: size)
    }

    func remove(_ id: UUID) throws {
        try reportingErrors {
            guard items.contains(where: { $0.id == id }) else { return }
            try transaction { try execute("DELETE FROM clips WHERE id = ?", [.text(id.uuidString)]) }
            publishItems(items.filter { $0.id != id })
            if boardMembership[id] != nil {
                var membership = boardMembership
                membership.removeValue(forKey: id)
                publishMembership(membership)
            }
        }
    }

    func clearUnfavorited() throws {
        try reportingErrors {
            let kept = items.filter(\.isFavorite)
            guard kept.count != items.count else { return }
            try transaction { try execute("DELETE FROM clips WHERE is_favorite = 0") }
            publishItems(kept)
            retainMembership(for: Set(kept.map(\.id)))
        }
    }

    /// Favorites are retained even if they alone exceed maxItems.
    func prune(olderThan date: Date, maxItems: Int, now: Date = Date()) throws {
        try reportingErrors {
            let live = items.filter { $0.isFavorite || ($0.expiresAt.map { $0 > now } ?? true) }
            let kept = retainedItems(live, olderThan: date, maxItems: maxItems)
            let keepIDs = Set(kept.map(\.id))
            let removed = items.filter { !keepIDs.contains($0.id) }
            guard !removed.isEmpty else { return }
            try transaction {
                for item in removed {
                    try execute("DELETE FROM clips WHERE id = ?", [.text(item.id.uuidString)])
                }
            }
            publishItems(kept)
            retainMembership(for: keepIDs)
        }
    }

    func search(_ query: String, filter: SidebarFilter, boardID: UUID? = nil) -> [ClipItem] {
        let keywords = query.split(whereSeparator: { $0.isWhitespace }).map { Self.normalized(String($0)) }
        // items are already in descending copy order. Empty-query navigation avoids text work entirely.
        if keywords.isEmpty {
            return items.filter { item in
                filter.matches(item) && (boardID == nil || boardMembership[item.id] == boardID)
            }
        }
        // Searching right after launch, before the background pass is done: finish it here.
        if !unindexedIDs.isEmpty {
            for item in items where unindexedIDs.contains(item.id) { searchHaystacks[item.id] = Self.haystack(for: item) }
            unindexedIDs.removeAll()
        }
        return items.filter { item in
            guard filter.matches(item), boardID == nil || boardMembership[item.id] == boardID,
                  let haystack = searchHaystacks[item.id] else { return false }
            return keywords.allSatisfy { Self.containsBytes(haystack, $0) }
        }
    }

    /// Substring test on the folded UTF-8 bytes. Character-wise `contains` walks grapheme clusters and
    /// was most of a search keystroke's cost; on folded text it finds the same matches for typed queries.
    private static func containsBytes(_ haystack: String, _ needle: String) -> Bool {
        var haystack = haystack, needle = needle
        return haystack.withUTF8 { h in
            needle.withUTF8 { n in
                guard !n.isEmpty else { return true }
                guard h.count >= n.count, let hBase = h.baseAddress, let nBase = n.baseAddress else { return false }
                return memmem(hBase, h.count, nBase, n.count) != nil
            }
        }
    }

    private nonisolated static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: searchLocale)
    }

    private func publishItems(_ next: [ClipItem], deferIndexing: Bool = false, precomputed: [UUID: String] = [:]) {
        guard next != items else { return }
        let previous = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let keepIDs = Set(next.map(\.id))
        searchHaystacks = searchHaystacks.filter { keepIDs.contains($0.key) }
        unindexedIDs.formIntersection(keepIDs)
        for item in next {
            if let haystack = precomputed[item.id] {
                searchHaystacks[item.id] = haystack
                unindexedIDs.remove(item.id)
                continue
            }
            let old = previous[item.id]
            if old?.title != item.title || old?.text != item.text || old?.sourceName != item.sourceName
                || old?.sourceBundleID != item.sourceBundleID || old?.ocrText != item.ocrText
                || old?.linkTitle != item.linkTitle || (searchHaystacks[item.id] == nil && !unindexedIDs.contains(item.id)) {
                if deferIndexing {
                    unindexedIDs.insert(item.id)
                } else {
                    searchHaystacks[item.id] = Self.haystack(for: item)
                    unindexedIDs.remove(item.id)
                }
            }
        }
        items = next
    }

    fileprivate nonisolated static func haystack(for item: ClipItem) -> String {
        let pinyin = pinyinKeys([item.title, item.sourceName, item.linkTitle ?? "", String(item.text.prefix(2_000))]
            .joined(separator: "\n"))
        var haystack = normalized(
            [item.title, item.text, item.sourceName, item.sourceBundleID ?? "", item.ocrText ?? "",
             item.linkTitle ?? "", item.detail?.label ?? "", pinyin].joined(separator: "\n"))
        // Folding may return a bridged string; keep native UTF-8 so each search reads it without copying.
        haystack.makeContiguousUTF8()
        return haystack
    }

    /// Full pinyin and initials of the Chinese in a text, one line each, so “huiyi” and “hy” find “会议”.
    /// Limited to the first `limit` Chinese characters: the title and the start of the text.
    nonisolated static func pinyinKeys(_ text: String, limit: Int = 600) -> String {
        var full: [String] = [], initials: [String] = []
        var syllables: [String] = []
        var count = 0
        func flush() {
            guard !syllables.isEmpty else { return }
            full.append(syllables.joined())
            initials.append(String(syllables.compactMap(\.first)))
            syllables.removeAll(keepingCapacity: true)
        }
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) {
                guard count < limit else { break }
                if let syllable = PinyinTable.shared.syllable(for: scalar) { syllables.append(syllable) }
                count += 1
            } else {
                flush()
            }
        }
        flush()
        guard !full.isEmpty else { return "" }
        return full.joined(separator: " ") + "\n" + initials.joined(separator: " ")
    }

    /// Rows edited meanwhile were re-indexed on the main thread and left the pending set, so their
    /// background result is dropped instead of overwriting the newer text.
    private func indexInBackground() {
        let pending = items.filter { unindexedIDs.contains($0.id) }
        guard !pending.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            let built = pending.map { ($0.id, Self.haystack(for: $0)) }
            await self?.applyBackgroundIndex(built)
        }
    }

    private func applyBackgroundIndex(_ built: [(UUID, String)]) {
        for (id, haystack) in built where unindexedIDs.contains(id) {
            searchHaystacks[id] = haystack
            unindexedIDs.remove(id)
        }
    }

    private func publishMembership(_ membership: [UUID: UUID]) {
        if membership != boardMembership { boardMembership = membership }
    }

    private func retainMembership(for clipIDs: Set<UUID>) {
        publishMembership(boardMembership.filter { clipIDs.contains($0.key) })
    }

    private func validatedBoardName(_ rawName: String, excluding id: UUID? = nil) throws -> String {
        let name = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !name.isEmpty else { throw HistoryError.invalidBoardName }
        let key = Self.normalized(name)
        guard !boards.contains(where: { $0.id != id && Self.normalized($0.name) == key }) else {
            throw HistoryError.duplicateBoardName
        }
        return name
    }

    private func retainedItems(_ values: [ClipItem], olderThan date: Date, maxItems: Int) -> [ClipItem] {
        let sorted = values.sorted(by: Self.newestFirst)
        let favoriteCount = sorted.filter(\.isFavorite).count
        var available = max(0, maxItems - favoriteCount)
        return sorted.filter { item in
            if item.isFavorite { return true }
            guard item.lastCopiedAt >= date, available > 0 else { return false }
            available -= 1
            return true
        }
    }

    private static func newestFirst(_ lhs: ClipItem, _ rhs: ClipItem) -> Bool {
        lhs.lastCopiedAt == rhs.lastCopiedAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.lastCopiedAt > rhs.lastCopiedAt
    }

    private nonisolated static func fingerprint(_ entries: [ClipboardEntry]) -> String {
        var digest = SHA256()
        func appendLength(_ length: Int) {
            var value = UInt64(length).bigEndian
            withUnsafeBytes(of: &value) { digest.update(bufferPointer: $0) }
        }
        appendLength(entries.count)
        for entry in entries {
            let representations = entry.representations.sorted {
                if $0.type != $1.type { return $0.type < $1.type }
                return $0.data.lexicographicallyPrecedes($1.data)
            }
            appendLength(representations.count)
            for representation in representations {
                let type = Data(representation.type.utf8)
                appendLength(type.count)
                digest.update(data: type)
                appendLength(representation.data.count)
                digest.update(data: representation.data)
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func loadMetadata() throws -> [ClipItem] {
        let statement = try prepare("""
            SELECT id, kind, title, text, source_name, source_bundle_id,
                   created_at, last_copied_at, is_favorite, detail_kind, expires_at, ocr_text, link_title
            FROM clips ORDER BY last_copied_at DESC, id ASC
            """)
        var result: [ClipItem] = []
        var backfill: [(UUID, ClipDetail?)] = []
        func optionalText(_ column: Int32) -> String? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : string(statement, column)
        }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                sqlite3_finalize(statement)
                // Rows from 0.3 are classified once; they keep their dates and never gain an expiry.
                if !backfill.isEmpty {
                    try transaction {
                        for (id, detail) in backfill {
                            try execute("UPDATE clips SET detail_kind = ? WHERE id = ?", [.text(detail?.rawValue ?? ""), .text(id.uuidString)])
                        }
                    }
                }
                return result
            }
            guard status == SQLITE_ROW else { sqlite3_finalize(statement); throw databaseError() }
            guard let id = UUID(uuidString: string(statement, 0)), let kind = ClipKind(rawValue: string(statement, 1)) else {
                sqlite3_finalize(statement)
                throw HistoryError.database("记录格式无效")
            }
            let text = string(statement, 3)
            var detail: ClipDetail?
            if let raw = optionalText(9) {
                detail = ClipDetail(rawValue: raw)
            } else {
                detail = ContentDetector.detect(kind: kind, text: text)
                backfill.append((id, detail))
            }
            result.append(ClipItem(id: id, kind: kind, title: string(statement, 2), text: text,
                                   sourceName: string(statement, 4),
                                   sourceBundleID: optionalText(5),
                                   createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                                   lastCopiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                                   isFavorite: sqlite3_column_int(statement, 8) != 0,
                                   detail: detail,
                                   expiresAt: sqlite3_column_type(statement, 10) == SQLITE_NULL ? nil
                                       : Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                                   ocrText: optionalText(11), linkTitle: optionalText(12)))
        }
    }

    private func expiry(for detail: ClipDetail, from date: Date) -> Date? {
        Self.expiry(for: detail, from: date, sensitiveLifetime: sensitiveLifetime)
    }

    fileprivate nonisolated static func expiry(for detail: ClipDetail, from date: Date, sensitiveLifetime: TimeInterval?) -> Date? {
        switch detail {
        case .otp: return date.addingTimeInterval(ContentDetector.otpLifetime)
        case .sensitive: return sensitiveLifetime.map { date.addingTimeInterval($0) }
        default: return nil
        }
    }

    private func columnNames() throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(clips)")
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { names.insert(string(statement, 1)) }
        return names
    }

    private func loadBoards() throws -> [FavoriteBoard] {
        let statement = try prepare("SELECT id, name FROM boards ORDER BY created_at ASC, id ASC")
        defer { sqlite3_finalize(statement) }
        var result: [FavoriteBoard] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw databaseError() }
            guard let id = UUID(uuidString: string(statement, 0)) else { throw HistoryError.database("收藏分类标识无效") }
            result.append(FavoriteBoard(id: id, name: string(statement, 1)))
        }
    }

    private func loadBoardMembership() throws -> [UUID: UUID] {
        let statement = try prepare("""
            SELECT m.clip_id, m.board_id FROM board_membership m
            JOIN clips c ON c.id = m.clip_id JOIN boards b ON b.id = m.board_id
            WHERE c.is_favorite = 1
            """)
        defer { sqlite3_finalize(statement) }
        var result: [UUID: UUID] = [:]
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw databaseError() }
            guard let clipID = UUID(uuidString: string(statement, 0)),
                  let boardID = UUID(uuidString: string(statement, 1)) else {
                throw HistoryError.database("收藏分类归属无效")
            }
            result[clipID] = boardID
        }
    }

    private func findID(fingerprint: String) throws -> UUID? {
        let statement = try prepare("SELECT id FROM clips WHERE fingerprint = ?", [.text(fingerprint)])
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw databaseError() }
        guard let id = UUID(uuidString: string(statement, 0)) else { throw HistoryError.database("记录标识无效") }
        return id
    }

    private enum SQLValue { case text(String), data(Data), double(Double), integer(Int32), null }

    private func prepare(_ sql: String, _ values: [SQLValue] = []) throws -> OpaquePointer {
        guard let database else { throw HistoryError.database("数据库已关闭") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError()
        }
        do {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let status: Int32
                switch value {
                case .text(let text):
                    status = text.utf8CString.withUnsafeBufferPointer {
                        sqlite3_bind_text(statement, index, $0.baseAddress, Int32($0.count - 1), transient)
                    }
                case .data(let data):
                    status = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
                case .double(let number): status = sqlite3_bind_double(statement, index, number)
                case .integer(let number): status = sqlite3_bind_int(statement, index, number)
                case .null: status = sqlite3_bind_null(statement, index)
                }
                guard status == SQLITE_OK else { throw databaseError() }
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    private func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW { status = sqlite3_step(statement) }
        guard status == SQLITE_DONE else { throw databaseError() }
    }

    private func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try work()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        // The database is inside a 0700 directory; secure SQLite's optional sibling files too.
        try? secureSidecars()
    }

    private func secureSidecars() throws {
        for path in [fileURL.path, fileURL.path + "-wal", fileURL.path + "-shm"] where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    private func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }

    private func databaseError() -> HistoryError {
        .database(database.map { String(cString: sqlite3_errmsg($0)) } ?? "数据库已关闭")
    }

    private func reportingErrors<T>(_ operation: () throws -> T) throws -> T {
        do {
            let result = try operation()
            if errorMessage != nil { errorMessage = nil }
            return result
        } catch {
            let message = error.localizedDescription
            if errorMessage != message { errorMessage = message }
            throw error
        }
    }
}

/// A second connection, used only on the clipboard monitor's serial capture queue, that inserts a newly
/// copied clip (images are several MB) without holding the main thread. The main thread then adopts the
/// row into the list. Anything else — content already in history, a conflict, an error — goes back to
/// the main-thread `capture(_:)` path unchanged.
final class CaptureWriter: @unchecked Sendable {
    struct Written {
        let item: ClipItem
        let haystack: String
    }

    enum Outcome {
        case written(Written)
        case needsMainThread
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var database: OpaquePointer?

    init(fileURL: URL) { self.fileURL = fileURL }

    deinit { if let database { sqlite3_close_v2(database) } }

    func write(_ prepared: HistoryStore.PreparedCapture, sensitiveLifetime: TimeInterval?, now: Date = Date()) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        guard let database = connection() else { return .needsMainThread }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func bind(_ statement: OpaquePointer, _ index: Int32, _ text: String?) -> Bool {
            guard let text else { return sqlite3_bind_null(statement, index) == SQLITE_OK }
            return text.utf8CString.withUnsafeBufferPointer {
                sqlite3_bind_text(statement, index, $0.baseAddress, Int32($0.count - 1), transient)
            } == SQLITE_OK
        }

        var lookup: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM clips WHERE fingerprint = ?", -1, &lookup, nil) == SQLITE_OK,
              let lookup else { return .needsMainThread }
        let known = bind(lookup, 1, prepared.fingerprint) ? sqlite3_step(lookup) : SQLITE_ERROR
        sqlite3_finalize(lookup)
        // Copied before: refreshing its date and source is a small update the main thread already does.
        guard known == SQLITE_DONE else { return .needsMainThread }

        let clip = prepared.clip
        let detail = prepared.detail
        let item = ClipItem(id: UUID(), kind: clip.kind, title: clip.title, text: clip.text,
                            sourceName: clip.sourceName, sourceBundleID: clip.sourceBundleID,
                            createdAt: now, lastCopiedAt: now, isFavorite: false, detail: detail,
                            expiresAt: detail.flatMap { HistoryStore.expiry(for: $0, from: now, sensitiveLifetime: sensitiveLifetime) })
        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(database, """
            INSERT INTO clips
            (id, fingerprint, kind, title, text, source_name, source_bundle_id,
             created_at, last_copied_at, is_favorite, payload, detail_kind, expires_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
            """, -1, &insert, nil) == SQLITE_OK, let insert else { return .needsMainThread }
        defer { sqlite3_finalize(insert) }
        let time = now.timeIntervalSince1970
        let bound = bind(insert, 1, item.id.uuidString) && bind(insert, 2, prepared.fingerprint)
            && bind(insert, 3, clip.kind.rawValue) && bind(insert, 4, clip.title) && bind(insert, 5, clip.text)
            && bind(insert, 6, clip.sourceName) && bind(insert, 7, clip.sourceBundleID)
            && sqlite3_bind_double(insert, 8, time) == SQLITE_OK && sqlite3_bind_double(insert, 9, time) == SQLITE_OK
            && prepared.payload.withUnsafeBytes {
                sqlite3_bind_blob(insert, 10, $0.baseAddress, Int32($0.count), transient) } == SQLITE_OK
            && bind(insert, 11, detail?.rawValue ?? "")
            && (item.expiresAt.map { sqlite3_bind_double(insert, 12, $0.timeIntervalSince1970) }
                ?? sqlite3_bind_null(insert, 12)) == SQLITE_OK
        // A constraint failure means the main thread stored the same content meanwhile.
        guard bound, sqlite3_step(insert) == SQLITE_DONE else { return .needsMainThread }
        for path in [fileURL.path + "-wal", fileURL.path + "-shm"] where FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        return .written(Written(item: item, haystack: HistoryStore.haystack(for: item)))
    }

    /// Opened on first use, after the main connection has created and migrated the schema.
    private func connection() -> OpaquePointer? {
        if let database { return database }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(fileURL.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let connection else {
            if let connection { sqlite3_close(connection) }
            return nil
        }
        sqlite3_busy_timeout(connection, 5_000)
        for pragma in ["PRAGMA synchronous = FULL", "PRAGMA foreign_keys = ON"] {
            guard sqlite3_exec(connection, pragma, nil, nil, nil) == SQLITE_OK else { sqlite3_close(connection); return nil }
        }
        database = connection
        return connection
    }
}

/// Pinyin of single Chinese characters, filled on first use. The system transform reads each
/// character on its own (银行 becomes “yinxing” either way), so caching per character gives the
/// same result as transforming whole runs at a fraction of the cost.
final class PinyinTable: @unchecked Sendable {
    static let shared = PinyinTable()
    private let lock = NSLock()
    private var syllables: [UInt32: String] = [:]

    func syllable(for scalar: Unicode.Scalar) -> String? {
        lock.lock()
        if let cached = syllables[scalar.value] { lock.unlock(); return cached.isEmpty ? nil : cached }
        lock.unlock()
        let latin = NSMutableString(string: String(Character(scalar)))
        CFStringTransform(latin, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(latin, nil, kCFStringTransformStripDiacritics, false)
        let value = (latin as String).lowercased().filter { $0.isASCII && $0.isLetter }
        lock.lock()
        syllables[scalar.value] = value
        lock.unlock()
        return value.isEmpty ? nil : value
    }
}
