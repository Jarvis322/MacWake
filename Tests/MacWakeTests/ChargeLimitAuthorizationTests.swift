import XCTest
@testable import MacWake

final class ChargeLimitAuthorizationTests: XCTestCase {
    func testAdapterCutHardwareRequiresAuthorization() {
        XCTAssertFalse(ChargeLimitAuthorization.standingLimitMayEnforce(
            holdCutsAdapter: true, allowActiveDischarge: false
        ))
        XCTAssertTrue(ChargeLimitAuthorization.standingLimitMayEnforce(
            holdCutsAdapter: true, allowActiveDischarge: true
        ))
    }

    func testCleanInhibitHardwareNeverNeedsAuthorization() {
        // A charge-inhibit key never discharges to hold, so there's nothing to authorize —
        // must be true regardless of the switch's own state.
        XCTAssertTrue(ChargeLimitAuthorization.standingLimitMayEnforce(
            holdCutsAdapter: false, allowActiveDischarge: false
        ))
        XCTAssertTrue(ChargeLimitAuthorization.standingLimitMayEnforce(
            holdCutsAdapter: false, allowActiveDischarge: true
        ))
    }

    func testUnconfirmedHardwareIsTreatedAsGatedUntilProvenOtherwise() {
        // Detection hasn't completed (nil) — fail toward not discharging rather than
        // assuming the safe, non-discharging mechanism exists.
        XCTAssertFalse(ChargeLimitAuthorization.standingLimitMayEnforce(
            holdCutsAdapter: nil, allowActiveDischarge: false
        ))
        XCTAssertTrue(ChargeLimitAuthorization.standingLimitMayEnforce(
            holdCutsAdapter: nil, allowActiveDischarge: true
        ))
    }
}
