import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Performance baseline with synthetic data only: a temporary database, a UUID-named pasteboard
/// and a separate defaults suite. It never reads NSPasteboard.general or the user's history.
/// Link previews and OCR are turned off, so nothing is fetched from the network.
/// The drawer is shown briefly on screen to time keyboard navigation and search typing.
/// Build: see README.md (all Sources except Launch.swift, plus this file, with -O).
@main
@MainActor
struct BenchPerformance {
    static var report: [String] = []

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        removeEmptyBenchPreferences()
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BENCH_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("lightpaste-bench-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "com.local.lightpaste.bench.\(UUID().uuidString)"
        var failed = false
        do {
            let dataDir = root.appendingPathComponent("data", isDirectory: true)
            log("机器：\(machine())；条目 \(itemCount)，其中图片 \(imageCount)")
            try autoreleasepool { try buildDataset(in: dataDir) }
            log(String(format: "数据库大小：%.1f MB", fileSize(dataDir.appendingPathComponent("history.sqlite3")) / 1_048_576))
            if ProcessInfo.processInfo.environment["BENCH_PROFILE"] == nil && ProcessInfo.processInfo.environment["BENCH_UI_ONLY"] == nil {
                try autoreleasepool { try benchStartup(dataDir) }
                try autoreleasepool { try benchCapture(copyOf: dataDir, to: root.appendingPathComponent("capture", isDirectory: true)) }
                try autoreleasepool { try benchSearch(dataDir) }
            }
            if ProcessInfo.processInfo.environment["BENCH_PROFILE"] == "startup" {
                FileHandle.standardError.write(Data("PROFILE-READY \(ProcessInfo.processInfo.processIdentifier)\n".utf8))
                let deadline = Date().addingTimeInterval(9)
                while Date() < deadline { try autoreleasepool { _ = try HistoryStore(directory: dataDir) } }
            } else {
                try benchUI(dataDir, suiteName: suiteName)
            }
        } catch {
            log("FAILED \(error)")
            failed = true
        }
        // exit() skips defer, so clean up explicitly before leaving.
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        CFPreferencesAppSynchronize(suiteName as CFString)
        removeEmptyBenchPreferences()
        if ProcessInfo.processInfo.environment["BENCH_KEEP"] == nil { try? FileManager.default.removeItem(at: root) }
        else { FileHandle.standardError.write(Data("KEPT \(root.path)\n".utf8)) }
        print(report.joined(separator: "\n"))
        exit(failed ? 1 : 0)
    }

    /// The preferences daemon may write a suite's empty file after it is removed; clear this script's own
    /// empty leftovers (com.local.lightpaste.bench.<UUID>.plist) so runs leave nothing behind.
    static func removeEmptyBenchPreferences() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix("com.local.lightpaste.bench.") && name.hasSuffix(".plist") {
            let url = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  values.isEmpty else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Dataset

    static let itemCount = Int(ProcessInfo.processInfo.environment["BENCH_ITEMS"] ?? "") ?? 1000
    static let imageCount = Int(ProcessInfo.processInfo.environment["BENCH_IMAGES"] ?? "") ?? 30
    static var rng = SplitMix(seed: 20261019)

    static let words = ["轻贴", "剪贴板", "会议", "项目", "configuration", "function", "release", "设计", "数据库", "search",
                        "performance", "报告", "客户", "deploy", "接口", "error", "timeout", "用户", "支付", "订单", "network",
                        "cache", "缓存", "测试", "review", "文档", "update", "index", "版本", "status"]

    static func prose(_ characters: Int) -> String {
        var parts: [String] = []
        var count = 0
        while count < characters {
            let word = words[rng.next(words.count)]
            parts.append(word); count += word.count + 1
            if rng.next(12) == 0 { parts.append("\n"); count += 1 }
        }
        return parts.joined(separator: " ")
    }

    static func code(_ lines: Int) -> String {
        (0..<lines).map { i in
            switch rng.next(4) {
            case 0: return "    let value\(i) = load(\"\(words[rng.next(words.count)])\", count: \(rng.next(500)));"
            case 1: return "func handle\(i)(request: Request) async throws -> Response {"
            case 2: return "    // \(prose(40))"
            default: return "}"
            }
        }.joined(separator: "\n")
    }

    static func textClip(_ text: String, rich: Bool = false) -> CapturedClip {
        var reps = [ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))]
        if rich {
            let html = "<html><body><p>" + text.replacingOccurrences(of: "\n", with: "</p><p>") + "</p></body></html>"
            reps.append(ClipboardRepresentation(type: NSPasteboard.PasteboardType.html.rawValue, data: Data(html.utf8)))
            let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)])
            if let rtf = attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]) {
                reps.append(ClipboardRepresentation(type: NSPasteboard.PasteboardType.rtf.rawValue, data: rtf))
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = String((trimmed.components(separatedBy: .newlines).first(where: { !$0.isEmpty }) ?? trimmed).prefix(160))
        return CapturedClip(entries: [ClipboardEntry(representations: reps)], kind: .text, title: title,
                            text: String(text.prefix(131_072)), sourceName: "合成应用", sourceBundleID: "bench.synthetic.app\(rng.next(8))")
    }

    static func linkClip(_ index: Int) -> CapturedClip {
        let url = "https://docs\(index).example.invalid/\(words[rng.next(words.count)])/page?id=\(index)"
        return CapturedClip(entries: [ClipboardEntry(representations: [
            ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(url.utf8)),
            ClipboardRepresentation(type: NSPasteboard.PasteboardType.URL.rawValue, data: Data(url.utf8))
        ])], kind: .link, title: url, text: url, sourceName: "合成浏览器", sourceBundleID: "bench.synthetic.browser")
    }

    /// A screenshot-like image: flat panels, text-like bars and some noise; PNG plus uncompressed TIFF like browsers provide.
    static func imageReps(seed: Int, width: Int = 1600, height: Int = 1000) -> [ClipboardRepresentation] {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var local = SplitMix(seed: UInt64(seed) &+ 99)
        context.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for _ in 0..<400 {
            context.setFillColor(CGColor(red: CGFloat(local.next(255)) / 255, green: CGFloat(local.next(255)) / 255,
                                         blue: CGFloat(local.next(255)) / 255, alpha: 1))
            context.fill(CGRect(x: local.next(width), y: local.next(height), width: 20 + local.next(300), height: 6 + local.next(14)))
        }
        for _ in 0..<20_000 {
            context.setFillColor(CGColor(gray: CGFloat(local.next(255)) / 255, alpha: 1))
            context.fill(CGRect(x: local.next(width), y: local.next(height), width: 2, height: 2))
        }
        let image = context.makeImage()!
        let png = NSMutableData()
        let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation ?? Data()
        return [ClipboardRepresentation(type: NSPasteboard.PasteboardType.png.rawValue, data: png as Data),
                ClipboardRepresentation(type: NSPasteboard.PasteboardType.tiff.rawValue, data: tiff)]
    }

    static func imageClip(_ index: Int) -> CapturedClip {
        CapturedClip(entries: [ClipboardEntry(representations: imageReps(seed: index))], kind: .image,
                     title: "图片 · 1600 × 1000", text: "", sourceName: "合成截图", sourceBundleID: "bench.synthetic.screenshot")
    }

    /// Mix: images spread through history, ~6% links, ~15% code, ~10% medium text, ~3% long rich text, the rest short text.
    static func buildDataset(in directory: URL) throws {
        let store = try HistoryStore(directory: directory)
        store.maximumItems = itemCount
        let start = now()
        let imageEvery = max(1, itemCount / max(1, imageCount))
        var images = 0
        for index in 0..<itemCount {
            let clip: CapturedClip
            if images < imageCount && index % imageEvery == imageEvery / 2 {
                clip = imageClip(index); images += 1
            } else {
                switch rng.next(100) {
                case 0..<6: clip = linkClip(index)
                case 6..<21: clip = textClip(code(10 + rng.next(60)))
                case 21..<31: clip = textClip(prose(5_000 + rng.next(15_000)), rich: rng.next(2) == 0)
                case 31..<34: clip = textClip(prose(80_000 + rng.next(60_000)), rich: true)
                default: clip = textClip(prose(20 + rng.next(400)) + " #\(index)")
                }
            }
            try store.capture(clip)
        }
        log(String(format: "生成数据：%d 条，用时 %.1f s", store.items.count, seconds(since: start)))
    }

    // MARK: Startup

    static func benchStartup(_ directory: URL) throws {
        var storeTimes: [Double] = []
        for _ in 0..<5 {
            let start = now()
            let store = try HistoryStore(directory: directory)
            storeTimes.append(ms(since: start))
            precondition(store.items.count == itemCount)
        }
        log("启动·打开数据库并载入列表（HistoryStore.init，热缓存）：\(stats(storeTimes))")
        var immediate: [Double] = [], settled: [Double] = []
        for _ in 0..<3 {
            let store = try HistoryStore(directory: directory)
            let start = now()
            _ = store.search("function", filter: .history)
            immediate.append(ms(since: start))
            let later = try HistoryStore(directory: directory)
            spin(0.5)
            let start2 = now()
            _ = later.search("function", filter: .history)
            settled.append(ms(since: start2))
        }
        log("启动·启动后立即搜索（含补建索引）：\(stats(immediate))；启动 0.5 秒后搜索：\(stats(settled))")
    }

    // MARK: Capture

    /// Captures into a copy of the full dataset, so list and retention work matches a real 1,000-item history.
    static func benchCapture(copyOf dataset: URL, to directory: URL) throws {
        try FileManager.default.copyItem(at: dataset, to: directory)
        let store = try HistoryStore(directory: directory)
        store.maximumItems = itemCount + 100
        let board = NSPasteboard(name: NSPasteboard.Name("LightPasteBench-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }

        func run(_ label: String, iterations: Int, write: (Int) -> Void) throws {
            var readTimes: [Double] = [], prepareTimes: [Double] = [], writeTimes: [Double] = []
            for i in 0..<iterations {
                write(i)
                let a = now()
                guard let entries = try ClipboardMonitor.readEntries(from: board) else { throw BenchError("\(label) 读取为空") }
                let b = now()
                guard let clip = ClipboardMonitor.clip(from: entries, sourceName: "合成应用", sourceBundleID: "bench.synthetic") else {
                    throw BenchError("\(label) 解析为空")
                }
                let prepared = try HistoryStore.prepare(clip)
                let outcome = store.captureWriter.write(prepared, sensitiveLifetime: store.sensitiveLifetime)
                let c = now()
                switch outcome {
                case .written(let written): guard try store.adoptCapture(written) != nil else { throw BenchError("\(label) 未并入") }
                case .needsMainThread: throw BenchError("\(label) 意外回到主线程写入")
                }
                readTimes.append(ms(between: a, b)); prepareTimes.append(ms(between: b, c)); writeTimes.append(ms(since: c))
            }
            log("采集·\(label)：主线程读取 \(stats(readTimes))；后台解析+哈希+编码+写库 \(stats(prepareTimes))；主线程并入列表 \(stats(writeTimes))")
        }

        try run("短文本", iterations: 30) { i in
            board.clearContents(); board.setString(prose(200) + " \(i)", forType: .string)
        }
        try run("10 万字富文本（纯文本+RTF+HTML）", iterations: 10) { i in
            let text = prose(100_000) + " \(i)"
            let clip = textClip(text, rich: true)
            board.clearContents()
            for rep in clip.entries[0].representations { board.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.type)) }
        }
        try run("图片 1600×1000（PNG+TIFF）", iterations: 8) { i in
            board.clearContents()
            for rep in imageReps(seed: 50_000 + i) { board.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.type)) }
        }
    }

    // MARK: Search (store level)

    static func benchSearch(_ directory: URL) throws {
        let store = try HistoryStore(directory: directory)
        for query in ["a", "轻贴", "function", "configuration release", "zzqxnotfound"] {
            var times: [Double] = []
            var count = 0
            for _ in 0..<15 {
                let start = now()
                count = store.search(query, filter: .history).count
                times.append(ms(since: start))
            }
            log("搜索·存储层「\(query)」→ \(count) 条：\(stats(times))")
        }
    }

    // MARK: UI: open drawer, arrow keys, typing

    static func benchUI(_ directory: URL, suiteName: String) throws {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(false, forKey: "linkPreview")
        defaults.set(false, forKey: "ocr")
        defaults.set(true, forKey: "onboardingDone")
        defaults.set(itemCount, forKey: "maxItems")
        defaults.set(36_500, forKey: "retentionDays")

        let baseFootprint = footprintMB()
        let initStart = now()
        let controller = try AppController(directory: directory, defaults: defaults)
        controller.pauseCapture(for: nil)
        let initTime = ms(since: initStart)
        defer { controller.stop() }
        spin(0.3)
        log(String(format: "启动·AppController 初始化：%.1f ms；内存增量 %.0f MB", initTime, footprintMB() - baseFootprint))

        let openStart = now()
        controller.showDrawer()
        guard let window = NSApp.windows.first(where: { $0 is ClipboardWindow && $0.isVisible }) as? ClipboardWindow else {
            throw BenchError("抽屉窗口未出现")
        }
        func key(_ code: UInt16, _ characters: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: characters,
                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        flush(window)
        log(String(format: "启动·首次打开抽屉到首帧：%.1f ms", ms(since: openStart)))
        spin(0.6)
        log(String(format: "打开抽屉后内存增量 %.0f MB", footprintMB() - baseFootprint))
        var idle: [Double] = []
        for _ in 0..<60 { let start = now(); flush(window); idle.append(ms(since: start)) }
        log("对照·无操作刷新一次：\(stats(idle))")
        if let profile = ProcessInfo.processInfo.environment["BENCH_PROFILE"] {
            FileHandle.standardError.write(Data("PROFILE-READY \(ProcessInfo.processInfo.processIdentifier)\n".utf8))
            spin(1.0)
            let deadline = Date().addingTimeInterval(8)
            var i = 0
            while Date() < deadline {
                if profile == "arrows" {
                    window.sendEvent(i % 200 < 100 ? key(124, "\u{F703}") : key(123, "\u{F702}"))
                } else {
                    let word = "configuration"
                    controller.query = String(word.prefix(i % word.count + 1))
                }
                flush(window); i += 1
            }
            controller.query = ""
            return
        }

        let right = key(124, "\u{F703}"), left = key(123, "\u{F702}")

        func arrows(_ label: String, steps: Int) {
            var times: [Double] = []
            let total = now()
            for i in 0..<steps {
                let start = now()
                window.sendEvent(i < steps / 2 ? right : left)
                flush(window)
                times.append(ms(since: start))
            }
            log(String(format: "方向键·\(label)（%d 次）：\(stats(times))；总计 %.0f ms", steps, ms(since: total)))
        }
        arrows("无搜索", steps: 120)
        if let path = ProcessInfo.processInfo.environment["BENCH_SNAPSHOT"], let view = window.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }

        func typing(_ word: String) {
            var times: [Double] = []
            var typed = ""
            for character in word {
                typed.append(character)
                let start = now()
                controller.query = typed
                flush(window)
                times.append(ms(since: start))
            }
            log("搜索·界面逐字输入「\(word)」→ \(controller.filteredItems.count) 条：\(stats(times))")
            controller.query = ""; flush(window)
        }
        typing("configuration")
        typing("function")
        typing("轻贴剪贴板")

        controller.query = "function"; flush(window)
        arrows("搜索「function」高亮中", steps: 60)
        controller.query = ""; flush(window)
        controller.dismissDrawer()
        spin(0.4)
    }

    // MARK: Helpers

    static func flush(_ window: NSWindow) {
        for _ in 0..<3 { RunLoop.main.run(mode: .default, before: Date()) }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    static func spin(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: .default, before: min(end, Date().addingTimeInterval(0.02))) }
    }

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func ms(since start: UInt64) -> Double { Double(now() - start) / 1_000_000 }
    static func ms(between a: UInt64, _ b: UInt64) -> Double { Double(b - a) / 1_000_000 }
    static func seconds(since start: UInt64) -> Double { ms(since: start) / 1000 }

    static func stats(_ values: [Double]) -> String {
        let sorted = values.sorted()
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))] }
        return String(format: "中位 %.2f ms，P95 %.2f ms，最大 %.2f ms", at(0.5), at(0.95), sorted.last ?? 0)
    }

    static func log(_ line: String) { report.append(line); FileHandle.standardError.write(Data((line + "\n").utf8)) }

    static func fileSize(_ url: URL) -> Double {
        let base = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.doubleValue ?? 0
        let wal = (try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? NSNumber)?.doubleValue ?? 0
        return base + wal
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func machine() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer) + "，macOS " + ProcessInfo.processInfo.operatingSystemVersionString
    }

    struct BenchError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

/// Deterministic generator, so every run builds the same dataset.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ upperBound: Int) -> Int {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Int(z % UInt64(max(1, upperBound)))
    }
}
