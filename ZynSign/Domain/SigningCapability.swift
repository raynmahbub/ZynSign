import Foundation

/// The narrow abstraction for future cryptographic signing.
///
/// `SigningCapability` represents the ability to produce a signature for a
/// given identity without exposing private-key bytes. It is the only place
/// where signing happens and the only consumer of usable key material.
///
/// The abstraction must support a future implementation where signing occurs
/// through a protected key handle or API (e.g. Keychain `SecKey` with
/// non-exportable storage, Secure Enclave-backed mechanisms where applicable).
/// It must not require private-key extraction to be useful.
///
/// Design rules, following the architecture:
/// - Private key material must not be exposed as bytes through this
///   abstraction. Callers receive only signatures.
/// - The capability is opaque: it does not reveal where the key is stored,
///   how it is protected, or what its bytes are.
/// - Signing input is treated as data to be signed; the caller decides what
///   to sign (digest, CodeDirectory, etc.). The capability does not interpret
///   the input.
/// - Errors are typed and categorized, never reduced to free-form strings.
///
/// This protocol does not implement the complete code-signing engine. It is
/// the cryptographic primitive that the future signing engine will use.
protocol SigningCapability {

    /// The identifier of the signing identity this capability belongs to.
    /// Used for diagnostics and for ensuring the correct capability is used
    /// for a given identity.
    var identityID: SigningIdentityIdentifier { get }

    /// The public-key algorithm this capability uses, for compatibility
    /// checks before attempting a signature.
    var publicKeyAlgorithm: PublicKeyAlgorithm { get }

    /// Whether the underlying key is currently available for signing. A
    /// capability may exist but be temporarily unavailable (e.g. device
    /// locked, key not accessible).
    var isAvailable: Bool { get }

    /// Produces a signature over `data`.
    ///
    /// The exact signature format (e.g. RSA PKCS#1 v1.5 over digest) is
    /// determined by the key and algorithm the capability was created with.
    /// Callers must ensure `data` is what they intend to sign; this method
    /// does not hash or interpret the input unless the underlying platform
    /// API requires it.
    ///
    /// - Parameter data: The data to sign. Treated as opaque bytes.
    /// - Returns: The signature bytes.
    /// - Throws: A typed `ZynSignError` when signing is unavailable, the key
    ///   is not accessible, or the operation fails.
    func sign(data: Data) throws -> Data

    /// Produces a signature over a pre-computed digest.
    ///
    /// Some platform APIs sign digests rather than raw data. This method
    /// allows callers to provide a digest directly when that is what the
    /// platform expects. The default implementation forwards to `sign(data:)`
    /// for implementations that do not distinguish.
    ///
    /// - Parameters:
    ///   - digest: The digest to sign.
    ///   - algorithm: The digest algorithm used, for the underlying API.
    /// - Returns: The signature bytes.
    /// - Throws: A typed `ZynSignError` when signing fails.
    func sign(digest: Data, algorithm: DigestAlgorithm) throws -> Data
}

extension SigningCapability {

    func sign(digest: Data, algorithm: DigestAlgorithm) throws -> Data {
        // Default implementation treats digest as data. Platform
        // implementations that require explicit digest handling should
        // override.
        try sign(data: digest)
    }
}

/// The digest algorithm used when signing a pre-computed digest.
enum DigestAlgorithm: String, CaseIterable, Equatable, Hashable {
    case sha1
    case sha256
    case sha384
    case sha512

    /// The digest length in bytes.
    var digestLength: Int {
        switch self {
        case .sha1: return 20
        case .sha256: return 32
        case .sha384: return 48
        case .sha512: return 64
        }
    }
}
