import SwiftUI

/// The App Store area — browse and manage your application sources.
///
/// ZynSign's original source browser. It aggregates the user's configured
/// AltSource-compatible feeds, shows newest and featured applications, and
/// lets the user add or refresh sources, search across all feeds, and start
/// a download which lands in Downloads. No remote code is executed; an entry
/// is metadata only until the user explicitly downloads it.
struct AppStoreView: View {

    @StateObject private var model = AppStoreViewModel()
    @State private var searchText = ""
    @State private var showAddSource = false
    @State private var newSourceURL = ""

    private var filtered: [StoreApp] {
        let apps = model.apps
        if searchText.isEmpty { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.bundleID.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.sources.isEmpty {
                    emptySources
                } else if filtered.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if filtered.isEmpty {
                    ContentUnavailableView("No Applications", systemImage: "bag") { Text("This source has no applications.") }
                } else {
                    appList
                }
            }
            .navigationTitle("App Store")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    Button { showAddSource = true } label: { Label("Add Source", systemImage: "plus") }
                }
            }
            .refreshable { await model.refresh() }
            .alert("Add Source", isPresented: $showAddSource) {
                TextField("https://example.com/apps.json", text: $newSourceURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) { newSourceURL = "" }
                Button("Add") {
                    model.addSource(urlString: newSourceURL)
                    newSourceURL = ""
                }
                .disabled(newSourceURL.trimmingCharacters(in: .whitespaces).isEmpty)
            } message: {
                Text("Add an AltSource-compatible JSON feed. ZynSign fetches metadata only — no code is executed until you download.")
            }
            .alert(model.notice?.title ?? "", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }), presenting: model.notice) { _ in Button("OK", role: .cancel) {} } message: { n in Text(n.message) }
        }
        .task { await model.load() }
    }

    private var appList: some View {
        List {
            if !model.featured.isEmpty {
                Section("Featured") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(model.featured) { app in
                                FeaturedCard(app: app) { model.download(app) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                }
            }
            Section(header: Label("All Applications", systemImage: "square.grid.2x2")) {
                ForEach(filtered) { app in
                    AppRow(app: app, onDownload: { model.download(app) })
                }
            }
            Section("Sources \(model.sources.count)") {
                ForEach(model.sources) { src in
                    HStack {
                        Image(systemName: "globe.desk").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(src.name).lineLimit(1)
                            Text(src.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if let ms = src.latencyMs {
                                Text("\(ms) ms").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        Spacer()
                        ZStatusBadge(src.healthBadge, systemImage: src.health.systemImage, kind: src.health == .fast ? .success : (src.health == .slow ? .warning : (src.health == .offline ? .error : .neutral)))
                        if src.isRefreshing { ProgressView().padding(.leading, 4) }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { model.removeSource(src) } label: { Label("Remove", systemImage: "trash") }
                    }
                    .contextMenu {
                        Button { Task { await model.probeHealth(for: src) } } label: { Label("Check Health", systemImage: "heart.text.square") }
                        Button(role: .destructive) { model.removeSource(src) } label: { Label("Remove Source", systemImage: "trash") }
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
            Text("Add a source to discover applications. Try the demo source or paste your own AltSource URL.")
        } actions: {
            VStack(spacing: 12) {
                Button { showAddSource = true } label: { Label("Add Source", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                Button { model.addDemoSource() } label: { Text("Add Demo Source") }
                    .buttonStyle(.bordered)
            }
        }
    }
}

private struct AppRow: View {
    let app: StoreApp
    let onDownload: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: app.iconURL) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                case .failure, .empty: Image(systemName: "app.fill").foregroundStyle(.secondary)
                @unknown default: Color.clear
                }
            }
            .frame(width: 48, height: 48)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).lineLimit(1)
                Text(app.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(app.versionText).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button { onDownload() } label: {
                Text("Get").font(.caption.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            Button { onDownload() } label: { Label("Download", systemImage: "arrow.down.circle") }
        }
    }
}

private struct FeaturedCard: View {
    let app: StoreApp
    let onDownload: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: app.iconURL) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default: Image(systemName: "app.fill").foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(width: 120, height: 120)
            .background(Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            Text(app.name).font(.caption.weight(.semibold)).lineLimit(1)
            Text(app.subtitle ?? app.bundleID).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Button { onDownload() } label: {
                Text("Get").font(.caption2.weight(.bold)).frame(maxWidth: .infinity)
                    .padding(.vertical, 5).background(Color.accentColor, in: Capsule()).foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 140)
        .padding(8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Model

@MainActor
final class AppStoreViewModel: ObservableObject {
    struct Notice: Identifiable { var id: String { title }; let title, message: String }
    struct Source: Identifiable, Equatable, Hashable {
        let id: String; let name: String; let url: URL; var isRefreshing = false
        var health: RepositoryHealth = .unknown
        var latencyMs: Int? = nil
        var healthBadge: String {
            switch health {
            case .fast: return "Fast"
            case .slow: return "Slow"
            case .offline: return "Offline"
            case .unknown: return "—"
            }
        }
    }

    @Published var sources: [Source] = []
    @Published var apps: [StoreApp] = []
    @Published var featured: [StoreApp] = []
    @Published var notice: Notice?

    private let fm = FileManager.default
    private var storeURL: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        return docs.appendingPathComponent("ZynSignSources.json")
    }

    func load() async {
        // Load persisted sources
        if let data = try? Data(contentsOf: storeURL), let arr = try? JSONDecoder().decode([PersistedSource].self, from: data) {
            sources = arr.map { Source(id: $0.id, name: $0.name, url: URL(string: $0.url) ?? URL(string: "https://example.com")!) }
        }
        if sources.isEmpty {
            // Seed with empty so empty state shows add prompt
        } else {
            await refresh()
        }
        // Demo apps if no network yet
        if apps.isEmpty && sources.isEmpty {
            apps = []
            featured = []
        }
    }

    func refresh() async {
        let probe = RepositoryHealthProbe()
        for idx in sources.indices {
            sources[idx].isRefreshing = true
            let url = sources[idx].url
            let start = Date()
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                let ms = Int(Date().timeIntervalSince(start)*1000)
                let httpOK = (response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
                if let feed = try? JSONDecoder().decode(AltSourceFeed.self, from: data), httpOK {
                    let mapped = feed.apps.map { a in
                        StoreApp(id: a.bundleIdentifier, name: a.name, bundleID: a.bundleIdentifier, versionText: [a.version, a.versionDate].compactMap { $0 }.joined(separator: " · "), subtitle: a.subtitle, iconURL: a.iconURL.flatMap { URL(string: $0) }, downloadURL: a.downloadURL.flatMap { URL(string: $0) })
                    }
                    apps.removeAll { existing in mapped.contains { $0.id == existing.id } }
                    apps.append(contentsOf: mapped)
                    apps.sort { $0.name < $1.name }
                    featured = Array(apps.prefix(6))
                    sources[idx].health = ms < 800 ? .fast : (ms < 3000 ? .slow : .offline)
                    sources[idx].latencyMs = ms
                } else {
                    sources[idx].health = httpOK ? .slow : .offline
                    sources[idx].latencyMs = ms
                }
            } catch {
                sources[idx].health = .offline
                sources[idx].latencyMs = nil
                // Also run bounded probe for a second opinion (timeout 3s)
                let result = await probe.probe(url: url)
                sources[idx].health = result.health
                sources[idx].latencyMs = result.latencyMilliseconds
            }
            sources[idx].isRefreshing = false
        }
        persist()
    }

    func probeHealth(for src: Source) async {
        guard let idx = sources.firstIndex(where: { $0.id == src.id }) else { return }
        sources[idx].isRefreshing = true
        let result = await RepositoryHealthProbe().probe(url: src.url)
        sources[idx].health = result.health
        sources[idx].latencyMs = result.latencyMilliseconds
        sources[idx].isRefreshing = false
    }

    func addSource(urlString: String) {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        guard let url = URL(string: s) else {
            notice = Notice(title: "Invalid URL", message: "The URL could not be parsed.")
            return
        }
        let src = Source(id: UUID().uuidString, name: url.host ?? s, url: url)
        sources.append(src)
        persist()
        Task { await refresh() }
    }

    func addDemoSource() {
        // A public AltSource demo feed — no private certs.
        addSource(urlString: "https://qnblackcat.github.io/AltStore/apps.json")
    }

    func removeSource(_ src: Source) {
        sources.removeAll { $0.id == src.id }
        persist()
    }

    func download(_ app: StoreApp) {
        guard let dlURL = app.downloadURL else {
            notice = Notice(title: "No Download", message: "This application has no download URL in its source.")
            return
        }
        // Hand off to Downloads via shared directory + notification so Downloads tab picks it up without tight coupling
        let downloadsDir = (fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory).appendingPathComponent("Downloads", isDirectory: true)
        try? fm.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        // Trigger a download through DownloadsViewModel's URL
        // Post notification and let Downloads handle; for now immediate URLSession
        notice = Notice(title: "Downloading", message: "\(app.name) will appear in Downloads. Switch to the Downloads tab to see progress.")
        // Fire an in-process download via a transient DownloadsViewModel
        Task.detached {
            var req = URLRequest(url: dlURL)
            req.timeoutInterval = 60
            if let (_, resp) = try? await URLSession.shared.download(for: req), let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                // DownloadsView will also handle its own queue; this is just a hint
            }
        }
        // Also post for Downloads tab to start its own download
        NotificationCenter.default.post(name: .zynSignRequestDownload, object: nil, userInfo: ["url": dlURL.absoluteString])
    }

    private func persist() {
        let persisted = sources.map { PersistedSource(id: $0.id, name: $0.name, url: $0.url.absoluteString) }
        if let data = try? JSONEncoder().encode(persisted) { try? data.write(to: storeURL, options: .atomic) }
    }

    private struct PersistedSource: Codable { let id, name, url: String }
    private struct AltSourceFeed: Codable { let apps: [AltApp]; let name: String? }
    private struct AltApp: Codable {
        let name: String
        let bundleIdentifier: String
        let version: String?
        let versionDate: String?
        let subtitle: String?
        let iconURL: String?
        let downloadURL: String?
    }
}

struct StoreApp: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let bundleID: String
    let versionText: String
    let subtitle: String?
    let iconURL: URL?
    let downloadURL: URL?
}

extension Notification.Name { static let zynSignRequestDownload = Notification.Name("zynSign.requestDownload") }
