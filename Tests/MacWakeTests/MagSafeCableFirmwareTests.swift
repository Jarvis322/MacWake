import XCTest
@testable import MacWake

final class MagSafeCableFirmwareTests: XCTestCase {
    /// Verbatim from `hpmdiagnose` on a MacBook Air (Mac16,12) with an Apple USB-C to MagSafe 3
    /// cable at firmware 3.1.12; the other two ports had nothing connected.
    private let sample = """
    HPM at RID 0x0 Route 0x0 Address 0x0c :

    0x48\t0x04\t0x00000000
    0x49\t0x3D\t0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
    HPM at RID 0x5 Route 0x0 Address 0x08 :

    0x49\t0x3D\t0x54AC05001C000000001231007840060B6100000000000000000000AC050000000000000000000000000000000000000000000000000000000000000000
    """

    func testReadsTheFirmwareOfAnAppleMagSafe3Cable() {
        XCTAssertEqual(MagSafeCableFirmware.parse(hpmdiagnose: sample), "3.1.12")
    }

    func testNoCableMeansNoFirmware() {
        let empty = "0x49\t0x3D\t0x" + String(repeating: "00", count: 61)
        XCTAssertNil(MagSafeCableFirmware.parse(hpmdiagnose: empty))
        XCTAssertNil(MagSafeCableFirmware.parse(hpmdiagnose: ""))
    }

    func testOtherProductsAreNotReportedAsTheCable() {
        // Same layout, product ID 0x7801 instead of 0x7800.
        let other = sample.replacingOccurrences(of: "1231007840", with: "1231017840")
        XCTAssertNil(MagSafeCableFirmware.parse(hpmdiagnose: other))
        // Different vendor.
        let foreign = sample.replacingOccurrences(of: "54AC0500", with: "54AD0500")
        XCTAssertNil(MagSafeCableFirmware.parse(hpmdiagnose: foreign))
    }

    func testDecodesBCDVersions() {
        XCTAssertEqual(MagSafeCableFirmware.decodeVersion(bcdDevice: 0x3112), "3.1.12")
        XCTAssertEqual(MagSafeCableFirmware.decodeVersion(bcdDevice: 0x3200), "3.2.0")
        XCTAssertNil(MagSafeCableFirmware.decodeVersion(bcdDevice: 0x31AF))
    }

    func testRecognisesANewerVersion() {
        XCTAssertTrue(MagSafeCableFirmware.isNewer("3.2.0", than: "3.1.12"))
        XCTAssertTrue(MagSafeCableFirmware.isNewer("3.1.12", than: "3.1.9"))
        XCTAssertFalse(MagSafeCableFirmware.isNewer("3.1.12", than: "3.1.12"))
        XCTAssertFalse(MagSafeCableFirmware.isNewer("3.1.12", than: "3.2.0"))
        XCTAssertFalse(MagSafeCableFirmware.isNewer("garbage", than: "3.1.12"))
    }
}
