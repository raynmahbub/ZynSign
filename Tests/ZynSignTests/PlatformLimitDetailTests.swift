import XCTest
@testable import ZynSign

/// Tests for the explanation behind the three platform limits.
///
/// The limits themselves are pinned elsewhere — `InstallationCapability`,
/// `PairingCapabilityTests`, and `AnalyticsPolicyTests` own those facts. What
/// this file guards is the *explanation*: that every never-row resolves to one,
/// that it names a requirement rather than a refusal, and that anything it
/// points at as "already on" is genuinely switched on at the current stop.
final class PlatformLimitDetailTests: XCTestCase {

    /// Every catalogue id is `limit.<rawValue>`, and the lookup has to find the
    /// explanation for exactly those three entries.
    func testEveryLimitResolvesFromItsCatalogEntry() throws {
        for limit in UnsupportedFeature.allCases {
            let entry = limit.catalogEntry
            XCTAssertEqual(entry.availability, .notSupported)
            XCTAssertEqual(entry.category, .platformLimits)
            let detail = try XCTUnwrap(
                PlatformLimitDetail.resolved(forCatalogID: entry.id),
                "\(entry.id) has no explanation"
            )
            XCTAssertEqual(detail, limit.detail, "\(entry.id) resolved a different explanation")
        }
    }

    /// A row that is not a platform limit must not resolve to one — the lookup
    /// is prefix-based, so a core or release id could otherwise collide.
    func testOnlyPlatformLimitEntriesResolve() {
        for feature in CoreFeature.allCases {
            XCTAssertNil(PlatformLimitDetail.resolved(forCatalogID: feature.catalogEntry.id))
        }
        for feature in ReleaseFeature.allCases {
            XCTAssertNil(PlatformLimitDetail.resolved(forCatalogID: "release.\(feature.rawValue)"))
        }
        XCTAssertNil(PlatformLimitDetail.resolved(forCatalogID: "limit.not-a-limit"))
        XCTAssertNil(PlatformLimitDetail.resolved(forCatalogID: ""))
    }

    /// Every part of the explanation is written, and is a sentence about the
    /// requirement rather than a bare "not supported".
    func testEveryExplanationNamesItsRequirementAndItsAlternative() {
        for limit in UnsupportedFeature.allCases {
            let detail = limit.detail
            for (label, text) in [
                ("requirement", detail.requirement),
                ("wouldHaveToChange", detail.wouldHaveToChange),
                ("instead", detail.instead),
            ] {
                XCTAssertGreaterThan(text.count, 40, "\(limit): \(label) is not explained")
                XCTAssertFalse(text.hasSuffix(" "), "\(limit): \(label) has trailing whitespace")
                XCTAssertTrue(text.hasSuffix("."), "\(limit): \(label) is not a full sentence")
            }
            XCTAssertFalse(detail.evidence.isEmpty, "\(limit) quotes no typed evidence")
            XCTAssertFalse(detail.alternatives.isEmpty, "\(limit) names nothing that ships instead")
        }
    }

    /// "Already on" has to mean already on. An alternative is a claim the source
    /// can check, so it is checked against the gate this build actually ships.
    func testEveryAlternativeIsLiveAtTheCurrentStop() {
        let gate = ReleaseGate(stage: ReleaseTrain.current, exposesEverything: false)
        for limit in UnsupportedFeature.allCases {
            for alternative in limit.detail.alternatives {
                XCTAssertTrue(
                    alternative.isAvailable(at: gate),
                    "\(limit) points at \(alternative.displayName), which this stop does not expose"
                )
                XCTAssertFalse(
                    alternative.displayName.isEmpty,
                    "\(limit) points at a surface with no name"
                )
            }
        }
    }

    /// The evidence quotes the typed limitations rather than inventing prose,
    /// so a change to a limitation message reaches the catalogue.
    func testEvidenceIsQuotedFromTheCapabilityTypes() {
        XCTAssertTrue(
            UnsupportedFeature.inAppInstallation.detail.evidence
                .contains(InstallationLimitation.noDeliveryMechanism.message)
        )
        XCTAssertEqual(
            UnsupportedFeature.pairingJITAndMux.detail.evidence,
            PairingCapabilityAssessment.allUnavailable.map(\.summary)
        )
        XCTAssertEqual(
            UnsupportedFeature.cloudSyncAndTelemetry.detail.evidence,
            AnalyticsPolicy.guarantees.map(\.message)
        )
    }

    /// The telemetry row says this build sends nothing. If that ever changes,
    /// the catalogue must stop saying it — this is the test that fails first.
    func testTheTelemetryExplanationStaysTrueToThePolicy() {
        let detail = UnsupportedFeature.cloudSyncAndTelemetry.detail
        XCTAssertFalse(AnalyticsPolicy.isEnabled, "the catalogue would be lying about telemetry")
        XCTAssertNil(AnalyticsPolicy.endpoint)
        XCTAssertEqual(AnalyticsPolicy.eventCount, 0)
        XCTAssertTrue(detail.instead.contains("journal"))
    }

    /// Installation is never offered as an action anywhere, and the catalogue
    /// still states the platform fact behind that.
    func testInstallationStaysARecordedLimit() {
        let assessment = InstallationCapabilityAssessment.assess(
            InstallationEvidence(profileStatus: .valid, deviceAuthorized: true, platformSupported: true)
        )
        XCTAssertFalse(assessment.supported)
        XCTAssertTrue(assessment.limitations.contains(.noDeliveryMechanism))
        XCTAssertTrue(
            UnsupportedFeature.inAppInstallation.detail.requirement.contains("install")
        )
    }
}
