import Foundation
import Combine

/// The signing queue: ZynSign's job orchestration for signing operations.
///
/// The queue exists so that signing many applications matches what the
/// machine can actually do. A person queuing five apps expects each to be
/// accounted for — its own stage, its own progress, its own outcome, its
/// own way out — while the device can honestly offer one heavy signing run
/// at a time. The queue is where those two views meet: every signing
/// request becomes an independent job, jobs wait their turn in an order the
/// user controls, and the interface stays responsive while work runs
/// because the queue, not any screen, owns the work. Navigating away from
/// the dashboard cancels nothing.
///
/// **One job runs at a time, highest priority first, then first asked.**
/// Sequential execution is deliberate, for the same reason the batch
/// coordinator gives: signing is CPU- and I/O-heavy, and parallel runs
/// would multiply peak memory and battery cost on a phone. The scheduler is
/// nevertheless written against a `maximumConcurrentJobs` bound rather than
/// a hard-coded single task, and every job is fully isolated — its own
/// request, its own operation-created working directory, its own export
/// name chosen by export storage, its own log, its own verification — so
/// raising the bound is a policy change, not an architecture change.
///
/// **A running job is never preempted.** Priorities and reordering arrange
/// *waiting* jobs; a run in flight always finishes, fails, or is cancelled
/// as a whole. Cancellation is cooperative and honest: the pipeline checks
/// at every stage boundary, so a cancelled run stops at the next safe point
/// and the job says "Cancelling…" until it does. Pause is not offered at
/// all — the pipeline has no checkpoint a half-signed working copy could
/// safely resume from, and a control that cannot be implemented safely is
/// not a control.
///
/// **A retry is a fresh, clean run.** Every attempt is a new signing
/// operation with a new working directory, a failed attempt delivers
/// nothing, and the source container is only ever read — so a retry never
/// continues from a partially modified state, it repeats an untouched
/// one. Retrying is offered only where it is honest: transient failures,
/// interruptions, and cancellations, never an input the pipeline refused on
/// its content.
///
/// **The queue survives an interruption, honestly.** Its list is persisted
/// whenever it changes; on restoration, settled jobs come back exactly as
/// they settled, waiting jobs come back runnable when their queue-owned
/// profile copy survived, and a job that was *running* when the process
/// died is recorded as an interrupted failure — never as completed, and
/// never as waiting on work that no longer exists. Temporary state (stale
/// working directories, orphaned profile copies) is swept during
/// restoration.
///
/// The queue owns no signed bytes. A completed job names the artifact its
/// signing operation committed to export storage, where the Export Center
/// lists it; removing the job from the list never touches that artifact,
/// and clearing the list never deletes anything the user can see in Files
/// or in Exports.
@MainActor
final class SigningQueue: ObservableObject {

    /// One signing job, as the interface sees it.
    ///
    /// The job is a value: the interface may keep it, diff it, or present
    /// it without holding a reference to the queue. It names the
    /// application by its declared display values and the signing
    /// configuration by captured display facts — never by a path, a URL,
    /// profile content, or anything the Keychain holds.
    struct Job: Identifiable, Equatable {

        /// The job's own stable identity.
        let id: SigningJobIdentifier

        /// The library record being signed.
        let recordID: ApplicationRecordIdentifier

        /// The library artifact the source container is derived from.
        let artifactID: ArtifactIdentifier

        /// The application's display name, captured when the job was
        /// accepted.
        let applicationName: String

        /// The declared bundle identifier.
        let bundleIdentifier: String

        /// The declared versions as one display line, when available.
        let versionText: String?

        /// The job's scheduling priority.
        var priority: SigningJobPriority

        /// Where the job was asked for. A job restored from persistence as
        /// a still-waiting job reads `.restored`: its original origin was a
        /// fact about a session that no longer exists.
        var origin: SigningJobOrigin

        /// When the job was accepted.
        let enqueuedAt: Date

        /// When the current run started, or `nil` before the first run.
        var startedAt: Date?

        /// When the job settled, or `nil` while it is still active.
        var finishedAt: Date?

        /// How many runs the job has started: 0 before the first, 1 after
        /// it, 2 after one retry, and so on.
        var attemptCount: Int

        /// The lifecycle state.
        var state: SigningJobState

        /// The last progress observation, or `nil` before the first run
        /// reports one. Kept separately from the state so a settled job
        /// keeps showing how far it got.
        var progress: SigningJobProgress?

        /// Whether cancellation has been requested and the run has not yet
        /// reached its next safe point. Only ever true for a running job.
        var cancellationRequested: Bool

        /// The job's own log — stage transitions, retries, settlements.
        /// Never interleaved with another job's.
        var log: [SigningJobLogEntry]

        /// Whether the queue holds everything a fresh run of this job needs
        /// — identity identifier and profile bytes. Always true for a job
        /// accepted this session; false for a restored job whose
        /// configuration could not be recovered, which is why such a job
        /// never offers a retry it could not perform.
        var hasRunnableSetup: Bool

        // MARK: Signing configuration display facts

        /// The identity's display name, captured at configuration time.
        let identityDisplayName: String?

        /// The certificate's SHA-256 fingerprint, captured at configuration
        /// time. Public certificate metadata; the private key never leaves
        /// the Keychain.
        let certificateFingerprint: CertificateFingerprint?

        /// The profile's display name, captured at configuration time.
        let profileDisplayName: String?

        /// The profile's team identifier, captured at configuration time.
        let profileTeamIdentifier: String?

        /// Whether the run emits the DER entitlements blob (v0x20400).
        let emitDEREntitlements: Bool

        /// Whether the job has not yet finished.
        var isActive: Bool { state.isActive }

        /// Whether the job has finished.
        var isSettled: Bool { state.isSettled }

        /// How far along the job is: `0` before it starts, the weighted
        /// stage fraction while it runs, `1` once completed, and the last
        /// fraction reached for a failure or cancellation.
        var fractionCompleted: Double {
            if case .completed = state { return 1 }
            return progress?.fractionCompleted ?? 0
        }

        /// The stage the job has reached, when it has reported one.
        var stage: SigningJobStage? {
            if case .completed = state { return .completed }
            return progress?.stage
        }

        /// What is happening to this job now, in the user's terms.
        var statusText: String {
            switch state {
            case .queued:
                return "Waiting"
            case .running:
                if cancellationRequested { return "Cancelling…" }
                return progress?.stage.displayName ?? "Starting"
            case .completed:
                return "Completed"
            case .failed(let failure):
                return "Failed at \(failure.stage.displayName)"
            case .cancelled:
                return "Cancelled"
            }
        }

        /// The completion evidence, when the job completed.
        var completion: SigningJobCompletion? { state.completion }

        /// The failure, when the job failed.
        var failure: SigningJobFailure? { state.failure }

        /// Whether offering to run this job again is honest: it failed or
        /// was cancelled, and the failure's explanation says a fresh clean
        /// run can end differently.
        var isRetryable: Bool {
            guard hasRunnableSetup else { return false }
            switch state {
            case .failed(let failure): return failure.isRetryable
            case .cancelled: return true
            case .queued, .running, .completed: return false
            }
        }

        /// Whether the job can be removed from the list: only after it has
        /// settled.
        var canBeRemoved: Bool { state.isSettled }
    }

    /// The counts the dashboard's statistics card shows.
    struct Summary: Equatable {

        /// How many jobs are running right now.
        let runningCount: Int

        /// How many jobs are waiting their turn.
        let waitingCount: Int

        /// How many jobs delivered a verified container.
        let completedCount: Int

        /// How many jobs failed.
        let failedCount: Int

        /// How many jobs were cancelled.
        let cancelledCount: Int

        /// Every job the queue is holding.
        let totalCount: Int

        var settledCount: Int { completedCount + failedCount + cancelledCount }

        /// Whether any work is running or waiting.
        var isBusy: Bool { runningCount + waitingCount > 0 }
    }

    /// The jobs the queue is holding, in schedule order: the running job
    /// (if any) sits where it started, waiting jobs follow in the order
    /// they will run, and settled jobs stay where they finished. The
    /// dashboard groups them by state; the array order is the truth for
    /// "which job runs next".
    @Published private(set) var jobs: [Job] = []

    /// The in-app notifications the queue has posted and the shell has not
    /// acknowledged yet, oldest first. The shell shows each once — as a
    /// toast, a VoiceOver announcement, and (where allowed) a local
    /// notification — then acknowledges it.
    @Published private(set) var pendingNotices: [SigningQueueNotice] = []

    /// Whether restoration from persistence is in progress. The dashboard
    /// shows the fact rather than an empty queue that is about to fill.
    @Published private(set) var isRestoring = false

    /// The most recent durable snapshot failure. Queue state remains in memory,
    /// but callers must not be told it was persisted when it was not.
    @Published private(set) var persistenceError: String?

    /// How many jobs may run at once. One, deliberately: signing is CPU-
    /// and I/O-heavy, and parallel runs would multiply peak memory and
    /// battery cost. Jobs are isolated per run, so raising this bound is a
    /// policy change the scheduler already supports.
    let maximumConcurrentJobs = 1

    /// How many notices the queue holds before dropping the oldest.
    private static let noticeCapacity = 20

    /// How many log lines one job keeps.
    private static let logCapacity = 64

    private let executor: any SigningQueueExecuting
    private let store: (any SigningQueueStore)?
    private let notifier: (any SigningQueueNotifying)?

    /// Derives the source container's location from the library artifact
    /// identifier, through the library's own storage convention. Injected
    /// so the queue never hard-codes a location — and so restoration
    /// re-derives locations exactly the way a fresh enqueue did.
    private let artifactURLResolver: @Sendable (ArtifactIdentifier) -> URL

    private let now: () -> Date

    /// The full submissions behind the listed jobs. Kept out of `Job` on
    /// purpose: profile bytes and identity identifiers are the queue's
    /// business, and the interface has no way to show them by accident.
    private var submissions: [SigningJobIdentifier: SigningJobSubmission] = [:]

    /// One coalescer per running job, so a run reporting hundreds of
    /// byte-level updates publishes only the ones that change what a row
    /// shows. Every stage change and every stage completion still passes.
    private var progressCoalescers: [SigningJobIdentifier: ProgressCoalescer] = [:]

    /// The queue-owned profile copy file names, once persistence has stored
    /// them. A snapshot written before a copy completes restores the job
    /// honestly — as a job whose configuration could not be recovered.
    private var profileFileNames: [SigningJobIdentifier: String] = [:]

    /// The tasks running jobs, keyed by job.
    private var runningTasks: [SigningJobIdentifier: Task<Void, Never>] = [:]

    /// The save counter the store rejects stale snapshots by.
    private var revision = 0

    /// Whether `restore()` has run. Restoration happens once per launch.
    private var hasRestored = false

    /// How many *runs* settled since the queue was last idle — the flag
    /// that makes "queue finished" a notice about work that ran, not about
    /// a list the user merely cleared.
    private var runsSettledSinceIdle = 0

    /// Records preset usage when a job that carried a preset settles.
    /// Passed in at init so composition never writes main-actor state after
    /// the queue exists. `nil` in tests that do not track presets.
    private let presetUsageRecorder: ((PresetUseOutcome) -> Void)?

    /// Creates the queue over the executor, persistence, and notification
    /// boundaries the composition root chose. `now` is injectable so tests
    /// get deterministic ordering and timestamps.
    ///
    /// The initializer is `nonisolated` because the composition root builds
    /// the queue while wiring the application environment, which is not a
    /// main-actor context. It only stores what it is given; every mutation
    /// of the queue's state after construction happens on the main actor.
    nonisolated init(
        executor: any SigningQueueExecuting,
        store: (any SigningQueueStore)? = nil,
        notifier: (any SigningQueueNotifying)? = nil,
        artifactURLResolver: @escaping @Sendable (ArtifactIdentifier) -> URL,
        presetUsageRecorder: ((PresetUseOutcome) -> Void)? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.executor = executor
        self.store = store
        self.notifier = notifier
        self.artifactURLResolver = artifactURLResolver
        self.presetUsageRecorder = presetUsageRecorder
        self.now = now
    }

    // MARK: - Reading

    /// The job that is running, when one is.
    var runningJob: Job? {
        jobs.first { $0.state == .running }
    }

    /// The jobs that are running, in schedule order. One today; the shape
    /// is ready for the bound to rise.
    var runningJobs: [Job] {
        jobs.filter { $0.state == .running }
    }

    /// The jobs waiting their turn, in the order they will run.
    var waitingJobs: [Job] {
        jobs.filter { $0.state == .queued }
    }

    /// The jobs that delivered a verified container, oldest first.
    var completedJobs: [Job] {
        jobs.filter { $0.state.completion != nil }
    }

    /// The jobs that failed, oldest first.
    var failedJobs: [Job] {
        jobs.filter { $0.state.failure != nil }
    }

    /// The jobs the user cancelled, oldest first.
    var cancelledJobs: [Job] {
        jobs.filter { $0.state == .cancelled }
    }

    /// The jobs that have finished, in list order.
    var settledJobs: [Job] {
        jobs.filter { $0.state.isSettled }
    }

    /// Whether a signing run is in progress or waiting to run.
    var isBusy: Bool {
        jobs.contains { $0.state.isActive }
    }

    /// The counts of everything the queue is holding.
    var summary: Summary {
        Summary(
            runningCount: runningJobs.count,
            waitingCount: waitingJobs.count,
            completedCount: completedJobs.count,
            failedCount: failedJobs.count,
            cancelledCount: cancelledJobs.count,
            totalCount: jobs.count
        )
    }

    /// The job with `id`, when the queue holds it.
    func job(withID id: SigningJobIdentifier) -> Job? {
        jobs.first { $0.id == id }
    }

    // MARK: - Enqueueing

    /// Accepts one request to sign an application.
    ///
    /// The submission is held as given; the source and output locations are
    /// derived when the job runs, through the library's and the composition
    /// root's own conventions. Accepting a request cannot itself fail:
    /// whether the package can be reached, the identity resolved, or the
    /// profile validated is the run's question, and its answer is reported
    /// on the job.
    ///
    /// The job is inserted among the waiting jobs by priority — before the
    /// first waiting job of strictly lower priority, otherwise after every
    /// waiting job — so urgent work overtakes background work, and within
    /// one priority the order the user asked is kept.
    @discardableResult
    func enqueue(
        _ submission: SigningJobSubmission,
        priority: SigningJobPriority = .normal,
        origin: SigningJobOrigin
    ) -> SigningJobIdentifier {
        let id = SigningJobIdentifier()
        let job = Job(
            id: id,
            recordID: submission.recordID,
            artifactID: submission.artifactID,
            applicationName: submission.applicationName,
            bundleIdentifier: submission.bundleIdentifier,
            versionText: submission.versionText,
            priority: priority,
            origin: origin,
            enqueuedAt: now(),
            startedAt: nil,
            finishedAt: nil,
            attemptCount: 0,
            state: .queued,
            progress: nil,
            cancellationRequested: false,
            log: [SigningJobLogEntry(
                timestamp: now(),
                message: "Queued from \(origin.displayName) · \(priority.displayName) priority."
            )],
            hasRunnableSetup: true,
            identityDisplayName: submission.identityDisplayName,
            certificateFingerprint: submission.certificateFingerprint,
            profileDisplayName: submission.profileDisplayName,
            profileTeamIdentifier: submission.profileTeamIdentifier,
            emitDEREntitlements: submission.emitDEREntitlements
        )
        submissions[id] = submission
        jobs.insert(job, at: waitingInsertionIndex(for: priority))
        storeProfileCopy(for: id, submission: submission)
        persist()
        scheduleNextJobs()
        return id
    }

    /// Accepts several requests, in the order the user made them, and
    /// returns their identifiers in that order. All share one priority and
    /// origin — a bulk selection is one decision.
    @discardableResult
    func enqueue(
        _ submissions: [SigningJobSubmission],
        priority: SigningJobPriority = .normal,
        origin: SigningJobOrigin
    ) -> [SigningJobIdentifier] {
        submissions.map { enqueue($0, priority: priority, origin: origin) }
    }

    // MARK: - Priorities and order

    /// Changes a waiting job's priority and re-inserts it at the position
    /// the new priority earns. A running or settled job's priority is
    /// display history and is left alone: changing it could not change
    /// anything safely.
    func setPriority(_ priority: SigningJobPriority, on id: SigningJobIdentifier) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard jobs[index].state == .queued else { return }
        guard jobs[index].priority != priority else { return }
        var job = jobs.remove(at: index)
        job.priority = priority
        appendLog(to: &job, "Priority set to \(priority.displayName).")
        jobs.insert(job, at: waitingInsertionIndex(for: priority))
        persist()
        scheduleNextJobs()
    }

    /// Moves a waiting job one position earlier or later among the waiting
    /// jobs. A running job is never reordered — its run is already in
    /// flight — and a settled job's position is history.
    func move(_ id: SigningJobIdentifier, up: Bool) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard jobs[index].state == .queued else { return }
        let waitingIndices = jobs.indices.filter { jobs[$0].state == .queued }
        guard let position = waitingIndices.firstIndex(of: index) else { return }
        let target = up ? position - 1 : position + 1
        guard target >= 0, target < waitingIndices.count else { return }
        jobs.swapAt(index, waitingIndices[target])
        persist()
        scheduleNextJobs()
    }

    /// Moves a waiting job to the front of the waiting list. The next job
    /// the scheduler picks is the first `.queued` job in list order, so a
    /// job sent to top runs next — as soon as the current run settles, if
    /// one is in flight.
    func sendToTop(_ id: SigningJobIdentifier) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard jobs[index].state == .queued else { return }
        let waitingIndices = jobs.indices.filter { jobs[$0].state == .queued }
        guard let top = waitingIndices.first, top != index else { return }
        let topID = jobs[top].id
        var job = jobs.remove(at: index)
        appendLog(to: &job, "Sent to the top of the queue.")
        guard let topIndex = jobs.firstIndex(where: { $0.id == topID }) else {
            jobs.append(job)
            persist()
            scheduleNextJobs()
            return
        }
        jobs.insert(job, at: topIndex)
        persist()
        scheduleNextJobs()
    }

    // MARK: - Cancelling

    /// Cancels one job.
    ///
    /// A waiting job is cancelled outright: it never opens the container. A
    /// running job is asked to stop — the pipeline checks at every stage
    /// boundary — and shows "Cancelling…" until the run reaches its next
    /// safe point; its working copy and any partial output are discarded on
    /// the way out. A settled job is left alone; removing it is a separate,
    /// explicit action.
    func cancel(_ id: SigningJobIdentifier) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[index].state {
        case .queued:
            // A task may already be scheduled for this job; cancelling it
            // makes its run guard exit without touching the container.
            runningTasks[id]?.cancel()
            settle(id, with: .cancelled, logMessage: "Cancelled while waiting.")
        case .running:
            jobs[index].cancellationRequested = true
            appendLog(id, "Cancellation requested — the run stops at its next safe point.")
            runningTasks[id]?.cancel()
        case .completed, .failed, .cancelled:
            break
        }
    }

    /// Cancels every waiting job. The running job — if any — is left in
    /// flight: "cancel all *waiting*" says exactly what it does.
    func cancelAllWaiting() {
        for job in jobs where job.state == .queued {
            cancel(job.id)
        }
    }

    // MARK: - Retrying

    /// Runs a job again, from the same untouched inputs.
    ///
    /// The retry re-queues the job at the position its priority earns and,
    /// when it runs, creates a completely fresh execution: a new working
    /// operation and working directory, the source read again. Nothing
    /// continues from a partially modified state, because no state
    /// survives a settled run to continue from.
    ///
    /// Retrying is offered only where it is honest — see `Job.isRetryable`.
    func retry(_ id: SigningJobIdentifier) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard jobs[index].isRetryable, submissions[id] != nil else { return }
        var job = jobs.remove(at: index)
        job.state = .queued
        job.progress = nil
        job.startedAt = nil
        job.finishedAt = nil
        job.cancellationRequested = false
        appendLog(to: &job, "Retry scheduled — a fresh run over untouched inputs.")
        jobs.insert(job, at: waitingInsertionIndex(for: job.priority))
        persist()
        scheduleNextJobs()
    }

    /// Retries every failed job whose failure says a fresh run can end
    /// differently. Jobs refused on their content are left alone: re-reading
    /// an unchanged package cannot change what it declares.
    func retryAllFailed() {
        for job in jobs where job.isRetryable && job.state.failure != nil {
            retry(job.id)
        }
    }

    // MARK: - Removing

    /// Removes a settled job from the list, discarding the queue's copy of
    /// its request and its persisted profile copy. Nothing else changes: an
    /// artifact the job delivered belongs to the Export Center, and removing
    /// the job never touches it.
    func remove(_ id: SigningJobIdentifier) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard jobs[index].state.isSettled else { return }
        jobs.remove(at: index)
        discardRequest(for: id)
        persist()
    }

    /// Removes every completed job, leaving everything else in place.
    func clearCompleted() {
        removeAllSettled { $0.state.completion != nil }
    }

    /// Removes every failed job, leaving everything else in place.
    func clearFailed() {
        removeAllSettled { $0.state.failure != nil }
    }

    /// Removes every cancelled job, leaving everything else in place.
    func clearCancelled() {
        removeAllSettled { $0.state == .cancelled }
    }

    /// Removes every settled job of the kinds the predicate selects.
    func removeAllSettled(where shouldBeRemoved: (Job) -> Bool) {
        let doomed = jobs.filter { $0.state.isSettled && shouldBeRemoved($0) }.map { $0.id }
        guard !doomed.isEmpty else { return }
        jobs.removeAll { job in doomed.contains(job.id) }
        for id in doomed {
            discardRequest(for: id)
        }
        persist()
    }

    // MARK: - Notices

    /// Acknowledges one notice: the shell has shown it, and it leaves the
    /// pending list. Acknowledging an unknown notice does nothing.
    func acknowledgeNotice(_ noticeID: UUID) {
        pendingNotices.removeAll { $0.id == noticeID }
    }

    // MARK: - Restoration

    /// Restores the queue from persistence, once per launch.
    ///
    /// Settled jobs come back exactly as they settled. Waiting jobs come
    /// back runnable when their setup survived — identity identifier parses,
    /// profile copy loads — and as an honest failure otherwise. A job that
    /// was running when the process died comes back as an interrupted
    /// failure, retryable when its setup survived: its working copy
    /// belonged to a dead process, and a run that did not finish is never
    /// presented as one that did. Temporary state — stale working
    /// directories and orphaned profile copies — is swept before anything
    /// runs again, and waiting jobs resume in their saved order.
    func restore() async {
        guard !hasRestored else { return }
        hasRestored = true
        guard let store else { return }
        isRestoring = true
        defer { isRestoring = false }

        let snapshot: SigningQueueSnapshot?
        do {
            snapshot = try await store.load()
        } catch {
            // A snapshot this build cannot read is degradation, not a dead
            // end: the queue starts empty and says nothing was restored.
            snapshot = nil
        }
        guard let snapshot else {
            try? await store.recoverWorkspace(referencedProfileFileNames: Set(profileFileNames.values))
            isRestoring = false
            persist()
            storeMissingProfileCopies()
            scheduleNextJobs()
            return
        }
        revision = max(revision, snapshot.revision)

        var restored: [Job] = []
        var referencedProfiles: Set<String> = []
        for stored in snapshot.jobs {
            guard let id = SigningJobIdentifier(rawValue: stored.id),
                  let recordID = ApplicationRecordIdentifier(rawValue: stored.recordID),
                  let artifactID = ArtifactIdentifier(rawValue: stored.artifactID) else {
                // A job whose identifiers no longer parse is dropped: it
                // could never run, and inventing a replacement identity
                // would be worse than losing the row.
                continue
            }
            var job = Job(
                id: id,
                recordID: recordID,
                artifactID: artifactID,
                applicationName: stored.applicationName,
                bundleIdentifier: stored.bundleIdentifier,
                versionText: stored.versionText,
                priority: stored.priority,
                origin: stored.origin,
                enqueuedAt: stored.enqueuedAt,
                startedAt: stored.startedAt,
                finishedAt: stored.finishedAt,
                attemptCount: stored.attemptCount,
                state: stored.state,
                progress: nil,
                cancellationRequested: false,
                log: stored.log,
                hasRunnableSetup: false,
                identityDisplayName: stored.setup?.identityDisplayName,
                certificateFingerprint: stored.setup?.certificateFingerprint,
                profileDisplayName: stored.setup?.profileDisplayName,
                profileTeamIdentifier: stored.setup?.profileTeamIdentifier,
                emitDEREntitlements: stored.setup?.emitDEREntitlements ?? false
            )
            job.log.append(SigningJobLogEntry(timestamp: now(), message: "Restored from the persisted queue."))

            // Rebuild the runnable request where the job still needs one:
            // waiting jobs so they can run, active failures so retry can.
            var submission: SigningJobSubmission?
            if let setup = stored.setup,
               let identityID = SigningIdentityIdentifier(rawValue: setup.identityID) {
                if let profileFileName = setup.profileFileName {
                    referencedProfiles.insert(profileFileName)
                }
                var profileData: Data?
                if let profileFileName = setup.profileFileName {
                    profileData = try? await store.loadProfile(fileName: profileFileName)
                }
                if let profileData {
                    if let profileFileName = setup.profileFileName {
                        profileFileNames[id] = profileFileName
                    }
                    submission = SigningJobSubmission(
                        recordID: recordID,
                        artifactID: artifactID,
                        applicationName: stored.applicationName,
                        bundleIdentifier: stored.bundleIdentifier,
                        versionText: stored.versionText,
                        identityID: identityID,
                        identityDisplayName: setup.identityDisplayName,
                        certificateFingerprint: setup.certificateFingerprint,
                        profile: profileData,
                        profileDisplayName: setup.profileDisplayName,
                        profileTeamIdentifier: setup.profileTeamIdentifier,
                        emitDEREntitlements: setup.emitDEREntitlements,
                        presetID: setup.presetID.flatMap { PresetIdentifier(rawValue: $0) }
                    )
                    submissions[id] = submission
                    job.hasRunnableSetup = true
                }
            }

            switch stored.state {
            case .running:
                // The run belonged to a dead process. Record the
                // interruption honestly; never let it stand as running,
                // and never mark it completed.
                job.state = .failed(SigningJobFailure(
                    stage: SigningJobStage(rawValue: stored.lastStageRawValue ?? "") ?? .preparing,
                    summary: "ZynSign was interrupted while this job was running.",
                    detail: submission != nil
                        ? "The run's working copy belonged to the interrupted process and was discarded. Retry starts a fresh, clean run."
                        : "The run's configuration could not be restored, so the job cannot run again. Remove it and queue the application again.",
                    category: .internalFailure,
                    isRetryable: submission != nil,
                    occurredAt: now()
                ))
                job.finishedAt = stored.finishedAt ?? now()
            case .queued:
                if submission == nil {
                    job.state = .failed(SigningJobFailure(
                        stage: .preparing,
                        summary: "This waiting job's configuration could not be restored.",
                        detail: "The queue's copy of the selected profile is gone, so the job cannot run again honestly. Remove it and queue the application again.",
                        category: .storageFailure,
                        isRetryable: false,
                        occurredAt: now()
                    ))
                    job.finishedAt = now()
                } else {
                    job.origin = .restored
                }
            case .completed, .failed, .cancelled:
                // Settled jobs come back exactly as they settled.
                break
            }
            restored.append(job)
        }
        // Jobs accepted while restoration was reading keep their place after
        // the restored ones; nothing the user asked for is overwritten.
        let restoredIDs = Set(restored.map(\.id))
        jobs = restored + jobs.filter { !restoredIDs.contains($0.id) }
        referencedProfiles.formUnion(profileFileNames.values)
        try? await store.recoverWorkspace(referencedProfileFileNames: referencedProfiles)
        isRestoring = false
        persist()
        storeMissingProfileCopies()
        scheduleNextJobs()
    }

    // MARK: - Running

    /// Starts waiting jobs while capacity is free, in list order. With the
    /// bound at one, that is the first waiting job when nothing runs; the
    /// loop is the whole scheduler, so the bound is the only policy.
    private func scheduleNextJobs() {
        // Nothing runs until the persisted queue has been restored: recovery
        // sweeps stale working directories, and a run started before it
        // could have its fresh working copy swept from under it. A queue
        // without persistence has nothing to restore and runs at once.
        guard !isRestoring, hasRestored || store == nil else { return }
        while JobQueueCapacity.hasCapacity(running: runningTasks.count, limit: maximumConcurrentJobs) {
            guard let next = jobs.first(where: { $0.state == .queued && runningTasks[$0.id] == nil }) else {
                return
            }
            startJob(next.id)
        }
    }

    private func startJob(_ id: SigningJobIdentifier) {
        // The task holds the queue while it runs, so a job that is running
        // is never abandoned by the queue being released underneath it.
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(id)
        }
        runningTasks[id] = task
    }

    /// Runs one job to its settlement.
    ///
    /// The job is checked once more before it starts, because a task is
    /// scheduled asynchronously: between the scheduler's decision and this
    /// point the user can cancel it, and a cancelled job is never started —
    /// the request was withdrawn, so nothing may open the container after
    /// the fact.
    private func run(_ id: SigningJobIdentifier) async {
        defer {
            runningTasks[id] = nil
            scheduleNextJobs()
            checkQueueFinished()
        }
        guard let submission = submissions[id],
              let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].state == .queued
        else {
            return
        }
        jobs[index].state = .running
        jobs[index].startedAt = now()
        jobs[index].attemptCount += 1
        jobs[index].progress = SigningJobProgress(stage: .preparing)
        jobs[index].cancellationRequested = false
        appendLog(id, "Run started (attempt \(jobs[index].attemptCount)).")
        persist()

        let request = makeExecutionRequest(
            jobID: id,
            submission: submission,
            attempt: jobs[index].attemptCount
        )
        let progress = JobProgressSink(job: id, queue: self)
        do {
            let outcome = try await executor.execute(request, reporting: progress)
            switch outcome {
            case .completed(let completion):
                settle(id, with: .completed(completion), logMessage: "Completed — verified container delivered.")
            case .failed(let failure):
                settle(id, with: .failed(failure), logMessage: "Failed at \(failure.stage.displayName).")
            }
        } catch is CancellationError {
            settle(id, with: .cancelled, logMessage: "Cancelled — working copy and partial output discarded.")
        } catch {
            // An infrastructure failure the executor itself could not
            // classify. Retryable: a fresh run is the honest next step.
            let failure = SigningJobFailure(
                stage: jobs.first(where: { $0.id == id })?.progress?.stage ?? .preparing,
                summary: "Signing failed unexpectedly.",
                detail: (error as? ZynSignError)?.userMessage ?? String(describing: error),
                category: (error as? ZynSignError)?.category ?? .internalFailure,
                isRetryable: true,
                occurredAt: now()
            )
            settle(id, with: .failed(failure), logMessage: "Failed unexpectedly at \(failure.stage.displayName).")
        }
    }

    /// Builds the execution request for one run: locations derived through
    /// the injected conventions, configuration from the submission.
    private func makeExecutionRequest(
        jobID: SigningJobIdentifier,
        submission: SigningJobSubmission,
        attempt: Int
    ) -> SigningJobExecutionRequest {
        SigningJobExecutionRequest(
            jobID: jobID,
            attempt: attempt,
            recordID: submission.recordID,
            sourceURL: artifactURLResolver(submission.artifactID),
            profile: submission.profile,
            identityID: submission.identityID,
            emitDEREntitlements: submission.emitDEREntitlements,
            applicationName: submission.applicationName,
            bundleIdentifier: submission.bundleIdentifier,
            versionText: submission.versionText,
            identityDisplayName: submission.identityDisplayName,
            certificateFingerprint: submission.certificateFingerprint,
            profileDisplayName: submission.profileDisplayName,
            profileTeamIdentifier: submission.profileTeamIdentifier,
            presetID: submission.presetID
        )
    }

    /// Mirrors one progress report onto its job.
    ///
    /// Reports are produced on the context the run is on and reach the
    /// queue asynchronously, so they can arrive out of order or after the
    /// job has settled. Both are handled here rather than at the source: a
    /// report for a job that is not running is dropped, and a report that
    /// would move a job backwards is dropped — progress never jumps up
    /// falsely and never rewinds.
    fileprivate func apply(_ progress: SigningJobProgress, to id: SigningJobIdentifier) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard jobs[index].state == .running else { return }
        if let current = jobs[index].progress {
            if progress.stage.order < current.stage.order { return }
            if progress.stage == current.stage, progress.fractionCompleted < current.fractionCompleted { return }
            if progress.stage != current.stage {
                appendLog(id, "Reached \(progress.stage.displayName).")
            }
        }
        // Publishing `jobs` re-renders every observer; a report that moves
        // the bar by less than a visible step is folded into the next one.
        var coalescer = progressCoalescers[id] ?? ProgressCoalescer()
        let isStageComplete = progress.totalUnitCount > 0 && progress.completedUnitCount >= progress.totalUnitCount
        let shouldPublish = coalescer.shouldPublish(
            stageOrder: progress.stage.order,
            fraction: progress.fractionCompleted,
            isStageComplete: isStageComplete,
            now: now()
        )
        progressCoalescers[id] = coalescer
        guard shouldPublish else { return }
        jobs[index].progress = progress
    }

    /// Records the outcome of one job, tells the observers, and offers the
    /// notice to the notification boundary.
    private func settle(_ id: SigningJobIdentifier, with state: SigningJobState, logMessage: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard jobs[index].state.isActive else { return }
        let wasRunning = jobs[index].state == .running
        jobs[index].state = state
        jobs[index].finishedAt = now()
        jobs[index].cancellationRequested = false
        progressCoalescers.removeValue(forKey: id)
        if state.completion != nil {
            jobs[index].progress = SigningJobProgress(stage: .completed)
        }
        appendLog(id, logMessage)
        if wasRunning {
            runsSettledSinceIdle += 1
        }
        recordPresetUsage(jobID: id, state: state)
        postNotice(for: jobs[index])
        persist()
        checkQueueFinished()
    }

    /// Updates preset usage only after a job settles. Enqueueing is not a
    /// use: a queued job can still be cancelled before it opens the package.
    private func recordPresetUsage(jobID: SigningJobIdentifier, state: SigningJobState) {
        guard let presetID = submissions[jobID]?.presetID,
              let result = Self.presetResult(state),
              let job = jobs.first(where: { $0.id == jobID }) else { return }
        presetUsageRecorder?(PresetUseOutcome(
            presetID: presetID,
            result: result,
            bundleIdentifier: job.bundleIdentifier,
            displayName: job.applicationName,
            at: now()
        ))
    }

    private static func presetResult(_ state: SigningJobState) -> PresetUseOutcome.Result? {
        switch state {
        case .completed: return .succeeded
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .queued, .running: return nil
        }
    }

    // MARK: - Notices and notifications

    private func postNotice(for job: Job) {
        let notice: SigningQueueNotice?
        switch job.state {
        case .completed:
            notice = SigningQueueNotice(
                kind: .jobCompleted,
                title: "\(job.applicationName) signed",
                message: "The verified artifact is ready in Exports.",
                jobID: job.id,
                createdAt: now()
            )
        case .failed(let failure):
            notice = SigningQueueNotice(
                kind: .jobFailed,
                title: "\(job.applicationName) failed",
                message: failure.summary,
                jobID: job.id,
                createdAt: now()
            )
        case .queued, .running, .cancelled:
            notice = nil
        }
        guard let notice else { return }
        deliver(notice)
    }

    /// Posts "queue finished" when the last run of a burst settles and no
    /// work remains — a notice about work that ran, never about a list the
    /// user merely cleared.
    private func checkQueueFinished() {
        guard runsSettledSinceIdle > 0 else { return }
        guard !jobs.contains(where: { $0.state.isActive }) else { return }
        let completed = completedJobs.count
        let failed = failedJobs.count
        let cancelled = cancelledJobs.count
        var parts: [String] = []
        if completed > 0 { parts.append("\(completed) signed") }
        if failed > 0 { parts.append("\(failed) failed") }
        if cancelled > 0 { parts.append("\(cancelled) cancelled") }
        runsSettledSinceIdle = 0
        deliver(SigningQueueNotice(
            kind: .queueFinished,
            title: "Queue finished",
            message: parts.isEmpty ? "Every job settled." : parts.joined(separator: " · ") + ".",
            jobID: nil,
            createdAt: now()
        ))
    }

    private func deliver(_ notice: SigningQueueNotice) {
        pendingNotices.append(notice)
        if pendingNotices.count > Self.noticeCapacity {
            pendingNotices.removeFirst(pendingNotices.count - Self.noticeCapacity)
        }
        if let notifier {
            Task { await notifier.notify(notice) }
        }
    }

    // MARK: - Waiting-order insertion

    /// The index a new waiting job of `priority` is inserted at: before the
    /// first waiting job of strictly lower priority, otherwise after every
    /// waiting job. Manual order among equal priorities is preserved — a
    /// new job never jumps ahead of an equal-priority job the user placed.
    private func waitingInsertionIndex(for priority: SigningJobPriority) -> Int {
        let waitingIndices = jobs.indices.filter { jobs[$0].state == .queued }
        if let firstWorse = waitingIndices.first(where: { jobs[$0].priority.sortRank > priority.sortRank }) {
            return firstWorse
        }
        if let lastWaiting = waitingIndices.last {
            return jobs.index(after: lastWaiting)
        }
        return jobs.endIndex
    }

    // MARK: - Request lifecycle

    /// Stores the queue-owned profile copy that lets a waiting job survive
    /// an interruption. The copy is persistence's business; the run reads
    /// the in-memory submission. A copy that finishes after the job was
    /// removed is an orphan the next restoration sweeps.
    private func storeProfileCopy(for id: SigningJobIdentifier, submission: SigningJobSubmission) {
        guard let store else { return }
        // Copies are written only once restoration has recovered the
        // workspace, so recovery can never sweep a copy it has not yet been
        // told about. Jobs accepted during restoration get theirs when it
        // finishes (`storeMissingProfileCopies`).
        guard hasRestored, !isRestoring else { return }
        let profile = submission.profile
        Task { [weak self] in
            guard let fileName = try? await store.storeProfile(profile, jobID: id) else { return }
            guard let self else { return }
            // The job may have settled and been removed while the copy was
            // written; only record it while the submission still stands.
            guard self.submissions[id] != nil else {
                try? await store.removeProfile(fileName: fileName)
                return
            }
            self.profileFileNames[id] = fileName
            self.persist()
        }
    }

    /// Writes the profile copy for every job that holds a submission but no
    /// persisted copy yet — the jobs accepted while restoration was reading.
    private func storeMissingProfileCopies() {
        for (id, submission) in submissions where profileFileNames[id] == nil {
            storeProfileCopy(for: id, submission: submission)
        }
    }

    /// Discards everything the queue holds for a removed job: the
    /// submission, the persisted profile copy, and any task bookkeeping.
    private func discardRequest(for id: SigningJobIdentifier) {
        submissions.removeValue(forKey: id)
        runningTasks[id]?.cancel()
        runningTasks.removeValue(forKey: id)
        if let fileName = profileFileNames.removeValue(forKey: id), let store {
            Task { try? await store.removeProfile(fileName: fileName) }
        }
    }

    // MARK: - Logging

    private func appendLog(_ id: SigningJobIdentifier, _ message: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        appendLog(to: &jobs[index], message)
    }

    private func appendLog(to job: inout Job, _ message: String) {
        job.log.append(SigningJobLogEntry(timestamp: now(), message: message))
        if job.log.count > Self.logCapacity {
            job.log.removeFirst(job.log.count - Self.logCapacity)
        }
    }

    // MARK: - Persistence

    /// Writes the queue's list whenever it changes. Progress ticks are not
    /// changes worth a write: snapshots record states, stages, and setups,
    /// and a restored run starts from its stage boundary honestly.
    private func persist() {
        guard let store else { return }
        // Before restoration has read the persisted queue, writing would
        // overwrite it with a partial list. Restoration persists the merged
        // list once it has read.
        guard hasRestored, !isRestoring else { return }
        revision += 1
        let snapshot = makeSnapshot()
        Task { @MainActor [weak self, store] in
            do {
                try await store.save(snapshot)
                self?.persistenceError = nil
            } catch {
                self?.persistenceError = "The signing queue could not be saved. The in-memory queue remains active; retry before leaving the app."
            }
        }
    }

    private func makeSnapshot() -> SigningQueueSnapshot {
        SigningQueueSnapshot(
            revision: revision,
            savedAt: now(),
            jobs: jobs.map { job in
                var setup: StoredSigningJobSetup?
                if let submission = submissions[job.id] {
                    setup = StoredSigningJobSetup(
                        identityID: submission.identityID.rawValue,
                        identityDisplayName: submission.identityDisplayName,
                        certificateFingerprint: submission.certificateFingerprint,
                        profileFileName: profileFileNames[job.id],
                        profileDisplayName: submission.profileDisplayName,
                        profileTeamIdentifier: submission.profileTeamIdentifier,
                        emitDEREntitlements: submission.emitDEREntitlements,
                        presetID: submission.presetID?.rawValue
                    )
                }
                return StoredSigningJob(
                    id: job.id.rawValue,
                    applicationName: job.applicationName,
                    bundleIdentifier: job.bundleIdentifier,
                    versionText: job.versionText,
                    recordID: job.recordID.rawValue,
                    artifactID: job.artifactID.rawValue,
                    priority: job.priority,
                    origin: job.origin,
                    enqueuedAt: job.enqueuedAt,
                    startedAt: job.startedAt,
                    finishedAt: job.finishedAt,
                    attemptCount: job.attemptCount,
                    state: job.state,
                    lastStageRawValue: job.progress?.stage.rawValue,
                    log: job.log,
                    setup: setup
                )
            }
        )
    }
}

/// Delivers one job's progress reports to the queue.
///
/// The run reports from whichever context it executes on — the pipeline's
/// stage boundaries, the archive machinery — so the sink hands each report
/// to the main actor instead of touching the queue's state directly.
/// Holding the two values it delivers together (the job's identity and the
/// queue) is all it does; it is therefore safe to call from any thread,
/// which is the whole of what `@unchecked Sendable` claims here.
private final class JobProgressSink: SigningJobProgressReporting, @unchecked Sendable {

    private let job: SigningJobIdentifier
    private let queue: SigningQueue

    init(job: SigningJobIdentifier, queue: SigningQueue) {
        self.job = job
        self.queue = queue
    }

    func report(_ progress: SigningJobProgress) {
        Task { @MainActor in
            queue.apply(progress, to: job)
        }
    }
}
