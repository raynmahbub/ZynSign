/// The structure of one application bundle, derived from a package's entry
/// table and held as a value.
///
/// `BundleContents` is what the explorer shows. It is built once, from the
/// metadata a container records about its entries, and answers structural
/// questions — what is in this directory, what is at this path, which
/// entries are conventionally significant — from memory. Nothing about it
/// touches the package again, and nothing about it reads file content.
///
/// ## Boundary
///
/// Only entries strictly inside the bundle directory are included. The
/// bundle directory itself is the root and is not an entry. The payload
/// directory, sibling bundles, and anything else the package carries are
/// outside the boundary and are neither listed nor counted. Locations are
/// expressed as `BundlePath` values, so nothing here can name a location
/// above the root.
///
/// Entries whose names failed ZynSign's path safety rules have no location
/// (`ArchiveEntry.path` is `nil`). They cannot be attributed to any bundle
/// and are never listed; they are counted in `omittedEntryCount` so that
/// their existence is not concealed.
///
/// ## Implied directories
///
/// Containers may record a file without recording the directories above
/// it. Every ancestor of a listed entry is therefore present in the tree,
/// as a directory, whether or not the container recorded it.
///
/// ## Conflicting entries
///
/// Package validation refuses containers that record the same location
/// twice or as both a file and a directory, so library artifacts do not
/// contain conflicts. If a table nonetheless does, the rule is
/// deterministic: the first entry recorded at a location describes it, and
/// an explicit entry takes precedence over an implied directory.
///
/// ## Ordering
///
/// Within a directory, entries are ordered with directories before other
/// kinds and then by name, compared as Unicode scalars, so that the same
/// table produces the same listing on every run and every device.
struct BundleContents: Equatable, Hashable {

    /// The bundle directory's own name — `Example.app`.
    let bundleName: String

    /// How many entries the bundle holds, at every depth, including implied
    /// directories.
    let entryCount: Int

    /// The sum of the byte counts the package declares for the bundle's
    /// regular files. Saturates rather than overflowing.
    let totalDeclaredByteCount: Int

    /// How many of the package's entries could not be attributed to any
    /// location because their names failed the path safety rules.
    let omittedEntryCount: Int

    /// The entries at conventionally significant locations, ordered by role
    /// and then by path.
    let notableEntries: [BundleEntry]

    private let entriesByPath: [BundlePath: BundleEntry]
    private let childrenByDirectory: [BundlePath: [BundleEntry]]

    /// Builds the structure of the bundle at `bundlePath` from a package's
    /// entry table.
    ///
    /// `declaredExecutableName` is the executable name the bundle's own
    /// metadata declared, when known; it lets the entry of that name be
    /// labelled as the executable.
    init(entryTable: [ArchiveEntry], bundlePath: ArchivePath, declaredExecutableName: String? = nil) {
        var nodes: [BundlePath: Node] = [:]
        var omitted = 0

        for entry in entryTable {
            guard let archivePath = entry.path else {
                omitted += 1
                continue
            }
            guard let path = BundlePath(archivePath, relativeTo: bundlePath), !path.isRoot else {
                continue
            }
            if let existing = nodes[path], existing.isExplicit {
                continue
            }
            nodes[path] = Node(kind: entry.kind, byteCount: entry.uncompressedSize, isExplicit: true)

            var ancestor = path.parent
            while let current = ancestor, !current.isRoot {
                if nodes[current] == nil {
                    nodes[current] = Node(kind: .directory, byteCount: 0, isExplicit: false)
                }
                ancestor = current.parent
            }
        }

        var entries: [BundlePath: BundleEntry] = [:]
        entries.reserveCapacity(nodes.count)
        var children: [BundlePath: [BundleEntry]] = [.root: []]
        var totalBytes = 0

        for (path, node) in nodes {
            let entry = BundleEntry(
                path: path,
                kind: node.kind,
                declaredByteCount: node.kind == .regularFile ? node.byteCount : nil,
                role: BundleEntryRole.recognize(
                    path: path,
                    kind: node.kind,
                    declaredExecutableName: declaredExecutableName
                )
            )
            entries[path] = entry
            if entry.isDirectory, children[path] == nil {
                children[path] = []
            }
            if let bytes = entry.declaredByteCount {
                let (sum, overflow) = totalBytes.addingReportingOverflow(bytes)
                totalBytes = overflow ? Int.max : sum
            }
        }

        for entry in entries.values {
            let parent = entry.path.parent ?? .root
            children[parent, default: []].append(entry)
        }
        for key in Array(children.keys) {
            children[key]?.sort(by: Self.order)
        }

        self.bundleName = bundlePath.lastComponent
        self.entryCount = entries.count
        self.totalDeclaredByteCount = totalBytes
        self.omittedEntryCount = omitted
        self.entriesByPath = entries
        self.childrenByDirectory = children
        self.notableEntries = entries.values
            .filter { $0.role != nil }
            .sorted(by: Self.orderNotable)
    }

    /// Whether the bundle holds no entries at all.
    var isEmpty: Bool {
        entryCount == 0
    }

    /// The entries directly inside the bundle root, in listing order.
    var rootEntries: [BundleEntry] {
        childrenByDirectory[.root] ?? []
    }

    /// The entry at `path`, or `nil` when the bundle has none there. The root
    /// has no entry.
    func entry(at path: BundlePath) -> BundleEntry? {
        entriesByPath[path]
    }

    /// The entries directly inside `directory`, in listing order; an empty
    /// array for a directory with nothing in it, and `nil` when `directory`
    /// is not a directory the bundle holds.
    func entries(in directory: BundlePath) -> [BundleEntry]? {
        childrenByDirectory[directory]
    }

    /// How many entries are directly inside `directory`, or `nil` when
    /// `directory` is not a directory the bundle holds.
    func childCount(of directory: BundlePath) -> Int? {
        childrenByDirectory[directory]?.count
    }

    /// The listing order: directories first, then by name compared as
    /// Unicode scalars, then — for the pathological case of equal names of
    /// different kinds — by kind.
    static func order(_ lhs: BundleEntry, _ rhs: BundleEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory
        }
        let lhsName = lhs.name.unicodeScalars
        let rhsName = rhs.name.unicodeScalars
        if !lhsName.elementsEqual(rhsName) {
            return lhsName.lexicographicallyPrecedes(rhsName)
        }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }

    private static func orderNotable(_ lhs: BundleEntry, _ rhs: BundleEntry) -> Bool {
        let lhsRank = Self.rank(of: lhs.role)
        let rhsRank = Self.rank(of: rhs.role)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        return lhs.path.rawValue.unicodeScalars.lexicographicallyPrecedes(rhs.path.rawValue.unicodeScalars)
    }

    private static func rank(of role: BundleEntryRole?) -> Int {
        guard let role, let index = BundleEntryRole.allCases.firstIndex(of: role) else { return Int.max }
        return index
    }

    private struct Node {
        let kind: ArchiveEntryKind
        let byteCount: Int
        let isExplicit: Bool
    }
}
