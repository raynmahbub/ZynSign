import Foundation

/// The certificates and profiles a preset can be checked against.
///
/// Snapshots are pure values assembled by the workflow from the identity
/// store and the profile library. Matching never reads the Keychain or a
/// file itself, and the snapshot carries display references only — no key
/// bytes and no profile bytes.
struct PresetInventory: Equatable, Sendable {
    struct Certificate: Equatable, Sendable, Identifiable {
        var id: String { fingerprint.hexDigest }
        var fingerprint: CertificateFingerprint
        var displayName: String
        /// Team identifier when the certificate's organizational unit is a
        /// ten-character team reference. Not proof of team membership.
        var teamIdentifier: String?
        var isUsable: Bool
        var notValidBefore: Date
        var notValidAfter: Date
    }

    struct Profile: Equatable, Sendable, Identifiable {
        var id: ProvisioningProfileIdentifier
        var name: String
        var teamIdentifier: String?
        var bundleIdentifierPatterns: [String]
        var expirationDate: Date
        var sourceFileName: String
        /// Whether the referenced file is present in profile storage.
        /// Metadata-only checks may leave this true; the workflow sets it
        /// from the file system before live compatibility is shown.
        var fileIsPresent: Bool

        func isExpired(at date: Date) -> Bool { date >= expirationDate }

        func daysUntilExpiration(at date: Date) -> Int {
            Int((expirationDate.timeIntervalSince(date) / 86400).rounded(.toNearestOrEven))
        }

        func covers(bundleIdentifier: String) -> Bool {
            bundleIdentifierPatterns.contains { pattern in
                ProvisioningProfileSummary.pattern(pattern, covers: bundleIdentifier)
            }
        }
    }

    var certificates: [Certificate]
    var profiles: [Profile]
    var now: Date

    func certificate(matching fingerprint: CertificateFingerprint) -> Certificate? {
        certificates.first { $0.fingerprint == fingerprint }
    }

    func profile(matching preset: SigningPreset) -> Profile? {
        if let id = preset.provisioningProfileID, let match = profiles.first(where: { $0.id == id }) {
            return match
        }
        guard let name = preset.provisioningProfileName else { return nil }
        return profiles.first { $0.name == name }
    }
}

/// One row of the live compatibility table.
struct PresetCompatibilityCheck: Equatable, Sendable, Identifiable {
    enum Status: Equatable, Sendable {
        case passing
        case warning
        case failing
        case unknown

        var displayName: String {
            switch self {
            case .passing: return "Passing"
            case .warning: return "Warning"
            case .failing: return "Failing"
            case .unknown: return "Unknown"
            }
        }

        var symbolName: String {
            switch self {
            case .passing: return "checkmark"
            case .warning: return "exclamationmark.triangle"
            case .failing: return "xmark"
            case .unknown: return "questionmark"
            }
        }
    }

    let id: String
    let title: String
    let status: Status
    let detail: String

    /// A sentence VoiceOver can read. No symbols.
    var spoken: String { "\(title), \(status.displayName). \(detail)" }
}

/// The current health of one preset, optionally against one app.
struct PresetCompatibilityReport: Equatable, Sendable {
    enum Overall: Equatable, Sendable {
        case ready
        case attention
        case blocked
        case incomplete

        var displayName: String {
            switch self {
            case .ready: return "Ready"
            case .attention: return "Needs attention"
            case .blocked: return "Not usable"
            case .incomplete: return "Incomplete"
            }
        }
    }

    let certificate: PresetCompatibilityCheck
    let profile: PresetCompatibilityCheck
    let expiration: PresetCompatibilityCheck
    let team: PresetCompatibilityCheck
    /// Present only when an app was part of the assessment.
    let bundle: PresetCompatibilityCheck?
    let overall: Overall
    /// Usable as a saved workflow, ignoring a specific bundle identifier.
    let isUsable: Bool
    /// Usable for the assessed app. False when no app was assessed, and
    /// false when the profile does not cover that app.
    let passesPreflight: Bool
    let spokenSummary: String

    var checks: [PresetCompatibilityCheck] {
        var rows = [certificate, profile, expiration, team]
        if let bundle { rows.append(bundle) }
        return rows
    }
}

/// One app a preset can be matched or queued against.
struct PresetAppContext: Equatable, Sendable {
    var bundleIdentifier: String
    var displayName: String?
}

/// An application offered to the bulk planner. The identifier is the
/// library record's raw identifier so the queue can pair results without
/// holding the record.
struct PresetBulkSubject: Equatable, Sendable, Identifiable {
    var id: String
    var bundleIdentifier: String
    var displayName: String
    var artifactAvailable: Bool

    var app: PresetAppContext {
        PresetAppContext(bundleIdentifier: bundleIdentifier, displayName: displayName)
    }
}

/// A ranked preset. Ranking does not sign and does not select a preset
/// for execution. `isRecommended` is true only when this match is the
/// highest-scoring preset that passes preflight.
struct PresetMatch: Equatable, Sendable, Identifiable {
    var id: PresetIdentifier { preset.id }
    let preset: SigningPreset
    let report: PresetCompatibilityReport
    let score: Int
    let reasons: [String]
    let isRecommended: Bool
}

/// The full ranking for one app, or for the library when no app is given.
struct PresetRanking: Equatable, Sendable {
    let matches: [PresetMatch]

    /// The preset to offer. Nil when nothing passes preflight — a closer
    /// but incompatible preset is not recommended and is not executed.
    var recommendation: PresetMatch? { matches.first { $0.isRecommended } }
}

/// A factual notice. Each case is emitted only when the underlying check
/// is true; none of them guess.
struct PresetSuggestion: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case expiresSoon(days: Int)
        case newerCompatibleProfile(name: String)
        case betterMatch(presetName: String, reason: String)
        case verificationRecommended
    }

    let kind: Kind

    var id: String { message }

    var message: String {
        switch kind {
        case .expiresSoon(let days):
            if days <= 0 {
                return "This preset expires soon. The provisioning profile expires today."
            }
            return "This preset expires soon. The provisioning profile expires in \(days) day\(days == 1 ? "" : "s")."
        case .newerCompatibleProfile(let name):
            return "A newer compatible profile is available. \(name) expires later and covers the same team."
        case .betterMatch(let presetName, let reason):
            return "Another preset better matches this app. \(presetName): \(reason)"
        case .verificationRecommended:
            return "Verification is recommended. This preset does not lead with the verification summary. The pipeline still verifies every run."
        }
    }
}

struct PresetBulkItem: Equatable, Sendable, Identifiable {
    let id: String
    let displayName: String
    let bundleIdentifier: String
    let reasons: [String]
}

/// The split a bulk workflow shows before anything is queued.
///
/// `compatible` and `needsAttention` are disjoint. Incompatible apps are
/// listed so the user can see them; they are not members of `compatible`.
struct PresetBulkPlan: Equatable, Sendable {
    let presetID: PresetIdentifier
    let presetName: String
    let compatible: [PresetBulkItem]
    let needsAttention: [PresetBulkItem]

    var queuesIncompatibleApps: Bool {
        !Set(compatible.map(\.id)).isDisjoint(with: needsAttention.map(\.id))
    }
}

/// What the import area may offer after a package is accepted.
struct ImportSigningReadiness: Equatable, Sendable {
    let bundleIdentifier: String
    let displayName: String?
    let recommendation: PresetMatch?

    /// Offered only when a preset passes preflight. A partial match is not
    /// described as ready.
    var isReadyToSign: Bool { recommendation?.report.passesPreflight == true }

    var title: String { "Ready to Sign" }

    var detail: String {
        guard let recommendation else { return "" }
        return "\(recommendation.preset.name) matches this app. Signing still needs confirmation."
    }
}

/// Weights used by `SigningPresetMatcher`. Tests and the architecture note
/// cite these numbers; changing one without the other would make a
/// recommendation unexplained.
enum PresetRankingWeights {
    static let certificateUsable = 25
    static let certificatePresentButUnusable = -15
    static let certificateMissing = -20
    static let profilePresent = 15
    static let profileMissing = -20
    static let bundleCovered = 30
    static let bundleNotCovered = -40
    static let teamAligned = 15
    static let teamContradicts = -30
    static let expirationHealthy = 10
    static let expirationExpired = -50
    static let previousSuccessOnBundle = 20
    static let successCountCap = 5
    static let successCountEach = 2
    static let failurePenaltyCap = 5
    static let failureEach = -1
    static let defaultPreset = 5
    static let betterMatchMargin = 15
    static let expirationWarningDays = 30
}

/// Live compatibility, ranking, suggestions, bulk planning, and the import
/// offer. All of it is a function of the snapshot it is given.
enum SigningPresetMatcher {

    static func compatibility(
        of preset: SigningPreset,
        in inventory: PresetInventory,
        for app: PresetAppContext? = nil
    ) -> PresetCompatibilityReport {
        let now = inventory.now
        let certificate = inventory.certificate(matchingFingerprint: preset)
        let resolvedProfile = inventory.profile(matching: preset)
        let profileMatchedByID = preset.provisioningProfileID != nil
            && resolvedProfile?.id == preset.provisioningProfileID
        let profileFellBackToName = preset.provisioningProfileID != nil
            && resolvedProfile != nil
            && !profileMatchedByID

        let certificateCheck = certificateCheck(preset: preset, certificate: certificate, now: now)
        let profileCheck = profileCheck(
            preset: preset,
            profile: resolvedProfile,
            fellBackToName: profileFellBackToName
        )
        let expirationCheck = expirationCheck(certificate: certificate, profile: resolvedProfile, now: now)
        let teamCheck = teamCheck(preset: preset, certificate: certificate, profile: resolvedProfile)
        let bundleEvaluation = app.map { bundleCheck(profile: resolvedProfile, app: $0) }

        let certificateBlocks = certificateCheck.status == .failing || certificateCheck.status == .unknown
        let profileBlocks = profileCheck.status == .failing || profileCheck.status == .unknown
        let expirationBlocks = expirationCheck.status == .failing
        let teamBlocks = teamCheck.status == .failing
        let bundleBlocks = bundleEvaluation?.status == .failing
        let hasWarning = [certificateCheck, profileCheck, expirationCheck, teamCheck].contains { $0.status == .warning }
            || bundleEvaluation?.status == .warning

        let isUsable = preset.isComplete
            && !certificateBlocks
            && !profileBlocks
            && !expirationBlocks
            && !teamBlocks
            && resolvedProfile?.fileIsPresent != false
        let passesPreflight = app != nil && isUsable && bundleBlocks == false && bundleEvaluation?.status == .passing

        let overall: PresetCompatibilityReport.Overall
        if !preset.isComplete {
            overall = .incomplete
        } else if !isUsable || bundleBlocks == true {
            overall = .blocked
        } else if hasWarning {
            overall = .attention
        } else {
            overall = .ready
        }

        let spoken = spokenSummary(
            preset: preset,
            certificate: certificateCheck,
            profile: profileCheck,
            expiration: expirationCheck,
            team: teamCheck,
            bundle: bundleEvaluation,
            overall: overall
        )
        return PresetCompatibilityReport(
            certificate: certificateCheck,
            profile: profileCheck,
            expiration: expirationCheck,
            team: teamCheck,
            bundle: bundleEvaluation,
            overall: overall,
            isUsable: isUsable,
            passesPreflight: passesPreflight,
            spokenSummary: spoken
        )
    }

    static func rank(
        presets: [SigningPreset],
        for app: PresetAppContext?,
        inventory: PresetInventory
    ) -> PresetRanking {
        let scored = presets.map { preset -> (SigningPreset, PresetCompatibilityReport, Int, [String]) in
            let report = compatibility(of: preset, in: inventory, for: app)
            let (score, reasons) = score(preset, report: report, app: app, inventory: inventory)
            return (preset, report, score, reasons)
        }
        let ordered = scored.sorted { lhs, rhs in
            if lhs.2 != rhs.2 { return lhs.2 > rhs.2 }
            let lhsSuccess = app != nil && lhs.0.usage.lastSuccessfulBundleIdentifier == app?.bundleIdentifier
            let rhsSuccess = app != nil && rhs.0.usage.lastSuccessfulBundleIdentifier == app?.bundleIdentifier
            if lhsSuccess != rhsSuccess { return lhsSuccess }
            if lhs.0.isDefault != rhs.0.isDefault { return lhs.0.isDefault }
            let lhsUsed = lhs.0.usage.lastUsedAt ?? .distantPast
            let rhsUsed = rhs.0.usage.lastUsedAt ?? .distantPast
            if lhsUsed != rhsUsed { return lhsUsed > rhsUsed }
            return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
        }
        // Recommendation is an offer to sign a specific app, so it requires
        // preflight. A usable preset with no app in context is not recommended
        // and is not executed.
        let recommendationID = app == nil ? nil : ordered.first { $0.1.passesPreflight }?.0.id
        let matches = ordered.map { preset, report, score, reasons in
            PresetMatch(
                preset: preset,
                report: report,
                score: score,
                reasons: reasons,
                isRecommended: preset.id == recommendationID
            )
        }
        return PresetRanking(matches: matches)
    }

    static func suggestions(
        for preset: SigningPreset,
        inventory: PresetInventory,
        ranking: PresetRanking? = nil,
        app: PresetAppContext? = nil
    ) -> [PresetSuggestion] {
        var suggestions: [PresetSuggestion] = []
        if let profile = inventory.profile(matching: preset), !profile.isExpired(at: inventory.now) {
            let days = profile.daysUntilExpiration(at: inventory.now)
            if days >= 0 && days <= PresetRankingWeights.expirationWarningDays {
                suggestions.append(PresetSuggestion(kind: .expiresSoon(days: days)))
            }
            if let newer = newerCompatibleProfile(than: profile, inventory: inventory, app: app) {
                suggestions.append(PresetSuggestion(kind: .newerCompatibleProfile(name: newer.name)))
            }
        }
        if let app, let ranking, let current = ranking.matches.first(where: { $0.preset.id == preset.id }) {
            if let better = ranking.matches.first(where: { $0.preset.id != preset.id }),
               better.score >= current.score + PresetRankingWeights.betterMatchMargin
                || (better.report.passesPreflight && !current.report.passesPreflight) {
                suggestions.append(PresetSuggestion(kind: .betterMatch(
                    presetName: better.preset.name,
                    reason: advantage(of: better, over: current, app: app)
                )))
            }
        }
        if preset.verificationPreference != .always {
            suggestions.append(PresetSuggestion(kind: .verificationRecommended))
        }
        return suggestions
    }

    static func bulkPlan(
        preset: SigningPreset,
        subjects: [PresetBulkSubject],
        inventory: PresetInventory
    ) -> PresetBulkPlan {
        var compatible: [PresetBulkItem] = []
        var attention: [PresetBulkItem] = []
        for subject in subjects {
            let report = compatibility(of: preset, in: inventory, for: subject.app)
            var reasons: [String] = []
            if !subject.artifactAvailable {
                reasons.append("The package file is not available.")
            }
            if !report.passesPreflight {
                reasons.append(contentsOf: blockingReasons(in: report, app: subject.app))
            }
            let item = PresetBulkItem(
                id: subject.id,
                displayName: subject.displayName,
                bundleIdentifier: subject.bundleIdentifier,
                reasons: reasons
            )
            if reasons.isEmpty && report.passesPreflight && subject.artifactAvailable {
                compatible.append(item)
            } else {
                let listed = item.reasons.isEmpty
                    ? PresetBulkItem(
                        id: item.id,
                        displayName: item.displayName,
                        bundleIdentifier: item.bundleIdentifier,
                        reasons: ["This app needs manual attention before it can use this preset."]
                    )
                    : item
                attention.append(listed)
            }
        }
        return PresetBulkPlan(
            presetID: preset.id,
            presetName: preset.name,
            compatible: compatible,
            needsAttention: attention
        )
    }

    static func importReadiness(
        app: PresetAppContext,
        presets: [SigningPreset],
        inventory: PresetInventory
    ) -> ImportSigningReadiness {
        let ranking = rank(presets: presets, for: app, inventory: inventory)
        return ImportSigningReadiness(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName,
            recommendation: ranking.recommendation
        )
    }

    // MARK: - Checks

    private static func certificateCheck(
        preset: SigningPreset,
        certificate: PresetInventory.Certificate?,
        now: Date
    ) -> PresetCompatibilityCheck {
        guard preset.certificateFingerprint != nil else {
            return PresetCompatibilityCheck(
                id: "certificate",
                title: "Certificate",
                status: .unknown,
                detail: "No certificate is selected."
            )
        }
        guard let certificate else {
            return PresetCompatibilityCheck(
                id: "certificate",
                title: "Certificate",
                status: .failing,
                detail: "The selected certificate is not in the Keychain."
            )
        }
        if now >= certificate.notValidAfter {
            return PresetCompatibilityCheck(
                id: "certificate",
                title: "Certificate",
                status: .failing,
                detail: "\(certificate.displayName) has expired."
            )
        }
        if now < certificate.notValidBefore {
            return PresetCompatibilityCheck(
                id: "certificate",
                title: "Certificate",
                status: .failing,
                detail: "\(certificate.displayName) is not valid yet."
            )
        }
        if !certificate.isUsable {
            return PresetCompatibilityCheck(
                id: "certificate",
                title: "Certificate",
                status: .failing,
                detail: "\(certificate.displayName) is not usable for signing."
            )
        }
        let days = Int((certificate.notValidAfter.timeIntervalSince(now) / 86400).rounded(.toNearestOrEven))
        if days <= PresetRankingWeights.expirationWarningDays {
            return PresetCompatibilityCheck(
                id: "certificate",
                title: "Certificate",
                status: .warning,
                detail: "\(certificate.displayName) expires in \(max(days, 0)) day\(days == 1 ? "" : "s")."
            )
        }
        return PresetCompatibilityCheck(
            id: "certificate",
            title: "Certificate",
            status: .passing,
            detail: "\(certificate.displayName) is available."
        )
    }

    private static func profileCheck(
        preset: SigningPreset,
        profile: PresetInventory.Profile?,
        fellBackToName: Bool
    ) -> PresetCompatibilityCheck {
        guard preset.provisioningProfileName != nil || preset.provisioningProfileID != nil else {
            return PresetCompatibilityCheck(
                id: "profile",
                title: "Profile",
                status: .unknown,
                detail: "No provisioning profile is selected."
            )
        }
        guard let profile else {
            return PresetCompatibilityCheck(
                id: "profile",
                title: "Profile",
                status: .failing,
                detail: "The selected provisioning profile is not in the library."
            )
        }
        if !profile.fileIsPresent {
            return PresetCompatibilityCheck(
                id: "profile",
                title: "Profile",
                status: .failing,
                detail: "\(profile.name) is listed, but its file is not in ZynSign's storage."
            )
        }
        if fellBackToName {
            return PresetCompatibilityCheck(
                id: "profile",
                title: "Profile",
                status: .warning,
                detail: "The saved profile identifier is gone. \(profile.name) matches by name."
            )
        }
        return PresetCompatibilityCheck(
            id: "profile",
            title: "Profile",
            status: .passing,
            detail: "\(profile.name) is available."
        )
    }

    private static func expirationCheck(
        certificate: PresetInventory.Certificate?,
        profile: PresetInventory.Profile?,
        now: Date
    ) -> PresetCompatibilityCheck {
        guard let profile else {
            return PresetCompatibilityCheck(
                id: "expiration",
                title: "Expiration",
                status: .unknown,
                detail: "Expiration cannot be checked without a profile."
            )
        }
        if profile.isExpired(at: now) {
            return PresetCompatibilityCheck(
                id: "expiration",
                title: "Expiration",
                status: .failing,
                detail: "\(profile.name) expired."
            )
        }
        let days = profile.daysUntilExpiration(at: now)
        if days <= PresetRankingWeights.expirationWarningDays {
            return PresetCompatibilityCheck(
                id: "expiration",
                title: "Expiration",
                status: .warning,
                detail: "\(profile.name) expires in \(max(days, 0)) day\(days == 1 ? "" : "s")."
            )
        }
        if let certificate, now < certificate.notValidAfter {
            let certDays = Int((certificate.notValidAfter.timeIntervalSince(now) / 86400).rounded(.toNearestOrEven))
            if certDays <= PresetRankingWeights.expirationWarningDays {
                return PresetCompatibilityCheck(
                    id: "expiration",
                    title: "Expiration",
                    status: .warning,
                    detail: "The certificate expires in \(max(certDays, 0)) day\(certDays == 1 ? "" : "s")."
                )
            }
        }
        return PresetCompatibilityCheck(
            id: "expiration",
            title: "Expiration",
            status: .passing,
            detail: "\(profile.name) expires in \(days) days."
        )
    }

    private static func teamCheck(
        preset: SigningPreset,
        certificate: PresetInventory.Certificate?,
        profile: PresetInventory.Profile?
    ) -> PresetCompatibilityCheck {
        var teams = Set<String>()
        if let team = preset.teamIdentifier { teams.insert(team) }
        if let team = SigningPreset.normalizedTeam(profile?.teamIdentifier) { teams.insert(team) }
        if let team = certificate?.teamIdentifier { teams.insert(team) }
        if teams.count > 1 {
            let listed = teams.sorted().joined(separator: ", ")
            return PresetCompatibilityCheck(
                id: "team",
                title: "Team",
                status: .failing,
                detail: "Team identifiers disagree: \(listed)."
            )
        }
        if let team = teams.first {
            return PresetCompatibilityCheck(
                id: "team",
                title: "Team",
                status: .passing,
                detail: "Team \(team)."
            )
        }
        return PresetCompatibilityCheck(
            id: "team",
            title: "Team",
            status: .unknown,
            detail: "No team identifier is recorded on this preset."
        )
    }

    private static func bundleCheck(
        profile: PresetInventory.Profile?,
        app: PresetAppContext
    ) -> PresetCompatibilityCheck {
        guard let profile else {
            return PresetCompatibilityCheck(
                id: "bundle",
                title: "Bundle ID",
                status: .failing,
                detail: "No profile is available to compare with \(app.bundleIdentifier)."
            )
        }
        if profile.covers(bundleIdentifier: app.bundleIdentifier) {
            return PresetCompatibilityCheck(
                id: "bundle",
                title: "Bundle ID",
                status: .passing,
                detail: "The profile covers \(app.bundleIdentifier)."
            )
        }
        return PresetCompatibilityCheck(
            id: "bundle",
            title: "Bundle ID",
            status: .failing,
            detail: "The profile does not cover \(app.bundleIdentifier)."
        )
    }

    // MARK: - Scoring

    private static func score(
        _ preset: SigningPreset,
        report: PresetCompatibilityReport,
        app: PresetAppContext?,
        inventory: PresetInventory
    ) -> (Int, [String]) {
        var score = 0
        var reasons: [String] = []
        switch report.certificate.status {
        case .passing:
            score += PresetRankingWeights.certificateUsable
            reasons.append("The certificate is available.")
        case .warning:
            score += PresetRankingWeights.certificateUsable / 2
            reasons.append(report.certificate.detail)
        case .failing:
            score += PresetRankingWeights.certificatePresentButUnusable
        case .unknown:
            score += PresetRankingWeights.certificateMissing
        }
        switch report.profile.status {
        case .passing, .warning:
            score += PresetRankingWeights.profilePresent
            if report.profile.status == .passing {
                reasons.append("The profile is available.")
            }
        case .failing, .unknown:
            score += PresetRankingWeights.profileMissing
        }
        if let bundle = report.bundle {
            if bundle.status == .passing {
                score += PresetRankingWeights.bundleCovered
                reasons.append(bundle.detail)
            } else {
                score += PresetRankingWeights.bundleNotCovered
            }
        }
        switch report.team.status {
        case .passing:
            score += PresetRankingWeights.teamAligned
            reasons.append(report.team.detail)
        case .failing:
            score += PresetRankingWeights.teamContradicts
        case .warning, .unknown:
            break
        }
        switch report.expiration.status {
        case .passing:
            score += PresetRankingWeights.expirationHealthy
        case .failing:
            score += PresetRankingWeights.expirationExpired
        case .warning, .unknown:
            break
        }
        if let app, preset.usage.lastSuccessfulBundleIdentifier == app.bundleIdentifier, preset.usage.successfulUses > 0 {
            score += PresetRankingWeights.previousSuccessOnBundle
            reasons.append("This preset has signed this app successfully before.")
        }
        let successes = min(preset.usage.successfulUses, PresetRankingWeights.successCountCap)
        score += successes * PresetRankingWeights.successCountEach
        let failures = min(preset.usage.failedUses, PresetRankingWeights.failurePenaltyCap)
        score += failures * PresetRankingWeights.failureEach
        if preset.isDefault {
            score += PresetRankingWeights.defaultPreset
        }
        _ = inventory
        return (score, reasons)
    }

    private static func newerCompatibleProfile(
        than current: PresetInventory.Profile,
        inventory: PresetInventory,
        app: PresetAppContext?
    ) -> PresetInventory.Profile? {
        guard let currentTeam = SigningPreset.normalizedTeam(current.teamIdentifier) else { return nil }
        return inventory.profiles
            .filter { candidate in
                candidate.id != current.id
                    && !candidate.isExpired(at: inventory.now)
                    && candidate.expirationDate > current.expirationDate
                    && SigningPreset.normalizedTeam(candidate.teamIdentifier) == currentTeam
                    && candidate.fileIsPresent
                    && coversSameScope(candidate, as: current, app: app)
            }
            .max { $0.expirationDate < $1.expirationDate }
    }

    private static func coversSameScope(
        _ candidate: PresetInventory.Profile,
        as current: PresetInventory.Profile,
        app: PresetAppContext?
    ) -> Bool {
        if let app {
            return candidate.covers(bundleIdentifier: app.bundleIdentifier)
                && current.covers(bundleIdentifier: app.bundleIdentifier)
        }
        guard !current.bundleIdentifierPatterns.isEmpty else { return false }
        return current.bundleIdentifierPatterns.allSatisfy { pattern in
            candidate.bundleIdentifierPatterns.contains(pattern)
                || candidate.covers(bundleIdentifier: String(pattern.dropLast(pattern.hasSuffix(".*") ? 2 : 0)))
        }
    }

    private static func advantage(
        of better: PresetMatch,
        over current: PresetMatch,
        app: PresetAppContext
    ) -> String {
        if better.report.bundle?.status == .passing && current.report.bundle?.status != .passing {
            return "Its profile covers \(app.bundleIdentifier)."
        }
        if better.report.certificate.status == .passing && current.report.certificate.status != .passing {
            return "Its certificate is available."
        }
        if better.report.team.status == .passing && current.report.team.status == .failing {
            return "Its team identifier matches."
        }
        if better.report.expiration.status == .passing && current.report.expiration.status != .passing {
            return "Its profile expires later."
        }
        if better.preset.usage.lastSuccessfulBundleIdentifier == app.bundleIdentifier
            && current.preset.usage.lastSuccessfulBundleIdentifier != app.bundleIdentifier {
            return "It has signed this app successfully before."
        }
        return "It ranks higher on the same compatibility checks."
    }

    private static func blockingReasons(
        in report: PresetCompatibilityReport,
        app: PresetAppContext
    ) -> [String] {
        _ = app
        return report.checks.compactMap { check in
            guard check.status == .failing || check.status == .unknown else { return nil }
            return check.detail
        }
    }

    private static func spokenSummary(
        preset: SigningPreset,
        certificate: PresetCompatibilityCheck,
        profile: PresetCompatibilityCheck,
        expiration: PresetCompatibilityCheck,
        team: PresetCompatibilityCheck,
        bundle: PresetCompatibilityCheck?,
        overall: PresetCompatibilityReport.Overall
    ) -> String {
        var parts = ["\(preset.name). \(overall.displayName)."]
        parts.append(certificate.spoken)
        parts.append(profile.spoken)
        parts.append(expiration.spoken)
        parts.append(team.spoken)
        if let bundle { parts.append(bundle.spoken) }
        return parts.joined(separator: " ")
    }
}

extension PresetInventory {
    func certificate(matchingFingerprint preset: SigningPreset) -> Certificate? {
        guard let fingerprint = preset.certificateFingerprint else { return nil }
        return certificate(matching: fingerprint)
    }
}

/// Team reference copied from a certificate subject. Apple team identifiers
/// are ten ASCII letters or digits, often carried in the organizational
/// unit. Anything else is not treated as a team id, so a company name in
/// the OU cannot fail a team comparison by accident.
enum CertificateTeamReference {
    static func teamIdentifier(in name: CertificateDistinguishedName) -> String? {
        guard let raw = name.organizationalUnit?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let normalized = raw.uppercased()
        guard normalized.count == 10,
              normalized.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return nil
        }
        return normalized
    }
}
