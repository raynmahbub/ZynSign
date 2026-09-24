import XCTest
@testable import ZynSign

/// Tests for the local activity journal: the in-memory journal, the
/// file-backed journal, and the redaction contract of the event type.
///
/// The journal is on-device only by construction — nothing in these types
/// has a sender — so these tests pin the observable contract: recording,
/// recency order, counts, capacity pruning, corruption tolerance, clearing,
/// and persistence across instances.
final class LocalAnalyticsJournalTests: XCTestCase {

    private var workDirectory: URL!
    private var journalLocation: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDirectory = try LibraryFixtures.makeTemporaryDirectory()
        journalLocation = workDirectory.appendingPathComponent("events.jsonl", isDirectory: false)
    }

    override func tearDownWithError() throws {
        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        workDirectory = nil
        journalLocation = nil
        try super.tearDownWithError()
    }

    private func makeFileJournal(capacity: Int = 500) -> FileLocalAnalyticsJournal {
        FileLocalAnalyticsJournal(location: journalLocation, capacity: capacity)
    }

    private func makeEvent(
        category: LocalAnalyticsEvent.Category = .signing,
        name: String = "sign.succeeded",
        succeeded: Bool = true
    ) -> LocalAnalyticsEvent {
        LocalAnalyticsEvent(category: category, name: name, succeeded: succeeded)
    }

    // MARK: - In-memory journal

    func testInMemoryJournalRecordsAndCounts() {
        let journal = InMemoryLocalAnalyticsJournal()
        journal.record(makeEvent(category: .intake, name: "import.accepted"))
        journal.record(makeEvent(category: .signing, name: "sign.succeeded"))
        journal.record(makeEvent(category: .signing, name: "sign.refused", succeeded: false))

        let counts = journal.counts()
        XCTAssertEqual(counts.total, 3)
        XCTAssertEqual(counts.byCategory[.intake], 1)
        XCTAssertEqual(counts.byCategory[.signing], 2)
    }

    func testRecentEventsAreNewestFirst() {
        let journal = InMemoryLocalAnalyticsJournal()
        journal.record(makeEvent(name: "first"))
        journal.record(makeEvent(name: "second"))
        journal.record(makeEvent(name: "third"))

        let recent = journal.recentEvents(limit: 2)
        XCTAssertEqual(recent.map(\.name), ["third", "second"])
    }

    func testRecentEventsLimitLargerThanJournalReturnsAll() {
        let journal = InMemoryLocalAnalyticsJournal()
        journal.record(makeEvent(name: "only"))
        XCTAssertEqual(journal.recentEvents(limit: 50).map(\.name), ["only"])
        XCTAssertTrue(journal.recentEvents(limit: 0).isEmpty)
    }

    func testInMemoryJournalPrunesToCapacity() {
        let journal = InMemoryLocalAnalyticsJournal(capacity: 2)
        journal.record(makeEvent(name: "one"))
        journal.record(makeEvent(name: "two"))
        journal.record(makeEvent(name: "three"))

        XCTAssertEqual(journal.counts().total, 2)
        XCTAssertEqual(journal.recentEvents(limit: 10).map(\.name), ["three", "two"])
    }

    func testClearEmptiesTheJournal() {
        let journal = InMemoryLocalAnalyticsJournal()
        journal.record(makeEvent())
        journal.clear()
        XCTAssertEqual(journal.counts(), .empty)
    }

    // MARK: - File-backed journal

    func testFileJournalPersistsAcrossInstances() {
        let first = makeFileJournal()
        first.record(makeEvent(category: .delivery, name: "delivery.manifestGenerated"))
        first.record(makeEvent(category: .intake, name: "import.accepted"))

        let second = makeFileJournal()
        XCTAssertEqual(second.counts().total, 2)
        XCTAssertEqual(second.recentEvents(limit: 10).first?.category, .intake)
    }

    func testFileJournalPrunesToCapacity() {
        let journal = makeFileJournal(capacity: 3)
        for index in 1...5 {
            journal.record(makeEvent(name: "event-\(index)"))
        }
        XCTAssertEqual(journal.counts().total, 3)
        XCTAssertEqual(journal.recentEvents(limit: 10).map(\.name), ["event-5", "event-4", "event-3"])
    }

    func testFileJournalSkipsDamagedLines() throws {
        let journal = makeFileJournal()
        journal.record(makeEvent(name: "kept"))

        // Append a damaged line directly, as a damaged or partially written
        // file might contain.
        let handle = try FileHandle(forWritingTo: journalLocation)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))

        let reloaded = makeFileJournal()
        XCTAssertEqual(reloaded.counts().total, 1)
        XCTAssertEqual(reloaded.recentEvents(limit: 10).map(\.name), ["kept"])
    }

    func testClearRemovesTheJournalFile() throws {
        let journal = makeFileJournal()
        journal.record(makeEvent())
        journal.clear()
        XCTAssertEqual(journal.counts(), .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalLocation.path))
    }

    func testFileJournalRoundTripsEveryCategory() {
        let journal = makeFileJournal()
        for category in LocalAnalyticsEvent.Category.allCases {
            journal.record(makeEvent(category: category, name: "round.trip"))
        }
        let reloaded = makeFileJournal()
        XCTAssertEqual(reloaded.counts().total, LocalAnalyticsEvent.Category.allCases.count)
        let counts = reloaded.counts()
        for category in LocalAnalyticsEvent.Category.allCases {
            XCTAssertEqual(counts.byCategory[category], 1)
        }
    }

    func testReadingAMissingFileIsAnEmptyJournal() {
        XCTAssertEqual(makeFileJournal().counts(), .empty)
        XCTAssertTrue(makeFileJournal().recentEvents(limit: 5).isEmpty)
    }

    // MARK: - Event redaction contract

    func testEventEncodesExactlyTheDeclaredFields() throws {
        let event = makeEvent(succeeded: false)
        XCTAssertEqual(event.succeeded, false)
        XCTAssertFalse(event.name.isEmpty)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        // The persisted form carries exactly the five declared fields —
        // no room for a path, identifier, or free-form detail to hide.
        XCTAssertEqual(
            Set(object.keys),
            Set(["id", "date", "category", "name", "succeeded"])
        )
    }

    func testEveryCategoryHasAPresentationName() {
        var names: Set<String> = []
        for category in LocalAnalyticsEvent.Category.allCases {
            XCTAssertFalse(category.displayName.isEmpty)
            names.insert(category.displayName)
        }
        XCTAssertEqual(names.count, LocalAnalyticsEvent.Category.allCases.count)
    }
}
