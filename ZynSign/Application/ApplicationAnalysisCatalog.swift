import Foundation

/// Keeps the `ApplicationAnalysis` of every library entry, so the detail
/// screen can show signing state, frameworks, and extensions the moment it
/// opens.
///
/// The Import Hub records each package's analysis here as it is admitted —
/// the library is populated before the user ever opens the details. Entries
/// imported before the hub existed are analyzed on first request, from the
/// package the library holds, and remembered.
///
/// The cache mirrors `AppIconExtraction`: an in-memory map backed by one
/// small file per artifact in the caches directory. Losing the cache loses
/// nothing — every analysis is recomputable from its package, and reading a
/// package here never changes it.
actor ApplicationAnalysisCatalog {

    private let readerProvider: any ArtifactArchiveReaderProvider
    private let structuralInspection: IPAArchiveInspection
    private let metadataInspection: IPABundleMetadataInspection
    private let cacheDirectory: URL
    private var memoryCache: [ArtifactIdentifier: ApplicationAnalysis] = [:]

    /// Creates the catalog over the archive boundary that reads library
    /// packages, caching into `cacheDirectory`.
    init(
        readerProvider: any ArtifactArchiveReaderProvider,
        cacheDirectory: URL,
        limits: ArchiveLimits = .default
    ) {
        self.readerProvider = readerProvider
        self.structuralInspection = IPAArchiveInspection(readerProvider: readerProvider, limits: limits)
        self.metadataInspection = IPABundleMetadataInspection(readerProvider: readerProvider, limits: limits)
        self.cacheDirectory = cacheDirectory
    }

    /// The analysis of the package stored as `artifact`, or `nil` when the
    /// package cannot be read.
    func analysis(for artifact: ArtifactIdentifier) -> ApplicationAnalysis? {
        if let cached = memoryCache[artifact] {
            return cached
        }
        if let data = try? Data(contentsOf: cacheURL(for: artifact)),
           let decoded = try? JSONDecoder().decode(ApplicationAnalysis.self, from: data) {
            memoryCache[artifact] = decoded
            return decoded
        }
        guard let computed = computeAnalysis(for: artifact) else {
            return nil
        }
        remember(computed, for: artifact)
        return computed
    }

    /// Records an analysis already computed — by the Import Hub, at
    /// analysis time — for the package stored as `artifact`.
    func remember(_ analysis: ApplicationAnalysis, for artifact: ArtifactIdentifier) {
        memoryCache[artifact] = analysis
        guard let data = try? JSONEncoder().encode(analysis) else { return }
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: cacheURL(for: artifact), options: .atomic)
        } catch {
            // A cache that cannot be written only means the analysis is
            // computed again next time.
        }
    }

    private func computeAnalysis(for artifact: ArtifactIdentifier) -> ApplicationAnalysis? {
        let examined = metadataInspection.inspect(structuralInspection.inspect(IPAArtifact(id: artifact)))
        guard examined.permitsLaterStages else { return nil }

        let reader: any ArchiveReader
        do {
            reader = try readerProvider.archiveReader(for: artifact)
        } catch {
            return nil
        }
        defer { reader.close() }
        guard let entries = try? reader.readEntryTable() else { return nil }

        return ApplicationAnalysis.derive(
            from: entries,
            bundleRoot: examined.discoveredBundle?.bundlePath,
            metadata: examined.metadata
        )
    }

    private func cacheURL(for artifact: ArtifactIdentifier) -> URL {
        cacheDirectory
            .appendingPathComponent(artifact.rawValue, isDirectory: false)
            .appendingPathExtension("analysis")
    }
}
