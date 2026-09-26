import XCTest
@testable import ZynSign

final class SigningPresetTests: XCTestCase {

    func testPresetWithoutCertificateIsIncomplete() {
        let now = Date()
        let preset = SigningPreset(
            name: "Draft",
            createdAt: now,
            updatedAt: now
        )
        XCTAssertFalse(preset.isComplete)
    }

    func testPresetWithBothInputsIsComplete() {
        let now = Date()
        let fingerprint = CertificateFingerprint(algorithm: .sha256, hexDigest:
            String(repeating: "a", count: 64))!
        let preset = SigningPreset(
            name: "Personal",
            certificateFingerprint: fingerprint,
            provisioningProfileName: "My Profile",
            createdAt: now,
            updatedAt: now
        )
        XCTAssertTrue(preset.isComplete)
    }

    func testCodableRoundTrip() throws {
        let now = Date()
        let fingerprint = CertificateFingerprint(algorithm: .sha256, hexDigest:
            String(repeating: "b", count: 64))!
        let preset = SigningPreset(
            name: "Personal",
            certificateFingerprint: fingerprint,
            provisioningProfileName: "My Profile",
            entitlementsSlot: .modern,
            bundleIdentifierOverride: "com.example.app",
            displayNameOverride: "MyApp",
            createdAt: now,
            updatedAt: now
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(preset)
        let decoded = try decoder.decode(SigningPreset.self, from: data)
        XCTAssertEqual(decoded, preset)
    }

    func testSortByRecencyThenName() {
        let now = Date()
        let a = SigningPreset(
            name: "Apple",
            createdAt: now.addingTimeInterval(-100),
            updatedAt: now.addingTimeInterval(-100)
        )
        let b = SigningPreset(
            name: "Banana",
            createdAt: now.addingTimeInterval(-100),
            updatedAt: now.addingTimeInterval(-50)
        )
        let sorted = [a, b].sorted(by: SigningPreset.sortByRecencyThenName)
        XCTAssertEqual(sorted.first?.name, "Banana")
    }
}

final class SigningRecordTests: XCTestCase {

    func testOutcomeDerivesFromOutput() {
        let now = Date()
        let succeeded = SigningRecord(
            presetID: nil,
            certificateFingerprint: nil,
            sourceBundleIdentifier: "com.example",
            sourceDisplayName: "Example",
            stoppingStage: "verification",
            errorCode: nil,
            outputFileName: "out.ipa",
            outputByteCount: 1000,
            startedAt: now,
            duration: 1.0
        )
        XCTAssertEqual(succeeded.outcome, .succeeded)

        let cancelled = SigningRecord(
            presetID: nil,
            certificateFingerprint: nil,
            sourceBundleIdentifier: nil,
            sourceDisplayName: nil,
            stoppingStage: nil,
            errorCode: nil,
            outputFileName: nil,
            outputByteCount: nil,
            startedAt: now,
            duration: 0.5
        )
        XCTAssertEqual(cancelled.outcome, .cancelled)

        let failed = SigningRecord(
            presetID: nil,
            certificateFingerprint: nil,
            sourceBundleIdentifier: nil,
            sourceDisplayName: nil,
            stoppingStage: "extraction",
            errorCode: "ERR",
            outputFileName: nil,
            outputByteCount: nil,
            startedAt: now,
            duration: 0.2
        )
        XCTAssertEqual(failed.outcome, .failed)
    }

    func testCodableRoundTrip() throws {
        let now = Date()
        let fingerprint = CertificateFingerprint(algorithm: .sha256, hexDigest:
            String(repeating: "c", count: 64))!
        let record = SigningRecord(
            presetID: PresetIdentifier(),
            certificateFingerprint: fingerprint,
            sourceBundleIdentifier: "com.example",
            sourceDisplayName: "Example",
            stoppingStage: "verification",
            errorCode: nil,
            outputFileName: "out.ipa",
            outputByteCount: 2048,
            startedAt: now,
            duration: 1.5
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(record)
        let decoded = try decoder.decode(SigningRecord.self, from: data)
        XCTAssertEqual(decoded, record)
    }
}

final class SigningPresetProfileSummaryTests: XCTestCase {

    func testCoversExactBundleIdentifier() {
        let now = Date()
        let summary = ProvisioningProfileSummary(
            name: "P",
            teamIdentifier: nil,
            bundleIdentifierPatterns: ["com.example.app"],
            expirationDate: now.addingTimeInterval(86400),
            entitlementsKeys: [],
            allowsDebug: false,
            sourceFileName: "p.mobileprovision",
            importedAt: now
        )
        XCTAssertTrue(summary.covers(bundleIdentifier: "com.example.app"))
        XCTAssertFalse(summary.covers(bundleIdentifier: "com.example.other"))
    }

    func testCoversWildcardPattern() {
        let now = Date()
        let summary = ProvisioningProfileSummary(
            name: "P",
            teamIdentifier: nil,
            bundleIdentifierPatterns: ["com.example.*"],
            expirationDate: now.addingTimeInterval(86400),
            entitlementsKeys: [],
            allowsDebug: false,
            sourceFileName: "p.mobileprovision",
            importedAt: now
        )
        XCTAssertTrue(summary.covers(bundleIdentifier: "com.example.app"))
        XCTAssertTrue(summary.covers(bundleIdentifier: "com.example.sub.app"))
        XCTAssertFalse(summary.covers(bundleIdentifier: "com.other.app"))
    }

    func testExpiredDetection() {
        let now = Date()
        let summary = ProvisioningProfileSummary(
            name: "P",
            teamIdentifier: nil,
            bundleIdentifierPatterns: [],
            expirationDate: now.addingTimeInterval(-86400),
            entitlementsKeys: [],
            allowsDebug: false,
            sourceFileName: "p.mobileprovision",
            importedAt: now
        )
        XCTAssertTrue(summary.isExpired(referenceDate: now))
        XCTAssertLessThan(summary.daysUntilExpiration(referenceDate: now), 0)
    }

    func testSortPutsSoonestToExpireFirst() {
        let now = Date()
        let expiring = ProvisioningProfileSummary(
            name: "soon",
            teamIdentifier: nil,
            bundleIdentifierPatterns: [],
            expirationDate: now.addingTimeInterval(2 * 86400),
            entitlementsKeys: [],
            allowsDebug: false,
            sourceFileName: "soon.mobileprovision",
            importedAt: now
        )
        let later = ProvisioningProfileSummary(
            name: "later",
            teamIdentifier: nil,
            bundleIdentifierPatterns: [],
            expirationDate: now.addingTimeInterval(60 * 86400),
            entitlementsKeys: [],
            allowsDebug: false,
            sourceFileName: "later.mobileprovision",
            importedAt: now
        )
        let expired = ProvisioningProfileSummary(
            name: "expired",
            teamIdentifier: nil,
            bundleIdentifierPatterns: [],
            expirationDate: now.addingTimeInterval(-86400),
            entitlementsKeys: [],
            allowsDebug: false,
            sourceFileName: "expired.mobileprovision",
            importedAt: now
        )
        let sorted = [later, expired, expiring].sorted(by: ProvisioningProfileSummary.sortByExpiration)
        XCTAssertEqual(sorted.map(\.name), ["soon", "later", "expired"])
    }
}
