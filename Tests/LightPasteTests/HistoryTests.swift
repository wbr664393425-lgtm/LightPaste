import AppKit
import XCTest
@testable import LightPaste

final class HistoryTests: XCTestCase {
    func testPlainTextPasteDoesNotUseTruncatedSearchSummary() async throws {
        let text = String(repeating: "正文很长仍须完整保留。", count: 20000)
        try await MainActor.run {
            let board = NSPasteboard(name: NSPasteboard.Name("LightPasteTests-\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            board.setString(text, forType: .string)
            let capture = try XCTUnwrap(ClipboardMonitor.snapshot(from: board, sourceName: "测试", sourceBundleID: nil))
            XCTAssertLessThan(capture.text.count, text.count)
            XCTAssertEqual(ClipboardMonitor.fullText(from: capture.entries), text)
        }
    }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LightPasteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func clip(_ text: String, kind: ClipKind = .text, title: String? = nil) -> CapturedClip {
        CapturedClip(
            entries: [ClipboardEntry(representations: [
                ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))
            ])],
            kind: kind,
            title: title ?? text,
            text: text,
            sourceName: "测试应用",
            sourceBundleID: "local.lightpaste.tests"
        )
    }

    func testDuplicateKeepsIdentityFavoriteAndPayloadAfterReopening() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let captured = clip("开会时要带的资料")
        try await MainActor.run {
            let store = try HistoryStore(directory: directory)
            let original = try store.capture(captured)
            try store.toggleFavorite(original.id)
            let duplicate = try store.capture(captured)
            XCTAssertEqual(duplicate.id, original.id)
            XCTAssertEqual(store.items.count, 1)
            XCTAssertTrue(duplicate.isFavorite)

            let reopened = try HistoryStore(directory: directory)
            XCTAssertEqual(reopened.items.count, 1)
            XCTAssertEqual(reopened.items.first?.id, original.id)
            XCTAssertEqual(reopened.items.first?.isFavorite, true)
            XCTAssertEqual(try reopened.payload(for: original.id), captured.entries)
        }
    }

    func testMultipleClipboardItemsAndFormatsSurvivePersistence() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = [
            ClipboardEntry(representations: [
                ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("带格式的文本".utf8)),
                ClipboardRepresentation(type: NSPasteboard.PasteboardType.rtf.rawValue, data: Data(#"{\rtf1\ansi formatted text}"#.utf8))
            ]),
            ClipboardEntry(representations: [
                ClipboardRepresentation(type: NSPasteboard.PasteboardType.URL.rawValue, data: Data("https://example.com/document".utf8)),
                ClipboardRepresentation(type: "local.lightpaste.tests.binary", data: Data([0, 255, 42, 0, 128]))
            ])
        ]
        let captured = CapturedClip(entries: entries, kind: .text, title: "多项目", text: "带格式的文本", sourceName: "测试应用", sourceBundleID: nil)
        try await MainActor.run {
            let store = try HistoryStore(directory: directory)
            let item = try store.capture(captured)
            let reopened = try HistoryStore(directory: directory)
            XCTAssertEqual(try reopened.payload(for: item.id), entries)
        }
    }

    func testChineseAndMultipleKeywordSearchWithFavoriteFilter() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = clip("上海项目的合同，请在周五确认。")
        let second = clip("北京项目的合同已经归档。")
        let third = clip("上海项目的发票。")
        try await MainActor.run {
            let store = try HistoryStore(directory: directory)
            let favorite = try store.capture(first)
            _ = try store.capture(second)
            _ = try store.capture(third)
            try store.toggleFavorite(favorite.id)
            XCTAssertEqual(store.search("合同", filter: .history).count, 2)
            XCTAssertEqual(store.search("上海 合同", filter: .history).map(\.id), [favorite.id])
            XCTAssertEqual(store.search("合同", filter: .favorites).map(\.id), [favorite.id])
            XCTAssertTrue(store.search("不存在的内容", filter: .history).isEmpty)
        }
    }

    func testRenamedTitleSurvivesDuplicateAndReopening() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let captured = clip("https://example.com/team", kind: .link, title: "example.com")
        try await MainActor.run {
            let store = try HistoryStore(directory: directory)
            let item = try store.capture(captured)
            try store.rename(item.id, title: "团队文档")
            let duplicate = try store.capture(captured)
            XCTAssertEqual(duplicate.id, item.id)
            XCTAssertEqual(duplicate.title, "团队文档")
            XCTAssertEqual(try HistoryStore(directory: directory).items.first?.title, "团队文档")
        }
    }

    func testPruningByCountAndAgePreservesFavorites() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let favoriteClip = clip("长期保留的地址")
        let otherClips = [clip("临时笔记一"), clip("临时笔记二"), clip("临时笔记三")]
        try await MainActor.run {
            let store = try HistoryStore(directory: directory)
            let favorite = try store.capture(favoriteClip)
            try store.toggleFavorite(favorite.id)
            for captured in otherClips { _ = try store.capture(captured) }
            try store.prune(olderThan: .distantPast, maxItems: 2)
            XCTAssertEqual(store.items.filter { !$0.isFavorite }.count, 1)
            XCTAssertEqual(store.items.first { $0.id == favorite.id }?.isFavorite, true)

            try store.prune(olderThan: .distantFuture, maxItems: 1)
            XCTAssertEqual(store.items.map(\.id), [favorite.id])
            XCTAssertEqual(try store.payload(for: favorite.id), favoriteClip.entries)
        }
    }

    func testClearHistoryAndRemoveFavoritePersist() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = clip("收藏内容")
        let second = clip("普通历史")
        try await MainActor.run {
            let store = try HistoryStore(directory: directory)
            let favorite = try store.capture(first)
            try store.toggleFavorite(favorite.id)
            _ = try store.capture(second)
            try store.clearUnfavorited()
            XCTAssertEqual(store.items.map(\.id), [favorite.id])
            try store.remove(favorite.id)
            XCTAssertTrue(store.items.isEmpty)
            XCTAssertTrue(try HistoryStore(directory: directory).items.isEmpty)
        }
    }

    func testSnapshotSkipsConcealedAndTransientContent() async throws {
        try await MainActor.run {
            let board = NSPasteboard(name: NSPasteboard.Name("LightPasteTests-\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"] {
                board.clearContents()
                let item = NSPasteboardItem()
                item.setString("这段内容不应进入历史", forType: .string)
                item.setData(Data([1]), forType: NSPasteboard.PasteboardType(marker))
                XCTAssertTrue(board.writeObjects([item]))
                XCTAssertNil(try ClipboardMonitor.snapshot(from: board, sourceName: "测试应用", sourceBundleID: nil))
            }
        }
    }

    func testSnapshotCapturesPlainTextAndURLFromDedicatedBoard() async throws {
        try await MainActor.run {
            let board = NSPasteboard(name: NSPasteboard.Name("LightPasteTests-\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            board.clearContents()
            XCTAssertTrue(board.setString("中文短句\n第二行", forType: .string))
            let plain = try XCTUnwrap(ClipboardMonitor.snapshot(from: board, sourceName: "文本编辑", sourceBundleID: "com.apple.TextEdit"))
            XCTAssertEqual(plain.kind, .text)
            XCTAssertEqual(plain.text, "中文短句\n第二行")
            XCTAssertEqual(plain.sourceBundleID, "com.apple.TextEdit")
            XCTAssertEqual(plain.entries.first?.representations.first { $0.type == NSPasteboard.PasteboardType.string.rawValue }?.data, Data("中文短句\n第二行".utf8))

            board.clearContents()
            XCTAssertTrue(board.setString("https://example.com/资料?q=clipboard", forType: .URL))
            let link = try XCTUnwrap(ClipboardMonitor.snapshot(from: board, sourceName: "浏览器", sourceBundleID: nil))
            XCTAssertEqual(link.kind, .link)
            XCTAssertTrue(link.text.contains("example.com"))
            XCTAssertTrue(link.entries.flatMap(\.representations).contains { $0.type == NSPasteboard.PasteboardType.URL.rawValue })
        }
    }

    func testPasteServiceWritesMultipleItemsWithOriginalFormats() async throws {
        let entries = [
            ClipboardEntry(representations: [
                ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("保留格式".utf8)),
                ClipboardRepresentation(type: NSPasteboard.PasteboardType.rtf.rawValue, data: Data(#"{\rtf1\ansi rich}"#.utf8))
            ]),
            ClipboardEntry(representations: [
                ClipboardRepresentation(type: NSPasteboard.PasteboardType.URL.rawValue, data: Data("https://example.com/second".utf8)),
                ClipboardRepresentation(type: "local.lightpaste.tests.binary", data: Data([0, 1, 255, 128]))
            ])
        ]
        try await MainActor.run {
            let board = NSPasteboard(name: NSPasteboard.Name("LightPasteTests-\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            try PasteService().write(entries, plainText: nil, to: board)
            let actualItems = try XCTUnwrap(board.pasteboardItems)
            XCTAssertEqual(actualItems.count, entries.count)
            for (actual, expected) in zip(actualItems, entries) {
                for representation in expected.representations {
                    XCTAssertEqual(actual.data(forType: NSPasteboard.PasteboardType(representation.type)), representation.data)
                }
            }
        }
    }

    func testPasteServicePlainTextReplacesRichFormatsOnDedicatedBoard() async throws {
        let rich = ClipboardEntry(representations: [
            ClipboardRepresentation(type: NSPasteboard.PasteboardType.rtf.rawValue, data: Data(#"{\rtf1\ansi rich}"#.utf8)),
            ClipboardRepresentation(type: "local.lightpaste.tests.binary", data: Data([1, 2, 3]))
        ])
        try await MainActor.run {
            let board = NSPasteboard(name: NSPasteboard.Name("LightPasteTests-\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            let service = PasteService()
            try service.write([rich], plainText: nil, to: board)
            try service.write([rich], plainText: "纯文本\n保留换行", to: board)
            let items = try XCTUnwrap(board.pasteboardItems)
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first?.string(forType: .string), "纯文本\n保留换行")
            XCTAssertNil(items.first?.data(forType: .rtf))
            XCTAssertNil(items.first?.data(forType: NSPasteboard.PasteboardType("local.lightpaste.tests.binary")))
        }
    }
}
