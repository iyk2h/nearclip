import AppKit
import Network
import CryptoKit

func clipboardWorkerTests() throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let worker = DispatchQueue(label: "nearclip.test.clipboard-worker")
    let sync = ClipboardSync(board: board, device: "local", backgroundIO: true, workQueue: worker)
    sync.connected = true
    waitFor({ sync.isIdle })
    defer { sync.stop() }
    var sent: [ClipMessage] = [], activities = 0, callbacksOnMain = true
    sync.onLocal = { callbacksOnMain = callbacksOnMain && Thread.isMainThread; sent.append($0) }
    sync.onActivity = { _ in callbacksOnMain = callbacksOnMain && Thread.isMainThread; activities += 1 }
    board.clearContents(); board.setString("first", forType: .string)
    worker.suspend(); sync.poll()
    board.clearContents(); board.setString("second", forType: .string); sync.poll()
    board.clearContents(); board.setString("latest", forType: .string); sync.poll()
    worker.resume()
    waitFor({ sent.count == 1 })
    try Check.that(sent.count == 1 && sent[0].payload.data == Data("latest".utf8), "clipboard worker coalesces rapid copies and never publishes stale contents")
    let png = try fixturePNG()
    let incoming = ClipMessage(id: UUID(), stamp: ClipStamp(counter: sync.clock + 1, device: "remote"), payload: ClipPayload(type: "public.png", data: png))
    _ = sync.receive(incoming)
    waitFor({ board.data(forType: .png) == png })
    try Check.that(board.data(forType: .png) == png && board.data(forType: .tiff) != nil, "background image preparation retains native PNG and TIFF paste support")
    let beforeEcho = sent.count; sync.poll()
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    try Check.that(sent.count == beforeEcho, "background clipboard commit does not echo")

    worker.suspend()
    let stale = ClipMessage(id: UUID(), stamp: ClipStamp(counter: sync.clock + 1, device: "remote"), payload: ClipPayload(type: "public.utf8-plain-text", data: Data("stale remote".utf8)))
    _ = sync.receive(stale)
    board.clearContents(); board.setString("new local", forType: .string)
    worker.resume()
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    try Check.that(board.string(forType: .string) == "new local", "copy during background preparation cannot be overwritten by remote completion")
    sync.poll(); waitFor({ sent.last?.payload.data == Data("new local".utf8) })
    try Check.that(sent.last?.payload.data == Data("new local".utf8), "newer local copy is still published after rejecting stale remote work")

    for interruption in 0..<3 {
        worker.suspend()
        _ = sync.receive(ClipMessage(id: UUID(), stamp: ClipStamp(counter: sync.clock + 1, device: "remote"), payload: stale.payload))
        if interruption == 0 { sync.enabled = false; sync.enabled = true }
        if interruption == 1 { sync.connected = false; sync.connected = true }
        if interruption == 2 { sync.stop() }
        worker.resume()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try Check.that(board.string(forType: .string) == "new local", "pause, reconnect, or stop invalidates in-progress clipboard preparation")
    }
    board.clearContents(); board.setString("private", forType: .string)
    board.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
    let beforePrivate = sent.count
    sync.poll(); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    try Check.that(sent.count == beforePrivate, "background reader retains confidential clipboard filtering")

    worker.suspend()
    for value in ["older remote", "latest remote"] {
        _ = sync.receive(ClipMessage(id: UUID(), stamp: ClipStamp(counter: sync.clock + 1, device: "remote"), payload: ClipPayload(type: "public.utf8-plain-text", data: Data(value.utf8))))
    }
    worker.resume()
    waitFor({ board.string(forType: .string) == "latest remote" })
    try Check.that(board.string(forType: .string) == "latest remote", "newest pending remote copy wins without an intermediate stale write")
    let beforeError = activities
    _ = sync.receive(ClipMessage(id: UUID(), stamp: ClipStamp(counter: sync.clock + 1, device: "remote"), payload: ClipPayload(type: "public.png", data: Data("invalid".utf8))))
    waitFor({ activities > beforeError })
    try Check.that(board.string(forType: .string) == "latest remote" && activities > beforeError && callbacksOnMain, "invalid background image leaves clipboard intact and callbacks remain on main")

    // A malformed local clipboard is reported once until its change count moves.
    board.clearContents(); board.setData(Data("invalid local PNG".utf8), forType: .png)
    let beforeInvalidLocal = activities
    sync.poll(); waitFor({ sync.isIdle })
    for _ in 0..<10 { sync.poll(); waitFor({ sync.isIdle }) }
    try Check.that(activities == beforeInvalidLocal + 1, "invalid local image is not decoded and reported again on every poll")
    try ClipboardCodec.write(stale.payload, to: board, id: UUID())
    sync.baseline(); waitFor({ sync.isIdle })
    let beforeForce = sent.count
    worker.suspend(); sync.poll(); sync.poll(force: true)
    for _ in 0..<20 { sync.poll() }
    worker.resume(); waitFor({ sync.isIdle })
    try Check.that(sent.count == beforeForce + 1 && sent.last?.payload == stale.payload, "automatic polling cannot replace a queued explicit resend of remote contents")

    // Hold the clipboard worker longer than the old three-second probe deadline.
    // Real TCP probes must continue while this work cannot finish.
    let code = try PairCode.create(), local = UUID().uuidString, remote = UUID().uuidString
    let server = try LocalTransport(code: code, device: local, name: "Worker test receiver", discovery: false)
    let client = try LocalTransport(code: code, device: remote, name: "Worker test sender", discovery: false)
    defer { server.stop(); client.stop() }
    server.onListening = { client.connectLoopback(port: $0, expected: local) }
    var sampleCount = 0, lostInput = false
    server.onMetrics = { _, _ in sampleCount += 1 }
    server.start(); client.start()
    waitFor({ server.separateInputPeerCount == 1 && client.separateInputPeerCount == 1 })
    try Check.that(server.separateInputPeerCount == 1, "clipboard stall test establishes authenticated input")
    server.onPeerDetails = { peers in if peers.first?.inputReady != true { lostInput = true } }
    worker.suspend()
    board.clearContents(); board.setString("delayed provider", forType: .string)
    let start = ProcessInfo.processInfo.systemUptime
    sync.poll()
    let callMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
    RunLoop.main.run(until: Date().addingTimeInterval(4.2))
    worker.resume()
    waitFor({ sent.last?.payload.data == Data("delayed provider".utf8) })
    try Check.that(callMS < 100 && sampleCount >= 3 && !lostInput && server.separateInputPeerCount == 1,
                   "clipboard work delayed beyond probe timeout cannot starve TCP input or cause reconnect")
    print("METRIC: clipboard_worker held_ms=4200 poll_return_ms=\(callMS) input_samples=\(sampleCount) lost_input=\(lostInput)")
}

// Models blocking pasteboard IPC itself, rather than merely suspending a queue.
private final class BlockingClipboardAccess: ClipboardAccess {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var hold: String?
    private var waiting = false
    private var mainAccess = false
    private var operations = 0
    private var count = 0
    private var payload: ClipPayload?
    var blocked: Bool { lock.lock(); defer { lock.unlock() }; return waiting }
    var accessedOnMain: Bool { lock.lock(); defer { lock.unlock() }; return mainAccess }
    var operationCount: Int { lock.lock(); defer { lock.unlock() }; return operations }
    func holdNext(_ operation: String) { lock.lock(); hold = operation; lock.unlock() }
    func unblock() { release.signal() }
    private func before(_ operation: String) {
        lock.lock()
        operations += 1; mainAccess = mainAccess || Thread.isMainThread
        let block = hold == operation
        if block { hold = nil; waiting = true }
        lock.unlock()
        if block {
            _ = release.wait(timeout: .now() + 8)
            lock.lock(); waiting = false; lock.unlock()
        }
    }
    var changeCount: Int { before("count"); lock.lock(); defer { lock.unlock() }; return count }
    func read(allowRemote: Bool) throws -> ClipPayload? { before("read"); lock.lock(); defer { lock.unlock() }; return payload }
    func commit(_ prepared: ClipboardCodec.Prepared, id: UUID, preventAppleRelay: Bool) throws {
        before("write"); lock.lock(); count += 1; payload = nil; lock.unlock()
    }
}

func clipboardIPCIsolationTests() throws {
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    let io = BlockingClipboardAccess()
    let sync = ClipboardSync(board: board, device: "local", backgroundIO: true, backgroundAccess: { io })
    sync.connected = true; waitFor({ sync.isIdle }); defer { sync.stop() }
    let code = try PairCode.create(), local = UUID().uuidString, remote = UUID().uuidString
    let server = try LocalTransport(code: code, device: local, name: "IPC test receiver", discovery: false)
    let client = try LocalTransport(code: code, device: remote, name: "IPC test sender", discovery: false)
    defer { server.stop(); client.stop() }
    server.onListening = { client.connectLoopback(port: $0, expected: local) }
    var samples = 0, lostInput = false
    server.onMetrics = { _, _ in samples += 1 }
    server.start(); client.start()
    waitFor({ server.separateInputPeerCount == 1 && client.separateInputPeerCount == 1 })
    try Check.that(server.separateInputPeerCount == 1, "blocking clipboard IPC test establishes independent input channel")
    server.onPeerDetails = { if $0.first?.inputReady != true { lostInput = true } }
    for operation in ["count", "write"] {
        io.holdNext(operation)
        let before = samples, calls = io.operationCount, start = ProcessInfo.processInfo.systemUptime
        if operation == "count" { sync.poll() }
        else {
            _ = sync.receive(ClipMessage(id: UUID(), stamp: ClipStamp(counter: sync.clock + 1, device: "remote"), payload: ClipPayload(type: "public.utf8-plain-text", data: Data("IPC test".utf8))))
        }
        let callMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        waitFor({ io.blocked })
        try Check.that(io.blocked && callMS < 100, "blocking \(operation) IPC starts on worker without blocking caller")
        for _ in 0..<100 { sync.poll() }
        RunLoop.main.run(until: Date().addingTimeInterval(4.2))
        io.unblock(); waitFor({ sync.isIdle })
        try Check.that(samples - before >= 3 && !lostInput && server.separateInputPeerCount == 1,
                       "real TCP input survives \(operation) IPC blocked longer than probe deadline")
        try Check.that(io.operationCount - calls < 15, "repeated polls stay bounded while \(operation) IPC is blocked")
        print("METRIC: clipboard_ipc operation=\(operation) held_ms=4200 call_ms=\(callMS) probe_replies=\(samples - before)")
    }
    io.holdNext("count"); sync.baseline(); waitFor({ io.blocked })
    var activity = ""; sync.onActivity = { activity = $0 }
    _ = sync.receive(ClipMessage(id: UUID(), stamp: ClipStamp(counter: sync.clock + 1, device: "remote"), payload: ClipPayload(type: "public.utf8-plain-text", data: Data("after baseline".utf8))))
    io.unblock(); waitFor({ sync.isIdle })
    try Check.that(activity.contains("받음"), "receive during asynchronous baseline is retained until baseline finishes")
    io.holdNext("count"); sync.poll(); waitFor({ io.blocked })
    let start = ProcessInfo.processInfo.systemUptime
    sync.enabled = false; sync.connected = false; sync.stop()
    let stopMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
    io.unblock(); waitFor({ sync.isIdle })
    try Check.that(stopMS < 100 && !io.accessedOnMain, "pause, disconnect, and stop never wait for pasteboard IPC on main")
    sync.enabled = true; sync.connected = true; waitFor({ sync.isIdle })
    io.holdNext("count"); sync.baseline(); waitFor({ io.blocked })
    sync.stop(); sync.start(); io.unblock(); waitFor({ sync.isIdle })
    activity = ""
    _ = sync.receive(ClipMessage(id: UUID(), stamp: ClipStamp(counter: sync.clock + 1, device: "remote"), payload: ClipPayload(type: "public.utf8-plain-text", data: Data("after restart".utf8))))
    waitFor({ activity.contains("받음") })
    try Check.that(activity.contains("받음"), "restart replaces a cancelled pending baseline and resumes incoming clipboard writes")
}

func asynchronousClipboardConvergenceTests() throws {
    let boardA = NSPasteboard.withUniqueName(), boardB = NSPasteboard.withUniqueName()
    defer { boardA.releaseGlobally(); boardB.releaseGlobally() }
    let a = ClipboardSync(board: boardA, device: "A", backgroundIO: true)
    let b = ClipboardSync(board: boardB, device: "B", backgroundIO: true)
    defer { a.stop(); b.stop() }
    a.connected = true; b.connected = true
    waitFor({ a.isIdle && b.isIdle })
    var forwards = 0
    a.onLocal = { forwards += 1; b.receive($0) }
    b.onLocal = { forwards += 1; a.receive($0) }
    boardA.clearContents(); boardA.setString("copy A", forType: .string)
    boardB.clearContents(); boardB.setString("copy B", forType: .string)
    a.poll(); b.poll()
    waitFor({ a.isIdle && b.isIdle && boardA.string(forType: .string) == boardB.string(forType: .string) })
    let result = boardA.string(forType: .string)
    try Check.that(result == boardB.string(forType: .string) && ["copy A", "copy B"].contains(result ?? ""), "asynchronous simultaneous copies converge without overwriting an unobserved local copy")
    let before = forwards
    for _ in 0..<5 { a.poll(); b.poll(); waitFor({ a.isIdle && b.isIdle }) }
    try Check.that(forwards == before && forwards <= 3, "asynchronous remote writes do not create an echo loop")
}
