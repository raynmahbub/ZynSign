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
        let image: MachOImage
        do { image = try parser.parse(request.artifact) }
        catch let error as MachOParsingError { throw MachOSigningError.invalidMachO(error) }
        try admit(image)
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
        let plannedDirectory = try directorySize(request.codeDirectory)
        let cmsLength: Int
        do { cmsLength = try cms.plannedLength() }
        catch { throw MachOSigningError.signatureBlobConstruction }
        let plannedSuperBlob: SuperBlobLayout
        do {
            plannedSuperBlob = try SuperBlobLayout(blobLengths: [plannedDirectory, cmsLength + 8])
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
                .construct(request.codeDirectory, code: prepared.prefix)
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
        let superBlob: SuperBlobSerialization
        do {
            superBlob = try SignatureSuperBlob(entries: [
                CodeSignatureBlobEntry(type: .codeDirectory, blob: directoryBlob),
                CodeSignatureBlobEntry(type: .cms, blob: cmsBlob)
            ]).serialize()
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
        return MachOSigningResult(artifact: output.bytes, codeDirectory: directoryBlob.bytes,
                                 codeDirectoryDigest: contentDigest, layout: output.layout,
                                 cryptographicSignature: signed.signature)
    }

    /// Re-verifies from final artifact bytes, not cached signing models. Useful
    /// for the controlled harness too; it neither resolves nor invokes a key.
    func verify(artifact: Data, request: MachOSigningRequest, certificate: Certificate) throws -> Digest {
        do {
            try request.validate()
            guard artifact.startIndex == 0 else { throw MachOSigningError.postSignVerification }
            let image = try parser.parse(artifact)
            guard case .thin(let slice) = image.container,
                  let embedded = slice.embeddedSignature,
                  embedded.command.dataOffset == Int(request.codeDirectory.codeLimit),
                  embedded.command.fileRange.upperBound == artifact.count,
                  embedded.superBlob.entries.count == 2,
                  let cd = embedded.superBlob.entries.first(where: { $0.slot == .codeDirectory }),
                  let cmsEntry = embedded.superBlob.entries.first(where: { $0.slot == .cms }),
                  cd.codeDirectory != nil,
                  artifact[embedded.superBlob.fileRange.upperBound..<artifact.count].allSatisfy({ $0 == 0 }) else {
                throw MachOSigningError.postSignVerification
            }
            let reconstructed = try CodeDirectoryConstructor(messageDigest: digest)
                .construct(request.codeDirectory, code: artifact).serialize()
            let directoryBytes = artifact.subdata(in: cd.fileRange)
            guard directoryBytes == reconstructed.bytes else { throw MachOSigningError.postSignVerification }
            let signatureBytes = artifact.subdata(in: (cmsEntry.fileRange.lowerBound + 8)..<cmsEntry.fileRange.upperBound)
            let cms = try DetachedCodeSignatureCMS(certificate: certificate)
            try cms.verify(signatureBytes, codeDirectory: directoryBytes, digest: digest, verifier: verifier)
            return try sha256(directoryBytes)
        } catch { throw MachOSigningError.postSignVerification }
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

    /// An explicit synthetic executable model: two non-overlapping segments,
    /// one file-backed text section, no encryption or unhandled load commands.
    /// Other valid Mach-O layouts are unsupported, not silently generalized.
    private func admit(_ image: MachOImage) throws {
        guard case .thin(let slice) = image.container else { throw MachOSigningError.unsupportedMachOForm }
        if slice.embeddedSignature != nil { throw MachOSigningError.layout(.existingSignatureRejected) }
        guard slice.header.wordSize == .bits64, slice.header.byteOrder == .littleEndian,
              slice.header.cpu == .arm64, slice.header.cpuSubtype == 0,
              slice.header.fileType == 2, slice.header.flags == 0x20,
              slice.header.reserved == 0,
              slice.loadCommands.count == 2,
              slice.loadCommands.allSatisfy({ $0.type == MachOLoadCommandType.segment64 }),
              slice.segments.count == 2 else { throw MachOSigningError.unsupportedMachOForm }
        let text = slice.segments[0]
        let link = slice.segments[1]
        let textName = Array("__TEXT".utf8) + Array(repeating: UInt8(0), count: 10)
        guard text.name.rawBytes == textName, link.isLinkEdit,
              text.fileOffset == 0, text.fileSize > 0,
              text.fileSize == link.fileOffset,
              text.fileSize <= text.virtualMemorySize,
              text.sectionCount == 1, let section = text.sections.first,
              text.maximumProtection == 7, text.initialProtection == 5, text.flags == 0,
              link.maximumProtection == 7, link.initialProtection == 1, link.flags == 0,
              link.sectionCount == 0,
              text.virtualMemoryAddress % 4096 == 0, link.virtualMemoryAddress % 4096 == 0,
              text.fileSize % 4096 == 0,
              section.name == Array("__text".utf8) + Array(repeating: UInt8(0), count: 10),
              section.segmentName == textName,
              section.flags == 0x80000400, section.alignmentExponent == 2,
              section.fileOffset % 4 == 0, section.size > 0,
              section.relocationOffset == 0, section.relocationCount == 0,
              section.reserved1 == 0, section.reserved2 == 0, section.reserved3 == 0 else {
            throw MachOSigningError.unsupportedMachOForm
        }
        // The parser already proved section.fileOffset + size fits text's file
        // extent. Require this single section to cover the rest of text and to
        // have the same file/VM mapping; no unmodeled relocations are admitted.
        guard section.size == text.fileSize - section.fileOffset else {
            throw MachOSigningError.unsupportedMachOForm
        }
        let (sectionAddress, sectionOverflow) = text.virtualMemoryAddress.addingReportingOverflow(section.fileOffset)
        guard !sectionOverflow, section.virtualAddress == sectionAddress else {
            throw MachOSigningError.unsupportedMachOForm
        }
        let (textEnd, textOverflow) = text.virtualMemoryAddress.addingReportingOverflow(text.virtualMemorySize)
        let (_, linkOverflow) = link.virtualMemoryAddress.addingReportingOverflow(link.virtualMemorySize)
        guard !textOverflow, !linkOverflow, textEnd <= link.virtualMemoryAddress else {
            throw MachOSigningError.unsupportedMachOForm
        }
    }
}
