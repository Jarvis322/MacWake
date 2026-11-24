import XCTest
@testable import MacWake

final class ScreenTimeLedgerTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    func testIntervalWithinOneDayIsCreditedToThatDay() {
        var ledger = ScreenTimeLedger()
        ledger.add(from: date(24, 9), to: date(24, 11, 30), calendar: calendar)

        XCTAssertEqual(ledger.days.count, 1)
        XCTAssertEqual(ledger.total(since: calendar.startOfDay(for: date(24, 0))), 9000)
    }

    func testIntervalAcrossMidnightIsSplitBetweenDays() {
        var ledger = ScreenTimeLedger()
        ledger.add(from: date(23, 23), to: date(24, 1, 30), calendar: calendar)

        XCTAssertEqual(ledger.days.map(\.seconds), [3600, 5400])
        // A session that started yesterday only counts today's part toward today.
        XCTAssertEqual(ledger.total(since: calendar.startOfDay(for: date(24, 12))), 5400)
    }

    func testRepeatedCreditsAccumulateInSortedDays() {
        var ledger = ScreenTimeLedger()
        ledger.add(from: date(24, 10), to: date(24, 11), calendar: calendar)
        ledger.add(from: date(22, 10), to: date(22, 10, 30), calendar: calendar)
        ledger.add(from: date(24, 14), to: date(24, 14, 30), calendar: calendar)

        XCTAssertEqual(ledger.days.map(\.start), [calendar.startOfDay(for: date(22, 0)), calendar.startOfDay(for: date(24, 0))])
        XCTAssertEqual(ledger.days.map(\.seconds), [1800, 5400])
    }

    func testEmptyOrReversedIntervalAddsNothing() {
        var ledger = ScreenTimeLedger()
        ledger.add(from: date(24, 10), to: date(24, 10), calendar: calendar)
        ledger.add(from: date(24, 11), to: date(24, 10), calendar: calendar)

        XCTAssertTrue(ledger.days.isEmpty)
    }

    func testBackfillSpreadsExactTotalOverActiveIntervals() {
        var ledger = ScreenTimeLedger()
        // Two hours of timeline marked active, one hour actually on screen.
        let intervals = [
            DateInterval(start: date(23, 23), end: date(24, 0)),
            DateInterval(start: date(24, 9), end: date(24, 10))
        ]
        ledger.add(seconds: 3600, spreadOver: intervals, calendar: calendar)

        XCTAssertEqual(ledger.days.map(\.seconds), [1800, 1800])
    }

    func testPruneDropsDaysBeforeCutoff() {
        var ledger = ScreenTimeLedger()
        ledger.add(from: date(1, 10), to: date(1, 11), calendar: calendar)
        ledger.add(from: date(24, 10), to: date(24, 11), calendar: calendar)
        ledger.prune(before: date(10, 0))

        XCTAssertEqual(ledger.days.count, 1)
        XCTAssertEqual(ledger.days.first?.start, calendar.startOfDay(for: date(24, 0)))
    }

    func testRoundTripsThroughJSON() throws {
        var ledger = ScreenTimeLedger()
        ledger.add(from: date(23, 22), to: date(24, 2), calendar: calendar)

        let decoded = try JSONDecoder().decode(ScreenTimeLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(decoded, ledger)
    }

    func testGoalPeriodsStartAtDayWeekAndMonth() {
        let now = date(26, 15) // Thursday
        XCTAssertEqual(ScreenTimeGoal.daily.periodStart(containing: now, calendar: calendar), date(26, 0))
        XCTAssertEqual(ScreenTimeGoal.weekly.periodStart(containing: now, calendar: calendar), date(23, 0))
        XCTAssertEqual(ScreenTimeGoal.monthly.periodStart(containing: now, calendar: calendar), date(1, 0))
    }

    func testGoalHoursAreClampedToTheirRange() {
        XCTAssertEqual(ScreenTimeGoal.daily.clampedHours(30), 24)
        XCTAssertEqual(ScreenTimeGoal.weekly.clampedHours(0), 1)
        XCTAssertEqual(ScreenTimeGoal.monthly.clampedHours(2), 5)
    }
}
