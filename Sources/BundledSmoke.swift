import Foundation

// Opt-in diagnostic with synthetic identities. Never touches the user's clipboard or Keychain.
final class BundledSmoke {
    private var a: NearbyPairing!
    private var b: NearbyPairing!
    private var ta: LocalTransport?
    private var tb: LocalTransport?
    private var timer: Timer?
    private var started = Date()
    private var codeA: String?
    private var codeB: String?
    private var began = false
    private var transferring = false
    private var received = false
    private let filesA = FileTransfer()
    private let filesB = FileTransfer()
    private var fileStarted = false
    private var fileDone = false
    private var layoutSent = false
    private var layoutReceived = false
    private var folder: URL?
    private var complete: ((Bool) -> Void)?
    func run(complete: @escaping (Bool) -> Void) {
        self.complete = complete
        a = NearbyPairing(device: UUID().uuidString, name: "NearClip test A")
        b = NearbyPairing(device: UUID().uuidString, name: "NearClip test B")
        a.onCandidates = { [weak self] candidates in
            guard let self, !self.began, candidates.contains(where: { $0.device == self.b.device }) else { return }
            self.began = true; self.a.connect(device: self.b.device)
        }
        a.onVerify = { _, _, reply in reply(true) }; b.onVerify = { _, _, reply in reply(true) }
        a.onPaired = { [weak self] code, _ in self?.codeA = code; self?.a.endDiscovery() }; b.onPaired = { [weak self] code, _ in self?.codeB = code; self?.b.endDiscovery() }
        a.onStatus = { print("Pairing A:", $0) }; b.onStatus = { print("Pairing B:", $0) }
        a.start(); b.start()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func tick() {
        if Date().timeIntervalSince(started) > 25 { finish(false); return }
        if let codeA, codeA == codeB, !transferring {
            transferring = true
            print("PASS: packaged app discovers and pairs through Bonjour")
            a.stop(); b.stop()
            do {
                let ta = try LocalTransport(code: codeA, device: a.device, name: "Test A")
                let tb = try LocalTransport(code: codeA, device: b.device, name: "Test B")
                self.ta = ta; self.tb = tb
                tb.onClip = { [weak self] clip in self?.received = clip.payload.data == Data("synthetic smoke test".utf8) }
                ta.start(); tb.start()
            } catch { finish(false) }
        }
        if let ta, let tb, ta.peerCount == 1, tb.peerCount == 1, !received {
            ta.send(ClipMessage(id: UUID(), stamp: .init(counter: 1, device: a.device), payload: .init(type: "public.utf8-plain-text", data: Data("synthetic smoke test".utf8))))
        }
        if received && !fileStarted {
            fileStarted = true
            print("PASS: packaged app authenticates and transfers synthetic clipboard content")
            startFileCheck()
        }
        if fileDone && !layoutSent {
            layoutSent = true
            print("PASS: packaged app streams and verifies a synthetic file")
            ta?.sendFeature(FeaturePacket(mouse: MousePacket(kind: .layout, layout: ScreenLayout(revision: 1, author: a.device, left: a.device, right: b.device))), to: b.device)
        }
        if layoutReceived { print("PASS: packaged app exchanges encrypted screen layout"); finish(true) }
    }
    private func startFileCheck() {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nearclip-smoke-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); folder = directory
            let source = directory.appendingPathComponent("source.bin"), destination = directory.appendingPathComponent("received.bin")
            let data = Data(repeating: 0xA7, count: 300_123); try data.write(to: source)
            filesA.send = { [weak self] peer, packet, reply in self?.ta?.sendFeature(FeaturePacket(file: packet), to: peer, completion: reply) }
            filesB.send = { [weak self] peer, packet, reply in self?.tb?.sendFeature(FeaturePacket(file: packet), to: peer, completion: reply) }
            ta?.onFeature = { [weak self] peer, packet in if let file = packet.file { self?.filesA.receive(file, from: peer) } }
            tb?.onFeature = { [weak self] peer, packet in
                guard let self else { return }
                if let file = packet.file { self.filesB.receive(file, from: peer) }
                if let layout = packet.mouse?.layout { self.layoutReceived = layout.left == self.a.device && layout.right == self.b.device }
            }
            filesB.onOffer = { [weak self] _, packet in self?.filesB.accept(id: packet.id, destination: destination) }
            filesA.onComplete = { [weak self] _ in self?.fileDone = (try? Data(contentsOf: destination)) == data }
            try filesA.offer(url: source, to: b.device)
        } catch { finish(false) }
    }
    private func finish(_ success: Bool) {
        timer?.invalidate(); timer = nil
        filesA.stop(); filesB.stop()
        a.stop(); b.stop(); ta?.stop(); tb?.stop()
        if let folder { try? FileManager.default.removeItem(at: folder) }
        let cleaned = !a.busy && !b.busy && (ta?.peerCount ?? 0) == 0 && (tb?.peerCount ?? 0) == 0
        print(cleaned ? "PASS: packaged app closes all network sessions" : "FAIL: network cleanup")
        let reply = complete; complete = nil; reply?(success && cleaned)
    }
}
