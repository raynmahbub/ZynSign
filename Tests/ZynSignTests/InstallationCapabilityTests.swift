import XCTest
@testable import ZynSign

/// Tests for the installation-capability assessment.
///
/// The assessment never reports an artifact as installable: no supported
/// delivery mechanism exists on the platform. These tests pin the exact
/// limitation sets each evidence combination produces, so that
/// installation-capability messaging stays precise and honest.
final class InstallationCapabilityTests: XCTestCase {

    func testFullyEstablishedEvidenceStillReportsNoMechanism() {
        let assessment = InstallationCapabilityAssessment.assess(
            InstallationEvidence(
                profileStatus: .valid,
                deviceAuthorized: true,
                platformSupported: true
            )
        )
        XCTAssertFalse(assessment.supported)
        XCTAssertEqual(assessment.limitations, [.noDeliveryMechanism])
        XCTAssertTrue(assessment.summary.contains("not available"))
    }

    func testAbsentEvidenceReportsEveryUnknown() {
        let assessment = InstallationCapabilityAssessment.assess(
            InstallationEvidence(profileStatus: .indeterminate)
        )
        XCTAssertFalse(assessment.supported)
        XCTAssertEqual(
            assessment.limitations,
            [.noDeliveryMechanism, .profileNotCompatible, .deviceAuthorizationUnknown, .platformSupportUnknown]
        )
    }

    func testNegativeEvidenceReportsNegativeLimitations() {
        let assessment = InstallationCapabilityAssessment.assess(
            InstallationEvidence(
                profileStatus: .invalid,
                deviceAuthorized: false,
                platformSupported: false
            )
        )
        XCTAssertFalse(assessment.supported)
        XCTAssertEqual(
            assessment.limitations,
            [.profileNotCompatible, .deviceNotAuthorized, .platformUnsupported].reduce(
                into: [InstallationLimitation.noDeliveryMechanism]
            ) { $0.append($1) }
        )
    }

    func testUnsupportedProfileStatusCountsAsNotCompatible() {
        let assessment = InstallationCapabilityAssessment.assess(
            InstallationEvidence(
                profileStatus: .unsupported,
                deviceAuthorized: true,
                platformSupported: true
            )
        )
        XCTAssertFalse(assessment.supported)
        XCTAssertEqual(assessment.limitations, [.noDeliveryMechanism, .profileNotCompatible])
    }

    func testLimitationMessagesAreFixedAndRedacted() {
        for limitation in InstallationLimitation.allCases {
            XCTAssertFalse(limitation.message.isEmpty)
            XCTAssertFalse(limitation.message.contains("TEAM"))
            XCTAssertFalse(limitation.message.contains("com.example"))
        }
        XCTAssertEqual(InstallationLimitation.allCases.count, 6)
    }

    func testAssessmentIsDeterministic() {
        let evidence = InstallationEvidence(profileStatus: .valid)
        XCTAssertEqual(
            InstallationCapabilityAssessment.assess(evidence),
            InstallationCapabilityAssessment.assess(evidence)
        )
    }
}
