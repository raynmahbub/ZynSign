import Foundation

/// One line of the release checklist.
///
/// An item is a promise about a workflow, not a task: it names the checks
/// that settle it and what a failure of it would cost the release. An item
/// whose checks did not run is not a pass — it is an open question, and the
/// evaluation says so.
///
/// `checkIDs` may name one check exactly (`signing.scenario.simpleApplication`)
/// or a whole family by its prefix (`signing.scenario.`). A prefix keeps an
/// item correct when a suite grows; an exact name keeps it precise when one
/// check is what the item means.
struct QAReleaseChecklistItem: Identifiable, Codable, Equatable, Sendable {

    let id: String
    let title: String
    let area: CompatibilityCategory
    let checkIDs: [String]
    let severityIfFailing: ReleaseBlockerSeverity
    let howVerified: String

    /// Whether `checkID` is one this item depends on.
    func depends(on checkID: String) -> Bool {
        checkIDs.contains { reference in
            reference.hasSuffix(".")
                ? checkID.hasPrefix(reference)
                : checkID == reference
        }
    }
}

/// The checklist nothing enters RC 2 without.
///
/// Every workflow the release train switched on has a line, and so do the
/// three that are not features but promises: recovery, accessibility and
/// performance. The list is short on purpose — a checklist that covers
/// everything is one nobody reads.
enum QAReleaseChecklist {

    /// Every item, in the order a release reviewer walks them: the path a
    /// user takes through the app, then the promises underneath it.
    static let items: [QAReleaseChecklistItem] = [
        QAReleaseChecklistItem(
            id: "import",
            title: "Import works",
            area: .signingPipeline,
            checkIDs: ["signing.scenario.", "regression.import"],
            severityIfFailing: .critical,
            howVerified: "Every signing scenario builds a synthetic package and reads it back through the production archive boundary, and the import regressions stay frozen."
        ),
        QAReleaseChecklistItem(
            id: "library",
            title: "Library works",
            area: .signingPipeline,
            checkIDs: ["regression.library"],
            severityIfFailing: .high,
            howVerified: "The library's frozen invariants — record shape, duplicate policy, artifact availability, ordering — are asserted unchanged."
        ),
        QAReleaseChecklistItem(
            id: "certificates",
            title: "Certificates work",
            area: .signingPipeline,
            checkIDs: ["regression.certificates", "security."],
            severityIfFailing: .high,
            howVerified: "Identity handling is asserted to keep private keys non-extractable and the security sweep confirms no key material reaches a file ZynSign writes."
        ),
        QAReleaseChecklistItem(
            id: "profiles",
            title: "Profiles work",
            area: .signingPipeline,
            checkIDs: ["regression.profiles"],
            severityIfFailing: .high,
            howVerified: "Profile parsing, expiration and compatibility keep their frozen results, including the refusal to infer a missing prefix."
        ),
        QAReleaseChecklistItem(
            id: "signing",
            title: "Signing works",
            area: .signingPipeline,
            checkIDs: ["signing."],
            severityIfFailing: .critical,
            howVerified: "The scenario lab reproduces each package shape and the plan validator accepts or refuses it on the record."
        ),
        QAReleaseChecklistItem(
            id: "verification",
            title: "Verification works",
            area: .signingPipeline,
            checkIDs: ["regression.verification", "signing.scenario."],
            severityIfFailing: .critical,
            howVerified: "Independent verification keeps its frozen contract: a verification result is a re-read, never a claim about the signature that produced it."
        ),
        QAReleaseChecklistItem(
            id: "export",
            title: "Export works",
            area: .signingPipeline,
            checkIDs: ["regression.export", "security.exportedReports"],
            severityIfFailing: .high,
            howVerified: "Export naming, availability and the credential-free projection of exported reports are asserted."
        ),
        QAReleaseChecklistItem(
            id: "store",
            title: "Store works",
            area: .storeBrowser,
            checkIDs: ["store."],
            severityIfFailing: .high,
            howVerified: "Sources are probed through injected transports for offline, slow, failing, malformed and truncated responses."
        ),
        QAReleaseChecklistItem(
            id: "downloads",
            title: "Downloads work",
            area: .storeBrowser,
            checkIDs: ["store.download."],
            severityIfFailing: .high,
            howVerified: "Interrupted and partial transfers are asserted to resume or to fail into a typed, retryable state."
        ),
        QAReleaseChecklistItem(
            id: "installation",
            title: "Installation workspace works",
            area: .iOSCompatibility,
            checkIDs: ["platform.ios.", "regression.installation"],
            severityIfFailing: .medium,
            howVerified: "The hand-off builds the same manifest, link and QR on every supported iOS version, and the honest assessment stays typed."
        ),
        QAReleaseChecklistItem(
            id: "backups",
            title: "Backups work",
            area: .securityPosture,
            checkIDs: ["security.backup.", "regression.persistence"],
            severityIfFailing: .medium,
            howVerified: "The backup-behaviour sweep reports what each directory ZynSign writes is marked for, and catalog schema conversion stays frozen."
        ),
        QAReleaseChecklistItem(
            id: "recovery",
            title: "Recovery works",
            area: .crashStatus,
            checkIDs: ["crash.", "resource."],
            severityIfFailing: .critical,
            howVerified: "Cancellation, interrupted work, low storage and memory pressure are asserted to end in typed recoveries the user can act on."
        ),
        QAReleaseChecklistItem(
            id: "accessibility",
            title: "Accessibility passes",
            area: .accessibility,
            checkIDs: ["accessibility."],
            severityIfFailing: .high,
            howVerified: "VoiceOver, Dynamic Type, Reduce Motion and contrast are checked against the running environment's own settings, with the manual protocol named where only a human can judge."
        ),
        QAReleaseChecklistItem(
            id: "performance",
            title: "Performance passes",
            area: .performance,
            checkIDs: ["performance."],
            severityIfFailing: .medium,
            howVerified: "Launch, search, import, signing preparation, scrolling and memory are measured against the internal benchmarks."
        )
    ]
}

/// The outcome of one checklist item against one report.
struct QAReleaseChecklistResult: Identifiable, Codable, Equatable, Sendable {
    let item: QAReleaseChecklistItem
    let status: CompatibilityStatus
    /// The checks the item was settled from, and what each said.
    let evidence: [String]
    /// What the item needs, when it is not a pass.
    let nextStep: String?

    var id: String { item.id }
}

/// Turns a Lab report into the checklist's answers.
enum QAReleaseChecklistEvaluator {

    /// Evaluates every checklist item against `report`.
    ///
    /// An item is a pass when every check it depends on passed, a warning
    /// when the worst it found was a warning, a failure when any check
    /// failed, and not run when a check did not run — or when no check
    /// answered at all, which is reported rather than treated as a pass.
    static func evaluate(_ report: CompatibilityLabReport) -> [QAReleaseChecklistResult] {
        items(report: report)
    }

    static func items(report: CompatibilityLabReport) -> [QAReleaseChecklistResult] {
        QAReleaseChecklist.items.map { item in
            let matching = report.checks.filter { item.depends(on: $0.id) }
            guard !matching.isEmpty else {
                return QAReleaseChecklistResult(
                    item: item,
                    status: .notRun,
                    evidence: ["No check in this report answered for \(item.id)."],
                    nextStep: "Run the Lab with every suite composed, then read this item again."
                )
            }
            let worst = matching.map(\.status).max(by: { $0.severity < $1.severity }) ?? .notRun
            let evidence = matching.map { "\($0.id) — \($0.status.displayName): \($0.summary)" }
            let nextStep: String?
            switch worst {
            case .passed:
                nextStep = nil
            case .warning:
                nextStep = matching.first(where: { $0.status == .warning })?.nextStep
                    ?? "Read the flagged evidence before the next candidate."
            case .failed:
                nextStep = matching.first(where: { $0.status == .failed })?.nextStep
                    ?? "Fix the failing check before the next candidate."
            case .notRun:
                nextStep = matching.first(where: { $0.status == .notRun })?.nextStep
                    ?? "Run this check on a device that can execute it."
            case .skipped:
                nextStep = nil
            }
            return QAReleaseChecklistResult(
                item: item,
                status: worst,
                evidence: evidence,
                nextStep: nextStep
            )
        }
    }

    /// The items that are not settled passes.
    static func outstanding(_ results: [QAReleaseChecklistResult]) -> [QAReleaseChecklistResult] {
        results.filter { $0.status != .passed && $0.status != .skipped }
    }
}

// MARK: - Readiness

/// Whether the release candidate may move on.
enum ReleaseReadiness: String, Codable, CaseIterable, Sendable {
    /// Every item settled as a pass or an accepted warning.
    case ready
    /// Something is open: a check did not run, or an item is unsettled.
    case incomplete
    /// A critical failure is open.
    case blocked

    var displayName: String {
        switch self {
        case .ready: return "Ready"
        case .incomplete: return "Incomplete"
        case .blocked: return "Blocked"
        }
    }

    /// One sentence for the top of the checklist.
    var summary: String {
        switch self {
        case .ready:
            return "Every checklist item is settled. Nothing blocks the next candidate on the evidence in this report."
        case .incomplete:
            return "Something did not run. An unrun check is an open question, not a pass — run it before the next candidate."
        case .blocked:
            return "A critical failure is open. The release candidate is blocked until it is fixed or reclassified with a documented disposition."
        }
    }
}

/// The verdict one report supports.
struct ReleaseReadinessVerdict: Equatable, Sendable {
    let readiness: ReleaseReadiness
    /// The failing checks whose severity blocks a candidate.
    let blockingChecks: [CompatibilityCheck]
    /// The checks that did not run, and therefore settle nothing.
    let unrunChecks: [CompatibilityCheck]
    /// The checklist items that are not settled passes.
    let outstandingItems: [QAReleaseChecklistResult]

    /// The verdict's headline, with counts.
    var headline: String {
        switch readiness {
        case .ready: return "Ready for the next candidate"
        case .incomplete: return "\(unrunChecks.count) check\(unrunChecks.count == 1 ? "" : "s") did not run"
        case .blocked: return "\(blockingChecks.count) critical failure\(blockingChecks.count == 1 ? "" : "s")"
        }
    }
}

/// Decides whether the candidate may move on, from evidence rather than
/// from optimism.
enum ReleaseReadinessEvaluator {

    /// Judges `report` against the QA checklist and the blocker registry.
    static func verdict(for report: CompatibilityLabReport) -> ReleaseReadinessVerdict {
        let results = QAReleaseChecklistEvaluator.items(report: report)
        let blocking = report.checks.filter { check in
            check.status == .failed && (check.blocker ?? .medium).blocksReleaseCandidate
        }
        let unrun = report.checks.filter { !$0.status.isSettled }
        let readiness: ReleaseReadiness
        if !blocking.isEmpty {
            readiness = .blocked
        } else if !unrun.isEmpty {
            readiness = .incomplete
        } else {
            readiness = .ready
        }
        return ReleaseReadinessVerdict(
            readiness: readiness,
            blockingChecks: blocking,
            unrunChecks: unrun,
            outstandingItems: QAReleaseChecklistEvaluator.outstanding(results)
        )
    }
}
