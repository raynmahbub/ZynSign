import SwiftUI

/// Duplicate Resources: informational analysis of redundant assets in the bundle.
public struct DuplicateResourcesView: View {

    @ObservedObject public var model: ResourceStudioModel

    private var report: ResourceDuplicateReport {
        model.catalog.duplicates
    }

    public init(model: ResourceStudioModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZSpacing.md) {
                summaryBanner

                if report.groups.isEmpty {
                    ContentUnavailableView {
                        Label("No Duplicate Resources", systemImage: "checkmark.circle")
                    } description: {
                        Text("No redundant assets or duplicate files were detected in this bundle.")
                    }
                    .padding(.top, ZSpacing.xl)
                } else {
                    Text("Duplicate Groups (\(report.groups.count))")
                        .font(.headline)

                    LazyVStack(spacing: ZSpacing.md) {
                        ForEach(report.groups) { group in
                            duplicateGroupCard(group)
                        }
                    }
                }
            }
            .padding(ZSpacing.md)
        }
    }

    private var summaryBanner: some View {
        ZCard(variant: .filled) {
            VStack(alignment: .leading, spacing: ZSpacing.xs) {
                HStack {
                    Image(systemName: "doc.on.doc.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("Duplicate Resource Analysis")
                        .font(.headline)
                    Spacer()
                    if report.hasDuplicates {
                        Text("\(report.wastedSpaceFormatted) Wasted")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }

                Text("Informational analysis of bundled assets sharing identical content, names, or dimensions across directories.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Divider()
                    .padding(.vertical, 2)

                HStack(spacing: ZSpacing.lg) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Redundant Files")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(report.totalDuplicateCount)")
                            .font(.title3.weight(.bold))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Duplicate Clusters")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(report.groups.count)")
                            .font(.title3.weight(.bold))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Potential Savings")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(report.wastedSpaceFormatted)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private func duplicateGroupCard(_ group: DuplicateGroup) -> some View {
        ZCard(variant: .filled) {
            VStack(alignment: .leading, spacing: ZSpacing.sm) {
                HStack {
                    Image(systemName: group.category.systemImage)
                        .foregroundStyle(Color.accentColor)
                    Text(group.reason)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(group.fileCount) copies")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }

                HStack {
                    Text("Each: \(ByteCountFormatter.string(fromByteCount: Int64(group.singleFileSize), countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Wasted: \(group.wastedBytesFormatted)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Bundle Locations:")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)

                    ForEach(group.paths, id: \.rawValue) { path in
                        HStack {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(path.rawValue)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
    }
}
