import Foundation

/// What one stage of a signing run has established so far.
enum SigningEngineStageState: String, CaseIterable, Hashable, Sendable {

    /// The stage has not started.
    case pending

    /// The stage is running.
    case active

    /// The stage finished successfully.
    case completed

    /// The stage had no work to do, and that is the whole truth about it —
    /// a bundle with no dynamic libraries reports its dynamic-library stage
    /// as skipped rather than as work that happened.
    case skipped

    /// The stage failed or refused the run. The run stops here.
    case failed

    /// Whether the stage is finished, however it finished.
    var isFinished: Bool {
        switch self {
        case .pending, .active: return false
        case .completed, .skipped, .failed: return true
        }
    }

    /// Whether the stage succeeded. A skipped stage is not a success claim
    /// about work: it is a claim that nothing needed doing.
    var isSuccessful: Bool { self == .completed }
}

/// One stage's state inside a progress snapshot.
struct SigningEngineStageRecord: Equatable, Sendable {

    /// The stage this record describes.
    let stage: SigningEngineStage

    /// The stage's state.
    let state: SigningEngineStageState

    /// How many of the stage's items are done. For the nested signing stages
    /// this counts signed binaries; for every other stage it is either zero
    /// or one.
    let completedItemCount: Int

    /// How many items the stage has, when its work is countable. Zero for
    /// stages that are not item-based.
    let totalItemCount: Int

    /// The most recent detail the stage reported, if any. Bounded text for
    /// diagnostics and the interface; never key material, profile content, or
    /// user data.
    let detail: String?

    /// The stage's own fraction complete, counting item progress inside the
    /// stage.
    var fraction: Double {
        guard state != .pending else { return 0 }
        if totalItemCount > 0 {
            return min(1, Double(completedItemCount) / Double(totalItemCount))
        }
        return state == .active ? 0.5 : 1
    }
}

/// A complete, immutable progress snapshot for one signing run.
///
/// The snapshot is derived state: it carries no bytes, no paths into the
/// working copy, and no signing material. It exists so the interface and
/// VoiceOver can render the run from one value, and so tests can assert the
/// run's shape without a UI.
struct SigningEngineProgress: Equatable, Sendable {

    /// One record per stage, in execution order.
    let records: [SigningEngineStageRecord]

    /// The stage the run is executing, or the stage that failed. `nil` once
    /// the run has completed every stage.
    let currentStage: SigningEngineStage?

    /// The current stage's most recent detail line.
    let detail: String

    /// How much of the run's work is done, from zero to one.
    let fractionCompleted: Double

    /// How long the run has been executing.
    let elapsed: TimeInterval

    /// How much longer the run is estimated to take, once enough of it has
    /// completed for an estimate to mean anything. `nil` when it is too early
    /// or the run has finished.
    let estimatedRemaining: TimeInterval?

    /// Whether the run finished every stage.
    var isComplete: Bool { records.allSatisfy { $0.state.isSuccessful || $0.state == .skipped } }

    /// Whether any stage failed.
    var hasFailed: Bool { records.contains { $0.state == .failed } }

    /// The record for one stage.
    func record(for stage: SigningEngineStage) -> SigningEngineStageRecord? {
        records.first { $0.stage == stage }
    }

    /// The state of one stage.
    func state(of stage: SigningEngineStage) -> SigningEngineStageState {
        record(for: stage)?.state ?? .pending
    }

    /// The estimated remaining work in whole seconds, for display. `nil` when
    /// no estimate exists; never a negative or sub-second value.
    var estimatedRemainingSeconds: Int? {
        guard let estimatedRemaining, estimatedRemaining >= 1 else { return nil }
        return Int(estimatedRemaining.rounded())
    }

    /// A spoken description of the run's position, for VoiceOver. It names
    /// the stage and the percentage, and the estimate when one exists.
    var accessibilityDescription: String {
        var parts: [String] = []
        if isComplete {
            parts.append("Signing complete")
        } else if let currentStage {
            parts.append("Signing stage: \(currentStage.title)")
        } else {
            parts.append("Signing not started")
        }
        parts.append("\(Int((fractionCompleted * 100).rounded())) percent complete")
        if !detail.isEmpty { parts.append(detail) }
        if let seconds = estimatedRemainingSeconds { parts.append("about \(seconds) seconds remaining") }
        return parts.joined(separator: ", ")
    }
}

/// The progress tracker one signing run drives.
///
/// The tracker is deliberately reference-typed and free of I/O: the
/// coordinator's pipeline observer reports into it from synchronous callbacks,
/// and the same instance produces the snapshot the interface renders. It
/// holds no more state than the stage records themselves — no bytes, no
/// paths, no cached signing results.
final class SigningEngineProgressTracker {

    private var states: [SigningEngineStage: SigningEngineStageState] = [:]
    private var details: [SigningEngineStage: String] = [:]
    private var completedItems: [SigningEngineStage: Int] = [:]
    private var totalItems: [SigningEngineStage: Int] = [:]
    private var current: SigningEngineStage?

    /// How long a run must have been executing before an estimate is offered.
    static let minimumElapsedForEstimate: TimeInterval = 0.4

    /// How much of the run must be complete before an estimate is offered.
    static let minimumFractionForEstimate: Double = 0.1

    init() {
        for stage in SigningEngineStage.allCases {
            states[stage] = .pending
            completedItems[stage] = 0
            totalItems[stage] = 0
        }
    }

    // MARK: - Stage transitions

    /// Marks a stage as running. A previous stage that was still active is
    /// completed first: a run that has moved on has finished what it was
    /// doing.
    func begin(_ stage: SigningEngineStage) {
        if let previous = current, previous != stage, states[previous] == .active {
            states[previous] = .completed
        }
        current = stage
        if states[stage] != .failed {
            states[stage] = .active
        }
    }

    /// Marks a stage as completed successfully.
    func complete(_ stage: SigningEngineStage) {
        states[stage] = .completed
        if current == stage { current = nil }
    }

    /// Marks a stage as having no work to do.
    func skip(_ stage: SigningEngineStage, reason: String? = nil) {
        states[stage] = .skipped
        if let reason { details[stage] = reason }
        if current == stage { current = nil }
    }

    /// Marks a stage as failed and makes it the current stage.
    func fail(_ stage: SigningEngineStage, detail: String?) {
        states[stage] = .failed
        if let detail { details[stage] = detail }
        current = stage
    }

    /// Records a detail line for a stage.
    func note(_ detail: String, at stage: SigningEngineStage) {
        details[stage] = detail
    }

    // MARK: - Nested item progress

    /// Records how many nested items each kind contributes, before signing
    /// begins. Totals are set once, from the validated plan, so the interface
    /// shows accurate counts from the first item.
    func setNestedTotals(_ totals: [NestedCodeKind: Int]) {
        for stage in SigningEngineStage.allCases where stage.isNestedSigningStage {
            guard let kind = stage.nestedCodeKind else { continue }
            let total = totals[kind] ?? 0
            totalItems[stage] = total
            completedItems[stage] = 0
            states[stage] = total == 0 ? .skipped : .pending
            if total == 0 {
                details[stage] = "No \(Self.itemNoun(for: kind)) in this bundle"
            }
        }
    }

    /// Records that the item at `order` of `kind` has begun signing.
    func beginNestedItem(kind: NestedCodeKind, path: BundlePath, order: Int, total: Int) {
        guard let stage = SigningEngineStage.nestedSigningStage(for: kind) else { return }
        if totalItems[stage] ?? 0 < total { totalItems[stage] = total }
        if states[stage] != .completed && states[stage] != .failed {
            states[stage] = .active
        }
        current = stage
        details[stage] = "Signing \(path.rawValue) (\(order) of \(total))"
    }

    /// Records that the item at `order` of `kind` finished signing.
    func completeNestedItem(kind: NestedCodeKind, path: BundlePath, order: Int, total: Int) {
        guard let stage = SigningEngineStage.nestedSigningStage(for: kind) else { return }
        if totalItems[stage] ?? 0 < total { totalItems[stage] = total }
        completedItems[stage] = max(completedItems[stage] ?? 0, order)
        if completedItems[stage] == totalItems[stage] && totalItems[stage] != 0 {
            states[stage] = .completed
        } else {
            states[stage] = .active
        }
        details[stage] = "Signed \(path.rawValue)"
    }

    /// Records that signing one nested item refused the run.
    func refuseNestedItem(kind: NestedCodeKind, path: BundlePath, detail: String) {
        guard let stage = SigningEngineStage.nestedSigningStage(for: kind) else { return }
        states[stage] = .failed
        current = stage
        details[stage] = "Refused \(path.rawValue): \(detail)"
    }

    // MARK: - Snapshot

    /// Builds the snapshot for the run so far.
    ///
    /// - Parameter elapsed: How long the run has been executing. Supplied by
    ///   the caller so the tracker stays free of clocks and stays testable.
    func snapshot(elapsed: TimeInterval) -> SigningEngineProgress {
        var records: [SigningEngineStageRecord] = []
        records.reserveCapacity(SigningEngineStage.allCases.count)
        var completedWeight = 0.0
        for stage in SigningEngineStage.allCases {
            let state = states[stage] ?? .pending
            let completed = completedItems[stage] ?? 0
            let total = totalItems[stage] ?? 0
            records.append(SigningEngineStageRecord(
                stage: stage,
                state: state,
                completedItemCount: completed,
                totalItemCount: total,
                detail: details[stage]
            ))
            switch state {
            case .completed, .skipped, .failed:
                if state != .failed {
                    completedWeight += stage.weight
                }
            case .active, .pending:
                let fraction: Double
                if total > 0 {
                    fraction = min(1, Double(completed) / Double(total))
                } else {
                    fraction = 0
                }
                completedWeight += stage.weight * fraction
            }
        }
        let fraction = min(1, max(0, completedWeight))
        var estimate: TimeInterval?
        if fraction >= Self.minimumFractionForEstimate,
           elapsed >= Self.minimumElapsedForEstimate,
           fraction < 1 {
            estimate = elapsed * (1 - fraction) / fraction
        }
        let currentDetail = current.flatMap { details[$0] } ?? ""
        return SigningEngineProgress(
            records: records,
            currentStage: current,
            detail: currentDetail,
            fractionCompleted: fraction,
            elapsed: elapsed,
            estimatedRemaining: estimate
        )
    }

    /// The noun the interface uses for one nested kind, singular.
    static func itemNoun(for kind: NestedCodeKind) -> String {
        switch kind {
        case .application: return "nested applications"
        case .framework: return "frameworks"
        case .dynamicLibrary: return "dynamic libraries"
        case .applicationExtension: return "extensions"
        }
    }
}
