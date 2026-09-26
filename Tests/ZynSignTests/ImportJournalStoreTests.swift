import XCTest
@testable import ZynSign

/// Filesystem tests for the import history store and the interrupted-import
/// journal, in a temporary directory the test owns.
final class ImportJournalStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZynSignImportJournalTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    private var historyLocation: URL {
        directory.appendingPathComponent("ImportHistory.json")
    }

    private var journalLocation: URL {
        directory.appendingPathComponent("ImportRecovery.json")
    }

    private func entry(finishedAt offset: TimeInterval, outcome: ImportHistoryEntry.Outcome = .imported) -> ImportHistoryEntry {
        let finished = Date(timeIntervalSinceReferenceDate: 800_000_000 + offset)
        return ImportHistoryEntry(
            id: ImportBatchIdentifier(),
            startedAt: finished.addingTimeInterval(-10),
            finishedAt: finished,
            origin: .dragAndDrop,
            items: [
                ImportHistoryEntry.Item(
                    id: UUID(),
                    fileName: "App.ipa",
                    outcome: outcome,
                    applicationName: "App",
                    bundleIdentifier: "com.example.app",
                    version: "1.0",
                    recordID: ApplicationRecordIdentifier().rawValue,
                    replacedCount: outcome == .replaced ? 1 : 0,
                    failureMessage: outcome == .failed ? "Something went wrong." : nil
                ),
            ]
        )
    }

    // MARK: - History

    func testAnEmptyHistoryHasNoEntries() async throws {
        let store = FileImportHistoryStore(location: historyLocation)
        let entries = try await store.allEntries()
        XCTAssertTrue(entries.isEmpty)
    }

    func testEntriesPersistNewestFirstAcrossStores() async throws {
        let older = entry(finishedAt: 0)
        let newer = entry(finishedAt: 60, outcome: .replaced)
        let store = FileImportHistoryStore(location: historyLocation)
        try await store.record(older)
        try await store.record(newer)

        let reopened = FileImportHistoryStore(location: historyLocation)
        let entries = try await reopened.allEntries()
        XCTAssertEqual(entries, [newer, older])
        XCTAssertEqual(entries.first?.count(of: .replaced), 1)
    }

    func testRecordingTheSameBatchAgainReplacesIt() async throws {
        let store = FileImportHistoryStore(location: historyLocation)
        let first = entry(finishedAt: 0, outcome: .failed)
        try await store.record(first)
        let retried = ImportHistoryEntry(
            id: first.id,
            startedAt: first.startedAt,
            finishedAt: first.finishedAt.addingTimeInterval(30),
            origin: first.origin,
            items: [entry(finishedAt: 30).items[0]]
        )
        try await store.record(retried)

        let entries = try await store.allEntries()
        XCTAssertEqual(entries, [retried])
    }

    func testTheHistoryIsBoundedToItsCapacity() async throws {
        let store = FileImportHistoryStore(location: historyLocation, capacity: 3)
        for offset in 0..<5 {
            try await store.record(entry(finishedAt: TimeInterval(offset)))
        }
        let entries = try await store.allEntries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.first?.finishedAt, Date(timeIntervalSinceReferenceDate: 800_000_004))
    }

    func testRemovingAndClearing() async throws {
        let store = FileImportHistoryStore(location: historyLocation)
        let keep = entry(finishedAt: 0)
        let drop = entry(finishedAt: 1)
        try await store.record(keep)
        try await store.record(drop)

        try await store.remove(entryWithID: drop.id)
        var entries = try await store.allEntries()
        XCTAssertEqual(entries, [keep])

        try await store.clear()
        entries = try await FileImportHistoryStore(location: historyLocation).allEntries()
        XCTAssertTrue(entries.isEmpty)
    }

    func testAnUnreadableHistoryIsReportedAndClearingStartsOver() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: historyLocation)
        let store = FileImportHistoryStore(location: historyLocation)

        do {
            _ = try await store.allEntries()
            XCTFail("An unreadable history must not read as empty.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .storageFailure)
        }

        try await store.clear()
        let entries = try await store.allEntries()
        XCTAssertTrue(entries.isEmpty)
    }

    func testTheHistoryStoresNoFileLocations() async throws {
        let store = FileImportHistoryStore(location: historyLocation)
        try await store.record(entry(finishedAt: 0))
        let text = try String(contentsOf: historyLocation, encoding: .utf8)
        XCTAssertFalse(text.contains("file://"))
        XCTAssertFalse(text.contains("/private/"))
    }

    // MARK: - Recovery journal

    private func record(staged: ArtifactIdentifier?) -> ImportRecoveryRecord {
        ImportRecoveryRecord(
            itemID: UUID(),
            batchID: UUID(),
            fileName: "App.ipa",
            origin: .openIn,
            enqueuedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            stagedArtifactID: staged?.rawValue,
            containerFileName: "Bundle.zip"
        )
    }

    func testTheJournalRoundTripsItsRecords() async throws {
        let records = [record(staged: ArtifactIdentifier()), record(staged: nil)]
        try await FileImportRecoveryJournal(location: journalLocation).replace(with: records)

        let read = try await FileImportRecoveryJournal(location: journalLocation).pendingRecords()
        XCTAssertEqual(read, records)
    }

    func testAnEmptyJournalLeavesNoFile() async throws {
        let journal = FileImportRecoveryJournal(location: journalLocation)
        try await journal.replace(with: [record(staged: nil)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalLocation.path))

        try await journal.replace(with: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalLocation.path))
        let read = try await journal.pendingRecords()
        XCTAssertTrue(read.isEmpty)
    }

    func testAnUnreadableJournalReadsAsEmpty() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0x00, 0x01]).write(to: journalLocation)
        let read = try await FileImportRecoveryJournal(location: journalLocation).pendingRecords()
        XCTAssertTrue(read.isEmpty)
    }
}
