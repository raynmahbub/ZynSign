import Foundation

/// Receives progress from an import as the import produces it.
///
/// Progress is produced on whichever context the work runs on — the copy
/// loop, the archive reader, the library actor — so implementations are
/// called from more than one thread and must be safe to call concurrently.
/// Declaring the receiver as a type rather than a closure is what lets a
/// synchronous worker report synchronously, which matters for the staged
/// copy: its chunk loop runs inside a file-coordination accessor that cannot
/// suspend, so an `async` callback could not be called from it at all.
///
/// Reporting is advisory. An implementation that drops reports, coalesces
/// them, or delivers them out of order changes only what the interface shows;
/// it cannot change what the import does.
protocol ImportProgressReporting: AnyObject, Sendable {

    /// Reports the import's current stage and, where the stage measures work,
    /// how much of it is done.
    func report(_ progress: ImportProgress)
}

/// Asks what to do about a package the library already appears to hold.
///
/// The provider is called only when the comparison found a collision worth
/// deciding — identical content, or the same application declaring the same
/// version and build. It may suspend for as long as it takes the user to
/// answer, which is why it is `async` and why the import pipeline holds
/// nothing open while it waits: the staged copy simply remains staged, and
/// nothing has been written to the library yet.
typealias DuplicateDecisionProvider = @Sendable (DuplicateReport) async -> DuplicateResolution

/// The boundary the import queue drives: one package, imported once.
///
/// The port exists so the queue — which owns scheduling, retries, and the
/// user's duplicate decisions — depends on the *capability* of importing a
/// package rather than on the concrete pipeline. `IPAPackageImport` is the
/// capability's only production implementation, and a test can substitute a
/// controllable one without a filesystem, an archive, or a library.
protocol PackageImporting {

    /// Imports the package the user selected and returns the examined
    /// artifact together with the library's decision.
    ///
    /// - Parameters:
    ///   - source: the URL the platform vended for the selected document.
    ///     Read only; it is never written to, moved, or modified.
    ///   - progress: where the import reports what it is doing, or `nil` when
    ///     the caller does not want progress.
    ///   - duplicateDecision: how the caller answers a duplicate collision,
    ///     or `nil` to let the library's own duplicate policy decide.
    ///
    /// A rejected package is a result, not an exception. Only intake, library,
    /// and infrastructure failures throw, and they throw typed errors.
    func importArtifact(
        from source: URL,
        reporting progress: (any ImportProgressReporting)?,
        resolvingDuplicatesWith duplicateDecision: DuplicateDecisionProvider?
    ) async throws -> PackageImportResult
}
