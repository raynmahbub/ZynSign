import Foundation

/// The stable identity of one application record in ZynSign's library.
///
/// A record identifier names the library entry, not the package bytes behind
/// it: the artifact a record refers to has its own `ArtifactIdentifier`, and
/// keeping the two apart lets a record outlive a replacement of its artifact
/// without changing identity. Like artifact identifiers, record identifiers
/// are opaque — never derived from package metadata, never presented as
/// package information — and a persisted identifier is reused when the
/// record is rehydrated rather than minted again.
struct ApplicationRecordIdentifier: Equatable, Hashable, CustomStringConvertible, Sendable {

    /// The underlying uniqueness value.
    let uuid: UUID

    /// Mints a fresh identifier for a newly created record.
    init() {
        self.uuid = UUID()
    }

    /// Reuses a previously minted identifier, for example when rehydrating a
    /// persisted record.
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
    /// diagnostics. Contains no package information.
    var rawValue: String { uuid.uuidString }

    var description: String { rawValue }
}
