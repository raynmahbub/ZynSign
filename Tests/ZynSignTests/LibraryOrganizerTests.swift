import XCTest
@testable import ZynSign

/// Tests for the library-organization use case and its file-backed store:
/// every change is saved before it becomes current, a failed save changes
/// nothing, and the document round-trips, versions, and fails closed.
final class LibraryOrganizerTests: XCTestCase {

    private var store: InMemoryLibraryOrganizationStore!
    private var organizer: LibraryOrganizer!

    override func setUp() {
        super.setUp()
        store = InMemoryLibraryOrganizationStore()
        let clock = SyntheticClock()
        organizer = LibraryOrganizer(store: store, now: { [clock] in clock.now() })
    }

    override func tearDown() {
        organizer = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Organizer

    func testCreatingACollectionSavesItAndReturnsIt() async throws {
        let member = ApplicationRecordIdentifier()

        let result = try await organizer.createCollection(named: "Games", containing: [member])

        XCTAssertEqual(result.collection.name, "Games")
        XCTAssertEqual(result.organization.userCollections.map(\.id), [result.collection.id])
        XCTAssertEqual(store.organization, result.organization)
        XCTAssertEqual(store.saveCount, 1)
    }

    func testAFailedSaveLeavesTheOrganizerUnchanged() async throws {
        let created = try await organizer.createCollection(named: "Games")
        store.failSaving(with: ZynSignError.libraryOrganizationStorageFailure(diagnosticDetail: "synthetic"))

        do {
            try await organizer.renameCollection(created.collection.id, to: "Play")
            XCTFail("A failed save must be reported.")
        } catch {
            XCTAssertEqual((error as? ZynSignError)?.category, .storageFailure)
        }

        let current = try await organizer.organization()
        XCTAssertEqual(current.collection(withID: created.collection.id)?.name, "Games")
        XCTAssertEqual(store.organization.collection(withID: created.collection.id)?.name, "Games")
    }

    func testARefusedChangeIsNeitherSavedNorApplied() async throws {
        _ = try await organizer.createCollection(named: "Games")
        let savesBefore = store.saveCount

        do {
            _ = try await organizer.createCollection(named: "GAMES")
            XCTFail("A duplicate name must be refused.")
        } catch {
            XCTAssertEqual((error as? ZynSignError)?.category, .invalidInput)
        }

        XCTAssertEqual(store.saveCount, savesBefore)
        let current = try await organizer.organization()
        XCTAssertEqual(current.userCollections.count, 1)
    }

    func testAnUnchangedOrganizationIsNotSavedAgain() async throws {
        let member = ApplicationRecordIdentifier()
        let created = try await organizer.createCollection(named: "Games", containing: [member])
        let savesBefore = store.saveCount

        try await organizer.add([member], to: created.collection.id)

        XCTAssertEqual(store.saveCount, savesBefore, "Adding a member already present changes nothing.")
    }

    func testMovingIsOneSavedChange() async throws {
        let member = ApplicationRecordIdentifier()
        let inbox = try await organizer.createCollection(named: "Inbox", containing: [member])
        let done = try await organizer.createCollection(named: "Done")
        let savesBefore = store.saveCount

        let updated = try await organizer.move([member], from: inbox.collection.id, to: done.collection.id)

        XCTAssertEqual(store.saveCount, savesBefore + 1)
        XCTAssertEqual(updated.collection(withID: inbox.collection.id)?.memberIDs, [])
        XCTAssertEqual(updated.collection(withID: done.collection.id)?.memberIDs, [member])
    }

    func testAReadFailureIsThrownAndRetriedRatherThanReplacedWithNothing() async throws {
        let existing = try LibraryOrganization.empty.creatingForTest(named: "Games")
        store = InMemoryLibraryOrganizationStore(organization: existing)
        organizer = LibraryOrganizer(store: store)
        store.failLoading(with: ZynSignError.libraryOrganizationUnreadable(diagnosticDetail: "synthetic"))

        do {
            _ = try await organizer.organization()
            XCTFail("A read failure must be reported.")
        } catch {
            XCTAssertEqual((error as? ZynSignError)?.userMessage, "Your library's collections could not be read.")
        }
        do {
            _ = try await organizer.createCollection(named: "Work")
            XCTFail("A change over an unreadable organization must not proceed.")
        } catch {}
        XCTAssertEqual(store.saveCount, 0, "Nothing may be written over an organization that could not be read.")

        store.failLoading(with: nil)
        let recovered = try await organizer.organization()
        XCTAssertEqual(recovered.userCollections.map(\.name), ["Games"])
    }

    func testRecordingAnOpenAndForgettingRecords() async throws {
        let member = ApplicationRecordIdentifier()
        let created = try await organizer.createCollection(named: "Games", containing: [member])

        let opened = try await organizer.recordOpened(member)
        XCTAssertNotNil(opened.lastOpened[member])

        let forgotten = try await organizer.forget([member])
        XCTAssertNil(forgotten.lastOpened[member])
        XCTAssertEqual(forgotten.collection(withID: created.collection.id)?.memberIDs, [])
    }

    // MARK: - File store

    func testTheDocumentRoundTripsCollectionsMembershipsKindsAndUsage() throws {
        let directory = try LibraryFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("Nested/Organization.json")
        let fileStore = FileLibraryOrganizationStore(documentLocation: location)

        let first = ApplicationRecordIdentifier()
        let second = ApplicationRecordIdentifier()
        let t0 = LibraryFixtures.importDate
        var organization = LibraryOrganization.empty
        try organization.createCollection(named: "Games", containing: [second, first], at: t0)
        let future = LibraryCollection(name: "Pinned", kind: LibraryCollectionKind(rawValue: "future-kind"), createdAt: t0)
        organization = LibraryOrganization(collections: organization.collections + [future], lastOpened: [first: LibraryFixtures.laterDate])

        try fileStore.saveOrganization(organization)
        let reloaded = try fileStore.loadOrganization()

        XCTAssertEqual(reloaded, organization)
        XCTAssertEqual(reloaded.userCollections.first?.memberIDs, [second, first], "Member order must survive.")
        XCTAssertEqual(reloaded.collections.last?.kind.rawValue, "future-kind", "Unknown kinds are preserved, not dropped.")
    }

    func testAMissingDocumentIsAnEmptyOrganization() throws {
        let directory = try LibraryFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileStore = FileLibraryOrganizationStore(documentLocation: directory.appendingPathComponent("Organization.json"))

        XCTAssertEqual(try fileStore.loadOrganization(), .empty)
    }

    func testADocumentFromANewerBuildIsReportedAndLeftInPlace() throws {
        let directory = try LibraryFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("Organization.json")
        let newer = Data(#"{"schemaVersion": 99, "collections": [], "usage": []}"#.utf8)
        try newer.write(to: location)

        XCTAssertThrowsError(try FileLibraryOrganizationStore(documentLocation: location).loadOrganization()) { error in
            XCTAssertEqual((error as? ZynSignError)?.category, .capabilityUnavailable)
        }
        XCTAssertEqual(try Data(contentsOf: location), newer, "The newer document must not be rewritten.")
    }

    func testDamagedDocumentsFailClosed() throws {
        let directory = try LibraryFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("Organization.json")
        let id = UUID().uuidString
        let damaged: [String] = [
            "not json",
            #"{"schemaVersion": 0, "collections": [], "usage": []}"#,
            #"{"schemaVersion": 1, "collections": [{"id": "nope", "name": "A", "kind": "collection", "createdAt": 0, "updatedAt": 0, "members": []}], "usage": []}"#,
            #"{"schemaVersion": 1, "collections": [{"id": "\#(id)", "name": "A", "kind": "collection", "createdAt": 0, "updatedAt": 0, "members": []}, {"id": "\#(id)", "name": "B", "kind": "collection", "createdAt": 0, "updatedAt": 0, "members": []}], "usage": []}"#,
            #"{"schemaVersion": 1, "collections": [{"id": "\#(UUID().uuidString)", "name": "Same", "kind": "collection", "createdAt": 0, "updatedAt": 0, "members": []}, {"id": "\#(UUID().uuidString)", "name": "same", "kind": "collection", "createdAt": 0, "updatedAt": 0, "members": []}], "usage": []}"#,
            #"{"schemaVersion": 1, "collections": [{"id": "\#(UUID().uuidString)", "name": "  padded  ", "kind": "collection", "createdAt": 0, "updatedAt": 0, "members": []}], "usage": []}"#,
            #"{"schemaVersion": 1, "collections": [], "usage": [{"recordID": "nope", "lastOpenedAt": 0}]}"#,
        ]
        for document in damaged {
            try Data(document.utf8).write(to: location)
            XCTAssertThrowsError(try FileLibraryOrganizationStore(documentLocation: location).loadOrganization(), document) { error in
                XCTAssertEqual((error as? ZynSignError)?.category, .storageFailure, document)
            }
        }
    }

    func testARecordListedTwiceInOneCollectionIsRefused() throws {
        let directory = try LibraryFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("Organization.json")
        let member = UUID().uuidString
        let document = #"{"schemaVersion": 1, "collections": [{"id": "\#(UUID().uuidString)", "name": "A", "kind": "collection", "createdAt": 0, "updatedAt": 0, "members": [{"recordID": "\#(member)", "addedAt": 0}, {"recordID": "\#(member)", "addedAt": 1}]}], "usage": []}"#
        try Data(document.utf8).write(to: location)

        XCTAssertThrowsError(try FileLibraryOrganizationStore(documentLocation: location).loadOrganization())
    }
}

private extension LibraryOrganization {
    /// A copy with one more collection, for arranging tests.
    func creatingForTest(named name: String) throws -> LibraryOrganization {
        var copy = self
        try copy.createCollection(named: name, at: LibraryFixtures.importDate)
        return copy
    }
}
