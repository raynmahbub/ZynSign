import SwiftUI

/// The Download Center.
///
/// Active, queued, paused, completed, and failed transfers live here, with
/// available updates from configured repositories. The screen owns no
/// transfers. `DownloadCenter` does, so leaving this tab does not cancel work.
struct DownloadsView: View {
    /// When this view is pushed into a navigation stack that already exists
    /// — Settings → Browse — it must not wrap itself in a second one.
    /// Nesting `NavigationStack` inside a pushed destination is a runtime
    /// crash, not a warning.
    var embedsNavigationStack: Bool = true

    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.downloadNavigation) private var navigation

    var body: some View {
        if let center = environment.downloadCenter {
            DownloadCenterScreen(
                center: center,
                directory: environment.repositoryDirectory,
                onOpenLibrary: navigation.openLibrary,
                onOpenSigningQueue: navigation.openSigningQueue,
                embedsNavigationStack: embedsNavigationStack
            )
        } else {
            ContentUnavailableView(
                "Downloads Unavailable",
                systemImage: "arrow.down.circle",
                description: Text("The Download Center is not installed in this build.")
            )
        }
    }
}

private struct DownloadCenterScreen: View {

    @ObservedObject var center: DownloadCenter
    var directory: RepositoryDirectory?
    var onOpenLibrary: () -> Void
    var onOpenSigningQueue: () -> Void
    /// Whether this view supplies its own navigation container. False when it
    /// is pushed into a stack the host already owns.
    var embedsNavigationStack: Bool = true

    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var searchText = ""
    @State private var showAdd = false
    @State private var urlText = ""
    @State private var linkMessage: String?
    @State private var storage = DownloadStorageReport.empty
    @State private var pendingBulk: BulkAction?
    @State private var notesCandidate: AppUpdateCandidate?
    @State private var milestoneTokens: [String: String] = [:]
    @State private var decisionPrompt: DownloadDuplicatePrompt?
    @State private var openedEntry: LibraryEntryLink?

    private var accessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        Group {
            if embedsNavigationStack {
                NavigationStack { centerScreen }
            } else {
                centerScreen
            }
        }
    }

    /// The Download Center's content, with no navigation container of its own.
    private var centerScreen: some View {
            List {
                if let store = environment.storeBrowser {
                    Section {
                        NavigationLink {
                            StoreDownloadsView(queue: store.downloads)
                        } label: {
                            Label("Store Download Jobs", systemImage: "bag")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                    } footer: {
                        Text("Store packages stay in isolated Store storage until you import them. They are separate from the downloads listed below.")
                    }
                }
                summary
                if !filteredUpdates.isEmpty { updatesSection }
                if !filtered(center.activeJobs).isEmpty { jobSection("Active Downloads", jobs: filtered(center.activeJobs), systemImage: "arrow.down.circle") }
                if !filtered(center.queuedJobs).isEmpty { jobSection("Queued", jobs: filtered(center.queuedJobs), systemImage: "clock") }
                if !filtered(center.pausedJobs).isEmpty { jobSection("Paused", jobs: filtered(center.pausedJobs), systemImage: "pause.circle") }
                if !filtered(center.completedJobs).isEmpty { jobSection("Completed", jobs: filtered(center.completedJobs), systemImage: "checkmark.circle") }
                if !filtered(center.failedJobs).isEmpty { jobSection("Failed", jobs: filtered(center.failedJobs), systemImage: "exclamationmark.circle") }
                if !filtered(center.cancelledJobs).isEmpty { jobSection("Cancelled", jobs: filtered(center.cancelledJobs), systemImage: "xmark.circle") }
                if center.jobs.isEmpty && center.updates.isEmpty && searchText.isEmpty { empty }
                historySection
                storageSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Downloads")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Apps and sources")
            .refreshable {
                await directory?.refresh()
                await center.refreshUpdates()
                storage = await center.storageReport()
            }
            .toolbar { toolbar }
            .confirmationDialog(
                pendingBulk?.title ?? "Downloads",
                isPresented: Binding(get: { pendingBulk != nil }, set: { if !$0 { pendingBulk = nil } }),
                titleVisibility: .visible
            ) {
                Button(pendingBulk?.title ?? "Continue", role: pendingBulk?.isDestructive == true ? .destructive : nil) {
                    perform(pendingBulk)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(pendingBulk?.message ?? "")
            }
            .confirmationDialog(
                "Already Held",
                isPresented: Binding(get: { decisionPrompt != nil }, set: { if !$0 { decisionPrompt = nil } }),
                titleVisibility: .visible
            ) {
                Button("Replace") { resolve(.replace) }
                Button("Keep Both") { resolve(.keepBoth) }
                Button("Skip", role: .cancel) { resolve(.skip) }
            } message: {
                Text(decisionPrompt?.explanation ?? "")
            }
            .alert("Add Download", isPresented: $showAdd) {
                TextField("https://example.com/app.ipa", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Cancel", role: .cancel) { urlText = "" }
                Button("Download") {
                    let raw = urlText
                    urlText = ""
                    Task { await addLink(raw) }
                }
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            } message: {
                Text("https addresses only. An install manifest is read for an https package address and is not imported as an app. Resume depends on the server and is never assumed.")
            }
            .alert("Download", isPresented: Binding(get: { linkMessage != nil }, set: { if !$0 { linkMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(linkMessage ?? "")
            }
            .sheet(item: $notesCandidate) { candidate in
                ReleaseNotesSheet(candidate: candidate, center: center)
            }
            .sheet(item: $openedEntry) { link in
                NavigationStack {
                    ApplicationDetailView(
                        entry: link.entry,
                        bundleInspection: environment.bundleInspection,
                        detailsInspection: environment.applicationDetailsInspection
                    )
                }
            }
            .navigationDestination(for: DownloadJobIdentifier.self) { id in
                DownloadDetailView(
                    center: center,
                    jobID: id,
                    onOpenLibrary: onOpenLibrary,
                    onOpenSigningQueue: onOpenSigningQueue
                )
            }
        .task {
            center.startObservingTransfers()
            await center.restore()
            directory?.load()
            await center.refreshUpdates()
            storage = await center.storageReport()
        }
        .onChange(of: center.pendingDecisions.count) { _, _ in
            decisionPrompt = center.pendingDecisions.first
        }
        .onChange(of: center.jobs.map(DownloadCenterRendering.milestoneToken(for:))) { _, _ in
            announceMilestones()
        }
    }

    private var summary: some View {
        Section {
            HStack {
                stat("Active", center.activeJobs.count)
                stat("Queued", center.queuedJobs.count)
                stat("Failed", center.failedJobs.count)
                stat("Updates", center.updates.count)
            }
            .accessibilityElement(children: .combine)
        } footer: {
            Text("Files stay in the Download Center until they pass validation. A configured source is not enough to import them.")
        }
    }

    private var updatesSection: some View {
        Section {
            if !filteredUpdates.isEmpty {
                Button {
                    Task { await updateAll() }
                } label: {
                    Label("Update All", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .keyboardShortcut("u", modifiers: .command)
                .accessibilityHint("Queues updates from configured repositories. Collisions ask before anything is replaced.")
            }
            ForEach(filteredUpdates) { candidate in
                updateRow(candidate)
            }
        } header: {
            Label("Available Updates", systemImage: "arrow.triangle.2.circlepath")
        } footer: {
            Text("Installed and latest versions from configured repositories only. Ignored versions stay hidden until a newer one is published.")
        }
    }

    private func updateRow(_ candidate: AppUpdateCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.name).font(.headline)
                    Text(candidate.sourceName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Update") {
                    Task { await update(candidate) }
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
            }
            HStack {
                labeledColumn("Installed", candidate.installedVersion ?? "—")
                labeledColumn("Latest", candidate.latestVersion)
            }
            HStack {
                Button("View Changes") { notesCandidate = candidate }
                    .frame(minHeight: 44)
                Button("Ignore Version") { center.ignore(candidate) }
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .font(.subheadline)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(candidate.name), installed \(candidate.installedVersion ?? "unknown"), latest \(candidate.latestVersion), \(candidate.sourceName)")
        .accessibilityHint("Update downloads the latest version. Ignore hides this version.")
    }

    private func jobSection(_ title: String, jobs: [DownloadCenter.Job], systemImage: String) -> some View {
        Section {
            ForEach(jobs) { job in
                NavigationLink(value: job.id) {
                    DownloadJobCard(job: job, stacksVertically: accessibilitySize)
                }
                .accessibilityHint("Opens download details")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if job.isPaused {
                        Button { center.resume(job.id) } label: { Label("Resume", systemImage: "play.fill") }.tint(.green)
                    } else if job.state == .downloading || job.state == .connecting {
                        Button { center.pause(job.id) } label: { Label("Pause", systemImage: "pause") }.tint(.orange)
                    }
                    if job.isQueued || job.isTransferring || job.isPaused {
                        Button(role: .destructive) { center.cancel(job.id) } label: { Label("Cancel", systemImage: "xmark") }
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    if job.isQueued {
                        Button { center.sendToTop(job.id) } label: { Label("Top", systemImage: "arrow.up.to.line") }.tint(.blue)
                    }
                    if job.isRetryable {
                        Button { center.retry(job.id) } label: { Label("Retry", systemImage: "arrow.clockwise") }.tint(.blue)
                    }
                }
                .contextMenu {
                    if job.isQueued {
                        Button { center.move(job.id, up: true) } label: { Label("Move Up", systemImage: "arrow.up") }
                        Button { center.move(job.id, up: false) } label: { Label("Move Down", systemImage: "arrow.down") }
                        Button { center.sendToTop(job.id) } label: { Label("Send to Top", systemImage: "arrow.up.to.line") }
                        Menu("Priority") {
                            ForEach(DownloadJobPriority.allCases, id: \.self) { priority in
                                Button(priority.displayName) { center.setPriority(priority, on: job.id) }
                            }
                        }
                    }
                    Button(role: .destructive) { center.removeDownload(job.id) } label: { Label("Remove Download", systemImage: "trash") }
                }
            }
        } header: {
            Label(title, systemImage: systemImage)
        }
    }

    private var historySection: some View {
        Section {
            if center.history.isEmpty {
                Text("Completed and rejected downloads are listed here with their validation result.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filteredHistory) { entry in
                    historyRow(entry)
                }
            }
        } header: {
            Label("History", systemImage: "clock.arrow.circlepath")
        }
    }

    private var storageSection: some View {
        Section {
            storageRow("Downloaded IPAs", DownloadCenterRendering.bytes(storage.downloadedIPABytes))
            storageRow("Completed Downloads", "\(storage.completedDownloadCount) · \(DownloadCenterRendering.bytes(storage.completedRetainedBytes))")
            storageRow("Temporary Data", DownloadCenterRendering.bytes(storage.temporaryBytes))
            storageRow("Total", DownloadCenterRendering.bytes(storage.totalBytes))
            Button(role: .destructive) { pendingBulk = .clearCompleted } label: {
                Label("Clear Completed", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .disabled(center.completedJobs.isEmpty)
            Button(role: .destructive) {
                Task {
                    _ = await center.clearTemporaryData()
                    storage = await center.storageReport()
                }
            } label: {
                Label("Clear Temporary Data", systemImage: "trash")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityHint("Removes partials and isolated rejects. Imported apps and validated packages are kept.")
        } header: {
            Label("Storage", systemImage: "internaldrive")
        } footer: {
            Text("Completed download size is included in Downloaded IPAs, not added again. These actions never delete imported apps.")
        }
    }

    private var empty: some View {
        Section {
            ZEmptyState.noDownloads {
                showAdd = true
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showAdd = true } label: { Label("Add", systemImage: "plus") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .accessibilityLabel("Add download")
        }
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button { pendingBulk = .cancelWaiting } label: { Label("Cancel Waiting", systemImage: "xmark.circle") }
                    .disabled(center.queuedJobs.isEmpty)
                Button { center.retryAllFailed() } label: { Label("Retry Failed", systemImage: "arrow.clockwise") }
                    .disabled(center.failedJobs.isEmpty)
                Button { pendingBulk = .clearCompleted } label: { Label("Clear Completed", systemImage: "checkmark.circle") }
                    .disabled(center.completedJobs.isEmpty)
                if let notifier = environment.downloadNotifier as? LocalDownloadNotifier, notifier.isSupported {
                    DownloadNotificationToggle(notifier: notifier)
                }
            } label: {
                Label("Download Actions", systemImage: "ellipsis.circle")
            }
            .accessibilityLabel("Download actions")
        }
    }

    private var filteredUpdates: [AppUpdateCandidate] {
        guard !searchText.isEmpty else { return center.updates }
        return center.updates.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.sourceName.localizedCaseInsensitiveContains(searchText)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredHistory: [DownloadHistoryEntry] {
        guard !searchText.isEmpty else { return center.history }
        return center.history.filter {
            $0.appName.localizedCaseInsensitiveContains(searchText) || $0.sourceName.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func filtered(_ jobs: [DownloadCenter.Job]) -> [DownloadCenter.Job] {
        guard !searchText.isEmpty else { return jobs }
        return jobs.filter {
            $0.request.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.request.sourceName.localizedCaseInsensitiveContains(searchText)
                || ($0.request.bundleIdentifier?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    /// One row of the download history: what it was, when it finished, and
    /// how its validation ended.
    private func historyRow(_ entry: DownloadHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.appName).font(.body)
            Text([entry.version, entry.sourceName].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(entry.completedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(entry.validationSummary)
                .font(.footnote)
                .foregroundStyle(entry.validationPassed ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            if entry.validationPassed {
                Button("Open App") { Task { await openHistory(entry) } }
                    .frame(minHeight: 44)
                    .accessibilityHint("Opens the imported app when it is in the Library. Does not delete it.")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func stat(_ title: String, _ count: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(count)").font(.headline).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }

    private func labeledColumn(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func storageRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func openHistory(_ entry: DownloadHistoryEntry) async {
        guard let bundle = entry.bundleIdentifier,
              let entries = try? await environment.library.entries(),
              let match = entries.first(where: { $0.record.bundleIdentifier.rawValue == bundle }) else {
            onOpenLibrary()
            return
        }
        openedEntry = LibraryEntryLink(entry: match)
    }

    private func addLink(_ raw: String) async {
        switch await center.enqueueUserLink(raw) {
        case .queued:
            linkMessage = "Queued. It will be validated before it can be imported."
        case .needsDecision:
            decisionPrompt = center.pendingDecisions.first
        case let .rejected(message):
            linkMessage = message
        case .skipped:
            break
        }
    }

    private func update(_ candidate: AppUpdateCandidate) async {
        switch await center.update(candidate) {
        case .queued:
            break
        case .needsDecision:
            decisionPrompt = center.pendingDecisions.first
        case let .rejected(message):
            linkMessage = message
        case .skipped:
            break
        }
    }

    private func updateAll() async {
        let result = await center.updateAll()
        if result.needsDecision > 0 {
            linkMessage = "\(result.queued) queued. \(result.needsDecision) need a decision before they can download. Nothing was overwritten."
            decisionPrompt = center.pendingDecisions.first
        }
    }

    private func resolve(_ choice: DownloadDuplicateChoice) {
        guard let prompt = decisionPrompt else { return }
        decisionPrompt = nil
        Task {
            _ = await center.resolveDuplicate(prompt.id, choice: choice)
            storage = await center.storageReport()
        }
    }

    private func perform(_ action: BulkAction?) {
        switch action {
        case .cancelWaiting: center.cancelAllWaiting()
        case .clearCompleted:
            center.clearCompleted()
            Task { storage = await center.storageReport() }
        case nil: break
        }
    }

    private func announceMilestones() {
        for job in center.jobs {
            let previous = milestoneTokens[job.id.rawValue]
            if let speech = DownloadCenterRendering.milestoneAnnouncement(previous: previous, current: job) {
                AccessibilityNotification.Announcement(speech).post()
            }
            milestoneTokens[job.id.rawValue] = DownloadCenterRendering.milestoneToken(for: job)
        }
    }

    private enum BulkAction: Identifiable {
        case cancelWaiting
        case clearCompleted
        var id: String { title }
        var title: String {
            switch self {
            case .cancelWaiting: return "Cancel Waiting"
            case .clearCompleted: return "Clear Completed"
            }
        }
        var isDestructive: Bool { true }
        var message: String {
            switch self {
            case .cancelWaiting:
                return "Waiting downloads will be cancelled. A transfer that has started is left alone until you cancel it. Imported apps are not touched."
            case .clearCompleted:
                return "Completed downloads will be removed from the Download Center, including their files. Imported apps in the Library are not deleted."
            }
        }
    }
}

private struct DownloadJobCard: View {
    let job: DownloadCenter.Job
    var stacksVertically: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.request.displayName).font(.headline).lineLimit(stacksVertically ? nil : 1)
                    Text(job.request.sourceName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Text(job.statusText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                ZStatusBadge(job.priority.displayName, systemImage: job.priority.symbolName, kind: job.priority == .high ? .info : .neutral)
            }
            if let fraction = job.progress.fraction {
                ProgressView(value: fraction)
            } else if job.isTransferring {
                ProgressView()
            }
            ViewThatFits(in: .horizontal) {
                HStack { metrics }
                VStack(alignment: .leading, spacing: 2) { metrics }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DownloadCenterRendering.cardLabel(for: job))
        .accessibilityValue(DownloadCenterRendering.progressValue(for: job))
    }

    @ViewBuilder
    private var metrics: some View {
        Text(job.stage.displayName)
        if let fraction = job.progress.fraction {
            Text("\(Int((fraction * 100).rounded()))%")
        }
        Text(DownloadCenterRendering.speed(job.progress.bytesPerSecond))
        Text(DownloadCenterRendering.remainingText(for: job))
    }

    private var icon: some View {
        AsyncImage(url: job.request.iconURL) { phase in
            switch phase {
            case let .success(image): image.resizable().scaledToFill()
            default: Image(systemName: "app.fill").foregroundStyle(.secondary)
            }
        }
        .frame(width: 48, height: 48)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: ZRadius.appIcon(side: 48), style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct ReleaseNotesSheet: View {
    let candidate: AppUpdateCandidate
    @ObservedObject var center: DownloadCenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("What's New") {
                    if let notes = candidate.releaseNotes {
                        Text(notes).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("This source did not include release notes.").foregroundStyle(.secondary)
                    }
                }
                Section("Release") {
                    labeled("Version", candidate.latestVersion)
                    labeled("Release date", candidate.releaseDate ?? "Not declared")
                    labeled("Source", candidate.sourceName)
                    labeled("Installed", candidate.installedVersion ?? "Unknown")
                }
                Section("Version History") {
                    if candidate.versionHistory.isEmpty {
                        Text("No earlier versions were listed.").foregroundStyle(.secondary)
                    }
                    ForEach(candidate.versionHistory) { note in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.version).font(.headline)
                            if let date = note.date { Text(date).font(.caption).foregroundStyle(.secondary) }
                            if let notes = note.notes { Text(notes).font(.subheadline).fixedSize(horizontal: false, vertical: true) }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle(candidate.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Update") {
                        Task { _ = await center.update(candidate) }
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DownloadNotificationToggle: View {
    @ObservedObject var notifier: LocalDownloadNotifier

    var body: some View {
        Toggle(isOn: $notifier.isEnabled) {
            Label("Notify When Downloads Finish", systemImage: "bell")
        }
        .accessibilityHint("Off by default. Turning it on asks the system for permission. In-app notices stay on either way.")
    }
}

private struct DownloadNavigationKey: EnvironmentKey {
    static let defaultValue = DownloadNavigation.inactive
}

extension EnvironmentValues {
    var downloadNavigation: DownloadNavigation {
        get { self[DownloadNavigationKey.self] }
        set { self[DownloadNavigationKey.self] = newValue }
    }
}
