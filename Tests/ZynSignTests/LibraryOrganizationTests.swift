import XCTest
@testable import ZynSign

/// Tests for the library-organization domain: collection names, collection
/// values, and the rules the organization enforces when collections are
/// created, renamed, deleted, filled, emptied, and moved between.
final class LibraryOrganizationTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 760_000_000)
    private let t1 = Date(timeIntervalSinceReferenceDate: 760_000_060)

    // MARK: - Names

    func testNamesAreTrimmedAndInnerWhitespaceCollapses() {
        XCTAssertEqual(LibraryCollection.normalizedName("  Work \n  Apps\t"), "Work Apps")
    }

    func testControlCharactersAreDroppedButEmojiSequencesSurvive() {
        XCTAssertEqual(LibraryCollection.normalizedName("Ga\u{0007}mes"), "Games")
        // A zero-width joiner is a format character, not a control
        // character: the family emoji must come through intact.
        XCTAssertEqual(LibraryCollection.normalizedName("👨‍👩‍👧 Family"), "👨‍👩‍👧 Family")
    }

    func testEmptyAndOverlongNamesAreRefused() {
        XCTAssertNil(LibraryCollection.normalizedName(""))
        XCTAssertNil(LibraryCollection.normalizedName(" \n\t "))
        let limit = String(repeating: "a", count: LibraryCollection.maximumNameLength)
        XCTAssertEqual(LibraryCollection.normalizedName(limit), limit)
        XCTAssertNil(LibraryCollection.normalizedName(limit + "a"))
    }

    func testComparableNamesIgnoreCaseDiacriticsAndWidth() {
        XCTAssertEqual(LibraryCollection.comparableName("Café"), LibraryCollection.comparableName("CAFE"))
        XCTAssertEqual(LibraryCollection.comparableName("ＡＢＣ"), LibraryCollection.comparableName("abc"))
    }

    // MARK: - Collection values

    func testAddingKeepsOrderSkipsDuplicatesAndStampsTheChange() {
        let first = ApplicationRecordIdentifier()
        let second = ApplicationRecordIdentifier()
        let collection = LibraryCollection(name: "Games", createdAt: t0)

        let filled = collection.adding([first, second, first], at: t1)

        XCTAssertEqual(filled.memberIDs, [first, second])
        XCTAssertEqual(filled.updatedAt, t1)
        XCTAssertEqual(filled.createdAt, t0)
        XCTAssertEqual(filled.memberships.map(\.addedAt), [t1, t1])
    }

    func testAddingOnlyExistingMembersChangesNothing() {
        let member = ApplicationRecordIdentifier()
        let collection = LibraryCollection(name: "Games", createdAt: t0).adding([member], at: t0)

        XCTAssertEqual(collection.adding([member], at: t1), collection)
    }

    func testRemovingDropsOnlyTheNamedMembers() {
        let keep = ApplicationRecordIdentifier()
        let drop = ApplicationRecordIdentifier()
        let collection = LibraryCollection(name: "Games", createdAt: t0).adding([keep, drop], at: t0)

        let trimmed = collection.removing([drop], at: t1)

        XCTAssertEqual(trimmed.memberIDs, [keep])
        XCTAssertEqual(trimmed.updatedAt, t1)
        XCTAssertEqual(trimmed.removing([drop], at: t1), trimmed)
    }

    // MARK: - Creating

    func testCreatingAppendsACollectionWithItsMembers() throws {
        var organization = LibraryOrganization.empty
        let member = ApplicationRecordIdentifier()

        let created = try organization.createCollection(named: " Work ", containing: [member], at: t0)

        XCTAssertEqual(created.name, "Work")
        XCTAssertEqual(created.memberIDs, [member])
        XCTAssertEqual(created.createdAt, t0)
        XCTAssertEqual(created.updatedAt, t0)
        XCTAssertEqual(organization.userCollections.map(\.id), [created.id])
    }

    func testNamesMustBeUniqueIgnoringCaseAndDiacritics() throws {
        var organization = LibraryOrganization.empty
        try organization.createCollection(named: "Café", at: t0)
        let before = organization

        XCTAssertThrowsError(try organization.createCollection(named: "cafe", at: t1)) { error in
            XCTAssertEqual((error as? ZynSignError)?.category, .invalidInput)
        }
        XCTAssertEqual(organization, before, "A refused creation must leave the organization untouched.")
    }

    func testAnInvalidNameIsRefusedWithAReadableReason() {
        var organization = LibraryOrganization.empty

        XCTAssertThrowsError(try organization.createCollection(named: "   ", at: t0)) { error in
            let message = (error as? ZynSignError)?.userMessage ?? ""
            XCTAssertTrue(message.contains("\(LibraryCollection.maximumNameLength)"))
        }
        XCTAssertTrue(organization.collections.isEmpty)
    }

    func testNamesAreUniqueOnlyWithinOneKind() throws {
        let tag = LibraryCollection(name: "Games", kind: LibraryCollectionKind(rawValue: "tag"), createdAt: t0)
        var organization = LibraryOrganization(collections: [tag], lastOpened: [:])

        XCTAssertNoThrow(try organization.createCollection(named: "Games", at: t1))
        XCTAssertEqual(organization.userCollections.count, 1, "Only collections of the user kind are presented.")
        XCTAssertEqual(organization.collections.count, 2, "Groupings of other kinds are kept.")
    }

    // MARK: - Renaming and deleting

    func testRenamingToADifferentSpellingOfItsOwnNameIsAllowed() throws {
        var organization = LibraryOrganization.empty
        let created = try organization.createCollection(named: "games", at: t0)

        try organization.renameCollection(created.id, to: "Games", at: t1)

        XCTAssertEqual(organization.collection(withID: created.id)?.name, "Games")
        XCTAssertEqual(organization.collection(withID: created.id)?.updatedAt, t1)
    }

    func testRenamingToAnotherCollectionsNameIsRefused() throws {
        var organization = LibraryOrganization.empty
        try organization.createCollection(named: "Games", at: t0)
        let work = try organization.createCollection(named: "Work", at: t0)
        let before = organization

        XCTAssertThrowsError(try organization.renameCollection(work.id, to: "GAMES", at: t1))
        XCTAssertEqual(organization, before)
    }

    func testDeletingACollectionKeepsTheOthers() throws {
        var organization = LibraryOrganization.empty
        let games = try organization.createCollection(named: "Games", at: t0)
        let work = try organization.createCollection(named: "Work", at: t0)

        try organization.deleteCollection(games.id)

        XCTAssertEqual(organization.userCollections.map(\.id), [work.id])
        XCTAssertThrowsError(try organization.deleteCollection(games.id)) { error in
            XCTAssertEqual((error as? ZynSignError)?.userMessage, "The collection is no longer in your library.")
        }
    }

    // MARK: - Membership

    func testARecordCanBelongToSeveralCollections() throws {
        var organization = LibraryOrganization.empty
        let member = ApplicationRecordIdentifier()
        let games = try organization.createCollection(named: "Games", at: t0)
        let work = try organization.createCollection(named: "Work", at: t0)

        try organization.add([member], to: games.id, at: t1)
        try organization.add([member], to: work.id, at: t1)

        XCTAssertEqual(Set(organization.collectionsHolding(member).map(\.id)), [games.id, work.id])
    }

    func testRemovingFromOneCollectionLeavesTheOthers() throws {
        var organization = LibraryOrganization.empty
        let member = ApplicationRecordIdentifier()
        let games = try organization.createCollection(named: "Games", containing: [member], at: t0)
        let work = try organization.createCollection(named: "Work", containing: [member], at: t0)

        try organization.remove([member], from: games.id, at: t1)

        XCTAssertEqual(organization.collectionsHolding(member).map(\.id), [work.id])
    }

    func testMovingAddsToTheDestinationAndRemovesFromTheSource() throws {
        var organization = LibraryOrganization.empty
        let member = ApplicationRecordIdentifier()
        let stay = ApplicationRecordIdentifier()
        let inbox = try organization.createCollection(named: "Inbox", containing: [member, stay], at: t0)
        let done = try organization.createCollection(named: "Done", at: t0)

        try organization.move([member], from: inbox.id, to: done.id, at: t1)

        XCTAssertEqual(organization.collection(withID: inbox.id)?.memberIDs, [stay])
        XCTAssertEqual(organization.collection(withID: done.id)?.memberIDs, [member])
    }

    func testMovingIntoTheSameCollectionChangesNothing() throws {
        var organization = LibraryOrganization.empty
        let member = ApplicationRecordIdentifier()
        let inbox = try organization.createCollection(named: "Inbox", containing: [member], at: t0)
        let before = organization

        try organization.move([member], from: inbox.id, to: inbox.id, at: t1)

        XCTAssertEqual(organization, before)
    }

    func testChangingAnUnknownCollectionThrowsAndChangesNothing() {
        var organization = LibraryOrganization.empty
        let unknown = LibraryCollectionIdentifier()

        XCTAssertThrowsError(try organization.add([ApplicationRecordIdentifier()], to: unknown, at: t0))
        XCTAssertThrowsError(try organization.renameCollection(unknown, to: "Name", at: t0))
        XCTAssertEqual(organization, .empty)
    }

    // MARK: - Usage and forgetting

    func testForgettingRecordsPrunesEveryMembershipAndUsage() throws {
        var organization = LibraryOrganization.empty
        let gone = ApplicationRecordIdentifier()
        let kept = ApplicationRecordIdentifier()
        let games = try organization.createCollection(named: "Games", containing: [gone, kept], at: t0)
        let work = try organization.createCollection(named: "Work", containing: [gone], at: t0)
        organization.recordOpen(of: gone, at: t0)
        organization.recordOpen(of: kept, at: t1)

        organization.forgetRecords([gone], at: t1)

        XCTAssertEqual(organization.collection(withID: games.id)?.memberIDs, [kept])
        XCTAssertEqual(organization.collection(withID: work.id)?.memberIDs, [])
        XCTAssertNil(organization.lastOpened[gone])
        XCTAssertEqual(organization.lastOpened[kept], t1)
        XCTAssertEqual(organization.userCollections.count, 2, "Forgetting records never deletes collections.")
    }

    // MARK: - Scopes

    func testScopesRoundTripThroughTheirStorageForm() {
        let scopes: [LibraryScope] = [
            .all,
            .smart(.favorites),
            .smart(.expiringSoon),
            .collection(LibraryCollectionIdentifier()),
        ]
        for scope in scopes {
            XCTAssertEqual(LibraryScope(storageValue: scope.storageValue), scope)
        }
        XCTAssertNil(LibraryScope(storageValue: "smart:unknown"))
        XCTAssertNil(LibraryScope(storageValue: "collection:not-a-uuid"))
        XCTAssertNil(LibraryScope(storageValue: "elsewhere"))
    }

    func testQueriesHaveAStableCodableForm() throws {
        let query = LibraryQuery(
            searchText: "delta mail",
            filters: [.favorites, .collection(LibraryCollectionIdentifier()), .version(.latest), .team("ABCDE12345")],
            sort: .nameDescending
        )

        let decoded = try JSONDecoder().decode(LibraryQuery.self, from: JSONEncoder().encode(query))

        XCTAssertEqual(decoded, query)
        XCTAssertEqual(decoded.searchTerms, ["delta", "mail"])
    }

    func testTheOriginalNameOrderKeepsItsStoredValue() {
        // The first library release stored "name" for its A–Z order; the
        // preference must still read as Name A–Z.
        XCTAssertEqual(LibrarySortMode(rawValue: "name"), .name)
        XCTAssertEqual(LibrarySortMode.name.displayName, "Name A–Z")
    }
}
