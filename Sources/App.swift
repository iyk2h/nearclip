import AppKit
import ServiceManagement

final class WindowBackground: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
}

final class DeviceList: NSStackView { override var isFlipped: Bool { true } }

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let files = FileTransfer()
    private var mouse: MouseSharing!
    private var featurePeer: ConnectedPeer?
    private var fileButton: NSButton!
    private var fileCancel: NSButton!
    private var revealButton: NSButton!
    private var mouseToggle: NSButton!
    private var sidePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let layoutLabel = NSTextField(wrappingLabelWithString: "연결한 Mac의 화면 배치를 여기서 정해요.")
    private let mouseHint = NSTextField(wrappingLabelWithString: "양쪽에서 마우스 공유를 켜주세요.")
    private let fileLabel = NSTextField(wrappingLabelWithString: "파일 하나를 선택하면 상대가 저장 위치를 정해요.")
    private let fileProgress = NSProgressIndicator()
    private var receivePanel: NSSavePanel?
    private var receivedFile: URL?
    private var menuMouseStop: NSMenuItem!
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
    private var candidates: [(device: String, name: String)] = []
    private var deviceList: NSStackView!
    private var discoveryView: NSView!
    private var trustedView: NSView!
    private var advancedView: NSView!
    private var advancedButton: NSButton!
    private var advanced = false
    private var tabHeight: NSLayoutConstraint!
    private var mainStack: NSStackView!
    private var peerLabel = NSTextField(labelWithString: "")
    private var peerDetail = NSTextField(wrappingLabelWithString: "")
    private let pairingHint = NSTextField(wrappingLabelWithString: "")
    private var trustLabel = NSTextField(wrappingLabelWithString: "")
    private var statusIcon: NSImageView!
    private var sharingActions: NSView!
    private var access = PairingAccess(hasTrustedPeer: false)
    private var pairedName: String?
    private var discoveryDeadline: Timer?
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
                pairedName = UserDefaults.standard.string(forKey: "pairedMacName")
                access = PairingAccess(hasTrustedPeer: pairedName != nil || UserDefaults.standard.data(forKey: "directPeer") != nil)
                let clock = UInt64(UserDefaults.standard.string(forKey: "logicalClock") ?? "0") ?? 0
                sync = ClipboardSync(device: device, clock: min(clock, UInt64.max - 100_000)) {
                    UserDefaults.standard.set(String($0), forKey: "logicalClock")
                }
                sync.enabled = enabled
                sync.onLocal = { [weak self] clip in self?.transport?.send(clip) }
                sync.onActivity = { [weak self] text in self?.lastActivity = text; self?.refresh() }
            }
            configureSharing(); makeMenu(); makeWindow(); applyPreviewState(); refresh(); showWindow()
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
            restartTransport(); startPairing(); sync.start(); files.startTimer()
            if let index = CommandLine.arguments.firstIndex(of: "--pair-with"), CommandLine.arguments.count > index + 3,
               let port = UInt16(CommandLine.arguments[index + 2]) {
                if access.hasTrustedPeer { openDiscovery() }
                pairing?.connectDirect(host: CommandLine.arguments[index + 1], port: port, expected: CommandLine.arguments[index + 3])
            }
            let center = NSWorkspace.shared.notificationCenter
            center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
            center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
            center.addObserver(self, selector: #selector(stopInput), name: NSWorkspace.screensDidSleepNotification, object: nil)
            center.addObserver(self, selector: #selector(stopInput), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(stopInput), name: NSApplication.didChangeScreenParametersNotification, object: nil)
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(stopInput), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        } catch {
            alert(error.localizedDescription)
            NSApp.terminate(nil)
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        mouse?.stop(); files.stop()
        discoveryDeadline?.invalidate(); sync?.stop(); transport?.stop(); pairing?.stop()
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
        item("파일·마우스 공유…", #selector(showSharing), menu: menu)
        menuMouseStop = item("마우스 공유 끄기  ⌃⌥Esc", #selector(stopInput), menu: menu)
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
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
    private func column(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = spacing
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 10; stack.distribution = .fill
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
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    private func symbol(_ name: String, size: CGFloat = 24) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        view.contentTintColor = .secondaryLabelColor
        view.widthAnchor.constraint(equalToConstant: size + 8).isActive = true
        view.heightAnchor.constraint(equalToConstant: size + 8).isActive = true
        return view
    }
    private func flexible(_ view: NSView) -> NSView {
        view.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "NearClip"; window.isReleasedWhenClosed = false
        window.delegate = self; window.center()
        let root = WindowBackground(); window.contentView = root
        let brand = label("nearclip", size: 20, weight: .semibold)
        brand.font = .monospacedSystemFont(ofSize: 20, weight: .semibold)
        let tagline = label("LOCAL SHARING", size: 10, color: .secondaryLabelColor)
        tagline.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        tabButtons = [button("연결", action: #selector(selectConnection)), button("공유", action: #selector(showSharing)), button("설정", action: #selector(showSettings))]
        for button in tabButtons { button.setButtonType(.pushOnPushOff); button.controlSize = .regular }
        tabButtons[0].state = .on
        let heading = row([flexible(column([brand, tagline], spacing: 3)), row(tabButtons)])
        statusLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        activityLabel.font = .systemFont(ofSize: 12); activityLabel.textColor = .secondaryLabelColor
        activityLabel.maximumNumberOfLines = 3
        statusIcon = symbol("laptopcomputer", size: 32)
        pauseButton = button("공유 일시 정지", action: #selector(toggleSharing))
        sendButton = button("지금 보내기", action: #selector(sendNow))
        sendButton.toolTip = "현재 클립보드의 텍스트나 이미지를 한 번 보내요."
        sharingActions = row([pauseButton, sendButton, flexible(NSView())])
        trustLabel.font = .systemFont(ofSize: 11); trustLabel.textColor = .secondaryLabelColor
        let statusCard = panel(column([
            row([statusIcon, flexible(column([statusLabel, activityLabel], spacing: 5))]),
            sharingActions, separator(), trustLabel
        ], spacing: 14))

        tabView = NSTabView(); tabView.tabViewType = .noTabsNoBorder
        let connect = NSTabViewItem(identifier: "connect"); connect.label = "연결"
        cancelButton = button("찾기 취소", action: #selector(cancelDiscovery))
        cancelButton.controlSize = .regular
        addressButton = button("주소로 연결…", action: #selector(connectAddress))
        localAddress.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        localAddress.isSelectable = true; _ = flexible(localAddress)
        copyAddressButton = button("주소 복사", action: #selector(copyAddress))
        copyAddressButton.isEnabled = false; localAddress.setAccessibilityLabel("이 Mac의 연결 주소")
        deviceList = DeviceList(); deviceList.orientation = .vertical; deviceList.alignment = .leading; deviceList.spacing = 0
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.documentView = deviceList
        deviceList.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            deviceList.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            deviceList.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            deviceList.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 116)
        ])
        advancedButton = button("Mac이 보이지 않나요?", action: #selector(toggleAdvanced))
        advancedButton.bezelStyle = .inline; advancedButton.controlSize = .regular
        advancedView = column([
            label("두 Mac에서 로컬 네트워크 권한을 허용하세요.\n주소로 연결할 때도 양쪽 숫자를 확인해야 해요.", size: 11, color: .secondaryLabelColor),
            row([localAddress, copyAddressButton]),
            row([addressButton, button("네트워크 권한", action: #selector(networkSettings)), flexible(NSView())])
        ], spacing: 8)
        advancedView.isHidden = true
        pairingHint.font = .systemFont(ofSize: 11); pairingHint.textColor = .secondaryLabelColor
        discoveryView = column([
            row([flexible(label("주변 Mac", size: 13, weight: .semibold)), cancelButton, button("다시 찾기", action: #selector(retry))]),
            scroll,
            pairingHint,
            row([advancedButton, flexible(NSView())]), advancedView
        ], spacing: 10)
        peerLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        peerLabel.lineBreakMode = .byTruncatingTail
        peerDetail.font = .systemFont(ofSize: 11); peerDetail.textColor = .secondaryLabelColor
        trustedView = column([
            label("저장된 Mac", size: 11, color: .secondaryLabelColor, weight: .medium),
            row([symbol("laptopcomputer"), flexible(column([peerLabel, peerDetail], spacing: 4)), button("다른 Mac 연결", action: #selector(openDiscovery))]),
            label("새 연결 요청은 닫혀 있어요. 저장된 Mac에는 자동으로 다시 연결해요.", size: 11, color: .secondaryLabelColor)
        ], spacing: 12)
        connect.view = inset(column([discoveryView, trustedView], spacing: 0))
        let sharing = NSTabViewItem(identifier: "sharing"); sharing.label = "공유"
        sidePicker.addItems(withTitles: ["왼쪽", "오른쪽"]); sidePicker.selectItem(at: 1)
        sidePicker.target = self; sidePicker.action = #selector(changeSide)
        sidePicker.setAccessibilityLabel("상대 Mac의 화면 위치")
        layoutLabel.font = .systemFont(ofSize: 14, weight: .semibold); layoutLabel.maximumNumberOfLines = 2
        mouseToggle = NSButton(checkboxWithTitle: "마우스 공유 켜기", target: self, action: #selector(toggleMouse))
        mouseHint.font = .systemFont(ofSize: 11); mouseHint.textColor = .secondaryLabelColor
        fileButton = button("파일 보내기…", action: #selector(sendFile))
        fileCancel = button("전송 취소", action: #selector(cancelFile)); fileCancel.isHidden = true
        revealButton = button("Finder에서 보기", action: #selector(revealFile)); revealButton.isHidden = true
        fileLabel.font = .systemFont(ofSize: 11); fileLabel.textColor = .secondaryLabelColor
        fileLabel.maximumNumberOfLines = 2
        fileProgress.isIndeterminate = false; fileProgress.minValue = 0; fileProgress.maxValue = 1
        fileProgress.style = .bar; fileProgress.isHidden = true
        sharing.view = inset(column([
            label("화면 배치", size: 13, weight: .semibold), layoutLabel,
            row([label("상대 Mac 위치", size: 12), sidePicker, flexible(NSView())]),
            label("한쪽에서 바꾸면 양쪽에 반영돼요. 화면 끝으로 밀면 넘어가요.", size: 11, color: .secondaryLabelColor),
            mouseToggle, mouseHint,
            row([button("손쉬운 사용", action: #selector(accessibilitySettings)), button("입력 모니터링", action: #selector(inputSettings)), flexible(NSView())]),
            separator(), label("파일 전송", size: 13, weight: .semibold),
            row([fileButton, fileCancel, revealButton, flexible(NSView())]), fileLabel, fileProgress
        ], spacing: 9))
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
            row([button("연결 해제…", action: #selector(forgetPairing)), button("네트워크 설정", action: #selector(networkSettings)), flexible(NSView())])
        ], spacing: 10)
        settings.view = inset(settingsContent)
        tabView.addTabViewItem(connect); tabView.addTabViewItem(sharing); tabView.addTabViewItem(settings)
        tabHeight = tabView.heightAnchor.constraint(equalToConstant: 250); tabHeight.isActive = true
        let footer = row([button("도움말", action: #selector(help)), label("v" + version + " · beta", size: 10, color: .secondaryLabelColor), flexible(NSView()), button("종료  ⌘Q", action: #selector(quit))])
        let stack = column([heading, statusCard, tabView, separator(), footer], spacing: 18)
        mainStack = stack
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20)
        ])
        rebuildDevices()
        root.layoutSubtreeIfNeeded()
    }
    private func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
    private func inset(_ content: NSView) -> NSView {
        let view = NSView(); content.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 0),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 0),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -12)
        ])
        return view
    }
    private func applyPreviewState() {
        guard preview else { return }
        localAddress.stringValue = "my-mac.local:54321"
        if CommandLine.arguments.contains("--connected") || CommandLine.arguments.contains("--offline") {
            pairedName = "Studio MacBook Pro"; access = PairingAccess(hasTrustedPeer: true)
        }
        if CommandLine.arguments.contains("--connected") { peers = ["Studio MacBook Pro"]; lastActivity = "텍스트 받음 · 14:32:08" }
        if CommandLine.arguments.contains("--nearby") {
            candidates = [("A1B20000-0000-0000-0000-000000000001", "Studio MacBook Pro"), ("C3D40000-0000-0000-0000-000000000002", "Design Mac mini")]
            rebuildDevices()
        }
        if CommandLine.arguments.contains("--advanced") { advanced = true }
        if CommandLine.arguments.contains("--invite") { access.open() }
        hasLocalAddress = true
        if CommandLine.arguments.contains("--paused") { enabled = false }
        if CommandLine.arguments.contains("--settings") { selectTab(2) }
        if CommandLine.arguments.contains("--sharing") { selectTab(1) }
        if !peers.isEmpty {
            featurePeer = ConnectedPeer(device: "B0000000-0000-0000-0000-000000000001", name: peers[0], connection: UUID(), features: Set(SharingFeature.supported))
            mouse.setPeer(featurePeer!.device)
        }
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
            self.candidates = candidates.map { ($0.device, $0.name) }
            if !candidates.isEmpty { self.networkNote = nil }
            self.rebuildDevices(); self.refresh()
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
                self.pairedName = name; UserDefaults.standard.set(name, forKey: "pairedMacName")
                self.access.didPair(); self.discoveryDeadline?.invalidate()
                // Stop accepting new requests without interrupting delivery of our confirmation.
                self.pairing?.endDiscovery()
                self.lastActivity = "\(name) 연결을 확인했어요."; self.restartTransport()
            } catch { self.alert(error.localizedDescription) }
        }
        pairing.onEnded = { [weak self] in
            guard let self else { return }
            if let sheet = self.verificationAlert { self.window.endSheet(sheet.window, returnCode: .abort) }
            self.verificationAlert = nil
            if !self.access.isOpen { self.pairing?.endDiscovery() }
            self.refresh()
        }
        if access.isOpen { pairing.start() }; refresh()
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
                if let name = peers.first {
                    self.networkNote = nil; self.pairedName = name
                    UserDefaults.standard.set(name, forKey: "pairedMacName")
                    self.access.didAuthenticate()
                    if !self.access.isOpen { self.pairing?.endDiscovery() }
                }
                self.refresh()
            }
            transport.onPeerDetails = { [weak self] peers in self?.updateFeaturePeer(peers) }
            transport.onFeature = { [weak self] peer, packet in
                guard let self, peer == self.featurePeer?.device else { return }
                if let file = packet.file {
                    if self.enabled { self.files.receive(file, from: peer) }
                    else if file.kind == .offer { self.transport?.sendFeature(FeaturePacket(file: FilePacket(kind: .cancel, id: file.id)), to: peer) }
                }
                if let mouse = packet.mouse { self.mouse.receive(mouse, from: peer) }
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
        let text: String
        if busy { text = "양쪽 숫자를 확인하세요" }
        else if !enabled { text = "공유가 일시 정지됐어요" }
        else if !peers.isEmpty { text = "클립보드 공유 중" }
        else if access.hasTrustedPeer { text = "Mac을 기다리고 있어요" }
        else { text = "옆 Mac과 연결하세요" }
        statusLabel.stringValue = text
        statusLabel.textColor = .labelColor
        statusIcon?.image = NSImage(systemSymbolName: busy ? "number.circle" : (!enabled ? "pause.circle" : (peers.isEmpty ? "laptopcomputer" : "checkmark.shield")), accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 32, weight: .regular))
        statusIcon?.contentTintColor = !peers.isEmpty && enabled ? .systemTeal : .secondaryLabelColor
        if !enabled { activityLabel.stringValue = "보내기와 받기를 멈췄어요. 재개한 뒤 복사한 내용부터 공유해요." }
        else if busy { activityLabel.stringValue = networkNote ?? "두 Mac에서 같은 숫자인지 확인하고 연결을 눌러주세요." }
        else if !peers.isEmpty { activityLabel.stringValue = lastActivity }
        else { activityLabel.stringValue = networkNote ?? (access.hasTrustedPeer ? "상대 Mac에서 NearClip을 켜면 자동으로 연결돼요." : "같은 네트워크에서 텍스트와 이미지를 복사하고 붙여넣으세요.") }
        sharingActions?.isHidden = !access.hasTrustedPeer && peers.isEmpty
        pairingHint.stringValue = access.hasTrustedPeer ? "양쪽 숫자를 확인하면 저장된 연결을 새 Mac으로 교체해요." : "상대 Mac의 ‘연결’을 누른 뒤, 양쪽의 6자리 숫자를 확인하세요."
        trustLabel.stringValue = access.isOpen && access.hasTrustedPeer ? "새 연결 허용 중 · 2분 뒤 자동 닫힘 · 양쪽 숫자 확인 필수" : access.isOpen ? "새 Mac 연결 허용 중 · 양쪽 숫자 확인 필수" : "인증된 Mac과 암호화 전송 · 클립보드 기록 저장 안 함"
        discoveryView?.isHidden = !access.isOpen
        trustedView?.isHidden = access.isOpen
        advancedView?.isHidden = !advanced
        advancedButton?.title = advanced ? "연결 도움말 접기 ▴" : "Mac이 보이지 않나요? ▾"
        cancelButton?.isHidden = !access.hasTrustedPeer && !busy
        cancelButton?.title = busy ? "연결 취소" : "찾기 취소"
        copyAddressButton?.isEnabled = hasLocalAddress && access.isOpen
        peerLabel.stringValue = peers.first ?? pairedName ?? "저장된 Mac"
        peerDetail.stringValue = peers.isEmpty ? "오프라인 · 자동 재연결 대기" : "연결됨 · 텍스트 + 이미지"
        for view in deviceList?.arrangedSubviews ?? [] {
            (view as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSButton }.forEach { $0.isEnabled = !busy }
        }
        updateSharingUI()
        if mouse?.mode == .controlling { statusLabel.stringValue = "상대 Mac 마우스 제어 중"; activityLabel.stringValue = "돌아오려면 반대쪽 끝으로 이동하세요. 긴급 해제: ⌃⌥Esc" }
        if mouse?.mode == .receiving { statusLabel.stringValue = "다른 Mac의 마우스로 제어 중"; activityLabel.stringValue = "이 Mac의 마우스를 움직이면 제어가 돌아와요. 긴급 해제: ⌃⌥Esc" }
        updateWindowSize()
        menuStatus?.title = statusLabel.stringValue
        menuToggle?.title = enabled ? "공유 일시 정지" : "공유 다시 시작"
        toggle?.state = enabled ? .on : .off
        statusItem?.button?.toolTip = "NearClip · " + statusLabel.stringValue
        statusItem?.button?.image = NSImage(systemSymbolName: !enabled ? "pause.circle" : (peers.isEmpty ? "doc.on.clipboard" : "checkmark.circle"), accessibilityDescription: text)
    }
    @objc private func showWindow() { NSApp.setActivationPolicy(.regular); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    private func rebuildDevices() {
        guard let deviceList else { return }
        for view in deviceList.arrangedSubviews { deviceList.removeArrangedSubview(view); view.removeFromSuperview() }
        if candidates.isEmpty {
            let empty = column([
                label("다른 Mac에서도 NearClip을 켜주세요", size: 13, weight: .medium),
                label("이미 연결한 Mac이라면 ‘다른 Mac 연결’을 누르세요.\n발견하면 이곳에 표시돼요.", size: 11, color: .secondaryLabelColor)
            ], spacing: 6)
            deviceList.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: deviceList.widthAnchor).isActive = true
        }
        for candidate in candidates {
            let name = label(candidate.name, size: 13, weight: .medium)
            name.maximumNumberOfLines = 1; name.lineBreakMode = .byTruncatingTail
            let identity = label("Mac · " + candidate.device.prefix(4), size: 10, color: .secondaryLabelColor)
            identity.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            let connect = button("연결", action: #selector(connectNearby(_:)))
            connect.identifier = NSUserInterfaceItemIdentifier(candidate.device)
            connect.setAccessibilityLabel(candidate.name + "에 연결")
            let item = row([symbol("laptopcomputer", size: 22), flexible(column([name, identity], spacing: 3)), connect])
            item.heightAnchor.constraint(equalToConstant: 54).isActive = true
            deviceList.addArrangedSubview(item); item.widthAnchor.constraint(equalTo: deviceList.widthAnchor).isActive = true
        }
    }
    private func updateWindowSize() {
        guard let tabView, let window else { return }
        let settings = tabView.selectedTabViewItem?.identifier as? String == "settings"
        let sharing = tabView.selectedTabViewItem?.identifier as? String == "sharing"
        let height: CGFloat = sharing ? (fileProgress.isHidden ? 304 : 326) : settings ? 250 : (access.isOpen ? (advanced ? 342 : 228) : 108)
        tabHeight.constant = height
        window.contentView?.layoutSubtreeIfNeeded()
        let contentHeight = ceil(mainStack.fittingSize.height + 44)
        if abs((window.contentView?.bounds.height ?? 0) - contentHeight) > 1 {
            var frame = window.frame
            let newHeight = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 560, height: contentHeight)).height
            frame.origin.y += frame.height - newHeight; frame.size.height = newHeight
            window.setFrame(frame, display: true)
        }
    }
    @objc private func toggleAdvanced() { advanced.toggle(); refresh() }
    @objc private func openDiscovery() {
        access.open(); advanced = false; networkNote = nil; hasLocalAddress = false
        localAddress.stringValue = "주소 준비 중…"
        discoveryDeadline?.invalidate()
        pairing?.invitationDeadline = Date().addingTimeInterval(120)
        let timer = Timer(timeInterval: 120, repeats: false) { [weak self] _ in self?.cancelDiscovery() }
        discoveryDeadline = timer; RunLoop.main.add(timer, forMode: .common)
        if !preview { pairing?.start() }
        selectTab(0); refresh()
    }
    @objc private func cancelDiscovery() {
        // A first-time user can cancel a handshake and keep discovering.
        if !access.hasTrustedPeer { pairing?.cancel(); pendingRoute = nil; refresh(); return }
        access.close(); discoveryDeadline?.invalidate(); pairing?.stop()
        pendingRoute = nil; networkNote = nil; hasLocalAddress = false; refresh()
    }
    @objc private func connectNearby(_ sender: NSButton) {
        guard !preview, access.isOpen, let selected = sender.identifier?.rawValue else { return }
        pendingRoute = nil; pairing?.connect(device: selected); refresh()
    }
    @objc private func connectAddress() {
        guard !preview, access.isOpen, pairing?.busy == false else { return }
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
            pairedName = nil; UserDefaults.standard.removeObject(forKey: "pairedMacName")
            access = PairingAccess(hasTrustedPeer: false); discoveryDeadline?.invalidate()
            pairing?.stop(); pairing?.invitationDeadline = nil; pairing?.start()
            sync.resetSession(); lastActivity = "기존 연결을 지웠어요. 목록에서 Mac을 선택해 주세요."; restartTransport()
        } catch { alert(error.localizedDescription) }
    }
    @objc private func sendNow() {
        guard !preview else { return }
        guard enabled, sync.connected else { lastActivity = "공유를 켜고 다른 Mac을 먼저 연결해 주세요."; refresh(); return }
        sync.poll(force: true)
    }
    @objc private func toggleSharing() {
        enabled.toggle();
        if !enabled { mouse?.stop(); files.cancel() }
         sync?.enabled = enabled
        if !preview { UserDefaults.standard.set(enabled, forKey: "enabled") }
        refresh()
    }
    @objc private func retry() { restartTransport(); pairing?.stop(); hasLocalAddress = false; if access.isOpen { pairing?.start() }; refresh() }
    @objc private func willSleep() { mouse?.stop(); files.cancel(); sync?.stop(); transport?.stop(); pairing?.stop(); sync?.connected = false }
    @objc private func didWake() { sync?.baseline(); sync?.start(); restartTransport(); if access.isOpen { pairing?.start() } }
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
        toggleSharing(); require(!enabled && statusLabel.stringValue.contains("일시 정지"), "pause updates visible state")
        toggleSharing(); require(enabled, "resume updates sharing state")
        showSharing(); require(tabView.selectedTabViewItem?.identifier as? String == "sharing", "file and mouse controls are reachable")
        require(!mouse.enabled, "mouse capture starts disabled")
        try? mouse.setEnabled(true); toggleSharing()
        require(!mouse.enabled && !enabled, "global pause revokes mouse capture")
        toggleSharing()
        showSettings(); require(tabView.selectedTabViewItem?.identifier as? String == "settings", "settings navigation")
        access = PairingAccess(hasTrustedPeer: true); refresh()
        require(!access.isOpen && discoveryView.isHidden, "trusted peer hides new pairing controls")
        openDiscovery(); require(access.isOpen && !discoveryView.isHidden, "explicit action opens new pairing")
        cancelDiscovery(); require(!access.isOpen && discoveryView.isHidden, "cancel closes new pairing")
        let stableFrame = window.frame
        for _ in 0..<10 { refresh() }
        require(window.frame == stableFrame, "repeated status updates keep window position and size stable")
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
        for (i, button) in tabButtons.enumerated() { button.state = i == index ? .on : .off }; updateWindowSize()
    }
    @objc private func selectConnection() { selectTab(0) }
    @objc private func showSettings() { showWindow(); selectTab(2) }
    @objc private func showSharing() { showWindow(); selectTab(1) }
    @objc private func changeCloseBehavior() { closeBehavior = CloseBehavior(rawValue: closePicker.indexOfSelectedItem) ?? .ask; refresh() }
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
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "NearClip", .applicationVersion: version, .credits: NSAttributedString(string: "Mac 사이의 클립보드·파일·마우스 공유. MIT License.")])
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func help() {
        let dialog = NSAlert(); dialog.messageText = "두 Mac에서 NearClip을 켜두세요"
        dialog.informativeText = "① 두 Mac 모두 NearClip 0.3 이상을 켜고 같은 Wi-Fi 또는 LAN에 연결하세요.\n② 한쪽에서 상대 Mac 옆의 ‘연결’을 누르세요.\n③ 양쪽 화면의 6자리 숫자가 같으면 두 Mac에서 모두 연결을 누르세요. 숫자를 전달하거나 입력할 필요 없어요.\n④ 연결됨이 표시되면 새로 복사한 텍스트나 이미지를 다른 Mac에 붙여넣으세요.\n\n권한 요청이 나오면 ‘로컬 네트워크’와 ‘다른 앱에서 붙여넣기’를 허용하세요. 거부했다면 시스템 설정 → 개인정보 보호 및 보안에서 변경할 수 있어요.\n\n텍스트와 실제 이미지 클립보드를 지원해요. Finder의 파일 복사는 지원하지 않아요. 이미지는 20MB·4천만 화소까지예요.\n\n연결 전·일시 정지 중 복사한 내용은 자동 전송하지 않아요. 필요하면 ‘지금 보내기’를 누르세요. 암호 관리자가 비공개로 표시한 내용은 공유하지 않아요.\n\n설정에서 연결 해제를 누르면 기존 연결이 끊어져요. 회사·게스트 Wi-Fi에서 기기 간 통신을 막으면 연결할 수 없어요."
        dialog.informativeText += "\n\n공유 탭에서 파일을 보내거나 화면 배치를 정할 수 있어요. 마우스 공유는 양쪽에서 직접 켜야 해요. 화면 가장자리로 밀어 이동하고 ⌃⌥Esc로 즉시 끄세요. 키보드 입력은 이 Mac에 남아요. 파일은 상대가 저장 위치를 선택해야 전송돼요."
        dialog.addButton(withTitle: "확인"); dialog.runModal()
    }
    private func alert(_ message: String) {
        let dialog = NSAlert(); dialog.messageText = "NearClip"; dialog.informativeText = message
        dialog.addButton(withTitle: "확인"); NSApp.activate(ignoringOtherApps: true); dialog.runModal()
    }
    private func configureSharing() {
        mouse = MouseSharing(local: device, native: !preview)
        mouse.send = { [weak self] peer, packet, reply in
            guard let self, let transport = self.transport else { reply(false); return }
            transport.sendFeature(FeaturePacket(mouse: packet), to: peer, completion: reply)
        }
        mouse.onChange = { [weak self] in if self?.window != nil { self?.refresh() } }
        mouse.onLayout = { [weak self] layout in
            guard let self, !self.preview else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(layout), forKey: "screenLayout")
        }
        files.send = { [weak self] peer, packet, reply in
            guard let transport = self?.transport else { reply(false); return }
            transport.sendFeature(FeaturePacket(file: packet), to: peer, completion: reply)
        }
        files.onStatus = { [weak self] text, progress, busy in
            guard let self else { return }
            self.fileLabel.stringValue = text; self.fileProgress.isHidden = progress == nil
            self.fileProgress.doubleValue = progress ?? 0; self.fileCancel?.isHidden = !busy
            if !busy, let panel = self.receivePanel { panel.cancel(nil); self.receivePanel = nil }
            self.refresh()
        }
        files.onOffer = { [weak self] _, offer in self?.receiveFile(offer) }
        files.onComplete = { [weak self] url in self?.receivedFile = url; self?.revealButton?.isHidden = url == nil }
    }
    private func updateFeaturePeer(_ peers: [ConnectedPeer]) {
        let next = peers.count == 1 ? peers.first : nil
        guard featurePeer?.connection != next?.connection else { updateSharingUI(); return }
        files.disconnected(); mouse.endSession(notify: false)
        featurePeer = next
        let saved = UserDefaults.standard.data(forKey: "screenLayout").flatMap { try? JSONDecoder().decode(ScreenLayout.self, from: $0) }
        mouse.setPeer(next?.features.contains(SharingFeature.mouse) == true ? next?.device : nil, savedLayout: saved)
        updateSharingUI()
    }
    private func updateSharingUI() {
        guard mouseToggle != nil else { return }
        let supportsFiles = featurePeer?.features.contains(SharingFeature.files) == true
        let supportsMouse = featurePeer?.features.contains(SharingFeature.mouse) == true
        fileButton.isEnabled = enabled && supportsFiles && !files.busy
        sidePicker.isEnabled = supportsMouse && !mouse.active
        mouseToggle.isEnabled = enabled && supportsMouse
        mouseToggle.state = mouse.enabled ? .on : .off
        sidePicker.selectItem(at: mouse.side == .left ? 0 : 1)
        let name = featurePeer?.name ?? "상대 Mac"
        layoutLabel.stringValue = mouse.side == .right ? "이 Mac   ↔   " + name : name + "   ↔   이 Mac"
        if !supportsMouse { mouseHint.stringValue = "두 Mac 모두 0.4 이상으로 연결하면 사용할 수 있어요." }
        else if !mouse.enabled { mouseHint.stringValue = "양쪽에서 켜주세요. 이동·클릭·스크롤을 공유해요. 긴급 해제: ⌃⌥Esc" }
        else if !mouse.remoteEnabled { mouseHint.stringValue = "이 Mac은 준비됐어요. 상대 Mac에서도 마우스 공유를 켜주세요." }
        else { mouseHint.stringValue = "준비됐어요. 가장자리로 밀어 이동하세요. ⌃⌥Esc는 공유를 꺼요." }
        menuMouseStop?.isEnabled = mouse.enabled
    }
    @objc private func changeSide() { mouse.setSide(sidePicker.indexOfSelectedItem == 0 ? .left : .right) }
    @objc private func toggleMouse() {
        do { try mouse.setEnabled(mouseToggle.state == .on) }
        catch {
            mouseToggle.state = .off
            if !preview { MouseSharing.requestPermissions() }
            alert(error.localizedDescription)
        }
        refresh()
    }
    @objc private func stopInput() { mouse?.stop(); if window != nil { refresh() } }
    @objc private func accessibilitySettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    @objc private func inputSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!) }
    @objc private func sendFile() {
        guard !preview, enabled, let peer = featurePeer, peer.features.contains(SharingFeature.files), !files.busy else { return }
        let panel = NSOpenPanel(); panel.title = "보낼 파일 선택"; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "일반 파일 하나를 2GB까지 보내요. 원본은 이 Mac에 남아요."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url, self.enabled, self.featurePeer?.connection == peer.connection else { return }
            do { try self.files.offer(url: url, to: peer.device) } catch { self.alert(error.localizedDescription) }
        }
    }
    private func receiveFile(_ offer: FilePacket) {
        guard !preview, enabled, window.attachedSheet == nil else { files.decline(id: offer.id); return }
        mouse.endSession(); showSharing()
        let panel = NSSavePanel(); panel.title = "파일 받기"; panel.nameFieldStringValue = offer.name ?? "파일"
        panel.message = "\(featurePeer?.name ?? "상대 Mac")에서 보낸 파일 · " + ByteCountFormatter.string(fromByteCount: offer.size ?? 0, countStyle: .file) + "\n저장 위치를 선택하면 전송을 시작해요. 기존 파일은 덮어쓰지 않아요."
        panel.prompt = "받기"; panel.canCreateDirectories = true; receivePanel = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }; self.receivePanel = nil
            if response == .OK, let url = panel.url { self.files.accept(id: offer.id, destination: url) }
            else { self.files.decline(id: offer.id) }
        }
    }
    @objc private func cancelFile() { files.cancel() }
    @objc private func revealFile() { if let receivedFile { NSWorkspace.shared.activateFileViewerSelecting([receivedFile]) } }
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
