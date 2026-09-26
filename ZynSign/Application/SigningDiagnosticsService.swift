import Foundation

/// Only a bounded set of redacted snapshots is durable. The report and its
/// transient verified entitlement claims remain in memory for the signing UI.
protocol SigningDiagnosticsHistoryStore: Sendable {
    func recent(for recordID: ApplicationRecordIdentifier) async throws -> [SigningDiagnosticSnapshot]
    func append(_ snapshot: SigningDiagnosticSnapshot) async throws
    func remove(for recordID: ApplicationRecordIdentifier) async throws
}

struct SigningDiagnosticsAnalysis {
    let report: SigningDiagnosticsReport
    /// Exactly the claims prepared from the authenticated selected profile.
    /// Never persisted or inferred from an unauthenticated plist fragment.
    let entitlements: CodeSigningEntitlements?
    let history: [SigningDiagnosticSnapshot]
    /// Comparison with the last stored observation, including identical
    /// scans which update the latest timestamp without filling the journal.
    let changes: SigningDiagnosticChanges?
    let historyUnavailable: Bool
}

/// Proactive, read-only analysis. An actor serializes archive/cache access;
/// the archive scan runs off the main actor and is reused when only the
/// identity, profile or DER option changes. Both caches are short-lived and
/// keyed by content/reference, never by a user-supplied filename. Expiry and
/// policy are evaluated afresh even on a cache hit. A forced scan (e.g. just
/// before signing) bypasses the archive cache.
actor SigningDiagnosticsService {
    private let library: ApplicationLibrary
    private let readerProvider: any ArtifactArchiveReaderProvider
    private let identities: any IdentityStore
    private let profilePipeline: ValidateProvisioningProfileUseCase
    private let policy: ValidateProvisioningConfigurationUseCase
    private let digest: any MessageDigest
    private let historyStore: any SigningDiagnosticsHistoryStore
    private let limits: ArchiveLimits
    private let now: @Sendable () -> Date

    private struct CachedPackage {
        let reference: ArtifactReference
        let scannedAt: Date
        let evidence: SigningPackageEvidence
    }
    private struct CachedProfile {
        let digest: Digest
        let scannedAt: Date
        let result: ProvisioningProfilePipelineResult
    }
    private var packages: [ApplicationRecordIdentifier: CachedPackage] = [:]
    private var profileCache: CachedProfile?
    private let cacheLifetime: TimeInterval = 60

    init(
        library: ApplicationLibrary,
        readerProvider: any ArtifactArchiveReaderProvider,
        identities: any IdentityStore,
        profilePipeline: ValidateProvisioningProfileUseCase,
        policy: ValidateProvisioningConfigurationUseCase,
        digest: any MessageDigest,
        historyStore: any SigningDiagnosticsHistoryStore,
        limits: ArchiveLimits = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.library = library
        self.readerProvider = readerProvider
        self.identities = identities
        self.profilePipeline = profilePipeline
        self.policy = policy
        self.digest = digest
        self.historyStore = historyStore
        self.limits = limits
        self.now = now
    }

    /// Looks up the current library entry, rather than trusting a view's old
    /// availability flag. Package/metadata/nested-code reads are bounded,
    /// read-only and off the UI actor. No failure silently becomes "ready".
    func analyze(
        recordWithID id: ApplicationRecordIdentifier,
        identityID: SigningIdentityIdentifier? = nil,
        profileData: Data? = nil,
        emitDEREntitlements: Bool = false,
        force: Bool = false
    ) async throws -> SigningDiagnosticsAnalysis {
        try Task.checkCancellation()
        guard let entry = try await library.entry(withID: id) else {
            throw SigningDiagnosticsError.recordUnavailable
        }
        try Task.checkCancellation()
        let date = now()
        let package = packageEvidence(for: entry, at: date, force: force)
        try Task.checkCancellation()
        let identity = identityEvidence(for: identityID)
        let (profile, claims) = profileEvidence(
            data: profileData,
            application: metadata(in: package),
            identityID: identityID,
            at: date
        )
        try Task.checkCancellation()
        let report = SigningDiagnosticsEvaluation.evaluate(
            record: entry.record, package: package, identity: identity,
            profile: profile, emitDEREntitlements: emitDEREntitlements, at: date
        )
        let snapshot = SigningDiagnosticSnapshot(report: report)
        var history: [SigningDiagnosticSnapshot] = []
        var changes: SigningDiagnosticChanges?
        var historyUnavailable = false
        do {
            history = try await historyStore.recent(for: id)
            try Task.checkCancellation()
            changes = snapshot.changes(since: history.first)
            try await historyStore.append(snapshot)
            history = try await historyStore.recent(for: id)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // History is a convenience, not a license to suppress current
            // evidence. A failed write/read is visible and never fabricated.
            historyUnavailable = true
        }
        try Task.checkCancellation()
        return SigningDiagnosticsAnalysis(
            report: report, entitlements: claims,
            history: history, changes: changes,
            historyUnavailable: historyUnavailable
        )
    }

    /// Called when the Keychain registrations change. The CMS relationship
    /// includes the locally listed identities, so it must not be reused.
    func identitiesDidChange() { profileCache = nil }

    /// Called after an artifact is replaced or removed. New records get a
    /// distinct ID; this also bounds a session's in-memory cache.
    func invalidate(recordWithID id: ApplicationRecordIdentifier) { packages.removeValue(forKey: id) }

    private func metadata(in evidence: SigningPackageEvidence) -> ApplicationMetadata? {
        if case .inspected(let inspection) = evidence, inspection.validation.isValid {
            return inspection.metadata
        }
        return nil
    }

    private func packageEvidence(for entry: LibraryEntry, at date: Date, force: Bool) -> SigningPackageEvidence {
        let record = entry.record
        guard entry.isArtifactAvailable else {
            packages.removeValue(forKey: record.id)
            switch entry.artifactAvailability {
            case .missing: return .missing
            case .inconsistent: return .changed
            case .available: return .unreadable
            }
        }
        if !force, let cached = packages[record.id],
           cached.reference == record.artifact,
           date.timeIntervalSince(cached.scannedAt) >= 0,
           date.timeIntervalSince(cached.scannedAt) < cacheLifetime {
            return cached.evidence
        }
        let evidence = scanPackage(record: record)
        packages[record.id] = CachedPackage(reference: record.artifact, scannedAt: date, evidence: evidence)
        // Keep only a small working set; no app bytes are retained in it.
        if packages.count > 24,
           let oldest = packages.min(by: { $0.value.scannedAt < $1.value.scannedAt })?.key {
            packages.removeValue(forKey: oldest)
        }
        return evidence
    }

    private func scanPackage(record: ApplicationRecord) -> SigningPackageEvidence {
        let reader: any ArchiveReader
        do { reader = try readerProvider.archiveReader(for: record.artifact.artifactID) }
        catch { return .unreadable }
        defer { reader.close() }
        let table: [ArchiveEntry]
        do { table = try reader.readEntryTable() }
        catch { return .unreadable }
        let inspected = IPAStructureValidator(limits: limits).validate(entryTable: table)
        guard inspected.isValid, let bundle = inspected.bundle else {
            return .inspected(SigningPackageInspection(
                validation: inspected.validation, metadata: nil,
                metadataFailure: nil, executablePresent: false,
                discovery: nil, images: .unchecked
            ))
        }
        guard let info = IPALayout.bundleInformationPath(within: bundle.bundlePath),
              table.contains(where: { $0.path == info && $0.kind == .regularFile }) else {
            return .inspected(SigningPackageInspection(
                validation: inspected.validation, metadata: nil,
                metadataFailure: .missingInfoPlist, executablePresent: false,
                discovery: nil, images: .unchecked
            ))
        }
        let bytes: Data
        do { bytes = try reader.readEntryData(at: info, maximumBytes: limits.maximumInspectionReadBytes) }
        catch {
            return .inspected(SigningPackageInspection(
                validation: inspected.validation, metadata: nil,
                metadataFailure: .unreadableInfoPlist, executablePresent: false,
                discovery: nil, images: .unchecked
            ))
        }
        let metadataResult = ApplicationMetadataReader.read(from: bytes)
        guard let metadata = metadataResult.metadata else {
            return .inspected(SigningPackageInspection(
                validation: inspected.validation, metadata: nil,
                metadataFailure: metadataResult.findings.first?.code,
                executablePresent: false, discovery: nil, images: .unchecked
            ))
        }
        let executablePath = metadata.executableName.flatMap { bundle.bundlePath.appending(component: $0) }
        let executablePresent = executablePath.map { candidate in
            table.contains(where: { $0.path == candidate && $0.kind == .regularFile })
        } ?? false
        guard executablePresent else {
            return .inspected(SigningPackageInspection(
                validation: inspected.validation, metadata: metadata,
                metadataFailure: nil, executablePresent: false,
                discovery: nil, images: .unchecked
            ))
        }
        let discovery = NestedCodeDiscovery.discover(
            entryTable: table,
            request: NestedCodeDiscoveryRequest(
                bundlePath: bundle.bundlePath,
                applicationIdentity: NestedCodeBundleIdentity(metadata: metadata)
            ),
            source: ArchiveNestedCodeInspectionSource(reader: reader, limits: limits)
        )
        let images = imageSupport(for: discovery, bundle: bundle.bundlePath, reader: reader)
        return .inspected(SigningPackageInspection(
            validation: inspected.validation, metadata: metadata,
            metadataFailure: nil, executablePresent: true,
            discovery: discovery, images: images
        ))
    }

    private func imageSupport(
        for discovery: NestedCodeDiscoveryOutcome,
        bundle: ArchivePath, reader: any ArchiveReader
    ) -> SigningImageSupport {
        guard case .plan(let plan) = discovery else { return .unchecked }
        let root = supportsSigningImage(plan.root, bundle: bundle, reader: reader)
        let nested = plan.nestedItems.map { supportsSigningImage($0, bundle: bundle, reader: reader) }
        let nestedStatus: Bool? = nested.contains(where: { $0 == false }) ? false :
            (nested.contains(where: { $0 == nil }) ? nil : true)
        return SigningImageSupport(rootSupported: root, nestedSupported: nestedStatus)
    }

    /// Reads only established, unsigned executables that discovery named.
    /// Both the parser and the signer's image policy are the SAME ones used
    /// during signing. A signed image is handled by the signature check, not
    /// misreported as an unsupported *unsigned* image.
    private func supportsSigningImage(
        _ item: NestedCodeItem, bundle: ArchivePath, reader: any ArchiveReader
    ) -> Bool? {
        guard item.status.isEstablished, item.existingSignature == .absent,
              let executable = item.executablePath else { return nil }
        var path = bundle
        for component in executable.components {
            guard let next = path.appending(component: component) else { return false }
            path = next
        }
        do {
            let bytes = try reader.readEntryData(at: path, maximumBytes: limits.maximumInspectionReadBytes)
            let image = try ReadOnlyMachOParser().parse(bytes)
            try SignMachOUseCase.checkSupportedImage(image)
            return true
        } catch let error as MachOSigningError {
            if case .unsupportedMachOForm = error { return false }
            return nil
        } catch is MachOParsingError {
            return false
        } catch {
            return nil
        }
    }

    private func identityEvidence(for id: SigningIdentityIdentifier?) -> SigningIdentityEvidence {
        guard let id else { return .notSelected }
        do {
            guard let identity = try identities.identity(withID: id) else { return .unavailable }
            return .selected(identity)
        } catch { return .storeUnavailable }
    }

    private func profileEvidence(
        data: Data?, application: ApplicationMetadata?,
        identityID: SigningIdentityIdentifier?, at date: Date
    ) -> (SigningProfileEvidence, CodeSigningEntitlements?) {
        guard let data else { return (.notSelected, nil) }
        let fingerprint = try? digest.digest(data, algorithm: .sha256)
        let result: ProvisioningProfilePipelineResult
        if let fingerprint, let cached = profileCache,
           cached.digest == fingerprint,
           date.timeIntervalSince(cached.scannedAt) >= 0,
           date.timeIntervalSince(cached.scannedAt) < cacheLifetime {
            result = cached.result
        } else {
            do {
                result = try profilePipeline.validate(ValidateProvisioningProfileRequest(
                    profile: .bytes(data), applicationMetadata: application
                ))
            } catch {
                return (.failed(.unreadable), nil)
            }
            if let fingerprint {
                profileCache = CachedProfile(digest: fingerprint, scannedAt: date, result: result)
            } else {
                profileCache = nil
            }
        }
        // The pipeline's overall status ALSO incorporates the configuration
        // policy from its first caller. Only its container/structural evidence
        // is cached by profile digest; never use that overall status to label
        // a profile unsupported in another app or after an option change.
        let inputUnsupported = result.findings.contains {
            $0.stage != .policyValidation && $0.severity == .unsupported
        }
        guard result.isProfileAuthenticated else {
            // A CMS rejection, unsupported verification, and an unevaluated
            // CMS are three different observations; none yields claims.
            let rejected = result.findings.contains {
                $0.stage == .cmsVerification && $0.severity == .rejected
            }
            return (.failed(rejected ? .unauthenticated :
                    (inputUnsupported ? .unsupported : .unreadable)), nil)
        }
        guard result.isStructurallyValid, let verified = result.verification,
              let parsed = result.profile else {
            return (.failed(inputUnsupported ? .unsupported : .invalid), nil)
        }
        let claims = parsed.entitlements.flatMap { try? CodeSigningEntitlements(profileEntitlements: $0) }
        let policyResult = policy.validate(ValidateProvisioningConfigurationRequest(
            verification: verified,
            applicationMetadata: application,
            signingIdentityID: identityID,
            signingConfiguration: SigningConfiguration(entitlements: claims?.profileEntitlements)
        ))
        return (.verified(policy: policyResult, expiration: parsed.expirationDate, claimsRepresentable: claims != nil), claims)
    }
}

enum SigningDiagnosticsError: Error {
    case recordUnavailable

    var userMessage: String { "This app is no longer in the library. Re-open the library and try again." }
}
