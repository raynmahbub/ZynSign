import Foundation

/// What the extractor does with symbolic-link entries.
enum ArchiveExtractionSymlinkPolicy: Equatable {

    /// Refuse any container that records a symbolic link.
    case refuse

    /// Recreate links whose recorded target is relative and resolves inside
    /// the destination. Absolute targets, escaping targets, and targets that
    /// are not valid text are refused along with the whole container.
    case recreateWithinRoot
}

/// The resource policy ZynSign applies while extracting an archive container.
struct ArchiveExtractionPolicy: Equatable {

    /// The greatest total content size accepted for one extraction, in bytes.
    /// Both the container's declared sizes and the bytes actually written are
    /// enforced against this bound.
    let maximumExtractedBytes: Int

    /// The greatest accepted symbolic-link target length, in bytes.
    let maximumLinkTargetBytes: Int

    /// What happens to symbolic-link entries.
    let symlinkPolicy: ArchiveExtractionSymlinkPolicy

    init(
        maximumExtractedBytes: Int,
        maximumLinkTargetBytes: Int,
        symlinkPolicy: ArchiveExtractionSymlinkPolicy
    ) {
        self.maximumExtractedBytes = maximumExtractedBytes
        self.maximumLinkTargetBytes = maximumLinkTargetBytes
        self.symlinkPolicy = symlinkPolicy
    }

    /// The policy ZynSign applies unless the caller chooses another: links
    /// refused, content bounded by the container form's own ceiling.
    static let `default` = ArchiveExtractionPolicy(
        maximumExtractedBytes: 4 * 1_024 * 1_024 * 1_024,
        maximumLinkTargetBytes: 4_096,
        symlinkPolicy: .refuse
    )
}

/// What one extraction produced.
struct ArchiveExtractionReport: Equatable {

    /// The number of regular files written.
    let fileCount: Int

    /// The number of directories created, including implied ones.
    let directoryCount: Int

    /// The number of symbolic links recreated.
    let symbolicLinkCount: Int

    /// The total file content bytes written, excluding directory entries
    /// and link targets.
    let extractedBytes: Int
}

/// Extracts an archive container's entries into a destination directory.
///
/// The extractor reads through the `ArchiveReader` boundary — entry table
/// first, then one bounded content read per entry — and writes regular
/// files, directories, and (under an explicit policy) symbolic links. Every
/// entry is validated before anything is written: unsafe names, duplicates,
/// kind conflicts, unsupported entry forms, and resource overflows refuse
/// the whole container rather than producing a partial tree.
///
/// Ordering is deliberate. Directories are created shallow-first, then
/// files, and symbolic links last, so no link can redirect a write that
/// follows it. Every written location is confined to the destination by its
/// canonical path with the boundary on a separator, and every link target
/// must resolve inside the destination. File permission bits come from the
/// Unix mode the container records when it records one — any execute bit
/// becomes owner-executable, anything else becomes a plain readable file —
/// and directories are always created traversable.
///
/// The extractor never follows a link it recreates and never reads outside
/// the container. A failed extraction may leave a partial tree behind; the
/// caller owns the destination directory and discards it on failure.
struct DirectoryArchiveExtractor {

    /// The directory extracted entries are written beneath. Created when the
    /// extraction begins.
    let destination: URL

    /// The resource and link policy to enforce.
    let policy: ArchiveExtractionPolicy

    /// The per-entry content bound requested from the reader. The reader's
    /// own policy still applies, so a caller cannot widen it.
    let readBound: Int

    init(
        destination: URL,
        policy: ArchiveExtractionPolicy = .default,
        readBound: Int = ArchiveLimits.extraction.maximumInspectionReadBytes
    ) {
        self.destination = destination
        self.policy = policy
        self.readBound = readBound
    }

    /// Extracts every entry the reader records into the destination.
    ///
    /// - Parameter reader: The container to extract from. The caller owns
    ///   the reader's lifecycle; this method does not close it.
    /// - Returns: A report of what was written.
    /// - Throws: `CancellationError`, or a typed `ZynSignError` refusing an
    ///   unsafe, conflicting, unsupported, or over-large container, or
    ///   reporting a read or write failure.
    func extract(reader: any ArchiveReader) async throws -> ArchiveExtractionReport {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            throw ZynSignError.packagingFailure(
                diagnosticDetail: "The extraction destination could not be created.",
                underlyingError: error
            )
        }
        let canonicalRoot = destination.standardizedFileURL.resolvingSymlinksInPath().path

        let table = try reader.readEntryTable()
        let planned = try validate(table: table)

        var extractedBytes = 0
        var directoryCount = 0
        for directory in planned.directories {
            try Task.checkCancellation()
            let url = try confinedURL(for: directory, canonicalRoot: canonicalRoot)
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o755]
                )
            } catch {
                throw ZynSignError.packagingFailure(
                    diagnosticDetail: "A directory in the extracted tree could not be created.",
                    underlyingError: error
                )
            }
            try setPermissions(0o755, at: url)
            directoryCount += 1
        }

        var fileCount = 0
        for file in planned.files {
            try Task.checkCancellation()
            let url = try confinedURL(for: file.path, canonicalRoot: canonicalRoot)
            let content = try reader.readEntryData(at: file.path, maximumBytes: readBound)
            extractedBytes = try adding(extractedBytes, content.count)
            do {
                try content.write(to: url, options: .atomic)
            } catch {
                throw ZynSignError.packagingFailure(
                    diagnosticDetail: "An extracted file could not be written.",
                    underlyingError: error
                )
            }
            try setPermissions(permissions(for: file.entry), at: url)
            fileCount += 1
        }

        var symbolicLinkCount = 0
        for link in planned.symbolicLinks {
            try Task.checkCancellation()
            let target = try linkTarget(for: link, reader: reader)
            let url = try confinedURL(for: link.path, canonicalRoot: canonicalRoot)
            try confinedTarget(target, linkPath: link.path, canonicalRoot: canonicalRoot)
            do {
                try fileManager.createSymbolicLink(at: url, withDestinationPath: target)
            } catch {
                throw ZynSignError.packagingFailure(
                    diagnosticDetail: "An extracted symbolic link could not be recreated.",
                    underlyingError: error
                )
            }
            symbolicLinkCount += 1
        }

        return ArchiveExtractionReport(
            fileCount: fileCount,
            directoryCount: directoryCount,
            symbolicLinkCount: symbolicLinkCount,
            extractedBytes: extractedBytes
        )
    }

    // MARK: - Planning

    private struct PlannedEntry {
        let path: ArchivePath
        let entry: ArchiveEntry
    }

    private struct PlannedExtraction {
        let directories: [ArchivePath]
        let files: [PlannedEntry]
        let symbolicLinks: [PlannedEntry]
    }

    private func validate(table: [ArchiveEntry]) throws -> PlannedExtraction {
        var kindsByPath: [String: ArchiveEntryKind] = [:]
        var declaredBytes = 0
        for entry in table {
            guard let path = entry.path else {
                throw ZynSignError.unsafeArchiveEntry(
                    diagnosticDetail: "The container records an entry ZynSign cannot safely name."
                )
            }
            guard kindsByPath[path.rawValue] == nil else {
                throw ZynSignError.unsafeArchiveEntry(
                    diagnosticDetail: "The container records one location more than once."
                )
            }
            switch entry.kind {
            case .directory, .regularFile:
                break
            case .symbolicLink:
                if policy.symlinkPolicy == .refuse {
                    throw ZynSignError.unsafeArchiveEntry(
                        diagnosticDetail: "The container records a symbolic link, which this extraction refuses."
                    )
                }
            case .unsupported:
                throw ZynSignError.unsupportedArchiveFeature(
                    diagnosticDetail: "The container records an entry form ZynSign cannot reproduce."
                )
            }
            let (accumulated, overflow) = declaredBytes.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, accumulated <= policy.maximumExtractedBytes else {
                throw ZynSignError.archiveResourceLimitExceeded(
                    diagnosticDetail: "The container declares more content than this extraction accepts."
                )
            }
            declaredBytes = accumulated
            kindsByPath[path.rawValue] = entry.kind
        }

        // Every file and link needs directory ancestors, and an ancestor
        // claimed by a non-directory entry is a conflict, not a directory.
        var implied: [String] = []
        var impliedSet: Set<String> = []
        for entry in table {
            guard let path = entry.path else {
                continue
            }
            if entry.kind == .directory {
                continue
            }
            var components = path.components
            components.removeLast()
            var prefix = ""
            for component in components {
                if prefix.isEmpty {
                    prefix = component
                } else {
                    prefix = prefix + "/" + component
                }
                if let claimed = kindsByPath[prefix] {
                    if claimed != .directory {
                        throw ZynSignError.unsafeArchiveEntry(
                            diagnosticDetail: "The container records one location as both a directory and another entry kind."
                        )
                    }
                    continue
                }
                if !impliedSet.contains(prefix) {
                    impliedSet.insert(prefix)
                    implied.append(prefix)
                }
            }
        }

        var directories: [ArchivePath] = []
        var files: [PlannedEntry] = []
        var symbolicLinks: [PlannedEntry] = []
        for entry in table {
            guard let path = entry.path else {
                continue
            }
            switch entry.kind {
            case .directory:
                directories.append(path)
            case .regularFile:
                files.append(PlannedEntry(path: path, entry: entry))
            case .symbolicLink:
                symbolicLinks.append(PlannedEntry(path: path, entry: entry))
            case .unsupported:
                throw ZynSignError.unsupportedArchiveFeature(
                    diagnosticDetail: "The container records an entry form ZynSign cannot reproduce."
                )
            }
        }
        for ancestor in implied {
            guard let path = ArchivePath(rawValue: ancestor) else {
                throw ZynSignError.unsafeArchiveEntry(
                    diagnosticDetail: "The container implies a directory ZynSign cannot safely name."
                )
            }
            directories.append(path)
        }

        directories.sort { left, right in
            if left.components.count != right.components.count {
                return left.components.count < right.components.count
            }
            return left.rawValue < right.rawValue
        }
        files.sort { left, right in
            left.path.rawValue < right.path.rawValue
        }
        symbolicLinks.sort { left, right in
            left.path.rawValue < right.path.rawValue
        }
        return PlannedExtraction(directories: directories, files: files, symbolicLinks: symbolicLinks)
    }

    // MARK: - Writing helpers

    private func confinedURL(for path: ArchivePath, canonicalRoot: String) throws -> URL {
        let url = destination.appendingPathComponent(path.rawValue)
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
        let isConfined = canonical == canonicalRoot || canonical.hasPrefix(canonicalRoot + "/")
        guard isConfined else {
            throw ZynSignError.unsafeArchiveEntry(
                diagnosticDetail: "An extracted location resolves outside the destination."
            )
        }
        return url
    }

    private func linkTarget(for link: PlannedEntry, reader: any ArchiveReader) throws -> String {
        let targetBytes = try reader.readEntryData(
            at: link.path,
            maximumBytes: min(readBound, policy.maximumLinkTargetBytes)
        )
        guard let target = String(data: targetBytes, encoding: .utf8) else {
            throw ZynSignError.unsafeArchiveEntry(
                diagnosticDetail: "A symbolic link records a target that is not valid text."
            )
        }
        return target
    }

    private func confinedTarget(_ target: String, linkPath: ArchivePath, canonicalRoot: String) throws {
        let depth = linkPath.components.count - 1
        guard ArchivePath.isContainedLinkTarget(target, directoryDepth: depth) else {
            throw ZynSignError.unsafeArchiveEntry(
                diagnosticDetail: "A symbolic link records a target outside the destination."
            )
        }
        // The lexical rule above is necessary but not sufficient on its own:
        // intermediate links in the destination could still redirect the
        // target. Links are created after every file and directory, and no
        // ancestor of any entry is a link, so resolving the would-be target
        // against the destination as it stands is conclusive.
        let linkDirectory = destination.appendingPathComponent(linkPath.rawValue).deletingLastPathComponent()
        let resolved = linkDirectory.appendingPathComponent(target).standardizedFileURL.resolvingSymlinksInPath().path
        let isConfined = resolved == canonicalRoot || resolved.hasPrefix(canonicalRoot + "/")
        guard isConfined else {
            throw ZynSignError.unsafeArchiveEntry(
                diagnosticDetail: "A symbolic link records a target outside the destination."
            )
        }
    }

    private func permissions(for entry: ArchiveEntry) -> Int {
        guard let mode = entry.unixMode else {
            return 0o644
        }
        if mode & 0o111 != 0 {
            return 0o755
        }
        return 0o644
    }

    private func setPermissions(_ permissions: Int, at url: URL) throws {
        do {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        } catch {
            throw ZynSignError.packagingFailure(
                diagnosticDetail: "Permissions on an extracted location could not be set.",
                underlyingError: error
            )
        }
    }

    private func adding(_ left: Int, _ right: Int) throws -> Int {
        let (value, overflow) = left.addingReportingOverflow(right)
        guard !overflow, value <= policy.maximumExtractedBytes else {
            throw ZynSignError.archiveResourceLimitExceeded(
                diagnosticDetail: "The extracted content grew beyond what this extraction accepts."
            )
        }
        return value
    }
}
