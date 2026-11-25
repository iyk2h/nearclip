import AppKit
import CryptoKit

// Isolated two-peer state machine; no event tap, system input, or clipboard.
final class InputFixture {
    let a = MouseSharing(local: "A", native: false)
    let b = MouseSharing(local: "B", native: false)
    var queue: [(Bool, FeaturePacket)] = []
    var inputs: [MousePacket] = []
    var gestures: [DockSwipePacket] = []
    var keys: [KeyboardPacket] = []
    var now = Date().addingTimeInterval(3)
    init() throws {
        a.displays = { [CGRect(x: 0, y: 0, width: 1000, height: 600)] }; b.displays = a.displays
        a.send = { [weak self] _, p, reply in self?.queue.append((true, FeaturePacket(mouse: p))); reply(true) }
        b.send = { [weak self] _, p, reply in self?.queue.append((false, FeaturePacket(mouse: p))); reply(true) }
        a.sendGesture = { [weak self] _, p, reply in self?.queue.append((true, FeaturePacket(gesture: p))); reply(true) }
        a.sendKeyboard = { [weak self] _, p, reply in self?.queue.append((true, FeaturePacket(keyboard: p))); reply(true) }
        b.onInput = { [weak self] p, _ in self?.inputs.append(p) }
        b.onGesture = { [weak self] p in self?.gestures.append(p) }
        b.onKeyboardInput = { [weak self] p in self?.keys.append(p) }
        a.setPeer("B", supportsKeyboard: true, supportsGestures: true)
        b.setPeer("A", supportsKeyboard: true, supportsGestures: true)
        try pump(); a.setSide(.right); try pump()
        try a.setEnabled(true); try b.setEnabled(true); try pump()
    }
    deinit { a.stop(); b.stop() }
    func pump() throws {
        var budget = 100
        while !queue.isEmpty, budget > 0 {
            budget -= 1
            let (toB, wire) = queue.removeFirst()
            let packet = try FeaturePacket.decode(wire.encoded()), target = toB ? b : a, sender = toB ? "A" : "B"
            if let mouse = packet.mouse { target.receive(mouse, from: sender, now: now) }
            if let keyboard = packet.keyboard { target.receiveKeyboard(keyboard, from: sender, now: now) }
            if let gesture = packet.gesture { target.receiveGesture(gesture, from: sender, now: now) }
        }
        guard queue.isEmpty else { throw ClipError.invalid("Fixture failed to settle") }
    }
    func enter() throws {
        now = now.addingTimeInterval(3)
        _ = a.localMove(point: CGPoint(x: 999, y: 300), dx: 2, dy: 0, now: now)
        now = now.addingTimeInterval(0.2)
        _ = a.localMove(point: CGPoint(x: 999, y: 300), dx: 2, dy: 0, now: now)
        try pump()
        try Check.that(a.mode == .controlling && b.mode == .receiving, "fixture has authenticated opt-in and accepted control")
    }
    func token() throws -> UUID {
        _ = a.localButton(action: .down, button: 0); _ = a.localButton(action: .up, button: 0)
        try pump()
        guard let token = inputs.last?.token else { throw ClipError.invalid("Missing fixture token") }
        return token
    }
}

func inputBoundaryTests() throws {
    for action in [MousePacket.Action.move, .down, .scroll] {
        let f = try InputFixture(); try f.enter(); let token = try f.token()
        let count = f.inputs.count
        f.b.secureInputEnabled = { true }
        f.b.receive(MousePacket(kind: .input, token: token, action: action, dx: 1, dy: 1), from: "A", now: f.now)
        try Check.that(f.inputs.count == count + (action == .scroll ? 0 : 1) && f.b.pointerOnly,
            "secure input allows plain pointer motion and clicks, and blocks scroll")
        try f.pump()
        try Check.that(f.a.pointerOnly && !f.a.keyboardActive, "both peers switch to pointer only")
        f.b.receiveKeyboard(KeyboardPacket(token: token, action: .down, keyCode: 0), from: "A")
        f.b.secureInputEnabled = { false }; f.b.tick(now: f.now); try f.pump()
        f.b.receiveKeyboard(KeyboardPacket(token: token, action: .up, keyCode: 0), from: "A")
        try Check.that(f.keys.isEmpty && f.b.pointerOnly, "old-token keys stay blocked after secure input clears")
        f.b.receive(MousePacket(kind: .input, token: token, action: .move, dx: 4, flags: 0x20000), from: "A")
        try Check.that(f.inputs.last?.flags == 0, "pointer only strips keyboard modifiers")
    }
    let f = try InputFixture()
    try f.enter()
    let token = try f.token()
    f.b.secureInputEnabled = { true }
    f.b.tick(now: f.now); try f.pump()
    for (dx, delay) in [(60.0, 0.0), (-100.0, 0.05), (-4.0, 0.22)] {
        f.b.receive(MousePacket(kind: .input, token: token, action: .move, dx: dx), from: "A", now: f.now.addingTimeInterval(delay))
    }
    try f.pump()
    try Check.that(f.a.mode == .local && f.b.mode == .local && f.a.lastEndReason == .returnEdge, "pointer returns home across the edge while Secure Input remains active")
}

func inputInterruptionTests() throws {
    for reason in [MouseSharing.Suspension.sleep, .displaySleep, .screenLock, .inactiveSession] {
        let f = try InputFixture(); try f.enter(); let token = try f.token()
        var released: Set<Int> = []
        f.b.onKeysReleased = { released = $0 }
        _ = f.a.localGesture(DockSwipePacket(token: token, axis: 2, phase: 1, progress: 0.2))
        _ = f.a.localKey(action: .down, keyCode: 0)
        try f.pump()
        f.b.suspend(reason); try f.pump()
        try Check.that(f.b.mode == .local && !f.b.enabled && f.b.sharingRequested,
            "\(reason) suspends capture while retaining the peer-scoped choice")
        try Check.that(released == [0] && f.gestures.last?.phase == 8,
            "\(reason) releases held keys and cancels the native swipe")
        let gestures = f.gestures.count, inputs = f.inputs.count
        let late = DockSwipePacket(token: token, axis: 2, phase: 2, progress: 0.5)
        f.b.receiveGesture(late, from: "A", now: f.now)
        f.b.receive(MousePacket(kind: .input, token: token, action: .down), from: "A", now: f.now)
        f.b.resume(reason); try f.pump()
        f.b.receiveGesture(late, from: "A", now: f.now)
        try Check.that(f.b.enabled && f.b.mode == .local && f.gestures.count == gestures && f.inputs.count == inputs,
            "\(reason) restores readiness without reviving old input or control")
    }
    let f = try InputFixture()
    f.b.suspend(.sleep); f.b.suspend(.screenLock)
    try f.b.setEnabled(false)
    f.b.resume(.sleep); f.b.resume(.screenLock)
    try Check.that(!f.b.enabled && !f.b.sharingRequested, "explicit off during overlapping suspension stays off after all resumes")
}

func fileRaceTests() throws {
    let folder = try testFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let destination = folder.appendingPathComponent("collision.bin")
    var writer: ReceivedFile? = try ReceivedFile(destination: destination)
    try writer?.append(Data([1, 2]), offset: 0, size: 2)
    try Data([9]).write(to: destination)
    try Check.rejects("destination created after acceptance is never overwritten") {
        try writer!.finish(size: 2, digest: Data(SHA256.hash(data: Data([1, 2]))))
    }
    writer = nil
    try Check.that(try Data(contentsOf: destination) == Data([9]), "racing destination keeps its original bytes")
    try Check.that(!(try FileManager.default.contentsOfDirectory(atPath: folder.path)).contains { $0.hasSuffix(".part") }, "failed atomic commit cleans partial data")
    let source = folder.appendingPathComponent("source.bin"); try Data([1, 2, 3]).write(to: source)
    let worker = FileTransferWorker(); defer { worker.stop() }
    var packets: [FilePacket] = [], completions: [(Bool) -> Void] = []
    worker.send = { _, packet, reply in packets.append(packet); completions.append(reply) }
    try worker.offer(url: source, to: "B")
    let old = worker.activeID!; worker.cancel()
    try worker.offer(url: source, to: "B"); let current = worker.activeID!
    completions[0](false)
    worker.receive(FilePacket(kind: .cancel, id: old), from: "B")
    worker.receive(FilePacket(kind: .cancel, id: current), from: "stranger")
    try Check.that(worker.busy && worker.activeID == current, "late send failure, stale cancel, and unknown peer cannot cancel a new transfer")
    worker.receive(FilePacket(kind: .accept, id: current), from: "B")
    worker.receive(FilePacket(kind: .ack, id: current, offset: 2), from: "B")
    try Check.that(!worker.busy, "wrong chunk acknowledgement cancels instead of skipping data")
    for growth in [true, false] {
        try Data([1, 2, 3]).write(to: source)
        try worker.offer(url: source, to: "B"); let id = worker.activeID!
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: growth ? 4 : 1); try handle.close()
        worker.receive(FilePacket(kind: .accept, id: id), from: "B")
        if let offset = packets.last(where: { $0.id == id && $0.kind == .chunk }).map({ ($0.offset ?? 0) + Int64($0.bytes?.count ?? 0) }) {
            worker.receive(FilePacket(kind: .ack, id: id, offset: offset), from: "B")
        }
        try Check.that(!worker.busy && !packets.contains { $0.id == id && $0.kind == .finish },
            "source \(growth ? "growth" : "truncation") is rejected before completion")
    }
}

func clipboardBoundaryTests() throws {
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    for marker in ClipboardCodec.ignored {
        board.clearContents(); board.setString("fixture confidential value", forType: .string)
        board.setData(Data(), forType: .init(marker))
        try Check.that(try ClipboardCodec.read(board) == nil && ClipboardCodec.read(board, allowRemote: true) == nil,
            "sensitive marker \(marker) is excluded from automatic and explicit sending")
    }
    board.clearContents(); board.setString("keep this fixture", forType: .string)
    let originalCount = board.changeCount
    try Check.rejects("invalid UTF-8 never replaces the local clipboard") {
        try ClipboardCodec.write(ClipPayload(type: "public.utf8-plain-text", data: Data([0xC0, 0xAF])), to: board, id: UUID())
    }
    let png = try fixturePNG()
    try Check.rejects("truncated PNG with readable dimensions is rejected") {
        try ClipboardCodec.write(ClipPayload(type: "public.png", data: png.dropLast(20)), to: board, id: UUID())
    }
    try Check.that(board.changeCount == originalCount && board.string(forType: .string) == "keep this fixture",
        "rejected text and image leave existing clipboard intact")
}

func finalBoundaryTests() throws {
    let png = try fixturePNG()
    try Check.that(ClipboardCodec.completePNG(png), "complete PNG chunk stream is accepted")
    try Check.that((0..<png.count).allSatisfy { !ClipboardCodec.completePNG(Data(png.prefix($0))) },
        "every truncated prefix is rejected without native clipboard access")
    var oversized = png; oversized.replaceSubrange(8..<12, with: [255, 255, 255, 255])
    try Check.that(!ClipboardCodec.completePNG(oversized), "oversized PNG chunk length is rejected before indexing or allocation")
    let f = try InputFixture(); try f.enter(); let token = try f.token()
    for axis in [1, 2] {
        for phase in [1, 2, 4] {
            try Check.that(f.a.localGesture(DockSwipePacket(token: token, axis: axis, phase: phase, progress: Double(phase) / 4)),
                "normal axis \(axis) phase \(phase) remains owned by remote control")
            try f.pump()
        }
    }
    try Check.that(f.gestures.map(\.phase) == [1, 2, 4, 1, 2, 4], "completed horizontal and vertical swipes can run back to back")
    let count = f.gestures.count
    f.b.tick(now: f.now.addingTimeInterval(9))
    try Check.that(f.gestures.count == count, "completed gestures are never cancelled twice on later session timeout")
}
