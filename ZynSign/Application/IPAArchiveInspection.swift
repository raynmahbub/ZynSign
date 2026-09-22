import Foundation

/// The inspection use case: it examines one imported package's archive
/// structure and records what it established.
///
/// This is the first workflow capability the application layer coordinates. It
/// composes the archive boundary with the domain's structural rules and
/// produces an examined artifact. It performs no signing, no verification, no
/// packaging, and no installation, and it grants no trust: an examined
/// artifact whose classification is `valid` has satisfied structural rules
/// only.
///
/// Two properties are deliberate.
///
/// Examination never extracts. It reads the container's entry table — metadata
/// only — and classifies the package from it. No entry is written to any
/// filesystem, and no temporary directory is created, because structural
/// validity does not require one. Extraction belongs to a later workflow that
/// will establish its own safe boundary and its own lifecycle.
///
/// Examination never throws. A structurally unsuitable package is a result, not
/// an exception: every outcome arrives as an examined artifact carrying typed
/// findings, so the presentation layer renders one shape rather than handling
/// both a value and an error path for the same user action.
struct IPAArchiveInspection {

    private let readerProvider: any ArtifactArchiveReaderProvider
    private let validator: IPAStructureValidator

    /// Creates the use case with the archive boundary the composition root
    /// selected and the resource policy to apply.
    init(
        readerProvider: any ArtifactArchiveReaderProvider,
        limits: ArchiveLimits = .default
    ) {
        self.readerProvider = readerProvider
        self.validator = IPAStructureValidator(limits: limits)
    }

    /// Examines an imported artifact and returns it with the outcome recorded.
    ///
    /// The reader is closed on every path, including failure.
    func inspect(_ artifact: IPAArtifact) -> IPAArtifact {
        let reader: any ArchiveReader
        do {
            reader = try readerProvider.archiveReader(for: artifact.id)
        } catch {
            return reject(
                artifact,
                code: .unreadableArchive,
                detail: "No archive could be opened for artifact '\(artifact.id.rawValue)': \(Self.diagnosticSummary(of: error))"
            )
        }
        defer { reader.close() }

        let entryTable: [ArchiveEntry]
        do {
            entryTable = try reader.readEntryTable()
        } catch {
            return reject(
                artifact,
                code: .unreadableArchive,
                detail: "The archive for artifact '\(artifact.id.rawValue)' could not be enumerated: \(Self.diagnosticSummary(of: error))"
            )
        }

        let inspection = validator.validate(entryTable: entryTable)
        return artifact.examined(bundle: inspection.bundle, validation: inspection.validation)
    }

    // MARK: - Failure recording

    private func reject(
        _ artifact: IPAArtifact,
        code: ValidationIssueCode,
        detail: String
    ) -> IPAArtifact {
        artifact.examined(
            bundle: nil,
            validation: ValidationResult.invalid(
                findings: [ValidationFinding(severity: .error, code: code, detail: detail)]
            )
        )
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
