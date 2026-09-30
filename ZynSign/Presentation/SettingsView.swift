import SwiftUI
import UIKit

/// Searchable, reorderable settings home. Every category opens an existing
/// settings workflow; unavailable platform capabilities are stated honestly
/// rather than presented as working controls.
struct SettingsView: View {

    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.signingQueuePresentation) private var signingQueuePresentation
    @Environment(\.importPresentation) private var importPresentation
    @AppStorage("zynsign.settings.categoryOrder") private var storedCategoryOrder = ""
    @State private var searchText = ""
    @State private var editMode: EditMode = .inactive

    private var orderedCategories: [SettingsCategory] {
        let storedIDs = storedCategoryOrder.split(separator: ",").compactMap {
            SettingsCategory(rawValue: String($0))
        }
        var result = storedIDs.reduce(into: [SettingsCategory]()) { result, category in
            if !result.contains(category) { result.append(category) }
        }
        result.append(contentsOf: SettingsCategory.allCases.filter { !result.contains($0) })
        return result
    }

    private var visibleCategories: [SettingsCategory] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return orderedCategories }
        return orderedCategories.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.summary.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(visibleCategories) { category in
                    NavigationLink {
                        destination(for: category)
                    } label: {
                        SettingsCategoryRow(category: category)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                }
                .onMove(perform: moveCategories)

                if searchText.isEmpty, editMode == .inactive {
                    Section {
                        Button {
                            withAnimation(.snappy) { editMode = .active }
                        } label: {
                            Label("Change the order", systemImage: "arrow.up.arrow.down")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, $editMode)
            .searchable(text: $searchText, prompt: "Search Settings")
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editMode == .active ? "Done" : "Edit") {
                        withAnimation(.snappy) {
                            editMode = editMode == .active ? .inactive : .active
                        }
                    }
                    .disabled(!searchText.isEmpty)
                }
            }
            .overlay {
                if !searchText.isEmpty && visibleCategories.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }

    private func moveCategories(from source: IndexSet, to destination: Int) {
        guard searchText.isEmpty else { return }
        var reordered = orderedCategories
        reordered.move(fromOffsets: source, toOffset: destination)
        storedCategoryOrder = reordered.map(\.rawValue).joined(separator: ",")
    }

    @ViewBuilder
    private func destination(for category: SettingsCategory) -> some View {
        switch category {
        case .signing: signingCategory
        case .updates: updatesCategory
        case .general: generalCategory
        case .devices: devicesCategory
        case .servers: serversCategory
        case .miscellaneous: miscellaneousCategory
        case .diagnostics: diagnosticsCategory
        case .reset: RecoverySettingsSection()
        case .about: AboutSettingsSection()
        case .socials: socialsCategory
        }
    }

    private var signingCategory: some View {
        List {
            Section("Signing Setup") {
                NavigationLink { SigningPreferencesSection() } label: {
                    ZSettingsLabel(title: "Signing Preferences", subtitle: "Default identity, profile, and selection behavior.", symbol: "slider.horizontal.3")
                }
                NavigationLink {
                    CertificateManagerView(
                        store: environment.identityStore,
                        annotations: environment.identityAnnotations,
                        importer: environment.pkcs12Importer
                    )
                } label: {
                    ZSettingsLabel(title: "Certificates", subtitle: "Import and manage .p12 / .pfx identities.", symbol: "signature")
                }
                NavigationLink {
                    ProfilesView(
                        profiles: environment.provisioningProfiles,
                        importer: environment.provisioningProfileImporter,
                        compatibility: environment.profileCompatibility,
                        selections: environment.profileSelections,
                        recordEvent: { name, succeeded in
                            environment.recordAnalyticsEvent(category: .intake, name: name, succeeded: succeeded)
                        },
                        embedsNavigationStack: false
                    )
                } label: {
                    ZSettingsLabel(title: "Provisioning Profiles", subtitle: "Import, inspect, and select profiles.", symbol: "person.text.rectangle")
                }
            }
            Section("Signing Tools") {
                NavigationLink { SigningOptionsView() } label: {
                    ZSettingsLabel(title: "Signing Options", subtitle: "Review supported pipeline behavior.", symbol: "slider.horizontal.3")
                }
                if let tweaks = environment.tweakLibrary {
                    NavigationLink { TweakLibraryView(service: tweaks) } label: {
                        ZSettingsLabel(title: "Tweak Library", subtitle: "Import and organize payloads for signing sessions.", symbol: "puzzlepiece.extension")
                    }
                }
                if let revocation = environment.revocationService {
                    NavigationLink { RevocationCenterView(service: revocation, identityStore: environment.identityStore) } label: {
                        ZSettingsLabel(title: "Revocation Center", subtitle: "Check how reachable a certificate's revocation channels are.", symbol: "shield.checkered")
                    }
                }
                if signingQueuePresentation.isAvailable {
                    Button { signingQueuePresentation.present() } label: {
                        ZSettingsLabel(title: "Signing Queue", subtitle: "Review and manage queued signing jobs.", symbol: "tray.full")
                    }
                }
                if ReleaseTrain.isAvailable(.signingPresets) {
                    NavigationLink { PresetsView(embedsNavigationStack: false) } label: {
                        ZSettingsLabel(title: "Signing Presets", subtitle: "Manage reusable signing configurations.", symbol: "rectangle.stack")
                    }
                }
            }
            if ReleaseTrain.isAvailable(.identityCenter), let identityCenter = environment.identityCenter {
                Section {
                    NavigationLink { IdentityCenterView(service: identityCenter) } label: {
                        ZSettingsLabel(title: "Developer Identity Center", subtitle: "Teams, identity health, conflicts, and expiration.", symbol: "person.badge.key")
                    }
                }
            }
        }
        .navigationTitle("Signing")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var updatesCategory: some View {
        List {
            Section {
                Text("Updates are reviewed before download. ZynSign does not silently switch repositories, import packages, sign them, or install them.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let store = environment.storeBrowser {
                Section("Repositories & Updates") {
                    NavigationLink { StoreUpdatesView(model: store) } label: {
                        ZSettingsLabel(title: "Updates", subtitle: "Compare repository releases with your library.", symbol: "arrow.triangle.2.circlepath")
                    }
                    NavigationLink { StoreSavedAppsView(model: store) } label: {
                        ZSettingsLabel(title: "Saved Apps", subtitle: "Review apps saved for later; saving never downloads.", symbol: "bookmark")
                    }
                    NavigationLink { StoreSourcesView(model: store) } label: {
                        ZSettingsLabel(title: "Repositories", subtitle: "Add, validate, refresh, and remove source URLs.", symbol: "globe")
                    }
                    NavigationLink { DownloadsView(embedsNavigationStack: false) } label: {
                        ZSettingsLabel(title: "Downloads", subtitle: "Manage transfer jobs and review downloaded packages.", symbol: "arrow.down.circle")
                    }
                    if let feeds = environment.releaseFeeds {
                        NavigationLink { ReleaseFeedsView(provider: feeds, library: environment.library) } label: {
                            ZSettingsLabel(title: "Release Feeds", subtitle: "Follow repository releases and track app updates.", symbol: "shippingbox")
                        }
                    }
                }
            } else {
                Section {
                    ContentUnavailableView("Updates Unavailable", systemImage: "arrow.triangle.2.circlepath", description: Text("Repository and download services are not configured in this build."))
                }
            }
        }
        .navigationTitle("Updates")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var generalCategory: some View {
        List {
            Section("App Preferences") {
                NavigationLink { GeneralSettingsSection() } label: {
                    ZSettingsLabel(title: "General", subtitle: "Landing tab, feedback, motion, and onboarding.", symbol: "gearshape")
                }
                NavigationLink { AppearanceSettingsSection() } label: {
                    ZSettingsLabel(title: "Appearance", subtitle: "Color scheme, contrast, text size, and theme.", symbol: "circle.lefthalf.filled")
                }
                NavigationLink { StorageManagerSection() } label: {
                    ZSettingsLabel(title: "Storage", subtitle: "Review app storage and manage local data.", symbol: "externaldrive")
                }
            }
            Section("Notifications") {
                Label("In-app notices are used for import, download, and signing results.", systemImage: "bell.badge")
                Text("This build has no separate push-notification or automatic-update switch. Transfer and update decisions remain under your control.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var devicesCategory: some View {
        List {
            Section {
                Text("ZynSign can inspect and prepare files on this device. It does not pair with Apple TV, Watch, Mac, or Vision Pro, and it does not enable JIT.")
                    .font(.footnote).foregroundStyle(.secondary)
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
                        ZSettingsLabel(title: "Installation Workspace", subtitle: "Review delivery readiness and handoff history; ZynSign does not install apps.", symbol: "arrow.down.app")
                    }
                }
            }
            if ReleaseTrain.isAvailable(.smartSign) {
                Section("Capability") {
                    NavigationLink { InstallationSettingsView() } label: {
                        ZSettingsLabel(title: "Installation Capability", subtitle: "See the platform limits and supported handoff behavior.", symbol: "checkmark.shield")
                    }
                }
            }
            Section("Unsupported Capabilities") {
                NavigationLink { PairingHonestView() } label: {
                    ZSettingsLabel(title: "Pairing / JIT / Mux", subtitle: "See supported boundaries and feasibility notes.", symbol: "cable.connector")
                }
            }
        }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var serversCategory: some View {
        List {
            Section("Repository Connections") {
                if let store = environment.storeBrowser {
                    NavigationLink { StoreSourcesView(model: store) } label: {
                        ZSettingsLabel(title: "Repository Sources", subtitle: "Manage HTTPS catalogs used for discovery and downloads.", symbol: "globe")
                    }
                }
                Text("Repository feeds are read when you choose to add or refresh them. Their metadata is unverified; adding a source does not establish trust.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Not Available") {
                Label("WebDAV and an always-on file server are not implemented.", systemImage: "externaldrive.badge.questionmark")
                Label("Remote signing is not implemented. Signing stays on this device.", systemImage: "signature")
            }
        }
        .navigationTitle("Servers")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var miscellaneousCategory: some View {
        List {
            Section("Files & Archives") {
                NavigationLink { FilesView(embedsNavigationStack: false) } label: {
                    ZSettingsLabel(title: "Files", subtitle: "Browse ZynSign's local files and exports.", symbol: "folder")
                }
                NavigationLink { ArchiveSettingsView() } label: {
                    ZSettingsLabel(title: "Archive & Extraction", subtitle: "Review supported formats and safe extraction limits.", symbol: "doc.zipper")
                }
                NavigationLink { AdvancedSettingsSection() } label: {
                    ZSettingsLabel(title: "Advanced", subtitle: "Working directory, cleanup policy, and verification strictness.", symbol: "slider.horizontal.3")
                }
                if importPresentation.isAvailable {
                    Button { importPresentation.chooseFiles() } label: {
                        ZSettingsLabel(title: "Import Files", subtitle: "Choose an IPA, TIPA, or supported archive.", symbol: "square.and.arrow.down")
                    }
                }
            }
            Section("Recovery") {
                NavigationLink { RecoveryCenterView() } label: {
                    ZSettingsLabel(title: "Backup & Restore", subtitle: "Create an encrypted backup or selectively restore data.", symbol: "lock.shield")
                }
            }
        }
        .navigationTitle("Miscellaneous")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var diagnosticsCategory: some View {
        List {
            Section("Troubleshooting") {
                NavigationLink { DiagnosticsPreferencesSection() } label: {
                    ZSettingsLabel(title: "Diagnostics", subtitle: "Control local logs and prepare diagnostic reports.", symbol: "stethoscope")
                }
                NavigationLink { AnalyticsHonestView() } label: {
                    ZSettingsLabel(title: "Analytics & Activity", subtitle: "Review what stays on-device and what is never sent.", symbol: "chart.bar.doc.horizontal")
                }
                ReleaseReadinessLink()
            }
            if CompatibilityLabAvailability.isCompiledIn {
                Section("Validation") {
                    NavigationLink { CompatibilityLabSection() } label: {
                        ZSettingsLabel(title: "Compatibility Lab", subtitle: "Run release and compatibility checks.", symbol: "checkmark.shield")
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
                        ZSettingsLabel(title: "Performance", subtitle: "Inspect caches, memory, indexes, and benchmarks.", symbol: "speedometer")
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var socialsCategory: some View {
        List {
            Section("ZynSign Community") {
                if let repositoryURL = URL(string: "https://github.com/raynmahbub/ZynSign") {
                    Link(destination: repositoryURL) {
                        ZSettingsLabel(title: "GitHub Repository", subtitle: "Source code, releases, and project discussions.", symbol: "chevron.left.forwardslash.chevron.right")
                    }
                }
                if let issueURL = URL(string: "https://github.com/raynmahbub/ZynSign/issues/new/choose") {
                    Link(destination: issueURL) {
                        ZSettingsLabel(title: "Report an Issue", subtitle: "Send a bug report or feature request on GitHub.", symbol: "ladybug")
                    }
                }
            }
            Section {
                Text("GitHub opens in your browser. Do not include signing keys, passwords, provisioning secrets, or private app files in an issue.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Socials")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case signing, updates, general, devices, servers, miscellaneous, diagnostics, reset, about, socials

    var id: String { rawValue }
    var title: String {
        switch self {
        case .signing: return "Signing"
        case .updates: return "Updates"
        case .general: return "General"
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
        case .updates: return "Repositories, available updates, and downloads"
        case .general: return "Appearance, tabs, app behavior, and storage"
        case .devices: return "Supported device handoff and capability status"
        case .servers: return "Repository connections and server capabilities"
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
        case .general: return "gearshape"
        case .devices: return "iphone.gen3"
        case .servers: return "server.rack"
        case .miscellaneous: return "square.grid.2x2"
        case .diagnostics: return "stethoscope"
        case .reset: return "arrow.counterclockwise"
        case .about: return "info.circle"
        case .socials: return "bubble.left.and.bubble.right"
        }
    }
}

private struct SettingsCategoryRow: View {
    let category: SettingsCategory

    var body: some View {
        HStack(spacing: ZSpacing.md) {
            Image(systemName: category.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: ZRadius.card, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                Text(category.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(category.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(ZSpacing.sm)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: ZRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ZRadius.lg, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sub-screens

/// Only controls that the signing screen really passes to the pipeline may
/// appear here. Settings has no global signing configuration to silently
/// promise a bundle-ID rewrite or plug-in removal the pipeline cannot do.
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
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("This build embeds XML entitlements only. DER output is not supported. Open an app in the Library to review its local signing diagnostics.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Supported today") {
                Text("The current pipeline only signs supported unsigned Mach-O layouts. It cannot replace existing signatures, change bundle identifiers, or strip nested code. Pre-sign diagnostics checks those limits before signing.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Signing Options").navigationBarTitleDisplayMode(.inline)
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
            Section { Text("Limits are architectural — enforced before any work is done. A package beyond them is refused with a typed error rather than expanded.").font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("Archive & Extraction").navigationBarTitleDisplayMode(.inline)
    }
}
private struct InstallationSettingsView: View {
    private var assessment: InstallationAssessment {
        InstallationCapabilityAssessment.assess(InstallationEvidence(profileStatus: .indeterminate, deviceAuthorized: nil, platformSupported: nil))
    }
    var body: some View {
        List {
            Section {
                HStack(spacing: ZSpacing.xs) {
                    ZStatusBadge("Unavailable", systemImage: "xmark.shield", kind: .error)
                    ZStatusBadge(assessment.limitations.first?.rawValue ?? "—", systemImage: "exclamationmark.triangle", kind: .warning)
                }
                Label(assessment.summary, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote)
                ForEach(assessment.limitations, id: \.self) { lim in
                    Label(lim.message, systemImage: "circle.fill").font(.caption).foregroundStyle(.secondary)
                        .listRowInsets(EdgeInsets(top: 4, leading: 32, bottom: 4, trailing: 16))
                }
            } header: { Text("Installation — Honest Unavailable") } footer: { Text("`InstallationCapabilityAssessment.deliveryMechanismAvailable == false` on every path. Extending requires a demonstrated mechanism (MDM/OTA/host) and an ADR. See docs/architecture/installation-compatibility.md.") }
            if ReleaseTrain.isAvailable(.deliveryHandoff) {
                Section("Delivery hand-off") {
                    ZStatusBadge("Hand-off wired", systemImage: "tray.and.arrow.up", kind: .info)
                    Text("After a successful sign, **Deliver…** on the signing screen builds an over-the-air manifest (itms-services), a ready-to-paste install link, and a QR code, plus step-by-step guides for the three operator channels: OTA hosting, MDM, and host tooling (Finder / Apple Configurator).").font(.footnote).foregroundStyle(.secondary)
                    Text("The hand-off produces artifacts for you — it never uploads, hosts, contacts a server, or learns whether an install happened. Installation itself remains exactly as unavailable as above.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("What ZynSign does today") {
                Text("Validates artifact, signature, and provisioning separately and reports installation as unavailable with exact limitations. Delivery of a signed IPA is the operator's responsibility (MDM, OTA with user confirmation, or host tooling). Signed output is in `Documents/Signed/*_signed.ipa`.").font(.footnote).foregroundStyle(.secondary)
                LabeledContent("Supported", value: assessment.supported ? "Yes" : "No").foregroundStyle(assessment.supported ? .green : .orange)
            }
            Section("Honest detail") {
                Text("Evidence read: profileStatus, deviceAuthorized, platformSupported — all passed in, never inferred. Missing facts stay missing. Limitations are deterministic, redacted, and in fixed order.").font(.caption).foregroundStyle(.tertiary)
            }
        }.navigationTitle("Installation").navigationBarTitleDisplayMode(.inline)
    }
}

private struct PairingHonestView: View {
    private var assessments: [PairingAssessment] { PairingCapabilityAssessment.allUnavailable }
    var body: some View {
        List {
            Section {
                HStack(spacing: ZSpacing.xs) { ZStatusBadge("Never", systemImage: "xmark.octagon", kind: .error); ZStatusBadge("4 capabilities", systemImage: "cable.connector", kind: .neutral) }
                Text("Pairing / JIT / Mux / OpenSSL linkage are not planned for any release through 1.0.0. No PairingKit, no JITBroker, no usbmuxd, no OpenSSL linked into the app binary. Keeps the binary reviewable and avoids private-API risk.").font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Pairing / JIT / Mux — Never") } footer: { Text("Until an ADR demonstrates feasibility, every `PairingCapabilityAssessment.assess(_:)` returns `supported == false` with typed limitations. The feasibility record — the private surface each capability needs and the triggers that would reopen the question — is docs/architecture/pairing-jit-mux-feasibility.md. See also docs/product/WHAT_DOES_NOT_EXIST.md.") }
            ForEach(assessments, id: \.capability) { a in
                Section(a.capability.rawValue.capitalized) {
                    HStack { ZStatusBadge("Unavailable", systemImage: "xmark.shield", kind: .error); Spacer(); Text(a.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    ForEach(a.limitations, id: \.self) { lim in Label(lim.message, systemImage: "circle.fill").font(.caption2).foregroundStyle(.tertiary) }
                    Text(a.capability.feasibilityNote).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(a.capability.documentationAnchor).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
            }
            Section("OpenSSL note") {
                Text("OpenSSL is used only in `Tests/Host` external validation (`openssl cms -verify` on host), never linked into the app. Binary stays reviewable.").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Pairing / JIT / Mux").navigationBarTitleDisplayMode(.inline)
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
        .navigationTitle("Analytics").navigationBarTitleDisplayMode(.inline)
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
                ZStatusBadge(assessment.isEnabled ? "Enabled" : "None", systemImage: assessment.isEnabled ? "chart.bar.fill" : "eye.slash", kind: assessment.isEnabled ? .success : .neutral)
                ZStatusBadge("\(assessment.eventCount) events sent", systemImage: "number", kind: .neutral)
                ZStatusBadge("Endpoint \(AnalyticsPolicy.endpoint.map { _ in "set" } ?? "none")", systemImage: "antenna.radiowaves.left.and.right.slash", kind: .neutral)
            }
            Text(assessment.summary).font(.footnote).foregroundStyle(.secondary)
        } header: { Text("Off-Device Measurement — None") } footer: { Text("`AnalyticsPolicy.isEnabled == false` on every path. Any future off-device measurement requires an ADR, an Application port, a Platform implementation, user consent storage, and an opt-in toggle in Settings.") }
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
        } header: { Text("Local Activity Journal") } footer: {
            Text("A small, on-device journal of what ZynSign has done — imports, signings, deliveries — so you can see its activity without trusting a server. Events carry a category, a fixed slug, a time, and an outcome: no bundle identifiers, no paths, no device or user identifiers. The journal never leaves the device; export writes a copy for you to keep.")
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
        Section {
            ForEach(assessment.guarantees, id: \.self) { g in
                Label(g.message, systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("Guarantees") }
    }

    private var notCollectedSection: some View {
        Section("What is not collected") {
            Label("No IDFV / IDFA / custom identifier for measurement", systemImage: "person.crop.circle.badge.xmark").font(.caption).foregroundStyle(.secondary)
            Label("No screen, event, or error telemetry off-device", systemImage: "antenna.radiowaves.left.and.right.slash").font(.caption).foregroundStyle(.secondary)
            Label("No bundle identifiers, file names, or paths in journal events", systemImage: "doc.text.magnifyingglass").font(.caption).foregroundStyle(.secondary)
            Label("Diagnostics are on-device, redacted; see Diagnostics screen", systemImage: "doc.text.magnifyingglass").font(.caption).foregroundStyle(.secondary)
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
            Section { Label("Default icon — more variants will appear with future releases.", systemImage: "app.badge").foregroundStyle(.secondary) }
        }.navigationTitle("App Icon").navigationBarTitleDisplayMode(.inline)
    }
}
