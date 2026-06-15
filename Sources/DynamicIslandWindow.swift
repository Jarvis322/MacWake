import SwiftUI
import AppKit
import Combine

// MARK: - State Enum
enum DynamicIslandState: Equatable {
    case compact
    case charging
    case alert(title: String, message: String, isWarning: Bool)
    case expanded
}

// MARK: - Observable State Manager
@MainActor
class DynamicIslandStateManager: ObservableObject {
    static let shared = DynamicIslandStateManager()

    @Published private(set) var state: DynamicIslandState = .compact

    func show(_ newState: DynamicIslandState, autoDismissAfter seconds: TimeInterval? = nil) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
            state = newState
        }
        guard let seconds else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.state == newState else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
                self.state = .compact
            }
        }
    }

    func trigger(_ newState: DynamicIslandState) {
        switch newState {
        case .charging: show(newState, autoDismissAfter: 4.0)
        default:        show(newState)
        }
    }
}

// MARK: - Compact Pill (sits in notch / menu-bar center)
struct NotchPillView: View {
    @ObservedObject var tracker: BatteryTracker

    var body: some View {
        HStack(spacing: 7) {
            if tracker.highTempAlert {
                Image(systemName: "thermometer.high")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.red)
            } else if tracker.continuousACAlert {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.orange)
            } else if tracker.isPluggedIn {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.blue)
            } else {
                Image(systemName: "battery.75")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(batteryColor)
            }
            Text("%\(tracker.currentBatteryLevel)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var batteryColor: Color {
        tracker.currentBatteryLevel > 50 ? .green : (tracker.currentBatteryLevel > 20 ? .orange : .red)
    }
}

// MARK: - Expanded Panel (grows down from notch)
struct DynamicIslandPanelView: View {
    @ObservedObject var tracker: BatteryTracker
    @ObservedObject private var sm = DynamicIslandStateManager.shared

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 0) {
                switch sm.state {
                case .charging:
                    chargingContent.padding(18)
                case .alert(let t, let m, let w):
                    alertContent(title: t, message: m, isWarning: w).padding(18)
                default:
                    statsContent.padding(16)
                }
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
    }

    // MARK: Charging
    private var chargingContent: some View {
        HStack(spacing: 14) {
            iconCircle("bolt.ring.closed", color: .green)
            VStack(alignment: .leading, spacing: 4) {
                Text("Şarj Ediliyor")
                    .font(.system(size: 15, weight: .semibold))
                if let w = tracker.powerAdapterWatts {
                    Text("\(w) W adaptör  •  %\(tracker.currentBatteryLevel) dolu")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                } else {
                    Text("Güç bağlı  •  %\(tracker.currentBatteryLevel) dolu")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
            Spacer()
        }
    }

    // MARK: Alert
    private func alertContent(title: String, message: String, isWarning: Bool) -> some View {
        HStack(spacing: 14) {
            iconCircle(
                isWarning ? "exclamationmark.triangle.fill" : "thermometer.high",
                color: isWarning ? .orange : .red
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isWarning ? .orange : .red)
                Text(message)
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
    }

    // MARK: Stats
    private var statsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.shield.fill")
                        .font(.system(size: 11, weight: .bold)).foregroundColor(.blue)
                    Text("MacWake")
                        .font(.system(size: 13, weight: .bold))
                }
                Spacer()
                statusBadge
            }

            Divider().opacity(0.4)

            HStack(spacing: 0) {
                statCell(icon: "battery.100",
                         value: "%\(tracker.currentBatteryLevel)",
                         label: "Pil", color: batteryColor)
                statDiv
                statCell(icon: "thermometer.medium",
                         value: String(format: "%.0f°", tracker.batteryTemperature),
                         label: "Sıcaklık",
                         color: tracker.batteryTemperature > 35 ? .orange : .cyan)
                statDiv
                statCell(icon: "heart.fill",
                         value: "%\(tracker.batteryHealth)",
                         label: "Sağlık",
                         color: tracker.batteryHealth > 80 ? .green : .orange)
                if tracker.hasFans {
                    statDiv
                    statCell(icon: "fan.fill",
                             value: tracker.currentFanSpeed.map { String(format: "%.0f", $0) } ?? "—",
                             label: "RPM", color: .purple)
                }
            }
        }
    }

    // MARK: Helpers
    private var statusBadge: some View {
        Text(tracker.isPluggedIn ? "Şarjda" : "Pilde")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(tracker.isPluggedIn ? .blue : .green)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(tracker.isPluggedIn
                ? Color.blue.opacity(0.15) : Color.green.opacity(0.15)))
    }

    private func iconCircle(_ name: String, color: Color) -> some View {
        ZStack {
            Circle().fill(color.opacity(0.15)).frame(width: 46, height: 46)
            Image(systemName: name).font(.system(size: 22)).foregroundColor(color)
        }
    }

    private func statCell(icon: String, value: String, label: String, color: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundColor(color)
            Text(value).font(.system(size: 16, weight: .bold, design: .rounded))
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDiv: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1, height: 44)
    }

    private var batteryColor: Color {
        tracker.currentBatteryLevel > 50 ? .green : (tracker.currentBatteryLevel > 20 ? .orange : .red)
    }
}

// MARK: - Window Manager
@MainActor
class DynamicIslandManager {
    static let shared = DynamicIslandManager()

    private var pillWindow:  NSPanel?
    private var panelWindow: NSPanel?
    private weak var tracker: BatteryTracker?
    private(set) var isEnabled = true
    private var cancellables = Set<AnyCancellable>()
    private var globalMonitor: Any?
    private var localMonitor:  Any?

    // MARK: Setup
    func setup(with tracker: BatteryTracker) {
        self.tracker = tracker
        self.isEnabled = tracker.enableDynamicIsland
        guard isEnabled else { return }
        buildWindows(for: tracker)
    }

    private func buildWindows(for tracker: BatteryTracker) {
        guard pillWindow == nil else { return }

        // Pill (compact indicator at notch level)
        pillWindow = makePanel()
        pillWindow?.level = NSWindow.Level(rawValue: Int(NSWindow.Level.mainMenu.rawValue) + 2)
        pillWindow?.contentView = NSHostingView(rootView: NotchPillView(tracker: tracker))

        // Panel (expanded content below notch)
        panelWindow = makePanel()
        panelWindow?.level = NSWindow.Level(rawValue: Int(NSWindow.Level.mainMenu.rawValue) + 1)
        panelWindow?.hasShadow = false
        panelWindow?.alphaValue = 0
        panelWindow?.contentView = NSHostingView(rootView: DynamicIslandPanelView(tracker: tracker))

        // Observe state
        DynamicIslandStateManager.shared.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.applyState(state) }
            .store(in: &cancellables)

        positionPill()
        pillWindow?.orderFrontRegardless()

        // Screen changes
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.positionPill() }
        }
    }

    // MARK: Mouse monitoring (hover to expand/collapse)
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
        let over = (pillWindow?.frame.contains(mouse) ?? false)
                || (panelWindow?.frame.contains(mouse) ?? false)

        let current = DynamicIslandStateManager.shared.state
        if over, case .compact = current {
            DynamicIslandStateManager.shared.show(.expanded)
        } else if !over, case .expanded = current {
            DynamicIslandStateManager.shared.show(.compact)
        }
    }

    // MARK: State → window frames
    private func applyState(_ state: DynamicIslandState) {
        guard let screen = NSScreen.main else { return }
        let sf = screen.frame
        let notchH: CGFloat = max(screen.safeAreaInsets.top, 37)

        positionPill()
        pillWindow?.orderFrontRegardless()

        switch state {
        case .compact:
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                panelWindow?.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                self?.panelWindow?.orderOut(nil)
            }

        default:
            let (pw, ph): (CGFloat, CGFloat)
            switch state {
            case .charging, .alert: (pw, ph) = (340, 90)
            default:                (pw, ph) = (360, 148)
            }

            let x = sf.minX + (sf.width - pw) / 2
            let y = sf.maxY - notchH - ph - 6   // 6pt gap below notch bottom edge

            panelWindow?.setFrame(NSRect(x: x, y: y, width: pw, height: ph), display: true)
            panelWindow?.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panelWindow?.animator().alphaValue = 1
            }
        }
    }

    // MARK: Pill frame (inside notch/menu-bar center)
    private func positionPill() {
        guard let screen = NSScreen.main else { return }
        let sf = screen.frame
        let notchH: CGFloat = max(screen.safeAreaInsets.top, 37)
        let pillW:  CGFloat = 160
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
        p.isReleasedWhenClosed = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovableByWindowBackground = false
        p.ignoresMouseEvents = false
        return p
    }

    // MARK: Public
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
