import SwiftUI
import UIKit

/// Shared, explicitly historical summary: never implies a cached pass still
/// applies after a certificate, profile, input or exported file changes.
struct ReleaseReadinessLink: View {
    var recordID: ApplicationRecordIdentifier? = nil
    var exportID: ExportIdentifier? = nil
    @Environment(\.applicationEnvironment) private var environment
    @State private var latest: ReleaseReadinessReport?

    var body: some View {
        NavigationLink {
            ReleaseReadinessView(recordID: recordID, exportID: exportID)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label("Release Readiness Center", systemImage: "checklist")
                Text(latest.map { "Last report: \($0.status) · \($0.score)/100 — rescan to confirm" }
                     ?? "Not validated · Check inputs and the produced IPA")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(minHeight: 44, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
        .task {
            guard let service = environment.releaseReadiness else { return }
            latest = try? await service.history.reports().first {
                (recordID == nil || $0.recordID == recordID?.rawValue)
                    && (exportID == nil || $0.exportID == exportID?.rawValue)
            }
        }
    }
}

@MainActor
struct ReleaseReadinessView: View {
    var recordID: ApplicationRecordIdentifier? = nil
    var exportID: ExportIdentifier? = nil
    @Environment(\.applicationEnvironment) private var environment
    @State private var entries: [LibraryEntry] = []
    @State private var identities: [SigningIdentity] = []
    @State private var profiles: [ProvisioningProfileSummary] = []
    @State private var exports: [ExportEntry] = []
    @State private var appSelection = ""
    @State private var identitySelection = ""
    @State private var profileSelection = ""
    @State private var exportSelection = ""
    @State private var reports: [ReleaseReadinessReport] = []
    @State private var report: ReleaseReadinessReport?
    @State private var notice: String?
    @State private var isRunning = false
    @State private var isLoading = true
    @State private var validationTask: Task<Void, Never>?

    private var matchingExports: [ExportEntry] {
        exports.filter { $0.record.sourceRecordIdentifier == appSelection }
    }
    private var appHistory: [ReleaseReadinessReport] {
        reports.filter { $0.recordID == appSelection }
    }
    var body: some View {
        List {
            Section {
                Text("Final Alpha Gate").font(.title2.bold())
                Text("Validate selected signing inputs and a produced IPA independently. No signing or package changes are made.")
                Text(ReleaseReadinessReport.boundary).font(.footnote).foregroundStyle(.secondary)
            }
            selectionSection
            Section {
                Button { run() } label: {
                    Label("Run Full Validation", systemImage: "checkmark.shield")
                        .frame(minHeight: 44)
                }
                .disabled(isRunning || isLoading || appSelection.isEmpty || environment.releaseReadiness == nil)
                if isRunning {
                    ProgressView("Validating inputs, package and executable signatures…")
                    Button("Cancel validation", role: .cancel) { validationTask?.cancel() }
                        .frame(minHeight: 44)
                }
                if let notice { Text(notice).foregroundStyle(.secondary) }
            } footer: {
                Text("Full validation rereads input and output bytes. A saved report is a historical observation, not a reusable release approval.")
            }
            if let report {
                Section("Latest completed validation") {
                    NavigationLink { ReleaseReadinessReportView(report: report) } label: {
                        VStack(alignment: .leading) {
                            Text(report.summary)
                            Text(report.validatedAt, style: .date).font(.caption)
                        }
                    }
                }
                ReadinessDashboardSections(report: report)
            }
            Section("Validation History") {
                Text("\(appHistory.filter { $0.status == "Ready" }.count) ready reports · up to 10 retained per app")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(appHistory) { snapshot in
                    NavigationLink { ReleaseReadinessReportView(report: snapshot) } label: {
                        VStack(alignment: .leading) {
                            Text(snapshot.summary)
                            Text(snapshot.validatedAt, format: .dateTime.year().month().day().hour().minute().second())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if appHistory.isEmpty { Text("No stored validations for this app.") }
            }
        }
        .navigationTitle("Release Readiness")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onDisappear { validationTask?.cancel() }
        .onChange(of: appSelection) { _, _ in
            if !matchingExports.contains(where: { $0.record.id.rawValue == exportSelection }) { exportSelection = "" }
            report = nil
        }
        .onChange(of: identitySelection) { _, _ in report = nil }
        .onChange(of: profileSelection) { _, _ in report = nil }
        .onChange(of: exportSelection) { _, _ in report = nil }
    }

    private var selectionSection: some View {
        Section("Validation inputs") {
            Picker("App", selection: $appSelection) {
                Text("Select an app").tag("")
                ForEach(entries, id: \.record.id) { entry in
                    Text(entry.record.displayName ?? "Application").tag(entry.record.id.rawValue)
                }
            }
            Picker("Signing identity", selection: $identitySelection) {
                Text("None selected").tag("")
                ForEach(identities, id: \.id) { identity in
                    Text(identity.displayName).tag(identity.id.rawValue)
                }
            }
            Picker("Provisioning profile", selection: $profileSelection) {
                Text("None selected").tag("")
                ForEach(profiles) { profile in Text(profile.name).tag(profile.id.rawValue) }
            }
            Picker("Produced IPA", selection: $exportSelection) {
                Text("None selected").tag("")
                ForEach(matchingExports, id: \.record.id) { entry in
                    Text(entry.record.fileName).tag(entry.record.id.rawValue)
                }
            }
            Text("Select the identity and profile to evaluate. Export checks describe the IPA's embedded data, not an assumption that it uses these selections.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .disabled(isRunning || isLoading)
    }

    private func load() async {
        defer { isLoading = false }
        do {
            entries = try await environment.library.entries()
            exports = try await environment.exportCenter.entries()
            identities = try environment.identityStore.listIdentities()
            if identitySelection.isEmpty,
               let fingerprint = try environment.identityAnnotations?.defaultIdentityFingerprint(),
               let identity = identities.first(where: { $0.fingerprint.hexDigest == fingerprint }) {
                identitySelection = identity.id.rawValue
            }
            profiles = try await environment.provisioningProfiles?.allProfiles() ?? []
            if appSelection.isEmpty { appSelection = recordID?.rawValue ?? "" }
            // An explicit output selection is offered, not silently replaced
            // with the newest artifact of a different signing configuration.
            if let exportID { exportSelection = exportID.rawValue }
            if let service = environment.releaseReadiness {
                do { reports = try await service.history.reports() }
                catch { notice = "Validation history could not be read. New checks are still available." }
            } else { notice = "Release validation is unavailable in this composition." }
        } catch { notice = "Validation inputs could not be loaded. Reopen this screen to retry." }
    }

    private func run() {
        guard let service = environment.releaseReadiness,
              let id = ApplicationRecordIdentifier(rawValue: appSelection), !isRunning else { return }
        isRunning = true
        report = nil
        notice = nil
        validationTask = Task {
            defer { isRunning = false }
            do {
                let profileBytes: Data?
                if profileSelection.isEmpty { profileBytes = nil }
                else {
                    profileBytes = try await environment.provisioningProfiles?.profileBytes(
                        withID: ProvisioningProfileIdentifier(rawValue: profileSelection))
                }
                // Read the default and identity inventory again at validation
                // time, not from the picker snapshot taken when this opened.
                let current = try environment.identityStore.listIdentities()
                let fingerprint = try environment.identityAnnotations?.defaultIdentityFingerprint()
                let date = Date()
                let healthyDefault = current.contains {
                    $0.fingerprint.hexDigest == fingerprint && $0.isUsableForSigning
                        && $0.certificate.notValidBefore <= date && $0.certificate.notValidAfter >= date
                }
                let result = try await service.validate(recordID: id,
                    identityID: SigningIdentityIdentifier(rawValue: identitySelection),
                    profileData: profileBytes,
                    exportID: exportSelection.isEmpty ? nil : ExportIdentifier(rawValue: exportSelection),
                    defaultIdentityAvailable: healthyDefault)
                try Task.checkCancellation()
                report = result.report
                if result.historyUnavailable { notice = "Validation completed, but history could not be saved. Export the report to keep it." }
                reports = (try? await service.history.reports()) ?? reports
                UIAccessibility.post(notification: .announcement, argument: result.report.summary)
            } catch is CancellationError {
                notice = "Validation cancelled. No partial result is marked ready."
            } catch {
                notice = "Validation could not complete. Confirm that the app, identity, profile and exported IPA are still available, then retry."
            }
        }
    }
}

struct ReleaseReadinessReportView: View {
    let report: ReleaseReadinessReport
    var body: some View {
        List {
            Section {
                Text("Read-only historical report").font(.headline)
                Text("App record: \(report.recordID)").font(.caption).textSelection(.enabled)
                Text("Export: \(report.exportID ?? "None selected")").font(.caption)
                Text(ReleaseReadinessReport.boundary).font(.footnote)
                ShareLink(item: report.plainText) {
                    Label("Export Validation Report", systemImage: "square.and.arrow.up").frame(minHeight: 44)
                }
            }
            ReadinessDashboardSections(report: report)
        }
        .navigationTitle("Validation Report")
    }
}

/// List/DisclosureGroup defer detailed rendering; no large executable data
/// is retained by a report view. Text and symbols supplement semantic colors.
private struct ReadinessDashboardSections: View {
    let report: ReleaseReadinessReport
    var body: some View {
        Section("Readiness Dashboard") {
            Text(report.summary).font(.headline).accessibilityLabel(report.summary)
            LabeledContent("Last validation") {
                Text(report.validatedAt, format: .dateTime.year().month().day().hour().minute())
            }
            Text("\(report.successfulCount) verified checks · \(report.information.count) informational / inconclusive checks")
            overviewRow("Structure", categories: [.structure])
            overviewRow("Signature", categories: [.signature])
            overviewRow("Security", categories: [.identity, .profile, .signature])
            overviewRow("Compatibility", categories: [.profile, .entitlements, .signature])
            overviewRow("Packaging", categories: [.package])
            overviewRow("Verification", categories: [.signature, .package])
        }
        Section("Score Breakdown") {
            ForEach(ReleaseReadinessCategory.allCases) { category in
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(category.title): \(report.state(for: category).title)",
                          systemImage: symbol(report.state(for: category)))
                    Text("\(report.points(for: category))/\(category.weight) points · deduction \(category.weight - report.points(for: category))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Text("Each category takes its least conclusive result. Verified earns full weight, warnings earn half (rounded down), and blocked, unsupported or unchecked earn zero. Warnings never block progress. Every deduction is explained below.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        issueSection("Blocking Issue Center", checks: report.blockers)
        issueSection("Warning Center", checks: report.warnings)
        issueSection("Informational & Unsupported Checks", checks: report.information)
        issueSection("Verified Checks", checks: report.checks.filter { $0.state == .verified })
    }
    private func overviewRow(_ title: String, categories: [ReleaseReadinessCategory]) -> some View {
        let state = categories.map { report.state(for: $0) }.max { $0.rank < $1.rank } ?? .notChecked
        return Label("\(title): \(state.title)", systemImage: symbol(state))
            .accessibilityElement(children: .combine)
    }
    private func issueSection(_ title: String, checks: [ReleaseReadinessCheck]) -> some View {
        Section(title) {
            if checks.isEmpty { Text("None") }
            ForEach(checks) { check in
                DisclosureGroup {
                    Text(check.explanation)
                    Text(check.technicalDetails).font(.footnote).foregroundStyle(.secondary)
                    Text("Next: \(check.nextAction)").font(.callout)
                } label: {
                    Label(check.title, systemImage: symbol(check.state)).frame(minHeight: 44)
                }
            }
        }
    }
    private func symbol(_ state: ReleaseCheckState) -> String {
        switch state {
        case .verified: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .blocked: return "xmark.octagon"
        case .unsupported, .notChecked: return "questionmark.circle"
        }
    }
}
