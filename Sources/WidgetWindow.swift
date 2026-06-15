import SwiftUI
import AppKit
import Combine

struct Theme {
    static let darkGreen = Color(red: 0.05, green: 0.50, blue: 0.22)
    static let midGreen = Color(red: 0.15, green: 0.65, blue: 0.40)
    static let darkBlue = Color(red: 0.00, green: 0.38, blue: 0.75)
    static let midBlue = Color(red: 0.15, green: 0.58, blue: 0.88)
}

struct CircularBatteryGauge: View {
    @ObservedObject var tracker: BatteryTracker
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 8)
            
            Circle()
                .trim(from: 0.0, to: CGFloat(tracker.currentBatteryLevel) / 100.0)
                .stroke(
                    LinearGradient(
                        colors: tracker.isPluggedIn ? [Theme.darkBlue, Theme.midBlue] : [Theme.darkGreen, Theme.midGreen],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: tracker.currentBatteryLevel)
            
            VStack(spacing: 1) {
                Text("\(tracker.currentBatteryLevel)%")
                    .font(.system(.title3, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                if tracker.isPluggedIn {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.darkBlue)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
    }
}

struct WidgetView: View {
    @ObservedObject var tracker: BatteryTracker
    @State private var isHoveringClose = false
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 16) {
                CircularBatteryGauge(tracker: tracker)
                    .frame(width: 64, height: 64)
                
                VStack(alignment: .leading, spacing: 4) {
                    if tracker.isPluggedIn {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("CHARGING")
                                .font(.system(.caption2, design: .rounded))
                                .fontWeight(.bold)
                                .foregroundColor(.secondary)
                            
                            if let dyn = tracker.dynamicWatts {
                                Text(String(format: "%.1f W", dyn))
                                    .font(.system(.title3, design: .rounded))
                                    .fontWeight(.bold)
                                    .foregroundColor(Theme.darkBlue)
                            } else if let nominal = tracker.powerAdapterWatts {
                                Text("\(nominal) W")
                                    .font(.system(.title3, design: .rounded))
                                    .fontWeight(.bold)
                                    .foregroundColor(Theme.darkBlue)
                            } else {
                                Text("Plugged")
                                    .font(.system(.title3, design: .rounded))
                                    .fontWeight(.bold)
                                    .foregroundColor(Theme.darkBlue)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("ON BATTERY")
                                .font(.system(.caption2, design: .rounded))
                                .fontWeight(.bold)
                                .foregroundColor(.secondary)
                            
                            Text(tracker.menuBarText.isEmpty ? "Active" : tracker.menuBarText)
                                .font(.system(.title3, design: .rounded))
                                .fontWeight(.bold)
                                .foregroundColor(Theme.darkGreen)
                        }
                    }
                    
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("TEMP")
                                .font(.system(.caption2, design: .rounded))
                                .foregroundColor(.secondary)
                            Text(String(format: "%.1f°C", tracker.batteryTemperature))
                                .font(.system(.footnote, design: .rounded))
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                        }
                        
                        VStack(alignment: .leading, spacing: 1) {
                            Text("CYCLES")
                                .font(.system(.caption2, design: .rounded))
                                .foregroundColor(.secondary)
                            Text("\(tracker.batteryCycles)")
                                .font(.system(.footnote, design: .rounded))
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                        }

                        if tracker.hasFans {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("FAN")
                                    .font(.system(.caption2, design: .rounded))
                                    .foregroundColor(.secondary)
                                Text(tracker.currentFanSpeed.map { String(format: "%.0f RPM", $0) } ?? "0")
                                    .font(.system(.footnote, design: .rounded))
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            if !tracker.isWidgetLocked {
                Button(action: {
                    tracker.showWidget = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(isHoveringClose ? .primary : .secondary)
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .padding(6)
                .onHover { hovering in
                    isHoveringClose = hovering
                }
                .transition(.opacity)
            }
        }
        .frame(width: 240, height: 96)
        .preferredColorScheme(.light)
    }
}

@MainActor
class WidgetManager: ObservableObject {
    static let shared = WidgetManager()
    
    private var window: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    
    func setup(with tracker: BatteryTracker) {
        // Observe showWidget to handle opening and closing the window
        tracker.$showWidget
            .receive(on: RunLoop.main)
            .sink { [weak self] show in
                self?.updateWindowVisibility(show: show, tracker: tracker)
            }
            .store(in: &cancellables)
            
        // Observe isWidgetLocked to handle mouse events and window levels
        tracker.$isWidgetLocked
            .receive(on: RunLoop.main)
            .sink { [weak self] locked in
                self?.updateWindowLockState(locked: locked)
            }
            .store(in: &cancellables)
    }
    
    private func updateWindowVisibility(show: Bool, tracker: BatteryTracker) {
        if show {
            if window == nil {
                createWindow(tracker: tracker)
            }
            window?.orderFront(nil)
            window?.invalidateShadow()
        } else {
            window?.orderOut(nil)
        }
    }
    
    private func updateWindowLockState(locked: Bool) {
        guard let window = window else { return }
        if locked {
            window.ignoresMouseEvents = true
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelKey.desktopWindow.rawValue))
        } else {
            window.ignoresMouseEvents = false
            window.level = .floating
        }
        window.invalidateShadow()
    }
    
    private func createWindow(tracker: BatteryTracker) {
        let contentView = NSHostingView(rootView: WidgetView(tracker: tracker))
        
        let win = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 240, height: 96),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        win.isReleasedWhenClosed = false
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = true
        win.isMovableByWindowBackground = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        // Add rounded visual effect view as backdrop
        let effectView = NSVisualEffectView()
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.appearance = NSAppearance(named: .vibrantLight)
        
        // Setup mask for smooth rounded corners (avoids black square corners in shadow calculation)
        let cornerRadius: CGFloat = 16
        let mask = maskImage(cornerRadius: cornerRadius)
        mask.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        mask.resizingMode = .stretch
        effectView.maskImage = mask
        
        // Configure frame autosave before showing
        win.setFrameAutosaveName("MacWakeWidgetWindow")
        
        // Set layout constraints
        win.contentView = effectView
        effectView.addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: effectView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor)
        ])
        
        self.window = win
        
        // Initialize the lock state
        updateWindowLockState(locked: tracker.isWidgetLocked)
        
        // Invalidate shadow to recalculate using the alpha mask shape
        win.invalidateShadow()
    }
    
    // Helper to generate a sliceable rounded-rect mask image
    private func maskImage(cornerRadius: CGFloat) -> NSImage {
        let edgeLength = 2.0 * cornerRadius + 1.0
        return NSImage(size: NSSize(width: edgeLength, height: edgeLength), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            NSColor.black.set()
            path.fill()
            return true
        }
    }
}
