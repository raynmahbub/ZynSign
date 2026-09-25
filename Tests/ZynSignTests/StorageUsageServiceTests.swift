import XCTest
@testable import ZynSign

/// The Storage Manager's measurements and cleanups, over synthetic
/// locations: what each row counts, and what each action may remove.
final class StorageUsageServiceTests: XCTestCase {

    private var root: URL!
    private var locations: StorageLocations!
    private var service: StorageUsageService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try SettingsFixtures.makeTemporaryDirectory()
        locations = SettingsFixtures.makeStorageLocations(root: root)
        service = StorageUsageService(locations: locations)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        locations = nil
        service = nil
        try super.tearDownWithError()
    }

    // MARK: - Measurement

    func testEveryCategoryIsMeasuredFromItsOwnLocation() async {
        try? SettingsFixtures.write(Data(repeating: 0x41, count: 4_096), to: locations.libraryArtifacts.appendingPathComponent("Example.ipa"))
        try? SettingsFixtures.write(Data(repeating: 0x42, count: 4_096), to: locations.signedArtifacts.appendingPathComponent("Example-signed.ipa"))
        try? SettingsFixtures.write(Data(repeating: 0x43, count: 4_096), to: locations.temporary.appendingPathComponent("zynsign-staging-1"))
        try? SettingsFixtures.write(Data(repeating: 0x44, count: 4_096), to: locations.caches.appendingPathComponent("ZynSignAppIcons/icon.png"))
        try? SettingsFixtures.write(Data(repeating: 0x45, count: 4_096), to: locations.signingHistoryJournal)
        try? SettingsFixtures.write(Data(repeating: 0x46, count: 4_096), to: locations.preferencesDocument)

        let report = await service.report()

        XCTAssertGreaterThan(report.bytes(for: .importedApps), 0)
        XCTAssertGreaterThan(report.bytes(for: .signedArtifacts), 0)
        XCTAssertGreaterThan(report.bytes(for: .temporaryFiles), 0)
        XCTAssertGreaterThan(report.bytes(for: .cache), 0)
        XCTAssertGreaterThan(report.bytes(for: .history), 0)
        XCTAssertGreaterThan(report.bytes(for: .records), 0)
        XCTAssertEqual(report.total, report.usage.values.reduce(0, +))
    }

    func testAnEmptyStorageReportsZeroEverywhere() async {
        let report = await service.report()

        for category in StorageCategory.allCases {
            XCTAssertEqual(report.bytes(for: category), 0, category.title)
        }
        XCTAssertEqual(report.total, 0)
        XCTAssertEqual(report.fraction(for: .importedApps), 0)
    }

    func testTheTotalIsTheSumOfTheRowsRatherThanAnEstimate() async {
        try? SettingsFixtures.write(Data(repeating: 0x41, count: 4_096), to: locations.libraryArtifacts.appendingPathComponent("Example.ipa"))
        try? SettingsFixtures.write(Data(repeating: 0x42, count: 4_096), to: locations.signedArtifacts.appendingPathComponent("Example-signed.ipa"))

        let report = await service.report()

        XCTAssertEqual(
            report.total,
            report.bytes(for: .importedApps) + report.bytes(for: .signedArtifacts)
        )
        XCTAssertGreaterThan(report.fraction(for: .importedApps), 0)
        XCTAssertEqual(
            report.fraction(for: .importedApps) + report.fraction(for: .signedArtifacts),
            1,
            accuracy: 0.0001
        )
    }

    func testSharedDirectoriesCountOnlyWhatZynSignWrote() async {
        let foreign = locations.temporary.appendingPathComponent("AnotherApp-scratch")
        let owned = locations.temporary.appendingPathComponent("zynsign-staging-1")
        try? SettingsFixtures.write(Data(repeating: 0x42, count: 4_096), to: foreign)
        try? SettingsFixtures.write(Data(repeating: 0x43, count: 4_096), to: locations.caches.appendingPathComponent("AnotherApp-cache"))

        let withForeignFilesOnly = await service.report()
        try? SettingsFixtures.write(Data(repeating: 0x41, count: 4_096), to: owned)
        let withOwnedFileToo = await service.report()

        // Another application's files, in directories the system shares with
        // every application, are neither counted nor offered for review.
        XCTAssertEqual(withForeignFilesOnly.bytes(for: .temporaryFiles), 0)
        XCTAssertEqual(withForeignFilesOnly.bytes(for: .cache), 0)
        XCTAssertGreaterThan(withOwnedFileToo.bytes(for: .temporaryFiles), 0)
    }

    // MARK: - Cleanup

    func testClearingTemporaryFilesRemovesScratchAndKeepsExports() async {
        try? SettingsFixtures.write(Data(repeating: 0x41, count: 4_096), to: locations.temporary.appendingPathComponent("zynsign-staging-1"))
        try? SettingsFixtures.write(Data(repeating: 0x42, count: 4_096), to: locations.export.appendingPathComponent("ZynSign-Report.json"))
        try? SettingsFixtures.write(Data(repeating: 0x43, count: 4_096), to: locations.temporary.appendingPathComponent("AnotherApp-scratch"))

        let outcome = await service.clearTemporaryFiles()

        XCTAssertTrue(outcome.removedAnything)
        XCTAssertGreaterThan(outcome.reclaimedBytes, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: locations.export.appendingPathComponent("ZynSign-Report.json").path),
            "An exported report is something the user asked for, not scratch."
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: locations.temporary.appendingPathComponent("AnotherApp-scratch").path),
            "Another application's file is never removed."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: locations.temporary.appendingPathComponent("zynsign-staging-1").path)
        )
    }

    func testClearingAnAlreadyEmptyTemporaryDirectoryRemovesNothing() async {
        let outcome = await service.clearTemporaryFiles()

        XCTAssertFalse(outcome.removedAnything)
        XCTAssertEqual(outcome.removedItemCount, 0)
        XCTAssertEqual(outcome.reclaimedBytes, 0)
        XCTAssertFalse(outcome.message.isEmpty)
    }

    func testClearingCacheRemovesOnlyZynSignsCachedData() async {
        try? SettingsFixtures.write(Data(repeating: 0x41, count: 4_096), to: locations.caches.appendingPathComponent("ZynSignAppIcons/icon.png"))
        try? SettingsFixtures.write(Data(repeating: 0x42, count: 4_096), to: locations.caches.appendingPathComponent("AnotherApp-cache"))

        let outcome = await service.clearCache()

        XCTAssertTrue(outcome.removedAnything)
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.caches.appendingPathComponent("ZynSignAppIcons/icon.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations.caches.appendingPathComponent("AnotherApp-cache").path))
    }

    func testRemovingOldExportsLeavesNewSignaturesAlone() async {
        let old = locations.signedArtifacts.appendingPathComponent("Old-signed.ipa")
        let recent = locations.signedArtifacts.appendingPathComponent("Recent-signed.ipa")
        try? SettingsFixtures.write(Data(repeating: 0x41, count: 4_096), to: old)
        try? SettingsFixtures.write(Data(repeating: 0x42, count: 4_096), to: recent)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-20 * 86_400)],
            ofItemAtPath: old.path
        )

        let outcome = await service.removeExports(olderThanDays: 30)

        XCTAssertFalse(outcome.removedAnything)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    func testRemovingExportsOlderThanTheWindowTakesOnlyThose() async {
        let old = locations.signedArtifacts.appendingPathComponent("Old-signed.ipa")
        let recent = locations.signedArtifacts.appendingPathComponent("Recent-signed.ipa")
        try? SettingsFixtures.write(Data(repeating: 0x41, count: 4_096), to: old)
        try? SettingsFixtures.write(Data(repeating: 0x42, count: 4_096), to: recent)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-20 * 86_400)],
            ofItemAtPath: old.path
        )

        let outcome = await service.removeExports(olderThanDays: 7)

        XCTAssertEqual(outcome.removedItemCount, 1)
        XCTAssertGreaterThan(outcome.reclaimedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    func testRemovingOneStoredFileTakesOnlyThatFile() async {
        let removed = locations.signedArtifacts.appendingPathComponent("One-signed.ipa")
        let kept = locations.signedArtifacts.appendingPathComponent("Two-signed.ipa")
        try? SettingsFixtures.write(Data(repeating: 0x41, count: 4_096), to: removed)
        try? SettingsFixtures.write(Data(repeating: 0x42, count: 4_096), to: kept)

        let outcome = await service.removeFile(at: removed)

        XCTAssertTrue(outcome)
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
    }

    func testRemovingAFileThatIsNotThereSaysSo() async {
        XCTAssertFalse(await service.removeFile(at: root.appendingPathComponent("missing.ipa")))
    }

    func testClearingTemporaryFilesReportsWhatItRemovedWithoutNamingAnything() async {
        try? SettingsFixtures.write(Data(repeating: 0x41, count: 4_096), to: locations.temporary.appendingPathComponent("zynsign-staging-1"))

        let outcome = await service.clearTemporaryFiles()

        XCTAssertTrue(outcome.message.contains("Removed 1"))
        XCTAssertFalse(outcome.message.contains("zynsign-staging-1"), "A message names no file.")
        XCTAssertFalse(outcome.message.contains(root.path), "A message names no path.")
    }

    // MARK: - Large files

    func testTheLargestFilesComeFirst() async {
        let small = locations.signedArtifacts.appendingPathComponent("Small-signed.ipa")
        let large = locations.signedArtifacts.appendingPathComponent("Large-signed.ipa")
        try? SettingsFixtures.write(Data(repeating: 0x41, count: 4_096), to: small)
        try? SettingsFixtures.write(Data(repeating: 0x42, count: 655_360), to: large)

        let files = await service.largestFiles(limit: 20)

        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files.first?.url, large)
        XCTAssertGreaterThan(files[0].byteCount, files[1].byteCount)
        XCTAssertEqual(files.first?.category, .signedArtifacts)
        XCTAssertEqual(files.first?.name, "Large-signed.ipa")
        XCTAssertFalse(files.first!.formattedByteCount.isEmpty)
        XCTAssertFalse(files.first!.formattedDate.isEmpty)
    }

    func testTheLargeFileListRespectsItsLimit() async {
        for index in 0..<5 {
            try? SettingsFixtures.write(
                Data(repeating: 0x41, count: 4_096),
                to: locations.signedArtifacts.appendingPathComponent("Signed-\(index).ipa")
            )
        }

        let files = await service.largestFiles(limit: 2)

        XCTAssertEqual(files.count, 2)
    }

    func testForeignFilesInASharedDirectoryAreNotOfferedForReview() async {
        try? SettingsFixtures.write(Data(repeating: 0x41, count: 4_096), to: locations.temporary.appendingPathComponent("AnotherApp-scratch"))

        let files = await service.largestFiles(limit: 20)

        XCTAssertTrue(files.isEmpty)
    }

    // MARK: - Helpers
}
