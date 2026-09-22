/// One entry inside an application bundle, as recorded by the package that
/// carries it.
///
/// An entry is a description, never a handle. It says where in the bundle
/// something is, what kind of object the package says it is, how many bytes
/// the package declares for it, and whether its location is conventionally
/// significant. It gives no way to open, read, follow, or change the object
/// it describes, and it does not know where the package is stored.
///
/// Symbolic links and objects of unsupported kinds are entries like any
/// other: they are listed with their kind, and that is all. A link's target
/// is content the explorer never reads, so a link is never followed and can
/// lead nowhere, inside the bundle or out of it. An unsupported object is
/// named and left alone.
struct BundleEntry: Equatable, Hashable {

    /// The entry's location relative to the bundle root. Never the root
    /// itself; the root is the directory being described, not an entry in it.
    let path: BundlePath

    /// What kind of object the package records at this location.
    let kind: ArchiveEntryKind

    /// The byte count the package declares for a regular file, or `nil` for
    /// every other kind. A declaration by an untrusted container: the
    /// explorer never verifies it by reading the file.
    let declaredByteCount: Int?

    /// The conventional significance of the entry's location, when it has
    /// one. Descriptive only; see `BundleEntryRole`.
    let role: BundleEntryRole?

    init(path: BundlePath, kind: ArchiveEntryKind, declaredByteCount: Int? = nil, role: BundleEntryRole? = nil) {
        self.path = path
        self.kind = kind
        self.declaredByteCount = kind == .regularFile ? declaredByteCount.map { max(0, $0) } : nil
        self.role = role
    }

    /// The entry's own name: the final component of its path.
    var name: String {
        path.name ?? ""
    }

    /// Whether the entry is a directory that the explorer can descend into.
    var isDirectory: Bool {
        kind == .directory
    }
}
