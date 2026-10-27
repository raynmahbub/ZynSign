import SwiftUI

/// The signing history — every operation the journal holds, successes and
/// failures alike.
///
/// The Export Center shows what signing *produced*. This screen shows what
/// signing *did*, including the runs that produced nothing: a failure has no
/// artifact, so without a history it left no trace the user could reach. That
/// is the reason this screen exists, and why a failed operation is a first-
/// class row rather than a footnote.
///
/// Three rules come from `SigningHistoryModel` and the record itself, and this
/// view adds no state of its own beyond what it is showing:
///
/// - A failure is never drawn as a success. The mark, the summary, and the
///   stage come from the record's own outcome.
/// - A record written by an earlier build reads as an operation whose newer
///   detail was not recorded, not as one that failed to record it now.
/// - Clearing the journal removes history and nothing else: no artifact, no
///   imported package, no identity.
struct SigningHistoryView: View {

    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.exportsPresentation) private var exportsPresentation
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model: SigningHistoryModel
    @State private var isConfirmingClear = false
    @State private var path: [SigningRecordIdentifier] = []
    @State private var isShowingToast = false
    @State private var toastMessage = ""
    @State private var toastStyle: ZToast.Style = .info

    /// Whether this screen owns its navigation container. A pushed host — the
    /// Settings stack — passes `false`, because a stack inside a stack is the
    /// crash this shell has chased before.
    private let embedsNavigationStack: Bool

    init(history: any SigningHistoryStore, embedsNavigationStack: Bool = true) {
        _model = StateObject(wrappedValue: SigningHistoryModel(history: history))
        self.embedsNavigationStack = embedsNavigationStack
    }

    var body: some View {
        if embedsNavigationStack {
            NavigationStack(path: $path) { screen }
        } else {
            screen
        }
    }

    private var screen: some View {
        content
            .navigationTitle("Signing History")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $model.query.searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: Text("App, bundle ID, or version")
            )
            .toolbar { toolbarContent }
            .navigationDestination(for: SigningRecordIdentifier.self) { identifier in
                detail(for: identifier)
            }
            .task { await model.load() }
            .refreshable { await model.load() }
            .onChange(of: model.notice) { _, notice in
                guard let notice else { return }
                toastMessage = "\(notice.title) — \(notice.message)"
                toastStyle = notice.title.localizedCaseInsensitiveContains("could not") ? .error : .success
                isShowingToast = true
                model.notice = nil
            }
            .zToast(isPresented: $isShowingToast, message: toastMessage, style: toastStyle)
            .confirmationDialog(
                "Clear Signing History?",
                isPresented: $isConfirmingClear,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive) {
                    Task { await model.clear() }
                }
                Button("Keep", role: .cancel) {}
            } message: {
                Text("Every operation in the journal is deleted from this device. Exported artifacts, imported applications, and your identities are untouched.")
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
                        Text("Reading the signing journal…")
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
                        title: "History Couldn't Be Read",
                        message: message,
                        systemImage: "clock.badge.exclamationmark",
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
                        ZEmptyState(
                            title: "No Signing Operations Yet",
                            message: "Every run of the signing pipeline is recorded here — what it signed, how it was configured, and where it stopped when it failed.",
                            systemImage: "clock.arrow.circlepath",
                            primaryActionTitle: embedsNavigationStack ? "Close" : nil,
                            primaryAction: embedsNavigationStack ? { dismiss() } : nil
                        )
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

    private var populatedList: some View {
        List {
            if model.isFilteredToNothing {
                Section {
                    ZEmptyState(
                        title: "Nothing Matches",
                        message: "The journal holds \(model.records.count) operation\(model.records.count == 1 ? "" : "s"), and the current search and filters hide them all.",
                        systemImage: "line.3.horizontal.decrease.circle",
                        secondaryActionTitle: "Clear Filters",
                        secondaryAction: {
                            withAnimation(ZMotion.fast) {
                                model.query = SigningHistoryQuery(searchText: model.query.searchText)
                            }
                        }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                ForEach(model.visibleRecords) { record in
                    NavigationLink(value: record.id) {
                        SigningHistoryRow(record: record)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if exportsPresentation.isAvailable, let exportID = record.exportID {
                            Button {
                                exportsPresentation.presentExport(exportID)
                            } label: {
                                Label("Artifact", systemImage: "shippingbox")
                            }
                            .tint(.blue)
                        }
                    }
                }
            } header: {
                Text(summaryLine)
            } footer: {
                Text(footerLine)
            }
        }
        .listStyle(.insetGrouped)
        .animation(ZMotion.fast, value: model.visibleRecords)
    }

    @ViewBuilder
    private func detail(for identifier: SigningRecordIdentifier) -> some View {
        if let record = model.records.first(where: { $0.id == identifier }) {
            SigningOperationDetailView(
                operation: record,
                exportEntry: nil,
                library: environment.library
            )
        } else {
            ContentUnavailableView(
                "Operation Not Found",
                systemImage: "clock.arrow.circlepath",
                description: Text("This operation is no longer in the signing journal.")
            )
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if embedsNavigationStack {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if !model.records.isEmpty {
                Menu {
                    Picker("Outcome", selection: $model.query.outcome) {
                        ForEach(SigningHistoryQuery.OutcomeFilter.allCases) { filter in
                            Text(filter.displayName).tag(filter)
                        }
                    }
                    Picker("Verification", selection: $model.query.verification) {
                        ForEach(SigningHistoryQuery.VerificationFilter.allCases) { filter in
                            Text(filter.displayName).tag(filter)
                        }
                    }
                    Picker("Date", selection: $model.query.date) {
                        ForEach(SigningHistoryQuery.DateFilter.allCases) { filter in
                            Text(filter.displayName).tag(filter)
                        }
                    }
                    Divider()
                    Button("Clear Filters") {
                        withAnimation(ZMotion.fast) {
                            model.query = SigningHistoryQuery(searchText: model.query.searchText)
                        }
                    }
                    .disabled(model.query.isDefault)
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filter signing history")

                Menu {
                    Picker("Sort By", selection: $model.query.sort) {
                        ForEach(SigningHistoryQuery.SortOrder.allCases) { order in
                            Text(order.displayName).tag(order)
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        isConfirmingClear = true
                    } label: {
                        Label("Clear History", systemImage: "trash")
                    }
                    .disabled(model.isClearing)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityLabel("Sort and clear signing history")
            }
        }
    }

    // MARK: - Wording

    private var summaryLine: String {
        let shown = model.visibleRecords.count
        let total = model.records.count
        let base = shown == total
            ? "\(total) operation\(total == 1 ? "" : "s")"
            : "\(shown) of \(total) operations"
        guard model.unsuccessfulCount > 0 else { return base }
        return "\(base) · \(model.unsuccessfulCount) without output"
    }

    private var footerLine: String {
        model.query.isDefault
            ? "Newest first. Each row is one run of the signing pipeline, as the run recorded it."
            : "Filtered order. Clear the filters to see the whole journal."
    }
}

// MARK: - A row

/// One operation, as a row: what was signed, what happened, and when.
private struct SigningHistoryRow: View {

    let record: SigningRecord

    var body: some View {
        HStack(spacing: ZSpacing.sm) {
            Text(record.outcome.displayMark)
                .font(.headline)
                .foregroundStyle(color)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                Text(record.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(record.outcomeSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: ZSpacing.xxs) {
                    ZStatusBadge(
                        record.outcome.displayName,
                        systemImage: symbol,
                        kind: kind
                    )
                    if record.deliveredArtifact {
                        ZStatusBadge("Artifact kept", systemImage: "shippingbox", kind: .info)
                    }
                    if let status = record.verificationStatus {
                        ZStatusBadge(
                            status.displayName,
                            systemImage: "checkmark.shield",
                            kind: status == .valid ? .success : .warning
                        )
                    }
                }
            }
            Spacer(minLength: ZSpacing.xs)
            VStack(alignment: .trailing, spacing: ZSpacing.xxs) {
                Text(record.startedAt, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let bytes = record.outputByteCount {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, ZSpacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var color: Color {
        switch record.outcome {
        case .succeeded: return ZColors.success
        case .failed: return ZColors.error
        case .cancelled: return .secondary
        }
    }

    private var symbol: String {
        switch record.outcome {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "minus.circle"
        }
    }

    private var kind: ZStatusBadge.Kind {
        switch record.outcome {
        case .succeeded: return .success
        case .failed: return .error
        case .cancelled: return .neutral
        }
    }

    private var accessibilityDescription: String {
        var parts = [record.displayName, record.outcomeSummary]
        if let bytes = record.outputByteCount, record.outcome == .succeeded {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Query convenience

private extension SigningHistoryQuery {

    /// A query that keeps the search text and drops every filter, which is what
    /// *Clear Filters* means.
    init(searchText: String) {
        self.init()
        self.searchText = searchText
    }
}
