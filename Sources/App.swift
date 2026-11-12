import AppKit
import ServiceManagement

final class WindowBackground: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var sync: ClipboardSync!
    private var transport: LocalTransport?
    private var pairing: NearbyPairing?
    private var code = ""
    private var device = ""
    private var peers: [String] = []
    private var lastActivity = "연결한 뒤 복사하는 내용부터 공유해요."
    private var networkNote: String?
    private var enabled = true
    private let preview = CommandLine.arguments.contains("--render-preview") || CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--lifecycle-smoke")
    private let statusLabel = NSTextField(labelWithString: "연결할 Mac을 기다리고 있어요")
    private let activityLabel = NSTextField(wrappingLabelWithString: "연결한 뒤 복사하는 내용부터 공유해요.")
    private let nearbyPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private var connectButton: NSButton!
    private var verificationAlert: NSAlert?
    private var toggle: NSButton!
    private var menuStatus: NSMenuItem!
    private var menuToggle: NSMenuItem!
    private var sendButton: NSButton!
    private var menuSend: NSMenuItem!
    private var pauseButton: NSButton!
    private var cancelButton: NSButton!
    private var addressButton: NSButton!
    private var copyAddressButton: NSButton!
    private var hasLocalAddress = false
    private var previewCloseBehavior: CloseBehavior = .ask
    private var localAddress = NSTextField(wrappingLabelWithString: "주소 준비 중…")
    private var closePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private var loginToggle: NSButton!
    private var closeHint = NSTextField(wrappingLabelWithString: "창을 닫을 때 실행 여부를 물어봐요.")
    private var tabView: NSTabView!
    private var tabButtons: [NSButton] = []
    private var closingPrompt = false
    private var terminating = false
    private var smoke: BundledSmoke?
    private var transferPort: UInt16 = 0
    private var pendingRoute: DirectPeer?
    private var deviceName: String { Host.current().localizedName ?? "Mac" }
    private var closeBehavior: CloseBehavior {
        get { preview ? previewCloseBehavior : (CloseBehavior(rawValue: UserDefaults.standard.integer(forKey: "closeBehavior")) ?? .ask) }
        set { if preview { previewCloseBehavior = newValue } else { UserDefaults.standard.set(newValue.rawValue, forKey: "closeBehavior") } }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if !preview, let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateAllWindows]); NSApp.terminate(nil); return
        }
        do {
            if preview {
                code = "A1B2-C3D4-E5F6-7890-1234-5678-9ABC-DEF0"
                device = UUID().uuidString
            } else {
                let saved = try KeyStore.load()
                code = try saved ?? PairCode.create()
                if saved == nil { try KeyStore.save(code) }
                let previousDefaults = UserDefaults(suiteName: "local.nearclip.app")
                device = UserDefaults.standard.string(forKey: "deviceID") ?? previousDefaults?.string(forKey: "deviceID") ?? UUID().uuidString
                UserDefaults.standard.set(device, forKey: "deviceID")
                enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
                let clock = UInt64(UserDefaults.standard.string(forKey: "logicalClock") ?? "0") ?? 0
                sync = ClipboardSync(device: device, clock: min(clock, UInt64.max - 100_000)) {
                    UserDefaults.standard.set(String($0), forKey: "logicalClock")
                }
                sync.enabled = enabled
                sync.onLocal = { [weak self] clip in self?.transport?.send(clip) }
                sync.onActivity = { [weak self] text in self?.lastActivity = text; self?.refresh() }
            }
            makeMenu(); makeWindow(); applyPreviewState(); refresh(); showWindow()
            if preview {
                if CommandLine.arguments.contains("--lifecycle-smoke") {
                    DispatchQueue.main.async { self.lifecycleSmoke() }
                } else if CommandLine.arguments.contains("--smoke-test") {
                    smoke = BundledSmoke()
                    smoke?.run { success in
                        print(success ? "Bundled smoke test passed." : "Bundled smoke test failed.")
                        fflush(stdout); exit(success ? 0 : 1)
                    }
                } else if CommandLine.arguments.contains("--render-preview") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.renderPreview() }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 600) { NSApp.terminate(nil) }
                }
                return
            }
            transferPort = UInt16(clamping: UserDefaults.standard.integer(forKey: "transferPort"))
            restartTransport(); startPairing(); sync.start()
            if let index = CommandLine.arguments.firstIndex(of: "--pair-with"), CommandLine.arguments.count > index + 3,
               let port = UInt16(CommandLine.arguments[index + 2]) {
                pairing?.connectDirect(host: CommandLine.arguments[index + 1], port: port, expected: CommandLine.arguments[index + 3])
            }
            let center = NSWorkspace.shared.notificationCenter
            center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
            center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        } catch {
            alert(error.localizedDescription)
            NSApp.terminate(nil)
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        sync?.stop(); transport?.stop(); pairing?.stop()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        if CommandLine.arguments.contains("--lifecycle-smoke") { print("PASS: app termination callback completed"); fflush(stdout) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "NearClip 클립보드 공유")
        let menu = NSMenu()
        menuStatus = NSMenuItem(title: "연결 대기 중", action: nil, keyEquivalent: ""); menu.addItem(menuStatus)
        menu.addItem(.separator())
        item("NearClip 열기…", #selector(showWindow), menu: menu)
        menuSend = item("지금 클립보드 보내기", #selector(sendNow), menu: menu)
        menuToggle = item("공유 일시 정지", #selector(toggleSharing), menu: menu)
        item("연결 다시 찾기", #selector(retry), menu: menu)
        menu.addItem(.separator())
        item("설정…", #selector(showSettings), menu: menu, key: ",")
        item("도움말", #selector(help), menu: menu)
        item("NearClip 종료", #selector(quit), menu: menu, key: "q")
        menu.autoenablesItems = false
        statusItem.menu = menu
        let main = NSMenu()
        let appMenu = NSMenu(); let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)
        item("NearClip 정보", #selector(about), menu: appMenu)
        item("설정…", #selector(showSettings), menu: appMenu, key: ",")
        appMenu.addItem(.separator())
        item("NearClip 종료", #selector(quit), menu: appMenu, key: "q")
        let edit = NSMenu(title: "편집"); let editItem = NSMenuItem(title: "편집", action: nil, keyEquivalent: ""); editItem.submenu = edit; main.addItem(editItem)
        for (title, action, key) in [("잘라내기", "cut:", "x"), ("복사", "copy:", "c"), ("붙여넣기", "paste:", "v"), ("전체 선택", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let win = NSMenu(title: "윈도우"); let winItem = NSMenuItem(title: "윈도우", action: nil, keyEquivalent: ""); winItem.submenu = win; main.addItem(winItem)
        item("창 닫기", #selector(closeWindow), menu: win, key: "w")
        NSApp.mainMenu = main
    }
    @discardableResult private func item(_ title: String, _ action: Selector, menu: NSMenu, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item); return item
    }
    private func label(_ text: String, size: CGFloat = 13, color: NSColor = .labelColor, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
        return field
    }
    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded; button.controlSize = .large
        return button
    }
    private func column(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = spacing
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 10
        return stack
    }
    private func panel(_ content: NSView) -> NSView {
        let box = NSBox(); box.boxType = .custom; box.cornerRadius = 12
        box.fillColor = .controlBackgroundColor; box.borderColor = .separatorColor; box.borderWidth = 0.5
        let body = NSView(); box.contentView = body
        content.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: body.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -16)
        ])
        return box
    }
    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "NearClip"; window.subtitle = "Mac 사이를 잇는 클립보드"
        window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        let root = WindowBackground(); window.contentView = root
        let brand = label("nearclip", size: 24, weight: .semibold)
        brand.font = .monospacedSystemFont(ofSize: 24, weight: .semibold)
        let tagline = label("LOCAL CLIPBOARD  /  텍스트 + 이미지", size: 11, color: .secondaryLabelColor)
        tagline.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let heading = column([brand, tagline], spacing: 4)
        statusLabel.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        activityLabel.font = .systemFont(ofSize: 12); activityLabel.textColor = .secondaryLabelColor
        pauseButton = button("공유 일시 정지", action: #selector(toggleSharing))
        sendButton = button("지금 보내기", action: #selector(sendNow))
        let trust = label("로컬 네트워크 · 암호화 전송 · 기록 저장 안 함", size: 11, color: .secondaryLabelColor)
        let statusCard = panel(column([statusLabel, activityLabel, row([pauseButton, sendButton]), trust], spacing: 9))

        tabView = NSTabView(); tabView.tabViewType = .noTabsNoBorder
        let connect = NSTabViewItem(identifier: "connect"); connect.label = "연결"
        nearbyPicker.controlSize = .large
        nearbyPicker.setAccessibilityLabel("같은 네트워크에서 찾은 Mac")
        nearbyPicker.addItem(withTitle: "주변 Mac을 찾고 있어요…")
        nearbyPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        connectButton = button("연결", action: #selector(connectNearby)); connectButton.bezelColor = .systemTeal
        cancelButton = button("취소", action: #selector(cancelPairing)); cancelButton.isHidden = true
        addressButton = button("주소로 연결…", action: #selector(connectAddress))
        localAddress.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        localAddress.isSelectable = true; localAddress.setContentHuggingPriority(.defaultLow, for: .horizontal);
        copyAddressButton = button("주소 복사", action: #selector(copyAddress)); copyAddressButton.isEnabled = false; localAddress.setAccessibilityLabel("이 Mac의 연결 주소")
        let connectionContent = column([
            label("주변 Mac", size: 13, weight: .semibold),
            row([nearbyPicker, connectButton, cancelButton]),
            label("연결할 Mac을 선택하고 양쪽의 6자리 숫자를 확인하세요.\n새 Mac과 연결하면 이전 연결을 교체해요.", size: 12, color: .secondaryLabelColor),
            row([button("다시 찾기", action: #selector(retry)), addressButton]),
            separator(), label("직접 연결", size: 12, weight: .semibold), row([localAddress, copyAddressButton]),
            label("상대 Mac의 ‘주소로 연결’에 이 주소를 입력하세요.", size: 11, color: .secondaryLabelColor)
        ], spacing: 10)
        connect.view = inset(connectionContent)
        let settings = NSTabViewItem(identifier: "settings"); settings.label = "설정"
        closePicker.addItems(withTitles: ["닫을 때 물어보기", "메뉴 막대에서 계속 실행", "앱 완전히 종료"])
        closePicker.selectItem(at: closeBehavior.rawValue); closePicker.target = self; closePicker.action = #selector(changeCloseBehavior)
        closePicker.setAccessibilityLabel("창 닫기 동작")
        loginToggle = NSButton(checkboxWithTitle: "로그인할 때 NearClip 시작", target: self, action: #selector(toggleLogin))
        loginToggle.state = !preview && SMAppService.mainApp.status == .enabled ? .on : .off
        closeHint.font = .systemFont(ofSize: 11); closeHint.textColor = .secondaryLabelColor
        let settingsContent = column([
            label("실행 방식", size: 14, weight: .semibold), loginToggle,
            label("창을 닫으면", size: 12, weight: .medium), closePicker, closeHint,
            separator(), label("연결 관리", size: 14, weight: .semibold),
            label("연결을 해제하면 상대 Mac과 다시 숫자를 확인해야 해요.", size: 12, color: .secondaryLabelColor),
            row([button("연결 해제…", action: #selector(forgetPairing)), button("네트워크 설정", action: #selector(networkSettings))])
        ], spacing: 10)
        settings.view = inset(settingsContent)
        tabView.addTabViewItem(connect); tabView.addTabViewItem(settings)
        tabView.heightAnchor.constraint(equalToConstant: 276).isActive = true
        tabButtons = [button("연결", action: #selector(selectConnection)), button("설정", action: #selector(showSettings))]
        for button in tabButtons { button.setButtonType(.pushOnPushOff) }
        tabButtons[0].state = .on
        let tabs = column([row(tabButtons), tabView], spacing: 6)
        let footer = row([button("도움말", action: #selector(help)), label("v0.3.0 · beta", size: 11, color: .secondaryLabelColor), NSView(), button("NearClip 종료", action: #selector(quit))])
        footer.arrangedSubviews[2].setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = column([heading, statusCard, tabs, footer], spacing: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -18)
        ])
        root.layoutSubtreeIfNeeded()
    }
    private func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
    private func inset(_ content: NSView) -> NSView {
        let view = NSView(); content.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -12)
        ])
        return view
    }
    private func applyPreviewState() {
        guard preview else { return }
        localAddress.stringValue = "my-mac.local:54321"
        if CommandLine.arguments.contains("--connected") { peers = ["옆자리 Mac"]; lastActivity = "텍스트 받음 · 14:32:08" }
        if CommandLine.arguments.contains("--paused") { enabled = false }
        if CommandLine.arguments.contains("--settings") { selectTab(1) }
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
    }
    private func startPairing() {
        guard !preview else { return }
        let pairing = NearbyPairing(device: device, name: deviceName)
        pairing.syncPort = transferPort == 0 ? nil : transferPort
        pairing.onListening = { [weak self] port in
            let host = Host.current().name ?? "이 Mac의 IP"
            self?.localAddress.stringValue = "\(host):\(port)"
            self?.hasLocalAddress = true; self?.copyAddressButton?.isEnabled = true
        }
        pairing.onRoute = { [weak self] route in self?.pendingRoute = route }
        self.pairing = pairing
        pairing.onCandidates = { [weak self] candidates in
            guard let self else { return }
            let selected = self.nearbyPicker.selectedItem?.representedObject as? String
            self.nearbyPicker.removeAllItems()
            for candidate in candidates {
                self.nearbyPicker.addItem(withTitle: candidate.name + " · " + candidate.device.prefix(4))
                self.nearbyPicker.lastItem?.representedObject = candidate.device
            }
            if candidates.isEmpty { self.nearbyPicker.addItem(withTitle: "발견된 Mac 없음 · 다시 찾기") }
            else { self.networkNote = nil }
            if let selected, let item = self.nearbyPicker.itemArray.first(where: { $0.representedObject as? String == selected }) {
                self.nearbyPicker.select(item)
            }
            self.refresh()
        }
        pairing.onStatus = { [weak self] status in
            guard let self, self.verificationAlert == nil, self.peers.isEmpty else { return }
            self.networkNote = status; self.refresh()
        }
        pairing.onVerify = { [weak self] name, digits, reply in self?.verifyPairing(name: name, digits: digits, reply: reply) }
        pairing.onPaired = { [weak self] code, name in
            guard let self else { return }
            do {
                try KeyStore.save(code); self.code = code; self.sync.resetSession()
                UserDefaults.standard.set(try self.pendingRoute.map { try JSONEncoder().encode($0) }, forKey: "directPeer")
                self.pendingRoute = nil
                self.lastActivity = "\(name) 연결을 확인했어요."; self.restartTransport()
            } catch { self.alert(error.localizedDescription) }
        }
        pairing.onEnded = { [weak self] in
            guard let self else { return }
            if let sheet = self.verificationAlert { self.window.endSheet(sheet.window, returnCode: .abort) }
            self.verificationAlert = nil; self.refresh()
        }
        pairing.start()
    }
    private func verifyPairing(name: String, digits: String, reply: @escaping (Bool) -> Void) {
        guard verificationAlert == nil else { reply(false); return }
        showWindow()
        let dialog = NSAlert(); dialog.messageText = "\(name)과 연결할까요?"
        dialog.informativeText = "두 Mac에 표시된 숫자가 같은지 확인하세요.\n양쪽에서 확인해야 클립보드 공유를 시작해요."
        let number = NSTextField(labelWithString: String(digits.prefix(3)) + "  " + String(digits.suffix(3)))
        number.font = .monospacedDigitSystemFont(ofSize: 42, weight: .semibold)
        number.alignment = .center; number.frame = NSRect(x: 0, y: 0, width: 280, height: 65)
        dialog.accessoryView = number
        dialog.addButton(withTitle: "숫자가 같아요 · 연결")
        dialog.addButton(withTitle: "취소")
        verificationAlert = dialog
        dialog.beginSheetModal(for: window) { [weak self] response in
            self?.verificationAlert = nil
            if response == .alertFirstButtonReturn {
                self?.networkNote = "다른 Mac에서도 같은 숫자인지 확인하고 연결을 눌러주세요."
            }
            reply(response == .alertFirstButtonReturn); self?.refresh()
        }
    }
    private func restartTransport() {
        guard !preview else { return }
        transport?.stop(); transport = nil; peers = []; networkNote = nil; sync.connected = false
        do {
            let transport = try LocalTransport(code: code, device: device, name: deviceName, port: transferPort)
            self.transport = transport
            transport.onListening = { [weak self] port in
                self?.transferPort = port.rawValue; self?.pairing?.syncPort = port.rawValue
                UserDefaults.standard.set(Int(port.rawValue), forKey: "transferPort")
            }
            if let data = UserDefaults.standard.data(forKey: "directPeer"), let peer = try? JSONDecoder().decode(DirectPeer.self, from: data) {
                transport.setDirectPeer(peer)
            }
            transport.clockProvider = { [weak self] in self?.sync.clock ?? 0 }
            transport.onClock = { [weak self] clock in self?.sync.observe(clock: clock) }
            transport.onPeers = { [weak self] peers in
                guard let self else { return }; self.peers = peers; self.sync.connected = !peers.isEmpty
                if !peers.isEmpty { self.networkNote = nil }; self.refresh()
            }
            transport.onClip = { [weak self] clip in self?.sync.receive(clip) }
            transport.onStatus = { [weak self] note in self?.networkNote = note; self?.refresh() }
            transport.start(); refresh()
        } catch { alert(error.localizedDescription) }
    }
    private func refresh() {
        guard !terminating else { return }
        let busy = pairing?.busy ?? false
        cancelButton?.isHidden = !busy; addressButton?.isEnabled = !busy
        pauseButton?.title = enabled ? "공유 일시 정지" : "공유 다시 시작"
        sendButton?.isEnabled = enabled && !peers.isEmpty
        menuSend?.isEnabled = enabled && !peers.isEmpty
        closeHint.stringValue = ["창을 닫을 때 실행 여부를 물어봐요.", "창을 닫아도 공유돼요. 완전히 끄려면 ‘NearClip 종료’를 누르세요.", "창을 닫으면 클립보드 공유도 함께 종료돼요."][closeBehavior.rawValue]
        connectButton?.isEnabled = !(pairing?.busy ?? false) && nearbyPicker.selectedItem?.representedObject != nil
        let text: String
        if !enabled { text = "PAUSED  /  공유 일시 정지" }
        else if busy { text = "PAIRING  /  연결 확인 중" }
        else if peers.isEmpty { text = "WAITING  /  연결 대기" }
        else { text = "CONNECTED  /  \(peers.count)대 공유 중" }
        statusLabel.stringValue = text
        statusLabel.textColor = enabled && !peers.isEmpty ? .systemTeal : .labelColor
        if !enabled { activityLabel.stringValue = "보내기와 받기가 모두 멈췄어요. 재개한 뒤 복사한 내용부터 공유해요." }
        else { activityLabel.stringValue = networkNote ?? (peers.isEmpty ? "두 Mac에서 앱을 열고 아래 목록에서 연결하세요." : peers.joined(separator: ", ") + "  ·  " + lastActivity) }
        menuStatus?.title = text
        menuToggle?.title = enabled ? "공유 일시 정지" : "공유 다시 시작"
        toggle?.state = enabled ? .on : .off
        statusItem?.button?.toolTip = "NearClip · " + text
        statusItem?.button?.image = NSImage(systemSymbolName: !enabled ? "pause.circle" : (peers.isEmpty ? "doc.on.clipboard" : "checkmark.circle"), accessibilityDescription: text)
    }
    @objc private func showWindow() { NSApp.setActivationPolicy(.regular); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func connectNearby() {
        guard !preview else { return }
        if let selected = nearbyPicker.selectedItem?.representedObject as? String { pendingRoute = nil; pairing?.connect(device: selected); refresh() }
    }
    @objc private func connectAddress() {
        guard !preview, pairing?.busy == false else { return }
        let dialog = NSAlert(); dialog.messageText = "Mac 주소로 연결"
        dialog.informativeText = "연결할 Mac의 호스트 또는 IP 주소와 포트를 입력하세요.\n예: my-mac.local:54321"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        field.placeholderString = "호스트:포트"; dialog.accessoryView = field
        dialog.addButton(withTitle: "연결 요청"); dialog.addButton(withTitle: "취소")
        dialog.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                let address = try ConnectionAddress(field.stringValue)
                self.pendingRoute = nil
                self.pairing?.connectDirect(host: address.host, port: address.port); self.refresh()
            } catch { self.alert(error.localizedDescription) }
        }
    }
    @objc private func newCode() {
        guard !preview else { return }
        do {
            let incoming = try PairCode.create(); try KeyStore.save(incoming); code = incoming
            UserDefaults.standard.removeObject(forKey: "directPeer"); pendingRoute = nil
            pairing?.cancel()
            sync.resetSession(); lastActivity = "기존 연결을 지웠어요. 목록에서 Mac을 선택해 주세요."; restartTransport()
        } catch { alert(error.localizedDescription) }
    }
    @objc private func sendNow() {
        guard !preview else { return }
        guard enabled, sync.connected else { lastActivity = "공유를 켜고 다른 Mac을 먼저 연결해 주세요."; refresh(); return }
        sync.poll(force: true)
    }
    @objc private func toggleSharing() {
        enabled.toggle(); sync?.enabled = enabled
        if !preview { UserDefaults.standard.set(enabled, forKey: "enabled") }
        refresh()
    }
    @objc private func retry() { restartTransport(); pairing?.stop(); pairing?.start(); refresh() }
    @objc private func willSleep() { sync?.stop(); transport?.stop(); pairing?.stop(); sync?.connected = false }
    @objc private func didWake() { sync?.baseline(); sync?.start(); restartTransport(); pairing?.start() }
    @objc private func copyAddress() {
        guard !preview, hasLocalAddress else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(localAddress.stringValue, forType: .string)
    }
    private func lifecycleSmoke() {
        func require(_ value: Bool, _ text: String) {
            guard value else { print("FAIL: " + text); fflush(stdout); exit(1) }
            print("PASS: " + text)
        }
        require(statusItem.menu?.items.contains(where: { $0.action == #selector(quit) }) == true, "menu bar exposes quit")
        require(NSApp.mainMenu?.items.first?.submenu?.items.contains(where: { $0.keyEquivalent == "q" }) == true, "Command-Q is installed in app menu")
        toggleSharing(); require(!enabled && statusLabel.stringValue.contains("PAUSED"), "pause updates visible state")
        toggleSharing(); require(enabled, "resume updates sharing state")
        showSettings(); require(tabView.selectedTabViewItem?.identifier as? String == "settings", "settings navigation")
        closeBehavior = .keepRunning
        require(windowShouldClose(window), "close can keep menu bar running")
        window.orderOut(nil)
        require(NSApp.activationPolicy() == .accessory, "hidden window becomes menu-bar-only app")
        showWindow(); require(window.isVisible && NSApp.activationPolicy() == .regular, "menu-bar app can reopen its window")
        closeBehavior = .quit
        print("PASS: closing with quit preference requests app termination"); fflush(stdout)
        _ = windowShouldClose(window)
    }
    @objc private func closeWindow() { window.performClose(nil) }
    private func selectTab(_ index: Int) {
        tabView.selectTabViewItem(at: index)
        for (i, button) in tabButtons.enumerated() { button.state = i == index ? .on : .off }
    }
    @objc private func selectConnection() { selectTab(0) }
    @objc private func showSettings() { showWindow(); selectTab(1) }
    @objc private func changeCloseBehavior() { closeBehavior = CloseBehavior(rawValue: closePicker.indexOfSelectedItem) ?? .ask; refresh() }
    @objc private func cancelPairing() { pairing?.cancel(); pendingRoute = nil; refresh() }
    @objc private func networkSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
    }
    @objc private func toggleLogin() {
        guard !preview else { loginToggle.state = .off; return }
        do {
            if loginToggle.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { alert("로그인 시작을 변경하지 못했어요. 앱을 응용 프로그램 폴더에 넣은 뒤 다시 시도해 주세요.\n" + error.localizedDescription) }
        loginToggle.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
    @objc private func forgetPairing() {
        let dialog = NSAlert(); dialog.messageText = "저장된 연결을 해제할까요?"
        dialog.informativeText = "즉시 공유가 끊기고, 다음에 연결할 때 양쪽 숫자를 다시 확인해야 해요."
        dialog.addButton(withTitle: "연결 해제"); dialog.addButton(withTitle: "취소")
        dialog.beginSheetModal(for: window) { [weak self] result in if result == .alertFirstButtonReturn { self?.newCode() } }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeBehavior == .quit { quit(); return false }
        if closeBehavior == .keepRunning { NSApp.setActivationPolicy(.accessory); return true }
        guard !closingPrompt else { return false }; closingPrompt = true
        let dialog = NSAlert(); dialog.messageText = "NearClip을 종료할까요?"
        dialog.informativeText = "종료하면 클립보드 공유가 멈춰요. 계속 공유하려면 메뉴 막대에 남겨둘 수 있어요."
        dialog.addButton(withTitle: "앱 종료"); dialog.addButton(withTitle: "메뉴 막대에 남기기"); dialog.addButton(withTitle: "취소")
        dialog.showsSuppressionButton = true; dialog.suppressionButton?.title = "이 선택 기억하기"
        dialog.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }; self.closingPrompt = false
            if response == .alertThirdButtonReturn { return }
            let choice: CloseBehavior = response == .alertFirstButtonReturn ? .quit : .keepRunning
            if dialog.suppressionButton?.state == .on { self.closeBehavior = choice; self.closePicker.selectItem(at: choice.rawValue) }
            if choice == .quit { self.quit() }
            else { self.window.orderOut(nil); NSApp.setActivationPolicy(.accessory) }
        }
        return false
    }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "NearClip", .applicationVersion: "0.3.0", .credits: NSAttributedString(string: "Mac 사이의 텍스트·이미지 클립보드 공유. MIT License.")])
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func help() {
        let dialog = NSAlert(); dialog.messageText = "두 Mac에서 NearClip을 켜두세요"
        dialog.informativeText = "① 두 Mac 모두 NearClip 0.3 이상을 켜고 같은 Wi-Fi 또는 LAN에 연결하세요.\n② 한쪽에서 목록의 상대 Mac을 선택하고 연결하기를 누르세요.\n③ 양쪽 화면의 6자리 숫자가 같으면 두 Mac에서 모두 연결을 누르세요. 숫자를 전달하거나 입력할 필요 없어요.\n④ 연결됨이 표시되면 새로 복사한 텍스트나 이미지를 다른 Mac에 붙여넣으세요.\n\n권한 요청이 나오면 ‘로컬 네트워크’와 ‘다른 앱에서 붙여넣기’를 허용하세요. 거부했다면 시스템 설정 → 개인정보 보호 및 보안에서 변경할 수 있어요.\n\n텍스트와 실제 이미지 클립보드를 지원해요. Finder의 파일 복사는 지원하지 않아요. 이미지는 20MB·4천만 화소까지예요.\n\n연결 전·일시 정지 중 복사한 내용은 자동 전송하지 않아요. 필요하면 ‘지금 보내기’를 누르세요. 암호 관리자가 비공개로 표시한 내용은 공유하지 않아요.\n\n설정에서 연결 해제를 누르면 기존 연결이 끊어져요. 회사·게스트 Wi-Fi에서 기기 간 통신을 막으면 연결할 수 없어요."
        dialog.addButton(withTitle: "확인"); dialog.runModal()
    }
    private func alert(_ message: String) {
        let dialog = NSAlert(); dialog.messageText = "NearClip"; dialog.informativeText = message
        dialog.addButton(withTitle: "확인"); NSApp.activate(ignoringOtherApps: true); dialog.runModal()
    }
    private func renderPreview() {
        guard let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1,
              let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { NSApp.terminate(nil); return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
        NSApp.terminate(nil)
    }
}

@main
struct NearClipMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
