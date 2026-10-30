import Foundation

/// Why the LAN Web Workspace refused a target, or a mutation of one.
///
/// The cases are the whole vocabulary: a refusal that is not named here cannot
/// happen, which is why "it failed" is never one of them. Each case carries the
/// status it is answered with, and its message names what was refused without
/// echoing the request back — a hostile target must not be able to make the
/// server repeat it.
enum WebDAVRequestRejection: Error, Equatable, Hashable, Sendable {

    /// The target was not an origin-form path (`/…`) or an absolute `http(s)` URL.
    case unreadableTarget

    /// The target percent-encoded bytes that do not decode to text.
    case undecodableTarget

    /// The target contained an empty segment, so two URLs would name one resource.
    case emptyComponent

    /// A segment was `.` or `..`, which is traversal however it was encoded.
    case traversal

    /// A segment carried a control character, a path separator, or a character a
    /// client or a filesystem would reinterpret.
    case reservedCharacter

    /// A segment began with a dot, so it would be a hidden name.
    case hiddenName

    /// A segment ended with a dot or a space, which some filesystems normalise away.
    case trailingDotOrSpace

    /// One segment exceeded the byte bound.
    case componentTooLong(limit: Int)

    /// The target had more segments than the workspace serves.
    case tooManyComponents(limit: Int)

    /// The decoded target exceeded the byte bound.
    case pathTooLong(limit: Int)

    /// The resolved location is not inside the workspace root — a symlink left it.
    case outsideWorkspace

    /// The workspace root itself, which no request replaces, moves, or deletes.
    case workspaceRoot

    /// One of the workspace's own category folders, which the shell relies on.
    case categoryRoot

    /// The file is larger than this surface serves in one response.
    case downloadTooLarge(limit: Int)

    /// Fewer bytes arrived than the request declared.
    case incompleteBody

    /// The request came from another site, so it is refused rather than allowed
    /// to act with a credential the browser attached on its own.
    case foreignOrigin

    /// The status line this refusal is answered with.
    var status: Int {
        switch self {
        case .unreadableTarget, .undecodableTarget, .emptyComponent, .traversal,
             .reservedCharacter, .trailingDotOrSpace, .incompleteBody:
            return 400
        case .hiddenName, .outsideWorkspace, .workspaceRoot, .categoryRoot, .foreignOrigin:
            return 403
        case .downloadTooLarge:
            return 413
        case .pathTooLong:
            return 414
        case .componentTooLong, .tooManyComponents:
            return 400
        }
    }

    /// The reason phrase the status line prints.
    var reason: String {
        switch status {
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 413: return "Content Too Large"
        case 414: return "URI Too Long"
        default: return "Error"
        }
    }

    /// A sentence a person can act on. It never repeats the refused target.
    var message: String {
        switch self {
        case .unreadableTarget:
            return "The request target is not a path this workspace serves."
        case .undecodableTarget:
            return "The request target is not valid percent-encoded text."
        case .emptyComponent:
            return "The request target has an empty path segment."
        case .traversal:
            return "The request target contains a relative path segment."
        case .reservedCharacter:
            return "The request target contains a character this workspace does not accept."
        case .hiddenName:
            return "Hidden names are not served."
        case .trailingDotOrSpace:
            return "A path segment ends with a dot or a space, which some filesystems rename."
        case .componentTooLong(let limit):
            return "A path segment is longer than \(limit) bytes."
        case .tooManyComponents(let limit):
            return "The path has more than \(limit) segments."
        case .pathTooLong(let limit):
            return "The path is longer than \(limit) bytes."
        case .outsideWorkspace:
            return "That location is outside the workspace."
        case .workspaceRoot:
            return "The workspace root cannot be replaced, moved, or deleted."
        case .categoryRoot:
            return "A workspace category folder cannot be replaced, moved, or deleted."
        case .downloadTooLarge(let limit):
            return "This file is larger than the workspace serves in one response (\(limit) bytes)."
        case .incompleteBody:
            return "The request declared more bytes than it sent."
        case .foreignOrigin:
            return "This workspace does not answer requests made from another site."
        }
    }

    /// The response this refusal becomes.
    var response: WebDAVProtocol.HTTPResponseMessage {
        WebDAVProtocol.HTTPResponseMessage(
            status: status,
            reason: reason,
            headers: [("Content-Type", "text/plain; charset=utf-8")],
            body: Data((message + "\n").utf8)
        )
    }
}

/// The one place a request target becomes a location inside the workspace.
///
/// Every rule here exists because a client can send the input: a target is
/// parsed once, decoded once, bounded, and then resolved against a root that has
/// already had its symlinks resolved, so a link cannot move a read, a write or a
/// delete out of the workspace. Nothing in this type touches the filesystem
/// except the two resolution helpers, which read metadata and never mutate it.
enum WebDAVPathPolicy {

    /// Bounds on what a target may contain. They are small on purpose: a path
    /// this surface serves names an uploaded package, not a tree.
    struct Limits: Equatable, Sendable {
        var maximumComponentBytes: Int = 255
        var maximumComponents: Int = 16
        var maximumPathBytes: Int = 1_024

        static let `default` = Limits()
    }

    /// Segment names a filesystem or a client may reinterpret as a device.
    private static let reservedDeviceNames: Set<String> = {
        var names: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for index in 1...9 {
            names.insert("COM\(index)")
            names.insert("LPT\(index)")
        }
        return names
    }()

    /// Characters that would let one segment address another location, or that a
    /// WebDAV client cannot round-trip. Backslash is included because a client on
    /// another platform may treat it as a separator.
    private static let reservedCharacters: Set<Character> = ["\\", ":", "<", ">", "|", "\"", "*", "?"]

    // MARK: - Parsing

    /// Parses a request target into the segments it names, or refuses it by name.
    ///
    /// The target may be origin-form (`/Packages/App.ipa`) or absolute-form
    /// (`http://192.168.1.4:8088/Packages/App.ipa`, which is what a WebDAV
    /// `Destination` header carries). Both are reduced to segments; the authority
    /// is dropped rather than trusted, so a client cannot name another host.
    static func components(
        fromTarget rawTarget: String,
        limits: Limits = .default
    ) -> Result<[String], WebDAVRequestRejection> {
        var target = rawTarget
        if let query = target.firstIndex(of: "?") {
            target = String(target[..<query])
        }
        if let path = pathOfAbsoluteForm(target) {
            target = path
        }
        guard target.hasPrefix("/") else {
            return .failure(.unreadableTarget)
        }
        guard let decoded = target.removingPercentEncoding else {
            return .failure(.undecodableTarget)
        }
        guard decoded.utf8.count <= limits.maximumPathBytes else {
            return .failure(.pathTooLong(limit: limits.maximumPathBytes))
        }

        var rawParts = decoded.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard rawParts.first == "" else {
            return .failure(.unreadableTarget)
        }
        rawParts.removeFirst()
        // A trailing slash names a collection, which is legal; any other empty
        // segment would let two targets name one location.
        if rawParts.last == "" {
            rawParts.removeLast()
        }
        guard rawParts.count <= limits.maximumComponents else {
            return .failure(.tooManyComponents(limit: limits.maximumComponents))
        }
        var parts: [String] = []
        parts.reserveCapacity(rawParts.count)
        for part in rawParts {
            if let rejection = rejectionForComponent(part, limits: limits) {
                return .failure(rejection)
            }
            parts.append(part)
        }
        return .success(parts)
    }

    /// Reduces an absolute-form target to its path, or returns `nil` when the
    /// target is not one. A non-HTTP scheme is not rewritten: it is refused by
    /// the caller because the result no longer starts with `/`.
    private static func pathOfAbsoluteForm(_ target: String) -> String? {
        guard let schemeEnd = target.range(of: "://") else { return nil }
        // The range is found on `target` and read from `target`; a lowercased
        // copy can differ in length, so its indices are never used here.
        let scheme = target[..<schemeEnd.lowerBound].lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        let remainder = target[schemeEnd.upperBound...]
        guard let slash = remainder.firstIndex(of: "/") else { return "/" }
        return String(remainder[slash...])
    }

    /// The single rule set a segment must satisfy.
    private static func rejectionForComponent(
        _ component: String,
        limits: Limits
    ) -> WebDAVRequestRejection? {
        if component == "." || component == ".." {
            return .traversal
        }
        guard !component.isEmpty else { return .emptyComponent }
        guard component.utf8.count <= limits.maximumComponentBytes else {
            return .componentTooLong(limit: limits.maximumComponentBytes)
        }
        for scalar in component.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7F {
            return .reservedCharacter
        }
        for character in component where reservedCharacters.contains(character) {
            return .reservedCharacter
        }
        if component.hasPrefix(".") {
            return .hiddenName
        }
        if component.hasSuffix(".") || component.hasSuffix(" ") {
            return .trailingDotOrSpace
        }
        if reservedDeviceNames.contains(component.uppercased()) {
            return .reservedCharacter
        }
        return nil
    }

    // MARK: - Resolution

    /// The workspace root with its symlinks resolved. Callers resolve once per
    /// request and compare against the result, so a link inside the workspace
    /// cannot redirect a request outside it.
    static func resolvedRoot(_ root: URL) -> URL {
        root.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The location a parsed target names, under an already resolved root.
    static func location(for parts: [String], underResolvedRoot root: URL) -> URL {
        parts.reduce(root) { $0.appendingPathComponent($1) }
    }

    /// Whether `candidate`, once resolved, is the root or below it.
    ///
    /// The comparison is on resolved paths with a separator on the root side, so
    /// a sibling directory whose name merely starts with the root's name is not
    /// mistaken for a child.
    static func isContained(_ candidate: URL, underResolvedRoot root: URL) -> Bool {
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let base = root.path
        if resolved == base { return true }
        return resolved.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    // MARK: - Mutations

    /// The refusal a mutating method earns for the target it names, or `nil` when
    /// the mutation may proceed. The workspace root and the category folders the
    /// shell creates are not a client's to replace, move, or delete: doing so
    /// would leave the workspace without the folders the app and the dashboard
    /// address by name.
    static func refusalForMutation(
        of parts: [String],
        protectedRoots: Set<String>
    ) -> WebDAVRequestRejection? {
        guard !parts.isEmpty else { return .workspaceRoot }
        if parts.count == 1, protectedRoots.contains(parts[0].lowercased()) {
            return .categoryRoot
        }
        return nil
    }
}
