/// One progress observation from a running import.
///
/// A progress value says which stage an import has reached and — when the
/// stage measures work that can be counted, which in practice means the bytes
/// of the copy — how much of that work is done. It is a description of the
/// import, not a promise about the package: reaching the last stage says the
/// bytes were stored, and nothing about whether they are genuine, signed, or
/// installable.
///
/// Values are produced on whichever context the work runs on and are
/// delivered through `ImportProgressReporting`, so a consumer may receive
/// them from a context other than its own and, because delivery is not
/// ordered, may receive them out of order. Consumers that care about order
/// compare `fractionCompleted`, which never decreases within one import.
struct ImportProgress: Equatable, Hashable, Sendable {

    /// The stage the import has reached.
    let stage: ImportStage

    /// How many units of the stage's work are done.
    let completedUnitCount: Int

    /// How many units the stage's work has in total. Zero means the stage
    /// measures nothing countable — for example an examination stage, whose
    /// cost is bounded and whose progress is therefore reported by stage
    /// alone.
    let totalUnitCount: Int

    /// Records an observation. Negative counts are clamped to zero: counts
    /// are observed from running work, so a negative value can only be a
    /// caller's mistake.
    init(stage: ImportStage, completedUnitCount: Int = 0, totalUnitCount: Int = 0) {
        self.stage = stage
        self.completedUnitCount = max(0, completedUnitCount)
        self.totalUnitCount = max(0, totalUnitCount)
    }

    /// Whether the stage reports countable work.
    var isDeterminate: Bool {
        totalUnitCount > 0
    }

    /// How far through this stage the import is: the ratio of completed to
    /// total units, or zero when the stage measures nothing.
    var stageFraction: Double {
        guard isDeterminate else { return 0 }
        return min(1, Double(completedUnitCount) / Double(totalUnitCount))
    }

    /// The overall fraction of the import that is complete, combining this
    /// stage's position in the pipeline with its own progress.
    var fractionCompleted: Double {
        ImportStage.fraction(of: stage, stageFraction: stageFraction)
    }

    /// The stage reached, described for the user.
    var displayName: String {
        stage.displayName
    }
}
