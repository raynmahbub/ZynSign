import Foundation

/// Authorization status reserved for the later profile-policy pipeline.
///
/// ZS-017 does not compare a profile with an application, identity, device, or
/// platform policy. A structurally valid result therefore remains
/// `.notEvaluated` here.
enum ProvisioningProfileAuthorizationStatus: String, CaseIterable, Equatable, Hashable {
    case notEvaluated
}

/// The application-layer result of parsing and structurally validating one
/// decoded provisioning profile.
///
/// `profile` means the payload was parsed into typed data. `validation` is the
/// separate structural result. `authenticity` and `authorization` are carried
/// explicitly so later CMS and policy stages can attach evidence without
/// making parsing imply trust.
struct ProvisioningProfileInspection: Equatable, Hashable {

    let profile: ProvisioningProfile
    let validation: ProvisioningProfileValidation
    let authenticity: ProvisioningProfileAuthenticityStatus
    let authorization: ProvisioningProfileAuthorizationStatus

    var isParsed: Bool { true }
    var isStructurallyValid: Bool { validation.isStructurallyValid }
    var isCurrentlyValid: Bool { validation.isCurrentlyValid }
}

/// Coordinates container decoding, payload parsing, and structural
/// validation for the application layer.
///
/// The caller supplies the container decoder because CMS unwrapping and
/// signature handling are a separate feasibility boundary. This use case does
/// not read files, persist profile data, or expose raw dictionaries to the UI.
struct ProvisioningProfileInspectionUseCase {

    private let payloadDecoder: any ProvisioningProfilePayloadDecoder
    private let parser: any ProvisioningProfileParser
    private let validator: ProvisioningProfileValidator

    init(
        payloadDecoder: any ProvisioningProfilePayloadDecoder,
        parser: any ProvisioningProfileParser = PropertyListProvisioningProfileParser(),
        clock: any EvaluationClock
    ) {
        self.payloadDecoder = payloadDecoder
        self.parser = parser
        self.validator = ProvisioningProfileValidator(clock: clock)
    }

    /// Decodes and inspects raw profile input.
    ///
    /// Empty and oversized input is rejected before the decoder is invoked.
    /// Foreign decoder/parser errors are normalized to a safe typed error so
    /// provider internals and profile contents cannot reach UI messages.
    func inspect(_ input: ProvisioningProfileInput) throws -> ProvisioningProfileInspection {
        guard !input.bytes.isEmpty else {
            throw ZynSignError.emptyProvisioningProfile()
        }
        guard input.bytes.count <= ProvisioningProfileInput.maximumByteCount else {
            throw ZynSignError.provisioningProfileInputTooLarge(
                diagnosticDetail: "The raw profile input exceeded the configured byte bound."
            )
        }

        let payload: ProvisioningProfilePayload
        do {
            payload = try payloadDecoder.decodePayload(from: input)
        } catch let error as ZynSignError where error.provisioningProfileFailure != nil {
            throw error
        } catch {
            throw ZynSignError.provisioningProfilePlatformParsingFailure(
                diagnosticDetail: "The profile container decoder failed (cause: \(Self.safeCauseSummary(error)))."
            )
        }
        return try inspect(payload: payload)
    }

    /// Parses and validates an already decoded payload. This overload keeps
    /// deterministic tests independent of CMS and is the boundary the future
    /// CMS verifier will feed.
    func inspect(payload: ProvisioningProfilePayload) throws -> ProvisioningProfileInspection {
        guard !payload.plistData.isEmpty else {
            throw ZynSignError.emptyProvisioningProfilePayload()
        }
        guard payload.plistData.count <= ProvisioningProfilePayload.maximumByteCount else {
            throw ZynSignError.provisioningProfilePayloadTooLarge(
                diagnosticDetail: "The decoded profile payload exceeded the configured byte bound."
            )
        }

        let profile: ProvisioningProfile
        do {
            profile = try parser.parse(payload)
        } catch let error as ZynSignError where error.provisioningProfileFailure != nil {
            throw error
        } catch {
            throw ZynSignError.provisioningProfileMetadataUnavailable(
                diagnosticDetail: "The profile payload parser failed (cause: \(Self.safeCauseSummary(error)))."
            )
        }

        return ProvisioningProfileInspection(
            profile: profile,
            validation: validator.validate(profile),
            authenticity: payload.authenticity,
            authorization: .notEvaluated
        )
    }

    private static func safeCauseSummary(_ error: any Error) -> String {
        if let cocoaError = error as? NSError {
            return "platform error code \(cocoaError.code)"
        }
        return String(describing: type(of: error))
    }
}
