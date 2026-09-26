import XCTest
@testable import ZynSign

/// Profile Matching: eligibility (covers the app, unexpired, not App
/// Store), ranking order (exact over wildcard, certificate over none,
/// team match, supported type), deterministic tie-breaks, and the empty
/// ranking that drives "Profile not suitable for this app".
final class ProfileMatchingTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
    private let matcher = ProfileMatcher()

    private let bundle = "com.example.synthetic"
    private let matchingFingerprint = String(repeating: "ab", count: 32)

    private func makeSummary(
        name: String = "Profile",
        patterns: [String] = ["com.example.synthetic"],
        bundleIdentifier: String? = "com.example.synthetic",
        teamIdentifier: String? = "TEAM123456",
        expirationDate: Date? = nil,
        profileType: ProvisioningProfileClassification? = .development,
        certificateFingerprints: [String]? = nil
    ) -> ProvisioningProfileSummary {
        ProvisioningProfileSummary(
            name: name,
            teamIdentifier: teamIdentifier,
            bundleIdentifierPatterns: patterns,
            expirationDate: expirationDate ?? referenceDate.addingTimeInterval(120 * 86400),
            entitlementsKeys: [],
            allowsDebug: false,
            sourceFileName: "\(name).mobileprovision",
            importedAt: referenceDate,
            profileType: profileType,
            bundleIdentifier: bundleIdentifier,
            certificateFingerprints: certificateFingerprints
        )
    }

    private func context(
        target: String? = "com.example.synthetic",
        certificates: [LocalCertificateFact] = []
    ) -> ProfileCompatibilityContext {
        ProfileCompatibilityContext(
            targetBundleIdentifier: target,
            localCertificates: certificates,
            referenceDate: referenceDate
        )
    }

    private func localCertificate(
        hex: String,
        team: String? = "TEAM123456"
    ) -> LocalCertificateFact {
        LocalCertificateFact(
            fingerprintHex: hex,
            teamIdentifier: team,
            displayName: "Synthetic Certificate",
            isUsableForSigning: true
        )
    }

    // MARK: - Eligibility

    func testProfilesThatDoNotCoverTheAppAreNotRanked() {
        let covering = makeSummary(name: "Covering")
        let other = makeSummary(
            name: "Other",
            patterns: ["com.other.app"],
            bundleIdentifier: "com.other.app"
        )
        let ranked = matcher.rank(profiles: [other, covering], context: context())
        XCTAssertEqual(ranked.map(\.profile.name), ["Covering"])
    }

    func testExpiredProfilesAreNotRanked() {
        let expired = makeSummary(
            name: "Expired",
            expirationDate: referenceDate.addingTimeInterval(-86400)
        )
        XCTAssertTrue(matcher.rank(profiles: [expired], context: context()).isEmpty)
        XCTAssertFalse(matcher.isEligible(expired, context: context()))
    }

    func testAppStoreProfilesAreNotRanked() {
        let appStore = makeSummary(name: "Store", profileType: .appStore)
        XCTAssertTrue(matcher.rank(profiles: [appStore], context: context()).isEmpty)
    }

    func testNoTargetAppMeansNoRanking() {
        let profile = makeSummary()
        XCTAssertTrue(matcher.rank(profiles: [profile], context: context(target: nil)).isEmpty)
        XCTAssertNil(matcher.bestMatch(profiles: [profile], context: context(target: nil)))
    }

    func testEmptyLibraryMeansNoBestMatch() {
        XCTAssertNil(matcher.bestMatch(profiles: [], context: context()))
    }

    // MARK: - Ranking

    func testExactMatchOutranksWildcard() {
        let wildcard = makeSummary(
            name: "Wildcard",
            patterns: ["com.example.*"],
            bundleIdentifier: nil
        )
        let exact = makeSummary(name: "Exact")
        let ranked = matcher.rank(profiles: [wildcard, exact], context: context())
        XCTAssertEqual(ranked.map(\.profile.name), ["Exact", "Wildcard"])
        XCTAssertTrue(ranked[0].reasons.contains("Exact bundle match"))
        XCTAssertFalse(ranked[0].reasons.contains("Wildcard covers the app"))
        XCTAssertTrue(ranked[1].reasons.contains("Wildcard covers the app"))
    }

    func testCertificateAvailabilityOutranksMissingCertificate() {
        let withCert = makeSummary(
            name: "With Certificate",
            certificateFingerprints: [matchingFingerprint]
        )
        let withoutCert = makeSummary(
            name: "Without Certificate",
            certificateFingerprints: [String(repeating: "cd", count: 32)]
        )
        let ranked = matcher.rank(
            profiles: [withoutCert, withCert],
            context: context(certificates: [localCertificate(hex: matchingFingerprint)])
        )
        XCTAssertEqual(ranked.map(\.profile.name), ["With Certificate", "Without Certificate"])
        XCTAssertTrue(ranked[0].reasons.contains("Your certificate is included"))
        XCTAssertFalse(ranked[1].reasons.contains("Your certificate is included"))
        XCTAssertGreaterThan(ranked[0].score, ranked[1].score)
    }

    func testSupportedTypeOutranksUnknownTypeAtEqualFit() {
        let unknown = makeSummary(
            name: "Unknown",
            patterns: ["com.example.*"],
            bundleIdentifier: nil,
            profileType: .unknown
        )
        let development = makeSummary(
            name: "Development",
            patterns: ["com.example.*"],
            bundleIdentifier: nil,
            profileType: .development
        )
        let ranked = matcher.rank(profiles: [unknown, development], context: context())
        XCTAssertEqual(ranked.map(\.profile.name), ["Development", "Unknown"])
    }

    func testTieBreakPrefersLaterExpirationThenName() {
        let sooner = makeSummary(
            name: "B Sooner",
            expirationDate: referenceDate.addingTimeInterval(60 * 86400)
        )
        let later = makeSummary(
            name: "A Later",
            expirationDate: referenceDate.addingTimeInterval(90 * 86400)
        )
        let ranked = matcher.rank(profiles: [sooner, later], context: context())
        XCTAssertEqual(ranked.map(\.profile.name), ["A Later", "B Sooner"])
    }

    func testSameScoresSortAlphabeticallyForDeterminism() {
        let first = makeSummary(name: "Alpha")
        let second = makeSummary(name: "Beta")
        let rankedOnce = matcher.rank(profiles: [second, first], context: context())
        let rankedTwice = matcher.rank(profiles: [first, second], context: context())
        XCTAssertEqual(rankedOnce.map(\.profile.name), ["Alpha", "Beta"])
        XCTAssertEqual(rankedOnce.map(\.profile.name), rankedTwice.map(\.profile.name))
    }

    func testPinnedCandidateSurvivesAsTopMatchWhenItIsBest() {
        let pinned = makeSummary(
            name: "Pinned",
            certificateFingerprints: [matchingFingerprint]
        )
        let other = makeSummary(name: "Other")
        let ranked = matcher.rank(
            profiles: [other, pinned],
            context: context(certificates: [localCertificate(hex: matchingFingerprint)])
        )
        XCTAssertEqual(ranked.first?.profile.name, "Pinned")
        XCTAssertTrue(ranked.first!.reasons.contains("Your certificate is included"))
        XCTAssertTrue(ranked.first!.reasons.contains("Team matches your certificates"))
    }

    func testReportInMatchCarriesTheSameContext() {
        let profile = makeSummary(certificateFingerprints: [matchingFingerprint])
        let match = matcher.bestMatch(
            profiles: [profile],
            context: context(certificates: [localCertificate(hex: matchingFingerprint)])
        )
        XCTAssertEqual(match?.report.targetBundleIdentifier, bundle)
        XCTAssertEqual(match?.report.overall, .ready)
        XCTAssertEqual(match?.profile.id, profile.id)
    }

    func testExpiringSoonProfileStillEligibleButRankedBelowLongerValidity() {
        let expiringSoon = makeSummary(
            name: "Expiring Soon",
            expirationDate: referenceDate.addingTimeInterval(10 * 86400)
        )
        let healthy = makeSummary(
            name: "Healthy",
            expirationDate: referenceDate.addingTimeInterval(100 * 86400)
        )
        XCTAssertTrue(matcher.isEligible(expiringSoon, context: context()))
        let ranked = matcher.rank(profiles: [expiringSoon, healthy], context: context())
        XCTAssertEqual(ranked.map(\.profile.name), ["Healthy", "Expiring Soon"])
        XCTAssertTrue(ranked[1].reasons.contains("Expiring soon"))
    }
}
