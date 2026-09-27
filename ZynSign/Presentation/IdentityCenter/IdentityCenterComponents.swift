import SwiftUI

/// Shared building blocks of the Developer Identity Center.
///
/// Every color decision in the center lives here, next to the semantic
/// status it renders — the same rule `ZStatusBadge` follows everywhere
/// else in ZynSign. Rows never pick `.green` or `.red` themselves.
enum IdentityCenterPalette {

    /// The color a health status renders in.
    static func color(for status: IdentityHealthStatus) -> Color {
        switch status {
        case .healthy: return .green
        case .warning: return .orange
        case .blocked: return .red
        }
    }

    /// The color a forecast band renders in.
    static func color(for band: ExpirationForecastBand) -> Color {
        switch band {
        case .expired: return .red
        case .critical: return .red
        case .important: return .orange
        case .warning: return .yellow
        case .watch: return .secondary
        }
    }

    /// The color a conflict severity renders in.
    static func color(for severity: IdentityConflictSeverity) -> Color {
        switch severity {
        case .warning: return .orange
        case .blocked: return .red
        }
    }
}

/// One dashboard statistic: a count, its label, and its symbol.
struct IdentityStatCard: View {

    let value: Int
    let label: String
    let symbolName: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xxs) {
            Label {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } icon: {
                Image(systemName: symbolName)
                    .font(.caption2)
                    .foregroundStyle(tint)
            }
            Text("\(value)")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ZSpacing.sm)
        .background(ZColors.cardBackground, in: RoundedRectangle(cornerRadius: ZRadius.card))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// The health dot: the one glyph the center uses to say healthy, warning,
/// or blocked beside a name.
struct IdentityHealthDot: View {

    let status: IdentityHealthStatus

    var body: some View {
        Image(systemName: status.symbolName)
            .foregroundStyle(IdentityCenterPalette.color(for: status))
            .font(.subheadline)
            .accessibilityLabel(status.spokenSummary)
    }
}

/// One health check, rendered as a row: mark, title, and the sentence the
/// engine composed.
struct IdentityCheckRow: View {

    let check: IdentityHealthCheck

    private var symbol: String {
        switch check.outcome {
        case .pass: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .blocked: return "xmark.octagon"
        case .notApplicable: return "minus.circle"
        }
    }

    private var tint: Color {
        switch check.outcome {
        case .pass: return .green
        case .warning: return .orange
        case .blocked: return .red
        case .notApplicable: return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: ZSpacing.sm) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.subheadline)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.kind.displayName)
                    .font(.subheadline.weight(.medium))
                Text(check.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(check.kind.displayName). \(check.outcome.spokenSummary). \(check.detail)")
    }
}

/// The header of one team's workspace section: name, counts, summary, and
/// the disclosure state.
struct TeamWorkspaceHeader: View {

    let team: DeveloperTeam
    let isExpanded: Bool
    let compatibleAppCount: Int

    var body: some View {
        HStack(spacing: ZSpacing.sm) {
            Image(systemName: isExpanded ? "folder.fill" : "folder")
                .foregroundStyle(.tint)
                .font(.subheadline)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(team.displayName)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 0 : -90))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isExpanded ? "Collapses the team." : "Expands the team.")
    }

    private var subtitle: String {
        var parts: [String] = []
        let certificates = team.certificateFingerprints.count
        let profiles = team.profileIDs.count
        if certificates > 0 { parts.append("\(certificates) certificate\(certificates == 1 ? "" : "s")") }
        if profiles > 0 { parts.append("\(profiles) profile\(profiles == 1 ? "" : "s")") }
        if team.isUngrouped { parts.append("no Team ID declared") }
        else if let teamID = team.teamID { parts.append("Team ID \(teamID)") }
        if compatibleAppCount > 0 {
            parts.append("\(compatibleAppCount) compatible app\(compatibleAppCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilitySummary: String {
        var summary = "Team \(team.displayName). "
        summary += "\(team.certificateFingerprints.count) certificates, \(team.profileIDs.count) profiles."
        if let teamID = team.teamID { summary += " Team ID \(teamID.spokenLetters)." }
        return summary
    }
}

/// One row of the expiration forecast.
struct ExpirationForecastRow: View {

    let entry: ExpirationForecastEntry

    var body: some View {
        HStack(spacing: ZSpacing.sm) {
            Image(systemName: entry.kind.symbolName)
                .foregroundStyle(IdentityCenterPalette.color(for: entry.band))
                .font(.subheadline)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                ZStatusBadge(entry.band.displayName, kind: badgeKind)
                Text(entry.countdownText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.kind.displayName) \(entry.name). \(entry.band.displayName). \(entry.countdownText).")
    }

    private var subtitle: String {
        var parts = [entry.kind.displayName]
        if let teamID = entry.teamID { parts.append("Team \(teamID)") }
        parts.append(entry.expirationDate.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }

    private var badgeKind: ZStatusBadge.Kind {
        switch entry.band {
        case .expired, .critical: return .error
        case .important, .warning: return .warning
        case .watch: return .neutral
        }
    }
}

/// One timeline event row.
struct IdentityTimelineRow: View {

    let event: IdentityTimelineEvent

    var body: some View {
        HStack(alignment: .top, spacing: ZSpacing.sm) {
            Image(systemName: event.significance.symbolName)
                .foregroundStyle(tint)
                .font(.subheadline)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.subheadline.weight(.medium))
                if let detail = event.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(event.date.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary)
    }

    private var tint: Color {
        switch event.significance {
        case .positive: return .green
        case .warning: return .orange
        case .neutral: return .secondary
        }
    }

    private var spokenSummary: String {
        let time = event.date.formatted(date: .omitted, time: .shortened)
        var summary = "\(event.title) at \(time)."
        if let detail = event.detail { summary += " \(detail)." }
        return summary
    }
}

/// One conflict card.
struct IdentityConflictCard: View {

    let conflict: IdentityConflict

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            HStack(spacing: ZSpacing.xs) {
                Image(systemName: conflict.severity == .blocked
                    ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(IdentityCenterPalette.color(for: conflict.severity))
                    .font(.subheadline)
                Text(conflict.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                ZStatusBadge(conflict.kind.displayName, kind: conflict.severity == .blocked ? .error : .warning)
            }
            Text(conflict.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label {
                Text(conflict.remedy)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
            }
            .foregroundStyle(.tint)
        }
        .padding(ZSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZColors.cardBackground, in: RoundedRectangle(cornerRadius: ZRadius.card))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(conflict.title). \(conflict.severity.spokenSummary). \(conflict.message) Remedy: \(conflict.remedy)")
    }
}

/// The spoken rendering of a Team ID, letter by letter, so VoiceOver reads
/// "A B C one two three" rather than attempting a word.
extension String {

    var spokenLetters: String {
        map { String($0) }.joined(separator: " ")
    }
}
