import SwiftUI

/// The signing queue dashboard: every job ZynSign is signing, is about to
/// sign, or has finished signing, in one screen.
///
/// The dashboard is a window into `SigningQueue` — it owns no work and no
/// state of its own beyond which bulk action is awaiting confirmation. It
/// shows the running job with its live stage list, the waiting jobs in the
/// order they will run with the controls that reorder them, and the settled
/// jobs with the actions that are honest for each: retry a failure the
/// evidence says can end differently, remove what has finished, and never
/// anything that pretends a control exists when the machine cannot back it
/// (there is no pause: the pipeline has no safe checkpoint to pause at).
///
/// The queue itself lives in the application environment, so leaving this
/// screen interrupts nothing — which is the entire point of a queue.
struct SigningQueueView: View {

    /// The queue this screen shows, observed directly: its state is the
    /// state the screen renders, so there is nothing to mirror.
    @ObservedObject var queue: SigningQueue

    /// Opens the Library tab, so jobs can be added where the applications
    /// are listed. Provided by whichever screen presents the dashboard.
    var onOpenLibrary: () -> Void = {}

    /// Closes the area, when it is presented as a sheet.
    var onDone: (() -> Void)? = nil

    @Environment(\.applicationEnvironment) private var env

    /// The bulk action awaiting the user's confirmation, when one is.
    @State private var pendingBulkAction: BulkAction?

    /// One destructive-or-not bulk operation the toolbar menu offers.
    enum BulkAction: String, Identifiable {
        case cancelAllWaiting
        case retryAllFailed
        case clearCompleted
        case clearFailed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .cancelAllWaiting: return "Cancel All Waiting"
            case .retryAllFailed: return "Retry All Failed"
            case .clearCompleted: return "Clear Completed"
            case .clearFailed: return "Clear Failed"
            }
        }

        /// Whether the action needs a confirmation before it runs.
        /// Cancelling waiting work and removing settled jobs from the list
        /// are destructive to the user's plan; retrying failed jobs only
        /// starts clean runs the user asked for.
        var requiresConfirmation: Bool {
            switch self {
            case .cancelAllWaiting, .clearCompleted, .clearFailed: return true
            case .retryAllFailed: return false
            }
        }

        /// The confirmation message, stating exactly what the action does
        /// and — just as exactly — what it does not touch.
        func confirmationMessage(count: Int) -> String {
            switch self {
            case .cancelAllWaiting:
                return "\(count) waiting job\(count == 1 ? "" : "s") will be cancelled. The running job, if any, is left in flight, and delivered containers are never touched."
            case .retryAllFailed:
                return "\(count) failed job\(count == 1 ? "" : "s") will run again from clean, untouched inputs."
            case .clearCompleted:
                return "\(count) completed job\(count == 1 ? "" : "s") will be removed from the list. The signed artifacts in Exports are not touched."
            case .clearFailed:
                return "\(count) failed job\(count == 1 ? "" : "s") will be removed from the list. Nothing else changes."
            }
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Signing Queue")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .confirmationDialog(
                    pendingBulkAction?.title ?? "",
                    isPresented: Binding(
                        get: { pendingBulkAction?.requiresConfirmation == true },
                        set: { if !$0 { pendingBulkAction = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: pendingBulkAction
                ) { action in
                    Button(action.title, role: .destructive) {
                        pendingBulkAction = nil
                        perform(action)
                    }
                    Button("Cancel", role: .cancel) { pendingBulkAction = nil }
                } message: { action in
                    Text(action.confirmationMessage(count: count(for: action)))
                }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if queue.jobs.isEmpty && !queue.isRestoring {
            emptyContent
        } else {
            jobList
        }
    }

    private var emptyContent: some View {
        ZEmptyState.noQueueJobs {
            onOpenLibrary()
        }
    }

    private var jobList: some View {
        List {
            statisticsSection

            if queue.isRestoring {
                Section {
                    Label("Restoring the queue…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !queue.runningJobs.isEmpty {
                Section {
                    ForEach(queue.runningJobs) { job in
                        jobRow(job, waitingPosition: nil)
                    }
                } header: {
                    Text("Running")
                }
            }

            if !queue.waitingJobs.isEmpty {
                Section {
                    ForEach(Array(queue.waitingJobs.enumerated()), id: \.element.id) { position, job in
                        jobRow(job, waitingPosition: position)
                    }
                } header: {
                    Text("Waiting · \(queue.waitingJobs.count)")
                } footer: {
                    Text("Highest priority first, then the order you asked. Reordering never interrupts the running job — it decides what runs next.")
                }
            }

            if !queue.completedJobs.isEmpty {
                Section("Completed") {
                    ForEach(queue.completedJobs) { job in
                        jobRow(job, waitingPosition: nil)
                    }
                }
            }

            if !queue.failedJobs.isEmpty {
                Section("Failed") {
                    ForEach(queue.failedJobs) { job in
                        jobRow(job, waitingPosition: nil)
                    }
                }
            }

            if !queue.cancelledJobs.isEmpty {
                Section("Cancelled") {
                    ForEach(queue.cancelledJobs) { job in
                        jobRow(job, waitingPosition: nil)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(for: SigningJobIdentifier.self) { jobID in
            SigningJobDetailView(queue: queue, jobID: jobID)
        }
        .animation(ZMotion.fast, value: queue.jobs.map { $0.id.rawValue + $0.statusText })
    }

    private func jobRow(_ job: SigningQueue.Job, waitingPosition: Int?) -> some View {
        NavigationLink(value: job.id) {
            if job.state == .running {
                // Only the running card ticks — once a second, for its
                // elapsed time and estimate. Every other card renders only
                // when its job changes, which keeps a long queue cheap.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    SigningJobCard(job: job, queue: queue, waitingPosition: waitingPosition)
                }
            } else {
                SigningJobCard(job: job, queue: queue, waitingPosition: waitingPosition)
            }
        }
        .contextMenu { contextMenuItems(for: job) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if job.state.isActive {
                Button(role: .destructive) {
                    ZHaptics.tap()
                    queue.cancel(job.id)
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
            } else if job.canBeRemoved {
                Button(role: .destructive) {
                    ZHaptics.tap()
                    withAnimation(ZMotion.fast) { queue.remove(job.id) }
                } label: {
                    Label("Remove", systemImage: "xmark")
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if job.state == .queued {
                Button {
                    ZHaptics.tap()
                    withAnimation(ZMotion.fast) { queue.sendToTop(job.id) }
                } label: {
                    Label("Send to Top", systemImage: "arrow.up.to.line")
                }
                .tint(.blue)
            } else if job.isRetryable {
                Button {
                    ZHaptics.tap()
                    queue.retry(job.id)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .tint(.orange)
            }
        }
    }

    @ViewBuilder
    private func contextMenuItems(for job: SigningQueue.Job) -> some View {
        if job.state == .queued {
            Button { queue.move(job.id, up: true) } label: {
                Label("Move Up", systemImage: "chevron.up")
            }
            Button { queue.move(job.id, up: false) } label: {
                Label("Move Down", systemImage: "chevron.down")
            }
            Button { queue.sendToTop(job.id) } label: {
                Label("Send to Top", systemImage: "arrow.up.to.line")
            }
            Menu {
                ForEach(SigningJobPriority.allCases, id: \.self) { priority in
                    Button {
                        queue.setPriority(priority, on: job.id)
                    } label: {
                        if job.priority == priority {
                            Label("\(priority.displayName) — \(priority.purposeText)", systemImage: "checkmark")
                        } else {
                            Text("\(priority.displayName) — \(priority.purposeText)")
                        }
                    }
                }
            } label: {
                Label("Priority", systemImage: job.priority.symbolName)
            }
            Button(role: .destructive) { queue.cancel(job.id) } label: {
                Label("Cancel Job", systemImage: "xmark.circle")
            }
        } else if job.state == .running {
            Button(role: .destructive) { queue.cancel(job.id) } label: {
                Label(job.cancellationRequested ? "Cancelling…" : "Cancel Job", systemImage: "xmark.circle")
            }
            .disabled(job.cancellationRequested)
        } else {
            if job.isRetryable {
                Button { queue.retry(job.id) } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
            if job.canBeRemoved {
                Button(role: .destructive) {
                    withAnimation(ZMotion.fast) { queue.remove(job.id) }
                } label: {
                    Label("Remove", systemImage: "xmark")
                }
            }
        }
    }

    // MARK: - Statistics

    @ViewBuilder
    private var statisticsSection: some View {
        let summary = queue.summary
        if summary.totalCount > 0 {
            Section {
                SigningQueueStatisticsCard(summary: summary)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let onDone {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { onDone() }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Section("Bulk Actions") {
                    Button {
                        requestBulkAction(.cancelAllWaiting)
                    } label: {
                        Label("Cancel All Waiting (\(queue.waitingJobs.count))", systemImage: "xmark.circle")
                    }
                    .disabled(queue.waitingJobs.isEmpty)

                    Button {
                        requestBulkAction(.retryAllFailed)
                    } label: {
                        Label("Retry All Failed (\(retryableFailedCount))", systemImage: "arrow.clockwise")
                    }
                    .disabled(retryableFailedCount == 0)

                    Button {
                        requestBulkAction(.clearCompleted)
                    } label: {
                        Label("Clear Completed (\(queue.completedJobs.count))", systemImage: "checkmark.circle")
                    }
                    .disabled(queue.completedJobs.isEmpty)

                    Button {
                        requestBulkAction(.clearFailed)
                    } label: {
                        Label("Clear Failed (\(queue.failedJobs.count))", systemImage: "trash")
                    }
                    .disabled(queue.failedJobs.isEmpty)
                }
                if let notifier = env.queueNotifier as? LocalSigningQueueNotifier, notifier.isSupported {
                    QueueNotificationToggle(notifier: notifier)
                }
            } label: {
                Label("Queue Actions", systemImage: "ellipsis.circle")
            }
            .accessibilityLabel("Queue actions")
        }
    }

    private var retryableFailedCount: Int {
        queue.failedJobs.filter { $0.isRetryable }.count
    }

    /// Routes a bulk action through confirmation when it is destructive,
    /// and runs it directly when it is not.
    private func requestBulkAction(_ action: BulkAction) {
        ZHaptics.tap()
        if action.requiresConfirmation {
            pendingBulkAction = action
        } else {
            perform(action)
        }
    }

    private func perform(_ action: BulkAction) {
        switch action {
        case .cancelAllWaiting:
            queue.cancelAllWaiting()
        case .retryAllFailed:
            queue.retryAllFailed()
        case .clearCompleted:
            withAnimation(ZMotion.fast) { queue.clearCompleted() }
        case .clearFailed:
            withAnimation(ZMotion.fast) { queue.clearFailed() }
        }
    }

    /// The number of jobs one bulk action would affect, for its
    /// confirmation message.
    private func count(for action: BulkAction) -> Int {
        switch action {
        case .cancelAllWaiting: return queue.waitingJobs.count
        case .retryAllFailed: return retryableFailedCount
        case .clearCompleted: return queue.completedJobs.count
        case .clearFailed: return queue.failedJobs.count
        }
    }
}

// MARK: - Statistics card

/// The queue at a glance: how many jobs are in each state, and what the
/// active work is doing. Counts, not claims.
private struct SigningQueueStatisticsCard: View {

    let summary: SigningQueue.Summary

    var body: some View {
        ZCard(variant: .material, cornerRadius: ZRadius.lg) {
            VStack(alignment: .leading, spacing: ZSpacing.sm) {
                HStack(spacing: ZSpacing.xs) {
                    Image(systemName: summary.isBusy ? "tray.full" : "tray")
                        .foregroundStyle(summary.isBusy ? Color.accentColor : .secondary)
                    Text(headline)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer()
                }
                HStack(spacing: ZSpacing.sm) {
                    statTile("Running", value: summary.runningCount, tint: .blue)
                    statTile("Waiting", value: summary.waitingCount, tint: .secondary)
                    statTile("Completed", value: summary.completedCount, tint: .green)
                    statTile("Failed", value: summary.failedCount, tint: .red)
                }
                .accessibilityElement(children: .contain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, ZSpacing.xs)
    }

    private var headline: String {
        if summary.runningCount > 0 {
            return summary.waitingCount == 1
                ? "Signing now · 1 job waiting"
                : "Signing now · \(summary.waitingCount) jobs waiting"
        }
        if summary.waitingCount > 0 {
            return "Starting next job…"
        }
        if summary.failedCount > 0 && summary.completedCount > 0 {
            return "Queue finished — \(summary.completedCount) signed, \(summary.failedCount) failed"
        }
        if summary.failedCount > 0 {
            return "Queue finished — \(summary.failedCount) failed"
        }
        if summary.completedCount > 0 {
            return "Queue finished — \(summary.completedCount) signed"
        }
        return "Queue idle"
    }

    private func statTile(_ label: String, value: Int, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(value > 0 ? tint : Color.secondary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ZSpacing.xxs)
        .background(Color(.tertiarySystemFill).opacity(0.5), in: RoundedRectangle(cornerRadius: ZRadius.sm))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}

// MARK: - Job card

/// One queued signing job: the application's icon and declared identity,
/// the stage the job is in, honest progress, the estimated remaining work,
/// its priority, and the time it has been running or took.
///
/// The card is the dashboard's row and reads as one element for VoiceOver;
/// its controls are separately focusable buttons and menus.
struct SigningJobCard: View {

    let job: SigningQueue.Job
    let queue: SigningQueue
    let waitingPosition: Int?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var now: Date { Date() }

    /// Badges side by side, or stacked at accessibility text sizes so no
    /// badge is truncated into meaninglessness.
    private var badgeLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ZSpacing.xxs))
            : AnyLayout(HStackLayout(spacing: ZSpacing.xs))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            header
            if let remaining = SigningQueueRendering.remainingWorkText(
                for: job,
                waitingPosition: waitingPosition,
                now: now
            ) {
                Label(remaining, systemImage: job.state == .queued ? "clock" : "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if job.state.isActive || job.state.failure != nil || job.state == .cancelled {
                progressBar
            }
            if job.state == .running, !job.cancellationRequested {
                // The live stage list is the running job's honest progress:
                // what finished, what is in flight, what has not been
                // reached. Spec-shaped, weighted, and never faked.
                SigningJobStageListView(rows: SigningQueueRendering.stageRows(for: job))
            }
            if let failure = job.failure {
                Text(failure.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let completion = job.completion {
                HStack(spacing: ZSpacing.xs) {
                    ZStatusBadge("Verified", systemImage: "checkmark.seal.fill", kind: .success)
                    Text(completion.outputFileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, ZSpacing.xxs)
        // VoiceOver reads the card as one element — everything it shows,
        // in the order a person would say it — and exposes every control
        // the card offers as a custom action, so nothing is reachable only
        // by sight or by a precise tap.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            SigningQueueRendering.accessibilityDescription(
                for: job,
                waitingPosition: waitingPosition,
                now: now
            )
        )
        .accessibilityHint("Opens the job's details.")
        .accessibilityActions { accessibilityControls }
    }

    @ViewBuilder
    private var accessibilityControls: some View {
        if job.state == .queued {
            Button("Move Up") { queue.move(job.id, up: true) }
            Button("Move Down") { queue.move(job.id, up: false) }
            Button("Send to Top") { queue.sendToTop(job.id) }
            ForEach(SigningJobPriority.allCases.filter { $0 != job.priority }, id: \.self) { priority in
                Button("Set \(priority.displayName) Priority") { queue.setPriority(priority, on: job.id) }
            }
            Button("Cancel Job") { queue.cancel(job.id) }
        }
        if job.state == .running && !job.cancellationRequested {
            Button("Cancel Job") { queue.cancel(job.id) }
        }
        if job.isRetryable {
            Button("Retry Job") { queue.retry(job.id) }
        }
        if job.canBeRemoved {
            Button("Remove from Queue") { queue.remove(job.id) }
        }
    }

    private var header: some View {
        HStack(spacing: ZSpacing.sm) {
            ApplicationIconView(
                artifactID: job.artifactID,
                displayName: job.applicationName,
                bundleIdentifier: job.bundleIdentifier,
                size: 44
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.applicationName)
                    .font(.body.weight(.medium))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 1)
                    .truncationMode(.middle)
                badgeLayout {
                    stateBadge
                    if job.state == .queued || job.state == .running {
                        ZStatusBadge(
                            job.priority.displayName,
                            systemImage: job.priority.symbolName,
                            kind: job.priority == .high ? .warning : .neutral
                        )
                    }
                    if job.attemptCount > 1 {
                        ZStatusBadge("Attempt \(job.attemptCount)", systemImage: "arrow.clockwise", kind: .neutral)
                    }
                }
            }
            Spacer(minLength: ZSpacing.xs)
            trailingControls
        }
    }

    private var subtitle: String {
        var parts = [job.bundleIdentifier]
        if let versionText = job.versionText {
            parts.append(versionText)
        }
        if let elapsed = SigningQueueRendering.elapsedText(for: job, now: now) {
            parts.append(job.state == .running ? elapsed : "took \(elapsed)")
        } else if job.state == .running, let startedAt = job.startedAt {
            parts.append("started \(startedAt.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch job.state {
        case .queued:
            ZStatusBadge("Waiting", systemImage: "clock", kind: .neutral)
        case .running:
            if job.cancellationRequested {
                ZStatusBadge("Cancelling…", systemImage: "xmark.circle", kind: .warning)
            } else {
                ZStatusBadge(job.progress?.stage.shortName ?? "Starting", systemImage: "hammer.fill", kind: .info)
            }
        case .completed:
            ZStatusBadge("Completed", systemImage: "checkmark.seal.fill", kind: .success)
        case .failed(let failure):
            ZStatusBadge("Failed · \(failure.stage.shortName)", systemImage: "xmark.shield.fill", kind: .error)
        case .cancelled:
            ZStatusBadge("Cancelled", systemImage: "xmark.circle", kind: .neutral)
        }
    }

    @ViewBuilder
    private var trailingControls: some View {
        HStack(spacing: ZSpacing.xs) {
            if job.state == .running {
                Button {
                    ZHaptics.tap()
                    queue.cancel(job.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(job.cancellationRequested)
                .accessibilityLabel(job.cancellationRequested
                    ? "Cancelling \(job.applicationName)"
                    : "Cancel signing \(job.applicationName)")
            }
            if job.isRetryable {
                Button {
                    ZHaptics.tap()
                    queue.retry(job.id)
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Retry signing \(job.applicationName)")
            }
            if job.canBeRemoved {
                Button {
                    ZHaptics.tap()
                    withAnimation(ZMotion.fast) { queue.remove(job.id) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(job.applicationName) from the queue list")
            }
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if job.state == .running {
            // The overall fraction advances at real stage boundaries, so the
            // bar is determinate overall even while the current stage itself
            // measures nothing countable — and never shows a percentage the
            // pipeline did not establish.
            ProgressView(value: job.fractionCompleted)
                .tint(.accentColor)
                .animation(ZMotion.fast, value: job.fractionCompleted)
                .accessibilityLabel("\(job.applicationName) progress")
                .accessibilityValue("\(Int((job.fractionCompleted * 100).rounded())) percent, \(job.statusText)")
        } else if job.failure != nil {
            ProgressView(value: job.fractionCompleted)
                .tint(.red)
                .accessibilityLabel("\(job.applicationName) stopped")
                .accessibilityValue("\(Int((job.fractionCompleted * 100).rounded())) percent when it failed")
        } else if job.state == .cancelled {
            ProgressView(value: job.fractionCompleted)
                .tint(.secondary)
                .accessibilityLabel("\(job.applicationName) cancelled")
                .accessibilityValue("\(Int((job.fractionCompleted * 100).rounded())) percent when it was cancelled")
        }
    }
}

// MARK: - Live stage list

/// The running job's stages, one row each: finished stages at 100%, the
/// current stage with its honest measure — a determinate bar where the
/// pipeline counts work, an activity indicator where it reports stage
/// boundaries alone — and the stages that have not been reached marked
/// pending. No row shows a percentage the pipeline did not establish.
struct SigningJobStageListView: View {

    let rows: [SigningQueueRendering.StageRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows, id: \.stage) { row in
                HStack(spacing: ZSpacing.xs) {
                    Image(systemName: symbol(for: row))
                        .font(.caption)
                        .foregroundStyle(tint(for: row))
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text(row.stage.displayName)
                        .font(.caption)
                        .foregroundStyle(row.status == .pending ? .secondary : .primary)
                    Spacer(minLength: ZSpacing.xs)
                    statusView(row)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.stage.displayName), \(statusText(row))")
            }
        }
        .padding(.vertical, ZSpacing.xxs)
    }

    @ViewBuilder
    private func statusView(_ row: SigningQueueRendering.StageRow) -> some View {
        switch row.status {
        case .complete:
            Text("100%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.green)
        case .current:
            if let fraction = row.stageFraction {
                HStack(spacing: ZSpacing.xxs) {
                    ProgressView(value: fraction)
                        .frame(width: 44)
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: ZSpacing.xxs) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("In progress")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .stopped:
            Text("Stopped")
                .font(.caption2)
                .foregroundStyle(.red)
        case .pending:
            Text("Pending")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func statusText(_ row: SigningQueueRendering.StageRow) -> String {
        switch row.status {
        case .complete: return "complete"
        case .current:
            if let fraction = row.stageFraction {
                return "\(Int((fraction * 100).rounded())) percent"
            }
            return "in progress"
        case .stopped: return "stopped here"
        case .pending: return "pending"
        }
    }

    private func symbol(for row: SigningQueueRendering.StageRow) -> String {
        switch row.status {
        case .complete: return "checkmark.circle.fill"
        case .current: return row.stage.symbolName
        case .stopped: return "xmark.circle.fill"
        case .pending: return "circle.dashed"
        }
    }

    private func tint(for row: SigningQueueRendering.StageRow) -> Color {
        switch row.status {
        case .complete: return .green
        case .current: return .accentColor
        case .stopped: return .red
        case .pending: return .secondary
        }
    }
}

// MARK: - Notification preference

/// The user's queue-notification preference, bound to the platform
/// notifier. Shown only where notifications exist; turning it on is the
/// only path that asks the system for permission, so the toggle explains
/// itself before it is tapped.
private struct QueueNotificationToggle: View {

    @ObservedObject var notifier: LocalSigningQueueNotifier

    var body: some View {
        Toggle(isOn: $notifier.isEnabled) {
            Label("Notify When Jobs Finish", systemImage: "bell.badge")
        }
    }
}

// MARK: - Preview

private struct SigningQueuePreviewHost: View {
    private let environment = CompositionRoot.fallbackEnvironment
    var body: some View {
        SigningQueueView(queue: environment.signingQueue)
    }
}

#Preview("Signing Queue") {
    SigningQueuePreviewHost()
}
