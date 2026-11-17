import AppKit

func keyboardSharingTests() throws {
    let a = MouseSharing(local: "A", native: false), b = MouseSharing(local: "B", native: false)
    defer { a.stop(); b.stop(); a.send = nil; b.send = nil; a.sendKeyboard = nil; b.sendKeyboard = nil }
    var queue: [(Bool, FeaturePacket)] = []
    var keys: [KeyboardPacket] = [], released: Set<Int> = [], edgeProgress: [Double] = []
    a.send = { _, packet, reply in queue.append((true, FeaturePacket(mouse: packet))); reply(true) }
    b.send = { _, packet, reply in queue.append((false, FeaturePacket(mouse: packet))); reply(true) }
    a.sendKeyboard = { _, packet, reply in queue.append((true, FeaturePacket(keyboard: packet))); reply(true) }
    b.sendKeyboard = { _, packet, reply in queue.append((false, FeaturePacket(keyboard: packet))); reply(true) }
    a.displays = { [CGRect(x: 0, y: 0, width: 1000, height: 600)] }; b.displays = a.displays
    b.onKeyboardInput = { keys.append($0) }; b.onKeysReleased = { released = $0 }
    a.onEdgeProgress = { point, _, progress in edgeProgress.append(point == nil ? -1 : progress) }
    var now = Date().addingTimeInterval(3)
    func pump() throws {
        var budget = 100
        while !queue.isEmpty && budget > 0 {
            budget -= 1
            let (toB, wire) = queue.removeFirst()
            let packet = try FeaturePacket.decode(wire.encoded())
            let target = toB ? b : a, sender = toB ? "A" : "B"
            if let mouse = packet.mouse { target.receive(mouse, from: sender, now: now) }
            if let keyboard = packet.keyboard { target.receiveKeyboard(keyboard, from: sender, now: now) }
        }
        try Check.that(queue.isEmpty, "input message exchange settles within its bound")
    }
    func enter() throws {
        now = now.addingTimeInterval(3)
        _ = a.localMove(point: CGPoint(x: 999, y: 300), dx: 2, dy: 0, now: now)
        now = now.addingTimeInterval(0.2)
        _ = a.localMove(point: CGPoint(x: 999, y: 300), dx: 2, dy: 0, now: now)
        try pump()
        try Check.that(a.mode == .controlling && b.mode == .receiving, "keyboard test has an accepted pointer handoff")
    }
    a.setPeer("B", supportsKeyboard: true); b.setPeer("A", supportsKeyboard: true)
    try pump(); a.setSide(.right); try pump()
    try Check.that(!a.localKey(action: .down, keyCode: 0) && queue.isEmpty, "disabled input sharing does not capture or transmit keys")
    try a.setEnabled(true); try pump()
    try Check.that(!a.keyboardActive, "keyboard requires both peers to opt in")
    try b.setEnabled(true); try pump(); try enter()
    try Check.that(edgeProgress.contains(0) && edgeProgress.contains(1), "edge indicator fills during handoff dwell")
    try Check.that(a.keyboardActive && b.keyboardActive, "keyboard consent is negotiated separately from mouse capability")
    try Check.that(a.localKey(action: .down, keyCode: 0), "controlling Mac consumes forwarded key down")
    _ = a.localKey(action: .down, keyCode: 0, isRepeat: true)
    _ = a.localKey(action: .up, keyCode: 0)
    _ = a.localKey(action: .modifiers, keyCode: 55, flags: 0x100000)
    _ = a.localKey(action: .down, keyCode: 8, flags: 0x100000)
    _ = a.localKey(action: .up, keyCode: 8, flags: 0x100000)
    _ = a.localKey(action: .modifiers, keyCode: 55)
    try pump()
    try Check.that(keys.map(\.action) == [.down, .down, .up, .modifiers, .down, .up, .modifiers] && keys[1].isRepeat,
                   "key up/down, autorepeat, and Command shortcuts cross the authenticated feature codec")
    try Check.that(a.mode == .controlling, "typing no longer ends a keyboard-enabled handoff")
    let token = keys[0].token, count = keys.count
    b.receiveKeyboard(KeyboardPacket(token: UUID(), action: .down, keyCode: 1), from: "A", now: now)
    b.receiveKeyboard(KeyboardPacket(token: token, action: .down, keyCode: 1), from: "stranger", now: now)
    b.receiveKeyboard(KeyboardPacket(token: token, action: .down, keyCode: 1, isRepeat: true), from: "A", now: now)
    try Check.that(keys.count == count, "reject stale, unpaired, and orphan autorepeat events")
    _ = a.localKey(action: .modifiers, keyCode: 56, flags: 0x20000)
    _ = a.localKey(action: .down, keyCode: 13, flags: 0x20000); try pump()
    a.endSession(); try pump()
    try Check.that(released == [56, 13] && b.mode == .local, "ending control releases held ordinary and modifier keys")
    try Check.that(edgeProgress.last == -1, "return clears the edge indicator")
    b.receiveKeyboard(KeyboardPacket(token: token, action: .down, keyCode: 0), from: "A", now: now)
    try Check.that(keys.count == count + 2, "keys arriving after control ended are ignored")
    _ = a.localKey(action: .up, keyCode: 13); _ = a.localKey(action: .modifiers, keyCode: 56)
    try enter()
    _ = a.localKey(action: .down, keyCode: 0); try pump()
    now = now.addingTimeInterval(3); b.tick(now: now); try pump()
    try Check.that(released == [0] && a.mode == .local && b.mode == .local, "heartbeat loss releases remote keys on both peers")
    _ = a.localKey(action: .up, keyCode: 0); try enter()
    let sentCount = keys.count
    try Check.that(a.localKey(action: .down, keyCode: 53, flags: 0xC0000), "emergency chord is consumed on the source")
    try pump()
    try Check.that(!a.enabled && b.mode == .local && keys.count == sentCount, "emergency chord is never forwarded and stops keyboard control")
    try a.setEnabled(true); try pump(); try enter()
    try Check.that(!b.localKey(action: .down, keyCode: 0), "receiver physical typing is retained locally")
    try pump()
    try Check.that(a.mode == .local && b.mode == .local, "receiver keyboard input immediately reclaims control")
    _ = b.localKey(action: .up, keyCode: 0)
    try enter()
    _ = a.localKey(action: .down, keyCode: 1); try pump()
    b.secureInputEnabled = { true }; b.tick(now: now); try pump()
    try Check.that(a.mode == .local && b.mode == .local && released == [1] && a.lastEndReason == .secureInput,
                   "secure input stops control and releases held keys without bypassing macOS protection")
    try Check.that(b.secureInputBlocked && a.remoteSecureInputBlocked && a.inputPauseMessage?.contains("상대 Mac") == true,
                   "secure-input interruption identifies the blocked Mac without clearing consent")
    try Check.that(a.enabled && b.enabled, "secure-input pause keeps both sharing choices enabled")
    now = now.addingTimeInterval(3)
    _ = a.localMove(point: CGPoint(x: 999, y: 300), dx: 2, dy: 0, now: now)
    _ = a.localMove(point: CGPoint(x: 999, y: 300), dx: 2, dy: 0, now: now.addingTimeInterval(0.2))
    try Check.that(a.mode == .local, "known secure-input peer does not receive repeated handoff requests")
    b.secureInputEnabled = { false }; b.tick(now: now); try pump()
    try Check.that(!a.remoteSecureInputBlocked && b.inputPauseMessage == nil && a.inputPauseMessage == nil,
                   "idle polling clears both pause messages when secure input ends")
    _ = a.localKey(action: .up, keyCode: 1)
    try enter()
    try Check.that(a.mode == .controlling && b.mode == .receiving, "handoff resumes after secure input without restarting either app")
    a.endSession(); try pump()
    _ = a.localKey(action: .down, keyCode: 12)
    a.secureInputEnabled = { true }; a.tick(now: now); try pump()
    _ = a.localKey(action: .up, keyCode: 12) // suppressed while secure input owns keyboard events
    a.secureInputEnabled = { false }; a.tick(now: now); try pump()
    try enter()
    try Check.that(a.mode == .controlling && b.mode == .receiving, "key-up hidden during secure input cannot leave re-entry permanently blocked")
    a.endSession(); try pump()

    a.setPeer("B", savedLayout: a.layout, supportsKeyboard: false)
    b.setPeer("A", savedLayout: b.layout, supportsKeyboard: false)
    try pump(); try enter()
    try Check.that(!a.localKey(action: .down, keyCode: 0), "legacy mouse-only peer keeps keyboard input local")
    try pump()
    try Check.that(!a.keyboardActive && a.mode == .local, "keyboard packets are not sent without negotiated capability")
}

func keyboardAdapterTests() throws {
    let token = UUID()
    let down = KeyboardPacket(token: token, action: .down, keyCode: 0, flags: 0x20000, isRepeat: true)
    let event = MouseSharing.makeKeyboardEvent(down)
    try Check.that(event?.type == .keyDown && event?.getIntegerValueField(.keyboardEventKeycode) == 0 &&
                   event?.getIntegerValueField(.keyboardEventAutorepeat) == 1 && event?.flags.contains(.maskShift) == true,
                   "native keyboard adapter preserves code, flags, and repeat without posting")
    let up = MouseSharing.makeKeyboardEvent(KeyboardPacket(token: token, action: .up, keyCode: 0))
    let modifier = MouseSharing.makeKeyboardEvent(KeyboardPacket(token: token, action: .modifiers, keyCode: 55, flags: 0x100000))
    try Check.that(up?.type == .keyUp && modifier?.type == .flagsChanged, "native adapter constructs releases and modifier transitions")
    try Check.that(event?.getIntegerValueField(.eventSourceUserData) != 0, "keyboard events carry the echo-suppression marker")
    for packet in [KeyboardPacket(token: token, action: .down, keyCode: 128),
                   KeyboardPacket(token: token, action: .down, keyCode: -1),
                   KeyboardPacket(token: token, action: .modifiers, keyCode: 0),
                   KeyboardPacket(token: token, action: .down, keyCode: 55),
                   KeyboardPacket(token: token, action: .up, keyCode: 0, isRepeat: true),
                   KeyboardPacket(token: token, action: .down, keyCode: 0, flags: UInt64.max)] {
        try Check.rejects("reject malformed keyboard packets") { try packet.validate() }
    }
    try Check.rejects("reject mixed keyboard and mouse feature payloads") {
        _ = try FeaturePacket(mouse: MousePacket(kind: .heartbeat, token: token), keyboard: down).encoded()
    }
}
