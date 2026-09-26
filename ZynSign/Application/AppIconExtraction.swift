import Foundation

/// Extracts an application's icon image from the package the library holds
/// for it.
///
/// Library cards show the application's icon when the package carries one
/// a reader can reach. The icon lives inside the imported archive — usually
/// as a `PNG` at the application bundle's root — so extraction means opening
/// the artifact read-only through the existing archive boundary, choosing a
/// candidate entry, and reading it within a small bound. Nothing is
/// extracted to a working directory; the bytes go straight into the icon
/// cache for presentation to decode.
///
/// **Candidates.** The use case looks only at regular files that sit
/// directly inside the application bundle (`Payload/<Name>.app/`), never
/// deeper, and reads the first candidate in a fixed preference order that
/// prefers the home-screen sizes over auxiliary ones. When no preferred
/// name is present — some packages ship icon files under other names — any
/// bundle-root `PNG` whose name mentions an icon is accepted, in container
/// order, so the outcome stays deterministic. A package that offers nothing
/// usable produces no icon; presentation falls back to a derived mark and
/// the absence is never invented into an image.
///
/// **Bounds.** One entry, at most `maximumIconBytes` expanded bytes, read
/// through the archive reader's own resource policy. A hostile or oversized
/// entry fails the read and simply yields no icon.
///
/// **Caching.** Extraction costs an entry-table scan, so the result is kept
/// in memory for the launch and in the caches directory across launches,
/// keyed by artifact identifier. Artifacts are content-addressed per import,
/// so a cache entry always describes exactly the package it was extracted
/// from, and the caches directory is one the system may reclaim at will.
actor AppIconExtraction {

    /// The archive boundary the library's artifacts are read through.
    private let readerProvider: any ArtifactArchiveReaderProvider

    /// The directory icon bytes are cached in. Created on first write.
    private let cacheDirectory: URL

    /// The largest expanded icon read accepted, in bytes.
    private let maximumIconBytes: Int

    /// Icons extracted or read this launch, keyed by artifact.
    private var memoryCache: [ArtifactIdentifier: Data] = [:]

    /// Creates the extractor over the reader provider the composition root
    /// selected, caching bytes in `cacheDirectory`.
    init(
        readerProvider: any ArtifactArchiveReaderProvider,
        cacheDirectory: URL,
        maximumIconBytes: Int = 512 * 1024
    ) {
        self.readerProvider = readerProvider
        self.cacheDirectory = cacheDirectory
        self.maximumIconBytes = maximumIconBytes
    }

    /// The icon image data for the package the library holds for `artifact`,
    /// or `nil` when the package carries no icon ZynSign can read within its
    /// bounds. An artifact that is missing or unreadable also produces `nil`
    /// — cards fall back to a derived mark rather than an error.
    func iconData(for artifact: ArtifactIdentifier) async -> Data? {
        if let cached = memoryCache[artifact] {
            return cached
        }

        let cacheURL = Self.cacheURL(for: artifact, in: cacheDirectory)
        if let data = try? Data(contentsOf: cacheURL), !data.isEmpty {
            memoryCache[artifact] = data
            return data
        }

        let reader: any ArchiveReader
        do {
            reader = try readerProvider.archiveReader(for: artifact)
        } catch {
            return nil
        }
        defer { reader.close() }

        guard let data = Self.extractIcon(using: reader, maximumBytes: maximumIconBytes) else {
            return nil
        }

        memoryCache[artifact] = data
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            // A cache write failure costs only the next launch a re-extract.
        }
        return data
    }

    /// Records icon data that was already extracted — by the Import Hub,
    /// while it analyzed the package — for the package stored as
    /// `artifact`, so the library shows the icon without reading the
    /// package again. Data beyond the size bound is ignored.
    func remember(_ data: Data, for artifact: ArtifactIdentifier) {
        guard !data.isEmpty, data.count <= maximumIconBytes else { return }
        memoryCache[artifact] = data
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: Self.cacheURL(for: artifact, in: cacheDirectory), options: .atomic)
        } catch {
            // Best effort: without the disk copy the icon is extracted
            // again the next time it is needed.
        }
    }

    // MARK: - Extraction

    /// Chooses and reads one icon entry from `reader`. Internal (not
    /// private) so the selection rules are testable without a filesystem.
    static func extractIcon(using reader: any ArchiveReader, maximumBytes: Int) -> Data? {
        guard let entries = try? reader.readEntryTable() else {
            return nil
        }
        guard let bundleRoot = applicationBundleRoot(in: entries) else {
            return nil
        }
        let rootFiles = bundleRootFiles(in: entries, under: bundleRoot)

        for name in preferredIconNames {
            if let candidate = rootFiles.first(where: { $0.fileName == name }) {
                if let data = read(candidate, from: reader, maximumBytes: maximumBytes) {
                    return data
                }
            }
        }

        let fallbacks = rootFiles
            .filter { candidate in
                let lowered = candidate.fileName.lowercased()
                return lowered.contains("appicon") && lowered.hasSuffix(".png")
            }
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        for candidate in fallbacks {
            if let data = read(candidate, from: reader, maximumBytes: maximumBytes) {
                return data
            }
        }
        return nil
    }

    /// Reads one candidate within the bound, treating any refusal as "no
    /// icon" rather than an error the caller must handle.
    private static func read(
        _ candidate: BundleRootFile,
        from reader: any ArchiveReader,
        maximumBytes: Int
    ) -> Data? {
        guard candidate.uncompressedSize > 0, candidate.uncompressedSize <= maximumBytes else {
            return nil
        }
        guard let data = try? reader.readEntryData(at: candidate.path, maximumBytes: maximumBytes) else {
            return nil
        }
        return data.isEmpty ? nil : data
    }

    /// One readable regular file sitting directly inside the application
    /// bundle.
    struct BundleRootFile {
        let path: ArchivePath
        let fileName: String
        let uncompressedSize: Int
    }

    /// The application bundle's root path (`Payload/<Name>.app`), derived
    /// from a recorded directory entry when the container records one, and
    /// from the `Info.plist` entry otherwise — some containers record no
    /// directory entries at all. The layout rules are the domain's own, so
    /// discovery agrees with what inspection accepted.
    static func applicationBundleRoot(in entries: [ArchiveEntry]) -> ArchivePath? {
        let usable = entries.compactMap { $0.path }
        if let directory = usable.first(where: { isApplicationBundleRoot($0) }) {
            return directory
        }
        let infoPlist = usable.first { path in
            guard IPALayout.isDirectChildOfPayload(path) else { return false }
            let components = path.components
            guard components.count == 3 else { return false }
            return IPALayout.namesApplicationBundle(components[1])
                && components[2] == IPALayout.bundleInformationFileName
        }
        return infoPlist?.parent
    }

    /// Whether `path` is a recorded application bundle root directory.
    static func isApplicationBundleRoot(_ path: ArchivePath) -> Bool {
        guard IPALayout.isDirectChildOfPayload(path) else { return false }
        return IPALayout.namesApplicationBundle(path.lastComponent)
    }

    /// The regular files recorded directly under `bundleRoot`, in container
    /// order. Entries deeper than the bundle root are ignored — icons live
    /// at the root, and descending further would read asset content this
    /// use case has no reason to touch.
    private static func bundleRootFiles(in entries: [ArchiveEntry], under bundleRoot: ArchivePath) -> [BundleRootFile] {
        let prefix = bundleRoot.rawValue + "/"
        return entries.compactMap { entry in
            guard entry.kind == .regularFile, let path = entry.path else { return nil }
            guard path.rawValue.hasPrefix(prefix) else { return nil }
            let remainder = path.rawValue.dropFirst(prefix.count)
            guard !remainder.contains("/") else { return nil }
            return BundleRootFile(
                path: path,
                fileName: String(remainder),
                uncompressedSize: entry.uncompressedSize
            )
        }
    }

    /// The icon file names extraction prefers, home-screen sizes first.
    /// The list is fixed so the outcome for a given package never depends
    /// on container order.
    static let preferredIconNames: [String] = [
        "AppIcon60x60@2x.png",          // iPhone home screen (120 px)
        "AppIcon76x76@2x~ipad.png",     // iPad home screen (152 px)
        "AppIcon83.5x83.5@2x~ipad.png", // iPad Pro home screen (167 px)
        "AppIcon60x60@3x.png",          // iPhone home screen (180 px)
        "Icon-60@2x.png",               // legacy home screen (120 px)
        "Icon-Small-80@2x.png",         // legacy Settings-scale icon
        "AppIcon29x29@2x.png",          // small icon — last preferred resort
        "Icon.png",                     // pre-iOS 7 icon
    ]

    private static func cacheURL(for artifact: ArtifactIdentifier, in directory: URL) -> URL {
        directory
            .appendingPathComponent(artifact.rawValue, isDirectory: false)
            .appendingPathExtension("icon")
    }
}
