/// One attribute of a distinguished name, in certificate order.
///
/// Recognised attributes are labelled so callers can read them without
/// parsing an OID. Unrecognised attributes are kept, with their OID and
/// value, so an unusual name does not force the certificate to be discarded.
struct CertificateNameAttribute: Equatable, Hashable {

    /// Whether ZynSign recognises the attribute type.
    enum Recognition: String, Equatable, Hashable {
        case commonName
        case organization
        case organizationalUnit
        case country
        case locality
        case stateOrProvince
        case emailAddress
        case surname
        case givenName
        case distinguishedNameSerialNumber
        case unrecognized
    }

    /// The attribute value as text, or as hexadecimal when the encoding
    /// could not be decoded. Undecoded values are preserved; they do not
    /// fail the certificate.
    enum Value: Equatable, Hashable {
        case text(String)
        case undecodedHexadecimal(String)
    }

    /// The attribute type OID, dotted.
    let objectIdentifier: String

    /// The recognition of `objectIdentifier`.
    let recognition: Recognition

    /// The attribute value.
    let value: Value

    /// The text value, when the encoding was decoded.
    var text: String? {
        if case .text(let text) = value { return text }
        return nil
    }

    /// A short label for display. Unrecognised attributes use their OID so
    /// the type is not dropped.
    var shortLabel: String {
        switch recognition {
        case .commonName: return "CN"
        case .organization: return "O"
        case .organizationalUnit: return "OU"
        case .country: return "C"
        case .locality: return "L"
        case .stateOrProvince: return "ST"
        case .emailAddress: return "emailAddress"
        case .surname: return "SN"
        case .givenName: return "GN"
        case .distinguishedNameSerialNumber: return "serialNumber"
        case .unrecognized: return objectIdentifier
        }
    }

    /// Maps a dotted OID to a recognition. Unknown OIDs are `.unrecognized`,
    /// not an error.
    static func recognition(for objectIdentifier: String) -> Recognition {
        switch objectIdentifier {
        case "2.5.4.3": return .commonName
        case "2.5.4.10": return .organization
        case "2.5.4.11": return .organizationalUnit
        case "2.5.4.6": return .country
        case "2.5.4.7": return .locality
        case "2.5.4.8": return .stateOrProvince
        case "1.2.840.113549.1.9.1": return .emailAddress
        case "2.5.4.4": return .surname
        case "2.5.4.42": return .givenName
        case "2.5.4.5": return .distinguishedNameSerialNumber
        default: return .unrecognized
        }
    }
}

/// A distinguished name as it appears in a certificate's subject or issuer.
///
/// The distinguished name is the human-meaningful identity the certificate
/// asserts: who issued it, who it was issued to. It is untrusted metadata
/// carried inside the certificate, not evidence of trust.
///
/// A distinguished name may contain many attributes. ZynSign keeps the
/// attributes in certificate order, including attributes it does not
/// recognise, and also exposes the common display fields. The display string
/// is separate from that structured representation and is not the canonical
/// form.
///
/// The value is pure: it contains only strings and no platform objects. It is
/// not evidence that the certificate is valid, trusted, or suitable for any
/// operation.
struct CertificateDistinguishedName: Equatable, Hashable {

    /// The common name (CN) attribute, when present as text. When the name
    /// carries more than one, this is the first.
    let commonName: String?

    /// The organization (O) attribute, when present as text. When the name
    /// carries more than one, this is the first.
    let organization: String?

    /// The organizational unit (OU) attribute, when present as text. When the
    /// name carries more than one, this is the first. Later units remain in
    /// `attributes`.
    let organizationalUnit: String?

    /// The country (C) attribute, when present as text.
    let country: String?

    /// The locality (L) attribute, when present as text.
    let locality: String?

    /// The state or province (ST) attribute, when present as text.
    let stateOrProvince: String?

    /// The email address attribute, when present as text.
    let emailAddress: String?

    /// Every attribute, in certificate order, including unrecognised ones.
    let attributes: [CertificateNameAttribute]

    /// A display rendering of the attributes in certificate order. Not a
    /// canonical encoding and not evidence of how a platform would print the
    /// name. Empty when the name has no attributes.
    let rawRepresentation: String

    /// Creates a distinguished name from its parts.
    ///
    /// `attributes` is the structured representation. `rawRepresentation` is
    /// the display rendering. The individual fields are conveniences and may
    /// be `nil` when the certificate does not carry them.
    init(
        commonName: String? = nil,
        organization: String? = nil,
        organizationalUnit: String? = nil,
        country: String? = nil,
        locality: String? = nil,
        stateOrProvince: String? = nil,
        emailAddress: String? = nil,
        attributes: [CertificateNameAttribute] = [],
        rawRepresentation: String
    ) {
        self.commonName = commonName
        self.organization = organization
        self.organizationalUnit = organizationalUnit
        self.country = country
        self.locality = locality
        self.stateOrProvince = stateOrProvince
        self.emailAddress = emailAddress
        self.attributes = attributes
        self.rawRepresentation = rawRepresentation
    }

    /// Builds a name from attributes in certificate order.
    ///
    /// Convenience fields take the first decoded text value of each
    /// recognised type. Unrecognised and undecoded attributes stay in
    /// `attributes` and in the display rendering.
    static func from(attributes: [CertificateNameAttribute]) -> CertificateDistinguishedName {
        func firstText(_ recognition: CertificateNameAttribute.Recognition) -> String? {
            attributes.first { $0.recognition == recognition }?.text
        }
        let raw = attributes.map { attribute -> String in
            let rendered: String
            switch attribute.value {
            case .text(let text):
                rendered = text
            case .undecodedHexadecimal(let hexadecimal):
                rendered = hexadecimal
            }
            return "\(attribute.shortLabel)=\(rendered)"
        }.joined(separator: ", ")
        return CertificateDistinguishedName(
            commonName: firstText(.commonName),
            organization: firstText(.organization),
            organizationalUnit: firstText(.organizationalUnit),
            country: firstText(.country),
            locality: firstText(.locality),
            stateOrProvince: firstText(.stateOrProvince),
            emailAddress: firstText(.emailAddress),
            attributes: attributes,
            rawRepresentation: raw
        )
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
