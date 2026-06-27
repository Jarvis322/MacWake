import SwiftUI
import Combine
import Sparkle

struct MacWakeMenuView: View {
    @ObservedObject var tracker: BatteryTracker
    @ObservedObject private var chargeLimit = ChargeLimitManager.shared
    @Environment(\.colorScheme) var colorScheme
    @State private var isLaunchAtLoginEnabled: Bool = LaunchAgentManager.isEnabled
    @State private var selectedTab: Int = 0
    @State private var isScrolledToBottom = false
    @State private var isCLIInstalled = CLIInstaller.isInstalled
    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    @State private var timerActive = true
    
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
                
                if tracker.highTempAlert {
                    smartProtectionWarningCard(
                        title: "High Battery Temperature",
                        message: String(format: "Battery reached %.1f°C. Overheating can shorten battery life. Consider unplugging.", tracker.batteryTemperature),
                        icon: "thermometer.high",
                        color: .red
                    )
                } else if tracker.continuousACAlert {
                    smartProtectionWarningCard(
                        title: "Plugged In All Day",
                        message: "Your Mac has been on AC power for 24 hours. Discharge the battery occasionally to protect battery health.",
                        icon: "powerplug",
                        color: .orange
                    )
                }
                
                // Tab Selection Bar
                tabSelectorBar
                
                Divider()
                
                // Conditional Tab Content
                GeometryReader { outer in
                    ZStack(alignment: .bottom) {
                        ScrollView(.vertical, showsIndicators: true) {
                            Group {
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
                            .padding(.bottom, 18)   // breathing room above the fade hint
                            .background(GeometryReader { inner in
                                Color.clear.preference(
                                    key: ScrollBottomKey.self,
                                    value: inner.frame(in: .named("tabScroll")).maxY
                                )
                            })
                        }
                        .coordinateSpace(name: "tabScroll")

                        // Bottom fade + chevron: only while there's more to scroll.
                        if !isScrolledToBottom {
                            VStack(spacing: 0) {
                                LinearGradient(
                                    colors: [Color(nsColor: .windowBackgroundColor).opacity(0), Color(nsColor: .windowBackgroundColor).opacity(0.55)],
                                    startPoint: .top, endPoint: .bottom
                                )
                                .frame(height: 26)
                                Image(systemName: "chevron.compact.down")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.secondary.opacity(0.5))
                                    .frame(maxWidth: .infinity)
                                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.55))
                            }
                            .allowsHitTesting(false)
                            .transition(.opacity)
                        }
                    }
                    .onPreferenceChange(ScrollBottomKey.self) { contentMaxY in
                        // contentMaxY = content's bottom edge in the viewport's coords.
                        // At/short of the bottom when it fits within the viewport height.
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isScrolledToBottom = contentMaxY <= outer.size.height + 6
                        }
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
            isLaunchAtLoginEnabled = LaunchAgentManager.isEnabled
            chargeLimit.refreshStatus()
            isCLIInstalled = CLIInstaller.isInstalled
            timerActive = true
        }
        .onDisappear {
            timerActive = false
        }
        .onReceive(timer) { _ in
            guard timerActive else { return }
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

            if tracker.cpuTemperature != nil || tracker.gpuTemperature != nil || tracker.ssdTemperature != nil {
                Divider()
                systemTemperaturesSection
            }

            Divider()

            batteryHealthDecaySection
            
            Divider()
            
            fanStatusSection
            
            if !tracker.adapterHistory.isEmpty {
                Divider()
                adapterHistorySection
            }
        }
    }

    // MARK: - Modern settings building blocks

    private func iconTile(_ icon: String, _ tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(tint.gradient)
            .frame(width: 26, height: 26)
            .overlay(Image(systemName: icon).font(.system(size: 12.5, weight: .semibold)).foregroundColor(.white))
    }

    @ViewBuilder
    private func settingsCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.05), lineWidth: 1))
    }

    private func rowDivider() -> some View { Divider().padding(.leading, 49) }

    private func toggleRow(_ icon: String, _ tint: Color, _ title: String, _ binding: Binding<Bool>) -> some View {
        HStack(spacing: 11) {
            iconTile(icon, tint)
            Text(LocalizedStringKey(title)).font(.subheadline)
            Spacer()
            Toggle("", isOn: binding).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func actionRow(_ icon: String, _ tint: Color, _ title: String, destructive: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                iconTile(icon, tint)
                Text(LocalizedStringKey(title)).font(.subheadline).foregroundColor(destructive ? .red : .primary)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary.opacity(0.4))
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionLabel(_ title: String) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.leading, 4)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { isLaunchAtLoginEnabled },
                set: { v in isLaunchAtLoginEnabled = v; LaunchAgentManager.setEnabled(v) })
    }

    private var settingsTabContent: some View {
        VStack(spacing: 10) {
            notificationPermissionRow
            
            sectionLabel("General")
            settingsCard {
                toggleRow("rectangle.on.rectangle", .blue, "Show Desktop Widget", $tracker.showWidget)
                if tracker.showWidget {
                    rowDivider()
                    toggleRow("lock.fill", .gray, "Lock Widget Position", $tracker.isWidgetLocked)
                }
                rowDivider()
                toggleRow("power", .green, "Launch at Login", launchAtLoginBinding)
                rowDivider()
                toggleRow("sparkles", .purple, "Enable Animations", $tracker.enableAnimations)
                rowDivider()
                toggleRow("oval.portrait.tophalf.filled", .indigo, "Dynamic Island Overlay", $tracker.enableDynamicIsland)
            }

            menuBarSection

            chargeLimitSection

            fanControlSection

            energyModeSection

            cliSection

            sectionLabel("Actions")
            settingsCard {
                actionRow("sparkles", .pink, "Welcome Tour") { OnboardingManager.shared.show() }
                rowDivider()
                actionRow("arrow.clockwise", .orange, "Reset Session") { tracker.resetCurrentSession() }
                rowDivider()
                actionRow("arrow.down.circle.fill", .blue, "Check for Updates") { AppDelegate.shared?.checkForUpdates() }
                rowDivider()
                actionRow("power", .red, "Quit MacWake", destructive: true) { NSApplication.shared.terminate(nil) }
            }
            .padding(.top, 2)
        }
    }

    // Robust slider bounds: use the helper's reported min/max when valid, otherwise
    // fall back to a sensible range (some Macs don't expose F0Mn/F0Mx).
    private var fanSliderMin: Double { Double(max(0, chargeLimit.fanMinRPM)) }
    private var fanSliderMax: Double {
        let reported = chargeLimit.fanMaxRPM
        if reported > chargeLimit.fanMinRPM + 200 { return Double(reported) }
        let observed = Int(tracker.currentFanSpeed ?? 0)
        return Double(max(6500, observed + 1500))
    }

    @ViewBuilder
    private var menuBarSection: some View {
        HStack {
            sectionLabel("Menu Bar")
            // Live preview of what the menu-bar item will show.
            HStack(spacing: 3) {
                if tracker.showMenuBarIcon || tracker.menuBarText.isEmpty {
                    Image(systemName: tracker.effectiveMenuBarIcon)
                }
                if !tracker.menuBarText.isEmpty {
                    Text(tracker.menuBarText)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundColor(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .padding(.trailing, 4)
        }

        settingsCard {
            toggleRow("app.badge", .blue, "Icon", $tracker.showMenuBarIcon)
            rowDivider()
            toggleRow("percent", .green, "Battery %", $tracker.showMenuBarPercent)
            rowDivider()
            toggleRow("bolt.fill", .orange, "Power / Time", $tracker.showMenuBarPower)
            rowDivider()
            toggleRow("hourglass", .purple, "Time Remaining", $tracker.showMenuBarTimeRemaining)
            rowDivider()
            toggleRow("thermometer.medium", .red, "Temperature", $tracker.showMenuBarTemp)
        }
    }

    @ViewBuilder
    private var cliSection: some View {
        sectionLabel("Command Line Tool")
        settingsCard {
            HStack(spacing: 11) {
                iconTile("terminal.fill", isCLIInstalled ? .green : .gray)
                VStack(alignment: .leading, spacing: 1) {
                    Text("macwake").font(.system(size: 14, weight: .semibold, design: .monospaced))
                    Text(isCLIInstalled
                         ? "status · charging · adapter · energy · fan"
                         : String(localized: "Control charging from Terminal."))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if isCLIInstalled {
                    Button(action: {
                        if CLIInstaller.uninstall() { isCLIInstalled = CLIInstaller.isInstalled }
                    }) { Text("Remove") }
                    .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button(action: {
                        if CLIInstaller.install() { isCLIInstalled = CLIInstaller.isInstalled }
                    }) { Text("Install") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
    }

    private var calibrationPhaseText: String {
        switch chargeLimit.calibrationPhase {
        case .discharge: return String(localized: "Calibrating — discharging to 15%…")
        case .charge:    return String(localized: "Calibrating — charging to 100%…")
        case .hold:      return String(localized: "Calibrating — holding at 100%…")
        }
    }

    @ViewBuilder
    private var energyModeSection: some View {
        if chargeLimit.helperStatus == .ready {
            sectionLabel("Energy Mode")
            settingsCard {
                HStack(spacing: 11) {
                    iconTile("leaf.fill", .green)
                    Picker("", selection: Binding(
                        get: { chargeLimit.energyMode },
                        set: { chargeLimit.setEnergyMode($0) }
                    )) {
                        Text("Automatic").tag(0)
                        Text("Low Power").tag(1)
                        if chargeLimit.highPowerSupported {
                            Text("High Power").tag(2)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
            }
        }
    }

    @ViewBuilder
    private var fanControlSection: some View {
        // Show whenever the Mac actually has fans (app-side detection, like the Hardware
        // tab) and the privileged helper is available to apply the change.
        if chargeLimit.helperStatus == .ready && tracker.hasFans {
            HStack {
                sectionLabel("Manual Fan Speed")
                Text("BETA")
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.orange.opacity(0.2))
                    .foregroundColor(.orange)
                    .cornerRadius(3)
                    .padding(.trailing, 4)
            }
            settingsCard {
                HStack(spacing: 11) {
                    iconTile("fanblades.fill", .cyan)
                    Text("Manual Fan Speed").font(.subheadline)
                    Spacer()
                    Toggle("", isOn: $chargeLimit.fanControlEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)

                if chargeLimit.fanControlEnabled {
                    rowDivider()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Target").font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text(String(format: String(localized: "RPM_FMT"), chargeLimit.fanTargetRPM))
                                .font(.caption.bold()).foregroundColor(.cyan)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(min(max(chargeLimit.fanTargetRPM, Int(fanSliderMin)), Int(fanSliderMax))) },
                                set: { chargeLimit.fanTargetRPM = Int($0) }
                            ),
                            in: fanSliderMin...fanSliderMax,
                            step: 100
                        )
                        Text(String(localized: "FAN_SAFETY_NOTE"))
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
        }
    }

    private func sliderBlock<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) { content() }
            .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder
    private var chargeLimitSection: some View {
        sectionLabel("Charge Limit")

        switch chargeLimit.helperStatus {
        case .ready:
            settingsCard {
                HStack(spacing: 11) {
                    iconTile("bolt.badge.automatic", .green)
                    Text("Limit Charging").font(.subheadline)
                    Spacer()
                    Toggle("", isOn: $chargeLimit.isEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)

                if chargeLimit.isEnabled {
                    rowDivider()
                    sliderBlock {
                        HStack {
                            Text("Stop at").font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text("\(chargeLimit.limit)%").font(.caption.bold()).foregroundColor(.green)
                        }
                        Slider(value: Binding(get: { Double(chargeLimit.limit) }, set: { chargeLimit.limit = Int($0) }), in: 50...95, step: 5).tint(.green)
                        Text(String(format: String(localized: "CL_HOLD_FMT"), chargeLimit.limit))
                            .font(.system(size: 10)).foregroundColor(.secondary)
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundColor(.orange)
                            Text(String(localized: "CL_OPT_WARNING")).font(.system(size: 10)).foregroundColor(.secondary)
                        }
                        .padding(.top, 2)
                    }

                    rowDivider()
                    HStack(spacing: 11) {
                        iconTile("sailboat.fill", .blue)
                        Text("Sailing Mode").font(.subheadline)
                        Spacer()
                        Toggle("", isOn: $chargeLimit.sailingEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    if chargeLimit.sailingEnabled {
                        sliderBlock {
                            HStack {
                                Text("Recharge at").font(.caption).foregroundColor(.secondary)
                                Spacer()
                                Text("\(chargeLimit.sailingLower)%").font(.caption.bold()).foregroundColor(.blue)
                            }
                            Slider(value: Binding(get: { Double(chargeLimit.sailingLower) }, set: { chargeLimit.sailingLower = Int($0) }), in: 40...Double(max(45, chargeLimit.limit - 5)), step: 5).tint(.blue)
                            Text(String(format: String(localized: "SAILING_DESC_FMT"), chargeLimit.sailingLower, chargeLimit.limit))
                                .font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    }

                    rowDivider()
                    HStack(spacing: 11) {
                        iconTile("gauge.with.needle", .purple)
                        Text("Battery Calibration").font(.subheadline)
                        Spacer()
                        Toggle("", isOn: $chargeLimit.calibrationEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    if chargeLimit.calibrationEnabled {
                        sliderBlock {
                            HStack {
                                Text("Every").font(.caption).foregroundColor(.secondary)
                                Spacer()
                                Text(String(format: String(localized: "DAYS_FMT"), chargeLimit.calibrationIntervalDays)).font(.caption.bold()).foregroundColor(.purple)
                            }
                            Slider(value: Binding(get: { Double(chargeLimit.calibrationIntervalDays) }, set: { chargeLimit.calibrationIntervalDays = Int($0) }), in: 7...90, step: 1).tint(.purple)
                            Text(String(localized: "CALIBRATION_DESC")).font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    }

                    rowDivider()
                    sliderBlock {
                        if chargeLimit.calibrationActive {
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.mini)
                                Text(calibrationPhaseText).font(.system(size: 10)).foregroundColor(.purple)
                                Spacer()
                            }
                            Button(action: { chargeLimit.cancelCalibration() }) { Text("Cancel").frame(maxWidth: .infinity) }
                                .buttonStyle(.bordered).controlSize(.small)
                        } else {
                            Button(action: { chargeLimit.calibrateNow() }) {
                                HStack { Image(systemName: "gauge.with.needle"); Text("Calibrate Now") }.frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }

        case .requiresApproval:
            settingsCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Approval needed").font(.subheadline.bold())
                    Text("Enable the MacWake background item in System Settings to allow charge limiting.")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                    Button("Open System Settings") { chargeLimit.install() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
                .padding(12)
            }

        case .notInstalled:
            settingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 11) {
                        iconTile("bolt.badge.automatic", .green)
                        Text("Charge Limit").font(.subheadline)
                        Spacer()
                    }
                    Text("Cap charging at a set level to reduce long-term battery wear. Installs a small background helper (one-time approval).")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                    Button("Enable Charge Limiting") { chargeLimit.install() }
                        .buttonStyle(.borderedProminent).controlSize(.small).frame(maxWidth: .infinity)
                }
                .padding(12)
            }
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
            let limitStr = String(format: String(localized: "LIMIT_FMT"), tracker.chargeLimit)
            var portStr = ""
            if let port = tracker.usbPortInfo {
                portStr = String(format: String(localized: "VIA_FMT"), port)
            }
            if let dyn = tracker.dynamicWatts, let maxWatts = tracker.powerAdapterWatts {
                return String(format: String(localized: "CHARGING_DYN_FMT"), dyn, maxWatts, portStr, limitStr)
            } else if let watts = tracker.powerAdapterWatts {
                return String(format: String(localized: "CHARGING_FIXED_FMT"), watts, portStr, limitStr)
            }
            return String(format: String(localized: "CHARGING_PORT_FMT"), portStr, limitStr)
        }

        return String(localized: "On Battery")
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
            return String(format: String(localized: "CHARGING_DESC_FMT"), watts)
        }
        return String(format: String(localized: "UNPLUG_DESC_FMT"), tracker.chargeLimit)
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
                    subtitle: tracker.batteryTemperature > 42 ? "Hot" : "Normal",
                    color: tracker.batteryTemperature > 42 ? .red : orangeColor
                )
            }
        }
    }

    // MARK: - System Temperatures (Apple Silicon sensors)
    private var systemTemperaturesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SYSTEM TEMPERATURES")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                systemTempCard(title: "CPU", value: tracker.cpuTemperature)
                systemTempCard(title: "GPU", value: tracker.gpuTemperature)
                systemTempCard(title: "SSD", value: tracker.ssdTemperature)
            }
        }
    }

    private func systemTempCard(title: String, value: Double?) -> some View {
        let color: Color = value.map { $0 > 85 ? .red : ($0 > 65 ? orangeColor : blueColor) } ?? .secondary
        let subtitle: String = value.map { $0 > 85 ? "Hot" : ($0 > 65 ? "Warm" : "Normal") } ?? "Unavailable"
        return statCard(
            title: title,
            value: value.map { String(format: "%.0f°C", $0) } ?? "N/A",
            subtitle: subtitle,
            color: color
        )
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
                            Text(String(format: String(localized: "LAST_SEEN_FMT"), formatRelativeDate(adapter.lastSeen)))
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
                                Text(String(format: String(localized: "SCREEN_FMT"), formatDuration(pastSession.screenOnDuration)))
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(greenColor)
                                Text(String(format: String(localized: "TOTAL_FMT"), formatDuration(pastSession.endTime?.timeIntervalSince(pastSession.startTime) ?? 0)))
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
            return String(localized: "Notifications On")
        case .denied:
            return String(localized: "Notifications Off")
        case .notDetermined:
            return String(localized: "Notifications Not Set")
        case .ephemeral:
            return String(localized: "Notifications Temporary")
        @unknown default:
            return String(localized: "Notifications Unknown")
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
            Text(LocalizedStringKey(title))
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(color)
            Text(LocalizedStringKey(subtitle))
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
            Text(LocalizedStringKey(title))
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
            Text(LocalizedStringKey(label))
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
            Text(LocalizedStringKey(label))
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

    private var batteryHealthDecaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("BATTERY HEALTH DECAY LOG")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: { tracker.recheckBatteryHealth() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(5)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Recheck battery health now")
            }

            if tracker.healthHistory.isEmpty {
                Text("No health changes recorded yet.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(tracker.healthHistory.sorted(by: { $0.date > $1.date }).prefix(3))) { record in
                        HStack {
                            Image(systemName: "heart.text.square.fill")
                                .foregroundColor(.red)
                                .font(.system(size: 14))
                            
                            VStack(alignment: .leading, spacing: 1) {
                                Text(String(format: String(localized: "BATTERY_HEALTH_FMT"), record.health))
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text(String(format: String(localized: "RECORDED_AT_FMT"), record.cycleCount))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Text(formatDate(record.date))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.04))
                        .cornerRadius(6)
                    }
                }
            }
        }
    }

    private func smartProtectionWarningCard(title: String, message: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.title3)
                .padding(.top, 2)
            
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(color)
                Text(message)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Tab Button Component
/// Reports the scrolled content's bottom-edge Y in the scroll viewport's coordinate
/// space, so the "scroll for more" hint can hide once you reach the bottom.
private struct ScrollBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

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
                Text(LocalizedStringKey(title))
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(isSelected ? activeColor : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(isSelected ? activeColor.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
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
