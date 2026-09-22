import Foundation

/// The status of a certificate's validity period at a given evaluation time.
///
/// Validity-period status answers one question: is the current time within
/// the interval the certificate declares? It does not answer whether the
/// certificate is trusted, whether its chain validates, or whether it is
/// suitable for code signing. Those are separate evaluations.
///
/// This distinction is intentional and required by the architecture:
/// parsing succeeded ≠ currently valid ≠ trusted ≠ suitable for code signing.
enum CertificateValidityPeriodStatus: String, CaseIterable, Equatable, Hashable {

    /// The evaluation time is before `notValidBefore`.
    case notYetValid

    /// The evaluation time is within `[notValidBefore, notValidAfter]`.
    case currentlyValid

    /// The evaluation time is after `notValidAfter`.
    case expired

    /// Whether the certificate is currently valid.
    var isCurrentlyValid: Bool { self == .currentlyValid }

    /// A human-readable name for diagnostics.
    var displayName: String {
        switch self {
        case .notYetValid: return "Not Yet Valid"
        case .currentlyValid: return "Currently Valid"
        case .expired: return "Expired"
        }
    }
}

/// The result of evaluating a certificate's validity period.
///
/// `CertificateValidity` is separate from parsing success. A certificate can
/// be structurally parseable and still be expired or not yet valid. The
/// evaluation is performed against an explicit date so that tests are
/// deterministic and the evaluation moment is visible in diagnostics.
struct CertificateValidity: Equatable, Hashable {

    /// The period status at the evaluation time.
    let periodStatus: CertificateValidityPeriodStatus

    /// The date at which the evaluation was performed.
    let evaluationDate: Date

    /// The certificate's notBefore date.
    let notValidBefore: Date

    /// The certificate's notAfter date.
    let notValidAfter: Date

    /// Whether the certificate is currently valid at `evaluationDate`.
    var isCurrentlyValid: Bool { periodStatus.isCurrentlyValid }

    /// Creates a validity evaluation.
    init(
        periodStatus: CertificateValidityPeriodStatus,
        evaluationDate: Date,
        notValidBefore: Date,
        notValidAfter: Date
    ) {
        self.periodStatus = periodStatus
        self.evaluationDate = evaluationDate
        self.notValidBefore = notValidBefore
        self.notValidAfter = notValidAfter
    }

    /// Evaluates a certificate's validity period against a date.
    ///
    /// The evaluation is inclusive of the boundaries: a certificate is
    /// considered valid when `date` equals `notValidBefore` or
    /// `notValidAfter`. This matches common X.509 evaluation practice and is
    /// documented explicitly here so that callers know what is being checked.
    static func evaluate(
        notValidBefore: Date,
        notValidAfter: Date,
        at date: Date = Date()
    ) -> CertificateValidity {
        let status: CertificateValidityPeriodStatus
        if date < notValidBefore {
            status = .notYetValid
        } else if date > notValidAfter {
            status = .expired
        } else {
            status = .currentlyValid
        }
        return CertificateValidity(
            periodStatus: status,
            evaluationDate: date,
            notValidBefore: notValidBefore,
            notValidAfter: notValidAfter
        )
    }

    /// Convenience that evaluates a `CertificateMetadata`'s validity period.
    static func evaluate(
        certificate: CertificateMetadata,
        at date: Date = Date()
    ) -> CertificateValidity {
        evaluate(
            notValidBefore: certificate.notValidBefore,
            notValidAfter: certificate.notValidAfter,
            at: date
        )
    }
}

/// The broader validity evaluation that distinguishes parsing, period, usage,
/// and trust.
///
/// This type exists to prevent collapsing distinct concepts. At minimum it
/// distinguishes:
/// - structurally parseable (represented by the existence of
///   `CertificateMetadata`),
/// - validity-period status (`CertificateValidity`),
/// - intended usage where verifiable (e.g. key usage, extended key usage),
/// - trust/chain evaluation (not implemented in this milestone).
///
/// For this milestone only period status is evaluated. Usage and trust are
/// represented as unknown/not-evaluated so that callers cannot mistake
/// absence of evaluation for a positive result.
struct CertificateTrustEvaluation: Equatable, Hashable {

    /// Whether intended-usage checks (key usage, extended key usage) have
    /// been evaluated.
    enum UsageStatus: String, Equatable, Hashable {
        case notEvaluated
        case appearsSuitable
        case unsuitable
    }

    /// Whether chain/trust evaluation has been performed.
    enum TrustStatus: String, Equatable, Hashable {
        case notEvaluated
        case trusted
        case untrusted
    }

    /// The period evaluation.
    let period: CertificateValidity

    /// The usage evaluation.
    let usage: UsageStatus

    /// The trust evaluation.
    let trust: TrustStatus

    /// Creates a trust evaluation. For this milestone usage and trust are
    /// `notEvaluated` unless a caller explicitly provides otherwise.
    init(
        period: CertificateValidity,
        usage: UsageStatus = .notEvaluated,
        trust: TrustStatus = .notEvaluated
    ) {
        self.period = period
        self.usage = usage
        self.trust = trust
    }

    /// Whether the certificate is currently valid *and* no evaluated aspect
    /// has been found unsuitable or untrusted. This does **not** mean the
    /// certificate is trusted; trust is `notEvaluated` in this milestone and
    /// therefore does not contribute to a negative result.
    ///
    /// The property is provided for convenience, but callers should inspect
    /// the individual fields when they need to explain a decision.
    var isCurrentlyValidForDisplay: Bool {
        period.isCurrentlyValid && usage != .unsuitable && trust != .untrusted
    }
}
