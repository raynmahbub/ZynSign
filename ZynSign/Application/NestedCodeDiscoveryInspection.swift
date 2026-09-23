import Foundation

/// The nested-code discovery use case: it locates the executable content of a
/// library application's bundle and derives the deterministic signing order
/// for it.
///
/// The library keeps each application as the package it was imported from, so
/// the bundle lives inside that container and is reached through the same
/// archive boundary import, inspection, and bundle metadata already use. This
/// use case looks the record up, confirms the library still holds the package
/// the record vouches for, opens it, reads the entry table once, finds the
/// single application bundle, and hands the table and the bundle's location to
/// the domain rule, which decides what is code, what is not, what it cannot
/// establish, and in which order the code it did establish would have to be
/// finalized.
///
/// Four properties are deliberate.
///
/// **It is read-only.** Nothing on this path writes: no entry is extracted, no
/// binary is modified, no signature is produced or updated, and no key is
/// reached. The result is a plan — descriptive data a later stage could
/// execute — and this increment does not execute it.
///
/// **It reads one table and a bounded set of candidates.** The entry table is
/// metadata, so enumerating a bundle whose files are huge costs no more than
/// enumerating one whose files are small. Content is read only at the
/// locations the domain rule names as candidates, only within the discovery
/// policy's bounds, and only through the archive boundary — the whole bundle is
/// never expanded.
///
/// **It concludes nothing about trust.** An existing signature is reported in
/// the same structural terms the read-only parser uses. A plan says nothing
/// about cryptographic validity, certificate trust, provisioning
/// authorization, or installability, and no caller may read it as such.
///
/// **It does not use a provisioning profile.** Discovery is driven by the
/// bundle's structure alone. Profile parsing, validation, and policy evaluation
/// are separate layers, and nothing here consults them: a profile neither
/// identifies nested code nor authorizes the order.
///
/// Errors are typed. A record that is gone, a package the library no longer
/// holds, a package that has changed since import, a container that cannot be
/// read, a package with no single application bundle, and a bundle discovery
/// rejects each reach the caller as a distinct `ZynSignError`; anything else is
/// normalised into one so that no foreign error text reaches the presentation
/// layer.
struct NestedCodeDiscoveryInspection {

    private let library: ApplicationLibrary
    private let readerProvider: any ArtifactArchiveReaderProvider
    private let parser: any MachOParsing
    private let archiveLimits: ArchiveLimits
    private let limits: NestedCodeDiscoveryLimits

    /// Creates the use case over the library, the archive boundary, and the
    /// parser the composition root selected.
    init(
        library: ApplicationLibrary,
        readerProvider: any ArtifactArchiveReaderProvider,
        parser: any MachOParsing = ReadOnlyMachOParser(),
        archiveLimits: ArchiveLimits = .default,
        limits: NestedCodeDiscoveryLimits = .default
    ) {
        self.library = library
        self.readerProvider = readerProvider
        self.parser = parser
        self.archiveLimits = archiveLimits
        self.limits = limits
    }

    /// Discovers the nested code of the application recorded under `id` and
    /// returns the plan a later stage would execute.
    ///
    /// The reader is closed on every path, including failure and cancellation.
    /// Cancellation is honoured before the library is consulted, before the
    /// table is interpreted, and after discovery, because nothing here needs to
    /// run to completion: discovering reads and changes nothing.
    func discoverNestedCode(recordWithID id: ApplicationRecordIdentifier) async throws -> NestedCodeSigningPlan {
        do {
            try Task.checkCancellation()

            guard let entry = try await library.entry(withID: id) else {
                throw ZynSignError.libraryRecordNotFound(
                    diagnosticDetail: "No record '\(id.rawValue)' exists to discover nested code for."
                )
            }
            switch entry.artifactAvailability {
            case .available:
                break
            case .missing:
                throw ZynSignError.bundleArtifactMissing(
                    diagnosticDetail: "The library holds no artifact '\(entry.record.artifact.artifactID.rawValue)' for record '\(id.rawValue)'."
                )
            case .inconsistent(let recorded, let observed):
                throw ZynSignError.bundleArtifactInconsistent(
                    diagnosticDetail: "Artifact '\(entry.record.artifact.artifactID.rawValue)' holds \(observed) bytes; record '\(id.rawValue)' expects \(recorded)."
                )
            }

            let record = entry.record
            let reader = try readerProvider.archiveReader(for: record.artifact.artifactID)
            defer { reader.close() }

            let entryTable = try reader.readEntryTable()
            try Task.checkCancellation()

            // The application's own bundle location is the import stage's
            // conclusion, re-derived from the same table so that a package
            // whose payload changed after import cannot be discovered as a
            // different bundle than the one inspection admitted.
            let bundlePath: ArchivePath
            switch ApplicationBundleDiscovery.discover(in: entryTable).outcome {
            case .exactlyOne(let discovered):
                bundlePath = discovered
            case .ambiguous(let candidates):
                throw ZynSignError.ambiguousArtifact(
                    diagnosticDetail: "The package for record '\(id.rawValue)' holds \(candidates.count) application bundles in its payload directory."
                )
            case .missingPayloadDirectory, .none:
                throw ZynSignError.missingApplicationBundle(
                    diagnosticDetail: "The package for record '\(id.rawValue)' holds no application bundle in its payload directory."
                )
            }

            // The application's own declared identity comes from the record:
            // the metadata stage already read and validated the bundle's
            // information file, so discovery does not read it a second time.
            // Every value below is a declaration, and none of them is treated
            // as authorization to sign anything.
            let request = NestedCodeDiscoveryRequest(
                bundlePath: bundlePath,
                applicationIdentity: NestedCodeBundleIdentity(
                    bundleIdentifier: record.bundleIdentifier,
                    executableName: record.executableName,
                    packageType: nil,
                    shortVersionString: record.identity.shortVersionString,
                    buildVersion: record.identity.buildVersion
                )
            )

            let source = ArchiveNestedCodeInspectionSource(
                reader: reader,
                parser: parser,
                limits: archiveLimits
            )
            let outcome = NestedCodeDiscovery.discover(
                entryTable: entryTable,
                request: request,
                limits: limits,
                source: source
            )
            try Task.checkCancellation()

            switch outcome {
            case .plan(let plan):
                return plan
            case .rejected(let error):
                throw ZynSignError.nestedCodeDiscovery(error)
            }
        } catch {
            throw Self.normalized(error)
        }
    }

    /// Passes ZynSign's own errors and cancellation through unchanged and
    /// wraps anything else, so that callers never see a foreign error and no
    /// platform error text is presented as a fact about the package.
    private static func normalized(_ error: any Error) -> any Error {
        if error is ZynSignError || error is CancellationError {
            return error
        }
        return ZynSignError.bundleInspectionFailure(
            diagnosticDetail: "Nested-code discovery failed with \(String(describing: type(of: error))).",
            underlyingError: error
        )
    }
}
