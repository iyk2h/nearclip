import Foundation

struct ConnectedPeer {
    let device: String
    let name: String
    let connection: UUID
    let features: Set<String>
}

enum SharingFeature {
    static let files = "files-v1"
    static let mouse = "mouse-v1"
    static let keyboard = "keyboard-v1"
    static let supported = [files, mouse, keyboard]
    static let maxPacket = 128 * 1024
}

struct FeaturePacket: Codable {
    var file: FilePacket? = nil
    var mouse: MousePacket? = nil
    var keyboard: KeyboardPacket? = nil
    var feature: String { file != nil ? SharingFeature.files : keyboard != nil ? SharingFeature.keyboard : SharingFeature.mouse }
    func encoded() throws -> Data {
        guard [file != nil, mouse != nil, keyboard != nil].filter({ $0 }).count == 1 else { throw ClipError.invalid("잘못된 공유 메시지예요.") }
        try file?.validate(); try mouse?.validate(); try keyboard?.validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= SharingFeature.maxPacket else { throw ClipError.invalid("공유 메시지가 너무 커요.") }
        return data
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= SharingFeature.maxPacket else { throw ClipError.invalid("공유 메시지가 너무 커요.") }
        let result = try JSONDecoder().decode(Self.self, from: data)
        _ = try result.encoded(); return result
    }
}

struct FilePacket: Codable {
    enum Kind: String, Codable { case offer, accept, chunk, ack, finish, complete, cancel }
    static let chunkSize = 48 * 1024
    static let maxSize: Int64 = 2 * 1024 * 1024 * 1024
    let kind: Kind
    let id: UUID
    var name: String? = nil
    var size: Int64? = nil
    var offset: Int64? = nil
    var bytes: Data? = nil
    var digest: Data? = nil
    func validate() throws {
        if let offset, offset < 0 || offset > Self.maxSize { throw ClipError.invalid("잘못된 파일 위치예요.") }
        switch kind {
        case .offer:
            guard let name, Self.safeName(name), let size, size >= 0, size <= Self.maxSize,
                  bytes == nil else { throw ClipError.invalid("일반 파일을 2GB까지 보낼 수 있어요.") }
        case .chunk:
            guard let bytes, !bytes.isEmpty, bytes.count <= Self.chunkSize, offset != nil else { throw ClipError.invalid("잘못된 파일 조각이에요.") }
        case .ack: guard offset != nil else { throw ClipError.invalid("파일 확인 위치가 없어요.") }
        case .finish: guard digest?.count == 32 else { throw ClipError.invalid("파일 검증 값이 없어요.") }
        default: guard bytes == nil else { throw ClipError.invalid("잘못된 파일 메시지예요.") }
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
        case .stopped: return "제어 종료"
        case .connectionChanged: return "연결 변경"
        case .layoutChanged: return "화면 배치 변경"
        case .disabled: return "마우스 공유 꺼짐"
        case .peerEnded: return "상대가 제어 종료 (상세 원인은 상대 앱에서 확인)"
        case .notReady: return "진입 요청 거절 · 잠시 뒤 다시 시도하세요"
        case .localMotion: return "로컬 마우스 이동 감지"
        case .localButton: return "로컬 마우스 버튼 감지"
        case .localKeyboard: return "로컬 키보드 입력 감지"
        case .localScroll: return "로컬 스크롤 감지"
        case .handoffCancelled: return "연결 대기 중 가장자리 이탈 또는 버튼 입력"
        case .timeout: return "마우스 제어 응답 시간 초과"
        case .returnEdge: return "돌아오는 화면 가장자리 도달"
        case .sendFailed: return "마우스 제어 메시지 전송 실패"
        case .secureInput: return "macOS 보안 입력 활성화 · 해당 Mac에서 직접 입력하세요"
        }
    }
}

struct MousePacket: Codable {
    enum Kind: String, Codable { case availability, layout, enter, accepted, input, leave, heartbeat, deny }
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
    func validate() throws {
        if let endReason, kind != .leave || endReason.utf8.count > 64 {
            throw ClipError.invalid("잘못된 마우스 종료 사유예요.")
        }
        guard dx.isFinite, dy.isFinite, abs(dx) <= 4096, abs(dy) <= 4096,
              (0...2).contains(button), (1...3).contains(clicks), flags & ~UInt64(0x1E0000) == 0 else { throw ClipError.invalid("잘못된 마우스 입력이에요.") }
        if let fraction, !fraction.isFinite || !(0...1).contains(fraction) { throw ClipError.invalid("잘못된 화면 위치예요.") }
        switch kind {
        case .availability: guard enabled != nil else { throw ClipError.invalid("입력 공유 상태가 없어요.") }
        case .layout: guard layout != nil else { throw ClipError.invalid("화면 배치가 없어요.") }
        case .enter: guard token != nil, side != nil, fraction != nil else { throw ClipError.invalid("화면 진입 위치가 없어요.") }
        case .input: guard token != nil, action != nil else { throw ClipError.invalid("입력 세션이 없어요.") }
        default: guard token != nil else { throw ClipError.invalid("입력 세션이 없어요.") }
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
              !isRepeat || action == .down else { throw ClipError.invalid("잘못된 키보드 입력이에요.") }
        if action == .modifiers {
            guard Self.modifierMasks[keyCode] != nil else { throw ClipError.invalid("잘못된 보조 키예요.") }
        } else if Self.modifierMasks[keyCode] != nil {
            throw ClipError.invalid("보조 키 이벤트 형식이 맞지 않아요.")
        }
    }
}

