import AppKit
import UniformTypeIdentifiers
import ImageIO

private enum ClipboardCaptureError: LocalizedError {
    case tooLarge
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge: return "这次复制的内容超过 20 MB，未加入历史记录。"
        case .unavailable(let type): return "无法读取这次复制的内容（\(type)）。"
        }
    }
}

@MainActor
final class ClipboardMonitor {
    var paused = false {
        didSet {
            // Resuming starts from now rather than recording content copied while paused.
            if oldValue != paused { lastChangeCount = pasteboard.changeCount }
        }
    }
    var excludedBundleIDs: Set<String> = []
    var onError: ((String) -> Void)?

    /// The app a copy is attributed to: the frontmost app as last observed, updated only after the
    /// clipboard has been checked on each app switch, so a copy made just before switching keeps its app.
    struct Source: Equatable {
        var name: String
        var bundleID: String?
    }

    private let store: HistoryStore
    private let onChange: () -> Void
    private let pasteboard: NSPasteboard
    /// The current frontmost app; injectable so the exclusion rules can be verified without switching apps.
    private let frontmost: @MainActor () -> Source?
    private var observedSource: Source?
    private var activationObserver: NSObjectProtocol?
    /// Parsing, hashing, encoding and inserting the new row run here in copy order; the main thread
    /// only reads the pasteboard and adds the stored row to the list.
    private let captureQueue = DispatchQueue(label: "com.local.lightpaste.capture", qos: .userInitiated)
    private var timer: Timer?
    private var lastChangeCount = 0
    private static let maximumBytes = 20 * 1_024 * 1_024
    private nonisolated static let summaryCharacterLimit = 131_072

    init(store: HistoryStore, pasteboard: NSPasteboard = .general,
         frontmost: @escaping @MainActor () -> Source? = ClipboardMonitor.systemFrontmost, onChange: @escaping () -> Void) {
        self.store = store
        self.pasteboard = pasteboard
        self.frontmost = frontmost
        self.onChange = onChange
    }

    static func systemFrontmost() -> Source? {
        NSWorkspace.shared.frontmostApplication.map { Source(name: $0.localizedName ?? "其他应用", bundleID: $0.bundleIdentifier) }
    }

    func start() {
        guard timer == nil else { return }
        // Do not inspect content already on the clipboard when the app starts.
        lastChangeCount = pasteboard.changeCount
        observedSource = frontmost()
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let source = app.map { Source(name: $0.localizedName ?? "其他应用", bundleID: $0.bundleIdentifier) }
            MainActor.assumeIsolated { self?.applicationDidActivate(source) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    /// Checks the clipboard before switching attribution, so a copy made in the previous app is
    /// judged (and excluded) as that app's, not the one the user switched to.
    func applicationDidActivate(_ source: Source?) {
        // Anything copied before this notification was copied in the app being left.
        poll(frontmostToo: false)
        observedSource = source
    }

    /// Call immediately after writing to NSPasteboard.general.
    func markOwnWrite() {
        lastChangeCount = pasteboard.changeCount
    }

    func poll() { poll(frontmostToo: true) }

    private func poll(frontmostToo: Bool) {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard !paused else { return }
        // A timer tick can run before the switch notification: if either the app last observed or
        // the app in front now is excluded, the copy may be theirs, so it is skipped rather than guessed.
        let current = frontmostToo || observedSource == nil ? frontmost() : nil
        let source = observedSource ?? current
        for candidate in [observedSource, current] {
            if let bundleID = candidate?.bundleID, excludedBundleIDs.contains(bundleID) { return }
        }
        let sourceName = source?.name ?? "其他应用"
        let sourceBundleID = source?.bundleID
        let entries: [ClipboardEntry]
        do {
            guard let read = try Self.readEntries(from: pasteboard) else { return }
            entries = read
        } catch {
            onError?(error.localizedDescription)
            return
        }
        let writer = store.captureWriter
        let sensitiveLifetime = store.sensitiveLifetime
        captureQueue.async { [weak self] in
            let outcome = Result { () throws -> (HistoryStore.PreparedCapture, CaptureWriter.Outcome)? in
                guard let clip = Self.clip(from: entries, sourceName: sourceName, sourceBundleID: sourceBundleID) else { return nil }
                let prepared = try HistoryStore.prepare(clip)
                return (prepared, writer.write(prepared, sensitiveLifetime: sensitiveLifetime))
            }
            // The queue is serial and each result hops to the main queue in order, so copies keep their order.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    do {
                        guard let (prepared, written) = try outcome.get() else { return }
                        switch written {
                        case .written(let result): try self.store.adoptCapture(result)
                        case .needsMainThread: try self.store.capture(prepared)
                        }
                        self.onChange()
                    } catch {
                        self.onError?(error.localizedDescription)
                    }
                }
            }
        }
    }

    /// Also accepts a private, named pasteboard for deterministic tests without touching the system clipboard.
    static func snapshot(from pasteboard: NSPasteboard, sourceName: String,
                         sourceBundleID: String?) throws -> CapturedClip? {
        guard let entries = try readEntries(from: pasteboard) else { return nil }
        return clip(from: entries, sourceName: sourceName, sourceBundleID: sourceBundleID)
    }

    /// Copies the raw representations while the pasteboard still holds this copy. Nothing is parsed here.
    static func readEntries(from pasteboard: NSPasteboard) throws -> [ClipboardEntry]? {
        let initialChangeCount = pasteboard.changeCount
        guard let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty else { return nil }
        let allTypes = (pasteboard.types ?? []) + pasteboardItems.flatMap(\.types)
        // Scan every item before asking any provider for its raw payload.
        guard !allTypes.contains(where: isPrivateType) else { return nil }

        var entries: [ClipboardEntry] = []
        var totalBytes = 0
        for item in pasteboardItems {
            var representations: [ClipboardRepresentation] = []
            let types = item.types.filter { isPersistentType($0) }.sorted { $0.rawValue < $1.rawValue }
            for type in types {
                guard let data = item.data(forType: type) else {
                    if pasteboard.changeCount != initialChangeCount { return nil }
                    throw ClipboardCaptureError.unavailable(type.rawValue)
                }
                guard data.count <= maximumBytes - totalBytes else { throw ClipboardCaptureError.tooLarge }
                totalBytes += data.count
                representations.append(ClipboardRepresentation(type: type.rawValue, data: data))
            }
            if !representations.isEmpty { entries.append(ClipboardEntry(representations: representations)) }
        }
        guard pasteboard.changeCount == initialChangeCount, !entries.isEmpty else { return nil }
        return entries
    }

    /// Text, links, files and image size from the copied data; safe off the main thread (RTF only, no HTML importer).
    nonisolated static func clip(from entries: [ClipboardEntry], sourceName: String,
                                 sourceBundleID: String?) -> CapturedClip? {
        guard !entries.isEmpty else { return nil }
        var plainTexts: [String] = []
        var richTexts: [String] = []
        var htmlTexts: [String] = []
        var rawHTML: [String] = []
        var fileURLs: [URL] = []
        var linkStrings: [String] = []
        var hasImage = false
        var imageSize: NSSize?

        for entry in entries {
            for representation in entry.representations {
                let type = NSPasteboard.PasteboardType(representation.type)
                let data = representation.data
                if type == .string, let text = decodeText(data) {
                    plainTexts.append(text)
                } else if type == .rtf,
                          let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
                    richTexts.append(attributed.string)
                } else if type == .html, let html = decodeText(data) {
                    rawHTML.append(html)
                    htmlTexts.append(htmlSummary(html))
                }

                if type == .fileURL, let string = decodeText(data), let url = URL(string: string), url.isFileURL {
                    fileURLs.append(url)
                } else if type.rawValue == "NSFilenamesPboardType",
                          let paths = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String] {
                    fileURLs.append(contentsOf: paths.map { URL(fileURLWithPath: $0) })
                } else if type == .URL, let string = decodeText(data) {
                    linkStrings.append(string)
                }

                if isImageType(type) {
                    hasImage = true
                    if imageSize == nil,
                       let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                       let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                       let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                       let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
                        imageSize = NSSize(width: width.doubleValue, height: height.doubleValue)
                    }
                }
            }
        }

        // The summary keeps one representation and is truncated; secrets are looked for in every text
        // the payload stores (all of plain text, RTF, raw HTML and links), since all of it is saved and pasted.
        let containsSecret = (plainTexts + richTexts + rawHTML + linkStrings).contains(where: ContentDetector.isSensitive)
        let selectedText = !plainTexts.isEmpty ? plainTexts : (!richTexts.isEmpty ? richTexts : htmlTexts)
        let text = String(selectedText.joined(separator: "\n").prefix(summaryCharacterLimit))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: ClipKind
        let title: String
        let searchableText: String
        if !fileURLs.isEmpty {
            kind = .files
            let uniqueURLs = Array(NSOrderedSet(array: fileURLs)) as? [URL] ?? fileURLs
            title = uniqueURLs.count == 1 ? uniqueURLs[0].lastPathComponent : "\(uniqueURLs.count) 个文件"
            searchableText = uniqueURLs.map(\.path).joined(separator: "\n")
        } else if hasImage {
            kind = .image
            if let imageSize {
                title = "图片 · \(Int(imageSize.width)) × \(Int(imageSize.height))"
            } else { title = "图片" }
            searchableText = text
        } else if !linkStrings.isEmpty || isWebLink(trimmed) {
            kind = .link
            let link = linkStrings.first ?? trimmed
            title = String((trimmed.isEmpty ? link : trimmed).prefix(160))
            searchableText = trimmed.isEmpty ? link : text
        } else if !trimmed.isEmpty {
            kind = .text
            title = String((trimmed.components(separatedBy: .newlines).first(where: { !$0.isEmpty }) ?? trimmed).prefix(160))
            searchableText = text
        } else {
            kind = .other
            title = "剪贴板内容"
            searchableText = ""
        }
        return CapturedClip(entries: entries, kind: kind, title: title, text: searchableText,
                            sourceName: sourceName, sourceBundleID: sourceBundleID,
                            containsSecret: containsSecret && kind != .files)
    }

    private nonisolated static func isPrivateType(_ type: NSPasteboard.PasteboardType) -> Bool {
        let name = type.rawValue.lowercased()
        return ["concealed", "confidential", "transient", "autogenerated", "password"].contains { name.contains($0) }
    }

    /// Produce complete text for a plain-text paste; list/search summaries may be truncated.
    nonisolated static func fullText(from entries: [ClipboardEntry]) -> String? {
        let texts = entries.compactMap { entry -> String? in
            for type in [NSPasteboard.PasteboardType.string, .rtf, .html, .URL, .fileURL] {
                guard let data = entry.representations.first(where: { $0.type == type.rawValue })?.data else { continue }
                if type == .rtf {
                    if let value = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) { return value.string }
                } else if type == .html {
                    if let value = decodeText(data) { return htmlSummary(value) }
                } else if let value = decodeText(data) { return value }
            }
            return nil
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func isPersistentType(_ type: NSPasteboard.PasteboardType) -> Bool {
        let name = type.rawValue.lowercased()
        guard !isPrivateType(type) else { return false }
        // Promises point into a live provider; persisting those bytes cannot make them replayable.
        if name.contains("promise") || name.contains("pasteboard.source") || name.contains("remote-clipboard") { return false }
        if name.hasPrefix("com.apple.pasteboard.") && (name.contains("type") || name.contains("metadata")) { return false }
        return true
    }

    private nonisolated static func isImageType(_ type: NSPasteboard.PasteboardType) -> Bool {
        if type == .png || type == .tiff { return true }
        return UTType(type.rawValue)?.conforms(to: .image) == true
    }

    private nonisolated static func decodeText(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        return nil
    }

    private nonisolated static func isWebLink(_ string: String) -> Bool {
        guard !string.contains(where: \.isWhitespace), let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else { return false }
        return true
    }

    /// A local text extractor; deliberately does not use WebKit / HTML importers that can fetch remote resources.
    private nonisolated static func htmlSummary(_ html: String) -> String {
        var result = html.replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1\\s*>", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?i)<(?:br\\s*/?|/p|/div|/li|/h[1-6])\\s*>", with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'"]
        for (entity, value) in entities { result = result.replacingOccurrences(of: entity, with: value) }
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let numberRange = Range(match.range(at: 1), in: result), let fullRange = Range(match.range, in: result) else { continue }
                let raw = String(result[numberRange])
                let number = raw.hasPrefix("x") ? UInt32(raw.dropFirst(), radix: 16) : UInt32(raw)
                if let number, let scalar = UnicodeScalar(number) { result.replaceSubrange(fullRange, with: String(scalar)) }
            }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}
