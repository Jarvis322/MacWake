import SwiftUI
import AppKit

// MARK: - Dynamic Island State
enum DynamicIslandState: Equatable {
    case capsule
    case charging
    case alert(title: String, message: String, isWarning: Bool)
    case expanded
}

// MARK: - Dynamic Island State Manager (Observable)
@MainActor
class DynamicIslandStateManager: ObservableObject {
    static let shared = DynamicIslandStateManager()
    
    @Published var state: DynamicIslandState = .capsule
    
    func trigger(_ newState: DynamicIslandState) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
            state = newState
        }
        // Auto-collapse charging state after 4 seconds
        if case .charging = newState {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                guard let self = self else { return }
                if case .charging = self.state {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                        self.state = .capsule
                    }
                }
            }
        }
    }
}

// MARK: - Dynamic Island View
struct DynamicIslandView: View {
    @ObservedObject var tracker: BatteryTracker
    @ObservedObject var stateManager = DynamicIslandStateManager.shared
    @State private var hoverState: Bool = false
    
    var body: some View {
        ZStack {
            // Glassmorphism background
            RoundedRectangle(cornerRadius: containerCornerRadius)
                .fill(Color.black.opacity(0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: containerCornerRadius)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.5), radius: 15, x: 0, y: 8)
            
            // Content
            VStack {
                switch stateManager.state {
                case .capsule:
                    capsuleContent
                case .charging:
                    chargingContent
                case .alert(let title, let message, let isWarning):
                    alertContent(title: title, message: message, isWarning: isWarning)
                case .expanded:
                    expandedContent
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: containerWidth, height: containerHeight)
        .animation(.spring(response: 0.45, dampingFraction: 0.72), value: stateManager.state)
        .contentShape(Rectangle())
        .onHover { inside in
            hoverState = inside
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                if inside {
                    stateManager.state = .expanded
                } else {
                    collapseToDefault()
                }
            }
        }
        .onTapGesture {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                if case .expanded = stateManager.state {
                    collapseToDefault()
                } else {
                    stateManager.state = .expanded
                }
            }
        }
        // React to tracker alert changes
        .onChange(of: tracker.highTempAlert) { _, _ in
            if !hoverState { collapseToDefault() }
        }
        .onChange(of: tracker.continuousACAlert) { _, _ in
            if !hoverState { collapseToDefault() }
        }
    }
    
    private func collapseToDefault() {
        if tracker.highTempAlert {
            stateManager.state = .alert(
                title: "Yüksek Pil Sıcaklığı",
                message: String(format: "Pil sıcaklığı %.1f°C seviyesine ulaştı.", tracker.batteryTemperature),
                isWarning: false
            )
        } else if tracker.continuousACAlert {
            stateManager.state = .alert(
                title: "Sürekli Prizde Kullanım",
                message: "Mac'iniz 24 saattir prizde. Pili deşarj edin.",
                isWarning: true
            )
        } else {
            stateManager.state = .capsule
        }
    }
    
    // MARK: - Dimensions
    private var containerWidth: CGFloat {
        switch stateManager.state {
        case .capsule:  return 150
        case .charging: return 280
        case .alert:    return 300
        case .expanded: return 320
        }
    }
    
    private var containerHeight: CGFloat {
        switch stateManager.state {
        case .capsule:  return 28
        case .charging: return 50
        case .alert:    return 75
        case .expanded: return 120
        }
    }
    
    private var containerCornerRadius: CGFloat {
        if case .capsule = stateManager.state { return 14 }
        return 20
    }
    
    // MARK: - State Views
    private var capsuleContent: some View {
        HStack(spacing: 8) {
            Image(systemName: tracker.isPluggedIn ? "battery.100.bolt" : "battery.75")
                .foregroundColor(tracker.isPluggedIn ? .blue : (tracker.currentBatteryLevel < 20 ? .red : .green))
                .font(.system(size: 11, weight: .bold))
            Text("\(tracker.currentBatteryLevel)%")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
    }
    
    private var chargingContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.ring.closed")
                .foregroundColor(.green)
                .font(.system(size: 24))
                .shadow(color: .green.opacity(0.5), radius: 5)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Şarj Ediliyor")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                if let watts = tracker.powerAdapterWatts {
                    Text("\(watts)W Adaptör bağlı (\(tracker.currentBatteryLevel)%)")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                } else {
                    Text("Güç kaynağı bağlandı (\(tracker.currentBatteryLevel)%)")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
            }
            Spacer()
        }
    }
    
    private func alertContent(title: String, message: String, isWarning: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "thermometer.high")
                .foregroundColor(isWarning ? .orange : .red)
                .font(.system(size: 22))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(isWarning ? .orange : .red)
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                    .lineLimit(2)
            }
            Spacer()
        }
    }
    
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MacWake Status")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.blue)
                Spacer()
                Text("\(tracker.currentBatteryLevel)%")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            
            Divider().background(Color.white.opacity(0.1))
            
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ekran Süresi")
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                    if let session = tracker.currentSession {
                        Text(formatDuration(tracker.liveSession(session).screenOnDuration))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                    } else {
                        Text("Prizde")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sıcaklık")
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                    Text(String(format: "%.1f°C", tracker.batteryTemperature))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(tracker.batteryTemperature > 38 ? .red : .orange)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fan Devri")
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                    Text(tracker.currentFanSpeed.map { String(format: "%.0f RPM", $0) } ?? "Fansız")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                }
            }
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        if hours > 0 { return "\(hours)sa \(minutes)dk" }
        return "\(minutes)dk"
    }
}

// MARK: - Dynamic Island Window Manager
@MainActor
class DynamicIslandManager {
    static let shared = DynamicIslandManager()
    
    private var window: NSPanel?
    private var isEnabled = true
    private weak var tracker: BatteryTracker?
    
    func setup(with tracker: BatteryTracker) {
        self.isEnabled = tracker.enableDynamicIsland
        self.tracker = tracker
        guard isEnabled else { return }
        createWindow(for: tracker)
    }
    
    private func createWindow(for tracker: BatteryTracker) {
        let contentView = NSHostingView(
            rootView: DynamicIslandView(tracker: tracker)
        )
        
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = contentView
        
        self.window = panel
        repositionWindow()
        panel.orderFrontRegardless()
        
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.repositionWindow() }
        }
    }
    
    func updateSettings(enabled: Bool) {
        self.isEnabled = enabled
        if enabled {
            if window == nil, let t = tracker {
                createWindow(for: t)
            } else {
                window?.orderFrontRegardless()
            }
        } else {
            window?.orderOut(nil)
            window = nil
        }
    }
    
    /// Trigger a state change in the Dynamic Island overlay
    func trigger(_ state: DynamicIslandState) {
        guard isEnabled else { return }
        DynamicIslandStateManager.shared.trigger(state)
    }
    
    private func repositionWindow() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let width: CGFloat = 320
        let height: CGFloat = 120
        let x = screenFrame.origin.x + (screenFrame.width - width) / 2
        let y = screenFrame.origin.y + screenFrame.height - height - 1
        window?.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}
