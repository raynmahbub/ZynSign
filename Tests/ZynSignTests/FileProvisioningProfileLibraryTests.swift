import XCTest
@testable import ZynSign

final class FileProvisioningProfileLibraryTests: XCTestCase {

    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ZynSignProfileLibraryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testEmptyLibraryReturnsNothing() async throws {
        let lib = FileProvisioningProfileLibrary(catalogLocation: temporaryDirectory.appendingPathComponent("profiles.json"))
        XCTAssertEqual(try await lib.count(), 0)
        XCTAssertEqual(try await lib.allProfiles(), [])
    }

    func testUpsertAndRetrieve() async throws {
        let lib = FileProvisioningProfileLibrary(catalogLocation: temporaryDirectory.appendingPathComponent("profiles.json"))
        let now = Date()
        let summary = ProvisioningProfileSummary(
            name: "My Profile",
            teamIdentifier: "TEAM123",
            bundleIdentifierPatterns: ["com.example.*"],
            expirationDate: now.addingTimeInterval(60 * 86400),
            entitlementsKeys: ["get-task-allow"],
            allowsDebug: true,
            sourceFileName: "p.mobileprovision",
            importedAt: now
        )
        try await lib.upsert(summary)
        XCTAssertEqual(try await lib.count(), 1)
        let fetched = try await lib.profile(withID: summary.id)
        XCTAssertEqual(fetched, summary)
    }

    func testPersistsAcrossInstances() async throws {
        let location = temporaryDirectory.appendingPathComponent("profiles.json")
        let now = Date()
        let summary = ProvisioningProfileSummary(
            name: "Persisted",
            teamIdentifier: nil,
            bundleIdentifierPatterns: [],
            expirationDate: now.addingTimeInterval(86400),
            entitlementsKeys: [],
            allowsDebug: false,
            sourceFileName: "p.mobileprovision",
            importedAt: now
        )
        let first = FileProvisioningProfileLibrary(catalogLocation: location)
        try await first.upsert(summary)
        let second = FileProvisioningProfileLibrary(catalogLocation: location)
        let fetched = try await second.profile(withID: summary.id)
        XCTAssertEqual(fetched?.name, "Persisted")
    }

    func testRemove() async throws {
        let lib = FileProvisioningProfileLibrary(catalogLocation: temporaryDirectory.appendingPathComponent("profiles.json"))
        let now = Date()
        let summary = ProvisioningProfileSummary(
            name: "Throwaway",
            teamIdentifier: nil,
            bundleIdentifierPatterns: [],
            expirationDate: now.addingTimeInterval(86400),
            entitlementsKeys: [],
            allowsDebug: false,
            sourceFileName: "p.mobileprovision",
            importedAt: now
        )
        try await lib.upsert(summary)
        try await lib.remove(profileWithID: summary.id)
        XCTAssertEqual(try await lib.count(), 0)
    }

    func testSavedProfileBytesAreBoundedAndRemovalDeletesTheUnreferencedCopy() async throws {
        let location = temporaryDirectory.appendingPathComponent("saved.mobileprovision")
        let contents = Data([0x30, 0x04, 0x01, 0x02])
        try contents.write(to: location)
        let lib = FileProvisioningProfileLibrary(catalogLocation: temporaryDirectory.appendingPathComponent("profiles.json"))
        let summary = makeSummary(fileName: location.lastPathComponent)
        try await lib.upsert(summary)

        let selected = try await lib.profileBytes(withID: summary.id)
        XCTAssertEqual(selected, contents)
        try await lib.remove(profileWithID: summary.id)
        let removed = try await lib.profileBytes(withID: summary.id)
        XCTAssertNil(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.path))
    }

    func testSavedProfileRefusesOversizedAndUnsafeReferences() async throws {
        let lib = FileProvisioningProfileLibrary(catalogLocation: temporaryDirectory.appendingPathComponent("profiles.json"))
        let oversized = makeSummary(fileName: "too-big.mobileprovision")
        try Data(repeating: 0x30, count: ProvisioningProfileInput.maximumByteCount + 1)
            .write(to: temporaryDirectory.appendingPathComponent(oversized.sourceFileName))
        try await lib.upsert(oversized)
        do {
            _ = try await lib.profileBytes(withID: oversized.id)
            XCTFail("An oversized saved profile must not reach CMS inspection.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .invalidInput)
        }

        let traversal = makeSummary(fileName: "../outside.mobileprovision")
        try await lib.upsert(traversal)
        do {
            _ = try await lib.profileBytes(withID: traversal.id)
            XCTFail("Catalog paths must not escape the saved-profile directory.")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.category, .storageFailure)
        }
    }

    func testDeletionKeepsAStoredFileWhileAnotherSummaryReferencesIt() async throws {
        let location = temporaryDirectory.appendingPathComponent("shared.mobileprovision")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: location)
        let lib = FileProvisioningProfileLibrary(catalogLocation: temporaryDirectory.appendingPathComponent("profiles.json"))
        let first = makeSummary(fileName: location.lastPathComponent)
        let second = makeSummary(fileName: location.lastPathComponent)
        try await lib.upsert(first)
        try await lib.upsert(second)
        try await lib.remove(profileWithID: first.id)
        let remaining = try await lib.profileBytes(withID: second.id)
        XCTAssertEqual(remaining, bytes)
        try await lib.remove(profileWithID: second.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.path))
    }

    private func makeSummary(fileName: String) -> ProvisioningProfileSummary {
        ProvisioningProfileSummary(
            name: "Synthetic", teamIdentifier: nil, bundleIdentifierPatterns: [],
            expirationDate: Date(timeIntervalSince1970: 1_900_000_000),
            entitlementsKeys: [], allowsDebug: false, sourceFileName: fileName,
            importedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}
