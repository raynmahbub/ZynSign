import SwiftUI

/// The signing run's stages, one row each, in execution order.
///
/// The list renders `SigningEngineStageRecord` values directly: a finished
/// stage shows a checkmark, the running stage a spinner with its live detail,
/// a skipped stage an honest dash and the reason nothing needed doing, and a
/// failed stage the reason it stopped. Rows scale with Dynamic Type, and each
/// row is one accessibility element with a spoken description of its stage,
/// state, and counts.
struct ZSigningStageList: View {

    /// The stage records, in execution order.
    let records: [SigningEngineStageRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            ForEach(records, id: \.stage) { record in
                ZSigningStageRow(record: record)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Signing stages")
    }
}

/// One stage's row.
struct ZSigningStageRow: View {

    /// The record to render.
    let record: SigningEngineStageRecord

    @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = 24

    var body: some View {
        HStack(alignment: .top, spacing: ZSpacing.sm) {
            statusIcon
                .frame(width: iconWidth, alignment: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: ZSpacing.xs) {
                    Text(record.stage.title)
                        .font(.subheadline.weight(record.state == .active ? .semibold : .regular))
                        .foregroundStyle(titleColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if record.totalItemCount > 0 {
                        Text("\(record.completedItemCount)/\(record.totalItemCount)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail = record.detail, !detail.isEmpty, showsDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(record.state == .failed ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, ZSpacing.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var showsDetail: Bool {
        switch record.state {
        case .active, .failed: return true
        case .skipped: return true
        case .pending, .completed: return false
        }
    }

    private var titleColor: Color {
        switch record.state {
        case .pending: return .secondary
        case .active: return .primary
        case .completed, .skipped: return .primary
        case .failed: return .red
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch record.state {
        case .pending:
            Image(systemName: "circle.dotted")
                .font(.subheadline)
                .foregroundStyle(Color(.tertiaryLabel))
        case .active:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.green)
        case .skipped:
            Image(systemName: "minus.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .font(.subheadline)
                .foregroundStyle(.red)
        }
    }

    /// The spoken description of the row: the stage, its state, its counts,
    /// and its detail when it has one.
    private var accessibilityLabel: String {
        var parts = [record.stage.title]
        switch record.state {
        case .pending: parts.append("waiting")
        case .active: parts.append("in progress")
        case .completed: parts.append("done")
        case .skipped: parts.append("skipped, nothing to do")
        case .failed: parts.append("failed")
        }
        if record.totalItemCount > 0 {
            parts.append("\(record.completedItemCount) of \(record.totalItemCount)")
        }
        if let detail = record.detail, !detail.isEmpty, showsDetail {
            parts.append(detail)
        }
        return parts.joined(separator: ", ")
    }
}
