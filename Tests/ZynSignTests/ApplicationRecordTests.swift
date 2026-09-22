import XCTest
@testable import ZynSign

/// Tests for the library's domain values: record construction, artifact
/// references, fingerprints, availability, and identifiers.
final class ApplicationRecordTests: XCTestCase {

    // MARK: - Admitting an import

    func testAdmittingAnAcceptedArtifactCapturesItsDeclaredMetadata() throws {
        let artifact = LibraryFixtures.acceptedArtifact()
        let reference = LibraryFixtures.reference(artifactID: artifact.id)

        let record = try ApplicationRecord(
            admitting: artifact,
            reference: reference,
            importedAt: LibraryFixtures.importDate
        )

        XCTAssertEqual(record.identity, artifact.metadata?.identity)
        XCTAssertEqual(record.bundleIdentifier.rawValue, "com.example.synthetic")
        XCTAssertEqual(record.displayName, "Example")
        XCTAssertEqual(record.executableName, "Example")
        XCTAssertEqual(record.sourceFileName, "Example.ipa")
        XCTAssertEqual(record.artifact, reference)
        XCTAssertEqual(record.inspection.classification, .valid)
        XCTAssertTrue(record.inspection.warningCodes.isEmpty)
        XCTAssertEqual(record.importedAt, LibraryFixtures.importDate)
        XCTAssertEqual(record.updatedAt, LibraryFixtures.importDate)
    }

    func testAdmittingKeepsWarningCodesButNotTheirDetails() throws {
        let artifact = LibraryFixtures.acceptedArtifact(
            validation: .validWithWarnings(findings: [
                ValidationFinding(severity: .warning, code: .inconsistentMetadata, detail: "synthetic detail"),
            ])
        )

        let record = try ApplicationRecord(
            admitting: artifact,
            reference: LibraryFixtures.reference(artifactID: artifact.id),
            importedAt: LibraryFixtures.importDate
        )

        XCTAssertEqual(record.inspection.classification, .valid)
        XCTAssertEqual(record.inspection.warningCodes, [.inconsistentMetadata])
    }

    func testAdmittingUsesTheSuppliedIdentifierWhenGivenOne() throws {
        let id = ApplicationRecordIdentifier()
        let artifact = LibraryFixtures.acceptedArtifact()

        let record = try ApplicationRecord(
            admitting: artifact,
            reference: LibraryFixtures.reference(artifactID: artifact.id),
            importedAt: LibraryFixtures.importDate,
            id: id
        )

        XCTAssertEqual(record.id, id)
    }

    func testAdmittingARejectedArtifactFails() {
        let artifact = LibraryFixtures.rejectedArtifact()

        XCTAssertThrowsError(try ApplicationRecord(
            admitting: artifact,
            reference: LibraryFixtures.reference(artifactID: artifact.id),
            importedAt: LibraryFixtures.importDate
        )) { error in
            XCTAssertEqual((error as? ZynSignError)?.category, .internalFailure)
            XCTAssertEqual((error as? ZynSignError)?.userMessage, ZynSignError.unrecordableArtifact().userMessage)
        }
    }

    func testAdmittingAnUnexaminedArtifactFails() {
        let artifact = IPAArtifact(sourceFileName: "Example.ipa")

        XCTAssertThrowsError(try ApplicationRecord(
            admitting: artifact,
            reference: LibraryFixtures.reference(artifactID: artifact.id),
            importedAt: LibraryFixtures.importDate
        ))
    }

    func testAdmittingAnArtifactWithoutMetadataFails() {
        let artifact = IPAArtifact(sourceFileName: "Example.ipa").examined(bundle: nil, validation: .valid())

        XCTAssertThrowsError(try ApplicationRecord(
            admitting: artifact,
            reference: LibraryFixtures.reference(artifactID: artifact.id),
            importedAt: LibraryFixtures.importDate
        ))
    }

    func testAdmittingWithAReferenceToAnotherArtifactFails() {
        let artifact = LibraryFixtures.acceptedArtifact()

        XCTAssertThrowsError(try ApplicationRecord(
            admitting: artifact,
            reference: LibraryFixtures.reference(artifactID: ArtifactIdentifier()),
            importedAt: LibraryFixtures.importDate
        ))
    }

    // MARK: - Ordering

    func testLibraryOrderSortsByImportTimeThenIdentifier() {
        let early = LibraryFixtures.record(importedAt: LibraryFixtures.importDate)
        let late = LibraryFixtures.record(importedAt: LibraryFixtures.laterDate)
        let lowID = ApplicationRecordIdentifier(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let highID = ApplicationRecordIdentifier(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let tieLow = LibraryFixtures.record(id: lowID, importedAt: LibraryFixtures.importDate)
        let tieHigh = LibraryFixtures.record(id: highID, importedAt: LibraryFixtures.importDate)

        XCTAssertTrue(ApplicationRecord.libraryOrder(early, late))
        XCTAssertFalse(ApplicationRecord.libraryOrder(late, early))
        XCTAssertTrue(ApplicationRecord.libraryOrder(tieLow, tieHigh))
        XCTAssertFalse(ApplicationRecord.libraryOrder(tieHigh, tieLow))
        XCTAssertFalse(ApplicationRecord.libraryOrder(tieLow, tieLow))

        let sorted = [late, tieHigh, tieLow].sorted(by: ApplicationRecord.libraryOrder)
        XCTAssertEqual(sorted.map { $0.id }, [tieLow.id, tieHigh.id, late.id])
    }

    // MARK: - Artifact references

    func testReferenceClampsNegativeByteCounts() {
        let reference = ArtifactReference(
            artifactID: ArtifactIdentifier(),
            byteCount: -5,
            fingerprint: LibraryFixtures.fingerprint(seed: 0x01)
        )
        XCTAssertEqual(reference.byteCount, 0)
    }

    func testReferencesDescribeTheSameContentByFingerprintAndSizeOnly() {
        let a = LibraryFixtures.reference(byteCount: 10, fingerprintSeed: 0x11)
        let sameContentOtherID = LibraryFixtures.reference(byteCount: 10, fingerprintSeed: 0x11)
        let otherSize = LibraryFixtures.reference(byteCount: 11, fingerprintSeed: 0x11)
        let otherDigest = LibraryFixtures.reference(byteCount: 10, fingerprintSeed: 0x12)

        XCTAssertNotEqual(a.artifactID, sameContentOtherID.artifactID)
        XCTAssertTrue(a.describesSameContent(as: sameContentOtherID))
        XCTAssertFalse(a.describesSameContent(as: otherSize))
        XCTAssertFalse(a.describesSameContent(as: otherDigest))
    }

    // MARK: - Fingerprints

    func testFingerprintAcceptsOnlyCompleteHexadecimalDigests() {
        let digest = String(repeating: "ab", count: 32)

        XCTAssertNotNil(ArtifactFingerprint(algorithm: .sha256, hexDigest: digest))
        XCTAssertNil(ArtifactFingerprint(algorithm: .sha256, hexDigest: String(digest.dropLast())))
        XCTAssertNil(ArtifactFingerprint(algorithm: .sha256, hexDigest: digest + "0"))
        XCTAssertNil(ArtifactFingerprint(algorithm: .sha256, hexDigest: String(repeating: "zz", count: 32)))
        XCTAssertNil(ArtifactFingerprint(algorithm: .sha256, hexDigest: ""))
    }

    func testFingerprintNormalisesUppercaseDigests() {
        let lower = ArtifactFingerprint(algorithm: .sha256, hexDigest: String(repeating: "ab", count: 32))
        let upper = ArtifactFingerprint(algorithm: .sha256, hexDigest: String(repeating: "AB", count: 32))

        XCTAssertEqual(lower, upper)
        XCTAssertEqual(upper?.hexDigest, String(repeating: "ab", count: 32))
    }

    func testFingerprintFromBytesRequiresTheAlgorithmsDigestLength() {
        XCTAssertNotNil(ArtifactFingerprint(algorithm: .sha256, digestBytes: Array(repeating: 0, count: 32)))
        XCTAssertNil(ArtifactFingerprint(algorithm: .sha256, digestBytes: Array(repeating: 0, count: 31)))
        XCTAssertNil(ArtifactFingerprint(algorithm: .sha256, digestBytes: []))
    }

    func testFingerprintFromBytesRendersLowercaseHexadecimal() throws {
        var bytes = Array(repeating: UInt8(0), count: 32)
        bytes[0] = 0x0F
        bytes[1] = 0xF0
        bytes[31] = 0xFF

        let fingerprint = try XCTUnwrap(ArtifactFingerprint(algorithm: .sha256, digestBytes: bytes))

        XCTAssertTrue(fingerprint.hexDigest.hasPrefix("0ff0"))
        XCTAssertTrue(fingerprint.hexDigest.hasSuffix("ff"))
        XCTAssertEqual(fingerprint.hexDigest.count, 64)
        XCTAssertEqual(fingerprint.description, "sha256:\(fingerprint.hexDigest)")
        XCTAssertEqual(
            fingerprint,
            ArtifactFingerprint(algorithm: .sha256, hexDigest: fingerprint.hexDigest)
        )
    }

    func testFingerprintMatchesAnIndependentDigestOfTheSameBytes() {
        let content = Data("abc".utf8)
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

        XCTAssertEqual(LibraryFixtures.fingerprint(of: content).hexDigest, expected)
    }

    // MARK: - Availability

    func testAvailabilityIsDerivedFromWhatStorageHolds() {
        let reference = LibraryFixtures.reference(byteCount: 100)

        XCTAssertEqual(ArtifactAvailability.derive(from: .absent, expecting: reference), .missing)
        XCTAssertEqual(ArtifactAvailability.derive(from: .present(byteCount: 100), expecting: reference), .available)
        XCTAssertEqual(
            ArtifactAvailability.derive(from: .present(byteCount: 60), expecting: reference),
            .inconsistent(recordedByteCount: 100, observedByteCount: 60)
        )

        XCTAssertTrue(ArtifactAvailability.available.isAvailable)
        XCTAssertFalse(ArtifactAvailability.missing.isAvailable)
        XCTAssertFalse(ArtifactAvailability.inconsistent(recordedByteCount: 1, observedByteCount: 2).isAvailable)
    }

    // MARK: - Identifiers

    func testRecordIdentifierRoundTripsThroughItsRawValue() throws {
        let identifier = ApplicationRecordIdentifier()

        let rehydrated = try XCTUnwrap(ApplicationRecordIdentifier(rawValue: identifier.rawValue))

        XCTAssertEqual(rehydrated, identifier)
        XCTAssertEqual(rehydrated.description, identifier.rawValue)
        XCTAssertNil(ApplicationRecordIdentifier(rawValue: "not-an-identifier"))
        XCTAssertNotEqual(ApplicationRecordIdentifier(), ApplicationRecordIdentifier())
    }

    // MARK: - Value semantics

    func testRecordsAreEquatableAndHashableByValue() {
        let id = ApplicationRecordIdentifier()
        let reference = LibraryFixtures.reference()
        let a = LibraryFixtures.record(id: id, artifact: reference)
        let b = LibraryFixtures.record(id: id, artifact: reference)
        let revised = LibraryFixtures.record(id: id, artifact: reference, updatedAt: LibraryFixtures.laterDate)

        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertNotEqual(a, revised)
        XCTAssertEqual(Set([a, b, revised]).count, 2)
    }
}
