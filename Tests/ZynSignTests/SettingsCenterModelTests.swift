import XCTest
@testable import ZynSign

/// The Settings Control Center's model: one path from the interface to the
/// disk, and maintenance actions that only do what they are asked.
@MainActor
final class SettingsCenterModelTests: XCTestCase {

    private var root: URL!
    private var model: SettingsCenterModel!
    private var locations: StorageLocations!

    override func setUp() async throws {
        try await super.setUp()
        root = try SettingsFixtures.makeTemporaryDirectory()
        locations = SettingsFixtures.makeStorageLocations(root: root)
        model = SettingsFixtures.makeSettingsModel(root: root)
    }

    override func tearDown() async throws {
        model = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        locations = nil
        try await super.tearDown()
    }

    // MARK: - Preferences

    func testPreferencesAreLoadedFromTheStoreWhenTheModelIsBuilt() throws {
        var stored = ZynSignPreferences.shippedDefault
        stored.general.landingTab = .certificates
        try SettingsFixtures.makePreferencesStore(root: root).save(stored)

        let rebuilt = SettingsFixtures.makeSettingsModel(root: root)

        XCTAssertEqual(rebuilt.preferences.general.landingTab, .certificates)
    }

    func testAChangeIsWrittenThroughTheStore() throws {
        model.update { $0.general.landingTab = .profiles }

        XCTAssertEqual(model.preferences.general.landingTab, .profiles)
        XCTAssertEqual(
            try SettingsFixtures.makePreferencesStore(root: root).snapshot.general.landingTab,
            .profiles
        )
        XCTAssertNil(model.lastSaveErrorMessage)
    }

    func testAnUnchangedPreferenceNeverTouchesTheDisk() {
        let store = RecordingPreferencesStore(
            store: SettingsFixtures.makePreferencesStore(root: root)
        )
        let model = SettingsCenterModel(
            store: store,
            environment: SettingsFixtures.makeEnvironment(root: root, preferences: SettingsFixtures.makePreferencesStore(root: root)),
            storage: SettingsFixtures.makeStorageService(root: root),
            diagnosticLog: SettingsFixtures.makeDiagnosticLog(root: root)
        )
        XCTAssertEqual(store.saveCount, 0)

        model.update { $0.general.landingTab = .home }

        XCTAssertEqual(store.saveCount, 0, "A section re-rendering must not write.")
    }

    func testAChangeThatCannotBeSavedIsReportedAndNotShown() {
        let failing = FailingPreferencesStore()
        let model = SettingsCenterModel(
            store: failing,
            environment: SettingsFixtures.makeEnvironment(root: root, preferences: SettingsFixtures.makePreferencesStore(root: root)),
            storage: SettingsFixtures.makeStorageService(root: root),
            diagnosticLog: SettingsFixtures.makeDiagnosticLog(root: root)
        )

        model.update { $0.general.landingTab = .settings }

        XCTAssertEqual(model.preferences.general.landingTab, .home)
        XCTAssertNotNil(model.lastSaveErrorMessage)
        XCTAssertFalse(model.lastSaveErrorMessage!.isEmpty)
    }

    func testABindingWritesThroughTheSamePath() {
        let binding = model.binding(\.general.hapticFeedbackEnabled)

        binding.wrappedValue = false

        XCTAssertFalse(model.preferences.general.hapticFeedbackEnabled)
        XCTAssertFalse(
            SettingsFixtures.makePreferencesStore(root: root).snapshot.general.hapticFeedbackEnabled
        )
    }

    func testResettingPreferencesRestoresEverySettingAndKeepsOnboarding() {
        model.update { $0.general.onboardingCompleted = true }
        model.update { $0.security.sessionTimeout = .immediately }
        model.update { $0.appearance.appearanceMode = .dark }

        model.resetPreferences()

        XCTAssertEqual(model.preferences.security, SecurityPreferences())
        XCTAssertEqual(model.preferences.appearance, AppearancePreferences())
        XCTAssertTrue(model.preferences.general.onboardingCompleted)
    }

    func testResettingOnboardingShowsTheWelcomeCardAgain() {
        model.update { $0.general.onboardingCompleted = true }

        model.resetOnboarding()

        XCTAssertFalse(model.preferences.general.onboardingCompleted)
        XCTAssertFalse(
            SettingsFixtures.makePreferencesStore(root: root).snapshot.general.onboardingCompleted
        )
    }

    // MARK: - Storage

    func testStorageIsMeasuredWhenAsked() async {
        try? SettingsFixtures.write(
            Data(repeating: 0x41, count: 4_096),
            to: locations.signedArtifacts.appendingPathComponent("Signed.ipa")
        )

        await model.refreshStorageUsage()

        XCTAssertNotNil(model.storageReport)
        XCTAssertGreaterThan(model.storageReport!.bytes(for: .signedArtifacts), 0)
        XCTAssertEqual(model.storageReport!.total, model.storageReport!.usage.values.reduce(0, +))
    }

    func testTheLargestFilesAreListedForReview() async {
        try? SettingsFixtures.write(
            Data(repeating: 0x41, count: 4_096),
            to: locations.signedArtifacts.appendingPathComponent("Small.ipa")
        )
        try? SettingsFixtures.write(
            Data(repeating: 0x42, count: 655_360),
            to: locations.signedArtifacts.appendingPathComponent("Large.ipa")
        )

        await model.refreshLargestFiles()

        XCTAssertEqual(model.largestFiles.first?.name, "Large.ipa")
    }

    func testRemovingAFileFromTheReviewListRemovesOnlyThatFile() async throws {
        let removed = locations.signedArtifacts.appendingPathComponent("One.ipa")
        let kept = locations.signedArtifacts.appendingPathComponent("Two.ipa")
        try SettingsFixtures.write(Data(repeating: 0x41, count: 4_096), to: removed)
        try SettingsFixtures.write(Data(repeating: 0x42, count: 4_096), to: kept)
        await model.refreshLargestFiles()
        let description = try XCTUnwrap(model.largestFiles.first { $0.url == removed })

        await model.removeStoredFile(description)

        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertFalse(model.largestFiles.contains { $0.url == removed })
    }

    func testClearingTemporaryFilesReportsWhatItRemoved() async {
        try? SettingsFixtures.write(
            Data(repeating: 0x41, count: 4_096),
            to: locations.temporary.appendingPathComponent("zynsign-staging-1")
        )

        await model.clearTemporaryFiles()

        // The sentence is built from the count and the reclaimed size, and
        // names neither the file nor where it was.
        XCTAssertTrue(
            model.maintenanceMessage?.hasPrefix("Removed 1 temporary file and reclaimed") == true,
            model.maintenanceMessage ?? "no message"
        )
    }

    func testClearingCacheReportsWhatItRemoved() async {
        try? SettingsFixtures.write(
            Data(repeating: 0x41, count: 4_096),
            to: locations.caches.appendingPathComponent("ZynSignAppIcons/icon.png")
        )

        await model.clearCache()

        XCTAssertTrue(model.maintenanceMessage?.hasPrefix("Removed 1 cached item and reclaimed") == true)
    }

    func testRemovingOldExportsHonoursTheRetentionPreference() async throws {
        let old = locations.signedArtifacts.appendingPathComponent("Old.ipa")
        let recent = locations.signedArtifacts.appendingPathComponent("Recent.ipa")
        try SettingsFixtures.write(Data(repeating: 0x41, count: 4_096), to: old)
        try SettingsFixtures.write(Data(repeating: 0x42, count: 4_096), to: recent)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-40 * 86_400)],
            ofItemAtPath: old.path
        )
        model.update { $0.storage.exportRetentionDays = 30 }

        await model.removeOldExports()

        XCTAssertTrue(model.maintenanceMessage?.hasPrefix("Removed 1 signed package and reclaimed") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    func testAMaintenanceActionWithNothingToDoSaysSo() async {
        await model.clearTemporaryFiles()

        XCTAssertEqual(model.maintenanceMessage, "Nothing to remove — no temporary files were left.")
    }

    func testRebuildingTheLibraryIndexRemovesNothingARecordRefersTo() async {
        await model.rebuildLibraryIndex()

        XCTAssertEqual(model.maintenanceMessage, "Checked 0 records and removed 0 orphaned artifacts.")
    }

    func testResettingTheLibraryIsTheDestructiveReset() async {
        await model.resetLibrary()

        XCTAssertEqual(model.maintenanceMessage, "Removed 0 records and 0 orphaned artifacts.")
    }

    func testTheWorkspaceIsOnlyTidiedAtLaunchWhenThePolicyAllowsIt() async {
        try? SettingsFixtures.write(
            Data(repeating: 0x41, count: 4_096),
            to: locations.temporary.appendingPathComponent("zynsign-staging-1")
        )

        // The shipped policy is "when ZynSign quits", so nothing is tidied at
        // launch.
        await model.cleanTemporaryWorkspaceIfPolicyAllows()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: locations.temporary.appendingPathComponent("zynsign-staging-1").path)
        )

        model.update { $0.advanced.temporaryCleanupPolicy = .onLaunch }
        await model.cleanTemporaryWorkspaceIfPolicyAllows()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: locations.temporary.appendingPathComponent("zynsign-staging-1").path)
        )
    }

    func testTheWorkspaceIsNeverTidiedWhenTheUserTurnedCleanupOff() async {
        try? SettingsFixtures.write(
            Data(repeating: 0x41, count: 4_096),
            to: locations.temporary.appendingPathComponent("zynsign-staging-1")
        )
        model.update { $0.storage.automaticTemporaryCleanup = false }
        model.update { $0.advanced.temporaryCleanupPolicy = .onLaunch }

        await model.cleanTemporaryWorkspaceIfPolicyAllows()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: locations.temporary.appendingPathComponent("zynsign-staging-1").path)
        )
    }

    // MARK: - Diagnostics

    func testTheTechnicalLogRecordsNothingWhileItIsOff() async {
        model.update { $0.general.landingTab = .profiles }

        await model.cleanTemporaryWorkspaceIfPolicyAllows()

        XCTAssertEqual(await model.diagnosticEntryCount(), 0)
    }

    func testTheTechnicalLogRecordsWhenTheUserTurnsItOn() async {
        model.update { $0.diagnostics.detailedTechnicalLogs = true }

        model.update { $0.general.landingTab = .profiles }

        let entries = await model.diagnosticEntries()
        // Turning the log on is itself the first entry it holds, because the
        // change it records is the change that makes recording possible.
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.detail, "preferences.updated")
        XCTAssertEqual(entries.first?.category, .preferences)
    }

    func testTheTechnicalLogRecordsNothingWhenHistoryIsNotKept() async {
        model.update { $0.diagnostics.detailedTechnicalLogs = true }
        model.update { $0.diagnostics.keepDiagnosticHistory = false }

        model.update { $0.general.landingTab = .profiles }

        XCTAssertEqual(await model.diagnosticEntryCount(), 0)
    }

    func testClearingTheTechnicalLogRemovesEveryEntry() async {
        model.update { $0.diagnostics.detailedTechnicalLogs = true }
        model.update { $0.general.landingTab = .profiles }

        await model.clearDiagnosticLog()

        XCTAssertEqual(await model.diagnosticEntryCount(), 0)
    }

    func testTheDiagnosticReportCarriesNoSensitiveValue() async throws {
        model.update { $0.diagnostics.detailedTechnicalLogs = true }
        model.update { $0.security.biometricLockEnabled = true }
        model.update { $0.signing.preferredIdentityFingerprint = "AABBCCDDEEFF0011" }
        model.update { $0.general.landingTab = .profiles }

        let report = await DiagnosticReport.make(
            applicationInfo: ApplicationInfo(
                displayName: "ZynSign",
                marketingVersion: "0.1.0",
                buildVersion: "42"
            ),
            releaseSummary: "ZynSign 0.1.0 (42)",
            storage: StorageUsageReport(usage: [:], measuredAt: Date()),
            library: DiagnosticLibraryCounts(),
            preferences: model.preferences,
            technicalLog: await model.diagnosticEntries(),
            generatedAt: Date()
        )
        let text = try XCTUnwrap(report.jsonData().flatMap { String(data: $0, encoding: .utf8) })

        XCTAssertFalse(text.contains("AABBCCDDEEFF0011"), "A fingerprint is never exported.")
        XCTAssertFalse(text.contains(root.path), "A path is never exported.")
        XCTAssertTrue(text.contains("changedGroupCount"))
        XCTAssertTrue(text.contains("ZynSign"))
    }

    func testExportingADiagnosticReportWritesAFileTheUserCanShare() async throws {
        let url = await model.exportDiagnosticReport()
        defer { if let url { try? FileManager.default.removeItem(at: url) } }

        let written = try XCTUnwrap(url)
        XCTAssertEqual(written.lastPathComponent, "zynsign-diagnostic-report.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
        let data = try Data(contentsOf: written)
        XCTAssertFalse(data.isEmpty)
    }
}
