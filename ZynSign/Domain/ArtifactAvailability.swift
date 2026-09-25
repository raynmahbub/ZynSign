/// What library storage reports about one artifact when asked to look for
/// it: whether a file is held under the identifier and, if so, how large it
/// is. An observation is a fact about storage; it is compared against what a
/// record expects to produce an `ArtifactAvailability`.
enum StoredArtifactObservation: Equatable, Hashable {

    /// A regular file is held under the identifier, with the observed size
    /// in bytes.
    case present(byteCount: Int)

    /// Nothing is held under the identifier.
    case absent
}

/// Whether a library record's artifact is where the record says it is.
///
/// Availability is derived every time it is asked for, by comparing what
/// storage holds against what the record recorded. It is never persisted:
/// the record keeps the reference, storage keeps the bytes, and this value
/// is the current relationship between them. A record whose artifact is
/// missing or inconsistent stays in the library with its metadata intact, so
/// the problem can be shown and diagnosed; nothing is silently recreated, and
/// the artifact is never reported as available.
enum ArtifactAvailability: Equatable, Hashable, Sendable {

    /// The artifact is held and its size matches the record.
    case available

    /// Nothing is held under the record's artifact identifier.
    case missing

    /// A file is held, but its size differs from the size the record
    /// captured when the artifact was taken into the library. The bytes
    /// were replaced, truncated, or damaged behind the record's back.
    case inconsistent(recordedByteCount: Int, observedByteCount: Int)

    /// Whether the artifact can be relied on to be the recorded bytes.
    var isAvailable: Bool {
        self == .available
    }

    /// Derives availability from a storage observation and the reference the
    /// record holds.
    static func derive(
        from observation: StoredArtifactObservation,
        expecting reference: ArtifactReference
    ) -> ArtifactAvailability {
        switch observation {
        case .absent:
            return .missing
        case .present(let byteCount):
            if byteCount == reference.byteCount {
                return .available
            }
            return .inconsistent(recordedByteCount: reference.byteCount, observedByteCount: byteCount)
        }
    }

    /// A human-readable name for presentation and diagnostics.
    var displayName: String {
        switch self {
        case .available: return "Available"
        case .missing: return "Missing"
        case .inconsistent: return "Inconsistent"
        }
    }
}
