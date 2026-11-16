import AppKit

func gestureSharingTests() throws {
    try Check.that(DockSwipeAdapter.supportedMajor(productVersion: "15.7.2", reportedMajor: 10) == 15,
        "kernel product version overrides SDK compatibility major 10")
    try Check.that(DockSwipeAdapter.supportedMajor(productVersion: nil, reportedMajor: 15) == 15,
        "unavailable kernel product version falls back to Foundation")
    try Check.that(DockSwipeAdapter.supportedMajor(productVersion: "invalid", reportedMajor: 15) == 15,
        "malformed kernel product version does not disable a known Foundation version")
    try Check.that(DockSwipeAdapter.eventMask & (1 << 29) != 0 && DockSwipeAdapter.eventMask & (1 << 30) != 0,
        "event tap observes both Dock-control and companion gesture events")
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
    try Check.that(DockSwipeAdapter.supports(major: 27) && !DockSwipeAdapter.supports(major: 28),
        "macOS 27 negotiates gestures while unknown native layouts remain disabled")
    func integer(_ data: Data, _ offset: Int, _ size: Int) -> UInt64 {
        (0..<size).reduce(0) { $0 | (UInt64(data[offset + $1]) << ($1 * 8)) }
    }
    for axis in [1, 2] {
        for phase in [1, 2, 4, 8] {
            let packet = DockSwipePacket(token: token, axis: axis, phase: phase, progress: -0.5, velocityX: 2, velocityY: -3)
            let payload = DockSwipeAdapter.hidPayload(packet, timestamp: 123)!
            try Check.that(payload.count == 96 && integer(payload, 0, 8) == 123 && integer(payload, 24, 4) == 2 &&
                integer(payload, 28, 4) == 40 && integer(payload, 32, 4) == 23 && integer(payload, 36, 4) == UInt64(phase) << 24 &&
                integer(payload, 60, 2) == UInt64(axis) && integer(payload, 62, 2) == 3 &&
                integer(payload, 64, 4) == UInt64(UInt32(bitPattern: -32768)) &&
                integer(payload, 68, 4) == 28 && integer(payload, 72, 4) == 9 && integer(payload, 80, 4) == 1 &&
                integer(payload, 84, 4) == 131072 && integer(payload, 88, 4) == UInt64(UInt32(bitPattern: -196608)),
                "modern HID payload preserves axis, phase, signed progress and velocity with fixed byte offsets")
            let modern = DockSwipeAdapter.events(packet, at: CGPoint(x: 100, y: 200), marker: 123, osMajor: 27, naturalScrolling: true)
            let reread = modern.first.flatMap { DockSwipeAdapter.read($0, token: token) }
            try Check.that(modern.count == 2 && reread?.axis == axis && reread?.phase == phase && reread?.progress == (axis == 1 ? 0.5 : -0.5) &&
                modern.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == 123 },
                "modern native event conversion retains gesture fields and echo marker without posting")
        }
    }
    let tiny = DockSwipePacket(token: token, axis: 1, phase: 2, progress: -0.0000001)
    let minimal = DockSwipeAdapter.hidPayload(tiny, timestamp: 1)!
    try Check.that(minimal.count == 68 && integer(minimal, 24, 4) == 1 && integer(minimal, 64, 4) == UInt64(UInt32.max),
        "modern payload omits unused velocity and preserves sub-unit progress sign")
    let ended = DockSwipePacket(token: token, axis: 1, phase: 4, progress: 0)
    try Check.that(DockSwipeAdapter.hidPayload(ended, timestamp: 1)?.count == 96,
        "ended gesture carries the velocity child even at zero velocity")
    try Check.that(DockSwipeAdapter.hidPayload(DockSwipePacket(token: token, axis: 1, phase: 2, progress: .nan), timestamp: 1) == nil &&
        DockSwipeAdapter.events(sample, at: .zero, marker: 123, osMajor: 28).isEmpty,
        "invalid packets and unsupported OS layouts cannot construct modern native events")
    let terminalPacket = DockSwipePacket(token: token, axis: 1, phase: 4, progress: 0.8, velocityX: 5)
    let terminalEvent = DockSwipeAdapter.events(terminalPacket, at: .zero, marker: 123, osMajor: 15)[0]
    let neutral = DockSwipeAdapter.localTermination(terminalEvent, packet: terminalPacket, osMajor: 27)
    let neutralPacket = neutral.flatMap { DockSwipeAdapter.read($0, token: token) }
    try Check.that(neutralPacket?.phase == 4 && neutralPacket?.progress == 0 && neutralPacket?.velocityX == 0 &&
        DockSwipeAdapter.localTermination(terminalEvent, packet: sample, osMajor: 27) == nil &&
        DockSwipeAdapter.localTermination(terminalEvent, packet: terminalPacket, osMajor: 15) == nil,
        "only modern terminal capture releases a neutral event to close local Dock tracking")
    for os in [15, 26, 27] {
        for natural in [false, true] {
            for axis in [1, 2] {
                for sign in [-1.0, 1.0] {
                    for phase in [1, 2, 4, 8] {
                        let logical = DockSwipePacket(token: token, axis: axis, phase: phase, progress: sign * 0.25,
                            velocityX: sign * 3, velocityY: sign * 2, inverted: true)
                        let expected = os == 27 && axis == 1 && natural ? -1.0 : 1.0
                        let rendered = DockSwipeAdapter.renderingPacket(logical, osMajor: os, naturalScrolling: natural)
                        let native = DockSwipeAdapter.events(logical, at: .zero, marker: 123, osMajor: os, naturalScrolling: natural)
                        let captured = native.first.flatMap { DockSwipeAdapter.read($0, token: token) }
                        try Check.that(rendered.progress == logical.progress * expected &&
                            rendered.velocityX == logical.velocityX * expected && rendered.velocityY == logical.velocityY &&
                            captured?.progress == rendered.progress && captured?.velocityX == rendered.velocityX && captured?.phase == phase &&
                            (os != 27 || axis != 1 || captured?.inverted == false),
                            "direction matrix preserves logical direction across OS, natural-scroll preference, axis, sign, and phase")
                        if os == 27 {
                            let hid = DockSwipeAdapter.hidPayload(rendered, timestamp: 1)!
                            try Check.that(integer(hid, 64, 4) == UInt64(UInt32(bitPattern: Int32(rendered.progress * 65536))) &&
                                integer(hid, 84, 4) == UInt64(UInt32(bitPattern: Int32(rendered.velocityX * 65536))),
                                "modern HID progress and end velocity use the same direction correction")
                        }
                    }
                }
            }
        }
    }
    a.setPeer("B", supportsGestures: false)
    try Check.that(!a.gesturesSupported && !a.localGesture(sample), "legacy peers keep gestures local")
}
