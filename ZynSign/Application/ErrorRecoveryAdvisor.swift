import Foundation

/// What one failure means, answered in the three parts a user needs.
///
/// Every failure in ZynSign already carries a category and a message written
/// for a person. What a message cannot carry is the shape of an answer: what
/// actually happened, what ZynSign did and did not establish, and what the
/// user can do next. This type supplies that, from the failure's own typed
/// vocabulary, so every screen that shows an error shows the same three
/// answers rather than inventing its own.
///
/// The advisor never adds facts a failure did not carry. It reads the typed
/// reason, the category, and nothing else: no path, no identifier, no
/// diagnostic detail the caller chose not to show.
struct ErrorRecoveryAdvice: Equatable, Sendable {

    /// What happened, in one sentence.
    let whatHappened: String

    /// What ZynSign checked, and the limit of what it established.
    let whatWasVerified: String

    /// What the user can do next, most likely to help first.
    let nextSteps: [String]

    /// Whether trying the same thing again can plausibly end differently.
    let canRetry: Bool

    /// An advice with no steps: nothing the user can do changes the outcome.
    static func settled(
        whatHappened: String,
        whatWasVerified: String
    ) -> ErrorRecoveryAdvice {
        ErrorRecoveryAdvice(
            whatHappened: whatHappened,
            whatWasVerified: whatWasVerified,
            nextSteps: [],
            canRetry: false
        )
    }
}

/// Turns a failure into the three answers.
///
/// The mapping is a switch over ZynSign's own typed reasons, with the
/// category as the fallback. A reason nobody has written advice for still
/// receives an answer — the category's — rather than silence, so a new
/// failure mode degrades into something useful instead of a blank panel.
enum ErrorRecoveryAdvisor {

    /// Advice for any failure, including ones ZynSign did not type.
    static func advice(for error: Error) -> ErrorRecoveryAdvice {
        if let zynSign = error as? ZynSignError { return advice(for: zynSign) }
        if let importFailure = error as? ImportFailure { return advice(for: importFailure) }
        if error is CancellationError {
            return ErrorRecoveryAdvice(
                whatHappened: "The operation was cancelled.",
                whatWasVerified: "Nothing was changed: a cancellation is a stop, not a failure of what was already done.",
                nextSteps: ["Start it again when you are ready — it will run from the beginning."],
                canRetry: true
            )
        }
        let network = error as NSError
        if network.domain == NSURLErrorDomain {
            return ErrorRecoveryAdvice(
                whatHappened: "The network could not complete the transfer (\(Self.networkWord(network.code))).",
                whatWasVerified: "The request was attempted and reported a transport failure; nothing was stored from it.",
                nextSteps: [
                    "Check the connection, then try again.",
                    "A source that keeps failing can be removed in App Store → Sources."
                ],
                canRetry: true
            )
        }
        return ErrorRecoveryAdvice(
            whatHappened: "ZynSign could not finish that.",
            whatWasVerified: "The failure was not one of ZynSign's typed errors, so only its shape is known.",
            nextSteps: [
                "Try again; if it repeats, the technical log (Settings → Diagnostics) records what happened.",
                "A failure that repeats on the same file is worth reporting with the report export."
            ],
            canRetry: true
        )
    }

    /// Advice for one of ZynSign's typed errors.
    static func advice(for failure: ZynSignError) -> ErrorRecoveryAdvice {
        if let reason = failure.identityFailure { return identityAdvice(reason) }
        if let reason = failure.provisioningProfileFailure { return profileAdvice(reason) }
        if let reason = failure.cmsFailure { return cmsAdvice(reason) }
        if let reason = failure.cryptoFailure { return cryptoAdvice(reason) }
        if let reason = failure.nestedCodeFailure { return nestedCodeAdvice(reason) }
        if let reason = failure.nestedSigningFailure { return nestedSigningAdvice(reason) }
        return categoryAdvice(failure.category, message: failure.userMessage)
    }

    /// Advice for an import refusal, which carries its own recovery kind.
    static func advice(for failure: ImportFailure) -> ErrorRecoveryAdvice {
        let steps: [String]
        switch failure.recovery {
        case .freeStorage:
            steps = [
                "Free about \(Self.spaceWord(failure)) of space, then try again.",
                "Remove old exports in Settings → Storage, or unneeded downloads in Files."
            ]
        case .chooseAnotherFile:
            steps = [
                "Choose a different package: this one will not import.",
                "If the package opens elsewhere, re-export it and try the new copy."
            ]
        case .retry:
            steps = ["Try the import again — the same file, unmodified."]
        case .checkAccess:
            steps = [
                "Choose the file again from Files so ZynSign is granted access to it.",
                "If the file lives in a cloud drive, let it finish downloading first."
            ]
        case .none:
            steps = []
        }
        return ErrorRecoveryAdvice(
            whatHappened: failure.message,
            whatWasVerified: Self.importVerifiedText(failure),
            nextSteps: steps,
            canRetry: failure.isRetryable
        )
    }

    // MARK: - Identity

    private static func identityAdvice(_ reason: SigningIdentityFailure) -> ErrorRecoveryAdvice {
        switch reason {
        case .identityNotFound:
            return ErrorRecoveryAdvice(
                whatHappened: "The signing identity is no longer registered on this device.",
                whatWasVerified: "ZynSign asked the Keychain for the identity it recorded; the Keychain reported nothing there.",
                nextSteps: [
                    "Re-import the certificate in Certificates.",
                    "If it keeps disappearing, check whether a profile or a device-management policy removes it."
                ],
                canRetry: false
            )
        case .privateKeyUnavailable:
            return ErrorRecoveryAdvice(
                whatHappened: "The identity's private key is not available for signing.",
                whatWasVerified: "The certificate was found; the key behind it could not be resolved. A certificate without its key cannot sign.",
                nextSteps: [
                    "Re-import the .p12 container that holds both the certificate and its key.",
                    "If the key lives in a hardware token, connect it and try again."
                ],
                canRetry: false
            )
        case .certificateKeyMismatch:
            return ErrorRecoveryAdvice(
                whatHappened: "The certificate and the signing key do not belong together.",
                whatWasVerified: "ZynSign compared the certificate's public key with the key it resolved; they are different keys.",
                nextSteps: ["Import the correct .p12 for this certificate."],
                canRetry: false
            )
        case .keychainAccessFailure:
            return ErrorRecoveryAdvice(
                whatHappened: "The Keychain could not be read.",
                whatWasVerified: "The storage boundary refused the request; ZynSign did not fall back to another location.",
                nextSteps: [
                    "Unlock the device and try again.",
                    "If it persists, Settings → Recovery → Reset Preferences restores ZynSign's own settings; it never touches the Keychain."
                ],
                canRetry: true
            )
        case .duplicateIdentity:
            return ErrorRecoveryAdvice(
                whatHappened: "This certificate is already imported.",
                whatWasVerified: "ZynSign compared certificate fingerprints; another registration carries the same one.",
                nextSteps: ["Use the existing identity, or remove the older registration first."],
                canRetry: false
            )
        case .unsupportedKeyType, .unsupportedSigningAlgorithm:
            return ErrorRecoveryAdvice(
                whatHappened: "This key or algorithm is not one ZynSign signs with.",
                whatWasVerified: "The key type was read and is outside what the signing engine supports.",
                nextSteps: ["Use an RSA or EC certificate from your Apple developer account."],
                canRetry: false
            )
        case .capabilityUnavailable, .platformRestriction:
            return ErrorRecoveryAdvice(
                whatHappened: "This device or build cannot provide the signing capability.",
                whatWasVerified: "The platform refused the capability itself; this is not a defect in the certificate.",
                nextSteps: ["Run ZynSign on a device with the key present and unlocked."],
                canRetry: false
            )
        case .authorizationFailure:
            return ErrorRecoveryAdvice(
                whatHappened: "Authorization for the key was not granted.",
                whatWasVerified: "ZynSign asked for the key and the request was refused.",
                nextSteps: ["Approve the authentication prompt, then try again."],
                canRetry: true
            )
        case .certificateUnavailable, .malformedStoredIdentity:
            return ErrorRecoveryAdvice(
                whatHappened: "The stored identity could not be read.",
                whatWasVerified: "The registration is present but its contents could not be interpreted.",
                nextSteps: ["Remove the identity in Certificates and import it again."],
                canRetry: false
            )
        case .signingFailure, .unexpectedSecurityFailure, .invalidSigningInput:
            return ErrorRecoveryAdvice(
                whatHappened: "The signing operation itself failed.",
                whatWasVerified: "The key was resolved and used; the operation reported a failure rather than a result.",
                nextSteps: [
                    "Try again; if it repeats, the signing history records the stage it reached.",
                    "Settings → Diagnostics can export a report with what was recorded."
                ],
                canRetry: true
            )
        }
    }

    // MARK: - Profiles

    private static func profileAdvice(_ reason: ProvisioningProfileFailure) -> ErrorRecoveryAdvice {
        switch reason {
        case .emptyInput, .truncatedContainer, .malformedContainer:
            return ErrorRecoveryAdvice(
                whatHappened: "The provisioning profile could not be read as a profile.",
                whatWasVerified: "ZynSign read the file's container and it is empty, cut short, or not the documented CMS structure.",
                nextSteps: [
                    "Download the profile again from your developer account.",
                    "A profile forwarded through a chat app is often altered in transit — re-download rather than re-share it."
                ],
                canRetry: false
            )
        case .unsupportedContainer, .unsupportedPayloadFormat:
            return ErrorRecoveryAdvice(
                whatHappened: "This profile uses a form ZynSign does not read.",
                whatWasVerified: "The container was recognized and the form inside it is outside what this build supports.",
                nextSteps: ["Use a standard .mobileprovision from your developer account."],
                canRetry: false
            )
        case .missingRequiredMetadata, .invalidFieldType, .invalidFieldValue, .invalidDate:
            return ErrorRecoveryAdvice(
                whatHappened: "The profile is missing information ZynSign needs, or declares it in an unusable form.",
                whatWasVerified: "The payload parsed, and the fields the policy requires are absent, wrongly typed, or inconsistent.",
                nextSteps: ["Re-download the profile; if it repeats, the profile itself may be damaged."],
                canRetry: false
            )
        case .invalidIdentifier:
            return ErrorRecoveryAdvice(
                whatHappened: "The profile's application identifier is not one ZynSign can match against an app.",
                whatWasVerified: "The identifier was read and does not satisfy the matching rules — a wildcard must sit at a component boundary.",
                nextSteps: [
                    "Check the App ID in your developer account.",
                    "Profiles → the profile → View Details shows the identifier ZynSign read."
                ],
                canRetry: false
            )
        case .malformedCertificate:
            return ErrorRecoveryAdvice(
                whatHappened: "A certificate inside the profile could not be read.",
                whatWasVerified: "ZynSign read the certificate entries and at least one is not a certificate it can parse.",
                nextSteps: ["Re-download the profile from your developer account."],
                canRetry: false
            )
        case .resourceLimitExceeded, .payloadTooLarge, .inputTooLarge:
            return ErrorRecoveryAdvice(
                whatHappened: "The profile is larger than ZynSign will read.",
                whatWasVerified: "The size was checked before the content was interpreted, so nothing partial was used.",
                nextSteps: ["Use a profile from your developer account; embedded profiles in ordinary apps are far below this bound."],
                canRetry: false
            )
        case .emptyPayload, .malformedPayload:
            return ErrorRecoveryAdvice(
                whatHappened: "The profile carries no payload.",
                whatWasVerified: "The container was read and the payload inside it is empty.",
                nextSteps: ["Re-download the profile."],
                canRetry: false
            )
        case .containerUnavailable, .metadataUnavailable:
            return ErrorRecoveryAdvice(
                whatHappened: "The profile's contents could not be reached.",
                whatWasVerified: "The storage or the platform's property-list reader could not supply what ZynSign asked for.",
                nextSteps: ["Import the profile again from Files."],
                canRetry: true
            )
        case .platformParsingFailure:
            return ErrorRecoveryAdvice(
                whatHappened: "The profile could not be parsed.",
                whatWasVerified: "The platform's property-list reader refused the payload; ZynSign reports the refusal rather than guessing at it.",
                nextSteps: ["Re-download the profile; a damaged download is the usual cause."],
                canRetry: false
            )
        case .unsupportedValue:
            return ErrorRecoveryAdvice(
                whatHappened: "The profile carries a value ZynSign cannot use.",
                whatWasVerified: "The field was read and its value falls outside what the profile format allows for it.",
                nextSteps: ["Re-download the profile; if it repeats, the profile itself may be damaged."],
                canRetry: false
            )
        }
    }

    // MARK: - CMS

    private static func cmsAdvice(_ reason: CMSFailure) -> ErrorRecoveryAdvice {
        switch reason {
        case .malformedCMS, .truncatedCMS, .unsupportedStructure, .decodeFailed:
            return ErrorRecoveryAdvice(
                whatHappened: "The profile's signature container could not be read.",
                whatWasVerified: "ZynSign read the CMS structure only far enough to establish that it is unusable. No trust decision was made, and none is implied by this message.",
                nextSteps: ["Re-download the profile from your developer account."],
                canRetry: false
            )
        case .unsupportedContentType:
            return ErrorRecoveryAdvice(
                whatHappened: "The signature container is not the kind of signed data ZynSign reads.",
                whatWasVerified: "The content type was read and is outside what this build supports.",
                nextSteps: ["Use a provisioning profile issued by Apple."],
                canRetry: false
            )
        case .emptyInput, .inputTooLarge, .resourceLimitExceeded, .payloadUnavailable:
            return ErrorRecoveryAdvice(
                whatHappened: "There was nothing readable to verify, or more of it than ZynSign will read.",
                whatWasVerified: "The bound was applied before any content was interpreted.",
                nextSteps: ["Re-download the profile and import the file itself, not an archive containing it."],
                canRetry: false
            )
        case .signerUnavailable:
            return ErrorRecoveryAdvice(
                whatHappened: "The container's signer could not be established.",
                whatWasVerified: "ZynSign read the signer information and it is absent or ambiguous, so no verification was performed.",
                nextSteps: ["Re-download the profile; if it repeats, the profile is not one ZynSign can verify."],
                canRetry: false
            )
        case .multipleSigners:
            return ErrorRecoveryAdvice(
                whatHappened: "The container is signed by more than one signer.",
                whatWasVerified: "ZynSign read the signer set and it holds several signers; the profile ZynSign expects carries exactly one.",
                nextSteps: ["Re-download the profile from your developer account."],
                canRetry: false
            )
        case .signatureInvalid, .certificateParseFailed, .certificateMismatch, .unsupportedAlgorithm:
            return ErrorRecoveryAdvice(
                whatHappened: "The container's signature did not verify.",
                whatWasVerified: "The signature and its certificate were checked against the container's own bytes and did not hold; no trust beyond that was established.",
                nextSteps: ["Re-download the profile; if it repeats, the profile is not one ZynSign can verify."],
                canRetry: false
            )
        case .signerCertificateUnavailable, .platformVerificationUnavailable, .unexpectedSecurityError:
            return ErrorRecoveryAdvice(
                whatHappened: "The platform could not complete the signature check.",
                whatWasVerified: "ZynSign asked the platform to verify and the certificate or the verification step itself was unavailable; nothing was assumed in its place.",
                nextSteps: ["Try again; if it repeats, re-import the profile from your developer account."],
                canRetry: true
            )
        }
    }

    // MARK: - Crypto

    private static func cryptoAdvice(_ reason: CryptoFailure) -> ErrorRecoveryAdvice {
        switch reason {
        case .unsupportedAlgorithm:
            return ErrorRecoveryAdvice(
                whatHappened: "The signature uses an algorithm ZynSign cannot evaluate with this key.",
                whatWasVerified: "The algorithm was read from the signature and is outside the supported set.",
                nextSteps: ["A signature made with an unsupported digest cannot be checked here; ZynSign reports that rather than skipping it."],
                canRetry: false
            )
        case .incompatibleKey:
            return ErrorRecoveryAdvice(
                whatHappened: "The key does not match the algorithm the signature asks for.",
                whatWasVerified: "The key type and the signature's algorithm were compared and do not fit.",
                nextSteps: ["Use the certificate the signature was made with."],
                canRetry: false
            )
        case .malformedSignature, .invalidInput:
            return ErrorRecoveryAdvice(
                whatHappened: "The signature data could not be evaluated.",
                whatWasVerified: "The bytes were read and are not a signature in a form that can be checked.",
                nextSteps: ["Re-run the verification; if it repeats, the artifact's signature region is damaged."],
                canRetry: true
            )
        case .certificateUnavailable:
            return ErrorRecoveryAdvice(
                whatHappened: "The certificate needed to check the signature is not available.",
                whatWasVerified: "ZynSign looked for the certificate the signature names and did not find it in the identity store.",
                nextSteps: ["Import the signing certificate in Certificates, then verify again."],
                canRetry: false
            )
        case .verificationFailure:
            return ErrorRecoveryAdvice(
                whatHappened: "The signature did not verify.",
                whatWasVerified: "The signature was checked against the artifact's own bytes and did not match. This is a statement about the bytes, not about Apple's acceptance of them.",
                nextSteps: [
                    "Re-sign the application; a signature made over different bytes will not verify.",
                    "Verification compares what ZynSign produced with what it recorded — a mismatch means the artifact changed."
                ],
                canRetry: true
            )
        case .signingFailure:
            return ErrorRecoveryAdvice(
                whatHappened: "The signature could not be produced.",
                whatWasVerified: "The signing operation was attempted with the resolved key and reported a failure.",
                nextSteps: ["Try again; if it repeats, check that the identity's key is available in Certificates."],
                canRetry: true
            )
        case .capabilityUnavailable, .platformLimitation:
            return ErrorRecoveryAdvice(
                whatHappened: "This environment cannot complete the cryptographic operation the artifact asks for.",
                whatWasVerified: "The operation ran and the platform reported the capability missing or a limit reached; nothing was substituted for it.",
                nextSteps: ["Try again; if it repeats, the operation exceeds what this build offers on this device."],
                canRetry: true
            )
        case .unexpectedFailure:
            return ErrorRecoveryAdvice(
                whatHappened: "The cryptographic operation failed for a reason ZynSign did not classify.",
                whatWasVerified: "The operation ran and reported a failure; no conclusion about the artifact's validity was drawn from it.",
                nextSteps: ["Try again; if it repeats, re-import the artifact."],
                canRetry: true
            )
        }
    }

    // MARK: - Nested code

    private static func nestedCodeAdvice(_ reason: NestedCodeFailure) -> ErrorRecoveryAdvice {
        ErrorRecoveryAdvice(
            whatHappened: "The code inside this package could not be established (\(reason.rawValue)).",
            whatWasVerified: "Discovery walked the bundle structure and refused rather than sign something it could not justify.",
            nextSteps: [
                "Open the app's details and read what the bundle contains.",
                "A package with conflicting or ambiguous nested code is refused on purpose: signing it would produce something ZynSign cannot explain."
            ],
            canRetry: false
        )
    }

    private static func nestedSigningAdvice(_ reason: NestedSigningFailureReason) -> ErrorRecoveryAdvice {
        ErrorRecoveryAdvice(
            whatHappened: "Signing the code inside this package was refused (\(reason.rawValue)).",
            whatWasVerified: "The plan was validated before anything was modified, so the package you imported is untouched.",
            nextSteps: [
                "Re-run the signing; a fresh attempt starts from a clean working copy.",
                "If it repeats, the package contains code ZynSign will not plan around."
            ],
            canRetry: true
        )
    }

    // MARK: - Categories

    /// The answer when only the category is known. Every category has one,
    /// so a failure never arrives with nothing to say.
    static func categoryAdvice(_ category: DiagnosticCategory, message: String) -> ErrorRecoveryAdvice {
        switch category {
        case .invalidInput:
            return ErrorRecoveryAdvice(
                whatHappened: message,
                whatWasVerified: "ZynSign checked the input and it did not satisfy the rule it was checked against. Nothing was written.",
                nextSteps: ["Use a package or file that satisfies the rule; the detail above names it."],
                canRetry: false
            )
        case .unsupportedInput:
            return ErrorRecoveryAdvice(
                whatHappened: message,
                whatWasVerified: "The input is coherent but falls outside what this build supports. That is a limit of ZynSign, not a defect in the file.",
                nextSteps: ["Nothing to fix in the file: this shape is not supported yet."],
                canRetry: false
            )
        case .ambiguousInput:
            return ErrorRecoveryAdvice(
                whatHappened: message,
                whatWasVerified: "More than one reading was possible, and ZynSign does not choose between them silently.",
                nextSteps: ["Pick one explicitly — a different package, or a different profile — and try again."],
                canRetry: false
            )
        case .capabilityUnavailable:
            return ErrorRecoveryAdvice(
                whatHappened: message,
                whatWasVerified: "A capability the platform does not provide to applications was asked for; ZynSign reports the absence rather than working around it.",
                nextSteps: ["This is a platform limit, not a setting: no preference turns it on."],
                canRetry: false
            )
        case .cancelled:
            return ErrorRecoveryAdvice(
                whatHappened: "The operation was cancelled.",
                whatWasVerified: "Nothing was changed beyond what had already completed.",
                nextSteps: ["Start it again when you are ready."],
                canRetry: true
            )
        case .storageFailure:
            return ErrorRecoveryAdvice(
                whatHappened: message,
                whatWasVerified: "Storage refused the operation before it could leave something half-written.",
                nextSteps: [
                    "Free space, then try again.",
                    "Settings → Storage shows what ZynSign holds and what can be reclaimed."
                ],
                canRetry: true
            )
        case .internalFailure:
            return ErrorRecoveryAdvice(
                whatHappened: message,
                whatWasVerified: "An internal condition ZynSign did not expect was reached; the operation stopped rather than continue on an assumption.",
                nextSteps: [
                    "Try again; if it repeats, the technical log records the entry that failed.",
                    "Settings → Diagnostics → Export Report produces a report you can attach to an issue."
                ],
                canRetry: true
            )
        }
    }

    // MARK: - Support

    private static func importVerifiedText(_ failure: ImportFailure) -> String {
        switch failure.category {
        case .invalidInput, .unsupportedInput, .ambiguousInput:
            return "The package was examined and refused before anything was stored. Retrying the same file gives the same answer."
        case .storageFailure:
            return "The refusal arrived before a byte was copied, so nothing partial was left behind."
        case .capabilityUnavailable:
            return "A capability the platform does not provide was asked for."
        case .cancelled:
            return "Nothing was changed beyond what had already completed."
        case .internalFailure:
            return "An unexpected condition was reached; the operation stopped rather than continue on an assumption."
        }
    }

    private static func spaceWord(_ failure: ImportFailure) -> String {
        // The storage refusal names the requirement in its own message; this
        // only supplies a scale when the message is shown elsewhere.
        failure.message.contains("free space") ? "the amount named above" : "some"
    }

    private static func networkWord(_ code: Int) -> String {
        switch code {
        case NSURLErrorTimedOut: return "timed out"
        case NSURLErrorNotConnectedToInternet: return "device is offline"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "host not found"
        case NSURLErrorNetworkConnectionLost: return "connection lost"
        case NSURLErrorCancelled: return "cancelled"
        default: return "transport failure"
        }
    }
}
