import Foundation
import Security

enum MobileNotificationError: LocalizedError {
    case invalidBarkURL
    case keychain(OSStatus)
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidBarkURL:
            return "Paste the Bark URL shown in the iPhone app."
        case .keychain:
            return "The Bark URL could not be saved securely."
        case .invalidResponse:
            return "Bark returned an invalid response."
        case .server(let message):
            return message
        }
    }
}

struct BarkEndpoint {
    let deviceKey: String

    init(urlString: String) throws {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "api.day.app",
              components.user == nil,
              components.password == nil else {
            throw MobileNotificationError.invalidBarkURL
        }

        let pathParts = components.path.split(separator: "/").map(String.init)
        guard let key = pathParts.first,
              key.range(of: #"^[A-Za-z0-9_-]{8,256}$"#, options: .regularExpression) != nil else {
            throw MobileNotificationError.invalidBarkURL
        }
        deviceKey = key
    }
}

final class BarkCredentialStore {
    private let service = "com.codexbeacon.native.bark"
    private let account = "device-key"

    func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    func save(_ deviceKey: String) throws {
        let data = Data(deviceKey.utf8)
        let status: OSStatus
        if load() == nil {
            var query = baseQuery
            query[kSecValueData as String] = data
            status = SecItemAdd(query as CFDictionary, nil)
        } else {
            status = SecItemUpdate(
                baseQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        }
        guard status == errSecSuccess else {
            throw MobileNotificationError.keychain(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MobileNotificationError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

struct BarkNotification {
    let title: String
    let body: String
}

final class BarkClient {
    static let iconURL = "https://raw.githubusercontent.com/nexteacc/codex-beacon/master/Resources/Notification/codex-color.png"

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func send(deviceKey: String, notification: BarkNotification, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: "https://api.day.app/push") else {
            completion(.failure(MobileNotificationError.invalidResponse))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("CodexBeacon/0.6", forHTTPHeaderField: "User-Agent")

        let payload: [String: Any] = [
            "device_key": deviceKey,
            "title": notification.title,
            "body": notification.body,
            "group": "codex-beacon-usage",
            "level": "active",
            "icon": Self.iconURL
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(.failure(error))
            return
        }

        session.dataTask(with: request) { data, response, error in
            let result: Result<Void, Error>
            if let error {
                result = .failure(error)
            } else if let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode) {
                if let data,
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let code = object["code"] as? Int,
                   code != 200 {
                    let message = object["message"] as? String ?? "Bark rejected the notification."
                    result = .failure(MobileNotificationError.server(message))
                } else {
                    result = .success(())
                }
            } else {
                result = .failure(MobileNotificationError.invalidResponse)
            }

            DispatchQueue.main.async {
                completion(result)
            }
        }.resume()
    }
}

private enum UsageNoticeLevel: String, Codable {
    case fifty
    case ten
    case exhausted
    case recovered
}

private struct UsageNotice {
    let selection: UsageWindowSelection
    let level: UsageNoticeLevel
    let remainingPercent: Double
    let resetsAt: Int

    var line: String {
        let label = selection == .fiveHour ? "5h" : "Weekly"
        switch level {
        case .fifty, .ten:
            return "\(label) usage has \(Int(remainingPercent.rounded()))% remaining"
        case .exhausted:
            return "\(label) usage is exhausted · Back \(Self.relativeResetText(resetsAt))"
        case .recovered:
            return "\(label) usage is available again"
        }
    }

    private static func relativeResetText(_ resetsAt: Int) -> String {
        let remaining = max(0, resetsAt - Int(Date().timeIntervalSince1970))
        if remaining < 60 {
            return "soon"
        }
        let minutes = Int(ceil(Double(remaining) / 60.0))
        if minutes < 60 {
            return "in \(minutes)m"
        }
        let hours = minutes / 60
        let leftoverMinutes = minutes % 60
        if hours < 24 {
            return leftoverMinutes == 0 ? "in \(hours)h" : "in \(hours)h \(leftoverMinutes)m"
        }
        let days = hours / 24
        let leftoverHours = hours % 24
        return leftoverHours == 0 ? "in \(days)d" : "in \(days)d \(leftoverHours)h"
    }
}

private struct UsageCycleState: Codable {
    var resetsAt: Int
    var sentFifty = false
    var sentTen = false
    var sentExhausted = false
    var sentRecovered = false
    var exhaustedObserved = false
}

private struct UsageNotificationLedger: Codable {
    var windows: [String: UsageCycleState] = [:]
}

final class UsageNotificationPolicy {
    private let fileURL: URL
    private var ledger: UsageNotificationLedger

    init(appSupportDirectory: URL) {
        fileURL = appSupportDirectory.appendingPathComponent("mobile-notifications.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(UsageNotificationLedger.self, from: data) {
            ledger = decoded
        } else {
            ledger = UsageNotificationLedger()
        }
    }

    func notification(for snapshot: CodexUsageSnapshot) -> BarkNotification? {
        let newNotices: [UsageNotice] = [UsageWindowSelection.fiveHour, .weekly].flatMap {
            usageNotices(for: $0, snapshot: snapshot)
        }
        guard !newNotices.isEmpty else { return nil }
        save()
        return BarkNotification(title: "Codex Usage", body: newNotices.map(\.line).joined(separator: "\n"))
    }

    func testNotification(for snapshot: CodexUsageSnapshot?) -> BarkNotification {
        guard let snapshot else {
            return BarkNotification(title: "Codex Beacon", body: "iPhone notifications are ready")
        }

        let lines = [UsageWindowSelection.fiveHour, .weekly].compactMap { selection -> String? in
            guard let window = snapshot.window(for: selection),
                  Date().timeIntervalSince1970 < TimeInterval(window.resetsAt + 8) else {
                return nil
            }
            if snapshot.isLimited(window: window, selection: selection) {
                return UsageNotice(
                    selection: selection,
                    level: .exhausted,
                    remainingPercent: window.remainingPercent,
                    resetsAt: window.resetsAt
                ).line
            }
            let label = selection == .fiveHour ? "5h" : "Weekly"
            return "\(label) \(Int(window.remainingPercent.rounded()))% remaining"
        }
        let body = lines.isEmpty ? "iPhone notifications are ready" : "Connected · " + lines.joined(separator: " · ")
        return BarkNotification(title: "Codex Beacon", body: body)
    }

    func establishBaseline(from snapshot: CodexUsageSnapshot?) {
        guard let snapshot else { return }
        for selection in [UsageWindowSelection.fiveHour, .weekly] {
            guard let window = snapshot.window(for: selection),
                  Date().timeIntervalSince1970 < TimeInterval(window.resetsAt + 8) else {
                continue
            }
            var state = UsageCycleState(resetsAt: window.resetsAt)
            markCurrentBand(window: window, limited: snapshot.isLimited(window: window, selection: selection), state: &state)
            ledger.windows[selection.rawValue] = state
        }
        save()
    }

    func reset() {
        ledger = UsageNotificationLedger()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func usageNotices(for selection: UsageWindowSelection, snapshot: CodexUsageSnapshot) -> [UsageNotice] {
        guard let window = snapshot.window(for: selection) else { return [] }
        let key = selection.rawValue
        let now = Int(Date().timeIntervalSince1970)
        var notices: [UsageNotice] = []

        if var state = ledger.windows[key] {
            if state.resetsAt != window.resetsAt {
                if state.exhaustedObserved && !state.sentRecovered {
                    notices.append(UsageNotice(selection: selection, level: .recovered, remainingPercent: window.remainingPercent, resetsAt: window.resetsAt))
                }
                state = UsageCycleState(resetsAt: window.resetsAt)
            } else if now >= state.resetsAt + 8 {
                if state.exhaustedObserved && !state.sentRecovered {
                    state.sentRecovered = true
                    notices.append(UsageNotice(selection: selection, level: .recovered, remainingPercent: window.remainingPercent, resetsAt: window.resetsAt))
                }
                ledger.windows[key] = state
                return notices
            }

            if let notice = thresholdNotice(selection: selection, window: window, limited: snapshot.isLimited(window: window, selection: selection), state: &state) {
                notices.append(notice)
            }
            ledger.windows[key] = state
            return notices
        }

        guard now < window.resetsAt + 8 else { return [] }
        var state = UsageCycleState(resetsAt: window.resetsAt)
        if let notice = thresholdNotice(selection: selection, window: window, limited: snapshot.isLimited(window: window, selection: selection), state: &state) {
            notices.append(notice)
        }
        ledger.windows[key] = state
        return notices
    }

    private func thresholdNotice(
        selection: UsageWindowSelection,
        window: CodexUsageWindow,
        limited: Bool,
        state: inout UsageCycleState
    ) -> UsageNotice? {
        let level: UsageNoticeLevel?
        if limited || window.remainingPercent <= 0 {
            level = state.sentExhausted ? nil : .exhausted
        } else if window.remainingPercent <= 10 {
            level = state.sentTen ? nil : .ten
        } else if window.remainingPercent <= 50 {
            level = state.sentFifty ? nil : .fifty
        } else {
            level = nil
        }

        guard let level else { return nil }
        mark(level: level, state: &state)
        return UsageNotice(
            selection: selection,
            level: level,
            remainingPercent: window.remainingPercent,
            resetsAt: window.resetsAt
        )
    }

    private func markCurrentBand(window: CodexUsageWindow, limited: Bool, state: inout UsageCycleState) {
        if limited || window.remainingPercent <= 0 {
            mark(level: .exhausted, state: &state)
        } else if window.remainingPercent <= 10 {
            mark(level: .ten, state: &state)
        } else if window.remainingPercent <= 50 {
            mark(level: .fifty, state: &state)
        }
    }

    private func mark(level: UsageNoticeLevel, state: inout UsageCycleState) {
        switch level {
        case .fifty:
            state.sentFifty = true
        case .ten:
            state.sentFifty = true
            state.sentTen = true
        case .exhausted:
            state.sentFifty = true
            state.sentTen = true
            state.sentExhausted = true
            state.exhaustedObserved = true
        case .recovered:
            state.sentRecovered = true
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(ledger).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("Codex Beacon mobile notification state error: \(error.localizedDescription)")
        }
    }
}

final class MobileNotificationsManager {
    private let credentialStore = BarkCredentialStore()
    private let client = BarkClient()
    private let policy: UsageNotificationPolicy
    private var isSendingUsageNotification = false

    init(appSupportDirectory: URL) {
        policy = UsageNotificationPolicy(appSupportDirectory: appSupportDirectory)
    }

    var isConfigured: Bool {
        credentialStore.load() != nil
    }

    func test(urlString: String?, snapshot: CodexUsageSnapshot?, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            let existingKey = credentialStore.load()
            let candidateKey: String
            if let urlString, !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                candidateKey = try BarkEndpoint(urlString: urlString).deviceKey
            } else if let existingKey {
                candidateKey = existingKey
            } else {
                throw MobileNotificationError.invalidBarkURL
            }

            let isNewCredential = candidateKey != existingKey
            client.send(deviceKey: candidateKey, notification: policy.testNotification(for: snapshot)) { [weak self] result in
                guard let self else { return }
                do {
                    try result.get()
                    if isNewCredential {
                        try self.credentialStore.save(candidateKey)
                        self.policy.reset()
                        self.policy.establishBaseline(from: snapshot)
                    }
                    completion(.success(()))
                } catch {
                    completion(.failure(error))
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    func disconnect() throws {
        try credentialStore.delete()
        policy.reset()
    }

    func process(snapshot: CodexUsageSnapshot) {
        guard !isSendingUsageNotification,
              let deviceKey = credentialStore.load(),
              let notification = policy.notification(for: snapshot) else {
            return
        }

        isSendingUsageNotification = true
        client.send(deviceKey: deviceKey, notification: notification) { [weak self] result in
            self?.isSendingUsageNotification = false
            if case .failure(let error) = result {
                NSLog("Codex Beacon Bark delivery failed: \(error.localizedDescription)")
            }
        }
    }
}
