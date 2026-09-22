import XCTest
@testable import ZynSign

final class CertificateChainTests: XCTestCase {

    private func makeMetadata(commonName: String, fingerprintHex: String) -> CertificateMetadata {
        let subject = CertificateDistinguishedName(
            commonName: commonName,
            rawRepresentation: "CN=\(commonName)"
        )
        let issuer = CertificateDistinguishedName(
            commonName: "Issuer of \(commonName)",
            rawRepresentation: "CN=Issuer of \(commonName)"
        )
        return CertificateMetadata(
            subject: subject,
            issuer: issuer,
            serialNumber: "01",
            notValidBefore: Date(timeIntervalSince1970: 1_000_000),
            notValidAfter: Date(timeIntervalSince1970: 2_000_000),
            publicKeyInfo: PublicKeyInfo(algorithm: .rsa, keySizeInBits: 2048),
            signatureAlgorithm: .sha256WithRSAEncryption,
            sha256Fingerprint: CertificateFingerprint(hexDigest: fingerprintHex)!
        )
    }

    func testChainCreation() {
        let leaf = makeMetadata(commonName: "Leaf", fingerprintHex: CertificateFixtures.validFingerprintHex)
        let intermediate = makeMetadata(commonName: "Intermediate", fingerprintHex: CertificateFixtures.expiredFingerprintHex)
        let root = makeMetadata(commonName: "Root", fingerprintHex: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")

        let chain = CertificateChain(certificates: [leaf, intermediate, root])
        XCTAssertNotNil(chain)
        XCTAssertEqual(chain?.count, 3)
        XCTAssertEqual(chain?.leaf, leaf)
        XCTAssertEqual(chain?.root, root)
    }

    func testEmptyChainRejected() {
        let chain = CertificateChain(certificates: [])
        XCTAssertNil(chain)
    }

    func testSingleCertificateChain() {
        let leaf = makeMetadata(commonName: "Leaf", fingerprintHex: CertificateFixtures.validFingerprintHex)
        let chain = CertificateChain(certificates: [leaf])!
        XCTAssertTrue(chain.isSingleCertificate)
        XCTAssertEqual(chain.leaf, leaf)
        XCTAssertNil(chain.root)
        XCTAssertTrue(chain.intermediates.isEmpty)
    }

    func testLeafFirstOrdering() {
        let leaf = makeMetadata(commonName: "Leaf", fingerprintHex: CertificateFixtures.validFingerprintHex)
        let intermediate = makeMetadata(commonName: "Intermediate", fingerprintHex: CertificateFixtures.expiredFingerprintHex)
        let root = makeMetadata(commonName: "Root", fingerprintHex: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

        let chain = CertificateChain(certificates: [leaf, intermediate, root])!
        XCTAssertEqual(chain.certificates[0], leaf)
        XCTAssertEqual(chain.certificates[1], intermediate)
        XCTAssertEqual(chain.certificates[2], root)
    }

    func testChainEquality() {
        let leaf = makeMetadata(commonName: "Leaf", fingerprintHex: CertificateFixtures.validFingerprintHex)
        let first = CertificateChain(certificates: [leaf])!
        let second = CertificateChain(certificates: [leaf])!
        XCTAssertEqual(first, second)
    }

    func testChainDoesNotImplyTrust() {
        // Chain existence does not mean trust evaluation succeeded.
        // This documents the required distinction.
        let leaf = makeMetadata(commonName: "Leaf", fingerprintHex: CertificateFixtures.validFingerprintHex)
        let chain = CertificateChain(certificates: [leaf])!
        XCTAssertNotNil(chain)
        // Trust evaluation is separate and not performed here.
        let validity = CertificateValidity.evaluate(
            notValidBefore: leaf.notValidBefore,
            notValidAfter: leaf.notValidAfter,
            at: Date(timeIntervalSince1970: 1_500_000)
        )
        let trust = CertificateTrustEvaluation(period: validity)
        XCTAssertEqual(trust.trust, .notEvaluated)
        // Chain exists, trust not evaluated.
    }
}
