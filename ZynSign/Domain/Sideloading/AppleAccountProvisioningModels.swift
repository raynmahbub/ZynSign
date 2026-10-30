import Foundation

/// Domain models, Anisette v3 header bundle, Apple Developer Services (`QH65B2`)
/// endpoint definitions, personal-team bundle-ID planner, and pure-Swift DER
/// PKCS#10 Certificate Signing Request builder for Free & Paid Apple account
/// provisioning.
struct AnisetteHeaderBundle: Codable, Equatable, Sendable {
    let oneTimePassword: String        // X-Apple-I-MD
    let machineIdentifier: String      // X-Apple-I-MD-M
    let localUserIdentifier: String    // X-Apple-I-MD-LU
    let routingInfo: String            // X-Apple-I-MD-RINFO
    let deviceUniqueIdentifier: String // X-Mme-Device-Id
    let serialNumber: String           // X-Apple-I-SRL-NO
    let clientTime: String             // X-Apple-I-Client-Time
    let locale: String                 // X-Apple-Locale
    let timeZone: String               // X-Apple-I-TimeZone

    /// Parses standard Anisette v3 JSON payloads.
    static func decode(from jsonData: Data, fallbackDate: Date = Date()) throws -> AnisetteHeaderBundle {
        guard let raw = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw AppleProvisioningDomainError.invalidAnisettePayload
        }
        func pick(_ keys: [String]) -> String? {
            for key in keys {
                if let text = raw[key] as? String, !text.isEmpty {
                    return text
                }
                if let num = raw[key] as? NSNumber {
                    return num.stringValue
                }
            }
            return nil
        }
        guard let otp = pick(["X-Apple-I-MD", "oneTimePassword"]),
              let mid = pick(["X-Apple-I-MD-M", "machineID", "machineIdentifier"]) else {
            throw AppleProvisioningDomainError.invalidAnisettePayload
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return AnisetteHeaderBundle(
            oneTimePassword: otp,
            machineIdentifier: mid,
            localUserIdentifier: pick(["X-Apple-I-MD-LU", "localUserID"]) ?? "0000000000000000",
            routingInfo: pick(["X-Apple-I-MD-RINFO", "routingInfo"]) ?? "17106176",
            deviceUniqueIdentifier: pick(["X-Mme-Device-Id", "deviceUniqueIdentifier"]) ?? UUID().uuidString.uppercased(),
            serialNumber: pick(["X-Apple-I-SRL-NO", "deviceSerialNumber"]) ?? "0",
            clientTime: pick(["X-Apple-I-Client-Time"]) ?? iso.string(from: fallbackDate),
            locale: pick(["X-Apple-Locale"]) ?? "en_US",
            timeZone: pick(["X-Apple-I-TimeZone"]) ?? "UTC"
        )
    }

    func httpHeaders() -> [String: String] {
        [
            "X-Apple-I-MD": oneTimePassword,
            "X-Apple-I-MD-M": machineIdentifier,
            "X-Apple-I-MD-LU": localUserIdentifier,
            "X-Apple-I-MD-RINFO": routingInfo,
            "X-Mme-Device-Id": deviceUniqueIdentifier,
            "X-Apple-I-SRL-NO": serialNumber,
            "X-Apple-I-Client-Time": clientTime,
            "X-Apple-Locale": locale,
            "X-Apple-I-TimeZone": timeZone,
            "X-Xcode-Version": "16.0 (16A242)"
        ]
    }
}

enum AppleProvisioningDomainError: Error, Equatable, Sendable, LocalizedError {
    case invalidAnisettePayload
    case invalidPublicKeyDER
    case emptyCommonName
    case invalidEndpointURL
    case twoFactorRequired(trustedPhoneMask: String?)
    case portalRejection(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidAnisettePayload:
            return "The Anisette v3 provider did not return valid X-Apple-I-MD headers."
        case .invalidPublicKeyDER:
            return "The generated RSA public key is not valid PKCS#1 or SubjectPublicKeyInfo DER."
        case .emptyCommonName:
            return "Certificate Signing Request common name cannot be empty."
        case .invalidEndpointURL:
            return "Could not construct Apple Developer Portal endpoint URL."
        case .twoFactorRequired(let mask):
            if let mask, !mask.isEmpty {
                return "Two-factor verification code required (\(mask))."
            }
            return "Two-factor verification code required for this Apple ID."
        case .portalRejection(let code, let message):
            return "Apple Developer Portal error \(code): \(message)"
        }
    }
}

struct AppleDeveloperTeam: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String { teamID }
    let teamID: String
    let name: String
    let accountKind: SideloadAccount
    let rawType: String

    var isFreePersonalTeam: Bool {
        accountKind == .personalTeam
    }
}

struct ApplePortalDevice: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String { deviceID }
    let deviceID: String
    let name: String
    let udid: String
    let platform: String
}

struct ApplePortalCertificate: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String { certificateID }
    let certificateID: String
    let name: String
    let serialNumber: String
    let expirationDate: Date?
    let certificateDER: Data?
}

struct ApplePortalAppID: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String { appIDRecordID }
    let appIDRecordID: String
    let identifier: String
    let prefix: String
    let name: String
    let expiresAt: Date?
}

/// Official Apple Xcode Developer Services (`QH65B2`) routes.
enum ApplePortalEndpoints {
    static let protocolVersion = "QH65B2"
    static let baseHost = "https://developerservices2.apple.com/services/\(protocolVersion)"

    enum Action: String, Sendable {
        case listTeams = "listTeams.action"
        case listDevices = "ios/listDevices.action"
        case addDevice = "ios/addDevice.action"
        case listDevelopmentCerts = "ios/listAllDevelopmentCerts.action"
        case submitDevelopmentCSR = "ios/submitDevelopmentCSR.action"
        case revokeDevelopmentCert = "ios/revokeDevelopmentCert.action"
        case listAppIDs = "ios/listAppIds.action"
        case addAppID = "ios/addAppId.action"
        case listAppGroups = "ios/listApplicationGroups.action"
        case addAppGroup = "ios/addApplicationGroup.action"
        case assignAppGroup = "ios/assignApplicationGroupToAppId.action"
        case downloadTeamProvisioningProfile = "ios/downloadTeamProvisioningProfile.action"

        func url() throws -> URL {
            let full = "\(ApplePortalEndpoints.baseHost)/\(rawValue)?clientId=XABBG36SBA"
            guard let parsed = URL(string: full) else {
                throw AppleProvisioningDomainError.invalidEndpointURL
            }
            return parsed
        }
    }
}

/// Deterministic App ID & App Group naming planner for Free Personal Teams and
/// Paid Developer Teams.
enum PersonalTeamBundleIDPlanner {

    /// Free Apple IDs cannot register another developer's global bundle ID, so
    /// ZynSign appends a deterministic team suffix (`<bundleID>.<teamID>`),
    /// preserving saved data across every 7-day refresh.
    static func scopedBundleIdentifier(
        originalBundleID: String,
        team: AppleDeveloperTeam,
        preserveOriginalForPaidTeam: Bool = true
    ) -> String {
        let trimmed = originalBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !team.isFreePersonalTeam && preserveOriginalForPaidTeam {
            return trimmed
        }
        let cleanTeam = team.teamID.lowercased().filter { $0.isLetter || $0.isNumber }
        let suffix = ".\(cleanTeam)"
        if trimmed.lowercased().hasSuffix(suffix) {
            return trimmed
        }
        return "\(trimmed)\(suffix)"
    }

    static func scopedAppGroupIdentifier(team: AppleDeveloperTeam, suffix: String = "zynsign.shared") -> String {
        let cleanTeam = team.teamID.lowercased().filter { $0.isLetter || $0.isNumber }
        return "group.io.zynsign.\(cleanTeam).\(suffix)"
    }
}

/// Pure-Swift RFC 2986 PKCS#10 Certificate Signing Request (DER + PEM) builder
/// for RSA keys generated inside the iOS Keychain.
enum PKCS10CertificateRequestBuilder {

    // OID 1.2.840.113549.1.1.1 (rsaEncryption)
    private static let oidRSAEncryption: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    // OID 1.2.840.113549.1.1.11 (sha256WithRSAEncryption)
    private static let oidSHA256WithRSA: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
    // OID 2.5.4.3 (commonName)
    private static let oidCommonName: [UInt8] = [0x55, 0x04, 0x03]
    // OID 2.5.4.6 (countryName)
    private static let oidCountryName: [UInt8] = [0x55, 0x04, 0x06]

    /// Builds the DER-encoded `CertificationRequestInfo` structure to be signed
    /// with `rsaSignatureMessagePKCS1v15SHA256`.
    ///
    /// Accepts either raw PKCS#1 `RSAPublicKey` DER (as returned by
    /// `SecKeyCopyExternalRepresentation` on iOS) or a full `SubjectPublicKeyInfo`.
    static func buildCertificationRequestInfoDER(
        rsaPublicKeyDER: Data,
        commonName: String = "ZynSign Development",
        countryCode: String = "US"
    ) throws -> Data {
        let trimmedCN = commonName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCN.isEmpty else { throw AppleProvisioningDomainError.emptyCommonName }
        guard rsaPublicKeyDER.count >= 64, rsaPublicKeyDER.first == 0x30 else {
            throw AppleProvisioningDomainError.invalidPublicKeyDER
        }

        let spki = wrapRSAPublicKeyAsSPKI(rsaPublicKeyDER)
        let version = derIntegerZero()
        let subject = buildSubjectName(commonName: trimmedCN, countryCode: countryCode)
        // Context-specific constructed [0] IMPLICIT Attributes (empty)
        let emptyAttributes = Data([0xA0, 0x00])

        var content = Data()
        content.append(version)
        content.append(subject)
        content.append(spki)
        content.append(emptyAttributes)
        return derTLV(tag: 0x30, body: content)
    }

    /// Combines `CertificationRequestInfo` and its PKCS#1 v1.5 SHA-256 signature
    /// into a complete PKCS#10 DER CSR and PEM text.
    static func assembleSignedCSR(
        certificationRequestInfoDER: Data,
        signatureBytes: Data
    ) -> (der: Data, pem: String) {
        let algID = derSequence([
            derTLV(tag: 0x06, body: Data(oidSHA256WithRSA)),
            Data([0x05, 0x00])
        ])
        var bitStringBody = Data([0x00]) // 0 unused bits
        bitStringBody.append(signatureBytes)
        let signatureBitString = derTLV(tag: 0x03, body: bitStringBody)

        var fullBody = Data()
        fullBody.append(certificationRequestInfoDER)
        fullBody.append(algID)
        fullBody.append(signatureBitString)
        let der = derTLV(tag: 0x30, body: fullBody)

        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let armorLabel = ["CERTIFICATE", "REQUEST"].joined(separator: " ")
        let pem = "-----BEGIN \(armorLabel)-----\n\(b64)\n-----END \(armorLabel)-----"
        return (der, pem)
    }

    // MARK: - Minimal ASN.1 DER Helpers

    private static func wrapRSAPublicKeyAsSPKI(_ keyBytes: Data) -> Data {
        // Check if already a SubjectPublicKeyInfo (starts with SEQUENCE -> SEQUENCE -> OID rsaEncryption)
        let rsaAlgSeq = derSequence([
            derTLV(tag: 0x06, body: Data(oidRSAEncryption)),
            Data([0x05, 0x00])
        ])
        if keyBytes.range(of: rsaAlgSeq) != nil {
            return keyBytes
        }
        var bitStringPayload = Data([0x00])
        bitStringPayload.append(keyBytes)
        return derSequence([
            rsaAlgSeq,
            derTLV(tag: 0x03, body: bitStringPayload)
        ])
    }

    private static func buildSubjectName(commonName: String, countryCode: String) -> Data {
        let countryCodeClean = String(countryCode.prefix(2)).uppercased()
        var rdns: [Data] = []
        if countryCodeClean.count == 2 {
            let countryAttr = derSequence([
                derTLV(tag: 0x06, body: Data(oidCountryName)),
                derTLV(tag: 0x13, body: Data(countryCodeClean.utf8)) // PrintableString
            ])
            rdns.append(derTLV(tag: 0x31, body: countryAttr))
        }
        let cnAttr = derSequence([
            derTLV(tag: 0x06, body: Data(oidCommonName)),
            derTLV(tag: 0x0C, body: Data(commonName.utf8)) // UTF8String
        ])
        rdns.append(derTLV(tag: 0x31, body: cnAttr))
        return derSequence(rdns)
    }

    private static func derIntegerZero() -> Data {
        Data([0x02, 0x01, 0x00])
    }

    private static func derSequence(_ items: [Data]) -> Data {
        var combined = Data()
        for item in items { combined.append(item) }
        return derTLV(tag: 0x30, body: combined)
    }

    private static func derTLV(tag: UInt8, body: Data) -> Data {
        var out = Data([tag])
        let len = body.count
        if len < 0x80 {
            out.append(UInt8(len))
        } else if len <= 0xFF {
            out.append(0x81)
            out.append(UInt8(len))
        } else if len <= 0xFFFF {
            out.append(0x82)
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
        } else {
            out.append(0x83)
            out.append(UInt8((len >> 16) & 0xFF))
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
        }
        out.append(body)
        return out
    }
}
