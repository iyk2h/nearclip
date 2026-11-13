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
    var interrupted = false, done = false, clipArrived = false, clipboardDuringRecovery = false, dataDisconnected = false
    server.onListening = { port in
        client = PeerLink(connection: NWConnection(host: "127.0.0.1", port: port, using: LocalTransport.parameters()), secret: secret, device: other, name: "Recovery B")
        client?.onFeature = { _, packet in if let file = packet.file { sender.receive(file, from: local) } }
        client?.onMetrics = { _, value in health = value }
        client?.start()
    }
    server.onPeerDetails = { peers in
        detail = peers.first
        if interrupted && peers.isEmpty { dataDisconnected = true }
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
                client?.send(ClipMessage(id: UUID(), stamp: ClipStamp(counter: 1, device: other), payload: ClipPayload(type: "public.utf8-plain-text", data: Data("during recovery".utf8))))
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
