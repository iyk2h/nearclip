import AppKit
import OSLog
import ImageIO

// A source app may advertise image bytes without a file URL. Keep that copy
// alive until the transfer worker opens it, including after Finder ends the drag.
final class DragSourceFile {
    let url: URL
    private let temporary: Bool
    init?(from board: NSPasteboard) {
        guard board.pasteboardItems?.count == 1 else { return nil }
        if let file = FinderFileDrop.fileURL(from: board) { url = file; temporary = false; return }
        guard Self.hasImage(on: board), let type = board.availableType(from: [.png, .tiff]),
              let data = board.data(forType: type), !data.isEmpty, data.count <= ClipPayload.maxBytes else { return nil }
        let name = type == .png ? "Image.png" : "Image.tiff"
        guard let path = try? AppFileDrop.stage(name, in: FileManager.default.temporaryDirectory) else { return nil }
        do { try data.write(to: path, options: .withoutOverwriting) }
        catch { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()); return nil }
        url = path; temporary = true
    }
    static func hasImage(on board: NSPasteboard) -> Bool {
        guard let types = board.types, !types.contains(.fileURL),
              !types.contains(where: { ClipboardCodec.ignored.contains($0.rawValue) }) else { return false }
        return types.contains(.png) || types.contains(.tiff)
    }
    deinit { if temporary { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
}

final class FinderFileDrop: NSView {
    var enter: ((DragSourceFile) -> Bool)?
    var drop: ((URL) -> Bool)?
    var exit: ((_ ended: Bool) -> Void)?
    private var candidate: (sequence: Int, revision: Int, source: DragSourceFile?)?
    private var accepted = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff])
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
        candidate = nil; accepted = false
        return draggingUpdated(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSourceOperationMask.contains(.copy) else { return [] }
        let board = sender.draggingPasteboard
        if candidate?.sequence != sender.draggingSequenceNumber || candidate?.revision != board.changeCount {
            guard !accepted else { return [] }
            let source = DragSourceFile(from: board)
            candidate = (sender.draggingSequenceNumber, board.changeCount, source)
        }
        if !accepted, let source = candidate?.source { accepted = enter?(source) == true }
        return accepted ? .copy : []
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        accepted && candidate?.sequence == sender.draggingSequenceNumber &&
        candidate?.revision == sender.draggingPasteboard.changeCount && sender.draggingSourceOperationMask.contains(.copy)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard prepareForDragOperation(sender), let source = candidate?.source else { return false }
        if sender.draggingPasteboard.types?.contains(.fileURL) == true,
           Self.fileURL(from: sender.draggingPasteboard) != source.url { return false }
        candidate = nil; accepted = false
        return drop?(source.url) == true
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { candidate = nil; accepted = false; exit?(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { candidate = nil; accepted = false; exit?(true) }
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
                if self.isVisible { self.target.exit?(true); self.orderOut(nil) }
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
    private let thumbnail = NSImageView()
    var preview: NSImage? { thumbnail.image }
    func setThumbnail(_ image: NSImage?) {
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        thumbnail.image = image
        layoutBadge()
        if isVisible { setFrameTopLeftPoint(topLeft) }
    }
    private func layoutBadge() {
        label.isHidden = preview != nil
        if let image = preview {
            backgroundColor = .clear
            let size = Self.previewSize(image)
            setContentSize(size)
            thumbnail.frame = NSRect(origin: .zero, size: size)
        } else {
            backgroundColor = .windowBackgroundColor
            let width = min(240, max(64, label.intrinsicContentSize.width + 16))
            setContentSize(NSSize(width: width, height: 24))
            label.frame = NSRect(x: 8, y: 3, width: width - 16, height: 18)
        }
    }
    static func previewSize(_ image: NSImage) -> NSSize {
        let scale = 52 / max(1, max(image.size.width, image.size.height))
        return NSSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 150, height: 24), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        ignoresMouseEvents = true; hidesOnDeactivate = false; level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false; hasShadow = false; thumbnail.imageScaling = .scaleProportionallyUpOrDown
        label.lineBreakMode = .byTruncatingMiddle; label.maximumNumberOfLines = 1
        contentView?.addSubview(thumbnail); contentView?.addSubview(label)
    }
    func show(_ name: String, at point: CGPoint) {
        guard let primary = NSScreen.screens.first else { return }
        if !isVisible || label.stringValue != name {
            label.stringValue = name
            layoutBadge()
        }
        setFrameOrigin(NSPoint(x: point.x + 12, y: primary.frame.maxY - point.y - frame.height - 8))
        if !isVisible { orderFrontRegardless() }
    }
}

// AppKit advertises the verified local URL on the drag pasteboard. Some apps read it
// later (for example, when a draft is sent), so keep it in the user's caches.
private final class FileDragSourceView: NSView {
    var begin: ((NSEvent) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) == MouseSharing.marker else { return }
        let start = begin; begin = nil; start?(event)
    }
}

final class AppFileDrop: NSObject, NSDraggingSource {
    let id: UUID
    let name: String
    let date = Date()
    private var point: CGPoint
    private let logger = Logger(subsystem: "dev.nearclip.mac", category: "input")
    private let target: AXUIElement?
    private let windowNumber: Int
    private var panel: NSPanel?
    private var session: NSDraggingSession?
    private var heldPoint: CGPoint?
    private var postedDown = false
    var didBegin: (() -> Void)?
    var isDragging: Bool { session != nil }
    private var authorized: (() -> Bool)?
    private var completion: ((Bool) -> Void)?
    private(set) var destination: URL?

    private static func hit(_ point: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var item: AXUIElement?
        return AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &item) == .success ? item : nil
    }
    private func appKitPoint(_ location: CGPoint) -> CGPoint {
        CGPoint(x: location.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - location.y)
    }
    private func originalWindow(at location: CGPoint) -> Bool {
        NSWindow.windowNumber(at: appKitPoint(location), belowWindowWithWindowNumber: 0) == windowNumber
    }
    init?(id: UUID, name: String, point: CGPoint, expectedPID: pid_t? = nil) {
        guard FilePacket.safeName(name), let primary = NSScreen.screens.first else { return nil }
        let number = NSWindow.windowNumber(at: CGPoint(x: point.x, y: primary.frame.maxY - point.y), belowWindowWithWindowNumber: 0)
        guard number > 0, let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]])?.first,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(), expectedPID == nil || expectedPID == pid,
              let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
              app.bundleIdentifier != "com.apple.finder" else { return nil }
        let target = Self.hit(point)
        self.id = id; self.name = name; self.point = point; self.target = target; windowNumber = number
    }

    static func stage(_ name: String, in base: URL) throws -> URL {
        guard FilePacket.safeName(name) else { throw ClipError.invalid(ui("Choose a valid filename.")) }
        let folder = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder.appendingPathComponent(name)
    }
    static func cacheURL(for name: String) throws -> URL {
        let base = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try stage(name, in: base.appendingPathComponent("dev.nearclip.mac/Drops", isDirectory: true))
    }
    func stage() throws -> URL {
        let url = try Self.cacheURL(for: name)
        destination = url
        return url
    }
    deinit {
        // Remove empty directories left by interrupted transfers. Retain completed files.
        if let destination { _ = rmdir(destination.deletingLastPathComponent().path) }
    }
    private func deliveryPoint() -> CGPoint? {
        guard let cursor = CGEvent(source: nil)?.location, originalWindow(at: point), originalWindow(at: cursor) else { return nil }
        let distance = hypot(cursor.x - point.x, cursor.y - point.y)
        guard distance <= 32 else { return nil }
        guard let target else { return distance < 5 ? point : nil }
        guard let current = Self.hit(cursor), CFEqual(target, current) else { return nil }
        return cursor
    }
    func deliver(file: URL? = nil, preview: NSImage? = nil, authorized: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        self.authorized = authorized
        guard let destination = file ?? destination, destination.lastPathComponent == name, authorized(), CGPreflightPostEventAccess(), NSEvent.pressedMouseButtons == 0 else {
            logger.notice("file_drop_unavailable"); completion(false); return
        }
        guard let cursor = deliveryPoint() else {
            logger.notice("file_drop_target_changed"); completion(false); return
        }
        point = cursor
        heldPoint = preview == nil ? nil : cursor
        let origin = appKitPoint(cursor)
        let frame = NSRect(x: origin.x - 5, y: origin.y - 5, width: 10, height: 10)
        let panel = NSPanel(contentRect: frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.05); panel.hasShadow = false
        panel.level = .popUpMenu; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = FileDragSourceView(frame: NSRect(origin: .zero, size: frame.size))
        self.panel = panel; self.completion = completion
        view.begin = { [weak self, weak view] event in
            guard let self, let view else { return }
            let item = NSDraggingItem(pasteboardWriter: destination as NSURL)
            if let preview {
                let size = DraggedFileBadge.previewSize(preview)
                item.setDraggingFrame(NSRect(x: 13, y: -size.height, width: size.width, height: size.height), contents: preview)
            } else {
                item.setDraggingFrame(view.bounds, contents: NSImage(size: view.bounds.size))
            }
            self.session = view.beginDraggingSession(with: [item], event: event, source: self)
            self.session?.animatesToStartingPositionsOnCancelOrFail = false
        }
        panel.contentView = view; panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            guard view.begin != nil else { return }
            guard authorized(), NSEvent.pressedMouseButtons == 0, let cursor = CGEvent(source: nil)?.location, hypot(cursor.x - point.x, cursor.y - point.y) < 5,
                  NSWindow.windowNumber(at: appKitPoint(point), belowWindowWithWindowNumber: 0) == panel.windowNumber,
                  NSWindow.windowNumber(at: appKitPoint(point), belowWindowWithWindowNumber: panel.windowNumber) == windowNumber else {
                logger.notice("file_drop_source_changed")
                self.abort(); return
            }
            postedDown = true
            MouseSharing.makeEvent(MousePacket(kind: .input, token: id, action: .down, button: 0), at: point, pressed: [])?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            guard view.begin != nil else { return }
            self.abort()
        }
    }
    func moveHeld(to location: CGPoint) {
        heldPoint = location
        if isDragging {
            MouseSharing.makeEvent(MousePacket(kind: .input, token: id, action: .move), at: location, pressed: [0])?.post(tap: .cghidEventTap)
        }
    }
    func releaseHeld(at location: CGPoint) {
        guard isDragging, heldPoint != nil else { return }
        moveHeld(to: location)
        postUp(at: location)
    }
    private func postUp(at location: CGPoint) {
        guard postedDown else { return }
        postedDown = false
        MouseSharing.makeEvent(MousePacket(kind: .input, token: id, action: .up, button: 0), at: location, pressed: [])?.post(tap: .cghidEventTap)
    }
    func abort() {
        (panel?.contentView as? FileDragSourceView)?.begin = nil
        if isDragging && postedDown {
            authorized = nil
            for action in [KeyboardPacket.Action.down, .up] {
                MouseSharing.makeKeyboardEvent(KeyboardPacket(token: id, action: action, keyCode: 53))?.post(tap: .cghidEventTap)
            }
        }
        postUp(at: CGEvent(source: nil)?.location ?? point)
        panel?.orderOut(nil)
        let finished = completion; completion = nil
        finished?(false)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        authorized?() == true ? .copy : []
    }
    private func stillOverTarget() -> Bool {
        guard authorized?() == true, let cursor = CGEvent(source: nil)?.location else { return false }
        return hypot(cursor.x - point.x, cursor.y - point.y) <= 8 && originalWindow(at: cursor) && originalWindow(at: point)
    }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        self.session = session
        panel?.orderOut(nil)
        if let heldPoint {
            didBegin?()
            moveHeld(to: heldPoint)
        } else {
            MouseSharing.makeEvent(MousePacket(kind: .input, token: id, action: .move), at: point, pressed: [0])?.post(tap: .cghidEventTap)
        }
        // Web drop zones negotiate acceptance on dragover, after their first dragenter.
        for (delay, offset) in [(0.035, 2.0), (0.085, 0.0)] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
                let hover = CGPoint(x: point.x + offset, y: point.y)
                guard self.session === session, postedDown, heldPoint == nil || heldPoint == point, stillOverTarget(), originalWindow(at: hover) else { return }
                MouseSharing.makeEvent(MousePacket(kind: .input, token: id, action: .move), at: hover, pressed: [0])?.post(tap: .cghidEventTap)
            }
        }
        guard heldPoint == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [self] in
            guard self.session === session else { return }
            // Apps may replace the hovered element with a drop zone on draggingEntered.
            if stillOverTarget() {
                MouseSharing.makeEvent(MousePacket(kind: .input, token: id, action: .up, button: 0), at: point, pressed: [])?.post(tap: .cghidEventTap)
            } else {
                logger.notice("file_drop_target_changed_during_drag")
                for action in [KeyboardPacket.Action.down, .up] {
                    MouseSharing.makeKeyboardEvent(KeyboardPacket(token: id, action: action, keyCode: 53))?.post(tap: .cghidEventTap)
                }
                MouseSharing.makeEvent(MousePacket(kind: .input, token: id, action: .up, button: 0), at: point, pressed: [])?.post(tap: .cghidEventTap)
            }
        }
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        postedDown = false; self.session = nil; panel?.orderOut(nil); panel = nil
        let finished = completion; completion = nil; authorized = nil
        if !operation.contains(.copy) { logger.notice("file_drop_not_accepted") }
        finished?(operation.contains(.copy))
    }
}

// The private copy is disposable until the user releases the drag over an app.
final class PreparedDragImage {
    let id: UUID
    let url: URL
    var nextHoverCheck: TimeInterval = 0
    var verified = false
    var released = false
    private var retained = false

    init(offer: FilePacket) throws {
        guard offer.kind == .offer, let name = offer.name, FilePacket.canPrepareImage(name: name, size: offer.size) else {
            throw ClipError.invalid(ui("Invalid file message."))
        }
        id = offer.id; url = try AppFileDrop.cacheURL(for: name)
    }
    func take() -> URL? {
        guard released, verified, !retained else { return nil }
        retained = true; return url
    }
    deinit {
        if !retained { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }
    static func encodePreview(_ image: CGImage) -> Data? {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              png.count <= FilePacket.maxPreviewBytes else { return nil }
        return png
    }
    static func thumbnail(_ data: Data, isPreview: Bool = false) -> CGImage? {
        if isPreview, data.count > FilePacket.maxPreviewBytes || !ClipboardCodec.completePNG(data) { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let w = props[kCGImagePropertyPixelWidth as String] as? Int,
              let h = props[kCGImagePropertyPixelHeight as String] as? Int,
              (1...16000).contains(w), (1...16000).contains(h), w * h <= 40_000_000,
              !isPreview || (w <= 64 && h <= 64 && CGImageSourceGetCount(source) == 1) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary)
    }
}
