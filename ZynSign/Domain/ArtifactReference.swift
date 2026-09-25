/// A library record's reference to the artifact it describes.
///
/// The reference is the only link between a persisted record and the package
/// bytes ZynSign keeps for it. It names the artifact by its identifier —
/// never by a path, a provider location, or a URL, none of which are stable
/// or belong in the domain — and it records what the bytes looked like when
/// they were taken into the library: their size and their content
/// fingerprint. The identifier is how the artifact is found again; the size
/// and fingerprint are how a record can tell whether what it finds is what it
/// recorded, and how the duplicate policy recognises the same content.
///
/// None of this is a trust statement. A reference says which bytes a record
/// belongs to; it says nothing about whether they are signed or genuine.
struct ArtifactReference: Equatable, Hashable, Sendable {

    /// The identifier under which library storage holds the artifact.
    let artifactID: ArtifactIdentifier

    /// The artifact's size when it was taken into the library, in bytes.
    let byteCount: Int

    /// The content fingerprint computed when the artifact was taken into the
    /// library.
    let fingerprint: ArtifactFingerprint

    /// Records a reference. A negative byte count is clamped to zero: sizes
    /// are observed, never declared, so a negative value can only be a
    /// caller's mistake.
    init(artifactID: ArtifactIdentifier, byteCount: Int, fingerprint: ArtifactFingerprint) {
        self.artifactID = artifactID
        self.byteCount = max(0, byteCount)
        self.fingerprint = fingerprint
    }

    /// Whether this reference and `other` describe byte-identical content:
    /// the same fingerprint and the same size. Identifiers are deliberately
    /// not compared — two artifacts held under different identifiers can be
    /// the same bytes, and that is exactly what this question is for.
    func describesSameContent(as other: ArtifactReference) -> Bool {
        fingerprint == other.fingerprint && byteCount == other.byteCount
    }
}
