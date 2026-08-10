import XCTest
@testable import MacWake

final class ExternalChargeHoldTests: XCTestCase {
    private func sample(percent: Int, charging: Bool = false, connected: Bool = true,
                        macWake: Bool = false) -> ExternalChargeHold.Sample {
        ExternalChargeHold.Sample(externallyConnected: connected, isCharging: charging,
                                  percent: percent, macWakeIsHolding: macWake)
    }

    func testStableHoldAcrossTheWindowIsDetected() {
        let samples = [sample(percent: 80), sample(percent: 80), sample(percent: 80)]
        XCTAssertEqual(ExternalChargeHold.detect(recentSamples: samples), 80)
    }

    func testInsufficientHistoryIsNotDetected() {
        // Only two samples with a default window of three — not enough to call it a plateau.
        let samples = [sample(percent: 80), sample(percent: 80)]
        XCTAssertNil(ExternalChargeHold.detect(recentSamples: samples))
    }

    func testMacWakesOwnHoldIsExcluded() {
        // MacWake is the one cutting the adapter here — must not read as an external hold.
        let samples = [
            sample(percent: 80, macWake: true),
            sample(percent: 80, macWake: true),
            sample(percent: 80, macWake: true),
        ]
        XCTAssertNil(ExternalChargeHold.detect(recentSamples: samples))
    }

    func testDrainingBatteryIsNotAPlateau() {
        // Plugged in but unable to charge (bad adapter, thermal fault) drifts downward
        // rather than holding — must not be mistaken for a policy.
        let samples = [sample(percent: 82), sample(percent: 81), sample(percent: 80)]
        XCTAssertNil(ExternalChargeHold.detect(recentSamples: samples))
    }

    func testActivelyChargingIsNotAHold() {
        let samples = [
            sample(percent: 80, charging: true),
            sample(percent: 80, charging: true),
            sample(percent: 80, charging: true),
        ]
        XCTAssertNil(ExternalChargeHold.detect(recentSamples: samples))
    }

    func testUnpluggedIsNotAHold() {
        let samples = [
            sample(percent: 80, connected: false),
            sample(percent: 80, connected: false),
            sample(percent: 80, connected: false),
        ]
        XCTAssertNil(ExternalChargeHold.detect(recentSamples: samples))
    }

    func testFullBatteryIsNotReportedAsAHold() {
        // 100% "not charging" is just finished, not a limit holding it down.
        let samples = [sample(percent: 100), sample(percent: 100), sample(percent: 100)]
        XCTAssertNil(ExternalChargeHold.detect(recentSamples: samples))
    }

    func testZeroPercentIsNotReportedAsAHold() {
        let samples = [sample(percent: 0), sample(percent: 0), sample(percent: 0)]
        XCTAssertNil(ExternalChargeHold.detect(recentSamples: samples))
    }

    func testOnlyTheMostRecentWindowIsConsidered() {
        // An old hold at 60% that has since moved to 80% must not linger in the verdict —
        // detect() looks at the tail of the history, not the whole thing.
        let samples = [
            sample(percent: 60), sample(percent: 60), sample(percent: 60),
            sample(percent: 80), sample(percent: 80), sample(percent: 80),
        ]
        XCTAssertEqual(ExternalChargeHold.detect(recentSamples: samples), 80)
    }

    func testASingleDisagreeingSampleBreaksTheWindow() {
        // A brief blip (one sample where charging flickered true) must reset the plateau —
        // this is what "several consecutive samples agree" means in practice.
        let samples = [sample(percent: 80), sample(percent: 80, charging: true), sample(percent: 80)]
        XCTAssertNil(ExternalChargeHold.detect(recentSamples: samples))
    }

    func testEmptyHistoryIsSafe() {
        XCTAssertNil(ExternalChargeHold.detect(recentSamples: []))
    }
}
