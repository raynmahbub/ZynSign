import Foundation

/// A tolerant, read-only view of an existing resource seal
/// (`_CodeSignature/CodeResources`), for verification only.
///
/// `CodeResourcesParser` models the subset ZynSign's own signing writes and
/// deliberately refuses the legacy `files` and `rules` dictionaries that
/// Apple's tools still emit beside `files2` and `rules2`. Verifying an
/// imported app has to read what those tools produced, so this reader takes
/// only what verification needs — each `files2` path with its SHA-256
/// (`hash2`) and its optional, symbolic-link, and nested-code markers — and
/// ignores every other key without interpreting it. It never produces a seal
/// and is never used by signing.
///
/// Recorded paths are untrusted. A path that fails ZynSign's bundle-path
/// safety rules is kept, flagged, and never read.
struct SealedResourceManifest: Equatable {

    /// One `files2` entry.
    struct Entry: Equatable, Identifiable {
        /// The path exactly as recorded, with control characters replaced.
        let recordedPath: String
        /// The validated bundle-relative path, or `nil` when the recorded
        /// path fails the safety rules.
        let path: BundlePath?
        /// The recorded SHA-256 digest (`hash2`), when present.
        let sha256: Data?
        /// Whether the entry is marked optional: its absence is allowed.
        let isOptional: Bool
        /// Whether the entry records a symbolic link rather than a file.
        let isSymbolicLink: Bool
        /// Whether the entry records nested code by its CodeDirectory hash.
        let isNestedCode: Bool

        var id: String { recordedPath }
    }

    /// The most entries ZynSign reads from one seal.
    static let maximumEntries = 100_000

    /// The largest seal ZynSign reads, in bytes.
    static let maximumByteCount = 64 * 1_024 * 1_024

    let entries: [Entry]

    /// How many entries were beyond `maximumEntries` and not read.
    let omittedEntryCount: Int

    /// Whether the seal carries a `files2` dictionary at all.
    let hasFiles2: Bool

    /// Reads a seal, or returns `nil` when the bytes are not a property-list
    /// dictionary within the bounds.
    static func read(_ data: Data) -> SealedResourceManifest? {
        guard !data.isEmpty, data.count <= maximumByteCount else { return nil }
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format),
              let dictionary = root as? [String: Any] else {
            return nil
        }
        guard let files2 = dictionary["files2"] as? [String: Any] else {
            return SealedResourceManifest(entries: [], omittedEntryCount: 0, hasFiles2: false)
        }
        let keys = files2.keys.sorted()
        var entries: [Entry] = []
        entries.reserveCapacity(min(keys.count, maximumEntries))
        for key in keys.prefix(maximumEntries) {
            guard let value = files2[key] else { continue }
            var sha256: Data?
            var isOptional = false
            var isSymbolicLink = false
            var isNestedCode = false
            if let details = value as? [String: Any] {
                sha256 = details["hash2"] as? Data
                isOptional = (details["optional"] as? Bool) ?? false
                isSymbolicLink = details["symlink"] != nil
                isNestedCode = details["cdhash"] != nil || details["requirement"] != nil
            }
            // A bare data value is the legacy SHA-1 form; it carries no hash2.
            entries.append(Entry(
                recordedPath: MachOText.sanitized(key, limit: 1_024),
                path: BundlePath(rawValue: key),
                sha256: sha256.flatMap { $0.count == DigestAlgorithm.sha256.digestLength ? $0 : nil },
                isOptional: isOptional,
                isSymbolicLink: isSymbolicLink,
                isNestedCode: isNestedCode
            ))
        }
        return SealedResourceManifest(
            entries: entries,
            omittedEntryCount: max(0, keys.count - entries.count),
            hasFiles2: true
        )
    }

    /// Entries whose content ZynSign can re-hash: files with a SHA-256
    /// digest and a safe path.
    var verifiableFileEntries: [Entry] {
        entries.filter { !$0.isSymbolicLink && !$0.isNestedCode && $0.sha256 != nil && $0.path != nil }
    }
}

/// The outcome of re-hashing every sealed file of one bundle.
struct SealedResourceVerification: Equatable {

    /// At most this many paths are retained per list.
    static let maximumListedPaths = 50

    /// Files re-hashed and compared.
    let checkedCount: Int
    /// Files whose SHA-256 matched the seal.
    let matchedCount: Int
    /// Files whose content differs from the seal (first paths).
    let mismatchedPaths: [String]
    let mismatchCount: Int
    /// Sealed files the bundle no longer contains and that are not optional.
    let missingPaths: [String]
    let missingCount: Int
    /// Sealed files that could not be read within the inspection bounds.
    let unreadablePaths: [String]
    let unreadableCount: Int
    /// Entries not re-hashed because they record symbolic links, nested code
    /// (verified as its own executable), unsafe paths, or no SHA-256 digest.
    let skippedCount: Int
    /// Entries beyond the per-seal bound.
    let omittedCount: Int
    let verifiedAt: Date

    var status: BinaryCheckStatus {
        if mismatchCount > 0 || missingCount > 0 { return .failed }
        if unreadableCount > 0 || omittedCount > 0 { return .notPerformed }
        return checkedCount > 0 ? .passed : .notApplicable
    }

    var summary: String {
        switch status {
        case .passed:
            return "\(matchedCount.formatted()) of \(checkedCount.formatted()) sealed files match"
        case .failed:
            var parts: [String] = []
            if mismatchCount > 0 { parts.append("\(mismatchCount.formatted()) changed") }
            if missingCount > 0 { parts.append("\(missingCount.formatted()) missing") }
            return "Sealed files: " + parts.joined(separator: ", ")
        case .notPerformed:
            return "\(matchedCount.formatted()) of \(checkedCount.formatted()) checked files match; some could not be checked"
        case .warning, .notApplicable:
            return "No sealed files to check"
        }
    }
}
