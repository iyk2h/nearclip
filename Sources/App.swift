import AppKit
import ServiceManagement

final class WindowBackground: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
}

final class DeviceList: NSStackView { override var isFlipped: Bool { true } }

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPathControlDelegate {
    private let files = FileTransfer()
    private let dragImages = FileTransfer()
    private var preparingImageID: UUID?
    private var heldDrop: AppFileDrop?
    private var preparedImage: PreparedDragImage?
    private var mouse: MouseSharing!
    private let edgeIndicator = ControlEdgeIndicator()
    private lazy var fileEdge = FileEdgePanel()
    private lazy var fileBadge = DraggedFileBadge()
    private var draggingFile: (source: DragSourceFile, connection: UUID)?
    private var showingFileEdge = false
    private var fileDestination: (id: UUID, name: String, folder: URL?, directory: ReceiveDirectory?, date: Date)?
    private var approvedDropDirectory: ReceiveDirectory?
    private var lastFileDropID: UUID?
    private var appDrop: AppFileDrop?
    private var featurePeer: ConnectedPeer?
    private let peerVersionLabel = NSTextField(wrappingLabelWithString: "")
    private let healthLabel = NSTextField(wrappingLabelWithString: ui("Input latency appears after you connect."))
    private var inputHealth: InputHealth?
    private let updateChecker = UpdateChecker()
    private var updateTimer: Timer?
    private var updateDownload: URL?
    private let updateLabel = NSTextField(wrappingLabelWithString: ui("Check for updates and install the latest beta here."))
    private var updateButton: NSButton!
    private var updateDownloadButton: NSButton!
    private var autoUpdateToggle: NSButton!
    private var updateMenu: NSMenuItem?
    private var fileButton: NSButton!
    private var fileCancel: NSButton!
    private var fileActions: NSView!
    private let retryFile = NSPathControl()
    private var revealButton: NSButton!
    private var mouseToggle: NSSwitch!
    private let inputTitle = NSTextField(labelWithString: ui("Mouse & Keyboard"))
    private let inputStatusLabel = NSTextField(labelWithString: ui("Off"))
    private var permissionActions: NSView!
    private var connectionHint = NSTextField(wrappingLabelWithString: "")
    private let arrangement = ScreenArrangementView(frame: .zero)
    private var swapScreens: NSButton!
    private let arrangementHint = NSTextField(wrappingLabelWithString: ui("Drag the screens to match your desk."))
    private let mouseHint = NSTextField(wrappingLabelWithString: ui("Turn on mouse sharing on both Macs."))
    private let gestureHint = NSTextField(wrappingLabelWithString: "")
    private static let fileHint = ui("Send a file, or drag it across the shared screen edge in Finder.")
    private let fileLabel = NSTextField(wrappingLabelWithString: AppDelegate.fileHint)
    private var progressDelay: Timer?
    private var pendingProgress: (text: String, value: Double?)?
    private var directDrop = false
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
    private var lastActivity = ui("Anything you copy after connecting is shared.")
    private var networkNote: String?
    private var enabled = true
    private let headlessDiagnostics = CommandLine.arguments.contains("--update-component-check") || CommandLine.arguments.contains("--update-check") || CommandLine.arguments.contains("--render-preview") || CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--lifecycle-smoke")
    private let preview = CommandLine.arguments.contains("--render-preview") || CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--lifecycle-smoke")
    private let statusLabel = NSTextField(labelWithString: ui("Waiting for a Mac"))
    private let activityLabel = NSTextField(wrappingLabelWithString: ui("Anything you copy after connecting is shared."))
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
    private var localAddress = NSTextField(wrappingLabelWithString: ui("Getting address…"))
    private var closePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private var loginToggle: NSButton!
    private var relayToggle: NSButton!
    private var preventAppleRelay = true
    private var closeHint = NSTextField(wrappingLabelWithString: ui("Choose what happens each time you close the window."))
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
        if CommandLine.arguments.contains("--app-drop-smoke") || CommandLine.arguments.contains("--web-drop-smoke") || CommandLine.arguments.contains("--held-drop-smoke") { AppDropSmoke.start(); return }
        if let i = CommandLine.arguments.firstIndex(of: "--app-drop-test-window"),
           i + 1 < CommandLine.arguments.count, let id = UUID(uuidString: CommandLine.arguments[i + 1]) {
            AppDropSmoke.openTarget(id); return
        }
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
            restartTransport(); startPairing(); sync.start(); files.startTimer(); dragImages.startTimer()
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
        progressDelay?.invalidate(); updateTimer?.invalidate(); updateChecker.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        heldDrop?.abort(); mouse?.stop(); dragImages.stop(); preparedImage = nil; files.stop()
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
        menuStatus = NSMenuItem(title: ui("Waiting for a connection"), action: nil, keyEquivalent: ""); menu.addItem(menuStatus)
        menu.addItem(.separator())
        item(ui("Open NearClip…"), #selector(showWindow), menu: menu)
        menuSend = item(ui("Send Current Clipboard"), #selector(sendNow), menu: menu)
        menuToggle = item(ui("Pause Sharing"), #selector(toggleSharing), menu: menu)
        menuMouseToggle = item(ui("Share Mouse & Keyboard"), #selector(toggleMouseFromMenu), menu: menu)
        menuScreenOrder = NSMenuItem(title: ui("Screen Layout · Waiting for a Mac"), action: nil, keyEquivalent: "")
        menu.addItem(menuScreenOrder)
        menuSwapScreens = item(ui("Swap Left and Right Screens"), #selector(swapScreenOrder), menu: menu)
        item(ui("Files and Screen Layout…"), #selector(showSharing), menu: menu)
        menuMouseStop = item(ui("Stop Input Sharing  ⌃⌥Esc"), #selector(stopInput), menu: menu)
        item(ui("Find Mac Again"), #selector(retry), menu: menu)
        menu.addItem(.separator())
        item(ui("Settings…"), #selector(showSettings), menu: menu, key: ",")
        updateMenu = item(ui("Check for Updates…"), #selector(checkUpdates), menu: menu)
        item(ui("Help"), #selector(help), menu: menu)
        item(ui("Quit NearClip"), #selector(quit), menu: menu, key: "q")
        menu.autoenablesItems = false
        statusItem.menu = menu
        let main = NSMenu()
        let appMenu = NSMenu(); let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)
        item(ui("About NearClip"), #selector(about), menu: appMenu)
        item(ui("Check for Updates…"), #selector(checkUpdates), menu: appMenu)
        item(ui("Settings…"), #selector(showSettings), menu: appMenu, key: ",")
        appMenu.addItem(.separator())
        item(ui("Quit NearClip"), #selector(quit), menu: appMenu, key: "q")
        let edit = NSMenu(title: ui("Edit")); let editItem = NSMenuItem(title: ui("Edit"), action: nil, keyEquivalent: ""); editItem.submenu = edit; main.addItem(editItem)
        for (title, action, key) in [(ui("Cut"), "cut:", "x"), (ui("Copy"), "copy:", "c"), (ui("Paste"), "paste:", "v"), (ui("Select All"), "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let win = NSMenu(title: ui("Window")); let winItem = NSMenuItem(title: ui("Window"), action: nil, keyEquivalent: ""); winItem.submenu = win; main.addItem(winItem)
        item(ui("Close Window"), #selector(closeWindow), menu: win, key: "w")
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
        let tagline = label(ui("Two Macs, one workspace"), size: 11, color: .secondaryLabelColor)
        settingsButton = button(ui("Settings"), action: #selector(toggleSettings))
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settingsButton.imagePosition = .imageLeading
        let heading = row([flexible(column([brand, tagline], spacing: 3)), settingsButton])
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        activityLabel.font = .systemFont(ofSize: 11); activityLabel.textColor = .secondaryLabelColor
        activityLabel.maximumNumberOfLines = 2
        statusIcon = symbol("circle.dotted", size: 16)
        pauseButton = button(ui("Pause"), action: #selector(toggleSharing))
        sendButton = button(ui("Send Now"), action: #selector(sendNow))
        sendButton.toolTip = ui("Send the text or image currently on the clipboard.")
        sharingActions = pauseButton
        connectionHint.font = .systemFont(ofSize: 11); connectionHint.textColor = .secondaryLabelColor
        connectionHint.maximumNumberOfLines = 3
        trustLabel.font = .systemFont(ofSize: 10); trustLabel.textColor = .secondaryLabelColor
        let statusCard = column([
            row([statusIcon, flexible(statusLabel), pauseButton]), connectionHint
        ], spacing: 6)
        statusSummary = statusCard

        cancelButton = button(ui("Stop Searching"), action: #selector(cancelDiscovery))
        cancelButton.controlSize = .regular
        addressButton = button(ui("Connect by Address…"), action: #selector(connectAddress))
        localAddress.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        localAddress.isSelectable = true; _ = flexible(localAddress)
        copyAddressButton = button(ui("Copy Address"), action: #selector(copyAddress))
        copyAddressButton.isEnabled = false; localAddress.setAccessibilityLabel(ui("Connection address for this Mac"))
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
        advancedButton = button(ui("Can't see your Mac?"), action: #selector(toggleAdvanced))
        advancedButton.controlSize = .small
        advancedView = column([
            label(ui("Allow Local Network access on both Macs.\nCompare the codes even when connecting by address."), size: 11, color: .secondaryLabelColor),
            row([localAddress, copyAddressButton]),
            row([addressButton, button(ui("Network Permissions"), action: #selector(networkSettings)), flexible(NSView())])
        ], spacing: 8)
        advancedView.isHidden = true
        pairingHint.font = .systemFont(ofSize: 11); pairingHint.textColor = .secondaryLabelColor
        discoveryView = column([
            row([flexible(label(ui("Nearby Macs"), size: 13, weight: .semibold)), cancelButton, button(ui("Search Again"), action: #selector(retry))]),
            scroll,
            pairingHint,
            row([advancedButton, flexible(NSView())]), advancedView
        ], spacing: 10)
        peerLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        peerLabel.lineBreakMode = .byTruncatingTail
        peerDetail.font = .systemFont(ofSize: 11); peerDetail.textColor = .secondaryLabelColor
        trustedView = panel(row([
            symbol("laptopcomputer", size: 26), flexible(column([peerLabel, peerDetail], spacing: 4)),
            button(ui("Change Mac…"), action: #selector(openDiscovery))
        ]))
        arrangement.heightAnchor.constraint(equalToConstant: 164).isActive = true
        arrangement.onCommit = { [weak self] side in
            guard let self, self.featurePeer?.features.contains(SharingFeature.mouse) == true, !self.mouse.active else { return }
            self.mouse.setSide(side)
        }
        swapScreens = button(ui("Swap Screens"), action: #selector(swapScreenOrder))
        swapScreens.controlSize = .small
        swapScreens.setAccessibilityLabel(ui("Swap the two Macs in the screen layout"))
        arrangementHint.font = .systemFont(ofSize: 11); arrangementHint.textColor = .secondaryLabelColor
        arrangementHint.maximumNumberOfLines = 2
        mouseToggle = NSSwitch(); mouseToggle.target = self; mouseToggle.action = #selector(toggleMouse)
        mouseToggle.setAccessibilityLabel(ui("Share Mouse & Keyboard"))
        mouseToggle.setContentHuggingPriority(.required, for: .horizontal)
        inputTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        inputStatusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        inputStatusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        mouseHint.font = .systemFont(ofSize: 11); mouseHint.textColor = .secondaryLabelColor
        fileButton = button(ui("Send File…"), action: #selector(sendFile))
        fileCancel = button(ui("Cancel Transfer"), action: #selector(cancelFile)); fileCancel.isHidden = true
        revealButton = button(ui("Show in Finder"), action: #selector(revealFile)); revealButton.isHidden = true
        retryFile.isEditable = false; retryFile.backgroundColor = .clear
        retryFile.controlSize = .small; retryFile.delegate = self; retryFile.isHidden = true
        retryFile.setDraggingSourceOperationMask(.copy, forLocal: false)
        retryFile.target = self; retryFile.doubleAction = #selector(revealFile)
        retryFile.toolTip = ui("Drag this file into your app, or double-click to show it in Finder.")
        retryFile.setAccessibilityHelp(retryFile.toolTip)
        fileLabel.font = .systemFont(ofSize: 11); fileLabel.textColor = .secondaryLabelColor
        fileLabel.maximumNumberOfLines = 2
        fileProgress.isIndeterminate = false; fileProgress.minValue = 0; fileProgress.maxValue = 1
        fileProgress.style = .bar; fileProgress.isHidden = true
        mouseDisclosure = button(ui("Screen Layout ▸"), action: #selector(toggleMouseDetails))
        mouseDisclosure.controlSize = .small
        permissionLabel.font = .systemFont(ofSize: 11); permissionLabel.textColor = .secondaryLabelColor
        permissionLabel.maximumNumberOfLines = 3
        permissionActions = row([button(ui("Accessibility"), action: #selector(accessibilitySettings)), button(ui("Input Monitoring"), action: #selector(inputSettings)), button(ui("Check Again"), action: #selector(recheckPermissions)), flexible(NSView())])
        gestureHint.font = .systemFont(ofSize: 11); gestureHint.textColor = .secondaryLabelColor
        gestureHint.maximumNumberOfLines = 3
        mouseDetails = column([
            separator(), row([flexible(label(ui("Screen Layout"), size: 12, weight: .semibold)), swapScreens]),
            arrangement, arrangementHint, gestureHint, permissionLabel, permissionActions
        ], spacing: 8)
        mouseDetails.isHidden = true
        peerVersionLabel.font = .systemFont(ofSize: 11); peerVersionLabel.textColor = .secondaryLabelColor
        peerVersionLabel.maximumNumberOfLines = 3
        healthLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        healthLabel.textColor = .secondaryLabelColor; healthLabel.maximumNumberOfLines = 5
        let clipboardCard = panel(row([
            symbol("doc.on.clipboard", size: 20),
            flexible(column([label(ui("Clipboard"), size: 13, weight: .semibold), activityLabel], spacing: 5)), sendButton
        ]))
        let inputCard = panel(column([
            row([symbol("keyboard", size: 20), flexible(inputTitle), inputStatusLabel, mouseDisclosure, mouseToggle]),
            mouseHint, label(ui("Saved for this Mac · Press ⌃⌥Esc to stop input sharing"), size: 10, color: .secondaryLabelColor), mouseDetails
        ], spacing: 8))
        fileActions = row([fileCancel, revealButton, flexible(NSView())]); fileActions.isHidden = true
        let fileCard = panel(column([
            row([symbol("arrow.up.doc", size: 20), flexible(column([label(ui("Files"), size: 13, weight: .semibold), fileLabel, retryFile], spacing: 5)), fileButton]),
            fileProgress, fileActions
        ], spacing: 8))
        let sharing = column([clipboardCard, inputCard, fileCard], spacing: 10)
        sharingContent = sharing
        closePicker.addItems(withTitles: [ui("Ask each time"), ui("Keep running in the menu bar"), ui("Quit NearClip on close")])
        closePicker.selectItem(at: closeBehavior.rawValue); closePicker.target = self; closePicker.action = #selector(changeCloseBehavior)
        closePicker.setAccessibilityLabel(ui("When the window closes"))
        loginToggle = NSButton(checkboxWithTitle: ui("Start NearClip at login"), target: self, action: #selector(toggleLogin))
        loginToggle.state = !preview && SMAppService.mainApp.status == .enabled ? .on : .off
        closeHint.font = .systemFont(ofSize: 11); closeHint.textColor = .secondaryLabelColor
        relayToggle = NSButton(checkboxWithTitle: ui("Keep received clipboard items on this Mac"), target: self, action: #selector(toggleAppleRelay))
        relayToggle.state = preventAppleRelay ? .on : .off
        updateButton = button(ui("Check for Updates"), action: #selector(checkUpdates))
        updateDownloadButton = button(ui("Update and Restart…"), action: #selector(downloadUpdate)); updateDownloadButton.isHidden = true
        autoUpdateToggle = NSButton(checkboxWithTitle: ui("Check for updates daily"), target: self, action: #selector(toggleAutomaticUpdates))
        autoUpdateToggle.state = (UserDefaults.standard.object(forKey: "automaticUpdateChecks") as? Bool ?? true) ? .on : .off
        updateLabel.font = .systemFont(ofSize: 11); updateLabel.textColor = .secondaryLabelColor; updateLabel.maximumNumberOfLines = 3
        let language = NSPopUpButton()
        language.addItems(withTitles: ["English", "한국어"])
        let selected = UserDefaults.standard.string(forKey: AppLanguage.preferenceKey)
        language.selectItem(at: selected == "ko" ? 1 : 0)
        language.setAccessibilityLabel(ui("Language"))
        language.target = self
        language.action = #selector(changeLanguage(_:))
        settingsContent = column([
            row([label(ui("Language"), size: 14, weight: .semibold), language]),
            label(ui("Changes take effect the next time you open NearClip."), size: 11, color: .secondaryLabelColor),
            separator(), label(ui("Updates"), size: 14, weight: .semibold), autoUpdateToggle, updateLabel,
            row([updateButton, updateDownloadButton, button(ui("View Releases"), action: #selector(openReleases)), flexible(NSView())]),
            label(ui("Installing an update restarts NearClip and keeps your pairing. Update each Mac separately."), size: 11, color: .secondaryLabelColor),
            separator(), label(ui("Connection Diagnostics"), size: 14, weight: .semibold), peerVersionLabel, healthLabel,
            row([button(ui("Reconnect"), action: #selector(retry)), button(ui("Universal Control Guide"), action: #selector(universalControlHelp)), flexible(NSView())]),
            label(ui("Round-trip time measures the input connection. NearClip keeps the last 60 samples in memory."), size: 11, color: .secondaryLabelColor),
            separator(), label(ui("Clipboard Privacy"), size: 14, weight: .semibold), relayToggle,
            label(ui("Applies to new items received through NearClip. Other apps keep their clipboard settings."), size: 11, color: .secondaryLabelColor),
            row([button(ui("Apple Clipboard Settings"), action: #selector(appleClipboardHelp)), flexible(NSView())]),
            separator(), label(ui("Startup and Window"), size: 14, weight: .semibold), loginToggle,
            label(ui("When you close the window"), size: 12, weight: .medium), closePicker, closeHint,
            separator(), label(ui("Paired Mac"), size: 14, weight: .semibold),
            label(ui("To pair again, you’ll need to confirm the code on both Macs."), size: 12, color: .secondaryLabelColor),
            row([button(ui("Forget Mac…"), action: #selector(forgetPairing)), button(ui("Network Settings"), action: #selector(networkSettings)), button(ui("Keychain Help"), action: #selector(keychainHelp)), flexible(NSView())])
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
        let helpButton = button(ui("Help"), action: #selector(help)); helpButton.controlSize = .small
        let quitButton = button(ui("Quit ⌘Q"), action: #selector(quit)); quitButton.controlSize = .small
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
    @objc private func changeLanguage(_ sender: NSPopUpButton) {
        guard !preview else { return }
        let language = sender.indexOfSelectedItem == 1 ? "ko" : "en"
        UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
        UserDefaults.standard.set([language], forKey: "AppleLanguages")
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
        if CommandLine.arguments.contains("--connected") { peers = ["Studio MacBook Pro"]; lastActivity = ui("Received text · 14:32:08") }
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
            let host = Host.current().name ?? ui("This Mac’s IP address")
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
                self.lastActivity = ui("Connected to %1$@.", "\(name)"); self.restartTransport()
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
        let dialog = NSAlert(); dialog.messageText = ui("Connect to %1$@?", "\(name)")
        dialog.informativeText = ui("Compare the six digits on both Macs.\nConfirm on both to start sharing.")
        let number = NSTextField(labelWithString: String(digits.prefix(3)) + "  " + String(digits.suffix(3)))
        number.font = .monospacedDigitSystemFont(ofSize: 42, weight: .semibold)
        number.alignment = .center; number.frame = NSRect(x: 0, y: 0, width: 280, height: 65)
        dialog.accessoryView = number
        dialog.addButton(withTitle: ui("Codes Match · Connect"))
        dialog.addButton(withTitle: ui("Cancel"))
        verificationAlert = dialog
        dialog.beginSheetModal(for: window) { [weak self] response in
            self?.verificationAlert = nil
            if response == .alertFirstButtonReturn {
                self?.networkNote = ui("Compare the code and confirm on the other Mac.")
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
                if let image = packet.dragImage {
                    if image.kind == .offer && (!self.enabled || !self.mouse.isReceivingDrop(image.id) || self.mouse.draggedFileName != image.name || self.preparedImage != nil) {
                        self.transport?.sendFeature(FeaturePacket(dragImage: FilePacket(kind: .cancel, id: image.id)), to: peer)
                    } else { self.dragImages.receive(image, from: peer) }
                }
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
        pauseButton?.title = enabled ? ui("Pause") : ui("Resume")
        sendButton?.isEnabled = enabled && !peers.isEmpty
        menuSend?.isEnabled = enabled && !peers.isEmpty
        closeHint.stringValue = [ui("Choose what happens each time you close the window."), ui("Sharing continues in the menu bar. Choose Quit NearClip to stop."), ui("Closing the window quits NearClip and stops sharing.")][closeBehavior.rawValue]
        let text: String
        if busy { text = ui("Compare the codes") }
        else if !enabled { text = ui("Sharing paused") }
        else if !peers.isEmpty { text = ui("Connected") }
        else if access.hasTrustedPeer { text = ui("Waiting for your Mac") }
        else { text = ui("Connect a nearby Mac") }
        statusLabel.stringValue = text
        statusLabel.textColor = .labelColor
        statusIcon?.image = NSImage(systemSymbolName: busy ? "number.circle" : (!enabled ? "pause.circle" : (peers.isEmpty ? "circle.dotted" : "checkmark.circle.fill")), accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        statusIcon?.contentTintColor = !peers.isEmpty && enabled ? .systemTeal : .secondaryLabelColor
        if !enabled { activityLabel.stringValue = ui("Sharing is paused. After you resume, copy something new to share it.") }
        else if busy { activityLabel.stringValue = ui("Confirm the connection to start sharing.") }
        else if !peers.isEmpty { activityLabel.stringValue = lastActivity }
        else { activityLabel.stringValue = ui("Text and images sync after you connect.") }
        connectionHint.isHidden = !peers.isEmpty && !busy
        connectionHint.stringValue = networkNote ?? (busy ? ui("Compare the six digits on both Macs.") : ui("Open NearClip on the other Mac and join the same network."))
        sharingActions?.isHidden = !access.hasTrustedPeer && peers.isEmpty
        sharingContent?.isHidden = settingsExpanded || (!access.hasTrustedPeer && peers.isEmpty)
        statusSummary?.isHidden = settingsExpanded
        trustLabel.isHidden = settingsExpanded
        settingsButton?.title = settingsExpanded ? ui("Done") : ui("Settings")
        settingsButton?.image = NSImage(systemSymbolName: settingsExpanded ? "checkmark" : "gearshape", accessibilityDescription: nil)
        pairingHint.stringValue = access.hasTrustedPeer ? ui("Confirm the code on both Macs to replace your saved pairing.") : ui("Choose Connect next to the other Mac, then compare the codes.")
        trustLabel.stringValue = access.isOpen && access.hasTrustedPeer ? ui("Pairing open for two minutes · Confirm on both Macs") : access.isOpen ? ui("Ready to pair · Confirm on both Macs") : ui("Encrypted direct connection · No clipboard history")
        discoveryView?.isHidden = settingsExpanded || !access.isOpen
        trustedView?.isHidden = settingsExpanded || access.isOpen
        advancedView?.isHidden = !advanced
        advancedButton?.title = advanced ? ui("Hide Connection Help ▴") : ui("Can't see your Mac? ▾")
        cancelButton?.isHidden = !access.hasTrustedPeer && !busy
        cancelButton?.title = busy ? ui("Cancel Connection") : ui("Stop Searching")
        copyAddressButton?.isEnabled = hasLocalAddress && access.isOpen
        peerLabel.stringValue = peers.first ?? pairedName ?? ui("Saved Mac")
        peerDetail.stringValue = peers.isEmpty ? ui("Offline · Reconnects automatically") : ui("Paired · Reconnects automatically")
        for view in deviceList?.arrangedSubviews ?? [] {
            (view as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSButton }.forEach { $0.isEnabled = !busy }
        }
        updateSharingUI()
        updateWindowSize()
        menuStatus?.title = statusLabel.stringValue
        menuToggle?.title = enabled ? ui("Pause Sharing") : ui("Resume Sharing")
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
                label(ui("Open NearClip on the other Mac"), size: 13, weight: .medium),
                label(ui("If it already has a pairing, choose Change Mac there.\nNearby Macs appear here."), size: 11, color: .secondaryLabelColor)
            ], spacing: 6)
            deviceList.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: deviceList.widthAnchor).isActive = true
        }
        for candidate in candidates {
            let name = label(candidate.name, size: 13, weight: .medium)
            name.maximumNumberOfLines = 1; name.lineBreakMode = .byTruncatingTail
            let identity = label("Mac · " + candidate.device.prefix(4), size: 10, color: .secondaryLabelColor)
            identity.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            let connect = button(ui("Connect"), action: #selector(connectNearby(_:)))
            connect.identifier = NSUserInterfaceItemIdentifier(candidate.device)
            connect.setAccessibilityLabel(ui("Connect to %1$@", candidate.name))
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
        localAddress.stringValue = ui("Getting address…")
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
        let dialog = NSAlert(); dialog.messageText = ui("Connect by Address")
        dialog.informativeText = ui("Enter the other Mac’s hostname or IP address and port.\nExample: my-mac.local:54321")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        field.placeholderString = ui("host:port"); dialog.accessoryView = field
        dialog.addButton(withTitle: ui("Request Connection")); dialog.addButton(withTitle: ui("Cancel"))
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
            sync.resetSession(); lastActivity = ui("Pairing removed. Choose a Mac to connect."); restartTransport()
        } catch { alert(error.localizedDescription) }
    }
    @objc private func sendNow() {
        guard !preview else { return }
        guard enabled, sync.connected else { lastActivity = ui("Resume sharing and connect a Mac first."); refresh(); return }
        sync.poll(force: true)
    }
    @objc private func toggleSharing() {
        enabled.toggle();
        if !enabled { appDrop = nil; approvedDropDirectory = nil; fileDestination = nil; mouse?.stop(); files.cancel() }
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
        if let screen = NSScreen.screens.first, let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            let bounds = CGDisplayBounds(display)
            for side in [ScreenSide.left, .right] {
                fileEdge.present(at: CGPoint(x: bounds.midX, y: bounds.midY), side: side)
                require(fileEdge.frame.minY == screen.frame.minY && fileEdge.frame.maxY == screen.frame.maxY &&
                        (side == .left ? fileEdge.frame.minX == screen.frame.minX : fileEdge.frame.maxX == screen.frame.maxX),
                        "a diagonal file drag can reach the full shared edge")
                fileEdge.orderOut(nil)
            }
        }
        require(NSApp.mainMenu?.items.first?.submenu?.items.contains(where: { $0.keyEquivalent == "q" }) == true, "Command-Q is installed in app menu")
        toggleSharing(); require(!enabled && statusLabel.stringValue == ui("Sharing paused"), "pause updates visible state")
        toggleSharing(); require(enabled, "resume updates sharing state")
        require(mouseDetails.isHidden, "mouse details start collapsed on the main screen")
        showSharing(); require(!mouseDetails.isHidden && fileButton.superview != nil, "file and mouse controls are reachable without tabs")
        toggleMouseDetails(); require(mouseDetails.isHidden, "mouse arrangement can collapse independently")
        toggleMouseDetails()
        directDrop = true
        fileStatus("Sending test image", progress: 0.5, busy: true)
        require(fileProgress.isHidden && fileActions.isHidden, "short drop stays quiet")
        fileStatus("Sent", progress: 1, busy: false)
        require(progressDelay == nil && fileProgress.isHidden && fileLabel.stringValue == Self.fileHint, "completed drop never flashes a progress bar")
        let offer = FilePacket(kind: .offer, id: UUID(), name: "preview.png", size: 1)
        do {
            let image = try PreparedDragImage(offer: offer)
            try Data([0]).write(to: image.url)
            defer { try? FileManager.default.removeItem(at: image.url.deletingLastPathComponent()) }
            preparedImage = image
            let outside = CGPoint(x: -100000, y: -100000)
            require(releaseFileDrop(id: offer.id, name: "preview.png", at: outside),
                    "an unresolved image drop keeps its pending transfer")
            dragImages.onComplete?(image.url)
            require(receivedFile == image.url && !retryFile.isHidden && receivePanel == nil && !files.busy,
                    "an unresolved image can be retried locally without opening a save sheet")
        } catch { require(false, "prepare synthetic drop") }
        let testURL = URL(fileURLWithPath: "/synthetic/drop.png")
        files.onComplete?(testURL)
        require(receivedFile == nil && revealButton.isHidden, "direct folder drops finish quietly")
        files.onComplete?(testURL)
        require(receivedFile == testURL && !revealButton.isHidden, "manual saves keep Show in Finder")
        fileStatus("Receiving", progress: 0.25, busy: true); progressDelay?.fire()
        require(!fileProgress.isHidden && !fileCancel.isHidden && fileProgress.doubleValue == 0.25, "long transfer exposes progress and cancellation")
        fileStatus("Cancelled", progress: nil, busy: false)
        require(fileProgress.isHidden && fileActions.isHidden && fileLabel.stringValue == "Cancelled", "failed transfer clears progress and keeps its explanation")
        finishAppDrop(accepted: false, url: testURL)
        require(receivedFile == testURL && !retryFile.isHidden && fileActions.isHidden && retryFile.pathItems.count == 1, "retry shows only the draggable filename in the Files card")
        if let leaf = retryFile.pathItems.last {
            require(leaf.url == testURL && pathControl(retryFile, shouldDrag: leaf, with: .init(name: .drag)), "retry drag offers the received URL")
        }
        finishAppDrop(accepted: true, url: testURL)
        require(receivedFile == nil && retryFile.isHidden && fileProgress.isHidden && fileActions.isHidden && fileLabel.stringValue == Self.fileHint, "accepted app drop leaves the file card idle")
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
        require(inputStatusLabel.stringValue == ui("Reconnecting"), "main window identifies input recovery separately from clipboard connectivity")
        require(fileButton.isEnabled && peerVersionLabel.stringValue.contains(ui("Builds match")), "input outage preserves file controls and reports matched versions")
        setMouseSharing(false)
        require(inputStatusLabel.stringValue == ui("Off"), "main window shows the explicit off choice during a transport outage")
        require(!mouse.sharingRequested && mouseToggle.state == .off && mouseToggle.isEnabled && menuMouseToggle.isEnabled,
                "turning sharing off during recovery keeps both enable controls available")
        toggleMouseFromMenu()
        require(mouse.sharingRequested && !mouse.enabled && mouse.peer == nil && mouseToggle.state == .on,
                "menu enable during recovery records consent without capturing input")
        require(mouseHint.stringValue.contains(ui("when input reconnects")), "pending input choice is distinguished from active sharing")
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
        require(inputStatusLabel.stringValue == ui("Waiting for peer"), "connected input is not presented as usable before remote consent")
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
        require(!menuSwapScreens.isEnabled && !menuMouseToggle.isEnabled && menuScreenOrder.title == ui("Screen Layout · Waiting for a Mac"),
                "disconnected menu disables new sharing and layout changes")
        mouse.send = originalSend
        require(gestureHint.stringValue.contains(ui("After connecting")), "disconnected gesture guidance explains capability check")
        let fixturePeer = ConnectedPeer(device: "gesture-peer", name: "Gesture fixture", connection: UUID(), features: [SharingFeature.mouse, SharingFeature.keyboard])
        updateFeaturePeer([fixturePeer])
        require(gestureHint.stringValue.contains(ui("check features")), "legacy peer explains why gestures stay local")
        let capablePeer = ConnectedPeer(device: "gesture-peer", name: "Gesture fixture", connection: UUID(), features: Set(SharingFeature.supported))
        updateFeaturePeer([capablePeer])
        require(gestureHint.stringValue.contains(ui("controlling Mac")), "gesture guidance identifies which Mac supplies finger-count settings")
        try? mouse.setEnabled(true)
        mouse.secureInputEnabled = { true }; mouse.tick(); updateSharingUI()
        require(mouseHint.stringValue.contains(ui("Secure Input on this Mac")) && mouseToggle.state == .on,
                "secure-input pause is visible without clearing the sharing choice")
        mouse.secureInputEnabled = { false }; mouse.tick(); updateSharingUI()
        mouse.receive(MousePacket(kind: .availability, enabled: true, secureInputActive: true), from: "gesture-peer")
        updateSharingUI()
        require(mouseHint.stringValue.contains(ui("Secure Input on the other Mac")), "remote secure-input pause identifies the blocked Mac")
        mouse.receive(MousePacket(kind: .availability, enabled: true, secureInputActive: false), from: "gesture-peer")
        updateSharingUI()
        require(!mouseHint.stringValue.contains(ui("Secure Input")), "cleared secure input restores normal sharing guidance")
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
        } catch { alert(ui("Couldn’t change the login setting. Move NearClip to Applications and try again.\n") + error.localizedDescription) }
        loginToggle.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
    @objc private func forgetPairing() {
        let dialog = NSAlert(); dialog.messageText = ui("Forget this Mac?")
        dialog.informativeText = ui("Sharing will stop. To reconnect, compare the codes on both Macs again.")
        dialog.addButton(withTitle: ui("Forget Mac")); dialog.addButton(withTitle: ui("Cancel"))
        dialog.beginSheetModal(for: window) { [weak self] result in if result == .alertFirstButtonReturn { self?.newCode() } }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeBehavior == .quit { quit(); return false }
        if closeBehavior == .keepRunning { NSApp.setActivationPolicy(.accessory); return true }
        guard !closingPrompt else { return false }; closingPrompt = true
        let dialog = NSAlert(); dialog.messageText = ui("Quit NearClip?")
        dialog.informativeText = ui("Quitting stops sharing. Keep NearClip in the menu bar to continue.")
        dialog.addButton(withTitle: ui("Quit")); dialog.addButton(withTitle: ui("Keep in Menu Bar")); dialog.addButton(withTitle: ui("Cancel"))
        dialog.showsSuppressionButton = true; dialog.suppressionButton?.title = ui("Remember my choice")
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
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "NearClip", .applicationVersion: version, .credits: NSAttributedString(string: ui("Share a clipboard, files, mouse, and keyboard between Macs. MIT License."))])
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func help() {
        let dialog = NSAlert(); dialog.messageText = ui("Connect two Macs")
        dialog.informativeText = ui("Open NearClip on both Macs and join the same network. Choose Connect and compare the six digits. If they match, confirm on both Macs. Copy text or an image, then paste it on the other Mac.\n\nAllow Local Network and paste access when prompted. You can change permissions in System Settings. Guest networks may block connections between devices.\n\nClipboard items can be up to 20 MiB. Images can contain up to 40 million pixels. To share something copied before connecting or while paused, choose Send Now. Items marked private by password managers are skipped.")
        dialog.informativeText += ui("\n\nOpen Screen Layout to arrange the Macs. Enable mouse and keyboard sharing on both, then push the pointer against the shared edge. Press ⌃⌥Esc to stop. To send a file, choose Send File. The recipient chooses where to save it.")
        dialog.addButton(withTitle: ui("OK")); dialog.runModal()
    }
    private func alert(_ message: String) {
        let dialog = NSAlert(); dialog.messageText = "NearClip"; dialog.informativeText = message
        dialog.addButton(withTitle: ui("OK")); NSApp.activate(ignoringOtherApps: true); dialog.runModal()
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
        fileEdge.target.enter = { [weak self] source, point in
            let url = source.url
            guard let self, let peer = self.featurePeer, self.enabled, !self.files.busy,
                  self.draggingFile == nil,
                  ScreenGeometry.exit(at: point, deltaX: self.mouse.side == .left ? -1 : 1, side: self.mouse.side, displays: self.mouse.displays()) != nil,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink == false,
                  let size = values.fileSize, size <= FilePacket.maxSize else { return false }
            self.draggingFile = (source, peer.connection)
            if self.mouse.startFileDrag(named: url.lastPathComponent, at: point) { return true }
            self.draggingFile = nil
            return false
        }
        fileEdge.target.drop = { [weak self] url in
            guard let self, let drag = self.draggingFile, drag.source.url == url,
                  drag.connection == self.featurePeer?.connection else { return false }
            return (self.mouse.returningFile && self.mouse.mode == .receiving) || self.mouse.fileDropReleased || self.mouse.releaseFileDrag()
        }
        fileEdge.target.exit = { [weak self] ended in
            guard let self, !self.mouse.fileDropReleased else { return }
            if self.draggingFile != nil {
                if self.mouse.returningFile && self.mouse.mode == .receiving { return }
                if !ended && self.mouse.mode == .controlling { return }
                self.mouse.endSession(reason: .handoffCancelled)
            }
            self.fileEdge.orderOut(nil)
        }
        mouse.onFileEdge = { [weak self] point, side in
            guard let self, !self.headlessDiagnostics, !self.showingFileEdge, !self.fileEdge.isVisible else { return }
            self.showingFileEdge = true
            DispatchQueue.main.async {
                defer { self.showingFileEdge = false }
                guard self.enabled, !self.files.busy, self.mouse.enabled, self.mouse.remoteEnabled,
                      self.mouse.side == side, self.mouse.canPickUpRemoteDrag || (self.mouse.mode == .local && NSEvent.pressedMouseButtons & 1 == 1),
                      (self.mouse.canPickUpRemoteDrag || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" || FinderFileDrop.fileURL(from: NSPasteboard(name: .drag)) != nil || DragSourceFile.hasImage(on: NSPasteboard(name: .drag))) else { return }
                self.fileEdge.present(at: point, side: side)
                self.fileEdge.dismissWhenDragEnds { [weak self] in self?.mouse.canPickUpRemoteDrag == true }
            }
        }
        mouse.onFileDragAccepted = { [weak self] id in
            guard let self, let peer = self.featurePeer, peer.features.contains(SharingFeature.dragImage),
                  let drag = self.draggingFile, drag.connection == peer.connection,
                  let size = try? drag.source.url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  FilePacket.canPrepareImage(name: drag.source.url.lastPathComponent, size: Int64(size)) else { return }
            do {
                try self.dragImages.offer(url: drag.source.url, to: peer.device, id: id, keeping: drag.source, preparePreview: true)
                self.preparingImageID = id
            } catch { /* The release can still use the regular file transfer. */ }
        }
        mouse.onFileDropPosition = { [weak self] id, point in
            guard let self, let name = self.mouse.draggedFileName else { return false }
            return self.releaseFileDrop(id: id, name: name, at: point)
        }
        mouse.onFileDropReady = { [weak self] id, prepared in
            guard let self, self.mouse.fileDropReleased, let drag = self.draggingFile, self.enabled,
                  let peer = self.featurePeer, peer.connection == drag.connection else { return }
            if self.preparingImageID == id {
                self.preparingImageID = nil
                if prepared { return }
                self.dragImages.decline(id: id)
            }
            self.directDrop = true
            do { try self.files.offer(url: drag.source.url, to: peer.device, id: id, keeping: drag.source) }
            catch { self.directDrop = false; self.alert(error.localizedDescription) }
        }
        mouse.onFileDragMove = { [weak self] point in
            guard let self, let name = self.mouse.draggedFileName else { return false }
            self.startHeldDropIfReady()
            if let held = self.heldDrop {
                held.moveHeld(to: point)
                return !self.mouse.returningFile || held.isDragging
            }
            self.fileBadge.show(name, at: point)
            return false
        }
        mouse.onEdgeProgress = { [weak self] point, side, progress in
            guard let self, !self.headlessDiagnostics else { return }
            if let point { self.edgeIndicator.show(at: point, side: side, progress: progress, connected: false) }
            else { self.edgeIndicator.hide() }
        }
        mouse.onChange = { [weak self] in
            guard let self else { return }
            if self.mouse.mode == .local {
                if self.preparedImage?.released != true { self.discardPreparedImage() }
                if let id = self.preparingImageID { self.dragImages.decline(id: id); self.preparingImageID = nil }
            }
            if !self.headlessDiagnostics {
                if self.mouse.mode == .local || (self.draggingFile != nil && self.mouse.draggedFileName == nil) {
                    self.draggingFile = nil
                    self.fileEdge.orderOut(nil); self.fileBadge.dismiss()
                }
                if (self.mouse.returningFile ? self.mouse.mode == .controlling : self.mouse.mode == .receiving), self.heldDrop?.isDragging != true, let name = self.mouse.draggedFileName {
                    self.fileBadge.show(name, at: self.mouse.indicatorPoint)
                }
                if self.mouse.active && self.mouse.draggedFileName == nil {
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
        dragImages.send = { [weak self] peer, packet, reply in
            guard let transport = self?.transport else { reply(false); return }
            transport.sendFeature(FeaturePacket(dragImage: packet), to: peer, completion: reply)
        }
        dragImages.onOffer = { [weak self] _, offer in
            guard let self else { return }
            guard self.enabled, self.mouse.isReceivingDrop(offer.id), self.mouse.draggedFileName == offer.name,
                  self.preparedImage == nil, let image = try? PreparedDragImage(offer: offer) else {
                self.dragImages.decline(id: offer.id); return
            }
            self.preparedImage = image
            self.dragImages.accept(id: offer.id, destination: image.url)
            if let data = offer.previewPNG, let thumbnail = PreparedDragImage.thumbnail(data, isPreview: true) {
                self.fileBadge.setThumbnail(NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height)))
            }
        }
        dragImages.onStatus = { [weak self] text, progress, busy in
            guard let self, !busy, progress == nil, let image = self.preparedImage else { return }
            if image.released {
                self.fileLabel.stringValue = text
                if self.appDrop?.id == image.id { self.appDrop = nil }
            }
            self.preparedImage = nil
            self.fileBadge.setThumbnail(nil)
        }
        dragImages.onComplete = { [weak self] url in
            guard let self, let image = self.preparedImage, image.url == url else { return }
            image.verified = true
            if image.released { self.deliverPreparedImage() } else { self.startHeldDropIfReady() }
        }
        files.send = { [weak self] peer, packet, reply in
            guard let transport = self?.transport else { reply(false); return }
            transport.sendFeature(FeaturePacket(file: packet), to: peer, completion: reply)
        }
        files.onStatus = { [weak self] text, progress, busy in
            self?.fileStatus(text, progress: progress, busy: busy)
        }
        files.onOffer = { [weak self] _, offer in self?.receiveFile(offer) }
        files.onComplete = { [weak self] url in
            guard let self else { return }
            let direct = self.directDrop; self.directDrop = false
            if let drop = self.appDrop, let url, drop.destination == url {
                self.deliverAppDrop(drop, url: url)
                return
            }
            self.showReceivedFile(direct ? nil : url)
        }
    }
    private func releaseFileDrop(id: UUID, name: String, at point: CGPoint) -> Bool {
        lastFileDropID = id
        if let pending = heldDrop, !pending.isDragging { pending.abort() }
        fileBadge.dismiss()
        appDrop = nil
        fileDestination = nil
        let image = preparedImage
        let matchesImage = image?.id == id && image?.url.lastPathComponent == name
        if matchesImage, let image, let held = heldDrop, held.id == id, held.canReleaseHeld(at: point) {
            image.released = true
            if image.take() != nil {
                held.releaseHeld(at: point)
                return true
            }
        }
        heldDrop?.abort()
        appDrop = AppFileDrop(id: id, name: name, point: point)
        if appDrop == nil {
            var isFinder = false
            let folder = finderFolder(at: point, isFinder: &isFinder)
            if isFinder {
                let directory = folder.flatMap { ReceiveDirectory.finderDrop(at: $0, named: name) }
                fileDestination = (id, name, folder, directory, Date())
                discardPreparedImage()
                return false
            }
        }
        guard matchesImage, let image else { discardPreparedImage(); return false }
        // An unresolved app drop keeps the verified file available for a local retry.
        image.released = true
        if mouse.returningFile {
            // AppKit can start the local drop once the physical mouse-up has cleared the event tap.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.preparedImage === image else { return }
                self.deliverPreparedImage()
            }
        } else { deliverPreparedImage() }
        return true
    }
    private func startHeldDropIfReady(recheck: Bool = false) {
        guard heldDrop?.isDragging != true, let image = preparedImage, image.verified, !image.released,
              let preview = fileBadge.preview, enabled, mouse.draggedFileName == image.url.lastPathComponent else { return }
        if !recheck {
            let now = ProcessInfo.processInfo.systemUptime
            guard now >= image.nextHoverCheck else { return }
            let next = now + 0.2
            image.nextHoverCheck = next
            if mouse.returningFile {
                // The pointer can stop over the chat while a moving source panel is rejected.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self, weak image] in
                    guard let self, let image, self.preparedImage === image, image.nextHoverCheck == next else { return }
                    self.startHeldDropIfReady(recheck: true)
                }
            }
        }
        guard heldDrop == nil, mouse.isReceivingDrop(image.id), let point = CGEvent(source: nil)?.location,
              let drop = AppFileDrop(id: image.id, name: image.url.lastPathComponent, point: point) else { return }
        heldDrop = drop
        drop.didBegin = { [weak self] in self?.fileBadge.hide() }
        drop.deliver(file: image.url, preview: preview, returningDrag: mouse.returningFile, authorized: { [weak self, weak drop] in
            guard let self, let drop else { return false }
            return self.heldDrop === drop && self.enabled && self.mouse.isReceivingDrop(drop.id)
        }) { [weak self, weak drop] accepted in
            guard let self, let drop, self.heldDrop === drop else { return }
            self.heldDrop = nil
            if image.released {
                self.preparedImage = nil
                self.appDrop = nil
                self.finishAppDrop(accepted: accepted, url: image.url)
            }
        }
    }
    private func discardPreparedImage() {
        heldDrop?.abort(); heldDrop = nil
        guard let image = preparedImage else { return }
        preparedImage = nil
        dragImages.decline(id: image.id)
        fileBadge.setThumbnail(nil)
    }
    private func deliverPreparedImage() {
        guard let image = preparedImage, let url = image.take() else { return }
        preparedImage = nil
        if let drop = appDrop, drop.id == image.id { deliverAppDrop(drop, url: url) }
        else { finishAppDrop(accepted: false, url: url) }
    }
    private func deliverAppDrop(_ drop: AppFileDrop, url: URL) {
        drop.deliver(file: url, authorized: { [weak self, weak drop] in
            guard let self, let drop else { return false }
            return self.enabled && self.appDrop === drop && self.mouse.isReceivingDrop(drop.id)
        }) { [weak self, weak drop] accepted in
            guard let self, let drop, self.appDrop === drop else { return }
            self.appDrop = nil
            self.finishAppDrop(accepted: accepted, url: url)
        }
    }
    private func fileStatus(_ text: String, progress: Double?, busy: Bool) {
        if busy {
            if fileCancel.isHidden {
                pendingProgress = (text, progress)
                if progressDelay == nil {
                    fileButton.isEnabled = false
                    showReceivedFile(nil)
                    fileLabel.stringValue = Self.fileHint
                    let delay = Timer(timeInterval: 0.55, repeats: false) { [weak self] _ in
                        guard let self, let pending = self.pendingProgress else { return }
                        self.progressDelay = nil; self.pendingProgress = nil
                        self.showFileProgress(pending.text, value: pending.value)
                    }
                    progressDelay = delay; RunLoop.main.add(delay, forMode: .common)
                }
            } else { showFileProgress(text, value: progress) }
            return
        }
        progressDelay?.invalidate(); progressDelay = nil; pendingProgress = nil
        fileProgress.isHidden = true; fileCancel.isHidden = true
        let quietSuccess = progress != nil && (directDrop || appDrop?.destination != nil)
        fileLabel.stringValue = quietSuccess ? Self.fileHint : text
        if progress == nil { directDrop = false; appDrop = nil }
        if let panel = receivePanel { panel.cancel(nil); receivePanel = nil }
        refresh()
    }
    private func showFileProgress(_ text: String, value: Double?) {
        let layoutChanged = fileCancel.isHidden || fileProgress.isHidden != (value == nil)
        fileLabel.stringValue = text
        fileProgress.doubleValue = value ?? 0; fileProgress.isHidden = value == nil
        fileCancel.isHidden = false; fileActions.isHidden = false
        if layoutChanged { updateWindowSize() }
    }
    private func showReceivedFile(_ url: URL?, forRetry: Bool = false) {
        receivedFile = url
        retryFile.url = forRetry ? url : nil
        if let leaf = retryFile.pathItems.last { retryFile.pathItems = [leaf] }
        retryFile.isHidden = !forRetry
        revealButton.isHidden = url == nil || forRetry
        let hidden = fileCancel.isHidden && revealButton.isHidden
        if fileActions.isHidden != hidden { fileActions.isHidden = hidden; updateWindowSize() }
    }
    func pathControl(_ pathControl: NSPathControl, shouldDrag pathItem: NSPathControlItem, with pasteboard: NSPasteboard) -> Bool {
        pathControl === retryFile && !retryFile.isHidden && receivedFile != nil && pathItem.url == receivedFile
    }
    private func finishAppDrop(accepted: Bool, url: URL) {
        fileLabel.stringValue = accepted ? Self.fileHint : ui("Drag the file below into your app.")
        showReceivedFile(accepted ? nil : url, forRetry: !accepted)
    }
    private func updateFeaturePeer(_ peers: [ConnectedPeer]) {
        let next = peers.count == 1 ? peers.first : nil
        let previous = featurePeer
        let parentChanged = previous?.connection != next?.connection
        let inputChanged = parentChanged || previous?.inputReady != next?.inputReady || previous?.inputSession != next?.inputSession
        featurePeer = next
        if inputChanged { lastFileDropID = nil; discardPreparedImage(); preparingImageID = nil; dragImages.disconnected(); appDrop = nil; fileDestination = nil; approvedDropDirectory = nil }
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
                              supportsGestures: next?.features.contains(SharingFeature.gestures) == true,
                              supportsFileDrag: next?.features.isSuperset(of: [SharingFeature.files, SharingFeature.fileDrag]) == true,
                              supportsReturnFile: next?.features.contains(SharingFeature.returnFileDrag) == true)
            }
        }
        updateSharingUI()
    }
    private func updateHealthUI() {
        guard let peer = featurePeer else { healthLabel.stringValue = ui("Connect to the other Mac to measure input latency."); return }
        if !peer.inputReady {
            healthLabel.stringValue = ui("Reconnecting input. Clipboard and file sharing are still connected.")
            if let failure = peer.inputFailure { healthLabel.stringValue += "\n" + failure }
        }
        else if let inputHealth { healthLabel.stringValue = ui("Input connection · ") + inputHealth.label }
        else if peer.features.contains(SharingFeature.inputMetrics) { healthLabel.stringValue = ui("Input connection · Measuring latency…") }
        else { healthLabel.stringValue = ui("Update the other Mac to see input latency.") }
        if let timing = mouse.motionTimingLabel { healthLabel.stringValue += "\n" + timing }
        if !mouse.active, let message = mouse.lastEndMessage { healthLabel.stringValue += "\n" + message }
        if mouse.active { healthLabel.stringValue += ui("\nCurrent control: NearClip · ") + (mouse.mode == .receiving ? ui("The other Mac controls this Mac") : ui("This Mac controls the other Mac")) }
        else { healthLabel.stringValue += ui("\nNearClip is idle. Check Displays settings for Apple Universal Control.") }
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
        guard !files.busy else { alert(ui("Finish or cancel the file transfer before updating.")); return }
        updateButton.isEnabled = false; updateDownloadButton.isEnabled = false
        updateLabel.stringValue = ui("Opening the update window…")
        UpdateInstaller.open { [weak self] error in
            guard let self else { return }
            self.updateButton.isEnabled = true; self.updateDownloadButton.isEnabled = true
            self.updateLabel.stringValue = error?.localizedDescription ?? ui("Installing the update disconnects sharing and restarts NearClip.")
            if let error { self.alert(error.localizedDescription) }
        }
    }
    private func performUpdateCheck() {
        guard !preview, !updateChecker.checking else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateAttempt")
        updateButton.isEnabled = false; updateLabel.stringValue = ui("Checking releases…")
        updateChecker.check { [weak self] result in
            guard let self, !self.terminating else { return }
            self.updateButton.isEnabled = true
            switch result {
            case .success(let release):
                self.updateDownload = nil
                if let release, let latest = release.version {
                    if AppVersion.current < latest {
                        self.updateDownload = release.downloadURL
                        self.updateLabel.stringValue = ui("%1$@ is available. Update both Macs.", "\(latest.label)")
                    } else if latest < AppVersion.current { self.updateLabel.stringValue = ui("This build is newer than the public release.") }
                    else { self.updateLabel.stringValue = ui("You have the latest public release.") }
                } else { self.updateLabel.stringValue = ui("No public release is available yet.") }
                self.updateDownloadButton.isHidden = self.updateDownload == nil
                self.updateMenu?.title = self.updateDownload == nil ? ui("Check for Updates…") : ui("Update Available…")
            case .failure:
                self.updateLabel.stringValue = ui("Couldn’t check for updates. Check your connection and try again.")
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
        mouseDisclosure?.title = mouseDetailsExpanded ? ui("Screen Layout ▾") : ui("Screen Layout ▸")
        permissionLabel.stringValue = permissions.granted ? ui("✓ Accessibility and Input Monitoring allowed") : permissions.statusText
        permissionActions?.isHidden = permissions.granted
        peerVersionLabel.isHidden = featurePeer == nil
        peerVersionLabel.stringValue = AppVersion.current.peerNotice(featurePeer?.appVersion)
        peerVersionLabel.textColor = featurePeer?.appVersion == AppVersion.current ? .secondaryLabelColor : .systemOrange
        updateHealthUI()
        let supportsFiles = featurePeer?.features.contains(SharingFeature.files) == true
        let supportsMouse = featurePeer?.features.contains(SharingFeature.mouse) == true
        if !DockSwipeAdapter.available { gestureHint.stringValue = ui("Gestures require a supported macOS version. Mouse and keyboard sharing are available.") }
        else if !supportsMouse { gestureHint.stringValue = ui("After connecting, NearClip checks whether the other Mac supports gestures.") }
        else if !mouse.gesturesSupported {
            let platform = featurePeer?.osMajor.map { ui("Other Mac: macOS %1$@ · ", "\($0)") } ?? ""
            gestureHint.stringValue = ui("Gestures unavailable · ") + platform + ui("Update the other Mac to check features and macOS compatibility.")
        }
        else { gestureHint.stringValue = ui("Swipe with three or four fingers for Spaces and Mission Control. Use the finger count set on the controlling Mac.") }
        fileButton.isEnabled = enabled && supportsFiles && !files.busy
        fileActions?.isHidden = fileCancel.isHidden && revealButton.isHidden
        swapScreens.isEnabled = supportsMouse && !mouse.active
        mouseToggle.isEnabled = mouse.sharingRequested || (enabled && supportsMouse)
        inputTitle.stringValue = featurePeer?.features.contains(SharingFeature.keyboard) == true || !supportsMouse ? ui("Mouse & Keyboard") : ui("Mouse")
        mouseToggle.state = mouse.sharingRequested ? .on : .off
        let inputStatus = InputSharingStatus.resolve(requested: mouse.sharingRequested, connected: supportsMouse,
            inputReady: featurePeer?.inputReady == true, permissions: permissions.granted,
            captureEnabled: mouse.enabled, peerEnabled: mouse.remoteEnabled, paused: mouse.inputPauseMessage != nil)
        inputStatusLabel.stringValue = ui(inputStatus.rawValue)
        inputStatusLabel.textColor = inputStatus == .ready ? .systemGreen : inputStatus == .off ? .secondaryLabelColor : .systemOrange
        arrangement.update(peerID: supportsMouse ? featurePeer?.connection.uuidString : nil,
                           localName: preview ? "My MacBook" : deviceName,
                           peerName: featurePeer?.name ?? ui("other Mac"), side: mouse.side,
                           editable: supportsMouse && !mouse.active)
        arrangementHint.stringValue = mouse.active ? ui("End remote control before arranging screens. Press ⌃⌥Esc to stop input sharing.") : ui("Drag the screens to match your desk. Both Macs use this layout.")
        if featurePeer != nil && featurePeer?.inputReady == false {
            mouseHint.stringValue = mouse.sharingRequested
                ? ui("Input sharing starts when input reconnects. Clipboard and files are still available.")
                : ui("Turn on input sharing now to start when the input connection is ready.")
        }
        else if mouse.sharingRequested && !mouse.enabled {
            mouseHint.stringValue = permissions.granted ? ui("Preference saved. Sharing resumes when this Mac reconnects.") : ui("Open Screen Layout to review permissions.")
        }
        else if !supportsMouse { mouseHint.stringValue = ui("Connect to share your pointer and keyboard.") }
        else if !mouse.enabled { mouseHint.stringValue = mouseSetupError ?? (mouse.keyboardSupported ? ui("Turn sharing on at both ends, then move the pointer to the edge.") : ui("Update the other Mac to share the keyboard.")) }
        else if let pause = mouse.inputPauseMessage { mouseHint.stringValue = pause }
        else if !mouse.remoteEnabled { mouseHint.stringValue = ui("This Mac is ready. Turn on mouse sharing on the other Mac.") }
        else {
            mouseHint.stringValue = mouse.gesturesSupported ? ui("Ready · Move to the edge to switch Macs · Three- and four-finger swipes in beta") : ui("Ready · Push the pointer against the edge to switch Macs.")
        }
        menuMouseToggle?.state = mouse.sharingRequested ? .on : .off
        menuMouseToggle?.isEnabled = mouse.sharingRequested || mouseToggle.isEnabled
        menuMouseToggle?.title = inputTitle.stringValue + ui(" sharing")
        menuSwapScreens?.isEnabled = swapScreens.isEnabled
        menuScreenOrder?.title = supportsMouse ? (mouse.side == .left ? ui("Other Mac ← This Mac") : ui("This Mac → Other Mac")) : ui("Screen Layout · Waiting for a Mac")
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
        let dialog = NSAlert(); dialog.messageText = ui("Using Apple Universal Control?")
        dialog.informativeText = ui("Universal Control links nearby Macs and iPads on the same Apple Account. To test NearClip on its own, open System Settings → Displays → Advanced and turn off pointer and keyboard sharing temporarily.\n\nFor permission errors, check Accessibility and Input Monitoring first.")
        dialog.addButton(withTitle: ui("Open Displays Settings")); dialog.addButton(withTitle: ui("Close"))
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
        let dialog = NSAlert(); dialog.messageText = ui("Apple Universal Clipboard")
        dialog.informativeText = ui("Turn on clipboard protection to keep new items received through NearClip on this Mac. Other apps and items you copy again can still use Universal Clipboard.\n\nTo turn off Universal Clipboard system-wide, open System Settings → General → AirDrop & Handoff and turn off Handoff. This also affects other Continuity features.")
        dialog.addButton(withTitle: ui("Open General Settings")); dialog.addButton(withTitle: ui("Close"))
        dialog.beginSheetModal(for: window) { result in
            if result == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.General-Settings.extension")!) }
        }
    }
    @objc private func keychainHelp() {
        alert(ui("NearClip stores its pairing key in your login keychain. Choose Always Allow to let the signed NearClipKeyStore helper read the key across updates. Allow grants access once.\n\nmacOS may ask again if the helper or its signature changes, or if the keychain is locked. Enter your password only in the macOS prompt."))
    }
    @objc private func stopInput() { mouse?.stop(); if window != nil { refresh() } }
    @objc private func accessibilitySettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    @objc private func inputSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!) }
    @objc private func sendFile() {
        guard !preview, enabled, let peer = featurePeer, peer.features.contains(SharingFeature.files), !files.busy else { return }
        let panel = NSOpenPanel(); panel.title = ui("Choose a File to Send"); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = ui("Send one file up to 2 GiB. The original stays on this Mac.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url, self.enabled, self.featurePeer?.connection == peer.connection else { return }
            do { try self.files.offer(url: url, to: peer.device) } catch { self.alert(error.localizedDescription) }
        }
    }
    private func receiveFile(_ offer: FilePacket) {
        guard !preview, enabled, window.attachedSheet == nil else { files.decline(id: offer.id); return }
        let target = fileDestination
        fileDestination = nil
        if let drop = appDrop, mouse.isReceivingDrop(offer.id),
           drop.id == offer.id, drop.name == offer.name, Date().timeIntervalSince(drop.date) < 5 {
            do { files.accept(id: offer.id, destination: try drop.stage()) }
            catch { files.decline(id: offer.id); fileLabel.stringValue = error.localizedDescription }
            return
        }
        appDrop = nil
        let finder = target.flatMap { mouse.isReceivingDrop(offer.id) && $0.id == offer.id && $0.name == offer.name && Date().timeIntervalSince($0.date) < 5 ? $0 : nil }
        if lastFileDropID == offer.id, finder == nil {
            files.decline(id: offer.id)
            fileLabel.stringValue = ui("Drop over a file attachment field or a Finder folder.")
            return
        }
        let folder = finder?.folder
        if let folder, let name = offer.name, let approved = finder?.directory ?? approvedDropDirectory, approved.matches(folder) {
            directDrop = true
            files.accept(id: offer.id, destination: folder.appendingPathComponent(name), directory: approved, keepBoth: true)
            return
        }
        let connection = featurePeer?.connection
        mouse.suspend(.fileApproval); showSharing()
        let panel = NSSavePanel(); panel.title = ui("Receive File"); panel.nameFieldStringValue = offer.name ?? ui("File")
        let remember = NSButton(checkboxWithTitle: ui("Allow drops into this folder until disconnect"), target: nil, action: nil)
        if let folder { panel.directoryURL = folder; panel.accessoryView = remember }
        panel.message = ui("From %1$@ · ", "\(featurePeer?.name ?? ui("other Mac"))") + ByteCountFormatter.string(fromByteCount: offer.size ?? 0, countStyle: .file) + ui("\nChoose where to save the file to start the transfer. Existing files are protected.")
        panel.prompt = ui("Receive"); panel.canCreateDirectories = true; receivePanel = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }; self.receivePanel = nil
            defer { self.mouse.resume(.fileApproval) }
            if response == .OK, let url = panel.url, self.enabled, self.featurePeer?.connection == connection, self.files.activeID == offer.id {
                if folder != nil, remember.state == .on { self.approvedDropDirectory = try? ReceiveDirectory(url.deletingLastPathComponent()) }
                self.files.accept(id: offer.id, destination: url)
            }
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
