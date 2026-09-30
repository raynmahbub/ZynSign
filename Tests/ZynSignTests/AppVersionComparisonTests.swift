import XCTest
@testable import ZynSign

/// Tests for the bounded application version comparator.
final class AppVersionComparisonTests: XCTestCase {

    func testNumericOrdering() {
        XCTAssertEqual(AppVersionComparison.compare("1.9", "1.10"), .older)
        XCTAssertEqual(AppVersionComparison.compare("1.10", "1.9"), .newer)
        XCTAssertEqual(AppVersionComparison.compare("2.0", "2.0.0"), .same)
        XCTAssertEqual(AppVersionComparison.compare("1.2.3.1", "1.2.3"), .newer)
        XCTAssertEqual(AppVersionComparison.compare("0.1", "0.1.0.0"), .same)
    }

    func testLeadingVIsAccepted() {
        XCTAssertEqual(AppVersionComparison.compare("v1.2", "1.2"), .same)
        XCTAssertEqual(AppVersionComparison.compare("V2.0", "v1.9"), .newer)
        XCTAssertEqual(AppVersionComparison.parse("v3.4.5"), [3, 4, 5])
    }

    func testUnparseableVersionsAreIncomparable() {
        XCTAssertEqual(AppVersionComparison.compare("1.2-beta", "1.2"), .incomparable)
        XCTAssertEqual(AppVersionComparison.compare("", "1.0"), .incomparable)
        XCTAssertEqual(AppVersionComparison.compare("1..2", "1.2"), .incomparable)
        XCTAssertEqual(AppVersionComparison.compare("1.2.3.4.5.6.7", "1.0"), .incomparable)
        XCTAssertNil(AppVersionComparison.parse("latest"))
    }

    func testHugeComponentsAreRejected() {
        XCTAssertNil(AppVersionComparison.parse("9999999999.1"))
        XCTAssertEqual(AppVersionComparison.parse("999999999.1"), [999_999_999, 1])
    }

    func testUpdateDetectionNeverGuesses() {
        XCTAssertTrue(AppVersionComparison.isUpdate("1.1", over: "1.0"))
        XCTAssertFalse(AppVersionComparison.isUpdate("1.0", over: "1.0"))
        XCTAssertFalse(AppVersionComparison.isUpdate("0.9", over: "1.0"))
        XCTAssertFalse(AppVersionComparison.isUpdate("weird", over: "1.0"))
        XCTAssertFalse(AppVersionComparison.isUpdate("1.0", over: "weird"))
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(AppVersionComparison.compare(" 1.0 ", "1.0"), .same)
    }
}
