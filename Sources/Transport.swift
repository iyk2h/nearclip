import Foundation
import Network
import CryptoKit

final class PeerLink {
    let id = UUID()
    let connection: NWConnection
    let local: Hello
    let secret: SymmetricKey
    let endpointKey: String?
    let expectedDevice: String?
    private(set) var remote: Hello?
    private(set) var authenticated = false
    private(set) var closed = false
    private var cipher: SessionCipher?
    private let advertisedFeatures: [String]
    private var sending = false
    private var featureQueue: [(Data, (Bool) -> Void)] = []
    private(set) var features: Set<String> = []
    var onFeature: ((PeerLink, FeaturePacket) -> Void)?
    private var pendingClip: ClipMessage?
    private var lastReceived = Date()
    private let created = Date()
    var onReady: ((PeerLink) -> Void)?
    var onClip: ((PeerLink, ClipMessage) -> Void)?
    var onClose: ((PeerLink) -> Void)?
    var clockProvider: (() -> UInt64)?
    var onClock: ((UInt64) -> Void)?

    init(connection: NWConnection, secret: SymmetricKey, device: String, name: String,
         endpointKey: String? = nil, expectedDevice: String? = nil, advertisedFeatures: [String] = SharingFeature.supported) {
        self.advertisedFeatures = advertisedFeatures
        self.connection = connection; self.secret = secret
        self.local = Hello.make(device: device, name: name)
        self.endpointKey = endpointKey; self.expectedDevice = expectedDevice
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                do { try self.sendFrame(JSONEncoder().encode(self.local)); self.readFrame() }
                catch { self.close() }
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        connection.start(queue: .main)
    }
    func close() {
        guard !closed else { return }
        closed = true; authenticated = false; pendingClip = nil
        let queued = featureQueue; featureQueue = []
        queued.forEach { $0.1(false) }
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(self)
        onReady = nil; onClip = nil; onClose = nil
    }
    private func sendFrame(_ body: Data, completion: (() -> Void)? = nil) throws {
        let data = try Framing.encode(body)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            if error != nil { self.close() } else { completion?() }
        })
    }
    private func readExactly(_ size: Int, partial: Data = Data(), completion: @escaping (Data) -> Void) {
        guard !closed else { return }
        let remaining = size - partial.count
        connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            var all = partial
            if let data { all.append(data) }
            if all.count == size { completion(all) }
            else if error != nil || complete { self.close() }
            else { self.readExactly(size, partial: all, completion: completion) }
        }
    }
    private func readFrame() {
        readExactly(4) { [weak self] header in
            guard let self else { return }
            do {
                let count = try Framing.length(header, limit: self.authenticated ? Framing.maxFrame : 4096)
                self.readExactly(count) { [weak self] body in
                    guard let self else { return }
                    do { try self.handle(body); self.lastReceived = Date(); self.readFrame() }
                    catch { self.close() }
                }
            } catch { self.close() }
        }
    }
    private func handle(_ data: Data) throws {
        if remote == nil {
            let hello = try JSONDecoder().decode(Hello.self, from: data)
            try hello.validate()
            if let expectedDevice, hello.device != expectedDevice { throw ClipError.invalid("기기가 일치하지 않아요.") }
            remote = hello
            let cipher = try SessionCipher(secret: secret, local: local, remote: hello)
            self.cipher = cipher
            try sendFrame(cipher.seal(kind: "ready", clock: clockProvider?() ?? 0, features: advertisedFeatures))
            return
        }
        guard let cipher else { throw ClipError.invalid("연결을 확인할 수 없어요.") }
        let message = try cipher.open(data)
        if !authenticated {
            guard message.kind == "ready", message.clip == nil else { throw ClipError.invalid("연결 인증에 실패했어요.") }
            if let clock = message.clock { onClock?(clock) }
            features = Set((message.features ?? []).prefix(8)).intersection(advertisedFeatures)
            authenticated = true; onReady?(self)
            return
        }
        switch message.kind {
        case "clip":
            guard let clip = message.clip, clip.stamp.device == remote?.device else { throw ClipError.invalid("보낸 기기를 확인할 수 없어요.") }
            try clip.payload.validate()
            onClip?(self, clip)
        case "feature":
            guard let data = message.data else { throw ClipError.invalid("공유 데이터가 없어요.") }
            let packet = try FeaturePacket.decode(data)
            guard features.contains(packet.feature) else { throw ClipError.invalid("지원하지 않는 공유 기능이에요.") }
            onFeature?(self, packet)
        case "ping": break
        default: throw ClipError.invalid("지원하지 않는 메시지예요.")
        }
    }
    func send(_ message: ClipMessage) {
        guard authenticated, !closed else { return }
        pendingClip = message
        flush()
    }
    func sendFeature(_ packet: FeaturePacket, completion: @escaping (Bool) -> Void) {
        guard authenticated, !closed, features.contains(packet.feature), featureQueue.count < 32,
              let data = try? packet.encoded() else { completion(false); return }
        featureQueue.append((data, completion)); flush()
    }
    private func flush() {
        guard !sending, !closed, authenticated, let cipher else { return }
        if !featureQueue.isEmpty {
            let (data, reply) = featureQueue.removeFirst(); sending = true
            do {
                let frame = try Framing.encode(cipher.seal(kind: "feature", data: data))
                connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                    guard let self else { reply(false); return }
                    self.sending = false; reply(error == nil && !self.closed)
                    if error != nil { self.close() } else { self.flush() }
                })
            } catch { sending = false; reply(false); close() }
            return
        }
        guard let clip = pendingClip else { return }
        pendingClip = nil; sending = true
        do {
            try sendFrame(cipher.seal(kind: "clip", clip: clip)) { [weak self] in
                guard let self else { return }
                self.sending = false; self.flush()
            }
        } catch { close() }
    }
    func tick() {
        guard !closed else { return }
        if (!authenticated && Date().timeIntervalSince(created) > 12) || Date().timeIntervalSince(lastReceived) > 90 {
            close(); return
        }
        guard authenticated, !sending, let cipher else { return }
        sending = true
        do {
            try sendFrame(cipher.seal(kind: "ping")) { [weak self] in
                guard let self else { return }; self.sending = false; self.flush()
            }
        } catch { close() }
    }
}

final class LocalTransport {
    static let serviceType = "_nearclip._tcp"
    let device: String
    let name: String
    private let code: String
    private let secret: SymmetricKey
    private let prefix: String
    private let discovery: Bool
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var links: [UUID: PeerLink] = [:]
    private var endpoints: [String: (NWEndpoint, String)] = [:]
    private var timer: Timer?
    private var running = false
    private var preferredPort: UInt16
    private var directPeer: DirectPeer?
    private var directAttempts = 0
    var onPeers: (([String]) -> Void)?
    var onPeerDetails: (([ConnectedPeer]) -> Void)?
    var onFeature: ((String, FeaturePacket) -> Void)?
    var onClip: ((ClipMessage) -> Void)?
    var onStatus: ((String) -> Void)?
    var onListening: ((NWEndpoint.Port) -> Void)?
    var clockProvider: (() -> UInt64)?
    var onClock: ((UInt64) -> Void)?
    var peerCount: Int { links.values.filter(\.authenticated).count }

    init(code: String, device: String, name: String, discovery: Bool = true, port: UInt16 = 0) throws {
        self.preferredPort = port
        self.code = code; self.device = device; self.name = name; self.discovery = discovery
        secret = try PairCode.key(code)
        prefix = "nc-" + (try PairCode.group(code)) + "-"
    }
    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        tcp.enableKeepalive = true; tcp.keepaliveIdle = 15; tcp.keepaliveInterval = 5; tcp.keepaliveCount = 3
        let p = NWParameters(tls: nil, tcp: tcp)
        p.includePeerToPeer = false
        return p
    }
    func start() {
        guard !running else { return }; running = true
        startListener()
        if discovery { startBrowser() }
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            guard let self else { return }
            for link in Array(self.links.values) { link.tick() }
            if self.listener == nil { self.startListener() }
            if self.discovery && self.browser == nil { self.startBrowser() }
            self.connectDiscovered(); self.connectDirectPeer()
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func stop() {
        running = false; timer?.invalidate(); timer = nil
        listener?.stateUpdateHandler = nil; listener?.cancel(); listener = nil
        browser?.stateUpdateHandler = nil; browser?.cancel(); browser = nil
        endpoints.removeAll()
        for link in Array(links.values) { link.close() }
        links.removeAll(); publishPeers()
    }
    private func startListener() {
        guard running, listener == nil else { return }
        do {
            let listener = try NWListener(using: Self.parameters(), on: NWEndpoint.Port(rawValue: preferredPort) ?? .any)
            self.listener = listener
            if discovery { listener.service = NWListener.Service(name: prefix + device, type: Self.serviceType) }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.listener === listener, self.running else { return }
                switch state {
                case .ready: if let port = listener.port { self.preferredPort = port.rawValue; self.onListening?(port) }
                case .waiting:
                    self.onStatus?("네트워크 연결과 로컬 네트워크 권한을 확인해 주세요.")
                case .failed(let error):
                    if case .posix(.EADDRINUSE) = error { self.preferredPort = 0 }
                    self.onStatus?("연결을 다시 시도하고 있어요. 로컬 네트워크 권한을 확인해 주세요.")
                    listener.cancel(); self.listener = nil
                default: break
                }
            }
            listener.start(queue: .main)
        } catch { onStatus?("네트워크를 열 수 없어요. 잠시 후 다시 시도할게요.") }
    }
    private func startBrowser() {
        guard running, browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: "local."), using: Self.parameters())
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser, self.browser === browser, self.running else { return }
            var found: [String: (NWEndpoint, String)] = [:]
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint, name.hasPrefix(self.prefix) {
                    let peer = String(name.dropFirst(self.prefix.count))
                    guard UUID(uuidString: peer) != nil, peer != self.device else { continue }
                    found[name] = (result.endpoint, peer)
                }
            }
            self.endpoints = found; self.connectDiscovered()
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, self.browser === browser, self.running else { return }
            switch state {
            case .waiting: self.onStatus?("로컬 네트워크 접근을 허용하면 다른 Mac을 찾을 수 있어요.")
            case .failed:
                self.onStatus?("다른 Mac을 다시 찾고 있어요. 네트워크 권한을 확인해 주세요.")
                browser.cancel(); self.browser = nil
            default: break
            }
        }
        browser.start(queue: .main)
    }
    private func connectDiscovered() {
        guard running else { return }
        for (key, (endpoint, peer)) in endpoints {
            // Only one side dials, so each pair has exactly one duplex connection.
            guard device < peer, !links.values.contains(where: { $0.endpointKey == key || $0.remote?.device == peer }), links.count < 8 else { continue }
            accept(NWConnection(to: endpoint, using: Self.parameters()), key: key, expected: peer)
        }
    }
    func setDirectPeer(_ peer: DirectPeer?) {
        directPeer = peer; directAttempts = 0; connectDirectPeer()
    }
    private func connectDirectPeer() {
        guard running, let peer = directPeer, peerCount == 0,
              !links.values.contains(where: { $0.expectedDevice == peer.device }), links.count < 8,
              let port = NWEndpoint.Port(rawValue: peer.port) else { return }
        // Give Bonjour a chance first, then let either side recover a broken connection.
        directAttempts += 1
        guard directAttempts >= 2 else { return }
        accept(NWConnection(host: .init(peer.host), port: port, using: Self.parameters()), expected: peer.device)
    }
    func connectLoopback(port: NWEndpoint.Port, expected: String) {
        accept(NWConnection(host: "127.0.0.1", port: port, using: Self.parameters()), expected: expected)
    }
    private func accept(_ connection: NWConnection, key: String? = nil, expected: String? = nil) {
        guard running, links.count < 8 else { connection.cancel(); return }
        let link = PeerLink(connection: connection, secret: secret, device: device, name: name,
                            endpointKey: key, expectedDevice: expected)
        links[link.id] = link
        link.clockProvider = { [weak self] in self?.clockProvider?() ?? 0 }
        link.onClock = { [weak self] in self?.onClock?($0) }
        link.onReady = { [weak self] link in
            guard let self else { return }
            if let existing = self.links.values.first(where: { $0.id != link.id && $0.authenticated && $0.remote?.device == link.remote?.device }) {
                // Both devices select the same physical connection when they dial at once.
                let preferOutgoing = self.device < (link.remote?.device ?? "")
                if (link.expectedDevice != nil) == preferOutgoing { existing.close() }
                else { link.close(); return }
            }
            self.publishPeers()
        }
        link.onFeature = { [weak self] link, packet in
            if let peer = link.remote?.device { self?.onFeature?(peer, packet) }
        }
        link.onClip = { [weak self] _, clip in self?.onClip?(clip) }
        link.onClose = { [weak self] link in self?.links.removeValue(forKey: link.id); self?.publishPeers() }
        link.start()
    }
    private func publishPeers() {
        let peers = links.values.filter(\.authenticated).compactMap { link -> ConnectedPeer? in
            guard let remote = link.remote else { return nil }
            return ConnectedPeer(device: remote.device, name: remote.name, connection: link.id, features: link.features)
        }
        onPeers?(peers.map(\.name).sorted()); onPeerDetails?(peers)
    }
    func sendFeature(_ packet: FeaturePacket, to peer: String, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let link = links.values.first(where: { $0.authenticated && $0.remote?.device == peer }) else { completion(false); return }
        link.sendFeature(packet, completion: completion)
    }
    func send(_ message: ClipMessage) { for link in links.values where link.authenticated { link.send(message) } }
}
