import XCTest
@testable import ZynSign

/// Tests for the Identity Center's presentation model: the phase machine,
/// the stale-snapshot rule, team expansion, and the three mutations.
///
/// The doubles are the same in-memory stores the service tests use, so
/// what the model shows is what those stores hold — never a projection
/// invented by the model.
@MainActor
final class IdentityCenterModelTests: XCTestCase {

    private var registry: MemoryIdentityRegistry!
    private var resolver: TestIdentityResolver!
    private var store: SecureIdentityStore!
    private var profiles: MemoryProvisioningProfileLibrary!
    private var annotations: MemoryIdentityAnnotationsStore!
    private var history: InMemorySigningHistoryStore!
    private var service: IdentityCenterService!
    private var model: IdentityCenterModel!

    private let referenceDate = IdentityCenterFixtures.referenceDate

    override func setUp() {
        super.setUp()
        registry = MemoryIdentityRegistry()
        resolver = TestIdentityResolver()
        store = SecureIdentityStore(registry: registry, resolver: resolver)
        profiles = MemoryProvisioningProfileLibrary()
        annotations = MemoryIdentityAnnotationsStore()
        history = InMemorySigningHistoryStore()
        service = IdentityCenterService(
            identityStore: store,
            profiles: profiles,
            library: nil,
            annotations: annotations,
            history: history,
            clock: FixedEvaluationClock(instant: referenceDate)
        )
        model = IdentityCenterModel(service: service)
    }

    override func tearDown() {
        model = nil
        service = nil
        history = nil
        annotations = nil
        profiles = nil
        store = nil
        resolver = nil
        registry = nil
        super.tearDown()
    }

    private func registerValidIdentity() throws {
        _ = try store.register(certificateDER: CertificateFixtures.validDER, keyReference: SigningIdentityFixtures.reference)
    }

    private func loadedSnapshot() throws -> IdentityCenterSnapshot {
        guard case .loaded(let snapshot) = model.phase else {
            throw NSError(domain: "test", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Expected the loaded phase"])
        }
        return snapshot
    }

    // MARK: - Phases

    func testLoadStartsLoadingThenLoads() async throws {
        XCTAssertEqual(model.phase, .loading)
        try registerValidIdentity()
        await model.load()
        let snapshot = try loadedSnapshot()
        XCTAssertEqual(snapshot.statistics.certificateCount, 1)
    }

    func testLoadFailureReportsTheFailedPhaseWithTypedLanguage() async {
        registry.failure = ZynSignError.identity(.keychainAccessFailure)
        await model.load()
        guard case .failed(let message) = model.phase else {
            return XCTFail("Expected the failed phase")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(model.loadedSnapshot)
    }

    func testLoadIfNeededWithinFreshnessDoesNotRecompute() async throws {
        try registerValidIdentity()
        await model.load()
        let first = try loadedSnapshot()

        // Mutate the store behind the model's back; the fresh snapshot is
        // still valid, so the next appearance must not recompute.
        _ = try store.register(certificateDER: CertificateFixtures.expiredDER, keyReference: SigningIdentityFixtures.reference)
        await model.loadIfNeeded()

        let second = try loadedSnapshot()
        XCTAssertEqual(second.generatedAt, first.generatedAt)
        XCTAssertEqual(second.statistics.certificateCount, 1)

        // A forced refresh does recompute.
        await model.refresh()
        let third = try loadedSnapshot()
        XCTAssertEqual(third.statistics.certificateCount, 2)
    }

    // MARK: - Team workspace state

    func testTeamsStartExpandedAndCollapseAndExpand() async throws {
        try registerValidIdentity()
        await model.load()

        XCTAssertTrue(model.isTeamExpanded(DeveloperTeam.ungroupedIdentifier))

        model.toggleTeam(DeveloperTeam.ungroupedIdentifier)
        XCTAssertFalse(model.isTeamExpanded(DeveloperTeam.ungroupedIdentifier))

        model.expandAllTeams()
        XCTAssertTrue(model.isTeamExpanded(DeveloperTeam.ungroupedIdentifier))

        model.collapseAllTeams()
        XCTAssertFalse(model.isTeamExpanded(DeveloperTeam.ungroupedIdentifier))
    }

    // MARK: - Mutations

    func testSetDefaultMarksAndSnapshotReflectsIt() async throws {
        try registerValidIdentity()
        await model.load()
        let certificate = try loadedSnapshot().certificates[0]

        await model.setDefault(certificate)

        let snapshot = try loadedSnapshot()
        XCTAssertEqual(snapshot.defaultFingerprintHex, certificate.facts.fingerprintHex)
        XCTAssertTrue(snapshot.certificates[0].facts.isDefault)
    }

    func testRemoveClearsRegistrationAndDefault() async throws {
        try registerValidIdentity()
        await model.load()
        let certificate = try loadedSnapshot().certificates[0]
        try annotations.setDefaultIdentityFingerprint(certificate.facts.fingerprintHex)

        await model.remove(certificate)

        let snapshot = try loadedSnapshot()
        XCTAssertEqual(snapshot.statistics.certificateCount, 0)
        XCTAssertNil(snapshot.defaultFingerprintHex)
    }

    func testRemoveProfileRemovesFromTheLibrary() async throws {
        let profile = IdentityCenterFixtures.profileFacts(name: "Profile")
        try await profiles.upsert(IdentityCenterFixtures.summary(for: profile))
        await model.load()
        XCTAssertEqual(try loadedSnapshot().statistics.profileCount, 1)

        let entry = try loadedSnapshot().profiles[0]
        await model.removeProfile(entry)

        XCTAssertEqual(try loadedSnapshot().statistics.profileCount, 0)
    }

    func testFailedMutationShowsANoticeAndClearsIt() async throws {
        try registerValidIdentity()
        await model.load()
        annotations.failure = ZynSignError.identityAnnotationsStorageFailure()

        await model.setDefault(try loadedSnapshot().certificates[0])

        XCTAssertNotNil(model.notice)
        model.clearNotice()
        XCTAssertNil(model.notice)
    }
}
