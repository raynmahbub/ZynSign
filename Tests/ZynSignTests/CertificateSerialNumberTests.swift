import XCTest
@testable import ZynSign

final class CertificateSerialNumberTests: XCTestCase {

    func testRejectsEmptyOddAndNonHexadecimal() {
        XCTAssertNil(CertificateSerialNumber(hexadecimal: ""))
        XCTAssertNil(CertificateSerialNumber(hexadecimal: "abc"))
        XCTAssertNil(CertificateSerialNumber(hexadecimal: "0g"))
        XCTAssertNil(CertificateSerialNumber(contentBytes: []))
    }

    func testNormalisesCaseAndPreservesLeadingZeros() {
        let serial = CertificateSerialNumber(hexadecimal: "0080")
        XCTAssertEqual(serial?.hexadecimal, "0080")
        XCTAssertEqual(CertificateSerialNumber(hexadecimal: "0080"), CertificateSerialNumber(hexadecimal: "0080"))
        XCTAssertNotEqual(serial, CertificateSerialNumber(hexadecimal: "80"))
        XCTAssertEqual(serial?.contentBytes, [0x00, 0x80])
    }

    func testRoundTripsContentBytes() {
        let bytes: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14]
        let serial = CertificateSerialNumber(contentBytes: bytes)
        XCTAssertEqual(serial?.contentBytes, bytes)
        XCTAssertEqual(serial?.hexadecimal, "0102030405060708090a0b0c0d0e0f1011121314")
        XCTAssertNil(UInt64(serial?.hexadecimal ?? "", radix: 16))
    }
}
