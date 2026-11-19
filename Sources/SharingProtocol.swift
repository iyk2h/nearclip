import Foundation

struct ConnectedPeer {
    let device: String
    let name: String
    let connection: UUID
    let features: Set<String>
    var appVersion: AppVersion? = nil
    var osMajor: Int? = nil
    var inputReady: Bool = true
    var inputSession: UUID? = nil
    var inputFailure: String? = nil
}

enum SharingFeature {
    static let files = "files-v1"
    static let fileDrag = "finder-drag-v1"
    static let mouse = "mouse-v1"
    static let keyboard = "keyboard-v1"
    static let gestures = "dock-swipe-v1"
    static let inputChannel = "input-channel-v1"
    static let inputRecovery = "input-recovery-v1"
    static let inputMetrics = "input-metrics-v1"
    static let inputDiagnostics = "input-diagnostics-v1"
    static let supported = [files, mouse, keyboard, inputChannel, inputRecovery, inputMetrics, inputDiagnostics] + (DockSwipeAdapter.available ? [gestures] : []) + [fileDrag]
    static let maxPacket = 128 * 1024
}

struct FeaturePacket: Codable {
    var file: FilePacket? = nil
    var mouse: MousePacket? = nil
    var keyboard: KeyboardPacket? = nil
    var gesture: DockSwipePacket? = nil
    var feature: String { gesture != nil ? SharingFeature.gestures : file != nil ? SharingFeature.files : keyboard != nil ? SharingFeature.keyboard : SharingFeature.mouse }
    func validate() throws {
        guard [file != nil, mouse != nil, keyboard != nil, gesture != nil].filter({ $0 }).count == 1 else { throw ClipError.invalid(ui("Invalid sharing message.")) }
        try file?.validate(); try mouse?.validate(); try keyboard?.validate(); try gesture?.validate()
    }
    func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= SharingFeature.maxPacket else { throw ClipError.invalid(ui("Sharing message exceeds the size limit.")) }
        return data
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= SharingFeature.maxPacket else { throw ClipError.invalid(ui("Sharing message exceeds the size limit.")) }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate(); return result
    }
}

struct FilePacket: Codable {
    enum Kind: String, Codable { case offer, accept, chunk, ack, finish, complete, cancel }
    static let maxChunkWindow = 3
    static let chunkSize = 48 * 1024
    static let maxSize: Int64 = 2 * 1024 * 1024 * 1024
    let kind: Kind
    let id: UUID
    var name: String? = nil
    var size: Int64? = nil
    var offset: Int64? = nil
    var bytes: Data? = nil
    var digest: Data? = nil
    var chunkWindow: Int? = nil
    func validate() throws {
        if let chunkWindow, kind != .accept || !(1...Self.maxChunkWindow).contains(chunkWindow) {
            throw ClipError.invalid(ui("Invalid file message."))
        }
        if let offset, offset < 0 || offset > Self.maxSize { throw ClipError.invalid(ui("Invalid file offset.")) }
        switch kind {
        case .offer:
            guard let name, Self.safeName(name), let size, size >= 0, size <= Self.maxSize,
                  bytes == nil else { throw ClipError.invalid(ui("Send one regular file up to 2 GiB.")) }
        case .chunk:
            guard let bytes, !bytes.isEmpty, bytes.count <= Self.chunkSize, offset != nil else { throw ClipError.invalid(ui("Invalid file chunk.")) }
        case .ack: guard offset != nil else { throw ClipError.invalid(ui("Missing acknowledgement offset.")) }
        case .finish: guard digest?.count == 32 else { throw ClipError.invalid(ui("Missing file checksum.")) }
        default: guard bytes == nil else { throw ClipError.invalid(ui("Invalid file message.")) }
        }
    }
    static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && name != "." && name != ".." &&
        !name.contains(where: { "/\\:".contains($0) }) &&
        !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

enum ScreenSide: String, Codable { case left, right
    var opposite: Self { self == .left ? .right : .left }
}

// Both peers converge on the latest layout. Equal revisions use a stable device-ID order.
struct ScreenLayout: Codable, Equatable {
    let revision: UInt64
    let author: String
    let left: String
    let right: String
    func isValid(local: String, peer: String) -> Bool {
        revision < UInt64.max - 100 && Set([left, right]) == Set([local, peer]) && left != right && (author == local || author == peer)
    }
    func isNewer(than old: Self) -> Bool { revision == old.revision ? author > old.author : revision > old.revision }
    func peerSide(for device: String) -> ScreenSide { device == left ? .right : .left }
}

// Only fixed reason codes cross the wire. No keys, pointer coordinates, or
// clipboard contents are included in handoff diagnostics.
enum MouseEndReason: String {
    case stopped, connectionChanged, layoutChanged, disabled, peerEnded, notReady
    case localMotion, localButton, localKeyboard, localScroll, handoffCancelled
    case timeout, returnEdge, sendFailed, secureInput
    var explanation: String {
        switch self {
        case .stopped: return ui("Control ended")
        case .connectionChanged: return ui("Connection changed")
        case .layoutChanged: return ui("Screen layout changed")
        case .disabled: return ui("Mouse sharing turned off")
        case .peerEnded: return ui("The other Mac ended control. Check that Mac for details.")
        case .notReady: return ui("Handoff declined. Try again shortly.")
        case .localMotion: return ui("Local pointer movement")
        case .localButton: return ui("Local mouse button pressed")
        case .localKeyboard: return ui("Local keyboard input")
        case .localScroll: return ui("Local scrolling")
        case .handoffCancelled: return ui("Pointer left the edge or a button was pressed during handoff")
        case .timeout: return ui("Mouse control timed out")
        case .returnEdge: return ui("Pointer reached the return edge")
        case .sendFailed: return ui("Couldn’t send mouse control message")
        case .secureInput: return ui("Secure Input active. Type directly on the affected Mac.")
        }
    }
}

struct MousePacket: Codable {
    enum Kind: String, Codable { case availability, layout, enter, accepted, input, leave, heartbeat, deny, dropFile, dropReady }
    enum Action: String, Codable { case move, down, up, scroll }
    let kind: Kind
    var token: UUID? = nil
    var enabled: Bool? = nil
    var layout: ScreenLayout? = nil
    var side: ScreenSide? = nil
    var fraction: Double? = nil
    var action: Action? = nil
    var dx: Double = 0
    var dy: Double = 0
    var button: Int = 0
    var clicks: Int = 1
    var flags: UInt64 = 0
    // Optional for compatibility with mouse-v1 peers released before 0.4.3.
    var endReason: String? = nil
    var keyboardEnabled: Bool? = nil
    var scrollPhase: Int? = nil
    var momentumPhase: Int? = nil
    var secureInputActive: Bool? = nil
    var draggedFileName: String? = nil
    var motionSentAt: Double? = nil
    func validate() throws {
        if let draggedFileName, kind != .enter || !FilePacket.safeName(draggedFileName) { throw ClipError.invalid(ui("Invalid file message.")) }
        if let motionSentAt {
            guard kind == .input, action == .move, motionSentAt.isFinite, motionSentAt >= 0 else { throw ClipError.invalid(ui("Invalid movement timestamp.")) }
        }
        if secureInputActive != nil && kind != .availability { throw ClipError.invalid(ui("Invalid Secure Input state.")) }
        if scrollPhase != nil || momentumPhase != nil {
            guard kind == .input, action == .scroll,
                  [0, 1, 2, 4, 8, 128].contains(scrollPhase ?? 0),
                  (0...3).contains(momentumPhase ?? 0) else { throw ClipError.invalid(ui("Invalid scroll state.")) }
        }
        if let endReason, kind != .leave || endReason.utf8.count > 64 {
            throw ClipError.invalid(ui("Invalid reason for ending control."))
        }
        guard dx.isFinite, dy.isFinite, abs(dx) <= 4096, abs(dy) <= 4096,
              (0...2).contains(button), (1...3).contains(clicks), flags & ~UInt64(0x1E0000) == 0 else { throw ClipError.invalid(ui("Invalid mouse input.")) }
        if let fraction, !fraction.isFinite || !(0...1).contains(fraction) { throw ClipError.invalid(ui("Invalid screen position.")) }
        switch kind {
        case .availability: guard enabled != nil else { throw ClipError.invalid(ui("Missing input-sharing state.")) }
        case .layout: guard layout != nil else { throw ClipError.invalid(ui("Missing screen layout.")) }
        case .enter: guard token != nil, side != nil, fraction != nil else { throw ClipError.invalid(ui("Missing entry position.")) }
        case .input: guard token != nil, action != nil else { throw ClipError.invalid(ui("Missing input session.")) }
        default: guard token != nil else { throw ClipError.invalid(ui("Missing input session.")) }
        }
    }
}

struct KeyboardPacket: Codable {
    enum Action: String, Codable { case down, up, modifiers }
    static let allowedFlags: UInt64 = 0xBF0000 // Caps, Shift, Control, Option, Command, keypad, Fn.
    static let modifierMasks: [Int: UInt64] = [
        54: 0x100000, 55: 0x100000, 56: 0x20000, 60: 0x20000,
        58: 0x80000, 61: 0x80000, 59: 0x40000, 62: 0x40000,
        57: 0x10000, 63: 0x800000
    ]
    let token: UUID
    let action: Action
    let keyCode: Int
    var flags: UInt64 = 0
    var isRepeat: Bool = false
    func validate() throws {
        guard (0...127).contains(keyCode), flags & ~Self.allowedFlags == 0,
              !isRepeat || action == .down else { throw ClipError.invalid(ui("Invalid keyboard input.")) }
        if action == .modifiers {
            guard Self.modifierMasks[keyCode] != nil else { throw ClipError.invalid(ui("Invalid modifier key.")) }
        } else if Self.modifierMasks[keyCode] != nil {
            throw ClipError.invalid(ui("Invalid modifier event."))
        }
    }
}

