/// The algorithm of a certificate's public key.
///
/// The algorithm identifies the cryptographic family. The key size or curve
/// carries the strength. Together they inform whether a certificate is
/// suitable for a given signing operation, but they do not establish trust.
enum PublicKeyAlgorithm: Equatable, Hashable {

    /// RSA, commonly used for code signing.
    case rsa

    /// Elliptic curve, e.g. P-256, P-384, P-521.
    case ec

    /// An algorithm ZynSign does not model explicitly. The raw identifier,
    /// typically an OID or platform-provided name, is preserved for
    /// diagnostics without being interpreted.
    case unknown(String)

    /// A human-readable name for the algorithm, suitable for diagnostics.
    var displayName: String {
        switch self {
        case .rsa: return "RSA"
        case .ec: return "EC"
        case .unknown(let identifier): return identifier
        }
    }

    /// Whether the algorithm is one ZynSign recognises for code-signing
    /// evaluation. An unknown algorithm is not automatically unsuitable, but
    /// its suitability cannot be established by the domain alone.
    var isRecognised: Bool {
        switch self {
        case .rsa, .ec: return true
        case .unknown: return false
        }
    }
}

/// Information about a certificate's public key.
///
/// The public key is the verifiable counterpart of the private signing
/// capability. Its algorithm and size inform suitability checks. The actual
/// key bytes are never carried in this type; only metadata about the key is
/// retained.
struct PublicKeyInfo: Equatable, Hashable {

    /// The algorithm family.
    let algorithm: PublicKeyAlgorithm

    /// The key size in bits, when known. For RSA, the modulus size; for EC,
    /// the field size. `nil` when the size could not be determined or the
    /// algorithm does not have a single size.
    let keySizeInBits: Int?

    /// The curve name for elliptic-curve keys, e.g. "P-256", "P-384",
    /// "prime256v1", when known. `nil` for RSA or when the curve could not be
    /// determined.
    let curveName: String?

    /// Creates public-key information.
    init(
        algorithm: PublicKeyAlgorithm,
        keySizeInBits: Int? = nil,
        curveName: String? = nil
    ) {
        self.algorithm = algorithm
        self.keySizeInBits = keySizeInBits
        self.curveName = curveName
    }

    /// Whether the key characteristics are within commonly accepted ranges
    /// for code signing. This is a domain heuristic, not a platform policy
    /// decision.
    ///
    /// - RSA: 2048 bits or larger is considered appropriate.
    /// - EC: P-256 or larger is considered appropriate.
    /// - Unknown algorithms: not considered appropriate by this heuristic.
    var appearsAdequateForCodeSigning: Bool {
        switch algorithm {
        case .rsa:
            guard let size = keySizeInBits else { return false }
            return size >= 2048
        case .ec:
            // Curve names vary by platform. Treat known P-256 and larger as
            // adequate; if size is known, require at least 256 bits.
            if let curve = curveName?.lowercased() {
                if curve.contains("p-256") || curve.contains("prime256v1") || curve.contains("secp256r1") {
                    return true
                }
                if curve.contains("p-384") || curve.contains("secp384r1") || curve.contains("p-521") || curve.contains("secp521r1") {
                    return true
                }
                // Unknown curve but size may still indicate adequacy.
            }
            if let size = keySizeInBits {
                return size >= 256
            }
            return false
        case .unknown:
            return false
        }
    }
}
