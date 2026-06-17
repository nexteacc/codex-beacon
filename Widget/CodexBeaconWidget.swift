import Foundation
import AppKit
import SwiftUI
import WidgetKit

struct CodexUsageEntry: TimelineEntry {
    let date: Date
    let fiveHourRemaining: Double?
    let weeklyRemaining: Double?
    let isLive: Bool

    static let placeholder = CodexUsageEntry(
        date: .now,
        fiveHourRemaining: 36,
        weeklyRemaining: 100,
        isLive: false
    )

    static let unavailable = CodexUsageEntry(
        date: .now,
        fiveHourRemaining: nil,
        weeklyRemaining: nil,
        isLive: false
    )
}

private struct CodexUsageSnapshot: Decodable {
    let ok: Bool
    let primary: CodexUsageWindow
    let secondary: CodexUsageWindow?
}

private struct CodexUsageWindow: Decodable {
    let remainingPercent: Double
}

struct CodexUsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> CodexUsageEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (CodexUsageEntry) -> Void) {
        guard !context.isPreview else {
            completion(.placeholder)
            return
        }

        loadEntry(completion: completion)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CodexUsageEntry>) -> Void) {
        loadEntry { entry in
            let refreshInterval: TimeInterval = entry.isLive ? 15 * 60 : 60
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(refreshInterval))))
        }
    }

    private func loadEntry(completion: @escaping (CodexUsageEntry) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:17321/usage") else {
            completion(.unavailable)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let snapshot = try? JSONDecoder().decode(CodexUsageSnapshot.self, from: data),
                  snapshot.ok else {
                completion(.unavailable)
                return
            }

            completion(CodexUsageEntry(
                date: .now,
                fiveHourRemaining: snapshot.primary.remainingPercent,
                weeklyRemaining: snapshot.secondary?.remainingPercent,
                isLive: true
            ))
        }.resume()
    }
}

struct CodexUsageWidgetView: View {
    let entry: CodexUsageEntry

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            UsageRing(label: "5h", percent: entry.fiveHourRemaining, icon: .asset("CodexParking"))
            UsageRing(label: "Weekly", percent: entry.weeklyRemaining, icon: .system("calendar"))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(WidgetBackgroundModifier())
    }
}

private struct WidgetBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.containerBackground(for: .widget) {
                SystemTranslucentWidgetBackground()
            }
        } else {
            content.padding().background(SystemTranslucentWidgetBackground())
        }
    }
}

private struct SystemTranslucentWidgetBackground: View {
    var body: some View {
        Color.black
    }
}

private struct UsageRing: View {
    enum Icon {
        case system(String)
        case asset(String)
    }

    let label: String
    let percent: Double?
    let icon: Icon
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode

    private var clampedPercent: Double? {
        percent.map { min(max($0, 0), 100) }
    }

    private var percentText: String {
        guard let clampedPercent else { return "--" }
        return "\(Int(clampedPercent.rounded()))%"
    }

    private var accessibilityText: String {
        guard let clampedPercent else { return "\(label) usage unavailable" }
        return "\(label) remaining \(Int(clampedPercent.rounded())) percent"
    }

    private var gaugeValue: Double {
        clampedPercent ?? 0
    }

    private var symbolOpacity: Double {
        widgetRenderingMode == .vibrant ? 0.9 : 0.82
    }

    private var valueOpacity: Double {
        widgetRenderingMode == .vibrant ? 0.95 : 0.9
    }

    private func ringColor(for value: Double) -> Color {
        switch value {
        case 0..<10:
            return .red
        case 10..<40:
            return .yellow
        default:
            return .green
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            Gauge(value: gaugeValue, in: 0...100) {
                Text(label)
            } currentValueLabel: {
                iconView
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .controlSize(.large)
            .tint(clampedPercent.map(ringColor) ?? .secondary)
            .frame(width: 64, height: 64)

            Text(percentText)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(valueOpacity))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(width: 72)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .system(let symbolName):
            Image(systemName: symbolName)
                .font(.system(size: 20, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white.opacity(symbolOpacity))
        case .asset(let assetName):
            Image(assetName)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(.white.opacity(symbolOpacity))
        }
    }
}

struct CodexUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CodexUsageWidget", provider: CodexUsageProvider()) { entry in
            CodexUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Codex Usage")
        .description("Shows local Codex 5h and weekly usage.")
        .supportedFamilies([.systemMedium])
        .containerBackgroundRemovable()
    }
}

@main
struct CodexBeaconWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexUsageWidget()
    }
}
