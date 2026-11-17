import Foundation
import CryptoKit
import Network

func connectionHealthTests() throws {
    let a = AppVersion(version: "0.4.3", build: 17), old = AppVersion(version: "0.4.3", build: 16)
    try Check.that(old < a && a < AppVersion(version: "0.4.10", build: 1), "version ordering compares numeric versions before build numbers")
    try Check.that(AppVersion.releaseTag("v0.4.3-build18") == AppVersion(version: "0.4.3", build: 18), "release tag carries an explicit same-version build")
    try Check.that(AppVersion.releaseTag("v0.4.3-buildx") == nil && AppVersion.releaseTag("v0.4.3-beta") == nil, "unrecognized release tags cannot offer an update")
    try Check.that(AppVersion(version: "0.4.3\nspoof", build: 1).components == nil && AppVersion(version: "0.4.3", build: -1).components == nil, "peer versions reject control characters and negative builds")
    try Check.that(a.peerNotice(nil).contains("확인 불가") && a.peerNotice(old).contains("달라요") && a.peerNotice(a).contains("같음"), "unknown, mismatched, and matched peer versions are distinct")
    let secret = try PairCode.key(PairCode.create()), h1 = Hello.make(device: UUID().uuidString, name: "A"), h2 = Hello.make(device: UUID().uuidString, name: "B")
    let tx = try SessionCipher(secret: secret, local: h1, remote: h2), rx = try SessionCipher(secret: secret, local: h2, remote: h1)
    try Check.that(try rx.open(tx.seal(kind: "ready", app: a)).app == a, "version metadata is inside the authenticated envelope")
    var m = InputMeasurements()
    let first = m.begin(now: 10)!
    try Check.that(!m.receive(UUID(), now: 10.1) && m.pending != nil, "unmatched latency replies cannot create a sample")
    try Check.that(m.receive(first, now: 10.01) && !m.receive(first, now: 10.02), "latency replies are accepted once")
    try Check.that(abs((m.snapshot?.rttMS ?? 0) - 10) < 0.001, "RTT uses local monotonic elapsed time")
    m.queueWait(4); m.queueWait(.nan)
    for n in 0..<70 { let time = Double(n + 20); let id = m.begin(now: time)!; _ = m.receive(id, now: time + 0.02) }
    try Check.that(m.snapshot?.samples == 60 && abs((m.snapshot?.p95MS ?? 0) - 20) < 0.001 && m.snapshot?.queueMaxMS == 4, "metrics windows are bounded and invalid queue samples are ignored")
    _ = m.begin(now: 100)
    try Check.that(m.begin(now: 101) == nil && !m.expired(now: 102) && m.expired(now: 104), "one outstanding probe expires without accumulating a queue")
}

func updateReleaseTests() throws {
    func release(_ tag: String, draft: Bool = false, beta: Bool = false, host: String = "github.com") -> [String: Any] {
        ["tag_name": tag, "html_url": "https://\(host)/iyk2h/nearclip/releases/tag/\(tag)", "draft": draft, "prerelease": beta,
         "assets": [["name": "NearClip-0.4.4-macOS.dmg", "browser_download_url": "https://github.com/iyk2h/nearclip/releases/download/\(tag)/NearClip-0.4.4-macOS.dmg"]]]
    }
    let data = try JSONSerialization.data(withJSONObject: [release("v0.4.4", beta: true), release("v0.4.3"), release("v9.0.0", draft: true), release("v8.0.0", host: "evil.example")])
    try Check.that(try PublicRelease.newest(data, includeBeta: true)?.tag_name == "v0.4.4", "update selection excludes drafts and untrusted release links")
    try Check.that(try PublicRelease.newest(data, includeBeta: false)?.tag_name == "v0.4.3", "stable channel excludes prereleases")
    try Check.that(try PublicRelease.newest(Data("[]".utf8), includeBeta: true) == nil, "empty release feed is not an available update")
    for raw in ["http://github.com/iyk2h/nearclip/releases/download/v1/x.dmg", "https://github.com.evil.example/iyk2h/nearclip/releases/download/v1/x.dmg", "https://user@github.com/iyk2h/nearclip/releases/download/v1/x.dmg", "https://github.com/other/nearclip/releases/download/v1/x.dmg", "https://github.com/iyk2h/nearclip/releases/download/v1/x.dmg?redirect=bad"] {
        try Check.that(!PublicRelease.trustedURL(URL(string: raw)!, download: true), "download links must remain in the official HTTPS repository")
    }
    let latest = try PublicRelease.newest(try JSONSerialization.data(withJSONObject: [release("v0.4.2", beta: true)]), includeBeta: true)!
    try Check.that(!(AppVersion(version: "0.4.3", build: 17) < latest.version!), "older public releases are never offered as an upgrade")
    try Check.rejects("oversized update feeds fail closed") { _ = try PublicRelease.newest(Data(repeating: 32, count: 2 * 1024 * 1024 + 1), includeBeta: true) }
}

func inputRecoveryNetworkTests() throws {
    let folder = try testFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("bulk"), target = folder.appendingPathComponent("received")
    let bytes = Data(repeating: 91, count: 8 * 1024 * 1024 + 3); try bytes.write(to: source)
    let code = try PairCode.create(), secret = try PairCode.key(code), local = UUID().uuidString, other = UUID().uuidString
    let server = try LocalTransport(code: code, device: local, name: "Recovery A", discovery: false)
    var client: PeerLink?, detail: ConnectedPeer?, health: InputHealth?
    let sender = FileTransfer(), receiver = FileTransfer()
    defer { sender.stop(); receiver.stop(); client?.close(); server.stop() }
    var interrupted = false, done = false, clipArrived = false, clipboardDuringRecovery = false, dataDisconnected = false, recoveryClipSent = false
    server.onListening = { port in
        client = PeerLink(connection: NWConnection(host: "127.0.0.1", port: port, using: LocalTransport.parameters()), secret: secret, device: other, name: "Recovery B")
        client?.onFeature = { _, packet in if let file = packet.file { sender.receive(file, from: local) } }
        client?.onMetrics = { _, value in health = value }
        client?.start()
    }
    server.onPeerDetails = { peers in
        detail = peers.first
        if interrupted && peers.isEmpty { dataDisconnected = true }
        // The two sockets deliver callbacks independently. Send only after the
        // receiver has observed the input outage, rather than racing its EOF.
        if interrupted, let detail, !detail.inputReady, !recoveryClipSent {
            recoveryClipSent = true
            client?.send(ClipMessage(id: UUID(), stamp: ClipStamp(counter: 1, device: other), payload: ClipPayload(type: "public.utf8-plain-text", data: Data("during recovery".utf8))))
        }
    }
    sender.send = { _, packet, reply in client?.sendFeature(FeaturePacket(file: packet), completion: reply) }
    receiver.send = { peer, packet, reply in server.sendFeature(FeaturePacket(file: packet), to: peer, completion: reply) }
    receiver.onOffer = { _, offer in receiver.accept(id: offer.id, destination: target) }
    sender.onComplete = { _ in done = true }
    server.onClip = { _ in clipArrived = true; clipboardDuringRecovery = !serverHasInput() }
    func serverHasInput() -> Bool { detail?.inputReady == true }
    server.onFeature = { peer, packet in
        if let file = packet.file {
            if file.kind == .chunk && !interrupted {
                interrupted = true; client?.inputLink?.close()
            }
            receiver.receive(file, from: peer)
        }
    }
    server.start(); waitFor({ client?.hasSeparateInput == true && detail?.inputReady == true })
    let parentID = detail?.connection, inputID = client?.inputLink?.id
    try Check.that(client?.hasSeparateInput == true && detail?.appVersion == AppVersion.current, "recovery peers authenticate version metadata and input socket")
    try sender.offer(url: source, to: local)
    waitFor({ done && clipArrived && client?.hasSeparateInput == true && client?.inputLink?.id != inputID && serverHasInput() }, seconds: 15)
    try Check.that(done && (try Data(contentsOf: target)) == bytes, "8 MiB file completes with verified content despite input socket loss")
    try Check.that(clipArrived && clipboardDuringRecovery && !dataDisconnected && detail?.connection == parentID, "clipboard continues during input recovery without parent disconnect")
    try Check.that(client?.inputLink?.id != inputID && client?.hasSeparateInput == true && serverHasInput(), "both peers reauthenticate a fresh input channel on the same parent")
    var inputArrived = false
    server.onFeature = { _, packet in inputArrived = packet.mouse?.kind == .availability }
    client?.sendFeature(FeaturePacket(mouse: MousePacket(kind: .availability, enabled: false))) { _ in }
    waitFor({ inputArrived && health != nil }, seconds: 4)
    try Check.that(inputArrived && health?.samples ?? 0 > 0, "recovered input transports fresh packets and authenticated RTT probes")
    client?.inputLink?.close(); client?.close(); server.stop()
    RunLoop.main.run(until: Date().addingTimeInterval(0.7))
    try Check.that(client?.inputLink == nil && client?.closed == true && server.peerCount == 0, "shutdown cancels a pending input reconnect")
}

func recoveryWakeTests() throws {
    try Check.that(NetworkNotice.classify(.dns(-65570)) == .localNetworkDenied, "Bonjour policy denial requests local network permission")
    try Check.that(NetworkNotice.classify(.posix(.ENETDOWN)) == .unavailable, "offline network is not reported as a privacy denial")
    try Check.that(NetworkNotice.classify(.posix(.ECONNREFUSED)) == .recovering, "unreachable peer does not claim the app is off or permission denied")
    try Check.that(NetworkNotice.classify(.dns(-65555)) == .recovering, "generic DNS authorization error does not misidentify privacy settings")
    try Check.that(NearbyPairing.failureMessage(.posix(.ETIMEDOUT)) == NetworkNotice.recovering.message, "pairing timeout uses the same factual recovery guidance")
    let code = try PairCode.create()
    let server = try LocalTransport(code: code, device: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", name: "Wake server", discovery: false)
    let client = try LocalTransport(code: code, device: "00000000-0000-0000-0000-000000000001", name: "Wake client", discovery: false)
    defer { server.stop(); client.stop() }
    var port: UInt16?, connection: UUID?, note: String?
    server.onListening = { port = $0.rawValue }
    client.onPeerDetails = { connection = $0.first?.connection }
    client.onStatus = { note = $0 }
    server.start(); waitFor({ port != nil })
    guard let port else { throw ClipError.invalid("Wake listener unavailable") }
    client.setDirectPeer(DirectPeer(host: "127.0.0.1", port: port, device: server.device))
    client.start(); waitFor({ connection != nil }, seconds: 2)
    try Check.that(connection != nil, "startup immediately dials a saved peer without the four-second retry tick")
    let original = connection
    client.networkPathChanged(available: false)
    client.networkPathChanged(available: true)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    client.reconnectNow()
    try Check.that(connection == original && note == nil, "path changes and manual retry preserve a healthy authenticated connection and clear warnings")
    server.stop(); waitFor({ client.peerCount == 0 })
    client.networkPathChanged(available: false)
    try Check.that(note == NetworkNotice.unavailable.message, "disconnected client explains offline state without a permission prompt")
    server.start(); client.networkPathChanged(available: true)
    waitFor({ client.peerCount == 1 }, seconds: 2)
    try Check.that(client.peerCount == 1 && connection != original && note == nil, "network restoration reconnects and authenticates before the periodic retry")
    for cycle in 1...3 {
        let prior = connection
        server.stop(); waitFor({ client.peerCount == 0 })
        server.start()
        // No synthetic path notification: peer closure itself schedules recovery.
        waitFor({ client.separateInputPeerCount == 1 }, seconds: 3)
        try Check.that(client.separateInputPeerCount == 1 && connection != prior,
                       "peer restart \(cycle) recovers input without waiting for a network-path notification")
    }
    client.networkPathChanged(available: true); client.stop()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    client.networkPathChanged(available: true); client.reconnectNow()
    try Check.that(client.peerCount == 0, "stop cancels queued path recovery and ignores later wake events")
}

func staleRouteTests() throws {
    let code = try PairCode.create()
    let client = try LocalTransport(code: code, device: "00000000-0000-0000-0000-000000000001", name: "Route client", discovery: false)
    let server = try LocalTransport(code: code, device: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", name: "Route server", discovery: false)
    // The old address accepts TCP but never authenticates, like a stale route
    // pointing at a different service. A live discovery result must win promptly.
    let stalled = try NWListener(using: LocalTransport.parameters(), on: .any)
    var held: [NWConnection] = [], realPort: NWEndpoint.Port?
    stalled.newConnectionHandler = { connection in held.append(connection); connection.start(queue: .main) }
    defer { held.forEach { $0.cancel() }; stalled.cancel(); client.stop(); server.stop() }
    server.onListening = { realPort = $0 }; server.start(); stalled.start(queue: .main)
    waitFor({ realPort != nil && stalled.port != nil })
    guard let realPort, let oldPort = stalled.port else { throw ClipError.invalid("Route fixture unavailable") }
    client.setDirectPeer(DirectPeer(host: "127.0.0.1", port: oldPort.rawValue, device: server.device)); client.start()
    waitFor({ !held.isEmpty }, seconds: 2)
    let started = ProcessInfo.processInfo.systemUptime
    client.discovered(["fresh-service": (.hostPort(host: "127.0.0.1", port: realPort), server.device)])
    waitFor({ client.separateInputPeerCount == 1 && server.separateInputPeerCount == 1 }, seconds: 3)
    try Check.that(client.separateInputPeerCount == 1 && server.separateInputPeerCount == 1,
                   "fresh discovery authenticates input despite a stalled saved-address handshake")
    try Check.that(ProcessInfo.processInfo.systemUptime - started < 3, "working route does not wait for the twelve-second handshake deadline")
    print("MEASURE: stalled-route recovery \(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) ms on local TCP")
    for _ in 0..<5 { client.discovered(["fresh-service": (.hostPort(host: "127.0.0.1", port: realPort), server.device)]) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.9))
    try Check.that(client.peerCount == 1 && server.peerCount == 1, "repeated discovery retains one authenticated peer")
    client.stop(); server.stop()
    RunLoop.main.run(until: Date().addingTimeInterval(0.9))
    try Check.that(client.peerCount == 0 && server.peerCount == 0, "stop cancels delayed route races and retry attempts")
}

func persistedInputConsentTests() throws {
    let code = try PairCode.create(), id = UUID().uuidString
    let saved = InputConsent(peer: id, group: try PairCode.group(code))
    let restored = try JSONDecoder().decode(InputConsent.self, from: JSONEncoder().encode(saved))
    try Check.that(restored.peer(for: code) == id, "input choice survives serialization for the same pairing")
    try Check.that(restored.peer(for: try PairCode.create()) == nil, "new pairing key rejects the remembered input choice")
    let mouse = MouseSharing(local: UUID().uuidString, native: false)
    var remembered: String? = id
    mouse.onConsentChange = { remembered = $0 }
    mouse.suspend(.screenLock); mouse.restoreConsent(for: id)
    try Check.that(!mouse.enabled && mouse.sharingRequested, "restoring input choice alone never installs capture")
    mouse.setPeer(id, supportsKeyboard: true)
    try Check.that(!mouse.enabled && mouse.sharingRequested, "restored choice remains suspended at a locked launch")
    mouse.resume(.screenLock)
    try Check.that(mouse.enabled && !mouse.remoteEnabled && mouse.mode == .local, "unlock restores same-peer readiness without remote consent or a control session")
    mouse.setPeer(nil)
    try Check.that(remembered == id && !mouse.enabled, "network outage keeps persistent choice without capturing input")
    mouse.setPeer(id); mouse.emergencyStop()
    try Check.that(remembered == nil && !mouse.sharingRequested, "emergency stop revokes the persisted choice")
    try mouse.setEnabled(true); mouse.setPeer(UUID().uuidString)
    try Check.that(remembered == nil && !mouse.enabled, "another authenticated device cannot inherit the stored choice")
    mouse.stop()
}

func startupDialElectionTests() throws {
    let code = try PairCode.create()
    let lower = try LocalTransport(code: code, device: "00000000-0000-0000-0000-000000000001", name: "Lower", discovery: false)
    let higher = try LocalTransport(code: code, device: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", name: "Higher", discovery: false)
    defer { lower.stop(); higher.stop() }
    var port: NWEndpoint.Port?
    lower.onListening = { port = $0 }; lower.start(); waitFor({ port != nil })
    guard let port else { throw ClipError.invalid("Election fixture unavailable") }
    higher.setDirectPeer(DirectPeer(host: "127.0.0.1", port: port.rawValue, device: lower.device))
    higher.start()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    try Check.that(higher.peerCount == 0, "secondary dialer gives the preferred peer a startup opportunity")
    waitFor({ higher.separateInputPeerCount == 1 && lower.separateInputPeerCount == 1 }, seconds: 6)
    try Check.that(higher.separateInputPeerCount == 1 && lower.separateInputPeerCount == 1,
                   "secondary direct fallback connects when discovery and primary dialing are unavailable")
    higher.stop(); higher.start(); higher.stop()
    RunLoop.main.run(until: Date().addingTimeInterval(4.7))
    try Check.that(higher.peerCount == 0 && lower.peerCount == 0, "stop cancels the deferred secondary dial")
}

func inputBurstNetworkTests() throws {
    let code = try PairCode.create(), secret = try PairCode.key(code)
    let local = UUID().uuidString, remote = UUID().uuidString, token = UUID()
    let server = try LocalTransport(code: code, device: local, name: "Burst receiver", discovery: false)
    var echoed: [Data] = []
    var client: PeerLink?, received: [Data] = [], callbacks = 0, failed = 0, clipboardArrived = false
    defer { client?.close(); server.stop() }
    server.onListening = { port in
        client = PeerLink(connection: NWConnection(host: "127.0.0.1", port: port, using: LocalTransport.parameters()),
                          secret: secret, device: remote, name: "Burst sender")
        client?.onFeature = { _, packet in if let data = try? packet.encoded() { echoed.append(data) } }
        client?.start()
    }
    server.onFeature = { _, packet in
        if let data = try? packet.encoded() { received.append(data) }
        server.sendFeature(packet, to: remote)
    }
    server.onClip = { clipboardArrived = $0.payload.data.count == ClipPayload.maxBytes }
    server.start(); waitFor({ client?.hasSeparateInput == true && server.peerCount == 1 })
    try Check.that(client?.hasSeparateInput == true, "keyboard burst has an authenticated separate input channel")
    let sequence = (0..<4).flatMap { _ in [
        FeaturePacket(mouse: MousePacket(kind: .input, token: token, action: .move, dx: 1)),
        FeaturePacket(keyboard: KeyboardPacket(token: token, action: .modifiers, keyCode: 55, flags: 0x100000)),
        FeaturePacket(keyboard: KeyboardPacket(token: token, action: .down, keyCode: 8, flags: 0x100000)),
        FeaturePacket(keyboard: KeyboardPacket(token: token, action: .down, keyCode: 8, flags: 0x100000, isRepeat: true)),
        FeaturePacket(keyboard: KeyboardPacket(token: token, action: .up, keyCode: 8, flags: 0x100000)),
        FeaturePacket(keyboard: KeyboardPacket(token: token, action: .modifiers, keyCode: 55))
    ] }
    // Bulk encryption and writing must not gate the independently sequenced input window.
    client?.send(ClipMessage(id: UUID(), stamp: ClipStamp(counter: 1, device: remote),
        payload: ClipPayload(type: "public.utf8-plain-text", data: Data(repeating: 65, count: ClipPayload.maxBytes))))
    let start = ProcessInfo.processInfo.systemUptime
    for packet in sequence { client?.sendFeature(packet) { callbacks += 1; if !$0 { failed += 1 } } }
    client?.tick() // An interleaved keepalive must not race the cipher's sequence.
    waitFor({ received.count == sequence.count && callbacks == sequence.count }, seconds: 3)
    let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
    // Compare decoded packets: JSON object key order is not a wire contract.
    let decoded = try received.map { try FeaturePacket.decode($0) }
    try Check.that(decoded.count == sequence.count && zip(decoded, sequence).allSatisfy {
        $0.keyboard?.action == $1.keyboard?.action && $0.keyboard?.keyCode == $1.keyboard?.keyCode &&
        $0.keyboard?.flags == $1.keyboard?.flags && $0.keyboard?.isRepeat == $1.keyboard?.isRepeat &&
        $0.mouse?.action == $1.mouse?.action
    }, "pipelined mouse, modifiers, repeats, and key releases retain exact order under bulk load")
    try Check.that(callbacks == sequence.count && failed == 0 && client?.hasSeparateInput == true,
                   "every input burst completion succeeds once with an interleaved keepalive")
    print("MEASURE: 24 ordered input frames under 20 MiB clipboard load: \(Int(elapsed)) ms (loopback, not physical Wi-Fi)")
    waitFor({ clipboardArrived }, seconds: 10)
    try Check.that(clipboardArrived, "input burst preserves concurrent large clipboard delivery")
    waitFor({ echoed.count == sequence.count })
    try Check.that(echoed.count == sequence.count, "batched input receive preserves a full-duplex mixed input burst")
    if let input = client?.inputLink {
        print("METRIC: input_receive frames=\(input.inputFramesReceived) callbacks=\(input.inputReadCallbacks); old exact-read path requires two callbacks per frame")
    }
    // Close while sends are pending: each accepted or rejected submission gets one callback.
    var closeCallbacks = [Int](repeating: 0, count: 40), rejected = 0
    for index in 0..<40 {
        client?.sendFeature(sequence[index % sequence.count]) { success in
            closeCallbacks[index] += 1; if !success { rejected += 1 }
        }
    }
    client?.close()
    waitFor({ closeCallbacks.allSatisfy { $0 == 1 } })
    try Check.that(closeCallbacks.allSatisfy { $0 == 1 } && rejected >= 8,
                   "input window stays bounded and shutdown completes every pending submission exactly once")
}


func delayedInputRouteTests() throws {
    let code = try PairCode.create(), secret = try PairCode.key(code)
    let local = "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", remote = "00000000-0000-0000-0000-000000000001"
    let server = try LocalTransport(code: code, device: local, name: "Delayed route receiver", discovery: false)
    var client: PeerLink?, routeAvailable = false, attempts = 0, delivered = false
    defer { client?.close(); server.stop() }
    server.onListening = { port in
        client = PeerLink(connection: NWConnection(host: "127.0.0.1", port: port, using: LocalTransport.parameters()),
                          secret: secret, device: remote, name: "Delayed route sender")
        client?.inputHostProvider = { attempts += 1; return routeAvailable ? NWEndpoint.Host("127.0.0.1") : nil }
        client?.start()
    }
    server.onFeature = { _, packet in delivered = packet.keyboard?.action == .up }
    server.start(); waitFor({ client?.authenticated == true && attempts > 0 })
    try Check.that(client?.ready == true && client?.hasSeparateInput == false && attempts == 1,
        "bulk authentication can finish while the input route is temporarily unavailable")
    routeAvailable = true
    waitFor({ client?.hasSeparateInput == true && server.separateInputPeerCount == 1 }, seconds: 3)
    try Check.that(attempts >= 2 && client?.hasSeparateInput == true,
        "delayed input route retries automatically without app restart or parent replacement")
    client?.sendFeature(FeaturePacket(keyboard: KeyboardPacket(token: UUID(), action: .up, keyCode: 0))) { _ in }
    waitFor({ delivered })
    try Check.that(delivered, "recovered initial route transports authenticated keyboard frames")
    client?.close(); server.stop()

    routeAvailable = false; attempts = 0
    server.start(); waitFor({ client?.authenticated == true && attempts > 0 })
    client?.close(); server.stop()
    let stoppedAttempts = attempts
    RunLoop.main.run(until: Date().addingTimeInterval(0.65))
    try Check.that(attempts == stoppedAttempts && client?.closed == true,
        "shutdown cancels the initial unresolved-route retry")
}

func inputFramingAndCadenceTests() throws {
    let payloads = [Data([1]), Data(repeating: 2, count: 80), Data(repeating: 3, count: 4096)]
    let wire = try payloads.reduce(into: Data()) { $0.append(try Framing.encode($1)) }
    var batched = InputFrameBuffer()
    try Check.that(try batched.append(wire) == payloads && batched.pendingBytes == 0,
                   "coalesced input frames drain in order in one receive callback")
    for split in [1, 2, 3, 4, 5, 6, 84, 85, 86, 87, wire.count - 1] {
        var parser = InputFrameBuffer()
        let first = try parser.append(Data(wire.prefix(split)))
        let last = try parser.append(Data(wire.dropFirst(split)))
        try Check.that(first + last == payloads && parser.pendingBytes == 0,
                       "fragmented header/body and consecutive frames preserve byte order")
    }
    var bytewise = InputFrameBuffer(), decoded: [Data] = []
    var bounded = true
    for byte in wire {
        decoded += try bytewise.append(Data([byte]))
        bounded = bounded && bytewise.pendingBytes <= InputFrameBuffer.frameLimit + 3
    }
    try Check.that(bounded, "partial input frame remains bounded across every single-byte fragment")
    try Check.that(decoded == payloads, "single-byte TCP delivery reconstructs every input frame")
    for header in [Data([0, 0, 0, 0]), Data([0, 0, 16, 1]), Data([255, 255, 255, 255])] {
        try Check.rejects("input parser rejects zero or oversized lengths before allocating their body") {
            var parser = InputFrameBuffer(); _ = try parser.append(header)
        }
    }
    try Check.rejects("input parser bounds one supplied receive chunk") {
        var parser = InputFrameBuffer(); _ = try parser.append(Data(repeating: 0, count: InputFrameBuffer.chunkLimit + 1))
    }
    var partial = InputFrameBuffer()
    _ = try partial.append(Data([0, 0, 0, 3, 42]))
    try Check.that(partial.pendingBytes == 5, "truncated EOF remains detectable instead of dispatching partial input")

    var steady = MotionCadence(), bursty = MotionCadence()
    for n in 0..<120 {
        let sent = 10000 + Double(n) / 120
        steady.record(sent: sent, arrived: 20000 + Double(n) / 120)
        bursty.record(sent: sent, arrived: 20000 + Double(n / 6) / 20)
    }
    try Check.that(steady.sourceP95 == 8 && steady.arrivalP95 == 8 && steady.excessP95 == 0,
                   "cadence uses clock-independent intervals without mistaking uptime offset for latency")
    try Check.that(bursty.sourceP95 == 8 && bursty.arrivalP95 == 50 && bursty.excessP95 == 42 && bursty.bursts > 0,
                   "same 120Hz input reveals 50ms network batching rather than a slow source device")
    let count = steady.count
    steady.record(sent: 10050, arrived: 20100)
    try Check.that(steady.count == count, "deliberate idle time is excluded from movement cadence")
    steady.record(sent: nil, arrived: 20101)
    steady.record(sent: 10051, arrived: 20102)
    try Check.that(steady.count == count, "legacy peer without timing resets interval comparison")
    for n in 0..<500 { steady.record(sent: 20000 + Double(n) / 120, arrived: 30000 + Double(n) / 120) }
    try Check.that(steady.count == 240, "cadence windows remain bounded during long sessions")
    let token = UUID()
    let motion = MousePacket(kind: .input, token: token, action: .move, dx: 3, motionSentAt: 500)
    try Check.that(try FeaturePacket.decode(FeaturePacket(mouse: motion).encoded()).mouse?.motionSentAt == 500,
                   "optional motion timing survives validated wire encoding")
    for packet in [MousePacket(kind: .input, token: token, action: .move, motionSentAt: -1),
                   MousePacket(kind: .input, token: token, action: .move, motionSentAt: .nan),
                   MousePacket(kind: .heartbeat, token: token, motionSentAt: 1)] {
        try Check.rejects("invalid or misplaced motion timing is rejected") { try packet.validate() }
    }
}
