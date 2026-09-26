import Foundation

/// How much work an item in the Import Hub still has ahead of it.
///
/// Three independent measures, each present only when it is honest: the
/// steps left on the stage track (always known), the bytes left to copy
/// (known while a copy with a known size runs), and a time estimate (only
/// once enough of a copy has happened for its rate to mean something).
/// The time is never guessed for work whose duration ZynSign cannot
/// measure, such as reading a package's contents.
struct ImportRemainingEstimate: Equatable, Hashable, Sendable {

    /// The track stages still to come, excluding the final outcome.
    let remainingSteps: Int

    /// The bytes still to copy, when a copy of known size is running.
    let remainingBytes: Int?

    /// The estimated seconds until the running copy finishes, when its
    /// rate is established.
    let remainingSeconds: TimeInterval?

    /// The fraction of a copy that must be done before its rate is used.
    static let minimumFractionForRate = 0.05

    /// The time a copy must have been running before its rate is used.
    static let minimumElapsedForRate: TimeInterval = 1

    /// Estimates the remaining work for an item at `stage`, given the most
    /// recent pipeline progress and when the current copy began.
    static func estimate(
        stage: ImportQueueStage,
        progress: ImportProgress?,
        transferStartedAt: Date?,
        now: Date
    ) -> ImportRemainingEstimate {
        let steps = stage.remainingStepCount
        guard let progress, progress.stage == .copying, progress.isDeterminate else {
            return ImportRemainingEstimate(remainingSteps: steps, remainingBytes: nil, remainingSeconds: nil)
        }

        let remainingBytes = max(0, progress.totalUnitCount - progress.completedUnitCount)
        var remainingSeconds: TimeInterval?
        if let transferStartedAt {
            let elapsed = now.timeIntervalSince(transferStartedAt)
            let fraction = progress.stageFraction
            if elapsed >= minimumElapsedForRate,
               fraction >= minimumFractionForRate,
               progress.completedUnitCount > 0 {
                let rate = Double(progress.completedUnitCount) / elapsed
                if rate > 0 {
                    remainingSeconds = Double(remainingBytes) / rate
                }
            }
        }
        return ImportRemainingEstimate(
            remainingSteps: steps,
            remainingBytes: remainingBytes,
            remainingSeconds: remainingSeconds
        )
    }
}
