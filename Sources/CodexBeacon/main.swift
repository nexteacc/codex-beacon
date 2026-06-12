import AppKit
import Foundation
import Network
import ObjectiveC

struct BeaconConfig: Codable, Equatable {
    var touchBarVisual: Bool
    var sound: Bool
    var activePreset: String?
    var authToken: String?

    static let `default` = BeaconConfig(touchBarVisual: true, sound: true, activePreset: "default", authToken: nil)

    var presetName: String {
        activePreset?.isEmpty == false ? activePreset! : "default"
    }
}

final class ConfigStore {
    let directoryURL: URL
    private let fileURL: URL
    private(set) var config: BeaconConfig

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("Codex Beacon", isDirectory: true)
        directoryURL = directory
        fileURL = directory.appendingPathComponent("config.json")

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                config = try JSONDecoder().decode(BeaconConfig.self, from: data)
                if config.activePreset == nil {
                    config.activePreset = "default"
                    try? save()
                }
                if config.authToken == nil {
                    config.authToken = Self.makeToken()
                    try? save()
                }
            } else {
                config = .default
                config.authToken = Self.makeToken()
                try save()
            }
        } catch {
            config = .default
            NSLog("Codex Beacon config error: \(error.localizedDescription)")
        }
    }

    func setTouchBarVisual(_ enabled: Bool) {
        config.touchBarVisual = enabled
        try? save()
    }

    func setSound(_ enabled: Bool) {
        config.sound = enabled
        try? save()
    }

    func reload() {
        guard let data = try? Data(contentsOf: fileURL),
              let nextConfig = try? JSONDecoder().decode(BeaconConfig.self, from: data) else {
            return
        }
        config = nextConfig
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func makeToken() -> String {
        let bytes = (0..<24).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

enum BeaconState: String, CaseIterable {
    case idle
    case needsYou
    case done
}

struct BeaconStateStyle: Codable, Equatable {
    var text: String
    var menuIcon: String?
    var background: String
    var foreground: String?
    var sound: String?

    var backgroundColor: NSColor {
        NSColor(hex: background) ?? NSColor(calibratedRed: 0.18, green: 0.18, blue: 0.20, alpha: 1.0)
    }

    var foregroundColor: NSColor {
        guard let foreground else { return .white }
        return NSColor(hex: foreground) ?? .white
    }

    var resolvedMenuIcon: String {
        menuIcon ?? String(text.prefix(1))
    }
}

struct BeaconPreset: Codable, Equatable {
    var name: String
    var states: [String: BeaconStateStyle]

    func style(for state: BeaconState) -> BeaconStateStyle {
        states[state.rawValue] ?? Self.default.states[state.rawValue]!
    }

    static let `default` = BeaconPreset(
        name: "Default",
        states: [
            BeaconState.idle.rawValue: BeaconStateStyle(
                text: "☕ Codex",
                menuIcon: "☕",
                background: "#4A3021",
                foreground: "#FFFFFF",
                sound: nil
            ),
            BeaconState.needsYou.rawValue: BeaconStateStyle(
                text: "🫶 Needs You",
                menuIcon: "🫶",
                background: "#B03646",
                foreground: "#FFFFFF",
                sound: "Submarine"
            ),
            BeaconState.done.rawValue: BeaconStateStyle(
                text: "❤️ Done",
                menuIcon: "❤️",
                background: "#3F8F68",
                foreground: "#FFFFFF",
                sound: "Ping"
            )
        ]
    )
}

final class PresetStore {
    private let presetsDirectory: URL
    private(set) var preset: BeaconPreset = .default

    init(appSupportDirectory: URL) {
        presetsDirectory = appSupportDirectory.appendingPathComponent("Presets", isDirectory: true)
        prepareDefaults()
    }

    func reload(activePresetName: String) {
        prepareDefaults()

        let fileName = activePresetName.hasSuffix(".json") ? activePresetName : "\(activePresetName).json"
        let fileURL = presetsDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL),
              let nextPreset = try? JSONDecoder().decode(BeaconPreset.self, from: data) else {
            preset = .default
            return
        }
        preset = nextPreset
    }

    private func prepareDefaults() {
        do {
            try FileManager.default.createDirectory(at: presetsDirectory, withIntermediateDirectories: true)
            let destination = presetsDirectory.appendingPathComponent("default.json")
            guard !FileManager.default.fileExists(atPath: destination.path) else { return }

            if let bundled = Bundle.main.url(forResource: "default", withExtension: "json", subdirectory: "Presets") {
                try FileManager.default.copyItem(at: bundled, to: destination)
            } else {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(BeaconPreset.default).write(to: destination, options: .atomic)
            }
        } catch {
            NSLog("Codex Beacon preset error: \(error.localizedDescription)")
        }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines))
        guard cleaned.count == 6 || cleaned.count == 8,
              let value = UInt64(cleaned, radix: 16) else {
            return nil
        }

        let hasAlpha = cleaned.count == 8
        let red = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255.0
        let green = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255.0
        let blue = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255.0
        let alpha = hasAlpha ? CGFloat(value & 0xFF) / 255.0 : 1.0
        self.init(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }
}

final class SettingsViewController: NSViewController {
    private let configStore: ConfigStore
    private let onChange: () -> Void
    private let touchBarSwitch = NSSwitch()
    private let soundSwitch = NSSwitch()

    init(configStore: ConfigStore, onChange: @escaping () -> Void) {
        self.configStore = configStore
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 168))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = NSTextField(labelWithString: "Codex Beacon")
        title.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        let touchBarRow = row(title: "Touch Bar", control: touchBarSwitch)
        let soundRow = row(title: "Sound", control: soundSwitch)

        let stack = NSStackView(views: [title, touchBarRow, soundRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        touchBarSwitch.target = self
        touchBarSwitch.action = #selector(touchBarChanged)
        soundSwitch.target = self
        soundSwitch.action = #selector(soundChanged)

        self.view = root
        refresh()
    }

    func refresh() {
        touchBarSwitch.state = configStore.config.touchBarVisual ? .on : .off
        soundSwitch.state = configStore.config.sound ? .on : .off
    }

    private func row(title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 15, weight: .medium)

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .gravityAreas
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 264).isActive = true
        return row
    }

    @objc private func touchBarChanged() {
        configStore.setTouchBarVisual(touchBarSwitch.state == .on)
        onChange()
    }

    @objc private func soundChanged() {
        configStore.setSound(soundSwitch.state == .on)
        onChange()
    }
}

final class TouchBarBeacon: NSObject, NSTouchBarDelegate {
    private let trayIdentifier = NSTouchBarItem.Identifier("codex.beacon.native.tray")
    private let modalIdentifier = NSTouchBarItem.Identifier("codex.beacon.native.modal")
    private let trayItem: NSCustomTouchBarItem
    private let modalItem: NSCustomTouchBarItem
    private let modalTouchBar: NSTouchBar
    private var style = BeaconPreset.default.style(for: .idle)
    private var installed = false
    private let onTap: () -> Void

    init(onTap: @escaping () -> Void) {
        trayItem = NSCustomTouchBarItem(identifier: trayIdentifier)
        modalItem = NSCustomTouchBarItem(identifier: modalIdentifier)
        modalTouchBar = NSTouchBar()
        self.onTap = onTap
        super.init()
        modalTouchBar.delegate = self
        modalTouchBar.defaultItemIdentifiers = [modalIdentifier]
        modalTouchBar.principalItemIdentifier = modalIdentifier
        updateViews()
    }

    func install() {
        guard !installed else { return }
        installed = true

        let itemClass: AnyObject = NSTouchBarItem.self
        let addSelector = NSSelectorFromString("addSystemTrayItem:")
        if itemClass.responds(to: addSelector) {
            _ = itemClass.perform(addSelector, with: trayItem)
        } else {
            NSLog("NSTouchBarItem.addSystemTrayItem: unavailable")
        }

        setControlStripPresence(true)
        setSystemModalCloseBoxVisible(false)
    }

    func setEnabled(_ enabled: Bool) {
        setControlStripPresence(enabled)
        if enabled {
            present()
        } else {
            minimize()
        }
    }

    func setStyle(_ nextStyle: BeaconStateStyle) {
        style = nextStyle
        updateViews()
    }

    func present() {
        let touchBarClass: AnyObject = NSTouchBar.self
        let placementSelector = NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
        let modernSelector = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
        let legacyPlacementSelector = NSSelectorFromString("presentSystemModalFunctionBar:placement:systemTrayItemIdentifier:")
        let legacySelector = NSSelectorFromString("presentSystemModalFunctionBar:systemTrayItemIdentifier:")

        if callSystemModalPlacement(selector: placementSelector) {
            return
        }
        if touchBarClass.responds(to: modernSelector) {
            _ = touchBarClass.perform(modernSelector, with: modalTouchBar, with: trayIdentifier.rawValue)
        } else if callSystemModalPlacement(selector: legacyPlacementSelector) {
            return
        } else if touchBarClass.responds(to: legacySelector) {
            _ = touchBarClass.perform(legacySelector, with: modalTouchBar, with: trayIdentifier.rawValue)
        } else {
            NSLog("NSTouchBar system modal presentation API unavailable")
        }
    }

    func minimize() {
        let touchBarClass: AnyObject = NSTouchBar.self
        let modernSelector = NSSelectorFromString("minimizeSystemModalTouchBar:")
        let legacySelector = NSSelectorFromString("minimizeSystemModalFunctionBar:")

        if touchBarClass.responds(to: modernSelector) {
            _ = touchBarClass.perform(modernSelector, with: modalTouchBar)
        } else if touchBarClass.responds(to: legacySelector) {
            _ = touchBarClass.perform(legacySelector, with: modalTouchBar)
        }
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == modalIdentifier else { return nil }
        return modalItem
    }

    private func updateViews() {
        trayItem.view = statusView(style: style, width: 120, height: 30, fontSize: 13)
        modalItem.view = fullTouchBarView(style: style)
    }

    private func callSystemModalPlacement(selector: Selector) -> Bool {
        guard let method = class_getClassMethod(NSTouchBar.self, selector) else {
            return false
        }

        typealias Function = @convention(c) (AnyObject, Selector, NSTouchBar, Int64, NSString) -> Void
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        function(NSTouchBar.self, selector, modalTouchBar, 1, trayIdentifier.rawValue as NSString)
        return true
    }

    private func setControlStripPresence(_ present: Bool) {
        guard let symbol = privateSymbol("DFRElementSetControlStripPresenceForIdentifier") else {
            NSLog("DFRElementSetControlStripPresenceForIdentifier unavailable")
            return
        }

        typealias PresenceFunction = @convention(c) (CFString, Bool) -> Void
        let function = unsafeBitCast(symbol, to: PresenceFunction.self)
        function(trayIdentifier.rawValue as CFString, present)
    }

    private func setSystemModalCloseBoxVisible(_ visible: Bool) {
        guard let symbol = privateSymbol("DFRSystemModalShowsCloseBoxWhenFrontMost") else {
            NSLog("DFRSystemModalShowsCloseBoxWhenFrontMost unavailable")
            return
        }

        typealias CloseBoxFunction = @convention(c) (Bool) -> Void
        let function = unsafeBitCast(symbol, to: CloseBoxFunction.self)
        function(visible)
    }

    private func privateSymbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW) else {
            return nil
        }
        return dlsym(handle, name)
    }

    private func fullTouchBarView(style: BeaconStateStyle) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 980, height: 36))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.04).cgColor

        let status = statusView(style: style, width: 300, height: 32, fontSize: 17)
        status.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(status)

        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            status.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            status.widthAnchor.constraint(equalToConstant: 300),
            status.heightAnchor.constraint(equalToConstant: 32)
        ])

        return container
    }

    private func statusView(style: BeaconStateStyle, width: CGFloat, height: CGFloat, fontSize: CGFloat) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = style.backgroundColor.cgColor
        container.layer?.cornerRadius = 9
        container.toolTip = "Open Codex"

        let button = NSButton(title: "", target: self, action: #selector(openCodex))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.setButtonType(.momentaryPushIn)
        button.wantsLayer = true
        button.layer?.backgroundColor = style.backgroundColor.cgColor
        button.layer?.cornerRadius = 9
        button.toolTip = "Open Codex"
        button.attributedTitle = NSAttributedString(
            string: style.text,
            attributes: [
                .foregroundColor: style.foregroundColor,
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            ]
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

    @objc private func openCodex() {
        NSLog("Codex Beacon Touch Bar item tapped")
        onTap()
    }
}

final class BeaconServer {
    private let listener: NWListener
    private let tokenProvider: () -> String?
    private let onEvent: (BeaconState) -> Void

    init(port: UInt16, tokenProvider: @escaping () -> String?, onEvent: @escaping (BeaconState) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(IPv4Address("127.0.0.1")!),
            port: NWEndpoint.Port(rawValue: port)!
        )
        listener = try NWListener(using: parameters)
        self.tokenProvider = tokenProvider
        self.onEvent = onEvent
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            self?.receive(on: connection)
        }
        listener.start(queue: .main)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let response: String
            if let state = self.state(from: request) {
                DispatchQueue.main.async {
                    self.onEvent(state)
                }
                response = Self.response(status: "200 OK", body: "ok\n")
            } else {
                response = Self.response(status: "404 Not Found", body: "not found\n")
            }

            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func state(from request: String) -> BeaconState? {
        guard let requestLine = request.components(separatedBy: "\r\n").first,
              requestLine.hasPrefix("GET /event?") else {
            return nil
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2,
              let url = URL(string: "http://127.0.0.1\(parts[1])"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if query[item.name] == nil {
                query[item.name] = item.value
            }
        }

        guard let expectedToken = tokenProvider(),
              query["token"] == expectedToken else {
            return nil
        }

        if query["type"] == "permission_request" || query["type"] == "needs_you" {
            return .needsYou
        }
        if query["type"] == "turn_done" || query["type"] == "done" {
            return .done
        }
        return nil
    }

    private static func response(status: String, body: String) -> String {
        """
        HTTP/1.1 \(status)\r
        Content-Type: text/plain\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configStore = ConfigStore()
    private lazy var presetStore = PresetStore(appSupportDirectory: configStore.directoryURL)
    private lazy var touchBarBeacon = TouchBarBeacon { [weak self] in
        self?.activateCodex()
    }
    private var settingsController: SettingsViewController?
    private var window: NSWindow?
    private var server: BeaconServer?
    private var resetWorkItem: DispatchWorkItem?
    private var statusItem: NSStatusItem?
    private var touchBarMenuItem: NSMenuItem?
    private var soundMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupWindow()
        setupMenuBar()
        setupServer()
        touchBarBeacon.install()
        applyConfig()
        showSettings()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    private func setupWindow() {
        let controller = SettingsViewController(configStore: configStore) { [weak self] in
            self?.applyConfig()
        }
        settingsController = controller

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 168),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Beacon"
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.center()
        self.window = window
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "☕"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show", action: #selector(showSettings), keyEquivalent: ""))

        let touchBar = NSMenuItem(title: "Touch Bar", action: #selector(toggleTouchBar), keyEquivalent: "")
        let sound = NSMenuItem(title: "Sound", action: #selector(toggleSound), keyEquivalent: "")
        touchBarMenuItem = touchBar
        soundMenuItem = sound
        menu.addItem(touchBar)
        menu.addItem(sound)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
        refreshMenu()
    }

    private func setupServer() {
        do {
            server = try BeaconServer(port: 17321, tokenProvider: { [weak self] in
                self?.configStore.reload()
                return self?.configStore.config.authToken
            }) { [weak self] state in
                self?.display(state)
            }
            server?.start()
        } catch {
            NSLog("Codex Beacon server error: \(error.localizedDescription)")
        }
    }

    private func applyConfig() {
        configStore.reload()
        presetStore.reload(activePresetName: configStore.config.presetName)
        settingsController?.refresh()
        refreshMenu()
        touchBarBeacon.setStyle(presetStore.preset.style(for: .idle))
        touchBarBeacon.setEnabled(configStore.config.touchBarVisual)
        statusItem?.button?.title = presetStore.preset.style(for: .idle).resolvedMenuIcon
    }

    private func refreshMenu() {
        touchBarMenuItem?.state = configStore.config.touchBarVisual ? .on : .off
        soundMenuItem?.state = configStore.config.sound ? .on : .off
    }

    private func display(_ state: BeaconState) {
        configStore.reload()
        presetStore.reload(activePresetName: configStore.config.presetName)
        refreshMenu()
        resetWorkItem?.cancel()
        let style = presetStore.preset.style(for: state)

        if configStore.config.touchBarVisual {
            touchBarBeacon.setStyle(style)
            touchBarBeacon.present()
        }

        if configStore.config.sound, state != .idle, let sound = style.sound {
            NSSound(named: NSSound.Name(sound))?.play()
        }

        statusItem?.button?.title = style.resolvedMenuIcon

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.configStore.reload()
            self.presetStore.reload(activePresetName: self.configStore.config.presetName)
            let idleStyle = self.presetStore.preset.style(for: .idle)
            self.touchBarBeacon.setStyle(idleStyle)
            if self.configStore.config.touchBarVisual {
                self.touchBarBeacon.present()
            }
            self.statusItem?.button?.title = idleStyle.resolvedMenuIcon
        }
        resetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    @objc private func showSettings() {
        if window == nil {
            setupWindow()
        }

        revealSettingsWindow()
        DispatchQueue.main.async { [weak self] in
            self?.revealSettingsWindow()
        }
    }

    private func revealSettingsWindow() {
        guard let window else { return }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func activateCodex() {
        let candidates = ["Codex", "iTerm2", "Terminal"]
        let apps = NSWorkspace.shared.runningApplications

        for name in candidates {
            if let app = apps.first(where: { runningApp in
                runningApp.localizedName == name && runningApp.bundleIdentifier != Bundle.main.bundleIdentifier
            }) {
                app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                return
            }
        }
    }

    @objc private func toggleTouchBar() {
        configStore.setTouchBarVisual(!configStore.config.touchBarVisual)
        applyConfig()
    }

    @objc private func toggleSound() {
        configStore.setSound(!configStore.config.sound)
        applyConfig()
    }

    @objc private func quit() {
        touchBarBeacon.minimize()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
