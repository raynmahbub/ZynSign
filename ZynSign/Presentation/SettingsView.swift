import SwiftUI
import UIKit

/// The Settings Control Center.
///
/// Settings is an index, not a form. Everything a user can configure lives in
/// its own section, reached from here, and every section is a peer of every
/// other: the hub lists what the catalog holds and nothing more, so a new
/// section is a new file rather than a new case in this view.
///
/// The order is deliberate — what ZynSign is, what else it can show you, the
/// preferences you will actually change, the honest capability screens, the
/// settings kept apart from everyday use, and finally what the application is
/// and ships with.
struct SettingsView: View {

    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.signingQueuePresentation) private var signingQueuePresentation

    var body: some View {
        NavigationStack {
            List {
                summarySection
                Section { ReleaseReadinessLink() }
                browseSection
                preferencesSection
                workflowSection
                separatedSection
                aboutSection
            }
            .navigationTitle("Settings")
        }
    }

    // MARK: - ZynSign

    /// What this build is, in one row. The rest is in About.
    private var summarySection: some View {
        Section {
            HStack(spacing: ZSpacing.md) {
                ZynSignAppMark(size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(environment.applicationInfo.displayName)
                        .font(.headline)
                    Text("Version \(environment.applicationInfo.marketingVersion) (\(environment.applicationInfo.buildVersion))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        } footer: {
            Text("Every preference is saved as you change it. Nothing here waits for a confirmation — except the one reset in Recovery that deletes imported applications, which says what it will delete and asks twice.")
        }
    }

    /// The complete areas that are not tabs: Files, Store, and
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
            Text("Files and the Store are reached from here. Downloads is also a tab when that feature is available. Store jobs stay isolated until you import them, and Download Center cleanup never deletes imported apps.")
        }
    }

    /// The everyday preference sections, listed from the catalog.
    ///
    /// The hub knows their titles and where they go; it knows nothing about
    /// what is inside them, which is what lets a section be added, extended,
    /// or reordered without touching this view.
    private var preferencesSection: some View {
        Section {
            ForEach(SettingsSectionCatalog.everyday) { section in
                NavigationLink { section.destination() } label: {
                    ZSettingsLabel(
                        title: section.descriptor.title,
                        subtitle: section.descriptor.summary,
                        symbol: section.descriptor.symbolName
                    )
                }
            }
        } header: { Text("Preferences") } footer: {
            Text("General, signing, security, storage, diagnostics, and appearance. Each section explains what it changes and what it cannot.")
        }
    }

    /// The honest capability screens: what ZynSign does, and what it
    /// deliberately does not.
    private var workflowSection: some View {
        Section {
            if ReleaseTrain.isAvailable(.smartSign) {
                NavigationLink { SigningOptionsView() } label: {
                    Label("Signing Options", systemImage: "slider.horizontal.3")
                }
            }
            if signingQueuePresentation.isAvailable {
                Button { signingQueuePresentation.present() } label: {
                    Label("Signing Queue", systemImage: "tray.full")
                }
                .accessibilityHint("Opens the signing queue dashboard.")
            }
            if ReleaseTrain.isAvailable(.signingPresets) {
                NavigationLink {
                    PresetsView(embedsNavigationStack: false)
                } label: {
                    Label("Signing Presets", systemImage: "rectangle.stack")
                }
                .accessibilityHint("Opens saved signing presets. Choosing one does not sign.")
            }
            if ReleaseTrain.isAvailable(.identityCenter), let identityCenter = environment.identityCenter {
                NavigationLink {
                    IdentityCenterView(service: identityCenter)
                } label: {
                    Label("Developer Identity", systemImage: "person.badge.key.fill")
                }
                .accessibilityHint("Opens the Developer Identity Center: teams, certificates, profiles, health, and conflicts.")
            }
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

    /// Advanced and recovery, listed apart from everyday settings.
    private var separatedSection: some View {
        Section {
            ForEach(SettingsSectionCatalog.separated) { section in
                NavigationLink { section.destination() } label: {
                    ZSettingsLabel(
                        title: section.descriptor.title,
                        subtitle: section.descriptor.summary,
                        symbol: section.descriptor.symbolName
                    )
                }
            }
        } header: { Text("Advanced & Recovery") } footer: {
            Text("Advanced changes how ZynSign works internally. Recovery restores a known-good state without taking anything you imported — with one labelled exception.")
        }
    }

    /// About, last: what this build is and what ships with it.
    private var aboutSection: some View {
        Section {
            ForEach(SettingsSectionCatalog.about) { section in
                NavigationLink { section.destination() } label: {
                    ZSettingsLabel(
                        title: section.descriptor.title,
                        subtitle: section.descriptor.summary,
                        symbol: section.descriptor.symbolName
                    )
                }
            }
        } header: { Text("About") }
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
