/// A validated location inside an application bundle, relative to the
/// bundle's own root directory.
///
/// `BundlePath` is the only path vocabulary the bundle explorer speaks. It
/// names entries relative to the `.app` directory — `Info.plist`,
/// `Frameworks/Example.framework/Example` — and never the payload directory
/// above it, the archive that holds it, or any filesystem location. The
/// root path, which has no components, stands for the bundle directory
/// itself.
///
/// Construction enforces the same conservative rules as `ArchivePath`, so a
/// value is always relative, canonical, and traversal-free: no leading
/// separator, no empty, `.`, or `..` components, no NUL bytes, no
/// backslashes, and a bounded length. A candidate that fails the rules is
/// not constructible. That is what keeps every location the explorer can be
/// asked about inside the bundle by construction rather than by checking:
/// there is no value that names anything above the root.
struct BundlePath: Equatable, Hashable, CustomStringConvertible {

    /// The bundle root: the `.app` directory itself.
    static let root = BundlePath(validatedComponents: [])

    /// Upper bound for accepted paths, in characters. Every bundle path is
    /// a suffix of an archive path, so the archive bound applies.
    static let maximumLength = ArchivePath.maximumLength

    /// The path components in order, from the bundle root. Empty for the
    /// root.
    let components: [String]

    private init(validatedComponents: [String]) {
        self.components = validatedComponents
    }

    /// Creates a bundle path from components, or returns `nil` when any
    /// component is not a single safe name or the joined path exceeds the
    /// length bound. An empty array is the root.
    init?(components: [String]) {
        guard components.allSatisfy(Self.isValidComponent) else { return nil }
        let separators = max(0, components.count - 1)
        let length = components.reduce(separators) { $0 + $1.count }
        guard length <= Self.maximumLength else { return nil }
        self.components = components
    }

    /// Creates a bundle path from its textual form, or returns `nil` when
    /// the text fails the safety rules.
    ///
    /// The empty string is the root. A single trailing separator — the
    /// conventional directory marker — is tolerated; a leading separator is
    /// refused, because it would name an absolute location.
    init?(rawValue: String) {
        if rawValue.isEmpty {
            self.init(validatedComponents: [])
            return
        }
        guard !rawValue.hasPrefix("/") else { return nil }
        var candidate = rawValue
        if candidate.hasSuffix("/") {
            candidate.removeLast()
        }
        guard !candidate.isEmpty, candidate.count <= Self.maximumLength else { return nil }
        let parts = candidate.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        self.init(components: parts)
    }

    /// Derives the location of an archive entry relative to a bundle
    /// directory, or returns `nil` when the entry lies outside the bundle.
    /// The bundle directory itself derives to the root.
    init?(_ path: ArchivePath, relativeTo bundlePath: ArchivePath) {
        if path == bundlePath {
            self.init(validatedComponents: [])
            return
        }
        guard path.isWithin(bundlePath) else { return nil }
        let relative = Array(path.components.dropFirst(bundlePath.components.count))
        self.init(components: relative)
    }

    /// ZynSign's safety rule for one bundle path component: a non-empty name
    /// that is not `.` or `..` and carries no separator, NUL byte, or
    /// backslash.
    static func isValidComponent(_ component: String) -> Bool {
        guard !component.isEmpty else { return false }
        guard component != "." && component != ".." else { return false }
        guard !component.contains("/") else { return false }
        guard !component.contains("\0") else { return false }
        guard !component.contains("\\") else { return false }
        return true
    }

    /// The path in textual form, components joined by `/`. Empty for the
    /// root.
    var rawValue: String {
        components.joined(separator: "/")
    }

    /// Whether this path is the bundle root.
    var isRoot: Bool {
        components.isEmpty
    }

    /// How many components deep the path is. Zero for the root.
    var depth: Int {
        components.count
    }

    /// The final component — the entry's own name — or `nil` for the root.
    var name: String? {
        components.last
    }

    /// The containing path, or `nil` for the root. A single-component path's
    /// parent is the root.
    var parent: BundlePath? {
        guard !components.isEmpty else { return nil }
        return BundlePath(validatedComponents: Array(components.dropLast()))
    }

    /// Whether this path names an entry strictly inside `ancestor`. Equal
    /// paths do not count; every non-root path is within the root.
    func isWithin(_ ancestor: BundlePath) -> Bool {
        guard components.count > ancestor.components.count else { return false }
        return components.prefix(ancestor.components.count).elementsEqual(ancestor.components)
    }

    /// Returns this path with one additional component appended, or `nil`
    /// when the component is not a single safe name.
    func appending(component: String) -> BundlePath? {
        BundlePath(components: components + [component])
    }

    var description: String { rawValue }
}
