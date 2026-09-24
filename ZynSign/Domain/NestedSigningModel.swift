import Foundation

/// The domain model for ZynSign's nested code signing layer.
///
/// Nested code signing takes the dependency-aware signing plan produced by
/// nested-code discovery and signs each nested code target in deterministic
/// dependency order (deepest nested code -> its dependents -> higher-level
/// nested code) while strictly deferring the parent application bundle to the
/// later complete application pipeline.
///
/// Every value in this model is descriptive and typed. No private-key bytes,
/// passwords, keychain tokens, or unredacted raw credentials appear anywhere
/// in these structures.
///
/// ## Architectural Boundaries
///
/// This layer maintains strict boundaries:
/// - Structural validity: Mach-O headers, load commands, SuperBlob, and
///   CodeDirectory bounds are correctly formed.
/// - Cryptographic validity: the CodeDirectory digest matches CMS signed attributes
///   and the cryptographic signature verifies against the certificate's public key.
/// - Certificate validity: independent certificate trust evaluation (separate boundary).
/// - Provisioning validity: profile/entitlement validation (ZS-020 boundary).
/// - Platform authorization: whether iOS/iPadOS platform policy accepts the artifact.
/// - Installation: device deployment (completely out of scope).
///
/// These distinct facts are never collapsed into a single `isValid` boolean.

// MARK: - Extension Points

/// Code-directory construction parameters for nested code signing, plus the
/// per-target signing metadata established by ZS-029.
///
/// Metadata is keyed by target and never inherited: the entitlements,
/// requirements, and resource seal that apply to the root application do not
/// silently apply to a framework, a dynamic library, or an extension, because
/// each nested target may require different claims. A target with no entry
/// signs with no metadata, exactly as ZS-026/028 established.
///
/// `specialSlots` remains the direct-construction hook it was; the signing
/// pipeline still rejects non-empty slots, and metadata is the only supported
/// way to derive special slots through signing.
struct NestedCodeSigningConfiguration: Equatable {
    let flags: CodeDirectoryFlags
    let specialSlots: [CodeDirectorySpecialSlot]

    /// Explicit per-target signing metadata. No entry means no metadata for
    /// that target.
    let targetMetadata: [NestedCodeItemID: MachOSigningMetadata]

    init(
        flags: CodeDirectoryFlags = [],
        specialSlots: [CodeDirectorySpecialSlot] = [],
        targetMetadata: [NestedCodeItemID: MachOSigningMetadata] = [:]
    ) {
        self.flags = flags
        self.specialSlots = specialSlots
        self.targetMetadata = targetMetadata
    }
}

// MARK: - Nested Signing Item

/// One nested code target to be signed.
///
/// The item identifies a single Mach-O binary within the managed application
/// bundle. The root application itself is never a `NestedSigningItem`; only
/// nested components (frameworks, dylibs, application extensions) are represented.
struct NestedSigningItem: Equatable {

    /// The item's stable identity.
    let id: NestedCodeItemID

    /// The kind of nested code (framework, dynamic library, application extension).
    let kind: NestedCodeKind

    /// The container bundle directory, relative to the managed application bundle.
    let bundlePath: BundlePath

    /// The established executable location, relative to the managed application bundle.
    let executablePath: BundlePath

    /// The parent container identity, or `nil` if directly enclosed by the root application.
    let parentID: NestedCodeItemID?

    /// The declared bundle identifier, if one was read and accepted.
    let bundleIdentifier: BundleIdentifier?

    /// What was observed about an existing signature before signing.
    let initialSignatureState: NestedCodeExistingSignature

    /// One-based sequential order in the validated signing execution order.
    let order: Int
}

// MARK: - Nested Signing Plan

/// A validated execution plan for signing nested code targets.
///
/// Produced only after comprehensive plan validation. The plan specifies the
/// exact sequential order in which nested targets must be signed so that every
/// child is finalized before its container. The parent application executable
/// is recorded as the root context but is strictly excluded from `items`.
struct NestedSigningPlan: Equatable {

    /// The managed root application bundle's identity.
    let rootItemID: NestedCodeItemID

    /// The root application executable location, deferred for later application signing.
    let rootExecutablePath: BundlePath?

    /// The validated nested targets to sign, in deterministic dependency order.
    let items: [NestedSigningItem]

    /// The dependency edges the plan satisfies.
    let dependencies: [NestedCodeDependency]

    /// Total number of nested targets to sign.
    var stepCount: Int { items.count }

    /// Item IDs in signing order.
    var orderedItemIDs: [NestedCodeItemID] { items.map(\.id) }

    /// Looks up a nested signing item by its ID.
    func item(withID id: NestedCodeItemID) -> NestedSigningItem? {
        items.first { $0.id == id }
    }

    /// Looks up a nested signing item by its executable location.
    func item(at executablePath: BundlePath) -> NestedSigningItem? {
        items.first { $0.executablePath == executablePath }
    }
}

// MARK: - Mutation Strategy & State

/// Controls how mutations are staged and applied to the bundle artifact.
enum NestedSigningMutationStrategy: Equatable {

    /// Staging strategy: changes are staged in working memory/copies and only
    /// committed to the underlying artifact store after all targets are successfully
    /// signed and verified. If any target fails, no targets are modified.
    case stagedWorkingCopy

    /// Direct mutation strategy: targets are written to the artifact store
    /// sequentially in dependency order. If a failure occurs mid-way, previously
    /// signed targets remain modified, reporting partial completion.
    case directMutation
}

/// The mutation state of the overall artifact after a nested signing attempt.
enum NestedSigningMutationState: Equatable {

    /// No artifact targets or bytes were modified.
    case noTargetsModified

    /// Some targets were modified before a failure interrupted execution.
    case someTargetsModified(modifiedCount: Int, totalTargetCount: Int)

    /// All intended nested targets were successfully modified and signed.
    case allTargetsModified(count: Int)

    /// A binary was modified on disk or in the store, but post-sign verification failed.
    case verificationFailedAfterMutation(path: BundlePath)

    /// Whether any mutation occurred to the underlying artifact.
    var mutationOccurred: Bool {
        switch self {
        case .noTargetsModified:
            return false
        case .someTargetsModified, .allTargetsModified, .verificationFailedAfterMutation:
            return true
        }
    }
}

// MARK: - Request

/// A request to sign the nested code of an application bundle.
struct NestedSigningRequest {

    /// The validated execution plan specifying targets and deterministic order.
    let plan: NestedSigningPlan

    /// The signing identity identifier to use for signing.
    let identityID: SigningIdentityIdentifier?

    /// The cryptographic algorithm to use (default: RSA PKCS#1 v1.5 with SHA-256).
    let signingAlgorithm: SigningAlgorithm

    /// Policy for existing signatures (default: reject existing signature).
    let existingSignaturePolicy: MachOExistingCodeSignaturePolicy

    /// Optional explicit team identifier for CodeDirectory construction.
    let teamIdentifier: CodeDirectoryTeamIdentifier?

    /// Configuration parameters (flags, special slots) for CodeDirectory construction.
    let configuration: NestedCodeSigningConfiguration

    /// Strategy for applying mutations and preserving failure atomicity.
    let mutationStrategy: NestedSigningMutationStrategy

    init(
        plan: NestedSigningPlan,
        identityID: SigningIdentityIdentifier?,
        signingAlgorithm: SigningAlgorithm = .rsaPKCS1SHA256Digest,
        existingSignaturePolicy: MachOExistingCodeSignaturePolicy = .rejectExistingSignature,
        teamIdentifier: CodeDirectoryTeamIdentifier? = nil,
        configuration: NestedCodeSigningConfiguration = NestedCodeSigningConfiguration(),
        mutationStrategy: NestedSigningMutationStrategy = .stagedWorkingCopy
    ) {
        self.plan = plan
        self.identityID = identityID
        self.signingAlgorithm = signingAlgorithm
        self.existingSignaturePolicy = existingSignaturePolicy
        self.teamIdentifier = teamIdentifier
        self.configuration = configuration
        self.mutationStrategy = mutationStrategy
    }
}

// MARK: - Failure Vocabulary

/// The stable reasons for nested code signing failures.
enum NestedSigningFailureReason: String, CaseIterable, Hashable {

    /// The signing plan is invalid (cycles, missing dependencies, invalid paths, or ordering).
    case invalidSigningPlan

    /// The requested signing identity is unavailable or could not be resolved.
    case invalidSigningIdentity

    /// The signing configuration is invalid or unsupported.
    case invalidConfiguration

    /// A nested target uses an unsupported code kind or structure.
    case unsupportedCodeType

    /// A target binary uses an unsupported Mach-O format (e.g. fat binary, wrong CPU).
    case unsupportedFormat

    /// Replacing an existing code signature is unsupported.
    case unsupportedExistingSignature

    /// An existing signature was present on a target and was rejected by policy.
    case existingSignatureRejected

    /// An existing signature is malformed or damaged.
    case malformedExistingSignature

    /// A nested binary could not be read from the artifact store.
    case artifactReadFailure

    /// A signed binary could not be written to the artifact store.
    case artifactWriteFailure

    /// A signed binary failed structural Mach-O or signature-region verification.
    case structuralFailure

    /// A signed binary failed cryptographic signature or digest verification.
    case cryptographicFailure

    /// The signing capability failed to sign the prepared digest.
    case signingCapabilityFailure

    /// Signing metadata (entitlements, requirements, or a resource seal) for a
    /// target failed its own boundary: an entitlement payload that does not
    /// decode, a requirements value that cannot be embedded, or resource-seal
    /// bytes that do not hold. The failure belongs to the metadata stage, not
    /// to the Mach-O layout or the cryptographic operation.
    case signingMetadataFailure

    /// Verification of the signed binary failed after signing.
    case postSignVerificationFailure

    /// The signing process stopped before all targets could be finalized.
    case partialCompletion

    /// Resource bounds were exceeded during nested signing.
    case resourceLimitExceeded

    /// The diagnostic category for this failure.
    var category: DiagnosticCategory {
        switch self {
        case .invalidSigningPlan, .invalidConfiguration:
            return .invalidInput
        case .unsupportedCodeType, .unsupportedFormat, .unsupportedExistingSignature,
             .existingSignatureRejected, .malformedExistingSignature:
            return .unsupportedInput
        case .invalidSigningIdentity, .signingCapabilityFailure:
            return .capabilityUnavailable
        case .artifactReadFailure, .artifactWriteFailure:
            return .storageFailure
        case .structuralFailure, .cryptographicFailure, .postSignVerificationFailure,
             .partialCompletion, .resourceLimitExceeded, .signingMetadataFailure:
            return .internalFailure
        }
    }

    /// User-presentable message, free of technical and sensitive details.
    var userMessage: String {
        switch self {
        case .invalidSigningPlan:
            return "The signing plan for nested code is not valid."
        case .invalidSigningIdentity:
            return "The requested signing identity is not available."
        case .invalidConfiguration:
            return "The signing configuration is not valid."
        case .unsupportedCodeType:
            return "The application bundle contains nested code in an unsupported form."
        case .unsupportedFormat:
            return "An executable file uses a form that is not supported."
        case .unsupportedExistingSignature:
            return "Replacing an existing signature is not supported."
        case .existingSignatureRejected:
            return "An existing signature was found on a file that cannot be resigned."
        case .malformedExistingSignature:
            return "An executable file carries a damaged existing signature."
        case .artifactReadFailure:
            return "A file could not be read from the package."
        case .artifactWriteFailure:
            return "A signed file could not be written to the package."
        case .structuralFailure:
            return "A signed executable failed structural verification."
        case .cryptographicFailure:
            return "A signed executable failed cryptographic verification."
        case .signingCapabilityFailure:
            return "The signature could not be produced by the signing identity."
        case .signingMetadataFailure:
            return "The signing metadata for a target is not usable."
        case .postSignVerificationFailure:
            return "Verification of the signed executable failed."
        case .partialCompletion:
            return "The signing operation stopped before all components were signed."
        case .resourceLimitExceeded:
            return "A signing resource limit was exceeded."
        }
    }

    var displayName: String { rawValue }
}

/// One structured nested signing failure.
struct NestedSigningFailure: Error, Equatable {

    let reason: NestedSigningFailureReason
    let itemID: NestedCodeItemID?
    let path: BundlePath?
    let detail: String
    let category: DiagnosticCategory
    let mutationOccurred: Bool

    init(
        reason: NestedSigningFailureReason,
        itemID: NestedCodeItemID? = nil,
        path: BundlePath? = nil,
        detail: String,
        category: DiagnosticCategory? = nil,
        mutationOccurred: Bool = false
    ) {
        self.reason = reason
        self.itemID = itemID
        self.path = path
        self.detail = detail
        self.category = category ?? reason.category
        self.mutationOccurred = mutationOccurred
    }

    var description: String {
        if let path {
            return "zynsign.nestedSigning(\(reason.rawValue)): \(path.rawValue)"
        }
        return "zynsign.nestedSigning(\(reason.rawValue))"
    }
}

// MARK: - Verification Outcomes

/// Structural verification outcome for a signed binary.
enum NestedStructuralValidity: Equatable {
    case valid
    case invalid(String)

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
}

/// Cryptographic verification outcome for a signed binary.
enum NestedCryptographicValidity: Equatable {
    case valid(digest: Digest)
    case invalid(String)
    case unsupported(String)

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
}

/// Relationship verification between the signing identity, certificate, and signed binary.
enum NestedRelationshipValidity: Equatable {
    case matched(signerSummary: String)
    case mismatched(String)
    case notEvaluated
}

/// Complete verification record for one signed nested target.
struct NestedSigningItemVerification: Equatable {
    let structuralValidity: NestedStructuralValidity
    let cryptographicValidity: NestedCryptographicValidity
    let relationshipValidity: NestedRelationshipValidity

    enum PolicyEvaluation: Equatable {
        case notPerformed
    }

    /// Explicit boundaries not performed by this layer:
    var certificateValidation: PolicyEvaluation { .notPerformed }
    var provisioningValidation: PolicyEvaluation { .notPerformed }
    var platformAuthorization: PolicyEvaluation { .notPerformed }
    var installation: PolicyEvaluation { .notPerformed }

    var isVerified: Bool {
        structuralValidity.isValid && cryptographicValidity.isValid
    }
}

// MARK: - Item Result

/// Details of a successfully signed Mach-O binary.
struct NestedMachOSigningDetails: Equatable {
    let codeDirectoryDigest: Digest
    let signatureByteCount: Int
    let verification: NestedSigningItemVerification
}

/// Status of one nested item in the signing execution.
enum NestedSigningItemStatus: Equatable {
    case signed(NestedMachOSigningDetails)
    case skipped(reason: String)
    case failed(NestedSigningFailure)

    var isSigned: Bool {
        if case .signed = self { return true }
        return false
    }
}

/// Result for one nested signing item.
struct NestedSigningItemResult: Equatable {
    let itemID: NestedCodeItemID
    let executablePath: BundlePath
    let codeKind: NestedCodeKind
    let order: Int
    let initialSignatureState: NestedCodeExistingSignature
    let status: NestedSigningItemStatus
    let mutationOccurred: Bool

    var isSuccess: Bool {
        status.isSigned
    }
}

// MARK: - Summary & Overall Result

/// High-level summary of a nested signing operation.
struct NestedSigningSummary: Equatable {
    let totalTargets: Int
    let successfullySignedCount: Int
    let failedCount: Int
    let skippedCount: Int
    let mutationState: NestedSigningMutationState

    var isSuccess: Bool {
        failedCount == 0 && successfullySignedCount == totalTargets
    }
}

/// Overall status of a nested signing operation.
enum NestedSigningStatus: Equatable {
    case succeeded
    case failed(NestedSigningFailure)

    var isSuccess: Bool {
        if case .succeeded = self { return true }
        return false
    }
}

/// The final structured result of a nested code signing operation.
struct NestedSigningResult: Equatable {
    let status: NestedSigningStatus
    let summary: NestedSigningSummary
    let itemResults: [NestedSigningItemResult]

    enum PolicyEvaluation: Equatable {
        case notPerformed
    }

    /// Preserved architectural boundaries:
    var certificateValidation: PolicyEvaluation { .notPerformed }
    var provisioningValidation: PolicyEvaluation { .notPerformed }
    var platformAuthorization: PolicyEvaluation { .notPerformed }
    var installation: PolicyEvaluation { .notPerformed }

    var isSuccess: Bool {
        status.isSuccess && summary.isSuccess
    }

    /// Looks up the result for a specific nested item.
    func result(for itemID: NestedCodeItemID) -> NestedSigningItemResult? {
        itemResults.first { $0.itemID == itemID }
    }
}
