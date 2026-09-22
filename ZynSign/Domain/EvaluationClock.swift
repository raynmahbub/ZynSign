import Foundation

/// A source of the instant used to evaluate a certificate validity period.
///
/// Validity evaluation must not read the system clock directly. Callers pass
/// an explicit instant, or a clock injected at the inspection boundary, so
/// tests stay deterministic and the evaluation moment is visible in the
/// result. This is the same idea as the library's injectable timestamp, kept
/// small because certificate inspection needs only "what time is it?".
protocol EvaluationClock: Sendable {

    /// The instant at which a validity period should be evaluated.
    func now() -> Date
}

/// The system clock. Use this at the composition root, not inside domain
/// comparisons.
struct SystemEvaluationClock: EvaluationClock {

    init() {}

    func now() -> Date { Date() }
}

/// A clock that always reports the same instant.
struct FixedEvaluationClock: EvaluationClock {

    /// The instant `now()` returns.
    let instant: Date

    init(instant: Date) {
        self.instant = instant
    }

    func now() -> Date { instant }
}
