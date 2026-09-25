import XCTest
@testable import ZynSign

/// `ProvisioningProfileImporter`: the rich summary the manager persists,
/// the fixed bundle-pattern derivation, typed refusals for corrupt and
/// oversized input, and Refresh Validation's re-read-and-repair behaviour.
final class ProvisioningProfileImporterTests: XCTestCase {

    private var storageDirectory: URL!
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    private let profileUUID = "12345678-1234-4ABC-8DEF-1234567890AB"
    private let team = "TEAM123456"

    override func setUpWithError() throws {
        storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileImporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let storageDirectory {
            try? FileManager.default.removeItem(at: storageDirectory)
        }
    }

    // MARK: - Fixtures

    private func makeRoot(
        applicationIdentifier: String = "TEAM123456.com.example.synthetic",
        teamName: String? = "Synthetic Team",
        includeDevices: Bool = true,
        includeCertificates: Bool = true
    ) -> [String: Any] {
        let entitlements: [String: Any] = [
            ProvisioningProfileEntitlementKeys.applicationIdentifier: applicationIdentifier,
            ProvisioningProfileEntitlementKeys.teamIdentifier: team,
            ProvisioningProfileEntitlementKeys.getTaskAllow: true,
        ]
        var root: [String: Any] = [
            ProvisioningProfileKeys.uuid: profileUUID,
            ProvisioningProfileKeys.name: "Synthetic Profile",
            ProvisioningProfileKeys.creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            ProvisioningProfileKeys.expirationDate: Date(timeIntervalSince1970: 1_900_000_000),
            ProvisioningProfileKeys.applicationIdentifierPrefix: [team],
            ProvisioningProfileKeys.teamIdentifier: [team],
            ProvisioningProfileKeys.entitlements: entitlements,
            ProvisioningProfileKeys.version: 1,
        ]
        if let teamName {
            root[ProvisioningProfileKeys.teamName] = teamName
        }
        if includeDevices {
            root[ProvisioningProfileKeys.provisionedDevices] = [String(repeating: "A", count: 40)]
        }
        if includeCertificates {
            root[ProvisioningProfileKeys.developerCertificates] = [Data([0x30, 0x00])]
        }
        return root
    }

    private func makePayload(root: [String: Any]) -> ProvisioningProfilePayload {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        ) else {
            XCTFail("Could not create synthetic profile payload")
            return ProvisioningProfilePayload(plistData: Data())
        }
        return ProvisioningProfilePayload(plistData: data)
    }

    private func makeImporter(
        payload: ProvisioningProfilePayload
    ) -> ProvisioningProfileImporter {
        let inspection = ProvisioningProfileInspectionUseCase(
            payloadDecoder: StubPayloadDecoder(payload: payload),
            parser: PropertyListProvisioningProfileParser(
                certificateParser: SyntheticCertificateParser()
            ),
            clock: FixedEvaluationClock(instant: fixedNow)
        )
        let now = fixedNow
        return ProvisioningProfileImporter(
            inspection: inspection,
            storageDirectory: storageDirectory,
            now: { now }
        )
    }

    private func writeSourceFile(named name: String = "profile.mobileprovision") throws -> URL {
        let url = storageDirectory.appendingPathComponent("source-\(name)")
        try Data("synthetic-profile-bytes".utf8).write(to: url)
        return url
    }

    // MARK: - Import

    func testImportRecordsTheRichSummaryTheManagerDisplays() async throws {
        let importer = makeImporter(payload: makePayload(root: makeRoot()))
        let source = try writeSourceFile()

        let summary = try await importer.importProfile(at: source)

        XCTAssertEqual(summary.name, "Synthetic Profile")
        XCTAssertEqual(summary.uuid, profileUUID)
        XCTAssertEqual(summary.teamIdentifier, team)
        XCTAssertEqual(summary.teamName, "Synthetic Team")
        XCTAssertEqual(
            summary.creationDate,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(summary.profileType, .development)
        XCTAssertEqual(summary.deviceCount, 1)
        XCTAssertEqual(
            summary.applicationIdentifier,
            "TEAM123456.com.example.synthetic"
        )
        XCTAssertEqual(summary.bundleIdentifier, "com.example.synthetic")
        XCTAssertFalse(summary.isWildcard)
        // The pattern is the bare bundle identifier — the derivation the
        // compatibility engine matches with, not the old team-prefixed form.
        XCTAssertEqual(summary.bundleIdentifierPatterns, ["com.example.synthetic"])
        XCTAssertTrue(summary.covers(bundleIdentifier: "com.example.synthetic"))
        XCTAssertEqual(
            summary.certificateFingerprints,
            [String(repeating: "ab", count: 32)]
        )
        XCTAssertEqual(summary.importedAt, fixedNow)
        XCTAssertEqual(summary.entitlementsKeys.sorted(), [
            "application-identifier",
            "com.apple.developer.team-identifier",
            "get-task-allow",
        ])
        // The stored copy exists beside the catalog under the recorded name.
        let stored = storageDirectory.appendingPathComponent(summary.sourceFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))
        XCTAssertNotEqual(summary.sourceFileName, source.lastPathComponent)
    }

    func testImportWildcardProfileDerivesPrefixPattern() async throws {
        let root = makeRoot(applicationIdentifier: "TEAM123456.com.example.*")
        let importer = makeImporter(payload: makePayload(root: root))
        let source = try writeSourceFile()

        let summary = try await importer.importProfile(at: source)

        XCTAssertEqual(summary.bundleIdentifierPatterns, ["com.example.*"])
        XCTAssertNil(summary.bundleIdentifier)
        XCTAssertTrue(summary.isWildcard)
        XCTAssertTrue(summary.covers(bundleIdentifier: "com.example.app"))
        XCTAssertFalse(summary.covers(bundleIdentifier: "org.other.app"))
    }

    func testImportTeamWideProfileDerivesUniversalPattern() async throws {
        let root = makeRoot(applicationIdentifier: "TEAM123456.*")
        let importer = makeImporter(payload: makePayload(root: root))
        let source = try writeSourceFile()

        let summary = try await importer.importProfile(at: source)

        XCTAssertEqual(summary.bundleIdentifierPatterns, ["*"])
        XCTAssertTrue(summary.isWildcard)
        XCTAssertTrue(summary.covers(bundleIdentifier: "anything.at.all"))
    }

    func testCorruptPayloadIsRefusedWithTypedErrorAndNothingStored() async throws {
        // The decoder yields bytes that are not a profile property list;
        // the parser refuses them with a typed profile failure.
        let garbage = ProvisioningProfilePayload(plistData: Data("not-a-profile".utf8))
        let importer = makeImporter(payload: garbage)
        let source = try writeSourceFile()
        let before = Set(
            try FileManager.default.contentsOfDirectory(atPath: storageDirectory.path)
        )

        do {
            _ = try await importer.importProfile(at: source)
            XCTFail("A corrupt payload must be refused")
        } catch let error as ZynSignError {
            XCTAssertNotNil(error.provisioningProfileFailure)
            XCTAssertFalse(error.userMessage.isEmpty)
        }

        let after = Set(
            try FileManager.default.contentsOfDirectory(atPath: storageDirectory.path)
        )
        XCTAssertEqual(before, after)
    }

    func testOversizedFileIsRefusedBeforeItIsReadIntoMemory() async throws {
        let importer = makeImporter(payload: makePayload(root: makeRoot()))
        let oversized = storageDirectory.appendingPathComponent("oversized.mobileprovision")
        try Data(count: ProvisioningProfileInput.maximumByteCount + 1).write(to: oversized)

        do {
            _ = try await importer.importProfile(at: oversized)
            XCTFail("An oversized profile file must be refused")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.provisioningProfileFailure, .inputTooLarge)
        }
    }

    // MARK: - Refresh Validation

    func testRefreshRepairsLegacySummaryAndPreservesIdentity() async throws {
        let importer = makeImporter(payload: makePayload(root: makeRoot()))
        let imported = try await importer.importProfile(at: try writeSourceFile())

        // A summary as the pre-manager importer would have written it:
        // team-prefixed pattern, no new fields, its own id and import date.
        let legacyImportedAt = fixedNow.addingTimeInterval(-1_000)
        let legacy = ProvisioningProfileSummary(
            id: ProvisioningProfileIdentifier(rawValue: "legacy-summary-id"),
            name: imported.name,
            teamIdentifier: imported.teamIdentifier,
            bundleIdentifierPatterns: ["TEAM123456.com.example.*"],
            expirationDate: imported.expirationDate,
            entitlementsKeys: [],
            allowsDebug: false,
            sourceFileName: imported.sourceFileName,
            importedAt: legacyImportedAt
        )
        XCTAssertFalse(legacy.covers(bundleIdentifier: "com.example.synthetic"))

        let refreshed = try await importer.refresh(legacy)

        XCTAssertEqual(refreshed.id.rawValue, "legacy-summary-id")
        XCTAssertEqual(refreshed.importedAt, legacyImportedAt)
        XCTAssertEqual(refreshed.bundleIdentifierPatterns, ["com.example.synthetic"])
        XCTAssertTrue(refreshed.covers(bundleIdentifier: "com.example.synthetic"))
        XCTAssertEqual(refreshed.uuid, profileUUID)
        XCTAssertEqual(refreshed.teamName, "Synthetic Team")
        XCTAssertEqual(refreshed.profileType, .development)
        XCTAssertEqual(refreshed.deviceCount, 1)
        XCTAssertEqual(refreshed.sourceFileName, imported.sourceFileName)
    }

    func testRefreshOfMissingStoredFileFailsWithStorageError() async throws {
        let importer = makeImporter(payload: makePayload(root: makeRoot()))
        let summary = ProvisioningProfileSummary(
            name: "Gone",
            teamIdentifier: team,
            bundleIdentifierPatterns: ["com.example.synthetic"],
            expirationDate: fixedNow.addingTimeInterval(86400),
            entitlementsKeys: [],
            allowsDebug: false,
            sourceFileName: "vanished.mobileprovision",
            importedAt: fixedNow
        )

        do {
            _ = try await importer.refresh(summary)
            XCTFail("A missing stored file must fail refresh")
        } catch let error as ZynSignError {
            XCTAssertEqual(
                error.userMessage,
                "ZynSign could not access your provisioning profiles."
            )
        }
    }
}

// MARK: - Test doubles

private struct StubPayloadDecoder: ProvisioningProfilePayloadDecoder {
    let payload: ProvisioningProfilePayload

    func decodePayload(from input: ProvisioningProfileInput) throws -> ProvisioningProfilePayload {
        payload
    }
}

/// Parses any non-empty certificate reference into fixed synthetic
/// metadata carrying a stable fingerprint — no DER parsing, no keys.
private struct SyntheticCertificateParser: CertificateParser {
    func parseCertificate(_ input: CertificateInput) throws -> CertificateMetadata {
        guard !input.bytes.isEmpty else {
            throw ZynSignError.invalidCertificateData()
        }
        let distinguishedName = CertificateDistinguishedName(
            commonName: "Synthetic Certificate",
            rawRepresentation: "CN=Synthetic Certificate"
        )
        guard let serialNumber = CertificateSerialNumber(hexadecimal: "01"),
              let fingerprint = CertificateFingerprint(
                hexDigest: String(repeating: "ab", count: CertificateFingerprint.hexDigestLength)
              ) else {
            throw ZynSignError.invalidCertificateData()
        }
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
