/// A certificate chain as observed or assembled.
///
/// A certificate may be part of a chain:
///
/// leaf certificate
///      ↓
/// intermediate certificate(s)
///      ↓
/// root certificate
///
/// The chain represents relationship, not trust. The presence of a chain does
/// not mean the chain has been validated, that the root is trusted, or that
/// any platform policy accepts it. Trust evaluation is a separate operation
/// with its own result type and is not implemented in this milestone.
///
/// The domain must be able to represent chain relationships without
/// hard-coding a simplistic "one certificate = identity" assumption. This
/// type provides that capability.
///
/// Ordering is leaf-first: `certificates[0]` is the leaf (end-entity)
/// certificate, followed by intermediates in order, with the root last when
/// present. An empty chain is not valid and must not be constructed; a chain
/// with a single certificate represents a leaf with no known issuer chain.
struct CertificateChain: Equatable, Hashable {

    /// The certificates in leaf-first order.
    let certificates: [CertificateMetadata]

    /// Creates a chain from leaf-first certificates.
    ///
    /// - Parameter certificates: The certificates in leaf-first order. Must
    ///   not be empty.
    init?(certificates: [CertificateMetadata]) {
        guard !certificates.isEmpty else { return nil }
        self.certificates = certificates
    }

    /// The leaf certificate, when the chain is non-empty.
    var leaf: CertificateMetadata? { certificates.first }

    /// The intermediates, if any. Excludes leaf and root when the chain
    /// contains more than two certificates; empty for a single-certificate
    /// chain.
    var intermediates: [CertificateMetadata] {
        guard certificates.count > 2 else {
            if certificates.count == 2 {
                // Two certificates: leaf and root (or leaf and intermediate).
                // Treat second as intermediate for simplicity in this
                // milestone; full root identification requires trust
                // evaluation.
                return []
            }
            return []
        }
        return Array(certificates[1..<(certificates.count - 1)])
    }

    /// The root certificate, when the chain contains more than one
    /// certificate. For a single-certificate chain there is no distinct root.
    var root: CertificateMetadata? {
        guard certificates.count > 1 else { return nil }
        return certificates.last
    }

    /// The number of certificates in the chain.
    var count: Int { certificates.count }

    /// Whether the chain contains only a leaf with no known intermediates or
    /// root.
    var isSingleCertificate: Bool { certificates.count == 1 }
}
