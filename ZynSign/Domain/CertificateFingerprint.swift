import Foundation

/// The SHA-256 fingerprint of a certificate's DER encoding.
///
/// A fingerprint identifies certificate bytes and nothing else. Two
/// certificates with the same fingerprint hold the same DER content. It is
/// not a signature, not evidence of trust, and must never be presented as
/// such. ZynSign uses it to recognise a certificate, to display a stable
/// identifier, and to match a certificate against references that store only
/// a digest.
///
/// The value is pure: the digest is computed by the platform layer, which
/// owns the hashing primitive, and handed to the domain as data. The
/// algorithm is fixed to SHA-256 for this type because that is what the
/// domain requires for certificate identification.
struct CertificateFingerprint: Equatable, Hashable, CustomStringConvertible {

    /// The algorithm that produced the digest. Fixed to SHA-256 for this
    /// type; recorded explicitly so that the representation stays
    /// interpretable if the domain ever supports additional algorithms.
    enum Algorithm: String, CaseIterable, Hashable {
        case sha256
    }

    /// The algorithm that produced the digest.
    let algorithm: Algorithm

    /// The digest as lowercase hexadecimal text, exactly 64 characters for
    /// SHA-256.
    let hexDigest: String

    /// The digest length SHA-256 produces, in bytes.
    static let digestByteCount = 32

    /// The digest length in hexadecimal characters.
    static let hexDigestLength = digestByteCount * 2

    /// Creates a fingerprint from hexadecimal digest text, or returns `nil`
    /// when the text is not a complete hexadecimal digest for SHA-256.
    /// Uppercase digits are accepted and normalised to lowercase.
    init?(algorithm: Algorithm = .sha256, hexDigest: String) {
        let normalized = hexDigest.lowercased()
        guard Self.isValidHexDigest(normalized) else { return nil }
        self.algorithm = algorithm
        self.hexDigest = normalized
    }

    /// Creates a fingerprint from raw digest bytes, or returns `nil` when the
    /// byte count does not match SHA-256.
    init?(algorithm: Algorithm = .sha256, digestBytes: [UInt8]) {
        guard digestBytes.count == Self.digestByteCount else { return nil }
        let hexDigits = Array("0123456789abcdef")
        var text = ""
        text.reserveCapacity(Self.hexDigestLength)
        for byte in digestBytes {
            text.append(hexDigits[Int(byte >> 4)])
            text.append(hexDigits[Int(byte & 0x0F)])
        }
        self.algorithm = algorithm
        self.hexDigest = text
    }

    /// Creates a fingerprint from raw digest data, or returns `nil` when the
    /// data length does not match SHA-256.
    init?(algorithm: Algorithm = .sha256, digestData: Data) {
        self.init(algorithm: algorithm, digestBytes: Array(digestData))
    }

    /// ZynSign's acceptance rule for SHA-256 digest text: exactly 64 ASCII
    /// hexadecimal characters.
    static func isValidHexDigest(_ candidate: String) -> Bool {
        guard candidate.count == hexDigestLength else { return false }
        return candidate.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// The canonical rendering `sha256:<hex>` for diagnostics.
    var description: String { "\(algorithm.rawValue):\(hexDigest)" }

    /// The digest bytes.
    var digestBytes: [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Self.digestByteCount)
        var index = hexDigest.startIndex
        while index < hexDigest.endIndex {
            let next = hexDigest.index(index, offsetBy: 2)
            let byteString = hexDigest[index..<next]
            if let byte = UInt8(byteString, radix: 16) {
                bytes.append(byte)
            }
            index = next
        }
        return bytes
    }
}
