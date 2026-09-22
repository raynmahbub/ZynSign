/// Stable reasons for failures at the provisioning-profile input and parsing
/// boundary.
///
/// The reason is safe to expose to application code. Diagnostic details passed
/// to the factories below must remain redacted: field names, indexes, type
/// names, bounded counts, and platform error codes are acceptable; raw profile
/// bytes, device identifiers, certificate data, and complete entitlement
/// values are not.
enum ProvisioningProfileFailure: String, CaseIterable, Hashable {

    case emptyInput
    case inputTooLarge
    case malformedContainer
    case truncatedContainer
    case unsupportedContainer
    case containerUnavailable
    case emptyPayload
    case payloadTooLarge
    case malformedPayload
    case unsupportedPayloadFormat
    case missingRequiredMetadata
    case invalidFieldType
    case invalidFieldValue
    case invalidDate
    case invalidIdentifier
    case unsupportedValue
    case malformedCertificate
    case resourceLimitExceeded
    case metadataUnavailable
    case platformParsingFailure

    var category: DiagnosticCategory {
        switch self {
        case .unsupportedContainer, .unsupportedPayloadFormat:
            return .unsupportedInput
        case .containerUnavailable:
            return .capabilityUnavailable
        case .metadataUnavailable, .platformParsingFailure:
            return .internalFailure
        default:
            return .invalidInput
        }
    }

    var userMessage: String {
        switch self {
        case .emptyInput: return "The provisioning profile is empty."
        case .inputTooLarge, .payloadTooLarge, .resourceLimitExceeded:
            return "The provisioning profile is too large or complex to inspect."
        case .malformedContainer, .truncatedContainer:
            return "The provisioning profile container is malformed or incomplete."
        case .unsupportedContainer, .unsupportedPayloadFormat:
            return "The provisioning profile uses a format ZynSign does not support."
        case .containerUnavailable:
            return "Provisioning-profile container handling is not available in this build."
        case .emptyPayload, .malformedPayload:
            return "The provisioning profile payload could not be read."
        case .missingRequiredMetadata:
            return "Required provisioning-profile information is missing."
        case .invalidFieldType, .invalidFieldValue:
            return "The provisioning profile contains invalid metadata."
        case .invalidDate:
            return "The provisioning profile contains an invalid date."
        case .invalidIdentifier:
            return "The provisioning profile contains an invalid identifier."
        case .unsupportedValue:
            return "The provisioning profile contains a value ZynSign cannot represent."
        case .malformedCertificate:
            return "The provisioning profile contains invalid certificate information."
        case .metadataUnavailable:
            return "Provisioning-profile metadata could not be read."
        case .platformParsingFailure:
            return "The platform could not parse the provisioning profile."
        }
    }
}

extension ZynSignError {

    /// Constructs a controlled profile failure. The caller supplies only
    /// redacted diagnostic context; this factory never includes profile
    /// contents in the user message.
    static func provisioningProfile(
        _ reason: ProvisioningProfileFailure,
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        ZynSignError(
            category: reason.category,
            userMessage: reason.userMessage,
            diagnosticDetail: diagnosticDetail,
            underlyingError: underlyingError,
            provisioningProfileFailure: reason
        )
    }

    static func emptyProvisioningProfile(
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        provisioningProfile(.emptyInput, diagnosticDetail: diagnosticDetail)
    }

    static func provisioningProfileInputTooLarge(
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        provisioningProfile(.inputTooLarge, diagnosticDetail: diagnosticDetail)
    }

    static func malformedProvisioningProfileContainer(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        provisioningProfile(.malformedContainer, diagnosticDetail: diagnosticDetail, underlyingError: underlyingError)
    }

    static func truncatedProvisioningProfileContainer(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        provisioningProfile(.truncatedContainer, diagnosticDetail: diagnosticDetail, underlyingError: underlyingError)
    }

    static func unsupportedProvisioningProfileContainer(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        provisioningProfile(.unsupportedContainer, diagnosticDetail: diagnosticDetail, underlyingError: underlyingError)
    }

    static func provisioningProfileContainerUnavailable(
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        provisioningProfile(.containerUnavailable, diagnosticDetail: diagnosticDetail)
    }

    static func emptyProvisioningProfilePayload(
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        provisioningProfile(.emptyPayload, diagnosticDetail: diagnosticDetail)
    }

    static func malformedProvisioningProfilePayload(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        provisioningProfile(.malformedPayload, diagnosticDetail: diagnosticDetail, underlyingError: underlyingError)
    }

    static func unsupportedProvisioningProfilePayloadFormat(
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        provisioningProfile(.unsupportedPayloadFormat, diagnosticDetail: diagnosticDetail)
    }

    static func provisioningProfilePayloadTooLarge(
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        provisioningProfile(.payloadTooLarge, diagnosticDetail: diagnosticDetail)
    }

    static func missingProvisioningProfileMetadata(
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        provisioningProfile(.missingRequiredMetadata, diagnosticDetail: diagnosticDetail)
    }

    static func invalidProvisioningProfileFieldType(
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        provisioningProfile(.invalidFieldType, diagnosticDetail: diagnosticDetail)
    }

    static func invalidProvisioningProfileField(
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        provisioningProfile(.invalidFieldValue, diagnosticDetail: diagnosticDetail)
    }

    static func invalidProvisioningProfileDate(
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        provisioningProfile(.invalidDate, diagnosticDetail: diagnosticDetail)
    }

    static func invalidProvisioningProfileIdentifier(
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        provisioningProfile(.invalidIdentifier, diagnosticDetail: diagnosticDetail)
    }

    static func unsupportedProvisioningProfileValue(
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        provisioningProfile(.unsupportedValue, diagnosticDetail: diagnosticDetail)
    }

    static func malformedProvisioningProfileCertificate(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        provisioningProfile(.malformedCertificate, diagnosticDetail: diagnosticDetail, underlyingError: underlyingError)
    }

    static func provisioningProfileResourceLimitExceeded(
        diagnosticDetail: String? = nil
    ) -> ZynSignError {
        provisioningProfile(.resourceLimitExceeded, diagnosticDetail: diagnosticDetail)
    }

    static func provisioningProfileMetadataUnavailable(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        provisioningProfile(.metadataUnavailable, diagnosticDetail: diagnosticDetail, underlyingError: underlyingError)
    }

    static func provisioningProfilePlatformParsingFailure(
        diagnosticDetail: String? = nil,
        underlyingError: (any Error)? = nil
    ) -> ZynSignError {
        provisioningProfile(.platformParsingFailure, diagnosticDetail: diagnosticDetail, underlyingError: underlyingError)
    }
}
