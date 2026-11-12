import AppKit

// Each card represents one paired Mac. Only a completed horizontal drop commits.
final class ScreenArrangementView: NSView {
    private(set) var peerSide: ScreenSide = .right
    private var peerID: String?
    private var localName = "이 Mac"
    private var peerName = "상대 Mac"
    private var editable = false
    private var draggingLocal: Bool?
    private var dragStart = CGPoint.zero
    private var dragOffset: CGFloat = 0
    private var dragCenter: CGFloat = 0
    private var proposedSide: ScreenSide = .right
    private var moved = false
    var onCommit: ((ScreenSide) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { editable }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 164) }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("Mac 화면 배치")
        setAccessibilityHelp("두 Mac의 좌우 순서입니다. 순서 바꾸기 버튼으로도 변경할 수 있습니다.")
        toolTip = "화면을 드래그해 순서를 바꾸세요. 선택 후 방향키로 상대 Mac을 왼쪽이나 오른쪽에 놓을 수도 있어요."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(peerID: String?, localName: String, peerName: String, side: ScreenSide, editable: Bool) {
        if self.peerID != peerID || peerSide != side || !editable { cancelDrag() }
        self.peerID = peerID; self.localName = localName; self.peerName = peerName
        peerSide = side; self.editable = editable
        setAccessibilityValue(peerID == nil ? "상대 Mac 연결 대기" : (side == .right ? "이 Mac 왼쪽, \(peerName) 오른쪽" : "\(peerName) 왼쪽, 이 Mac 오른쪽"))
        window?.invalidateCursorRects(for: self); needsDisplay = true
    }
    private var cardSize: NSSize { NSSize(width: min(188, max(100, (bounds.width - 64) / 2)), height: 112) }
    private func slot(_ side: ScreenSide) -> NSRect {
        let size = cardSize
        return NSRect(x: bounds.midX + (side == .left ? -size.width - 12 : 12), y: 22, width: size.width, height: size.height)
    }
    private func frame(local: Bool, side: ScreenSide) -> NSRect { slot(local ? side.opposite : side) }
    private func dragFrame() -> NSRect { NSRect(x: dragCenter - cardSize.width / 2, y: 18, width: cardSize.width, height: cardSize.height) }
    override func resetCursorRects() {
        guard editable else { return }
        addCursorRect(slot(.left), cursor: .openHand); addCursorRect(slot(.right), cursor: .openHand)
    }
    override func mouseDown(with event: NSEvent) {
        guard editable, peerID != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let local = frame(local: true, side: peerSide).contains(point)
        guard local || frame(local: false, side: peerSide).contains(point) else { return }
        window?.makeFirstResponder(self)
        draggingLocal = local; dragStart = point; moved = false; proposedSide = peerSide
        dragCenter = frame(local: local, side: peerSide).midX; dragOffset = point.x - dragCenter
        NSCursor.closedHand.set(); needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let local = draggingLocal, editable else { return }
        let point = convert(event.locationInWindow, from: nil)
        if abs(point.x - dragStart.x) >= 4 { moved = true }
        guard moved else { return }
        dragCenter = min(bounds.maxX - cardSize.width / 2 - 8, max(cardSize.width / 2 + 8, point.x - dragOffset))
        // A dead band prevents rapid slot changes near the midpoint.
        if dragCenter < bounds.midX - 8 { proposedSide = local ? .right : .left }
        else if dragCenter > bounds.midX + 8 { proposedSide = local ? .left : .right }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard draggingLocal != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let commit = editable && moved && bounds.contains(point) && proposedSide != peerSide
        let result = proposedSide; cancelDrag()
        if commit { onCommit?(result) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelDrag(); return }
        if editable, event.keyCode == 123 || event.keyCode == 124 {
            cancelDrag()
            let side: ScreenSide = event.keyCode == 123 ? .left : .right
            if side != peerSide { onCommit?(side) }
            return
        }
        super.keyDown(with: event)
    }
    override func resignFirstResponder() -> Bool { cancelDrag(); return true }
    private func cancelDrag() {
        draggingLocal = nil; moved = false; proposedSide = peerSide
        window?.invalidateCursorRects(for: self); needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.controlBackgroundColor.setFill(); background.fill()
        NSColor.separatorColor.withAlphaComponent(0.4).setStroke(); background.lineWidth = 1; background.stroke()
        let side = draggingLocal == nil ? peerSide : proposedSide
        if let local = draggingLocal {
            let target = NSBezierPath(roundedRect: frame(local: local, side: side).insetBy(dx: -4, dy: -4), xRadius: 10, yRadius: 10)
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill(); target.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.45).setStroke(); target.setLineDash([4, 4], count: 2, phase: 0); target.stroke()
            drawCard(local: !local, rect: frame(local: !local, side: side), lifted: false)
            drawCard(local: local, rect: dragFrame(), lifted: true)
        } else {
            drawCard(local: true, rect: frame(local: true, side: side), lifted: false)
            drawCard(local: false, rect: frame(local: false, side: side), lifted: false)
            if peerID != nil { drawText("↔", rect: NSRect(x: bounds.midX - 12, y: 61, width: 24, height: 24), size: 16, color: .secondaryLabelColor) }
        }
        let caption = peerID == nil ? "연결하면 화면을 배치할 수 있어요" : draggingLocal == nil ? "왼쪽 화면  ·  오른쪽 화면" : "놓으면 양쪽 Mac에 적용돼요"
        drawText(caption, rect: NSRect(x: 12, y: 142, width: bounds.width - 24, height: 16), size: 10, color: .secondaryLabelColor)
        if window?.firstResponder === self, editable {
            NSColor.keyboardFocusIndicatorColor.setStroke(); background.lineWidth = 2; background.stroke()
        }
    }
    private func drawCard(local: Bool, rect: NSRect, lifted: Bool) {
        let screen = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - 22)
        let connected = local || peerID != nil
        let body = NSBezierPath(roundedRect: screen, xRadius: 7, yRadius: 7)
        NSGraphicsContext.saveGraphicsState()
        if lifted { let shadow = NSShadow(); shadow.shadowBlurRadius = 8; shadow.shadowOffset = NSSize(width: 0, height: -3); shadow.shadowColor = NSColor.black.withAlphaComponent(0.22); shadow.set() }
        (connected ? NSColor.controlAccentColor.withAlphaComponent(local ? 0.16 : 0.09) : NSColor.quaternaryLabelColor.withAlphaComponent(0.12)).setFill(); body.fill()
        NSGraphicsContext.restoreGraphicsState()
        (connected ? NSColor.controlAccentColor.withAlphaComponent(lifted ? 0.9 : 0.45) : NSColor.separatorColor).setStroke()
        body.lineWidth = lifted ? 2 : 1; body.stroke()
        if local {
            NSColor.labelColor.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: NSRect(x: screen.minX + 8, y: screen.minY + 7, width: screen.width - 16, height: 4), xRadius: 2, yRadius: 2).fill()
        }
        drawText(local ? "이 Mac" : peerName, rect: NSRect(x: screen.minX + 10, y: screen.minY + 31, width: screen.width - 20, height: 20), size: 13, weight: .semibold, color: connected ? .labelColor : .secondaryLabelColor)
        drawText(local ? localName : (peerID == nil ? "연결 대기" : "연결된 Mac"), rect: NSRect(x: screen.minX + 10, y: screen.minY + 54, width: screen.width - 20, height: 16), size: 10, color: .secondaryLabelColor)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.midX - 2, y: screen.maxY + 1, width: 4, height: 8), xRadius: 1, yRadius: 1).fill()
        NSBezierPath(roundedRect: NSRect(x: rect.midX - 19, y: screen.maxY + 8, width: 38, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
    }
    private func drawText(_ text: String, rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) {
        let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style])
    }
}
