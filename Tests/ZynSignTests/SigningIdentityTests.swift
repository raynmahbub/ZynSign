import XCTest
@testable import ZynSign

final class SigningIdentityTests: XCTestCase {

    private func makeMetadata(commonName: String = "Test Identity") -> CertificateMetadata {
        let subject = CertificateDistinguishedName(
            commonName: commonName,
            rawRepresentation: "CN=\(commonName)"
        )
        let issuer = CertificateDistinguishedName(
            commonName: "Test CA",
            rawRepresentation: "CN=Test CA"
        )
        return CertificateMetadata(
            subject: subject,
            issuer: issuer,
            serialNumber: CertificateSerialNumber(hexadecimal: "01")!,
            notValidBefore: Date(timeIntervalSince1970: 1_000_000),
            notValidAfter: Date(timeIntervalSince1970: 4_000_000_000),
            publicKeyInfo: PublicKeyInfo(algorithm: .rsa, keySizeInBits: 2048),
            signatureAlgorithm: .sha256WithRSAEncryption,
            sha256Fingerprint: CertificateFingerprint(hexDigest: CertificateFixtures.validFingerprintHex)!
        )
    }

    func testCertificateAndSigningIdentityAreDistinct() {
        // Certificate metadata can exist independently.
        let metadata = makeMetadata()
        XCTAssertNotNil(metadata)

        // Signing identity requires certificate plus key availability.
        let identity = SigningIdentity(
            certificate: metadata,
            keyAvailability: .available,
            isKeyNonExportable: true,
            association: .matched,
            capabilityState: .ready
        )
        XCTAssertEqual(identity.certificate, metadata)
        XCTAssertEqual(identity.keyAvailability, .available)
        XCTAssertTrue(identity.isUsableForSigning)

        // Certificate metadata alone does not imply signing capability.
        // This documents the required distinction: certificate != signing identity.
    }

    func testKeyAvailabilityAloneDoesNotEstablishSigningReadiness() {
        let identity = SigningIdentity(certificate: makeMetadata(), keyAvailability: .available)
        XCTAssertEqual(identity.association, .unknown)
        XCTAssertEqual(identity.capabilityState, .unknown)
        XCTAssertFalse(identity.isUsableForSigning)
        let mismatched = SigningIdentity(certificate: makeMetadata(), keyAvailability: .available,
            association: .mismatched, capabilityState: .unavailable)
        XCTAssertFalse(mismatched.isUsableForSigning)
    }

    func testSigningIdentityWithUnavailableKey() {
        let metadata = makeMetadata()
        let identity = SigningIdentity(
            certificate: metadata,
            keyAvailability: .unavailable
        )
        XCTAssertFalse(identity.isUsableForSigning)
        XCTAssertEqual(identity.keyAvailability, .unavailable)
    }

    func testSigningIdentityDisplayName() {
        let metadata = makeMetadata(commonName: "My Signing Cert")
        let identity = SigningIdentity(
            certificate: metadata,
            keyAvailability: .available
        )
        XCTAssertEqual(identity.displayName, "My Signing Cert")
    }

    func testSigningIdentityFingerprint() {
        let metadata = makeMetadata()
        let identity = SigningIdentity(
            certificate: metadata,
            keyAvailability: .available
        )
        XCTAssertEqual(identity.fingerprint.hexDigest, CertificateFixtures.validFingerprintHex)
    }

    func testSigningIdentityIdentifierIsOpaque() {
        let metadata = makeMetadata()
        let first = SigningIdentity(certificate: metadata, keyAvailability: .available)
        let second = SigningIdentity(certificate: metadata, keyAvailability: .available)
        // Identifiers are freshly minted and should differ.
        XCTAssertNotEqual(first.id, second.id)
        // Raw value is UUID, not certificate info.
        XCTAssertFalse(first.id.rawValue.contains("Test"))
    }

    func testSigningIdentityMetadata() {
        let metadata = makeMetadata()
        let identity = SigningIdentity(certificate: metadata, keyAvailability: .available)
        let identityMetadata = SigningIdentityMetadata(identity: identity)
        XCTAssertEqual(identityMetadata.id, identity.id)
        XCTAssertEqual(identityMetadata.certificate, metadata)
        XCTAssertEqual(identityMetadata.keyAvailability, .available)
    }

    func testPrivateKeyMaterialNotInIdentity() {
        // Verify that SigningIdentity does not contain private key bytes.
        // This is a compile-time check: the type has no Data property that
        // could hold key material. We verify by inspecting Mirror.
        let metadata = makeMetadata()
        let identity = SigningIdentity(certificate: metadata, keyAvailability: .available)
        let mirror = Mirror(reflecting: identity)
        for child in mirror.children {
            if let data = child.value as? Data {
                // The only Data that should appear is none; certificate
                // metadata contains no Data.
                XCTFail("SigningIdentity should not contain Data property, found \(child.label ?? "unknown") with \(data.count) bytes")
            }
        }
    }

    func testCertificateMetadataCanExistIndependently() {
        // Certificate metadata can exist without any signing identity.
        let metadata = makeMetadata()
        // No identity needed.
        XCTAssertNotNil(metadata.subject)
        XCTAssertNotNil(metadata.issuer)
        // This is valid: certificate metadata exists independently.
    }

    func testNonExportableFlag() {
        let metadata = makeMetadata()
        let nonExportable = SigningIdentity(
            certificate: metadata,
            keyAvailability: .available,
            isKeyNonExportable: true
        )
        XCTAssertEqual(nonExportable.isKeyNonExportable, true)

        let unknown = SigningIdentity(
            certificate: metadata,
            keyAvailability: .available,
            isKeyNonExportable: nil
        )
        XCTAssertNil(unknown.isKeyNonExportable)
    }
}
