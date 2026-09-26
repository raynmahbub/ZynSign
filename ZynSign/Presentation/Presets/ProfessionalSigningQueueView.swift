import SwiftUI

/// Bulk signing against one preset.
///
/// Compatible apps are listed separately from apps that need manual
/// attention. Queueing requires a confirmation, and the queue refuses to
/// run the attention set. The manual wizard is unchanged.
struct ProfessionalSigningQueueView: View {
    var lockedEntries: [LibraryEntry]? = nil
    var lockedPresetID: PresetIdentifier? = nil

    @Environment(\.applicationEnvironment) private var environment

    var body: some View {
        if let queue = environment.professionalSigningQueue {
            ProfessionalSigningQueueScreen(
                queue: queue,
                lockedEntries: lockedEntries,
                lockedPresetID: lockedPresetID
            )
        } else {
            ContentUnavailableView(
                "Signing Queue Unavailable",
                systemImage: "list.bullet.rectangle",
                description: Text("The signing queue is not available.")
            )
        }
    }
}

private struct ProfessionalSigningQueueScreen: View {
    @ObservedObject var queue: ProfessionalSigningQueue
    var lockedEntries: [LibraryEntry]?
    var lockedPresetID: PresetIdentifier?

    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var presets: [SigningPreset] = []
    @State private var entries: [LibraryEntry] = []
    @State private var selectedPresetID: PresetIdentifier?
    @State private var selectedIDs: Set<String> = []
    @State private var plan: PresetBulkPlan?
    @State private var showConfirm = false
    @State private var errorMessage: String?
    @State private var isPreparing = false

    var body: some View {
        NavigationStack {
            List {
                if queue.phase == .running || queue.phase == .finished {
                    progress(queue)
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
            .navigationTitle("Signing Queue")
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
            Text("Incompatible apps are shown and are not signed. Nothing is queued until you confirm.")
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
                .accessibilityLabel("\(item.displayName), \(item.bundleIdentifier), compatible. Will be signed after confirmation.")
            }
        } header: {
            Text("Will be signed (\(plan.compatible.count))")
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
                .accessibilityLabel("\(item.displayName) needs manual attention. \(item.reasons.joined(separator: " ")) This app will not be signed.")
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
                Text("Queue Compatible Apps")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(plan.compatible.isEmpty || isPreparing)
            .keyboardShortcut(.defaultAction)
            .accessibilityHint("Asks you to confirm before signing \(plan.compatible.count) compatible apps. \(plan.needsAttention.count) apps that need manual attention will not be signed.")
        }
    }

    @ViewBuilder
    private func progress(_ queue: ProfessionalSigningQueue) -> some View {
        Section {
            if queue.phase == .running {
                HStack {
                    ProgressView()
                    Text("Signing compatible apps")
                }
                .accessibilityElement(children: .combine)
            }
            ForEach(queue.jobs) { job in
                VStack(alignment: .leading, spacing: ZSpacing.xxs) {
                    Text(job.displayName)
                    Text(job.bundleIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    jobBadge(job)
                    if case .needsAttention(let reasons) = job.state {
                        ForEach(reasons, id: \.self) { reason in
                            Text(reason)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if case .failed(let message) = job.state {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(jobSpoken(job))
            }
            if queue.phase == .running {
                Button("Cancel Remaining", role: .destructive) {
                    queue.cancelRemaining()
                }
                .presetTouchTarget()
            }
            if queue.phase == .finished {
                Button("Done") { dismiss() }
                    .presetTouchTarget()
                    .keyboardShortcut(.defaultAction)
            }
        } header: {
            Text(queue.presetName.map { "Queue · \($0)" } ?? "Queue")
        } footer: {
            Text("Apps that need manual attention stay in that state. They are not signed by this queue.")
        }
    }

    @ViewBuilder
    private func jobBadge(_ job: ProfessionalSigningQueue.Job) -> some View {
        switch job.state {
        case .waiting:
            ZStatusBadge("Waiting", systemImage: "clock", kind: .neutral)
        case .needsAttention:
            ZStatusBadge("Needs manual attention", systemImage: "exclamationmark.triangle", kind: .warning)
        case .running:
            ZStatusBadge("Signing", systemImage: "signature", kind: .info)
        case .succeeded:
            ZStatusBadge("Signed", systemImage: "checkmark", kind: .success)
        case .failed:
            ZStatusBadge("Failed", systemImage: "xmark", kind: .error)
        case .cancelled:
            ZStatusBadge("Cancelled", systemImage: "xmark.circle", kind: .neutral)
        }
    }

    private func jobSpoken(_ job: ProfessionalSigningQueue.Job) -> String {
        switch job.state {
        case .waiting:
            return "\(job.displayName), waiting."
        case .needsAttention(let reasons):
            return "\(job.displayName), needs manual attention. \(reasons.joined(separator: " "))"
        case .running:
            return "\(job.displayName), signing."
        case .succeeded(let name):
            return "\(job.displayName), signed. \(name)."
        case .failed(let message):
            return "\(job.displayName), failed. \(message)"
        case .cancelled:
            return "\(job.displayName), cancelled."
        }
    }

    private var confirmTitle: String {
        let count = plan?.compatible.count ?? 0
        return "Sign \(count) compatible app\(count == 1 ? "" : "s")?"
    }

    private var confirmButtonTitle: String { "Confirm and Sign" }

    private var confirmMessage: String {
        let attention = plan?.needsAttention.count ?? 0
        if attention == 0 {
            return "Each compatible app still goes through the signing pipeline, including verification. Nothing is signed until you confirm."
        }
        return "\(attention) app\(attention == 1 ? "" : "s") need manual attention and will not be signed. Nothing is signed until you confirm."
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
        if queue.phase == .finished {
            queue.reset()
        }
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
        guard let workflow = environment.signingPresetWorkflow,
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
        do {
            let directory = SigningPresetWorkflow.signedOutputDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let requests = try await workflow.executionRequests(for: plan, entries: chosen, outputDirectory: directory)
            try queue.stage(plan: plan, requests: requests)
            await queue.confirmAndStart()
            ZHaptics.success()
        } catch let error as ZynSignError {
            errorMessage = error.userMessage
            ZHaptics.warning()
        } catch {
            errorMessage = "The compatible apps could not be queued."
        }
    }
}
