import SwiftUI

/// The Import area: every way of bringing packages into ZynSign, in one
/// screen.
///
/// The screen is the destination for the whole import experience — the file
/// picker, a share-sheet hand-off, a drag from another app, and a pull-down
/// on this very list all end here — and it shows the queue that results: what
/// is running, what is waiting, what has finished, and what ZynSign did with
/// each package. Every row is the same shape whether one file was chosen or
/// ten, because a queue of one is still a queue.
///
/// Three things the screen deliberately does not do. It never shows a
/// location: a job is named by the file the user chose, never by a path. It
/// never edits the library: a finished import says what happened and offers
/// to open the Library, where the entry can be seen. And it never claims a
/// package is signed, genuine, or installable: an import that succeeded says
/// the bytes are in ZynSign's library. A matching preset may offer Ready to
/// Sign; that opens confirmation and does not sign by itself.
struct ImportQueueView: View {

    /// The import queue this screen shows, observed directly: its state is
    /// the state the screen renders, so there is nothing to mirror.
    @ObservedObject var queue: PackageImportQueue

    /// Opens the Library tab, so a finished import can be seen where it
    /// landed. Provided by whichever screen presents the import area.
    var onOpenLibrary: () -> Void = {}

    /// Closes the area, when it is presented as a sheet. `nil` when the
    /// screen is shown as another screen's content.
    var onDone: (() -> Void)? = nil

    @State private var isShowingPicker = false
    @State private var pickerFailure: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Import")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .fileImporter(
                    isPresented: $isShowingPicker,
                    allowedContentTypes: ImportablePackage.contentTypes,
                    allowsMultipleSelection: true
                ) { result in
                    handlePickerResult(result)
                }
                .alert(
                    "Import Failed",
                    isPresented: Binding(
                        get: { pickerFailure != nil },
                        set: { if !$0 { pickerFailure = nil } }
                    ),
                    presenting: pickerFailure
                ) { _ in
                    Button("OK", role: .cancel) { pickerFailure = nil }
                } message: { message in
                    Text(message)
                }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            queue.enqueue(urls, origin: .dragAndDrop)
            return true
        }
    }

    // MARK: - Picker

    /// Queues what the picker handed over. Closing the picker without a
    /// selection arrives as a failure, but is an ordinary cancellation;
    /// anything else is announced, because a picker that could not vend a
    /// file the user tapped is worth telling them about.
    private func handlePickerResult(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            queue.enqueue(urls, origin: .documentPicker)
        case .failure(let error):
            guard !ImportQueueRendering.isCancellation(error) else { return }
            pickerFailure = ImportQueueRendering.pickerFailureMessage(for: error)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if queue.jobs.isEmpty {
            emptyContent
        } else {
            jobList
        }
    }

    private var jobList: some View {
        List {
            if queue.summary.settledCount > 0 {
                Section {
                    ImportSummaryCard(
                        summary: queue.summary,
                        onOpenLibrary: onOpenLibrary,
                        onClear: { withAnimation(.snappy) { queue.removeSettled() } }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            if !queue.activeJobs.isEmpty {
                Section("Importing") {
                    ForEach(queue.activeJobs) { job in
                        row(for: job)
                    }
                }
            }

            if !queue.settledJobs.isEmpty {
                Section("Finished") {
                    ForEach(queue.settledJobs) { job in
                        row(for: job)
                    }
                }
            }

            Section {
                Text("Pull down to choose more packages, or drop them here on iPad. ZynSign copies what it needs into its own storage — the files you choose are never changed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { isShowingPicker = true }
        .animation(.snappy, value: queue.jobs.map(\.id))
    }

    private func row(for job: PackageImportQueue.Job) -> some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            ImportJobRow(
                job: job,
                onCancel: { queue.cancel(job.id) },
                onRetry: { queue.retry(job.id) },
                onRemove: { withAnimation(.snappy) { queue.remove(job.id) } },
                onResolve: { resolution in
                    withAnimation(.snappy) { queue.resolveDuplicate(job.id, with: resolution) }
                }
            )
            if let record = job.settlement?.record, job.settlement?.kind.isAccepted == true {
                ImportReadyToSignOffer(record: record)
            }
        }
    }

    private var emptyContent: some View {
        ContentUnavailableView {
            Label("Import Packages", systemImage: "square.and.arrow.down")
        } description: {
            Text("Choose one or more .ipa files to bring them into ZynSign. ZynSign checks each package, reads its structure and the information its application declares, and keeps accepted packages in its library. Importing never changes the files you choose, and never installs or signs anything.")
        } actions: {
            Button("Choose Packages…") { isShowingPicker = true }
                .buttonStyle(.borderedProminent)
            Text("You can also drop packages here on iPad, or share them to ZynSign from another app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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
        if queue.isBusy {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel All", role: .destructive) { queue.cancelAll() }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                isShowingPicker = true
            } label: {
                Label("Add Packages", systemImage: "plus")
            }
        }
    }
}

// MARK: - One job

/// One queued import: what is happening to it, how far it has come, and the
/// one action that makes sense at that moment.
private struct ImportJobRow: View {

    let job: PackageImportQueue.Job
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onRemove: () -> Void
    let onResolve: (DuplicateResolution) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            HStack(spacing: ZSpacing.sm) {
                Image(systemName: symbolName)
                    .font(.body)
                    .foregroundStyle(tint)
                    .frame(width: 26)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(job.sourceFileName)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: ZSpacing.xs)

                trailingActions
            }

            if job.state.isActive {
                ProgressView(value: job.fractionCompleted)
                    .tint(tint)
                    .animation(.easeOut(duration: 0.25), value: job.fractionCompleted)
                    .accessibilityLabel("\(job.sourceFileName): \(job.statusText)")
                    .accessibilityValue("\(Int(job.fractionCompleted * 100)) percent")
            }

            if let report = job.pendingDuplicateReport {
                DuplicateDecisionView(report: report, onResolve: onResolve)
            }

            if let settlement = job.settlement {
                Text(ImportQueueRendering.message(for: settlement))
                    .font(.footnote)
                    .foregroundStyle(settlement.kind.isAccepted ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, ZSpacing.xxs)
    }

    /// What the row shows beside the file name: the stage it is in, where it
    /// came from, and — once measured — how large it is.
    private var subtitle: String {
        var parts = [job.statusText, job.origin.displayName]
        if let byteCount = job.byteCount, byteCount > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    private var symbolName: String {
        if let settlement = job.settlement {
            return settlement.kind.symbolName
        }
        return job.origin.symbolName
    }

    private var tint: Color {
        guard let settlement = job.settlement else { return .accentColor }
        switch settlement.kind {
        case .imported, .keptBoth, .replaced: return .green
        case .alreadyHeld: return .blue
        case .rejected, .failed: return .orange
        case .cancelled: return .secondary
        }
    }

    @ViewBuilder
    private var trailingActions: some View {
        HStack(spacing: ZSpacing.xs) {
            if job.isRetryable {
                Button {
                    ZHaptics.tap()
                    onRetry()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Try \(job.sourceFileName) again")
            }

            if job.state.isActive {
                Button {
                    ZHaptics.tap()
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Cancel importing \(job.sourceFileName)")
            } else {
                Button {
                    ZHaptics.tap()
                    onRemove()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(job.sourceFileName) from the list")
            }
        }
    }
}

// MARK: - The duplicate question

/// The question ZynSign asks when a package relates to something the library
/// already holds, together with the evidence for the relation.
///
/// The question states facts and offers answers; it does not recommend one.
/// Keeping both is never destructive, replacing removes entries the user can
/// see listed above, and cancelling stores nothing at all — all three are
/// ordinary outcomes, and each says what it does before it is tapped.
private struct DuplicateDecisionView: View {

    let report: DuplicateReport
    let onResolve: (DuplicateResolution) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            HStack(spacing: ZSpacing.xs) {
                Image(systemName: "square.on.square")
                    .foregroundStyle(.orange)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: ZSpacing.xs) {
                ForEach(Array(report.decisiveMatches.prefix(3).enumerated()), id: \.offset) { _, match in
                    matchView(match)
                }
                if report.decisiveMatches.count > 3 {
                    Text("and \(report.decisiveMatches.count - 3) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(ZSpacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: ZRadius.sm))

            Text("Replacing removes the entries it matches. Keeping both stores this package as a further entry. Cancelling stores nothing and leaves the file you chose untouched.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: ZSpacing.xs) {
                ForEach(report.offeredResolutions, id: \.self) { resolution in
                    Button {
                        ZHaptics.tap()
                        onResolve(resolution)
                    } label: {
                        HStack(spacing: ZSpacing.xs) {
                            Image(systemName: resolution.symbolName)
                            Text(resolution.displayName)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(resolution.isDestructive ? .red : .accentColor)
                    .accessibilityLabel("\(resolution.displayName). \(resolution.explanation)")
                }
            }
        }
        .padding(.top, ZSpacing.xxs)
    }

    private var title: String {
        report.matches.contains { $0.kind == .identicalContent }
            ? "ZynSign already holds this package"
            : "ZynSign already has this application's version"
    }

    private func matchView(_ match: DuplicateMatch) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: ZSpacing.xxs) {
                ZStatusBadge(
                    match.kind.displayName,
                    systemImage: match.kind.symbolName,
                    kind: badgeKind(for: match.kind)
                )
                Text(match.record.displayName ?? match.record.bundleIdentifier.rawValue)
                    .font(.caption)
                    .lineLimit(1)
            }
            ForEach(Array(match.evidence.enumerated()), id: \.offset) { _, evidence in
                HStack(spacing: ZSpacing.xxs) {
                    Text(evidence.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(evidence.value)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private func badgeKind(for kind: DuplicateMatchKind) -> ZStatusBadge.Kind {
        switch kind {
        case .identicalContent: return .warning
        case .sameVersionAndBuild: return .info
        case .otherVersion: return .neutral
        }
    }
}

// MARK: - The summary

/// What the batch of imports did, once it is done.
///
/// The summary is the only place the whole queue is described at once, and it
/// counts rather than claims: how many packages went into the library, how
/// many were already there, how many were refused or failed, and how much
/// content was copied.
private struct ImportSummaryCard: View {

    let summary: ImportSummary
    let onOpenLibrary: () -> Void
    let onClear: () -> Void

    var body: some View {
        ZCard(variant: .material) {
            VStack(alignment: .leading, spacing: ZSpacing.xs) {
                HStack(spacing: ZSpacing.xs) {
                    Image(systemName: summary.unsuccessfulCount == 0 ? "checkmark.seal.fill" : "checkmark.seal")
                        .foregroundStyle(summary.unsuccessfulCount == 0 ? .green : .orange)
                    Text(ImportQueueRendering.headline(for: summary))
                        .font(.headline)
                        .lineLimit(2)
                }
                Text(ImportQueueRendering.detail(for: summary))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: ZSpacing.sm) {
                    if summary.addedCount > 0 {
                        Button("View Library") {
                            ZHaptics.tap()
                            onOpenLibrary()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Clear Finished") {
                        ZHaptics.tap()
                        onClear()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, ZSpacing.xs)
    }
}

// MARK: - Preview

/// A host so the preview can build one environment and hand the queue to the
/// screen, exactly the way `RootView` does.
private struct ImportQueuePreviewHost: View {

    private let environment = CompositionRoot.makeApplicationEnvironment()

    var body: some View {
        ImportQueueView(queue: environment.packageImportQueue)
    }
}

#Preview("Import") {
    ImportQueuePreviewHost()
}
