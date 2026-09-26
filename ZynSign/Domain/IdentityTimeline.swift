import Foundation

/// How significant one timeline event was.
enum IdentityTimelineSignificance: String, Equatable, Hashable, Sendable {

    /// Something worked: an import completed, a signing succeeded.
    case positive

    /// Something wants attention: an expiration approaching, a run failed.
    case warning

    /// A neutral record.
    case neutral

    /// The symbol the timeline shows for the significance.
    var symbolName: String {
        switch self {
        case .positive: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .neutral: return "circle.dotted"
        }
    }
}

/// What kind of thing happened.
enum IdentityTimelineEventKind: String, CaseIterable, Equatable, Hashable, Sendable {

    /// A signing identity was imported from a .p12 container.
    case certificateImported

    /// A provisioning profile was added to the library.
    case profileAdded

    /// An application was signed successfully.
    case applicationSigned

    /// A signing run failed.
    case signingFailed

    /// An identity is inside its expiration warning window. This is a
    /// generated observation of the current state, not a past moment:
    /// it is re-derived from the facts each time the timeline is built
    /// and is dated at the reference instant.
    case expiringSoon

    /// The timeline row's title for an event of this kind, when the event
    /// carries no subject-specific title.
    var fallbackTitle: String {
        switch self {
        case .certificateImported: return "Certificate Imported"
        case .profileAdded: return "Profile Added"
        case .applicationSigned: return "Signed Application"
        case .signingFailed: return "Signing Failed"
        case .expiringSoon: return "Expiring Soon"
        }
    }

    /// The symbol the timeline shows for the kind, when the significance
    /// does not override it.
    var symbolName: String {
        switch self {
        case .certificateImported: return "signature"
        case .profileAdded: return "person.text.rectangle"
        case .applicationSigned: return "checkmark.seal"
        case .signingFailed: return "xmark.octagon"
        case .expiringSoon: return "clock.badge.exclamationmark"
        }
    }
}

/// One event in the identity timeline.
///
/// Events are observations assembled from the stores ZynSign already
/// holds — import dates, the signing journal, and the expiration forecast
/// — reduced to fixed, composed language. An event never carries a path,
/// a credential, a key reference, or a raw error.
struct IdentityTimelineEvent: Identifiable, Equatable, Hashable, Sendable {

    /// The moment the event happened (or was observed, for generated
    /// expiration observations).
    let date: Date

    /// What kind of event it is.
    let kind: IdentityTimelineEventKind

    /// The one-line title.
    let title: String

    /// One sentence of context, when the event has any.
    let detail: String?

    /// How significant the event was.
    let significance: IdentityTimelineSignificance

    /// The certificate fingerprint involved, when the event is about one.
    let certificateFingerprintHex: String?

    /// The profile identifier involved, when the event is about one.
    let profileID: ProvisioningProfileIdentifier?

    /// The stable identity of the event, derived from its content so a
    /// rebuilt timeline keeps its rows identifiable.
    var id: String {
        let timestamp = Int(date.timeIntervalSince1970)
        let subject = certificateFingerprintHex ?? profileID?.rawValue ?? kind.rawValue
        return "\(kind.rawValue)|\(subject)|\(timestamp)|\(title)"
    }

    /// Creates an event from its parts.
    init(
        date: Date,
        kind: IdentityTimelineEventKind,
        title: String,
        detail: String? = nil,
        significance: IdentityTimelineSignificance,
        certificateFingerprintHex: String? = nil,
        profileID: ProvisioningProfileIdentifier? = nil
    ) {
        self.date = date
        self.kind = kind
        self.title = title
        self.detail = detail
        self.significance = significance
        self.certificateFingerprintHex = certificateFingerprintHex
        self.profileID = profileID
    }
}

/// One day of the timeline, as the grouped list shows it.
struct IdentityTimelineDay: Identifiable, Equatable, Hashable, Sendable {

    /// The day the events fall on, at local midnight.
    let day: Date

    /// The day's title: "Today", "Yesterday", or the date.
    let title: String

    /// The day's events, most recent first.
    let events: [IdentityTimelineEvent]

    /// The day's identity in a list.
    var id: Date { day }

    /// Creates a day from its parts.
    init(day: Date, title: String, events: [IdentityTimelineEvent]) {
        self.day = day
        self.title = title
        self.events = events
    }
}

/// The Identity Timeline builder.
///
/// The builder is pure: it assembles events from the facts handed to it —
/// certificate import dates, profile import dates, the signing journal's
/// records reduced to facts, and the expiration forecast — and groups them
/// into days. Events come out most recent first, capped to a bounded
/// number so the timeline stays instant to render however long the journal
/// grows.
struct IdentityTimelineBuilder: Sendable {

    /// How many events the timeline keeps. The journal itself is already
    /// bounded; the cap keeps a rebuilt timeline cheap to render.
    static let maximumEvents = 60

    /// How many generated expiration observations the timeline keeps. The
    /// observations repeat on every build, so a small number is honest —
    /// the most urgent identities, not every one.
    static let maximumGeneratedExpirations = 5

    /// Builds the timeline events.
    ///
    /// - Parameters:
    ///   - certificates: Every local certificate's facts.
    ///   - profiles: Every stored profile's facts.
    ///   - history: The signing journal reduced to facts, most recent
    ///     first.
    ///   - forecast: The expiration forecast, most urgent first.
    ///   - referenceDate: The instant generated observations are dated at.
    /// - Returns: The events, most recent first, capped to
    ///   `maximumEvents`.
    func events(
        certificates: [IdentityCertificateFacts],
        profiles: [IdentityProfileFacts],
        history: [IdentityHistoryFact],
        forecast: [ExpirationForecastEntry],
        referenceDate: Date
    ) -> [IdentityTimelineEvent] {
        var events: [IdentityTimelineEvent] = []

        for certificate in certificates {
            guard let importedAt = certificate.importedAt else { continue }
            events.append(IdentityTimelineEvent(
                date: importedAt,
                kind: .certificateImported,
                title: "Certificate Imported",
                detail: certificate.displayName,
                significance: .positive,
                certificateFingerprintHex: certificate.fingerprintHex
            ))
        }

        for profile in profiles {
            guard let importedAt = profile.importedAt else { continue }
            events.append(IdentityTimelineEvent(
                date: importedAt,
                kind: .profileAdded,
                title: "Profile Added",
                detail: profile.name,
                significance: .positive,
                profileID: profile.id
            ))
        }

        for record in history {
            let appName = record.applicationName
                ?? record.bundleIdentifier
                ?? "Application"
            if record.succeeded {
                events.append(IdentityTimelineEvent(
                    date: record.startedAt,
                    kind: .applicationSigned,
                    title: "Signed \(appName)",
                    detail: record.bundleIdentifier,
                    significance: .positive,
                    certificateFingerprintHex: record.certificateFingerprintHex
                ))
            } else {
                events.append(IdentityTimelineEvent(
                    date: record.startedAt,
                    kind: .signingFailed,
                    title: "Signing Failed",
                    detail: "Refused while signing \(appName).",
                    significance: .warning,
                    certificateFingerprintHex: record.certificateFingerprintHex
                ))
            }
        }

        // Generated expiration observations: the most urgent identities
        // within the warning window, dated at the reference instant. An
        // expired identity is already reported as blocked elsewhere; the
        // timeline's observation is for the ones still signable today.
        let expiring = forecast
            .filter { $0.band == .warning || $0.band == .critical || $0.band == .important }
            .prefix(Self.maximumGeneratedExpirations)
        for entry in expiring {
            events.append(IdentityTimelineEvent(
                date: referenceDate,
                kind: .expiringSoon,
                title: "\(entry.kind.displayName) Expiring Soon",
                detail: "\(entry.name) — \(entry.countdownText).",
                significance: .warning,
                certificateFingerprintHex: entry.kind == .certificate ? entry.subjectKey : nil,
                profileID: entry.kind == .profile
                    ? ProvisioningProfileIdentifier(rawValue: entry.subjectKey)
                    : nil
            ))
        }

        return Array(
            events
                .sorted { $0.date > $1.date }
                .prefix(Self.maximumEvents)
        )
    }

    /// Groups events into days, most recent day first, with the fixed
    /// relative titles.
    ///
    /// - Parameters:
    ///   - events: The events, in any order.
    ///   - referenceDate: The instant "today" is measured from.
    ///   - calendar: The calendar that decides where a day begins.
    ///   - dateFormatter: The formatter the non-relative day titles use.
    /// - Returns: One day per calendar day that has events, newest first.
    func groupedByDay(
        _ events: [IdentityTimelineEvent],
        referenceDate: Date,
        calendar: Calendar = .current,
        dateFormatter: DateFormatter = Self.dayFormatter
    ) -> [IdentityTimelineDay] {
        let startOfToday = calendar.startOfDay(for: referenceDate)
        guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else {
            return []
        }

        var byDay: [Date: [IdentityTimelineEvent]] = [:]
        for event in events {
            let day = calendar.startOfDay(for: event.date)
            byDay[day, default: []].append(event)
        }

        return byDay
            .map { day, dayEvents in
                let title: String
                if day == startOfToday {
                    title = "Today"
                } else if day == startOfYesterday {
                    title = "Yesterday"
                } else {
                    title = dateFormatter.string(from: day)
                }
                return IdentityTimelineDay(
                    day: day,
                    title: title,
                    events: dayEvents.sorted { $0.date > $1.date }
                )
            }
            .sorted { $0.day > $1.day }
    }

    /// The formatter for non-relative day titles, e.g. "Sep 20".
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}
