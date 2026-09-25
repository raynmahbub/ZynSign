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
}
