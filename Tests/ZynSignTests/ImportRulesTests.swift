import XCTest
@testable import ZynSign

/// Tests for the Import Hub's smart rules and the version ordering they
/// rest on.
final class ImportRulesTests: XCTestCase {

    // MARK: - Version ordering

    func testVersionsCompareTheWayPeopleReadThem() {
        XCTAssertEqual(DeclaredVersionOrder.compare("1.10", "1.9"), .orderedDescending)
        XCTAssertEqual(DeclaredVersionOrder.compare("1.9", "1.10"), .orderedAscending)
        XCTAssertEqual(DeclaredVersionOrder.compare("2.0", "10.0"), .orderedAscending)
        XCTAssertEqual(DeclaredVersionOrder.compare("1.2.3", "1.2.3"), .orderedSame)
    }

    func testMissingComponentsReadAsZero() {
        XCTAssertEqual(DeclaredVersionOrder.compare("1.2", "1.2.0"), .orderedSame)
        XCTAssertEqual(DeclaredVersionOrder.compare("1.2", "1.2.1"), .orderedAscending)
        XCTAssertEqual(DeclaredVersionOrder.compare("01.02", "1.2"), .orderedSame)
    }

    func testAPreReleaseComesBeforeItsRelease() {
        XCTAssertEqual(DeclaredVersionOrder.compare("1.0b1", "1.0"), .orderedAscending)
        XCTAssertEqual(DeclaredVersionOrder.compare("1.0-beta", "1.0"), .orderedAscending)
        XCTAssertEqual(DeclaredVersionOrder.compare("1.0b2", "1.0b10"), .orderedAscending)
        XCTAssertEqual(DeclaredVersionOrder.compare("1.0a1", "1.0B1"), .orderedAscending)
    }

    func testAbsurdlyLongNumbersCompareWithoutOverflow() {
        XCTAssertEqual(
            DeclaredVersionOrder.compare("1.99999999999999999999999", "1.100000000000000000000000"),
            .orderedAscending
        )
    }

    func testBuildsBreakTiesBetweenEqualVersions() {
        XCTAssertEqual(DeclaredVersionOrder.compare(version: "1.2", build: "35", with: "1.2", build: "34"), .orderedDescending)
        XCTAssertEqual(DeclaredVersionOrder.compare(version: "1.2", build: "34", with: "1.2", build: "34"), .orderedSame)
        XCTAssertEqual(DeclaredVersionOrder.compare(version: "1.3", build: "1", with: "1.2", build: "900"), .orderedDescending)
    }

    func testDeclarationsThatCannotBeOrderedAreNotGuessed() {
        XCTAssertNil(DeclaredVersionOrder.compare(version: nil, build: "5", with: "1.0", build: "5"))
        XCTAssertNil(DeclaredVersionOrder.compare(version: "1.0", build: nil, with: "1.0", build: "5"))
        XCTAssertNil(DeclaredVersionOrder.compare(version: "  ", build: nil, with: "1.0", build: nil))
        XCTAssertEqual(DeclaredVersionOrder.compare(version: nil, build: nil, with: nil, build: nil), .orderedSame)
    }

    // MARK: - Rules

    private func record(version: String?, build: String?, seed: UInt8 = 0xEE, byteCount: Int = 1_024, importedAt: Date = LibraryFixtures.importDate) -> ApplicationRecord {
        LibraryFixtures.record(
            identity: LibraryFixtures.identity(shortVersion: version, build: build),
            artifact: LibraryFixtures.reference(byteCount: byteCount, fingerprintSeed: seed),
            importedAt: importedAt
        )
    }

    private func conflict(
        incoming identity: ApplicationIdentity,
        seed: UInt8 = 0x01,
        byteCount: Int = 2_048,
        against existing: [ApplicationRecord]
    ) -> ImportConflict? {
        let reference = LibraryFixtures.reference(byteCount: byteCount, fingerprintSeed: seed)
        let report = DuplicateDetection.report(identity: identity, reference: reference, against: existing)
        return ImportRules.conflict(for: report, incoming: identity)
    }

    func testADifferentApplicationIsNotAConflict() {
        let other = LibraryFixtures.record(identity: LibraryFixtures.identity(bundleIdentifier: "com.example.other"))
        XCTAssertNil(conflict(incoming: LibraryFixtures.identity(), against: [other]))
        XCTAssertNil(conflict(incoming: LibraryFixtures.identity(), against: []))
    }

    func testANewerVersionSuggestsReplacing() throws {
        let existing = record(version: "1.2", build: "34")
        let result = try XCTUnwrap(conflict(incoming: LibraryFixtures.identity(shortVersion: "1.3", build: "1"), against: [existing]))

        XCTAssertEqual(result.relation, .newerVersion)
        XCTAssertEqual(result.suggestion, .replaceExisting)
        XCTAssertEqual(result.comparedRecord, existing)
        XCTAssertEqual(result.existingRecords, [existing])
        XCTAssertEqual(result.incomingByteCount, 2_048)
    }

    func testTheSameVersionWithDifferentContentAsksTheUser() throws {
        let existing = record(version: "1.2", build: "34")
        let result = try XCTUnwrap(conflict(incoming: LibraryFixtures.identity(shortVersion: "1.2", build: "34"), against: [existing]))

        XCTAssertEqual(result.relation, .sameVersion)
        XCTAssertNil(result.suggestion)
    }

    func testIdenticalContentSuggestsSkipping() throws {
        let existing = record(version: "1.2", build: "34", seed: 0x42, byteCount: 2_048)
        let result = try XCTUnwrap(conflict(incoming: LibraryFixtures.identity(shortVersion: "1.2", build: "34"), seed: 0x42, against: [existing]))

        XCTAssertEqual(result.relation, .identicalContent)
        XCTAssertEqual(result.suggestion, .skip)
    }

    func testAnOlderVersionSuggestsKeepingBoth() throws {
        let existing = record(version: "2.0", build: "1")
        let result = try XCTUnwrap(conflict(incoming: LibraryFixtures.identity(shortVersion: "1.9", build: "1"), against: [existing]))

        XCTAssertEqual(result.relation, .olderVersion)
        XCTAssertEqual(result.suggestion, .keepBoth)
    }

    func testVersionsThatCannotBeOrderedAskTheUser() throws {
        let existing = record(version: "1.0", build: "1")
        let result = try XCTUnwrap(conflict(incoming: LibraryFixtures.identity(shortVersion: nil, build: "1"), against: [existing]))

        XCTAssertEqual(result.relation, .undeterminedVersion)
        XCTAssertNil(result.suggestion)
    }

    func testTheComparisonIsAgainstTheNewestExistingVersion() throws {
        let old = record(version: "1.0", build: "1", seed: 0x0A, importedAt: LibraryFixtures.laterDate)
        let newest = record(version: "1.5", build: "1", seed: 0x0B, importedAt: LibraryFixtures.importDate)
        let result = try XCTUnwrap(conflict(incoming: LibraryFixtures.identity(shortVersion: "1.2", build: "1"), against: [old, newest]))

        XCTAssertEqual(result.comparedRecord, newest)
        XCTAssertEqual(result.relation, .olderVersion, "1.2 is newer than 1.0 but older than 1.5.")
        XCTAssertEqual(Set(result.existingRecords), [old, newest], "Replacing would remove every entry of the application.")
    }

    func testEveryConflictOffersAllThreeResolutions() throws {
        let existing = record(version: "1.0", build: "1")
        let result = try XCTUnwrap(conflict(incoming: LibraryFixtures.identity(shortVersion: "2.0"), against: [existing]))
        XCTAssertEqual(result.offeredResolutions, [.keepBoth, .replaceExisting, .skip])
        XCTAssertTrue(ConflictResolution.replaceExisting.isDestructive)
        XCTAssertFalse(ConflictResolution.keepBoth.isDestructive)
        XCTAssertFalse(ConflictResolution.skip.isDestructive)
    }
}
