import Foundation

/// The boundary through which a user-selected document becomes a staged
/// application-owned package archive.
///
/// Selecting a document with the platform's document APIs is a platform
/// concern: the resulting URL is a transient grant, it may require
/// security-scoped access, it is not guaranteed to stay reachable, and it is
/// never a place ZynSign stores anything. This port hides all of that behind
/// two operations — stage, and discard — so the application layer never sees
/// a security scope, a provider identity, or a storage location.
///
/// Staging copies the document's bytes, exactly once, into a unique
/// application-owned location that is named only by the artifact's own
/// identifier. After staging succeeds, the archive is reachable through the
/// established archive-reader boundary for that identifier and through
/// nothing else; the selected document's URL is not retained, persisted, or
/// used again.
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

    /// Stages the document the user selected as the archive of `artifact`.
    ///
    /// On return, the document's bytes have been copied into
    /// application-owned temporary storage under `artifact`'s identifier.
    /// The method either completes or throws; a thrown error leaves nothing
    /// behind — including a partially copied file — so callers never need to
    /// clean up after a failed staging.
    ///
    /// Cancellation is honoured: when the surrounding task is cancelled, the
    /// method stops as early as it can, removes what it has written, and
    /// throws a cancelled error.
    func stageDocument(at source: URL, as artifact: ArtifactIdentifier) throws

    /// Discards the staged archive for `artifact`, if one is present.
    /// Idempotent: discarding an identifier with no staged archive does
    /// nothing and does not fail.
    func discardStagedDocument(for artifact: ArtifactIdentifier)
}
