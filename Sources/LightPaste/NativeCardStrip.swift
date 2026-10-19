import AppKit
import SwiftUI

/// Everything a visible card shows besides its item; when it is unchanged, cells are not reconfigured.
struct CardStripState: Equatable {
    var selectedID: UUID?
    var multiSelection: [UUID]
    var commandHeld: Bool
    var query: String
    var size: CardSize
    var pastingID: UUID?
    var drawerRevision: Int
    var edge: DrawerEdge
    var boards: [FavoriteBoard]
    var membership: [UUID: UUID]
    var scrollRevision: Int
}

/// The drawer's card row as a native collection view: only visible cards exist, cells are reused
/// per content kind, and history changes are applied as animated inserts and removals.
@MainActor
struct NativeCardStrip: NSViewRepresentable {
    let controller: AppController
    let items: [ClipItem]
    let state: CardStripState
    let onSelect: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> CardStripScrollView {
        let coordinator = context.coordinator
        let layout = CardStripLayout()
        let collection = CardStripCollectionView()
        collection.collectionViewLayout = layout
        collection.isSelectable = false
        collection.backgroundColors = [.clear]
        collection.dataSource = coordinator
        for identifier in CardStripCell.identifiers.values {
            collection.register(CardStripCell.self, forItemWithIdentifier: identifier)
        }
        let scroll = CardStripScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.documentView = collection
        scroll.setAccessibilityIdentifier("drawer-cards")
        coordinator.collection = collection
        coordinator.layout = layout
        coordinator.apply(items: items, state: state, onSelect: onSelect)
        // The first layout pass has not run yet; center the selection once it has.
        DispatchQueue.main.async { coordinator.scrollToSelection() }
        return scroll
    }

    func updateNSView(_ scroll: CardStripScrollView, context: Context) {
        context.coordinator.apply(items: items, state: state, onSelect: onSelect)
    }

    /// The strip fills whatever it is offered. Answering directly keeps SwiftUI from asking AppKit for a
    /// fitting size, which builds Auto Layout constraints for every visible card on each drawer update.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CardStripScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: state.size.width, height: state.size.height))
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource {
        let controller: AppController
        weak var collection: NSCollectionView?
        weak var layout: CardStripLayout?
        private var items: [ClipItem] = []
        private var state: CardStripState?
        private var onSelect: () -> Void = {}
        private var lastScrolledID: UUID?
        private var shownObserver: NSObjectProtocol?

        init(controller: AppController) {
            self.controller = controller
            super.init()
            shownObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("LightPasteDrawerShown"), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scrollToSelection() }
            }
        }

        deinit { if let shownObserver { NotificationCenter.default.removeObserver(shownObserver) } }

        func apply(items next: [ClipItem], state nextState: CardStripState, onSelect: @escaping () -> Void) {
            guard let collection, let layout else { return }
            self.onSelect = onSelect
            layout.cardSize = CGSize(width: nextState.size.width, height: nextState.size.height)
            let previousState = state
            let oldIDs = items.map(\.id)
            let newIDs = next.map(\.id)
            let itemsChanged = items != next
            items = next
            state = nextState
            if oldIDs != newIDs {
                applyDifference(from: oldIDs, to: newIDs, in: collection)
            }
            if itemsChanged || previousState != nextState { reconfigureVisible() }
            if previousState?.scrollRevision != nextState.scrollRevision { scrollToSelection() }
        }

        /// Small changes animate in place; a new search or filter replaces the row at once.
        private func applyDifference(from oldIDs: [UUID], to newIDs: [UUID], in collection: NSCollectionView) {
            let difference = newIDs.difference(from: oldIDs)
            guard !oldIDs.isEmpty, difference.count <= 24, !DS.Motion.reduced, collection.window != nil else {
                collection.reloadData(); return
            }
            var removed = Set<IndexPath>(), inserted = Set<IndexPath>()
            for change in difference {
                switch change {
                case .remove(let offset, _, _): removed.insert(IndexPath(item: offset, section: 0))
                case .insert(let offset, _, _): inserted.insert(IndexPath(item: offset, section: 0))
                }
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                collection.animator().performBatchUpdates({
                    collection.deleteItems(at: removed)
                    collection.insertItems(at: inserted)
                })
            }
        }

        private func reconfigureVisible() {
            guard let collection else { return }
            for indexPath in collection.indexPathsForVisibleItems() {
                guard items.indices.contains(indexPath.item),
                      let cell = collection.item(at: indexPath) as? CardStripCell else { continue }
                configure(cell, at: indexPath.item)
            }
        }

        private func configure(_ cell: CardStripCell, at index: Int) {
            guard let state else { return }
            cell.show(DrawerCardCell(controller: controller, item: items[index], index: index, state: state, onSelect: onSelect))
        }

        /// Keyboard moves and new results recenter the selection; mouse clicks leave the row where it is.
        func scrollToSelection() {
            guard let collection, let layout, let scroll = collection.enclosingScrollView,
                  let id = state?.selectedID, id != lastScrolledID,
                  let index = items.firstIndex(where: { $0.id == id }) else { return }
            lastScrolledID = id
            let clip = scroll.contentView
            let card = layout.cardFrame(at: index)
            let maxX = max(0, collection.frame.width - clip.bounds.width)
            let target = NSPoint(x: min(maxX, max(0, card.midX - clip.bounds.width / 2)), y: clip.bounds.origin.y)
            guard abs(target.x - clip.bounds.origin.x) > 0.5 else { return }
            // Immediate, like the previous strip: held arrow keys would otherwise restart an animation each repeat.
            clip.scroll(to: target)
            scroll.reflectScrolledClipView(clip)
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = items[indexPath.item]
            let identifier = CardStripCell.identifiers[item.kind] ?? CardStripCell.identifiers[.other]!
            let cell = collectionView.makeItem(withIdentifier: identifier, for: indexPath)
            if let cell = cell as? CardStripCell { configure(cell, at: indexPath.item) }
            return cell
        }
    }
}

/// One row, cards centered vertically. Each cell extends half the gap to either side and the full
/// height, so the selected card's scale and shadow are never clipped by its own cell. Built on the
/// system flow layout, which keeps the collection view as wide as its content and finds visible
/// cards without walking the whole history.
final class CardStripLayout: NSCollectionViewFlowLayout {
    var cardSize = CGSize(width: 236, height: 222) {
        didSet { if oldValue != cardSize { invalidateLayout() } }
    }
    private let spacing = DS.Space.m
    private let inset = DS.Space.xl

    override init() {
        super.init()
        scrollDirection = .horizontal
        minimumLineSpacing = 0
        // Large enough that a tall drawer never wraps cards into a second row.
        minimumInteritemSpacing = 10_000
        sectionInset = NSEdgeInsets(top: 0, left: inset - spacing / 2, bottom: 0, right: inset - spacing / 2)
    }

    required init?(coder: NSCoder) { fatalError("CardStripLayout is created programmatically") }

    private var height: CGFloat { max(1, collectionView?.enclosingScrollView?.contentView.bounds.height ?? cardSize.height) }

    override func prepare() {
        let size = NSSize(width: cardSize.width + spacing, height: height)
        if itemSize != size { itemSize = size }
        super.prepare()
    }

    func cardFrame(at index: Int) -> NSRect {
        NSRect(x: inset + CGFloat(index) * (cardSize.width + spacing), y: max(0, (height - cardSize.height) / 2),
               width: cardSize.width, height: cardSize.height)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        abs(newBounds.height - itemSize.height) > 0.5
    }
}

/// Reused per content kind; the SwiftUI card inside is replaced, never rebuilt with its hosting view.
final class CardStripCell: NSCollectionViewItem {
    static let identifiers: [ClipKind: NSUserInterfaceItemIdentifier] = Dictionary(
        uniqueKeysWithValues: ClipKind.allCases.map { ($0, NSUserInterfaceItemIdentifier("card-\($0.rawValue)")) })

    private var host: NSHostingView<DrawerCardCell>?

    override func loadView() { view = NSView() }

    func show(_ content: DrawerCardCell) {
        if let host {
            // Moving the selection changes two cards; the others keep their hosting view untouched, so
            // SwiftUI does not re-run layout for every visible card on each arrow key.
            let current = host.rootView
            guard current.card != content.card || current.revision != content.revision || current.edge != content.edge else { return }
            host.rootView = content; return
        }
        let host = NSHostingView(rootView: content)
        // The cell's frame comes from the layout; SwiftUI need not report a size.
        host.sizingOptions = []
        host.frame = view.bounds
        host.autoresizingMask = [.width, .height]
        view.addSubview(host)
        self.host = host
    }
}

final class CardStripCollectionView: NSCollectionView {
    /// Keys stay with the drawer, which routes arrows, Enter and typing.
    override var acceptsFirstResponder: Bool { false }
}

/// Trackpads scroll natively; a plain mouse wheel's vertical turns browse the row sideways.
final class CardStripScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard !event.hasPreciseScrollingDeltas, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
              let copy = event.cgEvent?.copy() else { super.scrollWheel(with: event); return }
        let axes: [(CGEventField, CGEventField)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2),
            (.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2),
            (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2)
        ]
        for (vertical, horizontal) in axes {
            copy.setDoubleValueField(horizontal, value: copy.getDoubleValueField(vertical))
            copy.setDoubleValueField(vertical, value: 0)
        }
        super.scrollWheel(with: NSEvent(cgEvent: copy) ?? event)
    }
}
