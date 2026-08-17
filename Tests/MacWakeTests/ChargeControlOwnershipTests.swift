import XCTest
@testable import MacWake

final class ChargeControlOwnershipTests: XCTestCase {
    func testYieldsImmediatelyOnAConfirmedHold() {
        // A single confirmed hold is enough — waiting here would mean MacWake keeps
        // re-asserting its own enforcement for one more tick while something else already
        // holds the same key, which is the exact conflict this exists to avoid.
        let next = ChargeControlOwnership.next(
            current: .enforcing, externalHoldPercent: 95, consecutiveClearSamples: 0
        )
        XCTAssertEqual(next, .yielded(toPercent: 95, confirmingResume: false))
    }

    func testStaysYieldedWhileTheHoldContinues() {
        let next = ChargeControlOwnership.next(
            current: .yielded(toPercent: 95, confirmingResume: false),
            externalHoldPercent: 95, consecutiveClearSamples: 0
        )
        XCTAssertEqual(next, .yielded(toPercent: 95, confirmingResume: false))
    }

    func testYieldedPercentUpdatesIfTheHoldMoves() {
        // If the external hold itself settles at a different level, the displayed value
        // should track it rather than freeze at the first-observed percent.
        let next = ChargeControlOwnership.next(
            current: .yielded(toPercent: 95, confirmingResume: false),
            externalHoldPercent: 90, consecutiveClearSamples: 0
        )
        XCTAssertEqual(next, .yielded(toPercent: 90, confirmingResume: false))
    }

    func testASingleClearSampleEntersTheGracePeriodRatherThanResuming() {
        // The maintainer's explicit requirement: one missing or ambiguous sample must not
        // cause a silent takeover — but the live M5 report showed this needs to be visibly
        // distinct ("confirming") from a fresh, actively confirmed hold, not just internally
        // unchanged.
        let next = ChargeControlOwnership.next(
            current: .yielded(toPercent: 95, confirmingResume: false),
            externalHoldPercent: nil, consecutiveClearSamples: 1
        )
        XCTAssertEqual(next, .yielded(toPercent: 95, confirmingResume: true))
    }

    func testTheGracePeriodRetainsTheLastConfirmedPercentThroughout() {
        // This is the live bug report: the percent shown during the grace period must stay
        // the last real confirmed value (95), never fall back to a "nothing detected"
        // placeholder like 100.
        var state: ChargeControlOwnership = .yielded(toPercent: 95, confirmingResume: false)
        for clearCount in 1...2 {
            state = ChargeControlOwnership.next(
                current: state, externalHoldPercent: nil, consecutiveClearSamples: clearCount
            )
            XCTAssertEqual(state, .yielded(toPercent: 95, confirmingResume: true))
        }
    }

    func testResumesOnlyAfterTheConfiguredNumberOfClearSamples() {
        let stillYielded = ChargeControlOwnership.next(
            current: .yielded(toPercent: 95, confirmingResume: true), externalHoldPercent: nil,
            consecutiveClearSamples: 2, resumeAfterClearSamples: 3
        )
        XCTAssertEqual(stillYielded, .yielded(toPercent: 95, confirmingResume: true))

        let resumed = ChargeControlOwnership.next(
            current: .yielded(toPercent: 95, confirmingResume: true), externalHoldPercent: nil,
            consecutiveClearSamples: 3, resumeAfterClearSamples: 3
        )
        XCTAssertEqual(resumed, .enforcing)
    }

    func testAConfirmedHoldDuringTheGracePeriodCancelsTheResumeAndStopsConfirming() {
        // The hold coming back mid-grace-period must be treated as a fresh confirmation —
        // confirmingResume flips back to false, not left stuck true.
        let next = ChargeControlOwnership.next(
            current: .yielded(toPercent: 95, confirmingResume: true),
            externalHoldPercent: 95, consecutiveClearSamples: 2
        )
        XCTAssertEqual(next, .yielded(toPercent: 95, confirmingResume: false))
    }

    func testEnforcingStaysEnforcingWithNoHold() {
        let next = ChargeControlOwnership.next(
            current: .enforcing, externalHoldPercent: nil, consecutiveClearSamples: 5
        )
        XCTAssertEqual(next, .enforcing)
    }

    func testReenteringAHoldAfterResumingYieldsAgainImmediately() {
        // Symmetry check: the fast-yield / slow-resume asymmetry applies every cycle, not
        // just the first time.
        var state = ChargeControlOwnership.enforcing
        state = ChargeControlOwnership.next(current: state, externalHoldPercent: 80, consecutiveClearSamples: 0)
        XCTAssertEqual(state, .yielded(toPercent: 80, confirmingResume: false))
    }

    // MARK: - mayEnforceLimitNow (issue #19: MacWake's own cut pre-empted native-hold detection)

    func testMustNotEnforceTheInstantTheCeilingIsReached() {
        // The live bug: cutting on tick zero wins the race against ExternalChargeHold.detect,
        // which needs several samples (~90s) to ever confirm a native hold — none of which can
        // land once MacWake's own cut is already live and excludes every sample it gathers.
        XCTAssertFalse(ChargeControlOwnership.mayEnforceLimitNow(sinceLimitFirstReached: 0))
    }

    func testStillWithinTheDetectionWindowDoesNotEnforce() {
        XCTAssertFalse(ChargeControlOwnership.mayEnforceLimitNow(sinceLimitFirstReached: 90, graceInterval: 100))
    }

    func testEnforcesOnceTheGraceWindowSafelyClearsDetection() {
        // Comfortably past the detector's own ~90s window, so a Mac with no native hold
        // configured still gets real protection rather than waiting forever.
        XCTAssertTrue(ChargeControlOwnership.mayEnforceLimitNow(sinceLimitFirstReached: 100, graceInterval: 100))
    }
}
