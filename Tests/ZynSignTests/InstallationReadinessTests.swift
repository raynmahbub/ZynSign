import XCTest
@testable import ZynSign

/// Tests for the readiness evaluation: what each check does with its
/// evidence, what blocks, what does not, and the honesty of the summary,
/// guidance, and spoken forms.
final class InstallationReadinessTests: XCTestCase {

    // MARK: - The passing shape

    func testEvidenceWithEverythingEstablishedIsReady() {
        let report = InstallationReadinessReport.evaluate(InstallationFixtures.passingEvidence())

        XCTAssertTrue(report.isReady)
        XCTAssertTrue(report.blockedChecks.isEmpty)
        XCTAssertTrue(report.attentionChecks.isEmpty)
        XCTAssertTrue(report.notPerformedChecks.isEmpty)
        XCTAssertEqual(report.outcomes.count, InstallationReadinessCheck.allCases.count)
        for check in InstallationReadinessCheck.presentationOrder {
            XCTAssertEqual(report.state(of: check), .passed, "\(check) should pass")
        }
    }

    // MARK: - Signed

    func testMissingSigningRunIsNotPerformedAndDoesNotBlock() {
        var evidence = InstallationFixtures.passingEvidence()
        evidence.signingOutcome = nil

        let report = InstallationReadinessReport.evaluate(evidence)

        XCTAssertEqual(
            report.state(of: .signedArtifact)?.isNotPerformed,
            true,
            "No journal evidence must read as not performed, never as a pass or a failure."
        )
        XCTAssertTrue(report.isReady)
    }

    func testFailedAndCancelledSigningRunsBlock() {
        var failed = InstallationFixtures.passingEvidence()
        failed.signingOutcome = .failed
        XCTAssertFalse(InstallationReadinessReport.evaluate(failed).isReady)

        var cancelled = InstallationFixtures.passingEvidence()
        cancelled.signingOutcome = .cancelled
        XCTAssertFalse(InstallationReadinessReport.evaluate(cancelled).isReady)
    }

    // MARK: - Verification

    func testUnverifiedArtifactBlocks() {
        var evidence = InstallationFixtures.passingEvidence()
        evidence.verificationStatus = nil

        let report = InstallationReadinessReport.evaluate(evidence)

        XCTAssertFalse(report.isReady, "ZynSign verifies artifacts before presenting them as ready.")
        XCTAssertEqual(report.blockedChecks, [.artifactVerification])
        XCTAssertTrue(report.summary.contains("Verified"))
    }

    func testInvalidAndUnsupportedVerificationBlock() {
        var invalid = InstallationFixtures.passingEvidence()
        invalid.verificationStatus = .invalid
        XCTAssertFalse(InstallationReadinessReport.evaluate(invalid).isReady)

        var unsupported = InstallationFixtures.passingEvidence()
        unsupported.verificationStatus = .unsupported
        let report = InstallationReadinessReport.evaluate(unsupported)
        XCTAssertFalse(report.isReady, "Unsupported is never success.")
        XCTAssertTrue(report.state(of: .artifactVerification)?.isBlocking ?? false)
    }

    func testWarningVerificationDoesNotBlock() {
        var evidence = InstallationFixtures.passingEvidence()
        evidence.verificationStatus = .warning

        let report = InstallationReadinessReport.evaluate(evidence)

        XCTAssertTrue(report.isReady)
        XCTAssertEqual(report.attentionChecks, [.artifactVerification])
        XCTAssertTrue(report.summary.contains("notes"))
    }

    // MARK: - Package and export

    func testMissingArtifactBlocksThePackageCheck() {
        var evidence = InstallationFixtures.passingEvidence()
        evidence.artifactAvailable = false

        let report = InstallationReadinessReport.evaluate(evidence)

        XCTAssertFalse(report.isReady)
        XCTAssertEqual(report.blockedChecks, [.packageReadable])
    }

    func testUnmeasuredFingerprintAttendsWithoutBlocking() {
        var evidence = InstallationFixtures.passingEvidence()
        evidence.fingerprintRecorded = false

        let report = InstallationReadinessReport.evaluate(evidence)

        XCTAssertTrue(report.isReady)
        XCTAssertEqual(report.attentionChecks, [.exportCompleted])
    }

    // MARK: - Identity currency

    func testExpiredProfileBlocks() {
        var evidence = InstallationFixtures.passingEvidence()
        evidence.profileExpiresAt = evidence.now.addingTimeInterval(-1)

        let report = InstallationReadinessReport.evaluate(evidence)

        XCTAssertFalse(report.isReady)
        XCTAssertEqual(report.blockedChecks, [.signingAssetsCurrent])
    }

    func testExpiredCertificateBlocks() {
        var evidence = InstallationFixtures.passingEvidence()
        evidence.certificateExpiresAt = evidence.now.addingTimeInterval(-1)

        let report = InstallationReadinessReport.evaluate(evidence)

        XCTAssertFalse(report.isReady)
        XCTAssertEqual(report.blockedChecks, [.signingAssetsCurrent])
    }

    func testUnrecordedExpiryDatesAreNotPerformedAndDoNotBlock() {
        var evidence = InstallationFixtures.passingEvidence()
        evidence.profileExpiresAt = nil
        evidence.certificateExpiresAt = nil

        let report = InstallationReadinessReport.evaluate(evidence)

        XCTAssertTrue(report.isReady)
        XCTAssertEqual(report.notPerformedChecks, [.signingAssetsCurrent])
        XCTAssertTrue(report.guidance.contains { $0.contains("could not check") },
                      "Open questions are named, never hidden.")
    }

    // MARK: - Metadata

    func testMissingBundleIdentifierBlocks() {
        var evidence = InstallationFixtures.passingEvidence()
        evidence.bundleIdentifier = nil

        let report = InstallationReadinessReport.evaluate(evidence)

        XCTAssertFalse(report.isReady)
        XCTAssertEqual(report.blockedChecks, [.deliveryMetadata])
    }

    func testMissingNameOrVersionAttendsWithoutBlocking() {
        var noName = InstallationFixtures.passingEvidence()
        noName.displayName = nil
        XCTAssertEqual(InstallationReadinessReport.evaluate(noName).attentionChecks, [.deliveryMetadata])

        var noVersion = InstallationFixtures.passingEvidence()
        noVersion.shortVersion = nil
        XCTAssertEqual(InstallationReadinessReport.evaluate(noVersion).attentionChecks, [.deliveryMetadata])
    }

    // MARK: - Rendering

    func testGuidanceNeverImpliesPlatformAcceptance() {
        let ready = InstallationReadinessReport.evaluate(InstallationFixtures.passingEvidence())
        XCTAssertTrue(ready.guidance.contains { $0.contains("appears ready") })
        XCTAssertTrue(
            ready.guidance.contains { $0.contains("the platform's decision") },
            "Even a fully passing report names the boundary: acceptance is the platform's."
        )

        let blocked = InstallationReadinessReport.evaluate(InstallationFixtures.passingEvidence().with(verificationStatus: nil))
        XCTAssertTrue(blocked.guidance.contains { $0.contains("blocked checks") })
    }

    func testSpokenSummaryNamesBlockersForVoiceOver() {
        var evidence = InstallationFixtures.passingEvidence()
        evidence.verificationStatus = nil
        evidence.artifactAvailable = false

        let spoken = InstallationReadinessReport.evaluate(evidence).spokenSummary

        XCTAssertTrue(spoken.contains("Not ready"))
        XCTAssertTrue(spoken.contains("Verified"))
        XCTAssertTrue(spoken.contains("Package"))
    }

    func testSpokenSummaryForACleanReportIsReady() {
        let spoken = InstallationReadinessReport.evaluate(InstallationFixtures.passingEvidence()).spokenSummary
        XCTAssertTrue(spoken.hasPrefix("Ready to deliver"))
    }
}

/// Small evidence mutation helper for readability in the tests above.
private extension InstallationReadinessEvidence {
    func with(verificationStatus: ArtifactVerificationStatus?) -> InstallationReadinessEvidence {
        var copy = self
        copy.verificationStatus = verificationStatus
        return copy
    }
}
