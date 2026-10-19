import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Exercises the real background resource actor using its own temporary database.
/// No pasteboard, windows, or existing user data are accessed.
/// Compile Models.swift, HistoryStore.swift, ClipResources.swift and this file with
/// swiftc -swift-version 5 -parse-as-library ... -lsqlite3.
@main
struct VerifyResources {
    private struct Failure: Error { let check: String }

    private static func require(_ condition: @autoclosure () -> Bool, _ check: String) throws {
        guard condition() else { throw Failure(check: check) }
    }

    private static func captured(data: Data, type: String, kind: ClipKind, summary: String) -> CapturedClip {
        CapturedClip(entries: [ClipboardEntry(representations: [ClipboardRepresentation(type: type, data: data)])],
                     kind: kind, title: "资源验证", text: summary, sourceName: "测试应用", sourceBundleID: "local.lightpaste.tests")
    }

    private static func tiffFixture() throws -> Data {
        guard let context = CGContext(data: nil, width: 1600, height: 900, bitsPerComponent: 8, bytesPerRow: 1600 * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(check: "应可创建内存图像")
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 900))
        guard let image = context.makeImage() else { throw Failure(check: "应可获取内存图像") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil) else {
            throw Failure(check: "应可创建 TIFF 测试载荷")
        }
        CGImageDestinationAddImage(destination, image, nil)
        try require(CGImageDestinationFinalize(destination), "应可编码 TIFF 测试载荷")
        return data as Data
    }

    @MainActor
    static func main() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LightPasteResourcesVerification-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let store = try HistoryStore(directory: directory)
            let resources = ClipResources(directory: directory)
            let longText = String(repeating: "后台资源导出长文本。", count: 20_000) + "完整末尾标记"
            let textItem = try store.capture(captured(data: Data(longText.utf8), type: UTType.utf8PlainText.identifier,
                                                     kind: .text, summary: String(longText.prefix(128))))
            let exportedText = try await resources.exportData(id: textItem.id, type: UTType.utf8PlainText.identifier)
            try require(textItem.text.count < longText.count && exportedText == Data(longText.utf8), "长文本导出应使用完整载荷而非摘要")
            print("PASS 长文本后台导出不截断")

            let rawLink = "  https://example.com/document?q=clipboard  \n"
            let linkItem = try store.capture(captured(data: Data(rawLink.utf8), type: UTType.utf8PlainText.identifier,
                                                     kind: .link, summary: rawLink))
            let exportedURL = try await resources.exportData(id: linkItem.id, type: UTType.url.identifier)
            try require(String(data: exportedURL, encoding: .utf8) == "https://example.com/document?q=clipboard", "纯文本链接应转换为可拖出的 URL")
            try require(ClipResources.exportTypes(for: .link).contains(UTType.url.identifier), "链接应声明 URL 拖出格式")
            print("PASS 纯文本链接转 URL")

            let tiff = try tiffFixture()
            let imageItem = try store.capture(captured(data: tiff, type: UTType.tiff.identifier, kind: .image, summary: "测试图片"))
            let png = try await resources.exportData(id: imageItem.id, type: UTType.png.identifier)
            try require(png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), "TIFF 应导出为有效 PNG")
            guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let thumbnail = await resources.thumbnail(id: imageItem.id) else { throw Failure(check: "PNG 和缩略图应可解码") }
            try require(image.width == 1600 && image.height == 900, "拖出 PNG 应保留原图尺寸")
            try require(thumbnail.width > 0 && thumbnail.height > 0 && max(thumbnail.width, thumbnail.height) <= 480, "缩略图最长边应不超过 480")
            let cachedThumbnail = await resources.thumbnail(id: imageItem.id)
            try require(cachedThumbnail?.width == thumbnail.width && cachedThumbnail?.height == thumbnail.height, "重复获取缩略图应保持尺寸")
            print("PASS TIFF 转 PNG 与受限尺寸缩略图")

            let file = directory.appendingPathComponent("原样 文件.txt")
            try Data("临时文件".utf8).write(to: file)
            let originalURL = Data(file.absoluteString.utf8)
            let fileItem = try store.capture(captured(data: originalURL, type: UTType.fileURL.identifier, kind: .files, summary: file.path))
            let exportedFile = try await resources.exportData(id: fileItem.id, type: UTType.fileURL.identifier)
            try require(exportedFile == originalURL, "文件 URL 导出应保持原始字节")
            print("PASS 文件 URL 原样导出")

            let missingID = UUID()
            var rejectedMissing = false
            do { _ = try await resources.exportData(id: missingID, type: UTType.utf8PlainText.identifier) }
            catch { rejectedMissing = true }
            let missingThumbnail = await resources.thumbnail(id: missingID)
            try require(rejectedMissing && missingThumbnail == nil, "不存在的记录应导出失败并没有缩略图")
            print("PASS 不存在的记录安全失败")
            print("后台资源验证通过：5 项。")
        } catch let error as Failure {
            print("FAIL \(error.check)")
            try? FileManager.default.removeItem(at: directory)
            Darwin.exit(1)
        } catch {
            print("FAIL 后台资源验证遇到运行错误（\(String(reflecting: type(of: error)))）。")
            try? FileManager.default.removeItem(at: directory)
            Darwin.exit(1)
        }
    }
}
