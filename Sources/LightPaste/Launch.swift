import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: AppController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        makeMenu()
        do {
            let folder: URL
            if let override = ProcessInfo.processInfo.environment["LIGHTPASTE_DATA_DIR"] { folder = URL(fileURLWithPath: override, isDirectory: true) }
            else { folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("LightPaste", isDirectory: true) }
            let defaults = ProcessInfo.processInfo.environment["LIGHTPASTE_DATA_DIR"] == nil ? UserDefaults.standard : UserDefaults(suiteName: "com.local.lightpaste.acceptance")!
            controller = try AppController(directory: folder, defaults: defaults)
            controller?.launch()
        } catch {
            let alert = NSAlert(); alert.messageText = "轻贴无法打开本地资料库"; alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "退出"); alert.runModal(); NSApp.terminate(nil)
        }
    }
    func applicationWillTerminate(_ notification: Notification) { controller?.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showDrawer(); return true
    }
    @objc func openDrawer() { controller?.showDrawer() }
    @objc func openSettings() { controller?.showSettings() }
    @objc func newText() { controller?.createTextItem() }
    private func makeMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem(); bar.addItem(appItem)
        let app = NSMenu(title: "轻贴"); appItem.submenu = app
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ","); settings.target = self; app.addItem(settings)
        app.addItem(.separator()); app.addItem(withTitle: "退出轻贴", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem(); bar.addItem(fileItem); let file = NSMenu(title: "文件"); fileItem.submenu = file
        let drawer = NSMenuItem(title: "打开抽屉", action: #selector(openDrawer), keyEquivalent: "d"); drawer.target = self; file.addItem(drawer)
        let new = NSMenuItem(title: "新建常用文本…", action: #selector(newText), keyEquivalent: "n"); new.target = self; file.addItem(new)
        let editItem = NSMenuItem(); bar.addItem(editItem); let edit = NSMenu(title: "编辑"); editItem.submenu = edit
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator()); edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = bar
    }
}

@main
struct LightPasteApplication {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
