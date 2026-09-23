#if os(iOS)
import Foundation
import Security

/// Signature verification through the Security framework's key primitives.
///
/// The signature is checked with `SecKeyVerifySignature` (iOS 10.0+) under
/// the operation `algorithm` selects, with the public key read from the
/// presented certificate (`SecCertificateCreateWithData`, iOS 2.0+;
/// `SecCertificateCopyKey`, iOS 12.0+). Hashing stays inside the platform
/// primitive: a message is handed over whole under a message-based
/// operation, and a digest is handed over as-is under a digest-based
/// operation. ZynSign never recomputes what the platform hashes.
///
/// The outcome is a value, not an exception: a signature that does not
/// verify is `.invalid`; an operation the platform cannot perform is
/// `.unsupported`; an operation that could not conclude is `.failed`. The
/// status mapping reuses the CMS boundary's mismatch detection so that a
/// plain signature mismatch is never confused with an unavailable
/// mechanism.
///
/// Resource handling: both platform objects come from `Create`/`Copy`
/// functions and are owned by Swift's Core Foundation bridging, so this type
/// performs no manual retain or release, keeps no reference after the call,
/// and hands no `SecCertificate`, `SecKey`, or `CFError` to a caller.
///
/// What a `.valid` outcome establishes: the signature over the presented
/// bytes was produced by the private key matching this certificate's public
/// key. It does not establish that the certificate is currently valid, that
/// it chains to an anchor, that it is trusted, that Apple issued it, or
/// that anything is correctly code signed. Those are separate operations
/// this boundary does not perform.
struct AppleSignatureVerifier: CryptographicSignatureVerifier {

    init() {}

    func verify(
        signature: Data,
        message: SigningInput,
        algorithm: SigningAlgorithm,
        certificate: Certificate
    ) -> SignatureVerificationOutcome {
        // An empty signature carries no signature. This is a malformed
        // value, not a mismatch: no platform primitive is consulted.
        guard !signature.isEmpty else {
            return .failed(.malformedSignature)
        }

        var data: Data
        switch message {
        case .message(let value):
            data = value
        case .digest(let digest):
            // A digest must be one the operation works on. Re-hashing it or
            // accepting a different algorithm would be a silent
            // substitution.
            guard digest.algorithm == algorithm.digestAlgorithm else {
                return .failed(.invalidInput)
            }
            data = digest.bytes
        }

        guard !certificate.derData.isEmpty else {
            return .failed(.certificateUnavailable)
        }

        // The certificate's own key family must match the operation's. This
        // fast, deterministic check reports the combination as incompatible
        // before a platform primitive is asked to perform it.
        guard certificate.metadata.publicKeyInfo.algorithm == algorithm.publicKeyAlgorithm else {
            return .unsupported(.incompatibleKey)
        }

        guard let platformCertificate = SecCertificateCreateWithData(nil, certificate.derData as CFData) else {
            // The platform did not accept the encoding. No conclusion can
            // be drawn about the signature.
            return .failed(.certificateUnavailable)
        }
        guard let publicKey = SecCertificateCopyKey(platformCertificate) else {
            return .failed(.certificateUnavailable)
        }

        let keyAlgorithm = algorithm.securityAlgorithm
        guard SecKeyIsAlgorithmSupported(publicKey, .verify, keyAlgorithm) else {
            // A coherent input this platform cannot perform. Reported as a
            // limitation of the operation, not a defect in the signature.
            return .unsupported(.unsupportedAlgorithm)
        }

        var failure: Unmanaged<CFError>?
        let verified = SecKeyVerifySignature(
            publicKey,
            keyAlgorithm,
            data as CFData,
            signature as CFData,
            &failure
        )
        if verified {
            return .valid
        }

        let error = failure?.takeRetainedValue()
        // A plain mismatch is a conclusion, not an error.
        if CMSSecurityErrorMapping.isSignatureMismatch(error) {
            return .invalid
        }
        switch CMSSecurityErrorMapping.status(of: error) {
        case .some(errSecUnimplemented), .some(errSecMissingEntitlement), .some(errSecAuthFailed):
            // The platform cannot perform this verification here.
            return .failed(.platformLimitation)
        default:
            return .failed(.verificationFailure)
        }
    }
}
#endif
