import XCTest
@testable import ZynSign

/// A failure type standing in for an arbitrary platform error whose rendering
/// carries a filesystem location. ZynSign must not copy such text into a
/// finding.
private struct ForeignStorageError: Error, CustomStringConvertible {
    var description: String { "cannot open /Users/someone/private/Example.ipa" }
}

final class IPAArchiveInspectionTests: XCTestCase {

    private func artifact() -> IPAArtifact {
        IPAArtifact(
            id: ArtifactIdentifier(uuid: UUID(uuidString: "6B3FD418-6C5E-4E2A-9B1A-2C3D4E5F6071")!),
            sourceFileName: "Example.ipa"
        )
    }

    private func inspection(over reader: any ArchiveReader) -> IPAArchiveInspection {
        IPAArchiveInspection(readerProvider: SyntheticArchiveReaderProvider.providing(reader))
    }

    func testInspectionOfValidPackageProducesExaminedArtifact() {
        let reader = SyntheticArchiveReader(entryTable: validPackageEntryTable())
        let examined = inspection(over: reader).inspect(artifact())

        XCTAssertEqual(examined.state, .inspected)
        XCTAssertEqual(examined.validation?.classification, .valid)
        XCTAssertEqual(examined.discoveredBundle?.bundlePath.rawValue, "Payload/Example.app")
        XCTAssertTrue(examined.permitsLaterStages)
        XCTAssertEqual(examined.sourceFileName, "Example.ipa")
    }

    func testInspectionOfBrokenPackageProducesInvalidArtifact() {
        let reader = SyntheticArchiveReader(entryTable: [makeEntry("Payload", kind: .directory)])
        let examined = inspection(over: reader).inspect(artifact())

        XCTAssertEqual(examined.state, .invalid)
        XCTAssertEqual(examined.validation?.classification, .invalid)
        XCTAssertNil(examined.discoveredBundle)
        XCTAssertFalse(examined.permitsLaterStages)
    }

    func testInspectionOfAmbiguousPackageDoesNotChooseABundle() {
        let reader = SyntheticArchiveReader(entryTable: [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/First.app", kind: .directory),
            makeEntry("Payload/First.app/Info.plist"),
            makeEntry("Payload/Second.app", kind: .directory),
            makeEntry("Payload/Second.app/Info.plist"),
        ])
        let examined = inspection(over: reader).inspect(artifact())

        XCTAssertEqual(examined.validation?.classification, .ambiguous)
        XCTAssertNil(examined.discoveredBundle)
        XCTAssertFalse(examined.permitsLaterStages)
    }

    func testProviderFailureIsRecordedAsAnExaminedArtifact() {
        let inspection = IPAArchiveInspection(
            readerProvider: SyntheticArchiveReaderProvider.failing(
                with: ZynSignError.artifactNotAvailable(diagnosticDetail: "no archive held")
            )
        )
        let examined = inspection.inspect(artifact())

        XCTAssertEqual(examined.state, .invalid)
        XCTAssertEqual(examined.validation?.errors.first?.code, .unreadableArchive)
        XCTAssertNil(examined.discoveredBundle)
    }

    func testUnenumerableContainerIsRecordedAsAnExaminedArtifact() {
        let reader = SyntheticArchiveReader(
            entryTable: validPackageEntryTable(),
            failure: .entryTableUnreadable
        )
        let examined = inspection(over: reader).inspect(artifact())

        XCTAssertEqual(examined.state, .invalid)
        XCTAssertEqual(examined.validation?.errors.first?.code, .unreadableArchive)
        XCTAssertEqual(reader.closeCount, 1)
    }

    func testReaderIsClosedExactlyOnceOnSuccess() {
        let reader = SyntheticArchiveReader(entryTable: validPackageEntryTable())
        _ = inspection(over: reader).inspect(artifact())
        XCTAssertEqual(reader.closeCount, 1)
    }

    func testInspectionReadsNoEntryContent() {
        let reader = SyntheticArchiveReader(entryTable: validPackageEntryTable())
        _ = inspection(over: reader).inspect(artifact())
        XCTAssertTrue(reader.requestedPaths.isEmpty)
    }

    func testForeignFailureDetailIsNotCopiedIntoFindings() {
        let inspection = IPAArchiveInspection(
            readerProvider: SyntheticArchiveReaderProvider.failing(with: ForeignStorageError())
        )
        let examined = inspection.inspect(artifact())
        let detail = examined.validation?.errors.first?.detail ?? ""

        XCTAssertFalse(detail.contains("/Users/someone/private"))
        XCTAssertTrue(detail.contains("ForeignStorageError"))
    }

    func testZynSignFailureDetailIsPreserved() {
        let inspection = IPAArchiveInspection(
            readerProvider: SyntheticArchiveReaderProvider.failing(
                with: ZynSignError.unreadableArtifact(diagnosticDetail: "synthetic container failure")
            )
        )
        let examined = inspection.inspect(artifact())
        let detail = examined.validation?.errors.first?.detail ?? ""

        XCTAssertTrue(detail.contains("could not read"))
    }
}
