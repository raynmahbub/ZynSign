import SwiftUI

/// The final confirmation before a preset is queued for one app.
///
/// Opening this screen does not sign and does not enqueue. The Signing
/// Queue receives the job only after the user taps Confirm and Sign, the
/// app lock allows it, and preflight passed. The manual wizard remains
/// available. Usage counts update when the queue settles the job.
struct PresetSigningConfirmationView: View {
    let entry: LibraryEntry
    let presetID: PresetIdentifier
    var origin: SigningJobOrigin = .signingScreen

    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.signingQueuePresentation) private var signingQueuePresentation
    @Environment(\.appLock) private var appLock
    @Environment(\.dismiss) private var dismiss
    @State private var preset: SigningPreset?
    @State private var report: PresetCompatibilityReport?
    @State private var resolved: ResolvedPresetSigning?
    @State private var loadError: String?
    @State private var isSigning = false
    @State private var resultMessage: String?
    @State private var resultIsSuccess = false

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
                        if resultIsSuccess && signingQueuePresentation.isAvailable {
                            Button {
                                signingQueuePresentation.present()
                            } label: {
                                Label("Open Signing Queue", systemImage: "tray.full")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .presetTouchTarget()
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
            Text("Nothing is signed until you confirm. Confirming adds one job to the Signing Queue, which runs the same pipeline, including verification. This does not replace the manual signing wizard.")
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
                            Text("Adding to Queue…")
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
                .accessibilityHint("Adds this app to the Signing Queue with the recommended preset. This is the final confirmation. Nothing is signed on this screen.")
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
        let authorization = await appLock.authorize(.sign)
        guard authorization.isAuthenticated else {
            resultMessage = authorization.message
            resultIsSuccess = false
            return
        }
        let submission = workflow.submission(for: entry, resolved: resolved)
        environment.signingQueue.enqueue(submission, priority: .normal, origin: origin)
        resultIsSuccess = true
        resultMessage = "Added to the Signing Queue with \(preset.name). Signing and verification run there. This screen did not sign the app."
        environment.recordAnalyticsEvent(category: .signing, name: "queue.job.enqueued", succeeded: true)
        ZHaptics.success()
    }
}
