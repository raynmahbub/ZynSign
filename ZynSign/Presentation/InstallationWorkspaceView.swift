import SwiftUI

/// The Installation Workspace — ZynSign's hub for everything between
/// "signed" and "on the device".
///
/// The screen shows what ZynSign established — signing, verification,
/// package, export, identity, metadata — and what the user confirmed. It
/// never shows what the platform decided, because ZynSign cannot see the
/// platform's decision; the honesty line on every screen says so in the
/// interface's own words.
///
/// The dashboard is deliberately a *workspace*, not a button: readiness
/// cards per signed app, a pre-install checklist per app, the Installed
/// Apps Library, the history, and the bulk preparation queue, each in its
/// own section and each reachable from here.
struct InstallationWorkspaceView: View {

    /// When this view is pushed into a navigation stack the host already
    /// owns — Settings → Browse — it must not wrap itself in a second one.
    /// Nesting `NavigationStack` inside a pushed destination crashes at
    /// runtime, not with a warning.
    var embedsNavigationStack: Bool = true

    /// The workspace use case. `nil` in compositions without the feature;
    /// the screen then reports itself unavailable rather than showing an
    /// empty dashboard that could be mistaken for "nothing installed".
    private let workspace: InstallationWorkspace?
    private let storage: StorageManagement?

    @StateObject private var model: InstallationWorkspaceModel

    /// Which checklist sheet is open, by the candidate it belongs to.
    @State private var checklistCandidate: InstallationWorkspaceModel.CandidateRow?

    /// The hand-off sheet shown after a channel is chosen.
    private struct HandoffSheet: Identifiable {
        let package: InstallationDeliveryPackage
        var id: String { UUID().uuidString }
    }

    /// Which hand-off sheet is open, when a channel just produced a package.
    @State private var handoffSheet: HandoffSheet?

    // The model's notices surface here as toasts: the model writes a
    // Notice, `onChange` bridges it into the toast's presentation state,
    // and dismissal clears the Notice.
    @State private var isShowingToast = false
    @State private var toastMessage = ""
    @State private var toastStyle: ZToast.Style = .info

    /// The attempt awaiting channel confirmation before its hand-off.
    @State private var deliveryTarget: DeliveryTarget?

    /// Whether the after-the-fact recording sheet is open.
    @State private var recordingCandidate: InstallationWorkspaceModel.CandidateRow?

    /// Whether the storage actions are running.
    @State private var isCleaningStorage = false

    struct DeliveryTarget: Identifiable {
        let candidate: InstallationWorkspaceModel.CandidateRow
        let attempt: PendingInstallationAttempt
        var id: String { attempt.id.rawValue }
    }

    init(
        workspace: InstallationWorkspace?,
        storage: StorageManagement? = nil,
        embedsNavigationStack: Bool = true
    ) {
        self.workspace = workspace
        self.storage = storage
        self.embedsNavigationStack = embedsNavigationStack
        _model = StateObject(wrappedValue: InstallationWorkspaceModel(
            workspace: workspace,
            storage: storage
        ))
    }

    var body: some View {
        Group {
            if embedsNavigationStack {
                NavigationStack { contentChain }
            } else {
                contentChain
            }
        }
        .task { await model.load() }
        .sheet(item: $checklistCandidate) { row in
            InstallationChecklistSheet(
                model: model,
                row: row,
                onDeliver: { startDelivery(row, intent: .installed) },
                onRecord: { recordingCandidate = row }
            )
        }
        .sheet(item: $deliveryTarget) { target in
            DeliveryChannelSheet(model: model, target: target) { package in
                deliveryTarget = nil
                handoffSheet = HandoffSheet(package: package)
            }
        }
        .sheet(item: $handoffSheet) { sheet in
            NavigationStack {
                InstallationDeliveryView(package: sheet.package)
            }
        }
        .sheet(item: $recordingCandidate) { row in
            RecordAfterTheFactSheet(model: model, row: row)
        }
        .zToast(
            isPresented: $isShowingToast,
            message: toastMessage,
            style: toastStyle,
            duration: .seconds(4)
        )
        .onChange(of: model.notice) { _, notice in
            guard let notice else { return }
            toastMessage = "\(notice.title) — \(notice.message)"
            toastStyle = notice.isError ? .error : .success
            withAnimation(ZMotion.interactive) {
                isShowingToast = true
            }
        }
        .onChange(of: isShowingToast) { _, isShowing in
            guard !isShowing else { return }
            model.notice = nil
        }
    }

    /// The workspace's content, with no navigation container of its own, so
    /// this view can be pushed into a stack the host already owns.
    private var contentChain: some View {
            content
                .navigationTitle("Install")
                .toolbar { toolbar }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            VStack(spacing: ZSpacing.md) {
                ZSkeleton(rows: 1)
                ZSkeleton(rows: 3)
                ZSkeleton(rows: 2)
            }
            .padding(.horizontal, ZSpacing.md)
        case .failed(let message):
            VStack(spacing: ZSpacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Installation Workspace unavailable").font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        case .ready:
            dashboard
        }
    }

    // MARK: - Dashboard

    private var dashboard: some View {
        List {
            summarySection
            attemptsSection
            preparationSection
            readySection
            attentionSection
            installedSection
            updatesSection
            recentSection
            historySection
            storageSection
            honestySection
        }
        .listStyle(.insetGrouped)
        .accessibilityElement(children: .contain)
    }

    /// The dashboard's headline counts, as spec'd: Ready to Install,
    /// Installed, Updates Available.
    private var summarySection: some View {
        Section {
            HStack(spacing: ZSpacing.sm) {
                DashboardCountTile(
                    title: "Ready to Install",
                    value: "\(model.counts.readyToInstall)",
                    detail: "of \(model.counts.signed) signed",
                    symbol: "checkmark.seal.fill",
                    color: .green
                )
                DashboardCountTile(
                    title: "Installed",
                    value: "\(model.counts.installed)",
                    detail: "recorded by you",
                    symbol: "arrow.down.app.fill",
                    color: .blue
                )
                DashboardCountTile(
                    title: "Updates",
                    value: "\(model.counts.updatesAvailable)",
                    detail: "newer signed output",
                    symbol: "arrow.triangle.2.circlepath",
                    color: .orange
                )
            }
            .padding(.vertical, ZSpacing.xxs)
        } header: {
            Text("Installation Workspace")
        } footer: {
            Text("ZynSign validates on its own authority and records what you confirm. Whether the platform accepts a delivery is the platform's decision.")
        }
    }

    // MARK: - Pending attempts

    @ViewBuilder
    private var attemptsSection: some View {
        if !model.attempts.isEmpty {
            Section {
                ForEach(model.attempts) { attempt in
                    PendingAttemptRow(
                        attempt: attempt,
                        onDeliver: {
                            Task {
                                if let package = await model.deliveryPackage(for: attempt) {
                                    handoffSheet = HandoffSheet(package: package)
                                }
                            }
                        },
                        onConfirm: { Task { await model.confirm(attempt: attempt) } },
                        onAbandon: { Task { await model.abandon(attempt: attempt) } }
                    )
                }
            } header: {
                Text("Deliveries Awaiting Confirmation")
            } footer: {
                Text("These attempts stay open — across relaunches — until you say what happened. ZynSign never resolves one by itself and never records an interrupted delivery as installed.")
            }
        }
    }

    // MARK: - Preparation queue

    @ViewBuilder
    private var preparationSection: some View {
        if !model.preparationQueue.jobs.isEmpty {
            Section {
                ForEach(model.preparationQueue.jobs) { job in
                    PreparationJobRow(job: job) {
                        model.preparationQueue.cancel(job.id)
                    } onRetry: {
                        model.preparationQueue.retry(job.id)
                    }
                }
                if model.preparationQueue.failedCount > 0 {
                    Button {
                        ZHaptics.tap()
                        model.retryFailedPreparations()
                    } label: {
                        Label("Retry Failed (\(model.preparationQueue.failedCount))", systemImage: "arrow.clockwise")
                    }
                }
                if model.preparationQueue.completedCount > 0 {
                    Button(role: .destructive) {
                        ZHaptics.tap()
                        model.clearCompletedPreparations()
                    } label: {
                        Label("Clear Completed (\(model.preparationQueue.completedCount))", systemImage: "tray.full")
                    }
                }
            } header: {
                Text("Preparation Queue")
            } footer: {
                Text("Preparation re-checks readiness and re-verifies artifacts. It never signs, never delivers, and never records an installation.")
            }
        }
    }

    // MARK: - Ready to install

    @ViewBuilder
    private var readySection: some View {
        Section {
            if model.readyCandidateRows.isEmpty {
                Text(model.counts.signed == 0
                     ? "No signed applications yet. Sign an app in the Library to prepare it here."
                     : "No signed application has a clear readiness report yet. Open a card below to see what is missing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.readyCandidateRows) { row in
                    InstallationReadinessCard(
                        row: row,
                        onOpenChecklist: { checklistCandidate = row },
                        onDeliver: { startDelivery(row, intent: .installed) },
                        onVerify: { Task { await model.verifyAgain(row) } }
                    )
                }
            }
        } header: {
            Text("Ready to Install")
        } footer: {
            Text("“Ready” is ZynSign's own verdict — the checks ZynSign ran all passed. Delivery remains your step.")
        }
    }

    // MARK: - Needs attention

    @ViewBuilder
    private var attentionSection: some View {
        if !model.blockedCandidateRows.isEmpty {
            Section {
                ForEach(model.blockedCandidateRows) { row in
                    InstallationReadinessCard(
                        row: row,
                        onOpenChecklist: { checklistCandidate = row },
                        onDeliver: nil,
                        onVerify: {
                            Task { await model.verifyAgain(row) }
                        }
                    )
                }
            } header: {
                Text("Needs Attention")
            } footer: {
                Text("These applications are signed, but at least one readiness check is blocked. The checklist names what to resolve.")
            }
        }
    }

    // MARK: - Installed

    @ViewBuilder
    private var installedSection: some View {
        Section {
            if model.installedRows.isEmpty {
                Text("Nothing is recorded as installed yet. After a delivery, confirm the attempt here — or record an installation after the fact.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.visibleInstalledRows.prefix(3))) { row in
                    InstalledAppRow(row: row)
                }
                NavigationLink {
                    InstalledAppsLibraryView(model: model)
                } label: {
                    Label(
                        model.installedRows.count > 3
                            ? "Open Installed Apps Library (\(model.installedRows.count))"
                            : "Open Installed Apps Library",
                        systemImage: "square.grid.2x2"
                    )
                }
            }
        } header: {
            Text("Installed")
        } footer: {
            Text("A record exists because you confirmed a delivery or recorded one afterwards. ZynSign cannot see a device's app list.")
        }
    }

    // MARK: - Updates

    @ViewBuilder
    private var updatesSection: some View {
        if !model.installedRows.isEmpty {
            let updateRows = model.visibleInstalledRows.filter { $0.updateState.offersUpdate }
            Section {
                if updateRows.isEmpty {
                    Text("No newer signed output than what is recorded as installed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(updateRows) { row in
                        InstalledAppRow(row: row)
                    }
                }
            } header: {
                Text("Updates Available")
            } footer: {
                Text("ZynSign compares declared versions of what it holds. “Update” delivers the newer signed output; the device decides whether to accept it.")
            }
        }
    }

    // MARK: - Recent installs

    @ViewBuilder
    private var recentSection: some View {
        if !model.recentInstalls.isEmpty {
            Section {
                ForEach(model.recentInstalls) { entry in
                    NavigationLink {
                        InstallationHistoryEntryDetail(entry: entry)
                    } label: {
                        HistoryEntryRow(entry: entry)
                    }
                }
            } header: {
                Text("Recent Installs")
            }
        }
    }

    // MARK: - History

    private var historySection: some View {
        Section {
            if model.historyEntries.isEmpty {
                Text("The installation history is empty. Confirmed deliveries and recorded installations appear here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                NavigationLink {
                    InstallationHistoryView(model: model)
                } label: {
                    Label("Open Installation History (\(model.historyEntries.count)\(model.showsAllHistory ? "" : "+"))", systemImage: "clock.arrow.circlepath")
                }
            }
        } header: {
            Text("Installation History")
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section {
            StorageByteRow(
                label: "Installed Records",
                bytes: model.storageSummary.installedRecordsBytes,
                note: "ZynSign's own records — safe to clear"
            )
            StorageByteRow(
                label: "Signed IPAs",
                bytes: model.storageSummary.exportedArtifactsBytes,
                note: "Exported artifacts, in Documents/Signed"
            )
            StorageByteRow(
                label: "Temporary Data",
                bytes: model.storageSummary.temporaryBytes,
                note: "Staging and working copies"
            )
            if let temporary = model.storageSummary.temporaryBytes, temporary > 0 {
                Button {
                    Task { await cleanStorage(.temporaryFiles) }
                } label: {
                    Label("Remove Temporary Files", systemImage: "trash")
                }
                .disabled(isCleaningStorage)
            }
            if let exported = model.storageSummary.exportedArtifactsBytes, exported > 0 {
                Button(role: .destructive) {
                    Task { await cleanStorage(.exportedArtifacts) }
                } label: {
                    Label("Remove Exported Artifacts…", systemImage: "trash")
                }
                .disabled(isCleaningStorage)
            }
            if !model.installedRows.isEmpty {
                Button(role: .destructive) {
                    Task { await model.clearAllInstalledRecords() }
                } label: {
                    Label("Clear Installed Records…", systemImage: "eraser")
                }
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Cleanup never touches imported applications. Removing exported artifacts deletes the signed output — the library's source packages stay.")
                .textCase(nil)
        }
    }

    private func cleanStorage(_ kind: StorageCleanupKind) async {
        guard let storage = storage else { return }
        isCleaningStorage = true
        defer { isCleaningStorage = false }
        do {
            let report = try await storage.cleanup(kind)
            model.notice = InstallationWorkspaceModel.Notice(
                title: "Cleanup complete",
                message: report.summary
            )
            await model.load()
        } catch {
            model.notice = InstallationWorkspaceModel.Notice(
                title: "Cleanup unavailable",
                message: (error as? ZynSignError)?.userMessage ?? "The cleanup could not run."
            )
        }
    }

    // MARK: - Honesty

    private var honestySection: some View {
        Section {
            HStack(spacing: ZSpacing.sm) {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(.secondary)
                Text("ZynSign does not install. It validates, prepares, and records what you confirm — the delivery itself is yours, through your channel.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button {
                    ZHaptics.tap()
                    model.verifyAll()
                } label: {
                    Label("Verify All", systemImage: "checkmark.seal")
                }
                Button {
                    ZHaptics.tap()
                    model.prepareAll()
                } label: {
                    Label("Prepare All", systemImage: "wrench.and.screwdriver")
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                if model.preparationQueue.failedCount > 0 {
                    Button {
                        model.retryFailedPreparations()
                    } label: {
                        Label("Retry Failed", systemImage: "arrow.clockwise")
                    }
                }
                if model.preparationQueue.completedCount > 0 {
                    Button {
                        model.clearCompletedPreparations()
                    } label: {
                        Label("Clear Completed", systemImage: "tray.full")
                    }
                }
            } label: {
                Label("Bulk", systemImage: "square.stack.3d.up")
            }
            .accessibilityLabel("Bulk preparation actions")

            Button {
                ZHaptics.tap()
                Task { await model.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Refresh")
        }
    }

    // MARK: - Delivery

    /// Opens the delivery flow for a candidate: readiness is checked
    /// again, the attempt is started, and the channel sheet follows.
    private func startDelivery(_ row: InstallationWorkspaceModel.CandidateRow, intent: InstallationEventKind) {
        Task {
            if let attempt = await model.startDelivery(row, intent: intent, channel: .otaLink) {
                deliveryTarget = DeliveryTarget(candidate: row, attempt: attempt)
            } else {
                model.notice = InstallationWorkspaceModel.Notice(
                    title: "Not ready to deliver",
                    message: "The readiness checks must pass before delivery. Open the checklist to see what is blocking."
                )
            }
        }
    }
}

/// A pending attempt waiting to be handed to the delivery hand-off.
private struct PendingAttemptRow: View {
    let attempt: PendingInstallationAttempt
    let onDeliver: () -> Void
    let onConfirm: () -> Void
    let onAbandon: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            HStack(spacing: ZSpacing.xs) {
                ZStatusBadge(attempt.intent.displayName, systemImage: "arrow.down.app", kind: .info)
                ZStatusBadge(attempt.channel.displayName, systemImage: "point.3.connected.trianglepath.dotted", kind: .neutral)
                Spacer()
            }
            Text(attempt.displayOrIdentifier).font(.headline)
            Text(attempt.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: ZSpacing.sm) {
                Button("Deliver Now", action: onDeliver)
                    .buttonStyle(.bordered)
                Button("Mark Installed", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                Button("Not Installed", action: onAbandon)
                    .buttonStyle(.bordered)
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
        }
        .padding(.vertical, ZSpacing.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(attempt.summary) Actions: Deliver Now, Mark Installed, Not Installed.")
    }
}

/// One preparation-queue job.
private struct PreparationJobRow: View {
    let job: InstallationPreparationQueue.Job
    let onCancel: () -> Void
    let onRetry: () -> Void

    private var badgeKind: ZStatusBadge.Kind {
        switch job.state {
        case .queued, .running: return .info
        case .completed: return .success
        case .failed: return .error
        case .cancelled: return .neutral
        }
    }

    private var stateText: String {
        switch job.state {
        case .queued: return "Waiting"
        case .running: return "Preparing"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xxs) {
            HStack(spacing: ZSpacing.xs) {
                Text(job.applicationName).font(.subheadline.weight(.medium))
                Spacer()
                ZStatusBadge(stateText, systemImage: stateSymbol, kind: badgeKind)
            }
            Text(job.kind.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let outcome = job.outcomeSummary {
                Text(outcome)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if job.state == .running {
                ProgressView()
                    .controlSize(.small)
            }
            if job.state.isRetryable {
                Button("Retry", action: onRetry).font(.caption)
            }
            if job.state == .running || job.state == .queued {
                Button("Cancel", action: onCancel).font(.caption)
            }
        }
        .padding(.vertical, ZSpacing.xxs)
        .accessibilityElement(children: .combine)
    }

    private var stateSymbol: String {
        switch job.state {
        case .queued: return "clock"
        case .running: return "gearshape.2"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "slash.circle"
        }
    }
}

/// The dashboard's headline tile.
private struct DashboardCountTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xxs) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.body)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption.weight(.medium))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(title). \(detail).")
    }
}

/// A byte-count row in the storage table.
struct StorageByteRow: View {
    let label: String
    let bytes: Int?
    let note: String

    var body: some View {
        LabeledContent {
            Text(bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A history entry row, shared by the dashboard and the history screen.
struct HistoryEntryRow: View {
    let entry: InstallationHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xxs) {
            HStack(spacing: ZSpacing.xs) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .font(.subheadline)
                    .accessibilityHidden(true)
                Text(entry.appName)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(InstallationPresentation.timestamp(entry.event.at))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text("\(entry.event.kind.displayName) · \(entry.event.versionDisplay) · via \(entry.event.channel.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.appName) \(entry.event.kind.displayName.lowercased()), \(entry.event.versionDisplay), \(InstallationPresentation.timestamp(entry.event.at)).")
    }

    private var symbol: String {
        switch entry.event.kind {
        case .installed: return "arrow.down.app.fill"
        case .updated: return "arrow.triangle.2.circlepath"
        case .reinstalled: return "arrow.counterclockwise.circle.fill"
        }
    }

    private var tint: Color {
        switch entry.event.kind {
        case .installed: return .blue
        case .updated: return .orange
        case .reinstalled: return .purple
        }
    }
}
