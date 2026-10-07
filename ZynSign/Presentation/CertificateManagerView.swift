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

    @Environment(\.applicationEnvironment) private var env
    @StateObject private var model: CertificateManagerModel
    @AppStorage("zynsign.certs.showsGrid") private var showsGrid = false

    /// An identity handed to ZynSign through Open In, when present.
    let initialImportURL: URL?
    let onInitialImportConsumed: (() -> Void)?
    @State private var handledIncomingURL: URL? = nil

    // Import flow
    @State private var showImporter = false
    @State private var isOpeningCertificatePicker = false
    @State private var isReadingSelectedFile = false
    @State private var pendingData: Data?
    @State private var pendingFileName: String?
    @State private var showPasswordSheet = false
    @State private var isPresentingPasswordSheet = false
    @State private var showImportSummary = false
    @State private var isPresentingImportSummary = false
    @State private var wantsImportSummaryAfterPasswordDismissal = false

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
        importer: any SigningIdentityImporter,
        initialImportURL: URL? = nil,
        onInitialImportConsumed: (() -> Void)? = nil
    ) {
        self.initialImportURL = initialImportURL
        self.onInitialImportConsumed = onInitialImportConsumed
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
        // The phase swap — skeleton to library, library to a failure — fades
        // rather than snapping: the branches carry the default insertion
        // transition, and the animation is keyed on the phase alone so a
        // search keystroke or a rename never re-animates the list.
        ZStack { content }
            .animation(ZMotion.standard, value: model.phase)
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
            .task {
                await model.load()
                if let initialImportURL { handleIncomingImport(initialImportURL) }
            }
            .onChange(of: initialImportURL) { _, url in
                if let url { handleIncomingImport(url) }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: Self.importableContentTypes,
                allowsMultipleSelection: false
            ) { result in handlePicker(result) }
            .sheet(isPresented: $showPasswordSheet, onDismiss: { passwordSheetDidDismiss() }) {
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
                        ZSkeletonCertificateRow()
                            .padding(.horizontal)
                    }
                }
                .padding(.top, ZSpacing.sm)
            }
            .accessibilityLabel("Loading certificates")
        case .failed(let message):
            ZErrorView(
                title: "Certificates Unavailable",
                explanation: message,
                suggestedAction: "Verify iOS Keychain access or re-import your PKCS#12 identity.",
                technicalDetails: "CertificateManager read failure: \(message)",
                onRetry: { Task { await model.refresh() } }
            )
        case .empty:
            emptyState
        case .loaded:
            libraryContent
        }
    }

    /// The empty state: friendly, short, and free of technical wording.
    private var emptyState: some View {
        ZEmptyState.noCertificates {
            requestCertificatePicker()
        }
    }

    // MARK: - Library content

    /// The loaded library: the visible projection of the current search,
    /// filters, and sort, with explicit states when nothing matches.
    @ViewBuilder
    private var libraryContent: some View {
        let items = model.visibleItems()
        if items.isEmpty && !model.searchText.isEmpty {
            ZEmptyState.noSearchResults(query: model.searchText) {
                model.searchText = ""
            }
        } else if items.isEmpty && model.hasActiveFilters {
            ZEmptyState(
                title: "No Matching Certificates",
                message: "Every certificate is hidden by the current search or filters.",
                systemImage: "line.3.horizontal.decrease.circle",
                tint: .purple,
                primaryActionTitle: "Clear Filters",
                primaryAction: { model.clearFilters() }
            )
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
        .animation(ZMotion.fast, value: model.sortOrder)
        .animation(ZMotion.fast, value: model.expirationFilter)
        .animation(ZMotion.fast, value: model.kindFilter)
        .animation(ZMotion.fast, value: model.teamFilter)
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
        .animation(ZMotion.fast, value: model.sortOrder)
        .animation(ZMotion.fast, value: model.expirationFilter)
        .animation(ZMotion.fast, value: model.kindFilter)
        .animation(ZMotion.fast, value: model.teamFilter)
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
            if model.isImporting || isReadingSelectedFile {
                ProgressView().accessibilityLabel(isReadingSelectedFile ? "Reading certificate file" : "Importing certificate")
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
                requestCertificatePicker()
            } label: {
                Label("Import Certificate…", systemImage: "plus")
            }
            .disabled(
                model.isImporting || isOpeningCertificatePicker || isReadingSelectedFile
                    || pendingData != nil || showPasswordSheet
            )
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
            withAnimation(ZMotion.fast) {
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

    private static var importableContentTypes: [UTType] {
        var types: Set<UTType> = [.data, .item]
        if let p12 = UTType(filenameExtension: "p12") { types.insert(p12) }
        if let pfx = UTType(filenameExtension: "pfx") { types.insert(pfx) }
        if let rsa = UTType("com.rsa.pkcs-12") { types.insert(rsa) }
        if let ms = UTType("com.microsoft.pkcs12") { types.insert(ms) }
        return Array(types)
    }

    /// Presents the system picker from the stable Certificates screen.
    ///
    /// A document picker is owned by SwiftUI's `.fileImporter` presentation
    /// binding. Requiring an unrelated UIKit view-controller identity change
    /// before keeping that binding true can reset a valid request before the
    /// system picker appears, so this path only waits for the current transition
    /// to settle and then lets SwiftUI present it.
    private func requestCertificatePicker() {
        guard !isOpeningCertificatePicker,
              !model.isImporting,
              !isReadingSelectedFile,
              pendingData == nil,
              !showPasswordSheet else { return }
        isOpeningCertificatePicker = true
        Task { @MainActor in
            defer { isOpeningCertificatePicker = false }
            _ = await PresentationSettle.waitForIdle()
            guard !Task.isCancelled else { return }
            showImporter = true
        }
    }

    private func handlePicker(_ result: Result<[URL], any Error>) {
        showImporter = false
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            if urls.count > 1 {
                // One identity at a time is the model's rule, and a picker that
                // let the person tick three files has to say what happened to
                // the other two instead of quietly dropping them.
                presentToast("ZynSign imports one certificate file at a time. The other selected files were not read — choose one again when this import is finished.", style: .warning)
            }
            beginReadingSelectedFile(at: url)
        case .failure(let error):
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return }
            presentToast("The file picker could not provide the selected file.", style: .error)
        }
    }

    /// Starts the same coordinated read for picker-selected and Open In files.
    private func beginReadingSelectedFile(at url: URL) {
        guard !isReadingSelectedFile,
              !model.isImporting,
              pendingData == nil,
              !showPasswordSheet else {
            // Swallowing the file the person just chose is how this screen
            // starts to feel stuck. Saying what is busy, and what to do about
            // it, is the same answer Open In already gives.
            presentToast("Finish the current certificate import before opening another file.", style: .warning)
            return
        }
        // The name is not the verdict. The reader — which accepts a matching
        // `.p12`/`.pfx`, sniffs content for a name Files rewrote, and refuses
        // a foreign format by type — decides, and its typed failure becomes
        // the message. Pre-judging the extension here is what hid valid
        // certificates AirDrop had renamed.

        // File providers may vend placeholder or coordinated URLs rather
        // than a directly readable local path. Read off the main actor,
        // acquire security-scoped access for the read, and keep the
        // password sheet ready when read completes.
        let accessing = url.startAccessingSecurityScopedResource()
        let reader = env.pkcs12DocumentReader
        isReadingSelectedFile = true
        Task { @MainActor in
            defer {
                isReadingSelectedFile = false
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try reader.readPKCS12(at: url)
                }.value
                pendingData = data
                pendingFileName = url.lastPathComponent
                presentPasswordSheetAfterPickerSettles()
            } catch {
                presentToast(readFailureMessage(for: error), style: .error)
            }
        }
    }

    /// Handles a URL handed over by another app ("Open In ZynSign").
    ///
    /// The read itself is `beginReadingSelectedFile`'s, guard and all: an
    /// Open In file and a picked file must be answered identically, and the
    /// only thing that differs is that a handed-over URL must not be read
    /// twice.
    private func handleIncomingImport(_ url: URL) {
        guard handledIncomingURL != url else { return }
        handledIncomingURL = url
        onInitialImportConsumed?()
        beginReadingSelectedFile(at: url)
    }

    /// What to say when the chosen file never reached the importer.
    ///
    /// Each reason names the fix a person can actually try: an "empty"
    /// certificate is usually an iCloud placeholder whose bytes have not
    /// arrived, and a format refusal has to say why a `.cer` or a `.pem`
    /// cannot stand in for a `.p12` — it carries no private key.
    private func readFailureMessage(for error: any Error) -> String {
        switch error as? PKCS12DocumentReadError {
        case .unsupportedFileType:
            return "That file is not a PKCS#12 certificate container. Choose the .p12 or .pfx your Apple developer tools exported — a .cer, .pem, or .der holds no private key, so it cannot be imported here."
        case .emptyFile:
            return "The selected certificate file has no content on this device yet. If it lives in iCloud Drive, open it once in Files so it downloads, then choose it again."
        case .fileTooLarge:
            return "The selected certificate file is larger than the 10 MiB limit. A signing identity is a few kilobytes; this file is something else."
        case .unreadable, .none:
            return "The selected certificate file could not be read from its file provider. Try saving it to Files and choosing it again."
        }
    }

    /// Presents the password sheet only after the picker has fully left the
    /// presented-controller chain. The picker callback may arrive while its
    /// child controller is still dismissing; the shared helper waits for that
    /// child and confirms that the password form appeared.
    private func presentPasswordSheetAfterPickerSettles() {
        guard !isPresentingPasswordSheet, !showPasswordSheet else { return }
        isPresentingPasswordSheet = true
        Task { @MainActor in
            defer { isPresentingPasswordSheet = false }
            guard pendingData != nil, pendingFileName != nil else { return }
            for _ in 0..<2 {
                let appeared = await PresentationSettle.presentAndConfirm {
                    withAnimation(ZMotion.interactive) {
                        showPasswordSheet = true
                    }
                }
                if appeared { return }
                showPasswordSheet = false
                await Task.yield()
            }

            // Do not leave the import controls disabled if UIKit rejected both
            // presentations. The user can choose the file again after seeing
            // this explicit recovery instruction.
            pendingData = nil
            pendingFileName = nil
            presentToast("The certificate was read, but its password form could not be opened. Choose the file again to retry.", style: .error)
        }
    }

    /// Handles a password-sheet dismissal after UIKit has completed it. A
    /// swipe-to-dismiss clears unconfirmed bytes so Import is not stranded;
    /// successful imports use this platform callback to sequence the summary
    /// after the password sheet is actually gone.
    private func passwordSheetDidDismiss() {
        let shouldPresentSummary = wantsImportSummaryAfterPasswordDismissal
        wantsImportSummaryAfterPasswordDismissal = false
        if !model.isImporting, model.importSummary == nil {
            pendingData = nil
            pendingFileName = nil
        }
        guard shouldPresentSummary else { return }
        Task { @MainActor in
            let summaryAppeared = await presentImportSummaryAfterPasswordSheet()
            if !summaryAppeared {
                presentToast("Certificate imported successfully. It is now in your certificate list.", style: .success)
            }
        }
    }

    /// Opens the success summary after the password sheet's dismissal has
    /// completed. Requesting two sheets in the same update was another silent
    /// UIKit drop: the success state is now sequenced and confirmed.
    private func presentImportSummaryAfterPasswordSheet() async -> Bool {
        guard model.importSummary != nil, !isPresentingImportSummary else { return false }
        isPresentingImportSummary = true
        defer { isPresentingImportSummary = false }
        for _ in 0..<2 {
            let appeared = await PresentationSettle.presentAndConfirm {
                withAnimation(ZMotion.interactive) {
                    showImportSummary = true
                }
            }
            if appeared { return true }
            showImportSummary = false
            await Task.yield()
        }
        return false
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
            // Arm the dismissal hand-off before the first suspension. The
            // user can dismiss interactively as soon as the importer clears
            // `isImporting`, so the summary must already be waiting for the
            // platform's onDismiss callback.
            pendingData = nil
            pendingFileName = nil
            wantsImportSummaryAfterPasswordDismissal = true
            showPasswordSheet = false
            NotificationCenter.default.post(name: .zynsignSigningIdentityChanged, object: nil)
            await env.signingDiagnostics?.identitiesDidChange()
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
        withAnimation(ZMotion.interactive) {
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

private let previewEnvironment = CompositionRoot.fallbackEnvironment

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
