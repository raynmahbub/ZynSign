import Foundation

/// One expectation an independent verification holds a signed container to.
///
/// Expectations are captured from the signing run that produced the
/// container: where the bundle must sit, what it must declare, which bytes
/// the profile and the resource seal must carry, and what every signed
/// binary must embed. The verifier reads the container back through the
/// ordinary archive boundary and checks each expectation with machinery
/// that shares no code path with the signer: re-parsed metadata, re-read
/// bytes, re-computed digests, and re-inspected signatures.
struct SignedApplicationExpectations: Equatable {

    /// The bundle's location inside the container.
    let bundlePath: ArchivePath

    /// The declared bundle identifier.
    let bundleIdentifier: BundleIdentifier

    /// The declared executable name.
    let executableName: String

    /// The main executable's location inside the container.
    let executablePath: ArchivePath

    /// The exact profile bytes the container must embed.
    let profile: Data

    /// The exact resource-seal bytes the container must carry.
    let sealedCodeResources: Data

    /// The entitlement set the main executable must embed.
    let entitlements: CodeSigningEntitlements

    /// The nested executables that must each carry a signature, located
    /// relative to the bundle.
    let nestedExecutablePaths: [BundlePath]
}

/// What one independent verification established.
struct VerifySignedApplicationReport: Equatable {

    /// Whether every check passed.
    let passed: Bool

    /// The checks in the order they ran, each with its outcome.
    let checks: [SignedApplicationVerificationCheck]
}

/// One verification check and its outcome.
struct SignedApplicationVerificationCheck: Equatable {

    /// The stable check name for diagnostics and tests.
    let name: String

    /// Whether the check passed.
    let passed: Bool
}

/// Verifies a signed application container against the expectations its
/// signing run captured.
///
/// Verification is independent by construction: it reopens the container
/// through the `ArchiveReader` boundary, re-reads every byte it judges,
/// re-computes every digest it compares, and re-inspects every signature
/// it requires. It shares the deterministic parsers and inspectors with
/// the rest of ZynSign, but no signing state: nothing the signer believed
/// is taken on trust.
///
/// What verification establishes — and what it pointedly does not:
///
/// - structure, metadata, profile bytes, seal bytes, seal digests,
///   signature presence, embedded entitlements, and the slot-3 binding
///   between the main executable and the sealed resources are all checked;
/// - cryptographic validity of any signature is not established (no trust
///   evaluation runs here), platform authorization is not claimed, and
///   installability is not concluded. A passing report means the container
///   is exactly what the signing run produced and internally coherent —
///   nothing more.
///
/// A failing check is a returned report, never a thrown error: a container
/// that does not match its expectations is a fact about the container. Only
/// unreadable containers and infrastructure failures throw, and they throw
/// typed errors.
struct VerifySignedApplication {

    private let makeReader: (URL) -> any ArchiveReader
    private let digest: any MessageDigest
    private let limits: ArchiveLimits

    init(
        makeReader: @escaping (URL) -> any ArchiveReader = { ZipArchiveReader(location: $0) },
        digest: any MessageDigest,
        limits: ArchiveLimits = .default
    ) {
        self.makeReader = makeReader
        self.digest = digest
        self.limits = limits
    }

    /// Verifies one container against its expectations.
    func verify(containerURL: URL, expectations: SignedApplicationExpectations) async throws -> VerifySignedApplicationReport {
        try Task.checkCancellation()
        let reader = makeReader(containerURL)
        defer { reader.close() }
        var checks: [SignedApplicationVerificationCheck] = []
        func record(_ name: String, _ passed: Bool) {
            checks.append(SignedApplicationVerificationCheck(name: name, passed: passed))
        }

        let table = try reader.readEntryTable()
        let inspection = IPAStructureValidator(limits: limits).validate(entryTable: table)
        record("structure", inspection.isValid && inspection.bundle?.bundlePath == expectations.bundlePath)
        guard checks.allSatisfy({ $0.passed }) else {
            return VerifySignedApplicationReport(passed: false, checks: checks)
        }

        let metadata = try readMetadata(reader: reader, expectations: expectations)
        record("metadata", metadata != nil)
        guard metadata != nil else {
            return VerifySignedApplicationReport(passed: false, checks: checks)
        }
        try Task.checkCancellation()

        record("executable-present", try isNonEmptyRegularFile(reader: reader, table: table, path: expectations.executablePath))
        record("profile-bytes", try profileMatches(reader: reader, expectations: expectations))
        record("seal-bytes", try sealMatches(reader: reader, expectations: expectations))
        guard checks.allSatisfy({ $0.passed }) else {
            return VerifySignedApplicationReport(passed: false, checks: checks)
        }
        try Task.checkCancellation()

        record("seal-digests", try sealDigestsHold(reader: reader, expectations: expectations))
        record("main-executable", try mainExecutableHolds(reader: reader, expectations: expectations))
        record("nested-executables", try nestedExecutablesHold(reader: reader, table: table, expectations: expectations))

        return VerifySignedApplicationReport(
            passed: checks.allSatisfy { $0.passed },
            checks: checks
        )
    }

    // MARK: - Checks

    private func readMetadata(
        reader: any ArchiveReader,
        expectations: SignedApplicationExpectations
    ) throws -> ApplicationMetadata? {
        guard let informationPath = expectations.bundlePath.appending(component: "Info.plist") else {
            return nil
        }
        guard let bytes = try? reader.readEntryData(at: informationPath, maximumBytes: limits.maximumInspectionReadBytes) else {
            return nil
        }
        guard let metadata = ApplicationMetadataReader.read(from: bytes).metadata else {
            return nil
        }
        guard metadata.identity.bundleIdentifier == expectations.bundleIdentifier else {
            return nil
        }
        guard metadata.executableName == expectations.executableName else {
            return nil
        }
        return metadata
    }

    private func isNonEmptyRegularFile(
        reader: any ArchiveReader,
        table: [ArchiveEntry],
        path: ArchivePath
    ) throws -> Bool {
        guard table.first(where: { $0.path == path })?.kind == .regularFile else {
            return false
        }
        guard let bytes = try? reader.readEntryData(at: path, maximumBytes: limits.maximumEntryBytes) else {
            return false
        }
        return !bytes.isEmpty
    }

    private func bundleFile(
        reader: any ArchiveReader,
        expectations: SignedApplicationExpectations,
        components: [String]
    ) throws -> Data? {
        var path = expectations.bundlePath
        for component in components {
            guard let next = path.appending(component: component) else {
                return nil
            }
            path = next
        }
        // A missing or unreadable entry is an expectation mismatch — a
        // failing check — rather than an infrastructure failure.
        return try? reader.readEntryData(at: path, maximumBytes: limits.maximumEntryBytes)
    }

    private func profileMatches(reader: any ArchiveReader, expectations: SignedApplicationExpectations) throws -> Bool {
        guard let embedded = try bundleFile(reader: reader, expectations: expectations, components: ["embedded.mobileprovision"]) else {
            return false
        }
        return embedded == expectations.profile
    }

    private func sealMatches(reader: any ArchiveReader, expectations: SignedApplicationExpectations) throws -> Bool {
        guard let sealed = try bundleFile(
            reader: reader,
            expectations: expectations,
            components: ["_CodeSignature", "CodeResources"]
        ) else {
            return false
        }
        guard sealed == expectations.sealedCodeResources else {
            return false
        }
        // Byte equality alone would pass a corrupted expectation through;
        // the document must also parse as the supported subset.
        guard (try? CodeResourcesParser.parse(sealed)) != nil else {
            return false
        }
        return true
    }

    private func sealDigestsHold(reader: any ArchiveReader, expectations: SignedApplicationExpectations) throws -> Bool {
        guard let document = try? CodeResourcesParser.parse(expectations.sealedCodeResources) else {
            return false
        }
        for entry in document.files2 {
            guard case .file(let seal) = entry else {
                continue
            }
            var path = expectations.bundlePath
            var valid = true
            for component in seal.path.components {
                if let next = path.appending(component: component) {
                    path = next
                } else {
                    valid = false
                    break
                }
            }
            guard valid else {
                return false
            }
            guard let bytes = try? reader.readEntryData(at: path, maximumBytes: limits.maximumEntryBytes) else {
                return false
            }
            let computed = try digest.digest(bytes, algorithm: .sha256)
            guard Data(computed.bytes) == seal.hash2 else {
                return false
            }
        }
        return true
    }

    private func mainExecutableHolds(reader: any ArchiveReader, expectations: SignedApplicationExpectations) throws -> Bool {
        guard let bytes = try? reader.readEntryData(at: expectations.executablePath, maximumBytes: limits.maximumEntryBytes) else {
            return false
        }
        let image: MachOImage
        do {
            image = try MachOInspection().inspect(bytes: bytes)
        } catch {
            return false
        }
        guard !image.slices.isEmpty else {
            return false
        }
        let expectedSlot3 = try digest.digest(expectations.sealedCodeResources, algorithm: .sha256)
        let inspector = EmbeddedSigningMetadataInspector()
        for slice in image.slices {
            guard slice.embeddedSignature != nil else {
                return false
            }
            let embedded = inspector.inspect(slice: slice, artifact: bytes)
            guard embedded.entitlements == .present(expectations.entitlements) else {
                return false
            }
            guard embedded.codeResourcesSeal == .sealed(digest: Data(expectedSlot3.bytes)) else {
                return false
            }
        }
        return true
    }

    private func nestedExecutablesHold(
        reader: any ArchiveReader,
        table: [ArchiveEntry],
        expectations: SignedApplicationExpectations
    ) throws -> Bool {
        for nested in expectations.nestedExecutablePaths {
            var path = expectations.bundlePath
            var valid = true
            for component in nested.components {
                if let next = path.appending(component: component) {
                    path = next
                } else {
                    valid = false
                    break
                }
            }
            guard valid else {
                return false
            }
            guard table.first(where: { $0.path == path })?.kind == .regularFile else {
                return false
            }
            guard let bytes = try? reader.readEntryData(at: path, maximumBytes: limits.maximumEntryBytes) else {
                return false
            }
            guard let image = try? MachOInspection().inspect(bytes: bytes), !image.slices.isEmpty else {
                return false
            }
            for slice in image.slices {
                guard slice.embeddedSignature != nil else {
                    return false
                }
            }
        }
        return true
    }
}
