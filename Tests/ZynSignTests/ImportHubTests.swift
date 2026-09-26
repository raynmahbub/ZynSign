import Combine
import XCTest
@testable import ZynSign

/// Tests for the Smart Import Hub's orchestration: the single entry point,
/// independent items, bounded concurrency, the preview gate, collected
/// conflicts, archives, the summary, history, recovery, and background
/// pauses.
///
/// The hub runs over a scripted `ImportProcessing`, so each test states what
/// every file will do; the real workflow beneath it is covered by
/// `ImportWorkflowTests`.
@MainActor
final class ImportHubTests: XCTestCase {

    private var processing: SyntheticImportProcessing!
    private var history: InMemoryImportHistoryStore!
    private var journal: InMemoryImportRecoveryJournal!
    private var background: SyntheticBackgroundExecution!
    private var released: [URL] = []
    private var hub: ImportHub!

    override func setUp() {
        super.setUp()
        processing = SyntheticImportProcessing()
        history = InMemoryImportHistoryStore()
        journal = InMemoryImportRecoveryJournal()
        background = SyntheticBackgroundExecution()
        released = []
        hub = makeHub()
    }

    override func tearDown() {
        hub?.cancelAll()
        hub = nil
        processing = nil
        history = nil
        journal = nil
        background = nil
        super.tearDown()
    }

    private func makeHub(
        maximumConcurrentPreparations: Int = 2,
        now: @escaping () -> Date = { Date() }
    ) -> ImportHub {
        ImportHub(
            processing: processing,
            history: history,
            recoveryJournal: journal,
            backgroundExecution: background,
            releaseSource: { [weak self] url in self?.released.append(url) },
            maximumConcurrentPreparations: maximumConcurrentPreparations,
            progressInterval: 0,
            now: now
        )
    }

    private func item(named name: String) -> ImportHub.Item? {
        hub.items.first { $0.fileName == name }
    }

    private func receive(_ names: String..., origin: ImportOrigin = .documentPicker) -> [ImportJobIdentifier] {
        hub.receive(names.map(ImportHubFixtures.sourceURL), origin: origin)
    }

    private func waitUntilReady(_ names: String...) async {
        await waitUntil("\(names) never became ready.") {
            names.allSatisfy { name in self.item(named: name)?.isReady == true }
        }
    }

    private func waitUntilSettled(_ names: String...) async {
        await waitUntil("\(names) never settled.") {
            names.allSatisfy { name in self.item(named: name)?.settlement != nil }
        }
    }

    private func existingRecord(version: String, build: String = "1", seed: UInt8 = 0xEE) -> ApplicationRecord {
        LibraryFixtures.record(
            identity: LibraryFixtures.identity(shortVersion: version, build: build),
            artifact: LibraryFixtures.reference(fingerprintSeed: seed)
        )
    }

    // MARK: - One entry point, independent items

    func testEveryReceivedFileBecomesItsOwnItemInArrivalOrder() {
        processing.scriptStage("A.ipa", .waitsForRelease)
        processing.scriptStage("B.ipa", .waitsForRelease)
        processing.scriptStage("C.ipa", .waitsForRelease)

        let identifiers = receive("A.ipa", "B.ipa", "C.ipa")

        XCTAssertEqual(identifiers.count, 3)
        XCTAssertEqual(hub.items.map(\.fileName), ["A.ipa", "B.ipa", "C.ipa"])
        XCTAssertEqual(hub.items.map(\.id), identifiers)
        XCTAssertEqual(Set(hub.items.map(\.batchID)).count, 1, "Files that arrive together form one batch.")
        XCTAssertTrue(hub.items.allSatisfy { $0.origin == .documentPicker })
    }

    func testNonFileURLsAreIgnored() {
        let identifiers = hub.receive([URL(string: "https://example.com/App.ipa")!], origin: .shareSheet)
        XCTAssertTrue(identifiers.isEmpty)
        XCTAssertTrue(hub.items.isEmpty)
    }

    func testAtMostTheConfiguredNumberOfItemsPrepareAtOnce() async {
        for name in ["A.ipa", "B.ipa", "C.ipa"] {
            processing.scriptStage(name, .waitsForRelease)
        }
        _ = receive("A.ipa", "B.ipa", "C.ipa")

        await waitUntil { self.processing.stagedNames.count == 2 }
        XCTAssertEqual(hub.items.filter(\.isPreparing).count, 2)
        XCTAssertEqual(item(named: "C.ipa")?.phase, .waiting)
        XCTAssertEqual(item(named: "C.ipa")?.stage, .waiting)

        processing.release("A.ipa")
        await waitUntil("The third item never started.") { self.processing.stagedNames.count == 3 }
        processing.release("B.ipa")
        processing.release("C.ipa")
        await waitUntilReady("A.ipa", "B.ipa", "C.ipa")
        XCTAssertLessThanOrEqual(processing.maximumConcurrentStages, 2)
    }

    func testAFailureDoesNotStopTheOtherItems() async {
        processing.scriptStage("Broken.ipa", .fails(ZynSignError.selectedFileUnavailable()))
        _ = receive("Broken.ipa", "Good.ipa")

        await waitUntilSettled("Broken.ipa")
        await waitUntilReady("Good.ipa")
        XCTAssertEqual(item(named: "Broken.ipa")?.stage, .failed)
        XCTAssertEqual(item(named: "Broken.ipa")?.settlement?.kind, .failed)
        XCTAssertEqual(item(named: "Good.ipa")?.stage, .analyzing)
    }

    func testProgressIsDeliveredMonotonicallyAndDrivesTheStage() async {
        processing.scriptStage("A.ipa", .succeeds(progress: [
            ImportProgress(stage: .copying, completedUnitCount: 0, totalUnitCount: 100),
            ImportProgress(stage: .copying, completedUnitCount: 50, totalUnitCount: 100),
            ImportProgress(stage: .copying, completedUnitCount: 100, totalUnitCount: 100),
        ]))
        var fractions: [Double] = []
        let observation = hub.$items.sink { items in
            if let fraction = items.first?.fractionCompleted { fractions.append(fraction) }
        }
        _ = receive("A.ipa")
        await waitUntilReady("A.ipa")
        observation.cancel()

        XCTAssertEqual(fractions, fractions.sorted(), "Progress must never move backwards.")
        XCTAssertGreaterThan(item(named: "A.ipa")?.fractionCompleted ?? 0, 0.5)
        XCTAssertLessThan(item(named: "A.ipa")?.fractionCompleted ?? 1, 1, "A package waiting in the preview is not complete.")
    }

    // MARK: - Preview

    func testAnalyzedPackagesWaitInThePreviewUntilTheUserImports() async throws {
        _ = receive("A.ipa")
        await waitUntilReady("A.ipa")

        let ready = try XCTUnwrap(item(named: "A.ipa"))
        XCTAssertTrue(ready.isSelected, "Ready packages start selected.")
        XCTAssertEqual(ready.identity?.bundleIdentifier.rawValue, "com.example.synthetic")
        XCTAssertEqual(ready.prepared?.analysis.frameworkCount, 3)
        XCTAssertTrue(processing.admitted.isEmpty, "Nothing is stored before the user confirms.")

        hub.importSelected()
        await waitUntilSettled("A.ipa")
        XCTAssertEqual(item(named: "A.ipa")?.settlement?.kind, .imported)
        XCTAssertEqual(item(named: "A.ipa")?.stage, .complete)
        XCTAssertEqual(processing.admitted.map { $0.fileName }, ["A.ipa"])
    }

    func testDeselectedPackagesAreSkippedAndTheirWorkingCopiesDiscarded() async throws {
        _ = receive("Keep.ipa", "Drop.ipa")
        await waitUntilReady("Keep.ipa", "Drop.ipa")
        let dropped = try XCTUnwrap(item(named: "Drop.ipa")?.staged?.artifactID)

        hub.setSelected(false, for: try XCTUnwrap(item(named: "Drop.ipa")?.id))
        hub.importSelected()
        await waitUntilSettled("Keep.ipa", "Drop.ipa")

        XCTAssertEqual(item(named: "Drop.ipa")?.settlement?.kind, .skipped)
        XCTAssertEqual(item(named: "Keep.ipa")?.settlement?.kind, .imported)
        XCTAssertEqual(processing.admitted.map { $0.fileName }, ["Keep.ipa"])
        XCTAssertTrue(processing.discarded.contains(dropped))
    }

    func testImportingWithNothingSelectedDoesNothing() async throws {
        _ = receive("A.ipa")
        await waitUntilReady("A.ipa")
        hub.deselectAllReady()

        XCTAssertFalse(hub.canImportSelected)
        hub.importSelected()
        XCTAssertEqual(item(named: "A.ipa")?.phase, .ready, "Importing nothing must not skip anything either.")
    }

    func testImportsAreStoredOneAtATimeInOrder() async {
        _ = receive("A.ipa", "B.ipa", "C.ipa")
        await waitUntilReady("A.ipa", "B.ipa", "C.ipa")

        hub.importSelected()
        await waitUntilSettled("A.ipa", "B.ipa", "C.ipa")
        XCTAssertEqual(processing.admitted.map { $0.fileName }, ["A.ipa", "B.ipa", "C.ipa"])
    }

    func testIdenticalContentArrivingTwiceIsNotSelectedTwice() async {
        processing.scriptExamine("First.ipa", .package(identity: LibraryFixtures.identity(), fingerprintSeed: 0x42, existing: []))
        processing.scriptExamine("Copy.ipa", .package(identity: LibraryFixtures.identity(), fingerprintSeed: 0x42, existing: []))
        _ = receive("First.ipa")
        await waitUntilReady("First.ipa")
        _ = receive("Copy.ipa")
        await waitUntilReady("Copy.ipa")

        XCTAssertEqual(item(named: "Copy.ipa")?.note, .sameContent(as: "First.ipa"))
        XCTAssertEqual(item(named: "Copy.ipa")?.isSelected, false)
        XCTAssertEqual(item(named: "First.ipa")?.isSelected, true)
    }

    // MARK: - Conflicts

    func testConflictsAreCollectedAndBlockImportingUntilEachIsResolved() async throws {
        let existing = existingRecord(version: "1.2", build: "34")
        processing.scriptExamine("Newer.ipa", .package(identity: LibraryFixtures.identity(shortVersion: "1.3", build: "40"), fingerprintSeed: 0x01, existing: [existing]))
        processing.scriptExamine("Rebuild.ipa", .package(identity: LibraryFixtures.identity(shortVersion: "1.2", build: "34"), fingerprintSeed: 0x02, existing: [existing]))
        _ = receive("Newer.ipa", "Rebuild.ipa")
        await waitUntilReady("Newer.ipa", "Rebuild.ipa")

        // Both conflicts wait together; neither interrupted the other.
        XCTAssertEqual(hub.conflictItems.count, 2)
        XCTAssertEqual(hub.unresolvedConflictCount, 2)
        XCTAssertFalse(hub.canImportSelected)
        hub.importSelected()
        XCTAssertTrue(processing.admitted.isEmpty, "Nothing may be stored while a conflict is unresolved.")

        let newer = try XCTUnwrap(item(named: "Newer.ipa"))
        XCTAssertEqual(newer.conflict?.relation, .newerVersion)
        XCTAssertEqual(newer.conflict?.suggestion, .replaceExisting)
        XCTAssertNil(newer.resolution, "A suggestion is never applied without the user.")
        XCTAssertEqual(item(named: "Rebuild.ipa")?.conflict?.relation, .sameVersion)
        XCTAssertNil(item(named: "Rebuild.ipa")?.conflict?.suggestion, "Same version: the user decides.")

        hub.resolve(newer.id, with: .replaceExisting)
        XCTAssertFalse(hub.canImportSelected)
        hub.resolve(try XCTUnwrap(item(named: "Rebuild.ipa")?.id), with: .keepBoth)
        XCTAssertTrue(hub.canImportSelected)

        hub.importSelected()
        await waitUntilSettled("Newer.ipa", "Rebuild.ipa")
        XCTAssertEqual(item(named: "Newer.ipa")?.settlement?.kind, .replaced)
        XCTAssertEqual(item(named: "Rebuild.ipa")?.settlement?.kind, .keptBoth)
        XCTAssertEqual(processing.admitted.map { $0.resolution }, [.replaceExisting, .keepBoth])
    }

    func testApplyToAllResolvesEverySelectedConflict() async {
        let existing = existingRecord(version: "1.0")
        processing.scriptExamine("A.ipa", .package(identity: LibraryFixtures.identity(shortVersion: "2.0"), fingerprintSeed: 0x01, existing: [existing]))
        processing.scriptExamine("B.ipa", .package(identity: LibraryFixtures.identity(shortVersion: "0.9"), fingerprintSeed: 0x02, existing: [existing]))
        _ = receive("A.ipa", "B.ipa")
        await waitUntilReady("A.ipa", "B.ipa")

        hub.applyToAllConflicts(.skip)
        XCTAssertEqual(hub.conflictItems.map(\.resolution), [.skip, .skip])
        XCTAssertEqual(hub.unresolvedConflictCount, 0)

        hub.importSelected()
        await waitUntilSettled("A.ipa", "B.ipa")
        XCTAssertEqual(hub.summary.count(of: .skipped), 2)
        XCTAssertEqual(hub.summary.count(of: .imported), 0)
    }

    func testUseSuggestionsAppliesOnlyWhereTheRulesSuggestSomething() async {
        let existing = existingRecord(version: "1.0")
        processing.scriptExamine("Newer.ipa", .package(identity: LibraryFixtures.identity(shortVersion: "2.0"), fingerprintSeed: 0x01, existing: [existing]))
        processing.scriptExamine("Unknown.ipa", .package(identity: LibraryFixtures.identity(shortVersion: nil, build: nil), fingerprintSeed: 0x02, existing: [existing]))
        _ = receive("Newer.ipa", "Unknown.ipa")
        await waitUntilReady("Newer.ipa", "Unknown.ipa")

        hub.applySuggestions()
        XCTAssertEqual(item(named: "Newer.ipa")?.resolution, .replaceExisting)
        XCTAssertNil(item(named: "Unknown.ipa")?.resolution)
        XCTAssertEqual(hub.unresolvedConflictCount, 1)
    }

    func testAConflictOnADeselectedPackageDoesNotBlockTheOthers() async throws {
        let existing = existingRecord(version: "1.0")
        processing.scriptExamine("Conflict.ipa", .package(identity: LibraryFixtures.identity(shortVersion: "1.0", build: "1"), fingerprintSeed: 0x03, existing: [existing]))
        _ = receive("Conflict.ipa", "Clean.ipa")
        await waitUntilReady("Conflict.ipa", "Clean.ipa")
        XCTAssertFalse(hub.canImportSelected)

        hub.setSelected(false, for: try XCTUnwrap(item(named: "Conflict.ipa")?.id))
        XCTAssertTrue(hub.canImportSelected)
    }

    // MARK: - Summary

    func testTheSummaryCountsImportedSkippedReplacedAndFailed() async throws {
        let existing = existingRecord(version: "1.0")
        processing.scriptExamine("Replace.ipa", .package(identity: LibraryFixtures.identity(shortVersion: "2.0"), fingerprintSeed: 0x01, existing: [existing]))
        processing.scriptStage("Broken.ipa", .fails(ImportFailure.corruptedArchive()))
        _ = receive("New.ipa", "Skip.ipa", "Replace.ipa", "Broken.ipa")
        await waitUntilReady("New.ipa", "Skip.ipa", "Replace.ipa")
        await waitUntilSettled("Broken.ipa")

        hub.setSelected(false, for: try XCTUnwrap(item(named: "Skip.ipa")?.id))
        hub.resolve(try XCTUnwrap(item(named: "Replace.ipa")?.id), with: .replaceExisting)
        hub.importSelected()
        await waitUntilSettled("New.ipa", "Skip.ipa", "Replace.ipa")

        let summary = hub.summary
        XCTAssertEqual(summary.count(of: .imported), 1)
        XCTAssertEqual(summary.count(of: .skipped), 1)
        XCTAssertEqual(summary.count(of: .replaced), 1)
        XCTAssertEqual(summary.count(of: .failed), 1)
        XCTAssertEqual(summary.settledCount, 4)
        XCTAssertEqual(item(named: "Broken.ipa")?.settlement?.failure?.message, ImportFailure.corruptedArchive().message)
    }

    // MARK: - Cancel and retry

    func testCancellingAWaitingItemSettlesItWithoutStarting() async throws {
        let hub = makeHub(maximumConcurrentPreparations: 1)
        self.hub = hub
        processing.scriptStage("A.ipa", .waitsForRelease)
        _ = receive("A.ipa", "B.ipa")
        await waitUntil { self.processing.stagedNames == ["A.ipa"] }

        hub.cancel(try XCTUnwrap(item(named: "B.ipa")?.id))

        XCTAssertEqual(item(named: "B.ipa")?.settlement?.kind, .cancelled)
        processing.release("A.ipa")
        await waitUntilReady("A.ipa")
        XCTAssertEqual(processing.stagedNames, ["A.ipa"], "A cancelled item never starts.")
    }

    func testCancellingARunningItemStopsItAtOnce() async throws {
        processing.scriptStage("Slow.ipa", .waitsForRelease)
        _ = receive("Slow.ipa")
        await waitUntil { self.item(named: "Slow.ipa")?.phase == .preparing }

        hub.cancel(try XCTUnwrap(item(named: "Slow.ipa")?.id))

        XCTAssertEqual(item(named: "Slow.ipa")?.settlement?.kind, .cancelled)
        XCTAssertFalse(hub.isBusy)
        // The task winds down without resurrecting the item.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(item(named: "Slow.ipa")?.settlement?.kind, .cancelled)
    }

    func testCancellingAReadyItemDiscardsItsWorkingCopy() async throws {
        _ = receive("A.ipa")
        await waitUntilReady("A.ipa")
        let copy = try XCTUnwrap(item(named: "A.ipa")?.staged?.artifactID)

        hub.cancel(try XCTUnwrap(item(named: "A.ipa")?.id))

        XCTAssertEqual(item(named: "A.ipa")?.settlement?.kind, .cancelled)
        XCTAssertTrue(processing.discarded.contains(copy))
    }

    func testRetryStartsAFreshAttemptFromTheOriginalSource() async throws {
        processing.scriptStage("Flaky.ipa", .fails(ZynSignError.selectedFileUnavailable()))
        _ = receive("Flaky.ipa")
        await waitUntilSettled("Flaky.ipa")
        let id = try XCTUnwrap(item(named: "Flaky.ipa")?.id)
        XCTAssertTrue(hub.canRetry(id))

        processing.scriptStage("Flaky.ipa", .succeeds(progress: []))
        hub.retry(id)
        await waitUntilReady("Flaky.ipa")

        XCTAssertEqual(item(named: "Flaky.ipa")?.id, id, "A retry keeps the item.")
        XCTAssertEqual(item(named: "Flaky.ipa")?.attempt, 1)
        XCTAssertEqual(processing.stagedNames, ["Flaky.ipa", "Flaky.ipa"])
    }

    func testFailedItemsOfferRetryAndSuccessfulOnesDoNot() async throws {
        processing.scriptExamine("Refused.ipa", .fails(ImportFailure.archiveHasNoPackages()))
        _ = receive("Refused.ipa", "Fine.ipa")
        await waitUntilSettled("Refused.ipa")
        await waitUntilReady("Fine.ipa")
        hub.importSelected()
        await waitUntilSettled("Fine.ipa")

        XCTAssertEqual(item(named: "Refused.ipa")?.settlement?.kind, .rejected)
        XCTAssertTrue(hub.canRetry(try XCTUnwrap(item(named: "Refused.ipa")?.id)))
        XCTAssertFalse(hub.canRetry(try XCTUnwrap(item(named: "Fine.ipa")?.id)))
    }

    func testInsufficientStorageIsAFailureThatCanBeRetried() async throws {
        let shortage = ImportFailure.insufficientStorage(requiredBytes: 900_000_000, availableBytes: 100_000_000)
        processing.scriptStage("Huge.ipa", .fails(shortage))
        _ = receive("Huge.ipa")
        await waitUntilSettled("Huge.ipa")

        let settled = try XCTUnwrap(item(named: "Huge.ipa"))
        XCTAssertEqual(settled.settlement?.kind, .failed)
        XCTAssertEqual(settled.settlement?.failure?.recovery, .freeStorage)
        XCTAssertTrue(hub.canRetry(settled.id))
    }

    // MARK: - Archives

    func testAnArchiveWaitsForTheUsersChoiceAndEachChosenPackageBecomesAnItem() async throws {
        let one = ImportHubFixtures.candidate("Apps/One.ipa")
        let two = ImportHubFixtures.candidate("Apps/Two.ipa")
        let three = ImportHubFixtures.candidate("Three.tipa")
        processing.scriptExamine("Bundle.zip", .archive([one, two, three]))
        _ = receive("Bundle.zip")
        await waitUntil { self.item(named: "Bundle.zip")?.isAwaitingSelection == true }
        let container = try XCTUnwrap(item(named: "Bundle.zip"))
        let containerCopy = try XCTUnwrap(container.staged?.artifactID)

        hub.extract([one, three], from: container.id)

        XCTAssertEqual(item(named: "Bundle.zip")?.phase, .unpacked(2))
        XCTAssertEqual(hub.items.map(\.fileName), ["Bundle.zip", "One.ipa", "Three.tipa"])
        XCTAssertEqual(item(named: "One.ipa")?.containerFileName, "Bundle.zip")
        XCTAssertEqual(item(named: "One.ipa")?.batchID, container.batchID)
        await waitUntilReady("One.ipa", "Three.tipa")
        XCTAssertTrue(processing.stagedSources.contains(.archiveEntry(container: containerCopy, candidate: one)))
        XCTAssertTrue(processing.stagedSources.contains(.archiveEntry(container: containerCopy, candidate: three)))
        XCTAssertFalse(processing.stagedSources.contains(.archiveEntry(container: containerCopy, candidate: two)))
    }

    func testTheArchiveWorkingCopyIsReleasedOnceItsPackagesAreHandled() async throws {
        let only = ImportHubFixtures.candidate("Only.ipa")
        processing.scriptExamine("Single.zip", .archive([only]))
        _ = receive("Single.zip")
        await waitUntil { self.item(named: "Single.zip")?.isAwaitingSelection == true }
        let containerCopy = try XCTUnwrap(item(named: "Single.zip")?.staged?.artifactID)

        hub.extract([only], from: try XCTUnwrap(item(named: "Single.zip")?.id))
        await waitUntilReady("Only.ipa")
        XCTAssertFalse(processing.discarded.contains(containerCopy), "The archive is kept while its package may still need it.")

        hub.importSelected()
        await waitUntilSettled("Only.ipa")
        XCTAssertTrue(processing.discarded.contains(containerCopy))
    }

    func testDecliningAnArchiveSkipsItAndDiscardsItsWorkingCopy() async throws {
        processing.scriptExamine("Bundle.zip", .archive([ImportHubFixtures.candidate("A.ipa"), ImportHubFixtures.candidate("B.ipa")]))
        _ = receive("Bundle.zip")
        await waitUntil { self.item(named: "Bundle.zip")?.isAwaitingSelection == true }
        let copy = try XCTUnwrap(item(named: "Bundle.zip")?.staged?.artifactID)

        hub.declineArchive(try XCTUnwrap(item(named: "Bundle.zip")?.id))

        XCTAssertEqual(item(named: "Bundle.zip")?.settlement?.kind, .skipped)
        XCTAssertTrue(processing.discarded.contains(copy))
    }

    func testAnArchiveWithNoPackagesFailsWithItsExplanation() async {
        processing.scriptExamine("Photos.zip", .fails(ImportFailure.archiveHasNoPackages()))
        _ = receive("Photos.zip")
        await waitUntilSettled("Photos.zip")

        XCTAssertEqual(item(named: "Photos.zip")?.settlement?.failure?.message, "The archive doesn't contain an application package (.ipa).")
    }

    // MARK: - History

    func testAFinishedBatchIsRecordedWithWhatHappenedToEachItem() async throws {
        processing.scriptStage("Broken.ipa", .fails(ImportFailure.corruptedArchive()))
        _ = receive("Good.ipa", "Broken.ipa")
        await waitUntilReady("Good.ipa")
        hub.importSelected()
        await waitUntilSettled("Good.ipa", "Broken.ipa")
        await hub.flushPendingWrites()

        let entry = try XCTUnwrap(hub.lastFinishedBatch)
        XCTAssertEqual(entry.origin, .documentPicker)
        XCTAssertEqual(entry.items.map(\.fileName), ["Good.ipa", "Broken.ipa"])
        XCTAssertEqual(entry.items.map(\.outcome), [.imported, .refused])
        XCTAssertEqual(entry.count(of: .imported), 1)
        XCTAssertEqual(entry.count(of: .failed), 1)
        XCTAssertNotNil(entry.items[0].recordID, "An imported app can be reopened.")
        XCTAssertEqual(entry.items[1].failureMessage, ImportFailure.corruptedArchive().message)
        XCTAssertEqual(hub.history.first?.id, entry.id)

        let stored = try await history.allEntries()
        XCTAssertEqual(stored.map(\.id), [entry.id])
    }

    func testABatchIsNotRecordedUntilEveryItemIsFinished() async {
        _ = receive("A.ipa", "B.ipa")
        await waitUntilReady("A.ipa", "B.ipa")
        XCTAssertNil(hub.lastFinishedBatch, "Items waiting in the preview are not finished.")
    }

    func testClearingTheHistoryEmptiesItEverywhere() async throws {
        _ = receive("A.ipa")
        await waitUntilReady("A.ipa")
        hub.importSelected()
        await waitUntilSettled("A.ipa")

        hub.clearHistory()
        await hub.flushPendingWrites()
        XCTAssertTrue(hub.history.isEmpty)
        let stored = try await history.allEntries()
        XCTAssertTrue(stored.isEmpty)
    }

    // MARK: - Recovery

    func testUnfinishedItemsAreJournaledAndFinishedOnesAreNot() async throws {
        _ = receive("A.ipa")
        await waitUntilReady("A.ipa")
        await hub.flushPendingWrites()

        var records = await journal.records
        XCTAssertEqual(records.map(\.fileName), ["A.ipa"])
        XCTAssertEqual(records.first?.stagedArtifactID, item(named: "A.ipa")?.staged?.artifactID.rawValue)

        hub.importSelected()
        await waitUntilSettled("A.ipa")
        await hub.flushPendingWrites()
        records = await journal.records
        XCTAssertTrue(records.isEmpty)
    }

    func testRestoringResumesSurvivingWorkingCopiesAndExplainsTheRest() async throws {
        let surviving = ArtifactIdentifier()
        let lost = ArtifactIdentifier()
        processing.keepWorkingCopy(surviving, byteCount: 4_096)
        journal = InMemoryImportRecoveryJournal(records: [
            ImportRecoveryRecord(itemID: UUID(), batchID: UUID(), fileName: "Resumed.ipa", origin: .openIn, enqueuedAt: Date(), stagedArtifactID: surviving.rawValue, containerFileName: nil),
            ImportRecoveryRecord(itemID: UUID(), batchID: UUID(), fileName: "Lost.ipa", origin: .shareSheet, enqueuedAt: Date(), stagedArtifactID: lost.rawValue, containerFileName: nil),
            ImportRecoveryRecord(itemID: UUID(), batchID: UUID(), fileName: "NeverCopied.ipa", origin: .documentPicker, enqueuedAt: Date(), stagedArtifactID: nil, containerFileName: nil),
        ])
        hub = makeHub()

        await hub.restoreInterruptedImports()
        await waitUntilReady("Resumed.ipa")

        XCTAssertFalse(processing.stagedNames.contains("Resumed.ipa"), "A surviving working copy is examined again, not copied again.")
        XCTAssertEqual(processing.examinedNames, ["Resumed.ipa"])
        XCTAssertEqual(item(named: "Resumed.ipa")?.origin, .openIn)
        XCTAssertEqual(item(named: "Lost.ipa")?.settlement?.failure, ImportFailure.interrupted(hadWorkingCopy: true))
        XCTAssertEqual(item(named: "NeverCopied.ipa")?.settlement?.failure, ImportFailure.interrupted(hadWorkingCopy: false))
        XCTAssertFalse(hub.canRetry(try XCTUnwrap(item(named: "Lost.ipa")?.id)), "There is no way back to an original after an interruption.")
        XCTAssertEqual(processing.sweptKeeping, [surviving])
    }

    func testRestoringHappensOnlyOnce() async {
        journal = InMemoryImportRecoveryJournal(records: [
            ImportRecoveryRecord(itemID: UUID(), batchID: UUID(), fileName: "Lost.ipa", origin: .documentPicker, enqueuedAt: Date(), stagedArtifactID: nil, containerFileName: nil),
        ])
        hub = makeHub()

        await hub.restoreInterruptedImports()
        await hub.restoreInterruptedImports()

        XCTAssertEqual(hub.items.map(\.fileName), ["Lost.ipa"])
    }

    // MARK: - Background

    func testWorkHoldsBackgroundTimeOnlyWhileItRuns() async {
        processing.scriptStage("A.ipa", .waitsForRelease)
        _ = receive("A.ipa")
        XCTAssertEqual(background.begun, 1)
        XCTAssertTrue(background.ended.isEmpty)

        processing.release("A.ipa")
        await waitUntilReady("A.ipa")
        XCTAssertEqual(background.ended.count, 1, "Waiting for the user does not hold background time.")
    }

    func testExpiredBackgroundTimePausesWorkUntilResumed() async {
        processing.scriptStage("A.ipa", .waitsForRelease)
        _ = receive("A.ipa")
        await waitUntil { self.item(named: "A.ipa")?.phase == .preparing }

        background.expire()
        await waitUntil { self.item(named: "A.ipa")?.phase == .waiting }
        XCTAssertTrue(hub.isPaused)
        XCTAssertEqual(background.ended.count, 1)
        XCTAssertNil(item(named: "A.ipa")?.settlement, "A pause is not a failure.")

        processing.release("A.ipa")
        hub.resume()
        await waitUntilReady("A.ipa")
        XCTAssertFalse(hub.isPaused)
        XCTAssertEqual(processing.stagedNames, ["A.ipa", "A.ipa"])
    }

    // MARK: - Arrivals

    func testOpenInArrivalsCloseTogetherShareABatch() {
        var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
        hub = makeHub(now: { clock })
        processing.scriptStage("A.ipa", .waitsForRelease)
        processing.scriptStage("B.ipa", .waitsForRelease)
        processing.scriptStage("C.ipa", .waitsForRelease)

        _ = receive("A.ipa", origin: .openIn)
        clock.addTimeInterval(1)
        _ = receive("B.ipa", origin: .openIn)
        clock.addTimeInterval(ImportHub.batchCoalescingInterval + 1)
        _ = receive("C.ipa", origin: .openIn)

        XCTAssertEqual(item(named: "A.ipa")?.batchID, item(named: "B.ipa")?.batchID)
        XCTAssertNotEqual(item(named: "B.ipa")?.batchID, item(named: "C.ipa")?.batchID)
    }

    func testDropsThatCouldNotBeReceivedAreStillAccountedFor() {
        hub.recordUnreceivedDrops(2)

        XCTAssertEqual(hub.items.count, 2)
        XCTAssertTrue(hub.items.allSatisfy { $0.settlement?.kind == .rejected && $0.origin == .dragAndDrop })
        XCTAssertFalse(hub.canRetry(hub.items[0].id))
    }

    func testFinishedDocumentSourcesAreReleased() async throws {
        _ = receive("A.ipa")
        await waitUntilReady("A.ipa")
        hub.importSelected()
        await waitUntilSettled("A.ipa")

        XCTAssertEqual(released, [ImportHubFixtures.sourceURL("A.ipa")])
    }

    func testClearingFinishedItemsKeepsTheRest() async throws {
        processing.scriptStage("Slow.ipa", .waitsForRelease)
        processing.scriptStage("Broken.ipa", .fails(ImportFailure.corruptedArchive()))
        _ = receive("Slow.ipa", "Broken.ipa")
        await waitUntilSettled("Broken.ipa")

        hub.clearFinished()

        XCTAssertEqual(hub.items.map(\.fileName), ["Slow.ipa"])
        processing.release("Slow.ipa")
    }
}
