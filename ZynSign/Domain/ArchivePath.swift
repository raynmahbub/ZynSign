/// A validated logical path of one entry inside an application package.
///
/// `ArchivePath` names a location within the container's own hierarchy — for
/// example `Payload/Example.app/Info.plist` — without reaching any
/// filesystem, archive reader, or platform path service. It is the only path
/// representation the domain uses: provider locations, sandbox directories,
/// and extraction roots never appear in domain values.
///
/// Construction enforces ZynSign's own conservative safety rules, so an
/// `ArchivePath` value is always a relative, canonical, traversal-free name.
/// These are ZynSign's acceptance rules for container-internal names; they
/// make no claim about what any platform accepts, and a constructible path
/// is not evidence that the entry exists.
struct ArchivePath: Equatable, Hashable, CustomStringConvertible {

    /// Upper bound for accepted paths, in characters. A conservative guard
    /// against pathological input, not a platform limit.
    static let maximumLength = 1024

    /// The validated path in canonical form: a single trailing slash, the
    /// conventional directory-entry marker, is removed, and every other
    /// character is preserved exactly as supplied. Case is preserved.
    let rawValue: String

    /// Creates a validated archive path, or returns `nil` when the candidate
    /// fails ZynSign's safety rules.
    init?(rawValue: String) {
        var candidate = rawValue
        if candidate.hasSuffix("/") {
            candidate.removeLast()
        }
        guard Self.isValid(candidate) else { return nil }
        self.rawValue = candidate
    }

    /// ZynSign's safety rule for archive paths.
    ///
    /// A candidate is accepted when it is non-empty, length-bounded,
    /// relative (no leading slash, no leading drive-style prefix), free of
    /// NUL bytes and backslashes, and composed of non-empty components with
    /// no `.` or `..` entries. Rejected candidates describe malformed or
    /// unsafe container content, never a defect in ZynSign.
    static func isValid(_ candidate: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        guard candidate.count <= maximumLength else { return false }
        guard !candidate.contains("\0") else { return false }
        guard !candidate.contains("\\") else { return false }
        guard !candidate.hasPrefix("/") else { return false }
        if candidate.count >= 2 {
            let start = candidate.startIndex
            let first = candidate[start]
            let second = candidate[candidate.index(after: start)]
            if first.isASCII && first.isLetter && second == ":" {
                return false
            }
        }
        let components = candidate.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        for component in components {
            guard !component.isEmpty else { return false }
            guard component != "." && component != ".." else { return false }
        }
        return true
    }

    /// The path components in order, without separators. Never empty.
    var components: [String] {
        rawValue.split(separator: "/").map(String.init)
    }

    /// The final component — the entry's own name.
    var lastComponent: String {
        components.last ?? rawValue
    }

    /// The containing path, or `nil` when this path has a single component.
    var parent: ArchivePath? {
        let parts = components
        guard parts.count > 1 else { return nil }
        return ArchivePath(rawValue: parts.dropLast().joined(separator: "/"))
    }

    /// Whether this path names an entry strictly inside `ancestor`.
    /// Equal paths do not count: containment is a strict prefix of components.
    func isWithin(_ ancestor: ArchivePath) -> Bool {
        let own = components
        let base = ancestor.components
        guard own.count > base.count else { return false }
        return own.prefix(base.count).elementsEqual(base)
    }

    /// Returns this path with one additional component appended, or `nil`
    /// when the component is not a single safe name.
    func appending(component: String) -> ArchivePath? {
        guard !component.isEmpty else { return nil }
        guard !component.contains("/") else { return nil }
        return ArchivePath(rawValue: "\(rawValue)/\(component)")
    }

    /// Whether a symbolic-link target is a relative location that resolves
    /// inside the container when read from a link `directoryDepth`
    /// directories deep: no leading separator, no drive prefix, no NUL bytes
    /// or backslashes, and no climb above the container root. Unlike an
    /// `ArchivePath`, a target may name `.` components and may climb with
    /// `..` exactly as far as the link's own depth allows.
    static func isContainedLinkTarget(_ target: String, directoryDepth: Int) -> Bool {
        guard !target.isEmpty else { return false }
        guard !target.contains("\0") else { return false }
        guard !target.contains("\\") else { return false }
        guard !target.hasPrefix("/") else { return false }
        if target.count >= 2 {
            let start = target.startIndex
            let first = target[start]
            let second = target[target.index(after: start)]
            if first.isASCII && first.isLetter && second == ":" {
                return false
            }
        }
        var depth = directoryDepth
        for component in target.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            if component.isEmpty || component == "." {
                continue
            }
            if component == ".." {
                depth -= 1
                if depth < 0 {
                    return false
                }
                continue
            }
            depth += 1
        }
        return true
    }

    var description: String { rawValue }
}
