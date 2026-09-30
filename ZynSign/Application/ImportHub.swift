import Foundation
import Combine

/// The Smart Import Hub: the one place every import goes.
///
/// Every entry point — the Files picker, the share sheet, Open In, drag and
/// drop, multi-file selection — hands its files to `receive(_:origin:)`.
/// From there each file becomes an *item* that moves through the same
/// stages on its own:
///
/// ```
/// Waiting → Preparing → Validating → Analyzing → (preview) → Importing → Complete
///                                                                      ↘ Failed
/// ```
///
/// - **Preparing** checks the file and makes ZynSign's own working copy;
///   the original is only ever read.
/// - **Validating** classifies the copy. A ZIP holding packages pauses for
///   the user's choice of what to extract; an archive with unsafe or
///   duplicated entries, a corrupted file, or an unsupported layout is
///   refused with an explanation.
/// - **Analyzing** reads the icon, identity, signing state, and contents,
///   and compares the package with the library.
/// - The analyzed package waits in the **preview** until the user imports
///   it. Conflicts with the library are collected there — never asked one
///   at a time mid-import — and must each be resolved (Keep Both, Replace
///   Existing, or Skip) before the package can be stored.
/// - **Importing** stores confirmed packages one at a time, so the library's
///   serialized admission is never raced.
///
/// Up to `maximumConcurrentPreparations` items prepare at once and each
/// fails, retries, or is cancelled independently. Progress is delivered to
/// the main actor at a bounded rate so a large batch never floods the
/// interface.
///
/// Work continues while ZynSign is open. When ZynSign leaves the
/// foreground the hub asks the system for a finite amount of extra time;
/// if that runs out, running work pauses and resumes when ZynSign is active
/// again. Unfinished items are journaled, so after an interruption an item
/// whose working copy survived resumes, and one whose copy did not is
/// explained honestly rather than silently dropped.
@MainActor
final class ImportHub: ObservableObject {

    // MARK: - Items

    /// One file (or archive entry) moving through the hub.
    struct Item: Identifiable, Equatable {

        /// Where an item is in its life.
        enum Phase: Equatable {
            /// Queued; not started yet, or paused and waiting to resume.
            case waiting
            /// Checking the file and making the working copy.
            case preparing
            /// Classifying and validating the working copy.
            case validating
            /// Analyzing the package and comparing it with the library.
            case analyzing
            /// An archive of packages, waiting for the user to choose which
            /// to extract.
            case awaitingSelection([NestedPackageCandidate])
            /// Analyzed; waiting in the preview for the user's decision.
            case ready
            /// Confirmed by the user; waiting its turn to be stored.
            case queuedForImport
            /// Being stored in the library.
            case importing
            /// Finished, with the outcome.
            case settled(ImportSettlement)
            /// An archive whose chosen packages became their own items.
            case unpacked(Int)
        }

        /// Where the item's bytes come from.
        enum Source: Equatable {
            /// A document the user handed to ZynSign. Only ever read.
            case document(URL)
            /// A package inside an archive another item holds.
            case archiveEntry(container: ImportJobIdentifier, candidate: NestedPackageCandidate)
            /// Restored after an interruption, from its surviving working
            /// copy. There is no way back to the original file.
            case recovered
            /// A dropped item that could not be received as a file. It is
            /// listed so the drop is accounted for, and never runs.
            case unreceived
        }

        /// A remark about the item's relation to other items in the hub.
        enum Note: Equatable {
            /// Another item holds byte-identical content.
            case sameContent(as: String)
            /// Another item is a different package of the same application.
            case sameApplication(as: String)
        }

        let id: ImportJobIdentifier
        let batchID: ImportBatchIdentifier
        let origin: ImportOrigin
        let fileName: String
        let enqueuedAt: Date
        let source: Source
        /// The archive the item was extracted from, for display.
        let containerFileName: String?

        fileprivate(set) var phase: Phase {
            didSet { recordFurthestStage() }
        }
        /// The furthest stage of the track the item reached — where a failed
        /// item stopped.
        fileprivate(set) var furthestStage: ImportQueueStage = .waiting
        fileprivate(set) var progress: ImportProgress?
        fileprivate(set) var fractionCompleted: Double = 0
        fileprivate(set) var estimate = ImportRemainingEstimate(remainingSteps: 4, remainingBytes: nil, remainingSeconds: nil)
        fileprivate(set) var staged: StagedImport?
        fileprivate(set) var prepared: PreparedImport?
        fileprivate(set) var isSelected = false
        fileprivate(set) var resolution: ConflictResolution?
        fileprivate(set) var note: Note?
        fileprivate(set) var attempt = 0
        fileprivate(set) var startedAt: Date?
        fileprivate(set) var transferStartedAt: Date?
        fileprivate(set) var settledAt: Date?
        fileprivate(set) var lastKnownByteCount: Int?

        /// The working copy an attempt is writing, known before the copy
        /// completes so a launch-time sweep never removes it.
        fileprivate(set) var pendingArtifactID: ArtifactIdentifier?

        /// The stage the queue shows.
        var stage: ImportQueueStage {
            switch phase {
            case .waiting, .queuedForImport: return .waiting
            case .preparing: return .preparing
            case .validating: return .validating
            case .analyzing, .awaitingSelection, .ready: return .analyzing
            case .importing: return .importing
            case .unpacked: return .complete
            case .settled(let settlement):
                switch settlement.kind.bucket {
                case .failed: return .failed
                case .imported, .replaced, .skipped: return .complete
                }
            }
        }

        /// The outcome, once the item has settled. An unpacked archive has
        /// none of its own: its packages each settle separately.
        var settlement: ImportSettlement? {
            if case .settled(let settlement) = phase { return settlement }
            return nil
        }

        /// Whether the item is preparing: copying, validating, or analyzing.
        var isPreparing: Bool {
            switch phase {
            case .preparing, .validating, .analyzing: return true
            default: return false
            }
        }

        /// Whether the item still has work ahead that runs without the user.
        var isActive: Bool {
            switch phase {
            case .waiting, .preparing, .validating, .analyzing, .queuedForImport, .importing: return true
            default: return false
            }
        }

        /// Whether the item is finished.
        var isFinished: Bool {
            switch phase {
            case .settled, .unpacked: return true
            default: return false
            }
        }

        /// Whether the item waits for the user in the preview.
        var isReady: Bool {
            phase == .ready
        }

        /// Whether the item is an archive waiting for the user's choice.
        var isAwaitingSelection: Bool {
            if case .awaitingSelection = phase { return true }
            return false
        }

        /// Whether cancelling the item is possible now. Storing cannot be
        /// interrupted once it has begun.
        var canCancel: Bool {
            switch phase {
            case .waiting, .preparing, .validating, .analyzing, .awaitingSelection, .ready, .queuedForImport:
                return true
            case .importing, .settled, .unpacked:
                return false
            }
        }

        /// The conflict the item raises against the library, if any.
        var conflict: ImportConflict? {
            prepared?.conflict
        }

        /// Whether the item is selected for import but has an unresolved
        /// conflict, which blocks importing.
        var needsResolution: Bool {
            isReady && isSelected && conflict != nil && resolution == nil
        }

        /// The identity the package declares, once analyzed.
        var identity: ApplicationIdentity? {
            prepared?.identity ?? settlement?.record?.identity
        }

        /// The best-known size of the item's package.
        var byteCount: Int? {
            prepared?.byteCount ?? staged?.byteCount ?? lastKnownByteCount
        }

        private mutating func recordFurthestStage() {
            let current = stage
            guard !current.isTerminal,
                  let reached = ImportQueueStage.track.firstIndex(of: current),
                  let previous = ImportQueueStage.track.firstIndex(of: furthestStage) else { return }
            if reached > previous || phase == .waiting {
                furthestStage = current
            }
        }

        /// Whether the item's outcome is one a retry could change.
        fileprivate var hasRetryableOutcome: Bool {
            guard let settlement else { return false }
            switch settlement.kind {
            case .failed, .rejected, .cancelled: return true
            case .imported, .keptBoth, .replaced, .alreadyHeld, .skipped: return false
            }
        }
    }

    // MARK: - Published state

    /// Every item, in arrival order; packages extracted from an archive
    /// follow the archive.
    @Published private(set) var items: [Item] = []

    /// How many dropped files are still being received into the inbox.
    @Published private(set) var receivingDropCount = 0

    /// Whether running work is paused because the system's background time
    /// ran out. Cleared by `resume()` when ZynSign is active again.
    @Published private(set) var isPaused = false

    /// The import history, newest first, once loaded.
    @Published private(set) var history: [ImportHistoryEntry] = []

    /// Whether the history could not be read.
    @Published private(set) var historyUnavailable = false

    /// The most recently finished batch, for announcing completion.
    @Published private(set) var lastFinishedBatch: ImportHistoryEntry?

    // MARK: - Dependencies and bookkeeping

    /// The maximum number of items that prepare at the same time.
    let maximumConcurrentPreparations: Int

    private let processing: any ImportProcessing
    private let historyStore: (any ImportHistoryStore)?
    private let recoveryJournal: (any ImportRecoveryJournal)?
    private let backgroundExecution: (any ImportBackgroundExecution)?
    private let releaseSource: (URL) -> Void
    private let progressInterval: TimeInterval
    private let now: () -> Date

    private var tasks: [ImportJobIdentifier: Task<Void, Never>] = [:]
    private var commitTask: Task<Void, Never>?
    private var backgroundActivity: ImportBackgroundActivity?
    /// Which attempt of an item the system's expiry interrupted, by item.
    ///
    /// The attempt is part of the record on purpose: a preparation that ends
    /// after the interruption — cancellation is cooperative, so a copy can
    /// finish before it is noticed — must not make a *later* attempt's
    /// failure look like an interruption too. That misreading sent the item
    /// back to `waiting` and swallowed the error it had just reported.
    private var pausedByExpiration: [ImportJobIdentifier: Int] = [:]
    private var isRestoring = false
    private var hasRestored = false
    private var historyLoaded = false
    private var recordedBatches: Set<ImportBatchIdentifier> = []
    private var openBatch: (id: ImportBatchIdentifier, origin: ImportOrigin, lastArrival: Date)?
    private var journalNeedsWrite = false
    private var journalWriter: Task<Void, Never>?
    private var historyWriter: Task<Void, Never>?

    /// Arrivals from the share sheet or Open In within this interval of
    /// each other join the same batch: the system delivers a multi-file
    /// hand-off one file at a time.
    static let batchCoalescingInterval: TimeInterval = 2

    /// The most history entries kept in memory; the store keeps its own
    /// bound.
    static let historyCapacity = 100

    /// Creates the hub over the per-item workflow and the platform
    /// capabilities the composition root chose. Every capability is
    /// optional so tests and previews can leave out what they do not
    /// exercise; `now` and `progressInterval` are injectable for
    /// deterministic tests.
    ///
    /// The initializer is `nonisolated` because the composition root builds
    /// the hub while wiring the application environment, which is not a
    /// main-actor context. It only stores what it is given; every mutation
    /// of the hub's state after construction happens on the main actor.
    nonisolated init(
        processing: any ImportProcessing,
        history: (any ImportHistoryStore)? = nil,
        recoveryJournal: (any ImportRecoveryJournal)? = nil,
        backgroundExecution: (any ImportBackgroundExecution)? = nil,
        releaseSource: @escaping (URL) -> Void = { _ in },
        maximumConcurrentPreparations: Int = 2,
        progressInterval: TimeInterval = 0.1,
        now: @escaping () -> Date = { Date() }
    ) {
        self.processing = processing
        self.historyStore = history
        self.recoveryJournal = recoveryJournal
        self.backgroundExecution = backgroundExecution
        self.releaseSource = releaseSource
        self.maximumConcurrentPreparations = max(1, maximumConcurrentPreparations)
        self.progressInterval = max(0, progressInterval)
        self.now = now
    }

    // MARK: - Receiving

    /// Hands files to the hub. This is the single entry point for every
    /// way a file can arrive.
    ///
    /// Each file becomes its own item and starts as soon as a preparation
    /// slot is free. Non-file URLs are ignored. Returns the new items'
    /// identifiers, in order.
    @discardableResult
    func receive(_ urls: [URL], origin: ImportOrigin) -> [ImportJobIdentifier] {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return [] }

        let arrival = now()
        let batchID = self.batch(for: origin, at: arrival)
        let newItems = files.map { url in
            Item(
                id: ImportJobIdentifier(),
                batchID: batchID,
                origin: origin,
                fileName: url.lastPathComponent,
                enqueuedAt: arrival,
                source: .document(url),
                containerFileName: nil,
                phase: .waiting
            )
        }
        items.append(contentsOf: newItems)
        recordedBatches.remove(batchID)
        pump()
        return newItems.map(\.id)
    }

    /// Notes that `count` dropped files are being received, so the hub can
    /// show them before they arrive.
    func beginReceivingDrop(count: Int) {
        receivingDropCount += max(0, count)
    }

    /// Notes that `count` dropped files have been received or failed.
    func endReceivingDrop(count: Int) {
        receivingDropCount = max(0, receivingDropCount - max(0, count))
    }

    /// Lists dropped items that could not be received as files, so a drop
    /// is always accounted for rather than silently shrinking.
    func recordUnreceivedDrops(_ count: Int) {
        guard count > 0 else { return }
        let arrival = now()
        let batch = ImportBatchIdentifier()
        let failure = ImportFailure(
            title: "Couldn't Receive Item",
            message: "This dropped item couldn't be read as a file, so nothing was imported from it.",
            recovery: .chooseAnotherFile,
            isRetryable: false,
            category: .invalidInput
        )
        for _ in 0..<count {
            var item = Item(
                id: ImportJobIdentifier(),
                batchID: batch,
                origin: .dragAndDrop,
                fileName: "Dropped item",
                enqueuedAt: arrival,
                source: .unreceived,
                containerFileName: nil,
                phase: .settled(ImportSettlement(kind: .rejected, failure: failure))
            )
            item.settledAt = arrival
            item.fractionCompleted = 1
            item.estimate = Self.estimate(for: .failed)
            items.append(item)
        }
        pump()
    }

    private func batch(for origin: ImportOrigin, at arrival: Date) -> ImportBatchIdentifier {
        let coalesces = origin == .shareSheet || origin == .openIn
        if coalesces,
           let open = openBatch,
           open.origin == origin,
           arrival.timeIntervalSince(open.lastArrival) <= Self.batchCoalescingInterval,
           items.contains(where: { $0.batchID == open.id && !$0.isFinished }) {
            openBatch = (open.id, origin, arrival)
            return open.id
        }
        let batch = ImportBatchIdentifier()
        openBatch = coalesces ? (batch, origin, arrival) : nil
        return batch
    }

    // MARK: - Queue control

    /// Cancels an item. Its working copy is discarded and the original
    /// file is untouched. An item that has begun storing cannot be
    /// cancelled.
    func cancel(_ id: ImportJobIdentifier) {
        guard let index = self.index(of: id), items[index].canCancel else { return }
        tasks[id]?.cancel()
        tasks[id] = nil
        discardWorkingCopies(of: index)
        settle(at: index, with: .cancelled())
        pump()
    }

    /// Cancels every item that can still be cancelled.
    func cancelAll() {
        for id in items.filter(\.canCancel).map(\.id) {
            cancel(id)
        }
    }

    /// Whether `id` can be attempted again: it failed, was refused, or was
    /// cancelled, and the hub can still reach what it came from.
    func canRetry(_ id: ImportJobIdentifier) -> Bool {
        guard let item = items.first(where: { $0.id == id }), item.hasRetryableOutcome else { return false }
        switch item.source {
        case .document:
            return true
        case .archiveEntry(let containerID, _):
            return items.first(where: { $0.id == containerID })?.staged != nil
        case .recovered, .unreceived:
            return false
        }
    }

    /// Attempts an item again, from the beginning, with a fresh working
    /// copy.
    func retry(_ id: ImportJobIdentifier) {
        guard canRetry(id), let index = self.index(of: id) else { return }
        items[index].attempt += 1
        items[index].phase = .waiting
        items[index].progress = nil
        items[index].fractionCompleted = 0
        items[index].estimate = Self.estimate(for: .waiting)
        items[index].staged = nil
        items[index].prepared = nil
        items[index].isSelected = false
        items[index].resolution = nil
        items[index].note = nil
        items[index].startedAt = nil
        items[index].transferStartedAt = nil
        items[index].settledAt = nil
        items[index].pendingArtifactID = nil
        recordedBatches.remove(items[index].batchID)
        pump()
    }

    /// Attempts every retryable item again.
    func retryAllFailed() {
        for id in items.map(\.id) where canRetry(id) {
            retry(id)
        }
    }

    /// Removes an item from the hub, cancelling it first if it is still
    /// running. An item that is being stored is left to finish.
    func remove(_ id: ImportJobIdentifier) {
        guard let index = self.index(of: id) else { return }
        if items[index].canCancel {
            cancel(id)
        }
        guard let current = self.index(of: id), items[current].isFinished else { return }
        let removed = items.remove(at: current)
        forget(removed)
        scheduleJournalWrite()
    }

    /// Removes every finished item.
    func clearFinished() {
        let finished = items.filter { item in
            guard item.isFinished else { return false }
            // An archive stays while any of its packages is unfinished.
            if case .unpacked = item.phase {
                return !items.contains { child in
                    if case .archiveEntry(let container, _) = child.source {
                        return container == item.id && !child.isFinished
                    }
                    return false
                }
            }
            return true
        }
        let identifiers = Set(finished.map(\.id))
        items.removeAll { identifiers.contains($0.id) }
        for item in finished {
            forget(item)
        }
        scheduleJournalWrite()
    }

    private func forget(_ item: Item) {
        if let staged = item.staged {
            processing.discardWorkingCopy(staged.artifactID)
        }
        if case .document(let url) = item.source {
            releaseSource(url)
        }
    }

    // MARK: - Archives

    /// Extracts the chosen packages from an archive item. Each becomes its
    /// own item, in its own isolated working copy.
    func extract(_ candidates: [NestedPackageCandidate], from containerID: ImportJobIdentifier) {
        guard let index = self.index(of: containerID),
              case .awaitingSelection(let offered) = items[index].phase else { return }
        let chosen = candidates.filter { offered.contains($0) }
        guard !chosen.isEmpty else { return }

        let container = items[index]
        let arrival = now()
        let children = chosen.map { candidate in
            Item(
                id: ImportJobIdentifier(),
                batchID: container.batchID,
                origin: container.origin,
                fileName: candidate.fileName,
                enqueuedAt: arrival,
                source: .archiveEntry(container: container.id, candidate: candidate),
                containerFileName: container.fileName,
                phase: .waiting
            )
        }
        items[index].phase = .unpacked(children.count)
        items[index].fractionCompleted = 1
        items.insert(contentsOf: children, at: index + 1)
        pump()
    }

    /// Declines an archive: nothing is extracted and its working copy is
    /// discarded.
    func declineArchive(_ containerID: ImportJobIdentifier) {
        guard let index = self.index(of: containerID), items[index].isAwaitingSelection else { return }
        discardWorkingCopies(of: index)
        settle(at: index, with: .skipped())
        pump()
    }

    // MARK: - Preview

    /// Includes or excludes a ready item from the next import.
    func setSelected(_ isSelected: Bool, for id: ImportJobIdentifier) {
        guard let index = self.index(of: id), items[index].isReady else { return }
        items[index].isSelected = isSelected
    }

    /// Includes every ready item.
    func selectAllReady() {
        for index in items.indices where items[index].isReady {
            items[index].isSelected = true
        }
    }

    /// Excludes every ready item.
    func deselectAllReady() {
        for index in items.indices where items[index].isReady {
            items[index].isSelected = false
        }
    }

    /// Items waiting in the preview.
    var readyItems: [Item] {
        items.filter(\.isReady)
    }

    /// Ready items selected for import.
    var selectedReadyItems: [Item] {
        items.filter { $0.isReady && $0.isSelected }
    }

    /// Whether `importSelected()` would import anything now.
    var canImportSelected: Bool {
        let selected = selectedReadyItems
        return !selected.isEmpty && !selected.contains(where: \.needsResolution)
    }

    /// Imports every selected ready item and skips every deselected one.
    ///
    /// Only items that are ready at this moment are affected; items still
    /// preparing keep going and wait in the preview when they are done.
    /// Nothing happens while a selected item has an unresolved conflict.
    func importSelected() {
        guard canImportSelected else { return }
        for index in items.indices where items[index].isReady {
            if items[index].isSelected {
                items[index].phase = .queuedForImport
                items[index].estimate = Self.estimate(for: .waiting)
            } else {
                discardWorkingCopies(of: index)
                settle(at: index, with: .skipped(), pumping: false)
            }
        }
        pump()
    }

    // MARK: - Conflicts

    /// Ready items with a conflict against the library, selected or not.
    var conflictItems: [Item] {
        items.filter { $0.isReady && $0.conflict != nil }
    }

    /// How many selected items still need a resolution.
    var unresolvedConflictCount: Int {
        items.filter(\.needsResolution).count
    }

    /// Records the user's resolution for one conflict.
    func resolve(_ id: ImportJobIdentifier, with resolution: ConflictResolution?) {
        guard let index = self.index(of: id), items[index].isReady, items[index].conflict != nil else { return }
        items[index].resolution = resolution
    }

    /// Applies one resolution to every selected conflict.
    func applyToAllConflicts(_ resolution: ConflictResolution) {
        for index in items.indices where items[index].isReady && items[index].isSelected && items[index].conflict != nil {
            items[index].resolution = resolution
        }
    }

    /// Applies the rules' suggestion to every selected conflict that has
    /// one. Conflicts without a suggestion are left for the user.
    func applySuggestions() {
        for index in items.indices where items[index].isReady && items[index].isSelected {
            if let suggestion = items[index].conflict?.suggestion {
                items[index].resolution = suggestion
            }
        }
    }

    // MARK: - Summary

    /// Counts of what the hub holds, for its summary.
    var summary: ImportSummary {
        let counted = items.filter { item in
            if case .unpacked = item.phase { return false }
            return true
        }
        return ImportSummary(
            settlements: counted.compactMap(\.settlement),
            scheduledCount: counted.count,
            byteCount: counted.compactMap(\.byteCount).reduce(0) { total, bytes in
                let (sum, overflow) = total.addingReportingOverflow(bytes)
                return overflow ? Int.max : sum
            }
        )
    }

    /// Whether any item is still working without the user.
    var isBusy: Bool {
        items.contains(where: \.isActive)
    }

    /// The free space available for working copies, when known.
    func availableCapacity() -> Int? {
        processing.availableCapacity()
    }

    // MARK: - History

    /// Loads the import history from storage, once.
    func loadHistory() async {
        guard !historyLoaded, let historyStore else { return }
        historyLoaded = true
        do {
            let stored = try await historyStore.allEntries()
            // Entries recorded in this session before the load finished
            // stay; stored entries fill in behind them.
            let known = Set(history.map(\.id))
            history = Array((history + stored.filter { !known.contains($0.id) }).prefix(Self.historyCapacity))
            historyUnavailable = false
        } catch {
            historyUnavailable = true
        }
    }

    /// Removes one history entry.
    func removeHistoryEntry(_ id: ImportBatchIdentifier) {
        history.removeAll { $0.id == id }
        guard let historyStore else { return }
        chainHistoryWrite { try await historyStore.remove(entryWithID: id) }
    }

    /// Removes every history entry.
    func clearHistory() {
        history = []
        guard let historyStore else { return }
        chainHistoryWrite { try await historyStore.clear() }
    }

    // MARK: - Lifecycle

    /// Restores items an interruption left unfinished, then removes working
    /// copies nothing will resume. Call once, when ZynSign launches.
    ///
    /// An item whose working copy survived resumes from it and passes
    /// validation and analysis again before it reaches the preview. An item
    /// without one is settled as interrupted, with an explanation: the hub
    /// never keeps a way back to the user's original file.
    func restoreInterruptedImports() async {
        guard !hasRestored else { return }
        hasRestored = true
        isRestoring = true

        let records = (try? await recoveryJournal?.pendingRecords()) ?? []
        let processing = self.processing
        var restored: [Item] = []
        for record in records where !items.contains(where: { $0.id.uuid == record.itemID }) {
            var item = Item(
                id: ImportJobIdentifier(uuid: record.itemID),
                batchID: ImportBatchIdentifier(uuid: record.batchID),
                origin: record.origin,
                fileName: record.fileName,
                enqueuedAt: record.enqueuedAt,
                source: .recovered,
                containerFileName: record.containerFileName,
                phase: .waiting
            )
            if let raw = record.stagedArtifactID,
               let artifact = ArtifactIdentifier(rawValue: raw),
               let byteCount = processing.workingCopyByteCount(artifact) {
                item.staged = StagedImport(artifactID: artifact, fileName: record.fileName, byteCount: byteCount)
                item.lastKnownByteCount = byteCount
            } else {
                let failure = ImportFailure.interrupted(hadWorkingCopy: record.stagedArtifactID != nil)
                item.phase = .settled(ImportSettlement(kind: .failed, failure: failure))
                item.settledAt = now()
                item.fractionCompleted = 1
                item.estimate = Self.estimate(for: .failed)
            }
            restored.append(item)
        }

        // Keep every working copy something still needs: restored items,
        // and anything that arrived while the journal was being read.
        var keep = Set(restored.compactMap { $0.staged?.artifactID })
        for item in items {
            if let staged = item.staged { keep.insert(staged.artifactID) }
            if let pending = item.pendingArtifactID { keep.insert(pending) }
        }
        let keptArtifacts = keep
        await Task.detached(priority: .utility) {
            processing.sweepWorkingCopies(keeping: keptArtifacts)
        }.value

        items.insert(contentsOf: restored, at: 0)
        isRestoring = false
        scheduleJournalWrite()
        pump()
    }

    /// Resumes paused work. Call when ZynSign becomes active.
    func resume() {
        guard isPaused else { return }
        isPaused = false
        pump()
    }

    /// Pauses running work because the system's extra background time ran
    /// out. Items that were preparing return to waiting — keeping a
    /// complete working copy if they had one — and resume with `resume()`.
    /// A store that has begun is left to finish.
    func backgroundTimeExpired() {
        isPaused = true
        for (id, task) in tasks {
            // Record the attempt this interruption lands on, so only that
            // attempt's failure is read as "the system stopped us".
            if let itemIndex = self.index(of: id) {
                pausedByExpiration[id] = items[itemIndex].attempt
            }
            task.cancel()
        }
        endBackgroundActivity()
    }

    // MARK: - Scheduling

    private func pump() {
        defer {
            updateBackgroundActivity()
            recordFinishedBatches()
        }
        guard !isPaused, !isRestoring else { return }

        var running = items.filter(\.isPreparing).count
        for index in items.indices where running < maximumConcurrentPreparations {
            if items[index].phase == .waiting, startPreparation(at: index) {
                running += 1
            }
        }

        if commitTask == nil, let next = items.firstIndex(where: { $0.phase == .queuedForImport }) {
            startCommit(at: next)
        }
    }

    /// Starts preparing the item at `index`. Returns `false` when the item
    /// could not start and was settled instead.
    private func startPreparation(at index: Int) -> Bool {
        let item = items[index]
        let id = item.id
        let attempt = item.attempt
        let processing = self.processing

        // Work out where the bytes come from before anything starts.
        let stagingSource: ImportStagingSource?
        switch item.source {
        case .document(let url):
            stagingSource = item.staged == nil ? .document(url) : nil
        case .archiveEntry(let containerID, let candidate):
            if item.staged != nil {
                stagingSource = nil
            } else if let containerCopy = items.first(where: { $0.id == containerID })?.staged?.artifactID {
                stagingSource = .archiveEntry(container: containerCopy, candidate: candidate)
            } else {
                settle(
                    at: index,
                    with: ImportSettlement(kind: .failed, failure: ImportFailure.from(error: ZynSignError.selectedFileUnavailable(
                        diagnosticDetail: "The archive's working copy is no longer available."
                    ))),
                    pumping: false
                )
                return false
            }
        case .recovered, .unreceived:
            stagingSource = nil
        }

        let existing = item.staged
        let artifact = ArtifactIdentifier()
        items[index].phase = existing == nil ? .preparing : .validating
        items[index].startedAt = now()
        items[index].progress = nil
        items[index].transferStartedAt = nil
        items[index].pendingArtifactID = existing == nil ? artifact : nil
        items[index].estimate = Self.estimate(for: items[index].stage)

        let relay = ProgressRelay(hub: self, id: id, attempt: attempt, interval: progressInterval)
        let fileName = item.fileName

        tasks[id] = Task { [weak self] in
            do {
                let staged: StagedImport
                if let existing {
                    staged = existing
                } else if let stagingSource {
                    staged = try await processing.stage(stagingSource, fileName: fileName, as: artifact, reporting: relay)
                } else {
                    throw ZynSignError.selectedFileUnavailable(
                        diagnosticDetail: "The item has neither a source nor a working copy."
                    )
                }
                guard let hub = self else {
                    processing.discardWorkingCopy(staged.artifactID)
                    return
                }
                guard hub.didStage(id, staged, attempt: attempt) else { return }
                let examination = try await processing.examine(staged, reporting: relay)
                self?.didExamine(id, examination, attempt: attempt)
            } catch {
                self?.didFailPreparation(id, error: error, attempt: attempt)
            }
        }
        return true
    }

    /// Records a completed working copy. Returns `false`, discarding the
    /// copy, when the item was cancelled or removed meanwhile.
    private func didStage(_ id: ImportJobIdentifier, _ staged: StagedImport, attempt: Int) -> Bool {
        guard let index = self.index(of: id, attempt: attempt), items[index].isPreparing else {
            processing.discardWorkingCopy(staged.artifactID)
            return false
        }
        items[index].staged = staged
        items[index].pendingArtifactID = nil
        items[index].lastKnownByteCount = staged.byteCount ?? items[index].lastKnownByteCount
        if items[index].phase == .preparing {
            items[index].phase = .validating
            items[index].estimate = Self.estimate(for: .validating)
        }
        scheduleJournalWrite()
        return true
    }

    private func didExamine(_ id: ImportJobIdentifier, _ examination: ImportExamination, attempt: Int) {
        tasks[id] = nil
        guard let index = self.index(of: id, attempt: attempt), items[index].isPreparing else {
            // Cancelled or removed while examining: nothing may linger.
            switch examination {
            case .package(let prepared): processing.discardWorkingCopy(prepared.artifactID)
            case .archive: break
            }
            pump()
            return
        }

        switch examination {
        case .package(let prepared):
            items[index].prepared = prepared
            items[index].lastKnownByteCount = prepared.byteCount
            items[index].phase = .ready
            items[index].isSelected = true
            items[index].fractionCompleted = max(items[index].fractionCompleted, ImportStage.storing.startingFraction)
            items[index].estimate = Self.estimate(for: .analyzing, remainingSteps: 1)
            applyBatchNotes(at: index)
        case .archive(let candidates):
            items[index].phase = .awaitingSelection(candidates)
            items[index].estimate = Self.estimate(for: .analyzing, remainingSteps: 1)
        }
        scheduleJournalWrite()
        pump()
    }

    private func didFailPreparation(_ id: ImportJobIdentifier, error: any Error, attempt: Int) {
        tasks[id] = nil
        // Consume the interruption record whatever it names: this attempt is
        // over either way, and only a record naming *this* attempt makes the
        // failure an interruption rather than a failure.
        let wasPausedByExpiration = pausedByExpiration.removeValue(forKey: id) == attempt
        guard let index = self.index(of: id, attempt: attempt), items[index].isPreparing else {
            pump()
            return
        }

        // The preparation has stopped, so the copy it may have been writing
        // can be discarded here — the one place that knows the write is over
        // and that nothing has recorded the copy. Whatever ends the attempt,
        // neither branch below uses it again.
        discardUnrecordedWorkingCopy(of: index)

        if wasPausedByExpiration {
            // The system ended the background time, not the user: back to
            // waiting, keeping a complete working copy if there is one.
            // A new attempt number keeps any report still in flight from
            // the interrupted attempt from touching the resumed one.
            items[index].attempt += 1
            items[index].phase = .waiting
            items[index].progress = nil
            items[index].pendingArtifactID = nil
            items[index].estimate = Self.estimate(for: .waiting)
            pump()
            return
        }

        discardWorkingCopies(of: index)
        settle(at: index, with: ImportSettlement.from(error: error))
        pump()
    }

    private func startCommit(at index: Int) {
        let item = items[index]
        guard let prepared = item.prepared else {
            settle(
                at: index,
                with: ImportSettlement(kind: .failed, failure: ImportFailure.from(error: ZynSignError.importUnexpectedFailure(
                    diagnosticDetail: "A confirmed item had no prepared package."
                ))),
                pumping: false
            )
            return
        }
        let id = item.id
        let attempt = item.attempt
        let resolution = item.resolution
        let processing = self.processing
        items[index].phase = .importing
        items[index].estimate = Self.estimate(for: .importing)
        let relay = ProgressRelay(hub: self, id: id, attempt: attempt, interval: progressInterval)

        commitTask = Task { [weak self] in
            let settlement: ImportSettlement
            do {
                settlement = try await processing.admit(prepared, resolution: resolution, reporting: relay)
            } catch {
                settlement = ImportSettlement.from(error: error)
            }
            self?.didCommit(id, settlement, attempt: attempt)
        }
    }

    private func didCommit(_ id: ImportJobIdentifier, _ settlement: ImportSettlement, attempt: Int) {
        commitTask = nil
        guard let index = self.index(of: id, attempt: attempt) else {
            pump()
            return
        }
        // The workflow consumed the working copy whatever the outcome.
        items[index].staged = nil
        settle(at: index, with: settlement)
        pump()
    }

    // MARK: - Settling

    private func settle(at index: Int, with settlement: ImportSettlement, pumping: Bool = true) {
        items[index].phase = .settled(settlement)
        items[index].settledAt = now()
        items[index].fractionCompleted = 1
        items[index].pendingArtifactID = nil
        items[index].estimate = Self.estimate(for: items[index].stage)

        // A ZynSign-owned copy of a dropped file has no further use once its
        // package is safely handled; a failed one is kept for a retry.
        if case .document(let url) = items[index].source, !items[index].hasRetryableOutcome {
            releaseSource(url)
        }
        if case .archiveEntry(let containerID, _) = items[index].source {
            releaseArchiveIfDone(containerID)
        }
        scheduleJournalWrite()
        if pumping {
            recordFinishedBatches()
        }
    }

    /// Discards an archive's working copy once none of its packages can
    /// still need it: every one has finished, and none could be retried.
    private func releaseArchiveIfDone(_ containerID: ImportJobIdentifier) {
        guard let index = self.index(of: containerID), items[index].staged != nil else { return }
        let children = items.filter { item in
            if case .archiveEntry(let container, _) = item.source { return container == containerID }
            return false
        }
        guard children.allSatisfy({ $0.isFinished && !$0.hasRetryableOutcome }) else { return }
        if let staged = items[index].staged {
            processing.discardWorkingCopy(staged.artifactID)
        }
        items[index].staged = nil
    }

    private func discardWorkingCopies(of index: Int) {
        if let staged = items[index].staged {
            processing.discardWorkingCopy(staged.artifactID)
            items[index].staged = nil
        }
        if let prepared = items[index].prepared, items[index].phase != .importing {
            processing.discardWorkingCopy(prepared.artifactID)
        }
    }

    /// Discards the working copy a preparation was writing when it stopped
    /// before it could be recorded.
    ///
    /// `discardWorkingCopies(of:)` removes the copies the item *holds*; this
    /// removes the one it was still producing, which nothing else refers to:
    /// the retry stages afresh under a new identifier, and the recovery
    /// journal never named it. Called only once the write has ended, so the
    /// file is not unlinked under a writer.
    private func discardUnrecordedWorkingCopy(of index: Int) {
        guard items[index].staged == nil, let pending = items[index].pendingArtifactID else { return }
        processing.discardWorkingCopy(pending)
        items[index].pendingArtifactID = nil
    }

    // MARK: - Progress

    fileprivate func apply(_ progress: ImportProgress, to id: ImportJobIdentifier, attempt: Int) {
        guard let index = self.index(of: id, attempt: attempt) else { return }
        let reported = ImportQueueStage.stage(for: progress.stage)

        switch items[index].phase {
        case .preparing, .validating, .analyzing:
            let order: [ImportQueueStage] = [.preparing, .validating, .analyzing]
            guard let current = order.firstIndex(of: items[index].stage),
                  let incoming = order.firstIndex(of: reported),
                  incoming >= current else { return }
            switch reported {
            case .validating: items[index].phase = .validating
            case .analyzing: items[index].phase = .analyzing
            default: break
            }
        case .importing:
            guard reported == .importing || reported == .complete else { return }
        default:
            return
        }

        if progress.stage == .copying, items[index].transferStartedAt == nil {
            items[index].transferStartedAt = now()
        }
        items[index].progress = progress
        items[index].fractionCompleted = max(items[index].fractionCompleted, progress.fractionCompleted)
        items[index].estimate = ImportRemainingEstimate.estimate(
            stage: items[index].stage,
            progress: progress,
            transferStartedAt: items[index].transferStartedAt,
            now: now()
        )
    }

    private static func estimate(for stage: ImportQueueStage, remainingSteps: Int? = nil) -> ImportRemainingEstimate {
        ImportRemainingEstimate(
            remainingSteps: remainingSteps ?? stage.remainingStepCount,
            remainingBytes: nil,
            remainingSeconds: nil
        )
    }

    // MARK: - Notes between items

    /// Marks an item that just became ready when another item in the hub
    /// holds the same content (deselecting the newcomer) or another package
    /// of the same application.
    private func applyBatchNotes(at index: Int) {
        guard let prepared = items[index].prepared else { return }
        let others = items.indices.filter { other in
            guard other != index, let candidate = items[other].prepared else { return false }
            switch items[other].phase {
            case .ready, .queuedForImport, .importing:
                return candidate.artifactID != prepared.artifactID
            default:
                return false
            }
        }
        if let twin = others.first(where: { items[$0].prepared?.reference.describesSameContent(as: prepared.reference) == true }) {
            items[index].note = .sameContent(as: items[twin].fileName)
            items[index].isSelected = false
        } else if let sibling = others.first(where: {
            items[$0].prepared?.identity.bundleIdentifier == prepared.identity.bundleIdentifier
        }) {
            items[index].note = .sameApplication(as: items[sibling].fileName)
        }
    }

    // MARK: - History recording

    private func recordFinishedBatches() {
        let batches = Set(items.map(\.batchID)).subtracting(recordedBatches)
        for batch in batches {
            let members = items.filter { $0.batchID == batch }
            guard !members.isEmpty, members.allSatisfy(\.isFinished) else { continue }
            recordedBatches.insert(batch)

            let settled = members.filter { $0.settlement != nil }
            guard !settled.isEmpty, !settled.allSatisfy({ $0.settlement?.kind == .cancelled }) else { continue }

            let entry = ImportHistoryEntry(
                id: batch,
                startedAt: members.map(\.enqueuedAt).min() ?? now(),
                finishedAt: members.compactMap(\.settledAt).max() ?? now(),
                origin: members[0].origin,
                items: settled.map(Self.historyItem(for:))
            )
            history.removeAll { $0.id == batch }
            history.insert(entry, at: 0)
            if history.count > Self.historyCapacity {
                history.removeLast(history.count - Self.historyCapacity)
            }
            lastFinishedBatch = entry
            if let historyStore {
                chainHistoryWrite { try await historyStore.record(entry) }
            }
        }
    }

    private static func historyItem(for item: Item) -> ImportHistoryEntry.Item {
        let settlement = item.settlement
        let identity = item.identity
        let outcome: ImportHistoryEntry.Outcome
        switch settlement?.kind {
        case .some(.imported): outcome = .imported
        case .some(.keptBoth): outcome = .keptBoth
        case .some(.replaced): outcome = .replaced
        case .some(.skipped): outcome = .skipped
        case .some(.alreadyHeld): outcome = .alreadyInLibrary
        case .some(.cancelled), .none: outcome = .cancelled
        case .some(.rejected): outcome = .refused
        case .some(.failed): outcome = .failed
        }
        let fileName = item.containerFileName.map { "\($0) › \(item.fileName)" } ?? item.fileName
        return ImportHistoryEntry.Item(
            id: item.id.uuid,
            fileName: fileName,
            outcome: outcome,
            applicationName: identity?.displayName,
            bundleIdentifier: identity?.bundleIdentifier.rawValue,
            version: identity?.shortVersionString,
            recordID: settlement?.record?.id.rawValue,
            replacedCount: settlement?.replacedRecords.count ?? 0,
            failureMessage: settlement?.failure?.message
        )
    }

    private func chainHistoryWrite(_ write: @escaping @Sendable () async throws -> Void) {
        let previous = historyWriter
        historyWriter = Task {
            await previous?.value
            try? await write()
        }
    }

    // MARK: - Interrupted-import journal

    /// The items worth journaling: everything unfinished. Items without a
    /// working copy are journaled too, so an interruption can be explained
    /// rather than silently forgotten.
    private func recoveryRecords() -> [ImportRecoveryRecord] {
        items.compactMap { item in
            switch item.phase {
            case .settled, .unpacked:
                return nil
            default:
                return ImportRecoveryRecord(
                    itemID: item.id.uuid,
                    batchID: item.batchID.uuid,
                    fileName: item.fileName,
                    origin: item.origin,
                    enqueuedAt: item.enqueuedAt,
                    stagedArtifactID: item.staged?.artifactID.rawValue,
                    containerFileName: item.containerFileName
                )
            }
        }
    }

    private func scheduleJournalWrite() {
        guard let recoveryJournal else { return }
        journalNeedsWrite = true
        guard journalWriter == nil else { return }
        journalWriter = Task { [weak self] in
            while true {
                guard let hub = self, hub.journalNeedsWrite else { break }
                hub.journalNeedsWrite = false
                let snapshot = hub.recoveryRecords()
                try? await recoveryJournal.replace(with: snapshot)
            }
            self?.journalWriter = nil
        }
    }

    /// Waits until every journal and history write issued so far has
    /// finished. For tests and orderly shutdown.
    func flushPendingWrites() async {
        while let writer = journalWriter {
            await writer.value
        }
        await historyWriter?.value
    }

    // MARK: - Background execution

    private func updateBackgroundActivity() {
        let hasWork = !isPaused && (commitTask != nil || !tasks.isEmpty || items.contains(where: \.isActive))
        if hasWork {
            guard backgroundActivity == nil, let backgroundExecution else { return }
            backgroundActivity = backgroundExecution.beginBackgroundWork { [weak self] in
                self?.backgroundTimeExpired()
            }
        } else {
            endBackgroundActivity()
        }
    }

    private func endBackgroundActivity() {
        guard let activity = backgroundActivity else { return }
        backgroundActivity = nil
        backgroundExecution?.endBackgroundWork(activity)
    }

    // MARK: - Lookup

    private func index(of id: ImportJobIdentifier) -> Int? {
        items.firstIndex { $0.id == id }
    }

    private func index(of id: ImportJobIdentifier, attempt: Int) -> Int? {
        guard let index = self.index(of: id), items[index].attempt == attempt else { return nil }
        return index
    }
}

// MARK: - Progress relay

/// Delivers an item's progress to the hub at a bounded rate.
///
/// The pipeline reports from its own task, as often as it likes; the relay
/// forwards a report to the main actor only when the stage changes, when a
/// stage completes, or when `interval` has passed since the last delivery.
/// Every delivery carries the attempt it belongs to, so a report that
/// arrives after a retry or cancellation is ignored.
private final class ProgressRelay: ImportProgressReporting, @unchecked Sendable {

    private weak var hub: ImportHub?
    private let id: ImportJobIdentifier
    private let attempt: Int
    private let interval: TimeInterval
    private let lock = NSLock()
    private var lastDelivery = Date.distantPast
    private var lastStage: ImportStage?

    init(hub: ImportHub, id: ImportJobIdentifier, attempt: Int, interval: TimeInterval) {
        self.hub = hub
        self.id = id
        self.attempt = attempt
        self.interval = interval
    }

    func report(_ progress: ImportProgress) {
        let moment = Date()
        lock.lock()
        let stageChanged = progress.stage != lastStage
        let completesStage = progress.isDeterminate && progress.completedUnitCount >= progress.totalUnitCount
        let due = moment.timeIntervalSince(lastDelivery) >= interval
        guard stageChanged || completesStage || due else {
            lock.unlock()
            return
        }
        lastDelivery = moment
        lastStage = progress.stage
        let target = hub
        lock.unlock()

        let id = self.id
        let attempt = self.attempt
        Task { @MainActor [weak target] in
            target?.apply(progress, to: id, attempt: attempt)
        }
    }
}
