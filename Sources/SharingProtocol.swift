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
    static let supported = [files, mouse]
    static let maxPacket = 128 * 1024
}

struct FeaturePacket: Codable {
    var file: FilePacket? = nil
    var mouse: MousePacket? = nil
    var feature: String { file != nil ? SharingFeature.files : SharingFeature.mouse }
    func encoded() throws -> Data {
        guard (file != nil) != (mouse != nil) else { throw ClipError.invalid("잘못된 공유 메시지예요.") }
        try file?.validate(); try mouse?.validate()
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
    func validate() throws {
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

