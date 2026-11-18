import AppKit

private final class EdgePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class EdgeBarView: NSView {
    var progress: Double = 0 { didSet { needsDisplay = true } }
    var connected = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let width: CGFloat = connected ? 3 : 5 + 7 * CGFloat(progress)
        let rect = NSRect(x: (bounds.width - width) / 2, y: 6, width: width, height: bounds.height - 12)
        NSColor.black.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: width / 2 + 2, yRadius: width / 2 + 2).fill()
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
        let height = connected ? rect.height : max(width, rect.height * CGFloat(progress))
        let fill = NSRect(x: rect.minX, y: rect.midY - height / 2, width: width, height: height)
        NSColor.systemTeal.withAlphaComponent(connected ? 0.8 : 1).setFill()
        NSBezierPath(roundedRect: fill, xRadius: width / 2, yRadius: width / 2).fill()
    }
}

// A click-through edge affordance. It never activates the app or changes the
// focused field, and has no keyboard handlers or input-monitoring behavior.
final class ControlEdgeIndicator {
    private let panel: NSPanel
    private let bar = EdgeBarView(frame: NSRect(x: 0, y: 0, width: 20, height: 112))
    init() {
        panel = EdgePanel(contentRect: bar.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.level = .statusBar; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = bar
        bar.setAccessibilityLabel(ui("Mouse and keyboard handoff indicator"))
    }
    var isNonInteractive: Bool { panel.ignoresMouseEvents && !panel.canBecomeKey && !panel.canBecomeMain }
    func show(at point: CGPoint, side: ScreenSide, progress: Double, connected: Bool) {
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayBounds(id).insetBy(dx: -1, dy: -1).contains(point)
        }) ?? NSScreen.main,
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }
        let cgBounds = CGDisplayBounds(id)
        let y = screen.frame.maxY - (point.y - cgBounds.minY) * screen.frame.height / max(1, cgBounds.height)
        let x = side == .left ? screen.frame.minX : screen.frame.maxX - panel.frame.width
        panel.setFrameOrigin(NSPoint(x: x, y: max(screen.frame.minY + 8, min(screen.frame.maxY - panel.frame.height - 8, y - panel.frame.height / 2))))
        bar.progress = max(0, min(1, progress)); bar.connected = connected
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }
    static func previewView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        view.wantsLayer = true; view.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1).cgColor
        for (index, title) in [ui("Push to the edge"), ui("Switching Macs"), ui("Controlling")].enumerated() {
            let bar = EdgeBarView(frame: NSRect(x: 60 + index * 140, y: 44, width: 20, height: 112))
            bar.progress = [0, 0.65, 1][index]; bar.connected = index == 2; view.addSubview(bar)
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12); label.textColor = .white; label.alignment = .center
            label.frame = NSRect(x: index * 140, y: 16, width: 140, height: 20); view.addSubview(label)
        }
        return view
    }
}
