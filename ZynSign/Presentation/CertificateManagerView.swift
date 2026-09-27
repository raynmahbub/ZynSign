import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// The Certificates area: ZynSign's certificate manager.
///
/// The screen presents the signed identities the secure store holds as a
/// library of professional cards — name, team, type, expiration state,
/// import date, and key availability — and offers the everyday identity
/// operations around it:
///
/// - **Import** a `.p12` / `.pfx` identity through the password sheet; the
///   password travels once to the importer and is never stored or shown
///   again.
/// - **Search** by name, team, or fingerprint while typing.
/// - **Filter** by expiration state (active / expiring soon / expired /
///   not yet valid), certificate type, and team.
/// - **Sort** by name, team, expiration, or import date.
/// - **Organise**: mark a default identity for future signing, rename the
///   display of an identity locally, copy a team ID, or remove a
///   registration.
///
/// Security follows ZynSign's architecture: the private key never leaves
/// the Keychain, is non-extractable, and is never displayed, logged, or
/// exported. What this screen shows is the certificate's public metadata,
/// the store's status snapshot, and the user's own local notes.
struct CertificateManagerView: View {

    @Environment(\\.applicationEnvironment) private var env
    @StateObject private var model: CertificateManagerModel
    @AppStorage("zynsign.certs.showsGrid") private var showsGrid = false

    // Import flow
    @State private var showImporter = false
    @State private var pendingData: Data?
    @State private var pendingFileName: String?
    @State private var showPasswordSheet = false
    @State private var showImportSummary = false

    // Quick actions
    @State private var itemPendingRemoval: CertificateManagerModel.CertificateItem?
    @State private var showDeleteConfirm = false
    @State private var itemPendingRename: CertificateManagerModel.CertificateItem?
    @State private var itemPendingDetails: CertificateManagerModel.CertificateItem?
    @State private var exportURL: URL?
    @State private var showExportShare = false

    // Toast
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastStyle: ZToast.Style = .success

    /// Creates the screen over the identity store, the local annotation
    /// store, and the importer the composition root supplied. The model
    /// owns the screen's state machine; the view renders it.
    init(
        store: any IdentityStore,
        annotations: (any IdentityAnnotationsStore)?,
        importer: any SigningIdentityImporter
    ) {
        _model = StateObject(
            wrappedValue: CertificateManagerModel(
                store: store,
                annotations: annotations,
                importer: importer
            )
        )
    }

    private var noticeBinding: Binding<Bool> {
        Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.clearNotice() } }
        )
    }

    var body: some View {
        content
            .navigationTitle(ShellSection.certificates.title)
            .navigationDestination(for: CertificateManagerModel.CertificateItem.self) { item in
                detailView(for: item)
            }
            .navigationDestination(item: $itemPendingDetails) { item in
                detailView(for: item)
            }
            .searchable(
                text: $model.searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: Text("Name, Team, or Fingerprint")
            )
            .toolbar { toolbarContent }
            .overlay(alignment: .bottom) {
                if let busyID = model.busyItemID {
                    HStack(spacing: ZSpacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("Working…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, ZSpacing.md)
                    .padding(.vertical, ZSpacing.xs)
                    .background(.bar)
                    .clipShape(Capsule())
                    .padding(.bottom, ZSpacing.sm)
                    // Decorative: the row the operation works on already
                    // carries the state in its accessibility element.
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("busy-item")
                }
            }
            .task { await model.load() }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.data, .item],
                allowsMultipleSelection: false
            ) { result in handlePicker(result) }
            .sheet(isPresented: $showPasswordSheet) {
                if let data = pendingData, let fileName = pendingFileName {
                    ImportIdentityPasswordSheet(
                        fileName: fileName,
                        isImporting: model.isImporting,
                        importError: model.importError,
                        onImport: { password in
                            Task { await runImport(data: data, password: password) }
                        },
                        onCancel: {
                            pendingData = nil
                            pendingFileName = nil
                            showPasswordSheet = false
                        }
                    )
                    .interactiveDismissDisabled(model.isImporting)
                }
            }
            .sheet(isPresented: $showImportSummary) {
                if let imported = model.importSummary {
                    ImportIdentitySummaryView(item: imported) {
                        model.clearImportSummary()
                        showImportSummary = false
                    }
                }
            }
            .sheet(isPresented: $showExportShare) {
                if let url = exportURL {
                    #if os(iOS)
                    ShareSheet(url: url)
                        .ignoresSafeArea()
                    #endif
                }
            }
            .sheet(item: $itemPendingRename) { item in
                RenameIdentitySheet(
                    initialLabel: item.displayLabel,
                    certificateName: item.commonName,
                    onSave: { label in
                        Task {
                            let cleared = (label?.isEmpty ?? true) && (item.displayLabel != nil)
                            if await model.setDisplayLabel(label, for: item) {
                                presentToast(
                                    cleared
                                        ? "Display label removed"
                                        : "Display label updated",
                                    style: .success
                                )
                            }
                        }
                    }
                )
            }
            .confirmationDialog(
                "Remove Identity?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible,
                presenting: itemPendingRemoval
            ) { item in
                Button("Remove Identity", role: .destructive) {
                    itemPendingRemoval = nil
                    Task {
                        if await model.remove(item) {
                            await env.signingDiagnostics?.identitiesDidChange()
                            NotificationCenter.default.post(name: .zynsignSigningIdentityChanged, object: nil)
                            presentToast("“\(item.displayName)” removed", style: .success)
                        }
                    }
                }
                Button("Cancel", role: .cancel) { itemPendingRemoval = nil }
            } message: { item in
                Text("“\(item.displayName)” will be forgotten. The signing key it borrowed stays with its provisioning component, and anything signed with it is unaffected. This cannot be undone.")
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
            .zToast(isPresented: $showToast, message: toastMessage, style: toastStyle)
            .onChange(of: model.importSummary) { _, new in
                if new != nil {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        showImportSummary = true
                    }
                }
            }
            .onChange(of: model.phase) { _, new in
                reconcileTeamFilter(with: new)
            }
    }

    /// The details screen for one certificate, shared by value navigation
    /// and the context menu's "View Details" action. The details screen
    /// reads the item live from the model by fingerprint, so a rename or a
    /// default change made on another screen is reflected without the
    /// pushed screen going stale.
    private func detailView(for item: CertificateManagerModel.CertificateItem) -> some View {
        CertificateDetailView(model: model, fingerprint: item.id)
    }

    // MARK: - Phases

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ScrollView {
                VStack(spacing: ZSpacing.sm) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: ZRadius.card)
                            .fill(Color(.tertiarySystemFill))
                            .frame(height: 96)
                    }
                }
                .padding(ZSpacing.sm)
                .redacted(reason: .placeholder)
            }
            .accessibilityLabel("Loading certificates")
        case .failed(let message):
            ContentUnavailableView {
                Label("Certificates Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await model.refresh() } }
                    .buttonStyle(.borderedProminent)
            }
        case .empty:
            emptyState
        case .loaded:
            libraryContent
        }
    }

    /// The empty state: friendly, short, and free of technical wording.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Certificates Yet", systemImage: "person.text.rectangle.badge.plus")
        } description: {
            Text("Add a certificate and it stays on this device, ready to sign your applications.")
        } actions: {
            Button("Import Certificate") { showImporter = true }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Library content

    /// The loaded library: the visible projection of the current search,
    /// filters, and sort, with explicit states when nothing matches.
    @ViewBuilder
    private var libraryContent: some View {
        let items = model.visibleItems()
        if items.isEmpty && !model.searchText.isEmpty {
            ContentUnavailableView.search(Text(model.searchText))
        } else if items.isEmpty && model.hasActiveFilters {
            ContentUnavailableView {
                Label("No Matching Certificates", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Every certificate is hidden by the current search or filters.")
            } actions: {
                Button("Clear Filters") { model.clearFilters() }
                    .buttonStyle(.borderedProminent)
            }
        } else if items.isEmpty {
            emptyState
        } else if showsGrid {
            libraryGrid(items)
        } else {
            libraryList(items)
        }
    }

    private func libraryList(_ items: [CertificateManagerModel.CertificateItem]) -> some View {
        List {
            if let defaultItem = model.defaultItem {
                Section {
                    NavigationLink(value: defaultItem) {
                        DefaultIdentityRow(item: defaultItem)
                    }
                } header: {
                    Text("Default for Future Signing")
                }
            }
            Section("Certificates (\(items.count))") {
                ForEach(items) { item in
                    row(for: item)
                }
            }
            Section {
                Label(
                    "Private keys stay on this device — never shown, logged, or exported.",
                    systemImage: "lock.shield"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.refresh() }
        .animation(.easeInOut(duration: 0.2), value: model.sortOrder)
        .animation(.easeInOut(duration: 0.2), value: model.expirationFilter)
        .animation(.easeInOut(duration: 0.2), value: model.kindFilter)
        .animation(.easeInOut(duration: 0.2), value: model.teamFilter)
    }

    private func libraryGrid(_ items: [CertificateManagerModel.CertificateItem]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 250), spacing: ZSpacing.md)],
                spacing: ZSpacing.md
            ) {
                ForEach(items) { item in
                    card(for: item)
                }
            }
            .padding(ZSpacing.sm)
            if let defaultItem = model.defaultItem,
               !items.contains(where: { $0.id == defaultItem.id }) {
                // The default is filtered out of the grid but still applies
                // to future signing; say so rather than hiding it.
                ZCard(variant: .outlined) {
                    HStack(spacing: ZSpacing.sm) {
                        CertificateIconWell(item: defaultItem, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Default: \(defaultItem.displayName)")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text("Default for future signing")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .padding(.horizontal, ZSpacing.sm)
            }
        }
        .refreshable { await model.refresh() }
        .animation(.easeInOut(duration: 0.2), value: model.sortOrder)
        .animation(.easeInOut(duration: 0.2), value: model.expirationFilter)
        .animation(.easeInOut(duration: 0.2), value: model.kindFilter)
        .animation(.easeInOut(duration: 0.2), value: model.teamFilter)
    }

    // MARK: - Rows and cards

    @ViewBuilder
    private func row(for item: CertificateManagerModel.CertificateItem) -> some View {
        NavigationLink(value: item) {
            CertificateRow(item: item)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if item.isDefault {
                Button {
                    Task {
                        if await model.clearDefault() {
                            presentToast("Default identity cleared", style: .info)
                        }
                    }
                } label: {
                    Label("Clear Default", systemImage: "star.slash")
                }
                .tint(.orange)
            } else {
                Button {
                    Task {
                        if await model.setDefault(item) {
                            presentToast("“\(item.displayName)” is now your default", style: .success)
                        }
                    }
                } label: {
                    Label("Set Default", systemImage: "star")
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                itemPendingRename = item
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.blue)
            Button(role: .destructive) {
                itemPendingRemoval = item
                showDeleteConfirm = true
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu {
            contextMenuActions(for: item)
        }
    }

    @ViewBuilder
    private func card(for item: CertificateManagerModel.CertificateItem) -> some View {
        NavigationLink(value: item) {
            CertificateCard(item: item)
        }
        .buttonStyle(.plain)
        .contextMenu {
            contextMenuActions(for: item)
        }
    }

    @ViewBuilder
    private func contextMenuActions(for item: CertificateManagerModel.CertificateItem) -> some View {
        Button {
            itemPendingDetails = item
        } label: {
            Label("View Details", systemImage: "info.circle")
        }
        if item.isDefault {
            Button {
                Task {
                    if await model.clearDefault() {
                        presentToast("Default identity cleared", style: .info)
                    }
                }
            } label: {
                Label("Clear Default", systemImage: "star.slash")
            }
        } else {
            Button {
                Task {
                    if await model.setDefault(item) {
                        presentToast("“\(item.displayName)” is now your default", style: .success)
                    }
                }
            } label: {
                Label("Set as Default", systemImage: "star")
            }
        }
        Button {
            itemPendingRename = item
        } label: {
            Label("Rename Display Label", systemImage: "pencil")
        }
        if let teamID = item.teamID {
            Button {
                copyToPasteboard(teamID, "Team ID copied")
            } label: {
                Label("Copy Team ID", systemImage: "doc.on.doc")
            }
        }
        Button(role: .destructive) {
            itemPendingRemoval = item
            showDeleteConfirm = true
        } label: {
            Label("Remove", systemImage: "trash")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if model.isImporting {
                ProgressView().accessibilityLabel("Importing certificate")
            } else if ReleaseTrain.isAvailable(.identityCenter),
                      let identityCenter = env.identityCenter {
                NavigationLink {
                    IdentityCenterView(service: identityCenter)
                } label: {
                    Label("Identity Center", systemImage: "person.badge.key.fill")
                }
                .accessibilityLabel("Developer Identity Center")
                .accessibilityHint("Opens teams, health, conflicts, and the expiration forecast.")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            sortMenu
            filterMenu
            layoutToggle
            Button {
                showImporter = true
            } label: {
                Label("Import Certificate…", systemImage: "plus")
            }
            .disabled(model.isImporting)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $model.sortOrder) {
                ForEach(CertificateManagerModel.SortOrder.allCases) { order in
                    Text(order.displayName).tag(order)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort certificates")
    }

    private var filterMenu: some View {
        Menu {
            Picker("Status", selection: $model.expirationFilter) {
                ForEach(CertificateManagerModel.ExpirationFilter.allCases) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            Picker("Type", selection: $model.kindFilter) {
                ForEach(CertificateManagerModel.KindFilter.allCases) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            Picker("Team", selection: teamFilterBinding) {
                Text("All Teams").tag(String?.none)
                ForEach(model.teamOptions) { option in
                    Text(option.displayName).tag(String?.some(option.id))
                }
            }
            if model.hasActiveFilters {
                Divider()
                Button {
                    model.clearFilters()
                } label: {
                    Label("Clear Filters", systemImage: "xmark.circle")
                }
            }
        } label: {
            Label(
                "Filters",
                systemImage: model.hasActiveFilters
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .accessibilityLabel("Filter certificates")
    }

    private var teamFilterBinding: Binding<String?> {
        Binding(
            get: { model.teamFilter },
            set: { model.teamFilter = $0 }
        )
    }

    private var layoutToggle: some View {
        Button {
            ZHaptics.tap()
            withAnimation(.easeInOut(duration: 0.2)) {
                showsGrid.toggle()
            }
        } label: {
            Label(
                showsGrid ? "List View" : "Grid View",
                systemImage: showsGrid ? "list.bullet" : "square.grid.2x2"
            )
        }
        .accessibilityLabel(showsGrid ? "Switch to list view" : "Switch to grid view")
    }

    // MARK: - Import

    private func handlePicker(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let ext = url.pathExtension.lowercased()
            guard ext == "p12" || ext == "pfx" else {
                presentToast("That file is not a certificate. Choose a .p12 or .pfx file.", style: .warning)
                return
            }
            guard let data = try? Data(contentsOf: url) else {
                presentToast("The selected file could not be read.", style: .error)
                return
            }
            guard !data.isEmpty, data.count <= 10 * 1024 * 1024 else {
                presentToast("The selected file is empty or too large.", style: .error)
                return
            }
            pendingData = data
            pendingFileName = url.lastPathComponent
            showPasswordSheet = true
        case .failure(let error):
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return }
            presentToast("The file picker could not provide the selected file.", style: .error)
        }
    }

    /// Runs the import the password sheet confirmed.
    ///
    /// On success the sheet closes, the bytes are dropped, and the model's
    /// import summary takes over as the success view. On failure the sheet
    /// stays open with the reason, so the user can correct the password and
    /// retry — the password entered is never written anywhere; it lives in
    /// the sheet's own state until the sheet goes away.
    private func runImport(data: Data, password: String) async {
        let imported = await model.performImport(data: data, password: password)
        if imported != nil {
            await env.signingDiagnostics?.identitiesDidChange()
            NotificationCenter.default.post(name: .zynsignSigningIdentityChanged, object: nil)
            pendingData = nil
            pendingFileName = nil
            showPasswordSheet = false
            env.recordAnalyticsEvent(
                category: .certificate,
                name: "certificate.imported",
                succeeded: true
            )
        } else {
            env.recordAnalyticsEvent(
                category: .certificate,
                name: "certificate.importFailed",
                succeeded: false
            )
        }
    }

    // MARK: - Helpers

    /// The team filter names a team that no longer exists (its last
    /// identity was removed), so it would hide everything; clear it.
    private func reconcileTeamFilter(with phase: CertificateManagerModel.Phase) {
        guard case .loaded = phase, let selected = model.teamFilter else { return }
        if !model.teamOptions.contains(where: { $0.id == selected }) {
            model.teamFilter = nil
        }
    }

    private func copyToPasteboard(_ value: String, _ toastText: String) {
        #if os(iOS)
        UIPasteboard.general.string = value
        #endif
        ZHaptics.tap()
        presentToast(toastText, style: .info)
    }

    private func presentToast(_ message: String, style: ZToast.Style = .success) {
        toastMessage = message
        toastStyle = style
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            showToast = true
        }
    }

    /// Builds and shares the public-metadata backup of an identity. The
    /// backup carries certificate facts only; the private key never leaves
    /// the Keychain.
    private func presentExport(_ item: CertificateManagerModel.CertificateItem) {
        do {
            let service = CertificateExportService()
            exportURL = try service.backupURL(for: item.identity)
            showExportShare = true
        } catch {
            presentToast("The certificate backup could not be created.", style: .error)
        }
    }
}

// MARK: - Row

/// One certificate in the list: the status-tinted key mark, the display
/// name and the certificate's own name, the badges its state earns, and the
/// team and import date. Words carry the meaning; colour only reinforces it.
struct CertificateRow: View {
    let item: CertificateManagerModel.CertificateItem

    var body: some View {
        HStack(spacing: ZSpacing.sm) {
            CertificateIconWell(item: item)
            VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                HStack(spacing: ZSpacing.xs) {
                    Text(item.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    if item.isDefault {
                        ZStatusBadge("Default", systemImage: "star.fill", kind: .info)
                    }
                }
                Text(item.commonName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: ZSpacing.xs) {
                    CertificateBadges.expiration(for: item)
                    CertificateBadges.kind(for: item)
                    CertificateBadges.key(for: item)
                }
                metaLine
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Opens the certificate's details")
    }

    @ViewBuilder
    private var metaLine: some View {
        HStack(spacing: 4) {
            if let team = item.teamName ?? item.teamID {
                Text(team)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let imported = item.importedAt {
                if item.teamName != nil || item.teamID != nil {
                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(imported, format: .dateTime.year().month(.abbreviated).day())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var accessibilityDescription: String {
        var parts: [String] = [item.displayName]
        if item.isDefault { parts.append("default identity") }
        parts.append(item.commonName)
        parts.append(CertificateBadges.expirationSpeech(for: item))
        parts.append(item.kind.displayName)
        switch item.identity.keyAvailability {
        case .available: parts.append("key available")
        case .unavailable: parts.append("key unavailable")
        case .unknown: parts.append("key status unknown")
        }
        if let team = item.teamName ?? item.teamID { parts.append("team \(team)") }
        if let imported = item.importedAt {
            parts.append("imported \(imported.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Card

/// One certificate as a grid card: the status-tinted key mark, the display
/// name, the team, the state badges, and the import date.
struct CertificateCard: View {
    let item: CertificateManagerModel.CertificateItem

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            HStack(alignment: .top, spacing: ZSpacing.xs) {
                CertificateIconWell(item: item, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(teamLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if item.isDefault {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .accessibilityLabel("Default identity")
                }
            }
            HStack(spacing: ZSpacing.xs) {
                CertificateBadges.expiration(for: item)
                CertificateBadges.kind(for: item)
            }
            HStack(spacing: 4) {
                Text(keyStatusLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let imported = item.importedAt {
                    Text("Imported \(imported, format: .dateTime.month(.abbreviated).day().year())")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(ZSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zynCardBackground(cornerRadius: ZRadius.lg)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Opens the certificate's details")
    }

    private var teamLine: String {
        [item.teamName, item.teamID]
            .compactMap { $0 }
            .joined(separator: " • ")
            .ifEmpty("No team declared")
    }

    private var keyStatusLine: String {
        switch item.identity.keyAvailability {
        case .available: return "Key available"
        case .unavailable: return "Key unavailable"
        case .unknown: return "Key status unknown"
        }
    }

    private var accessibilityDescription: String {
        var parts: [String] = [item.displayName]
        if item.isDefault { parts.append("default identity") }
        parts.append(teamLine)
        parts.append(CertificateBadges.expirationSpeech(for: item))
        parts.append(item.kind.displayName)
        return parts.joined(separator: ", ")
    }
}

// MARK: - Default identity row

/// The header row that names the default identity: the one ZynSign will use
/// for future signing.
struct DefaultIdentityRow: View {
    let item: CertificateManagerModel.CertificateItem

    var body: some View {
        HStack(spacing: ZSpacing.sm) {
            CertificateIconWell(item: item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(item.teamName ?? item.teamID ?? item.commonName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            ZStatusBadge("Default", systemImage: "star.fill", kind: .info)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Default identity for future signing: \(item.displayName)")
    }
}

// MARK: - Icon well

/// The certificate's key mark: a status-tinted rounded square carrying the
/// key algorithm's glyph. Colour here reinforces the state the badges and
/// speech already say in words.
struct CertificateIconWell: View {
    let item: CertificateManagerModel.CertificateItem
    var size: CGFloat = 44

    var body: some View {
        RoundedRectangle(cornerRadius: ZRadius.icon, style: .continuous)
            .fill(statusColor.opacity(0.15))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch item.identity.certificate.publicKeyInfo.algorithm {
        case .rsa: return "key.fill"
        case .ec: return "key.viewfinder"
        case .unknown: return "key"
        }
    }

    private var statusColor: Color {
        switch item.expiration.status {
        case .healthy: return .green
        case .expiringSoon: return .orange
        case .expired: return .red
        case .notYetValid: return .blue
        }
    }
}

// MARK: - Badges

/// The semantic badges one certificate carries. The only place the state's
/// colour is chosen; rows and cards never pick colours themselves.
enum CertificateBadges {

    /// The expiration state badge.
    static func expiration(for item: CertificateManagerModel.CertificateItem) -> ZStatusBadge {
        switch item.expiration.status {
        case .healthy:
            return ZStatusBadge("Healthy", systemImage: "checkmark.circle.fill", kind: .success)
        case .expiringSoon:
            let days = max(item.expiration.remainingDays ?? 0, 0)
            return ZStatusBadge("\(days)d left", systemImage: "clock.badge.exclamationmark", kind: .warning)
        case .expired:
            return ZStatusBadge("Expired", systemImage: "xmark.circle.fill", kind: .error)
        case .notYetValid:
            return ZStatusBadge("Not Yet Valid", systemImage: "clock", kind: .info)
        }
    }

    /// The certificate purpose badge.
    static func kind(for item: CertificateManagerModel.CertificateItem) -> ZStatusBadge {
        let icon: String
        switch item.kind {
        case .development: icon = "chevron.left.forwardslash.chevron.right"
        case .distribution: icon = "shippingbox.fill"
        case .other: icon = "questionmark.circle"
        }
        return ZStatusBadge(item.kind.displayName, systemImage: icon, kind: .neutral)
    }

    /// The private-key availability badge.
    static func key(for item: CertificateManagerModel.CertificateItem) -> ZStatusBadge {
        switch item.identity.keyAvailability {
        case .available:
            return ZStatusBadge("Key Ready", systemImage: "checkmark.seal.fill", kind: .info)
        case .unavailable:
            return ZStatusBadge("Key Unavailable", systemImage: "key.slash", kind: .warning)
        case .unknown:
            return ZStatusBadge("Key Unknown", systemImage: "questionmark.circle", kind: .neutral)
        }
    }

    /// The expiration state in words, for VoiceOver and speech summaries.
    static func expirationSpeech(for item: CertificateManagerModel.CertificateItem) -> String {
        switch item.expiration.status {
        case .healthy:
            if let days = item.expiration.remainingDays {
                return "healthy, \(days) days remaining"
            }
            return "healthy"
        case .expiringSoon:
            if let days = item.expiration.remainingDays {
                return "expiring soon, \(days) days remaining"
            }
            return "expiring soon"
        case .expired:
            if let days = item.expiration.remainingDays, days < 0 {
                return "expired \(-days) days ago"
            }
            return "expired"
        case .notYetValid:
            return "not yet valid"
        }
    }
}

// MARK: - Small helpers

private extension String {
    func ifEmpty(_ replacement: String) -> String {
        isEmpty ? replacement : self
    }
}

/// The system share sheet for a generated file, wrapped for SwiftUI.
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ ui: UIActivityViewController, context: Context) {}
}

// MARK: - Previews

private let previewEnvironment = CompositionRoot.makeApplicationEnvironment()

#Preview("Certificates (empty)") {
    NavigationStack {
        CertificateManagerView(
            store: previewEnvironment.identityStore,
            annotations: previewEnvironment.identityAnnotations,
            importer: previewEnvironment.pkcs12Importer
        )
        .navigationTitle("Certificates")
    }
    .environment(\.applicationEnvironment, previewEnvironment)
}
