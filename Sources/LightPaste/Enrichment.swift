import AppKit
import Vision
import LinkPresentation
import QuickLookThumbnailing

/// On-device text recognition for copied images. Nothing leaves the Mac.
enum OCRService {
    static func recognize(_ image: CGImage) async -> String {
        await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do { try handler.perform([request]) } catch { return "" }
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        }.value
    }
}

/// Fetches a page title and icon for a copied link. Only the link's own host is contacted.
enum LinkPreviewService {
    static func webURL(in item: ClipItem) -> URL? {
        let candidates = (item.text.prefix(2048).split(whereSeparator: \.isWhitespace).prefix(12).map(String.init)) + [item.title]
        for candidate in candidates {
            if let url = URL(string: candidate), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil {
                return url
            }
        }
        return nil
    }

    /// Whether copying this link may contact its site on its own. Internal addresses, embedded
    /// credentials and links carrying tokens are left alone; the card menu can still fetch them once.
    /// This judges the URL as written; where redirects lead is up to the system loader.
    static func allowsAutomaticFetch(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let rawHost = url.host?.lowercased(), !rawHost.isEmpty else { return false }
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        if isInternalHost(host) { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return !items.contains { item in
            let name = item.name.lowercased()
            return credentialParameters.contains(name) || credentialSuffixes.contains { name.hasSuffix($0) }
        }
    }

    private static let credentialParameters: Set<String> = [
        "token", "access_token", "id_token", "refresh_token", "auth", "authorization", "code", "key", "apikey", "api_key",
        "secret", "client_secret", "password", "passwd", "pwd", "sig", "signature", "session", "sessionid", "sid",
        "ticket", "otp", "jwt", "credential", "credentials", "x-amz-signature", "x-amz-credential", "x-amz-security-token"
    ]
    private static let credentialSuffixes = ["token", "secret", "signature", "password", "_key", "-key"]

    /// Loopback, private, link-local and shared IPv4/IPv6 ranges, plus names that only resolve inside a network.
    static func isInternalHost(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || !host.contains(".") && !host.contains(":") { return true }
        for suffix in [".localhost", ".local", ".internal", ".intranet", ".lan", ".home", ".corp", ".home.arpa"]
        where host.hasSuffix(suffix) { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        if octets.count == 4, octets.allSatisfy({ $0.map { (0...255).contains($0) } ?? false }) {
            let a = octets[0]!, b = octets[1]!
            return a == 0 || a == 10 || a == 127 || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b))
                || (a == 192 && b == 168) || (a == 100 && (64...127).contains(b)) || a >= 224
        }
        if host.contains(":") {
            let lower = host.lowercased()
            return lower == "::1" || lower == "::" || lower.hasPrefix("fc") || lower.hasPrefix("fd")
                || lower.hasPrefix("fe8") || lower.hasPrefix("fe9") || lower.hasPrefix("fea") || lower.hasPrefix("feb")
                || lower.hasPrefix("::ffff:")
        }
        return false
    }

    @MainActor
    static func fetch(_ url: URL) async -> (title: String, icon: Data?) {
        let provider = LPMetadataProvider()
        provider.timeout = 8
        provider.shouldFetchSubresources = false
        // Cancelling the task (setting turned off, app quitting) stops the network request too.
        let fetched = await withTaskCancellationHandler {
            try? await provider.startFetchingMetadata(for: url)
        } onCancel: {
            provider.cancel()
        }
        guard let metadata = fetched, !Task.isCancelled else { return ("", nil) }
        let title = (metadata.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var icon: Data?
        if let iconProvider = metadata.iconProvider, iconProvider.canLoadObject(ofClass: NSImage.self) {
            let image: NSImage? = await withCheckedContinuation { continuation in
                iconProvider.loadObject(ofClass: NSImage.self) { object, _ in continuation.resume(returning: object as? NSImage) }
            }
            icon = image.flatMap { pngData($0, side: 64) }
        }
        return (String(title.prefix(200)), icon)
    }

    static func pngData(_ image: NSImage, side: CGFloat) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// Application and file icons, their dominant colors and Quick Look thumbnails, cached in memory.
@MainActor
final class IconProvider {
    private var appIcons: [String: NSImage] = [:]
    private var tints: [String: NSColor?] = [:]
    private let fileIcons = NSCache<NSString, NSImage>()
    private let thumbnails = NSCache<NSString, NSImage>()
    private var missingThumbnails = Set<String>()
    /// Apps that are no longer installed; cards would otherwise ask Launch Services on every redraw.
    private var missingAppIcons = Set<String>()

    init() { fileIcons.countLimit = 200; thumbnails.countLimit = 60 }

    func appIcon(bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let cached = appIcons[bundleID] { return cached }
        guard !missingAppIcons.contains(bundleID) else { return nil }
        let icon: NSImage?
        if bundleID == Bundle.main.bundleIdentifier { icon = NSApp.applicationIconImage }
        else { icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) } }
        if let icon { appIcons[bundleID] = icon } else { missingAppIcons.insert(bundleID) }
        return icon
    }

    /// Average color of the app icon, or nil when the icon is mostly gray.
    func tint(bundleID: String?) -> NSColor? {
        guard let bundleID else { return nil }
        if let cached = tints[bundleID] { return cached }
        var color: NSColor?
        if let icon = appIcon(bundleID: bundleID),
           let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 12, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            icon.draw(in: NSRect(x: 0, y: 0, width: 12, height: 12))
            NSGraphicsContext.restoreGraphicsState()
            var r = 0.0, g = 0.0, b = 0.0, weight = 0.0
            for x in 0..<12 { for y in 0..<12 {
                guard let pixel = rep.colorAt(x: x, y: y), pixel.alphaComponent > 0.5 else { continue }
                // Favor saturated pixels so a white icon background does not wash out the brand color.
                let w = 0.2 + pixel.saturationComponent
                r += pixel.redComponent * w; g += pixel.greenComponent * w; b += pixel.blueComponent * w; weight += w
            } }
            if weight > 0 {
                let average = NSColor(deviceRed: r / weight, green: g / weight, blue: b / weight, alpha: 1)
                if average.saturationComponent > 0.18 { color = average }
            }
        }
        tints[bundleID] = color
        return color
    }

    func fileIcon(path: String) -> NSImage {
        if let cached = fileIcons.object(forKey: path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        // A fixed 128-point size lets AppKit pick one representation instead of scaling the largest.
        icon.size = NSSize(width: 128, height: 128)
        fileIcons.setObject(icon, forKey: path as NSString)
        return icon
    }

    /// Quick Look thumbnail at up to 256×256 points; nil when the file has none (callers show its 128-point icon).
    func thumbnail(path: String, size: CGSize = CGSize(width: 256, height: 256)) async -> NSImage? {
        if let cached = thumbnails.object(forKey: path as NSString) { return cached }
        guard !missingThumbnails.contains(path), FileManager.default.fileExists(atPath: path) else { return nil }
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: size,
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            missingThumbnails.insert(path); return nil
        }
        let image = representation.nsImage
        thumbnails.setObject(image, forKey: path as NSString)
        return image
    }
}
