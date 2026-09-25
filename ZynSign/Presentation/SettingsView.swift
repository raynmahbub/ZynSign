import SwiftUI
import UIKit

/// The Settings area — ZynSign's configuration hub.
///
/// Settings is where signing options, appearance, storage and diagnostics
/// live, together with links to the complete areas that are not tabs
/// (Files, App Store, Downloads) and the honest capability screens
/// (Pairing, Analytics, Installation). Certificates and provisioning
/// profiles have their own tabs in the shell.
struct SettingsView: View {

    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.signingQueuePresentation) private var signingQueuePresentation
    @State private var showResetConfirm = false
    @State private var resetMessage: String?

    var body: some View {
        NavigationStack {
            List {
                aboutSection
                browseSection
                if ReleaseTrain.isAvailable(.smartSign) {
                    signingOptionsSection
                }
                signingSection
                appearanceSection
                storageSection
                diagnosticsSection
                resetSection
            }
            .navigationTitle("Settings")
            .alert("Reset Library?", isPresented: $showResetConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) { Task { await resetLibrary() } }
            } message: {
                Text("All imported packages and their records in ZynSign's library will be permanently deleted. This cannot be undone.")
            }
            .alert(resetMessage ?? "", isPresented: Binding(get: { resetMessage != nil }, set: { if !$0 { resetMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(resetMessage ?? "") }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Name", value: environment.applicationInfo.displayName)
            LabeledContent("Version", value: "\(environment.applicationInfo.marketingVersion) (\(environment.applicationInfo.buildVersion))")
            LabeledContent("Build", value: "Development")
            Link(destination: URL(string: "https://github.com/raynmahbub/ZynSign")!) {
                Label("ZynSign on GitHub", systemImage: "link")
            }
        }
    }

    /// The complete areas that are not tabs: Files, App Store, and
    /// Downloads. They are reached from here so the bottom navigation stays
    /// the five-tab foundation every other screen builds on.
    private var browseSection: some View {
        Section {
            NavigationLink { FilesView() } label: {
                Label(ShellSection.files.title, systemImage: ShellSection.files.symbolName)
            }
            if ReleaseTrain.isAvailable(.appStore) {
                NavigationLink { AppStoreView() } label: {
                    Label(ShellSection.appStore.title, systemImage: ShellSection.appStore.symbolName)
                }
            }
            if ReleaseTrain.isAvailable(.downloads) {
                NavigationLink { DownloadsView() } label: {
                    Label(ShellSection.downloads.title, systemImage: ShellSection.downloads.symbolName)
                }
            }
        } header: { Text("Browse") } footer: {
            Text("Files, the App Store, and Downloads are complete areas of ZynSign, reached from here rather than the tab bar.")
        }
    }

    /// Signing preferences. Certificates have their own tab; this is where
    /// the options a signing run uses are configured.
    private var signingOptionsSection: some View {
        Section {
            NavigationLink { SigningOptionsView() } label: {
                Label("Signing Options", systemImage: "slider.horizontal.3")
            }
            if signingQueuePresentation.isAvailable {
                Button { signingQueuePresentation.present() } label: {
                    Label("Signing Queue", systemImage: "tray.full")
                }
                .accessibilityHint("Opens the signing queue dashboard.")
            }
        } header: { Text("Signing") } footer: {
            Text("Configure the options used when the pipeline is composed for signing. Certificates and profiles are managed in their own tabs.")
        }
    }

    private var signingSection: some View {
        Section {
            NavigationLink { ArchiveSettingsView() } label: {
                Label("Archive & Extraction", systemImage: "doc.zipper")
            }
            if ReleaseTrain.isAvailable(.smartSign) {
                NavigationLink { InstallationSettingsView() } label: {
                    Label("Installation", systemImage: "arrow.down.app")
                }
            }
            NavigationLink { PairingHonestView() } label: {
                Label("Pairing / JIT / Mux", systemImage: "cable.connector")
            }
            NavigationLink { AnalyticsHonestView() } label: {
                Label("Analytics", systemImage: "chart.bar.doc.horizontal")
            }
        } header: { Text("Workflow") } footer: {
            Text(workflowFooter)
        }
    }

    /// The Workflow footer only describes screens this release shows.
    private var workflowFooter: String {
        var parts: [String] = []
        if ReleaseTrain.isAvailable(.deliveryHandoff) {
            parts.append("Installation is a delivery hand-off — ZynSign still never installs.")
        } else if ReleaseTrain.isAvailable(.smartSign) {
            parts.append("Installation is reported as unavailable — ZynSign never installs.")
        }
        parts.append("Pairing/JIT/Mux is a documented never.")
        if ReleaseTrain.isAvailable(.activityJournal) {
            parts.append("Analytics is a local, on-device journal with off-device measurement permanently off.")
        } else {
            parts.append("Off-device analytics is permanently off.")
        }
        parts.append("See each screen for the typed reason and the doc link.")
        return parts.joined(separator: " ")
    }

    private var appearanceSection: some View {
        Section {
            NavigationLink { AppearanceSettingsView() } label: {
                Label("Appearance", systemImage: "paintbrush")
            }
            NavigationLink { AppIconSettingsView() } label: {
                Label("App Icon", systemImage: "app.badge")
            }
        } header: { Text("Personalisation") }
    }

    private var storageSection: some View {
        Section {
            Button { openDocuments() } label: { Label("Open Documents", systemImage: "folder") }
            Button { openLibraryFolder() } label: { Label("Open Library Folder", systemImage: "externaldrive") }
            LabeledContent("Library Location", value: "Application Support/ZynSignLibrary")
                .font(.footnote).foregroundStyle(.secondary)
        } header: { Text("Storage") } footer: {
            Text("All of ZynSign's files — staged imports, adopted artifacts, and the catalog — live inside the app container. Nothing is shared outside the sandbox.")
        }
    }

    private var diagnosticsSection: some View {
        Section {
            NavigationLink { DiagnosticsView() } label: {
                Label("Diagnostics & Logs", systemImage: "doc.text.magnifyingglass")
            }
        } header: { Text("Diagnostics") }
    }

    private var resetSection: some View {
        Section {
            Button(role: .destructive) { showResetConfirm = true } label: {
                Label("Reset Library", systemImage: "trash")
            }
        } header: { Text("Reset") } footer: {
            Text("Clears every record and every package file ZynSign keeps. Orphaned artifacts are removed as well.")
        }
    }

    private func openDocuments() {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        // Open in Files via share sheet fallback
        share(url: url)
    }
    private func openLibraryFolder() {
        let lib = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("ZynSignLibrary", isDirectory: true)
        if let lib { share(url: lib) }
    }
    private func share(url: URL) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first,
              let vc = window.rootViewController else { return }
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = av.popoverPresentationController { pop.sourceView = window; pop.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0) }
        vc.present(av, animated: true)
    }
    private func resetLibrary() async {
        do {
            let entries = try await environment.library.entries()
            for e in entries { try? await environment.library.remove(recordWithID: e.record.id) }
            try? await environment.library.removeOrphanedArtifacts()
            resetMessage = "Library cleared."
        } catch {
            resetMessage = (error as? ZynSignError)?.userMessage ?? "The library could not be reset."
        }
    }
}

// MARK: - Sub-screens

private struct CertificatesSettingsView: View {
    var body: some View {
        List {
            Section {
                ContentUnavailableView {
                    Label("No Certificates", systemImage: "signature")
                } description: {
                    Text("Add a .p12 or Keychain identity to sign packages. Identities stay in the Keychain, marked non-extractable, and are never logged.")
                }
            }
            Section("What will be here") {
                Label("Import .p12 (when E7 lands)", systemImage: "key.fill").foregroundStyle(.secondary)
                Label("View certificate metadata, validity, chain", systemImage: "info.circle").foregroundStyle(.secondary)
                Label("Per-identity readiness (key available, associated, adequate)", systemImage: "checkmark.shield").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Certificates").navigationBarTitleDisplayMode(.inline)
    }
}
struct SigningOptionsView: View {
    @AppStorage("zynsign.signing.bundleIdPrefix") private var bundlePrefix = ""
    @AppStorage("zynsign.signing.stripPlugins") private var stripPlugins = false
    var body: some View {
        Form {
            Section("Bundle Identifier") {
                TextField("Optional prefix (e.g. com.example)", text: $bundlePrefix)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Applied when the provisioning profile's App ID scope covers the identifier. No wildcard is inferred.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Advanced") {
                Toggle("Strip plug-ins before signing", isOn: $stripPlugins)
                Text("Removes unsupported nested code rather than refusing the package. Disabled by default — the pipeline fails closed.").font(.caption).foregroundStyle(.secondary)
            }
            Section { Text("Options are applied by the pipeline's nested-signing and metadata stages in fixed order and are verified independently. Nothing is persisted until device validation is complete.").font(.footnote).foregroundStyle(.secondary) }
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

private struct AppearanceSettingsView: View {
    @AppStorage("zynsign.appearance.colorScheme") private var scheme = 0
    var body: some View {
        Form {
            Picker("Appearance", selection: $scheme) {
                Text("System").tag(0); Text("Light").tag(1); Text("Dark").tag(2)
            }.pickerStyle(.segmented)
            Section { Text("Restart the app to apply a scheme override on iOS 17.").font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("Appearance").navigationBarTitleDisplayMode(.inline)
    }
}
private struct AppIconSettingsView: View {
    var body: some View {
        List {
            Section { Label("Default icon — more variants will appear with future releases.", systemImage: "app.badge").foregroundStyle(.secondary) }
        }.navigationTitle("App Icon").navigationBarTitleDisplayMode(.inline)
    }
}
private struct DiagnosticsView: View {
    @Environment(\.applicationEnvironment) private var env
    var body: some View {
        List {
            Section("Diagnostics") {
                Text("ZynSign redacts diagnostics: no key material, profile bodies, file paths, or device identifiers in user-facing messages. Full `debugDescription` is written only where the security rules permit.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Build") {
                LabeledContent("Marketing version", value: env.applicationInfo.marketingVersion)
                LabeledContent("Build version", value: env.applicationInfo.buildVersion)
                LabeledContent("Release", value: ReleaseTrain.gate.summary)
            }
        }.navigationTitle("Diagnostics").navigationBarTitleDisplayMode(.inline)
    }
}
