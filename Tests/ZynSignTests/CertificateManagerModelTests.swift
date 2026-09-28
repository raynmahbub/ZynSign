import XCTest
@testable import ZynSign

/// Tests for the certificate manager's state machine: the join of the
/// identity store with local notes, search, filters, sort, the default
/// identity, local renames, import, and removal.
@MainActor
final class CertificateManagerModelTests: XCTestCase {

    // The fingerprints of the fixtures the tests register, in the order
    // registered.
    private static let validFingerprint = CertificateFixtures.validFingerprintHex
    private static let expiredFingerprint = CertificateFixtures.expiredFingerprintHex

    private var registry: MemoryIdentityRegistry!
    private var resolver: TestIdentityResolver!
    private var store: SecureIdentityStore!
    private var annotations: MemoryIdentityAnnotationsStore!
    private var importer: RecordingPKCS12Importer!
    private var model: CertificateManagerModel!

    override func setUp() {
        super.setUp()
        registry = MemoryIdentityRegistry()
        resolver = TestIdentityResolver()
        store = SecureIdentityStore(registry: registry, resolver: resolver)
        annotations = MemoryIdentityAnnotationsStore()
        importer = RecordingPKCS12Importer(store: store)
        model = CertificateManagerModel(
            store: store,
            annotations: annotations,
            importer: importer,
            clock: TestClocks.evaluationInstant
        )
    }

    override func tearDown() {
        model = nil
        importer = nil
        annotations = nil
        store = nil
        resolver = nil
        registry = nil
        super.tearDown()
    }

    /// Registers the four standing fixtures and loads the model.
    private func registerStandardIdentities() async throws {
        _ = try store.register(certificateDER: CertificateFixtures.validDER, keyReference: SigningIdentityFixtures.reference)
        _ = try store.register(certificateDER: CertificateFixtures.expiredDER, keyReference: SigningIdentityFixtures.reference)
        _ = try store.register(certificateDER: CertificateFixtures.futureDER, keyReference: SigningIdentityFixtures.reference)
        _ = try store.register(certificateDER: CertificateFixtures.multiAttributeDER, keyReference: SigningIdentityFixtures.reference)
        await model.load()
    }

    private func items(_ phase: CertificateManagerModel.Phase) -> [CertificateManagerModel.CertificateItem] {
        guard case .loaded(let items) = phase else {
            return []
        }
        return items
    }

    private func item(withCommonName name: String, in phase: CertificateManagerModel.Phase) -> CertificateManagerModel.CertificateItem {
        let item = items(phase).first { $0.commonName == name }
        return try! XCTUnwrap(item, "Expected an item for \(name)")
    }

    // MARK: - Loading and the join

    func testLoadJoinsStoreNotesAndClassifiesExpiration() async throws {
        // Local notes before the load: a label and import date on the valid
        // identity, and the multi-attribute identity marked default.
        try annotations.setAnnotation(
            IdentityAnnotation(
                displayLabel: "My Release Key",
                importedAt: TestClocks.utc(2026, 9, 25, hour: 9)
            ),
            forFingerprint: Self.validFingerprint
        )
        try annotations.setDefaultIdentityFingerprint(Self.expiredFingerprint)
        try await registerStandardIdentities()

        guard case .loaded(let all) = model.phase else {
            return XCTFail("Expected the loaded phase")
        }
        XCTAssertEqual(all.count, 4)

        let valid = item(withCommonName: "ZynSign Test Valid", in: model.phase)
        XCTAssertEqual(valid.displayName, "My Release Key")
        XCTAssertEqual(valid.commonName, "ZynSign Test Valid")
        XCTAssertNil(valid.teamID)
        XCTAssertNil(valid.teamName)
        XCTAssertEqual(valid.kind, .other)
        XCTAssertEqual(valid.expiration.status, .healthy)
        XCTAssertEqual(valid.importedAt, TestClocks.utc(2026, 9, 25, hour: 9))
        XCTAssertFalse(valid.isDefault)

        let expired = item(withCommonName: "ZynSign Test Expired", in: model.phase)
        XCTAssertEqual(expired.expiration.status, .expired)
        XCTAssertLessThan(expired.expiration.remainingDays ?? 0, 0)
        XCTAssertTrue(expired.isDefault)

        let future = item(withCommonName: "ZynSign Test Future", in: model.phase)
        XCTAssertEqual(future.expiration.status, .notYetValid)
        XCTAssertNil(future.expiration.remainingDays)

        let multi = item(withCommonName: "ZynSign Multi", in: model.phase)
        XCTAssertEqual(multi.teamName, "ZynSign Test Org")
        XCTAssertNil(multi.teamID)
        XCTAssertEqual(multi.expiration.status, .expiringSoon)
        XCTAssertEqual(multi.expiration.remainingDays, 21)
    }

    func testLoadWithNoIdentitiesPresentsEmpty() async {
        try await model.load()
        guard case .empty = model.phase else {
            return XCTFail("Expected the empty phase")
        }
    }

    func testAFailingFirstLoadPresentsTheFailure() async throws {
        _ = try store.register(certificateDER: CertificateFixtures.validDER, keyReference: SigningIdentityFixtures.reference)
        resolver.failure = ZynSignError.identity(.keychainAccessFailure)
        await model.load()
        guard case .failed(let message) = model.phase else {
            return XCTFail("Expected the failed phase")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testAResolvingFailureKeepsTheContentAndAnnouncesIt() async throws {
        try await registerStandardIdentities()
        resolver.failure = ZynSignError.identity(.keychainAccessFailure)
        await model.refresh()
        // The content stays; the failure is announced, not presented.
        XCTAssertEqual(items(model.phase).count, 4)
        XCTAssertEqual(model.notice?.title, "Refresh Failed")
    }

    // MARK: - Search

    func testSearchMatchesNameTeamAndFingerprint() async throws {
        try await registerStandardIdentities()

        model.searchText = "ZynSign Multi"
        XCTAssertEqual(model.visibleItems().count, 1)

        // The team name doubles as the organization search hit.
        model.searchText = "test org"
        XCTAssertEqual(model.visibleItems().count, 1)
        XCTAssertEqual(model.visibleItems().first?.commonName, "ZynSign Multi")

        // Three fixtures share the Test CA issuer; the multi-attribute
        // fixture is self-issued with its own distinguished name, so an
        // issuer search reaches three of the four.
        model.searchText = "Test CA"
        XCTAssertEqual(model.visibleItems().count, 3)

        // A fingerprint prefix finds its certificate.
        model.searchText = "4aea4f8b"
        XCTAssertEqual(model.visibleItems().count, 1)
        XCTAssertEqual(model.visibleItems().first?.commonName, "ZynSign Test Valid")

        // A search that matches nothing is an honest empty result.
        model.searchText = "no such certificate"
        XCTAssertEqual(model.visibleItems().count, 0)

        // An empty search matches everything.
        model.searchText = "   "
        XCTAssertEqual(model.visibleItems().count, 4)
    }

    func testSearchMatchesTheUserChosenLabel() async throws {
        try await registerStandardIdentities()
        _ = try await model.setDisplayLabel("Production Signing", for: item(withCommonName: "ZynSign Test Valid", in: model.phase))
        model.searchText = "Production"
        XCTAssertEqual(model.visibleItems().count, 1)
    }

    // MARK: - Filters

    func testTheExpirationFilters() async throws {
        try await registerStandardIdentities()

        model.expirationFilter = .active
        // Healthy plus expiring soon: both can still sign.
        XCTAssertEqual(model.visibleItems().count, 2)

        model.expirationFilter = .expiringSoon
        XCTAssertEqual(model.visibleItems().count, 1)
        XCTAssertEqual(model.visibleItems().first?.commonName, "ZynSign Multi")

        model.expirationFilter = .expired
        XCTAssertEqual(model.visibleItems().count, 1)
        XCTAssertEqual(model.visibleItems().first?.commonName, "ZynSign Test Expired")

        model.expirationFilter = .notYetValid
        XCTAssertEqual(model.visibleItems().count, 1)
        XCTAssertEqual(model.visibleItems().first?.commonName, "ZynSign Test Future")

        model.expirationFilter = .all
        XCTAssertEqual(model.visibleItems().count, 4)
    }

    func testTheKindFilter() async throws {
        try await registerStandardIdentities()
        model.kindFilter = .other
        XCTAssertEqual(model.visibleItems().count, 4)
        model.kindFilter = .development
        XCTAssertEqual(model.visibleItems().count, 0)
        model.kindFilter = .distribution
        XCTAssertEqual(model.visibleItems().count, 0)
        model.clearFilters()
        XCTAssertEqual(model.visibleItems().count, 4)
    }

    func testTheTeamFilterGroupsIdentitiesByTeam() async throws {
        try await registerStandardIdentities()

        let options = model.teamOptions
        XCTAssertEqual(options.map(\.displayName), ["No Team", "ZynSign Test Org"])

        model.teamFilter = options.first { $0.displayName == "ZynSign Test Org" }?.id
        XCTAssertEqual(model.visibleItems().count, 1)
        XCTAssertEqual(model.visibleItems().first?.commonName, "ZynSign Multi")

        model.teamFilter = CertificateManagerModel.TeamOption.noTeamID
        XCTAssertEqual(model.visibleItems().count, 3)

        model.clearFilters()
        XCTAssertEqual(model.visibleItems().count, 4)
        XCTAssertNil(model.teamFilter)
    }

    // MARK: - Sort

    func testSortingByNameTeamExpirationAndImport() async throws {
        try await registerStandardIdentities()
        // Import dates for the recency order: the valid identity older than
        // the multi-attribute one; the others unrecorded.
        try annotations.setAnnotation(
            IdentityAnnotation(importedAt: TestClocks.utc(2026, 1, 1)),
            forFingerprint: Self.validFingerprint
        )
        try annotations.setAnnotation(
            IdentityAnnotation(importedAt: TestClocks.utc(2026, 9, 1)),
            forFingerprint: CertificateFixtures.multiAttributeFingerprint
        )
        await model.refresh()

        model.sortOrder = .name
        XCTAssertEqual(
            model.visibleItems().map(\.commonName),
            ["ZynSign Multi", "ZynSign Test Expired", "ZynSign Test Future", "ZynSign Test Valid"]
        )

        model.sortOrder = .expiration
        XCTAssertEqual(
            model.visibleItems().map(\.commonName),
            ["ZynSign Test Expired", "ZynSign Multi", "ZynSign Test Valid", "ZynSign Test Future"]
        )

        model.sortOrder = .recentlyImported
        let recent = model.visibleItems()
        XCTAssertEqual(recent[0].commonName, "ZynSign Multi")
        XCTAssertEqual(recent[1].commonName, "ZynSign Test Valid")
        XCTAssertEqual(
            Set(recent.suffix(2).map(\.commonName)),
            ["ZynSign Test Expired", "ZynSign Test Future"]
        )

        model.sortOrder = .team
        let byTeam = model.visibleItems()
        XCTAssertEqual(byTeam.first?.commonName, "ZynSign Multi")
        // Identities without team information sort after the one that has
        // a team, then by name.
        XCTAssertEqual(
            byTeam.suffix(3).map(\.commonName),
            ["ZynSign Test Expired", "ZynSign Test Future", "ZynSign Test Valid"]
        )
    }

    // MARK: - The default identity

    func testSetAndClearDefault() async throws {
        try await registerStandardIdentities()
        let expired = item(withCommonName: "ZynSign Test Expired", in: model.phase)
        XCTAssertFalse(expired.isDefault)

        let saved = await model.setDefault(expired)
        XCTAssertTrue(saved)
        XCTAssertEqual(model.defaultFingerprint, Self.expiredFingerprint)
        let updated = item(withCommonName: "ZynSign Test Expired", in: model.phase)
        XCTAssertTrue(updated.isDefault)
        XCTAssertFalse(item(withCommonName: "ZynSign Test Valid", in: model.phase).isDefault)

        let cleared = await model.clearDefault()
        XCTAssertTrue(cleared)
        XCTAssertNil(model.defaultFingerprint)
        XCTAssertFalse(items(model.phase).contains(where: \.isDefault))
    }

    func testClearingAnUnsetDefaultIsASilentNoOp() async throws {
        try await registerStandardIdentities()
        let cleared = await model.clearDefault()
        XCTAssertFalse(cleared)
        XCTAssertNil(model.notice)
    }

    func testRemovingTheDefaultClearsTheDefault() async throws {
        try await registerStandardIdentities()
        _ = try await model.setDefault(item(withCommonName: "ZynSign Test Valid", in: model.phase))
        _ = await model.remove(item(withCommonName: "ZynSign Test Valid", in: model.phase))
        XCTAssertNil(model.defaultFingerprint)
        XCTAssertNil(try annotations.defaultIdentityFingerprint())
    }

    func testAStaleDefaultIsClearedOnLoad() async {
        // A default naming an identity the store no longer holds is stale:
        // loading clears it instead of keeping a ghost default.
        let ghost = String(repeating: "0", count: 64)
        try? annotations.setDefaultIdentityFingerprint(ghost)
        _ = try? store.register(certificateDER: CertificateFixtures.validDER, keyReference: SigningIdentityFixtures.reference)
        await model.load()
        XCTAssertNil(model.defaultFingerprint)
        XCTAssertNil(try? annotations.defaultIdentityFingerprint())
    }

    // MARK: - Local display labels

    func testARenameChangesOnlyTheDisplay() async throws {
        try await registerStandardIdentities()
        let valid = item(withCommonName: "ZynSign Test Valid", in: model.phase)
        let saved = await model.setDisplayLabel("  My Production Key  ", for: valid)
        XCTAssertTrue(saved)

        let renamed = item(withCommonName: "ZynSign Test Valid", in: model.phase)
        // Trimmed and shown; the certificate's own name is untouched.
        XCTAssertEqual(renamed.displayName, "My Production Key")
        XCTAssertEqual(renamed.commonName, "ZynSign Test Valid")
        XCTAssertEqual(renamed.identity.certificate.subject.commonName, "ZynSign Test Valid")
    }

    func testAnEmptyLabelClearsTheRename() async throws {
        try await registerStandardIdentities()
        let valid = item(withCommonName: "ZynSign Test Valid", in: model.phase)
        _ = try await model.setDisplayLabel("Temporary", for: valid)
        let cleared = await model.setDisplayLabel("   ", for: item(withCommonName: "ZynSign Test Valid", in: model.phase))
        XCTAssertTrue(cleared)
        let back = item(withCommonName: "ZynSign Test Valid", in: model.phase)
        XCTAssertEqual(back.displayName, "ZynSign Test Valid")
    }

    func testAnOverlongLabelIsRefusedWithANotice() async throws {
        try await registerStandardIdentities()
        let valid = item(withCommonName: "ZynSign Test Valid", in: model.phase)
        let overlong = String(repeating: "a", count: IdentityAnnotation.maximumLabelLength + 1)
        let saved = await model.setDisplayLabel(overlong, for: valid)
        XCTAssertFalse(saved)
        XCTAssertEqual(model.notice?.title, "Rename Failed")
        XCTAssertEqual(
            item(withCommonName: "ZynSign Test Valid", in: model.phase).displayName,
            "ZynSign Test Valid"
        )
    }

    // MARK: - Import

    func testImportRecordsTheImportDateAndForwardsThePasswordOnce() async throws {
        try await registerStandardIdentities()
        let containerBytes = Data("synthetic-pkcs12-container".utf8)
        importer.enqueue(certificateDER: CertificateFixtures.ecDER)

        let imported = await model.performImport(data: containerBytes, password: "s3cret-rotate-me")
        let item = try! XCTUnwrap(imported)
        XCTAssertEqual(item.commonName, "ZynSign Test EC")
        XCTAssertEqual(item.id, CertificateFixtures.ecFingerprint)
        XCTAssertEqual(item.importedAt, TestClocks.evaluationInstant.instant)
        XCTAssertEqual(model.importSummary?.id, item.id)

        // The password reached the importer exactly once, with the bytes
        // as selected…
        XCTAssertEqual(importer.recordedPasswords, ["s3cret-rotate-me"])
        XCTAssertEqual(importer.recordedData, [containerBytes])
        // …and nowhere in the local notes.
        let notes = try annotations.annotations()
        let notesJSON = String(decoding: try JSONEncoder().encode(notes), as: UTF8.self)
        XCTAssertFalse(notesJSON.contains("s3cret-rotate-me"))
    }

    func testImportingTheSameCertificateAgainReportsADuplicate() async throws {
        try await registerStandardIdentities()
        importer.enqueue(certificateDER: CertificateFixtures.ecDER)
        let first = await model.performImport(data: Data("first".utf8), password: "")
        XCTAssertNotNil(first)

        importer.enqueue(certificateDER: CertificateFixtures.ecDER)
        let second = await model.performImport(data: Data("second".utf8), password: "")
        XCTAssertNil(second)
        XCTAssertNotNil(model.importError)
        // The list still holds the identity exactly once.
        XCTAssertEqual(
            items(model.phase).filter { $0.commonName == "ZynSign Test EC" }.count,
            1
        )
    }

    func testAFailedImportKeepsTheListExactlyAsItIs() async throws {
        try await registerStandardIdentities()
        let before = model.phase
        importer.failure = ZynSignError.identity(.authorizationFailure)
        let imported = await model.performImport(data: Data("x".utf8), password: "wrong")
        XCTAssertNil(imported)
        XCTAssertNotNil(model.importError)
        XCTAssertEqual(model.phase, before)
    }

    // MARK: - Removal

    func testRemovalPrunesNotesAndKeepsTheRest() async throws {
        try await registerStandardIdentities()
        try annotations.setAnnotation(
            IdentityAnnotation(displayLabel: "Fated", importedAt: TestClocks.utc(2026, 9, 1)),
            forFingerprint: Self.validFingerprint
        )
        await model.refresh()
        let valid = item(withCommonName: "ZynSign Test Valid", in: model.phase)

        let removed = await model.remove(valid)
        XCTAssertTrue(removed)

        let remaining = items(model.phase)
        XCTAssertEqual(remaining.count, 3)
        XCTAssertFalse(remaining.contains(where: { $0.id == Self.validFingerprint }))
        XCTAssertNil(try annotations.annotations()[Self.validFingerprint])
        // The registration record is gone from the store itself.
        XCTAssertEqual(try store.listIdentities().count, 3)
    }

    // MARK: - Without the annotation store

    func testWithoutAnnotationsTheScreenStillListsImportsAndRemoves() async throws {
        let bareModel = CertificateManagerModel(
            store: store,
            annotations: nil,
            importer: importer,
            clock: TestClocks.evaluationInstant
        )
        _ = try store.register(certificateDER: CertificateFixtures.validDER, keyReference: SigningIdentityFixtures.reference)
        await bareModel.load()
        XCTAssertEqual(items(bareModel.phase).count, 1)

        // Default and rename degrade to an announced unavailability rather
        // than failing the screen.
        let item = items(bareModel.phase)[0]
        let defaulted = await bareModel.setDefault(item)
        XCTAssertFalse(defaulted)
        XCTAssertEqual(bareModel.notice?.title, "Notes Unavailable")
        let renamed = await bareModel.setDisplayLabel("X", for: item)
        XCTAssertFalse(renamed)

        // Import and removal still work; import just has no date to record.
        importer.enqueue(certificateDER: CertificateFixtures.ecDER)
        let imported = await bareModel.performImport(data: Data("y".utf8), password: "")
        XCTAssertNotNil(imported)
        XCTAssertNil(imported?.importedAt)
        let removed = await bareModel.remove(imported!)
        XCTAssertTrue(removed)
    }
}

extension CertificateFixtures {
    /// The SHA-256 fingerprint of the EC fixture, computed once.
    static var ecFingerprint: String {
        let metadata = try! AppleCertificateParser().parseCertificate(derData: ecDER)
        return metadata.sha256Fingerprint.hexDigest
    }

    /// The SHA-256 fingerprint of the multi-attribute fixture, computed once.
    static var multiAttributeFingerprint: String {
        let metadata = try! AppleCertificateParser().parseCertificate(derData: multiAttributeDER)
        return metadata.sha256Fingerprint.hexDigest
    }
}
