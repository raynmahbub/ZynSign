import SwiftUI

// MARK: - Naming a collection

/// Names a new collection or renames an existing one.
///
/// The name is checked as it is typed — empty, too long, or already used —
/// with the reason shown under the field, and Save stays disabled until
/// the name can be used. Saving goes through the organizer; if it still
/// fails (a collection created elsewhere in the meantime, or storage), the
/// reason is shown and the sheet stays open with the name intact.
struct LibraryCollectionNameSheet: View {

    enum Mode: Equatable {
        /// Create a collection holding `recordIDs`. When `source` is set,
        /// the entries are moved out of that collection.
        case create(adding: [ApplicationRecordIdentifier], movingFrom: LibraryCollectionIdentifier?)

        /// Rename the collection.
        case rename(LibraryCollection)
    }

    @ObservedObject private var model: ApplicationLibraryModel
    private let mode: Mode
    private let onFinished: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var submissionProblem: String? = nil
    @State private var isSaving = false
    @FocusState private var isFieldFocused: Bool

    init(model: ApplicationLibraryModel, mode: Mode, onFinished: @escaping (Bool) -> Void = { _ in }) {
        _model = ObservedObject(wrappedValue: model)
        self.mode = mode
        self.onFinished = onFinished
        switch mode {
        case .create:
            _name = State(initialValue: "")
        case .rename(let collection):
            _name = State(initialValue: collection.name)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Collection Name", text: $name)
                        .focused($isFieldFocused)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit {
                            Task { await save() }
                        }
                        .accessibilityHint("Up to \(LibraryCollection.maximumNameLength) characters")
                } footer: {
                    if let problem = visibleProblem {
                        Label(problem, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                    } else {
                        Text(hint)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                        onFinished(false)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveTitle) {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                }
            }
            .onChange(of: name) { _, _ in
                submissionProblem = nil
            }
            .onAppear {
                isFieldFocused = true
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isSaving)
    }

    private var title: String {
        switch mode {
        case .create: return "New Collection"
        case .rename: return "Rename Collection"
        }
    }

    private var saveTitle: String {
        switch mode {
        case .create: return "Create"
        case .rename: return "Save"
        }
    }

    private var hint: String {
        switch mode {
        case .create(let ids, let source):
            if ids.isEmpty {
                return "Collections group apps without moving or copying them. An app can be in any number of collections."
            }
            let count = ApplicationLibraryModel.applicationCount(ids.count)
            return source == nil
                ? "The new collection will contain \(count). They stay in your library and in their other collections."
                : "\(count) will move to the new collection. They stay in your library."
        case .rename:
            return "Renaming changes only the collection's name. Its apps are unchanged."
        }
    }

    private var renamingID: LibraryCollectionIdentifier? {
        if case .rename(let collection) = mode { return collection.id }
        return nil
    }

    private var liveProblem: String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return model.collectionNameProblem(name, renaming: renamingID)
    }

    private var visibleProblem: String? {
        submissionProblem ?? liveProblem
    }

    private var canSave: Bool {
        !isSaving && LibraryCollection.normalizedName(name) != nil && liveProblem == nil
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }
        let problem: String?
        switch mode {
        case .create(let ids, let source):
            problem = await model.createCollection(named: name, adding: ids, movingFrom: source)
        case .rename(let collection):
            problem = await model.renameCollection(collection.id, to: name)
        }
        if let problem {
            submissionProblem = problem
            LibraryAnnouncer.announce(problem)
        } else {
            dismiss()
            onFinished(true)
        }
    }
}

// MARK: - Choosing a collection

/// Puts applications into a collection: lists the collections, marks the
/// ones already holding every application, and offers a new collection.
/// From inside a collection the choice moves the applications there; from
/// anywhere else it adds them, and they stay wherever else they are.
struct LibraryCollectionPicker: View {

    @ObservedObject var model: ApplicationLibraryModel
    let request: LibraryCollectionPickerRequest
    var onFinished: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var nameRequest: LibraryCollectionNameRequest? = nil

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        startNewCollection()
                    } label: {
                        Label("New Collection…", systemImage: "folder.badge.plus")
                    }
                } footer: {
                    Text(explanation)
                }
                if model.userCollections.isEmpty {
                    Section {
                        LibraryNoCollectionsView(onCreate: startNewCollection)
                            .listRowBackground(Color.clear)
                    }
                } else {
                    Section("Collections") {
                        ForEach(model.userCollections) { collection in
                            row(for: collection)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(item: $nameRequest) { request in
                LibraryCollectionNameSheet(model: model, mode: request.mode) { created in
                    if created {
                        dismiss()
                        onFinished()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var title: String {
        let count = ApplicationLibraryModel.applicationCount(request.recordIDs.count)
        return request.source == nil ? "Add \(count) to…" : "Move \(count) to…"
    }

    private var explanation: String {
        if let source = request.source, let name = model.collection(withID: source)?.name {
            return "The apps leave “\(name)” and join the collection you choose. Nothing is deleted."
        }
        return "The apps join the collection you choose and stay in any others. Nothing is copied or deleted."
    }

    private func startNewCollection() {
        nameRequest = LibraryCollectionNameRequest(mode: .create(adding: request.recordIDs, movingFrom: request.source))
    }

    private func row(for collection: LibraryCollection) -> some View {
        let holdsAll = model.collection(collection.id, containsAll: request.recordIDs)
        let isSource = collection.id == request.source
        return Button {
            Task { await choose(collection) }
        } label: {
            HStack(spacing: ZSpacing.sm) {
                Label(collection.name, systemImage: "folder")
                    .foregroundStyle(.primary)
                Spacer(minLength: ZSpacing.xs)
                if holdsAll || isSource {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
                Text("\(model.index.memberCount(of: collection.id))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .disabled(holdsAll || isSource)
        .accessibilityLabel(collection.name)
        .accessibilityValue(holdsAll || isSource
                            ? "Already holds these apps"
                            : ApplicationLibraryModel.applicationCount(model.index.memberCount(of: collection.id)))
    }

    private func choose(_ collection: LibraryCollection) async {
        if let source = request.source {
            await model.move(request.recordIDs, from: source, to: collection.id)
        } else {
            await model.add(request.recordIDs, to: collection.id)
        }
        dismiss()
        onFinished()
    }
}

// MARK: - Managing collections

/// Every collection with its count: open one, create one, rename or delete
/// one. Deleting a collection is confirmed and never deletes its apps.
struct LibraryCollectionsManager: View {

    @ObservedObject var model: ApplicationLibraryModel
    let onOpen: (LibraryScope) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nameRequest: LibraryCollectionNameRequest? = nil
    @State private var pendingDeletion: LibraryCollection? = nil

    var body: some View {
        NavigationStack {
            Group {
                if model.userCollections.isEmpty {
                    LibraryNoCollectionsView(onCreate: startNewCollection)
                } else {
                    collectionList
                }
            }
            .navigationTitle("Collections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        startNewCollection()
                    } label: {
                        Label("New Collection", systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                }
            }
            .sheet(item: $nameRequest) { request in
                LibraryCollectionNameSheet(model: model, mode: request.mode)
            }
            .confirmationDialog(
                "Delete Collection?",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDeletion
            ) { collection in
                Button("Delete “\(collection.name)”", role: .destructive) {
                    pendingDeletion = nil
                    Task { await model.deleteCollection(collection.id) }
                }
                Button("Cancel", role: .cancel) {
                    pendingDeletion = nil
                }
            } message: { collection in
                Text("Only the collection is deleted. Its \(ApplicationLibraryModel.applicationCount(model.index.memberCount(of: collection.id))) stay in your library.")
            }
        }
    }

    private var collectionList: some View {
        List {
            Section {
                ForEach(model.userCollections) { collection in
                    Button {
                        onOpen(.collection(collection.id))
                        dismiss()
                    } label: {
                        HStack(spacing: ZSpacing.sm) {
                            Label(collection.name, systemImage: "folder")
                                .foregroundStyle(.primary)
                            Spacer(minLength: ZSpacing.xs)
                            Text("\(model.index.memberCount(of: collection.id))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel(collection.name)
                    .accessibilityValue(ApplicationLibraryModel.applicationCount(model.index.memberCount(of: collection.id)))
                    .accessibilityHint("Shows the collection's apps")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeletion = collection
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            nameRequest = LibraryCollectionNameRequest(mode: .rename(collection))
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
                    .contextMenu {
                        Button {
                            nameRequest = LibraryCollectionNameRequest(mode: .rename(collection))
                        } label: {
                            Label("Rename…", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            pendingDeletion = collection
                        } label: {
                            Label("Delete Collection…", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                Text("Collections group apps without copying them. Deleting a collection never deletes its apps.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func startNewCollection() {
        nameRequest = LibraryCollectionNameRequest(mode: .create(adding: [], movingFrom: nil))
    }
}

// MARK: - Quick actions

/// The per-application quick actions, shared by the context menu of every
/// row and card and by the detail screen's Actions menu: View Details,
/// Favorite, Sign, Verify, Export, Move to Collection, collection
/// membership, Remove from Collection, and Delete. Actions that need a
/// package file are disabled, with the reason in their name, when it is
/// missing.
struct LibraryQuickActionItems: View {

    @ObservedObject var model: ApplicationLibraryModel
    let entry: LibraryEntry
    let features: LibraryFeatureAvailability
    var onDetails: (() -> Void)?
    let onSign: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let id = entry.record.id
        Section {
            if let onDetails {
                Button(action: onDetails) {
                    Label("View Details", systemImage: "info.circle")
                }
            }
            Button {
                Task { await model.setFavorite(!entry.record.isFavorite, on: entry) }
            } label: {
                Label(
                    entry.record.isFavorite ? "Unfavorite" : "Favorite",
                    systemImage: entry.record.isFavorite ? "star.slash" : "star"
                )
            }
        }
        if features.powerFeatures {
            Section {
                if features.signing {
                    Button(action: onSign) {
                        Label(entry.isArtifactAvailable ? "Sign…" : "Sign… (Package Unavailable)", systemImage: "signature")
                    }
                    .disabled(!entry.isArtifactAvailable)
                }
                Button {
                    Task { await model.verify([id]) }
                } label: {
                    Label("Verify Package", systemImage: "checkmark.shield")
                }
                .disabled(model.isBusy)
                if model.canExport {
                    Button {
                        Task { await model.export([id]) }
                    } label: {
                        Label(entry.isArtifactAvailable ? "Export…" : "Export… (Package Unavailable)", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!entry.isArtifactAvailable || model.isBusy)
                }
            }
            if model.canOrganize {
                Section {
                    Button(action: onMove) {
                        Label(model.scope.collectionID == nil ? "Add to Collection…" : "Move to Collection…", systemImage: "folder.badge.plus")
                    }
                    if !model.userCollections.isEmpty {
                        Menu {
                            ForEach(model.userCollections) { collection in
                                Toggle(isOn: membershipBinding(for: id, in: collection.id)) {
                                    Text(collection.name)
                                }
                            }
                        } label: {
                            Label("Collections", systemImage: "folder")
                        }
                    }
                    if let collectionID = model.scope.collectionID, model.collection(collectionID, containsAll: [id]) {
                        Button {
                            Task { await model.remove([id], fromCollection: collectionID) }
                        } label: {
                            Label("Remove from Collection", systemImage: "folder.badge.minus")
                        }
                    }
                }
            }
        }
        Section {
            Button(role: .destructive, action: onDelete) {
                Label("Delete…", systemImage: "trash")
            }
        }
    }

    private func membershipBinding(
        for id: ApplicationRecordIdentifier,
        in collectionID: LibraryCollectionIdentifier
    ) -> Binding<Bool> {
        Binding(
            get: { model.collection(collectionID, containsAll: [id]) },
            set: { _ in
                Task { await model.toggleMembership(of: id, in: collectionID) }
            }
        )
    }
}

// MARK: - Detail destination

/// The detail screen for one library application, as pushed from the
/// library.
///
/// It shows the application's `ApplicationDetailView` for the entry as the
/// library holds it *now* — looked up by identifier on every render, so a
/// favourite toggled here or elsewhere shows at once — and adds the
/// library's own controls: a one-tap favourite star and the quick-actions
/// menu. Opening it records the application as opened, for the Last Opened
/// order. If the application leaves the library while the screen is open,
/// the screen says so instead of showing stale data.
struct LibraryDetailDestination: View {

    @ObservedObject var model: ApplicationLibraryModel
    let recordID: ApplicationRecordIdentifier
    let bundleInspection: IPABundleContentsInspection
    let features: LibraryFeatureAvailability
    let onSign: () -> Void
    let onMove: () -> Void
    let onDelete: (LibraryEntry) -> Void

    var body: some View {
        if let entry = model.entry(for: recordID) {
            ApplicationDetailView(entry: entry, bundleInspection: bundleInspection)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        favoriteButton(entry)
                        if features.powerFeatures {
                            Menu {
                                LibraryQuickActionItems(
                                    model: model,
                                    entry: entry,
                                    features: features,
                                    onDetails: nil,
                                    onSign: onSign,
                                    onMove: onMove,
                                    onDelete: { onDelete(entry) }
                                )
                            } label: {
                                Label("Actions", systemImage: "ellipsis.circle")
                            }
                            .accessibilityLabel("Actions for \(entry.record.displayName ?? "application")")
                        }
                    }
                }
                .task(id: recordID) {
                    await model.recordOpened(recordID)
                }
        } else {
            LibraryEntryUnavailableView()
        }
    }

    private func favoriteButton(_ entry: LibraryEntry) -> some View {
        Button {
            ZHaptics.tap()
            Task { await model.setFavorite(!entry.record.isFavorite, on: entry) }
        } label: {
            Label(
                entry.record.isFavorite ? "Unfavorite" : "Favorite",
                systemImage: entry.record.isFavorite ? "star.fill" : "star"
            )
        }
        .tint(.yellow)
        .accessibilityLabel(entry.record.isFavorite ? "Remove from Favorites" : "Add to Favorites")
    }
}
