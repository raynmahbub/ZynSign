import SwiftUI

/// One operation's stages, as they actually happened.
///
/// The view shows every stage in order, with the mark the stage earned: ✓ for
/// completed, ✕ for failed, ⊘ for cancelled, and — for a stage the operation
/// never reached. Stages after a failure are always shown, marked as not
/// reached, so a failure is immediately readable rather than being something
/// the reader has to infer from a missing row.
///
/// The whole row is one accessibility element: VoiceOver reads the stage, its
/// outcome, and what it established as one sentence, which is how a person
/// hears a timeline rather than a table.
struct SigningTimelineView: View {

    /// The operation's stages.
    let timeline: SigningTimeline

    /// Whether stage start and finish times are shown when they were
    /// recorded. Operation details show them; compact surfaces do not.
    var showsTimes: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            ForEach(timeline.entries, id: \.stage) { entry in
                row(for: entry)
            }
        }
        .padding(.vertical, ZSpacing.xxs)
    }

    @ViewBuilder
    private func row(for entry: SigningTimelineEntry) -> some View {
        HStack(alignment: .top, spacing: ZSpacing.sm) {
            Text(entry.status.displayMark)
                .font(.body.weight(.semibold))
                .foregroundStyle(color(for: entry.status))
                .frame(width: 18, alignment: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: ZSpacing.xs) {
                    Text(entry.stage.displayName)
                        .font(.subheadline.weight(entry.status == .notRun ? .regular : .semibold))
                        .foregroundStyle(entry.status == .notRun ? .secondary : .primary)
                    if showsTimes, let finishedAt = entry.finishedAt {
                        Text(Self.timeString(finishedAt))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(entry.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.stage.displayName), \(entry.status.displayName). \(entry.summary)")
    }

    private func color(for status: SigningStageStatus) -> Color {
        switch status {
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .orange
        case .notRun: return .secondary
        }
    }

    private static func timeString(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}

#Preview("Completed") {
    SigningTimelineView(
        timeline: .completed(
            startedAt: Date(timeIntervalSinceNow: -42),
            finishedAt: Date(),
            details: [.export: "Artifact committed as MyApp-1.2.3-456-signed.ipa"]
        )
    )
    .padding()
}

#Preview("Failed at preflight") {
    SigningTimelineView(
        timeline: .stopped(
            after: [.importSource, .validation],
            stopStatus: .failed,
            at: .preflight,
            detail: "The profile does not authorize this bundle identifier."
        ),
        showsTimes: true
    )
    .padding()
}
