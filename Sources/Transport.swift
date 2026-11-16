import Foundation
import Network
import CryptoKit
import OSLog

enum NetworkNotice: Equatable {
    case localNetworkDenied, unavailable, recovering, waitingForPeer
    static func classify(_ error: NWError) -> Self {
        // Bonjour PolicyDenied is the explicit privacy denial (TN3179).
        if case .dns(-65570) = error { return .localNetworkDenied }
        if case .posix(let code) = error, code == .ENETDOWN || code == .ENETUNREACH { return .unavailable }
        return .recovering
    }
    var message: String {
        switch self {
        case .localNetworkDenied: return "로컬 네트워크 접근이 차단됐어요. 시스템 설정 → 개인정보 보호 및 보안 → 로컬 네트워크에서 NearClip을 허용해 주세요."
        case .unavailable: return "네트워크 연결을 기다리고 있어요. Wi-Fi 또는 LAN이 돌아오면 자동으로 다시 연결해요."
        case .recovering: return "연결을 다시 시도하고 있어요. 두 Mac의 네트워크 연결을 확인해 주세요."
        case .waitingForPeer: return "상대 Mac 연결을 기다리고 있어요. 같은 네트워크에서 상대 NearClip이 실행 중인지 확인해 주세요."
        }
    }
}

final class PeerLink {
    enum CloseReason: String { case stopped, networkFailure, invalidFrame, peerClosed, handshakeTimeout, idleTimeout, duplicate }
    private let logger = Logger(subsystem: "dev.nearclip.mac", category: "transport")
    private let createdAt = ProcessInfo.processInfo.systemUptime
    var connectingFor: TimeInterval { ProcessInfo.processInfo.systemUptime - createdAt }
    private var peakQueueDepth = 0
    private var maxQueueWaitMS = 0.0
    private var lastSlowQueueLog = -Double.infinity
    private let clipboardEncodingQueue = DispatchQueue(label: "dev.nearclip.clipboard-encoding", qos: .userInitiated)
    private let decodingQueue = DispatchQueue(label: "dev.nearclip.frame-decoding", qos: .userInitiated)
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
    private let inputOnly: Bool
    private var inputListener: NWListener?
    private(set) var inputLink: PeerLink?
    private var pendingInputConnection: NWConnection?
    private var inputPort: UInt16?
    private var remoteInputPort: UInt16?
    private var retryInputWork: DispatchWorkItem?
    private var inputRetry = 0
    private var metricsTimer: Timer?
    private var measurements = InputMeasurements()
    private var lastMetricsLog = -Double.infinity
    private(set) var appVersion: AppVersion?
    var onNetworkError: ((NWError) -> Void)?
    var onInputChange: ((PeerLink) -> Void)?
    var onMetrics: ((PeerLink, InputHealth) -> Void)?
    var canRecoverInput: Bool { features.contains(SharingFeature.inputRecovery) }
    var inputReady: Bool { features.contains(SharingFeature.inputChannel) ? hasSeparateInput : ready }
    private(set) var ready = false
    var hasSeparateInput: Bool { ready && inputLink?.ready == true }
    private struct InputOffer: Codable { let port: UInt16 }

    // A new key for each parent handshake, distinct from clipboard keys and
    // bound to both authenticated identities/nonces. Never sent on the wire.
    static func inputKey(secret: SymmetricKey, local: Hello, remote: Hello) throws -> SymmetricKey {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let transcript = try encoder.encode([local, remote].sorted { $0.device < $1.device })
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, salt: transcript,
            info: Data("NearClip authenticated input channel v1".utf8), outputByteCount: 32)
    }
    private let advertisedFeatures: [String]
    private var sending = false
    private var featureQueue: [(String, Data, (Bool) -> Void, TimeInterval)] = []
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
         endpointKey: String? = nil, expectedDevice: String? = nil, advertisedFeatures: [String] = SharingFeature.supported, inputOnly: Bool = false) {
        self.inputOnly = inputOnly
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
                self.beginHandshake()
            case .waiting(let error):
                self.onNetworkError?(error)
                // Release held input promptly when an established route is lost.
                if self.ready { self.close(.networkFailure) }
            case .failed(let error): self.onNetworkError?(error); self.close(.networkFailure)
            case .cancelled: self.close(.networkFailure)
            default: break
            }
        }
        connection.start(queue: .main)
    }
    private func beginHandshake() {
        guard !inputOnly, advertisedFeatures.contains(SharingFeature.inputChannel) else { sendHello(); return }
        do {
            let listener = try NWListener(using: LocalTransport.parameters())
            inputListener = listener
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.closed, self.inputLink == nil, self.pendingInputConnection == nil else { connection.cancel(); return }
                // The independent socket can arrive before its parent's ready
                // frame. Hold one candidate until parent authentication finishes.
                if !self.authenticated { self.pendingInputConnection = connection; return }
                guard self.features.contains(SharingFeature.inputChannel),
                      self.local.device > (self.remote?.device ?? "") else { connection.cancel(); return }
                self.startInput(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, !self.closed else { return }
                switch state {
                case .ready:
                    guard let port = listener.port else { self.close(.networkFailure); return }
                    self.inputPort = port.rawValue; self.sendHello()
                case .failed: self.close(.networkFailure)
                default: break
                }
            }
            listener.start(queue: .main)
        } catch { close(.networkFailure) }
    }
    private func sendHello() {
        do { try sendFrame(JSONEncoder().encode(local)); readFrame() }
        catch { close(.invalidFrame) }
    }
    private func startInput(_ connection: NWConnection) {
        guard let remote, inputLink == nil, !closed else { connection.cancel(); return }
        do {
            let key = try Self.inputKey(secret: secret, local: local, remote: remote)
            let child = PeerLink(connection: connection, secret: key, device: local.device, name: local.name,
                expectedDevice: remote.device, advertisedFeatures: [SharingFeature.mouse, SharingFeature.keyboard] + (features.contains(SharingFeature.gestures) ? [SharingFeature.gestures] : []) + (features.contains(SharingFeature.inputMetrics) ? [SharingFeature.inputMetrics] : []), inputOnly: true)
            inputLink = child
            child.onReady = { [weak self] _ in
                guard let self, !self.closed else { return }
                if !self.canRecoverInput || self.local.device < remote.device {
                    self.inputListener?.cancel(); self.inputListener = nil
                }
                self.retryInputWork?.cancel(); self.retryInputWork = nil; self.inputRetry = 0
                let wasReady = self.ready; self.ready = true
                self.logger.notice("input_channel_ready elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime - self.createdAt) * 1000), privacy: .public)")
                if wasReady { self.onInputChange?(self) } else { self.onReady?(self) }
            }
            child.onFeature = { [weak self, weak child] _, packet in
                guard let self, self.inputLink === child, self.ready, !self.closed, self.features.contains(packet.feature) else { return }
                self.onFeature?(self, packet)
            }
            child.onMetrics = { [weak self, weak child] _, health in
                guard let self, self.inputLink === child, self.inputReady else { return }
                self.onMetrics?(self, health)
            }
            // Recovery is negotiated. Older split-channel peers retain the
            // build-16 whole-session teardown behavior.
            child.onClose = { [weak self] child in
                guard let self, !self.closed, self.inputLink === child else { return }
                self.inputLink = nil
                if self.canRecoverInput {
                    self.logger.notice("input_channel_lost bulk_preserved=true")
                    self.onInputChange?(self)
                    self.scheduleInputRetry()
                } else if self.ready || self.local.device < remote.device { self.close(.networkFailure) }
            }
            child.start()
        } catch { connection.cancel(); close(.invalidFrame) }
    }
    private func dialInput() {
        guard !closed, authenticated, inputLink == nil, local.device < (remote?.device ?? ""),
              let raw = remoteInputPort, let port = NWEndpoint.Port(rawValue: raw),
              case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint else { return }
        startInput(NWConnection(host: host, port: port, using: LocalTransport.parameters()))
    }
    func reconnectInputNow() {
        guard ready, canRecoverInput, !inputReady, !closed else { return }
        if let child = inputLink, case .waiting = child.connection.state { child.close(.networkFailure) }
        retryInputWork?.cancel(); retryInputWork = nil; inputRetry = 0
        dialInput()
    }
    private func scheduleInputRetry() {
        guard canRecoverInput, !closed, retryInputWork == nil, local.device < (remote?.device ?? "") else { return }
        let delay = min(8.0, 0.5 * pow(2, Double(min(inputRetry, 4))))
        inputRetry += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.closed else { return }
            self.retryInputWork = nil; self.dialInput()
        }
        retryInputWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private func startMetrics() {
        guard inputOnly, features.contains(SharingFeature.inputMetrics), metricsTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.probe() }
        metricsTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func probe() {
        guard ready, !closed else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if measurements.expired(now: now) { close(.idleTimeout); return }
        guard let id = measurements.begin(now: now) else { return }
        enqueue(kind: "probe", data: Data(id.uuidString.utf8)) { [weak self] sent in
            if !sent { self?.close(.networkFailure) }
        }
    }
    private func publishMeasurements() {
        guard let health = measurements.snapshot else { return }
        onMetrics?(self, health)
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMetricsLog >= 10 {
            lastMetricsLog = now
            logger.notice("input_latency samples=\(health.samples, privacy: .public) rtt_ms=\(Int(health.rttMS), privacy: .public) p95_ms=\(Int(health.p95MS), privacy: .public) jitter_ms=\(Int(health.jitterMS), privacy: .public) queue_max_ms=\(Int(health.queueMaxMS), privacy: .public)")
        }
    }
    func close(_ reason: CloseReason = .stopped) {
        guard !closed else { return }
        logger.notice("connection_close reason=\(reason.rawValue, privacy: .public) authenticated=\(self.authenticated, privacy: .public) peak_queue=\(self.peakQueueDepth, privacy: .public) max_queue_wait_ms=\(Int(self.maxQueueWaitMS), privacy: .public)")
        closed = true; authenticated = false; ready = false; pendingClip = nil
        retryInputWork?.cancel(); retryInputWork = nil; metricsTimer?.invalidate(); metricsTimer = nil
        inputListener?.stateUpdateHandler = nil; inputListener?.cancel(); inputListener = nil
        inputLink?.onClose = nil; inputLink?.close(reason); inputLink = nil
        pendingInputConnection?.cancel(); pendingInputConnection = nil
        let queued = featureQueue; featureQueue = []
        queued.forEach { $0.2(false) }
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(self)
        onReady = nil; onClip = nil; onClose = nil
    }
    private func sendFrame(_ body: Data, completion: (() -> Void)? = nil) throws {
        let data = try Framing.encode(body)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            if error != nil { self.close(.networkFailure) } else { completion?() }
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
            else if error != nil || complete { self.close(error == nil ? .peerClosed : .networkFailure) }
            else { self.readExactly(size, partial: all, completion: completion) }
        }
    }
    private func readFrame() {
        readExactly(4) { [weak self] header in
            guard let self else { return }
            do {
                let count = try Framing.length(header, limit: self.authenticated && !self.inputOnly ? Framing.maxFrame : 4096)
                self.readExactly(count) { [weak self] body in
                    self?.processFrame(body)
                }
            } catch { self.close(.invalidFrame) }
        }
    }
    private func processFrame(_ data: Data) {
        // Small input frames keep their direct path. Only one frame is decoded
        // at a time, so async bulk decoding cannot reorder receive sequences.
        guard authenticated, data.count > 256 * 1024, let cipher else {
            do { try handle(data); lastReceived = Date(); readFrame() }
            catch { close(.invalidFrame) }
            return
        }
        decodingQueue.async { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            let result = Result { try cipher.open(data) }
            let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                if elapsedMS >= 16 { self.logger.notice("frame_decode_slow elapsed_ms=\(elapsedMS, privacy: .public)") }
                do {
                    try self.handleMessage(result.get()); self.lastReceived = Date(); self.readFrame()
                } catch { self.close(.invalidFrame) }
            }
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
            let offer = try inputPort.map { try JSONEncoder().encode(InputOffer(port: $0)) }
            try sendFrame(cipher.seal(kind: "ready", clock: clockProvider?() ?? 0, features: advertisedFeatures, data: offer, app: AppVersion.current))
            return
        }
        guard let cipher else { throw ClipError.invalid("연결을 확인할 수 없어요.") }
        let message = try cipher.open(data)
        if !authenticated {
            guard message.kind == "ready", message.clip == nil else { throw ClipError.invalid("연결 인증에 실패했어요.") }
            if let version = message.app {
                guard version.components != nil else { throw ClipError.invalid("버전 정보가 올바르지 않아요.") }
                appVersion = version
            }
            if let clock = message.clock { onClock?(clock) }
            features = Set((message.features ?? []).prefix(8)).intersection(advertisedFeatures)
            authenticated = true
            if features.contains(SharingFeature.inputChannel) {
                guard let data = message.data, let offer = try? JSONDecoder().decode(InputOffer.self, from: data),
                      offer.port != 0 else { throw ClipError.invalid("입력 연결 정보를 확인할 수 없어요.") }
                remoteInputPort = offer.port
                if canRecoverInput { ready = true; onReady?(self) }
                if local.device < (remote?.device ?? "") {
                    pendingInputConnection?.cancel(); pendingInputConnection = nil
                    dialInput()
                } else if let pending = pendingInputConnection {
                    pendingInputConnection = nil; startInput(pending)
                }
            } else {
                pendingInputConnection?.cancel(); pendingInputConnection = nil
                inputListener?.cancel(); inputListener = nil
                ready = true; startMetrics(); onReady?(self)
            }
            logger.notice("connection_ready input_only=\(self.inputOnly, privacy: .public) elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime - self.createdAt) * 1000), privacy: .public)")
            return
        }
        try handleMessage(message)
    }
    private func handleMessage(_ message: Envelope) throws {
        switch message.kind {
        case "clip":
            guard !inputOnly else { throw ClipError.invalid("입력 채널에는 클립보드를 보낼 수 없어요.") }
            guard let clip = message.clip, clip.stamp.device == remote?.device else { throw ClipError.invalid("보낸 기기를 확인할 수 없어요.") }
            try clip.payload.validate()
            onClip?(self, clip)
        case "feature":
            guard let data = message.data else { throw ClipError.invalid("공유 데이터가 없어요.") }
            let packet = try FeaturePacket.decode(data)
            guard features.contains(packet.feature),
                  !(features.contains(SharingFeature.inputChannel) && packet.file == nil) else { throw ClipError.invalid("지원하지 않는 공유 기능이에요.") }
            onFeature?(self, packet)
        case "probe", "probe-reply":
            guard inputOnly, features.contains(SharingFeature.inputMetrics), let data = message.data,
                  data.count == 36, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else {
                throw ClipError.invalid("지연 측정 메시지가 올바르지 않아요.")
            }
            if message.kind == "probe" { enqueue(kind: "probe-reply", data: data) { _ in } }
            else if measurements.receive(id, now: ProcessInfo.processInfo.systemUptime) { publishMeasurements() }
        case "ping": break
        default: throw ClipError.invalid("지원하지 않는 메시지예요.")
        }
    }
    func send(_ message: ClipMessage) {
        guard ready, !inputOnly, !closed else { return }
        pendingClip = message
        flush()
    }
    func sendFeature(_ packet: FeaturePacket, completion: @escaping (Bool) -> Void) {
        if features.contains(SharingFeature.inputChannel), packet.file == nil {
            guard ready, features.contains(packet.feature), let inputLink, inputLink.ready else { completion(false); return }
            inputLink.sendFeature(packet, completion: completion); return
        }
        if featureQueue.count >= 32 { logger.error("send_queue_full depth=32") }
        guard ready, !closed, features.contains(packet.feature), featureQueue.count < 32,
              let data = try? packet.encoded() else { completion(false); return }
        enqueue(kind: "feature", data: data, completion: completion)
    }
    private func enqueue(kind: String, data: Data, completion: @escaping (Bool) -> Void) {
        guard ready, !closed, featureQueue.count < 32 else { completion(false); return }
        featureQueue.append((kind, data, completion, ProcessInfo.processInfo.systemUptime))
        peakQueueDepth = max(peakQueueDepth, featureQueue.count); flush()
    }
    private func flush() {
        guard !sending, !closed, authenticated, let cipher else { return }
        if !featureQueue.isEmpty {
            let (kind, data, reply, queuedAt) = featureQueue.removeFirst(); sending = true
            let uptime = ProcessInfo.processInfo.systemUptime
            let waitMS = (uptime - queuedAt) * 1000
            maxQueueWaitMS = max(maxQueueWaitMS, waitMS)
            if inputOnly && kind == "feature" { measurements.queueWait(waitMS) }
            if waitMS >= 50, uptime - lastSlowQueueLog >= 5 {
                lastSlowQueueLog = uptime
                logger.notice("send_queue_slow wait_ms=\(Int(waitMS), privacy: .public) remaining=\(self.featureQueue.count, privacy: .public)")
            }
            do {
                let frame = try Framing.encode(cipher.seal(kind: kind, data: data))
                connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                    guard let self else { reply(false); return }
                    self.sending = false; reply(error == nil && !self.closed)
                    if error != nil { self.close(.networkFailure) } else { self.flush() }
                })
            } catch { sending = false; reply(false); close(.invalidFrame) }
            return
        }
        guard let clip = pendingClip else { return }
        pendingClip = nil; sending = true
        // 'sending' remains true until delivery completes. No other outbound
        // cipher operation can run during preparation, preserving sequence order.
        clipboardEncodingQueue.async { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            let result = Result { try Framing.encode(cipher.seal(kind: "clip", clip: clip)) }
            let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                if elapsedMS >= 16 { self.logger.notice("clipboard_prepare_slow elapsed_ms=\(elapsedMS, privacy: .public)") }
                switch result {
                case .success(let frame):
                    self.connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                        guard let self, !self.closed else { return }
                        self.sending = false
                        if error != nil { self.close(.networkFailure) } else { self.flush() }
                    })
                case .failure: self.sending = false; self.close(.invalidFrame)
                }
            }
        }
    }
    func tick() {
        guard !closed else { return }
        inputLink?.tick()
        if (!ready && Date().timeIntervalSince(created) > 12) || Date().timeIntervalSince(lastReceived) > 90 {
            close(ready ? .idleTimeout : .handshakeTimeout); return
        }
        guard authenticated, !sending, let cipher else { return }
        sending = true
        do {
            try sendFrame(cipher.seal(kind: "ping")) { [weak self] in
                guard let self else { return }; self.sending = false; self.flush()
            }
        } catch { close(.invalidFrame) }
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
    private var pathMonitor: NWPathMonitor?
    private var recoveryWork: DispatchWorkItem?
    private var routeRaceWork: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var retryCount = 0
    private var pathAvailable: Bool?
    private var listenerIssue: NetworkNotice?
    private var browserIssue: NetworkNotice?
    private var connectionIssue: NetworkNotice?
    private let logger = Logger(subsystem: "dev.nearclip.mac", category: "transport")
    private var preferredPort: UInt16
    private var directPeer: DirectPeer?
    private var directAttempts = 0
    private var directFallbackAt: TimeInterval = 0
    private var directFallbackWork: DispatchWorkItem?
    var onPeers: (([String]) -> Void)?
    var onPeerDetails: (([ConnectedPeer]) -> Void)?
    var onMetrics: ((String, InputHealth) -> Void)?
    var onFeature: ((String, FeaturePacket) -> Void)?
    var onClip: ((ClipMessage) -> Void)?
    var onStatus: ((String?) -> Void)?
    var onListening: ((NWEndpoint.Port) -> Void)?
    var clockProvider: (() -> UInt64)?
    var onClock: ((UInt64) -> Void)?
    var separateInputPeerCount: Int { links.values.filter(\.hasSeparateInput).count }
    var peerCount: Int { links.values.filter(\.ready).count }

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
        // The lower identity owns startup dialing, just as it owns Bonjour and
        // input dialing. Let legacy peers finish their four-second retry before
        // the other side falls back to a direct connection.
        directFallbackAt = ProcessInfo.processInfo.systemUptime + 4.5
        let fallback = DispatchWorkItem { [weak self] in
            self?.directFallbackWork = nil; self?.connectDirectPeer(immediate: true)
        }
        directFallbackWork = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: fallback)
        startListener()
        if discovery {
            startBrowser()
            let monitor = NWPathMonitor(); pathMonitor = monitor
            monitor.pathUpdateHandler = { [weak self, weak monitor] path in
                guard let self, let monitor, self.pathMonitor === monitor, self.running else { return }
                self.networkPathChanged(available: path.status == .satisfied)
            }
            monitor.start(queue: .main)
        }
        reconnectNow()
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
        recoveryWork?.cancel(); recoveryWork = nil
        routeRaceWork?.cancel(); routeRaceWork = nil
        retryWork?.cancel(); retryWork = nil; retryCount = 0
        directFallbackWork?.cancel(); directFallbackWork = nil
        pathMonitor?.pathUpdateHandler = nil; pathMonitor?.cancel(); pathMonitor = nil
        pathAvailable = nil; listenerIssue = nil; browserIssue = nil; connectionIssue = nil
        listener?.stateUpdateHandler = nil; listener?.cancel(); listener = nil
        browser?.stateUpdateHandler = nil; browser?.cancel(); browser = nil
        endpoints.removeAll()
        for link in Array(links.values) { link.close() }
        links.removeAll(); publishPeers()
    }
    // Path events accelerate recovery; they never gate LAN traffic on internet
    // reachability or tear down an authenticated connection that still works.
    func networkPathChanged(available: Bool) {
        guard running else { return }
        pathAvailable = available
        recoveryWork?.cancel(); recoveryWork = nil
        if available {
            connectionIssue = nil
            let work = DispatchWorkItem { [weak self] in self?.reconnectNow() }
            recoveryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        publishStatus()
    }
    func reconnectNow() {
        guard running else { return }
        recoveryWork?.cancel(); recoveryWork = nil
        // Failed connection attempts can otherwise occupy the peer until the
        // handshake timeout. Keep in-progress handshakes and healthy sessions.
        for link in Array(links.values) where !link.ready {
            if case .waiting = link.connection.state { link.close(.networkFailure) }
        }
        if listener == nil { startListener() }
        if discovery && browser == nil { startBrowser() }
        for link in links.values where link.ready { link.reconnectInputNow() }
        connectDiscovered(); connectDirectPeer(immediate: true)
        logger.notice("network_recovery_attempt")
        publishStatus()
    }
    private func publishStatus() {
        guard running else { return }
        let issues = [listenerIssue, browserIssue, connectionIssue].compactMap { $0 }
        let notice: NetworkNotice
        if peerCount > 0 { onStatus?(nil); return }
        if issues.contains(.localNetworkDenied) { notice = .localNetworkDenied }
        else if pathAvailable == false || issues.contains(.unavailable) { notice = .unavailable }
        else if !issues.isEmpty { notice = .recovering }
        else { notice = .waitingForPeer }
        onStatus?(notice.message)
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
                case .ready:
                    self.listenerIssue = nil; self.publishStatus()
                    if let port = listener.port { self.preferredPort = port.rawValue; self.onListening?(port) }
                case .waiting(let error):
                    self.listenerIssue = NetworkNotice.classify(error); self.publishStatus()
                case .failed(let error):
                    if case .posix(.EADDRINUSE) = error { self.preferredPort = 0 }
                    self.listenerIssue = NetworkNotice.classify(error); self.publishStatus()
                    listener.cancel(); self.listener = nil
                default: break
                }
            }
            listener.start(queue: .main)
        } catch {
            listenerIssue = (error as? NWError).map(NetworkNotice.classify) ?? .recovering
            publishStatus()
        }
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
            self.discovered(found)
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, self.browser === browser, self.running else { return }
            switch state {
            case .ready: self.browserIssue = nil; self.publishStatus()
            case .waiting(let error): self.browserIssue = NetworkNotice.classify(error); self.publishStatus()
            case .failed(let error):
                self.browserIssue = NetworkNotice.classify(error); self.publishStatus()
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
            guard device < peer, !links.values.contains(where: {
                $0.endpointKey == key || ($0.ready && $0.remote?.device == peer) ||
                ($0.expectedDevice == peer && $0.connectingFor < 0.75)
            }), links.count < 8 else { continue }
            // Replace only the stale outbound direct attempt. Two concurrent
            // outgoing sessions would defeat the legacy direction-based election.
            for stale in Array(links.values) where !stale.ready && stale.endpointKey == nil && stale.expectedDevice == peer {
                stale.close(.stopped)
            }
            accept(NWConnection(to: endpoint, using: Self.parameters()), key: key, expected: peer)
        }
    }
    // Bonjour may advertise a working route while a saved address stalls.
    // Give the direct attempt a short head start, then use the service route.
    // The replacement still authenticates the expected identity.
    func discovered(_ found: [String: (NWEndpoint, String)]) {
        guard running else { return }
        endpoints = found; connectDiscovered()
        guard routeRaceWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.routeRaceWork = nil; self?.connectDiscovered()
        }
        routeRaceWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }
    private func retrySoon() {
        guard running, peerCount == 0, retryWork == nil else { return }
        let delay = min(4.0, 0.5 * pow(2, Double(min(retryCount, 3))))
        retryCount += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.retryWork = nil
            self.connectDiscovered(); self.connectDirectPeer(immediate: true)
        }
        retryWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func setDirectPeer(_ peer: DirectPeer?) {
        directPeer = peer; directAttempts = 0; connectDirectPeer()
    }
    private func connectDirectPeer(immediate: Bool = false) {
        guard running, let peer = directPeer, peerCount == 0,
              !links.values.contains(where: { $0.expectedDevice == peer.device }), links.count < 8,
              let port = NWEndpoint.Port(rawValue: peer.port) else { return }
        // Give Bonjour a chance first, then let either side recover a broken connection.
        directAttempts += 1
        guard device < peer.device || ProcessInfo.processInfo.systemUptime >= directFallbackAt else { return }
        guard immediate || directAttempts >= 2 else { return }
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
        link.onNetworkError = { [weak self] error in
            self?.connectionIssue = NetworkNotice.classify(error); self?.publishStatus()
        }
        link.onReady = { [weak self] link in
            guard let self else { return }
            self.connectionIssue = nil
            self.retryWork?.cancel(); self.retryWork = nil; self.retryCount = 0
            if let existing = self.links.values.first(where: { $0.id != link.id && $0.ready && $0.remote?.device == link.remote?.device }) {
                // Both devices select the same physical connection when they dial at once.
                let preferOutgoing = self.device < (link.remote?.device ?? "")
                if (link.expectedDevice != nil) == preferOutgoing { existing.close(.duplicate) }
                else { link.close(.duplicate); return }
            }
            self.publishPeers()
        }
        link.onInputChange = { [weak self] _ in self?.publishPeers() }
        link.onMetrics = { [weak self] link, health in
            if let peer = link.remote?.device { self?.onMetrics?(peer, health) }
        }
        link.onFeature = { [weak self] link, packet in
            if let peer = link.remote?.device { self?.onFeature?(peer, packet) }
        }
        link.onClip = { [weak self] _, clip in self?.onClip?(clip) }
        link.onClose = { [weak self] link in
            self?.links.removeValue(forKey: link.id); self?.publishPeers(); self?.retrySoon()
        }
        link.start()
    }
    private func publishPeers() {
        let peers = links.values.filter(\.ready).compactMap { link -> ConnectedPeer? in
            guard let remote = link.remote else { return nil }
            return ConnectedPeer(device: remote.device, name: remote.name, connection: link.id, features: link.features, appVersion: link.appVersion, inputReady: link.inputReady, inputSession: link.inputLink?.ready == true ? link.inputLink?.id : nil)
        }
        onPeers?(peers.map(\.name).sorted()); onPeerDetails?(peers)
        publishStatus()
    }
    func sendFeature(_ packet: FeaturePacket, to peer: String, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let link = links.values.first(where: { $0.ready && $0.remote?.device == peer }) else { completion(false); return }
        link.sendFeature(packet, completion: completion)
    }
    func send(_ message: ClipMessage) { for link in links.values where link.ready { link.send(message) } }
}
