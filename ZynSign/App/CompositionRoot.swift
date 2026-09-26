import Foundation

/// The composition root for ZynSign.
///
/// This is the single place where application-layer objects are constructed
/// and wired together. The application entry point calls into it and nothing
/// else; views receive dependencies through the SwiftUI environment and never
/// construct application-layer or domain objects themselves.
///
/// Concrete implementations are selected here and nowhere below. Where a
/// capability has more than one possible implementation — the archive reader
/// and the persistence stores above all — the choice is made here, so that
/// the layers beneath the choice depend only on the port.
enum CompositionRoot {

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
    static func makeApplicationEnvironment() -> ApplicationEnvironment {
        let intake = SecurityScopedArtifactIntake(directory: importStagingDirectory)
        let library = makeApplicationLibrary(intake: intake)
        let packageImport = makePackageImport(intake: intake, library: library)
        let identityStore = makeIdentityStore()
        let pkcs12Importer = makePKCS12Importer(identityStore: identityStore)
        let pipeline = makeSignApplicationPipeline(identityStore: identityStore)
        let presets = makeSigningPresetStore()
        let history = makeSigningHistoryStore()
        let profiles = makeProvisioningProfileLibrary()
        var environment = ApplicationEnvironment(
            applicationInfo: ApplicationInfo.current(bundle: .main),
            packageImport: packageImport,
            packageImportQueue: PackageImportQueue(importing: packageImport),
            library: library,
            bundleInspection: makeBundleContentsInspection(intake: intake, library: library),
            applicationDetailsInspection: makeApplicationDetailsInspection(intake: intake, library: library),
            identityStore: identityStore,
            pkcs12Importer: pkcs12Importer,
            signingPipeline: pipeline,
            analyticsJournal: makeAnalyticsJournal(),
            signingPresets: presets,
            signingHistory: history,
            provisioningProfiles: profiles
        )
        environment.provisioningProfileImporter = makeProvisioningProfileImporter()
        environment.appIcons = makeAppIconExtraction()
        environment.binaryInspection = makeBinaryInspection(intake: intake, library: library)
        return environment
    }

    /// Builds the Binary & Signature Inspector use case over the given
    /// library.
    ///
    /// The archive boundary reads library storage under the same file
    /// extension and resource policy as the other artifact-facing use cases,
    /// except for the single-read bound, which is widened to the inspector's
    /// executable bound: executables are routinely larger than the 4 MiB
    /// metadata reads the default policy allows. The per-entry and total
    /// ceilings still apply. Signed packages are opened only from the
    /// directory the signing screen writes to. The parser, decoder, digest,
    /// and CMS mechanism are the same read-only components the rest of the
    /// application composes; nothing built here signs, writes, or evaluates
    /// certificate trust.
    static func makeBinaryInspection(
        intake: SecurityScopedArtifactIntake,
        library: ApplicationLibrary,
        limits: ArchiveLimits = .default,
        inspectionLimits: BinaryInspectionLimits = .default
    ) -> IPABinaryInspection {
        let readerLimits = ArchiveLimits(
            maximumEntryCount: limits.maximumEntryCount,
            maximumEntryNameLength: limits.maximumEntryNameLength,
            maximumPathDepth: limits.maximumPathDepth,
            maximumEntryBytes: limits.maximumEntryBytes,
            maximumTotalUncompressedBytes: limits.maximumTotalUncompressedBytes,
            maximumCompressionRatio: limits.maximumCompressionRatio,
            maximumInspectionReadBytes: max(
                limits.maximumInspectionReadBytes,
                inspectionLimits.maximumExecutableBytes,
                inspectionLimits.maximumSealedFileBytes
            )
        )
        let digest = makeMessageDigest()
        return IPABinaryInspection(
            library: library,
            readerProvider: DirectoryArtifactArchiveReaderProvider(
                directory: libraryArtifactDirectory,
                fileExtension: intake.fileExtension,
                limits: readerLimits
            ),
            makePackageReader: { ZipArchiveReader(location: $0, limits: readerLimits) },
            signedPackagesDirectory: signedPackagesDirectory,
            parser: ReadOnlyMachOParser(),
            decoder: ReadOnlyMachOLoadCommandDecoder(),
            verifier: BinarySignatureVerifier(
                digest: digest,
                cmsVerifier: makeCodeSignatureCMSVerifier(digest: digest)
            ),
            digest: digest,
            limits: inspectionLimits
        )
    }

    /// Builds the mechanism that examines an existing code signature's CMS
    /// message: ZynSign's bounded CMS reader, the platform certificate parser,
    /// and the same signature-verification selection the provisioning-profile
    /// boundary uses — the Security framework's key primitives on iOS, an
    /// explicit "unavailable" everywhere else.
    static func makeCodeSignatureCMSVerifier(
        digest: any MessageDigest = makeMessageDigest(),
        certificateParser: any CertificateParser = AppleCertificateParser()
    ) -> any CodeSignatureCMSVerifying {
        DetachedCodeSignatureCMSInspector(
            certificateParser: certificateParser,
            signatureVerifier: makeCMSSignatureVerifier(),
            digest: digest
        )
    }

    /// The directory the signing screen writes signed packages to, which the
    /// inspector may open for comparison. Nothing is created here.
    static var signedPackagesDirectory: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Signed", isDirectory: true)
    }

    /// Builds the provisioning-profile importer the Profiles tab drives. It
    /// parses profiles through the same inspection use case the signing
    /// pipeline composes, and stores the original `.mobileprovision` files
    /// in the same directory the profile library's catalog lives in — the
    /// two are one library, not parallel stores.
    static func makeProvisioningProfileImporter() -> ProvisioningProfileImporter {
        let cmsVerifier = makeProvisioningProfileCMSVerifier()
        return ProvisioningProfileImporter(
            inspection: makeProvisioningProfileInspection(
                payloadDecoder: CMSProvisioningProfilePayloadDecoder(verifier: cmsVerifier)
            ),
            storageDirectory: provisioningProfileCatalogLocation().deletingLastPathComponent()
        )
    }

    /// Builds the icon extractor over the same storage convention the
    /// library artifacts live in, caching icon bytes in the system caches
    /// directory — a location the system may reclaim, which is exactly the
    /// durability a derived image deserves.
    static func makeAppIconExtraction() -> AppIconExtraction {
        let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Caches", isDirectory: true)
        return AppIconExtraction(
            readerProvider: DirectoryArtifactArchiveReaderProvider(
                directory: libraryArtifactDirectory
            ),
            cacheDirectory: caches.appendingPathComponent("ZynSignAppIcons", isDirectory: true)
        )
    }

    /// Builds the file-backed signing preset store, lazily created at the
    /// canonical Application Support location.
    static func makeSigningPresetStore() -> any SigningPresetStore {
        FileSigningPresetStore(catalogLocation: signingPresetCatalogLocation())
    }

    /// Builds the file-backed signing history store, lazily created at the
    /// canonical Application Support location.
    static func makeSigningHistoryStore() -> any SigningHistoryStore {
        FileSigningHistoryStore(
            journalLocation: signingHistoryJournalLocation(),
            capacity: AnalyticsPolicy.journalCapacity
        )
    }

    /// Builds the file-backed provisioning profile library, lazily created
    /// at the canonical Application Support location.
    static func makeProvisioningProfileLibrary() -> ProvisioningProfileLibrary {
        FileProvisioningProfileLibrary(catalogLocation: provisioningProfileCatalogLocation())
    }

    /// The on-disk location of the signing preset catalog. Lives under
    /// Application Support so it is not part of any iCloud or iTunes
    /// backup.
    static func signingPresetCatalogLocation() -> URL {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("ZynSignLibrary", isDirectory: true)
            .appendingPathComponent("SigningPresets.json", isDirectory: false)
    }

    /// The on-disk location of the signing history journal.
    static func signingHistoryJournalLocation() -> URL {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("ZynSignLibrary", isDirectory: true)
            .appendingPathComponent("SigningHistory.json", isDirectory: false)
    }

    /// The on-disk location of the provisioning profile library catalog.
    static func provisioningProfileCatalogLocation() -> URL {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("ZynSignLibrary", isDirectory: true)
            .appendingPathComponent("ProvisioningProfiles.json", isDirectory: false)
    }

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

    /// The signing identity store for this launch.
    ///
    /// On iOS the store is the experimental Keychain composition: registrations
    /// live as generic-password items, private keys remain in the Keychain with
    /// `WhenUnlockedThisDeviceOnly` and non-extractable protection, and
    /// resolution re-checks public-key association and algorithm support on
    /// every operation. On other platforms the store reports no identities
    /// rather than fabricating one.
    static func makeIdentityStore() -> any IdentityStore {
        #if os(iOS)
        return SecureIdentityStore.experimentalKeychainStore()
        #else
        return UnavailableIdentityStore()
        #endif
    }

    /// The PKCS#12 importer for this launch. It bridges Security's import to
    /// the store's registration. On non-iOS targets it reports a platform
    /// restriction.
    static func makePKCS12Importer(identityStore: any IdentityStore) -> any SigningIdentityImporter {
        #if os(iOS)
        if let secure = identityStore as? SecureIdentityStore {
            return ApplePKCS12Importer(store: secure)
        }
        #endif
        return UnavailablePKCS12Importer()
    }

    /// Builds the package inspection use case, selecting the concrete archive
    /// implementation.
    ///
    /// The selected implementation reads ZIP containers from `artifactDirectory`
    /// and applies the default resource policy. Nothing else in the application
    /// knows which implementation was chosen: the use case depends only on the
    /// archive ports, so a different container engine or storage convention can
    /// be substituted here alone.
    ///
    /// The directory is supplied by the caller rather than created here.
    /// Inspection neither extracts a package nor writes into the directory; it
    /// reads the entry table of the archive the directory holds.
    static func makeArchiveInspection(
        artifactDirectory: URL,
        limits: ArchiveLimits = .default
    ) -> IPAArchiveInspection {
        IPAArchiveInspection(
            readerProvider: DirectoryArtifactArchiveReaderProvider(
                directory: artifactDirectory,
                limits: limits
            ),
            limits: limits
        )
    }

    /// Builds the bundle metadata inspection use case, selecting the
    /// concrete archive implementation.
    ///
    /// It reads the bundle's information file from the same storage
    /// convention as structural inspection and applies the same resource
    /// policy, so the two halves of the inspection stage stay consistent
    /// when the composition root is the only place that changes them.
    static func makeBundleMetadataInspection(
        artifactDirectory: URL,
        limits: ArchiveLimits = .default
    ) -> IPABundleMetadataInspection {
        IPABundleMetadataInspection(
            readerProvider: DirectoryArtifactArchiveReaderProvider(
                directory: artifactDirectory,
                limits: limits
            ),
            limits: limits
        )
    }

    /// Builds the package import use case over the given intake and library,
    /// selecting the concrete archive implementation.
    ///
    /// The library is the one the environment carries, so packages an import
    /// admits are the records the Applications area lists and removes. The
    /// archive boundary searches library storage first and staging second,
    /// so an artifact is readable by identifier both while it is being
    /// examined and after it has been recorded. Everything is bound to the
    /// same directories and the same file-extension convention here, and no
    /// other type knows the locations. The default resource policy applies
    /// to every archive.
    static func makePackageImport(
        intake: SecurityScopedArtifactIntake,
        library: ApplicationLibrary,
        limits: ArchiveLimits = .default
    ) -> IPAPackageImport {
        let readerProvider = DirectoryArtifactArchiveReaderProvider(
            directories: [libraryArtifactDirectory, intake.directory],
            fileExtension: intake.fileExtension,
            limits: limits
        )
        return IPAPackageImport(
            intake: intake,
            readerProvider: readerProvider,
            library: library,
            limits: limits
        )
    }

    /// Builds a certificate inspector.
    ///
    /// The parser and the clock are selected here. Inspection is not installed
    /// in the application environment and is not reachable from the interface:
    /// nothing in the shell imports, exports, or manages certificates, and
    /// inspection does not persist the bytes it reads.
    static func makeCertificateInspector(
        parser: any CertificateParser = AppleCertificateParser(),
        clock: any EvaluationClock = SystemEvaluationClock()
    ) -> CertificateInspector {
        CertificateInspector(parser: parser, clock: clock)
    }

    /// Builds the provisioning-profile inspection use case. The container
    /// decoder is supplied explicitly because CMS unwrapping and verification
    /// are not implemented by ZS-017; the factory wires only the typed parser,
    /// validator, and injected clock around that future boundary.
    static func makeProvisioningProfileInspection(
        payloadDecoder: any ProvisioningProfilePayloadDecoder,
        certificateParser: (any CertificateParser)? = AppleCertificateParser(),
        clock: any EvaluationClock = SystemEvaluationClock(),
        limits: ProvisioningProfileParsingLimits = .default
    ) -> ProvisioningProfileInspectionUseCase {
        ProvisioningProfileInspectionUseCase(
            payloadDecoder: payloadDecoder,
            parser: PropertyListProvisioningProfileParser(
                certificateParser: certificateParser,
                limits: limits
            ),
            clock: clock
        )
    }

    /// Builds the provisioning-profile CMS verifier, selecting the signature
    /// mechanism for this target.
    ///
    /// Apple's CMS decoder family (`CMSDecoderCreate` and the rest) is
    /// documented for macOS 10.5 and later only, and `CMSSignerStatus` for
    /// macOS and Mac Catalyst only, so no platform CMS service is composed
    /// here: the container is read by ZynSign's own bounded structure reader
    /// and the signature is checked through the injected mechanism. On iOS that
    /// mechanism uses documented key primitives; on any other target it reports
    /// verification as unavailable rather than skipping it silently. Trust
    /// evaluation is not composed at all, because this increment performs none.
    static func makeProvisioningProfileCMSVerifier(
        certificateParser: any CertificateParser = AppleCertificateParser()
    ) -> any CMSVerifier {
        ProvisioningProfileCMSVerifier(
            certificateParser: certificateParser,
            signatureVerifier: makeCMSSignatureVerifier()
        )
    }

    /// Builds the provisioning-profile verification use case over the existing
    /// parsing and structural-validation use case.
    ///
    /// The CMS verifier is composed once and used both directly, for the
    /// verification evidence, and through the ZS-017 payload-decoder seam, so
    /// there is one container boundary and one profile parser rather than a
    /// parallel profile subsystem. The identity store is optional and read-only:
    /// the use case lists identities to answer a certificate-relationship
    /// question and never requests a signing capability. Nothing built here is
    /// installed in the application environment, because no interface consumes
    /// profile verification yet.
    static func makeProvisioningProfileVerification(
        certificateParser: any CertificateParser = AppleCertificateParser(),
        clock: any EvaluationClock = SystemEvaluationClock(),
        limits: ProvisioningProfileParsingLimits = .default,
        identityStore: (any IdentityStore)? = nil
    ) -> ProvisioningProfileVerificationUseCase {
        let cmsVerifier = makeProvisioningProfileCMSVerifier(certificateParser: certificateParser)
        return ProvisioningProfileVerificationUseCase(
            cmsVerifier: cmsVerifier,
            inspection: makeProvisioningProfileInspection(
                payloadDecoder: CMSProvisioningProfilePayloadDecoder(verifier: cmsVerifier),
                certificateParser: certificateParser,
                clock: clock,
                limits: limits
            ),
            identityStore: identityStore
        )
    }

    /// Builds the provisioning-configuration validation use case over the
    /// domain policy validator.
    ///
    /// The clock is injected so an evaluation is reproducible, and the identity
    /// store is optional and read-only: the use case resolves identity metadata
    /// to answer certificate and team questions and never requests a signing
    /// capability. The factory builds an evaluator only — it creates no profile,
    /// identity, signature, or package, and nothing built here is installed in
    /// the application environment, because no interface consumes a policy
    /// result yet.
    static func makeProvisioningPolicyValidation(
        clock: any EvaluationClock = SystemEvaluationClock(),
        identityStore: (any IdentityStore)? = nil
    ) -> ValidateProvisioningConfigurationUseCase {
        ValidateProvisioningConfigurationUseCase(
            policyValidator: ProvisioningPolicyValidator(clock: clock),
            identityStore: identityStore
        )
    }

    /// Builds the integrated provisioning-profile validation pipeline over the
    /// existing verification and policy use cases.
    ///
    /// The two halves are the ones already wired above — ZS-018's container,
    /// parsing, and certificate evidence, and ZS-019's policy evaluation — and
    /// this factory only composes them, so a single run performs one CMS
    /// verification, one payload parse, one structural validation, one
    /// relationship analysis, and one policy evaluation. The identity store is
    /// optional and read-only for both halves: it is asked to list identities and
    /// to resolve metadata, never for a signing capability, and no key handle is
    /// reached. The clock is injected so that validity is reproducible for a
    /// fixed instant.
    ///
    /// Nothing built here is installed in the application environment, because no
    /// interface consumes a pipeline result yet, and the pipeline persists nothing:
    /// its result is derived from the profile, the application, the identity, the
    /// configuration, the time, and the device context a caller has.
    static func makeProvisioningProfilePipeline(
        certificateParser: any CertificateParser = AppleCertificateParser(),
        clock: any EvaluationClock = SystemEvaluationClock(),
        limits: ProvisioningProfileParsingLimits = .default,
        identityStore: (any IdentityStore)? = nil
    ) -> ValidateProvisioningProfileUseCase {
        ValidateProvisioningProfileUseCase(
            profileVerification: makeProvisioningProfileVerification(
                certificateParser: certificateParser,
                clock: clock,
                limits: limits,
                identityStore: identityStore
            ),
            configurationValidation: makeProvisioningPolicyValidation(
                clock: clock,
                identityStore: identityStore
            )
        )
    }

    /// Builds the embedded-profile intake over the given archive boundary,
    /// selecting the concrete archive implementation the same way the other
    /// artifact-facing use cases do.
    ///
    /// The intake reads one entry of one package through the existing reader
    /// provider and resource policy and reaches no conclusion about what those
    /// bytes are; the pipeline it feeds is what classifies them. Nothing built
    /// here is installed in the application environment, because no interface
    /// consumes an embedded profile yet.
    static func makeBundleProvisioningProfileIntake(
        artifactDirectory: URL,
        limits: ArchiveLimits = .default
    ) -> BundleProvisioningProfileIntake {
        BundleProvisioningProfileIntake(
            readerProvider: DirectoryArtifactArchiveReaderProvider(
                directory: artifactDirectory,
                limits: limits
            ),
            limits: limits
        )
    }

    /// The signature mechanism available on this target.
    private static func makeCMSSignatureVerifier() -> any CMSSignatureVerifier {
        #if os(iOS)
        return AppleCMSSignatureVerifier()
        #else
        return UnavailableCMSSignatureVerifier()
        #endif
    }

    /// Builds the cryptographic signing use case over the given identity
    /// store.
    ///
    /// The engine is the pure capability engine, and the identity store is
    /// the ZS-016 boundary that owns the key: the use case resolves the
    /// capability, the engine asks it for a signature, and only signature
    /// bytes cross. Nothing built here is installed in the application
    /// environment — the identity store is not composed into the app until
    /// its device validation completes, and no interface consumes a
    /// signature result yet.
    static func makeCryptographicSigningUseCase(
        identityStore: any IdentityStore,
        engine: any CryptographicSigningEngine = CapabilitySigningEngine()
    ) -> CryptographicSigningUseCase {
        CryptographicSigningUseCase(identityStore: identityStore, engine: engine)
    }

    /// Builds the digest mechanism for this target.
    ///
    /// CryptoKit's hashing primitives are documented for the deployment
    /// target, so the platform implementation is the only candidate; the
    /// factory keeps the choice in the composition root, where every other
    /// mechanism selection happens.
    static func makeMessageDigest() -> any MessageDigest {
        CryptoKitMessageDigest()
    }

    /// Builds the signature-verification mechanism for this target.
    ///
    /// On iOS the mechanism uses the documented Security key primitives
    /// under the operations `SigningAlgorithm` selects; on any other target
    /// it reports verification as unavailable rather than skipping it
    /// silently. Nothing built here is installed in the application
    /// environment, because no interface consumes a verification outcome
    /// yet.
    static func makeCryptographicSignatureVerifier() -> any CryptographicSignatureVerifier {
        #if os(iOS)
        return AppleSignatureVerifier()
        #else
        return UnavailableCryptographicSignatureVerifier()
        #endif
    }

    /// Builds the bundle contents inspection use case over the given library,
    /// selecting the concrete archive implementation.
    ///
    /// The explorer describes applications the library holds, so its archive
    /// boundary reads library storage only, under the same file-extension
    /// convention and the same resource policy as import. It is the same
    /// reader implementation import uses, chosen here and nowhere below;
    /// inspection reads a package's entry table and never writes.
    static func makeBundleContentsInspection(
        intake: SecurityScopedArtifactIntake,
        library: ApplicationLibrary,
        limits: ArchiveLimits = .default
    ) -> IPABundleContentsInspection {
        IPABundleContentsInspection(
            library: library,
            readerProvider: DirectoryArtifactArchiveReaderProvider(
                directory: libraryArtifactDirectory,
                fileExtension: intake.fileExtension,
                limits: limits
            )
        )
    }

    /// Builds the comprehensive, read-only inspection used by App Details.
    ///
    /// Metadata reads keep the ordinary 4 MiB policy. The archive reader is
    /// configured to permit a separate, explicit 32 MiB ceiling for a
    /// best-effort Mach-O signature-structure summary; larger executables are
    /// not loaded and are reported as not inspected. This is structural
    /// parsing only, not cryptographic verification.
    static func makeApplicationDetailsInspection(
        intake: SecurityScopedArtifactIntake,
        library: ApplicationLibrary,
        limits: ArchiveLimits = .default,
        maximumExecutableReadBytes: Int = 32 * 1_024 * 1_024
    ) -> IPAApplicationDetailsInspection {
        let readerLimits = ArchiveLimits(
            maximumEntryCount: limits.maximumEntryCount,
            maximumEntryNameLength: limits.maximumEntryNameLength,
            maximumPathDepth: limits.maximumPathDepth,
            maximumEntryBytes: limits.maximumEntryBytes,
            maximumTotalUncompressedBytes: limits.maximumTotalUncompressedBytes,
            maximumCompressionRatio: limits.maximumCompressionRatio,
            maximumInspectionReadBytes: max(limits.maximumInspectionReadBytes, maximumExecutableReadBytes)
        )
        return IPAApplicationDetailsInspection(
            library: library,
            readerProvider: DirectoryArtifactArchiveReaderProvider(
                directory: libraryArtifactDirectory,
                fileExtension: intake.fileExtension,
                limits: readerLimits
            ),
            limits: limits,
            maximumExecutableReadBytes: maximumExecutableReadBytes
        )
    }

    /// Builds the nested-code discovery use case over the given library,
    /// selecting the concrete archive implementation.
    ///
    /// The archive boundary reads library storage only — discovery describes an
    /// application the library holds — under the same file-extension
    /// convention and the same resource policy as the other artifact-facing use
    /// cases, and the same read-only parser and signature inspector classify
    /// the candidates it reads. Discovery reads and concludes nothing about
    /// trust, and it reaches no signing capability: the plan it returns is
    /// descriptive data, and nothing built here signs, modifies, or extracts
    /// anything.
    ///
    /// The discovery policy is a separate injection point from the archive
    /// policy, because the two bound different things: the archive limits bound
    /// what a container may declare and expand, and the discovery limits bound
    /// how much of a bundle ZynSign is willing to describe.
    ///
    /// Nothing built here is installed in the application environment, because
    /// no interface consumes a plan yet.
    static func makeNestedCodeDiscoveryInspection(
        intake: SecurityScopedArtifactIntake,
        library: ApplicationLibrary,
        limits: ArchiveLimits = .default,
        discoveryLimits: NestedCodeDiscoveryLimits = .default
    ) -> NestedCodeDiscoveryInspection {
        NestedCodeDiscoveryInspection(
            library: library,
            readerProvider: DirectoryArtifactArchiveReaderProvider(
                directory: libraryArtifactDirectory,
                fileExtension: intake.fileExtension,
                limits: limits
            ),
            archiveLimits: limits,
            limits: discoveryLimits
        )
    }

    /// Builds the nested code signing use case over the given identity store.
    ///
    /// Signs nested Mach-O code in dependency-aware order, using the existing
    /// single Mach-O signing capability and cryptographic verification abstractions.
    /// Nothing built here is installed in the application environment, because no
    /// interface consumes nested signing results yet.
    static func makeNestedCodeSigningUseCase(
        identityStore: any IdentityStore,
        digest: any MessageDigest = makeMessageDigest(),
        verifier: any CryptographicSignatureVerifier = makeCryptographicSignatureVerifier(),
        parser: any MachOParsing = ReadOnlyMachOParser(),
        writer: MachOCodeSignatureWriter = MachOCodeSignatureWriter()
    ) -> SignNestedCodeUseCase {
        SignNestedCodeUseCase(
            identities: identityStore,
            digest: digest,
            verifier: verifier,
            parser: parser,
            writer: writer
        )
    }

    /// Selects the concrete archive writer: the deterministic stored-only
    /// ZIP writer. Nothing beneath the composition root names the format.
    static func makeArchiveWriter() -> any ArchiveWriter {
        ZipArchiveWriter()
    }

    /// Builds the signed-application packaging use case over the selected
    /// writer and the ordinary archive reader. Nothing built here is
    /// installed in the application environment — no interface packages a
    /// signed bundle yet.
    static func makePackageSignedApplication(
        writer: any ArchiveWriter = makeArchiveWriter(),
        limits: ArchiveLimits = .default
    ) -> PackageSignedApplication {
        PackageSignedApplication(writer: writer, limits: limits)
    }

    /// Builds the signed-application verifier over the ordinary archive
    /// reader and the target digest mechanism. Nothing built here is
    /// installed in the application environment — no interface verifies a
    /// signed container yet.
    static func makeVerifySignedApplication(
        digest: any MessageDigest = makeMessageDigest(),
        limits: ArchiveLimits = .default
    ) -> VerifySignedApplication {
        VerifySignedApplication(digest: digest, limits: limits)
    }

    /// Builds the end-to-end application signing pipeline over the given
    /// identity store.
    ///
    /// The pipeline, the packager, and the verifier are composed over the
    /// same writer, reader, digest, and profile machinery the rest of the
    /// application uses. Nothing built here is installed in the application
    /// environment: the pipeline is constructible and covered by tests, but
    /// no signing interface is composed until device validation completes,
    /// and no installation channel exists anywhere in the product.
    static func makeSignApplicationPipeline(
        identityStore: any IdentityStore,
        digest: any MessageDigest = makeMessageDigest(),
        signatureVerifier: any CryptographicSignatureVerifier = makeCryptographicSignatureVerifier(),
        certificateParser: any CertificateParser = AppleCertificateParser(),
        clock: any EvaluationClock = SystemEvaluationClock(),
        writer: any ArchiveWriter = makeArchiveWriter(),
        limits: ArchiveLimits = .default
    ) -> SignApplicationPipeline {
        SignApplicationPipeline(
            identities: identityStore,
            digest: digest,
            signatureVerifier: signatureVerifier,
            profileValidation: makeProvisioningProfilePipeline(
                certificateParser: certificateParser,
                clock: clock,
                identityStore: identityStore
            ),
            writer: writer,
            limits: limits
        )
    }

    /// Builds the library use case over the selected persistence
    /// implementations: a versioned catalog file for records, and
    /// application-owned artifact storage fed from the intake's staging
    /// directory for the bytes behind them. Nothing is created on disk at
    /// composition time; both stores create their directories on first use.
    private static func makeApplicationLibrary(intake: SecurityScopedArtifactIntake) -> ApplicationLibrary {
        ApplicationLibrary(
            records: FileApplicationRecordStore(catalogLocation: libraryCatalogLocation),
            artifacts: FileLibraryArtifactStore(
                stagingDirectory: intake.directory,
                libraryDirectory: libraryArtifactDirectory,
                fileExtension: intake.fileExtension
            )
        )
    }

    /// The application-owned temporary directory user-selected packages are
    /// staged into. The directory is created on first use by the intake;
    /// nothing is created at composition time.
    private static var importStagingDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ZynSignImports", isDirectory: true)
    }

    /// The root of durable library storage, inside the application
    /// container's Application Support directory: a location the system
    /// does not purge, private to the application, and covered by the
    /// container's default file protection.
    private static var libraryRootDirectory: URL {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport.appendingPathComponent("ZynSignLibrary", isDirectory: true)
    }

    /// The catalog file holding every library record.
    private static var libraryCatalogLocation: URL {
        libraryRootDirectory.appendingPathComponent("catalog.json", isDirectory: false)
    }

    /// The directory adopted artifacts are kept in, named by identifier.
    private static var libraryArtifactDirectory: URL {
        libraryRootDirectory.appendingPathComponent("Artifacts", isDirectory: true)
    }
}
