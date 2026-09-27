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
///
/// The shell likewise owns the Signing Queue dashboard. Screens ask for it
/// through `EnvironmentValues.signingQueuePresentation`; the shell presents
/// it, shows the queue's notices as toasts and VoiceOver announcements,
/// badges the Library tab with the jobs still in flight, and restores the
/// persisted queue once per launch.
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
    @State private var hubRequest: ImportHubRequest = .none

    /// The items whose outcome has already been recorded, so an import is
    /// reported exactly once however many times the item list changes.
    @State private var reportedImportItems: Set<ImportJobIdentifier> = []

    @State private var isShowingSigningQueue = false

    /// The signing-queue notice currently shown as a toast, if any.
    @State private var visibleQueueNotice: SigningQueueNotice?
    @State private var isShowingQueueToast = false

    /// The number of active signing jobs shown as the Library tab's badge,
    /// so work in flight stays visible wherever the user navigates.
    @State private var activeSigningJobBadge = 0

    /// Active downloads, shown on the Downloads tab when that feature is on.
    @State private var activeDownloadBadge = 0

    /// The download notice currently shown as a toast, if any.
    @State private var visibleDownloadNotice: DownloadNotice?
    @State private var isShowingDownloadToast = false

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
            ForEach(visibleTabs) { section in
                tabContent(section)
                    .tabItem {
                        Label(
                            section.title,
                            systemImage: selected == section ? section.symbolName : section.symbolNameUnselected
                        )
                    }
                    .tag(section)
                    .badge(badgeCount(for: section))
            }
        }
        .tint(.primary)
        .environment(\.settingsCenter, settings)
        .environment(\.appLock, appLock)
        .environment(\.downloadNavigation, DownloadNavigation(
            openLibrary: { selected = .library },
            openSigningQueue: { presentSigningQueue() }
        ))
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
                // Work the system paused while ZynSign was in the background
                // continues now that the scene is active again.
                environment.importHub.resume()
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
        .environment(
            \.signingQueuePresentation,
            SigningQueuePresentation(
                present: { presentSigningQueue() },
                isAvailable: SigningQueueAvailability.isAvailable
            )
        )
        .sheet(isPresented: $isShowingSigningQueue) {
            SigningQueueView(
                queue: environment.signingQueue,
                onOpenLibrary: {
                    isShowingSigningQueue = false
                    selected = .library
                },
                onDone: { isShowingSigningQueue = false }
            )
        }
        .onReceive(environment.signingQueue.$pendingNotices.receive(on: DispatchQueue.main)) { notices in
            // Delivered after the change lands (a `@Published` emits before
            // storing), so acknowledging here can never be overwritten.
            showNextQueueNotice(from: notices)
        }
        .onReceive(environment.signingQueue.$jobs) { jobs in
            activeSigningJobBadge = SigningQueueAvailability.isAvailable
                ? jobs.filter { $0.isActive }.count
                : 0
        }
        .background {
            if let center = environment.downloadCenter {
                DownloadNoticeBridge(center: center, badge: $activeDownloadBadge) { notices in
                    showNextDownloadNotice(from: notices)
                }
            }
        }
        .zToast(
            isPresented: $isShowingDownloadToast,
            message: visibleDownloadNotice.map { "\($0.title) — \($0.message)" } ?? "",
            style: visibleDownloadNotice?.kind == .validationFailed ? .error : (visibleDownloadNotice?.kind == .updateAvailable ? .info : .success),
            duration: .seconds(4)
        )
        .onChange(of: isShowingDownloadToast) { _, isShowing in
            guard !isShowing else { return }
            visibleDownloadNotice = nil
            showNextDownloadNotice(from: environment.downloadCenter?.pendingNotices ?? [])
        }
        .zToast(
            isPresented: $isShowingQueueToast,
            message: visibleQueueNotice.map { "\($0.title) — \($0.message)" } ?? "",
            style: visibleQueueNotice?.kind == .jobFailed ? .error : .success,
            duration: .seconds(4)
        )
        .onChange(of: isShowingQueueToast) { _, isShowing in
            // A dismissed toast makes room for the next pending notice.
            guard !isShowing else { return }
            visibleQueueNotice = nil
            showNextQueueNotice(from: environment.signingQueue.pendingNotices)
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
            // Tidying scratch files at launch happens only when the user's
            // policy allows it, and it finishes before the hub restores
            // interrupted imports: the restoration then sees exactly the
            // working copies the policy kept (cleanup removes only data
            // older than an hour), rather than racing it.
            await settings.cleanTemporaryWorkspaceIfPolicyAllows()
            if let droppedFiles = environment.droppedFiles {
                await Task.detached(priority: .utility) { droppedFiles.sweep() }.value
            }
            await environment.importHub.restoreInterruptedImports()
            // Restore the persisted signing queue once per launch, after the
            // temporary-workspace cleanup has finished, so no queued run
            // starts while scratch data is being tidied. Restoration is
            // gated with the feature: a build that does not show the queue
            // never runs queued work behind the user's back.
            if SigningQueueAvailability.isAvailable {
                await environment.signingQueue.restore()
            }
            environment.repositoryDirectory?.load()
            environment.repositoryDirectory?.onCatalogsChanged = { [environment] in
                Task { await environment.downloadCenter?.refreshUpdates() }
            }
            environment.downloadCenter?.startObservingTransfers()
            await environment.downloadCenter?.restore()
            await environment.downloadCenter?.refreshUpdates()
        }
    }

    /// Tabs the user can select. Downloads is added when that feature is
    /// available, immediately before Settings, without removing the five-tab
    /// foundation the other sections are built on.
    private var visibleTabs: [ShellSection] {
        var tabs = ShellSection.primaryTabs
        guard ReleaseTrain.isAvailable(.downloads), let settings = tabs.firstIndex(of: .settings) else {
            return tabs
        }
        tabs.insert(.downloads, at: settings)
        return tabs
    }

    private func badgeCount(for section: ShellSection) -> Int {
        switch section {
        case .library: return activeSigningJobBadge
        case .downloads: return activeDownloadBadge
        default: return 0
        }
    }

    // MARK: - Signing queue

    /// Opens the signing queue dashboard. When the Import Hub is up, it is
    /// closed first and the dashboard follows once the sheet is gone —
    /// presenting over a dismissing sheet would race.
    private func presentSigningQueue() {
        guard SigningQueueAvailability.isAvailable else { return }
        if isShowingImport {
            isShowingImport = false
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                isShowingSigningQueue = true
            }
        } else {
            isShowingSigningQueue = true
        }
    }

    /// Shows the oldest pending queue notice: a toast (with its haptic) and
    /// a VoiceOver announcement. The notice is acknowledged as soon as it is
    /// on screen, so it is delivered exactly once however often the queue
    /// publishes.
    private func showNextQueueNotice(from notices: [SigningQueueNotice]) {
        guard SigningQueueAvailability.isAvailable else { return }
        guard visibleQueueNotice == nil, let next = notices.first else { return }
        visibleQueueNotice = next
        environment.signingQueue.acknowledgeNotice(next.id)
        // The toast plays its own haptic on appearing; nothing is doubled.
        AccessibilityNotification.Announcement(SigningQueueRendering.announcement(for: next)).post()
        environment.recordAnalyticsEvent(
            category: .signing,
            name: next.kind == .jobFailed ? "queue.job.failed" : (next.kind == .jobCompleted ? "queue.job.completed" : "queue.finished"),
            succeeded: next.kind != .jobFailed
        )
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            isShowingQueueToast = true
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
        case .presets:
            PresetsView()
        case .downloads:
            DownloadsView()
        case .files, .appStore:
            // Files and the App Store are linked from Settings → Browse.
            // Each carries its own NavigationStack where presented.
            EmptyView()
        }
    }

    private func showNextDownloadNotice(from notices: [DownloadNotice]) {
        guard ReleaseTrain.isAvailable(.downloads) else { return }
        guard visibleDownloadNotice == nil, let next = notices.first else { return }
        visibleDownloadNotice = next
        environment.downloadCenter?.acknowledgeNotice(next.id)
        AccessibilityNotification.Announcement(DownloadCenterRendering.announcement(for: next)).post()
        let name: String
        switch next.kind {
        case .downloadCompleted: name = "download.completed"
        case .validationFailed: name = "download.failed"
        case .updateAvailable: name = "download.updateAvailable"
        case .queueFinished: name = "download.queueFinished"
        }
        environment.recordAnalyticsEvent(
            category: .download,
            name: name,
            succeeded: next.kind != .validationFailed
        )
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            isShowingDownloadToast = true
        }
    }
}

private struct DownloadNoticeBridge: View {
    @ObservedObject var center: DownloadCenter
    @Binding var badge: Int
    var onNotices: ([DownloadNotice]) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: center.pendingNotices) { _, notices in
                onNotices(notices)
            }
            .onChange(of: center.jobs) { _, jobs in
                badge = jobs.filter(\.isTransferring).count
            }
            .onAppear {
                badge = center.jobs.filter(\.isTransferring).count
                onNotices(center.pendingNotices)
            }
    }
}

#Preview {
    RootView().environment(\.applicationEnvironment, CompositionRoot.makeApplicationEnvironment())
}
