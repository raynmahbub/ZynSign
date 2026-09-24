import Foundation

/// Application-layer use case for signing nested Mach-O code in deterministic dependency order.
///
/// Orchestrates nested signing across all established frameworks, dynamic libraries, and
/// extensions within an application bundle. Execution strictly follows the dependency-aware
/// order established by nested discovery (deepest nested code -> its dependents -> higher-level
/// nested code) while leaving the parent application executable for the later complete pipeline.
///
/// ## Safety & Atomicity
/// - Input plan is validated before any read or mutation occurs.
/// - Unrelated bundle contents are preserved; only targeted Mach-O signature regions are mutated.
/// - Staged working copy or direct mutation strategies maintain explicit failure atomicity.
/// - Every signed binary is independently verified structurally and cryptographically.
/// - Private keys and raw credentials never cross this boundary.
struct SignNestedCodeUseCase {

    private let identities: any IdentityStore
    private let digest: any MessageDigest
    private let verifier: any CryptographicSignatureVerifier
    private let parser: any MachOParsing
    private let writer: MachOCodeSignatureWriter
    private let singleSigner: SignMachOUseCase

    init(
        identities: any IdentityStore,
        digest: any MessageDigest,
        verifier: any CryptographicSignatureVerifier,
        parser: any MachOParsing = ReadOnlyMachOParser(),
        writer: MachOCodeSignatureWriter = MachOCodeSignatureWriter()
    ) {
        self.identities = identities
        self.digest = digest
        self.verifier = verifier
        self.parser = parser
        self.writer = writer
        self.singleSigner = SignMachOUseCase(
            identities: identities,
            digest: digest,
            verifier: verifier
        )
    }

    /// Signs nested code according to a validated request and artifact store.
    func sign(
        _ request: NestedSigningRequest,
        store: any NestedSigningArtifactStore
    ) -> NestedSigningResult {
        // 1. Validate identity availability.
        guard let identityID = request.identityID else {
            let failure = NestedSigningFailure(
                reason: .invalidSigningIdentity,
                detail: "A signing identity identifier is required for nested code signing.",
                category: .capabilityUnavailable,
                mutationOccurred: false
            )
            return makeFailureResult(failure: failure, plan: request.plan, itemResults: [])
        }

        let certificate: Certificate
        do {
            certificate = try identities.signingCertificate(for: identityID)
        } catch let error as ZynSignError where error.identityFailure == .identityNotFound {
            let failure = NestedSigningFailure(
                reason: .invalidSigningIdentity,
                detail: "Signing identity '\(identityID.rawValue)' was not found in the identity store.",
                category: .capabilityUnavailable,
                mutationOccurred: false
            )
            return makeFailureResult(failure: failure, plan: request.plan, itemResults: [])
        } catch {
            let failure = NestedSigningFailure(
                reason: .invalidConfiguration,
                detail: "The signing certificate for identity '\(identityID.rawValue)' could not be retrieved.",
                category: .capabilityUnavailable,
                mutationOccurred: false
            )
            return makeFailureResult(failure: failure, plan: request.plan, itemResults: [])
        }

        // 2. Handle empty plan (no nested code to sign).
        if request.plan.items.isEmpty {
            return NestedSigningResult(
                status: .succeeded,
                summary: NestedSigningSummary(
                    totalTargets: 0,
                    successfullySignedCount: 0,
                    failedCount: 0,
                    skippedCount: 0,
                    mutationState: .allTargetsModified(count: 0)
                ),
                itemResults: []
            )
        }

        // 3. Sequential deterministic signing loop.
        var itemResults: [NestedSigningItemResult] = []
        itemResults.reserveCapacity(request.plan.items.count)

        var stagedBinaries: [BundlePath: Data] = [:]
        var modifiedTargetCount = 0
        var activeFailure: NestedSigningFailure?

        let signatureInspector = MachOCodeSignatureInspector(parser: parser)

        for (index, item) in request.plan.items.enumerated() {
            // If a previous target failed, mark subsequent targets as skipped.
            if let failure = activeFailure {
                itemResults.append(NestedSigningItemResult(
                    itemID: item.id,
                    executablePath: item.executablePath,
                    codeKind: item.kind,
                    order: item.order,
                    initialSignatureState: item.initialSignatureState,
                    status: .skipped(reason: "Prior target failed: \(failure.reason.rawValue)."),
                    mutationOccurred: false
                ))
                continue
            }

            // Step A: Read binary from artifact store.
            let originalBytes: Data
            do {
                originalBytes = try store.readBinary(at: item.executablePath)
            } catch let failure as NestedSigningFailure {
                activeFailure = failure
                itemResults.append(makeItemFailureResult(item: item, failure: failure, mutationOccurred: false))
                continue
            } catch {
                let failure = NestedSigningFailure(
                    reason: .artifactReadFailure,
                    itemID: item.id,
                    path: item.executablePath,
                    detail: "Failed to read binary at '\(item.executablePath.rawValue)'.",
                    category: .storageFailure,
                    mutationOccurred: false
                )
                activeFailure = failure
                itemResults.append(makeItemFailureResult(item: item, failure: failure, mutationOccurred: false))
                continue
            }

            // Step B: Inspect existing binary and classify signature state.
            let inspection = signatureInspector.inspect(bytes: originalBytes)
            if let existingSignatureFailure = classifyExistingSignature(
                inspection: inspection,
                item: item,
                policy: request.existingSignaturePolicy
            ) {
                activeFailure = existingSignatureFailure
                itemResults.append(makeItemFailureResult(item: item, failure: existingSignatureFailure, mutationOccurred: false))
                continue
            }

            // Step C: Determine CodeDirectory configuration.
            let cdIdentifierString = item.bundleIdentifier?.rawValue ?? item.executablePath.name ?? "nested"
            let cdIdentifier: CodeDirectoryIdentifier
            do {
                cdIdentifier = try CodeDirectoryIdentifier(rawValue: cdIdentifierString)
            } catch {
                let failure = NestedSigningFailure(
                    reason: .invalidConfiguration,
                    itemID: item.id,
                    path: item.executablePath,
                    detail: "Invalid CodeDirectory identifier '\(cdIdentifierString)': \(error).",
                    category: .invalidInput,
                    mutationOccurred: false
                )
                activeFailure = failure
                itemResults.append(makeItemFailureResult(item: item, failure: failure, mutationOccurred: false))
                continue
            }

            let codeLimit: UInt64
            do {
                let layout = try MachOCodeSignatureRegionLayout(
                    appendingSerializedSuperBlobLength: 1,
                    toFileLength: originalBytes.count
                )
                codeLimit = UInt64(layout.offset)
            } catch {
                let failure = NestedSigningFailure(
                    reason: .structuralFailure,
                    itemID: item.id,
                    path: item.executablePath,
                    detail: "Could not establish code limit for binary of size \(originalBytes.count).",
                    category: .internalFailure,
                    mutationOccurred: false
                )
                activeFailure = failure
                itemResults.append(makeItemFailureResult(item: item, failure: failure, mutationOccurred: false))
                continue
            }

            let hashConfiguration: CodeDirectoryHashConfiguration
            do {
                hashConfiguration = try CodeDirectoryHashConfiguration(hashType: .sha256)
            } catch {
                let failure = NestedSigningFailure(
                    reason: .invalidConfiguration,
                    itemID: item.id,
                    path: item.executablePath,
                    detail: "The CodeDirectory hash configuration could not be constructed.",
                    category: .invalidInput,
                    mutationOccurred: false
                )
                activeFailure = failure
                itemResults.append(makeItemFailureResult(item: item, failure: failure, mutationOccurred: false))
                continue
            }

            let cdRequest = CodeDirectoryConstructionRequest(
                version: .v20200,
                flags: request.configuration.flags,
                identifier: cdIdentifier,
                teamIdentifier: request.teamIdentifier,
                platform: 0,
                hashConfiguration: hashConfiguration,
                pageSize: .exponent(12),
                codeLimit: codeLimit,
                specialSlots: request.configuration.specialSlots
            )

            let machORequest = MachOSigningRequest(
                artifact: originalBytes,
                identityID: identityID,
                codeDirectory: cdRequest,
                algorithm: request.signingAlgorithm,
                existingSignaturePolicy: request.existingSignaturePolicy,
                policy: .singleImageCryptographicExperiment,
                metadata: request.configuration.targetMetadata[item.id]
            )

            // The metadata this target asked to embed, re-derived here so the
            // independent verification below can hold the pipeline to exactly
            // those bytes. Metadata is per target: only this item's entry is
            // consulted, never another target's and never the root's.
            let targetMetadata = request.configuration.targetMetadata[item.id]
            var expectedSlots: [CodeSignatureBlobType] = [.codeDirectory, .cms]
            var expectedRequirementsBytes: Data?
            var expectedEntitlementsBytes: Data?
            if let targetMetadata, !targetMetadata.isEmpty {
                do {
                    let preparation = try SigningMetadataPreparation.prepare(
                        targetMetadata,
                        hashConfiguration: try CodeDirectoryHashConfiguration(hashType: .sha256),
                        messageDigest: digest
                    )
                    if preparation.requirementsSet != nil {
                        expectedSlots.insert(.requirements, at: 1)
                        expectedRequirementsBytes = preparation.requirementsSetBytes
                    }
                    if preparation.entitlementsBlob != nil {
                        expectedSlots.insert(.entitlements, at: expectedSlots.count - 1)
                        expectedEntitlementsBytes = preparation.entitlementsBlob?.bytes
                    }
                } catch {
                    let failure = NestedSigningFailure(
                        reason: .signingMetadataFailure,
                        itemID: item.id,
                        path: item.executablePath,
                        detail: "Signing metadata for '\(item.executablePath.rawValue)' could not be prepared.",
                        category: .invalidInput,
                        mutationOccurred: false
                    )
                    activeFailure = failure
                    itemResults.append(makeItemFailureResult(item: item, failure: failure, mutationOccurred: false))
                    continue
                }
            }

            // Step D: Sign the single Mach-O image using existing capability engine.
            let signingResult: MachOSigningResult
            do {
                signingResult = try singleSigner.sign(machORequest)
            } catch let signingError as MachOSigningError {
                let failure = mapMachOSigningError(signingError, item: item)
                activeFailure = failure
                itemResults.append(makeItemFailureResult(item: item, failure: failure, mutationOccurred: false))
                continue
            } catch {
                let failure = NestedSigningFailure(
                    reason: .signingCapabilityFailure,
                    itemID: item.id,
                    path: item.executablePath,
                    detail: "Signing failed with unexpected error: \(error).",
                    category: .internalFailure,
                    mutationOccurred: false
                )
                activeFailure = failure
                itemResults.append(makeItemFailureResult(item: item, failure: failure, mutationOccurred: false))
                continue
            }

            // Step E: Independent structural and cryptographic verification (Section 16).
            let verificationOutcome = verifySignedBinary(
                artifact: signingResult.artifact,
                expectedCodeLimit: codeLimit,
                expectedIdentifier: cdIdentifierString,
                expectedTeam: request.teamIdentifier?.rawValue,
                expectedDigest: signingResult.codeDirectoryDigest,
                certificate: certificate,
                algorithm: request.signingAlgorithm,
                expectedSlots: expectedSlots,
                expectedRequirementsBytes: expectedRequirementsBytes,
                expectedEntitlementsBytes: expectedEntitlementsBytes
            )

            guard verificationOutcome.isVerified else {
                let failure = NestedSigningFailure(
                    reason: .postSignVerificationFailure,
                    itemID: item.id,
                    path: item.executablePath,
                    detail: "Post-sign independent verification failed for '\(item.executablePath.rawValue)'.",
                    category: .internalFailure,
                    mutationOccurred: false
                )
                activeFailure = failure
                itemResults.append(makeItemFailureResult(item: item, failure: failure, mutationOccurred: false))
                continue
            }

            // Step F: Apply mutation or stage based on strategy.
            let signedBytes = signingResult.artifact
            var mutationOccurredThisItem = false

            switch request.mutationStrategy {
            case .stagedWorkingCopy:
                stagedBinaries[item.executablePath] = signedBytes
            case .directMutation:
                do {
                    try store.writeBinary(signedBytes, at: item.executablePath)
                    mutationOccurredThisItem = true
                    modifiedTargetCount += 1
                } catch {
                    let failure = NestedSigningFailure(
                        reason: .artifactWriteFailure,
                        itemID: item.id,
                        path: item.executablePath,
                        detail: "Failed to write signed binary at '\(item.executablePath.rawValue)'.",
                        category: .storageFailure,
                        mutationOccurred: false
                    )
                    activeFailure = failure
                    itemResults.append(makeItemFailureResult(item: item, failure: failure, mutationOccurred: false))
                    continue
                }
            }

            // Record successful signing.
            let details = NestedMachOSigningDetails(
                codeDirectoryDigest: signingResult.codeDirectoryDigest,
                signatureByteCount: signingResult.cryptographicSignature.count,
                verification: verificationOutcome
            )
            itemResults.append(NestedSigningItemResult(
                itemID: item.id,
                executablePath: item.executablePath,
                codeKind: item.kind,
                order: item.order,
                initialSignatureState: item.initialSignatureState,
                status: .signed(details),
                mutationOccurred: mutationOccurredThisItem
            ))
        }

        // 4. Finalize result and commit staged mutations if needed.
        let totalCount = request.plan.items.count
        let signedCount = itemResults.filter { $0.status.isSigned }.count
        let failedCount = activeFailure != nil ? 1 : 0
        let skippedCount = totalCount - signedCount - failedCount

        if let failure = activeFailure {
            let mutationState: NestedSigningMutationState
            switch request.mutationStrategy {
            case .stagedWorkingCopy:
                // Staged changes discarded on failure; no targets modified.
                mutationState = .noTargetsModified
            case .directMutation:
                mutationState = modifiedTargetCount > 0
                    ? .someTargetsModified(modifiedCount: modifiedTargetCount, totalTargetCount: totalCount)
                    : .noTargetsModified
            }

            return NestedSigningResult(
                status: .failed(failure),
                summary: NestedSigningSummary(
                    totalTargets: totalCount,
                    successfullySignedCount: signedCount,
                    failedCount: failedCount,
                    skippedCount: skippedCount,
                    mutationState: mutationState
                ),
                itemResults: itemResults
            )
        }

        // All items succeeded. For staged strategy, commit now.
        if request.mutationStrategy == .stagedWorkingCopy {
            for (path, bytes) in stagedBinaries {
                do {
                    try store.writeBinary(bytes, at: path)
                    modifiedTargetCount += 1
                } catch {
                    let failure = NestedSigningFailure(
                        reason: .artifactWriteFailure,
                        path: path,
                        detail: "Failed to commit staged binary to store at '\(path.rawValue)'.",
                        category: .storageFailure,
                        mutationOccurred: modifiedTargetCount > 0
                    )
                    return NestedSigningResult(
                        status: .failed(failure),
                        summary: NestedSigningSummary(
                            totalTargets: totalCount,
                            successfullySignedCount: signedCount,
                            failedCount: 1,
                            skippedCount: 0,
                            mutationState: modifiedTargetCount > 0
                                ? .someTargetsModified(modifiedCount: modifiedTargetCount, totalTargetCount: totalCount)
                                : .noTargetsModified
                        ),
                        itemResults: itemResults
                    )
                }
            }
        }

        return NestedSigningResult(
            status: .succeeded,
            summary: NestedSigningSummary(
                totalTargets: totalCount,
                successfullySignedCount: signedCount,
                failedCount: 0,
                skippedCount: 0,
                mutationState: .allTargetsModified(count: totalCount)
            ),
            itemResults: itemResults
        )
    }

    /// Convenience overload to validate a discovery plan and execute nested signing in one call.
    func sign(
        plan: NestedCodeSigningPlan,
        identityID: SigningIdentityIdentifier?,
        store: any NestedSigningArtifactStore,
        signingAlgorithm: SigningAlgorithm = .rsaPKCS1SHA256Digest,
        existingSignaturePolicy: MachOExistingCodeSignaturePolicy = .rejectExistingSignature,
        teamIdentifier: CodeDirectoryTeamIdentifier? = nil,
        configuration: NestedCodeSigningConfiguration = NestedCodeSigningConfiguration(),
        mutationStrategy: NestedSigningMutationStrategy = .stagedWorkingCopy
    ) -> NestedSigningResult {
        let validatedPlan: NestedSigningPlan
        do {
            validatedPlan = try NestedSigningPlanValidator.validate(plan: plan)
        } catch let failure as NestedSigningFailure {
            return makeFailureResult(failure: failure, plan: nil, itemResults: [])
        } catch {
            let failure = NestedSigningFailure(
                reason: .invalidSigningPlan,
                detail: "Plan validation failed: \(error).",
                category: .invalidInput,
                mutationOccurred: false
            )
            return makeFailureResult(failure: failure, plan: nil, itemResults: [])
        }

        let request = NestedSigningRequest(
            plan: validatedPlan,
            identityID: identityID,
            signingAlgorithm: signingAlgorithm,
            existingSignaturePolicy: existingSignaturePolicy,
            teamIdentifier: teamIdentifier,
            configuration: configuration,
            mutationStrategy: mutationStrategy
        )

        return sign(request, store: store)
    }

    // MARK: - Verification (Section 16)

    private func verifySignedBinary(
        artifact: Data,
        expectedCodeLimit: UInt64,
        expectedIdentifier: String,
        expectedTeam: String?,
        expectedDigest: Digest,
        certificate: Certificate,
        algorithm: SigningAlgorithm,
        expectedSlots: [CodeSignatureBlobType],
        expectedRequirementsBytes: Data?,
        expectedEntitlementsBytes: Data?
    ) -> NestedSigningItemVerification {
        // 1. Structural Verification.
        var structuralValidity: NestedStructuralValidity = .valid
        var cryptographicValidity: NestedCryptographicValidity = .invalid("Verification not evaluated")
        var relationshipValidity: NestedRelationshipValidity = .notEvaluated

        do {
            guard artifact.startIndex == 0 else {
                return NestedSigningItemVerification(
                    structuralValidity: .invalid("Non-zero-based data index"),
                    cryptographicValidity: cryptographicValidity,
                    relationshipValidity: relationshipValidity
                )
            }
            let image = try parser.parse(artifact)
            guard case .thin(let slice) = image.container else {
                return NestedSigningItemVerification(
                    structuralValidity: .invalid("Parsed image is not a thin Mach-O"),
                    cryptographicValidity: cryptographicValidity,
                    relationshipValidity: relationshipValidity
                )
            }
            guard slice.header.cpu == .arm64 else {
                return NestedSigningItemVerification(
                    structuralValidity: .invalid("Parsed image is not arm64"),
                    cryptographicValidity: cryptographicValidity,
                    relationshipValidity: relationshipValidity
                )
            }
            guard let embedded = slice.embeddedSignature else {
                return NestedSigningItemVerification(
                    structuralValidity: .invalid("Missing LC_CODE_SIGNATURE"),
                    cryptographicValidity: cryptographicValidity,
                    relationshipValidity: relationshipValidity
                )
            }
            guard embedded.command.dataOffset == Int(expectedCodeLimit),
                  embedded.command.fileRange.upperBound == artifact.count else {
                return NestedSigningItemVerification(
                    structuralValidity: .invalid("Signature command bounds do not match code limit or file end"),
                    cryptographicValidity: cryptographicValidity,
                    relationshipValidity: relationshipValidity
                )
            }
            guard embedded.superBlob.entries.map(\.slot) == expectedSlots,
                  let cdEntry = embedded.superBlob.entries.first(where: { $0.slot == .codeDirectory }),
                  let cmsEntry = embedded.superBlob.entries.first(where: { $0.slot == .cms }),
                  let cd = cdEntry.codeDirectory else {
                return NestedSigningItemVerification(
                    structuralValidity: .invalid("SuperBlob slots do not match the expected signed layout"),
                    cryptographicValidity: cryptographicValidity,
                    relationshipValidity: relationshipValidity
                )
            }
            // Embedded metadata blobs must be the exact prepared bytes, and
            // their CodeDirectory special-slot digests must bind those bytes.
            // Both comparisons re-derive from the per-target preparation the
            // signing loop computed above, never from signing state.
            if let expectedRequirementsBytes {
                guard let requirementsEntry = embedded.superBlob.entries.first(where: { $0.slot == .requirements }),
                      artifact.subdata(in: requirementsEntry.fileRange) == expectedRequirementsBytes,
                      let requirementsSlot = cd.specialSlots.first(where: { $0.kind == .requirements }),
                      requirementsSlot.hash == Data(try digest.digest(expectedRequirementsBytes, algorithm: .sha256).bytes.prefix(requirementsSlot.hash.count)) else {
                    return NestedSigningItemVerification(
                        structuralValidity: .invalid("Embedded requirements do not match the prepared per-target metadata"),
                        cryptographicValidity: cryptographicValidity,
                        relationshipValidity: relationshipValidity
                    )
                }
            }
            if let expectedEntitlementsBytes {
                guard let entitlementsEntry = embedded.superBlob.entries.first(where: { $0.slot == .entitlements }),
                      artifact.subdata(in: entitlementsEntry.fileRange) == expectedEntitlementsBytes,
                      let entitlementsSlot = cd.specialSlots.first(where: { $0.kind == .entitlements }),
                      entitlementsSlot.hash == Data(try digest.digest(expectedEntitlementsBytes, algorithm: .sha256).bytes.prefix(entitlementsSlot.hash.count)) else {
                    return NestedSigningItemVerification(
                        structuralValidity: .invalid("Embedded entitlements do not match the prepared per-target metadata"),
                        cryptographicValidity: cryptographicValidity,
                        relationshipValidity: relationshipValidity
                    )
                }
            }
            guard cd.identifier == expectedIdentifier else {
                return NestedSigningItemVerification(
                    structuralValidity: .invalid("CodeDirectory identifier '\(cd.identifier)' does not match expected '\(expectedIdentifier)'"),
                    cryptographicValidity: cryptographicValidity,
                    relationshipValidity: relationshipValidity
                )
            }
            guard cd.effectiveCodeLimit == expectedCodeLimit else {
                return NestedSigningItemVerification(
                    structuralValidity: .invalid("CodeDirectory effectiveCodeLimit does not match planned limit"),
                    cryptographicValidity: cryptographicValidity,
                    relationshipValidity: relationshipValidity
                )
            }
            guard cd.pageSizeExponent == 12, cd.hashType == .sha256 else {
                return NestedSigningItemVerification(
                    structuralValidity: .invalid("CodeDirectory page size or hash type mismatch"),
                    cryptographicValidity: cryptographicValidity,
                    relationshipValidity: relationshipValidity
                )
            }

            // Verify CodeDirectory page hashes.
            let computedPageHashes = try CodePageHasher(messageDigest: digest).hashCodePages(
                artifact,
                codeLimit: expectedCodeLimit,
                pageSize: .exponent(12),
                hashConfiguration: CodeDirectoryHashConfiguration(hashType: .sha256)
            )
            guard cd.codeHashes == computedPageHashes.map(\.hash) else {
                return NestedSigningItemVerification(
                    structuralValidity: .invalid("CodeDirectory page hashes do not match computed page hashes"),
                    cryptographicValidity: cryptographicValidity,
                    relationshipValidity: relationshipValidity
                )
            }

            structuralValidity = .valid

            // 2. Cryptographic Verification.
            let cdBytes = artifact.subdata(in: cdEntry.fileRange)
            let computedDigest = try digest.digest(cdBytes, algorithm: .sha256)
            guard computedDigest == expectedDigest else {
                return NestedSigningItemVerification(
                    structuralValidity: structuralValidity,
                    cryptographicValidity: .invalid("CodeDirectory digest does not match expected digest"),
                    relationshipValidity: relationshipValidity
                )
            }

            let signatureBytes = artifact.subdata(in: (cmsEntry.fileRange.lowerBound + 8)..<cmsEntry.fileRange.upperBound)
            let cms = try DetachedCodeSignatureCMS(certificate: certificate)
            try cms.verify(signatureBytes, codeDirectory: cdBytes, digest: digest, verifier: verifier)

            cryptographicValidity = .valid(digest: computedDigest)

            // 3. Relationship Verification.
            if let expectedTeam {
                if cd.teamIdentifier == expectedTeam {
                    relationshipValidity = .matched(signerSummary: "Team \(expectedTeam) verified")
                } else {
                    relationshipValidity = .mismatched("Team identifier '\(cd.teamIdentifier ?? "")' does not match expected '\(expectedTeam)'")
                }
            } else {
                relationshipValidity = .matched(signerSummary: "Certificate fingerprint matched")
            }

        } catch {
            if structuralValidity.isValid {
                cryptographicValidity = .invalid("Verification failed: \(error)")
            } else {
                structuralValidity = .invalid("Structural verification failed: \(error)")
            }
        }

        return NestedSigningItemVerification(
            structuralValidity: structuralValidity,
            cryptographicValidity: cryptographicValidity,
            relationshipValidity: relationshipValidity
        )
    }

    // MARK: - Existing Signature Policy (Section 9)

    private func classifyExistingSignature(
        inspection: MachOCodeSignatureInspection,
        item: NestedSigningItem,
        policy: MachOExistingCodeSignaturePolicy
    ) -> NestedSigningFailure? {
        switch inspection {
        case .thin(let sliceInspection):
            switch sliceInspection.existingSignature {
            case .absent:
                return nil
            case .valid:
                switch policy {
                case .rejectExistingSignature:
                    return NestedSigningFailure(
                        reason: .existingSignatureRejected,
                        itemID: item.id,
                        path: item.executablePath,
                        detail: "Nested binary at '\(item.executablePath.rawValue)' already carries a signature, which is rejected by policy.",
                        category: .unsupportedInput,
                        mutationOccurred: false
                    )
                case .replaceExistingSignature:
                    return NestedSigningFailure(
                        reason: .unsupportedExistingSignature,
                        itemID: item.id,
                        path: item.executablePath,
                        detail: "Replacing existing signature on '\(item.executablePath.rawValue)' is unsupported.",
                        category: .unsupportedInput,
                        mutationOccurred: false
                    )
                }
            case .malformedCommand(let error), .invalidRegionOffset(let error),
                 .invalidRegionSize(let error), .malformedRegion(let error):
                return NestedSigningFailure(
                    reason: .malformedExistingSignature,
                    itemID: item.id,
                    path: item.executablePath,
                    detail: "Existing signature at '\(item.executablePath.rawValue)' is malformed: \(error.reason).",
                    category: .unsupportedInput,
                    mutationOccurred: false
                )
            }
        case .universal:
            return NestedSigningFailure(
                reason: .unsupportedFormat,
                itemID: item.id,
                path: item.executablePath,
                detail: "Universal (fat) Mach-O container at '\(item.executablePath.rawValue)' is unsupported.",
                category: .unsupportedInput,
                mutationOccurred: false
            )
        case .malformedSignature(_, let state):
            return NestedSigningFailure(
                reason: .malformedExistingSignature,
                itemID: item.id,
                path: item.executablePath,
                detail: "Existing signature at '\(item.executablePath.rawValue)' is malformed: \(state).",
                category: .unsupportedInput,
                mutationOccurred: false
            )
        case .malformedMachO(let error):
            return NestedSigningFailure(
                reason: .unsupportedFormat,
                itemID: item.id,
                path: item.executablePath,
                detail: "Binary at '\(item.executablePath.rawValue)' is malformed: \(error.reason).",
                category: .unsupportedInput,
                mutationOccurred: false
            )
        }
    }

    // MARK: - Helpers

    private func mapMachOSigningError(_ error: MachOSigningError, item: NestedSigningItem) -> NestedSigningFailure {
        let reason: NestedSigningFailureReason
        let detail: String

        switch error {
        case .invalidMachO(let parseError):
            reason = .structuralFailure
            detail = "Mach-O parsing failed: \(parseError.reason) at \(parseError.boundary)."
        case .unsupportedMachOForm:
            reason = .unsupportedFormat
            detail = "Mach-O binary format is unsupported."
        case .unsupportedConfiguration:
            reason = .invalidConfiguration
            detail = "Signing configuration is unsupported."
        case .invalidCodeLimit:
            reason = .structuralFailure
            detail = "Invalid code limit calculation."
        case .unsupportedHashType, .unsupportedSigningAlgorithm:
            reason = .invalidConfiguration
            detail = "Requested hash type or signing algorithm is unsupported."
        case .identityUnavailable:
            reason = .invalidSigningIdentity
            detail = "Signing identity is unavailable."
        case .certificateUnavailable:
            reason = .invalidConfiguration
            detail = "Signing certificate is unavailable."
        case .signingCapabilityFailure:
            reason = .signingCapabilityFailure
            detail = "Signing capability failed."
        case .codeDirectoryConstruction, .codeDirectorySerialization:
            reason = .structuralFailure
            detail = "CodeDirectory construction or serialization failed."
        case .entitlements, .requirements, .resourceSeal:
            reason = .signingMetadataFailure
            detail = "Signing metadata (entitlements, requirements, or resource seal) failed its boundary."
        case .digestFailure:
            reason = .cryptographicFailure
            detail = "Cryptographic digest computation failed."
        case .signatureBlobConstruction, .superBlobConstruction:
            reason = .structuralFailure
            detail = "SuperBlob or CMS blob construction failed."
        case .layout(let regionError), .mutation(let regionError):
            switch regionError {
            case .existingSignatureRejected:
                reason = .existingSignatureRejected
                detail = "Existing signature rejected by policy."
            case .replacementUnsupported:
                reason = .unsupportedExistingSignature
                detail = "Signature replacement is unsupported."
            case .malformedExistingSignature:
                reason = .malformedExistingSignature
                detail = "Existing signature is malformed."
            case .universalImageUnsupported:
                reason = .unsupportedFormat
                detail = "Universal Mach-O containers are unsupported."
            default:
                reason = .structuralFailure
                detail = "Mach-O layout or mutation error: \(regionError)."
            }
        case .postSignVerification:
            reason = .postSignVerificationFailure
            detail = "Post-sign verification failed."
        case .resourceLimitExceeded:
            reason = .resourceLimitExceeded
            detail = "Resource limit exceeded during Mach-O signing."
        }

        return NestedSigningFailure(
            reason: reason,
            itemID: item.id,
            path: item.executablePath,
            detail: detail,
            category: reason.category,
            mutationOccurred: false
        )
    }

    private func makeItemFailureResult(
        item: NestedSigningItem,
        failure: NestedSigningFailure,
        mutationOccurred: Bool
    ) -> NestedSigningItemResult {
        NestedSigningItemResult(
            itemID: item.id,
            executablePath: item.executablePath,
            codeKind: item.kind,
            order: item.order,
            initialSignatureState: item.initialSignatureState,
            status: .failed(failure),
            mutationOccurred: mutationOccurred
        )
    }

    private func makeFailureResult(
        failure: NestedSigningFailure,
        plan: NestedSigningPlan?,
        itemResults: [NestedSigningItemResult]
    ) -> NestedSigningResult {
        let totalCount = plan?.items.count ?? 0
        let signedCount = itemResults.filter { $0.status.isSigned }.count
        let failedCount = 1
        let skippedCount = max(0, totalCount - signedCount - failedCount)

        return NestedSigningResult(
            status: .failed(failure),
            summary: NestedSigningSummary(
                totalTargets: totalCount,
                successfullySignedCount: signedCount,
                failedCount: failedCount,
                skippedCount: skippedCount,
                mutationState: .noTargetsModified
            ),
            itemResults: itemResults
        )
    }
}
