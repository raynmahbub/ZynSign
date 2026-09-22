import SwiftUI

/// The Applications area of the shell: ZynSign's application library.
///
/// The screen presents the persisted records of accepted imports and offers
/// the two operations this build supports: importing another package through
/// the existing document-import workflow, and deleting an entry together
/// with the package file behind it. Each record opens a detail screen, from
/// which the bundle explorer lists the package's contents read-only. There
/// are deliberately no signing, installation, or verification controls —
/// those capabilities do not exist in this build, and a control that
/// pretended otherwise would misrepresent the application.
struct ApplicationLibraryView: View {

    @StateObject private var model: ApplicationLibraryModel
    @StateObject private var importing: PackageImportModel
    @State private var isShowingImporter = false
    @State private var entryPendingRemoval: LibraryEntry?
    private let bundleInspection: IPABundleContentsInspection

    /// Creates the screen over the library, import, and bundle inspection
    /// use cases the composition root supplied. The import presentation
    /// model is the same phase machine the Import area uses; the library
    /// model observes its outcomes, so a successful import refreshes the
    /// list. The inspection use case is handed on to the detail screen,
    /// which offers the bundle explorer.
    init(library: ApplicationLibrary, importing: IPAPackageImport, bundleInspection: IPABundleContentsInspection) {
        let importModel = PackageImportModel(importing: importing)
        _importing = StateObject(wrappedValue: importModel)
        _model = StateObject(wrappedValue: ApplicationLibraryModel(library: library, importing: importModel))
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
                .navigationTitle(ShellSection.applications.title)
                .navigationDestination(for: LibraryEntry.self) { entry in
                    ApplicationDetailView(entry: entry, bundleInspection: bundleInspection)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isShowingImporter = true
                        } label: {
                            Label("Import Package…", systemImage: "square.and.arrow.down")
                        }
                        .disabled(importing.phase == .importing)
                    }
                }
        }
        .task { await model.load() }
        .safeAreaInset(edge: .bottom) { importStatus }
        .fileImporter(
            isPresented: $isShowingImporter,
            allowedContentTypes: ImportablePackage.contentTypes
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
                Task { await model.remove(entry) }
            }
            Button("Cancel", role: .cancel) {
                entryPendingRemoval = nil
            }
        } message: { entry in
            Text("“\(ApplicationLibraryRowContent(entry: entry).name)” and its package file will be permanently deleted from ZynSign's library. This cannot be undone.")
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
        case .loaded(let entries):
            libraryList(entries)
        }
    }

    private var emptyContent: some View {
        ContentUnavailableView {
            Label("No Applications", systemImage: ShellSection.applications.symbolName)
        } description: {
            Text("Applications you import appear here. Importing reads a package's structure and the information its application declares, and keeps the package in ZynSign's library. Import does not sign or install anything.")
        } actions: {
            Button("Import Package…") {
                isShowingImporter = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func libraryList(_ entries: [LibraryEntry]) -> some View {
        List {
            ForEach(entries, id: \.record.id) { entry in
                libraryRow(for: entry)
            }
        }
        .refreshable { await model.refresh() }
    }

    private func libraryRow(for entry: LibraryEntry) -> some View {
        NavigationLink(value: entry) {
            ApplicationLibraryRow(entry: entry)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                entryPendingRemoval = entry
            } label: {
                Label("Delete", systemImage: "trash")
            }
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
        }
    }
}

// MARK: - Row

/// One library entry in the list: the application's declared name,
/// identifier, and declared versions, with the artifact's availability
/// flagged when the package file is not what the record expects.
struct ApplicationLibraryRow: View {

    let entry: LibraryEntry

    var body: some View {
        let content = ApplicationLibraryRowContent(entry: entry)
        VStack(alignment: .leading, spacing: 4) {
            Text(content.name)
                .font(.body)
                .foregroundStyle(.primary)
            Text(content.bundleIdentifier)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(content.versionText ?? "No Declared Version")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let availabilityText = content.availabilityText {
                Label(availabilityText, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        // The row is read as one element: name, identifier, versions, and —
        // when present — the artifact problem, so nothing depends on visual
        // styling alone.
        .accessibilityElement(children: .combine)
    }
}

/// The display values for one library row, derived from the entry.
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

// MARK: - Loading and failure presentations

/// The presentation shown while the library is being read from persistence.
/// It exists so an empty library is never shown while records are still
/// being read.
struct ApplicationLibraryLoadingView: View {

    var body: some View {
        ProgressView {
            Text("Loading Library…")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The presentation shown when the library could not be read at all. The
/// message is the typed error's user-facing text; the retry action re-reads
/// persistence.
struct ApplicationLibraryFailureView: View {

    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Library Unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { retry() }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Previews

/// One environment shared by the screen previews, so a preview that imports
/// acts on the same library the screen displays.
private let previewEnvironment = CompositionRoot.makeApplicationEnvironment()

/// Representative library entries: a fully declared application, one with a
/// long declared name and identifier, one that declared nothing optional,
/// and two whose package files are missing or no longer match their records.
private enum PreviewFixtures {

    static func record(
        identity: ApplicationIdentity,
        importedAt: Date = Date(timeIntervalSinceReferenceDate: 750_000_000)
    ) -> ApplicationRecord {
        ApplicationRecord(
            id: ApplicationRecordIdentifier(),
            identity: identity,
            executableName: nil,
            sourceFileName: "Example.ipa",
            artifact: ArtifactReference(
                artifactID: ArtifactIdentifier(),
                byteCount: 4_194_304,
                fingerprint: fingerprint
            ),
            inspection: ApplicationRecord.InspectionSummary(classification: .valid),
            importedAt: importedAt,
            updatedAt: importedAt
        )
    }

    static func identity(
        bundleIdentifier: String,
        displayName: String? = nil,
        shortVersion: String? = nil,
        build: String? = nil
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

    private static var fingerprint: ArtifactFingerprint {
        guard let fingerprint = ArtifactFingerprint(
            algorithm: .sha256,
            digestBytes: Array(repeating: 0xAB, count: 32)
        ) else {
            preconditionFailure("A 32-byte digest must always form a fingerprint.")
        }
        return fingerprint
    }

    static let complete = LibraryEntry(
        record: record(identity: identity(
            bundleIdentifier: "com.example.synthetic",
            displayName: "Example",
            shortVersion: "1.2",
            build: "34"
        )),
        artifactAvailability: .available
    )

    static let longDeclaredValues = LibraryEntry(
        record: record(identity: identity(
            bundleIdentifier: "com.example.very.long.bundle.identifier.an-example-application",
            displayName: "An Extremely Long Application Name That Must Still Wrap And Stay Readable",
            shortVersion: "10.4",
            build: "981"
        ), importedAt: Date(timeIntervalSinceReferenceDate: 750_000_060)),
        artifactAvailability: .available
    )

    static let undeclaredMetadata = LibraryEntry(
        record: record(identity: identity(bundleIdentifier: "com.example.minimal")),
        artifactAvailability: .available
    )

    static let missingArtifact = LibraryEntry(
        record: record(identity: identity(
            bundleIdentifier: "com.example.missing",
            displayName: "Missing Package",
            shortVersion: "2.0",
            build: "45"
        ), importedAt: Date(timeIntervalSinceReferenceDate: 750_000_120)),
        artifactAvailability: .missing
    )

    static let inconsistentArtifact = LibraryEntry(
        record: record(identity: identity(
            bundleIdentifier: "com.example.changed",
            displayName: "Changed Package",
            shortVersion: "0.9",
            build: "12"
        ), importedAt: Date(timeIntervalSinceReferenceDate: 750_000_180)),
        artifactAvailability: .inconsistent(recordedByteCount: 4_194_304, observedByteCount: 2_097_152)
    )

    static let all = [complete, longDeclaredValues, undeclaredMetadata, missingArtifact, inconsistentArtifact]
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

#Preview("Loading") {
    ApplicationLibraryLoadingView()
}

#Preview("Library Error") {
    ApplicationLibraryFailureView(
        message: "ZynSign could not access its application library."
    ) {}
}
