import SwiftUI
import AppKit
import UserNotifications
#if !APPSTORE
import Sparkle
#endif
import TelemetryDeck

/// Coordinates which features need the app temporarily promoted to a regular (Dock) app
/// so AppKit will show modal windows/alerts — menu-bar (accessory) apps otherwise never
/// surface them. Multiple independent owners (Sparkle's update UI, the onboarding window)
/// can hold this at once; the app only drops back to .accessory once ALL owners have
/// released, so one owner finishing first can't yank the policy out from under another
/// owner's still-open window.
@MainActor
final class RegularModeCoordinator {
    static let shared = RegularModeCoordinator()
    private var holders = Set<String>()
    private init() {}

    func acquire(_ owner: String) {
        if holders.isEmpty {
            NSApp.setActivationPolicy(.regular)
        }
        holders.insert(owner)
    }

    func release(_ owner: String) {
        holders.remove(owner)
        if holders.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// SwiftUI's `@NSApplicationDelegateAdaptor` installs its own `SwiftUI.AppDelegate`
    /// as `NSApp.delegate` and forwards lifecycle to ours, so `NSApp.delegate as? AppDelegate`
    /// is nil. Expose our instance directly for the menu's "Check for Updates" action.
    static private(set) weak var shared: AppDelegate?

    #if !APPSTORE
    lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: self
    )
    #endif

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        #if !APPSTORE
        _ = updaterController   // force-start the updater at launch
        #endif

        let config = TelemetryDeck.Config(appID: "47BC5AD6-3456-4A13-97F3-10C169BFDAD6")
        TelemetryDeck.initialize(config: config)
        TelemetryDeck.signal("app.launched")

        // First-run feature tour.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            OnboardingManager.shared.showIfNeeded()
        }
    }

    /// Called from the menu's "Check for Updates" button. No-op on the App Store build —
    /// the row is hidden there and updates are the store's job.
    @objc func checkForUpdates() {
        #if !APPSTORE
        elevateForUpdateUI()
        updaterController.checkForUpdates(nil)
        #endif
    }

    fileprivate func elevateForUpdateUI() {
        RegularModeCoordinator.shared.acquire("sparkle")
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Once the user dismisses the update dialog and clicks away, release our hold —
        // harmless no-op if we never acquired it. The app only actually drops back to a
        // pure menu-bar app once every other holder (e.g. onboarding) has also released.
        RegularModeCoordinator.shared.release("sparkle")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave the adapter disabled (CHIE=8) after we quit, or the Mac would
        // keep discharging on AC until reboot. Best-effort synchronous restore.
        ChargeLimitManager.shared.restoreChargingOnQuit()
        // Never leave keyboard/trackpad input blocked after we quit — the countdown
        // timer already stops it on its own, but a quit mid-cleaning must not rely on
        // that timer alone.
        CleaningModeManager.shared.stop()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

#if !APPSTORE
// SPUStandardUserDriverDelegate — bring the app forward before any Sparkle alert.
// Sparkle calls these from its own internal queue, not necessarily the main thread,
// so they stay nonisolated and hop to MainActor explicitly for the actual work.
extension AppDelegate: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillShowModalAlert() {
        Task { @MainActor in
            elevateForUpdateUI()
        }
    }
}
#endif

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
                // Always keep the icon if the user turned off every text part, so the
                // menu-bar item never becomes invisible.
                if tracker.showMenuBarIcon || tracker.menuBarText.isEmpty {
                    Image(systemName: tracker.effectiveMenuBarIcon)
                }
                if !tracker.menuBarText.isEmpty {
                    Text(tracker.menuBarText)
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
