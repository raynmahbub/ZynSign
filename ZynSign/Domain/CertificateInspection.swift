import Foundation

/// The result of inspecting one certificate.
///
/// Inspection pairs a successful parse with a validity-period evaluation
/// against an injected clock. It does not evaluate a chain, does not decide
/// trust, and does not decide that the certificate is an Apple code-signing
/// identity. `trustStatus` is recorded so a caller cannot treat a missing
/// field as a positive trust result.
///
/// The certificate's DER bytes are held only on this transient value. Inspection
/// does not persist them.
struct CertificateInspection: Equatable {

    /// The parsed certificate, including the DER bytes that were accepted.
    /// Those bytes are untrusted public certificate data, not a private key.
    let certificate: Certificate

    /// The validity-period evaluation. Separate from parse success.
    let validity: CertificateValidity

    /// Trust evaluation status. Inspection always sets `.notEvaluated`.
    let trustStatus: CertificateTrustEvaluation.TrustStatus

    /// The parsed metadata.
    var metadata: CertificateMetadata { certificate.metadata }
}

/// Parses a certificate and evaluates its validity period.
///
/// Parsing and period evaluation stay separate operations. This type only
/// sequences them and stamps the evaluation with the injected clock. It does
/// not persist the certificate, does not access a private key, and does not
/// evaluate trust or Apple code-signing policy.
struct CertificateInspector {

    /// The parser selected by the composition root.
    let parser: any CertificateParser

    /// The clock used for the validity-period evaluation.
    let clock: any EvaluationClock

    /// Creates an inspector.
    init(parser: any CertificateParser, clock: any EvaluationClock) {
        self.parser = parser
        self.clock = clock
    }

    /// Inspects `input`.
    ///
    /// - Throws: A typed `ZynSignError` when the bytes cannot be parsed.
    ///   A successful result still does not mean the certificate is trusted
    ///   or suitable for code signing.
    func inspect(_ input: CertificateInput) throws -> CertificateInspection {
        let metadata = try parser.parseCertificate(input)
        let validity = CertificateValidity.evaluate(certificate: metadata, clock: clock)
        return CertificateInspection(
            certificate: Certificate(metadata: metadata, derData: input.bytes),
            validity: validity,
            trustStatus: .notEvaluated
        )
    }
}
