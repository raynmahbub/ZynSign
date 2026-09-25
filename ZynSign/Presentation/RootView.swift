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
    @State private var isShowingSigningQueue = false

    /// The signing-queue notice currently shown as a toast, if any.
    @State private var visibleQueueNotice: SigningQueueNotice?
    @State private var isShowingQueueToast = false

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
                    .badge(section == .library ? activeSigningJobBadge : 0)
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
        .task {
            // Restore the persisted queue once per launch. Restoration is
            // gated with the feature: a build that does not show the queue
            // never runs queued work behind the user's back.
            guard SigningQueueAvailability.isAvailable else { return }
            await environment.signingQueue.restore()
        }
    }

    /// The number of active signing jobs shown as the Library tab's badge,
    /// so work in flight stays visible wherever the user navigates.
    @State private var activeSigningJobBadge = 0

    // MARK: - Signing queue

    /// Opens the signing queue dashboard. When the import area is up, it
    /// is closed first and the dashboard follows once the sheet is gone —
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

    /// Shows the oldest pending queue notice: a toast (with its haptic)
    /// and a VoiceOver announcement. The notice is acknowledged as soon as it
    /// is on screen, so it is delivered exactly once however often the
    /// queue publishes.
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
