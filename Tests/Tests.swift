import AppKit
import CryptoKit
import Network

enum Check {
    static var count = 0
    static func that(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw ClipError.invalid("FAIL: " + label) }
        count += 1; print("PASS: " + label)
    }
    static func rejects(_ label: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { count += 1; print("PASS: " + label); return }
        throw ClipError.invalid("FAIL: " + label)
    }
}

func fixturePNG() throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 8, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let bytes = bitmap.bitmapData!
    for y in 0..<8 { for x in 0..<12 {
        let i = y * bitmap.bytesPerRow + x * 4
        bytes[i] = UInt8(x * 10); bytes[i + 1] = UInt8(y * 15); bytes[i + 2] = 50; bytes[i + 3] = 153
    } }
    return bitmap.representation(using: .png, properties: [:])!
}

func cryptoTests() throws {
    let code = try PairCode.create()
    try Check.that(code.count == 39, "128-bit pairing code formatting")
    try Check.that(try PairCode.normalize(code.lowercased()) == PairCode.normalize(code), "pair code normalization")
    try Check.rejects("reject short pairing code") { _ = try PairCode.normalize("123456") }
    try Check.rejects("reject non-hex pairing code") { _ = try PairCode.normalize(String(repeating: "Z", count: 32)) }
    let key = try PairCode.key(code)
    let a = Hello.make(device: UUID().uuidString, name: "테스트 Mac A")
    let b = Hello.make(device: UUID().uuidString, name: "테스트 Mac B")
    let ab = try SessionCipher(secret: key, local: a, remote: b)
    let ba = try SessionCipher(secret: key, local: b, remote: a)
    let clip = ClipMessage(id: UUID(), stamp: ClipStamp(counter: 42, device: a.device),
        payload: ClipPayload(type: "public.utf8-plain-text", data: Data("한글\nemoji 🙂\tcode = true".utf8)))
    let encrypted = try ab.seal(kind: "clip", clip: clip)
    let decoded = try ba.open(encrypted)
    try Check.that(decoded.clip?.payload == clip.payload, "authenticated Unicode payload round trip")
    try Check.that(decoded.clip?.stamp.counter == 42, "stamp preserved")
    try Check.rejects("reject replay on same connection") { _ = try ba.open(encrypted) }
    try Check.rejects("reject reflection to sender") { _ = try ab.open(encrypted) }
    let freshReceiver = try SessionCipher(secret: key, local: b, remote: a)
    var tampered = encrypted; tampered[tampered.count - 1] ^= 1
    try Check.rejects("reject modified ciphertext") { _ = try freshReceiver.open(tampered) }
    let wrong = try SessionCipher(secret: PairCode.key(PairCode.create()), local: b, remote: a)
    try Check.rejects("reject different pairing secret") { _ = try wrong.open(encrypted) }
    let later = try SessionCipher(secret: key, local: Hello.make(device: b.device, name: b.name), remote: a)
    try Check.rejects("reject replay after reconnect") { _ = try later.open(encrypted) }
    let renamed = Hello(version: a.version, device: a.device, name: "changed", nonce: a.nonce)
    let changed = try SessionCipher(secret: key, local: b, remote: renamed)
    try Check.rejects("authenticate handshake identity fields") { _ = try changed.open(encrypted) }
    let response = try ba.seal(kind: "ready", clock: 100)
    try Check.that(try ab.open(response).clock == 100, "independent bidirectional keys")
    let frame = try Framing.encode(Data(repeating: 7, count: 100_001))
    try Check.that(try Framing.length(Data(frame.prefix(4))) == 100_001, "network byte-order frame length")
    try Check.rejects("reject empty frame") { _ = try Framing.length(Data([0, 0, 0, 0])) }
    try Check.rejects("reject oversized frame before allocation") { _ = try Framing.length(Data([127, 255, 255, 255])) }
    try Check.rejects("bound unauthenticated frame") { _ = try Framing.length(Data([0, 0, 32, 0]), limit: 4096) }
}

func clipboardTests() throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let text = ClipPayload(type: "public.utf8-plain-text", data: Data("Hello 한글 👩🏽‍💻\n\tconst x = 1;".utf8))
    try ClipboardCodec.write(text, to: board, id: UUID())
    try Check.that(board.string(forType: .string) == String(data: text.data, encoding: .utf8), "native clipboard Unicode and whitespace")
    try Check.that(try ClipboardCodec.read(board) == nil, "remote clipboard marker prevents echo")
    try Check.that(try ClipboardCodec.read(board, allowRemote: true) == text, "explicit resend supports remote content")
    let png = try fixturePNG()
    let image = ClipPayload(type: "public.png", data: png)
    try ClipboardCodec.write(image, to: board, id: UUID())
    try Check.that(board.data(forType: .png) == png, "native PNG clipboard round trip")
    try Check.that(board.data(forType: .tiff) != nil, "provide TIFF for native editor compatibility")
    let tiff = board.data(forType: .tiff)!
    board.clearContents(); board.setData(tiff, forType: .tiff)
    let converted = try ClipboardCodec.read(board)
    try Check.that(converted?.type == "public.png", "convert screenshot TIFF to PNG")
    let bitmap = NSBitmapImageRep(data: converted!.data)!
    try Check.that(bitmap.pixelsWide == 12 && bitmap.pixelsHigh == 8 && bitmap.hasAlpha, "image dimensions and transparency preserved")
    let original = NSBitmapImageRep(data: png)!
    var before = [Int](repeating: 0, count: 4), after = [Int](repeating: 0, count: 4)
    original.getPixel(&before, atX: 5, y: 4); bitmap.getPixel(&after, atX: 5, y: 4)
    try Check.that(zip(before, after).allSatisfy { abs($0 - $1) <= 1 }, "image color and alpha values survive TIFF conversion")
    board.clearContents(); board.setString("private test", forType: .string)
    board.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
    try Check.that(try ClipboardCodec.read(board) == nil, "skip confidential clipboard entries")
    board.clearContents(); board.setString("file:///tmp/test.png", forType: .fileURL)
    board.setString("test.png", forType: .string)
    try Check.that(try ClipboardCodec.read(board) == nil, "skip Finder file references")
    try Check.rejects("reject malformed incoming image") {
        try ClipboardCodec.write(ClipPayload(type: "public.png", data: Data("not a png".utf8)), to: board, id: UUID())
    }
    try Check.rejects("reject unknown pasteboard types") { try ClipPayload(type: "public.file-url", data: Data([1])).validate() }
    try Check.rejects("reject payload over 20MB") { try ClipPayload(type: "public.png", data: Data(repeating: 0, count: ClipPayload.maxBytes + 1)).validate() }

    let boardA = NSPasteboard.withUniqueName(), boardB = NSPasteboard.withUniqueName()
    defer { boardA.releaseGlobally(); boardB.releaseGlobally() }
    let a = ClipboardSync(board: boardA, device: "A")
    let b = ClipboardSync(board: boardB, device: "B")
    a.connected = true; b.connected = true
    var outboundA: [ClipMessage] = [], outboundB: [ClipMessage] = []
    a.onLocal = { outboundA.append($0) }; b.onLocal = { outboundB.append($0) }
    boardA.clearContents(); boardA.setString("A concurrent", forType: .string); a.poll()
    boardB.clearContents(); boardB.setString("B concurrent", forType: .string); b.poll()
    a.receive(outboundB[0]); b.receive(outboundA[0])
    try Check.that(boardA.string(forType: .string) == "B concurrent" && boardB.string(forType: .string) == "B concurrent", "simultaneous copies converge deterministically")
    a.poll(); b.poll()
    try Check.that(outboundA.count == 1 && outboundB.count == 1, "remote update never loops back")
    boardA.clearContents(); boardA.setString("new local copy", forType: .string)
    a.receive(outboundB[0])
    try Check.that(boardA.string(forType: .string) == "new local copy", "protect new local copy between polling ticks")
    b.receive(outboundA.last!)
    try Check.that(boardB.string(forType: .string) == "new local copy", "later local copy propagates")
    b.enabled = false
    boardA.clearContents(); boardA.setString("while paused", forType: .string); a.poll()
    b.receive(outboundA.last!)
    try Check.that(boardB.string(forType: .string) == "new local copy", "pause blocks received clipboard writes")
    boardB.clearContents(); boardB.setString("offline private", forType: .string)
    b.poll(); b.enabled = true; b.poll()
    try Check.that(outboundB.count == 1, "resume does not publish clipboard copied while paused")
    b.observe(clock: 500)
    boardB.clearContents(); boardB.setString("after reconnect", forType: .string); b.poll()
    try Check.that(outboundB.last?.stamp.counter == 501, "join catches up logical clock before new copies")
}

func networkTests() throws {
    let code = try PairCode.create()
    let idA = UUID().uuidString, idB = UUID().uuidString
    let a = try LocalTransport(code: code, device: idA, name: "Integration A", discovery: false)
    let b = try LocalTransport(code: code, device: idB, name: "Integration B", discovery: false)
    defer { a.stop(); b.stop() }
    let textData = Data(String(repeating: "한글🙂\n", count: 170_000).utf8)
    let text = ClipMessage(id: UUID(), stamp: ClipStamp(counter: 801, device: idA), payload: ClipPayload(type: "public.utf8-plain-text", data: textData))
    let image = ClipMessage(id: UUID(), stamp: ClipStamp(counter: 802, device: idB), payload: ClipPayload(type: "public.png", data: try fixturePNG()))
    var receivedText = false, receivedImage = false, didSend = false, observedClock: UInt64 = 0
    a.clockProvider = { 800 }; b.onClock = { observedClock = $0 }
    a.onListening = { port in b.connectLoopback(port: port, expected: idA) }
    func maybeSend() {
        if a.peerCount == 1 && b.peerCount == 1 && !didSend { didSend = true; a.send(text) }
    }
    a.onPeers = { _ in maybeSend() }; b.onPeers = { _ in maybeSend() }
    b.onClip = { clip in
        receivedText = clip.id == text.id && clip.payload == text.payload
        b.send(image)
    }
    a.onClip = { clip in receivedImage = clip.id == image.id && clip.payload == image.payload }
    a.start(); b.start()
    let deadline = Date().addingTimeInterval(15)
    while !receivedImage && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    try Check.that(a.peerCount == 1 && b.peerCount == 1, "real TCP authenticated connection")
    try Check.that(observedClock == 800, "authenticated handshake clock synchronization")
    try Check.that(receivedText, "real TCP multi-megabyte Unicode transfer with frame reassembly")
    try Check.that(receivedImage, "real TCP reverse-direction PNG transfer")
    a.stop(); b.stop(); receivedText = false; receivedImage = false; didSend = false
    a.start(); b.start()
    let retryDeadline = Date().addingTimeInterval(15)
    while !receivedImage && Date() < retryDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    try Check.that(receivedText && receivedImage, "reconnect with fresh session keys and bidirectional data")
    a.stop(); b.stop()
    let wrong = try LocalTransport(code: PairCode.create(), device: UUID().uuidString, name: "Wrong code", discovery: false)
    defer { wrong.stop() }
    a.onListening = { port in wrong.connectLoopback(port: port, expected: idA) }
    a.onPeers = nil; a.onClip = nil
    a.start(); wrong.start()
    let wrongDeadline = Date().addingTimeInterval(1.5)
    while Date() < wrongDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    try Check.that(a.peerCount == 0 && wrong.peerCount == 0, "different code cannot authenticate on real TCP")
}

func discoveryTests() throws {
    let code = try PairCode.create()
    let a = try LocalTransport(code: code, device: UUID().uuidString, name: "Discovery A")
    let b = try LocalTransport(code: code, device: UUID().uuidString, name: "Discovery B")
    defer { a.stop(); b.stop() }
    a.start(); b.start()
    let deadline = Date().addingTimeInterval(12)
    while (a.peerCount != 1 || b.peerCount != 1) && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    try Check.that(a.peerCount == 1 && b.peerCount == 1, "Bonjour automatic discovery and single duplex connection")
}

func numericPairingTests() throws {
    let agreementA = PairingAgreement(device: UUID().uuidString, name: "Mac A")
    let agreementB = PairingAgreement(device: UUID().uuidString, name: "Mac B")
    let resultA = try agreementA.finish(remote: agreementB.local, commitment: agreementB.local.commitment())
    let resultB = try agreementB.finish(remote: agreementA.local, commitment: agreementA.local.commitment())
    try Check.that(resultA.code == resultB.code, "ECDH derives identical persistent pairing secret")
    try Check.that(resultA.digits == resultB.digits && resultA.digits.count == 6, "both Macs show identical six-digit comparison")
    try Check.that(try PairCode.normalize(resultA.code).count == 32, "six digits do not replace the 128-bit stored secret")
    let confirm = try resultA.cipher.seal(kind: "pair-confirm")
    try Check.that(try resultB.cipher.open(confirm).kind == "pair-confirm", "pairing confirmation is authenticated and encrypted")
    try Check.rejects("reject changed reveal after commitment") {
        let changed = PairingReveal(hello: Hello.make(device: agreementB.local.hello.device, name: "tampered"), publicKey: agreementB.local.publicKey)
        _ = try agreementA.finish(remote: changed, commitment: agreementB.local.commitment())
    }
    try Check.rejects("reject pairing reflection") {
        _ = try agreementA.finish(remote: agreementA.local, commitment: agreementA.local.commitment())
    }

    let a = NearbyPairing(device: UUID().uuidString, name: "숫자 확인 A")
    let b = NearbyPairing(device: UUID().uuidString, name: "숫자 확인 B")
    defer { a.stop(); b.stop() }
    var began = false, digitsA: String?, digitsB: String?, codeA: String?, codeB: String?
    var replyA: ((Bool) -> Void)?, replyB: ((Bool) -> Void)?
    a.onCandidates = { candidates in
        if !began && candidates.contains(where: { $0.device == b.device }) { began = true; a.connect(device: b.device) }
    }
    a.onVerify = { _, digits, reply in digitsA = digits; replyA = reply }
    b.onVerify = { _, digits, reply in digitsB = digits; replyB = reply }
    a.onPaired = { code, _ in codeA = code; a.endDiscovery() }; b.onPaired = { code, _ in codeB = code; b.endDiscovery() }
    a.start(); b.start()
    let deadline = Date().addingTimeInterval(12)
    while (replyA == nil || replyB == nil) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    try Check.that(replyA != nil && replyB != nil, "discover and select nearby Mac without transferring a code")
    try Check.that(digitsA == digitsB, "real TCP pairing displays matching numbers")
    try Check.that(codeA == nil && codeB == nil, "no saved pairing before user confirmation")
    replyA?(true)
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    try Check.that(codeA == nil && codeB == nil, "one-sided approval cannot enable clipboard sharing")
    replyB?(true)
    let finishDeadline = Date().addingTimeInterval(4)
    while (codeA == nil || codeB == nil) && Date() < finishDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    try Check.that(codeA != nil && codeA == codeB, "both approvals establish the same persistent connection secret")
    a.stop(); b.stop()

    let c = NearbyPairing(device: UUID().uuidString, name: "Cancel A")
    let d = NearbyPairing(device: UUID().uuidString, name: "Cancel B")
    defer { c.stop(); d.stop() }
    var cancelBegan = false, unauthorizedPair = false, cancelReply: ((Bool) -> Void)?
    var cancelled = 0
    c.onCandidates = { candidates in
        if !cancelBegan && candidates.contains(where: { $0.device == d.device }) { cancelBegan = true; c.connect(device: d.device) }
    }
    c.onVerify = { _, _, reply in cancelReply = reply }
    d.onVerify = { _, _, reply in reply(true) }
    c.onPaired = { _, _ in unauthorizedPair = true }; d.onPaired = { _, _ in unauthorizedPair = true }
    c.onEnded = { cancelled += 1 }; d.onEnded = { cancelled += 1 }
    c.start(); d.start()
    let cancelDeadline = Date().addingTimeInterval(12)
    while cancelReply == nil && Date() < cancelDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    try Check.that(cancelReply != nil, "cancellable pairing prompt reached")
    cancelReply?(false)
    let closeDeadline = Date().addingTimeInterval(3)
    while cancelled < 2 && Date() < closeDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    try Check.that(cancelled == 2 && !unauthorizedPair, "rejecting numbers cancels both ends without saving a secret")
}

func pairingAccessTests() throws {
    var fresh = PairingAccess(hasTrustedPeer: false)
    try Check.that(fresh.isOpen, "first use allows discovery")
    fresh.didPair()
    try Check.that(!fresh.isOpen, "approved pairing closes discovery")
    var saved = PairingAccess(hasTrustedPeer: true)
    try Check.that(!saved.isOpen, "saved pairing starts closed")
    saved.open(); saved.didAuthenticate()
    try Check.that(saved.isOpen, "trusted reconnect preserves explicit invitation")
    saved.close()
    try Check.that(!saved.isOpen, "cancel or timeout closes invitation")
    var migrated = PairingAccess(hasTrustedPeer: false)
    migrated.didAuthenticate()
    try Check.that(!migrated.isOpen, "legacy authenticated peer closes first-use discovery")
}

func expiredInvitationTests() throws {
    let server = NearbyPairing(device: UUID().uuidString, name: "Expired invitation", discovery: false)
    let client = NearbyPairing(device: UUID().uuidString, name: "New requester", discovery: false)
    defer { server.stop(); client.stop() }
    var verified = false, ended = false
    server.onVerify = { _, _, _ in verified = true }
    client.onVerify = { _, _, _ in verified = true }
    client.onEnded = { ended = true }
    server.onListening = { port in
        // Simulate the deadline passing before a queued UI timer has run.
        server.invitationDeadline = Date.distantPast
        client.connectDirect(host: "127.0.0.1", port: port)
    }
    client.start(); server.start()
    let deadline = Date().addingTimeInterval(5)
    while !ended && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    try Check.that(ended && !verified, "expired invitation rejects incoming pairing before UI timer fires")
}

func addressTests() throws {
    try Check.that(try ConnectionAddress(" my-mac.local:54321 ") == ConnectionAddress("my-mac.local:54321"), "trim connection address")
    try Check.that(try ConnectionAddress("[::1]:1234").host == "::1", "IPv6 address brackets")
    for value in ["", ":12", "localhost:0", "localhost:65536", "https://host:123", "a b:12", "user@host:12", "host:abc"] {
        try Check.rejects("reject invalid address: " + value) { _ = try ConnectionAddress(value) }
    }
}

func directPairingTests() throws {
    let a = NearbyPairing(device: UUID().uuidString, name: "Direct A", discovery: false)
    let b = NearbyPairing(device: UUID().uuidString, name: "Direct B", discovery: false)
    defer { a.stop(); b.stop() }
    a.syncPort = 51001; b.syncPort = 51002
    var codeA: String?, codeB: String?, routeA: DirectPeer?, routeB: DirectPeer?
    a.onRoute = { routeA = $0 }; b.onRoute = { routeB = $0 }
    a.onPaired = { code, _ in codeA = code; a.endDiscovery() }; b.onPaired = { code, _ in codeB = code; b.endDiscovery() }
    var approveA: ((Bool) -> Void)?, approveB: ((Bool) -> Void)?
    a.onVerify = { _, _, reply in approveA = reply }; b.onVerify = { _, _, reply in approveB = reply }
    a.onListening = { port in b.connectDirect(host: "127.0.0.1", port: port, expected: a.device) }
    b.start(); a.start()
    let deadline = Date().addingTimeInterval(5)
    while (approveA == nil || approveB == nil) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    try Check.that(approveA != nil && approveB != nil, "direct pairing works without Bonjour")
    try Check.that(routeA == nil && routeB == nil, "unapproved peer cannot save reconnect address")
    approveA?(true); approveB?(true)
    let finish = Date().addingTimeInterval(5)
    while (codeA == nil || codeB == nil) && Date() < finish { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    try Check.that(codeA != nil && codeA == codeB, "closing discovery preserves both pairing confirmations")
    try Check.that(routeA?.device == b.device && routeA?.port == 51002 && routeB?.port == 51001, "approved handshake carries authenticated reconnect port")
    a.stop(); b.stop()
    try Check.that(!a.busy && !b.busy && a.candidates.isEmpty, "stop clears pairing sessions and discovery")

    let code = try PairCode.create()
    let ta = try LocalTransport(code: code, device: a.device, name: "Direct transfer A", discovery: false)
    let tb = try LocalTransport(code: code, device: b.device, name: "Direct transfer B", discovery: false)
    defer { ta.stop(); tb.stop() }
    ta.onListening = { port in tb.setDirectPeer(DirectPeer(host: "127.0.0.1", port: port.rawValue, device: a.device)) }
    tb.onListening = { port in ta.setDirectPeer(DirectPeer(host: "127.0.0.1", port: port.rawValue, device: b.device)) }
    ta.start(); tb.start()
    let connected = Date().addingTimeInterval(10)
    while (ta.peerCount != 1 || tb.peerCount != 1) && Date() < connected { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    try Check.that(ta.peerCount == 1 && tb.peerCount == 1, "simultaneous direct reconnect converges on one connection")
    var received = false
    tb.onClip = { clip in received = clip.payload.data == Data("direct test".utf8) }
    ta.send(ClipMessage(id: UUID(), stamp: .init(counter: 1, device: a.device), payload: .init(type: "public.utf8-plain-text", data: Data("direct test".utf8))))
    let sent = Date().addingTimeInterval(3)
    while !received && Date() < sent { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    try Check.that(received, "clipboard transport works without discovery")
    ta.stop(); tb.stop()
    try Check.that(ta.peerCount == 0 && tb.peerCount == 0, "stop closes all authenticated connections")
}

@main
struct TestMain {
    static func main() {
        do {
            try expiredInvitationTests(); try pairingAccessTests(); try addressTests(); try directPairingTests(); try cryptoTests(); try clipboardTests(); try networkTests(); try discoveryTests(); try numericPairingTests()
            print("\nAll \(Check.count) checks passed. General clipboard was not accessed.")
        } catch {
            fputs("\(error.localizedDescription)\n", stderr); exit(1)
        }
    }
}
