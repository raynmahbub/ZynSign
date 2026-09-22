import Foundation

/// The stable identity of one imported application package within ZynSign.
///
/// An artifact identifier correlates the domain artifact with whatever the
/// application and infrastructure layers store on its behalf — imported
/// bytes, extracted trees, persisted records — without exposing any
/// filesystem path, provider location, or storage detail to the domain.
///
/// Identifiers are opaque: they carry no information about package contents,
/// are never derived from package metadata, and must never be presented as
/// package information. A fresh identifier is minted when a package is
/// imported; persistence layers reuse the stored identifier when rehydrating
/// a known artifact instead of minting another.
struct ArtifactIdentifier: Equatable, Hashable, CustomStringConvertible {

    /// The underlying uniqueness value.
    let uuid: UUID

    /// Mints a fresh identifier for a newly imported artifact.
    init() {
        self.uuid = UUID()
    }

    /// Reuses a previously minted identifier, for example when rehydrating a
    /// persisted artifact record.
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
