import SwiftUI

/// Settings Control Center — clean native inset-grouped layout inspired by
/// iOS Settings and Ksign, with isolated modal sheets for complex searchable
/// sub-surfaces so pushed navigation stacks never collide.
struct SettingsView: View {

    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.importPresentation) private var importPresentation
    @Environment(\.signingQueuePresentation) private var signingQueuePresentation
    @Environment(\.exportsPresentation) private var exportsPresentation
    @Environment(\.settingsCenter) private var settings

    @State private var searchText = ""
    @State private var sheetDestination: SettingsSheetDestination?

    /// Modal destinations that own their own `.searchable` or complex
    /// `.navigationDestination` graphs, presented inside a fresh
    /// `NavigationStack` sheet so they never collide with `SettingsView`'s
    /// root search controller.
    private enum SettingsSheetDestination: String, Identifiable {
        case certificates
        case profiles
        case features
        case files
        case presets
        case signingHistory
        case updates
        case savedApps
        case repositories
        case downloads
        case releaseFeeds
        case firmware

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                if trimmedQuery.isEmpty {
                    headerSection
                    quickToolsSection
                }

                ForEach(groupedCategories, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.categories) { category in
                            categoryRow(for: category)
                        }
                    }
                }

                if groupedCategories.isEmpty {
                    Section {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(ShellSection.settings.title)
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Search Settings"
            )
            .sheet(item: $sheetDestination) { destination in
                NavigationStack {
                    modalScreen(for: destination)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { sheetDestination = nil }
                            }
                        }
                }
            }
        }
    }

    // MARK: - Header & Quick Tools

    private var headerSection: some View {
        Section {
            HStack(spacing: ZSpacing.md) {
                ZynSignMark(size: ZSpacing.xxxl)
                VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                    HStack(spacing: ZSpacing.xs) {
                        Text("ZynSign")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        ZStatusBadge(
                            ReleaseTrain.current.tag,
                            systemImage: "sparkles",
                            kind: .info
                        )
                    }
                    Text("On-device IPA signing, Free & Paid certificates, Tweaks, and WebDAV workspace.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, ZSpacing.xxs)

            if importPresentation.isAvailable {
                Button {
                    importPresentation.chooseFiles()
                } label: {
                    HStack(spacing: ZSpacing.sm) {
                        ZSettingsLabel(
                            title: "Import IPA / Package",
                            subtitle: "Select .ipa, .tipa, or .zip from Files",
                            symbol: "plus.app.fill",
                            tint: .blue
                        )
                        Spacer(minLength: ZSpacing.xs)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var quickToolsSection: some View {
        Section("Quick Access") {
            sheetRow(
                destination: .certificates,
                title: "Certificates",
                subtitle: "Import .p12 / .zcert identities and check validity",
                symbol: "key.fill",
                tint: .orange
            )
            sheetRow(
                destination: .profiles,
                title: "Provisioning Profiles",
                subtitle: "Import .mobileprovision files and inspect entitlements",
                symbol: "doc.badge.gearshape.fill",
                tint: .green
            )
            NavigationLink {
                UnifiedSigningHubView()
            } label: {
                ZSettingsLabel(
                    title: "Apple ID & Guest Container",
                    subtitle: "Free 7-day Apple ID provisioning, Paid certs, and zero-slot container",
                    symbol: "person.badge.key.fill",
                    tint: .indigo
                )
            }
            if let tweaks = environment.tweakLibrary {
                NavigationLink {
                    TweakLibraryView(service: tweaks)
                } label: {
                    ZSettingsLabel(
                        title: "Tweaks & Dylibs",
                        subtitle: "Manage .deb and .dylib payloads for injection",
                        symbol: "puzzlepiece.extension.fill",
                        tint: .purple
                    )
                }
            }
            if let lanServer = environment.lanWebWorkspace {
                NavigationLink {
                    LANWebWorkspaceView(service: lanServer)
                } label: {
                    ZSettingsLabel(
                        title: "Wi-Fi & WebDAV Server",
                        subtitle: "Upload packages from any browser or Finder",
                        symbol: "wifi",
                        tint: .cyan
                    )
                }
            }
            sheetRow(
                destination: .files,
                title: "Files Browser",
                subtitle: "Inspect ZynSign's local folders, archives, and plists",
                symbol: "folder.fill",
                tint: .teal
            )
        }
    }

    // MARK: - Grouped Categories

    private struct CategoryGroup {
        let title: String
        let categories: [SettingsCategory]
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var groupedCategories: [CategoryGroup] {
        let rawGroups: [(String, [SettingsCategory])] = [
            ("Signing & Sideloading", [.signing, .devices, .security]),
            ("Repositories, Files & Network", [.updates, .servers, .miscellaneous]),
            ("Appearance & Preferences", [.general, .reset]),
            ("Capabilities, Diagnostics & About", [.features, .diagnostics, .about, .socials])
        ]
        let query = trimmedQuery
        return rawGroups.compactMap { title, items in
            let matching = query.isEmpty
                ? items
                : items.filter { matches($0, query: query) }
            guard !matching.isEmpty else { return nil }
            return CategoryGroup(title: title, categories: matching)
        }
    }

    private func matches(_ category: SettingsCategory, query: String) -> Bool {
        if category.title.localizedStandardContains(query)
            || category.summary.localizedStandardContains(query) {
            return true
        }
        return category.searchKeywords.contains { $0.localizedStandardContains(query) }
    }

    @ViewBuilder
    private func categoryRow(for category: SettingsCategory) -> some View {
        if category == .features {
            sheetRow(
                destination: .features,
                title: category.title,
                subtitle: category.summary,
                symbol: category.symbol,
                tint: category.tint
            )
        } else {
            NavigationLink {
                destination(for: category)
            } label: {
                ZSettingsLabel(
                    title: category.title,
                    subtitle: category.summary,
                    symbol: category.symbol,
                    tint: category.tint
                )
            }
        }
    }

    private func sheetRow(
        destination: SettingsSheetDestination,
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color
    ) -> some View {
        Button {
            sheetDestination = destination
        } label: {
            HStack(spacing: ZSpacing.xs) {
                ZSettingsLabel(
                    title: title,
                    subtitle: subtitle,
                    symbol: symbol,
                    tint: tint
                )
                Spacer(minLength: ZSpacing.xs)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func modalScreen(for destination: SettingsSheetDestination) -> some View {
        switch destination {
        case .certificates:
            SigningMaterialsView(
                initialSelection: .certificates,
                embedsNavigationStack: false
            )
        case .profiles:
            SigningMaterialsView(
                initialSelection: .profiles,
                embedsNavigationStack: false
            )
        case .features:
            FeatureCatalogView(embedsNavigationStack: false)
        case .files:
            FilesView(embedsNavigationStack: false)
        case .presets:
            PresetsView(embedsNavigationStack: false)
        case .signingHistory:
            if let history = environment.signingHistory {
                SigningHistoryView(history: history, embedsNavigationStack: false)
            } else {
                ContentUnavailableView(
                    "History Unavailable",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Signing history is not configured in this build.")
                )
            }
        case .updates:
            if let store = environment.storeBrowser {
                StoreUpdatesView(model: store)
            } else {
                ContentUnavailableView(
                    "Repositories Unavailable",
                    systemImage: "globe",
                    description: Text("Repository services are not configured in this build.")
                )
            }
        case .savedApps:
            if let store = environment.storeBrowser {
                StoreSavedAppsView(model: store)
            } else {
                ContentUnavailableView(
                    "Repositories Unavailable",
                    systemImage: "bookmark",
                    description: Text("Repository services are not configured in this build.")
                )
            }
        case .repositories:
            if let store = environment.storeBrowser {
                StoreSourcesView(model: store)
            } else {
                ContentUnavailableView(
                    "Repositories Unavailable",
                    systemImage: "globe",
                    description: Text("Repository services are not configured in this build.")
                )
            }
        case .downloads:
            DownloadsView(embedsNavigationStack: false)
        case .releaseFeeds:
            if let feeds = environment.releaseFeeds {
                ReleaseFeedsView(provider: feeds, library: environment.library)
            } else {
                ContentUnavailableView(
                    "Release Feeds Unavailable",
                    systemImage: "shippingbox",
                    description: Text("Release feeds are not configured in this build.")
                )
            }
        case .firmware:
            IPSWBrowserView(embedsNavigationStack: false)
        }
    }

    // MARK: - Category Destinations

    @ViewBuilder
    private func destination(for category: SettingsCategory) -> some View {
        switch category {
        case .signing:
            signingCategory
        case .updates:
            updatesCategory
        case .features:
            FeatureCatalogView(embedsNavigationStack: false)
        case .general:
            generalCategory
        case .security:
            SecurityCenterSection()
        case .devices:
            devicesCategory
        case .servers:
            serversCategory
        case .miscellaneous:
            miscellaneousCategory
        case .diagnostics:
            diagnosticsCategory
        case .reset:
            RecoverySettingsSection()
        case .about:
            AboutSettingsSection()
        case .socials:
            socialsCategory
        }
    }

    private var signingCategory: some View {
        List {
            Section("Signing Materials & Defaults") {
                sheetRow(
                    destination: .certificates,
                    title: "Certificates",
                    subtitle: "Import and inspect PKCS#12 (.p12 / .pfx) and .zcert signing identities.",
                    symbol: "key.fill",
                    tint: .orange
                )
                sheetRow(
                    destination: .profiles,
                    title: "Provisioning Profiles",
                    subtitle: "Import and verify .mobileprovision files against bundles and identities.",
                    symbol: "doc.badge.gearshape.fill",
                    tint: .green
                )
                NavigationLink {
                    SigningPreferencesSection()
                } label: {
                    ZSettingsLabel(
                        title: "Signing Defaults",
                        subtitle: "Default certificate, profile, verification, and post-sign options.",
                        symbol: "checkmark.seal.fill",
                        tint: .blue
                    )
                }
                NavigationLink {
                    SigningOptionsView()
                } label: {
                    ZSettingsLabel(
                        title: "Signing Options",
                        subtitle: "Review supported pipeline behavior and entitlement encoding.",
                        symbol: "slider.horizontal.3",
                        tint: .indigo
                    )
                }
            }

            Section("Workflows & Tools") {
                if let tweaks = environment.tweakLibrary {
                    NavigationLink {
                        TweakLibraryView(service: tweaks)
                    } label: {
                        ZSettingsLabel(
                            title: "Tweak Library",
                            subtitle: "Import and organize .deb and .dylib payloads for signing sessions.",
                            symbol: "puzzlepiece.extension.fill",
                            tint: .purple
                        )
                    }
                }
                if let revocation = environment.revocationService {
                    NavigationLink {
                        RevocationCenterView(service: revocation, identityStore: environment.identityStore)
                    } label: {
                        ZSettingsLabel(
                            title: "Revocation Center",
                            subtitle: "Check how reachable a certificate's revocation channels are.",
                            symbol: "shield.checkered",
                            tint: .teal
                        )
                    }
                }
                if signingQueuePresentation.isAvailable {
                    Button {
                        signingQueuePresentation.present()
                    } label: {
                        HStack(spacing: ZSpacing.xs) {
                            ZSettingsLabel(
                                title: "Signing Queue",
                                subtitle: "Review and manage queued signing jobs.",
                                symbol: "tray.full.fill",
                                tint: .blue
                            )
                            Spacer(minLength: ZSpacing.xs)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if environment.signingHistory != nil {
                    sheetRow(
                        destination: .signingHistory,
                        title: "Signing History",
                        subtitle: "Every signing run the journal holds — including failed runs.",
                        symbol: "clock.arrow.circlepath",
                        tint: .cyan
                    )
                }
                if ReleaseTrain.isAvailable(.signingPresets) {
                    sheetRow(
                        destination: .presets,
                        title: "Signing Presets",
                        subtitle: "Manage reusable signing configurations.",
                        symbol: "rectangle.stack.fill",
                        tint: .mint
                    )
                }
            }

            if ReleaseTrain.isAvailable(.identityCenter), let identityCenter = environment.identityCenter {
                Section("Teams") {
                    NavigationLink {
                        IdentityCenterView(service: identityCenter)
                    } label: {
                        ZSettingsLabel(
                            title: "Developer Identity Center",
                            subtitle: "Teams, identity health, conflicts, and expiration.",
                            symbol: "person.badge.key.fill",
                            tint: .indigo
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Signing")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var updatesCategory: some View {
        List {
            Section {
                Text("Updates are reviewed before download. ZynSign does not silently switch repositories, import packages, sign them, or install them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if environment.storeBrowser != nil {
                Section("Repositories & Updates") {
                    sheetRow(
                        destination: .updates,
                        title: "Updates",
                        subtitle: "Compare repository releases with your library.",
                        symbol: "arrow.triangle.2.circlepath",
                        tint: .blue
                    )
                    sheetRow(
                        destination: .savedApps,
                        title: "Saved Apps",
                        subtitle: "Review apps saved for later; saving never downloads.",
                        symbol: "bookmark.fill",
                        tint: .orange
                    )
                    sheetRow(
                        destination: .repositories,
                        title: "Repositories",
                        subtitle: "Add, validate, refresh, and remove source URLs.",
                        symbol: "globe",
                        tint: .teal
                    )
                    sheetRow(
                        destination: .downloads,
                        title: "Downloads",
                        subtitle: "Manage transfer jobs and review downloaded packages.",
                        symbol: "arrow.down.circle.fill",
                        tint: .indigo
                    )
                    if environment.releaseFeeds != nil {
                        sheetRow(
                            destination: .releaseFeeds,
                            title: "Release Feeds",
                            subtitle: "Follow repository releases and track app updates.",
                            symbol: "shippingbox.fill",
                            tint: .purple
                        )
                    }
                }
            } else {
                Section {
                    ContentUnavailableView(
                        "Updates Unavailable",
                        systemImage: "arrow.triangle.2.circlepath",
                        description: Text("Repository and download services are not configured in this build.")
                    )
                }
            }
            Section("Apple Firmware") {
                sheetRow(
                    destination: .firmware,
                    title: "IPSW Browser",
                    subtitle: "Browse device firmware and current signing status.",
                    symbol: "iphone.gen3",
                    tint: .cyan
                )
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Updates")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var generalCategory: some View {
        List {
            Section("App Preferences") {
                NavigationLink {
                    GeneralSettingsSection()
                } label: {
                    ZSettingsLabel(
                        title: "General",
                        subtitle: "Landing tab, feedback, motion, and onboarding.",
                        symbol: "gearshape.fill",
                        tint: .gray
                    )
                }
                NavigationLink {
                    AppearanceSettingsSection()
                } label: {
                    ZSettingsLabel(
                        title: "Appearance",
                        subtitle: "Color scheme, contrast, density, and theme.",
                        symbol: "paintbrush.fill",
                        tint: .purple
                    )
                }
                NavigationLink {
                    StorageManagerSection()
                } label: {
                    ZSettingsLabel(
                        title: "Storage",
                        subtitle: "Review app storage and manage local data.",
                        symbol: "externaldrive.fill",
                        tint: .blue
                    )
                }
                NavigationLink {
                    PortableWorkspaceSettingsView()
                } label: {
                    ZSettingsLabel(
                        title: "Portable Workspace",
                        subtitle: "Mirror catalogs and packages to Documents/ZynSignPortable.",
                        symbol: "folder.badge.gearshape",
                        tint: .teal
                    )
                }
                if exportsPresentation.isAvailable {
                    Button {
                        exportsPresentation.present()
                    } label: {
                        HStack(spacing: ZSpacing.xs) {
                            ZSettingsLabel(
                                title: "Export Center",
                                subtitle: "Every signed artifact ZynSign holds — verify, share, or reveal.",
                                symbol: "shippingbox.fill",
                                tint: .orange
                            )
                            Spacer(minLength: ZSpacing.xs)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Notifications") {
                Label(
                    "In-app notices are used for import, download, and signing results.",
                    systemImage: "bell.badge"
                )
                Text("Transfer and update decisions remain under your explicit control.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var devicesCategory: some View {
        List {
            Section {
                Text("ZynSign inspects and prepares packages on this device. It does not pair with Apple TV, Watch, Mac, or Vision Pro, and it does not enable JIT.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Sideloading") {
                NavigationLink {
                    UnifiedSigningHubView()
                } label: {
                    ZSettingsLabel(
                        title: "Unified Signing & Container Hub",
                        subtitle: "Free 7-day & Paid 365-day Apple ID provisioning, zero-slot Host Container, and loopback bridge.",
                        symbol: "cpu.fill",
                        tint: .indigo
                    )
                }
                NavigationLink {
                    SideloadStudioView()
                } label: {
                    ZSettingsLabel(
                        title: "Sideload Studio",
                        subtitle: "Track 7-day refresh countdowns, account slot usage, and re-signing.",
                        symbol: "hourglass.badge.plus",
                        tint: .orange
                    )
                }
                NavigationLink {
                    SideloadingView(embedsNavigationStack: false)
                } label: {
                    ZSettingsLabel(
                        title: "Delivery Report",
                        subtitle: "Device pairing, installation, guest containers, and package edits.",
                        symbol: "arrow.down.app.fill",
                        tint: .blue
                    )
                }
            }
            if ReleaseTrain.isAvailable(.installationWorkspace) {
                Section("Device Handoff") {
                    NavigationLink {
                        InstallationWorkspaceView(
                            workspace: environment.installationWorkspace,
                            storage: environment.storageManagement,
                            embedsNavigationStack: false
                        )
                    } label: {
                        ZSettingsLabel(
                            title: "Installation Workspace",
                            subtitle: "Review delivery readiness and handoff history.",
                            symbol: "arrow.down.app",
                            tint: .teal
                        )
                    }
                }
            }
            if ReleaseTrain.isAvailable(.smartSign) {
                Section("Capability") {
                    NavigationLink {
                        InstallationSettingsView()
                    } label: {
                        ZSettingsLabel(
                            title: "Installation Capability",
                            subtitle: "Platform limits and supported handoff behavior.",
                            symbol: "checkmark.shield.fill",
                            tint: .green
                        )
                    }
                }
            }
            Section("Unsupported Capabilities") {
                NavigationLink {
                    PairingHonestView()
                } label: {
                    ZSettingsLabel(
                        title: "Pairing / JIT / Mux",
                        subtitle: "Supported boundaries and feasibility notes.",
                        symbol: "cable.connector",
                        tint: .red
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var serversCategory: some View {
        List {
            Section("Repository Connections") {
                if environment.storeBrowser != nil {
                    sheetRow(
                        destination: .repositories,
                        title: "Repository Sources",
                        subtitle: "Manage HTTPS catalogs used for discovery and downloads.",
                        symbol: "globe",
                        tint: .teal
                    )
                }
                Text("Repository feeds are read when you choose to add or refresh them. Adding a source does not establish trust.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("File Transfer") {
                if let localTransfer = environment.localTransfer {
                    NavigationLink {
                        LocalTransferView(service: localTransfer, embedsNavigationStack: false)
                    } label: {
                        ZSettingsLabel(
                            title: "Local Transfer",
                            subtitle: "Receive a file from another machine on this network with a session token.",
                            symbol: "wifi.router.fill",
                            tint: .blue
                        )
                    }
                } else {
                    Text("Local transfer is not composed in this build.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let lanServer = environment.lanWebWorkspace {
                    NavigationLink {
                        LANWebWorkspaceView(service: lanServer)
                    } label: {
                        ZSettingsLabel(
                            title: "Wi-Fi & WebDAV Server",
                            subtitle: "Foreground browser upload dashboard and Finder / Explorer WebDAV mount.",
                            symbol: "externaldrive.connected.to.line.below.fill",
                            tint: .cyan
                        )
                    }
                }
            }
            Section("On-Device Boundary") {
                Label("Remote signing is not implemented. Signing stays on this device.", systemImage: "signature")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Servers")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var miscellaneousCategory: some View {
        List {
            Section("Files & Archives") {
                sheetRow(
                    destination: .files,
                    title: "Files",
                    subtitle: "Browse ZynSign's local files and exports.",
                    symbol: "folder.fill",
                    tint: .teal
                )
                NavigationLink {
                    ArchiveSettingsView()
                } label: {
                    ZSettingsLabel(
                        title: "Archive & Extraction",
                        subtitle: "Review supported formats and safe extraction limits.",
                        symbol: "doc.zipper",
                        tint: .orange
                    )
                }
                NavigationLink {
                    AdvancedSettingsSection()
                } label: {
                    ZSettingsLabel(
                        title: "Advanced",
                        subtitle: "Working directory, cleanup policy, and verification strictness.",
                        symbol: "slider.horizontal.3",
                        tint: .indigo
                    )
                }
                if importPresentation.isAvailable {
                    Button {
                        importPresentation.chooseFiles()
                    } label: {
                        HStack(spacing: ZSpacing.xs) {
                            ZSettingsLabel(
                                title: "Import Files",
                                subtitle: "Choose an IPA, TIPA, or supported archive.",
                                symbol: "square.and.arrow.down.fill",
                                tint: .blue
                            )
                            Spacer(minLength: ZSpacing.xs)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Recovery") {
                NavigationLink {
                    RecoveryCenterView()
                } label: {
                    ZSettingsLabel(
                        title: "Backup & Restore",
                        subtitle: "Create an encrypted backup or selectively restore data.",
                        symbol: "lock.shield.fill",
                        tint: .green
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Miscellaneous")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var diagnosticsCategory: some View {
        List {
            Section("Troubleshooting") {
                NavigationLink {
                    DiagnosticsPreferencesSection()
                } label: {
                    ZSettingsLabel(
                        title: "Diagnostics",
                        subtitle: "Control local logs and prepare diagnostic reports.",
                        symbol: "stethoscope",
                        tint: .red
                    )
                }
                NavigationLink {
                    AnalyticsHonestView()
                } label: {
                    ZSettingsLabel(
                        title: "Analytics & Activity",
                        subtitle: "Review what stays on-device and what is never sent.",
                        symbol: "chart.bar.doc.horizontal.fill",
                        tint: .blue
                    )
                }
                ReleaseReadinessLink()
            }
            if CompatibilityLabAvailability.isCompiledIn {
                Section("Validation") {
                    NavigationLink {
                        CompatibilityLabSection()
                    } label: {
                        ZSettingsLabel(
                            title: "Compatibility Lab",
                            subtitle: "Run release and compatibility checks.",
                            symbol: "checkmark.shield.fill",
                            tint: .green
                        )
                    }
                }
            }
            if ReleaseTrain.isAvailable(.performanceDashboard), let engine = environment.performanceEngine {
                Section("Performance") {
                    NavigationLink {
                        PerformanceDashboardSection(
                            model: PerformanceDashboardModel(
                                engine: engine,
                                benchmarkSuite: { CompositionRoot.makePerformanceBenchmarks(environment: environment) }
                            )
                        )
                    } label: {
                        ZSettingsLabel(
                            title: "Performance",
                            subtitle: "Inspect caches, memory, indexes, and benchmarks.",
                            symbol: "speedometer",
                            tint: .orange
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var socialsCategory: some View {
        List {
            Section("ZynSign Community") {
                if let repositoryURL = URL(string: "https://github.com/raynmahbub/ZynSign") {
                    Link(destination: repositoryURL) {
                        ZSettingsLabel(
                            title: "GitHub Repository",
                            subtitle: "Source code, releases, and project discussions.",
                            symbol: "chevron.left.forwardslash.chevron.right",
                            tint: .primary
                        )
                    }
                }
                if let issueURL = URL(string: "https://github.com/raynmahbub/ZynSign/issues/new/choose") {
                    Link(destination: issueURL) {
                        ZSettingsLabel(
                            title: "Report an Issue",
                            subtitle: "Send a bug report or feature request on GitHub.",
                            symbol: "ladybug.fill",
                            tint: .red
                        )
                    }
                }
            }
            Section {
                Text("GitHub opens in your browser. Never include signing keys, passwords, provisioning secrets, or private app files in an issue.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Socials")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One category of the Settings index, pinned by `SettingsSectionCatalogTests`.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case signing, updates, features, general, security, devices, servers, miscellaneous, diagnostics, reset, about, socials

    var id: String { rawValue }

    var title: String {
        switch self {
        case .signing: return "Signing"
        case .updates: return "Updates"
        case .features: return "Features"
        case .general: return "General"
        case .security: return "Security"
        case .devices: return "Devices"
        case .servers: return "Servers"
        case .miscellaneous: return "Miscellaneous"
        case .diagnostics: return "Diagnostics"
        case .reset: return "Reset"
        case .about: return "About"
        case .socials: return "Socials"
        }
    }

    var summary: String {
        switch self {
        case .signing: return "Certificates, profiles, signing defaults, and tools"
        case .updates: return "Repositories, app updates, downloads, and Apple firmware"
        case .features: return "Browse available, staged, and unsupported capabilities"
        case .general: return "Appearance, tabs, app behavior, and storage"
        case .security: return "Face ID lock, sensitive actions, and what stays masked"
        case .devices: return "Sideloading, Apple ID hub, container, and delivery status"
        case .servers: return "Repositories, Wi-Fi upload, and WebDAV server"
        case .miscellaneous: return "Files, archives, imports, and backups"
        case .diagnostics: return "Logs, health checks, and troubleshooting"
        case .reset: return "Restore preferences or recover app data"
        case .about: return "Version, documents, and acknowledgements"
        case .socials: return "Find the project or report a problem"
        }
    }

    var symbol: String {
        switch self {
        case .signing: return "signature"
        case .updates: return "arrow.triangle.2.circlepath"
        case .features: return "square.grid.3x3.fill"
        case .general: return "gearshape.fill"
        case .security: return "faceid"
        case .devices: return "iphone.gen3"
        case .servers: return "server.rack"
        case .miscellaneous: return "square.grid.2x2.fill"
        case .diagnostics: return "stethoscope"
        case .reset: return "arrow.counterclockwise"
        case .about: return "info.circle.fill"
        case .socials: return "bubble.left.and.bubble.right.fill"
        }
    }

    var tint: Color {
        switch self {
        case .signing: return .blue
        case .updates: return .indigo
        case .features: return .purple
        case .general: return .gray
        case .security: return .green
        case .devices: return .cyan
        case .servers: return .teal
        case .miscellaneous: return .orange
        case .diagnostics: return .red
        case .reset: return .pink
        case .about: return .blue
        case .socials: return .mint
        }
    }

    var searchKeywords: [String] {
        switch self {
        case .signing:
            return ["certificate", "p12", "zcert", "profile", "mobileprovision", "tweak", "dylib", "deb", "preset", "revocation", "queue"]
        case .updates:
            return ["repo", "source", "download", "ipsw", "firmware", "saved"]
        case .features:
            return ["catalog", "capabilities", "release", "train"]
        case .general:
            return ["theme", "dark", "light", "glass", "storage", "portable", "export"]
        case .security:
            return ["biometric", "passcode", "lock", "mask", "timeout"]
        case .devices:
            return ["apple id", "free", "container", "sideload", "refresh", "pairing", "bridge", "udid"]
        case .servers:
            return ["webdav", "wifi", "lan", "transfer", "http"]
        case .miscellaneous:
            return ["files", "archive", "zip", "ipa", "backup", "restore"]
        case .diagnostics:
            return ["logs", "lab", "analytics", "performance", "health"]
        case .reset:
            return ["default", "wipe", "clear", "recover"]
        case .about:
            return ["version", "license", "credits", "changelog"]
        case .socials:
            return ["github", "issue", "bug", "community"]
        }
    }
}

extension SettingsCategory {

    /// Pinned by `SettingsSectionCatalogTests`.
    var openedSections: [SettingsSectionIdentifier] {
        switch self {
        case .signing: return [.signing]
        case .general: return [.general, .appearance, .storage]
        case .security: return [.security]
        case .miscellaneous: return [.advanced]
        case .diagnostics: return [.diagnostics, .compatibilityLab]
        case .reset: return [.recovery]
        case .about: return [.about]
        case .updates, .features, .devices, .servers, .socials: return []
        }
    }
}

// MARK: - Sub-screens

struct SigningOptionsView: View {
    private let emitDEREntitlements: Binding<Bool>?

    init(emitDEREntitlements: Binding<Bool>? = nil) {
        self.emitDEREntitlements = emitDEREntitlements
    }

    var body: some View {
        Form {
            Section("Entitlement encoding") {
                if let emitDEREntitlements {
                    Toggle("Request DER entitlements (unsupported)", isOn: emitDEREntitlements)
                    Text("This build embeds XML only. Requesting DER will be diagnosed as unsupported and block signing; the signer does not yet write slot 7. For an iOS 15+ target requiring DER, use a signer with verified DER support.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("This build embeds XML entitlements only. DER output is not supported. Open an app in the Library to review its local signing diagnostics.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Supported today") {
                Text("The current pipeline signs supported Mach-O layouts and applies optional tweak/Info.plist/entitlement transforms when configured in the signing session.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Signing Options")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ArchiveSettingsView: View {
    var body: some View {
        List {
            Section("Policy") {
                LabeledContent("Max entries", value: "100,000")
                LabeledContent("Max path depth", value: "32")
                LabeledContent("Max inspection read", value: "4 MiB")
                LabeledContent("Max extraction read", value: "512 MiB")
            }
            Section {
                Text("Limits are architectural — enforced before any work is done. A package beyond them is refused with a typed error rather than expanded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Archive & Extraction")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct InstallationSettingsView: View {
    private var assessment: InstallationAssessment {
        InstallationCapabilityAssessment.assess(
            InstallationEvidence(
                profileStatus: .indeterminate,
                deviceAuthorized: nil,
                platformSupported: nil
            )
        )
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: ZSpacing.xs) {
                    ZStatusBadge("Unavailable", systemImage: "xmark.shield", kind: .error)
                    ZStatusBadge(assessment.limitations.first?.rawValue ?? "—", systemImage: "exclamationmark.triangle", kind: .warning)
                }
                Label(assessment.summary, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
                ForEach(assessment.limitations, id: \.self) { lim in
                    Label(lim.message, systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowInsets(EdgeInsets(top: ZSpacing.xxs, leading: ZSpacing.xxl, bottom: ZSpacing.xxs, trailing: ZSpacing.md))
                }
            } header: {
                Text("Installation — Honest Unavailable")
            } footer: {
                Text("`InstallationCapabilityAssessment.deliveryMechanismAvailable == false` on every path. See docs/architecture/installation-compatibility.md.")
            }

            if ReleaseTrain.isAvailable(.deliveryHandoff) {
                Section("Delivery hand-off") {
                    ZStatusBadge("Hand-off wired", systemImage: "tray.and.arrow.up", kind: .info)
                    Text("After a successful sign, Deliver… on the signing screen builds an OTA manifest (itms-services), a ready-to-paste install link, and a QR code.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("What ZynSign does today") {
                Text("Validates artifact, signature, and provisioning separately and writes signed output to Documents/Signed/*_signed.ipa.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                LabeledContent("Supported", value: assessment.supported ? "Yes" : "No")
                    .foregroundStyle(assessment.supported ? .green : .orange)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Installation")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PairingHonestView: View {
    private var assessments: [PairingAssessment] { PairingCapabilityAssessment.allUnavailable }

    var body: some View {
        List {
            Section {
                HStack(spacing: ZSpacing.xs) {
                    ZStatusBadge("Never", systemImage: "xmark.octagon", kind: .error)
                    ZStatusBadge("4 capabilities", systemImage: "cable.connector", kind: .neutral)
                }
                Text("Private-API Pairing / JIT / Mux / OpenSSL linkage are not linked into the app binary. Keeps the binary reviewable and avoids private-API risk.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Pairing / JIT / Mux — Never")
            } footer: {
                Text("See docs/architecture/pairing-jit-mux-feasibility.md and docs/product/WHAT_DOES_NOT_EXIST.md.")
            }

            ForEach(assessments, id: \.capability) { a in
                Section(a.capability.rawValue.capitalized) {
                    HStack {
                        ZStatusBadge("Unavailable", systemImage: "xmark.shield", kind: .error)
                        Spacer()
                        Text(a.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(a.limitations, id: \.self) { lim in
                        Label(lim.message, systemImage: "circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(a.capability.feasibilityNote)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(a.capability.documentationAnchor)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Pairing / JIT / Mux")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AnalyticsHonestView: View {
    @Environment(\.applicationEnvironment) private var environment
    private var assessment: AnalyticsPolicy.Assessment { AnalyticsPolicy.assess() }
    @State private var recentEvents: [LocalAnalyticsEvent] = []
    @State private var counts = LocalAnalyticsJournalCounts.empty
    @State private var showClearConfirm = false
    @State private var shareItem: AnalyticsShareItem?

    var body: some View {
        List {
            measurementSection
            if ReleaseTrain.isAvailable(.activityJournal) {
                journalSection
                if !recentEvents.isEmpty { recentSection }
            }
            guaranteesSection
            notCollectedSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Analytics")
        .navigationBarTitleDisplayMode(.inline)
        .task { reloadJournal() }
        .sheet(item: $shareItem) { item in
            ActivityShareSheet(url: item.url)
        }
        .alert("Clear Activity Journal?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                environment.analyticsJournal.clear()
                reloadJournal()
            }
        } message: {
            Text("Every locally stored event will be deleted from this device. Nothing was ever transmitted, so nothing needs recalling.")
        }
    }

    private var measurementSection: some View {
        Section {
            HStack(spacing: ZSpacing.xs) {
                ZStatusBadge(
                    assessment.isEnabled ? "Enabled" : "None",
                    systemImage: assessment.isEnabled ? "chart.bar.fill" : "eye.slash",
                    kind: assessment.isEnabled ? .success : .neutral
                )
                ZStatusBadge("\(assessment.eventCount) events sent", systemImage: "number", kind: .neutral)
                ZStatusBadge("Endpoint \(AnalyticsPolicy.endpoint.map { _ in "set" } ?? "none")", systemImage: "antenna.radiowaves.left.and.right.slash", kind: .neutral)
            }
            Text(assessment.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Off-Device Measurement — None")
        } footer: {
            Text("`AnalyticsPolicy.isEnabled == false` on every path.")
        }
    }

    private var journalSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { AnalyticsPolicy.isJournalEnabled },
                set: { enabled in
                    UserDefaults.standard.set(enabled, forKey: AnalyticsPolicy.journalDefaultsKey)
                    reloadJournal()
                }
            )) {
                Label("Local activity journal", systemImage: "list.bullet.rectangle")
            }
            LabeledContent("Events on this device", value: "\(counts.total)")
            ForEach(LocalAnalyticsEvent.Category.allCases, id: \.self) { category in
                if let count = counts.byCategory[category], count > 0 {
                    LabeledContent(category.displayName, value: "\(count)")
                }
            }
            Button(role: .destructive) { showClearConfirm = true } label: {
                Label("Clear Journal", systemImage: "trash")
            }
            .disabled(counts.total == 0)
            Button {
                exportJournal()
            } label: {
                Label("Export Journal…", systemImage: "square.and.arrow.up")
            }
            .disabled(counts.total == 0)
        } header: {
            Text("Local Activity Journal")
        } footer: {
            Text("On-device journal of imports, signings, and deliveries. Events carry no bundle identifiers, paths, or user identifiers, and never leave this device.")
        }
    }

    private var recentSection: some View {
        Section("Recent Activity") {
            ForEach(recentEvents) { event in
                HStack(spacing: ZSpacing.xs) {
                    Image(systemName: event.succeeded ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(event.succeeded ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.name).font(.footnote.monospaced())
                        Text(event.category.displayName).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(event.date, format: .dateTime.month().day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var guaranteesSection: some View {
        Section("Guarantees") {
            ForEach(assessment.guarantees, id: \.self) { g in
                Label(g.message, systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var notCollectedSection: some View {
        Section("What is not collected") {
            Label("No IDFV / IDFA / custom identifier for measurement", systemImage: "person.crop.circle.badge.xmark")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label("No screen, event, or error telemetry off-device", systemImage: "antenna.radiowaves.left.and.right.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label("No bundle identifiers, file names, or paths in journal events", systemImage: "doc.text.magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func reloadJournal() {
        counts = environment.analyticsJournal.counts()
        recentEvents = environment.analyticsJournal.recentEvents(limit: 10)
    }

    private func exportJournal() {
        let events = environment.analyticsJournal.recentEvents(limit: AnalyticsPolicy.journalCapacity)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(events) else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ZynSign-Export", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("zynsign-activity-journal.json")
        try? data.write(to: url, options: .atomic)
        shareItem = AnalyticsShareItem(url: url)
    }
}

private struct AnalyticsShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct AppIconSettingsView: View {
    var body: some View {
        List {
            Section {
                Label("Default icon — more variants will appear with future releases.", systemImage: "app.badge")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
    }
}
