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
    let reasonPacket = MousePacket(kind: .leave, token: UUID(), endReason: MouseEndReason.localMotion.rawValue)
    let reasonRoundTrip = try FeaturePacket.decode(FeaturePacket(mouse: reasonPacket).encoded())
    try Check.that(reasonRoundTrip.mouse?.endReason == "localMotion", "handoff reason survives the wire codec")
    let legacy = try JSONDecoder().decode(MousePacket.self, from: Data("{\"kind\":\"leave\",\"token\":\"00000000-0000-0000-0000-000000000001\",\"dx\":0,\"dy\":0,\"button\":0,\"clicks\":1,\"flags\":0}".utf8))
    try legacy.validate()
    try Check.that(legacy.endReason == nil, "older peers can omit the optional handoff reason")
    try Check.that(legacy.scrollPhase == nil && legacy.momentumPhase == nil, "older peers can omit scroll phase metadata")
    for (phase, momentum) in [(1, 0), (2, 0), (4, 0), (8, 0), (128, 0), (0, 1), (0, 2), (0, 3)] {
        let scroll = MousePacket(kind: .input, token: UUID(), action: .scroll, dx: 0, dy: 0, scrollPhase: phase, momentumPhase: momentum)
        let decoded = try FeaturePacket.decode(FeaturePacket(mouse: scroll).encoded()).mouse!
        let event = MouseSharing.makeEvent(decoded, at: .zero, pressed: [])
        try Check.that(event?.getIntegerValueField(.scrollWheelEventScrollPhase) == Int64(phase) &&
                       event?.getIntegerValueField(.scrollWheelEventMomentumPhase) == Int64(momentum),
                       "scroll begin/change/end and momentum survive transport and native event construction, including zero-delta boundaries")
    }
    for bad in [MousePacket(kind: .input, token: UUID(), action: .scroll, scrollPhase: 99),
                MousePacket(kind: .input, token: UUID(), action: .scroll, momentumPhase: -1),
                MousePacket(kind: .input, token: UUID(), action: .move, scrollPhase: 1)] {
        try Check.rejects("reject unsupported scroll phase fields") { try bad.validate() }
    }
    try Check.rejects("bound untrusted handoff reason length") {
        try MousePacket(kind: .leave, token: UUID(), endReason: String(repeating: "x", count: 65)).validate()
    }
    let file = FilePacket(kind: .offer, id: UUID(), name: "test.txt", size: 12)
    let decoded = try FeaturePacket.decode(FeaturePacket(file: file).encoded())
    try Check.that(decoded.file?.name == "test.txt", "platform-neutral sharing packet round trip")
    try Check.rejects("reject mixed feature payloads") { _ = try FeaturePacket(file: file, mouse: MousePacket(kind: .availability, enabled: true)).encoded() }
    let a = Hello.make(device: UUID().uuidString, name: "A"), b = Hello.make(device: UUID().uuidString, name: "B")
    let key = try PairCode.key(PairCode.create())
    let inputKey = try PeerLink.inputKey(secret: key, local: a, remote: b)
    let reverseKey = try PeerLink.inputKey(secret: key, local: b, remote: a)
    let inputTX = try SessionCipher(secret: inputKey, local: a, remote: b)
    let inputRX = try SessionCipher(secret: reverseKey, local: b, remote: a)
    let inputFrame = try inputTX.seal(kind: "ping")
    try Check.that(try inputRX.open(inputFrame).kind == "ping", "both directions derive the same session-bound input secret")
    try Check.rejects("input secret cannot be used on the bulk channel") {
        _ = try SessionCipher(secret: key, local: b, remote: a).open(inputFrame)
    }
    try Check.rejects("reconnected parent cannot decrypt an old input channel") {
        let next = Hello.make(device: a.device, name: a.name)
        let nextKey = try PeerLink.inputKey(secret: key, local: next, remote: b)
        _ = try SessionCipher(secret: nextKey, local: b, remote: a).open(inputFrame)
    }
    try Check.rejects("input frame replay is rejected") { _ = try inputRX.open(inputFrame) }
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
    let permissionStates = (0..<8).map { MousePermissions(accessibility: $0 & 1 != 0, posting: $0 & 2 != 0, monitoring: $0 & 4 != 0) }
    try Check.that(permissionStates.enumerated().allSatisfy { $0.element.granted == ($0.offset == 7) }, "input permission gate requires all three approvals")
    try Check.that(permissionStates[3].missing == ["입력 모니터링"], "permission guidance identifies missing input monitoring")
    try Check.that(permissionStates[5].missing == ["손쉬운 사용의 입력 제어"], "permission guidance distinguishes event posting from accessibility trust")
    try Check.that(permissionStates[7].missing.isEmpty, "fully authorized input has no missing permission")

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
    func enter() throws {
        now = now.addingTimeInterval(2)
        let x: Double = a.side == .right ? 999 : 0
        let dx: Double = a.side == .right ? 2 : -2
        _ = a.localMove(point: CGPoint(x: x, y: 300), dx: dx, dy: 0, now: now)
        now = now.addingTimeInterval(0.2)
        _ = a.localMove(point: CGPoint(x: x, y: 300), dx: dx, dy: 0, now: now); pump()
        try Check.that(a.mode == .controlling && b.mode == .receiving, "each mouse scenario starts with an accepted handoff")
    }
    try enter()
    try Check.that(a.mode == .controlling && b.mode == .receiving, "edge dwell and handshake transfer control")
    try Check.that(a.maintenanceInterval! < 0.01 && b.maintenanceInterval == 0.1, "high-frequency maintenance runs only on the controlling sender")
    _ = a.localMove(point: .zero, dx: -20, dy: 0, now: now); now = now.addingTimeInterval(0.01); a.tick(now: now); pump()
    try Check.that(a.mode == .controlling && b.mode == .receiving, "reverse jitter immediately after entry does not bounce control back")
    a.endSession(); pump(); try enter()
    _ = b.localMove(point: CGPoint(x: 4, y: 600), dx: 0, dy: 0, now: now); pump()
    try Check.that(a.mode == .controlling && b.mode == .receiving, "zero-distance receiver motion does not cancel handoff")
    var lastPoint = CGPoint.zero, inputCount = 0, released: Set<Int> = []
    b.onInput = { _, point in lastPoint = point; inputCount += 1 }; b.onRelease = { released = $0 }
    _ = a.localMove(point: .zero, dx: 10, dy: 20, now: now); now = now.addingTimeInterval(0.01); a.tick(now: now); pump()
    try Check.that(abs(lastPoint.y - 620) < 0.01 && lastPoint.x == 14, "entry height scales across different screen sizes")
    let count = inputCount
    b.receive(MousePacket(kind: .input, token: UUID(), action: .down), from: "A", now: now)
    try Check.that(inputCount == count, "ignore input from a stale control session")
    _ = a.localButton(action: .down, button: 0); pump()
    b.setPeer(nil)
    try Check.that(released == [0] && b.mode == .local, "disconnect releases all remotely held buttons")
    now = now.addingTimeInterval(3); a.tick(now: now)
    try Check.that(a.mode == .local, "missing heartbeat restores local control")
    try Check.that(a.maintenanceInterval == 1, "return to local control restores the low-frequency permission watchdog")
    try Check.that(a.lastEndReason == .timeout && !a.endedByPeer, "watchdog records the local timeout reason")
    try Check.that(!b.enabled, "disconnect removes input capture for the lost peer")
    b.setPeer("A", savedLayout: a.layout); try b.setEnabled(true); try a.setEnabled(true); pump(); try enter()
    _ = a.localMove(point: .zero, dx: 40, dy: 0, now: now); now = now.addingTimeInterval(0.01); a.tick(now: now); pump()
    _ = a.localMove(point: .zero, dx: -80, dy: 0, now: now); now = now.addingTimeInterval(0.01); a.tick(now: now); pump()
    try Check.that(a.mode == .controlling && b.mode == .receiving, "one reverse movement at the return edge cannot end control")
    now = now.addingTimeInterval(0.5)
    _ = a.localMove(point: .zero, dx: -2, dy: 0, now: now); now = now.addingTimeInterval(0.01); a.tick(now: now); pump()
    try Check.that(a.mode == .controlling, "separated edge taps do not accumulate into a return")
    now = now.addingTimeInterval(0.2)
    _ = a.localMove(point: .zero, dx: -2, dy: 0, now: now); now = now.addingTimeInterval(0.01); a.tick(now: now); pump()
    try Check.that(a.mode == .local && b.mode == .local, "opposite edge returns control to source")
    try Check.that(a.lastEndReason == .returnEdge && a.endedByPeer && b.lastEndReason == .returnEdge, "return-edge reason reaches the controlling peer")
    try enter(); a.emergencyStop(); pump()
    try Check.that(!a.enabled && a.mode == .local && b.mode == .local, "emergency stop disables edge capture and releases both peers")
    try a.setEnabled(true); pump(); try enter()
    _ = b.localMove(point: CGPoint(x: 100, y: 100), dx: 1, dy: 0, now: now); pump()
    try Check.that(a.mode == .local && b.mode == .local, "physical receiver input reclaims control on both peers")
    try Check.that(a.lastEndReason == .localMotion && a.endedByPeer && !b.endedByPeer, "physical takeover identifies which Mac ended control")
    try enter()
    try Check.that(a.lastEndMessage == nil && b.lastEndMessage == nil, "new handoff clears stale diagnostic text")
    a.endSession(); pump()

    now = now.addingTimeInterval(2)
    _ = a.localMove(point: CGPoint(x: 999, y: 300), dx: 2, dy: 0, now: now)
    now = now.addingTimeInterval(0.2)
    _ = a.localMove(point: CGPoint(x: 999, y: 300), dx: 2, dy: 0, now: now)
    _ = a.localButton(action: .down, button: 0); pump()
    try Check.that(a.mode == .local && b.mode == .local, "local click cancels pending handoff and late acceptance cannot recapture input")
    a.setSide(.left); pump(); try enter()
    _ = b.localMove(point: CGPoint(x: 1996, y: 600), dx: 0, dy: 0, now: now); pump()
    _ = a.localMove(point: .zero, dx: -10, dy: 0, now: now); now = now.addingTimeInterval(0.01); a.tick(now: now); pump()
    try Check.that(a.mode == .controlling && b.mode == .receiving && lastPoint.x == 1986, "leftward handoff survives position-only events and moves into the peer screen")
    _ = a.localMove(point: .zero, dx: -30, dy: 0, now: now); now = now.addingTimeInterval(0.01); a.tick(now: now); pump()
    _ = a.localMove(point: .zero, dx: 80, dy: 0, now: now); now = now.addingTimeInterval(0.01); a.tick(now: now); pump()
    try Check.that(a.mode == .controlling, "right return edge also requires a deliberate push")
    // Moving away cancels the pending return, even if its previous dwell elapsed.
    now = now.addingTimeInterval(0.2)
    _ = a.localMove(point: .zero, dx: -10, dy: 0, now: now); now = now.addingTimeInterval(0.01); a.tick(now: now); pump()
    _ = a.localMove(point: .zero, dx: 30, dy: 0, now: now); now = now.addingTimeInterval(0.01); a.tick(now: now); pump()
    try Check.that(a.mode == .controlling, "moving inward resets the return dwell")
    now = now.addingTimeInterval(0.2)
    _ = a.localMove(point: .zero, dx: 2, dy: 0, now: now); now = now.addingTimeInterval(0.01); a.tick(now: now); pump()
    try Check.that(a.mode == .local && b.mode == .local && a.lastEndReason == .returnEdge, "right edge returns from a leftward handoff")
    try enter()
    _ = a.localMove(point: .zero, dx: 50, dy: 0, now: now); now = now.addingTimeInterval(0.01); a.tick(now: now); pump()
    now = now.addingTimeInterval(0.2)
    _ = a.localMove(point: .zero, dx: 2, dy: 0, now: now); now = now.addingTimeInterval(0.01); a.tick(now: now); pump()
    try Check.that(a.mode == .controlling, "a new handoff cannot reuse the previous session's return arming")
    _ = b.localMove(point: .zero, dx: 0, dy: 1, now: now); pump()
    try Check.that(a.mode == .local && b.mode == .local && a.lastEndReason == .localMotion, "vertical receiver motion still reclaims control immediately")
    let internalEdge = ScreenGeometry.exit(at: CGPoint(x: 999, y: 300), deltaX: 2, side: .right, displays: [CGRect(x: 0, y: 0, width: 1000, height: 600), CGRect(x: 1000, y: 0, width: 1000, height: 600)])
    try Check.that(internalEdge == nil, "local multi-display seams do not hand off remotely")
    let entry = ScreenGeometry.entry(side: .left, fraction: 0.25, displays: [CGRect(x: -1600, y: -100, width: 1600, height: 1000), CGRect(x: 0, y: 0, width: 1000, height: 600)])!
    try Check.that(entry.0.x == -1596 && entry.0.y == 150, "support negative display origins and normalized height")
}

func mousePacingTests() throws {
    let mouse = MouseSharing(local: "A", native: false)
    defer { mouse.stop() }
    var sent: [MousePacket] = []
    mouse.send = { _, packet, reply in sent.append(packet); reply(true) }
    mouse.displays = { [CGRect(x: 0, y: 0, width: 1000, height: 600)] }
    mouse.setPeer("B"); mouse.setSide(.right); try mouse.setEnabled(true)
    mouse.receive(MousePacket(kind: .availability, enabled: true), from: "B")
    var now = Date().addingTimeInterval(2)
    func enter() throws {
        _ = mouse.localMove(point: CGPoint(x: 999, y: 300), dx: 2, dy: 0, now: now)
        now = now.addingTimeInterval(0.2)
        _ = mouse.localMove(point: CGPoint(x: 999, y: 300), dx: 2, dy: 0, now: now)
        let token = sent.last(where: { $0.kind == .enter })!.token
        mouse.receive(MousePacket(kind: .accepted, token: token), from: "B", now: now)
        try Check.that(mouse.mode == .controlling, "pacing test starts with accepted control")
        sent = []
    }
    try enter()
    _ = mouse.localMove(point: .zero, dx: 1, dy: 2, now: now)
    try Check.that(sent.count == 1 && sent[0].dx == 1, "first cursor movement is sent without waiting for a timer tick")
    for step in 1...8 {
        _ = mouse.localMove(point: .zero, dx: 1, dy: 2, now: now.addingTimeInterval(Double(step) / 1000))
    }
    try Check.that(sent.count == 1, "1000 Hz device burst is coalesced within one 120 Hz update interval")
    mouse.tick(now: now.addingTimeInterval(0.009))
    var moves = sent.filter { $0.action == .move }
    try Check.that(moves.count == 2 && moves.reduce(0) { $0 + $1.dx } == 9 && moves.reduce(0) { $0 + $1.dy } == 18,
                   "timer drains the final movement sample without dropping distance")
    now = now.addingTimeInterval(0.010)
    _ = mouse.localMove(point: .zero, dx: 3, dy: 0, now: now)
    _ = mouse.localButton(action: .down, button: 0)
    let input = sent.filter { $0.kind == .input }
    try Check.that(input.suffix(2).map(\.action) == [.move, .down] && input[input.count - 2].dx == 3,
                   "click flushes pending movement before the button event")
    now = now.addingTimeInterval(0.5)
    let before = sent.count
    _ = mouse.localMove(point: .zero, dx: 1, dy: 0, now: now)
    try Check.that(sent.count == before + 1, "movement after an idle interval also has no timer wait")
    _ = mouse.localMove(point: .zero, dx: 2, dy: 0, now: now.addingTimeInterval(0.001))
    _ = mouse.localMove(point: .zero, dx: 3, dy: 0, flags: 0x20000, now: now.addingTimeInterval(0.002))
    mouse.tick(now: now.addingTimeInterval(0.012))
    moves = sent.filter { $0.action == .move }
    try Check.that(moves.suffix(2).map(\.flags) == [0, 0x20000] && moves.suffix(2).map(\.dx) == [2, 3],
                   "movement batching does not merge across modifier changes")
    var pendingReplies: [(Bool) -> Void] = []
    mouse.send = { _, packet, reply in
        sent.append(packet)
        if packet.action == .move { pendingReplies.append(reply) } else { reply(true) }
    }
    sent = []; now = now.addingTimeInterval(0.02)
    _ = mouse.localMove(point: .zero, dx: 1, dy: 0, now: now)
    for step in 1...100 {
        let sample = now.addingTimeInterval(Double(step) / 1000)
        _ = mouse.localMove(point: .zero, dx: 1, dy: 0, now: sample); mouse.tick(now: sample)
    }
    try Check.that(sent.filter { $0.action == .move }.count == 1 && pendingReplies.count == 1,
                   "slow transport holds only one normal movement packet instead of filling its queue")
    pendingReplies.removeFirst()(true)
    now = now.addingTimeInterval(0.11); mouse.tick(now: now)
    try Check.that(sent.last?.dx == 100, "accumulated movement drains after transport becomes writable")
    _ = mouse.localMove(point: .zero, dx: 2, dy: 0, now: now.addingTimeInterval(0.001))
    _ = mouse.localButton(action: .down, button: 0)
    try Check.that(sent.suffix(2).map(\.action) == [.move, .down], "click ordering is preserved even with movement in flight")
    mouse.endSession(); now = now.addingTimeInterval(2); try enter()
    pendingReplies.forEach { $0(false) }
    try Check.that(mouse.mode == .controlling, "late failed movement completion cannot end a newer control session")
    let count = sent.count
    mouse.secureInputEnabled = { true }
    _ = mouse.localMove(point: .zero, dx: 20, dy: 0, now: now)
    try Check.that(mouse.mode == .local && sent.dropFirst(count).allSatisfy { $0.action != .move },
                   "immediate movement dispatch still honors Secure Event Input")
}

func mouseResumeTests() throws {
    let mouse = MouseSharing(local: "A", native: false)
    defer { mouse.stop() }
    mouse.setPeer("B", supportsKeyboard: true)
    try mouse.setEnabled(true)
    mouse.receive(MousePacket(kind: .availability, enabled: true, keyboardEnabled: true), from: "B")
    let token = UUID(), now = Date().addingTimeInterval(2)
    mouse.receive(MousePacket(kind: .enter, token: token, side: .left, fraction: 0.5), from: "B", now: now)
    var buttonsReleased: Set<Int> = [], keysReleased: Set<Int> = []
    mouse.onRelease = { buttonsReleased = $0 }; mouse.onKeysReleased = { keysReleased = $0 }
    mouse.receive(MousePacket(kind: .input, token: token, action: .down), from: "B", now: now)
    mouse.receiveKeyboard(KeyboardPacket(token: token, action: .down, keyCode: 0), from: "B", now: now)
    mouse.suspend(.sleep)
    try Check.that(!mouse.enabled && mouse.sharingRequested && mouse.mode == .local && buttonsReleased == [0] && keysReleased == [0],
                   "sleep removes capture and releases held input while retaining the peer-specific choice")
    mouse.suspend(.screenLock); mouse.suspend(.displaySleep); mouse.suspend(.inactiveSession)
    mouse.setPeer(nil); mouse.setPeer("B", supportsKeyboard: true)
    mouse.resume(.sleep); mouse.resume(.displaySleep); mouse.resume(.inactiveSession)
    try Check.that(!mouse.enabled && mouse.sharingRequested, "reconnect and wake cannot resume while the screen remains locked")
    try Check.rejects("manual enable cannot bypass a suspended session") { try mouse.setEnabled(true) }
    mouse.resume(.screenLock)
    try Check.that(mouse.enabled && mouse.mode == .local && !mouse.remoteEnabled, "unlock restores readiness, never the old control session or peer opt-in")
    var inputCount = 0; mouse.onInput = { _, _ in inputCount += 1 }
    mouse.receive(MousePacket(kind: .input, token: token, action: .move, dx: 1), from: "B")
    try Check.that(inputCount == 0, "pre-sleep input token cannot control the resumed Mac")
    mouse.setPeer(nil)
    try Check.that(!mouse.enabled && mouse.sharingRequested, "temporary network loss preserves requested sharing without capturing input")
    mouse.setPeer("B", supportsKeyboard: true)
    try Check.that(mouse.enabled, "same authenticated peer reconnect restores requested sharing")
    mouse.suspend(.sleep); mouse.emergencyStop(); mouse.resume(.sleep)
    mouse.setPeer(nil); mouse.setPeer("B")
    try Check.that(!mouse.enabled && !mouse.sharingRequested, "explicit emergency stop stays off after wake and reconnect")
    try mouse.setEnabled(true); mouse.setPeer(nil); mouse.setPeer("C")
    try Check.that(!mouse.enabled && !mouse.sharingRequested, "a different peer does not inherit input consent")
    mouse.setPeer("B")
    try Check.that(!mouse.enabled, "returning to the old peer after replacement does not revive consent")
    try mouse.setEnabled(true); mouse.suspend(.sleep); mouse.resume(.sleep)
    mouse.suspend(.sleep); mouse.resume(.sleep)
    try Check.that(mouse.enabled, "repeated sleep cycles preserve the selected sharing state")
    mouse.stop(); mouse.setPeer(nil); mouse.setPeer("B")
    try Check.that(!mouse.enabled && !mouse.sharingRequested, "pause and shutdown stop clear the resume choice")
}

func featureNetworkTests() throws {
    let folder = try testFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.dat"), destination = folder.appendingPathComponent("copy.dat")
    let data = Data(repeating: 0x9A, count: 8 * 1024 * 1024 + 7); try data.write(to: source)
    let key = try PairCode.create(), idA = UUID().uuidString, idB = UUID().uuidString
    let a = try LocalTransport(code: key, device: idA, name: "File A", discovery: false)
    let b = try LocalTransport(code: key, device: idB, name: "File B", discovery: false)
    let fa = FileTransfer(), fb = FileTransfer()
    defer { fa.stop(); fb.stop(); a.stop(); b.stop() }
    var features: Set<String> = [], done = false, inputDuringFile = false, inputSent = false
    b.onListening = { a.connectLoopback(port: $0, expected: idB) }
    a.onPeerDetails = { features = $0.first?.features ?? [] }
    fa.send = { peer, packet, reply in a.sendFeature(FeaturePacket(file: packet), to: peer, completion: reply) }
    fb.send = { peer, packet, reply in b.sendFeature(FeaturePacket(file: packet), to: peer, completion: reply) }
    a.onFeature = { peer, packet in if let file = packet.file { fa.receive(file, from: peer) } }
    b.onFeature = { peer, packet in
        if let file = packet.file {
            fb.receive(file, from: peer)
            if file.kind == .chunk && !inputSent {
                inputSent = true
                a.sendFeature(FeaturePacket(mouse: MousePacket(kind: .availability, enabled: false)), to: idB)
            }
        } else if packet.mouse?.kind == .availability { inputDuringFile = !done }
    }
    fb.onOffer = { _, packet in fb.accept(id: packet.id, destination: destination) }
    fa.onComplete = { _ in done = true }
    a.start(); b.start(); waitFor({ a.peerCount == 1 && b.peerCount == 1 })
    try Check.that(features.contains(SharingFeature.files) && features.contains(SharingFeature.mouse), "authenticated ready negotiates file and mouse capabilities")
    try fa.offer(url: source, to: idB); waitFor({ done }, seconds: 10)
    try Check.that(done && (try Data(contentsOf: destination)) == data, "real encrypted TCP streams files through background I/O workers")
    try Check.that(inputDuringFile, "input arrives during an 8 MiB streamed file without waiting for completion")
    var layoutArrived = false
    b.onFeature = { _, packet in layoutArrived = packet.mouse?.layout?.left == idA }
    a.sendFeature(FeaturePacket(mouse: MousePacket(kind: .layout, layout: ScreenLayout(revision: 1, author: idA, left: idA, right: idB))), to: idB)
    waitFor({ layoutArrived })
    try Check.that(layoutArrived, "screen layout crosses the authenticated network channel")
    var keyboardArrived = false
    b.onFeature = { _, packet in keyboardArrived = packet.keyboard?.keyCode == 8 }
    a.sendFeature(FeaturePacket(keyboard: KeyboardPacket(token: UUID(), action: .down, keyCode: 8, flags: 0x100000)), to: idB)
    waitFor({ keyboardArrived })
    try Check.that(keyboardArrived && features.contains(SharingFeature.keyboard), "keyboard packets cross negotiated encrypted TCP without posting system input")
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
    rejected = false
    server.sendFeature(FeaturePacket(keyboard: KeyboardPacket(token: UUID(), action: .down, keyCode: 0)), to: legacyID) { rejected = !$0 }
    try Check.that(rejected, "do not send keyboard packets to peers without keyboard capability")
    old?.send(ClipMessage(id: UUID(), stamp: ClipStamp(counter: 1, device: legacyID), payload: ClipPayload(type: "public.utf8-plain-text", data: Data("legacy".utf8))))
    waitFor({ gotClip }); try Check.that(gotClip, "clipboard transfer remains available to an older peer")
    old?.close(); server.stop()
    var legacyInput = false
    server.onListening = { port in
        let link = PeerLink(connection: NWConnection(host: "127.0.0.1", port: port, using: LocalTransport.parameters()),
            secret: secret, device: legacyID, name: "Build 15", advertisedFeatures: [SharingFeature.mouse, SharingFeature.keyboard, SharingFeature.files])
        old = link
        link.onFeature = { _, packet in legacyInput = packet.mouse?.kind == .availability }
        link.start()
    }
    server.start(); waitFor({ old?.ready == true && server.peerCount == 1 })
    try Check.that(server.peerCount == 1 && server.separateInputPeerCount == 0, "older input peers retain the single-channel protocol")
    server.sendFeature(FeaturePacket(mouse: MousePacket(kind: .availability, enabled: false)), to: legacyID)
    waitFor({ legacyInput })
    try Check.that(legacyInput, "mouse availability reaches an older peer without a channel upgrade")
    old?.close(); server.stop()

    // Exercise the two physical connections and either-socket cleanup directly.
    server.onListening = { port in
        let link = PeerLink(connection: NWConnection(host: "127.0.0.1", port: port, using: LocalTransport.parameters()),
            secret: secret, device: legacyID, name: "Split input", advertisedFeatures: [SharingFeature.files, SharingFeature.mouse, SharingFeature.keyboard, SharingFeature.inputChannel])
        old = link; link.start()
    }
    server.start(); waitFor({ old?.hasSeparateInput == true && server.peerCount == 1 })
    try Check.that(old?.inputLink?.connection !== old?.connection && old?.hasSeparateInput == true, "input and bulk use distinct TCP connections")
    var fileRejected = false
    old?.inputLink?.sendFeature(FeaturePacket(file: FilePacket(kind: .cancel, id: UUID()))) { fileRejected = !$0 }
    try Check.that(fileRejected, "input channel rejects file packets")
    gotClip = false
    old?.inputLink?.send(ClipMessage(id: UUID(), stamp: ClipStamp(counter: 2, device: legacyID), payload: ClipPayload(type: "public.utf8-plain-text", data: Data("legacy".utf8))))
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    try Check.that(!gotClip, "input channel cannot send clipboard content")
    old?.inputLink?.close()
    waitFor({ old?.closed == true && server.peerCount == 0 })
    try Check.that(old?.closed == true && server.peerCount == 0, "input disconnect invalidates both peers and ends the parent session")
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
