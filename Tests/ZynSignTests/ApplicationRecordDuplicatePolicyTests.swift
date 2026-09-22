import XCTest
@testable import ZynSign

/// Tests for the deterministic duplicate policy: byte identity decides
/// whether a candidate is a duplicate; declared metadata only describes the
/// relation to existing records.
final class ApplicationRecordDuplicatePolicyTests: XCTestCase {

    private let synthetic = LibraryFixtures.identity()

    // MARK: - Byte identity

    func testCandidateWithNoRecordsIsUnrelated() {
        let verdict = ApplicationRecordDuplicatePolicy.evaluate(
            candidate: LibraryFixtures.reference(),
            identity: synthetic,
            against: []
        )

        XCTAssertEqual(verdict, .distinct(.unrelated))
        XCTAssertTrue(verdict.permitsNewRecord)
    }

    func testIdenticalBytesAreRecognisedRegardlessOfDeclaredIdentity() {
        let existing = LibraryFixtures.record(
            identity: LibraryFixtures.identity(bundleIdentifier: "com.example.other"),
            artifact: LibraryFixtures.reference(byteCount: 500, fingerprintSeed: 0x42)
        )
        let candidate = LibraryFixtures.reference(byteCount: 500, fingerprintSeed: 0x42)

        let verdict = ApplicationRecordDuplicatePolicy.evaluate(
            candidate: candidate,
            identity: synthetic,
            against: [existing]
        )

        XCTAssertEqual(verdict, .identical(existing: existing))
        XCTAssertFalse(verdict.permitsNewRecord)
    }

    func testIdenticalBytesTakePrecedenceOverSameVersionRecords() {
        let sameVersion = LibraryFixtures.record(
            artifact: LibraryFixtures.reference(fingerprintSeed: 0x01),
            importedAt: LibraryFixtures.importDate
        )
        let identical = LibraryFixtures.record(
            identity: LibraryFixtures.identity(shortVersion: "9.9"),
            artifact: LibraryFixtures.reference(fingerprintSeed: 0x02),
            importedAt: LibraryFixtures.laterDate
        )

        let verdict = ApplicationRecordDuplicatePolicy.evaluate(
            candidate: LibraryFixtures.reference(fingerprintSeed: 0x02),
            identity: synthetic,
            against: [sameVersion, identical]
        )

        XCTAssertEqual(verdict, .identical(existing: identical))
    }

    func testEarliestIdenticalRecordIsReportedWhenSeveralMatch() {
        let content = LibraryFixtures.reference(fingerprintSeed: 0x07)
        let earlier = LibraryFixtures.record(
            artifact: ArtifactReference(artifactID: ArtifactIdentifier(), byteCount: content.byteCount, fingerprint: content.fingerprint),
            importedAt: LibraryFixtures.importDate
        )
        let later = LibraryFixtures.record(
            artifact: ArtifactReference(artifactID: ArtifactIdentifier(), byteCount: content.byteCount, fingerprint: content.fingerprint),
            importedAt: LibraryFixtures.laterDate
        )

        let forward = ApplicationRecordDuplicatePolicy.evaluate(candidate: content, identity: synthetic, against: [earlier, later])
        let reversed = ApplicationRecordDuplicatePolicy.evaluate(candidate: content, identity: synthetic, against: [later, earlier])

        XCTAssertEqual(forward, .identical(existing: earlier))
        XCTAssertEqual(reversed, .identical(existing: earlier))
    }

    func testSameFingerprintWithDifferentSizeIsNotIdentical() {
        let existing = LibraryFixtures.record(
            identity: LibraryFixtures.identity(bundleIdentifier: "com.example.other"),
            artifact: LibraryFixtures.reference(byteCount: 500, fingerprintSeed: 0x42)
        )

        let verdict = ApplicationRecordDuplicatePolicy.evaluate(
            candidate: LibraryFixtures.reference(byteCount: 501, fingerprintSeed: 0x42),
            identity: synthetic,
            against: [existing]
        )

        XCTAssertEqual(verdict, .distinct(.unrelated))
    }

    func testRecordsWhoseArtifactIsNotHeldCannotMakeTheCandidateADuplicate() {
        let content = LibraryFixtures.reference(fingerprintSeed: 0x07)
        let unheld = LibraryFixtures.record(
            artifact: ArtifactReference(artifactID: ArtifactIdentifier(), byteCount: content.byteCount, fingerprint: content.fingerprint),
            importedAt: LibraryFixtures.importDate
        )
        let held = LibraryFixtures.record(
            artifact: ArtifactReference(artifactID: ArtifactIdentifier(), byteCount: content.byteCount, fingerprint: content.fingerprint),
            importedAt: LibraryFixtures.laterDate
        )

        let onlyLaterHeld = ApplicationRecordDuplicatePolicy.evaluate(
            candidate: content,
            identity: synthetic,
            against: [unheld, held],
            holding: { $0.id == held.id }
        )
        let nothingHeld = ApplicationRecordDuplicatePolicy.evaluate(
            candidate: content,
            identity: synthetic,
            against: [unheld, held],
            holding: { _ in false }
        )

        XCTAssertEqual(onlyLaterHeld, .identical(existing: held))
        // Without held content the same bytes are a distinct import; the
        // records are still related through their declared identity.
        XCTAssertEqual(nothingHeld, .distinct(.sameDeclaredVersion([unheld, held])))
    }

    // MARK: - Relations by declared identity

    func testDifferentBytesWithSameDeclaredVersionAreDistinctAndRelated() {
        let existing = LibraryFixtures.record(artifact: LibraryFixtures.reference(fingerprintSeed: 0x01))

        let verdict = ApplicationRecordDuplicatePolicy.evaluate(
            candidate: LibraryFixtures.reference(fingerprintSeed: 0x02),
            identity: synthetic,
            against: [existing]
        )

        XCTAssertEqual(verdict, .distinct(.sameDeclaredVersion([existing])))
        XCTAssertTrue(verdict.permitsNewRecord)
    }

    func testDifferentDeclaredVersionOfTheSameBundleIsAnotherVersion() {
        let older = LibraryFixtures.record(
            identity: LibraryFixtures.identity(shortVersion: "1.1", build: "30"),
            artifact: LibraryFixtures.reference(fingerprintSeed: 0x01)
        )
        let sameMarketingOtherBuild = LibraryFixtures.record(
            identity: LibraryFixtures.identity(shortVersion: "1.2", build: "35"),
            artifact: LibraryFixtures.reference(fingerprintSeed: 0x02)
        )

        let verdict = ApplicationRecordDuplicatePolicy.evaluate(
            candidate: LibraryFixtures.reference(fingerprintSeed: 0x03),
            identity: synthetic,
            against: [sameMarketingOtherBuild, older]
        )

        guard case .distinct(.otherVersions(let others)) = verdict else {
            return XCTFail("Expected other versions, got \(verdict)")
        }
        XCTAssertEqual(Set(others.map { $0.id }), Set([older.id, sameMarketingOtherBuild.id]))
    }

    func testSameVersionRecordsAreReportedInPreferenceToOtherVersions() {
        let otherVersion = LibraryFixtures.record(
            identity: LibraryFixtures.identity(shortVersion: "1.1"),
            artifact: LibraryFixtures.reference(fingerprintSeed: 0x01)
        )
        let sameVersion = LibraryFixtures.record(
            artifact: LibraryFixtures.reference(fingerprintSeed: 0x02),
            importedAt: LibraryFixtures.laterDate
        )

        let verdict = ApplicationRecordDuplicatePolicy.evaluate(
            candidate: LibraryFixtures.reference(fingerprintSeed: 0x03),
            identity: synthetic,
            against: [otherVersion, sameVersion]
        )

        XCTAssertEqual(verdict, .distinct(.sameDeclaredVersion([sameVersion])))
    }

    func testRelatedRecordsAreListedInLibraryOrderWhateverTheInputOrder() {
        let first = LibraryFixtures.record(
            identity: LibraryFixtures.identity(shortVersion: "1.0"),
            artifact: LibraryFixtures.reference(fingerprintSeed: 0x01),
            importedAt: LibraryFixtures.importDate
        )
        let second = LibraryFixtures.record(
            identity: LibraryFixtures.identity(shortVersion: "1.1"),
            artifact: LibraryFixtures.reference(fingerprintSeed: 0x02),
            importedAt: LibraryFixtures.laterDate
        )

        let forward = ApplicationRecordDuplicatePolicy.evaluate(
            candidate: LibraryFixtures.reference(fingerprintSeed: 0x03),
            identity: synthetic,
            against: [first, second]
        )
        let reversed = ApplicationRecordDuplicatePolicy.evaluate(
            candidate: LibraryFixtures.reference(fingerprintSeed: 0x03),
            identity: synthetic,
            against: [second, first]
        )

        XCTAssertEqual(forward, .distinct(.otherVersions([first, second])))
        XCTAssertEqual(reversed, forward)
    }

    func testRecordsOfOtherBundlesAreUnrelated() {
        let other = LibraryFixtures.record(
            identity: LibraryFixtures.identity(bundleIdentifier: "com.example.other"),
            artifact: LibraryFixtures.reference(fingerprintSeed: 0x01)
        )

        let verdict = ApplicationRecordDuplicatePolicy.evaluate(
            candidate: LibraryFixtures.reference(fingerprintSeed: 0x02),
            identity: synthetic,
            against: [other]
        )

        XCTAssertEqual(verdict, .distinct(.unrelated))
    }

    // MARK: - Version comparison

    func testDeclaredVersionsAreComparedExactlyIncludingUndeclaredValues() {
        let undeclared = LibraryFixtures.identity(shortVersion: nil, build: nil)
        let alsoUndeclared = LibraryFixtures.identity(displayName: "Renamed", shortVersion: nil, build: nil)
        let declared = LibraryFixtures.identity(shortVersion: "1.2", build: nil)

        XCTAssertTrue(undeclared.declaresSameVersion(as: alsoUndeclared))
        XCTAssertFalse(undeclared.declaresSameVersion(as: declared))
        XCTAssertTrue(synthetic.declaresSameVersion(as: LibraryFixtures.identity(displayName: "Other name")))
        XCTAssertFalse(synthetic.declaresSameVersion(as: LibraryFixtures.identity(shortVersion: "1.20")))
        XCTAssertFalse(synthetic.declaresSameVersion(as: LibraryFixtures.identity(bundleIdentifier: "com.example.other")))
    }
}
