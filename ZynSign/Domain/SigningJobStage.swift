import Foundation

/// The stages one signing job moves through, in the order it moves through
/// them.
///
/// The stages are the nine-stage signing pipeline seen from the queue: the
/// pipeline's own stages (integrity, profile, discovery, extraction, nested
/// signing, resource sealing, main-executable signing, packaging,
/// verification) are grouped into the coarser units a person watches — the
/// two lightweight validation stages become one preflight, discovery and
/// extraction become one extraction, sealing and the main executable become
/// one "signing app" stage. The mapping is fixed and honest: a job reports
/// a stage when the pipeline actually begins the work behind it, never to
/// make progress look smoother than it is.
///
/// Each stage carries a weight, so a determinate overall progress value can
/// be derived from the stage a job has reached. The weights follow where the
/// work actually is for a typical container: extraction and the two signing
/// stages dominate, validation and verification are bounded work.
///
/// `completed` is the terminal success stage and measures no work of its
/// own; failure and cancellation are states, not stages — a failed job keeps
/// the stage it stopped at.
enum SigningJobStage: String, CaseIterable, Hashable, Sendable, Codable {

    /// The job's inputs are being resolved: the package file is located, the
    /// entitlement set is derived from the profile, and the output location
    /// is prepared.
    case preparing

    /// The container's structure, metadata, and the replacement profile are
    /// being validated before any heavy work starts (the pipeline's
    /// integrity and profile stages).
    case preflight

    /// Nested code is being discovered and the container is being extracted
    /// to the job's own isolated working copy (the pipeline's discovery and
    /// extraction stages).
    case extraction

    /// Every nested framework, extension, and dylib is being signed inside
    /// the working copy (the pipeline's nested-signing stage).
    case signingFrameworks

    /// The working copy's resources are being sealed and the main executable
    /// is being signed (the pipeline's sealing and main-executable stages).
    case signingApp

    /// The signed working copy is being rebuilt as a deterministic container
    /// (the pipeline's packaging stage).
    case packaging

    /// The rebuilt container is being independently verified against the
    /// run's expectations (the pipeline's verification stage).
    case verification

    /// Every stage passed and the verified container was delivered. A
    /// terminal stage; it measures no work of its own.
    case completed

    /// The stages in pipeline order.
    static var ordered: [SigningJobStage] { allCases }

    /// The user-presentable name of the stage, phrased as work in progress.
    var displayName: String {
        switch self {
        case .preparing: return "Preparing"
        case .preflight: return "Preflight Validation"
        case .extraction: return "Extracting Working Copy"
        case .signingFrameworks: return "Signing Frameworks"
        case .signingApp: return "Signing App"
        case .packaging: return "Packaging"
        case .verification: return "Verification"
        case .completed: return "Completed"
        }
    }

    /// The short name used where space is tight, such as a progress caption.
    var shortName: String {
        switch self {
        case .preparing: return "Preparing"
        case .preflight: return "Preflight"
        case .extraction: return "Extracting"
        case .signingFrameworks: return "Frameworks"
        case .signingApp: return "Signing"
        case .packaging: return "Packaging"
        case .verification: return "Verifying"
        case .completed: return "Done"
        }
    }

    /// The SF Symbol shown beside the stage.
    var symbolName: String {
        switch self {
        case .preparing: return "gearshape"
        case .preflight: return "checkmark.shield"
        case .extraction: return "square.and.arrow.down"
        case .signingFrameworks: return "shippingbox"
        case .signingApp: return "signature"
        case .packaging: return "archivebox"
        case .verification: return "checkmark.seal"
        case .completed: return "checkmark.circle"
        }
    }

    /// The position of this stage in pipeline order, counting from zero.
    var order: Int {
        SigningJobStage.allCases.firstIndex(of: self) ?? 0
    }

    /// Whether the pipeline has reached this stage: `self` is at or after
    /// `other` in pipeline order.
    func isAtOrAfter(_ other: SigningJobStage) -> Bool {
        order >= other.order
    }

    // MARK: - Progress weighting

    /// How much of a signing run's total work this stage represents. The
    /// weights are policy, declared once, and add up to one.
    var weight: Double {
        switch self {
        case .preparing: return 0.03
        case .preflight: return 0.09
        case .extraction: return 0.24
        case .signingFrameworks: return 0.20
        case .signingApp: return 0.22
        case .packaging: return 0.13
        case .verification: return 0.09
        case .completed: return 0
        }
    }

    /// The sum of every stage's weight. Always one, because the weights are
    /// declared to add up; computed rather than assumed so a weight change
    /// cannot silently skew every progress value.
    static var totalWeight: Double {
        allCases.reduce(0) { $0 + $1.weight }
    }

    /// The fraction of the whole run that has completed when this stage
    /// begins.
    var startingFraction: Double {
        let preceding = SigningJobStage.allCases.prefix(while: { $0 != self })
        return preceding.reduce(0) { $0 + $1.weight } / SigningJobStage.totalWeight
    }

    /// The fraction of the whole run this stage spans.
    var fractionSpan: Double {
        weight / SigningJobStage.totalWeight
    }

    /// The overall fraction completed, given how far through `stage` the
    /// run is. Clamped to `0...1` so a stage that reports more work than it
    /// promised cannot produce a bar past its end.
    static func fraction(of stage: SigningJobStage, stageFraction: Double) -> Double {
        let withinStage = min(max(stageFraction, 0), 1)
        return min(max(stage.startingFraction + stage.fractionSpan * withinStage, 0), 1)
    }

    /// The number of stages that measure work — the count a "stage N of M"
    /// caption is honest about.
    static var workStageCount: Int {
        allCases.filter { $0 != .completed }.count
    }
}

/// One progress observation from a running signing job.
///
/// A progress value says which stage a job has reached and — when the stage
/// measures work that can be counted — how much of that work is done. The
/// signing pipeline reports stage boundaries, so in practice a job's overall
/// fraction advances when a stage completes; countable within-stage units
/// are supported for the stages that can produce them and are never
/// invented for the stages that cannot.
///
/// Values are produced on whichever context the work runs on and are
/// delivered through `SigningJobProgressReporting`, so a consumer may
/// receive them out of order. Consumers that care about order compare
/// `fractionCompleted`, which the queue keeps monotonic per job.
struct SigningJobProgress: Equatable, Hashable, Sendable, Codable {

    /// The stage the job has reached.
    let stage: SigningJobStage

    /// How many units of the stage's work are done.
    let completedUnitCount: Int

    /// How many units the stage's work has in total. Zero means the stage
    /// measures nothing countable — progress is then reported by stage
    /// boundaries alone, which is exactly as precise as the pipeline is.
    let totalUnitCount: Int

    /// Records an observation. Negative counts are clamped to zero: counts
    /// are observed from running work, so a negative value can only be a
    /// caller's mistake.
    init(stage: SigningJobStage, completedUnitCount: Int = 0, totalUnitCount: Int = 0) {
        self.stage = stage
        self.completedUnitCount = max(0, completedUnitCount)
        self.totalUnitCount = max(0, totalUnitCount)
    }

    /// Whether the stage reports countable work.
    var isDeterminate: Bool {
        totalUnitCount > 0
    }

    /// How far through this stage the job is: the ratio of completed to
    /// total units, or zero when the stage measures nothing.
    var stageFraction: Double {
        guard isDeterminate else { return 0 }
        return min(1, Double(completedUnitCount) / Double(totalUnitCount))
    }

    /// The overall fraction of the signing run that is complete, combining
    /// this stage's position in the pipeline with its own progress.
    var fractionCompleted: Double {
        SigningJobStage.fraction(of: stage, stageFraction: stageFraction)
    }

    /// The stage reached, described for the user.
    var displayName: String {
        stage.displayName
    }
}
