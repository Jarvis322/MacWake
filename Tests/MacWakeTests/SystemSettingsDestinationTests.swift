import XCTest
@testable import MacWake

final class SystemSettingsDestinationTests: XCTestCase {
    func testBatteryDestinationTargetsTheBatterySettingsExtension() {
        XCTAssertEqual(
            SystemSettingsDestination.battery.absoluteString,
            "x-apple.systempreferences:com.apple.Battery-Settings.extension"
        )
    }

    func testNativeChargeLimitRequiresMacOS264OrLater() {
        XCTAssertFalse(SystemSettingsDestination.supportsNativeChargeLimit(
            on: OperatingSystemVersion(majorVersion: 26, minorVersion: 3, patchVersion: 9)
        ))
        XCTAssertTrue(SystemSettingsDestination.supportsNativeChargeLimit(
            on: OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)
        ))
        XCTAssertTrue(SystemSettingsDestination.supportsNativeChargeLimit(
            on: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        ))
    }
}
