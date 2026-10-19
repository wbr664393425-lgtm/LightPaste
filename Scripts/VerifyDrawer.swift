import Foundation
import CoreGraphics

/// Pure layout validation. No AppKit, windows, clipboard, or user data are accessed.
/// Compile with DrawerGeometry.swift and -parse-as-library, then run the executable.
@main
struct VerifyDrawer {
    private struct Failure: Error { let message: String }

    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure(message: message) }
    }

    static func main() {
        let displays: [(name: String, screen: CGRect, visible: CGRect)] = [
            ("主屏与底部 Dock", CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 0, y: 64, width: 1440, height: 812)),
            ("负横坐标副屏与左 Dock", CGRect(x: -1920, y: 120, width: 1920, height: 1080), CGRect(x: -1880, y: 120, width: 1880, height: 1056)),
            ("负纵坐标副屏与右 Dock", CGRect(x: 400, y: -1200, width: 1600, height: 1000), CGRect(x: 400, y: -1200, width: 1548, height: 976)),
            ("上方副屏", CGRect(x: 200, y: 900, width: 1280, height: 1024), CGRect(x: 200, y: 930, width: 1280, height: 970)),
            ("负坐标竖屏", CGRect(x: -1080, y: -500, width: 1080, height: 1920), CGRect(x: -1080, y: -500, width: 1080, height: 1896))
        ]
        var configurations = 0
        do {
            for display in displays {
                for edge in DrawerEdge.allCases {
                    for height in [CGFloat(0), CGFloat(340), CGFloat(10_000)] {
                        let result = DrawerGeometry.frames(screenFrame: display.screen, visibleFrame: display.visible, edge: edge, height: height)
                        let shown = result.shown
                        let hidden = result.hidden
                        try require(shown.minX == display.screen.minX && shown.width == display.screen.width, "抽屉应横向贴满所在屏幕")
                        try require(hidden.minX == shown.minX && hidden.size == shown.size, "动画只应改变纵向位置")
                        try require(shown.height >= 220 && shown.height <= display.visible.height * 0.65, "高度应在可用区约束内")
                        try require(shown.minY >= display.screen.minY && shown.maxY <= display.screen.maxY, "显示位置应完整位于所在屏幕")
                        try require(!hidden.intersects(display.screen), "隐藏位置应完全离开所在屏幕")
                        if edge == .bottom {
                            try require(shown.minY == display.screen.minY, "底部抽屉应从屏幕底边展开")
                            try require(hidden.maxY < display.screen.minY, "底部隐藏应完全低于屏幕")
                        } else {
                            try require(shown.maxY == display.visible.maxY, "顶部抽屉应贴在菜单栏下方")
                            try require(hidden.minY > display.screen.maxY, "顶部隐藏应完全高于屏幕")
                        }
                        configurations += 1
                    }
                }
                print("PASS \(display.name)：上下边缘与高度约束")
            }
            let primary = displays[0]
            let minimum = DrawerGeometry.frames(screenFrame: primary.screen, visibleFrame: primary.visible, edge: .bottom, height: -1)
            try require(minimum.shown.height == 220, "负高度应钳制到最小高度")
            for size in CardSize.allCases {
                for display in displays {
                    let frames = DrawerGeometry.frames(screenFrame: display.screen, visibleFrame: display.visible,
                                                       edge: .bottom, height: size.drawerHeight)
                    try require(frames.shown.height >= min(size.drawerHeight, display.visible.height * 0.65),
                                "\(size.title)卡片应完整放入抽屉")
                    try require(size.drawerHeight - size.height >= 110, "\(size.title)卡片应保留工具栏和底栏空间")
                    configurations += 1
                }
            }
            print("PASS 紧凑 / 标准 / 宽松三档卡片高度")
            print("布局验证通过：\(configurations) 种配置及负高度边界。")
        } catch let error as Failure {
            print("FAIL \(error.message)")
            Darwin.exit(1)
        } catch {
            print("FAIL 布局验证遇到运行错误。")
            Darwin.exit(1)
        }
    }
}
