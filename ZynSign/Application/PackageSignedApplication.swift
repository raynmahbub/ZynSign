import Foundation

/// A request to rebuild one signed application bundle as an installable
/// package container.
struct PackageSignedApplicationRequest: Equatable {

    /// The signed `<Name>.app` directory to package. Read but never modified.
    let bundleDirectory: URL

    /// The bundle directory's own name, including the `.app` suffix.
    let bundleName: String

    /// Where the rebuilt container is written. Any partial file is removed
    /// when packaging fails.
    let outputURL: URL

    /// The resource policy for the written container.
    let policy: ArchiveWritePolicy

    init(
        bundleDirectory: URL,
        bundleName: String,
        outputURL: URL,
        policy: ArchiveWritePolicy = .default
    ) {
        self.bundleDirectory = bundleDirectory
        self.bundleName = bundleName
        self.outputURL = outputURL
        self.policy = policy
    }
}

/// What one packaging run produced and established.
struct PackageSignedApplicationReport: Equatable {

    /// The bundle's location inside the rebuilt container.
    let bundlePath: ArchivePath

    /// The number of entries recorded in the container, including directories.
    let entryCount: Int

    /// The rebuilt container's size in bytes.
    let outputBytes: Int
}

/// Rebuilds a signed application bundle as a deterministic package container.
///
/// Packaging reads a working-copy bundle directory — the signed output of
/// the signing pipeline — and writes `Payload/<Name>.app/...` through the
/// `ArchiveWriter` boundary: validated entry set, deterministic ordering,
/// preserved executable bits and symbolic links, and no timestamps or other
/// run-varying bytes. The bundle directory is never modified.
///
/// The produced container is then reopened through the ordinary archive
/// boundary and held to the same rules as any imported package: structural
/// validation must pass, the bundle must be discovered at its expected
/// location, and the recorded entry sequence must equal the plan that
/// produced it. A container that fails any of those checks is removed and
/// reported, never delivered.
struct PackageSignedApplication {

    private let writer: any ArchiveWriter
    private let limits: ArchiveLimits
    private let makeReader: (URL) -> any ArchiveReader

    /// Creates the use case over the selected writer and reader.
    ///
    /// - Parameters:
    ///   - writer: The archive writer, selected by the composition root.
    ///   - limits: The resource policy for reading bundle files and for the
    ///     reopen validation.
    ///   - makeReader: Builds the archive reader the reopen validation runs
    ///     through. A closure rather than a second provider port, because it
    ///     names no storage convention of its own.
    init(
        writer: any ArchiveWriter,
        limits: ArchiveLimits = .default,
        makeReader: @escaping (URL) -> any ArchiveReader = { ZipArchiveReader(location: $0) }
    ) {
        self.writer = writer
        self.limits = limits
        self.makeReader = makeReader
    }

    /// Packages one signed bundle directory.
    func package(_ request: PackageSignedApplicationRequest) async throws -> PackageSignedApplicationReport {
        try Task.checkCancellation()
        guard IPALayout.namesApplicationBundle(request.bundleName) else {
            throw ZynSignError.packagingFailure(
                diagnosticDetail: "The bundle name is not an application bundle name."
            )
        }
        guard let bundlePath = ArchivePath(rawValue: "Payload/\(request.bundleName)") else {
            throw ZynSignError.packagingFailure(
                diagnosticDetail: "The bundle location could not be represented as an archive path."
            )
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: request.bundleDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ZynSignError.packagingFailure(
                diagnosticDetail: "The bundle directory is not available for packaging."
            )
        }

        let entries = try await collectEntries(bundleDirectory: request.bundleDirectory, bundlePath: bundlePath)
        guard let information = entries.first(where: { $0.path.rawValue == bundlePath.rawValue + "/Info.plist" }) else {
            throw ZynSignError.packagingFailure(
                diagnosticDetail: "The bundle carries no information file to package."
            )
        }
        guard case .regularFile(_) = information.kind else {
            throw ZynSignError.packagingFailure(
                diagnosticDetail: "The bundle information location is not a regular file."
            )
        }

        let plan = try ArchiveWritePlan.plan(entries: entries, policy: request.policy)
        try writeContainer(plan: plan, outputURL: request.outputURL)
        try Task.checkCancellation()
        try await validateReopenedContainer(outputURL: request.outputURL, plan: plan, bundlePath: bundlePath)

        let outputBytes: Int
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: request.outputURL.path)
            outputBytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        } catch {
            throw ZynSignError.packagingFailure(
                diagnosticDetail: "The rebuilt container could not be measured.",
                underlyingError: error
            )
        }
        return PackageSignedApplicationReport(
            bundlePath: bundlePath,
            entryCount: plan.entries.count,
            outputBytes: outputBytes
        )
    }

    // MARK: - Collection

    private func collectEntries(
        bundleDirectory: URL,
        bundlePath: ArchivePath
    ) async throws -> [ArchiveWriteEntry] {
        var entries: [ArchiveWriteEntry] = []
        var stack: [URL] = [bundleDirectory]
        let fileManager = FileManager.default

        while let directory = stack.popLast() {
            try Task.checkCancellation()
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey],
                    options: []
                )
            } catch {
                throw ZynSignError.packagingFailure(
                    diagnosticDetail: "A bundle directory could not be listed for packaging.",
                    underlyingError: error
                )
            }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let relative = child.path.replacingOccurrences(
                    of: bundleDirectory.path + "/",
                    with: "",
                    options: [.anchored]
                )
                guard let entryPath = ArchivePath(rawValue: bundlePath.rawValue + "/" + relative) else {
                    throw ZynSignError.packagingFailure(
                        diagnosticDetail: "A bundle location cannot be represented as an archive path."
                    )
                }
                let values: URLResourceValues
                do {
                    values = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
                } catch {
                    throw ZynSignError.packagingFailure(
                        diagnosticDetail: "A bundle location could not be examined for packaging.",
                        underlyingError: error
                    )
                }
                if values.isSymbolicLink == true {
                    let target: String
                    do {
                        target = try fileManager.destinationOfSymbolicLink(atPath: child.path)
                    } catch {
                        throw ZynSignError.packagingFailure(
                            diagnosticDetail: "A bundle symbolic link could not be read for packaging.",
                            underlyingError: error
                        )
                    }
                    guard let targetData = target.data(using: .utf8) else {
                        throw ZynSignError.packagingFailure(
                            diagnosticDetail: "A bundle symbolic link records a target that is not valid text."
                        )
                    }
                    entries.append(ArchiveWriteEntry(path: entryPath, kind: .symbolicLink, content: targetData))
                    continue
                }
                if values.isDirectory == true {
                    stack.append(child)
                    continue
                }
                guard values.isRegularFile == true else {
                    throw ZynSignError.packagingFailure(
                        diagnosticDetail: "A bundle location is an entry form packaging cannot reproduce."
                    )
                }
                entries.append(try fileEntry(at: child, path: entryPath))
            }
        }
        return entries
    }

    private func fileEntry(at url: URL, path: ArchivePath) throws -> ArchiveWriteEntry {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw ZynSignError.packagingFailure(
                diagnosticDetail: "A bundle file could not be examined for packaging.",
                underlyingError: error
            )
        }
        if let size = (attributes[.size] as? NSNumber)?.intValue, size > limits.maximumEntryBytes {
            throw ZynSignError.archiveResourceLimitExceeded(
                diagnosticDetail: "A bundle file is larger than this packaging accepts."
            )
        }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        let content: Data
        do {
            content = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ZynSignError.packagingFailure(
                diagnosticDetail: "A bundle file could not be read for packaging.",
                underlyingError: error
            )
        }
        guard content.count <= limits.maximumEntryBytes else {
            throw ZynSignError.archiveResourceLimitExceeded(
                diagnosticDetail: "A bundle file is larger than this packaging accepts."
            )
        }
        return ArchiveWriteEntry(
            path: path,
            kind: .regularFile(isExecutable: permissions & 0o111 != 0),
            content: content
        )
    }

    // MARK: - Writing and reopen validation

    private func writeContainer(plan: ArchiveWritePlan, outputURL: URL) throws {
        // A previous file at the output location must not survive beneath
        // a shorter container: writing opens without truncating.
        try? FileManager.default.removeItem(at: outputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: outputURL)
        } catch {
            throw ZynSignError.packagingFailure(
                diagnosticDetail: "The rebuilt container could not be opened for writing.",
                underlyingError: error
            )
        }
        do {
            try writer.writeArchive(entries: plan.entries, policy: .default) { chunk in
                try handle.write(contentsOf: chunk)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: outputURL)
            if let zynSignError = error as? ZynSignError {
                throw zynSignError
            }
            throw ZynSignError.packagingFailure(
                diagnosticDetail: "The rebuilt container could not be written.",
                underlyingError: error
            )
        }
    }

    private func validateReopenedContainer(
        outputURL: URL,
        plan: ArchiveWritePlan,
        bundlePath: ArchivePath
    ) async throws {
        let reader = makeReader(outputURL)
        defer { reader.close() }
        do {
            let table = try reader.readEntryTable()
            let inspection = IPAStructureValidator(limits: limits).validate(entryTable: table)
            guard inspection.isValid else {
                throw ZynSignError.packagingFailure(
                    diagnosticDetail: "The rebuilt container failed structural validation on reopen."
                )
            }
            guard inspection.bundle?.bundlePath == bundlePath else {
                throw ZynSignError.packagingFailure(
                    diagnosticDetail: "The rebuilt container does not carry the bundle at its expected location."
                )
            }
            let recorded = table.map { $0.rawName }
            let planned = plan.entries.map { ArchiveWritePlan.recordedName(for: $0) }
            guard recorded == planned else {
                throw ZynSignError.packagingFailure(
                    diagnosticDetail: "The rebuilt container does not match the plan that produced it."
                )
            }
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            if let zynSignError = error as? ZynSignError {
                throw zynSignError
            }
            throw ZynSignError.packagingFailure(
                diagnosticDetail: "The rebuilt container could not be validated on reopen.",
                underlyingError: error
            )
        }
    }
}
