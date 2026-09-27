import SwiftUI

/// The artifact relationship view: one application's lifecycle, from an
/// import to an installed record, drawn from the links ZynSign actually
/// recorded.
///
/// A step with nothing behind it reads as missing — "not yet" — and a step
/// whose facts changed reads as needing attention. Nothing in the picture
/// is invented to make the chain look complete.
struct InstallationRelationshipView: View {

    @ObservedObject var model: InstallationWorkspaceModel
    let row: InstallationWorkspaceModel.InstalledRow

    var body: some View {
        List {
            Section {
                let relationship = assemble()
                ForEach(Array(relationship.nodes.enumerated()), id: \.element.id) { index, node in
                    RelationshipStepRow(node: node, isLast: index == relationship.nodes.count - 1)
                }
            } header: {
                Text("Lifecycle")
            } footer: {
                Text("Every step names a fact ZynSign holds. A missing step is an open position in the chain, shown as it is.")
            }
            relationshipHonesty
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Relationship")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Assembles the lifecycle from what the model holds. The library
    /// entry, when it still exists, provides the import and signing facts;
    /// the record's own events provide the delivery and installation.
    private func assemble() -> InstallationRelationship {
        let candidate = model.candidateRows.first {
            $0.candidate.bundleIdentifier == row.record.bundleIdentifier
        }
        return InstallationRelationship.assemble(
            appName: row.record.displayOrIdentifier,
            importedAt: candidate?.candidate.entry.record.importedAt,
            importAvailable: candidate.map { $0.candidate.isLibraryArtifactAvailable },
            signingRecord: candidate?.candidate.signingRecord,
            exportEntry: row.latestExportEntry ?? candidate?.candidate.exportEntry,
            latestEvent: row.record.latestEvent
        )
    }

    private var relationshipHonesty: some View {
        Section {
            Text("The chain describes ZynSign's records and your confirmations. ZynSign did not observe the delivery, and the platform's decision appears nowhere in it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// One step in the relationship chain, with the connector to the next.
private struct RelationshipStepRow: View {
    let node: InstallationRelationship.Node
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: ZSpacing.sm) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(fill)
                        .frame(width: 30, height: 30)
                    Image(systemName: node.kind.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
                .accessibilityHidden(true)
                if !isLast {
                    Rectangle()
                        .fill(Color(.separator))
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: ZSpacing.xxs) {
                    Text(node.kind.displayName)
                        .font(.subheadline.weight(.semibold))
                    ZStatusBadge(
                        node.state.displayMark,
                        kind: InstallationPresentation.badgeKind(for: node.state)
                    )
                    Spacer()
                }
                Text(node.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(node.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, ZSpacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.kind.displayName): \(node.title). \(node.detail).")
    }

    private var fill: Color {
        switch InstallationPresentation.badgeKind(for: node.state) {
        case .success: return .green.opacity(0.16)
        case .warning: return .orange.opacity(0.16)
        case .error: return .red.opacity(0.16)
        case .neutral: return Color(.tertiarySystemFill)
        case .info: return .blue.opacity(0.14)
        @unknown default: return Color(.tertiarySystemFill)
        }
    }

    private var iconColor: Color {
        switch InstallationPresentation.badgeKind(for: node.state) {
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .neutral: return .secondary
        case .info: return .blue
        @unknown default: return .secondary
        }
    }
}
