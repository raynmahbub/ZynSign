import XCTest
@testable import ZynSign

/// Tests for the storage gauge classification.
final class StorageGaugeReadingTests: XCTestCase {

    func testComfortablePressure() {
        let reading = StorageGaugeReading(facts: VolumeCapacityFacts(
            totalBytes: 100_000, availableBytes: 50_000, appUsageBytes: 1_000
        ))
        XCTAssertEqual(reading.pressure, .comfortable)
        XCTAssertEqual(reading.freeFraction ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(reading.usedFraction ?? 0, 0.5, accuracy: 0.001)
    }

    func testAttentionPressure() {
        let reading = StorageGaugeReading(facts: VolumeCapacityFacts(
            totalBytes: 100_000, availableBytes: 10_000, appUsageBytes: nil
        ))
        XCTAssertEqual(reading.pressure, .attention)
    }

    func testCriticalPressure() {
        let reading = StorageGaugeReading(facts: VolumeCapacityFacts(
            totalBytes: 100_000, availableBytes: 1_000, appUsageBytes: nil
        ))
        XCTAssertEqual(reading.pressure, .critical)
    }

    func testUnknownFactsYieldUnknownPressure() {
        let reading = StorageGaugeReading(facts: VolumeCapacityFacts(
            totalBytes: nil, availableBytes: nil, appUsageBytes: nil
        ))
        XCTAssertEqual(reading.pressure, .unknown)
        XCTAssertNil(reading.freeFraction)
        XCTAssertNil(reading.usedFraction)
    }

    func testZeroTotalIsUnknownRatherThanDivideByZero() {
        let reading = StorageGaugeReading(facts: VolumeCapacityFacts(
            totalBytes: 0, availableBytes: 0, appUsageBytes: nil
        ))
        XCTAssertEqual(reading.pressure, .unknown)
    }

    func testAvailableAboveTotalClampsToOne() {
        let reading = StorageGaugeReading(facts: VolumeCapacityFacts(
            totalBytes: 100, availableBytes: 500, appUsageBytes: nil
        ))
        XCTAssertEqual(reading.freeFraction ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(reading.usedFraction ?? 0, 0.0, accuracy: 0.001)
        XCTAssertEqual(reading.pressure, .comfortable)
    }

    func testHumanReadableFormats() {
        XCTAssertEqual(StorageGaugeReading.humanReadable(nil), "—")
        let oneGB = StorageGaugeReading.humanReadable(1_073_741_824)
        XCTAssertTrue(oneGB.contains("GB"), "got \(oneGB)")
    }
}
