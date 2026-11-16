import AppKit

func gestureSharingTests() throws {
    let a = MouseSharing(local: "A", native: false), b = MouseSharing(local: "B", native: false)
    defer { a.stop(); b.stop(); a.send = nil; b.send = nil; a.sendGesture = nil }
    var queue: [(Bool, FeaturePacket)] = [], received: [DockSwipePacket] = []
    a.send = { _, p, reply in queue.append((true, FeaturePacket(mouse: p))); reply(true) }
    b.send = { _, p, reply in queue.append((false, FeaturePacket(mouse: p))); reply(true) }
    a.sendGesture = { _, p, reply in queue.append((true, FeaturePacket(gesture: p))); reply(true) }
    b.onGesture = { received.append($0) }
    a.displays = { [CGRect(x: 0, y: 0, width: 1000, height: 600)] }; b.displays = a.displays
    var now = Date().addingTimeInterval(3)
    func pump() throws {
        var limit = 100
        while !queue.isEmpty && limit > 0 {
            limit -= 1
            let (toB, wire) = queue.removeFirst()
            let packet = try FeaturePacket.decode(wire.encoded()), target = toB ? b : a, sender = toB ? "A" : "B"
            if let mouse = packet.mouse { target.receive(mouse, from: sender, now: now) }
            if let gesture = packet.gesture { target.receiveGesture(gesture, from: sender, now: now) }
        }
        try Check.that(queue.isEmpty, "gesture exchange settles")
    }
    let sample = DockSwipePacket(token: UUID(), axis: 1, phase: 1, progress: 0.01)
    try Check.that(!a.localGesture(sample), "disabled sharing leaves trackpad gestures local")
    a.setPeer("B", supportsGestures: true); b.setPeer("A", supportsGestures: true)
    try pump(); a.setSide(.right); try pump(); try a.setEnabled(true); try b.setEnabled(true); try pump()
    _ = a.localMove(point: CGPoint(x: 999, y: 300), dx: 2, dy: 0, now: now)
    now = now.addingTimeInterval(0.2)
    _ = a.localMove(point: CGPoint(x: 999, y: 300), dx: 2, dy: 0, now: now)
    try pump()
    try Check.that(a.mode == .controlling && b.mode == .receiving, "gesture requires accepted pointer handoff")
    try Check.that(a.localGesture(sample), "Dock swipe is consumed only during remote control")
    try pump()
    try Check.that(a.localGesture(sample), "duplicate begin stays suppressed on the source Mac")
    try pump()
    try Check.that(received.count == 1, "duplicate begin is not forwarded to the Dock")
    let token = received[0].token
    let change = DockSwipePacket(token: token, axis: 1, phase: 2, progress: 0.5, velocityX: 2)
    b.receiveGesture(change, from: "stranger", now: now)
    b.receiveGesture(sample, from: "A", now: now)
    try Check.that(received.count == 1, "unpaired sender and stale token cannot inject gestures")
    _ = a.localGesture(change); try pump()
    try Check.that(received.map(\.phase) == [1, 2], "continuous progress survives authenticated feature codec")
    let stalled = now.addingTimeInterval(9)
    b.receive(MousePacket(kind: .heartbeat, token: token), from: "A", now: stalled)
    b.tick(now: stalled)
    try Check.that(b.mode == .local && received.last?.phase == 8, "missing gesture end is cancelled even while heartbeats continue")
    a.endSession(); try pump()
    try Check.that(received.last?.phase == 8, "disconnect or return cancels in-flight Dock animation")
    b.receiveGesture(change, from: "A", now: now)
    try Check.that(received.count == 3, "gesture cannot continue after control ends")
    let events = DockSwipeAdapter.events(change, at: CGPoint(x: 100, y: 200), marker: 123)
    let decoded = events.first.flatMap { DockSwipeAdapter.read($0, token: token) }
    try Check.that(events.count == 2 && decoded?.progress == 0.5 && decoded?.phase == 2 && decoded?.axis == 1,
        "native Dock event fields round-trip without posting system input")
    try Check.that(events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == 123 }, "generated gesture events carry loop prevention marker")
    try Check.that(DockSwipeAdapter.read(CGEvent(source: nil)!, token: token) == nil, "ordinary events never become gestures")
    for bad in [DockSwipePacket(token: token, axis: 3, phase: 1, progress: 0),
                DockSwipePacket(token: token, axis: 1, phase: 128, progress: 0),
                DockSwipePacket(token: token, axis: 1, phase: 1, progress: .nan),
                DockSwipePacket(token: token, axis: 1, phase: 1, progress: 17)] {
        try Check.that((try? bad.validate()) == nil, "reject unknown axis/phase and nonfinite or oversized gesture progress")
    }
    a.setPeer("B", supportsGestures: false)
    try Check.that(!a.gesturesSupported && !a.localGesture(sample), "legacy peers keep gestures local")
}
