import XCTest
@testable import ZynSign

/// What ZynSign's storage use case measures and removes.
///
/// The tests run over real files in a synthetic directory, so a footprint is
/// what the application would report and a cleanup is what the application
/// would do. The assertion that matters most is the one that never moves: no
/// cleanup can reach an imported application.
@MainActor
final class StorageManagementTests: XCTestCase {

    private var root: URL!
    private var layout: StorageLayout!
    private var management: StorageManagement!

    override func setUp() async throws {
        try await super.setUp()
        root = try SettingsFixtures.makeTemporaryDirectory()
        layout = SettingsFixtures.makeStorageLayout(root: root)
        management = SettingsFixtures.makeStorageManagement(root: root)
    }

    override func tearDown() async throws {
        management = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        layout = nil
        root = nil
        try await super.tearDown()
    }

    // MARK: - Measuring

    func testEveryCategoryIsMeasuredEvenWhenNothingIsThere() async throws {
        let footprint = try await management.footprint()

        XCTAssertEqual(footprint.usages.count, StorageCategory.allCases.count)
        XCTAssertEqual(footprint.totalByteCount, 0)
        XCTAssertEqual(footprint.usage(of: .importedApplications).itemCount, 0)
    }

    func testAFootprintReportsTheBytesTheFilesAllocate() async throws {
        try SettingsFixtures.write(
            Data(repeating: 0x41, count: 8_192),
            to: layout.exportedArtifacts.appendingPathComponent("Signed.ipa")
        )
        try SettingsFixtures.write(
            Data(repeating: 0x42, count: 4_096),
            to: layout.importedApplications.appendingPathComponent("Imported.ipa")
        )

        let footprint = try await management.footprint()

        XCTAssertGreaterThanOrEqual(footprint.usage(of: .exportedArtifacts).byteCount, 8_192)
        XCTAssertGreaterThanOrEqual(footprint.usage(of: .importedApplications).byteCount, 4_096)
        XCTAssertEqual(
            footprint.totalByteCount,
            footprint.usages.reduce(0) { $0 + $1.byteCount },
            "The total is the sum of the rows."
        )
    }

    func testTheHistoryItemCountIsTheNumberOfRecords() async throws {
        let store = FileSigningHistoryStore(journalLocation: layout.history, capacity: 20)
        for index in 0..<3 {
            try await store.append(SigningRecord(
                presetID: nil,
                certificateFingerprint: nil,
                sourceBundleIdentifier: "com.zynsign.test",
                sourceDisplayName: "Signed \(index)",
                stoppingStage: nil,
                errorCode: nil,
                outputFileName: "Signed\(index).ipa",
                outputByteCount: nil,
                startedAt: Date(),
                duration: 1,
                result: .succeeded
            ))
        }

        let footprint = try await management.footprint()

        XCTAssertEqual(footprint.usage(of: .history).itemCount, 3)
        XCTAssertGreaterThan(footprint.usage(of: .history).byteCount, 0)
    }

    // MARK: - Cleanup

    func testRemovingSignedArtifactsLeavesTheImportedApplicationsAlone() async throws {
        let exported = layout.exportedArtifacts.appendingPathComponent("Signed.ipa")
        let imported = layout.importedApplications.appendingPathComponent("Imported.ipa")
        try SettingsFixtures.write(Data(repeating: 0x41, count: 8_192), to: exported)
        try SettingsFixtures.write(Data(repeating: 0x42, count: 8_192), to: imported)
        try await SettingsFixtures.makeExportRecordStore(root: root)
            .write(SettingsFixtures.makeExportRecord(fileName: "Signed.ipa", byteCount: 8_192))

        let report = try await management.cleanup(.exportedArtifacts)

        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: imported.path),
            "Imported applications are the library, and no cleanup can reach them."
        )
        XCTAssertGreaterThan(report.freedByteCount, 0)
        XCTAssertEqual(report.removedArtifactCount, 1, "Only recorded exports are artifacts.")
    }

    func testTemporaryCleanupLeavesEntriesThatMayStillBeInUse() async throws {
        let working = layout.temporary[0].appendingPathComponent("zynsign-working-1")
        try SettingsFixtures.write(Data(repeating: 0x41, count: 4_096), to: working)

        let report = try await management.cleanup(.temporaryFiles)

        XCTAssertEqual(report.removedTemporaryFileCount, 0)
        XCTAssertEqual(report.skippedItemCount, 1, "Work younger than the retention interval is left alone.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: working.path))
    }

    func testTemporaryCleanupRemovesEntriesThatAreOldEnough() async throws {
        let stale = layout.temporary[0].appendingPathComponent("zynsign-working-1")
        let other = layout.temporary[0].appendingPathComponent("zynsign-working-2")
        try SettingsFixtures.write(Data(repeating: 0x41, count: 4_096), to: stale)
        try SettingsFixtures.write(Data(repeating: 0x42, count: 4_096), to: other)
        let staleInstant = Date().addingTimeInterval(-2 * 3_600)
        try FileManager.default.setAttributes([.modificationDate: staleInstant], ofItemAtPath: stale.path)

        let report = try await management.cleanup(.temporaryFiles)

        XCTAssertEqual(report.removedTemporaryFileCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testRemovingOldHistoryRecordsKeepsTheMostRecentOnes() async throws {
        let store = FileSigningHistoryStore(journalLocation: layout.history, capacity: 100)
        for index in 0..<25 {
            try await store.append(SigningRecord(
                presetID: nil,
                certificateFingerprint: nil,
                sourceBundleIdentifier: "com.zynsign.test",
                sourceDisplayName: "Old \(index)",
                stoppingStage: nil,
                errorCode: nil,
                outputFileName: "Old\(index).ipa",
                outputByteCount: nil,
                startedAt: Date().addingTimeInterval(-40 * 86_400),
                duration: 1,
                result: .succeeded
            ))
        }

        let report = try await management.cleanup(.oldHistoryRecords)

        let remaining = (try? await store.allRecords()) ?? []
        XCTAssertEqual(remaining.count, StorageCleanupPolicy.minimumRetainedHistoryRecords)
        XCTAssertGreaterThan(report.removedHistoryRecordCount, 0)
    }

    func testACleanupWithNothingToDoReportsNothing() async throws {
        let report = try await management.cleanup(.temporaryFiles)

        XCTAssertTrue(report.removedNothing)
        XCTAssertEqual(report.summary, "Nothing needed to be removed.")
    }
}
