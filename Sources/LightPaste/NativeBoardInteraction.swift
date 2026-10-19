import AppKit
import SwiftUI

/// Native drag destination for a favorite tab. Its SwiftUI button supplies visuals and accessibility.
@MainActor
struct NativeBoardInteraction: NSViewRepresentable {
    let controller: AppController
    let board: FavoriteBoard?
    @Binding var isTargeted: Bool

    func makeNSView(context: Context) -> NativeBoardInteractionView {
        let view = NativeBoardInteractionView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NativeBoardInteractionView, context: Context) {
        view.controller = controller
        view.board = board
        view.isTargeted = $isTargeted
    }
    /// An overlay that covers its tab; answering directly avoids an Auto Layout fitting pass per update.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeBoardInteractionView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

@MainActor
final class NativeBoardInteractionView: NSView {
    weak var controller: AppController?
    var board: FavoriteBoard?
    var isTargeted: Binding<Bool> = .constant(false)
    private static let identifierType = NSPasteboard.PasteboardType("com.local.lightpaste.clip-id")

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([Self.identifierType])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([Self.identifierType])
        setAccessibilityElement(false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), board != nil {
            showContextMenu(with: event)
        } else {
            window?.makeFirstResponder(nil)
            controller?.selectBoard(board?.id)
        }
    }

    override func rightMouseDown(with event: NSEvent) { showContextMenu(with: event) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrag(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrag(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlight(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { highlight(false) }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { highlight(false) }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !clipIDs(in: sender.draggingPasteboard).isEmpty && destinationExists
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { highlight(false) }
        guard let controller, destinationExists else { return false }
        let ids = clipIDs(in: sender.draggingPasteboard)
        guard !ids.isEmpty else { return false }
        var succeeded = false
        for id in ids {
            controller.moveItem(id, to: board?.id)
            if controller.store.items.contains(where: { $0.id == id && $0.isFavorite }),
               controller.store.boardMembership[id] == board?.id {
                succeeded = true
            }
        }
        return succeeded
    }

    private var destinationExists: Bool {
        guard let controller else { return false }
        guard let board else { return true }
        return controller.store.boards.contains(where: { $0.id == board.id })
    }

    private func updateDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        let valid = destinationExists && !clipIDs(in: sender.draggingPasteboard).isEmpty
        highlight(valid)
        return valid ? .copy : []
    }

    private func highlight(_ value: Bool) {
        if isTargeted.wrappedValue != value { isTargeted.wrappedValue = value }
    }

    private func clipIDs(in pasteboard: NSPasteboard) -> [UUID] {
        guard let controller else { return [] }
        var seen = Set<UUID>()
        var result: [UUID] = []
        let payloads = (pasteboard.pasteboardItems ?? []).compactMap { $0.data(forType: Self.identifierType) }
        for data in payloads {
            guard let string = String(data: data, encoding: .utf8),
                  let id = UUID(uuidString: string.trimmingCharacters(in: .whitespacesAndNewlines)),
                  seen.insert(id).inserted,
                  controller.store.items.contains(where: { $0.id == id }) else { continue }
            result.append(id)
        }
        return result
    }

    private func showContextMenu(with event: NSEvent) {
        guard board != nil else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let rename = NSMenuItem(title: "重命名分类…", action: #selector(renameBoard(_:)), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)
        let delete = NSMenuItem(title: "删除分类…", action: #selector(deleteBoard(_:)), keyEquivalent: "")
        delete.target = self
        menu.addItem(delete)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func renameBoard(_ sender: Any?) {
        guard let board else { return }
        controller?.renameBoard(board)
    }

    @objc private func deleteBoard(_ sender: Any?) {
        guard let board else { return }
        controller?.deleteBoard(board)
    }
}
