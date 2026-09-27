import SwiftUI

/// Resource & Asset Studio: complete visual inspection suite for imported IPAs.
///
/// Provides deep visual inspection for app icons, launch screens, image galleries,
/// bundled fonts, localization catalogs, audio/video media, duplicate analysis,
/// and asset relationship groupings.
public struct ResourceStudioView: View {

    @StateObject private var model: ResourceStudioModel
    @Environment(\.dismiss) private var dismiss

    public init(entry: LibraryEntry, inspection: IPAResourceStudioInspection) {
        _model = StateObject(wrappedValue: ResourceStudioModel(
            entry: entry,
            inspection: inspection
        ))
    }

    public var body: some View {
        content
            .navigationTitle("Resource & Asset Studio")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $model.searchText,
                prompt: "Search filenames, fonts, keys, formats"
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh resources")
                }
            }
            .sheet(item: Binding(
                get: { model.selectedResource.map { IdentifiableResource(item: $0) } },
                set: { model.selectedResource = $0?.item }
            )) { wrapper in
                ResourceInspectorSheet(
                    item: wrapper.item,
                    appName: model.entry.record.displayName ?? model.entry.record.bundleIdentifier.rawValue
                )
            }
            .sheet(item: Binding(
                get: { model.fullscreenImageItem.map { IdentifiableResource(item: $0) } },
                set: { model.fullscreenImageItem = $0?.item }
            )) { wrapper in
                NavigationStack {
                    ZoomableImageView(
                        bundlePath: wrapper.item.bundlePath,
                        recordID: model.entry.record.id,
                        mediaLoader: model.mediaLoader
                    )
                    .navigationTitle(wrapper.item.fileName)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { model.fullscreenImageItem = nil }
                        }
                    }
                }
            }
            .task {
                await model.load()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            VStack(spacing: ZSpacing.md) {
                ProgressView("Scanning bundle resources…")
                    .progressViewStyle(.circular)
                Text("Indexing icons, fonts, media, and localization tables")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Resource Studio Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    Task { await model.reload() }
                }
                .buttonStyle(.borderedProminent)
            }
        case .loaded:
            loadedView
        }
    }

    private var loadedView: some View {
        VStack(spacing: 0) {
            tabBar

            if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                searchOverlayView
            } else {
                tabContentView
            }
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ZSpacing.xs) {
                ForEach(ResourceStudioModel.Tab.allCases) { tab in
                    Button {
                        ZHaptics.tap()
                        model.selectedTab = tab
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: tab.systemImage)
                                .font(.caption2)
                            Text(tab.rawValue)
                                .font(.subheadline.weight(model.selectedTab == tab ? .semibold : .regular))
                        }
                        .padding(.horizontal, ZSpacing.sm)
                        .padding(.vertical, 7)
                        .background(
                            model.selectedTab == tab
                                ? Color.accentColor
                                : Color(.secondarySystemBackground),
                            in: Capsule()
                        )
                        .foregroundStyle(model.selectedTab == tab ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(tab.rawValue) tab")
                }
            }
            .padding(.horizontal, ZSpacing.md)
            .padding(.vertical, ZSpacing.xs)
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContentView: some View {
        switch model.selectedTab {
        case .dashboard:
            ResourceDashboardView(model: model)
        case .icons:
            AppIconStudioView(model: model)
        case .launch:
            LaunchScreenStudioView(model: model)
        case .images:
            ImageGalleryView(model: model)
        case .fonts:
            FontExplorerView(model: model)
        case .localization:
            LocalizationStudioView(model: model)
        case .audio:
            AudioExplorerView(model: model)
        case .video:
            VideoExplorerView(model: model)
        case .duplicates:
            DuplicateResourcesView(model: model)
        case .relationships:
            AssetRelationshipsView(model: model)
        }
    }

    // MARK: - Search View

    private var searchOverlayView: some View {
        VStack(spacing: 0) {
            ResourceFilterPills(selectedFilter: $model.selectedFilter)

            let results = model.filteredItems
            if results.isEmpty {
                ContentUnavailableView {
                    Label("No Results", systemImage: "magnifyingglass")
                } description: {
                    Text("No resources match '\(model.searchText)'.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    Section("Matches (\(results.count))") {
                        ForEach(results, id: \.id) { item in
                            Button {
                                model.selectedResource = item
                            } label: {
                                HStack(spacing: ZSpacing.sm) {
                                    Image(systemName: item.category.systemImage)
                                        .font(.title3)
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 28)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.fileName)
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(1)
                                        Text(item.detailsText)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.fileSize), countStyle: .file))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
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

/// Identifiable wrapper for protocol items to present in sheets.
private struct IdentifiableResource: Identifiable {
    let item: any ResourceItem
    var id: String { item.id }
}
