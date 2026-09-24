import Foundation

/// The signing area's application-layer facade.
///
/// This type is the single door the Signing tab walks through. It owns no
/// storage and implements no cryptography itself: it holds the identity
/// store, the profile-validation pipeline, and the nine-stage application
/// pipeline the composition root built, and it sequences them for one
/// signing run.
///
/// What it establishes, exactly:
///
/// - a provisioning profile can be validated standalone before anything is
///   signed, with the same staged pipeline the signing run uses;
/// - entitlements claimed in a signing run are the parsed profile's own
///   entitlements — never invented, never widened;
/// - a signing run produces the pipeline's typed result: either a
///   delivered container ZynSign's own verifier checked, or the refusing
///   stage with its reason and nothing delivered.
///
/// What it never claims: trust, Apple acceptance, or installability. The
/// output is verified by ZynSign's verifier alone, and no installation
/// mechanism exists anywhere in the product.
final class ApplicationSigning {

    /// The identity store the pipeline and the profile stages resolve
    /// identities from. `nil` on targets without the Keychain composition;
    /// the facade then reports no identities and refuses creation.
    private let identityStore: (any IdentityStore)?

    /// Creates a development identity on this device. Injected so key
    /// generation stays in the platform layer and out of this type.
    private let createIdentity: @Sendable () async throws -> SigningIdentityIdentifier

    /// Resolves a library entry to the source container's location, using
    /// the storage convention only the composition root knows.
    private let sourceURL: (LibraryEntry) throws -> URL

    /// Where delivered containers are written.
    private let outputDirectory: URL

    private let pipeline: SignApplicationPipeline
    private let profileValidation: ValidateProvisioningProfileUseCase

    init(
        identityStore: (any IdentityStore)?,
        createIdentity: @escaping @Sendable () async throws -> SigningIdentityIdentifier,
        sourceURL: @escaping (LibraryEntry) throws -> URL,
        outputDirectory: URL,
        pipeline: SignApplicationPipeline,
        profileValidation: ValidateProvisioningProfileUseCase
    ) {
        self.identityStore = identityStore
        self.createIdentity = createIdentity
        self.sourceURL = sourceURL
        self.outputDirectory = outputDirectory
        self.pipeline = pipeline
        self.profileValidation = profileValidation
    }

    // MARK: - Identities

    /// The identities registered in the store, or none when the store is
    /// absent. Listing never requests a signing capability.
    func identities() throws -> [SigningIdentity] {
        try identityStore?.listIdentities() ?? []
    }

    /// Generates and registers a development identity on this device.
    func createDevelopmentIdentity() async throws -> SigningIdentityIdentifier {
        try await createIdentity()
    }

    // MARK: - Profiles

    /// Validates one provisioning profile standalone: container, payload,
    /// structure, and policy — the same staged evaluation the signing run's
    /// profile stage performs — without signing anything.
    func validate(profile data: Data, identityID: SigningIdentityIdentifier? = nil) throws
        -> ProvisioningProfilePipelineResult
    {
        try profileValidation.validate(
            ValidateProvisioningProfileRequest(
                profile: .bytes(data),
                profileOrigin: .supplied,
                signingIdentityID: identityID
            )
        )
    }

    // MARK: - Signing

    /// Runs the nine-stage pipeline over one library package.
    ///
    /// The claimed entitlements are the parsed profile's own; a profile
    /// whose entitlements cannot be represented in the signing form fails
    /// here rather than being coerced. Every other refusal comes back from
    /// the pipeline as a typed stage failure with nothing delivered.
    func sign(
        entry: LibraryEntry,
        profile: Data,
        identityID: SigningIdentityIdentifier
    ) async throws -> SignApplicationResult {
        let entitlements = try claimedEntitlements(from: profile, identityID: identityID)
        // The output directory is created here rather than at composition
        // time; nothing exists until a run actually delivers.
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)
        let request = SignApplicationRequest(
            sourceURL: try sourceURL(entry),
            profile: profile,
            identityID: identityID,
            entitlements: entitlements,
            outputURL: outputDirectory.appendingPathComponent(
                "ZynSign-signed-\(UUID().uuidString).ipa", isDirectory: false),
            options: SignApplicationOptions()
        )
        return try await pipeline.sign(request)
    }

    /// Reads the profile's parsed entitlements through the validation
    /// pipeline. A profile whose payload cannot be parsed yields an empty
    /// claim set: the signing run's profile stage then refuses with its own
    /// typed reason, before anything is signed.
    private func claimedEntitlements(
        from profile: Data,
        identityID: SigningIdentityIdentifier
    ) throws -> CodeSigningEntitlements {
        guard let parsed = try? validate(profile: profile, identityID: identityID),
              let profileEntitlements = parsed.profile?.entitlements else {
            return try CodeSigningEntitlements(values: [:])
        }
        return try CodeSigningEntitlements(profileEntitlements: profileEntitlements)
    }
}
