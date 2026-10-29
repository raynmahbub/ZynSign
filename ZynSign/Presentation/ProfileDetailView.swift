import SwiftUI
import UIKit

/// One profile in full: the General, Application, and Distribution facts
/// the spec asks for, the Smart Compatibility Engine's pre-sign checks and
/// Compatibility Summary, the Diagnostics Panel with severity badges, and
/// the quick actions — all read through the environment so the same screen
/// opens from the Profiles section and from an app's detail suggestion.
///
/// Nothing here re-derives facts: the summary holds what import recorded,
/// Refresh Validation re-reads the stored file, and the compatibility
/// report is the domain engine's output for the current certificates and
/// reference instant.
struct ProfileDetailView: View {

    /// The profile as last read or refreshed.
    @State private var current: ProvisioningProfileSummary

    /// Called after the library changes through this screen — removal or
    /// refresh — so a hosting list or suggestion can re-read.
    private let onLibraryChanged: (() -> Void)?

    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var report: ProfileCompatibilityReport?
    @State private var preferredProfileID: ProvisioningProfileIdentifier?
    @State private var isRefreshingValidation = false
    @State private var pendingRemoval = false
    @State private var notice: Notice?
    @State private var isShowingToast = false
    @State private var toastMessage = ""
    @State private var toastStyle: ZToast.Style = .success
    @State private var provisionedUDIDs: [String] = []
    @State private var udidQuery = ""
    @State private var entitlementsXML: String?
    @State private var shareEntitlementsURL: URL?

    /// A transient, user-presentable announcement.
    private struct Notice: Equatable, Identifiable {
        let title: String
        let message: String
        var id: String { "\(title)-\(message)" }
    }

    init(
        summary: ProvisioningProfileSummary,
        onLibraryChanged: (() -> Void)? = nil
    ) {
        _current = State(initialValue: summary)
        self.onLibraryChanged = onLibraryChanged
    }

    private var noticeBinding: Binding<Bool> {
        Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )
    }

    private var isPreferred: Bool {
        preferredProfileID == current.id
    }

    private var compatibility: ProfileCompatibilityUseCase? {
        environment.profileCompatibility
    }

    var body: some View {
        List {
            headerSection
            generalSection
            applicationSection
            distributionSection
            if !provisionedUDIDs.isEmpty {
                udidLookupSection
            }
            if compatibility != nil {
                compatibilitySection
                diagnosticsSection
            }
            entitlementsSection
            quickActionsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refreshValidation() }
        .zToast(isPresented: $isShowingToast, message: toastMessage, style: toastStyle)
        .sheet(isPresented: Binding(
            get: { shareEntitlementsURL != nil },
            set: { if !$0 { shareEntitlementsURL = nil } }
        )) {
            if let url = shareEntitlementsURL {
                CertificateToolShareSheet(url: url)
            }
        }
        .task {
            preferredProfileID = environment.profileSelections?.preferredProfileID()
            evaluate()
            await loadStoredProfileDetails()
        }
        .alert(
            notice?.title ?? "",
            isPresented: noticeBinding,
            presenting: notice
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
        .confirmationDialog(
            "Delete Profile?",
            isPresented: $pendingRemoval,
            titleVisibility: .visible
        ) {
            Button("Delete Profile", role: .destructive) {
                Task { await removeCurrent() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(current.name)” and its stored .mobileprovision file will be permanently deleted. This cannot be undone.")
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        Section {
            HStack(spacing: ZSpacing.xs) {
                ProfileTypeBadge(type: current.resolvedProfileType)
                ProfileExpirationBadge(current.expirationAssessment())
                if isPreferred {
                    ZStatusBadge("Selected", systemImage: "star.fill", kind: .info)
                }
            }
            if let report {
                HStack(spacing: ZSpacing.xs) {
                    ProfileCompatibilityBadge(outcome: report.overall)
                    Text(report.summaryLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text(current.isExpired()
                 ? "This profile is past its expiration date. A signing operation that uses it will produce a package iOS refuses to launch."
                 : "\(current.expirationAssessment().countdownText). Profiles past expiration are the quietest way a signing operation fails.")
        }
    }

    // MARK: - General

    private var generalSection: some View {
        Section("General") {
            LabeledContent("Name", value: current.name)
            if let uuid = current.uuid {
                LabeledContent("UUID") {
                    Text(uuid)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            LabeledContent("Team Name", value: current.teamName ?? "—")
            LabeledContent("Team ID", value: current.teamIdentifier ?? "—")
            LabeledContent("Created") {
                if let created = current.creationDate {
                    Text(created, format: .dateTime.year().month().day())
                } else {
                    Text("—")
                }
            }
            LabeledContent("Expires") {
                Text(current.expirationDate, format: .dateTime.year().month().day().hour().minute())
                    .monospacedDigit()
            }
            LabeledContent("Imported") {
                Text(current.importedAt, format: .dateTime.year().month().day().hour().minute())
            }
        }
    }

    // MARK: - Application

    private var applicationSection: some View {
        Section {
            LabeledContent("App ID") {
                Text(current.applicationIdentifier ?? "—")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            LabeledContent("Bundle Identifier", value: current.bundleIdentifier ?? "—")
            LabeledContent("App ID Kind") {
                if current.bundleIdentifier != nil || current.applicationIdentifier != nil {
                    ZStatusBadge(
                        current.isWildcard ? "Wildcard" : "Explicit",
                        systemImage: current.isWildcard ? "asterisk" : "checkmark.circle",
                        kind: current.isWildcard ? .info : .success
                    )
                } else {
                    Text("—")
                }
            }
            if !current.bundleIdentifierPatterns.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Covers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(current.bundleIdentifierPatterns, id: \.self) { pattern in
                        Text(pattern)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        } header: {
            Text("Application")
        } footer: {
            Text("A wildcard ends in .* and covers every identifier beneath its prefix. Explicit App IDs cover exactly one app.")
        }
    }

    // MARK: - Distribution

    private var distributionSection: some View {
        Section {
            LabeledContent("Distribution Type", value: current.resolvedProfileType.displayName)
            LabeledContent("Devices", value: current.deviceCountDescription ?? "—")
            LabeledContent("Certificates") {
                if let fingerprints = current.certificateFingerprints, !fingerprints.isEmpty {
                    Text("\(fingerprints.count)")
                } else {
                    Text("Not recorded")
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Debug Builds", value: current.allowsDebug ? "Yes (get-task-allow)" : "No")
        } header: {
            Text("Distribution")
        } footer: {
            Text(current.resolvedProfileType == .appStore
                 ? "App Store profiles are shown for inspection only; they cannot install outside the App Store and ZynSign does not sign with them."
                 : "Distribution facts are read from the profile's own declarations for inspection. ZynSign does not re-classify or re-issue them.")
        }
    }

    // MARK: - Compatibility and diagnostics

    private var compatibilitySection: some View {
        Section {
            if let report {
                ProfileCompatibilitySummaryView(report: report)
            } else {
                HStack(spacing: ZSpacing.xs) {
                    ProgressView()
                    Text("Evaluating compatibility…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Compatibility")
        } footer: {
            Text("Pre-sign checks against your current certificates and this app's context. Bundle ID shows “Not Checked” here because no app was selected — open an app's details to evaluate against it. These checks are not a trust or authenticity verdict; verification is a separate stage.")
        }
    }

    private var diagnosticsSection: some View {
        Section {
            if let report {
                ProfileDiagnosticsPanel(diagnostics: report.diagnostics)
            } else {
                Text("Diagnostics appear once compatibility is evaluated.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Each message names what was found and what to do about it.")
        }
    }

    // MARK: - Entitlements

    private var entitlementsSection: some View {
        Section {
            if current.entitlementsKeys.isEmpty {
                Text("The profile grants no entitlement keys.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(current.entitlementsKeys, id: \.self) { key in
                    Text(key)
                        .font(.footnote.monospaced())
                }
            }
        } header: {
            Text("Entitlements")
        } footer: {
            Text("The entitlement keys the profile declares. Signing derives the application's entitlements from this profile.")
        }
    }

    // MARK: - Quick actions

    private var quickActionsSection: some View {
        Section("Quick Actions") {
            if environment.profileSelections != nil {
                Button {
                    environment.profileSelections?.setPreferredProfile(current.id)
                    preferredProfileID = current.id
                    ZHaptics.tap()
                    showToast("“\(current.name)” selected for signing. Apps it suits will suggest it first.")
                } label: {
                    Label(
                        isPreferred ? "Selected for Signing" : "Use for Signing",
                        systemImage: isPreferred ? "checkmark.shield.fill" : "checkmark.shield"
                    )
                }
                .disabled(isPreferred)
            }
            if let team = current.teamIdentifier {
                Button {
                    UIPasteboard.general.string = team
                    showToast("Team ID copied.", style: .info)
                } label: {
                    Label("Copy Team ID", systemImage: "person.text.rectangle")
                }
            }
            if let bundle = copyableBundleIdentifier {
                Button {
                    UIPasteboard.general.string = bundle
                    showToast("Bundle ID copied.", style: .info)
                } label: {
                    Label("Copy Bundle ID", systemImage: "app.badge.checkmark")
                }
            }
            if let xml = entitlementsXML {
                Button {
                    UIPasteboard.general.string = xml
                    showToast("Entitlements XML copied.", style: .info)
                } label: {
                    Label("Copy Entitlements XML", systemImage: "doc.on.clipboard")
                }
                Button {
                    let out = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(current.name).entitlements")
                    try? Data(xml.utf8).write(to: out, options: .atomic)
                    shareEntitlementsURL = out
                } label: {
                    Label("Export .entitlements File", systemImage: "square.and.arrow.up")
                }
            }
            Button {
                Task { await refreshValidation() }
            } label: {
                Label(
                    isRefreshingValidation ? "Refreshing…" : "Refresh Validation",
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(isRefreshingValidation)
            Button(role: .destructive) {
                pendingRemoval = true
            } label: {
                Label("Delete Profile", systemImage: "trash")
            }
        }
    }

    // MARK: - Behaviour

    private var udidLookupSection: some View {
        Section {
            TextField("Paste Device UDID to Check…", text: $udidQuery)
                .font(ZTypography.codeCaption)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            let cleaned = udidQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                let matched = provisionedUDIDs.contains { $0.caseInsensitiveCompare(cleaned) == .orderedSame }
                ZStatusBadge(
                    matched ? "Device UDID Included" : "UDID Not in Profile",
                    systemImage: matched ? "checkmark.circle.fill" : "xmark.octagon.fill",
                    kind: matched ? .success : .error
                )
            }
            DisclosureGroup("Provisioned Devices (\(provisionedUDIDs.count))") {
                ForEach(provisionedUDIDs, id: \.self) { udid in
                    Text(udid)
                        .font(ZTypography.codeCaption)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Device UDID Verification")
        }
    }

    private func loadStoredProfileDetails() async {
        guard let bytes = try? await environment.provisioningProfiles?.profileBytes(withID: current.id) else {
            return
        }
        let inspected = CertificateBundleAssistant.inspectStoredProfileDetails(profileBytes: bytes)
        provisionedUDIDs = inspected.udids
        entitlementsXML = inspected.entitlementsXML
    }

    private var copyableBundleIdentifier: String? {
        if let bundle = current.bundleIdentifier { return bundle }
        if let pattern = current.bundleIdentifierPatterns.first { return pattern }
        return current.applicationIdentifier
    }

    /// Runs the Smart Compatibility Engine for the current profile and
    /// local certificates.
    private func evaluate() {
        guard let compatibility else {
            report = nil
            return
        }
        report = compatibility.evaluate(profile: current, targetBundleIdentifier: nil)
    }

    /// Re-reads the stored file through the importer, updates the library,
    /// re-evaluates compatibility, and tells the host to re-read.
    private func refreshValidation() async {
        guard let importer = environment.provisioningProfileImporter,
              let library = environment.provisioningProfiles else {
            notice = Notice(
                title: "Refresh Unavailable",
                message: "Profile re-validation is not part of this build's composition."
            )
            return
        }
        isRefreshingValidation = true
        defer { isRefreshingValidation = false }
        do {
            let refreshed = try await importer.refresh(current)
            try await library.upsert(refreshed)
            current = refreshed
            environment.recordAnalyticsEvent(category: .intake, name: "profile.refreshed", succeeded: true)
            evaluate()
            showToast("“\(refreshed.name)” re-read from its stored file.")
            onLibraryChanged?()
        } catch let error as ZynSignError {
            environment.recordAnalyticsEvent(category: .intake, name: "profile.refreshed", succeeded: false)
            notice = Notice(title: "Refresh Failed", message: error.userMessage)
        } catch {
            environment.recordAnalyticsEvent(category: .intake, name: "profile.refreshed", succeeded: false)
            notice = Notice(title: "Refresh Failed", message: "The profile could not be re-validated.")
        }
    }

    /// Removes the profile and its stored file, then leaves the screen.
    private func removeCurrent() async {
        guard let library = environment.provisioningProfiles else { return }
        do {
            try await library.remove(profileWithID: current.id)
            environment.recordAnalyticsEvent(category: .intake, name: "profile.removed", succeeded: true)
            onLibraryChanged?()
            dismiss()
        } catch {
            environment.recordAnalyticsEvent(category: .intake, name: "profile.removed", succeeded: false)
            notice = Notice(
                title: "Deletion Failed",
                message: (error as? ZynSignError)?.userMessage ?? "The profile could not be deleted."
            )
        }
    }

    private func showToast(_ message: String, style: ZToast.Style = .success) {
        toastMessage = message
        toastStyle = style
        isShowingToast = true
    }
}

// MARK: - Previews

#Preview("Profile Detail") {
    NavigationStack {
        ProfileDetailView(
            summary: ProvisioningProfileSummary(
                name: "Synthetic Profile",
                teamIdentifier: "TEAM123456",
                bundleIdentifierPatterns: ["com.example.synthetic"],
                expirationDate: Date().addingTimeInterval(60 * 86400),
                entitlementsKeys: ["application-identifier", "get-task-allow"],
                allowsDebug: true,
                sourceFileName: "sample.mobileprovision",
                importedAt: Date(),
                uuid: "12345678-1234-4ABC-8DEF-1234567890AB",
                teamName: "Synthetic Team",
                creationDate: Date().addingTimeInterval(-30 * 86400),
                profileType: .development,
                deviceCount: 2,
                applicationIdentifier: "TEAM123456.com.example.synthetic",
                bundleIdentifier: "com.example.synthetic",
                certificateFingerprints: []
            )
        )
    }
    .environment(\.applicationEnvironment, CompositionRoot.fallbackEnvironment)
}
