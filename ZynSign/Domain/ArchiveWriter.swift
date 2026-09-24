import Foundation

/// The kind of content one written archive entry carries.
///
/// The writer models exactly the entry forms ZynSign can produce honestly:
/// directories, regular files with an executable bit, and symbolic links
/// whose target is recorded as UTF-8 bytes. Anything else — sockets, FIFOs,
/// device nodes, hard links — has no representation here and therefore
/// cannot be written.
enum ArchiveWriteEntryKind: Equatable, Hashable {

    /// A container directory. Carries no content.
    case directory

    /// An ordinary file. `isExecutable` records the owner-executable bit;
    /// files are otherwise owner-writable and group/other-readable.
    case regularFile(isExecutable: Bool)

    /// A symbolic link. The entry's content carries the link target as
    /// UTF-8 bytes: a relative, traversal-free location.
    case symbolicLink
}

/// One entry to place in a written archive container.
///
/// `ArchiveWriteEntry` is the domain's description of content to write: a
/// validated container-internal path, the kind of entry to record, and the
/// content bytes. It carries no filesystem location and no source handle;
/// the caller that lists a bundle directory is responsible for reading
/// those bytes before building entries.
///
/// Coherence between kind and content — directories carry none, links carry
/// a valid relative target — is enforced by `ArchiveWritePlan`, not by this
/// value, so that every refusal arrives with the plan's typed error.
struct ArchiveWriteEntry: Equatable, Hashable {

    /// The entry's location inside the container.
    let path: ArchivePath

    /// The kind of entry to record.
    let kind: ArchiveWriteEntryKind

    /// The content bytes: file content, link-target UTF-8 bytes, or empty
    /// for a directory.
    let content: Data

    init(path: ArchivePath, kind: ArchiveWriteEntryKind, content: Data = Data()) {
        self.path = path
        self.kind = kind
        self.content = content
    }

    /// Whether this entry records a directory.
    var isDirectory: Bool {
        if case .directory = kind {
            return true
        }
        return false
    }
}

/// The resource policy ZynSign applies while writing an archive container.
///
/// Unlike the inspection policy, which defends against hostile input, this
/// policy defends against unbounded work the caller asks for: the entry set
/// is caller-supplied, so the writer refuses sets it cannot deterministically
/// bound before writing anything.
struct ArchiveWritePolicy: Equatable, Hashable {

    /// The greatest number of entries one written container may hold,
    /// including implied directory entries.
    let maximumEntryCount: Int

    /// The greatest accepted entry-name length, in UTF-8 bytes.
    let maximumNameBytes: Int

    /// The greatest accepted total content size, in bytes, across all entries.
    let maximumTotalBytes: Int

    init(maximumEntryCount: Int, maximumNameBytes: Int, maximumTotalBytes: Int) {
        self.maximumEntryCount = maximumEntryCount
        self.maximumNameBytes = maximumNameBytes
        self.maximumTotalBytes = maximumTotalBytes
    }

    /// The policy ZynSign applies unless the composition root chooses another.
    static let `default` = ArchiveWritePolicy(
        maximumEntryCount: 100_000,
        maximumNameBytes: 4_096,
        maximumTotalBytes: 2 * 1_024 * 1_024 * 1_024
    )
}

/// A validated, deterministic entry set ready for serialization.
///
/// The plan is the single enforcement point for everything the writer
/// promises: every entry is validated, implied parent directories are
/// inserted, duplicates and kind conflicts are refused, and the result is
/// ordered by ascending UTF-8 bytes of the recorded name. Two plans built
/// from the same entry set are equal whatever order the caller supplied,
/// and a writer that serializes a plan in order produces byte-identical
/// containers for equal input.
struct ArchiveWritePlan: Equatable {

    /// The validated entries in serialization order.
    let entries: [ArchiveWriteEntry]

    /// The recorded container name of one planned entry: directories carry
    /// the conventional trailing separator, everything else its plain path.
    static func recordedName(for entry: ArchiveWriteEntry) -> String {
        switch entry.kind {
        case .directory:
            return entry.path.rawValue + "/"
        case .regularFile, .symbolicLink:
            return entry.path.rawValue
        }
    }

    /// Validates an entry set into a serialization plan.
    ///
    /// - Parameters:
    ///   - entries: The caller-supplied entries, in any order.
    ///   - policy: The resource policy to enforce.
    /// - Throws: A typed `ZynSignError` refusing duplicates, kind
    ///   conflicts, incoherent content, unrepresentable link targets, or
    ///   any bound the policy sets. Nothing is written on any failure.
    static func plan(
        entries: [ArchiveWriteEntry],
        policy: ArchiveWritePolicy = .default
    ) throws -> ArchiveWritePlan {
        var seen: [String: ArchiveWriteEntryKind] = [:]
        var totalBytes = 0

        for entry in entries {
            let name = entry.path.rawValue
            guard seen[name] == nil else {
                throw ZynSignError.packagingFailure(
                    diagnosticDetail: "The entry set records '\(name)' more than once."
                )
            }
            let nameBytes = recordedName(for: entry).utf8.count
            guard nameBytes <= policy.maximumNameBytes else {
                throw ZynSignError.packagingFailure(
                    diagnosticDetail: "The entry name of \(nameBytes) bytes exceeds the accepted maximum of \(policy.maximumNameBytes)."
                )
            }
            switch entry.kind {
            case .directory:
                guard entry.content.isEmpty else {
                    throw ZynSignError.packagingFailure(
                        diagnosticDetail: "The directory entry '\(name)' carries content, which directories cannot record."
                    )
                }
            case .regularFile:
                break
            case .symbolicLink:
                try validateLinkTarget(
                    entry.content,
                    entryName: name,
                    directoryDepth: entry.path.components.count - 1
                )
            }
            let (accumulated, overflow) = totalBytes.addingReportingOverflow(entry.content.count)
            guard !overflow, accumulated <= policy.maximumTotalBytes else {
                throw ZynSignError.packagingFailure(
                    diagnosticDetail: "The entry set carries more content than the accepted maximum of \(policy.maximumTotalBytes) bytes."
                )
            }
            totalBytes = accumulated
            seen[name] = entry.kind
        }

        // Implied parent directories: every ancestor of every entry must be
        // recorded, and an ancestor that an explicit entry already claims as
        // a file or a link is a conflict rather than a directory.
        var planned = entries
        var implied: [String] = []
        var impliedSet: Set<String> = []
        for entry in entries {
            var components = entry.path.components
            components.removeLast()
            var prefix = ""
            for component in components {
                if prefix.isEmpty {
                    prefix = component
                } else {
                    prefix = prefix + "/" + component
                }
                if let claimed = seen[prefix] {
                    if case .directory = claimed {
                        continue
                    }
                    throw ZynSignError.packagingFailure(
                        diagnosticDetail: "The entry '\(prefix)' is both a directory and another entry kind."
                    )
                }
                if !impliedSet.contains(prefix) {
                    impliedSet.insert(prefix)
                    implied.append(prefix)
                }
            }
        }
        for ancestor in implied {
            guard let path = ArchivePath(rawValue: ancestor) else {
                throw ZynSignError.packagingFailure(
                    diagnosticDetail: "An implied directory name could not be represented as an archive path."
                )
            }
            seen[ancestor] = .directory
            planned.append(ArchiveWriteEntry(path: path, kind: .directory))
        }

        guard planned.count <= policy.maximumEntryCount else {
            throw ZynSignError.packagingFailure(
                diagnosticDetail: "The entry set holds \(planned.count) entries, beyond the accepted maximum of \(policy.maximumEntryCount)."
            )
        }

        planned.sort { left, right in
            recordedName(for: left).utf8.lexicographicallyPrecedes(recordedName(for: right).utf8)
        }
        return ArchiveWritePlan(entries: planned)
    }

    private static func validateLinkTarget(
        _ target: Data,
        entryName: String,
        directoryDepth: Int
    ) throws {
        guard !target.isEmpty else {
            throw ZynSignError.packagingFailure(
                diagnosticDetail: "The link entry '\(entryName)' records an empty target."
            )
        }
        guard let text = String(data: target, encoding: .utf8) else {
            throw ZynSignError.packagingFailure(
                diagnosticDetail: "The link entry '\(entryName)' records a target that is not valid text."
            )
        }
        // A recorded target must be relative and must resolve inside the
        // container: it is resolved against the link's own directory, never
        // against a filesystem root, and never above the container root.
        guard isContainedLinkTarget(text, directoryDepth: directoryDepth) else {
            throw ZynSignError.packagingFailure(
                diagnosticDetail: "The link entry '\(entryName)' records a target outside the container."
            )
        }
    }

    /// Whether a link target resolves inside the container. The rule
    /// lives on `ArchivePath` so that writing and extraction share one
    /// definition of a contained target.
    private static func isContainedLinkTarget(_ target: String, directoryDepth: Int) -> Bool {
        ArchivePath.isContainedLinkTarget(target, directoryDepth: directoryDepth)
    }
}

/// The boundary through which ZynSign writes an archive container.
///
/// The port is deliberately narrow: it serializes a validated entry set in
/// deterministic order, emitting bytes to a caller-supplied sink so that
/// file-backed and memory-backed destinations share one implementation. It
/// does not list directories, read files, or choose what to include — the
/// caller builds the entry set, the plan validates it, and the writer
/// serializes the plan.
///
/// Implementations are substitutable behind this port. Whatever container
/// form an implementation writes, it keeps the plan's promises: refused
/// input is never partially written, and equal plans produce byte-identical
/// output.
protocol ArchiveWriter {

    /// Serializes an entry set, emitting container bytes to `sink` in order.
    ///
    /// The entries are planned first: validation, implied directories, and
    /// deterministic ordering all happen before the first byte is emitted,
    /// so a refused set writes nothing. Emission is incremental — the sink
    /// receives the container in pieces — so large containers never require
    /// the whole output in memory at once.
    ///
    /// - Parameters:
    ///   - entries: The entries to record, in any order.
    ///   - policy: The resource policy to enforce.
    ///   - sink: Receives container bytes in serialization order.
    /// - Throws: A typed `ZynSignError` refusing the entry set, exceeding
    ///   the container form's own ceilings, or reporting a sink failure.
    func writeArchive(
        entries: [ArchiveWriteEntry],
        policy: ArchiveWritePolicy,
        sink: (Data) throws -> Void
    ) throws
}

extension ArchiveWriter {

    /// Serializes an entry set into memory.
    ///
    /// A convenience over `writeArchive` for callers whose containers fit
    /// comfortably in memory — tests above all. Production packaging of
    /// application bundles streams to a file instead.
    func serializedArchive(
        entries: [ArchiveWriteEntry],
        policy: ArchiveWritePolicy = .default
    ) throws -> Data {
        var output = Data()
        try writeArchive(entries: entries, policy: policy) { chunk in
            output.append(chunk)
        }
        return output
    }
}
