import Foundation

/// One progress event from inside an application signing run.
///
/// The pipeline reports what it is doing, not what it concluded: an event
/// names a stage that started or finished, or a nested target that began or
/// finished signing. No event carries bytes, timing claims, or signing
/// material, and an observer cannot influence the run by throwing — it has no
/// return value and no failure channel.
enum ApplicationSigningProgressEvent: Equatable, Sendable {

    /// A stage began. Its work is now in progress.
    case stageStarted(ApplicationSigningStage)

    /// A stage finished. Only emitted for a stage that ran to completion.
    case stageCompleted(ApplicationSigningStage)

    /// Nested discovery established the plan: how many targets each kind
    /// contributes, and therefore how much nested signing work the run has.
    case nestedPlan([NestedCodeKind: Int])

    /// One nested target began signing, at `order` of `total` in the
    /// validated plan.
    case nestedItemStarted(order: Int, total: Int, kind: NestedCodeKind, path: BundlePath)

    /// One nested target finished signing.
    case nestedItemSigned(order: Int, total: Int, kind: NestedCodeKind, path: BundlePath)

    /// One nested target refused the run.
    case nestedItemRefused(order: Int, total: Int, kind: NestedCodeKind, path: BundlePath)
}

/// Receives progress events from inside a signing run.
///
/// The observer is called synchronously on the run's own execution context.
/// A caller that needs to touch interface state marshals the event itself;
/// the pipeline never assumes an actor.
typealias ApplicationSigningProgressObserver = (ApplicationSigningProgressEvent) -> Void

/// One nested target's progress inside a nested signing run.
struct NestedSigningItemProgress: Equatable, Sendable {

    /// What just happened to the target.
    enum Phase: String, Equatable, Sendable {

        /// The target's signing began.
        case signing

        /// The target was signed and its post-sign verification passed.
        case signed

        /// The target refused the run.
        case refused
    }

    /// The phase reported.
    let phase: Phase

    /// The target's one-based position in the validated plan.
    let order: Int

    /// How many targets the plan signs.
    let total: Int

    /// The target's kind.
    let kind: NestedCodeKind

    /// The target's executable location, relative to the application bundle.
    let executablePath: BundlePath
}

/// Receives progress from inside a nested signing run.
typealias NestedSigningProgressObserver = (NestedSigningItemProgress) -> Void
