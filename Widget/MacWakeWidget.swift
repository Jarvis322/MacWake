import WidgetKit
import SwiftUI

// MacWake's WidgetKit extension (Notification Center / desktop widgets). The main app
// writes a small JSON snapshot into the shared app-group container on every heartbeat;
// this sandboxed extension only ever reads that file — no IOKit, no helper access.

let kAppGroupID = "6NK6D7LL79.com.jarvisit.macwake"

struct BatterySnapshot: Codable {
    var level: Int
    var isPluggedIn: Bool
    var health: Int
    var temperature: Double
    var limitEnabled: Bool
    var limit: Int
    var timestamp: Date

    static let placeholder = BatterySnapshot(
        level: 82, isPluggedIn: true, health: 96, temperature: 31.5,
        limitEnabled: true, limit: 80, timestamp: Date()
    )

    static func load() -> BatterySnapshot? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: kAppGroupID) else { return nil }
        let url = container.appendingPathComponent("widget-snapshot.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BatterySnapshot.self, from: data)
    }
}

struct BatteryEntry: TimelineEntry {
    let date: Date
    let snapshot: BatterySnapshot
    /// True when the app hasn't written a snapshot recently (not running / just installed).
    let stale: Bool
}

struct BatteryProvider: TimelineProvider {
    func placeholder(in context: Context) -> BatteryEntry {
        BatteryEntry(date: Date(), snapshot: .placeholder, stale: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (BatteryEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BatteryEntry>) -> Void) {
        // The app pushes reloads on real changes; this refresh interval is just a backstop.
        completion(Timeline(entries: [makeEntry()], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    private func makeEntry() -> BatteryEntry {
        if let snap = BatterySnapshot.load() {
            let stale = Date().timeIntervalSince(snap.timestamp) > 30 * 60
            return BatteryEntry(date: Date(), snapshot: snap, stale: stale)
        }
        return BatteryEntry(date: Date(), snapshot: .placeholder, stale: true)
    }
}

struct BatteryWidgetView: View {
    var entry: BatteryEntry
    @Environment(\.widgetFamily) private var family

    private var levelColor: Color {
        let l = entry.snapshot.level
        return l <= 20 ? .red : (l <= 40 ? .orange : .green)
    }

    var body: some View {
        content
            .containerBackground(.background, for: .widget)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemMedium: medium
        default: small
        }
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 8)
            Circle()
                .trim(from: 0, to: CGFloat(entry.snapshot.level) / 100)
                .stroke(levelColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Image(systemName: entry.snapshot.isPluggedIn ? "bolt.fill" : "battery.100percent")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(levelColor)
                Text("\(entry.snapshot.level)%")
                    .font(.system(size: 17, weight: .bold).monospacedDigit())
            }
        }
    }

    private var small: some View {
        VStack(spacing: 6) {
            ring.frame(width: 74, height: 74)
            Text(entry.stale
                 ? String(localized: "Open MacWake")
                 : (entry.snapshot.isPluggedIn ? String(localized: "Charging") : String(localized: "On Battery")))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
        }
    }

    private var medium: some View {
        HStack(spacing: 18) {
            ring.frame(width: 80, height: 80)
            VStack(alignment: .leading, spacing: 5) {
                statRow(icon: "heart.fill", tint: .pink,
                        text: String(format: String(localized: "Health %d%%"), entry.snapshot.health))
                statRow(icon: "thermometer.medium", tint: .orange,
                        text: String(format: "%.1f°C", entry.snapshot.temperature))
                statRow(icon: "bolt.badge.automatic", tint: .green,
                        text: entry.snapshot.limitEnabled
                            ? String(format: String(localized: "Limit %d%%"), entry.snapshot.limit)
                            : String(localized: "No charge limit"))
                if entry.stale {
                    statRow(icon: "exclamationmark.circle", tint: .secondary,
                            text: String(localized: "Open MacWake to refresh"))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private func statRow(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundColor(tint).frame(width: 14)
            Text(text).font(.system(size: 12, weight: .medium).monospacedDigit())
        }
    }
}

struct BatteryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.jarvisit.macwake.battery", provider: BatteryProvider()) { entry in
            BatteryWidgetView(entry: entry)
        }
        .configurationDisplayName("MacWake Battery")
        .description(String(localized: "Battery level, health, temperature, and charge limit at a glance."))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct MacWakeWidgetBundle: WidgetBundle {
    var body: some Widget {
        BatteryWidget()
    }
}
