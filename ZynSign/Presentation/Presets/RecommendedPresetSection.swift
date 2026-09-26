import SwiftUI

/// The offer shown when an app is opened. A compatible preset is named.
/// It is not signed until the confirmation screen's final button is used.
struct RecommendedPresetSection: View {
    let entry: LibraryEntry

    @Environment(\.applicationEnvironment) private var environment
    @State private var match: PresetMatch?
    @State private var looked = false
    @State private var showConfirmation = false

    var body: some View {
        if ReleaseTrain.isAvailable(.signingPresets) {
            Section {
                if !looked {
                    ZSkeleton(rows: 2)
                } else if let match, match.report.passesPreflight {
                    VStack(alignment: .leading, spacing: ZSpacing.xs) {
                        Text(match.preset.name)
                            .font(.headline)
                        Text(match.reasons.prefix(3).joined(separator: " "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ZStatusBadge(match.report.overall.displayName, systemImage: "checkmark.seal", kind: PresetDisplay.badgeKind(for: match.report.overall))
                        Button {
                            ZHaptics.tap()
                            showConfirmation = true
                        } label: {
                            Text("Sign with Recommended Preset")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint("Opens the confirmation summary. Nothing is signed until you confirm there.")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Recommended Preset. \(match.report.spokenSummary)")
                } else {
                    Text("No preset passes preflight for this app. The signing wizard is still available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Recommended Preset")
            }
            .task { await load() }
            .sheet(isPresented: $showConfirmation) {
                if let match {
                    PresetSigningConfirmationView(entry: entry, presetID: match.preset.id)
                }
            }
        }
    }

    private func load() async {
        guard let workflow = environment.signingPresetWorkflow else {
            looked = true
            return
        }
        let app = PresetAppContext(
            bundleIdentifier: entry.record.bundleIdentifier.rawValue,
            displayName: entry.record.displayName
        )
        match = try? await workflow.recommendation(for: app)
        looked = true
    }
}

/// Shown under an accepted import when a preset passes preflight.
struct ImportReadyToSignOffer: View {
    let record: ApplicationRecord

    @Environment(\.applicationEnvironment) private var environment
    @State private var readiness: ImportSigningReadiness?
    @State private var entry: LibraryEntry?
    @State private var showConfirmation = false

    var body: some View {
        Group {
            if ReleaseTrain.isAvailable(.signingPresets), let readiness, readiness.isReadyToSign, let entry {
                VStack(alignment: .leading, spacing: ZSpacing.xs) {
                    Text(readiness.title)
                        .font(.subheadline.weight(.semibold))
                    Text(readiness.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        ZHaptics.tap()
                        showConfirmation = true
                    } label: {
                        Text("Ready to Sign")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Opens confirmation for \(readiness.recommendation?.preset.name ?? "the matching preset"). Nothing is signed until you confirm.")
                }
                .padding(.vertical, ZSpacing.xxs)
                .accessibilityElement(children: .contain)
                .sheet(isPresented: $showConfirmation) {
                    if let match = readiness.recommendation {
                        PresetSigningConfirmationView(entry: entry, presetID: match.preset.id)
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard ReleaseTrain.isAvailable(.signingPresets),
              let workflow = environment.signingPresetWorkflow else { return }
        let app = PresetAppContext(
            bundleIdentifier: record.bundleIdentifier.rawValue,
            displayName: record.displayName
        )
        readiness = try? await workflow.importReadiness(for: app)
        entry = try? await environment.library.entry(withID: record.id)
    }
}
