import AppKit
import Network
import CryptoKit

func clipboardWorkerTests() throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let worker = DispatchQueue(label: "nearclip.test.clipboard-worker")
    let sync = ClipboardSync(board: board, device: "local", backgroundIO: true, workQueue: worker)
    sync.connected = true
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
