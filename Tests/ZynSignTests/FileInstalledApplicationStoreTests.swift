import XCTest
@testable import ZynSign

/// Tests for the file-backed installed-applications store: round-trips,
/// orders, the record capacity trim, the attempts cap, byte measurement,
/// and the unreadable-catalog refusal.
final class FileInstalledApplicationStoreTests: XCTestCase {

    private var root: URL!
    private var location: URL!
    private var store: FileInstalledApplicationStore!

    override func setUpWithError() throws {
        root = try LibraryFixtures.makeTemporaryDirectory()
        location = root.appendingPathComponent("InstalledApplications.json", isDirectory: false)
        store = FileInstalledApplicationStore(catalogLocation: location, capacity: 3)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        store = nil
        location = nil
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Records

    func testMissingCatalogReadsAsEmpty() async throws {
        let records = try await store.allRecords()
        let attempts = try await store.allAttempts()
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(attempts.isEmpty)
    }

    func testRecordRoundTripKeepsEveryFact() async throws {
        let original = InstallationFixtures.installedRecord(
            exportIdentifier: ExportIdentifier().rawValue
        )
        try await store.write(original)

        let reloaded = FileInstalledApplicationStore(catalogLocation: location, capacity: 3)
        let records = try await reloaded.allRecords()

        XCTAssertEqual(records, [original])
    }

    func testRecordsComeBackMostRecentlyUpdatedFirst() async throws {
        let older = InstallationFixtures.installedRecord(
            bundleIdentifier: "com.example.older",
            exportedAt: InstallationFixtures.lastMonth
        )
        let newer = InstallationFixtures.installedRecord(
            bundleIdentifier: "com.example.newer",
            exportedAt: InstallationFixtures.lastWeek
        )
        try await store.write(older)
        try await store.write(newer)

        let records = try await store.allRecords()

        XCTAssertEqual(records.map(\.bundleIdentifier), ["com.example.newer", "com.example.older"])
    }

    func testWritingWithTheSameIdentifierReplacesInPlace() async throws {
        let original = InstallationFixtures.installedRecord()
        try await store.write(original)
        let renamed = original.renaming(to: "Renamed", now: InstallationFixtures.now)
        try await store.write(renamed)

        let records = try await store.allRecords()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.displayName, "Renamed")
    }

    func testCapacityTrimsTheLeastRecentlyUpdated() async throws {
        for index in 0..<5 {
            let record = InstallationFixtures.installedRecord(
                bundleIdentifier: "com.example.\(index)",
                exportedAt: InstallationFixtures.lastMonth.addingTimeInterval(TimeInterval(index) * 60)
            )
            try await store.write(record)
        }

        let records = try await store.allRecords()

        XCTAssertEqual(records.count, 3, "The store keeps its capacity, newest first.")
        XCTAssertEqual(records.map(\.bundleIdentifier), [
            "com.example.4", "com.example.3", "com.example.2",
        ])
    }

    // MARK: - Attempts

    func testAttemptsComeBackOldestFirstAndSurviveRelaunchUnresolved() async throws {
        let first = InstallationFixtures.attempt(
            bundleIdentifier: "com.example.first",
            startedAt: InstallationFixtures.lastMonth
        )
        let second = InstallationFixtures.attempt(
            bundleIdentifier: "com.example.second",
            startedAt: InstallationFixtures.lastWeek
        )
        try await store.write(first)
        try await store.write(second)

        // A fresh store over the same file is the relaunch.
        let reloaded = FileInstalledApplicationStore(catalogLocation: location, capacity: 3)
        let attempts = try await reloaded.allAttempts()

        XCTAssertEqual(attempts.map(\.bundleIdentifier), ["com.example.first", "com.example.second"])
        XCTAssertTrue(
            attempts.allSatisfy { $0.intent == .installed },
            "An attempt restored from disk is exactly as pending as it was — nothing resolves it."
        )
    }

    func testAttemptRemovalIsANoOpForUnknownIdentifiers() async throws {
        try await store.removeAttempt(withID: InstallationEventIdentifier())
        let attempts = try await store.allAttempts()
        XCTAssertTrue(attempts.isEmpty)
    }

    // MARK: - Measurement and refusal

    func testStoredByteCountMeasuresTheCatalog() async throws {
        let byteCount = await store.storedByteCount()
        XCTAssertNil(byteCount, "No catalog yet, no measurement.")
        try await store.write(InstallationFixtures.installedRecord())
        let bytes = await store.storedByteCount()
        XCTAssertEqual(bytes ?? 0, try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1)
    }

    func testUnrecognizableCatalogIsRefusedNotSilentlyEmptied() async throws {
        try Data("not a catalog".utf8).write(to: location)

        do {
            _ = try await store.allRecords()
            XCTFail("An unrecognizable catalog must be refused, not read as empty.")
        } catch let error as ZynSignError {
            XCTAssertFalse(error.userMessage.isEmpty)
        }
    }
}
