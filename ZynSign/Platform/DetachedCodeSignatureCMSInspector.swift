import Foundation

/// Examines the CMS signature of an existing Mach-O code signature.
///
/// A code signature's CMS message is detached: it signs the CodeDirectory
/// without carrying it. This inspector reads the message with ZynSign's
/// bounded `CMSStructureReader` in its code-signature mode, relates the single
/// signer to one embedded certificate by serial number (as the provisioning
/// profile verifier does), compares the message-digest signed attribute with
/// the digest of each CodeDirectory the signature carries, and hands the
/// signature over the signed attributes to the injected
/// `CMSSignatureVerifier`, which uses the platform's key primitives.
///
/// What an `evaluated` result establishes, at most: the message digest binds
/// one of the signature's CodeDirectories, and the signature over the signed
/// attributes was produced by the private key matching the embedded signer
/// certificate. It never establishes that the certificate chains to Apple, is
/// unexpired, is not revoked, or is authorised for anything — no trust
/// evaluation runs here — and it says nothing about installability.
///
/// Every outcome is a value. A message the bounded reader refuses is reported
/// as `unreadable` with the reason, never as an invalid signature.
struct DetachedCodeSignatureCMSInspector: CodeSignatureCMSVerifying {

    let certificateParser: any CertificateParser
    let signatureVerifier: any CMSSignatureVerifier
    let digest: any MessageDigest

    init(
        certificateParser: any CertificateParser,
        signatureVerifier: any CMSSignatureVerifier,
        digest: any MessageDigest
    ) {
        self.certificateParser = certificateParser
        self.signatureVerifier = signatureVerifier
        self.digest = digest
    }

    func assess(cmsPayload: Data, codeDirectories: [CodeSignatureCMSContent]) -> CodeSignatureCMSAssessment {
        guard !cmsPayload.isEmpty else { return .empty }

        let structure: CMSStructure
        do {
            structure = try CMSStructureReader.read(cmsPayload, mode: .codeSignature)
        } catch {
            return .unreadable(Self.unreadableReason(for: error))
        }

        let parsed = parseCertificates(structure.certificateEncodings)
        let signerCount = structure.signerInfos.count
        guard signerCount == 1, let signer = structure.signerInfos.first else {
            let reason = signerCount == 0
                ? "The CMS message names no signer."
                : "The CMS message names \(signerCount) signers; ZynSign does not choose one."
            return .evaluated(CodeSignatureCMSEvaluation(
                signerCount: signerCount,
                certificateCount: structure.certificateEncodings.count,
                signer: nil,
                signerCertificateNote: reason,
                digestAlgorithmName: nil,
                signatureAlgorithmName: nil,
                binding: .notCompared(reason),
                signature: .notPerformed(reason),
                declaredSigningTime: nil,
                hasUnsignedAttributes: false
            ))
        }

        let digestAlgorithm = CMSDigestAlgorithm.from(objectIdentifier: signer.digestAlgorithm)
        let signatureAlgorithm = SignatureAlgorithm.from(objectIdentifier: signer.signatureAlgorithm)
        let selection = selectSignerCertificate(
            identifier: signer.identifier,
            parsed: parsed.certificates,
            unparsableCount: parsed.unparsableCount
        )

        let binding = bindingResult(
            signedAttributes: signer.signedAttributes,
            digestAlgorithm: digestAlgorithm,
            codeDirectories: codeDirectories
        )
        let signatureCheck = signatureResult(
            signer: signer,
            selection: selection
        )

        return .evaluated(CodeSignatureCMSEvaluation(
            signerCount: signerCount,
            certificateCount: structure.certificateEncodings.count,
            signer: selection.certificate.map { Self.summary(of: $0.metadata) },
            signerCertificateNote: selection.note,
            digestAlgorithmName: Self.digestName(digestAlgorithm),
            signatureAlgorithmName: signatureAlgorithm.displayName,
            binding: binding,
            signature: signatureCheck,
            declaredSigningTime: signer.signedAttributes?.signingTime,
            hasUnsignedAttributes: signer.unsignedAttributeCount > 0
        ))
    }

    // MARK: - Binding

    private func bindingResult(
        signedAttributes: CMSStructureSignedAttributes?,
        digestAlgorithm: CMSDigestAlgorithm,
        codeDirectories: [CodeSignatureCMSContent]
    ) -> CMSSignatureBinding {
        guard let attributes = signedAttributes else {
            return .notCompared("The signer carries no signed attributes. Code signatures bind the CodeDirectory through the message-digest attribute, so ZynSign has nothing to compare.")
        }
        guard let messageDigest = attributes.messageDigest else {
            return .notCompared("The signed attributes carry no message digest, so no CodeDirectory is bound to the signature.")
        }
        guard case .recognized(let algorithm) = digestAlgorithm else {
            return .notCompared("The signer declares a digest algorithm ZynSign does not compute (\(digestAlgorithm.displayName)).")
        }
        guard messageDigest.count == algorithm.digestLength else {
            return .mismatch
        }
        guard !codeDirectories.isEmpty else {
            return .notCompared("The signature carries no CodeDirectory to compare with.")
        }
        for candidate in codeDirectories {
            do {
                let computed = try digest.digest(candidate.bytes, algorithm: algorithm)
                if computed.bytes == messageDigest {
                    return .matches(codeDirectorySlot: candidate.codeDirectorySlot)
                }
            } catch {
                return .notCompared("The \(Self.digestName(digestAlgorithm)) digest of the CodeDirectory could not be computed on this device.")
            }
        }
        return .mismatch
    }

    // MARK: - Signature

    private func signatureResult(
        signer: CMSStructureSignerInfo,
        selection: SignerCertificateSelection
    ) -> CMSSignatureCheck {
        guard let certificate = selection.certificate else {
            return .notPerformed(selection.note ?? "No signer certificate could be related to the signer.")
        }
        guard let attributes = signer.signedAttributes else {
            return .notPerformed("The signer carries no signed attributes, which is not the form code signatures use.")
        }
        let algorithm = CMSVerificationAlgorithm.from(
            digestObjectIdentifier: signer.digestAlgorithm,
            signatureObjectIdentifier: signer.signatureAlgorithm
        )
        guard algorithm.isSupported else {
            return .notPerformed("The signer declares an algorithm pair ZynSign does not verify. ZynSign verifies RSA and ECDSA signatures over SHA-256.")
        }
        do {
            let verified = try signatureVerifier.verify(
                message: attributes.verificationMessage,
                signature: signer.signature,
                algorithm: algorithm,
                certificate: certificate
            )
            return verified ? .verified : .invalid
        } catch let error as ZynSignError {
            switch error.cmsFailure {
            case .some(.platformVerificationUnavailable):
                return .notPerformed("No signature-verification mechanism is available in this build or on this platform.")
            case .some(.unsupportedAlgorithm):
                return .notPerformed("The signer's key does not support the declared verification algorithm on this device.")
            case .some(.signerCertificateUnavailable):
                return .notPerformed("The platform could not read a public key from the signer certificate.")
            default:
                return .notPerformed("The platform could not complete the signature check, so no conclusion was drawn.")
            }
        } catch {
            return .notPerformed("The platform could not complete the signature check, so no conclusion was drawn.")
        }
    }

    // MARK: - Signer certificate

    private struct SignerCertificateSelection {
        let certificate: Certificate?
        let note: String?
    }

    /// Relates the signer to one embedded certificate by serial number — the
    /// same rule the provisioning-profile verifier uses. A serial shared by two
    /// embedded certificates is reported as ambiguous rather than resolved.
    private func selectSignerCertificate(
        identifier: CMSStructureSignerIdentifier,
        parsed: [Certificate],
        unparsableCount: Int
    ) -> SignerCertificateSelection {
        switch identifier {
        case .subjectKeyIdentifier:
            return SignerCertificateSelection(
                certificate: nil,
                note: "The signer is identified by a subject key identifier, which ZynSign does not relate to embedded certificates."
            )
        case .issuerAndSerialNumber(let serialContentBytes):
            guard let serial = CertificateSerialNumber(contentBytes: serialContentBytes) else {
                return SignerCertificateSelection(certificate: nil, note: "The signer's serial number could not be read.")
            }
            let matches = parsed.filter { $0.metadata.serialNumber == serial }
            if matches.count == 1, let certificate = matches.first {
                return SignerCertificateSelection(certificate: certificate, note: nil)
            }
            if matches.isEmpty {
                return SignerCertificateSelection(
                    certificate: nil,
                    note: unparsableCount > 0
                        ? "No readable embedded certificate matches the signer, and at least one embedded certificate could not be read."
                        : "The message carries no certificate matching the signer."
                )
            }
            return SignerCertificateSelection(
                certificate: nil,
                note: "More than one embedded certificate matches the signer; ZynSign does not choose one."
            )
        }
    }

    private func parseCertificates(_ encodings: [Data]) -> (certificates: [Certificate], unparsableCount: Int) {
        var certificates: [Certificate] = []
        var unparsable = 0
        for encoding in encodings {
            do {
                let metadata = try certificateParser.parseCertificate(CertificateInput(bytes: encoding))
                certificates.append(Certificate(metadata: metadata, derData: encoding))
            } catch {
                unparsable += 1
            }
        }
        return (certificates, unparsable)
    }

    // MARK: - Presentation values

    private static func summary(of metadata: CertificateMetadata) -> CodeSignatureSignerSummary {
        CodeSignatureSignerSummary(
            commonName: metadata.subject.commonName,
            organization: metadata.subject.organization,
            organizationalUnit: metadata.subject.organizationalUnit,
            issuerCommonName: metadata.issuer.commonName,
            notValidBefore: metadata.notValidBefore,
            notValidAfter: metadata.notValidAfter,
            keyDescription: keyDescription(metadata.publicKeyInfo)
        )
    }

    private static func keyDescription(_ info: PublicKeyInfo) -> String {
        let family: String
        switch info.algorithm {
        case .rsa: family = "RSA"
        case .ec: family = info.curveName.map { "EC \($0)" } ?? "EC"
        case .unknown: family = "Unrecognized key"
        }
        guard let bits = info.keySizeInBits else { return family }
        return "\(family), \(bits)-bit"
    }

    private static func digestName(_ algorithm: CMSDigestAlgorithm) -> String {
        switch algorithm {
        case .recognized(.sha1): return "SHA-1"
        case .recognized(.sha256): return "SHA-256"
        case .recognized(.sha384): return "SHA-384"
        case .recognized(.sha512): return "SHA-512"
        case .unknown(let identifier): return identifier
        }
    }

    private static func unreadableReason(for error: any Error) -> String {
        guard let failure = (error as? ZynSignError)?.cmsFailure else {
            return "ZynSign's bounded CMS reader could not read the signature message."
        }
        switch failure {
        case .unsupportedStructure, .unsupportedContentType:
            return "The signature message uses a CMS structure ZynSign's bounded reader does not support, so it was not evaluated."
        case .resourceLimitExceeded, .inputTooLarge:
            return "The signature message exceeds a bound ZynSign's CMS reader enforces, so it was not evaluated."
        case .truncatedCMS:
            return "The signature message ends before a value it declares."
        default:
            return "The signature message is not well-formed DER CMS, so it was not evaluated."
        }
    }
}
