import Foundation

/// The five questions the Smart Compatibility Engine asks before signing.
///
/// Each check answers one pre-sign question about a stored profile against
/// an explicit context — the app's bundle identifier when one is known, the
/// certificates on this device, and a reference instant. A check never
/// claims trust, authenticity, CMS validity, or platform acceptance; those
/// belong to the separate verification and signing stages.
enum ProfileCompatibilityCheck: String, CaseIterable, Equatable, Hashable, Sendable {

    /// Does the profile's App ID cover the app being signed?
    case bundleIdentifier

    /// Does the profile's team agree with the local certificates' team?
    case teamIdentifier

    /// Is one of the profile's certificates present on this device?
    case certificateAvailable

    /// Is the profile past (or near) its expiration date?
    case profileExpiration

    /// Is the profile's distribution type usable for on-device signing?
    case profileType

    /// The short name shown in a check row.
    var displayName: String {
        switch self {
        case .bundleIdentifier: return "Bundle ID"
        case .teamIdentifier: return "Team ID"
        case .certificateAvailable: return "Certificate"
        case .profileExpiration: return "Expiration"
        case .profileType: return "Profile Type"
        }
    }

    /// The full question the check answers, used as the row title.
    var question: String {
        switch self {
        case .bundleIdentifier: return "Bundle ID matches"
        case .teamIdentifier: return "Team ID matches"
        case .certificateAvailable: return "Certificate available"
        case .profileExpiration: return "Profile not expired"
        case .profileType: return "Profile type supported"
        }
    }
}

/// The outcome of one compatibility check.
enum ProfileCheckStatus: String, CaseIterable, Equatable, Hashable, Sendable {

    /// The check passed.
    case pass

    /// The check passed with something the user should know.
    case warning

    /// The check failed and blocks a sensible signing.
    case fail

    /// The profile's kind is out of scope for this operation.
    case unsupported

    /// The context did not contain what the check needs (e.g. no app was
    /// named). Never treated as a pass and never treated as a failure.
    case notEvaluated

    /// The SF Symbol that carries the status next to its text.
    var systemImage: String {
        switch self {
        case .pass: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.circle.fill"
        case .unsupported: return "slash.circle.fill"
        case .notEvaluated: return "circle.dashed"
        }
    }
}

/// The severity badges the Diagnostics Panel shows, exactly as the product
/// spec names them: Success, Warning, Error, Unsupported.
enum ProfileDiagnosticSeverity: String, CaseIterable, Equatable, Hashable, Sendable {
    case success
    case warning
    case error
    case unsupported

    /// The badge text (capitalised the way the spec writes it).
    var displayName: String {
        switch self {
        case .success: return "Success"
        case .warning: return "Warning"
        case .error: return "Error"
        case .unsupported: return "Unsupported"
        }
    }

    /// The SF Symbol that accompanies the badge.
    var systemImage: String {
        switch self {
        case .success: return "checkmark.seal.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .unsupported: return "slash.circle"
        }
    }
}

/// One actionable diagnostic produced by a compatibility check: what is
/// wrong, how bad it is, and what the user can do about it. Messages name
/// concrete identifiers (bundle ID, team ID, day counts) because a generic
/// error cannot be acted on.
struct ProfileDiagnostic: Equatable, Identifiable, Sendable {

    /// The check that produced the diagnostic.
    let check: ProfileCompatibilityCheck

    /// The badge severity.
    let severity: ProfileDiagnosticSeverity

    /// The short headline, e.g. "Bundle ID mismatch".
    let title: String

    /// The actionable message.
    let message: String

    var id: String { check.rawValue }
}

/// One check's outcome: status, a short summary line, and the diagnostic
/// the Diagnostics Panel renders (absent only for `.notEvaluated`).
struct ProfileCompatibilityCheckResult: Equatable, Sendable {

    let check: ProfileCompatibilityCheck
    let status: ProfileCheckStatus

    /// A short factual line for the check row, e.g. "Covers com.example.app".
    let summary: String

    /// The actionable diagnostic. `nil` exactly when the check could not
    /// evaluate — an unevaluated check has nothing to report.
    let diagnostic: ProfileDiagnostic?
}

/// The overall Compatibility Summary over all evaluated checks.
enum ProfileCompatibilityOutcome: String, CaseIterable, Equatable, Hashable, Sendable {

    /// Every evaluated check passed.
    case ready

    /// No failure, but at least one warning deserves attention.
    case attention

    /// At least one check failed; signing now would produce a bad result.
    case blocked

    /// No failure, but the profile's distribution type is out of scope.
    case unsupported

    /// Nothing could be evaluated from the given context.
    case unknown

    /// The badge text shown as the Compatibility Summary.
    var displayName: String {
        switch self {
        case .ready: return "Compatible"
        case .attention: return "Needs Attention"
        case .blocked: return "Not Compatible"
        case .unsupported: return "Unsupported"
        case .unknown: return "Not Evaluated"
        }
    }

    /// The one-line explanation under the summary badge.
    var explanation: String {
        switch self {
        case .ready: return "Every check that could run passed. This profile suits the current context."
        case .attention: return "No check failed, but at least one warning should be reviewed before signing."
        case .blocked: return "At least one check failed. Fix the errors below before signing with this profile."
        case .unsupported: return "This profile's distribution type is for App Store submission; ZynSign inspects it but does not sign with it."
        case .unknown: return "Not enough context was available to run the checks."
        }
    }
}

/// The full result of evaluating one profile in one context.
struct ProfileCompatibilityReport: Equatable, Sendable {

    /// The instant the evaluation ran.
    let checkedAt: Date

    /// The app the evaluation targeted, when one was named.
    let targetBundleIdentifier: String?

    /// One result per check, in `ProfileCompatibilityCheck.caseIterable`
    /// order, including checks that could not evaluate.
    let results: [ProfileCompatibilityCheckResult]

    /// The Compatibility Summary over the evaluated checks.
    let overall: ProfileCompatibilityOutcome

    /// The diagnostics the Diagnostics Panel renders, evaluated checks only.
    var diagnostics: [ProfileDiagnostic] {
        results.compactMap(\.diagnostic)
    }

    /// The result of one specific check.
    func result(for check: ProfileCompatibilityCheck) -> ProfileCompatibilityCheckResult? {
        results.first { $0.check == check }
    }

    /// How many checks passed, of those that could evaluate.
    var passedCount: Int {
        results.filter { $0.status == .pass }.count
    }

    /// How many checks could evaluate (everything except `.notEvaluated`).
    var evaluatedCount: Int {
        results.filter { $0.status != .notEvaluated }.count
    }

    /// The summary line, e.g. "4 of 5 checks passed".
    var summaryLine: String {
        guard evaluatedCount > 0 else { return "No checks could run" }
        return "\(passedCount) of \(evaluatedCount) checks passed"
    }
}

/// One local certificate, reduced to the facts a compatibility check needs:
/// its fingerprint, the team in its subject (the OU when present), its
/// display name, and whether its private key is usable for signing.
///
/// Built by the application layer from `IdentityStore` — the engine itself
/// never touches the identity store or any platform API.
struct LocalCertificateFact: Equatable, Sendable {

    /// The certificate's SHA-256 fingerprint as lowercase hexadecimal.
    let fingerprintHex: String

    /// The subject's organizational unit, when the certificate carries one.
    /// Apple developer certificates record the team ID here.
    let teamIdentifier: String?

    /// The subject common name, for messages that name the certificate.
    let displayName: String

    /// Whether this device can currently use the identity for signing.
    let isUsableForSigning: Bool
}

/// Everything an evaluation runs against, assembled in one place so the
/// engine stays a pure function of its inputs.
struct ProfileCompatibilityContext: Equatable, Sendable {

    /// The app's bundle identifier, when a specific app is targeted.
    var targetBundleIdentifier: String?

    /// The certificates on this device.
    var localCertificates: [LocalCertificateFact]

    /// The instant expiration is judged against.
    var referenceDate: Date

    init(
        targetBundleIdentifier: String? = nil,
        localCertificates: [LocalCertificateFact] = [],
        referenceDate: Date = Date()
    ) {
        self.targetBundleIdentifier = targetBundleIdentifier
        self.localCertificates = localCertificates
        self.referenceDate = referenceDate
    }
}

/// The Smart Compatibility Engine: five pure checks over a stored profile
/// summary and an explicit context, plus the overall Compatibility Summary.
///
/// The engine is domain logic — no files, no identity store, no clock, no
/// UI. The application layer assembles the context; the presentation layer
/// renders the report.
struct ProfileCompatibilityEngine {

    init() {}

    /// Evaluates `profile` in `context` and returns the full report.
    func evaluate(
        profile: ProvisioningProfileSummary,
        context: ProfileCompatibilityContext
    ) -> ProfileCompatibilityReport {
        let results: [ProfileCompatibilityCheckResult] = [
            bundleResult(profile: profile, context: context),
            teamResult(profile: profile, context: context),
            certificateResult(profile: profile, context: context),
            expirationResult(profile: profile, context: context),
            typeResult(profile: profile),
        ]
        return ProfileCompatibilityReport(
            checkedAt: context.referenceDate,
            targetBundleIdentifier: context.targetBundleIdentifier,
            results: results,
            overall: overall(for: results)
        )
    }

    // MARK: - Checks

    private func bundleResult(
        profile: ProvisioningProfileSummary,
        context: ProfileCompatibilityContext
    ) -> ProfileCompatibilityCheckResult {
        guard let target = context.targetBundleIdentifier else {
            return ProfileCompatibilityCheckResult(
                check: .bundleIdentifier,
                status: .notEvaluated,
                summary: "No app selected",
                diagnostic: nil
            )
        }
        guard profile.covers(bundleIdentifier: target) else {
            return ProfileCompatibilityCheckResult(
                check: .bundleIdentifier,
                status: .fail,
                summary: "Does not cover \(target)",
                diagnostic: ProfileDiagnostic(
                    check: .bundleIdentifier,
                    severity: .error,
                    title: "Bundle ID mismatch",
                    message: "This profile does not cover \(target). Choose a profile whose App ID matches it, or import a profile that includes this app."
                )
            )
        }
        let isExplicit = profile.bundleIdentifier == target
        return ProfileCompatibilityCheckResult(
            check: .bundleIdentifier,
            status: .pass,
            summary: isExplicit ? "Matches \(target)" : "Wildcard covers \(target)",
            diagnostic: ProfileDiagnostic(
                check: .bundleIdentifier,
                severity: .success,
                title: "Bundle ID matches",
                message: isExplicit
                    ? "This profile is issued for exactly \(target)."
                    : "This profile's wildcard App ID covers \(target)."
            )
        )
    }

    private func teamResult(
        profile: ProvisioningProfileSummary,
        context: ProfileCompatibilityContext
    ) -> ProfileCompatibilityCheckResult {
        guard let profileTeam = profile.teamIdentifier else {
            return ProfileCompatibilityCheckResult(
                check: .teamIdentifier,
                status: .notEvaluated,
                summary: "Profile declares no team",
                diagnostic: nil
            )
        }
        let localTeams = Set(
            context.localCertificates.compactMap(\.teamIdentifier)
        )
        guard !localTeams.isEmpty else {
            return ProfileCompatibilityCheckResult(
                check: .teamIdentifier,
                status: .notEvaluated,
                summary: "No certificate teams to compare",
                diagnostic: nil
            )
        }
        guard !localTeams.contains(profileTeam) else {
            return ProfileCompatibilityCheckResult(
                check: .teamIdentifier,
                status: .pass,
                summary: "Matches team \(profileTeam)",
                diagnostic: ProfileDiagnostic(
                    check: .teamIdentifier,
                    severity: .success,
                    title: "Team ID matches",
                    message: "This profile belongs to team \(profileTeam), and your certificates do too."
                )
            )
        }
        let localDescription = localTeams.sorted().joined(separator: ", ")
        return ProfileCompatibilityCheckResult(
            check: .teamIdentifier,
            status: .warning,
            summary: "Team \(profileTeam) vs \(localDescription)",
            diagnostic: ProfileDiagnostic(
                check: .teamIdentifier,
                severity: .warning,
                title: "Team ID mismatch",
                message: "This profile belongs to team \(profileTeam), but your certificates are for \(localDescription). Signing will likely fail; import a profile or certificate for the same team."
            )
        )
    }

    private func certificateResult(
        profile: ProvisioningProfileSummary,
        context: ProfileCompatibilityContext
    ) -> ProfileCompatibilityCheckResult {
        let recorded = Set(
            (profile.certificateFingerprints ?? []).map { $0.lowercased() }
        )
        guard !recorded.isEmpty else {
            return ProfileCompatibilityCheckResult(
                check: .certificateAvailable,
                status: .warning,
                summary: "Not recorded — refresh to re-read",
                diagnostic: ProfileDiagnostic(
                    check: .certificateAvailable,
                    severity: .warning,
                    title: "Certificates not recorded",
                    message: "This profile was imported before ZynSign recorded its certificates. Run Refresh Validation to re-read the file and check certificate availability."
                )
            )
        }
        guard !context.localCertificates.isEmpty else {
            return ProfileCompatibilityCheckResult(
                check: .certificateAvailable,
                status: .fail,
                summary: "No certificates on this device",
                diagnostic: ProfileDiagnostic(
                    check: .certificateAvailable,
                    severity: .error,
                    title: "Missing certificate",
                    message: "This profile names \(recorded.count) certificate\(recorded.count == 1 ? "" : "s"), but no certificates are imported on this device. Import the .p12 this profile was issued with on the Certificates tab."
                )
            )
        }
        let matches = context.localCertificates.filter {
            recorded.contains($0.fingerprintHex.lowercased())
        }
        guard !matches.isEmpty else {
            return ProfileCompatibilityCheckResult(
                check: .certificateAvailable,
                status: .fail,
                summary: "None of your certificates is in this profile",
                diagnostic: ProfileDiagnostic(
                    check: .certificateAvailable,
                    severity: .error,
                    title: "Missing certificate",
                    message: "None of your imported certificates is named by this profile. Import the .p12 this profile was issued with, or choose a profile that includes one of your certificates."
                )
            )
        }
        guard matches.contains(where: \.isUsableForSigning) else {
            return ProfileCompatibilityCheckResult(
                check: .certificateAvailable,
                status: .warning,
                summary: "\(matches[0].displayName) found, key unavailable",
                diagnostic: ProfileDiagnostic(
                    check: .certificateAvailable,
                    severity: .warning,
                    title: "Certificate key unavailable",
                    message: "\(matches[0].displayName) is named by this profile, but its private key is not available right now. Unlock the device or re-import the .p12 if the key is missing."
                )
            )
        }
        let usable = matches.first { $0.isUsableForSigning } ?? matches[0]
        return ProfileCompatibilityCheckResult(
            check: .certificateAvailable,
            status: .pass,
            summary: "\(usable.displayName) is included",
            diagnostic: ProfileDiagnostic(
                check: .certificateAvailable,
                severity: .success,
                title: "Certificate available",
                message: "\(usable.displayName) is named by this profile and is usable for signing on this device."
            )
        )
    }

    private func expirationResult(
        profile: ProvisioningProfileSummary,
        context: ProfileCompatibilityContext
    ) -> ProfileCompatibilityCheckResult {
        let assessment = profile.expirationAssessment(referenceDate: context.referenceDate)
        switch assessment.state {
        case .expired:
            let days = abs(assessment.daysRemaining)
            let when = days == 0
                ? "today"
                : "\(days) day\(days == 1 ? "" : "s") ago"
            return ProfileCompatibilityCheckResult(
                check: .profileExpiration,
                status: .fail,
                summary: "Expired \(when)",
                diagnostic: ProfileDiagnostic(
                    check: .profileExpiration,
                    severity: .error,
                    title: "Expired profile",
                    message: "This profile expired \(when). Re-export it from the developer portal and import the new file; an expired profile produces packages iOS refuses to launch."
                )
            )
        case .expiringSoon:
            let days = max(assessment.daysRemaining, 0)
            return ProfileCompatibilityCheckResult(
                check: .profileExpiration,
                status: .warning,
                summary: "\(days) day\(days == 1 ? "" : "s") left",
                diagnostic: ProfileDiagnostic(
                    check: .profileExpiration,
                    severity: .warning,
                    title: "Expiring soon",
                    message: "This profile expires in \(days) day\(days == 1 ? "" : "s"). Re-export it from the developer portal soon so signing keeps working."
                )
            )
        case .healthy:
            return ProfileCompatibilityCheckResult(
                check: .profileExpiration,
                status: .pass,
                summary: "\(assessment.daysRemaining) days left",
                diagnostic: ProfileDiagnostic(
                    check: .profileExpiration,
                    severity: .success,
                    title: "Profile not expired",
                    message: "This profile is valid for \(assessment.daysRemaining) more days, until \(assessment.expirationDate.formatted(date: .abbreviated, time: .omitted))."
                )
            )
        }
    }

    private func typeResult(
        profile: ProvisioningProfileSummary
    ) -> ProfileCompatibilityCheckResult {
        switch profile.resolvedProfileType {
        case .appStore:
            return ProfileCompatibilityCheckResult(
                check: .profileType,
                status: .unsupported,
                summary: "App Store — inspection only",
                diagnostic: ProfileDiagnostic(
                    check: .profileType,
                    severity: .unsupported,
                    title: "Unsupported distribution type",
                    message: "App Store profiles are for App Store submission and cannot install outside it. ZynSign inspects this profile but does not sign with it; use a Development, Ad Hoc, or Enterprise profile instead."
                )
            )
        case .unknown:
            return ProfileCompatibilityCheckResult(
                check: .profileType,
                status: .warning,
                summary: "Could not determine the type",
                diagnostic: ProfileDiagnostic(
                    check: .profileType,
                    severity: .warning,
                    title: "Unknown distribution type",
                    message: "ZynSign could not determine this profile's distribution type from its fields. Run Refresh Validation; if the type stays unknown, treat the profile with caution."
                )
            )
        case .development, .adHoc, .enterprise:
            let name = profile.resolvedProfileType.displayName
            return ProfileCompatibilityCheckResult(
                check: .profileType,
                status: .pass,
                summary: "\(name) — supported",
                diagnostic: ProfileDiagnostic(
                    check: .profileType,
                    severity: .success,
                    title: "Profile type supported",
                    message: "\(name) profiles are supported for on-device signing."
                )
            )
        }
    }

    // MARK: - Overall

    /// The Compatibility Summary, ordered: any failure blocks, then an
    /// unsupported type, then warnings, then ready. Checks that could not
    /// evaluate never influence the outcome.
    private func overall(
        for results: [ProfileCompatibilityCheckResult]
    ) -> ProfileCompatibilityOutcome {
        let evaluated = results.filter { $0.status != .notEvaluated }
        guard !evaluated.isEmpty else { return .unknown }
        if evaluated.contains(where: { $0.status == .fail }) { return .blocked }
        if evaluated.contains(where: { $0.status == .unsupported }) { return .unsupported }
        if evaluated.contains(where: { $0.status == .warning }) { return .attention }
        return .ready
    }
}
