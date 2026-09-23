import Foundation
@testable import ZynSign

/// Synthetic fixtures for policy validation.
///
/// Every value here is invented for the test suite: placeholder identifiers, a
/// synthetic team identifier, synthetic device strings, and fingerprints built
/// from repeated hexadecimal text. No real provisioning profile, production
/// team or bundle identifier, device identifier, certificate, or credential
/// appears anywhere in this file. The certificate metadata fixtures carry no DER
/// bytes at all, so no private-key material can be reachable from them.
enum ProvisioningPolicyFixtures {

    // MARK: - Instants

    /// The instant the fixture profiles are evaluated at by default. It falls
    /// inside the default profile's validity period.
    static let evaluationDate = Date(timeIntervalSince1970: 1_800_000_000)

    /// An instant before the default profile's creation date.
    static let beforeCreationDate = Date(timeIntervalSince1970: 1_600_000_000)

    /// An instant after the default profile's expiration date.
    static let afterExpirationDate = Date(timeIntervalSince1970: 2_000_000_000)

    /// The default profile's creation instant.
    static let creationDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// The default profile's expiration instant.
    static let expirationDate = Date(timeIntervalSince1970: 1_900_000_000)

    // MARK: - Identifiers

    static let teamIdentifier = "TEAM123456"
    static let otherTeamIdentifier = "TEAM654321"
    static let bundleIdentifier = "com.example.synthetic"
    static let otherBundleIdentifier = "com.example.other"

    /// A bundle identifier, or a fixture failure.
    static func bundle(_ rawValue: String = bundleIdentifier) -> BundleIdentifier {
        guard let identifier = BundleIdentifier(rawValue: rawValue) else {
            fatalError("The synthetic bundle identifier fixture could not be built.")
        }
        return identifier
    }

    /// An application identifier, or a fixture failure.
    static func applicationIdentifier(
        prefix: String = teamIdentifier,
        component: String = bundleIdentifier
    ) -> ProvisioningApplicationIdentifier {
        do {
            return try ProvisioningApplicationIdentifier(
                fullValue: prefix + "." + component,
                applicationIdentifierPrefix: prefix
            )
        } catch {
            fatalError("The synthetic application identifier fixture could not be built.")
        }
    }

    /// A device identifier from hexadecimal-shaped text.
    static func device(_ hex: String) -> ProvisionedDeviceIdentifier {
        guard let identifier = ProvisionedDeviceIdentifier(rawValue: hex) else {
            fatalError("The synthetic device identifier fixture could not be built.")
        }
        return identifier
    }

    static let deviceA = device(String(repeating: "A", count: 40))
    static let deviceB = device(String(repeating: "B", count: 40))

    // MARK: - Fingerprints

    /// A fingerprint from hexadecimal text.
    static func fingerprint(_ hex: String) -> CertificateFingerprint {
        guard let fingerprint = CertificateFingerprint(hexDigest: hex) else {
            fatalError("The synthetic fingerprint fixture could not be built.")
        }
        return fingerprint
    }

    /// The fingerprint the profile's own certificate reference and the signing
    /// identity share by default.
    static let profileCertificateFingerprint = fingerprint(String(repeating: "ab", count: 32))

    /// A fingerprint no fixture certificate carries.
    static let unrelatedFingerprint = fingerprint(String(repeating: "cd", count: 32))

    // MARK: - Entitlements

    /// An allowlist shaped like the fixtures' profiles.
    ///
    /// The application-identifier claim, the team claim, and the debugging
    /// claim are the three keys policy evaluation handles with dedicated rules;
    /// additional claims can be added for the generic rules.
    static func entitlements(
        applicationIdentifierValue: String? = teamIdentifier + "." + bundleIdentifier,
        teamValue: String? = teamIdentifier,
        getTaskAllow: Bool? = false,
        betaReportsActive: Bool? = nil,
        additional: [String: ProvisioningProfileValue] = [:]
    ) -> ProvisioningProfileEntitlements {
        var values: [String: ProvisioningProfileValue] = [:]
        if let applicationIdentifierValue {
            values[ProvisioningProfileEntitlementKeys.applicationIdentifier] = .string(applicationIdentifierValue)
        }
        if let teamValue {
            values[ProvisioningProfileEntitlementKeys.teamIdentifier] = .string(teamValue)
        }
        if let getTaskAllow {
            values[ProvisioningProfileEntitlementKeys.getTaskAllow] = .boolean(getTaskAllow)
        }
        if let betaReportsActive {
            values[ProvisioningProfileEntitlementKeys.betaReportsActive] = .boolean(betaReportsActive)
        }
        for (key, value) in additional {
            values[key] = value
        }
        return ProvisioningProfileEntitlements(values: values)
    }

    // MARK: - Profiles

    /// The profile shapes the policy tests need. The cases exist so that a
    /// fixture cannot accidentally classify as a different profile class than
    /// the test intends; `enterpriseWithDeviceList` is deliberately
    /// contradictory.
    enum ProfileShape: String, CaseIterable {
        case enterprise
        case enterpriseWithDeviceList
        case development
        case adHoc
        case appStore
        case undetermined
    }

    /// A certificate reference. It holds no DER bytes and no metadata, which is
    /// enough for the profile's own classification and for the reference count;
    /// comparison fingerprints are supplied by the relationship fixture.
    static func certificateReference() -> ProvisioningProfileCertificateReference {
        ProvisioningProfileCertificateReference(certificateData: Data([0x30, 0x00]))
    }

    /// A parsed profile shaped like a synthetic profile payload.
    static func profile(
        shape: ProfileShape = .enterprise,
        applicationIdentifierPrefix: String = teamIdentifier,
        applicationIdentifierComponent: String = bundleIdentifier,
        includeApplicationIdentifier: Bool = true,
        creationDate: Date? = creationDate,
        expirationDate: Date? = expirationDate,
        platforms: [ProvisioningProfilePlatform]? = [.iPhoneOS],
        teamIdentifiers: [String]? = [teamIdentifier],
        entitlements: ProvisioningProfileEntitlements? = nil,
        includeEntitlements: Bool = true,
        provisionedDevices: [ProvisionedDeviceIdentifier]? = nil,
        developerCertificates: [ProvisioningProfileCertificateReference]? = nil,
        provisionsAllDevicesOverride: Bool?? = nil,
        version: Int64? = 1
    ) -> ProvisioningProfile {
        let devices: [ProvisionedDeviceIdentifier]?
        let provisionsAllDevices: Bool?
        let certificates: [ProvisioningProfileCertificateReference]?
        let defaultGetTaskAllow: Bool?
        let betaReportsActive: Bool?
        let defaultApplicationIdentifierValue: String?

        switch shape {
        case .enterprise:
            devices = provisionedDevices
            provisionsAllDevices = true
            certificates = developerCertificates ?? [certificateReference()]
            defaultGetTaskAllow = false
            betaReportsActive = nil
            defaultApplicationIdentifierValue = applicationIdentifierPrefix + "." + applicationIdentifierComponent
        case .enterpriseWithDeviceList:
            devices = provisionedDevices ?? [deviceA]
            provisionsAllDevices = true
            certificates = developerCertificates ?? [certificateReference()]
            defaultGetTaskAllow = false
            betaReportsActive = nil
            defaultApplicationIdentifierValue = applicationIdentifierPrefix + "." + applicationIdentifierComponent
        case .development:
            devices = provisionedDevices ?? [deviceA]
            provisionsAllDevices = nil
            certificates = developerCertificates ?? [certificateReference()]
            defaultGetTaskAllow = true
            betaReportsActive = nil
            defaultApplicationIdentifierValue = applicationIdentifierPrefix + "." + applicationIdentifierComponent
        case .adHoc:
            devices = provisionedDevices ?? [deviceA]
            provisionsAllDevices = nil
            certificates = developerCertificates ?? [certificateReference()]
            defaultGetTaskAllow = false
            betaReportsActive = nil
            defaultApplicationIdentifierValue = applicationIdentifierPrefix + "." + applicationIdentifierComponent
        case .appStore:
            devices = provisionedDevices
            provisionsAllDevices = nil
            certificates = developerCertificates ?? [certificateReference()]
            defaultGetTaskAllow = false
            betaReportsActive = true
            defaultApplicationIdentifierValue = applicationIdentifierPrefix + "." + applicationIdentifierComponent
        case .undetermined:
            devices = provisionedDevices
            provisionsAllDevices = nil
            certificates = developerCertificates
            defaultGetTaskAllow = nil
            betaReportsActive = nil
            defaultApplicationIdentifierValue = nil
        }

        let resolvedEntitlements: ProvisioningProfileEntitlements? = includeEntitlements
            ? (entitlements ?? Self.entitlements(
                applicationIdentifierValue: defaultApplicationIdentifierValue,
                teamValue: teamIdentifiers?.first,
                getTaskAllow: defaultGetTaskAllow,
                betaReportsActive: betaReportsActive
            ))
            : nil

        return ProvisioningProfile(
            uuid: UUID(uuidString: "12345678-1234-4ABC-8DEF-1234567890AB"),
            profileName: "Synthetic Policy Profile",
            creationDate: creationDate,
            expirationDate: expirationDate,
            platforms: platforms,
            applicationIdentifier: includeApplicationIdentifier
                ? applicationIdentifier(
                    prefix: applicationIdentifierPrefix,
                    component: applicationIdentifierComponent
                )
                : nil,
            applicationIdentifierPrefixes: includeApplicationIdentifier ? [applicationIdentifierPrefix] : nil,
            teamIdentifiers: teamIdentifiers,
            entitlementTeamIdentifier: teamIdentifiers?.first,
            entitlements: resolvedEntitlements,
            provisionedDevices: devices,
            developerCertificates: certificates,
            getTaskAllow: Self.booleanEntitlement(
                resolvedEntitlements[ProvisioningProfileEntitlementKeys.getTaskAllow]
            ),
            betaReportsActive: Self.booleanEntitlement(
                resolvedEntitlements[ProvisioningProfileEntitlementKeys.betaReportsActive]
            ),
            provisionsAllDevices: provisionsAllDevicesOverride ?? provisionsAllDevices,
            version: version,
            isXcodeManaged: nil
        )
    }

    private static func booleanEntitlement(_ value: ProvisioningProfileValue?) -> Bool? {
        guard let value else { return nil }
        if case .boolean(let boolean) = value { return boolean }
        return nil
    }

    // MARK: - Application and identity

    /// Application metadata declaring an identifier and, by default, an iPhone
    /// device family, which is the platform evidence the platform rule derives
    /// from when the caller states no platform explicitly.
    static func applicationMetadata(
        bundleIdentifier: String = bundleIdentifier,
        deviceFamilies: [ApplicationDeviceFamily]? = [.phone]
    ) -> ApplicationMetadata {
        do {
            return ApplicationMetadata(
                identity: try ApplicationIdentity(bundleIdentifier: bundleIdentifier),
                executableName: "Synthetic",
                minimumOSVersion: "17.0",
                deviceFamily: deviceFamilies,
                iconName: nil
            )
        } catch {
            fatalError("The synthetic application metadata fixture could not be built.")
        }
    }

    /// Safe signing-identity metadata. The certificate carries only structured
    /// attributes and a fingerprint: no DER bytes and no key material.
    static func identityMetadata(
        fingerprint: CertificateFingerprint = profileCertificateFingerprint,
        organizationalUnits: [String] = [teamIdentifier],
        commonName: String = "ZynSign Synthetic Identity",
        keyAvailability: SigningKeyAvailability = .available,
        association: CertificateKeyAssociation = .matched,
        capabilityState: SigningCapabilityState = .ready
    ) -> SigningIdentityMetadata {
        var attributes: [CertificateNameAttribute] = organizationalUnits.map { unit in
            CertificateNameAttribute(
                objectIdentifier: "2.5.4.11",
                recognition: .organizationalUnit,
                value: .text(unit)
            )
        }
        attributes.append(
            CertificateNameAttribute(
                objectIdentifier: "2.5.4.3",
                recognition: .commonName,
                value: .text(commonName)
            )
        )
        let metadata = CertificateMetadata(
            subject: CertificateDistinguishedName.from(attributes: attributes),
            issuer: CertificateDistinguishedName(rawRepresentation: "CN=ZynSign Test CA"),
            serialNumber: serialNumber("1000"),
            notValidBefore: creationDate,
            notValidAfter: expirationDate,
            publicKeyInfo: PublicKeyInfo(algorithm: .rsa, keySizeInBits: 2048),
            signatureAlgorithm: .sha256WithRSAEncryption,
            sha256Fingerprint: fingerprint
        )
        return SigningIdentityMetadata(
            id: identityID,
            certificate: metadata,
            keyAvailability: keyAvailability,
            association: association,
            capabilityState: capabilityState
        )
    }

    /// The identifier the synthetic identity carries. Opacity is the point:
    /// nothing about the certificate is derived from it.
    static let identityID: SigningIdentityIdentifier = {
        guard let uuid = UUID(uuidString: "87654321-4321-4CBA-BDEF-0987654321AB") else {
            fatalError("The synthetic identity identifier fixture could not be built.")
        }
        return SigningIdentityIdentifier(uuid: uuid)
    }()

    private static func serialNumber(_ hexadecimal: String) -> CertificateSerialNumber {
        guard let serial = CertificateSerialNumber(hexadecimal: hexadecimal) else {
            fatalError("The synthetic serial number fixture could not be built.")
        }
        return serial
    }

    // MARK: - Certificate relationship

    /// The relationship the CMS boundary would establish for a profile whose
    /// single certificate the signer and the identity both hold.
    static func relationship(
        profileCertificates: [CertificateFingerprint] = [profileCertificateFingerprint],
        match: CertificateMatchOutcome = .matched,
        signerFingerprint: CertificateFingerprint? = profileCertificateFingerprint,
        profileReferenceWithoutMetadataCount: Int = 0
    ) -> ProvisioningProfileCertificateRelationship {
        ProvisioningProfileCertificateRelationship(
            signerCertificateStatus: signerFingerprint == nil ? .absentFromMessage : .extracted,
            signerFingerprint: signerFingerprint,
            profileCertificateCount: profileCertificates.count,
            profileCertificateFingerprints: profileCertificates,
            profileReferenceWithoutMetadataCount: profileReferenceWithoutMetadataCount,
            duplicateProfileCertificateCount: 0,
            match: match,
            localSigningIdentity: .notEvaluated,
            localSigningIdentityKeyAvailability: nil,
            trustEvaluation: .notPerformed
        )
    }

    // MARK: - Configuration and context

    /// A requested signing configuration. An empty claim set is the default so
    /// that a test states only the claims it cares about.
    static func configuration(
        entitlements: ProvisioningProfileEntitlements? = ProvisioningProfileEntitlements(values: [:]),
        getTaskAllow: SigningGetTaskAllowPreference = .unspecified,
        intendedProfileClass: ProvisioningProfileClassification? = nil
    ) -> SigningConfiguration {
        SigningConfiguration(
            entitlements: entitlements,
            getTaskAllow: getTaskAllow,
            intendedProfileClass: intendedProfileClass
        )
    }

    /// A policy context whose every category is satisfied at the default
    /// evaluation instant.
    static func context(
        profile: ProvisioningProfile? = profile(),
        profileAuthenticity: ProvisioningProfileAuthenticityStatus = .authenticated,
        certificateRelationship: ProvisioningProfileCertificateRelationship = relationship(),
        applicationMetadata: ApplicationMetadata? = applicationMetadata(),
        bundleIdentifier: BundleIdentifier? = nil,
        signingIdentity: ProvisioningPolicySigningIdentity = .identity(identityMetadata()),
        signingConfiguration: SigningConfiguration = configuration(),
        deviceContext: ProvisioningDeviceContext = .unavailable,
        intendedPlatforms: [ProvisioningProfilePlatform]? = nil
    ) -> ProvisioningPolicyValidationContext {
        ProvisioningPolicyValidationContext(
            profile: profile,
            profileAuthenticity: profileAuthenticity,
            certificateRelationship: certificateRelationship,
            applicationMetadata: applicationMetadata,
            bundleIdentifier: bundleIdentifier,
            signingIdentity: signingIdentity,
            signingConfiguration: signingConfiguration,
            deviceContext: deviceContext,
            intendedPlatforms: intendedPlatforms
        )
    }

    // MARK: - Staged verification

    /// A staged verification result carrying a synthetic profile and a
    /// synthetic certificate relationship. No container bytes are involved:
    /// the CMS boundary's own behaviour is covered by its own suite.
    static func verification(
        profile: ProvisioningProfile? = profile(),
        authenticity: ProvisioningProfileAuthenticityStatus = .authenticated,
        relationship: ProvisioningProfileCertificateRelationship = relationship()
    ) -> ProvisioningProfileVerification {
        let inspection: ProvisioningProfileInspection?
        if let profile {
            inspection = ProvisioningProfileInspection(
                profile: profile,
                validation: ProvisioningProfileValidation(
                    classification: .valid,
                    findings: [],
                    validity: nil
                ),
                authenticity: authenticity,
                authorization: .notEvaluated
            )
        } else {
            inspection = nil
        }

        let status: CMSSignatureVerificationStatus
        switch authenticity {
        case .authenticated: status = .verified
        case .rejected: status = .invalid
        case .notEvaluated: status = .unavailable
        }

        return ProvisioningProfileVerification(
            cms: CMSVerificationResult(
                status: status,
                signerCount: 1,
                signerCertificateStatus: relationship.signerCertificateStatus,
                trustEvaluation: .notPerformed
            ),
            inspection: inspection,
            parsingState: inspection == nil ? .notAttempted : .parsed,
            certificateRelationship: relationship,
            trustEvaluation: .notPerformed,
            authorization: .notEvaluated
        )
    }

    // MARK: - Evaluation

    static func validator(at instant: Date = evaluationDate) -> ProvisioningPolicyValidator {
        ProvisioningPolicyValidator(clock: FixedEvaluationClock(instant: instant))
    }

    static func validate(
        _ context: ProvisioningPolicyValidationContext,
        at instant: Date = evaluationDate
    ) -> ProvisioningPolicyValidationResult {
        validator(at: instant).validate(context)
    }
}
