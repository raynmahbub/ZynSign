#if os(iOS)
import XCTest
import Security
@testable import ZynSign

/// Signature verification against the platform key primitives.
///
/// These tests run only where the primitives exist, and they are the ones that
/// check real signature mathematics: a synthetic RSA and a synthetic ECDSA
/// signature over fixture bytes, a tampered signature, and the wrong
/// certificate. They need no signed test host, no keychain, and no private key;
/// every fixture here is public test material.
///
/// A `true` result asserts only that the signature was produced by the private
/// key matching this certificate's public key. No test here asserts trust,
/// Apple issuance, or profile authorization.
final class AppleCMSSignatureVerifierTests: XCTestCase {

    private let verifier = AppleCMSSignatureVerifier()

    // MARK: - Accepted signatures

    func testAcceptsRSASignatureOverSignedAttributes() throws {
        let message = try signedAttributesMessage(of: CMSFixtures.validRSASignedAttributes)
        let signature = Data(CMSFixtures.validRSASignedAttributes[CMSFixtures.validRSASignatureRange])
        let certificate = try CMSVerificationTestSupport.certificate(CMSFixtures.signerCertificateDER)

        XCTAssertTrue(
            try verifier.verify(
                message: message,
                signature: signature,
                algorithm: .rsaPKCS1SHA256Message,
                certificate: certificate
            )
        )
    }

    func testAcceptsECDSASignatureOverSignedAttributes() throws {
        let container = CMSFixtures.ecDSASignedAttributes
        let structure = try CMSStructureReader.read(container)
        let signer = try XCTUnwrap(structure.signerInfos.first)
        let message = try XCTUnwrap(try XCTUnwrap(signer.signedAttributes).verificationMessage)
        let certificate = try CMSVerificationTestSupport.certificate(CMSFixtures.ecSignerCertificateDER)

        XCTAssertTrue(
            try verifier.verify(
                message: message,
                signature: signer.signature,
                algorithm: .ecdsaX962SHA256Message,
                certificate: certificate
            )
        )
    }

    // MARK: - Rejected signatures

    func testRejectsTamperedSignatureAsFalseNotAsAnError() throws {
        let message = try signedAttributesMessage(of: CMSFixtures.validRSASignedAttributes)
        let certificate = try CMSVerificationTestSupport.certificate(CMSFixtures.signerCertificateDER)
        var signature = Data(CMSFixtures.validRSASignedAttributes[CMSFixtures.validRSASignatureRange])
        signature[10] ^= 0x01

        XCTAssertFalse(
            try verifier.verify(
                message: message,
                signature: signature,
                algorithm: .rsaPKCS1SHA256Message,
                certificate: certificate
            )
        )
    }

    func testRejectsSignatureCheckedAgainstTheWrongCertificate() throws {
        let message = try signedAttributesMessage(of: CMSFixtures.validRSASignedAttributes)
        let signature = Data(CMSFixtures.validRSASignedAttributes[CMSFixtures.validRSASignatureRange])
        let wrongCertificate = try CMSVerificationTestSupport.certificate(CMSFixtures.otherCertificateDER)

        XCTAssertFalse(
            try verifier.verify(
                message: message,
                signature: signature,
                algorithm: .rsaPKCS1SHA256Message,
                certificate: wrongCertificate
            )
        )
    }

    func testRejectsSignatureOverDifferentBytes() throws {
        let message = try signedAttributesMessage(of: CMSFixtures.validRSASignedAttributes)
        let signature = Data(CMSFixtures.validRSASignedAttributes[CMSFixtures.validRSASignatureRange])
        let certificate = try CMSVerificationTestSupport.certificate(CMSFixtures.signerCertificateDER)
        var altered = message
        altered[altered.count - 2] ^= 0x01

        XCTAssertFalse(
            try verifier.verify(
                message: altered,
                signature: signature,
                algorithm: .rsaPKCS1SHA256Message,
                certificate: certificate
            )
        )
    }

    // MARK: - Failures that are not mismatches

    func testUnsupportedAlgorithmPairIsNotAttempted() throws {
        let certificate = try CMSVerificationTestSupport.certificate(CMSFixtures.signerCertificateDER)

        XCTAssertThrowsError(
            try verifier.verify(
                message: Data([0x31, 0x00]),
                signature: Data([0x00]),
                algorithm: .unsupported(
                    digestObjectIdentifier: CMSDigestAlgorithm.sha1ObjectIdentifier,
                    signatureObjectIdentifier: "1.2.840.113549.1.1.5"
                ),
                certificate: certificate
            )
        ) { error in
            XCTAssertEqual((error as? ZynSignError)?.cmsFailure, .unsupportedAlgorithm)
        }
    }

    func testAlgorithmThatDoesNotFitTheKeyIsReportedUnsupported() throws {
        // An RSA verification operation against an EC public key is not a
        // signature mismatch; it is a combination the platform cannot perform.
        let certificate = try CMSVerificationTestSupport.certificate(CMSFixtures.ecSignerCertificateDER)

        XCTAssertThrowsError(
            try verifier.verify(
                message: Data([0x31, 0x00]),
                signature: Data(repeating: 0x01, count: 64),
                algorithm: .rsaPKCS1SHA256Message,
                certificate: certificate
            )
        ) { error in
            XCTAssertEqual((error as? ZynSignError)?.cmsFailure, .unsupportedAlgorithm)
        }
    }

    func testEmptyInputsAreReportedAsTypedFailures() throws {
        let certificate = try CMSVerificationTestSupport.certificate(CMSFixtures.signerCertificateDER)
        let message = try signedAttributesMessage(of: CMSFixtures.validRSASignedAttributes)
        let signature = Data(CMSFixtures.validRSASignedAttributes[CMSFixtures.validRSASignatureRange])

        assertFailure(Data(), signature: signature, certificate: certificate, expected: .payloadUnavailable)
        assertFailure(message, signature: Data(), certificate: certificate, expected: .malformedCMS)
        assertFailure(
            message,
            signature: signature,
            certificate: Certificate(metadata: certificate.metadata, derData: Data()),
            expected: .signerCertificateUnavailable
        )
    }

    func testEncodingThePlatformDoesNotAcceptIsReportedAsUnavailableSigner() throws {
        let certificate = try CMSVerificationTestSupport.certificate(CMSFixtures.signerCertificateDER)
        let notACertificate = Certificate(
            metadata: certificate.metadata,
            derData: Data([0x30, 0x03, 0x02, 0x01, 0x01])
        )

        XCTAssertThrowsError(
            try verifier.verify(
                message: Data([0x31, 0x00]),
                signature: Data(repeating: 0x01, count: 256),
                algorithm: .rsaPKCS1SHA256Message,
                certificate: notACertificate
            )
        ) { error in
            XCTAssertEqual((error as? ZynSignError)?.cmsFailure, .signerCertificateUnavailable)
        }
    }

    // MARK: - Composed boundary

    func testComposedBoundaryVerifiesRealFixtureSignatures() throws {
        let boundary = ProvisioningProfileCMSVerifier(
            certificateParser: AppleCertificateParser(),
            signatureVerifier: AppleCMSSignatureVerifier()
        )

        let rsa = try boundary.verify(ProvisioningProfileInput(bytes: CMSFixtures.validRSASignedAttributes))
        XCTAssertEqual(rsa.status, .verified)
        XCTAssertEqual(rsa.trustEvaluation, .notPerformed)
        XCTAssertEqual(rsa.signerFingerprint?.hexDigest, CMSFixtures.signerCertificateFingerprint)

        let ec = try boundary.verify(ProvisioningProfileInput(bytes: CMSFixtures.ecDSASignedAttributes))
        XCTAssertEqual(ec.status, .verified)
        XCTAssertEqual(ec.signerFingerprint?.hexDigest, CMSFixtures.ecSignerCertificateFingerprint)

        let tampered = try boundary.verify(ProvisioningProfileInput(bytes: CMSFixtures.tamperedSignature()))
        XCTAssertEqual(tampered.status, .invalid)
        XCTAssertEqual(tampered.failure, .signatureInvalid)

        let noSigner = try boundary.verify(ProvisioningProfileInput(bytes: CMSFixtures.noSignerInfos))
        XCTAssertEqual(noSigner.status, .noSigner)

        XCTAssertThrowsError(
            try boundary.verify(ProvisioningProfileInput(bytes: CMSFixtures.detachedContent))
        ) { error in
            XCTAssertEqual((error as? ZynSignError)?.cmsFailure, .payloadUnavailable)
        }
    }

    // MARK: - Error mapping

    func testStatusMappingSeparatesMismatchFromUnavailable() {
        XCTAssertTrue(CMSSecurityErrorMapping.isSignatureMismatch(statusError(errSecVerifyFailed)))
        XCTAssertFalse(CMSSecurityErrorMapping.isSignatureMismatch(statusError(errSecUnimplemented)))
        XCTAssertFalse(CMSSecurityErrorMapping.isSignatureMismatch(nil))

        XCTAssertEqual(
            CMSSecurityErrorMapping.verificationFailure(statusError(errSecVerifyFailed)).cmsFailure,
            .signatureInvalid
        )
        XCTAssertEqual(
            CMSSecurityErrorMapping.verificationFailure(statusError(errSecUnimplemented)).cmsFailure,
            .platformVerificationUnavailable
        )
        XCTAssertEqual(
            CMSSecurityErrorMapping.verificationFailure(statusError(errSecMissingEntitlement)).cmsFailure,
            .platformVerificationUnavailable
        )
        XCTAssertEqual(
            CMSSecurityErrorMapping.verificationFailure(statusError(errSecAuthFailed)).cmsFailure,
            .platformVerificationUnavailable
        )
        XCTAssertEqual(
            CMSSecurityErrorMapping.verificationFailure(statusError(errSecParam)).cmsFailure,
            .unexpectedSecurityError
        )
        XCTAssertEqual(
            CMSSecurityErrorMapping.verificationFailure(nil).cmsFailure,
            .unexpectedSecurityError
        )
    }

    func testMappedDiagnosticsCarryCodesNotPlatformProse() {
        let error = CMSSecurityErrorMapping.verificationFailure(statusError(errSecVerifyFailed))

        XCTAssertTrue(error.debugDescription.contains("platform error code \(errSecVerifyFailed)"))
        XCTAssertFalse(error.userMessage.contains("errSec"))
        XCTAssertFalse(error.userMessage.isEmpty)
    }

    // MARK: - Support

    private func signedAttributesMessage(of container: Data) throws -> Data {
        let structure = try CMSStructureReader.read(container)
        let signer = try XCTUnwrap(structure.signerInfos.first)
        return try XCTUnwrap(try XCTUnwrap(signer.signedAttributes).verificationMessage)
    }

    private func assertFailure(
        _ message: Data,
        signature: Data,
        certificate: Certificate,
        expected: CMSFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try verifier.verify(
                message: message,
                signature: signature,
                algorithm: .rsaPKCS1SHA256Message,
                certificate: certificate
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual((error as? ZynSignError)?.cmsFailure, expected, file: file, line: line)
        }
    }

    /// A platform-style error carrying only a status code, built directly so
    /// the mapping sees exactly what Security produces.
    private func statusError(_ status: OSStatus) -> CFError? {
        CFErrorCreate(nil, kCFErrorDomainOSStatus, Int(status), nil)
    }
}
#endif
