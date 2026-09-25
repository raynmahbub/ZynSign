import Foundation
import XCTest
@testable import ZynSign

/// Synthetic payload decoder: these tests exercise importer decisions and
/// storage, NOT CMS cryptography (covered separately by profile verification).
final class ProvisioningProfileImporterTests: XCTestCase {
    private var directory: URL!
    private var storage: URL { directory.appendingPathComponent("Saved", isDirectory: true) }

    override func setUpWithError() throws {
        directory = try LibraryFixtures.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    func testAuthenticatedExactAppIDIsNotInventedAsAWildcard() async throws {
        let input = directory.appendingPathComponent("human-readable.mobileprovision")
        let originalBytes = Data([0x30, 0x01, 0x02])
        try originalBytes.write(to: input)
        let importer = try makeImporter(scope: "com.example.synthetic", authenticity: .authenticated)
        let summary = try await importer.importProfile(at: input)

        XCTAssertEqual(summary.bundleIdentifierPatterns, ["com.example.synthetic"])
        XCTAssertTrue(summary.covers(bundleIdentifier: "com.example.synthetic"))
        XCTAssertFalse(summary.covers(bundleIdentifier: "com.example.other"))
        XCTAssertFalse(summary.sourceFileName.contains("human-readable"))
        XCTAssertEqual(try Data(contentsOf: storage.appendingPathComponent(summary.sourceFileName)), originalBytes)
        XCTAssertEqual(summary.expirationDate, Date(timeIntervalSince1970: 1_900_000_000))
    }

    func testWildcardAndBareWildcardSummariesKeepTheirActualScope() async throws {
        let input = directory.appendingPathComponent("scope.mobileprovision")
        try Data([0x30, 0x01, 0x03]).write(to: input)
        let scoped = try await makeImporter(scope: "com.example.*", authenticity: .authenticated)
            .importProfile(at: input)
        XCTAssertEqual(scoped.bundleIdentifierPatterns, ["com.example.*"])
        XCTAssertTrue(scoped.covers(bundleIdentifier: "com.example.app"))
        XCTAssertFalse(scoped.covers(bundleIdentifier: "com.example"))
        XCTAssertFalse(scoped.covers(bundleIdentifier: "com.exampleOther.app"))

        let bare = try await makeImporter(scope: "*", authenticity: .authenticated)
            .importProfile(at: input)
        XCTAssertEqual(bare.bundleIdentifierPatterns, ["*"])
        XCTAssertTrue(bare.covers(bundleIdentifier: "any.bundle"))
    }

    func testUnauthenticatedOrIncompleteProfilesAreNotSavedOrGivenInventedExpiry() async throws {
        let input = directory.appendingPathComponent("not-verified.mobileprovision")
        try Data([0x30, 0x01, 0x04]).write(to: input)
        let unchecked = try makeImporter(scope: "com.example.synthetic", authenticity: .notEvaluated)
        do {
            _ = try await unchecked.importProfile(at: input)
            XCTFail("Decoding a CMS payload without authenticating it must not create a saved profile.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .invalidInput)
        }
        let incomplete = try makeImporter(scope: "com.example.synthetic", authenticity: .authenticated,
                                          includesExpiry: false)
        do {
            _ = try await incomplete.importProfile(at: input)
            XCTFail("A missing expiry must not be replaced by an invented date.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .invalidInput)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.path))
    }

    private func makeImporter(
        scope: String, authenticity: ProvisioningProfileAuthenticityStatus,
        includesExpiry: Bool = true
    ) throws -> ProvisioningProfileImporter {
        var root: [String: Any] = [
            ProvisioningProfileKeys.uuid: "12345678-1234-4ABC-8DEF-1234567890AB",
            ProvisioningProfileKeys.name: "Synthetic Import Profile",
            ProvisioningProfileKeys.creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            ProvisioningProfileKeys.applicationIdentifierPrefix: ["TEAM123456"],
            ProvisioningProfileKeys.teamIdentifier: ["TEAM123456"],
            ProvisioningProfileKeys.platform: ["iPhoneOS"],
            ProvisioningProfileKeys.entitlements: [
                ProvisioningProfileEntitlementKeys.applicationIdentifier: "TEAM123456." + scope,
                ProvisioningProfileEntitlementKeys.teamIdentifier: "TEAM123456",
                ProvisioningProfileEntitlementKeys.getTaskAllow: true
            ]
        ]
        if includesExpiry {
            root[ProvisioningProfileKeys.expirationDate] = Date(timeIntervalSince1970: 1_900_000_000)
        }
        let payload = try PropertyListSerialization.data(
            fromPropertyList: root, format: .binary, options: 0
        )
        let inspection = ProvisioningProfileInspectionUseCase(
            payloadDecoder: PreparedPayloadDecoder(payload: ProvisioningProfilePayload(
                plistData: payload, authenticity: authenticity
            )), clock: FixedEvaluationClock(instant: Date(timeIntervalSince1970: 1_800_000_000))
        )
        return ProvisioningProfileImporter(inspection: inspection, storageDirectory: storage)
    }
}

private struct PreparedPayloadDecoder: ProvisioningProfilePayloadDecoder {
    let payload: ProvisioningProfilePayload

    func decodePayload(from input: ProvisioningProfileInput) throws -> ProvisioningProfilePayload {
        payload
    }
}
