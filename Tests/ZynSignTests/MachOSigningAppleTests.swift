#if os(iOS)
import Foundation
import Security
import XCTest
@testable import ZynSign

/// Real Security primitive tests. These must run on an iOS simulator/device;
/// their presence is not evidence that either environment has been exercised.
final class MachOSigningAppleTests: XCTestCase {
    func testIndependentPublicVectorWithSecurityVerifier() throws {
        let identity = try MachOVectorIdentity()
        let engine = SignMachOUseCase(identities: identity, digest: CryptoKitMessageDigest(),
                                     verifier: AppleSignatureVerifier())
        let request = try signingRequest(identity: identity.id)
        let result = try engine.sign(request)
        XCTAssertEqual(identity.calls, 1)
        XCTAssertEqual(result.artifact, MachOSigningFixtures.expectedSignedMachO)
        var tampered = result.artifact
        tampered[512] ^= 1
        XCTAssertThrowsError(try engine.verify(artifact: tampered, request: request, certificate: identity.certificate))
    }

    func testEphemeralIdentitySignsOnceAndVerifiesCompleteArtifact() throws {
        let identity = try EphemeralMachOIdentity()
        let engine = SignMachOUseCase(identities: identity, digest: CryptoKitMessageDigest(),
                                     verifier: AppleSignatureVerifier())
        let request = try signingRequest(identity: identity.identityID)
        let first = try engine.sign(request)
        XCTAssertEqual(identity.calls, 1)
        XCTAssertEqual(try engine.verify(artifact: first.artifact, request: request,
                                        certificate: identity.certificate), first.codeDirectoryDigest)
        let second = try engine.sign(request)
        XCTAssertEqual(identity.calls, 2)
        // Fixed certificate and inputs, PKCS#1 v1.5, no time attributes.
        XCTAssertEqual(first.artifact, second.artifact)
        var damaged = first.artifact
        damaged[first.layout.offset + 28 + 80] ^= 1
        XCTAssertThrowsError(try engine.verify(artifact: damaged, request: request, certificate: identity.certificate))
        let other = try EphemeralMachOIdentity()
        XCTAssertThrowsError(try engine.verify(artifact: first.artifact, request: request, certificate: other.certificate))
    }
}

/// Test-only ephemeral capability, using the existing protocol. No private-key
/// export, import, serialization, Keychain persistence, or temporary key file.
private final class EphemeralMachOIdentity: IdentityStore, SigningCapability {
    let identityID = SigningIdentityIdentifier()
    private let key: SecKey
    let certificate: Certificate
    let publicKeyAlgorithm: PublicKeyAlgorithm = .rsa
    let isAvailable = true
    let supportedAlgorithms: Set<SigningAlgorithm> = [.rsaPKCS1SHA256Digest]
    var calls = 0

    init() throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrIsPermanent as String: false
        ]
        let generatedKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        key = generatedKey
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(generatedKey))
        // This is explicitly the public key, not the private signing handle.
        let publicBytes = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let rsaOID = Data([0x06,0x09,0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x01,0x01])
        let rsaSHA256OID = Data([0x06,0x09,0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x01,0x0B])
        let algorithm = Self.der(0x30, rsaSHA256OID + Data([0x05,0x00]))
        let name = Self.der(0x30, Self.der(0x31, Self.der(0x30,
            Data([0x06,0x03,0x55,0x04,0x03]) + Self.der(0x0C, Data("ZynSign Ephemeral Test".utf8)))))
        let validity = Self.der(0x30, Self.der(0x17, Data("260101000000Z".utf8))
            + Self.der(0x17, Data("270101000000Z".utf8)))
        let subjectPublicKeyInfo = Self.der(0x30,
            Self.der(0x30, rsaOID + Data([0x05,0x00])) + Self.der(0x03, Data([0]) + publicBytes))
        let tbs = Self.der(0x30, Data([0x02,0x01,0x1A]) + algorithm + name + validity + name + subjectPublicKeyInfo)
        // Certificate issuance is test setup, before the measured signing use
        // case. Certificate trust and suitability are not asserted by this test.
        let certificateSignature = try XCTUnwrap(SecKeyCreateSignature(
            generatedKey, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, nil) as Data?)
        let der = Self.der(0x30, tbs + algorithm + Self.der(0x03, Data([0]) + certificateSignature))
        certificate = Certificate(metadata: try AppleCertificateParser().parseCertificate(derData: der), derData: der)
    }

    func listIdentities() throws -> [SigningIdentity] { [] }
    func identity(withID id: SigningIdentityIdentifier) throws -> SigningIdentity? { nil }
    func signingCertificate(for id: SigningIdentityIdentifier) throws -> Certificate { certificate }
    func signingCapability(for id: SigningIdentityIdentifier) throws -> any SigningCapability { self }
    func sign(data: Data, algorithm: SigningAlgorithm) throws -> Data {
        calls += 1
        try algorithm.validate(data: data, keyAlgorithm: .rsa)
        guard algorithm == .rsaPKCS1SHA256Digest,
              let signature = SecKeyCreateSignature(key, .rsaSignatureDigestPKCS1v15SHA256,
                                                    data as CFData, nil) as Data? else {
            throw ZynSignError.crypto(.signingFailure)
        }
        return signature
    }

    /// Tiny test-certificate assembler; no production parsing or signing policy.
    private static func der(_ tag: UInt8, _ content: Data) -> Data {
        precondition(content.count < 65536)
        let count = content.count
        let length: [UInt8]
        if count < 128 { length = [UInt8(count)] }
        else if count < 256 { length = [0x81, UInt8(count)] }
        else { length = [0x82, UInt8(count >> 8), UInt8(count & 255)] }
        return Data([tag] + length) + content
    }
}
#endif
