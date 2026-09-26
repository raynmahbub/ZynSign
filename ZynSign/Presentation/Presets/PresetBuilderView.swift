import SwiftUI

/// Guided preset creator. Six steps, and going back only changes the step.
/// Certificate and profile choices are references. No secret is written
/// into the preset.
struct PresetBuilderView: View {
    let existing: SigningPreset?
    var onSaved: () -> Void = {}

    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var session: PresetBuilderSession
    @State private var identities: [SigningIdentity] = []
    @State private var profiles: [ProvisioningProfileSummary] = []
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var isSaving = false
    @FocusState private var nameFocused: Bool

    private let steps = BuilderStep.allCases

    init(existing: SigningPreset? = nil, template: PresetTemplate = .custom, onSaved: @escaping () -> Void = {}) {
        self.existing = existing
        self.onSaved = onSaved
        let draft = existing ?? template.makeDraft()
        let start = existing == nil ? 0 : BuilderStep.certificate.rawValue
        _session = State(initialValue: PresetBuilderSession(step: start, draft: draft))
    }

    private var step: BuilderStep { steps[min(max(session.step, 0), steps.count - 1)] }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(step.indexLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    Text(step.title)
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(step.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                stepContent
                if let loadError {
                    Section {
                        Text(loadError)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Preset" : "Edit Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .safeAreaInset(edge: .bottom) { navigationBar }
            .task { await loadChoices() }
            .alert("Could Not Save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .template: templateStep
        case .certificate: certificateStep
        case .profile: profileStep
        case .options: optionsStep
        case .preferences: preferencesStep
        case .review: reviewStep
        }
    }

    private var templateStep: some View {
        Section {
            TextField("Preset name", text: nameBinding)
                .textInputAutocapitalization(.words)
                .submitLabel(.next)
                .focused($nameFocused)
                .presetTouchTarget()
                .accessibilityLabel("Preset name")
            ForEach(PresetTemplate.allCases) { template in
                Button {
                    ZHaptics.tap()
                    apply(template)
                } label: {
                    HStack(spacing: ZSpacing.sm) {
                        Image(systemName: template.symbolName)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.suggestedName)
                                .font(.body)
                            Text(template.summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if session.draft.kind == template.kind {
                            Image(systemName: "checkmark.circle.fill")
                                .accessibilityLabel("Selected")
                        }
                    }
                    .presetTouchTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(template.suggestedName). \(template.summary)")
            }
        } header: {
            Text("Template")
        }
    }

    private var certificateStep: some View {
        Section {
            if identities.isEmpty {
                Text("No certificates are in the Keychain. You can save this preset as a draft and choose a certificate later.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                session.draft.certificateFingerprint = nil
            } label: {
                HStack {
                    Text("No certificate yet")
                    Spacer()
                    if session.draft.certificateFingerprint == nil {
                        Image(systemName: "checkmark")
                    }
                }
                .presetTouchTarget()
            }
            ForEach(identities, id: \.id) { identity in
                Button {
                    ZHaptics.tap()
                    session.draft.certificateFingerprint = identity.fingerprint
                    if session.draft.teamIdentifier == nil {
                        session.draft.teamIdentifier = CertificateTeamReference.teamIdentifier(in: identity.certificate.subject)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(identity.displayName)
                            Text(identity.isUsableForSigning ? "Usable" : "Not usable")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if session.draft.certificateFingerprint == identity.fingerprint {
                            Image(systemName: "checkmark")
                                .accessibilityLabel("Selected")
                        }
                    }
                    .presetTouchTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(identity.displayName). \(identity.isUsableForSigning ? "Usable for signing." : "Not usable for signing.")")
            }
        } header: {
            Text("Certificate")
        } footer: {
            Text("The preset stores the certificate's SHA-256 fingerprint. The private key stays in the Keychain.")
        }
    }

    private var profileStep: some View {
        Section {
            if profiles.isEmpty {
                Text("No provisioning profiles are in the library. You can save this preset as a draft and import a profile later.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                session.draft.provisioningProfileID = nil
                session.draft.provisioningProfileName = nil
            } label: {
                HStack {
                    Text("No profile yet")
                    Spacer()
                    if session.draft.provisioningProfileID == nil && session.draft.provisioningProfileName == nil {
                        Image(systemName: "checkmark")
                    }
                }
                .presetTouchTarget()
            }
            ForEach(profiles) { profile in
                Button {
                    ZHaptics.tap()
                    session.draft.provisioningProfileID = profile.id
                    session.draft.provisioningProfileName = profile.name
                    session.draft.teamIdentifier = SigningPreset.normalizedTeam(profile.teamIdentifier) ?? session.draft.teamIdentifier
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                            Text(profileSubtitle(profile))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if session.draft.provisioningProfileID == profile.id || session.draft.provisioningProfileName == profile.name {
                            Image(systemName: "checkmark")
                                .accessibilityLabel("Selected")
                        }
                    }
                    .presetTouchTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(profile.name). \(profileSubtitle(profile))")
            }
            TextField("Team identifier", text: teamBinding)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .presetTouchTarget()
                .accessibilityHint("Optional. A reference copied from the profile, not a credential.")
        } header: {
            Text("Provisioning Profile")
        } footer: {
            Text("The preset stores the profile's name and identifier. The profile file stays in the profile library.")
        }
    }

    private var optionsStep: some View {
        Section {
            Picker("Entitlements", selection: $session.draft.entitlementsSlot) {
                ForEach(SigningPreset.EntitlementsSlot.allCases, id: \.self) { slot in
                    Text(slot.displayName).tag(slot)
                }
            }
            .pickerStyle(.inline)
            TextField("Bundle identifier override", text: optionalBinding(\.bundleIdentifierOverride))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .presetTouchTarget()
            TextField("Display name override", text: optionalBinding(\.displayNameOverride))
                .presetTouchTarget()
        } header: {
            Text("Signing Options")
        } footer: {
            Text("Entitlements slot is applied when this preset signs. A bundle identifier or display name override is saved for a later version. This version does not change the application's declared identifier or name.")
        }
    }

    private var preferencesStep: some View {
        Section {
            Picker("Verification", selection: $session.draft.verificationPreference) {
                ForEach(SigningPreset.VerificationPreference.allCases, id: \.self) { preference in
                    Text(preference.displayName).tag(preference)
                }
            }
            Text(session.draft.verificationPreference.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("After signing", selection: $session.draft.exportBehavior) {
                ForEach(SigningPreset.ExportBehavior.allCases, id: \.self) { behavior in
                    Text(behavior.displayName).tag(behavior)
                }
            }
            Text(session.draft.exportBehavior.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Verification and Export")
        } footer: {
            Text("Verification always runs inside the signing pipeline. This preference only decides how the summary is presented. Export never uploads or installs.")
        }
    }

    private var reviewStep: some View {
        Section {
            LabeledContent("Name", value: session.draft.name)
            LabeledContent("Template", value: session.draft.kind.displayName)
            LabeledContent("Certificate", value: session.draft.certificateFingerprint == nil ? "Not selected" : "Selected")
            LabeledContent("Profile", value: session.draft.provisioningProfileName ?? "Not selected")
            LabeledContent("Team", value: session.draft.teamIdentifier ?? "Not recorded")
            LabeledContent("Entitlements", value: session.draft.entitlementsSlot.displayName)
            LabeledContent("Verification", value: session.draft.verificationPreference.displayName)
            LabeledContent("After signing", value: session.draft.exportBehavior.displayName)
            if !session.draft.isComplete {
                Text("This preset is a draft. It can be saved, and it will not be offered for one-tap signing until a certificate and a profile are selected.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Saved on this device. Sharing, team sync, and schedules are reserved and are not run by this version.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Review")
        }
    }

    private var navigationBar: some View {
        HStack(spacing: ZSpacing.sm) {
            Button("Back") {
                ZHaptics.tap()
                session.goBack()
            }
            .disabled(session.step == 0)
            .keyboardShortcut(.cancelAction)
            .presetTouchTarget()
            Spacer()
            if step == .review {
                Button(isSaving ? "Saving…" : "Save Preset") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
                .keyboardShortcut(.defaultAction)
                .presetTouchTarget()
            } else {
                Button("Continue") {
                    ZHaptics.tap()
                    session.goForward(maximum: steps.count - 1)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .presetTouchTarget()
                .disabled(step == .template && SigningPresetCatalog.normalizedName(session.draft.name).isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, ZSpacing.xs)
        .background(.bar)
    }

    private var nameBinding: Binding<String> {
        Binding(get: { session.draft.name }, set: { session.draft.name = $0 })
    }

    private var teamBinding: Binding<String> {
        Binding(
            get: { session.draft.teamIdentifier ?? "" },
            set: { session.draft.teamIdentifier = SigningPreset.normalizedTeam($0) }
        )
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<SigningPreset, String?>) -> Binding<String> {
        Binding(
            get: { session.draft[keyPath: keyPath] ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                session.draft[keyPath: keyPath] = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    private func apply(_ template: PresetTemplate) {
        let previousName = session.draft.name
        let wasTemplateName = PresetTemplate.allCases.contains { $0.suggestedName == previousName }
        var draft = session.draft
        draft.kind = template.kind
        if previousName.isEmpty || wasTemplateName {
            draft.name = template.suggestedName
        }
        draft.verificationPreference = template.makeDraft().verificationPreference
        draft.exportBehavior = template.makeDraft().exportBehavior
        draft.entitlementsSlot = template.makeDraft().entitlementsSlot
        session.draft = draft
    }

    private func profileSubtitle(_ profile: ProvisioningProfileSummary) -> String {
        let team = profile.teamIdentifier ?? "No team"
        let days = profile.daysUntilExpiration()
        if profile.isExpired() { return "\(team) · Expired" }
        return "\(team) · \(days) days left"
    }

    private func loadChoices() async {
        do {
            identities = try environment.identityStore.listIdentities()
        } catch let error as ZynSignError {
            loadError = error.userMessage
        } catch {
            loadError = "Certificates could not be loaded."
        }
        if let library = environment.provisioningProfiles {
            profiles = (try? await library.allProfiles()) ?? []
        }
        if step == .template {
            nameFocused = true
        }
    }

    private func save() async {
        guard let workflow = environment.signingPresetWorkflow else {
            saveError = "Signing presets are not available."
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            if existing == nil {
                _ = try await workflow.create(session.draft)
            } else {
                _ = try await workflow.save(session.draft)
            }
            ZHaptics.success()
            onSaved()
            dismiss()
        } catch let error as ZynSignError {
            saveError = error.userMessage
        } catch {
            saveError = "The preset could not be saved."
        }
    }
}

private enum BuilderStep: Int, CaseIterable, Identifiable {
    case template, certificate, profile, options, preferences, review

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .template: return "Name and template"
        case .certificate: return "Certificate"
        case .profile: return "Provisioning profile"
        case .options: return "Signing options"
        case .preferences: return "Verification and export"
        case .review: return "Review"
        }
    }

    var detail: String {
        switch self {
        case .template: return "Choose a starting point. You can change every option on the later steps, and you can come back without losing them."
        case .certificate: return "Choose the certificate this preset should prefer. Only a fingerprint is saved."
        case .profile: return "Choose the provisioning profile this preset should prefer. Only its name, identifier, and team are saved."
        case .options: return "Choose the entitlements layout. Overrides are saved and are not applied by the current pipeline."
        case .preferences: return "Choose how verification is presented and what to offer after a successful sign."
        case .review: return "Check the preset before saving it. Saving does not sign anything."
        }
    }

    var indexLabel: String { "Step \(rawValue + 1) of \(Self.allCases.count)" }
}
