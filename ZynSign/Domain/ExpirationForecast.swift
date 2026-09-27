import Foundation

/// How urgently one expiration wants attention.
///
/// The bands are the forecast's own language: expired identities block, a
/// week or less is critical, two weeks or less is important, the warning
/// threshold of 30 days or less is a warning, and anything further out is
/// on watch. The bands line up with — and never contradict — the
/// certificate manager's 30-day warning and the profile library's
/// expiring-soon badge.
enum ExpirationForecastBand: Int, Comparable, CaseIterable, Equatable, Hashable, Sendable {

    /// The validity period has ended. A blocked identity.
    case expired = 0

    /// Seven days of validity or fewer remain.
    case critical = 1

    /// Fourteen days of validity or fewer remain.
    case important = 2

    /// Thirty days of validity or fewer remain.
    case warning = 3

    /// More than thirty days remain.
    case watch = 4

    /// The day count that starts the band, evaluated against the days
    /// remaining.
    private static let thresholds: [ExpirationForecastBand: Int] = [
        .critical: 7,
        .important: 14,
        .warning: 30,
    ]

    /// Classifies a day count. Negative days are expired.
    static func band(forDaysRemaining days: Int) -> ExpirationForecastBand {
        if days < 0 { return .expired }
        for band in [.critical, .important, .warning] {
            if let threshold = thresholds[band], days <= threshold { return band }
        }
        return .watch
    }

    /// The band's name, as the forecast lists show it.
    var displayName: String {
        switch self {
        case .expired: return "Expired"
        case .critical: return "Critical"
        case .important: return "Important"
        case .warning: return "Warning"
        case .watch: return "Watch"
        }
    }

    /// Whether an identity in this band can still sign.
    var isBlocking: Bool { self == .expired }

    /// The sentence VoiceOver reads for the band.
    var spokenSummary: String {
        switch self {
        case .expired: return "Expired. Blocked."
        case .critical: return "Critical. Days remain."
        case .important: return "Important. Renew soon."
        case .warning: return "Warning. Renewal window open."
        case .watch: return "Under watch. No action needed yet."
        }
    }

    static func < (lhs: ExpirationForecastBand, rhs: ExpirationForecastBand) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One expiration the forecast tracks: a certificate or a profile, its
/// expiration date, and the band the remaining time falls into.
struct ExpirationForecastEntry: Identifiable, Equatable, Hashable, Sendable {

    /// What kind of identity expires.
    enum SubjectKind: String, Equatable, Hashable, Sendable {
        case certificate
        case profile

        /// The symbol shown next to the entry.
        var symbolName: String {
            switch self {
            case .certificate: return "signature"
            case .profile: return "person.text.rectangle"
            }
        }

        /// The word the entry uses for its subject.
        var displayName: String {
            switch self {
            case .certificate: return "Certificate"
            case .profile: return "Profile"
            }
        }
    }

    /// The kind of identity that expires.
    let kind: SubjectKind

    /// The subject's display name.
    let name: String

    /// The team the subject declares, when recognisable.
    let teamID: String?

    /// The expiration date the subject declares.
    let expirationDate: Date

    /// Whole days remaining at the reference instant; negative when past.
    let daysRemaining: Int

    /// The band the remaining time falls into.
    let band: ExpirationForecastBand

    /// The certificate fingerprint or profile identifier the entry refers
    /// to, so a screen can link to the subject.
    let subjectKey: String

    /// The stable identity of the entry.
    var id: String { "\(kind.rawValue):\(subjectKey)" }

    /// The countdown the entry shows, e.g. "3 days left".
    var countdownText: String {
        if daysRemaining < 0 {
            let past = abs(daysRemaining)
            return past == 0 ? "Expired today" : "Expired \(past) day\(past == 1 ? "" : "s") ago"
        }
        if daysRemaining == 0 { return "Expires today" }
        if daysRemaining == 1 { return "1 day left" }
        return "\(daysRemaining) days left"
    }

    /// Creates an entry, deriving its band from the day count.
    init(
        kind: SubjectKind,
        name: String,
        teamID: String?,
        expirationDate: Date,
        daysRemaining: Int,
        subjectKey: String
    ) {
        self.kind = kind
        self.name = name
        self.teamID = teamID
        self.expirationDate = expirationDate
        self.daysRemaining = daysRemaining
        self.band = ExpirationForecastBand.band(forDaysRemaining: daysRemaining)
        self.subjectKey = subjectKey
    }
}

/// The Expiration Forecast builder.
///
/// The builder is pure: certificates and profiles in, urgency-sorted
/// entries out. Entries are sorted most-urgent first — by band, then by
/// expiration date, then by name — so the top of the forecast is always
/// the next thing that stops working.
struct ExpirationForecastBuilder: Sendable {

    /// The instant later than which identities are still on watch and are
    /// included only when explicitly asked for. The default keeps the
    /// forecast focused on what wants attention: everything within the
    /// 30-day warning threshold plus everything expired.
    static let defaultHorizonDays = 30

    /// Builds the forecast for the given identities.
    ///
    /// - Parameters:
    ///   - certificates: Every local certificate's facts.
    ///   - profiles: Every stored profile's facts.
    ///   - referenceDate: The instant the days remaining are counted from.
    ///   - horizonDays: Identities expiring further out than this many
    ///     days are omitted. Expired identities are always included.
    /// - Returns: The entries, most urgent first.
    func build(
        certificates: [IdentityCertificateFacts],
        profiles: [IdentityProfileFacts],
        referenceDate: Date,
        horizonDays: Int = ExpirationForecastBuilder.defaultHorizonDays
    ) -> [ExpirationForecastEntry] {
        var entries: [ExpirationForecastEntry] = []

        for certificate in certificates {
            guard let days = certificate.expiration.remainingDays else { continue }
            guard days <= horizonDays || days < 0 else { continue }
            entries.append(ExpirationForecastEntry(
                kind: .certificate,
                name: certificate.displayName,
                teamID: certificate.teamID,
                expirationDate: certificate.expiration.notValidAfter,
                daysRemaining: days,
                subjectKey: certificate.fingerprintHex
            ))
        }

        for profile in profiles {
            let days = profile.daysUntilExpiration(referenceDate: referenceDate)
            guard days <= horizonDays || days < 0 else { continue }
            entries.append(ExpirationForecastEntry(
                kind: .profile,
                name: profile.name,
                teamID: profile.teamID,
                expirationDate: profile.expirationDate,
                daysRemaining: days,
                subjectKey: profile.id.rawValue
            ))
        }

        return entries.sorted { lhs, rhs in
            if lhs.band != rhs.band { return lhs.band < rhs.band }
            if lhs.expirationDate != rhs.expirationDate {
                return lhs.expirationDate < rhs.expirationDate
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
