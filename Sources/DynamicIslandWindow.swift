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
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { state = newState }
        guard let seconds else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.state == newState else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { self.state = .compact }
        }
    }

    func trigger(_ newState: DynamicIslandState) {
        switch newState {
        case .charging: show(newState, autoDismissAfter: 5.0)
        default: show(newState)
        }
    }
}

// MARK: - TrackingHostingView
final class TrackingHostingView<Content: View>: NSHostingView<Content> {
    override func mouseEntered(with event: NSEvent) {
        DynamicIslandManager.shared.hoverDidEnter()
    }
    override func mouseExited(with event: NSEvent) {
        DynamicIslandManager.shared.hoverDidExit()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Panel View
struct DynamicIslandPanelView: View {
    @ObservedObject var tracker: BatteryTracker
    @ObservedObject private var sm = DynamicIslandStateManager.shared

    private var isExpanded: Bool {
        switch sm.state {
        case .compact: return false
        default: return true
        }
    }

    var body: some View {
        // Panel is always 580×220. The visible shape morphs via SwiftUI spring —
        // no NSWindow frame animation needed, giving a true NotchNook-style liquid expand.
        ZStack(alignment: .top) {
            // Single continuous shape that morphs: compact pill → full panel
            RoundedRectangle(cornerRadius: blobRadius, style: .continuous)
                .fill(Color.black.opacity(0.88))
                .background(
                    RoundedRectangle(cornerRadius: blobRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: blobRadius, style: .continuous)
                        .stroke(Color.white.opacity(isExpanded ? 0.1 : 0), lineWidth: 1)
                )
                .frame(width: blobWidth, height: blobHeight)

            VStack(spacing: 0) {
                topBar
                    .frame(height: 36)
                    .padding(.top, 2)

                if sm.state == .expanded {
                    expandedContent
                        .padding(.top, 8)
                        .padding(.horizontal, 20)
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if sm.state == .charging {
                    chargingContent
                        .padding(.top, 12)
                        .padding(.horizontal, 20)
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if case let .alert(t, m, w) = sm.state {
                    alertContent(title: t, message: m, isWarning: w)
                        .padding(.top, 12)
                        .padding(.horizontal, 20)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(width: blobWidth)
        }
        // Fill the fixed 580×220 NSPanel, content anchored at top
        .frame(width: 580, height: 220, alignment: .top)
        .monospacedDigit()
        .animation(.spring(response: 0.38, dampingFraction: 0.72), value: sm.state)
    }

    // Blob geometry — all morphed by SwiftUI spring, NSPanel never resizes
    private var blobWidth: CGFloat {
        switch sm.state {
        case .compact: return 200
        default: return 580
        }
    }

    private var blobHeight: CGFloat {
        switch sm.state {
        case .compact: return 36
        case .charging, .alert: return 120
        case .expanded: return 220
        }
    }

    private var blobRadius: CGFloat {
        sm.state == .compact ? 20 : 32
    }

    // MARK: - Top Bar
    private var topBar: some View {
        HStack {
            if sm.state == .expanded {
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(tracker.isPluggedIn ? .blue : batteryColor)
                        Text("Power")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.15))
                    .cornerRadius(12)
                }
                .padding(.leading, 16)

                Spacer()
            } else {
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: tracker.isPluggedIn ? "bolt.fill" : "battery.75")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(tracker.isPluggedIn ? .blue : batteryColor)
                    Text("\(tracker.currentBatteryLevel)%")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                }
                Spacer()
            }
        }
    }

    // MARK: - Expanded Content (two-column)
    private var expandedContent: some View {
        HStack(spacing: 20) {
            leftWidget
                .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1)
                .padding(.vertical, 10)

            rightWidget
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Left Widget (Power)
    private var leftWidget: some View {
        HStack(spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(
                        colors: [batteryColor.opacity(0.25), batteryColor.opacity(0.1)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 80, height: 80)
                    .overlay(
                        Image(systemName: tracker.isPluggedIn ? "bolt.batteryblock.fill" : "battery.100")
                            .font(.system(size: 32))
                            .foregroundStyle(LinearGradient(
                                colors: [batteryColor.opacity(0.9), batteryColor],
                                startPoint: .top, endPoint: .bottom))
                    )
                Circle()
                    .fill(batteryColor)
                    .frame(width: 24, height: 24)
                    .overlay(
                        Image(systemName: tracker.isPluggedIn ? "bolt.fill" : "leaf.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.black)
                    )
                    .offset(x: 6, y: 6)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(tracker.isPluggedIn ? "Charging" : "On Battery")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Text("\(tracker.currentBatteryLevel)% Capacity")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))

                if let dyn = tracker.dynamicWatts {
                    Text(String(format: "%.1fW", dyn))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundColor(.cyan)
                } else if let w = tracker.powerAdapterWatts {
                    Text("\(w)W Adapter")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.55))
                } else if let name = tracker.powerAdapterName {
                    Text(name)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                }

                if !tracker.isPluggedIn {
                    let secs = Int(tracker.currentScreenOnSeconds)
                    let h = secs / 3600
                    let m = (secs % 3600) / 60
                    Text(h > 0 ? "\(h)h \(m)m screen on" : "\(m)m screen on")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
        }
    }

    // MARK: - Right Widget (Thermals)
    private var rightWidget: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Fan")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.4))
                    .textCase(.uppercase)
                if tracker.hasFans, let rpm = tracker.currentFanSpeed {
                    Text("\(Int(rpm)) RPM")
                        .font(.system(size: 22, weight: .bold).monospacedDigit())
                        .foregroundColor(.white)
                } else {
                    Text("Fanless")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Temperature")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.4))
                    .textCase(.uppercase)
                HStack(alignment: .bottom, spacing: 6) {
                    let samples = tracker.temperatureSamples.isEmpty
                        ? [tracker.batteryTemperature]
                        : tracker.temperatureSamples
                    let maxTemp = max(samples.max() ?? 1, 1)
                    ForEach(Array(samples.enumerated()), id: \.offset) { _, temp in
                        VStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(temp > 45 ? Color.red.opacity(0.8) : Color.cyan.opacity(0.7))
                                .frame(width: 14, height: max(CGFloat(temp / maxTemp) * 40, 4))
                            Text(String(format: "%.0f°", temp))
                                .font(.system(size: 8))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                }
                .frame(height: 56, alignment: .bottom)
            }

            HStack(spacing: 8) {
                statChip(label: "Health", value: "\(tracker.batteryHealth)%", highlight: tracker.batteryHealth < 80)
                statChip(label: "Cycles", value: "\(tracker.batteryCycles)", highlight: false)
            }
        }
        .padding(.trailing, 10)
    }

    private func statChip(label: String, value: String, highlight: Bool) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(highlight ? .red : .white.opacity(0.4))
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(highlight ? .red : .white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.08))
        .cornerRadius(8)
    }

    // MARK: - Charging Content
    private var chargingContent: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.2))
                    .frame(width: 64, height: 64)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.blue)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Charging Connected")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                Text("\(tracker.currentBatteryLevel)% • \(tracker.powerAdapterWatts.map { "\($0)W" } ?? "Power Source")")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
            }
            Spacer()
        }
    }

    // MARK: - Alert Content
    private func alertContent(title: String, message: String, isWarning: Bool) -> some View {
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill((isWarning ? Color.orange : Color.red).opacity(0.2))
                    .frame(width: 64, height: 64)
                Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "flame.fill")
                    .font(.system(size: 32))
                    .foregroundColor(isWarning ? .orange : .red)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
            }
            Spacer()
        }
    }

    private var batteryColor: Color {
        tracker.currentBatteryLevel > 50 ? .green : (tracker.currentBatteryLevel > 20 ? .orange : .red)
    }
}

// MARK: - Window Manager
@MainActor
class DynamicIslandManager {
    static let shared = DynamicIslandManager()

    private var islandWindow: NSPanel?
    private weak var tracker: BatteryTracker?
    private(set) var isEnabled = true
    private var cancellables = Set<AnyCancellable>()
    private var expandWorkItem: DispatchWorkItem?
    private var collapseWorkItem: DispatchWorkItem?

    func hoverDidEnter() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        guard DynamicIslandStateManager.shared.state == .compact else { return }
        // The NSPanel is always 580×220; only expand if mouse is over the compact pill (center 200×36).
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.main else { return }
        let pillRect = CGRect(
            x: screen.frame.midX - 100,
            y: screen.frame.maxY - 36,
            width: 200,
            height: 36
        )
        guard pillRect.contains(mouse) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard self != nil else { return }
            Task { @MainActor in
                guard DynamicIslandStateManager.shared.state == .compact else { return }
                DynamicIslandStateManager.shared.show(.expanded)
            }
        }
        expandWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func hoverDidExit() {
        expandWorkItem?.cancel()
        expandWorkItem = nil
        guard DynamicIslandStateManager.shared.state == .expanded else { return }
        let work = DispatchWorkItem { [weak self] in
            guard self != nil else { return }
            Task { @MainActor in
                guard DynamicIslandStateManager.shared.state == .expanded else { return }
                DynamicIslandStateManager.shared.show(.compact)
            }
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: work)
    }

    func setup(with tracker: BatteryTracker) {
        self.tracker = tracker
        self.isEnabled = tracker.enableDynamicIsland
        guard isEnabled else { return }
        buildWindow(for: tracker)
    }

    private func buildWindow(for tracker: BatteryTracker) {
        guard islandWindow == nil else { return }

        islandWindow = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        islandWindow?.isReleasedWhenClosed = false
        islandWindow?.backgroundColor = .clear
        islandWindow?.isOpaque = false
        islandWindow?.hasShadow = false
        islandWindow?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        islandWindow?.level = .popUpMenu

        islandWindow?.contentView = TrackingHostingView(rootView: DynamicIslandPanelView(tracker: tracker))

        positionWindow()
        islandWindow?.orderFrontRegardless()

        DynamicIslandStateManager.shared.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.updateWindowFrame(for: state) }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.positionWindow() }
        }
    }

    private func positionWindow() {
        updateWindowFrame(for: DynamicIslandStateManager.shared.state)
    }

    private func updateWindowFrame(for state: DynamicIslandState) {
        guard let screen = NSScreen.main, let win = islandWindow else { return }
        let sf = screen.frame

        // Panel is always 580×220 — SwiftUI spring morphs the visible blob shape.
        // No NSWindow frame animation; avoids the jerky AppKit resize.
        let w: CGFloat = 580
        let h: CGFloat = 220
        let x = sf.minX + (sf.width - w) / 2
        let y = sf.maxY - h

        let targetFrame = NSRect(x: x, y: y, width: w, height: h)
        win.setFrame(targetFrame, display: true)

        // If mouse is already inside the panel area when the window is placed,
        // mouseEntered never fires — trigger hover check manually.
        if targetFrame.contains(NSEvent.mouseLocation) {
            hoverDidEnter()
        }

        if let cv = win.contentView {
            cv.trackingAreas.forEach { cv.removeTrackingArea($0) }
            let area = NSTrackingArea(
                rect: CGRect(origin: .zero, size: CGSize(width: w, height: h)),
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: cv,
                userInfo: nil
            )
            cv.addTrackingArea(area)
        }
    }

    func updateSettings(enabled: Bool) {
        self.isEnabled = enabled
        if enabled {
            if islandWindow == nil, let t = tracker { buildWindow(for: t) }
            else { islandWindow?.orderFrontRegardless() }
        } else {
            islandWindow?.orderOut(nil)
        }
    }

    func trigger(_ state: DynamicIslandState) {
        guard isEnabled else { return }
        DynamicIslandStateManager.shared.trigger(state)
    }
}
