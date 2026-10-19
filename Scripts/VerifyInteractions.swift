import AppKit
import SwiftUI

/// Minimal controller seam for the real native destination and card views. Mutations
/// use the real HistoryStore; clipboard, preview and destructive UI actions are counters.
@MainActor
final class AppController {
    let store: HistoryStore
    var selectedID: UUID?
    var selectedBoardID: UUID?
    var multiSelection: [UUID] = []
    var statusText = ""
    var moveCount = 0
    var selectCount = 0
    var useCount = 0
    var menuActionCount = 0
    var lastError: Error?

    init(store: HistoryStore) { self.store = store }
    func select(_ id: UUID) { selectedID = id; selectCount += 1 }
    var multiSelectCount = 0
    func toggleMultiSelect(_ id: UUID) { multiSelectCount += 1 }
    func extendSelection(to id: UUID) { multiSelectCount += 1 }
    func selectBoard(_ id: UUID?) { selectedBoardID = id }
    func moveItem(_ id: UUID, to boardID: UUID?) {
        moveCount += 1
        do { try store.assignToBoard(id, boardID: boardID) }
        catch { lastError = error }
    }
    func useSelected(plainText: Bool = false, copyOnly: Bool = false) { useCount += 1 }
    func showItemPreview() { menuActionCount += 1 }
    func toggleFavorite(_ id: UUID) { menuActionCount += 1 }
    func renameItem(_ id: UUID) { menuActionCount += 1 }
    func deleteItem(_ id: UUID) { menuActionCount += 1 }
    func renameBoard(_ board: FavoriteBoard) { menuActionCount += 1 }
    func canEdit(_ item: ClipItem) -> Bool { item.kind == .text }
    func editItem(_ id: UUID) { menuActionCount += 1 }
    func duplicateItem(_ id: UUID) { menuActionCount += 1 }
    func openableURLs(for item: ClipItem) -> [URL]? { nil }
    func openItem(_ id: UUID, with application: URL? = nil) { menuActionCount += 1 }
    func applications(toOpen item: ClipItem, limit: Int = 12) -> [URL] { [] }
    func revealItem(_ id: UUID) { menuActionCount += 1 }
    func shareItems(for item: ClipItem) -> [Any] { [] }
    func deleteBoard(_ board: FavoriteBoard) { menuActionCount += 1 }
    func transforms(for item: ClipItem) -> [TextTransform] { [] }
    func paste(_ id: UUID, as transform: TextTransform) { useCount += 1 }
    func canFetchLinkPreview(_ item: ClipItem) -> Bool { false }
    func fetchLinkPreview(_ id: UUID) { menuActionCount += 1 }
}

/// Implements the SDK protocol without starting a system drag or opening a window.
@MainActor
private final class TestDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(board: NSPasteboard) { draggingPasteboard = board }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}

/// Calls actual native handlers directly. This validates handler and hit-testing
/// behavior, not an end-to-end macOS drag gesture or paste into another application.
@main
@MainActor
struct VerifyInteractions {
    private struct Failure: Error { let check: String }
    private static let identifierType = NSPasteboard.PasteboardType("com.local.lightpaste.clip-id")

    private static func require(_ condition: @autoclosure () -> Bool, _ check: String) throws {
        guard condition() else { throw Failure(check: check) }
    }

    private static func writeIDs(_ strings: [String], to board: NSPasteboard) throws {
        let items = strings.map { string -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setData(Data(string.utf8), forType: identifierType)
            return item
        }
        board.clearContents()
        try require(board.writeObjects(items), "应可写入命名测试剪贴板")
    }

    private static func mouseEvent(clicks: Int, type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 50, y: 80),
                                             modifierFlags: [], timestamp: 1, windowNumber: 0,
                                             context: nil, eventNumber: clicks, clickCount: clicks, pressure: 1) else {
            throw Failure(check: "应可创建本地鼠标事件对象")
        }
        return event
    }

    static func main() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LightPasteInteractionsVerification-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("LightPasteInteractionsVerification-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        do {
            let store = try HistoryStore(directory: directory)
            let controller = AppController(store: store)
            let captured = CapturedClip(entries: [ClipboardEntry(representations: [
                ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("交互验证内容".utf8))
            ])], kind: .text, title: "交互验证", text: "交互验证内容", sourceName: "测试应用", sourceBundleID: nil)
            let item = try store.capture(captured)
            let favoriteBoard = try store.createBoard(name: "测试分类")
            let destination = NativeBoardInteractionView(frame: NSRect(x: 0, y: 0, width: 160, height: 40))
            destination.controller = controller
            destination.board = favoriteBoard
            let drag = TestDraggingInfo(board: pasteboard)

            try writeIDs([item.id.uuidString, item.id.uuidString, UUID().uuidString], to: pasteboard)
            try require(destination.draggingEntered(drag) == .copy && destination.prepareForDragOperation(drag), "有效条目应被分类目标接受")
            try require(destination.performDragOperation(drag), "原生目标应完成有效归类")
            try require(controller.moveCount == 1 && controller.lastError == nil, "重复 UUID 应只移动一次，无效记录应忽略")
            try require(store.boardMembership[item.id] == favoriteBoard.id && store.items.first { $0.id == item.id }?.isFavorite == true, "原生归类应保存分类并自动收藏")
            print("PASS 原生拖入处理去重、归类和收藏")

            try writeIDs(["invalid-uuid", UUID().uuidString], to: pasteboard)
            try require(destination.draggingEntered(drag).isEmpty && !destination.prepareForDragOperation(drag), "无效 UUID 不应显示为有效目标")
            try require(!destination.performDragOperation(drag) && controller.moveCount == 1, "无效 UUID 应拒绝且不修改历史")
            print("PASS 无效拖入数据拒绝")

            let removedBoard = try store.createBoard(name: "已删除分类")
            destination.board = removedBoard
            try store.removeBoard(removedBoard.id)
            try writeIDs([item.id.uuidString], to: pasteboard)
            try require(!destination.prepareForDragOperation(drag) && !destination.performDragOperation(drag), "已删除分类不应接受拖入")
            try require(controller.moveCount == 1 && store.boardMembership[item.id] == favoriteBoard.id, "已删除分类不应改变既有归属")
            print("PASS 已删除分类拒绝拖入")

            destination.board = nil
            try require(destination.performDragOperation(drag), "默认收藏应接受有效条目")
            try require(store.boardMembership[item.id] == nil && store.items.first { $0.id == item.id }?.isFavorite == true, "回到默认收藏应解除分类但保留收藏")
            print("PASS 默认收藏解除分类并保留收藏")

            let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
            let card = NativeCardInteractionView(frame: NSRect(x: 20, y: 30, width: 240, height: 260))
            container.addSubview(card)
            card.controller = controller
            card.item = item
            let star = container.convert(NSPoint(x: card.bounds.maxX - 10, y: card.bounds.minY + 10), from: card)
            let body = container.convert(NSPoint(x: card.bounds.midX, y: card.bounds.midY), from: card)
            let outside = container.convert(NSPoint(x: -10, y: -10), from: card)
            try require(card.hitTest(star) == nil, "卡片星标区域应穿透给收藏按钮")
            try require(card.hitTest(body) === card && card.hitTest(outside) == nil, "卡片主体应接收点击且边界外不截获")
            print("PASS 原生卡片星标穿透和主体命中")

            var selectionCallbacks = 0
            card.onSelect = { selectionCallbacks += 1 }
            card.mouseDown(with: try mouseEvent(clicks: 1))
            try require(controller.selectedID == item.id && controller.selectCount == 1 && controller.useCount == 0 && selectionCallbacks == 1,
                        "单击按下应立即选中且不触发粘贴")
            card.mouseDown(with: try mouseEvent(clicks: 2))
            try require(controller.selectCount == 2 && controller.useCount == 1 && selectionCallbacks == 2, "双击应选中并仅触发一次使用")
            print("PASS 原生卡片单击选中和双击使用")

            controller.multiSelection = [UUID(), item.id]
            let before = controller.selectCount
            card.mouseDown(with: try mouseEvent(clicks: 1))
            try require(controller.selectCount == before && controller.useCount == 1, "多选中的卡片按下时应保留多选，便于整组拖动")
            card.mouseUp(with: try mouseEvent(clicks: 1, type: .leftMouseUp))
            try require(controller.selectCount == before + 1 && controller.selectedID == item.id, "未拖动松开后应只选中该卡片")
            controller.multiSelection = []
            print("PASS 多选卡片按下保留选择、松开收为单选")

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 10))!
            let lateYesterday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 23, minute: 59))!
            let sixDaysAgo = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 0))!
            let sevenDaysAgo = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 23))!
            try require(DateFilter.all.range(now: now, calendar: calendar) == nil, "全部日期不限制")
            try require(DateFilter.today.range(now: now, calendar: calendar)!.contains(now)
                        && !DateFilter.today.range(now: now, calendar: calendar)!.contains(lateYesterday), "今天从当日零点开始")
            try require(DateFilter.yesterday.range(now: now, calendar: calendar)!.contains(lateYesterday)
                        && !DateFilter.yesterday.range(now: now, calendar: calendar)!.contains(now), "昨天只含前一自然日")
            try require(DateFilter.week.range(now: now, calendar: calendar)!.contains(sixDaysAgo)
                        && !DateFilter.week.range(now: now, calendar: calendar)!.contains(sevenDaysAgo), "最近 7 天含今天共 7 个自然日")
            print("PASS 日期筛选边界")
            print("原生交互处理验证通过：8 项；未启动系统拖放会话或发送系统事件。")
        } catch let error as Failure {
            print("FAIL \(error.check)")
            try? FileManager.default.removeItem(at: directory)
            pasteboard.releaseGlobally()
            Darwin.exit(1)
        } catch {
            print("FAIL 原生交互验证遇到运行错误（\(String(reflecting: type(of: error)))）。")
            try? FileManager.default.removeItem(at: directory)
            pasteboard.releaseGlobally()
            Darwin.exit(1)
        }
    }
}
