import XCTest
@testable import ZynSign

/// Tests for the pairing / JIT / mux capability boundary.
///
/// Every capability stays `supported == false` on every path — that is the
/// honest platform fact these tests pin. The typed limitation sets, the
/// feasibility notes, and the documentation anchors are asserted exactly,
/// so a future edit cannot quietly soften the boundary.
final class PairingCapabilityTests: XCTestCase {

    // MARK: - Never supported

    func testEveryCapabilityIsUnavailable() {
        for assessment in PairingCapabilityAssessment.allUnavailable {
            XCTAssertFalse(assessment.supported, "\(assessment.capability) must stay unsupported.")
            XCTAssertFalse(assessment.limitations.isEmpty)
            XCTAssertFalse(assessment.summary.isEmpty)
        }
    }

    func testAllCasesAreCovered() {
        XCTAssertEqual(PairingCapability.allCases.count, 4)
        XCTAssertEqual(PairingCapabilityAssessment.allUnavailable.count, PairingCapability.allCases.count)
    }

    func testAssessmentIsDeterministic() {
        let first = PairingCapabilityAssessment.assess(.pairing)
        let second = PairingCapabilityAssessment.assess(.pairing)
        XCTAssertEqual(first, second)
    }

    // MARK: - Exact limitation sets

    func testPairingLimitationsAreExact() {
        let assessment = PairingCapabilityAssessment.assess(.pairing)
        XCTAssertEqual(assessment.limitations, [.requiresLockdownDaemon, .requiresPrivateEntitlement, .notComposed])
    }

    func testJITLimitationsAreExact() {
        let assessment = PairingCapabilityAssessment.assess(.jit)
        XCTAssertEqual(assessment.limitations, [.requiresDeveloperMode, .requiresPrivateEntitlement, .notComposed])
    }

    func testMuxLimitationsAreExact() {
        let assessment = PairingCapabilityAssessment.assess(.mux)
        XCTAssertEqual(assessment.limitations, [.requiresLockdownDaemon, .requiresHostTool, .notComposed])
    }

    func testOpenSSLLinkageLimitationsAreExact() {
        let assessment = PairingCapabilityAssessment.assess(.openSSLLinkage)
        XCTAssertEqual(assessment.limitations, [.notComposed])
    }

    // MARK: - Presentation text

    func testSummariesNameTheCapabilityAndTheFirstLimitation() {
        for assessment in PairingCapabilityAssessment.allUnavailable {
            XCTAssertTrue(assessment.summary.contains(assessment.capability.rawValue))
            let first = assessment.limitations.first
            XCTAssertNotNil(first)
            XCTAssertEqual(assessment.summary, "\(assessment.capability.rawValue) is not available: \(first?.message ?? "Not composed.")")
        }
    }

    func testLimitationMessagesAreRedactedSentences() {
        for limitation in PairingLimitation.allCases {
            let message = limitation.message
            XCTAssertFalse(message.isEmpty)
            XCTAssertTrue(message.hasSuffix("."), "Limitation text is a sentence: \(message)")
            XCTAssertFalse(message.contains("/"), "Limitation text must not carry paths: \(message)")
        }
    }

    func testEveryCapabilityHasAFeasibilityNote() {
        for capability in PairingCapability.allCases {
            let note = capability.feasibilityNote
            XCTAssertFalse(note.isEmpty)
            XCTAssertFalse(note.contains("http"), "Feasibility notes reference docs by path, not URL.")
        }
    }

    func testFeasibilityNotesNameThePrivateSurface() {
        XCTAssertTrue(PairingCapability.pairing.feasibilityNote.contains("usbmuxd"))
        XCTAssertTrue(PairingCapability.pairing.feasibilityNote.contains("com.apple.mobile.lockdown"))
        XCTAssertTrue(PairingCapability.jit.feasibilityNote.contains("get-task-allow"))
        XCTAssertTrue(PairingCapability.mux.feasibilityNote.contains("usbmuxd"))
        XCTAssertTrue(PairingCapability.openSSLLinkage.feasibilityNote.contains("Tests/Host"))
    }

    func testDocumentationAnchorsPointAtTheFeasibilityRecord() {
        for capability in PairingCapability.allCases {
            XCTAssertTrue(
                capability.documentationAnchor.hasPrefix("docs/architecture/pairing-jit-mux-feasibility.md"),
                "\(capability) anchor must point at the feasibility record."
            )
        }
    }
}
