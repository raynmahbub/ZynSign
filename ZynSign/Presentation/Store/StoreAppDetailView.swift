import SwiftUI

struct StoreAppDetailView: View {
    let app: CatalogApp
    @ObservedObject var model: StoreBrowserModel
    @State private var gallery: StoreGallerySelection?
    @State private var history = false
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    StoreArtwork(url: app.iconURL).frame(width: 100, height: 100).clipShape(RoundedRectangle(cornerRadius: 24))
                    Text(app.name).font(.largeTitle.bold())
                    Text(app.developer).font(.title3).foregroundStyle(.secondary)
                    if let subtitle = app.subtitle { Text(subtitle).font(.headline) }
                    Label(model.sourceName(app), systemImage: "globe").foregroundStyle(.tint)
                    if !model.liveSources.contains(app.sourceID) {
                        Label("Saved metadata · may be out of date", systemImage: "internaldrive").font(.caption)
                    }
                }.padding(.vertical, 8)
                StoreAppActions(app: app, model: model, queue: model.downloads)
                ShareLink(item: app.latest.downloadURL, subject: Text(app.name), message: Text("\(app.name) from \(model.sourceName(app)). Source and package are not verified by ZynSign.")) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            Section("About") { Text(app.description).textSelection(.enabled) }
            if !app.screenshots.isEmpty {
                Section("Screenshots") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(Array(app.screenshots.enumerated()), id: \.offset) { index, url in
                                Button { gallery = StoreGallerySelection(index: index) } label: {
                                    StoreArtwork(url: url, symbol: "photo").frame(width: 170, height: 300)
                                        .clipShape(RoundedRectangle(cornerRadius: 16))
                                }.buttonStyle(.plain).accessibilityLabel("Open screenshot \(index + 1) of \(app.screenshots.count)")
                            }
                        }
                    }
                }
            }
            Section("Release Notes") {
                StoreReleaseRow(release: app.latest)
                if app.releases.count > 1 {
                    DisclosureGroup("Version History (\(app.releases.count - 1))", isExpanded: $history) {
                        ForEach(Array(app.releases.dropFirst())) { release in StoreReleaseRow(release: release) }
                    }
                }
            }
            Section("Information") {
                LabeledContent("Version", value: app.latest.version)
                LabeledContent("Bundle ID", value: app.bundleID)
                LabeledContent("Category", value: app.category)
                LabeledContent("Download Size", value: app.latest.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Not supplied")
                LabeledContent("Minimum iOS", value: app.latest.minOSVersion ?? "Not supplied")
                if let max = app.latest.maxOSVersion { LabeledContent("Maximum iOS", value: max) }
                Text("Compatibility is declared by the source. Downloading does not guarantee that signing or installation will succeed.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Choose Your Source") {
                Text("Updates only use the source you select. Choosing a preference does not mark a publisher as trusted.").font(.footnote).foregroundStyle(.secondary)
                ForEach(model.variants(app)) { variant in
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent(model.sourceName(variant), value: variant.latest.version)
                        if variant.id != app.id {
                            NavigationLink("View This Listing") { StoreAppDetailView(app: variant, model: model) }
                        }
                        Button {
                            Task { await model.prefer(variant) }
                        } label: {
                            Label(model.snapshot.preferredSources[app.bundleID] == variant.sourceID ? "Preferred Source" : "Use for Updates",
                                  systemImage: model.snapshot.preferredSources[app.bundleID] == variant.sourceID ? "checkmark.circle.fill" : "circle")
                        }.frame(minHeight: 44)
                    }
                }
                NavigationLink { StoreSourceDetailView(id: app.sourceID, model: model) } label: { Label("View Source", systemImage: "globe") }
            }
            Section {
                Label("Unverified source content", systemImage: "shield.lefthalf.filled").font(.headline)
                Text("Descriptions, versions, images, and links are supplied by the repository. Packages remain isolated until you choose Import and review them in the Import Hub. No downloaded code is executed by the Store.").font(.footnote)
            }
        }
        .navigationTitle(app.name).navigationBarTitleDisplayMode(.inline)
        .task { await model.visit(app) }
        .fullScreenCover(item: $gallery) { selection in StoreScreenshotGallery(urls: app.screenshots, initial: selection.index, name: app.name) }
        .storeNotice($model.problem)
    }
}

private struct StoreAppActions: View {
    let app: CatalogApp
    @ObservedObject var model: StoreBrowserModel
    @ObservedObject var queue: StoreDownloadQueue
    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.importPresentation) private var importPresentation
    private var job: StoreDownloadJob? { queue.jobs.last { $0.appID == app.id && $0.release == app.latest } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { model.download(app) } label: { Label("Download", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity, minHeight: 44) }
                .buttonStyle(.borderedProminent)
                .disabled(model.source(app)?.enabled != true || (job.map { [.queued, .downloading, .paused, .ready].contains($0.state) } ?? false))
            if let job {
                Text("\(job.state.rawValue.capitalized) · \(job.sourceName)").font(.caption)
                if job.state == .downloading {
                    if let progress = job.progress { ProgressView(value: progress) } else { ProgressView("Downloading…") }
                }
                Button {
                    if queue.importPackage(job, into: environment.importHub) { importPresentation.present() }
                } label: { Label("Import", systemImage: "square.and.arrow.down").frame(minHeight: 44) }
                    .disabled(job.state != .ready || !importPresentation.isAvailable)
            } else {
                Label("Download first, then import for inspection.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            NavigationLink("Manage Download Jobs") { StoreDownloadsView(queue: queue) }
        }.storeNotice($queue.problem)
    }
}
struct StoreReleaseRow: View {
    let release: CatalogRelease
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Version \(release.version)").font(.headline)
            if let date = release.date { Text(date, format: .dateTime.year().month(.abbreviated).day()).font(.caption).foregroundStyle(.secondary) }
            else { Text("Date not supplied").font(.caption).foregroundStyle(.secondary) }
            Text(release.notes ?? "No release notes supplied.")
        }.padding(.vertical, 8).accessibilityElement(children: .combine)
    }
}
