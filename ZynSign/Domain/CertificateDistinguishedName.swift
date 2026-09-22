/// A distinguished name as it appears in a certificate's subject or issuer.
///
/// The distinguished name is the human-meaningful identity the certificate
/// asserts: who issued it, who it was issued to. It is untrusted metadata
/// carried inside the certificate, not evidence of trust.
///
/// A distinguished name may contain many attributes. ZynSign extracts a small
/// subset that is useful for display and diagnostics — common name,
/// organization, organizational unit, country — and preserves the complete
/// string representation the platform provided so that unusual structures are
/// not lost or misinterpreted.
///
/// The value is pure: it contains only strings and no platform objects. It is
/// not evidence that the certificate is valid, trusted, or suitable for any
/// operation.
struct CertificateDistinguishedName: Equatable, Hashable {

    /// The common name (CN) attribute, when present.
    let commonName: String?

    /// The organization (O) attribute, when present.
    let organization: String?

    /// The organizational unit (OU) attribute, when present.
    let organizationalUnit: String?

    /// The country (C) attribute, when present.
    let country: String?

    /// The raw, platform-provided string representation of the complete
    /// distinguished name. Always present, even when individual attributes
    /// could not be extracted. Used for display and for preserving unusual
    /// structures that do not fit the common attributes.
    let rawRepresentation: String

    /// Creates a distinguished name from its parts.
    ///
    /// `rawRepresentation` is the authoritative preservation of the name as
    /// observed. The individual attributes are extracted conveniences and may
    /// be `nil` when the certificate does not carry them or when the
    /// structure is unusual.
    init(
        commonName: String? = nil,
        organization: String? = nil,
        organizationalUnit: String? = nil,
        country: String? = nil,
        rawRepresentation: String
    ) {
        self.commonName = commonName
        self.organization = organization
        self.organizationalUnit = organizationalUnit
        self.country = country
        self.rawRepresentation = rawRepresentation
    }

    /// The most user-meaningful single value for display: common name when
    /// present, otherwise organization, otherwise the raw representation.
    var displayName: String {
        if let commonName, !commonName.trimmingCharacters(in: .whitespaces).isEmpty {
            return commonName
        }
        if let organization, !organization.trimmingCharacters(in: .whitespaces).isEmpty {
            return organization
        }
        return rawRepresentation
    }
}
