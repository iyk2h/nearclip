import AppKit

// Finder owns the drag pasteboard. Accept exactly one local file URL and copy only.
final class FinderFileDrop: NSView {
    var enter: ((URL) -> Bool)?
    var drop: ((URL) -> Bool)?
    var exit: (() -> Void)?
    private var accepted: (sequence: Int, url: URL)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { nil }

    static func fileURL(from pasteboard: NSPasteboard) -> URL? {
        guard let items = pasteboard.pasteboardItems, items.count == 1,
              let raw = items[0].string(forType: .fileURL), let url = URL(string: raw),
              url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.path.hasPrefix("/"), FilePacket.safeName(url.lastPathComponent) else { return nil }
        return url
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        accepted = nil
        guard sender.draggingSourceOperationMask.contains(.copy),
              let url = Self.fileURL(from: sender.draggingPasteboard), enter?(url) == true else { return [] }
        accepted = (sender.draggingSequenceNumber, url)
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        accepted?.sequence == sender.draggingSequenceNumber && sender.draggingSourceOperationMask.contains(.copy) ? .copy : []
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { draggingUpdated(sender) == .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let accepted, draggingUpdated(sender) == .copy,
              Self.fileURL(from: sender.draggingPasteboard) == accepted.url else { return false }
        self.accepted = nil
        return drop?(accepted.url) == true
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { accepted = nil; exit?() }
    override func draggingEnded(_ sender: NSDraggingInfo) { accepted = nil; exit?() }
}

final class FileEdgePanel: NSPanel {
    let target = FinderFileDrop(frame: NSRect(x: 0, y: 0, width: 108, height: 64))
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: target.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        hidesOnDeactivate = false; level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        target.wantsLayer = true
        target.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        target.layer?.cornerRadius = 10
        let label = NSTextField(labelWithString: ui("Copy to Mac"))
        label.alignment = .center; label.frame = target.bounds.insetBy(dx: 2, dy: 22)
        target.addSubview(label)
        contentView = target
    }

    private var dismissTimer: Timer?
    func dismissWhenDragEnds() {
        guard dismissTimer == nil else { return }
        var releasedOnPreviousTick = false
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let released = NSEvent.pressedMouseButtons & 1 == 0
            if !self.isVisible || (released && releasedOnPreviousTick) {
                if self.isVisible { self.target.exit?(); self.orderOut(nil) }
                timer.invalidate(); self.dismissTimer = nil
            }
            releasedOnPreviousTick = released
        }
        dismissTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func present(at point: CGPoint, side: ScreenSide) {
        guard !isVisible, let screen = NSScreen.screens.first(where: { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayBounds(id).insetBy(dx: -1, dy: -1).contains(point)
        }), let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }
        let bounds = CGDisplayBounds(id)
        let y = screen.frame.maxY - (point.y - bounds.minY) * screen.frame.height / bounds.height
        let x = side == .left ? screen.frame.minX : screen.frame.maxX - frame.width
        setFrameOrigin(NSPoint(x: x, y: max(screen.frame.minY, min(screen.frame.maxY - frame.height, y - frame.height / 2))))
        orderFrontRegardless()
    }
}

// Finder exposes ordinary folder icons through AXURL and folder windows through AXDocument.
// A virtual Finder location (for example Recents) falls back to the normal save panel.
func finderFolder(at point: CGPoint) -> URL? {
    var element: AXUIElement?
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.15)
    guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
          let element else { return nil }
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success,
          NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.finder" else { return nil }
    func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
    }
    func directory(_ value: CFTypeRef?) -> URL? {
        let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        guard let url, url.isFileURL, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        return url
    }
    AXUIElementSetMessagingTimeout(element, 0.15)
    var current = element
    var overItem = false
    for _ in 0..<8 {
        let role = attribute(current, kAXRoleAttribute) as? String
        if let value = attribute(current, kAXURLAttribute) { return directory(value) }
        if [kAXRowRole, kAXCellRole, kAXImageRole, kAXButtonRole, kAXStaticTextRole, kAXTextFieldRole].contains(role ?? "") { overItem = true }
        if let document = attribute(current, kAXDocumentAttribute) { return overItem ? nil : directory(document) }
        if role == kAXApplicationRole { break }
        guard let parent = attribute(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
        current = parent as! AXUIElement
    }
    guard !overItem else { return nil }
    if let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
       !windows.contains(where: { info in
           guard info[kCGWindowLayer as String] as? Int == 0,
                 let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                 let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
           return rect.contains(point)
       }) {
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    }
    return nil
}

final class DraggedFileBadge: NSPanel {
    private let label = NSTextField(labelWithString: "")
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 150, height: 24), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        ignoresMouseEvents = true; hidesOnDeactivate = false; level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        label.lineBreakMode = .byTruncatingMiddle; label.maximumNumberOfLines = 1
        contentView?.addSubview(label)
    }
    func show(_ name: String, at point: CGPoint) {
        guard let primary = NSScreen.screens.first else { return }
        if !isVisible || label.stringValue != name {
            label.stringValue = name
            let width = min(240, max(64, label.intrinsicContentSize.width + 16))
            setContentSize(NSSize(width: width, height: 24))
            label.frame = NSRect(x: 8, y: 3, width: width - 16, height: 18)
        }
        setFrameOrigin(NSPoint(x: point.x + 12, y: primary.frame.maxY - point.y - 32))
        if !isVisible { orderFrontRegardless() }
    }
}
