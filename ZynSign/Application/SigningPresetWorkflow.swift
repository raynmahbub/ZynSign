import Foundation

/// The application-layer operations for signing presets.
///
/// The workflow is the only place that talks to the preset store, the
/// profile library, and the identity store together. Matching itself stays
/// in the domain: this type assembles the snapshot, enforces name and
/// default rules, and resolves references into the bytes a signing request
/// needs. It does not sign. One-tap signing confirms first, then the queue
/// or the confirmation screen calls the pipeline.
struct SigningPresetWorkflow {
    let presets: any SigningPresetStore
    let profiles: any ProvisioningProfileLibrary
    let identities: any IdentityStore
    let profileDirectory: URL
    let artifactURL: (ArtifactIdentifier) -> URL
    let now: @Sendable () -> Date

    init(
        presets: any SigningPresetStore,
        profiles: any ProvisioningProfileLibrary,
        identities: any IdentityStore,
        profileDirectory: URL,
        artifactURL: @escaping (ArtifactIdentifier) -> URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.presets = presets
        self.profiles = profiles
        self.identities = identities
        self.profileDirectory = profileDirectory
        self.artifactURL = artifactURL
        self.now = now
    }

    /// The signed-output directory the signing screen already uses.
    static func signedOutputDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent("Signed", isDirectory: true)
    }

    func inventory() async throws -> PresetInventory {
        let listed = try identities.listIdentities()
        let stored = try await profiles.allProfiles()
        let date = now()
        return PresetInventory(
            certificates: listed.map { identity in
                PresetInventory.Certificate(
                    fingerprint: identity.fingerprint,
                    displayName: identity.displayName,
                    teamIdentifier: CertificateTeamReference.teamIdentifier(in: identity.certificate.subject),
                    isUsable: identity.isUsableForSigning,
                    notValidBefore: identity.certificate.notValidBefore,
                    notValidAfter: identity.certificate.notValidAfter
                )
            },
            profiles: stored.map { summary in
                PresetInventory.Profile(
                    id: summary.id,
                    name: summary.name,
                    teamIdentifier: SigningPreset.normalizedTeam(summary.teamIdentifier),
                    bundleIdentifierPatterns: summary.bundleIdentifierPatterns,
                    expirationDate: summary.expirationDate,
                    sourceFileName: summary.sourceFileName,
                    fileIsPresent: fileIsPresent(summary.sourceFileName)
                )
            },
            now: date
        )
    }

    func allPresets() async throws -> [SigningPreset] {
        try await presets.allPresets().sorted(by: SigningPreset.sortForLibrary)
    }

    func recommendation(for app: PresetAppContext) async throws -> PresetMatch? {
        let snapshot = try await inventory()
        let stored = try await presets.allPresets()
        return SigningPresetMatcher.rank(presets: stored, for: app, inventory: snapshot).recommendation
    }

    func importReadiness(for app: PresetAppContext) async throws -> ImportSigningReadiness {
        let snapshot = try await inventory()
        let stored = try await presets.allPresets()
        return SigningPresetMatcher.importReadiness(app: app, presets: stored, inventory: snapshot)
    }

    func compatibility(of preset: SigningPreset, for app: PresetAppContext? = nil) async throws -> PresetCompatibilityReport {
        let snapshot = try await inventory()
        return SigningPresetMatcher.compatibility(of: preset, in: snapshot, for: app)
    }

    func suggestions(for preset: SigningPreset, app: PresetAppContext? = nil) async throws -> [PresetSuggestion] {
        let snapshot = try await inventory()
        let stored = try await presets.allPresets()
        let ranking = SigningPresetMatcher.rank(presets: stored, for: app, inventory: snapshot)
        return SigningPresetMatcher.suggestions(for: preset, inventory: snapshot, ranking: ranking, app: app)
    }

    func bulkPlan(preset: SigningPreset, subjects: [PresetBulkSubject]) async throws -> PresetBulkPlan {
        let snapshot = try await inventory()
        return SigningPresetMatcher.bulkPlan(preset: preset, subjects: subjects, inventory: snapshot)
    }

    /// Inserts a new preset. The first preset, and any save made while no
    /// default exists, becomes the default. Names must be unique.
    func create(_ preset: SigningPreset) async throws -> SigningPreset {
        let existing = try await presets.allPresets()
        let name = try SigningPresetCatalog.validateName(preset.name, existing: existing)
        var stored = preset
        stored.name = name
        stored.isDefault = preset.isDefault || existing.isEmpty || !existing.contains(where: \.isDefault)
        stored.updatedAt = now()
        if stored.isDefault {
            try await clearOtherDefaults(except: stored.id, existing: existing)
        }
        try await presets.upsert(stored)
        return stored
    }

    /// Replaces the stored content of an existing preset, keeping its
    /// identifier, creation date, usage, and distribution scope.
    func save(_ edited: SigningPreset) async throws -> SigningPreset {
        let existing = try await presets.allPresets()
        guard let prior = existing.first(where: { $0.id == edited.id }) else {
            throw ZynSignError.presetNotFound(diagnosticDetail: "No preset has id \(edited.id.rawValue).")
        }
        let name = try SigningPresetCatalog.validateName(edited.name, existing: existing, excluding: edited.id)
        var stored = prior.edited(
            name: name,
            kind: edited.kind,
            certificateFingerprint: edited.certificateFingerprint,
            provisioningProfileName: edited.provisioningProfileName,
            provisioningProfileID: edited.provisioningProfileID,
            teamIdentifier: edited.teamIdentifier,
            entitlementsSlot: edited.entitlementsSlot,
            bundleIdentifierOverride: edited.bundleIdentifierOverride,
            displayNameOverride: edited.displayNameOverride,
            verificationPreference: edited.verificationPreference,
            exportBehavior: edited.exportBehavior,
            isDefault: edited.isDefault || !existing.contains(where: { $0.id != edited.id && $0.isDefault }),
            at: now()
        )
        if stored.isDefault {
            try await clearOtherDefaults(except: stored.id, existing: existing)
        }
        try await presets.upsert(stored)
        return stored
    }

    func duplicate(id: PresetIdentifier) async throws -> SigningPreset {
        let existing = try await presets.allPresets()
        guard let preset = existing.first(where: { $0.id == id }) else {
            throw ZynSignError.presetNotFound()
        }
        let copy = SigningPresetCatalog.duplicate(preset, existing: existing, now: now())
        try await presets.upsert(copy)
        return copy
    }

    func rename(id: PresetIdentifier, to name: String) async throws -> SigningPreset {
        let existing = try await presets.allPresets()
        guard let preset = existing.first(where: { $0.id == id }) else {
            throw ZynSignError.presetNotFound()
        }
        let validated = try SigningPresetCatalog.validateName(name, existing: existing, excluding: id)
        var updated = preset
        updated.name = validated
        updated.updatedAt = now()
        updated.distribution = updated.distribution.incrementedRevision()
        try await presets.upsert(updated)
        return updated
    }

    func delete(id: PresetIdentifier) async throws {
        try await presets.remove(presetWithID: id)
    }

    func setDefault(id: PresetIdentifier) async throws {
        let existing = try await presets.allPresets()
        guard existing.contains(where: { $0.id == id }) else {
            throw ZynSignError.presetNotFound()
        }
        let updated = SigningPresetCatalog.settingDefault(existing, id: id, now: now())
        for preset in updated {
            let priorDefault = existing.first { $0.id == preset.id }?.isDefault ?? false
            if priorDefault != preset.isDefault {
                try await presets.upsert(preset)
            }
        }
    }

    func record(_ outcome: PresetUseOutcome) async throws {
        guard var preset = try await presets.preset(withID: outcome.presetID) else { return }
        preset = preset.recording(outcome)
        try await presets.upsert(preset)
    }

    /// Resolves references into the identity and profile bytes a request
    /// needs. Does not sign. Fails when the certificate is missing, not
    /// usable, or the profile file cannot be read.
    func resolve(_ preset: SigningPreset) async throws -> ResolvedPresetSigning {
        let snapshot = try await inventory()
        let report = SigningPresetMatcher.compatibility(of: preset, in: snapshot)
        guard let fingerprint = preset.certificateFingerprint else {
            throw ZynSignError.presetNotReady(userMessage: "Choose a certificate before using this preset.")
        }
        let listed = try identities.listIdentities()
        guard let identity = listed.first(where: { $0.fingerprint == fingerprint && $0.isUsableForSigning })
                ?? listed.first(where: { $0.fingerprint == fingerprint }) else {
            throw ZynSignError.presetNotReady(userMessage: "The certificate this preset uses is not in the Keychain.")
        }
        guard identity.isUsableForSigning else {
            throw ZynSignError.presetNotReady(userMessage: "The certificate this preset uses is not usable for signing.")
        }
        guard let summary = try await storedProfile(matching: preset) else {
            throw ZynSignError.presetNotReady(userMessage: "The provisioning profile this preset uses is not in the library.")
        }
        let bytes = try profileBytes(for: summary)
        return ResolvedPresetSigning(
            preset: preset,
            identity: identity,
            profile: summary,
            profileBytes: bytes,
            report: report,
            options: options(for: preset)
        )
    }

    /// Builds signing requests for the compatible half of a plan only.
    /// An identifier in `needsAttention` is never given a request. If a
    /// compatible app cannot be prepared, the whole preparation fails and
    /// nothing is returned — a partial queue would hide the failure.
    func executionRequests(
        for plan: PresetBulkPlan,
        entries: [LibraryEntry],
        outputDirectory: URL
    ) async throws -> [String: SigningQueueStepRequest] {
        let attention = Set(plan.needsAttention.map(\.id))
        guard let preset = try await presets.preset(withID: plan.presetID) else {
            throw ZynSignError.presetNotFound()
        }
        let resolved = try await resolve(preset)
        var requests: [String: SigningQueueStepRequest] = [:]
        for item in plan.compatible {
            if attention.contains(item.id) {
                throw ZynSignError.presetQueueRefusedIncompatible(
                    diagnosticDetail: "Plan listed \(item.id) as both compatible and needing attention."
                )
            }
            guard let entry = entries.first(where: { $0.record.id.rawValue == item.id }) else {
                throw ZynSignError.presetNotReady(
                    userMessage: "ZynSign could not prepare “\(item.displayName)” for signing, so nothing was queued."
                )
            }
            let request = try makeRequest(entry: entry, resolved: resolved, outputDirectory: outputDirectory)
            requests[item.id] = SigningQueueStepRequest(
                id: item.id,
                entry: entry,
                presetID: preset.id,
                certificateFingerprint: preset.certificateFingerprint,
                request: request
            )
        }
        let leaked = Set(requests.keys).intersection(attention)
        if !leaked.isEmpty {
            throw ZynSignError.presetQueueRefusedIncompatible(
                diagnosticDetail: "Refused to prepare incompatible applications: \(leaked.sorted().joined(separator: ", "))."
            )
        }
        return requests
    }

    func options(for preset: SigningPreset) -> SignApplicationOptions {
        let team = preset.teamIdentifier.flatMap { try? CodeDirectoryTeamIdentifier(rawValue: $0) }
        return SignApplicationOptions(
            teamIdentifier: team,
            emitDEREntitlements: preset.entitlementsSlot.emitsDEREntitlements
        )
    }

    // MARK: - Storage helpers

    private func clearOtherDefaults(except id: PresetIdentifier, existing: [SigningPreset]) async throws {
        for preset in existing where preset.id != id && preset.isDefault {
            var cleared = preset
            cleared.isDefault = false
            cleared.updatedAt = now()
            try await presets.upsert(cleared)
        }
    }

    private func storedProfile(matching preset: SigningPreset) async throws -> ProvisioningProfileSummary? {
        let stored = try await profiles.allProfiles()
        if let id = preset.provisioningProfileID, let match = stored.first(where: { $0.id == id }) {
            return match
        }
        guard let name = preset.provisioningProfileName else { return nil }
        return stored.first { $0.name == name }
    }

    private func fileIsPresent(_ sourceFileName: String) -> Bool {
        guard let url = profileFileURL(sourceFileName) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    func profileBytes(for summary: ProvisioningProfileSummary) throws -> Data {
        guard let url = profileFileURL(summary.sourceFileName) else {
            throw ZynSignError.invalidProvisioningProfileFile(
                diagnosticDetail: "The profile file name is not a single path component."
            )
        }
        do {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else {
                throw ZynSignError.invalidProvisioningProfileFile(
                    diagnosticDetail: "The profile file is empty."
                )
            }
            return data
        } catch let error as ZynSignError {
            throw error
        } catch {
            throw ZynSignError.invalidProvisioningProfileFile(
                diagnosticDetail: "The profile file could not be read.",
                underlyingError: error
            )
        }
    }

    private func profileFileURL(_ sourceFileName: String) -> URL? {
        guard !sourceFileName.isEmpty,
              !sourceFileName.contains("/"),
              !sourceFileName.contains("\\"),
              sourceFileName != ".",
              sourceFileName != "..",
              !sourceFileName.contains("..") else {
            return nil
        }
        let directory = profileDirectory.standardizedFileURL
        let file = directory.appendingPathComponent(sourceFileName, isDirectory: false).standardizedFileURL
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        guard file.path.hasPrefix(prefix) else { return nil }
        return file
    }

    private func makeRequest(
        entry: LibraryEntry,
        resolved: ResolvedPresetSigning,
        outputDirectory: URL
    ) throws -> SignApplicationRequest {
        let source = artifactURL(entry.record.artifact.artifactID)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ZynSignError.presetNotReady(
                userMessage: "ZynSign could not prepare “\(entry.record.displayName ?? entry.record.bundleIdentifier.rawValue)” for signing, so nothing was queued.",
                diagnosticDetail: "The package file is not in library storage."
            )
        }
        let entitlements = try SigningProfileEntitlementDerivation.derive(from: resolved.profileBytes)
        let output = outputDirectory.appendingPathComponent(Self.outputName(for: entry), isDirectory: false)
        return SignApplicationRequest(
            sourceURL: source,
            profile: resolved.profileBytes,
            identityID: resolved.identity.id,
            entitlements: entitlements,
            outputURL: output,
            options: resolved.options
        )
    }

    static func outputName(for entry: LibraryEntry) -> String {
        let bundle = entry.record.bundleIdentifier.rawValue.replacingOccurrences(of: "/", with: "_")
        let short = String(entry.record.id.rawValue.prefix(8))
        return "\(bundle)_signed_\(short).ipa"
    }
}

/// A preset whose certificate and profile references resolved to something
/// the pipeline can be given. Still not a signature, and still not
/// permission to skip confirmation.
struct ResolvedPresetSigning {
    let preset: SigningPreset
    let identity: SigningIdentity
    let profile: ProvisioningProfileSummary
    let profileBytes: Data
    let report: PresetCompatibilityReport
    let options: SignApplicationOptions
}

/// One prepared queue step. Built only for apps the plan marked compatible.
struct SigningQueueStepRequest: Identifiable {
    let id: String
    let entry: LibraryEntry
    let presetID: PresetIdentifier
    let certificateFingerprint: CertificateFingerprint?
    let request: SignApplicationRequest
}

extension LibraryEntry {
    func presetSubject() -> PresetBulkSubject {
        PresetBulkSubject(
            id: record.id.rawValue,
            bundleIdentifier: record.bundleIdentifier.rawValue,
            displayName: record.displayName ?? "Unnamed Application",
            artifactAvailable: isArtifactAvailable
        )
    }
}
