import SwiftUI

/// Bulk planning against one preset.
///
/// Compatible apps are listed separately from apps that need manual
/// attention. Queueing requires a confirmation and the app lock. Only
/// compatible apps are added to `SigningQueue`. Incompatible apps are not
/// forced through. The manual wizard is unchanged.
struct ProfessionalSigningQueueView: View {
    var lockedEntries: [LibraryEntry]? = nil
    var lockedPresetID: PresetIdentifier? = nil

    @Environment(\.applicationEnvironment) private var environment

    var body: some View {
        if environment.signingPresetWorkflow == nil {
            ContentUnavailableView(
                "Signing Presets Unavailable",
                systemImage: "rectangle.stack",
                description: Text("Signing presets are not available.")
            )
        } else {
            ProfessionalSigningQueueScreen(
                lockedEntries: lockedEntries,
                lockedPresetID: lockedPresetID
            )
        }
    }
}

private struct ProfessionalSigningQueueScreen: View {
    var lockedEntries: [LibraryEntry]?
    var lockedPresetID: PresetIdentifier?

    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.signingQueuePresentation) private var signingQueuePresentation
    @Environment(\.appLock) private var appLock
    @Environment(\.dismiss) private var dismiss
    @State private var presets: [SigningPreset] = []
    @State private var entries: [LibraryEntry] = []
    @State private var selectedPresetID: PresetIdentifier?
    @State private var selectedIDs: Set<String> = []
    @State private var plan: PresetBulkPlan?
    @State private var showConfirm = false
    @State private var errorMessage: String?
    @State private var isPreparing = false
    @State private var queuedCount: Int?

    var body: some View {
        NavigationStack {
            List {
                if let queuedCount {
                    queuedSection(queuedCount)
                } else {
                    planner
                    if let plan {
                        planSections(plan)
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .navigationTitle("Sign with Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .task { await load() }
            .onChange(of: selectedPresetID) { _, _ in Task { await refreshPlan() } }
            .onChange(of: selectedIDs) { _, _ in Task { await refreshPlan() } }
            .confirmationDialog(
                confirmTitle,
                isPresented: $showConfirm,
                titleVisibility: .visible
            ) {
                Button(confirmButtonTitle) {
                    Task { await startQueue() }
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(confirmMessage)
            }
        }
    }

    @ViewBuilder
    private var planner: some View {
        Section {
            if lockedPresetID == nil {
                Picker("Preset", selection: $selectedPresetID) {
                    Text("Choose a preset").tag(Optional<PresetIdentifier>.none)
                    ForEach(presets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }
                .accessibilityLabel("Signing preset")
            } else if let preset = presets.first(where: { $0.id == lockedPresetID }) {
                LabeledContent("Preset", value: preset.name)
            }
        } header: {
            Text("Preset")
        } footer: {
            Text("Incompatible apps are shown and are not queued. Nothing is queued until you confirm.")
        }

        if lockedEntries == nil {
            Section("Applications") {
                if entries.isEmpty {
                    Text("The library has no applications to queue.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(entries, id: \.record.id) { entry in
                    Button {
                        toggle(entry)
                    } label: {
                        HStack {
                            Image(systemName: selectedIDs.contains(entry.record.id.rawValue) ? "checkmark.circle.fill" : "circle")
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.record.displayName ?? "Unnamed Application")
                                Text(entry.record.bundleIdentifier.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .presetTouchTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(entry.record.displayName ?? entry.record.bundleIdentifier.rawValue)
                    .accessibilityValue(selectedIDs.contains(entry.record.id.rawValue) ? "Selected" : "Not selected")
                    .accessibilityAddTraits(.isButton)
                }
            }
        }
    }

    @ViewBuilder
    private func planSections(_ plan: PresetBulkPlan) -> some View {
        Section {
            if plan.compatible.isEmpty {
                Text("No selected app passes preflight with this preset.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(plan.compatible) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                    Text(item.bundleIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ZStatusBadge("Compatible", systemImage: "checkmark", kind: .success)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.displayName), \(item.bundleIdentifier), compatible. Will be added to the Signing Queue after confirmation.")
            }
        } header: {
            Text("Will be queued (\(plan.compatible.count))")
        }

        Section {
            if plan.needsAttention.isEmpty {
                Text("Every selected app is compatible.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(plan.needsAttention) { item in
                VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                    Text(item.displayName)
                    Text(item.bundleIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ZStatusBadge("Needs manual attention", systemImage: "exclamationmark.triangle", kind: .warning)
                    ForEach(item.reasons, id: \.self) { reason in
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.displayName) needs manual attention. \(item.reasons.joined(separator: " ")) This app will not be queued.")
            }
        } header: {
            Text("Needs manual attention (\(plan.needsAttention.count))")
        } footer: {
            Text("These apps are not queued. Open each one and use the signing wizard. ZynSign will not force them through this preset.")
        }

        Section {
            Button {
                showConfirm = true
            } label: {
                Text(isPreparing ? "Adding to Queue…" : "Queue Compatible Apps")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(plan.compatible.isEmpty || isPreparing)
            .keyboardShortcut(.defaultAction)
            .accessibilityHint("Asks you to confirm before adding \(plan.compatible.count) compatible apps to the Signing Queue. \(plan.needsAttention.count) apps that need manual attention will not be queued.")
        }
    }

    @ViewBuilder
    private func queuedSection(_ count: Int) -> some View {
        Section {
            Text("Added \(count) compatible app\(count == 1 ? "" : "s") to the Signing Queue. Apps that need manual attention were not queued.")
                .fixedSize(horizontal: false, vertical: true)
            if signingQueuePresentation.isAvailable {
                Button {
                    signingQueuePresentation.present()
                } label: {
                    Label("Open Signing Queue", systemImage: "tray.full")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .presetTouchTarget()
            }
            Button("Done") { dismiss() }
                .presetTouchTarget()
                .keyboardShortcut(.defaultAction)
        } header: {
            Text("Queued")
        }
    }

    private var confirmTitle: String {
        let count = plan?.compatible.count ?? 0
        return "Queue \(count) compatible app\(count == 1 ? "" : "s")?"
    }

    private var confirmButtonTitle: String { "Confirm and Queue" }

    private var confirmMessage: String {
        let attention = plan?.needsAttention.count ?? 0
        if attention == 0 {
            return "Each compatible app is added to the Signing Queue, which verifies the result. Nothing is queued until you confirm."
        }
        return "\(attention) app\(attention == 1 ? "" : "s") need manual attention and will not be queued. Nothing is queued until you confirm."
    }

    private func toggle(_ entry: LibraryEntry) {
        ZHaptics.tap()
        let id = entry.record.id.rawValue
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func load() async {
        guard let workflow = environment.signingPresetWorkflow else { return }
        presets = (try? await workflow.allPresets()) ?? []
        if let lockedEntries {
            entries = lockedEntries
            selectedIDs = Set(lockedEntries.map { $0.record.id.rawValue })
        } else {
            entries = (try? await environment.library.entries()) ?? []
        }
        selectedPresetID = lockedPresetID ?? presets.first(where: \.isDefault)?.id ?? presets.first?.id
        await refreshPlan()
    }

    private func refreshPlan() async {
        guard queuedCount == nil,
              let workflow = environment.signingPresetWorkflow,
              let presetID = selectedPresetID,
              let preset = presets.first(where: { $0.id == presetID }) else {
            plan = nil
            return
        }
        let chosen = entries.filter { selectedIDs.contains($0.record.id.rawValue) }
        guard !chosen.isEmpty else {
            plan = nil
            return
        }
        plan = try? await workflow.bulkPlan(preset: preset, subjects: chosen.map { $0.presetSubject() })
    }

    private func startQueue() async {
        guard let workflow = environment.signingPresetWorkflow,
              let plan else { return }
        let chosen = entries.filter { selectedIDs.contains($0.record.id.rawValue) }
        isPreparing = true
        defer { isPreparing = false }
        let authorization = await appLock.authorize(.sign)
        guard authorization.isAuthenticated else {
            errorMessage = authorization.message
            return
        }
        do {
            let submissions = try await workflow.queueSubmissions(for: plan, entries: chosen)
            let allowed = Set(plan.compatible.map(\.id)).subtracting(plan.needsAttention.map(\.id))
            guard submissions.allSatisfy({ allowed.contains($0.recordID.rawValue) }) else {
                throw ZynSignError.presetQueueRefusedIncompatible()
            }
            guard !submissions.isEmpty else {
                errorMessage = "No compatible app could be queued."
                return
            }
            environment.signingQueue.enqueue(submissions, priority: .normal, origin: .bulkSelection)
            environment.recordAnalyticsEvent(category: .signing, name: "queue.job.enqueued", succeeded: true)
            queuedCount = submissions.count
            errorMessage = nil
            ZHaptics.success()
        } catch let error as ZynSignError {
            errorMessage = error.userMessage
            ZHaptics.warning()
        } catch {
            errorMessage = "The compatible apps could not be queued."
        }
    }
}
