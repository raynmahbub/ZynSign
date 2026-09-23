import Foundation

/// Explicit input semantics and signature encoding, independent of Security.
/// The certificate's issuer-signature algorithm does not select this operation.
enum SigningAlgorithm: String, CaseIterable, Hashable {
    /// Hash the message with SHA-256, then produce an RSA PKCS#1 v1.5 signature.
    case rsaPKCS1SHA256Message
    /// Sign exactly one SHA-256 digest with RSA PKCS#1 v1.5.
    case rsaPKCS1SHA256Digest
    /// Hash the message with SHA-256, then produce a DER X9.62 ECDSA signature.
    case ecdsaX962SHA256Message
    /// Sign exactly one SHA-256 digest, returning a DER X9.62 ECDSA signature.
    case ecdsaX962SHA256Digest

    var publicKeyAlgorithm: PublicKeyAlgorithm {
        switch self {
        case .rsaPKCS1SHA256Message, .rsaPKCS1SHA256Digest: return .rsa
        case .ecdsaX962SHA256Message, .ecdsaX962SHA256Digest: return .ec
        }
    }

    var digestLength: Int? {
        switch self {
        case .rsaPKCS1SHA256Digest, .ecdsaX962SHA256Digest: return 32
        case .rsaPKCS1SHA256Message, .ecdsaX962SHA256Message: return nil
        }
    }

    /// The digest algorithm this operation works on.
    ///
    /// Every operation in the current set works on SHA-256. Recording the
    /// digest on the operation keeps the digest, the key family, and the
    /// signature scheme distinct instead of implicit.
    var digestAlgorithm: DigestAlgorithm {
        switch self {
        case .rsaPKCS1SHA256Message, .rsaPKCS1SHA256Digest,
             .ecdsaX962SHA256Message, .ecdsaX962SHA256Digest:
            return .sha256
        }
    }

    func validate(data: Data, keyAlgorithm: PublicKeyAlgorithm) throws {
        guard keyAlgorithm == publicKeyAlgorithm else {
            throw ZynSignError.identity(.unsupportedSigningAlgorithm)
        }
        if let digestLength, data.count != digestLength {
            throw ZynSignError.identity(.invalidSigningInput)
        }
    }
}

/// A private signing operation, never a private-key export interface.
/// Only future signing use cases receive this capability; UI gets metadata.
protocol SigningCapability {
    var identityID: SigningIdentityIdentifier { get }
    var publicKeyAlgorithm: PublicKeyAlgorithm { get }
    /// A snapshot only. Every operation must recheck availability.
    var isAvailable: Bool { get }
    var supportedAlgorithms: Set<SigningAlgorithm> { get }

    /// Returns signature bytes only. Implementations throw structured
    /// `ZynSignError` values without retaining platform error payloads.
    func sign(data: Data, algorithm: SigningAlgorithm) throws -> Data
}

/// Digest vocabulary shared with certificate algorithms; not implicit signing policy.
enum DigestAlgorithm: String, CaseIterable, Equatable, Hashable {
    case sha1
    case sha256
    case sha384
    case sha512

    var digestLength: Int {
        switch self {
        case .sha1: return 20
        case .sha256: return 32
        case .sha384: return 48
        case .sha512: return 64
        }
    }
}
