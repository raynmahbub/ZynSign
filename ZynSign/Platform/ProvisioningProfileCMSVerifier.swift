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

    private struct VerificationEvidence {
        let signerCount: Int
        let payload: Data?
        let embeddedCertificates: [Certificate]
        let unparsableEmbeddedCertificateCount: Int
        var signerCertificate: Certificate? = nil
        var signerCertificateStatus: CMSSignerCertificateStatus = .notSought
        var signerIdentifier: CMSSignerIdentifier? = nil
        var digestAlgorithm: CMSDigestAlgorithm? = nil
        var signatureAlgorithm: SignatureAlgorithm? = nil
        var verificationAlgorithm: CMSVerificationAlgorithm? = nil
    }

    private struct PreparedVerificationMessage {
        let message: Data
        let signedAttributes: CMSSignedAttributeObservation
    }

    private enum MessagePreparation {
        case ready(PreparedVerificationMessage)
        case rejected(CMSVerificationResult)
    }

    func verify(_ input: ProvisioningProfileInput) throws -> CMSVerificationResult {
        try validateInput(input)
        let structure = try readStructure(from: input)
        let payload = try encapsulatedPayload(from: structure)
        let embedded = parseEmbeddedCertificates(structure.certificateEncodings)
        var evidence = VerificationEvidence(
            signerCount: structure.signerInfos.count,
            payload: payload,
            embeddedCertificates: embedded.certificates,
            unparsableEmbeddedCertificateCount: embedded.unparsableCount
        )
        guard structure.signerInfos.count == 1,
              let signer = structure.signerInfos.first else {
            return resultForSignerCount(evidence)
        }

        evidence.digestAlgorithm = CMSDigestAlgorithm.from(objectIdentifier: signer.digestAlgorithm)
        evidence.signatureAlgorithm = SignatureAlgorithm.from(objectIdentifier: signer.signatureAlgorithm)
        evidence.signerIdentifier = Self.domainIdentifier(from: signer.identifier)
        let selection = selectSignerCertificate(
            identifier: signer.identifier,
            parsed: embedded.certificates,
            unparsableCount: embedded.unparsableCount
        )
        guard case .extracted(let signerCertificate) = selection else {
            evidence.signerCertificateStatus = selection.signerCertificateStatus
            return resultForCertificateSelection(selection, evidence: evidence)
        }
        evidence.signerCertificate = signerCertificate
        evidence.signerCertificateStatus = .extracted

        let algorithm = CMSVerificationAlgorithm.from(
            digestObjectIdentifier: signer.digestAlgorithm,
            signatureObjectIdentifier: signer.signatureAlgorithm
        )
        evidence.verificationAlgorithm = algorithm
        guard algorithm.isSupported else {
            return resultForUnsupportedAlgorithm(signer, evidence: evidence)
        }

        let preparation = try prepareVerificationMessage(
            signer.signedAttributes,
            encapsulatedContentType: structure.encapsulatedContentType,
            payload: payload,
            evidence: evidence
        )
        switch preparation {
        case .rejected(let result):
            return result
        case .ready(let prepared):
            return verifySignature(
                signer,
                certificate: signerCertificate,
                algorithm: algorithm,
                prepared: prepared,
                evidence: evidence
            )
        }
    }

    private func validateInput(_ input: ProvisioningProfileInput) throws {
        guard !input.bytes.isEmpty else {
            throw ZynSignError.cms(.emptyInput, diagnosticDetail: "The CMS container input is empty.")
        }
        guard input.bytes.count <= ProvisioningProfileInput.maximumByteCount else {
            throw ZynSignError.cms(
                .inputTooLarge,
                diagnosticDetail: "The CMS container input exceeded the configured byte bound."
            )
        }
    }

    private func readStructure(from input: ProvisioningProfileInput) throws -> CMSStructure {
        do {
            return try CMSStructureReader.read(input.bytes)
        } catch let error as ZynSignError where error.cmsFailure != nil {
            throw error
        } catch {
            throw ZynSignError.cms(
                .decodeFailed,
                diagnosticDetail: "The CMS container could not be decoded (cause: \(Self.safeCauseSummary(error)))."
            )
        }
    }

    private func encapsulatedPayload(from structure: CMSStructure) throws -> Data {
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
        return payload
    }

    private func resultForSignerCount(_ evidence: VerificationEvidence) -> CMSVerificationResult {
        let isEmpty = evidence.signerCount == 0
        return makeResult(
            status: isEmpty ? .noSigner : .multipleSigners,
            failure: isEmpty ? .signerUnavailable : .multipleSigners,
            failureDetail: isEmpty
                ? "The CMS message declares no signer."
                : "The CMS message declares \(evidence.signerCount) signers; ZynSign does not choose one.",
            evidence: evidence
        )
    }

    private func resultForCertificateSelection(
        _ selection: SignerCertificateSelection,
        evidence: VerificationEvidence
    ) -> CMSVerificationResult {
        makeResult(
            status: .signerCertificateUnavailable,
            failure: .signerCertificateUnavailable,
            failureDetail: selection.diagnosticDetail(signerCount: evidence.embeddedCertificates.count),
            evidence: evidence
        )
    }

    private func resultForUnsupportedAlgorithm(
        _ signer: CMSStructureSignerInfo,
        evidence: VerificationEvidence
    ) -> CMSVerificationResult {
        makeResult(
            status: .unsupportedAlgorithm,
            failure: .unsupportedAlgorithm,
            failureDetail: "The CMS declares digest \(signer.digestAlgorithm) with signature algorithm \(signer.signatureAlgorithm).",
            evidence: evidence
        )
    }

    private func prepareVerificationMessage(
        _ attributes: CMSStructureSignedAttributes?,
        encapsulatedContentType: String?,
        payload: Data,
        evidence: VerificationEvidence
    ) throws -> MessagePreparation {
        guard let attributes else {
            return .ready(PreparedVerificationMessage(message: payload, signedAttributes: .absent))
        }
        guard let messageDigest = attributes.messageDigest else {
            throw ZynSignError.cms(
                .unsupportedStructure,
                diagnosticDetail: "The CMS signed attributes omit the message-digest attribute, "
                    + "so the payload is not bound to the signature."
            )
        }
        let contentTypeMatches = attributes.contentType.map { $0 == encapsulatedContentType }
        let hasSHA256Digest = messageDigest.count == CMSSHA256Digest.length
        let digestMatches = hasSHA256Digest && messageDigest == Data(CMSSHA256Digest.of(payload))
        let observation = CMSSignedAttributeObservation(
            present: true,
            attributeObjectIdentifiers: attributes.attributeObjectIdentifiers,
            messageDigestPresent: true,
            messageDigestMatchesContent: hasSHA256Digest ? digestMatches : nil,
            contentTypePresent: attributes.contentType != nil,
            contentTypeMatchesEncapsulated: contentTypeMatches
        )
        if !hasSHA256Digest {
            return .rejected(makeResult(
                status: .unsupportedAlgorithm,
                failure: .unsupportedAlgorithm,
                failureDetail: "The message-digest attribute carries \(messageDigest.count) bytes, which is not a SHA-256 digest.",
                evidence: evidence,
                signedAttributes: observation
            ))
        }
        guard digestMatches else {
            return .rejected(makeResult(
                status: .invalid,
                failure: .signatureInvalid,
                failureDetail: "The message-digest attribute does not bind the encapsulated content.",
                evidence: evidence,
                signedAttributes: observation
            ))
        }
        return .ready(PreparedVerificationMessage(
            message: attributes.verificationMessage,
            signedAttributes: observation
        ))
    }

    private func verifySignature(
        _ signer: CMSStructureSignerInfo,
        certificate: Certificate,
        algorithm: CMSVerificationAlgorithm,
        prepared: PreparedVerificationMessage,
        evidence: VerificationEvidence
    ) -> CMSVerificationResult {
        do {
            let verified = try signatureVerifier.verify(
                message: prepared.message,
                signature: signer.signature,
                algorithm: algorithm,
                certificate: certificate
            )
            return makeResult(
                status: verified ? .verified : .invalid,
                failure: verified ? nil : .signatureInvalid,
                failureDetail: verified ? nil : "The signature mechanism rejected the CMS signature.",
                evidence: evidence,
                signedAttributes: prepared.signedAttributes
            )
        } catch let error as ZynSignError {
            let reason = error.cmsFailure ?? .unexpectedSecurityError
            return makeResult(
                status: Self.status(for: reason),
                failure: reason,
                failureDetail: error.diagnosticDetail,
                evidence: evidence,
                signedAttributes: prepared.signedAttributes
            )
        } catch {
            return makeResult(
                status: .verificationFailed,
                failure: .unexpectedSecurityError,
                failureDetail: "The signature mechanism failed (cause: \(Self.safeCauseSummary(error))).",
                evidence: evidence,
                signedAttributes: prepared.signedAttributes
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
        evidence: VerificationEvidence,
        signedAttributes: CMSSignedAttributeObservation = .absent
    ) -> CMSVerificationResult {
        CMSVerificationResult(
            status: status,
            failure: failure,
            failureDetail: failureDetail,
            signerCount: evidence.signerCount,
            signedPayload: evidence.payload,
            signerCertificate: evidence.signerCertificate,
            signerCertificateStatus: evidence.signerCertificateStatus,
            signerIdentifier: evidence.signerIdentifier,
            embeddedCertificates: evidence.embeddedCertificates,
            unparsableEmbeddedCertificateCount: evidence.unparsableEmbeddedCertificateCount,
            digestAlgorithm: evidence.digestAlgorithm,
            signatureAlgorithm: evidence.signatureAlgorithm,
            verificationAlgorithm: evidence.verificationAlgorithm,
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
