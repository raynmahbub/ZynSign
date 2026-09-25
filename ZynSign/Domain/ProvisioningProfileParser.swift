import Foundation
import CoreFoundation

/// The parsing seam for a decoded provisioning-profile payload.
///
/// This parser receives only the payload bytes that a container decoder
/// supplied. It does not unwrap CMS, verify signatures, evaluate certificate
/// chains, or decide whether any entitlement is authorized by iOS.
protocol ProvisioningProfileParser {

    /// Parses one decoded property-list payload into typed profile metadata.
    ///
    /// A successful parse means that the payload could be represented by the
    /// model. Required-field and cross-field checks remain in
    /// `ProvisioningProfileValidator`, so parsing success is not structural
    /// validity or trust.
    func parse(_ payload: ProvisioningProfilePayload) throws -> ProvisioningProfile
}

extension ProvisioningProfileParser {

    /// Parses already-decoded property-list bytes. This convenience does not
    /// accept or unwrap a CMS container.
    func parse(plistData: Data) throws -> ProvisioningProfile {
        try parse(ProvisioningProfilePayload(plistData: plistData))
    }
}

/// Parses the property-list view of a provisioning-profile payload.
///
/// Foundation property-list values are converted once at this boundary. Raw
/// dictionaries do not escape into the Domain model, unknown root fields are
/// ignored, and every recognized field is interpreted without force casts or
/// coercion. Entitlement values use `ProvisioningProfileValue` so booleans,
/// numbers, strings, arrays, and dictionaries stay distinguishable.
struct PropertyListProvisioningProfileParser: ProvisioningProfileParser {

    /// Optional connection to the existing certificate metadata parser. When
    /// absent, certificate bytes remain explicit unparsed references; parsing
    /// the profile never implies private-key possession.
    let certificateParser: (any CertificateParser)?

    /// The bounds applied while converting entitlement values.
    let limits: ProvisioningProfileParsingLimits

    init(
        certificateParser: (any CertificateParser)? = nil,
        limits: ProvisioningProfileParsingLimits = .default
    ) {
        self.certificateParser = certificateParser
        self.limits = limits
    }

    /// Parses one decoded payload, refusing empty, oversized, malformed, or
    /// unsupported property-list data.
    func parse(_ payload: ProvisioningProfilePayload) throws -> ProvisioningProfile {
        guard !payload.plistData.isEmpty else {
            throw ZynSignError.emptyProvisioningProfilePayload()
        }
        guard payload.plistData.count <= ProvisioningProfilePayload.maximumByteCount else {
            throw ZynSignError.provisioningProfilePayloadTooLarge(
                diagnosticDetail: "The decoded profile payload exceeded the configured byte bound."
            )
        }

        var format = PropertyListSerialization.PropertyListFormat.openStep
        let root: Any
        do {
            root = try PropertyListSerialization.propertyList(
                from: payload.plistData,
                options: [],
                format: &format
            )
        } catch {
            throw ZynSignError.malformedProvisioningProfilePayload(
                diagnosticDetail: "The decoded profile payload was not a readable property list (cause: \(Self.causeSummary(error)))."
            )
        }

        // The dictionary check comes first: truncated input such as a bare
        // `bplist00` magic parses as an OpenStep string, which is damaged
        // input (malformed), not a well-formed payload in an unsupported
        // format. Only a well-formed OpenStep dictionary reaches the format
        // check below.
        guard let rootDictionary = root as? [String: Any] else {
            throw ZynSignError.malformedProvisioningProfilePayload(
                diagnosticDetail: "The decoded profile payload root was not a dictionary."
            )
        }
        guard format != .openStep else {
            throw ZynSignError.unsupportedProvisioningProfilePayloadFormat(
                diagnosticDetail: "OpenStep property lists are outside the profile payload formats supported by this parser."
            )
        }
        guard rootDictionary.count <= limits.maximumCollectionCount else {
            throw ZynSignError.provisioningProfileResourceLimitExceeded(
                diagnosticDetail: "The profile root exceeded the configured entry bound."
            )
        }

        return try parseRoot(rootDictionary)
    }

    // MARK: - Root extraction

    private func parseRoot(_ root: [String: Any]) throws -> ProvisioningProfile {
        let uuid = try parseUUID(root[ProvisioningProfileKeys.uuid])
        let profileName = try optionalString(root[ProvisioningProfileKeys.name], field: ProvisioningProfileKeys.name)
        let creationDate = try optionalDate(root[ProvisioningProfileKeys.creationDate], field: ProvisioningProfileKeys.creationDate)
        let expirationDate = try optionalDate(root[ProvisioningProfileKeys.expirationDate], field: ProvisioningProfileKeys.expirationDate)

        let prefixes = try optionalNonEmptyStringArray(
            root[ProvisioningProfileKeys.applicationIdentifierPrefix],
            field: ProvisioningProfileKeys.applicationIdentifierPrefix
        )
        let rootApplicationIdentifier = try optionalString(
            root[ProvisioningProfileKeys.applicationIdentifier],
            field: ProvisioningProfileKeys.applicationIdentifier
        )
        let teamIdentifiers = try optionalNonEmptyStringArray(
            root[ProvisioningProfileKeys.teamIdentifier],
            field: ProvisioningProfileKeys.teamIdentifier
        )
        let teamName = try optionalString(
            root[ProvisioningProfileKeys.teamName],
            field: ProvisioningProfileKeys.teamName
        )
        let platforms = try optionalNonEmptyStringArray(
            root[ProvisioningProfileKeys.platform],
            field: ProvisioningProfileKeys.platform
        )?.map { ProvisioningProfilePlatform(rawValue: $0) }
        let provisionsAllDevices = try optionalBoolean(
            root[ProvisioningProfileKeys.provisionsAllDevices],
            field: ProvisioningProfileKeys.provisionsAllDevices
        )
        let version = try optionalInteger(
            root[ProvisioningProfileKeys.version],
            field: ProvisioningProfileKeys.version
        )
        let isXcodeManaged = try optionalBoolean(
            root[ProvisioningProfileKeys.isXcodeManaged],
            field: ProvisioningProfileKeys.isXcodeManaged
        )
        let provisionedDevices = try parseProvisionedDevices(root[ProvisioningProfileKeys.provisionedDevices])
        let developerCertificates = try parseDeveloperCertificates(root[ProvisioningProfileKeys.developerCertificates])
        let entitlements = try parseEntitlements(root[ProvisioningProfileKeys.entitlements])

        let entitlementApplicationIdentifier = try stringEntitlement(
            entitlements,
            key: ProvisioningProfileEntitlementKeys.applicationIdentifier
        )
        if let rootApplicationIdentifier,
           let entitlementApplicationIdentifier,
           rootApplicationIdentifier != entitlementApplicationIdentifier {
            throw ZynSignError.invalidProvisioningProfileIdentifier(
                diagnosticDetail: "The root and entitlement application identifiers disagree."
            )
        }
        let fullApplicationIdentifier = entitlementApplicationIdentifier ?? rootApplicationIdentifier
        let applicationIdentifier: ProvisioningApplicationIdentifier?
        if let fullApplicationIdentifier {
            applicationIdentifier = try ProvisioningApplicationIdentifier(
                fullValue: fullApplicationIdentifier,
                applicationIdentifierPrefix: prefixes?.first
            )
        } else {
            applicationIdentifier = nil
        }

        let entitlementTeamIdentifier = try stringEntitlement(
            entitlements,
            key: ProvisioningProfileEntitlementKeys.teamIdentifier
        )
        let getTaskAllow = try booleanEntitlement(
            entitlements,
            key: ProvisioningProfileEntitlementKeys.getTaskAllow
        )
        let betaReportsActive = try booleanEntitlement(
            entitlements,
            key: ProvisioningProfileEntitlementKeys.betaReportsActive
        )

        return ProvisioningProfile(
            uuid: uuid,
            profileName: profileName,
            creationDate: creationDate,
            expirationDate: expirationDate,
            platforms: platforms,
            applicationIdentifier: applicationIdentifier,
            applicationIdentifierPrefixes: prefixes,
            teamIdentifiers: teamIdentifiers,
            teamName: teamName,
            entitlementTeamIdentifier: entitlementTeamIdentifier,
            entitlements: entitlements,
            provisionedDevices: provisionedDevices,
            developerCertificates: developerCertificates,
            getTaskAllow: getTaskAllow,
            betaReportsActive: betaReportsActive,
            provisionsAllDevices: provisionsAllDevices,
            version: version,
            isXcodeManaged: isXcodeManaged
        )
    }

    // MARK: - Entitlements

    private func parseEntitlements(_ value: Any?) throws -> ProvisioningProfileEntitlements? {
        guard let value else { return nil }
        guard let dictionary = value as? [String: Any] else {
            throw ZynSignError.invalidProvisioningProfileFieldType(
                diagnosticDetail: "Entitlements was not a dictionary."
            )
        }

        // Decode the dictionary as one tree so the node bound applies across
        // all entitlement keys, not once per key.
        let decoded = try ProvisioningProfileValue.decode(dictionary, limits: limits)
        guard case .dictionary(let values) = decoded else {
            throw ZynSignError.invalidProvisioningProfileFieldType(
                diagnosticDetail: "Entitlements was not a string-keyed dictionary."
            )
        }
        return ProvisioningProfileEntitlements(values: values)
    }

    private func stringEntitlement(
        _ entitlements: ProvisioningProfileEntitlements?,
        key: String
    ) throws -> String? {
        guard let value = entitlements?[key] else { return nil }
        guard case .string(let string) = value else {
            throw ZynSignError.invalidProvisioningProfileFieldType(
                diagnosticDetail: "Entitlement '\(key)' was not a string."
            )
        }
        return string
    }

    private func booleanEntitlement(
        _ entitlements: ProvisioningProfileEntitlements?,
        key: String
    ) throws -> Bool? {
        guard let value = entitlements?[key] else { return nil }
        guard case .boolean(let boolean) = value else {
            throw ZynSignError.invalidProvisioningProfileFieldType(
                diagnosticDetail: "Entitlement '\(key)' was not a boolean."
            )
        }
        return boolean
    }

    // MARK: - Arrays and certificates

    private func parseProvisionedDevices(_ value: Any?) throws -> [ProvisionedDeviceIdentifier]? {
        guard let value else { return nil }
        guard let array = value as? [Any] else {
            throw ZynSignError.invalidProvisioningProfileFieldType(
                diagnosticDetail: "ProvisionedDevices was not an array."
            )
        }
        guard array.count <= limits.maximumCollectionCount else {
            throw ZynSignError.provisioningProfileResourceLimitExceeded(
                diagnosticDetail: "ProvisionedDevices exceeded the configured element bound."
            )
        }
        var identifiers: [ProvisionedDeviceIdentifier] = []
        identifiers.reserveCapacity(array.count)
        for (index, element) in array.enumerated() {
            guard let string = element as? String else {
                throw ZynSignError.invalidProvisioningProfileFieldType(
                    diagnosticDetail: "ProvisionedDevices entry at index \(index) was not a string."
                )
            }
            guard let identifier = ProvisionedDeviceIdentifier(rawValue: string) else {
                throw ZynSignError.invalidProvisioningProfileIdentifier(
                    diagnosticDetail: "ProvisionedDevices entry at index \(index) was not a valid hexadecimal identifier."
                )
            }
            identifiers.append(identifier)
        }
        return identifiers
    }

    private func parseDeveloperCertificates(
        _ value: Any?
    ) throws -> [ProvisioningProfileCertificateReference]? {
        guard let value else { return nil }
        guard let array = value as? [Any] else {
            throw ZynSignError.invalidProvisioningProfileFieldType(
                diagnosticDetail: "DeveloperCertificates was not an array."
            )
        }
        guard array.count <= limits.maximumCollectionCount else {
            throw ZynSignError.provisioningProfileResourceLimitExceeded(
                diagnosticDetail: "DeveloperCertificates exceeded the configured element bound."
            )
        }
        var references: [ProvisioningProfileCertificateReference] = []
        references.reserveCapacity(array.count)
        for (index, element) in array.enumerated() {
            guard let data = element as? Data else {
                throw ZynSignError.invalidProvisioningProfileFieldType(
                    diagnosticDetail: "DeveloperCertificates entry at index \(index) was not a data value."
                )
            }
            guard !data.isEmpty else {
                throw ZynSignError.malformedProvisioningProfileCertificate(
                    diagnosticDetail: "DeveloperCertificates entry at index \(index) was empty."
                )
            }
            guard data.count <= CertificateInput.maximumByteCount else {
                throw ZynSignError.provisioningProfileResourceLimitExceeded(
                    diagnosticDetail: "A DeveloperCertificates entry exceeded the certificate input bound."
                )
            }

            var metadata: CertificateMetadata?
            if let certificateParser {
                do {
                    metadata = try certificateParser.parseCertificate(CertificateInput(bytes: data))
                } catch {
                    // Do not retain or render the parser's error: it may
                    // carry implementation detail, and the profile bytes
                    // must never enter a diagnostic.
                    throw ZynSignError.malformedProvisioningProfileCertificate(
                        diagnosticDetail: "DeveloperCertificates entry at index \(index) could not be parsed."
                    )
                }
            }
            references.append(
                ProvisioningProfileCertificateReference(
                    certificateData: data,
                    metadata: metadata
                )
            )
        }
        return references
    }

    // MARK: - Scalar fields

    private func optionalString(_ value: Any?, field: String) throws -> String? {
        guard let value else { return nil }
        guard let string = value as? String else {
            throw ZynSignError.invalidProvisioningProfileFieldType(
                diagnosticDetail: "Field '\(field)' was not a string."
            )
        }
        guard string.utf8.count <= limits.maximumStringByteCount else {
            throw ZynSignError.provisioningProfileResourceLimitExceeded(
                diagnosticDetail: "Field '\(field)' exceeded the configured string bound."
            )
        }
        return string
    }

    private func optionalNonEmptyStringArray(
        _ value: Any?,
        field: String
    ) throws -> [String]? {
        guard let value else { return nil }
        guard let array = value as? [Any] else {
            throw ZynSignError.invalidProvisioningProfileFieldType(
                diagnosticDetail: "Field '\(field)' was not an array of strings."
            )
        }
        guard array.count <= limits.maximumCollectionCount else {
            throw ZynSignError.provisioningProfileResourceLimitExceeded(
                diagnosticDetail: "Field '\(field)' exceeded the configured element bound."
            )
        }
        var strings: [String] = []
        strings.reserveCapacity(array.count)
        for (index, element) in array.enumerated() {
            guard let string = element as? String else {
                throw ZynSignError.invalidProvisioningProfileFieldType(
                    diagnosticDetail: "Field '\(field)' entry at index \(index) was not a string."
                )
            }
            guard !string.isEmpty,
                  string.utf8.count <= limits.maximumStringByteCount,
                  !string.contains(where: { $0.isControl || $0.isWhitespace }) else {
                throw ZynSignError.invalidProvisioningProfileField(
                    diagnosticDetail: "Field '\(field)' entry at index \(index) was empty, oversized, or contained whitespace."
                )
            }
            strings.append(string)
        }
        return strings
    }

    private func parseUUID(_ value: Any?) throws -> UUID? {
        guard let value else { return nil }
        guard let string = value as? String else {
            throw ZynSignError.invalidProvisioningProfileFieldType(
                diagnosticDetail: "UUID was not a string."
            )
        }
        guard string.utf8.count <= limits.maximumStringByteCount else {
            throw ZynSignError.provisioningProfileResourceLimitExceeded(
                diagnosticDetail: "UUID exceeded the configured string bound."
            )
        }
        guard let uuid = UUID(uuidString: string) else {
            throw ZynSignError.invalidProvisioningProfileIdentifier(
                diagnosticDetail: "UUID did not use a valid UUID representation."
            )
        }
        return uuid
    }

    private func optionalDate(_ value: Any?, field: String) throws -> Date? {
        guard let value else { return nil }
        guard let date = value as? Date else {
            throw ZynSignError.invalidProvisioningProfileDate(
                diagnosticDetail: "Field '\(field)' was not a property-list date."
            )
        }
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw ZynSignError.invalidProvisioningProfileDate(
                diagnosticDetail: "Field '\(field)' was not finite."
            )
        }
        return date
    }

    private func optionalBoolean(_ value: Any?, field: String) throws -> Bool? {
        guard let value else { return nil }
        if let number = value as? NSNumber {
            // Do not use NSNumber.boolValue: that would coerce an integer.
            guard CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() else {
                throw ZynSignError.invalidProvisioningProfileFieldType(
                    diagnosticDetail: "Field '\(field)' was not a boolean."
                )
            }
            return number.boolValue
        }
        if let boolean = value as? Bool {
            return boolean
        }
        throw ZynSignError.invalidProvisioningProfileFieldType(
            diagnosticDetail: "Field '\(field)' was not a boolean."
        )
    }

    private func optionalInteger(_ value: Any?, field: String) throws -> Int64? {
        guard let value else { return nil }
        guard let number = value as? NSNumber,
              CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else {
            throw ZynSignError.invalidProvisioningProfileFieldType(
                diagnosticDetail: "Field '\(field)' was not an integer."
            )
        }
        switch CFNumberGetType(number as CFNumber) {
        case .charType, .sInt8Type, .sInt16Type, .sInt32Type, .sInt64Type, .intType, .longType, .longLongType, .cfIndexType:
            return number.int64Value
        default:
            throw ZynSignError.invalidProvisioningProfileFieldType(
                diagnosticDetail: "Field '\(field)' was not an integer."
            )
        }
    }

    private static func causeSummary(_ error: any Error) -> String {
        if let cocoaError = error as? NSError {
            return "platform error code \(cocoaError.code)"
        }
        return String(describing: type(of: error))
    }
}

/// Keys read from the top-level provisioning-profile property list.
enum ProvisioningProfileKeys {
    static let uuid = "UUID"
    static let name = "Name"
    static let creationDate = "CreationDate"
    static let expirationDate = "ExpirationDate"
    static let platform = "Platform"
    static let applicationIdentifier = "ApplicationIdentifier"
    static let applicationIdentifierPrefix = "ApplicationIdentifierPrefix"
    static let teamIdentifier = "TeamIdentifier"
    static let teamName = "TeamName"
    static let entitlements = "Entitlements"
    static let provisionedDevices = "ProvisionedDevices"
    static let developerCertificates = "DeveloperCertificates"
    static let provisionsAllDevices = "ProvisionsAllDevices"
    static let version = "Version"
    static let isXcodeManaged = "IsXcodeManaged"
}

/// Entitlement keys whose types carry first-class meaning in the profile model.
enum ProvisioningProfileEntitlementKeys {
    static let applicationIdentifier = "application-identifier"
    static let teamIdentifier = "com.apple.developer.team-identifier"
    static let getTaskAllow = "get-task-allow"
    static let betaReportsActive = "beta-reports-active"
}
