/// The boundary through which the library owns the bytes behind its records.
///
/// An import stages a package into temporary storage owned by the import
/// flow. A record needs bytes that outlive the import, the session, and the
/// process, so the library takes ownership of them: it *adopts* the staged
/// archive into durable, application-owned artifact storage, and from then
/// on the record's `ArtifactReference` is the only way the bytes are reached.
/// No provider URL, security-scoped grant, or staging location is retained;
/// none of those is stable, and none appears at this boundary.
///
/// The port hides where artifacts live and how they are moved. Callers name
/// artifacts by identifier and receive domain values and typed errors. The
/// lifecycle it supports:
///
/// - **Describe** a staged archive: measure its size and compute its content
///   fingerprint without moving or modifying it, so the duplicate policy can
///   decide before anything is committed.
/// - **Adopt** a staged archive: move it into library storage under the same
///   identifier. Either the artifact ends up in library storage and is gone
///   from staging, or it stays staged and a typed error is thrown. An
///   identifier already held is never overwritten.
/// - **Observe** an artifact: report whether library storage holds a regular
///   file under the identifier and how large it is. Observation never
///   creates, repairs, or replaces anything.
/// - **Remove** an artifact from library storage. Idempotent.
/// - **Enumerate** the identifiers library storage holds, so that artifacts
///   no record refers to can be detected.
///
/// The port is declared here, by the layer that consumes it, and implemented
/// in the platform layer.
protocol LibraryArtifactStore: Sendable {

    /// Measures the staged archive for `artifact`: its size and its content
    /// fingerprint. Reads the archive once and leaves it in place. Fails
    /// with a typed error when no staged archive is held for the identifier
    /// or the archive cannot be read.
    func describeStagedArtifact(_ artifact: ArtifactIdentifier) throws -> ArtifactReference

    /// Moves the staged archive for `artifact` into library storage. On
    /// return the artifact is held by the library and no longer staged; on a
    /// thrown error nothing has moved. Refuses, with a typed error, to
    /// overwrite an artifact already held under the identifier.
    func adoptStagedArtifact(_ artifact: ArtifactIdentifier) throws

    /// Removes the artifact held for `artifact` from library storage.
    /// Idempotent: an identifier nothing is held under is not a failure.
    func removeArtifact(_ artifact: ArtifactIdentifier) throws

    /// What library storage currently holds under `artifact`.
    func observeArtifact(_ artifact: ArtifactIdentifier) -> StoredArtifactObservation

    /// The identifiers of every artifact library storage currently holds.
    func heldArtifactIdentifiers() throws -> Set<ArtifactIdentifier>
}
