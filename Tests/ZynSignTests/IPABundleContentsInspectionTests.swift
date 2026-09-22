import XCTest
@testable import ZynSign

/// Tests for the bundle contents inspection use case.
///
/// The use case is exercised over the real library use case with in-memory
/// stores and a synthetic archive boundary, so that every outcome — a
/// described bundle, a record that is gone, a package the library no longer
/// holds or no longer vouches for, a container that cannot be read, a
/// package with no single bundle — is the outcome the application layer
/// actually produces. One test reads a synthetic container through the
/// platform boundary the composition root selects. Every package is built
/// from literal names; no real application appears anywhere.
final class IPABundleContentsInspectionTests: XCTestCase {

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

    // MARK: - Helpers

    /// Records an application whose artifact the synthetic store holds, so
    /// the library reports it available.
    @discardableResult
    private func recordAvailableApplication(executableName: String? = "Example") async throws -> ApplicationRecord {
        let content = Data(repeating: 0x5A, count: 2_048)
        let artifactID = ArtifactIdentifier()
        artifacts.hold(content, as: artifactID)
        let record = LibraryFixtures.record(
            executableName: executableName,
            artifact: LibraryFixtures.reference(to: content, artifactID: artifactID)
        )
        try await records.insert(record)
        return record
    }

    private func inspection(reading reader: any ArchiveReader) -> IPABundleContentsInspection {
        IPABundleContentsInspection(library: library, readerProvider: SyntheticArchiveReaderProvider.providing(reader))
    }

    private func inspection(with provider: any ArtifactArchiveReaderProvider) -> IPABundleContentsInspection {
        IPABundleContentsInspection(library: library, readerProvider: provider)
    }

    private func capturedError(
        _ operation: () async throws -> BundleContents,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> any Error {
        do {
            _ = try await operation()
        } catch {
            return error
        }
        XCTFail("Expected inspection to fail.", file: file, line: line)
        throw NoErrorCaptured()
    }

    private struct NoErrorCaptured: Error {}

    private func path(_ rawValue: String) throws -> BundlePath {
        try XCTUnwrap(BundlePath(rawValue: rawValue))
    }

    // MARK: - Success

    func testDescribesTheBundleOfAnAvailableRecord() async throws {
        let record = try await recordAvailableApplication()
        let reader = SyntheticArchiveReader(entryTable: [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
            makeEntry("Payload/Example.app/Info.plist", uncompressedSize: 640, compressedSize: 300),
            makeEntry("Payload/Example.app/Example", uncompressedSize: 8_192, compressedSize: 4_000),
            makeEntry("Payload/Example.app/Frameworks/Core.framework/Core", uncompressedSize: 2_048),
            makeEntry("Payload/Example.app/_CodeSignature/CodeResources", uncompressedSize: 128),
            makeEntry("iTunesMetadata.plist", uncompressedSize: 50),
        ])

        let contents = try await inspection(reading: reader).inspect(recordWithID: record.id)

        XCTAssertEqual(contents.bundleName, "Example.app")
        XCTAssertEqual(contents.entryCount, 7)
        XCTAssertEqual(contents.rootEntries.map(\.name), ["Frameworks", "_CodeSignature", "Example", "Info.plist"])
        XCTAssertEqual(contents.entry(at: try path("Example"))?.role, .executable)
        XCTAssertEqual(contents.entry(at: try path("Example"))?.declaredByteCount, 8_192)
        XCTAssertEqual(contents.entries(in: try path("Frameworks/Core.framework"))?.map(\.name), ["Core"])
        XCTAssertEqual(contents.totalDeclaredByteCount, 640 + 8_192 + 2_048 + 128)
        XCTAssertEqual(reader.closeCount, 1)
        XCTAssertTrue(reader.requestedPaths.isEmpty)
    }

    func testEnumerationReadsNoEntryContentHoweverLargeTheFiles() async throws {
        let record = try await recordAvailableApplication()
        let reader = SyntheticArchiveReader(entryTable: [
            makeEntry("Payload/Example.app/Info.plist", uncompressedSize: 1_024),
            makeEntry("Payload/Example.app/Example", uncompressedSize: 3_221_225_472),
            makeEntry("Payload/Example.app/Assets.car", uncompressedSize: 6_442_450_944),
        ])

        let contents = try await inspection(reading: reader).inspect(recordWithID: record.id)

        XCTAssertEqual(contents.entry(at: try path("Example"))?.declaredByteCount, 3_221_225_472)
        XCTAssertEqual(contents.entry(at: try path("Assets.car"))?.declaredByteCount, 6_442_450_944)
        XCTAssertTrue(reader.requestedPaths.isEmpty, "Enumeration must never read entry content.")
        XCTAssertEqual(reader.closeCount, 1)
    }

    func testTheExecutableLabelFollowsTheRecordsDeclaredName() async throws {
        let table = [
            makeEntry("Payload/Example.app/Info.plist", uncompressedSize: 1),
            makeEntry("Payload/Example.app/Example", uncompressedSize: 1),
            makeEntry("Payload/Example.app/Other", uncompressedSize: 1),
        ]
        let declared = try await recordAvailableApplication(executableName: "Other")
        let undeclared = try await recordAvailableApplication(executableName: nil)

        let declaredContents = try await inspection(reading: SyntheticArchiveReader(entryTable: table))
            .inspect(recordWithID: declared.id)
        XCTAssertEqual(declaredContents.entry(at: try path("Other"))?.role, .executable)
        XCTAssertNil(declaredContents.entry(at: try path("Example"))?.role)

        let undeclaredContents = try await inspection(reading: SyntheticArchiveReader(entryTable: table))
            .inspect(recordWithID: undeclared.id)
        XCTAssertNil(undeclaredContents.entry(at: try path("Other"))?.role)
        XCTAssertNil(undeclaredContents.entry(at: try path("Example"))?.role)
    }

    func testAnEmptyBundleIsDescribedAsEmpty() async throws {
        let record = try await recordAvailableApplication()
        let reader = SyntheticArchiveReader(entryTable: [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
        ])

        let contents = try await inspection(reading: reader).inspect(recordWithID: record.id)

        XCTAssertTrue(contents.isEmpty)
        XCTAssertEqual(contents.bundleName, "Example.app")
        XCTAssertEqual(reader.closeCount, 1)
    }

    // MARK: - Record and artifact failures

    func testAMissingRecordIsReportedWithoutOpeningAnyPackage() async throws {
        let reader = SyntheticArchiveReader(entryTable: validPackageEntryTable())

        let error = try await capturedError {
            try await self.inspection(reading: reader).inspect(recordWithID: ApplicationRecordIdentifier())
        }

        let zynSignError = try XCTUnwrap(error as? ZynSignError)
        XCTAssertEqual(zynSignError.userMessage, ZynSignError.libraryRecordNotFound().userMessage)
        XCTAssertEqual(zynSignError.category, .storageFailure)
        XCTAssertEqual(reader.closeCount, 0)
    }

    func testAMissingArtifactIsReportedWithoutOpeningAnyPackage() async throws {
        let record = try await recordAvailableApplication()
        artifacts.drop(record.artifact.artifactID)
        let reader = SyntheticArchiveReader(entryTable: validPackageEntryTable())

        let error = try await capturedError {
            try await self.inspection(reading: reader).inspect(recordWithID: record.id)
        }

        let zynSignError = try XCTUnwrap(error as? ZynSignError)
        XCTAssertEqual(zynSignError.userMessage, ZynSignError.bundleArtifactMissing().userMessage)
        XCTAssertEqual(zynSignError.category, .storageFailure)
        XCTAssertEqual(reader.closeCount, 0)
    }

    func testAnInconsistentArtifactIsReportedWithoutOpeningAnyPackage() async throws {
        let record = try await recordAvailableApplication()
        artifacts.truncate(record.artifact.artifactID, to: 16)
        let reader = SyntheticArchiveReader(entryTable: validPackageEntryTable())

        let error = try await capturedError {
            try await self.inspection(reading: reader).inspect(recordWithID: record.id)
        }

        let zynSignError = try XCTUnwrap(error as? ZynSignError)
        XCTAssertEqual(zynSignError.userMessage, ZynSignError.bundleArtifactInconsistent().userMessage)
        XCTAssertEqual(reader.closeCount, 0)
    }

    // MARK: - Container failures

    func testATypedFailureToOpenThePackagePassesThrough() async throws {
        let record = try await recordAvailableApplication()
        let provider = SyntheticArchiveReaderProvider.failing(
            with: ZynSignError.artifactNotAvailable(diagnosticDetail: "synthetic missing file")
        )

        let error = try await capturedError {
            try await self.inspection(with: provider).inspect(recordWithID: record.id)
        }

        let zynSignError = try XCTUnwrap(error as? ZynSignError)
        XCTAssertEqual(zynSignError.userMessage, ZynSignError.artifactNotAvailable().userMessage)
        XCTAssertFalse(zynSignError.userMessage.contains("synthetic"))
    }

    func testAForeignFailureIsNormalisedIntoATypedError() async throws {
        let record = try await recordAvailableApplication()
        let cause = NSError(domain: "com.zynsign.synthetic.tests", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "synthetic platform failure at /private/var/some/location",
        ])
        let provider = SyntheticArchiveReaderProvider.failing(with: cause)

        let error = try await capturedError {
            try await self.inspection(with: provider).inspect(recordWithID: record.id)
        }

        let zynSignError = try XCTUnwrap(error as? ZynSignError)
        XCTAssertEqual(zynSignError.category, .internalFailure)
        XCTAssertEqual(zynSignError.userMessage, ZynSignError.bundleInspectionFailure().userMessage)
        XCTAssertFalse(zynSignError.userMessage.contains("/private"))
        XCTAssertNotNil(zynSignError.underlyingError)
    }

    func testAnUnreadableEntryTableIsReportedAndTheReaderClosed() async throws {
        let record = try await recordAvailableApplication()
        let reader = SyntheticArchiveReader(entryTable: [], failure: .entryTableUnreadable)

        let error = try await capturedError {
            try await self.inspection(reading: reader).inspect(recordWithID: record.id)
        }

        let zynSignError = try XCTUnwrap(error as? ZynSignError)
        XCTAssertEqual(zynSignError.userMessage, ZynSignError.unreadableArtifact().userMessage)
        XCTAssertEqual(reader.closeCount, 1)
    }

    func testAPackageWithoutAnApplicationBundleIsReported() async throws {
        let record = try await recordAvailableApplication()
        for table in [
            [makeEntry("Payload", kind: .directory), makeEntry("Payload/README.txt")],
            [makeEntry("Example.app/Info.plist")],
            [ArchiveEntry](),
        ] {
            let reader = SyntheticArchiveReader(entryTable: table)
            let error = try await capturedError {
                try await self.inspection(reading: reader).inspect(recordWithID: record.id)
            }
            let zynSignError = try XCTUnwrap(error as? ZynSignError)
            XCTAssertEqual(zynSignError.userMessage, ZynSignError.missingApplicationBundle().userMessage)
            XCTAssertEqual(zynSignError.category, .invalidInput)
            XCTAssertEqual(reader.closeCount, 1)
        }
    }

    func testAPackageWithSeveralApplicationBundlesIsReported() async throws {
        let record = try await recordAvailableApplication()
        let reader = SyntheticArchiveReader(entryTable: [
            makeEntry("Payload/Example.app/Info.plist"),
            makeEntry("Payload/Other.app/Info.plist"),
        ])

        let error = try await capturedError {
            try await self.inspection(reading: reader).inspect(recordWithID: record.id)
        }

        let zynSignError = try XCTUnwrap(error as? ZynSignError)
        XCTAssertEqual(zynSignError.userMessage, ZynSignError.ambiguousArtifact().userMessage)
        XCTAssertEqual(zynSignError.category, .ambiguousInput)
        XCTAssertEqual(reader.closeCount, 1)
    }

    // MARK: - Cancellation

    func testCancellationIsHonouredBeforeThePackageIsOpened() async throws {
        let record = try await recordAvailableApplication()
        let reader = SyntheticArchiveReader(entryTable: validPackageEntryTable())
        let useCase = inspection(reading: reader)

        let task = Task<BundleContents, any Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await useCase.inspect(recordWithID: record.id)
        }

        do {
            _ = try await task.value
            XCTFail("Expected the cancelled inspection to throw.")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
        XCTAssertEqual(reader.closeCount, 0)
    }

    // MARK: - Platform boundary

    func testReadsASyntheticContainerThroughThePlatformBoundary() async throws {
        let directory = try LibraryFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifactDirectory = directory.appendingPathComponent("Artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)

        let longName = String(repeating: "L", count: 120) + ".dat"
        let container = Data(ZipFixtureBuilder.archive([
            .directory("Payload"),
            .directory("Payload/Example.app"),
            ZipFixtureBuilder.Entry(name: "Payload/Example.app/Info.plist", content: ZipFixtureBuilder.syntheticPlist),
            ZipFixtureBuilder.Entry(name: "Payload/Example.app/Example", content: Array(repeating: 0x90, count: 4_096), deflate: true),
            ZipFixtureBuilder.Entry(name: "Payload/Example.app/Frameworks/Core.framework/Core", content: Array(repeating: 0x01, count: 512)),
            ZipFixtureBuilder.Entry(name: "Payload/Example.app/Base Name.lproj/Ünïcødé 名前.strings", content: [0x41, 0x42]),
            ZipFixtureBuilder.Entry(name: "Payload/Example.app/\(longName)", content: [0x00]),
            .symbolicLink("Payload/Example.app/Frameworks/Current", target: "../Example"),
            .directory("Payload/Example.app/PlugIns"),
            .undecodableName(content: [0x01]),
            ZipFixtureBuilder.Entry(name: "iTunesMetadata.plist", content: [0x02, 0x03]),
        ]))
        let artifactID = ArtifactIdentifier()
        try container.write(to: artifactDirectory.appendingPathComponent("\(artifactID.rawValue).ipa", isDirectory: false))

        let record = LibraryFixtures.record(
            executableName: "Example",
            artifact: LibraryFixtures.reference(to: container, artifactID: artifactID)
        )
        let fileLibrary = ApplicationLibrary(
            records: InMemoryApplicationRecordStore(records: [record]),
            artifacts: FileLibraryArtifactStore(
                stagingDirectory: directory.appendingPathComponent("Staging", isDirectory: true),
                libraryDirectory: artifactDirectory
            )
        )
        let useCase = IPABundleContentsInspection(
            library: fileLibrary,
            readerProvider: DirectoryArtifactArchiveReaderProvider(directory: artifactDirectory)
        )

        let contents = try await useCase.inspect(recordWithID: record.id)

        XCTAssertEqual(contents.bundleName, "Example.app")
        XCTAssertEqual(
            contents.rootEntries.map(\.name),
            ["Base Name.lproj", "Frameworks", "PlugIns", "Example", "Info.plist", longName]
        )
        XCTAssertEqual(contents.entry(at: try path("Info.plist"))?.role, .bundleInformation)
        XCTAssertEqual(contents.entry(at: try path("Info.plist"))?.declaredByteCount, ZipFixtureBuilder.syntheticPlist.count)
        XCTAssertEqual(contents.entry(at: try path("Example"))?.role, .executable)
        XCTAssertEqual(contents.entry(at: try path("Example"))?.declaredByteCount, 4_096)
        XCTAssertEqual(contents.entry(at: try path("Frameworks"))?.role, .frameworksDirectory)
        XCTAssertEqual(contents.entries(in: try path("Frameworks"))?.map(\.name), ["Core.framework", "Current"])
        XCTAssertEqual(contents.entry(at: try path("Frameworks/Current"))?.kind, .symbolicLink)
        XCTAssertNil(contents.entry(at: try path("Frameworks/Current"))?.declaredByteCount)
        XCTAssertNil(contents.entries(in: try path("Frameworks/Current")))
        XCTAssertEqual(contents.entries(in: try path("Frameworks/Core.framework"))?.map(\.name), ["Core"])
        XCTAssertEqual(contents.entries(in: try path("Base Name.lproj"))?.map(\.name), ["Ünïcødé 名前.strings"])
        XCTAssertEqual(contents.entries(in: try path("PlugIns")), [])
        XCTAssertEqual(contents.entry(at: try path(longName))?.declaredByteCount, 1)
        XCTAssertEqual(contents.omittedEntryCount, 1)
        XCTAssertNil(contents.entry(at: try path("iTunesMetadata.plist")))
    }
}
