/// The signature algorithm a certificate declares.
///
/// The signature algorithm is the combination of hash and public-key
/// operation the issuer used to sign the certificate. It is metadata about
/// how the certificate was produced, not about how ZynSign will use it.
///
/// The enumeration covers the algorithms commonly encountered in Apple
/// code-signing contexts. Unrecognised OIDs are preserved as `unknown` with
/// the raw identifier for diagnostics.
enum SignatureAlgorithm: Equatable, Hashable {

    case sha1WithRSAEncryption
    case sha256WithRSAEncryption
    case sha384WithRSAEncryption
    case sha512WithRSAEncryption
    case ecdsaWithSHA1
    case ecdsaWithSHA256
    case ecdsaWithSHA384
    case ecdsaWithSHA512
    case ed25519
    case unknown(String)

    /// A human-readable name suitable for diagnostics.
    var displayName: String {
        switch self {
        case .sha1WithRSAEncryption: return "sha1WithRSAEncryption"
        case .sha256WithRSAEncryption: return "sha256WithRSAEncryption"
        case .sha384WithRSAEncryption: return "sha384WithRSAEncryption"
        case .sha512WithRSAEncryption: return "sha512WithRSAEncryption"
        case .ecdsaWithSHA1: return "ecdsa-with-SHA1"
        case .ecdsaWithSHA256: return "ecdsa-with-SHA256"
        case .ecdsaWithSHA384: return "ecdsa-with-SHA384"
        case .ecdsaWithSHA512: return "ecdsa-with-SHA512"
        case .ed25519: return "ed25519"
        case .unknown(let identifier): return identifier
        }
    }

    /// Whether the algorithm uses SHA-1. SHA-1 is considered weak for
    /// certificate signatures, but its presence does not by itself make a
    /// certificate unparseable; it informs suitability checks.
    var usesSHA1: Bool {
        switch self {
        case .sha1WithRSAEncryption, .ecdsaWithSHA1: return true
        default: return false
        }
    }

    /// Whether the algorithm is one ZynSign recognises. Unknown algorithms
    /// are parseable as `unknown` but not recognised.
    var isRecognised: Bool {
        switch self {
        case .unknown: return false
        default: return true
        }
    }

    /// Attempts to map a platform-provided identifier (OID name, common name,
    /// or raw OID) to a known algorithm. Returns `unknown` when the identifier
    /// does not match a known case.
    static func from(identifier: String) -> SignatureAlgorithm {
        let lower = identifier.lowercased()
        // OID forms and common names vary by platform. Match loosely.
        if lower.contains("1.2.840.113549.1.1.5") || lower == "sha1withrsaencryption" || lower == "sha1withrsa" {
            return .sha1WithRSAEncryption
        }
        if lower.contains("1.2.840.113549.1.1.11") || lower == "sha256withrsaencryption" || lower == "sha256withrsa" {
            return .sha256WithRSAEncryption
        }
        if lower.contains("1.2.840.113549.1.1.12") || lower == "sha384withrsaencryption" {
            return .sha384WithRSAEncryption
        }
        if lower.contains("1.2.840.113549.1.1.13") || lower == "sha512withrsaencryption" {
            return .sha512WithRSAEncryption
        }
        if lower.contains("1.2.840.10045.4.1") || lower == "ecdsa-with-sha1" || lower == "ecdsaWithSHA1" {
            return .ecdsaWithSHA1
        }
        if lower.contains("1.2.840.10045.4.3.2") || lower == "ecdsa-with-sha256" || lower == "ecdsawithsha256" {
            return .ecdsaWithSHA256
        }
        if lower.contains("1.2.840.10045.4.3.3") || lower == "ecdsa-with-sha384" {
            return .ecdsaWithSHA384
        }
        if lower.contains("1.2.840.10045.4.3.4") || lower == "ecdsa-with-sha512" {
            return .ecdsaWithSHA512
        }
        if lower.contains("1.3.101.112") || lower == "ed25519" {
            return .ed25519
        }
        return .unknown(identifier)
    }
}
