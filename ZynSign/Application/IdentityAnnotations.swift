import Foundation

/// Local-only display information ZynSign keeps about a signing identity.
///
/// Annotations are the certificate manager's memory of the user's own
/// organisation, separate from what the certificate itself declares: a
/// display label the user chose for one identity, and the moment ZynSign
/// imported it. Both are local presentation concerns — a rename changes
/// nothing about the certificate or its key, and the import date is ZynSign's
/// own bookkeeping, not a property the certificate carries.
///
/// Security boundary: an annotation is keyed by the certificate's SHA-256
/// fingerprint, which is public information about the certificate, and it
/// holds only the label and the date. It never holds a password, a key
/// reference, a keychain account, or any other secret; the key's own
/// registration remains in the secure store.
struct IdentityAnnotation: Codable, Equatable, Hashable {

    /// The maximum length of a display label. Bounds the annotation file and
    /// the interface; a label longer than this is refused at the boundary,
    /// not silently truncated.
    static let maximumLabelLength = 120

    /// The user-chosen display label for the identity, or `nil` when the
    /// identity shows the certificate's own display name.
    var displayLabel: String?

    /// When ZynSign imported the identity, or `nil` for identities imported
    /// before the annotation existed.
    var importedAt: Date?

    init(displayLabel: String? = nil, importedAt: Date? = nil) {
        self.displayLabel = displayLabel
        self.importedAt = importedAt
    }

    /// Whether the annotation carries no information at all.
    var isEmpty: Bool { displayLabel == nil && importedAt == nil }

    /// Whether the stored label obeys the length boundary. A catalog that
    /// records a longer value is damaged, not long.
    var hasValidLabelLength: Bool {
        displayLabel.map { $0.count <= Self.maximumLabelLength } ?? true
    }
}

/// The boundary through which the certificate manager reads and writes the
/// local-only annotations of the identities it lists.
///
/// Annotations are keyed by the certificate's SHA-256 fingerprint (lowercase
/// hexadecimal) because the fingerprint is the most stable identifier of the
/// certificate's bytes: it outlives a registration's identity identifier,
/// which is freshly minted each time an identity is imported.
///
/// The store is a convenience surface, not a security surface: everything it
/// holds is display information. Implementations must fail closed on a
/// catalog they cannot interpret — never reset it, never load it partially —
/// and must refuse to write values that violate the annotation's own
/// boundaries.
protocol IdentityAnnotationsStore {

    /// All current annotations, keyed by certificate fingerprint.
    ///
    /// - Returns: The annotations as of this read.
    /// - Throws: A typed `ZynSignError` when the catalog cannot be read.
    func annotations() throws -> [String: IdentityAnnotation]

    /// Replaces the annotation for `fingerprint`.
    ///
    /// An annotation with no information replaces the stored value with an
    /// empty one; callers that want to delete the entry use
    /// `removeAnnotation(forFingerprint:)`.
    ///
    /// - Throws: A typed `ZynSignError` when the annotation violates its
    ///   boundaries or the catalog cannot be written.
    func setAnnotation(
        _ annotation: IdentityAnnotation,
        forFingerprint fingerprint: String
    ) throws

    /// Removes the annotation for `fingerprint`, when one exists.
    ///
    /// - Throws: A typed `ZynSignError` when the catalog cannot be written.
    func removeAnnotation(forFingerprint fingerprint: String) throws

    /// The fingerprint the user has marked as the default signing identity,
    /// or `nil` when no default is set. A default that no longer names a
    /// recorded identity is the manager's problem to clear, not the store's
    /// to invent.
    ///
    /// - Throws: A typed `ZynSignError` when the catalog cannot be read.
    func defaultIdentityFingerprint() throws -> String?

    /// Marks `fingerprint` as the default signing identity, or clears the
    /// default when `nil`.
    ///
    /// Marking a default for an identity that carries no annotation records
    /// an empty annotation for it, so the default names a recorded entry and
    /// survives a relaunch.
    ///
    /// - Throws: A typed `ZynSignError` when the fingerprint is not a
    ///   certificate fingerprint or the catalog cannot be written.
    func setDefaultIdentityFingerprint(_ fingerprint: String?) throws
}
