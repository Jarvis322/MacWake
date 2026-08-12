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

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    func testFirstReadingIsAdoptedImmediately() {
        // Never set before, so it must not sit on the 100% default waiting out a day.
        XCTAssertEqual(
            BatteryHealthMath.headline(samples: [95.97], current: 100, lastMoved: nil, now: epoch),
            95
        )
    }

    func testStateDependentRecalculationDoesNotMoveTheHeadline() {
        // The v1.52 follow-up: NominalChargeCapacity swung between 5997 and 6156 on a
        // 6249 mAh design capacity — 95.97% ↔ 98.51% — with the cycle count fixed at 63,
        // and each swing persisted a history row that looked like wear and then recovered.
        var displayed = 95
        var lastMoved: Date? = epoch
        var samples: [Double] = []
        var moves = 0
        for step in 0..<40 {
            samples.append(step.isMultiple(of: 2) ? 95.97 : 98.51)
            let now = epoch.addingTimeInterval(Double(step) * 30)
            let next = BatteryHealthMath.headline(
                samples: samples, current: displayed, lastMoved: lastMoved, now: now
            )
            if next != displayed { moves += 1; displayed = next; lastMoved = now }
        }
        XCTAssertEqual(moves, 0, "an alternating estimate must not be recorded as wear")
        XCTAssertEqual(displayed, 95)
    }

    func testHeadlineMovesAtMostOncePerDay() {
        // Even a sustained shift may only be written once a day, which is what bounds the
        // history to one row per day.
        let samples = Array(repeating: 91.2, count: 10)
        let tenMinutes = epoch.addingTimeInterval(600)
        XCTAssertEqual(
            BatteryHealthMath.headline(samples: samples, current: 95, lastMoved: epoch, now: tenMinutes),
            95
        )
        let nextDay = epoch.addingTimeInterval(24 * 3600 + 60)
        XCTAssertEqual(
            BatteryHealthMath.headline(samples: samples, current: 95, lastMoved: epoch, now: nextDay),
            91
        )
    }

    func testHeadlineStillFollowsRealDecay() {
        // Damping must not freeze the value: a sustained drop a day later gets through.
        let samples = Array(repeating: 93.4, count: 20)
        let later = epoch.addingTimeInterval(48 * 3600)
        XCTAssertEqual(
            BatteryHealthMath.headline(samples: samples, current: 95, lastMoved: epoch, now: later),
            93
        )
    }

    func testSubPointDriftIsIgnoredEvenAfterDays() {
        // 95.97 rounds to 95 already; a drift to 95.2 is not a point of movement.
        let samples = Array(repeating: 95.2, count: 20)
        let later = epoch.addingTimeInterval(72 * 3600)
        XCTAssertEqual(
            BatteryHealthMath.headline(samples: samples, current: 95, lastMoved: epoch, now: later),
            95
        )
    }

    func testMedianIgnoresIsolatedOutliers() {
        // One bad sample among many must not decide the figure.
        let samples = [95.9, 96.0, 95.8, 60.0, 96.1, 95.95, 96.05]
        XCTAssertEqual(BatteryHealthMath.median(samples) ?? 0, 95.95, accuracy: 0.01)
    }

    func testEmptySampleSetKeepsCurrentValue() {
        XCTAssertEqual(
            BatteryHealthMath.headline(samples: [], current: 95, lastMoved: nil, now: epoch),
            95
        )
    }

    func testRatioIsClampedToOneHundred() {
        // Some Macs report a nominal capacity above the design figure on a fresh battery.
        let ratio = BatteryHealthMath.ratio(nominal: 4820, liveMax: nil, design: 4629)
        XCTAssertEqual(ratio?.value, 100)
    }

    func testFallsBackToRawMaxCapacityOnlyBeforeAnyRealSample() {
        // A Mac that has never once produced a real ratio (old Intel, no capacity pair
        // exposed) may trust the normalised MaxCapacity as its only option.
        XCTAssertTrue(BatteryHealthMath.shouldFallBackToRawMaxCapacity(hasEverHadRatioSample: false))
    }

    func testDoesNotFallBackAfterARealSampleEverExisted() {
        // A transient nil once a real ratio has already been computed (e.g. BatteryData
        // briefly missing mid-recalculation) must not overwrite a correct, damped health
        // figure with the pinned-100 value — a bug that made a single bad IORegistry read
        // stick for up to 24 hours, since the headline only re-settles once a day.
        XCTAssertFalse(BatteryHealthMath.shouldFallBackToRawMaxCapacity(hasEverHadRatioSample: true))
    }
}
