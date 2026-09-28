import SwiftUI
import UniformTypeIdentifiers

/// A recovery operation stays on this screen until verified. Nothing is
/// silently restored: changing persistent files is staged for a cold launch.
struct RecoveryCenterView: View {
    @Environment(\.settingsCenter) private var settings
    @State private var store = CompositionRoot.makeRecoveryStore()
    @State private var items: [BackupHistoryItem] = []
    @State private var restoreStatus = "No pending restore"
    @State private var usage: (latest: Int64, older: Int64, recovery: Int64) = (0, 0, 0)
    @State private var showingBuilder = false
    @State private var showingRestore = false
    @State private var selectedItem: BackupHistoryItem?
    @State private var message: String?
    @State private var renameItem: BackupHistoryItem?
    @State private var renameText = ""
    @State private var deleteItem: BackupHistoryItem?
    @State private var cleanWorkspace = false
    @State private var cleanIncoming = false
    @State private var cleanPrevious = false

    var body: some View {
        List {
            Section("Backup Status") {
                LabeledContent("Last Backup", value: items.first?.createdAt.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                LabeledContent("Backup Size", value: items.first.map { size($0.bytes) } ?? "—")
                if let last = items.first, Date().timeIntervalSince(last.createdAt) > 7 * 86_400 {
                    Label("Last backup is more than a week old. Consider a new backup.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                LabeledContent("Workspace Health", value: "Inspect jobs below")
                LabeledContent("Restore Status", value: restoreStatus)
                LabeledContent("Recovery Ready", value: items.isEmpty ? "Create a backup" : "Backup available · verify before restore")
            }
            Section("Create Backup") {
                Button { showingBuilder = true } label: { Label("Create encrypted backup", systemImage: "plus.circle") }
                Text("You control when to back up. No automatic backup or cloud upload occurs. Keep your passphrase separately; ZynSign cannot recover it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Restore") {
                Button { showingRestore = true } label: { Label("Restore from a backup file", systemImage: "square.and.arrow.down") }
                Text("Restores are validated before staging and take effect after you close and reopen the app. Selected categories replace local data; unselected categories stay unchanged.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Workspace Recovery") {
                NavigationLink {
                    WorkspaceRecoveryView()
                } label: { Label("Inspect interrupted work", systemImage: "clock.arrow.circlepath") }
                Button("Clean up temporary files") { cleanWorkspace = true }
                Text("Signing identities and profiles must be set up separately on a new device. Interrupted jobs are not exported or marked complete.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Storage Health") {
                LabeledContent("Latest Backup", value: size(usage.latest))
                LabeledContent("Older Backups", value: size(usage.older))
                LabeledContent("Recovery Data", value: size(usage.recovery))
                LabeledContent("Total", value: size(usage.latest + usage.older + usage.recovery))
                Button("Remove transferred temporary copies") { cleanIncoming = true }
                Button("Remove previous restore snapshot", role: .destructive) { cleanPrevious = true }
                    .disabled(restoreStatus != "Restore verified after restart")
            }
            Section("Backup History") {
                if items.isEmpty { Text("No local backups yet").foregroundStyle(.secondary) }
                ForEach(items) { item in
                    Button {
                        selectedItem = item
                        showingRestore = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.name).foregroundStyle(.primary)
                                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(size(item.bytes)).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button("Rename") { renameItem = item; renameText = item.name }
                        Button("View Details / Verify") { selectedItem = item; showingRestore = true }
                        Button("Delete", role: .destructive) { deleteItem = item }
                    }
                }
            }
            Section("Move to another device") {
                NavigationLink {
                    MigrationAssistantView(store: store, latest: items.first)
                } label: { Label("Migration Assistant", systemImage: "iphone.gen3") }
            }
        }
        .navigationTitle("Recovery Center")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
        .sheet(isPresented: $showingBuilder, onDismiss: { Task { await refresh() } }) {
            NavigationStack { BackupBuilderView(store: store) }
        }
        .sheet(isPresented: $showingRestore, onDismiss: { selectedItem = nil; Task { await refresh() } }) {
            NavigationStack { RestoreBuilderView(store: store, localItem: selectedItem) }
        }
        .alert("Rename Backup", isPresented: Binding(get: { renameItem != nil }, set: { if !$0 { renameItem = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let item = renameItem { Task { do { try await store.rename(item, to: renameText); await refresh() } catch { message = error.localizedDescription } } }
                renameItem = nil
            }
            Button("Cancel", role: .cancel) { renameItem = nil }
        }
        .confirmationDialog("Delete this local backup? Transferred copies are not affected.", isPresented: Binding(get: { deleteItem != nil }, set: { if !$0 { deleteItem = nil } })) {
            Button("Delete Backup", role: .destructive) {
                if let item = deleteItem { Task { do { try await store.delete(item); await refresh() } catch { message = error.localizedDescription } } }
                deleteItem = nil
            }
        }
        .confirmationDialog("Clean temporary workspace? Review interrupted imports before cleaning.", isPresented: $cleanWorkspace) {
            Button("Clean", role: .destructive) { Task { await settings.clearTemporaryFiles() } }
        }
        .confirmationDialog("Remove transferred copies? Local backups and staged restores are kept.", isPresented: $cleanIncoming) {
            Button("Remove Copies", role: .destructive) {
                Task { do { _ = try await store.cleanIncoming(); await refresh() }
                       catch { message = error.localizedDescription } }
            }
        }
        .confirmationDialog("Permanently remove pre-restore snapshots? You will no longer be able to recover the data that was on this device before a restore.", isPresented: $cleanPrevious) {
            Button("Remove Previous Data", role: .destructive) {
                Task { do { try await store.cleanPreviousRestore(); await refresh() }
                       catch { message = error.localizedDescription } }
            }
        }
        .alert("Recovery", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }

    private func refresh() async {
        do { items = try await store.history(); usage = try await store.usage(); restoreStatus = await store.status() }
        catch { message = error.localizedDescription }
    }
}

private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

private struct BackupBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    let store: RecoveryStore
    @State private var categories: Set<BackupCategory> = Set(BackupCategory.allCases)
    @State private var password = ""
    @State private var confirm = ""
    @State private var step = 0
    @State private var busy = false
    @State private var result: BackupHistoryItem?
    @State private var error: String?

    var body: some View {
        Form {
            Section { Text("Step \(min(step + 1, 3)) of 3 · Select → Encrypt → Verify")
                .font(.headline).accessibilityAddTraits(.isHeader) }
            if step == 0 {
                Section("Include") {
                    ForEach(BackupCategory.allCases) { category in
                        Toggle(category.title, isOn: Binding(
                            get: { categories.contains(category) },
                            set: { if $0 { categories.insert(category) } else { categories.remove(category) } }
                        ))
                    }
                }
                Section { Text("Library includes favorites, metadata, and imported IPA packages. History contains references to signed artifacts, not the signed files. Search and download history are not currently stored in a portable format. Private keys, identities, profiles, queue setups, and temporary workspaces are excluded.")
                    .font(.footnote) }
                Button("Continue") { step = 1 }.disabled(categories.isEmpty)
            } else if step == 1 {
                Section("Encryption") {
                    SecureField("Passphrase (12 characters minimum)", text: $password)
                        .textContentType(.newPassword)
                    SecureField("Confirm passphrase", text: $confirm)
                        .textContentType(.newPassword)
                    Text("Without this passphrase, a backup cannot be restored. It is never stored by ZynSign.")
                        .font(.footnote)
                }
                Button("Create and verify backup") { create() }
                    .disabled(busy || password.count < 12 || password != confirm)
                Button("Back to selection") { step = 0 }.disabled(busy)
                if busy { ProgressView("Encrypting and verifying…") }
            } else if let result {
                Section("Verified Backup") {
                    Label("Backup complete", systemImage: "checkmark.shield")
                    Text("\(result.categories.map(\.title).joined(separator: ", ")) · \(size(result.bytes))")
                    ShareLink(item: storeURL(result)) { Label("Export backup file", systemImage: "square.and.arrow.up") }
                    Text("Transfer the file securely. The backup is not usable without your passphrase.").font(.footnote)
                }
                Button("Done") { dismiss() }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Create Backup")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
    }
    private func storeURL(_ item: BackupHistoryItem) -> URL {
        // History items use an app-owned backup location, independent of the
        // Files export destination chosen in the share sheet.
        CompositionRoot.backupFileURL(for: item)
    }
    private func create() {
        busy = true; error = nil
        Task {
            do { result = try await store.create(categories: categories, password: password); password = ""; confirm = ""; step = 2 }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

private struct RestoreBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    let store: RecoveryStore
    let localItem: BackupHistoryItem?
    @State private var file: URL?
    @State private var password = ""
    @State private var manifest: BackupManifest?
    @State private var scope: Set<BackupCategory> = []
    @State private var step = 0
    @State private var importing = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section { Text("Step \(min(step + 1, 4)) of 4 · Select → Validate → Preview → Stage")
                .font(.headline).accessibilityAddTraits(.isHeader) }
            if step == 0 {
                Section("Select backup") {
                    if let localItem {
                        Text(localItem.name)
                        Text(localItem.createdAt.formatted()).foregroundStyle(.secondary)
                    }
                    Button("Choose backup file…") { importing = true }
                    if let file { Text(file.lastPathComponent).font(.caption) }
                    Button("Continue") { step = 1 }.disabled(file == nil && localItem == nil)
                }
            } else if step == 1 {
                Section("Validate backup") {
                    SecureField("Backup passphrase", text: $password)
                    Button("Verify encryption, version & checksums") { verify() }.disabled(busy || password.isEmpty)
                    Button("Back to file selection") { step = 0 }.disabled(busy)
                    if busy { ProgressView("Validating all files…") }
                }
            } else if let manifest {
                Section("Verified contents") {
                    LabeledContent("Backup version", value: "\(manifest.version)")
                    LabeledContent("Backup date", value: manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Files", value: "\(manifest.entries.count)")
                    LabeledContent("Library items", value: manifest.libraryItems.map(String.init) ?? "Not included")
                    LabeledContent("Imported packages", value: "\(manifest.entries.filter { $0.path.hasPrefix("Artifacts/") }.count)")
                    LabeledContent("Favorites", value: manifest.favoriteItems.map(String.init) ?? "Not included")
                    LabeledContent("Collections", value: manifest.collectionCount.map(String.init) ?? "Not included")
                    LabeledContent("Settings", value: manifest.categories.contains(.settings) ? "Included" : "Not included")
                    LabeledContent("History", value: manifest.categories.contains(.history) ? "Included" : "Not included")
                }
                Section("Choose restore scope") {
                    ForEach(BackupCategory.allCases.filter { manifest.categories.contains($0) }) { category in
                        Toggle(category.title, isOn: Binding(
                            get: { scope.contains(category) },
                            set: { if $0 { scope.insert(category) } else { scope.remove(category) } }
                        ))
                    }
                }
                Section {
                    Text("Selected categories replace the matching data on this device after restart. Existing versions are kept for recovery. Unselected categories, identities, profiles, queue jobs and signed files are unchanged. Imported packages are not merged with the current library.")
                        .font(.footnote)
                    Button("Stage restore for next launch") { stage() }.disabled(busy || scope.isEmpty || step == 3)
                    if step == 3 { Label("Ready. Close and reopen ZynSign to finish and verify.", systemImage: "checkmark.shield") }
                    if step == 2 {
                        Button("Choose another backup") { self.manifest = nil; scope = []; password = ""; step = 0 }
                    }
                    if busy { ProgressView("Checking and staging…") }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Restore Backup")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                Task { do { file = try await store.importFile(url); manifest = nil; step = 0 }
                       catch { self.error = error.localizedDescription } }
            case .failure(let error): self.error = error.localizedDescription
            }
        }
        .task {
            if let localItem { file = await store.url(for: localItem) }
        }
    }
    private func verify() {
        guard let file else { return }
        busy = true; error = nil
        Task {
            do {
                let verified = try await store.inspect(file, password: password)
                manifest = verified; scope = verified.categories; step = 2
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
    private func stage() {
        guard let file else { return }
        busy = true; error = nil
        Task {
            do { _ = try await store.prepare(file, password: password, categories: scope, expected: manifest)
                 password = ""; step = 3 }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

private struct WorkspaceRecoveryView: View {
    @Environment(\.applicationEnvironment) private var environment

    var body: some View {
        WorkspaceJobsView(hub: environment.importHub, queue: environment.signingQueue)
    }
}

private struct WorkspaceJobsView: View {
    @ObservedObject var hub: ImportHub
    @ObservedObject var queue: SigningQueue
    @Environment(\.settingsCenter) private var settings
    @State private var cleanup = false

    var body: some View {
        List {
            Section("Interrupted imports") {
                if hub.items.isEmpty { Text("No imports to inspect") }
                ForEach(hub.items, id: \.id) { item in
                    LabeledContent(item.fileName, value: item.stage.displayName)
                }
                Button("Retry failed imports") { hub.retryAllFailed() }
                Button("Resume waiting imports") { hub.resume() }
            }
            Section("Signing queue") {
                if queue.jobs.isEmpty { Text("No jobs to inspect") }
                ForEach(queue.jobs, id: \.id) { job in
                    NavigationLink {
                        SigningJobDetailView(queue: queue, jobID: job.id)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(job.applicationName)
                            Text(job.statusText).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Retry safe failed jobs") { queue.retryAllFailed() }
                Text("Waiting jobs resume through the queue. Interrupted jobs can only be retried if their setup and source still exist. No unfinished job is treated as completed.")
                    .font(.footnote)
            }
            Section("Temporary workspace & pending exports") {
                Text("Inspect imports and jobs before cleaning. Temporary working copies may contain work that cannot be resumed. Signed exports remain in the Export Center and are not cleaned here.")
                    .font(.footnote)
                Button("Clean old temporary files", role: .destructive) { cleanup = true }
            }
        }
        .navigationTitle("Workspace Recovery")
        .confirmationDialog("Clean old temporary files?", isPresented: $cleanup) {
            Button("Clean", role: .destructive) {
                // The existing storage policy owns retention and exclusions.
                Task { await settings.clearTemporaryFiles() }
            }
        }
    }
}

private struct MigrationAssistantView: View {
    let store: RecoveryStore
    @State private var latest: BackupHistoryItem?
    @State private var backup = false
    @State private var restore = false
    @State private var status = "No pending restore"

    init(store: RecoveryStore, latest: BackupHistoryItem?) {
        self.store = store
        _latest = State(initialValue: latest)
    }

    var body: some View {
        Form {
            Section("1 · Export") {
                Text("Create a verified, encrypted backup. Keep the passphrase in a separate safe place.")
                Button("Create Backup") { backup = true }
            }
            Section("2 · Transfer") {
                if let latest {
                    ShareLink(item: CompositionRoot.backupFileURL(for: latest)) {
                        Label("Share latest .zynbackup file", systemImage: "square.and.arrow.up")
                    }
                } else { Text("Create a backup first.").foregroundStyle(.secondary) }
                Text("On iPad or iPhone use Files or AirDrop. Do not send your passphrase alongside the file.")
            }
            Section("3 · Restore on new device") {
                Button("Select and Restore Backup") { restore = true }
                Text("Verify the entire backup and preview the categories before selecting what to replace. Signing identities and profiles need separate setup.")
            }
            Section("4 · Verify") {
                Text(status)
                Text("Close and reopen ZynSign after staging. Confirm library items and collections are present, then inspect your signing queue. Nothing unfinished is marked completed.")
            }
        }
        .navigationTitle("Migration Assistant")
        .task { await refresh() }
        .sheet(isPresented: $backup, onDismiss: { Task { await refresh() } }) {
            NavigationStack { BackupBuilderView(store: store) }
        }
        .sheet(isPresented: $restore, onDismiss: { Task { await refresh() } }) {
            NavigationStack { RestoreBuilderView(store: store, localItem: nil) }
        }
    }

    private func refresh() async {
        latest = (try? await store.history())?.first
        status = await store.status()
    }
}
