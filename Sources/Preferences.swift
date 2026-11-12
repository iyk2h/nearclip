import Foundation

struct DirectPeer: Codable, Equatable {
    let host: String
    let port: UInt16
    let device: String
}

struct ConnectionAddress: Equatable {
    let host: String
    let port: UInt16
    init(_ input: String) throws {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let split = value.lastIndex(of: ":"), let port = UInt16(value[value.index(after: split)...]), port > 0 else {
            throw ClipError.invalid("주소:포트 형식으로 입력해 주세요. 예: my-mac.local:54321")
        }
        var host = String(value[..<split])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty, host.utf8.count <= 253,
              !host.contains(where: { $0.isWhitespace }),
              !host.contains("/"), !host.contains("@"), !host.contains("[") , !host.contains("]") else {
            throw ClipError.invalid("Mac의 IP 주소나 .local 주소를 입력해 주세요.")
        }
        self.host = host; self.port = port
    }
}

enum CloseBehavior: Int {
    case ask = 0, keepRunning = 1, quit = 2
}

// Discovery is open on first use. A trusted setup requires an explicit invitation.
// Re-authenticating an existing peer must not cancel an invitation the user opened.
struct PairingAccess {
    private(set) var hasTrustedPeer: Bool
    init(hasTrustedPeer: Bool) { self.hasTrustedPeer = hasTrustedPeer }
    private var invited = false
    var isOpen: Bool { !hasTrustedPeer || invited }
    mutating func open() { invited = true }
    mutating func close() { invited = false }
    mutating func didPair() { hasTrustedPeer = true; invited = false }
    mutating func didAuthenticate() { hasTrustedPeer = true }
}
