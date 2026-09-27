import SwiftUI

/// Image Gallery: responsive grid view, zoomable preview, format filtering, and search.
public struct ImageGalleryView: View {

    @ObservedObject public var model: ResourceStudioModel
    @State private var formatFilter: String = "All"

    private let columns = [
        GridItem(.adaptive(minimum: 140), spacing: ZSpacing.sm)
    ]

    private var availableFormats: [String] {
        var formats = Set(model.catalog.images.map(\.format))
        formats.insert("All")
        return formats.sorted()
    }

    private var filteredImages: [ImageAsset] {
        var list = model.catalog.images
        if formatFilter != "All" {
            list = list.filter { $0.format.uppercased() == formatFilter.uppercased() }
        }
        if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            let query = model.searchText.lowercased()
            list = list.filter {
                $0.fileName.lowercased().contains(query) ||
                $0.format.lowercased().contains(query) ||
                $0.bundlePath.rawValue.lowercased().contains(query)
            }
        }
        return list
    }

    public init(model: ResourceStudioModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            formatFilterBar

            if filteredImages.isEmpty {
                ContentUnavailableView {
                    Label("No Images Found", systemImage: "photo")
                } description: {
                    Text(model.searchText.isEmpty ? "No images match the selected format filter." : "No images match '\(model.searchText)'.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: ZSpacing.sm) {
                        ForEach(filteredImages) { img in
                            imageGridCell(img)
                        }
                    }
                    .padding(ZSpacing.md)
                }
            }
        }
    }

    private var formatFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ZSpacing.xs) {
                ForEach(availableFormats, id: \.self) { format in
                    Button {
                        ZHaptics.tap()
                        formatFilter = format
                    } label: {
                        Text(format)
                            .font(.caption.weight(formatFilter == format ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                formatFilter == format ? Color.accentColor : Color(.secondarySystemBackground),
                                in: Capsule()
                            )
                            .foregroundStyle(formatFilter == format ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, ZSpacing.md)
            .padding(.vertical, ZSpacing.xs)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func imageGridCell(_ img: ImageAsset) -> some View {
        ZCard(variant: .filled) {
            VStack(alignment: .leading, spacing: 6) {
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
                    .frame(height: 100)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(img.fileName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(img.dimensionsDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text(img.format.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(img.fileSize), countStyle: .file))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Button {
                    model.selectedResource = img
                } label: {
                    Label("Info", systemImage: "info.circle")
                        .font(.caption2)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
    }
}
