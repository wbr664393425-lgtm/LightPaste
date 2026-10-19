import AppKit

/// Edits one text or link clip. Bold, italic, underline and strikethrough apply to the selection
/// (or the next typed text); Save writes the content back, Discard leaves the clip unchanged.
@MainActor
final class ItemEditorController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private let itemID: UUID
    private let textView: NSTextView
    private let onSave: (NSAttributedString) -> Bool
    private let onClose: () -> Void
    private var modified = false

    /// Plain text is shown in the system font; clips that arrived as rich text keep their styling.
    static func attributedContent(from entries: [ClipboardEntry], fallback: String) -> NSAttributedString {
        for entry in entries {
            for type in [NSPasteboard.PasteboardType.rtfd, .rtf] {
                guard let data = entry.representations.first(where: { $0.type == type.rawValue })?.data else { continue }
                let documentType: NSAttributedString.DocumentType = type == .rtfd ? .rtfd : .rtf
                if let value = try? NSAttributedString(data: data, options: [.documentType: documentType], documentAttributes: nil),
                   value.length > 0 {
                    return value
                }
            }
        }
        let text = ClipboardMonitor.fullText(from: entries) ?? fallback
        return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor])
    }

    /// Plain text always; RTF only when the text carries formatting, so plain clips stay plain.
    static func entries(for text: NSAttributedString) -> [ClipboardEntry] {
        var representations = [ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.string.utf8))]
        if hasFormatting(text),
           let rtf = try? text.data(from: NSRange(location: 0, length: text.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            representations.insert(ClipboardRepresentation(type: NSPasteboard.PasteboardType.rtf.rawValue, data: rtf), at: 0)
        }
        return [ClipboardEntry(representations: representations)]
    }

    static func hasFormatting(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, stop in
            let traits = (attributes[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
            let underline = (attributes[.underlineStyle] as? Int ?? 0) != 0
            let strike = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
            if traits.contains(.boldFontMask) || traits.contains(.italicFontMask) || underline || strike
                || attributes[.link] != nil || attributes[.backgroundColor] != nil {
                found = true; stop.pointee = true
            }
        }
        return found
    }

    init(itemID: UUID, title: String, content: NSAttributedString,
         onSave: @escaping (NSAttributedString) -> Bool, onClose: @escaping () -> Void) {
        self.itemID = itemID
        self.onSave = onSave
        self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "编辑 · \(title.isEmpty ? "文本" : String(title.prefix(40)))"
        window.minSize = NSSize(width: 420, height: 260)
        window.isReleasedWhenClosed = false
        window.level = .floating

        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        super.init(window: window)
        window.delegate = self

        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFontPanel = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.font = .systemFont(ofSize: 14)
        textView.typingAttributes[.font] = NSFont.systemFont(ofSize: 14)
        if #available(macOS 15.0, *) { textView.writingToolsBehavior = .complete }
        textView.textStorage?.setAttributedString(content)
        textView.delegate = self
        textView.setAccessibilityLabel("编辑内容")

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        toolbar.addArrangedSubview(formatButton("bold", label: "加粗", key: "b", action: #selector(toggleBold)))
        toolbar.addArrangedSubview(formatButton("italic", label: "斜体", key: "i", action: #selector(toggleItalic)))
        toolbar.addArrangedSubview(formatButton("underline", label: "下划线", key: "u", action: #selector(toggleUnderline)))
        toolbar.addArrangedSubview(formatButton("strikethrough", label: "删除线", key: "x", modifiers: [.command, .shift],
                                                action: #selector(toggleStrikethrough)))
        if #available(macOS 15.2, *) {
            let tools = formatButton("apple.intelligence", label: "写作工具", key: "", action: #selector(openWritingTools(_:)))
            tools.image = NSImage(systemSymbolName: "apple.intelligence", accessibilityDescription: "写作工具")
                ?? NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "写作工具")
            toolbar.addArrangedSubview(tools)
        }
        toolbar.addArrangedSubview(NSView())
        let discard = NSButton(title: "放弃修改", target: self, action: #selector(discard))
        discard.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "保存", target: self, action: #selector(save))
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        save.bezelColor = .controlAccentColor
        save.hasDestructiveAction = false
        toolbar.addArrangedSubview(discard)
        toolbar.addArrangedSubview(save)
        toolbar.setHuggingPriority(.defaultHigh, for: .vertical)

        let separator = NSBox(); separator.boxType = .separator
        let root = NSStackView(views: [toolbar, separator, scroll])
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .leading
        for view in [toolbar, separator, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        window.contentView = root
        window.initialFirstResponder = textView
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("ItemEditorController is created programmatically") }

    func show() {
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
    }

    private func formatButton(_ symbol: String, label: String, key: String,
                              modifiers: NSEvent.ModifierFlags = .command, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
                              target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.setButtonType(.momentaryPushIn)
        button.keyEquivalent = key
        button.keyEquivalentModifierMask = modifiers
        let shortcut = key.isEmpty ? "" : "（\(modifiers.contains(.shift) ? "⇧" : "")⌘\(key.uppercased())）"
        button.toolTip = label + shortcut
        button.setAccessibilityLabel(label)
        return button
    }

    // MARK: Formatting

    @objc private func toggleBold() { toggleTrait(.boldFontMask) }
    @objc private func toggleItalic() { toggleTrait(.italicFontMask) }
    @objc private func toggleUnderline() { toggleLine(.underlineStyle) }
    @objc private func toggleStrikethrough() { toggleLine(.strikethroughStyle) }

    @available(macOS 15.2, *)
    @objc private func openWritingTools(_ sender: Any?) {
        window?.makeFirstResponder(textView)
        textView.showWritingTools(sender)
    }

    /// On if any of the selection lacks the trait, off when all of it has it — like a word processor.
    private func toggleTrait(_ trait: NSFontTraitMask) {
        let manager = NSFontManager.shared
        let range = textView.selectedRange()
        guard let storage = textView.textStorage else { return }
        if range.length == 0 {
            let font = textView.typingAttributes[.font] as? NSFont ?? .systemFont(ofSize: 14)
            let has = manager.traits(of: font).contains(trait)
            textView.typingAttributes[.font] = has ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
            return
        }
        var allHave = true
        storage.enumerateAttribute(.font, in: range) { value, _, stop in
            let font = value as? NSFont ?? .systemFont(ofSize: 14)
            if !manager.traits(of: font).contains(trait) { allHave = false; stop.pointee = true }
        }
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = value as? NSFont ?? .systemFont(ofSize: 14)
            let converted = allHave ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
            storage.addAttribute(.font, value: converted, range: subrange)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    private func toggleLine(_ key: NSAttributedString.Key) {
        let range = textView.selectedRange()
        guard let storage = textView.textStorage else { return }
        let on = NSUnderlineStyle.single.rawValue
        if range.length == 0 {
            let current = textView.typingAttributes[key] as? Int ?? 0
            textView.typingAttributes[key] = current == 0 ? on : 0
            return
        }
        var allHave = true
        storage.enumerateAttribute(key, in: range) { value, _, stop in
            if (value as? Int ?? 0) == 0 { allHave = false; stop.pointee = true }
        }
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        if allHave { storage.removeAttribute(key, range: range) } else { storage.addAttribute(key, value: on, range: range) }
        storage.endEditing()
        textView.didChangeText()
    }

    // MARK: Save and discard

    func textDidChange(_ notification: Notification) {
        modified = true
        window?.isDocumentEdited = true
    }

    @objc private func save() {
        guard let content = textView.textStorage?.copy() as? NSAttributedString else { return }
        guard !content.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            let alert = NSAlert(); alert.messageText = "内容不能为空"
            alert.informativeText = "如需移除这条内容，请在抽屉中删除。"
            alert.beginSheetModal(for: window!)
            return
        }
        if !modified || onSave(content) { modified = false; window?.close() }
    }

    @objc private func discard() {
        guard confirmDiscard() else { return }
        modified = false
        window?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmDiscard() }

    func windowWillClose(_ notification: Notification) { onClose() }

    private func confirmDiscard() -> Bool {
        guard modified else { return true }
        let alert = NSAlert()
        alert.messageText = "放弃对这条内容的修改？"
        alert.informativeText = "原内容保持不变。"
        alert.addButton(withTitle: "继续编辑")
        alert.addButton(withTitle: "放弃修改")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        modified = false
        return true
    }
}
