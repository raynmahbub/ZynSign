import Foundation
import Combine

/// The presentation-side state machine for the Applications Library screen.
///
/// The model carries exactly one content phase at a time — loading, loaded,
/// empty, or failed — so the screen can never show an empty library while
/// records are still being read, and never silently drops a persistence
/// failure. Removal and import are part of the same machine: while a
/// deletion runs, the entry being removed is named so the view can mark it;
/// a settled import re-reads the library so the new record appears without
/// any manual list editing.
///
/// The model coordinates nothing itself: it invokes the application-layer
/// library use case and observes the shared Import Hub, and renders the
/// outcomes. Persistence and file work run off the main actor inside the use
/// case; every phase transition happens here, on the main actor. The list is
/// never edited in place — after every change the model re-reads the library
/// from persistence, so what the screen shows is what the library holds.
///
/// The Import Hub is observed, not driven. The Library does not present a
/// picker, run an import, or track its progress — the shell's Import Hub
/// does all of that — so this model only notices that an import settled, and
/// reacts the way the screen should: a package that reached the library
/// re-reads the list, a package that did not says so without disturbing the
/// list, and a cancellation or a skip says nothing at all.
@MainActor
final class ApplicationLibraryModel: ObservableObject {

    /// How the library orders its entries.
    enum SortOrder: String, CaseIterable, Identifiable {

        /// Most recently imported first — the library's own order, reversed.
        case recentlyImported

        /// By declared display name, the way a Contacts list sorts.
        case name

        /// By declared version, then build, so the newest declared release
        /// of each application floats up.
        case version

        var id: Self { self }

        /// The user-presentable name, shown in the sort menu.
        var displayName: String {
            switch self {
            case .recentlyImported: return "Recently Imported"
            case .name: return "Name"
            case .version: return "Version"
            }
        }
    }

    /// The signing state one entry's card shows, derived from the on-device
    /// signing journal and the artifact's availability.
    ///
    /// "Signed" means the journal records successful signing output for the
    /// application's bundle identifier. "Package Problem" means the artifact
    /// is missing or no longer matches the record. Anything else reads as
    /// not signed — ZynSign holds no signed output for the application.
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

    /// The current content phase of the library.
    @Published private(set) var phase: Phase = .loading

    /// The search text the list filters on. Matching is by declared name,
    /// bundle identifier, and the source file name the import recorded.
    @Published var searchText = ""

    /// The order the library is listed in.
    @Published var sortOrder: SortOrder = .recentlyImported

    /// The bundle identifiers the signing journal records successful output
    /// for, as observed at the last read. An entry whose declared bundle
    /// identifier is in this set shows as signed.
    @Published private(set) var signedBundleIdentifiers: Set<String> = []

    /// Whether a bulk removal is running. One removal runs at a time; the
    /// view disables its destructive controls while this is set.
    @Published private(set) var isRemovingSelection = false


    /// The record whose removal is running, so the view can mark the entry.
    /// `nil` whenever no removal is running.
    @Published private(set) var removingRecordID: ApplicationRecordIdentifier?

    /// The announcement to show, if any. Cleared by `clearNotice()` once the
    /// user has acknowledged it.
    @Published private(set) var notice: Notice?

    private let library: ApplicationLibrary
    private let hub: ImportHub
    private let signingHistory: (any SigningHistoryStore)?
    private var isReadingLibrary = false
    private var hasPendingRead = false

    /// The subscriptions that keep this model following the Import Hub.
    private var cancellables: Set<AnyCancellable> = []

    /// The imports whose outcome has already been announced, so a settle is
    /// reported once and not again on every later change to the job list.
    private var announcedImportJobs: Set<ImportJobIdentifier> = []

    /// Creates the model over the library use case and the shared Import
    /// Hub, which it observes. The signing journal is optional and
    /// read-only; `nil` simply means no entry can show a signed state.
    init(
        library: ApplicationLibrary,
        hub: ImportHub,
        signingHistory: (any SigningHistoryStore)? = nil
    ) {
        self.library = library
        self.hub = hub
        self.signingHistory = signingHistory

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

        // Anything the hub settled before this model existed still has to
        // be acted on, so the current state is applied once at creation.
        handleSettledImports(hub.items.compactMap { item in item.settlement.map { (item.id, $0) } })
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
                let entries = try await library.entries()
                phase = entries.isEmpty ? .empty : .loaded(entries)
                await readSigningState()
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

    // MARK: - Filtering and ordering

    /// The entries the screen shows for the current search text and sort
    /// order. The library phase is never edited in place — the visible list
    /// is this projection of it, recomputed on every change of text or
    /// order, so what the screen shows always descends from persistence.
    func visibleEntries() -> [LibraryEntry] {
        guard case .loaded(let entries) = phase else { return [] }
        return Self.displayed(entries, matching: searchText, sortedBy: sortOrder)
    }

    /// Whether `entry` matches `query`: a match is a case-insensitive
    /// substring of the declared display name, the bundle identifier, or
    /// the recorded source file name. An empty query matches everything.
    /// Internal so the rule is testable without views.
    static func matches(_ entry: LibraryEntry, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let record = entry.record
        let haystacks = [
            record.displayName ?? "",
            record.bundleIdentifier.rawValue,
            record.sourceFileName ?? "",
        ]
        return haystacks.contains { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Orders `entries` by `order`, most preferred first. Name order uses
    /// the same deterministic fallback the row shows (unnamed entries sort
    /// by bundle identifier); version order compares declared version and
    /// build the way people read them, with the library order breaking ties
    /// so the result is always stable.
    static func ordered(_ entries: [LibraryEntry], by order: SortOrder) -> [LibraryEntry] {
        switch order {
        case .recentlyImported:
            return entries.sorted { lhs, rhs in
                if lhs.record.importedAt != rhs.record.importedAt {
                    return lhs.record.importedAt > rhs.record.importedAt
                }
                // Ties break by the library's own stable order.
                return ApplicationRecord.libraryOrder(lhs.record, rhs.record)
            }
        case .name:
            return entries.sorted { lhs, rhs in
                let lhsName = lhs.record.displayName ?? lhs.record.bundleIdentifier.rawValue
                let rhsName = rhs.record.displayName ?? rhs.record.bundleIdentifier.rawValue
                if lhsName.caseInsensitiveCompare(rhsName) != .orderedSame {
                    return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
                }
                return lhs.record.bundleIdentifier.rawValue < rhs.record.bundleIdentifier.rawValue
            }
        case .version:
            return entries.sorted { lhs, rhs in
                let lhsVersion = declaredVersion(lhs.record)
                let rhsVersion = declaredVersion(rhs.record)
                if lhsVersion != rhsVersion {
                    return lhsVersion.localizedStandardCompare(rhsVersion) == .orderedDescending
                }
                return ApplicationRecord.libraryOrder(lhs.record, rhs.record)
            }
        }
    }

    /// The filtered, ordered list the screen shows for a query and order.
    static func displayed(_ entries: [LibraryEntry], matching query: String, sortedBy order: SortOrder) -> [LibraryEntry] {
        ordered(entries.filter { matches($0, query: query) }, by: order)
    }

    /// The declared version a record sorts and displays by: the marketing
    /// version when declared, otherwise the build, otherwise the empty
    /// string — undeclared versions sort last without inventing a value.
    private static func declaredVersion(_ record: ApplicationRecord) -> String {
        record.identity.shortVersionString
            ?? record.identity.buildVersion
            ?? ""
    }

    // MARK: - Signing state

    /// The signing state an entry's card shows, derived at render time from
    /// the artifact's availability and the signing journal observed at the
    /// last read.
    func signingState(for entry: LibraryEntry) -> SigningState {
        if !entry.isArtifactAvailable {
            return .packageProblem
        }
        if signedBundleIdentifiers.contains(entry.record.bundleIdentifier.rawValue) {
            return .signed
        }
        return .notSigned
    }

    /// Re-reads the signing journal. A journal read failure leaves the
    /// previous observation standing — the journal is a convenience view of
    /// history, and a failed read must not turn entries unsigned.
    private func readSigningState() async {
        guard let signingHistory else {
            signedBundleIdentifiers = []
            return
        }
        if let records = try? await signingHistory.allRecords() {
            signedBundleIdentifiers = Set(
                records
                    .filter { $0.outcome == .succeeded }
                    .compactMap { $0.sourceBundleIdentifier }
            )
        }
    }

    // MARK: - Favourites

    /// Marks or unmarks an entry as a favourite, then re-reads the library
    /// so the screen reflects persistence. A failure is announced; the
    /// re-read shows what the library actually holds.
    func setFavorite(_ isFavorite: Bool, on entry: LibraryEntry) async {
        do {
            try await library.setFavorite(isFavorite, recordWithID: entry.record.id)
        } catch {
            notice = Notice(
                title: Self.favoriteFailureTitle,
                message: Self.failureMessage(for: error)
            )
        }
        await refresh()
    }

    // MARK: - Bulk removal

    /// Removes the entries the user selected, one at a time, each through
    /// the same removal the single-row flow uses — record first, then
    /// artifact. The selection the user confirmed is removed as completely
    /// as persistence allows; a failure partway is announced once, naming
    /// the outcome, and the re-read shows what remains. While the removal
    /// runs, `isRemovingSelection` is set so the view disables its controls.
    func removeEntries(_ entries: [LibraryEntry]) async {
        guard !entries.isEmpty, !isRemovingSelection, case .loaded = phase else { return }
        isRemovingSelection = true
        defer { isRemovingSelection = false }
        var failures = 0
        for entry in entries {
            do {
                try await library.remove(recordWithID: entry.record.id)
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
        } catch {
            notice = Notice(
                title: Self.removalFailureTitle,
                message: Self.failureMessage(for: error)
            )
        }
        await refresh()
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

    // MARK: - Rendering

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
}
