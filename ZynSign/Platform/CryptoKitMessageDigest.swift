import Foundation
import CryptoKit

/// Digest computation through CryptoKit's hashing primitives.
///
/// Every algorithm in ZynSign's digest vocabulary has a platform primitive
/// on the deployment target: CryptoKit's SHA-256, SHA-384, and SHA-512 are
/// documented for iOS 13 and later, and its `Insecure.SHA1` for the same
/// (the deployment target is iOS 17). No custom hashing implementation is
/// introduced where a verified Apple primitive is appropriate.
///
/// SHA-1 exists in the vocabulary because legacy Apple code-signing formats
/// use it. Nothing in this type claims SHA-1 is an acceptable signing
/// digest; it is a digest value the platform can compute, no more.
///
/// The one-shot API hashes the data the caller already holds and produces
/// no intermediate whole-buffer copy in ZynSign's code. Streaming hashing is
/// deliberately not introduced here: it belongs to the later Mach-O stage,
/// where page- and resource-scale inputs will require it, and adding it now
/// would be unmeasured complexity.
struct CryptoKitMessageDigest: MessageDigest {

    init() {}

    func digest(_ data: Data, algorithm: DigestAlgorithm) throws -> Digest {
        let bytes: Data
        switch algorithm {
        case .sha1:
            bytes = Data(Insecure.SHA1.hash(data: data))
        case .sha256:
            bytes = Data(SHA256.hash(data: data))
        case .sha384:
            bytes = Data(SHA384.hash(data: data))
        case .sha512:
            bytes = Data(SHA512.hash(data: data))
        }
        // A platform primitive produces the exact length; the guard keeps
        // the failure structured instead of force-unwrapped.
        guard let digest = Digest(algorithm: algorithm, bytes: bytes) else {
            throw ZynSignError.crypto(.unexpectedFailure)
        }
        return digest
    }
}
