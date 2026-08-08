import XCTest
@testable import MacWake

final class ChargeLimitSourceTests: XCTestCase {
    // The exact reproduced state from the report: MacWake limiting at 80%, the native
    // macOS policy inactive (so its reader defaults to 100).
    func testReportedContradictionResolvesToMacWakeOnly() {
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: true, macWakeReady: true, macWakeLimit: 80, nativeLimit: 100
        )
        XCTAssertEqual(source, .macWake(80))
    }

    func testMacWakeOffNativeOnShowsTheNativeValueLabeled() {
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: false, macWakeReady: true, macWakeLimit: 80, nativeLimit: 90
        )
        XCTAssertEqual(source, .macOSNative(90))
    }

    func testNeitherActiveShowsNoLimit() {
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: false, macWakeReady: true, macWakeLimit: 80, nativeLimit: 100
        )
        XCTAssertEqual(source, .none)
    }

    func testMacWakeWinsEvenWhenNativeIsAlsoActive() {
        // Two limits can be configured at once; MacWake's is the one actually enforced by
        // the helper, so it must not be shadowed by a lower macOS-reported figure.
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: true, macWakeReady: true, macWakeLimit: 80, nativeLimit: 60
        )
        XCTAssertEqual(source, .macWake(80))
    }

    func testMacWakeEnabledButHelperNotReadyDoesNotClaimTheLimit() {
        // Enabled-but-not-ready (e.g. approval pending) means the helper isn't actually
        // enforcing anything yet — falls through to whatever macOS itself reports.
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: true, macWakeReady: false, macWakeLimit: 80, nativeLimit: 100
        )
        XCTAssertEqual(source, .none)
    }

    func testSourceTracksChangingInputsWithoutARelaunch() {
        // The acceptance criterion is that changing the relevant limit updates the header;
        // since resolve() is pure and takes current values, calling it again is that update.
        var source = ChargeLimitSource.resolve(
            macWakeEnabled: true, macWakeReady: true, macWakeLimit: 80, nativeLimit: 100
        )
        XCTAssertEqual(source, .macWake(80))
        source = ChargeLimitSource.resolve(
            macWakeEnabled: true, macWakeReady: true, macWakeLimit: 60, nativeLimit: 100
        )
        XCTAssertEqual(source, .macWake(60))
    }
}
