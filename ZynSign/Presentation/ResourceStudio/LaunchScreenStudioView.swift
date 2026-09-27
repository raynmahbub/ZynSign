import SwiftUI

/// Launch Screen Studio: displays active launch configuration, storyboards, and launch images.
public struct LaunchScreenStudioView: View {

    @ObservedObject public var model: ResourceStudioModel

    public init(model: ResourceStudioModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZSpacing.lg) {
                activeConfigurationCard

                if !model.catalog.launchAsset.storyboardPaths.isEmpty || !model.catalog.launchAsset.launchNibEntries.isEmpty {
                    storyboardSection
                }

                if !model.catalog.launchAsset.launchImages.isEmpty {
                    launchImagesSection
                } else if model.catalog.launchAsset.storyboardPaths.isEmpty {
                    emptyLaunchNotice
                }
            }
            .padding(ZSpacing.md)
        }
    }

    // MARK: - Active Configuration

    private var activeConfigurationCard: some View {
        ZCard(variant: .filled) {
            VStack(alignment: .leading, spacing: ZSpacing.xs) {
                HStack {
                    Image(systemName: "arrow.up.right.video.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("Active Launch Screen")
                        .font(.headline)
                    Spacer()
                    Text(model.catalog.launchAsset.activeType.displayName)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }

                Text(model.catalog.launchAsset.activeAssetSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let storyboardName = model.catalog.launchAsset.declaredStoryboardName {
                    Divider()
                        .padding(.vertical, 2)
                    HStack {
                        Text("UILaunchStoryboardName:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(storyboardName)
                            .font(.caption.monospaced())
                    }
                }

                if !model.catalog.launchAsset.declaredConfiguration.isEmpty {
                    Divider()
                        .padding(.vertical, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Info.plist UILaunchScreen declarations:")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        ForEach(Array(model.catalog.launchAsset.declaredConfiguration.keys.sorted()), id: \.self) { key in
                            HStack {
                                Text(key)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(model.catalog.launchAsset.declaredConfiguration[key] ?? "")
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Storyboards & NIBs

    private var storyboardSection: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            Text("Launch Storyboards & NIBs")
                .font(.headline)

            LazyVStack(spacing: ZSpacing.xs) {
                ForEach(model.catalog.launchAsset.storyboardPaths, id: \.rawValue) { path in
                    storyboardRow(path: path, kind: "Storyboard")
                }
                ForEach(model.catalog.launchAsset.launchNibEntries, id: \.rawValue) { path in
                    storyboardRow(path: path, kind: "Compiled NIB")
                }
            }
        }
    }

    private func storyboardRow(path: BundlePath, kind: String) -> some View {
        ZCard(variant: .filled) {
            HStack(spacing: ZSpacing.sm) {
                Image(systemName: "rectangle.inset.filled.and.person.filled")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(path.lastComponent)
                        .font(.subheadline.weight(.medium))
                    Text("\(kind) · \(path.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
        }
    }

    // MARK: - Static Launch Images

    private var launchImagesSection: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            Text("Static Launch Images (\(model.catalog.launchAsset.launchImages.count))")
                .font(.headline)

            LazyVStack(spacing: ZSpacing.xs) {
                ForEach(model.catalog.launchAsset.launchImages) { img in
                    ZCard(variant: .filled) {
                        HStack(spacing: ZSpacing.sm) {
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
                                .frame(width: 56, height: 72)
                            }
                            .buttonStyle(.plain)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(img.fileName)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text(img.dimensionsDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(img.fileSize), countStyle: .file))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }

                            Spacer()

                            Button {
                                model.selectedResource = img
                            } label: {
                                Image(systemName: "info.circle")
                                    .font(.body)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    private var emptyLaunchNotice: some View {
        ContentUnavailableView {
            Label("No Launch Assets", systemImage: "arrow.up.right.video")
        } description: {
            Text("This application uses system default presentation without custom static launch assets.")
        }
    }
}
