import SwiftUI

/// The Applications area of the shell: ZynSign's application library.
///
/// The screen presents the persisted records of accepted imports and offers
/// the everyday library operations — opening an application's detail screen
/// (and from there the read-only bundle explorer), marking favourites, and
/// deleting entries together with the package files behind them, one at a
/// time or in a selection. Its import action opens the shell's Import Hub,
/// which also takes files dropped onto the screen, and its model follows the
/// same hub, so a package imported from anywhere in the application appears
/// here without any manual refreshing.
///
/// Where the release exposes the library's power features, the screen grows
/// into a library manager for hundreds of applications: statistics that
/// double as shortcuts; a scope bar with All Apps, the smart collections
/// (Favorites, Recently Imported, Recently Signed, Unsigned, Expiring Soon),
/// and the user's collections; stackable filters; seven orders, the chosen
/// one remembered; instant search across names, identifiers, versions,
/// declared developers and teams, and collection names, with matches
/// highlighted; per-application quick actions as swipe actions and context
/// menus; and a floating bar of bulk actions while applications are
/// selected.
///
/// Nothing here pretends to sign or to verify signatures: the signed state
/// is read from the on-device signing journal, Verify compares package bytes
/// with the fingerprint recorded at import, and a card whose package file
/// has drifted from its record says so.
struct ApplicationLibraryView: View {

    @StateObject private var model: ApplicationLibraryModel
    @Environment(\.importPresentation) private var importPresentation
    @Environment(\.signingQueuePresentation) private var signingQueuePresentation
    @Environment(\.applicationEnvironment) private var environment

    /// The applications awaiting a signing-queue configuration, when the
    /// user asked to queue one or several.
    @State private var queueConfiguration: SigningQueueConfigurationRequest?
    @State private var presetQueue: PresetQueuePresentation?
    @State private var path: [LibraryRoute] = []
    @State private var sheet: LibrarySheet? = nil
    @State private var entryPendingRemoval: LibraryEntry? = nil
    @State private var selectionPendingRemoval: [LibraryEntry] = []
    @State private var hasAppliedStoredPreferences = false
    @AppStorage(LibraryPreferenceKeys.showsGrid) private var showsGrid = false
    @AppStorage(LibraryPreferenceKeys.sortOrder) private var storedSortOrder = LibrarySortMode.recentlyImported.rawValue
    @AppStorage(LibraryPreferenceKeys.scope) private var storedScope = LibraryScope.all.storageValue
    @ScaledMetric(relativeTo: .body) private var gridMinimumWidth: CGFloat = 108

    private let bundleInspection: IPABundleContentsInspection
    private let detailsInspection: IPAApplicationDetailsInspection
    private let features = LibraryFeatureAvailability.current

    /// Creates the screen over the use cases the composition root supplied.
    ///
    /// The Import Hub is the application's single import path: the library
    /// model observes it, so a package that reaches the library from any
    /// entry point refreshes this list. Bundle browsing and the complete App
    /// Details report are handed on to each detail screen. Everything after
    /// them is optional: the signing journal (read-only; `nil` means no entry
    /// shows as signed), the organizer (collections and usage), the
    /// provenance source (declared developer and team), and the exporter.
    init(
        library: ApplicationLibrary,
        hub: ImportHub,
        bundleInspection: IPABundleContentsInspection,
        detailsInspection: IPAApplicationDetailsInspection,
        signingHistory: (any SigningHistoryStore)? = nil,
        organizer: LibraryOrganizer? = nil,
        provenance: ApplicationProvenanceExtraction? = nil,
        exporter: LibraryExportPreparation? = nil,
        performanceEngine: PerformanceEngine? = nil
    ) {
        _model = StateObject(wrappedValue: ApplicationLibraryModel(
            library: library,
            hub: hub,
            signingHistory: signingHistory,
            organizer: organizer,
            provenance: provenance,
            exporter: exporter,
            performanceEngine: performanceEngine
        ))
        self.bundleInspection = bundleInspection
        self.detailsInspection = detailsInspection
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(model.scopeTitle ?? ShellSection.library.title)
                .navigationDestination(for: LibraryRoute.self) { route in
                    destination(for: route)
                }
                .searchable(
                    text: $model.searchText,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: Text(features.powerFeatures ? "Name, Bundle ID, Developer, Team…" : "Name or Bundle ID")
                )
                .toolbar { toolbarContent }
                .safeAreaInset(edge: .top) { ReleaseReadinessLink().padding(.horizontal).padding(.vertical, 6) }
                .safeAreaInset(edge: .bottom) { floatingBar }
                .disabled(model.isRemovingSelection)
                // Files dropped anywhere on the Library go to the Import Hub.
                .importDropTarget()
        }
        .task { await prepare() }
        .onChange(of: storedScope) { _, newValue in
            applyStoredScope(newValue)
        }
        .onChange(of: model.scope) { _, newValue in
            if storedScope != newValue.storageValue {
                storedScope = newValue.storageValue
            }
        }
        .onChange(of: model.sortOrder) { _, newValue in
            storedSortOrder = newValue.rawValue
        }
        .onChange(of: model.selection) { oldValue, newValue in
            announceSelectionChange(from: oldValue, to: newValue)
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
        .confirmationDialog(
            "Delete Application?",
            isPresented: Binding(
                get: { entryPendingRemoval != nil },
                set: { if !$0 { entryPendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: entryPendingRemoval
        ) { entry in
            Button("Delete Application", role: .destructive) {
                entryPendingRemoval = nil
                leaveScreens(for: entry.record.id)
                Task { await model.remove(entry) }
            }
            Button("Cancel", role: .cancel) {
                entryPendingRemoval = nil
            }
        } message: { entry in
            Text("“\(ApplicationLibraryRowContent(entry: entry).name)” and its package file will be permanently deleted from ZynSign's library. This cannot be undone.")
        }
        .confirmationDialog(
            "Delete Selected Applications?",
            isPresented: Binding(
                get: { !selectionPendingRemoval.isEmpty },
                set: { if !$0 { selectionPendingRemoval = [] } }
            ),
            titleVisibility: .visible,
            presenting: selectionPendingRemoval
        ) { entries in
            Button("Delete \(entries.count) Application\(entries.count == 1 ? "" : "s")", role: .destructive) {
                let pending = selectionPendingRemoval
                selectionPendingRemoval = []
                model.setSelecting(false)
                Task {
                    await model.removeEntries(pending)
                    LibraryAnnouncer.announce("Deleted \(ApplicationLibraryModel.applicationCount(pending.count))")
                }
            }
            Button("Cancel", role: .cancel) {
                selectionPendingRemoval = []
            }
        } message: { entries in
            Text("\(entries.count) application\(entries.count == 1 ? "" : "s") and \(entries.count == 1 ? "its" : "their") package file\(entries.count == 1 ? "" : "s") will be permanently deleted from ZynSign's library. Collections they belong to keep their other apps. This cannot be undone.")
        }
        .sheet(item: $sheet) { sheet in
            sheetContent(sheet)
        }
        .sheet(item: $queueConfiguration) { request in
            SigningQueueConfigurationView(
                entries: request.entries,
                origin: request.origin,
                onOpenQueue: { signingQueuePresentation.present() },
                onDone: { queueConfiguration = nil }
            )
        }
        .sheet(item: $presetQueue) { request in
            ProfessionalSigningQueueView(lockedEntries: request.entries)
        }
        .sheet(item: verificationBinding) { report in
            LibraryVerificationReportView(report: report)
        }
        .sheet(item: exportBinding) { bundle in
            LibraryShareSheet(items: bundle.fileURLs) {
                model.finishExport()
            }
            .presentationDetents([.medium, .large])
            .ignoresSafeArea()
        }
        .zToast(
            isPresented: confirmationBinding,
            message: model.confirmation?.message ?? "",
            style: .success
        )
    }

    // MARK: - Bindings

    private var noticeBinding: Binding<Bool> {
        Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.clearNotice() } }
        )
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { model.confirmation != nil },
            set: { if !$0 { model.clearConfirmation() } }
        )
    }

    private var verificationBinding: Binding<ApplicationLibraryModel.VerificationReport?> {
        Binding(
            get: { model.verificationReport },
            set: { if $0 == nil { model.clearVerificationReport() } }
        )
    }

    private var exportBinding: Binding<LibraryExportBundle?> {
        Binding(
            get: { model.exportBundle },
            set: { if $0 == nil { model.finishExport() } }
        )
    }

    // MARK: - Phases

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ApplicationLibraryLoadingView()
        case .empty:
            emptyContent
        case .failed(let message):
            ApplicationLibraryFailureView(message: message) {
                Task { await model.load() }
            }
        case .loaded:
            if showsGrid {
                libraryGrid
            } else {
                libraryList
            }
        }
    }

    private var emptyContent: some View {
        ZEmptyState.noApps {
            importPresentation.present()
        }
    }

    // MARK: - List and grid

    /// The loaded library as rows. The list is virtualised — rows are built
    /// only as they scroll into view — and each row is an equatable value,
    /// so a change to one entry re-renders that row alone.
    private var libraryList: some View {
        List {
            if features.powerFeatures {
                Section {
                    header
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            if let reason = model.emptyReason {
                Section {
                    emptyResults(reason)
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(model.renderedIDs, id: \.self) { id in
                        libraryRow(id)
                            .onAppear { model.rowDidAppear(id) }
                    }
                    if model.unrenderedCount > 0 {
                        LibraryRenderMoreRow(remaining: model.unrenderedCount) {
                            model.showAllRows()
                        }
                    }
                } header: {
                    if features.powerFeatures {
                        Text(resultSummary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.refresh() }
    }

    /// The loaded library as a lazily built grid of cards.
    private var libraryGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZSpacing.sm) {
                if features.powerFeatures {
                    header
                    Text(resultSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, ZSpacing.md)
                }
                if let reason = model.emptyReason {
                    emptyResults(reason)
                        .padding(.top, ZSpacing.xl)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: gridMinimumWidth), spacing: ZSpacing.sm)],
                        spacing: ZSpacing.sm
                    ) {
                        ForEach(model.renderedIDs, id: \.self) { id in
                            gridCard(id)
                                .onAppear { model.rowDidAppear(id) }
                        }
                    }
                    .padding(.horizontal, ZSpacing.sm)
                    if model.unrenderedCount > 0 {
                        LibraryRenderMoreRow(remaining: model.unrenderedCount) {
                            model.showAllRows()
                        }
                        .padding(.horizontal, ZSpacing.md)
                    }
                }
            }
            .padding(.vertical, ZSpacing.sm)
        }
        .refreshable { await model.refresh() }
    }

    /// Statistics, scopes, and active filters, above the results.
    private var header: some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            LibraryStatisticsCard(
                statistics: model.statistics,
                showsSigning: features.signing,
                onSelect: handleStatisticSelection
            )
            .padding(.horizontal, ZSpacing.md)
            LibraryScopeBar(
                items: scopeItems,
                selection: model.scope,
                onSelect: selectScope,
                onNewCollection: model.canOrganize ? startNewCollection : nil,
                onManage: model.canOrganize ? manageCollections : nil
            )
            if !model.filters.isEmpty {
                LibraryActiveFilterBar(
                    items: activeFilterItems,
                    onRemove: { model.toggleFilter($0) },
                    onClear: { model.filters = [] }
                )
            }
        }
        .padding(.vertical, ZSpacing.xs)
    }

    private var resultSummary: String {
        let shown = model.visibleIDs.count
        let total = model.scopeCounts[model.scope] ?? shown
        if model.isNarrowing && shown != total {
            return "\(shown) of \(ApplicationLibraryModel.applicationCount(total)) · \(model.sortOrder.displayName)"
        }
        return "\(ApplicationLibraryModel.applicationCount(shown)) · \(model.sortOrder.displayName)"
    }

    // MARK: - Rows and cards

    @ViewBuilder
    private func libraryRow(_ id: ApplicationRecordIdentifier) -> some View {
        if let state = model.rowState(for: id) {
            let row = ApplicationLibraryRow(
                entry: state.entry,
                signingState: state.signingState,
                expiry: state.expiry,
                highlightTerms: state.highlightTerms,
                matchContext: state.matchContext,
                showsSigningInsights: features.signingInsights,
                isSelected: state.isSelected
            )
            Group {
                if model.isSelecting {
                    Button {
                        toggleSelection(id)
                    } label: {
                        row.equatable()
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink(value: LibraryRoute.details(id)) {
                        row.equatable()
                    }
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                leadingSwipeActions(state.entry)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                trailingSwipeActions(state.entry)
            }
            .contextMenu {
                if !model.isSelecting {
                    quickActions(for: state.entry)
                    queueContextAction(for: state.entry)
                }
            }
            .modifier(LibraryAccessibilityQuickActions(
                model: model,
                entry: state.entry,
                features: features,
                isEnabled: !model.isSelecting,
                onSign: { path.append(.sign(id)) },
                onMove: { presentCollectionPicker(for: [id]) },
                onDelete: { entryPendingRemoval = state.entry }
            ))
        }
    }

    @ViewBuilder
    private func gridCard(_ id: ApplicationRecordIdentifier) -> some View {
        if let state = model.rowState(for: id) {
            let card = ApplicationLibraryCard(
                entry: state.entry,
                signingState: state.signingState,
                isSelected: state.isSelected,
                expiry: state.expiry,
                highlightTerms: state.highlightTerms,
                showsSigningInsights: features.signingInsights
            )
            Group {
                if model.isSelecting {
                    Button {
                        toggleSelection(id)
                    } label: {
                        card.equatable()
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink(value: LibraryRoute.details(id)) {
                        card.equatable()
                    }
                    .buttonStyle(.plain)
                }
            }
            .contextMenu {
                if !model.isSelecting {
                    quickActions(for: state.entry)
                    queueContextAction(for: state.entry)
                }
            }
            .modifier(LibraryAccessibilityQuickActions(
                model: model,
                entry: state.entry,
                features: features,
                isEnabled: !model.isSelecting,
                onSign: { path.append(.sign(id)) },
                onMove: { presentCollectionPicker(for: [id]) },
                onDelete: { entryPendingRemoval = state.entry }
            ))
        }
    }

    private func quickActions(for entry: LibraryEntry) -> some View {
        let id = entry.record.id
        return LibraryQuickActionItems(
            model: model,
            entry: entry,
            features: features,
            onDetails: { path.append(.details(id)) },
            onSign: { path.append(.sign(id)) },
            onMove: { presentCollectionPicker(for: [id]) },
            onDelete: { entryPendingRemoval = entry }
        )
    }

    @ViewBuilder
    private func leadingSwipeActions(_ entry: LibraryEntry) -> some View {
        if !model.isSelecting {
            Button {
                Task { await model.setFavorite(!entry.record.isFavorite, on: entry) }
            } label: {
                Label(
                    entry.record.isFavorite ? "Unfavorite" : "Favorite",
                    systemImage: entry.record.isFavorite ? "star.slash" : "star.fill"
                )
            }
            .tint(.yellow)
            if features.signingInsights && entry.isArtifactAvailable {
                Button {
                    path.append(.sign(entry.record.id))
                } label: {
                    Label("Sign", systemImage: "signature")
                }
                .tint(.indigo)
            }
            if isQueueAvailable && entry.isArtifactAvailable {
                Button {
                    presentQueueConfiguration(for: [entry], origin: .library)
                } label: {
                    Label("Queue", systemImage: "tray.and.arrow.down")
                }
                .tint(.purple)
            }
            if features.powerFeatures {
                Button {
                    Task { await model.verify([entry.record.id]) }
                } label: {
                    Label("Verify", systemImage: "checkmark.shield")
                }
                .tint(.teal)
            }
        }
    }

    // MARK: - Signing queue

    /// Whether the signing queue is exposed in this build.
    private var isQueueAvailable: Bool {
        signingQueuePresentation.isAvailable
    }

    /// The queue action a row's context menu offers — reachable from a long
    /// press, a secondary click, or keyboard focus on iPad — alongside the
    /// shared quick actions.
    @ViewBuilder
    private func queueContextAction(for entry: LibraryEntry) -> some View {
        if isQueueAvailable && entry.isArtifactAvailable {
            Button {
                presentQueueConfiguration(for: [entry], origin: .library)
            } label: {
                Label("Queue for Signing…", systemImage: "tray.and.arrow.down")
            }
        }
    }

    /// Opens the queue configuration sheet for `entries`, skipping any whose
    /// package file is missing. Leaving selection mode first keeps the list
    /// from acting on a selection the sheet has already taken over.
    private func presentQueueConfiguration(for entries: [LibraryEntry], origin: SigningJobOrigin) {
        let signable = entries.filter { $0.isArtifactAvailable }
        guard !signable.isEmpty else { return }
        ZHaptics.tap()
        if model.isSelecting {
            withAnimation(.easeInOut(duration: 0.15)) {
                model.setSelecting(false)
            }
        }
        queueConfiguration = SigningQueueConfigurationRequest(entries: signable, origin: origin)
    }

    /// Queues the current selection with one configuration.
    private func queueSelection() {
        presentQueueConfiguration(for: model.selectedEntries, origin: .bulkSelection)
    }

    /// Opens preset planning for the current selection. Incompatible apps
    /// stay visible there and are not queued.
    private func presentPresetQueue() {
        let signable = model.selectedEntries.filter(\.isArtifactAvailable)
        guard !signable.isEmpty else { return }
        ZHaptics.tap()
        presetQueue = PresetQueuePresentation(entries: signable)
    }

    @ViewBuilder
    private func trailingSwipeActions(_ entry: LibraryEntry) -> some View {
        if !model.isSelecting {
            Button(role: .destructive) {
                entryPendingRemoval = entry
            } label: {
                Label("Delete", systemImage: "trash")
            }
            if features.powerFeatures {
                if model.canOrganize {
                    Button {
                        presentCollectionPicker(for: [entry.record.id])
                    } label: {
                        Label("Move", systemImage: "folder")
                    }
                    .tint(.blue)
                }
                if model.canExport && entry.isArtifactAvailable {
                    Button {
                        Task { await model.export([entry.record.id]) }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .tint(.gray)
                }
            } else {
                Button {
                    path.append(.details(entry.record.id))
                } label: {
                    Label("Details", systemImage: "info.circle")
                }
                .tint(.blue)
            }
        }
    }

    // MARK: - Empty results

    @ViewBuilder
    private func emptyResults(_ reason: ApplicationLibraryModel.EmptyReason) -> some View {
        switch reason {
        case .noResults:
            ZEmptyState.noSearchResults(query: model.searchText) {
                model.clearFiltersAndSearch()
            }
        case .smartCollection(let smart):
            ZEmptyState(
                title: smart.emptyTitle,
                message: smart.ruleDescription,
                systemImage: smart.systemImage,
                tint: .blue,
                primaryActionTitle: "View All Apps",
                primaryAction: { model.scope = .all }
            )
        case .emptyCollection(let name):
            ZEmptyState(
                title: "“\(name)” Is Empty",
                message: "Add apps from All Apps with Add to Collection from an app's menu or selection.",
                systemImage: "folder",
                tint: .indigo,
                badgeSymbol: "plus",
                primaryActionTitle: "Choose Apps to Add",
                primaryAction: {
                    model.scope = .all
                    model.setSelecting(true)
                }
            )
        }
    }

    // MARK: - Destinations and sheets

    @ViewBuilder
    private func destination(for route: LibraryRoute) -> some View {
        switch route {
        case .details(let id):
            LibraryDetailDestination(
                model: model,
                recordID: id,
                bundleInspection: bundleInspection,
                detailsInspection: detailsInspection,
                features: features,
                onSign: { path.append(.sign(id)) },
                onMove: { presentCollectionPicker(for: [id]) },
                onDelete: { entry in entryPendingRemoval = entry }
            )
        case .sign(let id):
            if let entry = model.entry(for: id) {
                SigningView(entry: entry)
            } else {
                LibraryEntryUnavailableView()
            }
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: LibrarySheet) -> some View {
        switch sheet {
        case .collectionPicker(let request):
            LibraryCollectionPicker(model: model, request: request) {
                if request.recordIDs.count > 1 {
                    model.setSelecting(false)
                }
            }
        case .nameCollection(let request):
            LibraryCollectionNameSheet(model: model, mode: request.mode)
        case .manageCollections:
            LibraryCollectionsManager(model: model) { scope in
                model.scope = scope
            }
        }
    }

    private func presentCollectionPicker(for ids: [ApplicationRecordIdentifier]) {
        guard !ids.isEmpty, model.canOrganize else { return }
        sheet = .collectionPicker(LibraryCollectionPickerRequest(recordIDs: ids, source: model.scope.collectionID))
    }

    private func startNewCollection() {
        sheet = .nameCollection(LibraryCollectionNameRequest(mode: .create(adding: [], movingFrom: nil)))
    }

    private func manageCollections() {
        sheet = .manageCollections
    }

    /// Pops any pushed screen showing `id`, before it is deleted.
    private func leaveScreens(for id: ApplicationRecordIdentifier) {
        path.removeAll { $0.recordID == id }
    }

    // MARK: - Scopes, filters, statistics

    private var scopeItems: [LibraryScopeBar.Item] {
        var items: [LibraryScopeBar.Item] = [
            LibraryScopeBar.Item(
                scope: .all,
                title: "All Apps",
                systemImage: "square.grid.2x2",
                count: model.scopeCounts[.all] ?? 0
            ),
        ]
        for smart in LibrarySmartCollection.allCases where features.allowsSmartCollection(smart) {
            items.append(LibraryScopeBar.Item(
                scope: .smart(smart),
                title: smart.title,
                systemImage: smart.systemImage,
                count: model.scopeCounts[.smart(smart)] ?? 0
            ))
        }
        for collection in model.userCollections {
            items.append(LibraryScopeBar.Item(
                scope: .collection(collection.id),
                title: collection.name,
                systemImage: "folder",
                count: model.scopeCounts[.collection(collection.id)] ?? 0
            ))
        }
        return items
    }

    private var activeFilterItems: [LibraryActiveFilterBar.Item] {
        model.filters
            .map { LibraryActiveFilterBar.Item(filter: $0, title: title(for: $0)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func title(for filter: LibraryFilter) -> String {
        switch filter {
        case .favorites: return "Favorites"
        case .signed: return "Signed"
        case .unsigned: return "Unsigned"
        case .recentlyImported: return "Recently Imported"
        case .recentlySigned: return "Recently Signed"
        case .expiringSoon: return "Expiring Soon"
        case .collection(let id): return model.collection(withID: id)?.name ?? "Collection"
        case .version(let version): return version.displayName
        case .team(let team): return model.teams.first(where: { $0.identifier == team })?.displayName ?? team
        }
    }

    private func selectScope(_ scope: LibraryScope) {
        withAnimation(.easeInOut(duration: 0.15)) {
            model.scope = scope
        }
        LibraryAnnouncer.announce("\(model.scopeTitle ?? "All Apps"), \(ApplicationLibraryModel.applicationCount(model.visibleIDs.count))")
    }

    private func handleStatisticSelection(_ tile: LibraryStatisticsCard.Tile) {
        switch tile {
        case .total:
            model.clearFiltersAndSearch()
            selectScope(.all)
        case .favorites:
            selectScope(.smart(.favorites))
        case .signed:
            selectScope(.all)
            model.filters = [.signed]
        case .unsigned:
            selectScope(.smart(.unsigned))
        case .collections:
            manageCollections()
        case .storage:
            model.sortOrder = .size
            selectScope(.all)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if case .loaded = model.phase {
                Button(model.isSelecting ? "Done" : "Select") {
                    toggleSelectionMode()
                }
                .keyboardShortcut(model.isSelecting ? KeyboardShortcut.cancelAction : nil)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.isSelecting {
                if isQueueAvailable {
                    Button {
                        queueSelection()
                    } label: {
                        Label("Queue Selected", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(!model.selectedEntries.contains { $0.isArtifactAvailable } || model.isRemovingSelection)
                    .accessibilityHint("Adds the selected applications to the signing queue with one configuration.")
                }
                Button(model.isEverythingSelected ? "Deselect All" : "Select All") {
                    toggleSelectAll()
                }
                .keyboardShortcut("a", modifiers: .command)
            } else {
                if isQueueAvailable {
                    SigningQueueToolbarButton(queue: environment.signingQueue) {
                        signingQueuePresentation.present()
                    }
                }
                if features.powerFeatures, case .loaded = model.phase {
                    filterMenu
                }
                sortMenu
                layoutToggle
                Button {
                    importPresentation.present()
                } label: {
                    Label("Import Package…", systemImage: "plus")
                }
                .disabled(!importPresentation.isAvailable)
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Section("Status") {
                filterToggle(.favorites, title: "Favorites", systemImage: "star")
                if features.signing {
                    filterToggle(.signed, title: "Signed", systemImage: "checkmark.seal")
                    filterToggle(.unsigned, title: "Unsigned", systemImage: "circle.dashed")
                }
            }
            Section("Activity") {
                filterToggle(.recentlyImported, title: "Recently Imported", systemImage: "square.and.arrow.down")
                if features.signing {
                    filterToggle(.recentlySigned, title: "Recently Signed", systemImage: "signature")
                    filterToggle(.expiringSoon, title: "Expiring Soon", systemImage: "clock.badge.exclamationmark")
                }
            }
            Section("Version") {
                filterToggle(.version(.latest), title: LibraryVersionFilter.latest.displayName, systemImage: "arrow.up.circle")
                filterToggle(.version(.older), title: LibraryVersionFilter.older.displayName, systemImage: "clock.arrow.circlepath")
            }
            if !model.userCollections.isEmpty {
                Section("Collection") {
                    ForEach(model.userCollections) { collection in
                        filterToggle(.collection(collection.id), title: collection.name, systemImage: "folder")
                    }
                }
            }
            if !model.teams.isEmpty {
                Section("Team") {
                    ForEach(model.teams) { team in
                        filterToggle(.team(team.identifier), title: team.displayName, systemImage: "person.2")
                    }
                }
            }
            if !model.filters.isEmpty {
                Section {
                    Button(role: .destructive) {
                        model.filters = []
                    } label: {
                        Label("Clear All Filters", systemImage: "xmark.circle")
                    }
                }
            }
        } label: {
            Label(
                "Filter",
                systemImage: model.filters.isEmpty
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
        }
        .accessibilityLabel(model.filters.isEmpty ? "Filter applications" : "Filter applications, \(model.filters.count) active")
    }

    private func filterToggle(_ filter: LibraryFilter, title: String, systemImage: String) -> some View {
        Toggle(isOn: Binding(
            get: { model.filters.contains(filter) },
            set: { isOn in
                if isOn {
                    model.filters.insert(filter)
                } else {
                    model.filters.remove(filter)
                }
            }
        )) {
            Label(title, systemImage: systemImage)
        }
        .menuActionDismissBehavior(.disabled)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $model.sortOrder) {
                ForEach(features.sortModes) { mode in
                    Label(mode.displayName, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort applications, currently \(model.sortOrder.displayName)")
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

    // MARK: - Floating bar

    @ViewBuilder
    private var floatingBar: some View {
        if model.isSelecting && !model.selection.isEmpty {
            LibraryBulkActionBar(
                model: model,
                features: features,
                onMove: { presentCollectionPicker(for: model.selectedIDs) },
                onDelete: { selectionPendingRemoval = model.selectedEntries },
                onQueue: isQueueAvailable ? { queueSelection() } : nil,
                onSignWithPreset: ReleaseTrain.isAvailable(.signingPresets) ? { presentPresetQueue() } : nil
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let progress = model.progress {
            LibraryProgressCapsule(progress: progress)
                .transition(.opacity)
        }
    }

    // MARK: - Selection

    private func toggleSelectionMode() {
        ZHaptics.tap()
        let selecting = !model.isSelecting
        withAnimation(.easeInOut(duration: 0.15)) {
            model.setSelecting(selecting)
        }
        LibraryAnnouncer.announce(selecting ? "Selection mode. Choose apps to act on." : "Selection mode ended")
    }

    private func toggleSelection(_ id: ApplicationRecordIdentifier) {
        ZHaptics.tap()
        withAnimation(.easeInOut(duration: 0.15)) {
            model.toggleSelection(id)
        }
    }

    private func toggleSelectAll() {
        ZHaptics.tap()
        withAnimation(.easeInOut(duration: 0.15)) {
            if model.isEverythingSelected {
                model.deselectAll()
            } else {
                model.selectAll()
            }
        }
    }

    /// Tells VoiceOver how many applications are selected whenever the
    /// selection changes, since the floating bar changes silently.
    private func announceSelectionChange(
        from oldValue: Set<ApplicationRecordIdentifier>,
        to newValue: Set<ApplicationRecordIdentifier>
    ) {
        guard model.isSelecting, oldValue != newValue else { return }
        if newValue.isEmpty {
            LibraryAnnouncer.announce("No apps selected")
        } else if model.isEverythingSelected && newValue.count > 1 {
            LibraryAnnouncer.announce("All \(newValue.count) apps selected")
        } else {
            LibraryAnnouncer.announce("\(newValue.count) selected")
        }
    }

    // MARK: - Preferences

    /// Applies the remembered order and scope once, then loads.
    private func prepare() async {
        if !hasAppliedStoredPreferences {
            hasAppliedStoredPreferences = true
            let stored = LibrarySortMode(rawValue: storedSortOrder) ?? .recentlyImported
            model.sortOrder = features.allowsSortMode(stored) ? stored : .recentlyImported
            applyStoredScope(storedScope)
        }
        await model.load()
    }

    /// Applies a remembered or handed-over scope — Home opens the library on
    /// Favorites this way. A scope this release does not expose falls back
    /// to everything.
    private func applyStoredScope(_ value: String) {
        let requested = LibraryScope(storageValue: value) ?? .all
        let scope = features.allowsScope(requested) ? requested : .all
        if model.scope != scope {
            model.scope = scope
        }
    }
}

// MARK: - VoiceOver quick actions

/// The quick actions as VoiceOver custom actions, so every action a swipe
/// or a long press offers is also reachable with the rotor. Only actions
/// the application can actually take are offered.
private struct LibraryAccessibilityQuickActions: ViewModifier {

    @ObservedObject var model: ApplicationLibraryModel
    let entry: LibraryEntry
    let features: LibraryFeatureAvailability
    let isEnabled: Bool
    let onSign: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.accessibilityActions {
                Button(entry.record.isFavorite ? "Unfavorite" : "Favorite") {
                    Task { await model.setFavorite(!entry.record.isFavorite, on: entry) }
                }
                if features.signingInsights && entry.isArtifactAvailable {
                    Button("Sign", action: onSign)
                }
                if features.powerFeatures {
                    Button("Verify Package") {
                        Task { await model.verify([entry.record.id]) }
                    }
                    if model.canExport && entry.isArtifactAvailable {
                        Button("Export") {
                            Task { await model.export([entry.record.id]) }
                        }
                    }
                    if model.canOrganize {
                        Button(model.scope.collectionID == nil ? "Add to Collection" : "Move to Collection", action: onMove)
                    }
                }
                Button("Delete", action: onDelete)
            }
        } else {
            content
        }
    }
}

// MARK: - Row

/// One library entry in the list: the application's icon, its declared name,
/// identifier, declared versions, the date it was imported, and the state
/// badges its card carries. Favorite and artifact state are shown inline —
/// words first, never styling alone. While searching, the matching text is
/// highlighted, and a match the visible text does not show (a developer, a
/// team, a collection) is explained on its own line.
///
/// The row is an equatable value: SwiftUI skips re-rendering it unless one
/// of its inputs changed.
struct ApplicationLibraryRow: View, Equatable {

    let entry: LibraryEntry
    var signingState: ApplicationLibraryModel.SigningState = .notSigned
    var expiry: LibraryExpiryStatus = .unknown
    var highlightTerms: [String] = []
    var matchContext: String? = nil
    var showsSigningInsights = false

    /// `nil` outside selection mode; otherwise whether the entry is selected.
    var isSelected: Bool? = nil

    var body: some View {
        let content = ApplicationLibraryRowContent(entry: entry)
        HStack(spacing: ZSpacing.sm) {
            if let isSelected {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color(.tertiaryLabel))
                    .imageScale(.large)
                    .frame(minWidth: 28)
            }
            ApplicationIconView(
                artifactID: entry.record.artifact.artifactID,
                displayName: content.name,
                bundleIdentifier: content.bundleIdentifier
            )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: ZSpacing.xxs) {
                    LibraryHighlighter.text(content.name, terms: highlightTerms)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if entry.record.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityHidden(true)
                    }
                }
                LibraryHighlighter.text(content.bundleIdentifier, terms: highlightTerms)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: ZSpacing.xs) {
                    if let versionText = content.versionText {
                        LibraryHighlighter.text(versionText, terms: highlightTerms)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(entry.record.importedAt, format: .dateTime.year().month().day())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let matchContext {
                    LibraryHighlighter.text(matchContext, terms: highlightTerms)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: ZSpacing.xs) {
                    signingBadge(content)
                    if showsSigningInsights {
                        expiryBadge
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // The row is read as one element: name, identifier, versions, import
        // date, badges — so nothing depends on visual styling alone.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription(content))
        .accessibilityAddTraits(isSelected == true ? .isSelected : [])
        .accessibilityHint(isSelected == nil ? "" : "Double-tap to change the selection")
    }

    @ViewBuilder
    private func signingBadge(_ content: ApplicationLibraryRowContent) -> some View {
        switch signingState {
        case .signed:
            ZStatusBadge("Signed", systemImage: "checkmark.seal.fill", kind: .success)
        case .notSigned:
            ZStatusBadge("Not Signed", systemImage: "circle.dashed", kind: .neutral)
        case .packageProblem:
            ZStatusBadge(content.availabilityText ?? "Package Problem", systemImage: "exclamationmark.triangle.fill", kind: .warning)
        }
    }

    @ViewBuilder
    private var expiryBadge: some View {
        switch expiry {
        case .expiringSoon(let date):
            ZStatusBadge("Expires \(date.formatted(.relative(presentation: .named)))", systemImage: "clock.badge.exclamationmark", kind: .warning)
        case .expired:
            ZStatusBadge("Signing Expired", systemImage: "xmark.circle.fill", kind: .error)
        case .unknown, .valid:
            EmptyView()
        }
    }

    private func accessibilityDescription(_ content: ApplicationLibraryRowContent) -> String {
        var parts: [String] = [content.name]
        if entry.record.isFavorite {
            parts.append("favourite")
        }
        parts.append(content.bundleIdentifier)
        if let versionText = content.versionText {
            parts.append(versionText)
        }
        parts.append("Imported \(entry.record.importedAt.formatted(date: .abbreviated, time: .omitted))")
        switch signingState {
        case .signed: parts.append("Signed")
        case .notSigned: parts.append("Not signed")
        case .packageProblem: parts.append(content.availabilityText ?? "Package problem")
        }
        if showsSigningInsights, let expiryText = Self.expiryDescription(expiry) {
            parts.append(expiryText)
        }
        if let matchContext {
            parts.append(matchContext)
        }
        return parts.joined(separator: ", ")
    }

    /// The spoken form of an expiry badge, or `nil` when there is no badge.
    static func expiryDescription(_ expiry: LibraryExpiryStatus) -> String? {
        switch expiry {
        case .expiringSoon(let date):
            return "Signing expires \(date.formatted(.relative(presentation: .named)))"
        case .expired(let date):
            return "Signing expired \(date.formatted(date: .abbreviated, time: .omitted))"
        case .unknown, .valid:
            return nil
        }
    }
}

// MARK: - Card

/// One library entry as a grid card: the application's icon, its declared
/// name and version, the import date, the signing state, and a favourite
/// indicator. In selection mode the card carries an explicit selection
/// mark instead of opening the detail screen. Like the row, the card is an
/// equatable value.
struct ApplicationLibraryCard: View, Equatable {

    let entry: LibraryEntry
    var signingState: ApplicationLibraryModel.SigningState = .notSigned

    /// `nil` outside selection mode; otherwise whether the entry is selected.
    var isSelected: Bool? = nil

    var expiry: LibraryExpiryStatus = .unknown
    var highlightTerms: [String] = []
    var showsSigningInsights = false

    var body: some View {
        let content = ApplicationLibraryRowContent(entry: entry)
        VStack(spacing: ZSpacing.xxs) {
            ZStack(alignment: .topTrailing) {
                ApplicationIconView(
                    artifactID: entry.record.artifact.artifactID,
                    displayName: content.name,
                    bundleIdentifier: content.bundleIdentifier,
                    size: 64
                )
                if let isSelected {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.body)
                        .foregroundStyle(isSelected ? Color.accentColor : Color(.tertiaryLabel))
                        .background(Circle().fill(.thinMaterial))
                        .offset(x: 6, y: -6)
                        .accessibilityHidden(true)
                } else if entry.record.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .padding(3)
                        .background(Circle().fill(.thinMaterial))
                        .offset(x: 5, y: -5)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            LibraryHighlighter.text(content.name, terms: highlightTerms)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
            Text(content.versionText ?? "No Declared Version")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            statusLine(content)
        }
        .padding(ZSpacing.xs)
        .frame(maxWidth: .infinity)
        .zynCardBackground()
        .overlay {
            if isSelected == true {
                RoundedRectangle(cornerRadius: ZRadius.card)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: ZRadius.card))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription(content))
        .accessibilityAddTraits(isSelected == true ? .isSelected : [])
        .accessibilityHint(isSelected == nil ? "Opens the application's details" : "Double-tap to change the selection")
    }

    /// The card's compact status: an expiry warning when signing insights
    /// are shown and one applies, else a signing mark, else the import date.
    /// A package problem outranks everything.
    @ViewBuilder
    private func statusLine(_ content: ApplicationLibraryRowContent) -> some View {
        switch signingState {
        case .packageProblem:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
        case .signed:
            if showsSigningInsights && expiry.needsAttention {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            }
        case .notSigned:
            Text(entry.record.importedAt, format: .dateTime.month(.abbreviated).day())
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func accessibilityDescription(_ content: ApplicationLibraryRowContent) -> String {
        var parts: [String] = [content.name]
        if entry.record.isFavorite {
            parts.append("favourite")
        }
        parts.append(content.versionText ?? "no declared version")
        switch signingState {
        case .signed: parts.append("Signed")
        case .notSigned: parts.append("Not signed")
        case .packageProblem: parts.append(content.availabilityText ?? "Package problem")
        }
        if showsSigningInsights, let expiryText = ApplicationLibraryRow.expiryDescription(expiry) {
            parts.append(expiryText)
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Row content

/// The display values for one library row or card, derived from the entry.
///
/// Absent declarations are never replaced by invented values: an
/// application that declared no usable name is shown as unnamed, and an
/// application that declared no versions shows that fact. A missing or
/// inconsistent artifact is flagged in words, not only in styling.
struct ApplicationLibraryRowContent: Equatable {

    /// The resolved display name, or a neutral placeholder when the
    /// package declared no usable name.
    let name: String

    /// The declared bundle identifier.
    let bundleIdentifier: String

    /// The declared versions as one line, or `nil` when the package
    /// declared neither a version nor a build.
    let versionText: String?

    /// A user-presentable flag for an artifact that is not available as
    /// recorded, or `nil` when the package file is as the record expects.
    let availabilityText: String?

    init(entry: LibraryEntry) {
        let record = entry.record
        self.name = record.displayName ?? "Unnamed Application"
        self.bundleIdentifier = record.bundleIdentifier.rawValue
        switch (record.identity.shortVersionString, record.identity.buildVersion) {
        case (.some(let version), .some(let build)):
            self.versionText = "Version \(version) (\(build))"
        case (.some(let version), .none):
            self.versionText = "Version \(version)"
        case (.none, .some(let build)):
            self.versionText = "Build \(build)"
        case (.none, .none):
            self.versionText = nil
        }
        switch entry.artifactAvailability {
        case .available:
            self.availabilityText = nil
        case .missing:
            self.availabilityText = "Package File Missing"
        case .inconsistent:
            self.availabilityText = "Package File Does Not Match Its Record"
        }
    }
}

// MARK: - Incremental rendering

/// The tail of a long list: skeleton rows standing for the results the
/// window has not materialised yet, and a way to show them all. Scrolling
/// into it grows the window on its own; the button is for people who
/// would rather not scroll, and for VoiceOver, which reads the count.
struct LibraryRenderMoreRow: View {
    let remaining: Int
    let onShowAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            ForEach(0..<min(3, remaining), id: \.self) { _ in
                LibrarySkeletonRow()
            }
            Button {
                onShowAll()
            } label: {
                Text("Show all \(ApplicationLibraryModel.applicationCount(remaining)) remaining")
                    .font(.footnote.weight(.medium))
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, ZSpacing.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(ApplicationLibraryModel.applicationCount(remaining)) more, loading as you scroll")
    }
}

/// One placeholder in the shape of a library row.
struct LibrarySkeletonRow: View {
    var body: some View {
        HStack(spacing: ZSpacing.sm) {
            RoundedRectangle(cornerRadius: ZRadius.icon)
                .fill(Color(.tertiarySystemFill))
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                RoundedRectangle(cornerRadius: 3).fill(Color(.tertiarySystemFill)).frame(height: 14)
                RoundedRectangle(cornerRadius: 3).fill(Color(.tertiarySystemFill)).frame(height: 10).padding(.trailing, 60)
                RoundedRectangle(cornerRadius: 3).fill(Color(.tertiarySystemFill)).frame(height: 10).padding(.trailing, 120)
            }
            Spacer()
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}

// MARK: - Loading and failure

/// The loading state: skeletons in the shape of the rows that will replace
/// them, so the screen never presents an empty library as a finding.
struct ApplicationLibraryLoadingView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: ZSpacing.sm) {
                ForEach(0..<6, id: \.self) { _ in
                    ZSkeletonAppRow()
                        .padding(.horizontal)
                        .padding(.vertical, ZSpacing.xxs)
                }
            }
            .padding(.top, ZSpacing.sm)
        }
        .accessibilityLabel("Loading applications")
    }
}

/// The failure state: the library could not be read, and the screen says so
/// instead of showing an empty list.
struct ApplicationLibraryFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ZErrorView(
            title: "Library Unavailable",
            explanation: message,
            suggestedAction: "Check device storage or restart ZynSign if the library database is locked.",
            technicalDetails: "ApplicationLibrary database read failure: \(message)",
            onRetry: { retry() }
        )
    }
}

// MARK: - Previews

private let previewEnvironment = CompositionRoot.makeApplicationEnvironment()

private enum PreviewFixtures {
    static func identity(
        bundleIdentifier: String,
        displayName: String,
        shortVersion: String? = "1.2",
        build: String? = "34"
    ) -> ApplicationIdentity {
        guard let identifier = BundleIdentifier(rawValue: bundleIdentifier) else {
            preconditionFailure("Preview fixture bundle identifier is not valid: \(bundleIdentifier)")
        }
        return ApplicationIdentity(
            bundleIdentifier: identifier,
            declaredDisplayName: displayName,
            shortVersionString: shortVersion,
            buildVersion: build
        )
    }

    static func record(
        identity: ApplicationIdentity,
        importedAt: Date = Date(timeIntervalSinceReferenceDate: 750_000_000),
        isFavorite: Bool = false
    ) -> ApplicationRecord {
        guard let fingerprint = ArtifactFingerprint(
            algorithm: .sha256,
            digestBytes: Array(repeating: 0xAB, count: 32)
        ) else {
            preconditionFailure("A 32-byte digest must always form a fingerprint.")
        }
        return ApplicationRecord(
            id: ApplicationRecordIdentifier(),
            identity: identity,
            executableName: nil,
            sourceFileName: nil,
            artifact: ArtifactReference(
                artifactID: ArtifactIdentifier(),
                byteCount: 1_024,
                fingerprint: fingerprint
            ),
            inspection: ApplicationRecord.InspectionSummary(classification: .valid),
            importedAt: importedAt,
            updatedAt: importedAt,
            isFavorite: isFavorite
        )
    }

    static let complete = LibraryEntry(
        record: record(
            identity: identity(bundleIdentifier: "com.example.complete", displayName: "Example"),
            isFavorite: true
        ),
        artifactAvailability: .available
    )

    static let missingArtifact = LibraryEntry(
        record: record(
            identity: identity(bundleIdentifier: "com.example.orphandesk", displayName: "Orphan Desk"),
            importedAt: Date(timeIntervalSinceReferenceDate: 750_000_120)
        ),
        artifactAvailability: .missing
    )

    static let all = [complete, missingArtifact]
}

#Preview("Empty Library") {
    ApplicationLibraryView(
        library: previewEnvironment.library,
        hub: previewEnvironment.importHub,
        bundleInspection: previewEnvironment.bundleInspection,
        detailsInspection: previewEnvironment.applicationDetailsInspection
    )
}

#Preview("Library Rows") {
    NavigationStack {
        List {
            ForEach(PreviewFixtures.all, id: \.record.id) { entry in
                ApplicationLibraryRow(entry: entry, highlightTerms: ["ex"])
            }
        }
        .navigationTitle("Applications")
    }
}

#Preview("Library Grid") {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: ZSpacing.sm)], spacing: ZSpacing.sm) {
            ForEach(PreviewFixtures.all, id: \.record.id) { entry in
                ApplicationLibraryCard(entry: entry)
            }
        }
        .padding()
    }
    .background(Color(.systemGroupedBackground))
}

#Preview("Statistics") {
    LibraryStatisticsCard(
        statistics: LibraryStatistics(
            totalApplications: 248,
            favorites: 12,
            signed: 31,
            unsigned: 217,
            collections: 6,
            storageBytes: 18_400_000_000
        ),
        showsSigning: true
    ) { _ in }
    .padding()
}

#Preview("Loading") {
    ApplicationLibraryLoadingView()
}

#Preview("Library Error") {
    ApplicationLibraryFailureView(
        message: "ZynSign could not access its application library."
    ) {}
}

// MARK: - Signing queue toolbar button

/// The Library's way into the signing queue: a toolbar button whose badge
/// counts the jobs running or waiting, so queued work stays visible from
/// the screen the jobs were queued on. `⌘⇧Q` opens it from a keyboard.
struct SigningQueueToolbarButton: View {

    @ObservedObject var queue: SigningQueue
    let action: () -> Void

    private var activeCount: Int {
        queue.jobs.filter { $0.isActive }.count
    }

    var body: some View {
        Button {
            ZHaptics.tap()
            action()
        } label: {
            Label("Signing Queue", systemImage: activeCount > 0 ? "tray.full.fill" : "tray.full")
                .overlay(alignment: .topTrailing) {
                    if activeCount > 0 {
                        Text("\(activeCount)")
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(Color.accentColor))
                            .offset(x: 8, y: -6)
                            .accessibilityHidden(true)
                    }
                }
        }
        .keyboardShortcut("q", modifiers: [.command, .shift])
        .accessibilityLabel("Signing Queue")
        .accessibilityValue(activeCount == 0 ? "No active jobs" : "\(activeCount) active job\(activeCount == 1 ? "" : "s")")
    }
}

/// The selection handed to the preset planner. Identifiable so the library
/// can present it as a sheet without signing anything itself.
private struct PresetQueuePresentation: Identifiable {
    let id = UUID()
    let entries: [LibraryEntry]
}
