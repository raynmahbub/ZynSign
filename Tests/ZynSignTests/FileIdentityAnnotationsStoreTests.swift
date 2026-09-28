import XCTest
@testable import ZynSign

/// Tests for the file-backed identity annotation store: round-trips,
/// failure-closed behaviour on damage, schema versioning, and the boundary
/// rules for labels, fingerprints, and the default mark.
final class FileIdentityAnnotationsStoreTests: XCTestCase {

    private var directory: URL!
    private var location: URL!
    private var store: FileIdentityAnnotationsStore!

    /// A valid SHA-256 fingerprint for test keys.
    private static let fingerprintA = "4aea4f8b88d249d4612ec2101efa985d75ab500640372e07ae82aa29c9c8c575"
    private static let fingerprintB = "724a8650f739ed9a6dc45099cbe66b519c8a7c9c99132f99c0917e591d9debb4"

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZynSignAnnotationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        location = directory.appendingPathComponent("catalog.json")
        store = FileIdentityAnnotationsStore(catalogLocation: location)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        location = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Round trips

    func testMissingCatalogReadsAsEmpty() throws {
        XCTAssertEqual(try store.annotations(), [:])
        XCTAssertNil(try store.defaultIdentityFingerprint())
    }

    func testAnnotationRoundTripsThroughADiscardedStoreInstance() throws {
        let importedAt = TestClocks.utc(2026, 10, 1, hour: 12)
        try store.setAnnotation(
            IdentityAnnotation(displayLabel: "Release Key", importedAt: importedAt),
            forFingerprint: Self.fingerprintA
        )
        // A fresh instance re-reads from disk: the annotation must survive
        // the "relaunch", not just the in-memory cache.
        let reread = FileIdentityAnnotationsStore(catalogLocation: location)
        let annotation = try XCTUnwrap(reread.annotations()[Self.fingerprintA])
        XCTAssertEqual(annotation.displayLabel, "Release Key")
        XCTAssertEqual(annotation.importedAt, importedAt)
    }

    func testRemoveAnnotationDeletesTheEntryOnly() throws {
        try store.setAnnotation(
            IdentityAnnotation(displayLabel: "A"),
            forFingerprint: Self.fingerprintA
        )
        try store.setAnnotation(
            IdentityAnnotation(displayLabel: "B"),
            forFingerprint: Self.fingerprintB
        )
        try store.removeAnnotation(forFingerprint: Self.fingerprintA)
        let annotations = try store.annotations()
        XCTAssertNil(annotations[Self.fingerprintA])
        XCTAssertEqual(annotations[Self.fingerprintB]?.displayLabel, "B")
    }

    func testRemoveAMissingAnnotationIsANoOp() throws {
        XCTAssertNoThrow(try store.removeAnnotation(forFingerprint: Self.fingerprintA))
        XCTAssertEqual(try store.annotations(), [:])
    }

    // MARK: - The default mark

    func testDefaultRoundTrips() throws {
        try store.setDefaultIdentityFingerprint(Self.fingerprintA)
        let reread = FileIdentityAnnotationsStore(catalogLocation: location)
        XCTAssertEqual(try reread.defaultIdentityFingerprint(), Self.fingerprintA)
    }

    func testDefaultingAnUnannotatedIdentityRecordsAnEmptyAnnotation() throws {
        try store.setDefaultIdentityFingerprint(Self.fingerprintA)
        let annotation = try store.annotations()[Self.fingerprintA]
        XCTAssertNotNil(annotation)
        XCTAssertTrue(annotation!.isEmpty)
    }

    func testClearingTheDefaultRemovesTheMarkButKeepsAnnotations() throws {
        try store.setAnnotation(IdentityAnnotation(displayLabel: "A"), forFingerprint: Self.fingerprintA)
        try store.setDefaultIdentityFingerprint(Self.fingerprintA)
        try store.setDefaultIdentityFingerprint(nil)
        XCTAssertNil(try store.defaultIdentityFingerprint())
        XCTAssertEqual(try store.annotations()[Self.fingerprintA]?.displayLabel, "A")
    }

    func testADefaultThatNamesNoRecordedAnnotationIsDroppedOnRead() throws {
        // Damage the catalog by hand: a default with no annotation behind it
        // is stale state, and a cold read drops it rather than inventing a
        // default for a ghost.
        let envelope = """
        {
          "schemaVersion": 1,
          "defaultFingerprint": "\(Self.fingerprintA)",
          "annotations": { "\(Self.fingerprintB)": { "displayLabel": "B" } }
        }
        """
        try envelope.data(using: .utf8)!.write(to: location)
        let reread = FileIdentityAnnotationsStore(catalogLocation: location)
        XCTAssertNil(try reread.defaultIdentityFingerprint())
        XCTAssertEqual(try reread.annotations()[Self.fingerprintB]?.displayLabel, "B")
    }

    // MARK: - Boundaries

    func testAnOverlongLabelIsRefusedAtWrite() {
        let overlong = String(repeating: "a", count: IdentityAnnotation.maximumLabelLength + 1)
        XCTAssertThrowsError(
            try store.setAnnotation(
                IdentityAnnotation(displayLabel: overlong),
                forFingerprint: Self.fingerprintA
            )
        )
        XCTAssertEqual(try? store.annotations(), [:])
    }

    func testALabelAtTheBoundaryLengthIsAccepted() throws {
        let boundary = String(repeating: "a", count: IdentityAnnotation.maximumLabelLength)
        XCTAssertNoThrow(
            try store.setAnnotation(
                IdentityAnnotation(displayLabel: boundary),
                forFingerprint: Self.fingerprintA
            )
        )
        XCTAssertEqual(try store.annotations()[Self.fingerprintA]?.displayLabel, boundary)
    }

    func testAValueThatIsNotAFingerprintIsRefusedAtWrite() {
        XCTAssertThrowsError(
            try store.setAnnotation(IdentityAnnotation(displayLabel: "X"), forFingerprint: "not-a-fingerprint")
        )
        XCTAssertThrowsError(try store.setDefaultIdentityFingerprint("not-a-fingerprint"))
        XCTAssertThrowsError(try store.removeAnnotation(forFingerprint: "not-a-fingerprint"))
    }

    // MARK: - Failure closed on damage

    func testACorruptCatalogIsReportedUnreadableAndLeftInPlace() throws {
        try Data("not json at all".utf8).write(to: location)
        XCTAssertThrowsError(try store.annotations()) { error in
            XCTAssertEqual((error as? ZynSignError)?.userMessage,
                           ZynSignError.identityAnnotationsUnreadable().userMessage)
        }
        // The catalog is left untouched for diagnosis.
        XCTAssertEqual(try Data(contentsOf: location), Data("not json at all".utf8))
    }

    func testAnUnsupportedSchemaVersionIsRefused() throws {
        let envelope = """
        { "schemaVersion": 99, "defaultFingerprint": null, "annotations": {} }
        """
        try envelope.data(using: .utf8)!.write(to: location)
        XCTAssertThrowsError(try store.annotations()) { error in
            XCTAssertEqual((error as? ZynSignError)?.userMessage,
                           ZynSignError.identityAnnotationsUnreadable().userMessage)
        }
    }

    func testACatalogRecodingAnOverlongLabelIsUnreadable() throws {
        let overlong = String(repeating: "a", count: IdentityAnnotation.maximumLabelLength + 1)
        let escaped = overlong
        let envelope = """
        {
          "schemaVersion": 1,
          "defaultFingerprint": null,
          "annotations": { "\(Self.fingerprintA)": { "displayLabel": "\(escaped)" } }
        }
        """
        try envelope.data(using: .utf8)!.write(to: location)
        XCTAssertThrowsError(try store.annotations())
    }

    func testACatalogRecodingAnInvalidFingerprintKeyIsUnreadable() throws {
        let envelope = """
        {
          "schemaVersion": 1,
          "defaultFingerprint": null,
          "annotations": { "not-a-fingerprint": { "displayLabel": "A" } }
        }
        """
        try envelope.data(using: .utf8)!.write(to: location)
        XCTAssertThrowsError(try store.annotations())
    }

    func testALocationThatIsADirectoryIsAStorageFailure() throws {
        let directoryLocation = directory.appendingPathComponent("as-a-directory")
        try FileManager.default.createDirectory(at: directoryLocation, withIntermediateDirectories: true)
        let storeAtDirectory = FileIdentityAnnotationsStore(catalogLocation: directoryLocation)
        XCTAssertThrowsError(try storeAtDirectory.annotations()) { error in
            XCTAssertEqual((error as? ZynSignError)?.userMessage,
                           ZynSignError.identityAnnotationsStorageFailure().userMessage)
        }
    }
}
