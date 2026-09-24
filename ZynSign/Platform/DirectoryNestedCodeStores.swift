import Foundation

/// Reads and writes binary artifacts inside one working-copy bundle
/// directory.
///
/// Bundle paths are bundle-relative and traversal-free by construction, so
/// every operation stays beneath the bundle directory without further
/// confinement checks. Reads refuse anything that is not a regular file;
/// writes replace the bytes atomically, preserve the previous permission
/// bits across the replacement, and refuse to create parent directories,
/// because every path the signing plan names already exists in a validated
/// working copy.
final class DirectoryBundleBinaryStore: NestedSigningArtifactStore {

    /// The working-copy `<Name>.app` directory the store is bounded to.
    let bundleDirectory: URL

    /// The greatest binary size the store reads, in bytes.
    let maximumBinaryBytes: Int

    init(bundleDirectory: URL, maximumBinaryBytes: Int) {
        self.bundleDirectory = bundleDirectory
        self.maximumBinaryBytes = maximumBinaryBytes
    }

    func readBinary(at path: BundlePath) throws -> Data {
        let url = url(for: path)
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw NestedSigningFailure(
                reason: .artifactReadFailure,
                path: path,
                detail: "A target binary could not be examined.",
                category: .storageFailure,
                mutationOccurred: false
            )
        }
        guard values.isRegularFile == true else {
            throw NestedSigningFailure(
                reason: .artifactReadFailure,
                path: path,
                detail: "A target location is not a regular file.",
                category: .invalidInput,
                mutationOccurred: false
            )
        }
        if let size = values.fileSize, size > maximumBinaryBytes {
            throw NestedSigningFailure(
                reason: .artifactReadFailure,
                path: path,
                detail: "A target binary is larger than this signing accepts.",
                category: .invalidInput,
                mutationOccurred: false
            )
        }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= maximumBinaryBytes else {
                throw NestedSigningFailure(
                    reason: .artifactReadFailure,
                    path: path,
                    detail: "A target binary is larger than this signing accepts.",
                    category: .invalidInput,
                    mutationOccurred: false
                )
            }
            return data
        } catch let failure as NestedSigningFailure {
            throw failure
        } catch {
            throw NestedSigningFailure(
                reason: .artifactReadFailure,
                path: path,
                detail: "A target binary could not be read.",
                category: .storageFailure,
                mutationOccurred: false
            )
        }
    }

    func writeBinary(_ bytes: Data, at path: BundlePath) throws {
        let url = url(for: path)
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else {
            throw NestedSigningFailure(
                reason: .artifactWriteFailure,
                path: path,
                detail: "A target's container is missing from the working copy.",
                category: .storageFailure,
                mutationOccurred: false
            )
        }
        // An atomic replacement resets permission bits, so the previous
        // bits are carried across: extraction established them from the
        // container's recorded modes, and signing must not clear them.
        let previousPermissions: Int?
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            previousPermissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        } catch {
            previousPermissions = nil
        }
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw NestedSigningFailure(
                reason: .artifactWriteFailure,
                path: path,
                detail: "A signed target binary could not be written.",
                category: .storageFailure,
                mutationOccurred: false
            )
        }
        if let previousPermissions {
            do {
                try FileManager.default.setAttributes([.posixPermissions: previousPermissions], ofItemAtPath: url.path)
            } catch {
                throw NestedSigningFailure(
                    reason: .artifactWriteFailure,
                    path: path,
                    detail: "Permissions on a signed target binary could not be restored.",
                    category: .storageFailure,
                    mutationOccurred: true
                )
            }
        }
    }

    private func url(for path: BundlePath) -> URL {
        var url = bundleDirectory
        for component in path.components {
            url.appendPathComponent(component)
        }
        return url
    }
}

/// Lists and reads the resources of one working-copy bundle directory.
///
/// The walk is iterative and never follows a symbolic link: links are
/// reported as links and left for the sealing configuration's explicit
/// policy. Directory entries are reported as directories and produce no
/// seal entries; anything that is neither a regular file, a directory, nor
/// a link stops the walk with a traversal failure rather than being
/// silently skipped.
///
/// Nested containers are listed but never descended into. The seal
/// references nested code by caller-supplied seals over paths the walk
/// never reports — a nested path that also appears in the listing is
/// refused as a collision — so the contents of every nested container
/// stay out of the file walk by construction.
final class DirectoryResourceContentStore: ResourceContentStore {

    /// The working-copy `<Name>.app` directory the store is bounded to.
    let bundleDirectory: URL

    /// The nested container directories the walk lists but never descends
    /// into, relative to the bundle root.
    let nestedContainers: Set<BundlePath>

    init(bundleDirectory: URL, nestedContainers: Set<BundlePath> = []) {
        self.bundleDirectory = bundleDirectory
        self.nestedContainers = nestedContainers
    }

    func listEntries() throws -> [ResourceListingEntry] {
        var entries: [ResourceListingEntry] = []
        var stack: [[String]] = [[]]
        let fileManager = FileManager.default
        while let components = stack.popLast() {
            var directory = bundleDirectory
            for component in components {
                directory.appendPathComponent(component)
            }
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey],
                    options: []
                )
            } catch {
                throw ResourceSealError.traversalFailure(detail: "A bundle directory could not be listed.")
            }
            for child in children {
                let entry = try classify(child: child, parentComponents: components)
                entries.append(entry)
                if case .directory = entry.kind, !nestedContainers.contains(entry.path) {
                    stack.append(components + [child.lastPathComponent])
                }
            }
        }
        return entries
    }

    func readResource(at path: BundlePath) throws -> Data {
        var url = bundleDirectory
        for component in path.components {
            url.appendPathComponent(component)
        }
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ResourceSealError.resourceUnavailable(path)
        }
    }

    private func classify(child: URL, parentComponents: [String]) throws -> ResourceListingEntry {
        let values: URLResourceValues
        do {
            values = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
        } catch {
            throw ResourceSealError.traversalFailure(detail: "A bundle location could not be examined.")
        }
        guard let path = BundlePath(components: parentComponents + [child.lastPathComponent]) else {
            throw ResourceSealError.traversalFailure(detail: "A bundle location cannot be represented as a bundle path.")
        }
        if values.isSymbolicLink == true {
            return ResourceListingEntry(path: path, kind: .symbolicLink)
        }
        if values.isDirectory == true {
            return ResourceListingEntry(path: path, kind: .directory)
        }
        guard values.isRegularFile == true else {
            throw ResourceSealError.traversalFailure(detail: "A bundle location is an entry form sealing cannot represent.")
        }
        return ResourceListingEntry(path: path, kind: .file, byteCount: values.fileSize)
    }
}
