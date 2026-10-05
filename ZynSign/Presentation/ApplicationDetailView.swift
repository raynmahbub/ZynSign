import SwiftUI

/// A professional, read-only inspection page for one imported IPA.
///
/// The overview stays visible while the archive is inspected. Metadata,
/// archive structure, component summaries, and diagnostics are presented as
/// expandable cards so the screen remains responsive on large packages. No
/// control edits the IPA or any value declared by its Info.plist.
@MainActor
struct ApplicationDetailView: View {

    let entry: LibraryEntry
    @StateObject private var studio = EntitlementsStudioModel()
    private let bundleInspection: IPABundleContentsInspection
    private let detailsInspection: IPAApplicationDetailsInspection

    @Environment(\.applicationEnvironment) private var environment
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.signingQueuePresentation) private var signingQueuePresentation
    @State private var queueConfiguration: SigningQueueConfigurationRequest?
    @State private var health: SigningDiagnosticsAnalysis?
    @State private var isAnalyzingHealth = true
    @State private var healthError: String?
    @State private var healthGeneration = 0
    @StateObject private var model: ApplicationDetailsModel
    @State private var isGeneralExpanded = true
    @State private var isBundleInfoExpanded = false
    @State private var isArchiveInfoExpanded = false
    @State private var isBundleExplorerExpanded = true
    @State private var areComponentsExpanded = false
    @State private var isInfoPlistExpanded = false
    @State private var isLibraryRecordExpanded = false
    @State private var areDiagnosticsExpanded = true
    @State private var infoPlistMode: InfoPlistDisplayMode = .friendly

    /// The profile-suggestion state for this app. Loading while the
    /// library and the compatibility engine are consulted.
    @State private var profilePhase: ProfileSuggestionPhase = .loading

    /// Every profile in the library, kept for the "Change…" menu.
    @State private var allProfiles: [ProvisioningProfileSummary] = []

    init(
        entry: LibraryEntry,
        bundleInspection: IPABundleContentsInspection,
        detailsInspection: IPAApplicationDetailsInspection
    ) {
        self.entry = entry
        self.bundleInspection = bundleInspection
        self.detailsInspection = detailsInspection
        _model = StateObject(wrappedValue: ApplicationDetailsModel(
            inspection: detailsInspection,
            recordID: entry.record.id
        ))
    }

    /// What the Provisioning Profile card currently shows.
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

    /// The chosen profile plus everything the card needs to present it.
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

    @ViewBuilder
    private var entitlementsStudioCard: some View {
        if ReleaseTrain.isAvailable(.entitlementsStudio) {
            DetailSectionCard(
                title: "Entitlements Studio",
                subtitle: "App requests & compatibility analysis",
                symbol: "checklist",
                isExpanded: .constant(true)
            ) {
                NavigationLink {
                    EntitlementsStudioView(entry: entry, studio: studio)
                } label: {
                    Label("Open Entitlements Studio", systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(!entry.isArtifactAvailable)
                .accessibilityHint("Inspect app claims and compare a selected provisioning profile, read only.")
                Text("Understand requested capabilities before signing. Inspection does not edit entitlements or predict platform acceptance.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var resourceStudioCard: some View {
        if let resourceInspection = environment.resourceInspection {
            let summary: ResourceSummary = {
                if let contents = model.report?.bundleContents {
                    return resourceInspection.quickSummary(from: contents)
                }
                return .empty
            }()

            DetailSectionCard(
                title: "Resource & Asset Studio",
                subtitle: "Visual inspection for icons, launch screens & media",
                symbol: "photo.stack.fill",
                isExpanded: .constant(true)
            ) {
                VStack(spacing: ZSpacing.sm) {
                    resourceSummaryGrid(summary)

                    NavigationLink {
                        ResourceStudioView(entry: entry, inspection: resourceInspection)
                    } label: {
                        Label("Open Resource & Asset Studio", systemImage: "arrow.up.right.square")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!entry.isArtifactAvailable)
                    .accessibilityHint("Visual inspector for app icons, launch screens, images, fonts, audio, video, and localizations.")

                    Text("Visually explore app icons, launch screens, bundled fonts, localization files, and media assets. Read-only inspection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func resourceSummaryGrid(_ summary: ResourceSummary) -> some View {
        let items: [(label: String, count: Int, symbol: String, tint: Color)] = [
            ("Icons", summary.iconCount, "app.badge", .orange),
            ("Launch Assets", summary.launchAssetCount, "arrow.up.right.video", .indigo),
            ("Images", summary.imageCount, "photo", .blue),
            ("Fonts", summary.fontCount, "textformat", .purple),
            ("Audio", summary.audioCount, "waveform", .pink),
            ("Videos", summary.videoCount, "film", .red),
            ("Localization Files", summary.localizationCount, "globe", .teal)
        ]

        LazyVGrid(columns: actionColumns, spacing: ZSpacing.xs) {
            ForEach(items, id: \.label) { item in
                HStack(spacing: ZSpacing.xs) {
                    Image(systemName: item.symbol)
                        .foregroundStyle(item.tint)
                        .font(.subheadline)
                        .frame(width: 20)
                    Text(item.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(item.count > 0 ? "\(item.count)" : "—")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, ZSpacing.sm)
                .padding(.vertical, 8)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: ZRadius.sm, style: .continuous))
            }
        }
    }

    private var recordContent: ApplicationDetailContent {
        ApplicationDetailContent(entry: entry)
    }

    private var actionColumns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: ZSpacing.sm), GridItem(.flexible(), spacing: ZSpacing.sm)]
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: ZSpacing.md) {
                hero
                overviewCard
                signingHealthCard
                signingStatusCard
                quickActionsCard
                RecommendedPresetCard(entry: entry)
                profileSuggestionCard
                entitlementsStudioCard
                resourceStudioCard

                if model.isRefreshing, model.report != nil {
                    HStack(spacing: ZSpacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("Refreshing inspection…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Refreshing app inspection")
                }

                if let message = model.refreshFailure {
                    refreshFailureCard(message)
                }

                if let report = model.report {
                    metadataSections(report)
                    bundleExplorerSection(report)
                    componentSummarySection(report)
                    infoPlistSection(report)
                } else {
                    inspectionPhaseCard
                }

                diagnosticsSection
                libraryRecordSection
                readOnlyNote
            }
            .padding(.horizontal, ZSpacing.md)
            .padding(.top, ZSpacing.md)
            .padding(.bottom, ZSpacing.xl)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(recordContent.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isRefreshing || !entry.isArtifactAvailable)
                .accessibilityLabel("Refresh Inspection")
                .accessibilityHint("Re-reads bounded metadata and bundle structure from the imported IPA.")
            }
        }
        .task { await model.load() }
        .task { await loadProfileSuggestion() }
        .task(id: entry.record.id.rawValue) { await analyzeHealth() }
        .task(id: entry.record.id.rawValue) {
            // Nova: remember what the user is looking at, for "Continue Last Session".
            environment.smartWorkspace?.noteSession(
                .inspecting,
                recordID: entry.record.id.rawValue,
                displayName: entry.record.displayName
            )
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
                guard !Task.isCancelled else { break }
                await analyzeHealth()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await analyzeHealth(force: true) } }
        }
        .refreshable {
            await model.refresh()
            await analyzeHealth(force: true)
            await loadProfileSuggestion()
        }
        .sheet(item: $queueConfiguration) { request in
            SigningQueueConfigurationView(
                entries: request.entries,
                origin: request.origin,
                onOpenQueue: { signingQueuePresentation.present() },
                onDone: { queueConfiguration = nil }
            )
        }
    }

    /// Diagnostics and the richer app-detail inspection use separate read-only
    /// boundaries; neither a structural detail verdict nor a saved profile
    /// summary is promoted into a signing authorization.
    private var signingHealthCard: some View {
        VStack(alignment: .leading, spacing: ZSpacing.sm) {
            ReleaseReadinessLink(recordID: entry.record.id)
            SigningHealthCard(report: health?.report, isAnalyzing: isAnalyzingHealth, error: healthError)
            if let health {
                NavigationLink {
                    SigningDiagnosticsView(report: health.report, history: health.history,
                                           changes: health.changes,
                                           historyUnavailable: health.historyUnavailable)
                } label: {
                    Label("Issues, recommendations & scan history", systemImage: "doc.text.magnifyingglass")
                        .font(.subheadline)
                }
                .accessibilityHint("Opens the read-only local diagnostics inspector")
            }
            if healthError != nil {
                Button("Retry signing health check") { Task { await analyzeHealth(force: true) } }
            }
            Text("No signing identity or profile is selected here. Open Sign App to check your actual configuration. A local score does not establish iOS acceptance.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @MainActor private func analyzeHealth(force: Bool = false) async {
        healthGeneration += 1
        let generation = healthGeneration
        guard let diagnostics = environment.signingDiagnostics else {
            isAnalyzingHealth = false
            healthError = "Signing diagnostics are unavailable in this build."
            return
        }
        isAnalyzingHealth = true
        health = nil
        healthError = nil
        defer {
            if generation == healthGeneration { isAnalyzingHealth = false }
        }
        do {
            let result = try await diagnostics.analyze(recordWithID: entry.record.id, force: force)
            guard !Task.isCancelled, generation == healthGeneration else { return }
            health = result
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == healthGeneration else { return }
            healthError = (error as? SigningDiagnosticsError)?.userMessage
                ?? "The app could not be analyzed. Please try again."
        }
    }

    // MARK: - Overview

    private var hero: some View {
        ZCard(variant: .material, cornerRadius: ZRadius.lg) {
            HStack(alignment: .center, spacing: ZSpacing.md) {
                ApplicationIconView(
                    artifactID: entry.record.artifact.artifactID,
                    displayName: recordContent.name,
                    bundleIdentifier: recordContent.bundleIdentifier,
                    size: 92
                )
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: ZSpacing.xs) {
                    Text(recordContent.name)
                        .font(.largeTitle.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(recordContent.bundleIdentifier)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: ZSpacing.xs) {
                        Text("Version \(recordContent.versionText)")
                        Text("·")
                        Text("Build \(recordContent.buildText)")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    signatureBadge
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    private var overviewCard: some View {
        ZCard {
            VStack(alignment: .leading, spacing: ZSpacing.md) {
                SectionHeading(title: "App Overview", symbol: "square.grid.2x2")
                DetailValueRow(label: "Imported", value: recordContent.imported.formatted(
                    Date.FormatStyle(date: .abbreviated, time: .shortened)
                ))
                DetailValueRow(
                    label: "IPA file size",
                    value: ByteCountFormatter.string(
                        fromByteCount: Int64(entry.record.artifact.byteCount),
                        countStyle: .file
                    )
                )
                DetailValueRow(label: "Signing status", value: signatureStatusText)
                if let explanation = recordContent.artifactExplanation {
                    Label(explanation, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Package unavailable. \(explanation)")
                }
            }
        }
    }

    // MARK: - Signing status and quick actions

    private var signingStatusCard: some View {
        ZCard(variant: .filled, cornerRadius: ZRadius.lg) {
            VStack(alignment: .leading, spacing: ZSpacing.md) {
                HStack(alignment: .top, spacing: ZSpacing.sm) {
                    Image(systemName: "signature")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: ZRadius.card))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Signing Status")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        Text("Signature presence on this page is structural only. The Binary Inspector re-computes the signature's hashes on this device.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: ZSpacing.xs) {
                    signatureBadge
                    if let architectures = model.report?.executable?.architectureNames, !architectures.isEmpty {
                        ZStatusBadge(architectures.joined(separator: ", "), systemImage: "cpu", kind: .neutral)
                    }
                }

                VStack(spacing: ZSpacing.sm) {
                    DetailValueRow(label: "Verification", value: "Not verified on this page — open the Binary Inspector")
                    DetailValueRow(label: "Selected certificate", value: "None — choose in Sign App")
                    DetailValueRow(label: "Provisioning profile", value: "None selected")
                    DetailValueRow(label: "Compatibility", value: compatibilitySummary)
                }

                if let binaryInspection = environment.binaryInspection, entry.isArtifactAvailable {
                    NavigationLink {
                        BinaryInspectorView(inspection: binaryInspection, entry: entry, generator: binaryInspectorGenerator)
                    } label: {
                        Label("Inspect & Verify Signature", systemImage: "checkmark.shield")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Opens the Binary and Signature Inspector, which inspects every executable and re-computes its signature's hashes on this device.")
                }

                if canSign {
                    NavigationLink {
                        SigningView(entry: entry, studio: studio)
                    } label: {
                        Label("Continue to Signing", systemImage: "arrow.right.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Choose a certificate and provisioning profile, then review the signing pipeline.")
                } else {
                    Text(signingUnavailableMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var quickActionsCard: some View {
        ZCard {
            VStack(alignment: .leading, spacing: ZSpacing.md) {
                SectionHeading(title: "Quick Actions", symbol: "bolt.fill")
                LazyVGrid(columns: actionColumns, alignment: .center, spacing: ZSpacing.sm) {
                    NavigationLink {
                        SigningView(entry: entry, studio: studio)
                    } label: {
                        QuickActionTile(
                            title: "Sign App",
                            subtitle: signActionSubtitle,
                            symbol: "signature",
                            tint: .accentColor
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSign)
                    .accessibilityHint(signingUnavailableMessage)

                    if signingQueuePresentation.isAvailable {
                        Button {
                            ZHaptics.tap()
                            queueConfiguration = SigningQueueConfigurationRequest(
                                entry: entry,
                                origin: .applicationDetails
                            )
                        } label: {
                            QuickActionTile(
                                title: "Add to Queue",
                                subtitle: canSign ? "Sign in the background" : signActionSubtitle,
                                symbol: "tray.and.arrow.down",
                                tint: .purple
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSign)
                        .accessibilityLabel("Add to Signing Queue")
                        .accessibilityHint(canSign
                            ? "Queues this application to be signed in the background while you keep using ZynSign."
                            : signingUnavailableMessage)
                    }

                    Button {} label: {
                        QuickActionTile(
                            title: "Verify",
                            subtitle: "Available for signed output",
                            symbol: "checkmark.shield",
                            tint: .blue
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(true)
                    .accessibilityHint("Independent verification for an imported source package is not available yet.")

                    ShareLink(item: environment.artifactFileURL(for: entry.record.artifact.artifactID)) {
                        QuickActionTile(
                            title: "Export",
                            subtitle: "Share the original IPA",
                            symbol: "square.and.arrow.up",
                            tint: .teal
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!entry.isArtifactAvailable)
                    .accessibilityLabel("Export original IPA")

                    if ReleaseTrain.isAvailable(.entitlementsStudio) {
                        NavigationLink {
                            EntitlementsStudioView(entry: entry, studio: studio)
                        } label: {
                            QuickActionTile(
                                title: "Entitlements",
                                subtitle: "Inspect claims & profile",
                                symbol: "checklist",
                                tint: .purple
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!entry.isArtifactAvailable)
                        .accessibilityHint("Inspect app claims and compare a selected provisioning profile, read only.")
                    }

                    NavigationLink {
                        BundleExplorerView(inspection: bundleInspection, entry: entry)
                    } label: {
                        QuickActionTile(
                            title: "View Bundle",
                            subtitle: "Browse files read-only",
                            symbol: "folder",
                            tint: .indigo
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!entry.isArtifactAvailable)
                    .accessibilityHint("Opens the read-only IPA explorer. Previews read a chosen file without changing it.")

                    if let binaryInspection = environment.binaryInspection {
                        NavigationLink {
                            BinaryInspectorView(inspection: binaryInspection, entry: entry, generator: binaryInspectorGenerator)
                        } label: {
                            QuickActionTile(
                                title: "Inspect Binary",
                                subtitle: "Mach-O, signature, verification",
                                symbol: "cpu",
                                tint: .purple
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!entry.isArtifactAvailable)
                        .accessibilityHint("Inspects every executable's structure and code signature, and verifies each signature on this device, read-only.")
                    }

                    if let resourceInspection = environment.resourceInspection {
                        NavigationLink {
                            ResourceStudioView(entry: entry, inspection: resourceInspection)
                        } label: {
                            QuickActionTile(
                                title: "Resource Studio",
                                subtitle: "Media, fonts, icons & localizations",
                                symbol: "photo.stack",
                                tint: .teal
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!entry.isArtifactAvailable)
                        .accessibilityHint("Visual inspector for app icons, launch screens, images, fonts, audio, video, and localizations.")
                    }

                    Button {
                        Task { await model.refresh() }
                    } label: {
                        QuickActionTile(
                            title: "Refresh Inspection",
                            subtitle: model.isRefreshing ? "Inspecting…" : "Re-read app metadata",
                            symbol: "arrow.clockwise",
                            tint: .orange
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!entry.isArtifactAvailable || model.isRefreshing)
                    .accessibilityHint("Re-reads bounded metadata, executable structure, and bundle contents from the imported IPA.")
                }
            }
        }
    }

    private var canSign: Bool {
        entry.isArtifactAvailable && ReleaseTrain.isAvailable(.smartSign)
    }

    /// How exported inspection reports name the tool that produced them.
    private var binaryInspectorGenerator: String {
        "ZynSign \(environment.applicationInfo.marketingVersion) (\(environment.applicationInfo.buildVersion))"
    }

    private var signActionSubtitle: String {
        if !entry.isArtifactAvailable { return "Re-import the IPA" }
        if !ReleaseTrain.isAvailable(.smartSign) { return "Available in a later release" }
        return "Choose identity and profile"
    }

    private var signingUnavailableMessage: String {
        if !entry.isArtifactAvailable {
            return "Signing requires the package file to be available. Re-import the application."
        }
        if !ReleaseTrain.isAvailable(.smartSign) {
            return "Signing is not available in this release stage yet."
        }
        return "Choose a signing identity and provisioning profile to continue."
    }

    private var signatureStatusText: String {
        guard let state = model.report?.executable?.signatureState else {
            if case .failed = model.phase { return "Inspection unavailable" }
            return "Inspecting…"
        }
        switch state {
        case .signed: return "Signed — structure detected"
        case .unsigned: return "Unsigned — no signature structure found"
        case .partiallySigned: return "Partially signed"
        case .malformed: return "Malformed signature structure"
        case .notInspected(let reason): return "Not inspected — \(reason.explanation)"
        }
    }

    private var signatureBadge: some View {
        guard let state = model.report?.executable?.signatureState else {
            if case .failed = model.phase {
                return AnyView(ZStatusBadge("Inspection unavailable", systemImage: "exclamationmark.triangle", kind: .warning))
            }
            return AnyView(ZStatusBadge("Inspecting", systemImage: "hourglass", kind: .neutral))
        }

        switch state {
        case .signed:
            return AnyView(ZStatusBadge("Signed", systemImage: "checkmark.seal", kind: .info))
        case .unsigned:
            return AnyView(ZStatusBadge("Unsigned", systemImage: "minus.circle", kind: .neutral))
        case .partiallySigned:
            return AnyView(ZStatusBadge("Partially Signed", systemImage: "exclamationmark.triangle", kind: .warning))
        case .malformed:
            return AnyView(ZStatusBadge("Malformed", systemImage: "xmark.shield", kind: .error))
        case .notInspected(let reason):
            let kind: ZStatusBadge.Kind = reason == .exceedsReadLimit ? .unsupported : .warning
            return AnyView(ZStatusBadge("Not Inspected", systemImage: "questionmark.circle", kind: kind))
        }
    }

    private var compatibilitySummary: String {
        guard let report = model.report else {
            return "Not evaluated — inspection has not completed."
        }
        if report.supportedPlatforms.contains(where: { $0.localizedCaseInsensitiveContains("simulator") }) {
            return "Simulator platform declared; device and profile compatibility are not evaluated here."
        }
        if let executable = report.executable, !executable.hasDeviceArchitecture,
           !executable.architectureNames.isEmpty {
            return "No ARM device architecture found. A profile and device context are also required."
        }
        if report.executable?.hasDeviceArchitecture == true {
            return "An ARM device slice is present. Certificate, profile, and device compatibility are not evaluated yet."
        }
        return "Not evaluated — choose a certificate and profile in the signing workflow."
    }

    // MARK: - Provisioning profile suggestion

    /// The "Provisioning Profile" card. It stays expanded so the suggestion
    /// is visible the moment the app opens, in whatever phase it is in.
    private var profileSuggestionCard: some View {
        ZCard {
            VStack(alignment: .leading, spacing: ZSpacing.md) {
                SectionHeading(title: "Provisioning Profile", symbol: "shippingbox")
                profileSuggestionContent
                Text("Suggestions rank saved display summaries by bundle ID, team, certificates, and declared dates. They do not authenticate the stored file or grant signing authority; Sign App verifies the original bytes before a run. You can pick a different profile for this app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                "No profiles yet. Import a .mobileprovision file in Certificates & Profiles → Profiles, then return here for a suggestion.",
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

    // MARK: - Metadata sections

    @ViewBuilder
    private func metadataSections(_ report: ApplicationDetailsInspectionReport) -> some View {
        DetailSectionCard(
            title: "General",
            subtitle: "Declared application metadata",
            symbol: "info.circle",
            isExpanded: $isGeneralExpanded
        ) {
            let identity = report.metadata?.identity
            DetailValueRow(label: "Display name", value: identity?.displayName ?? "Not declared")
            DetailValueRow(label: "Bundle ID", value: identity?.bundleIdentifier.rawValue ?? recordContent.bundleIdentifier)
            DetailValueRow(label: "Version", value: identity?.shortVersionString ?? "Not declared")
            DetailValueRow(label: "Build", value: identity?.buildVersion ?? "Not declared")
            DetailValueRow(label: "Minimum iOS version", value: report.metadata?.minimumOSVersion ?? "Not declared")
            DetailValueRow(label: "Executable name", value: report.metadata?.executableName ?? "Not declared")
        }
        DetailSectionCard(
            title: "Bundle Information",
            subtitle: report.bundlePath?.rawValue ?? "Bundle path unavailable",
            symbol: "shippingbox",
            isExpanded: $isBundleInfoExpanded
        ) {
            DetailValueRow(label: "Bundle path", value: report.bundlePath?.rawValue ?? "Not established")
            DetailValueRow(label: "Bundle type", value: report.bundleType ?? "Not declared")
            DetailValueRow(label: "Main executable", value: mainExecutablePath(for: report))
            DetailValueRow(label: "Supported platforms", value: supportedPlatformsText(for: report))
        }
        DetailSectionCard(
            title: "Archive Information",
            subtitle: "\(report.archive.entryCount.formatted()) entries · \(report.archive.state.displayName)",
            symbol: "archivebox",
            isExpanded: $isArchiveInfoExpanded
        ) {
            DetailValueRow(
                label: "Archive size",
                value: ByteCountFormatter.string(fromByteCount: Int64(entry.record.artifact.byteCount), countStyle: .file)
            )
            DetailValueRow(label: "Compression status", value: report.archive.state.displayName)
            DetailValueRow(
                label: "Compressed / expanded",
                value: "\(ByteCountFormatter.string(fromByteCount: Int64(report.archive.compressedByteCount), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(report.archive.uncompressedByteCount), countStyle: .file))"
            )
            DetailValueRow(label: "Import location", value: "ZynSign app-private library")
            DetailValueRow(label: "Original file", value: recordContent.sourceFileName)
            DetailValueRow(label: "Validation status", value: report.validationClassification.displayName)
            Text("Compression and sizes come from the archive's entry table and are declarations from the imported container.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func mainExecutablePath(for report: ApplicationDetailsInspectionReport) -> String {
        guard let bundlePath = report.bundlePath,
              let executableName = report.metadata?.executableName ?? entry.record.executableName,
              let path = bundlePath.appending(component: executableName) else {
            return "Not declared"
        }
        return path.rawValue
    }

    // MARK: - Bundle explorer

    private func bundleExplorerSection(_ report: ApplicationDetailsInspectionReport) -> some View {
        DetailSectionCard(
            title: "Visual Bundle Explorer",
            subtitle: report.bundleContents.map { "\($0.folderCount) folders · \($0.fileCount) files" } ?? "Bundle contents unavailable",
            symbol: "folder.tree",
            isExpanded: $isBundleExplorerExpanded
        ) {
            if let contents = report.bundleContents, let bundlePath = report.bundlePath {
                HStack(spacing: ZSpacing.xs) {
                    CountPill(title: "Files", count: contents.fileCount, symbol: "doc")
                    CountPill(title: "Folders", count: contents.folderCount, symbol: "folder")
                    if contents.otherEntryCount > 0 {
                        CountPill(title: "Other", count: contents.otherEntryCount, symbol: "link")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(contents.fileCount) files, \(contents.folderCount) folders, \(contents.otherEntryCount) other entries")

                BundleTreeView(bundlePath: bundlePath, contents: contents)

                NavigationLink {
                    BundleExplorerView(inspection: bundleInspection, entry: entry)
                } label: {
                    Label("Open Full Bundle Explorer", systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(!entry.isArtifactAvailable)
                .accessibilityHint("Opens the full read-only browser for this app bundle.")
            } else if report.bundlePath == nil {
                Text("A single valid app bundle could not be established in this archive.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Bundle entries are not available for this inspection.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Components

    private func componentSummarySection(_ report: ApplicationDetailsInspectionReport) -> some View {
        let summary = report.components
        return DetailSectionCard(
            title: "Frameworks & Extensions",
            subtitle: "\(summary.frameworks.count) frameworks · \(summary.appExtensions.count) extensions",
            symbol: "puzzlepiece.extension",
            isExpanded: $areComponentsExpanded
        ) {
            LazyVGrid(columns: actionColumns, spacing: ZSpacing.sm) {
                ComponentCountTile(title: "Frameworks", count: summary.frameworks.count, symbol: "shippingbox")
                ComponentCountTile(title: "Dynamic libraries", count: summary.dynamicLibraries.count, symbol: "dylib")
                ComponentCountTile(title: "App Extensions", count: summary.appExtensions.count, symbol: "puzzlepiece.extension")
                ComponentCountTile(title: "Nested apps", count: summary.nestedApplications.count, symbol: "app.badge")
                ComponentCountTile(title: "Widgets", count: summary.widgets.count, symbol: "rectangle.stack")
            }

            ComponentDisclosureList(title: "Frameworks", symbol: "shippingbox", components: summary.frameworks)
            ComponentDisclosureList(title: "Dynamic Libraries", symbol: "dylib", components: summary.dynamicLibraries)
            ComponentDisclosureList(title: "App Extensions", symbol: "puzzlepiece.extension", components: summary.appExtensions)
            ComponentDisclosureList(title: "Nested Applications", symbol: "app.badge", components: summary.nestedApplications)

            if summary.uninspectedExtensionCount > 0 {
                Text("Widget detection is based on the extension point in each inspected extension's Info.plist. Some extension metadata was skipped because of the per-pass inspection limit.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if summary.appExtensions.isEmpty {
                Text("No .appex extension bundles were found in the app bundle.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("Component counts are derived from bundle paths and file names. Nothing is loaded or executed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Info.plist viewer

    private func infoPlistSection(_ report: ApplicationDetailsInspectionReport) -> some View {
        DetailSectionCard(
            title: "Info.plist Viewer",
            subtitle: "Friendly fields or bounded raw key-value pairs",
            symbol: "doc.text.magnifyingglass",
            isExpanded: $isInfoPlistExpanded
        ) {
            Picker("Info.plist display mode", selection: $infoPlistMode) {
                Text("Friendly View").tag(InfoPlistDisplayMode.friendly)
                Text("Raw Key-Value").tag(InfoPlistDisplayMode.raw)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Info.plist display mode")

            switch infoPlistMode {
            case .friendly:
                let fields = friendlyFields(for: report)
                if fields.isEmpty {
                    Text("No Info.plist values could be read.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(fields) { field in
                        VStack(alignment: .leading, spacing: 3) {
                            DetailValueRow(label: field.title, value: field.value)
                            Text(field.rawKey)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                    }
                }
            case .raw:
                if report.infoPlistEntries.isEmpty {
                    Text("The raw property list is unavailable or could not be parsed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: ZSpacing.xs) {
                        ForEach(report.infoPlistEntries) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.key)
                                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Text(item.valueDescription)
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3)
                            if item.id != report.infoPlistEntries.last?.id {
                                Divider()
                            }
                        }
                    }
                    if report.omittedInfoPlistEntryCount > 0 {
                        Text("\(report.omittedInfoPlistEntryCount) additional key(s) were omitted to keep the raw view bounded.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text("Values are untrusted declarations. Nested collections are summarized and data blobs are represented by size only.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func supportedPlatformsText(for report: ApplicationDetailsInspectionReport) -> String {
        guard !report.supportedPlatforms.isEmpty else { return "Not declared" }
        let names = report.supportedPlatforms.joined(separator: ", ")
        guard report.omittedSupportedPlatformCount > 0 else { return names }
        return "\(names), plus \(report.omittedSupportedPlatformCount) additional value(s) omitted"
    }

    private func friendlyFields(for report: ApplicationDetailsInspectionReport) -> [FriendlyInfoField] {
        guard report.metadata != nil || !report.infoPlistEntries.isEmpty else { return [] }
        var values: [String: String] = [:]
        for item in report.infoPlistEntries {
            values[item.key] = item.valueDescription
        }
        let identity = report.metadata?.identity
        return [
            FriendlyInfoField(title: "App Name", rawKey: "CFBundleDisplayName", value: identity?.declaredDisplayName ?? values["CFBundleDisplayName"] ?? "Not declared"),
            FriendlyInfoField(title: "Bundle Name", rawKey: "CFBundleName", value: identity?.declaredBundleName ?? values["CFBundleName"] ?? "Not declared"),
            FriendlyInfoField(title: "Bundle ID", rawKey: "CFBundleIdentifier", value: identity?.bundleIdentifier.rawValue ?? values["CFBundleIdentifier"] ?? "Not declared"),
            FriendlyInfoField(title: "Version", rawKey: "CFBundleShortVersionString", value: identity?.shortVersionString ?? values["CFBundleShortVersionString"] ?? "Not declared"),
            FriendlyInfoField(title: "Build", rawKey: "CFBundleVersion", value: identity?.buildVersion ?? values["CFBundleVersion"] ?? "Not declared"),
            FriendlyInfoField(title: "Minimum iOS version", rawKey: "MinimumOSVersion", value: report.metadata?.minimumOSVersion ?? values["MinimumOSVersion"] ?? "Not declared"),
            FriendlyInfoField(title: "Executable", rawKey: "CFBundleExecutable", value: report.metadata?.executableName ?? values["CFBundleExecutable"] ?? "Not declared"),
            FriendlyInfoField(title: "Bundle Type", rawKey: "CFBundlePackageType", value: report.bundleType ?? values["CFBundlePackageType"] ?? "Not declared"),
            FriendlyInfoField(title: "Supported Platforms", rawKey: "CFBundleSupportedPlatforms", value: supportedPlatformsText(for: report))
        ]
    }

    // MARK: - Diagnostics and record notes

    private var diagnosticsSection: some View {
        DetailSectionCard(
            title: "Diagnostics",
            subtitle: diagnosticsSubtitle,
            symbol: "stethoscope",
            isExpanded: $areDiagnosticsExpanded
        ) {
            if let report = model.report {
                if report.diagnostics.isEmpty {
                    DiagnosticRow(diagnostic: ApplicationInspectionDiagnostic(
                        code: "diagnostics.clean",
                        title: "No diagnostics",
                        detail: "No structural or metadata findings were reported in the latest inspection.",
                        severity: .success
                    ))
                } else {
                    ForEach(report.diagnostics) { diagnostic in
                        DiagnosticRow(diagnostic: diagnostic)
                    }
                }
                HStack(spacing: ZSpacing.xs) {
                    Text("IPA structure & metadata")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: ZSpacing.sm)
                    ValidationStatusBadge(classification: report.validationClassification)
                }
                .accessibilityElement(children: .combine)
            } else {
                switch model.phase {
                case .loading:
                    HStack(spacing: ZSpacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("Inspection is running. Diagnostics will appear when it finishes.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    DiagnosticRow(diagnostic: ApplicationInspectionDiagnostic(
                        code: "inspection.failed",
                        title: "Inspection could not complete",
                        detail: message,
                        severity: .error
                    ))
                    Button("Retry Inspection") { Task { await model.refresh() } }
                        .buttonStyle(.bordered)
                        .disabled(!entry.isArtifactAvailable)
                case .loaded:
                    EmptyView()
                }
            }
            if let failure = model.refreshFailure {
                DiagnosticRow(diagnostic: ApplicationInspectionDiagnostic(
                    code: "inspection.refresh-failed",
                    title: "Refresh failed",
                    detail: failure,
                    severity: .warning
                ))
            }
        }
    }

    private var diagnosticsSubtitle: String {
        if let report = model.report {
            let count = report.diagnostics.filter { $0.severity != .success }.count
            return count == 0 ? "No findings" : "\(count) finding(s)"
        }
        if case .failed = model.phase { return "Inspection unavailable" }
        return "Waiting for inspection"
    }

    private func refreshFailureCard(_ message: String) -> some View {
        ZCard(variant: .outlined) {
            HStack(alignment: .top, spacing: ZSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Refresh did not complete")
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    model.clearRefreshFailure()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .accessibilityLabel("Dismiss refresh message")
            }
        }
    }

    private var libraryRecordSection: some View {
        DetailSectionCard(
            title: "Library Record",
            subtitle: "Import provenance",
            symbol: "tray.full",
            isExpanded: $isLibraryRecordExpanded
        ) {
            DetailValueRow(label: "Original file", value: recordContent.sourceFileName)
            DetailValueRow(label: "Imported", value: recordContent.imported.formatted(
                Date.FormatStyle(date: .abbreviated, time: .shortened)
            ))
            if let updated = recordContent.updated {
                DetailValueRow(label: "Last updated", value: updated.formatted(
                    Date.FormatStyle(date: .abbreviated, time: .shortened)
                ))
            }
            DetailValueRow(label: "Artifact state", value: recordContent.artifactStatus)
        }
    }

    private var inspectionPhaseCard: some View {
        ZCard {
            switch model.phase {
            case .loading:
                HStack(spacing: ZSpacing.sm) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Inspecting App Details…")
                            .font(.headline)
                        Text("Reading bounded metadata and archive structure without extracting files.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            case .failed(let message):
                VStack(alignment: .leading, spacing: ZSpacing.sm) {
                    Label("Inspection unavailable", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Try Again") { Task { await model.refresh() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!entry.isArtifactAvailable)
                }
            case .loaded:
                EmptyView()
            }
        }
    }

    private var readOnlyNote: some View {
        HStack(alignment: .top, spacing: ZSpacing.sm) {
            Image(systemName: "lock.doc")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("This page reports what the IPA declares. Inspection is read-only and does not establish signature trust, certificate authorization, or installability.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, ZSpacing.xs)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

/// Synthetic values for the detail previews: invented identifiers, names,
/// versions, and timestamps. No real package appears anywhere.
private enum PreviewFixtures {
    static func identity(bundleIdentifier: String, displayName: String?, shortVersion: String?, build: String?) -> ApplicationIdentity {
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
        guard let fingerprint = ArtifactFingerprint(algorithm: .sha256, digestBytes: Array(repeating: seed, count: 32)) else {
            preconditionFailure("A 32-byte digest must always form a fingerprint.")
        }
        return fingerprint
    }

    static func record(identity: ApplicationIdentity, sourceFileName: String?, importedAt: Date, updatedAt: Date) -> ApplicationRecord {
        ApplicationRecord(
            id: ApplicationRecordIdentifier(),
            identity: identity,
            executableName: "Example",
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
            identity: identity(bundleIdentifier: "com.example.synthetic", displayName: "Example", shortVersion: "1.2", build: "34"),
            sourceFileName: "Example.ipa",
            importedAt: Date(timeIntervalSinceReferenceDate: 750_000_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 750_000_900)
        ),
        artifactAvailability: .available
    )

    static let missingArtifactEntry = LibraryEntry(record: completeEntry.record, artifactAvailability: .missing)

    static let undeclaredMetadataEntry = LibraryEntry(
        record: record(
            identity: identity(bundleIdentifier: "com.example.minimal", displayName: nil, shortVersion: nil, build: nil),
            sourceFileName: nil,
            importedAt: Date(timeIntervalSinceReferenceDate: 750_000_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 750_000_000)
        ),
        artifactAvailability: .available
    )
}

private let previewEnvironment = CompositionRoot.fallbackEnvironment

#Preview("Application Detail") {
    NavigationStack {
        ApplicationDetailView(
            entry: PreviewFixtures.completeEntry,
            bundleInspection: previewEnvironment.bundleInspection,
            detailsInspection: previewEnvironment.applicationDetailsInspection
        )
    }
}

#Preview("Application Detail, Missing Package") {
    NavigationStack {
        ApplicationDetailView(
            entry: PreviewFixtures.missingArtifactEntry,
            bundleInspection: previewEnvironment.bundleInspection,
            detailsInspection: previewEnvironment.applicationDetailsInspection
        )
    }
}

#Preview("Application Detail, Undeclared Metadata") {
    NavigationStack {
        ApplicationDetailView(
            entry: PreviewFixtures.undeclaredMetadataEntry,
            bundleInspection: previewEnvironment.bundleInspection,
            detailsInspection: previewEnvironment.applicationDetailsInspection
        )
    }
}
