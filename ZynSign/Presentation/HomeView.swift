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
struct HomeView: View {

    /// Switches the shell to another tab. `RootView` binds it to its selection.
    var onOpenSection: (ShellSection) -> Void = { _ in }

    @Environment(\.applicationEnvironment) private var environment
    @StateObject private var missionControl = MissionControlService()
    @State private var entries: [LibraryEntry] = []
    @State private var certificateCount: Int?
    @State private var profileCount: Int?
    @State private var failedLoad = false
    @State private var hasReadLibrary = false
    @State private var isShowingImporter = false
    @State private var importNotice: String?
    @State private var importInProgress = false
    @AppStorage("zynsign.onboarding.completed") private var onboardingCompleted = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ZSpacing.lg) {
                    welcomeHeader
                    quickActions
                    if onboardingNeeded {
                        onboardingCard
                    }
                    statisticsCard
                    if !entries.isEmpty {
                        recentlyImportedCard
                    }
                    if importInProgress {
                        HStack { ProgressView(); Text("Importing…").font(.footnote).foregroundStyle(.secondary) }
                            .frame(maxWidth: .infinity).padding().zynCardBackground()
                    }
                    if let notice = importNotice {
                        Text(notice).font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding().zynCardBackground()
                    }
                    if ReleaseTrain.isAvailable(.missionControl) {
                        missionControlCard
                    }
                }
                .padding()
            }
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isShowingImporter = true } label: {
                        Label("Import IPA", systemImage: "square.and.arrow.down")
                    }
                    .disabled(importInProgress)
                }
            }
            .fileImporter(
                isPresented: $isShowingImporter,
                allowedContentTypes: ImportablePackage.contentTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        handlePicker(.success(url))
                    }
                case .failure(let error):
                    handlePicker(.failure(error))
                }
            }
            .task { await reload() }
            .refreshable { await reload() }
            .navigationDestination(for: LibraryEntry.self) { entry in
                ApplicationDetailView(entry: entry, bundleInspection: environment.bundleInspection)
            }
        }
    }

    // MARK: - Welcome header

    private var welcomeHeader: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            Text(greeting)
                .font(.largeTitle.weight(.bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: ZSpacing.sm) {
                Image(systemName: "signature")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: ZRadius.sm, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text("ZynSign")
                        .font(.headline)
                    Text("Version \(environment.applicationInfo.marketingVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .accessibilityElement(children: .combine)
        }
        .padding()
        .zynHeaderBackground()
    }

    /// The time-of-day greeting. Apple-quality polish: a dashboard that
    /// knows what time it is, without pretending to know who the user is.
    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 0..<12: return "Good Morning"
        case 12..<18: return "Good Afternoon"
        default: return "Good Evening"
        }
    }

    // MARK: - Quick actions

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            Text("Quick Actions")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: ZSpacing.sm) {
                HomeActionButton(title: "Import IPA", icon: "square.and.arrow.down.fill", color: .blue) {
                    isShowingImporter = true
                }
                HomeActionButton(title: "Certificates", icon: "signature", color: .purple) {
                    onOpenSection(.certificates)
                }
                HomeActionButton(title: "Profiles", icon: "person.text.rectangle", color: .orange) {
                    onOpenSection(.profiles)
                }
            }
        }
    }

    // MARK: - Library statistics

    private var statisticsCard: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            HStack {
                Text("Library")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("View All") { onOpenSection(.library) }
                    .font(.footnote)
                    .disabled(failedLoad && entries.isEmpty)
            }
            if failedLoad {
                Label("The library could not be reached.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else {
                HStack(spacing: ZSpacing.sm) {
                    StatTile(
                        value: hasReadLibrary ? "\(entries.count)" : nil,
                        label: "Apps",
                        icon: "square.grid.2x2",
                        color: .blue
                    ) {
                        onOpenSection(.library)
                    }
                    StatTile(
                        value: certificateCount.map { "\($0)" },
                        label: "Certificates",
                        icon: "signature",
                        color: .purple
                    ) {
                        onOpenSection(.certificates)
                    }
                    StatTile(
                        value: profileCount.map { "\($0)" },
                        label: "Profiles",
                        icon: "person.text.rectangle",
                        color: .orange
                    ) {
                        onOpenSection(.profiles)
                    }
                }
            }
        }
        .padding()
        .zynCardBackground(cornerRadius: ZRadius.lg)
    }

    // MARK: - Recently imported

    private var recentlyImportedCard: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            HStack {
                Text("Recently Imported")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Open Library") { onOpenSection(.library) }
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
                    onboardingCompleted = true
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
                    action: { isShowingImporter = true }
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
                            refreshRepositories: { HomeStorageCounts.sourceCount() },
                            checkLibrary: {
                                if let entries = try? await environment.library.entries() { return entries.count }
                                return 0
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
        certificateCount = (try? environment.identityStore.listIdentities().count) ?? nil
        profileCount = try? await environment.provisioningProfiles?.count()
        if !entries.isEmpty && (certificateCount ?? 0) > 0 && (profileCount ?? 0) > 0 {
            onboardingCompleted = true
        }
    }

    // MARK: - Import

    private func handlePicker(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            importInProgress = true
            importNotice = nil
            Task {
                do {
                    let res = try await environment.packageImport.importArtifact(from: url)
                    if res.isAccepted {
                        importNotice = "Imported \(res.artifact.metadata?.identity.bundleIdentifier.rawValue ?? "package") — added to Library."
                    } else {
                        let code = res.artifact.validation?.errors.first?.code
                        importNotice = code.map { "Import rejected: \($0)" } ?? "This file is not a valid application package."
                    }
                } catch let e as ZynSignError {
                    importNotice = e.userMessage
                } catch is CancellationError {
                    importNotice = "Import cancelled."
                } catch {
                    importNotice = "The import could not be completed."
                }
                importInProgress = false
                await reload()
            }
        case .failure(let err):
            let ns = err as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return }
            importNotice = (err as? ZynSignError)?.userMessage ?? "The picker could not provide the selected file."
        }
    }
}

/// Counts Home shows without touching the library: signed IPAs written by
/// `SigningView` to `Documents/Signed`, and sources saved by the App Store tab
/// in `Documents/ZynSignSources.json`. A missing or unreadable file counts as 0.
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

    static func sourceCount() -> Int {
        guard let url = documents?.appendingPathComponent("ZynSignSources.json"),
              let data = try? Data(contentsOf: url),
              let sources = try? JSONDecoder().decode([[String: String]].self, from: data)
        else { return 0 }
        return sources.count
    }
}

// MARK: - Pieces

/// One quick action: an icon on a card. The whole tile is the button.
private struct HomeActionButton: View {
    let title: String; let icon: String; let color: Color; let action: () -> Void
    var body: some View {
        Button {
            ZHaptics.tap()
            action()
        } label: {
            VStack(spacing: ZSpacing.xs) {
                Image(systemName: icon).font(.title2).foregroundStyle(color)
                Text(title).font(.caption.weight(.medium)).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, ZSpacing.sm)
            .zynCardBackground()
        }.buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// One library statistic: the count, what it counts, and where the tab that
/// manages it lives. A count the dashboard could not read shows "—", never
/// a fabricated zero.
private struct StatTile: View {
    let value: String?
    let label: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button {
            ZHaptics.tap()
            action()
        } label: {
            VStack(spacing: 2) {
                if let value {
                    Text(value).font(.title3.weight(.bold)).monospacedDigit()
                } else {
                    Text("—").font(.title3.weight(.bold)).foregroundStyle(.tertiary)
                }
                Label(label, systemImage: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, ZSpacing.sm)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: ZRadius.sm))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value ?? "unavailable")")
    }
}

/// One recently imported application: icon, name, declared version, and how
/// long ago it arrived.
private struct RecentApplicationRow: View {
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
        .environment(\.applicationEnvironment, CompositionRoot.makeApplicationEnvironment())
}
