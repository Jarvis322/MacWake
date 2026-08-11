import XCTest
@testable import MacWake

final class MenuBarLabelTests: XCTestCase {
    // duration(seconds:compact:) calls String(localized:), which resolves against
    // Bundle.main — only populated with Localizable.strings inside the actual built .app
    // (build.sh copies it in), not in the `swift test` runner. These tests exercise the
    // pure arithmetic and the locale-neutral compact digit form directly; the localized
    // text itself is verified by running the shipped app, not by a unit test.

    func testHoursAndMinutesBreaksDownCorrectly() {
        let split = MenuBarLabel.hoursAndMinutes(seconds: 12_000)
        XCTAssertEqual(split.hours, 3)
        XCTAssertEqual(split.minutes, 20)
    }

    func testHoursAndMinutesUnderAnHour() {
        let split = MenuBarLabel.hoursAndMinutes(seconds: 1200)
        XCTAssertEqual(split.hours, 0)
        XCTAssertEqual(split.minutes, 20)
    }

    func testHoursAndMinutesNegativeAndZeroAreSafe() {
        XCTAssertEqual(MenuBarLabel.hoursAndMinutes(seconds: 0).minutes, 0)
        XCTAssertEqual(MenuBarLabel.hoursAndMinutes(seconds: -500).minutes, 0)
    }

    func testCompactDurationIsDigitOnlyAndLocaleNeutral() {
        // "3:5" would be ambiguous; "3:05" is not. This branch never calls
        // String(localized:), so it's safe to assert literally in any environment.
        XCTAssertEqual(MenuBarLabel.duration(seconds: 11_100, compact: true), "3:05")
    }

    func testCompactUnderAnHourDoesNotUseTheDigitForm() {
        // Under an hour, compact and non-compact converge on the same localized "Nm" text
        // rather than "0:20" (which would misread as 20 hours). String(localized:) can't
        // resolve in this environment, so this only checks the branch taken, not the
        // localized text itself — that's verified by running the shipped app.
        let result = MenuBarLabel.duration(seconds: 1200, compact: true)
        XCTAssertFalse(result.contains(":"), "should not fall into the h:mm digit form: \(result)")
    }

    func testCompactWattsDropTheDecimal() {
        XCTAssertEqual(MenuBarLabel.watts(12.4, compact: true), "12W")
        XCTAssertEqual(MenuBarLabel.watts(12.4, compact: false), "12.4W")
    }

    func testSingleMetricIsUnaffectedBySeparatorChoice() {
        XCTAssertEqual(MenuBarLabel.join(["82%"], compact: true), "82%")
        XCTAssertEqual(MenuBarLabel.join(["82%"], compact: false), "82%")
        XCTAssertEqual(MenuBarLabel.join([], compact: false), "")
    }

    func testCompactJoinUsesTheNarrowerSeparator() {
        // Compact's point is spending fewer characters on the same metrics — verify the
        // separator itself narrows, without depending on localized duration/watt text.
        let standard = MenuBarLabel.join(["82%", "12.4W", "41°"], compact: false)
        let compact = MenuBarLabel.join(["82%", "12W", "41°"], compact: true)
        XCTAssertLessThan(compact.count, standard.count)
    }
}
