import XCTest
@testable import MacWake

final class FirmwareChargeLimitTests: XCTestCase {
    func testPlainLimitUsesTheHysteresisAsItsFloor() {
        let b = FirmwareChargeLimit.bounds(limit: 80, sailingEnabled: false, sailingLower: 70, hysteresis: 5)
        XCTAssertEqual(b.upper, 80)
        XCTAssertEqual(b.lower, 75)
    }

    func testSailingModeUsesItsOwnFloor() {
        // The reported setup: limit 55, Sailing on with a lower bound of 45.
        let b = FirmwareChargeLimit.bounds(limit: 55, sailingEnabled: true, sailingLower: 45, hysteresis: 5)
        XCTAssertEqual(b.upper, 55)
        XCTAssertEqual(b.lower, 45)
    }

    func testTheBandIsAlwaysValid() {
        // A stored floor at or above the limit must not produce an empty or inverted band.
        let high = FirmwareChargeLimit.bounds(limit: 60, sailingEnabled: true, sailingLower: 90, hysteresis: 5)
        XCTAssertEqual(high.upper, 60)
        XCTAssertEqual(high.lower, 59)
        let tiny = FirmwareChargeLimit.bounds(limit: 3, sailingEnabled: false, sailingLower: 0, hysteresis: 5)
        XCTAssertEqual(tiny.upper, 3)
        XCTAssertEqual(tiny.lower, 1)
        let over = FirmwareChargeLimit.bounds(limit: 150, sailingEnabled: false, sailingLower: 0, hysteresis: 5)
        XCTAssertEqual(over.upper, 100)
        XCTAssertLessThan(over.lower, over.upper)
    }
}
