import SwiftUI

/// The lightweight import history: when each batch arrived, from where,
/// what it imported, replaced, skipped, and why anything failed — with a
/// way back to every app it imported.
///
/// Reopening goes through the library, so an app that has since been
/// removed says so instead of opening a stale record.
@MainActor
struct ImportHistoryView: View {

    @ObservedObject var hub: ImportHub
    let library: ApplicationLibrary
    let bundleInspection: IPABundleContentsInspection
    let detailsInspection: IPAApplicationDetailsInspection

    @State private var openedEntry: LibraryEntry?
    @State private var isConfirmingClear = false
    @State private var missingApplicationName: String?

    var body: some View {
        List {
            if hub.historyUnavailable {
                Section {
                    Label("The import history couldn't be read. Clearing it starts a new one.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            if hub.history.isEmpty {
                ZEmptyState.noHistory()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            ForEach(hub.history) { entry in
                Section {
                    ForEach(entry.items) { item in
                        row(for: item)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.finishedAt, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                        Text("\(ImportQueueRendering.title(for: entry)) · \(ImportQueueRendering.counts(for: entry))")
                            .textCase(nil)
                    }
                    .accessibilityElement(children: .combine)
                    .contextMenu {
                        Button(role: .destructive) {
                            withAnimation(.snappy) { hub.removeHistoryEntry(entry.id) }
                        } label: {
                            Label("Remove from History", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Import History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear", role: .destructive) { isConfirmingClear = true }
                    .disabled(hub.history.isEmpty && !hub.historyUnavailable)
            }
        }
        .confirmationDialog("Clear Import History?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) {
                withAnimation(.snappy) { hub.clearHistory() }
            }
        } message: {
            Text("Only the history is removed. Imported apps stay in the library.")
        }
        .alert(
            "App Not in Library",
            isPresented: Binding(
                get: { missingApplicationName != nil },
                set: { if !$0 { missingApplicationName = nil } }
            ),
            presenting: missingApplicationName
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { name in
            Text("\(name) is no longer in the library.")
        }
        .navigationDestination(item: $openedEntry) { entry in
            ApplicationDetailView(
                entry: entry,
                bundleInspection: bundleInspection,
                detailsInspection: detailsInspection
            )
        }
        .task { await hub.loadHistory() }
    }

    private func row(for item: ImportHistoryEntry.Item) -> some View {
        HStack(alignment: .top, spacing: ZSpacing.sm) {
            Image(systemName: item.outcome.bucket.symbolName)
                .foregroundStyle(color(for: item.outcome.bucket))
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.applicationName ?? item.fileName)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Text(detail(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let failure = item.failureMessage {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if let recordID = item.recordID, entryCanReopen(item) {
                Button("Open") { reopen(recordID: recordID, name: item.applicationName ?? item.fileName) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func entryCanReopen(_ item: ImportHistoryEntry.Item) -> Bool {
        item.outcome.bucket == .imported || item.outcome.bucket == .replaced
    }

    private func detail(for item: ImportHistoryEntry.Item) -> String {
        var parts = [item.outcome.displayName]
        if let version = item.version {
            parts.append("Version \(version)")
        }
        if item.replacedCount > 0 {
            parts.append(item.replacedCount == 1 ? "replaced 1 entry" : "replaced \(item.replacedCount) entries")
        }
        if item.applicationName != nil {
            parts.append(item.fileName)
        }
        return parts.joined(separator: " · ")
    }

    private func reopen(recordID: String, name: String) {
        guard let identifier = ApplicationRecordIdentifier(rawValue: recordID) else {
            missingApplicationName = name
            return
        }
        Task {
            if let entry = try? await library.entry(withID: identifier) {
                openedEntry = entry
            } else {
                missingApplicationName = name
            }
        }
    }

    private func color(for bucket: ImportOutcomeBucket) -> Color {
        switch bucket {
        case .imported: return .green
        case .skipped: return .secondary
        case .replaced: return .blue
        case .failed: return .red
        }
    }
}
