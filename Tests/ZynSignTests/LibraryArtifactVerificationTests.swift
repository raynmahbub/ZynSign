import XCTest
@testable import ZynSign

/// Tests for verifying a library package on request: the held file is read
/// again in full and compared, by size and content fingerprint, with what
/// was recorded at import. Nothing is repaired or rewritten.
final class LibraryArtifactVerificationTests: XCTestCase {

    private var records: InMemoryApplicationRecordStore!
    private var artifacts: SyntheticLibraryArtifactStore!
    private var library: ApplicationLibrary!

    override func setUp() {
        super.setUp()
        records = InMemoryApplicationRecordStore()
        artifacts = SyntheticLibraryArtifactStore()
        library = ApplicationLibrary(records: records, artifacts: artifacts)
    }

    override func tearDown() {
        library = nil
        artifacts = nil
        records = nil
        super.tearDown()
    }

    /// Inserts a record describing `content` exactly and holds `content`.
    private func holdRecord(for content: Data) async throws -> ApplicationRecord {
        let record = LibraryFixtures.record(artifact: LibraryFixtures.reference(to: content))
        try await records.insert(record)
        artifacts.hold(content, as: record.artifact.artifactID)
        return record
    }

    func testAnUnchangedPackageIsIntact() async throws {
        let record = try await holdRecord(for: Data("synthetic package bytes".utf8))

        let integrity = try await library.verifyArtifact(recordWithID: record.id)

        XCTAssertEqual(integrity, .intact)
        XCTAssertTrue(integrity.isIntact)
    }

    func testChangedBytesOfTheSameSizeAreCaught() async throws {
        let original = Data("synthetic package bytes".utf8)
        let record = try await holdRecord(for: original)
        var tampered = original
        tampered[0] = tampered[0] ^ 0xFF
        artifacts.replaceHeldContent(record.artifact.artifactID, with: tampered)

        let integrity = try await library.verifyArtifact(recordWithID: record.id)

        // Availability compares sizes only and would call this file
        // available; verification compares the fingerprint too.
        XCTAssertEqual(integrity, .modified(recordedByteCount: original.count, observedByteCount: original.count))
        let entry = try await library.entry(withID: record.id)
        XCTAssertEqual(entry?.artifactAvailability, .available)
    }

    func testATruncatedPackageIsModified() async throws {
        let original = Data(repeating: 0x5A, count: 64)
        let record = try await holdRecord(for: original)
        artifacts.truncate(record.artifact.artifactID, to: 10)

        let integrity = try await library.verifyArtifact(recordWithID: record.id)

        XCTAssertEqual(integrity, .modified(recordedByteCount: 64, observedByteCount: 10))
    }

    func testAMissingPackageIsReportedNotRecreated() async throws {
        let record = try await holdRecord(for: Data("bytes".utf8))
        artifacts.drop(record.artifact.artifactID)

        let integrity = try await library.verifyArtifact(recordWithID: record.id)

        XCTAssertEqual(integrity, .missing)
        XCTAssertTrue(artifacts.held.isEmpty, "Verification must never recreate a file.")
    }

    func testVerifyingAnUnknownRecordFailsWithATypedError() async {
        do {
            _ = try await library.verifyArtifact(recordWithID: ApplicationRecordIdentifier())
            XCTFail("An unknown record must be reported.")
        } catch {
            XCTAssertEqual((error as? ZynSignError)?.userMessage, "The application is no longer in ZynSign's library.")
        }
    }

    func testAReadFailureIsThrownRatherThanReportedAsChanged() async throws {
        let record = try await holdRecord(for: Data("bytes".utf8))
        artifacts.failMeasuring(with: ZynSignError.libraryStorageFailure(diagnosticDetail: "synthetic read failure"))

        do {
            _ = try await library.verifyArtifact(recordWithID: record.id)
            XCTFail("A read failure must be thrown.")
        } catch {
            XCTAssertEqual((error as? ZynSignError)?.category, .storageFailure)
        }
    }

    // MARK: - Platform store

    func testTheFileStoreMeasuresAHeldArtifactExactlyAsImportDescribedIt() throws {
        let root = try LibraryFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("Staging", isDirectory: true)
        let libraryDirectory = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let store = FileLibraryArtifactStore(stagingDirectory: staging, libraryDirectory: libraryDirectory, readChunkSize: 7)
        let artifact = ArtifactIdentifier()
        let content = Data((0..<1_000).map { UInt8($0 % 251) })
        try content.write(to: staging.appendingPathComponent(artifact.rawValue).appendingPathExtension("ipa"))

        let described = try store.describeStagedArtifact(artifact)
        try store.adoptStagedArtifact(artifact)
        let measured = try store.measureHeldArtifact(artifact)

        XCTAssertEqual(measured, described)
        XCTAssertEqual(measured, LibraryFixtures.reference(to: content, artifactID: artifact))
        XCTAssertNil(try store.measureHeldArtifact(ArtifactIdentifier()), "Nothing held measures as nothing.")
    }
}
