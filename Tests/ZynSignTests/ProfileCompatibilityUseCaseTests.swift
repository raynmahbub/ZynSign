import XCTest
@testable import ZynSign

/// `ProfileCompatibilityUseCase`: the application-layer bridge that reads
/// local certificates through `IdentityStore` and feeds the domain engines.
final class ProfileCompatibilityUseCaseTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
    private let matchingFingerprint = String(repeating: "ab", count: 32)

    private func makeUseCase(
        identities: [SigningIdentity]? = nil
    ) -> ProfileCompatibilityUseCase {
        ProfileCompatibilityUseCase(
            identityStore: identities.map(StubIdentityStore.init(identities:)),
            clock: FixedEvaluationClock(instant: referenceDate)
        )
    }

    private func makeIdentity(
        fingerprintHex: String = String(repeating: "ab", count: 32),
        team: String = "TEAM123456",
        keyAvailability: SigningKeyAvailability = .available
    ) -> SigningIdentity {
        let metadata = ProvisioningPolicyFixtures.identityMetadata(
            fingerprint: ProvisioningPolicyFixtures.fingerprint(fingerprintHex),
            organizationalUnits: team.isEmpty ? [] : [team],
            keyAvailability: keyAvailability,
            association: keyAvailability == .available ? .matched : .unknown,
            capabilityState: keyAvailability == .available ? .ready : .unavailable
        )
        return SigningIdentity(
            id: metadata.id,
            certificate: metadata.certificate,
            keyAvailability: metadata.keyAvailability,
            association: metadata.association,
            capabilityState: metadata.capabilityState
        )
    }

    private func makeSummary(
        patterns: [String] = ["com.example.synthetic"],
        certificateFingerprints: [String]? = [String(repeating: "ab", count: 32)],
        profileType: ProvisioningProfileClassification? = .development
    ) -> ProvisioningProfileSummary {
        ProvisioningProfileSummary(
            name: "Synthetic Profile",
            teamIdentifier: "TEAM123456",
            bundleIdentifierPatterns: patterns,
            expirationDate: referenceDate.addingTimeInterval(120 * 86400),
            entitlementsKeys: [],
            allowsDebug: false,
            sourceFileName: "sample.mobileprovision",
            importedAt: referenceDate,
            profileType: profileType,
            certificateFingerprints: certificateFingerprints
        )
    }

    // MARK: - Local certificate facts

    func testLocalCertificatesAreReducedToFingerprintTeamAndUsability() {
        let useCase = makeUseCase(identities: [makeIdentity()])
        let facts = useCase.localCertificates()
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts[0].fingerprintHex, matchingFingerprint)
        XCTAssertEqual(facts[0].teamIdentifier, "TEAM123456")
        XCTAssertTrue(facts[0].isUsableForSigning)
        XCTAssertFalse(facts[0].displayName.isEmpty)
    }

    func testMissingIdentityStoreYieldsNoFactsInsteadOfCrashing() {
        let useCase = makeUseCase(identities: nil)
        XCTAssertEqual(useCase.localCertificates(), [])
    }

    func testThrowingIdentityStoreYieldsNoFacts() {
        let useCase = ProfileCompatibilityUseCase(
            identityStore: FailingIdentityStore(),
            clock: FixedEvaluationClock(instant: referenceDate)
        )
        XCTAssertEqual(useCase.localCertificates(), [])
    }

    // MARK: - Evaluation through the use case

    func testEvaluateUsesTheClockInstantAndLocalCertificates() throws {
        let useCase = makeUseCase(identities: [makeIdentity()])
        let report = useCase.evaluate(
            profile: makeSummary(),
            targetBundleIdentifier: "com.example.synthetic"
        )
        XCTAssertEqual(report.checkedAt, referenceDate)
        XCTAssertEqual(report.targetBundleIdentifier, "com.example.synthetic")
        XCTAssertEqual(report.overall, .ready)
        let certificate = try XCTUnwrap(report.result(for: .certificateAvailable))
        XCTAssertEqual(certificate.status, .pass)
        let team = try XCTUnwrap(report.result(for: .teamIdentifier))
        XCTAssertEqual(team.status, .pass)
    }

    func testEvaluateWithoutStoreReportsMissingCertificate() throws {
        let useCase = makeUseCase(identities: nil)
        let report = useCase.evaluate(
            profile: makeSummary(),
            targetBundleIdentifier: "com.example.synthetic"
        )
        let certificate = try XCTUnwrap(report.result(for: .certificateAvailable))
        XCTAssertEqual(certificate.status, .fail)
        XCTAssertEqual(report.overall, .blocked)
    }

    // MARK: - Reports for a whole library

    func testReportsForEachProfileShareOneCertificateRead() {
        let store = RecordingIdentityStore(identities: [makeIdentity()])
        let useCase = ProfileCompatibilityUseCase(
            identityStore: store,
            clock: FixedEvaluationClock(instant: referenceDate)
        )
        let profiles = [
            makeSummary(patterns: ["com.example.synthetic"]),
            makeSummary(patterns: ["com.example.*"]),
            ProvisioningProfileSummary(
                name: "Other",
                teamIdentifier: "TEAM123456",
                bundleIdentifierPatterns: ["org.other.app"],
                expirationDate: referenceDate.addingTimeInterval(120 * 86400),
                entitlementsKeys: [],
                allowsDebug: false,
                sourceFileName: "other.mobileprovision",
                importedAt: referenceDate,
                profileType: .adHoc,
                certificateFingerprints: [matchingFingerprint]
            ),
        ]
        let reports = useCase.reports(for: profiles)
        XCTAssertEqual(reports.count, 3)
        XCTAssertEqual(store.listCount, 1)
        XCTAssertNotNil(reports[profiles[0].id])
        XCTAssertNotNil(reports[profiles[2].id])
    }

    // MARK: - Ranking through the use case

    func testBestMatchRanksCoveringProfileFirst() throws {
        let useCase = makeUseCase(identities: [makeIdentity()])
        let covering = makeSummary(patterns: ["com.example.synthetic"])
        let other = ProvisioningProfileSummary(
            name: "Other",
            teamIdentifier: "TEAM123456",
            bundleIdentifierPatterns: ["org.other.app"],
            expirationDate: referenceDate.addingTimeInterval(120 * 86400),
            entitlementsKeys: [],
            allowsDebug: false,
            sourceFileName: "other.mobileprovision",
            importedAt: referenceDate,
            profileType: .development,
            certificateFingerprints: [matchingFingerprint]
        )
        let best = try XCTUnwrap(
            useCase.bestMatch(profiles: [other, covering], targetBundleIdentifier: "com.example.synthetic")
        )
        XCTAssertEqual(best.profile.id, covering.id)
        XCTAssertEqual(best.report.overall, .ready)
    }

    func testRankingWithNoTargetAppIsEmpty() {
        let useCase = makeUseCase(identities: [makeIdentity()])
        let ranked = useCase.rank(
            profiles: [makeSummary()],
            targetBundleIdentifier: nil
        )
        XCTAssertTrue(ranked.isEmpty)
    }
}

// MARK: - Test doubles

private struct StubIdentityStore: IdentityStore {
    let identities: [SigningIdentity]

    func listIdentities() throws -> [SigningIdentity] { identities }

    func identity(withID id: SigningIdentityIdentifier) throws -> SigningIdentity? {
        identities.first { $0.id == id }
    }

    func signingCapability(for id: SigningIdentityIdentifier) throws -> any SigningCapability {
        throw ZynSignError.identity(.certificateUnavailable)
    }
}

private final class RecordingIdentityStore: IdentityStore, @unchecked Sendable {
    private let backing: StubIdentityStore
    private(set) var listCount = 0

    init(identities: [SigningIdentity]) {
        self.backing = StubIdentityStore(identities: identities)
    }

    func listIdentities() throws -> [SigningIdentity] {
        listCount += 1
        return backing.identities
    }

    func identity(withID id: SigningIdentityIdentifier) throws -> SigningIdentity? {
        try backing.identity(withID: id)
    }

    func signingCapability(for id: SigningIdentityIdentifier) throws -> any SigningCapability {
        try backing.signingCapability(for: id)
    }
}

private struct FailingIdentityStore: IdentityStore {
    func listIdentities() throws -> [SigningIdentity] {
        throw ZynSignError.identity(.certificateUnavailable)
    }

    func identity(withID id: SigningIdentityIdentifier) throws -> SigningIdentity? {
        throw ZynSignError.identity(.certificateUnavailable)
    }

    func signingCapability(for id: SigningIdentityIdentifier) throws -> any SigningCapability {
        throw ZynSignError.identity(.certificateUnavailable)
    }
}
