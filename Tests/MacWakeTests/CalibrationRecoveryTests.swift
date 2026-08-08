import XCTest
@testable import MacWake

final class CalibrationRecoveryTests: XCTestCase {
    func testCalibrationAtSafetyFloorRequestsImmediateRecovery() {
        XCTAssertTrue(CalibrationRecovery.shouldRestoreImmediately(
            batteryLevel: 15,
            dischargeFloor: 15
        ))
    }

    func testCalibrationBelowSafetyFloorRequestsImmediateRecovery() {
        XCTAssertTrue(CalibrationRecovery.shouldRestoreImmediately(
            batteryLevel: 14,
            dischargeFloor: 15
        ))
    }

    func testCalibrationAboveSafetyFloorKeepsDischarging() {
        XCTAssertFalse(CalibrationRecovery.shouldRestoreImmediately(
            batteryLevel: 16,
            dischargeFloor: 15
        ))
    }

    func testCalibrationForcesDischargeOnlyAboveFloorWhenAdapterNeedsChanging() {
        XCTAssertFalse(CalibrationRecovery.shouldForceDischarge(
            batteryLevel: 15,
            dischargeFloor: 15,
            adapterEnabled: true
        ))
        XCTAssertTrue(CalibrationRecovery.shouldForceDischarge(
            batteryLevel: 16,
            dischargeFloor: 15,
            adapterEnabled: true
        ))
        XCTAssertFalse(CalibrationRecovery.shouldForceDischarge(
            batteryLevel: 16,
            dischargeFloor: 15,
            adapterEnabled: false
        ))
    }

    func testRecoveryRequiresBothWrites() {
        XCTAssertFalse(CalibrationRecovery.restoreSucceeded(
            forceDischargeCleared: false,
            chargingEnabled: true
        ))
        XCTAssertFalse(CalibrationRecovery.restoreSucceeded(
            forceDischargeCleared: true,
            chargingEnabled: false
        ))
        XCTAssertTrue(CalibrationRecovery.restoreSucceeded(
            forceDischargeCleared: true,
            chargingEnabled: true
        ))
    }
}
