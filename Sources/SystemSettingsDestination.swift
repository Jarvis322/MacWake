import AppKit
import Foundation

enum SystemSettingsDestination {
    /// Battery is a System Settings extension, not a stable public framework API. The URL
    /// only routes users to the Apple-owned settings surface; it never writes the native
    /// Charge Limit on their behalf.
    static let battery = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!

    static var nativeChargeLimitAvailable: Bool {
        supportsNativeChargeLimit(on: ProcessInfo.processInfo.operatingSystemVersion)
    }

    static func supportsNativeChargeLimit(on version: OperatingSystemVersion) -> Bool {
        version.majorVersion > 26 || (version.majorVersion == 26 && version.minorVersion >= 4)
    }

    static func openBattery() {
        NSWorkspace.shared.open(battery)
    }
}
