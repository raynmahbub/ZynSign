import XCTest
@testable import ZynSign

/// Boundary assertions for the cryptographic foundation: the types that
/// move data toward and away from the signing capability carry no private
/// key material, and the results they produce expose nothing but the
/// signature and its facts.
final class CryptographicBoundaryTests: XCTestCase {

    // MARK: - The request carries no key material

    func testSigningRequestCarriesNoKeyMaterial() throws {
        let request = SigningRequest(
            identityID: SigningIdentityIdentifier(),
            algorithm: .rsaPKCS1SHA256Message,
            input: .message(Data("synthetic".utf8)),
            context: SigningOperationContext(label: "test")
        )
        assertNoKeyMaterialFields(reflecting: request)
        // The request has exactly four fields: the identity reference, the
        // operation, the data being signed, and the context. There is no
        // field a key, a password, or a locator could occupy.
        let labels = Mirror(reflecting: request).children.compactMap(\.label)
        XCTAssertEqual(Set(labels), ["identityID", "algorithm", "input", "context"])
        // And the data it carries is exactly the data being signed.
        switch request.input {
        case .message(let data):
            XCTAssertEqual(data, Data("synthetic".utf8))
        case .digest:
            XCTFail("Expected message input")
        }
    }

    // MARK: - The result carries the signature and nothing sensitive

    func testSigningResultCarriesNoKeyMaterial() throws {
        let result = SigningResult(
            signature: Data("signature-bytes-marker".utf8),
            algorithm: .rsaPKCS1SHA256Digest,
            digestAlgorithm: .sha256,
            identityID: SigningIdentityIdentifier(),
            publicKeyAlgorithm: .rsa,
            certificateFingerprint: CertificateFingerprint(hexDigest: CertificateFixtures.validFingerprintHex),
            signedDigest: Digest(algorithm: .sha256, bytes: Data(repeating: 0, count: 32)),
            context: SigningOperationContext(label: "test")
        )
        assertNoKeyMaterialFields(reflecting: result)
    }

    func testSigningResultDiagnosticsNeverRenderTheSignatureOrData() throws {
        let marker = "signature-bytes-marker"
        let result = SigningResult(
            signature: Data(marker.utf8),
            algorithm: .ecdsaX962SHA256Message,
            digestAlgorithm: .sha256,
            identityID: SigningIdentityIdentifier(),
            publicKeyAlgorithm: .ec,
            context: SigningOperationContext(label: "codeDirectory")
        )

        let diagnostic = result.diagnosticDescription
        // Operation facts and lengths only.
        XCTAssertFalse(diagnostic.contains(marker))
        XCTAssertTrue(diagnostic.contains("ecdsaX962SHA256Message"))
        XCTAssertTrue(diagnostic.contains("sha256"))
        XCTAssertTrue(diagnostic.contains("codeDirectory"))
        XCTAssertTrue(diagnostic.contains("signatureBytes(\(marker.utf8.count))"))
        // The identity reference is an opaque UUID, which is safe to show.
        XCTAssertFalse(diagnostic.contains("private"))
    }

    // MARK: - The engine boundary is signature-only

    func testEngineAsksTheCapabilityOnlyForSignatures() throws {
        let engine = CapabilitySigningEngine()
        let capability = RecordingSigningCapability()
        let message = Data("engine boundary message".utf8)
        let request = SigningRequest(
            identityID: capability.identityID,
            algorithm: .ecdsaX962SHA256Message,
            input: .message(message)
        )
        capability.publicKeyAlgorithm = .ec

        let result = try engine.sign(request, capability: capability)

        // Exactly one request crossed the boundary: data plus an explicit
        // algorithm. Nothing else the capability exposes was needed.
        XCTAssertEqual(capability.signCallCount, 1)
        XCTAssertEqual(capability.signedCalls.first?.data, message)
        XCTAssertEqual(capability.signedCalls.first?.algorithm, .ecdsaX962SHA256Message)
        // And only signature bytes came back into the result.
        XCTAssertEqual(result.signature, capability.signatureBytes)
    }

    func testDigestInputCrossesTheBoundaryAsBytes() throws {
        let engine = CapabilitySigningEngine()
        let capability = RecordingSigningCapability()
        capability.publicKeyAlgorithm = .ec
        let digest = Digest(algorithm: .sha256, bytes: Data(repeating: 0x3C, count: 32))!
        let request = SigningRequest(
            identityID: capability.identityID,
            algorithm: .ecdsaX962SHA256Digest,
            input: .digest(digest)
        )

        _ = try engine.sign(request, capability: capability)

        XCTAssertEqual(capability.signedCalls.first?.data, digest.bytes)
        XCTAssertEqual(capability.signedCalls.first?.data.count, 32)
    }

    // MARK: - The verification boundary is public-material-only

    func testVerificationTakesOnlyPublicMaterial() throws {
        let verifier = RecordingCryptographicSignatureVerifier()
        let certificate = try CMSVerificationTestSupport.certificate(CertificateFixtures.ecDER)

        _ = verifier.verify(
            signature: Data(repeating: 0x01, count: 64),
            message: .message(Data("public bytes".utf8)),
            algorithm: .ecdsaX962SHA256Message,
            certificate: certificate
        )

        // The recorded call contains the signature, the bytes, the
        // operation, and the certificate reference — public material only.
        // No key, no capability, no locator.
        XCTAssertEqual(verifier.lastCall?.signature, Data(repeating: 0x01, count: 64))
        XCTAssertEqual(verifier.lastCall?.input, .message(Data("public bytes".utf8)))
        XCTAssertEqual(verifier.lastCall?.algorithm, .ecdsaX962SHA256Message)
        XCTAssertEqual(verifier.lastCall?.certificateFingerprint, certificate.fingerprint)
    }

    // MARK: - Support

    private func assertNoKeyMaterialFields(reflecting value: Any) {
        for child in Mirror(reflecting: value).children {
            let label = child.label?.lowercased() ?? ""
            XCTAssertFalse(label.contains("privatekey"), "\(type(of: value)) field '\(label)' suggests key material")
            XCTAssertFalse(label.contains("private_key"), "\(type(of: value)) field '\(label)' suggests key material")
            XCTAssertFalse(label.contains("keymaterial"), "\(type(of: value)) field '\(label)' suggests key material")
            XCTAssertFalse(label.contains("password"), "\(type(of: value)) field '\(label)' suggests a credential")
            XCTAssertFalse(label.contains("secret"), "\(type(of: value)) field '\(label)' suggests a secret")
        }
    }
}
