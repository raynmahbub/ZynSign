import Foundation

/// Preferences, diagnostics, and recovery.
///
/// Part of `CompositionRoot`, which chooses every concrete
/// implementation and wires the layers together. Split out of the
/// original single file for readability; the members are unchanged.
extension CompositionRoot {

    /// Builds the application environment for a fresh launch.
    ///
    /// One library use case is constructed per launch and shared by the
    /// import use case, the bundle inspection use case, and the environment,
    /// so the Import area and the Applications area act on the same records
    /// and the same storage wherever they admit, list, inspect, or remove
    /// entries. The signing identity store, its PKCS#12 importer, and the
    /// signing pipeline are composed here as well so the Certificates and
    /// Library signing screens act on the same Keychain registrations and
    /// the same cryptographic machinery that the tests cover.
    static func makeRecoveryStore() -> RecoveryStore { RecoveryStore(root: libraryRootDirectory) }

    /// Selects the local activity journal implementation: the file-backed
    /// journal on iOS, and the in-memory journal elsewhere. Both live
    /// entirely on-device; the choice only decides whether the journal
    /// survives relaunch.
    static func makeAnalyticsJournal() -> any LocalAnalyticsRecording {
        #if os(iOS)
        return FileLocalAnalyticsJournal(
            location: FileLocalAnalyticsJournal.defaultLocation(),
            capacity: AnalyticsPolicy.journalCapacity
        )
        #else
        return InMemoryLocalAnalyticsJournal(capacity: AnalyticsPolicy.journalCapacity)
        #endif
    }

    static func makeSigningDiagnosticsHistoryStore() -> any SigningDiagnosticsHistoryStore {
        FileSigningDiagnosticsHistoryStore(
            location: libraryRootDirectory.appendingPathComponent("SigningDiagnostics.json")
        )
    }

    /// One read-only analyzer for import, app details and the signing screen.
    /// The same profile validator, Keychain metadata port, archive reader and
    /// Mach-O admission rule are used by the pipeline; no second policy or
    /// filesystem location is invented by a view.
    static func makeSigningDiagnostics(
        library: ApplicationLibrary,
        intake: SecurityScopedArtifactIntake,
        identities: any IdentityStore,
        history: any SigningDiagnosticsHistoryStore
    ) -> SigningDiagnosticsService {
        SigningDiagnosticsService(
            library: library,
            readerProvider: DirectoryArtifactArchiveReaderProvider(
                directory: libraryArtifactDirectory,
                fileExtension: intake.fileExtension
            ),
            identities: identities,
            profilePipeline: makeProvisioningProfilePipeline(identityStore: identities),
            policy: makeProvisioningPolicyValidation(identityStore: identities),
            digest: makeMessageDigest(),
            historyStore: history
        )
    }

    /// The preferences store the whole application reads and writes through.
    ///
    /// One store per launch: the Settings Control Center writes through it,
    /// the shell reads it to apply appearance and locking, and the intake
    /// reads it once to learn where staging happens.
    static func makePreferencesStore() -> any PreferencesStore {
        MainActor.assumeIsolated {
            FilePreferencesStore(
                location: preferencesDocumentLocation(),
                legacyDefaults: .standard
            )
        }
    }

    /// Builds the biometric authenticator the Security Center and the lock
    /// use. The platform implementation owns LocalAuthentication; this is the
    /// only place it is chosen.
    static func makeBiometricAuthenticator() -> any BiometricAuthenticating {
        #if os(iOS) && !targetEnvironment(simulator)
        return LocalAuthenticationBiometricAuthenticator()
        #else
        return UnavailableBiometricAuthenticator()
        #endif
    }
}
