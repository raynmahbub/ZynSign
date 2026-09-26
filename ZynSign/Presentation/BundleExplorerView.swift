import SwiftUI

/// The IPA explorer: a read-only browser of a library application's package.
///
/// The screen is reached from the application detail screen when the
/// record's package is available. It reads the bundle's structure once,
/// through the inspection use case, and then browses that value. Opening a
/// file asks the separate entry-preview use case for one bounded read. The
/// phases mirror the library screen — loading, loaded, empty, failed — so an
/// empty bundle is never shown while the package is still being read and a
/// failure is never silently dropped.
///
/// Nothing on this screen writes, extracts, signs, or runs the package.
struct BundleExplorerView: View {

    @StateObject private var model: BundleExplorerModel
    private let recordID: ApplicationRecordIdentifier

    /// Creates the explorer for `entry`, over the inspection use case the
    /// composition root supplied. Previews use the entry-inspection use case
    /// from the application environment.
    init(inspection: IPABundleContentsInspection, entry: LibraryEntry) {
        recordID = entry.record.id
        _model = StateObject(
            wrappedValue: BundleExplorerModel(inspection: inspection, recordID: entry.record.id)
        )
    }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await model.load()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            BundleExplorerLoadingView()
        case .loaded(let contents):
            IPAExplorerScreen(contents: contents, recordID: recordID)
        case .empty:
            BundleExplorerEmptyView()
        case .failed(let message):
            BundleExplorerFailureView(message: message) {
                Task { await model.load() }
            }
        }
    }

    private var title: String {
        switch model.phase {
        case .loaded(let contents):
            return contents.bundleName
        case .empty(let bundleName):
            return bundleName
        case .loading, .failed:
            return "Bundle"
        }
    }
}

// MARK: - Loading, empty, and failure presentations

/// The presentation shown while the package is being read. It exists so an
/// empty bundle is never shown while its entries are still being read.
struct BundleExplorerLoadingView: View {

    var body: some View {
        ProgressView {
            Text("Reading Bundle…")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The presentation shown when the bundle was read and holds no entries at
/// all. A finding about the package, shown only after the read completed.
struct BundleExplorerEmptyView: View {

    var body: some View {
        ContentUnavailableView {
            Label("Empty Bundle", systemImage: "folder")
        } description: {
            Text("The package records no files or folders inside the application bundle.")
        }
    }
}

/// The presentation shown when the bundle could not be read. The message is
/// the typed error's user-facing text; the retry action reads the package
/// again.
struct BundleExplorerFailureView: View {

    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Bundle Unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { retry() }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Previews

/// A synthetic bundle structure for the explorer previews: invented names
/// and sizes describing a plausible layout. No real package appears anywhere.
private enum PreviewFixtures {

    static let contents: BundleContents = {
        let bundle = "Payload/Example.app"
        func entry(_ name: String, kind: ArchiveEntryKind = .regularFile, size: Int = 0) -> ArchiveEntry? {
            ArchivePath(rawValue: "\(bundle)/\(name)").map {
                ArchiveEntry(path: $0, kind: kind, uncompressedSize: size, compressedSize: size)
            }
        }
        let table: [ArchiveEntry?] = [
            ArchivePath(rawValue: "Payload").map { ArchiveEntry(path: $0, kind: .directory) },
            ArchivePath(rawValue: bundle).map { ArchiveEntry(path: $0, kind: .directory) },
            entry("Info.plist", size: 1_842),
            entry("Example", size: 6_291_456),
            entry("embedded.mobileprovision", size: 12_288),
            entry("_CodeSignature", kind: .directory),
            entry("_CodeSignature/CodeResources", size: 24_576),
            entry("Frameworks", kind: .directory),
            entry("Frameworks/Example Core.framework", kind: .directory),
            entry("Frameworks/Example Core.framework/Example Core", size: 1_048_576),
            entry("Frameworks/Example Core.framework/Info.plist", size: 912),
            entry("Frameworks/Example Core.framework/Link", kind: .symbolicLink),
            entry("PlugIns", kind: .directory),
            entry("Assets.car", size: 2_097_152),
            entry("Base.lproj", kind: .directory),
            entry("Base.lproj/LaunchScreen.storyboardc", kind: .directory),
            entry("Base.lproj/Main.storyboardc", kind: .directory),
            entry("A file with an unusually long name that keeps going well past the width of any phone screen.txt", size: 64),
        ]
        guard let bundlePath = ArchivePath(rawValue: bundle) else {
            preconditionFailure("Preview fixture bundle path is not valid.")
        }
        return BundleContents(
            entryTable: table.compactMap { $0 },
            bundlePath: bundlePath,
            declaredExecutableName: "Example"
        )
    }()
}

#Preview("IPA Explorer") {
    IPAExplorerScreen(
        contents: PreviewFixtures.contents,
        recordID: ApplicationRecordIdentifier()
    )
}

#Preview("Bundle Root") {
    NavigationStack {
        BundleDirectoryView(contents: PreviewFixtures.contents, directory: .root)
    }
}

#Preview("Nested Directory") {
    NavigationStack {
        if let frameworks = BundlePath(rawValue: "Frameworks/Example Core.framework") {
            BundleDirectoryView(contents: PreviewFixtures.contents, directory: frameworks)
        }
    }
}

#Preview("Empty Directory") {
    NavigationStack {
        if let plugIns = BundlePath(rawValue: "PlugIns") {
            BundleDirectoryView(contents: PreviewFixtures.contents, directory: plugIns)
        }
    }
}

#Preview("Entry Detail") {
    NavigationStack {
        if let path = BundlePath(rawValue: "_CodeSignature/CodeResources"),
           let entry = PreviewFixtures.contents.entry(at: path) {
            BundleEntryDetailView(entry: entry)
        }
    }
}

#Preview("Loading") {
    BundleExplorerLoadingView()
}

#Preview("Empty Bundle") {
    BundleExplorerEmptyView()
}

#Preview("Bundle Error") {
    BundleExplorerFailureView(
        message: "The package for this application is missing from ZynSign's library, so its contents cannot be shown."
    ) {}
}
