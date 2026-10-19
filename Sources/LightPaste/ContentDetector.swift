import Foundation

/// Pure, local classification of copied text. No network, no AppKit; validated by Scripts/VerifyDetection.swift.
enum ContentDetector {
    struct RGBA: Equatable { var red, green, blue, alpha: Double }

    static let otpLifetime: TimeInterval = 5 * 60

    /// Priority: secrets first, so a key is never shown as plain code.
    /// Links are checked for secrets too (a reset link with a token); the other kinds are text only.
    static func detect(kind: ClipKind, text: String) -> ClipDetail? {
        guard kind == .text || kind == .link else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isSensitive(trimmed) { return .sensitive }
        guard kind == .text else { return nil }
        if otp(in: trimmed) != nil { return .otp }
        if color(in: trimmed) != nil { return .color }
        if isEmail(trimmed) { return .email }
        if isPhone(trimmed) { return .phone }
        if codeLanguage(trimmed) != nil { return .code }
        return nil
    }

    // MARK: Secrets

    /// One alternation, so a long text is bridged and walked once instead of once per pattern.
    private static let secretPattern = try! NSRegularExpression(pattern: [
        #"\bsk-(?:ant-|proj-)?[A-Za-z0-9_\-]{20,}"#,
        #"\bgh[pousr]_[A-Za-z0-9]{36,}"#,
        #"\bgithub_pat_[A-Za-z0-9_]{40,}"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\bxox[baprs]-[A-Za-z0-9-]{10,}"#,
        #"\bAIza[0-9A-Za-z_\-]{35}\b"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
        #"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#
    ].map { "(?:\($0))" }.joined(separator: "|"))

    /// Scans the whole text: a key at the end of a long log is as secret as one at the start.
    static func isSensitive(_ text: String) -> Bool {
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)
        if secretPattern.firstMatch(in: text, range: range) != nil { return true }
        if isBankCard(text) { return true }
        return containsChineseID(text)
    }

    /// Only the whole clip counts as a card number; long order numbers inside prose do not.
    static func isBankCard(_ text: String) -> Bool {
        guard text.utf8.count <= 64 else { return false }
        let compact = text.filter { $0 != " " && $0 != "-" }
        guard (13...19).contains(compact.count), compact.allSatisfy(\.isASCIIDigit) else { return false }
        return luhn(compact)
    }

    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (index, character) in digits.reversed().enumerated() {
            guard var value = character.wholeNumberValue else { return false }
            if index % 2 == 1 { value *= 2; if value > 9 { value -= 9 } }
            sum += value
        }
        return sum % 10 == 0
    }

    private static let idPattern = try! NSRegularExpression(pattern: #"(?<![0-9])[1-9][0-9]{16}[0-9Xx](?![0-9A-Za-z])"#)

    static func containsChineseID(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return idPattern.matches(in: text, range: range).contains { match in
            guard let r = Range(match.range, in: text) else { return false }
            return isChineseID(String(text[r]))
        }
    }

    static func isChineseID(_ value: String) -> Bool {
        let chars = Array(value.uppercased())
        guard chars.count == 18 else { return false }
        let digits = chars.prefix(17).compactMap(\.wholeNumberValue)
        guard digits.count == 17 else { return false }
        let year = digits[6...9].reduce(0) { $0 * 10 + $1 }
        let month = digits[10] * 10 + digits[11]
        let day = digits[12] * 10 + digits[13]
        guard (1900...2100).contains(year), (1...12).contains(month), (1...31).contains(day) else { return false }
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let checks: [Character] = ["1", "0", "X", "9", "8", "7", "6", "5", "4", "3", "2"]
        let sum = zip(digits, weights).reduce(0) { $0 + $1.0 * $1.1 }
        return checks[sum % 11] == chars[17]
    }

    // MARK: One-time codes

    private static let otpKeywords = try! NSRegularExpression(
        pattern: #"(验证码|校验码|动态码|动态密码|确认码|安全码|verification|passcode|one[- ]time|\bcode\b|\bOTP\b|\b2FA\b)"#,
        options: [.caseInsensitive])
    private static let otpDigits = try! NSRegularExpression(pattern: #"(?<![0-9A-Za-z])[0-9]{4,8}(?![0-9A-Za-z])"#)

    /// A 4–8 digit code next to a keyword such as “验证码”, in a short message.
    static func otp(in text: String) -> String? {
        guard text.count <= 240 else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard otpKeywords.firstMatch(in: text, range: range) != nil,
              let match = otpDigits.firstMatch(in: text, range: range),
              let r = Range(match.range, in: text) else { return nil }
        return String(text[r])
    }

    // MARK: Colors

    private static let hexPattern = try! NSRegularExpression(pattern: #"^#([0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"#)
    private static let functionPattern = try! NSRegularExpression(
        pattern: #"^(rgba?|hsla?)\(\s*([0-9.]+)(deg)?\s*[, ]\s*([0-9.]+)(%?)\s*[, ]\s*([0-9.]+)(%?)\s*(?:[,/]\s*([0-9.]+)(%?)\s*)?\)$"#,
        options: [.caseInsensitive])

    static func color(in text: String) -> RGBA? {
        guard text.count <= 40 else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        if hexPattern.firstMatch(in: text, range: range) != nil {
            var hex = String(text.dropFirst())
            if hex.count <= 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            if hex.count == 6 { hex += "FF" }
            guard let value = UInt64(hex, radix: 16) else { return nil }
            return RGBA(red: Double((value >> 24) & 0xFF) / 255, green: Double((value >> 16) & 0xFF) / 255,
                        blue: Double((value >> 8) & 0xFF) / 255, alpha: Double(value & 0xFF) / 255)
        }
        guard let match = functionPattern.firstMatch(in: text, range: range) else { return nil }
        func group(_ index: Int) -> String? {
            guard let r = Range(match.range(at: index), in: text) else { return nil }
            return String(text[r])
        }
        guard let name = group(1)?.lowercased(), let a = group(2).flatMap(Double.init),
              let b = group(4).flatMap(Double.init), let c = group(6).flatMap(Double.init) else { return nil }
        var alpha = 1.0
        if let raw = group(8).flatMap(Double.init) { alpha = group(9) == "%" ? raw / 100 : raw }
        guard (0...1).contains(alpha) else { return nil }
        if name.hasPrefix("rgb") {
            let channels = [(a, group(3)), (b, group(5)), (c, group(7))].map { value, unit in unit == "%" ? value / 100 : value / 255 }
            guard channels.allSatisfy({ (0...1).contains($0) }) else { return nil }
            return RGBA(red: channels[0], green: channels[1], blue: channels[2], alpha: alpha)
        }
        guard (0...360).contains(a), (0...100).contains(b), (0...100).contains(c) else { return nil }
        let (r, g, bl) = hslToRGB(h: a / 360, s: b / 100, l: c / 100)
        return RGBA(red: r, green: g, blue: bl, alpha: alpha)
    }

    private static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func hue(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }; if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return (hue(h + 1 / 3), hue(h), hue(h - 1 / 3))
    }

    // MARK: Contact

    private static let emailPattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#)

    static func isEmail(_ text: String) -> Bool {
        text.count <= 254 && emailPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func isPhone(_ text: String) -> Bool {
        guard text.count <= 24 else { return false }
        let compact = text.filter { !" -()".contains($0) }
        let body = compact.hasPrefix("+86") ? String(compact.dropFirst(3)) : compact.hasPrefix("86") && compact.count == 13 ? String(compact.dropFirst(2)) : compact
        if body.count == 11, body.first == "1", let second = body.dropFirst().first, "3456789".contains(second),
           body.allSatisfy(\.isASCIIDigit) { return true }
        // International format needs an explicit +.
        return compact.hasPrefix("+") && (8...16).contains(compact.count - 1) && compact.dropFirst().allSatisfy(\.isASCIIDigit)
    }

    // MARK: Code

    private static let keywordLanguages: [(String, [String])] = [
        ("Swift", ["func ", "let ", "var ", "guard ", "import SwiftUI", "import Foundation", "struct ", "-> "]),
        ("Python", ["def ", "import ", "from ", "elif ", "self.", "print(", "__init__"]),
        ("Go", ["package ", "func ", ":= ", "fmt.", "go func"]),
        ("TypeScript", ["interface ", ": string", ": number", "export type ", "import type "]),
        ("JavaScript", ["const ", "function ", "=> ", "console.", "require(", "export ", "document."]),
        ("SQL", ["SELECT ", "FROM ", "WHERE ", "INSERT INTO", "UPDATE ", "CREATE TABLE", "JOIN "]),
        ("Shell", ["#!/bin/", "echo ", "sudo ", "export ", "$(", "&& ", "| grep"])
    ]

    /// Returns a language guess for text that reads as source code, nil for prose.
    static func codeLanguage(_ text: String) -> String? {
        let sample = String(text.prefix(4_000))
        if (sample.hasPrefix("{") && sample.hasSuffix("}")) || (sample.hasPrefix("[") && sample.hasSuffix("]")),
           let data = sample.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil, sample.count > 2 {
            return "JSON"
        }
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: true)
        // CJK-heavy text is prose, even with punctuation.
        let cjk = sample.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        guard cjk * 5 < sample.count else { return nil }
        var score = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(";") || trimmed.hasSuffix("{") || trimmed == "}" || trimmed.hasSuffix("):") { score += 2 }
            if line.hasPrefix("    ") || line.hasPrefix("\t") { score += 1 }
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("# ") || trimmed.hasPrefix("--") { score += 1 }
        }
        var best: (String, Int)?
        for (language, keywords) in keywordLanguages {
            let hits = keywords.filter { sample.contains($0) }.count
            if hits > (best?.1 ?? 0) { best = (language, hits) }
        }
        let symbols = sample.filter { "{}();=<>[]".contains($0) }.count
        score += (best?.1 ?? 0) * 2 + min(6, symbols / 6)
        let needed = lines.count <= 1 ? 7 : 5
        guard score >= needed else { return nil }
        return best?.0 ?? "代码"
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

/// Variables in snippets created with “新建文本”. Copied content is never expanded.
enum SnippetExpander {
    static let variables = ["{日期}", "{时间}", "{剪贴板}", "{光标}"]

    static func hasVariables(_ text: String) -> Bool { variables.contains { text.contains($0) } }

    /// Returns the expanded text and how many characters follow the cursor marker,
    /// so the caller can move the caret back after pasting.
    static func expand(_ text: String, now: Date = Date(), clipboard: String?) -> (text: String, cursorFromEnd: Int) {
        let date = DateFormatter()
        date.locale = Locale(identifier: "zh_CN")
        date.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.locale = Locale(identifier: "zh_CN")
        time.dateFormat = "HH:mm"
        var output = text
            .replacingOccurrences(of: "{日期}", with: date.string(from: now))
            .replacingOccurrences(of: "{时间}", with: time.string(from: now))
            .replacingOccurrences(of: "{剪贴板}", with: clipboard ?? "")
        var cursorFromEnd = 0
        if let marker = output.range(of: "{光标}") {
            cursorFromEnd = output[marker.upperBound...].count
            output.removeSubrange(marker)
            // Only the first marker counts.
            output = output.replacingOccurrences(of: "{光标}", with: "")
        }
        return (output, cursorFromEnd)
    }
}
