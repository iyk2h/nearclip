import Foundation
import Network
import CryptoKit
import os

struct PairingReveal: Codable {
    let hello: Hello
    let publicKey: Data
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
    func commitment() throws -> Data { Data(SHA256.hash(data: try encoded())) }
}

// Commit both ephemeral keys and nonces before revealing either. This prevents
// adapting a key to the other side's revealed key while searching for a matching SAS.
final class PairingAgreement {
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    let local: PairingReveal
    init(device: String, name: String, syncPort: UInt16? = nil) {
        local = PairingReveal(hello: Hello.make(device: device, name: name, syncPort: syncPort), publicKey: privateKey.publicKey.rawRepresentation)
    }
    func finish(remote: PairingReveal, commitment: Data) throws -> (code: String, digits: String, cipher: SessionCipher) {
        try remote.hello.validate()
        guard remote.hello.device != local.hello.device, remote.publicKey.count == 32,
              commitment.count == 32, try remote.commitment() == commitment else {
            throw ClipError.invalid("연결 확인에 실패했어요. 다시 시도해 주세요.")
        }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: remote.publicKey))
        var transcript = Data("NearClip numeric pairing v1".utf8)
        for reveal in [local, remote].sorted(by: { $0.hello.device < $1.hello.device }) { transcript.append(try reveal.encoded()) }
        let salt = Data(SHA256.hash(data: transcript))
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
            sharedInfo: Data("persistent pairing secret".utf8), outputByteCount: 16)
        let code = PairCode.format(key.withUnsafeBytes { Data($0) }.map { String(format: "%02X", $0) }.joined())
        let sas = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
            sharedInfo: Data("human comparison only".utf8), outputByteCount: 4)
        let number = sas.withUnsafeBytes { Data($0) }.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        let digits = String(format: "%06u", number)
        let cipher = try SessionCipher(secret: PairCode.key(code), local: local.hello, remote: remote.hello)
        return (code, digits, cipher)
    }
}

private struct PairingCommit: Codable { let version: Int; let hash: Data }

final class PairingLink {
    let connection: NWConnection
    let agreement: PairingAgreement
    let expected: String?
    private var remoteCommitment: Data?
    private var remote: PairingReveal?
    private var cipher: SessionCipher?
    private var code: String?
    private var localConfirmed = false
    private var confirmationSent = false
    private var remoteConfirmed = false
    private var finished = false
    private var closed = false
    private var deadline: Timer?
    var onVerify: ((String, String, @escaping (Bool) -> Void) -> Void)?
    var onPaired: ((String, String) -> Void)?
    var onClose: ((Bool) -> Void)?
    var onRoute: ((DirectPeer) -> Void)?

    init(connection: NWConnection, device: String, name: String, expected: String? = nil, syncPort: UInt16? = nil) {
        self.connection = connection; self.expected = expected
        agreement = PairingAgreement(device: device, name: name, syncPort: syncPort)
    }
    func start() {
        let deadline = Timer(timeInterval: 120, repeats: false) { [weak self] _ in self?.close() }
        self.deadline = deadline; RunLoop.main.add(deadline, forMode: .common)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                do {
                    try self.send(JSONEncoder().encode(PairingCommit(version: 1, hash: self.agreement.local.commitment())))
                    self.readFrame()
                } catch { self.close() }
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        connection.start(queue: .main)
    }
    func close() {
        guard !closed else { return }; closed = true
        deadline?.invalidate(); deadline = nil
        connection.stateUpdateHandler = nil; connection.cancel()
        onClose?(finished); onClose = nil; onVerify = nil; onPaired = nil
    }
    private func send(_ body: Data, completion: (() -> Void)? = nil) throws {
        guard body.count <= 4096 else { throw ClipError.invalid("연결 메시지가 너무 커요.") }
        connection.send(content: try Framing.encode(body), completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            if error != nil { self.close() } else { completion?() }
        })
    }
    private func read(_ size: Int, partial: Data = Data(), done: @escaping (Data) -> Void) {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: size - partial.count, maximumLength: size - partial.count) { [weak self] bytes, _, complete, error in
            guard let self, !self.closed else { return }
            var all = partial; if let bytes { all.append(bytes) }
            if all.count == size { done(all) }
            else if complete || error != nil { self.close() }
            else { self.read(size, partial: all, done: done) }
        }
    }
    private func readFrame() {
        read(4) { [weak self] header in
            guard let self else { return }
            do {
                let n = try Framing.length(header, limit: 4096)
                self.read(n) { [weak self] body in
                    guard let self else { return }
                    do { try self.handle(body); self.readFrame() } catch { self.close() }
                }
            } catch { self.close() }
        }
    }
    private func handle(_ body: Data) throws {
        if remoteCommitment == nil {
            let commit = try JSONDecoder().decode(PairingCommit.self, from: body)
            guard commit.version == 1, commit.hash.count == 32 else { throw ClipError.invalid("지원하지 않는 연결 방식이에요.") }
            remoteCommitment = commit.hash
            try send(agreement.local.encoded()); return
        }
        if remote == nil {
            let reveal = try JSONDecoder().decode(PairingReveal.self, from: body)
            if let expected, reveal.hello.device != expected { throw ClipError.invalid("선택한 Mac과 달라요.") }
            let result = try agreement.finish(remote: reveal, commitment: remoteCommitment!)
            remote = reveal; code = result.code; cipher = result.cipher
            onVerify?(reveal.hello.name, result.digits, { [weak self] accepted in self?.confirm(accepted) })
            return
        }
        guard let cipher, !remoteConfirmed else { throw ClipError.invalid("잘못된 연결 확인이에요.") }
        let message = try cipher.open(body)
        guard message.kind == "pair-confirm", message.clip == nil else { throw ClipError.invalid("잘못된 연결 확인이에요.") }
        remoteConfirmed = true; completeIfConfirmed()
    }
    private func confirm(_ accepted: Bool) {
        guard !closed, !finished, !localConfirmed, let cipher else { return }
        guard accepted else { close(); return }
        localConfirmed = true
        do {
            try send(cipher.seal(kind: "pair-confirm")) { [weak self] in
                self?.confirmationSent = true; self?.completeIfConfirmed()
            }
        } catch { close() }
    }
    private func completeIfConfirmed() {
        guard !closed, !finished, localConfirmed, confirmationSent, remoteConfirmed, let code, let remote else { return }
        finished = true
        if let port = remote.hello.syncPort, port > 0,
           case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint {
            onRoute?(DirectPeer(host: String(describing: host), port: port, device: remote.hello.device))
        }
        onPaired?(code, remote.hello.name)
        // Keep the stream alive long enough for the peer to consume our confirmation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.close() }
    }
}

struct NearbyMac { let device: String; let name: String; let endpoint: NWEndpoint }

final class NearbyPairing {
    private let logger = Logger(subsystem: "dev.nearclip.mac", category: "pairing")
    static let serviceType = LocalTransport.serviceType
    let device: String
    let name: String
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var timer: Timer?
    private var active: PairingLink?
    private var running = false
    private var lastIncoming = Date.distantPast
    private(set) var candidates: [NearbyMac] = []
    var onCandidates: (([NearbyMac]) -> Void)?
    var onVerify: ((String, String, @escaping (Bool) -> Void) -> Void)?
    var onPaired: ((String, String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onEnded: (() -> Void)?
    var busy: Bool { active != nil }
    var syncPort: UInt16?
    var invitationDeadline: Date?
    private var accepting: Bool { running && (invitationDeadline.map { Date() < $0 } ?? true) }
    var onListening: ((UInt16) -> Void)?
    var onRoute: ((DirectPeer) -> Void)?
    private let discovery: Bool
    init(device: String, name: String, discovery: Bool = true) { self.device = device; self.name = name; self.discovery = discovery }
    func start() {
        guard !running else { return }; running = true; openServices()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.openServices() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func stop() {
        endDiscovery()
        active?.close(); active = nil
    }
    // Close the unauthenticated entry point while allowing an approved handshake to drain.
    func endDiscovery() {
        running = false; timer?.invalidate(); timer = nil
        listener?.stateUpdateHandler = nil; listener?.cancel(); listener = nil
        browser?.stateUpdateHandler = nil; browser?.cancel(); browser = nil
        candidates = []; onCandidates?([])
    }
    private func openServices() {
        guard running else { return }
        if listener == nil {
            do {
                let server = try NWListener(using: LocalTransport.parameters()); listener = server
                var shortName = ""
                for c in name { if (shortName + String(c)).utf8.count > 20 { break }; shortName.append(c) }
                if discovery { server.service = NWListener.Service(name: "pair-" + shortName + "#" + device, type: Self.serviceType) }
                server.newConnectionHandler = { [weak self] connection in
                    guard let self, self.accepting, self.active == nil, Date().timeIntervalSince(self.lastIncoming) > 8 else { connection.cancel(); return }
                    self.lastIncoming = Date(); self.attach(connection)
                }
                server.stateUpdateHandler = { [weak self, weak server] state in
                    guard let self, let server, self.listener === server, self.running else { return }
                    if case .ready = state, let port = server.port { self.onListening?(port.rawValue) }
                    if case .failed(let error) = state {
                        self.logger.error("Pairing listener failed: \(String(describing: error), privacy: .public)")
                        self.onStatus?(Self.failureMessage(error)); server.cancel(); self.listener = nil
                    }
                }
                server.start(queue: .main)
            } catch { onStatus?("주변 Mac을 찾을 수 없어요. 네트워크 권한을 확인해 주세요.") }
        }
        if discovery && browser == nil {
            let finder = NWBrowser(for: .bonjour(type: Self.serviceType, domain: "local."), using: LocalTransport.parameters())
            browser = finder
            finder.browseResultsChangedHandler = { [weak self, weak finder] results, _ in
                guard let self, let finder, self.browser === finder, self.running else { return }
                var found: [String: NearbyMac] = [:]
                for result in results {
                    guard case .service(let service, _, _, _) = result.endpoint, service.hasPrefix("pair-"), service.count > 42 else { continue }
                    let device = String(service.suffix(36))
                    guard UUID(uuidString: device) != nil, device != self.device else { continue }
                    found[device] = NearbyMac(device: device, name: String(service.dropFirst(5).dropLast(37)), endpoint: result.endpoint)
                }
                self.candidates = found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                self.logger.info("Nearby Mac count: \(self.candidates.count, privacy: .public)")
                self.onCandidates?(self.candidates)
            }
            finder.stateUpdateHandler = { [weak self, weak finder] state in
                guard let self, let finder, self.browser === finder else { return }
                switch state {
                case .failed(let error):
                    self.logger.error("Pairing browser failed: \(String(describing: error), privacy: .public)")
                    self.onStatus?(Self.failureMessage(error)); finder.cancel(); self.browser = nil
                case .waiting: self.onStatus?("주변 Mac을 찾으려면 로컬 네트워크 접근을 허용해 주세요.")
                default: break
                }
            }
            finder.start(queue: .main)
        }
    }
    static func failureMessage(_ error: NWError) -> String {
        if case .dns(let code) = error, code == -65555 {
            return "주변 검색 권한이 없어요. 시스템 설정에서 로컬 네트워크를 허용한 뒤 다시 찾아주세요."
        }
        return "주변 Mac 검색에 실패했어요. 로컬 네트워크 권한을 확인한 뒤 ‘다시 찾기’를 눌러주세요. (\(error))"
    }
    func connect(device: String) {
        guard accepting, active == nil, let candidate = candidates.first(where: { $0.device == device }) else { return }
        attach(NWConnection(to: candidate.endpoint, using: LocalTransport.parameters()), expected: device)
    }
    func connectDirect(host: String, port: UInt16, expected: String? = nil) {
        guard accepting, active == nil, let port = NWEndpoint.Port(rawValue: port), !host.isEmpty else { return }
        attach(NWConnection(host: NWEndpoint.Host(host), port: port, using: LocalTransport.parameters()), expected: expected)
    }
    func cancel() { active?.close() }
    private func attach(_ connection: NWConnection, expected: String? = nil) {
        let link = PairingLink(connection: connection, device: device, name: name, expected: expected, syncPort: syncPort)
        link.onRoute = { [weak self] in self?.onRoute?($0) }
        active = link; onStatus?("양쪽 Mac에서 확인할 숫자를 준비하고 있어요.")
        link.onVerify = { [weak self] name, digits, reply in self?.onVerify?(name, digits, reply) }
        link.onPaired = { [weak self] code, name in self?.onPaired?(code, name) }
        link.onClose = { [weak self, weak link] succeeded in
            guard let self, self.active === link else { return }
            self.active = nil; self.onEnded?()
            if !succeeded { self.onStatus?("연결이 취소됐어요. 두 Mac에서 다시 시도해 주세요.") }
        }
        link.start()
    }
}
