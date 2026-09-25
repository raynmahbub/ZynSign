import SwiftUI

/// The Applications area of the shell: ZynSign's application library.
///
/// The screen presents the persisted records of accepted imports and offers
/// the everyday library operations: importing another package through the
/// existing document-import workflow, opening an application's detail
/// screen (and from there the read-only bundle explorer), marking favourites,
/// and deleting entries together with the package files behind them — one at
/// a time or in a selection.
///
/// The list can be shown as rows or as a grid of cards, filtered by name or
/// bundle identifier, and ordered by recency, name, or declared version.
/// Nothing here pretends to sign: the signed state a card shows is read from
/// the on-device signing journal, and a card whose package file has drifted
/// from its record says so.
struct ApplicationLibraryView: View {

    @StateObject private var model: ApplicationLibraryModel
    @StateObject private var importing: PackageImportModel
    @Environment(\.applicationEnvironment) private var environment
    @State private var isShowingImporter = false
    @State private var entryPendingRemoval: LibraryEntry?
    @State private var selectionPendingRemoval: [LibraryEntry] = []
    @State private var entryPendingDetails: LibraryEntry?
    @State private var isSelecting = false
    @State private var selection: Set<ApplicationRecordIdentifier> = []
    @AppStorage("zynsign.library.showsGrid") private var showsGrid = false
    private let bundleInspection: IPABundleContentsInspection

    /// Creates the screen over the library, import, and bundle inspection
    /// use cases the composition root supplied. The import presentation
    /// model is the same phase machine the Import area uses; the library
    /// model observes its outcomes, so a successful import refreshes the
    /// list. The inspection use case is handed on to the detail screen,
    /// which offers the bundle explorer. The signing journal is read-only;
    /// `nil` simply means cards never show a signed state.
    init(
        library: ApplicationLibrary,
        importing: IPAPackageImport,
        bundleInspection: IPABundleContentsInspection,
        signingHistory: (any SigningHistoryStore)? = nil
    ) {
        let importModel = PackageImportModel(importing: importing)
        _importing = StateObject(wrappedValue: importModel)
        _model = StateObject(wrappedValue: ApplicationLibraryModel(
            library: library,
            importing: importModel,
            signingHistory: signingHistory
        ))
        self.bundleInspection = bundleInspection
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
                .navigationTitle(ShellSection.library.title)
                .navigationDestination(for: LibraryEntry.self) { entry in
                    ApplicationDetailView(entry: entry, bundleInspection: bundleInspection)
                }
                .navigationDestination(item: $entryPendingDetails) { entry in
                    ApplicationDetailView(entry: entry, bundleInspection: bundleInspection)
                }
                .searchable(
                    text: $model.searchText,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: Text("Name or Bundle ID")
                )
                .toolbar { toolbarContent }
                .disabled(model.isRemovingSelection)
        }
        .task { await model.load() }
        .onChange(of: importing.phase) { _, phase in
            switch phase {
            case .succeeded:
                environment.recordAnalyticsEvent(category: .intake, name: "import.accepted", succeeded: true)
                exitSelectionMode()
            case .failed:
                environment.recordAnalyticsEvent(category: .intake, name: "import.rejected", succeeded: false)
            case .idle, .importing, .cancelled:
                break
            }
        }
        .safeAreaInset(edge: .bottom) { importStatus }
        .fileImporter(
            isPresented: $isShowingImporter,
            allowedContentTypes: ImportablePackage.contentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    model.handlePickerResult(.success(url))
                }
            case .failure(let error):
                model.handlePickerResult(.failure(error))
            }
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
                guard let pending = entryPendingRemoval else { return }
                entryPendingRemoval = nil
                removeFromSelection(pending)
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
                exitSelectionMode()
                Task { await model.removeEntries(pending) }
            }
            Button("Cancel", role: .cancel) {
                selectionPendingRemoval = []
            }
        } message: { entries in
            Text("\(entries.count) application\(entries.count == 1 ? "" : "s") and \(entries.count == 1 ? "its" : "their") package file\(entries.count == 1 ? "" : "s") will be permanently deleted from ZynSign's library. This cannot be undone.")
        }
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
            libraryContent
        }
    }

    private var emptyContent: some View {
        ContentUnavailableView {
            Label("No Applications", systemImage: ShellSection.library.symbolName)
        } description: {
            Text("Applications you import appear here. Importing reads a package's structure and the information its application declares, and keeps the package in ZynSign's library. Import does not sign or install anything.")
        } actions: {
            Button("Import Package…") {
                isShowingImporter = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// The loaded library: the visible projection of the current search and
    /// sort, with an explicit state when the search matches nothing.
    @ViewBuilder
    private var libraryContent: some View {
        let entries = model.visibleEntries()
        if entries.isEmpty && !model.searchText.isEmpty {
            ContentUnavailableView.search(Text(model.searchText))
        } else if entries.isEmpty {
            ContentUnavailableView {
                Label("No Matching Applications", systemImage: ShellSection.library.symbolName)
            } description: {
                Text("Every application is filtered out by the current search.")
            }
        } else if showsGrid {
            libraryGrid(entries)
        } else {
            libraryList(entries)
        }
    }

    private func libraryList(_ entries: [LibraryEntry]) -> some View {
        List {
            ForEach(entries, id: \.record.id) { entry in
                libraryRow(for: entry)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.refresh() }
    }

    private func libraryGrid(_ entries: [LibraryEntry]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 108), spacing: ZSpacing.sm)],
                spacing: ZSpacing.sm
            ) {
                ForEach(entries, id: \.record.id) { entry in
                    gridCard(for: entry)
                }
            }
            .padding(ZSpacing.sm)
        }
        .refreshable { await model.refresh() }
    }

    // MARK: - Rows and cards

    @ViewBuilder
    private func libraryRow(for entry: LibraryEntry) -> some View {
        Group {
            if isSelecting {
                Button {
                    toggleSelection(entry)
                } label: {
                    selectionRow(entry)
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink(value: entry) {
                    ApplicationLibraryRow(entry: entry, signingState: model.signingState(for: entry))
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !isSelecting {
                Button {
                    Task { await model.setFavorite(!entry.record.isFavorite, on: entry) }
                } label: {
                    Label(
                        entry.record.isFavorite ? "Unfavorite" : "Favorite",
                        systemImage: entry.record.isFavorite ? "star.slash" : "star.fill"
                    )
                }
                .tint(.yellow)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isSelecting {
                Button {
                    entryPendingDetails = entry
                } label: {
                    Label("Details", systemImage: "info.circle")
                }
                .tint(.blue)
                Button(role: .destructive) {
                    entryPendingRemoval = entry
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    /// The row shown in selection mode: the same content with an explicit
    /// selection mark, because a checkmark the system draws for editing a
    /// `List` cannot be reproduced per-row without the editing machinery.
    private func selectionRow(_ entry: LibraryEntry) -> some View {
        HStack(spacing: ZSpacing.sm) {
            Image(systemName: selection.contains(entry.record.id) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selection.contains(entry.record.id) ? Color.accentColor : Color(.tertiaryLabel))
                .imageScale(.large)
                .accessibilityLabel(selection.contains(entry.record.id) ? "Selected" : "Not selected")
            ApplicationLibraryRow(entry: entry, signingState: model.signingState(for: entry))
        }
    }

    @ViewBuilder
    private func gridCard(for entry: LibraryEntry) -> some View {
        Group {
            if isSelecting {
                Button {
                    toggleSelection(entry)
                } label: {
                    ApplicationLibraryCard(
                        entry: entry,
                        signingState: model.signingState(for: entry),
                        isSelected: selection.contains(entry.record.id)
                    )
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink(value: entry) {
                    ApplicationLibraryCard(
                        entry: entry,
                        signingState: model.signingState(for: entry),
                        isSelected: nil
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu {
            if !isSelecting {
                Button {
                    Task { await model.setFavorite(!entry.record.isFavorite, on: entry) }
                } label: {
                    Label(
                        entry.record.isFavorite ? "Unfavorite" : "Favorite",
                        systemImage: entry.record.isFavorite ? "star.slash" : "star.fill"
                    )
                }
                Button {
                    entryPendingDetails = entry
                } label: {
                    Label("Details", systemImage: "info.circle")
                }
                Button(role: .destructive) {
                    entryPendingRemoval = entry
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Selection

    private func toggleSelection(_ entry: LibraryEntry) {
        ZHaptics.tap()
        withAnimation(.easeInOut(duration: 0.15)) {
            if selection.contains(entry.record.id) {
                selection.remove(entry.record.id)
            } else {
                selection.insert(entry.record.id)
            }
        }
    }

    private func exitSelectionMode() {
        isSelecting = false
        selection = []
    }

    /// Removes an entry from the local selection when it is being deleted,
    /// so a confirmed removal never leaves a selected identifier the
    /// library no longer holds.
    private func removeFromSelection(_ entry: LibraryEntry) {
        selection.remove(entry.record.id)
    }

    /// The entries the current selection names, in the order the screen
    /// shows them.
    private var selectedEntries: [LibraryEntry] {
        model.visibleEntries().filter { selection.contains($0.record.id) }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if case .loaded = model.phase {
                Button(isSelecting ? "Done" : "Select") {
                    ZHaptics.tap()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if isSelecting {
                            exitSelectionMode()
                        } else {
                            isSelecting = true
                        }
                    }
                }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if isSelecting {
                Button(selection.isEmpty ? "Select All" : "Deselect All") {
                    ZHaptics.tap()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if selection.isEmpty {
                            selection = Set(model.visibleEntries().map { $0.record.id })
                        } else {
                            selection = []
                        }
                    }
                }
            } else {
                sortMenu
                layoutToggle
                Button {
                    isShowingImporter = true
                } label: {
                    Label("Import Package…", systemImage: "plus")
                }
                .disabled(importing.phase == .importing)
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $model.sortOrder) {
                ForEach(ApplicationLibraryModel.SortOrder.allCases) { order in
                    Text(order.displayName).tag(order)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort applications")
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

    // MARK: - Selection action bar

    @ViewBuilder
    private var selectionBar: some View {
        if isSelecting {
            HStack(spacing: ZSpacing.md) {
                Text("\(selection.count) selected")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button {
                    selectionPendingRemoval = selectedEntries
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selection.isEmpty || model.isRemovingSelection)
                .tint(.red)
            }
            .padding(.horizontal)
            .padding(.vertical, ZSpacing.xs)
            .background(.bar)
        }
    }

    // MARK: - Import progress

    /// The import progress bar shown while the document the user picked is
    /// being read. A terminal import outcome is announced through the
    /// notice alert, so the bar only covers the running phase.
    @ViewBuilder
    private var importStatus: some View {
        if importing.phase == .importing {
            HStack(spacing: 12) {
                ProgressView()
                Text("Reading package…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.cancelImport()
                }
            }
            .padding()
            .background(.bar)
        } else {
            selectionBar
        }
    }
}

// MARK: - Row

/// One library entry in the list: the application's icon, its declared name,
/// identifier, declared versions, the date it was imported, and the state
/// badges its card carries. Favorite and artifact state are shown inline —
/// words first, never styling alone.
struct ApplicationLibraryRow: View {

    let entry: LibraryEntry
    var signingState: ApplicationLibraryModel.SigningState = .notSigned

    var body: some View {
        let content = ApplicationLibraryRowContent(entry: entry)
        HStack(spacing: ZSpacing.sm) {
            ApplicationIconView(
                artifactID: entry.record.artifact.artifactID,
                displayName: content.name,
                bundleIdentifier: content.bundleIdentifier
            )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: ZSpacing.xxs) {
                    Text(content.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if entry.record.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favorite")
                    }
                }
                Text(content.bundleIdentifier)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: ZSpacing.xs) {
                    if let versionText = content.versionText {
                        Text(versionText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(entry.record.importedAt, format: .dateTime.year().month().day())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                signingBadge
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        // The row is read as one element: name, identifier, versions, import
        // date, badges — so nothing depends on visual styling alone.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription(content))
    }

    @ViewBuilder
    private var signingBadge: some View {
        switch signingState {
        case .signed:
            ZStatusBadge("Signed", systemImage: "checkmark.seal.fill", kind: .success)
        case .notSigned:
            ZStatusBadge("Not Signed", systemImage: "circle.dashed", kind: .neutral)
        case .packageProblem:
            ZStatusBadge(content.availabilityText ?? "Package Problem", systemImage: "exclamationmark.triangle.fill", kind: .warning)
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
        return parts.joined(separator: ", ")
    }
}

// MARK: - Card

/// One library entry as a grid card: the application's icon, its declared
/// name and version, the import date, the signing state, and a favourite
/// indicator. In selection mode the card carries an explicit selection
/// mark instead of opening the detail screen.
struct ApplicationLibraryCard: View {

    let entry: LibraryEntry
    var signingState: ApplicationLibraryModel.SigningState = .notSigned

    /// `nil` outside selection mode; otherwise whether the entry is selected.
    var isSelected: Bool? = nil

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
                        .accessibilityLabel(isSelected ? "Selected" : "Not selected")
                }
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 2) {
                Text(content.name)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
                if entry.record.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("Favorite")
                }
            }
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription(content))
        .accessibilityHint(isSelected == nil ? "Opens the application's details" : "")
    }

    /// The card's compact status: a signing mark when it has one, otherwise
    /// the declared import date. A package problem outranks both.
    @ViewBuilder
    private func statusLine(_ content: ApplicationLibraryRowContent) -> some View {
        switch signingState {
        case .packageProblem:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .accessibilityLabel(content.availabilityText ?? "Package problem")
        case .signed:
            Image(systemName: "checkmark.seal.fill")
                .font(.caption2)
                .foregroundStyle(.green)
                .accessibilityLabel("Signed")
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

// MARK: - Loading and failure

/// The loading state: skeletons in the shape of the rows that will replace
/// them, so the screen never presents an empty library as a finding.
struct ApplicationLibraryLoadingView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: ZSpacing.sm) {
                ForEach(0..<6, id: \.self) { _ in
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
        ContentUnavailableView {
            Label("Library Unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { retry() }
                .buttonStyle(.borderedProminent)
        }
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
        importedAt: Date = Date(timeIntervalSinceReferenceDate: 750_000_000)
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
            updatedAt: importedAt
        )
    }

    static let complete = LibraryEntry(
        record: record(identity: identity(
            bundleIdentifier: "com.example.complete",
            displayName: "Example"
        )),
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
        importing: previewEnvironment.packageImport,
        bundleInspection: previewEnvironment.bundleInspection
    )
}

#Preview("Library Rows") {
    NavigationStack {
        List {
            ForEach(PreviewFixtures.all, id: \.record.id) { entry in
                NavigationLink(value: entry) {
                    ApplicationLibraryRow(entry: entry)
                }
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

#Preview("Loading") {
    ApplicationLibraryLoadingView()
}

#Preview("Library Error") {
    ApplicationLibraryFailureView(
        message: "ZynSign could not access its application library."
    ) {}
}
