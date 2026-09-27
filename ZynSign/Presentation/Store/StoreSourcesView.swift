import SwiftUI

struct StoreSourcesView: View {
    @ObservedObject var model: StoreBrowserModel
    @State private var query = ""
    @State private var add = false
    @State private var removing: CatalogSource?
    private var sources: [CatalogSource] {
        model.snapshot.sources.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.url.absoluteString.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        List {
            Section {
                Label("Adding a source is not a trust endorsement.", systemImage: "shield.lefthalf.filled")
                Text("Sources supply unverified metadata and download links. Packages stay isolated until you explicitly import them.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !model.migrationCandidates.isEmpty {
                Section("Previous Sources") {
                    Text("Earlier versions saved sources without full validation. Validate each source to bring it into the new Store. Your previous list is preserved.").font(.footnote)
                    ForEach(model.migrationCandidates) { previous in
                        Button("Validate \(previous.name)") { Task { _ = await model.add(previous.url) } }
                            .disabled(model.adding)
                    }
                }
            }
            if sources.isEmpty { ContentUnavailableView("No Matching Sources", systemImage: "globe", description: Text("Add a repository URL or change your search.")) }
            ForEach(sources) { source in
                Section {
                    NavigationLink { StoreSourceDetailView(id: source.id, model: model) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            StoreArtwork(url: source.iconURL, symbol: "globe").frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: ZRadius.appIcon(side: 48), style: .continuous))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(source.name).font(.headline)
                                Text("\(source.apps.count) apps").font(.caption)
                                if let date = source.refreshedAt { Text("Updated \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                                StoreHealthBadge(source: source)
                                if !model.liveSources.contains(source.id) { Text("Saved metadata").font(.caption).foregroundStyle(.secondary) }
                            }
                            if model.refreshing.contains(source.id) { ProgressView().accessibilityLabel("Refreshing \(source.name)") }
                        }
                    }
                    Toggle("Enable \(source.name)", isOn: Binding(get: { source.enabled }, set: { enabled in Task { await model.enable(source.id, enabled) } }))
                    Button { Task { await model.refresh(source.id) } } label: { Label("Refresh Source", systemImage: "arrow.clockwise") }
                        .disabled(model.refreshing.contains(source.id))
                    Button("Remove Source", role: .destructive) { removing = source }
                }
            }
        }
        .navigationTitle("Sources")
        .searchable(text: $query, prompt: "Source name or URL")
        .toolbar { Button { add = true } label: { Label("Add Source", systemImage: "plus") }.keyboardShortcut("n", modifiers: .command) }
        .sheet(isPresented: $add) { StoreAddSourceView(model: model) }
        .confirmationDialog("Remove \(removing?.name ?? "source")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove Source", role: .destructive) { if let source = removing { Task { await model.remove(source.id) } }; removing = nil }
        } message: { Text("Its apps leave the catalog. Existing download jobs are not cancelled and keep their original source. Update preferences will not switch to another source.") }
        .storeNotice($model.problem)
    }
}

private struct StoreAddSourceView: View {
    @ObservedObject var model: StoreBrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var raw = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Repository URL") {
                    TextField("https://example.com/source.json", text: $raw)
                        .keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Source HTTPS URL")
                }
                Section {
                    Text("ZynSign checks reachability, manifest structure, required fields, and duplicates before saving. Only HTTPS sources and assets are supported.")
                    Text("A successful check does not verify the publisher or establish trust.").font(.callout.weight(.semibold))
                    if let problem = model.problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    if model.adding { ProgressView("Validating source…") }
                    Button("Validate & Add Source") {
                        model.problem = nil
                        Task { if await model.add(raw) { dismiss() } }
                    }.disabled(model.adding || raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Add Source")
            .toolbar { Button("Cancel") { dismiss() }.disabled(model.adding) }
            .interactiveDismissDisabled(model.adding)
        }
    }
}

struct StoreSourceDetailView: View {
    let id: UUID
    @ObservedObject var model: StoreBrowserModel
    var body: some View {
        List {
            if let source = model.snapshot.sources.first(where: { $0.id == id }) {
                Section {
                    StoreArtwork(url: source.iconURL, symbol: "globe").frame(width: 80, height: 80).clipShape(RoundedRectangle(cornerRadius: ZRadius.appIcon(side: 80), style: .continuous))
                    Text(source.name).font(.title.bold())
                    StoreHealthBadge(source: source)
                    Text(source.summary ?? "No source description supplied.")
                    Text(source.url.absoluteString).font(.footnote).textSelection(.enabled)
                    ShareLink(item: source.url) { Label("Share Source", systemImage: "square.and.arrow.up") }
                    Text("Publisher not verified. Health is not a trust rating.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Health") {
                    LabeledContent("Apps", value: "\(source.apps.count)")
                    LabeledContent("Last successful refresh", value: source.refreshedAt?.formatted() ?? "Never")
                    LabeledContent("Last attempt", value: source.attemptedAt?.formatted() ?? "Never")
                    LabeledContent("Newest release", value: source.apps.compactMap { $0.latest.date }.max()?.formatted(date: .abbreviated, time: .omitted) ?? "Not supplied")
                    if let issue = source.problem { Text(issue).foregroundStyle(.orange) }
                    Text(source.apps.isEmpty ? "This source has no apps." : "The last accepted manifest parsed successfully.")
                    if source.status() == .warning { Text("Warning: empty catalog, failed refresh, or metadata not refreshed within seven days.").font(.caption) }
                    Toggle("Source Enabled", isOn: Binding(get: { source.enabled }, set: { value in Task { await model.enable(id, value) } }))
                    Button("Refresh Source") { Task { await model.refresh(id) } }.disabled(model.refreshing.contains(id))
                }
                Section("Apps From This Source") { ForEach(source.apps) { StoreAppLink(app: $0, model: model) } }
            } else { ContentUnavailableView("Source Removed", systemImage: "globe") }
        }.navigationTitle("Source Details").storeNotice($model.problem)
    }
}
