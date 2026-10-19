import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let inset = CGFloat(pixels) * 0.07
        let area = NSRect(x: inset, y: inset, width: CGFloat(pixels) - 2 * inset, height: CGFloat(pixels) - 2 * inset)
        NSColor(calibratedRed: 0.18, green: 0.38, blue: 0.31, alpha: 1).setFill()
        NSBezierPath(roundedRect: area, xRadius: CGFloat(pixels) * 0.2, yRadius: CGFloat(pixels) * 0.2).fill()
        if let symbol = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: CGFloat(pixels) * 0.43, weight: .medium)) {
            let drawing = NSRect(x: CGFloat(pixels) * 0.28, y: CGFloat(pixels) * 0.25, width: CGFloat(pixels) * 0.47, height: CGFloat(pixels) * 0.51)
            symbol.draw(in: drawing)
            NSColor.white.setFill()
            drawing.fill(using: .sourceAtop)
        }
        image.unlockFocus()
        let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try data.write(to: folder.appendingPathComponent(name))
    }
}
