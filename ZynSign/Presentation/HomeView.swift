import SwiftUI

/// The Home area — the dashboard the user lands on.
///
/// Home answers, at a glance: what ZynSign holds (library statistics), what
/// arrived most recently (recently imported applications), and what the
/// user most likely wants to do next (quick actions). On a first launch it
/// is an onboarding surface: the empty-state card walks through importing
/// an application, adding a certificate, and importing a provisioning
/// profile, with each step reflecting the library's real state.
///
/// Nothing here is decorative data: every count is read from the same use
/// cases the tabs read, and the onboarding steps are complete only when the
/// library, certificate store, and profile library actually hold something.
///
/// Importing is not Home's business. Every import action here — the toolbar
/// button, the quick action, the first onboarding step, and files dropped
/// anywhere on the screen or onto the quick action — opens the shell's
/// Import Hub, where files are chosen and the queue, preview, conflicts, and
/// outcomes live. Home shows the hub's status while it has work, and reads
/// the results: when an import adds to the library, the dashboard's counts
/// and its recently imported list are read again, so what is on screen is
/// what the library holds.
struct HomeView: View {

    /// Switches the shell to another tab. `RootView` binds it to its selection.
    var onOpenSection: (ShellSection) -> Void = { _ in }

    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.importPresentation) private var importPresentation
    @StateObject private var missionControl = MissionControlService()
    @State private var entries: [LibraryEntry] = []
    @State private var certificateCount: Int?
    @State private var profileCount: Int?
    @State private var failedLoad = false
    @State private var hasReadLibrary = false
    @State private var settledImportCount = 0
    @State private var isShowingWalkthrough = false
    /// The direct-link field, and the state of the one transfer it can start.
    @State private var directLink = ""
    @State private var isSubmittingLink = false
    @State private var linkNotice: String?
    /// The application Quick Sign opens, when the user has one to open.
    @State private var quickSignEntry: LibraryEntry?
    /// Profiles and Sources each supply their own navigation stack, so they
    /// are presented rather than pushed onto Home's.
    @State private var isShowingProfiles = false
    @State private var isShowingSources = false
    /// Certificates own no navigation stack, so they push onto Home's.
    @State private var isShowingCertificates = false
    @AppStorage(LibraryPreferenceKeys.scope) private var libraryScope = LibraryScope.all.storageValue
    /// Whether first-launch onboarding has been completed.
    ///
    /// This lives in the preferences store rather than in `UserDefaults`, so
    /// that Settings → General can show it again and there is exactly one
    /// record of it. It is the one preference that records something the user
    /// did rather than something the user wants.
    @Environment(\.settingsCenter) private var settings

    private var onboardingCompleted: Bool {
        settings.preferences.general.onboardingCompleted
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ZSpacing.lg) {
                    wordmark
                    countsRow
                    ImportHubStatusBanner(hub: environment.importHub) {
                        importPresentation.present()
                    }
                    if let updates = pendingUpdates {
                        ZHomeAttentionRow(
                            symbol: "arrow.down.circle.fill",
                            title: updates.count == 1 ? "1 Update Available" : "\(updates.count) Updates Available",
                            subtitle: "From repositories you have apps from",
                            count: updates.count,
                            tint: ZHomeTint.attention
                        ) {
                            onOpenSection(.downloads)
                            Task { await environment.downloadCenter?.refreshUpdates() }
                        }
                    }
                    ZHomeImportTarget {
                        importPresentation.chooseFiles()
                    }
                    ZHomeDirectLinkField(
                        text: $directLink,
                        isSubmitting: isSubmittingLink
                    ) { link in
                        submitDirectLink(link)
                    }
                    actionRows
                    if onboardingNeeded {
                        onboardingCard
                    }
                    if showsFavorites {
                        favoritesCard
                    }
                    if !entries.isEmpty {
                        recentlyImportedCard
                    }
                    if ReleaseTrain.isAvailable(.missionControl) {
                        missionControlCard
                    }
                }
                .padding()
            }
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { isShowingWalkthrough = true } label: {
                        Label("Getting Started", systemImage: "questionmark.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importPresentation.present() } label: {
                        Label("Import IPA", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!importPresentation.isAvailable)
                }
            }
            .task { await reload() }
            .onReceive(environment.importHub.$items) { items in
                reloadWhenAnImportSettles(items)
            }
            .refreshable { await reload() }
            .navigationDestination(for: LibraryEntry.self) { entry in
                ApplicationDetailView(
                    entry: entry,
                    bundleInspection: environment.bundleInspection,
                    detailsInspection: environment.applicationDetailsInspection
                )
            }
            .navigationDestination(item: $quickSignEntry) { entry in
                SigningView(entry: entry)
            }
            .navigationDestination(isPresented: $isShowingCertificates) {
                CertificateManagerView(
                    store: environment.identityStore,
                    annotations: environment.identityAnnotations,
                    importer: environment.pkcs12Importer
                )
            }
            .sheet(isPresented: $isShowingProfiles) {
                ProfilesView(
                    profiles: environment.provisioningProfiles,
                    importer: environment.provisioningProfileImporter,
                    compatibility: environment.profileCompatibility,
                    selections: environment.profileSelections
                )
            }
            .sheet(isPresented: $isShowingSources) {
                if let store = environment.storeBrowser {
                    StoreSourcesView(model: store)
                }
            }
            .alert(
                "Download Center",
                isPresented: Binding(
                    get: { linkNotice != nil },
                    set: { if !$0 { linkNotice = nil } }
                ),
                presenting: linkNotice
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
            .sheet(isPresented: $isShowingWalkthrough) {
                ZOnboardingView(
                    isPresented: $isShowingWalkthrough,
                    onComplete: { completeOnboarding() }
                )
            }
        }
    }

    // MARK: - Command center

    /// The resolved theme this dashboard renders with.
    @Environment(\.appTheme) private var theme

    /// The wordmark. The one place the product names itself, so the screen
    /// below it can be read as a dashboard rather than as a page of a form.
    private var wordmark: some View {
        Group {
            if theme.minimalInterface {
                Text("ZynSign")
                    .font(.system(.largeTitle, design: .default).weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                    Text("ZynSign")
                        .font(.system(.largeTitle, design: .default).weight(.bold))
                        .foregroundStyle(.white)
                    Text("One Workspace. Complete Control.")
                        .font(ZynSignTokens.Typography.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ZSpacing.lg)
                .background(theme.heroGradient, in: RoundedRectangle(cornerRadius: ZynSignTokens.Radius.xl, style: .continuous))
            }
        }
        .accessibilityAddTraits(.isHeader)
    }

    /// What ZynSign holds, in three counts. Each opens the area it counts,
    /// so a count is also the shortest way to get there.
    private var countsRow: some View {
        HStack(spacing: ZSpacing.sm) {
            ZHomeStatTile(
                symbol: "folder.fill",
                title: "Repos",
                value: repositoryCount,
                tint: ZHomeTint.sources
            ) {
                onOpenSection(.appStore)
            }
            ZHomeStatTile(
                symbol: "checkmark.shield.fill",
                title: "Certs",
                value: certificateCount,
                tint: ZHomeTint.certificates
            ) {
                onOpenSection(.settings)
            }
            ZHomeStatTile(
                symbol: "square.stack.fill",
                title: "Apps",
                value: entries.isEmpty && hasReadLibrary ? 0 : entries.count,
                tint: ZHomeTint.apps
            ) {
                onOpenSection(.library)
            }
        }
    }

    /// How many repositories are configured, or `nil` while that has not
    /// been read — so the tile does not claim "0" before it knows.
    private var repositoryCount: Int? {
        guard let store = environment.storeBrowser else { return nil }
        return store.snapshot.sources.count
    }

    /// The updates the Download Center has ready, or `nil` when there are
    /// none. The row is absent rather than reassuring — an empty "0 updates
    /// available" is a claim about the repositories, not a state of the app.
    private var pendingUpdates: [AppUpdateCandidate]? {
        guard let center = environment.downloadCenter else { return nil }
        let updates = center.updates
        return updates.isEmpty ? nil : updates
    }

    /// The things a user comes here to do, in the order they are likely to
    /// want them. Import is deliberately absent: it is the target above, and
    /// repeating it here would be two doors to one room.
    private var actionRows: some View {
        VStack(spacing: ZSpacing.sm) {
            ZHomeActionRow(
                title: "Quick Sign",
                subtitle: quickSignSubtitle,
                symbol: "signature",
                tint: ZHomeTint.sources
            ) {
                openQuickSign()
            }
            ZHomeActionRow(
                title: "Certificates",
                subtitle: certificateSubtitle,
                symbol: "checkmark.shield.fill",
                tint: ZHomeTint.certificates
            ) {
                isShowingCertificates = true
            }
            ZHomeActionRow(
                title: "Add Repository",
                subtitle: "Add a new app source",
                symbol: "plus.circle.fill",
                tint: ZHomeTint.apps
            ) {
                isShowingSources = true
            }
            ZHomeActionRow(
                title: "Profiles",
                subtitle: "Provisioning profiles and compatibility",
                symbol: "person.text.rectangle.fill",
                tint: ZHomeTint.profiles
            ) {
                isShowingProfiles = true
            }
        }
    }

    /// Quick Sign needs an application to sign, so the row says what it
    /// will do rather than promising a one-tap signature it cannot perform.
    private var quickSignSubtitle: String {
        entries.isEmpty
            ? "Import an app first, then sign it here."
            : "Pick an app in the library and sign it with your identity."
    }

    private var certificateSubtitle: String {
        switch certificateCount {
        case .none: return "Manage your signing certificates"
        case .some(0): return "No certificates yet — import a .p12 to sign"
        case .some(let count): return count == 1 ? "1 certificate available" : "\(count) certificates available"
        }
    }

    /// Signs the most recently imported application when there is one, and
    /// otherwise sends the user to the library to pick. The sign screen
    /// always asks for a certificate and a profile, so "quick" never means
    /// "unattended".
    private func openQuickSign() {
        guard let entry = entries.first else {
            onOpenSection(.library)
            return
        }
        quickSignEntry = entry
    }

    /// Hands a direct link to the Download Center, which owns the transfer
    /// from that point. ZynSign does not fetch an `.ipa` from a URL on its
    /// own, and the message says which area took it so the result is findable.
    private func submitDirectLink(_ link: String) {
        guard let center = environment.downloadCenter else {
            linkNotice = "The Download Center is not available in this build."
            return
        }
        isSubmittingLink = true
        Task { @MainActor in
            let result = await center.enqueueUserLink(link)
            isSubmittingLink = false
            switch result {
            case .queued:
                directLink = ""
                linkNotice = "Queued in the Download Center. Open Downloads to follow it."
            case .needsDecision:
                // A collision with a package already held. The decision
                // belongs to the Download Center, which owns the prompt.
                onOpenSection(.downloads)
            case let .rejected(message):
                linkNotice = message
            case .skipped:
                break
            }
        }
    }
    // MARK: - Recently imported

    private var recentlyImportedCard: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            HStack {
                Text("Recently Imported")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Open Library") { openLibrary(on: .all) }
                    .font(.footnote)
            }
            VStack(spacing: 0) {
                ForEach(recentEntries, id: \.record.id) { entry in
                    NavigationLink(value: entry) {
                        RecentApplicationRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                    if entry.record.id != recentEntries.last?.record.id {
                        Divider()
                            .padding(.leading, 68)
                    }
                }
            }
        }
        .padding()
        .zynCardBackground(cornerRadius: ZRadius.lg)
    }

    // MARK: - Favorites

    /// Favourites are the user's own shortlist, so they sit above what
    /// merely arrived recently. The card appears once the library holds
    /// anything; before the first star it says how to make one.
    private var showsFavorites: Bool {
        ReleaseTrain.isAvailable(.libraryPowerFeatures) && !entries.isEmpty
    }

    private var favoritesCard: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            HStack {
                Text("Favorites")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !favoriteEntries.isEmpty {
                    Button("See All") { openLibrary(on: .smart(.favorites)) }
                        .font(.footnote)
                        .accessibilityLabel("See all favorites in the library")
                }
            }
            if favoriteEntries.isEmpty {
                HStack(spacing: ZSpacing.sm) {
                    Image(systemName: "star")
                        .font(.title3)
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No Favorites")
                            .font(.subheadline.weight(.semibold))
                        Text("Star your favorite apps to find them quickly.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: ZSpacing.sm) {
                        ForEach(favoriteEntries, id: \.record.id) { entry in
                            NavigationLink(value: entry) {
                                FavoriteApplicationTile(entry: entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding()
        .zynCardBackground(cornerRadius: ZRadius.lg)
    }

    /// Every favourite, by name — the same order the library's Name A–Z
    /// uses, so the two never disagree.
    private var favoriteEntries: [LibraryEntry] {
        entries
            .filter { $0.record.isFavorite }
            .sorted { LibraryIndex.nameOrder($0.record, $1.record) }
    }

    /// Opens the library tab on `scope`. The library remembers its scope,
    /// so Home sets it before switching tabs rather than reaching into the
    /// other tab's state.
    private func openLibrary(on scope: LibraryScope) {
        libraryScope = scope.storageValue
        onOpenSection(.library)
    }

    /// The most recent imports, newest first, at most three — a window into
    /// the library, never a second library.
    private var recentEntries: [LibraryEntry] {
        Array(entries.sorted { lhs, rhs in
            if lhs.record.importedAt != rhs.record.importedAt {
                return lhs.record.importedAt > rhs.record.importedAt
            }
            return lhs.record.id.rawValue < rhs.record.id.rawValue
        }.prefix(3))
    }

    // MARK: - First-launch onboarding

    /// Onboarding shows until the user completes or dismisses it. It is an
    /// empty-state surface: it never appears over a library that already
    /// holds applications unless the user left it up with steps missing.
    private var onboardingNeeded: Bool {
        guard !onboardingCompleted else { return false }
        return true
    }

    private var onboardingCard: some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to ZynSign")
                        .font(.title3.weight(.semibold))
                    Text("Three steps to your first signed application. Everything stays on this device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    completeOnboarding()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss onboarding")
            }
            VStack(alignment: .leading, spacing: ZSpacing.sm) {
                OnboardingStepRow(
                    number: 1,
                    title: "Import an application",
                    detail: "Pick an .ipa from Files. ZynSign inspects it and keeps it in your library.",
                    icon: "square.and.arrow.down.fill",
                    color: .blue,
                    isComplete: !entries.isEmpty,
                    action: { importPresentation.present() }
                )
                OnboardingStepRow(
                    number: 2,
                    title: "Add a certificate",
                    detail: "Import a .p12 signing identity. The private key never leaves the Keychain.",
                    icon: "signature",
                    color: .purple,
                    isComplete: (certificateCount ?? 0) > 0,
                    action: { onOpenSection(.certificates) }
                )
                OnboardingStepRow(
                    number: 3,
                    title: "Import a provisioning profile",
                    detail: "Add the .mobileprovision that authorizes your application's bundle identifier.",
                    icon: "person.text.rectangle",
                    color: .orange,
                    isComplete: (profileCount ?? 0) > 0,
                    action: { onOpenSection(.profiles) }
                )

                Button {
                    isShowingWalkthrough = true
                } label: {
                    Label("View 6-Step Walkthrough", systemImage: "sparkles")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
        }
        .padding()
        .zynCardBackground(cornerRadius: ZRadius.lg)
    }

    // MARK: - Mission Control (release-gated)

    private var missionControlCard: some View {
        ZCard(variant: .material, cornerRadius: ZRadius.lg) {
            VStack(alignment: .leading, spacing: ZSpacing.sm) {
                HStack {
                    Label("Mission Control", systemImage: "command").font(.headline)
                    Spacer()
                    if missionControl.isRunning { ProgressView() }
                }
                Text("One tap: refresh sources → check library → cache cleanup. Re-sign is policy-checked, never auto-triggered without your confirm.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let report = missionControl.lastReport {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: ZSpacing.xs) {
                            ZStatusBadge(report.repository.status, systemImage: "globe", kind: report.repository.status == "Completed" ? .success : .neutral)
                            ZStatusBadge("\(report.library.count) apps", systemImage: "square.grid.2x2", kind: .neutral)
                            ZStatusBadge("\(report.cacheCleanup.count) cleaned", systemImage: "trash", kind: .neutral)
                        }
                        Text("Last run \(report.durationMilliseconds) ms • \(report.repository.detail) • \(report.cacheCleanup.detail)")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.vertical, 4)
                }
                Button {
                    ZHaptics.tap()
                    Task {
                        _ = await missionControl.refreshEverything(
                            refreshRepositories: {
                                var count = 0
                                var refreshed = false
                                if let store = environment.storeBrowser {
                                    let refreshedCount = await store.refreshForMaintenance()
                                    if refreshedCount >= 0 {
                                        count += refreshedCount
                                        refreshed = true
                                    }
                                }
                                if let directory = environment.repositoryDirectory {
                                    await directory.refresh()
                                    count += directory.sources.count
                                    refreshed = true
                                }
                                return refreshed ? count : await HomeStorageCounts.sourceCount()
                            },
                            checkLibrary: {
                                do {
                                    let entries = try await environment.library.entries()
                                    return entries.count
                                } catch { return 0 }
                            },
                            cleanupCache: { missionControl.defaultCleanup() }
                        )
                        await reload()
                        ZHaptics.success()
                    }
                } label: {
                    HStack { Spacer(); Label(missionControl.isRunning ? "Refreshing…" : "Refresh Everything", systemImage: "arrow.triangle.2.circlepath"); Spacer() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(missionControl.isRunning)
            }
        }
    }

    // MARK: - Reading

    /// Re-reads everything the dashboard shows: the library entries, the
    /// certificate count, and the profile count. Each source fails
    /// independently — a certificate store that cannot be read never blanks
    /// the library section.
    private func reload() async {
        defer { hasReadLibrary = true }
        do {
            let loaded = try await environment.library.entries()
            entries = loaded
            failedLoad = false
        } catch {
            failedLoad = true
        }
        certificateCount = try? environment.identityStore.listIdentities().count
        profileCount = try? await environment.provisioningProfiles?.count()
        if !entries.isEmpty && (certificateCount ?? 0) > 0 && (profileCount ?? 0) > 0 {
            completeOnboarding()
        }
    }

    /// Records that the user has finished with first-launch onboarding.
    ///
    /// The record is a preference, so Settings → General can show the card
    /// again, and so there is exactly one place that says whether the user has
    /// seen it.
    private func completeOnboarding() {
        guard !onboardingCompleted else { return }
        settings.update { $0.general.onboardingCompleted = true }
    }

    // MARK: - Import

    /// Reads the dashboard again when the number of settled imports changes.
    ///
    /// Home does not act on an import — the import area owns that — it only
    /// notices that the library it describes may have changed. The count is
    /// kept in `@State` so a re-read happens once per settle, not on every
    /// progress report.
    private func reloadWhenAnImportSettles(_ items: [ImportHub.Item]) {
        let settled = items.filter { $0.settlement?.kind.isAccepted == true }.count
        guard settled != settledImportCount else { return }
        settledImportCount = settled
        Task { await reload() }
    }
}

/// Counts Home shows without touching the library: signed IPAs written by
/// `SigningView` to `Documents/Signed`. A missing or unreadable directory counts as 0.
enum HomeStorageCounts {
    private static var documents: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    static func signedCount() -> Int {
        guard let dir = documents?.appendingPathComponent("Signed", isDirectory: true),
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return 0 }
        return items.filter { $0.pathExtension.lowercased() == "ipa" }.count
    }

    static func sourceCount() async -> Int {
        guard let url = documents?.appendingPathComponent("ZynSignSources.json") else { return 0 }
        return await MainActor.run { RepositoryDirectory.sourceCount(at: url) }
    }
}

// MARK: - Pieces

/// One favourite application on Home: its icon and name. The whole tile
/// opens the application's details.
private struct FavoriteApplicationTile: View {
    let entry: LibraryEntry

    @ScaledMetric(relativeTo: .caption) private var tileWidth: CGFloat = 76

    var body: some View {
        let name = entry.record.displayName ?? "Unnamed Application"
        VStack(spacing: ZSpacing.xxs) {
            ApplicationIconView(
                artifactID: entry.record.artifact.artifactID,
                displayName: name,
                bundleIdentifier: entry.record.bundleIdentifier.rawValue,
                size: 56
            )
            Text(name)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(width: tileWidth)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityHint("Opens the application's details")
        .accessibilityAddTraits(.isButton)
    }
}

/// One recently imported application: icon, name, declared version, and how
/// long ago it arrived.
/// One recently imported application. Shared with the Smart Workspace.
struct RecentApplicationRow: View {
    let entry: LibraryEntry

    var body: some View {
        HStack(spacing: ZSpacing.sm) {
            ApplicationIconView(
                artifactID: entry.record.artifact.artifactID,
                displayName: entry.record.displayName ?? "Unnamed Application",
                bundleIdentifier: entry.record.bundleIdentifier.rawValue
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: ZSpacing.xxs) {
                    Text(entry.record.displayName ?? "Unnamed Application")
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if entry.record.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favorite")
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, ZSpacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.record.displayName ?? "Unnamed Application"), \(subtitle)")
    }

    private var subtitle: String {
        let record = entry.record
        var parts: [String] = []
        if let version = record.identity.shortVersionString {
            parts.append("Version \(version)")
        }
        parts.append(record.importedAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
}

/// One onboarding step: what to do, why, and whether the library says it is
/// already done. The state is never simulated — a step is complete only
/// when the corresponding library actually holds something.
private struct OnboardingStepRow: View {
    let number: Int
    let title: String
    let detail: String
    let icon: String
    let color: Color
    let isComplete: Bool
    let action: () -> Void

    var body: some View {
        Button {
            ZHaptics.tap()
            action()
        } label: {
            HStack(spacing: ZSpacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: ZRadius.sm, style: .continuous)
                        .fill(color.opacity(0.15))
                    Image(systemName: isComplete ? "checkmark.circle.fill" : icon)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(color)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if isComplete {
                    ZStatusBadge("Done", systemImage: "checkmark", kind: .success)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(detail). \(isComplete ? "Complete" : "Not done yet.")")
        .accessibilityAddTraits(.isButton)
    }
}

#Preview("Dashboard") {
    HomeView()
        .environment(\.applicationEnvironment, CompositionRoot.fallbackEnvironment)
}
