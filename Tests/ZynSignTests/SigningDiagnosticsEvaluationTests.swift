import Foundation
import XCTest
@testable import ZynSign

/// The score describes checks ZynSign actually implements, not an iOS verdict.
final class SigningDiagnosticsEvaluationTests: XCTestCase {
    private let instant = ProvisioningPolicyFixtures.evaluationDate

    func testMissingInputsBlockAndRemainExplicitRatherThanReceivingFreePoints() {
        let report = evaluate(package: .missing, profile: .notSelected)

        XCTAssertEqual(report.state(for: .package), .blocked)
        XCTAssertEqual(report.state(for: .certificate), .blocked)
        XCTAssertEqual(report.state(for: .profile), .blocked)
        XCTAssertEqual(report.state(for: .metadata), .notChecked)
        XCTAssertEqual(report.status, .blocked)
        XCTAssertFalse(report.readyToSign)
        XCTAssertLessThan(report.score, 100)
        XCTAssertTrue(report.issues.contains(where: { $0.id == .packageMissing && $0.severity == .error }))
        XCTAssertTrue(report.issues.contains(where: { $0.id == .certificateMissing }))
        XCTAssertTrue(report.issues.contains(where: { $0.id == .profileMissing }))
        XCTAssertEqual(report.warningCount, 1) // XML-only output
    }

    func testRequestingAnUnimplementedDEROptionBlocksInsteadOfClaimingSuccess() {
        let report = evaluate(package: .missing, profile: .notSelected, emitDER: true)

        XCTAssertEqual(report.state(for: .signingOptions), .unsupported)
        XCTAssertEqual(report.status, .blocked)
        XCTAssertTrue(report.issues.contains(where: { $0.id == .derUnavailable && $0.severity == .unsupported }))
        XCTAssertFalse(report.issues.contains(where: { $0.id == .legacyEntitlements }))
        XCTAssertEqual(report.unsupportedCount, 1)
    }

    func testScoreCountsOnlyCheckedStatesAndDoesNotTurnUnsupportedIntoReady() {
        let record = LibraryFixtures.record()
        var checks = SigningDiagnosticArea.allCases.map {
            SigningDiagnosticCheck(area: $0, state: SigningCheckState.passed)
        }
        let full = SigningDiagnosticsReport(recordID: record.id, analyzedAt: instant,
                                            checks: checks, issues: [])
        XCTAssertEqual(full.score, 100)
        XCTAssertEqual(full.status, .ready)

        checks[0] = SigningDiagnosticCheck(area: .package, state: .notChecked)
        let unknown = SigningDiagnosticsReport(recordID: record.id, analyzedAt: instant,
                                               checks: checks, issues: [])
        XCTAssertLessThan(unknown.score, 100)
        XCTAssertEqual(unknown.status, .attention)
        XCTAssertFalse(unknown.readyToSign)

        checks[0] = SigningDiagnosticCheck(area: .package, state: .unsupported)
        let unsupported = SigningDiagnosticsReport(recordID: record.id, analyzedAt: instant,
                                                   checks: checks, issues: [])
        XCTAssertEqual(unsupported.status, .blocked)
        XCTAssertFalse(unsupported.readyToSign)
    }

    func testOnlyAuthenticatedPolicyFactsAreShownAsCompatible() {
        let fixtures = ProvisioningPolicyFixtures.self
        let matching = fixtures.validate(fixtures.context())
        let report = evaluate(package: .missing,
                              profile: .verified(policy: matching,
                                                 expiration: fixtures.expirationDate,
                                                 claimsRepresentable: true))
        XCTAssertEqual(report.state(for: .bundleIdentifier), .passed)
        XCTAssertEqual(report.state(for: .entitlements), .passed)
        // No certificate was selected, so its relationship is not claimed.
        XCTAssertEqual(report.state(for: .certificate), .blocked)
        XCTAssertEqual(report.state(for: .teamIdentifier), .notChecked)

        let mismatch = fixtures.validate(fixtures.context(
            applicationMetadata: fixtures.applicationMetadata(bundleIdentifier: fixtures.otherBundleIdentifier)
        ))
        let mismatched = evaluate(package: .missing,
                                  profile: .verified(policy: mismatch,
                                                     expiration: fixtures.expirationDate,
                                                     claimsRepresentable: true))
        XCTAssertEqual(mismatched.state(for: .bundleIdentifier), .blocked)
        XCTAssertTrue(mismatched.issues.contains(where: { $0.id == .bundleMismatch }))
        XCTAssertTrue(mismatched.issues.allSatisfy {
            !$0.technicalDetails.contains(fixtures.teamIdentifier) &&
            !$0.technicalDetails.contains(fixtures.bundleIdentifier)
        })
    }

    func testCertificateAndProfileExpiryAreEvaluatedAtEachScanTime() {
        let fixtures = ProvisioningPolicyFixtures.self
        let identityMetadata = fixtures.identityMetadata()
        let identity = SigningIdentity(
            id: identityMetadata.id, certificate: identityMetadata.certificate,
            keyAvailability: .available, association: .matched, capabilityState: .ready
        )
        let soon = fixtures.expirationDate.addingTimeInterval(-7 * 86_400)
        let expired = fixtures.expirationDate.addingTimeInterval(1)
        let record = LibraryFixtures.record()

        for (date, certificateState, profileState) in [
            (soon, SigningCheckState.attention, SigningCheckState.attention),
            (expired, SigningCheckState.blocked, SigningCheckState.blocked)
        ] {
            let policy = fixtures.validate(fixtures.context(), at: date)
            let report = SigningDiagnosticsEvaluation.evaluate(
                record: record, package: .missing, identity: .selected(identity),
                profile: .verified(policy: policy, expiration: fixtures.expirationDate,
                                   claimsRepresentable: true),
                emitDEREntitlements: false, at: date
            )
            XCTAssertEqual(report.state(for: .certificate), certificateState)
            XCTAssertEqual(report.state(for: .profile), profileState)
        }
    }

    func testUnrepresentableEntitlementsAreBlockedNotReplacedWithEmptyClaims() {
        let fixtures = ProvisioningPolicyFixtures.self
        let compatible = fixtures.validate(fixtures.context())
        let report = evaluate(package: .missing,
                              profile: .verified(policy: compatible,
                                                 expiration: fixtures.expirationDate,
                                                 claimsRepresentable: false))
        XCTAssertEqual(report.state(for: .entitlements), .blocked)
        XCTAssertTrue(report.issues.contains(where: { $0.id == .entitlementsInvalid }))
    }

    private func evaluate(
        package: SigningPackageEvidence, profile: SigningProfileEvidence,
        emitDER: Bool = false
    ) -> SigningDiagnosticsReport {
        SigningDiagnosticsEvaluation.evaluate(
            record: LibraryFixtures.record(), package: package, identity: .notSelected,
            profile: profile, emitDEREntitlements: emitDER, at: instant
        )
    }
}
