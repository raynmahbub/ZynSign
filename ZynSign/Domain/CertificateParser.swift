import Foundation

/// The boundary through which ZynSign reaches certificate parsing.
///
/// Certificate input is untrusted. This port is the seam where DER parsing,
/// resource limits, and metadata extraction live; callers see only domain
/// types and structured failures, and never see a platform certificate object
/// or raw parsing detail.
///
/// The port is deliberately narrow. It answers the questions the domain
/// actually needs — can these bytes be parsed as a certificate, and what
/// metadata do they carry — and nothing else. Trust evaluation, chain
/// validation, and suitability for code signing are separate operations with
/// separate result types.
protocol CertificateParser {

    /// Parses `derData` as a single X.509 certificate and returns its
    /// metadata.
    ///
    /// - Parameter derData: The DER-encoded certificate bytes. Treated as
    ///   untrusted input.
    /// - Returns: The extracted metadata. Existence of metadata means only
    ///   that the bytes were structurally parseable; it does not mean the
    ///   certificate is currently valid, trusted, or suitable for code
    ///   signing.
    /// - Throws: A typed `ZynSignError` when the bytes are malformed,
    ///   unsupported, or otherwise unparseable.
    func parseCertificate(derData: Data) throws -> CertificateMetadata

    /// Parses multiple DER-encoded certificates as a chain.
    ///
    /// The default implementation parses each entry individually and returns
    /// a chain in the order provided. Implementations may override to
    /// perform additional chain-specific validation, but must not perform
    /// trust evaluation.
    ///
    /// - Parameter derDatas: The DER-encoded certificates, leaf-first.
    /// - Returns: The chain.
    /// - Throws: A typed `ZynSignError` when any entry is malformed or the
    ///   chain is empty.
    func parseChain(derDatas: [Data]) throws -> CertificateChain
}

extension CertificateParser {

    func parseChain(derDatas: [Data]) throws -> CertificateChain {
        guard !derDatas.isEmpty else {
            throw ZynSignError.invalidCertificateData(
                diagnosticDetail: "No certificate data was provided for chain parsing."
            )
        }
        var metadatas: [CertificateMetadata] = []
        metadatas.reserveCapacity(derDatas.count)
        for data in derDatas {
            let metadata = try parseCertificate(derData: data)
            metadatas.append(metadata)
        }
        guard let chain = CertificateChain(certificates: metadatas) else {
            throw ZynSignError.invalidCertificateData(
                diagnosticDetail: "Certificate chain construction failed after parsing."
            )
        }
        return chain
    }
}
