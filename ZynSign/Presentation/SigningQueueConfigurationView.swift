import SwiftUI
import UniformTypeIdentifiers

/// The configuration sheet every "queue for signing" entry point presents:
/// Library rows, the Library's bulk selection, an application's detail
/// screen, the Smart Sign screen, and a settled import all land here, so
/// one signing configuration is chosen exactly one way.
///
/// The sheet collects the three facts a signing job needs — which identity,
/// which profile, which entitlements layout — plus the job's priority, and
/// turns them into one submission per selected application. It enqueues and
/// steps aside: from the moment a job is accepted, the queue owns the work,
/// and the sheet's success state offers the dashboard rather than pretending
/// to run anything itself.
///
/// Queueing is the moment the user asks for signing, so it is the moment
/// ZynSign's lock is consulted: when the user requires authentication
/// before sensitive actions, the sheet asks once for the whole selection —
/// exactly as Smart Sign asks before a run — and queues nothing unless the
/// attempt succeeds. A queued job never signs behind a preference the user
/// set.
///
/// One configuration applies to the whole selection. That is a deliberate
/// limit, stated on screen: a provisioning profile authorizes specific
/// bundle identifiers, so signing several applications with one profile is
/// only meaningful when the profile covers them — and the pipeline's
/// preflight holds every job to that on its own run, refusing the ones the
/// profile does not establish.
struct SigningQueueConfigurationView: View {

    /// The applications to queue, in the order the user selected them.
    let entries: [LibraryEntry]

    /// Where the request came from, recorded on every job.
    let origin: SigningJobOrigin

    /// Opens the queue dashboard after a successful enqueue. The presenting
    /// screen dismisses this sheet first; the shell presents the dashboard.
    var onOpenQueue: () -> Void = {}

    /// Closes the sheet.
    var onDone: () -> Void = {}

    @Environment(\.applicationEnvironment) private var env
    @Environment(\.appLock) private var appLock

    @State private var identities: [SigningIdentity] = []
    @State private var isLoadingIdentities = true
    @State private var identitiesError: String?
    @State private var selectedIdentityID: SigningIdentityIdentifier?

    @State private var profileSummaries: [ProvisioningProfileSummary] = []
    @State private var selectedProfileSummaryID: ProvisioningProfileIdentifier?
    @State private var profileData: Data?
    @State private var profileName: String?
    @State private var profileTeam: String?
    @State private var profileError: String?
    @State private var showProfileImporter = false

    @State private var emitDEREntitlements = false
    @State private var priority: SigningJobPriority = .normal

    @State private var queuedCount: Int?
    @State private var skippedUnavailableCount = 0
    @State private var isAuthorizing = false
    @State private var authorizationError: String?

    private var queue: SigningQueue { env.signingQueue }

    private var selectedIdentity: SigningIdentity? {
        guard let id = selectedIdentityID else { return nil }
        return identities.first { $0.id == id }
    }

    private var signableEntries: [LibraryEntry] {
        entries.filter { $0.isArtifactAvailable }
    }

    private var derivedEntitlementCount: Int? {
        guard let data = profileData else { return nil }
        guard let entitlements = try? ProfileEntitlementDerivation.entitlements(fromProvisioningProfile: data) else {
            return nil
        }
        return entitlements.count
    }

    private var canQueue: Bool {
        queuedCount == nil
            && !isAuthorizing
            && selectedIdentityID != nil
            && profileData != nil
            && !signableEntries.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if let count = queuedCount {
                    successContent(count)
                } else {
                    formContent
                }
            }
            .navigationTitle(entries.count == 1 ? "Queue for Signing" : "Queue \(entries.count) Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(queuedCount == nil ? "Cancel" : "Done") { onDone() }
                }
            }
            .task {
                await loadIdentities()
                await loadProfileSummaries()
            }
            .fileImporter(
                isPresented: $showProfileImporter,
                allowedContentTypes: [.data, .item],
                allowsMultipleSelection: false
            ) { result in
                handleProfilePicker(result)
            }
        }
    }

    // MARK: - Form

    private var formContent: some View {
        List {
            applicationsSection
            identitySection
            profileSection
            optionsSection
            actionSection
        }
        .listStyle(.insetGrouped)
    }

    private var applicationsSection: some View {
        Section {
            ForEach(entries, id: \.record.id) { entry in
                HStack(spacing: ZSpacing.sm) {
                    ApplicationIconView(
                        artifactID: entry.record.artifact.artifactID,
                        displayName: entry.record.displayName ?? entry.record.bundleIdentifier.rawValue,
                        bundleIdentifier: entry.record.bundleIdentifier.rawValue,
                        size: 36
                    )
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.record.displayName ?? "Unnamed Application")
                            .font(.body)
                            .lineLimit(1)
                        Text(entry.record.bundleIdentifier.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: ZSpacing.xs)
                    if !entry.isArtifactAvailable {
                        ZStatusBadge("Package Missing", systemImage: "exclamationmark.triangle", kind: .warning)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(entry.record.displayName ?? "Unnamed Application"), \(entry.record.bundleIdentifier.rawValue)\(entry.isArtifactAvailable ? "" : ", package file missing, will be skipped")")
            }
            if signableEntries.count < entries.count {
                Text("\(entries.count - signableEntries.count) application(s) have no available package file and will be skipped. Re-import them before queueing.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Applications")
        } footer: {
            if entries.count > 1 {
                Text("One configuration applies to every selected application. The pipeline's preflight validates each job against the profile on its own run, so a job the profile does not cover fails cleanly without touching the others.")
            }
        }
    }

    private var identitySection: some View {
        Section {
            if isLoadingIdentities {
                ZSkeleton(rows: 1)
            } else if let error = identitiesError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("Retry") { Task { await loadIdentities() } }
            } else if identities.isEmpty {
                Label("No certificates imported.", systemImage: "signature")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                NavigationLink {
                    CertificateManagerView(
                        store: env.identityStore,
                        annotations: env.identityAnnotations,
                        importer: env.pkcs12Importer
                    )
                } label: {
                    Label("Open Certificates", systemImage: "key.fill")
                }
            } else {
                Picker("Signing Identity", selection: $selectedIdentityID) {
                    Text("Select Identity").tag(nil as SigningIdentityIdentifier?)
                    ForEach(identities, id: \.id) { identity in
                        VStack(alignment: .leading) {
                            Text(identity.displayName)
                            Text(identity.certificate.subject.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(Optional(identity.id))
                    }
                }
                .pickerStyle(.navigationLink)
                if let identity = selectedIdentity {
                    HStack(spacing: ZSpacing.xs) {
                        if identity.isUsableForSigning {
                            ZStatusBadge.ready("Ready to sign")
                        } else {
                            ZStatusBadge.needsAttention("Not usable")
                        }
                        Spacer()
                    }
                }
            }
        } header: {
            Text("Signing Identity")
        } footer: {
            Text("Private keys never leave the Keychain. The pipeline verifies key association and protection again on every run.")
        }
    }

    private var profileSection: some View {
        Section {
            if let name = profileName, profileData != nil {
                LabeledContent("Profile", value: name)
                if let team = profileTeam {
                    LabeledContent("Team", value: team)
                }
                if let count = derivedEntitlementCount {
                    LabeledContent("Entitlements", value: "\(count) from profile")
                }
                Button("Remove Profile", role: .destructive) {
                    profileData = nil
                    profileName = nil
                    profileTeam = nil
                    profileError = nil
                    selectedProfileSummaryID = nil
                }
            } else {
                Button {
                    showProfileImporter = true
                } label: {
                    Label("Choose Profile from Files…", systemImage: "doc.badge.ellipsis")
                }
            }
            if !profileSummaries.isEmpty {
                ForEach(profileSummaries) { summary in
                    Button {
                        selectLibraryProfile(summary)
                    } label: {
                        HStack(spacing: ZSpacing.xs) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(summary.name)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(profileSummaryDetail(summary))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: ZSpacing.xs)
                            if selectedProfileSummaryID == summary.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityLabel("Selected")
                            }
                            if summary.expirationDate < Date() {
                                ZStatusBadge("Expired", systemImage: "calendar.badge.exclamationmark", kind: .error)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Profile \(summary.name)\(summary.teamIdentifier.map { ", team \($0)" } ?? "")\(summary.expirationDate < Date() ? ", expired" : "")\(selectedProfileSummaryID == summary.id ? ", selected" : "")")
                }
            }
            if let error = profileError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
        } header: {
            Text("Provisioning Profile")
        } footer: {
            Text("From your profile library or from Files. The queue keeps its own copy of the profile while the job is listed — that is what lets a waiting job survive an interruption — and discards the copy when the job is removed.")
        }
    }

    private func profileSummaryDetail(_ summary: ProvisioningProfileSummary) -> String {
        var parts: [String] = []
        if let team = summary.teamIdentifier {
            parts.append("Team \(team)")
        }
        parts.append("Expires \(summary.expirationDate.formatted(date: .abbreviated, time: .omitted))")
        return parts.joined(separator: " · ")
    }

    private var optionsSection: some View {
        Section {
            Picker("Priority", selection: $priority) {
                ForEach(SigningJobPriority.allCases, id: \.self) { option in
                    Text("\(option.displayName) — \(option.purposeText)").tag(option)
                }
            }
            .accessibilityLabel("Job priority")
            Toggle(isOn: $emitDEREntitlements) {
                Label("DER entitlements (iOS 15+ • 0x20400)", systemImage: "doc.text.image")
            }
            .tint(.blue)
            HStack(spacing: ZSpacing.xs) {
                ZStatusBadge(emitDEREntitlements ? "0x20400" : "0x20200", systemImage: "cpu", kind: emitDEREntitlements ? .info : .neutral)
                ZStatusBadge(emitDEREntitlements ? "Slot 5 + 7" : "Slot 5", systemImage: "square.stack.3d.up", kind: .neutral)
                Spacer()
            }
        } header: {
            Text("Queue Options")
        } footer: {
            Text("Priority orders waiting jobs — high before normal before low, and within one priority, the order you asked. A running job is never preempted.")
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                Task { await authorizeAndEnqueue() }
            } label: {
                HStack {
                    Spacer()
                    if isAuthorizing {
                        ProgressView().tint(.white)
                    }
                    Text(queueButtonTitle)
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            .listRowBackground(canQueue ? Color.accentColor : Color.gray.opacity(0.3))
            .foregroundStyle(canQueue ? .white : .secondary)
            .disabled(!canQueue)
            if !canQueue && !isAuthorizing {
                Text(whyDisabled)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let authorizationError {
                Label(authorizationError, systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } footer: {
            Text("Each job runs as its own signing operation — an isolated workspace, its own log, independent verification — and its verified artifact is committed to Exports and recorded in the signing history. The queue keeps working while you use the rest of ZynSign.")
        }
    }

    private var queueButtonTitle: String {
        switch signableEntries.count {
        case 0: return "Add to Queue"
        case 1: return "Add to Signing Queue"
        default: return "Add \(signableEntries.count) Apps to Queue"
        }
    }

    private var whyDisabled: String {
        if signableEntries.isEmpty { return "No selected application has an available package file." }
        if selectedIdentityID == nil { return "Select a signing identity." }
        if profileData == nil { return "Choose a provisioning profile." }
        return "Resolve the requirements above to queue."
    }

    // MARK: - Success

    private func successContent(_ count: Int) -> some View {
        VStack(spacing: ZSpacing.lg) {
            Spacer()
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(count == 1 ? "1 Job Queued" : "\(count) Jobs Queued")
                .font(.title2.weight(.semibold))
            Text("The queue owns the work now. Jobs run one at a time, \(priority.displayName.lowercased()) priority first, and each verified artifact is added to Exports.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if skippedUnavailableCount > 0 {
                Text("\(skippedUnavailableCount) application(s) were skipped: no available package file.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: ZSpacing.xs) {
                Button {
                    onDone()
                    // The dashboard is presented by the shell after this
                    // sheet has gone away — presenting over a dismissing
                    // sheet would race, so the hand-off waits one beat.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        onOpenQueue()
                    }
                } label: {
                    Label("Open Signing Queue", systemImage: "list.bullet.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button("Done") { onDone() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, ZSpacing.xl)
            Spacer()
        }
        .padding()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(count) signing jobs queued at \(priority.displayName) priority")
    }

    // MARK: - Actions

    private func loadIdentities() async {
        isLoadingIdentities = true
        defer { isLoadingIdentities = false }
        do {
            identities = try env.identityStore.listIdentities()
            identitiesError = nil
            if selectedIdentityID == nil,
               let first = identities.first(where: { $0.isUsableForSigning }) ?? identities.first {
                selectedIdentityID = first.id
            }
        } catch let error as ZynSignError {
            identitiesError = error.userMessage
        } catch {
            identitiesError = "Secure identity storage could not be accessed."
        }
    }

    private func loadProfileSummaries() async {
        guard let profiles = env.provisioningProfiles else {
            profileSummaries = []
            return
        }
        profileSummaries = (try? await profiles.allProfiles()) ?? []
    }

    /// Selects a profile the library already holds: its bytes are read
    /// through the profile library itself, never re-picked and never copied
    /// by the sheet — the queue keeps its own copy once the job is accepted.
    private func selectLibraryProfile(_ summary: ProvisioningProfileSummary) {
        Task { await loadLibraryProfile(summary) }
    }

    private func loadLibraryProfile(_ summary: ProvisioningProfileSummary) async {
        guard let profiles = env.provisioningProfiles,
              let data = try? await profiles.profileBytes(withID: summary.id),
              !data.isEmpty else {
            profileError = "The profile's stored file could not be read. Choose it from Files instead."
            return
        }
        profileData = data
        profileName = summary.name
        profileTeam = summary.teamIdentifier
        profileError = nil
        selectedProfileSummaryID = summary.id
        ZHaptics.tap()
    }

    private func handleProfilePicker(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let ext = url.pathExtension.lowercased()
            guard ext == "mobileprovision" || ext == "provisionprofile" else {
                profileError = "The selected file is not a provisioning profile. Choose a .mobileprovision file."
                return
            }
            guard let data = try? Data(contentsOf: url), !data.isEmpty, data.count <= 10 * 1024 * 1024 else {
                profileError = "The profile could not be read or is too large."
                return
            }
            profileData = data
            profileName = url.lastPathComponent
            let summary = ProfileEntitlementDerivation.displaySummary(fromProvisioningProfile: data)
            if let name = summary?.name { profileName = name }
            profileTeam = summary?.teamIdentifier
            profileError = nil
            selectedProfileSummaryID = nil
        case .failure(let error):
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return }
            profileError = (error as? ZynSignError)?.userMessage
                ?? "The file picker could not provide the selected profile."
        }
    }

    /// Consults ZynSign's lock, then queues. The lock asks only when the
    /// user requires authentication before sensitive actions (or ZynSign is
    /// locked); a failed or cancelled attempt queues nothing and says why.
    private func authorizeAndEnqueue() async {
        guard canQueue else { return }
        isAuthorizing = true
        authorizationError = nil
        let outcome = await appLock.authorize(.sign)
        isAuthorizing = false
        guard outcome.isAuthenticated else {
            authorizationError = outcome.message
            return
        }
        enqueueJobs()
    }

    /// Builds one submission per signable entry and hands them to the queue
    /// in the order the user selected them.
    private func enqueueJobs() {
        guard let identityID = selectedIdentityID, let profile = profileData else { return }
        let identity = selectedIdentity
        let signable = signableEntries
        guard !signable.isEmpty else { return }
        ZHaptics.tap()
        for entry in signable {
            let submission = SigningJobSubmission(
                recordID: entry.record.id,
                artifactID: entry.record.artifact.artifactID,
                applicationName: entry.record.displayName ?? entry.record.bundleIdentifier.rawValue,
                bundleIdentifier: entry.record.bundleIdentifier.rawValue,
                versionText: ApplicationLibraryRowContent(entry: entry).versionText,
                identityID: identityID,
                identityDisplayName: identity?.displayName,
                certificateFingerprint: identity?.fingerprint,
                profile: profile,
                profileDisplayName: profileName,
                profileTeamIdentifier: profileTeam,
                emitDEREntitlements: emitDEREntitlements
            )
            queue.enqueue(submission, priority: priority, origin: origin)
        }
        skippedUnavailableCount = entries.count - signable.count
        queuedCount = signable.count
        env.recordAnalyticsEvent(
            category: .signing,
            name: signable.count == 1 ? "queue.job.enqueued" : "queue.bulk.enqueued",
            succeeded: true
        )
    }
}

// MARK: - Presentation plumbing

/// The items a configuration sheet is presented for: the entries to queue
/// and where the request came from. Identifiable so any screen can drive
/// the sheet with `.sheet(item:)`.
struct SigningQueueConfigurationRequest: Identifiable, Equatable {

    let entries: [LibraryEntry]
    let origin: SigningJobOrigin

    var id: String {
        entries.map { $0.record.id.rawValue }.joined(separator: ",") + "|\(origin.rawValue)"
    }

    init(entries: [LibraryEntry], origin: SigningJobOrigin) {
        self.entries = entries
        self.origin = origin
    }

    init(entry: LibraryEntry, origin: SigningJobOrigin) {
        self.entries = [entry]
        self.origin = origin
    }
}

// MARK: - Preview

private struct SigningQueueConfigurationPreviewHost: View {
    private let environment = CompositionRoot.makeApplicationEnvironment()
    @State private var request: SigningQueueConfigurationRequest?

    var body: some View {
        Color(.systemGroupedBackground)
            .overlay {
                Button("Queue Preview…") {
                    request = SigningQueueConfigurationRequest(
                        entries: PreviewEntries.all,
                        origin: .library
                    )
                }
                .buttonStyle(.borderedProminent)
            }
            .sheet(item: $request) { request in
                SigningQueueConfigurationView(
                    entries: request.entries,
                    origin: request.origin
                )
            }
            .environment(\.applicationEnvironment, environment)
    }
}

private enum PreviewEntries {
    static let all: [LibraryEntry] = []
}

#Preview("Queue Configuration") {
    SigningQueueConfigurationPreviewHost()
}
