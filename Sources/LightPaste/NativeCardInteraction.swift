import AppKit
import SwiftUI

/// A transparent mouse surface; all card content and accessibility stay in SwiftUI.
@MainActor
struct NativeCardInteraction: NSViewRepresentable {
    let controller: AppController
    let item: ClipItem
    var onSelect: () -> Void = {}

    func makeNSView(context: Context) -> NativeCardInteractionView {
        let view = NativeCardInteractionView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NativeCardInteractionView, context: Context) {
        view.controller = controller
        view.item = item
        view.onSelect = onSelect
    }
    /// An overlay that covers its card; answering directly avoids an Auto Layout fitting pass per update.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeCardInteractionView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

@MainActor
final class NativeCardInteractionView: NSView, NSDraggingSource {
    weak var controller: AppController?
    var item: ClipItem?
    var onSelect: () -> Void = {}

    private var mouseDownPoint: NSPoint?
    private var pressedItem: ClipItem?
    private var dragStarted = false
    /// A plain click on a card inside the multi-selection keeps the selection until mouse-up,
    /// so dragging it moves the whole group; releasing without a drag selects just this card.
    private var collapseSelectionOnMouseUp = false
    /// Kept while the context menu is open; the share menu item does not retain its picker.
    private var sharePicker: NSSharingServicePicker?
    private static let identifierType = NSPasteboard.PasteboardType("com.local.lightpaste.clip-id")

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHidden, alphaValue > 0, bounds.contains(local) else { return nil }
        let favoriteButton = NSRect(x: max(bounds.minX, bounds.maxX - 36), y: bounds.minY,
                                    width: min(36, bounds.width), height: min(35, bounds.height))
        return favoriteButton.contains(local) ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showContextMenu(with: event)
            return
        }
        guard let controller, let item else { return }
        // ⌘-click and ⇧-click build a multi-selection; they never start a drag or a paste.
        let modifiers = event.modifierFlags.intersection([.command, .shift])
        if modifiers == .command || modifiers == .shift {
            resetMouseTracking()
            window?.makeFirstResponder(nil)
            if modifiers == .command { controller.toggleMultiSelect(item.id) } else { controller.extendSelection(to: item.id) }
            onSelect()
            return
        }
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        pressedItem = item
        dragStarted = false
        window?.makeFirstResponder(nil)
        if event.clickCount == 1, controller.multiSelection.contains(item.id) {
            collapseSelectionOnMouseUp = true
            return
        }
        controller.select(item.id)
        onSelect()
        if event.clickCount == 2 {
            mouseDownPoint = nil
            pressedItem = nil
            controller.useSelected()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let start = mouseDownPoint, let pressedItem, let controller else { return }
        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - start.x
        let dy = current.y - start.y
        guard dx * dx + dy * dy > 9 else { return }
        // Start once per mouse-down, including a failed payload read.
        dragStarted = true
        collapseSelectionOnMouseUp = false
        let ids = controller.multiSelection.contains(pressedItem.id) ? controller.multiSelection : [pressedItem.id]
        do {
            let entries = try ids.flatMap { id in try controller.store.payload(for: id).map { (id, $0) } }
            let draggingItems = entries.enumerated().map { index, pair in
                let (id, entry) = pair
                let pasteboardItem = NSPasteboardItem()
                for representation in entry.representations {
                    pasteboardItem.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
                }
                pasteboardItem.setData(Data(id.uuidString.utf8), forType: Self.identifierType)
                let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
                let fileName = pasteboardItem.string(forType: .fileURL).flatMap { URL(string: $0)?.lastPathComponent }
                let title = pressedItem.detail == .sensitive ? "敏感内容" : fileName ?? pressedItem.title
                let image = dragImage(for: pressedItem, title: ids.count > 1 ? "\(ids.count) 张卡片" : title,
                                      itemCount: entries.count)
                let offset = CGFloat(min(index, 5)) * 3
                let frame = NSRect(x: current.x - 18 + offset, y: current.y - 32 + offset,
                                   width: image.size.width, height: image.size.height)
                draggingItem.setDraggingFrame(frame, contents: image)
                return draggingItem
            }
            guard !draggingItems.isEmpty else {
                controller.statusText = "这条内容没有可拖出的数据。"
                NSSound.beep()
                return
            }
            let session = beginDraggingSession(with: draggingItems, event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
            session.draggingFormation = .pile
        } catch {
            controller.statusText = "无法拖动：\(error.localizedDescription)"
            NSSound.beep()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if collapseSelectionOnMouseUp, !dragStarted, let controller, let item {
            controller.select(item.id)
            onSelect()
        }
        resetMouseTracking()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        resetMouseTracking()
    }

    override func rightMouseDown(with event: NSEvent) { showContextMenu(with: event) }

    private func resetMouseTracking() {
        mouseDownPoint = nil
        pressedItem = nil
        dragStarted = false
        collapseSelectionOnMouseUp = false
    }

    private func showContextMenu(with event: NSEvent) {
        resetMouseTracking()
        guard let controller, let item else { return }
        controller.select(item.id)
        onSelect()
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(NativeCardMenuItem("粘贴") { [weak controller] in
            controller?.select(item.id); controller?.useSelected()
        })
        let plainText = NativeCardMenuItem("以纯文本粘贴") { [weak controller] in
            controller?.select(item.id); controller?.useSelected(plainText: true)
        }
        plainText.isEnabled = !item.text.isEmpty
        menu.addItem(plainText)
        let transforms = controller.transforms(for: item)
        if !transforms.isEmpty {
            let pasteAs = NSMenuItem(title: "粘贴为", action: nil, keyEquivalent: "")
            let transformMenu = NSMenu()
            transformMenu.autoenablesItems = false
            for transform in transforms {
                transformMenu.addItem(NativeCardMenuItem(transform.title) { [weak controller] in
                    controller?.paste(item.id, as: transform)
                })
            }
            pasteAs.submenu = transformMenu
            menu.addItem(pasteAs)
        }
        menu.addItem(NativeCardMenuItem("仅复制") { [weak controller] in
            controller?.select(item.id); controller?.useSelected(copyOnly: true)
        })
        menu.addItem(.separator())
        menu.addItem(NativeCardMenuItem("预览") { [weak controller] in
            controller?.select(item.id); controller?.showItemPreview()
        })
        menu.addItem(NativeCardMenuItem(item.isFavorite ? "取消收藏" : "收藏") { [weak controller] in
            controller?.toggleFavorite(item.id)
        })

        let category = NSMenuItem(title: "收藏到", action: nil, keyEquivalent: "")
        let categoryMenu = NSMenu()
        categoryMenu.autoenablesItems = false
        let currentBoard = controller.store.boardMembership[item.id]
        let defaultBoard = NativeCardMenuItem("默认收藏") { [weak controller] in
            controller?.moveItem(item.id, to: nil)
        }
        defaultBoard.state = item.isFavorite && currentBoard == nil ? .on : .off
        categoryMenu.addItem(defaultBoard)
        for board in controller.store.boards {
            let entry = NativeCardMenuItem(board.name) { [weak controller] in
                controller?.moveItem(item.id, to: board.id)
            }
            entry.state = currentBoard == board.id ? .on : .off
            categoryMenu.addItem(entry)
        }
        category.submenu = categoryMenu
        menu.addItem(category)
        menu.addItem(NativeCardMenuItem("重命名…") { [weak controller] in controller?.renameItem(item.id) })
        if controller.canEdit(item) {
            menu.addItem(NativeCardMenuItem("编辑…") { [weak controller] in controller?.editItem(item.id) })
        }
        menu.addItem(NativeCardMenuItem("创建副本") { [weak controller] in controller?.duplicateItem(item.id) })

        menu.addItem(.separator())
        if controller.canFetchLinkPreview(item) {
            let title = item.linkTitle?.isEmpty == false ? "刷新链接预览" : "获取链接预览"
            menu.addItem(NativeCardMenuItem(title) { [weak controller] in controller?.fetchLinkPreview(item.id) })
        }
        if controller.openableURLs(for: item) != nil {
            let open = NativeCardMenuItem(item.kind == .link ? "打开链接" : "打开") { [weak controller] in controller?.openItem(item.id) }
            open.keyEquivalent = "o"; open.keyEquivalentModifierMask = .command
            menu.addItem(open)
            let applications = controller.applications(toOpen: item)
            if !applications.isEmpty {
                let openWith = NSMenuItem(title: "打开方式", action: nil, keyEquivalent: "")
                let appsMenu = NSMenu()
                appsMenu.autoenablesItems = false
                for (index, app) in applications.enumerated() {
                    let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
                    let entry = NativeCardMenuItem(index == 0 ? "\(name)（默认）" : name) { [weak controller] in
                        controller?.openItem(item.id, with: app)
                    }
                    let icon = NSWorkspace.shared.icon(forFile: app.path)
                    icon.size = NSSize(width: 16, height: 16)
                    entry.image = icon
                    appsMenu.addItem(entry)
                    if index == 0 && applications.count > 1 { appsMenu.addItem(.separator()) }
                }
                openWith.submenu = appsMenu
                menu.addItem(openWith)
            }
            if item.kind == .files {
                menu.addItem(NativeCardMenuItem("在访达中显示") { [weak controller] in controller?.revealItem(item.id) })
            }
        }
        let shared = controller.shareItems(for: item)
        if !shared.isEmpty, item.detail != .sensitive {
            let picker = NSSharingServicePicker(items: shared)
            sharePicker = picker
            let share = picker.standardShareMenuItem
            share.title = "共享"
            menu.addItem(share)
        }
        menu.addItem(.separator())
        menu.addItem(NativeCardMenuItem("删除…") { [weak controller] in controller?.deleteItem(item.id) })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func dragImage(for item: ClipItem, title: String, itemCount: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 226, height: 64))
        image.lockFocus()
        defer { image.unlockFocus() }
        let frame = NSRect(origin: .zero, size: image.size).insetBy(dx: 1, dy: 1)
        let shape = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.withAlphaComponent(0.96).setFill()
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        let symbol = NSImage(systemSymbolName: item.kind.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
        symbol?.draw(in: NSRect(x: 14, y: 21, width: 23, height: 23))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: String(title.prefix(100)), attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]).draw(in: NSRect(x: 49, y: 31, width: 162, height: 17))
        let detail = itemCount > 1 ? "\(itemCount) 个项目" : item.kind.label
        NSAttributedString(string: detail, attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ]).draw(in: NSRect(x: 49, y: 15, width: 162, height: 14))
        return image
    }
}

@MainActor
private final class NativeCardMenuItem: NSMenuItem {
    private let callback: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        callback = action
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("NativeCardMenuItem is created programmatically") }

    @objc private func invoke() { callback() }
}
