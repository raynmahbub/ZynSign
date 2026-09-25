import SwiftUI

/// The detail screen for one application record in the library.
///
/// The screen renders what the persisted record holds: the identity the
/// package declared, the state of the package file ZynSign keeps for it,
/// and the record's import and update information. Nothing is read from
/// storage here and no new conclusions are drawn — the entry the list
/// produced is the whole input, mapped into display values.
///
/// The screen states what a record is and is not: it records what the
/// package declared and that the package passed inspection when it was
/// imported. It is not a statement about signatures, trust, or
/// installability, none of which this build evaluates.
///
/// When the record's package is available, the screen offers the bundle
/// explorer, which lists the bundle's contents read-only. The offer follows
/// the entry's availability as the library derived it; the screen does not
/// re-examine storage to decide whether to show it.
struct ApplicationDetailView: View {

    let entry: LibraryEntry
    private let bundleInspection: IPABundleContentsInspection

    @Environment(\.applicationEnvironment) private var environment

    /// The profile-suggestion state for this app. Loading while the
    /// library and the compatibility engine are consulted.
    @State private var profilePhase: ProfileSuggestionPhase = .loading

    /// Every profile in the library, kept for the "Change Profile…" menu.
    @State private var allProfiles: [ProvisioningProfileSummary] = []

    /// Creates the screen for `entry`, with the inspection use case the
    /// bundle explorer runs on.
    init(entry: LibraryEntry, bundleInspection: IPABundleContentsInspection) {
        self.entry = entry
        self.bundleInspection = bundleInspection
    }

    /// What the Provisioning Profile section currently shows.
    private enum ProfileSuggestionPhase {
        case loading
        /// No compatibility use case in this composition.
        case unavailable
        /// The library holds no profiles yet.
        case noProfiles
        /// Profiles exist, but none suits this app.
        case noneSuitable
        /// A profile was chosen: automatically, from the pinned "Use for
        /// Signing" profile, or by the user's manual override.
        case resolved(Suggestion)
        /// The user's manual override names a profile that is not eligible
        /// for this app. Shown honestly, with its own report.
        case overriddenIneligible(
            profile: ProvisioningProfileSummary,
            report: ProfileCompatibilityReport
        )
    }

    /// The chosen profile plus everything the section needs to present it.
    private struct Suggestion {
        let match: ProfileMatch
        let source: Source
        /// Every eligible profile, best-first, for the change menu.
        let ranked: [ProfileMatch]

        enum Source: Equatable {
            /// The highest-ranked eligible profile.
            case automatic
            /// The profile pinned by "Use for Signing", when it ranks.
            case pinned
            /// The user's manual override for this app.
            case `override`
        }
    }

    var body: some View {
        let content = ApplicationDetailContent(entry: entry)
        List {
            Section("Application") {
                LabeledContent("Name", value: content.name)
                LabeledContent("Identifier", value: content.bundleIdentifier)
                LabeledContent("Version", value: content.versionText)
                LabeledContent("Build", value: content.buildText)
            }
            Section {
                LabeledContent("Status", value: content.artifactStatus)
                if let explanation = content.artifactExplanation {
                    Text(explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if content.canExploreBundle {
                    NavigationLink {
                        BundleExplorerView(inspection: bundleInspection, entry: entry)
                    } label: {
                        Label("Explore Bundle", systemImage: "folder")
                    }
                    .accessibilityHint("Lists the files and folders inside the application bundle.")
                    if ReleaseTrain.isAvailable(.smartSign) {
                        NavigationLink { SigningView(entry: entry) } label: {
                            Label("Sign Application…", systemImage: "signature")
                        }
                        .accessibilityHint("Sign this imported package with a certificate and provisioning profile.")
                    }
                } else {
                    Label(ReleaseTrain.isAvailable(.smartSign)
                          ? "Signing requires the package file to be available. Re-import the application."
                          : "Exploring requires the package file to be available. Re-import the application.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.footnote)
                }
            } header: {
                Text("Package")
            } footer: {
                if content.canExploreBundle {
                    Text(ReleaseTrain.isAvailable(.smartSign)
                         ? "Exploring lists the files and folders inside the application bundle. It reads the package's own records of them and does not open, run, or change any file. Signing runs the nine-stage pipeline end to end and delivers a signed IPA to Documents/Signed."
                         : "Exploring lists the files and folders inside the application bundle. It reads the package's own records of them and does not open, run, or change any file.")
                }
            }
            profileSuggestionSection
            Section("Library Record") {
                LabeledContent("Original File", value: content.sourceFileName)
                LabeledContent("Imported") {
                    Text(content.imported, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                }
                if let updated = content.updated {
                    LabeledContent("Last Updated") {
                        Text(updated, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                    }
                }
            }
            Section {
                Text(ReleaseTrain.isAvailable(.smartSign)
                     ? "This record states what the package declared and that it passed ZynSign's inspection when it was imported. Signing is performed on-device with the certificate and profile you supply; the delivered IPA is independently verified but not evaluated for trust or installability by ZynSign."
                     : "This record states what the package declared and that it passed ZynSign's inspection when it was imported. It is not a trust or installability claim.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(content.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadProfileSuggestion() }
    }

    // MARK: - Profile suggestion

    @ViewBuilder
    private var profileSuggestionSection: some View {
        Section {
            profileSuggestionContent
        } header: {
            Text("Provisioning Profile")
        } footer: {
            Text("Suggestions rank your profiles by bundle ID, team, certificates, and validity. You can always pick a different profile for this app — the choice is remembered.")
        }
    }

    @ViewBuilder
    private var profileSuggestionContent: some View {
        switch profilePhase {
        case .loading:
            HStack(spacing: ZSpacing.xs) {
                ProgressView()
                Text("Finding the best profile…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .unavailable:
            Label(
                "Profile suggestions are not part of this build's composition.",
                systemImage: "questionmark.circle"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .noProfiles:
            Label(
                "No profiles yet. Import a .mobileprovision file in the Profiles tab, then return here for a suggestion.",
                systemImage: "person.text.rectangle"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .noneSuitable:
            VStack(alignment: .leading, spacing: ZSpacing.xs) {
                ZStatusBadge(
                    ProfileDiagnosticSeverity.error.displayName,
                    systemImage: ProfileDiagnosticSeverity.error.systemImage,
                    kind: .error
                )
                Text("Profile not suitable for this app")
                    .font(.subheadline.weight(.semibold))
                Text("None of your imported profiles covers \(entry.record.bundleIdentifier.rawValue). Import a profile whose App ID matches this app, then reopen its details.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        case .overriddenIneligible(let profile, let report):
            overriddenContent(profile: profile, report: report)
        case .resolved(let suggestion):
            resolvedContent(suggestion)
        }
    }

    private func resolvedContent(_ suggestion: Suggestion) -> some View {
        let profile = suggestion.match.profile
        return VStack(alignment: .leading, spacing: ZSpacing.sm) {
            HStack(spacing: ZSpacing.xs) {
                Text(sourceLabel(for: suggestion.source))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if environment.profileSelections != nil {
                    Menu {
                        ForEach(allProfiles, id: \.id) { candidate in
                            Button {
                                Task { await chooseProfile(candidate) }
                            } label: {
                                if candidate.id == profile.id {
                                    Label(candidate.name, systemImage: "checkmark")
                                } else {
                                    Text(candidate.name)
                                }
                            }
                        }
                        if suggestion.source == .override {
                            Button {
                                Task { await useBestMatch() }
                            } label: {
                                Label("Use Best Match", systemImage: "wand.and.stars")
                            }
                        }
                    } label: {
                        Label("Change…", systemImage: "ellipsis.circle")
                    }
                    .accessibilityHint("Manually pick a different profile for this app.")
                }
            }
            Text(profile.name)
                .font(.body.weight(.medium))
                .lineLimit(1)
            HStack(spacing: ZSpacing.xs) {
                ProfileTypeBadge(type: profile.resolvedProfileType)
                ProfileExpirationBadge(profile.expirationAssessment())
                ProfileCompatibilityBadge(outcome: suggestion.match.report.overall)
            }
            if !suggestion.match.reasons.isEmpty {
                Text(suggestion.match.reasons.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProfileCompatibilitySummaryView(report: suggestion.match.report)
            NavigationLink {
                ProfileDetailView(summary: profile) {
                    Task { await loadProfileSuggestion() }
                }
            } label: {
                Label("View Profile Details", systemImage: "info.circle")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Provisioning profile suggestion")
    }

    private func overriddenContent(
        profile: ProvisioningProfileSummary,
        report: ProfileCompatibilityReport
    ) -> some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            HStack(spacing: ZSpacing.xs) {
                Text("Your choice")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if environment.profileSelections != nil {
                    Button {
                        Task { await useBestMatch() }
                    } label: {
                        Label("Use Best Match", systemImage: "wand.and.stars")
                    }
                    .font(.caption)
                }
            }
            Text(profile.name)
                .font(.body.weight(.medium))
                .lineLimit(1)
            HStack(spacing: ZSpacing.xs) {
                ZStatusBadge(
                    "Not suitable for this app",
                    systemImage: "exclamationmark.triangle.fill",
                    kind: .warning
                )
                ProfileExpirationBadge(profile.expirationAssessment())
            }
            ProfileCompatibilitySummaryView(report: report)
            NavigationLink {
                ProfileDetailView(summary: profile) {
                    Task { await loadProfileSuggestion() }
                }
            } label: {
                Label("View Profile Details", systemImage: "info.circle")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    private func sourceLabel(for source: Suggestion.Source) -> String {
        switch source {
        case .automatic: return "Suggested for this app"
        case .pinned: return "Your pinned profile"
        case .override: return "Your choice for this app"
        }
    }

    /// Re-reads the library and recomputes the suggestion for this app:
    /// manual override first, then the pinned "Use for Signing" profile
    /// when it ranks, then the best match.
    private func loadProfileSuggestion() async {
        guard let compatibility = environment.profileCompatibility else {
            profilePhase = .unavailable
            return
        }
        let profiles: [ProvisioningProfileSummary]
        if let library = environment.provisioningProfiles {
            do {
                profiles = try await library.allProfiles()
            } catch {
                profiles = []
            }
        } else {
            profiles = []
        }
        allProfiles = profiles
        guard !profiles.isEmpty else {
            profilePhase = .noProfiles
            return
        }

        let bundle = entry.record.bundleIdentifier.rawValue
        let ranked = compatibility.rank(profiles: profiles, targetBundleIdentifier: bundle)

        // The user's manual override wins, even when it is ineligible —
        // but an ineligible override is shown with its honest report and
        // an obvious way back to the best match.
        if let overrideID = environment.profileSelections?.selection(forApplication: entry.record.id),
           let overridden = profiles.first(where: { $0.id == overrideID }) {
            if let match = ranked.first(where: { $0.profile.id == overrideID }) {
                profilePhase = .resolved(Suggestion(match: match, source: .override, ranked: ranked))
            } else {
                profilePhase = .overriddenIneligible(
                    profile: overridden,
                    report: compatibility.evaluate(profile: overridden, targetBundleIdentifier: bundle)
                )
            }
            return
        }

        if let preferredID = environment.profileSelections?.preferredProfileID(),
           let pinned = ranked.first(where: { $0.profile.id == preferredID }) {
            profilePhase = .resolved(Suggestion(match: pinned, source: .pinned, ranked: ranked))
            return
        }

        if let best = ranked.first {
            profilePhase = .resolved(Suggestion(match: best, source: .automatic, ranked: ranked))
            return
        }

        profilePhase = .noneSuitable
    }

    /// Remembers the user's manual override for this app.
    private func chooseProfile(_ profile: ProvisioningProfileSummary) async {
        environment.profileSelections?.setSelection(
            profile.id,
            forApplication: entry.record.id
        )
        ZHaptics.tap()
        await loadProfileSuggestion()
    }

    /// Clears the override so the automatic ranking decides again.
    private func useBestMatch() async {
        environment.profileSelections?.setSelection(nil, forApplication: entry.record.id)
        ZHaptics.tap()
        await loadProfileSuggestion()
    }
}

/// The detail screen's display values, derived from a library entry.
///
/// The mapping is the only place the record's vocabulary becomes the
/// screen's vocabulary. Absent declarations are shown as em dashes rather
/// than invented, a record that was never updated shows only its import
/// date, and a missing or inconsistent package file is represented
/// explicitly instead of being reported as available.
struct ApplicationDetailContent: Equatable {

    /// The resolved display name, or a neutral placeholder when the
    /// package declared no usable name.
    let name: String

    /// The declared bundle identifier.
    let bundleIdentifier: String

    /// The declared marketing version, or an em dash when undeclared.
    let versionText: String

    /// The declared build version, or an em dash when undeclared.
    let buildText: String

    /// The file name the package was imported from, or an em dash when none
    /// was recorded. A provenance label only, never a path.
    let sourceFileName: String

    /// The current availability of the record's package file.
    let artifactStatus: String

    /// A user-presentable explanation shown when the package file is not
    /// what the record expects, or `nil` when it is available.
    let artifactExplanation: String?

    /// Whether the bundle explorer is offered. True exactly when the
    /// library reports the package available; a missing or inconsistent
    /// package has nothing trustworthy to explore, and the screen shows its
    /// explanation instead.
    let canExploreBundle: Bool

    /// When the record was created.
    let imported: Date

    /// When the record last changed, or `nil` when it never changed after
    /// being created.
    let updated: Date?

    init(entry: LibraryEntry) {
        let record = entry.record
        self.name = record.displayName ?? "Unnamed Application"
        self.bundleIdentifier = record.bundleIdentifier.rawValue
        self.versionText = record.identity.shortVersionString ?? "—"
        self.buildText = record.identity.buildVersion ?? "—"
        self.sourceFileName = record.sourceFileName ?? "—"
        self.imported = record.importedAt
        self.updated = record.updatedAt > record.importedAt ? record.updatedAt : nil
        self.canExploreBundle = entry.isArtifactAvailable
        switch entry.artifactAvailability {
        case .available:
            self.artifactStatus = entry.artifactAvailability.displayName
            self.artifactExplanation = nil
        case .missing:
            self.artifactStatus = entry.artifactAvailability.displayName
            self.artifactExplanation = "The package file kept for this record could not be found in ZynSign's storage. The record's information is preserved; the package itself is gone."
        case .inconsistent:
            self.artifactStatus = entry.artifactAvailability.displayName
            self.artifactExplanation = "The package file kept for this record has changed since it was imported: it no longer matches what the record captured. The file may have been damaged or replaced."
        }
    }
}

// MARK: - Previews

/// Synthetic values for the detail previews: invented identifiers, names,
/// versions, and timestamps. No real package appears anywhere.
private enum PreviewFixtures {

    static func identity(
        bundleIdentifier: String,
        displayName: String?,
        shortVersion: String?,
        build: String?
    ) -> ApplicationIdentity {
        guard let identifier = BundleIdentifier(rawValue: bundleIdentifier) else {
            preconditionFailure("Preview fixture bundle identifier is not valid: \(bundleIdentifier)")
        }
        return ApplicationIdentity(
            bundleIdentifier: identifier,
            declaredDisplayName: displayName,
            shortVersionString: shortVersion,
            buildVersion: build
        )
    }

    static func fingerprint(seed: UInt8) -> ArtifactFingerprint {
        guard let fingerprint = ArtifactFingerprint(
            algorithm: .sha256,
            digestBytes: Array(repeating: seed, count: 32)
        ) else {
            preconditionFailure("A 32-byte digest must always form a fingerprint.")
        }
        return fingerprint
    }

    static func record(
        identity: ApplicationIdentity,
        sourceFileName: String?,
        importedAt: Date,
        updatedAt: Date
    ) -> ApplicationRecord {
        ApplicationRecord(
            id: ApplicationRecordIdentifier(),
            identity: identity,
            executableName: nil,
            sourceFileName: sourceFileName,
            artifact: ArtifactReference(
                artifactID: ArtifactIdentifier(),
                byteCount: 4_194_304,
                fingerprint: fingerprint(seed: 0xAB)
            ),
            inspection: ApplicationRecord.InspectionSummary(classification: .valid),
            importedAt: importedAt,
            updatedAt: updatedAt
        )
    }

    static let completeEntry = LibraryEntry(
        record: record(
            identity: identity(
                bundleIdentifier: "com.example.synthetic",
                displayName: "Example",
                shortVersion: "1.2",
                build: "34"
            ),
            sourceFileName: "Example.ipa",
            importedAt: Date(timeIntervalSinceReferenceDate: 750_000_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 750_000_900)
        ),
        artifactAvailability: .available
    )

    static let missingArtifactEntry = LibraryEntry(
        record: completeEntry.record,
        artifactAvailability: .missing
    )

    static let undeclaredMetadataEntry = LibraryEntry(
        record: record(
            identity: identity(
                bundleIdentifier: "com.example.minimal",
                displayName: nil,
                shortVersion: nil,
                build: nil
            ),
            sourceFileName: nil,
            importedAt: Date(timeIntervalSinceReferenceDate: 750_000_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 750_000_000)
        ),
        artifactAvailability: .available
    )
}

private let previewEnvironment = CompositionRoot.makeApplicationEnvironment()

#Preview("Application Detail") {
    NavigationStack {
        ApplicationDetailView(
            entry: PreviewFixtures.completeEntry,
            bundleInspection: previewEnvironment.bundleInspection
        )
    }
}

#Preview("Application Detail, Missing Package") {
    NavigationStack {
        ApplicationDetailView(
            entry: PreviewFixtures.missingArtifactEntry,
            bundleInspection: previewEnvironment.bundleInspection
        )
    }
}

#Preview("Application Detail, Undeclared Metadata") {
    NavigationStack {
        ApplicationDetailView(
            entry: PreviewFixtures.undeclaredMetadataEntry,
            bundleInspection: previewEnvironment.bundleInspection
        )
    }
}
