import Foundation

/// The result of a successful cryptographic signing operation.
///
/// A `SigningResult` means exactly one thing: the requested generic
/// cryptographic operation completed and produced a signature. It is not a
/// statement that anything is code-signed, that an artifact is valid, that
/// an identity is trusted, that a profile authorizes anything, or that
/// anything can be installed. Those are separate questions for later stages.
///
/// A successful result claims:
///
///     signature bytes
///         produced by the identity's protected key
///
/// and nothing else. In particular:
///
///     cryptographic signature succeeded
///         ≠
///     Apple code signing valid
///         ≠
///     provisioning authorized
///         ≠
///     installation eligible
///
/// and this type carries no field that could collapse that distinction.
struct SigningResult: Equatable, Hashable {

    /// The signature bytes the operation produced.
    let signature: Data

    /// The signature operation that produced the signature.
    let algorithm: SigningAlgorithm

    /// The digest algorithm the operation works on.
    let digestAlgorithm: DigestAlgorithm

    /// The identity whose capability produced the signature.
    let identityID: SigningIdentityIdentifier

    /// The key family the signature was produced under, as reported by the
    /// capability.
    let publicKeyAlgorithm: PublicKeyAlgorithm

    /// The signing identity's certificate fingerprint, when the store could
    /// provide it. A reference for identification and display, not a trust
    /// statement. `nil` when the engine produced the result directly or the
    /// store could not describe the identity after the fact.
    let certificateFingerprint: CertificateFingerprint?

    /// The digest that was signed, when the request carried one. `nil` when
    /// the request carried a message: the platform primitive hashed it
    /// internally, and ZynSign does not recompute the value.
    let signedDigest: Digest?

    /// The operation context the request carried, when it had one.
    let context: SigningOperationContext?

    /// Creates a signing result.
    init(
        signature: Data,
        algorithm: SigningAlgorithm,
        digestAlgorithm: DigestAlgorithm,
        identityID: SigningIdentityIdentifier,
        publicKeyAlgorithm: PublicKeyAlgorithm,
        certificateFingerprint: CertificateFingerprint? = nil,
        signedDigest: Digest? = nil,
        context: SigningOperationContext? = nil
    ) {
        self.signature = signature
        self.algorithm = algorithm
        self.digestAlgorithm = digestAlgorithm
        self.identityID = identityID
        self.publicKeyAlgorithm = publicKeyAlgorithm
        self.certificateFingerprint = certificateFingerprint
        self.signedDigest = signedDigest
        self.context = context
    }

    /// A redacted diagnostic rendering: the operation's facts and byte
    /// counts. It never carries the signature bytes, the signed data, any
    /// key, or any credential.
    var diagnosticDescription: String {
        var parts = [
            "crypto.signature(algorithm \(algorithm.rawValue))",
            "crypto.digest(\(digestAlgorithm.rawValue))",
            "crypto.key(\(publicKeyAlgorithm.displayName))",
            "crypto.identity(\(identityID.rawValue))",
            "crypto.signatureBytes(\(signature.count))",
        ]
        if let certificateFingerprint {
            parts.append("crypto.certificate(\(certificateFingerprint.hexDigest))")
        }
        if let signedDigest {
            parts.append("crypto.signedDigest(\(signedDigest.algorithm.rawValue))")
        }
        if let context {
            parts.append("crypto.context(\(context.label))")
        }
        return parts.joined(separator: " ")
    }
}
