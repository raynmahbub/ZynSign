import XCTest
@testable import ZynSign

final class SignatureVerificationTests: XCTestCase {

    // MARK: - Outcome model

    func testOutcomesAreDistinctExplicitFacts() {
        // "Verified", "does not verify", "could not be performed", and
        // "could not conclude" are four different facts.
        let outcomes: [SignatureVerificationOutcome] = [
            .valid,
            .invalid,
            .unsupported(.unsupportedAlgorithm),
            .failed(.malformedSignature),
        ]
        XCTAssertEqual(Set(outcomes).count, 4)
        XCTAssertEqual(outcomes[0].isValid, true)
        XCTAssertEqual(outcomes.dropFirst().allSatisfy { !$0.isValid }, true)

        // Conclusions and non-conclusions stay separable.
        XCTAssertTrue(SignatureVerificationOutcome.valid.isConclusion)
        XCTAssertTrue(SignatureVerificationOutcome.invalid.isConclusion)
        XCTAssertFalse(SignatureVerificationOutcome.unsupported(.platformLimitation).isConclusion)
        XCTAssertFalse(SignatureVerificationOutcome.failed(.verificationFailure).isConclusion)
    }

    func testUnsupportedCarriesItsStructuredReason() {
        XCTAssertEqual(SignatureVerificationOutcome.unsupported(.platformLimitation),
                       .unsupported(.platformLimitation))
        XCTAssertNotEqual(SignatureVerificationOutcome.unsupported(.platformLimitation),
                          .unsupported(.unsupportedAlgorithm))
        XCTAssertEqual(SignatureVerificationOutcome.unsupported(.incompatibleKey),
                       .unsupported(.incompatibleKey))
    }

    // MARK: - The unavailable fallback

    func testUnavailableMechanismReportsUnavailableNeverSkips() throws {
        let verifier = UnavailableCryptographicSignatureVerifier()
        let certificate = try CMSVerificationTestSupport.certificate(CertificateFixtures.validDER)
        let signature = Data(repeating: 0x01, count: 256)
        let message = Data("synthetic".utf8)

        for algorithm in SigningAlgorithm.allCases {
            let outcome = verifier.verify(
                signature: signature,
                message: .message(message),
                algorithm: algorithm,
                certificate: certificate
            )
            // A missing mechanism is reported as a limitation of this build.
            // It is never answered with a guess and never reported as a
            // failure of the presented signature.
            XCTAssertEqual(outcome, .unsupported(.platformLimitation))
        }
    }

    // MARK: - The port is substitutable for tests

    func testVerifierPortIsSubstitutableWithARecordingDouble() throws {
        let verifier = RecordingCryptographicSignatureVerifier()
        verifier.outcome = .valid
        let certificate = try CMSVerificationTestSupport.certificate(CertificateFixtures.ecDER)
        let digest = Digest(algorithm: .sha256, bytes: Data(repeating: 0x09, count: 32))!

        let outcome = verifier.verify(
            signature: Data(repeating: 0x02, count: 64),
            message: .digest(digest),
            algorithm: .ecdsaX962SHA256Digest,
            certificate: certificate
        )

        XCTAssertEqual(outcome, .valid)
        XCTAssertEqual(verifier.callCount, 1)
        // The double received the digest value, not a re-encoding.
        XCTAssertEqual(verifier.lastCall?.input, .digest(digest))
        XCTAssertEqual(verifier.lastCall?.algorithm, .ecdsaX962SHA256Digest)
        XCTAssertEqual(
            verifier.lastCall?.certificateFingerprint,
            certificate.fingerprint
        )
    }
}
