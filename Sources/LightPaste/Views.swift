import SwiftUI
import AppKit

// MARK: Settings

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @State private var showAdvancedExclusions = false
    @State private var excludedDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("设置").font(.ds(DS.Size.display, .semibold))
                Text("历史与收藏只保存在这台 Mac。").font(.ds(DS.Size.body)).foregroundStyle(DS.secondary)
                    .padding(.top, DS.Space.xs).padding(.bottom, DS.Space.xl)

                section("通用", symbol: "keyboard") {
                    row("唤起快捷键") { ShortcutRecorder(controller: controller) }
                    row("抽屉位置") {
                        Picker("抽屉位置", selection: saved(\.drawerEdge)) {
                            ForEach(DrawerEdge.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 200)
                    }
                    row("卡片尺寸") {
                        Picker("卡片尺寸", selection: saved(\.cardSize)) {
                            ForEach(CardSize.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 200)
                    }
                    toggleRow("登录时打开", "开机后自动在后台运行，随时可用快捷键唤起。",
                              Binding(get: { controller.launchAtLogin }, set: { controller.setLaunchAtLogin($0) }))
                    toggleRow("始终粘贴为纯文本", "去掉字体、颜色等格式；按 ⇧ 使用时改为保留原格式。图片和文件不受影响。",
                              saved(\.alwaysPlainText))
                    if !controller.alwaysPlainText {
                        settingLabel("粘贴到这些应用时用纯文本", "适合终端和代码编辑器；按 ⇧ 使用时保留原格式。")
                        ExcludedAppsPicker(controller: controller, list: \.plainTextAppsText, countLabel: "已选")
                    }
                    permissionRow
                }

                section("记录", symbol: "clock.arrow.circlepath") {
                    toggleRow("记录剪贴板历史", controller.capturePaused ? "\(controller.pauseLabel)。" : "复制文字、链接、图片和文件时自动记录。",
                              Binding(get: { !controller.capturePaused },
                                      set: { if $0 == controller.capturePaused { controller.togglePause() } }))
                    row("历史保留") {
                        Picker("历史保留", selection: saved(\.retentionDays)) {
                            ForEach(retentionChoices, id: \.self) { days in Text(Self.retentionTitle(days)).tag(days) }
                        }.labelsHidden().frame(width: 140)
                    }
                    row("数量上限") {
                        Stepper(value: saved(\.maxItems), in: 100...20_000, step: 100) {
                            Text("\(controller.maxItems.formatted()) 项").monospacedDigit().frame(width: 80, alignment: .trailing)
                        }.fixedSize()
                    }
                    note("到期或超出上限的历史会自动清理，选“永久”时只按数量上限清理；收藏一直保留。菜单栏图标右键可暂停记录 15 分钟、1 小时或 8 小时。")
                    toggleRow("识别图片中的文字", "在本机识别，可直接搜索截图里的文字。", saved(\.ocrEnabled))
                    toggleRow("显示链接标题和图标", "会访问所复制链接的网站以获取标题和图标；关闭后不再联网。", saved(\.linkPreviewEnabled))
                }

                section("隐私", symbol: "hand.raised") {
                    row("敏感内容保留") {
                        Picker("敏感内容保留", selection: saved(\.sensitiveMinutes)) {
                            Text("5 分钟").tag(5); Text("10 分钟").tag(10); Text("30 分钟").tag(30); Text("与历史相同").tag(0)
                        }.labelsHidden().frame(width: 140)
                    }
                    note("识别到密钥、银行卡号、身份证号时，卡片会打码显示，到时自动删除；验证码 5 分钟后删除。收藏的内容不受影响。")
                    toggleRow("共享屏幕时隐藏轻贴", "开启后，屏幕共享、录屏和截图中都不会出现抽屉与预览窗口。", saved(\.hideDuringScreenShare))
                    Text("不记录这些应用").font(.ds(DS.Size.body, .medium)).padding(.top, DS.Space.s)
                    ExcludedAppsPicker(controller: controller)
                    DisclosureGroup("高级：按应用标识编辑", isExpanded: $showAdvancedExclusions) {
                        VStack(alignment: .leading, spacing: DS.Space.s) {
                            TextEditor(text: $excludedDraft)
                                .font(.system(size: DS.Size.caption, design: .monospaced))
                                .scrollContentBackground(.hidden)
                                .padding(6).frame(height: 84)
                                .background(DS.field, in: RoundedRectangle(cornerRadius: DS.Radius.small))
                                .overlay(RoundedRectangle(cornerRadius: DS.Radius.small).stroke(DS.line))
                                .accessibilityLabel("忽略的应用标识列表")
                            HStack {
                                Text("每行一个，例如 com.agilebits.onepassword7").font(.ds(DS.Size.caption)).foregroundStyle(DS.secondary)
                                Spacer()
                                Button("保存") { controller.excludedAppsText = excludedDraft; controller.saveSettings() }
                                    .disabled(excludedDraft == controller.excludedAppsText)
                            }
                        }.padding(.top, DS.Space.s)
                    }
                    .font(.ds(DS.Size.body)).foregroundStyle(DS.secondary)
                    .onChange(of: showAdvancedExclusions) { open in if open { excludedDraft = controller.excludedAppsText } }
                }

                section("本机数据", symbol: "externaldrive") {
                    HStack {
                        Button("导出收藏…") { controller.exportFavorites() }
                        Button("导入收藏…") { controller.importFavorites() }
                        Spacer()
                    }
                    note("把收藏和分类存成一个文件，换电脑或重装后导入即可恢复；已有的内容不会重复。备份文件没有加密。")
                    HStack {
                        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([controller.storageLocation()]) }
                        Button("重新查看引导") { controller.showOnboarding() }
                        Spacer()
                        Button("清空历史…", role: .destructive) { controller.clearHistory() }
                    }
                    note("清空历史会保留收藏。")
                }
                if !controller.statusText.isEmpty {
                    Text(controller.statusText).font(.ds(DS.Size.caption)).foregroundStyle(DS.accent).padding(.top, DS.Space.m)
                }
            }
            .padding(.horizontal, 32).padding(.top, 40).padding(.bottom, 32)
        }
        .background(DS.background)
        .foregroundStyle(DS.ink).tint(DS.accent)
        .toggleStyle(.switch).controlSize(.small)
        .frame(minWidth: 600, idealWidth: 640, minHeight: 640)
        .onAppear { controller.refreshPermissions() }
    }

    /// Day, week, month, year, forever; an older custom value stays selectable.
    private var retentionChoices: [Int] {
        let presets = [1, 7, 30, 365, 0]
        return presets.contains(controller.retentionDays) ? presets : [controller.retentionDays] + presets
    }

    private static func retentionTitle(_ days: Int) -> String {
        switch days {
        case 0: return "永久"; case 1: return "1 天"; case 7: return "1 周"; case 30: return "1 个月"; case 365: return "1 年"
        default: return "\(days) 天"
        }
    }

    private var permissionRow: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: controller.accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(controller.accessibilityGranted ? DS.accent : DS.warning)
            settingLabel(controller.accessibilityGranted ? "已允许自动粘贴" : "自动粘贴需要辅助功能权限",
                         "用于把内容粘贴回刚才的应用和按顺序粘贴；只复制无需开启。")
            Spacer()
            if controller.accessibilityGranted { Button("重新检查") { controller.refreshPermissions() } }
            else { Button("开启权限…") { controller.requestAccessibility() }.buttonStyle(.borderedProminent) }
        }
        .padding(DS.Space.m)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(DS.line))
    }

    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Label(title, systemImage: symbol).font(.ds(DS.Size.emphasis, .semibold)).foregroundStyle(DS.secondary)
            VStack(alignment: .leading, spacing: DS.Space.m) { content() }
                .font(.ds(DS.Size.body))
                .padding(DS.Space.l)
                .background(DS.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: DS.Radius.panel))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel).stroke(DS.line))
        }
        .padding(.bottom, DS.Space.xxl)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).frame(width: 110, alignment: .leading)
            Spacer(minLength: DS.Space.s)
            content()
        }
    }

    private func toggleRow(_ title: String, _ detail: String, _ binding: Binding<Bool>) -> some View {
        HStack(alignment: .center) {
            settingLabel(title, detail)
            Spacer(minLength: DS.Space.l)
            Toggle(title, isOn: binding).labelsHidden()
        }
    }

    private func settingLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.ds(DS.Size.body, .medium))
            Text(detail).font(.ds(DS.Size.caption)).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.ds(DS.Size.caption)).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func saved<Value>(_ keyPath: ReferenceWritableKeyPath<AppController, Value>) -> Binding<Value> {
        Binding(get: { controller[keyPath: keyPath] }, set: { value in
            controller[keyPath: keyPath] = value
            controller.saveSettings()
        })
    }
}

// MARK: Shortcut recorder

/// Click, then press the new combination. Esc cancels; the old shortcut stays until a valid one is pressed.
struct ShortcutRecorder: View {
    @ObservedObject var controller: AppController
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint = ""

    var body: some View {
        HStack(spacing: DS.Space.s) {
            if !hint.isEmpty { Text(hint).font(.ds(DS.Size.caption)).foregroundStyle(DS.warning) }
            Button { recording ? stop() : start() } label: {
                Text(recording ? "按下新的快捷键…" : controller.hotKey.label)
                    .font(.ds(DS.Size.body, .medium)).monospacedDigit()
                    .frame(minWidth: 132).frame(height: 26)
                    .foregroundStyle(recording ? DS.accent : DS.ink)
                    .background(recording ? DS.selected : DS.field, in: RoundedRectangle(cornerRadius: DS.Radius.small))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.small).stroke(recording ? DS.accent : DS.line))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recording ? "正在录制快捷键" : "唤起快捷键：\(controller.hotKey.label)，点击后按下新组合")
        }
        .onDisappear { stop() }
    }

    private func start() {
        hint = ""
        recording = true
        controller.suspendHotKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            guard let spec = HotKeySpec(event: event) else {
                hint = "需包含 ⌘、⌥ 或 ⌃"
                return nil
            }
            if controller.setHotKey(spec) { hint = "" } else { hint = "已被占用" }
            stop(resume: false)
            return nil
        }
    }

    private func stop(resume: Bool = true) {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if recording && resume { controller.resumeHotKey() }
        recording = false
    }
}

// MARK: Excluded apps

struct AppEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
}

/// Pick apps instead of typing bundle identifiers: the apps not to record, or the apps that get plain text.
/// Stored as the same identifier list.
struct ExcludedAppsPicker: View {
    @ObservedObject var controller: AppController
    var list: ReferenceWritableKeyPath<AppController, String> = \.excludedAppsText
    var countLabel = "已忽略"
    @State private var apps: [AppEntry] = []
    @State private var search = ""

    private var excluded: Set<String> { AppController.bundleIDs(in: controller[keyPath: list]) }

    private var visible: [AppEntry] {
        let filtered = search.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search)
        }
        // Ignored apps first, then by name.
        return filtered.sorted { lhs, rhs in
            let l = excluded.contains(lhs.id), r = excluded.contains(rhs.id)
            return l != r ? l : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(DS.secondary)
                TextField("搜索应用", text: $search).textFieldStyle(.plain)
                Text("\(countLabel) \(excluded.count) 个").font(.ds(DS.Size.caption)).foregroundStyle(DS.secondary)
            }
            .padding(.horizontal, DS.Space.s).frame(height: 30)
            Rectangle().fill(DS.line).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { app in
                        Toggle(isOn: Binding(get: { excluded.contains(app.id) }, set: { set(app.id, ignored: $0) })) {
                            HStack(spacing: DS.Space.s) {
                                Image(nsImage: controller.icons.fileIcon(path: app.path)).resizable().frame(width: 20, height: 20)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(app.name).font(.ds(DS.Size.body))
                                    Text(app.id).font(.system(size: 10)).foregroundStyle(DS.tertiary)
                                }
                                Spacer()
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.horizontal, DS.Space.s).padding(.vertical, 5)
                    }
                    if apps.isEmpty { ProgressView().controlSize(.small).padding() }
                }
            }
            .frame(height: 190)
        }
        .background(DS.field, in: RoundedRectangle(cornerRadius: DS.Radius.small))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.small).stroke(DS.line))
        .task { if apps.isEmpty { apps = await Self.installedApps(including: excluded) } }
    }

    private func set(_ id: String, ignored: Bool) {
        var ids = controller[keyPath: list].components(separatedBy: .newlines)
            .flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ",，;；")) }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if ignored { if !ids.contains(id) { ids.append(id) } } else { ids.removeAll { $0 == id } }
        controller[keyPath: list] = ids.joined(separator: "\n")
        controller.saveSettings()
    }

    /// Running apps plus apps in the standard folders; reading Info.plist only, nothing is launched.
    static func installedApps(including ids: Set<String>) async -> [AppEntry] {
        let running = await MainActor.run {
            NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
                .compactMap { app -> AppEntry? in
                    guard let id = app.bundleIdentifier, let url = app.bundleURL else { return nil }
                    return AppEntry(id: id, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent, path: url.path)
                }
        }
        let missingIDs = ids
        return await Task.detached(priority: .utility) {
            var result: [String: AppEntry] = [:]
            for entry in running { result[entry.id] = entry }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities"]
                .map { URL(fileURLWithPath: $0) } + [home.appendingPathComponent("Applications")]
            for folder in folders {
                let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                for url in urls where url.pathExtension == "app" {
                    guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, result[id] == nil else { continue }
                    let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                    result[id] = AppEntry(id: id, name: name, path: url.path)
                }
            }
            // Ignored apps that are not installed still appear so they can be removed.
            for id in missingIDs where result[id] == nil { result[id] = AppEntry(id: id, name: id, path: "/Applications") }
            return Array(result.values)
        }.value
    }
}

// MARK: Onboarding

/// Three steps on first launch: shortcut, permission, first copy.
struct OnboardingView: View {
    @ObservedObject var controller: AppController
    @State private var step = 0
    @State private var startDate = Date()
    @State private var copied = false
    private let permissionTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s) {
                ForEach(0..<3) { index in
                    Capsule().fill(index <= step ? DS.accent : DS.line).frame(width: index == step ? 28 : 12, height: 4)
                }
                Spacer()
                Button("跳过") { controller.finishOnboarding(openDrawer: false) }
                    .buttonStyle(.plain).font(.ds(DS.Size.body)).foregroundStyle(DS.secondary)
            }
            .animation(.easeOut(duration: 0.2), value: step)
            .padding(.bottom, 28)

            Group {
                switch step {
                case 0: shortcutStep
                case 1: permissionStep
                default: copyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                if step > 0 { Button("上一步") { step -= 1 }.buttonStyle(.plain).foregroundStyle(DS.secondary) }
                Spacer()
                Button(step == 2 ? "打开抽屉" : "继续") {
                    if step == 2 { controller.finishOnboarding(openDrawer: true) } else { step += 1 }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 40).padding(.top, 44).padding(.bottom, 32)
        .frame(width: 560, height: 460)
        .background(DS.background)
        .foregroundStyle(DS.ink).tint(DS.accent)
        .onReceive(permissionTimer) { _ in
            if step == 1 { controller.refreshPermissions() }
            if step == 2, !copied, controller.store.items.contains(where: { $0.lastCopiedAt > startDate }) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { copied = true }
            }
        }
        .onChange(of: step) { value in if value == 2 { startDate = Date(); copied = false } }
    }

    private func title(_ text: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(text).font(.system(size: 24, weight: .semibold))
            Text(detail).font(.ds(DS.Size.emphasis)).foregroundStyle(DS.secondary).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, DS.Space.xxl)
    }

    private var shortcutStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("一个快捷键，找回复制过的一切", "轻贴在后台记录你复制的文字、链接、图片和文件。按下快捷键，抽屉从屏幕边缘滑出。")
            HStack {
                Text("唤起快捷键").font(.ds(DS.Size.emphasis, .medium))
                Spacer()
                ShortcutRecorder(controller: controller)
            }
            .padding(DS.Space.l)
            .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(DS.line))
            Text("点击右侧可改成你习惯的组合，比如 ⇧⌘V。").font(.ds(DS.Size.caption)).foregroundStyle(DS.secondary).padding(.top, DS.Space.s)
        }
    }

    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("选中即粘贴", "开启辅助功能权限后，按回车会直接把内容粘贴回刚才的应用。不开启也能用：内容会复制好，再按 ⌘V 即可。")
            HStack(spacing: DS.Space.m) {
                Image(systemName: controller.accessibilityGranted ? "checkmark.circle.fill" : "hand.point.up.left")
                    .font(.system(size: 24)).foregroundStyle(controller.accessibilityGranted ? DS.accent : DS.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.accessibilityGranted ? "已开启自动粘贴" : "在系统设置中打开“轻贴”的开关")
                        .font(.ds(DS.Size.emphasis, .medium))
                    Text("系统设置 → 隐私与安全性 → 辅助功能").font(.ds(DS.Size.caption)).foregroundStyle(DS.secondary)
                }
                Spacer()
                if !controller.accessibilityGranted { Button("前往开启…") { controller.requestAccessibility() } }
            }
            .padding(DS.Space.l)
            .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(controller.accessibilityGranted ? DS.accent : DS.line))
        }
    }

    private var copyStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("试一下", "在任意应用里复制一段文字。轻贴记录下来后，这里会打勾。")
            HStack(spacing: DS.Space.m) {
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 24)).foregroundStyle(copied ? DS.accent : DS.secondary)
                    .scaleEffect(copied ? 1.1 : 1)
                Text(copied ? "已记录，按 \(controller.shortcutLabel) 随时取用" : "等待你复制… （⌘C）")
                    .font(.ds(DS.Size.emphasis, .medium))
                Spacer()
            }
            .padding(DS.Space.l)
            .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(copied ? DS.accent : DS.line))
            VStack(alignment: .leading, spacing: 6) {
                Text("在抽屉里：").font(.ds(DS.Size.caption, .semibold))
                Text("← → 选择 · ↩ 粘贴 · ⌘1–9 快速粘贴 · 空格预览 · 直接打字即搜索 · ⌘ 点击多选后按顺序粘贴")
                    .font(.ds(DS.Size.caption)).foregroundStyle(DS.secondary)
            }
            .padding(.top, DS.Space.l)
        }
    }
}
