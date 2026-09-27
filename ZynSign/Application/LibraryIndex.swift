import Foundation

/// The parts of a library entry that search looks at.
enum LibrarySearchField: String, CaseIterable, Hashable, Sendable {
    case name
    case bundleIdentifier
    case version
    case sourceFileName
    case developer
    case teamIdentifier
    case collection

    /// The user-presentable name of the field, for "matched in" hints.
    var displayName: String {
        switch self {
        case .name: return "Name"
        case .bundleIdentifier: return "Bundle ID"
        case .version: return "Version"
        case .sourceFileName: return "File Name"
        case .developer: return "Developer"
        case .teamIdentifier: return "Team ID"
        case .collection: return "Collection"
        }
    }
}

/// Library-wide counts. Every value is derived from the index, which is
/// derived from persistence, so a statistic can never disagree with the
/// list it summarises.
struct LibraryStatistics: Hashable, Sendable {

    /// Every entry the library holds.
    var totalApplications: Int

    /// Entries marked as favourites.
    var favorites: Int

    /// Entries the signing journal records a successful signing for.
    var signed: Int

    /// Entries with no successful signing on record. Always
    /// `totalApplications - signed`.
    var unsigned: Int

    /// Collections the user made.
    var collections: Int

    /// The bytes the library's package files occupy: each available file at
    /// its recorded size, each inconsistent file at its observed size, and
    /// nothing for a missing file.
    var storageBytes: Int64

    static let zero = LibraryStatistics(
        totalApplications: 0,
        favorites: 0,
        signed: 0,
        unsigned: 0,
        collections: 0,
        storageBytes: 0
    )
}

/// A development team the library's packages declare, and how many
/// entries declare it.
struct LibraryTeam: Hashable, Sendable, Identifiable {
    let identifier: String
    let name: String?
    let applicationCount: Int

    var id: String { identifier }

    /// "Team Name (TEAMID)" when a name was declared, else the identifier.
    var displayName: String {
        if let name { return "\(name) (\(identifier))" }
        return identifier
    }
}

/// The library's in-memory index: every entry together with the facts the
/// library screen searches, filters, sorts, and counts by.
///
/// **Why an index.** A library of hundreds of applications must answer
/// every keystroke of a search, every filter toggle, and every change of
/// order without re-reading persistence or re-deriving the same text. The
/// index derives, once per change, what those questions need: the folded
/// search text of each entry, which collections each entry is in and which
/// entries each collection holds, which entry is the latest declared
/// version of its application, and the signing fact of each entry. A query
/// is then a pass over precomputed values.
///
/// **Incremental.** A change to one entry — a favourite toggled, a record
/// re-read — updates that entry's derived values only. A change to the
/// organization rebuilds collection membership and nothing else unless
/// names or members changed. Provenance arriving for a few packages
/// refreshes those entries' search text. Only a full reload rebuilds
/// everything.
///
/// **Faithful.** The index holds nothing persistence does not. Collection
/// memberships that name records the library no longer holds are ignored;
/// signing facts come only from the journal; provenance comes only from
/// the packages. The index is a value, so the screen can hold one, replace
/// it, and compare it without any shared mutable state.
struct LibraryIndex: Sendable {

    /// The search index over every entry's folded text, by field. Trigram
    /// postings narrow each term to a handful of candidates before the
    /// substring check, so a keystroke over a thousand entries costs a few
    /// set intersections rather than a thousand string scans.
    typealias LibrarySearchIndex = SearchIndex<ApplicationRecordIdentifier, LibrarySearchField>

    /// One entry's searchable text.
    private typealias SearchDocument = LibrarySearchIndex.Document

    /// Every entry, by record identifier.
    private(set) var entriesByID: [ApplicationRecordIdentifier: LibraryEntry] = [:]

    /// The organization the index was last given.
    private(set) var organization: LibraryOrganization = .empty

    /// The signing facts the index was last given.
    private(set) var signingFacts: LibrarySigningFacts = .empty

    /// Declared provenance by artifact, for the packages resolved so far.
    private(set) var provenanceByArtifact: [ArtifactIdentifier: ApplicationProvenance] = [:]

    /// The search index. Exposed read-only so an owner can report its size
    /// and generation without copying the entries.
    private(set) var searchIndex = LibrarySearchIndex()
    private var signing: [ApplicationRecordIdentifier: LibrarySigningFact] = [:]
    private var membersByCollection: [LibraryCollectionIdentifier: Set<ApplicationRecordIdentifier>] = [:]
    private var collectionsByRecord: [ApplicationRecordIdentifier: [LibraryCollectionIdentifier]] = [:]
    private var latestVersions: Set<ApplicationRecordIdentifier> = []

    /// An empty index.
    init() {}

    /// Builds the index over `entries` and the facts that describe them.
    init(
        entries: [LibraryEntry],
        organization: LibraryOrganization = .empty,
        signingFacts: LibrarySigningFacts = .empty,
        provenance: [ArtifactIdentifier: ApplicationProvenance] = [:]
    ) {
        self.organization = organization
        self.signingFacts = signingFacts
        self.provenanceByArtifact = provenance
        replaceEntries(entries)
    }

    // MARK: - Reading entries

    /// How many entries the index holds.
    var count: Int { entriesByID.count }

    /// The entry for `id`, or `nil` when the index holds none.
    func entry(for id: ApplicationRecordIdentifier) -> LibraryEntry? {
        entriesByID[id]
    }

    /// How close the assets behind the entry's last signing are to expiry.
    func expiryStatus(for id: ApplicationRecordIdentifier, now: Date) -> LibraryExpiryStatus {
        LibraryExpiryStatus.evaluate(signing[id], now: now)
    }

    /// The declared provenance of the entry's package, or `nil` when it has
    /// not been resolved yet.
    func provenance(for id: ApplicationRecordIdentifier) -> ApplicationProvenance? {
        guard let entry = entriesByID[id] else { return nil }
        return provenanceByArtifact[entry.record.artifact.artifactID]
    }

    /// Whether provenance has been resolved for `artifact`.
    func hasResolvedProvenance(for artifact: ArtifactIdentifier) -> Bool {
        provenanceByArtifact[artifact] != nil
    }

    // MARK: - Reading collections

    /// The collections the user made, in creation order.
    var userCollections: [LibraryCollection] {
        organization.userCollections
    }

    /// The user collection with `id`, or `nil` when there is none.
    func collection(withID id: LibraryCollectionIdentifier) -> LibraryCollection? {
        guard let collection = organization.collection(withID: id), collection.isUserCollection else {
            return nil
        }
        return collection
    }

    /// The user collections containing the entry, in creation order.
    func collections(containing id: ApplicationRecordIdentifier) -> [LibraryCollection] {
        (collectionsByRecord[id] ?? []).compactMap { collection(withID: $0) }
    }

    /// How many entries the library holds in the collection. Memberships
    /// naming records the library no longer holds are not counted.
    func memberCount(of id: LibraryCollectionIdentifier) -> Int {
        membersByCollection[id]?.count ?? 0
    }

    /// Whether every entry in `ids` is in the collection.
    func collection(_ id: LibraryCollectionIdentifier, containsAll ids: [ApplicationRecordIdentifier]) -> Bool {
        guard !ids.isEmpty, let members = membersByCollection[id] else { return false }
        return ids.allSatisfy { members.contains($0) }
    }

    /// The development teams the library's packages declare, by name.
    func teams() -> [LibraryTeam] {
        var counts: [String: Int] = [:]
        var names: [String: String] = [:]
        for entry in entriesByID.values {
            guard let declared = provenanceByArtifact[entry.record.artifact.artifactID],
                  let team = declared.teamIdentifier else { continue }
            counts[team, default: 0] += 1
            if names[team] == nil, let name = declared.teamName {
                names[team] = name
            }
        }
        return counts
            .map { LibraryTeam(identifier: $0.key, name: names[$0.key], applicationCount: $0.value) }
            .sorted { lhs, rhs in
                let comparison = (lhs.name ?? lhs.identifier).localizedStandardCompare(rhs.name ?? rhs.identifier)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.identifier < rhs.identifier
            }
    }

    // MARK: - Querying

    /// The entries `query` selects within `scope`, in the query's order.
    ///
    /// The scope gives the starting set; filters narrow it (AND across
    /// facets, OR within one); every search term must then occur in at
    /// least one searchable field; the survivors are sorted. `now` anchors
    /// the recency and expiry windows.
    func results(
        for query: LibraryQuery,
        in scope: LibraryScope = .all,
        now: Date
    ) -> [ApplicationRecordIdentifier] {
        var candidates = members(of: scope, now: now)

        let facets = Dictionary(grouping: query.filters, by: { $0.facet })
        if !facets.isEmpty {
            candidates = candidates.filter { id in
                facets.values.allSatisfy { alternatives in
                    alternatives.contains { satisfies(id, $0, now: now) }
                }
            }
        }

        let terms = query.foldedSearchTerms
        if !terms.isEmpty {
            let matched = searchIndex.matches(allOf: terms, among: Set(candidates))
            candidates = candidates.filter { matched.contains($0) }
        }

        return sorted(candidates, by: query.sort)
    }

    /// How many entries `scope` holds before any filter or search.
    func entryCount(in scope: LibraryScope, now: Date) -> Int {
        members(of: scope, now: now).count
    }

    /// The fields of the entry that the folded search terms occur in, in
    /// field order. Used to explain a match that the visible row text does
    /// not show.
    func matchedFields(
        for id: ApplicationRecordIdentifier,
        foldedTerms: [String]
    ) -> [LibrarySearchField] {
        guard !foldedTerms.isEmpty, let document = searchIndex.document(for: id) else { return [] }
        return LibrarySearchField.allCases.filter { field in
            guard let text = document.fields[field], !text.isEmpty else { return false }
            return foldedTerms.contains { text.contains($0) }
        }
    }

    /// The library-wide statistics.
    func statistics() -> LibraryStatistics {
        var statistics = LibraryStatistics.zero
        statistics.totalApplications = entriesByID.count
        for (id, entry) in entriesByID {
            if entry.record.isFavorite {
                statistics.favorites += 1
            }
            if signing[id] != nil {
                statistics.signed += 1
            }
            statistics.storageBytes += Int64(Self.storedByteCount(of: entry))
        }
        statistics.unsigned = statistics.totalApplications - statistics.signed
        statistics.collections = organization.userCollections.count
        return statistics
    }

    // MARK: - Updating

    /// Replaces every entry and rebuilds everything derived from them.
    mutating func replaceEntries(_ entries: [LibraryEntry]) {
        var map: [ApplicationRecordIdentifier: LibraryEntry] = [:]
        map.reserveCapacity(entries.count)
        for entry in entries {
            map[entry.record.id] = entry
        }
        entriesByID = map
        rebuildMembership()
        rebuildSigning()
        rebuildLatestVersions()
        rebuildDocuments()
    }

    /// Replaces one entry (or adds it), updating only what depends on it.
    mutating func update(_ entry: LibraryEntry) {
        let id = entry.record.id
        let previous = entriesByID[id]
        entriesByID[id] = entry
        if previous == nil {
            // A record the index did not hold may be named by a collection.
            rebuildMembership()
        }
        let fact = signingFacts.fact(for: entry.record)
        signing[id] = fact
        if previous?.record.identity != entry.record.identity {
            rebuildLatestVersions()
        }
        searchIndex.upsert(id, document: makeDocument(for: entry))
    }

    /// Removes the entries in `ids`.
    mutating func remove(_ ids: Set<ApplicationRecordIdentifier>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            entriesByID.removeValue(forKey: id)
            signing.removeValue(forKey: id)
        }
        searchIndex.remove(ids)
        rebuildMembership()
        rebuildLatestVersions()
    }

    /// Adopts a new organization. Membership and collection search text are
    /// rebuilt only when collections changed; a usage-only change (an
    /// application opened) costs nothing more than storing the value.
    mutating func setOrganization(_ newOrganization: LibraryOrganization) {
        guard newOrganization != organization else { return }
        let collectionsChanged = newOrganization.collections != organization.collections
        organization = newOrganization
        guard collectionsChanged else { return }
        rebuildMembership()
        for id in Array(entriesByID.keys) {
            guard var document = searchIndex.document(for: id) else { continue }
            document.fields[.collection] = collectionText(for: id)
            searchIndex.upsert(id, document: document)
        }
    }

    /// Adopts new signing facts, re-deriving each entry's fact.
    mutating func setSigningFacts(_ facts: LibrarySigningFacts) {
        guard facts != signingFacts else { return }
        signingFacts = facts
        rebuildSigning()
    }

    /// Adds resolved provenance and refreshes the search text of the
    /// entries whose packages it describes.
    mutating func mergeProvenance(_ additions: [ArtifactIdentifier: ApplicationProvenance]) {
        guard !additions.isEmpty else { return }
        provenanceByArtifact.merge(additions) { _, new in new }
        let affected = entriesByID.values.filter { additions[$0.record.artifact.artifactID] != nil }
        for entry in affected {
            searchIndex.upsert(entry.record.id, document: makeDocument(for: entry))
        }
    }

    // MARK: - Ordering

    /// Most recently imported first; ties by the library's stable order.
    static func recentlyImportedOrder(_ lhs: ApplicationRecord, _ rhs: ApplicationRecord) -> Bool {
        if lhs.importedAt != rhs.importedAt {
            return lhs.importedAt > rhs.importedAt
        }
        return ApplicationRecord.libraryOrder(lhs, rhs)
    }

    /// By display name the way people read names — case-insensitive and
    /// numeric-aware — with unnamed entries sorting under their bundle
    /// identifier; ties by bundle identifier, then the stable order.
    static func nameOrder(_ lhs: ApplicationRecord, _ rhs: ApplicationRecord) -> Bool {
        let lhsName = lhs.displayName ?? lhs.bundleIdentifier.rawValue
        let rhsName = rhs.displayName ?? rhs.bundleIdentifier.rawValue
        let comparison = lhsName.localizedStandardCompare(rhsName)
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }
        if lhs.bundleIdentifier.rawValue != rhs.bundleIdentifier.rawValue {
            return lhs.bundleIdentifier.rawValue < rhs.bundleIdentifier.rawValue
        }
        if lhsName != rhsName {
            return lhsName < rhsName
        }
        return ApplicationRecord.libraryOrder(lhs, rhs)
    }

    /// Newest declared version first, compared the way people read
    /// versions (10.0 above 2.0), then by build; undeclared versions last;
    /// ties by the stable order.
    static func versionOrder(_ lhs: ApplicationRecord, _ rhs: ApplicationRecord) -> Bool {
        switch compareDeclaredVersions(lhs, rhs) {
        case .orderedDescending: return true
        case .orderedAscending: return false
        case .orderedSame: return ApplicationRecord.libraryOrder(lhs, rhs)
        }
    }

    /// Compares declared marketing versions, then builds, numerically.
    static func compareDeclaredVersions(_ lhs: ApplicationRecord, _ rhs: ApplicationRecord) -> ComparisonResult {
        let version = (lhs.identity.shortVersionString ?? "")
            .localizedStandardCompare(rhs.identity.shortVersionString ?? "")
        if version != .orderedSame {
            return version
        }
        return (lhs.identity.buildVersion ?? "").localizedStandardCompare(rhs.identity.buildVersion ?? "")
    }

    /// Entries carrying a date first, newest first; entries without one
    /// follow, most recently imported first.
    static func dateFirstOrder(
        _ lhsDate: Date?,
        _ rhsDate: Date?,
        _ lhs: ApplicationRecord,
        _ rhs: ApplicationRecord
    ) -> Bool {
        switch (lhsDate, rhsDate) {
        case (.some(let lhsValue), .some(let rhsValue)):
            if lhsValue != rhsValue {
                return lhsValue > rhsValue
            }
            return recentlyImportedOrder(lhs, rhs)
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return recentlyImportedOrder(lhs, rhs)
        }
    }

    /// The bytes an entry's package file occupies in storage.
    static func storedByteCount(of entry: LibraryEntry) -> Int {
        switch entry.artifactAvailability {
        case .available:
            return entry.record.artifact.byteCount
        case .missing:
            return 0
        case .inconsistent(_, let observed):
            return observed
        }
    }

    // MARK: - Private

    private func members(of scope: LibraryScope, now: Date) -> [ApplicationRecordIdentifier] {
        switch scope {
        case .all:
            return Array(entriesByID.keys)
        case .smart(let smart):
            let filter = smart.filter
            return entriesByID.keys.filter { satisfies($0, filter, now: now) }
        case .collection(let id):
            guard collection(withID: id) != nil, let members = membersByCollection[id] else { return [] }
            return Array(members)
        }
    }

    private func satisfies(_ id: ApplicationRecordIdentifier, _ filter: LibraryFilter, now: Date) -> Bool {
        guard let entry = entriesByID[id] else { return false }
        switch filter {
        case .favorites:
            return entry.record.isFavorite
        case .signed:
            return signing[id] != nil
        case .unsigned:
            return signing[id] == nil
        case .recentlyImported:
            return Self.isRecent(entry.record.importedAt, now: now)
        case .recentlySigned:
            guard let fact = signing[id] else { return false }
            return Self.isRecent(fact.lastSignedAt, now: now)
        case .expiringSoon:
            return LibraryExpiryStatus.evaluate(signing[id], now: now).needsAttention
        case .collection(let collectionID):
            return membersByCollection[collectionID]?.contains(id) ?? false
        case .version(.latest):
            return latestVersions.contains(id)
        case .version(.older):
            return !latestVersions.contains(id)
        case .team(let team):
            return provenanceByArtifact[entry.record.artifact.artifactID]?.teamIdentifier == team
        }
    }

    /// Whether `date` falls within the recent window before `now`. A date
    /// after `now` (a clock that moved backwards) counts as recent.
    private static func isRecent(_ date: Date, now: Date) -> Bool {
        now.timeIntervalSince(date) <= LibraryWindows.recent
    }

    private func sorted(
        _ ids: [ApplicationRecordIdentifier],
        by mode: LibrarySortMode
    ) -> [ApplicationRecordIdentifier] {
        let pairs = ids.compactMap { id -> (id: ApplicationRecordIdentifier, record: ApplicationRecord)? in
            guard let entry = entriesByID[id] else { return nil }
            return (id: id, record: entry.record)
        }
        let ordered: [(id: ApplicationRecordIdentifier, record: ApplicationRecord)]
        switch mode {
        case .recentlyImported:
            ordered = pairs.sorted { Self.recentlyImportedOrder($0.record, $1.record) }
        case .name:
            ordered = pairs.sorted { Self.nameOrder($0.record, $1.record) }
        case .nameDescending:
            ordered = pairs.sorted { Self.nameOrder($1.record, $0.record) }
        case .version:
            ordered = pairs.sorted { Self.versionOrder($0.record, $1.record) }
        case .size:
            ordered = pairs.sorted { lhs, rhs in
                if lhs.record.artifact.byteCount != rhs.record.artifact.byteCount {
                    return lhs.record.artifact.byteCount > rhs.record.artifact.byteCount
                }
                return Self.nameOrder(lhs.record, rhs.record)
            }
        case .recentlySigned:
            ordered = pairs.sorted { lhs, rhs in
                Self.dateFirstOrder(signing[lhs.id]?.lastSignedAt, signing[rhs.id]?.lastSignedAt, lhs.record, rhs.record)
            }
        case .lastOpened:
            ordered = pairs.sorted { lhs, rhs in
                Self.dateFirstOrder(organization.lastOpened[lhs.id], organization.lastOpened[rhs.id], lhs.record, rhs.record)
            }
        }
        return ordered.map { $0.id }
    }

    private func makeDocument(for entry: LibraryEntry) -> SearchDocument {
        let record = entry.record
        var fields: [LibrarySearchField: String] = [:]
        let names = [record.identity.declaredDisplayName, record.identity.declaredBundleName].compactMap { $0 }
        fields[.name] = LibraryQuery.fold(names.joined(separator: "\n"))
        fields[.bundleIdentifier] = LibraryQuery.fold(record.bundleIdentifier.rawValue)
        let versions = [record.identity.shortVersionString, record.identity.buildVersion].compactMap { $0 }
        fields[.version] = LibraryQuery.fold(versions.joined(separator: "\n"))
        fields[.sourceFileName] = LibraryQuery.fold(record.sourceFileName ?? "")
        if let declared = provenanceByArtifact[record.artifact.artifactID] {
            let developers = [declared.developerName, declared.teamName].compactMap { $0 }
            fields[.developer] = LibraryQuery.fold(developers.joined(separator: "\n"))
            fields[.teamIdentifier] = LibraryQuery.fold(declared.teamIdentifier ?? "")
        }
        fields[.collection] = collectionText(for: record.id)
        return SearchDocument(fields: fields)
    }

    private func collectionText(for id: ApplicationRecordIdentifier) -> String {
        guard let collectionIDs = collectionsByRecord[id], !collectionIDs.isEmpty else { return "" }
        let names = collectionIDs.compactMap { organization.collection(withID: $0)?.name }
        return LibraryQuery.fold(names.joined(separator: "\n"))
    }

    private mutating func rebuildDocuments() {
        var rebuilt: [ApplicationRecordIdentifier: SearchDocument] = [:]
        rebuilt.reserveCapacity(entriesByID.count)
        for (id, entry) in entriesByID {
            rebuilt[id] = makeDocument(for: entry)
        }
        searchIndex.replaceAll(rebuilt)
    }

    private mutating func rebuildSigning() {
        var rebuilt: [ApplicationRecordIdentifier: LibrarySigningFact] = [:]
        for (id, entry) in entriesByID {
            if let fact = signingFacts.fact(for: entry.record) {
                rebuilt[id] = fact
            }
        }
        signing = rebuilt
    }

    private mutating func rebuildMembership() {
        var members: [LibraryCollectionIdentifier: Set<ApplicationRecordIdentifier>] = [:]
        var byRecord: [ApplicationRecordIdentifier: [LibraryCollectionIdentifier]] = [:]
        for collection in organization.userCollections {
            var held: Set<ApplicationRecordIdentifier> = []
            for membership in collection.memberships where entriesByID[membership.recordID] != nil {
                if held.insert(membership.recordID).inserted {
                    byRecord[membership.recordID, default: []].append(collection.id)
                }
            }
            members[collection.id] = held
        }
        membersByCollection = members
        collectionsByRecord = byRecord
    }

    private mutating func rebuildLatestVersions() {
        var best: [String: ApplicationRecord] = [:]
        for entry in entriesByID.values {
            let key = entry.record.bundleIdentifier.rawValue
            if let current = best[key] {
                if Self.compareDeclaredVersions(entry.record, current) == .orderedDescending {
                    best[key] = entry.record
                }
            } else {
                best[key] = entry.record
            }
        }
        var latest: Set<ApplicationRecordIdentifier> = []
        for (id, entry) in entriesByID {
            guard let top = best[entry.record.bundleIdentifier.rawValue] else { continue }
            if Self.compareDeclaredVersions(entry.record, top) != .orderedAscending {
                latest.insert(id)
            }
        }
        latestVersions = latest
    }
}
