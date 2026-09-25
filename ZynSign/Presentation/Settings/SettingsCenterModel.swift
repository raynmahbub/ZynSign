import SwiftUI

/// The model behind the Settings Control Center.
///
/// One model owns every preference in the application, so the sections never
/// disagree and a change is written exactly once:
///
/// - **Read once, kept in memory.** The preferences are loaded from the store
///   when the model is created, so a section renders from a value rather than
///   a file read. Nothing recomputes while the user browses.
/// - **Write whole, publish once.** A change is applied to a copy, written
///   through the store, and only then published. A failed write leaves the
///   published value at the last state that was actually saved, and says so —
///   the interface never shows a preference the disk does not hold.
/// - **Side effects in one place.** Haptics, the technical log, and the
///   storage and library actions all go through here, so a section is a view
///   over this model and nothing else.
@MainActor
final class SettingsCenterModel: ObservableObject {

    /// The preferences as currently saved.
    @Published private(set) var preferences: ZynSignPreferences

    /// Whether the storage measurement is running.
    @Published private(set) var isMeasuringStorage = false

    /// The most recent storage measurement.
    @Published private(set) var storageFootprint: StorageFootprint?

    /// Whether a maintenance action is running.
    @Published private(set) var isPerformingMaintenance = false

    /// What the last maintenance action did, in one sentence.
    @Published private(set) var maintenanceMessage: String?

    /// Why the last change could not be saved, if it could not.
    @Published private(set) var lastSaveErrorMessage: String?

    /// The store the preferences are written through.
    let store: any PreferencesStore

    /// The application dependencies maintenance actions act on.
    let environment: ApplicationEnvironment

    /// Measures what ZynSign holds, and runs the cleanups the storage screen
    /// may offer. It is the application's own storage use case, and it can
    /// never reach an imported application: no code path in it can.
    var storage: StorageManagement { environment.storageManagement }

    /// The opt-in technical log.
    let diagnosticLog: DiagnosticLog

    init(
        store: any PreferencesStore,
        environment: ApplicationEnvironment,
        diagnosticLog: DiagnosticLog? = nil
    ) {
        self.store = store
        self.environment = environment
        self.preferences = store.snapshot
        self.diagnosticLog = diagnosticLog
            ?? DiagnosticLog(location: CompositionRoot.diagnosticsLogLocation())
        syncSideEffects(from: store.snapshot)
    }

    /// Whether this construction migrated values an earlier version kept in
    /// `UserDefaults`.
    var didMigrateLegacyValues: Bool { store.didMigrateLegacyValues }

    // MARK: - Preferences

    /// A binding onto one preference.
    ///
    /// Reading the binding reads the saved value; writing it goes through
    /// `update(_:)`, so there is one path from the interface to the disk.
    func binding<Value>(_ keyPath: WritableKeyPath<ZynSignPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { self.preferences[keyPath: keyPath] },
            set: { newValue in self.update { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// Applies a change, saves it, and publishes it.
    ///
    /// An unchanged value is not written, so a section that re-renders does
    /// not touch the disk.
    func update(_ mutation: (inout ZynSignPreferences) -> Void) {
        var updated = preferences
        mutation(&updated)
        guard updated != preferences else { return }
        do {
            try store.save(updated)
            preferences = updated
            lastSaveErrorMessage = nil
            syncSideEffects(from: updated)
            recordDiagnostic(category: .preferences, detail: "preferences.updated")
        } catch {
            lastSaveErrorMessage = (error as? ZynSignError)?.userMessage
                ?? "ZynSign could not save that change."
        }
    }

    /// Restores every preference to its shipped default, leaving the record
    /// of finished onboarding alone — resetting preferences is not a reason to
    /// walk a user back through the welcome card.
    func resetPreferences() {
        update { preferences in
            preferences.resetToShippedDefaults(preservingOnboardingCompletion: true)
        }
        recordDiagnostic(category: .preferences, detail: "preferences.reset")
    }

    /// Shows first-launch onboarding again.
    func resetOnboarding() {
        update { $0.general.onboardingCompleted = false }
        recordDiagnostic(category: .preferences, detail: "preferences.onboarding.reset")
    }

    /// Keeps the process-wide consequences of the preferences in step with the
    /// preferences themselves.
    private func syncSideEffects(from preferences: ZynSignPreferences) {
        ZHaptics.isEnabled = preferences.general.hapticFeedbackEnabled
    }

    // MARK: - Storage

    /// Measures what ZynSign holds.
    ///
    /// The measurement is the application's own footprint: read from the
    /// storage that holds the bytes, never estimated, so a reported number can
    /// always be traced back to a location.
    func refreshStorageUsage() async {
        isMeasuringStorage = true
        defer { isMeasuringStorage = false }
        storageFootprint = try? await storage.footprint()
    }

    /// Removes the working copies and staging files finished or interrupted
    /// operations left behind.
    ///
    /// Only entries older than the retention interval are removed, and only
    /// entries whose names ZynSign recognises as its own work, so cleanup can
    /// never race an operation in flight and never touches another
    /// application's files.
    func clearTemporaryFiles() async {
        await performMaintenance(.storage, detail: "storage.temporary.cleared") {
            try await self.storage.cleanup(.temporaryFiles).summary
        }
    }

    /// Removes the exported artifacts ZynSign produced, together with the
    /// records that describe them. The applications they were signed from are
    /// not touched — that is what the Export Center owns, and it is why this
    /// action cannot reach the library.
    func removeOldExports() async {
        await performMaintenance(.storage, detail: "storage.exports.pruned") {
            try await self.storage.cleanup(.exportedArtifacts).summary
        }
    }

    /// Removes signing-history records older than the retention interval,
    /// keeping the most recent records whatever their age.
    func removeOldHistoryRecords() async {
        await performMaintenance(.storage, detail: "storage.history.pruned") {
            try await self.storage.cleanup(.oldHistoryRecords).summary
        }
    }

    /// Re-reads the library and clears artifacts no record refers to.
    ///
    /// This is the safe recovery action: it removes nothing a record points
    /// at, so no imported application is lost by running it.
    func rebuildLibraryIndex() async {
        await performMaintenance(.recovery, detail: "library.index.rebuilt") {
            let entries = (try? await self.environment.library.entries()) ?? []
            let orphans = (try? await self.environment.library.removeOrphanedArtifacts()) ?? []
            return "Checked \(entries.count) record\(entries.count == 1 ? "" : "s") and removed \(orphans.count) orphaned artifact\(orphans.count == 1 ? "" : "s")."
        }
        await refreshStorageUsage()
    }

    /// Removes every record and every package file in the library.
    ///
    /// This is the one destructive reset in the application, and it is only
    /// reachable from Settings → Recovery behind a confirmation and, when the
    /// user asked for it, authentication. Orphaned artifacts are removed as
    /// well, so nothing is left behind that no record refers to.
    func resetLibrary() async {
        await performMaintenance(.recovery, detail: "library.reset") {
            let entries = (try? await self.environment.library.entries()) ?? []
            for entry in entries {
                try? await self.environment.library.remove(recordWithID: entry.record.id)
            }
            let orphans = (try? await self.environment.library.removeOrphanedArtifacts()) ?? []
            return "Removed \(entries.count) record\(entries.count == 1 ? "" : "s") and \(orphans.count) orphaned artifact\(orphans.count == 1 ? "" : "s")."
        }
        await refreshStorageUsage()
    }

    /// Removes ZynSign's scratch files, honouring the cleanup policy.
    ///
    /// Called at launch when the policy says ZynSign may tidy without being
    /// asked; never called otherwise.
    func cleanTemporaryWorkspaceIfPolicyAllows() async {
        guard preferences.storage.automaticTemporaryCleanup else { return }
        switch preferences.advanced.temporaryCleanupPolicy {
        case .onLaunch:
            _ = try? await storage.cleanup(.temporaryFiles)
            recordDiagnostic(category: .storage, detail: "storage.temporary.cleared.onLaunch")
        case .onExit, .manual:
            break
        }
    }

    // MARK: - Diagnostics

    /// Records one technical log entry when the user has opted in.
    ///
    /// The preference is checked here, at the single call site every section
    /// goes through, so a section cannot record anything the user has not
    /// asked for.
    func recordDiagnostic(category: DiagnosticLogEntry.Category, detail: String) {
        guard preferences.diagnostics.detailedTechnicalLogs,
              preferences.diagnostics.keepDiagnosticHistory else { return }
        Task { await diagnosticLog.record(category: category, detail: detail) }
    }

    /// The technical log's entries, oldest first.
    func diagnosticEntries() async -> [DiagnosticLogEntry] {
        await diagnosticLog.entries()
    }

    /// How many entries the technical log holds.
    func diagnosticEntryCount() async -> Int {
        await diagnosticLog.entryCount
    }

    /// Removes every technical log entry.
    ///
    /// Nothing is written afterwards: an entry recording that the log was
    /// cleared is exactly the entry the user asked to be rid of.
    func clearDiagnosticLog() async {
        await diagnosticLog.clear()
    }

    /// Builds and writes a diagnostic report the user can share.
    @discardableResult
    func exportDiagnosticReport() async -> URL? {
        let report = await makeDiagnosticReport()
        guard let data = report.jsonData() else {
            maintenanceMessage = "The diagnostic report could not be created."
            return nil
        }
        let directory = CompositionRoot.diagnosticReportDirectory()
        let url = directory.appendingPathComponent("zynsign-diagnostic-report.json", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            maintenanceMessage = "The diagnostic report could not be written."
            return nil
        }
        recordDiagnostic(category: .maintenance, detail: "diagnostics.report.exported")
        return url
    }

    /// Assembles the report from counts and facts, never from contents.
    private func makeDiagnosticReport() async -> DiagnosticReport {
        let measured = storageFootprint
            ?? (try? await storage.footprint())
            ?? StorageFootprint.empty
        return DiagnosticReport.make(
            applicationInfo: environment.applicationInfo,
            releaseSummary: "ZynSign \(environment.applicationInfo.marketingVersion) (\(environment.applicationInfo.buildVersion))",
            storage: measured,
            library: await libraryCounts(),
            preferences: preferences,
            technicalLog: await diagnosticLog.entries(),
            generatedAt: Date()
        )
    }

    /// Counts, not contents: the report says how many of each thing exists.
    private func libraryCounts() async -> DiagnosticLibraryCounts {
        var counts = DiagnosticLibraryCounts.empty
        if let entries = try? await environment.library.entries() {
            counts.recordCount = entries.count
            counts.availableArtifactCount = entries.filter(\.isArtifactAvailable).count
        }
        counts.identityCount = (try? environment.identityStore.listIdentities().count) ?? 0
        counts.profileCount = (try? await environment.provisioningProfiles?.count()) ?? 0
        counts.presetCount = (try? await environment.signingPresets?.count()) ?? 0
        counts.historyCount = (try? await environment.signingHistory?.count()) ?? 0
        return counts
    }

    // MARK: - Maintenance

    /// Runs one maintenance action, reporting its outcome.
    ///
    /// A cleanup that could not be carried out is reported as a sentence the
    /// user can act on, never as a silent success: the interface says what
    /// happened or says that it could not find out.
    private func performMaintenance(
        _ category: DiagnosticLogEntry.Category,
        detail: String,
        operation: @escaping @MainActor () async throws -> String
    ) async {
        isPerformingMaintenance = true
        defer { isPerformingMaintenance = false }
        do {
            maintenanceMessage = try await operation()
            recordDiagnostic(category: category, detail: detail)
        } catch {
            maintenanceMessage = (error as? ZynSignError)?.userMessage
                ?? "That action could not be completed."
        }
        await refreshStorageUsage()
    }
}

// MARK: - SwiftUI integration

private struct SettingsCenterKey: EnvironmentKey {
    /// A standalone model, so a section rendered outside the shell — a
    /// preview, or a test — still has something to read. The shell installs
    /// the shared instance, which is the one the user's changes reach.
    static let defaultValue = SettingsCenterModel(
        store: FilePreferencesStore(location: CompositionRoot.preferencesDocumentLocation()),
        environment: CompositionRoot.makeApplicationEnvironment()
    )
}

extension EnvironmentValues {
    /// The Settings Control Center's model.
    var settingsCenter: SettingsCenterModel {
        get { self[SettingsCenterKey.self] }
        set { self[SettingsCenterKey.self] = newValue }
    }
}

private struct AppLockKey: EnvironmentKey {
    /// A standalone controller, so a view rendered outside the shell — a
    /// preview, or a section presented on its own — still has one to read. The
    /// shell installs the shared instance, which is the one the user's lock
    /// state lives in.
    static let defaultValue = AppLockController(
        authenticator: LocalAuthenticationBiometricAuthenticator(),
        preferences: {
            ZynSignPreferences.shippedDefault
        }
    )
}

extension EnvironmentValues {
    /// ZynSign's lock: whether the application is locked, and what asking to
    /// unlock it will do.
    var appLock: AppLockController {
        get { self[AppLockKey.self] }
        set { self[AppLockKey.self] = newValue }
    }
}
