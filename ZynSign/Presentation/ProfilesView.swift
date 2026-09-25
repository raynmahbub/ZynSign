import SwiftUI
import UniformTypeIdentifiers

/// The Profiles area: ZynSign's library of imported provisioning profiles.
///
/// A profile's summary is what the tab lists — name, team, allowed bundle
/// identifiers, entitlement keys, and expiry — all read from the profile's
/// own declarations at import time. Importing copies the `.mobileprovision`
/// into ZynSign's profile storage and records the summary; the original
/// bytes are kept so a signing operation can use the very file that was
/// imported. Deleting removes the stored copy and the summary together.
///
/// Expiry is shown in words with a semantic badge, because an expired
/// profile is the quietest way a signing operation fails.
struct ProfilesView: View {

    @StateObject private var model: ProvisioningProfilesModel

    /// Creates the tab over the profile library and importer the
    /// composition root supplied. `nil` library renders an honest
    /// unavailable state; `nil` importer disables importing with a written
    /// reason rather than a dead control.
    init(profiles: ProvisioningProfileLibrary?, importer: ProvisioningProfileImporter?) {
        _model = StateObject(wrappedValue: ProvisioningProfilesModel(
            profiles: profiles,
            importer: importer
        ))
    }

    private var noticeBinding: Binding<Bool> {
        Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.clearNotice() } }
        )
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(ShellSection.profiles.title)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.showImporter()
                        } label: {
                            Label("Import Profile…", systemImage: "plus")
                        }
                        .disabled(!model.canImport || model.isImporting)
                    }
                }
        }
        .task { await model.load() }
        .refreshable { await model.refresh() }
        .fileImporter(
            isPresented: Binding(
                get: { model.isShowingImporter },
                set: { model.isShowingImporter = $0 }
            ),
            allowedContentTypes: ProvisioningProfilesModel.importableTypes,
            allowsMultipleSelection: false
        ) { result in
            model.handlePickerResult(result)
        }
        .alert(
            model.notice?.title ?? "",
            isPresented: noticeBinding,
            presenting: model.notice
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ScrollView { ZSkeleton(rows: 4).padding() }
                .accessibilityLabel("Loading profiles")
        case .empty:
            emptyContent
        case .failed(let message):
            ContentUnavailableView {
                Label("Profiles Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await model.load() } }
                    .buttonStyle(.borderedProminent)
            }
        case .loaded(let summaries):
            profileList(summaries)
        }
    }

    private var emptyContent: some View {
        ContentUnavailableView {
            Label("No Profiles", systemImage: ShellSection.profiles.symbolName)
        } description: {
            Text("Import a .mobileprovision file to add it to ZynSign's profile library. ZynSign reads the profile's name, team, bundle-identifier patterns, and expiry, and keeps the original file for signing.")
        } actions: {
            if model.canImport {
                Button("Import Profile…") {
                    model.showImporter()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("Profile importing is not available in this build.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func profileList(_ summaries: [ProvisioningProfileSummary]) -> some View {
        List {
            Section {
                ForEach(summaries, id: \.id) { summary in
                    NavigationLink(value: summary) {
                        ProvisioningProfileRow(summary: summary)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            model.requestRemoval(summary)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                Text("\(summaries.count) profile\(summaries.count == 1 ? "" : "s") · Profiles are read from each file's own declarations; ZynSign adds nothing to them.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(for: ProvisioningProfileSummary.self) { summary in
            ProvisioningProfileDetailView(summary: summary, model: model)
        }
        .confirmationDialog(
            "Delete Profile?",
            isPresented: Binding(
                get: { model.pendingRemoval != nil },
                set: { if !$0 { model.pendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: model.pendingRemoval
        ) { summary in
            Button("Delete Profile", role: .destructive) {
                let pending = summary
                model.pendingRemoval = nil
                Task { await model.remove(pending) }
            }
            Button("Cancel", role: .cancel) {
                model.pendingRemoval = nil
            }
        } message: { summary in
            Text("“\(summary.name)” and its stored .mobileprovision file will be permanently deleted. This cannot be undone.")
        }
    }
}

// MARK: - Row

/// One profile row: name, team, expiry countdown, and the semantic badge
/// the expiry earns — valid, expiring soon (30 days), or expired.
struct ProvisioningProfileRow: View {

    let summary: ProvisioningProfileSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(summary.name)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
            HStack(spacing: ZSpacing.xs) {
                if let team = summary.teamIdentifier {
                    Text(team)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(expiryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            expiryBadge
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(summary.name), \(summary.teamIdentifier ?? "no team"), \(expiryText)")
    }

    private var daysRemaining: Int {
        summary.daysUntilExpiration()
    }

    private var expiryText: String {
        if summary.isExpired() {
            return "Expired \(summary.expirationDate.formatted(date: .abbreviated, time: .omitted))"
        }
        return "Expires \(summary.expirationDate.formatted(date: .abbreviated, time: .omitted))"
    }

    private var expiryBadge: some View {
        Group {
            if summary.isExpired() {
                ZStatusBadge("Expired", systemImage: "xmark.circle.fill", kind: .error)
            } else if daysRemaining < 30 {
                ZStatusBadge("\(daysRemaining)d left", systemImage: "clock.badge.exclamationmark", kind: .warning)
            } else {
                ZStatusBadge("\(daysRemaining)d left", systemImage: "checkmark.circle", kind: .success)
            }
        }
    }
}

// MARK: - Detail

/// One profile in full: every fact import recorded, in the profile's own
/// words, with the expiry state at the top.
struct ProvisioningProfileDetailView: View {

    let summary: ProvisioningProfileSummary
    @ObservedObject var model: ProvisioningProfilesModel

    var body: some View {
        List {
            Section {
                HStack {
                    expiryBadge
                    Spacer()
                    Text(summary.expirationDate, format: .dateTime.year().month().day())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Expiry")
            } footer: {
                Text(summary.isExpired()
                     ? "This profile is past its expiration date. A signing operation that uses it will produce a package iOS refuses to launch."
                     : "\(daysRemainingText) remain. Profiles past expiration are the quietest way a signing operation fails.")
            }
            Section("Identity") {
                LabeledContent("Name", value: summary.name)
                if let team = summary.teamIdentifier {
                    LabeledContent("Team", value: team)
                }
                LabeledContent("Type", value: summary.allowsDebug ? "Development (get-task-allow)" : "Distribution")
                LabeledContent("Imported", value: summary.importedAt.formatted(date: .abbreviated, time: .shortened))
            }
            Section {
                if summary.bundleIdentifierPatterns.isEmpty {
                    Text("The profile declares no bundle-identifier patterns.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(summary.bundleIdentifierPatterns, id: \.self) { pattern in
                        Text(pattern)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Bundle Identifiers")
            } footer: {
                Text("A wildcard ends in .* and covers every identifier beneath its prefix.")
            }
            Section {
                if summary.entitlementsKeys.isEmpty {
                    Text("The profile grants no entitlement keys.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(summary.entitlementsKeys, id: \.self) { key in
                        Text(key)
                            .font(.footnote.monospaced())
                    }
                }
            } header: {
                Text("Entitlements")
            } footer: {
                Text("The entitlement keys the profile declares. Signing derives the application's entitlements from this profile.")
            }
            Section {
                Button(role: .destructive) {
                    model.requestRemoval(summary)
                } label: {
                    Label("Delete Profile", systemImage: "trash")
                }
            }
        }
        .navigationTitle(summary.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete Profile?",
            isPresented: Binding(
                get: { model.pendingRemoval != nil },
                set: { if !$0 { model.pendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: model.pendingRemoval
        ) { summary in
            Button("Delete Profile", role: .destructive) {
                let pending = summary
                model.pendingRemoval = nil
                Task { await model.remove(pending) }
            }
            Button("Cancel", role: .cancel) {
                model.pendingRemoval = nil
            }
        } message: { summary in
            Text("“\(summary.name)” and its stored .mobileprovision file will be permanently deleted. This cannot be undone.")
        }
    }

    private var daysRemaining: Int {
        summary.daysUntilExpiration()
    }

    private var daysRemainingText: String {
        let days = daysRemaining
        return "\(days) day\(days == 1 ? "" : "s")"
    }

    private var expiryBadge: some View {
        Group {
            if summary.isExpired() {
                ZStatusBadge("Expired", systemImage: "xmark.circle.fill", kind: .error)
            } else if daysRemaining < 30 {
                ZStatusBadge("\(daysRemaining)d left", systemImage: "clock.badge.exclamationmark", kind: .warning)
            } else {
                ZStatusBadge("Valid", systemImage: "checkmark.circle", kind: .success)
            }
        }
    }
}

// MARK: - Model

/// The presentation-side state machine for the Profiles tab.
///
/// One content phase at a time — loading, loaded, empty, failed — so the
/// screen never shows an empty library while profiles are still being read.
/// Import and removal re-read the library after they settle, so the screen
/// always shows what the profile library holds.
@MainActor
final class ProvisioningProfilesModel: ObservableObject {

    enum Phase: Equatable {
        case loading
        case loaded([ProvisioningProfileSummary])
        case empty
        case failed(String)
    }

    struct Notice: Equatable, Identifiable {
        let title: String
        let message: String

        var id: String { "\(title)-\(message)" }
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var isImporting = false
    @Published var isShowingImporter = false
    @Published private(set) var notice: Notice?

    /// The profile awaiting a confirmed removal, if any.
    @Published var pendingRemoval: ProvisioningProfileSummary?

    private let profiles: ProvisioningProfileLibrary?
    private let importer: ProvisioningProfileImporter?

    /// The content types the profile picker offers: the `.mobileprovision`
    /// extension type when the system can form it, with `.data` as the
    /// supertype that keeps the file selectable regardless of how the
    /// provider reports it. The importer re-checks the file either way.
    static var importableTypes: [UTType] {
        var types: [UTType] = []
        if let mobileprovision = UTType(filenameExtension: "mobileprovision", conformingTo: .data) {
            types.append(mobileprovision)
        }
        if let plain = UTType(filenameExtension: "mobileprovision") {
            types.append(plain)
        }
        types.append(.data)
        return types
    }

    init(profiles: ProvisioningProfileLibrary?, importer: ProvisioningProfileImporter?) {
        self.profiles = profiles
        self.importer = importer
    }

    /// Whether importing is possible in this composition. A missing library
    /// or a missing importer both mean no.
    var canImport: Bool {
        profiles != nil && importer != nil
    }

    func showImporter() {
        guard canImport else { return }
        isShowingImporter = true
    }

    /// Loads the profiles when the screen appears. A refresh keeps content
    /// on screen and announces failure instead of replacing it.
    func load() async {
        switch phase {
        case .loaded, .empty:
            await refresh()
        case .loading, .failed:
            await readProfiles(presentingLoadingState: true)
        }
    }

    func refresh() async {
        await readProfiles(presentingLoadingState: false)
    }

    private func readProfiles(presentingLoadingState: Bool) async {
        guard let profiles else {
            phase = .failed("The profile library is not part of this build's composition.")
            return
        }
        if presentingLoadingState {
            phase = .loading
        }
        do {
            let summaries = try await profiles.allProfiles()
            phase = summaries.isEmpty ? .empty : .loaded(summaries)
        } catch {
            let message = (error as? ZynSignError)?.userMessage ?? "The profile library could not be accessed."
            if presentingLoadingState {
                phase = .failed(message)
            } else {
                notice = Notice(title: "Refresh Failed", message: message)
            }
        }
    }

    /// Records how the system picker closed and, when a file was chosen,
    /// imports it. The importer owns validation; a refused file is announced
    /// with the typed reason and nothing is stored.
    func handlePickerResult(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result else {
            return // The user closed the picker without choosing. Ordinary.
        }
        guard let url = urls.first else {
            return
        }
        guard let importer, let profiles else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                let summary = try await importer.importProfile(at: url)
                try await profiles.upsert(summary)
                NotificationCenter.default.post(name: .zynsignProvisioningProfilesChanged, object: nil)
                notice = Notice(
                    title: "Profile Imported",
                    message: "“\(summary.name)” was added to the profile library."
                )
                await refresh()
            } catch let error as ZynSignError {
                notice = Notice(title: "Import Failed", message: error.userMessage)
            } catch {
                notice = Notice(title: "Import Failed", message: "The profile could not be imported.")
            }
        }
    }

    /// Requests removal; the view confirms before calling `remove(_:)`.
    func requestRemoval(_ summary: ProvisioningProfileSummary) {
        pendingRemoval = summary
    }

    /// Clears the announcement once the user has acknowledged it.
    func clearNotice() {
        notice = nil
    }

    /// Removes the profile and its stored file, then re-reads the library.
    func remove(_ summary: ProvisioningProfileSummary) async {
        guard let profiles else { return }
        do {
            try await profiles.remove(profileWithID: summary.id)
        } catch {
            notice = Notice(
                title: "Deletion Failed",
                message: (error as? ZynSignError)?.userMessage ?? "The profile could not be deleted."
            )
        }
        // A file cleanup can fail after catalog removal; in either case
        // refresh any signing view that had selected this saved profile.
        NotificationCenter.default.post(name: .zynsignProvisioningProfilesChanged, object: nil)
        await refresh()
    }
}

// MARK: - Previews

#Preview("Profiles") {
    ProfilesView(
        profiles: CompositionRoot.makeProvisioningProfileLibrary(),
        importer: nil
    )
    .environment(\.applicationEnvironment, CompositionRoot.makeApplicationEnvironment())
}
