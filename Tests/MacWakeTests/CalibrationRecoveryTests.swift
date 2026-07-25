import XCTest
@testable import MacWake

final class CalibrationRecoveryTests: XCTestCase {
    func testCalibrationAtSafetyFloorRequestsImmediateRecovery() {
        XCTAssertTrue(CalibrationRecovery.shouldRestoreImmediately(
            batteryLevel: 15,
            dischargeFloor: 15,
            adapterEnabled: false
        ))
    }

    func testFailedRecoveryKeepsAdapterMarkedUnavailableForRetry() {
        XCTAssertEqual(
            CalibrationRecovery.adapterStateAfterRestore(
                previous: false,
                forceDischargeWasActive: true,
                forceDischargeCleared: false,
                chargingEnabled: true
            ),
            false
        )
    }
}
