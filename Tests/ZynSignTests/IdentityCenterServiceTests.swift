import XCTest
@testable import ZynSign

/// Tests for the Developer Identity Center's service: the snapshot's
/// assembly over the real secure store, the profile library double, the
/// library double, the annotation store double, and the journal double;
/// the statistics, the teams, the health, the conflicts, the forecast,
/// the timeline; the default mark; removal; and the recommendation.
///
/// Every certificate in play is one of the synthetic fixtures; no key
/// material exists anywhere in these tests.
@MainActor
final class IdentityCenterServiceTests: XCTestCase {

    private var registry: MemoryIdentityRegistry!
    private var resolver: TestIdentityResolver!
    private var store: SecureIdentityStore!
    private var profiles: MemoryProvisioningProfileLibrary!
    private var annotations: MemoryIdentityAnnotationsStore!
    private var history: InMemorySigningHistoryStore!
    private var records: InMemoryApplicationRecordStore!
    private var artifacts: SyntheticLibraryArtifactStore!
    private var library: ApplicationLibrary!
    private var service: IdentityCenterService!

    /// The reference instant: 2026-10-01.
    private let referenceDate = IdentityCenterFixtures.referenceDate

    override func setUp() {
        super.setUp()
        registry = MemoryIdentityRegistry()
        resolver = TestIdentityResolver()
        store = SecureIdentityStore(registry: registry, resolver: resolver)
        profiles = MemoryProvisioningProfileLibrary()
        annotations = MemoryIdentityAnnotationsStore()
        history = InMemorySigningHistoryStore()
        records = InMemoryApplicationRecordStore()
        artifacts = SyntheticLibraryArtifactStore()
        library = ApplicationLibrary(records: records, artifacts: artifacts)
        service = IdentityCenterService(
            identityStore: store,
            profiles: profiles,
            library: library,
            annotations: annotations,
            history: history,
            clock: FixedEvaluationClock(instant: referenceDate)
        )
    }

    override func tearDown() {
        service = nil
        library = nil
        artifacts = nil
        records = nil
        history = nil
        annotations = nil
        profiles = nil
        store = nil
        resolver = nil
        registry = nil
        super.tearDown()
    }

    /// Registers the valid, expired, and future fixtures.
    private func registerStandardIdentities() throws {
        _ = try store.register(certificateDER: CertificateFixtures.validDER, keyReference: SigningIdentityFixtures.reference)
        _ = try store.register(certificateDER: CertificateFixtures.expiredDER, keyReference: SigningIdentityFixtures.reference)
        _ = try store.register(certificateDER: CertificateFixtures.futureDER, keyReference: SigningIdentityFixtures.reference)
    }

    // MARK: - Snapshot assembly

    func testSnapshotCountsIdentitiesProfilesAndTeams() async throws {
        try registerStandardIdentities()
        let profile = IdentityCenterFixtures.profileFacts(name: "One Profile", teamID: nil, teamName: nil)
        try await profiles.upsert(IdentityCenterFixtures.summary(for: profile))

        let snapshot = try await service.snapshot()

        XCTAssertEqual(snapshot.statistics.certificateCount, 3)
        XCTAssertEqual(snapshot.statistics.profileCount, 1)
        // The fixtures declare no Team ID, so everything lands in the one
        // ungrouped bucket.
        XCTAssertEqual(snapshot.teams.count, 1)
        XCTAssertTrue(snapshot.teams[0].isUngrouped)
        XCTAssertEqual(snapshot.teams[0].certificateFingerprints.count, 3)
        XCTAssertEqual(snapshot.teams[0].profileIDs, [profile.id])
    }

    func testEmptyCenterIsHealthyWithZeroes() async throws {
        let snapshot = try await service.snapshot()

        XCTAssertEqual(snapshot.statistics.certificateCount, 0)
        XCTAssertEqual(snapshot.statistics.teamCount, 0)
        XCTAssertEqual(snapshot.statistics.healthyCount, 0)
        XCTAssertEqual(snapshot.statistics.needsAttentionCount, 0)
        XCTAssertTrue(snapshot.conflicts.isEmpty)
        XCTAssertTrue(snapshot.forecast.isEmpty)
        XCTAssertTrue(snapshot.timeline.isEmpty)
    }

    func testExpiredCertificateDrivesNeedsAttentionAndConflicts() async throws {
        try registerStandardIdentities()

        let snapshot = try await service.snapshot()

        XCTAssertGreaterThan(snapshot.statistics.needsAttentionCount, 0)
        let expired = snapshot.certificates.first {
            $0.facts.fingerprintHex == CertificateFixtures.expiredFingerprintHex
        }
        XCTAssertEqual(expired?.health.status, .blocked)
        XCTAssertFalse(snapshot.forecast.isEmpty)
        // The expired fixture's expiration is inside the horizon.
        XCTAssertTrue(snapshot.forecast.contains { $0.band == .expired })
    }

    func testHealthReportsAreAttachedToEveryEntry() async throws {
        try registerStandardIdentities()
        let profile = IdentityCenterFixtures.profileFacts(name: "Profile")
        try await profiles.upsert(IdentityCenterFixtures.summary(for: profile))

        let snapshot = try await service.snapshot()

        XCTAssertEqual(snapshot.certificates.count, 3)
        XCTAssertEqual(snapshot.certificates.filter { !$0.health.checks.isEmpty }.count, 3)
        XCTAssertEqual(snapshot.profiles.count, 1)
        XCTAssertFalse(snapshot.profiles[0].health.checks.isEmpty)
    }

    func testAnnotationsJoinLabelsImportDatesAndTheDefaultMark() async throws {
        try registerStandardIdentities()
        let fingerprint = IdentityCenterFixtures.metadata(for: CertificateFixtures.validDER)
            .sha256Fingerprint.hexDigest.lowercased()
        try annotations.setAnnotation(
            IdentityAnnotation(displayLabel: "My Key", importedAt: TestClocks.utc(2026, 9, 25, hour: 9)),
            forFingerprint: fingerprint
        )
        try annotations.setDefaultIdentityFingerprint(fingerprint)

        let snapshot = try await service.snapshot()

        XCTAssertEqual(snapshot.defaultFingerprintHex, fingerprint)
        let entry = snapshot.certificate(fingerprintHex: fingerprint)
        XCTAssertEqual(entry?.displayName, "My Key")
        XCTAssertEqual(entry?.facts.importedAt, TestClocks.utc(2026, 9, 25, hour: 9))
        XCTAssertTrue(entry?.facts.isDefault == true)
    }

    func testCompatibleAppsComeFromTheLibraryRecords() async throws {
        try registerStandardIdentities()
        let covered = LibraryOrganizationFixtures.entry(
            name: "Covered App",
            bundleIdentifier: "com.example.covered"
        )
        let uncovered = LibraryOrganizationFixtures.entry(
            name: "Uncovered App",
            bundleIdentifier: "com.other.app"
        )
        try await records.insert(covered.record)
        try await records.insert(uncovered.record)

        let profile = IdentityCenterFixtures.profileFacts(
            name: "Covering Profile",
            teamID: nil,
            teamName: nil,
            bundleIdentifierPatterns: ["com.example.*"]
        )
        try await profiles.upsert(IdentityCenterFixtures.summary(for: profile))

        let snapshot = try await service.snapshot()

        XCTAssertEqual(snapshot.profiles.count, 1)
        XCTAssertEqual(snapshot.profiles[0].compatibleApps.map(\.bundleIdentifier), ["com.example.covered"])
        XCTAssertEqual(snapshot.profiles[0].status, .ready)
        // The certificates link to the profile by declared team? The
        // fixtures declare no team; the profile declares none either, so
        // linkage is by embedded fingerprint only — none. Compatible
        // certificates are therefore still zero and the profile-coverage
        // facts live on the profile entry alone.
        XCTAssertTrue(snapshot.certificates.allSatisfy { $0.compatibleApps.isEmpty })
    }

    func testJournalFeedsTheTimeline() async throws {
        try registerStandardIdentities()
        let fingerprint = CertificateFixtures.validFingerprintHex
        let record = SigningRecord(
            presetID: nil,
            certificateFingerprint: CertificateFingerprint(hexDigest: fingerprint),
            sourceBundleIdentifier: "com.example.app",
            sourceDisplayName: "Example",
            stoppingStage: "verification",
            errorCode: nil,
            outputFileName: "example.ipa",
            outputByteCount: 1_024,
            startedAt: referenceDate.addingTimeInterval(-3_600),
            duration: 1,
            result: .succeeded
        )
        await history.append(record)

        let snapshot = try await service.snapshot()

        XCTAssertTrue(snapshot.timeline.contains { $0.kind == .applicationSigned })
    }

    // MARK: - Degradation

    func testUnreadableProfileLibraryDegradesToEmptyProfiles() async throws {
        try registerStandardIdentities()
        profiles.failReads(with: ZynSignError.identity(.certificateUnavailable))

        let snapshot = try await service.snapshot()

        XCTAssertEqual(snapshot.statistics.certificateCount, 3)
        XCTAssertEqual(snapshot.statistics.profileCount, 0)
    }

    func testUnreadableIdentityStoreFailsTheSnapshot() async {
        registry.failure = ZynSignError.identity(.keychainAccessFailure)

        do {
            _ = try await service.snapshot()
            XCTFail("Expected the snapshot to fail")
        } catch let error as ZynSignError {
            XCTAssertFalse(error.userMessage.isEmpty)
        } catch {
            XCTFail("Expected a typed error, got \(error)")
        }
    }

    // MARK: - Actions

    func testSetDefaultAndRemoveClearTheDefaultMark() async throws {
        try registerStandardIdentities()
        let fingerprint = CertificateFixtures.validFingerprintHex
        try annotations.setDefaultIdentityFingerprint(fingerprint)

        try await service.setDefaultIdentityFingerprint(nil)
        XCTAssertNil(try annotations.defaultIdentityFingerprint())

        try await service.setDefaultIdentityFingerprint(fingerprint)
        XCTAssertEqual(try annotations.defaultIdentityFingerprint(), fingerprint)

        try await service.removeIdentity(fingerprintHex: fingerprint)
        XCTAssertNil(try annotations.defaultIdentityFingerprint())
        let remaining = try store.listIdentities()
        XCTAssertEqual(remaining.count, 2)
    }

    func testRemoveUnknownIdentityThrows() async {
        do {
            try await service.removeIdentity(fingerprintHex: IdentityCenterFixtures.fingerprintHex(seed: 0xFF))
            XCTFail("Expected identityNotFound")
        } catch let error as ZynSignError {
            XCTAssertFalse(error.userMessage.isEmpty)
        } catch {
            XCTFail("Expected a typed error, got \(error)")
        }
    }

    func testRemoveProfileRemovesFromTheLibrary() async throws {
        let profile = IdentityCenterFixtures.profileFacts(name: "Removable")
        try await profiles.upsert(IdentityCenterFixtures.summary(for: profile))
        try await service.removeProfile(id: profile.id)
        let count = try await profiles.count()
        XCTAssertEqual(count, 0)
    }

    // MARK: - Recommendation

    func testRecommendationUsesTheStoresEndToEnd() async throws {
        try registerStandardIdentities()
        let fingerprint = CertificateFixtures.validFingerprintHex
        let profile = IdentityCenterFixtures.profileFacts(
            name: "Covering Profile",
            teamID: nil,
            bundleIdentifierPatterns: ["com.example.*"]
        )
        try await profiles.upsert(IdentityCenterFixtures.summary(for: profile))

        // A previous successful signing of this very app with the valid
        // fixture's certificate.
        let record = SigningRecord(
            presetID: nil,
            certificateFingerprint: CertificateFingerprint(hexDigest: fingerprint),
            sourceBundleIdentifier: "com.example.covered",
            sourceDisplayName: "Covered App",
            stoppingStage: "verification",
            errorCode: nil,
            outputFileName: "covered.ipa",
            outputByteCount: 1_024,
            startedAt: referenceDate.addingTimeInterval(-86_400),
            duration: 1,
            result: .succeeded
        )
        await history.append(record)

        let recommendation = await service.recommendation(forBundleIdentifier: "com.example.covered")

        XCTAssertEqual(recommendation?.certificateFingerprintHex, fingerprint)
        XCTAssertEqual(recommendation?.profileID, profile.id)
        XCTAssertTrue(recommendation?.reasons.contains(.previousSuccess) == true)
    }

    func testRecommendationIsEmptyWhenNothingQualifies() async throws {
        let recommendation = await service.recommendation(forBundleIdentifier: "com.example.app")
        XCTAssertNil(recommendation)
    }
}
