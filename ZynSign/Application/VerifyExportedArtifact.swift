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
    private let digest: any MessageDigest
    private let inspector: MachOCodeSignatureInspector
    private let metadataInspector: EmbeddedSigningMetadataInspector
    private let profileDecoder: (any ProvisioningProfilePayloadDecoder)?
    private let profileParser: any ProvisioningProfileParser
    private let limits: ArtifactVerificationLimits
    private let archiveLimits: ArchiveLimits
    private let now: @Sendable () -> Date

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

    /// Verifies the artifact at `location`.
    ///
    /// - Returns: The report, whose status is `valid`, `invalid`, `warning`,
    ///   or `unsupported`. A report is always returned for an artifact that
    ///   can be looked at; nothing about the artifact is thrown.
    /// - Throws: `CancellationError` when the surrounding task is cancelled.
    func verify(artifactAt location: URL) async throws -> ArtifactVerificationReport {
        try Task.checkCancellation()
        let verifiedAt = now()
        var collector = FindingCollector()

        guard let byteCount = Self.regularFileByteCount(at: location) else {
            collector.record(
                .artifactUnavailable,
                .unsupported,
                "The artifact is not held in export storage, so verification had nothing to read."
            )
            return collector.report(verifiedAt: verifiedAt, artifactByteCount: nil)
        }

        let reader = makeReader(location)
        defer { reader.close() }

        let table: [ArchiveEntry]
        do {
            table = try reader.readEntryTable()
        } catch {
            collector.record(
                .containerUnreadable,
                .unsupported,
                "The artifact's container could not be read by this build."
            )
            return collector.report(verifiedAt: verifiedAt, artifactByteCount: byteCount)
        }
        try Task.checkCancellation()

        let structure = IPAStructureValidator(limits: archiveLimits).validate(entryTable: table)
        guard structure.isValid, let bundlePath = structure.bundle?.bundlePath else {
            collector.record(
                .containerStructure,
                .error,
                structure.validation.findings.first?.detail ?? "The package layout did not satisfy ZynSign's structural rules."
            )
            return collector.report(verifiedAt: verifiedAt, artifactByteCount: byteCount)
        }
        collector.record(
            .containerStructure,
            .note,
            "The container holds one application bundle at \(bundlePath.rawValue)."
        )

        guard let informationPath = IPALayout.bundleInformationPath(within: bundlePath) else {
            collector.record(.bundleInformation, .error, "The bundle's information file cannot be named.")
            return collector.report(verifiedAt: verifiedAt, artifactByteCount: byteCount)
        }
        guard let informationBytes = try? reader.readEntryData(
            at: informationPath,
            maximumBytes: archiveLimits.maximumInspectionReadBytes
        ) else {
            collector.record(.bundleInformation, .error, "The bundle's information file could not be read.")
            return collector.report(verifiedAt: verifiedAt, artifactByteCount: byteCount)
        }
        let examination = ApplicationMetadataReader.read(from: informationBytes)
        guard examination.isValid, let metadata = examination.metadata else {
            collector.record(
                .bundleInformation,
                .error,
                examination.findings.first?.detail ?? "The bundle's declared metadata failed validation."
            )
            return collector.report(verifiedAt: verifiedAt, artifactByteCount: byteCount)
        }
        let declaredBundleIdentifier = metadata.identity.bundleIdentifier.rawValue
        collector.record(.bundleInformation, .note, "The bundle declares identifier \(declaredBundleIdentifier).")
        try Task.checkCancellation()

        guard let executableName = metadata.executableName,
              let executablePath = bundlePath.appending(component: executableName) else {
            collector.record(.executableMissing, .error, "The bundle declares no usable executable name.")
            return collector.report(verifiedAt: verifiedAt, artifactByteCount: byteCount)
        }
        guard table.first(where: { $0.path == executablePath })?.kind == .regularFile else {
            collector.record(
                .executableMissing,
                .error,
                "The declared executable is not a regular file inside the bundle."
            )
            return collector.report(verifiedAt: verifiedAt, artifactByteCount: byteCount)
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
            return collector.report(verifiedAt: verifiedAt, artifactByteCount: byteCount)
        }
        try Task.checkCancellation()

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
            return collector.report(verifiedAt: verifiedAt, artifactByteCount: byteCount)
        case .malformedSignature(_, let state):
            collector.record(
                .signatureStructure,
                .error,
                "The executable's code-signature region is malformed (\(Self.describe(state)))."
            )
            return collector.report(verifiedAt: verifiedAt, artifactByteCount: byteCount)
        }
        guard !slices.isEmpty else {
            collector.record(.executableFormat, .unsupported, "The executable's architecture list is empty.")
            return collector.report(verifiedAt: verifiedAt, artifactByteCount: byteCount)
        }

        var sealDigestDeclared: Data?
        for slice in slices {
            switch slice.existingSignature {
            case .absent:
                collector.record(.mainSignature, .error, "The main executable carries no code signature.")
                collector.record(.trustNotEvaluated, .note, Self.trustNote)
                return collector.report(verifiedAt: verifiedAt, artifactByteCount: byteCount)
            case .valid(let embedded):
                collector.record(
                    .mainSignature,
                    .note,
                    "The main executable carries a code signature with \(embedded.superBlob.count) blob entries."
                )
                let directoryEntry = embedded.superBlob.entries.first { $0.slot == .codeDirectory }
                guard let directoryEntry, let directory = directoryEntry.codeDirectory else {
                    collector.record(.codeDirectory, .error, "The signature carries no readable CodeDirectory.")
                    return collector.report(verifiedAt: verifiedAt, artifactByteCount: byteCount)
                }
                collector.record(
                    .codeDirectory,
                    .note,
                    "CodeDirectory version 0x\(String(directory.version, radix: 16)) declares identifier \(directory.identifier)."
                )
                if directory.identifier != declaredBundleIdentifier {
                    collector.record(
                        .codeDirectoryIdentifier,
                        .warning,
                        "The signature's identifier \(directory.identifier) differs from the bundle's declared identifier \(declaredBundleIdentifier)."
                    )
                }
                let embeddedMetadata = metadataInspector.inspect(slice: slice.slice, artifact: executableBytes)
                switch embeddedMetadata.entitlements {
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
                switch embeddedMetadata.codeResourcesSeal {
                case .sealed(let declared):
                    sealDigestDeclared = declared
                case .notSealed:
                    collector.record(
                        .resourceSeal,
                        .warning,
                        "The signature records no resource-seal digest in its CodeDirectory."
                    )
                case .noCodeDirectory:
                    collector.record(.codeDirectory, .error, "The signature carries no CodeDirectory to read a seal digest from.")
                }
            case .malformedCommand, .invalidRegionOffset, .invalidRegionSize, .malformedRegion:
                collector.record(
                    .signatureStructure,
                    .error,
                    "The executable's code-signature region is present but malformed."
                )
                return collector.report(verifiedAt: verifiedAt, artifactByteCount: byteCount)
            }
        }
        collector.record(.trustNotEvaluated, .note, Self.trustNote)
        try Task.checkCancellation()

        try verifyResourceSeal(
            reader: reader,
            table: table,
            bundlePath: bundlePath,
            declaredSealDigest: sealDigestDeclared,
            collector: &collector
        )
        try Task.checkCancellation()

        try verifyNestedCode(reader: reader, table: table, bundlePath: bundlePath, collector: &collector)
        try Task.checkCancellation()

        try verifyEmbeddedProfile(
            reader: reader,
            bundlePath: bundlePath,
            declaredBundleIdentifier: declaredBundleIdentifier,
            collector: &collector
        )

        return collector.report(verifiedAt: verifiedAt, artifactByteCount: byteCount)
    }

    // MARK: - Resource seal

    /// Re-reads the resource seal and every file resource it covers.
    ///
    /// The seal is checked twice over. Its own bytes are digested and held
    /// against the CodeDirectory's slot-3 digest, which is what ties the seal
    /// to the signature; then each sealed file is re-read and re-digested,
    /// which is what ties the bundle's resources to the seal. Both are
    /// recomputed here from the artifact's bytes.
    private func verifyResourceSeal(
        reader: any ArchiveReader,
        table: [ArchiveEntry],
        bundlePath: ArchivePath,
        declaredSealDigest: Data?,
        collector: inout FindingCollector
    ) throws {
        guard let sealPath = ArchivePath(rawValue: bundlePath.rawValue + "/_CodeSignature/CodeResources") else {
            collector.record(.resourceSeal, .error, "The bundle's seal location cannot be named.")
            return
        }
        guard table.contains(where: { $0.path == sealPath }), reader.containsEntrySafe(at: sealPath) else {
            collector.record(.resourceSeal, .error, "The bundle carries no resource seal.")
            return
        }
        guard let sealBytes = try? reader.readEntryData(at: sealPath, maximumBytes: archiveLimits.maximumInspectionReadBytes) else {
            collector.record(.resourceSeal, .error, "The bundle's resource seal could not be read.")
            return
        }
        let seal: CodeResourcesDocument
        do {
            seal = try CodeResourcesParser.parse(sealBytes)
        } catch {
            collector.record(.resourceSeal, .error, "The bundle's resource seal could not be parsed.")
            return
        }
        collector.record(
            .resourceSeal,
            .note,
            "The resource seal records \(seal.files2.count) entr\(seal.files2.count == 1 ? "y" : "ies")."
        )

        switch declaredSealDigest {
        case .some(let declared):
            if let computed = try? digest.digest(sealBytes, algorithm: .sha256) {
                if computed.bytes == declared {
                    collector.record(.resourceSeal, .note, "The signature's seal digest matches the seal's own bytes.")
                } else {
                    collector.record(
                        .resourceSeal,
                        .error,
                        "The signature's recorded seal digest does not match the resource seal's own bytes."
                    )
                }
            } else {
                collector.record(.resourceSeal, .unsupported, "The resource seal could not be digested.")
            }
        case .none:
            collector.record(
                .resourceSeal,
                .warning,
                "The signature records no seal digest, so the seal is not bound to the signature."
            )
        }

        var checkedFiles = 0
        var readBytes = 0
        var mismatches = 0
        var unreadable = 0
        var skipped = 0
        var nestedChecked = 0
        var reachTotalBound = false

        for entry in seal.files2 {
            if checkedFiles + unreadable >= limits.maximumSealedResourceCount {
                reachTotalBound = true
                break
            }
            switch entry {
            case .file(let fileSeal):
                guard let path = Self.archivePath(bundle: bundlePath, relative: fileSeal.path) else {
                    skipped += 1
                    continue
                }
                guard let data = try? reader.readEntryData(at: path, maximumBytes: limits.maximumSealedResourceBytes) else {
                    unreadable += 1
                    continue
                }
                readBytes += data.count
                if readBytes > limits.maximumTotalSealedReadBytes {
                    reachTotalBound = true
                    break
                }
                guard let computed = try? digest.digest(data, algorithm: .sha256) else {
                    unreadable += 1
                    continue
                }
                checkedFiles += 1
                if computed.bytes != fileSeal.hash2 {
                    mismatches += 1
                    if mismatches <= Self.maximumDetailedFindings {
                        collector.record(
                            .sealedResourceDigest,
                            .error,
                            "The sealed resource \(fileSeal.path.rawValue) does not match the digest the seal records for it."
                        )
                    }
                }
            case .nestedCode(let nestedSeal):
                guard let path = Self.archivePath(bundle: bundlePath, relative: nestedSeal.path) else {
                    skipped += 1
                    continue
                }
                nestedChecked += 1
                switch nestedCodeDirectoryHash(reader: reader, path: path) {
                case .some(let hash):
                    if hash == nestedSeal.codeDirectoryHash {
                        checkedFiles += 1
                    } else {
                        mismatches += 1
                        if mismatches <= Self.maximumDetailedFindings {
                            collector.record(
                                .sealedResourceDigest,
                                .error,
                                "The nested code \(nestedSeal.path.rawValue) does not match the code-directory hash the seal records for it."
                            )
                        }
                    }
                case .none:
                    unreadable += 1
                }
            }
        }

        if mismatches > Self.maximumDetailedFindings {
            collector.record(
                .sealedResourceDigest,
                .error,
                "\(mismatches) sealed resources do not match the digests the seal records for them; the first \(Self.maximumDetailedFindings) are listed."
            )
        }
        if unreadable > 0 {
            collector.record(
                .sealedResourceUnreadable,
                mismatches > 0 ? .warning : .unsupported,
                "\(unreadable) sealed resource\(unreadable == 1 ? " could" : "s could") not be read within verification's bounds."
            )
        }
        if skipped > 0 {
            collector.record(
                .sealedResourceUnreadable,
                .warning,
                "\(skipped) seal entr\(skipped == 1 ? "y names a path" : "ies name paths") verification did not read."
            )
        }
        if reachTotalBound {
            collector.record(
                .sealCoverage,
                .warning,
                "The seal lists more content than verification reads, so only \(checkedFiles + unreadable) of \(seal.files2.count) entries were checked."
            )
        } else {
            collector.record(
                .sealCoverage,
                .note,
                "Every resource the seal covers was re-read and re-digested (\(checkedFiles) sealed file\(checkedFiles == 1 ? "" : "s"), \(nestedChecked) nested code reference\(nestedChecked == 1 ? "" : "s"))."
            )
        }
    }

    /// The SHA-256 digest of a nested binary's CodeDirectory blob, which is
    /// what a seal's `cdhash` entry names. Returns `nil` when the binary
    /// cannot be read or carries no CodeDirectory, so an unreadable
    /// reference is reported rather than assumed to match.
    private func nestedCodeDirectoryHash(reader: any ArchiveReader, path: ArchivePath) -> Data? {
        guard let bytes = try? reader.readEntryData(at: path, maximumBytes: limits.maximumSealedResourceBytes) else {
            return nil
        }
        let inspection = inspector.inspect(bytes: bytes)
        let slices: [MachOCodeSignatureSliceInspection]
        switch inspection {
        case .thin(let slice): slices = [slice]
        case .universal(let list): slices = list
        case .malformedMachO, .malformedSignature: return nil
        }
        guard let slice = slices.first,
              case .valid(let embedded) = slice.existingSignature,
              let directoryEntry = embedded.superBlob.entries.first(where: { $0.slot == .codeDirectory }),
              directoryEntry.fileRange.lowerBound >= bytes.startIndex,
              directoryEntry.fileRange.upperBound <= bytes.endIndex else {
            return nil
        }
        let directoryBytes = bytes.subdata(in: directoryEntry.fileRange)
        guard let computed = try? digest.digest(directoryBytes, algorithm: .sha256) else { return nil }
        return Data(computed.bytes.prefix(NestedCodeResourceSeal.codeDirectoryHashByteCount))
    }

    // MARK: - Nested code

    /// Inspects every nested code bundle the bundle carries for a signature of
    /// its own.
    ///
    /// Bundle directories are found structurally — by the suffixes the
    /// platform's conventions give them — not by guessing from file names, and
    /// each one's executable is located by the convention that names it after
    /// its directory. A nested binary that cannot be read within the bound is
    /// reported as unsupported rather than as signed.
    private func verifyNestedCode(
        reader: any ArchiveReader,
        table: [ArchiveEntry],
        bundlePath: ArchivePath,
        collector: inout FindingCollector
    ) throws {
        let prefix = bundlePath.rawValue + "/"
        var directories: [(path: ArchivePath, name: String)] = []
        for entry in table {
            guard let path = entry.path, entry.kind == .directory, path.rawValue.hasPrefix(prefix) else { continue }
            let name = path.components.last ?? ""
            guard NestedCodeLocation.codeBundleSuffixes.contains(where: { NestedCodeLocation.hasSuffix(name, $0) }) else {
                continue
            }
            directories.append((path, name))
        }
        directories.sort { $0.path.rawValue < $1.path.rawValue }

        guard !directories.isEmpty else {
            collector.record(.nestedCode, .note, "The bundle carries no nested code bundles.")
            return
        }
        let inspected = directories.prefix(limits.maximumNestedCodeCount)
        if directories.count > inspected.count {
            collector.record(
                .nestedCode,
                .warning,
                "The bundle carries more nested code bundles than verification inspects; \(inspected.count) of \(directories.count) were inspected."
            )
        }

        var unsigned: [String] = []
        var unreadable: [String] = []
        var signed = 0
        for directory in inspected {
            let executableName = NestedCodeLocation.baseName(ofBundleNamed: directory.name)
            guard !executableName.isEmpty,
                  let executablePath = directory.path.appending(component: executableName) else {
                unreadable.append(directory.name)
                continue
            }
            guard let bytes = try? reader.readEntryData(at: executablePath, maximumBytes: limits.maximumExecutableBytes) else {
                unreadable.append(directory.name)
                continue
            }
            switch inspector.inspect(bytes: bytes) {
            case .thin(let slice):
                if case .valid = slice.existingSignature { signed += 1 } else { unsigned.append(directory.name) }
            case .universal(let list):
                if list.allSatisfy({ if case .valid = $0.existingSignature { return true } else { return false } }) {
                    signed += 1
                } else {
                    unsigned.append(directory.name)
                }
            case .malformedMachO, .malformedSignature:
                unreadable.append(directory.name)
            }
        }
        if !unsigned.isEmpty {
            collector.record(
                .nestedCode,
                .error,
                "Nested code carries no readable signature: \(unsigned.prefix(Self.maximumDetailedFindings).joined(separator: ", "))."
            )
        }
        if !unreadable.isEmpty {
            collector.record(
                .nestedCode,
                .unsupported,
                "Nested code could not be inspected: \(unreadable.prefix(Self.maximumDetailedFindings).joined(separator: ", "))."
            )
        }
        if signed > 0 {
            collector.record(.nestedCode, .note, "\(signed) nested code bundle\(signed == 1 ? "" : "s") carr\(signed == 1 ? "ies" : "y") a signature.")
        }
    }

    // MARK: - Embedded profile

    /// Decodes, parses, and holds the embedded provisioning profile against
    /// what the bundle declares and against the current instant.
    ///
    /// The profile is read from the artifact, not remembered from the signing
    /// run: the bytes embedded in the container are the only profile this
    /// check knows about.
    private func verifyEmbeddedProfile(
        reader: any ArchiveReader,
        bundlePath: ArchivePath,
        declaredBundleIdentifier: String,
        collector: inout FindingCollector
    ) throws {
        guard let profilePath = ArchivePath(rawValue: bundlePath.rawValue + "/embedded.mobileprovision") else {
            collector.record(.embeddedProfile, .warning, "The bundle's profile location cannot be named.")
            return
        }
        guard let profileBytes = try? reader.readEntryData(at: profilePath, maximumBytes: limits.maximumProfileBytes) else {
            collector.record(
                .embeddedProfile,
                .error,
                "The bundle embeds no readable provisioning profile."
            )
            return
        }
        guard let profileDecoder else {
            collector.record(
                .embeddedProfile,
                .unsupported,
                "The embedded provisioning profile was found, but no profile decoder is composed in this build."
            )
            return
        }
        let payload: ProvisioningProfilePayload
        do {
            payload = try profileDecoder.decodePayload(from: ProvisioningProfileInput(bytes: profileBytes))
        } catch {
            collector.record(
                .embeddedProfile,
                .error,
                "The embedded provisioning profile's container could not be decoded."
            )
            return
        }
        let profile: ProvisioningProfile
        do {
            profile = try profileParser.parse(payload)
        } catch {
            collector.record(
                .embeddedProfile,
                .error,
                "The embedded provisioning profile's payload could not be parsed."
            )
            return
        }

        switch payload.authenticity {
        case .authenticated:
            collector.record(.embeddedProfileAuthenticity, .note, "The embedded profile's container signature was evaluated and matched.")
        case .notEvaluated:
            collector.record(
                .embeddedProfileAuthenticity,
                .warning,
                "The embedded profile decoded, but its container signature was not evaluated."
            )
        case .rejected:
            collector.record(
                .embeddedProfileAuthenticity,
                .error,
                "The embedded profile's container signature was rejected."
            )
        }

        let profileName = profile.profileName.map { "named \($0) " } ?? ""
        let deviceCount = profile.provisionedDevices?.count ?? 0
        collector.record(
            .embeddedProfile,
            .note,
            "The embedded profile \(profileName)declares \(deviceCount) provisioned device\(deviceCount == 1 ? "" : "s")."
        )

        switch profile.applicationIdentifier?.bundleIdentifierComponent {
        case .exact(let identifier):
            if identifier.rawValue != declaredBundleIdentifier {
                collector.record(
                    .embeddedProfileIdentifier,
                    .error,
                    "The embedded profile authorizes \(identifier.rawValue), which is not the bundle's identifier \(declaredBundleIdentifier)."
                )
            } else {
                collector.record(.embeddedProfileIdentifier, .note, "The embedded profile authorizes this bundle identifier.")
            }
        case .wildcard(let prefix):
            if declaredBundleIdentifier == prefix || declaredBundleIdentifier.hasPrefix(prefix + ".") {
                collector.record(
                    .embeddedProfileIdentifier,
                    .note,
                    "The embedded profile authorizes the wildcard \(prefix).* which covers this bundle identifier."
                )
            } else {
                collector.record(
                    .embeddedProfileIdentifier,
                    .error,
                    "The embedded profile authorizes the wildcard \(prefix).*, which does not cover the bundle identifier \(declaredBundleIdentifier)."
                )
            }
        case .none:
            collector.record(
                .embeddedProfileIdentifier,
                .warning,
                "The embedded profile's application identifier could not be compared with the bundle's identifier."
            )
        }

        guard let creationDate = profile.creationDate, let expirationDate = profile.expirationDate else {
            collector.record(
                .embeddedProfileExpiry,
                .warning,
                "The embedded profile declares no complete validity period, so it was not evaluated against the current time."
            )
            return
        }
        let validity = ProvisioningProfileValidity.evaluate(
            creationDate: creationDate,
            expirationDate: expirationDate,
            at: now()
        )
        switch validity.periodStatus {
        case .currentlyValid:
            collector.record(.embeddedProfileExpiry, .note, "The embedded profile is within its validity period.")
        case .expired:
            collector.record(.embeddedProfileExpiry, .warning, "The embedded profile expired on \(Self.dayString(expirationDate)).")
        case .notYetValid:
            collector.record(.embeddedProfileExpiry, .warning, "The embedded profile is not yet valid.")
        case .malformed:
            collector.record(.embeddedProfileExpiry, .warning, "The embedded profile's validity period is not ordered.")
        }
    }

    // MARK: - Helpers

    /// How many individual findings one check may add before it summarises.
    /// A container with thousands of mismatched resources is reported as a
    /// count, not as thousands of lines.
    private static let maximumDetailedFindings = 8

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

    private static func archivePath(bundle: ArchivePath, relative path: BundlePath) -> ArchivePath? {
        guard !path.rawValue.isEmpty else { return bundle }
        return ArchivePath(rawValue: bundle.rawValue + "/" + path.rawValue)
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

// MARK: - Finding collection

/// Collects findings and counts the checks that ran.
private struct FindingCollector {

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

private extension ArchiveReader {

    /// A non-throwing existence check for callers that treat absence as a
    /// finding rather than a failure.
    func containsEntrySafe(at path: ArchivePath) -> Bool {
        (try? containsEntry(at: path)) == true
    }
}
