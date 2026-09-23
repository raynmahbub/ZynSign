#if os(iOS)
import XCTest
import Security
@testable import ZynSign

/// Signature verification against the platform key primitives.
///
/// These tests run only where the primitives exist, and they are the ones
/// that check real signature mathematics: the committed synthetic RSA and
/// ECDSA signatures from the CMS fixtures over their signed-attribute
/// messages, under both the message-based and the digest-based operations,
/// a tampered signature, a changed message, and the wrong certificate.
/// They need no signed test host, no keychain, and no private key; every
/// fixture here is public test material.
///
/// A `.valid` outcome asserts only that the signature was produced by the
/// private key matching the certificate's public key. No test here asserts
/// trust, Apple issuance, code signing, or authorization. On-device
/// behaviour of these primitives remains subject to experiments E1 and E4.
final class AppleSignatureVerifierTests: XCTestCase {

    private let verifier = AppleSignatureVerifier()
    private let digest = CryptoKitMessageDigest()

    // MARK: - Accepted signatures

    func testAcceptsRSAMessageSignature() throws {
        let container = CMSFixtures.validRSASignedAttributes
        let message = try signedAttributesMessage(of: container)
        let signature = Data(container[CMSFixtures.validRSASignatureRange])
        let certificate = try CMSVerificationTestSupport.certificate(CMSFixtures.signerCertificateDER)

        let outcome = verifier.verify(
            signature: signature,
            message: .message(message),
            algorithm: .rsaPKCS1SHA256Message,
            certificate: certificate
        )
        XCTAssertEqual(outcome, .valid)
    }

    func testAcceptsRSADigestSignature() throws {
        let container = CMSFixtures.validRSASignedAttributes
        let message = try signedAttributesMessage(of: container)
        let signature = Data(container[CMSFixtures.validRSASignatureRange])
        let certificate = try CMSVerificationTestSupport.certificate(CMSFixtures.signerCertificateDER)
        let digestValue = try digest.digest(message, algorithm: .sha256)

        // The digest input path signs/checks the digest bytes as-is, under
        // the digest-based operation.
        let outcome = verifier.verify(
            signature: signature,
            message: .digest(digestValue),
            algorithm: .rsaPKCS1SHA256Digest,
            certificate: certificate
        )
        XCTAssertEqual(outcome, .valid)
    }

    func testAcceptsECDSAMessageSignature() throws {
        let container = CMSFixtures.ecDSASignedAttributes
        let message = try signedAttributesMessage(of: container)
        let structure = try CMSStructureReader.read(container)
        let signature = try XCTUnwrap(try XCTUnwrap(structure.signerInfos.first).signature)
        let certificate = try CMSVerificationTestSupport.certificate(CMSFixtures.ecSignerCertificateDER)

        let outcome = verifier.verify(
            signature: signature,
            message: .message(message),
            algorithm: .ecdsaX962SHA256Message,
            certificate: certificate
        )
        XCTAssertEqual(outcome, .valid)
    }

    func testAcceptsECDSADigestSignature() throws {
        let container = CMSFixtures.ecDSASignedAttributes
        let message = try signedAttributesMessage(of: container)
        let structure = try CMSStructureReader.read(container)
        let signature = try XCTUnwrap(try XCTUnwrap(structure.signerInfos.first).signature)
        let certificate = try CMSVerificationTestSupport.certificate(CMSFixtures.ecSignerCertificateDER)
        let digestValue = try digest.digest(message, algorithm: .sha256)

        let outcome = verifier.verify(
            signature: signature,
            message: .digest(digestValue),
            algorithm: .ecdsaX962SHA256Digest,
            certificate: certificate
        )
        XCTAssertEqual(outcome, .valid)
    }

    // MARK: - Rejected signatures are conclusions, not errors

    func testRejectsTamperedSignatureAsInvalidNotAsAnError() throws {
        let container = CMSFixtures.validRSASignedAttributes
        let message = try signedAttributesMessage(of: container)
        let certificate = try CMSVerificationTestSupport.certificate(CMSFixtures.signerCertificateDER)
        var signature = Data(container[CMSFixtures.validRSASignatureRange])
        signature[10] ^= 0x01

        let outcome = verifier.verify(
            signature: signature,
            message: .message(message),
            algorithm: .rsaPKCS1SHA256Message,
            certificate: certificate
        )
        XCTAssertEqual(outcome, .invalid)
    }

    func testRejectsSignatureOverChangedBytes() throws {
        let container = CMSFixtures.validRSASignedAttributes
        var message = try signedAttributesMessage(of: container)
        message[message.count - 2] ^= 0x01
        let signature = Data(container[CMSFixtures.validRSASignatureRange])
        let certificate = try CMSVerificationTestSupport.certificate(CMSFixtures.signerCertificateDER)

        let outcome = verifier.verify(
            signature: signature,
            message: .message(message),
            algorithm: .rsaPKCS1SHA256Message,
            certificate: certificate
        )
        XCTAssertEqual(outcome, .invalid)
    }

    func testRejectsSignatureCheckedAgainstTheWrongCertificate() throws {
        // A different RSA 2048 leaf: same key family, so the fast
        // incompatibility check does not fire and the platform check ends
        // in a mismatch.
        let container = CMSFixtures.validRSASignedAttributes
        let message = try signedAttributesMessage(of: container)
        let signature = Data(container[CMSFixtures.validRSASignatureRange])
        let wrongCertificate = try CMSVerificationTestSupport.certificate(CMSFixtures.otherCertificateDER)

        let outcome = verifier.verify(
            signature: signature,
            message: .message(message),
            algorithm: .rsaPKCS1SHA256Message,
            certificate: wrongCertificate
        )
        XCTAssertEqual(outcome, .invalid)
    }

    // MARK: - Incompatible and unsupported combinations

    func testRSAOperationAgainstAnECCertificateIsIncompatible() throws {
        // The fast, deterministic check: the certificate's own key family
        // does not match the operation's. No platform primitive is
        // consulted, so this is stable on every iOS build.
        let certificate = try CMSVerificationTestSupport.certificate(CMSFixtures.ecSignerCertificateDER)
        let container = CMSFixtures.validRSASignedAttributes
        let message = try signedAttributesMessage(of: container)
        let signature = Data(container[CMSFixtures.validRSASignatureRange])

        let outcome = verifier.verify(
            signature: signature,
            message: .message(message),
            algorithm: .rsaPKCS1SHA256Message,
            certificate: certificate
        )
        XCTAssertEqual(outcome, .unsupported(.incompatibleKey))
    }

    func testECDigestOperationAgainstAnRSACertificateIsIncompatible() throws {
        let certificate = try CMSVerificationTestSupport.certificate(CMSFixtures.signerCertificateDER)
        let digestValue = try digest.digest(Data("synthetic".utf8), algorithm: .sha256)

        let outcome = verifier.verify(
            signature: Data(repeating: 0x01, count: 64),
            message: .digest(digestValue),
            algorithm: .ecdsaX962SHA256Digest,
            certificate: certificate
        )
        XCTAssertEqual(outcome, .unsupported(.incompatibleKey))
    }

    // MARK: - Malformed and unusable inputs

    func testEmptySignatureIsMalformed() throws {
        let certificate = try CMSVerificationTestSupport.certificate(CMSFixtures.signerCertificateDER)
        let outcome = verifier.verify(
            signature: Data(),
            message: .message(Data("synthetic".utf8)),
            algorithm: .rsaPKCS1SHA256Message,
            certificate: certificate
        )
        XCTAssertEqual(outcome, .failed(.malformedSignature))
    }

    func testDigestOfTheWrongAlgorithmIsInvalidInput() throws {
        let certificate = try CMSVerificationTestSupport.certificate(CMSFixtures.signerCertificateDER)
        let digestValue = Digest(algorithm: .sha384, bytes: Data(repeating: 0x01, count: 48))!

        let outcome = verifier.verify(
            signature: Data(repeating: 0x01, count: 256),
            message: .digest(digestValue),
            algorithm: .rsaPKCS1SHA256Digest,
            certificate: certificate
        )
        // A SHA-384 digest is never re-hashed or accepted for a SHA-256
        // operation.
        XCTAssertEqual(outcome, .failed(.invalidInput))
    }

    func testCertificateWithoutEncodingIsUnavailable() throws {
        let metadata = try AppleCertificateParser().parseCertificate(derData: CertificateFixtures.validDER)
        let certificate = Certificate(metadata: metadata, derData: Data())

        let outcome = verifier.verify(
            signature: Data(repeating: 0x01, count: 256),
            message: .message(Data("synthetic".utf8)),
            algorithm: .rsaPKCS1SHA256Message,
            certificate: certificate
        )
        XCTAssertEqual(outcome, .failed(.certificateUnavailable))
    }

    func testEncodingThePlatformDoesNotAcceptIsReportedAsUnavailable() throws {
        let metadata = try AppleCertificateParser().parseCertificate(derData: CertificateFixtures.validDER)
        let notACertificate = Certificate(
            metadata: metadata,
            derData: Data([0x30, 0x03, 0x02, 0x01, 0x01])
        )

        let outcome = verifier.verify(
            signature: Data(repeating: 0x01, count: 256),
            message: .message(Data("synthetic".utf8)),
            algorithm: .rsaPKCS1SHA256Message,
            certificate: notACertificate
        )
        XCTAssertEqual(outcome, .failed(.certificateUnavailable))
    }

    // MARK: - Support

    private func signedAttributesMessage(of container: Data) throws -> Data {
        let structure = try CMSStructureReader.read(container)
        let signer = try XCTUnwrap(structure.signerInfos.first)
        return try XCTUnwrap(try XCTUnwrap(signer.signedAttributes).verificationMessage)
    }
}
#endif
