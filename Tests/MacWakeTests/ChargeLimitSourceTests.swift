import XCTest
@testable import MacWake

final class ChargeLimitSourceTests: XCTestCase {
    // The exact reproduced state from the report: MacWake limiting at 80%, the native
    // macOS policy inactive (so its reader defaults to 100).
    func testReportedContradictionResolvesToMacWakeOnly() {
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: true, macWakeReady: true, macWakeLimit: 80, nativeLimit: 100,
            yieldedPercent: nil
        )
        XCTAssertEqual(source, .macWake(80))
    }

    func testMacWakeOffNativeOnShowsTheNativeValueLabeled() {
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: false, macWakeReady: true, macWakeLimit: 80, nativeLimit: 90,
            yieldedPercent: nil
        )
        XCTAssertEqual(source, .macOSNative(90))
    }

    func testNeitherActiveShowsNoLimit() {
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: false, macWakeReady: true, macWakeLimit: 80, nativeLimit: 100,
            yieldedPercent: nil
        )
        XCTAssertEqual(source, .none)
    }

    func testMacWakeWinsEvenWhenNativeIsAlsoActive() {
        // Two limits can be configured at once; MacWake's is the one actually enforced by
        // the helper, so it must not be shadowed by a lower macOS-reported figure.
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: true, macWakeReady: true, macWakeLimit: 80, nativeLimit: 60,
            yieldedPercent: nil
        )
        XCTAssertEqual(source, .macWake(80))
    }

    func testMacWakeEnabledButHelperNotReadyDoesNotClaimTheLimit() {
        // Enabled-but-not-ready (e.g. approval pending) means the helper isn't actually
        // enforcing anything yet — falls through to whatever macOS itself reports.
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: true, macWakeReady: false, macWakeLimit: 80, nativeLimit: 100,
            yieldedPercent: nil
        )
        XCTAssertEqual(source, .none)
    }

    func testSourceTracksChangingInputsWithoutARelaunch() {
        // The acceptance criterion is that changing the relevant limit updates the header;
        // since resolve() is pure and takes current values, calling it again is that update.
        var source = ChargeLimitSource.resolve(
            macWakeEnabled: true, macWakeReady: true, macWakeLimit: 80, nativeLimit: 100,
            yieldedPercent: nil
        )
        XCTAssertEqual(source, .macWake(80))
        source = ChargeLimitSource.resolve(
            macWakeEnabled: true, macWakeReady: true, macWakeLimit: 60, nativeLimit: 100,
            yieldedPercent: nil
        )
        XCTAssertEqual(source, .macWake(60))
    }

    // MARK: - Ownership handoff (yielded)

    func testConfirmedExternalHoldYieldsInsteadOfClaimingMacWakeIsEnforcing() {
        // The maintainer's product call for #13: MacWake at 80%, a confirmed external hold
        // at 95% — MacWake must not be described as actively holding at 80% here.
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: true, macWakeReady: true, macWakeLimit: 80, nativeLimit: 95,
            yieldedPercent: 95
        )
        XCTAssertEqual(source, .yielded(externalPercent: 95, macWakeLimit: 80))
    }

    func testYieldedPreservesTheConfiguredMacWakeLimit() {
        // The configured limit must survive the handoff unchanged, since authorization was
        // never revoked — only enforcement moved.
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: true, macWakeReady: true, macWakeLimit: 65, nativeLimit: 90,
            yieldedPercent: 90
        )
        guard case .yielded(_, let macWakeLimit) = source else {
            return XCTFail("expected .yielded, got \(source)")
        }
        XCTAssertEqual(macWakeLimit, 65)
    }

    func testYieldedPercentIsIgnoredWhenMacWakeIsNotEnabled() {
        // Yielding is a statement about MacWake's own enforcement stepping back — with
        // nothing enabled to step back from, this must read as a plain external hold.
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: false, macWakeReady: true, macWakeLimit: 80, nativeLimit: 90,
            yieldedPercent: 90
        )
        XCTAssertEqual(source, .macOSNative(90))
    }

    func testYieldedPercentIsIgnoredWhenHelperIsNotReady() {
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: true, macWakeReady: false, macWakeLimit: 80, nativeLimit: 90,
            yieldedPercent: 90
        )
        XCTAssertEqual(source, .macOSNative(90))
    }
}
