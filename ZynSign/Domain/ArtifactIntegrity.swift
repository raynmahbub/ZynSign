/// Whether the package file the library holds for a record is still the
/// exact bytes the record describes.
///
/// Integrity is the answer to an explicit check. The library normally
/// observes only a file's presence and size, which is cheap enough to do on
/// every listing; verifying reads the whole file again and recomputes its
/// content fingerprint, then compares both size and fingerprint with what
/// was recorded when the package was imported. The result says whether the
/// bytes changed — nothing more. It is not a signature check, and an intact
/// package is not thereby trusted, signed, or installable.
enum ArtifactIntegrity: Hashable, Sendable {

    /// The file's size and content fingerprint match the record.
    case intact

    /// A file is held, but its size or content fingerprint differs from the
    /// record: the bytes were replaced or damaged after import.
    case modified(recordedByteCount: Int, observedByteCount: Int)

    /// No file is held for the record.
    case missing

    /// Whether the file is exactly the recorded bytes.
    var isIntact: Bool {
        self == .intact
    }

    /// A short, user-presentable name for the outcome.
    var displayName: String {
        switch self {
        case .intact: return "Intact"
        case .modified: return "Changed Since Import"
        case .missing: return "Package File Missing"
        }
    }

    /// A one-sentence, user-presentable explanation of the outcome.
    var explanation: String {
        switch self {
        case .intact:
            return "The package file matches the size and content fingerprint recorded when it was imported."
        case .modified:
            return "The package file no longer matches what was recorded at import. Re-import the application to restore it."
        case .missing:
            return "ZynSign's library no longer holds this application's package file. Re-import the application to restore it."
        }
    }
}
