import Foundation

/// The digest algorithm a CMS signer declares.
///
/// Recognised spellings reuse the existing `DigestAlgorithm` vocabulary rather
/// than inventing a second one. An unrecognised object identifier is preserved
/// exactly: a digest ZynSign cannot name is a digest it cannot verify, and
/// silently substituting another one would turn an unsupported container into a
/// false conclusion.
enum CMSDigestAlgorithm: Equatable, Hashable {

    case recognized(DigestAlgorithm)
    case unknown(String)

    static let sha1ObjectIdentifier = "1.3.14.3.2.26"
    static let sha256ObjectIdentifier = "2.16.840.1.101.3.4.2.1"
    static let sha384ObjectIdentifier = "2.16.840.1.101.3.4.2.2"
    static let sha512ObjectIdentifier = "2.16.840.1.101.3.4.2.3"

    /// Maps a dotted digest object identifier exactly. Unrecognised
    /// identifiers are preserved, never guessed.
    static func from(objectIdentifier: String) -> CMSDigestAlgorithm {
        switch objectIdentifier {
        case CMSDigestAlgorithm.sha1ObjectIdentifier: return .recognized(.sha1)
        case CMSDigestAlgorithm.sha256ObjectIdentifier: return .recognized(.sha256)
        case CMSDigestAlgorithm.sha384ObjectIdentifier: return .recognized(.sha384)
        case CMSDigestAlgorithm.sha512ObjectIdentifier: return .recognized(.sha512)
        default: return .unknown(objectIdentifier)
        }
    }

    /// Whether the digest is one ZynSign names.
    var isRecognised: Bool {
        if case .unknown = self { return false }
        return true
    }

    /// The digest length in bytes, when the algorithm is recognised.
    var digestLength: Int? {
        switch self {
        case .recognized(let algorithm): return algorithm.digestLength
        case .unknown: return nil
        }
    }

    /// A diagnostic name. Unrecognised identifiers are reported as written.
    var displayName: String {
        switch self {
        case .recognized(let algorithm): return algorithm.rawValue
        case .unknown(let objectIdentifier): return objectIdentifier
        }
    }
}

/// The verification operation a CMS signer's declared algorithms map to.
///
/// CMS names a digest algorithm and a signature algorithm separately, so the
/// pair has to be mapped onto one concrete verification operation before any
/// platform primitive is asked to check a signature. Only the two operations
/// the deployment target's key APIs are documented to provide are mapped; every
/// other combination stays `.unsupported` with both identifiers preserved.
///
/// This mapping is a statement about algorithm vocabulary. It is not a
/// statement that any signature verifies, that a certificate is trusted, or
/// that a profile is authorized.
enum CMSVerificationAlgorithm: Equatable, Hashable {

    /// RSA PKCS#1 v1.5 over the SHA-256 digest of the message.
    case rsaPKCS1SHA256Message

    /// ECDSA X9.62 over the SHA-256 digest of the message.
    case ecdsaX962SHA256Message

    /// A combination ZynSign does not map onto a verification operation.
    case unsupported(digestObjectIdentifier: String, signatureObjectIdentifier: String)

    static let rsaEncryptionObjectIdentifier = "1.2.840.113549.1.1.1"
    static let sha256WithRSAEncryptionObjectIdentifier = "1.2.840.113549.1.1.11"
    static let ecdsaWithSHA256ObjectIdentifier = "1.2.840.10045.4.3.2"

    /// Maps a declared digest/signature pair. The mapping is exact; an
    /// unrecognised pair is preserved rather than approximated.
    static func from(
        digestObjectIdentifier: String,
        signatureObjectIdentifier: String
    ) -> CMSVerificationAlgorithm {
        guard digestObjectIdentifier == CMSDigestAlgorithm.sha256ObjectIdentifier else {
            return .unsupported(
                digestObjectIdentifier: digestObjectIdentifier,
                signatureObjectIdentifier: signatureObjectIdentifier
            )
        }
        switch signatureObjectIdentifier {
        case CMSVerificationAlgorithm.rsaEncryptionObjectIdentifier,
             CMSVerificationAlgorithm.sha256WithRSAEncryptionObjectIdentifier:
            return .rsaPKCS1SHA256Message
        case CMSVerificationAlgorithm.ecdsaWithSHA256ObjectIdentifier:
            return .ecdsaX962SHA256Message
        default:
            return .unsupported(
                digestObjectIdentifier: digestObjectIdentifier,
                signatureObjectIdentifier: signatureObjectIdentifier
            )
        }
    }

    /// Whether the pair maps onto an operation ZynSign can attempt.
    var isSupported: Bool {
        if case .unsupported = self { return false }
        return true
    }

    /// A diagnostic name.
    var displayName: String {
        switch self {
        case .rsaPKCS1SHA256Message: return "rsaPKCS1SHA256Message"
        case .ecdsaX962SHA256Message: return "ecdsaX962SHA256Message"
        case .unsupported(let digest, let signature):
            return "unsupported(digest \(digest), signature \(signature))"
        }
    }
}

/// How one CMS signer names the certificate that signed.
///
/// The identifier is recorded as observed. Only the issuer-and-serial form can
/// be related to an embedded certificate by ZynSign today; the subject-key
/// identifier form is preserved so a caller can see that a signer exists
/// without ZynSign pretending it could be matched.
enum CMSSignerIdentifier: Equatable, Hashable {

    case issuerAndSerialNumber(CertificateSerialNumber)
    case subjectKeyIdentifier(Data)

    /// Whether ZynSign can relate this identifier to an embedded certificate.
    var isMatchable: Bool {
        if case .issuerAndSerialNumber = self { return true }
        return false
    }

    /// A redacted diagnostic form: the serial's hexadecimal text, or the byte
    /// count of a key identifier. Never the identifier's raw bytes.
    var diagnosticDescription: String {
        switch self {
        case .issuerAndSerialNumber(let serial):
            return "issuerAndSerialNumber(serial \(serial.hexadecimal))"
        case .subjectKeyIdentifier(let identifier):
            return "subjectKeyIdentifier(\(identifier.count) bytes)"
        }
    }
}

/// The outcome of the CMS signature check itself.
///
/// This is deliberately not a `Bool`. `.verified` and `.invalid` are the two
/// cryptographic conclusions; the remaining cases record that no conclusion was
/// reached and why. None of them is a trust decision, and `.verified` does not
/// mean the signer's certificate is trusted or that a profile is authorized.
enum CMSSignatureVerificationStatus: String, CaseIterable, Equatable, Hashable {

    /// The signature over the authenticated content checks out.
    case verified

    /// The signature does not check out, or the signed attributes do not bind
    /// the encapsulated content. The container is rejected as inauthentic.
    case invalid

    /// The message carries no signer at all.
    case noSigner

    /// The message carries more than one signer. ZynSign does not choose one.
    case multipleSigners

    /// No embedded certificate could be related to the signer.
    case signerCertificateUnavailable

    /// The declared digest or signature algorithm is not one ZynSign maps onto
    /// a verification operation.
    case unsupportedAlgorithm

    /// No verification mechanism is available in this build or on this
    /// platform. Reported as unavailable, never as a defect in the input.
    case unavailable

    /// The verification operation reported an unexpected failure, so no
    /// conclusion is drawn.
    case verificationFailed

    /// Whether the signature was checked and accepted.
    var isVerified: Bool { self == .verified }

    /// Whether the outcome rejects the container as inauthentic, as opposed to
    /// recording that authenticity could not be established.
    var isRejection: Bool {
        switch self {
        case .invalid, .noSigner, .multipleSigners: return true
        default: return false
        }
    }

    /// Whether no cryptographic conclusion was reached at all.
    var isUnevaluated: Bool { !isVerified && !isRejection }
}

/// The outcome of extracting the certificate a CMS signer names.
enum CMSSignerCertificateStatus: String, CaseIterable, Equatable, Hashable {

    /// No signer was examined, so no certificate was sought.
    case notSought

    /// Exactly one embedded certificate was related to the signer and parsed.
    case extracted

    /// The message carries no certificate the signer identifier names.
    case absentFromMessage

    /// More than one embedded certificate matches the signer identifier.
    /// ZynSign does not choose between them.
    case ambiguous

    /// No parseable embedded certificate matches the signer identifier and the
    /// message carried at least one entry that could not be parsed, so the
    /// signer's certificate may exist in the message without being usable.
    case unparsable

    /// The signer identifier uses a form ZynSign does not relate to embedded
    /// certificates.
    case identifierNotMatchable

    /// Whether a signer certificate was obtained.
    var isExtracted: Bool { self == .extracted }
}

/// Certificate-chain trust evaluation state at the CMS boundary.
///
/// ZS-018 performs no trust evaluation. The state exists so that the absence of
/// trust evidence is explicit and cannot be mistaken for a positive result: a
/// verified CMS signature says the payload is the payload the signer signed,
/// not that the signer's certificate chains to an anchor Apple's policy
/// accepts. A later increment adds evaluated states behind the same seam.
enum CMSTrustEvaluationStatus: String, CaseIterable, Equatable, Hashable {

    /// No chain, anchor, revocation, or platform-policy evaluation was run.
    case notPerformed
}

/// What the CMS signed attributes were observed to contain.
///
/// Signed attributes change what a signature covers: when they are present, the
/// signature is over their DER re-encoding as a `SET OF`, and the encapsulated
/// content is bound only through the message-digest attribute. Both facts are
/// recorded so a caller can see whether that binding was checked, without this
/// type becoming an authorization decision.
struct CMSSignedAttributeObservation: Equatable, Hashable {

    /// Whether the signer carried signed attributes at all.
    let present: Bool

    /// The attribute object identifiers observed, in message order.
    let attributeObjectIdentifiers: [String]

    /// Whether a message-digest attribute was present.
    let messageDigestPresent: Bool

    /// Whether the message-digest attribute equals the digest of the
    /// encapsulated content. `nil` when the comparison was not performed, for
    /// example because there are no signed attributes or the digest algorithm
    /// is not one ZynSign computes.
    let messageDigestMatchesContent: Bool?

    /// Whether a content-type attribute was present.
    let contentTypePresent: Bool

    /// Whether the content-type attribute names the encapsulated content type.
    /// `nil` when the comparison was not performed.
    let contentTypeMatchesEncapsulated: Bool?

    /// No signed attributes were observed and nothing was compared.
    static let absent = CMSSignedAttributeObservation(
        present: false,
        attributeObjectIdentifiers: [],
        messageDigestPresent: false,
        messageDigestMatchesContent: nil,
        contentTypePresent: false,
        contentTypeMatchesEncapsulated: nil
    )
}

/// The evidence a CMS verification produced.
///
/// Every field is evidence about one question, and the questions stay separate:
/// could the container be decoded, does the signature verify, which certificate
/// signed, what else was embedded, and what was not evaluated. There is no
/// `isValid` here on purpose. A caller reading `.verified` learns only that the
/// signature over the authenticated content checked out with the signer's own
/// public key.
///
/// The payload and certificate bytes on this value are untrusted public data
/// held transiently. They are not logged, not persisted, and not exposed
/// through the interface; the redacted `description` is the diagnostic form.
struct CMSVerificationResult: Equatable, Hashable, CustomStringConvertible {

    /// The signature-check outcome.
    let status: CMSSignatureVerificationStatus

    /// The structured reason behind a non-verified status, when one applies.
    let failure: CMSFailure?

    /// Redacted diagnostic context for `failure`: structural facts, bounded
    /// counts, algorithm identifiers, and mapped platform error codes. It never
    /// contains container bytes, payload bytes, certificate bodies, or foreign
    /// error text.
    let failureDetail: String?

    /// How many signers the message carried.
    let signerCount: Int

    /// The encapsulated content, when the message carried it. Presence is not
    /// authenticity: this is the payload the container declares, and it is only
    /// authenticated when `status` is `.verified`.
    let signedPayload: Data?

    /// The signer's certificate, when one could be extracted and parsed.
    let signerCertificate: Certificate?

    /// How signer-certificate extraction ended.
    let signerCertificateStatus: CMSSignerCertificateStatus

    /// The signer identifier as observed, when a signer was examined.
    let signerIdentifier: CMSSignerIdentifier?

    /// Every certificate embedded in the message that parsed. Presence here is
    /// not a claim that a certificate is the signer, an intermediate, a root,
    /// or trusted, and the order carries no chain meaning.
    let embeddedCertificates: [Certificate]

    /// How many embedded entries could not be parsed as certificates.
    let unparsableEmbeddedCertificateCount: Int

    /// The digest algorithm the signer declared, when a signer was examined.
    let digestAlgorithm: CMSDigestAlgorithm?

    /// The signature algorithm the signer declared, when a signer was examined.
    let signatureAlgorithm: SignatureAlgorithm?

    /// The verification operation the declared pair maps to, when examined.
    let verificationAlgorithm: CMSVerificationAlgorithm?

    /// What the signed attributes were observed to contain.
    let signedAttributes: CMSSignedAttributeObservation

    /// Trust evaluation state. Always `.notPerformed` in this increment.
    let trustEvaluation: CMSTrustEvaluationStatus

    init(
        status: CMSSignatureVerificationStatus,
        failure: CMSFailure? = nil,
        failureDetail: String? = nil,
        signerCount: Int,
        signedPayload: Data? = nil,
        signerCertificate: Certificate? = nil,
        signerCertificateStatus: CMSSignerCertificateStatus = .notSought,
        signerIdentifier: CMSSignerIdentifier? = nil,
        embeddedCertificates: [Certificate] = [],
        unparsableEmbeddedCertificateCount: Int = 0,
        digestAlgorithm: CMSDigestAlgorithm? = nil,
        signatureAlgorithm: SignatureAlgorithm? = nil,
        verificationAlgorithm: CMSVerificationAlgorithm? = nil,
        signedAttributes: CMSSignedAttributeObservation = .absent,
        trustEvaluation: CMSTrustEvaluationStatus = .notPerformed
    ) {
        self.status = status
        self.failure = failure
        self.failureDetail = failureDetail
        self.signerCount = signerCount
        self.signedPayload = signedPayload
        self.signerCertificate = signerCertificate
        self.signerCertificateStatus = signerCertificateStatus
        self.signerIdentifier = signerIdentifier
        self.embeddedCertificates = embeddedCertificates
        self.unparsableEmbeddedCertificateCount = unparsableEmbeddedCertificateCount
        self.digestAlgorithm = digestAlgorithm
        self.signatureAlgorithm = signatureAlgorithm
        self.verificationAlgorithm = verificationAlgorithm
        self.signedAttributes = signedAttributes
        self.trustEvaluation = trustEvaluation
    }

    /// Whether the CMS signature over the payload verified.
    var isSignatureVerified: Bool { status.isVerified }

    /// The signer certificate's fingerprint, when a signer certificate exists.
    /// This is the only certificate rendering intended for display.
    var signerFingerprint: CertificateFingerprint? { signerCertificate?.fingerprint }

    /// The payload as the ZS-017 parsing seam expects it, with the authenticity
    /// state the CMS outcome implies. Returns `nil` when the message carried no
    /// encapsulated content.
    ///
    /// A definitive rejection is `.rejected`; an outcome that reached no
    /// cryptographic conclusion is `.notEvaluated`. The distinction matters to a
    /// caller: one says the container was found inauthentic, the other says its
    /// authenticity is unknown, and only the second may be re-examined later.
    func profilePayload() -> ProvisioningProfilePayload? {
        guard let signedPayload else { return nil }
        let authenticity: ProvisioningProfileAuthenticityStatus
        if status.isVerified {
            authenticity = .authenticated
        } else if status.isRejection {
            authenticity = .rejected
        } else {
            authenticity = .notEvaluated
        }
        return ProvisioningProfilePayload(
            plistData: signedPayload,
            authenticity: authenticity
        )
    }

    /// A redacted diagnostic rendering: states, counts, and the signer
    /// fingerprint only. It never contains payload bytes, certificate bytes, or
    /// platform error text.
    var description: String {
        var parts = [
            "cms.status(\(status.rawValue))",
            "cms.signers(\(signerCount))",
            "cms.signerCertificate(\(signerCertificateStatus.rawValue))",
            "cms.embeddedCertificates(\(embeddedCertificates.count))",
            "cms.unparsableCertificates(\(unparsableEmbeddedCertificateCount))",
            "cms.payloadBytes(\(signedPayload?.count ?? 0))",
            "cms.trust(\(trustEvaluation.rawValue))",
        ]
        if let failure {
            parts.append("cms.failure(\(failure.rawValue))")
        }
        if let failureDetail {
            parts.append("cms.failureDetail(\(failureDetail))")
        }
        if let digestAlgorithm {
            parts.append("cms.digest(\(digestAlgorithm.displayName))")
        }
        if let signatureAlgorithm {
            parts.append("cms.signatureAlgorithm(\(signatureAlgorithm.displayName))")
        }
        if let signerFingerprint {
            parts.append("cms.signerFingerprint(\(signerFingerprint.hexDigest))")
        }
        return parts.joined(separator: " ")
    }
}

/// The boundary through which ZynSign reaches CMS verification.
///
/// Callers hand over bounded, untrusted container bytes and receive evidence.
/// The port exists because CMS handling is platform-constrained — Apple's CMS
/// decoder family is documented for macOS only and is not part of the iOS API
/// surface — and because tests must be able to substitute the mechanism. It
/// exposes no platform object, no `OSStatus`, and no Core Foundation ownership
/// question to the Domain or Application layer.
///
/// What this port answers: whether the container decoded, whether the signature
/// over the authenticated content verifies, which certificate signed, and what
/// else the message embedded. What it never answers: whether the signer's
/// certificate is trusted, whether a chain reaches an Apple anchor, and whether
/// a profile authorizes anything.
protocol CMSVerifier {

    /// Verifies one untrusted CMS container.
    ///
    /// - Parameter input: The bounded raw container bytes.
    /// - Returns: The verification evidence. A non-verified status is a normal
    ///   outcome and is reported rather than thrown, so callers can distinguish
    ///   a rejected container from one that could not be evaluated.
    /// - Throws: A typed `ZynSignError` when the input is empty or oversized,
    ///   when the bytes are not a decodable CMS message of a supported shape,
    ///   or when no payload is available to hand back.
    func verify(_ input: ProvisioningProfileInput) throws -> CMSVerificationResult
}

/// The narrow seam where one signature is checked against one certificate.
///
/// This is the only place the CMS boundary touches a cryptographic primitive.
/// Keeping it separate means the container reading, signer selection, and
/// attribute binding stay deterministic and testable without a device, and that
/// the platform-specific part can be substituted or reported as unavailable.
///
/// The port verifies signature mathematics only. It does not evaluate a
/// certificate chain, does not consult a trust store, and does not decide
/// whether the certificate was allowed to sign this content.
protocol CMSSignatureVerifier {

    /// Checks `signature` over `message` with `certificate`'s public key.
    ///
    /// - Returns: `true` when the signature verifies, `false` when it does not.
    /// - Throws: A typed `ZynSignError` when the algorithm is not one this
    ///   mechanism supports, when no verification mechanism is available, or
    ///   when the platform reported an unexpected failure. A thrown error is
    ///   never a claim that the signature is invalid.
    func verify(
        message: Data,
        signature: Data,
        algorithm: CMSVerificationAlgorithm,
        certificate: Certificate
    ) throws -> Bool
}

/// The honest fallback when no signature-verification mechanism is composed.
///
/// Apple's CMS decoder is documented for macOS 10.5 and later only; it is not
/// in the iOS API surface, so no platform CMS service can back this seam on the
/// product runtime. Where ZynSign has no composed mechanism — a non-iOS build,
/// or a composition that deliberately omits one — verification is reported as
/// unavailable instead of being skipped silently or reported as a failure of
/// the user's profile.
struct UnavailableCMSSignatureVerifier: CMSSignatureVerifier {

    init() {}

    func verify(
        message: Data,
        signature: Data,
        algorithm: CMSVerificationAlgorithm,
        certificate: Certificate
    ) throws -> Bool {
        throw ZynSignError.cms(
            .platformVerificationUnavailable,
            diagnosticDetail: "No CMS signature-verification mechanism is composed in this build."
        )
    }
}
