import AppKit
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = size * scale
        let image = NSImage(size: NSSize(width: px, height: px))
        image.lockFocus()
        let area = NSRect(x: 0, y: 0, width: px, height: px)
        NSColor(calibratedRed: 0.06, green: 0.43, blue: 0.47, alpha: 1).setFill()
        NSBezierPath(roundedRect: area.insetBy(dx: CGFloat(px) * 0.06, dy: CGFloat(px) * 0.06), xRadius: CGFloat(px) * 0.20, yRadius: CGFloat(px) * 0.20).fill()
        if let symbol = NSImage(systemSymbolName: "doc.on.clipboard.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: CGFloat(px) * 0.56, weight: .medium))?
            .withSymbolConfiguration(.init(paletteColors: [.white])) {
            let width = CGFloat(px) * 0.52, height = CGFloat(px) * 0.60
            symbol.draw(in: NSRect(x: (CGFloat(px) - width) / 2, y: (CGFloat(px) - height) / 2, width: width, height: height))
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
