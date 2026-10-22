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
            // A borderless menu keeps only an icon and a title from its label and colors them with the tint.
            Label(filterSummary, systemImage: controller.hasNarrowingFilters
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                .font(.ds(DS.Size.body))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .tint(controller.hasNarrowingFilters ? DS.accent : DS.secondary)
        .frame(maxWidth: 200)
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
                    hint("⌘", "点击多选")
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
            KeyCap(text: key)
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
    /// Off in the quick-paste preview, where clicks belong to the list.
    var interactive = true
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
            contentArea
            footer
        }
        .frame(width: size.width, height: size.height)
        // A wash marks group members; a single selection keeps its body plain under the border.
        .background(inMultiSelection ? DS.selected.opacity(0.55) : .clear)
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
        .overlay(interaction)
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

    @ViewBuilder private var interaction: some View {
        if interactive { NativeCardInteraction(controller: controller, item: item, onSelect: onSelect) }
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

    /// A faint wash of the source app's color: the icon carries identity, so a row of cards stays calm.
    /// Only time-limited content (codes, secrets) keeps a warm header as a signal.
    private var headerTint: some View {
        ZStack {
            if let detail = item.detail, detail == .sensitive || detail == .otp {
                DS.tint(for: detail)
            } else {
                DS.surface
                if let tint = controller.icons.tint(bundleID: item.sourceBundleID) {
                    Color(nsColor: tint).opacity(0.1)
                } else {
                    DS.ink.opacity(0.035)
                }
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

    /// Covers, images, colors and code fill the card edge to edge; everything else keeps the text margins.
    private var fullBleed: Bool {
        if let detail = item.detail { return detail == .color || detail == .code }
        return item.kind == .link || (item.kind == .image && thumbnail != nil)
    }

    @ViewBuilder private var contentArea: some View {
        if fullBleed {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        } else {
            content
                .padding(.horizontal, 14).padding(.top, DS.Space.m)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        }
    }

    private var zoomed: Bool { hovering && !reduceMotion }

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
            let value = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
            let rgba = ContentDetector.color(in: value)
            let (r, g, b, a) = (rgba?.red ?? 0, rgba?.green ?? 0, rgba?.blue ?? 0, rgba?.alpha ?? 1)
            // Dark ink on light swatches, white on dark ones; translucent colors sit on the card surface.
            let light = (0.299 * r + 0.587 * g + 0.114 * b) * a + (1 - a) * 0.9 > 0.6
            ZStack(alignment: .bottomLeading) {
                Color(.sRGB, red: r, green: g, blue: b, opacity: a)
                VStack(alignment: .leading, spacing: 2) {
                    Text(value).font(.system(size: DS.Size.display, weight: .semibold, design: .monospaced))
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(String(format: "RGB %d, %d, %d", Int(r * 255), Int(g * 255), Int(b * 255)) + (a < 1 ? String(format: " · %.0f%%", a * 100) : ""))
                        .font(.system(size: DS.Size.caption, design: .monospaced)).opacity(0.75)
                }
                .foregroundStyle(light ? Color.black.opacity(0.78) : Color.white)
                .padding(14)
            }
        case .code:
            let code = keywords.isEmpty ? String(bodyText.prefix(800)) : SearchHighlight.excerpt(bodyText, keywords: keywords, limit: 800)
            // An editor-like dark panel in both appearances, so code reads as code at a glance.
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.white.opacity(0.18)).frame(width: 7, height: 7) }
                    Spacer(minLength: 0)
                    Text(CodeLanguageCache.label(for: item.id, text: bodyText))
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.white.opacity(0.55))
                }
                Text(keywords.isEmpty ? SyntaxHighlighter.attributed(code, dark: true)
                     : SearchHighlight.attributed(code, keywords: keywords, base: SyntaxHighlighter.attributed(code, dark: true)))
                    .font(.system(size: DS.Size.caption, design: .monospaced)).lineSpacing(2)
                    .lineLimit(size == .compact ? 6 : 8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 14).padding(.vertical, DS.Space.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(red: 0.12, green: 0.13, blue: 0.15))
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
            if let thumbnail {
                ZStack(alignment: .bottomLeading) {
                    Color.clear.overlay(
                        Image(nsImage: thumbnail).resizable().interpolation(.high).scaledToFill()
                            .scaleEffect(zoomed ? 1.05 : 1)
                            .animation(.easeOut(duration: 0.25), value: zoomed)
                    )
                    .clipped()
                    Group {
                        if !keywords.isEmpty, let ocr = item.ocrText, !ocr.isEmpty {
                            highlightedText(SearchHighlight.excerpt(ocr, keywords: keywords, limit: 120), limit: 120)
                        } else {
                            Text(item.title)
                        }
                    }
                    .font(.ds(DS.Size.caption, .medium)).lineLimit(1)
                    .padding(.horizontal, DS.Space.s).frame(height: 22)
                    .background(.regularMaterial, in: Capsule())
                    .padding(DS.Space.s)
                }
                .background(DS.ink.opacity(0.04))
            } else {
                VStack(alignment: .leading, spacing: 7) {
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
                    Text(item.title).font(.ds(DS.Size.caption)).foregroundStyle(DS.secondary).lineLimit(1)
                }
            }
        case .link:
            VStack(alignment: .leading, spacing: 0) {
                linkHero.frame(height: (size.height * 0.42).rounded())
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    highlightedText(linkHeadline, limit: 200)
                        .font(.ds(DS.Size.title, .semibold)).lineLimit(size == .compact ? 1 : 2).lineSpacing(2)
                    // The hero already names the site; this line adds only the page within it.
                    if let linkDetail {
                        highlightedText(linkDetail, limit: 400)
                            .font(.ds(DS.Size.caption)).foregroundStyle(DS.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .padding(.horizontal, 14).padding(.top, 10)
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
        case .text where keywords.isEmpty && isShortText:
            // A word or a short phrase reads as a headline instead of a lone line in the corner.
            let phrase = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
            Text(phrase)
                .font(.system(size: phrase.count <= 8 ? 28 : DS.Size.display + 2, weight: .semibold))
                .lineLimit(3).minimumScaleFactor(0.7).lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .topLeading)
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

    private func linkIcon(side: CGFloat) -> some View {
        Group {
            if let icon = controller.linkIcon(for: item) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Text(String((linkHost ?? "?").prefix(1)).uppercased())
                    .font(.system(size: side * 0.6, weight: .bold)).foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(linkColor)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
    }

    private var linkColor: Color {
        controller.linkTint(for: item).map { Color(nsColor: $0) } ?? Color(red: 0.26, green: 0.52, blue: 0.92)
    }

    /// The page's cover when it has one; otherwise the site's color with its icon, large and small.
    @ViewBuilder private var linkHero: some View {
        if let cover = controller.linkImage(for: item) {
            Color.clear
                .overlay(Image(nsImage: cover).resizable().interpolation(.high).scaledToFill()
                    .scaleEffect(zoomed ? 1.06 : 1)
                    .animation(.easeOut(duration: 0.3), value: zoomed))
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 5) {
                        linkIcon(side: 14)
                        Text(linkHost ?? "链接").font(.ds(DS.Size.caption, .medium)).lineLimit(1)
                    }
                    .padding(.horizontal, 7).frame(height: 22)
                    .background(.regularMaterial, in: Capsule())
                    .padding(DS.Space.s)
                }
        } else {
            ZStack(alignment: .leading) {
                LinearGradient(colors: [linkColor.opacity(0.42), linkColor.opacity(0.14)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                linkIcon(side: 76)
                    .opacity(0.18).blur(radius: 1.5)
                    .rotationEffect(.degrees(zoomed ? -4 : -12))
                    .offset(x: size.width - 70, y: 14)
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: zoomed)
                HStack(spacing: 10) {
                    linkIcon(side: 34).shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    Text(linkHost ?? "链接").font(.ds(DS.Size.emphasis, .semibold)).foregroundStyle(DS.ink.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
            }
            .clipped()
        }
    }

    /// The path and query under the title, or the full address while searching so matches in the host show.
    private var linkDetail: String? {
        var detail = linkAddress
        if keywords.isEmpty, let url = LinkPreviewService.webURL(in: item) {
            detail = url.path + (url.query.map { "?" + $0 } ?? "")
        }
        let trimmed = detail.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty || trimmed == linkHeadline ? nil : detail
    }

    /// The address without its scheme, for the line under the title.
    private var linkAddress: String {
        let raw = (item.text.isEmpty ? item.title : item.text).trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where raw.lowercased().hasPrefix(prefix) { return String(raw.dropFirst(prefix.count)) }
        return raw
    }

    private var isShortText: Bool {
        let text = bodyText
        guard text.utf16.count <= 60 else { return false }
        let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !phrase.isEmpty && phrase.count <= 24 && !phrase.contains(where: \.isNewline)
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
