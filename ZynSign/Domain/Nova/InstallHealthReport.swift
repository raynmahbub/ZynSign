import Foundation

// MARK: - Install Health Pro — the advanced health report

/// One check in an Install Health Pro report.
///
/// A check that did not run is `notPerformed`, and it counts against the
/// score: an open question is never a pass. This is the same rule the
/// Compatibility Lab and the release-readiness tooling follow.
struct InstallHealthCheck: Equatable, Hashable, Identifiable, Sendable {

    enum Kind: String, CaseIterable, Hashable, Sendable {
        case certificateValid
        case profileCompatible
        case noBundleConflict
        case entitlementsCompatible
        case frameworkIntegrity
        case signatureValid
        case deviceCompatible
        case installHistory

        var title: String {
            switch self {
            case .certificateValid: return "Certificate Valid"
            case .profileCompatible: return "Profile Compatible"
            case .noBundleConflict: return "No Conflicts"
            case .entitlementsCompatible: return "Entitlements Compatible"
            case .frameworkIntegrity: return "Framework Integrity"
            case .signatureValid: return "Signature Valid"
            case .deviceCompatible: return "Device Compatible"
            case .installHistory: return "Install History"
            }
        }

        /// How much of the 100-point score this check carries.
        var weight: Int {
            switch self {
            case .certificateValid: return 20
            case .profileCompatible: return 20
            case .signatureValid: return 15
            case .noBundleConflict: return 10
            case .entitlementsCompatible: return 10
            case .frameworkIntegrity: return 10
            case .deviceCompatible: return 10
            case .installHistory: return 5
            }
        }
    }

    enum Status: String, Hashable, Sendable {
        case passed
        case failed
        case notPerformed
    }

    let kind: Kind
    let status: Status
    /// What happened / what was verified / what to do next — one sentence.
    let note: String

    var id: Kind { kind }
}

/// The report: a 0–100 score, a verdict, and the checks behind it.
struct InstallHealthReport: Equatable, Hashable, Sendable {

    enum Verdict: String, Hashable, Sendable {
        case ready
        case attention
        case blocked

        var title: String {
            switch self {
            case .ready: return "Ready"
            case .attention: return "Needs Attention"
            case .blocked: return "Blocked"
            }
        }
    }

    let checks: [InstallHealthCheck]

    init(checks: [InstallHealthCheck]) {
        // One entry per kind, in the declared order; missing kinds are "not performed".
        let byKind = Dictionary(checks.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        self.checks = InstallHealthCheck.Kind.allCases.map { kind in
            byKind[kind] ?? InstallHealthCheck(kind: kind, status: .notPerformed, note: "Not checked in this run.")
        }
    }

    /// Passed weight over total weight. `notPerformed` earns nothing.
    var score: Int {
        let total = InstallHealthCheck.Kind.allCases.reduce(0) { $0 + $1.weight }
        let earned = checks.filter { $0.status == .passed }.reduce(0) { $0 + $1.kind.weight }
        guard total > 0 else { return 0 }
        return Int((Double(earned) / Double(total) * 100).rounded())
    }

    /// Blocked when any gating check failed; attention when anything failed
    /// or was skipped; ready only when every check ran and passed.
    var verdict: Verdict {
        let gating: Set<InstallHealthCheck.Kind> = [.certificateValid, .profileCompatible, .signatureValid]
        if checks.contains(where: { gating.contains($0.kind) && $0.status == .failed }) { return .blocked }
        if checks.allSatisfy({ $0.status == .passed }) { return .ready }
        return .attention
    }

    var failed: [InstallHealthCheck] { checks.filter { $0.status == .failed } }
    var notPerformed: [InstallHealthCheck] { checks.filter { $0.status == .notPerformed } }
}

// MARK: - Preview from workspace facts

extension InstallHealthReport {

    /// The report the Smart Workspace can honestly show *before* a signing
    /// run: what the identity and profile inventory already tells us about
    /// one application. Everything that needs the binary — entitlements,
    /// frameworks, signature, device — stays *not performed*, which is why
    /// this preview never reads "Ready".
    static func preview(for app: NovaFacts.ApplicationFact, facts: NovaFacts, now: Date, expiryWarningDays: Int = 14) -> InstallHealthReport {
        var checks: [InstallHealthCheck] = []

        // Certificate: the best (latest-expiring) valid identity.
        if let best = facts.certificates.filter({ $0.expiresAt > now }).max(by: { $0.expiresAt < $1.expiresAt }) {
            let days = Int((best.expiresAt.timeIntervalSince(now) / 86_400).rounded(.down))
            let note = days <= expiryWarningDays ? "\(best.name) expires in \(days) day\(days == 1 ? "" : "s")." : "\(best.name) is healthy."
            checks.append(InstallHealthCheck(kind: .certificateValid, status: .passed, note: note))
        } else if facts.certificates.isEmpty {
            checks.append(InstallHealthCheck(kind: .certificateValid, status: .notPerformed, note: "No certificate imported yet."))
        } else {
            checks.append(InstallHealthCheck(kind: .certificateValid, status: .failed, note: "Every imported certificate has expired."))
        }

        // Profile: one that covers the bundle identifier and is still valid.
        let covering = facts.profiles.filter { profile in
            profile.bundleIdentifierPatterns.contains { NovaAdvisor.pattern($0, matches: app.bundleIdentifier) }
        }
        if let valid = covering.filter({ $0.expiresAt > now }).max(by: { $0.expiresAt < $1.expiresAt }) {
            let days = Int((valid.expiresAt.timeIntervalSince(now) / 86_400).rounded(.down))
            let note = days <= expiryWarningDays ? "\(valid.name) expires in \(days) day\(days == 1 ? "" : "s")." : "\(valid.name) covers \(app.bundleIdentifier)."
            checks.append(InstallHealthCheck(kind: .profileCompatible, status: .passed, note: note))
        } else if facts.profiles.isEmpty {
            checks.append(InstallHealthCheck(kind: .profileCompatible, status: .notPerformed, note: "No provisioning profile imported yet."))
        } else if covering.isEmpty {
            checks.append(InstallHealthCheck(kind: .profileCompatible, status: .failed, note: "No profile covers \(app.bundleIdentifier)."))
        } else {
            checks.append(InstallHealthCheck(kind: .profileCompatible, status: .failed, note: "The profile that covers this app has expired."))
        }

        // Conflicts: another imported app with the same bundle identifier.
        let duplicates = facts.applications.filter { $0.bundleIdentifier == app.bundleIdentifier }.count
        checks.append(duplicates > 1
            ? InstallHealthCheck(kind: .noBundleConflict, status: .failed, note: "\(duplicates) imported apps share \(app.bundleIdentifier).")
            : InstallHealthCheck(kind: .noBundleConflict, status: .passed, note: "No other imported app uses this bundle identifier."))

        // History is a fact we have.
        checks.append(InstallHealthCheck(kind: .installHistory, status: app.wasSignedBefore ? .passed : .notPerformed,
                                         note: app.wasSignedBefore ? "Signed successfully before." : "Not signed on this device yet."))

        return InstallHealthReport(checks: checks)
    }
}
