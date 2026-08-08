import XCTest
@testable import MacWake

final class ChargeHoldRulesTests: XCTestCase {
    // The reported scenario: 80% limit, default 5-point hysteresis, Heat Guard enabled, on a
    // Mac whose SMC has no charge-inhibit key so stopping charge cuts adapter input.
    private let limit = 80
    private let lowerBound = 75

    func testHeatGuardStopsAtTheLowerBound() {
        // Without a floor a hot battery kept draining until it cooled; the report reached 73%.
        XCTAssertTrue(ChargeHoldRules.heatGuardShouldRestore(batteryLevel: 75, lowerBound: lowerBound))
        XCTAssertTrue(ChargeHoldRules.heatGuardShouldRestore(batteryLevel: 73, lowerBound: lowerBound))
        XCTAssertTrue(ChargeHoldRules.heatGuardShouldRestore(batteryLevel: 20, lowerBound: lowerBound))
    }

    func testHeatGuardStillPausesAboveTheLowerBound() {
        // The feature must keep working: above the floor, charging stays paused.
        XCTAssertFalse(ChargeHoldRules.heatGuardShouldRestore(batteryLevel: 76, lowerBound: lowerBound))
        XCTAssertFalse(ChargeHoldRules.heatGuardShouldRestore(batteryLevel: 86, lowerBound: lowerBound))
    }

    func testRestoringChargeIsNeverRateLimited() {
        // A restore delayed by the anti-flapping window leaves the Mac draining on adapter
        // power for another interval, which is how the level overshot the lower bound.
        XCTAssertFalse(ChargeHoldRules.toggleIsRateLimited(
            chargingAllowed: true, sinceLastToggle: 1, minimumInterval: 90
        ))
        XCTAssertFalse(ChargeHoldRules.toggleIsRateLimited(
            chargingAllowed: true, sinceLastToggle: 0, minimumInterval: 90
        ))
    }

    func testStoppingChargeStillRespectsTheFlapGuard() {
        XCTAssertTrue(ChargeHoldRules.toggleIsRateLimited(
            chargingAllowed: false, sinceLastToggle: 30, minimumInterval: 90
        ))
        XCTAssertFalse(ChargeHoldRules.toggleIsRateLimited(
            chargingAllowed: false, sinceLastToggle: 120, minimumInterval: 90
        ))
    }

    func testFirstToggleIsNotRateLimited() {
        XCTAssertFalse(ChargeHoldRules.toggleIsRateLimited(
            chargingAllowed: false, sinceLastToggle: nil, minimumInterval: 90
        ))
    }
}
