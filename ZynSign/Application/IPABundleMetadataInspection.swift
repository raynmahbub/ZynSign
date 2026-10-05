import Foundation

/// The bundle metadata inspection use case.
///
/// Structural inspection (`IPAArchiveInspection`) reads a container's entry
/// table only. This use case performs the content-level half of the
/// inspection stage for an artifact that structural inspection has
/// established: it reads exactly one entry — the bundle's information file —
/// within the configured bound, hands its bytes to the domain's metadata
/// reader, resolves the declared executable against the entry table, and
/// records the outcome on the artifact.
///
/// Two properties are deliberate.
///
/// It never throws, and it never reads more than it needs. Every outcome
/// arrives as an updated artifact carrying typed findings; the only content
/// read is the bundle's information file, produced within the policy bound,
/// and no entry is extracted to any filesystem.
///
/// It grants no trust. Recorded metadata is a statement of what the bundle's
/// information file declares; it is not evidence that the application is
/// signed, genuine, or installable. A structurally valid package whose
/// declared metadata fails validation becomes `invalid` — its metadata is
/// never guessed — and an artifact that has not passed structural
/// examination is returned unchanged, because there is no established bundle
/// to read.
struct IPABundleMetadataInspection {

    private let readerProvider: any ArtifactArchiveReaderProvider
    private let limits: ArchiveLimits

    /// Creates the use case with the archive boundary the composition root
    /// selected and the resource policy to apply.
    init(
        readerProvider: any ArtifactArchiveReaderProvider,
        limits: ArchiveLimits = .default
    ) {
        self.readerProvider = readerProvider
        self.limits = limits
    }

    /// Examines the declared metadata of the artifact's established bundle
    /// and returns the artifact with the outcome recorded.
    ///
    /// The reader is closed on every path, including failure.
    func inspect(_ artifact: IPAArtifact) -> IPAArtifact {
        guard artifact.permitsLaterStages, let bundle = artifact.discoveredBundle else {
            return artifact
        }
        let reader: any ArchiveReader
        do {
            reader = try readerProvider.archiveReader(for: artifact.id)
        } catch {
            return recordFailure(
                on: artifact,
                code: .unreadableArchive,
                detail: "No archive could be opened for artifact '\(artifact.id.rawValue)': \(Self.diagnosticSummary(of: error))"
            )
        }
        defer { reader.close() }
        return inspectBundle(artifact, bundle: bundle, reader: reader)
    }

    private func inspectBundle(
        _ artifact: IPAArtifact,
        bundle: ApplicationBundle,
        reader: any ArchiveReader
    ) -> IPAArtifact {
        let entryTable: [ArchiveEntry]
        do {
            entryTable = try reader.readEntryTable()
        } catch {
            return recordFailure(
                on: artifact,
                code: .unreadableArchive,
                detail: "The archive for artifact '\(artifact.id.rawValue)' could not be enumerated: \(Self.diagnosticSummary(of: error))"
            )
        }
        let kindsByPath = Self.kinds(byPath: entryTable)
        guard let informationPath = checkedInformationPath(for: bundle, kindsByPath: kindsByPath) else {
            return recordInformationPathFailure(for: bundle, artifact: artifact, kindsByPath: kindsByPath)
        }
        let infoPlistData: Data
        do {
            infoPlistData = try reader.readEntryData(
                at: informationPath,
                maximumBytes: limits.maximumInspectionReadBytes
            )
        } catch {
            return recordFailure(
                on: artifact,
                code: .unreadableInfoPlist,
                detail: "The bundle information file at '\(informationPath)' could not be read: \(Self.diagnosticSummary(of: error))",
                location: informationPath
            )
        }
        let examination = ApplicationMetadataReader.read(from: infoPlistData)
        return recordExamination(
            examination,
            on: artifact,
            bundle: bundle,
            informationPath: informationPath,
            kindsByPath: kindsByPath
        )
    }

    private func checkedInformationPath(
        for bundle: ApplicationBundle,
        kindsByPath: [ArchivePath: ArchiveEntryKind]
    ) -> ArchivePath? {
        guard let informationPath = IPALayout.bundleInformationPath(within: bundle.bundlePath),
              kindsByPath[informationPath] == .regularFile else {
            return nil
        }
        return informationPath
    }

    private func recordInformationPathFailure(
        for bundle: ApplicationBundle,
        artifact: IPAArtifact,
        kindsByPath: [ArchivePath: ArchiveEntryKind]
    ) -> IPAArtifact {
        guard let informationPath = IPALayout.bundleInformationPath(within: bundle.bundlePath) else {
            return recordFailure(
                on: artifact,
                code: .missingInfoPlist,
                detail: "The location of the bundle information file for '\(bundle.bundlePath)' is not a representable archive path."
            )
        }
        switch kindsByPath[informationPath] {
        case .none:
            return recordFailure(
                on: artifact,
                code: .missingInfoPlist,
                detail: "The application bundle at '\(bundle.bundlePath)' records no '\(IPALayout.bundleInformationFileName)'.",
                location: informationPath
            )
        case .some(let kind):
            return recordFailure(
                on: artifact,
                code: .missingInfoPlist,
                detail: "The bundle information file at '\(informationPath)' is \(kind.displayName) rather than a regular file.",
                location: informationPath
            )
        }
    }

    private func recordExamination(
        _ examination: ApplicationMetadataExamination,
        on artifact: IPAArtifact,
        bundle: ApplicationBundle,
        informationPath: ArchivePath,
        kindsByPath: [ArchivePath: ArchiveEntryKind]
    ) -> IPAArtifact {
        var findings = examination.findings.map {
            ValidationFinding(severity: $0.severity, code: $0.code, detail: $0.detail, location: informationPath)
        }
        let updatedBundle: ApplicationBundle
        if let metadata = examination.metadata {
            updatedBundle = updatingBundle(bundle, metadata: metadata, kindsByPath: kindsByPath, findings: &findings)
        } else {
            updatedBundle = bundle
        }
        let structuralFindings = artifact.validation?.findings ?? []
        let allFindings = structuralFindings + findings
        let validation = ValidationResult(
            classification: IPAStructureValidator.classification(for: allFindings),
            findings: allFindings
        )
        return artifact.metadataExamined(
            bundle: updatedBundle,
            metadata: examination.metadata,
            validation: validation
        )
    }

    private func updatingBundle(
        _ bundle: ApplicationBundle,
        metadata: ApplicationMetadata,
        kindsByPath: [ArchivePath: ArchiveEntryKind],
        findings: inout [ValidationFinding]
    ) -> ApplicationBundle {
        let executablePath = resolvedExecutablePath(
            metadata.executableName,
            within: bundle.bundlePath,
            kindsByPath: kindsByPath,
            findings: &findings
        )
        do {
            return try ApplicationBundle(
                bundlePath: bundle.bundlePath,
                identity: metadata.identity,
                executablePath: executablePath
            )
        } catch {
            // Structural validation already accepted this bundle path.
            return bundle
        }
    }

    private func resolvedExecutablePath(
        _ executableName: String?,
        within bundlePath: BundlePath,
        kindsByPath: [ArchivePath: ArchiveEntryKind],
        findings: inout [ValidationFinding]
    ) -> ArchivePath? {
        guard let executableName,
              let candidate = bundlePath.appending(component: executableName) else {
            return nil
        }
        guard kindsByPath[candidate] == .regularFile else {
            findings.append(ValidationFinding(
                severity: .error,
                code: .missingExecutable,
                detail: "The declared executable '\(executableName)' is not a regular file inside the bundle at '\(candidate)'.",
                location: candidate
            ))
            return nil
        }
        return candidate
    }

    // MARK: - Failure recording

    /// Records a metadata-examination failure on the artifact, merging the
    /// finding with whatever structural examination already established.
    private func recordFailure(
        on artifact: IPAArtifact,
        code: ValidationIssueCode,
        detail: String,
        location: ArchivePath? = nil
    ) -> IPAArtifact {
        let finding = ValidationFinding(severity: .error, code: code, detail: detail, location: location)
        let structuralFindings = artifact.validation?.findings ?? []
        let validation = ValidationResult(
            classification: IPAStructureValidator.classification(for: structuralFindings + [finding]),
            findings: structuralFindings + [finding]
        )
        return artifact.metadataExamined(
            bundle: artifact.discoveredBundle,
            metadata: nil,
            validation: validation
        )
    }

    /// The recorded kind of each accepted path in an entry table.
    ///
    /// Structural examination has already rejected duplicate and conflicting
    /// paths, so first recorded kind wins defensively.
    private static func kinds(byPath table: [ArchiveEntry]) -> [ArchivePath: ArchiveEntryKind] {
        var kinds: [ArchivePath: ArchiveEntryKind] = [:]
        for entry in table {
            if let path = entry.path, kinds[path] == nil {
                kinds[path] = entry.kind
            }
        }
        return kinds
    }

    /// A log-safe one-line summary of a failure.
    ///
    /// Only ZynSign's own errors are described in full, because their
    /// rendering is written to be free of sensitive and filesystem detail.
    /// Anything else is reduced to its type name, so an arbitrary platform
    /// error — which may carry a path, a provider identity, or another
    /// implementation detail — cannot enter a finding.
    private static func diagnosticSummary(of error: any Error) -> String {
        if let zynSignError = error as? ZynSignError {
            return zynSignError.description
        }
        return String(describing: type(of: error))
    }
}
