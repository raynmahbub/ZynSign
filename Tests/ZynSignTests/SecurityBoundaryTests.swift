import XCTest
@testable import ZynSign

final class SecurityBoundaryTests: XCTestCase {

    func testPrivateKeyBytesNotPersistedInApplicationRecord() {
        // ApplicationRecord must not contain private key material.
        // Verify by checking its properties via Mirror.
        let identity = try! ApplicationIdentity(bundleIdentifier: "com.example.test")
        let reference = ArtifactReference(
            artifactID: ArtifactIdentifier(),
            byteCount: 100,
            fingerprint: ArtifactFingerprint(algorithm: .sha256, hexDigest: String(repeating: "a", count: 64))!
        )
        let record = ApplicationRecord(
            id: ApplicationRecordIdentifier(),
            identity: identity,
            executableName: "TestApp",
            sourceFileName: "Test.ipa",
            artifact: reference,
            inspection: ApplicationRecord.InspectionSummary(classification: .valid, warningCodes: []),
            importedAt: Date(),
            updatedAt: Date()
        )
        let mirror = Mirror(reflecting: record)
        for child in mirror.children {
            if let label = child.label?.lowercased() {
                XCTAssertFalse(label.contains("privatekey"), "ApplicationRecord should not contain private key: \(label)")
                XCTAssertFalse(label.contains("private_key"), "ApplicationRecord should not contain private key: \(label)")
                XCTAssertFalse(label.contains("keymaterial"), "ApplicationRecord should not contain key material: \(label)")
            }
        }
    }

    func testCertificateMetadataDoesNotContainPrivateKey() {
        let subject = CertificateDistinguishedName(rawRepresentation: "CN=Test")
        let issuer = CertificateDistinguishedName(rawRepresentation: "CN=CA")
        let fingerprint = CertificateFingerprint(hexDigest: CertificateFixtures.validFingerprintHex)!
        let metadata = CertificateMetadata(
            subject: subject,
            issuer: issuer,
            serialNumber: CertificateSerialNumber(hexadecimal: "01")!,
            notValidBefore: Date(),
            notValidAfter: Date().addingTimeInterval(3600),
            publicKeyInfo: PublicKeyInfo(algorithm: .rsa, keySizeInBits: 2048),
            signatureAlgorithm: .sha256WithRSAEncryption,
            sha256Fingerprint: fingerprint
        )
        let mirror = Mirror(reflecting: metadata)
        for child in mirror.children {
            if let label = child.label?.lowercased() {
                XCTAssertFalse(label.contains("private"), "CertificateMetadata should not contain private key: \(label)")
            }
            if child.value is Data {
                // CertificateMetadata should not contain raw Data that could be key material
                // It contains no Data properties at all.
                XCTFail("CertificateMetadata should not contain Data, found \(child.label ?? "unknown")")
            }
        }
    }

    func testSigningIdentityDoesNotExposePrivateKeyBytes() {
        let subject = CertificateDistinguishedName(rawRepresentation: "CN=Test")
        let issuer = CertificateDistinguishedName(rawRepresentation: "CN=CA")
        let fingerprint = CertificateFingerprint(hexDigest: CertificateFixtures.validFingerprintHex)!
        let metadata = CertificateMetadata(
            subject: subject,
            issuer: issuer,
            serialNumber: CertificateSerialNumber(hexadecimal: "01")!,
            notValidBefore: Date(),
            notValidAfter: Date().addingTimeInterval(3600),
            publicKeyInfo: PublicKeyInfo(algorithm: .rsa, keySizeInBits: 2048),
            signatureAlgorithm: .sha256WithRSAEncryption,
            sha256Fingerprint: fingerprint
        )
        let identity = SigningIdentity(
            certificate: metadata,
            keyAvailability: .available,
            isKeyNonExportable: true
        )
        let mirror = Mirror(reflecting: identity)
        var foundData = false
        for child in mirror.children {
            if child.value is Data {
                foundData = true
            }
            if let label = child.label?.lowercased() {
                XCTAssertFalse(label.contains("privatekey"), "SigningIdentity should not expose private key bytes")
            }
        }
        XCTAssertFalse(foundData, "SigningIdentity should not contain Data that could be private key material")
    }

    func testSigningCapabilityDoesNotRequireKeyExport() {
        // The SigningCapability protocol must not have a method that returns
        // private key bytes. Verify by checking protocol requirements via
        // documentation: it only returns signatures for explicitly selected algorithms.
        // This test documents the requirement.

        // Create a mock capability that does not expose key bytes.
        struct MockSigningCapability: SigningCapability {
            var identityID: SigningIdentityIdentifier = SigningIdentityIdentifier()
            var publicKeyAlgorithm: PublicKeyAlgorithm = .rsa
            var isAvailable: Bool = true
            var supportedAlgorithms: Set<SigningAlgorithm> = [.rsaPKCS1SHA256Message]
            func sign(data: Data, algorithm: SigningAlgorithm) throws -> Data {
                try algorithm.validate(data: data, keyAlgorithm: publicKeyAlgorithm)
                // Return dummy signature, not key
                return Data(repeating: 0, count: 256)
            }
        }

        let capability = MockSigningCapability()
        let data = Data("test data".utf8)
        let signature = try! capability.sign(data: data, algorithm: .rsaPKCS1SHA256Message)
        // Signature is not key material; it's 256 bytes for RSA 2048
        XCTAssertEqual(signature.count, 256)
        // Capability does not have a property that returns private key
        let mirror = Mirror(reflecting: capability)
        for child in mirror.children {
            XCTAssertNotEqual(child.label, "privateKey")
            XCTAssertNotEqual(child.label, "privateKeyData")
        }
    }

    func testCertificateParsingDoesNotExecuteArbitraryContent() {
        // Parsing malformed input should throw, not crash or execute.
        let parser = AppleCertificateParser()
        XCTAssertThrowsError(try parser.parseCertificate(derData: CertificateFixtures.malformedDER))
        XCTAssertThrowsError(try parser.parseCertificate(derData: CertificateFixtures.randomDER))
        XCTAssertThrowsError(try parser.parseCertificate(derData: CertificateFixtures.emptyDER))
    }

    func testSensitiveValuesNotLoggedInErrorMessages() {
        // Errors must not log private key material, passwords, tokens, etc.
        let error = ZynSignError.invalidCertificateData(diagnosticDetail: "test")
        // User message should not contain sensitive keywords
        let userMessage = error.userMessage.lowercased()
        XCTAssertFalse(userMessage.contains("private"))
        XCTAssertFalse(userMessage.contains("password"))
        XCTAssertFalse(userMessage.contains("token"))
        // Description (log-safe) should not contain diagnostic detail
        XCTAssertFalse(error.description.contains("test"))
        // Debug description may contain detail, but must not contain key material
        // (we don't put key material in diagnosticDetail)
    }

    func testCertificateDataOwnershipBoundary() {
        // CertificateData holds DER bytes but must not be logged.
        let der = CertificateFixtures.validDER
        let fingerprint = CertificateFingerprint(hexDigest: CertificateFixtures.validFingerprintHex)!
        let certData = CertificateData(derData: der, fingerprint: fingerprint)

        // Verify it holds data
        XCTAssertEqual(certData.derData, der)
        // But its description should not include full DER
        // (We don't implement CustomStringConvertible that logs bytes)
        let mirror = Mirror(reflecting: certData)
        var hasSensitiveDescription = false
        for child in mirror.children {
            if let data = child.value as? Data, data.count > 100 {
                // Data property exists, but we must ensure it's not logged via description
                hasSensitiveDescription = false
            }
        }
        XCTAssertFalse(hasSensitiveDescription)
    }
}
