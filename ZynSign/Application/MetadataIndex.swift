import Foundation

/// The searchable facts about one library application, separated from the
/// package they were read from.
///
/// Everything the library screen, the Home dashboard, the queue's rows,
/// and search need to *show* an application is here: name, version,
/// bundle identifier, developer and team, import date, size, and signing
/// state. None of it requires opening the archive again — the archive is
/// reopened only when someone asks for something deeper (the bundle
/// explorer, App Details, the binary inspector). The record is a value
/// derived from persistence and never edited by hand; a build that finds
/// it disagrees with the catalog rebuilds it.
struct LibraryMetadata: Equatable, Hashable, Sendable, Codable, Identifiable {

    /// The signing state as the library shows it.
    enum SigningState: String, Codable, Hashable, Sendable {
        case signed
        case notSigned
        case packageProblem
    }

    let id: ApplicationRecordIdentifier
    let artifactID: ArtifactIdentifier
    let displayName: String?
    let bundleIdentifier: String
    let shortVersion: String?
    let buildVersion: String?
    let developerName: String?
    let teamIdentifier: String?
    let teamName: String?
    let importedAt: Date
    let byteCount: Int
    let isFavorite: Bool
    let signingState: SigningState
    let lastSignedAt: Date?

    init(
        id: ApplicationRecordIdentifier,
        artifactID: ArtifactIdentifier,
        displayName: String?,
        bundleIdentifier: String,
        shortVersion: String?,
        buildVersion: String?,
        developerName: String?,
        teamIdentifier: String?,
        teamName: String?,
        importedAt: Date,
        byteCount: Int,
        isFavorite: Bool,
        signingState: SigningState,
        lastSignedAt: Date?
    ) {
        self.id = id
        self.artifactID = artifactID
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.developerName = developerName
        self.teamIdentifier = teamIdentifier
        self.teamName = teamName
        self.importedAt = importedAt
        self.byteCount = max(0, byteCount)
        self.isFavorite = isFavorite
        self.signingState = signingState
        self.lastSignedAt = lastSignedAt
    }

    /// Derives the metadata of `entry` from what the library, the signing
    /// journal, and the provenance cache know right now.
    init(entry: LibraryEntry, provenance: ApplicationProvenance?, signingFact: LibrarySigningFact?) {
        let record = entry.record
        let state: SigningState
        if !entry.isArtifactAvailable {
            state = .packageProblem
        } else if signingFact != nil {
            state = .signed
        } else {
            state = .notSigned
        }
        self.init(
            id: record.id,
            artifactID: record.artifact.artifactID,
            displayName: record.displayName,
            bundleIdentifier: record.bundleIdentifier.rawValue,
            shortVersion: record.identity.shortVersionString,
            buildVersion: record.identity.buildVersion,
            developerName: provenance?.developerName,
            teamIdentifier: provenance?.teamIdentifier,
            teamName: provenance?.teamName,
            importedAt: record.importedAt,
            byteCount: record.artifact.byteCount,
            isFavorite: record.isFavorite,
            signingState: state,
            lastSignedAt: signingFact?.lastSignedAt
        )
    }

    /// The name shown when the package declared none.
    var resolvedDisplayName: String {
        displayName ?? "Unnamed Application"
    }

    /// "Version 1.2 (34)", "Version 1.2", "Build 34", or `nil`.
    var versionText: String? {
        switch (shortVersion, buildVersion) {
        case (.some(let version), .some(let build)): return "Version \(version) (\(build))"
        case (.some(let version), .none): return "Version \(version)"
        case (.none, .some(let build)): return "Build \(build)"
        case (.none, .none): return nil
        }
    }

    // Identifiers are stored as their string form so the document is
    // readable and the domain identifiers need no Codable of their own.
    private enum CodingKeys: String, CodingKey {
        case id, artifactID, displayName, bundleIdentifier, shortVersion, buildVersion
        case developerName, teamIdentifier, teamName, importedAt, byteCount, isFavorite
        case signingState, lastSignedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try container.decode(String.self, forKey: .id)
        let rawArtifact = try container.decode(String.self, forKey: .artifactID)
        guard let id = ApplicationRecordIdentifier(rawValue: rawID) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Not a record identifier.")
        }
        guard let artifactID = ArtifactIdentifier(rawValue: rawArtifact) else {
            throw DecodingError.dataCorruptedError(forKey: .artifactID, in: container, debugDescription: "Not an artifact identifier.")
        }
        self.init(
            id: id,
            artifactID: artifactID,
            displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
            bundleIdentifier: try container.decode(String.self, forKey: .bundleIdentifier),
            shortVersion: try container.decodeIfPresent(String.self, forKey: .shortVersion),
            buildVersion: try container.decodeIfPresent(String.self, forKey: .buildVersion),
            developerName: try container.decodeIfPresent(String.self, forKey: .developerName),
            teamIdentifier: try container.decodeIfPresent(String.self, forKey: .teamIdentifier),
            teamName: try container.decodeIfPresent(String.self, forKey: .teamName),
            importedAt: try container.decode(Date.self, forKey: .importedAt),
            byteCount: try container.decode(Int.self, forKey: .byteCount),
            isFavorite: try container.decode(Bool.self, forKey: .isFavorite),
            signingState: try container.decode(SigningState.self, forKey: .signingState),
            lastSignedAt: try container.decodeIfPresent(Date.self, forKey: .lastSignedAt)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.rawValue, forKey: .id)
        try container.encode(artifactID.rawValue, forKey: .artifactID)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encodeIfPresent(shortVersion, forKey: .shortVersion)
        try container.encodeIfPresent(buildVersion, forKey: .buildVersion)
        try container.encodeIfPresent(developerName, forKey: .developerName)
        try container.encodeIfPresent(teamIdentifier, forKey: .teamIdentifier)
        try container.encodeIfPresent(teamName, forKey: .teamName)
        try container.encode(importedAt, forKey: .importedAt)
        try container.encode(byteCount, forKey: .byteCount)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(signingState, forKey: .signingState)
        try container.encodeIfPresent(lastSignedAt, forKey: .lastSignedAt)
    }
}

/// The metadata index: every application's `LibraryMetadata`, as a value.
struct MetadataIndex: Equatable, Sendable, Codable {

    /// The document version this build writes. Any other version on disk
    /// is ignored and rebuilt.
    static let schemaVersion = 1

    private(set) var schema: Int = MetadataIndex.schemaVersion
    private(set) var entries: [LibraryMetadata] = []

    /// When the index was last brought in line with persistence.
    private(set) var builtAt: Date?

    init() {}

    init(entries: [LibraryMetadata], builtAt: Date?) {
        self.entries = entries.sorted { $0.importedAt > $1.importedAt }
        self.builtAt = builtAt
    }

    var count: Int { entries.count }

    var isEmpty: Bool { entries.isEmpty }

    func metadata(for id: ApplicationRecordIdentifier) -> LibraryMetadata? {
        entries.first { $0.id == id }
    }

    /// The entries whose bundle identifier is `bundleIdentifier`.
    func entries(withBundleIdentifier bundleIdentifier: String) -> [LibraryMetadata] {
        entries.filter { $0.bundleIdentifier == bundleIdentifier }
    }

    /// Replaces or inserts each of `updated`; returns how many changed.
    @discardableResult
    mutating func upsert(_ updated: [LibraryMetadata], at date: Date) -> Int {
        var byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var changed = 0
        for metadata in updated where byID[metadata.id] != metadata {
            byID[metadata.id] = metadata
            changed += 1
        }
        if changed > 0 {
            entries = byID.values.sorted { $0.importedAt > $1.importedAt }
            builtAt = date
        }
        return changed
    }

    /// Removes the entries for `ids`; returns how many were removed.
    @discardableResult
    mutating func remove(_ ids: Set<ApplicationRecordIdentifier>, at date: Date) -> Int {
        let before = entries.count
        entries.removeAll { ids.contains($0.id) }
        let removed = before - entries.count
        if removed > 0 { builtAt = date }
        return removed
    }
}

/// Where the metadata index is kept between launches.
protocol MetadataIndexStore: Sendable {
    func loadMetadataIndex() throws -> MetadataIndex?
    func saveMetadataIndex(_ index: MetadataIndex) throws
    func removeMetadataIndex() throws
}

/// Keeps the metadata index in step with the library, incrementally, and
/// persists it in the background.
///
/// The library model hands the service the entries it read, together with
/// the provenance and signing facts it knows; the service derives the
/// metadata for each, changes only what differs, and writes the document
/// through the scheduler so the main actor never waits on a file. A
/// document whose schema this build does not recognise is discarded; the
/// next full read rebuilds it.
actor MetadataIndexService {

    private let store: (any MetadataIndexStore)?
    private let scheduler: BackgroundWorkScheduler
    private let now: @Sendable () -> Date

    private var index = MetadataIndex()
    private var hasLoaded = false
    private var isDirty = false

    /// How many incremental updates changed something, for diagnostics.
    private(set) var updateCount = 0

    init(store: (any MetadataIndexStore)?, scheduler: BackgroundWorkScheduler, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.scheduler = scheduler
        self.now = now
    }

    // MARK: - Reading

    /// The index as currently held, loading the persisted document first
    /// if it has not been loaded this launch.
    func current() -> MetadataIndex {
        loadIfNeeded()
        return index
    }

    /// The metadata for `id`, when the index holds it.
    func metadata(for id: ApplicationRecordIdentifier) -> LibraryMetadata? {
        loadIfNeeded()
        return index.metadata(for: id)
    }

    // MARK: - Updating

    /// Brings the index in line with `entries`: entries the library no
    /// longer holds are dropped, and every entry's metadata is re-derived
    /// and replaced only when it differs. Returns how many entries changed.
    @discardableResult
    func reconcile(
        entries: [LibraryEntry],
        provenance: [ArtifactIdentifier: ApplicationProvenance],
        signingFacts: LibrarySigningFacts
    ) -> Int {
        loadIfNeeded()
        let date = now()
        let metadata = entries.map { entry in
            LibraryMetadata(
                entry: entry,
                provenance: provenance[entry.record.artifact.artifactID],
                signingFact: signingFacts.fact(for: entry.record)
            )
        }
        let held = Set(entries.map { $0.record.id })
        let gone = Set(index.entries.map(\.id)).subtracting(held)
        var changed = index.remove(gone, at: date)
        changed += index.upsert(metadata, at: date)
        if changed > 0 {
            updateCount += 1
            isDirty = true
            persistInBackground()
        }
        return changed
    }

    /// Drops the entries for `ids`.
    func forget(_ ids: Set<ApplicationRecordIdentifier>) {
        loadIfNeeded()
        if index.remove(ids, at: now()) > 0 {
            isDirty = true
            persistInBackground()
        }
    }

    /// Discards the index in memory and on disk. The next reconcile
    /// rebuilds it.
    func reset() {
        index = MetadataIndex()
        hasLoaded = true
        isDirty = false
        try? store?.removeMetadataIndex()
    }

    /// Writes the index now, if it changed. Tests and `optimize()` use
    /// this; ordinary updates persist in the background.
    func flush() {
        guard isDirty, let store else { return }
        do {
            try store.saveMetadataIndex(index)
            isDirty = false
        } catch {
            // A failed write costs the next launch a rebuild, nothing more.
        }
    }

    // MARK: - Private

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let store else { return }
        if let loaded = try? store.loadMetadataIndex(), loaded.schema == MetadataIndex.schemaVersion {
            index = loaded
        } else {
            index = MetadataIndex()
        }
    }

    private func persistInBackground() {
        Task {
            await scheduler.schedule(key: "metadata-index.persist", priority: .maintenance) { [weak self] in
                await self?.flush()
            }
        }
    }
}
