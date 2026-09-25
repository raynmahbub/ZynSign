import SwiftUI

// MARK: - Severity and badge mappings

extension ProfileDiagnosticSeverity {
    /// The semantic badge kind this severity renders with. The badge text
    /// always spells the severity out, so color is never the only signal.
    var badgeKind: ZStatusBadge.Kind {
        switch self {
        case .success: return .success
        case .warning: return .warning
        case .error: return .error
        case .unsupported: return .unsupported
        }
    }
}

extension ProfileCompatibilityOutcome {
    /// The semantic badge kind of the Compatibility Summary.
    var badgeKind: ZStatusBadge.Kind {
        switch self {
        case .ready: return .success
        case .attention: return .warning
        case .blocked: return .error
        case .unsupported: return .unsupported
        case .unknown: return .neutral
        }
    }

    /// The SF Symbol paired with the summary badge.
    var systemImage: String {
        switch self {
        case .ready: return "checkmark.shield.fill"
        case .attention: return "exclamationmark.shield"
        case .blocked: return "xmark.shield.fill"
        case .unsupported: return "slash.shield"
        case .unknown: return "questionmark.circle"
        }
    }
}

// MARK: - Badges

/// The expiration badge: Healthy, Expiring Soon (with days), or Expired,
/// with its countdown carried in the label.
struct ProfileExpirationBadge: View {

    let assessment: ProfileExpirationAssessment

    init(_ assessment: ProfileExpirationAssessment) {
        self.assessment = assessment
    }

    var body: some View {
        switch assessment.state {
        case .expired:
            ZStatusBadge(assessment.countdownText, systemImage: assessment.state.systemImage, kind: .error)
        case .expiringSoon:
            ZStatusBadge(assessment.countdownText, systemImage: assessment.state.systemImage, kind: .warning)
        case .healthy:
            ZStatusBadge(assessment.countdownText, systemImage: assessment.state.systemImage, kind: .success)
        }
    }
}

/// The distribution-type badge: Development, Ad Hoc, Enterprise, App Store,
/// or Unknown.
struct ProfileTypeBadge: View {

    let type: ProvisioningProfileClassification

    var body: some View {
        ZStatusBadge(
            type.displayName,
            systemImage: "shippingbox",
            kind: type == .unknown ? .warning : .info
        )
    }
}

/// The Compatibility Summary badge for a report's overall outcome.
struct ProfileCompatibilityBadge: View {

    let outcome: ProfileCompatibilityOutcome

    var body: some View {
        ZStatusBadge(outcome.displayName, systemImage: outcome.systemImage, kind: outcome.badgeKind)
    }
}

// MARK: - Check rows and diagnostics

/// One compatibility check: the question, its status symbol, and its short
/// factual summary. The symbol and text always travel together — VoiceOver
/// reads the status word, not the picture.
struct ProfileCheckRow: View {

    let result: ProfileCompatibilityCheckResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ZSpacing.xs) {
            Image(systemName: result.status.systemImage)
                .foregroundStyle(statusColor)
                .font(.footnote)
                .imageScale(.medium)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.check.question)
                    .font(.subheadline)
                Text(result.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: ZSpacing.xs)
            statusWord
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(result.check.question): \(statusWordText), \(result.summary)")
    }

    private var statusWord: some View {
        Text(statusWordText)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(statusColor)
            .accessibilityHidden(true)
    }

    private var statusWordText: String {
        switch result.status {
        case .pass: return "Pass"
        case .warning: return "Warning"
        case .fail: return "Error"
        case .unsupported: return "Unsupported"
        case .notEvaluated: return "Not Checked"
        }
    }

    private var statusColor: Color {
        switch result.status {
        case .pass: return .green
        case .warning: return .orange
        case .fail: return .red
        case .unsupported: return .secondary
        case .notEvaluated: return .secondary
        }
    }
}

/// The Diagnostics Panel: one actionable message per finding, each wearing
/// its Success / Warning / Error / Unsupported badge. When nothing is
/// wrong, a single success row says so instead of showing an empty box.
struct ProfileDiagnosticsPanel: View {

    let diagnostics: [ProfileDiagnostic]

    var body: some View {
        if diagnostics.isEmpty {
            HStack(spacing: ZSpacing.xs) {
                ZStatusBadge("Success", systemImage: ProfileDiagnosticSeverity.success.systemImage, kind: .success)
                Text("Nothing needs attention.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: ZSpacing.sm) {
                ForEach(diagnostics) { diagnostic in
                    diagnosticRow(diagnostic)
                }
            }
        }
    }

    private func diagnosticRow(_ diagnostic: ProfileDiagnostic) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStatusBadge(
                diagnostic.severity.displayName,
                systemImage: diagnostic.severity.systemImage,
                kind: diagnostic.severity.badgeKind
            )
            Text(diagnostic.title)
                .font(.subheadline.weight(.semibold))
            Text(diagnostic.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(diagnostic.severity.displayName): \(diagnostic.title). \(diagnostic.message)")
    }
}

/// The Compatibility Summary block: overall badge, the counts line, and
/// every check row — the full "pre-sign evaluation" the spec asks for, in
/// one place. Used by the profile detail screen and the app detail screen's
/// suggestion section.
struct ProfileCompatibilitySummaryView: View {

    let report: ProfileCompatibilityReport

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            HStack(spacing: ZSpacing.xs) {
                ProfileCompatibilityBadge(outcome: report.overall)
                Text(report.summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(report.overall.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ForEach(report.results, id: \.check) { result in
                ProfileCheckRow(result: result)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Compatibility Summary")
    }
}
