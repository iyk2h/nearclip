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
            throw ClipError.invalid(ui("Enter a hostname and port, such as my-mac.local:54321."))
        }
        var host = String(value[..<split])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty, host.utf8.count <= 253,
              !host.contains(where: { $0.isWhitespace }),
              !host.contains("/"), !host.contains("@"), !host.contains("[") , !host.contains("]") else {
            throw ClipError.invalid(ui("Enter an IP address or a .local hostname."))
        }
        self.host = host; self.port = port
    }
}

enum CloseBehavior: Int {
    case ask = 0, keepRunning = 1, quit = 2
}

// A remembered choice is bound to the authenticated device AND pairing key.
// A new pairing must never inherit an old input-sharing choice.
struct InputConsent: Codable, Equatable {
    let peer: String
    let group: String
    func peer(for pairingCode: String) -> String? {
        guard UUID(uuidString: peer) != nil, (try? PairCode.group(pairingCode)) == group else { return nil }
        return peer
    }
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
