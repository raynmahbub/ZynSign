import SwiftUI

/// Asset Relationships: presents logically grouped asset collections (Icon Sets, Launch Sets, String Tables, Font Families).
public struct AssetRelationshipsView: View {

    @ObservedObject public var model: ResourceStudioModel
    @State private var selectedGroupType: GroupType = .iconSets

    private enum GroupType: String, CaseIterable, Identifiable {
        case iconSets = "Icon Sets"
        case launchAssets = "Launch Sets"
        case stringTables = "String Tables"
        case fontFamilies = "Font Families"

        var id: String { rawValue }
    }

    public init(model: ResourceStudioModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Relationship", selection: $selectedGroupType) {
                ForEach(GroupType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .padding(ZSpacing.sm)
            .background(Color(.systemGroupedBackground))

            ScrollView {
                VStack(alignment: .leading, spacing: ZSpacing.md) {
                    switch selectedGroupType {
                    case .iconSets:
                        iconSetsSection
                    case .launchAssets:
                        launchAssetsSection
                    case .stringTables:
                        stringTablesSection
                    case .fontFamilies:
                        fontFamiliesSection
                    }
                }
                .padding(ZSpacing.md)
            }
        }
    }

    // MARK: - Icon Sets

    private var iconSetsSection: some View {
        LazyVStack(spacing: ZSpacing.md) {
            ForEach(model.catalog.relationships.iconSets) { set in
                ZCard(variant: .filled) {
                    VStack(alignment: .leading, spacing: ZSpacing.sm) {
                        HStack {
                            Text(set.name)
                                .font(.headline)
                            Spacer()
                            Text("\(set.count) sizes")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }

                        Text("Resolutions: \(set.resolutionsSummary)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: ZSpacing.xs) {
                                ForEach(set.icons) { icon in
                                    Button {
                                        model.fullscreenImageItem = icon
                                    } label: {
                                        VStack(spacing: 4) {
                                            LazyImageThumbnail(
                                                bundlePath: icon.bundlePath,
                                                recordID: model.entry.record.id,
                                                mediaLoader: model.mediaLoader,
                                                cornerRadius: ZRadius.sm,
                                                contentMode: .fit
                                            )
                                            .frame(width: 48, height: 48)

                                            Text(icon.dimensionsDescription)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Launch Assets

    private var launchAssetsSection: some View {
        let launch = model.catalog.relationships.launchAssets
        return ZCard(variant: .filled) {
            VStack(alignment: .leading, spacing: ZSpacing.sm) {
                HStack {
                    Text(launch.name)
                        .font(.headline)
                    Spacer()
                    Text(launch.activeLaunchType.displayName)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }

                Text("\(launch.totalCount) associated launch elements")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                if !launch.storyboardPaths.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Storyboards:")
                            .font(.caption.weight(.semibold))
                        ForEach(launch.storyboardPaths, id: \.rawValue) { p in
                            Text(p.rawValue)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !launch.launchImages.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Images:")
                            .font(.caption.weight(.semibold))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: ZSpacing.xs) {
                                ForEach(launch.launchImages) { img in
                                    Button {
                                        model.fullscreenImageItem = img
                                    } label: {
                                        LazyImageThumbnail(
                                            bundlePath: img.bundlePath,
                                            recordID: model.entry.record.id,
                                            mediaLoader: model.mediaLoader,
                                            cornerRadius: ZRadius.sm,
                                            contentMode: .fit
                                        )
                                        .frame(width: 50, height: 70)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - String Tables

    private var stringTablesSection: some View {
        LazyVStack(spacing: ZSpacing.sm) {
            ForEach(model.catalog.relationships.localizationTables) { table in
                ZCard(variant: .filled) {
                    VStack(alignment: .leading, spacing: ZSpacing.xs) {
                        HStack {
                            Text(table.tableName)
                                .font(.headline)
                            Spacer()
                            Text("\(table.languageCount) languages")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.teal.opacity(0.15), in: Capsule())
                                .foregroundStyle(.teal)
                        }

                        Text("\(table.totalKeys) total string definitions across languages")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        HStack {
                            Text("Available in: \(table.languages.map { $0.uppercased() }.joined(separator: ", "))")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Font Families

    private var fontFamiliesSection: some View {
        LazyVStack(spacing: ZSpacing.sm) {
            ForEach(model.catalog.relationships.fontFamilies) { family in
                ZCard(variant: .filled) {
                    VStack(alignment: .leading, spacing: ZSpacing.xs) {
                        HStack {
                            Text(family.familyName)
                                .font(.headline)
                            Spacer()
                            Text("\(family.count) styles")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.15), in: Capsule())
                                .foregroundStyle(.purple)
                        }

                        Text("Variants: \(family.stylesSummary)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        ForEach(family.fonts) { font in
                            HStack {
                                Text(font.style)
                                    .font(.subheadline)
                                Spacer()
                                Text(font.fileName)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}
