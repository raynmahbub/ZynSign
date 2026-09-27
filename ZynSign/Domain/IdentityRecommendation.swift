import Foundation

/// Why the recommendation engine proposed an identity.
enum IdentityRecommendationReasonKind: String, CaseIterable, Equatable, Hashable, Sendable {

    /// The journal shows a successful signing of this very application
    /// with this very certificate.
    case previousSuccess

    /// The user marked this identity as the default.
    case defaultIdentity

    /// The certificate's team and the profile's team agree.
    case teamMatch

    /// The profile covers the application's bundle identifier.
    case profileCompatible

    /// The certificate has an available key, a matched association, and a
    /// ready capability.
    case usableKey

    /// The only certificate available, or the only one that can sign.
    case onlyOption

    /// Something about the recommendation wants attention: an expiration
    /// inside the warning window, an unusable key.
    case caution

    /// The sentence the recommendation card shows.
    func text(certificateName: String, profileName: String?) -> String {
        switch self {
        case .previousSuccess:
            return "This certificate signed this app successfully before."
        case .defaultIdentity:
            return "You set this certificate as your default identity."
        case .teamMatch:
            return "The certificate and profile belong to the same team."
        case .profileCompatible:
            if let profileName {
                return "The profile “\(profileName)” covers this app's bundle identifier."
            }
            return "The profile covers this app's bundle identifier."
        case .usableKey:
            return "The private key is available and ready to sign."
        case .onlyOption:
            return "This is the only certificate that can sign right now."
        case .caution:
            return "Check the cautions before signing."
        }
    }
}

/// One reason behind a recommendation.
struct IdentityRecommendationReason: Equatable, Hashable, Sendable {

    /// Which observation the reason records.
    let kind: IdentityRecommendationReasonKind

    /// Creates a reason.
    init(kind: IdentityRecommendationReasonKind) {
        self.kind = kind
    }

    /// The sentence the recommendation card shows, composed with the
    /// subject names.
    func text(certificateName: String, profileName: String?) -> String {
        kind.text(certificateName: certificateName, profileName: profileName)
    }
}

/// The signing identity the engine recommends for one application, with
/// the reasons it earned the recommendation.
///
/// A recommendation is a proposal — nothing more. It never signs, never
/// enqueues, and never changes a store. The signing screen shows it above
/// the pickers; applying it sets the pickers, and the user's own final
/// confirmation is always the Sign button.
struct SigningIdentityRecommendation: Equatable, Hashable, Sendable {

    /// The recommended identity's identifier.
    let identityID: SigningIdentityIdentifier

    /// The recommended identity's certificate fingerprint, lowercase hex.
    let certificateFingerprintHex: String

    /// The recommended profile, when one can sign the application.
    let profileID: ProvisioningProfileIdentifier?

    /// The recommended profile's name, when one is recommended.
    let profileName: String?

    /// The recommendation's score, comparable only within one ranking.
    let score: Int

    /// The reasons, strongest first.
    let reasons: [IdentityRecommendationReasonKind]

    /// The recommendation's display name: the certificate's.
    let certificateName: String

    /// The one-line summary the card shows.
    var summary: String {
        if let profileName {
            return "\(certificateName) with “\(profileName)”"
        }
        return certificateName
    }
}

/// The identity recommendation engine.
///
/// The engine is pure. Given one application's bundle identifier, the
/// local certificates, the stored profiles, the signing journal reduced to
/// facts, and the user's default mark, it scores every certificate–profile
/// pairing that could sign the application and proposes the best. Its
/// weights reward what history and compatibility established, never what
/// looks plausible:
///
/// | Observation | Score |
/// |---|---|
/// | Previous successful signing of this app with this certificate | +45 |
/// | Default identity | +10 |
/// | Usable key (available, matched, ready) | +40 |
/// | Team match between certificate and profile | +20 |
/// | Profile covers the app's bundle identifier | +25 |
/// | Profile is the only eligible one | +5 |
/// | Certificate inside its expiration warning window | −5 |
/// | Certificate that cannot sign | excluded |
/// | Profile that cannot cover the app, or has expired | excluded |
///
/// When no pairing qualifies the recommendation is `nil` and the signing
/// screen shows its ordinary pickers — the engine never proposes an
/// identity that cannot sign the application in front of the user.
struct IdentityRecommender: Sendable {

    /// Creates the engine.
    init() {}

    /// Recommends an identity–profile pairing for `bundleIdentifier`.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: The application to sign, or `nil` when no
    ///     application is in context. Without an application the engine
    ///     recommends only on identity quality and history.
    ///   - certificates: Every local certificate's facts.
    ///   - profiles: Every stored profile's facts.
    ///   - history: The signing journal reduced to facts.
    ///   - defaultFingerprintHex: The fingerprint the user marked default,
    ///     or `nil`.
    ///   - referenceDate: The instant expiration is judged at.
    /// - Returns: The best pairing, or `nil` when none qualifies.
    func recommend(
        bundleIdentifier: String?,
        certificates: [IdentityCertificateFacts],
        profiles: [IdentityProfileFacts],
        history: [IdentityHistoryFact],
        defaultFingerprintHex: String?,
        referenceDate: Date
    ) -> SigningIdentityRecommendation? {
        var best: (candidate: SigningIdentityRecommendation, score: Int)?

        for certificate in certificates {
            guard certificate.canSignAtEvaluationDate else { continue }
            let eligibleProfiles = eligibleProfiles(
                for: bundleIdentifier,
                certificate: certificate,
                profiles: profiles,
                referenceDate: referenceDate
            )

            if let profile = bestProfile(
                for: certificate,
                among: eligibleProfiles,
                bundleIdentifier: bundleIdentifier
            ) {
                let scoring = score(
                    certificate: certificate,
                    profile: profile,
                    bundleIdentifier: bundleIdentifier,
                    history: history,
                    defaultFingerprintHex: defaultFingerprintHex,
                    eligibleProfileCount: eligibleProfiles.count,
                    certificateCount: certificates.count,
                    referenceDate: referenceDate
                )
                if best == nil || scoring.score > best!.score {
                    best = (scoring.candidate, scoring.score)
                }
            } else if eligibleProfiles.isEmpty && bundleIdentifier == nil {
                // No application in context: an identity-only
                // recommendation is still meaningful when there is nothing
                // to match a profile against.
                let scoring = score(
                    certificate: certificate,
                    profile: nil,
                    bundleIdentifier: nil,
                    history: history,
                    defaultFingerprintHex: defaultFingerprintHex,
                    eligibleProfileCount: 0,
                    certificateCount: certificates.count,
                    referenceDate: referenceDate
                )
                if best == nil || scoring.score > best!.score {
                    best = (scoring.candidate, scoring.score)
                }
            }
        }

        return best?.candidate
    }

    // MARK: - Scoring

    /// Scores one pairing and composes its recommendation.
    private func score(
        certificate: IdentityCertificateFacts,
        profile: IdentityProfileFacts?,
        bundleIdentifier: String?,
        history: [IdentityHistoryFact],
        defaultFingerprintHex: String?,
        eligibleProfileCount: Int,
        certificateCount: Int,
        referenceDate: Date
    ) -> (candidate: SigningIdentityRecommendation, score: Int) {
        var score = 0
        var reasons: [IdentityRecommendationReasonKind] = []

        let signedBefore = history.contains { record in
            guard record.succeeded,
                  let fingerprint = record.certificateFingerprintHex else { return false }
            guard fingerprint == certificate.fingerprintHex else { return false }
            if let bundleIdentifier, let signedBundle = record.bundleIdentifier {
                return signedBundle == bundleIdentifier
            }
            return bundleIdentifier == nil
        }
        if signedBefore {
            score += 45
            reasons.append(.previousSuccess)
        }

        if certificate.isDefault || certificate.fingerprintHex == defaultFingerprintHex {
            score += 10
            reasons.append(.defaultIdentity)
        }

        if certificate.isUsableForSigning {
            score += 40
            reasons.append(.usableKey)
        }

        if let profile {
            if let certificateTeam = certificate.teamID,
               let profileTeam = profile.teamID,
               certificateTeam.caseInsensitiveCompare(profileTeam) == .orderedSame {
                score += 20
                reasons.append(.teamMatch)
            }
            if let bundleIdentifier, profile.covers(bundleIdentifier: bundleIdentifier) {
                score += 25
                reasons.append(.profileCompatible)
            }
            if eligibleProfileCount == 1 {
                score += 5
            }

            let profileDays = profile.daysUntilExpiration(referenceDate: referenceDate)
            if profileDays >= 0, profileDays <= ProfileExpirationAssessment.expiringSoonThreshold {
                score -= 5
                reasons.append(.caution)
            }
        }

        if certificate.expiration.status == .expiringSoon {
            score -= 5
            reasons.append(.caution)
        }

        if !reasons.contains(.previousSuccess), !reasons.contains(.defaultIdentity),
           certificateCount == 1 {
            score += 5
            reasons.append(.onlyOption)
        }

        let orderedReasons = ordered(reasons)
        let candidate = SigningIdentityRecommendation(
            identityID: certificate.identityID,
            certificateFingerprintHex: certificate.fingerprintHex,
            profileID: profile?.id,
            profileName: profile?.name,
            score: score,
            reasons: orderedReasons,
            certificateName: certificate.displayName
        )
        return (candidate, score)
    }

    /// Deduplicates reasons, ordering them by weight: the strongest
    /// signals first.
    private func ordered(
        _ reasons: [IdentityRecommendationReasonKind]
    ) -> [IdentityRecommendationReasonKind] {
        var seen: Set<IdentityRecommendationReasonKind> = []
        var unique: [IdentityRecommendationReasonKind] = []
        for kind in reasons where !seen.contains(kind) {
            seen.insert(kind)
            unique.append(kind)
        }
        return unique.sorted { weight($0) > weight($1) }
    }

    /// The ranking weight of a reason kind.
    private func weight(_ kind: IdentityRecommendationReasonKind) -> Int {
        switch kind {
        case .previousSuccess: return 6
        case .usableKey: return 5
        case .profileCompatible: return 4
        case .teamMatch: return 3
        case .defaultIdentity: return 2
        case .onlyOption: return 1
        case .caution: return 0
        }
    }

    // MARK: - Eligibility

    /// The profiles that could sign `bundleIdentifier` with `certificate`.
    ///
    /// A profile is eligible when it has not expired and — when an
    /// application is in context — its declared patterns cover the
    /// application's bundle identifier. App Store profiles are excluded:
    /// they cannot re-sign an application on this device.
    private func eligibleProfiles(
        for bundleIdentifier: String?,
        certificate: IdentityCertificateFacts,
        profiles: [IdentityProfileFacts],
        referenceDate: Date
    ) -> [IdentityProfileFacts] {
        profiles.filter { profile in
            guard !profile.isExpired(referenceDate: referenceDate) else { return false }
            guard profile.profileType != .appStore else { return false }
            if let bundleIdentifier {
                return profile.covers(bundleIdentifier: bundleIdentifier)
            }
            return true
        }
    }

    /// The best eligible profile for one certificate: team match first,
    /// then exact bundle match, then the longest remaining validity.
    private func bestProfile(
        for certificate: IdentityCertificateFacts,
        among profiles: [IdentityProfileFacts],
        bundleIdentifier: String?
    ) -> IdentityProfileFacts? {
        guard !profiles.isEmpty else { return nil }
        return profiles.max { lhs, rhs in
            let lhsScore = profileScore(lhs, certificate: certificate, bundleIdentifier: bundleIdentifier)
            let rhsScore = profileScore(rhs, certificate: certificate, bundleIdentifier: bundleIdentifier)
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            if lhs.expirationDate != rhs.expirationDate { return lhs.expirationDate < rhs.expirationDate }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// The preference score of one profile for one certificate.
    private func profileScore(
        _ profile: IdentityProfileFacts,
        certificate: IdentityCertificateFacts,
        bundleIdentifier: String?
    ) -> Int {
        var score = 0
        if let certificateTeam = certificate.teamID,
           let profileTeam = profile.teamID,
           certificateTeam.caseInsensitiveCompare(profileTeam) == .orderedSame {
            score += 3
        }
        if let bundleIdentifier, profile.bundleIdentifier == bundleIdentifier {
            score += 2
        } else if let bundleIdentifier, profile.covers(bundleIdentifier: bundleIdentifier) {
            score += 1
        }
        return score
    }
}
