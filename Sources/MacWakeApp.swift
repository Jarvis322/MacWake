import SwiftUI
import AppKit
import UserNotifications
import Sparkle
import TelemetryDeck

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, SPUStandardUserDriverDelegate {
    /// SwiftUI's `@NSApplicationDelegateAdaptor` installs its own `SwiftUI.AppDelegate`
    /// as `NSApp.delegate` and forwards lifecycle to ours, so `NSApp.delegate as? AppDelegate`
    /// is nil. Expose our instance directly for the menu's "Check for Updates" action.
    static private(set) weak var shared: AppDelegate?

    lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: self
    )

    /// True while we've temporarily promoted to a regular (Dock) app so Sparkle's
    /// update dialogs come to the front. Menu-bar (LSUIElement/accessory) apps don't
    /// show modal alerts otherwise — the "You're up to date" panel never appears.
    private var didElevateForUpdate = false

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        _ = updaterController   // force-start the updater at launch

        let config = TelemetryDeck.Config(appID: "47BC5AD6-3456-4A13-97F3-10C169BFDAD6")
        TelemetryDeck.initialize(config: config)
        TelemetryDeck.signal("app.launched")
    }

    /// Called from the menu's "Check for Updates" button.
    @objc func checkForUpdates() {
        elevateForUpdateUI()
        updaterController.checkForUpdates(nil)
    }

    private func elevateForUpdateUI() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            didElevateForUpdate = true
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // SPUStandardUserDriverDelegate — bring the app forward before any Sparkle alert.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillShowModalAlert() {
        elevateForUpdateUI()
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Once the user dismisses the update dialog and clicks away, drop back to a
        // pure menu-bar app (no Dock icon).
        if didElevateForUpdate {
            didElevateForUpdate = false
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave the adapter disabled (CHIE=8) after we quit, or the Mac would
        // keep discharging on AC until reboot. Best-effort synchronous restore.
        ChargeLimitManager.shared.restoreChargingOnQuit()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@main
struct MacWakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Instantiate the battery tracker as a StateObject to manage its lifecycle
    @StateObject private var tracker = BatteryTracker()
    
    init() {
        // Prevent duplicate instances of the application from running simultaneously
        let bundleId = Bundle.main.bundleIdentifier ?? "com.macwake"
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        if runningApps.count > 1 {
            print("Another instance of MacWake is already running. Exiting.")
            exit(0)
        }
    }
    
    var body: some Scene {
        MenuBarExtra {
            MacWakeMenuView(tracker: tracker)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: tracker.effectiveMenuBarIcon)
                if !tracker.menuBarText.isEmpty {
                    Text(tracker.menuBarText)
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
