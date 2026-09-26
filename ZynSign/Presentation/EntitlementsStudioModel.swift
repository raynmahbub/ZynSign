import Foundation
import Combine

/// One session owned by App Details, shared by Signing and the Studio. Parsed
/// app claims and profile declarations are retained once; analysis has a single
/// bounded cache entry, automatically invalidated by every effective input.
@MainActor
final class EntitlementsStudioModel: ObservableObject {
    @Published var identities: [SigningIdentity] = [] { didSet { updateAnalysis() } }
    @Published var selectedIdentityID: SigningIdentityIdentifier? { didSet { updateAnalysis() } }
    @Published var emitDEREntitlements = false { didSet { updateAnalysis() } }
    @Published private(set) var profileData: Data?
    @Published private(set) var profileFileName: String?
    @Published private(set) var profile: ProvisioningProfile?
    @Published private(set) var signingEntitlements: CodeSigningEntitlements?
    @Published private(set) var profileError: String?
    @Published private(set) var isParsingProfile = false
    @Published private(set) var targets: [EntitlementStudioTarget] = []
    @Published var selectedTargetID = 0 { didSet { updateAnalysis() } }
    @Published private(set) var isLoading = false
    @Published private(set) var inspectionError: String?
    @Published private(set) var analysis: EntitlementStudioAnalysis?
    @Published private(set) var signingBlocked = false
    private var entry: LibraryEntry?
    private var loadedArtifact: ArtifactIdentifier?
    private var analysisTask: Task<Void, Never>?
    private var profileTask: Task<Void, Never>?
    private var revision = 0
    private var profileRevision = 0
    private var cachedInput: Input?

    private struct Input: Equatable {
        let app: CodeSigningEntitlements?
        let targets: [EntitlementStudioTarget]
        let profile: ProvisioningProfile?
        let bundleID: BundleIdentifier
        let certificateTeam: String?
        let identityID: SigningIdentityIdentifier?
        let certificateFingerprint: CertificateFingerprint?
        let emitDER: Bool
        let note: String
    }

    var selectedIdentity: SigningIdentity? { identities.first { $0.id == selectedIdentityID } }
    var target: EntitlementStudioTarget? { targets.first { $0.id == selectedTargetID } }

    func load(entry: LibraryEntry, inspection: IPABundleContentsInspection) async {
        guard !isLoading else { return }
        self.entry = entry
        guard loadedArtifact != entry.record.artifact.artifactID else { updateAnalysis(); return }
        isLoading = true
        cachedInput = nil
        targets = []
        analysis = nil
        inspectionError = nil
        defer { isLoading = false }
        do {
            // Navigation may cancel the caller's SwiftUI task. The bounded,
            // session-owned read still completes for the next screen.
            let worker = Task { try await inspection.inspectEntitlements(recordWithID: entry.record.id) }
            let result = try await worker.value
            targets = result
            loadedArtifact = entry.record.artifact.artifactID
            selectedTargetID = result.first?.id ?? 0
        } catch is CancellationError { return }
        catch {
            inspectionError = "The main executable could not be inspected within the supported format and 64 MB read limit. Re-import an intact package. Entitlements remain unknown."
        }
        updateAnalysis()
    }

    func retry(entry: LibraryEntry, inspection: IPABundleContentsInspection) async {
        loadedArtifact = nil
        await load(entry: entry, inspection: inspection)
    }

    func removeProfile() {
        profileRevision += 1
        profileTask?.cancel()
        isParsingProfile = false
        profile = nil; signingEntitlements = nil; profileData = nil; profileFileName = nil; profileError = nil
        updateAnalysis()
    }

    func selectProfileFile(_ url: URL) {
        startProfileLoad(name: url.lastPathComponent) { try EntitlementsStudioInspection.readProfileFile(url) }
    }

    func selectProfile(data: Data, name: String) {
        startProfileLoad(name: name) { data }
    }

    private func startProfileLoad(name: String, read: @escaping @Sendable () throws -> Data) {
        removeProfile()
        isParsingProfile = true
        let generation = profileRevision
        profileTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let data = try read()
                let parsed = try EntitlementsStudioInspection.parseProfile(data)
                try Task.checkCancellation()
                let signingClaims = parsed.entitlements.flatMap { try? CodeSigningEntitlements(profileEntitlements: $0) }
                return (data, parsed, signingClaims)
            }
            let result = await withTaskCancellationHandler(operation: { try? await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, generation == profileRevision else { return }
            if let (data, parsed, signingClaims) = result {
                profile = parsed; profileData = data; profileFileName = name
                signingEntitlements = signingClaims
            } else {
                profileError = "The selected profile could not be read or parsed within the 10 MB input limit. Choose a valid .mobileprovision file; the previous profile was cleared."
            }
            updateAnalysis()
            isParsingProfile = false
        }
    }

    func updateAnalysis() {
        guard let entry else { return }
        let input = Input(app: target?.entitlements, targets: targets, profile: profile,
                          bundleID: entry.record.bundleIdentifier,
                          certificateTeam: selectedIdentity?.certificate.subject.organizationalUnit,
                          identityID: selectedIdentityID,
                          certificateFingerprint: selectedIdentity?.certificate.sha256Fingerprint, emitDER: emitDEREntitlements,
                          note: target?.note ?? inspectionError ?? "App entitlement inspection has not completed.")
        guard input != cachedInput else { return }
        cachedInput = input
        revision += 1
        let generation = revision
        analysisTask?.cancel()
        analysis = nil // Never show a verdict from the previous selection.
        analysisTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                let selected = EntitlementsStudioAnalyzer.analyze(app: input.app, profile: input.profile, bundleID: input.bundleID,
                                                                  certificateTeam: input.certificateTeam, emitDER: input.emitDER,
                                                                  sourceNote: input.note)
                let blocked = selected.status == .blocked || input.targets.contains { target in
                    guard !Task.isCancelled else { return false }
                    if target.entitlements == input.app { return false }
                    return EntitlementsStudioAnalyzer.analyze(app: target.entitlements, profile: input.profile,
                                                             bundleID: input.bundleID, certificateTeam: input.certificateTeam,
                                                             emitDER: input.emitDER, sourceNote: target.note).status == .blocked
                }
                return (selected, blocked)
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, generation == revision else { return }
            signingBlocked = result.1
            analysis = result.0
        }
    }
}
