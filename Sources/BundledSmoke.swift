import WebKit
import AppKit

// Opt-in diagnostic with synthetic identities. Never touches the user's clipboard or Keychain.
final class BundledSmoke {
    private var a: NearbyPairing!
    private var b: NearbyPairing!
    private var ta: LocalTransport?
    private var tb: LocalTransport?
    private var timer: Timer?
    private var started = Date()
    private var codeA: String?
    private var codeB: String?
    private var began = false
    private var transferring = false
    private var received = false
    private let filesA = FileTransfer()
    private let filesB = FileTransfer()
    private var fileStarted = false
    private var fileDone = false
    private var layoutSent = false
    private var layoutReceived = false
    private var folder: URL?
    private var complete: ((Bool) -> Void)?
    func run(complete: @escaping (Bool) -> Void) {
        self.complete = complete
        a = NearbyPairing(device: UUID().uuidString, name: "NearClip test A")
        b = NearbyPairing(device: UUID().uuidString, name: "NearClip test B")
        a.onCandidates = { [weak self] candidates in
            guard let self, !self.began, candidates.contains(where: { $0.device == self.b.device }) else { return }
            self.began = true; self.a.connect(device: self.b.device)
        }
        a.onVerify = { _, _, reply in reply(true) }; b.onVerify = { _, _, reply in reply(true) }
        a.onPaired = { [weak self] code, _ in self?.codeA = code; self?.a.endDiscovery() }; b.onPaired = { [weak self] code, _ in self?.codeB = code; self?.b.endDiscovery() }
        a.onStatus = { print("Pairing A:", $0) }; b.onStatus = { print("Pairing B:", $0) }
        a.start(); b.start()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func tick() {
        if Date().timeIntervalSince(started) > 25 { finish(false); return }
        if let codeA, codeA == codeB, !transferring {
            transferring = true
            print("PASS: packaged app discovers and pairs through Bonjour")
            a.stop(); b.stop()
            do {
                let ta = try LocalTransport(code: codeA, device: a.device, name: "Test A")
                let tb = try LocalTransport(code: codeA, device: b.device, name: "Test B")
                self.ta = ta; self.tb = tb
                tb.onClip = { [weak self] clip in self?.received = clip.payload.data == Data("synthetic smoke test".utf8) }
                ta.start(); tb.start()
            } catch { finish(false) }
        }
        if let ta, let tb, ta.peerCount == 1, tb.peerCount == 1, !received {
            ta.send(ClipMessage(id: UUID(), stamp: .init(counter: 1, device: a.device), payload: .init(type: "public.utf8-plain-text", data: Data("synthetic smoke test".utf8))))
        }
        if received && !fileStarted {
            fileStarted = true
            print("PASS: packaged app authenticates and transfers synthetic clipboard content")
            startFileCheck()
        }
        if fileDone && !layoutSent {
            layoutSent = true
            print("PASS: packaged app streams and verifies a synthetic file")
            ta?.sendFeature(FeaturePacket(mouse: MousePacket(kind: .layout, layout: ScreenLayout(revision: 1, author: a.device, left: a.device, right: b.device))), to: b.device)
        }
        if layoutReceived { print("PASS: packaged app exchanges encrypted screen layout"); finish(true) }
    }
    private func startFileCheck() {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nearclip-smoke-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); folder = directory
            let source = directory.appendingPathComponent("source.bin"), destination = directory.appendingPathComponent("received.bin")
            let data = Data(repeating: 0xA7, count: 300_123); try data.write(to: source)
            filesA.send = { [weak self] peer, packet, reply in self?.ta?.sendFeature(FeaturePacket(file: packet), to: peer, completion: reply) }
            filesB.send = { [weak self] peer, packet, reply in self?.tb?.sendFeature(FeaturePacket(file: packet), to: peer, completion: reply) }
            ta?.onFeature = { [weak self] peer, packet in if let file = packet.file { self?.filesA.receive(file, from: peer) } }
            tb?.onFeature = { [weak self] peer, packet in
                guard let self else { return }
                if let file = packet.file { self.filesB.receive(file, from: peer) }
                if let layout = packet.mouse?.layout { self.layoutReceived = layout.left == self.a.device && layout.right == self.b.device }
            }
            filesB.onOffer = { [weak self] _, packet in self?.filesB.accept(id: packet.id, destination: destination) }
            filesA.onComplete = { [weak self] _ in self?.fileDone = (try? Data(contentsOf: destination)) == data }
            try filesA.offer(url: source, to: b.device)
        } catch { finish(false) }
    }
    private func finish(_ success: Bool) {
        timer?.invalidate(); timer = nil
        filesA.stop(); filesB.stop()
        a.stop(); b.stop(); ta?.stop(); tb?.stop()
        if let folder { try? FileManager.default.removeItem(at: folder) }
        let cleaned = !a.busy && !b.busy && (ta?.peerCount ?? 0) == 0 && (tb?.peerCount ?? 0) == 0
        print(cleaned ? "PASS: packaged app closes all network sessions" : "FAIL: network cleanup")
        let reply = complete; complete = nil; reply?(success && cleaned)
    }
}

private final class WebDropFixture: NSObject, WKScriptMessageHandler {
    static let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgqWr8DwADhAH/SDByBQAAAABJRU5ErkJggg=="
    static func composer(id: UUID) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WebDropFixture(), name: "result")
        let view = WKWebView(frame: .zero, configuration: config)
        view.loadHTMLString("""
            <style>body,textarea{position:absolute;inset:0;margin:0}</style><textarea></textarea>
            <script>
            if (\(CommandLine.arguments.contains("--refresh-target"))) {
                const button = document.createElement('button');
                button.textContent = 'Refresh composer';
                button.style.cssText = 'position:absolute;inset:0';
                button.onclick = () => button.replaceWith(document.createElement('textarea'));
                document.querySelector('textarea').replaceWith(button);
            }
            let fileHover;
            document.ondragenter = event => {
                event.preventDefault();
                document.querySelector('textarea')?.replaceWith('Attach here');
            };
            document.ondragover = event => { event.preventDefault(); event.dataTransfer.dropEffect = 'copy';
                if (event.dataTransfer.types.includes('Files')) fileHover ??= performance.now(); };
            if (\(CommandLine.arguments.contains("--cancel-target"))) {
                document.ondragleave = () => { if (fileHover !== undefined)
                    setTimeout(() => window.webkit.messageHandlers.result.postMessage('cancelled'), 400); };
            }
            document.ondrop = async event => {
                if (\(CommandLine.arguments.contains("--cancel-target"))) {
                    window.webkit.messageHandlers.result.postMessage('unexpected drop'); return;
                }
                event.preventDefault();
                if (\(CommandLine.arguments.contains("--held-target")) && !(performance.now() - fileHover >= 300)) return;
                const file = event.dataTransfer.files[0];
                if (file?.name !== '\(id.uuidString).png' || file.type !== 'image/png') return;
                const image = await createImageBitmap(file);
                if (image.width !== 1 || image.height !== 1) return;
                const bytes = new Uint8Array(await file.arrayBuffer());
                window.webkit.messageHandlers.result.postMessage(btoa(String.fromCharCode(...bytes)));
            };
            </script>
            """, baseURL: nil)
        return view
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if CommandLine.arguments.contains("--cancel-target") {
            guard message.body as? String == "cancelled" else { exit(1) }
            print("PASS: hover ended without delivering the file"); fflush(stdout); exit(0)
        }
        guard message.body as? String == Self.png else { exit(1) }
        print("PASS: web composer attached the original PNG after replacing its drop zone"); fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }
}

final class AppDropSmoke: NSView {
    private let id: UUID
    init(_ id: UUID) {
        self.id = id
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        if CommandLine.arguments.contains("--refresh-target") {
            let button = NSButton(title: "Refresh composer", target: self, action: #selector(refreshComposer))
            button.frame = bounds
            addSubview(button)
        } else { addComposer() }
        registerForDraggedTypes([.fileURL])
    }
    @objc private func refreshComposer() {
        subviews.forEach { $0.removeFromSuperview() }
        addComposer()
    }
    private func addComposer() {
        let composer = NSTextField(labelWithString: "Message")
        composer.frame = bounds
        composer.unregisterDraggedTypes()
        composer.setAccessibilityLabel("Test message field")
        addSubview(composer)
    }
    required init?(coder: NSCoder) { nil }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Model a chat composer that swaps its input field for a drop target on hover.
        subviews.forEach { $0.removeFromSuperview() }
        print("PASS: test window replaced its composer with a drop zone"); fflush(stdout)
        return .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = FinderFileDrop.fileURL(from: sender.draggingPasteboard), url.lastPathComponent == id.uuidString,
              (try? Data(contentsOf: url)) == Data(id.uuidString.utf8) else { return false }
        print("PASS: target process received the exact native file URL and bytes")
        fflush(stdout); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }; return true
    }
    static func openTarget(_ id: UUID) {
        NSApp.setActivationPolicy(.regular)
        let point = NSEvent.mouseLocation
        if CommandLine.arguments.contains("--edge-target") {
            let edge = FileEdgePanel()
            edge.setFrameOrigin(NSPoint(x: point.x - edge.frame.width / 2, y: point.y - edge.frame.height / 2))
            edge.target.enter = { $0.url.lastPathComponent == id.uuidString }
            edge.target.drop = { url in
                guard (try? Data(contentsOf: url)) == Data(id.uuidString.utf8) else { return false }
                print("PASS: the unlabelled edge accepts a native file drag"); fflush(stdout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
                return true
            }
            edge.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { edge.orderOut(nil); exit(1) }
            return
        }
        let window = NSPanel(contentRect: NSRect(x: point.x-50, y: point.y-50, width: 100, height: 100),
                             styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        window.contentView = CommandLine.arguments.contains("--web-target") ? WebDropFixture.composer(id: id) : AppDropSmoke(id)
        window.title = "NearClip drop test"; window.level = .floating; window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { window.orderOut(nil); exit(1) }
    }
    static func start() {
        guard let executable = Bundle.main.executableURL else { exit(1) }
        let id = UUID(), child = Process()
        child.executableURL = executable; child.arguments = ["--app-drop-test-window", id.uuidString]
        let cancel = CommandLine.arguments.contains("--cancel-drag")
        let held = CommandLine.arguments.contains("--held-drop-smoke")
        if CommandLine.arguments.contains("--edge-target") { child.arguments?.append("--edge-target") }
        let refresh = CommandLine.arguments.contains("--refresh-target")
        if refresh { child.arguments?.append("--refresh-target") }
        if cancel { child.arguments?.append("--cancel-target") }
        let web = held || CommandLine.arguments.contains("--web-drop-smoke")
        if held { child.arguments?.append("--held-target") }
        if web { child.arguments?.append("--web-target") }
        do { try child.run() } catch { exit(1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (web ? 1.7 : 1)) {
            guard let point = CGEvent(source: nil)?.location,
                  let drop = AppFileDrop(id: id, name: web ? id.uuidString + ".png" : id.uuidString, point: point, expectedPID: child.processIdentifier) else {
                print("FAIL: test drop window unavailable"); exit(1)
            }
            do {
                let file = try drop.stage()
                let bytes = web ? Data(base64Encoded: WebDropFixture.png)! : Data(id.uuidString.utf8)
                try bytes.write(to: file)
                if refresh {
                    let fixture = AXUIElementCreateApplication(child.processIdentifier)
                    var before: AXUIElement?, after: AXUIElement?
                    guard AXUIElementCopyElementAtPosition(fixture, Float(point.x), Float(point.y), &before) == .success,
                          let before, AXUIElementPerformAction(before, kAXPressAction as CFString) == .success,
                          AXUIElementCopyElementAtPosition(fixture, Float(point.x), Float(point.y), &after) == .success,
                          let after, !CFEqual(before, after) else {
                        print("FAIL: test composer did not refresh at the release point"); exit(1)
                    }
                    print("PASS: composer replaced its accessibility element before delivery")
                }
                if CommandLine.arguments.contains("--covered-target") {
                    let cover = NSPanel(contentRect: NSRect(x: NSEvent.mouseLocation.x - 25, y: NSEvent.mouseLocation.y - 25, width: 50, height: 50),
                                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
                    cover.level = .popUpMenu; cover.orderFrontRegardless()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        let covered = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == cover.windowNumber
                        var declined = false
                        if covered { drop.deliver(authorized: { true }) { declined = !$0 } }
                        cover.orderOut(nil); child.terminate()
                        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                        print(declined ? "PASS: a covering window blocks delivery" : "FAIL: covering window check failed (covered=\(covered))")
                        exit(declined ? 0 : 1)
                    }
                    return
                }
                var completed = false
                drop.deliver(preview: held ? NSImage(data: bytes) : nil, authorized: { child.isRunning }) { completed = ($0 != cancel) }
                if held {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                        guard drop.canReleaseHeld(at: point),
                              AppFileDrop(id: id, name: file.lastPathComponent, point: point, expectedPID: child.processIdentifier) != nil else {
                            print("FAIL: target changed while hovering"); exit(1)
                        }
                        if cancel { drop.abort() } else { drop.releaseHeld(at: point) }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                    let received = !child.isRunning && child.terminationStatus == 0
                    if child.isRunning { child.terminate() }
                    withExtendedLifetime(drop) { print(completed && received ? "PASS: native drop completed" : "FAIL: native drop did not complete"); exit(completed && received ? 0 : 1) }
                }
            } catch { print(error); exit(1) }
        }
    }
}
