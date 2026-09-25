import Foundation

/// The stable identity of one import job inside ZynSign.
///
/// A job identifier names one user request to bring a package into ZynSign.
/// It is minted when the request is accepted by the import queue, and it
/// lives exactly as long as the queue lists the request — a job that is
/// cancelled, refused, or removed leaves no trace. The identifier is opaque:
/// it is never derived from a URL, a file name, a provider identity, or
/// package content, and it is never presented as package information.
///
/// A job identifier and an `ArtifactIdentifier` are deliberately distinct.
/// They answer different questions: a job may be cancelled, refused, or fail
/// without ever producing an artifact, and an artifact outlives the job that
/// produced it — the record a completed import creates refers to the
/// artifact, never to the job. Correlating the two is a runtime concern and
/// never a stored one.
struct ImportJobIdentifier: Equatable, Hashable, CustomStringConvertible, Sendable {

    /// The underlying uniqueness value.
    let uuid: UUID

    /// Mints a fresh identifier for a newly requested import.
    init() {
        self.uuid = UUID()
    }

    /// Reuses a previously minted identifier.
    init(uuid: UUID) {
        self.uuid = uuid
    }

    /// Rehydrates an identifier from its string form, or returns `nil` when
    /// the string is not a valid identifier representation.
    init?(rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue) else { return nil }
        self.uuid = uuid
    }

    /// The canonical string form, suitable for diagnostics. Contains no
    /// package information and no location.
    var rawValue: String { uuid.uuidString }

    var description: String { rawValue }
}
