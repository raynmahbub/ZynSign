/// A content fingerprint of one stored artifact: a digest over its bytes.
///
/// A fingerprint identifies bytes and nothing else. Two artifacts with the
/// same fingerprint hold the same content; that is the whole of its meaning.
/// It is not a signature, it is not evidence that a package is genuine,
/// trusted, validly signed, or installable, and it must never be presented
/// as any of those. ZynSign uses it for one purpose — recognising when the
/// same package is imported again — and the duplicate policy is the only
/// consumer of that equality.
///
/// The value is pure: the digest is computed by the platform layer, which
/// owns file access and the hashing primitive, and is handed to the domain as
/// data. The algorithm is recorded alongside the digest so that a stored
/// fingerprint stays interpretable if the algorithm is ever changed.
struct ArtifactFingerprint: Equatable, Hashable, CustomStringConvertible {

    /// The digest algorithms ZynSign records.
    enum Algorithm: String, CaseIterable, Hashable {

        /// SHA-256, producing a 32-byte digest.
        case sha256

        /// The digest length the algorithm produces, in bytes.
        var digestByteCount: Int {
            switch self {
            case .sha256: return 32
            }
        }
    }

    /// The algorithm that produced the digest.
    let algorithm: Algorithm

    /// The digest as lowercase hexadecimal text, exactly twice the
    /// algorithm's digest length in characters.
    let hexDigest: String

    /// Creates a fingerprint from hexadecimal digest text, or returns `nil`
    /// when the text is not a complete hexadecimal digest for the algorithm.
    /// Uppercase digits are accepted and normalised to lowercase.
    init?(algorithm: Algorithm, hexDigest: String) {
        let normalized = hexDigest.lowercased()
        guard Self.isValidHexDigest(normalized, for: algorithm) else { return nil }
        self.algorithm = algorithm
        self.hexDigest = normalized
    }

    /// Creates a fingerprint from raw digest bytes, or returns `nil` when the
    /// byte count does not match the algorithm.
    init?(algorithm: Algorithm, digestBytes: [UInt8]) {
        guard digestBytes.count == algorithm.digestByteCount else { return nil }
        let hexDigits = Array("0123456789abcdef")
        var text = ""
        text.reserveCapacity(digestBytes.count * 2)
        for byte in digestBytes {
            text.append(hexDigits[Int(byte >> 4)])
            text.append(hexDigits[Int(byte & 0x0F)])
        }
        self.algorithm = algorithm
        self.hexDigest = text
    }

    /// ZynSign's acceptance rule for digest text: the exact length the
    /// algorithm requires, composed only of ASCII hexadecimal digits.
    static func isValidHexDigest(_ candidate: String, for algorithm: Algorithm) -> Bool {
        guard candidate.count == algorithm.digestByteCount * 2 else { return false }
        return candidate.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// The canonical rendering, `algorithm:digest`, for diagnostics.
    var description: String { "\(algorithm.rawValue):\(hexDigest)" }
}
