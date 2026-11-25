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
    let imageOffer = FilePacket(kind: .offer, id: UUID(), name: "drag.PNG", size: 250_000)
    let imagePacket = try FeaturePacket.decode(FeaturePacket(dragImage: imageOffer).encoded())
    try Check.that(imagePacket.dragImage?.id == imageOffer.id && !imagePacket.usesInputChannel, "image preparation travels on the bulk connection")
    for (name, size) in [("program.app", Int64(1)), ("big.png", Int64(ClipPayload.maxBytes + 1))] {
        try Check.rejects("reject speculative transfer outside image limits") {
            try FeaturePacket(dragImage: FilePacket(kind: .offer, id: UUID(), name: name, size: size)).validate()
        }
    }
    var staged: PreparedDragImage? = try PreparedDragImage(offer: imageOffer)
    let discarded = staged!.url.deletingLastPathComponent()
    staged!.verified = true
    try Check.that(staged!.take() == nil, "finishing before release cannot deliver an image")
    staged = nil
    try Check.that(!FileManager.default.fileExists(atPath: discarded.path), "cancelling a prepared drag removes its private directory")
    let earlyRelease = try PreparedDragImage(offer: imageOffer)
    earlyRelease.released = true
    try Check.that(earlyRelease.take() == nil, "release waits for verified bytes")
    earlyRelease.verified = true
    try Check.that(earlyRelease.take() == earlyRelease.url && earlyRelease.take() == nil, "verified release can deliver only once")
    try FileManager.default.removeItem(at: earlyRelease.url.deletingLastPathComponent())
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
    let secure = MousePacket(kind: .availability, enabled: true, secureInputActive: true)
    try Check.that(try FeaturePacket.decode(FeaturePacket(mouse: secure).encoded()).mouse?.secureInputActive == true,
                   "secure-input availability survives authenticated feature codec")
    try Check.that(legacy.secureInputActive == nil, "legacy mouse packets need no secure-input status")
    try Check.rejects("secure-input status is restricted to availability packets") {
        _ = try FeaturePacket(mouse: MousePacket(kind: .heartbeat, token: UUID(), secureInputActive: true)).encoded()
    }
    try Check.rejects("decoded mixed features are rejected without a validation re-encode") {
        _ = try FeaturePacket.decode(Data("{\"mouse\":{\"kind\":\"availability\",\"enabled\":true,\"dx\":0,\"dy\":0,\"button\":0,\"clicks\":1,\"flags\":0},\"file\":{\"kind\":\"cancel\",\"id\":\"00000000-0000-0000-0000-000000000001\"}}".utf8))
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
    let staged = FileTransferWorker(), dragID = UUID()
    var wire: [FilePacket.Kind] = []
    staged.send = { _, packet, reply in wire.append(packet.kind); reply(true) }
    try staged.offer(url: source, to: "peer", id: dragID, preparePreview: true)
    staged.receive(FilePacket(kind: .accept, id: dragID), from: "peer")
    staged.releaseImage(id: UUID())
    staged.cancel()
    staged.releaseImage(id: dragID)
    try Check.that(wire == [.offer, .cancel], "cancelling a preview discards the accepted original even if a late release arrives")
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.writeObjects([source as NSURL])
    try Check.that(FinderFileDrop.fileURL(from: board)?.path == source.path, "read one native Finder file URL")
    board.clearContents(); board.writeObjects([source as NSURL, destination as NSURL])
    try Check.that(FinderFileDrop.fileURL(from: board) == nil, "reject multiple files without sending a partial selection")
    board.clearContents(); board.setString(source.path, forType: .string)
    try Check.that(FinderFileDrop.fileURL(from: board) == nil, "plain text paths are not Finder drags")
    board.clearContents()
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgqWr8DwADhAH/SDByBQAAAABJRU5ErkJggg==")!
    if let thumbnail = PreparedDragImage.thumbnail(png), let preview = PreparedDragImage.encodePreview(thumbnail) {
        try Check.that(PreparedDragImage.thumbnail(preview, isPreview: true)?.width == 1, "sender thumbnail decodes within receiver preview limits")
    } else { try Check.that(false, "generate thumbnail for a valid PNG") }
    try Check.that(PreparedDragImage.thumbnail(Data(repeating: 0, count: FilePacket.maxPreviewBytes + 1), isPreview: true) == nil, "reject oversized drag preview")
    let badge = DraggedFileBadge()
    let label = badge.contentView?.subviews.compactMap { $0 as? NSTextField }.first
    badge.setThumbnail(NSImage(size: NSSize(width: 64, height: 32)))
    try Check.that(label?.isHidden == true && badge.backgroundColor == .clear && badge.contentView?.bounds.size == NSSize(width: 52, height: 26),
                   "image preview shows only the proportional thumbnail on a transparent panel")
    badge.setThumbnail(nil)
    try Check.that(label?.isHidden == false && badge.contentView?.bounds.height == 24, "filename returns when the drag has no thumbnail")
    let point = CGPoint(x: 25, y: 25)
    badge.show("Photo.PNG", at: point)
    try Check.that(!badge.isVisible, "the receiver never flashes the image filename before the thumbnail")
    let pixels = NSImage(size: NSSize(width: 32, height: 24))
    badge.setThumbnail(pixels)
    try Check.that(badge.isVisible && badge.preview === pixels && label?.isHidden == true, "pixels appear immediately even when the pointer is stationary")
    badge.dismiss()
    badge.show("Large.jpg", at: point)
    waitFor({ badge.isVisible })
    try Check.that(badge.isVisible && badge.preview == nil && label?.isHidden == true, "images without a thumbnail use a file icon")
    badge.dismiss()
    badge.show("Cancelled.png", at: point)
    badge.dismiss()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    try Check.that(!badge.isVisible, "cancelled image drags never show a late icon")
    badge.show("Document.txt", at: point)
    try Check.that(badge.isVisible && label?.isHidden == false, "non-image files keep their name while dragging")
    badge.dismiss()
    board.setData(png, forType: .png)
    var imageSource = DragSourceFile(from: board)
    let temporary = imageSource?.url
    try Check.that(temporary?.lastPathComponent == "Image.png" && (try temporary.map { try Data(contentsOf: $0) }) == png, "raw image drag preserves bytes in a private file")
    imageSource = nil
    try Check.that(temporary.map { !FileManager.default.fileExists(atPath: $0.path) } == true, "raw drag source is removed when the transfer releases it")
    board.setString("private", forType: .init("org.nspasteboard.ConcealedType"))
    try Check.that(DragSourceFile(from: board) == nil, "concealed raw images are not staged")
    board.clearContents()
    let tiff = NSBitmapImageRep(data: png)!.tiffRepresentation!
    board.setData(tiff, forType: .tiff)
    let tiffSource = DragSourceFile(from: board)
    try Check.that(tiffSource?.url.lastPathComponent == "Image.tiff" && (try tiffSource.map { try Data(contentsOf: $0.url) }) == tiff, "TIFF-only app drags preserve image data")


    let appFolder = try testFolder(); defer { try? FileManager.default.removeItem(at: appFolder) }
    let firstDrop = try AppFileDrop.stage("photo.png", in: appFolder)
    let secondDrop = try AppFileDrop.stage("photo.png", in: appFolder)
    try Check.that(firstDrop != secondDrop && firstDrop.lastPathComponent == "photo.png", "native app drops preserve filenames without overwriting another drop")
    try Check.rejects("native drops reject remote paths") { _ = try AppFileDrop.stage("../photo.png", in: appFolder) }
    let pinned = try ReceiveDirectory(folder)
    let alternate = try testFolder(); defer { try? FileManager.default.removeItem(at: alternate) }
    try Check.rejects("drop approval cannot address a different folder") {
        _ = try ReceivedFile(destination: alternate.appendingPathComponent("wrong.txt"), directory: pinned)
    }
    let root = appFolder.resolvingSymlinksInPath()
    let nested = root.appendingPathComponent("Photos", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
    guard let dropDirectory = ReceiveDirectory.finderDrop(at: nested, named: "photo.png", roots: [root]) else {
        throw ClipError.invalid("Finder drop did not pin the selected folder")
    }
    try Check.that(dropDirectory.matches(nested), "Finder drop pins a folder below a personal destination")
    try Check.that(ReceiveDirectory.finderDrop(at: root, named: "photo.png", roots: [root]) != nil, "Finder drop accepts the desktop itself")
    try Check.that(ReceiveDirectory.finderDrop(at: root, named: ".profile", roots: [root]) == nil, "hidden incoming names require local approval")
    let folderLink = root.appendingPathComponent("Shortcut")
    try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: alternate)
    try Check.that(ReceiveDirectory.finderDrop(at: folderLink, named: "photo.png", roots: [root]) == nil, "symlinks cannot redirect automatic drops outside personal folders")
    for special in [".private", "Example.app"] {
        let subfolder = root.appendingPathComponent(special).appendingPathComponent("Content")
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        try Check.that(ReceiveDirectory.finderDrop(at: subfolder, named: "photo.png", roots: [root]) == nil,
                       "automatic Finder drops exclude hidden and package ancestors")
    }
    let photo = nested.appendingPathComponent("photo.png")
    let copy = try ReceivedFile(destination: photo, directory: dropDirectory, keepBoth: true)
    try Data([1]).write(to: photo)
    try Data([2]).write(to: nested.appendingPathComponent("photo 2.png"))
    try copy.append(Data([3]), offset: 0, size: 1)
    try copy.finish(size: 1, digest: Data(SHA256.hash(data: Data([3]))))
    try Check.that(copy.destination.lastPathComponent == "photo 3.png" && (try Data(contentsOf: copy.destination)) == Data([3]) &&
                   (try Data(contentsOf: photo)) == Data([1]), "a Finder filename collision at commit keeps both files")
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
    b.accept(id: offered!.id, destination: destination)
    a.receive(queue.removeFirst().1, from: "B")
    try Check.that(queue.map { $0.1.offset } == [0, Int64(FilePacket.chunkSize), Int64(2 * FilePacket.chunkSize)],
                   "new peers send three ordered chunks before waiting for the first receipt")
    pump()
    try Check.that(complete && !a.busy && !b.busy, "bounded chunk transfer reaches acknowledged completion")
    try Check.that(try Data(contentsOf: destination) == data && Data(contentsOf: source) == data, "file bytes preserved and source is not deleted")
    try Check.that(getxattr(destination.path, "com.apple.quarantine", nil, 0, 0, 0) > 0, "received file retains Gatekeeper quarantine metadata")
    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
    try Check.that((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "received file is private and not executable")
    try Check.that(!(try FileManager.default.contentsOfDirectory(atPath: folder.path)).contains(where: { $0.hasSuffix(".part") }), "successful transfer removes partial file")

    try a.offer(url: source, to: "B")
    let legacyOffer = queue.removeFirst().1
    a.receive(FilePacket(kind: .accept, id: legacyOffer.id), from: "B")
    try Check.that(queue.count == 1 && queue[0].1.kind == .chunk, "legacy acceptance keeps one outstanding chunk")
    a.receive(FilePacket(kind: .ack, id: legacyOffer.id, offset: 2 * Int64(FilePacket.chunkSize)), from: "B")
    try Check.that(!a.busy && queue.last?.1.kind == .cancel, "a receipt cannot skip an outstanding chunk")
    queue.removeAll()
    try Check.rejects("unbounded transfer window is rejected") {
        try FilePacket(kind: .accept, id: legacyOffer.id, chunkWindow: 4).validate()
    }
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
    try Check.that(permissionStates[3].missing == ["Input Monitoring"], "permission guidance identifies missing input monitoring")
    try Check.that(permissionStates[5].missing == ["Accessibility input control"], "permission guidance distinguishes event posting from accessibility trust")
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
    for (sender, receiver, edgeX, height, otherHeight, dx) in [
        (a, b, 999.0, 600.0, 1200.0, 2.0),
        (b, a, 0.0, 1200.0, 600.0, -2.0)
    ] {
        for fraction in [0.1, 0.9] {
            now = now.addingTimeInterval(2)
            let point = CGPoint(x: edgeX, y: height * fraction)
            _ = sender.localMove(point: point, dx: dx, dy: 0, now: now)
            now = now.addingTimeInterval(0.2)
            _ = sender.localMove(point: point, dx: dx, dy: 0, now: now); pump()
            try Check.that(receiver.mode == .receiving && receiver.indicatorPoint.y == otherHeight * fraction,
                           "handoff preserves the relative entry height in either direction")
            sender.endSession(); pump()
        }
    }
    now = now.addingTimeInterval(2)
    let edge = CGPoint(x: 999, y: 300)
    try Check.that(!a.startFileDrag(named: "photo.png", at: edge, now: now), "no file drag with a legacy peer")
    a.setPeer("B", savedLayout: original, supportsFileDrag: true)
    b.setPeer("A", savedLayout: original, supportsFileDrag: true)
    try a.setEnabled(true); try b.setEnabled(true); pump()
    var droppedAt: CGPoint?, acknowledged: UUID?
    b.onFileDropPosition = { _, point in droppedAt = point; return true }
    a.onFileDropReady = { id, prepared in if prepared { acknowledged = id } }
    try Check.that(a.startFileDrag(named: "photo.png", at: edge, now: now), "Finder drag starts only at the shared edge")
    try Check.that(!a.releaseFileDrag(), "early release cannot send a file before acceptance")
    pump()
    _ = a.localMove(point: edge, dx: 50, dy: -10, buttonsDown: true, now: now)
    try Check.that(!a.localButton(action: .up, button: 0) && a.fileDropReleased, "physical button release commits the accepted file and lets Finder end its drag")
    try Check.that(!a.releaseFileDrag(), "later AppKit drop callback cannot duplicate the transfer")
    pump()
    try Check.that(droppedAt == CGPoint(x: 54, y: 590) && acknowledged.map(b.isReceivingDrop) == true, "final motion precedes the matching received drop acknowledgement")
    try Check.that(a.mode == .controlling && b.mode == .receiving && a.draggedFileName == nil && b.draggedFileName == nil, "successful drop leaves ordinary pointer control on destination")
    a.endSession(); pump()
    now = now.addingTimeInterval(2)
    acknowledged = nil; droppedAt = nil
    try Check.that(a.startFileDrag(named: "photo.png", at: edge, now: now), "second Finder drag can start")
    pump(); _ = a.localKey(action: .down, keyCode: 53, flags: 0); pump()
    try Check.that(a.mode == .local && b.mode == .local && acknowledged == nil && droppedAt == nil, "Escape cancels before any file offer")
    func enter() throws {
        now = now.addingTimeInterval(2)
        let x: Double = a.side == .right ? 999 : 0
        let dx: Double = a.side == .right ? 2 : -2
        _ = a.localMove(point: CGPoint(x: x, y: 300), dx: dx, dy: 0, now: now)
        now = now.addingTimeInterval(0.2)
        _ = a.localMove(point: CGPoint(x: x, y: 300), dx: dx, dy: 0, now: now); pump()
        try Check.that(a.mode == .controlling && b.mode == .receiving, "each mouse scenario starts with an accepted handoff")
    }
    let returnEdge = CGPoint(x: 1, y: 900)
    try enter()
    _ = a.localButton(action: .down, button: 0); pump()
    try Check.that(!b.startFileDrag(named: "photo.png", at: returnEdge, now: now), "an older controller cannot start a return drag")
    a.endSession(); pump()
    a.setPeer("B", savedLayout: original, supportsFileDrag: true, supportsReturnFile: true)
    b.setPeer("A", savedLayout: original, supportsFileDrag: true, supportsReturnFile: true)
    try a.setEnabled(true); try b.setEnabled(true); pump()
    try enter()
    try Check.that(!b.startFileDrag(named: "photo.png", at: returnEdge, now: now), "remote pickup requires a held left button")
    _ = a.localButton(action: .down, button: 0); pump()
    try Check.that(!b.startFileDrag(named: "photo.png", at: CGPoint(x: 500, y: 400), now: now), "remote pickup requires the return edge")
    _ = b.localKey(action: .modifiers, keyCode: 56, flags: 0); pump()
    try Check.that(b.canPickUpRemoteDrag, "an unmatched modifier release preserves the remote Finder pickup")
    var returnID: UUID?, returnPoint: CGPoint?, offers = 0
    b.onFileDragAccepted = { returnID = $0 }
    a.onFileDropPosition = { _, point in returnPoint = point; return false }
    b.onFileDropReady = { _, _ in offers += 1 }
    try Check.that(b.startFileDrag(named: "photo.png", at: returnEdge, now: now), "pick up a file on the controlled Mac")
    pump()
    try Check.that(a.returningFile && a.indicatorPoint.y == 450 && returnID.map(a.isReceivingDrop) == true, "return cursor preserves the relative height and prepares the file")
    _ = b.localKey(action: .modifiers, keyCode: 0); pump()
    try Check.that(a.returningFile && b.returningFile, "an unrecognized flags update cannot discard an accepted return drag")
    let folderPoint = CGPoint(x: 220, y: 170)
    _ = a.localMove(point: folderPoint, dx: -9, dy: 1, buttonsDown: true, now: now)
    try Check.that(offers == 0 && returnPoint == nil, "hover cannot commit a returned file")
    _ = a.localButton(action: .up, button: 0, at: folderPoint); pump()
    try Check.that(offers == 1 && returnPoint == folderPoint && a.mode == .local && b.mode == .local &&
                   returnID.map(a.isReceivingDrop) == true, "physical release commits one copy at the local target and returns control")
    try enter()
    try Check.that(returnID.map(a.isReceivingDrop) == false, "new session invalidates previous drop authorization")
    _ = a.localButton(action: .down, button: 0); pump()
    _ = b.startFileDrag(named: "photo.png", at: returnEdge, now: now)
    _ = a.localButton(action: .up, button: 0); pump()
    try Check.that(offers == 1 && a.mode == .local && b.mode == .local, "early release cancels a pending return without transferring")
    try enter()
    _ = a.localButton(action: .down, button: 0); pump()
    _ = b.startFileDrag(named: "photo.png", at: returnEdge, now: now); pump()
    _ = a.localKey(action: .down, keyCode: 53); pump()
    try Check.that(offers == 1 && a.mode == .local && b.mode == .local && returnID.map(a.isReceivingDrop) == false,
                   "Escape discards the held return drag before committing a file")
    a.onFileDropPosition = nil; b.onFileDragAccepted = nil; b.onFileDropReady = nil
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
    try Check.that(sent.last?.dx == 100 && pendingReplies.count == 1, "accumulated movement drains on send completion without another timer tick")
    now = now.addingTimeInterval(0.11); mouse.tick(now: now)
    _ = mouse.localMove(point: .zero, dx: 2, dy: 0, now: now.addingTimeInterval(0.001))
    _ = mouse.localButton(action: .down, button: 0)
    try Check.that(sent.suffix(2).map(\.action) == [.move, .down], "click ordering is preserved even with movement in flight")
    _ = mouse.localMove(point: .zero, dx: 3, dy: 0, now: now.addingTimeInterval(0.002))
    mouse.secureInputEnabled = { true }
    let beforeSecureCompletion = sent.count
    pendingReplies.removeFirst()(true)
    pendingReplies.removeFirst()(true)
    try Check.that(mouse.pointerOnly && sent.dropFirst(beforeSecureCompletion).allSatisfy { $0.action != .move },
                   "send completion cannot drain motion after secure input activates")
    mouse.secureInputEnabled = { false }; mouse.tick(now: now)
    mouse.endSession(); now = now.addingTimeInterval(2); try enter()
    pendingReplies.forEach { $0(false) }
    try Check.that(mouse.mode == .controlling, "late failed movement completion cannot end a newer control session")
    let count = sent.count
    mouse.secureInputEnabled = { true }
    _ = mouse.localMove(point: .zero, dx: 20, dy: 0, flags: 0x20000, now: now)
    try Check.that(mouse.pointerOnly && sent.dropFirst(count).contains { $0.action == .move && $0.dx == 20 && $0.flags == 0 },
                   "new movement during Secure Input carries plain pointer deltas")
}

func mouseResumeTests() throws {
    let mouse = MouseSharing(local: "A", native: false)
    mouse.displays = { [CGRect(x: 0, y: 0, width: 1000, height: 600)] }
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
    mouse.setPeer(nil)
    var savedConsent: String?
    mouse.onConsentChange = { savedConsent = $0 }
    mouse.requestSharingWhenConnected(to: "B")
    try Check.that(mouse.sharingRequested && !mouse.enabled && savedConsent == "B", "recovery enable persists a peer-specific choice without input capture")
    mouse.stop()
    try Check.that(!mouse.sharingRequested && savedConsent == nil, "recovery disable clears persisted pending consent")
    mouse.setPeer("B")
    try Check.that(!mouse.enabled, "cancelled recovery enable cannot activate on reconnect")
    mouse.setPeer(nil); mouse.requestSharingWhenConnected(to: "B")
    mouse.suspend(.screenLock); mouse.setPeer("B")
    try Check.that(!mouse.enabled && mouse.sharingRequested, "pending enable cannot bypass screen lock")
    mouse.resume(.screenLock)
    try Check.that(mouse.enabled && !mouse.remoteEnabled, "pending enable resumes with fresh remote consent required")
    mouse.setPeer(nil); mouse.requestSharingWhenConnected(to: "B"); mouse.setPeer("C")
    try Check.that(!mouse.enabled && !mouse.sharingRequested && savedConsent == nil, "pending enable never transfers to another peer")
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
    var features: Set<String> = [], done = false, inputDuringFile = false, gestureDuringFile = false, inputSent = false
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
                a.sendFeature(FeaturePacket(gesture: DockSwipePacket(token: UUID(), axis: 1, phase: 1, progress: 0.01)), to: idB)
            }
        } else if packet.mouse?.kind == .availability { inputDuringFile = !done }
        else if packet.gesture?.phase == 1 { gestureDuringFile = !done }
    }
    fb.onOffer = { _, packet in fb.accept(id: packet.id, destination: destination) }
    fa.onComplete = { _ in done = true }
    a.start(); b.start(); waitFor({ a.peerCount == 1 && b.peerCount == 1 })
    try Check.that(features.isSuperset(of: [SharingFeature.files, SharingFeature.mouse, SharingFeature.fileDrag]), "authenticated ready negotiates file and mouse capabilities")
    try fa.offer(url: source, to: idB); waitFor({ done }, seconds: 10)
    try Check.that(done && (try Data(contentsOf: destination)) == data, "real encrypted TCP streams files through background I/O workers")
    try Check.that(inputDuringFile && gestureDuringFile, "mouse and gesture input arrive during an 8 MiB streamed file before completion")
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
    var gestureArrived = false
    b.onFeature = { _, packet in gestureArrived = packet.gesture?.phase == 1 && packet.gesture?.axis == 1 }
    a.sendFeature(FeaturePacket(gesture: DockSwipePacket(token: UUID(), axis: 1, phase: 1, progress: 0.01)), to: idB)
    waitFor({ gestureArrived })
    try Check.that(gestureArrived && features.contains(SharingFeature.gestures), "Dock swipe crosses negotiated encrypted input TCP without posting system input")
    let sourceMouse = MouseSharing(local: idA, native: false), receiverMouse = MouseSharing(local: idB, native: false)
    sourceMouse.displays = { [CGRect(x: 0, y: 0, width: 900, height: 600)] }
    receiverMouse.displays = sourceMouse.displays
    defer { sourceMouse.stop(); receiverMouse.stop() }
    sourceMouse.send = { peer, packet, reply in a.sendFeature(FeaturePacket(mouse: packet), to: peer, completion: reply) }
    receiverMouse.send = { peer, packet, reply in b.sendFeature(FeaturePacket(mouse: packet), to: peer, completion: reply) }
    a.onFeature = { peer, packet in
        if let mouse = packet.mouse { sourceMouse.receive(mouse, from: peer) }
        if let file = packet.file { fa.receive(file, from: peer) }
    }
    b.onFeature = { peer, packet in
        if let mouse = packet.mouse { receiverMouse.receive(mouse, from: peer) }
        if let file = packet.file { fb.receive(file, from: peer) }
    }
    let layout = ScreenLayout(revision: 1, author: idA, left: idA, right: idB)
    sourceMouse.setPeer(idB, savedLayout: layout, supportsFileDrag: true, supportsReturnFile: features.contains(SharingFeature.returnFileDrag))
    receiverMouse.setPeer(idA, savedLayout: layout, supportsFileDrag: true, supportsReturnFile: features.contains(SharingFeature.returnFileDrag))
    try sourceMouse.setEnabled(true); try receiverMouse.setEnabled(true)
    let afterActivationCooldown = Date().addingTimeInterval(0.8)
    waitFor { sourceMouse.remoteEnabled && receiverMouse.remoteEnabled && Date() >= afterActivationCooldown }
    done = false
    let dropped = folder.appendingPathComponent("drop.dat")
    let approved = try ReceiveDirectory(folder)
    var dropID: UUID?
    receiverMouse.onFileDropPosition = { id, _ in dropID = id; return false }
    sourceMouse.onFileDropReady = { id, _ in try? fa.offer(url: source, to: idB, id: id) }
    fb.onOffer = { _, offer in
        guard offer.id == dropID, receiverMouse.isReceivingDrop(offer.id) else { fb.decline(id: offer.id); return }
        fb.accept(id: offer.id, destination: dropped, directory: approved)
    }
    try Check.that(sourceMouse.startFileDrag(named: source.lastPathComponent, at: CGPoint(x: 899, y: 200)), "start a file handoff between two connected clients")
    waitFor { sourceMouse.mode == .controlling }
    let sourceEdge = CGPoint(x: 899, y: 200), drift = CGPoint(x: 760, y: 320)
    let move = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: drift, mouseButton: .left)!
    move.setIntegerValueField(.mouseEventDeltaY, value: 120)
    try Check.that(sourceMouse.handle(.leftMouseDragged, event: move) != nil && move.location == sourceEdge,
                   "remote motion keeps the local Finder drag anchored at its accepted edge")
    let release = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: drift, mouseButton: .left)!
    try Check.that(sourceMouse.handle(.leftMouseUp, event: release) != nil && release.location == sourceEdge && sourceMouse.fileDropReleased,
                   "the real event-tap release path starts the network drop before Finder responds")
    waitFor({ done }, seconds: 12)
    try Check.that(done && (try Data(contentsOf: dropped)) == data, "acknowledged input-channel drop delivers the intact file through the separate file channel")
    let broughtBack = folder.appendingPathComponent("brought-back.dat")
    var returnedID: UUID?, returned = false
    sourceMouse.onFileDropPosition = { id, _ in returnedID = id; return false }
    receiverMouse.onFileDropReady = { id, _ in try? fb.offer(url: dropped, to: idA, id: id) }
    fa.onOffer = { _, offer in
        guard offer.id == returnedID, sourceMouse.isReceivingDrop(offer.id) else { fa.decline(id: offer.id); return }
        fa.accept(id: offer.id, destination: broughtBack, directory: approved)
    }
    fa.onComplete = { url in returned = url == broughtBack }
    _ = sourceMouse.localButton(action: .down, button: 0)
    waitFor { receiverMouse.canPickUpRemoteDrag }
    try Check.that(receiverMouse.startFileDrag(named: dropped.lastPathComponent, at: CGPoint(x: 1, y: 320)), "pick up the remote file without switching mice")
    waitFor { sourceMouse.returningFile }
    var clipboardMessages = 0
    a.onClip = { _ in clipboardMessages += 1 }; b.onClip = { _ in clipboardMessages += 1 }
    let backMove = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: drift, mouseButton: .left)!
    try Check.that(sourceMouse.handle(.leftMouseDragged, event: backMove) != nil && backMove.type == .mouseMoved && backMove.location == drift, "held return drag tracks the real local cursor")
    sourceMouse.onFileDragMove = { $0 == drift }
    let hoverMove = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: drift, mouseButton: .left)!
    try Check.that(sourceMouse.handle(.leftMouseDragged, event: hoverMove) == nil, "the native return drag handles motion without a second cursor event")
    try Check.that(sourceMouse.handle(.leftMouseUp, event: release) == nil, "return drop consumes the hardware release")
    waitFor({ returned }, seconds: 12)
    try Check.that(returned && (try Data(contentsOf: broughtBack)) == data && (try Data(contentsOf: dropped)) == data &&
                   sourceMouse.mode == .local && receiverMouse.mode == .local, "encrypted reverse transfer copies the original and leaves the hardware mouse at home")
    try Check.that(clipboardMessages == 0, "return drag does not send a clipboard update")
    sourceMouse.endSession()
    waitFor { receiverMouse.mode == .local }
    let photo = folder.appendingPathComponent("photo.png")
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 384, pixelsHigh: 320, bitsPerSample: 8,
        samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 384 * 3, bitsPerPixel: 24)!
    var noise: UInt32 = 43
    for pixel in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) {
        noise = noise &* 1664525 &+ 1013904223
        bitmap.bitmapData![pixel] = UInt8(truncatingIfNeeded: noise >> 24)
    }
    let pngBytes = bitmap.representation(using: .png, properties: [:])!
    try Check.that(pngBytes.count > 3 * FilePacket.chunkSize, "image fixture spans multiple transfer windows")
    try pngBytes.write(to: photo)
    let preparedURL = folder.appendingPathComponent("prepared.png")
    let earlySender = FileTransfer(), earlyReceiver = FileTransfer()
    defer { earlySender.stop(); earlyReceiver.stop() }
    var previewReceived = false, completed = false, skippedSecondOffer = false
    var bodyPackets = 0, acceptedEarly = false
    earlySender.send = { peer, chunk, reply in
        if chunk.kind == .chunk || chunk.kind == .finish { bodyPackets += 1 }
        a.sendFeature(FeaturePacket(dragImage: chunk), to: peer, completion: reply)
    }
    earlyReceiver.send = { peer, chunk, reply in b.sendFeature(FeaturePacket(dragImage: chunk), to: peer, completion: reply) }
    sourceMouse.finishLocalPickup = { _ in true }
    sourceMouse.onFileDragAccepted = { id in try? earlySender.offer(url: photo, to: idB, id: id, preparePreview: true) }
    a.onFeature = { peer, packet in
        if let image = packet.dragImage { earlySender.receive(image, from: peer); if image.kind == .accept { acceptedEarly = true } }
        if let mouse = packet.mouse { sourceMouse.receive(mouse, from: peer) }
    }
    b.onFeature = { peer, packet in
        if let image = packet.dragImage { earlyReceiver.receive(image, from: peer) }
        if let mouse = packet.mouse { receiverMouse.receive(mouse, from: peer) }
    }
    earlyReceiver.onOffer = { _, offer in
        guard receiverMouse.isReceivingDrop(offer.id), offer.name == receiverMouse.draggedFileName,
              let preview = offer.previewPNG, PreparedDragImage.thumbnail(preview, isPreview: true)?.width == 64,
              !FileManager.default.fileExists(atPath: preparedURL.path) else { earlyReceiver.decline(id: offer.id); return }
        previewReceived = true
        earlyReceiver.accept(id: offer.id, destination: preparedURL)
    }
    earlyReceiver.onComplete = { _ in completed = true }
    receiverMouse.onFileDropPosition = { _, _ in previewReceived }
    sourceMouse.onFileDropReady = { id, prepared in skippedSecondOffer = prepared; if prepared { earlySender.releaseImage(id: id) } }
    let canReenter = Date().addingTimeInterval(0.8)
    waitFor { Date() >= canReenter }
    try Check.that(sourceMouse.startFileDrag(named: "photo.png", at: sourceEdge), "image drag starts at the shared edge")
    waitFor({ acceptedEarly }, seconds: 12)
    try Check.that(acceptedEarly && previewReceived && bodyPackets == 0 && !FileManager.default.fileExists(atPath: preparedURL.path), "early acceptance exposes only a thumbnail before release")
    try Check.that(sourceMouse.finishedLocalPickup && !sourceMouse.fileDropReleased && !skippedSecondOffer,
                   "finishing the local Finder pickup does not drop the remote file")
    try Check.that(sourceMouse.handle(.leftMouseUp, event: release) == nil && sourceMouse.fileDropReleased,
                   "only the physical release commits the detached image and consumes the extra button-up")
    waitFor({ completed }, seconds: 12)
    try Check.that(completed && (try Data(contentsOf: preparedURL)) == pngBytes, "release delivers the verified original")
    try Check.that(skippedSecondOffer, "release acknowledges the staged image without sending the file again")
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
    var received: [Data] = []
    server.onClip = { received.append($0.payload.data) }
    func sendText(_ text: String, _ counter: UInt64) {
        old?.send(ClipMessage(id: UUID(), stamp: ClipStamp(counter: counter, device: legacyID),
                             payload: ClipPayload(type: "public.utf8-plain-text", data: Data(text.utf8))))
    }
    sendText("encoding", 2); sendText("queued", 3)
    old?.cancelClipboard()
    sendText("resumed", 4)
    waitFor { !received.isEmpty }
    try Check.that(received == [Data("resumed".utf8)] && old?.ready == true, "pause cancels encoding and queued items while preserving the authenticated sequence on resume")
    server.onClip = { gotClip = $0.payload.data == Data("legacy".utf8) }
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
