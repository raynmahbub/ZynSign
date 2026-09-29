import Foundation

/// Inspection: archives, bundles, profiles, and the import hub.
///
/// Part of `CompositionRoot`, which chooses every concrete
/// implementation and wires the layers together. Split out of the
/// original single file for readability; the members are unchanged.
extension CompositionRoot {

    /// Builds the Binary & Signature Inspector use case over the given
    /// library.
    ///
    /// The archive boundary reads library storage under the same file
    /// extension and resource policy as the other artifact-facing use cases,
    /// except for the single-read bound, which is widened to the inspector's
    /// executable bound: executables are routinely larger than the 4 MiB
    /// metadata reads the default policy allows. The per-entry and total
    /// ceilings still apply. Signed packages are opened only from the Export
    /// Center's artifact directory, for comparison. The parser, decoder, digest,
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
            readerProvider: cachingLibraryReaderProvider(fileExtension: intake.fileExtension, limits: readerLimits),
            makePackageReader: { ZipArchiveReader(location: $0, limits: readerLimits) },
            signedPackagesDirectory: exportArtifactDirectory(),
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

    /// Builds the Resource & Asset Studio inspection use case: inspects app
    /// icons, launch assets, images, fonts, media, and localization tables in
    /// an imported IPA bundle, completely read-only.
    static func makeResourceStudioInspection(
        library: ApplicationLibrary,
        readerProvider: any ArtifactArchiveReaderProvider,
        limits: ArchiveLimits = .default
    ) -> IPAResourceStudioInspection {
        IPAResourceStudioInspection(
            library: library,
            readerProvider: readerProvider,
            limits: limits
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
        AppIconExtraction(
            readerProvider: cachingLibraryReaderProvider(),
            cacheDirectory: cachesDirectory.appendingPathComponent("ZynSignAppIcons", isDirectory: true)
        )
    }

    /// Builds the Smart Import Hub over the same intake and library the rest
    /// of the application uses.
    ///
    /// The hub's workflow reads staged working copies through a provider
    /// bound to the staging directory and library storage — the same
    /// convention as the one-shot import — checks free space on the staging
    /// volume before every copy, primes the icon cache as each package is
    /// admitted, and hands each admitted record to the signing diagnostics,
    /// as the one-shot import does. History and the interrupted-import journal
    /// live beside the library catalog in Application Support. Nothing is
    /// read or written at composition time: the hub restores interrupted
    /// imports only when the interface asks it to at launch.
    static func makeImportHub(
        intake: SecurityScopedArtifactIntake,
        library: ApplicationLibrary,
        appIcons: AppIconExtraction?,
        droppedFiles: (any DroppedFileReceiving)?,
        diagnostics: SigningDiagnosticsService? = nil,
        limits: ArchiveLimits = .default
    ) -> ImportHub {
        let readerProvider = DirectoryArtifactArchiveReaderProvider(
            directories: [libraryArtifactDirectory, intake.directory],
            fileExtension: intake.fileExtension,
            limits: limits
        )
        let workflow = ImportWorkflow(
            intake: intake,
            stagingArea: intake,
            readerProvider: readerProvider,
            library: library,
            storage: ImportStorageGuard(
                probe: VolumeStorageCapacityProbe(volume: FileManager.default.temporaryDirectory)
            ),
            limits: limits,
            onAdmitted: { prepared, record in
                if let iconData = prepared.iconData {
                    await appIcons?.remember(iconData, for: record.artifact.artifactID)
                }
                if let diagnostics {
                    // As in the one-shot import: scan the adopted copy at
                    // utility priority without making the import wait for
                    // Mach-O/CMS inspection. The dashboard also scans on
                    // opening if this task is suspended.
                    let recordID = record.id
                    Task.detached(priority: .utility) {
                        _ = try? await diagnostics.analyze(recordWithID: recordID)
                    }
                }
            }
        )
        return ImportHub(
            processing: workflow,
            history: FileImportHistoryStore(
                location: libraryRootDirectory.appendingPathComponent("ImportHistory.json", isDirectory: false)
            ),
            recoveryJournal: FileImportRecoveryJournal(
                location: libraryRootDirectory.appendingPathComponent("ImportRecovery.json", isDirectory: false)
            ),
            backgroundExecution: UIKitImportBackgroundExecution(),
            releaseSource: { url in droppedFiles?.release(url) }
        )
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
        limits: ArchiveLimits = .default,
        diagnostics: SigningDiagnosticsService? = nil
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
            limits: limits,
            diagnostics: diagnostics
        )
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
    static func makeCMSSignatureVerifier() -> any CMSSignatureVerifier {
        #if os(iOS)
        return AppleCMSSignatureVerifier()
        #else
        return UnavailableCMSSignatureVerifier()
        #endif
    }

    /// Builds the on-demand entry preview the IPA explorer uses when the user
    /// opens a file. It shares the library artifact directory and the default
    /// resource policy with structure inspection. Preview reads are bounded
    /// and read-only; this factory wires no writer.
    static func makeBundleEntryInspection(
        intake: SecurityScopedArtifactIntake,
        library: ApplicationLibrary,
        limits: ArchiveLimits = .default
    ) -> IPABundleEntryInspection {
        IPABundleEntryInspection(
            library: library,
            readerProvider: cachingLibraryReaderProvider(fileExtension: intake.fileExtension, limits: limits),
            limits: limits
        )
    }

    /// Builds the bundle contents inspection use case over the given library,
    /// selecting the concrete archive implementation.
    ///
    /// The explorer describes applications the library holds, so its archive
    /// boundary reads library storage only, under the same file-extension
    /// convention and the same resource policy as import. It is the same
    /// reader implementation import uses, chosen here and nowhere below.
    /// Structure listing reads a package's entry table and never writes.
    static func makeBundleContentsInspection(
        intake: SecurityScopedArtifactIntake,
        library: ApplicationLibrary,
        limits: ArchiveLimits = .default
    ) -> IPABundleContentsInspection {
        IPABundleContentsInspection(
            library: library,
            readerProvider: cachingLibraryReaderProvider(fileExtension: intake.fileExtension, limits: limits),
            entitlementReaderProvider: DirectoryArtifactArchiveReaderProvider(
                directory: libraryArtifactDirectory,
                fileExtension: intake.fileExtension,
                limits: ArchiveLimits(
                    maximumEntryCount: limits.maximumEntryCount,
                    maximumEntryNameLength: limits.maximumEntryNameLength,
                    maximumPathDepth: limits.maximumPathDepth,
                    maximumEntryBytes: limits.maximumEntryBytes,
                    maximumTotalUncompressedBytes: limits.maximumTotalUncompressedBytes,
                    maximumCompressionRatio: limits.maximumCompressionRatio,
                    maximumInspectionReadBytes: EntitlementsStudioInspection.maximumExecutableBytes
                )
            ),
            machOParser: ReadOnlyMachOParser()
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
            readerProvider: cachingLibraryReaderProvider(fileExtension: intake.fileExtension, limits: readerLimits),
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
}
