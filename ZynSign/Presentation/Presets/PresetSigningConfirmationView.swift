import SwiftUI
import UIKit

/// The final confirmation before a preset signs one app.
///
/// Opening this screen does not sign. The pipeline runs only after the
/// user taps Confirm and Sign, and only when preflight passed. The manual
/// wizard is a separate screen and remains available from the app.
struct PresetSigningConfirmationView: View {
    let entry: LibraryEntry
    let presetID: PresetIdentifier

    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var preset: SigningPreset?
    @State private var report: PresetCompatibilityReport?
    @State private var resolved: ResolvedPresetSigning?
    @State private var loadError: String?
    @State private var isSigning = false
    @State private var resultMessage: String?
    @State private var resultIsSuccess = false
    @State private var outputURL: URL?
    @State private var shareItem: PresetShareURL?
    @State private var deliveryPackage: InstallationDeliveryPackage?
    @StateObject private var liveActivity = LiveActivityService()

    var body: some View {
        NavigationStack {
            List {
                if let loadError, preset == nil {
                    Section {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                summarySection
                checksSection
                honestySection
                actionSection
                if let resultMessage {
                    Section("Result") {
                        Text(resultMessage)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                        if resultIsSuccess, let outputURL {
                            Text("Saved as \(outputURL.lastPathComponent) in Documents/Signed.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if let deliveryPackage, ReleaseTrain.isAvailable(.deliveryHandoff) {
                                NavigationLink {
                                    InstallationDeliveryView(package: deliveryPackage)
                                } label: {
                                    Label("Deliver…", systemImage: "tray.and.arrow.up")
                                }
                                .presetTouchTarget()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Confirm Signing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .task { await load() }
            .sheet(item: $shareItem) { item in
                PresetShareSheet(url: item.url)
            }
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        Section {
            LabeledContent("Application", value: entry.record.displayName ?? "Unnamed Application")
            LabeledContent("Identifier", value: entry.record.bundleIdentifier.rawValue)
            LabeledContent("Preset", value: preset?.name ?? "Loading")
            if let preset {
                LabeledContent("Certificate", value: resolved?.identity.displayName ?? "—")
                LabeledContent("Profile", value: resolved?.profile.name ?? preset.provisioningProfileName ?? "—")
                LabeledContent("Team", value: preset.teamIdentifier ?? resolved?.profile.teamIdentifier ?? "—")
                LabeledContent("Entitlements", value: preset.entitlementsSlot.displayName)
                LabeledContent("Verification", value: preset.verificationPreference.displayName)
                LabeledContent("After signing", value: preset.exportBehavior.displayName)
            }
        } header: {
            Text("Recommended Preset")
        } footer: {
            Text("Nothing is signed until you confirm. The signing pipeline still verifies the result. This does not replace the manual signing wizard.")
        }
    }

    @ViewBuilder
    private var checksSection: some View {
        if let report {
            Section {
                ForEach(report.checks) { check in
                    VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                        HStack {
                            Text(check.title)
                            Spacer()
                            ZStatusBadge(check.status.displayName, systemImage: check.symbolName, kind: PresetDisplay.checkKind(check.status))
                        }
                        Text(check.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(check.spoken)
                }
            } header: {
                Text("Compatibility")
            } footer: {
                Text(report.spokenSummary)
                    .accessibilityLabel(report.spokenSummary)
            }
        }
    }

    @ViewBuilder
    private var honestySection: some View {
        if let preset, preset.bundleIdentifierOverride != nil || preset.displayNameOverride != nil {
            Section {
                Text("A bundle identifier or display name override is saved on this preset. This signing run does not apply it. The application keeps the identifier and name it declared.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        Section {
            if report?.passesPreflight == true && resolved != nil && !resultIsSuccess {
                Button {
                    Task { await sign() }
                } label: {
                    HStack {
                        Spacer()
                        if isSigning {
                            ProgressView()
                            Text("Signing…")
                        } else {
                            Text("Confirm and Sign")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                    .presetTouchTarget()
                }
                .disabled(isSigning)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Signs this app with the recommended preset. This is the final confirmation.")
            } else if !resultIsSuccess {
                Text(loadError ?? "This preset does not pass preflight for this app, so Sign with Recommended Preset is not available. Use the signing wizard to choose a certificate and profile yourself.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func load() async {
        guard let workflow = environment.signingPresetWorkflow else {
            loadError = "Signing presets are not available."
            return
        }
        do {
            let stored = try await workflow.allPresets()
            guard let preset = stored.first(where: { $0.id == presetID }) else {
                loadError = "That signing preset is no longer available."
                return
            }
            self.preset = preset
            let app = PresetAppContext(
                bundleIdentifier: entry.record.bundleIdentifier.rawValue,
                displayName: entry.record.displayName
            )
            let report = try await workflow.compatibility(of: preset, for: app)
            self.report = report
            if report.passesPreflight {
                resolved = try await workflow.resolve(preset)
            }
            loadError = nil
        } catch let error as ZynSignError {
            loadError = error.userMessage
        } catch {
            loadError = "ZynSign could not prepare this preset."
        }
    }

    private func sign() async {
        guard let preset, let report, let resolved, let workflow = environment.signingPresetWorkflow else { return }
        let confirmation = PresetSignConfirmation(
            presetID: preset.id,
            bundleIdentifier: entry.record.bundleIdentifier.rawValue,
            passesPreflight: report.passesPreflight,
            acknowledged: true
        )
        do {
            try PresetSignConfirmationGate.validate(confirmation)
        } catch let error as ZynSignError {
            resultMessage = error.userMessage
            resultIsSuccess = false
            return
        } catch {
            resultMessage = "Confirm the preset summary before signing."
            resultIsSuccess = false
            return
        }
        let source = environment.artifactFileURL(for: entry.record.artifact.artifactID)
        guard FileManager.default.fileExists(atPath: source.path) else {
            resultMessage = "The package file is not available."
            resultIsSuccess = false
            return
        }
        isSigning = true
        defer { isSigning = false }
        await liveActivity.start(stage: "Signing", detail: preset.name)
        let entitlements: CodeSigningEntitlements
        do {
            entitlements = try SigningProfileEntitlementDerivation.derive(from: resolved.profileBytes)
        } catch {
            resultMessage = "The profile's entitlements could not be derived, so nothing was signed."
            resultIsSuccess = false
            await liveActivity.end(success: false)
            await record(workflow, preset: preset, result: .failed)
            return
        }
        let directory = SigningPresetWorkflow.signedOutputDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(SigningPresetWorkflow.outputName(for: entry))
        try? FileManager.default.removeItem(at: output)
        let request = SignApplicationRequest(
            sourceURL: source,
            profile: resolved.profileBytes,
            identityID: resolved.identity.id,
            entitlements: entitlements,
            outputURL: output,
            options: resolved.options
        )
        do {
            let signed = try await environment.signingPipeline.sign(request)
            if signed.status == .signed {
                outputURL = signed.outputURL ?? output
                resultIsSuccess = true
                resultMessage = "Signed with \(preset.name). Verification ran as part of the pipeline."
                await liveActivity.end(success: true)
                await record(workflow, preset: preset, result: .succeeded)
                await appendHistory(preset: preset, succeeded: true, output: outputURL)
                environment.recordAnalyticsEvent(category: .signing, name: "preset.sign.succeeded", succeeded: true)
                applyExport(preset: preset, url: outputURL ?? output)
                ZHaptics.success()
            } else {
                resultIsSuccess = false
                resultMessage = signed.failure?.detail ?? "Signing was refused. Nothing was delivered."
                await liveActivity.end(success: false)
                await record(workflow, preset: preset, result: .failed)
                await appendHistory(preset: preset, succeeded: false, output: nil)
                environment.recordAnalyticsEvent(category: .signing, name: "preset.sign.refused", succeeded: false)
                ZHaptics.warning()
            }
        } catch is CancellationError {
            resultMessage = "Signing was cancelled."
            resultIsSuccess = false
            try? FileManager.default.removeItem(at: output)
            await liveActivity.end(success: false)
            await record(workflow, preset: preset, result: .cancelled)
        } catch let error as ZynSignError {
            resultMessage = error.userMessage
            resultIsSuccess = false
            try? FileManager.default.removeItem(at: output)
            await liveActivity.end(success: false)
            await record(workflow, preset: preset, result: .failed)
            environment.recordAnalyticsEvent(category: .signing, name: "preset.sign.failed", succeeded: false)
        } catch {
            resultMessage = "Signing failed unexpectedly."
            resultIsSuccess = false
            try? FileManager.default.removeItem(at: output)
            await liveActivity.end(success: false)
            await record(workflow, preset: preset, result: .failed)
        }
    }

    private func record(_ workflow: SigningPresetWorkflow, preset: SigningPreset, result: PresetUseOutcome.Result) async {
        let outcome = PresetUseOutcome(
            presetID: preset.id,
            result: result,
            bundleIdentifier: entry.record.bundleIdentifier.rawValue,
            displayName: entry.record.displayName,
            at: Date()
        )
        try? await workflow.record(outcome)
    }

    private func appendHistory(preset: SigningPreset, succeeded: Bool, output: URL?) async {
        guard let history = environment.signingHistory else { return }
        let record = SigningRecord(
            presetID: preset.id,
            certificateFingerprint: preset.certificateFingerprint,
            sourceBundleIdentifier: entry.record.bundleIdentifier.rawValue,
            sourceDisplayName: entry.record.displayName,
            stoppingStage: succeeded ? "verification" : "signing",
            errorCode: succeeded ? nil : "refused",
            outputFileName: succeeded ? output?.lastPathComponent : nil,
            outputByteCount: nil,
            startedAt: Date(),
            duration: 0
        )
        try? await history.append(record)
    }

    private func applyExport(preset: SigningPreset, url: URL) {
        switch preset.exportBehavior {
        case .keepInSignedFolder:
            break
        case .promptToShare:
            shareItem = PresetShareURL(url: url)
        case .promptToDeliver:
            if ReleaseTrain.isAvailable(.deliveryHandoff) {
                deliveryPackage = InstallationDeliveryPackage(signedIPA: url, record: entry.record)
            } else {
                shareItem = PresetShareURL(url: url)
            }
        }
    }
}

private struct PresetShareURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct PresetShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
