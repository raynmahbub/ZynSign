import XCTest
@testable import ZynSign

/// Tests for preparing library packages for export: readable, safe, unique
/// file names; the library's own files only ever read; gaps counted rather
/// than papered over; and prepared files discarded afterwards.
final class LibraryExportPreparationTests: XCTestCase {

    private typealias Fixtures = LibraryOrganizationFixtures

    private var root: URL!
    private var artifactDirectory: URL!
    private var preparation: LibraryExportPreparation!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try LibraryFixtures.makeTemporaryDirectory()
        artifactDirectory = root.appendingPathComponent("Artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        let directory: URL = artifactDirectory
        preparation = LibraryExportPreparation(
            exportRoot: root.appendingPathComponent("Exports", isDirectory: true),
            artifactLocation: { artifact in
                directory.appendingPathComponent(artifact.rawValue).appendingPathExtension("ipa")
            }
        )
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        preparation = nil
        artifactDirectory = nil
        root = nil
        try super.tearDownWithError()
    }

    /// Writes the package file an entry refers to.
    private func store(_ content: Data, for entry: LibraryEntry) throws {
        let location = artifactDirectory
            .appendingPathComponent(entry.record.artifact.artifactID.rawValue)
            .appendingPathExtension("ipa")
        try content.write(to: location)
    }

    // MARK: - Names

    func testFileNamesCarryTheNameVersionAndBuild() {
        func name(_ version: String?, _ build: String?) -> String {
            LibraryExportPreparation.exportFileName(for: Fixtures.entry(name: "Delta Mail", version: version, build: build).record)
        }

        XCTAssertEqual(name("2.1", "340"), "Delta Mail 2.1 (340).ipa")
        XCTAssertEqual(name("2.1", "2.1"), "Delta Mail 2.1.ipa")
        XCTAssertEqual(name("2.1", nil), "Delta Mail 2.1.ipa")
        XCTAssertEqual(name(nil, "340"), "Delta Mail (340).ipa")
        XCTAssertEqual(name(nil, nil), "Delta Mail.ipa")
    }

    func testUnnamedApplicationsAreNamedByBundleIdentifier() {
        let record = Fixtures.entry(name: nil, bundleIdentifier: "com.example.anonymous", version: nil, build: nil).record

        XCTAssertEqual(LibraryExportPreparation.exportFileName(for: record), "com.example.anonymous.ipa")
    }

    func testUnsafeCharactersAreReplacedAndTheStemIsBounded() {
        XCTAssertEqual(LibraryExportPreparation.sanitizedStem("../Evil/Name: \"x\"?"), "-Evil-Name- -x--")
        XCTAssertEqual(LibraryExportPreparation.sanitizedStem("...hidden"), "hidden")
        XCTAssertEqual(LibraryExportPreparation.sanitizedStem("   "), "Application")
        let long = String(repeating: "a", count: 300)
        XCTAssertEqual(LibraryExportPreparation.sanitizedStem(long).count, LibraryExportPreparation.maximumStemLength)
    }

    func testNamesAreMadeUniqueIgnoringCase() {
        var used: Set<String> = []

        XCTAssertEqual(LibraryExportPreparation.uniqueName("App.ipa", avoiding: &used), "App.ipa")
        XCTAssertEqual(LibraryExportPreparation.uniqueName("app.ipa", avoiding: &used), "app 2.ipa")
        XCTAssertEqual(LibraryExportPreparation.uniqueName("App.ipa", avoiding: &used), "App 3.ipa")
    }

    // MARK: - Preparing

    func testPreparedFilesHaveReadableNamesAndTheLibrarysBytes() throws {
        let first = Fixtures.entry(name: "Delta Mail", version: "2.1", build: "340")
        let second = Fixtures.entry(name: "Delta Mail", version: "2.1", build: "340")
        try store(Data("first".utf8), for: first)
        try store(Data("second".utf8), for: second)

        let bundle = try preparation.prepare([first, second])

        XCTAssertEqual(bundle.fileURLs.map(\.lastPathComponent), ["Delta Mail 2.1 (340).ipa", "Delta Mail 2.1 (340) 2.ipa"])
        XCTAssertEqual(try Data(contentsOf: bundle.fileURLs[0]), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: bundle.fileURLs[1]), Data("second".utf8))
        XCTAssertEqual(bundle.skippedCount, 0)
    }

    func testUnavailablePackagesAreSkippedAndCounted() throws {
        let present = Fixtures.entry(name: "Present")
        let missingFile = Fixtures.entry(name: "Missing File")
        let flagged = Fixtures.entry(name: "Flagged", availability: .missing)
        try store(Data("present".utf8), for: present)
        try store(Data("flagged".utf8), for: flagged)

        let bundle = try preparation.prepare([present, missingFile, flagged])

        XCTAssertEqual(bundle.fileURLs.map(\.lastPathComponent), ["Present 1.0 (1).ipa"])
        XCTAssertEqual(bundle.skippedCount, 2)
    }

    func testNothingToExportIsAFailureNotAnEmptyShare() {
        let missing = Fixtures.entry(name: "Missing")

        XCTAssertThrowsError(try preparation.prepare([missing])) { error in
            XCTAssertEqual(
                (error as? ZynSignError)?.userMessage,
                "None of the selected applications has a package file that can be exported."
            )
        }
    }

    func testDiscardingRemovesThePreparedNamesAndNeverTheLibrarysFiles() throws {
        let entry = Fixtures.entry(name: "Kept")
        try store(Data("kept".utf8), for: entry)
        let libraryFile = artifactDirectory
            .appendingPathComponent(entry.record.artifact.artifactID.rawValue)
            .appendingPathExtension("ipa")

        let bundle = try preparation.prepare([entry])
        preparation.discard(bundle)

        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.directory.path))
        XCTAssertEqual(try Data(contentsOf: libraryFile), Data("kept".utf8))

        let another = try preparation.prepare([entry])
        preparation.discardAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: another.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: libraryFile.path))
    }
}
