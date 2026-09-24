import Foundation

/// Explicit opt-in to a cryptographic single-image experiment, not application
/// authorization. No bundle/profile intake is hidden behind this policy.
enum MachOSigningPolicy: Equatable {
    case singleImageCryptographicExperiment
}

struct MachOSigningRequest {
    let artifact: Data
    let identityID: SigningIdentityIdentifier?
    let codeDirectory: CodeDirectoryConstructionRequest
    let algorithm: SigningAlgorithm
    let existingSignaturePolicy: MachOExistingCodeSignaturePolicy
    let policy: MachOSigningPolicy

    /// The signing metadata for this one target: entitlements, requirements,
    /// and the sealed CodeResources bytes. `nil` signs exactly as ZS-026 did,
    /// with no special slots and a two-blob SuperBlob.
    ///
    /// Metadata is per target and never inherited: the caller states what
    /// this binary carries, and the pipeline derives every special-slot
    /// digest from it. Hand-crafted special slots in `codeDirectory` remain
    /// rejected, so there is exactly one path from metadata bytes to slot
    /// digests.
    let metadata: MachOSigningMetadata?

    init(
        artifact: Data,
        identityID: SigningIdentityIdentifier?,
        codeDirectory: CodeDirectoryConstructionRequest,
        algorithm: SigningAlgorithm,
        existingSignaturePolicy: MachOExistingCodeSignaturePolicy,
        policy: MachOSigningPolicy,
        metadata: MachOSigningMetadata? = nil
    ) {
        self.artifact = artifact
        self.identityID = identityID
        self.codeDirectory = codeDirectory
        self.algorithm = algorithm
        self.existingSignaturePolicy = existingSignaturePolicy
        self.policy = policy
        self.metadata = metadata
    }

    func validate() throws {
        guard identityID != nil else { throw MachOSigningError.identityUnavailable }
        // Existing binary offsets are zero-based. Refuse sliced Data values
        // whose indices would not address the parser's relative ranges.
        guard artifact.startIndex == 0 else { throw MachOSigningError.unsupportedConfiguration }
        guard artifact.count <= 256 * 1024 * 1024 else {
            throw MachOSigningError.resourceLimitExceeded
        }
        guard algorithm == .rsaPKCS1SHA256Digest else {
            throw MachOSigningError.unsupportedSigningAlgorithm
        }
        guard codeDirectory.hashConfiguration.hashType == .sha256 else {
            throw MachOSigningError.unsupportedHashType
        }
        guard codeDirectory.version == .v20200,
              codeDirectory.flags.rawValue == 0, codeDirectory.platform == 0,
              codeDirectory.pageSize == .exponent(12),
              codeDirectory.specialSlots.isEmpty else {
            throw MachOSigningError.unsupportedConfiguration
        }
        // Metadata components must be embeddable before anything else runs.
        // A requirements value whose framing was recorded malformed is
        // refused here; a parsed set is embeddable with its expressions
        // preserved and uninterpreted.
        if let metadata {
            do { try metadata.validateForEmbedding() }
            catch let error as RequirementsError { throw MachOSigningError.requirements(error) }
            catch let error as EntitlementsError { throw MachOSigningError.entitlements(error) }
            catch let error as ResourceSealError { throw MachOSigningError.resourceSeal(error) }
            catch { throw MachOSigningError.unsupportedConfiguration }
        }
        do { try codeDirectory.validate() }
        catch let error as CodeDirectoryError { throw MachOSigningError.codeDirectoryConstruction(error) }
        if existingSignaturePolicy == .replaceExistingSignature {
            throw MachOSigningError.layout(.replacementUnsupported)
        }
    }
}

/// Stage-specific, payload-free failures. No platform errors or certificate/key
/// material are retained in diagnostics.
enum MachOSigningError: Error, Equatable {
    case invalidMachO(MachOParsingError)
    case unsupportedMachOForm
    case unsupportedConfiguration
    case invalidCodeLimit
    case unsupportedHashType
    case unsupportedSigningAlgorithm
    case identityUnavailable
    case certificateUnavailable
    case signingCapabilityFailure
    case codeDirectoryConstruction(CodeDirectoryError)
    case codeDirectorySerialization
    case entitlements(EntitlementsError)
    case requirements(RequirementsError)
    case resourceSeal(ResourceSealError)
    case digestFailure
    case signatureBlobConstruction
    case superBlobConstruction
    case layout(MachOCodeSignatureRegionError)
    case mutation(MachOCodeSignatureRegionError)
    case postSignVerification
    case resourceLimitExceeded
}

/// Only returned after structural, page-hash, detached-content, and public-key
/// verification. Certificate/provisioning/platform policy is NOT evaluated.
struct MachOSigningResult {
    let artifact: Data
    let codeDirectory: Data
    let codeDirectoryDigest: Digest
    let layout: MachOCodeSignatureRegionLayout
    let cryptographicSignature: Data

    /// The exact entitlements blob bytes embedded in the SuperBlob, when this
    /// target carried entitlements. These bytes are what special slot 5
    /// digests; their presence says nothing about provisioning compatibility
    /// or platform authorization.
    let entitlementsBlob: Data?

    /// The exact requirements set bytes embedded in the SuperBlob, when this
    /// target carried requirements. Expressions inside are preserved, not
    /// interpreted.
    let requirementsBlob: Data?

    /// The metadata-derived special-slot digests, when metadata was present.
    /// A nil value means no metadata was supplied.
    let metadataSlotDigests: SigningMetadataSlotDigests?

    init(
        artifact: Data,
        codeDirectory: Data,
        codeDirectoryDigest: Digest,
        layout: MachOCodeSignatureRegionLayout,
        cryptographicSignature: Data,
        entitlementsBlob: Data? = nil,
        requirementsBlob: Data? = nil,
        metadataSlotDigests: SigningMetadataSlotDigests? = nil
    ) {
        self.artifact = artifact
        self.codeDirectory = codeDirectory
        self.codeDirectoryDigest = codeDirectoryDigest
        self.layout = layout
        self.cryptographicSignature = cryptographicSignature
        self.entitlementsBlob = entitlementsBlob
        self.requirementsBlob = requirementsBlob
        self.metadataSlotDigests = metadataSlotDigests
    }

    enum PolicyEvaluation { case notPerformed }
    var certificateValidation: PolicyEvaluation { .notPerformed }
    var provisioningValidation: PolicyEvaluation { .notPerformed }
    var platformAuthorization: PolicyEvaluation { .notPerformed }
}
