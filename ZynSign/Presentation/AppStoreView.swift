import SwiftUI

/// The App Store area — browse configured AltSource-compatible repositories.
///
/// Metadata is fetched and validated by `RepositoryDirectory`. Get queues a
/// download in the Download Center. No package is imported, and no code from
/// a source is executed. A source listing is not trust.
struct AppStoreView: View {

    @Environment(\.applicationEnvironment) private var environment

    var body: some View {
        if let directory = environment.repositoryDirectory {
            AppStoreScreen(directory: directory)
        } else {
            ContentUnavailableView(
                "Sources Unavailable",
                systemImage: "globe.desk",
                description: Text("Repository browsing is not installed in this build.")
            )
        }
    }
}

private struct AppStoreScreen: View {

    @ObservedObject var directory: RepositoryDirectory
    @Environment(\.applicationEnvironment) private var environment
    @State private var searchText = ""
    @State private var showAddSource = false
    @State private var newSourceURL = ""
    @State private var notice: String?
    @State private var decision: DownloadDuplicatePrompt?

    /// One catalog entry. Two sources that list the same bundle stay two rows,
    /// so Get does not silently pick a source.
    private struct Listing: Identifiable {
        let catalog: RepositoryCatalog
        let app: RepositoryApp
        var id: String { catalog.sourceURL + "|" + app.bundleIdentifier }
    }

    private var listings: [Listing] {
        let all = directory.catalogs.flatMap { catalog in
            catalog.apps.map { Listing(catalog: catalog, app: $0) }
        }
        let sorted = all.sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter {
            $0.app.name.localizedCaseInsensitiveContains(searchText)
                || $0.app.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
                || $0.catalog.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if directory.sources.isEmpty {
                    emptySources
                } else if listings.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if listings.isEmpty {
                    ContentUnavailableView("No Applications", systemImage: "bag", description: Text("Refresh a source to load its catalog. Apps appear only after the metadata is accepted."))
                } else {
                    appList
                }
            }
            .navigationTitle("App Store")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { Task { await directory.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    Button { showAddSource = true } label: { Label("Add Source", systemImage: "plus") }
                }
            }
            .refreshable { await directory.refresh() }
            .alert("Add Source", isPresented: $showAddSource) {
                TextField("https://example.com/apps.json", text: $newSourceURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) { newSourceURL = "" }
                Button("Add") {
                    let raw = newSourceURL
                    newSourceURL = ""
                    if let message = directory.addSource(urlString: raw) {
                        notice = message
                    } else {
                        Task { await directory.refresh() }
                    }
                }
                .disabled(newSourceURL.trimmingCharacters(in: .whitespaces).isEmpty)
            } message: {
                Text("Add an https AltSource-compatible feed. ZynSign validates the metadata before any package address can be downloaded. No code is executed.")
            }
            .alert("Source", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(notice ?? "")
            }
            .confirmationDialog("Already Held", isPresented: Binding(get: { decision != nil }, set: { if !$0 { decision = nil } }), titleVisibility: .visible) {
                Button("Replace") { resolve(.replace) }
                Button("Keep Both") { resolve(.keepBoth) }
                Button("Skip", role: .cancel) { resolve(.skip) }
            } message: {
                Text(decision?.explanation ?? "")
            }
        }
        .task { directory.load() }
    }

    private var appList: some View {
        List {
            if !listings.prefix(6).isEmpty {
                Section("Featured") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Array(listings.prefix(6))) { listing in
                                FeaturedCard(app: listing.app, sourceName: listing.catalog.name) {
                                    Task { await download(listing) }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }
            Section {
                ForEach(listings) { listing in
                    AppRow(app: listing.app, sourceName: listing.catalog.name) {
                        Task { await download(listing) }
                    }
                }
            } header: {
                Label("All Applications", systemImage: "square.grid.2x2")
            }
            Section("Sources \(directory.sources.count)") {
                ForEach(directory.sources) { source in
                    HStack {
                        Image(systemName: "globe.desk").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name).lineLimit(1)
                            Text(source.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if let milliseconds = source.latencyMilliseconds {
                                Text("\(milliseconds) ms").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            }
                            if let error = source.lastError {
                                Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        ZStatusBadge(
                            source.health.rawValue,
                            systemImage: source.health.systemImage,
                            kind: source.health == .fast ? .success : (source.health == .slow ? .warning : (source.health == .offline ? .error : .neutral))
                        )
                        if source.isRefreshing { ProgressView().padding(.leading, 4) }
                    }
                    .accessibilityElement(children: .combine)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { directory.removeSource(id: source.id) } label: { Label("Remove", systemImage: "trash") }
                    }
                    .contextMenu {
                        Button { Task { await directory.probeHealth(id: source.id) } } label: { Label("Check Health", systemImage: "heart.text.square") }
                        Button(role: .destructive) { directory.removeSource(id: source.id) } label: { Label("Remove Source", systemImage: "trash") }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptySources: some View {
        ContentUnavailableView {
            Label("No Sources", systemImage: "globe.desk")
        } description: {
            Text("Add an https source to discover applications. Packages are not downloaded until you ask, and they are validated before import.")
        } actions: {
            VStack(spacing: 12) {
                Button { showAddSource = true } label: { Label("Add Source", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                Button { addDemo() } label: { Text("Add Demo Source") }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
            }
        }
    }

    private func addDemo() {
        if let message = directory.addSource(urlString: "https://qnblackcat.github.io/AltStore/apps.json") {
            notice = message
        } else {
            Task { await directory.refresh() }
        }
    }

    private func download(_ listing: Listing) async {
        guard let center = environment.downloadCenter else {
            notice = "The Download Center is not available."
            return
        }
        guard var request = UpdatePlanner.downloadRequest(for: listing.app, catalog: listing.catalog) else {
            notice = "Refresh this source before downloading. Its metadata has not been validated."
            return
        }
        request.sourceKind = DownloadRequest.kindRepository
        request.sourceName = listing.catalog.name
        switch await center.enqueue(request) {
        case .queued:
            notice = "\(listing.app.name) was queued in Downloads. It will be validated before it can be imported."
        case .needsDecision:
            decision = center.pendingDecisions.first
        case let .rejected(message):
            notice = message
        case .skipped:
            break
        }
    }

    private func resolve(_ choice: DownloadDuplicateChoice) {
        guard let prompt = decision, let center = environment.downloadCenter else { return }
        decision = nil
        Task { _ = await center.resolveDuplicate(prompt.id, choice: choice) }
    }
}

private struct AppRow: View {
    let app: RepositoryApp
    let sourceName: String
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            icon(url: app.iconURL.flatMap(URL.init(string:)), size: 48, radius: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).lineLimit(1)
                Text(sourceName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(app.latest.version).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button(action: onDownload) {
                Text("Get").font(.caption.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Get \(app.name)")
            .accessibilityHint("Queues a download. The file is validated before it can be imported.")
        }
    }
}

private struct FeaturedCard: View {
    let app: RepositoryApp
    let sourceName: String
    let onDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            icon(url: app.iconURL.flatMap(URL.init(string:)), size: 120, radius: 16)
            Text(app.name).font(.caption.weight(.semibold)).lineLimit(2)
            Text(sourceName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Button(action: onDownload) {
                Text("Get").font(.caption2.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Get \(app.name)")
        }
        .frame(width: 140)
        .padding(8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

private func icon(url: URL?, size: CGFloat, radius: CGFloat) -> some View {
    AsyncImage(url: url) { phase in
        switch phase {
        case let .success(image): image.resizable().scaledToFill()
        default: Image(systemName: "app.fill").foregroundStyle(.secondary)
        }
    }
    .frame(width: size, height: size)
    .background(Color(.secondarySystemBackground))
    .clipShape(RoundedRectangle(cornerRadius: radius))
    .accessibilityHidden(true)
}
