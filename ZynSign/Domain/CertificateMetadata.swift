import Foundation

/// Public, inspectable metadata of an X.509 certificate.
///
/// `CertificateMetadata` is a platform-independent domain value that records
/// what a certificate declares about itself: who it is for, who issued it,
/// when it is valid, what key it carries, how it was signed, and how it can
/// be identified by fingerprint.
///
/// It is **not** the certificate itself. It carries no raw DER bytes, no
/// platform `SecCertificate` object, no private-key material, and no trust
/// evaluation. It is safe to display, to persist in non-sensitive storage,
/// and to include in diagnostics (subject to redaction of personal data
/// where required by product policy). Raw DER bytes, when needed for later
/// operations such as CMS construction, are represented by a separate type
/// with an explicit ownership boundary (see `Certificate` and
/// `CertificateData` documentation).
///
/// A successfully parsed `CertificateMetadata` means only that the bytes were
/// structurally parseable and the fields could be extracted. It does **not**
/// mean:
/// - the certificate is currently valid,
/// - the certificate is trusted,
/// - the certificate is suitable for code signing,
/// - the application presenting it is trusted.
///
/// Those evaluations are separate operations with separate result types.
struct CertificateMetadata: Equatable, Hashable {

    /// The subject distinguished name: who the certificate was issued to.
    let subject: CertificateDistinguishedName

    /// The issuer distinguished name: who issued the certificate.
    let issuer: CertificateDistinguishedName

    /// The serial number as a hexadecimal string, lowercased, without
    /// leading `0x`. Preserved as observed; may be empty when the
    /// certificate does not carry a serial number or it could not be
    /// extracted, but a valid certificate normally carries one.
    let serialNumber: String

    /// The start of the validity period (notBefore).
    let notValidBefore: Date

    /// The end of the validity period (notAfter).
    let notValidAfter: Date

    /// Information about the public key the certificate carries.
    let publicKeyInfo: PublicKeyInfo

    /// The signature algorithm the issuer used.
    let signatureAlgorithm: SignatureAlgorithm

    /// The SHA-256 fingerprint of the DER encoding.
    let sha256Fingerprint: CertificateFingerprint

    /// Whether the certificate appears self-signed by comparing subject and
    /// issuer raw representations. This is a heuristic for display; it does
    /// not verify the signature.
    var isSelfSigned: Bool {
        subject.rawRepresentation == issuer.rawRepresentation
    }

    /// Creates certificate metadata from its parts.
    init(
        subject: CertificateDistinguishedName,
        issuer: CertificateDistinguishedName,
        serialNumber: String,
        notValidBefore: Date,
        notValidAfter: Date,
        publicKeyInfo: PublicKeyInfo,
        signatureAlgorithm: SignatureAlgorithm,
        sha256Fingerprint: CertificateFingerprint
    ) {
        self.subject = subject
        self.issuer = issuer
        self.serialNumber = serialNumber
        self.notValidBefore = notValidBefore
        self.notValidAfter = notValidAfter
        self.publicKeyInfo = publicKeyInfo
        self.signatureAlgorithm = signatureAlgorithm
        self.sha256Fingerprint = sha256Fingerprint
    }

    /// The common name of the subject, when available, for display.
    var subjectCommonName: String? { subject.commonName }

    /// The common name of the issuer, when available, for display.
    var issuerCommonName: String? { issuer.commonName }
}
