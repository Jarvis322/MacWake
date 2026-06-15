import SwiftUI
import AppKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
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
