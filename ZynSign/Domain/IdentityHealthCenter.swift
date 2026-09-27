import Foundation

/// The overall health of one identity in the Identity Center.
///
/// Health is a workflow signal, not a trust verdict: 🟢 Healthy means the
/// checks that apply found nothing to report, 🟡 Warning means signing is
/// possible today but something is expiring or unmatched, and 🔴 Blocked
/// means the identity cannot complete a signing run as it stands. The
/// status is spoken by VoiceOver through `spokenSummary`.
enum IdentityHealthStatus: String, CaseIterable, Equatable, Hashable, Sendable {

    /// Every applicable check passed.
    case healthy

    /// Signing is possible now, but at least one check wants attention.
    case warning

    /// At least one check blocks signing.
    case blocked

    /// The symbol the health lists show.
    var symbolName: String {
        switch self {
        case .healthy: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .blocked: return "xmark.octagon.fill"
        }
    }

    /// The sentence VoiceOver reads for the status alone.
    var spokenSummary: String {
        switch self {
        case .healthy: return "Healthy. Ready to sign."
        case .warning: return "Needs attention. Signing works today, but something is expiring or unmatched."
        case .blocked: return "Blocked. This identity cannot sign in its current state."
        }
    }

    /// The worse of two statuses, so a report can fold its checks.
    static func combine(_ lhs: IdentityHealthStatus, _ rhs: IdentityHealthStatus) -> IdentityHealthStatus {
        switch (lhs, rhs) {
        case (.blocked, _), (_, .blocked): return .blocked
        case (.warning, _), (_, .warning): return .warning
        default: return .healthy
        }
    }
}

/// The outcome of one health check.
enum IdentityHealthCheckOutcome: String, Equatable, Hashable, Sendable {

    /// The check found nothing to report.
    case pass

    /// The check found something that wants attention but does not block.
    case warning

    /// The check found something that blocks signing.
    case blocked

    /// The check does not apply to this identity — for example the
    /// team-match check on a subject that declares no team. An
    /// unapplicable check is neither good nor bad and is displayed as such.
    case notApplicable

    /// Whether the check concluded with a finding.
    var isConclusive: Bool { self != .notApplicable }

    /// The sentence VoiceOver reads for the outcome.
    var spokenSummary: String {
        switch self {
        case .pass: return "Passed"
        case .warning: return "Warning"
        case .blocked: return "Blocked"
        case .notApplicable: return "Not applicable"
        }
    }
}

/// Which question a health check answers.
enum IdentityHealthCheckKind: String, CaseIterable, Equatable, Hashable, Sendable {

    /// The certificate is inside its validity window.
    case certificateValid

    /// The private key behind the certificate was observed available.
    case keyAvailable

    /// The profile is inside its validity window and carries declarations.
    case profileValid

    /// The teams a certificate and its profiles declare agree.
    case teamMatch

    /// The remaining validity is above the warning threshold.
    case expiration

    /// The profile covers at least one application in the library.
    case bundleCompatible

    /// The check's title, as the health lists show it.
    var displayName: String {
        switch self {
        case .certificateValid: return "Certificate Valid"
        case .keyAvailable: return "Key Available"
        case .profileValid: return "Profile Valid"
        case .teamMatch: return "Team Match"
        case .expiration: return "Expiration"
        case .bundleCompatible: return "Bundle Compatible"
        }
    }
}

/// One evaluated health check.
struct IdentityHealthCheck: Identifiable, Equatable, Hashable, Sendable {

    /// Which question this answers.
    let kind: IdentityHealthCheckKind

    /// What the check found, in one sentence. Never a secret and never a
    /// raw error: the engines compose fixed language from the facts.
    let detail: String

    /// The outcome.
    let outcome: IdentityHealthCheckOutcome

    /// The check's identity in a list.
    var id: IdentityHealthCheckKind { kind }

    /// Creates a check from its parts.
    init(kind: IdentityHealthCheckKind, detail: String, outcome: IdentityHealthCheckOutcome) {
        self.kind = kind
        self.detail = detail
        self.outcome = outcome
    }
}

/// Which subject a health report describes.
enum IdentityHealthSubject: Equatable, Hashable, Sendable {

    /// A certificate, named by its SHA-256 fingerprint.
    case certificate(fingerprintHex: String)

    /// A provisioning profile, named by its library identifier.
    case profile(ProvisioningProfileIdentifier)

    /// The sentence VoiceOver reads to introduce the subject.
    var spokenName: String {
        switch self {
        case .certificate: return "Certificate"
        case .profile: return "Provisioning profile"
        }
    }
}

/// The health of one identity: its checks, the folded overall status, and
/// a spoken summary.
///
/// A report is computed from facts at one instant and is cached with its
/// snapshot; it never re-reads a store. The overall status folds the
/// conclusive checks: any blocked check blocks, any warning warns, and a
/// report whose checks all passed — or that carries only inapplicable
/// checks — is healthy.
struct IdentityHealthReport: Equatable, Hashable, Sendable {

    /// The subject the report describes.
    let subject: IdentityHealthSubject

    /// The subject's display name at the time the report was computed.
    let subjectName: String

    /// The checks, in the order they are displayed.
    let checks: [IdentityHealthCheck]

    /// The folded status of the conclusive checks.
    let status: IdentityHealthStatus

    /// The instant the report was computed at.
    let evaluatedAt: Date

    /// The sentence VoiceOver reads for the whole report.
    var spokenSummary: String {
        let blocking = checks.filter { $0.outcome == .blocked }.count
        let warnings = checks.filter { $0.outcome == .warning }.count
        var summary = "\(subject.spokenName) \(subjectName). \(status.spokenSummary)"
        if blocking > 0 { summary += " \(blocking) blocked check\(blocking == 1 ? "" : "s")." }
        if warnings > 0 { summary += " \(warnings) warning\(warnings == 1 ? "" : "s")." }
        return summary
    }

    /// Creates a report, folding its checks into the overall status.
    init(
        subject: IdentityHealthSubject,
        subjectName: String,
        checks: [IdentityHealthCheck],
        evaluatedAt: Date
    ) {
        self.subject = subject
        self.subjectName = subjectName
        self.checks = checks
        self.evaluatedAt = evaluatedAt
        self.status = checks.reduce(IdentityHealthStatus.healthy) { partial, check in
            guard check.outcome.isConclusive else { return partial }
            let checkStatus: IdentityHealthStatus
            switch check.outcome {
            case .pass: checkStatus = .healthy
            case .warning: checkStatus = .warning
            case .blocked: checkStatus = .blocked
            case .notApplicable: checkStatus = .healthy
            }
            return IdentityHealthStatus.combine(partial, checkStatus)
        }
    }
}

/// The Identity Health engine: computes each identity's health from facts.
///
/// The engine is pure. It reads no store and no clock; every call carries
/// the facts and the reference instant. Checks that cannot be answered by
/// the facts — for example a certificate's team match with no linked
/// profiles — report `notApplicable` rather than guessing.
///
/// What health is not: a trust evaluation, a chain validation, a platform
/// acceptance prediction, or a promise that a signing run will succeed.
/// The signing pipeline re-checks everything it needs when it runs.
struct IdentityHealthEngine: Sendable {

    /// Creates the engine.
    init() {}

    /// Computes the health of one certificate.
    ///
    /// - Parameters:
    ///   - certificate: The certificate's facts.
    ///   - linkedProfiles: The profiles that name the certificate's
    ///     fingerprint among their embedded certificates, or that declare
    ///     the same team. The caller decides the linkage; the engine only
    ///     evaluates it.
    ///   - compatibleAppCounts: The number of library applications each
    ///     linked profile can sign, by profile identifier.
    ///   - referenceDate: The instant the checks are judged at.
    func assessCertificate(
        _ certificate: IdentityCertificateFacts,
        linkedProfiles: [IdentityProfileFacts],
        compatibleAppCounts: [ProvisioningProfileIdentifier: Int],
        referenceDate: Date
    ) -> IdentityHealthReport {
        var checks: [IdentityHealthCheck] = []

        // Certificate valid: inside the declared validity window.
        let validityOutcome: IdentityHealthCheckOutcome
        let validityDetail: String
        switch certificate.expiration.status {
        case .healthy, .expiringSoon:
            validityOutcome = .pass
            validityDetail = "Inside its validity period."
        case .expired:
            validityOutcome = .blocked
            validityDetail = "The certificate's validity period has ended."
        case .notYetValid:
            validityOutcome = .blocked
            validityDetail = "The certificate's validity period has not started."
        }
        checks.append(IdentityHealthCheck(kind: .certificateValid, detail: validityDetail, outcome: validityOutcome))

        // Key available: the last observation of the private key.
        let keyOutcome: IdentityHealthCheckOutcome
        let keyDetail: String
        switch certificate.keyAvailability {
        case .available:
            keyOutcome = .pass
            keyDetail = "The private key was available at the last observation."
        case .unavailable:
            keyOutcome = .blocked
            keyDetail = "The private key is not available. The certificate cannot sign without it."
        case .unknown:
            keyOutcome = .warning
            keyDetail = "The private key's availability could not be determined."
        }
        checks.append(IdentityHealthCheck(kind: .keyAvailable, detail: keyDetail, outcome: keyOutcome))

        // Expiration: remaining validity against the warning threshold.
        let expirationOutcome: IdentityHealthCheckOutcome
        let expirationDetail: String
        if let days = certificate.expiration.remainingDays {
            if days < 0 {
                expirationOutcome = .blocked
                expirationDetail = "Expired \(abs(days)) day\(abs(days) == 1 ? "" : "s") ago."
            } else if certificate.expiration.status == .expiringSoon {
                expirationOutcome = .warning
                expirationDetail = days == 0 ? "Expires today." : "\(days) day\(days == 1 ? "" : "s") of validity remain."
            } else {
                expirationOutcome = .pass
                expirationDetail = "More than \(certificate.expiration.warningThresholdDays) days of validity remain."
            }
        } else {
            expirationOutcome = .blocked
            expirationDetail = "The validity period has not started, so no expiration can be counted."
        }
        checks.append(IdentityHealthCheck(kind: .expiration, detail: expirationDetail, outcome: expirationOutcome))

        // Team match: the certificate's team against the teams its
        // profiles declare.
        let declaredProfileTeams = linkedProfiles.compactMap(\.teamID)
        if let certificateTeam = certificate.teamID, !declaredProfileTeams.isEmpty {
            let agreements = declaredProfileTeams.filter {
                $0.caseInsensitiveCompare(certificateTeam) == .orderedSame
            }
            if agreements.isEmpty {
                checks.append(IdentityHealthCheck(
                    kind: .teamMatch,
                    detail: "None of the \(declaredProfileTeams.count) linked profile\(declaredProfileTeams.count == 1 ? "" : "s") declares this certificate's team.",
                    outcome: .blocked
                ))
            } else if agreements.count < declaredProfileTeams.count {
                checks.append(IdentityHealthCheck(
                    kind: .teamMatch,
                    detail: "\(declaredProfileTeams.count - agreements.count) linked profile\(declaredProfileTeams.count - agreements.count == 1 ? "" : "s") declare a different team.",
                    outcome: .warning
                ))
            } else {
                checks.append(IdentityHealthCheck(
                    kind: .teamMatch,
                    detail: "Every linked profile declares the same team.",
                    outcome: .pass
                ))
            }
        } else {
            checks.append(IdentityHealthCheck(
                kind: .teamMatch,
                detail: "No team to compare: the certificate or its profiles declare no Team ID.",
                outcome: .notApplicable
            ))
        }

        // Profile valid: at least one usable linked profile, none expired.
        if linkedProfiles.isEmpty {
            checks.append(IdentityHealthCheck(
                kind: .profileValid,
                detail: "No provisioning profile is linked to this certificate.",
                outcome: .warning
            ))
        } else {
            let expired = linkedProfiles.filter { $0.isExpired(referenceDate: referenceDate) }
            if expired.count == linkedProfiles.count {
                checks.append(IdentityHealthCheck(
                    kind: .profileValid,
                    detail: "Every linked profile has expired.",
                    outcome: .blocked
                ))
            } else if !expired.isEmpty {
                checks.append(IdentityHealthCheck(
                    kind: .profileValid,
                    detail: "\(expired.count) linked profile\(expired.count == 1 ? "" : "s") \(expired.count == 1 ? "has" : "have") expired.",
                    outcome: .warning
                ))
            } else {
                checks.append(IdentityHealthCheck(
                    kind: .profileValid,
                    detail: "A linked profile is valid.",
                    outcome: .pass
                ))
            }
        }

        // Bundle compatible: the linked profiles cover at least one
        // application in the library.
        let counts = linkedProfiles.compactMap { compatibleAppCounts[$0.id] }
        if counts.isEmpty {
            checks.append(IdentityHealthCheck(
                kind: .bundleCompatible,
                detail: "No compatible application count is known for this certificate's profiles.",
                outcome: .notApplicable
            ))
        } else if counts.allSatisfy({ $0 == 0 }) {
            checks.append(IdentityHealthCheck(
                kind: .bundleCompatible,
                detail: "No application in the library matches this certificate's profiles.",
                outcome: .warning
            ))
        } else {
            let total = counts.reduce(0, +)
            checks.append(IdentityHealthCheck(
                kind: .bundleCompatible,
                detail: "\(total) application\(total == 1 ? "" : "s") in the library match.",
                outcome: .pass
            ))
        }

        return IdentityHealthReport(
            subject: .certificate(fingerprintHex: certificate.fingerprintHex),
            subjectName: certificate.displayName,
            checks: checks,
            evaluatedAt: referenceDate
        )
    }

    /// Computes the health of one provisioning profile.
    ///
    /// - Parameters:
    ///   - profile: The profile's facts.
    ///   - certificates: Every local certificate's facts, so the engine
    ///     can resolve the profile's embedded fingerprints itself.
    ///   - compatibleAppCount: How many library applications the profile
    ///     can sign. `nil` when the library was not composed, in which
    ///     case the bundle check reports not-applicable.
    ///   - referenceDate: The instant the checks are judged at.
    func assessProfile(
        _ profile: IdentityProfileFacts,
        certificates: [IdentityCertificateFacts],
        compatibleAppCount: Int?,
        referenceDate: Date
    ) -> IdentityHealthReport {
        var checks: [IdentityHealthCheck] = []

        // Profile valid: unexpired and carrying declarations.
        if profile.isExpired(referenceDate: referenceDate) {
            checks.append(IdentityHealthCheck(
                kind: .profileValid,
                detail: "The profile's validity period has ended.",
                outcome: .blocked
            ))
        } else {
            checks.append(IdentityHealthCheck(
                kind: .profileValid,
                detail: "The profile is within its validity period.",
                outcome: .pass
            ))
        }

        // Expiration: remaining validity against the 30-day threshold.
        let days = profile.daysUntilExpiration(referenceDate: referenceDate)
        let expirationOutcome: IdentityHealthCheckOutcome
        let expirationDetail: String
        if days < 0 {
            expirationOutcome = .blocked
            expirationDetail = "Expired \(abs(days)) day\(abs(days) == 1 ? "" : "s") ago."
        } else if days <= ProfileExpirationAssessment.expiringSoonThreshold {
            expirationOutcome = .warning
            expirationDetail = days == 0 ? "Expires today." : "\(days) day\(days == 1 ? "" : "s") of validity remain."
        } else {
            expirationOutcome = .pass
            expirationDetail = "More than \(ProfileExpirationAssessment.expiringSoonThreshold) days of validity remain."
        }
        checks.append(IdentityHealthCheck(kind: .expiration, detail: expirationDetail, outcome: expirationOutcome))

        // Team match: the profile's team against the local certificates.
        if let profileTeam = profile.teamID {
            let local = certificates.filter { certificate in
                guard let certificateTeam = certificate.teamID else { return false }
                return certificateTeam.caseInsensitiveCompare(profileTeam) == .orderedSame
            }
            if local.isEmpty {
                checks.append(IdentityHealthCheck(
                    kind: .teamMatch,
                    detail: "No local certificate declares the profile's team.",
                    outcome: .warning
                ))
            } else if local.contains(where: \.isUsableForSigning) {
                checks.append(IdentityHealthCheck(
                    kind: .teamMatch,
                    detail: "A local certificate of the same team is usable.",
                    outcome: .pass
                ))
            } else {
                checks.append(IdentityHealthCheck(
                    kind: .teamMatch,
                    detail: "Local certificates declare the team, but none is usable.",
                    outcome: .warning
                ))
            }
        } else {
            checks.append(IdentityHealthCheck(
                kind: .teamMatch,
                detail: "The profile declares no Team ID to compare.",
                outcome: .notApplicable
            ))
        }

        // Certificate validity: the profile's embedded certificates.
        if profile.certificateFingerprints.isEmpty {
            checks.append(IdentityHealthCheck(
                kind: .certificateValid,
                detail: "The profile's embedded certificates were not recorded.",
                outcome: .notApplicable
            ))
        } else {
            let known = profile.certificateFingerprints.filter { fingerprint in
                certificates.contains { $0.fingerprintHex == fingerprint }
            }
            if known.isEmpty {
                checks.append(IdentityHealthCheck(
                    kind: .certificateValid,
                    detail: "None of the embedded certificates is on this device.",
                    outcome: .blocked
                ))
            } else if known.count < profile.certificateFingerprints.count {
                checks.append(IdentityHealthCheck(
                    kind: .certificateValid,
                    detail: "\(profile.certificateFingerprints.count - known.count) of the embedded certificates are missing locally.",
                    outcome: .warning
                ))
            } else {
                checks.append(IdentityHealthCheck(
                    kind: .certificateValid,
                    detail: "The embedded certificates are on this device.",
                    outcome: .pass
                ))
            }
        }

        // Bundle compatible: applications the profile can sign.
        if let compatibleAppCount {
            if compatibleAppCount == 0 {
                checks.append(IdentityHealthCheck(
                    kind: .bundleCompatible,
                    detail: "No application in the library matches this profile.",
                    outcome: .warning
                ))
            } else {
                checks.append(IdentityHealthCheck(
                    kind: .bundleCompatible,
                    detail: "\(compatibleAppCount) application\(compatibleAppCount == 1 ? "" : "s") in the library match.",
                    outcome: .pass
                ))
            }
        } else {
            checks.append(IdentityHealthCheck(
                kind: .bundleCompatible,
                detail: "No application library is composed, so no count is known.",
                outcome: .notApplicable
            ))
        }

        return IdentityHealthReport(
            subject: .profile(profile.id),
            subjectName: profile.name,
            checks: checks,
            evaluatedAt: referenceDate
        )
    }
}
