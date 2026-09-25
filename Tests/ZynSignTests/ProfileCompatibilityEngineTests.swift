import XCTest
@testable import ZynSign

/// The Smart Compatibility Engine: each of the five checks in its pass,
/// warning, failure, unsupported, and not-evaluated states, the overall
/// Compatibility Summary's precedence, and the actionable diagnostics the
/// Diagnostics Panel renders.
final class ProfileCompatibilityEngineTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
    private let engine = ProfileCompatibilityEngine()

    private let matchingFingerprint = String(repeating: "ab", count: 32)
    private let otherFingerprint = String(repeating: "cd", count: 32)

    // MARK: - Fixtures

    private func makeSummary(
        patterns: [String] = ["com.example.synthetic"],
        bundleIdentifier: String? = "com.example.synthetic",
        teamIdentifier: String? = "TEAM123456",
        expirationDate: Date? = nil,
        profileType: ProvisioningProfileClassification? = .development,
        certificateFingerprints: [String]? = nil
    ) -> ProvisioningProfileSummary {
        ProvisioningProfileSummary(
            name: "Synthetic Profile",
            teamIdentifier: teamIdentifier,
            bundleIdentifierPatterns: patterns,
            expirationDate: expirationDate ?? referenceDate.addingTimeInterval(120 * 86400),
            entitlementsKeys: [],
            allowsDebug: false,
            sourceFileName: "sample.mobileprovision",
            importedAt: referenceDate,
            profileType: profileType,
            bundleIdentifier: bundleIdentifier,
            certificateFingerprints: certificateFingerprints
        )
    }

    private func certificate(
        hex: String,
        team: String? = "TEAM123456",
        usable: Bool = true
    ) -> LocalCertificateFact {
        LocalCertificateFact(
            fingerprintHex: hex,
            teamIdentifier: team,
            displayName: "Synthetic Certificate",
            isUsableForSigning: usable
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

    /// A fully passing context: covering bundle, matching team and
    /// certificate, healthy expiration, supported type.
    private func healthyContext() -> ProfileCompatibilityContext {
        context(certificates: [certificate(hex: matchingFingerprint)])
    }

    private func result(
        _ report: ProfileCompatibilityReport,
        _ check: ProfileCompatibilityCheck
    ) -> ProfileCompatibilityCheckResult {
        report.results.first { $0.check == check }!
    }

    // MARK: - Ready path

    func testAllChecksPassAndSummaryIsReady() throws {
        let summary = makeSummary(certificateFingerprints: [matchingFingerprint])
        let report = engine.evaluate(profile: summary, context: healthyContext())

        XCTAssertEqual(report.overall, .ready)
        XCTAssertEqual(report.evaluatedCount, 5)
        XCTAssertEqual(report.passedCount, 5)
        XCTAssertEqual(report.summaryLine, "5 of 5 checks passed")
        for check in ProfileCompatibilityCheck.allCases {
            XCTAssertEqual(result(report, check).status, .pass, check.rawValue)
        }
        XCTAssertEqual(report.diagnostics.count, 5)
        XCTAssertTrue(report.diagnostics.allSatisfy { $0.severity == .success })
    }

    func testExplicitBundleMatchSummary() {
        let summary = makeSummary(certificateFingerprints: [matchingFingerprint])
        let report = engine.evaluate(profile: summary, context: healthyContext())
        let bundle = result(report, .bundleIdentifier)
        XCTAssertEqual(bundle.summary, "Matches com.example.synthetic")
        XCTAssertEqual(bundle.diagnostic?.title, "Bundle ID matches")
    }

    func testWildcardCoverPassesWithWildcardWording() {
        let summary = makeSummary(
            patterns: ["com.example.*"],
            bundleIdentifier: nil,
            certificateFingerprints: [matchingFingerprint]
        )
        let report = engine.evaluate(profile: summary, context: healthyContext())
        let bundle = result(report, .bundleIdentifier)
        XCTAssertEqual(bundle.status, .pass)
        XCTAssertTrue(bundle.summary.contains("Wildcard"))
    }

    // MARK: - Bundle ID

    func testBundleMismatchFailsWithActionableDiagnostic() {
        let summary = makeSummary(certificateFingerprints: [matchingFingerprint])
        let report = engine.evaluate(
            profile: summary,
            context: context(
                target: "com.example.other",
                certificates: [certificate(hex: matchingFingerprint)]
            )
        )
        let bundle = result(report, .bundleIdentifier)
        XCTAssertEqual(bundle.status, .fail)
        XCTAssertEqual(bundle.diagnostic?.severity, .error)
        XCTAssertEqual(bundle.diagnostic?.title, "Bundle ID mismatch")
        XCTAssertTrue(bundle.diagnostic?.message.contains("com.example.other") == true)
        XCTAssertEqual(report.overall, .blocked)
    }

    func testNoTargetBundleIsNotEvaluatedAndExcludedFromOverall() {
        let summary = makeSummary(certificateFingerprints: [matchingFingerprint])
        let report = engine.evaluate(profile: summary, context: context(target: nil, certificates: [certificate(hex: matchingFingerprint)]))
        let bundle = result(report, .bundleIdentifier)
        XCTAssertEqual(bundle.status, .notEvaluated)
        XCTAssertNil(bundle.diagnostic)
        XCTAssertEqual(report.evaluatedCount, 4)
        XCTAssertEqual(report.overall, .ready)
        XCTAssertEqual(report.summaryLine, "4 of 4 checks passed")
    }

    // MARK: - Team ID

    func testTeamMatchWithLocalCertificateTeam() {
        let summary = makeSummary(certificateFingerprints: [matchingFingerprint])
        let report = engine.evaluate(profile: summary, context: healthyContext())
        let team = result(report, .teamIdentifier)
        XCTAssertEqual(team.status, .pass)
        XCTAssertEqual(team.diagnostic?.severity, .success)
    }

    func testTeamMismatchIsWarningNamingBothTeams() {
        let summary = makeSummary(certificateFingerprints: [matchingFingerprint])
        let report = engine.evaluate(
            profile: summary,
            context: context(certificates: [certificate(hex: matchingFingerprint, team: "TEAM999999")])
        )
        let team = result(report, .teamIdentifier)
        XCTAssertEqual(team.status, .warning)
        XCTAssertEqual(team.diagnostic?.severity, .warning)
        XCTAssertTrue(team.diagnostic?.message.contains("TEAM123456") == true)
        XCTAssertTrue(team.diagnostic?.message.contains("TEAM999999") == true)
        XCTAssertEqual(report.overall, .attention)
    }

    func testTeamNotEvaluatedWithoutLocalCertificateTeams() {
        let summary = makeSummary(certificateFingerprints: [matchingFingerprint])
        let report = engine.evaluate(
            profile: summary,
            context: context(certificates: [certificate(hex: matchingFingerprint, team: nil)])
        )
        XCTAssertEqual(result(report, .teamIdentifier).status, .notEvaluated)
    }

    func testTeamNotEvaluatedWhenProfileDeclaresNoTeam() {
        let summary = makeSummary(
            teamIdentifier: nil,
            certificateFingerprints: [matchingFingerprint]
        )
        let report = engine.evaluate(profile: summary, context: healthyContext())
        XCTAssertEqual(result(report, .teamIdentifier).status, .notEvaluated)
    }

    // MARK: - Certificate

    func testMissingCertificateFailsWhenNoLocalIdentities() {
        let summary = makeSummary(certificateFingerprints: [matchingFingerprint])
        let report = engine.evaluate(profile: summary, context: context(certificates: []))
        let certificate = result(report, .certificateAvailable)
        XCTAssertEqual(certificate.status, .fail)
        XCTAssertEqual(certificate.diagnostic?.severity, .error)
        XCTAssertEqual(certificate.diagnostic?.title, "Missing certificate")
        XCTAssertEqual(report.overall, .blocked)
    }

    func testCertificateNotMatchingLocalIdentitiesFails() {
        let summary = makeSummary(certificateFingerprints: [otherFingerprint])
        let report = engine.evaluate(profile: summary, context: healthyContext())
        let certificate = result(report, .certificateAvailable)
        XCTAssertEqual(certificate.status, .fail)
        XCTAssertEqual(certificate.diagnostic?.title, "Missing certificate")
    }

    func testUnrecordedCertificatesWarnWithRefreshGuidance() {
        let summary = makeSummary(certificateFingerprints: nil)
        let report = engine.evaluate(profile: summary, context: healthyContext())
        let certificate = result(report, .certificateAvailable)
        XCTAssertEqual(certificate.status, .warning)
        XCTAssertEqual(certificate.diagnostic?.severity, .warning)
        XCTAssertTrue(certificate.diagnostic?.message.contains("Refresh Validation") == true)
        // A warning without failures or unsupported types is attention, not
        // a block: the profile may still be fine once re-validated.
        XCTAssertEqual(report.overall, .attention)
    }

    func testMatchingCertificateWithoutUsableKeyWarns() {
        let summary = makeSummary(certificateFingerprints: [matchingFingerprint])
        let report = engine.evaluate(
            profile: summary,
            context: context(certificates: [certificate(hex: matchingFingerprint, usable: false)])
        )
        let certificate = result(report, .certificateAvailable)
        XCTAssertEqual(certificate.status, .warning)
        XCTAssertEqual(certificate.diagnostic?.title, "Certificate key unavailable")
    }

    func testFingerprintComparisonIgnoresHexCase() {
        let summary = makeSummary(certificateFingerprints: [matchingFingerprint.uppercased()])
        let report = engine.evaluate(profile: summary, context: healthyContext())
        XCTAssertEqual(result(report, .certificateAvailable).status, .pass)
    }

    // MARK: - Expiration

    func testExpiredProfileFailsWithErrorDiagnostic() {
        let summary = makeSummary(
            expirationDate: referenceDate.addingTimeInterval(-5 * 86400),
            certificateFingerprints: [matchingFingerprint]
        )
        let report = engine.evaluate(profile: summary, context: healthyContext())
        let expiration = result(report, .profileExpiration)
        XCTAssertEqual(expiration.status, .fail)
        XCTAssertEqual(expiration.diagnostic?.severity, .error)
        XCTAssertEqual(expiration.diagnostic?.title, "Expired profile")
        XCTAssertTrue(expiration.diagnostic?.message.contains("5 days ago") == true)
        XCTAssertEqual(report.overall, .blocked)
    }

    func testExpiringSoonWarnsWithDayCount() {
        let summary = makeSummary(
            expirationDate: referenceDate.addingTimeInterval(10 * 86400),
            certificateFingerprints: [matchingFingerprint]
        )
        let report = engine.evaluate(profile: summary, context: healthyContext())
        let expiration = result(report, .profileExpiration)
        XCTAssertEqual(expiration.status, .warning)
        XCTAssertEqual(expiration.diagnostic?.severity, .warning)
        XCTAssertEqual(expiration.diagnostic?.title, "Expiring soon")
        XCTAssertEqual(report.overall, .attention)
    }

    // MARK: - Profile type

    func testAppStoreProfileIsUnsupported() {
        let summary = makeSummary(profileType: .appStore, certificateFingerprints: [matchingFingerprint])
        let report = engine.evaluate(profile: summary, context: healthyContext())
        let type = result(report, .profileType)
        XCTAssertEqual(type.status, .unsupported)
        XCTAssertEqual(type.diagnostic?.severity, .unsupported)
        XCTAssertEqual(type.diagnostic?.title, "Unsupported distribution type")
        XCTAssertEqual(report.overall, .unsupported)
        XCTAssertEqual(report.overall.displayName, "Unsupported")
    }

    func testUnknownProfileTypeWarns() {
        let summary = makeSummary(profileType: .unknown, certificateFingerprints: [matchingFingerprint])
        let report = engine.evaluate(profile: summary, context: healthyContext())
        XCTAssertEqual(result(report, .profileType).status, .warning)
        XCTAssertEqual(report.overall, .attention)
    }

    func testDevelopmentAdHocAndEnterpriseTypesPass() {
        for type in [ProvisioningProfileClassification.development, .adHoc, .enterprise] {
            let summary = makeSummary(profileType: type, certificateFingerprints: [matchingFingerprint])
            let report = engine.evaluate(profile: summary, context: healthyContext())
            XCTAssertEqual(result(report, .profileType).status, .pass, type.rawValue)
        }
    }

    func testLegacySummaryWithoutRecordedTypeTreatedAsUnknown() {
        let summary = ProvisioningProfileSummary(
            name: "Legacy",
            teamIdentifier: "TEAM123456",
            bundleIdentifierPatterns: ["com.example.synthetic"],
            expirationDate: referenceDate.addingTimeInterval(120 * 86400),
            entitlementsKeys: [],
            allowsDebug: false,
            sourceFileName: "legacy.mobileprovision",
            importedAt: referenceDate
        )
        XCTAssertNil(summary.profileType)
        XCTAssertEqual(summary.resolvedProfileType, .unknown)
        let report = engine.evaluate(
            profile: summary,
            context: context(target: nil, certificates: [])
        )
        XCTAssertEqual(result(report, .profileType).status, .warning)
    }

    // MARK: - Overall precedence

    func testFailureBeatsUnsupportedAndWarnings() {
        // Expired (fail) + App Store (unsupported) + expiring… the fail wins.
        let summary = makeSummary(
            expirationDate: referenceDate.addingTimeInterval(-1 * 86400),
            profileType: .appStore,
            certificateFingerprints: [matchingFingerprint]
        )
        let report = engine.evaluate(
            profile: summary,
            context: context(target: "com.example.other", certificates: [])
        )
        XCTAssertEqual(report.overall, .blocked)
    }

    func testLegacySummaryWithoutNewFieldsStaysUsableAndWarns() {
        let summary = ProvisioningProfileSummary(
            name: "Legacy",
            teamIdentifier: "TEAM123456",
            bundleIdentifierPatterns: ["com.example.synthetic"],
            expirationDate: referenceDate.addingTimeInterval(120 * 86400),
            entitlementsKeys: [],
            allowsDebug: false,
            sourceFileName: "legacy.mobileprovision",
            importedAt: referenceDate
        )
        XCTAssertNil(summary.profileType)
        XCTAssertEqual(summary.resolvedProfileType, .unknown)
        let report = engine.evaluate(profile: summary, context: context(target: nil, certificates: []))
        // Bundle and team have nothing to compare; the certificate was never
        // recorded (warning), the type reads as unknown (warning), and the
        // healthy expiration passes.
        XCTAssertEqual(result(report, .bundleIdentifier).status, .notEvaluated)
        XCTAssertEqual(result(report, .teamIdentifier).status, .notEvaluated)
        XCTAssertEqual(result(report, .certificateAvailable).status, .warning)
        XCTAssertEqual(result(report, .profileType).status, .warning)
        XCTAssertEqual(result(report, .profileExpiration).status, .pass)
        XCTAssertEqual(report.evaluatedCount, 3)
        XCTAssertEqual(report.overall, .attention)
    }

    func testUnknownOutcomeBadgeWording() {
        XCTAssertEqual(ProfileCompatibilityOutcome.unknown.displayName, "Not Evaluated")
        XCTAssertEqual(ProfileCompatibilityOutcome.ready.displayName, "Compatible")
        XCTAssertEqual(ProfileCompatibilityOutcome.attention.displayName, "Needs Attention")
        XCTAssertEqual(ProfileCompatibilityOutcome.blocked.displayName, "Not Compatible")
    }

    // MARK: - Diagnostics panel contract

    func testDiagnosticSeveritiesMatchTheSpecBadges() {
        var summaries: [ProvisioningProfileSummary] = []
        summaries.append(makeSummary(certificateFingerprints: [matchingFingerprint])) // success
        summaries.append(makeSummary(certificateFingerprints: nil)) // warning
        summaries.append(makeSummary(certificateFingerprints: [otherFingerprint])) // error
        summaries.append(makeSummary(profileType: .appStore, certificateFingerprints: [matchingFingerprint])) // unsupported

        let severities = Set(
            summaries.map { engine.evaluate(profile: $0, context: healthyContext()) }
                .flatMap(\.diagnostics)
                .map(\.severity)
        )
        XCTAssertEqual(severities, Set(ProfileDiagnosticSeverity.allCases))
    }

    func testDiagnosticsCarryUniqueIDsAndActionableText() {
        let summary = makeSummary(certificateFingerprints: [matchingFingerprint])
        let report = engine.evaluate(profile: summary, context: healthyContext())
        let ids = report.diagnostics.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        for diagnostic in report.diagnostics {
            XCTAssertFalse(diagnostic.title.isEmpty)
            XCTAssertFalse(diagnostic.message.isEmpty)
        }
    }
}
