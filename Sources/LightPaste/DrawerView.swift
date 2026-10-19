import SwiftUI
import AppKit

/// The everyday clipboard surface. Window positioning and keyboard routing live in AppController.
@MainActor
struct DrawerView: View {
    @ObservedObject var controller: AppController
    @FocusState private var searchFocused: Bool

    private var items: [ClipItem] { controller.filteredItems }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                toolbar(width: geometry.size.width)
                    .frame(height: 52)
                Rectangle().fill(DS.line).frame(height: 1)
                cardStrip.frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(DS.line).frame(height: 1)
                footer.frame(height: 30)
            }
            .foregroundStyle(DS.ink)
            .tint(DS.accent)
        }
        .frame(minWidth: 680, minHeight: 280)
        .accessibilityIdentifier("drawer-root")
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LightPasteFocusSearch"))) { _ in
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LightPasteDrawerShown"))) { _ in
            searchFocused = false
        }
    }

    // MARK: Toolbar

    private func toolbar(width: CGFloat) -> some View {
        HStack(spacing: width < 820 ? DS.Space.s : DS.Space.m) {
            HStack(spacing: 7) {
                Image(systemName: "square.on.square")
                    .font(.ds(DS.Size.title, .medium))
                    .foregroundStyle(DS.accent)
                if width >= 1100 { Text("轻贴").font(.ds(DS.Size.emphasis, .semibold)) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("轻贴")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.xs) {
                    scopeTab("历史", selected: !controller.isFavoritesScope) { controller.showHistory() }
                    DrawerBoardTab(controller: controller, board: nil,
                                   selected: controller.isFavoritesScope && controller.selectedBoardID == nil)
                    ForEach(controller.store.boards) { board in
                        DrawerBoardTab(controller: controller, board: board, selected: controller.selectedBoardID == board.id)
                    }
                    Button { controller.createBoard() } label: {
                        Image(systemName: "plus").font(.ds(DS.Size.caption, .semibold))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(DS.line, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain).foregroundStyle(DS.secondary)
                    .accessibilityLabel("新建收藏分类").help("新建收藏分类")
                }
                .padding(.vertical, 3)
            }
            .frame(minWidth: 120, maxWidth: .infinity)
            .accessibilityLabel("历史和收藏分类")

            typeMenu

            searchField
                .frame(width: min(380, max(200, width * 0.3)))

            Button { controller.createTextItem() } label: {
                Image(systemName: "square.and.pencil").font(.ds(DS.Size.emphasis))
            }
            .buttonStyle(DSIconButtonStyle())
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityLabel("新建常用文本")
            .help("新建常用文本（⌘N）")

            Button { controller.showSettings() } label: {
                Image(systemName: "gearshape").font(.ds(DS.Size.emphasis))
            }
            .buttonStyle(DSIconButtonStyle())
            .accessibilityLabel("设置")
            .help("设置")
        }
        .padding(.horizontal, DS.Space.xl)
    }

    private func scopeTab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.ds(DS.Size.body, selected ? .semibold : .regular))
                .foregroundStyle(selected ? DS.accent : DS.secondary)
                .padding(.horizontal, DS.Space.m).frame(height: 28)
                .background(selected ? DS.selected : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(title)
    }

    /// Type, source app and date in one menu; the label lists whatever is active.
    private var typeMenu: some View {
        Menu {
            Section("类型") {
                ForEach([SidebarFilter.history, .text, .link, .image, .files]) { filter in
                    let active = filter == .history ? [.history, .favorites].contains(controller.filter) : controller.filter == filter
                    Button {
                        controller.filter = filter == .history ? (controller.isFavoritesScope ? .favorites : .history) : filter
                    } label: {
                        Label(filter == .history ? "全部类型" : filter.title, systemImage: active ? "checkmark" : filter.symbol)
                    }
                }
            }
            Section("来源应用") {
                Button { controller.sourceFilter = nil } label: {
                    Label("全部应用", systemImage: controller.sourceFilter == nil ? "checkmark" : "square.grid.2x2")
                }
                ForEach(controller.sourceOptions(), id: \.key) { option in
                    Button { controller.sourceFilter = option.key } label: {
                        if controller.sourceFilter == option.key {
                            Label(option.name, systemImage: "checkmark")
                        } else if let icon = menuIcon(option.key) {
                            Label { Text(option.name) } icon: { Image(nsImage: icon) }
                        } else {
                            Label(option.name, systemImage: "app")
                        }
                    }
                }
            }
            Section("日期") {
                ForEach(DateFilter.allCases) { range in
                    Button { controller.dateFilter = range } label: {
                        Label(range.title, systemImage: controller.dateFilter == range ? "checkmark" : "calendar")
                    }
                }
            }
            if controller.hasNarrowingFilters {
                Divider()
                Button("清除筛选") { controller.clearNarrowingFilters() }
            }
        } label: {
            HStack(spacing: 5) {
                if controller.hasNarrowingFilters {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill").font(.ds(DS.Size.body))
                }
                Text(filterSummary).font(.ds(DS.Size.body)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(controller.hasNarrowingFilters ? DS.accent : DS.secondary)
            .frame(maxWidth: 200)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("筛选：\(filterSummary)")
        .help("按类型、来源应用和日期筛选")
    }

    private var filterSummary: String {
        var parts: [String] = []
        if ![.history, .favorites].contains(controller.filter) { parts.append(controller.filter.title) }
        if let source = controller.sourceFilter { parts.append(controller.sourceName(for: source)) }
        if controller.dateFilter != .all { parts.append(controller.dateFilter.title) }
        return parts.isEmpty ? "筛选" : parts.joined(separator: " · ")
    }

    /// Menu rows render images at their own size, so app icons are scaled down first.
    private func menuIcon(_ bundleID: String) -> NSImage? {
        guard let icon = controller.icons.appIcon(bundleID: bundleID)?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    private var searchField: some View {
        HStack(spacing: DS.Space.s) {
            Button { searchFocused = true } label: {
                Image(systemName: "magnifyingglass").font(.ds(DS.Size.body, .medium))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .accessibilityLabel("搜索历史")
            .help("搜索（⌘F）")
            TextField("搜索内容、图片文字或应用", text: $controller.query)
                .textFieldStyle(.plain)
                .font(.ds(DS.Size.emphasis))
                .foregroundStyle(DS.ink)
                .focused($searchFocused)
                .accessibilityLabel("搜索剪贴板历史")
                .accessibilityIdentifier("drawer-search")
                .help("支持拼音和首字母；可加 app:应用、type:图片 / 链接 / 代码、date:今天 / 昨天 / 本周、is:收藏")
            if !controller.query.isEmpty {
                Text("\(items.count) 项").font(.ds(DS.Size.caption)).monospacedDigit()
                Button { controller.query = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").font(.ds(DS.Size.body))
                }
                .buttonStyle(.plain).accessibilityLabel("清除搜索")
            } else {
                KeyCap(text: "⌘F")
            }
        }
        .foregroundStyle(DS.secondary)
        .padding(.horizontal, DS.Space.m)
        .frame(height: 32)
        .background(DS.field, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card)
            .stroke(searchFocused ? DS.accent.opacity(0.8) : DS.line, lineWidth: searchFocused ? 1.5 : 1))
    }

    // MARK: Cards

    @ViewBuilder private var cardStrip: some View {
        if items.isEmpty {
            emptyState
        } else {
            NativeCardStrip(
                controller: controller, items: items,
                state: CardStripState(
                    selectedID: controller.selectedID, multiSelection: controller.multiSelection,
                    commandHeld: controller.commandHeld, query: controller.query, size: controller.cardSize,
                    pastingID: controller.pastingID, drawerRevision: controller.drawerRevision, edge: controller.drawerEdge,
                    boards: controller.store.boards, membership: controller.store.boardMembership,
                    scrollRevision: controller.selectionScrollRevision),
                onSelect: { searchFocused = false })
        }
    }

    private var emptyState: some View {
        HStack(spacing: 18) {
            Image(systemName: controller.query.isEmpty ? (controller.selectedBoardID != nil ? "folder" : controller.isFavoritesScope ? "star" : "square.on.square") : "magnifyingglass")
                .font(.system(size: 32, weight: .ultraLight)).foregroundStyle(DS.accent.opacity(0.75))
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(emptyTitle).font(.ds(DS.Size.title, .medium))
                Text(emptyMessage).font(.ds(DS.Size.body)).foregroundStyle(DS.secondary)
                if !controller.query.isEmpty {
                    Button("清除搜索") { controller.query = "" }.buttonStyle(.bordered).controlSize(.small).padding(.top, DS.Space.xs)
                } else if controller.hasNarrowingFilters {
                    Button("清除筛选") { controller.clearNarrowingFilters() }.buttonStyle(.bordered).controlSize(.small).padding(.top, DS.Space.xs)
                } else if controller.capturePaused {
                    Button("继续记录") { controller.resumeCapture() }.buttonStyle(.bordered).controlSize(.small).padding(.top, DS.Space.xs)
                } else if controller.filter != .history || controller.isFavoritesScope {
                    Button("查看全部历史") { controller.showHistory() }.buttonStyle(.bordered).controlSize(.small).padding(.top, DS.Space.xs)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(26)
        .accessibilityIdentifier("drawer-empty")
    }

    private var emptyTitle: String {
        if !controller.query.isEmpty { return "没有找到“\(controller.query)”" }
        if let board = controller.store.boards.first(where: { $0.id == controller.selectedBoardID }) {
            return "“\(board.name)”还没有内容"
        }
        if controller.hasNarrowingFilters { return "没有符合筛选条件的内容" }
        if controller.isFavoritesScope { return "把常用内容留在手边" }
        if controller.capturePaused { return controller.pauseLabel }
        if controller.filter != .history { return "还没有\(controller.filter.title)记录" }
        return "从下一次复制开始"
    }

    private var emptyMessage: String {
        if !controller.query.isEmpty { return "搜索覆盖正文、标题、链接标题、图片中的文字和来源应用，中文可用拼音或首字母。可加 app:微信、type:图片、date:今天、is:收藏 缩小范围。" }
        if controller.hasNarrowingFilters { return "当前筛选：\(filterSummary)。" }
        if controller.selectedBoardID != nil { return "将卡片拖到这个分类，或在卡片菜单中选择“收藏到”。" }
        if controller.isFavoritesScope { return "点击卡片上的星标，常用内容就会留在这里。" }
        if controller.capturePaused { return "继续记录后，新复制的内容会显示在这里。" }
        return "复制文字、链接、图片或文件，之后按 \(controller.shortcutLabel) 随时取用。"
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        if controller.multiSelection.count > 1 {
            batchBar
        } else {
            HStack(spacing: DS.Space.m) {
                HStack(spacing: DS.Space.m) {
                    hint("← →", "选择")
                    hint("↩", controller.accessibilityGranted
                         ? (controller.alwaysPlainText || controller.targetPastesPlainText ? "粘贴纯文本" : "粘贴") : "复制")
                    hint("⌘1–9", "快速粘贴")
                    hint("空格", "预览")
                    hint("⌘ 点击", "多选")
                }
                Spacer(minLength: DS.Space.xs)
                if !controller.statusText.isEmpty {
                    Text(controller.statusText).font(.ds(DS.Size.caption, .medium)).foregroundStyle(DS.accent)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    HStack(spacing: 5) {
                        Circle().fill(controller.capturePaused ? DS.secondary : DS.accent).frame(width: 5, height: 5)
                        Text(controller.capturePaused ? controller.pauseLabel : "本机记录")
                        Text("· \(items.count.formatted()) 项").monospacedDigit()
                    }
                    .font(.ds(DS.Size.caption)).foregroundStyle(DS.secondary)
                }
            }
            .padding(.horizontal, DS.Space.xl + 2)
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.ds(DS.Size.caption, .semibold))
            Text(label).font(.ds(DS.Size.caption))
        }
        .foregroundStyle(DS.secondary)
    }

    private var batchBar: some View {
        HStack(spacing: DS.Space.m) {
            Text("已选 \(controller.multiSelection.count) 项").font(.ds(DS.Size.body, .semibold)).monospacedDigit()
            Text("按选择顺序粘贴").font(.ds(DS.Size.caption)).foregroundStyle(DS.secondary)
            Spacer()
            Button { controller.startPasteQueue() } label: {
                Label("按顺序粘贴", systemImage: "list.number").font(.ds(DS.Size.body, .medium))
            }
            .buttonStyle(.borderless).help("逐个粘贴：每按一次 ⌘V 粘贴下一项（⌥↩）")
            Menu {
                Button("每项一行") { controller.pasteMerged(separator: "\n") }
                Button("每项之间空一行") { controller.pasteMerged(separator: "\n\n") }
                Button("用逗号分隔") { controller.pasteMerged(separator: ",") }
                Button("用空格分隔") { controller.pasteMerged(separator: " ") }
            } label: {
                Label("合并粘贴", systemImage: "text.append").font(.ds(DS.Size.body))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("按选择顺序合并为一条文字后粘贴，合并结果会保存在历史中")
            Menu {
                Button("全部收藏") { controller.favoriteSelection(to: nil) }
                if !controller.store.boards.isEmpty { Divider() }
                ForEach(controller.store.boards) { board in
                    Button(board.name) { controller.favoriteSelection(to: board.id) }
                }
            } label: {
                Label("收藏到", systemImage: "star").font(.ds(DS.Size.body))
            }
            .menuStyle(.borderlessButton).fixedSize()
            Button(role: .destructive) { controller.deleteSelection() } label: {
                Label("删除", systemImage: "trash").font(.ds(DS.Size.body))
            }
            .buttonStyle(.borderless).help("删除选中内容（⌘⌫）")
            Button("取消") { controller.clearMultiSelection() }
                .buttonStyle(.borderless).font(.ds(DS.Size.body)).foregroundStyle(DS.secondary)
                .help("取消多选（esc）")
        }
        .padding(.horizontal, DS.Space.xl + 2)
        .background(DS.selected.opacity(0.6))
    }

}

/// The first eight cards rise in one after another when the drawer opens.
private struct CardEntrance: ViewModifier {
    let index: Int
    let revision: Int
    let edge: DrawerEdge
    @State private var visible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : (edge == .bottom ? 8 : -8))
            .onChange(of: revision) { _ in
                guard !reduceMotion, index < 8 else { return }
                visible = false
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.28).delay(Double(index) * DS.Motion.stagger)) { visible = true }
                }
            }
    }
}

private let drawerClipIdentifierType = "com.local.lightpaste.clip-id"

@MainActor
private struct DrawerBoardTab: View {
    let controller: AppController
    let board: FavoriteBoard?
    let selected: Bool
    @State private var dropTargeted = false

    private var title: String { board?.name ?? "全部收藏" }

    var body: some View {
        Button { controller.selectBoard(board?.id) } label: {
            Text(title)
                .font(.ds(DS.Size.body, selected ? .semibold : .regular))
                .foregroundStyle(selected || dropTargeted ? DS.accent : DS.secondary)
                .lineLimit(1).truncationMode(.tail)
                .padding(.horizontal, DS.Space.m).frame(height: 28)
                .background(dropTargeted ? DS.accent.opacity(0.17) : selected ? DS.selected : .clear, in: Capsule())
                .overlay(Capsule().stroke(dropTargeted ? DS.accent.opacity(0.75) : .clear, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .overlay(NativeBoardInteraction(controller: controller, board: board, isTargeted: $dropTargeted))
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("拖入卡片以收藏到\(title)")
    }
}

/// What a reused collection cell hosts. `.id` gives each item fresh card state (thumbnail,
/// hover, loading task), so a recycled cell never shows the previous item's image.
@MainActor
struct DrawerCardCell: View {
    let card: DrawerClipCard
    let revision: Int
    let edge: DrawerEdge

    init(controller: AppController, item: ClipItem, index: Int, state: CardStripState, onSelect: @escaping () -> Void) {
        card = DrawerClipCard(controller: controller, item: item, index: index,
                              selected: state.selectedID == item.id,
                              inMultiSelection: state.multiSelection.contains(item.id),
                              multiOrder: state.multiSelection.firstIndex(of: item.id).map { $0 + 1 },
                              badgeHighlighted: state.commandHeld && index < 9,
                              boards: state.boards, boardID: state.membership[item.id],
                              query: state.query, size: state.size,
                              pasting: state.pastingID == item.id, onSelect: onSelect)
        revision = state.drawerRevision
        edge = state.edge
    }

    var body: some View {
        card.equatable()
            .id(card.item.id)
            .modifier(CardEntrance(index: card.index, revision: revision, edge: edge))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(DS.ink)
            .tint(DS.accent)
    }
}

/// Each visible card owns its asynchronous image. Selection changes do not reload its payload.
@MainActor
struct DrawerClipCard: View, Equatable {
    let controller: AppController
    let item: ClipItem
    let index: Int
    let selected: Bool
    let inMultiSelection: Bool
    let multiOrder: Int?
    let badgeHighlighted: Bool
    let boards: [FavoriteBoard]
    let boardID: UUID?
    let query: String
    let size: CardSize
    let pasting: Bool
    let onSelect: () -> Void
    @State private var thumbnail: NSImage?
    @State private var thumbnailFinished = false
    @State private var fileThumbnail: NSImage?
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.controller === rhs.controller && lhs.item == rhs.item && lhs.index == rhs.index && lhs.selected == rhs.selected &&
        lhs.inMultiSelection == rhs.inMultiSelection && lhs.multiOrder == rhs.multiOrder &&
        lhs.badgeHighlighted == rhs.badgeHighlighted && lhs.query == rhs.query && lhs.size == rhs.size &&
        lhs.pasting == rhs.pasting && lhs.boardID == rhs.boardID && lhs.boards.count == rhs.boards.count &&
        zip(lhs.boards, rhs.boards).allSatisfy { pair in pair.0.id == pair.1.id && pair.0.name == pair.1.name }
    }

    private var keywords: [String] { SearchHighlight.keywords(query) }
    private var isSecret: Bool { item.detail == .sensitive }
    private var highlighted: Bool { selected || inMultiSelection }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .padding(.horizontal, 14).padding(.top, DS.Space.m)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            footer
        }
        .frame(width: size.width, height: size.height)
        .background(highlighted ? DS.selected.opacity(0.55) : .clear)
        .background(DS.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card)
            .strokeBorder(highlighted ? DS.accent : DS.line, lineWidth: highlighted ? 2 : 1))
        .shadow(color: Color.black.opacity(selected ? 0.16 : 0.05), radius: selected ? 10 : 3, y: selected ? 5 : 1)
        .scaleEffect(pasting ? 0.92 : selected ? 1.03 : 1)
        .opacity(pasting ? 0.4 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.78), value: selected)
        .animation(reduceMotion ? nil : .easeIn(duration: 0.14), value: pasting)
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        .onHover { hovering = $0 }
        .overlay(NativeCardInteraction(controller: controller, item: item, onSelect: onSelect))
        .task(id: item.id) {
            if item.kind == .image {
                let loaded = await controller.thumbnail(for: item)
                guard !Task.isCancelled else { return }
                thumbnail = loaded
                thumbnailFinished = true
            } else if item.kind == .files, let first = filePaths.first {
                let loaded = await controller.icons.thumbnail(path: first)
                guard !Task.isCancelled else { return }
                // Without a Quick Look thumbnail a single file shows its 128-point system icon instead.
                fileThumbnail = loaded ?? (filePaths.count == 1 ? controller.icons.fileIcon(path: first) : nil)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(index < 9 ? "第 \(index + 1) 项，" : "")\(kindLabel)：\(displayTitle)")
        .accessibilityIdentifier("clip-\(item.id.uuidString)")
        .accessibilityAddTraits(highlighted ? .isSelected : [])
        .accessibilityAction(named: "选中") { controller.select(item.id); onSelect() }
        .accessibilityAction(named: "粘贴") { controller.select(item.id); controller.useSelected() }
        .accessibilityAction(named: "预览") { controller.select(item.id); controller.showItemPreview() }
        .accessibilityAction(named: inMultiSelection ? "移出多选" : "加入多选") { controller.toggleMultiSelect(item.id) }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 6) {
            if let icon = controller.icons.appIcon(bundleID: item.sourceBundleID) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 16, height: 16)
                    .help(sourceName)
            } else {
                Image(systemName: item.kind.symbol).font(.ds(DS.Size.caption, .medium)).frame(width: 16)
            }
            Text(kindLabel).font(.ds(DS.Size.caption, .semibold)).lineLimit(1)
            Spacer(minLength: DS.Space.xs)
            if let multiOrder {
                Text("\(multiOrder)").font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(DS.background)
                    .frame(minWidth: 16, minHeight: 16).padding(.horizontal, 2)
                    .background(DS.accent, in: Capsule())
                    .accessibilityLabel("多选第 \(multiOrder) 项")
            } else if index < 9 {
                KeyCap(text: "⌘\(index + 1)", highlighted: badgeHighlighted)
            }
            Text(CardTime.label(for: item.lastCopiedAt)).font(.ds(DS.Size.caption)).monospacedDigit().lineLimit(1)
            Button { controller.toggleFavorite(item.id) } label: {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .font(.ds(DS.Size.body))
                    .foregroundStyle(item.isFavorite ? DS.accent : DS.secondary)
                    .frame(width: 24, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isFavorite ? "取消收藏：\(displayTitle)" : "收藏：\(displayTitle)")
            .help(item.isFavorite ? "取消收藏" : "收藏")
        }
        .foregroundStyle(DS.ink.opacity(0.82))
        .padding(.leading, DS.Space.m).padding(.trailing, 6)
        .frame(height: 35)
        .background(headerTint)
    }

    /// The source app's color, softened; detected content and gray icons fall back to the kind color.
    private var headerTint: some View {
        ZStack {
            if let detail = item.detail, detail == .sensitive || detail == .otp || detail == .code {
                DS.tint(for: detail)
            } else if let tint = controller.icons.tint(bundleID: item.sourceBundleID) {
                DS.surface
                Color(nsColor: tint).opacity(0.26)
            } else {
                DS.tint(for: item.kind)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(sourceName).lineLimit(1)
            if item.kind == .image, let text = item.ocrText, !text.isEmpty {
                Label("含文字", systemImage: "text.viewfinder").labelStyle(.titleAndIcon)
                    .padding(.horizontal, 5).frame(height: 16)
                    .background(DS.ink.opacity(0.06), in: Capsule())
            }
            Spacer(minLength: DS.Space.xs)
            if let expiresAt = item.expiresAt, !item.isFavorite {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Label(CardTime.remaining(until: expiresAt, now: context.date), systemImage: "timer")
                        .foregroundStyle(DS.warning)
                }
            } else if selected {
                Image(systemName: "return").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.accent)
            }
        }
        .font(.ds(DS.Size.caption)).foregroundStyle(DS.secondary)
        .padding(.horizontal, 14).padding(.bottom, DS.Space.m).padding(.top, DS.Space.s)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let detail = item.detail {
            detailContent(detail)
        } else {
            kindContent
        }
    }

    @ViewBuilder private func detailContent(_ detail: ClipDetail) -> some View {
        switch detail {
        case .sensitive:
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                    Text(hovering ? "原文" : "已隐藏，悬停查看").font(.ds(DS.Size.caption, .medium))
                }
                .foregroundStyle(DS.warning)
                ZStack(alignment: .topLeading) {
                    Text(String((item.kind == .image ? item.ocrText ?? "" : bodyText).prefix(300)))
                        .font(.system(size: DS.Size.body, design: .monospaced)).lineSpacing(3).lineLimit(5)
                        .blur(radius: hovering ? 0 : 7)
                        .accessibilityHidden(!hovering)
                    if !hovering {
                        Text(String(repeating: "•", count: 14)).font(.ds(DS.Size.display, .semibold))
                            .foregroundStyle(DS.secondary).padding(.top, DS.Space.s)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
            }
        case .otp:
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(ContentDetector.otp(in: bodyText) ?? "")
                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                    .kerning(4).foregroundStyle(DS.ink)
                    .textSelection(.disabled)
                if let expiresAt = item.expiresAt {
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        let total = ContentDetector.otpLifetime
                        let left = max(0, expiresAt.timeIntervalSince(context.date))
                        ProgressView(value: left, total: total).progressViewStyle(.linear).tint(DS.warning)
                    }
                }
                Text(bodyText).font(.ds(DS.Size.caption)).foregroundStyle(DS.secondary).lineLimit(3)
            }
        case .color:
            let rgba = ContentDetector.color(in: bodyText.trimmingCharacters(in: .whitespacesAndNewlines))
            VStack(alignment: .leading, spacing: DS.Space.s) {
                RoundedRectangle(cornerRadius: DS.Radius.small)
                    .fill(Color(.sRGB, red: rgba?.red ?? 0, green: rgba?.green ?? 0, blue: rgba?.blue ?? 0, opacity: rgba?.alpha ?? 1))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.small).strokeBorder(DS.line))
                    .frame(maxWidth: .infinity).frame(height: size.height * 0.36)
                Text(bodyText).font(.system(size: DS.Size.title, weight: .semibold, design: .monospaced)).lineLimit(1)
            }
        case .code:
            let code = keywords.isEmpty ? String(bodyText.prefix(800)) : SearchHighlight.excerpt(bodyText, keywords: keywords, limit: 800)
            VStack(alignment: .leading, spacing: 6) {
                Text(CodeLanguageCache.label(for: item.id, text: bodyText))
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.secondary)
                    .padding(.horizontal, 5).frame(height: 16).background(DS.ink.opacity(0.06), in: Capsule())
                Text(keywords.isEmpty ? SyntaxHighlighter.attributed(code)
                     : SearchHighlight.attributed(code, keywords: keywords, base: SyntaxHighlighter.attributed(code)))
                    .font(.system(size: DS.Size.caption, design: .monospaced)).lineSpacing(2)
                    .lineLimit(size == .compact ? 6 : 8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        case .email, .phone:
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Image(systemName: detail.symbol).font(.system(size: 22, weight: .light)).foregroundStyle(DS.accent)
                highlightedText(bodyText, limit: 200)
                    .font(.ds(DS.Size.title, .semibold)).lineLimit(3)
            }
        }
    }

    @ViewBuilder private var kindContent: some View {
        switch item.kind {
        case .image:
            VStack(alignment: .leading, spacing: 7) {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: size.height - 110)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    VStack(spacing: DS.Space.s) {
                        if thumbnailFinished {
                            Image(systemName: "photo").font(.system(size: 24, weight: .light))
                            Text("图片预览不可用").font(.ds(DS.Size.caption))
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .foregroundStyle(DS.secondary)
                    .frame(maxWidth: .infinity).frame(height: size.height - 110)
                }
                if !keywords.isEmpty, let ocr = item.ocrText, !ocr.isEmpty {
                    highlightedText(SearchHighlight.excerpt(ocr, keywords: keywords, limit: 120), limit: 120)
                        .font(.ds(DS.Size.caption)).lineLimit(1)
                } else {
                    Text(item.title).font(.ds(DS.Size.caption)).foregroundStyle(DS.secondary).lineLimit(1)
                }
            }
        case .link:
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    linkIcon
                    Text(linkHost ?? "链接").font(.ds(DS.Size.caption, .medium)).foregroundStyle(DS.secondary).lineLimit(1)
                }
                highlightedText(linkHeadline, limit: 200)
                    .font(.ds(DS.Size.title, .semibold)).lineLimit(3).lineSpacing(2)
                highlightedText(item.text.isEmpty ? item.title : item.text, limit: 400)
                    .font(.ds(DS.Size.caption)).foregroundStyle(DS.secondary).lineSpacing(3)
                    .lineLimit(size == .compact ? 1 : 2)
            }
        case .files:
            VStack(alignment: .leading, spacing: DS.Space.s) {
                if let fileThumbnail, filePaths.count == 1 {
                    Image(nsImage: fileThumbnail).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: size.height - 130)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Text(item.title).font(.ds(DS.Size.emphasis, .semibold)).lineLimit(2)
                if !(fileThumbnail != nil && filePaths.count == 1) {
                    ForEach(Array(filePaths.prefix(3).enumerated()), id: \.offset) { _, path in
                        HStack(spacing: DS.Space.s) {
                            Image(nsImage: controller.icons.fileIcon(path: path)).resizable().frame(width: 20, height: 20)
                            highlightedText(URL(fileURLWithPath: path).lastPathComponent, limit: 120)
                                .font(.ds(DS.Size.body)).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
        case .text:
            highlightedText(keywords.isEmpty ? String(bodyText.prefix(600)) : SearchHighlight.excerpt(bodyText, keywords: keywords), limit: 600)
                .font(.ds(DS.Size.emphasis)).lineSpacing(4)
                .lineLimit(size == .compact ? 5 : size == .standard ? 7 : 9)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        case .other:
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Image(systemName: "square.on.square").font(.system(size: 22, weight: .light)).foregroundStyle(DS.secondary)
                Text(item.title).font(.ds(DS.Size.emphasis, .medium)).lineLimit(2)
                Text(item.text.isEmpty ? "原始格式已保留" : String(item.text.prefix(600)))
                    .font(.ds(DS.Size.caption)).foregroundStyle(DS.secondary).lineLimit(3)
            }
        }
    }

    private func highlightedText(_ text: String, limit: Int) -> Text {
        let clipped = String(text.prefix(limit))
        return keywords.isEmpty ? Text(clipped) : Text(SearchHighlight.attributed(clipped, keywords: keywords))
    }

    @ViewBuilder private var linkIcon: some View {
        if let icon = controller.linkIcon(for: item) {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Text(String((linkHost ?? "?").prefix(1)).uppercased())
                .font(.system(size: 11, weight: .bold)).foregroundStyle(DS.background)
                .frame(width: 18, height: 18)
                .background(DS.accent.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private var linkHeadline: String {
        if let title = item.linkTitle, !title.isEmpty { return title }
        return linkHost ?? item.title
    }

    private var bodyText: String { item.text.isEmpty ? item.title : item.text }
    private var sourceName: String { item.sourceName.isEmpty ? "未知应用" : item.sourceName }
    private var kindLabel: String { item.detail?.label ?? item.kind.label }
    private var displayTitle: String { isSecret ? "敏感内容" : item.title }

    private var linkHost: String? {
        LinkPreviewService.webURL(in: item)?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            ?? URL(string: item.title)?.host
    }

    private var filePaths: [String] {
        item.text.components(separatedBy: .newlines).filter { !$0.isEmpty }.prefix(3).map { $0 }
    }
}
