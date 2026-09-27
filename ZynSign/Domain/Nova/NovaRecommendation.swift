import Foundation

// MARK: - Nova Assistant — on-device, rule-based, never autonomous

/// One thing Nova noticed and suggests. Nova never acts: every
/// recommendation is a sentence and an optional destination the user may
/// open. No network, no model download, no telemetry — the rules below read
/// facts the app already holds.
struct NovaRecommendation: Equatable, Hashable, Identifiable, Sendable {

    enum Kind: String, CaseIterable, Hashable, Sendable {
        case certificateExpiring
        case certificateExpired
        case profileExpiring
        case profileExpired
        case matchingProfileExists
        case noProfileForApp
        case previouslySignedApp
        case duplicateBundle
        case backupRecommended
        case noIdentityYet
        case noProfileYet
    }

    enum Severity: Int, Comparable, Hashable, Sendable {
        case info = 0
        case attention = 1
        case urgent = 2

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Where the user may go to act on it. Nova only points; it never opens.
    enum Destination: String, Hashable, Sendable {
        case certificates
        case profiles
        case library
        case signing
        case backup
    }

    let kind: Kind
    let severity: Severity
    let title: String
    let detail: String
    let destination: Destination?
    /// A stable identity so the interface can dismiss or animate one item.
    let subject: String

    var id: String { "\(kind.rawValue):\(subject)" }
}

// MARK: - Facts

/// Everything Nova reasons about, as plain values. The Application layer
/// assembles these from the stores the tabs already read; the Domain never
/// touches a store.
struct NovaFacts: Equatable, Sendable {

    struct CertificateFact: Equatable, Hashable, Sendable {
        let name: String
        let expiresAt: Date
    }

    struct ProfileFact: Equatable, Hashable, Sendable {
        let name: String
        let expiresAt: Date
        /// Application-identifier patterns without the team prefix, e.g.
        /// `com.example.app` or `com.example.*` or `*`.
        let bundleIdentifierPatterns: [String]
    }

    struct ApplicationFact: Equatable, Hashable, Sendable {
        let displayName: String
        let bundleIdentifier: String
        let importedAt: Date
        let wasSignedBefore: Bool
    }

    var certificates: [CertificateFact] = []
    var profiles: [ProfileFact] = []
    var applications: [ApplicationFact] = []
    /// Days since the last backup; `nil` when none was ever made.
    var daysSinceBackup: Int? = nil

    init(
        certificates: [CertificateFact] = [],
        profiles: [ProfileFact] = [],
        applications: [ApplicationFact] = [],
        daysSinceBackup: Int? = nil
    ) {
        self.certificates = certificates
        self.profiles = profiles
        self.applications = applications
        self.daysSinceBackup = daysSinceBackup
    }
}

// MARK: - Advisor

/// The rule set. Pure and deterministic: the same facts and clock give the
/// same recommendations in the same order (urgent first, then by title).
struct NovaAdvisor: Sendable {

    /// Certificates and profiles within this many days of expiry are flagged.
    var expiryWarningDays = 14
    /// A backup older than this is recommended.
    var backupReminderDays = 7
    /// At most this many suggestions are returned — Nova is quiet by design.
    var limit = 6

    init(expiryWarningDays: Int = 14, backupReminderDays: Int = 7, limit: Int = 6) {
        self.expiryWarningDays = expiryWarningDays
        self.backupReminderDays = backupReminderDays
        self.limit = limit
    }

    func recommendations(for facts: NovaFacts, now: Date) -> [NovaRecommendation] {
        var out: [NovaRecommendation] = []

        // Identities
        if facts.certificates.isEmpty, !facts.applications.isEmpty {
            out.append(NovaRecommendation(
                kind: .noIdentityYet, severity: .attention,
                title: "No signing identity yet",
                detail: "Import a .p12 certificate to sign the \(facts.applications.count == 1 ? "app" : "apps") in your library.",
                destination: .certificates, subject: "identities"))
        }
        for certificate in facts.certificates {
            let days = Self.wholeDays(from: now, to: certificate.expiresAt)
            if days < 0 {
                out.append(NovaRecommendation(
                    kind: .certificateExpired, severity: .urgent,
                    title: "\(certificate.name) has expired",
                    detail: "Apps signed with it will stop launching once their profile lapses. Import a current certificate.",
                    destination: .certificates, subject: certificate.name))
            } else if days <= expiryWarningDays {
                out.append(NovaRecommendation(
                    kind: .certificateExpiring, severity: days <= 3 ? .urgent : .attention,
                    title: "\(certificate.name) expires in \(Self.dayPhrase(days))",
                    detail: "Sign anything you still need before then, or import a renewed certificate.",
                    destination: .certificates, subject: certificate.name))
            }
        }

        // Profiles
        if facts.profiles.isEmpty, !facts.certificates.isEmpty {
            out.append(NovaRecommendation(
                kind: .noProfileYet, severity: .attention,
                title: "No provisioning profile yet",
                detail: "A profile that names your devices is required before signing.",
                destination: .profiles, subject: "profiles"))
        }
        for profile in facts.profiles {
            let days = Self.wholeDays(from: now, to: profile.expiresAt)
            if days < 0 {
                out.append(NovaRecommendation(
                    kind: .profileExpired, severity: .urgent,
                    title: "Profile “\(profile.name)” has expired",
                    detail: "Apps installed with it will stop launching. Import a renewed profile.",
                    destination: .profiles, subject: profile.name))
            } else if days <= expiryWarningDays {
                out.append(NovaRecommendation(
                    kind: .profileExpiring, severity: days <= 3 ? .urgent : .attention,
                    title: "Profile “\(profile.name)” expires in \(Self.dayPhrase(days))",
                    detail: "Re-sign the apps that use it once you have a renewed profile.",
                    destination: .profiles, subject: profile.name))
            }
        }

        // Applications
        let grouped = Dictionary(grouping: facts.applications, by: { $0.bundleIdentifier })
        for (bundle, apps) in grouped where apps.count > 1 {
            out.append(NovaRecommendation(
                kind: .duplicateBundle, severity: .attention,
                title: "\(apps.count) apps share \(bundle)",
                detail: "Only one can be installed at a time; installing another replaces it. Keep the version you mean to use.",
                destination: .library, subject: bundle))
        }
        let validProfiles = facts.profiles.filter { $0.expiresAt > now }
        for app in facts.applications.sorted(by: { $0.importedAt > $1.importedAt }).prefix(5) {
            let matching = validProfiles.filter { profile in
                profile.bundleIdentifierPatterns.contains { Self.pattern($0, matches: app.bundleIdentifier) }
            }
            if app.wasSignedBefore {
                out.append(NovaRecommendation(
                    kind: .previouslySignedApp, severity: .info,
                    title: "\(app.displayName) was signed successfully before",
                    detail: "Its previous identity and profile are a safe starting point.",
                    destination: .signing, subject: app.bundleIdentifier))
            } else if let profile = matching.first {
                out.append(NovaRecommendation(
                    kind: .matchingProfileExists, severity: .info,
                    title: "A matching profile exists for \(app.displayName)",
                    detail: "“\(profile.name)” already covers \(app.bundleIdentifier).",
                    destination: .signing, subject: app.bundleIdentifier))
            } else if !facts.profiles.isEmpty {
                out.append(NovaRecommendation(
                    kind: .noProfileForApp, severity: .attention,
                    title: "No profile covers \(app.displayName)",
                    detail: "None of your profiles names \(app.bundleIdentifier). A wildcard or matching profile is needed to sign it.",
                    destination: .profiles, subject: app.bundleIdentifier))
            }
        }

        // Backup
        if let days = facts.daysSinceBackup, days >= backupReminderDays {
            out.append(NovaRecommendation(
                kind: .backupRecommended, severity: .info,
                title: "Backup recommended",
                detail: "Your last backup was \(Self.dayPhrase(days)) ago.",
                destination: .backup, subject: "backup"))
        }

        return Array(out
            .sorted { lhs, rhs in
                if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            .prefix(limit))
    }

    // MARK: - Helpers

    /// Whole days from `from` to `to`; negative when `to` is in the past.
    static func wholeDays(from: Date, to: Date) -> Int {
        Int((to.timeIntervalSince(from) / 86_400).rounded(.down))
    }

    static func dayPhrase(_ days: Int) -> String {
        switch days {
        case 0: return "less than a day"
        case 1: return "1 day"
        default: return "\(days) days"
        }
    }

    /// Matches an App ID pattern (`*`, `com.example.*`, `com.example.app`)
    /// against a bundle identifier. A leading team prefix (`TEAMID.`) on the
    /// pattern is tolerated and ignored.
    static func pattern(_ rawPattern: String, matches bundleIdentifier: String) -> Bool {
        var pattern = rawPattern
        // Strip a 10-character alphanumeric team prefix if present.
        let parts = pattern.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, parts[0].count == 10, parts[0].allSatisfy({ $0.isLetter || $0.isNumber }), parts[0].uppercased() == parts[0] {
            pattern = String(parts[1])
        }
        if pattern == "*" { return true }
        if pattern.hasSuffix(".*") {
            let prefix = String(pattern.dropLast(1)) // keep the trailing dot
            return bundleIdentifier.hasPrefix(prefix)
        }
        if pattern.hasSuffix("*") {
            return bundleIdentifier.hasPrefix(String(pattern.dropLast()))
        }
        return pattern == bundleIdentifier
    }
}
