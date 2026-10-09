import XCTest
@testable import MacWake

final class ClamshellGuardTests: XCTestCase {
    func testSuppressesOnlyWithTheLidClosedAndADisplayAttached() {
        XCTAssertTrue(ClamshellGuard.shouldSuppressAdapterCut(lidClosed: true, externalDisplayAttached: true, allowOverride: false))
        XCTAssertFalse(ClamshellGuard.shouldSuppressAdapterCut(lidClosed: false, externalDisplayAttached: true, allowOverride: false))
        XCTAssertFalse(ClamshellGuard.shouldSuppressAdapterCut(lidClosed: true, externalDisplayAttached: false, allowOverride: false))
        XCTAssertFalse(ClamshellGuard.shouldSuppressAdapterCut(lidClosed: false, externalDisplayAttached: false, allowOverride: false))
    }

    func testTheUserCanOverrideIt() {
        XCTAssertFalse(ClamshellGuard.shouldSuppressAdapterCut(lidClosed: true, externalDisplayAttached: true, allowOverride: true))
    }
}
