import Foundation

/// The urgency of one piece of background work.
///
/// The lanes are deliberately few. `interactive` is for work the user is
/// waiting on but that must not block the main actor — a thumbnail for a
/// row on screen. `maintenance` is for work nobody is waiting on — a
/// re-index, a cache sweep, a benchmark. `deferred` is for work that should
/// not even start until the launch has settled.
enum BackgroundWorkPriority: Int, Comparable, Hashable, Sendable, CaseIterable {
    case deferred = 0
    case maintenance = 1
    case interactive = 2

    static func < (lhs: BackgroundWorkPriority, rhs: BackgroundWorkPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The task priority the lane runs at. Nothing here runs at
    /// `userInitiated` or above: the main actor keeps the top of the
    /// scheduler to itself.
    var taskPriority: TaskPriority {
        switch self {
        case .interactive: return .utility
        case .maintenance: return .background
        case .deferred: return .background
        }
    }
}

/// Runs expensive work away from the main actor, a bounded number of jobs
/// at a time, in priority order, with coalescing by key.
///
/// **Why a scheduler.** Indexing, thumbnail generation, metadata
/// extraction, cache sweeps, and diagnostics refreshes all compete for the
/// same cores as the interface. Left to themselves, twenty rows appearing
/// at once would start twenty archive reads at once and starve the
/// scroll. The scheduler keeps at most `maximumConcurrentJobs` running,
/// starts the most urgent waiting job first, and lets a caller name a job
/// with a key so a second request for the same work — the same thumbnail,
/// the same re-index — joins the first instead of duplicating it.
///
/// **What it is not.** It is not a queue of user-visible jobs (that is
/// `SigningQueue`), and it never persists anything: a job that has not run
/// when the process ends simply has not run, which is the correct outcome
/// for work whose only purpose is to be ready sooner next time.
///
/// **Cancellation.** Each job runs in its own task; cancelling by key
/// cancels the task, and `cancelAll()` clears the waiting list and cancels
/// the running tasks. Jobs check `Task.isCancelled` at their own
/// boundaries, as they do everywhere else in ZynSign.
actor BackgroundWorkScheduler {

    /// A handle a caller can await for a job's result.
    struct Ticket<Value: Sendable>: Sendable {
        fileprivate let task: Task<Value, Error>

        /// The job's value, or its thrown error.
        var value: Value {
            get async throws { try await task.value }
        }

        /// Cancels the job.
        func cancel() { task.cancel() }
    }

    private struct Waiting {
        let id: UInt64
        let priority: BackgroundWorkPriority
        let enqueuedAt: Date
        let start: @Sendable () -> Void
    }

    /// One scheduled job, from scheduling until it ends.
    private struct Handle {
        let key: String?
        let erased: Task<any Sendable, Error>
        let cancel: @Sendable () -> Void
    }

    /// The most jobs running at once.
    let maximumConcurrentJobs: Int

    private var waiting: [Waiting] = []
    private var runningCount = 0
    private var completedCount = 0
    private var nextID: UInt64 = 0
    private var isPaused = false

    /// Every job not yet finished, by identifier.
    private var handles: [UInt64: Handle] = [:]

    /// The unfinished job for each key, so a repeated request joins it.
    private var inFlightByKey: [String: UInt64] = [:]

    /// Wakes the waiters when the scheduler drains.
    private var drainContinuations: [CheckedContinuation<Void, Never>] = []

    private let now: @Sendable () -> Date

    /// Creates a scheduler that runs at most `maximumConcurrentJobs` jobs
    /// at once. The default keeps two cores' worth of background work in
    /// flight, which fills a scroll with thumbnails without starving it.
    init(maximumConcurrentJobs: Int = 2, now: @escaping @Sendable () -> Date = { Date() }) {
        self.maximumConcurrentJobs = max(1, maximumConcurrentJobs)
        self.now = now
    }

    // MARK: - Observing

    /// How much work the scheduler is carrying.
    var summary: BackgroundWorkSummary {
        BackgroundWorkSummary(runningCount: runningCount, waitingCount: waiting.count, completedCount: completedCount)
    }

    /// Whether nothing is running or waiting.
    var isIdle: Bool { runningCount == 0 && waiting.isEmpty }

    // MARK: - Scheduling

    /// Schedules `operation`.
    ///
    /// When `key` names a job already waiting or running, the returned
    /// ticket joins that job and `operation` is not run again. Otherwise
    /// the job waits until a slot is free, most urgent first and oldest
    /// first within a lane.
    @discardableResult
    func schedule<Value: Sendable>(
        key: String? = nil,
        priority: BackgroundWorkPriority = .maintenance,
        _ operation: @escaping @Sendable () async throws -> Value
    ) -> Ticket<Value> {
        if let key, let existingID = inFlightByKey[key], let existing = handles[existingID] {
            let joined = Task<Value, Error>(priority: priority.taskPriority) {
                let any = try await existing.erased.value
                guard let value = any as? Value else {
                    throw BackgroundWorkError.keyReusedWithDifferentResultType(key: key)
                }
                return value
            }
            return Ticket(task: joined)
        }

        nextID &+= 1
        let id = nextID

        // The job's own task starts suspended on a gate; the scheduler
        // opens the gate when a slot is free. The task exists from the
        // moment of scheduling so the caller can await or cancel it, and
        // cancellation while waiting opens the gate so the task can observe
        // it and end instead of hanging on a slot it will never take.
        let gate = Gate()
        let task = Task<Value, Error>(priority: priority.taskPriority) {
            await withTaskCancellationHandler {
                await gate.wait()
            } onCancel: {
                gate.open()
            }
            try Task.checkCancellation()
            return try await operation()
        }
        let erased = Task<any Sendable, Error>(priority: priority.taskPriority) {
            let value: Value = try await task.value
            return value
        }
        handles[id] = Handle(key: key, erased: erased, cancel: { task.cancel() })
        if let key {
            inFlightByKey[key] = id
        }

        insert(Waiting(id: id, priority: priority, enqueuedAt: now(), start: { gate.open() }))

        // Whether the job runs, fails, or is cancelled while waiting, the
        // slot is released and the key is forgotten when the task ends.
        Task<Void, Never>(priority: priority.taskPriority) { [weak self] in
            _ = try? await task.value
            await self?.finish(id: id)
        }

        startNextIfPossible()
        return Ticket(task: task)
    }

    /// Cancels the waiting or running job for `key`, if any.
    func cancel(key: String) {
        guard let id = inFlightByKey[key], let handle = handles[id] else { return }
        handle.cancel()
    }

    /// Cancels every waiting job and every running job.
    func cancelAll() {
        for handle in handles.values {
            handle.cancel()
        }
    }

    /// Stops starting new jobs until `resume()`; running jobs finish.
    /// Used while the interface is under heavy user interaction.
    func pause() {
        isPaused = true
    }

    /// Starts waiting jobs again.
    func resume() {
        guard isPaused else { return }
        isPaused = false
        startNextIfPossible()
    }

    /// Suspends until nothing is running or waiting. Tests use this;
    /// production code awaits tickets instead.
    func waitUntilIdle() async {
        if isIdle { return }
        await withCheckedContinuation { continuation in
            drainContinuations.append(continuation)
        }
    }

    // MARK: - Private

    private func insert(_ entry: Waiting) {
        // Higher priority first; within a priority, older first.
        let index = waiting.firstIndex { existing in
            existing.priority < entry.priority
        } ?? waiting.endIndex
        waiting.insert(entry, at: index)
    }

    private func startNextIfPossible() {
        while !isPaused, runningCount < maximumConcurrentJobs, !waiting.isEmpty {
            let next = waiting.removeFirst()
            runningCount += 1
            next.start()
        }
    }

    private func finish(id: UInt64) {
        // A job cancelled while still waiting never held a slot.
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            waiting.remove(at: index)
        } else {
            runningCount = max(0, runningCount - 1)
            completedCount += 1
        }
        if let handle = handles.removeValue(forKey: id), let key = handle.key, inFlightByKey[key] == id {
            inFlightByKey[key] = nil
        }
        startNextIfPossible()
        if isIdle {
            let waiters = drainContinuations
            drainContinuations.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
}

/// Failures the scheduler itself can produce.
enum BackgroundWorkError: Error, Equatable {

    /// A key was reused for a job whose result type differs from the job
    /// already in flight under that key.
    case keyReusedWithDifferentResultType(key: String)
}

/// A one-shot latch a suspended task waits on until the scheduler opens
/// it. Thread-safe, so the scheduler can open it from its own executor
/// while the task waits on another.
private final class Gate: @unchecked Sendable {

    private let lock = NSLock()
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume()
    }
}
