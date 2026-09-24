/// The kind of content one archive entry records.
///
/// Containers differ in how faithfully they record type information. Where a
/// container does record it, ZynSign uses the recorded value; where it does
/// not, the reader falls back to the container's own naming convention. The
/// `unsupported` case is honest about everything else — sockets, FIFOs, device
/// nodes, hard links, and any other entry form ZynSign does not model — rather
/// than quietly treating an unknown form as an ordinary file.
enum ArchiveEntryKind: String, CaseIterable, Hashable {

    /// A container directory.
    case directory

    /// An ordinary readable file.
    case regularFile

    /// A symbolic link. Links are never followed by inspection, and a link
    /// whose target lies outside the container is refused.
    case symbolicLink

    /// An entry form ZynSign deliberately does not model.
    case unsupported

    /// Whether inspection may treat this entry as part of the package layout.
    /// Only directories and regular files qualify; links and unmodelled forms
    /// are reported rather than traversed.
    var isUsable: Bool {
        switch self {
        case .directory, .regularFile:
            return true
        case .symbolicLink, .unsupported:
            return false
        }
    }

    /// A human-readable kind name for diagnostics.
    var displayName: String {
        switch self {
        case .directory: return "a directory"
        case .regularFile: return "a regular file"
        case .symbolicLink: return "a symbolic link"
        case .unsupported: return "an unsupported entry type"
        }
    }
}

/// One entry recorded in an imported archive container.
///
/// `ArchiveEntry` is the domain's description of container content: what the
/// container recorded, and whether ZynSign accepted the recorded name. It
/// carries no bytes, no file handles, and no filesystem location; reading
/// content happens through the `ArchiveReader` boundary.
///
/// The name is deliberately split in two. `rawName` is what the container
/// recorded, kept for diagnostics; `path` is that name after ZynSign's own
/// safety rules, and is `nil` whenever the name fails them. An entry with a
/// `nil` path is never silently dropped — it is reported as an unsafe entry,
/// because a container that records a name ZynSign will not accept is exactly
/// the kind of input that must not be processed on trust.
struct ArchiveEntry: Equatable, Hashable {

    /// Upper bound for the name reproduced in diagnostics. The stored
    /// `rawName` is bounded by the reader's configured limits; this narrower
    /// bound keeps a single pathological name from dominating a report.
    static let diagnosticNameLength = 200

    /// The entry name exactly as the container recorded it, bounded by the
    /// reader's limits. Diagnostic context only: it is never treated as a
    /// path and never used to reach content.
    let rawName: String

    /// The validated archive path, or `nil` when the recorded name failed
    /// ZynSign's safety rules.
    let path: ArchivePath?

    /// The recorded kind of content.
    let kind: ArchiveEntryKind

    /// The size the container declares for the entry's content once expanded,
    /// in bytes. Declared by untrusted metadata; used only as a pre-check.
    let uncompressedSize: Int

    /// The size the entry occupies in the container, in bytes.
    let compressedSize: Int

    /// The Unix file-type and permission bits the container records for the
    /// entry, when it records any — for example `0o100644` for an ordinary
    /// file or `0o100755` for an executable one. `nil` when the container
    /// names no Unix host or records no mode. Declared by untrusted
    /// metadata like every other field here: extraction derives permission
    /// bits from it but never trusts it as evidence of anything else.
    let unixMode: UInt16?

    /// Records an entry whose container name satisfied ZynSign's safety rules.
    init(
        path: ArchivePath,
        kind: ArchiveEntryKind,
        uncompressedSize: Int = 0,
        compressedSize: Int = 0,
        unixMode: UInt16? = nil
    ) {
        self.rawName = path.rawValue
        self.path = path
        self.kind = kind
        self.uncompressedSize = max(0, uncompressedSize)
        self.compressedSize = max(0, compressedSize)
        self.unixMode = unixMode
    }

    /// Records an entry whose container name ZynSign refuses to accept —
    /// because it is absolute, escaping, malformed, over-long, or not
    /// decodable text. The entry stays in the table so that it is reported
    /// instead of ignored.
    init(
        rejectedName: String,
        kind: ArchiveEntryKind,
        uncompressedSize: Int = 0,
        compressedSize: Int = 0,
        unixMode: UInt16? = nil
    ) {
        self.rawName = rejectedName
        self.path = nil
        self.kind = kind
        self.uncompressedSize = max(0, uncompressedSize)
        self.compressedSize = max(0, compressedSize)
        self.unixMode = unixMode
    }

    /// Whether ZynSign accepted the recorded name.
    var isSafelyNamed: Bool {
        path != nil
    }

    /// The recorded name in a form that is safe to place in a diagnostic:
    /// truncated, and stripped of control characters that could forge
    /// structure in a log line.
    var diagnosticName: String {
        let sanitized = rawName.map { character -> Character in
            character.isControl ? "\u{FFFD}" : character
        }
        let name = String(sanitized)
        if name.count <= Self.diagnosticNameLength {
            return name
        }
        return String(name.prefix(Self.diagnosticNameLength)) + "\u{2026}"
    }
}
