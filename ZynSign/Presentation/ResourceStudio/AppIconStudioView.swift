import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// App Icon Studio: read-only inspector for primary, alternate, and multi-resolution app icons.
public struct AppIconStudioView: View {

    @ObservedObject public var model: ResourceStudioModel
    @State private var toastMessage: String?

    public init(model: ResourceStudioModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZSpacing.lg) {
                if let primary = model.catalog.primaryIcon {
                    primaryIconSection(primary)
                }

                if !model.catalog.alternateIcons.isEmpty {
                    alternateIconsSection
                }

                allResolutionsSection
            }
            .padding(ZSpacing.md)
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, ZSpacing.md)
                    .padding(.vertical, ZSpacing.xs)
                    .background(Color.black.opacity(0.85), in: Capsule())
                    .padding(.bottom, ZSpacing.lg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Primary Icon

    private func primaryIconSection(_ icon: AppIconAsset) -> some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            Text("Primary App Icon")
                .font(.headline)

            ZCard(variant: .filled) {
                VStack(spacing: ZSpacing.md) {
                    HStack(spacing: ZSpacing.md) {
                        Button {
                            model.fullscreenImageItem = icon
                        } label: {
                            LazyImageThumbnail(
                                bundlePath: icon.bundlePath,
                                recordID: model.entry.record.id,
                                mediaLoader: model.mediaLoader,
                                cornerRadius: ZRadius.lg,
                                contentMode: .fit
                            )
                            .frame(width: 96, height: 96)
                            .zynSoftShadow()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Primary app icon preview")
                        .accessibilityHint("Tap for full screen zoom preview")

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(icon.fileName)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text("Primary")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                            }

                            Text("Dimensions: \(icon.dimensionsDescription)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            if let scale = icon.scale {
                                Text("Scale: @\(scale)x")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            Text(ByteCountFormatter.string(fromByteCount: Int64(icon.fileSize), countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    HStack(spacing: ZSpacing.sm) {
                        Button {
                            model.fullscreenImageItem = icon
                        } label: {
                            Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered)

                        Button {
                            copyText(icon.fileName, label: "Filename copied")
                        } label: {
                            Label("Copy Filename", systemImage: "doc.on.doc")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered)

                        Button {
                            copyText(icon.bundlePath.rawValue, label: "Bundle path copied")
                        } label: {
                            Label("Reveal in Bundle", systemImage: "folder")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button {
                            model.selectedResource = icon
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.body)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("File Inspector")
                    }
                }
            }
        }
    }

    // MARK: - Alternate Icons

    private var alternateIconsSection: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            Text("Alternate Icons (\(model.catalog.alternateIcons.count))")
                .font(.headline)

            LazyVStack(spacing: ZSpacing.xs) {
                ForEach(model.catalog.alternateIcons) { alt in
                    iconRow(alt)
                }
            }
        }
    }

    // MARK: - All Resolutions

    private var allResolutionsSection: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            Text("All Discovered Resolutions (\(model.catalog.icons.count))")
                .font(.headline)

            LazyVStack(spacing: ZSpacing.xs) {
                ForEach(model.catalog.icons) { icon in
                    iconRow(icon)
                }
            }

            Text("App icons are read-only and extracted safely without altering package contents.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, ZSpacing.xs)
        }
    }

    private func iconRow(_ icon: AppIconAsset) -> some View {
        ZCard(variant: .filled) {
            HStack(spacing: ZSpacing.sm) {
                Button {
                    model.fullscreenImageItem = icon
                } label: {
                    LazyImageThumbnail(
                        bundlePath: icon.bundlePath,
                        recordID: model.entry.record.id,
                        mediaLoader: model.mediaLoader,
                        cornerRadius: ZRadius.sm,
                        contentMode: .fit
                    )
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(icon.fileName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(icon.detailsText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Menu {
                    Button {
                        model.fullscreenImageItem = icon
                    } label: {
                        Label("Preview Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    Button {
                        copyText(icon.fileName, label: "Filename copied")
                    } label: {
                        Label("Copy Filename", systemImage: "doc.on.doc")
                    }
                    Button {
                        copyText(icon.bundlePath.rawValue, label: "Path copied")
                    } label: {
                        Label("Reveal in Bundle", systemImage: "folder")
                    }
                    Divider()
                    Button {
                        model.selectedResource = icon
                    } label: {
                        Label("File Inspector", systemImage: "info.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func copyText(_ text: String, label: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
        ZHaptics.tap()
        withAnimation {
            toastMessage = label
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                if toastMessage == label {
                    toastMessage = nil
                }
            }
        }
    }
}
