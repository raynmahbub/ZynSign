import SwiftUI

/// The preset library. Each card shows the references a preset stores and
/// its current health. Actions match the context menu. Nothing on this
/// screen signs an app by itself.
struct PresetsView: View {
    /// When this view is already inside a navigation stack, the compact
    /// layout should not wrap itself in a second one.
    var embedsNavigationStack: Bool = true

    @Environment(\.horizontalSizeClass) private var sizeClass
    @StateObject private var model = PresetLibraryModel()
    @Environment(\.applicationEnvironment) private var environment

    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    library
                } detail: {
                    if let id = model.selectedID {
                        PresetDetailView(presetID: id, model: model)
                    } else {
                        ContentUnavailableView(
                            "Select a Preset",
                            systemImage: "rectangle.stack",
                            description: Text("Choose a preset to see its compatibility, history, and actions.")
                        )
                    }
                }
            } else if embedsNavigationStack {
                NavigationStack {
                    compactLibrary
                }
            } else {
                compactLibrary
            }
        }
        .task { await model.load(using: environment) }
        .sheet(item: $model.builder) { route in
            PresetBuilderView(existing: route.existing, template: route.template) {
                Task { await model.load(using: environment) }
            }
        }
        .sheet(item: $model.rename) { route in
            PresetRenameSheet(name: route.name) { newName in
                Task { await model.rename(route.presetID, to: newName, using: environment) }
            }
        }
        .sheet(item: $model.useNow) { route in
            ProfessionalSigningQueueView(lockedEntries: nil, lockedPresetID: route.presetID)
        }
        .confirmationDialog(
            "Delete Preset?",
            isPresented: Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: model.pendingDelete
        ) { preset in
            Button("Delete \(preset.name)", role: .destructive) {
                Task { await model.delete(preset.id, using: environment) }
            }
            Button("Cancel", role: .cancel) { model.pendingDelete = nil }
        } message: { preset in
            Text("“\(preset.name)” will be removed. Signing history already recorded is kept. This does not delete the certificate or the profile.")
        }
        .alert("Presets", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var compactLibrary: some View {
        library
            .navigationDestination(for: PresetIdentifier.self) { id in
                PresetDetailView(presetID: id, model: model)
            }
    }

    private var library: some View {
        List {
            if model.isLoading && model.presets.isEmpty {
                ZSkeleton(rows: 3)
            } else if model.presets.isEmpty {
                emptyState
            } else {
                ForEach(model.presets) { preset in
                    presetRow(preset)
                }
            }
        }
        .navigationTitle("Presets")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    ZHaptics.tap()
                    model.builder = .create(.custom)
                } label: {
                    Label("New Preset", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityLabel("Create preset")
            }
        }
        .refreshable { await model.load(using: environment) }
    }

    private var emptyState: some View {
        Section {
            ContentUnavailableView {
                Label("No Presets", systemImage: "rectangle.stack")
            } description: {
                Text("Save a certificate, a profile, and the options you reuse. Presets store references, not secrets.")
            }
            ForEach(PresetTemplate.allCases) { template in
                Button {
                    model.builder = .create(template)
                } label: {
                    Label(template.suggestedName, systemImage: template.symbolName)
                        .presetTouchTarget()
                }
                .accessibilityHint(template.summary)
            }
        }
    }

    @ViewBuilder
    private func presetRow(_ preset: SigningPreset) -> some View {
        let report = model.reports[preset.id]
        let row = PresetCard(preset: preset, report: report, inventory: model.inventory)
        if sizeClass == .regular {
            Button {
                model.selectedID = preset.id
            } label: { row }
            .buttonStyle(.plain)
            .presetActions(preset, model: model, environment: environment)
        } else {
            NavigationLink(value: preset.id) { row }
                .presetActions(preset, model: model, environment: environment)
        }
    }
}

private struct PresetCard: View {
    let preset: SigningPreset
    let report: PresetCompatibilityReport?
    let inventory: PresetInventory?

    var body: some View {
        VStack(alignment: .leading, spacing: ZSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(preset.name)
                    .font(.headline)
                if preset.isDefault {
                    ZStatusBadge("Default", systemImage: "star.fill", kind: .info)
                }
                Spacer()
                if let report {
                    ZStatusBadge(report.overall.displayName, systemImage: "checkmark.seal", kind: PresetDisplay.badgeKind(for: report.overall))
                }
            }
            LabeledContent("Certificate", value: PresetDisplay.certificateName(preset, inventory: inventory))
            LabeledContent("Profile", value: PresetDisplay.profileName(preset, inventory: inventory))
            LabeledContent("Team", value: PresetDisplay.teamName(preset, inventory: inventory))
            LabeledContent("Last used", value: PresetDisplay.lastUsed(preset.usage.lastUsedAt))
            if let report {
                HStack(spacing: ZSpacing.xs) {
                    ForEach(report.checks.prefix(4)) { check in
                        ZStatusBadge(check.title, systemImage: check.symbolName, kind: PresetDisplay.checkKind(check.status))
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, ZSpacing.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityHint("Opens preset details")
    }

    private var spoken: String {
        var parts = [preset.name]
        if preset.isDefault { parts.append("Default preset") }
        parts.append("Certificate \(PresetDisplay.certificateName(preset, inventory: inventory))")
        parts.append("Profile \(PresetDisplay.profileName(preset, inventory: inventory))")
        parts.append("Team \(PresetDisplay.teamName(preset, inventory: inventory))")
        parts.append(PresetDisplay.lastUsed(preset.usage.lastUsedAt))
        if let report { parts.append(report.spokenSummary) }
        return parts.joined(separator: ". ")
    }
}

struct PresetDetailView: View {
    let presetID: PresetIdentifier
    @ObservedObject var model: PresetLibraryModel
    @Environment(\.applicationEnvironment) private var environment
    @State private var history: [SigningRecord] = []

    private var preset: SigningPreset? { model.presets.first { $0.id == presetID } }

    var body: some View {
        List {
            if let preset {
                Section {
                    LabeledContent("Certificate", value: PresetDisplay.certificateName(preset, inventory: model.inventory))
                    LabeledContent("Profile", value: PresetDisplay.profileName(preset, inventory: model.inventory))
                    LabeledContent("Team", value: PresetDisplay.teamName(preset, inventory: model.inventory))
                    LabeledContent("Template", value: preset.kind.displayName)
                    LabeledContent("Verification", value: preset.verificationPreference.displayName)
                    LabeledContent("After signing", value: preset.exportBehavior.displayName)
                    if preset.isDefault {
                        ZStatusBadge("Default", systemImage: "star.fill", kind: .info)
                    }
                } header: {
                    Text(preset.name)
                }

                if let report = model.reports[preset.id] {
                    Section {
                        Text(report.spokenSummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(report.spokenSummary)
                        ForEach(report.checks) { check in
                            VStack(alignment: .leading, spacing: 2) {
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
                    }
                }

                if let suggestions = model.suggestions[preset.id], !suggestions.isEmpty {
                    Section("Suggestions") {
                        ForEach(suggestions) { suggestion in
                            Text(suggestion.message)
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Section("History") {
                    LabeledContent("Last used", value: PresetDisplay.lastUsed(preset.usage.lastUsedAt))
                    LabeledContent("Successful uses", value: "\(preset.usage.successfulUses)")
                    LabeledContent("Failed uses", value: "\(preset.usage.failedUses)")
                    LabeledContent("Last successful app", value: preset.usage.lastSuccessfulAppLabel ?? "None")
                    if history.isEmpty {
                        Text("No journal entries for this preset yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(history.prefix(5)) { record in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.sourceDisplayName ?? record.sourceBundleIdentifier ?? "Application")
                                Text("\(record.outcome.displayName) · \(record.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                Section {
                    actionButton("Use Now", systemImage: "signature") { model.useNow = PresetRoute(presetID: preset.id) }
                    actionButton("Edit", systemImage: "pencil") { model.builder = .edit(preset) }
                    actionButton("Duplicate", systemImage: "plus.square.on.square") {
                        Task { await model.duplicate(preset.id, using: environment) }
                    }
                    actionButton("Rename", systemImage: "character.cursor.ibeam") {
                        model.rename = PresetRenameRoute(presetID: preset.id, name: preset.name)
                    }
                    if !preset.isDefault {
                        actionButton("Set Default", systemImage: "star") {
                            Task { await model.setDefault(preset.id, using: environment) }
                        }
                    }
                    Button(role: .destructive) {
                        model.pendingDelete = preset
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .presetTouchTarget()
                    }
                }

                Section {
                    Text(distributionNote(preset))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ContentUnavailableView("Preset Unavailable", systemImage: "rectangle.stack", description: Text("That preset is no longer in the library."))
            }
        }
        .navigationTitle(preset?.name ?? "Preset")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadHistory() }
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .presetTouchTarget()
        }
    }

    private func distributionNote(_ preset: SigningPreset) -> String {
        var parts = ["Saved on this device. This version does not sync, share, or run schedules."]
        if preset.distribution.scope != .local {
            parts.append("This preset is marked \(preset.distribution.scope.displayName). It is still stored only on this device.")
        }
        if preset.distribution.schedule != nil {
            parts.append("A schedule is saved. This version does not run it.")
        }
        if let label = preset.distribution.automationLabel, !label.isEmpty {
            parts.append("An automation label is saved. This version does not run it.")
        }
        return parts.joined(separator: " ")
    }

    private func loadHistory() async {
        guard let historyStore = environment.signingHistory else { return }
        history = (try? await historyStore.records(forPreset: presetID)) ?? []
    }
}

private struct PresetRenameSheet: View {
    @State var name: String
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Preset name", text: $name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($focused)
                    .presetTouchTarget()
                    .onSubmit { save() }
            }
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(SigningPresetCatalog.normalizedName(name).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        onSave(name)
        dismiss()
    }
}

@MainActor
final class PresetLibraryModel: ObservableObject {
    @Published var presets: [SigningPreset] = []
    @Published var inventory: PresetInventory?
    @Published var reports: [PresetIdentifier: PresetCompatibilityReport] = [:]
    @Published var suggestions: [PresetIdentifier: [PresetSuggestion]] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var selectedID: PresetIdentifier?
    @Published var builder: PresetBuilderRoute?
    @Published var rename: PresetRenameRoute?
    @Published var useNow: PresetRoute?
    @Published var pendingDelete: SigningPreset?

    func load(using environment: ApplicationEnvironment) async {
        guard let workflow = environment.signingPresetWorkflow else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await workflow.inventory()
            let stored = try await workflow.allPresets()
            inventory = snapshot
            presets = stored
            var nextReports: [PresetIdentifier: PresetCompatibilityReport] = [:]
            var nextSuggestions: [PresetIdentifier: [PresetSuggestion]] = [:]
            let ranking = SigningPresetMatcher.rank(presets: stored, for: nil, inventory: snapshot)
            for preset in stored {
                nextReports[preset.id] = SigningPresetMatcher.compatibility(of: preset, in: snapshot)
                nextSuggestions[preset.id] = SigningPresetMatcher.suggestions(
                    for: preset,
                    inventory: snapshot,
                    ranking: ranking
                )
            }
            reports = nextReports
            suggestions = nextSuggestions
            errorMessage = nil
        } catch let error as ZynSignError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Signing presets could not be loaded."
        }
    }

    func delete(_ id: PresetIdentifier, using environment: ApplicationEnvironment) async {
        guard let workflow = environment.signingPresetWorkflow else { return }
        do {
            try await workflow.delete(id: id)
            if selectedID == id { selectedID = nil }
            pendingDelete = nil
            await load(using: environment)
        } catch let error as ZynSignError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "The preset could not be deleted."
        }
    }

    func duplicate(_ id: PresetIdentifier, using environment: ApplicationEnvironment) async {
        guard let workflow = environment.signingPresetWorkflow else { return }
        do {
            let copy = try await workflow.duplicate(id: id)
            await load(using: environment)
            selectedID = copy.id
            ZHaptics.success()
        } catch let error as ZynSignError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "The preset could not be duplicated."
        }
    }

    func rename(_ id: PresetIdentifier, to name: String, using environment: ApplicationEnvironment) async {
        guard let workflow = environment.signingPresetWorkflow else { return }
        do {
            _ = try await workflow.rename(id: id, to: name)
            await load(using: environment)
        } catch let error as ZynSignError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "The preset could not be renamed."
        }
    }

    func setDefault(_ id: PresetIdentifier, using environment: ApplicationEnvironment) async {
        guard let workflow = environment.signingPresetWorkflow else { return }
        do {
            try await workflow.setDefault(id: id)
            await load(using: environment)
            ZHaptics.success()
        } catch let error as ZynSignError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "The default preset could not be changed."
        }
    }
}

struct PresetBuilderRoute: Identifiable {
    enum Mode {
        case create(PresetTemplate)
        case edit(SigningPreset)
    }
    let id = UUID()
    let mode: Mode

    static func create(_ template: PresetTemplate) -> PresetBuilderRoute {
        PresetBuilderRoute(mode: .create(template))
    }

    static func edit(_ preset: SigningPreset) -> PresetBuilderRoute {
        PresetBuilderRoute(mode: .edit(preset))
    }

    var existing: SigningPreset? {
        if case .edit(let preset) = mode { return preset }
        return nil
    }

    var template: PresetTemplate {
        if case .create(let template) = mode { return template }
        return .custom
    }
}

struct PresetRenameRoute: Identifiable {
    var id: String { presetID.rawValue }
    let presetID: PresetIdentifier
    let name: String
}

struct PresetRoute: Identifiable {
    var id: String { presetID.rawValue }
    let presetID: PresetIdentifier
}

private extension View {
    func presetActions(_ preset: SigningPreset, model: PresetLibraryModel, environment: ApplicationEnvironment) -> some View {
        self
            .contextMenu {
                presetMenu(preset, model: model, environment: environment)
            }
            .accessibilityActions {
                Button("Use Now") { model.useNow = PresetRoute(presetID: preset.id) }
                Button("Edit") { model.builder = .edit(preset) }
                Button("Duplicate") { Task { await model.duplicate(preset.id, using: environment) } }
                Button("Rename") { model.rename = PresetRenameRoute(presetID: preset.id, name: preset.name) }
                Button("View Compatibility") { model.selectedID = preset.id }
                Button("Set Default") { Task { await model.setDefault(preset.id, using: environment) } }
                Button("Delete") { model.pendingDelete = preset }
            }
    }

    @ViewBuilder
    func presetMenu(_ preset: SigningPreset, model: PresetLibraryModel, environment: ApplicationEnvironment) -> some View {
        Button { model.useNow = PresetRoute(presetID: preset.id) } label: { Label("Use Now", systemImage: "signature") }
        Button { model.builder = .edit(preset) } label: { Label("Edit", systemImage: "pencil") }
        Button { Task { await model.duplicate(preset.id, using: environment) } } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Button { model.rename = PresetRenameRoute(presetID: preset.id, name: preset.name) } label: { Label("Rename", systemImage: "character.cursor.ibeam") }
        Button { model.selectedID = preset.id } label: { Label("View Compatibility", systemImage: "checkmark.seal") }
        if !preset.isDefault {
            Button { Task { await model.setDefault(preset.id, using: environment) } } label: { Label("Set Default", systemImage: "star") }
        }
        Button(role: .destructive) { model.pendingDelete = preset } label: { Label("Delete", systemImage: "trash") }
    }
}
