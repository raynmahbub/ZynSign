import Foundation

/// The account behind a signature: what it is allowed to sign, how long its
/// output keeps launching, and what its profile can never carry.
///
/// A sideloaded build is not permanent. The profile that authorises it is
/// issued for a fixed period, and when that period ends the app stops
/// opening — not because anything changed on the device, but because the
/// signature's own lease ran out. The period is the account's, not the app's:
/// a free Apple ID issues a seven-day profile, a paid membership issues a
/// year, and an in-house membership issues a year to devices that never had to
/// be registered at all. Knowing which account signed a build is therefore the
/// only way to answer the one question a sideloading tool must answer *before*
/// the answer becomes "it stopped working": when does this needs re-signing?
///
/// The values here are the platform's published limits. They are the policy
/// this app plans with, never evidence that a particular profile was issued
/// under them — the profile's own expiry, held on the lease, is the authority.
/// A build signed with a profile that expires sooner than its account's
/// nominal lifetime is planned by the profile, not by this table.
enum SideloadAccount: String, CaseIterable, Hashable, Sendable, Codable {

    /// A free Apple ID's personal team. Seven-day profiles, three apps at a
    /// time, and a profile that cannot carry most of the platform's services.
    case personalTeam

    /// A paid Apple Developer Program membership. Year-long profiles for
    /// development, ad hoc, and App Store distribution.
    case developerProgram

    /// An Apple Developer Enterprise Program membership. Year-long profiles
    /// that install on the organisation's own devices without registering
    /// them, and that may not be distributed outside the organisation.
    case enterpriseProgram

    /// No account took part: an ad-hoc signature with no certificate chain.
    /// Nothing expires, and no installer accepts it either.
    case adHoc

    // MARK: - Identity

    /// The name the studio shows.
    var displayName: String {
        switch self {
        case .personalTeam: return "Personal Team"
        case .developerProgram: return "Developer Program"
        case .enterpriseProgram: return "Enterprise Program"
        case .adHoc: return "Ad Hoc"
        }
    }

    /// The two-or-three-word label a chip carries.
    var shortLabel: String {
        switch self {
        case .personalTeam: return "Free"
        case .developerProgram: return "Developer"
        case .enterpriseProgram: return "Enterprise"
        case .adHoc: return "Unsigned"
        }
    }

    /// One sentence about what this account is.
    var summary: String {
        switch self {
        case .personalTeam:
            return "A free Apple ID. The profile lasts seven days, and three apps may be installed at once."
        case .developerProgram:
            return "A paid membership. Profiles last a year, and ad hoc builds install on the devices the profile lists."
        case .enterpriseProgram:
            return "An in-house membership. Profiles last a year and install on your organisation's devices without registering them."
        case .adHoc:
            return "No account and no certificate. The signature has no chain, so only the guest container can run the result."
        }
    }

    // MARK: - The limits

    /// How long a profile this account issues lasts, in days. `nil` when the
    /// account has no profile at all.
    var profileLifetimeDays: Int? {
        switch self {
        case .personalTeam: return 7
        case .developerProgram, .enterpriseProgram: return 365
        case .adHoc: return nil
        }
    }

    /// How many days before expiry the studio asks for a re-sign.
    ///
    /// A week-long profile gets two days: enough to notice, not so much that
    /// every build is permanently "due". A year-long profile gets three weeks,
    /// which covers a holiday without nagging.
    var refreshLeadDays: Int {
        switch self {
        case .personalTeam: return 2
        case .developerProgram: return 21
        case .enterpriseProgram: return 45
        case .adHoc: return 0
        }
    }

    /// How many apps signed by this account may be installed at once.
    var concurrentAppLimit: Int? {
        switch self {
        case .personalTeam: return 3
        case .developerProgram, .enterpriseProgram, .adHoc: return nil
        }
    }

    /// How many new App IDs the account may register in a rolling week.
    var weeklyAppIdentifierLimit: Int? {
        switch self {
        case .personalTeam: return 10
        case .developerProgram, .enterpriseProgram, .adHoc: return nil
        }
    }

    /// How many new devices the account may register in a rolling week.
    var weeklyDeviceLimit: Int? {
        switch self {
        case .personalTeam: return 3
        case .developerProgram, .enterpriseProgram, .adHoc: return nil
        }
    }

    /// How many devices a development or ad hoc profile may list at once.
    var registeredDeviceLimit: Int? {
        switch self {
        case .developerProgram: return 100
        case .personalTeam, .enterpriseProgram, .adHoc: return nil
        }
    }

    /// Whether the devices a build installs on have to be registered with the
    /// account first. An in-house profile does not list devices at all.
    var requiresDeviceRegistration: Bool {
        switch self {
        case .personalTeam, .developerProgram: return true
        case .enterpriseProgram, .adHoc: return false
        }
    }

    /// Whether a build has to be replaced at least once a week to keep
    /// launching — the fact that makes refresh a routine rather than an
    /// emergency.
    var requiresWeeklyRefresh: Bool {
        profileLifetimeDays == 7
    }

    /// Services a profile issued to this account cannot carry.
    ///
    /// Fixed text, and deliberately short: it is the list a person needs in
    /// order to understand why an app that works when built by Xcode with a
    /// paid team refuses to work here with a free one.
    var uncarriedCapabilities: [String] {
        switch self {
        case .personalTeam:
            return [
                "Push Notifications", "iCloud", "App Groups", "HealthKit",
                "HomeKit", "Wallet", "CarPlay", "NFC",
            ]
        case .developerProgram, .enterpriseProgram, .adHoc:
            return []
        }
    }

    /// The limit rows the studio shows, in a fixed order, already worded.
    var limitRows: [SideloadAccountLimit] {
        var rows: [SideloadAccountLimit] = []
        if let days = profileLifetimeDays {
            rows.append(SideloadAccountLimit("Profile lifetime", days == 7 ? "7 days" : "\(days) days"))
        }
        rows.append(SideloadAccountLimit("Re-sign before", refreshLeadDays == 0
            ? "Every install"
            : "\(refreshLeadDays) day\(refreshLeadDays == 1 ? "" : "s") before expiry"))
        if let limit = concurrentAppLimit {
            rows.append(SideloadAccountLimit("Installed at once", "\(limit) apps"))
        }
        if let limit = weeklyAppIdentifierLimit {
            rows.append(SideloadAccountLimit("New App IDs", "\(limit) per week"))
        }
        if let limit = weeklyDeviceLimit {
            rows.append(SideloadAccountLimit("New devices", "\(limit) per week"))
        }
        if let limit = registeredDeviceLimit {
            rows.append(SideloadAccountLimit("Registered devices", "\(limit) per profile"))
        }
        return rows
    }

    // MARK: - Reading an account off what is already known

    /// The account a profile's own classification implies.
    ///
    /// Development covers both a free personal team and a paid membership —
    /// the profile does not say which — so it maps to `nil` here and is
    /// settled by the lifetime or by the person. Ad hoc and App Store profiles
    /// are only issued to paid memberships.
    static func account(for profileType: ProvisioningProfileClassification?) -> SideloadAccount? {
        switch profileType {
        case .enterprise:
            return .enterpriseProgram
        case .adHoc, .appStore:
            return .developerProgram
        case .development, .unknown, .none:
            return nil
        }
    }

    /// The account a profile's lifetime implies, when nothing closer is known.
    ///
    /// A profile that lasts about a week is a personal team's: no paid
    /// membership issues one. A profile that lasts about a year is a paid
    /// membership's, but which of the two is not established by the date
    /// alone, so it is left to the profile's classification.
    static func account(forProfileLifetimeDays days: Int?) -> SideloadAccount? {
        guard let days else { return nil }
        if days <= shortLifetimeCeilingDays { return .personalTeam }
        return nil
    }

    /// The longest lifetime still read as a personal team's: a week, plus the
    /// day of slack a device clock or a time-zone boundary can add.
    static let shortLifetimeCeilingDays = 8

    /// The account behind one signing run, from the facts a record holds.
    ///
    /// The profile's classification is the strongest signal; its lifetime
    /// settles the development case. When neither is available the answer is
    /// `nil` — an account that was not established, never a guess.
    static func infer(
        profileType: ProvisioningProfileClassification?,
        profileExpiresAt: Date?,
        signedAt: Date
    ) -> SideloadAccount? {
        if let account = account(for: profileType) { return account }
        guard let profileExpiresAt else { return nil }
        let days = Int((profileExpiresAt.timeIntervalSince(signedAt) / 86_400).rounded())
        return account(forProfileLifetimeDays: days)
    }
}

/// One published limit, already worded for the row that shows it.
///
/// A value rather than a tuple: the studio groups these by the title, and a
/// named type keeps the row's identity in the domain instead of in a key path.
struct SideloadAccountLimit: Identifiable, Equatable, Hashable, Sendable {

    /// The row's own name, which is also its identity — an account never
    /// publishes the same limit twice.
    let title: String

    /// The limit, in the words the row shows.
    let value: String

    var id: String { title }

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }
}
