import Foundation

/// The presentation classification of a certificate's remaining validity.
///
/// `CertificateValidity` answers the structural question — is the evaluation
/// instant inside the declared interval? This status adds the intelligence a
/// certificate manager needs: how much time is left, and whether that much is
/// a cause for attention. The classification is a display and workflow
/// signal, not a trust result: a "healthy" certificate is not thereby
/// trusted, and an "expired" certificate is still a fully parseable record.
///
/// The assessment is always performed against an explicit instant so tests
/// are deterministic and the evaluation moment is visible in the result.
enum CertificateExpirationStatus: String, CaseIterable, Equatable, Hashable {

    /// The certificate is valid and enough time remains.
    case healthy

    /// The certificate is valid, but the remaining period has fallen within
    /// the warning threshold.
    case expiringSoon

    /// The certificate's interval ended before the evaluation instant.
    case expired

    /// The certificate's interval has not started at the evaluation instant.
    case notYetValid

    /// The user-presentable name of the classification.
    var displayName: String {
        switch self {
        case .healthy: return "Healthy"
        case .expiringSoon: return "Expiring Soon"
        case .expired: return "Expired"
        case .notYetValid: return "Not Yet Valid"
        }
    }
}

/// The result of classifying a certificate's remaining validity.
///
/// `remainingDays` is the whole number of days between the evaluation instant
/// and the end of the validity period: positive while time remains, zero on
/// the final day, negative once the certificate is expired. It is `nil` when
/// the certificate is not yet valid, because "days left" has no meaning for a
/// period that has not started; the start of the period is available in
/// `notValidBefore` for a "valid from" presentation.
///
/// The classification is pure: it reads no clock and no platform state.
struct CertificateExpirationAssessment: Equatable, Hashable {

    /// The default warning threshold: a certificate whose remaining period
    /// has fallen to 30 days or fewer is classified `.expiringSoon`.
    static let defaultWarningThresholdDays = 30

    /// The number of seconds in one day, used for the whole-day arithmetic.
    private static let secondsPerDay: TimeInterval = 24 * 60 * 60

    /// The classification at the evaluation instant.
    let status: CertificateExpirationStatus

    /// The instant at which the classification was made.
    let evaluationDate: Date

    /// The start of the certificate's validity period.
    let notValidBefore: Date

    /// The end of the certificate's validity period.
    let notValidAfter: Date

    /// The warning threshold in whole days applied by this assessment.
    let warningThresholdDays: Int

    /// Whole days until `notValidAfter`, negative when expired. `nil` when
    /// the certificate is not yet valid.
    let remainingDays: Int?

    /// Whether the certificate can sign at the evaluation instant: valid,
    /// and past any not-yet-valid window. Expiration warning does not reduce
    /// usability — a certificate expiring in ten days still signs today.
    var isUsableAtEvaluationDate: Bool {
        status == .healthy || status == .expiringSoon
    }

    /// The number of days between `evaluationDate` and `notValidAfter`, as a
    /// whole number of complete days: the seconds of the interval, truncated
    /// toward zero. A certificate with 29 days and 23 hours left has 29 days
    /// remaining; one that expired one day and one second ago is one day ago.
    private static func wholeDays(remainingInterval: TimeInterval) -> Int {
        Int(remainingInterval / secondsPerDay)
    }

    /// Classifies the interval `notValidBefore`…`notValidAfter` at
    /// `evaluationDate` using `warningThresholdDays` as the attention line.
    ///
    /// The boundary is inclusive the way `CertificateValidity` evaluates it:
    /// the final instant of validity is still valid, and the first instant
    /// after it is expired.
    static func assess(
        notValidBefore: Date,
        notValidAfter: Date,
        at evaluationDate: Date,
        warningThresholdDays: Int = defaultWarningThresholdDays
    ) -> CertificateExpirationAssessment {
        if evaluationDate < notValidBefore {
            return CertificateExpirationAssessment(
                status: .notYetValid,
                evaluationDate: evaluationDate,
                notValidBefore: notValidBefore,
                notValidAfter: notValidAfter,
                warningThresholdDays: warningThresholdDays,
                remainingDays: nil
            )
        }
        let remaining = wholeDays(
            remainingInterval: notValidAfter.timeIntervalSince(evaluationDate)
        )
        if evaluationDate > notValidAfter {
            return CertificateExpirationAssessment(
                status: .expired,
                evaluationDate: evaluationDate,
                notValidBefore: notValidBefore,
                notValidAfter: notValidAfter,
                warningThresholdDays: warningThresholdDays,
                remainingDays: remaining
            )
        }
        let status: CertificateExpirationStatus
        if remaining <= warningThresholdDays {
            status = .expiringSoon
        } else {
            status = .healthy
        }
        return CertificateExpirationAssessment(
            status: status,
            evaluationDate: evaluationDate,
            notValidBefore: notValidBefore,
            notValidAfter: notValidAfter,
            warningThresholdDays: warningThresholdDays,
            remainingDays: remaining
        )
    }

    /// Classifies a parsed certificate's interval at `date`.
    static func assess(
        certificate: CertificateMetadata,
        at date: Date,
        warningThresholdDays: Int = defaultWarningThresholdDays
    ) -> CertificateExpirationAssessment {
        assess(
            notValidBefore: certificate.notValidBefore,
            notValidAfter: certificate.notValidAfter,
            at: date,
            warningThresholdDays: warningThresholdDays
        )
    }

    /// Classifies a parsed certificate's interval at `clock.now()`.
    static func assess(
        certificate: CertificateMetadata,
        clock: any EvaluationClock,
        warningThresholdDays: Int = defaultWarningThresholdDays
    ) -> CertificateExpirationAssessment {
        assess(
            certificate: certificate,
            at: clock.now(),
            warningThresholdDays: warningThresholdDays
        )
    }
}
