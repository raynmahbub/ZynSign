import Foundation

/// CMS verification for provisioning-profile containers.
///
/// This is where the CMS boundary is composed: the container is read by
/// `CMSStructureReader`, embedded certificates are parsed through the existing
/// `CertificateParser` port into the existing `Certificate` model, the signer is
/// related to one embedded certificate, the signed attributes are checked
/// against the encapsulated content, and the signature itself is handed to the
/// injected `CMSSignatureVerifier`. No ASN.1 signature mathematics, no
/// certificate-chain evaluation, no keychain access, and no platform-policy
/// decision happens here.
///
/// The container and everything inside it are hostile input. Structural
/// problems are reported as typed errors; a container that decoded but did not
/// verify is reported as evidence instead, so a caller can tell a rejected
/// container from one that could not be evaluated. Payload and certificate
/// bytes stay on the transient result and are not logged or persisted.
struct ProvisioningProfileCMSVerifier: CMSVerifier {

    /// The certificate parser used for embedded certificates.
    let certificateParser: any CertificateParser

    /// The signature mechanism. Substitutable so the boundary stays testable
    /// and so an unavailable mechanism is reported rather than worked around.
    let signatureVerifier: any CMSSignatureVerifier

    init(
        certificateParser: any CertificateParser,
        signatureVerifier: any CMSSignatureVerifier
    ) {
        self.certificateParser = certificateParser
        self.signatureVerifier = signatureVerifier
    }

    func verify(_ input: ProvisioningProfileInput) throws -> CMSVerificationResult {
        guard !input.bytes.isEmpty else {
            throw ZynSignError.cms(.emptyInput, diagnosticDetail: "The CMS container input is empty.")
        }
        guard input.bytes.count <= ProvisioningProfileInput.maximumByteCount else {
            throw ZynSignError.cms(
                .inputTooLarge,
                diagnosticDetail: "The CMS container input exceeded the configured byte bound."
            )
        }

        let structure: CMSStructure
        do {
            structure = try CMSStructureReader.read(input.bytes)
        } catch let error as ZynSignError where error.cmsFailure != nil {
            throw error
        } catch {
            throw ZynSignError.cms(
                .decodeFailed,
                diagnosticDetail: "The CMS container could not be decoded (cause: \(Self.safeCauseSummary(error)))."
            )
        }

        guard let payload = structure.encapsulatedContent else {
            throw ZynSignError.cms(
                .payloadUnavailable,
                diagnosticDetail: "The CMS message carries no encapsulated content; detached content is not supported."
            )
        }
        guard !payload.isEmpty else {
            throw ZynSignError.cms(
                .payloadUnavailable,
                diagnosticDetail: "The CMS encapsulated content is empty."
            )
        }
        guard payload.count <= ProvisioningProfilePayload.maximumByteCount else {
            throw ZynSignError.cms(
                .resourceLimitExceeded,
                diagnosticDetail: "The CMS encapsulated content exceeded the payload bound."
            )
        }

        let embedded = parseEmbeddedCertificates(structure.certificateEncodings)
        let signerCount = structure.signerInfos.count

        guard signerCount == 1, let signer = structure.signerInfos.first else {
            let isEmpty = signerCount == 0
            return makeResult(
                status: isEmpty ? .noSigner : .multipleSigners,
                failure: isEmpty ? .signerUnavailable : .multipleSigners,
                failureDetail: isEmpty
                    ? "The CMS message declares no signer."
                    : "The CMS message declares \(signerCount) signers; ZynSign does not choose one.",
                signerCount: signerCount,
                payload: payload,
                embeddedCertificates: embedded.certificates,
                unparsableEmbeddedCertificateCount: embedded.unparsableCount
            )
        }

        let digestAlgorithm = CMSDigestAlgorithm.from(objectIdentifier: signer.digestAlgorithm)
        let signatureAlgorithm = SignatureAlgorithm.from(objectIdentifier: signer.signatureAlgorithm)
        let signerIdentifier = Self.domainIdentifier(from: signer.identifier)
        let selection = selectSignerCertificate(
            identifier: signer.identifier,
            parsed: embedded.certificates,
            unparsableCount: embedded.unparsableCount
        )

        guard case .extracted(let signerCertificate) = selection else {
            let status = selection.signerCertificateStatus
            return makeResult(
                status: .signerCertificateUnavailable,
                failure: .signerCertificateUnavailable,
                failureDetail: selection.diagnosticDetail(signerCount: embedded.certificates.count),
                signerCount: signerCount,
                payload: payload,
                signerCertificateStatus: status,
                signerIdentifier: signerIdentifier,
                embeddedCertificates: embedded.certificates,
                unparsableEmbeddedCertificateCount: embedded.unparsableCount,
                digestAlgorithm: digestAlgorithm,
                signatureAlgorithm: signatureAlgorithm
            )
        }

        let verificationAlgorithm = CMSVerificationAlgorithm.from(
            digestObjectIdentifier: signer.digestAlgorithm,
            signatureObjectIdentifier: signer.signatureAlgorithm
        )
        guard verificationAlgorithm.isSupported else {
            return makeResult(
                status: .unsupportedAlgorithm,
                failure: .unsupportedAlgorithm,
                failureDetail: "The CMS declares digest \(signer.digestAlgorithm) with signature algorithm \(signer.signatureAlgorithm).",
                signerCount: signerCount,
                payload: payload,
                signerCertificate: signerCertificate,
                signerCertificateStatus: .extracted,
                signerIdentifier: signerIdentifier,
                embeddedCertificates: embedded.certificates,
                unparsableEmbeddedCertificateCount: embedded.unparsableCount,
                digestAlgorithm: digestAlgorithm,
                signatureAlgorithm: signatureAlgorithm,
                verificationAlgorithm: verificationAlgorithm
            )
        }

        // Bind the payload to the signature. With signed attributes present the
        // signature covers the attributes, so the payload is authenticated only
        // if the message-digest attribute is the digest of that payload.
        let observation: CMSSignedAttributeObservation
        let message: Data
        if let attributes = signer.signedAttributes {
            guard let messageDigest = attributes.messageDigest else {
                throw ZynSignError.cms(
                    .unsupportedStructure,
                    diagnosticDetail: "The CMS signed attributes omit the message-digest attribute, "
                        + "so the payload is not bound to the signature."
                )
            }
            let contentTypeMatches = attributes.contentType.map { $0 == structure.encapsulatedContentType }
            let digestMatches = messageDigest.count == CMSSHA256Digest.length
                && messageDigest == Data(CMSSHA256Digest.of(payload))
            observation = CMSSignedAttributeObservation(
                present: true,
                attributeObjectIdentifiers: attributes.attributeObjectIdentifiers,
                messageDigestPresent: true,
                messageDigestMatchesContent: messageDigest.count == CMSSHA256Digest.length ? digestMatches : nil,
                contentTypePresent: attributes.contentType != nil,
                contentTypeMatchesEncapsulated: contentTypeMatches
            )
            guard messageDigest.count == CMSSHA256Digest.length else {
                return makeResult(
                    status: .unsupportedAlgorithm,
                    failure: .unsupportedAlgorithm,
                    failureDetail: "The message-digest attribute carries \(messageDigest.count) bytes, which is not a SHA-256 digest.",
                    signerCount: signerCount,
                    payload: payload,
                    signerCertificate: signerCertificate,
                    signerCertificateStatus: .extracted,
                    signerIdentifier: signerIdentifier,
                    embeddedCertificates: embedded.certificates,
                    unparsableEmbeddedCertificateCount: embedded.unparsableCount,
                    digestAlgorithm: digestAlgorithm,
                    signatureAlgorithm: signatureAlgorithm,
                    verificationAlgorithm: verificationAlgorithm,
                    signedAttributes: observation
                )
            }
            guard digestMatches else {
                return makeResult(
                    status: .invalid,
                    failure: .signatureInvalid,
                    failureDetail: "The message-digest attribute does not bind the encapsulated content.",
                    signerCount: signerCount,
                    payload: payload,
                    signerCertificate: signerCertificate,
                    signerCertificateStatus: .extracted,
                    signerIdentifier: signerIdentifier,
                    embeddedCertificates: embedded.certificates,
                    unparsableEmbeddedCertificateCount: embedded.unparsableCount,
                    digestAlgorithm: digestAlgorithm,
                    signatureAlgorithm: signatureAlgorithm,
                    verificationAlgorithm: verificationAlgorithm,
                    signedAttributes: observation
                )
            }
            message = attributes.verificationMessage
        } else {
            observation = .absent
            message = payload
        }

        do {
            let verified = try signatureVerifier.verify(
                message: message,
                signature: signer.signature,
                algorithm: verificationAlgorithm,
                certificate: signerCertificate
            )
            return makeResult(
                status: verified ? .verified : .invalid,
                failure: verified ? nil : .signatureInvalid,
                failureDetail: verified ? nil : "The signature mechanism rejected the CMS signature.",
                signerCount: signerCount,
                payload: payload,
                signerCertificate: signerCertificate,
                signerCertificateStatus: .extracted,
                signerIdentifier: signerIdentifier,
                embeddedCertificates: embedded.certificates,
                unparsableEmbeddedCertificateCount: embedded.unparsableCount,
                digestAlgorithm: digestAlgorithm,
                signatureAlgorithm: signatureAlgorithm,
                verificationAlgorithm: verificationAlgorithm,
                signedAttributes: observation
            )
        } catch let error as ZynSignError {
            let reason = error.cmsFailure ?? .unexpectedSecurityError
            return makeResult(
                status: Self.status(for: reason),
                failure: reason,
                failureDetail: error.diagnosticDetail,
                signerCount: signerCount,
                payload: payload,
                signerCertificate: signerCertificate,
                signerCertificateStatus: .extracted,
                signerIdentifier: signerIdentifier,
                embeddedCertificates: embedded.certificates,
                unparsableEmbeddedCertificateCount: embedded.unparsableCount,
                digestAlgorithm: digestAlgorithm,
                signatureAlgorithm: signatureAlgorithm,
                verificationAlgorithm: verificationAlgorithm,
                signedAttributes: observation
            )
        } catch {
            return makeResult(
                status: .verificationFailed,
                failure: .unexpectedSecurityError,
                failureDetail: "The signature mechanism failed (cause: \(Self.safeCauseSummary(error))).",
                signerCount: signerCount,
                payload: payload,
                signerCertificate: signerCertificate,
                signerCertificateStatus: .extracted,
                signerIdentifier: signerIdentifier,
                embeddedCertificates: embedded.certificates,
                unparsableEmbeddedCertificateCount: embedded.unparsableCount,
                digestAlgorithm: digestAlgorithm,
                signatureAlgorithm: signatureAlgorithm,
                verificationAlgorithm: verificationAlgorithm,
                signedAttributes: observation
            )
        }
    }

    // MARK: - Signer certificate selection

    /// Why a signer certificate could not be obtained.
    private enum SignerCertificateSelection {

        case extracted(Certificate)
        case absentFromMessage
        case unparsableCandidate
        case ambiguous
        case identifierNotMatchable

        var signerCertificateStatus: CMSSignerCertificateStatus {
            switch self {
            case .extracted: return .extracted
            case .absentFromMessage: return .absentFromMessage
            case .unparsableCandidate: return .unparsable
            case .ambiguous: return .ambiguous
            case .identifierNotMatchable: return .identifierNotMatchable
            }
        }

        func diagnosticDetail(signerCount: Int) -> String {
            switch self {
            case .extracted:
                return "The signer certificate was extracted."
            case .absentFromMessage:
                return "No parseable embedded certificate matches the signer identifier (\(signerCount) parsed)."
            case .unparsableCandidate:
                return "No parseable embedded certificate matches the signer identifier, "
                    + "and the bag held at least one entry that could not be parsed."
            case .ambiguous:
                return "More than one embedded certificate matches the signer identifier; ZynSign does not choose one."
            case .identifierNotMatchable:
                return "The signer is identified by a subject key identifier, which ZynSign does not relate to embedded certificates."
            }
        }
    }

    /// Relates the signer identifier to the embedded certificates.
    ///
    /// Matching uses the certificate's serial number as parsed by the existing
    /// certificate reader — cryptographic identity, not a name, label, or bag
    /// position. The issuer name in the identifier is not re-parsed here, so a
    /// serial collision between two different issuers inside one bag would be
    /// reported as `.ambiguous` rather than resolved; that is the conservative
    /// outcome and is recorded as a limitation.
    private func selectSignerCertificate(
        identifier: CMSStructureSignerIdentifier,
        parsed: [Certificate],
        unparsableCount: Int
    ) -> SignerCertificateSelection {
        switch identifier {
        case .subjectKeyIdentifier:
            return .identifierNotMatchable
        case .issuerAndSerialNumber(let serialContentBytes):
            guard let serial = CertificateSerialNumber(contentBytes: serialContentBytes) else {
                return unparsableCount > 0 ? .unparsableCandidate : .absentFromMessage
            }
            let matches = parsed.filter { $0.metadata.serialNumber == serial }
            if matches.count == 1, let certificate = matches.first {
                return .extracted(certificate)
            }
            if matches.isEmpty {
                return unparsableCount > 0 ? .unparsableCandidate : .absentFromMessage
            }
            return .ambiguous
        }
    }

    // MARK: - Embedded certificates

    /// Parses every embedded certificate encoding through the existing
    /// certificate port.
    ///
    /// Bag order carries no meaning: entries are returned in bag order only so
    /// a caller can see what was there, and no entry is assumed to be the
    /// signer, an intermediate, a root, or trusted. An entry that does not
    /// parse is counted, not retained, and its parse failure is not carried
    /// into a diagnostic, because certificate parse detail may quote bytes.
    private func parseEmbeddedCertificates(
        _ encodings: [Data]
    ) -> (certificates: [Certificate], unparsableCount: Int) {
        var certificates: [Certificate] = []
        certificates.reserveCapacity(encodings.count)
        var unparsableCount = 0
        for encoding in encodings {
            do {
                let metadata = try certificateParser.parseCertificate(CertificateInput(bytes: encoding))
                certificates.append(Certificate(metadata: metadata, derData: encoding))
            } catch {
                unparsableCount += 1
            }
        }
        return (certificates, unparsableCount)
    }

    private static func domainIdentifier(
        from identifier: CMSStructureSignerIdentifier
    ) -> CMSSignerIdentifier? {
        switch identifier {
        case .issuerAndSerialNumber(let serialContentBytes):
            guard let serial = CertificateSerialNumber(contentBytes: serialContentBytes) else { return nil }
            return .issuerAndSerialNumber(serial)
        case .subjectKeyIdentifier(let keyIdentifier):
            return .subjectKeyIdentifier(Data(keyIdentifier))
        }
    }

    /// Maps a structured failure from the signature mechanism onto a status.
    ///
    /// An unsupported algorithm and an unavailable mechanism are not signature
    /// mismatches, and neither is an unexpected failure: only a definitive
    /// rejection is reported as `.invalid`.
    private static func status(for reason: CMSFailure) -> CMSSignatureVerificationStatus {
        switch reason {
        case .signatureInvalid: return .invalid
        case .unsupportedAlgorithm: return .unsupportedAlgorithm
        case .platformVerificationUnavailable: return .unavailable
        case .signerCertificateUnavailable: return .signerCertificateUnavailable
        default: return .verificationFailed
        }
    }

    private func makeResult(
        status: CMSSignatureVerificationStatus,
        failure: CMSFailure?,
        failureDetail: String?,
        signerCount: Int,
        payload: Data?,
        signerCertificate: Certificate? = nil,
        signerCertificateStatus: CMSSignerCertificateStatus = .notSought,
        signerIdentifier: CMSSignerIdentifier? = nil,
        embeddedCertificates: [Certificate] = [],
        unparsableEmbeddedCertificateCount: Int = 0,
        digestAlgorithm: CMSDigestAlgorithm? = nil,
        signatureAlgorithm: SignatureAlgorithm? = nil,
        verificationAlgorithm: CMSVerificationAlgorithm? = nil,
        signedAttributes: CMSSignedAttributeObservation = .absent
    ) -> CMSVerificationResult {
        CMSVerificationResult(
            status: status,
            failure: failure,
            failureDetail: failureDetail,
            signerCount: signerCount,
            signedPayload: payload,
            signerCertificate: signerCertificate,
            signerCertificateStatus: signerCertificateStatus,
            signerIdentifier: signerIdentifier,
            embeddedCertificates: embeddedCertificates,
            unparsableEmbeddedCertificateCount: unparsableEmbeddedCertificateCount,
            digestAlgorithm: digestAlgorithm,
            signatureAlgorithm: signatureAlgorithm,
            verificationAlgorithm: verificationAlgorithm,
            signedAttributes: signedAttributes,
            trustEvaluation: .notPerformed
        )
    }

    private static func safeCauseSummary(_ error: any Error) -> String {
        if let cocoaError = error as? NSError {
            return "platform error code \(cocoaError.code)"
        }
        return String(describing: type(of: error))
    }
}

/// The digest the CMS boundary computes itself.
///
/// SHA-256 is reused from the existing platform digest rather than implemented
/// twice. It is used for exactly one question — does the message-digest signed
/// attribute bind the encapsulated content — and never for signature
/// verification, which stays inside the platform primitive.
enum CMSSHA256Digest {

    /// The digest length in bytes.
    static let length = 32

    /// The SHA-256 digest of `data`.
    static func of(_ data: Data) -> [UInt8] {
        CertificateDigest.sha256(data)
    }
}

/// Adapts the CMS boundary to the ZS-017 payload-decoder seam.
///
/// The seam exists so profile parsing can be reached without CMS evidence; this
/// adapter is the other direction, supplying that seam from a verified
/// container. Authenticity is attached only when the signature verified. A
/// container that decoded but could not be evaluated hands over a payload
/// marked `.notEvaluated`, which is exactly what that state means. A container
/// the CMS boundary rejects is not handed over at all: the adapter fails closed
/// rather than passing unauthenticated profile bytes to a parser.
struct CMSProvisioningProfilePayloadDecoder: ProvisioningProfilePayloadDecoder {

    let verifier: any CMSVerifier

    init(verifier: any CMSVerifier) {
        self.verifier = verifier
    }

    func decodePayload(from input: ProvisioningProfileInput) throws -> ProvisioningProfilePayload {
        let result = try verifier.verify(input)
        guard let payload = result.signedPayload else {
            throw ZynSignError.cms(
                .payloadUnavailable,
                diagnosticDetail: "The CMS verification produced no payload."
            )
        }
        switch result.status {
        case .verified:
            return ProvisioningProfilePayload(plistData: payload, authenticity: .authenticated)
        case .invalid, .noSigner, .multipleSigners:
            throw ZynSignError.cms(
                result.failure ?? .signatureInvalid,
                diagnosticDetail: result.failureDetail
            )
        case .signerCertificateUnavailable, .unsupportedAlgorithm, .unavailable, .verificationFailed:
            return ProvisioningProfilePayload(plistData: payload, authenticity: .notEvaluated)
        }
    }
}
