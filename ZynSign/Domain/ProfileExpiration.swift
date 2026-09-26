import Foundation

/// Expiration intelligence for a stored provisioning-profile summary.
///
/// Every imported profile is classified against an explicit reference date
/// into one of three states — healthy, expiring soon, or expired — with the
/// number of days remaining. The threshold matches the 30-day warning the
/// profile library has always shown, so a card, a detail screen, and a
/// compatibility report never disagree about what "expiring soon" means.
///
/// The classification reads only the profile's own expiration date. It is
/// not a trust, authenticity, or platform-acceptance statement.
enum ProfileExpirationState: String, CaseIterable, Equatable, Hashable, Sendable {

    /// More than the threshold remains.
    case healthy

    /// The threshold remains or less, but the profile has not expired.
    case expiringSoon

    /// The reference date has reached or passed the expiration date.
    case expired

    /// The user-presentable name shown on badges and filters.
    var displayName: String {
        switch self {
        case .healthy: return "Healthy"
        case .expiringSoon: return "Expiring Soon"
        case .expired: return "Expired"
        }
    }

    /// The SF Symbol that carries the state next to its label.
    var systemImage: String {
        switch self {
        case .healthy: return "checkmark.circle"
        case .expiringSoon: return "clock.badge.exclamationmark"
        case .expired: return "xmark.circle.fill"
        }
    }
}

/// The assessed expiration state of one profile at one instant.
struct ProfileExpirationAssessment: Equatable, Sendable {

    /// Days within which a profile counts as expiring soon. Matches the
    /// library's historical 30-day badge so no screen contradicts another.
    static let expiringSoonThreshold = 30

    /// The classified state.
    let state: ProfileExpirationState

    /// Whole days remaining; negative once the profile has expired.
    let daysRemaining: Int

    /// The expiration date the classification was made against.
    let expirationDate: Date

    /// Classifies `expirationDate` relative to `referenceDate`.
    init(expirationDate: Date, referenceDate: Date) {
        self.expirationDate = expirationDate
        // The same rounding the summary's `daysUntilExpiration` uses, so a
        // badge and an assessment computed at one instant always agree.
        let interval = expirationDate.timeIntervalSince(referenceDate)
        let days = Int((interval / 86400).rounded(.toNearestOrEven))
        self.daysRemaining = days
        if referenceDate >= expirationDate {
            self.state = .expired
        } else if days <= Self.expiringSoonThreshold {
            self.state = .expiringSoon
        } else {
            self.state = .healthy
        }
    }

    /// A user-presentable countdown, e.g. "243 days left" or "Expired 5 days
    /// ago". Used where a screen wants words rather than a badge.
    var countdownText: String {
        switch state {
        case .expired:
            let days = abs(daysRemaining)
            if days == 0 { return "Expired today" }
            return "Expired \(days) day\(days == 1 ? "" : "s") ago"
        case .expiringSoon, .healthy:
            if daysRemaining <= 0 { return "Expires today" }
            if daysRemaining == 1 { return "1 day left" }
            return "\(daysRemaining) days left"
        }
    }
}

extension ProvisioningProfileSummary {

    /// The expiration state of this profile at `referenceDate`.
    func expirationAssessment(referenceDate: Date = Date()) -> ProfileExpirationAssessment {
        ProfileExpirationAssessment(
            expirationDate: expirationDate,
            referenceDate: referenceDate
        )
    }
}
