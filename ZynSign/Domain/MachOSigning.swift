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

    enum PolicyEvaluation { case notPerformed }
    var certificateValidation: PolicyEvaluation { .notPerformed }
    var provisioningValidation: PolicyEvaluation { .notPerformed }
    var platformAuthorization: PolicyEvaluation { .notPerformed }
}
