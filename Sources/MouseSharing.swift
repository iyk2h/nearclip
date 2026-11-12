import AppKit
import ApplicationServices

struct MousePermissions {
    let accessibility: Bool
    let posting: Bool
    let monitoring: Bool
    var granted: Bool { accessibility && posting && monitoring }
    var missing: [String] {
        var items: [String] = []
        if !accessibility { items.append("손쉬운 사용") }
        else if !posting { items.append("손쉬운 사용의 입력 제어") }
        if !monitoring { items.append("입력 모니터링") }
        return items
    }
    var statusText: String {
        let control = accessibility && posting ? "허용됨" : accessibility ? "입력 제어 확인 필요" : "허용 필요"
        return "손쉬운 사용: \(control) · 입력 모니터링: \(monitoring ? "허용됨" : "허용 필요")\n설정에서 돌아오면 다시 확인해요. 반영됐으면 바로 켤 수 있어요."
    }
    var explanation: String {
        "\(missing.joined(separator: " · ")) 권한을 확인해 주세요. 설정에서 허용한 뒤 다시 켜세요. macOS가 재실행을 요구할 때만 앱을 다시 여세요."
    }
}

// The state machine is also exercised with native=false: no event taps, cursor
// movement, accessibility prompts or generated system input are used in tests.
final class MouseSharing {
    enum Mode: String { case local, requesting, controlling, receiving }
    private(set) var mode: Mode = .local
    private(set) var enabled = false
    private(set) var remoteEnabled = false
    private(set) var layout: ScreenLayout?
    private(set) var peer: String?
    private let local: String
    private let native: Bool
    private var token: UUID?
    private var lastHeard = Date()
    private var lastBeat = Date.distantPast
    private var cooldown = Date.distantPast
    private var edgeSince: Date?
    private var origin = CGPoint.zero
    private var originRect = CGRect.zero
    private var entrySide: ScreenSide = .left
    private var entryRect = CGRect.zero
    private var position = CGPoint.zero
    private var pressed: Set<Int> = []
    private var pendingX: Double = 0
    private var pendingY: Double = 0
    private var pendingFlags: UInt64 = 0
    private var tap: CFMachPort?
    private var runSource: CFRunLoopSource?
    private var timer: Timer?
    private var hiddenOn: CGDirectDisplayID?
    private var lastPermissionCheck = Date.distantPast
    private static let marker: Int64 = 0x4E434C4950
    var displays: () -> [CGRect] = {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [CGDisplayBounds(CGMainDisplayID())] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
    var send: ((String, MousePacket, @escaping (Bool) -> Void) -> Void)?
    var onChange: (() -> Void)?
    var onLayout: ((ScreenLayout) -> Void)?
    var onInput: ((MousePacket, CGPoint) -> Void)?
    var onRelease: ((Set<Int>) -> Void)?
    var side: ScreenSide { layout?.peerSide(for: local) ?? .right }
    var active: Bool { mode != .local }
    init(local: String, native: Bool = true) { self.local = local; self.native = native }
    func setPeer(_ peer: String?, savedLayout: ScreenLayout? = nil) {
        if self.peer != peer && enabled { try? setEnabled(false) }
        endSession(notify: false); self.peer = peer; remoteEnabled = false
        if let peer {
            if let savedLayout, savedLayout.isValid(local: local, peer: peer) { layout = savedLayout }
            else { layout = ScreenLayout(revision: 0, author: local, left: local, right: peer) }
            advertise()
            emit(MousePacket(kind: .layout, layout: layout))
        } else { layout = nil }
        onChange?()
    }
    func setSide(_ side: ScreenSide) {
        guard let peer else { return }
        endSession()
        let revision = (layout?.revision ?? 0) + 1
        guard revision < UInt64.max - 100 else { return }
        let layout = ScreenLayout(revision: revision, author: local, left: side == .right ? local : peer, right: side == .right ? peer : local)
        self.layout = layout; onLayout?(layout)
        emit(MousePacket(kind: .layout, layout: layout)); onChange?()
    }
    static var permissions: MousePermissions {
        MousePermissions(accessibility: AXIsProcessTrusted(), posting: CGPreflightPostEventAccess(), monitoring: CGPreflightListenEventAccess())
    }
    static var permissionsGranted: Bool { permissions.granted }
    static func requestPermissions() {
        let current = permissions
        // Request only the missing permission, from an explicit enable action.
        if !current.accessibility {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        } else if !current.posting {
            _ = CGRequestPostEventAccess()
        } else if !current.monitoring {
            _ = CGRequestListenEventAccess()
        }
    }
    func setEnabled(_ value: Bool) throws {
        if value && native {
            let current = Self.permissions
            guard current.granted else { throw ClipError.invalid(current.explanation) }
            try installTap()
        }
        if !value { endSession(); removeTap() }
        enabled = value; edgeSince = nil; cooldown = Date().addingTimeInterval(0.7)
        if value, native, timer == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        if !value { timer?.invalidate(); timer = nil }
        advertise(); onChange?()
    }
    func stop() { try? setEnabled(false) }
    private func advertise() { emit(MousePacket(kind: .availability, enabled: enabled)) }
    func receive(_ packet: MousePacket, from sender: String, now: Date = Date()) {
        guard sender == peer, (try? packet.validate()) != nil else { return }
        if packet.kind == .layout {
            guard let next = packet.layout, next.isValid(local: local, peer: sender) else { return }
            if layout == nil || next.isNewer(than: layout!) {
                endSession(); layout = next; onLayout?(next); onChange?()
            }
            return
        }
        if packet.kind == .availability {
            remoteEnabled = packet.enabled == true
            if !remoteEnabled { endSession(notify: false) }
            onChange?(); return
        }
        if packet.kind == .enter {
            guard enabled, remoteEnabled, mode == .local, now >= cooldown,
                  let side = packet.side, let fraction = packet.fraction,
                  let (point, rect) = ScreenGeometry.entry(side: side, fraction: fraction, displays: displays()) else {
                emit(MousePacket(kind: .deny, token: packet.token)); return
            }
            token = packet.token; mode = .receiving; position = point; entryRect = rect; entrySide = side
            lastHeard = now; lastBeat = .distantPast
            if native { CGWarpMouseCursorPosition(point) }
            emit(MousePacket(kind: .accepted, token: token)); onChange?(); return
        }
        guard let token, token == packet.token, enabled else { return }
        lastHeard = now
        switch packet.kind {
        case .accepted:
            guard mode == .requesting else { return }
            mode = .controlling; lastBeat = .distantPast
            if native {
                let id = CGMainDisplayID()
                if CGDisplayHideCursor(id) == .success { hiddenOn = id }
                CGWarpMouseCursorPosition(CGPoint(x: originRect.midX, y: originRect.midY))
            }
            onChange?()
        case .input:
            guard mode == .receiving else { return }
            apply(packet)
        case .leave: endSession(notify: false, fraction: packet.fraction)
        case .deny: if mode == .requesting { endSession(notify: false) }
        case .heartbeat: break
        default: break
        }
    }
    // Return true only while local mouse events must be suppressed.
    func localMove(point: CGPoint, dx: Double, dy: Double, flags: UInt64 = 0, buttonsDown: Bool = false, now: Date = Date()) -> Bool {
        guard enabled else { return false }
        if mode == .receiving { endSession(); return false }
        if mode == .controlling {
            pendingX = max(-4096, min(4096, pendingX + dx)); pendingY = max(-4096, min(4096, pendingY + dy)); pendingFlags = flags & 0x1E0000
            return true
        }
        if mode == .requesting {
            let edge = side == .left ? originRect.minX : originRect.maxX
            if abs(point.x - edge) > 8 || buttonsDown { endSession() }
            return false
        }
        guard mode == .local, remoteEnabled, peer != nil, !buttonsDown, flags == 0, now >= cooldown,
              let rect = ScreenGeometry.exit(at: point, deltaX: dx, side: side, displays: displays()) else { edgeSince = nil; return false }
        if edgeSince == nil { edgeSince = now }
        guard now.timeIntervalSince(edgeSince!) >= 0.15 else { return false }
        origin = ScreenGeometry.clamp(point, to: rect, inset: 24); originRect = rect
        token = UUID(); mode = .requesting; edgeSince = nil; lastHeard = now
        emit(MousePacket(kind: .enter, token: token, side: side.opposite, fraction: ScreenGeometry.fraction(point.y, in: rect)))
        onChange?(); return false
    }
    func localButton(action: MousePacket.Action, button: Int, clicks: Int = 1, flags: UInt64 = 0) -> Bool {
        if mode == .receiving || mode == .requesting { endSession(); return false }
        guard enabled, mode == .controlling else { return false }
        flushMove()
        emit(MousePacket(kind: .input, token: token, action: action, button: button, clicks: max(1, min(3, clicks)), flags: flags & 0x1E0000))
        return true
    }
    func emergencyStop() { try? setEnabled(false) }
    func tick(now: Date = Date()) {
        if native, now.timeIntervalSince(lastPermissionCheck) > 1 {
            lastPermissionCheck = now
            if enabled && !Self.permissionsGranted { emergencyStop(); return }
        }
        guard active else { return }
        if now.timeIntervalSince(lastHeard) > (mode == .requesting ? 1 : 2) { endSession(); return }
        flushMove()
        if now.timeIntervalSince(lastBeat) >= 0.5 {
            lastBeat = now; emit(MousePacket(kind: .heartbeat, token: token))
        }
    }
    private func flushMove() {
        guard mode == .controlling, pendingX != 0 || pendingY != 0 else { return }
        let dx = pendingX, dy = pendingY; pendingX = 0; pendingY = 0
        emit(MousePacket(kind: .input, token: token, action: .move, dx: dx, dy: dy, flags: pendingFlags))
    }
    private func apply(_ packet: MousePacket) {
        guard let action = packet.action else { return }
        switch action {
        case .move:
            let next = CGPoint(x: position.x + packet.dx, y: position.y + packet.dy)
            let atReturnEdge = entrySide == .left ? next.x <= entryRect.minX + 1 && packet.dx < 0 : next.x >= entryRect.maxX - 1 && packet.dx > 0
            if atReturnEdge, pressed.isEmpty, position.y >= entryRect.minY, position.y <= entryRect.maxY {
                endSession(fraction: ScreenGeometry.fraction(position.y, in: entryRect)); return
            }
            position = ScreenGeometry.project(next, displays: displays())
        case .down: guard !pressed.contains(packet.button) else { return }; pressed.insert(packet.button)
        case .up: guard pressed.contains(packet.button) else { return }; pressed.remove(packet.button)
        case .scroll: break
        }
        onInput?(packet, position)
        if native { post(packet, at: position) }
    }
    func endSession(notify: Bool = true, fraction: Double? = nil) {
        let old = mode, oldToken = token
        mode = .local; token = nil; pendingX = 0; pendingY = 0; edgeSince = nil
        cooldown = Date().addingTimeInterval(0.7)
        if !pressed.isEmpty {
            onRelease?(pressed)
            if native { for button in pressed { post(MousePacket(kind: .input, token: oldToken, action: .up, button: button), at: position) } }
            pressed = []
        }
        if let id = hiddenOn { CGDisplayShowCursor(id); hiddenOn = nil }
        if native, old == .controlling {
            var point = origin
            if let fraction { point.y = originRect.minY + originRect.height * fraction }
            CGWarpMouseCursorPosition(ScreenGeometry.clamp(point, to: originRect, inset: 24))
        }
        if notify, let oldToken { emit(MousePacket(kind: .leave, token: oldToken, fraction: fraction)) }
        if old != .local { onChange?() }
    }
    private func emit(_ packet: MousePacket) {
        guard let peer, let send else { return }
        let session = token
        send(peer, packet) { [weak self] success in
            guard let self, !success, self.peer == peer, self.token == session else { return }
            self.endSession(notify: false)
        }
    }
    private func installTap() throws {
        guard tap == nil else { return }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<MouseSharing>.fromOpaque(context).takeUnretainedValue().handle(type, event: event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw ClipError.invalid("마우스 이벤트를 열 수 없어요. 권한을 허용한 뒤 NearClip을 다시 실행해 주세요.")
        }
        self.tap = tap
        runSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes); CGEvent.tapEnable(tap: tap, enable: true)
    }
    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runSource, .commonModes) }
        tap = nil; runSource = nil
    }
    private func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { emergencyStop(); return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return Unmanaged.passUnretained(event) }
        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 && event.flags.contains([.maskControl, .maskAlternate]) {
                emergencyStop(); return nil
            }
            // Keyboard input remains local; typing reclaims local mouse control too.
            if active { endSession() }; return Unmanaged.passUnretained(event)
        }
        let flags = event.flags.rawValue & 0x1E0000
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let down = (0...2).contains { CGEventSource.buttonState(.combinedSessionState, button: CGMouseButton(rawValue: UInt32($0))!) }
            let blocked = localMove(point: event.location, dx: Double(event.getIntegerValueField(.mouseEventDeltaX)), dy: Double(event.getIntegerValueField(.mouseEventDeltaY)), flags: flags, buttonsDown: down)
            if blocked {
                CGWarpMouseCursorPosition(CGPoint(x: originRect.midX, y: originRect.midY)); return nil
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            guard (0...2).contains(button) else { if active { endSession() }; return Unmanaged.passUnretained(event) }
            let down = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
            if localButton(action: down ? .down : .up, button: button, clicks: Int(event.getIntegerValueField(.mouseEventClickState)), flags: flags) { return nil }
        case .scrollWheel:
            if mode == .receiving { endSession() }
            if mode == .controlling {
                flushMove()
                let x = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
                let y = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
                emit(MousePacket(kind: .input, token: token, action: .scroll, dx: max(-4096, min(4096, x)), dy: max(-4096, min(4096, y)), flags: flags)); return nil
            }
        default: break
        }
        return Unmanaged.passUnretained(event)
    }
    private func post(_ packet: MousePacket, at point: CGPoint) {
        Self.makeEvent(packet, at: point, pressed: pressed)?.post(tap: .cgSessionEventTap)
    }
    // Creating an event has no system input effect; tests inspect this adapter without posting.
    static func makeEvent(_ packet: MousePacket, at point: CGPoint, pressed: Set<Int>) -> CGEvent? {
        guard packet.kind == .input, packet.action != nil, (try? packet.validate()) != nil else { return nil }
        let event: CGEvent?
        let source = CGEventSource(stateID: .privateState)
        if packet.action == .scroll {
            event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(packet.dy), wheel2: Int32(packet.dx), wheel3: 0)
        } else {
            let type: CGEventType
            if packet.action == .down { type = packet.button == 0 ? .leftMouseDown : (packet.button == 1 ? .rightMouseDown : .otherMouseDown) }
            else if packet.action == .up { type = packet.button == 0 ? .leftMouseUp : (packet.button == 1 ? .rightMouseUp : .otherMouseUp) }
            else { type = pressed.contains(0) ? .leftMouseDragged : (pressed.contains(1) ? .rightMouseDragged : (pressed.contains(2) ? .otherMouseDragged : .mouseMoved)) }
            let button = packet.action == .move ? (pressed.min() ?? 0) : packet.button
            event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: CGMouseButton(rawValue: UInt32(button))!)
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(packet.clicks))
            event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(packet.dx)); event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(packet.dy))
        }
        event?.flags = CGEventFlags(rawValue: packet.flags)
        event?.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        return event
    }
}
