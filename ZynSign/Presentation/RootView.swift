import Combine
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
///
/// The shell is finally where the application-wide consequences of the user's
/// preferences are applied, because they are properties of the whole
/// interface rather than of any one screen: the colour scheme, the contrast,
/// whether ZynSign's own transitions animate, and whether the application is
/// locked. Applying them here is what makes a change in Settings take effect
/// everywhere at once.
struct RootView: View {

    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// The Settings Control Center's model: every preference, written once.
    @StateObject private var settings: SettingsCenterModel

    /// ZynSign's lock, over the same preferences.
    @StateObject private var appLock: AppLockController

    @State private var selected: ShellSection
    @State private var isShowingImport = false

    /// The jobs whose outcome has already been recorded, so an import is
    /// reported exactly once however many times the job list changes.
    @State private var reportedImportJobs: Set<ImportJobIdentifier> = []

    /// Ticks while the shell is open, so a lapsed session can be noticed.
    private let inactivityTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    /// Builds the shell over one environment.
    ///
    /// The settings model and the lock are created here, once, from that
    /// environment, and installed into the hierarchy — so the Settings area,
    /// the Security Center, and the lock overlay all act on the same
    /// preferences and the same lock state.
    init(environment: ApplicationEnvironment = CompositionRoot.makeApplicationEnvironment()) {
        let model = SettingsCenterModel(store: environment.preferencesStore, environment: environment)
        _settings = StateObject(wrappedValue: model)
        _appLock = StateObject(wrappedValue: AppLockController(
            authenticator: environment.biometricAuthenticator,
            preferences: { model.preferences }
        ))
        _selected = State(initialValue: model.preferences.general.landingTab.shellSection)
    }

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
        .environment(\.settingsCenter, settings)
        .environment(\.appLock, appLock)
        .preferredColorScheme(settings.preferences.appearance.appearanceMode.resolvedColorScheme)
        .environment(
            \.colorSchemeContrast,
            settings.preferences.appearance.increaseContrast ? .increased : .standard
        )
        .transaction { transaction in
            // ZynSign's own transitions follow the animation preference. The
            // system's Reduce Motion setting is honoured on top of it, so a
            // user who asked for less motion never gets more.
            if !settings.preferences.general.animationPreference.permitsAnimation(
                systemReduceMotion: systemReduceMotion
            ) {
                transaction.animation = nil
            }
        }
        .onChange(of: settings.preferences.general.landingTab) { _, landingTab in
            selected = landingTab.shellSection
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                appLock.lockIfProtectionEnabled()
            case .active:
                appLock.refreshAvailability()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onReceive(inactivityTimer) { _ in
            appLock.evaluateInactivity()
        }
        .overlay {
            if appLock.isLocked {
                AppLockOverlay()
            }
        }
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
        .task {
            // Tidying scratch files at launch is the only maintenance the
            // shell performs, and only when the user's policy allows it.
            await settings.cleanTemporaryWorkspaceIfPolicyAllows()
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
                signingHistory: environment.signingHistory,
                organizer: environment.libraryOrganizer,
                provenance: environment.applicationProvenance,
                exporter: environment.libraryExport
            )
        case .certificates:
            NavigationStack {
                CertificateManagerView(
                    store: environment.identityStore,
                    annotations: environment.identityAnnotations,
                    importer: environment.pkcs12Importer
                )
            }
        case .profiles:
            ProfilesView(
                profiles: environment.provisioningProfiles,
                importer: environment.provisioningProfileImporter,
                compatibility: environment.profileCompatibility,
                selections: environment.profileSelections,
                recordEvent: { name, succeeded in
                    environment.recordAnalyticsEvent(
                        category: .intake,
                        name: name,
                        succeeded: succeeded
                    )
                }
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
