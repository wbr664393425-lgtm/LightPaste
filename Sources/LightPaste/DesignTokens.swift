import SwiftUI
import AppKit

/// One visual language for the drawer, settings, preview, onboarding and HUD.
/// Type: 5 sizes. Space: 4pt grid. Radius: 3 steps. Colors adapt to light and dark.
enum DS {
    enum Size {
        static let caption: CGFloat = 11
        static let body: CGFloat = 12
        static let emphasis: CGFloat = 13
        static let title: CGFloat = 15
        static let display: CGFloat = 20
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    enum Radius {
        static let small: CGFloat = 6
        static let card: CGFloat = 10
        static let panel: CGFloat = 14
    }

    enum Motion {
        static let open = 0.26
        static let close = 0.16
        static let stagger = 0.025
        static let hud = 1.2
        /// Fast start, long soft landing: the drawer arrives instead of sliding linearly.
        static let openCurve = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    }

    static let ink = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let line = Color(nsColor: .separatorColor).opacity(0.7)
    static let accent = dynamic(light: (0.22, 0.42, 0.31), dark: (0.55, 0.78, 0.62))
    static let accentNS = dynamicNS(light: (0.22, 0.42, 0.31), dark: (0.55, 0.78, 0.62))
    static let selected = dynamic(light: (0.90, 0.94, 0.90), dark: (0.20, 0.29, 0.23))
    static let warning = dynamic(light: (0.70, 0.36, 0.10), dark: (0.96, 0.66, 0.38))
    static let field = dynamic(light: (1, 1, 1), dark: (0.16, 0.16, 0.17), alpha: 0.85)

    static func tint(for kind: ClipKind) -> Color {
        switch kind {
        case .text: return dynamic(light: (0.86, 0.92, 0.86), dark: (0.22, 0.31, 0.24))
        case .link: return dynamic(light: (0.84, 0.90, 0.96), dark: (0.20, 0.28, 0.36))
        case .image: return dynamic(light: (0.95, 0.87, 0.86), dark: (0.36, 0.24, 0.25))
        case .files: return dynamic(light: (0.95, 0.90, 0.80), dark: (0.36, 0.30, 0.19))
        case .other: return dynamic(light: (0.90, 0.88, 0.95), dark: (0.29, 0.26, 0.36))
        }
    }

    static func tint(for detail: ClipDetail) -> Color {
        switch detail {
        case .code: return dynamic(light: (0.88, 0.88, 0.94), dark: (0.24, 0.24, 0.33))
        case .sensitive, .otp: return dynamic(light: (0.97, 0.88, 0.80), dark: (0.38, 0.27, 0.18))
        case .color, .email, .phone: return dynamic(light: (0.86, 0.92, 0.86), dark: (0.22, 0.31, 0.24))
        }
    }

    static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double), alpha: Double = 1) -> Color {
        Color(nsColor: dynamicNS(light: light, dark: dark, alpha: alpha))
    }

    static func dynamicNS(light: (Double, Double, Double), dark: (Double, Double, Double), alpha: Double = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let values = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: values.0, green: values.1, blue: values.2, alpha: alpha)
        }
    }
}

extension Font {
    static func ds(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
}

/// Quiet icon button shared by the drawer toolbar and batch bar.
struct DSIconButtonStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(DS.secondary)
            .frame(width: 28, height: 28)
            .background(DS.ink.opacity(configuration.isPressed ? 0.12 : hovered ? 0.06 : 0),
                        in: RoundedRectangle(cornerRadius: DS.Radius.small))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

/// Small keyboard hint chip, e.g. "⌘1".
struct KeyCap: View {
    let text: String
    var highlighted = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(highlighted ? DS.background : DS.secondary)
            .padding(.horizontal, 5).frame(height: 16)
            .background(highlighted ? DS.accent : DS.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
    }
}
