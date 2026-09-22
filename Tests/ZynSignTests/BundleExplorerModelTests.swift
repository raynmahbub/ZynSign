import XCTest
@testable import ZynSign

/// Tests for the bundle explorer presentation model and the display
/// mappings the explorer screens render.
///
/// The model is exercised with the real inspection use case over the real
/// library use case with in-memory stores and a synthetic archive boundary,
/// so the phases it renders are the phases the application layer actually
/// produces: loading into loaded, empty, or failed; a retry after a failure;
/// and, once content is on screen, no further reads of the package however
/// often the screen asks.
@MainActor
final class BundleExplorerModelTests: XCTestCase {

    private var records: InMemoryApplicationRecordStore!
    private var artifacts: SyntheticLibraryArtifactStore!
    private var library: ApplicationLibrary!
    private var provider: CountingArchiveReaderProvider!
    private var record: ApplicationRecord!
    private var model: BundleExplorerModel!

    override func setUp() async throws {
        try await super.setUp()
        records = InMemoryApplicationRecordStore()
        artifacts = SyntheticLibraryArtifactStore()
        library = ApplicationLibrary(records: records, artifacts: artifacts)
        provider = CountingArchiveReaderProvider(entryTable: Self.exampleTable)

        let content = Data(repeating: 0x5A, count: 4_096)
        let artifactID = ArtifactIdentifier()
        artifacts.hold(content, as: artifactID)
        record = LibraryFixtures.record(
            executableName: "Example",
            artifact: LibraryFixtures.reference(to: content, artifactID: artifactID)
        )
        try await records.insert(record)
        model = makeModel()
    }

    override func tearDown() {
        model = nil
        record = nil
        provider = nil
        library = nil
        artifacts = nil
        records = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private static let exampleTable: [ArchiveEntry] = [
        makeEntry("Payload", kind: .directory),
        makeEntry("Payload/Example.app", kind: .directory),
        makeEntry("Payload/Example.app/Info.plist", uncompressedSize: 700),
        makeEntry("Payload/Example.app/Example", uncompressedSize: 9_000),
        makeEntry("Payload/Example.app/Frameworks/Core.framework/Core", uncompressedSize: 3_000),
        makeEntry("Payload/Example.app/Frameworks/Link", kind: .symbolicLink),
        makeEntry("Payload/Example.app/PlugIns", kind: .directory),
        makeEntry("Payload/Example.app/_CodeSignature/CodeResources", uncompressedSize: 100),
    ]

    private func makeModel(recordID: ApplicationRecordIdentifier? = nil) -> BundleExplorerModel {
        BundleExplorerModel(
            inspection: IPABundleContentsInspection(library: library, readerProvider: provider),
            recordID: recordID ?? record.id
        )
    }

    private func path(_ rawValue: String) throws -> BundlePath {
        try XCTUnwrap(BundlePath(rawValue: rawValue))
    }

    private func loadedContents(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> BundleContents {
        guard case .loaded(let contents) = model.phase else {
            XCTFail("Expected a loaded phase, got \(model.phase)", file: file, line: line)
            throw PhaseMismatch()
        }
        return contents
    }

    private struct PhaseMismatch: Error {}

    // MARK: - Phases

    func testTheExplorerIsPresentedAsLoadingUntilThePackageIsRead() {
        XCTAssertEqual(model.phase, .loading)
        XCTAssertNil(model.contents)
        XCTAssertNil(model.entries(in: .root))
        XCTAssertEqual(provider.openCount, 0)
    }

    func testLoadingPresentsTheBundleStructure() async throws {
        await model.load()

        let contents = try loadedContents()
        XCTAssertEqual(contents.bundleName, "Example.app")
        XCTAssertEqual(
            model.entries(in: .root)?.map(\.name),
            ["Frameworks", "PlugIns", "_CodeSignature", "Example", "Info.plist"]
        )
        XCTAssertEqual(model.entries(in: try path("Frameworks"))?.map(\.name), ["Core.framework", "Link"])
        XCTAssertEqual(model.entries(in: try path("PlugIns")), [])
        XCTAssertNil(model.entries(in: try path("Frameworks/Link")))
        XCTAssertEqual(contents.entry(at: try path("Example"))?.role, .executable)
        XCTAssertEqual(provider.openCount, 1)
    }

    func testAnEmptyBundleIsPresentedAsEmpty() async throws {
        provider.entryTable = [
            makeEntry("Payload", kind: .directory),
            makeEntry("Payload/Example.app", kind: .directory),
        ]

        await model.load()

        XCTAssertEqual(model.phase, .empty(bundleName: "Example.app"))
        XCTAssertNil(model.contents)
        XCTAssertNil(model.entries(in: .root))
    }

    func testAMissingArtifactIsPresentedAsAFailureWithTheTypedMessage() async throws {
        artifacts.drop(record.artifact.artifactID)

        await model.load()

        XCTAssertEqual(model.phase, .failed(ZynSignError.bundleArtifactMissing().userMessage))
        XCTAssertNil(model.contents)
        XCTAssertEqual(provider.openCount, 0)
    }

    func testAnUnknownRecordIsPresentedAsAFailure() async throws {
        model = makeModel(recordID: ApplicationRecordIdentifier())

        await model.load()

        XCTAssertEqual(model.phase, .failed(ZynSignError.libraryRecordNotFound().userMessage))
    }

    func testAnUnreadableContainerIsPresentedAsAFailure() async throws {
        provider.failure = ZynSignError.unreadableArtifact(diagnosticDetail: "synthetic detail")

        await model.load()

        XCTAssertEqual(model.phase, .failed(ZynSignError.unreadableArtifact().userMessage))
        if case .failed(let message) = model.phase {
            XCTAssertFalse(message.contains("synthetic"))
        }
    }

    func testAPackageWithoutABundleIsPresentedAsAFailure() async throws {
        provider.entryTable = [makeEntry("Payload", kind: .directory)]

        await model.load()

        XCTAssertEqual(model.phase, .failed(ZynSignError.missingApplicationBundle().userMessage))
    }

    // MARK: - Retry and idempotence

    func testLoadingAgainAfterAFailureReadsThePackageAgain() async throws {
        provider.failure = ZynSignError.unreadableArtifact()
        await model.load()
        guard case .failed = model.phase else {
            return XCTFail("Expected a failed phase, got \(model.phase)")
        }
        XCTAssertEqual(provider.openCount, 1)

        provider.failure = nil
        await model.load()

        XCTAssertEqual(try loadedContents().bundleName, "Example.app")
        XCTAssertEqual(provider.openCount, 2)
    }

    func testLoadingAgainOnceContentIsOnScreenReadsNothing() async throws {
        await model.load()
        let first = try loadedContents()
        XCTAssertEqual(provider.openCount, 1)

        await model.load()
        await model.load()

        XCTAssertEqual(provider.openCount, 1)
        XCTAssertEqual(try loadedContents(), first)
    }

    func testLoadingAgainOnceAnEmptyBundleIsOnScreenReadsNothing() async throws {
        provider.entryTable = [makeEntry("Payload/Example.app", kind: .directory)]
        await model.load()
        XCTAssertEqual(model.phase, .empty(bundleName: "Example.app"))

        await model.load()

        XCTAssertEqual(provider.openCount, 1)
    }

    func testOverlappingLoadsReadThePackageOnce() async throws {
        async let first: Void = model.load()
        async let second: Void = model.load()
        _ = await (first, second)

        XCTAssertEqual(provider.openCount, 1)
        XCTAssertNotNil(model.contents)
    }

    // MARK: - Failure rendering

    func testForeignErrorsAreNeverRenderedVerbatim() {
        let foreign = NSError(domain: "com.zynsign.synthetic.tests", code: 9, userInfo: [
            NSLocalizedDescriptionKey: "synthetic failure at /private/var/location",
        ])
        let message = BundleExplorerModel.failureMessage(for: foreign)
        XCTAssertFalse(message.contains("synthetic"))
        XCTAssertFalse(message.contains("/private"))
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(
            BundleExplorerModel.failureMessage(for: ZynSignError.bundleArtifactInconsistent(diagnosticDetail: "synthetic")),
            ZynSignError.bundleArtifactInconsistent().userMessage
        )
    }

    // MARK: - Entry point from the application detail screen

    func testTheDetailScreenOffersTheExplorerOnlyForAnAvailablePackage() {
        let available = ApplicationDetailContent(entry: LibraryEntry(record: record, artifactAvailability: .available))
        XCTAssertTrue(available.canExploreBundle)
        XCTAssertNil(available.artifactExplanation)

        let missing = ApplicationDetailContent(entry: LibraryEntry(record: record, artifactAvailability: .missing))
        XCTAssertFalse(missing.canExploreBundle)
        XCTAssertNotNil(missing.artifactExplanation)

        let inconsistent = ApplicationDetailContent(
            entry: LibraryEntry(record: record, artifactAvailability: .inconsistent(recordedByteCount: 4_096, observedByteCount: 16))
        )
        XCTAssertFalse(inconsistent.canExploreBundle)
        XCTAssertNotNil(inconsistent.artifactExplanation)
    }

    // MARK: - Row content

    func testDirectoryRowsShowTheirRoleAndItemCount() async throws {
        await model.load()
        let contents = try loadedContents()
        let frameworks = try XCTUnwrap(contents.entry(at: try path("Frameworks")))

        let row = BundleEntryRowContent(entry: frameworks, childCount: contents.childCount(of: frameworks.path))

        XCTAssertEqual(row.name, "Frameworks")
        XCTAssertTrue(row.isDirectory)
        XCTAssertEqual(row.symbolName, "folder")
        XCTAssertEqual(row.detailText, "Frameworks directory · 2 items")
        XCTAssertNil(row.byteCount)
        XCTAssertEqual(row.accessibilityLabel, "Frameworks, Folder, Frameworks directory, 2 items")

        let plugIns = try XCTUnwrap(contents.entry(at: try path("PlugIns")))
        let emptyRow = BundleEntryRowContent(entry: plugIns, childCount: contents.childCount(of: plugIns.path))
        XCTAssertEqual(emptyRow.detailText, "Plug-ins directory · 0 items")

        let core = try XCTUnwrap(contents.entry(at: try path("Frameworks/Core.framework")))
        let plainRow = BundleEntryRowContent(entry: core, childCount: contents.childCount(of: core.path))
        XCTAssertEqual(plainRow.detailText, "1 item")
    }

    func testFileRowsShowTheirRoleOrKindAndTheirDeclaredSize() async throws {
        await model.load()
        let contents = try loadedContents()

        let info = try XCTUnwrap(contents.entry(at: try path("Info.plist")))
        let infoRow = BundleEntryRowContent(entry: info, childCount: nil)
        XCTAssertFalse(infoRow.isDirectory)
        XCTAssertEqual(infoRow.symbolName, "doc")
        XCTAssertEqual(infoRow.detailText, "Bundle information file")
        XCTAssertEqual(infoRow.byteCount, 700)
        XCTAssertEqual(infoRow.accessibilityLabel, "Info.plist, File, Bundle information file")

        let core = try XCTUnwrap(contents.entry(at: try path("Frameworks/Core.framework/Core")))
        let coreRow = BundleEntryRowContent(entry: core, childCount: nil)
        XCTAssertEqual(coreRow.detailText, "File")
        XCTAssertEqual(coreRow.byteCount, 3_000)
    }

    func testLinkAndUnsupportedRowsNameTheirKindAndLeadNowhere() throws {
        let link = BundleEntry(path: try path("Frameworks/Link"), kind: .symbolicLink, declaredByteCount: 12)
        let linkRow = BundleEntryRowContent(entry: link, childCount: nil)
        XCTAssertFalse(linkRow.isDirectory)
        XCTAssertEqual(linkRow.symbolName, "link")
        XCTAssertEqual(linkRow.detailText, "Symbolic link")
        XCTAssertNil(linkRow.byteCount)
        XCTAssertEqual(linkRow.accessibilityLabel, "Link, Symbolic link")

        let device = BundleEntry(path: try path("dev"), kind: .unsupported)
        let deviceRow = BundleEntryRowContent(entry: device, childCount: nil)
        XCTAssertFalse(deviceRow.isDirectory)
        XCTAssertEqual(deviceRow.symbolName, "questionmark.square.dashed")
        XCTAssertEqual(deviceRow.detailText, "Unsupported entry")
    }

    func testLongAndUnusualNamesAreCarriedIntoRowsUnchanged() throws {
        let longName = String(repeating: "x", count: 300) + ".txt"
        let entry = BundleEntry(path: try path(longName), kind: .regularFile, declaredByteCount: 1)
        XCTAssertEqual(BundleEntryRowContent(entry: entry, childCount: nil).name, longName)
        let unicode = BundleEntry(path: try path("Ünïcødé 名前 📦.strings"), kind: .regularFile)
        XCTAssertEqual(BundleEntryRowContent(entry: unicode, childCount: nil).name, "Ünïcødé 名前 📦.strings")
    }

    // MARK: - Listing content

    func testTheRootListingSurfacesNotableEntriesAndTheBundleName() async throws {
        await model.load()
        let contents = try loadedContents()

        let listing = BundleDirectoryListingContent(contents: contents, directory: .root)

        XCTAssertEqual(listing.title, "Example.app")
        XCTAssertNil(listing.locationText)
        XCTAssertEqual(listing.entriesHeader, "Bundle Contents")
        XCTAssertEqual(listing.entries, contents.rootEntries)
        XCTAssertEqual(
            listing.notableEntries.map(\.path.rawValue),
            ["Info.plist", "Example", "_CodeSignature", "_CodeSignature/CodeResources", "Frameworks", "PlugIns"]
        )
        XCTAssertEqual(listing.itemCountText, "5 items")
        XCTAssertNil(listing.omittedEntriesText)
    }

    func testNestedListingsShowTheirLocationAndNoNotableEntries() async throws {
        await model.load()
        let contents = try loadedContents()

        let listing = BundleDirectoryListingContent(contents: contents, directory: try path("Frameworks/Core.framework"))

        XCTAssertEqual(listing.title, "Core.framework")
        XCTAssertEqual(listing.locationText, "Frameworks/Core.framework")
        XCTAssertEqual(listing.entriesHeader, "Contents")
        XCTAssertEqual(listing.entries.map(\.name), ["Core"])
        XCTAssertEqual(listing.notableEntries, [])
        XCTAssertEqual(listing.itemCountText, "1 item")
        XCTAssertNil(listing.omittedEntriesText)
    }

    func testTheRootListingReportsEntriesThatCouldNotBeListed() {
        let contents = BundleContents(
            entryTable: [
                makeEntry("Payload/Example.app/Info.plist"),
                makeRejectedEntry("Payload/Example.app/../escape"),
            ],
            bundlePath: makePath("Payload/Example.app")
        )
        let listing = BundleDirectoryListingContent(contents: contents, directory: .root)
        let note = try? XCTUnwrap(listing.omittedEntriesText)
        XCTAssertEqual(note?.hasPrefix("1 entry in the package could not be listed"), true)
        XCTAssertEqual(BundleDirectoryListingContent.omittedEntriesText(for: 2).hasPrefix("2 entries"), true)
    }

    func testTheNotableEntriesNoteDisclaimsTrustConclusions() {
        let note = BundleDirectoryListingContent.notableEntriesNote
        XCTAssertTrue(note.contains("not evidence"))
        XCTAssertTrue(note.contains("nothing here has been opened"))
    }

    // MARK: - Entry detail content

    func testEntryDetailsShowRecordedMetadataAndTheBoundary() async throws {
        await model.load()
        let contents = try loadedContents()

        let resources = try XCTUnwrap(contents.entry(at: try path("_CodeSignature/CodeResources")))
        let detail = BundleEntryDetailContent(entry: resources)
        XCTAssertEqual(detail.name, "CodeResources")
        XCTAssertEqual(detail.locationText, "_CodeSignature/CodeResources")
        XCTAssertEqual(detail.kindText, "File")
        XCTAssertEqual(detail.byteCount, 100)
        XCTAssertEqual(detail.roleTitle, BundleEntryRole.codeResources.displayName)
        XCTAssertEqual(detail.roleExplanation, BundleEntryRole.codeResources.explanation)
        XCTAssertTrue(detail.kindNote.contains("has not been opened"))

        let link = try XCTUnwrap(contents.entry(at: try path("Frameworks/Link")))
        let linkDetail = BundleEntryDetailContent(entry: link)
        XCTAssertEqual(linkDetail.kindText, "Symbolic link")
        XCTAssertNil(linkDetail.byteCount)
        XCTAssertNil(linkDetail.roleTitle)
        XCTAssertTrue(linkDetail.kindNote.contains("does not read or follow"))

        let unsupportedNote = BundleEntryDetailContent.kindNote(for: .unsupported)
        XCTAssertTrue(unsupportedNote.contains("left alone"))
    }
}

// MARK: - Provider double

/// An `ArtifactArchiveReaderProvider` that counts how often a reader is
/// requested and hands out a fresh synthetic reader over the current table,
/// or fails with the configured error.
private final class CountingArchiveReaderProvider: ArtifactArchiveReaderProvider, @unchecked Sendable {

    private let lock = NSLock()
    private var _entryTable: [ArchiveEntry]
    private var _failure: (any Error)?
    private var _openCount = 0

    init(entryTable: [ArchiveEntry]) {
        _entryTable = entryTable
    }

    var entryTable: [ArchiveEntry] {
        get { lock.withLock { _entryTable } }
        set { lock.withLock { _entryTable = newValue } }
    }

    var failure: (any Error)? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }

    /// How many times a reader was requested.
    var openCount: Int {
        lock.withLock { _openCount }
    }

    func archiveReader(for artifact: ArtifactIdentifier) throws -> any ArchiveReader {
        let (table, failure): ([ArchiveEntry], (any Error)?) = lock.withLock {
            _openCount += 1
            return (_entryTable, _failure)
        }
        if let failure {
            throw failure
        }
        return SyntheticArchiveReader(entryTable: table)
    }
}
