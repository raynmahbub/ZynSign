import XCTest
@testable import ZynSign

/// Tests for the Applications Library presentation model and the display
/// mappings the library screen renders.
///
/// The model is exercised with the real library use case over in-memory
/// stores and the real import presentation model over synthetic ports, so
/// the phases it renders are the phases the application layer actually
/// produces: loading into loaded, empty, or failed; import settlement
/// refreshing the library; and removal passing through an observable
/// in-flight state back to loaded or empty, always re-reading persistence
/// rather than editing the list in place.
@MainActor
final class ApplicationLibraryModelTests: XCTestCase {

    private var records: InMemoryApplicationRecordStore!
    private var artifacts: SyntheticLibraryArtifactStore!
    private var library: ApplicationLibrary!
    private var intake: SyntheticIntake!
    private var importing: PackageImportModel!
    private var model: ApplicationLibraryModel!

    override func setUp() {
        super.setUp()
        records = InMemoryApplicationRecordStore()
        artifacts = SyntheticLibraryArtifactStore()
        let clock = SyntheticClock()
        library = ApplicationLibrary(
            records: records,
            artifacts: artifacts,
            now: { [clock] in clock.now() }
        )
        intake = SyntheticIntake()
        intake.artifactStore = artifacts
        importing = PackageImportModel(importing: makePackageImport())
        model = ApplicationLibraryModel(library: library, importing: importing)
    }

    override func tearDown() {
        model = nil
        importing = nil
        intake = nil
        library = nil
        artifacts = nil
        records = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makePackageImport() -> IPAPackageImport {
        IPAPackageImport(
            intake: intake,
            readerProvider: SyntheticArchiveReaderProvider.providing(ImportFixtures.validReader()),
            library: library
        )
    }

    /// Rebuilds the import presentation model and the screen model over a
    /// different reader, for tests that need a specific container outcome.
    private func makeModels(reader: SyntheticArchiveReader) {
        importing = PackageImportModel(importing: IPAPackageImport(
            intake: intake,
            readerProvider: SyntheticArchiveReaderProvider.providing(reader),
            library: library
        ))
        model = ApplicationLibraryModel(library: library, importing: importing)
    }

    /// Spins the main actor until the import phase leaves `importing`,
    /// bounded so a model that never settles fails the test instead of
    /// hanging it.
    private func awaitSettledImport() async -> PackageImportModel.Phase {
        var spins = 0
        while case .importing = importing.phase {
            spins += 1
            if spins > 10_000 {
                XCTFail("The import phase never settled.")
                break
            }
            await Task.yield()
        }
        return importing.phase
    }

    /// Spins the main actor until `condition` holds, bounded so a condition
    /// that never arrives fails the test instead of hanging it.
    private func awaitCondition(
        _ message: String,
        _ condition: () -> Bool
    ) async {
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

    /// Inserts two records — the first with its artifact held, the second
    /// with its artifact gone — and loads the model over them.
    private func loadWithTwoRecords() async throws -> (first: LibraryEntry, second: LibraryEntry) {
        let first = LibraryFixtures.record(
            identity: LibraryFixtures.identity(displayName: "First"),
            importedAt: LibraryFixtures.importDate
        )
        let second = LibraryFixtures.record(
            identity: LibraryFixtures.identity(
                bundleIdentifier: "com.example.second",
                displayName: "Second"
            ),
            artifact: LibraryFixtures.reference(fingerprintSeed: 0x01),
            importedAt: LibraryFixtures.laterDate
        )
        try await records.insert(first)
        try await records.insert(second)
        artifacts.hold(Data(count: first.artifact.byteCount), as: first.artifact.artifactID)

        await model.load()

        guard case .loaded(let entries) = model.phase else {
            XCTFail("Expected a loaded phase, got \(model.phase)")
            return (LibraryEntry(record: first, artifactAvailability: .missing),
                    LibraryEntry(record: second, artifactAvailability: .missing))
        }
        return (entries[0], entries[1])
    }

    // MARK: - Loading

    func testTheLibraryIsPresentedAsLoadingUntilPersistenceIsRead() {
        XCTAssertEqual(model.phase, .loading)
        XCTAssertNil(model.notice)
    }

    func testLoadingPresentsThePersistedRecordsWithTheirAvailability() async throws {
        let loaded = try await loadWithTwoRecords()

        guard case .loaded(let entries) = model.phase else {
            return XCTFail("Expected a loaded phase, got \(model.phase)")
        }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].record.id, loaded.first.record.id)
        XCTAssertEqual(entries[1].record.id, loaded.second.record.id)
        XCTAssertEqual(entries.map { $0.artifactAvailability }, [.available, .missing])
    }

    func testLoadingAnEmptyLibraryProducesTheEmptyPhase() async {
        await model.load()

        XCTAssertEqual(model.phase, .empty)
    }

    func testAPersistenceFailureProducesTheFailedPhaseWithTheErrorUserMessage() async {
        await records.failListing(with: ZynSignError.libraryCatalogUnreadable(diagnosticDetail: "synthetic damage"))

        await model.load()

        XCTAssertEqual(
            model.phase,
            .failed("ZynSign's application library could not be read.")
        )
    }

    func testARetryAfterAFailureLoadsTheLibraryAgain() async {
        await records.failListing(with: ZynSignError.libraryStorageFailure(diagnosticDetail: "synthetic failure"))
        await model.load()
        guard case .failed = model.phase else {
            return XCTFail("Expected a failed phase, got \(model.phase)")
        }

        await records.failListing(with: nil)
        await model.load()

        XCTAssertEqual(model.phase, .empty)
    }

    // MARK: - Import

    func testASuccessfulImportRefreshesTheLibrary() async {
        await model.load()
        XCTAssertEqual(model.phase, .empty)

        intake.nextStagedContent = Data("first imported package".utf8)
        importing.beginImport(from: ImportFixtures.sourceURL())
        let phase = await awaitSettledImport()

        guard case .succeeded(let summary) = phase else {
            return XCTFail("Expected a succeeded import, got \(phase)")
        }
        XCTAssertEqual(summary.libraryMessage, "The package was added to ZynSign's library.")
        XCTAssertEqual(model.notice?.message, "The package was added to ZynSign's library.")

        await awaitCondition("The library never refreshed after the import.") {
            if case .loaded = self.model.phase { return true }
            return false
        }
        guard case .loaded(let entries) = model.phase else {
            return XCTFail("Expected a loaded phase, got \(model.phase)")
        }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.record.identity.displayName, "Example")

        let stored = try? await records.allRecords()
        XCTAssertEqual(stored?.count, 1)
    }

    func testAPickerCancellationIsAnOrdinaryOutcomeAndNotAFailure() async {
        await model.load()
        XCTAssertEqual(model.phase, .empty)

        struct PickerFailure: Error {}
        model.handlePickerResult(.failure(PickerFailure()))

        XCTAssertEqual(importing.phase, .cancelled)
        XCTAssertEqual(model.phase, .empty)
        XCTAssertNil(model.notice)
    }

    func testARejectedImportIsSurfacedAndChangesNothingInTheLibrary() async {
        makeModels(reader: ImportFixtures.emptyPayloadReader())
        await model.load()
        XCTAssertEqual(model.phase, .empty)

        importing.beginImport(from: ImportFixtures.sourceURL())
        let phase = await awaitSettledImport()

        guard case .failed(let message) = phase else {
            return XCTFail("Expected a failed import, got \(phase)")
        }
        XCTAssertEqual(message, "No application was found inside the package.")
        XCTAssertEqual(model.notice?.message, message)
        XCTAssertEqual(model.phase, .empty)

        let stored = try? await records.allRecords()
        XCTAssertEqual(stored?.count, 0)
    }

    func testAStagingFailureIsSurfacedAndChangesNothingInTheLibrary() async {
        await model.load()
        XCTAssertEqual(model.phase, .empty)

        intake.behaviour = .fails
        importing.beginImport(from: ImportFixtures.sourceURL())
        let phase = await awaitSettledImport()

        guard case .failed(let message) = phase else {
            return XCTFail("Expected a failed import, got \(phase)")
        }
        XCTAssertEqual(message, "The selected file could not be reached.")
        XCTAssertEqual(model.notice?.message, message)
        XCTAssertEqual(model.phase, .empty)
    }

    // MARK: - Removal

    func testRemovalRemovesTheRecordAndItsArtifactAndRefreshesTheLibrary() async throws {
        let loaded = try await loadWithTwoRecords()

        await model.remove(loaded.first)

        XCTAssertNil(model.removingRecordID)
        let stored = try await records.allRecords()
        XCTAssertEqual(stored.map { $0.id }, [loaded.second.record.id])
        XCTAssertEqual(artifacts.removed, [loaded.first.record.artifact.artifactID])
        guard case .loaded(let remaining) = model.phase else {
            return XCTFail("Expected a loaded phase, got \(model.phase)")
        }
        XCTAssertEqual(remaining.map { $0.record.id }, [loaded.second.record.id])
        XCTAssertNil(model.notice)
    }

    func testRemovalToAnEmptyLibraryProducesTheEmptyPhase() async throws {
        let record = LibraryFixtures.record()
        try await records.insert(record)
        artifacts.hold(Data(count: record.artifact.byteCount), as: record.artifact.artifactID)
        await model.load()
        guard case .loaded(let entries) = model.phase, let entry = entries.first else {
            return XCTFail("Expected a loaded phase, got \(model.phase)")
        }

        await model.remove(entry)

        XCTAssertEqual(model.phase, .empty)
        let count = await records.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(artifacts.removed, [record.artifact.artifactID])
    }

    func testAFailedDeletionKeepsTheRecordAndAnnouncesTheFailure() async throws {
        let loaded = try await loadWithTwoRecords()
        await records.failDeletion(with: ZynSignError.libraryStorageFailure(diagnosticDetail: "synthetic delete failure"))

        await model.remove(loaded.first)

        XCTAssertNotNil(model.notice)
        // Nothing was removed from persistence, and the screen shows what
        // persistence holds — the entry is still listed.
        let stored = try await records.allRecords()
        XCTAssertEqual(stored.map { $0.id }, [loaded.first.record.id, loaded.second.record.id])
        guard case .loaded(let entries) = model.phase else {
            return XCTFail("Expected a loaded phase, got \(model.phase)")
        }
        XCTAssertEqual(entries.map { $0.record.id }, [loaded.first.record.id, loaded.second.record.id])
        XCTAssertNil(model.removingRecordID)
    }

    func testAFailedArtifactCleanupIsAnnouncedAndTheListReflectsPersistence() async throws {
        let loaded = try await loadWithTwoRecords()
        artifacts.failRemoval(with: ZynSignError.libraryStorageFailure(diagnosticDetail: "synthetic removal failure"))

        await model.remove(loaded.first)

        XCTAssertNotNil(model.notice)
        // The record was deleted first, so the screen reflects persistence:
        // the entry is gone and the artifact is an orphan for later cleanup.
        let stored = try await records.allRecords()
        XCTAssertEqual(stored.map { $0.id }, [loaded.second.record.id])
        guard case .loaded(let entries) = model.phase else {
            return XCTFail("Expected a loaded phase, got \(model.phase)")
        }
        XCTAssertEqual(entries.map { $0.record.id }, [loaded.second.record.id])
        XCTAssertEqual(artifacts.held, [loaded.first.record.artifact.artifactID])
    }

    func testARemovalRunsThroughAnObservableInFlightState() async throws {
        let loaded = try await loadWithTwoRecords()
        await records.gateDeletions()

        let removal = Task { await model.remove(loaded.first) }
        await awaitCondition("The removal never started.") {
            self.model.removingRecordID != nil
        }
        XCTAssertEqual(model.removingRecordID, loaded.first.record.id)
        guard case .loaded(let entriesDuringRemoval) = model.phase else {
            return XCTFail("Expected a loaded phase during removal, got \(model.phase)")
        }
        XCTAssertEqual(entriesDuringRemoval.count, 2)

        await records.releaseDeletionGate()
        await removal.value

        guard case .loaded(let remaining) = model.phase else {
            return XCTFail("Expected a loaded phase, got \(model.phase)")
        }
        XCTAssertEqual(remaining.map { $0.record.id }, [loaded.second.record.id])
        XCTAssertNil(model.removingRecordID)
    }

    // MARK: - Row content

    func testRowContentPresentsTheDeclaredMetadata() {
        let entry = LibraryEntry(
            record: LibraryFixtures.record(
                identity: LibraryFixtures.identity(
                    displayName: "Example",
                    shortVersion: "1.2",
                    build: "34"
                )
            ),
            artifactAvailability: .available
        )

        let content = ApplicationLibraryRowContent(entry: entry)

        XCTAssertEqual(content.name, "Example")
        XCTAssertEqual(content.bundleIdentifier, "com.example.synthetic")
        XCTAssertEqual(content.versionText, "Version 1.2 (34)")
        XCTAssertNil(content.availabilityText)
    }

    func testRowContentFallsBackWithoutInventingUndeclaredMetadata() {
        let entry = LibraryEntry(
            record: LibraryFixtures.record(
                identity: LibraryFixtures.identity(
                    displayName: nil,
                    shortVersion: nil,
                    build: nil
                ),
                sourceFileName: nil
            ),
            artifactAvailability: .available
        )

        let content = ApplicationLibraryRowContent(entry: entry)

        XCTAssertEqual(content.name, "Unnamed Application")
        XCTAssertEqual(content.versionText, nil)
        XCTAssertNil(content.availabilityText)
    }

    func testRowContentFlagsArtifactsThatAreNotAvailable() {
        let missing = LibraryEntry(
            record: LibraryFixtures.record(),
            artifactAvailability: .missing
        )
        let inconsistent = LibraryEntry(
            record: LibraryFixtures.record(),
            artifactAvailability: .inconsistent(recordedByteCount: 10, observedByteCount: 4)
        )

        XCTAssertEqual(
            ApplicationLibraryRowContent(entry: missing).availabilityText,
            "Package File Missing"
        )
        XCTAssertEqual(
            ApplicationLibraryRowContent(entry: inconsistent).availabilityText,
            "Package File Does Not Match Its Record"
        )
    }

    // MARK: - Detail content

    func testDetailContentPresentsThePersistedMetadata() {
        let entry = LibraryEntry(
            record: LibraryFixtures.record(
                identity: LibraryFixtures.identity(
                    displayName: "Example",
                    shortVersion: "1.2",
                    build: "34"
                ),
                sourceFileName: "Example.ipa"
            ),
            artifactAvailability: .available
        )

        let content = ApplicationDetailContent(entry: entry)

        XCTAssertEqual(content.name, "Example")
        XCTAssertEqual(content.bundleIdentifier, "com.example.synthetic")
        XCTAssertEqual(content.versionText, "1.2")
        XCTAssertEqual(content.buildText, "34")
        XCTAssertEqual(content.sourceFileName, "Example.ipa")
        XCTAssertEqual(content.artifactStatus, "Available")
        XCTAssertNil(content.artifactExplanation)
        XCTAssertEqual(content.imported, LibraryFixtures.importDate)
        XCTAssertNil(content.updated)
    }

    func testDetailContentShowsUndeclaredMetadataWithoutInventingIt() {
        let entry = LibraryEntry(
            record: LibraryFixtures.record(
                identity: LibraryFixtures.identity(
                    displayName: nil,
                    shortVersion: nil,
                    build: nil
                ),
                sourceFileName: nil
            ),
            artifactAvailability: .available
        )

        let content = ApplicationDetailContent(entry: entry)

        XCTAssertEqual(content.name, "Unnamed Application")
        XCTAssertEqual(content.versionText, "—")
        XCTAssertEqual(content.buildText, "—")
        XCTAssertEqual(content.sourceFileName, "—")
    }

    func testDetailContentShowsTheUpdateDateOnlyWhenTheRecordChanged() {
        let unchanged = ApplicationDetailContent(entry: LibraryEntry(
            record: LibraryFixtures.record(),
            artifactAvailability: .available
        ))
        let changed = ApplicationDetailContent(entry: LibraryEntry(
            record: LibraryFixtures.record(updatedAt: LibraryFixtures.laterDate),
            artifactAvailability: .available
        ))

        XCTAssertNil(unchanged.updated)
        XCTAssertEqual(changed.updated, LibraryFixtures.laterDate)
    }

    func testDetailContentRepresentsAMissingArtifactExplicitly() {
        let entry = LibraryEntry(
            record: LibraryFixtures.record(),
            artifactAvailability: .missing
        )

        let content = ApplicationDetailContent(entry: entry)

        XCTAssertEqual(content.artifactStatus, "Missing")
        XCTAssertFalse(content.artifactExplanation?.isEmpty ?? true)
    }

    func testDetailContentRepresentsAnInconsistentArtifactExplicitly() {
        let entry = LibraryEntry(
            record: LibraryFixtures.record(),
            artifactAvailability: .inconsistent(recordedByteCount: 4_194_304, observedByteCount: 2_097_152)
        )

        let content = ApplicationDetailContent(entry: entry)

        XCTAssertEqual(content.artifactStatus, "Inconsistent")
        XCTAssertFalse(content.artifactExplanation?.isEmpty ?? true)
    }

    // MARK: - Search

    func testSearchMatchesNameAndBundleIdentifierAndSourceFileName() {
        let byName = LibraryEntry(
            record: LibraryFixtures.record(identity: LibraryFixtures.identity(displayName: "Delta Mail")),
            artifactAvailability: .available
        )
        let byBundleID = LibraryEntry(
            record: LibraryFixtures.record(
                identity: LibraryFixtures.identity(
                    bundleIdentifier: "com.example.deltamail",
                    displayName: "Other"
                )
            ),
            artifactAvailability: .available
        )
        let bySourceFile = LibraryEntry(
            record: LibraryFixtures.record(
                identity: LibraryFixtures.identity(displayName: "Other"),
                sourceFileName: "delta-mail-2.0.ipa"
            ),
            artifactAvailability: .available
        )
        let unrelated = LibraryEntry(
            record: LibraryFixtures.record(identity: LibraryFixtures.identity(displayName: "Calendar")),
            artifactAvailability: .available
        )

        let visible = ApplicationLibraryModel.displayed(
            [byName, byBundleID, bySourceFile, unrelated],
            matching: "delta",
            sortedBy: .recentlyImported
        )

        XCTAssertEqual(Set(visible.map { $0.record.id }), Set([byName.record.id, byBundleID.record.id, bySourceFile.record.id]))
    }

    func testAnEmptyOrWhitespaceQueryMatchesEverything() {
        let entries = [
            LibraryEntry(record: LibraryFixtures.record(), artifactAvailability: .available),
        ]

        XCTAssertEqual(ApplicationLibraryModel.displayed(entries, matching: "", sortedBy: .name), entries)
        XCTAssertEqual(ApplicationLibraryModel.displayed(entries, matching: "   ", sortedBy: .name), entries)
    }

    // MARK: - Ordering

    func testRecentlyImportedPutsTheNewestRecordFirst() {
        let older = LibraryEntry(
            record: LibraryFixtures.record(identity: LibraryFixtures.identity(displayName: "Older")),
            artifactAvailability: .available
        )
        let newer = LibraryEntry(
            record: LibraryFixtures.record(
                identity: LibraryFixtures.identity(displayName: "Newer"),
                importedAt: LibraryFixtures.laterDate
            ),
            artifactAvailability: .available
        )

        let ordered = ApplicationLibraryModel.ordered([older, newer], by: .recentlyImported)

        XCTAssertEqual(ordered.map { $0.record.displayName }, ["Newer", "Older"])
    }

    func testNameOrderSortsCaseInsensitivelyAndDeterministically() {
        let zebra = LibraryEntry(
            record: LibraryFixtures.record(identity: LibraryFixtures.identity(
                bundleIdentifier: "com.example.zebra",
                displayName: "zebra"
            )),
            artifactAvailability: .available
        )
        let alpha = LibraryEntry(
            record: LibraryFixtures.record(identity: LibraryFixtures.identity(
                bundleIdentifier: "com.example.alpha",
                displayName: "Alpha"
            )),
            artifactAvailability: .available
        )
        let unnamed = LibraryEntry(
            record: LibraryFixtures.record(identity: LibraryFixtures.identity(
                bundleIdentifier: "zzz.example.anonymous",
                displayName: nil
            )),
            artifactAvailability: .available
        )

        let ordered = ApplicationLibraryModel.ordered([zebra, unnamed, alpha], by: .name)

        // Alpha, then zebra (case-insensitive), then the unnamed entry under
        // its bundle identifier.
        XCTAssertEqual(ordered.map { $0.record.displayName }, ["Alpha", "zebra", nil])
    }

    func testVersionOrderSortsTheWayPeopleReadVersions() {
        let two = LibraryEntry(
            record: LibraryFixtures.record(identity: LibraryFixtures.identity(
                bundleIdentifier: "com.example.two",
                displayName: "Two",
                shortVersion: "2.0"
            )),
            artifactAvailability: .available
        )
        let ten = LibraryEntry(
            record: LibraryFixtures.record(identity: LibraryFixtures.identity(
                bundleIdentifier: "com.example.ten",
                displayName: "Ten",
                shortVersion: "10.0"
            )),
            artifactAvailability: .available
        )

        let ordered = ApplicationLibraryModel.ordered([two, ten], by: .version)

        // Numeric reading: 10.0 above 2.0, not "10" before "2" as text.
        XCTAssertEqual(ordered.map { $0.record.identity.shortVersionString }, ["10.0", "2.0"])
    }

    // MARK: - Favourites

    func testSettingAFavouriteThroughTheModelPersistsAndRefreshes() async throws {
        let record = LibraryFixtures.record(identity: LibraryFixtures.identity(displayName: "First"))
        try await records.insert(record)
        artifacts.hold(Data(count: record.artifact.byteCount), as: record.artifact.artifactID)
        await model.load()

        guard case .loaded(let entries) = model.phase, let entry = entries.first else {
            return XCTFail("Expected a loaded phase, got \(model.phase)")
        }
        await model.setFavorite(true, on: entry)

        let stored = try await records.record(withID: record.id)
        XCTAssertEqual(stored?.isFavorite, true)
        guard case .loaded(let refreshed) = model.phase, let refreshedEntry = refreshed.first else {
            return XCTFail("Expected a re-read after the change, got \(model.phase)")
        }
        XCTAssertEqual(refreshedEntry.record.isFavorite, true)
    }

    // MARK: - Signing state

    /// A signing journal double returning fixed records.
    private struct SyntheticSigningHistoryStore: SigningHistoryStore {
        var recordsToReturn: [SigningRecord] = []
        var capacity: Int { 100 }
        func allRecords() async throws -> [SigningRecord] { recordsToReturn }
        func records(forPreset presetID: PresetIdentifier) async throws -> [SigningRecord] { [] }
        func append(_ record: SigningRecord) async throws {}
        func remove(recordWithID id: SigningRecordIdentifier) async throws {}
        func clear() async throws {}
        func count() async throws -> Int { recordsToReturn.count }
    }

    func testAPackageProblemOutranksTheSigningJournal() {
        let entry = LibraryEntry(
            record: LibraryFixtures.record(),
            artifactAvailability: .missing
        )

        XCTAssertEqual(model.signingState(for: entry), .packageProblem)
    }

    func testTheSigningJournalMarksSignedApplications() async throws {
        let record = LibraryFixtures.record(identity: LibraryFixtures.identity(displayName: "First"))
        try await records.insert(record)
        artifacts.hold(Data(count: record.artifact.byteCount), as: record.artifact.artifactID)
        let signed = SigningRecord(
            presetID: nil,
            certificateFingerprint: nil,
            sourceBundleIdentifier: record.bundleIdentifier.rawValue,
            sourceDisplayName: record.displayName,
            stoppingStage: "verification",
            errorCode: nil,
            outputFileName: "First_signed.ipa",
            outputByteCount: 1_024,
            startedAt: LibraryFixtures.laterDate,
            duration: 1
        )
        let modelWithJournal = ApplicationLibraryModel(
            library: library,
            importing: importing,
            signingHistory: SyntheticSigningHistoryStore(recordsToReturn: [signed])
        )
        await modelWithJournal.load()

        let entry = LibraryEntry(record: record, artifactAvailability: .available)
        XCTAssertEqual(modelWithJournal.signingState(for: entry), .signed)
        XCTAssertEqual(model.signingState(for: entry), .notSigned)
    }

    // MARK: - Bulk removal

    func testBulkRemovalRemovesEverySelectedEntry() async throws {
        let first = LibraryFixtures.record(identity: LibraryFixtures.identity(displayName: "First"))
        let second = LibraryFixtures.record(
            identity: LibraryFixtures.identity(bundleIdentifier: "com.example.second", displayName: "Second"),
            artifact: LibraryFixtures.reference(fingerprintSeed: 0x01),
            importedAt: LibraryFixtures.laterDate
        )
        try await records.insert(first)
        try await records.insert(second)
        artifacts.hold(Data(count: first.artifact.byteCount), as: first.artifact.artifactID)
        artifacts.hold(Data(count: second.artifact.byteCount), as: second.artifact.artifactID)
        await model.load()

        await model.removeEntries([
            LibraryEntry(record: first, artifactAvailability: .available),
            LibraryEntry(record: second, artifactAvailability: .available),
        ])

        let remaining = try await records.allRecords()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertNil(model.notice)
    }
}
