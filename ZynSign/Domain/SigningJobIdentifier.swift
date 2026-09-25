import Foundation

/// The stable identity of one signing job inside ZynSign.
///
/// A job identifier names one user request to sign one application through
/// the signing queue. It is minted when the request is accepted by the
/// queue, and it lives exactly as long as the queue lists the request — a
/// job that is removed after settling leaves no trace in the queue, though
/// the signing record it produced (if any) remains in the history journal
/// under its own identifier. The identifier is opaque: it is never derived
/// from a URL, an application identity, a certificate, or package content,
/// and it is never presented as application or certificate information.
///
/// A job identifier and a `SigningRecordIdentifier` are deliberately
/// distinct. They answer different questions: a job may be cancelled or
/// fail without ever producing a record, and a record outlives the job
/// that produced it. Correlating the two is a runtime concern and never a
/// stored one.
struct SigningJobIdentifier: Equatable, Hashable, Codable, CustomStringConvertible, Sendable {

    /// The underlying uniqueness value.
    let uuid: UUID

    /// Mints a fresh identifier for a newly requested signing job.
    init() {
        self.uuid = UUID()
    }

    /// Reuses a previously minted identifier, for example when rehydrating
    /// a persisted queue snapshot.
    init(uuid: UUID) {
        self.uuid = uuid
    }

    /// Rehydrates an identifier from its string form, or returns `nil` when
    /// the string is not a valid identifier representation.
    init?(rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue) else { return nil }
        self.uuid = uuid
    }

    /// The canonical string form, suitable for persistence keys and
    /// diagnostics. Contains no application, certificate, or profile
    /// information and no location.
    var rawValue: String { uuid.uuidString }

    var description: String { rawValue }
}
