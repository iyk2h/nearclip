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
