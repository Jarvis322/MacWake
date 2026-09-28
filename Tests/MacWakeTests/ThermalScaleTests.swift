import XCTest
@testable import MacWake

final class ThermalScaleTests: XCTestCase {
    func testFractionIsClampedToTheGauge() {
        XCTAssertEqual(ThermalScale.battery.fraction(5), 0)
        XCTAssertEqual(ThermalScale.battery.fraction(80), 1)
        XCTAssertEqual(ThermalScale.battery.fraction(35), 0.5, accuracy: 0.0001)
    }

    func testZoneStopsSitAtTheThresholdsTheOldTilesUsed() {
        // Battery dot went amber above 35 and red above 40; SoC above 65 and 85.
        XCTAssertEqual(ThermalScale.battery.warmStop, ThermalScale.battery.fraction(35), accuracy: 0.0001)
        XCTAssertEqual(ThermalScale.battery.hotStop, ThermalScale.battery.fraction(40), accuracy: 0.0001)
        XCTAssertEqual(ThermalScale.soc.warmStop, ThermalScale.soc.fraction(65), accuracy: 0.0001)
        XCTAssertEqual(ThermalScale.soc.hotStop, ThermalScale.soc.fraction(85), accuracy: 0.0001)
    }

    func testDegenerateRangeDoesNotDivideByZero() {
        XCTAssertEqual(ThermalScale(lower: 10, upper: 10, warm: 10, hot: 10).fraction(10), 0)
    }
}
