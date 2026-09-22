import Foundation

/// The certificate parser selected by the composition root.
///
/// Metadata is read by `CertificateDERParser`, not by `SecCertificateCopyValues`.
/// Apple documents `SecCertificateCopyValues` for macOS 10.7+. It is not in
/// the iOS API surface, so it is not available on the iOS 17 deployment
/// target (**Verified** — Apple Security documentation). Calling it would not
/// compile for this target.
///
/// Other Security APIs exist on iOS and are intentionally not the metadata
/// source:
///
/// - `SecCertificateCreateWithData` (**Verified**, iOS 2.0+) returns nil when
///   Apple does not accept the bytes as DER-encoded X.509. That nil result
///   does not distinguish empty, truncated, malformed, and unsupported input.
///   Whether it accepts unrecognised algorithms, GeneralizedTime, or unusual
///   names was not measured (**Requires experiment**). Using nil as a
///   rejection gate would collapse those cases and could discard certificates
///   inspection is required to parse. Inspection therefore classifies input
///   itself and does not retain a `SecCertificate`.
/// - `SecCertificateCopyData` (**Verified**, iOS 2.0+) returns a DER
///   representation. Apple does not state that those bytes are identical to
///   the input (**Unknown**). The fingerprint is the SHA-256 of the accepted
///   input, not of a platform re-encoding.
/// - `SecCertificateCopyKey` (**Verified**, iOS 12.0+) returns nil for an
///   unsupported key encoding. Agreement between `SecKeyCopyAttributes` and
///   the certificate's own key fields, including leading-zero serial bytes,
///   was not measured (**Requires experiment**). Key characteristics are read
///   from the certificate encoding.
///
/// No third-party ASN.1 or X.509 library is used. The reader is bounded by
/// `CertificateInput.maximumByteCount` and a nesting cap. Those limits are
/// ZynSign policy; no published size limit for `SecCertificateCreateWithData`
/// was found (**Unknown**).
///
/// Input is untrusted. Malformed input throws a typed `ZynSignError`. Nothing
/// in the certificate is executed, logged, or persisted by this type.
final class AppleCertificateParser: CertificateParser {

    /// Creates the parser.
    init() {}

    func parseCertificate(_ input: CertificateInput) throws -> CertificateMetadata {
        try CertificateDERParser.parse(input)
    }
}
