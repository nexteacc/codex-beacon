import AppKit
import Foundation
import Network
import ObjectiveC
import QuartzCore
import UniformTypeIdentifiers
import WidgetKit

struct BeaconConfig: Codable, Equatable {
    var touchBarVisual: Bool
    var sound: Bool
    var activePreset: String?
    var authToken: String?
    var usageWindow: UsageWindowSelection?
    var menuBarUsage: Bool?
    var stateAnimations: [String: String]?

    static let `default` = BeaconConfig(
        touchBarVisual: true,
        sound: true,
        activePreset: "default",
        authToken: nil,
        usageWindow: .fiveHour,
        menuBarUsage: true,
        stateAnimations: nil
    )

    var presetName: String {
        activePreset?.isEmpty == false ? activePreset! : "default"
    }

    var selectedUsageWindow: UsageWindowSelection {
        usageWindow ?? .fiveHour
    }

    var showsMenuBarUsage: Bool {
        menuBarUsage ?? true
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

    func setMenuBarUsage(_ enabled: Bool) {
        config.menuBarUsage = enabled
        try? save()
    }

    func animationSelection(for state: BeaconState) -> String? {
        guard let selection = config.stateAnimations?[state.rawValue] else { return nil }
        return selection == "builtin:TaskComplete" ? nil : selection
    }

    func animationURL(for state: BeaconState) -> URL? {
        guard let selection = animationSelection(for: state) else { return nil }
        return customAnimationURL(for: selection)
    }

    func animationURL(for selection: String) -> URL? {
        customAnimationURL(for: selection)
    }

    func customAnimationSelections(for state: BeaconState) -> [String] {
        let animationsDirectory = directoryURL.appendingPathComponent("Animations", isDirectory: true)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: animationsDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url -> (String, Date)? in
            guard url.pathExtension.lowercased() == "gif",
                  url.lastPathComponent.hasPrefix("\(state.rawValue)-"),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return ("custom:\(url.lastPathComponent)", values.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    func setAnimation(_ selection: String?, for state: BeaconState) {
        var selections = config.stateAnimations ?? [:]
        selections[state.rawValue] = selection
        if selection == nil {
            selections.removeValue(forKey: state.rawValue)
        }
        config.stateAnimations = selections
        try? save()
    }

    func importAnimation(from sourceURL: URL, for state: BeaconState) throws -> String {
        let animationsDirectory = directoryURL.appendingPathComponent("Animations", isDirectory: true)
        try FileManager.default.createDirectory(at: animationsDirectory, withIntermediateDirectories: true)
        let filename = "\(state.rawValue)-\(UUID().uuidString).gif"
        let destinationURL = animationsDirectory.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        try Self.secureFile(destinationURL)
        let selection = "custom:\(filename)"
        let previousAnimations = config.stateAnimations

        var selections = config.stateAnimations ?? [:]
        selections[state.rawValue] = selection
        config.stateAnimations = selections
        do {
            try save()
        } catch {
            config.stateAnimations = previousAnimations
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }

        return selection
    }

    func deleteAnimation(_ selection: String, for state: BeaconState) throws {
        guard let animationURL = customAnimationURL(for: selection) else { return }
        let previousAnimations = config.stateAnimations
        if animationSelection(for: state) == selection {
            var selections = config.stateAnimations ?? [:]
            selections.removeValue(forKey: state.rawValue)
            config.stateAnimations = selections
            do {
                try save()
            } catch {
                config.stateAnimations = previousAnimations
                throw error
            }
        }
        if FileManager.default.fileExists(atPath: animationURL.path) {
            try FileManager.default.removeItem(at: animationURL)
        }
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

    private func customAnimationURL(for selection: String) -> URL? {
        guard selection.hasPrefix("custom:") else { return nil }
        let filename = String(selection.dropFirst("custom:".count))
        guard !filename.isEmpty, filename == URL(fileURLWithPath: filename).lastPathComponent else { return nil }
        return directoryURL
            .appendingPathComponent("Animations", isDirectory: true)
            .appendingPathComponent(filename)
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

final class BeaconSwitch: NSSwitch {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        controlSize = .small
        focusRingType = .none
        refusesFirstResponder = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class PasteableTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if currentEditor() != nil,
           modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            return pasteFromClipboard()
        }
        return super.performKeyEquivalent(with: event)
    }

    @discardableResult
    func pasteFromClipboard() -> Bool {
        guard let value = NSPasteboard.general.string(forType: .string) else {
            NSSound.beep()
            return false
        }
        stringValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return true
    }
}

final class SettingsAtmosphereView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let bounds = bounds

        NSGradient(colors: [
            NSColor(calibratedRed: 0.985, green: 0.972, blue: 0.992, alpha: 1.0),
            NSColor(calibratedRed: 0.948, green: 0.958, blue: 0.988, alpha: 1.0),
            NSColor(calibratedRed: 1.000, green: 0.950, blue: 0.934, alpha: 1.0)
        ])?.draw(in: bounds, angle: -18)

        func glow(center: CGPoint, radius: CGFloat, color: NSColor) {
            let colors = [
                color.withAlphaComponent(0.62).cgColor,
                color.withAlphaComponent(0.0).cgColor
            ] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0]) else { return }
            context.drawRadialGradient(
                gradient,
                startCenter: center,
                startRadius: 0,
                endCenter: center,
                endRadius: radius,
                options: [.drawsAfterEndLocation]
            )
        }

        glow(
            center: CGPoint(x: bounds.minX + bounds.width * 0.18, y: bounds.minY + bounds.height * 0.92),
            radius: bounds.width * 0.38,
            color: NSColor(calibratedRed: 1.0, green: 0.71, blue: 0.66, alpha: 1.0)
        )
        glow(
            center: CGPoint(x: bounds.minX + bounds.width * 0.88, y: bounds.minY + bounds.height * 0.86),
            radius: bounds.width * 0.44,
            color: NSColor(calibratedRed: 0.66, green: 0.70, blue: 1.0, alpha: 1.0)
        )
        glow(
            center: CGPoint(x: bounds.minX + bounds.width * 0.52, y: bounds.minY + bounds.height * 0.45),
            radius: bounds.width * 0.24,
            color: NSColor(calibratedRed: 1.0, green: 0.87, blue: 0.93, alpha: 1.0)
        )

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
        context.setLineWidth(1)
        for offset in stride(from: -bounds.height, through: bounds.width, by: 86) {
            context.move(to: CGPoint(x: offset, y: bounds.maxY))
            context.addLine(to: CGPoint(x: offset + bounds.height, y: bounds.minY))
            context.strokePath()
        }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class AnimationChoiceView: NSView {
    let selection: String?
    private let imageView = NSImageView()
    private let checkBadge = NSView()
    private let checkView = NSImageView()
    private let dashedBorderLayer = CAShapeLayer()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private let isImport: Bool

    var onClick: (() -> Void)?
    var onDelete: (() -> Void)?

    init(selection: String?, imageURL: URL?, isImport: Bool = false, defaultStyle: BeaconStateStyle? = nil) {
        self.selection = selection
        self.isImport = isImport
        super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 118))
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.borderWidth = 1
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor(calibratedWhite: 0.45, alpha: 1).cgColor
        layer?.shadowOpacity = 0.06
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: -5)

        dashedBorderLayer.fillColor = NSColor.clear.cgColor
        dashedBorderLayer.lineWidth = 1.5
        dashedBorderLayer.lineDashPattern = [7, 7]
        dashedBorderLayer.isHidden = true
        layer?.addSublayer(dashedBorderLayer)

        imageView.image = isImport
            ? NSImage(systemSymbolName: "plus", accessibilityDescription: "Import GIF")
            : imageURL.flatMap(NSImage.init(contentsOf:))
        imageView.animates = !isImport && imageURL != nil
        imageView.isHidden = defaultStyle != nil
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = isImport ? NSColor.labelColor.withAlphaComponent(0.72) : nil
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        checkBadge.wantsLayer = true
        checkBadge.layer?.cornerRadius = 11
        checkBadge.layer?.backgroundColor = NSColor.systemGreen.cgColor
        checkBadge.layer?.shadowColor = NSColor.systemGreen.cgColor
        checkBadge.layer?.shadowOpacity = 0.18
        checkBadge.layer?.shadowRadius = 5
        checkBadge.layer?.shadowOffset = CGSize(width: 0, height: -1)
        checkBadge.translatesAutoresizingMaskIntoConstraints = false
        checkBadge.isHidden = true
        addSubview(checkBadge)

        checkView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Selected")
        checkView.contentTintColor = .white
        checkView.translatesAutoresizingMaskIntoConstraints = false
        checkBadge.addSubview(checkView)

        if let defaultStyle {
            let preview = NSView()
            preview.wantsLayer = true
            preview.layer?.cornerRadius = 8
            preview.layer?.backgroundColor = defaultStyle.backgroundColor.cgColor
            preview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(preview)

            let label = NSTextField(labelWithString: defaultStyle.text)
            label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            label.textColor = defaultStyle.foregroundColor
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            preview.addSubview(label)

            NSLayoutConstraint.activate([
                preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                preview.centerYAnchor.constraint(equalTo: centerYAnchor),
                preview.heightAnchor.constraint(equalToConstant: 36),
                label.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: preview.centerYAnchor)
            ])
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 128),
            heightAnchor.constraint(equalToConstant: 118),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: isImport ? 42 : 13),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: isImport ? -42 : -13),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: isImport ? 33 : 12),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: isImport ? -33 : -12),
            checkBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            checkBadge.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            checkBadge.widthAnchor.constraint(equalToConstant: 22),
            checkBadge.heightAnchor.constraint(equalToConstant: 22),
            checkView.centerXAnchor.constraint(equalTo: checkBadge.centerXAnchor),
            checkView.centerYAnchor.constraint(equalTo: checkBadge.centerYAnchor),
            checkView.widthAnchor.constraint(equalToConstant: 12),
            checkView.heightAnchor.constraint(equalToConstant: 12)
        ])
        updateAppearance(selected: false)
        toolTip = isImport ? "Import GIF" : (selection?.hasPrefix("custom:") == true ? "Select animation. Right-click to delete." : "Use default")
        setAccessibilityLabel(isImport ? "Import GIF" : (defaultStyle?.text ?? "Custom animation"))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = dashedBorderLayer.lineWidth / 2
        dashedBorderLayer.frame = bounds
        dashedBorderLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            cornerWidth: 15,
            cornerHeight: 15,
            transform: nil
        )
    }

    override func updateLayer() {
        super.updateLayer()
        refreshBorder()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let next = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self)
        addTrackingArea(next)
        trackingArea = next
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshBorder()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshBorder()
    }

    override func mouseDown(with event: NSEvent) {
        if event.type == .leftMouseDown {
            onClick?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard selection?.hasPrefix("custom:") == true else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Delete", action: #selector(deleteAnimation), keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete animation")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func deleteAnimation() {
        onDelete?()
    }

    func updateAppearance(selected: Bool) {
        checkBadge.isHidden = !selected || isImport
        layer?.borderWidth = selected && !isImport ? 1.4 : 1
        refreshBorder(selected: selected)
    }

    private func refreshBorder(selected: Bool? = nil) {
        let isSelected = selected ?? !checkBadge.isHidden
        if isImport {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
            dashedBorderLayer.isHidden = false
            dashedBorderLayer.strokeColor = (isHovered
                ? NSColor.labelColor.withAlphaComponent(0.50)
                : NSColor.labelColor.withAlphaComponent(0.30)).cgColor
            return
        }

        dashedBorderLayer.isHidden = true
        layer?.borderWidth = isSelected ? 1.4 : 1
        layer?.backgroundColor = (isHovered
            ? NSColor.controlBackgroundColor.withAlphaComponent(0.82)
            : NSColor.controlBackgroundColor.withAlphaComponent(0.62)).cgColor
        layer?.borderColor = isSelected
            ? NSColor.labelColor.withAlphaComponent(0.66).cgColor
            : (isHovered
                ? NSColor.separatorColor.withAlphaComponent(0.72)
                : NSColor.separatorColor.withAlphaComponent(0.46)).cgColor
    }
}

final class SidebarNavigationButton: NSControl {
    private let iconView = NSImageView()
    private let titleField: NSTextField
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    var isSelected = false {
        didSet { updateAppearance() }
    }

    init(title: String, symbolName: String) {
        titleField = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        image?.isTemplate = true
        iconView.image = image
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleField.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 42),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityLabel(title)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let next = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self)
        addTrackingArea(next)
        trackingArea = next
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    func iconFrame(relativeTo view: NSView) -> NSRect {
        iconView.convert(iconView.bounds, to: view)
    }

    private func updateAppearance() {
        let foreground = NSColor.labelColor
        layer?.backgroundColor = isSelected
            ? NSColor.labelColor.withAlphaComponent(0.14).cgColor
            : (isHovered ? NSColor.labelColor.withAlphaComponent(0.07).cgColor : NSColor.clear.cgColor)
        iconView.contentTintColor = foreground.withAlphaComponent(isSelected ? 0.94 : 0.66)
        titleField.textColor = foreground.withAlphaComponent(isSelected ? 0.96 : 0.74)
        titleField.font = NSFont.systemFont(ofSize: 14, weight: isSelected ? .bold : .semibold)
    }
}

final class BeaconSegmentedControl: NSControl {
    private let selectedBackground = NSView()
    private let labels: [NSTextField]
    private var selectedLeadingConstraint: NSLayoutConstraint!
    var selectedSegment = 0 {
        didSet {
            guard selectedSegment != oldValue else { return }
            updateSelection()
        }
    }

    init(labels titles: [String]) {
        precondition(titles.count == 2)
        labels = titles.map(NSTextField.init(labelWithString:))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.045).cgColor
        layer?.borderWidth = 0

        selectedBackground.wantsLayer = true
        selectedBackground.layer?.cornerRadius = 7
        selectedBackground.layer?.backgroundColor = NSColor(calibratedWhite: 0.72, alpha: 0.34).cgColor
        selectedBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(selectedBackground)

        for (index, label) in labels.enumerated() {
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)

            let button = NSButton(title: "", target: self, action: #selector(selectSegment(_:)))
            button.tag = index
            button.isBordered = false
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)

            NSLayoutConstraint.activate([
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.widthAnchor.constraint(equalToConstant: 84),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(index) * 84),
                button.topAnchor.constraint(equalTo: topAnchor),
                button.bottomAnchor.constraint(equalTo: bottomAnchor),
                button.widthAnchor.constraint(equalToConstant: 84),
                button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(index) * 84)
            ])
        }

        selectedLeadingConstraint = selectedBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 168),
            heightAnchor.constraint(equalToConstant: 28),
            selectedLeadingConstraint,
            selectedBackground.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            selectedBackground.widthAnchor.constraint(equalToConstant: 82),
            selectedBackground.heightAnchor.constraint(equalToConstant: 24)
        ])
        updateSelection()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func selectSegment(_ sender: NSButton) {
        selectedSegment = sender.tag
        sendAction(action, to: target)
    }

    private func updateSelection() {
        selectedLeadingConstraint?.constant = selectedSegment == 0 ? 2 : 84
        for (index, label) in labels.enumerated() {
            let selected = index == selectedSegment
            label.font = NSFont.systemFont(ofSize: 12, weight: selected ? .bold : .semibold)
            label.textColor = selected ? NSColor.labelColor.withAlphaComponent(0.94) : NSColor.labelColor.withAlphaComponent(0.56)
        }
        needsLayout = true
    }
}

final class SettingsViewController: NSViewController {
    private static let maximumAnimationChoicesPerRow = 5
    private let isLayoutProbe = ProcessInfo.processInfo.arguments.contains("--layout-probe")
    private enum Page: Int, CaseIterable {
        case general
        case animations
        case connections

        var title: String {
            switch self {
            case .general: return "General"
            case .animations: return "Animations"
            case .connections: return "Connections"
            }
        }

        var symbolName: String {
            switch self {
            case .general: return "gearshape"
            case .animations: return "sparkles.rectangle.stack"
            case .connections: return "link"
            }
        }
    }

    private let configStore: ConfigStore
    private let hookInstaller: HookInstaller
    private let mobileNotifications: MobileNotificationsManager
    private let usageSnapshotProvider: () -> CodexUsageSnapshot?
    private let onChange: () -> Void
    private let onAnimationPreview: (BeaconState) -> Void
    private let touchBarSwitch = BeaconSwitch()
    private let soundSwitch = BeaconSwitch()
    private let menuBarSwitch = BeaconSwitch()
    private let usageControl = BeaconSegmentedControl(labels: ["5 Hours", "Weekly"])
    private let hooksButton = NSButton(title: "Install Hooks", target: nil, action: nil)
    private let hooksStatusDot = StatusDotView()
    private let hooksStatusLabel = NSTextField(labelWithString: "Checking")
    private let mobileStatusDot = StatusDotView()
    private let mobileStatusLabel = NSTextField(labelWithString: "Not Configured")
    private let barkURLField = PasteableTextField(string: "")
    private let testNotificationButton = NSButton(title: "Connect", target: nil, action: nil)
    private let mobileMoreButton = NSButton()
    private var barkURLGridRow: NSGridRow?
    private var isServerReady = false
    private var isTestingMobileNotifications = false
    private var mobileStatusOverride: (text: String, color: NSColor, detail: String?)?
    private var animationChoices: [BeaconState: [AnimationChoiceView]] = [:]
    private var pages: [Page: NSView] = [:]
    private var navigationButtons: [Page: SidebarNavigationButton] = [:]
    private var sidebarView: NSView?
    private var contentHostView: NSView?
    private var animationSectionViews: [NSView] = []
    private var animationHeading: NSTextField?
    private var selectedPage: Page = .animations

    init(
        configStore: ConfigStore,
        hookInstaller: HookInstaller,
        mobileNotifications: MobileNotificationsManager,
        isServerReady: Bool,
        usageSnapshotProvider: @escaping () -> CodexUsageSnapshot?,
        onAnimationPreview: @escaping (BeaconState) -> Void,
        onChange: @escaping () -> Void
    ) {
        self.configStore = configStore
        self.hookInstaller = hookInstaller
        self.mobileNotifications = mobileNotifications
        self.isServerReady = isServerReady
        self.usageSnapshotProvider = usageSnapshotProvider
        self.onAnimationPreview = onAnimationPreview
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        animationChoices.removeAll()
        pages.removeAll()
        navigationButtons.removeAll()
        animationSectionViews.removeAll()
        animationHeading = nil

        let root = SettingsAtmosphereView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
        root.wantsLayer = true
        root.layer?.cornerRadius = 18
        root.layer?.masksToBounds = true

        let windowTitle = NSTextField(labelWithString: "Codex Beacon")
        windowTitle.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        windowTitle.textColor = NSColor.labelColor.withAlphaComponent(0.58)
        windowTitle.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(windowTitle, positioned: .above, relativeTo: nil)

        configureControls()

        let sidebar = makeSidebar()
        sidebarView = sidebar
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        contentHostView = content

        pages = [
            .general: makeGeneralPage(),
            .animations: makeAnimationsPage(),
            .connections: makeConnectionsPage()
        ]
        for pageView in pages.values {
            pageView.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(pageView)
            NSLayoutConstraint.activate([
                pageView.topAnchor.constraint(equalTo: content.topAnchor),
                pageView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                pageView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                pageView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
            ])
        }

        NSLayoutConstraint.activate([
            windowTitle.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            windowTitle.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 220),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        touchBarSwitch.target = self
        touchBarSwitch.action = #selector(touchBarChanged)
        soundSwitch.target = self
        soundSwitch.action = #selector(soundChanged)
        menuBarSwitch.target = self
        menuBarSwitch.action = #selector(menuBarChanged)
        usageControl.target = self
        usageControl.action = #selector(usageChanged)
        hooksButton.target = self
        hooksButton.action = #selector(installHooks)
        testNotificationButton.target = self
        testNotificationButton.action = #selector(testMobileNotification)
        mobileMoreButton.target = self
        mobileMoreButton.action = #selector(showMobileMenu)

        self.view = root
        showPage(selectedPage)
        refresh()
    }

    func layoutDiagnostics() -> String {
        view.layoutSubtreeIfNeeded()
        var lines: [String] = []
        var failures: [String] = []

        func record(_ name: String, _ frame: NSRect) {
            lines.append("\(name)=x:\(Int(frame.minX)),y:\(Int(frame.minY)),w:\(Int(frame.width)),h:\(Int(frame.height))")
        }

        if let sidebarView {
            let frame = sidebarView.convert(sidebarView.bounds, to: view)
            record("sidebar", frame)
            if abs(frame.width - 220) > 1 { failures.append("sidebar width") }
        }
        if let contentHostView {
            let frame = contentHostView.convert(contentHostView.bounds, to: view)
            record("content", frame)
            if abs(frame.minX - 220) > 1 { failures.append("content x") }
        }
        for page in Page.allCases {
            guard let button = navigationButtons[page] else {
                failures.append("navigation \(page.title) missing")
                continue
            }
            let frame = button.convert(button.bounds, to: view)
            let iconFrame = button.iconFrame(relativeTo: view)
            record("navigation.\(page.title)", frame)
            record("navigation.\(page.title).icon", iconFrame)
            if abs(frame.minX - 20) > 1 || abs(frame.width - 180) > 1 {
                failures.append("navigation \(page.title) inset")
            }
            if iconFrame.minX < frame.minX || iconFrame.maxX > frame.maxX {
                failures.append("navigation \(page.title) icon")
            }
        }
        if let animationHeading {
            let frame = animationHeading.convert(animationHeading.bounds, to: view)
            record("animation.heading", frame)
            if abs(frame.minX - 257) > 2 { failures.append("heading x") }
        }
        for (index, section) in animationSectionViews.enumerated() {
            let frame = section.convert(section.bounds, to: view)
            record("animation.section.\(index)", frame)
            if abs(frame.minX - 257) > 2 { failures.append("section \(index) x") }
            if abs(frame.width - 806) > 2 { failures.append("section \(index) width") }
        }
        for state in [BeaconState.idle, .needsYou, .done] {
            if let choices = animationChoices[state], let first = choices.first {
                let frame = first.convert(first.bounds, to: view)
                record("animation.choice.\(state.rawValue)", frame)
                if abs(frame.minX - 257) > 2 { failures.append("choice \(state.rawValue) x") }
                if abs(frame.width - 128) > 1 || abs(frame.height - 118) > 1 {
                    failures.append("choice \(state.rawValue) size")
                }
                if first.selection != "default:\(state.rawValue)" {
                    failures.append("choice \(state.rawValue) default order")
                }
                if choices.count > Self.maximumAnimationChoicesPerRow {
                    failures.append("choice \(state.rawValue) count")
                }
                if let section = animationSectionViews.first(where: { section in
                    section.convert(section.bounds, to: view).minY <= frame.minY
                        && section.convert(section.bounds, to: view).maxY >= frame.maxY
                }) {
                    let sectionFrame = section.convert(section.bounds, to: view)
                    for choice in choices {
                        let choiceFrame = choice.convert(choice.bounds, to: view)
                        if choiceFrame.maxX > sectionFrame.maxX + 1 {
                            failures.append("choice \(state.rawValue) overflow")
                            break
                        }
                    }
                }
            }
        }
        lines.append(failures.isEmpty ? "result=passed" : "result=failed:\(failures.joined(separator: ","))")
        return lines.joined(separator: "\n") + "\n"
    }

    func refresh() {
        touchBarSwitch.state = configStore.config.touchBarVisual ? .on : .off
        soundSwitch.state = configStore.config.sound ? .on : .off
        menuBarSwitch.state = configStore.config.showsMenuBarUsage ? .on : .off
        usageControl.selectedSegment = configStore.config.selectedUsageWindow == .fiveHour ? 0 : 1
        refreshHooks()
        refreshMobileNotifications()
        refreshAnimationChoices()
    }

    func setServerReady(_ ready: Bool) {
        isServerReady = ready
        refresh()
    }

    private func configureControls() {
        [hooksButton, testNotificationButton].forEach {
            $0.bezelStyle = .rounded
            $0.controlSize = .small
            $0.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            $0.widthAnchor.constraint(equalToConstant: 84).isActive = true
        }

        mobileMoreButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "iPhone notification options")
        mobileMoreButton.bezelStyle = .inline
        mobileMoreButton.isBordered = false
        mobileMoreButton.toolTip = "iPhone notification options"
        mobileMoreButton.setAccessibilityLabel("iPhone notification options")
        mobileMoreButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
    }

    private func grid(rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.columnSpacing = 18
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing
        for index in 0..<rows.count {
            grid.row(at: index).height = 32
            grid.row(at: index).yPlacement = .center
        }
        return grid
    }

    private func rowLabel(_ text: String, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: secondary ? 11 : 13, weight: .medium)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        return label
    }

    private func makeSidebar() -> NSView {
        let sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.36).cgColor

        let navigation = NSStackView()
        navigation.orientation = .vertical
        navigation.alignment = .width
        navigation.spacing = 11
        navigation.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(navigation)

        for page in Page.allCases {
            let button = SidebarNavigationButton(title: page.title, symbolName: page.symbolName)
            button.target = self
            button.action = #selector(selectPage(_:))
            button.tag = page.rawValue
            navigation.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: navigation.widthAnchor).isActive = true
            navigationButtons[page] = button
        }

        NSLayoutConstraint.activate([
            navigation.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 118),
            navigation.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            navigation.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -20)
        ])
        return sidebar
    }

    private func makeGeneralPage() -> NSView {
        let settingsGrid = grid(rows: [
            [rowLabel("Touch Bar"), touchBarSwitch],
            [rowLabel("Sounds"), soundSwitch],
            [rowLabel("Menu Bar"), menuBarSwitch],
            [rowLabel("Usage"), usageControl]
        ])
        return makePage(title: "General", content: makeGroup(containing: settingsGrid, height: 208))
    }

    private func makeConnectionsPage() -> NSView {
        let urlRow = barkConnectionRow()
        let connectionsGrid = grid(rows: [
            [hookStatusControl(), hooksActionsControl()],
            [mobileStatusControl(), mobileActionsControl()],
            [rowLabel("Bark Push URL", secondary: true), urlRow]
        ])
        barkURLGridRow = connectionsGrid.row(at: 2)
        return makePage(title: "Connections", content: makeGroup(containing: connectionsGrid, height: 164))
    }

    private func makeAnimationsPage() -> NSView {
        let page = NSView()

        let sections = [
            animationSection(for: .idle),
            animationSection(for: .needsYou),
            animationSection(for: .done)
        ]
        animationSectionViews = sections
        sections.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            page.addSubview($0)
        }

        NSLayoutConstraint.activate([
            sections[0].topAnchor.constraint(equalTo: page.topAnchor, constant: 86),
            sections[0].leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 37),
            sections[0].trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -37),

            sections[1].topAnchor.constraint(equalTo: sections[0].bottomAnchor, constant: 10),
            sections[1].leadingAnchor.constraint(equalTo: sections[0].leadingAnchor),
            sections[1].trailingAnchor.constraint(equalTo: sections[0].trailingAnchor),

            sections[2].topAnchor.constraint(equalTo: sections[1].bottomAnchor, constant: 10),
            sections[2].leadingAnchor.constraint(equalTo: sections[0].leadingAnchor),
            sections[2].trailingAnchor.constraint(equalTo: sections[0].trailingAnchor),
            sections[2].bottomAnchor.constraint(lessThanOrEqualTo: page.bottomAnchor, constant: -24)
        ])
        return page
    }

    private func makePage(title _: String, content: NSView) -> NSView {
        let page = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: page.topAnchor, constant: 88),
            content.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 37),
            content.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -37),
            content.bottomAnchor.constraint(lessThanOrEqualTo: page.bottomAnchor, constant: -36)
        ])
        return page
    }

    private func makeGroup(containing content: NSView, height: CGFloat) -> NSView {
        let group = NSView()
        group.wantsLayer = true
        group.layer?.cornerRadius = 10

        let material = NSVisualEffectView()
        material.material = .contentBackground
        material.blendingMode = .withinWindow
        material.state = .active
        material.alphaValue = 0.52
        material.translatesAutoresizingMaskIntoConstraints = false
        group.addSubview(material)

        content.translatesAutoresizingMaskIntoConstraints = false
        group.addSubview(content)
        NSLayoutConstraint.activate([
            group.heightAnchor.constraint(equalToConstant: height),
            material.leadingAnchor.constraint(equalTo: group.leadingAnchor),
            material.trailingAnchor.constraint(equalTo: group.trailingAnchor),
            material.topAnchor.constraint(equalTo: group.topAnchor),
            material.bottomAnchor.constraint(equalTo: group.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -20),
            content.centerYAnchor.constraint(equalTo: group.centerYAnchor)
        ])
        return group
    }

    private func animationSection(for state: BeaconState) -> NSView {
        let section = NSView()

        let label = NSTextField(labelWithString: animationTitle(for: state))
        label.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        label.textColor = NSColor.labelColor.withAlphaComponent(0.86)
        label.translatesAutoresizingMaskIntoConstraints = false
        section.addSubview(label)

        var choices: [AnimationChoiceView] = []
        let defaultSelection = "default:\(state.rawValue)"
        choices.append(AnimationChoiceView(
            selection: defaultSelection,
            imageURL: nil,
            defaultStyle: BeaconPreset.default.style(for: state)
        ))

        let maximumCustomAnimations = Self.maximumAnimationChoicesPerRow - 2
        var availableCustomAnimations = configStore.customAnimationSelections(for: state)
        if let selected = configStore.animationSelection(for: state),
           let selectedIndex = availableCustomAnimations.firstIndex(of: selected),
           selectedIndex != 0 {
            availableCustomAnimations.insert(availableCustomAnimations.remove(at: selectedIndex), at: 0)
        }
        let customSelections = Array(availableCustomAnimations.prefix(maximumCustomAnimations))
        for selection in customSelections {
            let imageURL = isLayoutProbe ? nil : configStore.animationURL(for: selection)
            choices.append(AnimationChoiceView(selection: selection, imageURL: imageURL))
        }

        if choices.count < Self.maximumAnimationChoicesPerRow {
            choices.append(AnimationChoiceView(selection: nil, imageURL: nil, isImport: true))
        }
        animationChoices[state] = choices

        for choice in choices {
            choice.onClick = { [weak self, weak choice] in
                guard let self, let choice else { return }
                if choice.selection == nil {
                    self.importAnimation(for: state)
                } else if choice.selection == defaultSelection {
                    self.selectDefaultAnimation(for: state)
                } else {
                    self.toggleAnimation(choice.selection!, for: state)
                }
            }
            if let selection = choice.selection, selection.hasPrefix("custom:") {
                choice.onDelete = { [weak self] in
                    self?.deleteAnimation(selection, for: state)
                }
            }
        }

        let row = NSStackView(views: choices)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 20
        row.translatesAutoresizingMaskIntoConstraints = false
        section.addSubview(row)

        NSLayoutConstraint.activate([
            section.heightAnchor.constraint(equalToConstant: 154),
            label.topAnchor.constraint(equalTo: section.topAnchor),
            label.leadingAnchor.constraint(equalTo: section.leadingAnchor),
            row.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: section.leadingAnchor),
            row.heightAnchor.constraint(equalToConstant: 118)
        ])
        return section
    }

    @objc private func selectPage(_ sender: SidebarNavigationButton) {
        guard let page = Page(rawValue: sender.tag) else { return }
        selectedPage = page
        showPage(page)
    }

    private func showPage(_ page: Page) {
        for (candidate, pageView) in pages {
            pageView.isHidden = candidate != page
        }
        for (candidate, button) in navigationButtons {
            button.isSelected = candidate == page
        }
    }

    private func animationTitle(for state: BeaconState) -> String {
        switch state {
        case .idle: return "Idle"
        case .needsYou: return "Needs You"
        case .done: return "Done"
        }
    }

    private func refreshAnimationChoices() {
        for (state, choices) in animationChoices {
            let selected = configStore.animationSelection(for: state)
            for choice in choices {
                let isDefault = choice.selection == "default:\(state.rawValue)"
                choice.updateAppearance(selected: isDefault ? selected == nil : choice.selection == selected)
            }
        }
    }

    private func selectDefaultAnimation(for state: BeaconState) {
        configStore.setAnimation(nil, for: state)
        refreshAnimationChoices()
        onChange()
        onAnimationPreview(state)
    }

    private func toggleAnimation(_ selection: String, for state: BeaconState) {
        let nextSelection = configStore.animationSelection(for: state) == selection ? nil : selection
        configStore.setAnimation(nextSelection, for: state)
        refreshAnimationChoices()
        onChange()
        onAnimationPreview(state)
    }

    private func importAnimation(for state: BeaconState) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gif]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a GIF for \(animationTitle(for: state))"
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        do {
            _ = try configStore.importAnimation(from: sourceURL, for: state)
            rebuildView()
            onChange()
            onAnimationPreview(state)
        } catch {
            showAlert(title: "Could Not Import GIF", message: error.localizedDescription)
        }
    }

    private func deleteAnimation(_ selection: String, for state: BeaconState) {
        let alert = NSAlert()
        alert.messageText = "Delete this animation?"
        alert.informativeText = "The imported copy will be removed from Codex Beacon."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try configStore.deleteAnimation(selection, for: state)
            rebuildView()
            onChange()
        } catch {
            showAlert(title: "Could Not Delete GIF", message: error.localizedDescription)
        }
    }

    private func rebuildView() {
        animationChoices.removeAll()
        loadView()
    }

    private func hookStatusControl() -> NSView {
        hooksStatusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let status = NSStackView(views: [hooksStatusDot, hooksStatusLabel])
        status.orientation = .horizontal
        status.alignment = .centerY
        status.spacing = 9
        return status
    }

    private func mobileStatusControl() -> NSView {
        mobileStatusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let status = NSStackView(views: [mobileStatusDot, mobileStatusLabel])
        status.orientation = .horizontal
        status.alignment = .centerY
        status.spacing = 9
        return status
    }

    private func mobileActionsControl() -> NSView {
        let actions = NSStackView(views: [testNotificationButton, mobileMoreButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        return actions
    }

    private func hooksActionsControl() -> NSView {
        return hooksButton
    }

    private func barkConnectionRow() -> NSView {
        barkURLField.placeholderString = "https://api.day.app/..."
        barkURLField.toolTip = "Paste the Push URL copied from Bark."
        barkURLField.controlSize = .small
        barkURLField.font = NSFont.systemFont(ofSize: 12)
        barkURLField.isEditable = true
        barkURLField.isSelectable = true
        barkURLField.widthAnchor.constraint(equalToConstant: 250).isActive = true
        return barkURLField
    }

    private func refreshMobileNotifications() {
        let configured = mobileNotifications.isConfigured
        let requiresReconnect = mobileNotifications.requiresReconnect
        if isTestingMobileNotifications {
            mobileStatusLabel.stringValue = "iPhone Testing"
            mobileStatusDot.setColor(.systemOrange, tooltip: "Sending a test notification")
        } else if let mobileStatusOverride {
            mobileStatusLabel.stringValue = "iPhone \(mobileStatusOverride.text)"
            mobileStatusDot.setColor(mobileStatusOverride.color, tooltip: mobileStatusOverride.detail ?? mobileStatusOverride.text)
        } else if configured {
            mobileStatusLabel.stringValue = "iPhone Connected"
            mobileStatusDot.setColor(.systemGreen, tooltip: "Bark notifications configured")
        } else if requiresReconnect {
            mobileStatusLabel.stringValue = "iPhone Reconnect Required"
            mobileStatusDot.setColor(.systemOrange, tooltip: "Paste the Bark Push URL and test again")
        } else {
            mobileStatusLabel.stringValue = "iPhone Not Connected"
            mobileStatusDot.setColor(.systemGray, tooltip: "Paste a Bark URL and test it")
        }

        testNotificationButton.title = configured ? "Send Test" : "Connect"
        mobileMoreButton.isHidden = !configured
        mobileMoreButton.isEnabled = configured && !isTestingMobileNotifications
        barkURLGridRow?.isHidden = configured
        barkURLField.isEnabled = !isTestingMobileNotifications
        testNotificationButton.isEnabled = !isTestingMobileNotifications
    }

    private func refreshHooks() {
        let state = hookInstaller.state()
        switch state {
        case .installed:
            hooksStatusLabel.stringValue = "Hooks"
            hooksStatusDot.setColor(isServerReady ? .systemGreen : .systemRed, tooltip: isServerReady ? "Hooks active" : "Local service unavailable")
            hooksButton.title = "Repair"
            hooksButton.toolTip = "Reinstall Codex hooks"
            hooksButton.isEnabled = true
            hooksButton.isHidden = false
        case .invalid:
            hooksStatusLabel.stringValue = "Hooks"
            hooksStatusDot.setColor(.systemOrange, tooltip: state.detail)
            hooksButton.title = "Repair"
            hooksButton.toolTip = state.detail
            hooksButton.isEnabled = true
            hooksButton.isHidden = false
        case .moveToApplications:
            hooksStatusLabel.stringValue = "Hooks Need App in Applications"
            hooksStatusDot.setColor(.systemOrange, tooltip: state.detail)
            hooksButton.title = "Move"
            hooksButton.toolTip = state.detail
            hooksButton.isEnabled = true
            hooksButton.isHidden = false
        case .missing:
            hooksStatusLabel.stringValue = "Hooks"
            hooksStatusDot.setColor(.systemGray, tooltip: state.detail)
            hooksButton.title = "Install"
            hooksButton.toolTip = state.detail
            hooksButton.isEnabled = state.canInstall
            hooksButton.isHidden = false
        }
    }

    @objc private func touchBarChanged() {
        configStore.setTouchBarVisual(touchBarSwitch.state == .on)
        onChange()
    }

    @objc private func soundChanged() {
        configStore.setSound(soundSwitch.state == .on)
        onChange()
    }

    @objc private func menuBarChanged() {
        configStore.setMenuBarUsage(menuBarSwitch.state == .on)
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
                self.showAlert(title: "Bark Test Failed", message: error.localizedDescription)
            }
            self.refreshMobileNotifications()
        }
    }

    @objc private func showMobileMenu() {
        let menu = NSMenu()
        let disconnect = NSMenuItem(title: "Disconnect Bark", action: #selector(disconnectMobileNotifications), keyEquivalent: "")
        disconnect.target = self
        menu.addItem(disconnect)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: mobileMoreButton.bounds.height + 4), in: mobileMoreButton)
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
    private var state: BeaconState = .idle
    private var animationURL: URL?
    private var usageDisplay: CodexUsageDisplay?
    private var usageShouldPulse = false
    private var completionAnimationWorkItem: DispatchWorkItem?
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

    func setState(_ nextState: BeaconState, style nextStyle: BeaconStateStyle, animationURL nextAnimationURL: URL?) {
        state = nextState
        style = nextStyle
        animationURL = nextAnimationURL
        updateViews()
    }

    func setUsage(_ display: CodexUsageDisplay?, pulse: Bool = false) {
        usageDisplay = display
        usageShouldPulse = pulse
        updateViews()
    }

    func previewAnimation(for previewState: BeaconState, url: URL, duration: TimeInterval = 3.0) {
        completionAnimationWorkItem?.cancel()
        modalItem.view = animatedTouchBarView(state: previewState, url: url, usageDisplay: usageDisplay)
        present()

        let workItem = DispatchWorkItem { [weak self] in
            self?.updateViews()
        }
        completionAnimationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
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
        modalItem.view = fullTouchBarView(
            state: state,
            style: style,
            usageDisplay: usageDisplay,
            animationURL: animationURL,
            pulse: shouldPulse
        )
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

    private func fullTouchBarView(
        state: BeaconState,
        style: BeaconStateStyle,
        usageDisplay: CodexUsageDisplay?,
        animationURL: URL?,
        pulse: Bool
    ) -> NSView {
        if let animationURL {
            return animatedTouchBarView(state: state, url: animationURL, usageDisplay: usageDisplay)
        }

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

    private func animatedTouchBarView(state: BeaconState, url: URL, usageDisplay: CodexUsageDisplay?) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 980, height: 36))
        guard let image = NSImage(contentsOf: url) else { return container }

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedRed: 0.165, green: 0.129, blue: 0.106, alpha: 1.0).cgColor
        content.layer?.cornerRadius = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)

        let imageView = NSImageView(image: image)
        imageView.animates = true
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(imageView)

        var constraints = [
            content.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            content.heightAnchor.constraint(equalToConstant: 32),
            imageView.topAnchor.constraint(equalTo: content.topAnchor, constant: 2),
            imageView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -2)
        ]

        switch state {
        case .idle where usageDisplay != nil:
            let separator = NSView()
            separator.wantsLayer = true
            separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
            separator.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(separator)

            let usage = NSTextField(labelWithString: usageDisplay!.text)
            usage.textColor = usageTextColor(for: usageDisplay!)
            usage.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            usage.alignment = .right
            usage.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(usage)

            constraints += [
                content.widthAnchor.constraint(equalToConstant: 310),
                imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
                imageView.widthAnchor.constraint(equalToConstant: 104),
                separator.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 7),
                separator.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                separator.widthAnchor.constraint(equalToConstant: 1),
                separator.heightAnchor.constraint(equalToConstant: 18),
                usage.leadingAnchor.constraint(equalTo: separator.trailingAnchor, constant: 12),
                usage.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
                usage.centerYAnchor.constraint(equalTo: content.centerYAnchor)
            ]
        case .needsYou:
            let label = NSTextField(labelWithString: "Needs You")
            label.textColor = style.foregroundColor
            label.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
            label.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(label)
            constraints += [
                content.widthAnchor.constraint(equalToConstant: 280),
                imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                imageView.widthAnchor.constraint(equalToConstant: 160),
                label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 10),
                label.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
                label.centerYAnchor.constraint(equalTo: content.centerYAnchor)
            ]
        default:
            constraints += [
                content.widthAnchor.constraint(equalToConstant: 280),
                imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
                imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10)
            ]
        }

        NSLayoutConstraint.activate(constraints)
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
        setupMainMenu()
        setupWindow()
        setupMenuBar()
        setupServer()
        touchBarBeacon.install()
        applyConfig()
        setupUsageRefresh()
        showSettings()

    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
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
            },
            onAnimationPreview: { [weak self] state in
                self?.previewAnimation(for: state)
            }
        ) { [weak self] in
            self?.applyConfig()
        }
        settingsController = controller

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Beacon"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
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
        touchBarBeacon.setState(.idle, style: idleStyle, animationURL: configStore.animationURL(for: .idle))
        refreshUsageDisplay()
        touchBarBeacon.setEnabled(configStore.config.touchBarVisual)
        refreshStatusItem(snapshot: usageMonitor.cachedSnapshot(), style: idleStyle)
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
            touchBarBeacon.setState(state, style: style, animationURL: configStore.animationURL(for: state))
            touchBarBeacon.present()
        }

        if configStore.config.sound, state != .idle, let sound = style.sound {
            NSSound(named: NSSound.Name(sound))?.play()
        }

        refreshStatusItem(snapshot: usageMonitor.cachedSnapshot(), style: style)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.configStore.reload()
            self.presetStore.reload(activePresetName: self.configStore.config.presetName)
            self.currentState = .idle
            let idleStyle = self.presetStore.preset.style(for: .idle)
            self.touchBarBeacon.setState(.idle, style: idleStyle, animationURL: self.configStore.animationURL(for: .idle))
            self.refreshUsageDisplay()
            if self.configStore.config.touchBarVisual {
                self.touchBarBeacon.present()
            }
            self.refreshStatusItem(snapshot: self.usageMonitor.cachedSnapshot(), style: idleStyle)
        }
        resetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private func previewAnimation(for state: BeaconState) {
        configStore.reload()
        guard configStore.config.touchBarVisual,
              let url = configStore.animationURL(for: state) else { return }
        touchBarBeacon.previewAnimation(for: state, url: url)
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
        refreshStatusItem(snapshot: snapshot)
        publishWidgetSnapshotIfNeeded(snapshot, enabled: publishWidgetUpdate)

        if playRecoverySound && usageDisplay.isReady && configStore.config.sound {
            NSSound(named: NSSound.Name("Ping"))?.play()
        }
    }

    private func clearUsageDisplay() {
        if currentState == .idle {
            touchBarBeacon.setUsage(nil)
        }
        refreshStatusItem(snapshot: usageMonitor.cachedSnapshot())
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

    private func refreshStatusItem(
        snapshot: CodexUsageSnapshot?,
        style: BeaconStateStyle? = nil
    ) {
        guard let button = statusItem?.button else { return }
        let resolvedStyle = style ?? presetStore.preset.style(for: currentState)

        guard configStore.config.showsMenuBarUsage else {
            button.image = nil
            button.imagePosition = .noImage
            button.title = resolvedStyle.resolvedMenuIcon
            button.toolTip = "Codex Beacon"
            return
        }

        button.image = nil
        button.imagePosition = .noImage
        let usageIcon = presetStore.preset.style(for: .idle).resolvedMenuIcon

        let selection = configStore.config.selectedUsageWindow
        guard let window = snapshot?.window(for: selection) else {
            button.title = "\(usageIcon) —"
            button.toolTip = "Codex usage unavailable"
            return
        }

        button.title = "\(usageIcon) \(Int(window.remainingPercent.rounded()))%"
        button.toolTip = "\(window.label) · resets \(window.resetDisplayText)"
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

if ProcessInfo.processInfo.arguments.contains("--layout-probe") {
    let configStore = ConfigStore()
    let controller = SettingsViewController(
        configStore: configStore,
        hookInstaller: HookInstaller(),
        mobileNotifications: MobileNotificationsManager(appSupportDirectory: configStore.directoryURL),
        isServerReady: true,
        usageSnapshotProvider: { nil },
        onAnimationPreview: { _ in },
        onChange: {}
    )
    let probeWindow = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
        styleMask: [.titled, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    probeWindow.contentViewController = controller
    probeWindow.contentView?.layoutSubtreeIfNeeded()
    let report = controller.layoutDiagnostics()
    try? report.write(
        to: URL(fileURLWithPath: "/tmp/codex-beacon-layout-report.txt"),
        atomically: true,
        encoding: .utf8
    )
    exit(report.contains("result=passed") ? EXIT_SUCCESS : EXIT_FAILURE)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
