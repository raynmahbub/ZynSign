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
/// The shell is also the single owner of the import area. Every way a
/// package can arrive — a quick action, a toolbar button, a share-sheet
/// hand-off, a file opened into ZynSign — ends in the same place: a job in
/// `ApplicationEnvironment.packageImportQueue`, shown by the same
/// `ImportQueueView`. Screens ask for it through
/// `EnvironmentValues.importPresentation`; nothing presents a second,
/// competing import flow.
struct RootView: View {

    @Environment(\.applicationEnvironment) private var environment
    @State private var selected: ShellSection = .home
    @State private var isShowingImport = false

    /// The jobs whose outcome has already been recorded, so an import is
    /// reported exactly once however many times the job list changes.
    @State private var reportedImportJobs: Set<ImportJobIdentifier> = []

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
                isAvailable: true
            )
        )
        .sheet(isPresented: $isShowingImport) {
            ImportQueueView(
                queue: environment.packageImportQueue,
                onOpenLibrary: {
                    isShowingImport = false
                    selected = .library
                },
                onDone: { isShowingImport = false }
            )
        }
        .onOpenURL { url in acceptIncoming(url) }
        .onReceive(environment.packageImportQueue.$jobs) { jobs in
            reportOutcomes(of: jobs)
        }
    }

    // MARK: - Import

    /// Accepts a URL the system opened ZynSign for.
    ///
    /// ZynSign declares itself a viewer for packages, provisioning profiles,
    /// and identities, so this is reached for all three. Only packages are
    /// this area's business: a URL that is not a file, or whose name is not a
    /// package, is left alone rather than pushed at the queue — a profile or
    /// an identity arriving here keeps its own flow, and anything else is
    /// ignored rather than reported as a failed import.
    private func acceptIncoming(_ url: URL) {
        guard url.isFileURL, IPAFileFormat.accepts(url) else { return }
        environment.packageImportQueue.enqueue(url, origin: .shareSheet)
        isShowingImport = true
    }

    /// Records the local activity for each import that has settled since the
    /// last look. The event carries the category, a fixed name, and whether
    /// the package ended up in the library — never a file name, a location,
    /// or a bundle identifier.
    private func reportOutcomes(of jobs: [PackageImportQueue.Job]) {
        for job in jobs {
            guard let settlement = job.settlement else { continue }
            guard reportedImportJobs.insert(job.id).inserted else { continue }
            environment.recordAnalyticsEvent(
                category: .intake,
                name: settlement.kind.isAccepted ? "import.accepted" : "import.rejected",
                succeeded: settlement.kind.isAccepted
            )
        }
        // A job that was removed and enqueued again must be reportable again,
        // so the marks are pruned to what the queue still holds.
        let live = Set(jobs.map(\.id))
        reportedImportJobs.formIntersection(live)
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
                queue: environment.packageImportQueue,
                bundleInspection: environment.bundleInspection,
                detailsInspection: environment.applicationDetailsInspection,
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
