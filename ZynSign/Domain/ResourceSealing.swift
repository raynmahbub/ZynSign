import Foundation

/// Structured failures at the resource-sealing boundary.
///
/// Every case names the stage that refused and carries the minimum
/// identifying detail — a bundle-relative path or a bounded count — and never
/// resource contents. Paths in these errors are `BundlePath` values: relative,
/// canonical, and traversal-free by construction, so a diagnostic can never
/// leak an absolute filesystem location.
enum ResourceSealError: Error, Equatable {
    /// The store reported a path that cannot be a sealable resource (for
    /// example the bundle root itself).
    case unsealablePath(BundlePath)
    /// The store listed an entry kind the generator does not handle.
    case unsupportedEntryKind(BundlePath)
    /// A resource byte count exceeded the configured per-resource bound.
    case resourceTooLarge(BundlePath)
    /// The resource count exceeded the configured bound.
    case resourceCountExceeded
    /// The total sealed byte count exceeded the configured bound.
    case totalSealedBytesExceeded
    /// A symbolic link was encountered and the policy is fail-closed.
    case symbolicLinkRejected(BundlePath)
    /// Two entries claim the same resource path.
    case duplicateResourcePath(BundlePath)
    /// A resource could not be read from the store.
    case resourceUnavailable(BundlePath)
    /// The walk could not be completed against the store.
    case traversalFailure(detail: String)
    /// The digest port failed or returned an unexpected algorithm.
    case digestFailure
    /// The requested digest algorithm is not the resource-seal form.
    case unsupportedDigestAlgorithm(DigestAlgorithm)
    /// A checked arithmetic step overflowed.
    case integerOverflow
}

/// How symbolic links encountered during resource traversal are handled.
///
/// The walk never follows a symbolic link under either policy: following
/// links is how a walk escapes the bundle, and whether the platform's own
/// seal treats symlinks specially is **not established** in ZynSign's record
/// (**Requires experiment**). The only choice is what to do when one is
/// found, and both answers are explicit.
enum ResourceSymlinkPolicy: Equatable, Hashable {

    /// Fail the walk. This is the default: no symlink is hashed, excluded,
    /// or interpreted without an explicit decision by the caller.
    case failClosed

    /// Record the link as an omission and continue. The link is neither
    /// followed nor hashed. This is a caller's explicit configuration, not a
    /// claim that the platform's seal omits symlinks.
    case exclude
}

/// Bounds applied while sealing one resource set. ZynSign policy, chosen to
/// keep untrusted trees bounded; not Apple-documented limits.
struct ResourceSealingLimits: Equatable, Hashable {

    /// Maximum number of sealed resources in one set.
    let maximumResourceCount: Int

    /// Maximum byte count of one resource.
    let maximumResourceByteCount: Int

    /// Maximum cumulative byte count read while sealing one set.
    let maximumTotalSealedByteCount: Int

    static let `default` = ResourceSealingLimits(
        maximumResourceCount: 10_000,
        maximumResourceByteCount: 32 * 1_024 * 1_024,
        maximumTotalSealedByteCount: 512 * 1_024 * 1_024
    )

    init(
        maximumResourceCount: Int,
        maximumResourceByteCount: Int,
        maximumTotalSealedByteCount: Int
    ) {
        self.maximumResourceCount = maximumResourceCount
        self.maximumResourceByteCount = maximumResourceByteCount
        self.maximumTotalSealedByteCount = maximumTotalSealedByteCount
    }
}

/// What one listed entry is.
enum ResourceListingKind: Equatable, Hashable {
    case file
    case directory
    case symbolicLink
}

/// One entry in a store's listing. `byteCount` is the store's declared size
/// for a file when it knows one without reading; it is a hint for early
/// bounding, never a substitute for hashing the bytes actually read.
struct ResourceListingEntry: Equatable, Hashable {
    let path: BundlePath
    let kind: ResourceListingKind
    let byteCount: Int?

    init(path: BundlePath, kind: ResourceListingKind, byteCount: Int? = nil) {
        self.path = path
        self.kind = kind
        self.byteCount = byteCount
    }
}

/// Read-only access to the resources of one signing target.
///
/// The port is deliberately narrower than an archive or filesystem: it can
/// list entries and read one resource's bytes, nothing else. Listing order is
/// irrelevant to the seal — the generator imposes its own deterministic
/// order — so a store backed by unsorted filesystem enumeration cannot
/// produce a different document. All paths are `BundlePath` values, which are
/// bundle-relative and traversal-free by construction.
protocol ResourceContentStore {

    /// Lists every entry under the store's root, files, directories, and
    /// symbolic links included, in any order.
    func listEntries() throws -> [ResourceListingEntry]

    /// Reads the exact bytes of one file resource.
    ///
    /// Stores must not normalize, transform, or re-encode content: the seal
    /// hashes the bytes as stored.
    func readResource(at path: BundlePath) throws -> Data
}

/// An in-memory resource store for deterministic tests and staged sealing.
final class MemoryResourceContentStore: ResourceContentStore {

    /// The file resources, keyed by bundle-relative path.
    private(set) var files: [BundlePath: Data]

    /// Paths that behave as symbolic links. Links have no target in this
    /// model — the walk never follows one — so the path alone is enough to
    /// exercise the policy.
    private(set) var symbolicLinks: Set<BundlePath>

    init(files: [BundlePath: Data] = [:], symbolicLinks: [BundlePath] = []) {
        self.files = files
        self.symbolicLinks = Set(symbolicLinks)
    }

    func listEntries() throws -> [ResourceListingEntry] {
        var entries: [ResourceListingEntry] = files.map { path, data in
            ResourceListingEntry(path: path, kind: .file, byteCount: data.count)
        }
        entries.append(contentsOf: symbolicLinks.map {
            ResourceListingEntry(path: $0, kind: .symbolicLink)
        })
        return entries
    }

    func readResource(at path: BundlePath) throws -> Data {
        guard let data = files[path] else {
            throw ResourceSealError.resourceUnavailable(path)
        }
        return data
    }
}

/// A filesystem-backed, strictly read-only resource store rooted at a bundle
/// directory.
///
/// Defends against:
///
/// - **Path traversal and escape** — every listed path is a `BundlePath`, and
///   reads are composed by appending validated components to the root; the
///   walk never resolves a symlink, so no link can redirect it outside the
///   root.
/// - **Unbounded work** — the walk refuses more entries than the configured
///   listing bound, and reads refuse files larger than the configured byte
///   bound.
/// - **Mutation** — the store performs no write operation of any kind.
final class DirectoryResourceContentStore: ResourceContentStore {

    /// The root URL of the bundle directory this store reads.
    let bundleURL: URL

    /// The maximum number of entries one listing may report.
    let maximumListedEntries: Int

    /// The maximum byte count of one read resource.
    let maximumResourceByteCount: Int

    init(
        bundleURL: URL,
        maximumListedEntries: Int = 20_000,
        maximumResourceByteCount: Int = ResourceSealingLimits.default.maximumResourceByteCount
    ) {
        self.bundleURL = bundleURL.standardizedFileURL
        self.maximumListedEntries = maximumListedEntries
        self.maximumResourceByteCount = maximumResourceByteCount
    }

    func listEntries() throws -> [ResourceListingEntry] {
        var entries: [ResourceListingEntry] = []
        var stack: [BundlePath] = [.root]
        let fileManager = FileManager.default

        while let directory = stack.popLast() {
            let directoryURL = directory.isRoot
                ? bundleURL
                : bundleURL.appendingPathComponent(directory.rawValue)
            let children: [String]
            do {
                children = try fileManager.contentsOfDirectory(atPath: directoryURL.path)
            } catch {
                throw ResourceSealError.traversalFailure(
                    detail: "The resource directory at '\(directory.rawValue)' could not be listed."
                )
            }
            for name in children.sorted() {
                guard let path = BundlePath(components: directory.components + [name]) else {
                    // The name failed the bundle-path safety rules. It is not
                    // echoed into diagnostics: untrusted names are never
                    // copied into error text.
                    throw ResourceSealError.traversalFailure(
                        detail: "A resource name is not representable as a bundle-relative path."
                    )
                }
                entries.append(try classify(path: path))
                guard entries.count <= maximumListedEntries else {
                    throw ResourceSealError.resourceCountExceeded
                }
                if case .directory = entries.last?.kind {
                    stack.append(path)
                }
            }
        }
        return entries
    }

    func readResource(at path: BundlePath) throws -> Data {
        guard !path.isRoot else { throw ResourceSealError.unsealablePath(path) }
        let url = bundleURL.appendingPathComponent(path.rawValue)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let type = attributes[.type] as? FileAttributeType, type == .typeSymbolicLink {
                throw ResourceSealError.symbolicLinkRejected(path)
            }
            if let size = attributes[.size] as? NSNumber, size.intValue > maximumResourceByteCount {
                throw ResourceSealError.resourceTooLarge(path)
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= maximumResourceByteCount else {
                throw ResourceSealError.resourceTooLarge(path)
            }
            return data
        } catch let error as ResourceSealError {
            throw error
        } catch {
            throw ResourceSealError.resourceUnavailable(path)
        }
    }

    /// Classifies one entry without following symbolic links. A link is
    /// reported as a link whether it points at a file, a directory, or
    /// outside the bundle: the walk never distinguishes, because it never
    /// resolves.
    private func classify(path: BundlePath) throws -> ResourceListingEntry {
        let url = bundleURL.appendingPathComponent(path.rawValue)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw ResourceSealError.traversalFailure(
                detail: "The resource at '\(path.rawValue)' could not be examined."
            )
        }
        guard let type = attributes[.type] as? FileAttributeType else {
            throw ResourceSealError.unsupportedEntryKind(path)
        }
        switch type {
        case .typeSymbolicLink:
            return ResourceListingEntry(path: path, kind: .symbolicLink)
        case .typeDirectory:
            return ResourceListingEntry(path: path, kind: .directory)
        case .typeRegular:
            let byteCount = (attributes[.size] as? NSNumber)?.intValue
            return ResourceListingEntry(path: path, kind: .file, byteCount: byteCount)
        default:
            throw ResourceSealError.unsupportedEntryKind(path)
        }
    }
}

/// The caller's explicit resource-sealing configuration.
struct ResourceSealingConfiguration: Equatable, Hashable {

    /// What happens when the walk meets a symbolic link.
    let symlinkPolicy: ResourceSymlinkPolicy

    /// Paths explicitly excluded from the seal. Exclusions are the caller's
    /// decision; this layer invents none.
    let excludedPaths: Set<BundlePath>

    /// Bounds for the walk.
    let limits: ResourceSealingLimits

    static let `default` = ResourceSealingConfiguration(
        symlinkPolicy: .failClosed,
        excludedPaths: [],
        limits: .default
    )

    init(
        symlinkPolicy: ResourceSymlinkPolicy = .failClosed,
        excludedPaths: Set<BundlePath> = [],
        limits: ResourceSealingLimits = .default
    ) {
        self.symlinkPolicy = symlinkPolicy
        self.excludedPaths = excludedPaths
        self.limits = limits
    }
}

/// Generates the resource-seal document for one signing target.
///
/// The generator's contract:
///
/// - **Deterministic order.** Entries are emitted in ascending UTF-8 byte
///   order of their bundle-relative paths, regardless of the store's listing
///   order. The same tree yields the same document bytes.
/// - **Exact bytes only.** Each file is hashed exactly as stored; no content
///   is normalized, decompressed, or re-encoded. The digest algorithm is
///   SHA-256, the `hash2` form of the files2 dictionary — the only resource
///   digest form ZynSign's signing configuration uses.
/// - **Bounded work.** Resource count, per-resource size, and cumulative
///   size are enforced against the configured limits, and each resource's
///   bytes are held only while hashing it.
/// - **No invention.** Directories are structural and produce no entries;
///   exclusions come only from the configuration; symbolic links are handled
///   by the explicit policy; nested code appears only when the caller
///   supplies the final nested-code state as `NestedCodeResourceSeal` values.
///   The generator never signs nested code and never re-derives it.
struct CodeResourcesGenerator {

    private let messageDigest: any MessageDigest

    init(messageDigest: any MessageDigest) {
        self.messageDigest = messageDigest
    }

    /// Seals one resource set.
    ///
    /// - Parameters:
    ///   - store: The read-only resource store for one signing target.
    ///   - configuration: The caller's explicit policy and bounds.
    ///   - nestedCode: Final nested-code seals, each carrying the nested
    ///     binary's code-directory hash. These represent already-signed
    ///     state; this generator neither signs nor re-hashes nested code.
    func generate(
        from store: any ResourceContentStore,
        configuration: ResourceSealingConfiguration = .default,
        nestedCode: [NestedCodeResourceSeal] = []
    ) throws -> CodeResourcesDocument {
        let listing: [ResourceListingEntry]
        do {
            listing = try store.listEntries()
        } catch let error as ResourceSealError {
            throw error
        } catch {
            throw ResourceSealError.traversalFailure(detail: "The resource store could not be listed.")
        }
        guard listing.count <= configuration.limits.maximumResourceCount else {
            throw ResourceSealError.resourceCountExceeded
        }

        var omitted: [OmittedResource] = []
        var fileSeals: [FileResourceSeal] = []
        var seenPaths: Set<BundlePath> = []
        var totalSealedBytes = 0

        // Deterministic processing order: ascending path bytes.
        let sortedListing = listing.sorted { left, right in
            CanonicalPropertyListXMLSerializer.utf8Ascending(left.path.rawValue, right.path.rawValue)
        }

        for entry in sortedListing {
            let path = entry.path
            guard !path.isRoot else { throw ResourceSealError.unsealablePath(path) }

            if configuration.excludedPaths.contains(path) {
                omitted.append(OmittedResource(path: path, reason: .excludedByConfiguration))
                seenPaths.insert(path)
                continue
            }

            switch entry.kind {
            case .directory:
                // Directories are structure, not sealed content.
                continue
            case .symbolicLink:
                switch configuration.symlinkPolicy {
                case .failClosed:
                    throw ResourceSealError.symbolicLinkRejected(path)
                case .exclude:
                    omitted.append(OmittedResource(path: path, reason: .symbolicLinkExcluded))
                    seenPaths.insert(path)
                }
            case .file:
                if let byteCount = entry.byteCount, byteCount > configuration.limits.maximumResourceByteCount {
                    throw ResourceSealError.resourceTooLarge(path)
                }
                let bytes: Data
                do {
                    bytes = try store.readResource(at: path)
                } catch let error as ResourceSealError {
                    throw error
                } catch {
                    throw ResourceSealError.resourceUnavailable(path)
                }
                guard bytes.count <= configuration.limits.maximumResourceByteCount else {
                    throw ResourceSealError.resourceTooLarge(path)
                }
                let (updatedTotal, overflow) = totalSealedBytes.addingReportingOverflow(bytes.count)
                guard !overflow else { throw ResourceSealError.integerOverflow }
                guard updatedTotal <= configuration.limits.maximumTotalSealedByteCount else {
                    throw ResourceSealError.totalSealedBytesExceeded
                }
                totalSealedBytes = updatedTotal

                let digest: Digest
                do {
                    digest = try messageDigest.digest(bytes, algorithm: .sha256)
                } catch {
                    throw ResourceSealError.digestFailure
                }
                guard digest.algorithm == .sha256, digest.bytes.count == DigestAlgorithm.sha256.digestLength else {
                    throw ResourceSealError.digestFailure
                }
                guard seenPaths.insert(path).inserted else {
                    throw ResourceSealError.duplicateResourcePath(path)
                }
                fileSeals.append(FileResourceSeal(path: path, hash2: digest.bytes))
            }
        }

        // Nested code seals are caller-supplied final state. Paths must not
        // collide with sealed files or each other.
        var entries: [CodeResourcesFileEntry] = fileSeals.map { .file($0) }
        for seal in nestedCode.sorted(by: { left, right in
            CanonicalPropertyListXMLSerializer.utf8Ascending(left.path.rawValue, right.path.rawValue)
        }) {
            guard seal.path != .root else { throw ResourceSealError.unsealablePath(seal.path) }
            guard seenPaths.insert(seal.path).inserted else {
                throw ResourceSealError.duplicateResourcePath(seal.path)
            }
            entries.append(.nestedCode(seal))
        }

        return try CodeResourcesDocument(
            files2: entries,
            rules2: nil,
            omitted: omitted
        )
    }
}
