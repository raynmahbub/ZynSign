import Foundation

/// A pre-sign compatibility assessment.
///
/// `SigningHealthScore` is the v1.0.0 distinguishing feature: instead of
/// showing users a button that may or may not work, ZynSign runs a static
/// read-only check before signing and tells them — in plain terms —
/// whether the combination of (identity, provisioning profile, bundle)
/// will likely succeed and why. It does not run the signing pipeline; it
/// reads the same inputs the pipeline would read and reasons about them.
///
/// The score is purely informational. It is never a hard precondition: a
/// user can still choose to sign with a low score, because we do not block
/// legitimate workflows. The score tells them what the pipeline will say
/// later.
///
/// Scores live in the Domain layer because they are pure values computed
/// from other domain values. No presentation, no platform, no signing.
struct SigningHealthScore: Equatable, Hashable, Sendable {

    /// One band on the 0–100 scale.
    enum Band: String, Equatable, Hashable, CaseIterable, Sendable {
        case excellent  // 90…100
        case good       // 70…89
        case fair       // 50…69
        case poor       // 25…49
        case risky      // 0…24

        /// User-readable label.
        var displayName: String {
            switch self {
            case .excellent: return "Excellent"
            case .good:      return "Good"
            case .fair:      return "Fair"
            case .poor:      return "Poor"
            case .risky:     return "Risky"
            }
        }

        /// Short sentence used on cards and badges.
        var headline: String {
            switch self {
            case .excellent: return "Ready to sign"
            case .good:      return "Likely ready"
            case .fair:      return "May need attention"
            case .poor:      return "Likely to fail"
            case .risky:     return "Will probably fail"
            }
        }

        /// Maps a numeric score to its band.
        static func band(for score: Int) -> Band {
            switch score {
            case 90...100: return .excellent
            case 70..<90:  return .good
            case 50..<70:  return .fair
            case 25..<50:  return .poor
            default:       return .risky
            }
        }
    }

    /// One explanation behind the score. A score is the sum of its findings:
    /// each finding either adds points (good signal) or subtracts points
    /// (a risk). Findings are ordered by impact, descending.
    struct Finding: Equatable, Hashable, Sendable, Identifiable {
        let id: String
        let title: String
        let detail: String
        let weight: Int   // negative for risks, positive for strengths

        var isRisk: Bool { weight < 0 }
    }

    /// 0…100. The arithmetic sum of finding weights, clamped.
    let score: Int

    /// The band the score falls into.
    var band: Band { Band.band(for: score) }

    /// The findings behind the score, most-impactful first.
    let findings: [Finding]

    /// The latest certificate expiry date considered, when relevant.
    let certificateExpiry: Date?

    /// The latest provisioning profile expiry date considered, when relevant.
    let profileExpiry: Date?

    /// Records an assessment.
    init(
        score: Int,
        findings: [Finding],
        certificateExpiry: Date? = nil,
        profileExpiry: Date? = nil
    ) {
        let clamped = max(0, min(100, score))
        self.score = clamped
        // Order by absolute weight so the most impactful findings surface first.
        self.findings = findings.sorted { abs($0.weight) > abs($1.weight) }
        self.certificateExpiry = certificateExpiry
        self.profileExpiry = profileExpiry
    }

    /// An empty assessment, used when inputs are missing.
    static let empty = SigningHealthScore(
        score: 0,
        findings: [Finding(
            id: "missing.inputs",
            title: "Not enough information",
            detail: "ZynSign needs a certificate and a provisioning profile to assess signing readiness.",
            weight: 0
        )],
        certificateExpiry: nil,
        profileExpiry: nil
    )

    /// The total absolute weight of all risks; useful for "top risk" UI.
    var totalRiskWeight: Int {
        findings.filter { $0.isRisk }.reduce(0) { $0 + abs($1.weight) }
    }

    /// The total positive weight across all strengths.
    var totalStrengthWeight: Int {
        findings.filter { !$0.isRisk }.reduce(0) { $0 + $1.weight }
    }
}
