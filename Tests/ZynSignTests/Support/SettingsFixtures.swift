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

    /// A storage layout inside `root`, mirroring the real one.
    static func makeStorageLocations(root: URL) -> StorageLocations {
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let temporary = root.appendingPathComponent("Temporary", isDirectory: true)
        let caches = root.appendingPathComponent("Caches", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        return StorageLocations(
            libraryArtifacts: library.appendingPathComponent("Artifacts", isDirectory: true),
            signedArtifacts: documents.appendingPathComponent("Signed", isDirectory: true),
            temporary: temporary,
            caches: caches,
            libraryMetadata: library,
            export: temporary.appendingPathComponent("ZynSign-Export", isDirectory: true),
            signingHistoryJournal: library.appendingPathComponent("SigningHistory.json", isDirectory: false),
            analyticsJournal: root.appendingPathComponent("Analytics", isDirectory: true)
                .appendingPathComponent("events.jsonl", isDirectory: false),
            diagnosticsLog: library.appendingPathComponent("Diagnostics.json", isDirectory: false),
            libraryCatalog: library.appendingPathComponent("catalog.json", isDirectory: false),
            signingPresetsCatalog: library.appendingPathComponent("SigningPresets.json", isDirectory: false),
            provisioningProfilesCatalog: library.appendingPathComponent("ProvisioningProfiles.json", isDirectory: false),
            preferencesDocument: preferencesLocation(root: root)
        )
    }

    /// A storage service over the synthetic locations inside `root`.
    static func makeStorageService(root: URL) -> StorageUsageService {
        StorageUsageService(locations: makeStorageLocations(root: root))
    }

    /// A technical log inside `root`.
    static func makeDiagnosticLog(root: URL) -> DiagnosticLog {
        DiagnosticLog(
            location: makeStorageLocations(root: root).diagnosticsLog,
            maximumBytes: 64 * 1024
        )
    }

    /// An application environment over synthetic stores inside `root`.
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
        return ApplicationEnvironment(
            applicationInfo: ApplicationInfo(
                displayName: "ZynSign",
                marketingVersion: "0.1.0",
                buildVersion: "42"
            ),
            packageImport: packageImport,
            packageImportQueue: PackageImportQueue(importing: packageImport),
            library: library,
            bundleInspection: IPABundleContentsInspection(
                library: library,
                readerProvider: readerProvider
            ),
            identityStore: identityStore,
            pkcs12Importer: UnavailablePKCS12Importer(),
            signingPipeline: SignApplicationPipeline(
                identities: identityStore,
                digest: CryptoKitMessageDigest(),
                signatureVerifier: UnavailableCryptographicSignatureVerifier(),
                profileValidation: CompositionRoot.makeProvisioningProfilePipeline(identityStore: identityStore),
                writer: ZipArchiveWriter()
            ),
            analyticsJournal: InMemoryLocalAnalyticsJournal(),
            signingPresets: nil,
            signingHistory: nil,
            preferencesStore: preferences,
            biometricAuthenticator: FakeBiometricAuthenticator(),
            provisioningProfiles: nil
        )
    }

    /// A Settings Control Center model over synthetic locations inside `root`.
    @MainActor
    static func makeSettingsModel(root: URL) -> SettingsCenterModel {
        let preferences = makePreferencesStore(root: root)
        return SettingsCenterModel(
            store: preferences,
            environment: makeEnvironment(root: root, preferences: preferences),
            storage: makeStorageService(root: root),
            diagnosticLog: makeDiagnosticLog(root: root)
        )
    }
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
