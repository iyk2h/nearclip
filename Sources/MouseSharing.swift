import AppKit
import ApplicationServices
import Carbon
import OSLog

struct MousePermissions {
    let accessibility: Bool
    let posting: Bool
    let monitoring: Bool
    var granted: Bool { accessibility && posting && monitoring }
    var missing: [String] {
        var items: [String] = []
        if !accessibility { items.append(ui("Accessibility")) }
        else if !posting { items.append(ui("Accessibility input control")) }
        if !monitoring { items.append(ui("Input Monitoring")) }
        return items
    }
    var statusText: String {
        let control = accessibility && posting ? ui("Allowed") : accessibility ? ui("Check input control") : ui("Required")
        return ui("Accessibility: %1$@ · Input Monitoring: %2$@\nNearClip checks again when you return from Settings.", "\(control)", "\(monitoring ? ui("Allowed") : ui("Required"))")
    }
    var explanation: String {
        ui("Check %1$@ in System Settings, then turn on sharing again. Restart NearClip only if macOS asks.", "\(missing.joined(separator: " · "))")
    }
}

// The state machine is also exercised with native=false: no event taps, cursor
// movement, accessibility prompts or generated system input are used in tests.
final class MouseSharing {
    enum Mode: String { case local, requesting, controlling, receiving }
    enum Suspension: Hashable { case sleep, displaySleep, inactiveSession, screenLock, fileApproval }
    private var suspensions: Set<Suspension> = []
    private var requestedPeer: String?
    var sharingRequested: Bool { requestedPeer != nil || enabled }
    private(set) var mode: Mode = .local
    private(set) var enabled = false
    private(set) var remoteEnabled = false
    private(set) var secureInputBlocked = false
    private(set) var remoteSecureInputBlocked = false
    var inputPauseMessage: String? {
        if secureInputBlocked { return ui("Secure Input on this Mac paused input sharing. Finish entering your password or leave the protected app, then move to the edge again.") }
        if remoteSecureInputBlocked { return ui("Secure Input on the other Mac paused input sharing. Finish entering your password there, then move to the edge again.") }
        return nil
    }
    private(set) var keyboardSupported = false
    private(set) var gesturesSupported = false
    private var sentGesture: DockSwipePacket?
    private var receivedGesture: DockSwipePacket?
    private var lastGestureHeard: Date?
    private var lastGestureObservation: TimeInterval = -10
    var sendGesture: ((String, DockSwipePacket, @escaping (Bool) -> Void) -> Void)?
    var onGesture: ((DockSwipePacket) -> Void)?
    private(set) var remoteKeyboardEnabled = false
    var keyboardActive: Bool { enabled && keyboardSupported && remoteKeyboardEnabled }
    private(set) var lastEndReason: MouseEndReason?
    private(set) var endedByPeer = false
    var lastEndMessage: String? {
        guard let reason = lastEndReason else { return nil }
        return ui("Last return: %1$@ · %2$@", "\(endedByPeer ? ui("other Mac") : ui("this Mac"))", "\(reason.explanation)")
    }
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
    private(set) var draggedFileName: String?
    private(set) var fileDropReleased = false
    private var fileDragAnchor: CGPoint?
    private var dropDeadline: Date?
    private var supportsFileDrag = false
    private var supportsReturnFile = false
    private(set) var returningFile = false
    private var controllerButtons: Set<Int> = []
    private var releasedReturn: UUID?
    var canPickUpRemoteDrag: Bool {
        supportsReturnFile && mode == .receiving && pressed == [0] && draggedFileName == nil &&
            pressedKeys.isEmpty && receivedKeyFlags & 0x1E0000 == 0 && !remoteSecureInputBlocked && !secureInputBlocked
    }
    var onFileEdge: ((CGPoint, ScreenSide) -> Void)?
    var onFileDragAccepted: ((UUID) -> Void)?
    var onFileDragMove: ((CGPoint) -> Bool)?
    var onFileDropPosition: ((UUID, CGPoint) -> Bool)?
    var onFileDropReady: ((UUID, Bool) -> Void)?
    private var entrySide: ScreenSide = .left
    private var entryRect = CGRect.zero
    private var position = CGPoint.zero
    private var returnArmed = false
    private var returnEdgeSince: Date?
    private var lastReturnPush: Date?
    private var pressed: Set<Int> = []
    private var pressedKeys: Set<Int> = []
    private var receivedKeyFlags: UInt64 = 0
    private var localHeldKeys: Set<Int> = []
    private lazy var eventSource = CGEventSource(stateID: .privateState)
    private var pendingX: Double = 0
    private var pendingY: Double = 0
    private var pendingFlags: UInt64 = 0
    private var movesInFlight = 0
    private var lastMoveObserved = Date.distantPast
    private static let moveInterval = 1.0 / 120
    private var tap: CFMachPort?
    private var runSource: CFRunLoopSource?
    private var timer: Timer?
    private var inputActivity: NSObjectProtocol?
    private let logger = Logger(subsystem: "dev.nearclip.mac", category: "input")
    private var controlStarted: TimeInterval?
    private var sentMoves = 0
    private var receivedMoves = 0
    private var motionCadence = MotionCadence()
    private var lastCadenceLog = -Double.infinity
    var motionTimingLabel: String? { motionCadence.label }
    private var lastTick: TimeInterval?
    private var maxTimerDelayMS = 0.0
    var maintenanceInterval: TimeInterval? {
        guard enabled else { return nil }
        return mode == .controlling ? Self.moveInterval : mode == .local ? 1 : 0.1
    }
    private var hiddenOn: CGDirectDisplayID?
    private var lastPermissionCheck = Date.distantPast
    static let marker: Int64 = 0x4E434C4950
    var displays: () -> [CGRect] = {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [CGDisplayBounds(CGMainDisplayID())] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
    var send: ((String, MousePacket, @escaping (Bool) -> Void) -> Void)?
    var sendKeyboard: ((String, KeyboardPacket, @escaping (Bool) -> Void) -> Void)?
    var onChange: (() -> Void)?
    var onConsentChange: ((String?) -> Void)?
    var onEdgeProgress: ((CGPoint?, ScreenSide, Double) -> Void)?
    var onLayout: ((ScreenLayout) -> Void)?
    var onInput: ((MousePacket, CGPoint) -> Void)?
    var onRelease: ((Set<Int>) -> Void)?
    var onKeyboardInput: ((KeyboardPacket) -> Void)?
    var onKeysReleased: ((Set<Int>) -> Void)?
    var secureInputEnabled: () -> Bool = { false }
    var indicatorPoint: CGPoint { mode == .receiving || returningFile ? position : origin }
    var side: ScreenSide { layout?.peerSide(for: local) ?? .right }
    var active: Bool { mode != .local }
    init(local: String, native: Bool = true) {
        self.local = local; self.native = native
        if native { secureInputEnabled = { IsSecureEventInputEnabled() } }
    }
    func setPeer(_ peer: String?, savedLayout: ScreenLayout? = nil, supportsKeyboard: Bool = false, supportsGestures: Bool = false, supportsFileDrag: Bool = false, supportsReturnFile: Bool = false) {
        if self.peer != peer && enabled { try? applyEnabled(false) }
        if let peer, requestedPeer != nil, requestedPeer != peer { requestedPeer = nil; onConsentChange?(nil) }
        endSession(notify: false, reason: .connectionChanged); self.peer = peer; remoteEnabled = false; remoteSecureInputBlocked = false
        motionCadence = MotionCadence()
        self.supportsFileDrag = supportsFileDrag
        self.supportsReturnFile = supportsFileDrag && supportsReturnFile
        keyboardSupported = supportsKeyboard; remoteKeyboardEnabled = false
        gesturesSupported = supportsGestures && DockSwipeAdapter.available
        if native { logger.notice("gesture_capability peer_present=\(peer != nil, privacy: .public) negotiated=\(supportsGestures, privacy: .public) enabled=\(self.gesturesSupported, privacy: .public)") }
        if let peer {
            if let savedLayout, savedLayout.isValid(local: local, peer: peer) { layout = savedLayout }
            else { layout = ScreenLayout(revision: 0, author: local, left: local, right: peer) }
            advertise()
            emit(MousePacket(kind: .layout, layout: layout))
        } else { layout = nil }
        restoreIfReady()
        onChange?()
    }
    func setSide(_ side: ScreenSide) {
        guard let peer else { return }
        endSession(reason: .layoutChanged)
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
        if value, !suspensions.isEmpty { throw ClipError.invalid(ui("Input sharing resumes after wake or unlock.")) }
        if !value { requestedPeer = nil }
        try applyEnabled(value)
        if value { requestedPeer = peer }
        onConsentChange?(requestedPeer)
        onChange?()
    }
    // Restore only a stored local choice. This does not restore remote consent,
    // session tokens, or held input, and cannot bypass native permissions.
    func restoreConsent(for peer: String) {
        guard !enabled, self.peer == nil else { return }
        requestedPeer = peer
    }
    // Explicit user choice while the authenticated peer's input socket recovers.
    // Do not install an event tap or reuse the previous remote consent/session.
    func requestSharingWhenConnected(to peer: String) {
        guard !enabled, self.peer == nil else { return }
        requestedPeer = peer
        onConsentChange?(peer)
        onChange?()
    }
    func retryRequestedSharing() { restoreIfReady() }
    // Suspend capture, not the user's choice. Consent is scoped to this peer
    // and its pairing; a new device or an explicit stop never inherits it.
    func suspend(_ reason: Suspension) {
        if native { logger.notice("input_suspend reason=\(String(describing: reason), privacy: .public)") }
        suspensions.insert(reason); try? applyEnabled(false)
    }
    func resume(_ reason: Suspension) {
        suspensions.remove(reason); restoreIfReady(); onChange?()
        if native { logger.notice("input_resume reason=\(String(describing: reason), privacy: .public) ready=\(self.enabled, privacy: .public)") }
    }
    private func restoreIfReady() {
        guard !enabled, suspensions.isEmpty, let peer, peer == requestedPeer else { return }
        // No permission prompts during wake/reconnect. A failed permission
        // check leaves input off until the user can correct it.
        try? applyEnabled(true)
    }
    private func applyEnabled(_ value: Bool) throws {
        if value && native {
            let current = Self.permissions
            guard current.granted else { throw ClipError.invalid(current.explanation) }
            try installTap()
        }
        if !value { endSession(reason: .disabled); removeTap(); localHeldKeys = [] }
        enabled = value; edgeSince = nil; cooldown = Date().addingTimeInterval(0.7)
        updateTimer()
        if native { logger.notice("input_enabled value=\(value, privacy: .public)") }
        observeSecureInput(); advertise(); onChange?()
    }
    private func updateTimer() {
        guard native else { return }
        if active, inputActivity == nil {
            inputActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Interactive input sharing")
        } else if !active, let activity = inputActivity {
            ProcessInfo.processInfo.endActivity(activity); inputActivity = nil
        }
        guard let interval = maintenanceInterval else { timer?.invalidate(); timer = nil; lastTick = nil; return }
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate(); lastTick = nil
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func beganControl() {
        motionCadence = MotionCadence(); lastCadenceLog = -Double.infinity
        controlStarted = ProcessInfo.processInfo.systemUptime
        sentMoves = 0; receivedMoves = 0; maxTimerDelayMS = 0
        updateTimer()
        if native { logger.notice("control_begin role=\(self.mode.rawValue, privacy: .public)") }
    }
    func stop() { try? setEnabled(false) }
    deinit {
        if let inputActivity { ProcessInfo.processInfo.endActivity(inputActivity) }
    }
    private func advertise() {
        emit(MousePacket(kind: .availability, enabled: enabled, keyboardEnabled: enabled && keyboardSupported, secureInputActive: secureInputBlocked))
    }
    @discardableResult
    private func observeSecureInput() -> Bool {
        let blocked = enabled && secureInputEnabled()
        guard blocked != secureInputBlocked else { return blocked }
        if blocked { releasedReturn = nil }
        secureInputBlocked = blocked
        edgeSince = nil
        onEdgeProgress?(nil, side, 0)
        if !blocked {
            // Secure input can hide key-up events. Keep keys that are still
            // physically down, but never let a missed release block re-entry.
            localHeldKeys = localHeldKeys.filter { native && CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) }
        }
        if native { logger.notice("secure_input changed blocked=\(blocked, privacy: .public)") }
        advertise(); onChange?()
        return blocked
    }
    func receive(_ packet: MousePacket, from sender: String, now: Date = Date()) {
        guard sender == peer, (try? packet.validate()) != nil else { return }
        if packet.kind == .layout {
            guard let next = packet.layout, next.isValid(local: local, peer: sender) else { return }
            if layout == nil || next.isNewer(than: layout!) {
                endSession(reason: .layoutChanged); layout = next; onLayout?(next); onChange?()
            }
            return
        }
        if packet.kind == .availability {
            if native, remoteEnabled != (packet.enabled == true) {
                logger.notice("input_peer_enabled value=\(packet.enabled == true, privacy: .public)")
            }
            remoteEnabled = packet.enabled == true
            remoteSecureInputBlocked = packet.secureInputActive == true
            if remoteSecureInputBlocked && active { endSession(notify: false, reason: .secureInput, byPeer: true) }
            let wasKeyboardEnabled = remoteKeyboardEnabled
            remoteKeyboardEnabled = keyboardSupported && packet.keyboardEnabled == true
            if wasKeyboardEnabled && !remoteKeyboardEnabled { endSession(reason: .disabled, byPeer: true) }
            if !remoteEnabled { endSession(notify: false, reason: .disabled, byPeer: true) }
            onChange?(); return
        }
        if packet.kind == .enter {
            if observeSecureInput() {
                emit(MousePacket(kind: .leave, token: packet.token, endReason: MouseEndReason.secureInput.rawValue)); return
            }
            guard enabled, remoteEnabled, mode == .local, now >= cooldown, packet.draggedFileName == nil || supportsFileDrag,
                  let side = packet.side, let fraction = packet.fraction,
                  let (point, rect) = ScreenGeometry.entry(side: side, fraction: fraction, displays: displays()) else {
                emit(MousePacket(kind: .deny, token: packet.token)); return
            }
            releasedReturn = nil
            draggedFileName = packet.draggedFileName
            token = packet.token; mode = .receiving; position = point; entryRect = rect; entrySide = side
            beganControl()
            returnArmed = false; returnEdgeSince = nil; lastReturnPush = nil
            lastEndReason = nil
            lastHeard = now; lastBeat = .distantPast
            if native { CGWarpMouseCursorPosition(point) }
            emit(MousePacket(kind: .accepted, token: token)); onChange?(); return
        }
        guard let token, token == packet.token, enabled else { return }
        if observeSecureInput() { endSession(reason: .secureInput); return }
        lastHeard = now
        switch packet.kind {
        case .accepted:
            guard mode == .requesting else { return }
            mode = .controlling; lastBeat = .distantPast
            beganControl()
            if native {
                let id = CGMainDisplayID()
                if CGDisplayHideCursor(id) == .success { hiddenOn = id }
                if draggedFileName == nil { CGWarpMouseCursorPosition(CGPoint(x: originRect.midX, y: origin.y)) }
            }
            if draggedFileName != nil { onFileDragAccepted?(token) }
            onChange?()
        case .returnFile:
            guard mode == .controlling, supportsReturnFile, !returningFile, draggedFileName == nil else { return }
            guard controllerButtons == [0], localHeldKeys.isEmpty, remoteEnabled, !remoteSecureInputBlocked,
                  let fraction = packet.fraction else { endSession(reason: .handoffCancelled); return }
            returningFile = true
            draggedFileName = packet.draggedFileName
            pendingX = 0; pendingY = 0
            position = ScreenGeometry.clamp(CGPoint(x: origin.x, y: originRect.minY + originRect.height * fraction), to: originRect)
            if let id = hiddenOn { CGDisplayShowCursor(id); hiddenOn = nil }
            if native { CGWarpMouseCursorPosition(position) }
            if native { logger.notice("return_drag_controller_accepted") }
            emit(MousePacket(kind: .returnAccepted, token: token))
            onChange?()
        case .returnAccepted:
            guard mode == .receiving, returningFile, pressed == [0] else { return }
            // Finish Finder's copy onto the edge panel while the hardware button stays down on the other Mac.
            pressed.remove(0)
            if native { post(MousePacket(kind: .input, token: token, action: .up), at: position) }
            onFileDragAccepted?(token)
        case .dropFile:
            guard mode == .receiving, !returningFile, draggedFileName != nil, !fileDropReleased else { return }
            fileDropReleased = true
            if native { logger.notice("file_drop_received") }
            let prepared = onFileDropPosition?(token, position) == true
            draggedFileName = nil; fileDropReleased = false
            emit(MousePacket(kind: .dropReady, token: token, preparedImage: prepared ? true : nil))
        case .dropReady:
            if returningFile, mode == .receiving, pressed.isEmpty {
                fileDropReleased = true
                onFileDropReady?(token, packet.preparedImage == true)
                endSession(notify: false, reason: .returnEdge)
                return
            }
            guard mode == .controlling, draggedFileName != nil, fileDropReleased else { return }
            if native { logger.notice("file_drop_acknowledged") }
            onFileDropReady?(token, packet.preparedImage == true)
            fileDragAnchor = nil
            draggedFileName = nil; fileDropReleased = false; dropDeadline = nil
            if native { CGWarpMouseCursorPosition(CGPoint(x: originRect.midX, y: origin.y)) }
            onChange?()
        case .input:
            guard mode == .receiving, !returningFile, draggedFileName == nil || (packet.action == .move && !fileDropReleased) else { return }
            apply(packet, now: now)
        case .leave: endSession(notify: false, fraction: packet.fraction, reason: packet.endReason.flatMap(MouseEndReason.init(rawValue:)) ?? .peerEnded, byPeer: true)
        case .deny: if mode == .requesting { endSession(notify: false, reason: .notReady, byPeer: true) }
        case .heartbeat: break
        default: break
        }
    }
    // Return true only while local mouse events must be suppressed.
    func localMove(point: CGPoint, dx: Double, dy: Double, flags: UInt64 = 0, buttonsDown: Bool = false, now: Date = Date()) -> Bool {
        guard enabled else { return false }
        if observeSecureInput() { endSession(reason: .secureInput); return false }
        if mode == .receiving {
            // A position-only event is not evidence of local input. In particular,
            // it must not undo a newly accepted handoff with no physical motion.
            if dx != 0 || dy != 0 { endSession(reason: .localMotion) }
            return false
        }
        if mode == .controlling {
            if returningFile {
                position = point
                _ = onFileDragMove?(point)
                return true
            }
            if fileDropReleased { return true }
            if pendingFlags != flags & 0x1E0000 { flushMove(force: true) }
            let idle = now.timeIntervalSince(lastMoveObserved)
            lastMoveObserved = now
            pendingX = max(-4096, min(4096, pendingX + dx)); pendingY = max(-4096, min(4096, pendingY + dy)); pendingFlags = flags & 0x1E0000
            // Send the first sample immediately. During a burst, coalesce only
            // the samples inside one update interval; the timer drains its tail.
            if idle >= Self.moveInterval || idle < 0 { flushMove() }
            return true
        }
        if mode == .requesting {
            let edge = side == .left ? originRect.minX : originRect.maxX
            if abs(point.x - edge) > 8 || (buttonsDown && draggedFileName == nil) { endSession(reason: .handoffCancelled) }
            return false
        }
        guard mode == .local, remoteEnabled, !remoteSecureInputBlocked, peer != nil, !buttonsDown, localHeldKeys.isEmpty, flags == 0, now >= cooldown,
              let rect = ScreenGeometry.exit(at: point, deltaX: dx, side: side, displays: displays()) else {
            if edgeSince != nil { onEdgeProgress?(nil, side, 0) }
            edgeSince = nil; return false
        }
        if edgeSince == nil { edgeSince = now }
        onEdgeProgress?(point, side, min(1, now.timeIntervalSince(edgeSince!) / 0.15))
        guard now.timeIntervalSince(edgeSince!) >= 0.15 else { return false }
        requestHandoff(at: point, rect: rect, now: now)
        return false
    }
    func isReceivingDrop(_ id: UUID) -> Bool {
        guard enabled, remoteEnabled, !remoteSecureInputBlocked, !observeSecureInput() else { return false }
        if releasedReturn == id { return true }
        return token == id && (returningFile ? mode == .controlling : mode == .receiving)
    }

    func startFileDrag(named name: String, at point: CGPoint, now: Date = Date()) -> Bool {
        if canPickUpRemoteDrag, enabled, remoteEnabled, !observeSecureInput(), FilePacket.safeName(name),
           let token, let rect = ScreenGeometry.exit(at: point, deltaX: entrySide == .left ? -1 : 1, side: entrySide, displays: displays()),
           rect == entryRect {
            returningFile = true; draggedFileName = name; position = point
            if native { logger.notice("return_drag_source_captured") }
            emit(MousePacket(kind: .returnFile, token: token, fraction: ScreenGeometry.fraction(point.y, in: rect), draggedFileName: name))
            return returningFile
        }
        guard supportsFileDrag, enabled, remoteEnabled, mode == .local, now >= cooldown, !observeSecureInput(),
              !remoteSecureInputBlocked, localHeldKeys.isEmpty, FilePacket.safeName(name),
              let rect = ScreenGeometry.exit(at: point, deltaX: side == .left ? -1 : 1, side: side, displays: displays()) else { return false }
        fileDragAnchor = point
        draggedFileName = name
        requestHandoff(at: point, rect: rect, now: now)
        return draggedFileName != nil
    }
    func releaseFileDrag() -> Bool {
        guard mode == .controlling, draggedFileName != nil, !fileDropReleased else { return false }
        flushMove(force: true)
        guard mode == .controlling, !observeSecureInput() else { return false }
        fileDropReleased = true; dropDeadline = Date().addingTimeInterval(2)
        if native { logger.notice("file_drop_released") }
        emit(MousePacket(kind: .dropFile, token: token))
        return true
    }
    private func requestHandoff(at point: CGPoint, rect: CGRect, now: Date) {
        origin = ScreenGeometry.clamp(point, to: rect, inset: 24); originRect = rect
        releasedReturn = nil
        token = UUID(); mode = .requesting; edgeSince = nil; lastHeard = now; lastEndReason = nil
        updateTimer()
        if native { logger.notice("control_request") }
        emit(MousePacket(kind: .enter, token: token, side: side.opposite, fraction: ScreenGeometry.fraction(point.y, in: rect), draggedFileName: draggedFileName))
        onChange?()
    }
    func localButton(action: MousePacket.Action, button: Int, clicks: Int = 1, flags: UInt64 = 0, at point: CGPoint? = nil) -> Bool {
        if returningFile, mode == .controlling, let token {
            guard action == .up, button == 0, controllerButtons == [0], !observeSecureInput() else {
                endSession(reason: .handoffCancelled); return true
            }
            let prepared = onFileDropPosition?(token, point ?? position) == true
            emit(MousePacket(kind: .dropReady, token: token, preparedImage: prepared ? true : nil))
            if self.token == token {
                endSession(notify: false, reason: .returnEdge)
                releasedReturn = token
            }
            return true
        }
        if draggedFileName != nil, mode == .requesting || mode == .controlling {
            if action == .up && button == 0 && mode == .controlling {
                if !fileDropReleased && !releaseFileDrag() { endSession(reason: .handoffCancelled) }
            } else { endSession(reason: .localButton) }
            return false // Finder must receive the button-up to finish its native drag.
        }
        if mode == .receiving || mode == .requesting { endSession(reason: .localButton); return false }
        guard enabled, mode == .controlling else { return false }
        flushMove(force: true)
        if action == .down { controllerButtons.insert(button) } else { controllerButtons.remove(button) }
        emit(MousePacket(kind: .input, token: token, action: action, button: button, clicks: max(1, min(3, clicks)), flags: flags & 0x1E0000))
        return true
    }
    // Only normalized Dock swipe fields cross the network, never opaque CGEvent data.
    func localGesture(_ packet: DockSwipePacket) -> Bool {
        guard draggedFileName == nil, enabled, (try? packet.validate()) != nil else { return false }
        if mode == .receiving || mode == .requesting { endSession(reason: .localScroll); return false }
        guard mode == .controlling, gesturesSupported, remoteEnabled, let token,
              let peer, let sendGesture else { return false }
        if observeSecureInput() { endSession(reason: .secureInput); return false }
        // Once a swipe belongs to the remote Mac, malformed sequence updates
        // must not leak into the source Dock. Ignore them but keep ownership.
        guard packet.phase == 1 ? sentGesture == nil : sentGesture?.axis == packet.axis else { return sentGesture != nil }
        if native, packet.phase == 1 || packet.isTerminal {
            logger.notice("gesture_send phase=\(packet.phase, privacy: .public) axis=\(packet.axis, privacy: .public)")
        }
        var outgoing = packet; outgoing.token = token
        sentGesture = packet.isTerminal ? nil : outgoing
        flushMove(force: true)
        sendGesture(peer, outgoing) { [weak self] success in
            guard let self, !success, self.token == token else { return }
            self.endSession(notify: false, reason: .sendFailed)
        }
        return true
    }
    func receiveGesture(_ packet: DockSwipePacket, from sender: String, now: Date = Date()) {
        guard draggedFileName == nil, enabled, remoteEnabled, gesturesSupported, mode == .receiving,
              sender == peer, packet.token == token, (try? packet.validate()) != nil else { return }
        if observeSecureInput() { endSession(reason: .secureInput); return }
        guard packet.phase == 1 ? receivedGesture == nil : receivedGesture?.axis == packet.axis else { return }
        lastHeard = now
        if native, packet.phase == 1 || packet.isTerminal {
            logger.notice("gesture_receive phase=\(packet.phase, privacy: .public) axis=\(packet.axis, privacy: .public)")
        }
        receivedGesture = packet.isTerminal ? nil : packet
        lastGestureHeard = packet.isTerminal ? nil : now
        onGesture?(packet)
        if native { postGesture(packet) }
    }
    private func postGesture(_ packet: DockSwipePacket) {
        for event in DockSwipeAdapter.events(packet, at: position, marker: Self.marker) {
            event.post(tap: .cgSessionEventTap)
        }
    }
    func emergencyStop() { try? setEnabled(false) }
    // Called only by the enabled input tap. Key codes follow the receiving Mac's
    // input source; text and keyboard history are never collected.
    func localKey(action: KeyboardPacket.Action, keyCode: Int, flags: UInt64 = 0, isRepeat: Bool = false) -> Bool {
        guard enabled, (0...127).contains(keyCode) else { return false }
        if mode == .local, edgeSince != nil { edgeSince = nil; onEdgeProgress?(nil, side, 0) }
        if action == .down, keyCode == 53, flags & 0xC0000 == 0xC0000 { emergencyStop(); return true }
        if mode == .receiving, (canPickUpRemoteDrag || returningFile), action == .modifiers,
           !localHeldKeys.contains(keyCode), flags & (KeyboardPacket.modifierMasks[keyCode] ?? 0) == 0 {
            return false // A modifier release without a local press does not take over a Finder drag.
        }
        if draggedFileName != nil { endSession(reason: .localKeyboard); return false }
        if observeSecureInput() { endSession(reason: .secureInput); return false }
        switch action {
        case .down: localHeldKeys.insert(keyCode)
        case .up: localHeldKeys.remove(keyCode)
        case .modifiers:
            guard let mask = KeyboardPacket.modifierMasks[keyCode] else { return false }
            if flags & mask == 0 { localHeldKeys = localHeldKeys.filter { KeyboardPacket.modifierMasks[$0] != mask } }
            else if keyCode != 57 {
                if localHeldKeys.contains(keyCode) { localHeldKeys.remove(keyCode) } else { localHeldKeys.insert(keyCode) }
            }
        }
        if mode == .receiving || mode == .requesting { endSession(reason: .localKeyboard); return false }
        guard mode == .controlling else { return false }
        guard keyboardActive else { endSession(reason: .localKeyboard); return false }
        flushMove(force: true)
        guard let token, let peer, mode == .controlling, let sendKeyboard else { endSession(reason: .sendFailed); return true }
        let packet = KeyboardPacket(token: token, action: action, keyCode: keyCode, flags: flags & KeyboardPacket.allowedFlags, isRepeat: isRepeat)
        guard (try? packet.validate()) != nil else { endSession(reason: .localKeyboard); return false }
        sendKeyboard(peer, packet) { [weak self] success in
            guard let self, !success, self.token == token else { return }
            self.endSession(notify: false, reason: .sendFailed)
        }
        return true
    }
    func receiveKeyboard(_ packet: KeyboardPacket, from sender: String, now: Date = Date()) {
        guard draggedFileName == nil, sender == peer, keyboardActive, mode == .receiving, packet.token == token,
              (try? packet.validate()) != nil else { return }
        if observeSecureInput() { endSession(reason: .secureInput); return }
        lastHeard = now
        switch packet.action {
        case .down:
            if packet.isRepeat { guard pressedKeys.contains(packet.keyCode) else { return } }
            else { guard pressedKeys.insert(packet.keyCode).inserted else { return } }
        case .up: guard pressedKeys.remove(packet.keyCode) != nil else { return }
        case .modifiers:
            let mask = KeyboardPacket.modifierMasks[packet.keyCode]!
            if packet.flags & mask == 0 { pressedKeys = pressedKeys.filter { KeyboardPacket.modifierMasks[$0] != mask } }
            else if packet.keyCode != 57 {
                if pressedKeys.contains(packet.keyCode) { pressedKeys.remove(packet.keyCode) } else { pressedKeys.insert(packet.keyCode) }
            }
        }
        receivedKeyFlags = packet.flags
        onKeyboardInput?(packet)
        if native { postKeyboard(packet) }
    }
    func tick(now: Date = Date()) {
        if active {
            let uptime = ProcessInfo.processInfo.systemUptime
            if let lastTick { maxTimerDelayMS = max(maxTimerDelayMS, max(0, uptime - lastTick - (maintenanceInterval ?? 0)) * 1000) }
            lastTick = uptime
        }
        if native, now.timeIntervalSince(lastPermissionCheck) > 1 {
            lastPermissionCheck = now
            if enabled && !Self.permissionsGranted { emergencyStop(); return }
        }
        let secure = observeSecureInput()
        if secure && active { endSession(reason: .secureInput); return }
        guard active else { return }
        if let dropDeadline, now > dropDeadline { endSession(reason: .timeout); return }
        // Heartbeats prove liveness, not progress of an interactive Dock swipe.
        // Bound a missing ended/cancelled event so its animation cannot stay open.
        if receivedGesture != nil, let lastGestureHeard, now.timeIntervalSince(lastGestureHeard) > 8 {
            endSession(reason: .timeout); return
        }
        if now.timeIntervalSince(lastHeard) > (mode == .requesting ? 1 : 2) { endSession(reason: .timeout); return }
        flushMove()
        if now.timeIntervalSince(lastBeat) >= 0.5 {
            lastBeat = now; emit(MousePacket(kind: .heartbeat, token: token))
        }
    }
    private func flushMove(force: Bool = false) {
        guard mode == .controlling, force || movesInFlight == 0, pendingX != 0 || pendingY != 0 else { return }
        if observeSecureInput() { endSession(reason: .secureInput); return }
        let dx = pendingX, dy = pendingY; pendingX = 0; pendingY = 0
        sentMoves += 1
        movesInFlight += 1
        let session = token
        emit(MousePacket(kind: .input, token: token, action: .move, dx: dx, dy: dy, flags: pendingFlags, motionSentAt: ProcessInfo.processInfo.systemUptime)) { [weak self] success in
            guard let self, self.token == session else { return }
            self.movesInFlight = max(0, self.movesInFlight - 1)
            // Drain accumulated motion as soon as the socket accepts input.
            // Waiting for the next display-rate tick adds avoidable latency.
            if success { self.flushMove() }
        }
    }
    private func apply(_ packet: MousePacket, now: Date) {
        guard let action = packet.action else { return }
        switch action {
        case .move:
            receivedMoves += 1
            let uptime = ProcessInfo.processInfo.systemUptime
            motionCadence.record(sent: packet.motionSentAt, arrived: uptime)
            if native, motionCadence.count >= 10, uptime - lastCadenceLog >= 5 {
                lastCadenceLog = uptime
                logger.notice("motion_cadence samples=\(self.motionCadence.count, privacy: .public) source_p95_ms=\(self.motionCadence.sourceP95, privacy: .public) arrival_p95_ms=\(self.motionCadence.arrivalP95, privacy: .public) excess_p95_ms=\(self.motionCadence.excessP95, privacy: .public) bursts=\(self.motionCadence.bursts, privacy: .public)")
            }
            let next = CGPoint(x: position.x + packet.dx, y: position.y + packet.dy)
            let atReturnEdge = entrySide == .left ? next.x <= entryRect.minX + 1 && packet.dx < 0 : next.x >= entryRect.maxX - 1 && packet.dx > 0
            // Entry is only four points inside the screen. Do not interpret a
            // single reverse delta there as an intentional return. First move
            // into the display, then push its edge continuously, as on entry.
            if returnArmed, atReturnEdge, pressed.isEmpty, position.y >= entryRect.minY, position.y <= entryRect.maxY {
                if lastReturnPush == nil || now.timeIntervalSince(lastReturnPush!) > 0.25 { returnEdgeSince = now }
                if returnEdgeSince == nil { returnEdgeSince = now }
                lastReturnPush = now
                if now.timeIntervalSince(returnEdgeSince!) >= 0.15 {
                    endSession(fraction: ScreenGeometry.fraction(position.y, in: entryRect), reason: .returnEdge); return
                }
            } else {
                returnEdgeSince = nil; lastReturnPush = nil
            }
            position = ScreenGeometry.project(next, displays: displays())
            if canPickUpRemoteDrag, packet.flags == 0,
               ScreenGeometry.exit(at: position, deltaX: packet.dx, side: entrySide, displays: displays(), distance: 120) == entryRect {
                onFileEdge?(position, entrySide)
            }
            let depth = entrySide == .left ? position.x - entryRect.minX : entryRect.maxX - position.x
            if depth >= min(24, entryRect.width / 4) { returnArmed = true }
        case .down:
            guard !pressed.contains(packet.button) else { return }; pressed.insert(packet.button)
            returnEdgeSince = nil; lastReturnPush = nil
        case .up: guard pressed.contains(packet.button) else { return }; pressed.remove(packet.button)
        case .scroll: break
        }
        onInput?(packet, position)
        if native {
            if action == .move, draggedFileName != nil, onFileDragMove?(position) == true { return }
            post(packet, at: position)
        }
    }
    func endSession(notify: Bool = true, fraction: Double? = nil, reason: MouseEndReason = .stopped, byPeer: Bool = false) {
        let old = mode, oldToken = token
        let cursorReturned = returningFile && old == .controlling
        returningFile = false; controllerButtons.removeAll(); releasedReturn = nil
        if let gesture = receivedGesture {
            let cancelled = gesture.cancelled
            onGesture?(cancelled)
            if native { postGesture(cancelled) }
        }
        sentGesture = nil; receivedGesture = nil; lastGestureHeard = nil
        if old != .local, native {
            let duration = Int((ProcessInfo.processInfo.systemUptime - (controlStarted ?? ProcessInfo.processInfo.systemUptime)) * 1000)
            logger.notice("control_end role=\(old.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public) peer_ended=\(byPeer, privacy: .public) duration_ms=\(duration, privacy: .public) sent_moves=\(self.sentMoves, privacy: .public) received_moves=\(self.receivedMoves, privacy: .public) max_timer_delay_ms=\(Int(self.maxTimerDelayMS), privacy: .public)")
        }
        controlStarted = nil; sentMoves = 0; receivedMoves = 0; maxTimerDelayMS = 0
        if old != .local { lastEndReason = reason; endedByPeer = byPeer }
        fileDragAnchor = nil
        draggedFileName = nil; fileDropReleased = false; dropDeadline = nil
        mode = .local; token = nil; pendingX = 0; pendingY = 0; edgeSince = nil; movesInFlight = 0
        updateTimer()
        lastMoveObserved = .distantPast
        returnArmed = false; returnEdgeSince = nil; lastReturnPush = nil
        cooldown = Date().addingTimeInterval(0.7)
        onEdgeProgress?(nil, side, 0)
        if !pressedKeys.isEmpty || receivedKeyFlags != 0 {
            onKeysReleased?(pressedKeys)
            if native, let oldToken {
                for key in pressedKeys.sorted() {
                    postKeyboard(KeyboardPacket(token: oldToken, action: KeyboardPacket.modifierMasks[key] == nil ? .up : .modifiers, keyCode: key))
                }
                // Clear flags even when only Caps Lock was carried by an event.
                postKeyboard(KeyboardPacket(token: oldToken, action: .modifiers, keyCode: 55))
            }
            pressedKeys = []; receivedKeyFlags = 0
        }
        if !pressed.isEmpty {
            onRelease?(pressed)
            if native { for button in pressed { post(MousePacket(kind: .input, token: oldToken, action: .up, button: button), at: position) } }
            pressed = []
        }
        if let id = hiddenOn { CGDisplayShowCursor(id); hiddenOn = nil }
        if native, old == .controlling, !cursorReturned {
            var point = origin
            if let fraction { point.y = originRect.minY + originRect.height * fraction }
            CGWarpMouseCursorPosition(ScreenGeometry.clamp(point, to: originRect, inset: 24))
        }
        if notify, let oldToken { emit(MousePacket(kind: .leave, token: oldToken, fraction: fraction, endReason: reason.rawValue)) }
        if old != .local { onChange?() }
    }
    private func emit(_ packet: MousePacket, completion: ((Bool) -> Void)? = nil) {
        guard let peer, let send else { completion?(false); return }
        let session = token
        send(peer, packet) { [weak self] success in
            completion?(success)
            guard let self, !success, self.peer == peer, self.token == session else { return }
            self.endSession(notify: false, reason: .sendFailed)
        }
    }
    private func installTap() throws {
        guard tap == nil else { return }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        let gestureMask: CGEventMask = DockSwipeAdapter.available ? DockSwipeAdapter.eventMask : 0
        let mask = types.reduce(gestureMask) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<MouseSharing>.fromOpaque(context).takeUnretainedValue().handle(type, event: event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw ClipError.invalid(ui("Couldn’t start mouse input. Allow access, then restart NearClip."))
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
    func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { emergencyStop(); return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return Unmanaged.passUnretained(event) }
        if type == .keyDown || type == .keyUp || type == .flagsChanged {
            let action: KeyboardPacket.Action = type == .flagsChanged ? .modifiers : type == .keyDown ? .down : .up
            let blocked = localKey(action: action, keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                                   flags: event.flags.rawValue, isRepeat: type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
            return blocked ? nil : Unmanaged.passUnretained(event)
        }
        if type.rawValue == 29 || type.rawValue == 30 {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastGestureObservation >= 5 {
                lastGestureObservation = now
                let nativeType = DockSwipeAdapter.nativeType(event)
                let hid = event.getIntegerValueField(CGEventField(rawValue: 110)!)
                let phase = event.getIntegerValueField(CGEventField(rawValue: 132)!)
                let axis = event.getIntegerValueField(CGEventField(rawValue: 123)!)
                logger.notice("gesture_observed type=\(nativeType, privacy: .public) hid=\(hid, privacy: .public) phase=\(phase, privacy: .public) axis=\(axis, privacy: .public) role=\(self.mode.rawValue, privacy: .public) supported=\(self.gesturesSupported, privacy: .public)")
            }
        }
        if DockSwipeAdapter.nativeType(event) == 29, mode == .controlling, sentGesture != nil { return nil }
        if DockSwipeAdapter.nativeType(event) == 30, let packet = DockSwipeAdapter.read(event, token: token ?? UUID()) {
            if localGesture(packet) {
                if let terminal = DockSwipeAdapter.localTermination(event, packet: packet) {
                    return Unmanaged.passUnretained(terminal)
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        let flags = event.flags.rawValue & 0x1E0000
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let down = (0...2).contains { CGEventSource.buttonState(.combinedSessionState, button: CGMouseButton(rawValue: UInt32($0))!) }
            if mode == .local, type == .leftMouseDragged, supportsFileDrag, remoteEnabled, !secureInputBlocked, !remoteSecureInputBlocked,
               flags == 0, ScreenGeometry.exit(at: event.location, deltaX: Double(event.getIntegerValueField(.mouseEventDeltaX)), side: side, displays: displays(), distance: 120) != nil {
                onFileEdge?(event.location, side)
            }
            let blocked = localMove(point: event.location, dx: Double(event.getIntegerValueField(.mouseEventDeltaX)), dy: Double(event.getIntegerValueField(.mouseEventDeltaY)), flags: flags, buttonsDown: down)
            if blocked {
                if returningFile && mode == .controlling {
                    event.type = .mouseMoved
                    return Unmanaged.passUnretained(event)
                }
                if let anchor = fileDragAnchor, type == .leftMouseDragged {
                    // Move the remote pointer while keeping Finder over the source drop target.
                    event.location = anchor
                    return Unmanaged.passUnretained(event)
                }
                if draggedFileName == nil { CGWarpMouseCursorPosition(CGPoint(x: originRect.midX, y: origin.y)) }
                return nil
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            guard (0...2).contains(button) else { if active { endSession(reason: .localButton) }; return Unmanaged.passUnretained(event) }
            if type == .leftMouseUp, mode == .controlling, let anchor = fileDragAnchor { event.location = anchor }
            let down = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
            if localButton(action: down ? .down : .up, button: button, clicks: Int(event.getIntegerValueField(.mouseEventClickState)), flags: flags, at: event.location) { return nil }
        case .scrollWheel:
            if returningFile { endSession(reason: .localScroll); return nil }
            if mode == .receiving { endSession(reason: .localScroll) }
            if mode == .controlling {
                flushMove(force: true)
                let x = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
                let y = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
                let phase = Int(event.getIntegerValueField(.scrollWheelEventScrollPhase))
                let momentum = Int(event.getIntegerValueField(.scrollWheelEventMomentumPhase))
                emit(MousePacket(kind: .input, token: token, action: .scroll, dx: max(-4096, min(4096, x)), dy: max(-4096, min(4096, y)), flags: flags,
                                 scrollPhase: [0, 1, 2, 4, 8, 128].contains(phase) ? phase : 0,
                                 momentumPhase: (0...3).contains(momentum) ? momentum : 0)); return nil
            }
        default: break
        }
        return Unmanaged.passUnretained(event)
    }
    private func post(_ packet: MousePacket, at point: CGPoint) {
        Self.makeEvent(packet, at: point, pressed: pressed, source: eventSource)?.post(tap: .cgSessionEventTap)
    }
    private func postKeyboard(_ packet: KeyboardPacket) {
        Self.makeKeyboardEvent(packet, source: eventSource)?.post(tap: .cgSessionEventTap)
    }
    static func makeKeyboardEvent(_ packet: KeyboardPacket, source: CGEventSource? = nil) -> CGEvent? {
        guard (try? packet.validate()) != nil else { return nil }
        let down = packet.action == .down || (packet.action == .modifiers && packet.flags & (KeyboardPacket.modifierMasks[packet.keyCode] ?? 0) != 0)
        guard let event = CGEvent(keyboardEventSource: source ?? CGEventSource(stateID: .privateState), virtualKey: CGKeyCode(packet.keyCode), keyDown: down) else { return nil }
        if packet.action == .modifiers { event.type = .flagsChanged }
        event.flags = CGEventFlags(rawValue: packet.flags)
        event.setIntegerValueField(.keyboardEventAutorepeat, value: packet.isRepeat ? 1 : 0)
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        return event
    }
    // Creating an event has no system input effect; tests inspect this adapter without posting.
    static func makeEvent(_ packet: MousePacket, at point: CGPoint, pressed: Set<Int>, source: CGEventSource? = nil) -> CGEvent? {
        guard packet.kind == .input, packet.action != nil, (try? packet.validate()) != nil else { return nil }
        let event: CGEvent?
        let source = source ?? CGEventSource(stateID: .privateState)
        if packet.action == .scroll {
            event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(packet.dy), wheel2: Int32(packet.dx), wheel3: 0)
            if let phase = packet.scrollPhase { event?.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase)) }
            if let momentum = packet.momentumPhase { event?.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum)) }
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
