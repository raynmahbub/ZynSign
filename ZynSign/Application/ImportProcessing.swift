import Foundation

/// Where an Import Hub item's working copy comes from.
enum ImportStagingSource: Equatable, Hashable, Sendable {

    /// A document the user chose, dropped, shared, or opened in ZynSign.
    /// It is only ever read.
    case document(URL)

    /// A package inside an archive whose working copy ZynSign already
    /// holds.
    case archiveEntry(container: ArtifactIdentifier, candidate: NestedPackageCandidate)
}

/// A working copy the Import Hub's workflow made, in ZynSign's own staging
/// area, under an identifier ZynSign chose.
struct StagedImport: Equatable, Hashable, Sendable {

    /// The working copy's identifier.
    let artifactID: ArtifactIdentifier

    /// The name of the file (or archive entry) it was copied from, for
    /// display and for the library record.
    let fileName: String

    /// The working copy's size, when known.
    let byteCount: Int?
}

/// A package that passed validation and analysis and waits in the Import
/// Hub's preview for the user's decision.
///
/// Holding a prepared import changes nothing: its working copy is staged,
/// the library is untouched, and the file it came from was never modified.
struct PreparedImport: Equatable {

    /// The examined, accepted artifact.
    let artifact: IPAArtifact

    /// The identity the package declares.
    let identity: ApplicationIdentity

    /// The working copy's size and content fingerprint, measured once.
    let reference: ArtifactReference

    /// What was learned from the package's contents.
    let analysis: ApplicationAnalysis

    /// The application's icon image data, when one could be read.
    let iconData: Data?

    /// The conflict the package raises against the library, if any. The
    /// package cannot be stored until the user resolves it.
    let conflict: ImportConflict?

    /// The working copy's identifier.
    var artifactID: ArtifactIdentifier { artifact.id }

    /// The working copy's size, in bytes.
    var byteCount: Int { reference.byteCount }
}

/// What examining a working copy found.
enum ImportExamination: Equatable {

    /// An application package, validated and analyzed.
    case package(PreparedImport)

    /// An archive holding packages the user can choose from. Always
    /// non-empty; an archive with none is refused instead.
    case archive([NestedPackageCandidate])
}

/// The per-item work the Import Hub schedules.
///
/// Each step runs off the main actor and either completes or leaves
/// nothing behind but the working copy it was given. No step ever writes to
/// the user's original file, and only `admit` changes the library.
protocol ImportProcessing: Sendable {

    /// Checks a source and makes ZynSign's own working copy of it as
    /// `artifact`, refusing before anything is copied when the source is
    /// unacceptable or the device lacks the space.
    func stage(
        _ source: ImportStagingSource,
        fileName: String,
        as artifact: ArtifactIdentifier,
        reporting progress: (any ImportProgressReporting)?
    ) async throws -> StagedImport

    /// Validates a working copy and, for a package, analyzes it and
    /// compares it with the library. Refusals are thrown as
    /// `ImportFailure`s that explain themselves.
    func examine(
        _ staged: StagedImport,
        reporting progress: (any ImportProgressReporting)?
    ) async throws -> ImportExamination

    /// Stores a prepared package in the library according to `resolution`,
    /// which must be present when the package has a conflict. Skipping
    /// stores nothing. The working copy is always consumed.
    func admit(
        _ prepared: PreparedImport,
        resolution: ConflictResolution?,
        reporting progress: (any ImportProgressReporting)?
    ) async throws -> ImportSettlement

    /// Removes a working copy. Removing one that does not exist does
    /// nothing.
    func discardWorkingCopy(_ artifact: ArtifactIdentifier)

    /// The size of a working copy that survived, or `nil` when there is
    /// none — how an interrupted import finds out whether it can resume.
    func workingCopyByteCount(_ artifact: ArtifactIdentifier) -> Int?

    /// Removes every working copy except `artifacts`.
    func sweepWorkingCopies(keeping artifacts: Set<ArtifactIdentifier>)

    /// The free space available for working copies, when the platform can
    /// report it.
    func availableCapacity() -> Int?
}
