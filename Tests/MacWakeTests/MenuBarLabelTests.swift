import XCTest
@testable import MacWake

final class MenuBarLabelTests: XCTestCase {
    func testCompactShortensTheWholeLabelSubstantially() {
        // The reported problem: with every metric on, the label crowds neighbouring menu-bar
        // items. Same metrics either way — Compact just spends fewer characters on them.
        let defaultParts = [
            "82%",
            MenuBarLabel.watts(12.4, compact: false),
            "~" + MenuBarLabel.duration(seconds: 12_000, compact: false),
            "41°",
        ]
        let compactParts = [
            "82%",
            MenuBarLabel.watts(12.4, compact: true),
            "~" + MenuBarLabel.duration(seconds: 12_000, compact: true),
            "41°",
        ]
        let standard = MenuBarLabel.join(defaultParts, compact: false)
        let compact = MenuBarLabel.join(compactParts, compact: true)

        XCTAssertEqual(standard, "82%  12.4W  ~3h 20m  41°")
        XCTAssertEqual(compact, "82% 12W ~3:20 41°")
        // Roughly a third narrower is the point of the feature; assert it holds.
        XCTAssertLessThan(Double(compact.count), Double(standard.count) * 0.75)
    }

    func testDurationsUnderAnHourReadTheSameInBothModes() {
        // "0:20" would be misread as 20 hours at a glance, so minutes stay minutes.
        XCTAssertEqual(MenuBarLabel.duration(seconds: 1200, compact: false), "20m")
        XCTAssertEqual(MenuBarLabel.duration(seconds: 1200, compact: true), "20m")
    }

    func testCompactDurationPadsMinutes() {
        // "3:5" would be ambiguous; "3:05" is not.
        XCTAssertEqual(MenuBarLabel.duration(seconds: 11_100, compact: true), "3:05")
        XCTAssertEqual(MenuBarLabel.duration(seconds: 11_100, compact: false), "3h 5m")
    }

    func testNegativeAndZeroDurationsAreSafe() {
        XCTAssertEqual(MenuBarLabel.duration(seconds: 0, compact: true), "0m")
        XCTAssertEqual(MenuBarLabel.duration(seconds: -500, compact: true), "0m")
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
}
