import Foundation
@testable import ZynSign

/// Fixtures the Settings, Security, and Storage tests share.
///
/// The settings tests exercise real behaviour — a real preferences document,
/// a real storage walk, a real library — over synthetic locations, so what
/// they assert is what the application does rather than what a double lets it
/// do. Every location is inside a temporary directory that the test owns and
/// removes afterwards.
enum SettingsFixtures {

    /// A fresh, empty directory inside the system temporary directory.
    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZynSignSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes `data` to `url`, creating any missing directories.
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    /// The location of the preferences document inside `root`.
    static func preferencesLocation(root: URL) -> URL {
        root.appendingPathComponent("Preferences.json", isDirectory: false)
    }

    /// A preferences store over a document inside `root`, with legacy
    /// `UserDefaults` migration disabled — tests construct the legacy state
    /// explicitly rather than through the shared defaults.
    static func makePreferencesStore(root: URL) -> FilePreferencesStore {
        FilePreferencesStore(location: preferencesLocation(root: root), legacyDefaults: nil)
    }

    /// The storage layout inside `root`, mirroring the real one: the four
    /// categories the storage screen reports on, each in its own place.
    static func makeStorageLayout(root: URL) -> StorageLayout {
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let temporary = root.appendingPathComponent("Temporary", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        return StorageLayout(
            importedApplications: library.appendingPathComponent("Artifacts", isDirectory: true),
            exportedArtifacts: documents.appendingPathComponent("Signed", isDirectory: true),
            temporary: [temporary],
            history: library.appendingPathComponent("SigningHistory.json", isDirectory: false),
            exportCatalog: library.appendingPathComponent("ExportCatalog.json", isDirectory: false),
            diagnosticsLog: library.appendingPathComponent("Diagnostics.json", isDirectory: false)
        )
    }

    /// The storage use case over the synthetic locations inside `root`,
    /// measured from real files: what a footprint reports is what the
    /// application would report.
    static func makeStorageManagement(root: URL) -> StorageManagement {
        let layout = makeStorageLayout(root: root)
        return StorageManagement(
            reporting: FileStorageFootprint(
                importedApplicationsDirectory: layout.importedApplications,
                exportedArtifactsDirectory: layout.exportedArtifacts,
                temporaryDirectories: layout.temporary,
                historyFiles: [layout.history]
            ),
            temporaryData: FileTemporaryStorage(directories: layout.temporary),
            exports: ExportCenter(
                records: FileExportRecordStore(catalogLocation: layout.exportCatalog),
                artifacts: FileExportArtifactStore(exportsDirectory: layout.exportedArtifacts)
            ),
            history: FileSigningHistoryStore(
                journalLocation: layout.history,
                capacity: 20
            )
        )
    }

    /// The export catalog inside `root`, for a test that needs to record an
    /// export before storage can be asked to remove it.
    static func makeExportRecordStore(root: URL) -> FileExportRecordStore {
        FileExportRecordStore(catalogLocation: makeStorageLayout(root: root).exportCatalog)
    }

    /// An export record for a file already sitting in export storage.
    static func makeExportRecord(fileName: String, byteCount: Int, createdAt: Date = Date()) -> ExportRecord {
        ExportRecord(
            sourceRecordIdentifier: nil,
            sourceArtifactIdentifier: nil,
            applicationName: "Test Application",
            bundleIdentifier: "com.zynsign.test",
            shortVersion: "1.0",
            buildVersion: "1",
            fileName: fileName,
            byteCount: byteCount,
            fingerprint: nil,
            createdAt: createdAt
        )
    }

    /// A technical log inside `root`.
    static func makeDiagnosticLog(root: URL) -> DiagnosticLog {
        DiagnosticLog(
            location: makeStorageLayout(root: root).diagnosticsLog,
            maximumBytes: 64 * 1024
        )
    }

    /// An application environment over synthetic stores inside `root`.
    ///
    /// Arguments follow `ApplicationEnvironment`'s declaration order, which
    /// its memberwise initializer requires. The signing engine and the
    /// signing operation runner come from the composition root's own
    /// factories over the same pipeline; nothing here signs anything.
    @MainActor
    static func makeEnvironment(root: URL, preferences: FilePreferencesStore) -> ApplicationEnvironment {
        let records = InMemoryApplicationRecordStore()
        let artifacts = SyntheticLibraryArtifactStore()
        let library = ApplicationLibrary(records: records, artifacts: artifacts)
        let intake = SyntheticIntake()
        intake.artifactStore = artifacts
        let readerProvider = SyntheticArchiveReaderProvider.providing(ImportFixtures.validReader())
        let packageImport = IPAPackageImport(
            intake: intake,
            readerProvider: readerProvider,
            library: library
        )
        let identityStore = InMemorySigningIdentityStore()
        let pipeline = SignApplicationPipeline(
            identities: identityStore,
            digest: CryptoKitMessageDigest(),
            signatureVerifier: UnavailableCryptographicSignatureVerifier(),
            profileValidation: CompositionRoot.makeProvisioningProfilePipeline(identityStore: identityStore),
            writer: ZipArchiveWriter()
        )
        let layout = makeStorageLayout(root: root)
        let exports = ExportCenter(
            records: FileExportRecordStore(catalogLocation: layout.exportCatalog),
            artifacts: FileExportArtifactStore(exportsDirectory: layout.exportedArtifacts)
        )
        let operations = CompositionRoot.makeSigningOperationCenter(
            pipeline: pipeline,
            exports: exports,
            history: InMemorySigningHistoryStore()
        )
        return ApplicationEnvironment(
            applicationInfo: ApplicationInfo(
                displayName: "ZynSign",
                marketingVersion: "0.1.0",
                buildVersion: "42"
            ),
            packageImport: packageImport,
            importHub: ImportHub(
                processing: ImportWorkflow(
                    intake: intake,
                    stagingArea: SyntheticImportStagingArea(),
                    readerProvider: readerProvider,
                    library: library,
                    storage: ImportStorageGuard(probe: nil)
                ),
                progressInterval: 0
            ),
            library: library,
            bundleInspection: IPABundleContentsInspection(
                library: library,
                readerProvider: readerProvider
            ),
            applicationDetailsInspection: IPAApplicationDetailsInspection(
                library: library,
                readerProvider: readerProvider
            ),
            bundleEntryInspection: IPABundleEntryInspection(
                library: library,
                readerProvider: readerProvider
            ),
            identityStore: identityStore,
            pkcs12Importer: UnavailablePKCS12Importer(),
            signingPipeline: pipeline,
            signingEngine: CompositionRoot.makeSigningEngine(identityStore: identityStore, pipeline: pipeline),
            analyticsJournal: InMemoryLocalAnalyticsJournal(),
            signingPresets: nil,
            signingHistory: nil,
            provisioningProfiles: nil,
            exportCenter: exports,
            signingOperations: operations,
            signingQueue: SigningQueue(
                executor: SigningOperationExecutor(operations: operations, library: library),
                artifactURLResolver: { _ in root.appendingPathComponent("unused.ipa") }
            ),
            storageManagement: makeStorageManagement(root: root),
            preferencesStore: preferences,
            biometricAuthenticator: FakeBiometricAuthenticator()
        )
    }

    /// A Settings Control Center model over synthetic locations inside `root`.
    @MainActor
    static func makeSettingsModel(root: URL) -> SettingsCenterModel {
        let preferences = makePreferencesStore(root: root)
        return SettingsCenterModel(
            store: preferences,
            environment: makeEnvironment(root: root, preferences: preferences),
            diagnosticLog: makeDiagnosticLog(root: root)
        )
    }
}

/// Where ZynSign's storage lives inside a synthetic root.
///
/// The four categories are the four the user can act on, plus the technical
/// log's own location, so a fixture that needs to place a file places it in
/// the category that file belongs to.
struct StorageLayout {
    let importedApplications: URL
    let exportedArtifacts: URL
    let temporary: [URL]
    let history: URL
    let exportCatalog: URL
    let diagnosticsLog: URL
}

/// A biometric authenticator that answers whatever the test decides and
/// records what it was asked.
final class FakeBiometricAuthenticator: BiometricAuthenticating, @unchecked Sendable {

    private let lock = NSLock()
    private var recorded: [String] = []

    /// What the device offers.
    var availability: BiometricAvailability

    /// What an attempt answers.
    var outcome: AuthenticationOutcome

    init(
        availability: BiometricAvailability = BiometricAvailability(
            kind: .faceID,
            isAvailable: true,
            unavailableReason: ""
        ),
        outcome: AuthenticationOutcome = .authenticated
    ) {
        self.availability = availability
        self.outcome = outcome
    }

    func availability() -> BiometricAvailability { availability }

    func authenticate(reason: String) async -> AuthenticationOutcome {
        lock.withLock { recorded.append(reason) }
        return outcome
    }

    /// Every reason the test's attempts carried, in order.
    var recordedReasons: [String] { lock.withLock { recorded } }

    /// How many attempts were made.
    var attemptCount: Int { lock.withLock { recorded.count } }
}

/// A preferences store that counts what it is asked to write, so a test can
/// assert that an unchanged preference never touches the disk.
final class RecordingPreferencesStore: PreferencesStore {

    private let store: FilePreferencesStore

    init(store: FilePreferencesStore) {
        self.store = store
    }

    var snapshot: ZynSignPreferences { store.snapshot }

    var didMigrateLegacyValues: Bool { store.didMigrateLegacyValues }

    private(set) var saveCount = 0

    func save(_ preferences: ZynSignPreferences) throws {
        saveCount += 1
        try store.save(preferences)
    }

    func reset() throws {
        saveCount += 1
        try store.reset()
    }
}

/// A preferences store that cannot write, so a test can assert that a failed
/// change is reported rather than shown.
final class FailingPreferencesStore: PreferencesStore {

    var snapshot: ZynSignPreferences
    var didMigrateLegacyValues: Bool { false }

    init(snapshot: ZynSignPreferences = ZynSignPreferences.shippedDefault) {
        self.snapshot = snapshot
    }

    func save(_ preferences: ZynSignPreferences) throws {
        throw ZynSignError.preferencesStorageFailure(
            diagnosticDetail: "The preferences document could not be written.",
            underlyingError: CocoaError(.fileWriteNoPermission)
        )
    }

    func reset() throws {
        throw ZynSignError.preferencesStorageFailure(
            diagnosticDetail: "The preferences document could not be written.",
            underlyingError: CocoaError(.fileWriteNoPermission)
        )
    }
}
