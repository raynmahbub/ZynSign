import SwiftUI

/// The root of the ZynSign interface: the tab shell the user navigates.
///
/// Five tabs, in the deliberate order ZynSign presents: Home → Library →
/// Certificates → Profiles → Settings. Each tab is a real area with its own
/// NavigationStack; no placeholder is shown. Home is the default selected
/// tab so a fresh install lands on the dashboard.
///
/// Files, App Store, and Downloads remain complete, reachable areas —
/// Settings → Browse links to them — but the bottom navigation is these
/// five tabs, which every later milestone builds on.
///
/// The shell is also the single owner of the Import Hub. Every way a
/// package can arrive — a quick action, a toolbar button, a share-sheet
/// hand-off, an Open In request, a drop, the ⌘I and ⌘O shortcuts — ends in
/// the same place: an item in `ApplicationEnvironment.importHub`, shown by
/// the same `ImportHubView`. Screens ask for it through
/// `EnvironmentValues.importPresentation`; nothing presents a second,
/// competing import flow.
///
/// At launch the shell asks the hub to restore interrupted imports and
/// sweeps the drop inbox; whenever the scene becomes active again it lets
/// the hub resume work the system paused in the background.
struct RootView: View {

    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var selected: ShellSection = .home
    @State private var isShowingImport = false
    @State private var hubRequest: ImportHubRequest = .none

    /// The items whose outcome has already been recorded, so an import is
    /// reported exactly once however many times the item list changes.
    @State private var reportedImportItems: Set<ImportJobIdentifier> = []

    var body: some View {
        TabView(selection: $selected) {
            ForEach(ShellSection.primaryTabs) { section in
                tabContent(section)
                    .tabItem {
                        Label(
                            section.title,
                            systemImage: selected == section ? section.symbolName : section.symbolNameUnselected
                        )
                    }
                    .tag(section)
            }
        }
        .tint(.primary)
        .environment(
            \.importPresentation,
            ImportPresentation(
                present: { isShowingImport = true },
                chooseFiles: { openHub(with: .chooseFiles) },
                isAvailable: true
            )
        )
        .sheet(isPresented: $isShowingImport) {
            ImportHubView(
                hub: environment.importHub,
                request: $hubRequest,
                onOpenLibrary: {
                    isShowingImport = false
                    selected = .library
                },
                onDone: { isShowingImport = false }
            )
        }
        .focusedSceneValue(
            \.importCommandActions,
            ImportCommandActions(
                openHub: { isShowingImport = true },
                chooseFiles: { openHub(with: .chooseFiles) },
                showHistory: { openHub(with: .history) }
            )
        )
        .onOpenURL { url in acceptIncoming(url) }
        .onReceive(environment.importHub.$items) { items in
            reportOutcomes(of: items)
        }
        .task {
            if let droppedFiles = environment.droppedFiles {
                await Task.detached(priority: .utility) { droppedFiles.sweep() }.value
            }
            await environment.importHub.restoreInterruptedImports()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                environment.importHub.resume()
            }
        }
    }

    // MARK: - Import

    /// Opens the Import Hub with a request for it to carry out.
    private func openHub(with request: ImportHubRequest) {
        hubRequest = request
        isShowingImport = true
    }

    /// Accepts a URL the system opened ZynSign for.
    ///
    /// ZynSign declares itself a viewer for packages, archives, provisioning
    /// profiles, and identities, so this is reached for all of them. Only
    /// packages and archives are the hub's business: a URL that is not a
    /// file, or whose name is neither, is left alone rather than pushed at
    /// the hub — a profile or an identity arriving here keeps its own flow,
    /// and anything else is ignored rather than reported as a failed import.
    ///
    /// A copy the system placed in ZynSign's own inbox came through the
    /// share sheet; anything else was opened in place.
    private func acceptIncoming(_ url: URL) {
        guard url.isFileURL, IPAFileFormat.acceptsForImport(url) else { return }
        let origin: ImportOrigin = Self.isShareSheetCopy(url) ? .shareSheet : .openIn
        environment.importHub.receive([url], origin: origin)
        isShowingImport = true
    }

    /// Whether `url` is a copy the system placed in ZynSign's own
    /// `Documents/Inbox` — which is where share-sheet hand-offs land.
    private static func isShareSheetCopy(_ url: URL) -> Bool {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return false
        }
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL.path + "/"
        return url.standardizedFileURL.path.hasPrefix(inbox)
    }

    /// Records the local activity for each import that has settled since the
    /// last look. The event carries the category, a fixed name, and whether
    /// the package ended up in the library — never a file name, a location,
    /// or a bundle identifier.
    private func reportOutcomes(of items: [ImportHub.Item]) {
        for item in items {
            guard let settlement = item.settlement else { continue }
            guard reportedImportItems.insert(item.id).inserted else { continue }
            let name: String
            switch settlement.kind.bucket {
            case .imported, .replaced: name = "import.accepted"
            case .skipped: name = "import.skipped"
            case .failed: name = "import.rejected"
            }
            environment.recordAnalyticsEvent(
                category: .intake,
                name: name,
                succeeded: settlement.kind.bucket != .failed
            )
        }
        // An item that was retried or removed must be reportable again, so
        // the marks are pruned to what the hub still holds settled.
        let live = Set(items.filter { $0.settlement != nil }.map(\.id))
        reportedImportItems.formIntersection(live)
    }

    // MARK: - Tabs

    /// The view each tab presents. Every tab owns a NavigationStack, so a
    /// tab's push state is its own.
    @ViewBuilder
    private func tabContent(_ section: ShellSection) -> some View {
        switch section {
        case .home:
            HomeView(onOpenSection: { selected = $0 })
        case .library:
            ApplicationLibraryView(
                library: environment.library,
                hub: environment.importHub,
                bundleInspection: environment.bundleInspection,
                signingHistory: environment.signingHistory
            )
        case .certificates:
            NavigationStack { CertificatesView() }
        case .profiles:
            ProfilesView(
                profiles: environment.provisioningProfiles,
                importer: environment.provisioningProfileImporter
            )
        case .settings:
            SettingsView()
        case .files, .appStore, .downloads:
            // Secondary sections are linked from Settings → Browse; they are
            // not tabs. Each carries its own NavigationStack where presented.
            EmptyView()
        }
    }
}

#Preview {
    RootView().environment(\.applicationEnvironment, CompositionRoot.makeApplicationEnvironment())
}
