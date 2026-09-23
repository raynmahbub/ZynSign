import Foundation

/// The result of a digest operation: the algorithm that produced it and the
/// exact digest bytes.
///
/// A digest is a value, not a string. The bytes are the digest; the
/// hexadecimal rendering (`hexString`) is a presentation concern for
/// diagnostics and identifiers and never replaces the bytes. Two digests are
/// equal only when they carry the same algorithm and the same bytes: the
/// same bytes under two different algorithms are different values, which is
/// exactly why the algorithm is part of the value.
///
/// A digest identifies bytes. It is not a signature, not a fingerprint of
/// trust, and not evidence that anything is authentic.
struct Digest: Equatable, Hashable, CustomStringConvertible {

    /// The algorithm that produced the digest.
    let algorithm: DigestAlgorithm

    /// The exact digest bytes. The count is always
    /// `algorithm.digestLength`.
    let bytes: Data

    /// Creates a digest, or returns `nil` when `bytes` does not carry the
    /// exact length the algorithm produces.
    ///
    /// There is no truncation and no padding: bytes of the wrong length are
    /// not a digest of this algorithm, and pretending they are would turn a
    /// malformed value into a false match.
    init?(algorithm: DigestAlgorithm, bytes: Data) {
        guard bytes.count == algorithm.digestLength else { return nil }
        self.algorithm = algorithm
        self.bytes = bytes
    }

    /// Creates a digest from a byte sequence, or returns `nil` when the
    /// length does not match the algorithm.
    init?(algorithm: DigestAlgorithm, bytes: [UInt8]) {
        self.init(algorithm: algorithm, bytes: Data(bytes))
    }

    /// The digest as lowercase hexadecimal text, for diagnostics and
    /// identifiers. This is a rendering of `bytes`, never a substitute for
    /// them.
    var hexString: String {
        let hexDigits = Array("0123456789abcdef")
        var text = ""
        text.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            text.append(hexDigits[Int(byte >> 4)])
            text.append(hexDigits[Int(byte & 0x0F)])
        }
        return text
    }

    /// The canonical rendering `algorithm:hex` for diagnostics.
    var description: String { "\(algorithm.rawValue):\(hexString)" }
}

/// The boundary through which ZynSign computes digests over arbitrary byte
/// input.
///
/// Domain names the operation and the result but never performs hashing
/// itself; the implementation is platform-bound (Apple's hashing primitives)
/// and lives in Platform, and tests substitute it. The port exists because
/// hashing is platform-bound on the product runtime and because deterministic
/// tests need to stand in for it.
protocol MessageDigest {

    /// Computes the digest of `data` under `algorithm`.
    ///
    /// - Parameters:
    ///   - data: The exact bytes to digest, in any order and of any length
    ///     the caller can hold.
    ///   - algorithm: The digest algorithm to apply.
    /// - Returns: The digest value: the algorithm and its exact bytes.
    /// - Throws: A typed `ZynSignError` when `algorithm` is not one this
    ///   mechanism supports. An unsupported algorithm is reported, never
    ///   substituted for another one.
    func digest(_ data: Data, algorithm: DigestAlgorithm) throws -> Digest
}
