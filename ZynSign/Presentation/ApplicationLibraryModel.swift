import Foundation
import Combine

/// The presentation-side state machine for the Applications Library screen.
///
/// The model carries exactly one content phase at a time — loading, loaded,
/// empty, or failed — so the screen can never show an empty library while
/// records are still being read, and never silently drops a persistence
/// failure. Removal, import, organization, and the bulk operations are part
/// of the same machine, and every outcome is either shown or announced.
///
/// **One index, many questions.** Everything the screen asks — which
/// entries the current scope, filters, search, and order select; how many
/// entries each smart collection and collection holds; the library
/// statistics; whether an entry is signed or expiring — is answered from a
/// `LibraryIndex` built from persistence. Typing, toggling a filter, or
/// changing the order runs a query over the index and publishes the list of
/// visible identifiers; nothing is re-read, and rows whose content did not
/// change are not re-rendered.
///
/// **Incremental, but never invented.** A full read (on appearance, on
/// refresh, after an import or a removal) rebuilds the index from the
/// library, the organization, the signing journal, and the provenance known
/// so far. A small change — a favourite toggled, applications moved between
/// collections, an application opened — re-reads only what changed from
/// persistence and patches the index. The list is never edited on the
/// strength of a request alone: what the screen shows is what persistence
/// returned after the change.
///
/// **Safety.** A selection only ever holds entries the screen is showing:
/// when a filter or search hides an entry, it leaves the selection, so a
/// bulk action can never touch something the user cannot see. One bulk
/// operation runs at a time. Deletion is confirmed by the view and then
/// removes each entry through the library's own removal, record first.
///
/// The model coordinates nothing itself: it invokes application-layer use
/// cases and observes the shared Import Hub and the signing journal.
/// Persistence and file work run off the main actor inside those use cases;
/// every state transition happens here, on the main actor.
@MainActor
final class ApplicationLibraryModel: ObservableObject {

    /// How the library orders its entries. The library's own query
    /// vocabulary, named here for the screen and its tests.
    typealias SortOrder = LibrarySortMode

    /// The signing state one entry's card shows, derived from the on-device
    /// signing journal and the artifact's availability.
    ///
    /// "Signed" means the journal records a successful signing attributable
    /// to the entry (see `LibrarySigningFacts`). "Package Problem" means the
    /// artifact is missing or no longer matches the record. Anything else
    /// reads as not signed — ZynSign holds no signed output for the entry.
    enum SigningState: Equatable {
        case signed
        case notSigned
        case packageProblem
    }

    /// The phase of the library's content, rendered directly by the view.
    enum Phase: Equatable {

        /// The library is being read from persistence. The initial phase, so
        /// the screen never presents an empty library as a finding.
        case loading

        /// The library holds the given entries, in library order.
        case loaded([LibraryEntry])

        /// The library was read and holds no records.
        case empty

        /// The library could not be read. Carries a user-presentable
        /// explanation, never diagnostic detail.
        case failed(String)
    }

    /// A transient, user-presentable announcement — an import outcome, or a
    /// failure that did not need to replace the content on screen. The view
    /// renders it as an alert and clears it when acknowledged.
    struct Notice: Equatable, Identifiable {
        let title: String
        let message: String

        var id: String { "\(title)-\(message)" }
    }

    /// A brief confirmation that something worked, shown without
    /// interrupting.
    struct Confirmation: Equatable, Identifiable {
        let id = UUID()
        let message: String
    }

    /// What a running multi-entry operation has done so far.
    struct Progress: Equatable {
        let title: String
        let completed: Int
        let total: Int
    }

    /// Why the loaded library shows no rows, so the view can explain it.
    enum EmptyReason: Equatable {

        /// The search or the filters exclude every entry in scope.
        case noResults

        /// The smart collection currently holds nothing.
        case smartCollection(LibrarySmartCollection)

        /// The collection currently holds nothing.
        case emptyCollection(name: String)
    }

    /// The outcome of verifying one or more entries.
    struct VerificationReport: Equatable, Identifiable {

        struct Item: Equatable, Identifiable {
            enum Outcome: Equatable {
                case checked(ArtifactIntegrity)
                case failed(String)
            }

            let id: ApplicationRecordIdentifier
            let name: String
            let outcome: Outcome

            var isIntact: Bool {
                outcome == .checked(.intact)
            }
        }

        let id: UUID
        let items: [Item]

        var intactCount: Int {
            items.filter(\.isIntact).count
        }

        var problemCount: Int {
            items.count - intactCount
        }

        /// One sentence summarising the outcome.
        var summary: String {
            if problemCount == 0 {
                return items.count == 1
                    ? "The package file matches what was recorded at import."
                    : "All \(items.count) package files match what was recorded at import."
            }
            if intactCount == 0 {
                return items.count == 1
                    ? "The package file could not be confirmed."
                    : "None of the \(items.count) package files could be confirmed."
            }
            return "\(intactCount) of \(items.count) package files match; \(problemCount) need attention."
        }
    }

    /// Everything one row or card needs, as one comparable value, so an
    /// unchanged row is never re-rendered.
    struct RowState: Equatable {
        let entry: LibraryEntry
        let signingState: SigningState
        let expiry: LibraryExpiryStatus
        let highlightTerms: [String]
        let matchContext: String?
        let isSelected: Bool?
    }

    // MARK: - Published state

    /// The current content phase of the library.
    @Published private(set) var phase: Phase = .loading

    /// The search text. Every word must occur in the name, bundle
    /// identifier, version, file name, declared developer or team, or the
    /// name of a collection the entry is in.
    @Published var searchText = "" {
        didSet { if searchText != oldValue { recomputeResults() } }
    }

    /// The order the library is listed in.
    @Published var sortOrder: SortOrder = .recentlyImported {
        didSet { if sortOrder != oldValue { recomputeResults() } }
    }

    /// The stacked filters. See `LibraryFilter` for how they combine.
    @Published var filters: Set<LibraryFilter> = [] {
        didSet { if filters != oldValue { recomputeResults() } }
    }

    /// Where the user is looking: everything, a smart collection, or a
    /// collection.
    @Published var scope: LibraryScope = .all {
        didSet { if scope != oldValue { recomputeResults() } }
    }

    /// The identifiers of the entries the screen shows, in order.
    @Published private(set) var visibleIDs: [ApplicationRecordIdentifier] = []

    /// The index every answer comes from.
    @Published private(set) var index = LibraryIndex()

    /// The library-wide statistics.
    @Published private(set) var statistics = LibraryStatistics.zero

    /// How many entries each scope holds before filters and search.
    @Published private(set) var scopeCounts: [LibraryScope: Int] = [:]

    /// The development teams the library's packages declare.
    @Published private(set) var teams: [LibraryTeam] = []

    /// Whether the screen is in selection mode. Leaving it clears the
    /// selection.
    @Published var isSelecting = false {
        didSet {
            if !isSelecting && !selection.isEmpty {
                selection = []
            }
        }
    }

    /// The selected entries. Always a subset of `visibleIDs`.
    @Published private(set) var selection: Set<ApplicationRecordIdentifier> = []

    /// The progress of a running verification or export, if any.
    @Published private(set) var progress: Progress?

    /// The outcome of the last verification, until acknowledged.
    @Published private(set) var verificationReport: VerificationReport?

    /// Package files prepared for the share sheet, until it closes.
    @Published private(set) var exportBundle: LibraryExportBundle?

    /// A brief confirmation to show, if any.
    @Published private(set) var confirmation: Confirmation?

    /// Whether a bulk removal is running. One removal runs at a time; the
    /// view disables its destructive controls while this is set.
    @Published private(set) var isRemovingSelection = false

    /// The record whose removal is running, so the view can mark the entry.
    /// `nil` whenever no removal is running.
    @Published private(set) var removingRecordID: ApplicationRecordIdentifier?

    /// The announcement to show, if any. Cleared by `clearNotice()` once the
    /// user has acknowledged it.
    @Published private(set) var notice: Notice?

    // MARK: - Dependencies

    private let library: ApplicationLibrary
    private let hub: ImportHub
    private let signingHistory: (any SigningHistoryStore)?
    private let organizer: LibraryOrganizer?
    private let provenanceSource: ApplicationProvenanceExtraction?
    private let exporter: LibraryExportPreparation?
    private let performanceEngine: PerformanceEngine?
    private let now: () -> Date

    /// The incremental render window over `visibleIDs`: how many rows the
    /// list materialises right now. It grows as the user scrolls and
    /// resets when the query changes, so a 1,000-entry library costs the
    /// first screen and a little more, not a thousand rows at once.
    @Published private(set) var renderWindow = IncrementalRenderWindow()

    private var isReadingLibrary = false
    private var hasPendingRead = false
    private var hasAnnouncedOrganizationFailure = false
    private var provenanceTask: Task<Void, Never>?

    /// The subscriptions that keep this model following the Import Hub
    /// and the signing journal.
    private var cancellables: Set<AnyCancellable> = []

    /// The imports whose outcome has already been announced, so a settle is
    /// reported once and not again on every later change to the job list.
    private var announcedImportJobs: Set<ImportJobIdentifier> = []

    /// Creates the model over the library use case and the shared Import
    /// Hub, which it observes.
    ///
    /// Everything else is optional, so a composition that lacks a capability
    /// renders without it rather than failing: no signing journal means no
    /// entry shows as signed; no organizer means no collections or usage;
    /// no provenance source means developer and team are never known; no
    /// exporter means Export is not offered. `now` anchors the recency and
    /// expiry windows and is injectable for deterministic tests.
    init(
        library: ApplicationLibrary,
        hub: ImportHub,
        signingHistory: (any SigningHistoryStore)? = nil,
        organizer: LibraryOrganizer? = nil,
        provenance: ApplicationProvenanceExtraction? = nil,
        exporter: LibraryExportPreparation? = nil,
        performanceEngine: PerformanceEngine? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.library = library
        self.hub = hub
        self.signingHistory = signingHistory
        self.organizer = organizer
        self.provenanceSource = provenance
        self.exporter = exporter
        self.performanceEngine = performanceEngine
        self.now = now

        // The hub publishes on the main actor, so each delivery is handed
        // to the main actor explicitly rather than relying on where the
        // change happened to be made.
        hub.$items
            .map { items in items.compactMap { item in item.settlement.map { (item.id, $0) } } }
            .removeDuplicates { lhs, rhs in lhs.map(\.0) == rhs.map(\.0) }
            .sink { [weak self] settled in
                Task { @MainActor in
                    self?.handleSettledImports(settled)
                }
            }
            .store(in: &cancellables)

        // A signing run elsewhere changes what is signed, recently signed,
        // and expiring; the journal is re-read when it says so.
        NotificationCenter.default.publisher(for: .signingHistoryDidChange)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.refreshSigningFacts()
                }
            }
            .store(in: &cancellables)

        // Anything the hub settled before this model existed still has to
        // be acted on, so the current state is applied once at creation.
        handleSettledImports(hub.items.compactMap { item in item.settlement.map { (item.id, $0) } })
    }

    // MARK: - Capabilities

    /// Whether collections and usage can be kept.
    var canOrganize: Bool { organizer != nil }

    /// Whether package files can be exported.
    var canExport: Bool { exporter != nil }

    /// Whether a bulk operation is running.
    var isBusy: Bool {
        isRemovingSelection || progress != nil
    }

    // MARK: - Loading

    /// Loads the library when the screen appears. The first load presents
    /// the loading state; once content is on screen the same call acts as a
    /// refresh that keeps the content visible while persistence is read
    /// again — so a record imported in another area appears without the
    /// screen flashing through a loading state, and a failure during such a
    /// refresh never replaces the user's library with an error screen.
    func load() async {
        switch phase {
        case .loaded, .empty:
            await refresh()
        case .loading, .failed:
            await readLibrary(presentingLoadingState: true)
        }
    }

    /// Reads the library again while keeping whatever is on screen.
    func refresh() async {
        await readLibrary(presentingLoadingState: false)
    }

    /// Reads the library and updates the phase. A read already in progress
    /// is not interrupted; a request arriving during one is answered by a
    /// follow-up read, so a refresh can never be lost to a concurrent load.
    private func readLibrary(presentingLoadingState: Bool) async {
        if isReadingLibrary {
            hasPendingRead = true
            return
        }
        isReadingLibrary = true
        defer { isReadingLibrary = false }
        var showLoadingState = presentingLoadingState
        while true {
            if showLoadingState {
                phase = .loading
            }
            do {
                let started = ContinuousClock.now
                let entries = try await library.entries()
                let organization = await readOrganization()
                let signingFacts = await readSigningFacts()
                let knownProvenance = await provenanceSource?.knownProvenance() ?? [:]
                index = LibraryIndex(
                    entries: entries,
                    organization: organization,
                    signingFacts: signingFacts,
                    provenance: knownProvenance
                )
                phase = entries.isEmpty ? .empty : .loaded(entries)
                indexDidChange()
                recordBenchmark(.libraryLoad, since: started, itemCount: entries.count)
                resolveProvenance(for: entries)
            } catch {
                if showLoadingState {
                    phase = .failed(Self.failureMessage(for: error))
                } else {
                    // Content is on screen; keep it and announce the failure
                    // rather than silently discarding it.
                    notice = Notice(
                        title: Self.refreshFailureTitle,
                        message: Self.failureMessage(for: error)
                    )
                }
            }
            guard hasPendingRead else { break }
            hasPendingRead = false
            showLoadingState = false
        }
    }

    /// Reads the organization. A failure keeps the organization already
    /// shown and is announced once, not on every refresh; the library's
    /// applications are listed either way.
    private func readOrganization() async -> LibraryOrganization {
        guard let organizer else { return .empty }
        do {
            let organization = try await organizer.organization()
            hasAnnouncedOrganizationFailure = false
            return organization
        } catch {
            if !hasAnnouncedOrganizationFailure {
                hasAnnouncedOrganizationFailure = true
                notice = Notice(title: Self.collectionsFailureTitle, message: Self.failureMessage(for: error))
            }
            return index.organization
        }
    }

    /// Reads the signing journal. A read failure leaves the previous facts
    /// standing — the journal is a convenience view of history, and a
    /// failed read must not turn entries unsigned.
    private func readSigningFacts() async -> LibrarySigningFacts {
        guard let signingHistory else { return .empty }
        do {
            let records = try await signingHistory.allRecords()
            return LibrarySigningFacts(journal: records)
        } catch {
            return index.signingFacts
        }
    }

    /// Re-reads the signing journal alone and patches the index.
    func refreshSigningFacts() async {
        let facts = await readSigningFacts()
        guard facts != index.signingFacts else { return }
        var updated = index
        updated.setSigningFacts(facts)
        index = updated
        indexDidChange()
    }

    /// Resolves the declared developer and team of packages not yet known,
    /// in the background and a few at a time, patching the index as results
    /// arrive. The list is already on screen; this only adds detail.
    private func resolveProvenance(for entries: [LibraryEntry]) {
        guard let provenanceSource else { return }
        let pending = entries
            .filter { $0.isArtifactAvailable && !index.hasResolvedProvenance(for: $0.record.artifact.artifactID) }
            .map { $0.record.artifact.artifactID }
        guard !pending.isEmpty else { return }
        provenanceTask?.cancel()
        provenanceTask = Task { [weak self] in
            let chunkSize = 16
            var start = 0
            while start < pending.count {
                if Task.isCancelled { return }
                let chunk = Array(pending[start..<min(start + chunkSize, pending.count)])
                start += chunkSize
                let resolved = await provenanceSource.resolve(chunk)
                guard let self else { return }
                self.applyProvenance(resolved)
            }
        }
    }

    private func applyProvenance(_ resolved: [ArtifactIdentifier: ApplicationProvenance]) {
        let additions = resolved.filter { index.provenanceByArtifact[$0.key] != $0.value }
        guard !additions.isEmpty else { return }
        var updated = index
        updated.mergeProvenance(additions)
        index = updated
        teams = index.teams()
        reportToPerformanceEngine()
        recomputeResults()
    }

    // MARK: - Derived state

    /// Recomputes everything derived from the index: statistics, teams,
    /// scope counts, and the visible list. Scopes and filters that name a
    /// collection that no longer exists fall back to everything.
    private func indexDidChange() {
        statistics = index.statistics()
        teams = index.teams()
        scopeCounts = computeScopeCounts()
        reportToPerformanceEngine()
        if let collectionID = scope.collectionID, index.collection(withID: collectionID) == nil {
            scope = .all
        }
        let validFilters = filters.filter { filter in
            if case .collection(let id) = filter {
                return index.collection(withID: id) != nil
            }
            return true
        }
        if validFilters != filters {
            filters = validFilters
        }
        recomputeResults()
    }

    private func computeScopeCounts() -> [LibraryScope: Int] {
        let date = now()
        var counts: [LibraryScope: Int] = [.all: index.count]
        for smart in LibrarySmartCollection.allCases {
            counts[.smart(smart)] = index.entryCount(in: .smart(smart), now: date)
        }
        for collection in index.userCollections {
            counts[.collection(collection.id)] = index.memberCount(of: collection.id)
        }
        return counts
    }

    /// Runs the current query and publishes the visible identifiers when
    /// they changed. Entries that are no longer visible leave the selection.
    private func recomputeResults() {
        let query = LibraryQuery(searchText: searchText, filters: filters, sort: sortOrder)
        let started = ContinuousClock.now
        let results = index.results(for: query, in: scope, now: now())
        if !query.foldedSearchTerms.isEmpty {
            recordBenchmark(.searchLatency, since: started, itemCount: index.count)
        }
        if results != visibleIDs {
            visibleIDs = results
            var window = renderWindow
            window.reset()
            if window != renderWindow {
                renderWindow = window
            }
        }
        if !selection.isEmpty {
            let pruned = selection.intersection(results)
            if pruned != selection {
                selection = pruned
            }
        }
    }

    // MARK: - Performance

    /// The identifiers the list materialises right now: the visible
    /// results, cut to the render window.
    var renderedIDs: [ApplicationRecordIdentifier] {
        renderWindow.rendered(of: visibleIDs)
    }

    /// How many visible results the window has not materialised yet.
    var unrenderedCount: Int {
        renderWindow.remainingCount(of: visibleIDs.count)
    }

    /// Tells the window a row appeared; the window grows when the row is
    /// near its end. Called from the row's `onAppear`, so it is cheap and
    /// publishes only when the limit actually moves.
    func rowDidAppear(_ id: ApplicationRecordIdentifier) {
        guard renderWindow.isTruncating(visibleIDs.count),
              let position = renderedIDs.lastIndex(of: id) else { return }
        var window = renderWindow
        if window.rowDidAppear(at: position, total: visibleIDs.count) {
            renderWindow = window
        }
    }

    /// Materialises every visible row at once.
    func showAllRows() {
        guard renderWindow.isTruncating(visibleIDs.count) else { return }
        var window = renderWindow
        window.showAll()
        renderWindow = window
    }

    /// The readiness of the search index as the Performance page reports
    /// it: ready once every entry is indexed, building while provenance is
    /// still being resolved for available packages.
    var searchIndexStatus: SearchIndexStatus {
        let indexed = index.searchIndex.count
        if indexed == 0 { return .empty }
        let awaitingProvenance = provenanceSource == nil ? 0 : index.entriesByID.values.filter {
            $0.isArtifactAvailable && !index.hasResolvedProvenance(for: $0.record.artifact.artifactID)
        }.count
        if awaitingProvenance > 0 {
            return .building(indexed: indexed - awaitingProvenance, total: indexed)
        }
        return .ready(indexed: indexed)
    }

    private func reportToPerformanceEngine() {
        guard let performanceEngine else { return }
        let count = index.count
        let status = searchIndexStatus
        let indexed: Int
        switch status {
        case .empty: indexed = 0
        case .building(let done, _): indexed = done
        case .ready(let done), .stale(let done): indexed = done
        }
        // The metadata index — the facts the list shows without opening a
        // package — is reconciled off the main actor; it diffs against what
        // it holds, so a report that changed nothing writes nothing.
        let entries = Array(index.entriesByID.values)
        let provenance = index.provenanceByArtifact
        let facts = index.signingFacts
        Task.detached(priority: .utility) {
            await performanceEngine.reportLibrary(itemCount: count, indexed: indexed, status: status)
            await performanceEngine.metadata.reconcile(entries: entries, provenance: provenance, signingFacts: facts)
        }
    }

    /// Drops everything the engine derived from a removed application —
    /// thumbnails, cached entry tables, its metadata row — so nothing
    /// refers to a package the library no longer holds.
    private func forgetDerivedData(for entry: LibraryEntry) {
        guard let performanceEngine else { return }
        let artifactID = entry.record.artifact.artifactID
        let recordID = entry.record.id
        Task.detached(priority: .utility) {
            await performanceEngine.forget(artifactID: artifactID)
            await performanceEngine.metadata.forget([recordID])
        }
    }

    private func recordBenchmark(_ kind: BenchmarkKind, since started: ContinuousClock.Instant, itemCount: Int) {
        guard let performanceEngine else { return }
        let elapsed = ContinuousClock.now - started
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        Task { await performanceEngine.benchmarks.record(kind: kind, duration: seconds, itemCount: itemCount) }
    }

    // MARK: - Reading for the view

    /// The entries the screen shows for the current scope, filters, search,
    /// and order.
    func visibleEntries() -> [LibraryEntry] {
        guard case .loaded = phase else { return [] }
        return visibleIDs.compactMap { index.entry(for: $0) }
    }

    /// The entry for `id`, or `nil` when the library no longer holds it.
    func entry(for id: ApplicationRecordIdentifier) -> LibraryEntry? {
        index.entry(for: id)
    }

    /// Everything one row or card renders.
    func rowState(for id: ApplicationRecordIdentifier) -> RowState? {
        guard let entry = index.entry(for: id) else { return nil }
        let terms = LibraryQuery.terms(in: searchText)
        return RowState(
            entry: entry,
            signingState: signingState(for: entry),
            expiry: index.expiryStatus(for: id, now: now()),
            highlightTerms: terms,
            matchContext: matchContext(for: id, terms: terms),
            isSelected: isSelecting ? selection.contains(id) : nil
        )
    }

    /// Whether the query currently narrows the scope.
    var isNarrowing: Bool {
        !LibraryQuery.terms(in: searchText).isEmpty || !filters.isEmpty
    }

    /// Why the loaded library shows no rows, or `nil` when it shows some or
    /// is not loaded.
    var emptyReason: EmptyReason? {
        guard case .loaded = phase, visibleIDs.isEmpty else { return nil }
        if isNarrowing {
            return .noResults
        }
        switch scope {
        case .all:
            return .noResults
        case .smart(let smart):
            return .smartCollection(smart)
        case .collection(let id):
            return .emptyCollection(name: index.collection(withID: id)?.name ?? "Collection")
        }
    }

    /// The title for the current scope.
    var scopeTitle: String? {
        switch scope {
        case .all: return nil
        case .smart(let smart): return smart.title
        case .collection(let id): return index.collection(withID: id)?.name
        }
    }

    /// A line explaining a match the visible row text does not show: the
    /// declared developer or team, the original file name, or the
    /// collections the entry is in.
    private func matchContext(for id: ApplicationRecordIdentifier, terms: [String]) -> String? {
        guard !terms.isEmpty else { return nil }
        let fields = index.matchedFields(for: id, foldedTerms: terms.map(LibraryQuery.fold))
        var parts: [String] = []
        let provenance = index.provenance(for: id)
        for field in fields {
            switch field {
            case .name, .bundleIdentifier, .version:
                continue
            case .sourceFileName:
                if let file = index.entry(for: id)?.record.sourceFileName {
                    parts.append("File: \(file)")
                }
            case .developer:
                if let developer = provenance?.displayDeveloper {
                    parts.append("Developer: \(developer)")
                }
            case .teamIdentifier:
                if let team = provenance?.teamIdentifier {
                    parts.append("Team: \(team)")
                }
            case .collection:
                let names = index.collections(containing: id).map(\.name)
                if !names.isEmpty {
                    parts.append("In: \(names.joined(separator: ", "))")
                }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Filtering and ordering

    /// Adds `filter` when absent and removes it when present.
    func toggleFilter(_ filter: LibraryFilter) {
        if filters.contains(filter) {
            filters.remove(filter)
        } else {
            filters.insert(filter)
        }
    }

    /// Removes every filter and the search text.
    func clearFiltersAndSearch() {
        filters = []
        searchText = ""
    }

    /// Whether `entry` matches `query`: every word of the query occurs in
    /// the entry's name, bundle identifier, version, or source file name.
    /// An empty query matches everything. Internal so the rule is testable
    /// without views.
    static func matches(_ entry: LibraryEntry, query: String) -> Bool {
        let index = LibraryIndex(entries: [entry])
        return !index.results(for: LibraryQuery(searchText: query), now: Date()).isEmpty
    }

    /// Orders `entries` by `order`, most preferred first, using the same
    /// ordering rules the screen uses. Orders that depend on the signing
    /// journal or on usage fall back to recency here, where neither is
    /// known.
    static func ordered(_ entries: [LibraryEntry], by order: SortOrder) -> [LibraryEntry] {
        let index = LibraryIndex(entries: entries)
        return index.results(for: LibraryQuery(sort: order), now: Date()).compactMap { index.entry(for: $0) }
    }

    /// The filtered, ordered list for a query and order.
    static func displayed(_ entries: [LibraryEntry], matching query: String, sortedBy order: SortOrder) -> [LibraryEntry] {
        let index = LibraryIndex(entries: entries)
        return index.results(for: LibraryQuery(searchText: query, sort: order), now: Date())
            .compactMap { index.entry(for: $0) }
    }

    // MARK: - Signing state

    /// The signing state an entry's card shows, derived from the artifact's
    /// availability and the signing journal observed at the last read.
    func signingState(for entry: LibraryEntry) -> SigningState {
        if !entry.isArtifactAvailable {
            return .packageProblem
        }
        if index.signingFacts.fact(for: entry.record) != nil {
            return .signed
        }
        return .notSigned
    }

    // MARK: - Selection

    /// Enters or leaves selection mode.
    func setSelecting(_ selecting: Bool) {
        isSelecting = selecting
    }

    /// Selects `id` when it is visible and unselected; deselects it when
    /// selected.
    func toggleSelection(_ id: ApplicationRecordIdentifier) {
        if selection.contains(id) {
            selection.remove(id)
        } else if visibleIDs.contains(id) {
            selection.insert(id)
        }
    }

    /// Selects every visible entry.
    func selectAll() {
        selection = Set(visibleIDs)
    }

    /// Clears the selection, staying in selection mode.
    func deselectAll() {
        selection = []
    }

    /// Whether every visible entry is selected.
    var isEverythingSelected: Bool {
        !visibleIDs.isEmpty && selection.count == visibleIDs.count
    }

    /// The selected identifiers, in the order the screen shows them.
    var selectedIDs: [ApplicationRecordIdentifier] {
        visibleIDs.filter { selection.contains($0) }
    }

    /// The selected entries, in the order the screen shows them.
    var selectedEntries: [LibraryEntry] {
        selectedIDs.compactMap { index.entry(for: $0) }
    }

    /// Whether every entry in `ids` is a favourite.
    func areAllFavorites(_ ids: [ApplicationRecordIdentifier]) -> Bool {
        let entries = ids.compactMap { index.entry(for: $0) }
        return !entries.isEmpty && entries.allSatisfy(\.record.isFavorite)
    }

    // MARK: - Favourites

    /// Marks or unmarks an entry as a favourite, then re-reads that entry so
    /// the screen reflects persistence. A failure is announced and the whole
    /// library is re-read, so the screen shows what the library holds.
    func setFavorite(_ isFavorite: Bool, on entry: LibraryEntry) async {
        do {
            try await library.setFavorite(isFavorite, recordWithID: entry.record.id)
        } catch {
            notice = Notice(
                title: Self.favoriteFailureTitle,
                message: Self.failureMessage(for: error)
            )
            await refresh()
            return
        }
        await reloadEntries([entry.record.id])
    }

    /// Favourites every entry in `ids` — or, when all of them already are,
    /// removes them all from Favorites. Entries already in the requested
    /// state are left alone.
    func toggleFavorite(_ ids: [ApplicationRecordIdentifier]) async {
        let entries = ids.compactMap { index.entry(for: $0) }
        guard !entries.isEmpty else { return }
        let makeFavorite = !entries.allSatisfy(\.record.isFavorite)
        var changed: [ApplicationRecordIdentifier] = []
        var failures = 0
        for entry in entries where entry.record.isFavorite != makeFavorite {
            do {
                try await library.setFavorite(makeFavorite, recordWithID: entry.record.id)
                changed.append(entry.record.id)
            } catch {
                failures += 1
            }
        }
        await reloadEntries(changed)
        if failures > 0 {
            notice = Notice(
                title: Self.favoriteFailureTitle,
                message: "\(failures) of \(entries.count) applications could not be updated."
            )
        } else if entries.count > 1 {
            confirm(makeFavorite
                    ? "Added \(Self.applicationCount(entries.count)) to Favorites"
                    : "Removed \(Self.applicationCount(entries.count)) from Favorites")
        }
    }

    /// Re-reads the named entries from persistence and patches them into the
    /// index. An entry the library no longer holds leaves the index. A read
    /// failure falls back to re-reading the whole library.
    private func reloadEntries(_ ids: [ApplicationRecordIdentifier]) async {
        guard !ids.isEmpty else { return }
        var fresh: [LibraryEntry] = []
        var removed: Set<ApplicationRecordIdentifier> = []
        for id in ids {
            do {
                if let entry = try await library.entry(withID: id) {
                    fresh.append(entry)
                } else {
                    removed.insert(id)
                }
            } catch {
                await refresh()
                return
            }
        }
        // The index is copied only after every read, so nothing another
        // task patched in while this one was reading is overwritten.
        var updated = index
        for entry in fresh {
            updated.update(entry)
        }
        updated.remove(removed)
        index = updated
        syncPhaseWithIndex()
        indexDidChange()
    }

    /// Brings the phase's entry list in line with the index, keeping library
    /// order.
    private func syncPhaseWithIndex() {
        let entries: [LibraryEntry]
        if case .loaded(let current) = phase {
            let patched = current.compactMap { index.entry(for: $0.record.id) }
            if patched.count == index.count {
                entries = patched
            } else {
                entries = index.entriesByID.values.sorted { ApplicationRecord.libraryOrder($0.record, $1.record) }
            }
        } else {
            entries = index.entriesByID.values.sorted { ApplicationRecord.libraryOrder($0.record, $1.record) }
        }
        phase = entries.isEmpty ? .empty : .loaded(entries)
    }

    // MARK: - Collections

    /// The collections the user made, in creation order.
    var userCollections: [LibraryCollection] {
        index.userCollections
    }

    /// The user collection with `id`, or `nil`.
    func collection(withID id: LibraryCollectionIdentifier) -> LibraryCollection? {
        index.collection(withID: id)
    }

    /// The user collections containing `id`.
    func collections(containing id: ApplicationRecordIdentifier) -> [LibraryCollection] {
        index.collections(containing: id)
    }

    /// Whether the collection holds every entry in `ids`.
    func collection(_ collectionID: LibraryCollectionIdentifier, containsAll ids: [ApplicationRecordIdentifier]) -> Bool {
        index.collection(collectionID, containsAll: ids)
    }

    /// Checks a name the user is typing, returning a user-presentable reason
    /// it cannot be used, or `nil` when it can. `renaming` names the
    /// collection being renamed.
    func collectionNameProblem(_ raw: String, renaming id: LibraryCollectionIdentifier? = nil) -> String? {
        do {
            _ = try index.organization.validatedName(raw, excluding: id)
            return nil
        } catch {
            return Self.failureMessage(for: error)
        }
    }

    /// Creates a collection holding `ids`. When `source` names the
    /// collection the user is viewing, the entries are then taken out of it,
    /// so creating from a collection moves rather than copies. Returns a
    /// user-presentable reason when the collection could not be created, or
    /// `nil` once it exists — a failure to take the entries out of `source`
    /// afterwards is announced separately, because the new collection
    /// stands either way.
    func createCollection(
        named name: String,
        adding ids: [ApplicationRecordIdentifier] = [],
        movingFrom source: LibraryCollectionIdentifier? = nil
    ) async -> String? {
        guard let organizer else { return Self.organizationUnavailableMessage }
        let created: (collection: LibraryCollection, organization: LibraryOrganization)
        do {
            created = try await organizer.createCollection(named: name, containing: ids)
        } catch {
            return Self.failureMessage(for: error)
        }
        applyOrganization(created.organization)
        guard !ids.isEmpty else {
            confirm("Created “\(created.collection.name)”")
            return nil
        }
        if let source, source != created.collection.id {
            do {
                let updated = try await organizer.remove(ids, from: source)
                applyOrganization(updated)
                confirm("Moved \(Self.applicationCount(ids.count)) to “\(created.collection.name)”")
            } catch {
                notice = Notice(title: Self.collectionsFailureTitle, message: Self.failureMessage(for: error))
            }
        } else {
            confirm("Added \(Self.applicationCount(ids.count)) to “\(created.collection.name)”")
        }
        return nil
    }

    /// Renames a collection. Returns a user-presentable reason when it could
    /// not be renamed, or `nil` on success.
    func renameCollection(_ id: LibraryCollectionIdentifier, to name: String) async -> String? {
        guard let organizer else { return Self.organizationUnavailableMessage }
        do {
            let updated = try await organizer.renameCollection(id, to: name)
            applyOrganization(updated)
            return nil
        } catch {
            return Self.failureMessage(for: error)
        }
    }

    /// Deletes a collection. Its applications stay in the library.
    func deleteCollection(_ id: LibraryCollectionIdentifier) async {
        guard let organizer else { return }
        let name = index.collection(withID: id)?.name
        do {
            let updated = try await organizer.deleteCollection(id)
            applyOrganization(updated)
            if let name {
                confirm("Deleted “\(name)” — its apps are still in your library")
            }
        } catch {
            notice = Notice(title: Self.collectionsFailureTitle, message: Self.failureMessage(for: error))
        }
    }

    /// Adds `ids` to a collection.
    func add(_ ids: [ApplicationRecordIdentifier], to collectionID: LibraryCollectionIdentifier) async {
        guard let organizer, !ids.isEmpty else { return }
        do {
            let updated = try await organizer.add(ids, to: collectionID)
            applyOrganization(updated)
            if let name = index.collection(withID: collectionID)?.name {
                confirm("Added \(Self.applicationCount(ids.count)) to “\(name)”")
            }
        } catch {
            notice = Notice(title: Self.collectionsFailureTitle, message: Self.failureMessage(for: error))
        }
    }

    /// Moves `ids` from one collection to another as one change.
    func move(
        _ ids: [ApplicationRecordIdentifier],
        from source: LibraryCollectionIdentifier,
        to destination: LibraryCollectionIdentifier
    ) async {
        guard let organizer, !ids.isEmpty else { return }
        do {
            let updated = try await organizer.move(ids, from: source, to: destination)
            applyOrganization(updated)
            if let name = index.collection(withID: destination)?.name {
                confirm("Moved \(Self.applicationCount(ids.count)) to “\(name)”")
            }
        } catch {
            notice = Notice(title: Self.collectionsFailureTitle, message: Self.failureMessage(for: error))
        }
    }

    /// Removes `ids` from a collection. The applications stay in the
    /// library and in every other collection.
    func remove(_ ids: [ApplicationRecordIdentifier], fromCollection collectionID: LibraryCollectionIdentifier) async {
        guard let organizer, !ids.isEmpty else { return }
        let name = index.collection(withID: collectionID)?.name
        do {
            let updated = try await organizer.remove(ids, from: collectionID)
            applyOrganization(updated)
            if let name {
                confirm("Removed \(Self.applicationCount(ids.count)) from “\(name)”")
            }
        } catch {
            notice = Notice(title: Self.collectionsFailureTitle, message: Self.failureMessage(for: error))
        }
    }

    /// Adds `id` to the collection when it is not a member, and removes it
    /// when it is.
    func toggleMembership(of id: ApplicationRecordIdentifier, in collectionID: LibraryCollectionIdentifier) async {
        if index.collection(collectionID, containsAll: [id]) {
            await remove([id], fromCollection: collectionID)
        } else {
            await add([id], to: collectionID)
        }
    }

    /// Records that an application's details were opened, for the Last
    /// Opened order. A failure to record it is not worth interrupting the
    /// user for, and is dropped.
    func recordOpened(_ id: ApplicationRecordIdentifier) async {
        guard let organizer, index.entry(for: id) != nil else { return }
        if let updated = try? await organizer.recordOpened(id) {
            applyOrganization(updated)
        }
    }

    private func applyOrganization(_ organization: LibraryOrganization) {
        guard organization != index.organization else { return }
        var updated = index
        updated.setOrganization(organization)
        index = updated
        indexDidChange()
    }

    // MARK: - Verification

    /// Verifies the package files of `ids`, one after another, and publishes
    /// a report. Verification only reads; if it finds a problem the library
    /// is re-read so the cards show the files' current state.
    func verify(_ ids: [ApplicationRecordIdentifier]) async {
        let entries = ids.compactMap { index.entry(for: $0) }
        guard !entries.isEmpty, progress == nil else { return }
        var items: [VerificationReport.Item] = []
        for (offset, entry) in entries.enumerated() {
            progress = Progress(title: "Verifying", completed: offset, total: entries.count)
            let name = entry.record.displayName ?? "Unnamed Application"
            do {
                let integrity = try await library.verifyArtifact(recordWithID: entry.record.id)
                items.append(VerificationReport.Item(id: entry.record.id, name: name, outcome: .checked(integrity)))
            } catch {
                items.append(VerificationReport.Item(
                    id: entry.record.id,
                    name: name,
                    outcome: .failed(Self.failureMessage(for: error))
                ))
            }
        }
        progress = nil
        let report = VerificationReport(id: UUID(), items: items)
        verificationReport = report
        if report.problemCount > 0 {
            await refresh()
        }
    }

    /// Clears the verification report once the user has read it.
    func clearVerificationReport() {
        verificationReport = nil
    }

    // MARK: - Export

    /// Prepares the package files of `ids` for the share sheet. Entries
    /// without a package file are skipped and counted; when none can be
    /// exported the failure is announced instead.
    func export(_ ids: [ApplicationRecordIdentifier]) async {
        guard let exporter, progress == nil, exportBundle == nil else { return }
        let entries = ids.compactMap { index.entry(for: $0) }
        guard !entries.isEmpty else { return }
        progress = Progress(title: "Preparing Export", completed: 0, total: entries.count)
        defer { progress = nil }
        do {
            let bundle = try await Task.detached(priority: .userInitiated) { () throws -> LibraryExportBundle in
                exporter.discardAll()
                return try exporter.prepare(entries)
            }.value
            exportBundle = bundle
            if bundle.skippedCount > 0 {
                confirm("\(Self.applicationCount(bundle.skippedCount)) skipped — package file missing or changed")
            }
        } catch {
            notice = Notice(title: Self.exportFailureTitle, message: Self.failureMessage(for: error))
        }
    }

    /// Discards the prepared files once the share sheet has closed.
    func finishExport() {
        guard let bundle = exportBundle else { return }
        exportBundle = nil
        exporter?.discard(bundle)
    }

    // MARK: - Bulk removal

    /// Removes the entries in `ids` that the library holds.
    func delete(_ ids: [ApplicationRecordIdentifier]) async {
        await removeEntries(ids.compactMap { index.entry(for: $0) })
    }

    /// Removes the entries the user selected, one at a time, each through
    /// the same removal the single-row flow uses — record first, then
    /// artifact. The selection the user confirmed is removed as completely
    /// as persistence allows; a failure partway is announced once, naming
    /// the outcome, and the re-read shows what remains. While the removal
    /// runs, `isRemovingSelection` is set so the view disables its controls.
    /// Collections forget the removed entries afterwards.
    func removeEntries(_ entries: [LibraryEntry]) async {
        guard !entries.isEmpty, !isRemovingSelection, case .loaded = phase else { return }
        isRemovingSelection = true
        defer { isRemovingSelection = false }
        var failures = 0
        for entry in entries {
            do {
                try await library.remove(recordWithID: entry.record.id)
                forgetDerivedData(for: entry)
            } catch {
                failures += 1
            }
        }
        if failures > 0 {
            let total = entries.count
            notice = Notice(
                title: Self.removalFailureTitle,
                message: failures == total
                    ? "None of the selected applications could be deleted."
                    : "\(failures) of \(total) selected applications could not be deleted."
            )
        }
        await refresh()
        await forgetEntriesNoLongerHeld(entries)
        if failures == 0 && entries.count > 1 {
            confirm("Deleted \(Self.applicationCount(entries.count))")
        }
    }

    // MARK: - Removal

    /// Removes a library entry: its record and the package file behind it.
    ///
    /// The user has already confirmed the removal in the view; this
    /// coordinates the effect. The library use case owns the persistence and
    /// artifact-ownership rules — the model only invokes it and then re-reads
    /// the library, so the screen always reflects persistence. On failure
    /// the error is announced and the re-read shows what the library
    /// actually holds; nothing is silently dropped.
    ///
    /// While the removal runs, `removingRecordID` names the entry. One
    /// removal runs at a time.
    func remove(_ entry: LibraryEntry) async {
        guard removingRecordID == nil, case .loaded = phase else { return }
        removingRecordID = entry.record.id
        defer { removingRecordID = nil }
        do {
            try await library.remove(recordWithID: entry.record.id)
            forgetDerivedData(for: entry)
        } catch {
            notice = Notice(
                title: Self.removalFailureTitle,
                message: Self.failureMessage(for: error)
            )
        }
        await refresh()
        await forgetEntriesNoLongerHeld([entry])
    }

    /// After a removal and re-read, drops every reference the organization
    /// and the provenance cache hold to entries the library no longer holds.
    /// Entries still held — a removal that failed — keep their collections.
    private func forgetEntriesNoLongerHeld(_ requested: [LibraryEntry]) async {
        let gone = requested.filter { index.entry(for: $0.record.id) == nil }
        guard !gone.isEmpty else { return }
        if let organizer, let updated = try? await organizer.forget(Set(gone.map { $0.record.id })) {
            applyOrganization(updated)
        }
        await provenanceSource?.forget(Set(gone.map { $0.record.artifact.artifactID }))
    }

    // MARK: - Import integration

    /// Reacts to imports that settled since the last look.
    ///
    /// A package that reached the library re-reads the list, so the new
    /// record appears without any manual editing, and announces it. A
    /// package that did not says why, and leaves the list exactly as it is —
    /// a refused or failed import changed nothing, so the screen must not
    /// suggest otherwise. A cancellation is silent: the user withdrew the
    /// request, and there is nothing to report.
    private func handleSettledImports(_ settled: [(ImportJobIdentifier, ImportSettlement)]) {
        for (id, settlement) in settled {
            guard announcedImportJobs.insert(id).inserted else { continue }
            switch settlement.kind {
            case .imported, .keptBoth, .replaced, .alreadyHeld:
                notice = Notice(
                    title: Self.importSuccessTitle,
                    message: ImportQueueRendering.message(for: settlement)
                )
                Task { await refresh() }
            case .rejected, .failed:
                notice = Notice(
                    title: Self.importFailureTitle,
                    message: ImportQueueRendering.message(for: settlement)
                )
            case .cancelled, .skipped:
                break
            }
        }
        // An item that was removed or retried is no longer settled; pruning
        // the marks to what is settled now lets a retried item announce its
        // new outcome.
        announcedImportJobs.formIntersection(Set(settled.map(\.0)))
    }

    /// Clears the announcement once the user has acknowledged it.
    func clearNotice() {
        notice = nil
    }

    /// Clears the confirmation once it has been shown.
    func clearConfirmation() {
        confirmation = nil
    }

    private func confirm(_ message: String) {
        confirmation = Confirmation(message: message)
    }

    // MARK: - Rendering

    /// "1 app" or "N apps". Not isolated, so any view can phrase a count.
    nonisolated static func applicationCount(_ count: Int) -> String {
        count == 1 ? "1 app" : "\(count) apps"
    }

    /// The user-presentable message for a failure. A typed error's own
    /// user-facing text carries no diagnostic detail; a foreign error is
    /// reduced to a fixed explanation and is never rendered verbatim.
    static func failureMessage(for error: any Error) -> String {
        if let zynSignError = error as? ZynSignError {
            return zynSignError.userMessage
        }
        return "The library could not be accessed."
    }

    private static let importSuccessTitle = "Import Complete"
    private static let importFailureTitle = "Import Failed"
    private static let removalFailureTitle = "Deletion Failed"
    private static let refreshFailureTitle = "Refresh Failed"
    private static let favoriteFailureTitle = "Favourite Could Not Be Saved"
    private static let collectionsFailureTitle = "Collections Unavailable"
    private static let exportFailureTitle = "Export Failed"
    private static let organizationUnavailableMessage = "Collections are not available in this build."
}
