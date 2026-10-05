import Foundation

/// The kinds of signing-relationship conflict the Identity Center detects.
///
/// Detection is an observation of the user's own holdings — certificates,
/// profiles, and the library — read together at one instant. No kind of
/// conflict is a trust verdict or a platform statement, and a conflict the
/// detector misses is not evidence that none exists: detection runs over
/// the facts ZynSign holds, nothing more.
enum IdentityConflictKind: String, CaseIterable, Equatable, Hashable, Sendable {

    /// Two or more local certificates declare the same team and the same
    /// subject name — most often the same certificate imported twice.
    case duplicateCertificates

    /// A team has more than one usable certificate of the same purpose and
    /// no default is set, so a signing run cannot say which to use.
    case multipleMatchingCertificates

    /// A profile's team disagrees with the team of a certificate it
    /// embeds.
    case teamMismatch

    /// A team holds usable certificates but no profile of any kind.
    case missingProfile

    /// A profile has passed its expiration date.
    case expiredProfile

    /// A profile names embedded certificates, none of which is on the
    /// device, so the profile cannot sign with what ZynSign holds.
    case orphanedProfile

    /// The title the conflict list shows.
    var displayName: String {
        switch self {
        case .duplicateCertificates: return "Duplicate Certificates"
        case .multipleMatchingCertificates: return "Multiple Matching Certificates"
        case .teamMismatch: return "Team Mismatch"
        case .missingProfile: return "Missing Profile"
        case .expiredProfile: return "Expired Profile"
        case .orphanedProfile: return "Orphaned Profile"
        }
    }
}

/// How urgently a conflict wants attention.
enum IdentityConflictSeverity: String, Equatable, Hashable, Sendable {

    /// Signing with the affected identity still works; the situation is
    /// confusing or wasteful rather than blocking.
    case warning

    /// A signing run with the affected identity will not complete.
    case blocked

    /// The sentence VoiceOver reads for the severity.
    var spokenSummary: String {
        switch self {
        case .warning: return "Warning"
        case .blocked: return "Blocking conflict"
        }
    }
}

/// One detected conflict between the identities the user holds.
///
/// A conflict carries fixed, composed language — never a raw error, never
/// a secret, and never key material — together with the identifiers of the
/// subjects involved so a screen can link to them. The `remedy` says what
/// the user can do about it; the Identity Center never applies a remedy on
/// its own.
struct IdentityConflict: Identifiable, Equatable, Hashable, Sendable {

    /// The kind of conflict.
    let kind: IdentityConflictKind

    /// How urgently it wants attention.
    let severity: IdentityConflictSeverity

    /// The Team ID the conflict is about, when the conflict is team-scoped.
    let teamID: String?

    /// The one-line title.
    let title: String

    /// What was found, in one or two sentences of fixed language.
    let message: String

    /// What the user can do about it.
    let remedy: String

    /// The certificates involved, by fingerprint.
    let certificateFingerprints: [String]

    /// The profiles involved, by library identifier.
    let profileIDs: [ProvisioningProfileIdentifier]

    /// The stable identity of the conflict: its kind and the subjects
    /// involved. Two scans that find the same facts find the same ID.
    var id: String {
        let certificates = certificateFingerprints.sorted().joined(separator: ",")
        let profiles = profileIDs.map(\.rawValue).sorted().joined(separator: ",")
        let team = teamID ?? "-"
        return "\(kind.rawValue)|\(team)|\(certificates)|\(profiles)"
    }

    /// Creates a conflict from its parts.
    init(
        kind: IdentityConflictKind,
        severity: IdentityConflictSeverity,
        teamID: String?,
        title: String,
        message: String,
        remedy: String,
        certificateFingerprints: [String],
        profileIDs: [ProvisioningProfileIdentifier]
    ) {
        self.kind = kind
        self.severity = severity
        self.teamID = teamID
        self.title = title
        self.message = message
        self.remedy = remedy
        self.certificateFingerprints = certificateFingerprints
        self.profileIDs = profileIDs
    }
}

/// The Smart Conflict Detection engine.
///
/// The detector is pure: it reads the certificate facts, the profile
/// facts, and the default-identity mark, and reports every conflict those
/// facts contain. Its rules, in the order the results are reported:
///
/// 1. **Duplicate certificates** — two or more local certificates share a
///    team and a subject name. Usually the same credential imported twice.
/// 2. **Multiple matching certificates** — a team holds more than one
///    usable certificate of the same purpose and no default is set.
/// 3. **Team mismatch** — a profile's declared team disagrees with the
///    team of one of its embedded certificates.
/// 4. **Missing profile** — a team holds a usable certificate and no
///    profile at all.
/// 5. **Expired profile** — a profile has passed its expiration date.
/// 6. **Orphaned profile** — a profile's embedded certificates are all
///    absent from the device.
struct IdentityConflictDetector: Sendable {

    /// Creates the detector.
    init() {}

    /// Detects every conflict the facts contain.
    ///
    /// - Parameters:
    ///   - certificates: Every local certificate's facts.
    ///   - profiles: Every stored profile's facts.
    ///   - defaultFingerprintHex: The fingerprint the user marked as the
    ///     default, or `nil`.
    ///   - referenceDate: The instant expiration is judged at.
    /// - Returns: The conflicts, ordered blocked-first and then by kind,
    ///   so the most urgent float up deterministically.
    func detect(
        certificates: [IdentityCertificateFacts],
        profiles: [IdentityProfileFacts],
        defaultFingerprintHex: String?,
        referenceDate: Date
    ) -> [IdentityConflict] {
        var conflicts: [IdentityConflict] = []
        conflicts.append(
            contentsOf: duplicateCertificateConflicts(certificates: certificates)
        )
        conflicts.append(
            contentsOf: multipleMatchingCertificateConflicts(
                certificates: certificates,
                defaultFingerprintHex: defaultFingerprintHex
            )
        )
        conflicts.append(
            contentsOf: teamMismatchConflicts(
                certificates: certificates,
                profiles: profiles
            )
        )
        conflicts.append(
            contentsOf: missingProfileConflicts(
                certificates: certificates,
                profiles: profiles
            )
        )
        conflicts.append(
            contentsOf: expiredProfileConflicts(profiles: profiles, referenceDate: referenceDate)
        )
        conflicts.append(
            contentsOf: orphanedProfileConflicts(
                certificates: certificates,
                profiles: profiles
            )
        )

        return conflicts.sorted { lhs, rhs in
            if lhs.severity != rhs.severity {
                return lhs.severity == .blocked
            }
            let lhsOrder = IdentityConflictKind.allCases.firstIndex(of: lhs.kind) ?? 0
            let rhsOrder = IdentityConflictKind.allCases.firstIndex(of: rhs.kind) ?? 0
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return lhs.id < rhs.id
        }
    }

    // MARK: - Rules

    /// Certificates that share a team and a subject display name.
    private func duplicateCertificateConflicts(
        certificates: [IdentityCertificateFacts]
    ) -> [IdentityConflict] {
        var groups: [String: [IdentityCertificateFacts]] = [:]
        for certificate in certificates {
            let team = certificate.teamID?.uppercased() ?? "-"
            let key = "\(team)|\(certificate.displayName.lowercased())"
            groups[key, default: []].append(certificate)
        }
        return groups.values.compactMap { members in
            guard members.count > 1 else { return nil }
            let fingerprints = members.map(\.fingerprintHex)
            let team = members.first?.teamID
            return IdentityConflict(
                kind: .duplicateCertificates,
                severity: .warning,
                teamID: team,
                title: "Duplicate certificates",
                message: "\(members.count) certificates declare the same name\(team.map { " in team \($0)" } ?? ""). The same credential may have been imported more than once.",
                remedy: "Keep the one you sign with and remove the rest. Removing a registration never deletes the key.",
                certificateFingerprints: fingerprints,
                profileIDs: []
            )
        }
    }

    /// Teams with several usable certificates of one purpose and no
    /// default.
    private func multipleMatchingCertificateConflicts(
        certificates: [IdentityCertificateFacts],
        defaultFingerprintHex: String?
    ) -> [IdentityConflict] {
        var teams: [String: [IdentityCertificateFacts]] = [:]
        for certificate in certificates where certificate.canSignAtEvaluationDate {
            guard let team = certificate.teamID else { continue }
            teams[team.uppercased(), default: []].append(certificate)
        }
        return teams.compactMap { teamKey, members in
            var byKind: [SigningCertificateKind: [IdentityCertificateFacts]] = [:]
            for member in members { byKind[member.kind, default: []].append(member) }
            let ambiguous = byKind.values.filter { $0.count > 1 }
            guard let group = ambiguous.first, defaultFingerprintHex == nil else { return nil }
            let team = group.first?.teamID
            let fingerprints = group.map(\.fingerprintHex)
            let purpose = group.first?.kind.displayName.lowercased() ?? "signing"
            return IdentityConflict(
                kind: .multipleMatchingCertificates,
                severity: .warning,
                teamID: team,
                title: "Multiple matching certificates",
                message: "Multiple compatible \(purpose) certificates were found for this team. Choose a default identity so signing has a clear first choice.",
                remedy: "Set one of the certificates as the default in the Identity Center.",
                certificateFingerprints: fingerprints,
                profileIDs: []
            )
        }
    }

    /// Profiles whose declared team disagrees with an embedded
    /// certificate's team.
    private func teamMismatchConflicts(
        certificates: [IdentityCertificateFacts],
        profiles: [IdentityProfileFacts]
    ) -> [IdentityConflict] {
        var conflicts: [IdentityConflict] = []
        for profile in profiles {
            guard let profileTeam = profile.teamID else { continue }
            let embedded = certificates.filter { certificate in
                profile.certificateFingerprints.contains(certificate.fingerprintHex)
            }
            let mismatched = embedded.filter { certificate in
                guard let certificateTeam = certificate.teamID else { return false }
                return certificateTeam.caseInsensitiveCompare(profileTeam) != .orderedSame
            }
            guard let first = mismatched.first else { continue }
            conflicts.append(IdentityConflict(
                kind: .teamMismatch,
                severity: .blocked,
                teamID: profileTeam,
                title: "Team mismatch",
                message: "The profile “\(profile.name)” declares team \(profileTeam), but an embedded certificate declares \(first.teamID ?? "no team"). Signing would embed disagreeing teams.",
                remedy: "Re-import the correct profile, or sign with a certificate that matches the profile's team.",
                certificateFingerprints: mismatched.map(\.fingerprintHex),
                profileIDs: [profile.id]
            ))
        }
        return conflicts
    }

    /// Teams holding a usable certificate and no profile.
    private func missingProfileConflicts(
        certificates: [IdentityCertificateFacts],
        profiles: [IdentityProfileFacts]
    ) -> [IdentityConflict] {
        let profileTeams = Set(profiles.compactMap { $0.teamID?.uppercased() })
        var teams: [String: IdentityCertificateFacts] = [:]
        for certificate in certificates where certificate.canSignAtEvaluationDate {
            guard let team = certificate.teamID else { continue }
            let key = team.uppercased()
            if teams[key] == nil { teams[key] = certificate }
        }
        return teams.compactMap { key, certificate in
            guard !profileTeams.contains(key) else { return nil }
            return IdentityConflict(
                kind: .missingProfile,
                severity: .warning,
                teamID: certificate.teamID,
                title: "Missing profile",
                message: "Team \(certificate.teamID ?? "") has a usable certificate but no provisioning profile. Signing needs a profile that matches the app and the team.",
                remedy: "Import a .mobileprovision for this team in Certificates & Profiles → Profiles.",
                certificateFingerprints: [certificate.fingerprintHex],
                profileIDs: []
            )
        }
    }

    /// Expired profiles, one conflict each.
    private func expiredProfileConflicts(
        profiles: [IdentityProfileFacts],
        referenceDate: Date
    ) -> [IdentityConflict] {
        profiles.compactMap { profile in
            guard profile.isExpired(referenceDate: referenceDate) else { return nil }
            return IdentityConflict(
                kind: .expiredProfile,
                severity: .blocked,
                teamID: profile.teamID,
                title: "Expired profile",
                message: "The profile “\(profile.name)” expired \(formattedPastDays(profile.daysUntilExpiration(referenceDate: referenceDate))).",
                remedy: "Renew the profile in your developer account and import the replacement.",
                certificateFingerprints: [],
                profileIDs: [profile.id]
            )
        }
    }

    /// Profiles whose embedded certificates are all absent.
    private func orphanedProfileConflicts(
        certificates: [IdentityCertificateFacts],
        profiles: [IdentityProfileFacts]
    ) -> [IdentityConflict] {
        let localFingerprints = Set(certificates.map(\.fingerprintHex))
        return profiles.compactMap { profile in
            let embedded = profile.certificateFingerprints
            guard !embedded.isEmpty else { return nil }
            guard embedded.allSatisfy({ !localFingerprints.contains($0) }) else { return nil }
            return IdentityConflict(
                kind: .orphanedProfile,
                severity: .warning,
                teamID: profile.teamID,
                title: "Orphaned profile",
                message: "None of the certificates the profile “\(profile.name)” embeds is on this device.",
                remedy: "Import the matching .p12 certificate, or remove the profile if it is no longer used.",
                certificateFingerprints: [],
                profileIDs: [profile.id]
            )
        }
    }

    /// "5 days ago" / "today" from a negative day count.
    private func formattedPastDays(_ days: Int) -> String {
        let past = abs(days)
        if past == 0 { return "today" }
        return "\(past) day\(past == 1 ? "" : "s") ago"
    }
}
