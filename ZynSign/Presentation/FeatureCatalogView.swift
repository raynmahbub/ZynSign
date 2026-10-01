import SwiftUI

/// Routes exposed from the catalogue. Store and Downloads remain complete
/// destinations, but opening them from this tab avoids exceeding the native
/// tab bar's five-item limit.
enum FeatureCatalogDestination: Hashable {
    case appStore
    case downloads
}

/// A searchable index of all always-on, staged, and explicitly unsupported
/// product capabilities. Gateable items come directly from
/// `ReleaseFeature.allCases` through `FeatureCatalog`.
struct FeatureCatalogView: View {
    @Binding private var path: [FeatureCatalogDestination]
    @State private var query = ""
    @State private var availabilityFilter: AvailabilityFilter = .all

    private let gate = ReleaseTrain.gate
    private let entries = FeatureCatalog.allEntries

    init(path: Binding<[FeatureCatalogDestination]>) {
        _path = path
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                catalogueSummary

                ForEach(FeatureCatalogCategory.allCases) { category in
                    let categoryEntries = visibleEntries.filter { $0.category == category }
                    if !categoryEntries.isEmpty {
                        Section(category.title) {
                            ForEach(categoryEntries) { entry in
                                featureRow(entry)
                            }
                        }
                    }
                }

                if visibleEntries.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "No Features Match This Filter" : "No Matching Features",
                        systemImage: "magnifyingglass",
                        description: Text(query.isEmpty ? "Choose another availability filter." : "Try a shorter search or a different term.")
                    )
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Features")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, prompt: "Search features")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Availability", selection: $availabilityFilter) {
                            ForEach(AvailabilityFilter.allCases) { filter in
                                Text(filter.title).tag(filter)
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Filter features by availability")
                }
            }
            .navigationDestination(for: FeatureCatalogDestination.self) { destination in
                switch destination {
                case .appStore:
                    AppStoreView(embedsNavigationStack: false)
                case .downloads:
                    DownloadsView(embedsNavigationStack: false)
                }
            }
        }
    }

    private var catalogueSummary: some View {
        Section {
            VStack(alignment: .leading, spacing: ZSpacing.sm) {
                Text("The complete ZynSign capability index")
                    .font(.headline)
                Text("Availability follows this build’s release stage. Debug builds may expose features that a Release build still stages.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: ZSpacing.xs) {
                    countLabel("\(availableCount) available", color: .green)
                    countLabel("\(stagedCount) staged", color: .orange)
                    countLabel("\(unsupportedCount) unsupported", color: .secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(availableCount) available, \(stagedCount) staged, \(unsupportedCount) not supported")
            }
            .padding(.vertical, ZSpacing.xs)
        }
    }

    private var visibleEntries: [FeatureCatalogEntry] {
        entries.filter { entry in
            let status = entry.status(in: gate)
            guard availabilityFilter.includes(status) else { return false }
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
            let searchable = "\(entry.title) \(entry.summary) \(entry.category.title) \(status.label)"
            return searchable.localizedCaseInsensitiveContains(query)
        }
    }

    private var availableCount: Int {
        entries.filter { $0.status(in: gate) == .available }.count
    }

    private var stagedCount: Int {
        entries.filter {
            if case .staged = $0.status(in: gate) { return true }
            return false
        }.count
    }

    private var unsupportedCount: Int {
        entries.filter { $0.status(in: gate) == .notSupported }.count
    }

    @ViewBuilder
    private func featureRow(_ entry: FeatureCatalogEntry) -> some View {
        let status = entry.status(in: gate)
        if status == .available, let destination = destination(for: entry) {
            NavigationLink(value: destination) {
                FeatureCatalogRow(entry: entry, status: status)
            }
        } else {
            FeatureCatalogRow(entry: entry, status: status)
        }
    }

    private func destination(for entry: FeatureCatalogEntry) -> FeatureCatalogDestination? {
        switch entry.availability.releaseFeature {
        case .some(.appStore): return .appStore
        case .some(.downloads): return .downloads
        default: return nil
        }
    }

    private func countLabel(_ value: String, color: Color) -> some View {
        Text(value)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, ZSpacing.sm)
            .padding(.vertical, ZSpacing.xxs)
            .background(color.opacity(0.12), in: Capsule())
            .accessibilityHidden(true)
    }

    private enum AvailabilityFilter: String, CaseIterable, Identifiable {
        case all
        case available
        case staged
        case unsupported

        var id: Self { self }

        var title: String {
            switch self {
            case .all: return "All"
            case .available: return "Available"
            case .staged: return "Staged"
            case .unsupported: return "Not supported"
            }
        }

        func includes(_ status: FeatureCatalogStatus) -> Bool {
            switch self {
            case .all: return true
            case .available: return status == .available
            case .staged:
                if case .staged = status { return true }
                return false
            case .unsupported: return status == .notSupported
            }
        }
    }
}

private struct FeatureCatalogRow: View {
    let entry: FeatureCatalogEntry
    let status: FeatureCatalogStatus

    var body: some View {
        HStack(alignment: .top, spacing: ZSpacing.md) {
            Image(systemName: entry.category.symbolName)
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: ZynSignTokens.Radius.sm, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: ZSpacing.sm) {
                    Text(entry.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: ZSpacing.xs)
                    FeatureStatusPill(status: status)
                }
                Text(entry.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, ZSpacing.xs)
        .accessibilityElement(children: .combine)
    }
}

private struct FeatureStatusPill: View {
    let status: FeatureCatalogStatus

    private var tint: Color {
        switch status {
        case .available: return .green
        case .staged: return .orange
        case .notSupported: return .secondary
        }
    }

    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, ZSpacing.xs)
            .padding(.vertical, ZSpacing.xxs)
            .background(tint.opacity(0.12), in: Capsule())
            .fixedSize()
            .accessibilityLabel(status.label)
    }
}
