import Foundation

/// Independently verifies one exported artifact by reopening its bytes.
///
/// Verification takes nothing on trust. It does not consult the signing run
/// that produced the artifact, it does not read the run's report, and it does
/// not share working state with it: every fact in its report was read from the
/// artifact in front of it, through the same read-only parsers and inspectors
/// the rest of ZynSign uses.
///
/// What it checks, in order:
///
/// 1. **Presence** — the artifact is held in export storage.
/// 2. **Container** — the package's structure, re-validated from its entry
///    table.
/// 3. **Metadata** — the bundle's declared identity, re-parsed from its
///    information file.
/// 4. **Executable** — the declared executable exists, is a regular file, is a
///    Mach-O image this build parses, and carries a code signature whose
///    CodeDirectory is readable.
/// 5. **Signature coherence** — the CodeDirectory's identifier is held against
///    the bundle's declared identifier, and the entitlements slot is decoded.
/// 6. **Resource seal** — `_CodeSignature/CodeResources` is parsed, its own
///    SHA-256 is held against the CodeDirectory's slot-3 digest, and every
///    sealed file resource it covers is re-read and re-digested.
/// 7. **Nested code** — every nested code bundle the bundle carries is
///    inspected for a signature of its own.
/// 8. **Embedded profile** — `embedded.mobileprovision` is decoded, parsed,
///    and held against the bundle's identifier and the current instant.
///
/// What it deliberately does not do, and never claims:
///
/// - cryptographic trust is not evaluated: no certificate chain, no trust
///   anchor, no platform policy;
/// - the platform's authorization and installability are not concluded;
/// - a `valid` report means the artifact is internally coherent against the
///   checks above, and nothing more.
///
/// Verification is total: a missing artifact, an unreadable container, and a
/// bound being reached are all reported as findings, with `unsupported`
/// standing for "this check could not conclude" — never for success. Only
/// cancellation propagates as an error.
struct VerifyExportedArtifact {

    private let makeReader: (URL) -> any ArchiveReader
    let digest: any MessageDigest
    let inspector: MachOCodeSignatureInspector
    private let metadataInspector: EmbeddedSigningMetadataInspector
    let profileDecoder: (any ProvisioningProfilePayloadDecoder)?
    let profileParser: any ProvisioningProfileParser
    let limits: ArtifactVerificationLimits
    let archiveLimits: ArchiveLimits
    let now: @Sendable () -> Date

    init(
        makeReader: @escaping (URL) -> any ArchiveReader = { ZipArchiveReader(location: $0) },
        digest: any MessageDigest,
        inspector: MachOCodeSignatureInspector = MachOCodeSignatureInspector(),
        metadataInspector: EmbeddedSigningMetadataInspector = EmbeddedSigningMetadataInspector(),
        profileDecoder: (any ProvisioningProfilePayloadDecoder)? = nil,
        profileParser: any ProvisioningProfileParser = PropertyListProvisioningProfileParser(),
        limits: ArtifactVerificationLimits = .default,
        archiveLimits: ArchiveLimits = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.makeReader = makeReader
        self.digest = digest
        self.inspector = inspector
        self.metadataInspector = metadataInspector
        self.profileDecoder = profileDecoder
        self.profileParser = profileParser
        self.limits = limits
        self.archiveLimits = archiveLimits
        self.now = now
    }

    private struct PackageContext {
        let table: [ArchiveEntry]
        let bundlePath: ArchivePath
        let declaredBundleIdentifier: String
        let executableBytes: Data
    }

    private struct MainSignatureInspection {
        let declaredSealDigest: Data?
    }

    private enum SignatureSliceResult {
        case rejected
        case accepted(sealDigest: Data?)
    }

    /// Verifies the artifact at `location`.
    ///
    /// - Returns: The report, whose status is `valid`, `invalid`, `warning`,
    ///   or `unsupported`. A report is always returned for an artifact that
    ///   can be looked at; nothing about the artifact is thrown.
    /// - Throws: `CancellationError` when the surrounding task is cancelled.
    func verify(artifactAt location: URL) async throws -> ArtifactVerificationReport {
        try Task.checkCancellation()
        let verifiedAt = now()
        guard let byteCount = Self.regularFileByteCount(at: location) else {
            var collector = ArtifactVerificationCollector()
            collector.record(
                .artifactUnavailable,
                .unsupported,
                "The artifact is not held in export storage, so verification had nothing to read."
            )
            return collector.report(verifiedAt: verifiedAt, artifactByteCount: nil)
        }
        let reader = makeReader(location)
        defer { reader.close() }
        return try verify(reader: reader, byteCount: byteCount, verifiedAt: verifiedAt)
    }

    private func verify(
        reader: any ArchiveReader,
        byteCount: Int,
        verifiedAt: Date
    ) throws -> ArtifactVerificationReport {
        var collector = ArtifactVerificationCollector()
        guard let package = try packageContext(
            reader: reader,
            collector: &collector
        ) else {
            return collector.report(verifiedAt: verifiedAt, artifactByteCount: byteCount)
        }
        guard let signature = inspectMainSignatures(
            package,
            collector: &collector
        ) else {
            return collector.report(verifiedAt: verifiedAt, artifactByteCount: byteCount)
        }
        collector.record(.trustNotEvaluated, .note, Self.trustNote)
        try Task.checkCancellation()
        try verifyResourceSeal(
            reader: reader,
            table: package.table,
            bundlePath: package.bundlePath,
            declaredSealDigest: signature.declaredSealDigest,
            collector: &collector
        )
        try Task.checkCancellation()
        try verifyNestedCode(
            reader: reader,
            table: package.table,
            bundlePath: package.bundlePath,
            collector: &collector
        )
        try Task.checkCancellation()
        try verifyEmbeddedProfile(
            reader: reader,
            bundlePath: package.bundlePath,
            declaredBundleIdentifier: package.declaredBundleIdentifier,
            collector: &collector
        )
        return collector.report(verifiedAt: verifiedAt, artifactByteCount: byteCount)
    }

    private func packageContext(
        reader: any ArchiveReader,
        collector: inout ArtifactVerificationCollector
    ) throws -> PackageContext? {
        guard let container = try readContainer(reader, collector: &collector) else {
            return nil
        }
        guard let metadata = try readBundleMetadata(
            reader,
            bundlePath: container.bundlePath,
            collector: &collector
        ) else {
            return nil
        }
        guard let executableBytes = try readMainExecutable(
            reader,
            table: container.table,
            bundlePath: container.bundlePath,
            metadata: metadata,
            collector: &collector
        ) else {
            return nil
        }
        return PackageContext(
            table: container.table,
            bundlePath: container.bundlePath,
            declaredBundleIdentifier: metadata.identity.bundleIdentifier.rawValue,
            executableBytes: executableBytes
        )
    }

    private func readContainer(
        _ reader: any ArchiveReader,
        collector: inout ArtifactVerificationCollector
    ) throws -> (table: [ArchiveEntry], bundlePath: ArchivePath)? {
        let table: [ArchiveEntry]
        do {
            table = try reader.readEntryTable()
        } catch {
            collector.record(
                .containerUnreadable,
                .unsupported,
                "The artifact's container could not be read by this build."
            )
            return nil
        }
        try Task.checkCancellation()
        let structure = IPAStructureValidator(limits: archiveLimits).validate(entryTable: table)
        guard structure.isValid, let bundlePath = structure.bundle?.bundlePath else {
            collector.record(
                .containerStructure,
                .error,
                structure.validation.findings.first?.detail ?? "The package layout did not satisfy ZynSign's structural rules."
            )
            return nil
        }
        collector.record(
            .containerStructure,
            .note,
            "The container holds one application bundle at \(bundlePath.rawValue)."
        )
        return (table, bundlePath)
    }

    private func readBundleMetadata(
        _ reader: any ArchiveReader,
        bundlePath: ArchivePath,
        collector: inout ArtifactVerificationCollector
    ) throws -> ApplicationMetadata? {
        guard let informationPath = IPALayout.bundleInformationPath(within: bundlePath) else {
            collector.record(.bundleInformation, .error, "The bundle's information file cannot be named.")
            return nil
        }
        guard let informationBytes = try? reader.readEntryData(
            at: informationPath,
            maximumBytes: archiveLimits.maximumInspectionReadBytes
        ) else {
            collector.record(.bundleInformation, .error, "The bundle's information file could not be read.")
            return nil
        }
        let examination = ApplicationMetadataReader.read(from: informationBytes)
        guard examination.isValid, let metadata = examination.metadata else {
            collector.record(
                .bundleInformation,
                .error,
                examination.findings.first?.detail ?? "The bundle's declared metadata failed validation."
            )
            return nil
        }
        let identifier = metadata.identity.bundleIdentifier.rawValue
        collector.record(.bundleInformation, .note, "The bundle declares identifier \(identifier).")
        try Task.checkCancellation()
        return metadata
    }

    private func readMainExecutable(
        _ reader: any ArchiveReader,
        table: [ArchiveEntry],
        bundlePath: ArchivePath,
        metadata: ApplicationMetadata,
        collector: inout ArtifactVerificationCollector
    ) throws -> Data? {
        guard let executableName = metadata.executableName,
              let executablePath = bundlePath.appending(component: executableName) else {
            collector.record(.executableMissing, .error, "The bundle declares no usable executable name.")
            return nil
        }
        guard table.first(where: { $0.path == executablePath })?.kind == .regularFile else {
            collector.record(
                .executableMissing,
                .error,
                "The declared executable is not a regular file inside the bundle."
            )
            return nil
        }
        guard let executableBytes = try? reader.readEntryData(
            at: executablePath,
            maximumBytes: limits.maximumExecutableBytes
        ) else {
            collector.record(
                .executableUnreadable,
                .unsupported,
                "The declared executable is larger than verification reads, so its signature was not inspected."
            )
            return nil
        }
        try Task.checkCancellation()
        return executableBytes
    }

    private func inspectMainSignatures(
        _ package: PackageContext,
        collector: inout ArtifactVerificationCollector
    ) -> MainSignatureInspection? {
        guard let slices = signatureSlices(in: package.executableBytes, collector: &collector) else {
            return nil
        }
        var sealDigest: Data?
        for slice in slices {
            switch inspectSignatureSlice(slice, package: package, collector: &collector) {
            case .rejected:
                return nil
            case .accepted(let declared):
                if let declared { sealDigest = declared }
            }
        }
        return MainSignatureInspection(declaredSealDigest: sealDigest)
    }

    private func signatureSlices(
        in executableBytes: Data,
        collector: inout ArtifactVerificationCollector
    ) -> [MachOCodeSignatureSliceInspection]? {
        let inspection = inspector.inspect(bytes: executableBytes)
        let slices: [MachOCodeSignatureSliceInspection]
        switch inspection {
        case .thin(let slice):
            slices = [slice]
        case .universal(let list):
            slices = list
        case .malformedMachO:
            collector.record(
                .executableFormat,
                .unsupported,
                "The declared executable is not a Mach-O image this build parses."
            )
            return nil
        case .malformedSignature(_, let state):
            collector.record(
                .signatureStructure,
                .error,
                "The executable's code-signature region is malformed (\(Self.describe(state)))."
            )
            return nil
        }
        guard !slices.isEmpty else {
            collector.record(.executableFormat, .unsupported, "The executable's architecture list is empty.")
            return nil
        }
        return slices
    }

    private func inspectSignatureSlice(
        _ slice: MachOCodeSignatureSliceInspection,
        package: PackageContext,
        collector: inout ArtifactVerificationCollector
    ) -> SignatureSliceResult {
        switch slice.existingSignature {
        case .absent:
            collector.record(.mainSignature, .error, "The main executable carries no code signature.")
            collector.record(.trustNotEvaluated, .note, Self.trustNote)
            return .rejected
        case .valid:
            return inspectValidSignature(slice, package: package, collector: &collector)
        case .malformedCommand, .invalidRegionOffset, .invalidRegionSize, .malformedRegion:
            collector.record(
                .signatureStructure,
                .error,
                "The executable's code-signature region is present but malformed."
            )
            return .rejected
        }
    }

    private func inspectValidSignature(
        _ slice: MachOCodeSignatureSliceInspection,
        package: PackageContext,
        collector: inout ArtifactVerificationCollector
    ) -> SignatureSliceResult {
        guard case .valid(let embedded) = slice.existingSignature else { return .rejected }
        collector.record(
            .mainSignature,
            .note,
            "The main executable carries a code signature with \(embedded.superBlob.count) blob entries."
        )
        guard let directoryEntry = embedded.superBlob.entries.first(where: { $0.slot == .codeDirectory }),
              let directory = directoryEntry.codeDirectory else {
            collector.record(.codeDirectory, .error, "The signature carries no readable CodeDirectory.")
            return .rejected
        }
        collector.record(
            .codeDirectory,
            .note,
            "CodeDirectory version 0x\(String(directory.version, radix: 16)) declares identifier \(directory.identifier)."
        )
        recordIdentifierComparison(directory.identifier, declared: package.declaredBundleIdentifier, collector: &collector)
        let metadata = metadataInspector.inspect(slice: slice.slice, artifact: package.executableBytes)
        recordEntitlements(metadata.entitlements, collector: &collector)
        let sealDigest = declaredSealDigest(metadata.codeResourcesSeal, collector: &collector)
        return .accepted(sealDigest: sealDigest)
    }

    private func recordIdentifierComparison(
        _ signatureIdentifier: String,
        declared bundleIdentifier: String,
        collector: inout ArtifactVerificationCollector
    ) {
        guard signatureIdentifier != bundleIdentifier else { return }
        collector.record(
            .codeDirectoryIdentifier,
            .warning,
            "The signature's identifier \(signatureIdentifier) differs from the bundle's declared identifier \(bundleIdentifier)."
        )
    }

    private func recordEntitlements(
        _ state: EmbeddedEntitlementsState,
        collector: inout ArtifactVerificationCollector
    ) {
        switch state {
        case .present(let entitlements):
            collector.record(
                .entitlements,
                .note,
                "The signature embeds \(entitlements.keys.count) entitlement claim\(entitlements.keys.count == 1 ? "" : "s")."
            )
        case .absent:
            collector.record(.entitlements, .warning, "The signature embeds no entitlements blob.")
        case .malformed:
            collector.record(.entitlements, .error, "The signature's entitlements blob could not be decoded.")
        }
    }

    private func declaredSealDigest(
        _ state: EmbeddedCodeResourcesSealState,
        collector: inout ArtifactVerificationCollector
    ) -> Data? {
        switch state {
        case .sealed(let declared):
            return declared
        case .notSealed:
            collector.record(
                .resourceSeal,
                .warning,
                "The signature records no resource-seal digest in its CodeDirectory."
            )
            return nil
        case .noCodeDirectory:
            collector.record(.codeDirectory, .error, "The signature carries no CodeDirectory to read a seal digest from.")
            return nil
        }
    }

    // MARK: - Helpers

    /// How many individual findings one check may add before it summarises.
    /// A container with thousands of mismatched resources is reported as a
    /// count, not as thousands of lines.
    static let maximumDetailedFindings = 8

    /// The fixed note about what verification does not establish.
    private static let trustNote =
        "Cryptographic trust was not evaluated: ZynSign reports what the artifact contains, not whether a platform would trust or install it."

    private static func describe(_ state: MachOExistingCodeSignatureState) -> String {
        switch state {
        case .absent: return "no signature present"
        case .valid: return "signature present"
        case .malformedCommand: return "malformed signature command"
        case .invalidRegionOffset: return "invalid signature region offset"
        case .invalidRegionSize: return "invalid signature region size"
        case .malformedRegion: return "malformed signature region"
        }
    }

    private static func regularFileByteCount(at location: URL) -> Int? {
        guard let values = try? location.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else {
            return nil
        }
        return max(0, values.fileSize ?? 0)
    }

    static func archivePath(bundle: ArchivePath, relative path: BundlePath) -> ArchivePath? {
        guard !path.rawValue.isEmpty else { return bundle }
        return ArchivePath(rawValue: bundle.rawValue + "/" + path.rawValue)
    }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

// MARK: - Finding collection

/// Collects findings and counts the checks that ran.
struct ArtifactVerificationCollector {

    private(set) var findings: [ArtifactVerificationFinding] = []
    private(set) var checksRun = 0

    mutating func record(
        _ code: ArtifactVerificationFindingCode,
        _ severity: ArtifactVerificationSeverity,
        _ detail: String
    ) {
        findings.append(ArtifactVerificationFinding(code: code, severity: severity, detail: detail))
        checksRun += 1
    }

    func report(verifiedAt: Date, artifactByteCount: Int?) -> ArtifactVerificationReport {
        ArtifactVerificationReport.derive(
            findings: findings,
            verifiedAt: verifiedAt,
            artifactByteCount: artifactByteCount,
            checksRun: checksRun
        )
    }
}

extension ArchiveReader {

    /// A non-throwing existence check for callers that treat absence as a
    /// finding rather than a failure.
    func containsEntrySafe(at path: ArchivePath) -> Bool {
        (try? containsEntry(at: path)) == true
    }
}
