import Foundation
import CoreGraphics

enum DrawerEdge: String, CaseIterable, Identifiable {
    case bottom, top
    var id: String { rawValue }
    var title: String { self == .bottom ? "底部抽屉" : "顶部抽屉" }
}

enum DrawerGeometry {
    static func frames(screenFrame: CGRect, visibleFrame: CGRect, edge: DrawerEdge,
                       height: CGFloat = 340) -> (shown: CGRect, hidden: CGRect) {
        let drawerHeight = min(max(height, 220), max(220, visibleFrame.height * 0.65))
        let shownY = edge == .bottom ? screenFrame.minY : visibleFrame.maxY - drawerHeight
        let hiddenY = edge == .bottom ? screenFrame.minY - drawerHeight - 12 : screenFrame.maxY + 12
        return (
            CGRect(x: screenFrame.minX, y: shownY, width: screenFrame.width, height: drawerHeight),
            CGRect(x: screenFrame.minX, y: hiddenY, width: screenFrame.width, height: drawerHeight)
        )
    }
}

/// Card density chosen in settings. The drawer height follows the card height.
enum CardSize: String, CaseIterable, Identifiable {
    case compact, standard, large
    var id: String { rawValue }
    var title: String { self == .compact ? "紧凑" : self == .standard ? "标准" : "宽松" }
    var width: CGFloat { self == .compact ? 200 : self == .standard ? 236 : 280 }
    var height: CGFloat { self == .compact ? 190 : self == .standard ? 222 : 260 }
    /// Toolbar 52 + separators 2 + strip padding 24 + footer 30 + selection headroom 10.
    var drawerHeight: CGFloat { height + 118 }
}
