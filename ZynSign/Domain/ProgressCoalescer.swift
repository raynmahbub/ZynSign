import Foundation

/// Decides which progress reports are worth publishing.
///
/// A signing run reports progress from the archive machinery, sometimes
/// many times per millisecond. Publishing every report re-renders every
/// observer for a change no one can see. The coalescer lets a report
/// through when it carries information the interface can show — a new
/// stage, a visible change in the fraction, or enough time since the last
/// publication that the bar should move — and drops the rest. Stage
/// boundaries always pass, so a job never appears stuck in a stage it has
/// already left, and the final report of a stage always passes, so a bar
/// never stops short of full.
///
/// The coalescer is a value the owner keeps per job. It is pure: given the
/// same sequence of reports and instants it always makes the same choices.
struct ProgressCoalescer: Equatable, Sendable {

    /// The smallest change in the fraction (0…1) worth publishing.
    let minimumFractionDelta: Double

    /// The longest time a report may be held back within a stage even when
    /// the fraction has barely moved.
    let maximumInterval: TimeInterval

    /// The last report that was published, and when.
    private(set) var lastPublishedStageOrder: Int?
    private(set) var lastPublishedFraction: Double?
    private(set) var lastPublishedAt: Date?

    /// How many reports were accepted and dropped, for diagnostics.
    private(set) var publishedCount = 0
    private(set) var droppedCount = 0

    init(minimumFractionDelta: Double = 0.01, maximumInterval: TimeInterval = 0.25) {
        self.minimumFractionDelta = max(0, minimumFractionDelta)
        self.maximumInterval = max(0, maximumInterval)
    }

    /// Whether a report should be published, recording the decision.
    ///
    /// - Parameters:
    ///   - stageOrder: The stage's position, so a new stage is recognised.
    ///   - fraction: The fraction completed within the run, 0…1.
    ///   - isStageComplete: Whether the report is the stage's final one.
    ///   - now: The instant the report arrived.
    mutating func shouldPublish(
        stageOrder: Int,
        fraction: Double,
        isStageComplete: Bool,
        now: Date
    ) -> Bool {
        let fraction = min(1, max(0, fraction))
        let publish: Bool
        if lastPublishedStageOrder != stageOrder {
            publish = true
        } else if isStageComplete && lastPublishedFraction != fraction {
            publish = true
        } else if let last = lastPublishedFraction, abs(fraction - last) >= minimumFractionDelta {
            publish = true
        } else if let lastAt = lastPublishedAt, now.timeIntervalSince(lastAt) >= maximumInterval,
                  lastPublishedFraction != fraction {
            publish = true
        } else if lastPublishedFraction == nil {
            publish = true
        } else {
            publish = false
        }
        if publish {
            lastPublishedStageOrder = stageOrder
            lastPublishedFraction = fraction
            lastPublishedAt = now
            publishedCount += 1
        } else {
            droppedCount += 1
        }
        return publish
    }

    /// Forgets the last publication, so the next report passes.
    mutating func reset() {
        lastPublishedStageOrder = nil
        lastPublishedFraction = nil
        lastPublishedAt = nil
    }
}
