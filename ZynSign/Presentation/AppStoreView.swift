import SwiftUI

/// Store entry point; services are composed once, not created by navigation.
struct AppStoreView: View {
    @Environment(\.applicationEnvironment) private var environment
    var body: some View {
        if let model = environment.storeBrowser {
            StoreHomeView(model: model)
        } else {
            ContentUnavailableView("Store Unavailable", systemImage: "bag", description: Text("Store services are not configured."))
        }
    }
}

struct StoreHomeView: View {
    @ObservedObject var model: StoreBrowserModel
    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var query = ""
    @State private var category: String?
    @State private var results: [CatalogApp] = []
    private var filtering: Bool { !query.isEmpty || category != nil }
    var body: some View {
        NavigationStack {
            List {
                if !filtering {
                    welcome
                    destinations
                }
                categoryPicker
                if filtering {
                    Section("\(results.count) Results") {
                        if results.isEmpty { ContentUnavailableView.search(text: query) }
                        ForEach(results) { app in StoreAppLink(app: app, model: model) }
                    }
                } else {
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
                        shelf("Featured Apps", subtitle: "Selected by your sources", apps: model.apps.filter(\.featured))
                        shelf("Recently Updated", subtitle: "Latest release dates reported by sources", apps: model.apps.filter { $0.latest.date != nil }.sorted { ($0.latest.date ?? .distantPast) > ($1.latest.date ?? .distantPast) })
                        shelf("Trending", subtitle: "Most viewed on this device • not community rankings", apps: model.trending)
                        shelf("New Releases", subtitle: "Newest first-known releases in source history", apps: model.apps.sorted { earliest($0) > earliest($1) }.filter { earliest($0) != .distantPast })
                        shelf("Installed Apps", subtitle: "Matched to your Library • device installation is not detectable", apps: model.apps.filter { model.installed[$0.bundleID] != nil })
                        shelf("Continue Browsing", subtitle: "Pick up where you left off", apps: model.continueBrowsing)
                        Section("Unified Catalog") {
                            ForEach(model.apps) { app in StoreAppLink(app: app, model: model) }
                        }
                    }
                }
            }
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
            .task(id: query + "\u{0}" + (category ?? "")) {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                results = model.search(query, category: category)
            }
            .onChange(of: model.apps) { _, _ in results = model.search(query, category: category) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.load(library: environment.library) } }
            }
        }
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
        .background(LinearGradient(colors: [Color(red: 0.12, green: 0.20, blue: 0.46), Color(red: 0.22, green: 0.16, blue: 0.40)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
    }
    private var destinations: some View {
        Section {
            NavigationLink { StoreUpdatesView(model: model) } label: {
                Label("Updates · \(model.updates.count)", systemImage: "arrow.triangle.2.circlepath")
            }
            NavigationLink { StoreDownloadsView(queue: model.downloads) } label: { Label("Download Jobs", systemImage: "arrow.down.circle") }
            NavigationLink { StoreSourcesView(model: model) } label: { Label("Sources", systemImage: "globe") }
        }
    }
    private var categoryPicker: some View {
        Section("Categories") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    categoryButton("All", value: nil)
                    ForEach(model.categories, id: \.self) { categoryButton($0, value: $0) }
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
