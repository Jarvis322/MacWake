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

    // Invalidates any previously scheduled auto-dismiss whenever a new state is shown, so
    // two quick triggers (e.g. unplug/replug) can't have the OLDER dismiss fire and cut the
    // newer notification short. Comparing `state == newState` alone isn't enough since two
    // unrelated triggers can carry an equal (or both `.charging`) payload.
    private var dismissGeneration = 0

    func show(_ newState: DynamicIslandState, autoDismissAfter seconds: TimeInterval? = nil) {
        withAnimation(Self.springAnimation) { state = newState }
        dismissGeneration += 1
        guard let seconds else { return }
        let myGeneration = dismissGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.dismissGeneration == myGeneration else { return }
            withAnimation(Self.springAnimation) { self.state = .compact }
        }
    }

    func trigger(_ newState: DynamicIslandState) {
        switch newState {
        case .charging: show(newState, autoDismissAfter: 5.0)
        case .alert:    show(newState, autoDismissAfter: 6.0)
        default:        show(newState)
        }
    }

    /// Immediately collapse the island (e.g. when a calibration is cancelled).
    func dismiss() {
        dismissGeneration += 1   // invalidate any still-pending scheduled auto-dismiss
        withAnimation(Self.springAnimation) { state = .compact }
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
    @ObservedObject private var chargeLimit = ChargeLimitManager.shared
    #if !APPSTORE
    @ObservedObject private var nowPlaying = NowPlayingManager.shared
    #endif

    private var openedSize: CGSize {
        DynamicIslandManager.openedSize(shelfEnabled: tracker.enableNotchShelf, musicShown: DynamicIslandManager.musicShown)
    }
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
            // Rasterize the masked shape offscreen via Metal so the concave-corner
            // `blendMode(.destinationOut)` flares composite deterministically. Without
            // this, some Macs (e.g. M2 Air) intermittently leave a white/transparent
            // gap on a top corner until the island is toggled.
            .drawingGroup()
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
                expandedContent
            } else if sm.state == .charging {
                chargingContent
            } else if case let .alert(t, m, w) = sm.state {
                alertContent(title: t, message: m, isWarning: w)
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, sm.notchHeight + 8)   // clear the camera/notch headline
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottomTrailing) {
            // With the menu bar emptied on purpose the island is the only thing left to click,
            // so it carries the way back — nothing else on screen would say how to find Settings.
            if sm.state == .expanded, !tracker.menuBarItemVisible {
                Button { tracker.revealMenuBarItem() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "menubar.rectangle")
                        Text("SHOW_MENUBAR_ICON")
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 22).padding(.bottom, 8)
            }
        }
    }

    // MARK: - Expanded Content (Power | Thermals, plus an optional Shelf column)
    private var expandedContent: some View {
        HStack(spacing: DynamicIslandManager.columnSpacing) {
            leftWidget
                .frame(width: DynamicIslandManager.powerColumnWidth, alignment: .leading)

            // Temperatures/fan need SMC access — dead inside the App Store sandbox,
            // so the whole column is dropped there rather than showing zeros.
            if !Distribution.isAppStore {
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 1)
                    .padding(.vertical, 8)

                rightWidget
                    .frame(width: DynamicIslandManager.tempColumnWidth, alignment: .leading)
            }

            #if !APPSTORE
            if nowPlaying.isEnabled, nowPlaying.info != nil {
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 1)
                    .padding(.vertical, 8)

                NowPlayingView()
            }
            #endif

            // The Shelf is the reason to open the panel — drop files in, grab the last
            // thing you copied — so it sits at the end of the row and is on by default.
            if tracker.enableNotchShelf {
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 1)
                    .padding(.vertical, 8)

                NotchShelfView()
            }
        }
    }

    // MARK: - Left Widget (Power) — charge ring, live readout, capacity meter
    private var leftWidget: some View {
        batteryInfoColumn
            .fixedSize(horizontal: true, vertical: false)
    }

    /// The Mac can be physically on the adapter while macOS reports "on battery" — MacWake's
    /// own limit cuts the adapter to hold the level (see `isHoldingChargeOff`).
    private var isHoldingAtLimit: Bool { chargeLimit.isEnabled && chargeLimit.isHoldingChargeOff }

    private var batteryInfoColumn: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                IslandChargeRing(
                    level: tracker.currentBatteryLevel,
                    tint: batteryColor,
                    plugged: tracker.isPluggedIn,
                    limit: chargeLimit.isEnabled ? chargeLimit.limit : nil,
                    sailingLower: chargeLimit.isEnabled && chargeLimit.sailingEnabled ? chargeLimit.sailingLower : nil,
                    animated: tracker.enableAnimations
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(tracker.currentBatteryLevel)%")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                    Text(stateText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isHoldingAtLimit ? .cyan : .white.opacity(0.6))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    powerReadout
                }
            }

            IslandHealthMeter(health: tracker.batteryHealth, cycles: tracker.batteryCycles)
        }
    }

    private var stateText: String {
        if isHoldingAtLimit {
            return String(format: String(localized: "ISLAND_HOLDING_FMT"), chargeLimit.limit)
        }
        return tracker.isPluggedIn ? String(localized: "Charging") : String(localized: "On Battery")
    }

    @ViewBuilder
    private var powerReadout: some View {
        if tracker.isPluggedIn, let dyn = tracker.dynamicWatts {
            wattBadge(String(format: "%.1f W", dyn))
        } else if tracker.isPluggedIn, let w = tracker.powerAdapterWatts {
            wattBadge("\(w) W")
        }

        // While MacWake holds the adapter off, the battery is draining by design — a
        // "time left" or screen-on figure would describe a discharge that isn't real use.
        if !isHoldingAtLimit, let remaining = BatteryTimeEstimate.label(
            isPluggedIn: tracker.isPluggedIn,
            timeToFullCharge: tracker.timeToFullCharge,
            timeToEmpty: tracker.remainingBatteryEstimate
        ) {
            Text(String(
                format: tracker.isPluggedIn ? String(localized: "ISLAND_FULL_FMT") : String(localized: "ISLAND_LEFT_FMT"),
                MenuBarLabel.duration(seconds: remaining, compact: false)
            ))
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(0.5))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }

        if !tracker.isPluggedIn, !isHoldingAtLimit {
            let secs = Int(tracker.currentScreenOnSeconds)
            let h = secs / 3600, m = (secs % 3600) / 60
            Text(h > 0
                 ? String(format: String(localized: "SCREEN_ON_HM_FMT"), h, m)
                 : String(format: String(localized: "SCREEN_ON_M_FMT"), m))
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))
                .lineLimit(1)
        }
    }

    private func wattBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold).monospacedDigit())
            .foregroundColor(.cyan)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.cyan.opacity(0.15))
            .cornerRadius(7)
    }

    // MARK: - Right Widget (Thermals) — one gauge row per sensor
    private var rightWidget: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("TEMPERATURES")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.4))

            IslandThermalRow(label: "BATTERY", value: tracker.batteryTemperature > 0 ? tracker.batteryTemperature : nil, scale: .battery)
            IslandThermalRow(label: "CPU", value: tracker.cpuTemperature, scale: .soc)
            IslandThermalRow(label: "SSD", value: tracker.ssdTemperature, scale: .soc)
            // GPU where exposed; otherwise the fan takes the fourth row.
            if let gpu = tracker.gpuTemperature {
                IslandThermalRow(label: "GPU", value: gpu, scale: .soc)
            } else {
                IslandFanRow(
                    hasFans: tracker.hasFans,
                    rpm: tracker.currentFanSpeed,
                    maxRPM: Double(chargeLimit.fanMaxRPM),
                    animated: tracker.enableAnimations
                )
            }
        }
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
                Text("\(tracker.currentBatteryLevel)% • \(tracker.powerAdapterWatts.map { "\($0)W" } ?? String(localized: "Power Source"))")
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

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor  { NSEvent.removeMonitor(localMonitor) }
    }

    // The window is a fixed full-width strip across the top; the SwiftUI content
    // morphs the notch shape. Height comfortably fits the opened panel.
    private let stripHeight: CGFloat = 300
    private var openedSize: CGSize {
        Self.openedSize(shelfEnabled: tracker?.enableNotchShelf ?? false, musicShown: Self.musicShown)
    }

    /// Whether the Now Playing column should be shown (feature on + something playing).
    /// Always false on the App Store build (the feature is compiled out there).
    static var musicShown: Bool {
        #if !APPSTORE
        NowPlayingManager.shared.isEnabled && NowPlayingManager.shared.info != nil
        #else
        false
        #endif
    }

    /// Single source of truth for the expanded panel size, shared with the SwiftUI view.
    /// The App Store build drops the temperatures column (sandbox), so it's narrower.
    /// Grows for the optional Shelf and Now Playing columns when they're active.
    // Column widths are explicit and the panel is the sum of the ones actually shown.
    // Deriving the window from the columns is what keeps the two in step: a hand-tuned
    // panel width leaves dead space at the edges when a column is removed, and squeezes
    // the cells (truncating "Fanless") when it's too small.
    static let columnSpacing: CGFloat = 18
    static let panelSidePadding: CGFloat = 26
    static let powerColumnWidth: CGFloat = 176
    static let tempColumnWidth: CGFloat = 224
    static let shelfColumnWidth: CGFloat = 168
    static let musicColumnWidth: CGFloat = 190
    /// A divider plus the spacing on each side of it.
    private static var separatorSpan: CGFloat { 1 + columnSpacing * 2 }

    static func openedSize(shelfEnabled: Bool, musicShown: Bool) -> CGSize {
        var width = panelSidePadding * 2 + powerColumnWidth
        if !Distribution.isAppStore { width += separatorSpan + tempColumnWidth }
        if musicShown { width += separatorSpan + musicColumnWidth }
        if shelfEnabled { width += separatorSpan + shelfColumnWidth }
        return CGSize(width: width, height: 204)
    }
    private let hoverInset: CGFloat = -4   // expands the notch hover target a touch

    private var islandWindow: NSPanel?
    private weak var tracker: BatteryTracker?
    private(set) var isEnabled = true

    /// What the user asked for is `isEnabled`; whether the island is actually on screen also
    /// depends on `hideOnExternalDisplay` — with a monitor attached (clamshell above all, where
    /// the monitor is the only screen) the island would otherwise be drawn on that monitor.
    private var isShown: Bool {
        isEnabled && !(tracker?.hideIslandOnExternalDisplay == true && LidAndDisplay.externalDisplayAttached())
    }
    private var cancellables = Set<AnyCancellable>()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var screenObserver: Any?
    private var expandWorkItem: DispatchWorkItem?
    private var collapseWorkItem: DispatchWorkItem?
    // A trigger that arrives before buildWindow() runs (the ~0.5s deferred setup window
    // after launch) would otherwise start its auto-dismiss timer against a state nothing
    // is rendering yet, and silently expire before the panel ever exists. Replay it once
    // the window is actually built instead.
    private var pendingTrigger: DynamicIslandState?

    // Hit-test rects in screen coordinates.
    private var deviceNotchRect: CGRect = .zero
    private var openedRect: CGRect = .zero

    /// The region that keeps the panel expanded. Inset outward so the boundary is
    /// forgiving — crucially it extends ABOVE the screen's top edge, because
    /// `CGRect.contains` excludes the max-Y edge and the notch sits exactly there.
    /// Without this, hovering the very top pixel reads as "inside expand, outside stay"
    /// and the panel oscillates open/closed (seen on 16" M4 Pro / macOS 15.7).
    private var stayExpandedRect: CGRect { openedRect.insetBy(dx: -24, dy: -24) }

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
        guard tracker?.enableDynamicIslandHaptics == true else { return }
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
        setupMouseMonitors()   // shown or kept hidden by applyVisibility() below

        // Make the panel clickable only while expanded (controls); pass clicks
        // through to the menu bar otherwise.
        DynamicIslandStateManager.shared.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.islandWindow?.ignoresMouseEvents = (state != .expanded)
            }
            .store(in: &cancellables)

        #if !APPSTORE
        // Music appearing/disappearing changes openedSize (width += 210), which shifts the
        // hover hit-test rect. Only recomputeLayout() (via positionWindow) refreshes the
        // cached openedRect — without this the rect goes stale when a song starts or stops,
        // so the expanded panel collapses out from under the cursor. Recompute on change.
        Publishers.Merge(
            NowPlayingManager.shared.$info.map { _ in () },
            NowPlayingManager.shared.$isEnabled.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.recomputeLayout() }
        .store(in: &cancellables)
        #endif

        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.positionWindow()
                self?.applyVisibility()
            }
        }

        applyVisibility()

        // Replay anything that tried to trigger before the panel existed.
        if let pending = pendingTrigger {
            pendingTrigger = nil
            if isShown { DynamicIslandStateManager.shared.trigger(pending) }
        }
    }

    private func setupMouseMonitors() {
        // .leftMouseDragged matters: during a drag session AppKit delivers dragged events,
        // NOT mouseMoved, so without it hover-expansion can never fire mid-drag and the
        // Shelf's file drop tray would be unreachable by drag-and-drop.
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged]) { [weak self] event in
                let type = event.type
                Task { @MainActor in
                    switch type {
                    case .leftMouseDown: self?.handleMouseDown()
                    case .leftMouseDragged: self?.handleMouseDragged()
                    default: self?.handleMouseMoved()
                    }
                }
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged]) { [weak self] event in
                let type = event.type
                Task { @MainActor in
                    switch type {
                    case .leftMouseDown: self?.handleMouseDown()
                    case .leftMouseDragged: self?.handleMouseDragged()
                    default: self?.handleMouseMoved()
                    }
                }
                return event
            }
        }
    }

    /// Fired while the user drags something (file, text, window). Only used to open the
    /// panel so a file can reach the Shelf's drop tray — gated on the Shelf being enabled
    /// so ordinary window-drags near the menu bar don't pop the island open.
    private func handleMouseDragged() {
        guard isShown, tracker?.enableNotchShelf == true else { return }
        let mouse = NSEvent.mouseLocation
        let state = DynamicIslandStateManager.shared.state

        if state == .compact {
            if deviceNotchRect.insetBy(dx: hoverInset, dy: hoverInset).contains(mouse) {
                openPanel()   // immediate — drags move fast, the 0.12s hover delay would miss
            }
        } else if state == .expanded {
            if stayExpandedRect.contains(mouse) {
                collapseWorkItem?.cancel()
                collapseWorkItem = nil
            } else {
                hoverDidExit()
            }
        }
    }

    private func handleMouseDown() {
        guard isShown else { return }
        let mouse = NSEvent.mouseLocation
        switch DynamicIslandStateManager.shared.state {
        case .compact:
            // Click on the notch opens the panel.
            if deviceNotchRect.insetBy(dx: hoverInset, dy: hoverInset).contains(mouse) {
                openPanel()
            }
        case .expanded:
            // Click outside the panel closes it; clicks inside fall through to the controls.
            if !stayExpandedRect.contains(mouse) {
                closePanel()
            }
        default:
            break
        }
    }

    private func handleMouseMoved() {
        guard isShown else { return }
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
            if stayExpandedRect.contains(mouse) {
                collapseWorkItem?.cancel()
                collapseWorkItem = nil
            } else {
                hoverDidExit()
            }
        }
    }

    private func positionWindow() {
        guard let screen = NSScreen.screens.first(where: { $0.miNotchSize != .zero }) ?? NSScreen.main,
              let win = islandWindow else { return }
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
        if enabled, islandWindow == nil, let t = tracker { buildWindow(for: t) }
        applyVisibility()
    }

    /// Shows or hides the panel to match `isShown`. The window is kept while merely hidden so the
    /// screen-change observer lives on and can bring the island back when the display goes.
    func applyVisibility() {
        guard let window = islandWindow else { return }
        if isShown {
            window.orderFrontRegardless()
        } else {
            DynamicIslandStateManager.shared.dismiss()
            pendingTrigger = nil
            window.orderOut(nil)
        }
    }

    /// Re-derive the hover hit-test rect after the panel's width changes at runtime
    /// (e.g. the Notch Shelf column is toggled on/off in Settings).
    func recomputeLayout() {
        positionWindow()
    }

    func trigger(_ state: DynamicIslandState) {
        guard isShown else { return }
        guard islandWindow != nil else {
            // setup()/buildWindow() hasn't run yet — queue it instead of starting an
            // auto-dismiss timer against a state nothing can render.
            pendingTrigger = state
            return
        }
        DynamicIslandStateManager.shared.trigger(state)
    }

    func dismiss() {
        pendingTrigger = nil
        DynamicIslandStateManager.shared.dismiss()
    }
}

// MARK: - Island instruments

/// Where a sensor's reading sits between "cool" and "hot", kept pure so the thresholds the
/// gauges colour by are testable. The warm/hot cut-offs are the same ones the old tile dots
/// used, so a reading keeps the colour it always had.
struct ThermalScale: Equatable {
    let lower: Double
    let upper: Double
    let warm: Double
    let hot: Double

    static let battery = ThermalScale(lower: 20, upper: 50, warm: 35, hot: 40)
    static let soc = ThermalScale(lower: 30, upper: 105, warm: 65, hot: 85)

    func fraction(_ value: Double) -> Double {
        guard upper > lower else { return 0 }
        return min(1, max(0, (value - lower) / (upper - lower)))
    }

    var warmStop: Double { fraction(warm) }
    var hotStop: Double { fraction(hot) }
}

/// A capsule whose bright part ends where the value sits. The full-width track is drawn
/// dim in the same colour zones, so the reading shows both its value and its headroom.
private struct IslandGauge: View {
    /// `nil` draws only the dim track — no reading, so no bright part either.
    let fraction: Double?
    let warmStop: Double
    let hotStop: Double
    var height: CGFloat = 4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Capsule()
            .fill(spectrum(opacity: 0.2))
            .frame(height: height)
            .overlay(alignment: .leading) {
                if let fraction {
                    Capsule()
                        .fill(spectrum(opacity: 1))
                        .mask(alignment: .leading) {
                            Rectangle()
                                .scaleEffect(x: max(fraction, 0.03), anchor: .leading)
                                .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: fraction)
                        }
                }
            }
    }

    private func spectrum(opacity: Double) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .cyan.opacity(opacity), location: 0),
                .init(color: .cyan.opacity(opacity), location: warmStop),
                .init(color: .orange.opacity(opacity), location: warmStop),
                .init(color: .orange.opacity(opacity), location: hotStop),
                .init(color: .red.opacity(opacity), location: hotStop),
                .init(color: .red.opacity(opacity), location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }
}

private struct IslandRowLabel: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(.white.opacity(0.4))
    }
}

struct IslandThermalRow: View {
    let label: LocalizedStringKey
    let value: Double?
    let scale: ThermalScale

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                IslandRowLabel(text: label)
                Spacer(minLength: 4)
                Text(value.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.system(size: 14, weight: .bold).monospacedDigit())
                    .foregroundColor(value == nil ? .white.opacity(0.3) : .white)
                if value != nil {
                    Text("°")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            IslandGauge(fraction: value.map(scale.fraction), warmStop: scale.warmStop, hotStop: scale.hotStop)
        }
        .accessibilityElement(children: .combine)
    }
}

struct IslandFanRow: View {
    let hasFans: Bool
    let rpm: Double?
    /// The helper-reported ceiling; 0 when the Mac doesn't expose one.
    let maxRPM: Double
    let animated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ceiling: Double { maxRPM > 1000 ? maxRPM : 6500 }
    private var spinning: Bool { hasFans && animated && !reduceMotion && (rpm ?? 0) > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 5) {
                IslandRowLabel(text: "FAN")
                Spacer(minLength: 4)
                bladeIcon
                Text(valueText)
                    .font(.system(size: 14, weight: .bold).monospacedDigit())
                    .foregroundColor(hasFans ? .white : .white.opacity(0.5))
            }
            IslandGauge(
                fraction: hasFans ? min(1, (rpm ?? 0) / ceiling) : nil,
                warmStop: 1, hotStop: 1
            )
        }
        .accessibilityElement(children: .combine)
    }

    private var valueText: String {
        guard hasFans else { return String(localized: "Fanless") }
        return rpm.map { String(format: "%.0f", $0) } ?? "—"
    }

    private var bladeIcon: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !spinning)) { context in
            // Visual speed only follows the fan's — real rpm would be an unreadable blur.
            let degreesPerSecond = min(540, max(60, (rpm ?? 0) / 8))
            let angle = context.date.timeIntervalSinceReferenceDate * degreesPerSecond
            Image(systemName: hasFans ? "fanblades.fill" : "fanblades")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(hasFans ? 0.6 : 0.35))
                .rotationEffect(.degrees(spinning ? angle.truncatingRemainder(dividingBy: 360) : 0))
        }
    }
}

/// Charge ring that also draws what MacWake is doing: a tick at the configured limit and,
/// under Sailing Mode, the inner band the level is allowed to drift through.
struct IslandChargeRing: View {
    let level: Int
    let tint: Color
    let plugged: Bool
    let limit: Int?
    let sailingLower: Int?
    let animated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let size: CGFloat = 60
    private let stroke: CGFloat = 7

    private var fraction: Double { Double(min(100, max(0, level))) / 100 }

    var body: some View {
        ZStack {
            Circle()
                .inset(by: stroke / 2)
                .stroke(Color.white.opacity(0.1), lineWidth: stroke)

            Circle()
                .inset(by: stroke / 2)
                .trim(from: 0, to: fraction)
                .stroke(
                    AngularGradient(
                        colors: [tint.opacity(0.45), tint],
                        center: .center, startAngle: .degrees(0), endAngle: .degrees(max(1, 360 * fraction))
                    ),
                    style: StrokeStyle(lineWidth: stroke, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: level)

            if let sailingLower, let limit, limit > sailingLower {
                Circle()
                    .inset(by: stroke + 4)
                    .trim(from: Double(sailingLower) / 100, to: Double(limit) / 100)
                    .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }

            if let limit {
                Color.clear
                    .overlay {
                        Capsule()
                            .fill(Color.white)
                            .frame(width: 2.5, height: stroke + 5)
                            .offset(y: -(size / 2 - stroke / 2))
                    }
                    .rotationEffect(.degrees(Double(limit) * 3.6))
            }

            Image(systemName: plugged ? "bolt.fill" : batterySymbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(tint)
                .symbolEffect(.pulse, options: .repeating, isActive: plugged && animated && !reduceMotion)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("BATTERY"))
        .accessibilityValue(Text("\(level)%"))
    }

    private var batterySymbol: String {
        switch level {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default:    return "battery.100"
        }
    }
}

/// Capacity and cycle count as one compact meter. The figure it shows is the damped headline
/// (see `BatteryHealthMath.headline`) — it must not move with the controller's recalculation.
struct IslandHealthMeter: View {
    let health: Int
    let cycles: Int

    private var tint: Color { health >= 80 ? .green : (health >= 60 ? .orange : .red) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                IslandRowLabel(text: "Health")
                Spacer(minLength: 4)
                Text("\(health)%")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundColor(.white)
            }
            Capsule()
                .fill(Color.white.opacity(0.1))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint)
                        .mask(alignment: .leading) {
                            Rectangle().scaleEffect(x: max(0.03, Double(min(100, max(0, health))) / 100), anchor: .leading)
                        }
                }
            HStack(alignment: .firstTextBaseline) {
                IslandRowLabel(text: "Cycles")
                Spacer(minLength: 4)
                Text("\(cycles)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
