import Foundation

/// One app ZynSign signed, with the date its signature stops working.
///
/// A lease is a *reading of the journal*, not a second record of it: every
/// field comes from a signing record the operation itself wrote, or from the
/// profile that run used. Nothing here is stored, so nothing here can drift
/// from what actually happened — delete a run from the signing history and its
/// lease is gone with it.
///
/// The two dates that matter are both the profile's and the certificate's. A
/// build stops launching when *either* expires, so the lease keeps the earlier
/// of the two and says which one it was.
struct SideloadLease: Identifiable, Equatable, Sendable {

    /// A stable identity for the row: the library record the run signed when
    /// it still exists, otherwise the bundle identifier it recorded.
    let id: String

    /// The application's name as the signing record captured it.
    let displayName: String

    /// The bundle identifier the run signed.
    let bundleIdentifier: String

    /// The library record that produced the run, when it is known. This is what
    /// lets the studio open the app's signing screen again.
    let libraryRecordIdentifier: String?

    /// When the run finished signing.
    let signedAt: Date

    /// When the profile the run used expires, as the profile declared it.
    let profileExpiresAt: Date?

    /// When the certificate the run used stops being valid.
    let certificateExpiresAt: Date?

    /// The account behind the run, when it was established.
    let account: SideloadAccount?

    /// How many days before expiry the studio asks for a re-sign. Resolved at
    /// derivation, so a lease read on its own answers the whole question.
    let refreshLeadDays: Int

    /// The profile's declared name, when the run recorded one.
    let profileName: String?

    /// The signed artifact's file name in export storage, when one was made.
    let outputFileName: String?

    /// The lead used when no account was established. Three days is later than
    /// a personal team's two and far earlier than a membership's three weeks:
    /// it warns without pretending to know which account signed the build.
    static let defaultRefreshLeadDays = 3

    init(
        id: String,
        displayName: String,
        bundleIdentifier: String,
        libraryRecordIdentifier: String? = nil,
        signedAt: Date,
        profileExpiresAt: Date? = nil,
        certificateExpiresAt: Date? = nil,
        account: SideloadAccount? = nil,
        refreshLeadDays: Int? = nil,
        profileName: String? = nil,
        outputFileName: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.libraryRecordIdentifier = libraryRecordIdentifier
        self.signedAt = signedAt
        self.profileExpiresAt = profileExpiresAt
        self.certificateExpiresAt = certificateExpiresAt
        self.account = account
        self.refreshLeadDays = max(0, refreshLeadDays ?? account?.refreshLeadDays ?? Self.defaultRefreshLeadDays)
        self.profileName = profileName
        self.outputFileName = outputFileName
    }

    // MARK: - Expiry

    /// The date the build stops launching: whichever of the profile and the
    /// certificate ends first.
    var expiresAt: Date? {
        let dates = [profileExpiresAt, certificateExpiresAt].compactMap { $0 }
        return dates.min()
    }

    /// Which of the two dates ends the lease. `nil` when both are unknown, and
    /// `.profile` when the profile is the earlier of an equal pair — a profile
    /// and a certificate that expire together are re-issued together.
    enum Ending: Equatable, Sendable {
        case profile
        case certificate

        var title: String {
            switch self {
            case .profile: return "Profile"
            case .certificate: return "Certificate"
            }
        }
    }

    var ending: Ending? {
        guard let profileExpiresAt else {
            return certificateExpiresAt == nil ? nil : .certificate
        }
        guard let certificateExpiresAt else { return .profile }
        return certificateExpiresAt < profileExpiresAt ? .certificate : .profile
    }

    /// How many whole days the build has left, rounded toward the person's
    /// interest: a lease with twelve hours left reads "0 days", never "1".
    func daysRemaining(at now: Date) -> Int? {
        guard let expiresAt else { return nil }
        let seconds = expiresAt.timeIntervalSince(now)
        if seconds <= 0 { return 0 }
        return Int(seconds / 86_400)
    }

    /// The share of the lease still to run, for a ring: one at signing time,
    /// zero at expiry. `nil` when the run recorded no expiry, because a
    /// fraction of an unknown lifetime is not a fact.
    func remainingFraction(at now: Date) -> Double? {
        guard let expiresAt else { return nil }
        let total = expiresAt.timeIntervalSince(signedAt)
        guard total > 0 else { return 0 }
        return min(max(expiresAt.timeIntervalSince(now) / total, 0), 1)
    }

    /// Where the lease stands at `now`.
    func status(at now: Date) -> SideloadLeaseStatus {
        guard let expiresAt else { return .unrecorded }
        if now >= expiresAt { return .expired }
        let lead = TimeInterval(refreshLeadDays) * 86_400
        if expiresAt.timeIntervalSince(now) <= lead { return .refreshDue }
        return .current
    }
}

/// Where one lease stands.
enum SideloadLeaseStatus: Equatable, Hashable, Sendable {

    /// More than the account's lead time is left.
    case current

    /// Inside the lead window: sign again now, and the app never stops opening.
    case refreshDue

    /// The expiry has passed. The build no longer launches.
    case expired

    /// The run recorded no expiry at all — an older journal entry, or a
    /// profile whose date the run could not read. Not the same as healthy, and
    /// not the same as broken.
    case unrecorded

    /// Whether the studio puts the row in the refresh queue.
    var isActionable: Bool {
        switch self {
        case .refreshDue, .expired: return true
        case .current, .unrecorded: return false
        }
    }

    /// The chip's word.
    var title: String {
        switch self {
        case .current: return "Current"
        case .refreshDue: return "Re-sign"
        case .expired: return "Expired"
        case .unrecorded: return "No expiry"
        }
    }

    /// The badge kind the row uses.
    var tone: SideloadStatusTone {
        switch self {
        case .current: return .success
        case .refreshDue: return .warning
        case .expired: return .error
        case .unrecorded: return .neutral
        }
    }
}

/// The four tones a studio row can carry, mapped to badges by the interface.
/// Kept here so the status rules stay testable without SwiftUI.
enum SideloadStatusTone: Equatable, Hashable, Sendable {
    case success
    case warning
    case error
    case neutral
}

/// How many apps one account currently holds, against the limit it publishes.
struct SideloadAccountUsage: Equatable, Sendable {

    /// The account being counted.
    let account: SideloadAccount

    /// How many leases the account signed that have not expired.
    let installed: Int

    /// The limit, when the account publishes one.
    var limit: Int? { account.concurrentAppLimit }

    /// Whether the account holds more live leases than it may install at once.
    var isOverLimit: Bool {
        guard let limit else { return false }
        return installed > limit
    }

    /// How many more apps the account may install, or `nil` when unlimited.
    var remaining: Int? {
        guard let limit else { return nil }
        return max(0, limit - installed)
    }

    /// The one-line state the studio shows beside the account.
    var summary: String {
        guard let limit else {
            return "\(installed) installed · no app limit"
        }
        if isOverLimit {
            return "\(installed) of \(limit) installed · over the limit"
        }
        return "\(installed) of \(limit) installed"
    }
}

/// What the journal says has to be signed again, and when.
///
/// The plan is a partition, not a filter: every lease the journal produced
/// appears in exactly one of the four lists, so a screen can show the whole
/// picture instead of only the urgent part.
struct SideloadRefreshPlan: Equatable, Sendable {

    /// Inside the lead window, or already past it. Most urgent first: expired
    /// before due, and the nearest expiry before the furthest.
    let due: [SideloadLease]

    /// Healthy, soonest expiry first.
    let healthy: [SideloadLease]

    /// No expiry was recorded. Listed, never counted as healthy or as due.
    let unrecorded: [SideloadLease]

    /// An empty plan, for a model that has not read the journal yet.
    static let empty = SideloadRefreshPlan(due: [], healthy: [], unrecorded: [])

    /// How many leases need a re-sign.
    var dueCount: Int { due.count }

    /// How many of the due leases have already stopped launching at `now`.
    /// Asked with a date rather than read from the clock, so the answer is the
    /// same one the plan was built from.
    func expiredCount(at now: Date) -> Int {
        due.filter { $0.status(at: now) == .expired }.count
    }

    /// Whether nothing needs anything.
    var isClear: Bool { due.isEmpty }

    /// Whether the plan holds no lease in any of its lists — a journal that has
    /// not produced a delivered run, rather than a healthy one.
    var isEmpty: Bool { due.isEmpty && healthy.isEmpty && unrecorded.isEmpty }

    /// The soonest date any lease stops launching, due or not.
    var nearestExpiry: Date? {
        (due + healthy).compactMap(\.expiresAt).min()
    }

    /// The partition itself.
    ///
    /// Ordering inside each list is by the date that ends the lease, ascending,
    /// so the first row of the refresh queue is always the one that stops
    /// working first. Leases with no expiry sort last, by name, so the list is
    /// stable between reads.
    static func plan(_ leases: [SideloadLease], at now: Date) -> SideloadRefreshPlan {
        var due: [SideloadLease] = []
        var healthy: [SideloadLease] = []
        var unrecorded: [SideloadLease] = []
        for lease in leases {
            switch lease.status(at: now) {
            case .expired, .refreshDue:
                due.append(lease)
            case .current:
                healthy.append(lease)
            case .unrecorded:
                unrecorded.append(lease)
            }
        }
        return SideloadRefreshPlan(
            due: due.sorted { first, second in
                switch (first.expiresAt, second.expiresAt) {
                case let (firstDate?, secondDate?):
                    if firstDate != secondDate { return firstDate < secondDate }
                    return first.displayName < second.displayName
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return first.displayName < second.displayName
                }
            },
            healthy: healthy.sorted { first, second in
                switch (first.expiresAt, second.expiresAt) {
                case let (firstDate?, secondDate?):
                    if firstDate != secondDate { return firstDate < secondDate }
                    return first.displayName < second.displayName
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return first.displayName < second.displayName
                }
            },
            unrecorded: unrecorded.sorted { $0.displayName < $1.displayName }
        )
    }
}
