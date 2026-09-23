#if os(iOS)
import Foundation
import Security

/// CMS signature verification through the Security framework's key APIs.
///
/// Apple's CMS decoder family is documented for macOS only — `CMSDecoderCreate`
/// and `CMSDecoderCopySignerStatus` list macOS 10.5 and no iOS availability,
/// and `CMSSignerStatus` lists macOS and Mac Catalyst only — so no platform CMS
/// service can perform this check on the product runtime. The signature is
/// instead verified with the primitives that are documented for iOS: a public
/// key read from the signer's certificate (`SecCertificateCreateWithData`,
/// `SecCertificateCopyKey`) and `SecKeyVerifySignature` under the algorithm the
/// CMS declared, mapped by `CMSVerificationAlgorithm`.
///
/// Hashing stays inside the platform primitive: the message is handed over
/// whole, under a message-based algorithm, rather than as a digest ZynSign
/// computed. Where CMS signed attributes exist, the message is their
/// `SET OF` re-encoding, which is what the signature covers.
///
/// Resource handling: both platform objects come from `Create`/`Copy`
/// functions and are owned by Swift's Core Foundation bridging, so this type
/// performs no manual retain or release, keeps no reference after the call, and
/// never hands a `SecCertificate`, `SecKey`, `OSStatus`, or `CFError` to a
/// caller. Failures are mapped to the CMS error vocabulary, with a numeric
/// status recorded only in redacted diagnostic detail.
///
/// What a `true` result establishes: the signature over this message was
/// produced by the private key matching this certificate's public key. It does
/// not establish that the certificate is currently valid, that it chains to an
/// anchor, that it is trusted, that Apple issued it, or that a profile is
/// authorized. Chain and policy evaluation are separate operations that ZS-018
/// does not perform.
struct AppleCMSSignatureVerifier: CMSSignatureVerifier {

    init() {}

    func verify(
        message: Data,
        signature: Data,
        algorithm: CMSVerificationAlgorithm,
        certificate: Certificate
    ) throws -> Bool {
        let keyAlgorithm: SecKeyAlgorithm
        switch algorithm {
        case .rsaPKCS1SHA256Message:
            keyAlgorithm = .rsaSignatureMessagePKCS1v15SHA256
        case .ecdsaX962SHA256Message:
            keyAlgorithm = .ecdsaSignatureMessageX962SHA256
        case .unsupported(let digest, let signatureAlgorithm):
            throw ZynSignError.cms(
                .unsupportedAlgorithm,
                diagnosticDetail: "The CMS declares digest \(digest) with signature algorithm \(signatureAlgorithm)."
            )
        }

        guard !message.isEmpty else {
            throw ZynSignError.cms(
                .payloadUnavailable,
                diagnosticDetail: "There is no signed message to verify."
            )
        }
        guard !signature.isEmpty else {
            throw ZynSignError.cms(
                .malformedCMS,
                diagnosticDetail: "The CMS signature value is empty."
            )
        }
        guard !certificate.derData.isEmpty else {
            throw ZynSignError.cms(
                .signerCertificateUnavailable,
                diagnosticDetail: "The signer certificate carries no encoding."
            )
        }

        guard let platformCertificate = SecCertificateCreateWithData(nil, certificate.derData as CFData) else {
            throw ZynSignError.cms(
                .signerCertificateUnavailable,
                diagnosticDetail: "The platform did not accept the signer certificate encoding."
            )
        }
        guard let publicKey = SecCertificateCopyKey(platformCertificate) else {
            throw ZynSignError.cms(
                .signerCertificateUnavailable,
                diagnosticDetail: "The platform could not read a public key from the signer certificate."
            )
        }
        guard SecKeyIsAlgorithmSupported(publicKey, .verify, keyAlgorithm) else {
            throw ZynSignError.cms(
                .unsupportedAlgorithm,
                diagnosticDetail: "The signer's public key does not support the mapped verification algorithm."
            )
        }

        var failure: Unmanaged<CFError>?
        let verified = SecKeyVerifySignature(
            publicKey,
            keyAlgorithm,
            message as CFData,
            signature as CFData,
            &failure
        )
        if verified {
            return true
        }
        let error = failure?.takeRetainedValue()
        if CMSSecurityErrorMapping.isSignatureMismatch(error) {
            return false
        }
        throw CMSSecurityErrorMapping.verificationFailure(error)
    }
}

/// Maps platform signature-verification failures onto the CMS error vocabulary.
///
/// A mismatch is data, not a defect: it is reported so the caller can record
/// that the signature does not verify. Anything else is reported as an
/// unavailable mechanism or an unexpected failure, never as a claim about the
/// profile's authenticity.
enum CMSSecurityErrorMapping {

    /// Whether the platform reported that the signature simply does not match.
    static func isSignatureMismatch(_ error: CFError?) -> Bool {
        guard let status = status(of: error) else { return false }
        return status == errSecVerifyFailed
    }

    /// A typed error for a verification attempt that could not conclude.
    static func verificationFailure(_ error: CFError?) -> ZynSignError {
        guard let status = status(of: error) else {
            return ZynSignError.cms(
                .unexpectedSecurityError,
                diagnosticDetail: "The platform reported a verification failure without a status code."
            )
        }
        switch status {
        case errSecVerifyFailed:
            return ZynSignError.cms(
                .signatureInvalid,
                diagnosticDetail: "The platform rejected the CMS signature (platform error code \(status))."
            )
        case errSecUnimplemented, errSecMissingEntitlement, errSecAuthFailed:
            return ZynSignError.cms(
                .platformVerificationUnavailable,
                diagnosticDetail: "The platform cannot perform this verification (platform error code \(status))."
            )
        default:
            return ZynSignError.cms(
                .unexpectedSecurityError,
                diagnosticDetail: "Signature verification failed (platform error code \(status))."
            )
        }
    }

    private static func status(of error: CFError?) -> OSStatus? {
        guard let error else { return nil }
        guard CFErrorGetDomain(error) as String == NSOSStatusErrorDomain else { return nil }
        return OSStatus(exactly: CFErrorGetCode(error))
    }
}
#endif
