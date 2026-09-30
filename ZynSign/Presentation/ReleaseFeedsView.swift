import SwiftUI

/// The observable model behind the Release Feeds screen.
@MainActor
final class ReleaseFeedsModel: ObservableObject {

    struct FeedState: Identifiable, Equatable {
        let reference: ReleaseFeedReference
        var snapshot: ReleaseFeedSnapshot?
        var isRefreshing = false
        var errorMessage: String?
        var id: String { "\(reference.owner)/\(reference.repository)" }
    }

    @Published private(set) var feeds: [FeedState] = []
    @Published private(set) var updates: [LibraryUpdateTracker.AvailableUpdate] = []
    @Published var addFieldText = ""
    @Published var addError: String?

    private let provider: GitHubReleaseSourceProvider
    private let library: ApplicationLibrary

    init(provider: GitHubReleaseSourceProvider, library: ApplicationLibrary) {
        self.provider = provider
        self.library = library
        reloadFeeds()
    }

    func reloadFeeds() {
        let references = (try? provider.feeds()) ?? []
        feeds = references.map { FeedState(reference: $0) }
    }

    func addFeed() {
        addError = nil
        let text = addFieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard (try? provider.addFeed(ownerSlashName: text)) == true else {
            addError = "Enter a repository as owner/name, for example acme/launcher."
            return
        }
        addFieldText = ""
        reloadFeeds()
        if let index = feeds.indices.last {
            refresh(at: index)
        }
    }

    func removeFeed(at index: Int) {
        guard feeds.indices.contains(index) else { return }
        try? provider.removeFeed(feeds[index].reference)
        reloadFeeds()
    }

    func refresh(at index: Int) {
        guard feeds.indices.contains(index) else { return }
        feeds[index].isRefreshing = true
        feeds[index].errorMessage = nil
        let reference = feeds[index].reference
        Task {
            do {
                let snapshot = try await provider.load(reference)
                if let position = self.feeds.firstIndex(where: { $0.id == snapshot.reference.owner + "/" + snapshot.reference.repository }) {
                    self.feeds[position].snapshot = snapshot
                    self.feeds[position].isRefreshing = false
                }
                await self.recomputeUpdates()
            } catch {
                if let position = self.feeds.firstIndex(where: { $0.reference == reference }) {
                    self.feeds[position].errorMessage = "The feed could not be loaded."
                    self.feeds[position].isRefreshing = false
                }
            }
        }
    }

    func setTracking(bundleIdentifier: String?, for reference: ReleaseFeedReference) {
        try? provider.setTracking(bundleIdentifier: bundleIdentifier, for: reference)
        reloadFeeds()
        // Preserve loaded snapshots across the tracking change.
        Task { await recomputeUpdates() }
    }

    func refreshAll() {
        for index in feeds.indices {
            refresh(at: index)
        }
    }

    func recomputeUpdates() async {
        let entries: [LibraryEntry]
        do {
            entries = try await library.entries()
        } catch {
            updates = []
            return
        }
        let installed: [LibraryUpdateTracker.InstalledApp] = entries.compactMap { entry in
            guard let version = entry.record.identity.shortVersionString else { return nil }
            return LibraryUpdateTracker.InstalledApp(
                appName: entry.record.identity.displayName ?? entry.record.bundleIdentifier.rawValue,
                bundleIdentifier: entry.record.bundleIdentifier.rawValue,
                version: version
            )
        }
        var offers: [LibraryUpdateTracker.OfferedRelease] = []
        for feed in feeds {
            guard let snapshot = feed.snapshot else { continue }
            offers += LibraryUpdateTracker.offers(from: snapshot)
        }
        updates = LibraryUpdateTracker.availableUpdates(installed: installed, offers: offers)
    }

    /// Hands one release asset to the download queue.
    func download(_ asset: ReleaseFeedAsset, downloadCenter: DownloadCenter?) async {
        guard let downloadCenter else { return }
        _ = await downloadCenter.enqueueUserLink(asset.downloadURL.absoluteString)
    }
}

/// Repository release feeds: the releases public repositories publish, with
/// per-app update tracking against the library and hand-off to the download
/// queue.
///
/// A feed is a discovery channel. Nothing a feed says is trusted: a package
/// downloaded from one still passes the ordinary import boundary, and the
/// interface says so where it matters.
struct ReleaseFeedsView: View {
    @Environment(\.applicationEnvironment) private var environment
    @StateObject private var model: ReleaseFeedsModel
    @State private var trackingPickerFeed: ReleaseFeedReference?

    init(provider: GitHubReleaseSourceProvider, library: ApplicationLibrary) {
        _model = StateObject(wrappedValue: ReleaseFeedsModel(provider: provider, library: library))
    }

    var body: some View {
        List {
            updatesSection
            addSection
            ForEach(Array(model.feeds.enumerated()), id: \.element.id) { pair in
                feedSection(index: pair.offset, feed: pair.element)
            }
        }
        .navigationTitle("Release Feeds")
        .refreshable { model.refreshAll() }
        .sheet(item: $trackingPickerFeed) { reference in
            TrackingPickerSheet(reference: reference, model: model)
        }
    }

    private var updatesSection: some View {
        Section {
            if model.updates.isEmpty {
                Text("No updates detected. Track an application from a feed's menu to compare its version with the releases the feed lists.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(model.updates, id: \.bundleIdentifier) { update in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(update.appName).font(.headline)
                        Text("\(update.installedVersion) → \(update.availableVersion) · \(update.sourceName)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, ZSpacing.xxs)
                }
            }
        } header: {
            Text("Available Updates")
        }
    }

    private var addSection: some View {
        Section {
            HStack {
                TextField("owner/repository", text: $model.addFieldText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add") { model.addFeed() }
                    .disabled(model.addFieldText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error = model.addError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Add a Repository Feed")
        } footer: {
            Text("Feeds list releases a repository publishes. ZynSign does not verify feed content; imported packages are validated like any other import.")
        }
    }

    private func feedSection(index: Int, feed: ReleaseFeedsModel.FeedState) -> some View {
        Section {
            if feed.isRefreshing && feed.snapshot == nil {
                HStack { ProgressView(); Text("Loading releases…").font(.footnote).foregroundStyle(.secondary) }
            }
            if let message = feed.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
            if let snapshot = feed.snapshot {
                ForEach(snapshot.entries.prefix(5), id: \.tag) { entry in
                    releaseRow(entry: entry, feed: feed)
                }
                if snapshot.entries.count > 5 {
                    Text("… and \(snapshot.entries.count - 5) earlier releases.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            Button {
                trackingPickerFeed = feed.reference
            } label: {
                Label(
                    feed.reference.trackedBundleIdentifier.map { "Tracking: \($0)" } ?? "Track an App…",
                    systemImage: "scope"
                )
                .font(.callout)
            }
        } header: {
            HStack {
                Text("\(feed.reference.owner)/\(feed.reference.repository)")
                Spacer()
                Button {
                    model.refresh(at: index)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(feed.isRefreshing)
            }
        }
    }

    private func releaseRow(entry: ReleaseFeedEntry, feed: ReleaseFeedsModel.FeedState) -> some View {
        HStack(spacing: ZSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.callout).lineLimit(1)
                HStack(spacing: ZSpacing.xs) {
                    Text(entry.tag).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let date = entry.publishedAt {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    if entry.isPrerelease {
                        ZStatusBadge("Pre-release", systemImage: "flask", kind: .neutral)
                    }
                }
            }
            Spacer()
            if let asset = entry.packageAsset {
                Button {
                    Task { await model.download(asset, downloadCenter: environment.downloadCenter) }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Download \(entry.tag)")
            }
        }
        .padding(.vertical, ZSpacing.xxs)
    }
}

/// The sheet that chooses which library application a feed tracks.
private struct TrackingPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.applicationEnvironment) private var environment
    let reference: ReleaseFeedReference
    @ObservedObject var model: ReleaseFeedsModel
    @State private var entries: [LibraryEntry] = []

    var body: some View {
        NavigationStack {
            List {
                Button {
                    model.setTracking(bundleIdentifier: nil, for: reference)
                    dismiss()
                } label: {
                    Label("Do Not Track", systemImage: "slash.circle")
                }
                ForEach(entries, id: \.record.id) { entry in
                    Button {
                        model.setTracking(bundleIdentifier: entry.record.bundleIdentifier.rawValue, for: reference)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.record.identity.displayName ?? entry.record.bundleIdentifier.rawValue)
                                .foregroundStyle(reference.trackedBundleIdentifier == entry.record.bundleIdentifier.rawValue ? Color.accentColor : .primary)
                            Text(entry.record.bundleIdentifier.rawValue)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Track an App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            entries = (try? await environment.library.entries()) ?? []
        }
    }
}
