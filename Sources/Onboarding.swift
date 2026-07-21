import SwiftUI
import AppKit

// MARK: - Window manager

/// Shows an interactive first-run feature tour in its own window. Menu-bar (accessory)
/// apps don't get a normal window, so we briefly promote to a regular app to present it.
@MainActor
final class OnboardingManager: NSObject, NSWindowDelegate {
    static let shared = OnboardingManager()
    private var window: NSWindow?
    private let key = "didCompleteOnboarding"

    func showIfNeeded() {
        if !UserDefaults.standard.bool(forKey: key) { show() }
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        RegularModeCoordinator.shared.acquire("onboarding")

        let host = NSHostingController(rootView: OnboardingView { [weak self] in self?.finish() })
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = .windowBackgroundColor
        w.delegate = self
        w.setContentSize(NSSize(width: 620, height: 600))
        w.center()
        w.level = .floating
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: key)
        window?.delegate = nil
        window?.close()
        window = nil
        RegularModeCoordinator.shared.release("onboarding")
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: key)
        window = nil
        RegularModeCoordinator.shared.release("onboarding")
    }
}

// MARK: - Tour

struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page = 0
    /// Logical page ids in presentation order. The App Store build skips the pages that
    /// tout helper-backed features (charge limit, sailing/calibration, power tools).
    private var pageOrder: [Int] {
        Distribution.isAppStore ? [0, 3, 4, 7, 6] : [0, 1, 2, 3, 4, 5, 7, 6]
    }
    private var total: Int { pageOrder.count }

    // Interactive demo state
    @State private var demoLimit: Double = 80
    @State private var energySel = 0
    @State private var fanRPM: Double = 2800
    @State private var mbIcon = true
    @State private var mbPercent = true
    @State private var mbPower = true
    @State private var mbTime = false
    @State private var mbTemp = false

    private var accent: Color {
        [.green, .green, .teal, .cyan, .blue, .indigo, .orange, .pink][pageOrder[page]]
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch pageOrder[page] {
                case 0: welcomePage
                case 1: chargeLimitPage
                case 2: sailingCalibrationPage
                case 3: dynamicIslandPage
                case 4: menuBarPage
                case 5: powerToolsPage
                case 7: widgetsShortcutsPage
                default: setupPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 44)

            HStack(spacing: 7) {
                ForEach(0..<total, id: \.self) { i in
                    Capsule()
                        .fill(i == page ? accent : Color.secondary.opacity(0.25))
                        .frame(width: i == page ? 18 : 7, height: 7)
                        .animation(.spring(response: 0.3), value: page)
                }
            }
            .padding(.bottom, 16)

            HStack {
                if page > 0 {
                    Button("Back") { withAnimation(.easeInOut) { page -= 1 } }
                        .buttonStyle(.bordered)
                } else {
                    Button("Skip") { onFinish() }
                        .buttonStyle(.borderless)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(page == total - 1 ? "Get Started" : "Next") {
                    if page == total - 1 { onFinish() } else { withAnimation(.easeInOut) { page += 1 } }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(accent)
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 28)
        }
        .frame(width: 620, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Header helper

    @ViewBuilder
    private func header(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        ZStack {
            Circle().fill(accent.opacity(0.12)).frame(width: 84, height: 84)
            Image(systemName: icon).font(.system(size: 36, weight: .semibold)).foregroundColor(accent)
        }
        Text(LocalizedStringKey(title)).font(.system(size: 25, weight: .bold)).multilineTextAlignment(.center)
        Text(LocalizedStringKey(subtitle))
            .font(.system(size: 14)).foregroundColor(.secondary)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 460)
    }

    // MARK: Pages

    private var welcomePage: some View {
        VStack(spacing: 16) {
            TimelineView(.animation) { tl in
                let p = (sin(tl.date.timeIntervalSinceReferenceDate * 1.4) + 1) / 2
                ZStack {
                    Circle().fill(Color.green.opacity(0.14 + 0.12 * p)).frame(width: 138, height: 138).blur(radius: 10)
                    // The app's own icon (the Power Core), so the welcome mirrors the Dock/Finder icon.
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().interpolation(.high)
                        .frame(width: 108, height: 108)
                        .scaleEffect(0.97 + 0.05 * p)
                        .shadow(color: .green.opacity(0.25 + 0.2 * p), radius: 22)
                }
            }
            .frame(height: 150)
            Text("Welcome to MacWake").font(.system(size: 28, weight: .bold))
            Text("Your Mac's battery, finally visible. Let's take a quick interactive tour — try the controls as you go.")
                .font(.system(size: 14)).foregroundColor(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
            Spacer()
        }
    }

    private var chargeLimitPage: some View {
        VStack(spacing: 18) {
            header("battery.100.bolt", "Charge Limit", "Stop charging at the level you choose to slow battery wear. Drag it:")

            DemoBattery(fill: Int(demoLimit), accent: .green)
                .frame(height: 92)
                .padding(.top, 8)

            HStack {
                Text("Stop at").font(.caption).foregroundColor(.secondary)
                Slider(value: $demoLimit, in: 50...95, step: 5).tint(.green)
                Text("\(Int(demoLimit))%").font(.headline.monospacedDigit()).foregroundColor(.green).frame(width: 46)
            }
            .frame(maxWidth: 420)

            Text(String(format: String(localized: "ONB_LIMIT_FMT"), Int(demoLimit)))
                .font(.system(size: 12)).foregroundColor(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
    }

    private var sailingCalibrationPage: some View {
        VStack(spacing: 18) {
            header("sailboat.fill", "Sailing & Calibration", "Smarter than holding a hard ceiling.")
            SailingDemo().frame(height: 96).frame(maxWidth: 440).padding(.top, 4)
            VStack(spacing: 12) {
                tourRow("sailboat.fill", "Sailing Mode", "Let it drift in a band instead of micro-charging — fewer cycles, less heat.")
                tourRow("gauge.with.needle", "Deep Calibration", "Discharge → full charge → hold 1 hour, to recalibrate the gauge.")
            }
            .frame(maxWidth: 440).padding(.top, 4)
            Spacer()
        }
    }

    private var dynamicIslandPage: some View {
        VStack(spacing: 16) {
            header("oval.portrait.tophalf.filled", "Dynamic Island", "On notch Macs, hover the notch — you'll see this live JARVIS arc reactor.")
            ZStack {
                RoundedRectangle(cornerRadius: 22).fill(Color.black).frame(width: 360, height: 150)
                ArcReactorView(level: 82, isCharging: true, temperature: 34, watts: 60)
            }
            .padding(.top, 6)
            Text("The core pulses faster the more power flows in. Color shifts on low battery or heat.")
                .font(.system(size: 12)).foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)

            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down").foregroundColor(.secondary)
                Text("Turn on the Shelf in Settings for a last-copied-text peek and a file drop tray.")
                    .foregroundColor(.secondary)
            }
            .font(.system(size: 12))
            .padding(.top, 4)
            #if !APPSTORE
            HStack(spacing: 6) {
                Image(systemName: "music.note").foregroundColor(.secondary)
                Text("Now Playing shows your Spotify or Apple Music track in the notch, with controls.")
                    .foregroundColor(.secondary)
            }
            .font(.system(size: 12))
            #endif
            Spacer()
        }
    }

    private var menuBarPage: some View {
        VStack(spacing: 16) {
            header("menubar.rectangle", "Custom Menu Bar", "Show exactly what you want. Toggle these — the preview updates:")

            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").font(.system(size: 12)).opacity(mbIcon ? 1 : 0.001)
                Text(menuBarPreview).font(.system(size: 13, weight: .medium).monospacedDigit())
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
            .padding(.top, 4)

            VStack(spacing: 8) {
                Toggle("Icon", isOn: $mbIcon)
                Toggle("Battery %", isOn: $mbPercent)
                Toggle("Power", isOn: $mbPower)
                Toggle("Time Remaining", isOn: $mbTime)
                Toggle("Temperature", isOn: $mbTemp)
            }
            .toggleStyle(.switch).tint(.blue)
            .frame(maxWidth: 300).padding(.top, 4)
            Spacer()
        }
    }

    private var powerToolsPage: some View {
        VStack(spacing: 14) {
            header("slider.horizontal.3", "Power tools", "For when you need more control.")

            // Energy Mode
            Picker("", selection: $energySel) {
                Text("Automatic").tag(0); Text("Low Power").tag(1); Text("High Power").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
            Text("Energy Mode — set how hard your Mac runs.").font(.caption).foregroundColor(.secondary)

            // Manual fan speed (interactive)
            HStack(spacing: 14) {
                TimelineView(.animation) { tl in
                    Image(systemName: "fanblades.fill")
                        .font(.system(size: 34))
                        .foregroundColor(.cyan)
                        .rotationEffect(.degrees(tl.date.timeIntervalSinceReferenceDate * fanRPM * 0.12))
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Manual Fan Speed").font(.system(size: 13, weight: .semibold))
                        Text("BETA").font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2)).foregroundColor(.orange).cornerRadius(3)
                        Spacer()
                        Text("\(Int(fanRPM)) RPM").font(.caption.bold().monospacedDigit()).foregroundColor(.cyan)
                    }
                    Slider(value: $fanRPM, in: 0...6000, step: 100).tint(.cyan)
                    Text("Lives in the Monitor tab, next to Top Apps by CPU/RAM.").font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: 380)
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill").foregroundColor(.secondary)
                    Text("Plus a macwake command line tool — install it in Settings.")
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.slash.fill").foregroundColor(.secondary)
                    Text("Cleaning Mode locks the keyboard/trackpad while you wipe the screen.")
                        .foregroundColor(.secondary)
                }
            }
            .font(.system(size: 12))
            .frame(maxWidth: 400, alignment: .leading)
            .padding(.top, 6)
            Spacer()
        }
    }

    private var widgetsShortcutsPage: some View {
        VStack(spacing: 14) {
            header("square.grid.2x2.fill", "Widgets & Shortcuts", "Battery info everywhere you look.")
            VStack(spacing: 12) {
                tourRow("rectangle.on.rectangle", "Desktop Widget", "A translucent battery gauge you can drag anywhere on the desktop and lock in place.")
                tourRow("square.grid.2x2", "Notification Center", "Small and medium widgets with level, health and cycle count at a glance.")
                tourRow("bolt.badge.clock", "Shortcuts", "A Get Battery Status action, ready to drop into your own automations.")
                tourRow("bell.badge", "Smart Alerts", "A custom low-battery warning, a high-temperature guard, and a plugged-in-all-day reminder.")
            }
            .frame(maxWidth: 470).padding(.top, 6)
            Spacer()
        }
    }

    private var setupPage: some View {
        VStack(spacing: 16) {
            #if APPSTORE
            header("lock.shield.fill", "Private by design", "No account, no cloud, no tracking — ever.")
            VStack(spacing: 12) {
                tourRow("bolt.fill", "Everything is instant", "Monitoring, Dynamic Island, widgets and the menu bar work right away.")
                tourRow("lock.fill", "100% private", "No account, no cloud. Your data never leaves your Mac.")
            }
            .frame(maxWidth: 460).padding(.top, 6)
            #else
            header("lock.shield.fill", "One-time setup", "Charge limiting, fan, and energy control use a small background helper.")
            VStack(spacing: 12) {
                tourRow("checkmark.shield.fill", "Approve once", "The first time you turn on Charge Limiting, macOS asks you to allow it in System Settings — no passwords.")
                tourRow("bolt.fill", "Everything else is instant", "Monitoring, Dynamic Island, and menu bar work right away.")
                tourRow("lock.fill", "100% private", "No account, no cloud. Your data never leaves your Mac.")
            }
            .frame(maxWidth: 460).padding(.top, 6)
            #endif
            Spacer()
        }
    }

    // MARK: Helpers

    private func tourRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon).font(.system(size: 16)).foregroundColor(accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(title)).font(.system(size: 14, weight: .semibold))
                Text(LocalizedStringKey(detail)).font(.system(size: 12)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var menuBarPreview: String {
        var parts: [String] = []
        if mbPercent { parts.append("76%") }
        if mbPower { parts.append("12.4W") }
        if mbTime { parts.append("~3h 20m") }
        if mbTemp { parts.append("39°") }
        return parts.isEmpty ? (mbIcon ? "" : "—") : parts.joined(separator: "  ")
    }
}

// MARK: - Demo visuals

/// A horizontal battery that fills to `fill`%.
private struct DemoBattery: View {
    let fill: Int
    let accent: Color
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - 14
            let h = geo.size.height
            HStack(spacing: 3) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.4), lineWidth: 2)
                    RoundedRectangle(cornerRadius: 7)
                        .fill(accent)
                        .padding(3)
                        .frame(width: max(10, (w - 6) * CGFloat(fill) / 100))
                        .animation(.spring(response: 0.4), value: fill)
                    Text("\(fill)%")
                        .font(.system(size: h * 0.32, weight: .bold))
                        .foregroundColor(.white)
                        .shadow(radius: 2)
                        .padding(.leading, 14)
                }
                .frame(width: w)
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.4)).frame(width: 6, height: h * 0.35)
            }
        }
    }
}

/// Animated dot drifting between a lower and upper bound to illustrate Sailing Mode.
private struct SailingDemo: View {
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let p = (sin(t * 0.9) + 1) / 2          // 0…1
            let lower: CGFloat = 0.25, upper: CGFloat = 0.80
            let pos = lower + (upper - lower) * p
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15)).frame(height: 8)
                    Capsule().fill(Color.teal.opacity(0.30))
                        .frame(width: w * (upper - lower), height: 8)
                        .offset(x: w * lower)
                    Circle().fill(Color.teal).frame(width: 18, height: 18)
                        .overlay(Image(systemName: "battery.50").font(.system(size: 8)).foregroundColor(.white))
                        .offset(x: w * pos - 9)
                    Text("75%").font(.system(size: 9)).foregroundColor(.secondary).offset(x: w * lower - 6, y: 16)
                    Text("80%").font(.system(size: 9)).foregroundColor(.secondary).offset(x: w * upper - 6, y: 16)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
    }
}
