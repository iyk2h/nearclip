import AppKit
import ServiceManagement

final class WindowBackground: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
}

final class DeviceList: NSStackView { override var isFlipped: Bool { true } }

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let files = FileTransfer()
    private var mouse: MouseSharing!
    private let edgeIndicator = ControlEdgeIndicator()
    private var featurePeer: ConnectedPeer?
    private let peerVersionLabel = NSTextField(wrappingLabelWithString: "")
    private let healthLabel = NSTextField(wrappingLabelWithString: "연결 후 입력 지연을 측정해요.")
    private var inputHealth: InputHealth?
    private let updateChecker = UpdateChecker()
    private var updateTimer: Timer?
    private var updateDownload: URL?
    private let updateLabel = NSTextField(wrappingLabelWithString: "새 버전을 확인하고 앱에서 설치할 수 있어요. 베타 배포를 포함해요.")
    private var updateButton: NSButton!
    private var updateDownloadButton: NSButton!
    private var autoUpdateToggle: NSButton!
    private var updateMenu: NSMenuItem?
    private var fileButton: NSButton!
    private var fileCancel: NSButton!
    private var fileActions: NSView!
    private var revealButton: NSButton!
    private var mouseToggle: NSSwitch!
    private let inputTitle = NSTextField(labelWithString: "마우스·키보드")
    private let inputStatusLabel = NSTextField(labelWithString: "꺼짐")
    private var permissionActions: NSView!
    private var connectionHint = NSTextField(wrappingLabelWithString: "")
    private let arrangement = ScreenArrangementView(frame: .zero)
    private var swapScreens: NSButton!
    private let arrangementHint = NSTextField(wrappingLabelWithString: "화면을 드래그해 실제 Mac의 좌우 순서에 맞춰주세요.")
    private let mouseHint = NSTextField(wrappingLabelWithString: "양쪽에서 마우스 공유를 켜주세요.")
    private let gestureHint = NSTextField(wrappingLabelWithString: "")
    private let fileLabel = NSTextField(wrappingLabelWithString: "파일 하나를 선택하면 상대가 저장 위치를 정해요.")
    private let fileProgress = NSProgressIndicator()
    private var receivePanel: NSSavePanel?
    private var receivedFile: URL?
    private var menuMouseStop: NSMenuItem!
    private var menuMouseToggle: NSMenuItem!
    private var menuScreenOrder: NSMenuItem!
    private var menuSwapScreens: NSMenuItem!
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
    private let headlessDiagnostics = CommandLine.arguments.contains("--update-component-check") || CommandLine.arguments.contains("--update-check") || CommandLine.arguments.contains("--render-preview") || CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--lifecycle-smoke")
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
    private var bodyHeight: NSLayoutConstraint!
    private var bodyScroll: NSScrollView!
    private var bodyContent: NSStackView!
    private var settingsContent: NSView!
    private var settingsButton: NSButton!
    private var statusSummary: NSView!
    private var settingsExpanded = false
    private var mouseDetails: NSView!
    private var mouseDetailsExpanded = false
    private var mouseDisclosure: NSButton!
    private var permissionLabel = NSTextField(wrappingLabelWithString: "")
    private var mouseSetupError: String?
    private var permissions = MousePermissions(accessibility: false, posting: false, monitoring: false)
    private var mainStack: NSStackView!
    private var peerLabel = NSTextField(labelWithString: "")
    private var peerDetail = NSTextField(wrappingLabelWithString: "")
    private let pairingHint = NSTextField(wrappingLabelWithString: "")
    private var trustLabel = NSTextField(wrappingLabelWithString: "")
    private var statusIcon: NSImageView!
    private var sharingActions: NSView!
    private var sharingContent: NSView!
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
    private var relayToggle: NSButton!
    private var preventAppleRelay = true
    private var closeHint = NSTextField(wrappingLabelWithString: "창을 닫을 때 실행 여부를 물어봐요.")
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
        NSApp.setActivationPolicy(headlessDiagnostics ? .accessory : .regular)
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if CommandLine.arguments.contains("--update-check") {
            updateChecker.check { result in
                switch result {
                case .success(let release):
                    print("PASS: public release check; latest=\(release?.tag_name ?? "none") upgrade=\(release?.version.map { AppVersion.current < $0 } ?? false)")
                    fflush(stdout); exit(0)
                case .failure:
                    print("FAIL: public release check unavailable."); fflush(stdout); exit(1)
                }
            }
            return
        }
        if CommandLine.arguments.contains("--update-component-check") {
            do { _ = try UpdateInstaller.verifiedHelper(); print("PASS: update component signature and nested code verified."); fflush(stdout); exit(0) }
            catch { print("FAIL: update component rejected."); fflush(stdout); exit(1) }
        }
        if CommandLine.arguments.contains("--keychain-check") {
            let success = KeyStore.checkWithoutPrompt()
            print(success ? "PASS: pairing key is readable without a prompt." : "FAIL: pairing key requires authorization or helper verification failed.")
            fflush(stdout); exit(success ? 0 : 1)
        }
        if !preview, let bundleID = Foundation.Bundle.main.bundleIdentifier,
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
                preventAppleRelay = UserDefaults.standard.object(forKey: "preventAppleRelay") as? Bool ?? true
                pairedName = UserDefaults.standard.string(forKey: "pairedMacName")
                access = PairingAccess(hasTrustedPeer: pairedName != nil || UserDefaults.standard.data(forKey: "directPeer") != nil)
                let clock = UInt64(UserDefaults.standard.string(forKey: "logicalClock") ?? "0") ?? 0
                sync = ClipboardSync(device: device, clock: min(clock, UInt64.max - 100_000), backgroundIO: true, persist: {
                    UserDefaults.standard.set(String($0), forKey: "logicalClock")
                })
                sync.enabled = enabled
                sync.onLocal = { [weak self] clip in self?.transport?.send(clip) }
                sync.onActivity = { [weak self] text in self?.lastActivity = text; self?.refresh() }
            }
            sync?.preventAppleRelay = preventAppleRelay
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
            center.addObserver(self, selector: #selector(displaySlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
            center.addObserver(self, selector: #selector(displayWoke), name: NSWorkspace.screensDidWakeNotification, object: nil)
            center.addObserver(self, selector: #selector(sessionDeactivated), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(sessionActivated), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenLocked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenUnlocked), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
            configureUpdates()
        } catch {
            alert(error.localizedDescription)
            NSApp.terminate(nil)
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        updateTimer?.invalidate(); updateChecker.cancel()
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
        let menuIcon = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "NearClip")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        if let menuIcon {
            // Symbol point size is not its image bounds. Keep the actual glyph
            // compact beside other menu extras without changing the hit target.
            let scale = 14 / max(menuIcon.size.width, menuIcon.size.height)
            menuIcon.size = NSSize(width: menuIcon.size.width * scale, height: menuIcon.size.height * scale)
            menuIcon.isTemplate = true
        }
        statusItem.button?.image = menuIcon
        statusItem.button?.imagePosition = .imageOnly
        let menu = NSMenu()
        menuStatus = NSMenuItem(title: "연결 대기 중", action: nil, keyEquivalent: ""); menu.addItem(menuStatus)
        menu.addItem(.separator())
        item("NearClip 열기…", #selector(showWindow), menu: menu)
        menuSend = item("지금 클립보드 보내기", #selector(sendNow), menu: menu)
        menuToggle = item("공유 일시 정지", #selector(toggleSharing), menu: menu)
        menuMouseToggle = item("마우스·키보드 공유", #selector(toggleMouseFromMenu), menu: menu)
        menuScreenOrder = NSMenuItem(title: "화면 배치 · 연결 대기", action: nil, keyEquivalent: "")
        menu.addItem(menuScreenOrder)
        menuSwapScreens = item("화면 좌우 바꾸기", #selector(swapScreenOrder), menu: menu)
        item("파일·화면 배치…", #selector(showSharing), menu: menu)
        menuMouseStop = item("마우스·키보드 공유 끄기  ⌃⌥Esc", #selector(stopInput), menu: menu)
        item("연결 다시 찾기", #selector(retry), menu: menu)
        menu.addItem(.separator())
        item("설정…", #selector(showSettings), menu: menu, key: ",")
        updateMenu = item("업데이트 확인…", #selector(checkUpdates), menu: menu)
        item("도움말", #selector(help), menu: menu)
        item("NearClip 종료", #selector(quit), menu: menu, key: "q")
        menu.autoenablesItems = false
        statusItem.menu = menu
        let main = NSMenu()
        let appMenu = NSMenu(); let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)
        item("NearClip 정보", #selector(about), menu: appMenu)
        item("업데이트 확인…", #selector(checkUpdates), menu: appMenu)
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
        button.bezelStyle = .rounded; button.controlSize = .regular
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
    private func column(_ views: [NSView], spacing: CGFloat = 12, flipped: Bool = false) -> NSStackView {
        let stack: NSStackView = flipped ? DeviceList(views: views) : NSStackView(views: views); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = spacing
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 10; stack.distribution = .fill
        return stack
    }
    private func panel(_ content: NSView) -> NSView {
        let box = NSBox(); box.boxType = .custom; box.cornerRadius = 10
        box.fillColor = .controlBackgroundColor; box.borderColor = .separatorColor; box.borderWidth = 0.5
        let body = NSView(); box.contentView = body
        content.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: body.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -14)
        ])
        return box
    }
    private var version: String { Foundation.Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    private var buildNumber: String { Foundation.Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev" }
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
        let brand = label("nearclip", size: 17, weight: .semibold)
        brand.font = .monospacedSystemFont(ofSize: 17, weight: .semibold)
        let tagline = label("두 Mac, 하나의 작업 공간", size: 11, color: .secondaryLabelColor)
        settingsButton = button("설정", action: #selector(toggleSettings))
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settingsButton.imagePosition = .imageLeading
        let heading = row([flexible(column([brand, tagline], spacing: 3)), settingsButton])
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        activityLabel.font = .systemFont(ofSize: 11); activityLabel.textColor = .secondaryLabelColor
        activityLabel.maximumNumberOfLines = 2
        statusIcon = symbol("circle.dotted", size: 16)
        pauseButton = button("일시 정지", action: #selector(toggleSharing))
        sendButton = button("지금 보내기", action: #selector(sendNow))
        sendButton.toolTip = "현재 클립보드의 텍스트나 이미지를 한 번 보내요."
        sharingActions = pauseButton
        connectionHint.font = .systemFont(ofSize: 11); connectionHint.textColor = .secondaryLabelColor
        connectionHint.maximumNumberOfLines = 3
        trustLabel.font = .systemFont(ofSize: 10); trustLabel.textColor = .secondaryLabelColor
        let statusCard = column([
            row([statusIcon, flexible(statusLabel), pauseButton]), connectionHint
        ], spacing: 6)
        statusSummary = statusCard

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
        advancedButton.controlSize = .small
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
        trustedView = panel(row([
            symbol("laptopcomputer", size: 26), flexible(column([peerLabel, peerDetail], spacing: 4)),
            button("Mac 변경…", action: #selector(openDiscovery))
        ]))
        arrangement.heightAnchor.constraint(equalToConstant: 164).isActive = true
        arrangement.onCommit = { [weak self] side in
            guard let self, self.featurePeer?.features.contains(SharingFeature.mouse) == true, !self.mouse.active else { return }
            self.mouse.setSide(side)
        }
        swapScreens = button("순서 바꾸기", action: #selector(swapScreenOrder))
        swapScreens.controlSize = .small
        swapScreens.setAccessibilityLabel("두 Mac의 화면 순서 바꾸기")
        arrangementHint.font = .systemFont(ofSize: 11); arrangementHint.textColor = .secondaryLabelColor
        arrangementHint.maximumNumberOfLines = 2
        mouseToggle = NSSwitch(); mouseToggle.target = self; mouseToggle.action = #selector(toggleMouse)
        mouseToggle.setAccessibilityLabel("마우스·키보드 공유")
        mouseToggle.setContentHuggingPriority(.required, for: .horizontal)
        inputTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        inputStatusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        inputStatusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        mouseHint.font = .systemFont(ofSize: 11); mouseHint.textColor = .secondaryLabelColor
        fileButton = button("파일 보내기…", action: #selector(sendFile))
        fileCancel = button("전송 취소", action: #selector(cancelFile)); fileCancel.isHidden = true
        revealButton = button("Finder에서 보기", action: #selector(revealFile)); revealButton.isHidden = true
        fileLabel.font = .systemFont(ofSize: 11); fileLabel.textColor = .secondaryLabelColor
        fileLabel.maximumNumberOfLines = 2
        fileProgress.isIndeterminate = false; fileProgress.minValue = 0; fileProgress.maxValue = 1
        fileProgress.style = .bar; fileProgress.isHidden = true
        mouseDisclosure = button("화면 배치 ▸", action: #selector(toggleMouseDetails))
        mouseDisclosure.controlSize = .small
        permissionLabel.font = .systemFont(ofSize: 11); permissionLabel.textColor = .secondaryLabelColor
        permissionLabel.maximumNumberOfLines = 3
        permissionActions = row([button("손쉬운 사용", action: #selector(accessibilitySettings)), button("입력 모니터링", action: #selector(inputSettings)), button("다시 확인", action: #selector(recheckPermissions)), flexible(NSView())])
        gestureHint.font = .systemFont(ofSize: 11); gestureHint.textColor = .secondaryLabelColor
        gestureHint.maximumNumberOfLines = 3
        mouseDetails = column([
            separator(), row([flexible(label("화면 배치", size: 12, weight: .semibold)), swapScreens]),
            arrangement, arrangementHint, gestureHint, permissionLabel, permissionActions
        ], spacing: 8)
        mouseDetails.isHidden = true
        peerVersionLabel.font = .systemFont(ofSize: 11); peerVersionLabel.textColor = .secondaryLabelColor
        peerVersionLabel.maximumNumberOfLines = 3
        healthLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        healthLabel.textColor = .secondaryLabelColor; healthLabel.maximumNumberOfLines = 5
        let clipboardCard = panel(row([
            symbol("doc.on.clipboard", size: 20),
            flexible(column([label("클립보드", size: 13, weight: .semibold), activityLabel], spacing: 5)), sendButton
        ]))
        let inputCard = panel(column([
            row([symbol("keyboard", size: 20), flexible(inputTitle), inputStatusLabel, mouseDisclosure, mouseToggle]),
            mouseHint, label("이 Mac의 선택을 기억해요 · 긴급 정지 ⌃⌥Esc", size: 10, color: .secondaryLabelColor), mouseDetails
        ], spacing: 8))
        fileActions = row([fileCancel, revealButton, flexible(NSView())]); fileActions.isHidden = true
        let fileCard = panel(column([
            row([symbol("arrow.up.doc", size: 20), flexible(column([label("파일 전송", size: 13, weight: .semibold), fileLabel], spacing: 5)), fileButton]),
            fileProgress, fileActions
        ], spacing: 8))
        let sharing = column([clipboardCard, inputCard, fileCard], spacing: 10)
        sharingContent = sharing
        closePicker.addItems(withTitles: ["닫을 때 물어보기", "메뉴 막대에서 계속 실행", "앱 완전히 종료"])
        closePicker.selectItem(at: closeBehavior.rawValue); closePicker.target = self; closePicker.action = #selector(changeCloseBehavior)
        closePicker.setAccessibilityLabel("창 닫기 동작")
        loginToggle = NSButton(checkboxWithTitle: "로그인할 때 NearClip 시작", target: self, action: #selector(toggleLogin))
        loginToggle.state = !preview && SMAppService.mainApp.status == .enabled ? .on : .off
        closeHint.font = .systemFont(ofSize: 11); closeHint.textColor = .secondaryLabelColor
        relayToggle = NSButton(checkboxWithTitle: "받은 클립보드의 Apple 기기 재공유 막기", target: self, action: #selector(toggleAppleRelay))
        relayToggle.state = preventAppleRelay ? .on : .off
        updateButton = button("업데이트 확인", action: #selector(checkUpdates))
        updateDownloadButton = button("업데이트 및 재시작…", action: #selector(downloadUpdate)); updateDownloadButton.isHidden = true
        autoUpdateToggle = NSButton(checkboxWithTitle: "새 버전 자동 확인 (하루 한 번)", target: self, action: #selector(toggleAutomaticUpdates))
        autoUpdateToggle.state = (UserDefaults.standard.object(forKey: "automaticUpdateChecks") as? Bool ?? true) ? .on : .off
        updateLabel.font = .systemFont(ofSize: 11); updateLabel.textColor = .secondaryLabelColor; updateLabel.maximumNumberOfLines = 3
        settingsContent = column([
            separator(), label("업데이트", size: 14, weight: .semibold), autoUpdateToggle, updateLabel,
            row([updateButton, updateDownloadButton, button("공개 배포 보기", action: #selector(openReleases)), flexible(NSView())]),
            label("설치를 선택하면 앱을 교체하고 다시 열어요. 연결 정보는 유지돼요. 두 Mac을 각각 업데이트하세요.", size: 11, color: .secondaryLabelColor),
            separator(), label("연결 진단", size: 14, weight: .semibold), peerVersionLabel, healthLabel,
            row([button("다시 연결", action: #selector(retry)), button("Apple 마우스 공유 안내", action: #selector(universalControlHelp)), flexible(NSView())]),
            label("왕복은 입력 채널의 응답 시간이에요. 실제 화면 반영 시간과는 달라요. 최근 최대 60회만 메모리에 보관해요.", size: 11, color: .secondaryLabelColor),
            separator(), label("클립보드 보호", size: 14, weight: .semibold), relayToggle,
            label("다음에 NearClip으로 받는 내용부터 적용돼요. 다른 앱에서 복사한 내용에는 적용되지 않아요.", size: 11, color: .secondaryLabelColor),
            row([button("Apple 클립보드 설정 안내", action: #selector(appleClipboardHelp)), flexible(NSView())]),
            separator(), label("실행 방식", size: 14, weight: .semibold), loginToggle,
            label("창을 닫으면", size: 12, weight: .medium), closePicker, closeHint,
            separator(), label("연결 관리", size: 14, weight: .semibold),
            label("연결을 해제하면 상대 Mac과 다시 숫자를 확인해야 해요.", size: 12, color: .secondaryLabelColor),
            row([button("연결 해제…", action: #selector(forgetPairing)), button("네트워크 설정", action: #selector(networkSettings)), button("키체인 안내", action: #selector(keychainHelp)), flexible(NSView())])
        ], spacing: 10)
        settingsContent.isHidden = true
        bodyContent = column([column([discoveryView, trustedView], spacing: 0), sharing, settingsContent], spacing: 12, flipped: true)
        bodyScroll = NSScrollView(); bodyScroll.drawsBackground = false
        bodyScroll.hasVerticalScroller = true; bodyScroll.autohidesScrollers = true
        bodyScroll.documentView = bodyContent
        bodyContent.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bodyContent.leadingAnchor.constraint(equalTo: bodyScroll.contentView.leadingAnchor),
            bodyContent.topAnchor.constraint(equalTo: bodyScroll.contentView.topAnchor),
            bodyContent.widthAnchor.constraint(equalTo: bodyScroll.contentView.widthAnchor)
        ])
        bodyHeight = bodyScroll.heightAnchor.constraint(equalToConstant: 260); bodyHeight.isActive = true
        let helpButton = button("도움말", action: #selector(help)); helpButton.controlSize = .small
        let quitButton = button("종료 ⌘Q", action: #selector(quit)); quitButton.controlSize = .small
        let footer = row([label("v" + version + " · " + buildNumber + " beta", size: 10, color: .secondaryLabelColor), flexible(NSView()), helpButton, quitButton])
        let stack = column([heading, statusCard, bodyScroll, trustLabel, footer], spacing: 14)
        mainStack = stack
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16)
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
        if CommandLine.arguments.contains("--settings") { settingsExpanded = true }
        if CommandLine.arguments.contains("--sharing") { mouseDetailsExpanded = true }
        if !peers.isEmpty {
            featurePeer = ConnectedPeer(device: "B0000000-0000-0000-0000-000000000001", name: peers[0], connection: UUID(), features: Set(SharingFeature.supported), appVersion: AppVersion.current)
            mouse.setPeer(featurePeer!.device, supportsKeyboard: true, supportsGestures: true)
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
                try KeyStore.save(code); self.mouse.stop(); self.code = code; self.sync.resetSession()
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
            transport.onMetrics = { [weak self] peer, health in
                guard let self, self.featurePeer?.device == peer else { return }
                self.inputHealth = health; self.updateHealthUI()
            }
            transport.onFeature = { [weak self] peer, packet in
                guard let self, peer == self.featurePeer?.device else { return }
                if let file = packet.file {
                    if self.enabled { self.files.receive(file, from: peer) }
                    else if file.kind == .offer { self.transport?.sendFeature(FeaturePacket(file: FilePacket(kind: .cancel, id: file.id)), to: peer) }
                }
                if let mouse = packet.mouse { self.mouse.receive(mouse, from: peer) }
                if let keyboard = packet.keyboard { self.mouse.receiveKeyboard(keyboard, from: peer) }
                if let gesture = packet.gesture { self.mouse.receiveGesture(gesture, from: peer) }
            }
            transport.onClip = { [weak self] clip in self?.sync.receive(clip) }
            transport.onStatus = { [weak self] note in
                guard let self, self.verificationAlert == nil, self.pairing?.busy != true else { return }
                self.networkNote = note; self.refresh()
            }
            transport.start(); refresh()
        } catch { alert(error.localizedDescription) }
    }
    private func refresh() {
        guard !terminating else { return }
        let busy = pairing?.busy ?? false
        cancelButton?.isHidden = !busy; addressButton?.isEnabled = !busy
        pauseButton?.title = enabled ? "일시 정지" : "공유 재개"
        sendButton?.isEnabled = enabled && !peers.isEmpty
        menuSend?.isEnabled = enabled && !peers.isEmpty
        closeHint.stringValue = ["창을 닫을 때 실행 여부를 물어봐요.", "창을 닫아도 공유돼요. 완전히 끄려면 ‘NearClip 종료’를 누르세요.", "창을 닫으면 클립보드 공유도 함께 종료돼요."][closeBehavior.rawValue]
        let text: String
        if busy { text = "양쪽 숫자를 확인하세요" }
        else if !enabled { text = "공유가 일시 정지됐어요" }
        else if !peers.isEmpty { text = "연결됨" }
        else if access.hasTrustedPeer { text = "Mac을 기다리고 있어요" }
        else { text = "옆 Mac과 연결하세요" }
        statusLabel.stringValue = text
        statusLabel.textColor = .labelColor
        statusIcon?.image = NSImage(systemSymbolName: busy ? "number.circle" : (!enabled ? "pause.circle" : (peers.isEmpty ? "circle.dotted" : "checkmark.circle.fill")), accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        statusIcon?.contentTintColor = !peers.isEmpty && enabled ? .systemTeal : .secondaryLabelColor
        if !enabled { activityLabel.stringValue = "보내기와 받기를 멈췄어요. 재개한 뒤 복사한 내용부터 공유해요." }
        else if busy { activityLabel.stringValue = "연결을 확인하면 복사한 내용이 공유돼요." }
        else if !peers.isEmpty { activityLabel.stringValue = lastActivity }
        else { activityLabel.stringValue = "텍스트와 이미지 · 연결 후 자동 공유" }
        connectionHint.isHidden = !peers.isEmpty && !busy
        connectionHint.stringValue = networkNote ?? (busy ? "양쪽의 6자리 숫자를 확인하세요." : "같은 네트워크에서 상대 Mac의 NearClip을 켜주세요.")
        sharingActions?.isHidden = !access.hasTrustedPeer && peers.isEmpty
        sharingContent?.isHidden = settingsExpanded || (!access.hasTrustedPeer && peers.isEmpty)
        statusSummary?.isHidden = settingsExpanded
        trustLabel.isHidden = settingsExpanded
        settingsButton?.title = settingsExpanded ? "완료" : "설정"
        settingsButton?.image = NSImage(systemSymbolName: settingsExpanded ? "checkmark" : "gearshape", accessibilityDescription: nil)
        pairingHint.stringValue = access.hasTrustedPeer ? "양쪽 숫자를 확인하면 저장된 연결을 새 Mac으로 교체해요." : "상대 Mac의 ‘연결’을 누른 뒤, 양쪽의 6자리 숫자를 확인하세요."
        trustLabel.stringValue = access.isOpen && access.hasTrustedPeer ? "새 연결 허용 중 · 2분 후 닫힘 · 양쪽 숫자 확인 필수" : access.isOpen ? "새 Mac 연결 허용 중 · 양쪽 숫자 확인 필수" : "암호화된 직접 연결 · 클립보드 기록을 저장하지 않아요"
        discoveryView?.isHidden = settingsExpanded || !access.isOpen
        trustedView?.isHidden = settingsExpanded || access.isOpen
        advancedView?.isHidden = !advanced
        advancedButton?.title = advanced ? "연결 도움말 접기 ▴" : "Mac이 보이지 않나요? ▾"
        cancelButton?.isHidden = !access.hasTrustedPeer && !busy
        cancelButton?.title = busy ? "연결 취소" : "찾기 취소"
        copyAddressButton?.isEnabled = hasLocalAddress && access.isOpen
        peerLabel.stringValue = peers.first ?? pairedName ?? "저장된 Mac"
        peerDetail.stringValue = peers.isEmpty ? "오프라인 · 자동 재연결" : "저장된 Mac · 자동 재연결"
        for view in deviceList?.arrangedSubviews ?? [] {
            (view as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSButton }.forEach { $0.isEnabled = !busy }
        }
        updateSharingUI()
        updateWindowSize()
        menuStatus?.title = statusLabel.stringValue
        menuToggle?.title = enabled ? "공유 일시 정지" : "공유 다시 시작"
        toggle?.state = enabled ? .on : .off
        statusItem?.button?.toolTip = "NearClip · " + statusLabel.stringValue
        statusItem?.button?.setAccessibilityLabel("NearClip · " + statusLabel.stringValue)
    }
    @objc private func showWindow() {
        if headlessDiagnostics {
            NSApp.setActivationPolicy(.accessory)
            window?.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window?.orderFront(nil)
        } else {
            NSApp.setActivationPolicy(.regular); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        }
    }
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
        guard let bodyContent, let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        let naturalHeight = ceil(bodyContent.fittingSize.height)
        let fixedHeight = mainStack.fittingSize.height - bodyHeight.constant + 44
        let available = min(820, (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 850)
        bodyHeight.constant = min(naturalHeight, settingsExpanded ? 520 : .greatestFiniteMagnitude, max(180, available - fixedHeight - 42))
        window.contentView?.layoutSubtreeIfNeeded()
        let contentHeight = ceil(mainStack.fittingSize.height + 44)
        if abs((window.contentView?.bounds.height ?? 0) - contentHeight) > 1 {
            var frame = window.frame
            let newHeight = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 560, height: contentHeight)).height
            frame.origin.y += frame.height - newHeight; frame.size.height = newHeight
            if !headlessDiagnostics, let screen = window.screen ?? NSScreen.main { frame.origin.y = max(screen.visibleFrame.minY, min(frame.origin.y, screen.visibleFrame.maxY - newHeight)) }
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
        settingsExpanded = false; refresh(); refresh()
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
            let incoming = try PairCode.create(); try KeyStore.save(incoming); mouse.stop(); code = incoming
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
    @objc private func retry() {
        if let transport { transport.reconnectNow() } else { restartTransport() }
        if access.isOpen { pairing?.stop(); hasLocalAddress = false; pairing?.start() }
        refresh()
    }
    @objc private func willSleep() { mouse?.suspend(.sleep); files.cancel(); sync?.stop(); transport?.stop(); pairing?.stop(); sync?.connected = false }
    @objc private func didWake() { sync?.baseline(); sync?.start(); restartTransport(); mouse?.resume(.sleep); if access.isOpen { pairing?.start() } }
    @objc private func displaySlept() { mouse?.suspend(.displaySleep) }
    @objc private func displayWoke() { mouse?.resume(.displaySleep) }
    @objc private func sessionDeactivated() { mouse?.suspend(.inactiveSession) }
    @objc private func sessionActivated() { mouse?.resume(.inactiveSession) }
    @objc private func screenLocked() { mouse?.suspend(.screenLock) }
    @objc private func screenUnlocked() { mouse?.resume(.screenLock) }
    @objc private func displaysChanged() { mouse?.endSession(reason: .layoutChanged) }
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
        require(edgeIndicator.isNonInteractive, "edge indicator cannot take keyboard focus or intercept clicks")
        require(NSApp.mainMenu?.items.first?.submenu?.items.contains(where: { $0.keyEquivalent == "q" }) == true, "Command-Q is installed in app menu")
        toggleSharing(); require(!enabled && statusLabel.stringValue.contains("일시 정지"), "pause updates visible state")
        toggleSharing(); require(enabled, "resume updates sharing state")
        require(mouseDetails.isHidden, "mouse details start collapsed on the main screen")
        showSharing(); require(!mouseDetails.isHidden && fileButton.superview != nil, "file and mouse controls are reachable without tabs")
        toggleMouseDetails(); require(mouseDetails.isHidden, "mouse arrangement can collapse independently")
        toggleMouseDetails()
        require(!mouse.enabled, "mouse capture starts disabled")
        try? mouse.setEnabled(true)
        toggleMouseDetails(); require(mouse.enabled && mouseDetails.isHidden, "collapsing setup does not revoke enabled mouse sharing")
        toggleMouseDetails(); toggleSharing()
        require(!mouse.enabled && !enabled, "global pause revokes mouse capture")
        toggleSharing()
        // Exercise arrangement gestures through AppKit events without posting
        // system input. A synthetic peer verifies the actual layout callbacks.
        let other = MouseSharing(local: "arrangement-peer", native: false)
        other.setPeer(device)
        let originalSend = mouse.send
        mouse.send = { [weak other] _, packet, reply in other?.receive(packet, from: self.device); reply(true) }
        updateFeaturePeer([ConnectedPeer(device: "arrangement-peer", name: "Test Mac", connection: UUID(), features: Set(SharingFeature.supported))])
        try? mouse.setEnabled(true)
        var recoveryPeer = featurePeer!
        recoveryPeer.appVersion = AppVersion.current; recoveryPeer.inputReady = false
        updateFeaturePeer([recoveryPeer])
        require(!mouse.enabled && mouse.sharingRequested && mouseToggle.state == .on && mouseToggle.isEnabled,
                "input outage retains consent and allows explicit stop while clipboard peer remains")
        require(menuMouseToggle.isEnabled && menuMouseToggle.state == .on, "menu bar can revoke input consent during channel recovery")
        require(inputStatusLabel.stringValue == "연결 복구 중", "main window identifies input recovery separately from clipboard connectivity")
        require(fileButton.isEnabled && peerVersionLabel.stringValue.contains("양쪽 버전 같음"), "input outage preserves file controls and reports matched versions")
        setMouseSharing(false)
        require(inputStatusLabel.stringValue == "꺼짐", "main window shows the explicit off choice during a transport outage")
        require(!mouse.sharingRequested && mouseToggle.state == .off && mouseToggle.isEnabled && menuMouseToggle.isEnabled,
                "turning sharing off during recovery keeps both enable controls available")
        toggleMouseFromMenu()
        require(mouse.sharingRequested && !mouse.enabled && mouse.peer == nil && mouseToggle.state == .on,
                "menu enable during recovery records consent without capturing input")
        require(mouseHint.stringValue.contains("복구되면"), "pending input choice is distinguished from active sharing")
        setMouseSharing(false)
        recoveryPeer.inputReady = true; recoveryPeer.inputSession = UUID()
        updateFeaturePeer([recoveryPeer])
        require(!mouse.enabled && !mouse.sharingRequested, "revoked pending choice stays off when input reconnects")
        recoveryPeer.inputReady = false
        updateFeaturePeer([recoveryPeer])
        mouseToggle.state = .on; toggleMouse()
        require(mouse.sharingRequested && !mouse.enabled, "main switch also accepts enable during recovery")
        recoveryPeer.inputReady = true; recoveryPeer.inputSession = UUID()
        updateFeaturePeer([recoveryPeer])
        require(mouse.enabled && !mouse.remoteEnabled && mouse.mode == .local, "input reconnect restores local readiness with fresh remote consent")
        require(inputStatusLabel.stringValue == "상대 켜기 대기", "connected input is not presented as usable before remote consent")
        require(updateDownloadButton.isHidden && updateButton.isEnabled, "update controls never offer an unchecked download")
        displaySlept(); screenLocked(); sessionDeactivated(); willSleep()
        require(!mouse.enabled && mouseToggle.state == .on, "sleep stops capture while the sharing checkbox retains the choice")
        didWake(); displayWoke(); sessionActivated()
        require(!mouse.enabled, "wake callbacks cannot resume before screen unlock")
        screenUnlocked()
        require(mouse.enabled, "unlock callback restores input readiness for the same peer")
        displaySlept(); stopInput(); displayWoke()
        require(!mouse.enabled && mouseToggle.state == .off, "explicit stop while suspended stays off after wake")
        require(menuMouseToggle.isEnabled && menuMouseToggle.state == .off, "menu bar offers input sharing for an eligible connected peer")
        window.orderOut(nil)
        NSApp.sendAction(menuMouseToggle.action!, to: menuMouseToggle.target, from: menuMouseToggle)
        require(mouse.enabled && menuMouseToggle.state == .on && !window.isVisible, "menu bar enables sharing without opening the main window")
        let previousSide = mouse.side
        NSApp.sendAction(menuSwapScreens.action!, to: menuSwapScreens.target, from: menuSwapScreens)
        require(mouse.side == previousSide.opposite && mouse.layout == other.layout && !window.isVisible,
                "menu bar swaps and synchronizes screen order without opening the window")
        NSApp.sendAction(menuMouseToggle.action!, to: menuMouseToggle.target, from: menuMouseToggle)
        require(!mouse.enabled && menuMouseToggle.state == .off, "menu bar toggle stops input capture")
        showWindow()
        mouse.setSide(.right)
        let left = CGPoint(x: arrangement.bounds.midX - 110, y: 60)
        let right = CGPoint(x: arrangement.bounds.midX + 110, y: 60)
        func gesture(_ type: NSEvent.EventType, _ point: CGPoint) {
            let location = arrangement.convert(point, to: nil)
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
            switch type {
            case .leftMouseDown: arrangement.mouseDown(with: event)
            case .leftMouseDragged: arrangement.mouseDragged(with: event)
            default: arrangement.mouseUp(with: event)
            }
        }
        let beforeDrag = mouse.layout
        gesture(.leftMouseDown, right); gesture(.leftMouseDragged, left)
        require(mouse.layout == beforeDrag && other.layout == beforeDrag, "drag preview does not publish a layout")
        gesture(.leftMouseUp, left)
        require(mouse.side == .left && other.side == .right && mouse.layout == other.layout, "dropping peer card updates both Mac layouts")
        let afterDrop = mouse.layout
        gesture(.leftMouseDown, right); gesture(.leftMouseUp, right)
        require(mouse.layout == afterDrop, "clicking a monitor does not rearrange it")
        gesture(.leftMouseDown, right); gesture(.leftMouseDragged, left)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        arrangement.keyDown(with: escape); gesture(.leftMouseUp, left)
        require(mouse.layout == afterDrop, "Escape cancels a pending arrangement")
        gesture(.leftMouseDown, right); gesture(.leftMouseDragged, left); gesture(.leftMouseUp, CGPoint(x: -20, y: 60))
        require(mouse.layout == afterDrop, "dropping outside the canvas keeps the layout")
        gesture(.leftMouseDown, right); gesture(.leftMouseDragged, left); gesture(.leftMouseUp, left)
        require(mouse.side == .right && mouse.layout == other.layout, "dragging this Mac also updates both layouts")
        swapScreens.performClick(nil)
        require(mouse.side == .left && mouse.layout == other.layout, "accessible swap button updates both Mac layouts")
        gesture(.leftMouseDown, right); gesture(.leftMouseDragged, left)
        updateFeaturePeer([])
        gesture(.leftMouseUp, left)
        require(mouse.layout == nil && !swapScreens.isEnabled, "disconnect cancels arrangement editing")
        require(!menuSwapScreens.isEnabled && !menuMouseToggle.isEnabled && menuScreenOrder.title.contains("연결 대기"),
                "disconnected menu disables new sharing and layout changes")
        mouse.send = originalSend
        require(gestureHint.stringValue.contains("연결하면"), "disconnected gesture guidance explains capability check")
        let fixturePeer = ConnectedPeer(device: "gesture-peer", name: "Gesture fixture", connection: UUID(), features: [SharingFeature.mouse, SharingFeature.keyboard])
        updateFeaturePeer([fixturePeer])
        require(gestureHint.stringValue.contains("기능 확인"), "legacy peer explains why gestures stay local")
        let capablePeer = ConnectedPeer(device: "gesture-peer", name: "Gesture fixture", connection: UUID(), features: Set(SharingFeature.supported))
        updateFeaturePeer([capablePeer])
        require(gestureHint.stringValue.contains("조작하는 Mac"), "gesture guidance identifies which Mac supplies finger-count settings")
        try? mouse.setEnabled(true)
        mouse.secureInputEnabled = { true }; mouse.tick(); updateSharingUI()
        require(mouseHint.stringValue.contains("이 Mac의 보안 입력") && mouseToggle.state == .on,
                "secure-input pause is visible without clearing the sharing choice")
        mouse.secureInputEnabled = { false }; mouse.tick(); updateSharingUI()
        mouse.receive(MousePacket(kind: .availability, enabled: true, secureInputActive: true), from: "gesture-peer")
        updateSharingUI()
        require(mouseHint.stringValue.contains("상대 Mac의 보안 입력"), "remote secure-input pause identifies the blocked Mac")
        mouse.receive(MousePacket(kind: .availability, enabled: true, secureInputActive: false), from: "gesture-peer")
        updateSharingUI()
        require(!mouseHint.stringValue.contains("보안 입력"), "cleared secure input restores normal sharing guidance")
        updateFeaturePeer([])
        showSettings(); require(!settingsContent.isHidden && sharingContent.isHidden && statusSummary.isHidden, "settings focus on preferences without duplicating sharing controls")
        require(window.frame.height < 760, "settings remain a compact scrollable window")
        toggleSettings(); require(settingsContent.isHidden, "settings can collapse without leaving sharing")
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
        showWindow(); require(window.isVisible && NSApp.activationPolicy() == (headlessDiagnostics ? .accessory : .regular), "menu-bar app can reopen its window")
        closeBehavior = .quit
        print("PASS: closing with quit preference requests app termination"); fflush(stdout)
        _ = windowShouldClose(window)
    }
    @objc private func closeWindow() { window.performClose(nil) }
    private func scrollToTop() { bodyScroll.contentView.scroll(to: .zero); bodyScroll.reflectScrolledClipView(bodyScroll.contentView) }
    @objc private func toggleSettings() { settingsExpanded.toggle(); refresh(); scrollToTop() }
    @objc private func showSettings() { showWindow(); settingsExpanded = true; refresh(); scrollToTop() }
    @objc private func showSharing() { showWindow(); settingsExpanded = false; mouseDetailsExpanded = true; recheckPermissions(); mouseToggle.scrollToVisible(mouseToggle.bounds) }
    @objc private func toggleMouseDetails() { mouseDetailsExpanded.toggle(); recheckPermissions() }
    @objc private func recheckPermissions() {
        permissions = preview ? MousePermissions(accessibility: true, posting: true, monitoring: true) : MouseSharing.permissions
        if permissions.granted { mouseSetupError = nil; mouse.retryRequestedSharing() }
        refresh()
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard window != nil else { return }
        recheckPermissions()
    }
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
        dialog.informativeText += "\n\n연결 화면 아래에서 파일을 보내거나 ‘화면 배치 · 권한’을 펼쳐 두 Mac의 좌우 순서를 정할 수 있어요. 배치는 양쪽에 반영돼요. 마우스·키보드 공유는 양쪽에서 직접 켜야 해요. 화면 가장자리로 밀어 이동하고 ⌃⌥Esc로 즉시 끄세요. 두 Mac 모두 0.4.3 이상이면 키보드도 커서와 함께 이동해요. 파일은 상대가 저장 위치를 선택해야 전송돼요."
        dialog.addButton(withTitle: "확인"); dialog.runModal()
    }
    private func alert(_ message: String) {
        let dialog = NSAlert(); dialog.messageText = "NearClip"; dialog.informativeText = message
        dialog.addButton(withTitle: "확인"); NSApp.activate(ignoringOtherApps: true); dialog.runModal()
    }
    private func configureSharing() {
        permissions = preview ? MousePermissions(accessibility: true, posting: true, monitoring: true) : MouseSharing.permissions
        mouse = MouseSharing(local: device, native: !preview)
        mouse.onConsentChange = { [weak self] peer in
            guard let self, !self.preview, !self.terminating else { return }
            let consent = peer.flatMap { peer in (try? PairCode.group(self.code)).map { InputConsent(peer: peer, group: $0) } }
            if let consent, let data = try? JSONEncoder().encode(consent) {
                UserDefaults.standard.set(data, forKey: "inputConsent")
            } else { UserDefaults.standard.removeObject(forKey: "inputConsent") }
        }
        if !preview {
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            if session?[kCGSessionOnConsoleKey] as? Bool != true || session?[kCGSessionLoginDoneKey] as? Bool != true {
                mouse.suspend(.inactiveSession)
            }
            if session?["CGSSessionScreenIsLocked"] as? Bool == true { mouse.suspend(.screenLock) }
            if enabled, let data = UserDefaults.standard.data(forKey: "inputConsent"),
               let consent = try? JSONDecoder().decode(InputConsent.self, from: data), let peer = consent.peer(for: code) {
                mouse.restoreConsent(for: peer)
            }
        }
        mouse.send = { [weak self] peer, packet, reply in
            guard let self, let transport = self.transport else { reply(false); return }
            transport.sendFeature(FeaturePacket(mouse: packet), to: peer, completion: reply)
        }
        mouse.sendGesture = { [weak self] peer, packet, reply in
            guard let transport = self?.transport else { reply(false); return }
            transport.sendFeature(FeaturePacket(gesture: packet), to: peer, completion: reply)
        }
        mouse.sendKeyboard = { [weak self] peer, packet, reply in
            guard let transport = self?.transport else { reply(false); return }
            transport.sendFeature(FeaturePacket(keyboard: packet), to: peer, completion: reply)
        }
        mouse.onEdgeProgress = { [weak self] point, side, progress in
            guard let self, !self.headlessDiagnostics else { return }
            if let point { self.edgeIndicator.show(at: point, side: side, progress: progress, connected: false) }
            else { self.edgeIndicator.hide() }
        }
        mouse.onChange = { [weak self] in
            guard let self else { return }
            if !self.headlessDiagnostics {
                if self.mouse.active {
                    self.edgeIndicator.show(at: self.mouse.indicatorPoint, side: self.mouse.side, progress: 1,
                                            connected: self.mouse.mode != .requesting)
                } else { self.edgeIndicator.hide() }
            }
            if self.window != nil { self.refresh() }
        }
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
        let previous = featurePeer
        let parentChanged = previous?.connection != next?.connection
        let inputChanged = parentChanged || previous?.inputReady != next?.inputReady || previous?.inputSession != next?.inputSession
        featurePeer = next
        if parentChanged { files.disconnected() }
        if inputChanged {
            inputHealth = nil
            // Clear remote consent and held input before an independent socket
            // reconnects. Keep the same-peer local opt-in, never the old token.
            mouse.setPeer(nil)
            let saved = UserDefaults.standard.data(forKey: "screenLayout").flatMap { try? JSONDecoder().decode(ScreenLayout.self, from: $0) }
            if next?.inputReady == true {
                mouse.setPeer(next?.features.contains(SharingFeature.mouse) == true ? next?.device : nil, savedLayout: saved,
                              supportsKeyboard: next?.features.contains(SharingFeature.keyboard) == true,
                              supportsGestures: next?.features.contains(SharingFeature.gestures) == true)
            }
        }
        updateSharingUI()
    }
    private func updateHealthUI() {
        guard let peer = featurePeer else { healthLabel.stringValue = "상대 Mac에 연결하면 입력 지연을 측정해요."; return }
        if !peer.inputReady {
            healthLabel.stringValue = "입력 연결 복구 중 · 클립보드와 파일 연결은 유지돼요."
            if let failure = peer.inputFailure { healthLabel.stringValue += "\n" + failure }
        }
        else if let inputHealth { healthLabel.stringValue = "입력 전용 연결 · " + inputHealth.label }
        else if peer.features.contains(SharingFeature.inputMetrics) { healthLabel.stringValue = "입력 전용 연결 · 왕복 지연 측정 중…" }
        else { healthLabel.stringValue = "상대도 최신 빌드로 업데이트하면 왕복 지연을 확인할 수 있어요." }
        if let timing = mouse.motionTimingLabel { healthLabel.stringValue += "\n" + timing }
        if !mouse.active, let message = mouse.lastEndMessage { healthLabel.stringValue += "\n" + message }
        if mouse.active { healthLabel.stringValue += "\n현재 제어: NearClip · " + (mouse.mode == .receiving ? "상대 Mac에서 이 Mac 제어 중" : "이 Mac에서 상대 Mac 제어 중") }
        else { healthLabel.stringValue += "\nNearClip 원격 제어 대기 · Apple 연결 여부는 디스플레이 설정에서 확인하세요." }
    }
    private func configureUpdates() {
        guard !preview else { return }
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.automaticUpdateCheck() }
        updateTimer = timer; RunLoop.main.add(timer, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.automaticUpdateCheck() }
    }
    private func automaticUpdateCheck() {
        guard !preview, !terminating, UserDefaults.standard.object(forKey: "automaticUpdateChecks") as? Bool ?? true,
              Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: "lastUpdateAttempt") >= 86400 else { return }
        performUpdateCheck()
    }
    @objc private func toggleAutomaticUpdates() {
        guard !preview else { return }
        UserDefaults.standard.set(autoUpdateToggle.state == .on, forKey: "automaticUpdateChecks")
        if autoUpdateToggle.state == .on { automaticUpdateCheck() }
    }
    @objc private func checkUpdates() { openUpdater() }
    private func openUpdater() {
        guard !preview, !terminating else { return }
        guard !files.busy else { alert("파일 전송을 마치거나 취소한 뒤 업데이트해 주세요."); return }
        updateButton.isEnabled = false; updateDownloadButton.isEnabled = false
        updateLabel.stringValue = "업데이트 창을 열고 있어요…"
        UpdateInstaller.open { [weak self] error in
            guard let self else { return }
            self.updateButton.isEnabled = true; self.updateDownloadButton.isEnabled = true
            self.updateLabel.stringValue = error?.localizedDescription ?? "업데이트 창에서 설치를 선택하면 연결을 종료하고 앱을 다시 열어요."
            if let error { self.alert(error.localizedDescription) }
        }
    }
    private func performUpdateCheck() {
        guard !preview, !updateChecker.checking else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateAttempt")
        updateButton.isEnabled = false; updateLabel.stringValue = "공개 배포를 확인하고 있어요…"
        updateChecker.check { [weak self] result in
            guard let self, !self.terminating else { return }
            self.updateButton.isEnabled = true
            switch result {
            case .success(let release):
                self.updateDownload = nil
                if let release, let latest = release.version {
                    if AppVersion.current < latest {
                        self.updateDownload = release.downloadURL
                        self.updateLabel.stringValue = "새 버전 \(latest.label)이 있어요. 두 Mac을 함께 업데이트하세요."
                    } else if latest < AppVersion.current { self.updateLabel.stringValue = "현재는 공개 배포보다 최신 테스트 빌드예요. 내려받을 업데이트가 없어요." }
                    else { self.updateLabel.stringValue = "현재 공개된 최신 버전이에요." }
                } else { self.updateLabel.stringValue = "아직 다운로드할 공개 배포가 없어요." }
                self.updateDownloadButton.isHidden = self.updateDownload == nil
                self.updateMenu?.title = self.updateDownload == nil ? "업데이트 확인…" : "새 버전 있음 · 업데이트…"
            case .failure:
                self.updateLabel.stringValue = "업데이트 확인에 실패했어요. 네트워크를 확인하고 다시 눌러주세요."
            }
            self.updateWindowSize()
        }
    }
    @objc private func downloadUpdate() {
        openUpdater()
    }
    @objc private func openReleases() { NSWorkspace.shared.open(UpdateChecker.releasesURL) }
    private func updateSharingUI() {
        guard mouseToggle != nil else { return }
        mouseDetails?.isHidden = !mouseDetailsExpanded
        settingsContent?.isHidden = !settingsExpanded
        mouseDisclosure?.title = mouseDetailsExpanded ? "화면 배치 ▾" : "화면 배치 ▸"
        permissionLabel.stringValue = permissions.granted ? "✓ 손쉬운 사용 · 입력 모니터링 허용됨" : permissions.statusText
        permissionActions?.isHidden = permissions.granted
        peerVersionLabel.isHidden = featurePeer == nil
        peerVersionLabel.stringValue = AppVersion.current.peerNotice(featurePeer?.appVersion)
        peerVersionLabel.textColor = featurePeer?.appVersion == AppVersion.current ? .secondaryLabelColor : .systemOrange
        updateHealthUI()
        let supportsFiles = featurePeer?.features.contains(SharingFeature.files) == true
        let supportsMouse = featurePeer?.features.contains(SharingFeature.mouse) == true
        if !DockSwipeAdapter.available { gestureHint.stringValue = "제스처 베타 · 현재 macOS 버전은 지원하지 않아요. 마우스·키보드는 계속 사용할 수 있어요." }
        else if !supportsMouse { gestureHint.stringValue = "제스처 베타 · 연결하면 상대 앱의 지원 여부를 확인해요." }
        else if !mouse.gesturesSupported {
            let platform = featurePeer?.osMajor.map { "상대 macOS \($0) · " } ?? ""
            gestureHint.stringValue = "제스처 연결 안 됨 · " + platform + "상대 앱의 기능 확인이 필요해요. 운영체제 호환성 확인에 실패하면 꺼져요."
        }
        else { gestureHint.stringValue = "제스처 베타 · 3·4손가락으로 데스크탑·Mission Control 전환. 손가락 수는 조작하는 Mac의 설정을 따라요." }
        fileButton.isEnabled = enabled && supportsFiles && !files.busy
        fileActions?.isHidden = fileCancel.isHidden && revealButton.isHidden
        swapScreens.isEnabled = supportsMouse && !mouse.active
        mouseToggle.isEnabled = mouse.sharingRequested || (enabled && supportsMouse)
        inputTitle.stringValue = featurePeer?.features.contains(SharingFeature.keyboard) == true || !supportsMouse ? "마우스·키보드" : "마우스"
        mouseToggle.state = mouse.sharingRequested ? .on : .off
        let inputStatus = InputSharingStatus.resolve(requested: mouse.sharingRequested, connected: supportsMouse,
            inputReady: featurePeer?.inputReady == true, permissions: permissions.granted,
            captureEnabled: mouse.enabled, peerEnabled: mouse.remoteEnabled, paused: mouse.inputPauseMessage != nil)
        inputStatusLabel.stringValue = inputStatus.rawValue
        inputStatusLabel.textColor = inputStatus == .ready ? .systemGreen : inputStatus == .off ? .secondaryLabelColor : .systemOrange
        arrangement.update(peerID: supportsMouse ? featurePeer?.connection.uuidString : nil,
                           localName: preview ? "My MacBook" : deviceName,
                           peerName: featurePeer?.name ?? "상대 Mac", side: mouse.side,
                           editable: supportsMouse && !mouse.active)
        arrangementHint.stringValue = mouse.active ? "마우스 제어를 끝낸 뒤 배치를 바꿀 수 있어요. ⌃⌥Esc로 공유를 끄세요." : "화면을 드래그해 실제 Mac의 좌우 순서에 맞춰주세요. 양쪽에 자동 반영돼요."
        if featurePeer != nil && featurePeer?.inputReady == false {
            mouseHint.stringValue = mouse.sharingRequested
                ? "켜기 선택을 저장했어요. 입력 연결이 복구되면 시작해요. 클립보드와 파일 공유는 계속돼요."
                : "마우스·키보드 공유가 꺼져 있어요. 지금 켜두면 입력 연결이 복구된 뒤 시작해요."
        }
        else if mouse.sharingRequested && !mouse.enabled {
            mouseHint.stringValue = permissions.granted ? "선택을 기억했어요 · 같은 Mac에 연결되면 다시 켜져요." : "권한 확인 필요 · 화면 배치를 펼쳐 허용 상태를 확인하세요."
        }
        else if !supportsMouse { mouseHint.stringValue = "연결하면 커서와 키보드를 함께 사용할 수 있어요." }
        else if !mouse.enabled { mouseHint.stringValue = mouseSetupError ?? (mouse.keyboardSupported ? "양쪽에서 켠 뒤 화면 가장자리로 이동하세요." : "상대 Mac을 업데이트하면 키보드도 공유해요.") }
        else if let pause = mouse.inputPauseMessage { mouseHint.stringValue = pause }
        else if !mouse.remoteEnabled { mouseHint.stringValue = "이 Mac은 준비됐어요. 상대 Mac에서도 마우스 공유를 켜주세요." }
        else {
            mouseHint.stringValue = mouse.gesturesSupported ? "NearClip 준비 완료 · 화면 가장자리로 이동 · 3·4손가락 쓸어넘기기 베타" : "NearClip 준비 완료 · 화면 가장자리로 밀어 이동하세요."
        }
        menuMouseToggle?.state = mouse.sharingRequested ? .on : .off
        menuMouseToggle?.isEnabled = mouse.sharingRequested || mouseToggle.isEnabled
        menuMouseToggle?.title = inputTitle.stringValue + " 공유"
        menuSwapScreens?.isEnabled = swapScreens.isEnabled
        menuScreenOrder?.title = supportsMouse ? (mouse.side == .left ? "상대 Mac ← 이 Mac" : "이 Mac → 상대 Mac") : "화면 배치 · 연결 대기"
        menuScreenOrder?.isEnabled = false
        menuMouseStop?.isEnabled = mouse.sharingRequested
    }
    @objc private func swapScreenOrder() {
        guard featurePeer?.features.contains(SharingFeature.mouse) == true, !mouse.active else { return }
        mouse.setSide(mouse.side.opposite)
    }
    @objc private func toggleMouseFromMenu() {
        guard mouse.sharingRequested || mouseToggle.isEnabled else { return }
        setMouseSharing(!mouse.sharingRequested)
        if mouseSetupError != nil { showWindow() }
    }
    @objc private func toggleMouse() { setMouseSharing(mouseToggle.state == .on) }
    private func setMouseSharing(_ requested: Bool) {
        mouseSetupError = nil
        if requested, enabled, let peer = featurePeer,
           peer.features.contains(SharingFeature.mouse), !peer.inputReady {
            mouse.requestSharingWhenConnected(to: peer.device)
            refresh()
            return
        }
        do { try mouse.setEnabled(requested) }
        catch {
            mouseDetailsExpanded = true
            mouseToggle.state = .off; mouseSetupError = error.localizedDescription
            if !preview { MouseSharing.requestPermissions() }
        }
        permissions = preview ? MousePermissions(accessibility: true, posting: true, monitoring: true) : MouseSharing.permissions
        refresh()
    }
    @objc private func universalControlHelp() {
        let dialog = NSAlert(); dialog.messageText = "Apple 유니버설 컨트롤과 함께 쓰고 있나요?"
        dialog.informativeText = "유니버설 컨트롤은 같은 Apple 계정의 Mac·iPad 사이에서 동작해요. 두 기능을 동시에 사용 중이라면 테스트할 동안 시스템 설정 → 디스플레이 → 고급에서 ‘포인터 및 키보드가 근처의 Mac 또는 iPad 간에 이동하도록 허용’을 꺼보세요.\n\nNearClip은 이 설정을 자동으로 바꾸지 않아요. 지금 권한 오류가 난다면 손쉬운 사용·입력 모니터링을 먼저 확인하세요."
        dialog.addButton(withTitle: "디스플레이 설정 열기"); dialog.addButton(withTitle: "닫기")
        dialog.beginSheetModal(for: window) { result in
            if result == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.displays")!) }
        }
    }
    @objc private func toggleAppleRelay() {
        preventAppleRelay = relayToggle.state == .on
        sync?.preventAppleRelay = preventAppleRelay
        if !preview { UserDefaults.standard.set(preventAppleRelay, forKey: "preventAppleRelay") }
    }
    @objc private func appleClipboardHelp() {
        let dialog = NSAlert(); dialog.messageText = "Apple 기기 간 클립보드 공유"
        dialog.informativeText = "위 옵션은 NearClip으로 새로 받은 내용이 Apple 유니버설 클립보드로 다시 전달되지 않도록 지정해요. 다른 앱의 복사, 이미 전달된 내용, 수동으로 다시 복사한 내용은 막지 않아요.\n\n이 Mac의 Apple 클립보드 공유 전체를 끄려면 시스템 설정 → 일반 → AirDrop 및 Handoff(또는 연속성)에서 ‘이 Mac과 iCloud 기기 간에 Handoff 허용’을 끄세요. 앱 이어서 작업하기 등 다른 Handoff 기능에도 영향을 줘요. NearClip은 이 시스템 설정을 자동으로 바꾸지 않아요."
        dialog.addButton(withTitle: "일반 설정 열기"); dialog.addButton(withTitle: "닫기")
        dialog.beginSheetModal(for: window) { result in
            if result == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.General-Settings.extension")!) }
        }
    }
    @objc private func keychainHelp() {
        alert("NearClip은 저장된 기기 연결 키를 키체인에서 읽어요. 시작할 때 접근 확인이 뜨면 Mac 로그인 암호를 입력하고 ‘항상 허용(Always Allow)’을 선택할 수 있어요. ‘허용(Allow)’은 이번 접근만 승인해요.\n\n연결 키는 고정 서명의 NearClipKeyStore 구성요소가 읽어요. 이 구성요소를 처음 사용할 때 한 번 승인하면 일반 앱 업데이트에서는 그대로 사용해요. 구성요소나 서명이 바뀌거나 키체인이 잠기면 다시 확인할 수 있어요. 앱에 로그인 암호를 저장하거나 키체인 보호를 해제하지 않아요.")
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
        if CommandLine.arguments.contains("--edge") {
            let edgePreview = ControlEdgeIndicator.previewView()
            let size = edgePreview.frame.size
            window.contentView = edgePreview; window.setContentSize(size)
        }
        if settingsExpanded { scrollToTop() }
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
