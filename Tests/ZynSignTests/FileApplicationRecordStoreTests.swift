import XCTest
@testable import ZynSign

/// Filesystem-backed tests for the catalog-file record store.
///
/// Every test works in a temporary directory it creates and removes; no
/// application container, shared location, or real package is touched.
final class FileApplicationRecordStoreTests: XCTestCase {

    private var workDirectory: URL!
    private var catalogLocation: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDirectory = try LibraryFixtures.makeTemporaryDirectory()
        catalogLocation = workDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("catalog.json", isDirectory: false)
    }

    override func tearDownWithError() throws {
        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        workDirectory = nil
        catalogLocation = nil
        try super.tearDownWithError()
    }

    private func makeStore() -> FileApplicationRecordStore {
        FileApplicationRecordStore(catalogLocation: catalogLocation)
    }

    private func writeCatalog(_ text: String) throws {
        try FileManager.default.createDirectory(
            at: catalogLocation.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: catalogLocation)
    }

    private func catalogJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: catalogLocation)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - CRUD

    func testMissingCatalogIsAnEmptyLibrary() async throws {
        let store = makeStore()

        let records = try await store.allRecords()

        XCTAssertTrue(records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogLocation.path))
    }

    func testInsertedRecordIsFetchedByIdentifierAndListed() async throws {
        let store = makeStore()
        let record = LibraryFixtures.record()

        try await store.insert(record)

        let fetched = try await store.record(withID: record.id)
        let listed = try await store.allRecords()
        XCTAssertEqual(fetched, record)
        XCTAssertEqual(listed, [record])
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogLocation.path))
    }

    func testFetchingAnUnknownIdentifierReturnsNil() async throws {
        let store = makeStore()
        try await store.insert(LibraryFixtures.record())

        let fetched = try await store.record(withID: ApplicationRecordIdentifier())

        XCTAssertNil(fetched)
    }

    func testInsertingAnExistingIdentifierFailsWithoutChangingTheStoredRecord() async throws {
        let store = makeStore()
        let original = LibraryFixtures.record(sourceFileName: "Original.ipa")
        try await store.insert(original)
        let colliding = LibraryFixtures.record(id: original.id, sourceFileName: "Colliding.ipa")

        do {
            try await store.insert(colliding)
            XCTFail("Expected the conflicting insert to fail.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .internalFailure)
            XCTAssertEqual(error.userMessage, ZynSignError.libraryRecordConflict().userMessage)
        }

        let stored = try await store.record(withID: original.id)
        XCTAssertEqual(stored, original)
        let reopened = try await makeStore().record(withID: original.id)
        XCTAssertEqual(reopened, original)
    }

    func testUpdateReplacesTheRecordWithoutCreatingAnother() async throws {
        let store = makeStore()
        let original = LibraryFixtures.record()
        try await store.insert(original)
        let revised = LibraryFixtures.record(
            id: original.id,
            sourceFileName: "Renamed.ipa",
            artifact: original.artifact,
            updatedAt: LibraryFixtures.laterDate
        )

        try await store.update(revised)

        let listed = try await store.allRecords()
        XCTAssertEqual(listed, [revised])
        XCTAssertEqual(listed.first?.updatedAt, LibraryFixtures.laterDate)
    }

    func testUpdatingAnUnknownRecordFailsAndStoresNothing() async throws {
        let store = makeStore()

        do {
            try await store.update(LibraryFixtures.record())
            XCTFail("Expected the update to fail.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.userMessage, ZynSignError.libraryRecordNotFound().userMessage)
        }

        let listed = try await store.allRecords()
        XCTAssertTrue(listed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogLocation.path))
    }

    func testDeleteRemovesTheRecordAndIsIdempotent() async throws {
        let store = makeStore()
        let kept = LibraryFixtures.record(importedAt: LibraryFixtures.importDate)
        let removed = LibraryFixtures.record(importedAt: LibraryFixtures.laterDate)
        try await store.insert(kept)
        try await store.insert(removed)

        try await store.delete(recordWithID: removed.id)
        try await store.delete(recordWithID: removed.id)
        try await store.delete(recordWithID: ApplicationRecordIdentifier())

        let listed = try await store.allRecords()
        XCTAssertEqual(listed, [kept])
        let reopened = try await makeStore().allRecords()
        XCTAssertEqual(reopened, [kept])
    }

    func testRecordsAreListedInLibraryOrder() async throws {
        let store = makeStore()
        let late = LibraryFixtures.record(importedAt: LibraryFixtures.laterDate)
        let early = LibraryFixtures.record(importedAt: LibraryFixtures.importDate)
        try await store.insert(late)
        try await store.insert(early)

        let listed = try await store.allRecords()

        XCTAssertEqual(listed, [early, late])
    }

    // MARK: - Persistence across the lifecycle

    func testRecordsSurviveANewStoreOverTheSameCatalog() async throws {
        let record = LibraryFixtures.record(
            identity: LibraryFixtures.identity(displayName: "Persisted", shortVersion: "3.1", build: "77"),
            warningCodes: [.inconsistentMetadata]
        )
        try await makeStore().insert(record)

        // A new store instance over the same location is what a relaunch
        // produces: no shared memory, only the catalog file.
        let reopened = makeStore()
        let fetched = try await reopened.record(withID: record.id)
        let listed = try await reopened.allRecords()

        XCTAssertEqual(fetched, record)
        XCTAssertEqual(listed, [record])
    }

    func testEveryFieldRoundTripsIncludingUndeclaredValues() async throws {
        let sparse = LibraryFixtures.record(
            identity: LibraryFixtures.identity(displayName: nil, shortVersion: nil, build: nil),
            executableName: nil,
            sourceFileName: nil,
            artifact: LibraryFixtures.reference(byteCount: 0, fingerprintSeed: 0x00)
        )
        try await makeStore().insert(sparse)

        let fetched = try await makeStore().record(withID: sparse.id)

        XCTAssertEqual(fetched, sparse)
        XCTAssertNil(fetched?.identity.declaredDisplayName)
        XCTAssertNil(fetched?.identity.shortVersionString)
        XCTAssertNil(fetched?.executableName)
        XCTAssertNil(fetched?.sourceFileName)
    }

    // MARK: - Catalog document

    func testCatalogDeclaresTheCurrentSchemaVersionAndOnlyExpectedFields() async throws {
        let record = LibraryFixtures.record()
        try await makeStore().insert(record)

        let document = try catalogJSON()
        XCTAssertEqual(document["schemaVersion"] as? Int, LibraryCatalogDocument.currentSchemaVersion)
        XCTAssertEqual(LibraryCatalogDocument.currentSchemaVersion, 2)
        XCTAssertEqual(Set(document.keys), ["schemaVersion", "records"])

        let records = try XCTUnwrap(document["records"] as? [[String: Any]])
        XCTAssertEqual(records.count, 1)
        let stored = try XCTUnwrap(records.first)
        XCTAssertEqual(
            Set(stored.keys),
            [
                "recordID", "bundleIdentifier", "declaredDisplayName", "shortVersion", "buildVersion",
                "executableName", "sourceFileName", "artifactID", "artifactByteCount",
                "fingerprintAlgorithm", "fingerprintDigest", "inspectionClassification",
                "inspectionWarningCodes", "importedAt", "updatedAt", "isFavorite",
            ]
        )
        XCTAssertEqual(stored["recordID"] as? String, record.id.rawValue)
        XCTAssertEqual(stored["artifactID"] as? String, record.artifact.artifactID.rawValue)
        XCTAssertEqual(stored["fingerprintAlgorithm"] as? String, "sha256")
        XCTAssertEqual(stored["fingerprintDigest"] as? String, record.artifact.fingerprint.hexDigest)
        XCTAssertEqual(stored["inspectionClassification"] as? String, "valid")
        XCTAssertEqual(stored["isFavorite"] as? Bool, false)
    }

    func testStoredRecordRehydratesThroughDomainValidation() throws {
        let record = LibraryFixtures.record(warningCodes: [.inconsistentMetadata])

        let rehydrated = try StoredApplicationRecord(record).applicationRecord()

        XCTAssertEqual(rehydrated, record)
    }

    func testFavouriteMarkRoundTripsThroughTheCatalog() async throws {
        let store = makeStore()
        let record = LibraryFixtures.record().with(
            isFavorite: true,
            updatedAt: LibraryFixtures.laterDate
        )

        try await store.insert(record)
        let fetched = try await makeStore().record(withID: record.id)

        XCTAssertEqual(fetched, record)
        XCTAssertEqual(fetched?.isFavorite, true)
    }

    /// Schema 1 carried no favourite mark. The conversion at the read
    /// boundary is exactly that absence: every record reads as
    /// not-favourite, and the rest of the record is untouched.
    func testSchema1CatalogConvertsWithEveryRecordReadingAsNotFavourite() async throws {
        let record = LibraryFixtures.record()
        let stored: [String: Any] = [
            "recordID": record.id.rawValue,
            "bundleIdentifier": record.identity.bundleIdentifier.rawValue,
            "declaredDisplayName": record.identity.declaredDisplayName ?? "",
            "shortVersion": record.identity.shortVersionString ?? "",
            "buildVersion": record.identity.buildVersion ?? "",
            "executableName": record.executableName ?? "",
            "sourceFileName": record.sourceFileName ?? "",
            "artifactID": record.artifact.artifactID.rawValue,
            "artifactByteCount": record.artifact.byteCount,
            "fingerprintAlgorithm": "sha256",
            "fingerprintDigest": record.artifact.fingerprint.hexDigest,
            "inspectionClassification": record.inspection.classification.rawValue,
            "inspectionWarningCodes": [String](),
            "importedAt": record.importedAt.timeIntervalSinceReferenceDate,
            "updatedAt": record.updatedAt.timeIntervalSinceReferenceDate,
        ]
        let document: [String: Any] = ["schemaVersion": 1, "records": [stored]]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try FileManager.default.createDirectory(
            at: catalogLocation.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: catalogLocation)

        let fetched = try await makeStore().allRecords()

        XCTAssertEqual(fetched, [record])
        XCTAssertEqual(fetched.first?.isFavorite, false)
    }

    // MARK: - Damaged or foreign catalogs

    func testUnreadableCatalogFailsClosedAndIsLeftInPlace() async throws {
        try writeCatalog("this is not a catalog")
        let before = try Data(contentsOf: catalogLocation)
        let store = makeStore()

        await assertLibraryError(category: .storageFailure, message: ZynSignError.libraryCatalogUnreadable().userMessage) {
            _ = try await store.allRecords()
        }
        await assertLibraryError(category: .storageFailure, message: ZynSignError.libraryCatalogUnreadable().userMessage) {
            try await store.insert(LibraryFixtures.record())
        }

        let after = try Data(contentsOf: catalogLocation)
        XCTAssertEqual(after, before)
    }

    func testNewerSchemaIsRefusedAsUnsupportedAndLeftInPlace() async throws {
        let newer = LibraryCatalogDocument.currentSchemaVersion + 1
        try writeCatalog(#"{"schemaVersion": \#(newer), "records": [], "future": true}"#)
        let before = try Data(contentsOf: catalogLocation)
        let store = makeStore()

        await assertLibraryError(category: .capabilityUnavailable, message: ZynSignError.libraryCatalogUnsupported().userMessage) {
            _ = try await store.allRecords()
        }
        await assertLibraryError(category: .capabilityUnavailable, message: ZynSignError.libraryCatalogUnsupported().userMessage) {
            try await store.delete(recordWithID: ApplicationRecordIdentifier())
        }

        let after = try Data(contentsOf: catalogLocation)
        XCTAssertEqual(after, before)
    }

    func testUnknownOlderSchemaIsRefusedAsUnreadable() async throws {
        try writeCatalog(#"{"schemaVersion": 0, "records": []}"#)
        let store = makeStore()

        await assertLibraryError(category: .storageFailure, message: ZynSignError.libraryCatalogUnreadable().userMessage) {
            _ = try await store.allRecords()
        }
    }

    func testCatalogWithoutAVersionIsRefusedAsUnreadable() async throws {
        try writeCatalog(#"{"records": []}"#)
        let store = makeStore()

        await assertLibraryError(category: .storageFailure, message: ZynSignError.libraryCatalogUnreadable().userMessage) {
            _ = try await store.allRecords()
        }
    }

    func testRecordWithAValueTheDomainRejectsMakesTheCatalogUnreadable() async throws {
        let record = LibraryFixtures.record()
        try await makeStore().insert(record)
        var text = try String(contentsOf: catalogLocation, encoding: .utf8)
        text = text.replacingOccurrences(of: record.artifact.fingerprint.hexDigest, with: "not-a-digest")
        try writeCatalog(text)

        let store = makeStore()
        await assertLibraryError(category: .storageFailure, message: ZynSignError.libraryCatalogUnreadable().userMessage) {
            _ = try await store.allRecords()
        }
    }

    func testDuplicateIdentifiersInTheCatalogMakeItUnreadable() async throws {
        let record = LibraryFixtures.record()
        let stored = StoredApplicationRecord(record)
        let document = LibraryCatalogDocument(records: [stored, stored])
        let data = try JSONEncoder().encode(document)
        try writeCatalog(String(decoding: data, as: UTF8.self))

        let store = makeStore()
        await assertLibraryError(category: .storageFailure, message: ZynSignError.libraryCatalogUnreadable().userMessage) {
            _ = try await store.allRecords()
        }
    }

    func testCatalogLocationThatIsADirectoryIsUnreadable() async throws {
        try FileManager.default.createDirectory(at: catalogLocation, withIntermediateDirectories: true)
        let store = makeStore()

        await assertLibraryError(category: .storageFailure, message: ZynSignError.libraryCatalogUnreadable().userMessage) {
            _ = try await store.allRecords()
        }
    }

    // MARK: - Write failures

    func testWriteFailureIsTypedAndLeavesTheStoreUnchanged() async throws {
        // The catalog's parent "directory" is a regular file, so the
        // directory cannot be created and the catalog cannot be written.
        let blockedParent = workDirectory.appendingPathComponent("blocked", isDirectory: false)
        try Data("occupied".utf8).write(to: blockedParent)
        let blockedLocation = blockedParent.appendingPathComponent("catalog.json", isDirectory: false)
        let store = FileApplicationRecordStore(catalogLocation: blockedLocation)
        let record = LibraryFixtures.record()

        await assertLibraryError(category: .storageFailure, message: ZynSignError.libraryStorageFailure().userMessage) {
            try await store.insert(record)
        }

        let fetched = try await store.record(withID: record.id)
        XCTAssertNil(fetched)
        let listed = try await store.allRecords()
        XCTAssertTrue(listed.isEmpty)
    }

    // MARK: - Helpers

    private func assertLibraryError(
        category: DiagnosticCategory,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected a typed library error.", file: file, line: line)
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, category, file: file, line: line)
            XCTAssertEqual(error.userMessage, message, file: file, line: line)
        } catch {
            XCTFail("Expected a ZynSignError, got \(error)", file: file, line: line)
        }
    }
}
