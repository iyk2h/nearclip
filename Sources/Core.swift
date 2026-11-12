import Foundation
import CryptoKit
import Security

enum ClipError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

enum PairCode {
    static func create() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ClipError.invalid("연결 코드를 만들 수 없어요.")
        }
        return format(bytes.map { String(format: "%02X", $0) }.joined())
    }
    static func normalize(_ code: String) throws -> String {
        let clean = code.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard clean.count == 32, clean.allSatisfy({ "0123456789ABCDEF".contains($0) }) else {
            throw ClipError.invalid("32자리 연결 코드를 모두 입력해 주세요. 하이픈은 생략해도 돼요.")
        }
        return clean
    }
    static func format(_ clean: String) -> String {
        stride(from: 0, to: clean.count, by: 4).map { n in
            let a = clean.index(clean.startIndex, offsetBy: n)
            let b = clean.index(a, offsetBy: min(4, clean.count - n))
            return String(clean[a..<b])
        }.joined(separator: "-")
    }
    static func key(_ code: String) throws -> SymmetricKey {
        let clean = try normalize(code)
        return SymmetricKey(data: SHA256.hash(data: Data(("NearClip pairing v1:" + clean).utf8)))
    }
    // A discovery hint, not the secret. A 128-bit random code makes guessing impractical.
    static func group(_ code: String) throws -> String {
        let normalized = try normalize(code)
        return SHA256.hash(data: Data(("NearClip discovery v1:" + normalized).utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

enum KeyStore {
    private static let service = "local.nearclip.pairing.v1"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "pairing-code"]
    }
    static func load() throws -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data, let code = String(data: data, encoding: .utf8) else {
            throw ClipError.invalid("키체인에서 연결 코드를 읽을 수 없어요. 오류 \(status)")
        }
        return PairCode.format(try PairCode.normalize(code))
    }
    static func save(_ code: String) throws {
        let data = Data(try PairCode.normalize(code).utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw ClipError.invalid("연결 코드를 저장할 수 없어요. 오류 \(added)") }
        } else if status != errSecSuccess {
            throw ClipError.invalid("연결 코드를 저장할 수 없어요. 오류 \(status)")
        }
    }
}

struct ClipStamp: Codable, Comparable, Equatable {
    let counter: UInt64
    let device: String
    static func < (a: Self, b: Self) -> Bool {
        a.counter == b.counter ? a.device < b.device : a.counter < b.counter
    }
}

struct ClipPayload: Codable, Equatable {
    static let maxBytes = 20 * 1024 * 1024
    let type: String // public.utf8-plain-text or public.png
    let data: Data
    var label: String { type == "public.png" ? "이미지" : "텍스트" }
    func validate() throws {
        guard data.count <= Self.maxBytes, !data.isEmpty else { throw ClipError.invalid("한 번에 20MB까지 공유할 수 있어요.") }
        guard type == "public.png" || type == "public.utf8-plain-text" else { throw ClipError.invalid("지원하지 않는 클립보드 형식이에요.") }
        if type == "public.utf8-plain-text", String(data: data, encoding: .utf8) == nil {
            throw ClipError.invalid("텍스트를 읽을 수 없어요.")
        }
    }
}

struct ClipMessage: Codable {
    let id: UUID
    let stamp: ClipStamp
    let payload: ClipPayload
}

struct Hello: Codable {
    let version: Int
    let device: String
    let name: String
    let nonce: Data
    var syncPort: UInt16? = nil
    static func make(device: String, name: String, syncPort: UInt16? = nil) -> Hello {
        let nonce = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return Hello(version: 1, device: device, name: String(name.prefix(80)), nonce: nonce, syncPort: syncPort)
    }
    func validate() throws {
        guard version == 1, UUID(uuidString: device) != nil, !name.isEmpty, name.utf8.count <= 320, nonce.count == 32 else {
            throw ClipError.invalid("연결 형식이 올바르지 않아요.")
        }
    }
}

struct Envelope: Codable {
    let sequence: UInt64
    let kind: String // ready, clip, ping
    let clip: ClipMessage?
    let clock: UInt64?
}

// Fresh nonces bind every connection to a new key. Directional keys and monotonic
// encrypted sequence numbers prevent reflection and replay, including across reconnects.
final class SessionCipher {
    private let outgoing: SymmetricKey
    private let incoming: SymmetricKey
    private var sendSequence: UInt64 = 0
    private var receiveSequence: UInt64 = 0
    init(secret: SymmetricKey, local: Hello, remote: Hello) throws {
        try local.validate(); try remote.validate()
        guard local.device != remote.device else { throw ClipError.invalid("같은 기기에는 연결하지 않아요.") }
        let pair = [local, remote].sorted { $0.device < $1.device }
        var transcript = Data("NearClip session v1".utf8)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for h in pair { transcript.append(try encoder.encode(h)) }
        let salt = Data(SHA256.hash(data: transcript))
        outgoing = HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, salt: salt,
            info: Data(("NearClip sender:" + local.device).utf8), outputByteCount: 32)
        incoming = HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, salt: salt,
            info: Data(("NearClip sender:" + remote.device).utf8), outputByteCount: 32)
    }
    func seal(kind: String, clip: ClipMessage? = nil, clock: UInt64? = nil) throws -> Data {
        sendSequence += 1
        let plain = try JSONEncoder().encode(Envelope(sequence: sendSequence, kind: kind, clip: clip, clock: clock))
        guard let sealed = try AES.GCM.seal(plain, using: outgoing).combined else { throw ClipError.invalid("암호화하지 못했어요.") }
        return sealed
    }
    func open(_ data: Data) throws -> Envelope {
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: incoming)
        let envelope = try JSONDecoder().decode(Envelope.self, from: plain)
        guard envelope.sequence == receiveSequence + 1 else { throw ClipError.invalid("중복되거나 순서가 잘못된 메시지예요.") }
        receiveSequence = envelope.sequence
        return envelope
    }
}

enum Framing {
    static let maxFrame = 29 * 1024 * 1024
    static func encode(_ body: Data) throws -> Data {
        guard !body.isEmpty, body.count <= maxFrame else { throw ClipError.invalid("전송 크기를 초과했어요.") }
        var length = UInt32(body.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(body)
        return frame
    }
    static func length(_ header: Data, limit: Int = maxFrame) throws -> Int {
        guard header.count == 4 else { throw ClipError.invalid("전송 헤더가 잘못됐어요.") }
        let n = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard n > 0, n <= limit else { throw ClipError.invalid("전송 크기를 초과했어요.") }
        return Int(n)
    }
}
