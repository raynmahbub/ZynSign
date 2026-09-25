import SwiftUI

/// The Library tab — the dual-pane library ZynSign users expect.
///
/// This is ZynSign's original library experience. It keeps the existing
/// `ApplicationLibraryView` for the list/detail/bundle-explorer flow, but
/// adds the segmented Downloaded / Signed header and bulk actions that make
/// everyday use fast. The underlying storage is still `ApplicationLibrary`
/// (file-catalog + file artifacts, no Core Data, no desktop import).
/// Nothing here claims signing; a “Sign” action appears only when the
/// future signing pipeline is composed — until then it shows the honest
/// “Signing not yet composed” state from the docs.
struct LibraryTabView: View {

    @Environment(\.applicationEnvironment) private var env
    @State private var selectedSegment = 0 // 0 Downloaded, 1 Signed
    @State private var searchText = ""
    @State private var isSelecting = false
    @State private var selection: Set<ApplicationRecordIdentifier> = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if ReleaseTrain.isAvailable(.smartSign) {
                    Picker("", selection: $selectedSegment) {
                        Text("Imported").tag(0)
                        Text("Signed").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }

                // The real library list is the existing ApplicationLibraryView's
                // content, but we embed it without its own NavigationStack to
                // avoid double navigation. We therefore reuse its model directly.
                LibrarySegmentContent(segment: selectedSegment, searchText: searchText, isSelecting: $isSelecting, selection: $selection)
            }
            .navigationTitle("Library")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isSelecting ? "Done" : "Select") { isSelecting.toggle(); if !isSelecting { selection = [] } }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isSelecting && !selection.isEmpty {
                        Menu {
                            Button("Delete Selected", systemImage: "trash", role: .destructive) {
                                Task { await deleteSelected() }
                            }
                        } label: { Text("Actions") }
                    }
                }
            }
        }
    }

    private func deleteSelected() async {
        for id in selection {
            try? await env.library.remove(recordWithID: id)
        }
        selection = []
        isSelecting = false
    }
}

private struct LibrarySegmentContent: View {
    let segment: Int
    let searchText: String
    @Binding var isSelecting: Bool
    @Binding var selection: Set<ApplicationRecordIdentifier>
    @Environment(\.applicationEnvironment) private var env
    @State private var entries: [LibraryEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var filtered: [LibraryEntry] {
        if searchText.isEmpty { return entries }
        return entries.filter { $0.record.bundleIdentifier.rawValue.localizedCaseInsensitiveContains(searchText) || ($0.record.displayName?.localizedCaseInsensitiveContains(searchText) ?? false) }
    }

    // Signed output is not re-imported into the library: SigningView writes it
    // to Documents/Signed, so this segment points there with the real count.
    var body: some View {
        Group {
            if isLoading {
                ScrollView { ZSkeleton(rows: 5).padding() }
            } else if let msg = errorMessage {
                ContentUnavailableView {
                    Label("Library Unavailable", systemImage: "exclamationmark.triangle")
                } description: { Text(msg) } actions: {
                    Button("Retry") { Task { await load() } }.buttonStyle(.borderedProminent)
                }
            } else if segment == 1 {
                // Signed — output lives in Documents/Signed, browsable in Files
                let signed = HomeStorageCounts.signedCount()
                ContentUnavailableView {
                    Label(signed == 0 ? "No Signed Apps" : "\(signed) Signed App\(signed == 1 ? "" : "s")", systemImage: "signature")
                } description: {
                    Text(signed == 0
                         ? "Sign an application from Imported (touch and hold → Sign Application…). The signed IPA is saved to Documents/Signed."
                         : "Signed IPAs are saved to Documents/Signed. Open the Files tab → Signed to share them.")
                }
            } else if filtered.isEmpty {
                ContentUnavailableView {
                    Label("No Apps", systemImage: "square.stack.3d.up")
                } description: {
                    Text(ReleaseTrain.isAvailable(.downloads)
                         ? "Import an .ipa from Files or Downloads. Accepted packages are kept across launches and listed here."
                         : "Import an .ipa from Files or Home. Accepted packages are kept across launches and listed here.")
                }
            } else {
                List {
                    ForEach(filtered, id: \.record.id) { entry in
                        HStack(spacing: 12) {
                            if isSelecting {
                                Image(systemName: selection.contains(entry.record.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selection.contains(entry.record.id) ? Color.accentColor : .secondary)
                                    .onTapGesture { toggle(entry) }
                            }
                            NavigationLink(value: entry) {
                                LibraryRow(entry: entry)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { if isSelecting { toggle(entry) } }
                        .contextMenu {
                            if entry.isArtifactAvailable && ReleaseTrain.isAvailable(.smartSign) {
                                NavigationLink { SigningView(entry: entry) } label: {
                                    Label("Sign Application…", systemImage: "signature")
                                }
                            }
                            NavigationLink(value: entry) { Label("Details", systemImage: "info.circle") }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await load() }
                .navigationDestination(for: LibraryEntry.self) { entry in
                    ApplicationDetailView(entry: entry, bundleInspection: env.bundleInspection)
                }
            }
        }
        .task { await load() }
        .onChange(of: searchText) { _, _ in }
    }

    private func toggle(_ entry: LibraryEntry) {
        if selection.contains(entry.record.id) { selection.remove(entry.record.id) }
        else { selection.insert(entry.record.id) }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await env.library.entries()
            errorMessage = nil
        } catch {
            errorMessage = (error as? ZynSignError)?.userMessage ?? "The library could not be accessed."
        }
    }
}

private struct LibraryRow: View {
    let entry: LibraryEntry
    var body: some View {
        let content = ApplicationLibraryRowContent(entry: entry)
        VStack(alignment: .leading, spacing: ZSpacing.xxs) {
            Text(content.name).font(.body).lineLimit(1)
            Text(content.bundleIdentifier).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: ZSpacing.xs) {
                if let v = content.versionText { Text(v).font(.caption2).foregroundStyle(.tertiary) }
                if let flag = content.availabilityText {
                    ZStatusBadge(flag, systemImage: "exclamationmark.triangle", kind: .warning)
                } else if entry.isArtifactAvailable {
                    ZStatusBadge("Available", systemImage: "checkmark.circle.fill", kind: .success)
                }
            }
        }
        .padding(.vertical, ZSpacing.xxs)
    }
}
