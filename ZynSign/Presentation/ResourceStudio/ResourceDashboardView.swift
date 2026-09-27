import SwiftUI

/// The main Asset Dashboard displaying summary count cards and bundle insights.
public struct ResourceDashboardView: View {

    @ObservedObject public var model: ResourceStudioModel

    private let columns = [
        GridItem(.flexible(), spacing: ZSpacing.sm),
        GridItem(.flexible(), spacing: ZSpacing.sm)
    ]

    public init(model: ResourceStudioModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: ZSpacing.md) {
                primaryHeroCard

                if model.catalog.duplicates.hasDuplicates {
                    duplicateAlertCard
                }

                summaryCardsSection

                quickRelationshipsSection
            }
            .padding(ZSpacing.md)
        }
    }

    // MARK: - Hero Card

    private var primaryHeroCard: some View {
        ZCard(variant: .filled) {
            HStack(spacing: ZSpacing.md) {
                if let primary = model.catalog.primaryIcon {
                    LazyImageThumbnail(
                        bundlePath: primary.bundlePath,
                        recordID: model.entry.record.id,
                        mediaLoader: model.mediaLoader,
                        cornerRadius: ZRadius.icon,
                        contentMode: .fill
                    )
                    .frame(width: 64, height: 64)
                    .zynSoftShadow()
                } else {
                    RoundedRectangle(cornerRadius: ZRadius.icon, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 64, height: 64)
                        .overlay {
                            Image(systemName: "photo.stack.fill")
                                .font(.title)
                                .foregroundStyle(Color.accentColor)
                        }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.entry.record.displayName ?? model.entry.record.bundleIdentifier.rawValue)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(model.catalog.summary.totalResourceCount) total bundled resources")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(model.catalog.summary.totalByteCount), countStyle: .file))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }

                Spacer()
            }
        }
    }

    // MARK: - Duplicate Notice

    private var duplicateAlertCard: some View {
        ZCard(variant: .filled) {
            HStack(spacing: ZSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Redundant Resources Detected")
                        .font(.subheadline.weight(.semibold))
                    Text("\(model.catalog.duplicates.totalDuplicateCount) duplicates · \(model.catalog.duplicates.wastedSpaceFormatted) potential savings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    ZHaptics.tap()
                    model.selectedTab = .duplicates
                } label: {
                    Text("Inspect")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Summary Cards

    private var summaryCardsSection: some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            Text("Resource Summary")
                .font(.headline)

            LazyVGrid(columns: columns, spacing: ZSpacing.sm) {
                ResourceSummaryCard(
                    title: "Icons",
                    count: model.catalog.summary.iconCount,
                    systemImage: "app.badge",
                    tint: .orange
                ) {
                    ZHaptics.tap()
                    model.selectedTab = .icons
                }

                ResourceSummaryCard(
                    title: "Launch Assets",
                    count: model.catalog.summary.launchAssetCount,
                    systemImage: "arrow.up.right.video",
                    tint: .indigo
                ) {
                    ZHaptics.tap()
                    model.selectedTab = .launch
                }

                ResourceSummaryCard(
                    title: "Images",
                    count: model.catalog.summary.imageCount,
                    systemImage: "photo",
                    tint: .blue
                ) {
                    ZHaptics.tap()
                    model.selectedTab = .images
                }

                ResourceSummaryCard(
                    title: "Fonts",
                    count: model.catalog.summary.fontCount,
                    systemImage: "textformat",
                    tint: .purple
                ) {
                    ZHaptics.tap()
                    model.selectedTab = .fonts
                }

                ResourceSummaryCard(
                    title: "Audio",
                    count: model.catalog.summary.audioCount,
                    systemImage: "waveform",
                    tint: .pink
                ) {
                    ZHaptics.tap()
                    model.selectedTab = .audio
                }

                ResourceSummaryCard(
                    title: "Videos",
                    count: model.catalog.summary.videoCount,
                    systemImage: "film",
                    tint: .red
                ) {
                    ZHaptics.tap()
                    model.selectedTab = .video
                }

                ResourceSummaryCard(
                    title: "Localization Files",
                    count: model.catalog.summary.localizationCount,
                    systemImage: "globe",
                    tint: .teal
                ) {
                    ZHaptics.tap()
                    model.selectedTab = .localization
                }
            }
        }
    }

    // MARK: - Relationships Preview

    private var quickRelationshipsSection: some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            HStack {
                Text("Asset Groupings")
                    .font(.headline)
                Spacer()
                Button {
                    ZHaptics.tap()
                    model.selectedTab = .relationships
                } label: {
                    Text("View All")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }

            VStack(spacing: ZSpacing.xs) {
                relationshipRow(
                    title: "Icon Families",
                    detail: "\(model.catalog.relationships.iconSets.count) logical sets",
                    systemImage: "app.badge",
                    tint: .orange
                )
                relationshipRow(
                    title: "Font Families",
                    detail: "\(model.catalog.relationships.fontFamilies.count) families",
                    systemImage: "textformat",
                    tint: .purple
                )
                relationshipRow(
                    title: "String Tables",
                    detail: "\(model.catalog.relationships.localizationTables.count) string tables",
                    systemImage: "globe",
                    tint: .teal
                )
            }
        }
    }

    private func relationshipRow(title: String, detail: String, systemImage: String, tint: Color) -> some View {
        ZCard(variant: .filled) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 24)
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .onTapGesture {
            ZHaptics.tap()
            model.selectedTab = .relationships
        }
    }
}
