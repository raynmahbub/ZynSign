import Foundation

/// What the platform observed about a selected document before any of it was
/// copied.
///
/// The description exists so the pre-import checks can refuse a selection
/// before ZynSign spends storage on it, and so a refusal can say what was
/// actually observed rather than only that the import failed. Every field is
/// an observation, never a claim: the description says a file is 4 MiB and
/// begins with an archive signature, which is not evidence that the archive
/// is valid, readable in full, or an application package at all. Only the
/// archive boundary and the metadata examination decide that, and they decide
/// it about the copied bytes.
struct ImportSourceDescription: Equatable, Sendable {

    /// What kind of thing the platform reported at the selected location.
    enum Kind: Equatable, Sendable {

        /// A regular file.
        case regularFile

        /// A directory, which cannot be imported.
        case directory

        /// The platform could not say — a provider placeholder, a package
        /// directory presented as a document, or a link. The description
        /// never guesses: an unknown kind is passed on as unknown, and the
        /// copy that follows settles the question.
        case unknown
    }

    /// The selected document's name, when the platform reported one. A
    /// display and diagnostic label: never a path, never resolved against
    /// anything, and never trusted for a decision.
    let fileName: String?

    /// The document's size in bytes, when the platform reported one. `nil`
    /// means the size was not available at description time.
    let byteCount: Int?

    /// What the platform reported the location to be.
    let kind: Kind

    /// Whether the document's first bytes are one of the signatures a ZIP
    /// container can begin with.
    ///
    /// `nil` means the leading bytes could not be read through any route the
    /// platform offers — a provider that vends its content only through a
    /// coordinated read, for example. Unknown is not failure: the pre-import
    /// checks refuse a document that *begins with something that is not an
    /// archive signature*, and let the archive boundary decide when nothing
    /// could be observed.
    let beginsWithArchiveSignature: Bool?
}

/// The boundary through which a user-selected document becomes a staged
/// application-owned package archive.
///
/// Selecting a document with the platform's document APIs is a platform
/// concern: the resulting URL is a transient grant, it may require
/// security-scoped access, it is not guaranteed to stay reachable, and it is
/// never a place ZynSign stores anything. This port hides all of that behind
/// three operations — describe, stage, and discard — so the application layer
/// never sees a security scope, a provider identity, or a storage location.
///
/// **The selected document is only ever read.** Staging copies the document's
/// bytes into application-owned storage; nothing in this port opens the
/// selected document for writing, moves it, renames it, changes its
/// attributes, or deletes it. An import that fails, is cancelled, or is
/// refused leaves the user's file exactly as it was found, and that guarantee
/// belongs to this boundary — no caller above it has the means to touch the
/// original.
///
/// Staging copies the document's bytes, exactly once, into a unique
/// application-owned location that is named only by the artifact's own
/// identifier. After staging succeeds, the archive is reachable through the
/// established archive-reader boundary for that identifier and through
/// nothing else; the selected document's URL is not retained, persisted, or
/// used again by this boundary.
///
/// Lifecycle, **explicit**:
///
/// - A staged archive is owned by the import flow that created it. It is
///   discarded by that flow when the import fails, is cancelled, or the
///   package is rejected by examination.
/// - A staged archive for an accepted import is retained deliberately, for
///   the lifetime of the result that holds it, and must be released through
///   `discardStagedDocument(for:)` when the result is dropped or replaced.
///   There is no third path: nothing staged survives implicitly.
/// - Files left behind by a process that ended without releasing them are
///   cleared by the implementation before the first staging of a new
///   process; they are never silently kept indefinitely.
///
/// The port is declared by the layer that consumes it and implemented in the
/// platform layer, keeping security-scoped access out of the application and
/// domain layers entirely.
protocol ArtifactIntake: AnyObject {

    /// Describes the document the user selected without copying any of it.
    ///
    /// The description is used by the pre-import checks, which refuse a
    /// selection before ZynSign spends storage on it. It either completes or
    /// throws; a thrown error leaves nothing behind, because nothing was
    /// created.
    ///
    /// Implementations acquire and release access for the duration of this
    /// one call, exactly as staging does, and never hold a grant.
    func describeDocument(at source: URL) throws -> ImportSourceDescription

    /// Stages the document the user selected as the archive of `artifact`.
    ///
    /// On return, the document's bytes have been copied into
    /// application-owned temporary storage under `artifact`'s identifier.
    /// The method either completes or throws; a thrown error leaves nothing
    /// behind — including a partially copied file — so callers never need to
    /// clean up after a failed staging.
    ///
    /// - Parameters:
    ///   - source: the selected document. Read only.
    ///   - artifact: the identifier the staged copy is named by.
    ///   - progress: where the copy reports how many bytes it has written,
    ///     or `nil` when the caller does not want progress. Reports are
    ///     produced on the copying thread and may be dropped or coalesced
    ///     without affecting the copy.
    ///
    /// Cancellation is honoured: when the surrounding task is cancelled, the
    /// method stops as early as it can, removes what it has written, and
    /// throws a cancelled error.
    func stageDocument(
        at source: URL,
        as artifact: ArtifactIdentifier,
        reporting progress: (any ImportProgressReporting)?
    ) throws

    /// Discards the staged archive for `artifact`, if one is present.
    /// Idempotent: discarding an identifier with no staged archive does
    /// nothing and does not fail.
    func discardStagedDocument(for artifact: ArtifactIdentifier)
}

extension ArtifactIntake {

    /// Stages the document without reporting progress.
    ///
    /// A convenience for callers that do not show progress — the single
    /// package import path, and the tests — so that adding progress
    /// reporting did not add a parameter to every call site.
    func stageDocument(at source: URL, as artifact: ArtifactIdentifier) throws {
        try stageDocument(at: source, as: artifact, reporting: nil)
    }
}
