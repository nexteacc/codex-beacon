import AppKit
import Foundation
import Network
import ObjectiveC
import QuartzCore
import WidgetKit

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
            config.authToken = Self.makeToken()
            try? save()
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

struct CodexUsageWindow: Codable, Equatable {
    let label: String
    let usedPercent: Double
    let remainingPercent: Double
    let windowMinutes: Int
    let resetsAt: Int
    let resetsAtLocal: String
    let resetInSeconds: Int

    static func == (lhs: CodexUsageWindow, rhs: CodexUsageWindow) -> Bool {
        lhs.label == rhs.label
            && lhs.usedPercent == rhs.usedPercent
            && lhs.remainingPercent == rhs.remainingPercent
            && lhs.windowMinutes == rhs.windowMinutes
            && lhs.resetsAt == rhs.resetsAt
            && lhs.resetsAtLocal == rhs.resetsAtLocal
    }
}

struct CodexUsageDisplay: Equatable {
    let text: String
    let isLimited: Bool
    let isReady: Bool
    let pulseKey: String?
    let resetAt: Int?
}

struct CodexUsageSnapshot: Codable, Equatable {
    let ok: Bool
    let updatedAt: String
    let planType: String?
    let rateLimitReachedType: String?
    let primary: CodexUsageWindow
    let secondary: CodexUsageWindow?

    func window(for selection: UsageWindowSelection) -> CodexUsageWindow? {
        switch selection {
        case .fiveHour:
            return primary
        case .weekly:
            return secondary
        }
    }

    func display(for selection: UsageWindowSelection) -> CodexUsageDisplay? {
        guard let window = window(for: selection) else { return nil }

        if isLimited(window: window, selection: selection) {
            if window.isPastResetGracePeriod {
                return CodexUsageDisplay(
                    text: "Ready",
                    isLimited: false,
                    isReady: true,
                    pulseKey: "\(selection.rawValue):\(window.resetsAt):ready",
                    resetAt: window.resetsAt
                )
            }

            return CodexUsageDisplay(
                text: "Back \(window.resetDisplayText)",
                isLimited: true,
                isReady: false,
                pulseKey: "\(selection.rawValue):\(window.resetsAt):\(rateLimitReachedType ?? "used")",
                resetAt: window.resetsAt
            )
        }

        return CodexUsageDisplay(
            text: "\(window.label) \(Int(window.remainingPercent.rounded()))% · \(window.resetDisplayText)",
            isLimited: false,
            isReady: false,
            pulseKey: nil,
            resetAt: window.resetsAt
        )
    }

    func isLimited(window: CodexUsageWindow, selection: UsageWindowSelection) -> Bool {
        if window.remainingPercent <= 0 {
            return true
        }

        guard let reachedType = rateLimitReachedType?.lowercased(), !reachedType.isEmpty else {
            return false
        }

        switch selection {
        case .fiveHour:
            return reachedType.contains("primary")
                || reachedType.contains("5h")
                || reachedType.contains("five")
                || reachedType == "codex"
        case .weekly:
            return reachedType.contains("secondary")
                || reachedType.contains("weekly")
                || reachedType.contains("week")
        }
    }
}

extension CodexUsageWindow {
    var resetDisplayText: String {
        let date = Date(timeIntervalSince1970: TimeInterval(resetsAt))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = windowMinutes >= 1_440 ? "MMM d" : "HH:mm"
        return formatter.string(from: date)
    }

    var isPastResetGracePeriod: Bool {
        Date().timeIntervalSince1970 >= TimeInterval(resetsAt + 8)
    }
}

final class CodexUsageReader {
    private let sessionsDirectory: URL
    private let scanLimits = [8, 24, 64]
    private let maxTailBytes: UInt64 = 1_048_576
    private var lastMatchedFileURL: URL?

    private struct UsageCandidate {
        let snapshot: CodexUsageSnapshot
        let timestamp: Date
        let modifiedAt: Date
        let fileURL: URL
    }

    init() {
        sessionsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    func latestSnapshot() -> CodexUsageSnapshot? {
        var candidates: [UsageCandidate] = []
        var scanned = Set<URL>()
        let files = recentSessionFiles()

        if let cachedFileURL = lastMatchedFileURL,
           let candidate = usageCandidate(from: cachedFileURL, modifiedAt: fileModifiedAt(cachedFileURL)) {
            candidates.append(candidate)
            scanned.insert(cachedFileURL)
        }

        for limit in scanLimits {
            let batch = Array(files.prefix(limit))
            for file in batch where !scanned.contains(file.url) {
                if let candidate = usageCandidate(from: file.url, modifiedAt: file.modifiedAt) {
                    candidates.append(candidate)
                }
                scanned.insert(file.url)
            }

            guard let best = newestCandidate(candidates) else {
                continue
            }
            if canStopScanning(best: best, scannedBatch: batch) || limit == scanLimits.last {
                lastMatchedFileURL = best.fileURL
                return best.snapshot
            }
        }

        guard let best = newestCandidate(candidates) else {
            lastMatchedFileURL = nil
            return nil
        }
        lastMatchedFileURL = best.fileURL
        return best.snapshot
    }

    private func recentSessionFiles() -> [(url: URL, modifiedAt: Date)] {
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

        return Array(files
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(scanLimits.last ?? 64))
    }

    private func usageCandidate(from fileURL: URL, modifiedAt: Date) -> UsageCandidate? {
        guard let line = latestTokenCountRateLimitLine(in: fileURL),
              let snapshot = snapshot(from: line) else {
            return nil
        }

        return UsageCandidate(
            snapshot: snapshot,
            timestamp: dateValue(snapshot.updatedAt) ?? .distantPast,
            modifiedAt: modifiedAt,
            fileURL: fileURL
        )
    }

    private func latestTokenCountRateLimitLine(in fileURL: URL) -> String? {
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
                .first { $0.contains(#""token_count""#) && $0.contains(#""rate_limits""#) }
                .map(String.init)
        } catch {
            return nil
        }
    }

    private func snapshot(from line: String) -> CodexUsageSnapshot? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "event_msg",
              let payload = root["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let rateLimits = rateLimits(from: root),
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
            rateLimitReachedType: stringValue(rateLimits["rate_limit_reached_type"]),
            primary: primary,
            secondary: secondary
        )
    }

    private func rateLimits(from root: [String: Any]) -> [String: Any]? {
        if let payload = root["payload"] as? [String: Any],
           let rateLimits = payload["rate_limits"] as? [String: Any] {
            return rateLimits
        }
        return root["rate_limits"] as? [String: Any]
    }

    private func newestCandidate(_ candidates: [UsageCandidate]) -> UsageCandidate? {
        candidates.sorted {
            if $0.timestamp == $1.timestamp {
                return $0.modifiedAt > $1.modifiedAt
            }
            return $0.timestamp > $1.timestamp
        }.first
    }

    private func canStopScanning(best: UsageCandidate, scannedBatch: [(url: URL, modifiedAt: Date)]) -> Bool {
        guard let oldestScannedModification = scannedBatch.map(\.modifiedAt).min() else {
            return false
        }
        return best.timestamp >= oldestScannedModification
    }

    private func fileModifiedAt(_ fileURL: URL) -> Date {
        guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]) else {
            return .distantPast
        }
        return values.contentModificationDate ?? .distantPast
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

    private func stringValue(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else {
            return nil
        }
        return value
    }

    private func dateValue(_ value: String) -> Date? {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: value) {
            return date
        }

        isoFormatter.formatOptions = [.withInternetDateTime]
        return isoFormatter.date(from: value)
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

final class CodexUsageMonitor {
    private let reader = CodexUsageReader()
    private let queue = DispatchQueue(label: "codex-beacon.usage-monitor", qos: .utility)
    private let snapshotLock = NSLock()
    private var snapshot: CodexUsageSnapshot?
    private var isRefreshing = false
    private var pendingCompletions: [(CodexUsageSnapshot?) -> Void] = []

    func cachedSnapshot() -> CodexUsageSnapshot? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshot
    }

    func refresh(completion: ((CodexUsageSnapshot?) -> Void)? = nil) {
        queue.async { [completion] in
            if let completion {
                self.pendingCompletions.append(completion)
            }

            guard !self.isRefreshing else {
                return
            }

            self.isRefreshing = true
            let nextSnapshot = self.reader.latestSnapshot()
            self.snapshotLock.lock()
            self.snapshot = nextSnapshot
            self.snapshotLock.unlock()

            let completions = self.pendingCompletions
            self.pendingCompletions = []
            self.isRefreshing = false

            guard !completions.isEmpty else {
                return
            }

            DispatchQueue.main.async {
                completions.forEach { $0(nextSnapshot) }
            }
        }
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
                background: "#2A211B",
                foreground: "#F3EDE4",
                sound: nil
            ),
            BeaconState.needsYou.rawValue: BeaconStateStyle(
                text: "🫶 Needs You",
                menuIcon: "🫶",
                background: "#9F4A3F",
                foreground: "#FFF7F2",
                sound: "Submarine"
            ),
            BeaconState.done.rawValue: BeaconStateStyle(
                text: "❤️ Done",
                menuIcon: "❤️",
                background: "#2A211B",
                foreground: "#D7A85B",
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

        guard let fileName = safePresetFileName(activePresetName) else {
            preset = .default
            return
        }
        let fileURL = presetsDirectory.appendingPathComponent(fileName)
        guard isPresetFile(fileURL) else {
            preset = .default
            return
        }
        guard let data = try? Data(contentsOf: fileURL),
              let nextPreset = try? JSONDecoder().decode(BeaconPreset.self, from: data) else {
            preset = .default
            return
        }
        preset = nextPreset
    }

    private func safePresetFileName(_ name: String) -> String? {
        let fileName = name.hasSuffix(".json") ? name : "\(name).json"
        guard fileName.range(of: #"^[A-Za-z0-9_-]+\.json$"#, options: .regularExpression) != nil else {
            return nil
        }
        return fileName
    }

    private func isPresetFile(_ url: URL) -> Bool {
        let base = presetsDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base + "/")
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
    private let mobileNotifications: MobileNotificationsManager
    private let usageSnapshotProvider: () -> CodexUsageSnapshot?
    private let onChange: () -> Void
    private let touchBarSwitch = BeaconToggle()
    private let soundSwitch = BeaconToggle()
    private let usageControl = NSSegmentedControl(labels: ["5h", "Weekly"], trackingMode: .selectOne, target: nil, action: nil)
    private let hooksButton = NSButton(title: "Install Hooks", target: nil, action: nil)
    private let mobileStatusDot = StatusDotView()
    private let mobileStatusLabel = NSTextField(labelWithString: "Not Configured")
    private let barkURLField = NSSecureTextField(string: "")
    private let testNotificationButton = NSButton(title: "Test", target: nil, action: nil)
    private let disconnectButton = NSButton(title: "Disconnect", target: nil, action: nil)
    private let serverDot = StatusDotView()
    private var isServerReady = false
    private var isTestingMobileNotifications = false
    private var mobileStatusOverride: (text: String, color: NSColor, detail: String?)?

    init(
        configStore: ConfigStore,
        hookInstaller: HookInstaller,
        mobileNotifications: MobileNotificationsManager,
        isServerReady: Bool,
        usageSnapshotProvider: @escaping () -> CodexUsageSnapshot?,
        onChange: @escaping () -> Void
    ) {
        self.configStore = configStore
        self.hookInstaller = hookInstaller
        self.mobileNotifications = mobileNotifications
        self.isServerReady = isServerReady
        self.usageSnapshotProvider = usageSnapshotProvider
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 260))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let touchBarRow = row(title: "Touch Bar", control: touchBarSwitch)
        let soundRow = row(title: "Sound", control: soundSwitch)
        let usageRow = row(title: "Usage", control: usageControl)
        let hooksRow = hookRow()
        let mobileStatusRow = row(title: "iPhone", control: mobileStatusControl())
        let barkURLRow = row(title: "Bark URL", control: barkURLControl())

        usageControl.segmentStyle = .rounded
        usageControl.controlSize = .small
        usageControl.setWidth(56, forSegment: 0)
        usageControl.setWidth(78, forSegment: 1)

        let stack = NSStackView(views: [touchBarRow, soundRow, usageRow, hooksRow, mobileStatusRow, barkURLRow])
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
        testNotificationButton.target = self
        testNotificationButton.action = #selector(testMobileNotification)
        disconnectButton.target = self
        disconnectButton.action = #selector(disconnectMobileNotifications)

        self.view = root
        refresh()
    }

    func refresh() {
        touchBarSwitch.isOn = configStore.config.touchBarVisual
        soundSwitch.isOn = configStore.config.sound
        usageControl.selectedSegment = configStore.config.selectedUsageWindow == .fiveHour ? 0 : 1
        serverDot.setColor(isServerReady ? .systemGreen : .systemRed, tooltip: isServerReady ? "Ready" : "Port busy")
        refreshHooks()
        refreshMobileNotifications()
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

    private func mobileStatusControl() -> NSView {
        mobileStatusLabel.font = NSFont.systemFont(ofSize: 12)
        mobileStatusLabel.lineBreakMode = .byTruncatingTail

        disconnectButton.bezelStyle = .rounded
        disconnectButton.controlSize = .small
        disconnectButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)

        let status = NSStackView(views: [mobileStatusDot, mobileStatusLabel])
        status.orientation = .horizontal
        status.alignment = .centerY
        status.spacing = 7

        let control = NSStackView(views: [status, disconnectButton])
        control.orientation = .horizontal
        control.alignment = .centerY
        control.distribution = .gravityAreas
        control.spacing = 8
        return control
    }

    private func barkURLControl() -> NSView {
        barkURLField.placeholderString = "Paste from Bark"
        barkURLField.controlSize = .small
        barkURLField.font = NSFont.systemFont(ofSize: 12)

        testNotificationButton.bezelStyle = .rounded
        testNotificationButton.controlSize = .small
        testNotificationButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        testNotificationButton.widthAnchor.constraint(equalToConstant: 48).isActive = true

        let control = NSStackView(views: [barkURLField, testNotificationButton])
        control.orientation = .horizontal
        control.alignment = .centerY
        control.spacing = 8
        return control
    }

    private func refreshMobileNotifications() {
        let configured = mobileNotifications.isConfigured
        if isTestingMobileNotifications {
            mobileStatusLabel.stringValue = "Testing"
            mobileStatusDot.setColor(.systemOrange, tooltip: "Sending a test notification")
        } else if let mobileStatusOverride {
            mobileStatusLabel.stringValue = mobileStatusOverride.text
            mobileStatusDot.setColor(mobileStatusOverride.color, tooltip: mobileStatusOverride.detail ?? mobileStatusOverride.text)
        } else if configured {
            mobileStatusLabel.stringValue = "Configured"
            mobileStatusDot.setColor(.systemGreen, tooltip: "Bark notifications configured")
        } else {
            mobileStatusLabel.stringValue = "Not Configured"
            mobileStatusDot.setColor(.systemGray, tooltip: "Paste a Bark URL and test it")
        }

        disconnectButton.isHidden = !configured
        disconnectButton.isEnabled = configured && !isTestingMobileNotifications
        barkURLField.isEnabled = !isTestingMobileNotifications
        testNotificationButton.isEnabled = !isTestingMobileNotifications
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

    @objc private func testMobileNotification() {
        isTestingMobileNotifications = true
        mobileStatusOverride = nil
        refreshMobileNotifications()

        let value = barkURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        mobileNotifications.test(
            urlString: value.isEmpty ? nil : value,
            snapshot: usageSnapshotProvider()
        ) { [weak self] result in
            guard let self else { return }
            self.isTestingMobileNotifications = false
            switch result {
            case .success:
                self.barkURLField.stringValue = ""
                self.mobileStatusOverride = ("Connected", .systemGreen, "Test notification sent")
            case .failure(let error):
                self.mobileStatusOverride = ("Test Failed", .systemRed, error.localizedDescription)
            }
            self.refreshMobileNotifications()
        }
    }

    @objc private func disconnectMobileNotifications() {
        do {
            try mobileNotifications.disconnect()
            barkURLField.stringValue = ""
            mobileStatusOverride = nil
            refreshMobileNotifications()
        } catch {
            mobileStatusOverride = ("Disconnect Failed", .systemRed, error.localizedDescription)
            refreshMobileNotifications()
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
    private var usageDisplay: CodexUsageDisplay?
    private var usageShouldPulse = false
    private var installed = false
    private let onCodexTap: () -> Void
    private let onUsageTap: () -> Void

    init(onCodexTap: @escaping () -> Void, onUsageTap: @escaping () -> Void) {
        trayItem = NSCustomTouchBarItem(identifier: trayIdentifier)
        modalItem = NSCustomTouchBarItem(identifier: modalIdentifier)
        modalTouchBar = NSTouchBar()
        self.onCodexTap = onCodexTap
        self.onUsageTap = onUsageTap
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

    func setUsage(_ display: CodexUsageDisplay?, pulse: Bool = false) {
        usageDisplay = display
        usageShouldPulse = pulse
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
        let shouldPulse = usageShouldPulse
        modalItem.view = fullTouchBarView(style: style, usageDisplay: usageDisplay, pulse: shouldPulse)
        usageShouldPulse = false
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

    private func fullTouchBarView(style: BeaconStateStyle, usageDisplay: CodexUsageDisplay?, pulse: Bool) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 980, height: 36))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.04).cgColor

        let status = usageDisplay.map { unifiedUsageView(style: style, usageDisplay: $0, width: 310, height: 32, pulse: pulse) }
            ?? statusView(style: style, width: 300, height: 32, fontSize: 17)
        status.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(status)

        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            status.widthAnchor.constraint(equalToConstant: usageDisplay == nil ? 300 : 310),
            status.heightAnchor.constraint(equalToConstant: 32)
        ])

        return container
    }

    private func unifiedUsageView(style: BeaconStateStyle, usageDisplay: CodexUsageDisplay, width: CGFloat, height: CGFloat, pulse: Bool) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        let background: NSColor
        if usageDisplay.isLimited {
            background = NSColor(calibratedRed: 0.165, green: 0.129, blue: 0.106, alpha: 1.0)
        } else if usageDisplay.isReady {
            background = NSColor(calibratedRed: 0.165, green: 0.129, blue: 0.106, alpha: 1.0)
        } else {
            background = NSColor(calibratedRed: 0.165, green: 0.129, blue: 0.106, alpha: 1.0)
        }
        container.layer?.backgroundColor = background.cgColor
        container.layer?.cornerRadius = 10
        container.layer?.borderWidth = (usageDisplay.isLimited || usageDisplay.isReady) ? 1 : 0
        container.layer?.borderColor = usageBorderColor(for: usageDisplay).cgColor
        container.toolTip = "Open Codex"
        if (usageDisplay.isLimited || usageDisplay.isReady) && pulse {
            addUsagePulse(to: container.layer, from: background, to: usagePulseColor(for: usageDisplay))
        }

        let button = NSButton(title: "", target: self, action: #selector(openCodex))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.setButtonType(.momentaryPushIn)
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.toolTip = "Open Codex"
        button.attributedTitle = NSAttributedString(
            string: style.text,
            attributes: [
                .foregroundColor: style.foregroundColor,
                .font: NSFont.systemFont(ofSize: 16, weight: .semibold)
            ]
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator)

        let usage = NSTextField(labelWithString: usageDisplay.text)
        usage.alignment = .right
        usage.lineBreakMode = .byTruncatingTail
        usage.textColor = usageTextColor(for: usageDisplay)
        usage.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        usage.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(usage)

        let usageButton = NSButton(title: "", target: self, action: #selector(toggleUsageWindow))
        usageButton.isBordered = false
        usageButton.bezelStyle = .regularSquare
        usageButton.setButtonType(.momentaryPushIn)
        usageButton.wantsLayer = true
        usageButton.layer?.backgroundColor = NSColor.clear.cgColor
        usageButton.toolTip = "Switch usage window"
        usageButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(usageButton)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            button.widthAnchor.constraint(equalToConstant: 118),

            separator.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: 2),
            separator.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.heightAnchor.constraint(equalToConstant: 18),

            usage.leadingAnchor.constraint(equalTo: separator.trailingAnchor, constant: 12),
            usage.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            usage.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            usageButton.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            usageButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            usageButton.topAnchor.constraint(equalTo: container.topAnchor),
            usageButton.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

    private func usageBorderColor(for display: CodexUsageDisplay) -> NSColor {
        if display.isLimited {
            return NSColor(calibratedRed: 0.851, green: 0.541, blue: 0.404, alpha: 0.45)
        }
        if display.isReady {
            return NSColor(calibratedRed: 0.843, green: 0.659, blue: 0.357, alpha: 0.38)
        }
        return NSColor.clear
    }

    private func usagePulseColor(for display: CodexUsageDisplay) -> NSColor {
        if display.isReady {
            return NSColor(calibratedRed: 0.227, green: 0.188, blue: 0.133, alpha: 1.0)
        }
        return NSColor(calibratedRed: 0.227, green: 0.161, blue: 0.145, alpha: 1.0)
    }

    private func usageTextColor(for display: CodexUsageDisplay) -> NSColor {
        if display.isLimited {
            return NSColor(calibratedRed: 0.851, green: 0.541, blue: 0.404, alpha: 0.95)
        }
        if display.isReady {
            return NSColor(calibratedRed: 0.843, green: 0.659, blue: 0.357, alpha: 0.95)
        }
        return NSColor(calibratedRed: 0.953, green: 0.929, blue: 0.894, alpha: 0.90)
    }

    private func addUsagePulse(to layer: CALayer?, from background: NSColor, to highlight: NSColor) {
        guard let layer else { return }
        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = background.cgColor
        animation.toValue = highlight.cgColor
        animation.duration = 0.85
        animation.autoreverses = true
        animation.repeatCount = 8
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "codexBeaconLimitedPulse")
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
        onCodexTap()
    }

    @objc private func toggleUsageWindow() {
        NSLog("Codex Beacon usage item tapped")
        onUsageTap()
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
        guard query(from: request, matchingPath: "/usage") != nil else {
            return nil
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
    private let usageMonitor = CodexUsageMonitor()
    private lazy var mobileNotifications = MobileNotificationsManager(appSupportDirectory: configStore.directoryURL)
    private lazy var presetStore = PresetStore(appSupportDirectory: configStore.directoryURL)
    private lazy var touchBarBeacon = TouchBarBeacon(
        onCodexTap: { [weak self] in
            self?.activateCodex()
        },
        onUsageTap: { [weak self] in
            self?.toggleUsageWindowFromTouchBar()
        }
    )
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
    private var limitedUsagePulseKey: String?
    private var readyUsagePulseKey: String?
    private var usageRecoveryWorkItem: DispatchWorkItem?
    private var usageRecoveryKey: String?
    private var lastWidgetSnapshot: CodexUsageSnapshot?

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

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshUsageDisplay()
    }

    private func setupWindow() {
        let controller = SettingsViewController(
            configStore: configStore,
            hookInstaller: hookInstaller,
            mobileNotifications: mobileNotifications,
            isServerReady: isServerReady,
            usageSnapshotProvider: { [weak self] in
                self?.usageMonitor.cachedSnapshot()
            }
        ) { [weak self] in
            self?.applyConfig()
        }
        settingsController = controller

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 332),
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
                let cachedSnapshot = self?.usageMonitor.cachedSnapshot()
                self?.usageMonitor.refresh()
                return cachedSnapshot
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
        touchBarBeacon.setUsage(nil)

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
        usageTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.refreshUsageDisplay()
        }
    }

    private func refreshUsageDisplay(triggeredByRecoveryTimer: Bool = false) {
        configStore.reload()
        guard currentState == .idle else {
            clearUsageDisplay()
            return
        }

        let cachedSnapshot = usageMonitor.cachedSnapshot()
        if let cachedSnapshot {
            applyUsageSnapshot(cachedSnapshot, selection: configStore.config.selectedUsageWindow, playRecoverySound: false, publishWidgetUpdate: false)
        }

        usageMonitor.refresh { [weak self] snapshot in
            guard let self else { return }
            self.configStore.reload()
            guard self.currentState == .idle else {
                self.clearUsageDisplay()
                return
            }
            self.applyUsageSnapshot(
                snapshot,
                selection: self.configStore.config.selectedUsageWindow,
                playRecoverySound: triggeredByRecoveryTimer,
                publishWidgetUpdate: true
            )
        }
    }

    private func applyUsageSnapshot(
        _ snapshot: CodexUsageSnapshot?,
        selection: UsageWindowSelection,
        playRecoverySound: Bool,
        publishWidgetUpdate: Bool
    ) {
        if let snapshot {
            mobileNotifications.process(snapshot: snapshot)
        }

        guard let usageDisplay = snapshot?.display(for: selection) else {
            clearUsageDisplay()
            publishWidgetSnapshotIfNeeded(snapshot, enabled: publishWidgetUpdate)
            return
        }

        if usageDisplay.isLimited {
            scheduleUsageRecovery(for: usageDisplay)
        } else {
            cancelUsageRecovery()
        }

        let shouldPulse: Bool
        if usageDisplay.isLimited {
            shouldPulse = usageDisplay.pulseKey != limitedUsagePulseKey
            limitedUsagePulseKey = usageDisplay.pulseKey
            readyUsagePulseKey = nil
        } else if usageDisplay.isReady {
            shouldPulse = usageDisplay.pulseKey != readyUsagePulseKey
            readyUsagePulseKey = usageDisplay.pulseKey
            limitedUsagePulseKey = nil
        } else {
            shouldPulse = false
            limitedUsagePulseKey = nil
            readyUsagePulseKey = nil
        }

        touchBarBeacon.setUsage(usageDisplay, pulse: shouldPulse)
        publishWidgetSnapshotIfNeeded(snapshot, enabled: publishWidgetUpdate)

        if playRecoverySound && usageDisplay.isReady && configStore.config.sound {
            NSSound(named: NSSound.Name("Ping"))?.play()
        }
    }

    private func clearUsageDisplay() {
        if currentState == .idle {
            touchBarBeacon.setUsage(nil)
        }
        limitedUsagePulseKey = nil
        readyUsagePulseKey = nil
        cancelUsageRecovery()
    }

    private func publishWidgetSnapshotIfNeeded(_ snapshot: CodexUsageSnapshot?, enabled: Bool) {
        guard enabled, snapshot != lastWidgetSnapshot else {
            return
        }
        lastWidgetSnapshot = snapshot
        if #available(macOS 14.0, *) {
            WidgetCenter.shared.reloadTimelines(ofKind: "CodexUsageWidget")
        }
    }

    private func scheduleUsageRecovery(for display: CodexUsageDisplay) {
        guard let resetAt = display.resetAt,
              let key = display.pulseKey else {
            cancelUsageRecovery()
            return
        }
        guard usageRecoveryKey != key else { return }

        usageRecoveryWorkItem?.cancel()
        usageRecoveryKey = key

        let fireAt = TimeInterval(resetAt + 8)
        let delay = max(1, fireAt - Date().timeIntervalSince1970)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.usageRecoveryKey = nil
            self.usageRecoveryWorkItem = nil
            self.refreshUsageDisplay(triggeredByRecoveryTimer: true)
            if self.configStore.config.touchBarVisual {
                self.touchBarBeacon.present()
            }
        }
        usageRecoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelUsageRecovery() {
        usageRecoveryWorkItem?.cancel()
        usageRecoveryWorkItem = nil
        usageRecoveryKey = nil
    }

    private func toggleUsageWindowFromTouchBar() {
        configStore.reload()
        let nextSelection: UsageWindowSelection = configStore.config.selectedUsageWindow == .fiveHour ? .weekly : .fiveHour
        configStore.setUsageWindow(nextSelection)
        settingsController?.refresh()
        refreshUsageDisplay()
        if configStore.config.touchBarVisual {
            touchBarBeacon.present()
        }
    }

    @objc private func showSettings() {
        if window == nil {
            setupWindow()
        }

        refreshUsageDisplay()
        revealSettingsWindow()
        DispatchQueue.main.async { [weak self] in
            self?.refreshUsageDisplay()
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
