import Foundation

/// The resource-seal input to signing: the exact CodeResources bytes.
///
/// The conceptual boundary this type pins down is:
///
///     resource tree → CodeResources bytes → digest → CodeDirectory slot 3
///
/// The bytes are carried, not the tree: by the time a target's resources are
/// sealed, the document is finished data, and the pipeline must hash exactly
/// what was sealed — never a re-serialization, and never the signature
/// region, the CodeDirectory, or the SuperBlob, which are not resource
/// content.
struct SealedCodeResources: Equatable, Hashable {

    /// The upper bound for one sealed CodeResources document. ZynSign policy.
    static let maximumByteCount = CodeResourcesSerializer.maximumDocumentByteCount

    /// The exact serialized document bytes. These are the bytes whose digest
    /// occupies CodeDirectory special slot 3.
    let bytes: Data

    /// Creates a seal from exact bytes. The bytes are trusted to be a
    /// finished CodeResources document; they are hashed verbatim and never
    /// re-parsed or re-serialized on this path.
    init(bytes: Data) throws {
        guard !bytes.isEmpty else { throw CodeResourcesError.emptyInput }
        guard bytes.count <= Self.maximumByteCount else {
            throw CodeResourcesError.inputTooLarge
        }
        self.bytes = bytes
    }

    /// Creates a seal by serializing a document canonically.
    init(document: CodeResourcesDocument) throws {
        let serialized = try document.serialized()
        try self.init(bytes: serialized)
    }

    /// The document, when the bytes parse as the supported subset. Optional
    /// tooling; the signing path never needs it.
    func parseDocument() throws -> CodeResourcesDocument {
        try CodeResourcesParser.parse(bytes)
    }
}

/// The signing metadata for one signing target.
///
/// Metadata is per target by construction: the entitlements, requirements,
/// and resource seal that apply to the main application executable are not
/// assumed to apply to a framework, an extension, or a plug-in, and nothing
/// in this model copies a parent's metadata into a child. A target that has
/// no metadata signs exactly as ZS-026/028 did, with no special slots and a
/// two-blob SuperBlob.
///
/// Each component keeps its own stage vocabulary:
///
/// - `entitlements` is decoded, structurally valid data — provisioning
///   compatibility is evaluated separately through
///   `EntitlementsProvisioningValidation`, and platform authorization is
///   never claimed;
/// - `requirements` carries its framing disposition, and embedding preserves
///   its bytes without interpreting the expression language;
/// - `resourceSeal` is finished CodeResources bytes, digested verbatim into
///   special slot 3.
struct MachOSigningMetadata: Equatable {

    let entitlements: CodeSigningEntitlements?
    let requirements: CodeSigningRequirements?
    let resourceSeal: SealedCodeResources?

    init(
        entitlements: CodeSigningEntitlements? = nil,
        requirements: CodeSigningRequirements? = nil,
        resourceSeal: SealedCodeResources? = nil
    ) {
        self.entitlements = entitlements
        self.requirements = requirements
        self.resourceSeal = resourceSeal
    }

    /// Whether any component is present.
    var isEmpty: Bool {
        entitlements == nil && requirements == nil && resourceSeal == nil
    }

    /// Validates that every present component can actually be embedded.
    ///
    /// An entitlement set is always embeddable (it was constructed). A
    /// requirements value must either be absent, carry the absent
    /// disposition, or carry an embeddable set — a value whose framing was
    /// recorded malformed is refused here, at the boundary, before any
    /// cryptographic operation happens.
    func validateForEmbedding() throws {
        if let requirements {
            switch requirements.disposition {
            case .absent:
                break
            case .presentAndParsed, .presentButUnsupported, .generated:
                guard requirements.set != nil else {
                    throw RequirementsError.notEmbeddable
                }
            case .malformed, .verified:
                throw RequirementsError.notEmbeddable
            }
        }
    }
}

/// The digests of signing metadata, each destined for one CodeDirectory
/// special slot.
///
/// Slot assignments, all **Verified** against the Apple open-source headers
/// and the parser's own `CodeDirectorySpecialSlotKind`:
///
/// - slot 2 — the requirements blob (embedded in the SuperBlob);
/// - slot 3 — the CodeResources *file* bytes (not a SuperBlob blob);
/// - slot 5 — the entitlements blob (embedded in the SuperBlob).
///
/// The digest inputs are **Observed** across consistent independent
/// reimplementations of the format: for slots 2 and 5 the hash covers the
/// complete embedded blob including its eight-byte header; for slot 3 it
/// covers the CodeResources file content, which is not part of the SuperBlob
/// at all. Byte-exact agreement with Apple's signer is recorded as requiring
/// experiment in the architecture document.
struct SigningMetadataSlotDigests: Equatable {

    let requirements: Digest?
    let codeResources: Digest?
    let entitlements: Digest?

    /// Whether any digest is present.
    var isEmpty: Bool {
        requirements == nil && codeResources == nil && entitlements == nil
    }

    /// The special slots in CodeDirectory construction order: contiguous
    /// indices from 1 to the highest occupied slot, with absent reserved
    /// slots represented as zero-hash placeholders.
    ///
    /// A zero-filled reserved slot is the format's absence representation,
    /// not an invented digest. Note what this does **not** do: it never
    /// produces the Info.plist digest of slot 1. An iOS application
    /// executable's slot 1 carries its bundle's Info.plist hash; producing
    /// that belongs to bundle-level signing, not to this layer.
    ///
    /// - Parameter hashSize: the CodeDirectory's per-slot hash size. A full
    ///   digest longer than the slot size keeps its first `hashSize` bytes,
    ///   the same truncation rule the page-hash path applies.
    func specialSlots(hashSize: Int) -> [CodeDirectorySpecialSlot] {
        var highest = 0
        if requirements != nil { highest = max(highest, CodeDirectorySpecialSlotKind.requirements.slotIndex) }
        if codeResources != nil { highest = max(highest, CodeDirectorySpecialSlotKind.codeResources.slotIndex) }
        if entitlements != nil { highest = max(highest, CodeDirectorySpecialSlotKind.entitlements.slotIndex) }
        guard highest > 0 else { return [] }
        var slots: [CodeDirectorySpecialSlot] = []
        slots.reserveCapacity(highest)
        for index in 1...highest {
            switch index {
            case CodeDirectorySpecialSlotKind.requirements.slotIndex:
                slots.append(CodeDirectorySpecialSlot(
                    kind: .requirements,
                    hash: requirements.map { truncated($0, hashSize: hashSize) }
                ))
            case CodeDirectorySpecialSlotKind.codeResources.slotIndex:
                slots.append(CodeDirectorySpecialSlot(
                    kind: .codeResources,
                    hash: codeResources.map { truncated($0, hashSize: hashSize) }
                ))
            case CodeDirectorySpecialSlotKind.entitlements.slotIndex:
                slots.append(CodeDirectorySpecialSlot(
                    kind: .entitlements,
                    hash: entitlements.map { truncated($0, hashSize: hashSize) }
                ))
            default:
                slots.append(CodeDirectorySpecialSlot(index: index, hash: nil))
            }
        }
        return slots
    }

    /// Applies the CodeDirectory's hash-size truncation to a full digest,
    /// mirroring the page-hash path: a digest longer than the slot size
    /// keeps its first `hashSize` bytes.
    private func truncated(_ digest: Digest, hashSize: Int) -> Data {
        guard digest.bytes.count > hashSize else { return digest.bytes }
        return Data(digest.bytes.prefix(hashSize))
    }
}

extension CodeDirectoryConstructionRequest {
    /// Returns a copy whose special slots are replaced.
    ///
    /// Used by the signing pipeline to inject metadata-derived slots into its
    /// own construction step; a caller-visible request still carries none, so
    /// there is exactly one path from metadata bytes to slot digests.
    func replacingSpecialSlots(
        _ specialSlots: [CodeDirectorySpecialSlot]
    ) -> CodeDirectoryConstructionRequest {
        CodeDirectoryConstructionRequest(
            version: version,
            flags: flags,
            identifier: identifier,
            teamIdentifier: teamIdentifier,
            platform: platform,
            hashConfiguration: hashConfiguration,
            pageSize: pageSize,
            codeLimit: codeLimit,
            specialSlots: specialSlots
        )
    }
}

/// The stage error for signing-metadata preparation: each component keeps
/// its own boundary's failure, and digest-port failures keep their own case
/// so no component is blamed for another's refusal.
enum SigningMetadataError: Error, Equatable {
    case entitlements(EntitlementsError)
    case requirements(RequirementsError)
    case resourceSeal(ResourceSealError)
    case digestFailure
}

/// The prepared, immutable inputs the signing pipeline embeds.
///
/// Preparation is the single place where the ordering constraint of the
/// signing pipeline is enforced:
///
/// 1. the entitlements payload is canonically serialized and framed;
/// 2. the requirements set is serialized;
/// 3. each blob's exact bytes are digested;
/// 4. the digests become CodeDirectory special slots.
///
/// Only after all of that does the pipeline construct the CodeDirectory,
/// hash it, and sign that digest. The CodeDirectory is never signed before
/// every special-slot input is final.
struct SigningMetadataPreparation: Equatable {

    let entitlementsBlob: EntitlementsBlob?

    /// The embedded-entitlements record, when this target carried
    /// entitlements: the exact blob bytes, the digest destined for special
    /// slot 5, and the explicit `notEvaluated` platform-authorization state.
    /// Embedding is the only fact asserted here.
    let entitlementsRecord: EmbeddedEntitlementsRecord?

    let requirementsSet: RequirementsSet?
    let requirementsSetBytes: Data?
    let slotDigests: SigningMetadataSlotDigests

    /// The SuperBlob entries this preparation contributes, in slot order.
    /// CodeResources contributes none: slot 3 hashes a bundle file, not an
    /// embedded blob.
    var contributesSuperBlobEntries: Bool {
        entitlementsBlob != nil || requirementsSetBytes != nil
    }

    /// Prepares metadata for embedding under one hash configuration.
    ///
    /// - Parameters:
    ///   - metadata: The target's metadata, or `nil` / empty for none.
    ///   - hashConfiguration: The CodeDirectory's hashing configuration. The
    ///     digest algorithm is taken from it, so a special-slot digest always
    ///     matches the directory that carries it.
    ///   - messageDigest: The digest port.
    /// - Throws: `SigningMetadataError`, whose cases preserve the refusing
    ///   component's own error type.
    static func prepare(
        _ metadata: MachOSigningMetadata?,
        hashConfiguration: CodeDirectoryHashConfiguration,
        messageDigest: any MessageDigest
    ) throws -> SigningMetadataPreparation {
        guard let metadata, !metadata.isEmpty else {
            return SigningMetadataPreparation(
                entitlementsBlob: nil,
                entitlementsRecord: nil,
                requirementsSet: nil,
                requirementsSetBytes: nil,
                slotDigests: SigningMetadataSlotDigests(
                    requirements: nil,
                    codeResources: nil,
                    entitlements: nil
                )
            )
        }
        do { try metadata.validateForEmbedding() }
        catch let error as RequirementsError { throw SigningMetadataError.requirements(error) }
        catch { throw SigningMetadataError.requirements(.notEmbeddable) }

        var entitlementsBlob: EntitlementsBlob?
        var entitlementsRecord: EmbeddedEntitlementsRecord?
        var requirementsSet: RequirementsSet?
        var requirementsBytes: Data?
        var entitlementsDigest: Digest?
        var requirementsDigest: Digest?
        var codeResourcesDigest: Digest?

        if let entitlements = metadata.entitlements {
            let blob: EntitlementsBlob
            do {
                blob = try EntitlementsCanonicalSerializer().blob(entitlements)
            } catch let error as EntitlementsError {
                throw SigningMetadataError.entitlements(error)
            }
            entitlementsBlob = blob
            let digest = try slotDigest(blob.bytes, hashConfiguration: hashConfiguration, messageDigest: messageDigest)
            entitlementsDigest = digest
            entitlementsRecord = EmbeddedEntitlementsRecord(
                blobBytes: blob.bytes,
                specialSlotDigest: digest,
                platformAuthorization: .notEvaluated
            )
        }

        if let requirements = metadata.requirements, requirements.requiresEmbedding,
           let set = requirements.set {
            let bytes: Data
            do {
                bytes = try set.serialized()
            } catch let error as RequirementsError {
                throw SigningMetadataError.requirements(error)
            }
            requirementsSet = set
            requirementsBytes = bytes
            requirementsDigest = try slotDigest(bytes, hashConfiguration: hashConfiguration, messageDigest: messageDigest)
        }

        if let resourceSeal = metadata.resourceSeal {
            codeResourcesDigest = try slotDigest(resourceSeal.bytes, hashConfiguration: hashConfiguration, messageDigest: messageDigest)
        }

        return SigningMetadataPreparation(
            entitlementsBlob: entitlementsBlob,
            entitlementsRecord: entitlementsRecord,
            requirementsSet: requirementsSet,
            requirementsSetBytes: requirementsBytes,
            slotDigests: SigningMetadataSlotDigests(
                requirements: requirementsDigest,
                codeResources: codeResourcesDigest,
                entitlements: entitlementsDigest
            )
        )
    }

    /// Digests the exact bytes a special slot covers, under the directory's
    /// hash configuration. The digest algorithm is taken from the
    /// configuration; a port result of a different algorithm is a failure.
    private static func slotDigest(
        _ bytes: Data,
        hashConfiguration: CodeDirectoryHashConfiguration,
        messageDigest: any MessageDigest
    ) throws -> Digest {
        let digest: Digest
        do {
            digest = try messageDigest.digest(bytes, algorithm: hashConfiguration.digestAlgorithm)
        } catch {
            throw SigningMetadataError.digestFailure
        }
        guard digest.algorithm == hashConfiguration.digestAlgorithm,
              digest.bytes.count == hashConfiguration.digestAlgorithm.digestLength else {
            throw SigningMetadataError.digestFailure
        }
        return digest
    }
}
