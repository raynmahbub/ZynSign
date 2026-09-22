import Foundation
import Security
import CryptoKit

/// A certificate parser that uses Apple Security framework APIs.
///
/// `AppleCertificateParser` implements `CertificateParser` using
/// `SecCertificate` and related APIs that are documented as available on
/// iOS/iPadOS for the project's deployment target (iOS 17.0).
///
/// Platform facts, **Verified** from Apple documentation:
/// - `SecCertificateCreateWithData` creates a certificate from DER data on
///   iOS.
/// - `SecCertificateCopyData` returns the DER encoding.
/// - `SecCertificateCopyValues` returns standard X.509 fields for OIDs such
///   as subject, issuer, serial, validity, and key information.
///
/// Platform facts, **Inferred** from documentation and feasibility research:
/// - Uncommon extensions may not be available through
///   `SecCertificateCopyValues` and would require custom ASN.1 parsing. For
///   this milestone only the fields the domain model requires are extracted,
///   and missing optional fields are tolerated.
///
/// Security boundary:
/// - Input is treated as untrusted. Malformed DER returns a typed error,
///   never crashes.
/// - No private-key material is handled here.
/// - Raw DER bytes are not logged.
///
/// Evidence labels used in comments:
/// - Verified: established through Apple documentation.
/// - Inferred: technically reasoned but not experimentally verified in this
///   task.
/// - Requires experiment: needs physical-device validation.
final class AppleCertificateParser: CertificateParser {

    /// Creates the parser.
    init() {}

    func parseCertificate(derData: Data) throws -> CertificateMetadata {
        guard !derData.isEmpty else {
            throw ZynSignError.invalidCertificateData(
                diagnosticDetail: "Certificate data is empty."
            )
        }

        // SecCertificateCreateWithData returns nil for malformed DER.
        // Verified: API exists on iOS.
        guard let secCertificate = SecCertificateCreateWithData(nil, derData as CFData) else {
            throw ZynSignError.invalidCertificateData(
                diagnosticDetail: "Data is not a valid DER-encoded certificate."
            )
        }

        // Compute SHA-256 fingerprint over DER bytes.
        // Verified: CryptoKit SHA256 available on iOS 17.
        let fingerprint = Self.sha256Fingerprint(of: derData)

        // Extract values via SecCertificateCopyValues.
        // The set of OIDs requested covers what the domain model needs.
        // Some values may be absent for unusual certificates; those cases
        // are handled as optional.
        let oids: [CFString] = [
            kSecOIDX509V1SubjectName,
            kSecOIDX509V1IssuerName,
            kSecOIDX509V1SerialNumber,
            kSecOIDX509V1ValidityNotBefore,
            kSecOIDX509V1ValidityNotAfter,
            kSecOIDX509V1SignatureAlgorithm,
            kSecOIDX509V1PublicKeyAlgorithm,
        ]

        var error: Unmanaged<CFError>?
        guard let values = SecCertificateCopyValues(secCertificate, oids as CFArray, &error) as? [CFString: Any] else {
            let underlying = error?.takeRetainedValue()
            throw ZynSignError.invalidCertificateData(
                diagnosticDetail: "Certificate values could not be extracted.",
                underlyingError: underlying
            )
        }

        let subject = Self.extractDistinguishedName(from: values, oid: kSecOIDX509V1SubjectName, fallback: "Unknown Subject")
        let issuer = Self.extractDistinguishedName(from: values, oid: kSecOIDX509V1IssuerName, fallback: "Unknown Issuer")
        let serialNumber = Self.extractSerialNumber(from: values)
        let notBefore = try Self.extractDate(from: values, oid: kSecOIDX509V1ValidityNotBefore, fieldName: "notBefore")
        let notAfter = try Self.extractDate(from: values, oid: kSecOIDX509V1ValidityNotAfter, fieldName: "notAfter")
        let signatureAlgorithm = Self.extractSignatureAlgorithm(from: values)
        let publicKeyInfo = Self.extractPublicKeyInfo(from: secCertificate, values: values)

        return CertificateMetadata(
            subject: subject,
            issuer: issuer,
            serialNumber: serialNumber,
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            publicKeyInfo: publicKeyInfo,
            signatureAlgorithm: signatureAlgorithm,
            sha256Fingerprint: fingerprint
        )
    }

    // MARK: - Fingerprint

    private static func sha256Fingerprint(of data: Data) -> CertificateFingerprint {
        let digest = SHA256.hash(data: data)
        // Force-unwrap is safe: SHA256 always produces 32 bytes, which is
        // valid for CertificateFingerprint.
        return CertificateFingerprint(digestData: Data(digest))!
    }

    // MARK: - Distinguished Name

    private static func extractDistinguishedName(
        from values: [CFString: Any],
        oid: CFString,
        fallback: String
    ) -> CertificateDistinguishedName {
        guard let entry = values[oid] as? [CFString: Any],
              let valueArray = entry[kSecPropertyKeyValue] as? [[CFString: Any]] else {
            return CertificateDistinguishedName(rawRepresentation: fallback)
        }

        var commonName: String?
        var organization: String?
        var orgUnit: String?
        var country: String?
        var components: [String] = []

        for attribute in valueArray {
            guard let label = attribute[kSecPropertyKeyLabel] as? String,
                  let value = attribute[kSecPropertyKeyValue] as? String else {
                continue
            }
            components.append("\(label)=\(value)")
            switch label {
            case "CN", "Common Name":
                if commonName == nil { commonName = value }
            case "O", "Organization":
                if organization == nil { organization = value }
            case "OU", "Organizational Unit":
                if orgUnit == nil { orgUnit = value }
            case "C", "Country":
                if country == nil { country = value }
            default:
                break
            }
        }

        let raw = components.isEmpty ? fallback : components.joined(separator: ", ")
        return CertificateDistinguishedName(
            commonName: commonName,
            organization: organization,
            organizationalUnit: orgUnit,
            country: country,
            rawRepresentation: raw
        )
    }

    // MARK: - Serial Number

    private static func extractSerialNumber(from values: [CFString: Any]) -> String {
        guard let entry = values[kSecOIDX509V1SerialNumber] as? [CFString: Any],
              let data = entry[kSecPropertyKeyValue] as? Data else {
            // Missing serial is unusual but not fatal for parsing; return
            // empty string so that the certificate is still representable.
            // Callers that require a serial can treat empty as missing.
            return ""
        }
        // Serial is DER-encoded integer bytes. Represent as lowercased hex
        // without leading 0x.
        return data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Dates

    private static func extractDate(
        from values: [CFString: Any],
        oid: CFString,
        fieldName: String
    ) throws -> Date {
        guard let entry = values[oid] as? [CFString: Any],
              let date = entry[kSecPropertyKeyValue] as? Date else {
            throw ZynSignError.malformedCertificate(
                diagnosticDetail: "Certificate missing \(fieldName) field."
            )
        }
        return date
    }

    // MARK: - Signature Algorithm

    private static func extractSignatureAlgorithm(from values: [CFString: Any]) -> SignatureAlgorithm {
        guard let entry = values[kSecOIDX509V1SignatureAlgorithm] as? [CFString: Any] else {
            return .unknown("Unknown")
        }
        // The value may be a dictionary containing algorithm name or OID.
        // Try multiple extraction paths.
        if let dict = entry[kSecPropertyKeyValue] as? [CFString: Any],
           let algName = dict[kSecPropertyKeyValue] as? String {
            return SignatureAlgorithm.from(identifier: algName)
        }
        if let algName = entry[kSecPropertyKeyValue] as? String {
            return SignatureAlgorithm.from(identifier: algName)
        }
        // Fallback: use label if available.
        if let label = entry[kSecPropertyKeyLabel] as? String {
            return SignatureAlgorithm.from(identifier: label)
        }
        return .unknown("Unknown")
    }

    // MARK: - Public Key Info

    private static func extractPublicKeyInfo(
        from secCertificate: SecCertificate,
        values: [CFString: Any]
    ) -> PublicKeyInfo {
        // Try to get SecKey from certificate.
        // Verified: SecCertificateCopyKey exists on iOS.
        var algorithm: PublicKeyAlgorithm = .unknown("Unknown")
        var keySize: Int?
        var curveName: String?

        if let key = SecCertificateCopyKey(secCertificate) {
            // Determine algorithm from key attributes.
            if let attrs = SecKeyCopyAttributes(key) as? [CFString: Any] {
                if let keyType = attrs[kSecAttrKeyType] as? String {
                    switch keyType {
                    case kSecAttrKeyTypeRSA as String:
                        algorithm = .rsa
                    case kSecAttrKeyTypeECSECPrimeRandom as String, kSecAttrKeyTypeEC as String:
                        algorithm = .ec
                    default:
                        algorithm = .unknown(keyType)
                    }
                }
                if let size = attrs[kSecAttrKeySizeInBits] as? Int {
                    keySize = size
                }
            }

            // For EC, try to get curve or key size via additional heuristics.
            // Requires experiment for exact attribute availability on iOS 17.
            // Inferred: key size attribute is present for RSA and EC.
        } else {
            // Fallback: try to extract from SecCertificateCopyValues public
            // key algorithm entry, if present.
            if let entry = values[kSecOIDX509V1PublicKeyAlgorithm] as? [CFString: Any],
               let valueDict = entry[kSecPropertyKeyValue] as? [CFString: Any],
               let algName = valueDict[kSecPropertyKeyValue] as? String {
                let lower = algName.lowercased()
                if lower.contains("rsa") {
                    algorithm = .rsa
                } else if lower.contains("ec") {
                    algorithm = .ec
                } else {
                    algorithm = .unknown(algName)
                }
            }
        }

        // If still unknown, check if values contain key size hints.
        if keySize == nil {
            // Some platforms include key size in the public-key info dict.
            // Attempt to extract, but tolerate absence.
            if let entry = values[kSecOIDX509V1PublicKeyAlgorithm] as? [CFString: Any],
               let dict = entry[kSecPropertyKeyValue] as? [CFString: Any] {
                if let size = dict["Key Size"] as? Int {
                    keySize = size
                }
            }
        }

        return PublicKeyInfo(
            algorithm: algorithm,
            keySizeInBits: keySize,
            curveName: curveName
        )
    }
}
