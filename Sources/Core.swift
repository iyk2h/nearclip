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
            throw ClipError.invalid(ui("Couldn’t create a pairing code."))
        }
        return format(bytes.map { String(format: "%02X", $0) }.joined())
    }
    static func normalize(_ code: String) throws -> String {
        let clean = code.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard clean.count == 32, clean.allSatisfy({ "0123456789ABCDEF".contains($0) }) else {
            throw ClipError.invalid(ui("Enter all 32 characters of the pairing code. Hyphens are optional."))
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
    private static func run(_ operation: String, input: Data? = nil) throws -> (Int32, Data) {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NearClipKeyStore")
        var own: SecCode?, ownStatic: SecStaticCode?, ownRequirement: SecRequirement?, requirementText: CFString?
        var helper: SecStaticCode?, required: SecRequirement?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
              SecCodeCopyStaticCode(own, [], &ownStatic) == errSecSuccess, let ownStatic,
              SecCodeCopyDesignatedRequirement(ownStatic, [], &ownRequirement) == errSecSuccess, let ownRequirement,
              SecRequirementCopyString(ownRequirement, [], &requirementText) == errSecSuccess, let requirementText else {
            throw ClipError.invalid(ui("Couldn’t verify the app signature."))
        }
        let text = requirementText as String
        guard text.contains("identifier \"dev.nearclip.mac\""), text.contains("certificate"), !text.contains("cdhash") else {
            throw ClipError.invalid(ui("Saving a pairing requires a stable signing identity."))
        }
        let helperRequirement = text.replacingOccurrences(of: "identifier \"dev.nearclip.mac\"", with: "identifier \"dev.nearclip.keystore\"")
        guard SecRequirementCreateWithString(helperRequirement as CFString, [], &required) == errSecSuccess,
              SecStaticCodeCreateWithPath(url as CFURL, [], &helper) == errSecSuccess, let helper,
              SecStaticCodeCheckValidity(helper, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), required) == errSecSuccess else {
            throw ClipError.invalid(ui("Couldn’t verify the keychain helper. Reinstall NearClip."))
        }
        let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = url; process.arguments = [operation]
        process.environment = [:]
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
    static func checkWithoutPrompt() -> Bool {
        guard let (status, _) = try? run("check") else { return false }
        return status == 0
    }
    static func load() throws -> String? {
        let (status, data) = try run("load")
        if status == 2 { return nil }
        guard status == 0, data.count == 32, let code = String(data: data, encoding: .utf8) else {
            throw ClipError.invalid(ui("Couldn’t read the pairing from Keychain. Error %1$@", "\(status)"))
        }
        return PairCode.format(try PairCode.normalize(code))
    }
    static func save(_ code: String) throws {
        let (status, _) = try run("save", input: Data(try PairCode.normalize(code).utf8))
        guard status == 0 else { throw ClipError.invalid(ui("Couldn’t save the pairing. Error %1$@", "\(status)")) }
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
    var label: String { type == "public.png" ? ui("image") : ui("text") }
    func validate() throws {
        guard data.count <= Self.maxBytes, !data.isEmpty else { throw ClipError.invalid(ui("Clipboard items can be up to 20 MiB.")) }
        guard type == "public.png" || type == "public.utf8-plain-text" else { throw ClipError.invalid(ui("This clipboard format isn’t supported.")) }
        if type == "public.utf8-plain-text", String(data: data, encoding: .utf8) == nil {
            throw ClipError.invalid(ui("Couldn’t read the text."))
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
            throw ClipError.invalid(ui("Invalid connection format."))
        }
    }
}

struct Envelope: Codable {
    let sequence: UInt64
    let kind: String // ready, clip, ping
    let clip: ClipMessage?
    let clock: UInt64?
    var features: [String]? = nil
    var osMajor: Int? = nil
    var app: AppVersion? = nil
    var data: Data? = nil
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
        guard local.device != remote.device else { throw ClipError.invalid(ui("Choose a different device to connect.")) }
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
    func seal(kind: String, clip: ClipMessage? = nil, clock: UInt64? = nil, features: [String]? = nil, data: Data? = nil, app: AppVersion? = nil) throws -> Data {
        let envelope = Envelope(sequence: sendSequence + 1, kind: kind, clip: clip, clock: clock, features: features, osMajor: kind == "ready" ? DockSwipeAdapter.systemMajor : nil, app: app, data: data)
        let data = try encrypt(envelope)
        sendSequence += 1
        return data
    }
    // PeerLink serializes outbound frames. Consume this sequence only at socket submission.
    func prepareClipboard(_ clip: ClipMessage) throws -> Data {
        try encrypt(Envelope(sequence: sendSequence + 1, kind: "clip", clip: clip, clock: nil))
    }
    func commitClipboard() { sendSequence += 1 }
    private func encrypt(_ envelope: Envelope) throws -> Data {
        let plain = try JSONEncoder().encode(envelope)
        guard let sealed = try AES.GCM.seal(plain, using: outgoing).combined else { throw ClipError.invalid(ui("Encryption failed.")) }
        return sealed
    }
    func open(_ data: Data) throws -> Envelope {
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: incoming)
        let envelope = try JSONDecoder().decode(Envelope.self, from: plain)
        guard envelope.sequence == receiveSequence + 1 else { throw ClipError.invalid(ui("Duplicate or out-of-order message.")) }
        receiveSequence = envelope.sequence
        return envelope
    }
}

enum Framing {
    static let maxFrame = 29 * 1024 * 1024
    static func encode(_ body: Data) throws -> Data {
        guard !body.isEmpty, body.count <= maxFrame else { throw ClipError.invalid(ui("Transfer exceeds the size limit.")) }
        var length = UInt32(body.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(body)
        return frame
    }
    static func length(_ header: Data, limit: Int = maxFrame) throws -> Int {
        guard header.count == 4 else { throw ClipError.invalid(ui("Invalid transfer header.")) }
        let n = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard n > 0, n <= limit else { throw ClipError.invalid(ui("Transfer exceeds the size limit.")) }
        return Int(n)
    }
}

// Input frames have a much smaller limit than clipboard frames. One receive
// callback can hold several frames, but never an unbounded peer-supplied buffer.
struct InputFrameBuffer {
    static let frameLimit = 4096
    static let chunkLimit = 64 * 1024
    private var bytes = Data()
    var pendingBytes: Int { bytes.count }
    mutating func append(_ chunk: Data) throws -> [Data] {
        guard chunk.count <= Self.chunkLimit else { throw ClipError.invalid(ui("Input packet exceeds the size limit.")) }
        bytes.append(chunk)
        var offset = 0
        var frames: [Data] = []
        while bytes.count - offset >= 4 {
            let size = try Framing.length(bytes.subdata(in: offset..<(offset + 4)), limit: Self.frameLimit)
            guard bytes.count - offset - 4 >= size else { break }
            frames.append(bytes.subdata(in: (offset + 4)..<(offset + 4 + size)))
            offset += 4 + size
        }
        if offset > 0 { bytes = Data(bytes.dropFirst(offset)) }
        return frames
    }
}
