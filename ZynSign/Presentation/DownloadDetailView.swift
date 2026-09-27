import SwiftUI

/// One download, in full: application, transfer, and validation.
///
/// Import, signing handoff, and keeping the file are separate actions. None
/// of them starts signing. A failed validation explains the issue and does
/// not offer import.
struct DownloadDetailView: View {

    @ObservedObject var center: DownloadCenter
    let jobID: DownloadJobIdentifier
    var onOpenLibrary: () -> Void = {}
    var onOpenSigningQueue: () -> Void = {}

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.applicationEnvironment) private var environment
    @State private var handoffMessage: String?
    @State private var openedEntry: LibraryEntryLink?

    private var job: DownloadCenter.Job? { center.job(withID: jobID) }

    var body: some View {
        Group {
            if let job {
                detail(job)
            } else {
                ContentUnavailableView("Download Removed", systemImage: "arrow.down.circle", description: Text("This download is no longer in the queue."))
            }
        }
        .navigationTitle(job?.request.displayName ?? "Download")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Download", isPresented: Binding(get: { handoffMessage != nil }, set: { if !$0 { handoffMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(handoffMessage ?? "")
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
    }

    @ViewBuilder
    private func detail(_ job: DownloadCenter.Job) -> some View {
        List {
            Section("Application") {
                labeled("Name", job.request.displayName)
                labeled("Version", job.request.version ?? "Not declared")
                labeled("Source", job.request.sourceName)
                labeled("Priority", job.priority.displayName)
            }
            Section("Transfer") {
                labeled("Stage", job.statusText)
                if let fraction = job.progress.fraction {
                    ProgressView(value: fraction)
                        .accessibilityLabel("Progress")
                        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
                } else if job.isTransferring {
                    ProgressView()
                        .accessibilityLabel("Progress")
                        .accessibilityValue("Size not yet known")
                }
                labeled("Downloaded", DownloadCenterRendering.bytes(job.progress.receivedBytes))
                labeled("Remaining", DownloadCenterRendering.remainingText(for: job))
                labeled("Speed", DownloadCenterRendering.speed(job.progress.bytesPerSecond))
                labeled("Estimated time", DownloadCenterRendering.etaText(job.progress.estimatedRemainingSeconds))
                Text(job.resumeFact == .notCaptured && job.isPaused
                     ? DownloadResumeFact.notCaptured.explanation
                     : (job.resumeFact == .held ? DownloadResumeFact.held.explanation : "Resume is reported only when the transfer captures resume data."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Validation") {
                validationRows(job)
            }
            if job.request.releaseNotes != nil || !job.request.versionHistory.isEmpty {
                Section("What's New") {
                    if let date = job.request.releaseDate { labeled("Release date", date) }
                    labeled("Source", job.request.sourceName)
                    if let notes = job.request.releaseNotes {
                        Text(notes).font(.body).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(job.request.versionHistory) { note in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.version).font(.headline)
                            if let date = note.date { Text(date).font(.caption).foregroundStyle(.secondary) }
                            if let notes = note.notes { Text(notes).font(.subheadline).fixedSize(horizontal: false, vertical: true) }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            if job.isQueued {
                Section("Priority") {
                    priorityControls(job)
                }
            }
            Section {
                handoffButtons(job)
            } footer: {
                Text("Import and signing are separate. Nothing here signs an app automatically, and removing a download never removes an imported app.")
            }
            if !job.log.isEmpty {
                Section("Activity") {
                    ForEach(job.log.suffix(12).reversed()) { entry in
                        Text(entry.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func validationRows(_ job: DownloadCenter.Job) -> some View {
        if let validation = job.validation {
            labeled("File integrity", validation.checksumMatched == false ? "Checksum did not match" : (validation.archiveReadable ? "Archive readable" : "Not readable"))
            labeled("Package layout", validation.ipaStructureAccepted ? "Expected structure" : "Not an expected app package")
            labeled("Extraction readiness", validation.extractionReady ? "Structure allows a later extract" : "Not ready")
            labeled("Metadata", validation.metadataAvailable ? "Declared metadata is readable" : "Metadata unavailable")
            labeled("Import readiness", validation.isImportReady ? "Ready — not imported yet" : "Not ready")
            Text(validation.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = validation.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else if let failure = job.failure {
            Text(failure.summary).fixedSize(horizontal: false, vertical: true)
            if let detail = failure.detail {
                Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Validation runs after the transfer finishes. A configured source is not treated as trust.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func handoffButtons(_ job: DownloadCenter.Job) -> some View {
        if job.isImportReady {
            Button {
                Task { await importNow(job) }
            } label: {
                Label("Import Now", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityHint("Hands the validated file to Import. Does not sign it.")
            Button {
                Task { await queueSigning(job) }
            } label: {
                Label("Queue for Signing", systemImage: "signature")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityHint("Imports the file and does not start signing. You confirm a certificate and profile later.")
            Button {
                center.keepDownloaded(job.id)
            } label: {
                Label("Keep Downloaded", systemImage: "archivebox")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            if job.handoff == .signingRequested {
                Button {
                    onOpenSigningQueue()
                } label: {
                    Label("Open Signing Queue", systemImage: "tray.full")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
            Button {
                Task { await openLibraryApp(job) }
            } label: {
                Label("View in Library", systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        }
        if job.isRetryable {
            Button { center.retry(job.id) } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityHint(job.resumeFact.explanation)
        }
        if job.isQueued || job.isTransferring || job.isPaused {
            Button(role: .destructive) { center.cancel(job.id) } label: {
                Label("Cancel", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        }
        if job.isPaused {
            Button { center.resume(job.id) } label: {
                Label("Resume", systemImage: "play.fill")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityHint(job.resumeFact.explanation)
        }
        if job.isImportReady || job.isFailed || job.isCancelled {
            Button(role: .destructive) { center.removeDownload(job.id) } label: {
                Label("Remove Download", systemImage: "trash")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityHint("Removes this download only. Imported apps are not deleted.")
        }
    }

    @ViewBuilder
    private func priorityControls(_ job: DownloadCenter.Job) -> some View {
        Picker("Priority", selection: Binding(
            get: { job.priority },
            set: { center.setPriority($0, on: job.id) }
        )) {
            ForEach(DownloadJobPriority.allCases, id: \.self) { priority in
                Text(priority.displayName).tag(priority)
            }
        }
        .pickerStyle(.segmented)
        HStack {
            Button { center.move(job.id, up: true) } label: { Label("Move Up", systemImage: "arrow.up") }
                .frame(minHeight: 44)
            Button { center.move(job.id, up: false) } label: { Label("Move Down", systemImage: "arrow.down") }
                .frame(minHeight: 44)
            Button { center.sendToTop(job.id) } label: { Label("Send to Top", systemImage: "arrow.up.to.line") }
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityElement(children: .contain)
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func importNow(_ job: DownloadCenter.Job) async {
        if let message = await center.importNow(job.id) {
            handoffMessage = message
        } else {
            handoffMessage = "Handed to Import. Signing was not started."
        }
    }

    private func queueSigning(_ job: DownloadCenter.Job) async {
        if let message = await center.requestSigningHandoff(job.id) {
            handoffMessage = message
        } else {
            handoffMessage = "Imported. Signing has not started and was not queued. Choose a certificate and profile from the Library when you want to sign."
        }
    }

    private func openLibraryApp(_ job: DownloadCenter.Job) async {
        guard let bundle = job.request.bundleIdentifier,
              let entries = try? await environment.library.entries(),
              let entry = entries.first(where: { $0.record.bundleIdentifier.rawValue == bundle }) else {
            onOpenLibrary()
            handoffMessage = "Library is open. This download has not been imported yet, or no matching app was found."
            return
        }
        openedEntry = LibraryEntryLink(entry: entry)
    }
}

struct LibraryEntryLink: Identifiable {
    let entry: LibraryEntry
    var id: String { entry.record.id.rawValue }
}
