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
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { state = newState }
        guard let seconds else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.state == newState else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { self.state = .compact }
        }
    }

    func trigger(_ newState: DynamicIslandState) {
        switch newState {
        case .charging: show(newState, autoDismissAfter: 5.0)
        default: show(newState)
        }
    }
}

// MARK: - Textream / NotchNook Style UI
struct DynamicIslandPanelView: View {
    @ObservedObject var tracker: BatteryTracker
    @ObservedObject private var sm = DynamicIslandStateManager.shared
    @State private var hoverState = false
    @State private var isPressed = false

    var body: some View {
        ZStack(alignment: .top) {
            // Main Panel Background
            // When expanded, we show the full panel. When compact, it's just the notch pill.
            if sm.state == .expanded || sm.state == .charging || sm.state == .alert(title: "", message: "", isWarning: false) {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(Color.black.opacity(0.85)) // Dark material look
                    .background(
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    .frame(height: panelHeight)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .top))
                    ))
            } else {
                // Compact Pill Background
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.black)
                    .frame(width: 200, height: 32)
            }

            VStack(spacing: 0) {
                // TOP BAR (Notch level)
                topBar
                    .frame(height: 36) // Matches notch height approx
                    .padding(.top, 2)
                
                // EXPANDED CONTENT
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
            .frame(width: panelWidth)
        }
        .scaleEffect(isPressed ? 0.97 : 1.0)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: sm.state)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isPressed)
        .onHover { isHovered in
            self.hoverState = isHovered
        }
        .onTapGesture {
            if sm.state == .compact {
                sm.show(.expanded)
            } else if sm.state == .expanded {
                sm.show(.compact)
            }
        }
        .onLongPressGesture(minimumDuration: .infinity, maximumDistance: .infinity, pressing: { pressing in
            self.isPressed = pressing
        }, perform: {})
    }

    private var panelWidth: CGFloat {
        switch sm.state {
        case .compact: return 200
        default: return 580
        }
    }

    private var panelHeight: CGFloat {
        switch sm.state {
        case .compact: return 36
        case .charging, .alert: return 120
        case .expanded: return 180
        }
    }

    // MARK: - Top Bar (Nook / Tray style)
    private var topBar: some View {
        HStack {
            if sm.state == .expanded {
                // Left Tabs
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(tracker.isPluggedIn ? .blue : batteryColor)
                        Text("Power")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
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
                // Compact View inside notch
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: tracker.isPluggedIn ? "bolt.fill" : "battery.75")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(tracker.isPluggedIn ? .blue : batteryColor)
                    Text("%\(tracker.currentBatteryLevel)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                Spacer()
            }
        }
    }

    // MARK: - Expanded Content (Textream Split Layout)
    private var expandedContent: some View {
        HStack(spacing: 20) {
            // LEFT SIDE: Media/Battery Player Style
            leftWidget
                .frame(maxWidth: .infinity, alignment: .leading)
            
            // Subtle Divider
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1)
                .padding(.vertical, 10)
            
            // RIGHT SIDE: Calendar / Stats Style
            rightWidget
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Left Widget (Player style)
    private var leftWidget: some View {
        HStack(spacing: 16) {
            // Big App/Status Icon (like album art)
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [.cyan.opacity(0.2), .blue.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 80, height: 80)
                    .overlay(
                        Image(systemName: tracker.isPluggedIn ? "bolt.batteryblock.fill" : "battery.100")
                            .font(.system(size: 32))
                            .foregroundStyle(LinearGradient(colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom))
                    )
                
                // Small indicator (like Spotify icon)
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
            
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tracker.isPluggedIn ? "Şarj Ediliyor" : "Pilde Çalışıyor")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
                    Text("\(tracker.currentBatteryLevel)% Kapasite")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
                
                // Controls row (like media controls)
                HStack(spacing: 16) {
                    miniControlBtn(icon: "bolt.fill", isActive: tracker.isPluggedIn, tooltip: "Güç Kaynağı Durumu")
                    miniControlBtn(icon: "hare.fill", isActive: tracker.currentBatteryLevel > 20, tooltip: "Performans Modu")
                    miniControlBtn(icon: "leaf.fill", isActive: !tracker.isPluggedIn, tooltip: "Enerji Tasarrufu")
                }
                .padding(.top, 4)
            }
        }
    }

    private func miniControlBtn(icon: String, isActive: Bool, tooltip: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 14))
            .foregroundColor(isActive ? .white : .white.opacity(0.3))
            .help(tooltip)
    }

    // MARK: - Right Widget (Calendar / Stats style)
    private var rightWidget: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Top Row: Like Calendar Days
            HStack(spacing: 12) {
                Text("Stats")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                Spacer()
                
                HStack(spacing: 8) {
                    statDay(label: "TMP", value: String(format: "%.0f°", tracker.batteryTemperature), isHighlighted: tracker.batteryTemperature > 35)
                    statDay(label: "HLT", value: "\(tracker.batteryHealth)%", isHighlighted: false)
                    statDay(label: "CYC", value: "\(tracker.batteryCycles)", isHighlighted: false)
                }
            }
            
            // Bottom Area: Like "Nothing for today"
            VStack(alignment: .center, spacing: 6) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.3))
                
                if let w = tracker.powerAdapterWatts {
                    Text("\(w)W Adaptör Bağlı")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                } else {
                    Text("Normal Kullanım")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
        .padding(.trailing, 10)
    }

    private func statDay(label: String, value: String, isHighlighted: Bool) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(isHighlighted ? .red : .white.opacity(0.4))
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(isHighlighted ? .red : (label == "HLT" ? .blue : .white))
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
                Text("Şarj Bağlandı")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("\(tracker.currentBatteryLevel)% • \(tracker.powerAdapterWatts.map { "\($0)W" } ?? "Güç Kaynağı")")
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
                    .font(.system(size: 20, weight: .bold, design: .rounded))
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
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func setup(with tracker: BatteryTracker) {
        self.tracker = tracker
        self.isEnabled = tracker.enableDynamicIsland
        guard isEnabled else { return }
        buildWindow(for: tracker)
    }

    private func buildWindow(for tracker: BatteryTracker) {
        guard islandWindow == nil else { return }

        // We use a single window for the island, floating at high level
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
        islandWindow?.level = .popUpMenu // Very high level

        islandWindow?.contentView = NSHostingView(rootView: DynamicIslandPanelView(tracker: tracker))

        // Position it right at the notch
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

    func startMonitoring() {
        // We handle hover inside the SwiftUI view now, but global monitor helps if mouse leaves fast
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in self?.evaluateHover() }
        }
    }

    private func evaluateHover() {
        guard isEnabled, let window = islandWindow else { return }
        let mouse = NSEvent.mouseLocation
        let over = window.frame.contains(mouse)
        let state = DynamicIslandStateManager.shared.state

        if over && state == .compact {
            DynamicIslandStateManager.shared.show(.expanded)
        } else if !over && state == .expanded {
            DynamicIslandStateManager.shared.show(.compact)
        }
    }

    private func positionWindow() {
        updateWindowFrame(for: DynamicIslandStateManager.shared.state)
    }

    private func updateWindowFrame(for state: DynamicIslandState) {
        guard let screen = NSScreen.main else { return }
        let sf = screen.frame
        let notchH: CGFloat = 37.5 // Max physical notch height on 14"/16"

        let w: CGFloat
        let h: CGFloat
        switch state {
        case .compact: (w, h) = (200, 36)
        case .charging, .alert: (w, h) = (580, 120)
        case .expanded: (w, h) = (580, 180)
        }

        // Notch is at the top center of the screen
        let x = sf.minX + (sf.width - w) / 2
        // Touch the absolute top of the screen to integrate seamlessly with the physical notch
        let y = sf.maxY - h

        if let win = islandWindow {
            win.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true, animate: true)
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
