import AppKit
import SwiftUI

/// A short confirmation near the bottom of the active screen. It never takes focus or clicks.
@MainActor
final class FeedbackHUD {
    private var panel: NSPanel?
    private var host: NSHostingView<HUDLabel>?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, symbol: String = "checkmark.circle.fill", duration: TimeInterval = DS.Motion.hud) {
        let panel = self.panel ?? makePanel()
        host?.rootView = HUDLabel(text: text, symbol: symbol)
        let size = host?.fittingSize ?? NSSize(width: 220, height: 44)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + 72, width: size.width, height: size.height), display: true)
        hideWork?.cancel()
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.reduced ? 0 : 0.14
            panel.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.reduced ? 0 : 0.22
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.ignoresMouseEvents = true; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let effect = NSVisualEffectView()
        effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
        effect.wantsLayer = true; effect.layer?.cornerRadius = 22; effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: HUDLabel(text: "", symbol: "checkmark"))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        panel.contentView = effect
        host.frame = effect.bounds
        self.panel = panel; self.host = host
        return panel
    }
}

struct HUDLabel: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: symbol).font(.ds(DS.Size.title, .semibold)).foregroundStyle(DS.accent)
            Text(text).font(.ds(DS.Size.emphasis, .medium)).foregroundStyle(DS.ink).lineLimit(1)
        }
        .padding(.horizontal, DS.Space.xl).frame(height: 44)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
