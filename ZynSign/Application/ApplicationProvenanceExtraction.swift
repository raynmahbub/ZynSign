import Foundation

/// Reads who a package says it comes from — its development team and
/// developer — from the package the library holds for it.
///
/// Two optional files carry those declarations. The application bundle's
/// `embedded.mobileprovision` is the provisioning profile the package was
/// last signed with; its property list names the development team
/// (`TeamIdentifier`, `TeamName`). The archive-root `iTunesMetadata.plist`
/// that store packages carry names the developer (`artistName`). The use
/// case reads at most those two entries, each within a small bound, through
/// the same read-only archive boundary inspection uses; nothing is
/// extracted to disk and nothing inside the package is executed or trusted.
///
/// **Declarations, not findings.** The embedded profile's signature is not
/// verified here, and neither file proves anything: they are what the
/// package declares, exactly like its `Info.plist`, and they are sanitised
/// and presented as such (`ApplicationProvenance`). A package that carries
/// neither file resolves to `ApplicationProvenance.unknown`.
///
/// **Lazy and cached.** Resolution costs an entry-table scan and up to two
/// small reads per package, so the library screen asks for it in the
/// background, a few packages at a time, after the list is already on
/// screen. Results are kept for the launch and in one small document in the
/// caches directory across launches, keyed by artifact identifier. Artifact
/// bytes never change under an identifier, so a cached result always
/// describes exactly the package it was read from; a package whose archive
/// could not be opened is not cached and is tried again next time.
actor ApplicationProvenanceExtraction {

    /// The file inside the application bundle that holds the embedded
    /// provisioning profile.
    static let embeddedProfileFileName = "embedded.mobileprovision"

    /// The archive-root file store packages carry their metadata in.
    static let storeMetadataPath = "iTunesMetadata.plist"

    /// The version of the cache document this build reads and writes. A
    /// cache of any other version is ignored and rebuilt.
    private static let cacheSchemaVersion = 1

    private struct CacheDocument: Codable {
        var schemaVersion: Int
        var entries: [String: ApplicationProvenance]
    }

    private let readerProvider: any ArtifactArchiveReaderProvider
    private let cacheLocation: URL?
    private let profilePayload: @Sendable (Data) -> Data?
    private let maximumProfileBytes: Int
    private let maximumMetadataBytes: Int

    /// Everything resolved so far, once the cache has been read.
    private var resolved: [ArtifactIdentifier: ApplicationProvenance]?

    /// Creates the use case over the reader provider the composition root
    /// selected.
    ///
    /// - Parameters:
    ///   - cacheLocation: Where the cache document lives; `nil` keeps
    ///     results for the launch only.
    ///   - profilePayload: Extracts the property list a profile's signed
    ///     container encapsulates. When it returns `nil` the use case looks
    ///     for the property list's own markers in the bytes instead.
    init(
        readerProvider: any ArtifactArchiveReaderProvider,
        cacheLocation: URL?,
        profilePayload: @escaping @Sendable (Data) -> Data? = { _ in nil },
        maximumProfileBytes: Int = 1_048_576,
        maximumMetadataBytes: Int = 1_048_576
    ) {
        self.readerProvider = readerProvider
        self.cacheLocation = cacheLocation
        self.profilePayload = profilePayload
        self.maximumProfileBytes = maximumProfileBytes
        self.maximumMetadataBytes = maximumMetadataBytes
    }

    // MARK: - Resolving

    /// Everything resolved so far, including results cached by earlier
    /// launches. Reads nothing from any package.
    func knownProvenance() -> [ArtifactIdentifier: ApplicationProvenance] {
        loadedCache()
    }

    /// Resolves provenance for `artifacts`, reading packages only for the
    /// ones not already known, and returns the result for each artifact
    /// that could be resolved. Stops early, returning what it has, when the
    /// calling task is cancelled.
    func resolve(_ artifacts: [ArtifactIdentifier]) -> [ArtifactIdentifier: ApplicationProvenance] {
        var cache = loadedCache()
        var results: [ArtifactIdentifier: ApplicationProvenance] = [:]
        var didExtract = false
        for artifact in artifacts {
            if Task.isCancelled {
                break
            }
            if let known = cache[artifact] {
                results[artifact] = known
                continue
            }
            let provenance: ApplicationProvenance
            do {
                let reader = try readerProvider.archiveReader(for: artifact)
                defer { reader.close() }
                provenance = Self.extract(
                    using: reader,
                    maximumProfileBytes: maximumProfileBytes,
                    maximumMetadataBytes: maximumMetadataBytes,
                    profilePayload: profilePayload
                )
            } catch {
                // An archive that cannot be opened is not cached, so a
                // package that comes back is read again next time.
                continue
            }
            cache[artifact] = provenance
            results[artifact] = provenance
            didExtract = true
        }
        resolved = cache
        if didExtract {
            persist(cache)
        }
        return results
    }

    /// Forgets the results for `artifacts`, after the library removed the
    /// packages they describe.
    func forget(_ artifacts: Set<ArtifactIdentifier>) {
        var cache = loadedCache()
        let before = cache.count
        for artifact in artifacts {
            cache.removeValue(forKey: artifact)
        }
        resolved = cache
        if cache.count != before {
            persist(cache)
        }
    }

    // MARK: - Extraction

    /// Reads the declarations from one package. Internal (not private) so
    /// the rules are testable without a filesystem.
    static func extract(
        using reader: any ArchiveReader,
        maximumProfileBytes: Int,
        maximumMetadataBytes: Int,
        profilePayload: (Data) -> Data?
    ) -> ApplicationProvenance {
        guard let entries = try? reader.readEntryTable() else {
            return .unknown
        }
        let regularFiles = Set(entries.compactMap { entry -> ArchivePath? in
            entry.kind == .regularFile ? entry.path : nil
        })

        var teamIdentifier: String?
        var teamName: String?
        if let bundleRoot = AppIconExtraction.applicationBundleRoot(in: entries),
           let profilePath = bundleRoot.appending(component: Self.embeddedProfileFileName),
           regularFiles.contains(profilePath),
           let profile = try? reader.readEntryData(at: profilePath, maximumBytes: maximumProfileBytes) {
            let declared = Self.teamDeclarations(inProfile: profile, profilePayload: profilePayload)
            teamIdentifier = declared.identifier
            teamName = declared.name
        }

        var developer: String?
        if let metadataPath = ArchivePath(rawValue: Self.storeMetadataPath),
           regularFiles.contains(metadataPath),
           let metadata = try? reader.readEntryData(at: metadataPath, maximumBytes: maximumMetadataBytes) {
            developer = Self.developerName(inStoreMetadata: metadata)
        }

        return ApplicationProvenance(
            developerName: developer,
            teamIdentifier: teamIdentifier,
            teamName: teamName
        )
    }

    /// The team a provisioning profile declares: the first `TeamIdentifier`
    /// (or the entitlements' team identifier) and `TeamName`.
    static func teamDeclarations(
        inProfile data: Data,
        profilePayload: (Data) -> Data?
    ) -> (identifier: String?, name: String?) {
        let payload = profilePayload(data) ?? Self.embeddedPropertyList(in: data) ?? data
        guard let dictionary = Self.propertyListDictionary(payload) else {
            return (nil, nil)
        }
        let identifiers = dictionary["TeamIdentifier"] as? [String]
        let entitlements = dictionary["Entitlements"] as? [String: Any]
        let entitlementTeam = entitlements?["com.apple.developer.team-identifier"] as? String
        let name = dictionary["TeamName"] as? String
        return (identifiers?.first ?? entitlementTeam, name)
    }

    /// The developer store metadata declares.
    static func developerName(inStoreMetadata data: Data) -> String? {
        guard let dictionary = Self.propertyListDictionary(data) else { return nil }
        return (dictionary["artistName"] as? String) ?? (dictionary["playlistArtistName"] as? String)
    }

    /// The XML property list a signed profile container carries, located by
    /// its own markers. Used when no container decoder is available.
    static func embeddedPropertyList(in data: Data) -> Data? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), options: [], in: start.lowerBound..<data.endIndex)
        else {
            return nil
        }
        return data.subdata(in: start.lowerBound..<end.upperBound)
    }

    private static func propertyListDictionary(_ data: Data) -> [String: Any]? {
        guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }
        return value as? [String: Any]
    }

    // MARK: - Cache

    private func loadedCache() -> [ArtifactIdentifier: ApplicationProvenance] {
        if let resolved {
            return resolved
        }
        var loaded: [ArtifactIdentifier: ApplicationProvenance] = [:]
        if let cacheLocation,
           let data = try? Data(contentsOf: cacheLocation),
           let document = try? JSONDecoder().decode(CacheDocument.self, from: data),
           document.schemaVersion == Self.cacheSchemaVersion {
            for (key, value) in document.entries {
                guard let artifact = ArtifactIdentifier(rawValue: key) else { continue }
                // Values are sanitised again on the way in: the cache is a
                // file, and a file is input.
                loaded[artifact] = ApplicationProvenance(
                    developerName: value.developerName,
                    teamIdentifier: value.teamIdentifier,
                    teamName: value.teamName
                )
            }
        }
        resolved = loaded
        return loaded
    }

    private func persist(_ cache: [ArtifactIdentifier: ApplicationProvenance]) {
        guard let cacheLocation else { return }
        var entries: [String: ApplicationProvenance] = [:]
        for (artifact, provenance) in cache {
            entries[artifact.rawValue] = provenance
        }
        let document = CacheDocument(schemaVersion: Self.cacheSchemaVersion, entries: entries)
        do {
            let data = try JSONEncoder().encode(document)
            try FileManager.default.createDirectory(
                at: cacheLocation.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: cacheLocation, options: .atomic)
        } catch {
            // A cache write failure costs only the next launch a re-read.
        }
    }
}
