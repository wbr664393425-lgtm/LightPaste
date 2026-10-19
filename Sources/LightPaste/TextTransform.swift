import Foundation

/// “粘贴为…” conversions of a clip's full text. Pure Foundation; validated by Scripts/VerifyDetection.swift.
enum TextTransform: String, CaseIterable, Identifiable {
    case trimmed, singleLine, uppercase, lowercase, jsonPretty, jsonCompact, cleanLinks, hex, rgb, hsl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trimmed: return "去掉多余空白"
        case .singleLine: return "合并为一行"
        case .uppercase: return "全部大写"
        case .lowercase: return "全部小写"
        case .jsonPretty: return "格式化 JSON"
        case .jsonCompact: return "压缩 JSON"
        case .cleanLinks: return "去掉链接跟踪参数"
        case .hex: return "HEX 颜色"
        case .rgb: return "RGB 颜色"
        case .hsl: return "HSL 颜色"
        }
    }

    /// The conversions that would change this text, in menu order.
    static func available(for text: String) -> [TextTransform] {
        // Judged on the start of a long clip; the full text is converted when pasting.
        let sample = String(text.prefix(20_000))
        return allCases.filter { transform in
            guard let result = transform.apply(sample) else { return false }
            return result != sample
        }
    }

    /// nil when the text is not of the right shape (not JSON, not a color).
    func apply(_ text: String) -> String? {
        switch self {
        case .trimmed:
            let lines = text.components(separatedBy: .newlines).map { line in
                String(line.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
            }
            var kept: [String] = []
            for line in lines where !(line.isEmpty && (kept.last?.isEmpty ?? true)) { kept.append(line) }
            return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        case .singleLine:
            let parts = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // Chinese lines join without a space; other text gets one.
            var result = ""
            for part in parts {
                if let last = result.last, let first = part.first, !(Self.isCJK(last) && Self.isCJK(first)) { result += " " }
                result += part
            }
            return result
        case .uppercase:
            return text.uppercased()
        case .lowercase:
            return text.lowercased()
        case .jsonPretty, .jsonCompact:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.first == "{" || trimmed.first == "[", let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
            var options: JSONSerialization.WritingOptions = [.withoutEscapingSlashes]
            if self == .jsonPretty { options.formUnion([.prettyPrinted, .sortedKeys]) }
            guard let output = try? JSONSerialization.data(withJSONObject: object, options: options) else { return nil }
            return String(data: output, encoding: .utf8)
        case .cleanLinks:
            return Self.cleaningLinks(in: text)
        case .hex, .rgb, .hsl:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let color = ContentDetector.color(in: trimmed) else { return nil }
            return Self.format(color, as: self)
        }
    }

    // MARK: Links

    /// Query parameters that only record where a link was shared from.
    private static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid", "igshid", "igsh",
        "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "ref_src", "ref_url", "spm", "scm", "vd_source",
        "share_source", "share_medium", "share_plat", "share_session_id", "share_tag", "share_from", "xsec_source"
    ]

    private static let linkPattern = try! NSRegularExpression(pattern: #"https?://[^\s<>"'，。、）]+"#, options: [.caseInsensitive])

    static func cleaningLinks(in text: String) -> String {
        var result = text
        let matches = linkPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  var components = URLComponents(string: String(result[range])),
                  let items = components.queryItems, !items.isEmpty else { continue }
            let kept = items.filter { item in
                let name = item.name.lowercased()
                return !name.hasPrefix("utm_") && !trackingParameters.contains(name)
            }
            guard kept.count != items.count else { continue }
            components.queryItems = kept.isEmpty ? nil : kept
            guard let cleaned = components.string else { continue }
            result.replaceSubrange(range, with: cleaned)
        }
        return result
    }

    // MARK: Colors

    private static func format(_ color: ContentDetector.RGBA, as transform: TextTransform) -> String {
        func channel(_ value: Double) -> Int { Int((value * 255).rounded()) }
        let alpha = (color.alpha * 100).rounded() / 100
        let hasAlpha = alpha < 1
        let alphaText = String(format: "%g", alpha)
        switch transform {
        case .rgb:
            let channels = "\(channel(color.red)), \(channel(color.green)), \(channel(color.blue))"
            return hasAlpha ? "rgba(\(channels), \(alphaText))" : "rgb(\(channels))"
        case .hsl:
            let (h, s, l) = hsl(color)
            let values = "\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%"
            return hasAlpha ? "hsla(\(values), \(alphaText))" : "hsl(\(values))"
        default:
            var hex = String(format: "#%02X%02X%02X", channel(color.red), channel(color.green), channel(color.blue))
            if hasAlpha { hex += String(format: "%02X", channel(color.alpha)) }
            return hex
        }
    }

    private static func hsl(_ color: ContentDetector.RGBA) -> (Double, Double, Double) {
        let maximum = max(color.red, color.green, color.blue), minimum = min(color.red, color.green, color.blue)
        let lightness = (maximum + minimum) / 2
        let delta = maximum - minimum
        guard delta > 0 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        switch maximum {
        case color.red: hue = (color.green - color.blue) / delta
        case color.green: hue = (color.blue - color.red) / delta + 2
        default: hue = (color.red - color.green) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, saturation, lightness)
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }
}
