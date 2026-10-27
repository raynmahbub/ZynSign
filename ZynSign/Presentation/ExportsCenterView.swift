import SwiftUI
import UIKit

/// The Export Center — everywhere a signed artifact is, in one place.
///
/// Signing writes a container into export storage and records it; this screen
/// is the list of those records, and the only place every one of them can be
/// found again. Without it a signed package was reachable exactly once — from
/// the signing result that produced it, until that screen was closed — which
/// is not a library of anything.
///
/// The screen owns no state of its own beyond what it is showing: the catalog,
/// its availability, verification, delivery, and removal all belong to
/// `ExportsCenterModel` and the export use case. Three honest rules come from
/// there and are the reason this view has no logic of its own:
///
/// - An artifact whose file is gone is still listed, and says so. It is part of
///   the record of what the user signed; hiding it would hide that the bytes
///   are gone, and the actions that need them are disabled instead.
/// - A failure to delete or verify is a message, never a silent no-op, and
///   never a change to the list it did not actually make.
/// - Nothing here installs, hosts, or claims an installation. Sharing hands the
///   artifact to iOS and learns only whether the sheet completed.
@MainActor
struct ExportsCenterView: View {

    @Environment(\.exportsPresentation) private var exportsPresentation
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model: ExportsCenterModel

    /// The journal, so a run that produced no artifact is still reachable.
    private let history: (any SigningHistoryStore)?

    /// The artifact the caller already knew about, opened once the catalog has
    /// loaded so the push happens against a real entry rather than a guess.
    private let initialSelection: ExportIdentifier?

    /// Called when the user asks for the application an artifact was signed
    /// from. The shell closes this screen and opens the library at it.
    private let onRevealInLibrary: (ApplicationRecordIdentifier) -> Void

    @State private var path: [ExportIdentifier] = []
    /// The signing journal, opened from here: the two halves of "what signing
    /// did" belong a tap apart, because an artifact's row cannot explain a run
    /// that produced no artifact at all.
    @State private var isShowingHistory = false
    @State private var isConfirmingClear = false
    @State private var entryPendingRemoval: ExportEntry?
    @State private var isShowingToast = false
    @State private var toastMessage = ""
    @State private var toastStyle: ZToast.Style = .info

    init(
        exports: ExportCenter,
        history: (any SigningHistoryStore)? = nil,
        verifyExport: @escaping (ExportIdentifier) async throws -> ExportedArtifactVerification,
        initialSelection: ExportIdentifier? = nil,
        onRevealInLibrary: @escaping (ApplicationRecordIdentifier) -> Void = { _ in }
    ) {
        _model = StateObject(wrappedValue: ExportsCenterModel(
            exports: exports,
            history: history,
            verifyExport: verifyExport
        ))
        self.history = history
        self.initialSelection = initialSelection
        self.onRevealInLibrary = onRevealInLibrary
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Export Center")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(
                    text: $model.query.searchText,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: Text("App, bundle ID, or file name")
                )
                .toolbar { toolbarContent }
                .navigationDestination(for: ExportIdentifier.self) { identifier in
                    detail(for: identifier)
                }
        }
        .task {
            await model.load()
            if let initialSelection, path.isEmpty {
                path = [initialSelection]
            }
        }
        .onChange(of: model.notice) { _, notice in
            guard let notice else { return }
            present(notice)
            model.notice = nil
        }
        .onChange(of: model.verificationPresentation) { _, presentation in
            guard let presentation else { return }
            if presentation.report.status == .valid {
                ZHaptics.success()
            } else {
                ZHaptics.warning()
            }
        }
        .zToast(isPresented: $isShowingToast, message: toastMessage, style: toastStyle)
        .confirmationDialog(
            "Delete Exported Artifact?",
            isPresented: Binding(
                get: { entryPendingRemoval != nil },
                set: { if !$0 { entryPendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: entryPendingRemoval
        ) { entry in
            Button("Delete", role: .destructive) {
                entryPendingRemoval = nil
                Task { await delete(entry) }
            }
            Button("Keep", role: .cancel) { entryPendingRemoval = nil }
        } message: { entry in
            Text("“\(entry.record.fileName)” will be deleted from ZynSign's export storage. The application it was signed from stays in your library, and so does its signing history.")
        }
        .sheet(item: $model.verificationPresentation) { presentation in
            VerificationReportSheet(presentation: presentation)
        }
        .sheet(isPresented: $isShowingHistory) {
            if let history = history {
                SigningHistoryView(history: history)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            List {
                Section {
                    HStack(spacing: ZSpacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("Reading export storage…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .listStyle(.insetGrouped)

        case .failed(let message):
            List {
                Section {
                    ZEmptyState(
                        title: "Exports Couldn't Be Read",
                        message: message,
                        systemImage: "exclamationmark.triangle",
                        tint: .orange,
                        primaryActionTitle: "Try Again",
                        primaryAction: { Task { await model.load() } }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)

        case .ready:
            if model.isEmpty {
                List {
                    Section {
                        emptyState
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
            } else {
                populatedList
            }
        }
    }

    private var emptyState: some View {
        ZEmptyState(
            title: "No Signed Artifacts Yet",
            message: "Sign an application from the Library and its signed package is kept here — with its verification, its delivery record, and the application it came from.",
            systemImage: "shippingbox",
            primaryActionTitle: exportsPresentation.isAvailable ? "Close" : nil,
            primaryAction: exportsPresentation.isAvailable ? { dismiss() } : nil
        )
    }

    private var populatedList: some View {
        List {
            if model.isFilteredToNothing {
                Section {
                    ZEmptyState(
                        title: "Nothing Matches",
                        message: "Export storage holds \(model.entries.count) artifact\(model.entries.count == 1 ? "" : "s"), and the current search and filters hide them all.",
                        systemImage: "line.3.horizontal.decrease.circle",
                        secondaryActionTitle: "Clear Filters",
                        secondaryAction: {
                            withAnimation(ZMotion.fast) { model.query = ExportQuery() }
                        }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                ForEach(model.visibleEntries) { entry in
                    NavigationLink(value: entry.record.id) {
                        ExportRow(entry: entry, isVerifying: model.verifyingIDs.contains(entry.record.id))
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            entryPendingRemoval = entry
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(model.removingIDs.contains(entry.record.id))
                        Button {
                            Task { await verify(entry) }
                        } label: {
                            Label("Verify", systemImage: "checkmark.seal")
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        Button {
                            ZShareSheet.present(items: [entry.fileURL].compactMap { $0 }) { completed in
                                guard completed else { return }
                                Task { await model.markDelivered(entry) }
                            }
                        } label: {
                            Label("Export / Share", systemImage: "square.and.arrow.up")
                        }
                        .disabled(!entry.permitsArtifactActions)

                        Button {
                            Task { await verify(entry) }
                        } label: {
                            Label("Verify Again", systemImage: "checkmark.seal")
                        }
                        .disabled(model.verifyingIDs.contains(entry.record.id))

                        Button {
                            UIPasteboard.general.string = entry.record.reference
                        } label: {
                            Label("Copy Artifact Reference", systemImage: "doc.on.doc")
                        }

                        if let source = entry.record.sourceRecordID {
                            Button {
                                reveal(source)
                            } label: {
                                Label("Reveal in Library", systemImage: "books.vertical")
                            }
                        }

                        Divider()

                        Button(role: .destructive) {
                            entryPendingRemoval = entry
                        } label: {
                            Label("Delete Exported Artifact", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text(summaryLine)
            } footer: {
                Text(footerLine)
            }

            if model.unavailableCount > 0 {
                Section {
                    Label(
                        "\(model.unavailableCount) record\(model.unavailableCount == 1 ? "" : "s") name\(model.unavailableCount == 1 ? "s" : "") an artifact that is no longer in export storage. The record is kept so the signing history stays readable.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.load() }
        .animation(ZMotion.fast, value: model.visibleEntries)
    }

    @ViewBuilder
    private func detail(for identifier: ExportIdentifier) -> some View {
        if let entry = model.entries.first(where: { $0.record.id == identifier }) {
            ExportDetailView(
                entry: entry,
                operation: model.operationRecord(for: entry.record),
                onRevealInLibrary: { recordID in reveal(recordID) },
                onVerify: { await verify(entry) },
                onDelivered: { await model.markDelivered(entry) },
                onDelete: { entryPendingRemoval = entry }
            )
        } else {
            ContentUnavailableView(
                "Artifact Removed",
                systemImage: "shippingbox",
                description: Text("This export is no longer in the Export Center.")
            )
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") {
                dismiss()
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if history != nil {
                Button {
                    ZHaptics.tap()
                    isShowingHistory = true
                } label: {
                    Label("Signing History", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityHint("Every signing run the journal holds, including the ones that produced no artifact.")
            }
            if !model.entries.isEmpty {
                Menu {
                    Picker("Verification", selection: $model.query.verification) {
                        ForEach(ExportQuery.VerificationFilter.allCases) { filter in
                            Text(filter.displayName).tag(filter)
                        }
                    }
                    Picker("Availability", selection: $model.query.availability) {
                        ForEach(ExportQuery.AvailabilityFilter.allCases) { filter in
                            Text(filter.displayName).tag(filter)
                        }
                    }
                    Picker("Date", selection: $model.query.date) {
                        ForEach(ExportQuery.DateFilter.allCases) { filter in
                            Text(filter.displayName).tag(filter)
                        }
                    }
                    Divider()
                    Button("Clear Filters") {
                        withAnimation(ZMotion.fast) {
                            model.query = ExportQuery(searchText: model.query.searchText)
                        }
                    }
                    .disabled(model.query.isDefault)
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filter exports")

                Menu {
                    Picker("Sort By", selection: $model.query.sort) {
                        ForEach(ExportQuery.SortOrder.allCases) { order in
                            Text(order.displayName).tag(order)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sort exports")

                Button {
                    Task { await verifyEverything() }
                } label: {
                    Label("Verify All", systemImage: "checkmark.seal")
                }
                .disabled(model.verifyingIDs.count > 0 || model.visibleEntries.allSatisfy { !$0.permitsArtifactActions })
            }
        }
    }

    // MARK: - Wording

    private var summaryLine: String {
        let count = model.visibleEntries.count
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(model.visibleByteCount), countStyle: .file)
        return "\(count) artifact\(count == 1 ? "" : "s") · \(bytes)"
    }

    private var footerLine: String {
        model.query.isDefault
            ? "Newest first. Every artifact is the exact container the signing run delivered and verified."
            : "Filtered order. Clear the filters to see everything export storage holds."
    }

    // MARK: - Actions

    private func verify(_ entry: ExportEntry) async {
        ZHaptics.tap()
        await model.verify(entry)
    }

    private func verifyEverything() async {
        ZHaptics.tap()
        for entry in model.visibleEntries where entry.permitsArtifactActions {
            if Task.isCancelled { return }
            await model.verify(entry)
        }
    }

    private func delete(_ entry: ExportEntry) async {
        await model.remove(entry)
    }

    private func reveal(_ recordID: ApplicationRecordIdentifier) {
        dismiss()
        onRevealInLibrary(recordID)
    }

    private func present(_ notice: ExportsCenterModel.Notice) {
        toastMessage = "\(notice.title) — \(notice.message)"
        toastStyle = notice.title.localizedCaseInsensitiveContains("could not") ? .error : .success
        isShowingToast = true
    }
}

// MARK: - A row

/// One exported artifact, as a row: what was signed, what verification last
/// concluded, and whether the bytes are still there.
private struct ExportRow: View {

    let entry: ExportEntry

    /// Whether a verification of this artifact is running right now.
    let isVerifying: Bool

    private var record: ExportRecord { entry.record }

    var body: some View {
        HStack(spacing: ZSpacing.sm) {
            icon
            VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                Text(record.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(record.bundleIdentifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: ZSpacing.xxs) {
                    ZStatusBadge(
                        record.verificationStatus.displayName,
                        systemImage: Self.verificationSymbol(record.verificationStatus),
                        kind: Self.verificationKind(record.verificationStatus)
                    )
                    if !entry.isAvailable {
                        ZStatusBadge(
                            entry.availability.displayName,
                            systemImage: "exclamationmark.triangle",
                            kind: .warning
                        )
                    }
                    if record.hasBeenDelivered {
                        ZStatusBadge("Exported", systemImage: "square.and.arrow.up", kind: .info)
                    }
                    if isVerifying {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            Spacer(minLength: ZSpacing.xs)
            VStack(alignment: .trailing, spacing: ZSpacing.xxs) {
                Text(ByteCountFormatter.string(fromByteCount: Int64(record.byteCount), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(record.createdAt, format: Date.FormatStyle(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, ZSpacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts = [record.displayName, record.bundleIdentifier, record.verificationStatus.displayName]
        if !entry.isAvailable {
            parts.append("Artifact \(entry.availability.displayName.lowercased())")
        }
        if record.hasBeenDelivered {
            parts.append("Exported")
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var icon: some View {
        if let artifactID = record.sourceArtifactID {
            ApplicationIconView(
                artifactID: artifactID,
                displayName: record.displayName,
                bundleIdentifier: record.bundleIdentifier,
                size: 44
            )
        } else {
            RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous)
                .fill(Color(.tertiarySystemFill))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "shippingbox")
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
        }
    }

    private static func verificationSymbol(_ status: ArtifactVerificationStatus) -> String {
        switch status {
        case .valid: return "checkmark.seal.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .invalid: return "xmark.octagon.fill"
        case .unsupported: return "questionmark.circle"
        }
    }

    private static func verificationKind(_ status: ArtifactVerificationStatus) -> ZStatusBadge.Kind {
        switch status {
        case .valid: return .success
        case .warning: return .warning
        case .invalid: return .error
        case .unsupported: return .neutral
        }
    }
}

// MARK: - The verification report

/// What an independent verification of one artifact concluded, with every
/// finding it kept. The report is the record's own: nothing here re-runs or
/// reinterprets a check.
private struct VerificationReportSheet: View {

    let presentation: ExportsCenterModel.VerificationPresentation

    @Environment(\.dismiss) private var dismiss

    private var report: ArtifactVerificationReport { presentation.report }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: ZSpacing.xs) {
                        ZStatusBadge(
                            report.status.displayName,
                            systemImage: report.status == .valid ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                            kind: report.status == .valid ? .success : .warning
                        )
                        Spacer()
                        Text("\(report.checksRun) check\(report.checksRun == 1 ? "" : "s") run")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(presentation.fileName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } footer: {
                    Text(report.status.explanation)
                }

                if report.findings.isEmpty {
                    Section("Findings") {
                        Label("No findings: every check the verifier could run passed.", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Findings") {
                        ForEach(Array(report.findings.enumerated()), id: \.offset) { _, finding in
                            VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                                Text(finding.detail)
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("\(finding.severity.displayName) · \(finding.code.rawValue)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                Section {
                    Text("Verification reopened the artifact at \(report.verifiedAt.formatted(date: .abbreviated, time: .standard)) and inspected its bytes. It shares no state with the signing run, it does not evaluate trust, and it does not claim the package is installable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Verification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Query convenience

private extension ExportQuery {

    /// A query that keeps the search text and drops every filter, which is
    /// what *Clear Filters* means: the person typed a search on purpose, and
    /// the pickers are what they asked to reset.
    init(searchText: String) {
        self.init()
        self.searchText = searchText
    }
}
