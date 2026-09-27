import Foundation

/// The stable identity of one download job inside ZynSign.
///
/// A download identifier names one user request to transfer one package. It is
/// minted when the request is accepted and lives as long as the Download Center
/// lists the job. It is opaque: it is never derived from a URL, a bundle
/// identifier, or package bytes, and it is never presented as application
/// information.
struct DownloadJobIdentifier: Equatable, Hashable, Codable, CustomStringConvertible, Sendable {

    /// The underlying uniqueness value.
    let uuid: UUID

    /// Mints a fresh identifier for a newly accepted download.
    init() {
        self.uuid = UUID()
    }

    /// Reuses a previously minted identifier, for example when rehydrating a
    /// persisted queue.
    init(uuid: UUID) {
        self.uuid = uuid
    }

    /// Rehydrates an identifier from its string form, or returns `nil` when
    /// the string is not a valid identifier representation.
    init?(rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue) else { return nil }
        self.uuid = uuid
    }

    /// The canonical string form, suitable for persistence keys. Contains no
    /// package information.
    var rawValue: String { uuid.uuidString }

    var description: String { rawValue }
}
