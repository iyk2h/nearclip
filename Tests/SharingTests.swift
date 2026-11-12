import AppKit
import CryptoKit
import Network
import Darwin

func waitFor(_ predicate: () -> Bool, seconds: Double = 5) {
    let until = Date().addingTimeInterval(seconds)
    while !predicate() && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
}
func testFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nearclip-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
}

func sharingProtocolTests() throws {
    for name in ["../escape", "a/b", "a\\b", "..", ".", "a:b", "a\u{0}b", String(repeating: "a", count: 256)] {
        try Check.that(!FilePacket.safeName(name), "reject unsafe incoming file name")
    }
    try Check.that(FilePacket.safeName("사진 한글 🙂.png"), "allow Unicode file names")
    try Check.rejects("reject oversized file offers") { try FilePacket(kind: .offer, id: UUID(), name: "a", size: FilePacket.maxSize + 1).validate() }
    try Check.rejects("reject oversized chunks") { try FilePacket(kind: .chunk, id: UUID(), offset: 0, bytes: Data(repeating: 0, count: FilePacket.chunkSize + 1)).validate() }
    try Check.rejects("reject non-finite mouse input") { try MousePacket(kind: .input, token: UUID(), action: .move, dx: .nan).validate() }
    try Check.rejects("reject out-of-range mouse input") { try MousePacket(kind: .input, token: UUID(), action: .move, dx: 5000).validate() }
    try Check.rejects("reject unsupported mouse buttons") { try MousePacket(kind: .input, token: UUID(), action: .down, button: 9).validate() }
    try Check.rejects("reject missing input session") { try MousePacket(kind: .input, action: .down).validate() }
    try Check.rejects("reject unsupported input flags") { try MousePacket(kind: .input, token: UUID(), action: .down, flags: UInt64.max).validate() }
    let file = FilePacket(kind: .offer, id: UUID(), name: "test.txt", size: 12)
    let decoded = try FeaturePacket.decode(FeaturePacket(file: file).encoded())
    try Check.that(decoded.file?.name == "test.txt", "platform-neutral sharing packet round trip")
    try Check.rejects("reject mixed feature payloads") { _ = try FeaturePacket(file: file, mouse: MousePacket(kind: .availability, enabled: true)).encoded() }
    let a = Hello.make(device: UUID().uuidString, name: "A"), b = Hello.make(device: UUID().uuidString, name: "B")
    let key = try PairCode.key(PairCode.create())
    let tx = try SessionCipher(secret: key, local: a, remote: b), rx = try SessionCipher(secret: key, local: b, remote: a)
    let sealed = try tx.seal(kind: "feature", data: FeaturePacket(file: file).encoded())
    let opened = try rx.open(sealed)
    try Check.that(try FeaturePacket.decode(opened.data!).file?.id == file.id, "file control messages use authenticated encryption")
    try Check.rejects("reject replayed feature packet") { _ = try rx.open(sealed) }
}

func fileTransferTests() throws {
    let folder = try testFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.bin"), destination = folder.appendingPathComponent("received.bin")
    let data = Data((0..<300_123).map { UInt8($0 % 251) }); try data.write(to: source)
    let a = FileTransferWorker(), b = FileTransferWorker()
    defer { a.stop(); b.stop(); a.send = nil; b.send = nil }
    var queue: [(Bool, FilePacket)] = []
    a.send = { _, packet, reply in queue.append((true, packet)); reply(true) }
    b.send = { _, packet, reply in queue.append((false, packet)); reply(true) }
    var offered: FilePacket?, complete = false
    b.onOffer = { _, offer in offered = offer }; a.onComplete = { _ in complete = true }
    func pump() {
        var limit = 200
        while !queue.isEmpty && limit > 0 {
            limit -= 1; let (toB, packet) = queue.removeFirst()
            if toB { b.receive(packet, from: "A") } else { a.receive(packet, from: "B") }
        }
    }
    try a.offer(url: source, to: "B"); pump()
    try Check.that(offered != nil && !FileManager.default.fileExists(atPath: destination.path), "file offer requires explicit recipient acceptance")
    try Check.that(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1, "no temporary file is created before acceptance")
    b.accept(id: offered!.id, destination: destination); pump()
    try Check.that(complete && !a.busy && !b.busy, "bounded chunk transfer reaches acknowledged completion")
    try Check.that(try Data(contentsOf: destination) == data && Data(contentsOf: source) == data, "file bytes preserved and source is not deleted")
    try Check.that(getxattr(destination.path, "com.apple.quarantine", nil, 0, 0, 0) > 0, "received file retains Gatekeeper quarantine metadata")
    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
    try Check.that((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "received file is private and not executable")
    try Check.that(!(try FileManager.default.contentsOfDirectory(atPath: folder.path)).contains(where: { $0.hasSuffix(".part") }), "successful transfer removes partial file")

    // A corruption on the authenticated application stream must still fail the final digest.
    let bad = folder.appendingPathComponent("bad.bin")
    complete = false; offered = nil
    a.send = { _, packet, reply in
        var packet = packet
        if packet.kind == .chunk, var bytes = packet.bytes { bytes[0] ^= 1; packet.bytes = bytes }
        queue.append((true, packet)); reply(true)
    }
    try a.offer(url: source, to: "B"); pump(); b.accept(id: offered!.id, destination: bad); pump()
    try Check.that(!complete && !FileManager.default.fileExists(atPath: bad.path) && !a.busy && !b.busy, "digest mismatch cancels without publishing a file")
    try Check.that(!(try FileManager.default.contentsOfDirectory(atPath: folder.path)).contains(where: { $0.hasSuffix(".part") }), "failed transfer cleans partial data")

    let id = UUID()
    b.receive(FilePacket(kind: .offer, id: id, name: "x", size: 4), from: "A")
    b.receive(FilePacket(kind: .chunk, id: id, offset: 0, bytes: Data([1])), from: "A")
    try Check.that(!b.busy, "unsolicited chunks cannot write before acceptance")
    queue = []
    b.receive(FilePacket(kind: .offer, id: UUID(), name: "x", size: 4), from: "A")
    b.checkTimeout(now: Date().addingTimeInterval(121))
    try Check.that(!b.busy, "unanswered offers expire")
    queue = []
    a.send = { _, packet, reply in queue.append((true, packet)); reply(true) }
    try a.offer(url: source, to: "B"); pump(); b.accept(id: offered!.id, destination: destination); pump()
    try Check.that(try Data(contentsOf: destination) == data, "existing destination is never overwritten")
    let alias = folder.appendingPathComponent("alias.bin")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
    try Check.rejects("reject sending symlinks") { try a.offer(url: alias, to: "B") }
    try Check.rejects("reject sending a directory") { try a.offer(url: folder, to: "B") }

    queue = []
    let cancelled = folder.appendingPathComponent("cancelled.bin"), cancelledID = UUID()
    b.receive(FilePacket(kind: .offer, id: cancelledID, name: "cancelled.bin", size: 4), from: "A")
    b.accept(id: cancelledID, destination: cancelled)
    b.receive(FilePacket(kind: .chunk, id: cancelledID, offset: 0, bytes: Data([1, 2])), from: "A")
    b.cancel(); queue = []
    try Check.that(!b.busy && !FileManager.default.fileExists(atPath: cancelled.path), "cancel after partial write never publishes the destination")
    try Check.that(!(try FileManager.default.contentsOfDirectory(atPath: folder.path)).contains(where: { $0.hasSuffix(".part") }), "cancellation removes the private partial file")

    let zero = folder.appendingPathComponent("empty"), zeroOut = folder.appendingPathComponent("empty-copy")
    try Data().write(to: zero); offered = nil; complete = false
    try a.offer(url: zero, to: "B"); pump(); b.accept(id: offered!.id, destination: zeroOut); pump()
    try Check.that(complete && (try Data(contentsOf: zeroOut)).isEmpty, "empty files transfer and validate")
}

func mouseSharingTests() throws {
    let a = MouseSharing(local: "A", native: false), b = MouseSharing(local: "B", native: false)
    defer { a.stop(); b.stop(); a.send = nil; b.send = nil }
    var messages: [(Bool, MousePacket)] = []
    a.send = { _, p, reply in messages.append((true, p)); reply(true) }
    b.send = { _, p, reply in messages.append((false, p)); reply(true) }
    a.displays = { [CGRect(x: 0, y: 0, width: 1000, height: 600)] }
    b.displays = { [CGRect(x: 0, y: 0, width: 2000, height: 1200)] }
    var now = Date().addingTimeInterval(2)
    func pump() {
        var limit = 100
        while !messages.isEmpty && limit > 0 {
            limit -= 1; let (toB, packet) = messages.removeFirst()
            if toB { b.receive(packet, from: "A", now: now) } else { a.receive(packet, from: "B", now: now) }
        }
    }
    a.setPeer("B"); b.setPeer("A"); pump()
    try Check.that(a.layout == b.layout && a.side != b.side, "initial screen layouts converge on complementary sides")
    a.setSide(.right); pump()
    try Check.that(a.side == .right && b.side == .left && a.layout == b.layout, "changing layout on one Mac updates both sides")
    let original = a.layout
    a.receive(MousePacket(kind: .layout, layout: ScreenLayout(revision: 999, author: "B", left: "A", right: "stranger")), from: "B")
    try Check.that(a.layout == original, "reject layout naming an unpaired device")
    try Check.that(!a.enabled && !b.enabled, "input control is off by default")
    let denied = UUID()
    b.receive(MousePacket(kind: .enter, token: denied, side: .left, fraction: 0.5), from: "A", now: now)
    try Check.that(b.mode == .local, "pairing alone cannot authorize mouse control"); pump()
    try a.setEnabled(true); try b.setEnabled(true); pump()
    func enter() {
        now = now.addingTimeInterval(2)
        _ = a.localMove(point: CGPoint(x: 999, y: 300), dx: 2, dy: 0, now: now)
        now = now.addingTimeInterval(0.2)
        _ = a.localMove(point: CGPoint(x: 999, y: 300), dx: 2, dy: 0, now: now); pump()
    }
    enter()
    try Check.that(a.mode == .controlling && b.mode == .receiving, "edge dwell and handshake transfer control")
    var lastPoint = CGPoint.zero, inputCount = 0, released: Set<Int> = []
    b.onInput = { _, point in lastPoint = point; inputCount += 1 }; b.onRelease = { released = $0 }
    _ = a.localMove(point: .zero, dx: 10, dy: 20, now: now); a.tick(now: now); pump()
    try Check.that(abs(lastPoint.y - 620) < 0.01 && lastPoint.x == 14, "entry height scales across different screen sizes")
    let count = inputCount
    b.receive(MousePacket(kind: .input, token: UUID(), action: .down), from: "A", now: now)
    try Check.that(inputCount == count, "ignore input from a stale control session")
    _ = a.localButton(action: .down, button: 0); pump()
    b.setPeer(nil)
    try Check.that(released == [0] && b.mode == .local, "disconnect releases all remotely held buttons")
    now = now.addingTimeInterval(3); a.tick(now: now)
    try Check.that(a.mode == .local, "missing heartbeat restores local control")
    try Check.that(!b.enabled, "disconnect revokes input consent for the lost peer")
    b.setPeer("A", savedLayout: a.layout); try b.setEnabled(true); pump(); enter()
    _ = a.localMove(point: .zero, dx: -20, dy: 0, now: now); a.tick(now: now); pump()
    try Check.that(a.mode == .local && b.mode == .local, "opposite edge returns control to source")
    enter(); a.emergencyStop(); pump()
    try Check.that(!a.enabled && a.mode == .local && b.mode == .local, "emergency stop disables edge capture and releases both peers")
    try a.setEnabled(true); pump(); enter()
    _ = b.localMove(point: CGPoint(x: 100, y: 100), dx: 1, dy: 0, now: now); pump()
    try Check.that(a.mode == .local && b.mode == .local, "physical receiver input reclaims control on both peers")
    now = now.addingTimeInterval(2)
    _ = a.localMove(point: CGPoint(x: 999, y: 300), dx: 2, dy: 0, now: now)
    now = now.addingTimeInterval(0.2)
    _ = a.localMove(point: CGPoint(x: 999, y: 300), dx: 2, dy: 0, now: now)
    _ = a.localButton(action: .down, button: 0); pump()
    try Check.that(a.mode == .local && b.mode == .local, "local click cancels pending handoff and late acceptance cannot recapture input")
    let internalEdge = ScreenGeometry.exit(at: CGPoint(x: 999, y: 300), deltaX: 2, side: .right, displays: [CGRect(x: 0, y: 0, width: 1000, height: 600), CGRect(x: 1000, y: 0, width: 1000, height: 600)])
    try Check.that(internalEdge == nil, "local multi-display seams do not hand off remotely")
    let entry = ScreenGeometry.entry(side: .left, fraction: 0.25, displays: [CGRect(x: -1600, y: -100, width: 1600, height: 1000), CGRect(x: 0, y: 0, width: 1000, height: 600)])!
    try Check.that(entry.0.x == -1596 && entry.0.y == 150, "support negative display origins and normalized height")
}

func featureNetworkTests() throws {
    let folder = try testFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.dat"), destination = folder.appendingPathComponent("copy.dat")
    let data = Data(repeating: 0x9A, count: 500_007); try data.write(to: source)
    let key = try PairCode.create(), idA = UUID().uuidString, idB = UUID().uuidString
    let a = try LocalTransport(code: key, device: idA, name: "File A", discovery: false)
    let b = try LocalTransport(code: key, device: idB, name: "File B", discovery: false)
    let fa = FileTransfer(), fb = FileTransfer()
    defer { fa.stop(); fb.stop(); a.stop(); b.stop() }
    var features: Set<String> = [], done = false
    b.onListening = { a.connectLoopback(port: $0, expected: idB) }
    a.onPeerDetails = { features = $0.first?.features ?? [] }
    fa.send = { peer, packet, reply in a.sendFeature(FeaturePacket(file: packet), to: peer, completion: reply) }
    fb.send = { peer, packet, reply in b.sendFeature(FeaturePacket(file: packet), to: peer, completion: reply) }
    a.onFeature = { peer, packet in if let file = packet.file { fa.receive(file, from: peer) } }
    b.onFeature = { peer, packet in if let file = packet.file { fb.receive(file, from: peer) } }
    fb.onOffer = { _, packet in fb.accept(id: packet.id, destination: destination) }
    fa.onComplete = { _ in done = true }
    a.start(); b.start(); waitFor({ a.peerCount == 1 && b.peerCount == 1 })
    try Check.that(features.contains(SharingFeature.files) && features.contains(SharingFeature.mouse), "authenticated ready negotiates file and mouse capabilities")
    try fa.offer(url: source, to: idB); waitFor({ done }, seconds: 10)
    try Check.that(done && (try Data(contentsOf: destination)) == data, "real encrypted TCP streams files through background I/O workers")
    var layoutArrived = false
    b.onFeature = { _, packet in layoutArrived = packet.mouse?.layout?.left == idA }
    a.sendFeature(FeaturePacket(mouse: MousePacket(kind: .layout, layout: ScreenLayout(revision: 1, author: idA, left: idA, right: idB))), to: idB)
    waitFor({ layoutArrived })
    try Check.that(layoutArrived, "screen layout crosses the authenticated network channel")
}

func legacyCapabilityTests() throws {
    let code = try PairCode.create(), local = UUID().uuidString, legacyID = UUID().uuidString
    let server = try LocalTransport(code: code, device: local, name: "New Mac", discovery: false)
    var old: PeerLink?, supported: Set<String>?, gotClip = false
    defer { old?.close(); server.stop() }
    let secret = try PairCode.key(code)
    server.onListening = { port in
        let connection = NWConnection(host: "127.0.0.1", port: port, using: LocalTransport.parameters())
        let link = PeerLink(connection: connection, secret: secret, device: legacyID, name: "Old Mac", advertisedFeatures: [])
        old = link; link.start()
    }
    server.onPeerDetails = { supported = $0.first?.features }
    server.onClip = { gotClip = $0.payload.data == Data("legacy".utf8) }
    server.start(); waitFor({ old?.authenticated == true && server.peerCount == 1 })
    try Check.that(supported == [], "clipboard-only peer authenticates without new capabilities")
    var rejected = false
    server.sendFeature(FeaturePacket(mouse: MousePacket(kind: .availability, enabled: false)), to: legacyID) { rejected = !$0 }
    try Check.that(rejected, "do not send new feature packets to clipboard-only peers")
    old?.send(ClipMessage(id: UUID(), stamp: ClipStamp(counter: 1, device: legacyID), payload: ClipPayload(type: "public.utf8-plain-text", data: Data("legacy".utf8))))
    waitFor({ gotClip }); try Check.that(gotClip, "clipboard transfer remains available to an older peer")
}

func mouseAdapterTests() throws {
    let token = UUID(), point = CGPoint(x: 123, y: 456)
    for (button, type) in [(0, CGEventType.leftMouseDown), (1, .rightMouseDown), (2, .otherMouseDown)] {
        let event = MouseSharing.makeEvent(MousePacket(kind: .input, token: token, action: .down, button: button, clicks: 2), at: point, pressed: [button])
        try Check.that(event?.type == type && event?.location == point && event?.getIntegerValueField(.mouseEventClickState) == 2, "native mouse button adapter preserves type, position and click count")
    }
    let drag = MouseSharing.makeEvent(MousePacket(kind: .input, token: token, action: .move, dx: 5, flags: CGEventFlags.maskShift.rawValue), at: point, pressed: [0])
    try Check.that(drag?.type == .leftMouseDragged && drag?.flags.contains(.maskShift) == true, "native movement adapter preserves dragging and allowed modifiers")
    try Check.that(drag?.getIntegerValueField(.eventSourceUserData) != 0, "native generated input carries an echo-suppression marker")
    let scroll = MouseSharing.makeEvent(MousePacket(kind: .input, token: token, action: .scroll, dy: 30), at: point, pressed: [])
    try Check.that(scroll?.type == .scrollWheel, "native scroll adapter creates a scroll event without posting it")
    try Check.that(MouseSharing.makeEvent(MousePacket(kind: .heartbeat, token: token), at: point, pressed: []) == nil, "control messages cannot become native input events")
}
