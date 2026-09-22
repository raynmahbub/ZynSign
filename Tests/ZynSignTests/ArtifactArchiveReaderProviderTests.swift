import XCTest
@testable import ZynSign

/// Tests for the concrete archive-access boundary the composition root selects.
final class ArtifactArchiveReaderProviderTests: XCTestCase {

    private var temporaryDirectory: URL!
    private var openedReaders: [any ArchiveReader] = []

    override func setUp() {
        super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zynsign-provider-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        openedReaders.forEach { $0.close() }
        openedReaders = []
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
        super.tearDown()
    }

    private func identifier(_ rawValue: String = "6B3FD418-6C5E-4E2A-9B1A-2C3D4E5F6071") throws -> ArtifactIdentifier {
        try XCTUnwrap(ArtifactIdentifier(rawValue: rawValue))
    }

    private func storeFixture(named fileName: String, entries: [ZipFixtureBuilder.Entry]) throws {
        let location = temporaryDirectory.appendingPathComponent(fileName, isDirectory: false)
        try Data(ZipFixtureBuilder.archive(entries)).write(to: location)
    }

    func testProviderOpensTheArchiveStoredForAnArtifact() throws {
        let artifact = try identifier()
        try storeFixture(named: "\(artifact.rawValue).ipa", entries: ZipFixtureBuilder.validPackage())

        let provider = DirectoryArtifactArchiveReaderProvider(directory: temporaryDirectory)
        let reader = try provider.archiveReader(for: artifact)
        openedReaders.append(reader)

        let table = try reader.readEntryTable()
        XCTAssertEqual(table.count, ZipFixtureBuilder.validPackage().count)
    }

    func testProviderReportsAnArtifactWithNoStoredArchive() throws {
        let provider = DirectoryArtifactArchiveReaderProvider(directory: temporaryDirectory)
        var captured: (any Error)?
        do {
            _ = try provider.archiveReader(for: try identifier())
        } catch {
            captured = error
        }
        let error = try XCTUnwrap(captured, "Expected the provider to report the missing archive.")
        let zynSignError = try XCTUnwrap(error as? ZynSignError)
        XCTAssertEqual(zynSignError.category, .storageFailure)
    }

    func testProviderRefusesADirectoryNamedLikeAnArchive() throws {
        let artifact = try identifier()
        let location = temporaryDirectory
            .appendingPathComponent(artifact.rawValue, isDirectory: false)
            .appendingPathExtension("ipa")
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)

        let provider = DirectoryArtifactArchiveReaderProvider(directory: temporaryDirectory)
        XCTAssertThrowsError(try provider.archiveReader(for: artifact))
    }

    func testProviderUsesTheConfiguredFileExtension() throws {
        let artifact = try identifier()
        try storeFixture(named: "\(artifact.rawValue).zip", entries: ZipFixtureBuilder.validPackage())

        let provider = DirectoryArtifactArchiveReaderProvider(
            directory: temporaryDirectory,
            fileExtension: "zip"
        )
        let reader = try provider.archiveReader(for: artifact)
        openedReaders.append(reader)
        XCTAssertFalse(try reader.readEntryTable().isEmpty)
    }

    /// End-to-end exercise of the composition root's selection: an artifact
    /// identifier, the directory convention, the ZIP reader, the structural
    /// validator, and the examined artifact.
    func testCompositionRootSelectionInspectsAStoredPackage() throws {
        let artifact = IPAArtifact(id: try identifier(), sourceFileName: "Example.ipa")
        try storeFixture(named: "\(artifact.id.rawValue).ipa", entries: ZipFixtureBuilder.validPackage())

        let inspection = CompositionRoot.makeArchiveInspection(artifactDirectory: temporaryDirectory)
        let examined = inspection.inspect(artifact)

        XCTAssertEqual(examined.state, .inspected)
        XCTAssertEqual(examined.discoveredBundle?.bundlePath.rawValue, "Payload/Example.app")
        XCTAssertEqual(examined.validation?.classification, .valid)
    }

    func testCompositionRootSelectionReportsAPackageThatIsNotAContainer() throws {
        let artifact = IPAArtifact(id: try identifier(), sourceFileName: "Example.ipa")
        let location = temporaryDirectory
            .appendingPathComponent("\(artifact.id.rawValue).ipa", isDirectory: false)
        try Data(ZipFixtureBuilder.notAnArchive()).write(to: location)

        let inspection = CompositionRoot.makeArchiveInspection(artifactDirectory: temporaryDirectory)
        let examined = inspection.inspect(artifact)

        XCTAssertEqual(examined.state, .invalid)
        XCTAssertEqual(examined.validation?.errors.first?.code, .unreadableArchive)
    }

    func testCompositionRootSelectionReportsAMissingPackage() throws {
        let artifact = IPAArtifact(id: try identifier(), sourceFileName: "Example.ipa")
        let inspection = CompositionRoot.makeArchiveInspection(artifactDirectory: temporaryDirectory)
        let examined = inspection.inspect(artifact)

        XCTAssertEqual(examined.state, .invalid)
        XCTAssertEqual(examined.validation?.errors.first?.code, .unreadableArchive)
    }
}
