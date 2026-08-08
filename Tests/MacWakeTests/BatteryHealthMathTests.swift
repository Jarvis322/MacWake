import XCTest
@testable import MacWake

final class BatteryHealthMathTests: XCTestCase {
    // The snapshot from the report in issue #11: MaxCapacity is a normalised 100 while the
    // real capacities describe a worn battery. The two must not be conflated.
    private let nominal = 6156
    private let design = 6249
    private let liveMax = 6004

    func testSettledCapacityWinsOverLiveEstimate() {
        let ratio = BatteryHealthMath.ratio(nominal: nominal, liveMax: liveMax, design: design)
        XCTAssertEqual(ratio?.value ?? 0, 98.51, accuracy: 0.01)
        XCTAssertEqual(ratio?.isLiveEstimate, false)
    }

    func testLiveEstimateUsedOnlyWhenNothingBetterIsExposed() {
        let ratio = BatteryHealthMath.ratio(nominal: nil, liveMax: liveMax, design: design)
        XCTAssertEqual(ratio?.value ?? 0, 96.08, accuracy: 0.01)
        XCTAssertEqual(ratio?.isLiveEstimate, true)
    }

    func testNormalisedMaxCapacityIsNeverTheRatio() {
        // A ratio needs a capacity pair. With none exposed we must report nothing rather
        // than fall through to a value that would read as 100% on a worn battery.
        XCTAssertNil(BatteryHealthMath.ratio(nominal: nil, liveMax: nil, design: design))
        XCTAssertNil(BatteryHealthMath.ratio(nominal: nominal, liveMax: liveMax, design: 0))
        XCTAssertNil(BatteryHealthMath.ratio(nominal: nominal, liveMax: liveMax, design: nil))
    }

    func testSettledRatioIsNotDamped() {
        // Real wear must move the value immediately, however small the step.
        let ratio = BatteryHealthMath.Ratio(value: 98.51, isLiveEstimate: false)
        XCTAssertEqual(BatteryHealthMath.displayedHealth(current: 99, ratio: ratio), 98)
    }

    func testLiveEstimateStopsOscillating() {
        // The reported symptom: the value bounced 96↔97 minute to minute and wrote a
        // health-history entry on every flip. The guarantee is that drift settles — it may
        // move once as it finds its level, then stays put while samples wobble around it.
        let samples = [96.9, 97.05, 96.4, 97.02, 96.08, 96.95, 97.1, 96.2]
        var displayed = 96
        var changes: [Int] = []
        for value in samples {
            let next = BatteryHealthMath.displayedHealth(
                current: displayed,
                ratio: BatteryHealthMath.Ratio(value: value, isLiveEstimate: true)
            )
            if next != displayed { changes.append(next) }
            displayed = next
        }
        XCTAssertLessThanOrEqual(changes.count, 1, "drift must not keep rewriting the value")
        XCTAssertEqual(displayed, 97)
    }

    func testLiveEstimateStillFollowsRealDecay() {
        // Damping must not freeze the value: a full point of movement gets through.
        let decayed = BatteryHealthMath.Ratio(value: 95.4, isLiveEstimate: true)
        XCTAssertEqual(BatteryHealthMath.displayedHealth(current: 97, ratio: decayed), 95)
    }

    func testRatioIsClampedToOneHundred() {
        // Some Macs report a nominal capacity above the design figure on a fresh battery.
        let ratio = BatteryHealthMath.ratio(nominal: 4820, liveMax: nil, design: 4629)
        XCTAssertEqual(ratio?.value, 100)
    }
}
