import XCTest
@testable import MacWake

final class ChargeLimitSourceTests: XCTestCase {
    // The exact reproduced state from the report: MacWake limiting at 80%, the native
    // macOS policy inactive (so its reader defaults to 100).
    func testReportedContradictionResolvesToMacWakeOnly() {
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: true, macWakeReady: true, macWakeLimit: 80, nativeLimit: 100,
            yieldedPercent: nil, isAuthorized: true
        )
        XCTAssertEqual(source, .macWake(80))
    }

    func testMacWakeOffNativeOnShowsTheNativeValueLabeled() {
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: false, macWakeReady: true, macWakeLimit: 80, nativeLimit: 90,
            yieldedPercent: nil, isAuthorized: true
        )
        XCTAssertEqual(source, .macOSNative(90))
    }

    func testNeitherActiveShowsNoLimit() {
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: false, macWakeReady: true, macWakeLimit: 80, nativeLimit: 100,
            yieldedPercent: nil, isAuthorized: true
        )
        XCTAssertEqual(source, .none)
    }

    func testMacWakeWinsEvenWhenNativeIsAlsoActive() {
        // Two limits can be configured at once; MacWake's is the one actually enforced by
        // the helper, so it must not be shadowed by a lower macOS-reported figure.
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: true, macWakeReady: true, macWakeLimit: 80, nativeLimit: 60,
            yieldedPercent: nil, isAuthorized: true
        )
        XCTAssertEqual(source, .macWake(80))
    }

    func testMacWakeEnabledButHelperNotReadyDoesNotClaimTheLimit() {
        // Enabled-but-not-ready (e.g. approval pending) means the helper isn't actually
        // enforcing anything yet — falls through to whatever macOS itself reports.
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: true, macWakeReady: false, macWakeLimit: 80, nativeLimit: 100,
            yieldedPercent: nil, isAuthorized: true
        )
        XCTAssertEqual(source, .none)
    }

    func testSourceTracksChangingInputsWithoutARelaunch() {
        // The acceptance criterion is that changing the relevant limit updates the header;
        // since resolve() is pure and takes current values, calling it again is that update.
        var source = ChargeLimitSource.resolve(
            macWakeEnabled: true, macWakeReady: true, macWakeLimit: 80, nativeLimit: 100,
            yieldedPercent: nil, isAuthorized: true
        )
        XCTAssertEqual(source, .macWake(80))
        source = ChargeLimitSource.resolve(
            macWakeEnabled: true, macWakeReady: true, macWakeLimit: 60, nativeLimit: 100,
            yieldedPercent: nil, isAuthorized: true
        )
        XCTAssertEqual(source, .macWake(60))
    }

    // MARK: - Ownership handoff (yielded)

    func testConfirmedExternalHoldYieldsInsteadOfClaimingMacWakeIsEnforcing() {
        // The maintainer's product call for #13: MacWake at 80%, a confirmed external hold
        // at 95% — MacWake must not be described as actively holding at 80% here.
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: true, macWakeReady: true, macWakeLimit: 80, nativeLimit: 95,
            yieldedPercent: 95, isAuthorized: true
        )
        XCTAssertEqual(source, .yielded(externalPercent: 95, macWakeLimit: 80))
    }

    func testYieldedPreservesTheConfiguredMacWakeLimit() {
        // The configured limit must survive the handoff unchanged, since authorization was
        // never revoked — only enforcement moved.
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: true, macWakeReady: true, macWakeLimit: 65, nativeLimit: 90,
            yieldedPercent: 90, isAuthorized: true
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
            yieldedPercent: 90, isAuthorized: true
        )
        XCTAssertEqual(source, .macOSNative(90))
    }

    func testYieldedPercentIsIgnoredWhenHelperIsNotReady() {
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: true, macWakeReady: false, macWakeLimit: 80, nativeLimit: 90,
            yieldedPercent: 90, isAuthorized: true
        )
        XCTAssertEqual(source, .macOSNative(90))
    }

    // MARK: - Discharge authorization (#17)

    func testUnauthorizedNeverClaimsMacWakeIsEnforcing() {
        // The maintainer's requirement: MacWake must not describe the limit as enforced
        // when the user has declined the only mechanism that can enforce it.
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: true, macWakeReady: true, macWakeLimit: 80, nativeLimit: 100,
            yieldedPercent: nil, isAuthorized: false
        )
        XCTAssertEqual(source, .notAuthorized(macWakeLimit: 80))
    }

    func testUnauthorizedTakesPrecedenceOverAnExternalHold() {
        // Even if something else happens to be holding at the same moment, MacWake itself
        // has nothing to yield — it was never going to enforce without authorization.
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: true, macWakeReady: true, macWakeLimit: 80, nativeLimit: 95,
            yieldedPercent: 95, isAuthorized: false
        )
        XCTAssertEqual(source, .notAuthorized(macWakeLimit: 80))
    }

    func testUnauthorizedIsIgnoredWhenMacWakeIsNotEnabled() {
        // Authorization is meaningless with nothing enabled to authorize.
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: false, macWakeReady: true, macWakeLimit: 80, nativeLimit: 90,
            yieldedPercent: nil, isAuthorized: false
        )
        XCTAssertEqual(source, .macOSNative(90))
    }

    func testAuthorizedFallsThroughToNormalResolutionUnchanged() {
        let source = ChargeLimitSource.resolve(
            macWakeEnabled: true, macWakeReady: true, macWakeLimit: 80, nativeLimit: 100,
            yieldedPercent: nil, isAuthorized: true
        )
        XCTAssertEqual(source, .macWake(80))
    }
}
