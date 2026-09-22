import Foundation

/// Untrusted certificate bytes at the inspection boundary.
///
/// Certificate data enters ZynSign as bytes and nothing else. Holding a
/// `CertificateInput` does not mean the bytes are a certificate, that they
/// are authentic, that they are trusted, that they are suitable for code
/// signing, or that a matching private key is available. Parsing is an
/// inspection operation. It does not authorise anything.
///
/// The bytes are not logged, not persisted by inspection, and not executed.
struct CertificateInput: Equatable, Hashable {

    /// ZynSign's bound on untrusted certificate input, in bytes.
    ///
    /// No published size limit for `SecCertificateCreateWithData` was found
    /// (**Unknown**). This bound is ZynSign policy so inspection cannot be
    /// asked to retain an unbounded buffer. It is far above ordinary X.509
    /// certificates, including code-signing certificates with extensions.
    static let maximumByteCount = 256 * 1024

    /// The untrusted bytes, exactly as presented.
    let bytes: Data

    /// Creates an input from untrusted bytes. Acceptance is not checked here;
    /// the parser classifies empty, oversized, and malformed input.
    init(bytes: Data) {
        self.bytes = bytes
    }
}
