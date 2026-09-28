import XCTest
@testable import ZynSign

/// Tests for the advanced library behaviour of the library screen model:
/// scopes, stacked filters, and search on the visible list; collections;
/// bulk actions and the safety of the selection; statistics; verification;
/// export; the signing journal; usage; and empty states.
///
/// The model runs over the real library, organizer, and index, with
/// in-memory stores beneath them, so what it shows is what those layers
/// actually produce.
@MainActor
final class ApplicationLibraryAdvancedModelTests: XCTestCase {

    private typealias Fixtures = LibraryOrganizationFixtures

    private var records: InMemoryApplicationRecordStore!
    private var artifacts: SyntheticLibraryArtifactStore!
    private var library: ApplicationLibrary!
    private var organizationStore: InMemoryLibraryOrganizationStore!
    private var organizer: LibraryOrganizer!
    private var journal: InMemorySigningHistoryStore!
    private var hub: ImportHub!
    private var model: ApplicationLibraryModel!
    private let now = LibraryOrganizationFixtures.now

    override func setUp() {
        super.setUp()
        records = InMemoryApplicationRecordStore()
        artifacts = SyntheticLibraryArtifactStore()
        library = ApplicationLibrary(records: records, artifacts: artifacts)
        organizationStore = InMemoryLibraryOrganizationStore()
        organizer = LibraryOrganizer(store: organizationStore)
        journal = InMemorySigningHistoryStore()
        let intake = SyntheticIntake()
        intake.artifactStore = artifacts
        hub = ImportHub(
            processing: ImportWorkflow(
                intake: intake,
                stagingArea: SyntheticImportStagingArea(),
                readerProvider: SyntheticArchiveReaderProvider.providing(ImportFixtures.validReader()),
                library: library,
                storage: ImportStorageGuard(probe: nil)
            ),
            progressInterval: 0
        )
        model = makeModel()
    }

    override func tearDown() {
        model = nil
        hub?.cancelAll()
        hub = nil
        journal = nil
        organizer = nil
        organizationStore = nil
        library = nil
        artifacts = nil
        records = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeModel(exporter: LibraryExportPreparation? = nil) -> ApplicationLibraryModel {
        let fixedNow = now
        return ApplicationLibraryModel(
            library: library,
            hub: hub,
            signingHistory: journal,
            organizer: organizer,
            exporter: exporter,
            now: { fixedNow }
        )
    }

    /// Stores `entry`'s record and, when it is available, bytes of its
    /// recorded size.
    @discardableResult
    private func insert(_ entry: LibraryEntry) async throws -> LibraryEntry {
        try await records.insert(entry.record)
        if entry.isArtifactAvailable {
            artifacts.hold(Data(count: entry.record.artifact.byteCount), as: entry.record.artifact.artifactID)
        }
        return entry
    }

    /// Spins the main actor until `condition` holds, bounded so a condition
    /// that never arrives fails the test instead of hanging it.
    private func awaitCondition(_ message: String, _ condition: () -> Bool) async {
        var spins = 0
        while !condition() {
            spins += 1
            if spins > 10_000 {
                XCTFail(message)
                return
            }
            await Task.yield()
        }
    }

    // MARK: - Scopes, filters, and search

    func testScopesFiltersAndSearchStackOnTheVisibleList() async throws {
        let recentFavorite = try await insert(Fixtures.entry(name: "Delta", bundleIdentifier: "com.example.delta", importedAt: now.addingTimeInterval(-3_600), isFavorite: true))
        let oldFavorite = try await insert(Fixtures.entry(name: "Echo", bundleIdentifier: "com.example.echo", importedAt: now.addingTimeInterval(-40 * 86_400), isFavorite: true))
        let plain = try await insert(Fixtures.entry(name: "Foxtrot", bundleIdentifier: "com.example.foxtrot", importedAt: now.addingTimeInterval(-7_200)))
        await model.load()
        XCTAssertEqual(Set(model.visibleIDs), [recentFavorite.record.id, oldFavorite.record.id, plain.record.id])

        model.scope = .smart(.favorites)
        XCTAssertEqual(Set(model.visibleIDs), [recentFavorite.record.id, oldFavorite.record.id])

        model.toggleFilter(.recentlyImported)
        XCTAssertEqual(model.visibleIDs, [recentFavorite.record.id])

        model.searchText = "echo"
        XCTAssertEqual(model.visibleIDs, [])
        XCTAssertEqual(model.emptyReason, .noResults)

        model.clearFiltersAndSearch()
        XCTAssertEqual(Set(model.visibleIDs), [recentFavorite.record.id, oldFavorite.record.id])
        XCTAssertEqual(model.scopeCounts[.smart(.favorites)], 2)
        XCTAssertEqual(model.scopeCounts[.all], 3)
    }

    func testTheOrderIsAppliedToTheVisibleList() async throws {
        let bravo = try await insert(Fixtures.entry(name: "Bravo", bundleIdentifier: "com.example.bravo", importedAt: now.addingTimeInterval(-60)))
        let alpha = try await insert(Fixtures.entry(name: "Alpha", bundleIdentifier: "com.example.alpha", importedAt: now.addingTimeInterval(-120)))
        await model.load()

        model.sortOrder = .name
        XCTAssertEqual(model.visibleIDs, [alpha.record.id, bravo.record.id])

        model.sortOrder = .nameDescending
        XCTAssertEqual(model.visibleIDs, [bravo.record.id, alpha.record.id])
    }

    // MARK: - Collections

    func testCreatingFillingMovingAndEmptyingCollections() async throws {
        let first = try await insert(Fixtures.entry(name: "First", bundleIdentifier: "com.example.first"))
        let second = try await insert(Fixtures.entry(name: "Second", bundleIdentifier: "com.example.second"))
        await model.load()

        let problem = await model.createCollection(named: "Inbox", adding: [first.record.id, second.record.id])
        XCTAssertNil(problem)
        let inbox = try XCTUnwrap(model.userCollections.first)
        XCTAssertEqual(model.scopeCounts[.collection(inbox.id)], 2)
        XCTAssertNotNil(model.confirmation)

        _ = await model.createCollection(named: "Done")
        let done = try XCTUnwrap(model.userCollections.last)
        await model.move([first.record.id], from: inbox.id, to: done.id)
        XCTAssertEqual(model.collections(containing: first.record.id).map(\.id), [done.id])

        await model.add([second.record.id], to: done.id)
        XCTAssertEqual(Set(model.collections(containing: second.record.id).map(\.id)), [inbox.id, done.id], "An app can be in several collections.")

        await model.remove([second.record.id], fromCollection: inbox.id)
        XCTAssertEqual(model.collections(containing: second.record.id).map(\.id), [done.id])
        XCTAssertEqual(model.index.count, 2, "Removing from a collection never removes from the library.")

        XCTAssertEqual(organizationStore.organization, model.index.organization, "Every change is persisted.")
    }

    func testCreatingFromInsideACollectionMovesTheApps() async throws {
        let entry = try await insert(Fixtures.entry(name: "Mover", bundleIdentifier: "com.example.mover"))
        await model.load()
        _ = await model.createCollection(named: "Inbox", adding: [entry.record.id])
        let inbox = try XCTUnwrap(model.userCollections.first)

        let problem = await model.createCollection(named: "Archive", adding: [entry.record.id], movingFrom: inbox.id)

        XCTAssertNil(problem)
        XCTAssertEqual(model.collections(containing: entry.record.id).map(\.name), ["Archive"])
    }

    func testCollectionNameProblemsAreReportedWhileTyping() async throws {
        await model.load()
        _ = await model.createCollection(named: "Games")
        let games = try XCTUnwrap(model.userCollections.first)

        XCTAssertNotNil(model.collectionNameProblem("GAMES"))
        XCTAssertNil(model.collectionNameProblem("GAMES", renaming: games.id))
        XCTAssertNil(model.collectionNameProblem("Work"))

        let duplicate = await model.createCollection(named: "games")
        XCTAssertEqual(duplicate, "A collection with that name already exists. Choose a different name.")
    }

    func testDeletingTheViewedCollectionFallsBackToAllApps() async throws {
        try await insert(Fixtures.entry(name: "Kept", bundleIdentifier: "com.example.kept"))
        await model.load()
        _ = await model.createCollection(named: "Temporary")
        let temporary = try XCTUnwrap(model.userCollections.first)
        model.scope = .collection(temporary.id)
        model.toggleFilter(.collection(temporary.id))

        await model.deleteCollection(temporary.id)

        XCTAssertEqual(model.scope, .all)
        XCTAssertTrue(model.filters.isEmpty, "A filter naming a deleted collection is dropped.")
        XCTAssertEqual(model.visibleIDs.count, 1, "Deleting a collection never deletes its apps.")
    }

    func testDeletingAnAppRemovesItFromItsCollections() async throws {
        let gone = try await insert(Fixtures.entry(name: "Gone", bundleIdentifier: "com.example.gone"))
        let kept = try await insert(Fixtures.entry(name: "Kept", bundleIdentifier: "com.example.kept"))
        await model.load()
        _ = await model.createCollection(named: "Both", adding: [gone.record.id, kept.record.id])

        await model.delete([gone.record.id])

        let stored = try await records.allRecords()
        XCTAssertEqual(stored.map(\.id), [kept.record.id])
        XCTAssertEqual(organizationStore.organization.userCollections.first?.memberIDs, [kept.record.id])
    }

    // MARK: - Bulk actions and selection

    func testTheSelectionOnlyEverHoldsVisibleEntries() async throws {
        let favorite = try await insert(Fixtures.entry(name: "Favorite", bundleIdentifier: "com.example.favorite", isFavorite: true))
        let plain = try await insert(Fixtures.entry(name: "Plain", bundleIdentifier: "com.example.plain"))
        await model.load()
        model.setSelecting(true)

        model.selectAll()
        XCTAssertEqual(model.selection, [favorite.record.id, plain.record.id])

        model.toggleFilter(.favorites)
        XCTAssertEqual(model.selection, [favorite.record.id], "A hidden entry leaves the selection.")

        model.toggleSelection(plain.record.id)
        XCTAssertEqual(model.selection, [favorite.record.id], "An entry that is not visible cannot be selected.")

        model.setSelecting(false)
        XCTAssertTrue(model.selection.isEmpty, "Leaving selection mode clears the selection.")
    }

    func testBulkFavoriteFavoritesAllOrUnfavoritesWhenAllAre() async throws {
        let favorite = try await insert(Fixtures.entry(name: "Favorite", bundleIdentifier: "com.example.favorite", isFavorite: true))
        let plain = try await insert(Fixtures.entry(name: "Plain", bundleIdentifier: "com.example.plain"))
        await model.load()
        let ids = [favorite.record.id, plain.record.id]

        await model.toggleFavorite(ids)
        XCTAssertTrue(model.areAllFavorites(ids))
        XCTAssertEqual(model.statistics.favorites, 2)

        await model.toggleFavorite(ids)
        XCTAssertFalse(model.areAllFavorites(ids))
        XCTAssertEqual(model.statistics.favorites, 0)
        let stored = try await records.allRecords()
        XCTAssertTrue(stored.allSatisfy { !$0.isFavorite }, "The change reached persistence.")
    }

    func testBulkDeletionRemovesEverySelectedEntryAndPrunesTheSelection() async throws {
        let first = try await insert(Fixtures.entry(name: "First", bundleIdentifier: "com.example.first"))
        let second = try await insert(Fixtures.entry(name: "Second", bundleIdentifier: "com.example.second"))
        let third = try await insert(Fixtures.entry(name: "Third", bundleIdentifier: "com.example.third"))
        await model.load()
        model.setSelecting(true)
        model.toggleSelection(first.record.id)
        model.toggleSelection(second.record.id)

        await model.removeEntries(model.selectedEntries)

        XCTAssertEqual(model.visibleIDs, [third.record.id])
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertNil(model.notice)
    }

    // MARK: - Statistics

    func testStatisticsFollowTheLibraryAndTheJournal() async throws {
        let signed = try await insert(Fixtures.entry(name: "Signed", bundleIdentifier: "com.example.signed", byteCount: 2_000))
        try await insert(Fixtures.entry(name: "Plain", bundleIdentifier: "com.example.plain", byteCount: 3_000, isFavorite: true))
        try await journal.append(Fixtures.signing(of: signed.record, at: now))
        await model.load()

        XCTAssertEqual(model.statistics.totalApplications, 2)
        XCTAssertEqual(model.statistics.signed, 1)
        XCTAssertEqual(model.statistics.unsigned, 1)
        XCTAssertEqual(model.statistics.favorites, 1)
        XCTAssertEqual(model.statistics.storageBytes, 5_000)
    }

    // MARK: - Signing journal

    func testASigningElsewhereRefreshesSignedStateWithoutAReload() async throws {
        let entry = try await insert(Fixtures.entry(name: "App", bundleIdentifier: "com.example.app"))
        await model.load()
        XCTAssertEqual(model.signingState(for: entry), .notSigned)

        try await journal.append(Fixtures.signing(of: entry.record, at: now, profileExpiresAt: now.addingTimeInterval(2 * 86_400)))
        NotificationCenter.default.post(name: .signingHistoryDidChange, object: nil)

        await awaitCondition("The journal was never re-read.") {
            self.model.signingState(for: entry) == .signed
        }
        XCTAssertEqual(model.scopeCounts[.smart(.recentlySigned)], 1)
        XCTAssertEqual(model.scopeCounts[.smart(.expiringSoon)], 1)
        XCTAssertEqual(model.rowState(for: entry.record.id)?.expiry, .expiringSoon(on: now.addingTimeInterval(2 * 86_400)))
    }

    func testAJournalReadFailureKeepsTheSignedStateShown() async throws {
        let entry = try await insert(Fixtures.entry(name: "App", bundleIdentifier: "com.example.app"))
        try await journal.append(Fixtures.signing(of: entry.record, at: now))
        await model.load()
        XCTAssertEqual(model.signingState(for: entry), .signed)

        await journal.failReads(with: ZynSignError.libraryStorageFailure(diagnosticDetail: "synthetic"))
        await model.refresh()

        XCTAssertEqual(model.signingState(for: entry), .signed, "A failed read must not turn entries unsigned.")
    }

    // MARK: - Verification

    func testVerificationReportsEachPackage() async throws {
        // The stored bytes are zeros of the recorded size; record the
        // fingerprint those exact bytes hash to, so the intact package
        // verifies intact instead of against the seeded stand-in digest.
        let intact = try await insert(Fixtures.entry(
            name: "Intact",
            bundleIdentifier: "com.example.intact",
            artifact: LibraryFixtures.reference(to: Data(count: 1_024))
        ))
        let vanished = try await insert(Fixtures.entry(
            name: "Vanished",
            bundleIdentifier: "com.example.vanished",
            artifact: LibraryFixtures.reference(to: Data(count: 1_024))
        ))
        await model.load()
        artifacts.drop(vanished.record.artifact.artifactID)

        await model.verify([intact.record.id, vanished.record.id])

        let report = try XCTUnwrap(model.verificationReport)
        XCTAssertEqual(report.intactCount, 1)
        XCTAssertEqual(report.problemCount, 1)
        XCTAssertEqual(report.items.map(\.outcome), [.checked(.intact), .checked(.missing)])
        XCTAssertNil(model.progress)
        XCTAssertEqual(model.signingState(for: try XCTUnwrap(model.entry(for: vanished.record.id))), .packageProblem, "A problem found re-reads the library.")

        model.clearVerificationReport()
        XCTAssertNil(model.verificationReport)
    }

    // MARK: - Export

    func testExportPreparesFilesAndFinishingDiscardsThem() async throws {
        let root = try LibraryFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactDirectory = root.appendingPathComponent("Artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        let exporter = LibraryExportPreparation(
            exportRoot: root.appendingPathComponent("Exports", isDirectory: true),
            artifactLocation: { artifact in
                artifactDirectory.appendingPathComponent(artifact.rawValue).appendingPathExtension("ipa")
            }
        )
        model = makeModel(exporter: exporter)
        let entry = try await insert(Fixtures.entry(name: "Shared", bundleIdentifier: "com.example.shared"))
        try Data("package".utf8).write(to: artifactDirectory
            .appendingPathComponent(entry.record.artifact.artifactID.rawValue)
            .appendingPathExtension("ipa"))
        await model.load()

        await model.export([entry.record.id])

        let bundle = try XCTUnwrap(model.exportBundle)
        XCTAssertEqual(bundle.fileURLs.map(\.lastPathComponent), ["Shared 1.0 (1).ipa"])
        XCTAssertNil(model.progress)

        model.finishExport()
        XCTAssertNil(model.exportBundle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.directory.path))
    }

    func testExportingNothingAvailableIsAnnounced() async throws {
        let root = try LibraryFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exporter = LibraryExportPreparation(
            exportRoot: root.appendingPathComponent("Exports", isDirectory: true),
            artifactLocation: { artifact in
                root.appendingPathComponent(artifact.rawValue).appendingPathExtension("ipa")
            }
        )
        model = makeModel(exporter: exporter)
        let entry = try await insert(Fixtures.entry(name: "Absent", bundleIdentifier: "com.example.absent"))
        await model.load()

        await model.export([entry.record.id])

        XCTAssertNil(model.exportBundle)
        XCTAssertEqual(model.notice?.title, "Export Failed")
    }

    // MARK: - Usage

    func testOpeningAnAppFeedsTheLastOpenedOrder() async throws {
        let older = try await insert(Fixtures.entry(name: "Older", bundleIdentifier: "com.example.older", importedAt: now.addingTimeInterval(-7_200)))
        let newer = try await insert(Fixtures.entry(name: "Newer", bundleIdentifier: "com.example.newer", importedAt: now.addingTimeInterval(-3_600)))
        await model.load()
        model.sortOrder = .lastOpened
        XCTAssertEqual(model.visibleIDs, [newer.record.id, older.record.id], "Never-opened apps list newest import first.")

        await model.recordOpened(older.record.id)

        XCTAssertEqual(model.visibleIDs, [older.record.id, newer.record.id])
        XCTAssertNotNil(organizationStore.organization.lastOpened[older.record.id])
    }

    // MARK: - Empty states and rows

    func testEmptyReasonsNameWhyNothingIsShown() async throws {
        try await insert(Fixtures.entry(name: "Plain", bundleIdentifier: "com.example.plain"))
        await model.load()

        model.scope = .smart(.favorites)
        XCTAssertEqual(model.emptyReason, .smartCollection(.favorites))
        XCTAssertEqual(LibrarySmartCollection.favorites.emptyTitle, "No Favorites")
        XCTAssertEqual(LibrarySmartCollection.favorites.ruleDescription, "Star your favorite apps to find them quickly.")

        _ = await model.createCollection(named: "Empty")
        let empty = try XCTUnwrap(model.userCollections.first)
        model.scope = .collection(empty.id)
        XCTAssertEqual(model.emptyReason, .emptyCollection(name: "Empty"))

        model.scope = .all
        XCTAssertNil(model.emptyReason)
        model.searchText = "nothing matches this"
        XCTAssertEqual(model.emptyReason, .noResults)
    }

    func testRowsCarryHighlightTermsAndExplainHiddenMatches() async throws {
        let entry = try await insert(Fixtures.entry(name: "Plain", bundleIdentifier: "com.example.plain"))
        await model.load()
        _ = await model.createCollection(named: "Weekend Games", adding: [entry.record.id])

        model.searchText = "weekend"

        let state = try XCTUnwrap(model.rowState(for: entry.record.id))
        XCTAssertEqual(state.highlightTerms, ["weekend"])
        XCTAssertEqual(state.matchContext, "In: Weekend Games")
        XCTAssertNil(state.isSelected)
    }
}
