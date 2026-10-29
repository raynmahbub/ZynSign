import Foundation

/// Controlled, in-memory single-image signing. No files, profiles, bundles,
/// installation, or presentation state participate in this use case.
struct SignMachOUseCase {
    private let identities: any IdentityStore
    private let digest: any MessageDigest
    private let verifier: any CryptographicSignatureVerifier
    private let parser = ReadOnlyMachOParser()
    private let writer = MachOCodeSignatureWriter()

    init(identities: any IdentityStore, digest: any MessageDigest,
         verifier: any CryptographicSignatureVerifier) {
        self.identities = identities
        self.digest = digest
        self.verifier = verifier
    }

    func sign(_ request: MachOSigningRequest) throws -> MachOSigningResult {
        try request.validate()
        // Signing metadata is prepared before anything else: the exact
        // entitlements and requirements bytes are serialized and framed, each
        // blob's digest is computed, and the special slots are finalized.
        // The CodeDirectory — and everything signed after it — can then be
        // built over complete slot contents. The CodeDirectory is never
        // signed before every special-slot input is final.
        let preparation = try prepareMetadata(request.metadata,
                                               hashConfiguration: request.codeDirectory.hashConfiguration)
        let effectiveCodeDirectory = request.codeDirectory.replacingSpecialSlots(
            preparation.slotDigests.specialSlots(hashSize: request.codeDirectory.hashConfiguration.hashSize)
        )
        let image: MachOImage
        do { image = try parser.parse(request.artifact) }
        catch let error as MachOParsingError { throw MachOSigningError.invalidMachO(error) }
        try Self.checkSupportedImage(image)
        // The offset depends only on the original length, not on CMS contents.
        let offsetPlan = try MachOCodeSignatureRegionLayout(
            appendingSerializedSuperBlobLength: 1, toFileLength: request.artifact.count)
        guard request.codeDirectory.codeLimit == UInt64(offsetPlan.offset) else {
            throw MachOSigningError.invalidCodeLimit
        }
        guard let identityID = request.identityID else { throw MachOSigningError.identityUnavailable }
        let certificate: Certificate
        do { certificate = try identities.signingCertificate(for: identityID) }
        catch let error as ZynSignError where error.identityFailure == .identityNotFound {
            throw MachOSigningError.identityUnavailable
        }
        catch { throw MachOSigningError.certificateUnavailable }
        let cms: DetachedCodeSignatureCMS
        do { cms = try DetachedCodeSignatureCMS(certificate: certificate) }
        catch let error as MachOSigningError { throw error }
        catch { throw MachOSigningError.certificateUnavailable }

        // Size-only planning uses placeholder hashes, never a placeholder
        // cryptographic operation. No placeholder artifact escapes this method.
        let plannedDirectory = try directorySize(effectiveCodeDirectory)
        let cmsLength: Int
        do { cmsLength = try cms.plannedLength() }
        catch { throw MachOSigningError.signatureBlobConstruction }
        // Slot order: CodeDirectory (0), requirements (2), entitlements (5),
        // CMS (0x10000). CodeResources contributes no SuperBlob blob.
        var plannedBlobLengths = [plannedDirectory]
        if let requirementsBytes = preparation.requirementsSetBytes {
            plannedBlobLengths.append(requirementsBytes.count)
        }
        if let entitlementsBlob = preparation.entitlementsBlob {
            plannedBlobLengths.append(entitlementsBlob.serializedLength)
        }
        plannedBlobLengths.append(cmsLength + 8)
        let plannedSuperBlob: SuperBlobLayout
        do {
            plannedSuperBlob = try SuperBlobLayout(blobLengths: plannedBlobLengths)
        } catch { throw MachOSigningError.superBlobConstruction }
        let prepared: MachOCodeSignaturePreparation
        do {
            prepared = try writer.prepare(request.artifact,
                serializedSuperBlobLength: plannedSuperBlob.length,
                signedCodeLimit: request.codeDirectory.codeLimit,
                existingSignaturePolicy: request.existingSignaturePolicy)
        } catch let error as MachOCodeSignatureRegionError { throw MachOSigningError.layout(error) }
        // Writer output must also fit the parser that will validate it.
        guard prepared.layout.resultingFileLength <= ReadOnlyMachOParser.maximumInputBytes else {
            throw MachOSigningError.resourceLimitExceeded
        }
        let directory: CodeDirectory
        do {
            directory = try CodeDirectoryConstructor(messageDigest: digest)
                .construct(effectiveCodeDirectory, code: prepared.prefix)
        } catch let error as CodeDirectoryError { throw MachOSigningError.codeDirectoryConstruction(error) }
        catch { throw MachOSigningError.digestFailure }
        let directoryBlob: CodeSignatureBlob
        do { directoryBlob = try .codeDirectory(directory) }
        catch { throw MachOSigningError.codeDirectorySerialization }
        guard directoryBlob.bytes.count == plannedDirectory else {
            throw MachOSigningError.codeDirectorySerialization
        }
        let contentDigest = try sha256(directoryBlob.bytes)
        let attributes: Data
        do { attributes = try cms.signedAttributes(contentDigest: contentDigest.bytes) }
        catch { throw MachOSigningError.signatureBlobConstruction }
        let signingDigest = try sha256(attributes)

        // The only private operation is below, after all input/layout checks.
        let capability: any SigningCapability
        do { capability = try identities.signingCapability(for: identityID) }
        catch { throw MachOSigningError.identityUnavailable }
        guard capability.identityID == identityID, capability.isAvailable else {
            throw MachOSigningError.identityUnavailable
        }
        guard capability.publicKeyAlgorithm == .rsa,
              capability.supportedAlgorithms.contains(request.algorithm) else {
            throw MachOSigningError.unsupportedSigningAlgorithm
        }
        let signed: SigningResult
        do {
            signed = try CapabilitySigningEngine().sign(
                SigningRequest(identityID: identityID, algorithm: request.algorithm,
                               input: .digest(signingDigest)), capability: capability)
        } catch { throw MachOSigningError.signingCapabilityFailure }
        let cmsBlob: CodeSignatureBlob
        do { cmsBlob = try cms.blob(contentDigest: contentDigest.bytes, signature: signed.signature) }
        catch { throw MachOSigningError.signatureBlobConstruction }
        var blobEntries: [CodeSignatureBlobEntry]
        do {
            blobEntries = [try CodeSignatureBlobEntry(type: .codeDirectory, blob: directoryBlob)]
            if let requirementsSet = preparation.requirementsSet {
                blobEntries.append(try CodeSignatureBlobEntry(
                    type: .requirements, blob: .requirements(requirementsSet)))
            }
            if let entitlementsBlob = preparation.entitlementsBlob {
                blobEntries.append(try CodeSignatureBlobEntry(
                    type: .entitlements, blob: .entitlements(blob: entitlementsBlob)))
            }
            blobEntries.append(try CodeSignatureBlobEntry(type: .cms, blob: cmsBlob))
        } catch { throw MachOSigningError.superBlobConstruction }
        let superBlob: SuperBlobSerialization
        do {
            superBlob = try SignatureSuperBlob(entries: blobEntries).serialize()
            try superBlob.validate()
        } catch { throw MachOSigningError.superBlobConstruction }
        let output: MachOCodeSignatureMutationResult
        do {
            let region = try MachOCodeSignatureRegion(serializedSuperBlob: superBlob)
            output = try writer.finalize(prepared, region: region)
        } catch let error as MachOCodeSignatureRegionError { throw MachOSigningError.mutation(error) }
        guard output.bytes.prefix(prepared.prefix.count) == prepared.prefix else {
            throw MachOSigningError.postSignVerification
        }
        let checkedDigest = try verify(artifact: output.bytes, request: request, certificate: certificate)
        guard checkedDigest == contentDigest else { throw MachOSigningError.postSignVerification }
        return MachOSigningResult(
            artifact: output.bytes,
            codeDirectory: directoryBlob.bytes,
            codeDirectoryDigest: contentDigest,
            layout: output.layout,
            cryptographicSignature: signed.signature,
            entitlementsBlob: preparation.entitlementsBlob?.bytes,
            requirementsBlob: preparation.requirementsSetBytes,
            metadataSlotDigests: preparation.slotDigests.isEmpty ? nil : preparation.slotDigests
        )
    }

    /// Re-verifies from final artifact bytes, not cached signing models. Useful
    /// for the controlled harness too; it neither resolves nor invokes a key.
    ///
    /// Verification re-derives the metadata preparation from the request, so
    /// a signature cannot verify against metadata bytes that differ from the
    /// ones the caller asked to embed: the embedded entitlements and
    /// requirements blobs are compared byte for byte, and the CodeDirectory's
    /// declared special-slot digests are compared against the re-derived
    /// digests for slots 2, 3, and 5.
    func verify(artifact: Data, request: MachOSigningRequest, certificate: Certificate) throws -> Digest {
        do {
            try request.validate()
            let preparation = try prepareMetadata(request.metadata,
                                                   hashConfiguration: request.codeDirectory.hashConfiguration)
            let effectiveCodeDirectory = request.codeDirectory.replacingSpecialSlots(
                preparation.slotDigests.specialSlots(hashSize: request.codeDirectory.hashConfiguration.hashSize)
            )
            guard artifact.startIndex == 0 else { throw MachOSigningError.postSignVerification }
            let image = try parser.parse(artifact)
            var expectedSlots: [CodeSignatureBlobType] = [.codeDirectory]
            if preparation.requirementsSet != nil { expectedSlots.append(.requirements) }
            if preparation.entitlementsBlob != nil { expectedSlots.append(.entitlements) }
            expectedSlots.append(.cms)
            guard case .thin(let slice) = image.container,
                  let embedded = slice.embeddedSignature,
                  embedded.command.dataOffset == Int(request.codeDirectory.codeLimit),
                  embedded.command.fileRange.upperBound == artifact.count,
                  embedded.superBlob.entries.count == expectedSlots.count,
                  embedded.superBlob.entries.map(\.slot) == expectedSlots,
                  let cd = embedded.superBlob.entries.first(where: { $0.slot == .codeDirectory }),
                  let cmsEntry = embedded.superBlob.entries.first(where: { $0.slot == .cms }),
                  cd.codeDirectory != nil,
                  artifact[embedded.superBlob.fileRange.upperBound..<artifact.count].allSatisfy({ $0 == 0 }) else {
                throw MachOSigningError.postSignVerification
            }
            // Embedded metadata blobs must be the exact prepared bytes.
            if let requirementsBytes = preparation.requirementsSetBytes {
                guard let requirementsEntry = embedded.superBlob.entries.first(where: { $0.slot == .requirements }),
                      artifact.subdata(in: requirementsEntry.fileRange) == requirementsBytes else {
                    throw MachOSigningError.postSignVerification
                }
            }
            if let entitlementsBlob = preparation.entitlementsBlob {
                guard let entitlementsEntry = embedded.superBlob.entries.first(where: { $0.slot == .entitlements }),
                      artifact.subdata(in: entitlementsEntry.fileRange) == entitlementsBlob.bytes else {
                    throw MachOSigningError.postSignVerification
                }
            }
            // Declared special-slot digests must match the re-derived digests.
            let declaredDirectory = cd.codeDirectory
            for (kind, expected) in [
                (MachOSpecialHashKind.requirements, preparation.slotDigests.requirements),
                (MachOSpecialHashKind.codeResources, preparation.slotDigests.codeResources),
                (MachOSpecialHashKind.entitlements, preparation.slotDigests.entitlements)
            ] {
                guard let expected else { continue }
                guard let slot = declaredDirectory?.specialSlots.first(where: { $0.kind == kind }),
                      slot.hash == Data(expected.bytes.prefix(slot.hash.count)) else {
                    throw MachOSigningError.postSignVerification
                }
            }
            let reconstructed = try CodeDirectoryConstructor(messageDigest: digest)
                .construct(effectiveCodeDirectory, code: artifact).serialize()
            let directoryBytes = artifact.subdata(in: cd.fileRange)
            guard directoryBytes == reconstructed.bytes else { throw MachOSigningError.postSignVerification }
            let signatureBytes = artifact.subdata(in: (cmsEntry.fileRange.lowerBound + 8)..<cmsEntry.fileRange.upperBound)
            let cms = try DetachedCodeSignatureCMS(certificate: certificate)
            try cms.verify(signatureBytes, codeDirectory: directoryBytes, digest: digest, verifier: verifier)
            return try sha256(directoryBytes)
        } catch { throw MachOSigningError.postSignVerification }
    }

    /// Prepares signing metadata, mapping each component boundary's failure
    /// into the signing stage error for that component.
    private func prepareMetadata(
        _ metadata: MachOSigningMetadata?,
        hashConfiguration: CodeDirectoryHashConfiguration
    ) throws -> SigningMetadataPreparation {
        do {
            return try SigningMetadataPreparation.prepare(
                metadata,
                hashConfiguration: hashConfiguration,
                messageDigest: digest
            )
        } catch let error as SigningMetadataError {
            switch error {
            case .entitlements(let entitlementsError):
                throw MachOSigningError.entitlements(entitlementsError)
            case .requirements(let requirementsError):
                throw MachOSigningError.requirements(requirementsError)
            case .resourceSeal(let resourceSealError):
                throw MachOSigningError.resourceSeal(resourceSealError)
            case .emptyInfoPlist:
                throw MachOSigningError.emptyInfoPlist
            case .digestFailure:
                throw MachOSigningError.digestFailure
            }
        } catch {
            throw MachOSigningError.digestFailure
        }
    }

    private func sha256(_ bytes: Data) throws -> Digest {
        do {
            let result = try digest.digest(bytes, algorithm: .sha256)
            guard result.algorithm == .sha256 else { throw MachOSigningError.digestFailure }
            return result
        } catch { throw MachOSigningError.digestFailure }
    }

    private func directorySize(_ request: CodeDirectoryConstructionRequest) throws -> Int {
        do {
            let count = try CodeDirectory.expectedCodeSlotCount(codeLimit: request.codeLimit, pageSize: request.pageSize)
            let slots = (0..<count).map { CodeDirectoryCodeSlot(index: $0, hash: Data(repeating: 0, count: 32)) }
            let directory = try CodeDirectory(version: request.version, flags: request.flags,
                identifier: request.identifier, teamIdentifier: request.teamIdentifier,
                platform: request.platform, hashConfiguration: request.hashConfiguration,
                pageSize: request.pageSize, codeLimit: request.codeLimit,
                specialSlots: request.specialSlots, codeSlots: slots)
            return try CodeDirectorySerializer().makeLayout(for: directory).length
        } catch let error as CodeDirectoryError { throw MachOSigningError.codeDirectoryConstruction(error) }
    }

    /// The read-only image admission rule the signer applies before any key
    /// operation. Diagnostics reuse it instead of guessing support from a
    /// Mach-O header.
    ///
    /// The rule describes *forms this build signs*, not one known byte layout:
    /// a thin little-endian 64-bit arm64 image that is either an executable or
    /// a dynamic library, carries no existing signature, is not encrypted, and
    /// has exactly one `__LINKEDIT` segment. Everything the append actually
    /// needs — zero load-command padding, a `__LINKEDIT` file range ending at
    /// the file end, virtual-memory room for the region — is re-checked by
    /// `MachOCodeSignatureWriter`, which fails before a key is used.
    ///
    /// Universal containers are still refused here. A container is a table of
    /// images; signing one means signing each slice and rebuilding the table,
    /// which is a different code path from this single-image signer.
    static func checkSupportedImage(_ image: MachOImage) throws {
        guard case .thin(let slice) = image.container else { throw MachOSigningError.unsupportedMachOForm }
        if slice.embeddedSignature != nil { throw MachOSigningError.layout(.existingSignatureRejected) }
        guard slice.header.wordSize == .bits64,
              slice.header.byteOrder == .littleEndian,
              slice.header.cpu == .arm64,
              slice.header.fileType == Self.executableFileType
                || slice.header.fileType == Self.dynamicLibraryFileType else {
            throw MachOSigningError.unsupportedMachOForm
        }
        // An encrypted image is refused, not signed around: the signature would
        // describe ciphertext the device rewrites at load time.
        guard !slice.loadCommands.contains(where: {
            $0.type == Self.encryptionInfoCommand || $0.type == Self.encryptionInfo64Command
        }) else {
            throw MachOSigningError.unsupportedMachOForm
        }
        guard slice.segments.filter(\.isLinkEdit).count == 1 else {
            throw MachOSigningError.unsupportedMachOForm
        }
    }

    /// `MH_EXECUTE`.
    private static let executableFileType: UInt32 = 2
    /// `MH_DYLIB` — frameworks and nested dylibs carry this type.
    private static let dynamicLibraryFileType: UInt32 = 6
    private static let encryptionInfoCommand: UInt32 = 0x21
    private static let encryptionInfo64Command: UInt32 = 0x2C
}
