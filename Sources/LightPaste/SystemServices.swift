import AppKit
import ApplicationServices
import Carbon
import SwiftUI

final class DrawerHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { true }
}

final class HotKeyManager {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onTrigger: (() -> Void)?

    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<HotKeyManager>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { owner.onTrigger?() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    @discardableResult
    func register(_ spec: HotKeySpec) -> Bool {
        unregister()
        let identifier = EventHotKeyID(signature: OSType(0x4c505354), id: 1)
        return RegisterEventHotKey(spec.keyCode, spec.carbonModifiers, identifier, GetApplicationEventTarget(), 0, &reference) == noErr
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}

/// A global shortcut: a virtual key code plus Carbon modifier flags.
struct HotKeySpec: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let `default` = HotKeySpec(keyCode: 49, carbonModifiers: UInt32(optionKey))

    /// The three presets offered before 0.4.
    static func legacy(option: Int) -> HotKeySpec {
        switch option {
        case 1: return HotKeySpec(keyCode: 9, carbonModifiers: UInt32(controlKey))
        case 2: return HotKeySpec(keyCode: 9, carbonModifiers: UInt32(cmdKey | shiftKey))
        default: return .default
        }
    }

    /// Requires ⌘, ⌥ or ⌃ so ordinary typing is never captured; function keys may stand alone.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isFunctionKey = Self.functionKeys[event.keyCode] != nil
        guard !flags.intersection([.command, .option, .control]).isEmpty || isFunctionKey else { return nil }
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
    }

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    var label: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + " " + Self.keyName(UInt16(keyCode))
    }

    private static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15"
    ]
    private static let named: [UInt16: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "esc", 123: "←", 124: "→", 125: "↓", 126: "↑",
        50: "`", 27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/"
    ]
    private static let letters: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
        45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9"
    ]

    static func keyName(_ code: UInt16) -> String {
        functionKeys[code] ?? named[code] ?? letters[code] ?? "键 \(code)"
    }
}

final class ClipboardWindow: NSPanel {
    var handleKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let text = firstResponder as? NSTextView, text.hasMarkedText() {
            super.sendEvent(event)
            return
        }
        if event.type == .keyDown, handleKey?(event) == true { return }
        super.sendEvent(event)
    }
}

@MainActor
final class PasteService {
    private var pending: Timer?
    /// Stamped on the keystrokes 轻贴 posts, so its own ⌘V can be told apart from the user's.
    nonisolated static let syntheticEventMarker: Int64 = 0x4C505354

    nonisolated static func isSynthetic(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker
    }

    func write(_ entries: [ClipboardEntry], plainText: String?, to board: NSPasteboard = .general) throws {
        pending?.invalidate(); pending = nil
        let objects: [NSPasteboardItem]
        if let plainText {
            let item = NSPasteboardItem()
            item.setString(plainText, forType: .string)
            objects = [item]
        } else {
            objects = entries.map { entry in
                let item = NSPasteboardItem()
                for representation in entry.representations {
                    item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
                }
                return item
            }
        }
        guard !objects.isEmpty else { throw ServiceError.message("内容为空，无法复制。") }
        board.clearContents()
        guard board.writeObjects(objects) else { throw ServiceError.message("无法写入系统剪贴板，请重试。") }
    }

    /// Whether the app's focused element accepts typed text. nil when Accessibility cannot tell
    /// (no permission, or apps such as Electron that expose no focus until queried more deeply).
    static func focusedTextInput(in pid: pid_t) -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if let role = role as? String,
           [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"].contains(role) { return true }
        // Web contenteditable regions and custom editors report an editable ancestor or a settable caret.
        var names: CFArray?
        if AXUIElementCopyAttributeNames(element, &names) == .success,
           let names = names as? [String], names.contains("AXEditableAncestor") { return true }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
           settable.boolValue { return true }
        return false
    }

    /// Sends ⌘V to the target, then optionally moves the caret left for a snippet's {光标} marker.
    func paste(into target: NSRunningApplication, cursorBack: Int = 0, completion: @escaping (Bool) -> Void) {
        pending?.invalidate()
        guard AXIsProcessTrusted(), !target.isTerminated else { completion(false); return }
        target.activate(options: [])
        let deadline = Date().addingTimeInterval(1.4)
        let expectedChangeCount = NSPasteboard.general.changeCount
        pending = Timer.scheduledTimer(withTimeInterval: 0.035, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard !target.isTerminated, Date() < deadline, NSPasteboard.general.changeCount == expectedChangeCount else {
                    timer.invalidate(); self?.pending = nil; completion(false); return
                }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { return }
                timer.invalidate(); self?.pending = nil
                guard AXIsProcessTrusted(), let source = CGEventSource(stateID: .combinedSessionState),
                      let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
                    completion(false); return
                }
                down.flags = .maskCommand; up.flags = .maskCommand
                for event in [down, up] {
                    event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
                    event.post(tap: .cgSessionEventTap)
                }
                if cursorBack > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        for _ in 0..<min(cursorBack, 2_000) {
                            for isDown in [true, false] {
                                guard let arrow = CGEvent(keyboardEventSource: source, virtualKey: 123, keyDown: isDown) else { continue }
                                arrow.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
                                arrow.post(tap: .cgSessionEventTap)
                            }
                        }
                    }
                }
                completion(true)
            }
        }
    }
}

enum ServiceError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
