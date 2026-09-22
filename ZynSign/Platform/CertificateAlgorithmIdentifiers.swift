import Foundation

/// Object identifiers the certificate reader recognises.
///
/// Recognition is a labelling convenience. An identifier that is not listed
/// here is preserved on the metadata; it does not fail parsing.
enum CertificateAlgorithmIdentifiers {

    static let rsaEncryption = "1.2.840.113549.1.1.1"
    static let ecPublicKey = "1.2.840.10045.2.1"
    static let ed25519 = "1.3.101.112"

    /// A recognised named curve, or `nil` when the identifier is not one
    /// ZynSign names. The size is the curve's field size. P-521 is 521 bits,
    /// not the next multiple of 8.
    static func namedCurve(for objectIdentifier: String) -> (name: String, sizeInBits: Int)? {
        switch objectIdentifier {
        case "1.2.840.10045.3.1.7":
            return ("P-256", 256)
        case "1.3.132.0.34":
            return ("P-384", 384)
        case "1.3.132.0.35":
            return ("P-521", 521)
        default:
            return nil
        }
    }
}
