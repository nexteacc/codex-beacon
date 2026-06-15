import AppKit
import Foundation
import Network
import ObjectiveC

struct BeaconConfig: Codable, Equatable {
    var touchBarVisual: Bool
    var sound: Bool
    var activePreset: String?
    var authToken: String?
    var usageWindow: UsageWindowSelection?

    static let `default` = BeaconConfig(
        touchBarVisual: true,
        sound: true,
        activePreset: "default",
        authToken: nil,
        usageWindow: .fiveHour
    )

    var presetName: String {
        activePreset?.isEmpty == false ? activePreset! : "default"
    }

    var selectedUsageWindow: UsageWindowSelection {
        usageWindow ?? .fiveHour
    }
}

enum UsageWindowSelection: String, Codable, Equatable, CaseIterable {
    case fiveHour
    case weekly
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
            try Self.secureDirectory(directory)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                config = try JSONDecoder().decode(BeaconConfig.self, from: data)
                try? Self.secureFile(fileURL)
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

    func setUsageWindow(_ selection: UsageWindowSelection) {
        config.usageWindow = selection
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
        try Self.secureDirectory(directoryURL)
        try Self.secureFile(fileURL)
    }

    private static func makeToken() -> String {
        let bytes = (0..<24).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func secureDirectory(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func secureFile(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum HookInstallState: Equatable {
    case installed
    case missing
    case moveToApplications
    case invalid(String)

    var label: String {
        switch self {
        case .installed:
            return "Installed"
        case .missing:
            return "Not Installed"
        case .moveToApplications:
            return "Move to Applications"
        case .invalid:
            return "Needs Repair"
        }
    }

    var canInstall: Bool {
        switch self {
        case .installed:
            return false
        case .missing, .moveToApplications, .invalid:
            return true
        }
    }

    var detail: String {
        switch self {
        case .installed:
            return "Hooks installed"
        case .missing:
            return "Hooks not installed"
        case .moveToApplications:
            return "Move Codex Beacon to Applications first."
        case .invalid(let message):
            return message
        }
    }
}

final class HookInstaller {
    private let hooksURL: URL
    private let helperURL: URL
    private let expectedAppPath = "/Applications/Codex Beacon.app"

    private let ownedFragments = [
        "codex-beacon-native/notify.sh",
        "Codex Beacon.app/Contents/Resources/helper/notify.sh",
        "codex-beacon/run.sh",
        "codex-mac-attention"
    ]
    private let staleFragments = [
        "codex-beacon-native/notify.sh",
        "codex-beacon/run.sh",
        "codex-mac-attention"
    ]

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        hooksURL = home.appendingPathComponent(".codex/hooks.json")
        helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/helper/notify.sh")
    }

    var isRunningFromApplications: Bool {
        Bundle.main.bundleURL.path == expectedAppPath
    }

    func state() -> HookInstallState {
        guard isRunningFromApplications else {
            return .moveToApplications
        }
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            return .invalid("Helper missing")
        }
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            return .invalid("Helper not executable")
        }
        do {
            let root = try readRoot()
            return hookState(in: root)
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    func install() throws {
        guard isRunningFromApplications else {
            throw NSError(
                domain: "CodexBeacon.Hooks",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Move Codex Beacon to Applications first."]
            )
        }

        let directory = hooksURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: hooksURL.path) {
            try backupHooks()
        }

        let root: [String: Any]
        do {
            root = try readRoot()
        } catch {
            root = ["hooks": [:]]
        }
        var nextRoot = root
        var hooks = nextRoot["hooks"] as? [String: Any] ?? [:]
        hooks["PermissionRequest"] = cleanHooks(hooks["PermissionRequest"] as? [[String: Any]] ?? [])
        hooks["Stop"] = cleanHooks(hooks["Stop"] as? [[String: Any]] ?? [])

        var permissionItems = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        permissionItems.append([
            "matcher": "*",
            "hooks": [[
                "type": "command",
                "command": "\(shellQuoted(helperURL.path)) permission_request",
                "timeout": 3,
                "statusMessage": "Signaling Codex Beacon"
            ]]
        ])
        hooks["PermissionRequest"] = permissionItems

        var stopItems = hooks["Stop"] as? [[String: Any]] ?? []
        stopItems.append([
            "hooks": [[
                "type": "command",
                "command": "\(shellQuoted(helperURL.path)) turn_done",
                "timeout": 3,
                "statusMessage": "Signaling Codex Beacon"
            ]]
        ])
        hooks["Stop"] = stopItems

        nextRoot["hooks"] = hooks
        try writeRoot(nextRoot)
    }

    private func readRoot() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: hooksURL.path) else {
            return ["hooks": [:]]
        }
        let data = try Data(contentsOf: hooksURL)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            return ["hooks": [:]]
        }
        return root
    }

    private func writeRoot(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        var output = data
        output.append(0x0A)
        try output.write(to: hooksURL, options: .atomic)
    }

    private func backupHooks() throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = formatter.string(from: Date())
        let backupURL = hooksURL.deletingLastPathComponent()
            .appendingPathComponent("hooks.json.codex-beacon-\(suffix).backup")
        try FileManager.default.copyItem(at: hooksURL, to: backupURL)
    }

    private func hookState(in root: [String: Any]) -> HookInstallState {
        guard let hooks = root["hooks"] as? [String: Any] else {
            return .missing
        }

        let permissionCount = helperCommandCount(in: hooks["PermissionRequest"], event: "permission_request")
        let stopCount = helperCommandCount(in: hooks["Stop"], event: "turn_done")

        if hasStaleOwnedHooks(in: hooks) {
            return .invalid("Old hooks found")
        }
        if permissionCount == 1 && stopCount == 1 {
            return .installed
        }
        if permissionCount == 0 && stopCount == 0 {
            return .missing
        }
        return .invalid("Hooks need repair")
    }

    private func helperCommandCount(in value: Any?, event: String) -> Int {
        guard let items = value as? [[String: Any]] else { return 0 }
        return items.reduce(0) { count, entry in
            guard let hooks = entry["hooks"] as? [[String: Any]] else { return count }
            let matches = hooks.filter { hook in
                guard let command = hook["command"] as? String else { return false }
                return command.contains(helperURL.path) && command.contains(event)
            }
            return count + matches.count
        }
    }

    private func hasStaleOwnedHooks(in hooks: [String: Any]) -> Bool {
        for value in hooks.values {
            guard let items = value as? [[String: Any]] else { continue }
            for entry in items {
                guard let hookItems = entry["hooks"] as? [[String: Any]] else { continue }
                for hook in hookItems {
                    guard let command = hook["command"] as? String else { continue }
                    if staleFragments.contains(where: { command.contains($0) }) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func cleanHooks(_ items: [[String: Any]]) -> [[String: Any]] {
        items.compactMap { entry in
            guard let hookItems = entry["hooks"] as? [[String: Any]] else {
                return entry
            }
            let nextHooks = hookItems.filter { hook in
                guard let command = hook["command"] as? String else { return true }
                return !ownedFragments.contains { command.contains($0) }
            }
            guard !nextHooks.isEmpty else { return nil }
            var nextEntry = entry
            nextEntry["hooks"] = nextHooks
            return nextEntry
        }
    }

    private func shellQuoted(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

enum BeaconState: String, CaseIterable {
    case idle
    case needsYou
    case done
}

struct BeaconReturnTarget {
    let processIdentifier: pid_t?
    let bundleIdentifier: String?

    var isEmpty: Bool {
        processIdentifier == nil && bundleIdentifier == nil
    }
}

struct BeaconEvent {
    let state: BeaconState
    let returnTarget: BeaconReturnTarget
}

struct CodexUsageWindow: Codable {
    let label: String
    let usedPercent: Double
    let remainingPercent: Double
    let windowMinutes: Int
    let resetsAt: Int
    let resetsAtLocal: String
    let resetInSeconds: Int
}

struct CodexUsageSnapshot: Codable {
    let ok: Bool
    let updatedAt: String
    let planType: String?
    let primary: CodexUsageWindow
    let secondary: CodexUsageWindow?

    func displayText(for selection: UsageWindowSelection) -> String? {
        let window: CodexUsageWindow?
        switch selection {
        case .fiveHour:
            window = primary
        case .weekly:
            window = secondary
        }
        guard let window else { return nil }
        return "\(window.label) \(Int(window.remainingPercent.rounded()))%"
    }
}

final class CodexUsageReader {
    private let sessionsDirectory: URL
    private let maxFiles = 24
    private let maxTailBytes: UInt64 = 1_048_576

    init() {
        sessionsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    func latestSnapshot() -> CodexUsageSnapshot? {
        for fileURL in recentSessionFiles() {
            guard let line = latestRateLimitLine(in: fileURL),
                  let snapshot = snapshot(from: line) else {
                continue
            }
            return snapshot
        }
        return nil
    }

    private func recentSessionFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [(url: URL, modifiedAt: Date)] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            files.append((fileURL, values.contentModificationDate ?? .distantPast))
        }

        return files
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maxFiles)
            .map(\.url)
    }

    private func latestRateLimitLine(in fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer {
            try? handle.close()
        }

        do {
            let size = try handle.seekToEnd()
            let offset = size > maxTailBytes ? size - maxTailBytes : 0
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            return text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .reversed()
                .first { $0.contains(#""rate_limits""#) }
                .map(String.init)
        } catch {
            return nil
        }
    }

    private func snapshot(from line: String) -> CodexUsageSnapshot? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["payload"] as? [String: Any],
              let rateLimits = payload["rate_limits"] as? [String: Any],
              let primaryObject = rateLimits["primary"] as? [String: Any],
              let primary = window(from: primaryObject, fallbackLabel: "5h") else {
            return nil
        }

        let secondary = (rateLimits["secondary"] as? [String: Any]).flatMap {
            window(from: $0, fallbackLabel: "Weekly")
        }
        let updatedAt = root["timestamp"] as? String ?? isoString(Date())

        return CodexUsageSnapshot(
            ok: true,
            updatedAt: updatedAt,
            planType: rateLimits["plan_type"] as? String,
            primary: primary,
            secondary: secondary
        )
    }

    private func window(from object: [String: Any], fallbackLabel: String) -> CodexUsageWindow? {
        guard let usedPercent = doubleValue(object["used_percent"]),
              let windowMinutes = intValue(object["window_minutes"]),
              let resetsAt = intValue(object["resets_at"]) else {
            return nil
        }

        let remainingPercent = max(0, min(100, 100 - usedPercent))
        let resetDate = Date(timeIntervalSince1970: TimeInterval(resetsAt))
        let resetInSeconds = max(0, Int(resetDate.timeIntervalSinceNow.rounded()))
        return CodexUsageWindow(
            label: label(forWindowMinutes: windowMinutes, fallback: fallbackLabel),
            usedPercent: usedPercent,
            remainingPercent: remainingPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetsAtLocal: isoString(resetDate),
            resetInSeconds: resetInSeconds
        )
    }

    private func label(forWindowMinutes minutes: Int, fallback: String) -> String {
        if minutes == 300 {
            return "5h"
        }
        if minutes == 10_080 {
            return "Weekly"
        }
        if minutes % 1_440 == 0 {
            return "\(minutes / 1_440)d"
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60)h"
        }
        return fallback
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
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

final class StatusDotView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: 8, height: 8)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setColor(_ color: NSColor, tooltip: String) {
        layer?.backgroundColor = color.cgColor
        toolTip = tooltip
    }
}

final class BeaconToggle: NSControl {
    private let trackLayer = CALayer()
    private let knobLayer = CALayer()
    var isOn: Bool = true {
        didSet {
            needsLayout = true
            updateLayerColors()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 44, height: 24)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        focusRingType = .none
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(knobLayer)
        knobLayer.shadowColor = NSColor.black.cgColor
        knobLayer.shadowOpacity = 0.16
        knobLayer.shadowOffset = NSSize(width: 0, height: 1)
        knobLayer.shadowRadius = 2
        updateLayerColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let trackFrame = bounds.insetBy(dx: 0, dy: 1)
        trackLayer.frame = trackFrame
        trackLayer.cornerRadius = trackFrame.height / 2

        let knobSize = trackFrame.height - 4
        let knobX = isOn ? trackFrame.maxX - knobSize - 2 : trackFrame.minX + 2
        knobLayer.frame = NSRect(x: knobX, y: trackFrame.minY + 2, width: knobSize, height: knobSize)
        knobLayer.cornerRadius = knobSize / 2
        knobLayer.shadowPath = CGPath(ellipseIn: knobLayer.bounds, transform: nil)

        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        sendAction(action, to: target)
    }

    private func updateLayerColors() {
        trackLayer.backgroundColor = (isOn ? NSColor.systemGreen : NSColor.controlColor).cgColor
        knobLayer.backgroundColor = NSColor.white.cgColor
    }
}

final class SettingsViewController: NSViewController {
    private let configStore: ConfigStore
    private let hookInstaller: HookInstaller
    private let onChange: () -> Void
    private let touchBarSwitch = BeaconToggle()
    private let soundSwitch = BeaconToggle()
    private let usageControl = NSSegmentedControl(labels: ["5h", "Weekly"], trackingMode: .selectOne, target: nil, action: nil)
    private let hooksButton = NSButton(title: "Install Hooks", target: nil, action: nil)
    private let serverDot = StatusDotView()
    private var isServerReady = false

    init(configStore: ConfigStore, hookInstaller: HookInstaller, isServerReady: Bool, onChange: @escaping () -> Void) {
        self.configStore = configStore
        self.hookInstaller = hookInstaller
        self.isServerReady = isServerReady
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 176))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let touchBarRow = row(title: "Touch Bar", control: touchBarSwitch)
        let soundRow = row(title: "Sound", control: soundSwitch)
        let usageRow = row(title: "Usage", control: usageControl)
        let hooksRow = hookRow()

        usageControl.segmentStyle = .rounded
        usageControl.controlSize = .small
        usageControl.setWidth(56, forSegment: 0)
        usageControl.setWidth(78, forSegment: 1)

        let stack = NSStackView(views: [touchBarRow, soundRow, usageRow, hooksRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        serverDot.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(serverDot)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            serverDot.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            serverDot.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            serverDot.widthAnchor.constraint(equalToConstant: 8),
            serverDot.heightAnchor.constraint(equalToConstant: 8)
        ])

        touchBarSwitch.target = self
        touchBarSwitch.action = #selector(touchBarChanged)
        soundSwitch.target = self
        soundSwitch.action = #selector(soundChanged)
        usageControl.target = self
        usageControl.action = #selector(usageChanged)
        hooksButton.target = self
        hooksButton.action = #selector(installHooks)

        self.view = root
        refresh()
    }

    func refresh() {
        touchBarSwitch.isOn = configStore.config.touchBarVisual
        soundSwitch.isOn = configStore.config.sound
        usageControl.selectedSegment = configStore.config.selectedUsageWindow == .fiveHour ? 0 : 1
        serverDot.setColor(isServerReady ? .systemGreen : .systemRed, tooltip: isServerReady ? "Ready" : "Port busy")
        refreshHooks()
    }

    func setServerReady(_ ready: Bool) {
        isServerReady = ready
        refresh()
    }

    private func row(title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .gravityAreas
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 252).isActive = true
        label.widthAnchor.constraint(equalToConstant: 92).isActive = true
        return row
    }

    private func hookRow() -> NSView {
        let label = NSTextField(labelWithString: "Hooks")
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        hooksButton.bezelStyle = .rounded
        hooksButton.controlSize = .small
        hooksButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [label, spacer, hooksButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 252).isActive = true
        label.widthAnchor.constraint(equalToConstant: 92).isActive = true
        hooksButton.widthAnchor.constraint(equalToConstant: 76).isActive = true
        return row
    }

    private func refreshHooks() {
        let state = hookInstaller.state()
        switch state {
        case .installed:
            hooksButton.title = "Repair"
            hooksButton.toolTip = state.detail
            hooksButton.isEnabled = true
        case .invalid:
            hooksButton.title = "Repair"
            hooksButton.toolTip = state.detail
            hooksButton.isEnabled = true
        case .moveToApplications:
            hooksButton.title = "Move App"
            hooksButton.toolTip = state.detail
            hooksButton.isEnabled = true
        case .missing:
            hooksButton.title = "Install"
            hooksButton.toolTip = state.detail
            hooksButton.isEnabled = state.canInstall
        }
    }

    @objc private func touchBarChanged() {
        configStore.setTouchBarVisual(touchBarSwitch.isOn)
        onChange()
    }

    @objc private func soundChanged() {
        configStore.setSound(soundSwitch.isOn)
        onChange()
    }

    @objc private func usageChanged() {
        let selection: UsageWindowSelection = usageControl.selectedSegment == 1 ? .weekly : .fiveHour
        configStore.setUsageWindow(selection)
        onChange()
    }

    @objc private func installHooks() {
        do {
            try hookInstaller.install()
            refreshHooks()
            showAlert(title: "Hooks Ready", message: "Restart Codex and trust hooks.")
        } catch {
            refreshHooks()
            showAlert(title: "Setup Needed", message: error.localizedDescription)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let window = view.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }
}

final class TouchBarBeacon: NSObject, NSTouchBarDelegate {
    private let trayIdentifier = NSTouchBarItem.Identifier("codex.beacon.native.tray")
    private let modalIdentifier = NSTouchBarItem.Identifier("codex.beacon.native.modal")
    private let trayItem: NSCustomTouchBarItem
    private let modalItem: NSCustomTouchBarItem
    private let modalTouchBar: NSTouchBar
    private var style = BeaconPreset.default.style(for: .idle)
    private var usageText: String?
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

    func setUsageText(_ text: String?) {
        usageText = text
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
        modalItem.view = fullTouchBarView(style: style, usageText: usageText)
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

    private func fullTouchBarView(style: BeaconStateStyle, usageText: String?) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 980, height: 36))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.04).cgColor

        let statusWidth: CGFloat = usageText == nil ? 300 : 150
        let status = statusView(style: style, width: statusWidth, height: 32, fontSize: 17)
        status.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(status)

        var constraints = [
            status.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            status.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            status.widthAnchor.constraint(equalToConstant: statusWidth),
            status.heightAnchor.constraint(equalToConstant: 32)
        ]

        if let usageText {
            let usage = usageView(text: usageText, width: 132, height: 32, fontSize: 16)
            usage.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(usage)
            constraints.append(contentsOf: [
                usage.leadingAnchor.constraint(equalTo: status.trailingAnchor, constant: 8),
                usage.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                usage.widthAnchor.constraint(equalToConstant: 132),
                usage.heightAnchor.constraint(equalToConstant: 32)
            ])
        }

        NSLayoutConstraint.activate(constraints)

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

    private func usageView(text: String, width: CGFloat, height: CGFloat, fontSize: CGFloat) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedRed: 0.15, green: 0.16, blue: 0.17, alpha: 1.0).cgColor
        container.layer?.cornerRadius = 9
        container.toolTip = "Codex usage"

        let label = NSTextField(labelWithString: text)
        label.alignment = .center
        label.textColor = .white
        label.font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
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
    private let usageProvider: () -> CodexUsageSnapshot?
    private let onEvent: (BeaconEvent) -> Void

    init(
        port: UInt16,
        tokenProvider: @escaping () -> String?,
        usageProvider: @escaping () -> CodexUsageSnapshot?,
        onEvent: @escaping (BeaconEvent) -> Void
    ) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(IPv4Address("127.0.0.1")!),
            port: NWEndpoint.Port(rawValue: port)!
        )
        listener = try NWListener(using: parameters)
        self.tokenProvider = tokenProvider
        self.usageProvider = usageProvider
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
            if let usageResponse = self.usage(from: request) {
                response = usageResponse
            } else if let event = self.event(from: request) {
                DispatchQueue.main.async {
                    self.onEvent(event)
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

    private func usage(from request: String) -> String? {
        guard let query = query(from: request, matchingPath: "/usage") else {
            return nil
        }

        guard isAuthorized(query) else {
            return Self.response(
                status: "401 Unauthorized",
                contentType: "application/json",
                body: #"{"ok":false,"error":"unauthorized"}"# + "\n"
            )
        }

        guard let snapshot = usageProvider(),
              let data = try? JSONEncoder().encode(snapshot),
              let body = String(data: data, encoding: .utf8) else {
            return Self.response(
                status: "503 Service Unavailable",
                contentType: "application/json",
                body: #"{"ok":false,"error":"usage unavailable"}"# + "\n"
            )
        }

        return Self.response(status: "200 OK", contentType: "application/json", body: body + "\n")
    }

    private func event(from request: String) -> BeaconEvent? {
        guard let query = query(from: request, matchingPath: "/event"),
              isAuthorized(query) else {
            return nil
        }

        let state: BeaconState
        if query["type"] == "permission_request" || query["type"] == "needs_you" {
            state = .needsYou
        } else if query["type"] == "turn_done" || query["type"] == "done" {
            state = .done
        } else {
            return nil
        }

        return BeaconEvent(
            state: state,
            returnTarget: BeaconReturnTarget(
                processIdentifier: sanitizedProcessIdentifier(query["return_pid"]),
                bundleIdentifier: sanitizedBundleIdentifier(query["return_bundle"])
            )
        )
    }

    private func query(from request: String, matchingPath path: String) -> [String: String]? {
        guard let requestLine = request.components(separatedBy: "\r\n").first,
              requestLine.hasPrefix("GET ") else {
            return nil
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2,
              let url = URL(string: "http://127.0.0.1\(parts[1])"),
              url.path == path,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value
        }
        return query
    }

    private func isAuthorized(_ query: [String: String]) -> Bool {
        guard let expectedToken = tokenProvider() else {
            return false
        }
        return query["token"] == expectedToken
    }

    private func sanitizedProcessIdentifier(_ value: String?) -> pid_t? {
        guard let value,
              let identifier = Int32(value),
              identifier > 1 else {
            return nil
        }
        return identifier
    }

    private func sanitizedBundleIdentifier(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.count <= 200,
              value.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    private static func response(status: String, contentType: String = "text/plain", body: String) -> String {
        """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configStore = ConfigStore()
    private let hookInstaller = HookInstaller()
    private let usageReader = CodexUsageReader()
    private lazy var presetStore = PresetStore(appSupportDirectory: configStore.directoryURL)
    private lazy var touchBarBeacon = TouchBarBeacon { [weak self] in
        self?.activateCodex()
    }
    private var settingsController: SettingsViewController?
    private var window: NSWindow?
    private var server: BeaconServer?
    private var resetWorkItem: DispatchWorkItem?
    private var usageTimer: Timer?
    private var statusItem: NSStatusItem?
    private var touchBarMenuItem: NSMenuItem?
    private var soundMenuItem: NSMenuItem?
    private var isServerReady = false
    private var currentState: BeaconState = .idle
    private var returnTarget = BeaconReturnTarget(processIdentifier: nil, bundleIdentifier: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupWindow()
        setupMenuBar()
        setupServer()
        touchBarBeacon.install()
        applyConfig()
        setupUsageRefresh()
        showSettings()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    private func setupWindow() {
        let controller = SettingsViewController(configStore: configStore, hookInstaller: hookInstaller, isServerReady: isServerReady) { [weak self] in
            self?.applyConfig()
        }
        settingsController = controller

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 252),
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
            }, usageProvider: { [weak self] in
                self?.usageReader.latestSnapshot()
            }) { [weak self] event in
                self?.display(event)
            }
            server?.start()
            isServerReady = true
            settingsController?.setServerReady(true)
        } catch {
            isServerReady = false
            settingsController?.setServerReady(false)
            NSLog("Codex Beacon server error: \(error.localizedDescription)")
        }
    }

    private func applyConfig() {
        configStore.reload()
        presetStore.reload(activePresetName: configStore.config.presetName)
        settingsController?.refresh()
        refreshMenu()
        let idleStyle = presetStore.preset.style(for: .idle)
        touchBarBeacon.setStyle(idleStyle)
        refreshUsageDisplay()
        touchBarBeacon.setEnabled(configStore.config.touchBarVisual)
        statusItem?.button?.title = idleStyle.resolvedMenuIcon
    }

    private func refreshMenu() {
        touchBarMenuItem?.state = configStore.config.touchBarVisual ? .on : .off
        soundMenuItem?.state = configStore.config.sound ? .on : .off
    }

    private func display(_ event: BeaconEvent) {
        returnTarget = event.returnTarget
        configStore.reload()
        presetStore.reload(activePresetName: configStore.config.presetName)
        refreshMenu()
        resetWorkItem?.cancel()
        let state = event.state
        currentState = state
        let style = presetStore.preset.style(for: state)
        touchBarBeacon.setUsageText(nil)

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
            self.currentState = .idle
            let idleStyle = self.presetStore.preset.style(for: .idle)
            self.touchBarBeacon.setStyle(idleStyle)
            self.refreshUsageDisplay()
            if self.configStore.config.touchBarVisual {
                self.touchBarBeacon.present()
            }
            self.statusItem?.button?.title = idleStyle.resolvedMenuIcon
        }
        resetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private func setupUsageRefresh() {
        usageTimer?.invalidate()
        refreshUsageDisplay()
        usageTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshUsageDisplay()
        }
    }

    private func refreshUsageDisplay() {
        configStore.reload()
        guard currentState == .idle,
              let usageText = usageReader.latestSnapshot()?.displayText(for: configStore.config.selectedUsageWindow) else {
            if currentState == .idle {
                touchBarBeacon.setUsageText(nil)
            }
            return
        }
        touchBarBeacon.setUsageText(usageText)
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
        if activate(returnTarget) {
            return
        }

        if activate(bundleIdentifier: "com.openai.codex", allowLaunch: true) {
            return
        }

        if activate(appNamed: "Codex") {
            return
        }

        NSLog("Codex Beacon has no valid return target")
    }

    private func activate(_ target: BeaconReturnTarget) -> Bool {
        guard !target.isEmpty else { return false }

        let apps = NSWorkspace.shared.runningApplications
        if let processIdentifier = target.processIdentifier,
           let app = apps.first(where: { $0.processIdentifier == processIdentifier && isActivatable($0) }),
           activate(app) {
            return true
        }

        guard let bundleIdentifier = target.bundleIdentifier else {
            return false
        }
        return activate(bundleIdentifier: bundleIdentifier, allowLaunch: false)
    }

    private func activate(bundleIdentifier: String, allowLaunch: Bool) -> Bool {
        let apps = NSWorkspace.shared.runningApplications
        if let app = apps.first(where: { $0.bundleIdentifier == bundleIdentifier && isActivatable($0) }),
           activate(app) {
            return true
        }

        guard allowLaunch,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return false
        }

        return NSWorkspace.shared.open(url)
    }

    private func activate(appNamed name: String) -> Bool {
        let apps = NSWorkspace.shared.runningApplications
        guard let app = apps.first(where: { runningApp in
            guard isActivatable(runningApp) else { return false }
            return runningApp.localizedName?.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else {
            return false
        }
        return activate(app)
    }

    private func isActivatable(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier != Bundle.main.bundleIdentifier && app.activationPolicy == .regular
    }

    @discardableResult
    private func activate(_ app: NSRunningApplication) -> Bool {
        let didActivate = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        if !didActivate {
            NSLog("Codex Beacon failed to activate \(app.localizedName ?? app.bundleIdentifier ?? "unknown app")")
        }
        return didActivate
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
        usageTimer?.invalidate()
        touchBarBeacon.minimize()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
