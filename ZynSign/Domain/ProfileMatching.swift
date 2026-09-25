import Foundation

/// One profile's ranking for a specific app: the profile itself, its full
/// compatibility report, a ranking score, and the human-readable reasons it
/// earned that score.
struct ProfileMatch: Equatable, Sendable {

    /// The ranked profile.
    let profile: ProvisioningProfileSummary

    /// The profile's full compatibility report in the ranking context.
    let report: ProfileCompatibilityReport

    /// Higher ranks first. Scores are comparable only within one ranking.
    let score: Int

    /// Short reasons shown next to a suggestion, e.g. "Exact bundle match".
    let reasons: [String]
}

/// The Profile Matching engine: ranks a user's profiles for one app so the
/// best candidate can be suggested automatically when the app is opened.
///
/// Ranking is pure domain logic. Eligibility first — a profile must cover
/// the app's bundle identifier, not be expired, and not be an App Store
/// profile — then score: exact bundle match beats wildcard, a certificate
/// on this device beats none, a matching team beats a mismatch, and a
/// supported distribution type beats an unknown one. Ties break toward the
/// longer validity, then the alphabetically smaller name, so the order is
/// deterministic.
///
/// When no profile is eligible the ranking is empty and the caller shows
/// "Profile not suitable for this app" — the matcher never suggests a
/// profile that could not sensibly sign the app.
struct ProfileMatcher {

    init() {}

    /// All eligible profiles ranked best-first for `context`'s target app.
    /// Returns an empty ranking when the context names no app.
    func rank(
        profiles: [ProvisioningProfileSummary],
        context: ProfileCompatibilityContext
    ) -> [ProfileMatch] {
        guard context.targetBundleIdentifier != nil else { return [] }
        let engine = ProfileCompatibilityEngine()
        var matches: [ProfileMatch] = []
        for profile in profiles where isEligible(profile, context: context) {
            let report = engine.evaluate(profile: profile, context: context)
            let (score, reasons) = scoring(for: profile, report: report)
            matches.append(
                ProfileMatch(profile: profile, report: report, score: score, reasons: reasons)
            )
        }
        return matches.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.profile.expirationDate != rhs.profile.expirationDate {
                return lhs.profile.expirationDate > rhs.profile.expirationDate
            }
            return lhs.profile.name.localizedCaseInsensitiveCompare(rhs.profile.name) == .orderedAscending
        }
    }

    /// The single best profile for the context's target app, if any.
    func bestMatch(
        profiles: [ProvisioningProfileSummary],
        context: ProfileCompatibilityContext
    ) -> ProfileMatch? {
        rank(profiles: profiles, context: context).first
    }

    /// Whether `profile` may be suggested at all: it must cover the app,
    /// be unexpired, and not be an App Store profile.
    func isEligible(
        _ profile: ProvisioningProfileSummary,
        context: ProfileCompatibilityContext
    ) -> Bool {
        guard let target = context.targetBundleIdentifier else { return false }
        guard profile.covers(bundleIdentifier: target) else { return false }
        guard !profile.isExpired(referenceDate: context.referenceDate) else { return false }
        return profile.resolvedProfileType != .appStore
    }

    // MARK: - Scoring

    private func scoring(
        for profile: ProvisioningProfileSummary,
        report: ProfileCompatibilityReport
    ) -> (score: Int, reasons: [String]) {
        var score = 0
        var reasons: [String] = []

        // Bundle fit: an exact App ID is a much stronger signal than a
        // wildcard that merely covers the app.
        if profile.bundleIdentifier == report.targetBundleIdentifier {
            score += 1000
            reasons.append("Exact bundle match")
        } else {
            score += 700
            reasons.append("Wildcard covers the app")
        }

        // A certificate on this device that the profile names.
        switch report.result(for: .certificateAvailable)?.status {
        case .some(.pass):
            score += 300
            reasons.append("Your certificate is included")
        case .some(.warning):
            score += 100
        default:
            break
        }

        // A team the local certificates agree with.
        if case .some(.pass) = report.result(for: .teamIdentifier)?.status {
            score += 150
            reasons.append("Team matches your certificates")
        }

        // Distribution type: a known signing type is preferred; a type
        // ZynSign could not determine costs nothing but earns nothing.
        switch profile.resolvedProfileType {
        case .development, .adHoc, .enterprise:
            score += 100
        case .appStore:
            score -= 400 // excluded by eligibility; kept for completeness
        case .unknown:
            break
        }

        // Prefer more remaining validity when everything else ties less
        // decisively; the tie-break below still applies first at equal
        // scores, so this only nudges within the same class.
        let assessment = profile.expirationAssessment(referenceDate: report.checkedAt)
        if assessment.state == .expiringSoon {
            score -= 50
            reasons.append("Expiring soon")
        }

        return (score, reasons)
    }
}
