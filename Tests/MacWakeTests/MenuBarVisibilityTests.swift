import XCTest
@testable import MacWake

final class MenuBarVisibilityTests: XCTestCase {
    private func contentEnabled(icon: Bool = false, percent: Bool = false, power: Bool = false,
                               timeRemaining: Bool = false, temperature: Bool = false) -> Bool {
        MenuBarVisibility.contentEnabled(icon: icon, percent: percent, power: power,
                                         timeRemaining: timeRemaining, temperature: temperature)
    }

    func testAnEnabledMetricWithNoValueKeepsTheItem() {
        // The reported lock-out: only Time Remaining was on, no estimate was available yet,
        // so the rendered text was empty and the item vanished — taking the only route into
        // Settings with it. Visibility follows the preference, not the text.
        let enabled = contentEnabled(timeRemaining: true)
        XCTAssertTrue(enabled)
        XCTAssertTrue(MenuBarVisibility.itemVisible(contentEnabled: enabled, dynamicIslandEnabled: true))
    }

    func testEveryMetricCountsOnItsOwn() {
        // Any one of these being on means the user still expects an item.
        XCTAssertTrue(contentEnabled(icon: true))
        XCTAssertTrue(contentEnabled(percent: true))
        XCTAssertTrue(contentEnabled(power: true))
        XCTAssertTrue(contentEnabled(timeRemaining: true))
        XCTAssertTrue(contentEnabled(temperature: true))
    }

    func testItemIsHiddenOnlyWhenEverythingIsOff() {
        XCTAssertFalse(contentEnabled())
        XCTAssertFalse(MenuBarVisibility.itemVisible(contentEnabled: false, dynamicIslandEnabled: true))
    }

    func testWithoutTheDynamicIslandTheItemNeverDisappears() {
        // With no notch UI there would be no way back in at all, so the item stays.
        XCTAssertTrue(MenuBarVisibility.itemVisible(contentEnabled: false, dynamicIslandEnabled: false))
    }

    func testIconStandsInWhileTheTextIsEmpty() {
        // Text-only is a valid choice, but an item with neither icon nor text is invisible
        // yet still clickable, which is worse than showing the icon for a moment.
        XCTAssertTrue(MenuBarVisibility.showsIcon(iconEnabled: false, textIsEmpty: true))
        XCTAssertFalse(MenuBarVisibility.showsIcon(iconEnabled: false, textIsEmpty: false))
        XCTAssertTrue(MenuBarVisibility.showsIcon(iconEnabled: true, textIsEmpty: false))
    }
}
