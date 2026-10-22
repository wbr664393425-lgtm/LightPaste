import SwiftUI
import AppKit

/// Quick paste at the text cursor: its own query and selection, so the drawer's filters stay as they were.
@MainActor
final class QuickPasteModel: ObservableObject {
    @Published var query = "" { didSet { if oldValue != query { refresh() } } }
    @Published private(set) var results: [ClipItem] = []
    @Published var selectedID: UUID?
    /// Bumped by keyboard moves so the list scrolls to the selection; mouse picks do not scroll.
    @Published private(set) var scrollRevision = 0
    private let store: HistoryStore
    static let limit = 60

    init(store: HistoryStore) { self.store = store }

    var selectedItem: ClipItem? { results.first { $0.id == selectedID } }

    func refresh() {
        let parsed = SearchQuery.parse(query)
        let now = Date()
        let matches = store.search(parsed.text, filter: .history).lazy
            .filter { !parsed.hasFilters || parsed.matches($0, now: now) }
        let next = Array(matches.prefix(Self.limit))
        if next != results { results = next }
        if !results.contains(where: { $0.id == selectedID }) { selectedID = results.first?.id }
    }

    func move(by delta: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.id == selectedID } ?? 0
        selectedID = results[min(results.count - 1, max(0, index + delta))].id
        scrollRevision += 1
    }
}

struct QuickPasteView: View {
    let controller: AppController
    @ObservedObject var model: QuickPasteModel
    static let size = CGSize(width: 600, height: 340)

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                searchField
                Divider().opacity(0.6)
                list
            }
            .frame(width: 300)
            Divider().opacity(0.6)
            preview
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var searchField: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(DS.secondary)
            TextField("搜索历史", text: $model.query)
                .textFieldStyle(.plain).font(.ds(DS.Size.emphasis))
                .accessibilityLabel("搜索剪贴板历史")
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(DS.tertiary)
                }
                .buttonStyle(.plain).accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, DS.Space.m).frame(height: 44)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                        row(item, index: index).id(item.id)
                    }
                }
                .padding(6)
            }
            .overlay {
                if model.results.isEmpty {
                    Text(model.query.isEmpty ? "复制内容后会出现在这里" : "没有匹配的内容")
                        .font(.ds(DS.Size.body)).foregroundStyle(DS.secondary)
                }
            }
            .onChange(of: model.scrollRevision) { _ in
                guard let id = model.selectedID else { return }
                proxy.scrollTo(id)
            }
        }
    }

    private func row(_ item: ClipItem, index: Int) -> some View {
        let selected = item.id == model.selectedID
        return HStack(spacing: DS.Space.s) {
            rowIcon(item)
            Text(rowTitle(item)).font(.ds(DS.Size.body, selected ? .medium : .regular)).lineLimit(1)
                .foregroundStyle(DS.ink)
            Spacer(minLength: DS.Space.xs)
            if index < 9 {
                KeyCap(text: "⌘\(index + 1)", highlighted: selected)
            } else {
                Text(CardTime.label(for: item.lastCopiedAt)).font(.ds(DS.Size.caption)).foregroundStyle(DS.tertiary)
            }
        }
        .padding(.horizontal, DS.Space.s).frame(height: 30)
        .background(selected ? DS.selected : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.small))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { controller.pasteFromQuickPaste(item.id) }
        .onTapGesture { model.selectedID = item.id }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(index < 9 ? "第 \(index + 1) 项，" : "")\(rowTitle(item))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { controller.pasteFromQuickPaste(item.id) }
    }

    @ViewBuilder private func rowIcon(_ item: ClipItem) -> some View {
        if item.kind == .link, item.detail != .sensitive, let icon = controller.linkIcon(for: item) {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else if let icon = controller.icons.appIcon(bundleID: item.sourceBundleID) {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 16, height: 16)
        } else {
            Image(systemName: item.detail?.symbol ?? item.kind.symbol).font(.ds(DS.Size.caption)).frame(width: 16)
                .foregroundStyle(DS.secondary)
        }
    }

    private func rowTitle(_ item: ClipItem) -> String {
        if item.detail == .sensitive { return "敏感内容 · 已隐藏" }
        if item.kind == .link, let title = item.linkTitle, !title.isEmpty { return title }
        let line = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? item.kind.label : line
    }

    private var preview: some View {
        VStack(spacing: DS.Space.m) {
            Spacer(minLength: 0)
            if let item = model.selectedItem {
                // The drawer's own card, read-only here: clicks belong to the list.
                DrawerClipCard(controller: controller, item: item, index: model.results.firstIndex(of: item) ?? 99,
                               selected: false, inMultiSelection: false, multiOrder: nil, badgeHighlighted: false,
                               boards: [], boardID: nil, query: model.query, size: .standard, pasting: false, onSelect: {}, interactive: false)
                    .id(item.id)
            }
            Spacer(minLength: 0)
            HStack(spacing: DS.Space.m) {
                hint("↩", "粘贴"); hint("⇧↩", "纯文本"); hint("esc", "关闭")
            }
            .padding(.bottom, DS.Space.m)
        }
        .frame(maxWidth: .infinity)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            KeyCap(text: key)
            Text(label).font(.ds(DS.Size.caption)).foregroundStyle(DS.secondary)
        }
    }
}
