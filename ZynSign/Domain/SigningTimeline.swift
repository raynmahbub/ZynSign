import Foundation

/// One stage of a signing operation, in the order the operation runs them.
///
/// These are the stages the product shows. They are not the pipeline's
/// internal steps: several pipeline steps belong to one stage, and that
/// grouping is stated once, in `SigningOperationCenter.pipelineStage(for:)`,
/// so a failure report and the interface can never disagree about which stage
/// a failure happened in.
enum SigningOperationStage: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {

    /// The package the operation signs was taken from the library. The stage
    /// completes when the library holds bytes for it; nothing is re-imported.
    case importSource

    /// The container's structure, bundle metadata, and executable are
    /// established and checked.
    case validation

    /// The identity, the provisioning profile, and the entitlements are held
    /// against each other before anything is signed.
    case preflight

    /// Nested code is discovered, extracted, and signed inside the working
    /// copy.
    case nestedSigning

    /// The working copy's resources are sealed and the main executable is
    /// signed against that seal.
    case mainSigning

    /// The produced container is verified against the run's expectations.
    case verification

    /// The working copy is rebuilt as a container.
    case packaging

    /// The produced container is named, delivered to the Export Center, and
    /// independently verified.
    case export

    var id: Self { self }

    /// The stage's name as the timeline shows it.
    var displayName: String {
        switch self {
        case .importSource: return "Import"
        case .validation: return "Validation"
        case .preflight: return "Preflight"
        case .nestedSigning: return "Nested Signing"
        case .mainSigning: return "Main Signing"
        case .verification: return "Verification"
        case .packaging: return "Packaging"
        case .export: return "Export"
        }
    }

    /// What the stage does, in one sentence.
    var explanation: String {
        switch self {
        case .importSource:
            return "The package ZynSign holds for this application is taken as the operation's input."
        case .validation:
            return "The container's structure, its bundle information, and its executable are checked."
        case .preflight:
            return "The signing identity, the provisioning profile, and the entitlements are held against each other."
        case .nestedSigning:
            return "Nested frameworks, extensions, and libraries are discovered and signed in dependency order."
        case .mainSigning:
            return "The bundle's resources are sealed and the main executable is signed against the seal."
        case .verification:
            return "The produced container is reopened and checked against what the run established."
        case .packaging:
            return "The signed working copy is rebuilt as a container."
        case .export:
            return "The finished container is named, added to the Export Center, and verified independently."
        }
    }

    /// The stage's position in the order.
    var order: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    /// The stages that come after this one.
    var subsequentStages: [SigningOperationStage] {
        Array(Self.allCases.dropFirst(order + 1))
    }
}

/// How one stage of an operation ended.
enum SigningStageStatus: String, Codable, CaseIterable, Hashable, Sendable {

    /// The stage ran to completion.
    case succeeded

    /// The stage refused the operation or failed.
    case failed

    /// The operation was cancelled while the stage was in flight.
    case cancelled

    /// The stage was never reached, because the operation stopped before it.
    case notRun

    /// The mark the timeline shows.
    var displayMark: String {
        switch self {
        case .succeeded: return "✓"
        case .failed: return "✕"
        case .cancelled: return "⊘"
        case .notRun: return "—"
        }
    }

    /// The status name, as the timeline and VoiceOver read it.
    var displayName: String {
        switch self {
        case .succeeded: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .notRun: return "Not reached"
        }
    }

    /// Whether the stage reached a conclusion. A stage that succeeded,
    /// failed, or was cancelled concluded; a stage not reached did not.
    var isConcluded: Bool {
        self == .succeeded || self == .failed || self == .cancelled
    }

    /// Whether the stage ended the operation.
    var isStopping: Bool {
        self == .failed || self == .cancelled
    }
}

/// One stage of one operation, as it actually happened.
struct SigningTimelineEntry: Codable, Equatable, Hashable, Sendable {

    /// The stage.
    let stage: SigningOperationStage

    /// How the stage ended.
    let status: SigningStageStatus

    /// When the stage began, when the operation recorded it.
    let startedAt: Date?

    /// When the stage concluded. `nil` when the stage was never reached, and
    /// for entries restored from a record that never captured a time.
    let finishedAt: Date?

    /// Fixed-language context for the stage: what it established, or why it
    /// stopped. Never carries a key, a profile body, a password, or an
    /// absolute path.
    let detail: String?

    init(
        stage: SigningOperationStage,
        status: SigningStageStatus,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        detail: String? = nil
    ) {
        self.stage = stage
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.detail = detail
    }

    /// How long the stage took, when both ends were recorded.
    var duration: TimeInterval? {
        guard let startedAt, let finishedAt, finishedAt >= startedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }

    /// The line the timeline shows beside the stage name.
    var summary: String {
        if let detail, !detail.isEmpty { return detail }
        return status.displayName
    }
}

/// A whole operation's stages: every stage in order, with the ones the
/// operation never reached reading "not reached" rather than being absent.
///
/// The timeline is always complete. An operation that failed at preflight
/// says so about preflight and says "not reached" about everything after it,
/// which is what makes a failure immediately readable: nothing is silently
/// missing, and nothing that did not happen is shown as if it had.
struct SigningTimeline: Equatable, Sendable {

    /// Every stage's entry, in stage order. Always one entry per stage.
    let entries: [SigningTimelineEntry]

    /// Builds a timeline from whatever entries were recorded, filling every
    /// unrecorded stage with "not reached".
    ///
    /// The first entry for a stage wins: a stage is described by the report
    /// that concluded it, so a later report can never turn a failure into a
    /// success.
    init(entries: [SigningTimelineEntry]) {
        var byStage: [SigningOperationStage: SigningTimelineEntry] = [:]
        for entry in entries where byStage[entry.stage] == nil {
            byStage[entry.stage] = entry
        }
        self.entries = SigningOperationStage.allCases.map { stage in
            byStage[stage] ?? SigningTimelineEntry(stage: stage, status: .notRun)
        }
    }

    /// A timeline in which every stage completed.
    static func completed(
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        details: [SigningOperationStage: String] = [:]
    ) -> SigningTimeline {
        SigningTimeline(entries: SigningOperationStage.allCases.map { stage in
            SigningTimelineEntry(
                stage: stage,
                status: .succeeded,
                startedAt: startedAt,
                finishedAt: finishedAt,
                detail: details[stage]
            )
        })
    }

    /// The timeline an operation that reached `stages` and then stopped has.
    ///
    /// The stages that ran are marked completed, the stopping stage carries
    /// `stopStatus` and the explanation, and every stage after it is "not
    /// reached". This is the truthful shape for an operation whose per-stage
    /// timestamps were not captured: it states what happened and what did
    /// not, without inventing times.
    static func stopped(
        after stages: [SigningOperationStage],
        stopStatus: SigningStageStatus,
        at stopStage: SigningOperationStage?,
        detail: String? = nil
    ) -> SigningTimeline {
        let reached = Set(stages)
        let stopOrder = stopStage?.order ?? Int.max
        var entries: [SigningTimelineEntry] = []
        for stage in SigningOperationStage.allCases {
            if stage == stopStage {
                entries.append(SigningTimelineEntry(stage: stage, status: stopStatus, detail: detail))
            } else if stage.order < stopOrder, reached.contains(stage) {
                entries.append(SigningTimelineEntry(stage: stage, status: .succeeded))
            } else if stage.order < stopOrder, stopStage == nil {
                entries.append(SigningTimelineEntry(stage: stage, status: .succeeded))
            } else {
                entries.append(SigningTimelineEntry(stage: stage, status: .notRun))
            }
        }
        return SigningTimeline(entries: entries)
    }

    /// One stage's entry. Always present.
    func entry(for stage: SigningOperationStage) -> SigningTimelineEntry {
        entries.first { $0.stage == stage }
            ?? SigningTimelineEntry(stage: stage, status: .notRun)
    }

    /// One stage's status. Always present.
    func status(of stage: SigningOperationStage) -> SigningStageStatus {
        entry(for: stage).status
    }

    /// The stage the operation stopped at: the failure or cancellation, when
    /// one was recorded.
    var stoppingStage: SigningOperationStage? {
        entries.first { $0.status.isStopping }?.stage
    }

    /// The stage the operation failed at, when it failed.
    var failedStage: SigningOperationStage? {
        entries.first { $0.status == .failed }?.stage
    }

    /// The stage the operation was cancelled during, when it was cancelled.
    var cancelledStage: SigningOperationStage? {
        entries.first { $0.status == .cancelled }?.stage
    }

    /// The stages that completed.
    var completedStages: [SigningOperationStage] {
        entries.filter { $0.status == .succeeded }.map(\.stage)
    }

    /// The stages that were never reached.
    var unreachedStages: [SigningOperationStage] {
        entries.filter { $0.status == .notRun }.map(\.stage)
    }

    /// The last stage that reached a conclusion.
    var lastConcludedStage: SigningOperationStage? {
        entries.last { $0.status.isConcluded }?.stage
    }

    /// The number of stages that completed.
    var completedStageCount: Int { completedStages.count }

    /// Whether every stage completed.
    var isComplete: Bool {
        completedStages.count == SigningOperationStage.allCases.count
    }

    /// Whether the timeline records a failure.
    var hasFailure: Bool { failedStage != nil }

    /// The one-line summary the operation detail shows beside the timeline.
    var summary: String {
        if let stopping = entries.first(where: { $0.status.isStopping }) {
            return "\(stopping.stage.displayName) — \(stopping.status.displayName)"
        }
        if isComplete { return "Every stage completed" }
        return "\(completedStages.count) of \(SigningOperationStage.allCases.count) stages completed"
    }
}

/// Accumulates stage reports into a timeline.
///
/// The recorder is deliberately conservative about conclusions: the first
/// report that concludes a stage is the one that stands, a stage that was
/// never reported reads "not reached" rather than being inferred, and a
/// failure is never upgraded or removed. It is a value type with mutating
/// methods, so a caller decides where it lives — a run's own task, an actor,
/// or a lock-guarded box.
struct SigningTimelineRecorder {

    /// The entries recorded so far, in the order the stages were reported.
    private var order: [SigningOperationStage] = []
    private var entries: [SigningOperationStage: SigningTimelineEntry] = [:]

    /// Creates an empty recorder.
    init() {}

    /// The stages reported so far, in report order.
    var reportedStages: [SigningOperationStage] { order }

    /// Records that a stage began. A stage that already concluded is left
    /// alone: its conclusion is the fact worth keeping.
    mutating func began(_ stage: SigningOperationStage, at instant: Date) {
        guard entries[stage]?.status.isConcluded != true else { return }
        if entries[stage] == nil { order.append(stage) }
        entries[stage] = SigningTimelineEntry(
            stage: stage,
            status: entries[stage]?.status ?? .notRun,
            startedAt: entries[stage]?.startedAt ?? instant,
            finishedAt: entries[stage]?.finishedAt,
            detail: entries[stage]?.detail
        )
    }

    /// Records that a stage completed.
    mutating func finished(_ stage: SigningOperationStage, at instant: Date, detail: String? = nil) {
        record(stage, status: .succeeded, at: instant, detail: detail)
    }

    /// Records that a stage failed.
    mutating func failed(_ stage: SigningOperationStage, at instant: Date, detail: String? = nil) {
        record(stage, status: .failed, at: instant, detail: detail)
    }

    /// Records that a stage was cancelled mid-flight.
    mutating func cancelled(_ stage: SigningOperationStage, at instant: Date, detail: String? = nil) {
        record(stage, status: .cancelled, at: instant, detail: detail)
    }

    /// Records that a stage reached a conclusion. Convenience for callers
    /// that hold a status rather than an outcome.
    mutating func completed(_ stage: SigningOperationStage, at instant: Date, detail: String? = nil) {
        record(stage, status: .succeeded, at: instant, detail: detail)
    }

    /// Marks a stage as never reached, with an explanation.
    ///
    /// A stage that already concluded is left alone: "not reached" describes
    /// what did not happen, and it can never overwrite what did.
    mutating func notRun(_ stage: SigningOperationStage, detail: String? = nil) {
        guard entries[stage]?.status.isConcluded != true else { return }
        if entries[stage] == nil { order.append(stage) }
        entries[stage] = SigningTimelineEntry(stage: stage, status: .notRun, detail: detail)
    }

    /// The timeline built from what was recorded. Every stage the recorder
    /// never saw reads "not reached".
    func build() -> SigningTimeline {
        SigningTimeline(entries: order.compactMap { entries[$0] })
    }

    private mutating func record(
        _ stage: SigningOperationStage,
        status: SigningStageStatus,
        at instant: Date,
        detail: String?
    ) {
        guard entries[stage]?.status.isConcluded != true else { return }
        let startedAt = entries[stage]?.startedAt
        if entries[stage] == nil { order.append(stage) }
        entries[stage] = SigningTimelineEntry(
            stage: stage,
            status: status,
            startedAt: startedAt,
            finishedAt: instant,
            detail: detail
        )
    }
}
