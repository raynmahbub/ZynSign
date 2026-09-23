import XCTest
@testable import ZynSign

final class DigestTests: XCTestCase {

    private let digest = CryptoKitMessageDigest()

    // MARK: - Known vectors

    func testSHA256KnownVectors() throws {
        XCTAssertEqual(
            try digest.digest(Data("abc".utf8), algorithm: .sha256).hexString,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        // The empty message has a defined digest.
        XCTAssertEqual(
            try digest.digest(Data(), algorithm: .sha256).hexString,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        // The one-million-character 'a' vector exercises the multi-block path.
        XCTAssertEqual(
            try digest.digest(Data(repeating: 0x61, count: 1_000_000), algorithm: .sha256).hexString,
            "cdc76e5c9914fb92816abde91043f1510111ecb01cd12af983c2477bc7cd5517"
        )
    }

    func testSHA1KnownVectors() throws {
        XCTAssertEqual(
            try digest.digest(Data("abc".utf8), algorithm: .sha1).hexString,
            "a9993e364706816aba3e25717850c26c9cd0d89d"
        )
        XCTAssertEqual(
            try digest.digest(Data(), algorithm: .sha1).hexString,
            "da39a3ee5e6b4b0d3255bfef95601890afd80709"
        )
    }

    func testSHA384KnownVector() throws {
        XCTAssertEqual(
            try digest.digest(Data("abc".utf8), algorithm: .sha384).hexString,
            "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed"
            + "8086072ba1e7cc2358baeca134c825a7"
        )
    }

    func testSHA512KnownVector() throws {
        XCTAssertEqual(
            try digest.digest(Data("abc".utf8), algorithm: .sha512).hexString,
            "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
            + "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
        )
    }

    // MARK: - Binary input and determinism

    func testBinaryDataIsDigestedExactly() throws {
        let binary = Data((0...255).map { UInt8($0) })
        let first = try digest.digest(binary, algorithm: .sha256)
        XCTAssertEqual(first.algorithm, .sha256)
        XCTAssertEqual(first.bytes.count, 32)
        // Deterministic: repeated hashing produces the same value.
        for _ in 0..<4 {
            XCTAssertEqual(try digest.digest(binary, algorithm: .sha256), first)
        }
        // Distinct inputs produce distinct digests.
        XCTAssertNotEqual(try digest.digest(Data([0x00]), algorithm: .sha256), first)
    }

    func testRepeatedHashingIsDeterministicForEverySupportedAlgorithm() throws {
        let data = Data((0..<1000).map { UInt8($0 % 251) })
        for algorithm in DigestAlgorithm.allCases {
            let first = try digest.digest(data, algorithm: algorithm)
            XCTAssertEqual(first.algorithm, algorithm)
            XCTAssertEqual(first.bytes.count, algorithm.digestLength)
            for _ in 0..<3 {
                XCTAssertEqual(try digest.digest(data, algorithm: algorithm), first)
            }
        }
    }

    func testCryptoKitSHA256AgreesWithTheCertificateFingerprintImplementation() throws {
        // The certificate fingerprint keeps its own FIPS 180-4
        // implementation; the new digest primitive must agree with it byte
        // for byte over the same inputs.
        for input in [Data(), Data("abc".utf8), CertificateFixtures.validDER,
                      Data(repeating: 0x7E, count: 70_000)] {
            let cryptoKit = try digest.digest(input, algorithm: .sha256).bytes
            let fips = Data(CertificateDigest.sha256(input))
            XCTAssertEqual(cryptoKit, fips)
        }
        // And over the fixture it reproduces the committed fingerprint.
        XCTAssertEqual(
            try digest.digest(CertificateFixtures.validDER, algorithm: .sha256).hexString,
            CertificateFixtures.validFingerprintHex
        )
    }

    // MARK: - Digest value semantics

    func testDigestIsAnExplicitValueNotAString() throws {
        let digestValue = try digest.digest(Data("abc".utf8), algorithm: .sha256)
        XCTAssertEqual(digestValue.algorithm, .sha256)
        XCTAssertEqual(digestValue.bytes.count, 32)
        // The hex rendering is lowercase and exactly twice the byte count.
        XCTAssertEqual(digestValue.hexString.count, 64)
        XCTAssertEqual(digestValue.hexString, digestValue.hexString.lowercased())
        // The canonical rendering names the algorithm.
        XCTAssertEqual(digestValue.description, "sha256:\(digestValue.hexString)")
    }

    func testWrongLengthBytesAreNotADigestOfTheAlgorithm() {
        XCTAssertNil(Digest(algorithm: .sha256, bytes: Data(repeating: 0, count: 31)))
        XCTAssertNil(Digest(algorithm: .sha256, bytes: Data(repeating: 0, count: 33)))
        XCTAssertNil(Digest(algorithm: .sha1, bytes: Data(repeating: 0, count: 32)))
        XCTAssertNotNil(Digest(algorithm: .sha256, bytes: Data(repeating: 0, count: 32)))
        XCTAssertNotNil(Digest(algorithm: .sha1, bytes: Data(repeating: 0, count: 20)))
        XCTAssertNotNil(Digest(algorithm: .sha384, bytes: Data(repeating: 0, count: 48)))
        XCTAssertNotNil(Digest(algorithm: .sha512, bytes: Data(repeating: 0, count: 64)))
    }

    func testDigestEqualityIsAlgorithmAndBytes() {
        let bytes = Data(repeating: 0x11, count: 32)
        let other = bytes.prefix(31) + Data([0xFF])
        XCTAssertEqual(Digest(algorithm: .sha256, bytes: bytes), Digest(algorithm: .sha256, bytes: bytes))
        XCTAssertNotEqual(Digest(algorithm: .sha256, bytes: bytes), Digest(algorithm: .sha256, bytes: other))
        // The 32-byte length is legal only for SHA-256 in this vocabulary:
        // the algorithm is part of the value, not an afterthought.
        XCTAssertNil(Digest(algorithm: .sha384, bytes: bytes))
    }
}
