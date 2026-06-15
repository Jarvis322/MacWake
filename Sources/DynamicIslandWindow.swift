import SwiftUI
import AppKit
import Combine

// MARK: - State
enum DynamicIslandState: Equatable {
    case compact
    case charging
    case alert(title: String, message: String, isWarning: Bool)
    case expanded
}

// MARK: - State Manager
@MainActor
class DynamicIslandStateManager: ObservableObject {
    static let shared = DynamicIslandStateManager()
    @Published private(set) var state: DynamicIslandState = .compact

    func show(_ newState: DynamicIslandState, autoDismissAfter seconds: TimeInterval? = nil) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) { state = newState }
        guard let seconds else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.state == newState else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) { self.state = .compact }
        }
    }

    func trigger(_ newState: DynamicIslandState) {
        switch newState {
        case .charging: show(newState, autoDismissAfter: 5.0)
        default: show(newState)
        }
    }
}

// MARK: - Notch pill (compact bar at menu-bar level)
struct NotchPillView: View {
    @ObservedObject var tracker: BatteryTracker
    @ObservedObject private var sm = DynamicIslandStateManager.shared

    var body: some View {
        HStack(spacing: 0) {
            // Left tab: Power
            HStack(spacing: 5) {
                Image(systemName: tracker.isPluggedIn ? "bolt.fill" : "battery.75")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(tracker.isPluggedIn ? .blue : batteryColor)
                Text("%\(tracker.currentBatteryLevel)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 10)

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 1, height: 14)

            // Right tab: Stats
            HStack(spacing: 5) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.purple)
                Text("Stats")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.horizontal, 10)

            Spacer()

            // Alert indicator if needed
            if tracker.highTempAlert || tracker.continuousACAlert {
                Image(systemName: tracker.highTempAlert ? "thermometer.high" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(tracker.highTempAlert ? .red : .orange)
                    .padding(.trailing, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var batteryColor: Color {
        tracker.currentBatteryLevel > 50 ? .green : (tracker.currentBatteryLevel > 20 ? .orange : .red)
    }
}

// MARK: - Full NotchNook-style Panel
struct DynamicIslandPanelView: View {
    @ObservedObject var tracker: BatteryTracker
    @ObservedObject private var sm = DynamicIslandStateManager.shared
    @State private var selectedTab = 0

    var body: some View {
        ZStack {
            // Glass background
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )

            // Content
            switch sm.state {
            case .charging:
                chargingLayout
            case .alert(let t, let m, let w):
                alertLayout(title: t, message: m, isWarning: w)
            default:
                mainLayout
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
    }

    // MARK: ── Main two-column layout (NotchNook style)
    private var mainLayout: some View {
        HStack(spacing: 0) {
            // LEFT: Battery / Power widget
            powerWidget
                .frame(maxWidth: .infinity)

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(width: 1)
                .padding(.vertical, 14)

            // RIGHT: Session / Stats widget
            sessionWidget
                .frame(maxWidth: .infinity)
        }
        .padding(4)
    }

    // MARK: Power Widget (left column)
    private var powerWidget: some View {
        HStack(spacing: 14) {
            // Battery visual
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.35))
                    .frame(width: 56, height: 56)

                if tracker.isPluggedIn {
                    Image(systemName: "bolt.ring.closed")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(colors: [.blue, .cyan], startPoint: .top, endPoint: .bottom)
                        )
                } else {
                    ZStack {
                        Image(systemName: batteryIconName)
                            .font(.system(size: 26, weight: .medium))
                            .foregroundColor(batteryColor)
                    }
                }
            }

            // Info
            VStack(alignment: .leading, spacing: 6) {
                // Big percentage
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(tracker.currentBatteryLevel)")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("%")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                }

                // Status line
                if tracker.isPluggedIn {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.blue)
                        if let watts = tracker.powerAdapterWatts {
                            Text("\(watts)W · Şarj Ediliyor")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                        } else {
                            Text("Şarj Ediliyor")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                        Text("Pil Kullanımı")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }

                // Temp + health pills
                HStack(spacing: 6) {
                    miniPill(
                        icon: "thermometer.medium",
                        text: String(format: "%.0f°C", tracker.batteryTemperature),
                        color: tracker.batteryTemperature > 35 ? .orange : .cyan
                    )
                    miniPill(
                        icon: "heart.fill",
                        text: "%\(tracker.batteryHealth)",
                        color: tracker.batteryHealth > 80 ? .green : .orange
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: Session Widget (right column)
    private var sessionWidget: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Text("Oturum & Donanım")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                Spacer()
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.3))
            }

            // Stat row
            HStack(spacing: 0) {
                sessionStat(
                    icon: "clock.fill",
                    value: sessionDuration,
                    label: "Oturum",
                    color: .purple
                )
                sessionStat(
                    icon: "arrow.clockwise",
                    value: "\(tracker.batteryCycles)",
                    label: "Döngü",
                    color: .blue
                )
                if tracker.hasFans {
                    sessionStat(
                        icon: "fan.fill",
                        value: tracker.currentFanSpeed.map { String(format: "%.0f", $0) } ?? "—",
                        label: "RPM",
                        color: .cyan
                    )
                } else {
                    sessionStat(
                        icon: "wind",
                        value: "Fansız",
                        label: "Soğutma",
                        color: .gray
                    )
                }
            }

            // Bottom note
            HStack(spacing: 6) {
                Image(systemName: tracker.highTempAlert || tracker.continuousACAlert
                    ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(tracker.highTempAlert || tracker.continuousACAlert ? .orange : .green)

                Text(tracker.highTempAlert ? "Yüksek sıcaklık uyarısı"
                    : tracker.continuousACAlert ? "Uzun süreli şarj uyarısı"
                    : "Her şey normal görünüyor")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.04))
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: Charging overlay layout
    private var chargingLayout: some View {
        HStack(spacing: 20) {
            // Animated bolt icon
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 60, height: 60)
                Image(systemName: "bolt.ring.closed")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(LinearGradient(colors: [.blue, .cyan], startPoint: .top, endPoint: .bottom))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Şarj Ediliyor")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                if let w = tracker.powerAdapterWatts {
                    Text("\(w) W güç adaptörü bağlandı")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                } else {
                    Text("Güç kaynağı bağlandı")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 8) {
                    miniPill(icon: "battery.100", text: "%\(tracker.currentBatteryLevel)", color: batteryColor)
                    miniPill(icon: "thermometer.medium", text: String(format: "%.0f°C", tracker.batteryTemperature), color: .cyan)
                }
            }
            Spacer()
        }
        .padding(22)
    }

    // MARK: Alert overlay layout
    private func alertLayout(title: String, message: String, isWarning: Bool) -> some View {
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill((isWarning ? Color.orange : Color.red).opacity(0.12))
                    .frame(width: 60, height: 60)
                Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "thermometer.high")
                    .font(.system(size: 30))
                    .foregroundColor(isWarning ? .orange : .red)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(isWarning ? .orange : .red)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(22)
    }

    // MARK: Sub-components
    private func miniPill(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private func sessionStat(icon: String, value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(color)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Computed helpers
    private var sessionDuration: String {
        guard let session = tracker.currentSession else { return "—" }
        let live = tracker.liveSession(session)
        let total = live.screenOnDuration
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        return h > 0 ? "\(h)s\(m)d" : "\(m)dk"
    }

    private var batteryColor: Color {
        tracker.currentBatteryLevel > 50 ? .green : (tracker.currentBatteryLevel > 20 ? .orange : .red)
    }

    private var batteryIconName: String {
        switch tracker.currentBatteryLevel {
        case 76...100: return "battery.100"
        case 51...75:  return "battery.75"
        case 26...50:  return "battery.50"
        case 11...25:  return "battery.25"
        default:       return "battery.0"
        }
    }
}

// MARK: - Window Manager
@MainActor
class DynamicIslandManager {
    static let shared = DynamicIslandManager()

    private var pillWindow:    NSPanel?
    private var panelWindow:   NSPanel?
    private weak var tracker:  BatteryTracker?
    private(set) var isEnabled = true
    private var cancellables   = Set<AnyCancellable>()
    private var globalMonitor: Any?
    private var localMonitor:  Any?

    // MARK: Setup
    func setup(with tracker: BatteryTracker) {
        self.tracker  = tracker
        self.isEnabled = tracker.enableDynamicIsland
        guard isEnabled else { return }
        buildWindows(for: tracker)
    }

    private func buildWindows(for tracker: BatteryTracker) {
        guard pillWindow == nil else { return }

        // Pill window at notch level
        pillWindow = makePanel()
        pillWindow?.level = NSWindow.Level(rawValue: Int(NSWindow.Level.mainMenu.rawValue) + 2)
        pillWindow?.contentView = NSHostingView(rootView: NotchPillView(tracker: tracker))

        // Panel window (drops below notch)
        panelWindow = makePanel()
        panelWindow?.level = NSWindow.Level(rawValue: Int(NSWindow.Level.mainMenu.rawValue) + 1)
        panelWindow?.alphaValue = 0
        panelWindow?.contentView = NSHostingView(rootView: DynamicIslandPanelView(tracker: tracker))

        // Observe state
        DynamicIslandStateManager.shared.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.applyState(state) }
            .store(in: &cancellables)

        positionPill()
        pillWindow?.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.positionPill() }
        }
    }

    // MARK: Mouse monitoring (hover expand/collapse)
    func startMonitoring() {
        guard globalMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in self?.evaluateHover() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in self?.evaluateHover() }
            return event
        }
    }

    private func evaluateHover() {
        guard isEnabled else { return }
        let mouse = NSEvent.mouseLocation
        let over  = (pillWindow?.frame.contains(mouse) ?? false)
                 || (panelWindow?.frame.contains(mouse) ?? false)

        switch DynamicIslandStateManager.shared.state {
        case .compact  where over:  DynamicIslandStateManager.shared.show(.expanded)
        case .expanded where !over: DynamicIslandStateManager.shared.show(.compact)
        default: break
        }
    }

    // MARK: Apply state → window frames
    private func applyState(_ state: DynamicIslandState) {
        guard let screen = NSScreen.main else { return }
        let sf      = screen.frame
        let notchH: CGFloat = max(screen.safeAreaInsets.top, 37)

        positionPill()
        pillWindow?.orderFrontRegardless()

        switch state {
        case .compact:
            // Collapse panel with fade
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                panelWindow?.animator().alphaValue = 0
            }) { [weak self] in
                self?.panelWindow?.orderOut(nil)
            }

        default:
            // Panel dimensions — NotchNook style: wide, short
            let pw: CGFloat
            let ph: CGFloat
            switch state {
            case .charging, .alert: (pw, ph) = (560, 100)
            default:                (pw, ph) = (600, 156)
            }

            let x = sf.minX + (sf.width - pw) / 2
            let y = sf.maxY - notchH - ph - 8   // 8pt gap below notch

            panelWindow?.setFrame(NSRect(x: x, y: y, width: pw, height: ph), display: true)
            panelWindow?.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration  = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panelWindow?.animator().alphaValue = 1
            }
        }
    }

    // MARK: Pill position (notch center)
    private func positionPill() {
        guard let screen = NSScreen.main else { return }
        let sf      = screen.frame
        let notchH: CGFloat = max(screen.safeAreaInsets.top, 37)
        // Wider pill showing tab labels
        let pillW:  CGFloat = 240
        let pillH:  CGFloat = notchH - 4

        let x = sf.minX + (sf.width - pillW) / 2
        let y = sf.maxY - notchH + 2
        pillWindow?.setFrame(NSRect(x: x, y: y, width: pillW, height: pillH), display: true)
    }

    // MARK: Factory
    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isReleasedWhenClosed      = false
        p.backgroundColor           = .clear
        p.isOpaque                  = false
        p.hasShadow                 = false
        p.collectionBehavior        = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovableByWindowBackground = false
        p.ignoresMouseEvents        = false
        return p
    }

    // MARK: Public API
    func updateSettings(enabled: Bool) {
        self.isEnabled = enabled
        if enabled {
            if pillWindow == nil, let t = tracker { buildWindows(for: t) }
            else { positionPill(); pillWindow?.orderFrontRegardless() }
        } else {
            pillWindow?.orderOut(nil)
            panelWindow?.orderOut(nil)
        }
    }

    func trigger(_ state: DynamicIslandState) {
        guard isEnabled else { return }
        DynamicIslandStateManager.shared.trigger(state)
    }
}
