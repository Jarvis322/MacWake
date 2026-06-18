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

    // Physical notch dimensions (set by the manager from the active screen)
    @Published var notchWidth: CGFloat = 200
    @Published var notchHeight: CGFloat = 32

    // NotchDrop's signature spring — bouncy, organic open/close.
    static let springAnimation: Animation = .interactiveSpring(
        duration: 0.5, extraBounce: 0.25, blendDuration: 0.125
    )

    func show(_ newState: DynamicIslandState, autoDismissAfter seconds: TimeInterval? = nil) {
        withAnimation(Self.springAnimation) { state = newState }
        guard let seconds else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.state == newState else { return }
            withAnimation(Self.springAnimation) { self.state = .compact }
        }
    }

    func trigger(_ newState: DynamicIslandState) {
        switch newState {
        case .charging: show(newState, autoDismissAfter: 5.0)
        default: show(newState)
        }
    }
}

// MARK: - Screen notch detection
extension NSScreen {
    /// Physical notch size, or .zero on non-notch displays. (NotchDrop technique)
    var miNotchSize: CGSize {
        guard safeAreaInsets.top > 0 else { return .zero }
        let h = safeAreaInsets.top
        let left = auxiliaryTopLeftArea?.width ?? 0
        let right = auxiliaryTopRightArea?.width ?? 0
        guard left > 0, right > 0 else { return .zero }
        return CGSize(width: frame.width - left - right, height: h)
    }
}

// MARK: - Panel View (NotchDrop-style)
struct DynamicIslandPanelView: View {
    @ObservedObject var tracker: BatteryTracker
    @ObservedObject private var sm = DynamicIslandStateManager.shared

    private let openedSize = CGSize(width: 580, height: 270)
    private let flareSpacing: CGFloat = 16   // size of the concave top-corner flare

    private var isOpened: Bool { sm.state != .compact }

    // The black body size: device-notch sized when closed, panel sized when opened.
    private var notchSize: CGSize {
        if isOpened { return openedSize }
        return CGSize(
            width: max(sm.notchWidth - 4, 0),
            height: max(sm.notchHeight - 4, 0)
        )
    }

    private var cornerRadius: CGFloat { isOpened ? 32 : 8 }

    var body: some View {
        ZStack(alignment: .top) {
            notch
                .zIndex(0)

            if isOpened {
                openedContent
                    .frame(width: openedSize.width, height: openedSize.height, alignment: .top)
                    .zIndex(1)
                    .transition(
                        .scale.combined(with: .opacity)
                            .combined(with: .offset(y: -openedSize.height / 2))
                            .animation(DynamicIslandStateManager.springAnimation)
                    )
            }
        }
        .monospacedDigit()
        .preferredColorScheme(.dark)
        .animation(DynamicIslandStateManager.springAnimation, value: sm.state)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - The notch body (black shape with concave top corners)
    private var notch: some View {
        Rectangle()
            .foregroundStyle(.black)
            .mask(notchMask)
            .frame(
                width: notchSize.width + cornerRadius * 2,
                height: notchSize.height
            )
            .shadow(color: .black.opacity(isOpened ? 0.9 : 0), radius: 16)
    }

    /// NotchDrop's mask: a bottom-rounded rectangle, with the two top corners carved into
    /// concave curves via `blendMode(.destinationOut)` so the body flares into the bezel.
    private var notchMask: some View {
        let r = cornerRadius
        let s = flareSpacing
        return Rectangle()
            .foregroundStyle(.black)
            .frame(width: notchSize.width, height: notchSize.height)
            .clipShape(.rect(bottomLeadingRadius: r, bottomTrailingRadius: r))
            .overlay {
                // Top-left concave flare
                ZStack(alignment: .topTrailing) {
                    Rectangle()
                        .frame(width: r, height: r)
                        .foregroundStyle(.black)
                    Rectangle()
                        .clipShape(.rect(topTrailingRadius: r))
                        .foregroundStyle(.white)
                        .frame(width: r + s, height: r + s)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .offset(x: -r - s + 0.5, y: -0.5)
            }
            .overlay {
                // Top-right concave flare
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .frame(width: r, height: r)
                        .foregroundStyle(.black)
                    Rectangle()
                        .clipShape(.rect(topLeadingRadius: r))
                        .foregroundStyle(.white)
                        .frame(width: r + s, height: r + s)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .offset(x: r + s - 0.5, y: -0.5)
            }
    }

    // MARK: - Opened content (battery panel), pushed clear of the physical notch
    private var openedContent: some View {
        Group {
            if sm.state == .expanded {
                VStack(spacing: 14) {
                    expandedContent
                    controlsRow
                }
            } else if sm.state == .charging {
                chargingContent
            } else if case let .alert(t, m, w) = sm.state {
                alertContent(title: t, message: m, isWarning: w)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, sm.notchHeight + 8)   // clear the camera/notch headline
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Functional controls (real MacWake actions)
    private var controlsRow: some View {
        HStack(spacing: 10) {
            controlButton(
                icon: "rectangle.on.rectangle",
                label: "Widget",
                active: tracker.showWidget
            ) { tracker.showWidget.toggle() }

            controlButton(
                icon: "arrow.counterclockwise",
                label: "Reset",
                active: false
            ) { tracker.resetCurrentSession() }

            controlButton(
                icon: "sparkles",
                label: "Animate",
                active: tracker.enableAnimations
            ) { tracker.enableAnimations.toggle() }

            controlButton(
                icon: "bell.fill",
                label: "Notify",
                active: tracker.notificationStatus == .authorized
            ) {
                if tracker.notificationStatus == .authorized {
                    tracker.openNotificationSettings()
                } else {
                    tracker.requestNotificationAuthorization()
                }
            }
        }
    }

    private func controlButton(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(active ? .black : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(active ? Color.white.opacity(0.92) : Color.white.opacity(0.12))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
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

// MARK: - Window Manager (NotchDrop-style)
@MainActor
class DynamicIslandManager {
    static let shared = DynamicIslandManager()

    // The window is a fixed full-width strip across the top; the SwiftUI content
    // morphs the notch shape. Height comfortably fits the opened panel.
    private let stripHeight: CGFloat = 300
    private let openedSize = CGSize(width: 580, height: 270)
    private let hoverInset: CGFloat = -4   // expands the notch hover target a touch

    private var islandWindow: NSPanel?
    private weak var tracker: BatteryTracker?
    private(set) var isEnabled = true
    private var cancellables = Set<AnyCancellable>()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var expandWorkItem: DispatchWorkItem?
    private var collapseWorkItem: DispatchWorkItem?

    // Hit-test rects in screen coordinates.
    private var deviceNotchRect: CGRect = .zero
    private var openedRect: CGRect = .zero

    func hoverDidEnter() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        guard DynamicIslandStateManager.shared.state == .compact else { return }
        guard expandWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.openPanel() }
        }
        expandWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func hoverDidExit() {
        expandWorkItem?.cancel()
        expandWorkItem = nil
        // Only auto-close the user-opened panel; charging/alert dismiss on their own timer.
        guard DynamicIslandStateManager.shared.state == .expanded else { return }
        guard collapseWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.closePanel() }
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // Centralized open/close with NotchDrop-style haptic feedback.
    private func openPanel() {
        guard DynamicIslandStateManager.shared.state == .compact else { return }
        expandWorkItem = nil
        performHaptic()
        DynamicIslandStateManager.shared.show(.expanded)
    }

    private func closePanel() {
        guard DynamicIslandStateManager.shared.state == .expanded else { return }
        collapseWorkItem = nil
        performHaptic()
        DynamicIslandStateManager.shared.show(.compact)
    }

    private func performHaptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    func setup(with tracker: BatteryTracker) {
        self.tracker = tracker
        self.isEnabled = tracker.enableDynamicIsland
        guard isEnabled else { return }
        buildWindow(for: tracker)
    }

    private func buildWindow(for tracker: BatteryTracker) {
        guard islandWindow == nil else { return }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.level = .statusBar + 8       // above the menu bar, like NotchDrop
        panel.ignoresMouseEvents = true    // never block menu-bar clicks; hover via global monitor
        panel.contentView = NSHostingView(rootView: DynamicIslandPanelView(tracker: tracker))
        islandWindow = panel

        positionWindow()
        panel.orderFrontRegardless()
        setupMouseMonitors()

        // Make the panel clickable only while expanded (controls); pass clicks
        // through to the menu bar otherwise.
        DynamicIslandStateManager.shared.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.islandWindow?.ignoresMouseEvents = (state != .expanded)
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.positionWindow() }
        }
    }

    private func setupMouseMonitors() {
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
                Task { @MainActor in
                    if event.type == .leftMouseDown { self?.handleMouseDown() }
                    else { self?.handleMouseMoved() }
                }
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
                Task { @MainActor in
                    if event.type == .leftMouseDown { self?.handleMouseDown() }
                    else { self?.handleMouseMoved() }
                }
                return event
            }
        }
    }

    private func handleMouseDown() {
        guard isEnabled else { return }
        let mouse = NSEvent.mouseLocation
        switch DynamicIslandStateManager.shared.state {
        case .compact:
            // Click on the notch opens the panel.
            if deviceNotchRect.insetBy(dx: hoverInset, dy: hoverInset).contains(mouse) {
                openPanel()
            }
        case .expanded:
            // Click outside the panel closes it; clicks inside fall through to the controls.
            if !openedRect.contains(mouse) {
                closePanel()
            }
        default:
            break
        }
    }

    private func handleMouseMoved() {
        guard isEnabled else { return }
        let mouse = NSEvent.mouseLocation
        let state = DynamicIslandStateManager.shared.state

        if state == .compact {
            if deviceNotchRect.insetBy(dx: hoverInset, dy: hoverInset).contains(mouse) {
                hoverDidEnter()
            } else {
                expandWorkItem?.cancel()
                expandWorkItem = nil
            }
        } else if state == .expanded {
            if openedRect.contains(mouse) {
                collapseWorkItem?.cancel()
                collapseWorkItem = nil
            } else {
                hoverDidExit()
            }
        }
    }

    private func positionWindow() {
        guard let screen = NSScreen.main, let win = islandWindow else { return }
        let sf = screen.frame

        // Detect the physical notch (falls back to a sensible pill on non-notch Macs).
        var ns = screen.miNotchSize
        if ns == .zero { ns = CGSize(width: 180, height: 32) }
        DynamicIslandStateManager.shared.notchWidth = ns.width
        DynamicIslandStateManager.shared.notchHeight = ns.height

        // Full-width strip pinned to the very top.
        let frame = NSRect(x: sf.minX, y: sf.maxY - stripHeight, width: sf.width, height: stripHeight)
        win.setFrame(frame, display: true)

        // Screen-coordinate hit-test rects.
        deviceNotchRect = CGRect(
            x: sf.minX + (sf.width - ns.width) / 2,
            y: sf.maxY - ns.height,
            width: ns.width, height: ns.height
        )
        openedRect = CGRect(
            x: sf.minX + (sf.width - openedSize.width) / 2,
            y: sf.maxY - openedSize.height,
            width: openedSize.width, height: openedSize.height
        )
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
