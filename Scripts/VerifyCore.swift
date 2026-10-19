import AppKit
import SQLite3

/// Standalone validation against the app's real implementation. It uses only UUID-named
/// pasteboards and its own temporary database; it never accesses NSPasteboard.general.
/// See README.md for the swiftc command (no XCTest or extra dependencies required).
@main
@MainActor
struct VerifyCore {
    private struct VerificationFailure: Error {
        let check: String
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw VerificationFailure(check: label) }
    }

    private static func clip(_ text: String, kind: ClipKind = .text, title: String? = nil) -> CapturedClip {
        CapturedClip(entries: [ClipboardEntry(representations: [
            ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))
        ])], kind: kind, title: title ?? text, text: text, sourceName: "测试应用", sourceBundleID: "local.lightpaste.tests")
    }

    /// Runs the main run loop until the condition holds, so main-queue work from the capture queue lands.
    private static func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    private static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }

    private static func write(_ text: String, to board: NSPasteboard) {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    private static func newBoard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("LightPasteVerification-\(UUID().uuidString)"))
    }

    private static func richEntries() -> [ClipboardEntry] {
        [
            ClipboardEntry(representations: [
                ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("带格式的文本".utf8)),
                ClipboardRepresentation(type: NSPasteboard.PasteboardType.rtf.rawValue, data: Data(#"{\rtf1\ansi formatted text}"#.utf8))
            ]),
            ClipboardEntry(representations: [
                ClipboardRepresentation(type: NSPasteboard.PasteboardType.URL.rawValue, data: Data("https://example.com/document".utf8)),
                ClipboardRepresentation(type: "local.lightpaste.tests.binary", data: Data([0, 255, 42, 0, 128]))
            ])
        ]
    }

    /// Creates the pre-classification schema directly, so migration is checked against
    /// an existing database rather than a database already created by the new store.
    private static func seedLegacyDatabase(in directory: URL, id: UUID, captured: CapturedClip) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var connection: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("history.sqlite3").path, &connection) == SQLITE_OK,
              let database = connection else {
            if let connection { sqlite3_close(connection) }
            throw VerificationFailure(check: "应可创建旧版临时数据库")
        }
        defer { sqlite3_close(database) }
        let schema = """
            CREATE TABLE clips (
                id TEXT PRIMARY KEY NOT NULL, fingerprint TEXT UNIQUE NOT NULL,
                kind TEXT NOT NULL, title TEXT NOT NULL, text TEXT NOT NULL,
                source_name TEXT NOT NULL, source_bundle_id TEXT,
                created_at REAL NOT NULL, last_copied_at REAL NOT NULL,
                is_favorite INTEGER NOT NULL DEFAULT 0, payload BLOB NOT NULL
            )
            """
        try require(sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK, "应可创建原始 clips 表")
        var statement: OpaquePointer?
        let insert = "INSERT INTO clips VALUES (?, ?, ?, ?, ?, ?, ?, 1700000000, 1700000000, 1, ?)"
        try require(sqlite3_prepare_v2(database, insert, -1, &statement, nil) == SQLITE_OK, "应可准备旧版记录")
        guard let statement else { throw VerificationFailure(check: "应有旧版记录语句") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let fields = [id.uuidString, "legacy-fixture", captured.kind.rawValue, captured.title,
                      captured.text, captured.sourceName, captured.sourceBundleID ?? ""]
        for (offset, text) in fields.enumerated() {
            let status = text.utf8CString.withUnsafeBufferPointer {
                sqlite3_bind_text(statement, Int32(offset + 1), $0.baseAddress, Int32($0.count - 1), transient)
            }
            try require(status == SQLITE_OK, "应可写入旧版元数据")
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let payload = try encoder.encode(captured.entries)
        let status = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 8, $0.baseAddress, Int32($0.count), transient) }
        try require(status == SQLITE_OK && sqlite3_step(statement) == SQLITE_DONE, "应可保存旧版原始载荷")
    }

    static func main() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LightPasteVerification-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var completed = 0
        func run(_ name: String, _ body: () throws -> Void) throws {
            try body()
            completed += 1
            print("PASS \(name)")
        }
        do {
            try run("去重、收藏与重启持久化") {
                let folder = root.appendingPathComponent("dedup")
                let store = try HistoryStore(directory: folder)
                let captured = clip("开会时要带的资料")
                let first = try store.capture(captured)
                try store.toggleFavorite(first.id)
                let duplicate = try store.capture(captured)
                try require(duplicate.id == first.id && duplicate.isFavorite && store.items.count == 1, "重复内容应沿用收藏记录")
                let reopened = try HistoryStore(directory: folder)
                try require(reopened.items.count == 1 && reopened.items.first?.id == first.id && reopened.items.first?.isFavorite == true, "收藏和标识应持久化")
                try require(reopened.payload(for: first.id) == captured.entries, "载荷应持久化")
            }
            try run("多项目、多格式载荷持久化") {
                let folder = root.appendingPathComponent("formats")
                let store = try HistoryStore(directory: folder)
                let entries = richEntries()
                let item = try store.capture(CapturedClip(entries: entries, kind: .text, title: "多项目", text: "带格式的文本", sourceName: "测试应用", sourceBundleID: nil))
                let reopened = try HistoryStore(directory: folder)
                try require(reopened.payload(for: item.id) == entries, "多项目原始字节应完整恢复")
            }
            try run("中文、多关键词搜索与收藏筛选") {
                let store = try HistoryStore(directory: root.appendingPathComponent("search"))
                let favorite = try store.capture(clip("上海项目的合同，请在周五确认。"))
                _ = try store.capture(clip("北京项目的合同已经归档。"))
                _ = try store.capture(clip("上海项目的发票。"))
                try store.toggleFavorite(favorite.id)
                try require(store.search("合同", filter: .history).count == 2, "中文短词应找到相应内容")
                try require(store.search("上海 合同", filter: .history).map(\.id) == [favorite.id], "多个关键词应共同匹配")
                try require(store.search("合同", filter: .favorites).map(\.id) == [favorite.id], "收藏筛选应生效")
                try require(store.search("不存在的内容", filter: .history).isEmpty, "不存在的内容应返回空结果")
            }
            try run("重命名后重复复制与重启") {
                let folder = root.appendingPathComponent("rename")
                let store = try HistoryStore(directory: folder)
                let captured = clip("https://example.com/team", kind: .link, title: "example.com")
                let first = try store.capture(captured)
                try store.rename(first.id, title: "团队文档")
                let duplicate = try store.capture(captured)
                try require(duplicate.id == first.id && duplicate.title == "团队文档", "再次复制应保留自定义标题")
                try require(HistoryStore(directory: folder).items.first?.title == "团队文档", "重命名应持久化")
            }
            try run("数量、时间清理保留收藏") {
                let store = try HistoryStore(directory: root.appendingPathComponent("prune"))
                let captured = clip("长期保留的地址")
                let favorite = try store.capture(captured)
                try store.toggleFavorite(favorite.id)
                for text in ["临时笔记一", "临时笔记二", "临时笔记三"] { _ = try store.capture(clip(text)) }
                try store.prune(olderThan: .distantPast, maxItems: 2)
                try require(store.items.count == 2 && store.items.filter { !$0.isFavorite }.count == 1, "数量清理只应删除普通历史")
                try store.prune(olderThan: .distantFuture, maxItems: 0)
                try require(store.items.map(\.id) == [favorite.id], "过期和超额收藏应保留")
                try require(store.payload(for: favorite.id) == captured.entries, "收藏载荷应保留")
            }
            try run("清空普通历史与删除持久化") {
                let folder = root.appendingPathComponent("delete")
                let store = try HistoryStore(directory: folder)
                let favorite = try store.capture(clip("收藏内容"))
                try store.toggleFavorite(favorite.id)
                _ = try store.capture(clip("普通历史"))
                try store.clearUnfavorited()
                try require(store.items.map(\.id) == [favorite.id], "清空历史应保留收藏")
                try store.remove(favorite.id)
                try require(store.items.isEmpty && HistoryStore(directory: folder).items.isEmpty, "删除应持久化")
            }
            try run("机密与临时剪贴板不采集") {
                let board = newBoard()
                defer { board.releaseGlobally() }
                for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"] {
                    board.clearContents()
                    let item = NSPasteboardItem()
                    item.setString("这段内容不应进入历史", forType: .string)
                    item.setData(Data([1]), forType: NSPasteboard.PasteboardType(marker))
                    try require(board.writeObjects([item]), "测试专用板应可写入")
                    try require(ClipboardMonitor.snapshot(from: board, sourceName: "测试应用", sourceBundleID: nil) == nil, "隐私标记应阻止采集")
                }
            }
            try run("纯文本与链接类型采集") {
                let board = newBoard()
                defer { board.releaseGlobally() }
                board.clearContents()
                try require(board.setString("中文短句\n第二行", forType: .string), "测试专用板应可写入文本")
                guard let plain = try ClipboardMonitor.snapshot(from: board, sourceName: "文本编辑", sourceBundleID: "com.apple.TextEdit") else { throw VerificationFailure(check: "纯文本应可采集") }
                try require(plain.kind == .text && plain.text == "中文短句\n第二行" && plain.sourceBundleID == "com.apple.TextEdit", "纯文本摘要和来源应正确")
                board.clearContents()
                try require(board.setString("https://example.com/document", forType: .URL), "测试专用板应可写入链接")
                guard let link = try ClipboardMonitor.snapshot(from: board, sourceName: "浏览器", sourceBundleID: nil) else { throw VerificationFailure(check: "链接应可采集") }
                try require(link.kind == .link && link.text.contains("example.com"), "URL 类型应识别为链接")
                try require(link.entries.flatMap(\.representations).contains { $0.type == NSPasteboard.PasteboardType.URL.rawValue }, "URL 原始格式应保留")
            }
            try run("多项目原始格式回写") {
                let board = newBoard()
                defer { board.releaseGlobally() }
                let expected = richEntries()
                try PasteService().write(expected, plainText: nil, to: board)
                guard let actual = board.pasteboardItems else { throw VerificationFailure(check: "应有回写项目") }
                try require(actual.count == expected.count, "回写项目数应保持")
                for (actualItem, expectedItem) in zip(actual, expected) {
                    for representation in expectedItem.representations {
                        try require(actualItem.data(forType: NSPasteboard.PasteboardType(representation.type)) == representation.data, "回写格式和字节应保持")
                    }
                }
            }
            try run("纯文本回写去除富文本格式") {
                let board = newBoard()
                defer { board.releaseGlobally() }
                let service = PasteService()
                try service.write(richEntries(), plainText: nil, to: board)
                try service.write(richEntries(), plainText: "纯文本\n保留换行", to: board)
                guard let items = board.pasteboardItems else { throw VerificationFailure(check: "应有纯文本回写项目") }
                try require(items.count == 1 && items.first?.string(forType: .string) == "纯文本\n保留换行", "纯文本回写内容应正确")
                try require(items.first?.data(forType: .rtf) == nil && items.first?.data(forType: .URL) == nil, "纯文本回写不应保留旧格式")
            }
            try run("长文本纯文本回写不截断") {
                let board = newBoard()
                defer { board.releaseGlobally() }
                let text = String(repeating: "长文本测试段落。", count: 20_000) + "末尾标记"
                board.clearContents()
                try require(board.setString(text, forType: .string), "测试专用板应可写入长文本")
                guard let captured = try ClipboardMonitor.snapshot(from: board, sourceName: "测试应用", sourceBundleID: nil),
                      let fullText = ClipboardMonitor.fullText(from: captured.entries) else { throw VerificationFailure(check: "长文本应可提取") }
                try require(captured.text.count < text.count && fullText == text, "截短摘要不应影响完整文本提取")
                let store = try HistoryStore(directory: root.appendingPathComponent("long-text"))
                let saved = try store.capture(captured)
                let payload = try store.payload(for: saved.id)
                try PasteService().write(payload, plainText: ClipboardMonitor.fullText(from: payload), to: board)
                try require(board.string(forType: .string) == text, "纯文本粘贴应完整回写长文本")
            }
            try run("可配置容量与启动不擅自清理") {
                let folder = root.appendingPathComponent("capacity")
                let store = try HistoryStore(directory: folder)
                store.maximumItems = 1_005
                for index in 0..<1_002 { _ = try store.capture(clip("容量测试 \(index)")) }
                try require(store.items.count == 1_002, "设置超过 1000 的容量应生效")
                let reopened = try HistoryStore(directory: folder)
                try require(reopened.items.count == 1_002, "启动不应先按默认上限清理")
                reopened.maximumItems = 1_010
                _ = try reopened.capture(clip("容量测试新增"))
                try require(reopened.items.count == 1_003, "重新配置后采集应保留已有条目")
                reopened.maximumItems = 3
                _ = try reopened.capture(clip("降低容量后新增"))
                try require(reopened.items.count == 3, "降低容量应在采集时生效")
            }
            try run("旧数据库自动升级保留历史和原始载荷") {
                let folder = root.appendingPathComponent("legacy-migration")
                let oldID = UUID()
                let original = clip("升级前的收藏内容", title: "旧版自定义标题")
                try seedLegacyDatabase(in: folder, id: oldID, captured: original)
                let upgraded = try HistoryStore(directory: folder)
                try require(upgraded.items.count == 1, "升级不应新增或删除旧历史")
                guard let retained = upgraded.items.first else { throw VerificationFailure(check: "升级应保留旧条目") }
                try require(retained.id == oldID && retained.title == original.title && retained.text == original.text && retained.isFavorite, "升级应保留旧内容、标题与收藏状态")
                try require(retained.createdAt.timeIntervalSince1970 == 1_700_000_000, "升级应保留原始时间")
                try require(upgraded.payload(for: oldID) == original.entries, "升级应保留旧载荷")
                let board = try upgraded.createBoard(name: "升级后分类")
                try upgraded.assignToBoard(oldID, boardID: board.id)
                let reopened = try HistoryStore(directory: folder)
                try require(reopened.boardMembership[oldID] == board.id && reopened.payload(for: oldID) == original.entries, "升级后分类和旧载荷应可共同持久化")
            }
            try run("收藏分类创建、重命名与重启持久化") {
                let folder = root.appendingPathComponent("boards")
                let store = try HistoryStore(directory: folder)
                let first = try store.createBoard(name: "项目资料")
                let second = try store.createBoard(name: "常用回复")
                try require(first.id != second.id && store.boards.count == 2, "分类应独立创建")
                try store.renameBoard(first.id, name: "客户资料")
                let reopened = try HistoryStore(directory: folder)
                try require(reopened.boards.count == 2 && reopened.boards.first { $0.id == first.id }?.name == "客户资料", "改名后应沿用分类标识并持久化")
                try require(reopened.boards.first { $0.id == second.id }?.name == "常用回复", "修改分类不应影响其他分类")
            }
            try run("分类分配、移动及取消收藏解除归属") {
                let folder = root.appendingPathComponent("membership")
                let store = try HistoryStore(directory: folder)
                let first = try store.createBoard(name: "第一类")
                let second = try store.createBoard(name: "第二类")
                let captured = clip("用于分类的剪贴板内容")
                let item = try store.capture(captured)
                try store.assignToBoard(item.id, boardID: first.id)
                try require(store.items.first { $0.id == item.id }?.isFavorite == true && store.boardMembership[item.id] == first.id, "归类应自动收藏")
                _ = try store.capture(captured)
                try require(store.boardMembership[item.id] == first.id, "重复采集应保留分类")
                try store.assignToBoard(item.id, boardID: second.id)
                try require(store.boardMembership[item.id] == second.id && store.search("", filter: .favorites, boardID: first.id).isEmpty, "移动分类应解除旧归属")
                try require(store.search("分类 剪贴板", filter: .favorites, boardID: second.id).map(\.id) == [item.id], "应可在指定分类搜索")
                try store.assignToBoard(item.id, boardID: nil)
                try require(store.boardMembership[item.id] == nil && store.items.first { $0.id == item.id }?.isFavorite == true, "移出分类仍应保留收藏")
                try store.assignToBoard(item.id, boardID: first.id)
                try store.toggleFavorite(item.id)
                try require(store.boardMembership[item.id] == nil && store.items.first { $0.id == item.id }?.isFavorite == false, "取消收藏应解除分类归属")
                let reopened = try HistoryStore(directory: folder)
                try require(reopened.boardMembership[item.id] == nil && reopened.items.first { $0.id == item.id }?.isFavorite == false, "取消收藏后的归属状态应持久化")
            }
            try run("删除分类保留内容及收藏") {
                let folder = root.appendingPathComponent("remove-board")
                let store = try HistoryStore(directory: folder)
                let board = try store.createBoard(name: "待移除分类")
                let captured = clip("删除分类时保留的内容")
                let item = try store.capture(captured)
                try store.assignToBoard(item.id, boardID: board.id)
                try store.removeBoard(board.id)
                try require(!store.boards.contains { $0.id == board.id } && store.boardMembership[item.id] == nil, "删除分类应清理归属")
                try require(store.items.first { $0.id == item.id }?.isFavorite == true && store.payload(for: item.id) == captured.entries, "删除分类应保留内容、收藏与载荷")
                let reopened = try HistoryStore(directory: folder)
                try require(!reopened.boards.contains { $0.id == board.id } && reopened.items.first { $0.id == item.id }?.isFavorite == true, "删除分类后的内容状态应持久化")
            }
            try run("分类中的内容不被历史剪枝清理") {
                let folder = root.appendingPathComponent("board-retention")
                let store = try HistoryStore(directory: folder)
                let board = try store.createBoard(name: "长期资料")
                let captured = clip("已经分类的长期资料")
                let item = try store.capture(captured)
                try store.assignToBoard(item.id, boardID: board.id)
                _ = try store.capture(clip("临时普通历史"))
                try store.prune(olderThan: .distantFuture, maxItems: 0)
                try require(store.items.map(\.id) == [item.id] && store.boardMembership[item.id] == board.id, "超期超额清理应保留分类条目及归属")
                try require(store.payload(for: item.id) == captured.entries, "分类保护应包含原始载荷")
                let reopened = try HistoryStore(directory: folder)
                try require(reopened.search("长期", filter: .favorites, boardID: board.id).map(\.id) == [item.id], "清理后分类应可恢复并搜索")
            }
            try run("千条大摘要搜索结果与耗时") {
                let store = try HistoryStore(directory: root.appendingPathComponent("search-performance"))
                store.maximumItems = 1_100
                let repeated = String(repeating: "常用资料 ", count: 250)
                for index in 0..<1_000 {
                    let category = index.isMultiple(of: 2) ? "上海 合同" : "北京 发票"
                    _ = try store.capture(clip("\(index) \(category) \(repeated)"))
                }
                let started = ProcessInfo.processInfo.systemUptime
                for _ in 0..<5 {
                    try require(store.search("合同", filter: .history).count == 500, "大摘要中的中文检索应准确")
                    try require(store.search("上海 合同", filter: .history).count == 500, "大摘要多关键词检索应准确")
                    try require(store.search("绝不存在的词", filter: .history).isEmpty, "大摘要无结果检索应准确")
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                try require(elapsed < 20, "千条大摘要的重复检索不应出现明显性能退化")
                print("搜索测量：1000 条、15 次查询，\(String(format: "%.3f", elapsed)) 秒。")
            }
            try run("0.3 数据库升级后补充识别且不设过期") {
                let folder = root.appendingPathComponent("legacy-detail")
                let id = UUID()
                try seedLegacyDatabase(in: folder, id: id, captured: clip("sk-proj-abcdefghijklmnopqrstuvwxyz012345"))
                let store = try HistoryStore(directory: folder)
                try require(store.items.first?.detail == .sensitive, "旧记录应补充识别为敏感内容")
                try require(store.items.first?.expiresAt == nil, "旧记录不应被追加过期时间")
                let reopened = try HistoryStore(directory: folder)
                try require(reopened.items.first?.detail == .sensitive && reopened.items.first?.ocrText == nil, "识别结果应写回并可重读")
            }
            try run("敏感内容与验证码到期清理，收藏保留") {
                let store = try HistoryStore(directory: root.appendingPathComponent("expiry"))
                store.sensitiveLifetime = 600
                let secret = try store.capture(clip("ghp_" + String(repeating: "a1B2", count: 9)))
                let code = try store.capture(clip("您的验证码是 482913"))
                let kept = try store.capture(clip("AKIAIOSFODNN7EXAMPLE"))
                let plain = try store.capture(clip("普通笔记"))
                try require(secret.detail == .sensitive && secret.expiresAt != nil, "密钥应标记敏感并设置过期")
                try require(code.detail == .otp && code.expiresAt != nil, "验证码应设置过期")
                try require(plain.expiresAt == nil, "普通内容不应过期")
                try store.toggleFavorite(kept.id)
                try store.prune(olderThan: .distantPast, maxItems: 1000, now: Date().addingTimeInterval(400))
                try require(!store.items.contains { $0.id == code.id }, "验证码 5 分钟后应删除")
                try require(store.items.contains { $0.id == secret.id }, "敏感内容 10 分钟内应保留")
                try store.prune(olderThan: .distantPast, maxItems: 1000, now: Date().addingTimeInterval(700))
                try require(!store.items.contains { $0.id == secret.id }, "敏感内容到期应删除")
                try require(store.items.contains { $0.id == kept.id } && store.items.contains { $0.id == plain.id }, "收藏和普通内容应保留")
                let reopened = try HistoryStore(directory: root.appendingPathComponent("expiry"))
                try require(reopened.items.count == 2, "清理结果应持久化")
            }
            try run("批量删除与批量收藏到分类") {
                let folder = root.appendingPathComponent("batch")
                let store = try HistoryStore(directory: folder)
                let items = try (1...5).map { try store.capture(clip("批量第 \($0) 条")) }
                let board = try store.createBoard(name: "表单")
                try store.favorite([items[0].id, items[1].id], boardID: board.id)
                try store.remove(Set([items[2].id, items[3].id]))
                let reopened = try HistoryStore(directory: folder)
                try require(reopened.items.count == 3, "批量删除应移除两条")
                try require(reopened.boardMembership[items[0].id] == board.id && reopened.boardMembership[items[1].id] == board.id, "批量收藏应写入分类")
                try require(reopened.items.filter(\.isFavorite).count == 2, "批量收藏应标记收藏")
            }
            try run("图片文字和链接标题可搜索") {
                let folder = root.appendingPathComponent("enrich")
                let store = try HistoryStore(directory: folder)
                let image = try store.capture(CapturedClip(entries: [ClipboardEntry(representations: [
                    ClipboardRepresentation(type: "public.png", data: Data([1, 2, 3]))])], kind: .image,
                    title: "图片", text: "", sourceName: "测试应用", sourceBundleID: nil))
                let link = try store.capture(clip("https://example.com/a", kind: .link))
                try store.setOCRText(image.id, text: "发票号码 20261019")
                try store.setLinkPreview(link.id, title: "示例站点首页", iconPNG: Data([9, 9]))
                let reopened = try HistoryStore(directory: folder)
                try require(reopened.search("发票号码", filter: .history).map(\.id) == [image.id], "应能搜到图片中的文字")
                try require(reopened.search("示例站点", filter: .history).map(\.id) == [link.id], "应能搜到链接标题")
                try require(reopened.linkIcon(for: link.id) == Data([9, 9]), "链接图标应持久化")
            }
            try run("编辑保存：内容、自动标题、收藏与重启持久化") {
                let folder = root.appendingPathComponent("edit")
                let store = try HistoryStore(directory: folder)
                let item = try store.capture(clip("第一行\n第二行", title: "第一行"))
                try store.toggleFavorite(item.id)
                let rich = NSMutableAttributedString(string: "新的第一行\n正文", attributes: [.font: NSFont.systemFont(ofSize: 14)])
                rich.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: NSRange(location: 0, length: 2))
                let entries = ItemEditorController.entries(for: rich)
                try require(entries.first?.representations.map(\.type) == [NSPasteboard.PasteboardType.rtf.rawValue, NSPasteboard.PasteboardType.string.rawValue],
                            "有格式时应同时保存 RTF 与纯文本")
                try store.updateContent(item.id, entries: entries, text: rich.string)
                let reopened = try HistoryStore(directory: folder)
                let saved = reopened.items.first { $0.id == item.id }
                try require(saved?.text == "新的第一行\n正文" && saved?.title == "新的第一行" && saved?.isFavorite == true, "编辑后应更新正文与自动标题并保留收藏")
                let loaded = ItemEditorController.attributedContent(from: try reopened.payload(for: item.id), fallback: "")
                try require(ItemEditorController.hasFormatting(loaded) && loaded.string == rich.string, "重新打开应保留加粗格式")
                let plain = ItemEditorController.entries(for: NSAttributedString(string: "纯文本", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
                try require(plain.first?.representations.map(\.type) == [NSPasteboard.PasteboardType.string.rawValue], "无格式时只保存纯文本")
            }
            try run("编辑保留重命名标题，改成与其他条目相同也不冲突") {
                let store = try HistoryStore(directory: root.appendingPathComponent("edit-collide"))
                let other = try store.capture(clip("已有内容"))
                let item = try store.capture(clip("原内容"))
                try store.rename(item.id, title: "我的标题")
                try store.updateContent(item.id, entries: clip("已有内容").entries, text: "已有内容")
                try require(store.items.count == 2 && store.items.first { $0.id == item.id }?.title == "我的标题", "重命名标题应保留且两条并存")
                let again = try store.capture(clip("已有内容"))
                try require(again.id == other.id, "再次复制相同内容应刷新原条目")
            }
            try run("创建副本独立存在且原条目不受影响") {
                let folder = root.appendingPathComponent("duplicate")
                let store = try HistoryStore(directory: folder)
                let item = try store.capture(clip("要复制的内容"))
                try store.toggleFavorite(item.id)
                let copy = try store.duplicate(item.id)
                try require(copy.id != item.id && !copy.isFavorite && copy.title == "要复制的内容 副本", "副本应是新的未收藏条目")
                try require(store.items.first?.id == copy.id && store.items.count == 2, "副本应排在最前")
                try store.updateContent(copy.id, entries: clip("改过的副本").entries, text: "改过的副本")
                let reopened = try HistoryStore(directory: folder)
                try require(reopened.payload(for: item.id) == clip("要复制的内容").entries
                            && reopened.items.first { $0.id == item.id }?.isFavorite == true, "编辑副本不应影响原条目")
                try require(reopened.items.first { $0.id == copy.id }?.text == "改过的副本", "副本修改应持久化")
            }
            try run("后台写入新条目：并入、去重转主线程、清空后不复现") {
                let folder = root.appendingPathComponent("capture-writer")
                let store = try HistoryStore(directory: folder)
                let earlier = try store.capture(clip("早先的内容"))
                let prepared = try HistoryStore.prepare(clip("后台写入的合同条款"))
                guard case .written(let written) = store.captureWriter.write(prepared, sensitiveLifetime: 600) else {
                    throw VerificationFailure(check: "新内容应在后台写入")
                }
                let adopted = try store.adoptCapture(written)
                try require(adopted?.id == written.item.id && store.items.first?.id == written.item.id
                            && store.items.count == 2, "后台写入的条目应排在最前")
                try require(store.search("合同", filter: .history).map(\.id) == [written.item.id], "后台写入的条目应可搜索")
                try require(store.payload(for: written.item.id) == clip("后台写入的合同条款").entries, "后台写入的载荷应完整")
                try require(try store.adoptCapture(written) == nil && store.items.count == 2, "同一条目不应重复并入")

                let again = try HistoryStore.prepare(clip("早先的内容"))
                guard case .needsMainThread = store.captureWriter.write(again, sensitiveLifetime: 600) else {
                    throw VerificationFailure(check: "已存在的内容应交回主线程")
                }
                let refreshed = try store.capture(again)
                try require(refreshed.id == earlier.id && store.items.count == 2 && store.items.first?.id == earlier.id,
                            "重复内容应更新原条目而不新增")

                let secret = try HistoryStore.prepare(clip("sk-" + String(repeating: "A", count: 32)))
                guard case .written(let secretRow) = store.captureWriter.write(secret, sensitiveLifetime: 600) else {
                    throw VerificationFailure(check: "敏感内容应在后台写入")
                }
                try require(secretRow.item.detail == .sensitive && secretRow.item.expiresAt != nil, "后台写入应保留敏感到期时间")
                let late = try HistoryStore.prepare(clip("清空前写入的内容"))
                guard case .written(let lateRow) = store.captureWriter.write(late, sensitiveLifetime: 600) else {
                    throw VerificationFailure(check: "清空前应可写入")
                }
                try store.clearUnfavorited()
                try require(try store.adoptCapture(lateRow) == nil && store.items.isEmpty, "清空后不应再出现已删除的写入")
                let reopened = try HistoryStore(directory: folder)
                try require(reopened.items.isEmpty, "重开后也不应有已清空的条目")
            }
            try run("排除应用按复制时的应用判定，切换时先检查剪贴板") {
                let store = try HistoryStore(directory: root.appendingPathComponent("exclusion"))
                let board = newBoard()
                defer { board.releaseGlobally() }
                let excluded = ClipboardMonitor.Source(name: "密码应用", bundleID: "test.excluded")
                let normal = ClipboardMonitor.Source(name: "备忘录", bundleID: "test.normal")
                var front: ClipboardMonitor.Source? = excluded
                let monitor = ClipboardMonitor(store: store, pasteboard: board, frontmost: { front }) { }
                monitor.excludedBundleIDs = ["test.excluded"]
                monitor.applicationDidActivate(excluded)
                // Copied in the excluded app, then switched to a normal app before the next timer tick.
                write("排除应用里的口令", to: board)
                front = normal
                monitor.applicationDidActivate(normal)
                settle()
                try require(store.items.isEmpty, "排除应用复制后切走，不应记录")
                // An ordinary copy in the normal app is recorded under that app.
                write("普通应用里的内容", to: board)
                monitor.poll()
                try require(waitUntil { store.items.count == 1 } && store.items.first?.sourceBundleID == "test.normal",
                            "普通应用的复制应记录并归属该应用")
                // Copied in the normal app, then switched to the excluded app: still the normal app's copy.
                write("切走前复制的内容", to: board)
                front = excluded
                monitor.applicationDidActivate(excluded)
                try require(waitUntil { store.items.count == 2 } && store.items.first?.text == "切走前复制的内容"
                            && store.items.first?.sourceBundleID == "test.normal", "切换前的复制应按原应用记录")
                // Copied in the excluded app; the timer runs before the switch notification arrives.
                write("排除应用里的第二条", to: board)
                front = normal
                monitor.poll()
                monitor.applicationDidActivate(normal)
                settle()
                try require(store.items.count == 2, "切换通知晚于轮询时，排除应用的复制也不应记录")
                // Paused: nothing is recorded, and resuming does not pick up what was copied meanwhile.
                monitor.paused = true
                write("暂停期间的内容", to: board)
                monitor.poll()
                monitor.paused = false
                monitor.poll()
                settle()
                try require(store.items.count == 2, "暂停期间的复制不应补录")
            }
            try run("敏感内容按完整载荷判定，图片文字也会到期删除") {
                let store = try HistoryStore(directory: root.appendingPathComponent("secrets"))
                let secret = "sk-" + String(repeating: "A", count: 32)
                @MainActor func captured(_ representations: [(NSPasteboard.PasteboardType, String)]) throws -> ClipItem {
                    let entries = [ClipboardEntry(representations: representations.map {
                        ClipboardRepresentation(type: $0.0.rawValue, data: Data($0.1.utf8))
                    })]
                    guard let clip = ClipboardMonitor.clip(from: entries, sourceName: "测试应用", sourceBundleID: nil) else {
                        throw VerificationFailure(check: "应能解析合成剪贴板内容")
                    }
                    return try store.capture(clip)
                }
                let longText = try captured([(.string, String(repeating: "普", count: 131_072) + "\n" + secret)])
                try require(longText.detail == .sensitive && longText.expiresAt != nil, "摘要截断之外的密钥也应识别")
                let htmlOnly = try captured([(.string, "普通便笺"), (.html, "<p>普通便笺</p><!-- \(secret) -->")])
                try require(htmlOnly.detail == .sensitive, "备用 HTML 中的密钥也应识别")
                let link = try captured([(.string, "https://example.invalid/reset?token=\(secret)")])
                try require(link.kind == .link && link.detail == .sensitive && link.expiresAt != nil, "带密钥的链接应按敏感内容处理")
                let image = try store.capture(CapturedClip(
                    entries: [ClipboardEntry(representations: [ClipboardRepresentation(type: "public.png", data: Data([1, 2, 3]))])],
                    kind: .image, title: "图片", text: "", sourceName: "测试应用", sourceBundleID: nil))
                let now = Date()
                try store.setOCRText(image.id, text: "截图里的密钥 \(secret)", now: now)
                let recognized = store.items.first { $0.id == image.id }
                try require(recognized?.detail == .sensitive && recognized?.expiresAt != nil, "图片文字中的密钥应让图片按敏感内容到期")
                let plain = try store.capture(clip("普通内容"))
                try store.prune(olderThan: .distantPast, maxItems: 1_000, now: now.addingTimeInterval(601))
                try require(store.items.map(\.id) == [plain.id], "到期后敏感内容（含链接与图片）应全部删除")
                let reopened = try HistoryStore(directory: root.appendingPathComponent("secrets"))
                try require(reopened.items.map(\.id) == [plain.id], "删除应持久化")
            }
            try run("拼音、首字母搜索与搜索语法") {
                let store = try HistoryStore(directory: root.appendingPathComponent("pinyin"))
                let minutes = try store.capture(clip("周五会议纪要：确认报价"))
                let report = try store.capture(clip("季度报告初稿"))
                try require(store.search("huiyi", filter: .history).map(\.id) == [minutes.id], "全拼应找到中文")
                try require(store.search("hyjy", filter: .history).map(\.id) == [minutes.id], "首字母应找到中文")
                try require(store.search("jdbg", filter: .history).map(\.id) == [report.id], "首字母应找到另一条")
                try require(store.search("hyjy baojia", filter: .history).map(\.id) == [minutes.id], "拼音关键词可组合")
                try require(store.search("bg", filter: .history).map(\.id) == [report.id], "首字母不跨条目误配")
                let reopened = try HistoryStore(directory: root.appendingPathComponent("pinyin"))
                try require(reopened.search("baojia", filter: .history).map(\.id) == [minutes.id], "重启后台建索引后拼音仍可用")

                let query = SearchQuery.parse("合同 app:微信 type:图片 类型：代码 date:今天 is:收藏 http://a.b/c")
                try require(query.text == "合同 http://a.b/c" && query.sources == ["微信"] && query.kinds == [.image]
                            && query.details == [.code] && query.date == .today && query.favoritesOnly, "搜索语法应拆出筛选条件")
                try require(SearchQuery.parse("type:图 报价").text == "报价" && !SearchQuery.parse("type:图").hasFilters,
                            "输入到一半的筛选不应当作关键词")
                var item = minutes
                item.sourceName = "微信"; item.isFavorite = true
                try require(SearchQuery.parse("app:微信 is:收藏 date:今天").matches(item), "满足条件的条目应保留")
                try require(!SearchQuery.parse("type:图片").matches(item) && !SearchQuery.parse("app:飞书").matches(item),
                            "不满足条件的条目应排除")
            }
            try run("收藏导出与导入：分类、去重与重复导入") {
                let source = try HistoryStore(directory: root.appendingPathComponent("backup-source"))
                let work = try source.createBoard(name: "工作")
                let filed = try source.capture(CapturedClip(entries: richEntries(), kind: .text, title: "报价单", text: "带格式的文本",
                                                            sourceName: "测试应用", sourceBundleID: nil))
                try source.assignToBoard(filed.id, boardID: work.id)
                let loose = try source.capture(clip("常用回复：收到，马上处理"))
                try source.toggleFavorite(loose.id)
                _ = try source.capture(clip("未收藏的历史"))
                let export = try source.exportFavorites()
                try require(export.count == 2 && export.sensitive == 0, "应只导出收藏")

                let target = try HistoryStore(directory: root.appendingPathComponent("backup-target"))
                let existing = try target.capture(clip("常用回复：收到，马上处理"))
                _ = try target.createBoard(name: "工作")
                let result = try target.importFavorites(export.data)
                try require(result == .init(added: 1, updated: 1, boardsCreated: 0), "已有内容应设为收藏，分类按名称合并")
                try require(target.items.count == 2 && target.items.allSatisfy(\.isFavorite), "导入后两条都应是收藏")
                try require(target.items.contains { $0.id == existing.id && $0.isFavorite }, "已有内容应沿用原条目")
                guard let imported = target.items.first(where: { $0.title == "报价单" }),
                      let board = target.boards.first(where: { $0.name == "工作" }) else {
                    throw VerificationFailure(check: "导入的内容和分类应存在")
                }
                try require(target.boardMembership[imported.id] == board.id && target.boards.count == 1, "导入的内容应归入同名分类")
                try require(target.payload(for: imported.id) == richEntries(), "导入后的载荷应与原始字节一致")
                let again = try target.importFavorites(export.data)
                try require(again == .init(added: 0, updated: 2, boardsCreated: 0) && target.items.count == 2, "重复导入不应新增")
                let reopened = try HistoryStore(directory: root.appendingPathComponent("backup-target"))
                try require(reopened.items.count == 2 && reopened.boardMembership[imported.id] != nil, "导入结果应持久化")
                var invalid = false
                do { try target.importFavorites(Data("不是备份".utf8)) } catch { invalid = true }
                try require(invalid && target.items.count == 2, "无效文件应报错且不改动数据")
            }
            print("核心验证通过：\(completed) 项。")
        } catch let error as VerificationFailure {
            print("FAIL \(error.check)")
            try? FileManager.default.removeItem(at: root)
            Darwin.exit(1)
        } catch {
            print("FAIL 核心验证遇到运行错误。")
            try? FileManager.default.removeItem(at: root)
            Darwin.exit(1)
        }
    }
}
