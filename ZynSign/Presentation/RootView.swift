import Combine
import SwiftUI

/// The root of the ZynSign interface: the tab shell the user navigates.
///
/// The shell draws exactly five tabs — Home, Library, Store, Downloads, and
/// Settings, the Storefront shell order. The Files browser, the searchable
/// Features catalogue, and the signing materials live inside Settings; Store
/// and Downloads keep direct tabs when their release gates are open. Each
/// root destination keeps its own navigation state.
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
    /// The system's contrast choice — ZynSign follows it unless the
    /// appearance preference asks for more.
    @Environment(\.colorSchemeContrast) private var systemColorSchemeContrast

    /// The Settings Control Center's model: every preference, written once.
    @StateObject private var settings: SettingsCenterModel

    /// ZynSign's lock, over the same preferences.
    @StateObject private var appLock: AppLockController

    @State private var selected: ShellSection

    /// The tabs that have been opened at least once. A destination is built
    /// when it is first selected and kept alive afterwards, so state the user
    /// expects to persist — a scroll position, a push, an in-flight import —
    /// survives leaving a tab and coming back to it.
    @State private var visitedTabs: Set<ShellSection>

    @State private var isShowingImport = false
    @State private var hubRequest: ImportHubRequest = .none

    /// The combined signing-material screen is presented for a system-opened
    /// certificate/profile file; the selected segment follows the file type.
    @State private var isShowingSigningMaterials = false
    @State private var signingMaterialsSelection: SigningMaterialsSection = .certificates
    @State private var signingMaterialsImportURL: URL?

    /// A shell surface the app owes the user once the scene is active again.
    ///
    /// An Open In or share-sheet hand-off is delivered as ZynSign comes back
    /// to the foreground; UIKit drops a presentation asked for in that frame
    /// and the state that asked for it stays set, so the surface never opens
    /// and the screen looks like it did nothing. The request is held as the
    /// surface's name and any incoming document URL — no stored closure —
    /// and honoured the moment the scene is active.
    private enum ShellPresentation {
        case importHub
        case profiles(URL)
        case certificates(URL)
    }

    @State private var pendingShellPresentation: ShellPresentation?

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

    /// First-launch onboarding walkthrough.
    @State private var isShowingOnboarding = false

    /// The download notice currently shown as a toast, if any.
    @State private var visibleDownloadNotice: DownloadNotice?
    @State private var isShowingDownloadToast = false

    /// Ticks while the shell is open, so a lapsed session can be noticed.
    private let inactivityTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    /// The one thumbnail pipeline every icon view draws through, so a
    /// decoded icon is shared by every row and card that shows it.
    @StateObject private var thumbnailPipeline: ThumbnailPipeline

    /// The order launch work runs in. Nothing in it precedes the first
    /// frame; see `StartupWorkPlan`.
    private let startupPlan = StartupWorkPlan.standard

    /// Builds the shell over one environment.
    ///
    /// The settings model and the lock are created here, once, from that
    /// environment, and installed into the hierarchy — so the Settings area,
    /// the Security Center, and the lock overlay all act on the same
    /// preferences and the same lock state.
    init(environment: ApplicationEnvironment) {
        let model = SettingsCenterModel(store: environment.preferencesStore, environment: environment)
        _settings = StateObject(wrappedValue: model)
        _appLock = StateObject(wrappedValue: AppLockController(
            authenticator: environment.biometricAuthenticator,
            preferences: { model.preferences }
        ))
        let landing = Self.visibleSelection(
            for: model.preferences.general.landingTab.selectable.shellSection
        )
        _selected = State(initialValue: landing)
        _visitedTabs = State(initialValue: [landing])
        _thumbnailPipeline = StateObject(wrappedValue: ThumbnailPipeline(
            engine: environment.performanceEngine,
            icons: environment.appIcons
        ))
        environment.performanceEngine?.launch.mark(LaunchTimeline.Milestone.environmentReady)
    }

    /// One motion policy for the environment and for `ZMotion`'s static presets.
    private var motion: ZMotion {
        let resolved = ZMotion(reduceMotion: systemReduceMotion, preference: settings.preferences.general.animationPreference)
        ZMotion.permitsAnimationGlobally = resolved.permitsAnimation
        return resolved
    }

    var body: some View {
        environmentRoot
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
                openHub: { presentImportHub() },
                chooseFiles: { openHub(with: .chooseFiles) },
                showHistory: { openHub(with: .history) }
            )
        )
        .onOpenURL { url in acceptIncoming(url) }
        .onReceive(environment.importHub.$items) { items in
            reportOutcomes(of: items)
        }
        .task {
            await runStartupWork()
        }
    }

    /// Sheets, covers, and the bridges behind them, applied to the
    /// configured root — another chain split out of `body`.
    private var environmentRoot: some View {
        configuredRoot
        .environment(
            \.importPresentation,
            ImportPresentation(
                present: { presentImportHub() },
                chooseFiles: { openHub(with: .chooseFiles) },
                isAvailable: true
            )
        )
        .environment(
            \.signingMaterialsPresentation,
            SigningMaterialsPresentation(
                importIdentity: { url in presentWhenActive(.certificates(url)) },
                importProfile: { url in presentWhenActive(.profiles(url)) },
                isAvailable: true
            )
        )
        .sheet(isPresented: $isShowingImport, onDismiss: { presentPendingShellPresentation() }) {
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
        .sheet(
            isPresented: $isShowingSigningMaterials,
            onDismiss: {
                signingMaterialsImportURL = nil
                presentPendingShellPresentation()
            }
        ) {
            NavigationStack {
                SigningMaterialsView(
                    initialSelection: signingMaterialsSelection,
                    incomingURL: $signingMaterialsImportURL,
                    embedsNavigationStack: false
                )
            }
            .id(signingMaterialsSelection)
        }
        .environment(
            \.signingQueuePresentation,
            SigningQueuePresentation(
                present: { presentSigningQueue() },
                isAvailable: SigningQueueAvailability.isAvailable
            )
        )
        .sheet(isPresented: $isShowingSigningQueue, onDismiss: { presentPendingShellPresentation() }) {
            SigningQueueView(
                queue: environment.signingQueue,
                onOpenLibrary: {
                    isShowingSigningQueue = false
                    selected = .library
                },
                onDone: { isShowingSigningQueue = false }
            )
        }
        .fullScreenCover(isPresented: $isShowingOnboarding, onDismiss: { presentPendingShellPresentation() }) {
            ZOnboardingView(
                isPresented: $isShowingOnboarding,
                onComplete: {
                    settings.update { $0.general.onboardingCompleted = true }
                }
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
    }

    /// The theme the whole interface renders with, resolved once from
    /// preferences so every screen agrees on accent, gradient, density, and
    /// whether the glass is on. The `ZGlass` mirror follows the resolution —
    /// the same one-place pattern `motion` uses for `ZMotion` — so a flip in
    /// Settings → Appearance turns every glass surface in the app at once.
    private var resolvedTheme: ResolvedAppTheme {
        let resolved = ResolvedAppTheme.resolve(settings.preferences.appearance)
        ZGlass.isEnabled = resolved.liquidGlass
        return resolved
    }

    /// The tabs with their environment, transaction rules, and lock
    /// overlay, split from `body` so each chain is a modest expression
    /// the type checker can solve on its own.
    private var configuredRoot: some View {
        rootTabs
        .tint(resolvedTheme.accent)
        .zGlassNavigationChrome()
        .environment(\.appTheme, resolvedTheme)
        .environment(\.thumbnailPipeline, thumbnailPipeline)
        .environment(\.zMotion, motion)
        .environment(\.settingsCenter, settings)
        .environment(\.appLock, appLock)
        .environment(\.downloadNavigation, DownloadNavigation(
            openLibrary: { selected = .library },
            openSigningQueue: { presentSigningQueue() }
        ))
        .preferredColorScheme(settings.preferences.appearance.appearanceMode.resolvedColorScheme)
        .environment(
            \.preferredColorSchemeContrast,
            settings.preferences.appearance.increaseContrast ? .increased : systemColorSchemeContrast
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
            selected = Self.visibleSelection(for: landingTab.selectable.shellSection)
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
                // A surface asked for while ZynSign was away opens only when
                // its shell sheet is also free to present it.
                presentPendingShellPresentation()
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
    }

    /// The tab container, split from `body` so the type checker solves the
    /// tab list and the environment chain as two modest expressions.
    ///
    /// The shell draws its own bar (`ShellTabBar`) rather than using UIKit's,
    /// whose five-item ceiling folds the rest of the product into a pushed
    /// *More* list — the crash this shell used to work around by hiding
    /// destinations. Content is laid out behind that bar, and a destination is
    /// built the first time it is selected and kept alive afterwards, so each
    /// area keeps its scroll position, push state, and in-flight work: the
    /// lifetime a `TabView` gives, without the ceiling.
    private var rootTabs: some View {
        ZStack {
            ForEach(visibleTabs) { section in
                if visitedTabs.contains(section) {
                    tabContent(section)
                        .opacity(section == selected ? 1 : 0)
                        .zIndex(section == selected ? 1 : 0)
                        .allowsHitTesting(section == selected)
                        .accessibilityHidden(section != selected)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ShellTabBar(tabs: visibleTabs, selection: $selected, badgeCount: badgeCount(for:))
        }
        .onChange(of: selected) { _, section in
            visitedTabs.insert(section)
        }
        .animation(motion.fast, value: selected)
    }

    // MARK: - Launch

    /// Runs the launch work the plan defers past the first frame.
    ///
    /// The Home screen is already on screen when this starts: `.task`
    /// fires once the view is attached, the first frame is marked, and
    /// the plan's deferral delay then keeps the initial layout and tab bar
    /// animation from competing with restoration. Items that touch main-
    /// actor state run here in order; sweeps and cache work go to the
    /// background scheduler at maintenance priority.
    ///
    /// The order is the one the earlier shell used and for the same
    /// reasons: tidying scratch files happens only when the user's policy
    /// allows it and finishes before the hub restores interrupted imports,
    /// so the restoration sees exactly the working copies the policy kept;
    /// the signing queue is restored after that, and only in a build that
    /// shows it, so no queued run starts behind the user's back. The
    /// repository directory and Download Center follow once the plan's
    /// items are done, as they did before.
    private func runStartupWork() async {
        let engine = environment.performanceEngine
        engine?.launch.mark(LaunchTimeline.Milestone.firstFrame)
        engine?.launch.mark(LaunchTimeline.Milestone.essentialWorkDone)
        try? await Task.sleep(for: startupPlan.deferralDelay)
        engine?.launch.mark(LaunchTimeline.Milestone.deferredWorkStarted)
        for item in startupPlan.deferred {
            switch item {
            case .temporaryCleanup:
                await settings.cleanTemporaryWorkspaceIfPolicyAllows()
            case .restoreInterruptedImports:
                await environment.importHub.restoreInterruptedImports()
            case .sweepDropInbox:
                guard let droppedFiles = environment.droppedFiles else { continue }
                if let engine {
                    await engine.scheduler.schedule(key: "startup.sweepDropInbox", priority: .maintenance) {
                        droppedFiles.sweep()
                    }
                } else {
                    await Task.detached(priority: .utility) { droppedFiles.sweep() }.value
                }
            case .restoreSigningQueue:
                if SigningQueueAvailability.isAvailable {
                    await environment.signingQueue.restore()
                }
            case .reconcileIndexes:
                // The library model reconciles the metadata index as it
                // loads; at launch the persisted index is warmed so the
                // first read is a memory read.
                guard let engine else { continue }
                await engine.scheduler.schedule(key: "startup.warmMetadataIndex", priority: .maintenance) {
                    _ = await engine.metadata.current()
                }
            case .enforceCachePolicies:
                await engine?.scheduleMaintenance()
            case .startMemoryObservation:
                await engine?.startMemoryObservation()
            }
        }
        environment.repositoryDirectory?.load()
        environment.repositoryDirectory?.onCatalogsChanged = { [environment] in
            Task { await environment.downloadCenter?.refreshUpdates() }
        }
        environment.downloadCenter?.startObservingTransfers()
        await environment.downloadCenter?.restore()
        await environment.downloadCenter?.refreshUpdates()
        engine?.launch.mark(LaunchTimeline.Milestone.deferredWorkDone)
        if let engine, let firstFrame = engine.launch.timeToFirstFrame {
            await engine.benchmarks.record(kind: .launch, duration: firstFrame, itemCount: 1)
        }
        if !settings.preferences.general.onboardingCompleted {
            isShowingOnboarding = true
        }
    }

    /// Tabs the user can select at this release stop.
    ///
    /// Every destination the running release exposes is a tab: the staged ones
    /// follow the release gate, and the ungated ones are always present, so
    /// there is always somewhere to land.
    private var visibleTabs: [ShellSection] {
        ShellSection.primaryTabs
    }

    /// The root tab to select for a requested section. A destination that is
    /// a tab is selected; the Files browser, the Features catalogue, and the
    /// signing tools name Settings, and a gated destination resolves to
    /// Settings or the Library.
    static func visibleSelection(for section: ShellSection) -> ShellSection {
        visibleSelection(for: section, in: ShellSection.primaryTabs)
    }

    /// The clamp itself, against an explicit tab list — so the fallback is
    /// testable at a stop where the section is missing, which the live train
    /// only reaches in a Release build.
    static func visibleSelection(for section: ShellSection, in tabs: [ShellSection]) -> ShellSection {
        if tabs.contains(section) { return section }
        if section == .files || section == .features || section == .presets || section == .install
            || section == .certificates || section == .profiles
            || section == .appStore || section == .downloads {
            return tabs.contains(.settings) ? .settings : (tabs.contains(.library) ? .library : (tabs.first ?? .settings))
        }
        return tabs.contains(.library) ? .library : (tabs.first ?? .settings)
    }

    /// Home can request any destination it links to; a destination that is a
    /// root tab is selected, and one that lives inside Settings opens there.
    private func openHomeSection(_ section: ShellSection) {
        selected = ShellSection.tab(toOpen: section)
    }

    private func badgeCount(for section: ShellSection) -> Int {
        switch section {
        case .library:
            return activeSigningJobBadge
        case .downloads:
            // Downloads is a tab of its own again. The badge follows the same
            // gate as the tab, so a build without the destination holds no
            // state for it.
            return ReleaseTrain.isAvailable(.downloads) ? activeDownloadBadge : 0
        default:
            return 0
        }
    }

    // MARK: - Signing queue

    /// Opens the signing queue dashboard. When the Import Hub is up, it is
    /// closed first and the dashboard follows once the sheet is gone —
    /// presenting over a dismissing sheet would race.
    private func presentSigningQueue() {
        guard SigningQueueAvailability.isAvailable else { return }
        guard isShowingImport else {
            isShowingSigningQueue = true
            return
        }
        // The hub is up, and a sheet raised in the frame it is dismissing is
        // dropped by UIKit with no error: the queue would simply never open.
        // The retry is the platform's report that the hierarchy is idle plus a
        // confirmation that the sheet appeared — not a fixed wait that a slow
        // device can outlast.
        isShowingImport = false
        Task { @MainActor in
            for _ in 0..<2 {
                if await PresentationSettle.presentAndConfirm({ isShowingSigningQueue = true }) {
                    return
                }
                isShowingSigningQueue = false
            }
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
        withAnimation(ZMotion.interactive) {
            isShowingQueueToast = true
        }
    }

    // MARK: - Import

    /// Opens the Import Hub with a request for it to carry out.
    private func openHub(with request: ImportHubRequest) {
        hubRequest = request
        presentImportHub()
    }

    /// Opens the Import Hub, or holds the request until the scene is active.
    private func presentImportHub() {
        presentWhenActive(.importHub)
    }

    /// Presents a shell surface now, or queues it until the scene and any
    /// already-presented ZynSign sheet are ready. A presentation requested
    /// while another application's controller is dismissing (the share sheet
    /// or Files hand-off) is also held until UIKit reports the whole chain idle.
    private func presentWhenActive(_ surface: ShellPresentation) {
        guard scenePhase == .active else {
            // First request wins: it is the one the user acted on, and the
            // surface it names is the one whose data is already arriving.
            if pendingShellPresentation == nil { pendingShellPresentation = surface }
            return
        }

        if isShowingSameSurface(as: surface) {
            // A second Open In can update the URL/selection of the already
            // visible signing-material screen without stacking another sheet.
            present(surface)
            return
        }
        guard !hasPresentedShellSurface else {
            if pendingShellPresentation == nil { pendingShellPresentation = surface }
            return
        }

        Task { @MainActor in
            guard await PresentationSettle.waitForIdle(cap: .seconds(8)) else {
                if pendingShellPresentation == nil { pendingShellPresentation = surface }
                return
            }
            guard scenePhase == .active else {
                if pendingShellPresentation == nil { pendingShellPresentation = surface }
                return
            }
            if isShowingSameSurface(as: surface) {
                present(surface)
            } else if hasPresentedShellSurface {
                if pendingShellPresentation == nil { pendingShellPresentation = surface }
            } else {
                present(surface)
            }
        }
    }

    /// A pending import is retried as soon as the shell sheet or onboarding
    /// cover that was in the way reports dismissal.
    private func presentPendingShellPresentation() {
        guard scenePhase == .active,
              !hasPresentedShellSurface,
              let pending = pendingShellPresentation else { return }
        pendingShellPresentation = nil
        presentWhenActive(pending)
    }

    private var hasPresentedShellSurface: Bool {
        isShowingImport || isShowingSigningMaterials || isShowingSigningQueue || isShowingOnboarding
    }

    private func isShowingSameSurface(as surface: ShellPresentation) -> Bool {
        switch surface {
        case .importHub:
            return isShowingImport
        case .profiles(_):
            return isShowingSigningMaterials && signingMaterialsSelection == .profiles
        case .certificates(_):
            return isShowingSigningMaterials && signingMaterialsSelection == .certificates
        }
    }

    /// Raises the sheet a held or immediate request names.
    private func present(_ surface: ShellPresentation) {
        switch surface {
        case .importHub:
            isShowingImport = true
        case .profiles(let url):
            signingMaterialsSelection = .profiles
            signingMaterialsImportURL = url
            isShowingSigningMaterials = true
        case .certificates(let url):
            signingMaterialsSelection = .certificates
            signingMaterialsImportURL = url
            isShowingSigningMaterials = true
        }
    }

    /// Accepts a URL the system opened ZynSign for.
    ///
    /// ZynSign declares itself a viewer for packages, archives, provisioning
    /// profiles, and identities, so this is reached for all of them.
    /// `SigningMaterialFileFormat` decides what the name claims: an identity
    /// or a profile keeps its own flow — the same one a drop of the same
    /// file takes — and packages and archives go to the hub. A URL that is
    /// not a file, or whose name is neither, is answered by the hub's
    /// preflight, which refuses it with the reason rather than dropping it
    /// in silence.
    ///
    /// A copy the system placed in ZynSign's own inbox came through the
    /// share sheet; anything else was opened in place.
    private func acceptIncoming(_ url: URL) {
        guard url.isFileURL else { return }
        switch SigningMaterialFileFormat.kind(for: url) {
        case .identity?:
            presentWhenActive(.certificates(url))
            ZHaptics.tap()
        case .profile?:
            presentWhenActive(.profiles(url))
            ZHaptics.tap()
        case nil:
            if IPAFileFormat.acceptsForImport(url) {
                let origin: ImportOrigin = Self.isShareSheetCopy(url) ? .shareSheet : .openIn
                environment.importHub.receive([url], origin: origin)
                presentImportHub()
            } else {
                // A handed-over file ZynSign has no dedicated route for still has
                // to be answered. The hub's preflight refuses it with the reason
                // and the sheet shows that refusal; dropping the file in silence
                // is what made Open In look broken for anything that was not a
                // package.
                environment.importHub.receive([url], origin: .openIn)
                presentImportHub()
            }
        }
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
            HomeView(onOpenSection: openHomeSection)
        case .library:
            ApplicationLibraryView(
                library: environment.library,
                hub: environment.importHub,
                bundleInspection: environment.bundleInspection,
                detailsInspection: environment.applicationDetailsInspection,
                signingHistory: environment.signingHistory,
                organizer: environment.libraryOrganizer,
                provenance: environment.applicationProvenance,
                exporter: environment.libraryExport,
                performanceEngine: environment.performanceEngine
            )
        case .features:
            FeatureCatalogView()
        case .certificates:
            SigningMaterialsView(initialSelection: .certificates)
        case .profiles:
            SigningMaterialsView(initialSelection: .profiles)
        case .settings:
            SettingsView()
        case .presets:
            PresetsView()
        case .downloads:
            DownloadsView()
        case .install:
            // Secondary sections are linked from Settings → Browse; they are
            // not tabs. Each carries its own NavigationStack where presented.
            EmptyView()
        case .files:
            // As a tab this view owns the navigation stack, so it embeds one.
            FilesView(embedsNavigationStack: true)
        case .appStore:
            AppStoreView(embedsNavigationStack: true)
        }
    }

    private func showNextDownloadNotice(from notices: [DownloadNotice]) {
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
        withAnimation(ZMotion.interactive) {
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
    // One environment for the shell and for the hierarchy it installs it in:
    // the shared composition-root fallback, never a second graph built here.
    RootView(environment: CompositionRoot.fallbackEnvironment)
        .environment(\.applicationEnvironment, CompositionRoot.fallbackEnvironment)
}
