import XCTest
@testable import ZynSign

/// The Settings Control Center's model: one path from the interface to the
/// disk, and maintenance actions that only do what they are asked.
@MainActor
final class SettingsCenterModelTests: XCTestCase {

    private var root: URL!
    private var model: SettingsCenterModel!
    private var layout: StorageLayout!

    override func setUp() async throws {
        try await super.setUp()
        root = try SettingsFixtures.makeTemporaryDirectory()
        layout = SettingsFixtures.makeStorageLayout(root: root)
        model = SettingsFixtures.makeSettingsModel(root: root)
    }

    override func tearDown() async throws {
        model = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        layout = nil
        try await super.tearDown()
    }

    /// The technical log receives entries from a queued write, so an
    /// observation that wants the log's real state waits for the queued
    /// write to land instead of racing it.
    private func diagnosticEntries(afterEntryCount expected: Int) async -> [DiagnosticLogEntry] {
        for _ in 0..<200 {
            let current = await model.diagnosticEntries()
            if current.count >= expected { return current }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await model.diagnosticEntries()
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

    func testStorageIsMeasuredWhenAsked() async throws {
        try SettingsFixtures.write(
            Data(repeating: 0x41, count: 4_096),
            to: layout.exportedArtifacts.appendingPathComponent("Signed.ipa")
        )

        await model.refreshStorageUsage()

        let footprint = try XCTUnwrap(model.storageFootprint)
        XCTAssertGreaterThan(footprint.usage(of: .exportedArtifacts).byteCount, 0)
        XCTAssertEqual(
            footprint.totalByteCount,
            footprint.usages.reduce(0) { $0 + $1.byteCount },
            "The total is the sum of the rows."
        )
    }

    func testEveryCategoryIsReportedEvenWhenItIsEmpty() async {
        await model.refreshStorageUsage()

        let footprint = try? XCTUnwrap(model.storageFootprint)
        for category in StorageCategory.allCases {
            XCTAssertNotNil(footprint?.usage(of: category), "\(category.displayName) is always reported.")
        }
    }

    func testClearingTemporaryFilesReportsWhatItRemoved() async throws {
        try SettingsFixtures.write(
            Data(repeating: 0x41, count: 4_096),
            to: layout.temporary[0].appendingPathComponent("zynsign-staging-1")
        )
        // The cleanup is age-based: a file from this instant may belong to an
        // operation running right now, so it is counted as skipped rather than
        // removed. Either way the screen is told what happened.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-2 * 3_600)],
            ofItemAtPath: layout.temporary[0].appendingPathComponent("zynsign-staging-1").path
        )

        await model.clearTemporaryFiles()

        XCTAssertTrue(
            model.maintenanceMessage?.hasPrefix("Removed 1 temporary file") == true,
            model.maintenanceMessage ?? "no message"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.temporary[0].appendingPathComponent("zynsign-staging-1").path
        ))
    }

    func testAMaintenanceActionWithNothingToDoSaysSo() async {
        await model.clearTemporaryFiles()

        XCTAssertEqual(model.maintenanceMessage, "Nothing needed to be removed.")
    }

    func testRemovingSignedArtifactsRemovesTheArtifactsAndKeepsTheImports() async throws {
        let export = layout.exportedArtifacts.appendingPathComponent("Signed.ipa")
        let imported = layout.importedApplications.appendingPathComponent("Imported.ipa")
        try SettingsFixtures.write(Data(repeating: 0x41, count: 4_096), to: export)
        try SettingsFixtures.write(Data(repeating: 0x42, count: 4_096), to: imported)
        try await SettingsFixtures.makeExportRecordStore(root: root)
            .write(SettingsFixtures.makeExportRecord(fileName: "Signed.ipa", byteCount: 4_096))

        await model.removeOldExports()

        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: imported.path),
            "Imported applications are the library and are never removed here."
        )
    }

    func testRemovingOldHistoryRecordsKeepsTheMostRecentRecords() async throws {
        // The policy always keeps the most recent records whatever their age,
        // so the journal has to hold more than that minimum before an old
        // record becomes a candidate at all.
        let store = FileSigningHistoryStore(journalLocation: layout.history, capacity: 100)
        let oldestNames = (0..<5).map { "Old \($0)" }
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
        let recent = SigningRecord(
            presetID: nil,
            certificateFingerprint: nil,
            sourceBundleIdentifier: "com.zynsign.test",
            sourceDisplayName: "Recent",
            stoppingStage: nil,
            errorCode: nil,
            outputFileName: "Recent.ipa",
            outputByteCount: nil,
            startedAt: Date(),
            duration: 1,
            result: .succeeded
        )
        try await store.append(recent)

        await model.removeOldHistoryRecords()

        // A fresh reader observes the journal as cleanup left it on disk;
        // this test's own store still holds the cache it built while appending.
        let remaining = (try? await FileSigningHistoryStore(journalLocation: layout.history, capacity: 100).allRecords()) ?? []
        XCTAssertEqual(remaining.count, StorageCleanupPolicy.minimumRetainedHistoryRecords)
        XCTAssertEqual(remaining.first?.id, recent.id, "The most recent record is always kept.")
        for name in oldestNames {
            XCTAssertFalse(
                remaining.contains { $0.sourceDisplayName == name },
                "\(name) is older than the retention interval and is not one of the minimum kept."
            )
        }
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
            to: layout.temporary[0].appendingPathComponent("zynsign-staging-1")
        )

        // The shipped policy is "when ZynSign quits", so nothing is tidied at
        // launch.
        await model.cleanTemporaryWorkspaceIfPolicyAllows()
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: layout.temporary[0].appendingPathComponent("zynsign-staging-1").path
            )
        )

        // The cleanup itself is age-gated (an hour) so it can never race an
        // operation still writing into the workspace; backdate the fixture so
        // the now-allowed cleanup may actually remove it.
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7_200)],
            ofItemAtPath: layout.temporary[0].appendingPathComponent("zynsign-staging-1").path
        )

        model.update { $0.advanced.temporaryCleanupPolicy = .onLaunch }
        await model.cleanTemporaryWorkspaceIfPolicyAllows()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: layout.temporary[0].appendingPathComponent("zynsign-staging-1").path)
        )
    }

    func testTheWorkspaceIsNeverTidiedWhenTheUserTurnedCleanupOff() async {
        try? SettingsFixtures.write(
            Data(repeating: 0x41, count: 4_096),
            to: layout.temporary[0].appendingPathComponent("zynsign-staging-1")
        )
        model.update { $0.storage.automaticTemporaryCleanup = false }
        model.update { $0.advanced.temporaryCleanupPolicy = .onLaunch }

        await model.cleanTemporaryWorkspaceIfPolicyAllows()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: layout.temporary[0].appendingPathComponent("zynsign-staging-1").path)
        )
    }

    // MARK: - Diagnostics

    func testTheTechnicalLogRecordsNothingWhileItIsOff() async {
        model.update { $0.general.landingTab = .profiles }

        await model.cleanTemporaryWorkspaceIfPolicyAllows()

        let entryCount = await model.diagnosticEntryCount()
        XCTAssertEqual(entryCount, 0)
    }

    func testTheTechnicalLogRecordsWhenTheUserTurnsItOn() async {
        model.update { $0.diagnostics.detailedTechnicalLogs = true }

        model.update { $0.general.landingTab = .profiles }

        let entries = await diagnosticEntries(afterEntryCount: 2)
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

        let entryCount = await model.diagnosticEntryCount()
        XCTAssertEqual(entryCount, 0)
    }

    func testClearingTheTechnicalLogRemovesEveryEntry() async {
        model.update { $0.diagnostics.detailedTechnicalLogs = true }
        model.update { $0.general.landingTab = .profiles }

        // Let every queued write land first; clearing while one is still in
        // flight would leave the cleared log holding it again.
        _ = await diagnosticEntries(afterEntryCount: 2)
        await model.clearDiagnosticLog()

        let entryCount = await model.diagnosticEntryCount()
        XCTAssertEqual(entryCount, 0)
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
            storage: StorageFootprint(usages: []),
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
