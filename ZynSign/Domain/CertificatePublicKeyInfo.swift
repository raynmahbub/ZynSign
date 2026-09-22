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

    /// The curve name for elliptic-curve keys, e.g. "P-256", when a
    /// recognised curve identifier was present. `nil` for RSA, for an
    /// unrecognised curve, or when no curve identifier was available.
    /// Display only; `curveIdentifier` is the stable form.
    let curveName: String?

    /// The elliptic-curve identifier from the certificate, as a dotted OID,
    /// when the key algorithm parameters carried one. `nil` when the
    /// certificate did not include a curve identifier. This is not inferred
    /// from the key size.
    let curveIdentifier: String?

    /// Creates public-key information.
    init(
        algorithm: PublicKeyAlgorithm,
        keySizeInBits: Int? = nil,
        curveName: String? = nil,
        curveIdentifier: String? = nil
    ) {
        self.algorithm = algorithm
        self.keySizeInBits = keySizeInBits
        self.curveName = curveName
        self.curveIdentifier = curveIdentifier
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
            // Curve names and OIDs vary. Treat known P-256 and larger as
            // adequate; if size is known, require at least 256 bits. This is
            // a domain heuristic, not an Apple policy decision.
            if Self.namesAdequateCurve(curveName) || Self.identifiesAdequateCurve(curveIdentifier) {
                return true
            }
            if let size = keySizeInBits {
                return size >= 256
            }
            return false
        case .unknown:
            return false
        }
    }

    private static func namesAdequateCurve(_ name: String?) -> Bool {
        guard let curve = name?.lowercased() else { return false }
        if curve.contains("p-256") || curve.contains("prime256v1") || curve.contains("secp256r1") {
            return true
        }
        if curve.contains("p-384") || curve.contains("secp384r1") || curve.contains("p-521") || curve.contains("secp521r1") {
            return true
        }
        return false
    }

    private static func identifiesAdequateCurve(_ identifier: String?) -> Bool {
        switch identifier {
        case "1.2.840.10045.3.1.7", "1.3.132.0.34", "1.3.132.0.35":
            return true
        default:
            return false
        }
    }
}
