import Foundation

/// The outcome of one queued signing step, as the queue shows it.
enum SigningQueueStepOutcome: Equatable, Sendable {
    case succeeded(outputFileName: String)
    case failed(message: String)
    case cancelled
}

/// Identifiers the queue is allowed to run. The attention set is excluded
/// even if a caller also put those identifiers in `requests`.
enum SigningQueueAdmission {
    static func runnableIDs(in plan: PresetBulkPlan) -> Set<String> {
        Set(plan.compatible.map(\.id)).subtracting(plan.needsAttention.map(\.id))
    }

    static func refusedIDs(requests: Set<String>, plan: PresetBulkPlan) -> [String] {
        let allowed = runnableIDs(in: plan)
        return requests.filter { !allowed.contains($0) }.sorted()
    }
}

/// Admission checks for a preset plan, kept for tests.
///
/// The interface does not drive this type. After confirmation and the app
/// lock, compatible apps are enqueued on `SigningQueue`. `stage` still
/// refuses an attention-set identifier, and `confirmAndStart` still runs
/// only waiting jobs, so those refusals can be tested without the job queue.
/// Incompatible apps are not forced through.
@MainActor
final class ProfessionalSigningQueue: ObservableObject {

    struct Job: Identifiable, Equatable {
        enum State: Equatable {
            case waiting
            case needsAttention(reasons: [String])
            case running
            case succeeded(outputFileName: String)
            case failed(message: String)
            case cancelled

            var canRun: Bool {
                if case .waiting = self { return true }
                return false
            }
        }

        let id: String
        let displayName: String
        let bundleIdentifier: String
        var state: State
    }

    enum Phase: Equatable {
        case idle
        case review
        case running
        case finished
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var presetName: String?
    @Published private(set) var presetID: PresetIdentifier?
    @Published private(set) var errorMessage: String?

    private let runner: (SigningQueueStepRequest) async -> SigningQueueStepOutcome
    private let recordOutcome: (PresetUseOutcome) async -> Void
    private var requests: [String: SigningQueueStepRequest] = [:]
    private var cancelRequested = false

    /// `runner` performs one already-confirmed, already-compatible step.
    /// `recordOutcome` updates the preset's lightweight history. Neither is
    /// called from `stage`.
    init(
        runner: @escaping (SigningQueueStepRequest) async -> SigningQueueStepOutcome,
        recordOutcome: @escaping (PresetUseOutcome) async -> Void = { _ in }
    ) {
        self.runner = runner
        self.recordOutcome = recordOutcome
    }

    var compatibleCount: Int { jobs.filter { $0.state.canRun || isActive($0.state) }.count }
    var attentionCount: Int {
        jobs.filter {
            if case .needsAttention = $0.state { return true }
            return false
        }.count
    }

    /// Shows the plan and holds the requests for compatible apps. Does not
    /// call the runner. Throws, and leaves the queue idle, when a request
    /// belongs to an app the plan says needs manual attention.
    func stage(plan: PresetBulkPlan, requests prepared: [String: SigningQueueStepRequest]) throws {
        guard phase != .running else {
            throw ZynSignError.presetNotReady(
                userMessage: "A signing queue is already running."
            )
        }
        let refused = SigningQueueAdmission.refusedIDs(requests: Set(prepared.keys), plan: plan)
        if !refused.isEmpty {
            throw ZynSignError.presetQueueRefusedIncompatible(
                diagnosticDetail: "Refused incompatible applications: \(refused.joined(separator: ", "))."
            )
        }
        let allowed = SigningQueueAdmission.runnableIDs(in: plan)
        for id in prepared.keys where !allowed.contains(id) {
            throw ZynSignError.presetQueueRefusedIncompatible(
                diagnosticDetail: "Request \(id) is not in the compatible set."
            )
        }
        var staged: [Job] = []
        staged.reserveCapacity(plan.compatible.count + plan.needsAttention.count)
        for item in plan.compatible where allowed.contains(item.id) {
            guard prepared[item.id] != nil else {
                throw ZynSignError.presetNotReady(
                    userMessage: "ZynSign could not prepare “\(item.displayName)” for signing, so nothing was queued."
                )
            }
            staged.append(Job(
                id: item.id,
                displayName: item.displayName,
                bundleIdentifier: item.bundleIdentifier,
                state: .waiting
            ))
        }
        for item in plan.needsAttention {
            staged.append(Job(
                id: item.id,
                displayName: item.displayName,
                bundleIdentifier: item.bundleIdentifier,
                state: .needsAttention(reasons: item.reasons)
            ))
        }
        requests = prepared.filter { allowed.contains($0.key) }
        jobs = staged
        presetName = plan.presetName
        presetID = plan.presetID
        errorMessage = nil
        cancelRequested = false
        phase = .review
    }

    /// The final confirmation. No-op unless the queue is showing a review
    /// the user has not started. Attention jobs are not started. Awaiting
    /// this method waits until every waiting job has been handed to the
    /// runner or cancelled.
    func confirmAndStart() async {
        guard phase == .review else { return }
        guard jobs.contains(where: { $0.state.canRun }) else { return }
        phase = .running
        cancelRequested = false
        await runWaitingJobs()
    }

    func cancelRemaining() {
        cancelRequested = true
        guard phase == .running || phase == .review else { return }
        for index in jobs.indices where jobs[index].state.canRun {
            jobs[index].state = .cancelled
        }
        if phase == .review {
            phase = .finished
        }
    }

    func reset() {
        guard phase != .running else { return }
        phase = .idle
        jobs = []
        requests = [:]
        presetName = nil
        presetID = nil
        errorMessage = nil
        cancelRequested = false
    }

    private func runWaitingJobs() async {
        for index in jobs.indices {
            if cancelRequested {
                if jobs[index].state.canRun {
                    jobs[index].state = .cancelled
                }
                continue
            }
            guard jobs[index].state.canRun else { continue }
            let id = jobs[index].id
            guard let prepared = requests[id] else {
                jobs[index].state = .failed(message: "This application was not prepared, so it was not signed.")
                continue
            }
            jobs[index].state = .running
            let outcome = await runner(prepared)
            switch outcome {
            case .succeeded(let fileName):
                jobs[index].state = .succeeded(outputFileName: fileName)
                await record(prepared, result: .succeeded)
            case .failed(let message):
                jobs[index].state = .failed(message: message)
                await record(prepared, result: .failed)
            case .cancelled:
                jobs[index].state = .cancelled
                await record(prepared, result: .cancelled)
            }
        }
        phase = .finished
    }

    private func record(_ prepared: SigningQueueStepRequest, result: PresetUseOutcome.Result) async {
        let outcome = PresetUseOutcome(
            presetID: prepared.presetID,
            result: result,
            bundleIdentifier: prepared.entry.record.bundleIdentifier.rawValue,
            displayName: prepared.entry.record.displayName,
            at: Date()
        )
        await recordOutcome(outcome)
    }

    private func isActive(_ state: Job.State) -> Bool {
        switch state {
        case .running, .succeeded, .failed, .cancelled: return true
        case .waiting, .needsAttention: return false
        }
    }
}
