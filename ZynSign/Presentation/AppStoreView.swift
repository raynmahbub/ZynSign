import SwiftUI

/// Store entry point; services are composed once, not created by navigation.
struct AppStoreView: View {
    /// When this view is pushed into a navigation stack that already exists
    /// — Settings → Browse — it must not wrap itself in a second one.
    /// Nesting `NavigationStack` inside a pushed destination is a runtime
    /// crash, not a warning.
    var embedsNavigationStack: Bool = true

    @Environment(\.applicationEnvironment) private var environment
    var body: some View {
        if let model = environment.storeBrowser {
            StoreHomeView(model: model, embedsNavigationStack: embedsNavigationStack)
        } else {
            ContentUnavailableView("Store Unavailable", systemImage: "bag", description: Text("Store services are not configured."))
        }
    }
}

struct StoreHomeView: View {
    @ObservedObject var model: StoreBrowserModel

    /// Whether this view supplies its own navigation container. False when it
    /// is pushed into a stack the host already owns.
    var embedsNavigationStack: Bool = true
    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var query = ""
    @State private var category: String?
    @State private var sourceFilter: UUID?
    @State private var results: [CatalogApp] = []
    private var filtering: Bool { !query.isEmpty || category != nil || sourceFilter != nil }

    /// The result list shown while a query, category, or source filter is on.
    @ViewBuilder
    private var resultsSection: some View {
        Section("\(results.count) Results") {
            if results.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView("No Matching Apps", systemImage: "line.3.horizontal.decrease.circle", description: Text("Try a different repository or category filter."))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
            ForEach(results) { app in StoreAppLink(app: app, model: model) }
        }
    }

    /// Everything the store shows while no filter is active: recents, the
    /// empty-state invitation, and the shelves.
    @ViewBuilder
    private var browseSections: some View {
        if !model.snapshot.recentSearches.isEmpty {
            Section("Recent Searches") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(model.snapshot.recentSearches, id: \.self) { term in
                        Button(term) { query = term }.buttonStyle(.bordered).frame(minHeight: 44)
                    } }
                }
                Button("Clear Browsing & Search History", role: .destructive) { Task { await model.clearHistory() } }
            }
        }
        if model.apps.isEmpty {
            ContentUnavailableView("Your Store Starts Here", systemImage: "globe", description: Text("Add or enable a source to discover apps. Previously cached sources remain available offline."))
            NavigationLink("Manage Sources") { StoreSourcesView(model: model) }
        } else {
            shelf("Featured This Week", subtitle: "Apps explicitly marked featured by their repositories · not an endorsement", apps: model.apps.filter(\.featured))
            shelf("Trending Apps", subtitle: "Most opened on this device · not repository-wide popularity", apps: model.trending)
            shelf("Recently Updated", subtitle: "Latest release dates reported by sources", apps: recentlyUpdatedApps)
            shelf("New Releases", subtitle: "First-known releases with dates from repository history", apps: newReleaseApps)
            shelf("Suggestions for You", subtitle: "Based on apps you recently viewed · suggestions only", apps: model.suggestions)
            shelf("Saved for Later", subtitle: "Stored locally · saving never downloads", apps: model.savedApps)
            shelf("Continue Browsing", subtitle: "Recently viewed on this device", apps: model.continueBrowsing)
            shelf("Available Updates", subtitle: "Compared with your ZynSign Library records; not device installation status", apps: model.updates.map(\.app))
            Section("Recently Browsed Developers") {
                ForEach(model.recentlyViewedDevelopers, id: \.self) { developer in
                    NavigationLink(developer) { StoreDeveloperView(developer: developer, model: model) }
                }
            }
            Section("Featured Collections") {
                Text("Collections are assembled from repository categories and release metadata, not endorsements.").font(.caption).foregroundStyle(.secondary)
                ForEach(model.collections) { collection in
                    NavigationLink { StoreCollectionDetailView(collection: collection, model: model) } label: {
                        LabeledContent(collection.title, value: "\(collection.apps.count) apps")
                    }
                }
            }
            Section("Staff Picks") {
                Text("No staff-curated list is configured. Explore metadata-based collections instead.").font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Unified Catalog") {
                ForEach(model.apps) { app in StoreAppLink(app: app, model: model) }
            }
        }
    }

    /// Apps whose sources reported a release date, newest first — the
    /// Recently Updated shelf.
    private var recentlyUpdatedApps: [CatalogApp] {
        model.apps
            .filter { $0.latest.date != nil }
            .sorted { ($0.latest.date ?? .distantPast) > ($1.latest.date ?? .distantPast) }
    }

    /// First-known releases with dates from repository history — the New
    /// Releases shelf.
    private var newReleaseApps: [CatalogApp] {
        model.apps
            .sorted { earliest($0) > earliest($1) }
            .filter { earliest($0) != .distantPast }
    }

    var body: some View {
        Group {
            if embedsNavigationStack {
                NavigationStack { storeScreen }
            } else {
                storeScreen
            }
        }
    }

    /// The store's content, with no navigation container of its own, so this
    /// view can be pushed into a stack the host already owns.
    private var storeScreen: some View {
            storeList
                .listStyle(.insetGrouped)
                .navigationTitle("Store")
                .searchable(text: $query, prompt: "Apps, developers, bundle IDs, sources")
                .onSubmit(of: .search) { Task { await model.recordSearch(query) } }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink { StoreSourcesView(model: model) } label: { Label("Sources", systemImage: "globe") }
                    }
                }
                .refreshable { await model.refreshDue() }
                .storeNotice($model.problem)
                .task { await model.load(library: environment.library) }
                .task(id: searchTaskID) {
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                    applySearch()
                }
                .onChange(of: model.apps) { _, _ in applySearch() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.load(library: environment.library) } }
                }
    }

    /// The list contents, split from `body` so the type checker solves the
    /// sections and the modifier chain as two modest expressions.
    @ViewBuilder
    private var storeList: some View {
        List {
            if !filtering {
                welcome
                destinations
            }
            categoryPicker
            if !model.snapshot.sources.isEmpty { sourcePicker }
            if filtering {
                resultsSection
            } else {
                browseSections
            }
        }
    }

    /// Re-runs the client-side search against the current query, category,
    /// and source filter — one place instead of repeating the call in every
    /// task and change handler that needs it.
    private func applySearch() {
        results = model.search(query, category: category, sourceID: sourceFilter)
    }

    /// Identity for the debounced search task: a change to any of these
    /// inputs restarts it.
    private var searchTaskID: String {
        query + "\u{0}" + (category ?? "") + "\u{0}" + (sourceFilter?.uuidString ?? "")
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("YOUR SOURCES. YOUR CHOICE.", systemImage: "sparkles").font(.caption.weight(.bold))
            Text("Find your next\nfavorite app.").font(.largeTitle.bold())
            Text("An independent catalog, built around the repositories you choose.").font(.body)
            Label("\(model.apps.count) apps · \(model.snapshot.sources.filter(\.enabled).count) enabled sources", systemImage: "square.stack.3d.up")
                .font(.subheadline)
            if model.snapshot.sources.contains(where: { $0.enabled && !model.liveSources.contains($0.id) }) {
                Label("Includes saved metadata. Refresh a source to check for changes.", systemImage: "internaldrive").font(.caption)
            }
        }
        .foregroundStyle(.white).padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: ZRadius.xl))
        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
    }
    private var destinations: some View {
        Section {
            NavigationLink { StoreUpdatesView(model: model) } label: {
                Label("Updates · \(model.updates.count)", systemImage: "arrow.triangle.2.circlepath")
            }
            NavigationLink { StoreDownloadsView(queue: model.downloads) } label: { Label("Download Jobs", systemImage: "arrow.down.circle") }
            NavigationLink { StoreSourcesView(model: model) } label: { Label("Sources", systemImage: "globe") }
            NavigationLink { StoreSavedAppsView(model: model) } label: { Label("Saved Items · \(model.savedApps.count)", systemImage: "bookmark") }
            NavigationLink { StoreCollectionsView(model: model) } label: { Label("Collections", systemImage: "square.stack.3d.up") }
            NavigationLink { StoreCategoryExplorerView(model: model) } label: { Label("Browse Categories", systemImage: "square.grid.2x2") }
        }
    }
    private var categoryPicker: some View {
        Section("Categories") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    categoryButton("All", value: nil)
                    ForEach(model.categories, id: \.self) { value in
                        let count = model.categoryCounts.first(where: { $0.name.caseInsensitiveCompare(value) == .orderedSame })?.count ?? 0
                        categoryButton(count > 0 ? "\(value) · \(count)" : value, value: value)
                    }
                }
            }
        }
    }
    private var sourcePicker: some View {
        Section("Repositories") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button { sourceFilter = nil } label: {
                        Text("All Sources").font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(minHeight: 44)
                            .background(sourceFilter == nil ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.09), in: Capsule())
                    }.buttonStyle(.plain).accessibilityAddTraits(sourceFilter == nil ? [.isSelected] : [])
                    ForEach(model.snapshot.sources) { source in
                        Button { sourceFilter = sourceFilter == source.id ? nil : source.id } label: {
                            Text(source.name).font(.subheadline.weight(.semibold)).lineLimit(1).padding(.horizontal, 14).frame(minHeight: 44)
                                .background(sourceFilter == source.id ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.09), in: Capsule())
                        }.buttonStyle(.plain).accessibilityAddTraits(sourceFilter == source.id ? [.isSelected] : [])
                    }
                }
            }
        }
    }
    private func categoryButton(_ title: String, value: String?) -> some View {
        Button { category = value } label: {
            Text(title).font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(minHeight: 44)
                .background(category == value ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.09), in: Capsule())
        }
        .buttonStyle(.plain).accessibilityAddTraits(category == value ? [.isSelected] : [])
    }
    private func earliest(_ app: CatalogApp) -> Date { app.releases.compactMap(\.date).min() ?? .distantPast }
    private func shelf(_ title: String, subtitle: String, apps: [CatalogApp]) -> some View {
        Section {
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            if apps.isEmpty {
                Text(title == "Featured Apps" ? "Your sources have not marked any apps as featured." : "Nothing here yet.").foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(Array(apps.prefix(12))) { app in
                            NavigationLink { StoreAppDetailView(app: app, model: model) } label: {
                                StoreFeatureCard(app: app, source: model.sourceName(app))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.vertical, 6)
                }
            }
        } header: { Text(title).font(.title3.bold()).textCase(nil) }
    }
}
