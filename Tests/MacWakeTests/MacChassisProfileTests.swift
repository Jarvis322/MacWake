import XCTest
@testable import MacWake

final class MacChassisProfileTests: XCTestCase {
    func testM4AirIsAThirteenInchNotchedAirInStarlightFirst() {
        let profile = MacChassisProfile(productName: "MacBook Air (13-inch, M4, 2025)", chip: "Apple M4")
        XCTAssertEqual(profile.family, .air)
        XCTAssertEqual(profile.width, 30.41)
        XCTAssertTrue(profile.hasNotch)
        XCTAssertFalse(profile.hasTouchBar)
        XCTAssertEqual(profile.finishes.first, .starlight)
        XCTAssertTrue(profile.finishes.contains(.skyBlue))
    }

    func testFifteenInchAirIsWider() {
        let profile = MacChassisProfile(productName: "MacBook Air (15-inch, M3, 2024)", chip: "Apple M3")
        XCTAssertEqual(profile.width, 34.04)
        XCTAssertFalse(profile.finishes.contains(.skyBlue))
    }

    func testM1AirHasNoNotch() {
        let profile = MacChassisProfile(productName: "MacBook Air (M1, 2020)", chip: "Apple M1")
        XCTAssertEqual(profile.family, .air)
        XCTAssertFalse(profile.hasNotch)
    }

    func testThirteenInchProHasATouchBarAndNoNotch() {
        let profile = MacChassisProfile(productName: "MacBook Pro (13-inch, M2, 2022)", chip: "Apple M2")
        XCTAssertTrue(profile.hasTouchBar)
        XCTAssertFalse(profile.hasNotch)
    }

    func testSixteenInchProIsTheLargestFootprint() {
        let profile = MacChassisProfile(productName: "MacBook Pro (16-inch, 2024)", chip: "Apple M4 Max")
        XCTAssertEqual(profile.family, .pro)
        XCTAssertEqual(profile.width, 35.57)
        XCTAssertTrue(profile.hasNotch)
    }

    func testDesktopsGetNoLid() {
        XCTAssertFalse(MacChassisProfile(productName: "Mac mini (2024)", chip: "Apple M4").isLaptop)
    }

    func testPanelSizeComesFromTheDiagonalAndResolution() throws {
        let panel = try XCTUnwrap(MacChassisProfile(productName: "MacBook Air (13-inch, M4, 2025)", chip: "Apple M4").panel)
        XCTAssertEqual(panel.widthCm, 28.97, accuracy: 0.05)
        XCTAssertEqual(panel.heightCm, 18.83, accuracy: 0.05)
    }

    func testCurrentMacMiniIsTheSmallBox() {
        let mini = MacChassisProfile(productName: "Mac mini (2024)", chip: "Apple M4")
        XCTAssertEqual(mini.family, .mini)
        XCTAssertEqual(mini.width, 12.7)
        XCTAssertEqual(mini.height, 5.0)
        XCTAssertEqual(MacChassisProfile(productName: "Mac mini (M2, 2023)", chip: "Apple M2").width, 19.7)
    }

    func testStudioAndUnknownDesktopsGetTheStudioBox() {
        XCTAssertEqual(MacChassisProfile(productName: "Mac Studio (2025)", chip: "Apple M4 Max").family, .studio)
        XCTAssertEqual(MacChassisProfile(productName: "Mac Pro (2023)", chip: "Apple M2 Ultra").family, .studio)
    }

    func testIMacHasAPanelAndItsColours() {
        let iMac = MacChassisProfile(productName: "iMac (24-inch, 2024)", chip: "Apple M4")
        XCTAssertEqual(iMac.family, .iMac)
        XCTAssertNotNil(iMac.panel)
        XCTAssertTrue(iMac.finishes.contains(.purple))
        XCTAssertFalse(iMac.isLaptop)
    }

    func testSavedFinishOnlyAppliesWhenTheModelCameInIt() {
        let air = MacChassisProfile(productName: "MacBook Air (13-inch, M4, 2025)", chip: "Apple M4")
        XCTAssertEqual(air.finish(saved: "midnight"), .midnight)
        XCTAssertEqual(air.finish(saved: "spaceBlack"), .starlight)
        XCTAssertEqual(air.finish(saved: nil), .starlight)
    }
}
