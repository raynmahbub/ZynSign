import XCTest
@testable import ZynSign

/// The enriched `ProvisioningProfileSummary`: the pattern-derivation fix
/// that made `covers` always fail for imported profiles, the computed
/// helpers the manager displays, and — most importantly — that catalogs
/// written before the manager existed still decode under schema 1.
final class ProvisioningProfileSummaryTests: XCTestCase {

    private let referenceDate = Date()

    private func makeSummary(
        patterns: [String],
        bundleIdentifier: String? = nil,
        applicationIdentifier: String? = nil,
        profileType: ProvisioningProfileClassification? = nil,
        deviceCount: Int? = nil,
        teamName: String? = nil,
        uuid: String? = nil,
        creationDate: Date? = nil,
        certificateFingerprints: [String]? = nil,
        expirationDate: Date? = nil
    ) -> ProvisioningProfileSummary {
        ProvisioningProfileSummary(
            name: "Synthetic",
            teamIdentifier: "TEAM123456",
            bundleIdentifierPatterns: patterns,
            expirationDate: expirationDate ?? referenceDate.addingTimeInterval(90 * 86400),
            entitlementsKeys: [],
            allowsDebug: false,
            sourceFileName: "sample.mobileprovision",
            importedAt: referenceDate,
            uuid: uuid,
            teamName: teamName,
            creationDate: creationDate,
            profileType: profileType,
            deviceCount: deviceCount,
            applicationIdentifier: applicationIdentifier,
            bundleIdentifier: bundleIdentifier,
            certificateFingerprints: certificateFingerprints
        )
    }

    // MARK: - covers()

    func testExactPatternCoversOnlyItsBundle() {
        let summary = makeSummary(
            patterns: ["com.example.app"],
            bundleIdentifier: "com.example.app"
        )
        XCTAssertTrue(summary.covers(bundleIdentifier: "com.example.app"))
        XCTAssertFalse(summary.covers(bundleIdentifier: "com.example.other"))
        XCTAssertFalse(summary.covers(bundleIdentifier: "com.example.app.more"))
    }

    func testWildcardPatternCoversBeneathItsPrefix() {
        let summary = makeSummary(
            patterns: ["com.example.*"],
            applicationIdentifier: "TEAM123456.com.example.*"
        )
        XCTAssertTrue(summary.covers(bundleIdentifier: "com.example.app"))
        XCTAssertTrue(summary.covers(bundleIdentifier: "com.example"))
        XCTAssertTrue(summary.covers(bundleIdentifier: "com.example.nested.app"))
        XCTAssertFalse(summary.covers(bundleIdentifier: "com.examplar.app"))
        XCTAssertFalse(summary.covers(bundleIdentifier: "org.other.app"))
    }

    func testTeamWidePatternCoversEveryBundle() {
        let summary = makeSummary(
            patterns: ["*"],
            applicationIdentifier: "TEAM123456.*"
        )
        XCTAssertTrue(summary.covers(bundleIdentifier: "com.example.anything"))
        XCTAssertTrue(summary.covers(bundleIdentifier: "org.other.app"))
        XCTAssertTrue(summary.isWildcard)
    }

    func testLegacyTeamPrefixedPatternDoesNotMatchPlainBundleIdentifiers() {
        // The pre-manager importer derived "TEAM.com.example.*" from the full
        // App ID, which never matches a plain bundle identifier. Documents
        // why Refresh Validation exists: only a re-read repairs such entries.
        let legacy = makeSummary(patterns: ["TEAM123456.com.example.*"])
        XCTAssertFalse(legacy.covers(bundleIdentifier: "com.example.app"))
    }

    // MARK: - Computed helpers

    func testResolvedProfileTypeDefaultsToUnknown() {
        XCTAssertNil(makeSummary(patterns: []).profileType)
        XCTAssertEqual(makeSummary(patterns: []).resolvedProfileType, .unknown)
        XCTAssertEqual(
            makeSummary(patterns: [], profileType: .adHoc).resolvedProfileType,
            .adHoc
        )
    }

    func testIsWildcardOnlyForWildcardProfiles() {
        XCTAssertFalse(makeSummary(patterns: ["com.example.app"], bundleIdentifier: "com.example.app").isWildcard)
        XCTAssertTrue(makeSummary(patterns: ["com.example.*"], bundleIdentifier: nil).isWildcard)
    }

    func testDeviceCountDescription() {
        XCTAssertEqual(makeSummary(patterns: [], deviceCount: 3).deviceCountDescription, "3")
        XCTAssertEqual(
            makeSummary(patterns: [], profileType: .enterprise).deviceCountDescription,
            "All devices"
        )
        XCTAssertNil(makeSummary(patterns: [], profileType: .appStore).deviceCountDescription)
        XCTAssertNil(makeSummary(patterns: [], profileType: .development).deviceCountDescription)
    }

    func testResolvedCertificateFingerprintsNormaliseToLowercase() {
        let summary = makeSummary(patterns: [], certificateFingerprints: [String(repeating: "AB", count: 32)])
        XCTAssertEqual(
            summary.resolvedCertificateFingerprints,
            [String(repeating: "ab", count: 32)]
        )
        XCTAssertEqual(makeSummary(patterns: []).resolvedCertificateFingerprints, [])
    }

    // MARK: - Catalog compatibility

    /// A schema-1 catalog written before the manager existed — only the
    /// original nine fields — must decode without loss.
    func testLegacyCatalogEntryDecodesWithNilNewFields() throws {
        let legacyJSON = """
        {
            "id": { "rawValue": "11111111-2222-3333-4444-555555555555" },
            "name": "Legacy Profile",
            "teamIdentifier": "TEAM123456",
            "bundleIdentifierPatterns": ["TEAM123456.com.example.*"],
            "expirationDate": 700000000,
            "entitlementsKeys": ["application-identifier"],
            "allowsDebug": true,
            "sourceFileName": "legacy.mobileprovision",
            "importedAt": 600000000
        }
        """
        let summary = try JSONDecoder().decode(
            ProvisioningProfileSummary.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertEqual(summary.name, "Legacy Profile")
        XCTAssertEqual(summary.teamIdentifier, "TEAM123456")
        XCTAssertEqual(summary.bundleIdentifierPatterns, ["TEAM123456.com.example.*"])
        XCTAssertNil(summary.uuid)
        XCTAssertNil(summary.teamName)
        XCTAssertNil(summary.creationDate)
        XCTAssertNil(summary.profileType)
        XCTAssertNil(summary.deviceCount)
        XCTAssertNil(summary.applicationIdentifier)
        XCTAssertNil(summary.bundleIdentifier)
        XCTAssertNil(summary.certificateFingerprints)
        XCTAssertEqual(summary.resolvedProfileType, .unknown)
    }

    func testEnrichedSummaryRoundTripsThroughJSON() throws {
        let summary = makeSummary(
            patterns: ["com.example.app"],
            bundleIdentifier: "com.example.app",
            applicationIdentifier: "TEAM123456.com.example.app",
            profileType: .adHoc,
            deviceCount: 2,
            teamName: "Synthetic Team",
            uuid: "12345678-1234-4ABC-8DEF-1234567890AB",
            creationDate: referenceDate.addingTimeInterval(-30 * 86400),
            certificateFingerprints: [String(repeating: "ab", count: 32)]
        )
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(ProvisioningProfileSummary.self, from: data)
        XCTAssertEqual(decoded, summary)
        XCTAssertEqual(decoded.profileType, .adHoc)
        XCTAssertEqual(decoded.uuid, "12345678-1234-4ABC-8DEF-1234567890AB")
        XCTAssertEqual(decoded.teamName, "Synthetic Team")
        XCTAssertEqual(decoded.deviceCount, 2)
    }

    /// An unrecognised profile-type raw value fails decoding loudly rather
    /// than being silently misread; a future build that adds a type is
    /// expected to bump the catalog schema version so older builds refuse
    /// the catalog with the schema message instead.
    func testUnknownProfileTypeRawValueIsRejectedNotMisread() throws {
        let json = """
        {
            "id": { "rawValue": "11111111-2222-3333-4444-555555555555" },
            "name": "Future Profile",
            "teamIdentifier": null,
            "bundleIdentifierPatterns": [],
            "expirationDate": 700000000,
            "entitlementsKeys": [],
            "allowsDebug": false,
            "sourceFileName": "future.mobileprovision",
            "importedAt": 600000000,
            "profileType": "visionProAdHoc"
        }
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(ProvisioningProfileSummary.self, from: Data(json.utf8))
        )
    }

    // MARK: - Sort order

    func testSortByExpirationSinksExpiredProfiles() {
        let healthy = makeSummary(patterns: [], expirationDate: referenceDate.addingTimeInterval(60 * 86400))
        let expiring = makeSummary(patterns: [], expirationDate: referenceDate.addingTimeInterval(10 * 86400))
        let expired = makeSummary(patterns: [], expirationDate: referenceDate.addingTimeInterval(-86400))
        let sorted = [healthy, expired, expiring].sorted(by: ProvisioningProfileSummary.sortByExpiration)
        XCTAssertEqual(
            sorted.map { $0.expirationDate },
            [expiring.expirationDate, healthy.expirationDate, expired.expirationDate]
        )
    }
}
