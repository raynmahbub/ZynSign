import SwiftUI
import UIKit

/// The detail screen for one signing job: everything the queue knows about
/// it, in the four registers the job's story has — the application, the
/// signing configuration, the execution, and the output — plus the job's
/// own log and the controls that are honest for its current state.
///
/// The screen observes the queue directly, so a running job's stage,
/// progress, and log update live while it is open. It states facts and
/// nothing beyond them: a completed job's verification line reports the
/// pipeline's own independent verification, never trust or installability,
/// and the output section names the artifact the job's signing operation
/// committed to Exports — an artifact the removal of a job from this list
/// never touches.
struct SigningJobDetailView: View {

    @ObservedObject var queue: SigningQueue
    let jobID: SigningJobIdentifier

    @Environment(\.applicationEnvironment) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shareItem: SignedOutputShare?

    /// The Export Center's current view of the artifact a completed job
    /// delivered: its availability and location, read when the job's
    /// completion is shown so the screen never names a path itself.
    @State private var exportEntry: ExportEntry?

    private var job: SigningQueue.Job? { queue.job(withID: jobID) }
    private var now: Date { Date() }

    var body: some View {
        Group {
            if let job {
                if job.state == .running {
                    // A running job's duration and estimate tick once a
                    // second; every other state renders only on change.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        content(job)
                    }
                } else {
                    content(job)
                }
            } else {
                ContentUnavailableView {
                    Label("Job Removed", systemImage: "tray")
                } description: {
                    Text("This job is no longer in the signing queue. Anything it delivered is still in Exports, and the signing history still records what it did.")
                }
            }
        }
        .navigationTitle("Signing Job")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareItem) { item in
            SignedOutputShareSheet(url: item.url)
        }
        .task(id: job?.completion?.exportIdentifier) {
            // Re-read whenever the job's delivered export changes — a retry
            // that completes again delivers a different artifact.
            exportEntry = await env.exportCenter.entry(
                forStoredIdentifier: job?.completion?.exportIdentifier
            )
        }
    }

    @ViewBuilder
    private func content(_ job: SigningQueue.Job) -> some View {
        List {
            statusSection(job)
            applicationSection(job)
            signingSection(job)
            executionSection(job)
            if let failure = job.failure {
                failureSection(job, failure: failure)
            }
            if let completion = job.completion {
                outputSection(job, completion: completion)
            }
            controlsSection(job)
            logSection(job)
        }
        .listStyle(.insetGrouped)
        .animation(reduceMotion ? nil : .snappy, value: job.statusText)
    }

    // MARK: - Status

    private func statusSection(_ job: SigningQueue.Job) -> some View {
        Section {
            ZCard(variant: .material, cornerRadius: ZRadius.lg) {
                VStack(alignment: .leading, spacing: ZSpacing.sm) {
                    HStack(spacing: ZSpacing.md) {
                        ApplicationIconView(
                            artifactID: job.artifactID,
                            displayName: job.applicationName,
                            bundleIdentifier: job.bundleIdentifier,
                            size: 52
                        )
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                            Text(job.applicationName)
                                .font(.headline)
                                .lineLimit(2)
                            Text(job.statusText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            HStack(spacing: ZSpacing.xs) {
                                stateBadge(job)
                                ZStatusBadge(
                                    job.priority.displayName,
                                    systemImage: job.priority.symbolName,
                                    kind: job.priority == .high ? .warning : .neutral
                                )
                            }
                        }
                        Spacer(minLength: 0)
                        if job.state == .running {
                            ZProgressRing(progress: job.fractionCompleted, status: job.progress?.stage.shortName ?? "Signing")
                        } else if job.state.completion != nil {
                            ZProgressRing(progress: 1, status: "Done", tint: .green)
                        }
                    }
                    if job.state == .running || job.failure != nil {
                        SigningJobStageListView(rows: SigningQueueRendering.stageRows(for: job))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .listRowInsets(EdgeInsets(top: ZSpacing.sm, leading: ZSpacing.md, bottom: ZSpacing.sm, trailing: ZSpacing.md))
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private func stateBadge(_ job: SigningQueue.Job) -> some View {
        switch job.state {
        case .queued:
            ZStatusBadge("Waiting", systemImage: "clock", kind: .neutral)
        case .running:
            ZStatusBadge(
                job.cancellationRequested ? "Cancelling…" : "Running",
                systemImage: job.cancellationRequested ? "xmark.circle" : "hammer.fill",
                kind: job.cancellationRequested ? .warning : .info
            )
        case .completed:
            ZStatusBadge("Completed", systemImage: "checkmark.seal.fill", kind: .success)
        case .failed(let failure):
            ZStatusBadge("Failed · \(failure.stage.shortName)", systemImage: "xmark.shield.fill", kind: .error)
        case .cancelled:
            ZStatusBadge("Cancelled", systemImage: "xmark.circle", kind: .neutral)
        }
    }

    // MARK: - Application

    private func applicationSection(_ job: SigningQueue.Job) -> some View {
        Section("Application") {
            LabeledContent("Name", value: job.applicationName)
            LabeledContent("Bundle ID", value: job.bundleIdentifier)
            LabeledContent("Version", value: job.versionText ?? "—")
            LabeledContent("Queued From", value: job.origin.displayName)
            LabeledContent("Queued At") {
                Text(job.enqueuedAt, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
            }
        }
    }

    // MARK: - Signing configuration

    private func signingSection(_ job: SigningQueue.Job) -> some View {
        Section {
            LabeledContent("Certificate", value: job.identityDisplayName ?? "—")
            if let fingerprint = job.certificateFingerprint {
                LabeledContent("Fingerprint") {
                    Text(String(fingerprint.hexDigest.prefix(16)) + "…")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Certificate fingerprint SHA-256, starting \(String(fingerprint.hexDigest.prefix(8)))")
            }
            LabeledContent("Team", value: job.profileTeamIdentifier ?? "—")
            LabeledContent("Profile", value: job.profileDisplayName ?? "—")
            HStack(spacing: ZSpacing.xs) {
                ZStatusBadge(
                    job.emitDEREntitlements ? "DER 0x20400" : "0x20200",
                    systemImage: "cpu",
                    kind: job.emitDEREntitlements ? .info : .neutral
                )
                ZStatusBadge(
                    job.emitDEREntitlements ? "Slot 5 + 7" : "Slot 5",
                    systemImage: "square.stack.3d.up",
                    kind: .neutral
                )
                Spacer()
            }
        } header: {
            Text("Signing")
        } footer: {
            Text("The configuration captured when the job was queued. The private key never leaves the Keychain; the fingerprint is public certificate metadata.")
        }
    }

    // MARK: - Execution

    private func executionSection(_ job: SigningQueue.Job) -> some View {
        Section("Execution") {
            LabeledContent("Current Stage", value: job.state == .queued
                ? "Waiting"
                : (job.stage?.displayName ?? "—"))
            if let startedAt = job.startedAt {
                LabeledContent("Start Time") {
                    Text(startedAt, format: Date.FormatStyle(date: .omitted, time: .standard))
                }
            }
            LabeledContent("Duration", value: SigningQueueRendering.elapsedText(for: job, now: now) ?? "—")
            LabeledContent("Attempts", value: job.attemptCount == 0 ? "Not started" : "\(job.attemptCount)")
            LabeledContent("Verification", value: verificationText(job))
            if let remaining = SigningQueueRendering.remainingWorkText(
                for: job,
                waitingPosition: job.state == .queued
                    ? queue.waitingJobs.firstIndex(where: { $0.id == job.id })
                    : nil,
                now: now
            ) {
                LabeledContent("Remaining", value: remaining)
            }
        }
    }

    private func verificationText(_ job: SigningQueue.Job) -> String {
        switch job.state {
        case .completed(let completion):
            return completion.verificationPassed ? "Passed — independently verified" : "Not established"
        case .failed(let failure):
            return failure.stage == .verification ? "Refused the container" : "Not reached"
        case .running:
            return "Pending"
        case .queued:
            return "Not started"
        case .cancelled:
            return "Not reached"
        }
    }

    // MARK: - Failure recovery

    private func failureSection(_ job: SigningQueue.Job, failure: SigningJobFailure) -> some View {
        Section {
            HStack(spacing: ZSpacing.xs) {
                ZStatusBadge("Failed at \(failure.stage.displayName)", systemImage: "xmark.shield.fill", kind: .error)
                ZStatusBadge(String(describing: failure.category), kind: .neutral)
                Spacer()
            }
            Text(failure.summary)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            ErrorRecoveryView(category: failure.category, message: failure.summary, showsWhatHappened: false)
            if let detail = failure.detail {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Technical Detail")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Text(failure.occurredAt, format: Date.FormatStyle(date: .abbreviated, time: .standard))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if job.isRetryable {
                Button {
                    ZHaptics.tap()
                    queue.retry(job.id)
                } label: {
                    Label("Retry Job", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityHint("Starts a fresh, clean run over untouched inputs.")
            } else {
                Text("Retrying cannot change this outcome: the inputs were refused on their content. Remove the job, fix the inputs — re-import the application or choose a different profile — and queue it again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Failure")
        } footer: {
            Text("Nothing was delivered, and the run's working copy was discarded. A retry never continues from a partially modified state — it repeats a clean one. The answers above come from the failure's own category, so every job explains itself the same way.")
        }
    }

    // MARK: - Output

    private func outputSection(_ job: SigningQueue.Job, completion: SigningJobCompletion) -> some View {
        Section {
            HStack(spacing: ZSpacing.xs) {
                ZStatusBadge("Delivered", systemImage: "checkmark.seal.fill", kind: .success)
                if let nested = completion.nestedItemCount {
                    ZStatusBadge("\(nested) nested", systemImage: "internaldrive", kind: .neutral)
                }
                if let sealed = completion.sealedFileCount {
                    ZStatusBadge("\(sealed) sealed", systemImage: "lock.doc", kind: .neutral)
                }
                Spacer()
            }
            LabeledContent("Run Verification", value: completion.verificationPassed ? "Passed" : "Not recorded")
            if let exportVerification = completion.exportVerification {
                LabeledContent("Export Verification", value: exportVerification.displayName)
            }
            LabeledContent("Artifact", value: completion.outputFileName)
            LabeledContent("Location", value: "Exports")
            if let exportEntry {
                LabeledContent("Availability", value: exportEntry.availability.displayName)
            }
            if let byteCount = completion.outputByteCount {
                LabeledContent(
                    "Size",
                    value: ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
                )
            }
            if let signatureBytes = completion.signatureByteCount {
                LabeledContent(
                    "Signature",
                    value: ByteCountFormatter.string(fromByteCount: Int64(signatureBytes), countStyle: .file)
                )
            }
            if let exportEntry, exportEntry.permitsArtifactActions, let url = exportEntry.fileURL {
                Button {
                    shareItem = SignedOutputShare(url: url)
                } label: {
                    Label("Share Signed IPA…", systemImage: "square.and.arrow.up")
                }
            }
        } header: {
            Text("Output")
        } footer: {
            Text("The artifact is exactly what the signing operation produced, verified, and committed to Exports — not a trust, authorization, or installability claim. Manage or verify it again from Exports; removing this job from the queue never touches the file.")
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private func controlsSection(_ job: SigningQueue.Job) -> some View {
        Section {
            if job.state == .queued {
                Picker("Priority", selection: priorityBinding(job)) {
                    ForEach(SigningJobPriority.allCases, id: \.self) { priority in
                        Text("\(priority.displayName) — \(priority.purposeText)").tag(priority)
                    }
                }
                .pickerStyle(.inline)
                .accessibilityLabel("Priority")
                Button { queue.move(job.id, up: true) } label: {
                    Label("Move Up", systemImage: "chevron.up")
                }
                .disabled(queue.waitingJobs.first?.id == job.id)
                .keyboardShortcut(.upArrow, modifiers: .command)
                Button { queue.move(job.id, up: false) } label: {
                    Label("Move Down", systemImage: "chevron.down")
                }
                .disabled(queue.waitingJobs.last?.id == job.id)
                .keyboardShortcut(.downArrow, modifiers: .command)
                Button { queue.sendToTop(job.id) } label: {
                    Label("Send to Top", systemImage: "arrow.up.to.line")
                }
                .disabled(queue.waitingJobs.first?.id == job.id)
                .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                Button(role: .destructive) { queue.cancel(job.id) } label: {
                    Label("Cancel Job", systemImage: "xmark.circle")
                }
                .keyboardShortcut(".", modifiers: .command)
            } else if job.state == .running {
                Button(role: .destructive) {
                    queue.cancel(job.id)
                } label: {
                    Label(
                        job.cancellationRequested ? "Cancelling… — Stops at the Next Safe Point" : "Cancel Job",
                        systemImage: "xmark.circle"
                    )
                }
                .disabled(job.cancellationRequested)
                .keyboardShortcut(".", modifiers: .command)
                Text("Pause is not offered: the pipeline has no checkpoint a half-signed working copy could safely resume from, so the honest control is a clean cancellation and a clean retry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if job.isRetryable {
                    Button { queue.retry(job.id) } label: {
                        Label("Retry Job", systemImage: "arrow.clockwise")
                    }
                }
                Button(role: .destructive) {
                    withAnimation(reduceMotion ? nil : .snappy) { queue.remove(job.id) }
                } label: {
                    Label("Remove from Queue", systemImage: "trash")
                }
            }
        } header: {
            Text("Controls")
        } footer: {
            if job.state == .queued {
                Text("Reordering affects waiting jobs only — the running job, if any, is never interrupted by a change of plan behind it.")
            }
        }
    }

    private func priorityBinding(_ job: SigningQueue.Job) -> Binding<SigningJobPriority> {
        Binding(
            get: { job.priority },
            set: { queue.setPriority($0, on: job.id) }
        )
    }

    // MARK: - Log

    private func logSection(_ job: SigningQueue.Job) -> some View {
        Section {
            if job.log.isEmpty {
                Text("Nothing recorded yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(job.log.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .top, spacing: ZSpacing.xs) {
                        Text(entry.timestamp, format: Date.FormatStyle(date: .omitted, time: .standard))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 64, alignment: .leading)
                        Text(entry.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(entry.message), at \(entry.timestamp.formatted(date: .omitted, time: .shortened))")
                }
            }
        } header: {
            Text("Job Log")
        } footer: {
            Text("This job's own log. Every job logs separately — two jobs can never interleave their histories.")
        }
    }
}

// MARK: - Share

/// One delivered container to share, as a sheet item.
private struct SignedOutputShare: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct SignedOutputShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ ui: UIActivityViewController, context: Context) {}
}

// MARK: - Preview

private struct SigningJobDetailPreviewHost: View {
    private let environment = CompositionRoot.makeApplicationEnvironment()
    var body: some View {
        NavigationStack {
            if let first = environment.signingQueue.jobs.first {
                SigningJobDetailView(queue: environment.signingQueue, jobID: first.id)
            } else {
                ContentUnavailableView("No Jobs", systemImage: "tray")
            }
        }
    }
}

#Preview("Signing Job Detail") {
    SigningJobDetailPreviewHost()
}
