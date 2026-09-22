import XCTest
@testable import ZynSign

final class ArchiveLimitsTests: XCTestCase {

    func testDefaultPolicyIsPositiveEverywhere() {
        let limits = ArchiveLimits.default
        XCTAssertGreaterThan(limits.maximumEntryCount, 0)
        XCTAssertGreaterThan(limits.maximumEntryNameLength, 0)
        XCTAssertGreaterThan(limits.maximumPathDepth, 0)
        XCTAssertGreaterThan(limits.maximumEntryBytes, 0)
        XCTAssertGreaterThan(limits.maximumTotalUncompressedBytes, 0)
        XCTAssertGreaterThan(limits.maximumCompressionRatio, 0)
        XCTAssertGreaterThan(limits.maximumInspectionReadBytes, 0)
    }

    func testDefaultPolicyAcceptsAnOrdinaryPackage() {
        let limits = ArchiveLimits.default
        XCTAssertFalse(limits.exceedsEntryBytes(512 * 1_024 * 1_024))
        XCTAssertFalse(limits.exceedsTotalUncompressedBytes(2 * 1_024 * 1_024 * 1_024))
        XCTAssertFalse(limits.exceedsCompressionRatio(uncompressedSize: 4_096, compressedSize: 1_024))
    }

    func testEntryByteCeilingIsDetected() {
        let limits = ArchiveLimits.default
        XCTAssertTrue(limits.exceedsEntryBytes(limits.maximumEntryBytes + 1))
        XCTAssertFalse(limits.exceedsEntryBytes(limits.maximumEntryBytes))
    }

    func testTotalUncompressedCeilingIsDetected() {
        let limits = ArchiveLimits.default
        XCTAssertTrue(limits.exceedsTotalUncompressedBytes(limits.maximumTotalUncompressedBytes + 1))
        XCTAssertFalse(limits.exceedsTotalUncompressedBytes(limits.maximumTotalUncompressedBytes))
    }

    func testCompressionRatioCeilingIsDetected() {
        let limits = ArchiveLimits.default
        let beyond = limits.maximumCompressionRatio + 1
        XCTAssertTrue(limits.exceedsCompressionRatio(uncompressedSize: beyond * 100, compressedSize: 100))
        XCTAssertFalse(limits.exceedsCompressionRatio(uncompressedSize: 100, compressedSize: 100))
    }

    func testCompressionRatioOfStoredContentIsNotAViolation() {
        let limits = ArchiveLimits.default
        XCTAssertFalse(limits.exceedsCompressionRatio(uncompressedSize: 64, compressedSize: 64))
        XCTAssertFalse(limits.exceedsCompressionRatio(uncompressedSize: 0, compressedSize: 0))
    }

    func testCompressionRatioComparisonDoesNotOverflowOnHostileSizes() {
        let limits = ArchiveLimits.default
        // Both values are near Int's ceiling; a multiplication-based
        // comparison would overflow and could report the wrong result.
        let hostile = Int.max
        XCTAssertTrue(limits.exceedsCompressionRatio(uncompressedSize: hostile, compressedSize: 1))
        XCTAssertFalse(limits.exceedsCompressionRatio(uncompressedSize: hostile, compressedSize: hostile))
    }
}
