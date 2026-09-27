import Foundation
import Combine

/// The Installation Workspace's preparation queue: the job list behind
/// Queue Selected, Verify All, and Prepare All.
///
/// **What a job is.** One application's preparation step — a readiness
/// re-evaluation plus, when the artifact is held, an independent
/// verification of the artifact's own bytes through the same verifier the
/// signing pipeline and the Export Center use. Preparation is read-only
/// work: it writes only the verification result on the export record, and
/// it never signs, never delivers, and never records an installation.
///
/// **Why a queue of its own.** The Signing Queue exists to isolate
/// expensive, stateful signing runs; preparation is cheap, read-only, and
/// safe to run again at any time, so persisting it would persist nothing
/// the user could not redo with one tap. The queue is therefore
/// in-memory and single-flight: one job at a time, in the order asked,
/// each job cancellable at verification's own safe points, and a failed
/// job retryable as a fresh run. The shape — jobs, states, retry failed,
/// clear completed, one-at-a-time scheduling — deliberately mirrors the
/// Signing Queue so the two dashboards read the same way; only the
/// persistence differs, and the workspace says so.
///
/// **Only ready work is queued for delivery.** The queue itself will
/// prepare anything with an export, because establishing readiness is its
/// purpose. The *delivery* actions — starting an attempt, handing off —
/// are the ones the workspace gates on readiness: an application that has
/// not passed readiness is never offered to the delivery flow.
@MainActor
final class InstallationPreparationQueue: ObservableObject {

    /// The work one job performs. Injected, so the queue stays
    /// transport-free: the workspace model supplies the real runner
    /// (readiness plus the independent verifier), tests supply doubles.
    typealias Work = (Job) async throws -> Outcome

    /// One request to prepare an application, before it becomes a job.
    struct Request {
        /// What the job should do.
        let kind: Kind

        /// The library record the job prepares.
        let recordID: ApplicationRecordIdentifier

        /// The export the job verifies, when one exists.
        let exportID: ExportIdentifier?

        /// The application's display name.
        let applicationName: String

        /// The declared bundle identifier.
        let bundleIdentifier: String
    }

    /// What one job does.
    enum Kind: Equatable, Hashable {

        /// Re-evaluate readiness only.
        case readiness

        /// Re-evaluate readiness and independently verify the artifact.
        case fullVerification

        /// The action's name.
        var displayName: String {
            switch self {
            case .readiness: return "Check Readiness"
            case .fullVerification: return "Verify & Prepare"
            }
        }
    }

    /// Where a job sits in its life.
    enum State: Equatable {

        /// Accepted, not yet started.
        case queued

        /// Running now.
        case running

        /// Finished successfully.
        case completed

        /// Finished with a failure. The payload is the fixed-language
        /// explanation the row shows.
        case failed(String)

        /// Cancelled before it ran, or cancelled during verification at
        /// verification's own cancellation point.
        case cancelled

        /// Whether the job still needs the queue's attention.
        var isActive: Bool {
            switch self {
            case .queued, .running: return true
            case .completed, .failed, .cancelled: return false
            }
        }

        /// Whether the job can be retried. A cancelled job was interrupted,
        /// not refused, so it retries too — as a fresh run.
        var isRetryable: Bool {
            switch self {
            case .failed, .cancelled: return true
            case .queued, .running, .completed: return false
            }
        }
    }

    /// One preparation job, as the interface sees it.
    struct Job: Identifiable, Equatable {

        /// The job's stable identity.
        let id: UUID

        /// The library record the job prepares.
        let recordID: ApplicationRecordIdentifier

        /// The export the job verifies, when one exists. A job without one
        /// can only re-evaluate readiness, and its completion says so.
        let exportID: ExportIdentifier?

        /// The application's display name, captured when queued.
        let applicationName: String

        /// The declared bundle identifier.
        let bundleIdentifier: String

        /// What the job does.
        let kind: Kind

        /// When the job was accepted.
        let enqueuedAt: Date

        /// When the current run started, or `nil` before the first run.
        var startedAt: Date?

        /// When the job settled, or `nil` while active.
        var finishedAt: Date?

        /// The lifecycle state.
        var state: State

        /// The one-line outcome, set at settlement: what preparation
        /// established.
        var outcomeSummary: String?

        /// Whether the queue may act on the job right now.
        var isActive: Bool { state.isActive }

        static func == (lhs: Job, rhs: Job) -> Bool {
            lhs.id == rhs.id
                && lhs.state == rhs.state
                && lhs.outcomeSummary == rhs.outcomeSummary
                && lhs.startedAt == rhs.startedAt
                && lhs.finishedAt == rhs.finishedAt
        }
    }

    /// What running one job reports.
    struct Outcome: Equatable {

        /// The fixed-language summary the row keeps, e.g. what readiness
        /// and verification concluded.
        let summary: String

        /// Whether the readiness report that came out of the job is ready
        /// in ZynSign's sense.
        let isReady: Bool
    }

    @Published private(set) var jobs: [Job] = []

    /// Runs one job. Injected, so the queue stays transport-free: the
    /// workspace model supplies the real runner (readiness plus the
    /// independent verifier), tests supply doubles.
    private let work: Work

    /// Whether a run loop is currently draining the queue.
    private var isRunning = false

    /// The drain loop. Cancelling it is never a user action — job
    /// cancellation goes to `runningWork`, so the queue keeps draining.
    private var drainTask: Task<Void, Never>?

    /// The work task of the job currently running. Cancelling this stops
    /// one job at verification's next safe point, exactly like the
    /// signing pipeline's cooperative cancellation.
    private var runningWork: Task<Outcome, Error>?

    init(work: @escaping Work) {
        self.work = work
    }

    // MARK: - Counts

    /// How many jobs are waiting or running.
    var activeCount: Int { jobs.filter(\.isActive).count }

    /// How many jobs failed.
    var failedCount: Int {
        jobs.filter {
            if case .failed = $0.state { return true }
            return false
        }.count
    }

    /// How many jobs completed.
    var completedCount: Int {
        jobs.filter { $0.state == .completed }.count
    }

    // MARK: - Queueing

    /// Queues preparation for one application, unless an active job for the
    /// same record and kind is already in the queue — asking twice does not
    /// enqueue twice.
    @discardableResult
    func enqueue(_ request: Request, now: Date = Date()) -> Job {
        if let existing = jobs.first(where: {
            $0.recordID == request.recordID && $0.kind == request.kind && $0.state.isActive
        }) {
            return existing
        }
        let job = Job(
            id: UUID(),
            recordID: request.recordID,
            exportID: request.exportID,
            applicationName: request.applicationName,
            bundleIdentifier: request.bundleIdentifier,
            kind: request.kind,
            enqueuedAt: now,
            startedAt: nil,
            finishedAt: nil,
            state: .queued,
            outcomeSummary: nil
        )
        jobs.append(job)
        runNextIfIdle()
        return job
    }

    /// Queues preparation for every request, in the order given.
    func enqueueAll(_ requests: [Request], now: Date = Date()) {
        for request in requests {
            enqueue(request, now: now)
        }
    }

    /// Cancels one active job. A running job stops at verification's next
    /// cancellation point and reads `cancelled`; a queued job never
    /// starts. Cancelling one job never touches the others — the queue
    /// keeps draining.
    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[index].state {
        case .queued:
            jobs[index].state = .cancelled
            jobs[index].finishedAt = Date()
        case .running:
            runningWork?.cancel()
        case .completed, .failed, .cancelled:
            return
        }
    }

    /// Cancels every active job.
    func cancelAll() {
        for job in jobs where job.isActive {
            cancel(job.id)
        }
    }

    /// Retries one retryable job as a fresh run: state reset, attempt
    /// counted from the queue's own log of it, no partial state continued.
    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard jobs[index].state.isRetryable else { return }
        jobs[index].state = .queued
        jobs[index].startedAt = nil
        jobs[index].finishedAt = nil
        jobs[index].outcomeSummary = nil
        runNextIfIdle()
    }

    /// Retries every retryable job, oldest first.
    func retryFailed() {
        for job in jobs where job.state.isRetryable {
            retry(job.id)
        }
    }

    /// Removes every settled job from the list. The verification results a
    /// completed job wrote stay on the export records — clearing the list
    /// never un-verifies anything.
    func clearSettled() {
        jobs.removeAll { !$0.isActive }
    }

    // MARK: - Scheduling

    /// Starts the run loop when the queue is idle and something is waiting.
    private func runNextIfIdle() {
        guard !isRunning else { return }
        guard jobs.contains(where: { $0.state == .queued }) else { return }
        isRunning = true
        drainTask = Task { [weak self] in
            await self?.drainQueue()
            self?.isRunning = false
            self?.drainTask = nil
        }
    }

    /// Runs waiting jobs one at a time, in the order they were asked for.
    /// A running job is never preempted by a later enqueue, and cancelling
    /// one job — through `runningWork` — never stops the loop: the next
    /// waiting job starts when the cancelled one settles.
    private func drainQueue() async {
        while let index = jobs.firstIndex(where: { $0.state == .queued }) {
            guard !Task.isCancelled else { break }
            jobs[index].state = .running
            jobs[index].startedAt = Date()
            let job = jobs[index]
            // The work runs in its own task so cancellation targets one
            // job. The work honours it at verification's own safe points,
            // which is the only cancellation the queue claims.
            let runner = Task { [work] in
                try await work(job)
            }
            runningWork = runner
            do {
                let outcome = try await runner.value
                if let index = jobs.firstIndex(where: { $0.id == job.id }), jobs[index].state == .running {
                    jobs[index].state = .completed
                    jobs[index].outcomeSummary = outcome.summary
                    jobs[index].finishedAt = Date()
                }
            } catch is CancellationError {
                if let index = jobs.firstIndex(where: { $0.id == job.id }), jobs[index].state == .running {
                    jobs[index].state = .cancelled
                    jobs[index].outcomeSummary = "Cancelled"
                    jobs[index].finishedAt = Date()
                }
            } catch {
                if let index = jobs.firstIndex(where: { $0.id == job.id }), jobs[index].state == .running {
                    jobs[index].state = .failed((error as? ZynSignError)?.userMessage ?? "Preparation could not finish.")
                    jobs[index].outcomeSummary = nil
                    jobs[index].finishedAt = Date()
                }
            }
            runningWork = nil
        }
    }
}
