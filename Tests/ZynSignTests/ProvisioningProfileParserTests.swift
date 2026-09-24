import Foundation
import XCTest
@testable import ZynSign

/// Synthetic property-list payload tests for ZS-017.
///
/// These are payload fixtures only. No real provisioning profiles, profile
/// signatures, certificates, private keys, device records, or credentials are
/// stored in the test suite.
final class ProvisioningProfileParserTests: XCTestCase {

    private let profileUUID = "12345678-1234-4ABC-8DEF-1234567890AB"
    private let teamIdentifier = "TEAM123456"
    private let bundleIdentifier = "com.example.synthetic"
    private let creationDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let expirationDate = Date(timeIntervalSince1970: 1_900_000_000)

    private var validApplicationIdentifier: String {
        "\(teamIdentifier).\(bundleIdentifier)"
    }

    private func makePayload(
        _ root: [String: Any],
        format: PropertyListSerialization.PropertyListFormat = .binary
    ) -> ProvisioningProfilePayload {
        let data = makePlist(root, format: format)
        return ProvisioningProfilePayload(plistData: data)
    }

    private func makePlist(
        _ root: [String: Any],
        format: PropertyListSerialization.PropertyListFormat = .binary
    ) -> Data {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: root,
            format: format,
            options: []
        ) else {
            XCTFail("Could not create synthetic property-list payload")
            return Data()
        }
        return data
    }

    private func validRoot(
        includeOptionalFields: Bool = false,
        includeDevices: Bool = false,
        includeCertificates: Bool = false
    ) -> [String: Any] {
        var entitlements: [String: Any] = [
            ProvisioningProfileEntitlementKeys.applicationIdentifier: validApplicationIdentifier,
            ProvisioningProfileEntitlementKeys.teamIdentifier: teamIdentifier,
        ]
        if includeOptionalFields {
            entitlements[ProvisioningProfileEntitlementKeys.getTaskAllow] = true
            entitlements[ProvisioningProfileEntitlementKeys.betaReportsActive] = false
            entitlements["synthetic.string"] = "value"
            entitlements["synthetic.integer"] = 7
            entitlements["synthetic.boolean"] = false
            entitlements["synthetic.array"] = ["one", "two"]
            entitlements["synthetic.dictionary"] = ["nested": "value"]
        }

        var root: [String: Any] = [
            ProvisioningProfileKeys.uuid: profileUUID,
            ProvisioningProfileKeys.name: "Synthetic Profile",
            ProvisioningProfileKeys.creationDate: creationDate,
            ProvisioningProfileKeys.expirationDate: expirationDate,
            ProvisioningProfileKeys.applicationIdentifierPrefix: [teamIdentifier],
            ProvisioningProfileKeys.teamIdentifier: [teamIdentifier],
            ProvisioningProfileKeys.platform: ["iPhoneOS"],
            ProvisioningProfileKeys.entitlements: entitlements,
            ProvisioningProfileKeys.version: 1,
        ]
        if includeDevices {
            root[ProvisioningProfileKeys.provisionedDevices] = [String(repeating: "A", count: 40)]
        }
        if includeCertificates {
            root[ProvisioningProfileKeys.developerCertificates] = [
                Data([0x30, 0x01, 0x00]),
                Data([0x30, 0x02, 0x01, 0x00]),
            ]
        }
        return root
    }

    private func parser(
        certificateParser: (any CertificateParser)? = nil,
        limits: ProvisioningProfileParsingLimits = .default
    ) -> PropertyListProvisioningProfileParser {
        PropertyListProvisioningProfileParser(
            certificateParser: certificateParser,
            limits: limits
        )
    }

    private func parse(_ root: [String: Any]) throws -> ProvisioningProfile {
        try parser().parse(makePayload(root))
    }

    private func assertProfileFailure(
        _ expression: @autoclosure () throws -> Any,
        reason: ProvisioningProfileFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let profileError = error as? ZynSignError else {
                return XCTFail("Expected ZynSignError, got \(type(of: error))", file: file, line: line)
            }
            XCTAssertEqual(profileError.provisioningProfileFailure, reason, file: file, line: line)
            XCTAssertFalse(profileError.userMessage.isEmpty, file: file, line: line)
        }
    }

    // MARK: - Basic parsing and metadata

    func testParsesValidMinimalProfile() throws {
        let profile = try parse(validRoot())

        XCTAssertEqual(profile.uuid?.uuidString, profileUUID)
        XCTAssertEqual(profile.profileName, "Synthetic Profile")
        XCTAssertEqual(profile.creationDate, creationDate)
        XCTAssertEqual(profile.expirationDate, expirationDate)
        XCTAssertEqual(profile.applicationIdentifier?.fullValue, validApplicationIdentifier)
        XCTAssertEqual(profile.applicationIdentifierPrefix, teamIdentifier)
        XCTAssertEqual(profile.bundleIdentifier?.rawValue, bundleIdentifier)
        XCTAssertEqual(profile.teamIdentifier, teamIdentifier)
        XCTAssertEqual(profile.teamIdentifiers, [teamIdentifier])
        XCTAssertEqual(profile.platforms, [.iPhoneOS])
        XCTAssertNil(profile.provisionedDevices)
        XCTAssertNil(profile.developerCertificates)
    }

    func testParsesXMLPayloadWithoutChangingTheModel() throws {
        let profile = try parser().parse(makePayload(validRoot(), format: .xml))
        XCTAssertEqual(profile.uuid?.uuidString, profileUUID)
        XCTAssertEqual(profile.entitlements?.count, 2)
    }

    func testParsesOptionalMetadataWithoutRejectingUnknownRootFields() throws {
        var root = validRoot(includeOptionalFields: true, includeDevices: true, includeCertificates: true)
        root["UnknownFutureField"] = ["opaque": [1, 2, 3]]
        root[ProvisioningProfileKeys.provisionsAllDevices] = false
        root[ProvisioningProfileKeys.isXcodeManaged] = true

        let profile = try parse(root)

        XCTAssertEqual(profile.provisionedDevices?.count, 1)
        XCTAssertEqual(profile.provisionedDevices?.first?.rawValue, String(repeating: "A", count: 40))
        XCTAssertEqual(profile.developerCertificates?.count, 2)
        XCTAssertEqual(profile.getTaskAllow, true)
        XCTAssertEqual(profile.betaReportsActive, false)
        XCTAssertEqual(profile.provisionsAllDevices, false)
        XCTAssertEqual(profile.isXcodeManaged, true)
        XCTAssertEqual(profile.version, 1)
        XCTAssertEqual(profile.entitlements?.keys, [
            "beta-reports-active",
            "com.apple.developer.team-identifier",
            "get-task-allow",
            "synthetic.array",
            "synthetic.boolean",
            "synthetic.dictionary",
            "synthetic.integer",
            "synthetic.string",
            "application-identifier",
        ].sorted())
    }

    func testMissingOptionalFieldsRemainDistinctFromEmptyCollections() throws {
        let missing = try parse(validRoot())
        XCTAssertNil(missing.provisionedDevices)
        XCTAssertNil(missing.developerCertificates)

        var emptyRoot = validRoot()
        emptyRoot[ProvisioningProfileKeys.provisionedDevices] = [Any]()
        emptyRoot[ProvisioningProfileKeys.developerCertificates] = [Any]()
        let empty = try parse(emptyRoot)
        XCTAssertEqual(empty.provisionedDevices, [])
        XCTAssertEqual(empty.developerCertificates, [])
    }

    func testPlatformValuesPreserveUnknownValues() throws {
        var root = validRoot()
        root[ProvisioningProfileKeys.platform] = ["iPhoneOS", "FutureOS"]
        let profile = try parse(root)
        XCTAssertEqual(profile.platforms, [.iPhoneOS, .unknown("FutureOS")])
        XCTAssertEqual(profile.platforms?.map(\.rawValue), ["iPhoneOS", "FutureOS"])
    }

    // MARK: - Input and property-list failures

    func testEmptyPayloadIsControlled() {
        assertProfileFailure(
            try parser().parse(ProvisioningProfilePayload(plistData: Data())),
            reason: .emptyPayload
        )
    }

    func testMalformedPayloadIsControlled() {
        assertProfileFailure(
            try parser().parse(ProvisioningProfilePayload(plistData: Data("not a plist".utf8))),
            reason: .malformedPayload
        )
    }

    func testTruncatedPayloadIsControlled() {
        let data = makePayload(validRoot()).plistData
        assertProfileFailure(
            try parser().parse(ProvisioningProfilePayload(plistData: Data(data.prefix(8)))),
            reason: .malformedPayload
        )
    }

    func testOpenStepPayloadIsRejectedAsUnsupported() {
        let openStep = Data("{ UUID = \"12345678-1234-4ABC-8DEF-1234567890AB\"; }".utf8)
        assertProfileFailure(
            try parser().parse(ProvisioningProfilePayload(plistData: openStep)),
            reason: .unsupportedPayloadFormat
        )
    }

    func testNonDictionaryPayloadIsControlled() {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: ["not", "a", "profile"],
            format: .binary,
            options: []
        ) else {
            XCTFail("Could not create the synthetic non-dictionary payload")
            return
        }
        assertProfileFailure(
            try parser().parse(ProvisioningProfilePayload(plistData: data)),
            reason: .malformedPayload
        )
    }

    func testOversizedPayloadIsRejectedBeforePropertyListConversion() {
        let limits = ProvisioningProfilePayload.maximumByteCount
        let data = Data(repeating: 0x41, count: limits + 1)
        assertProfileFailure(
            try parser().parse(ProvisioningProfilePayload(plistData: data)),
            reason: .payloadTooLarge
        )
    }

    func testDeepEntitlementValuesAreBounded() {
        var value: Any = "leaf"
        for _ in 0..<5 {
            value = [value]
        }
        var root = validRoot()
        root[ProvisioningProfileKeys.entitlements] = [
            ProvisioningProfileEntitlementKeys.applicationIdentifier: validApplicationIdentifier,
            "nested": value,
        ]
        let limits = ProvisioningProfileParsingLimits(
            maximumNestingDepth: 2,
            maximumValueNodeCount: 100,
            maximumStringByteCount: 1_024,
            maximumDataByteCount: 1_024,
            maximumCollectionCount: 100
        )
        assertProfileFailure(
            try parser(limits: limits).parse(makePayload(root)),
            reason: .resourceLimitExceeded
        )
    }

    func testOversizedEntitlementScalarIsBounded() {
        var root = validRoot()
        var entitlements = (root[ProvisioningProfileKeys.entitlements] as? [String: Any]) ?? [:]
        entitlements["oversized-data"] = Data(repeating: 0x01, count: 5)
        root[ProvisioningProfileKeys.entitlements] = entitlements
        let limits = ProvisioningProfileParsingLimits(
            maximumNestingDepth: 8,
            maximumValueNodeCount: 100,
            maximumStringByteCount: 1_024,
            maximumDataByteCount: 4,
            maximumCollectionCount: 100
        )
        assertProfileFailure(
            try parser(limits: limits).parse(makePayload(root)),
            reason: .resourceLimitExceeded
        )
    }

    // MARK: - Entitlements

    func testEntitlementsPreserveSupportedTypes() throws {
        var root = validRoot()
        var entitlements = (root[ProvisioningProfileKeys.entitlements] as? [String: Any]) ?? [:]
        entitlements["string"] = "text"
        entitlements["boolean"] = true
        entitlements["integer"] = 42
        entitlements["real"] = 3.5
        entitlements["array"] = ["a", false, 9]
        entitlements["dictionary"] = ["nested": ["value", true]]
        entitlements["data"] = Data([0x01, 0x02])
        entitlements["date"] = creationDate
        root[ProvisioningProfileKeys.entitlements] = entitlements

        let profile = try parse(root)
        let values = try XCTUnwrap(profile.entitlements)
        XCTAssertEqual(values["string"], .string("text"))
        XCTAssertEqual(values["boolean"], .boolean(true))
        XCTAssertEqual(values["integer"], .integer(42))
        XCTAssertEqual(values["real"], .real(3.5))
        XCTAssertEqual(values["array"], .array([.string("a"), .boolean(false), .integer(9)]))
        XCTAssertEqual(values["dictionary"], .dictionary(["nested": .array([.string("value"), .boolean(true)])]))
        XCTAssertEqual(values["data"], .data(Data([0x01, 0x02])))
        XCTAssertEqual(values["date"], .date(creationDate))
    }

    func testMissingEntitlementsParsesButFailsStructuralValidation() throws {
        var root = validRoot()
        root.removeValue(forKey: ProvisioningProfileKeys.entitlements)
        let profile = try parse(root)
        let validation = ProvisioningProfileValidator(clock: FixedEvaluationClock(instant: creationDate))
            .validate(profile)
        XCTAssertFalse(validation.isStructurallyValid)
        XCTAssertTrue(validation.findings.contains { $0.code == .missingRequiredMetadata })
    }

    func testTeamMetadataMismatchIsReportedStructurally() throws {
        var root = validRoot()
        var entitlements = (root[ProvisioningProfileKeys.entitlements] as? [String: Any]) ?? [:]
        entitlements[ProvisioningProfileEntitlementKeys.teamIdentifier] = "OTHERTEAM"
        root[ProvisioningProfileKeys.entitlements] = entitlements
        let profile = try parse(root)
        let validation = ProvisioningProfileValidator(clock: FixedEvaluationClock(instant: creationDate))
            .validate(profile)
        XCTAssertFalse(validation.isStructurallyValid)
        XCTAssertTrue(validation.findings.contains { $0.code == .inconsistentMetadata })
    }

    func testInvalidEntitlementTypeIsNotCoerced() {
        var root = validRoot()
        var entitlements = (root[ProvisioningProfileKeys.entitlements] as? [String: Any]) ?? [:]
        entitlements[ProvisioningProfileEntitlementKeys.getTaskAllow] = "true"
        root[ProvisioningProfileKeys.entitlements] = entitlements
        assertProfileFailure(
            try parser().parse(makePayload(root)),
            reason: .invalidFieldType
        )
    }

    func testInvalidTopLevelTypeIsNotCoerced() {
        var root = validRoot()
        root[ProvisioningProfileKeys.platform] = "iPhoneOS"
        assertProfileFailure(
            try parser().parse(makePayload(root)),
            reason: .invalidFieldType
        )

        root = validRoot()
        root[ProvisioningProfileKeys.version] = true
        assertProfileFailure(
            try parser().parse(makePayload(root)),
            reason: .invalidFieldType
        )
    }

    // MARK: - Application identifiers

    func testApplicationIdentifierDoesNotGuessPrefixWithoutContext() throws {
        var root = validRoot()
        root.removeValue(forKey: ProvisioningProfileKeys.applicationIdentifierPrefix)
        let profile = try parse(root)
        XCTAssertEqual(profile.applicationIdentifier?.fullValue, validApplicationIdentifier)
        XCTAssertNil(profile.applicationIdentifier?.applicationIdentifierPrefix)
        XCTAssertNil(profile.applicationIdentifier?.bundleIdentifierComponent)
        XCTAssertNil(profile.bundleIdentifier)
    }

    func testPrefixMismatchIsRejected() {
        var root = validRoot()
        root[ProvisioningProfileKeys.applicationIdentifierPrefix] = ["OTHERTEAM"]
        assertProfileFailure(
            try parser().parse(makePayload(root)),
            reason: .invalidIdentifier
        )
    }

    func testWildcardApplicationIdentifierIsRepresentedSeparately() throws {
        var root = validRoot()
        var entitlements = (root[ProvisioningProfileKeys.entitlements] as? [String: Any]) ?? [:]
        entitlements[ProvisioningProfileEntitlementKeys.applicationIdentifier] = "\(teamIdentifier).com.example.*"
        root[ProvisioningProfileKeys.entitlements] = entitlements
        let profile = try parse(root)
        XCTAssertEqual(profile.applicationIdentifier?.bundleIdentifierComponent?.rawValue, "com.example.*")
        XCTAssertNil(profile.bundleIdentifier)
        XCTAssertTrue(profile.applicationIdentifier?.bundleIdentifierComponent?.isWildcard == true)
    }

    // MARK: - Dates and structural validation

    func testDateValidityUsesInjectedClockAndInclusiveBoundaries() throws {
        let profile = try parse(validRoot())
        let validator = ProvisioningProfileValidator(clock: FixedEvaluationClock(instant: creationDate))
        let atCreation = validator.validate(profile)
        XCTAssertEqual(atCreation.validity?.periodStatus, .currentlyValid)

        let atExpiration = ProvisioningProfileValidator(clock: FixedEvaluationClock(instant: expirationDate))
            .validate(profile)
        XCTAssertEqual(atExpiration.validity?.periodStatus, .currentlyValid)

        let expired = ProvisioningProfileValidator(
            clock: FixedEvaluationClock(instant: expirationDate.addingTimeInterval(1))
        ).validate(profile)
        XCTAssertEqual(expired.validity?.periodStatus, .expired)

        let future = ProvisioningProfileValidator(
            clock: FixedEvaluationClock(instant: creationDate.addingTimeInterval(-1))
        ).validate(profile)
        XCTAssertEqual(future.validity?.periodStatus, .notYetValid)
    }

    func testCreationAfterExpirationIsStructurallyInvalid() throws {
        var root = validRoot()
        root[ProvisioningProfileKeys.creationDate] = expirationDate
        root[ProvisioningProfileKeys.expirationDate] = creationDate
        let profile = try parse(root)
        let validation = ProvisioningProfileValidator(clock: FixedEvaluationClock(instant: creationDate))
            .validate(profile)
        XCTAssertFalse(validation.isStructurallyValid)
        XCTAssertEqual(validation.findings.first?.code, .invalidDate)
        XCTAssertEqual(validation.validity?.periodStatus, .malformed)
    }

    func testCorruptedDateTypeIsRejected() {
        var root = validRoot()
        root[ProvisioningProfileKeys.creationDate] = "not-a-date"
        assertProfileFailure(
            try parser().parse(makePayload(root)),
            reason: .invalidDate
        )
    }

    func testMissingRequiredMetadataIsReportedWithoutForceUnwrap() throws {
        var root = validRoot()
        root.removeValue(forKey: ProvisioningProfileKeys.uuid)
        root.removeValue(forKey: ProvisioningProfileKeys.name)
        let profile = try parse(root)
        let validation = ProvisioningProfileValidator(clock: FixedEvaluationClock(instant: creationDate))
            .validate(profile)
        XCTAssertFalse(validation.isStructurallyValid)
        XCTAssertEqual(
            validation.findings.map(\.code),
            [.missingRequiredMetadata, .missingRequiredMetadata]
        )
    }

    // MARK: - Devices and certificates

    func testMalformedDeviceIdentifierIsRejectedWithoutNormalization() {
        var root = validRoot()
        root[ProvisioningProfileKeys.provisionedDevices] = ["not-a-device"]
        assertProfileFailure(
            try parser().parse(makePayload(root)),
            reason: .invalidIdentifier
        )
    }

    func testMalformedCertificateInformationIsRejected() {
        var root = validRoot()
        root[ProvisioningProfileKeys.developerCertificates] = ["not-data"]
        assertProfileFailure(
            try parser().parse(makePayload(root)),
            reason: .invalidFieldType
        )

        root[ProvisioningProfileKeys.developerCertificates] = [Data()]
        assertProfileFailure(
            try parser().parse(makePayload(root)),
            reason: .malformedCertificate
        )
    }

    func testCertificateReferencesCanAttachExistingCertificateMetadata() throws {
        let certificateParser = SyntheticCertificateParser()
        let profile = try parser(certificateParser: certificateParser)
            .parse(makePayload(validRoot(includeCertificates: true)))
        let references = try XCTUnwrap(profile.developerCertificates)
        XCTAssertEqual(references.count, 2)
        XCTAssertEqual(references[0].certificateData, Data([0x30, 0x01, 0x00]))
        XCTAssertEqual(references[0].metadata?.subject.commonName, "Synthetic Certificate")
        XCTAssertNotNil(references[1].fingerprint)
    }

    // MARK: - Classification and redaction

    func testClassificationRequiresMoreThanOneIncidentalField() throws {
        let developmentRoot = validRoot(includeOptionalFields: true, includeDevices: true, includeCertificates: true)
        let development = try parse(developmentRoot)
        XCTAssertEqual(development.classification, .development)

        var adHocRoot = validRoot(includeDevices: true)
        var adHocEntitlements = (adHocRoot[ProvisioningProfileKeys.entitlements] as? [String: Any]) ?? [:]
        adHocEntitlements[ProvisioningProfileEntitlementKeys.getTaskAllow] = false
        adHocRoot[ProvisioningProfileKeys.entitlements] = adHocEntitlements
        let adHoc = try parse(adHocRoot)
        XCTAssertEqual(adHoc.classification, .adHoc)

        var enterpriseRoot = validRoot()
        enterpriseRoot[ProvisioningProfileKeys.provisionsAllDevices] = false
        var enterpriseEntitlements = (enterpriseRoot[ProvisioningProfileKeys.entitlements] as? [String: Any]) ?? [:]
        enterpriseEntitlements[ProvisioningProfileEntitlementKeys.getTaskAllow] = false
        enterpriseEntitlements[ProvisioningProfileEntitlementKeys.betaReportsActive] = true
        enterpriseRoot[ProvisioningProfileKeys.entitlements] = enterpriseEntitlements
        let appStore = try parse(enterpriseRoot)
        XCTAssertEqual(appStore.classification, .appStore)

        enterpriseRoot[ProvisioningProfileKeys.provisionsAllDevices] = true
        enterpriseEntitlements[ProvisioningProfileEntitlementKeys.betaReportsActive] = false
        enterpriseRoot[ProvisioningProfileKeys.entitlements] = enterpriseEntitlements
        let enterprise = try parse(enterpriseRoot)
        XCTAssertEqual(enterprise.classification, .enterprise)

        developmentRoot[ProvisioningProfileKeys.provisionsAllDevices] = true
        let conflicting = try parse(developmentRoot)
        XCTAssertEqual(conflicting.classification, .unknown)
    }

    func testProfileErrorsDoNotEchoProfileValues() {
        var root = validRoot()
        let sensitiveDevice = String(repeating: "B", count: 40)
        root[ProvisioningProfileKeys.provisionedDevices] = [sensitiveDevice]
        root[ProvisioningProfileKeys.platform] = 42
        XCTAssertThrowsError(try parser().parse(makePayload(root))) { error in
            let zynSignError = error as? ZynSignError
            XCTAssertNotNil(zynSignError)
            XCTAssertFalse(error.localizedDescription.contains(sensitiveDevice))
            XCTAssertFalse(error.localizedDescription.contains("Synthetic Profile"))
        }
    }
}

private struct SyntheticCertificateParser: CertificateParser {

    func parseCertificate(_ input: CertificateInput) throws -> CertificateMetadata {
        guard !input.bytes.isEmpty else {
            throw ZynSignError.invalidCertificateData()
        }
        let distinguishedName = CertificateDistinguishedName(rawRepresentation: "CN=Synthetic Certificate")
        let serialNumber = try XCTUnwrap(CertificateSerialNumber(hexadecimal: "01"))
        let fingerprint = try XCTUnwrap(
            CertificateFingerprint(
                hexDigest: String(repeating: "a", count: CertificateFingerprint.hexDigestLength)
            )
        )
        return CertificateMetadata(
            subject: distinguishedName,
            issuer: distinguishedName,
            serialNumber: serialNumber,
            notValidBefore: Date(timeIntervalSince1970: 1_600_000_000),
            notValidAfter: Date(timeIntervalSince1970: 2_000_000_000),
            publicKeyInfo: PublicKeyInfo(algorithm: .rsa, keySizeInBits: 2048),
            signatureAlgorithm: .sha256WithRSAEncryption,
            sha256Fingerprint: fingerprint
        )
    }
}
