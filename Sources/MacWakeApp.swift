import SwiftUI
import AppKit
import UserNotifications
import Sparkle
import TelemetryDeck

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self

        let config = TelemetryDeck.Config(appID: "47BC5AD6-3456-4A13-97F3-10C169BFDAD6")
        TelemetryDeck.initialize(config: config)
        TelemetryDeck.signal("app.launched")
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
