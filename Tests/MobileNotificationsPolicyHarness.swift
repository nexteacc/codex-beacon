import Foundation

enum UsageWindowSelection: String, Codable, Equatable, CaseIterable {
    case fiveHour
    case weekly
}

struct CodexUsageWindow: Codable, Equatable {
    let label: String
    let usedPercent: Double
    let remainingPercent: Double
    let windowMinutes: Int
    let resetsAt: Int
    let resetsAtLocal: String
    let resetInSeconds: Int
}

struct CodexUsageSnapshot: Codable, Equatable {
    let ok: Bool
    let updatedAt: String
    let planType: String?
    let rateLimitReachedType: String?
    let primary: CodexUsageWindow
    let secondary: CodexUsageWindow?

    func window(for selection: UsageWindowSelection) -> CodexUsageWindow? {
        selection == .fiveHour ? primary : secondary
    }

    func isLimited(window: CodexUsageWindow, selection: UsageWindowSelection) -> Bool {
        window.remainingPercent <= 0
    }
}

private func usageWindow(label: String, remaining: Double, minutes: Int, reset: Int) -> CodexUsageWindow {
    CodexUsageWindow(
        label: label,
        usedPercent: 100 - remaining,
        remainingPercent: remaining,
        windowMinutes: minutes,
        resetsAt: reset,
        resetsAtLocal: "",
        resetInSeconds: reset - Int(Date().timeIntervalSince1970)
    )
}

private func snapshot(remaining: Double, weeklyRemaining: Double? = nil, reset: Int) -> CodexUsageSnapshot {
    CodexUsageSnapshot(
        ok: true,
        updatedAt: ISO8601DateFormatter().string(from: Date()),
        planType: nil,
        rateLimitReachedType: nil,
        primary: usageWindow(label: "5h", remaining: remaining, minutes: 300, reset: reset),
        secondary: weeklyRemaining.map {
            usageWindow(label: "Weekly", remaining: $0, minutes: 10_080, reset: reset + 86_400)
        }
    )
}

@main
enum MobileNotificationsPolicyHarness {
    static func main() throws {
        let directory = URL(fileURLWithPath: "/tmp/codexbeacon-policy-harness", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try verifyCredentialFile(in: directory)
        try verifyNotificationTransactions(in: directory.appendingPathComponent("transactions"))
        try verifyThresholdJump(in: directory.appendingPathComponent("jump"))
        verifyTestNotificationLayout()
        verifyBarkURLParsing()
        print("mobile notification policy harness passed")
    }

    private static func verifyCredentialFile(in directory: URL) throws {
        let store = BarkDeviceKeyStore(appSupportDirectory: directory)
        try store.save("local-test-key")
        precondition(store.load() == "local-test-key")

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("bark-device-key").path
        )
        precondition((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        precondition((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        try store.delete()
        precondition(store.load() == nil)
    }

    private static func verifyNotificationTransactions(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reset = Int(Date().timeIntervalSince1970) + 18_000
        let policy = UsageNotificationPolicy(appSupportDirectory: directory)

        precondition(policy.notification(for: snapshot(remaining: 60, reset: reset)) == nil)

        let firstAttempt = policy.notification(for: snapshot(remaining: 47, reset: reset))
        precondition(firstAttempt?.body.contains("47%") == true)
        policy.rollbackPendingNotification()

        let retry = policy.notification(for: snapshot(remaining: 47, reset: reset))
        precondition(retry?.body.contains("47%") == true)
        policy.commitPendingNotification()
        precondition(policy.hasPersistedState)
        precondition(policy.notification(for: snapshot(remaining: 47, reset: reset)) == nil)

        precondition(policy.notification(for: snapshot(remaining: 7, reset: reset))?.body.contains("7%") == true)
        policy.commitPendingNotification()

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        let expectedReset = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(reset)))
        let exhausted = policy.notification(for: snapshot(remaining: 0, reset: reset))
        precondition(exhausted?.body.contains("Back \(expectedReset)") == true)
        precondition(exhausted?.body.contains(" in ") == false)
        policy.commitPendingNotification()
        precondition(policy.notification(for: snapshot(remaining: 0, reset: reset)) == nil)

        let recoveredSnapshot = snapshot(remaining: 100, reset: reset + 18_000)
        precondition(policy.notification(for: recoveredSnapshot)?.body.contains("available again") == true)
        policy.commitPendingNotification()

        let reloadedPolicy = UsageNotificationPolicy(appSupportDirectory: directory)
        precondition(reloadedPolicy.notification(for: recoveredSnapshot) == nil)
    }

    private static func verifyThresholdJump(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reset = Int(Date().timeIntervalSince1970) + 18_000
        let policy = UsageNotificationPolicy(appSupportDirectory: directory)
        precondition(policy.notification(for: snapshot(remaining: 60, reset: reset)) == nil)
        let jump = policy.notification(for: snapshot(remaining: 7, reset: reset))
        precondition(jump?.body.contains("7%") == true)
        precondition(jump?.body.contains("50%") == false)
        policy.commitPendingNotification()
    }

    private static func verifyTestNotificationLayout() {
        let reset = Int(Date().timeIntervalSince1970) + 18_000
        let policy = UsageNotificationPolicy(
            appSupportDirectory: URL(fileURLWithPath: "/tmp/codexbeacon-policy-layout", isDirectory: true)
        )
        let body = policy.testNotification(
            for: snapshot(remaining: 38, weeklyRemaining: 90, reset: reset)
        ).body
        precondition(body == "5h 38% remaining\nWeekly 90% remaining")
        precondition(!body.contains("Connected"))
    }

    private static func verifyBarkURLParsing() {
        precondition((try? BarkEndpoint(urlString: "https://api.day.app/KMer").deviceKey) == "KMer")
        precondition((try? BarkEndpoint(urlString: "https://api.day.app/KMer/Body Text").deviceKey) == "KMer")
        precondition((try? BarkEndpoint(urlString: "https://api.day.app/KMer/Title/Body?sound=bell").deviceKey) == "KMer")
        precondition((try? BarkEndpoint(urlString: "http://api.day.app/KMer").deviceKey) == nil)
    }
}
