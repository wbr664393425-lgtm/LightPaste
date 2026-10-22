import AppKit
import SwiftUI
import Combine
import ApplicationServices
import ImageIO
import QuartzCore
import UniformTypeIdentifiers
import ServiceManagement

@MainActor
final class AppController: NSObject, ObservableObject {
    let store: HistoryStore
    @Published var query = "" { didSet { if oldValue != query { refreshResults() } } }
    @Published var filter: SidebarFilter = .history {
        didSet {
            if filter == .favorites { isFavoritesScope = true }
            if oldValue != filter { refreshResults() }
        }
    }
    @Published var selectedBoardID: UUID? { didSet { if oldValue != selectedBoardID { refreshResults() } } }
    @Published private(set) var isFavoritesScope = false
    @Published private(set) var filteredItems: [ClipItem] = []
    @Published private(set) var selectionScrollRevision = 0
    @Published var selectedID: UUID?
    /// Ordered multi-selection (click order); empty when only one card is selected.
    @Published private(set) var multiSelection: [UUID] = []
    @Published private(set) var commandHeld = false
    /// Bumped each time the drawer opens; cards use it to play their entrance.
    @Published private(set) var drawerRevision = 0
    /// The card being pasted, for its exit animation.
    @Published private(set) var pastingID: UUID?
    @Published private(set) var queueProgress: (index: Int, total: Int)?
    @Published var capturePaused = false
    /// When a timed pause ends; nil while recording or paused until resumed by hand.
    @Published private(set) var pausedUntil: Date?
    /// Narrow the current scope by source app (bundle ID, else app name) and copy date.
    @Published var sourceFilter: String? { didSet { if oldValue != sourceFilter { refreshResults() } } }
    @Published var dateFilter: DateFilter = .all { didSet { if oldValue != dateFilter { refreshResults() } } }
    @Published var statusText = ""
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var retentionDays = 30
    @Published var maxItems = 1000
    @Published var excludedAppsText = ""
    @Published private(set) var hotKey = HotKeySpec.default
    @Published private(set) var quickHotKey = HotKeySpec.quickDefault
    @Published var drawerEdge: DrawerEdge = .bottom
    @Published var cardSize: CardSize = .standard
    @Published var linkPreviewEnabled = true
    @Published var ocrEnabled = true
    /// Minutes a detected secret is kept; 0 keeps it like ordinary history.
    @Published var sensitiveMinutes = 10
    @Published var alwaysPlainText = false
    /// Apps that always receive plain text, as bundle identifiers one per line (terminals, code editors).
    @Published var plainTextAppsText = ""
    @Published var hideDuringScreenShare = false
    @Published private(set) var launchAtLogin = false
    let icons = IconProvider()
    private let defaults: UserDefaults
    private let directory: URL
    private let resources: ClipResources
    private var updatingScope = false
    private var refreshScheduled = false
    private var monitor: ClipboardMonitor!
    private let pasteService = PasteService()
    private let hotKeys = HotKeyManager()
    private let hud = FeedbackHUD()
    private var compactPanel: ClipboardWindow?
    private var quickPanel: ClipboardWindow?
    let quick: QuickPasteModel
    private var drawerHost: NSView?
    private var drawerEffect: NSVisualEffectView?
    private var settingsWindow: NSWindow?
    private var previewWindow: ClipboardWindow?
    private var onboardingWindow: NSWindow?
    private var editors: [UUID: ItemEditorController] = [:]
    private var outsideClickMonitor: Any?
    private var flagsMonitor: Any?
    private var queueMonitor: Any?
    private var aliasMonitor: Any?
    /// What has been typed since the last “;” in another app, while it can still become an alias.
    private var aliasTyped: (text: String, pid: pid_t)?
    private var queueIDs: [UUID] = []
    private var drawerFrames: (shown: CGRect, hidden: CGRect)?
    private var drawerAnimationID = 0
    private var isClosingDrawer = false
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var previousApplication: NSRunningApplication?
    private var registeredHotKey: HotKeySpec?
    private var registeredQuickHotKey: HotKeySpec?
    private var rangeAnchor: UUID?
    private var subscription: AnyCancellable?
    private var activationObserver: NSObjectProtocol?
    private var maintenance: Timer?
    private var statusTimer: Timer?
    private var ocrRunning = false
    private var pauseTimer: Timer?
    /// Rebuilt after history changes; the filter menu reads it on every drawer redraw.
    private var sourceOptionsCache: [SourceOption]?
    /// In-flight link previews; the token tells a finished fetch whether it is still the current one.
    private var linkFetches: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    private var enrichmentAttempted = Set<UUID>()
    private let images = NSCache<NSString, NSImage>()
    private let linkIcons = NSCache<NSString, NSImage>()
    /// Links whose stored icon is missing, so scrolling does not re-read the database for them.
    private var missingLinkIcons = Set<UUID>()
    private let linkImages = NSCache<NSString, NSImage>()
    private var missingLinkImages = Set<UUID>()
    private var linkTints: [UUID: NSColor?] = [:]
    /// Links fetched before 0.7 stored no icon or cover; each is fetched once more after the upgrade.
    private var linkRefreshQueue = Set<UUID>()

    init(directory: URL, defaults: UserDefaults = .standard) throws {
        self.directory = directory
        self.defaults = defaults
        resources = ClipResources(directory: directory)
        store = try HistoryStore(directory: directory)
        quick = QuickPasteModel(store: store)
        super.init()
        images.countLimit = 60
        defaults.register(defaults: ["retentionDays": 30, "maxItems": 1000, "drawerEdge": "bottom", "cardSize": "standard",
            "linkPreview": true, "ocr": true, "sensitiveMinutes": 10, "alwaysPlainText": false, "hideDuringScreenShare": false,
            "plainTextApps": "com.apple.Terminal\ncom.googlecode.iterm2\ncom.microsoft.VSCode\ncom.apple.dt.Xcode",
            "excludedApps": "com.apple.Passwords\ncom.apple.keychainaccess\ncom.agilebits.onepassword7\ncom.1password.1password\ncom.bitwarden.desktop\norg.keepassxc.keepassxc\ncom.lastpass.LastPass\ncom.dashlane.Dashlane\nin.sinew.Enpass-Desktop"])
        retentionDays = defaults.integer(forKey: "retentionDays")
        maxItems = defaults.integer(forKey: "maxItems")
        if defaults.object(forKey: "hotKeyCode") != nil {
            hotKey = HotKeySpec(keyCode: UInt32(defaults.integer(forKey: "hotKeyCode")),
                                carbonModifiers: UInt32(defaults.integer(forKey: "hotKeyModifiers")))
        } else {
            // 0.3 stored one of three presets.
            hotKey = .legacy(option: defaults.integer(forKey: "shortcutOption"))
        }
        if defaults.object(forKey: "quickHotKeyCode") != nil {
            quickHotKey = HotKeySpec(keyCode: UInt32(defaults.integer(forKey: "quickHotKeyCode")),
                                     carbonModifiers: UInt32(defaults.integer(forKey: "quickHotKeyModifiers")))
        }
        drawerEdge = DrawerEdge(rawValue: defaults.string(forKey: "drawerEdge") ?? "bottom") ?? .bottom
        cardSize = CardSize(rawValue: defaults.string(forKey: "cardSize") ?? "standard") ?? .standard
        linkPreviewEnabled = defaults.bool(forKey: "linkPreview")
        ocrEnabled = defaults.bool(forKey: "ocr")
        sensitiveMinutes = defaults.integer(forKey: "sensitiveMinutes")
        alwaysPlainText = defaults.bool(forKey: "alwaysPlainText")
        plainTextAppsText = defaults.string(forKey: "plainTextApps") ?? ""
        hideDuringScreenShare = defaults.bool(forKey: "hideDuringScreenShare")
        launchAtLogin = SMAppService.mainApp.status == .enabled
        excludedAppsText = defaults.string(forKey: "excludedApps") ?? ""
        monitor = ClipboardMonitor(store: store) { }
        monitor.onError = { [weak self] message in self?.setStatus(message) }
        subscription = store.objectWillChange.sink { [weak self] in
            guard let self, !self.refreshScheduled else { return }
            self.refreshScheduled = true
            DispatchQueue.main.async {
                self.refreshScheduled = false
                self.sourceOptionsCache = nil
                self.objectWillChange.send()
                self.refreshResults()
                if self.quickPanel?.isVisible == true { self.quick.refresh() }
                self.scheduleEnrichment()
            }
        }
        hotKeys.onTrigger = { [weak self] id in
            if id == 2 { self?.toggleQuickPaste() } else { self?.togglePanel() }
        }
        applySettings()
        createStatusItem()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                if let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    self?.previousApplication = application
                    self?.closeDrawer(animated: true, restoreFocus: false)
                }
            }
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeDrawer(animated: true, restoreFocus: false) }
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                let held = event.modifierFlags.contains(.command)
                if self?.commandHeld != held { self?.commandHeld = held }
            }
            return event
        }
        // Short interval so one-time codes and secrets disappear close to their deadline.
        maintenance = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruneHistory(); self?.refreshPermissions() }
        }
        if defaults.integer(forKey: "linkPreviewRevision") < 2 {
            linkRefreshQueue = Set(store.items.lazy.filter { item in
                item.kind == .link && item.linkTitle != nil && item.detail != .sensitive
                    && self.store.linkIcon(for: item.id) == nil && self.store.linkImage(for: item.id) == nil
            }.map(\.id))
            defaults.set(2, forKey: "linkPreviewRevision")
        }
        monitor.start()
        installAliasMonitor()
        refreshResults()
        scheduleEnrichment()
    }

    var selectedItem: ClipItem? { store.items.first { $0.id == selectedID } }
    var shortcutLabel: String { hotKey.label }
    var onboardingDone: Bool { defaults.bool(forKey: "onboardingDone") }

    /// First launch shows the guide; afterwards the app opens straight into the drawer.
    func launch() {
        if onboardingDone { showDrawer() } else { showOnboarding() }
    }

    // MARK: Selection

    func select(_ id: UUID) {
        selectedID = id
        rangeAnchor = id
        if !multiSelection.isEmpty { multiSelection = [] }
        if compactPanel?.isKeyWindow == true { compactPanel?.makeFirstResponder(drawerHost) }
    }

    /// ⌘-click: add or remove one card, keeping click order for the paste queue.
    func toggleMultiSelect(_ id: UUID) {
        var next = multiSelection
        if next.isEmpty, let current = selectedID, current != id { next = [current] }
        if let index = next.firstIndex(of: id) {
            next.remove(at: index)
            if selectedID == id { selectedID = next.last ?? id }
        } else {
            next.append(id)
            selectedID = id
        }
        multiSelection = next.count > 1 ? next : []
        rangeAnchor = id
    }

    /// ⇧-click: select the visible range between the anchor and this card.
    func extendSelection(to id: UUID) {
        let items = filteredItems
        guard let anchor = rangeAnchor ?? selectedID,
              let from = items.firstIndex(where: { $0.id == anchor }),
              let to = items.firstIndex(where: { $0.id == id }) else { select(id); return }
        let range = (from <= to ? Array(items[from...to]) : Array(items[to...from].reversed())).map(\.id)
        let kept = multiSelection.filter { !range.contains($0) }
        multiSelection = range.count > 1 || !kept.isEmpty ? kept + range : []
        selectedID = id
    }

    func selectAllVisible() {
        let ids = filteredItems.map(\.id)
        guard ids.count > 1 else { return }
        multiSelection = ids
    }

    func clearMultiSelection() {
        if !multiSelection.isEmpty { multiSelection = [] }
    }

    /// The cards the next batch action applies to.
    private var actionIDs: [UUID] {
        if !multiSelection.isEmpty { return multiSelection }
        return selectedID.map { [$0] } ?? []
    }

    private func ensureSelection() {
        let results = filteredItems
        if !results.contains(where: { $0.id == selectedID }) {
            selectedID = results.first?.id
            selectionScrollRevision += 1
        }
        let existing = Set(store.items.map(\.id))
        let kept = multiSelection.filter { existing.contains($0) }
        if kept != multiSelection { multiSelection = kept.count > 1 ? kept : [] }
    }

    private func refreshResults() {
        guard !updatingScope else { return }
        let parsed = SearchQuery.parse(query)
        let matches = store.search(parsed.text, filter: filter, boardID: selectedBoardID)
        let now = Date()
        let range = dateFilter.range(now: now)
        let results = matches.filter { item in
            (!isFavoritesScope || item.isFavorite)
                && (sourceFilter == nil || Self.sourceKey(item) == sourceFilter)
                && (range.map { $0.contains(item.lastCopiedAt) } ?? true)
                && (!parsed.hasFilters || parsed.matches(item, now: now))
        }
        if filteredItems != results { filteredItems = results }
        ensureSelection()
    }

    func showHistory() {
        updatingScope = true
        selectedBoardID = nil; isFavoritesScope = false; filter = .history
        sourceFilter = nil; dateFilter = .all
        updatingScope = false; refreshResults()
    }

    var hasNarrowingFilters: Bool { sourceFilter != nil || dateFilter != .all || ![.history, .favorites].contains(filter) }

    func clearNarrowingFilters() {
        updatingScope = true
        sourceFilter = nil; dateFilter = .all
        if ![.history, .favorites].contains(filter) { filter = isFavoritesScope ? .favorites : .history }
        updatingScope = false; refreshResults()
    }

    static func sourceKey(_ item: ClipItem) -> String {
        if let id = item.sourceBundleID, !id.isEmpty { return id }
        return item.sourceName
    }

    /// Source apps seen in history, most frequent first, for the filter menu.
    func sourceOptions(limit: Int = 15) -> [SourceOption] {
        if let cached = sourceOptionsCache { return cached }
        var counts: [String: SourceOption] = [:]
        for item in store.items {
            let key = Self.sourceKey(item)
            guard !key.isEmpty else { continue }
            counts[key, default: SourceOption(key: key, name: item.sourceName.isEmpty ? key : item.sourceName, count: 0)].count += 1
        }
        let sorted = counts.values.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let result = Array(sorted.prefix(limit))
        sourceOptionsCache = result
        return result
    }

    func sourceName(for key: String) -> String {
        store.items.first { Self.sourceKey($0) == key }.map { $0.sourceName.isEmpty ? key : $0.sourceName } ?? key
    }

    func selectBoard(_ id: UUID?) {
        updatingScope = true
        selectedBoardID = id; isFavoritesScope = true; filter = .favorites
        updatingScope = false; refreshResults()
    }

    // MARK: Boards

    func createBoard() {
        guard let name = boardName(title: "新建收藏分类", value: "") else { return }
        do { let board = try store.createBoard(name: name); selectBoard(board.id) }
        catch { present(error) }
    }

    func renameBoard(_ board: FavoriteBoard) {
        guard let name = boardName(title: "重命名收藏分类", value: board.name) else { return }
        do { try store.renameBoard(board.id, name: name) } catch { present(error) }
    }

    func deleteBoard(_ board: FavoriteBoard) {
        let alert = NSAlert(); alert.messageText = "删除“\(board.name)”分类？"
        alert.informativeText = "分类中的内容会保留在全部收藏和历史中。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "删除分类")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            try store.removeBoard(board.id)
            if selectedBoardID == board.id { selectBoard(nil) }
        } catch { present(error) }
    }

    private func boardName(title: String, value: String) -> String? {
        let field = NSTextField(string: value)
        field.placeholderString = "例如：工作、常用回复、设计素材"
        field.frame = NSRect(x: 0, y: 0, width: 330, height: 24)
        let alert = NSAlert(); alert.messageText = title; alert.accessoryView = field
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(40))
    }

    func moveItem(_ id: UUID, to boardID: UUID?) {
        do {
            try store.assignToBoard(id, boardID: boardID)
            refreshResults()
            let name = store.boards.first(where: { $0.id == boardID })?.name ?? "全部收藏"
            setStatus("已收藏到“\(name)”")
        } catch { present(error) }
    }

    /// Batch: favorite every selected card into one board.
    func favoriteSelection(to boardID: UUID?) {
        let ids = actionIDs
        guard !ids.isEmpty else { return }
        do {
            try store.favorite(ids, boardID: boardID)
            let name = store.boards.first(where: { $0.id == boardID })?.name ?? "全部收藏"
            setStatus("已将 \(ids.count) 项收藏到“\(name)”")
            clearMultiSelection(); refreshResults()
        } catch { present(error) }
    }

    func dragProvider(for item: ClipItem) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = item.title
        provider.registerDataRepresentation(forTypeIdentifier: ClipResources.dragIdentifier, visibility: .ownProcess) { done in
            done(Data(item.id.uuidString.utf8), nil); return nil
        }
        let resources = self.resources
        for type in ClipResources.exportTypes(for: item.kind) {
            provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { done in
                let task = Task {
                    do { done(try await resources.exportData(id: item.id, type: type), nil) }
                    catch { done(nil, error) }
                }
                let progress = Progress(totalUnitCount: 1)
                progress.cancellationHandler = { task.cancel() }
                return progress
            }
        }
        return provider
    }

    // MARK: Images and icons

    func thumbnail(for item: ClipItem) async -> NSImage? {
        guard item.kind == .image else { return nil }
        let key = item.id.uuidString as NSString
        if let image = images.object(forKey: key) { return image }
        guard let cg = await resources.thumbnail(id: item.id), !Task.isCancelled else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        images.setObject(image, forKey: key)
        return image
    }

    func linkIcon(for item: ClipItem) -> NSImage? {
        guard item.kind == .link, item.linkTitle != nil else { return nil }
        let key = item.id.uuidString as NSString
        if let image = linkIcons.object(forKey: key) { return image }
        guard !missingLinkIcons.contains(item.id) else { return nil }
        guard let data = store.linkIcon(for: item.id), let image = NSImage(data: data) else {
            missingLinkIcons.insert(item.id); return nil
        }
        linkIcons.setObject(image, forKey: key)
        return image
    }

    /// The page's cover image, when the site offers one.
    func linkImage(for item: ClipItem) -> NSImage? {
        guard item.kind == .link, item.linkTitle?.isEmpty == false else { return nil }
        let key = item.id.uuidString as NSString
        if let image = linkImages.object(forKey: key) { return image }
        guard !missingLinkImages.contains(item.id) else { return nil }
        guard let data = store.linkImage(for: item.id), let image = NSImage(data: data) else {
            missingLinkImages.insert(item.id); return nil
        }
        linkImages.setObject(image, forKey: key)
        return image
    }

    /// The site icon's main color, for link cards without a cover.
    func linkTint(for item: ClipItem) -> NSColor? {
        if let cached = linkTints[item.id] { return cached }
        let color = linkIcon(for: item).flatMap(IconProvider.averageColor)
        linkTints[item.id] = color
        return color
    }

    private func forgetLinkPreview(_ id: UUID) {
        missingLinkIcons.remove(id); missingLinkImages.remove(id); linkTints[id] = nil
        linkIcons.removeObject(forKey: id.uuidString as NSString)
        linkImages.removeObject(forKey: id.uuidString as NSString)
    }

    func previewImage(for item: ClipItem) -> NSImage? {
        guard item.kind == .image else { return nil }
        let key = "preview-\(item.id.uuidString)" as NSString
        if let image = images.object(forKey: key) { return image }
        guard let entries = try? store.payload(for: item.id) else { return nil }
        for entry in entries {
            for rep in entry.representations where rep.type.contains("png") || rep.type.contains("tiff") || rep.type.contains("jpeg") {
                guard let source = CGImageSourceCreateWithData(rep.data as CFData, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                           kCGImageSourceThumbnailMaxPixelSize: 1400, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { continue }
                let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                images.setObject(image, forKey: key); return image
            }
        }
        return nil
    }

    // MARK: Background enrichment (OCR on this Mac, link titles from the link's own site)

    private func scheduleEnrichment() {
        if ocrEnabled && !ocrRunning { runNextOCR() }
        guard linkPreviewEnabled else {
            linkFetches.values.forEach { $0.task.cancel() }
            return
        }
        let pending = store.items.lazy.filter { $0.kind == .link && ($0.linkTitle == nil || self.linkRefreshQueue.contains($0.id)) }
            .filter { self.linkFetches[$0.id] == nil && !self.enrichmentAttempted.contains($0.id) }
            .prefix(max(0, 2 - linkFetches.count))
        for item in pending {
            enrichmentAttempted.insert(item.id)
            let refreshing = linkRefreshQueue.remove(item.id) != nil
            // Secrets, internal addresses and links with credentials are not fetched automatically;
            // an empty title records that, and the card menu offers a one-time fetch for the safe ones.
            guard let url = LinkPreviewService.webURL(in: item), item.detail != .sensitive,
                  LinkPreviewService.allowsAutomaticFetch(url) else {
                // A refresh leaves an existing title alone when the link may not be fetched automatically.
                if !refreshing { try? store.setLinkPreview(item.id, title: "", iconPNG: nil) }
                continue
            }
            startLinkFetch(item.id, url: url)
        }
    }

    private func startLinkFetch(_ id: UUID, url: URL, announce: Bool = false) {
        linkFetches[id]?.task.cancel()
        let token = UUID()
        let task = Task { [weak self] in
            let result = await LinkPreviewService.fetch(url)
            guard let self else { return }
            let current = self.linkFetches[id]?.token == token
            if current { self.linkFetches[id] = nil }
            // Cancelled when the setting is turned off or the link was edited; a cancelled fetch may be retried later.
            guard current, !Task.isCancelled, self.linkPreviewEnabled else {
                if current { self.enrichmentAttempted.remove(id) }
                return
            }
            // The link may have been edited meanwhile: the old page's title must not land on the new link.
            guard let item = self.store.items.first(where: { $0.id == id }), LinkPreviewService.webURL(in: item) == url else {
                self.scheduleEnrichment(); return
            }
            // A refresh that fails keeps the preview already shown.
            let hadTitle = item.linkTitle?.isEmpty == false
            if !(hadTitle && result.title.isEmpty) {
                self.forgetLinkPreview(id)
                try? self.store.setLinkPreview(id, title: result.title, iconPNG: result.icon, imageJPEG: result.image)
            }
            if announce {
                self.hud.show(result.title.isEmpty ? "未能获取链接预览" : "已更新链接预览",
                              symbol: result.title.isEmpty ? "exclamationmark.triangle" : "link", duration: 1.6)
            }
            self.scheduleEnrichment()
        }
        linkFetches[id] = (token, task)
    }

    /// Links skipped by the automatic rules (or whose fetch failed) can be fetched on request,
    /// and fetched ones refreshed (links saved before 0.7 have no cover image yet).
    func canFetchLinkPreview(_ item: ClipItem) -> Bool {
        linkPreviewEnabled && item.kind == .link && item.linkTitle != nil && item.detail != .sensitive
            && linkFetches[item.id] == nil && LinkPreviewService.webURL(in: item) != nil
    }

    func fetchLinkPreview(_ id: UUID) {
        guard let item = store.items.first(where: { $0.id == id }), canFetchLinkPreview(item),
              let url = LinkPreviewService.webURL(in: item) else { return }
        enrichmentAttempted.insert(id)
        startLinkFetch(id, url: url, announce: true)
    }

    private func runNextOCR() {
        guard ocrEnabled, let item = store.items.first(where: {
            $0.kind == .image && $0.ocrText == nil && !enrichmentAttempted.contains($0.id)
        }) else { ocrRunning = false; return }
        ocrRunning = true
        enrichmentAttempted.insert(item.id)
        let resources = self.resources
        Task { [weak self] in
            var text = ""
            if let image = await resources.ocrImage(id: item.id) { text = await OCRService.recognize(image) }
            guard let self else { return }
            try? self.store.setOCRText(item.id, text: String(text.prefix(20_000)))
            self.runNextOCR()
        }
    }

    // MARK: Using clips

    func useSelected(plainText requested: Bool = false, copyOnly: Bool = false, transform: TextTransform? = nil) {
        if multiSelection.count > 1, !copyOnly, transform == nil { startPasteQueue(); return }
        guard let item = selectedItem else { NSSound.beep(); return }
        // With plain text as the default (always, or for the target app), the plain-text modifier asks for the formatting.
        let plainText = transform != nil || (pastesPlainText(item) ? !requested : requested)
        do {
            if plainText && item.text.isEmpty { setStatus("这条内容没有可粘贴的文本。"); return }
            let payload = try store.payload(for: item.id)
            var text = plainText ? (ClipboardMonitor.fullText(from: payload) ?? item.text) : nil
            if let transform {
                guard let converted = text.flatMap(transform.apply) else { setStatus("这条内容无法\(transform.title)。"); return }
                text = converted
            }
            var cursorBack = 0
            if transform == nil, let expanded = expandedSnippet(item, payload: payload) {
                text = expanded.text; cursorBack = expanded.cursorFromEnd
            }
            try pasteService.write(payload, plainText: text)
            monitor.markOwnWrite()
            refreshPermissions()
            guard !copyOnly else { setStatus(transform.map { "已复制 · \($0.title)" } ?? "已复制"); return }
            guard accessibilityGranted else {
                closeDrawer(animated: true, restoreFocus: true)
                hud.show("已复制，按 ⌘V 粘贴", symbol: "command", duration: 2.2)
                return
            }
            guard let previousApplication, !previousApplication.isTerminated else {
                setStatus("已复制，请切换到目标应用后按 ⌘V。"); return
            }
            // Text goes straight in only when an input has focus; otherwise just copy.
            // Images and files keep pasting, since canvases and Finder accept them without a text field.
            if item.kind != .image, item.kind != .files,
               PasteService.focusedTextInput(in: previousApplication.processIdentifier) == false {
                closeDrawer(animated: true, restoreFocus: true)
                hud.show("已复制", symbol: "doc.on.doc", duration: 1.6)
                return
            }
            pastingID = item.id
            hideWindows()
            let label = transform.map { "已粘贴 · \($0.title)" } ?? (plainText ? "已粘贴 · 纯文本" : "已粘贴")
            pasteService.paste(into: previousApplication, cursorBack: cursorBack) { [weak self] sent in
                if sent { self?.hud.show(label) }
                else {
                    self?.showPanel(rememberTarget: false)
                    self?.setStatus("已复制；未能切换到目标应用，请手动按 ⌘V。")
                }
            }
        } catch { present(error) }
    }

    /// Snippets made in 轻贴 may contain variables; copied content is pasted verbatim.
    private func expandedSnippet(_ item: ClipItem, payload: [ClipboardEntry]) -> (text: String, cursorFromEnd: Int)? {
        guard item.kind == .text, item.sourceBundleID == Bundle.main.bundleIdentifier,
              let full = ClipboardMonitor.fullText(from: payload), SnippetExpander.hasVariables(full) else { return nil }
        return SnippetExpander.expand(full, clipboard: NSPasteboard.general.string(forType: .string))
    }

    // MARK: Aliases

    /// A card renamed to “;” plus letters, digits, “-” or “_” is an alias: typing it in another app
    /// replaces it with the card. Only the characters after a “;” are kept, and only until they stop matching.
    static func isAlias(_ title: String) -> Bool {
        title.count >= 2 && title.count <= 32 && title.first == ";"
            && title.dropFirst().allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private func aliasItem(_ typed: String) -> ClipItem? {
        store.items.first { $0.title == typed && Self.isAlias($0.title) && $0.title != HistoryStore.automaticTitle($0.text) }
    }

    /// Global key monitors only receive events once Accessibility is granted, so this is retried as it changes.
    private func installAliasMonitor() {
        guard aliasMonitor == nil, accessibilityGranted else { return }
        aliasMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.aliasKeyDown(event) }
        }
    }

    private func aliasKeyDown(_ event: NSEvent) {
        guard !PasteService.isSynthetic(event) else { return }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { aliasTyped = nil; return }
        let characters = event.characters ?? ""
        if characters == ";" || characters == "；" { aliasTyped = (";", pid); return }
        guard var typed = aliasTyped, typed.pid == pid else { aliasTyped = nil; return }
        if event.keyCode == 51 {
            typed.text.removeLast()
            aliasTyped = typed.text.isEmpty ? nil : typed
            return
        }
        guard characters.count == 1, let character = characters.first, character.isASCII,
              character.isLetter || character.isNumber || character == "-" || character == "_",
              typed.text.count < 32 else { aliasTyped = nil; return }
        typed.text.append(character)
        aliasTyped = typed
        if let item = aliasItem(typed.text) { aliasTyped = nil; expandAlias(item, typedCount: typed.text.count) }
    }

    private func expandAlias(_ item: ClipItem, typedCount: Int) {
        guard let target = NSWorkspace.shared.frontmostApplication,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !Self.bundleIDs(in: excludedAppsText).contains(target.bundleIdentifier ?? "") else { return }
        do {
            let payload = try store.payload(for: item.id)
            let expanded = expandedSnippet(item, payload: payload)
            try pasteService.write(payload, plainText: expanded?.text)
            monitor.markOwnWrite()
            pasteService.deleteBackward(typedCount)
            pasteService.paste(into: target, cursorBack: expanded?.cursorFromEnd ?? 0) { _ in }
        } catch { present(error) }
    }

    /// Paste several cards one by one: each ⌘V in the target app loads the next card.
    func startPasteQueue() {
        let ids = actionIDs
        guard ids.count > 1 else { useSelected(); return }
        refreshPermissions()
        guard accessibilityGranted else {
            setStatus("按顺序粘贴需要辅助功能权限，可在设置中开启。"); return
        }
        endPasteQueue(message: nil)
        queueIDs = ids
        clearMultiSelection()
        guard writeQueueItem(at: 0) else { endPasteQueue(message: nil); return }
        queueMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
                // 轻贴's own ⌘V advances from its completion below; a held ⌘V repeats are not new pastes.
                if event.keyCode == 9, flags == .command, !event.isARepeat, !PasteService.isSynthetic(event) {
                    self.queuePasted(index: self.queueProgress?.index)
                } else if event.keyCode == 53 {
                    self.endPasteQueue(message: "已结束按顺序粘贴")
                }
            }
        }
        if let previousApplication, !previousApplication.isTerminated {
            hideWindows()
            pasteService.paste(into: previousApplication) { [weak self] sent in
                guard sent else { self?.hud.show("队列 1/\(ids.count) · 按 ⌘V 粘贴", symbol: "list.number", duration: 3); return }
                self?.queuePasted(index: 0)
            }
        } else {
            closeDrawer(animated: true, restoreFocus: true)
            hud.show("队列 1/\(ids.count) · 按 ⌘V 粘贴", symbol: "list.number", duration: 3)
        }
    }

    /// A ⌘V reached the target while card `index` was on the clipboard. The next card is written after a
    /// short wait, so the target reads this one first; a second report for the same card changes nothing.
    private func queuePasted(index: Int?) {
        guard let index else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.queueAdvanceDelay) { [weak self] in
            self?.advancePasteQueue(from: index)
        }
    }

    static let queueAdvanceDelay: TimeInterval = 0.2

    /// Moves on only from the card that was pasted, so a repeated or late-seen ⌘V cannot skip one.
    private func advancePasteQueue(from index: Int) {
        guard let progress = queueProgress, progress.index == index else { return }
        let next = progress.index + 1
        if next >= progress.total { endPasteQueue(message: "已按顺序粘贴 \(progress.total) 项"); return }
        if writeQueueItem(at: next) {
            hud.show("已粘贴 \(next)/\(progress.total)，下一项已就绪", symbol: "list.number", duration: 2)
        } else {
            endPasteQueue(message: "队列中的内容已不存在")
        }
    }

    /// Text-like clips only; images and files always keep their original data.
    private static func prefersPlainText(_ item: ClipItem) -> Bool {
        !item.text.isEmpty && (item.kind == .text || item.kind == .link || item.kind == .other)
    }

    /// Plain text is the default for this clip: always, or because the target app is on the plain-text list.
    private func pastesPlainText(_ item: ClipItem) -> Bool {
        guard Self.prefersPlainText(item) else { return false }
        if alwaysPlainText { return true }
        guard let target = previousApplication?.bundleIdentifier else { return false }
        return Self.bundleIDs(in: plainTextAppsText).contains(target)
    }

    var targetPastesPlainText: Bool {
        previousApplication?.bundleIdentifier.map { Self.bundleIDs(in: plainTextAppsText).contains($0) } ?? false
    }

    /// The conversions offered under “粘贴为” for a text clip.
    func transforms(for item: ClipItem) -> [TextTransform] {
        guard Self.prefersPlainText(item) else { return [] }
        return TextTransform.available(for: item.text)
    }

    func paste(_ id: UUID, as transform: TextTransform) {
        select(id)
        useSelected(transform: transform)
    }

    /// Joins the selected cards' text in selection order, keeps the result as a new clip and pastes it.
    /// Images have no text and are left out.
    func pasteMerged(separator: String) {
        let ids = actionIDs
        guard ids.count > 1 else { return }
        var parts: [String] = []
        var skipped = 0
        for id in ids {
            guard let item = store.items.first(where: { $0.id == id }) else { continue }
            let text: String
            switch item.kind {
            case .image: skipped += 1; continue
            case .files: text = item.text
            default: text = (try? store.payload(for: id)).flatMap(ClipboardMonitor.fullText(from:)) ?? item.text
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { skipped += 1 } else { parts.append(trimmed) }
        }
        guard !parts.isEmpty else { setStatus("选中的内容里没有可合并的文字。"); return }
        // A comma follows the text: “，” between Chinese items, “, ” otherwise.
        let chinese = parts.contains { $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }
        let merged = parts.joined(separator: separator == "," ? (chinese ? "，" : ", ") : separator)
        do {
            // Not marked as made in 轻贴, so {日期}-style text from copied content is never expanded.
            let clip = CapturedClip(entries: [ClipboardEntry(representations: [.init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(merged.utf8))])],
                                    kind: .text, title: HistoryStore.automaticTitle(merged), text: String(merged.prefix(131_072)),
                                    sourceName: "轻贴 · 合并", sourceBundleID: nil,
                                    containsSecret: ContentDetector.isSensitive(merged))
            let item = try store.capture(clip)
            clearMultiSelection()
            if isFavoritesScope || hasNarrowingFilters || !query.isEmpty { query = ""; showHistory() }
            refreshResults(); select(item.id); selectionScrollRevision += 1
            if skipped > 0 { setStatus("已合并 \(parts.count) 项，跳过 \(skipped) 项没有文字的内容") }
            useSelected()
        } catch { present(error) }
    }

    @discardableResult
    private func writeQueueItem(at index: Int) -> Bool {
        guard queueIDs.indices.contains(index), let payload = try? store.payload(for: queueIDs[index]) else { return false }
        let item = store.items.first { $0.id == queueIDs[index] }
        let plain = item.map(pastesPlainText) == true ? (ClipboardMonitor.fullText(from: payload) ?? item?.text) : nil
        guard (try? pasteService.write(payload, plainText: plain)) != nil else { return false }
        monitor.markOwnWrite()
        queueProgress = (index, queueIDs.count)
        return true
    }

    private func endPasteQueue(message: String?) {
        if let queueMonitor { NSEvent.removeMonitor(queueMonitor); self.queueMonitor = nil }
        let wasRunning = queueProgress != nil
        queueProgress = nil; queueIDs = []
        if wasRunning, let message { hud.show(message, symbol: "checkmark.circle.fill", duration: 1.6) }
    }

    func toggleFavorite(_ id: UUID) {
        do { try store.toggleFavorite(id); refreshResults() } catch { present(error) }
    }

    func deleteItem(_ id: UUID) {
        guard store.items.contains(where: { $0.id == id }) else { return }
        if multiSelection.contains(id) { deleteSelection(); return }
        let alert = NSAlert()
        alert.messageText = "删除这条内容？"
        alert.informativeText = "内容会从轻贴的本地历史和收藏中移除，此操作无法撤销。系统剪贴板不会被清空。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "删除")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try store.remove(id); images.removeObject(forKey: id.uuidString as NSString); ensureSelection() } catch { present(error) }
    }

    func deleteSelection() {
        let ids = actionIDs
        guard !ids.isEmpty else { return }
        if ids.count == 1 { multiSelection = []; deleteItem(ids[0]); return }
        let alert = NSAlert()
        alert.messageText = "删除选中的 \(ids.count) 项内容？"
        alert.informativeText = "内容会从轻贴的本地历史和收藏中移除，此操作无法撤销。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "删除 \(ids.count) 项")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            try store.remove(Set(ids))
            ids.forEach { images.removeObject(forKey: $0.uuidString as NSString) }
            multiSelection = []; ensureSelection()
            setStatus("已删除 \(ids.count) 项")
        } catch { present(error) }
    }

    func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "清空未收藏的历史？"
        alert.informativeText = "收藏会保留。其他历史将永久删除，此操作无法撤销。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "清空历史")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try store.clearUnfavorited(); images.removeAllObjects(); ensureSelection() } catch { present(error) }
    }

    func renameItem(_ id: UUID) {
        guard let item = store.items.first(where: { $0.id == id }) else { return }
        let field = NSTextField(string: item.title)
        field.frame = NSRect(x: 0, y: 0, width: 330, height: 24)
        let alert = NSAlert(); alert.messageText = "重命名内容"; alert.accessoryView = field
        alert.informativeText = "名称以英文分号开头（如 ;gh）即成为别名：在其他应用输入它，会自动替换成这条内容。"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do { try store.rename(id, title: String(title.prefix(160))) } catch { present(error) }
    }

    // MARK: Editing, copies, opening and sharing

    func canEdit(_ item: ClipItem) -> Bool { item.kind == .text || item.kind == .link }

    func editItem(_ id: UUID) {
        if let editor = editors[id] { editor.show(); return }
        guard let item = store.items.first(where: { $0.id == id }), canEdit(item) else { return }
        do {
            let content = ItemEditorController.attributedContent(from: try store.payload(for: id), fallback: item.text)
            closeDrawer(animated: true, restoreFocus: false)
            let editor = ItemEditorController(itemID: id, title: item.title, content: content, onSave: { [weak self] text in
                self?.saveEdit(id, text: text) ?? false
            }, onClose: { [weak self] in
                self?.editors[id] = nil
            })
            editors[id] = editor
            editor.show()
        } catch { present(error) }
    }

    private func saveEdit(_ id: UUID, text: NSAttributedString) -> Bool {
        do {
            try store.updateContent(id, entries: ItemEditorController.entries(for: text), text: text.string)
            // A preview still loading for the old link must not be written back to the edited one.
            linkFetches.removeValue(forKey: id)?.task.cancel()
            images.removeObject(forKey: id.uuidString as NSString)
            enrichmentAttempted.remove(id); forgetLinkPreview(id)
            scheduleEnrichment()
            hud.show("已保存修改")
            return true
        } catch {
            let alert = NSAlert(); alert.messageText = "无法保存修改"; alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
    }

    func duplicateItem(_ id: UUID) {
        do {
            let copy = try store.duplicate(id)
            if isFavoritesScope || hasNarrowingFilters { showHistory() }
            refreshResults(); select(copy.id); selectionScrollRevision += 1
            setStatus("已创建副本")
        } catch { present(error) }
    }

    /// Web links and files that still exist; nil for content that has nothing to open.
    func openableURLs(for item: ClipItem) -> [URL]? {
        switch item.kind {
        case .link:
            return LinkPreviewService.webURL(in: item).map { [$0] }
        case .files:
            let urls = item.text.components(separatedBy: .newlines).filter { !$0.isEmpty }
                .map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            return urls.isEmpty ? nil : urls
        default:
            return nil
        }
    }

    func openItem(_ id: UUID, with application: URL? = nil) {
        guard let item = store.items.first(where: { $0.id == id }), let urls = openableURLs(for: item) else {
            setStatus("这条内容没有可打开的链接或文件。"); NSSound.beep(); return
        }
        closeDrawer(animated: true, restoreFocus: false)
        let configuration = NSWorkspace.OpenConfiguration()
        let hud = self.hud
        let done: @Sendable (NSRunningApplication?, Error?) -> Void = { _, error in
            guard let message = error?.localizedDescription else { return }
            Task { @MainActor in hud.show("无法打开：\(message)", symbol: "exclamationmark.triangle", duration: 2.4) }
        }
        if let application {
            NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: configuration, completionHandler: done)
        } else {
            for url in urls { NSWorkspace.shared.open(url, configuration: configuration, completionHandler: done) }
        }
    }

    /// The default app first, then other apps that can open the first URL.
    func applications(toOpen item: ClipItem, limit: Int = 12) -> [URL] {
        guard let url = openableURLs(for: item)?.first else { return [] }
        let preferred = NSWorkspace.shared.urlForApplication(toOpen: url)
        var result = preferred.map { [$0] } ?? []
        for app in NSWorkspace.shared.urlsForApplications(toOpen: url) where !result.contains(app) && result.count < limit {
            result.append(app)
        }
        return result
    }

    func revealItem(_ id: UUID) {
        guard let item = store.items.first(where: { $0.id == id }), item.kind == .files,
              let urls = openableURLs(for: item) else { return }
        closeDrawer(animated: true, restoreFocus: false)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func openSelected() {
        guard let id = selectedID else { return }
        openItem(id)
    }

    /// What the system share menu receives: the link, the files, the image or the full text.
    func shareItems(for item: ClipItem) -> [Any] {
        switch item.kind {
        case .link, .files:
            return openableURLs(for: item) ?? [item.text]
        case .image:
            return previewImage(for: item).map { [$0] } ?? []
        default:
            let full = (try? store.payload(for: item.id)).flatMap(ClipboardMonitor.fullText(from:)) ?? item.text
            return full.isEmpty ? [] : [full]
        }
    }

    func createTextItem() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 170))
        let editor = NSTextView(frame: scroll.bounds)
        editor.isRichText = false; editor.font = .systemFont(ofSize: 14)
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isVerticallyResizable = true; scroll.documentView = editor; scroll.hasVerticalScroller = true
        let alert = NSAlert(); alert.messageText = "新建常用文本"
        alert.informativeText = "保存一段常用内容，之后可搜索或收藏。可插入变量：{日期}、{时间}、{剪贴板}，用 {光标} 标记粘贴后光标的位置。"
        alert.accessoryView = scroll; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = editor
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = editor.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let title = String(text.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(120) ?? "文本".prefix(120))
        do {
            let clip = CapturedClip(entries: [ClipboardEntry(representations: [.init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))])],
                                    kind: .text, title: title, text: text, sourceName: "轻贴", sourceBundleID: Bundle.main.bundleIdentifier)
            let item = try store.capture(clip)
            if isFavoritesScope {
                try store.assignToBoard(item.id, boardID: selectedBoardID)
                selectBoard(selectedBoardID)
            } else { showHistory() }
            query = ""; refreshResults(); select(item.id); selectionScrollRevision += 1
        } catch { present(error) }
    }

    // MARK: Settings

    func togglePause() { capturePaused ? resumeCapture() : pauseCapture(for: nil) }

    /// Pause recording; with a duration it resumes by itself, nil waits for the user.
    func pauseCapture(for duration: TimeInterval?) {
        pauseTimer?.invalidate(); pauseTimer = nil
        capturePaused = true; monitor.paused = true
        pausedUntil = duration.map { Date().addingTimeInterval($0) }
        if let pausedUntil {
            let timer = Timer(fire: pausedUntil, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeCapture() }
            }
            RunLoop.main.add(timer, forMode: .common); pauseTimer = timer
        }
        rebuildStatusMenu()
    }

    func resumeCapture() {
        pauseTimer?.invalidate(); pauseTimer = nil
        capturePaused = false; monitor.paused = false; pausedUntil = nil
        rebuildStatusMenu()
    }

    /// "已暂停记录" plus the resume time for a timed pause.
    var pauseLabel: String {
        guard let pausedUntil else { return "已暂停记录" }
        let sameDay = Calendar.current.isDateInToday(pausedUntil)
        return "已暂停记录，\(sameDay ? "" : "明天 ")\(pausedUntil.formatted(date: .omitted, time: .shortened)) 恢复"
    }

    static let pauseChoices: [(title: String, seconds: TimeInterval?)] = [
        ("15 分钟", 15 * 60), ("1 小时", 3600), ("8 小时", 8 * 3600), ("直到手动继续", nil)
    ]

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            setStatus(enabled ? "无法设置开机启动：\(error.localizedDescription)" : "无法取消开机启动：\(error.localizedDescription)")
        }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if enabled, status == .requiresApproval {
            setStatus("请在“系统设置 → 通用 → 登录项”中允许轻贴。")
            SMAppService.openSystemSettingsLoginItems()
        }
    }
    func storageLocation() -> URL { directory }

    static let backupType = UTType("com.local.lightpaste.favorites") ?? UTType(filenameExtension: "lightpaste") ?? .data

    /// Saves every favorite, with its boards, to a file the user picks.
    func exportFavorites() {
        do {
            let export = try store.exportFavorites()
            guard export.count > 0 else { setStatus("还没有收藏，无需导出。"); return }
            let alert = NSAlert()
            alert.messageText = "导出 \(export.count) 条收藏？"
            alert.informativeText = "备份文件没有加密，任何拿到文件的人都能看到内容"
                + (export.sensitive > 0 ? "，其中包含 \(export.sensitive) 条敏感内容" : "") + "。请妥善保管。"
            alert.addButton(withTitle: "继续导出"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [Self.backupType]
            panel.nameFieldStringValue = "轻贴收藏 \(Date().formatted(.iso8601.year().month().day())).lightpaste"
            activate()
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try export.data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            setStatus("已导出 \(export.count) 条收藏")
        } catch { present(error) }
    }

    func importFavorites() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.backupType]
        panel.allowsMultipleSelection = false
        activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try store.importFavorites(try Data(contentsOf: url))
            refreshResults()
            var parts = ["新增 \(result.added) 条"]
            if result.updated > 0 { parts.append("\(result.updated) 条已在历史中，已设为收藏") }
            if result.boardsCreated > 0 { parts.append("新建 \(result.boardsCreated) 个分类") }
            setStatus("已导入收藏：" + parts.joined(separator: "，"))
        } catch { present(error) }
    }
    func refreshPermissions() {
        let granted = AXIsProcessTrusted()
        if accessibilityGranted != granted { accessibilityGranted = granted }
        installAliasMonitor()
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        if !accessibilityGranted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func saveSettings() {
        retentionDays = min(3650, max(0, retentionDays)); maxItems = min(20000, max(100, maxItems))
        defaults.set(retentionDays, forKey: "retentionDays"); defaults.set(maxItems, forKey: "maxItems")
        defaults.set(excludedAppsText, forKey: "excludedApps")
        defaults.set(drawerEdge.rawValue, forKey: "drawerEdge"); defaults.set(cardSize.rawValue, forKey: "cardSize")
        defaults.set(linkPreviewEnabled, forKey: "linkPreview"); defaults.set(ocrEnabled, forKey: "ocr")
        defaults.set(sensitiveMinutes, forKey: "sensitiveMinutes")
        defaults.set(alwaysPlainText, forKey: "alwaysPlainText"); defaults.set(hideDuringScreenShare, forKey: "hideDuringScreenShare")
        defaults.set(plainTextAppsText, forKey: "plainTextApps")
        applySettings()
        scheduleEnrichment()
    }

    /// Registers a recorded shortcut; on conflict the previous one is restored and false is returned.
    @discardableResult
    func setHotKey(_ spec: HotKeySpec) -> Bool {
        // Recording released both shortcuts; whatever happens, both are registered again afterwards.
        defer { resumeHotKey() }
        guard spec != quickHotKey, hotKeys.register(spec) else {
            setStatus("\(spec.label) 已被其他应用占用，请换一个组合。")
            return false
        }
        registeredHotKey = spec; hotKey = spec
        defaults.set(Int(spec.keyCode), forKey: "hotKeyCode"); defaults.set(Int(spec.carbonModifiers), forKey: "hotKeyModifiers")
        rebuildStatusMenu()
        return true
    }

    /// While recording, the current shortcut must not fire.
    func setQuickHotKey(_ spec: HotKeySpec) -> Bool {
        defer { resumeHotKey() }
        guard spec != hotKey, hotKeys.register(spec, id: 2) else { return false }
        registeredQuickHotKey = spec; quickHotKey = spec
        defaults.set(Int(spec.keyCode), forKey: "quickHotKeyCode"); defaults.set(Int(spec.carbonModifiers), forKey: "quickHotKeyModifiers")
        rebuildStatusMenu()
        return true
    }

    func suspendHotKey() { hotKeys.unregister() }
    func resumeHotKey() {
        if let registeredHotKey { hotKeys.register(registeredHotKey) }
        if let registeredQuickHotKey { hotKeys.register(registeredQuickHotKey, id: 2) }
    }

    private func applySettings() {
        store.maximumItems = maxItems
        store.sensitiveLifetime = sensitiveMinutes > 0 ? TimeInterval(sensitiveMinutes * 60) : nil
        monitor.excludedBundleIDs = Self.bundleIDs(in: excludedAppsText)
        applySharingType()
        if registeredHotKey != hotKey {
            if hotKeys.register(hotKey) { registeredHotKey = hotKey }
            else {
                setStatus("这个快捷键已被占用，请在设置中录制其他组合。")
                if let registeredHotKey { hotKeys.register(registeredHotKey); hotKey = registeredHotKey }
            }
        }
        if registeredQuickHotKey != quickHotKey, quickHotKey != hotKey {
            if hotKeys.register(quickHotKey, id: 2) { registeredQuickHotKey = quickHotKey }
            else { setStatus("光标处粘贴的快捷键 \(quickHotKey.label) 已被占用，请在设置中录制其他组合。") }
        }
        pruneHistory(); rebuildStatusMenu()
    }

    static func bundleIDs(in text: String) -> Set<String> {
        Set(text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，;；"))).filter { !$0.isEmpty })
    }

    /// Keeps the drawer and preview out of screen sharing, recordings and screenshots when asked.
    private func applySharingType() {
        let type: NSWindow.SharingType = hideDuringScreenShare ? .none : .readOnly
        compactPanel?.sharingType = type; previewWindow?.sharingType = type; quickPanel?.sharingType = type
    }

    private func pruneHistory() {
        // 0 keeps history until the item limit is reached.
        let cutoff = retentionDays > 0 ? Date().addingTimeInterval(-Double(retentionDays) * 86400) : .distantPast
        do { try store.prune(olderThan: cutoff, maxItems: maxItems) }
        catch { present(error) }
    }

    // MARK: Windows

    func showSettings() {
        closeDrawer(animated: true, restoreFocus: false)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "轻贴设置"; window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
            window.contentView = NSHostingView(rootView: SettingsView(controller: self))
            window.center(); settingsWindow = window
        }
        activate(); settingsWindow?.makeKeyAndOrderFront(nil); refreshPermissions()
    }

    func showOnboarding() {
        closeDrawer(animated: false, restoreFocus: false)
        if onboardingWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "欢迎使用轻贴"; window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
            window.contentView = NSHostingView(rootView: OnboardingView(controller: self))
            window.center(); onboardingWindow = window
        }
        activate(); onboardingWindow?.makeKeyAndOrderFront(nil); refreshPermissions()
    }

    func finishOnboarding(openDrawer: Bool) {
        defaults.set(true, forKey: "onboardingDone")
        onboardingWindow?.orderOut(nil)
        if openDrawer { showPanel(rememberTarget: false) }
    }

    func hideWindows() { closeDrawer(animated: true, restoreFocus: false); previewWindow?.orderOut(nil) }
    func showDrawer() { showPanel() }
    func dismissDrawer() { closeDrawer(animated: true, restoreFocus: true) }
    func togglePanel() {
        if compactPanel?.isVisible == true, !isClosingDrawer { dismissDrawer() }
        else { showPanel() }
    }

    private func makeDrawerPanel() -> ClipboardWindow {
        let window = ClipboardWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 340),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "轻贴 · 抽屉"
        window.level = .statusBar; window.isOpaque = false; window.backgroundColor = .clear
        window.hasShadow = true; window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Native material under SwiftUI: the drawer reads as part of macOS, not a pasted-on window.
        let effect = NSVisualEffectView()
        effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = DS.Radius.panel; effect.layer?.masksToBounds = true
        let host = DrawerHostingView(rootView: DrawerView(controller: self))
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        window.contentView = effect
        host.frame = effect.bounds
        window.handleKey = { [weak self, weak window] event in self?.handleKey(event, window: window) ?? false }
        drawerHost = host; drawerEffect = effect
        window.sharingType = hideDuringScreenShare ? .none : .readOnly
        return window
    }

    private func showPanel(rememberTarget: Bool = true) {
        if rememberTarget { self.rememberTarget() }
        settingsWindow?.orderOut(nil)
        if compactPanel == nil { compactPanel = makeDrawerPanel() }
        // Only the edge facing the screen center is rounded.
        drawerEffect?.layer?.maskedCorners = drawerEdge == .bottom
            ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main,
           let compactPanel {
            let frames = DrawerGeometry.frames(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                               edge: drawerEdge, height: cardSize.drawerHeight)
            drawerFrames = frames
            let openingFromHidden = !compactPanel.isVisible || isClosingDrawer
            drawerAnimationID += 1; isClosingDrawer = false
            pastingID = nil
            if openingFromHidden { compactPanel.setFrame(frames.hidden, display: false); drawerRevision += 1 }
            activate(); compactPanel.makeKeyAndOrderFront(nil)
            compactPanel.makeFirstResponder(drawerHost)
            commandHeld = NSEvent.modifierFlags.contains(.command)
            NotificationCenter.default.post(name: Notification.Name("LightPasteDrawerShown"), object: compactPanel)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DS.Motion.reduced ? 0 : DS.Motion.open
                context.timingFunction = DS.Motion.openCurve
                compactPanel.animator().setFrame(frames.shown, display: true)
            }
        }
        refreshPermissions(); ensureSelection()
    }

    private func closeDrawer(animated: Bool, restoreFocus: Bool) {
        if quickPanel?.isVisible == true {
            quickPanel?.orderOut(nil)
            if restoreFocus, compactPanel?.isVisible != true, let previousApplication, !previousApplication.isTerminated {
                previousApplication.activate(options: [])
            }
        }
        guard let panel = compactPanel, panel.isVisible else { return }
        if isClosingDrawer {
            if !animated { drawerAnimationID += 1; panel.orderOut(nil); isClosingDrawer = false }
            return
        }
        previewWindow?.orderOut(nil)
        drawerAnimationID += 1
        let token = drawerAnimationID
        isClosingDrawer = true
        commandHeld = false
        if restoreFocus, let previousApplication, !previousApplication.isTerminated { previousApplication.activate(options: []) }
        guard animated, let frames = drawerFrames, !DS.Motion.reduced else {
            panel.orderOut(nil); isClosingDrawer = false; return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.close
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(frames.hidden, display: true)
        } completionHandler: { [weak self, weak panel] in
            MainActor.assumeIsolated {
                guard let self, self.drawerAnimationID == token else { return }
                panel?.orderOut(nil); self.isClosingDrawer = false
            }
        }
    }

    // MARK: Quick paste at the cursor

    func toggleQuickPaste() {
        if quickPanel?.isVisible == true { closeDrawer(animated: false, restoreFocus: true) }
        else { showQuickPaste() }
    }

    private func showQuickPaste() {
        closeDrawer(animated: false, restoreFocus: false)
        previewWindow?.orderOut(nil)
        rememberTarget()
        // Read the caret before 轻贴 takes focus; afterwards the target app reports no focused field.
        let caret = previousApplication.flatMap { PasteService.caretRect(in: $0.processIdentifier) }
        quick.query = ""
        quick.refresh()
        if quickPanel == nil { quickPanel = makeQuickPanel() }
        guard let panel = quickPanel else { return }
        panel.setFrame(quickPanelFrame(near: caret), display: false)
        refreshPermissions()
        activate(); panel.makeKeyAndOrderFront(nil)
        // The SwiftUI field exists after the first layout pass.
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, let root = panel.contentView, let field = self.editableField(in: root) else { return }
            panel.makeFirstResponder(field)
        }
    }

    private func makeQuickPanel() -> ClipboardWindow {
        let size = QuickPasteView.size
        let window = ClipboardWindow(contentRect: NSRect(origin: .zero, size: size),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "轻贴 · 光标处粘贴"
        window.level = .statusBar; window.isOpaque = false; window.backgroundColor = .clear
        window.hasShadow = true; window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = DS.Radius.panel; effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: QuickPasteView(controller: self, model: quick))
        host.frame = effect.bounds; host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        window.contentView = effect
        window.handleKey = { [weak self, weak window] event in self?.handleQuickKey(event, window: window) ?? false }
        window.sharingType = hideDuringScreenShare ? .none : .readOnly
        return window
    }

    /// Just below the caret (above it near the bottom of the screen); at the pointer when the caret is unknown.
    private func quickPanelFrame(near caret: CGRect?) -> CGRect {
        let size = QuickPasteView.size
        let anchor = caret ?? CGRect(origin: NSEvent.mouseLocation, size: .zero)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor.insetBy(dx: -1, dy: -1)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(origin: .zero, size: size)
        var origin = CGPoint(x: anchor.minX - 14, y: anchor.minY - size.height - 6)
        if origin.y < visible.minY { origin.y = anchor.maxY + 6 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        return CGRect(origin: origin, size: size)
    }

    func pasteFromQuickPaste(_ id: UUID, plainText: Bool = false) {
        guard store.items.contains(where: { $0.id == id }) else { NSSound.beep(); return }
        selectedID = id
        if !multiSelection.isEmpty { multiSelection = [] }
        useSelected(plainText: plainText)
    }

    private func handleQuickKey(_ event: NSEvent, window: NSWindow?) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let numberKeys: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        if modifiers == .command || modifiers == [.command, .shift], let number = numberKeys[event.keyCode] {
            let results = quick.results
            guard results.indices.contains(number - 1) else { return true }
            pasteFromQuickPaste(results[number - 1].id, plainText: modifiers.contains(.shift)); return true
        }
        guard modifiers.isEmpty || modifiers == .shift else { return false }
        switch event.keyCode {
        case 53:
            if !quick.query.isEmpty { quick.query = "" } else { closeDrawer(animated: false, restoreFocus: true) }
            return true
        case 125, 126:
            quick.move(by: event.keyCode == 125 ? 1 : -1); return true
        case 36, 76:
            guard let id = quick.selectedID else { NSSound.beep(); return true }
            pasteFromQuickPaste(id, plainText: modifiers.contains(.shift)); return true
        default:
            // Typing always searches, even if the field has not taken focus yet.
            let isEditing = (window?.firstResponder as? NSTextView)?.isEditable == true
            if !isEditing, let characters = event.characters, !characters.isEmpty,
               characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
               let root = window?.contentView, let field = editableField(in: root) {
                window?.makeFirstResponder(field)
                (window?.firstResponder as? NSTextView)?.interpretKeyEvents([event])
                return true
            }
            return false
        }
    }

    func showItemPreview() {
        guard selectedItem != nil else { return }
        if previewWindow?.isVisible == true { previewWindow?.orderOut(nil); compactPanel?.makeKeyAndOrderFront(nil); return }
        if previewWindow == nil {
            let preview = ClipboardWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
                                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            preview.title = "内容预览"; preview.isReleasedWhenClosed = false; preview.level = .statusBar; preview.hidesOnDeactivate = false
            preview.titlebarAppearsTransparent = true
            preview.contentView = NSHostingView(rootView: ItemPreviewView(controller: self))
            preview.handleKey = { [weak self, weak preview] event in
                let editing = (preview?.firstResponder as? NSTextView)?.isEditable == true
                if event.keyCode == 53 || (event.keyCode == 49 && !editing) {
                    preview?.orderOut(nil); self?.compactPanel?.makeKeyAndOrderFront(nil); return true
                }
                if event.keyCode == 36 { self?.useSelected(plainText: event.modifierFlags.contains(.shift)); return true }
                return false
            }
            preview.sharingType = hideDuringScreenShare ? .none : .readOnly
            previewWindow = preview
        }
        previewWindow?.center(); previewWindow?.makeKeyAndOrderFront(nil)
    }

    private func handleKey(_ event: NSEvent, window: NSWindow?) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let numberKeys: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        let isEditing = (window?.firstResponder as? NSTextView)?.isEditable == true
        if (modifiers == .command || modifiers == [.command, .shift]), let number = numberKeys[event.keyCode] {
            let items = filteredItems; guard items.indices.contains(number - 1) else { return false }
            select(items[number - 1].id); useSelected(plainText: modifiers.contains(.shift)); return true
        }
        if modifiers == .command, event.keyCode == 0, !isEditing { selectAllVisible(); return true }
        if modifiers == .command, event.keyCode == 31, !isEditing { openSelected(); return true }
        if modifiers == .command, event.keyCode == 51, !isEditing { deleteSelection(); return true }
        if modifiers == .option, event.keyCode == 36 || event.keyCode == 76 { startPasteQueue(); return true }
        guard modifiers.isEmpty || modifiers == .shift else { return false }
        switch event.keyCode {
        case 53:
            if !multiSelection.isEmpty {
                clearMultiSelection()
            } else if !query.isEmpty {
                query = ""
                NotificationCenter.default.post(name: Notification.Name("LightPasteDrawerShown"), object: compactPanel)
                window?.makeFirstResponder(drawerHost)
            } else { dismiss(window) }
            return true
        case 123, 124, 125, 126:
            if (event.keyCode == 123 || event.keyCode == 124) && isEditing { return false }
            let items = filteredItems; guard !items.isEmpty else { return false }
            let index = items.firstIndex(where: { $0.id == selectedID }) ?? 0
            let forward = event.keyCode == 124 || event.keyCode == 125
            let target = items[min(items.count - 1, max(0, index + (forward ? 1 : -1)))].id
            if modifiers == .shift { extendSelection(to: target) } else { select(target) }
            selectionScrollRevision += 1
            return true
        case 36, 76:
            useSelected(plainText: modifiers.contains(.shift)); return true
        case 49:
            if isEditing { return false }
            showItemPreview()
            return true
        default:
            if !isEditing, let characters = event.characters, !characters.isEmpty,
               characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
               let root = window?.contentView, let field = editableField(in: root) {
                NotificationCenter.default.post(name: Notification.Name("LightPasteFocusSearch"), object: compactPanel)
                window?.makeFirstResponder(field)
                (window?.firstResponder as? NSTextView)?.interpretKeyEvents([event])
                return true
            }
            return false
        }
    }

    private func editableField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { self.editableField(in: $0) }.first
    }

    private func rememberTarget() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = app
        }
    }
    private func dismiss(_ window: NSWindow?) {
        if window === compactPanel { dismissDrawer(); return }
        window?.orderOut(nil)
        if let previousApplication, !previousApplication.isTerminated { previousApplication.activate(options: []) }
    }
    private func activate() {
        if #available(macOS 14, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
    }
    func setStatus(_ text: String) {
        statusText = text; statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusText = "" }
        }
    }
    private func present(_ error: Error) { setStatus(error.localizedDescription) }

    // MARK: Menu bar

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "轻贴")
        item.button?.toolTip = "轻贴 · 本地剪贴板"
        item.button?.target = self
        item.button?.action = #selector(statusButtonPressed(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item; rebuildStatusMenu()
    }
    private func rebuildStatusMenu() {
        guard statusItem != nil else { return }
        let menu = NSMenu()
        let title = NSMenuItem(title: "轻贴 · \(capturePaused ? pauseLabel : "正在记录")", action: nil, keyEquivalent: "")
        title.isEnabled = false; menu.addItem(title)
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        add("打开抽屉  \(shortcutLabel)", #selector(menuShowPanel))
        add("光标处粘贴  \(quickHotKey.label)", #selector(menuQuickPaste))
        add("新建常用文本…", #selector(menuNewText))
        menu.addItem(.separator())
        if capturePaused { add("继续记录", #selector(menuPause)) }
        else {
            let pause = NSMenuItem(title: "暂停记录", action: nil, keyEquivalent: "")
            let choices = NSMenu()
            for (index, choice) in Self.pauseChoices.enumerated() {
                let item = NSMenuItem(title: choice.title, action: #selector(menuPauseFor(_:)), keyEquivalent: "")
                item.target = self; item.tag = index; choices.addItem(item)
            }
            pause.submenu = choices; menu.addItem(pause)
        }
        add("设置…", #selector(menuSettings)); add("使用引导…", #selector(menuOnboarding)); menu.addItem(.separator())
        add("退出轻贴", #selector(menuQuit)); statusMenu = menu
    }
    @objc private func statusButtonPressed(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp, let statusMenu {
            statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
        } else { togglePanel() }
    }
    @objc private func menuShowPanel() { showPanel() }
    @objc private func menuQuickPaste() { showQuickPaste() }
    @objc private func menuNewText() { showPanel(); createTextItem() }
    @objc private func menuPause() { togglePause() }
    @objc private func menuPauseFor(_ sender: NSMenuItem) {
        guard Self.pauseChoices.indices.contains(sender.tag) else { return }
        pauseCapture(for: Self.pauseChoices[sender.tag].seconds)
    }
    @objc private func menuSettings() { showSettings() }
    @objc private func menuOnboarding() { showOnboarding() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    func stop() {
        endPasteQueue(message: nil)
        monitor.stop(); maintenance?.invalidate(); statusTimer?.invalidate(); pauseTimer?.invalidate()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
    }
}
