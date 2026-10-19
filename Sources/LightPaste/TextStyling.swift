import SwiftUI
import AppKit

/// Search hits on cards: highlight every keyword and start the excerpt near the first hit.
enum SearchHighlight {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    static func keywords(_ query: String) -> [String] {
        SearchQuery.parse(query).keywords
    }

    /// Starts one line before the first matching line so the hit is visible in a 7-line card.
    static func excerpt(_ text: String, keywords: [String], limit: Int = 600) -> String {
        guard let first = keywords.compactMap({ text.range(of: $0, options: options)?.lowerBound }).min() else {
            return String(text.prefix(limit))
        }
        let before = text[..<first]
        var start = before.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        if start > text.startIndex {
            let previous = text[..<text.index(before: start)]
            start = previous.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        }
        // A single very long line: keep a short lead-in before the hit.
        if text.distance(from: start, to: first) > 80 {
            start = text.index(first, offsetBy: -40, limitedBy: start) ?? start
            return "…" + String(text[start...].prefix(limit))
        }
        return String(text[start...].prefix(limit))
    }

    static func attributed(_ text: String, keywords: [String], base: AttributedString? = nil) -> AttributedString {
        var result = base ?? AttributedString(text)
        guard !keywords.isEmpty else { return result }
        for keyword in keywords {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: keyword, options: options, range: searchStart..<text.endIndex) {
                if let lower = AttributedString.Index(range.lowerBound, within: result),
                   let upper = AttributedString.Index(range.upperBound, within: result) {
                    result[lower..<upper].backgroundColor = DS.accent.opacity(0.28)
                    result[lower..<upper].foregroundColor = DS.ink
                }
                searchStart = range.upperBound
            }
        }
        return result
    }
}

/// Small regex highlighter for code cards; it colors tokens only and never parses or runs anything.
enum SyntaxHighlighter {
    private static let keywordList = [
        "func", "let", "var", "if", "else", "guard", "return", "for", "while", "in", "struct", "class", "enum",
        "import", "from", "def", "const", "function", "async", "await", "try", "catch", "throw", "new", "public",
        "private", "static", "package", "type", "interface", "export", "default", "switch", "case", "break",
        "true", "false", "nil", "null", "None", "self", "this", "SELECT", "FROM", "WHERE", "INSERT", "UPDATE",
        "DELETE", "JOIN", "AND", "OR", "CREATE", "TABLE", "echo", "then", "fi", "do", "done"
    ]
    private static let rules: [(NSRegularExpression, Color)] = {
        let keyword = DS.dynamic(light: (0.60, 0.18, 0.55), dark: (0.93, 0.55, 0.85))
        let string = DS.dynamic(light: (0.72, 0.25, 0.15), dark: (0.98, 0.58, 0.48))
        let number = DS.dynamic(light: (0.15, 0.35, 0.75), dark: (0.55, 0.72, 1.0))
        let comment = DS.dynamic(light: (0.45, 0.48, 0.45), dark: (0.55, 0.58, 0.55))
        let patterns: [(String, Color)] = [
            (#"\b(\#(keywordList.joined(separator: "|")))\b"#, keyword),
            (#"\b\d+(\.\d+)?\b"#, number),
            (#""([^"\\\n]|\\.)*"|'([^'\\\n]|\\.)*'|`[^`]*`"#, string),
            (#"//[^\n]*|#(?!!)[^\n]*|--[^\n]*|/\*[\s\S]*?\*/"#, comment)
        ]
        return patterns.compactMap { pattern, color in (try? NSRegularExpression(pattern: pattern)).map { ($0, color) } }
    }()

    /// Later rules win, so strings and comments override keywords inside them.
    static func attributed(_ code: String) -> AttributedString {
        var result = AttributedString(code)
        let range = NSRange(code.startIndex..., in: code)
        for (expression, color) in rules {
            for match in expression.matches(in: code, range: range) {
                guard let r = Range(match.range, in: code),
                      let lower = AttributedString.Index(r.lowerBound, within: result),
                      let upper = AttributedString.Index(r.upperBound, within: result) else { continue }
                result[lower..<upper].foregroundColor = color
            }
        }
        return result
    }
}

/// Language labels for code cards. Detection scans up to 4,000 characters, so it runs once per
/// card content instead of on every redraw (search typing redraws all visible cards).
@MainActor
enum CodeLanguageCache {
    private static var labels: [UUID: (length: Int, label: String)] = [:]

    static func label(for id: UUID, text: String) -> String {
        // An edit almost always changes the byte length; utf8.count is O(1) for native strings.
        let length = text.utf8.count
        if let cached = labels[id], cached.length == length { return cached.label }
        let label = ContentDetector.codeLanguage(text) ?? "代码"
        if labels.count >= 2_000 { labels.removeAll(keepingCapacity: true) }
        labels[id] = (length, label)
        return label
    }
}

/// Relative times on cards: “刚刚”, “5 分钟前”, “昨天”, then a date.
enum CardTime {
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()

    static func label(for date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 6 * 3600 { return relative.localizedString(for: date, relativeTo: now) }
        if Calendar.current.isDateInToday(date) { return date.formatted(.dateTime.hour().minute()) }
        if Calendar.current.isDateInYesterday(date) { return "昨天" }
        return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
    }

    static func remaining(until date: Date, now: Date = Date()) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        return minutes <= 1 ? "1 分钟内删除" : "\(minutes) 分钟后删除"
    }
}
