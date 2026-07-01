import AppIntents
import Foundation

// Shortcuts / Siri actions. The metadata bundle these need (Metadata.appintents) is not
// produced by plain `swift build` — build.sh runs appintentsmetadataprocessor manually
// and copies the result into Contents/Resources. Intents run inside the app process
// (AppIntents launches the menu-bar app in the background if it isn't running).

struct SetChargeLimitIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Charge Limit"
    static let description = IntentDescription("Turns on charge limiting and sets the maximum battery percentage.")

    @Parameter(title: "Limit (%)", inclusiveRange: (50, 95))
    var limit: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = ChargeLimitManager.shared
        guard manager.helperStatus == .ready else {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Advanced Controls aren't set up yet — enable them once in MacWake's settings.")))
        }
        manager.limit = limit
        if !manager.isEnabled { manager.isEnabled = true }
        return .result(dialog: IntentDialog(stringLiteral: String(format: String(localized: "INTENT_LIMIT_SET_FMT"), manager.limit)))
    }
}

struct TopUpIntent: AppIntent {
    static let title: LocalizedStringResource = "Charge to 100% Once"
    static let description = IntentDescription("Overrides the charge limit for a single full charge, then re-applies it automatically.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = ChargeLimitManager.shared
        guard manager.helperStatus == .ready else {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Advanced Controls aren't set up yet — enable them once in MacWake's settings.")))
        }
        manager.topUp(true)
        return .result(dialog: IntentDialog(stringLiteral: String(localized: "Topping up to 100% — the limit resumes when full.")))
    }
}

struct StartCleaningModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Cleaning Mode"
    static let description = IntentDescription("Locks the keyboard and trackpad briefly so you can wipe the screen.")

    @Parameter(title: "Duration (seconds)", default: 30, inclusiveRange: (10, 120))
    var seconds: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = CleaningModeManager.shared
        guard manager.hasAccessibilityPermission else {
            manager.requestAccessibilityPermission()
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Cleaning Mode needs Accessibility permission — approve MacWake in System Settings, then try again.")))
        }
        manager.start(durationSeconds: seconds)
        return .result(dialog: IntentDialog(stringLiteral: String(localized: "Cleaning Mode is on. Hold Escape to unlock early.")))
    }
}

struct BatteryStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Battery Status"
    static let description = IntentDescription("Returns the battery level, power source, health, and temperature.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let tracker = BatteryTracker.sharedForIntents else {
            return .result(value: "", dialog: IntentDialog(stringLiteral: String(localized: "MacWake is still starting up — try again in a moment.")))
        }
        let source = tracker.isPluggedIn ? String(localized: "AC Power") : String(localized: "Battery")
        let status = String(
            format: String(localized: "INTENT_STATUS_FMT"),
            tracker.currentBatteryLevel, source, tracker.batteryHealth, tracker.batteryTemperature
        )
        return .result(value: status, dialog: IntentDialog(stringLiteral: status))
    }
}

struct MacWakeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TopUpIntent(),
            phrases: ["Charge to full with \(.applicationName)"],
            shortTitle: "Charge to 100% Once",
            systemImageName: "battery.100.bolt"
        )
        AppShortcut(
            intent: BatteryStatusIntent(),
            phrases: ["Get battery status with \(.applicationName)"],
            shortTitle: "Battery Status",
            systemImageName: "battery.75percent"
        )
    }
}
