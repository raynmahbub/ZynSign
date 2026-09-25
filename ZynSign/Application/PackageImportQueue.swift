import Foundation
import Combine

/// The import queue: it accepts requests to bring packages into ZynSign from
/// every entry point, runs them, and reports what each one did.
///
/// The queue exists so that the *user's* view of importing matches what the
/// machine can actually do. A person dropping five files, or picking several
/// at once, expects them all to be accounted for — each with its own progress,
/// its own outcome, and its own way out: cancel the one that is running,
/// retry the one that failed, remove the ones that are finished. What the
/// machine can do is narrower: the intake is deliberately not internally
/// synchronized, staging and adoption both move large files, and an import
/// may need an answer from the user before it can continue. The queue is the
/// place those two views meet.
///
/// **One import runs at a time, in the order the user asked for them.** That
/// is a deliberate choice, not a limitation of the queue's shape: it means two
/// large copies never compete for the device's storage throughput, the
/// library's admission sequence is always observable, and the user is never
/// asked two duplicate questions at once. Waiting jobs are held with their
/// file name and origin so the interface can list them, and they start as the
/// preceding job settles — including a job that settles by being cancelled or
/// refused.
///
/// **A decision is part of the import, not a detour from it.** When the
/// comparison against the library finds a collision, the running job moves to
/// `awaitingDuplicateDecision` and the queue waits there — visibly, with the
/// report on the job — until `resolveDuplicate(_:with:)` answers it. Nothing
/// has been stored at that point and nothing will be until the answer arrives,
/// so cancelling at the question, including by cancelling the job, discards
/// the staged copy and leaves the library, and the user's file, untouched.
///
/// **A source URL is kept only for as long as the job is listed.** Retrying
/// re-reads the file the user selected, so the URL has to survive the job's
/// own lifetime; it never leaves the queue, is never persisted, and is dropped
/// the moment the job is removed. The queue's `Job` values — the only thing
/// the interface sees — carry the file's *name*, never its location.
///
/// The queue owns no bytes. Staged copies belong to the import flow, and a
/// settled job's archive has either been moved into library storage by the
/// library or discarded by the import — the queue holds no way to reach
/// either, which is why clearing a job cannot delete anything.
@MainActor
final class PackageImportQueue: ObservableObject {

    /// One import request, as the interface sees it.
    ///
    /// The job is a value: the interface may keep it, diff it, or present it
    /// without holding a reference to the queue. It names the file the user
    /// chose by its *file name* — a display label captured at the moment the
    /// request was accepted — and never by a path or a URL.
    struct Job: Identifiable, Equatable {

        /// The stage of the import machine this job is in.
        enum State: Equatable {

            /// Accepted and waiting for its turn.
            case queued

            /// Running. What it is doing now is in `progress`.
            case running

            /// Waiting for the user to decide what to do about a package the
            /// library appears to hold already. Nothing has been stored.
            case awaitingDuplicateDecision(DuplicateReport)

            /// Finished, with the outcome recorded.
            case settled(ImportSettlement)

            /// Whether the job has not yet finished.
            var isActive: Bool {
                switch self {
                case .queued, .running, .awaitingDuplicateDecision: return true
                case .settled: return false
                }
            }

            /// Whether the job has finished.
            var isSettled: Bool {
                !isActive
            }
        }

        let id: ImportJobIdentifier
        let origin: ImportOrigin
        let sourceFileName: String
        let enqueuedAt: Date
        var state: State

        /// The last progress observation, or `nil` before the import reports
        /// one. Kept separately from the state so a job waiting on the user's
        /// decision keeps showing how far it got.
        var progress: ImportProgress?

        /// The size of the file being imported, in bytes, once a report or a
        /// measurement established it. Never an estimate.
        var byteCount: Int?

        /// When the job finished, or `nil` while it is still active.
        var settledAt: Date?

        /// How far along the job is: `0` before it starts, the reported
        /// fraction while it runs, and the last fraction reached once it
        /// settles.
        var fractionCompleted: Double {
            progress?.fractionCompleted ?? 0
        }

        /// What is happening to this job now, in the user's terms.
        var statusText: String {
            switch state {
            case .queued: return "Waiting"
            case .running: return progress?.stage.displayName ?? "Starting"
            case .awaitingDuplicateDecision: return "Waiting for your decision"
            case .settled(let settlement): return settlement.kind.displayName
            }
        }

        /// The stage the job has reached, when it has reported one.
        var stage: ImportStage? {
            progress?.stage
        }

        /// How the job ended, when it has.
        var settlement: ImportSettlement? {
            if case .settled(let settlement) = state { return settlement }
            return nil
        }

        /// The duplicate comparison the job is waiting on, when it is.
        var pendingDuplicateReport: DuplicateReport? {
            if case .awaitingDuplicateDecision(let report) = state { return report }
            return nil
        }

        /// Whether offering to run this job again is honest.
        var isRetryable: Bool {
            settlement?.isRetryable ?? false
        }

        /// Whether the job can be removed from the list.
        var canBeRemoved: Bool {
            state.isSettled
        }
    }

    /// The requests the queue is holding, oldest first: active jobs in the
    /// order they will run, then settled jobs in the order they finished.
    ///
    /// Published, because a queue's state *is* what the import experience
    /// shows: progress, stages, outcomes, and the question it is waiting on.
    /// A separate presentation model would mirror this array and could only
    /// ever disagree with it.
    @Published private(set) var jobs: [Job] = []

    private let importing: any PackageImporting
    private let now: () -> Date

    /// Where each active job's file came from. Kept out of `Job` on purpose:
    /// the location is the queue's business, and the interface has no way to
    /// show it, log it, or persist it by accident.
    private var sources: [ImportJobIdentifier: URL] = [:]

    /// The jobs waiting for the user's decision, with the continuation that
    /// will resume their import.
    private var pendingDecisions: [ImportJobIdentifier: CheckedContinuation<DuplicateResolution, Never>] = [:]

    /// The task running the current import, if one is running.
    private var activeTask: Task<Void, Never>?

    /// Creates the queue over the import capability and the clock the
    /// composition root chose. `now` is injectable so tests get deterministic
    /// ordering and timestamps.
    ///
    /// The initializer is `nonisolated` because the composition root builds
    /// the queue while wiring the application environment, which is not a
    /// main-actor context. It only stores what it is given; every mutation of
    /// the queue's state after construction happens on the main actor.
    nonisolated init(importing: any PackageImporting, now: @escaping () -> Date = { Date() }) {
        self.importing = importing
        self.now = now
    }

    // MARK: - Reading

    /// The jobs that have not finished, in the order they will run.
    var activeJobs: [Job] {
        jobs.filter { $0.state.isActive }
    }

    /// The jobs that have finished, oldest first.
    var settledJobs: [Job] {
        jobs.filter { $0.state.isSettled }
    }

    /// The job waiting for the user's decision, when there is one.
    var jobAwaitingDecision: Job? {
        activeJobs.first { $0.pendingDuplicateReport != nil }
    }

    /// Whether an import is running or waiting to run.
    var isBusy: Bool {
        !activeJobs.isEmpty
    }

    /// The counts and totals of everything the queue is holding.
    var summary: ImportSummary {
        ImportSummary(
            settlements: jobs.compactMap { $0.settlement },
            scheduledCount: jobs.count,
            byteCount: jobs.reduce(0) { total, job in total + (job.byteCount ?? 0) }
        )
    }

    // MARK: - Enqueueing

    /// Accepts one request to import a package.
    ///
    /// The URL is read from when the job runs; it is never resolved, stat-ed,
    /// or persisted here, so accepting a request cannot itself fail. Whether
    /// the file can be reached is the import's question, and its answer is
    /// reported on the job.
    @discardableResult
    func enqueue(_ url: URL, origin: ImportOrigin) -> ImportJobIdentifier {
        let job = Job(
            id: ImportJobIdentifier(),
            origin: origin,
            sourceFileName: url.lastPathComponent,
            enqueuedAt: now(),
            state: .queued
        )
        sources[job.id] = url
        jobs.append(job)
        startNextIfNeeded()
        return job.id
    }

    /// Accepts several requests, in the order the user made them, and returns
    /// their identifiers in that order.
    @discardableResult
    func enqueue(_ urls: [URL], origin: ImportOrigin) -> [ImportJobIdentifier] {
        urls.map { enqueue($0, origin: origin) }
    }

    // MARK: - Cancelling

    /// Cancels one job.
    ///
    /// A job that has not started is cancelled outright: it never opens the
    /// file. A running job is asked to stop — the copy checks on every chunk —
    /// and its staged copy is removed on the way out. A job waiting on the
    /// user's decision is answered with "cancel", which discards the staged
    /// copy and stores nothing. A settled job is left alone; removing it is a
    /// separate, explicit action.
    func cancel(_ id: ImportJobIdentifier) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        switch job.state {
        case .queued:
            settle(id, with: ImportSettlement.cancelled())
        case .running, .awaitingDuplicateDecision:
            if let continuation = pendingDecisions.removeValue(forKey: id) {
                continuation.resume(returning: .cancel)
            }
            activeTask?.cancel()
        case .settled:
            break
        }
    }

    /// Cancels every job the queue is holding: the waiting ones outright, the
    /// running one at its next cancellation point, and any job waiting on a
    /// decision by cancelling it.
    func cancelAll() {
        for job in jobs where job.state.isActive {
            cancel(job.id)
        }
    }

    /// Removes a settled job from the list, and with it the only record of
    /// where its file came from. Nothing else changes: the library entry the
    /// import created (if any) is the library's, and removing the job never
    /// touches it.
    func remove(_ id: ImportJobIdentifier) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard jobs[index].state.isSettled else { return }
        jobs.remove(at: index)
        sources.removeValue(forKey: id)
    }

    /// Removes every settled job, leaving the active ones in place.
    func removeSettled() {
        let settled = jobs.filter { $0.state.isSettled }.map { $0.id }
        guard !settled.isEmpty else { return }
        jobs.removeAll { $0.state.isSettled }
        for id in settled {
            sources.removeValue(forKey: id)
        }
    }

    // MARK: - Retrying

    /// Runs a job again, from the same file the user selected.
    ///
    /// Retrying is offered only where it is honest: a cancellation, or a
    /// failure whose explanation says a later attempt can end differently.
    /// Everything else — a refused package, a recognised duplicate, an
    /// import that succeeded — is left alone, because re-reading an unchanged
    /// file cannot change what it declares. The retry re-reads the original
    /// file; it never substitutes, repairs, or rewrites it.
    func retry(_ id: ImportJobIdentifier) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard let settlement = jobs[index].settlement, settlement.isRetryable else { return }
        guard sources[id] != nil else { return }

        jobs[index].state = .queued
        jobs[index].progress = nil
        jobs[index].settledAt = nil
        startNextIfNeeded()
    }

    // MARK: - Answering a duplicate question

    /// Applies the user's answer to the job that is waiting for it.
    ///
    /// Answering a job that is not waiting does nothing: an answer that
    /// arrives twice, or after the job was removed, cannot resume anything.
    func resolveDuplicate(_ id: ImportJobIdentifier, with resolution: DuplicateResolution) {
        guard let continuation = pendingDecisions.removeValue(forKey: id) else { return }
        continuation.resume(returning: resolution)
    }

    // MARK: - Running

    /// Starts the oldest waiting job when nothing is running.
    private func startNextIfNeeded() {
        guard activeTask == nil else { return }
        guard let next = jobs.first(where: { $0.state == .queued }) else { return }
        let id = next.id
        // The task holds the queue while it runs, so a job that is running is
        // never abandoned by the queue being released underneath it.
        activeTask = Task { [weak self] in
            guard let self else { return }
            await self.run(id)
        }
    }

    /// Runs one job to its settlement.
    ///
    /// The job is checked once more before it starts, because a task is
    /// scheduled asynchronously: between the queue's decision to run a job and
    /// this point, the user can cancel it. A cancelled job has already
    /// settled, and a settled job is never started — the request was
    /// withdrawn, so nothing may open the file after the fact.
    private func run(_ id: ImportJobIdentifier) async {
        defer {
            activeTask = nil
            startNextIfNeeded()
        }
        guard let source = sources[id],
              let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].state == .queued
        else {
            return
        }
        jobs[index].state = .running
        jobs[index].progress = ImportProgress(stage: .preparing)

        let progress = JobProgressSink(job: id, queue: self)
        do {
            let result = try await importing.importArtifact(
                from: source,
                reporting: progress,
                resolvingDuplicatesWith: decisionProvider(for: id)
            )
            settle(id, with: ImportSettlement.from(result))
        } catch {
            settle(id, with: ImportSettlement.from(error: error))
        }
    }

    /// The duplicate-question channel for one job, handed to the import.
    private func decisionProvider(for id: ImportJobIdentifier) -> DuplicateDecisionProvider {
        { [weak self] report in
            guard let self else { return .cancel }
            return await self.awaitDecision(for: id, report: report)
        }
    }

    /// Moves the job to `awaitingDuplicateDecision` and suspends until the
    /// user answers. Nothing is stored while the question stands, so a
    /// cancellation at this point discards the staged copy and nothing else.
    private func awaitDecision(
        for id: ImportJobIdentifier,
        report: DuplicateReport
    ) async -> DuplicateResolution {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return .cancel }
        jobs[index].state = .awaitingDuplicateDecision(report)

        // A job cancelled between the import's last cancellation check and
        // this point would otherwise wait for an answer nobody can give.
        // `Task` identity survives the hop to the main actor, so the question
        // is answered here rather than left open.
        guard !Task.isCancelled else { return .cancel }

        return await withCheckedContinuation { (continuation: CheckedContinuation<DuplicateResolution, Never>) in
            pendingDecisions[id] = continuation
        }
    }

    /// Records the outcome of one job and tells the observers.
    private func settle(_ id: ImportJobIdentifier, with settlement: ImportSettlement) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard jobs[index].state.isActive else { return }

        jobs[index].state = .settled(settlement)
        jobs[index].settledAt = now()
        if jobs[index].byteCount == nil, let progress = jobs[index].progress, progress.isDeterminate {
            jobs[index].byteCount = progress.totalUnitCount
        }
        if settlement.kind.isAccepted, let progress = jobs[index].progress {
            // An import that stored something finished its last stage; one
            // that did not keeps the fraction it actually reached.
            jobs[index].progress = ImportProgress(
                stage: .finished,
                completedUnitCount: progress.totalUnitCount,
                totalUnitCount: progress.totalUnitCount
            )
        }
    }

    /// Mirrors one progress report onto its job.
    ///
    /// Reports are produced on the context the import runs on and reach the
    /// queue asynchronously, so they can arrive out of order or after the job
    /// has already moved on. Both are handled here rather than at the source:
    /// a report for a job that is not running is dropped, and a report that
    /// would move a job backwards is dropped, which makes the delivery order
    /// irrelevant instead of load-bearing.
    fileprivate func apply(_ progress: ImportProgress, to id: ImportJobIdentifier) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard case .running = jobs[index].state else { return }
        if let current = jobs[index].progress, progress.fractionCompleted < current.fractionCompleted {
            return
        }
        jobs[index].progress = progress
        if progress.isDeterminate {
            jobs[index].byteCount = progress.totalUnitCount
        }
    }

}

/// Delivers one job's progress reports to the queue.
///
/// The import reports from whichever context it runs on — the copy loop
/// inside a file-coordination accessor, the metadata reader, the library
/// actor — so the sink hands each report to the main actor instead of
/// touching the queue's state directly. Holding the two values it delivers
/// together (the job's identity and the queue) is all it does; it is
/// therefore safe to call from any thread, which is the whole of what
/// `@unchecked Sendable` claims here.
private final class JobProgressSink: ImportProgressReporting, @unchecked Sendable {

    private let job: ImportJobIdentifier
    private let queue: PackageImportQueue

    init(job: ImportJobIdentifier, queue: PackageImportQueue) {
        self.job = job
        self.queue = queue
    }

    func report(_ progress: ImportProgress) {
        Task { @MainActor in
            queue.apply(progress, to: job)
        }
    }
}
