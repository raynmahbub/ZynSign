import Foundation
import XCTest
@testable import ZynSign

/// End-to-end signing-metadata integration: the signing pipeline prepares
/// metadata first, embeds entitlements and requirements blobs in the
/// SuperBlob, digests CodeResources into special slot 3, builds the
/// CodeDirectory over finalized slots, and only then signs — with
/// verification holding the artifact to the exact prepared bytes.
///
/// The metadata-signing tests use the always-valid verifier and the
/// fixed-signature identity, because the golden-digest verifier of the
/// ZS-026 vectors pins a signature over a metadata-free CodeDirectory; the
/// CMS boundary itself stays covered by those existing suites. The digest
/// literals below were computed independently on a host.
final class SigningMetadataIntegrationTests: XCTestCase {

    private let digest = CryptoKitMessageDigest()

    // MARK: - Fixtures

    private func makeEntitlements() throws -> CodeSigningEntitlements {
        try CodeSigningEntitlements(values: ["get-task-allow": .boolean(true)])
    }

    private func makeRequirementsSet() throws -> RequirementsSet {
        try RequirementsSet(entries: [
            RequirementsSetEntry(
                kind: .designated,
                requirement: try FramedRequirement(
                    expressionBytes: Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
                )
            )
        ])
    }

    private func makeSealedCodeResources() throws -> SealedCodeResources {
        let iconPath = try XCTUnwrap(BundlePath(rawValue: "Assets/icon.png"))
        let iconHash = try digest.digest(Data("icon-png-bytes\u{00}\u{01}".utf8), algorithm: .sha256)
        let document = try CodeResourcesDocument(files2: [
            .file(try FileResourceSeal(path: iconPath, hash2: iconHash.bytes))
        ])
        return try SealedCodeResources(document: document)
    }

    private func request(
        metadata: MachOSigningMetadata?,
        identity: SigningIdentityIdentifier?
    ) throws -> MachOSigningRequest {
        MachOSigningRequest(
            artifact: MachOSigningFixtures.unsignedMachO,
            identityID: identity,
            codeDirectory: CodeDirectoryConstructionRequest(
                version: .v20200,
                flags: [],
                identifier: try CodeDirectoryIdentifier(rawValue: "com.example.single"),
                teamIdentifier: try CodeDirectoryTeamIdentifier(rawValue: "TESTTEAM"),
                hashConfiguration: try CodeDirectoryHashConfiguration(hashType: .sha256),
                pageSize: .exponent(12),
                codeLimit: 4144,
                specialSlots: []
            ),
            algorithm: .rsaPKCS1SHA256Digest,
            existingSignaturePolicy: .rejectExistingSignature,
            policy: .singleImageCryptographicExperiment,
            metadata: metadata
        )
    }

    private func useCase(_ identities: any IdentityStore,
                         verifier: any CryptographicSignatureVerifier) -> SignMachOUseCase {
        SignMachOUseCase(identities: identities, digest: digest, verifier: verifier)
    }

    private func slice(of artifact: Data) throws -> MachOSlice {
        let image = try ReadOnlyMachOParser().parse(artifact)
        guard case .thin(let slice) = image.container else {
            throw NSError(domain: "test", code: 1, userInfo: nil)
        }
        return slice
    }

    // MARK: - The metadata-free path is unchanged

    func testNilMetadataReproducesGoldenArtifactByteForByte() throws {
        let store = try MachOVectorIdentity()
        let request = try request(metadata: nil, identity: store.id)
        let result = try useCase(store, verifier: MachOVectorVerifier()).sign(request)
        XCTAssertEqual(result.artifact, MachOSigningFixtures.expectedSignedMachO)
        XCTAssertNil(result.entitlementsBlob)
        XCTAssertNil(result.requirementsBlob)
        XCTAssertNil(result.metadataSlotDigests)
        XCTAssertEqual(result.platformAuthorization, .notPerformed)
        XCTAssertEqual(result.provisioningValidation, .notPerformed)
    }

    // MARK: - Preparation

    func testPreparationDerivesBlobsDigestsAndRecord() throws {
        let metadata = MachOSigningMetadata(
            entitlements: try makeEntitlements(),
            requirements: CodeSigningRequirements(
                disposition: .presentAndParsed, set: try makeRequirementsSet()
            ),
            resourceSeal: try makeSealedCodeResources()
        )
        let preparation = try SigningMetadataPreparation.prepare(
            metadata,
            hashConfiguration: try CodeDirectoryHashConfiguration(hashType: .sha256),
            messageDigest: digest
        )

        XCTAssertEqual(preparation.entitlementsBlob?.bytes,
                       try EntitlementsCanonicalSerializer().blob(try makeEntitlements()).bytes)
        XCTAssertEqual(preparation.requirementsSetBytes, try makeRequirementsSet().serialized())
        XCTAssertTrue(preparation.contributesSuperBlobEntries)

        // Independently computed slot-digest vectors: slots 2 and 5 hash the
        // complete embedded blob including its eight-byte header; slot 3
        // hashes the CodeResources file bytes.
        XCTAssertEqual(preparation.slotDigests.requirements?.hexString,
                       "fb68f59a513f4cc2f81597abea1be016e966ca46747b9c293bf98f095ea16251")
        XCTAssertEqual(preparation.slotDigests.codeResources?.hexString,
                       "371ce8e39d430a0e35a3b24a3e6b818f12c8674579065dbd52a7abf197e4bef8")
        XCTAssertEqual(preparation.slotDigests.entitlements?.hexString,
                       "5e0d951237bedfee269217a268ac00ccd46c6994b48387b0ccf43f5ab6e73be2")

        // The embedded-entitlements record: exact bytes, the slot-5 digest,
        // and platform authorization explicitly not evaluated — embedding is
        // the only fact asserted.
        let record = try XCTUnwrap(preparation.entitlementsRecord)
        XCTAssertEqual(record.blobBytes, preparation.entitlementsBlob?.bytes)
        XCTAssertEqual(record.specialSlotDigest, preparation.slotDigests.entitlements)
        XCTAssertEqual(record.platformAuthorization, .notEvaluated)

        // Special slots in construction order: contiguous 1...5, with
        // reserved slots as zero-hash placeholders and no slot-1 invention.
        let slots = preparation.slotDigests.specialSlots(hashSize: 32)
        XCTAssertEqual(slots.map(\.index), [1, 2, 3, 4, 5])
        XCTAssertNil(slots[0].hash)
        XCTAssertEqual(slots[1].hash, preparation.slotDigests.requirements?.bytes)
        XCTAssertEqual(slots[2].hash, preparation.slotDigests.codeResources?.bytes)
        XCTAssertNil(slots[3].hash)
        XCTAssertEqual(slots[4].hash, preparation.slotDigests.entitlements?.bytes)
    }

    func testEmptyPreparationContributesNothing() throws {
        let preparation = try SigningMetadataPreparation.prepare(
            nil,
            hashConfiguration: try CodeDirectoryHashConfiguration(hashType: .sha256),
            messageDigest: digest
        )
        XCTAssertNil(preparation.entitlementsBlob)
        XCTAssertNil(preparation.entitlementsRecord)
        XCTAssertNil(preparation.requirementsSet)
        XCTAssertNil(preparation.requirementsSetBytes)
        XCTAssertTrue(preparation.slotDigests.isEmpty)
        XCTAssertFalse(preparation.contributesSuperBlobEntries)
        XCTAssertTrue(preparation.slotDigests.specialSlots(hashSize: 32).isEmpty)

        // An empty metadata value is the same as none.
        let empty = try SigningMetadataPreparation.prepare(
            MachOSigningMetadata(),
            hashConfiguration: try CodeDirectoryHashConfiguration(hashType: .sha256),
            messageDigest: digest
        )
        XCTAssertEqual(empty, preparation)
    }

    func testMalformedRequirementsFailPreparationWithTheirOwnError() {
        let metadata = MachOSigningMetadata(
            requirements: CodeSigningRequirements(disposition: .malformed, set: nil)
        )
        XCTAssertThrowsError(
            try SigningMetadataPreparation.prepare(
                metadata,
                hashConfiguration: try CodeDirectoryHashConfiguration(hashType: .sha256),
                messageDigest: digest
            )
        ) { error in
            XCTAssertEqual(error as? SigningMetadataError, .requirements(.notEmbeddable))
        }
    }

    // MARK: - Signing with full metadata

    func testFullMetadataSigningEmbedsBlobsAndSpecialSlots() throws {
        let store = try NestedSigningTestIdentityStore()
        let verifier = NestedSigningTestVerifier()
        let engine = useCase(store, verifier: verifier)
        let metadata = MachOSigningMetadata(
            entitlements: try makeEntitlements(),
            requirements: CodeSigningRequirements(
                disposition: .presentAndParsed, set: try makeRequirementsSet()
            ),
            resourceSeal: try makeSealedCodeResources()
        )
        let request = try request(metadata: metadata, identity: store.id)

        let result = try engine.sign(request)

        // Result carries the exact embedded bytes and derived digests.
        XCTAssertEqual(result.entitlementsBlob,
                       try EntitlementsCanonicalSerializer().blob(try makeEntitlements()).bytes)
        XCTAssertEqual(result.requirementsBlob, try makeRequirementsSet().serialized())
        XCTAssertEqual(result.metadataSlotDigests?.entitlements?.hexString,
                       "5e0d951237bedfee269217a268ac00ccd46c6994b48387b0ccf43f5ab6e73be2")
        XCTAssertEqual(result.metadataSlotDigests?.requirements?.hexString,
                       "fb68f59a513f4cc2f81597abea1be016e966ca46747b9c293bf98f095ea16251")
        XCTAssertEqual(result.metadataSlotDigests?.codeResources?.hexString,
                       "371ce8e39d430a0e35a3b24a3e6b818f12c8674579065dbd52a7abf197e4bef8")
        // Embedding entitlements grants no platform claim.
        XCTAssertEqual(result.platformAuthorization, .notPerformed)

        // The artifact embeds the blobs in slot order, and the CodeDirectory
        // declares the derived digests in its special slots.
        let slice = try slice(of: result.artifact)
        let signature = try XCTUnwrap(slice.embeddedSignature)
        XCTAssertEqual(signature.superBlob.entries.map(\.slot),
                       [.codeDirectory, .requirements, .entitlements, .cms])
        let requirementsEntry = try XCTUnwrap(signature.superBlob.entries.first { $0.slot == .requirements })
        XCTAssertEqual(result.artifact.subdata(in: requirementsEntry.fileRange),
                       try makeRequirementsSet().serialized())
        let entitlementsEntry = try XCTUnwrap(signature.superBlob.entries.first { $0.slot == .entitlements })
        XCTAssertEqual(result.artifact.subdata(in: entitlementsEntry.fileRange),
                       result.entitlementsBlob)

        let directory = try XCTUnwrap(signature.superBlob.entries.first?.codeDirectory)
        let slotFor: (MachOSpecialHashKind) -> MachOSpecialHashSlot? = { kind in
            directory.specialSlots.first { $0.kind == kind }
        }
        XCTAssertEqual(directory.specialSlots.count, 5)
        XCTAssertEqual(slotFor(.requirements)?.hash, result.metadataSlotDigests?.requirements?.bytes)
        XCTAssertEqual(slotFor(.codeResources)?.hash, result.metadataSlotDigests?.codeResources?.bytes)
        XCTAssertEqual(slotFor(.entitlements)?.hash, result.metadataSlotDigests?.entitlements?.bytes)
        XCTAssertEqual(slotFor(.infoPlist)?.hasNonzeroBytes, false)
        XCTAssertEqual(slotFor(.application)?.hasNonzeroBytes, false)

        // Read-only inspection sees the same metadata.
        let inspection = EmbeddedSigningMetadataInspector().inspect(slice: slice, artifact: result.artifact)
        XCTAssertEqual(inspection.entitlements, .present(try makeEntitlements()))
        XCTAssertEqual(inspection.requirements.disposition, .presentAndParsed)
        XCTAssertEqual(inspection.requirements.set, try makeRequirementsSet())
        XCTAssertEqual(inspection.codeResourcesSeal,
                       .sealed(digest: result.metadataSlotDigests!.codeResources!.bytes))

        // Deterministic: the same request produces the identical artifact.
        let again = try engine.sign(request)
        XCTAssertEqual(again.artifact, result.artifact)

        // Verification holds the artifact to the prepared bytes.
        XCTAssertEqual(
            try engine.verify(artifact: result.artifact, request: request, certificate: store.certificate),
            result.codeDirectoryDigest
        )
    }

    func testEntitlementsOnlyMetadataLeavesUnoccupiedSlotsZeroed() throws {
        let store = try NestedSigningTestIdentityStore()
        let engine = useCase(store, verifier: NestedSigningTestVerifier())
        let request = try request(
            metadata: MachOSigningMetadata(entitlements: try makeEntitlements()),
            identity: store.id
        )
        let result = try engine.sign(request)

        let slice = try slice(of: result.artifact)
        let signature = try XCTUnwrap(slice.embeddedSignature)
        XCTAssertEqual(signature.superBlob.entries.map(\.slot),
                       [.codeDirectory, .entitlements, .cms])
        let directory = try XCTUnwrap(signature.superBlob.entries.first?.codeDirectory)
        XCTAssertEqual(directory.specialSlots.count, 5)
        XCTAssertEqual(
            directory.specialSlots.first { $0.kind == .entitlements }?.hash,
            result.metadataSlotDigests?.entitlements?.bytes
        )
        for kind in [MachOSpecialHashKind.requirements, .codeResources, .infoPlist, .application] {
            XCTAssertEqual(directory.specialSlots.first { $0.kind == kind }?.hasNonzeroBytes, false)
        }
        XCTAssertEqual(try engine.verify(artifact: result.artifact, request: request,
                                         certificate: store.certificate),
                       result.codeDirectoryDigest)
    }

    func testCodeResourcesOnlyContributesSlotThreeAndNoBlob() throws {
        let store = try NestedSigningTestIdentityStore()
        let engine = useCase(store, verifier: NestedSigningTestVerifier())
        let request = try request(
            metadata: MachOSigningMetadata(resourceSeal: try makeSealedCodeResources()),
            identity: store.id
        )
        let result = try engine.sign(request)

        XCTAssertNil(result.entitlementsBlob)
        XCTAssertNil(result.requirementsBlob)
        let slice = try slice(of: result.artifact)
        let signature = try XCTUnwrap(slice.embeddedSignature)
        // No requirements blob, no entitlements blob: CodeResources is a
        // bundle file digest, not a SuperBlob blob.
        XCTAssertEqual(signature.superBlob.entries.map(\.slot), [.codeDirectory, .cms])
        let directory = try XCTUnwrap(signature.superBlob.entries.first?.codeDirectory)
        XCTAssertEqual(directory.specialSlots.count, 3)
        XCTAssertEqual(
            directory.specialSlots.first { $0.kind == .codeResources }?.hash,
            result.metadataSlotDigests?.codeResources?.bytes
        )
        XCTAssertEqual(try engine.verify(artifact: result.artifact, request: request,
                                         certificate: store.certificate),
                       result.codeDirectoryDigest)
    }

    // MARK: - Tamper detection

    func testTamperedMetadataBytesFailVerification() throws {
        let store = try NestedSigningTestIdentityStore()
        let engine = useCase(store, verifier: NestedSigningTestVerifier())
        let metadata = MachOSigningMetadata(
            entitlements: try makeEntitlements(),
            requirements: CodeSigningRequirements(
                disposition: .presentAndParsed, set: try makeRequirementsSet()
            ),
            resourceSeal: try makeSealedCodeResources()
        )
        let request = try request(metadata: metadata, identity: store.id)
        let result = try engine.sign(request)
        let slice = try slice(of: result.artifact)
        let signature = try XCTUnwrap(slice.embeddedSignature)
        let directory = try XCTUnwrap(signature.superBlob.entries.first?.codeDirectory)

        func flippedArtifact(_ offset: Int) -> Data {
            var tampered = result.artifact
            tampered[offset] ^= 1
            return tampered
        }

        var offsets: [Int] = []
        // Inside the entitlements blob payload.
        offsets.append(try XCTUnwrap(signature.superBlob.entries.first { $0.slot == .entitlements })
            .fileRange.lowerBound + 8 + 5)
        // Inside the requirements blob payload.
        offsets.append(try XCTUnwrap(signature.superBlob.entries.first { $0.slot == .requirements })
            .fileRange.lowerBound + 8 + 2)
        // Inside the declared slot-3 digest in the CodeDirectory.
        offsets.append(try XCTUnwrap(directory.specialSlots.first { $0.kind == .codeResources })
            .hashRange.lowerBound)
        // Inside the declared slot-5 digest in the CodeDirectory.
        offsets.append(try XCTUnwrap(directory.specialSlots.first { $0.kind == .entitlements })
            .hashRange.lowerBound)
        // A code page byte.
        offsets.append(512)

        for offset in offsets {
            let tampered = flippedArtifact(offset)
            XCTAssertThrowsError(
                try engine.verify(artifact: tampered, request: request, certificate: store.certificate)
            ) { error in
                XCTAssertEqual(error as? MachOSigningError, .postSignVerification)
            }
        }
        XCTAssertEqual(store.signCalls, 1) // Verification never signs.
    }

    func testUnembeddableRequirementsRefusedBeforeAnyCapabilityUse() throws {
        let store = try NestedSigningTestIdentityStore()
        let engine = useCase(store, verifier: NestedSigningTestVerifier())
        let request = try request(
            metadata: MachOSigningMetadata(
                requirements: CodeSigningRequirements(disposition: .malformed, set: nil)
            ),
            identity: store.id
        )
        XCTAssertThrowsError(try engine.sign(request)) { error in
            XCTAssertEqual(error as? MachOSigningError, .requirements(.notEmbeddable))
        }
        XCTAssertEqual(store.signCalls, 0)
    }

    // MARK: - Nested code: per-target metadata

    private func makePlan(root: NestedCodeItem, nestedItems: [NestedCodeItem]) -> NestedCodeSigningPlan {
        let graph = NestedCodeDependencyGraph.structural(items: [root] + nestedItems, rootItemID: root.id)
        let steps = graph.orderedItemIDs().enumerated().map { index, id in
            NestedCodeSigningStep(order: index + 1, itemID: id)
        }
        return NestedCodeSigningPlan(
            root: root,
            nestedItems: nestedItems,
            dependencies: graph.dependencies,
            steps: steps,
            unsupportedItems: [],
            diagnostics: []
        )
    }

    func testNestedTargetsCarryTheirOwnMetadataOnly() throws {
        let identities = try NestedSigningTestIdentityStore()
        let verifier = NestedSigningTestVerifier()
        let useCase = SignNestedCodeUseCase(identities: identities, digest: digest, verifier: verifier)

        let app = makeNestedCodeItem(kind: .application, location: "")
        let framework = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/Core.framework",
            parentID: app.id,
            bundleIdentifier: "com.example.core"
        )
        let extensionItem = makeNestedCodeItem(
            kind: .applicationExtension,
            location: "PlugIns/Ext.appex",
            parentID: app.id,
            bundleIdentifier: "com.example.ext"
        )
        let plan = makePlan(root: app, nestedItems: [framework, extensionItem])

        var binaries: [BundlePath: Data] = [:]
        for item in plan.items where item.executablePath != nil {
            binaries[item.executablePath!] = MachOSigningFixtures.unsignedMachO
        }

        // Per-target metadata: the extension carries entitlements and
        // requirements; the framework carries only a resource seal; the
        // application root carries none and is not part of this use case.
        let configuration = NestedCodeSigningConfiguration(targetMetadata: [
            extensionItem.id: MachOSigningMetadata(
                entitlements: try makeEntitlements(),
                requirements: CodeSigningRequirements(
                    disposition: .presentAndParsed, set: try makeRequirementsSet()
                )
            ),
            framework.id: MachOSigningMetadata(resourceSeal: try makeSealedCodeResources()),
        ])

        let store = MemoryNestedSigningArtifactStore(binaries: binaries)
        let result = useCase.sign(
            plan: plan,
            identityID: identities.id,
            store: store,
            configuration: configuration
        )

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.summary.mutationState, .allTargetsModified(count: 2))
        XCTAssertEqual(result.itemResults.filter { $0.status.isSigned }.count, 2)

        // The extension's signature embeds its own metadata and no other
        // target's.
        let extensionBinary = try XCTUnwrap(store.binaries[extensionItem.executablePath!])
        let extensionSlice = try slice(of: extensionBinary)
        let extensionSignature = try XCTUnwrap(extensionSlice.embeddedSignature)
        XCTAssertEqual(extensionSignature.superBlob.entries.map(\.slot),
                       [.codeDirectory, .requirements, .entitlements, .cms])
        let extensionInspection = EmbeddedSigningMetadataInspector()
            .inspect(slice: extensionSlice, artifact: extensionBinary)
        XCTAssertEqual(extensionInspection.entitlements, .present(try makeEntitlements()))
        XCTAssertEqual(extensionInspection.requirements.set, try makeRequirementsSet())

        // The framework carries only the resource seal: no blobs beyond the
        // CodeDirectory and CMS, and a nonzero slot-3 digest.
        let frameworkBinary = try XCTUnwrap(store.binaries[framework.executablePath!])
        let frameworkSlice = try slice(of: frameworkBinary)
        let frameworkSignature = try XCTUnwrap(frameworkSlice.embeddedSignature)
        XCTAssertEqual(frameworkSignature.superBlob.entries.map(\.slot), [.codeDirectory, .cms])
        let frameworkInspection = EmbeddedSigningMetadataInspector()
            .inspect(slice: frameworkSlice, artifact: frameworkBinary)
        XCTAssertEqual(frameworkInspection.entitlements, .absent)
        XCTAssertEqual(frameworkInspection.requirements.disposition, .absent)
        let frameworkDirectory = try XCTUnwrap(frameworkSignature.superBlob.entries.first?.codeDirectory)
        let slotThree = try XCTUnwrap(frameworkDirectory.specialSlots.first { $0.kind == .codeResources })
        XCTAssertEqual(slotThree.hasNonzeroBytes, true)
        XCTAssertEqual(slotThree.hash,
                       try digest.digest(try makeSealedCodeResources().bytes, algorithm: .sha256).bytes)
    }

    func testNestedMetadataFailureIsStagedAndTyped() throws {
        let identities = try NestedSigningTestIdentityStore()
        let verifier = NestedSigningTestVerifier()
        let useCase = SignNestedCodeUseCase(identities: identities, digest: digest, verifier: verifier)

        let app = makeNestedCodeItem(kind: .application, location: "")
        let framework = makeNestedCodeItem(
            kind: .framework,
            location: "Frameworks/Core.framework",
            parentID: app.id,
            bundleIdentifier: "com.example.core"
        )
        let plan = makePlan(root: app, nestedItems: [framework])

        var binaries: [BundlePath: Data] = [:]
        for item in plan.items where item.executablePath != nil {
            binaries[item.executablePath!] = MachOSigningFixtures.unsignedMachO
        }

        // A requirements value recorded malformed is refused at the metadata
        // boundary, reported as a metadata failure, and — under the staged
        // strategy — leaves the artifact untouched.
        let configuration = NestedCodeSigningConfiguration(targetMetadata: [
            framework.id: MachOSigningMetadata(
                requirements: CodeSigningRequirements(disposition: .malformed, set: nil)
            ),
        ])
        let store = MemoryNestedSigningArtifactStore(binaries: binaries)
        let result = useCase.sign(
            plan: plan,
            identityID: identities.id,
            store: store,
            configuration: configuration
        )

        guard case .failed(let failure) = result.status else {
            return XCTFail("Expected the metadata failure to fail the run")
        }
        XCTAssertEqual(failure.reason, .signingMetadataFailure)
        XCTAssertEqual(result.summary.mutationState, .noTargetsModified)
        XCTAssertEqual(store.binaries[framework.executablePath!], MachOSigningFixtures.unsignedMachO)
    }
}
