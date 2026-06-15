import SwiftUI
import Combine

struct MacWakeMenuView: View {
    @ObservedObject var tracker: BatteryTracker
    @Environment(\.colorScheme) var colorScheme
    @State private var isLaunchAtLoginEnabled: Bool = LaunchAgentManager.isEnabled
    @State private var selectedTab: Int = 0
    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    
    private var greenColor: Color { .dynamicGreen(for: colorScheme) }
    private var orangeColor: Color { .dynamicOrange(for: colorScheme) }
    private var blueColor: Color { .dynamicBlue(for: colorScheme) }
    
    var body: some View {
        ZStack {
            VisualEffectView()
                .ignoresSafeArea()
            
            VStack(spacing: 11) {
                // Header (Always Visible)
                headerSection
                
                if let alert = tracker.slowChargingAlert {
                    slowChargingWarningCard(alert)
                }
                
                // Tab Selection Bar
                tabSelectorBar
                
                Divider()
                
                // Conditional Tab Content
                ScrollView(.vertical, showsIndicators: false) {
                    switch selectedTab {
                    case 0:
                        dashboardTabContent
                    case 1:
                        historyTabContent
                    case 2:
                        hardwareTabContent
                    case 3:
                        settingsTabContent
                    default:
                        EmptyView()
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                
                Divider()
                
                // Credits Link (Always Visible)
                creditsSection
            }
            .padding(14)
        }
        .frame(width: 360, height: 450)
        .ignoresSafeArea()
        .onAppear {
            tracker.updateDynamicWatts()
        }
        .onReceive(timer) { _ in
            tracker.updateDynamicWatts()
        }
    }
    
    // MARK: - Tab Selector Bar
    private var tabSelectorBar: some View {
        HStack(spacing: 4) {
            TabButton(title: "Session", icon: "chart.bar.fill", isSelected: selectedTab == 0, activeColor: greenColor) { selectedTab = 0 }
            TabButton(title: "History", icon: "clock.fill", isSelected: selectedTab == 1, activeColor: orangeColor) { selectedTab = 1 }
            TabButton(title: "Hardware", icon: "cpu", isSelected: selectedTab == 2, activeColor: blueColor) { selectedTab = 2 }
            TabButton(title: "Settings", icon: "gearshape.fill", isSelected: selectedTab == 3, activeColor: .purple) { selectedTab = 3 }
        }
        .padding(4)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    // MARK: - Tab Contents
    private var dashboardTabContent: some View {
        VStack(spacing: 11) {
            if let session = tracker.currentSession {
                currentSessionSection(tracker.liveSession(session))
            } else {
                noActiveSessionSection
            }
        }
    }

    private var historyTabContent: some View {
        VStack(alignment: .leading, spacing: 11) {
            weeklySummarySection
            
            Divider()
            
            historySection
        }
    }

    private var hardwareTabContent: some View {
        VStack(alignment: .leading, spacing: 11) {
            batteryHealthSection
            
            Divider()
            
            fanStatusSection
            
            if !tracker.adapterHistory.isEmpty {
                Divider()
                adapterHistorySection
            }
        }
    }

    private var settingsTabContent: some View {
        VStack(spacing: 10) {
            notificationPermissionRow
            
            Toggle(isOn: $tracker.showWidget) {
                Text("Show Desktop Widget")
                    .font(.subheadline)
            }
            .toggleStyle(SwitchToggleStyle())
            
            if tracker.showWidget {
                Toggle(isOn: $tracker.isWidgetLocked) {
                    Text("Lock Widget Position")
                        .font(.subheadline)
                }
                .toggleStyle(SwitchToggleStyle())
            }

            Toggle(isOn: $isLaunchAtLoginEnabled) {
                Text("Launch at Login")
                    .font(.subheadline)
            }
            .toggleStyle(SwitchToggleStyle())
            .onChange(of: isLaunchAtLoginEnabled) { oldValue, newValue in
                LaunchAgentManager.setEnabled(newValue)
            }
            
            Toggle(isOn: $tracker.enableAnimations) {
                HStack(spacing: 4) {
                    Text("Enable Animations")
                        .font(.subheadline)
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundColor(.purple)
                }
            }
            .toggleStyle(SwitchToggleStyle())
            
            HStack(spacing: 12) {
                Button(action: {
                    tracker.resetCurrentSession()
                }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Reset Session")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                
                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    HStack {
                        Image(systemName: "power")
                        Text("Quit")
                    }
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
    }

    private var creditsSection: some View {
        Link(destination: URL(string: "https://x.com/yigitech")!) {
            HStack(spacing: 4) {
                Text("Developed by")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text("x.com/yigitech")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(blueColor)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Header
    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("MacWake")
                        .font(.headline)
                        .fontWeight(.bold)
                    
                    if tracker.isPluggedIn && tracker.isOriginalAppleAdapter {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 10))
                                .foregroundColor(greenColor)
                            Text("Apple Original")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(greenColor)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(greenColor.opacity(0.12))
                        .cornerRadius(4)
                    }
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Battery Status Badge
            HStack(spacing: 4) {
                Image(systemName: tracker.isPluggedIn ? "battery.100.bolt" : "battery.75")
                    .foregroundColor(tracker.isPluggedIn ? blueColor : (tracker.currentBatteryLevel < 20 ? .red : greenColor))
                Text("\(tracker.currentBatteryLevel)%")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
        }
    }

    private var statusText: String {
        if tracker.isPluggedIn {
            let limitStr = "(Limit: \(tracker.chargeLimit)%)"
            var portStr = ""
            if let port = tracker.usbPortInfo {
                portStr = " via \(port)"
            }
            if let dyn = tracker.dynamicWatts, let maxWatts = tracker.powerAdapterWatts {
                return String(format: "Charging: %.1fW of %dW adapter%@ %@", dyn, maxWatts, portStr, limitStr)
            } else if let watts = tracker.powerAdapterWatts {
                return "Charging: \(watts)W adapter\(portStr) \(limitStr)"
            }
            return "Charging\(portStr) \(limitStr)"
        }

        return "On Battery"
    }
    
    // MARK: - Current Session Components
    private func currentSessionSection(_ session: BatteryTracker.Session) -> some View {
        let totalDuration = (session.endTime ?? Date()).timeIntervalSince(session.startTime)
        
        return VStack(alignment: .leading, spacing: 12) {
            Text("CURRENT SESSION")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
            
            // Primary Stats Cards
            HStack(spacing: 12) {
                statCard(
                    title: "Screen On",
                    value: formatDuration(session.screenOnDuration),
                    subtitle: "Active time",
                    color: greenColor
                )
                
                statCard(
                    title: "Total Time",
                    value: formatDuration(totalDuration),
                    subtitle: "Since \(formatTime(session.startTime))",
                    color: .primary
                )
            }

            if let remaining = tracker.remainingBatteryEstimate {
                HStack {
                    Image(systemName: "hourglass")
                        .foregroundColor(.purple)
                    Text("Estimated remaining")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formatDuration(remaining))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.purple)
                }
                .padding(8)
                .background(Color.purple.opacity(0.08))
                .cornerRadius(6)
            }
            
            // Detail Stats Row
            HStack {
                detailStat(label: "Sleep Time", value: formatDuration(session.sleepDuration))
                Spacer()
                detailStat(label: "Shutdown", value: formatDuration(session.shutdownDuration))
                Spacer()
                detailStat(label: "Restarts", value: "\(session.rebootCount)")
                Spacer()
                detailStat(label: "Start Charge", value: "\(session.startBattery)%")
            }
            .padding(.horizontal, 4)

            if let efficiency = session.screenMinutesPerPercent {
                HStack {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .foregroundColor(blueColor)
                    Text("\(formatDecimal(efficiency)) min screen-on per 1% battery")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(session.batteryUsed)% used")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .padding(8)
                .background(blueColor.opacity(0.08))
                .cornerRadius(6)
            }
            
            // Custom Timeline Chart
            VStack(alignment: .leading, spacing: 6) {
                Text("Session Timeline")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                TimelineBarView(session: session, tracker: tracker)
                    .frame(height: 12)
                
                // Legend
                HStack(spacing: 10) {
                    legendItem(color: greenColor, label: "Screen On")
                    legendItem(color: orangeColor, label: "Sleep")
                    legendItem(color: .gray, label: "Shutdown")
                    if session.events.contains(where: { $0.type == "plugged" }) {
                        legendItem(color: blueColor, label: "Plugged")
                    }
                }
            }
            .padding(.top, 4)
        }
    }
    
    private var noActiveSessionSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.batteryblock.fill")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("Mac is Plugged In")
                .font(.subheadline)
                .fontWeight(.semibold)
            Text(pluggedInDescription)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
    }

    private var pluggedInDescription: String {
        if let watts = tracker.powerAdapterWatts {
            return "Charging from a \(watts)W adapter. Tracking will start automatically when you unplug the power cable."
        }
        return "Tracking will start automatically when you unplug the power cable (limit: \(tracker.chargeLimit)%)."
    }

    // MARK: - Weekly Summary
    private var weeklySummarySection: some View {
        let summary = tracker.weeklySummary

        return VStack(alignment: .leading, spacing: 8) {
            Text("LAST 7 DAYS")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.secondary)

            if summary.sessionCount == 0 {
                Text("No battery sessions in the last 7 days.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                HStack(spacing: 8) {
                    summaryStat(
                        title: "Screen",
                        value: formatDuration(summary.screenOnDuration),
                        color: greenColor
                    )
                    summaryStat(
                        title: "Efficiency",
                        value: summary.averageMinutesPerPercent.map { "\(formatDecimal($0))m/%" } ?? "N/A",
                        color: blueColor
                    )
                    summaryStat(
                        title: "Used",
                        value: "\(summary.batteryUsed)%",
                        color: orangeColor
                    )
                }
            }
        }
    }

    // MARK: - Battery Health & Hardware
    private var batteryHealthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BATTERY HEALTH & HARDWARE")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
            
            HStack(spacing: 8) {
                statCard(
                    title: "Health",
                    value: "\(tracker.batteryHealth)%",
                    subtitle: "Max capacity",
                    color: greenColor
                )
                
                statCard(
                    title: "Cycles",
                    value: "\(tracker.batteryCycles)",
                    subtitle: "Total count",
                    color: blueColor
                )
                
                statCard(
                    title: "Temperature",
                    value: String(format: "%.1f°C", tracker.batteryTemperature),
                    subtitle: tracker.batteryTemperature > 38 ? "Hot" : "Normal",
                    color: tracker.batteryTemperature > 38 ? .red : orangeColor
                )
            }
        }
    }

    // MARK: - Fan Status
    private var fanStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FAN STATUS")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
            
            if tracker.hasFans {
                HStack(spacing: 12) {
                    // Current Fan Speed Card
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fan Speed")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(tracker.currentFanSpeed.map { String(format: "%.0f RPM", $0) } ?? "N/A")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(blueColor)
                        Text("Active cooling")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(8)
                    
                    // Mini Fan History Graph
                    if !tracker.fanSpeedHistory.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("1h History")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            
                            HStack(alignment: .bottom, spacing: 2) {
                                let maxSpeed = max(1000.0, tracker.fanSpeedHistory.map(\.rpm).max() ?? 2000.0)
                                ForEach(Array(tracker.fanSpeedHistory.suffix(20))) { sample in
                                    let heightPct = CGFloat(sample.rpm / maxSpeed)
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(blueColor.opacity(0.6))
                                        .frame(width: 4, height: max(2, heightPct * 24))
                                }
                            }
                            .frame(height: 24)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 4)
                            
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(8)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "wind.slash")
                        .foregroundColor(.secondary)
                        .font(.title3)
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Fanless Device")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text("This Mac operates silently without cooling fans.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)
            }
        }
    }

    // MARK: - Adapter History
    private var adapterHistorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADAPTER HISTORY")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
            VStack(spacing: 6) {
                ForEach(Array(tracker.adapterHistory.prefix(2))) { adapter in
                    HStack {
                        Image(systemName: "powerplug.fill")
                            .foregroundColor(blueColor)
                            .frame(width: 18)
 
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                  Text(adapter.displayName)
                                      .font(.caption)
                                      .fontWeight(.medium)
                                      .lineLimit(1)
                                  
                                  if let mfg = adapter.manufacturer, mfg.lowercased().contains("apple") {
                                      Image(systemName: "checkmark.seal.fill")
                                          .font(.system(size: 9))
                                          .foregroundColor(greenColor)
                                  }
                            }
                            Text("Last seen \(formatRelativeDate(adapter.lastSeen))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Text("x\(adapter.seenCount)")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.08))
                            .cornerRadius(5)
                    }
                }
            }
        }
    }
    
    // MARK: - History Section
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENT SESSIONS (LAST 3)")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
            
            if tracker.history.isEmpty {
                Text("No sessions recorded yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(tracker.history.prefix(3))) { pastSession in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(formatDate(pastSession.startTime))
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("\(pastSession.startBattery)% → \(pastSession.endBatteryLevel ?? 0)%")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("Screen: \(formatDuration(pastSession.screenOnDuration))")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(greenColor)
                                Text("Total: \(formatDuration(pastSession.endTime?.timeIntervalSince(pastSession.startTime) ?? 0))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                if let efficiency = pastSession.screenMinutesPerPercent {
                                    Text("\(formatDecimal(efficiency))m per 1%")
                                        .font(.caption2)
                                        .foregroundColor(blueColor)
                                }
                            }
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(6)
                    }
                }
            }
        }
    }
    
    private var notificationPermissionRow: some View {
        HStack {
            Label(notificationStatusText, systemImage: notificationStatusIcon)
                .font(.caption)
                .foregroundColor(notificationStatusColor)

            Spacer()

            if tracker.notificationStatus == .authorized || tracker.notificationStatus == .provisional {
                Button("Test") {
                    tracker.sendTestNotification()
                }
                .font(.caption)
            } else if tracker.notificationStatus == .denied {
                Button("Settings") {
                    tracker.openNotificationSettings()
                }
                .font(.caption)
            } else {
                Button("Enable") {
                    tracker.requestNotificationAuthorization()
                }
                .font(.caption)
            }
        }
        .onAppear {
            tracker.refreshNotificationStatus()
        }
    }

    private var notificationStatusText: String {
        switch tracker.notificationStatus {
        case .authorized, .provisional:
            return "Notifications On"
        case .denied:
            return "Notifications Off"
        case .notDetermined:
            return "Notifications Not Set"
        case .ephemeral:
            return "Notifications Temporary"
        @unknown default:
            return "Notifications Unknown"
        }
    }

    private var notificationStatusIcon: String {
        switch tracker.notificationStatus {
        case .authorized, .provisional:
            return "bell.fill"
        case .denied:
            return "bell.slash.fill"
        default:
            return "bell"
        }
    }

    private var notificationStatusColor: Color {
        switch tracker.notificationStatus {
        case .authorized, .provisional:
            return greenColor
        case .denied:
            return .red
        default:
            return .secondary
        }
    }
    
    // MARK: - Helpers
    private func statCard(title: String, value: String, subtitle: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(color)
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    private func summaryStat(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(6)
    }
    
    private func detailStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }

    private func slowChargingWarningCard(_ alert: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(orangeColor)
                .font(.title3)
                .padding(.top, 2)
            
            VStack(alignment: .leading, spacing: 3) {
                Text("Slow Charging Alert")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(orangeColor)
                Text(alert)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(orangeColor.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(orangeColor.opacity(0.2), lineWidth: 1)
        )
    }
    
    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }

    private func formatRelativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func formatDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

// MARK: - Tab Button Component
struct TabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let activeColor: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(isSelected ? activeColor : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(isSelected ? activeColor.opacity(0.1) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Timeline Bar View
struct TimelineBarView: View {
    let session: BatteryTracker.Session
    let tracker: BatteryTracker
    @Environment(\.colorScheme) var colorScheme
    
    private var greenColor: Color { .dynamicGreen(for: colorScheme) }
    private var orangeColor: Color { .dynamicOrange(for: colorScheme) }
    private var blueColor: Color { .dynamicBlue(for: colorScheme) }
    
    var body: some View {
        GeometryReader { geometry in
            let segments = session.getTimelineSegments(currentAppState: tracker.appState, lastStateChange: Date())
            let totalDuration = max(1.0, (session.endTime ?? Date()).timeIntervalSince(session.startTime))
            
            HStack(spacing: 0) {
                if segments.isEmpty {
                    Rectangle()
                        .fill(greenColor)
                        .frame(width: geometry.size.width)
                } else {
                    ForEach(segments) { segment in
                        let segDuration = segment.endTime.timeIntervalSince(segment.startTime)
                        let width = geometry.size.width * CGFloat(segDuration / totalDuration)
                        
                        Rectangle()
                            .fill(colorFor(state: segment.state))
                            .frame(width: max(0, width))
                    }
                }
            }
            .cornerRadius(6)
        }
    }
    
    private func colorFor(state: String) -> Color {
        switch state {
        case "active":
            return greenColor
        case "sleep":
            return orangeColor
        case "shutdown":
            return .gray
        case "charging":
            return blueColor
        default:
            return .secondary
        }
    }
}

// MARK: - Visual Effect View
struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .popover
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension Color {
    static func dynamicGreen(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.15, green: 0.85, blue: 0.40)
            : Color(red: 0.05, green: 0.50, blue: 0.22)
    }
    
    static func dynamicOrange(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 1.0, green: 0.60, blue: 0.10)
            : Color(red: 0.78, green: 0.35, blue: 0.00)
    }
    
    static func dynamicBlue(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.25, green: 0.68, blue: 1.00)
            : Color(red: 0.00, green: 0.35, blue: 0.72)
    }
}
