#if os(iOS)
import XCTest
import Security
@testable import ZynSign

/// Opt-in tests requiring a signed iOS test host and disposable Keychain state.
/// No private key is exported, embedded in a fixture, or written to a file.
final class KeychainIdentityIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["ZYNSIGN_RUN_KEYCHAIN_TESTS"] == "1" else {
            throw XCTSkip("Set ZYNSIGN_RUN_KEYCHAIN_TESTS=1 in a signed iOS test host to run Keychain integration tests.")
        }
    }

    func testRegistryPersistenceDuplicatesRemovalAndProtection() throws {
        let service = "ZynSign.IdentityTests." + UUID().uuidString
        let registry = KeychainIdentityRegistry(service: service)
        let record = try SigningIdentityFixtures.record()
        let id = try record.id
        addTeardownBlock { try registry.remove(id) }
        try registry.insert(record)
        let restored = KeychainIdentityRegistry(service: service)
        XCTAssertEqual(try restored.records().map { try $0.id }, [id])
        XCTAssertThrowsError(try restored.insert(record)) { error in
            XCTAssertEqual((error as? ZynSignError)?.identityFailure, .duplicateIdentity)
        }
        // records() checks WhenUnlockedThisDeviceOnly; its query excludes sync.
        try restored.remove(id)
        XCTAssertTrue(try registry.records().isEmpty)
    }

    func testProtectedRSAAndECKeyResolutionAssociationAndSignatureVerification() throws {
        for isRSA in [true, false] {
            let (key, reference, deleteQuery) = try makeStoredKey(isRSA: isRSA)
            let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
            let der = try certificateContaining(publicKey: publicKey, isRSA: isRSA)
            let registry = KeychainIdentityRegistry(service: "ZynSign.IdentityTests." + UUID().uuidString)
            let store = SecureIdentityStore(registry: registry, resolver: AppleSigningKeyResolver())
            // This must fail, not skip or weaken policy, if the OS does not
            // honor/report the requested non-extractability and accessibility.
            let id = try store.register(certificateDER: der, keyReference: reference)
            addTeardownBlock { try registry.remove(id) }
            let capability = try store.signingCapability(for: id)
            XCTAssertEqual(try store.identity(withID: id)?.association, .matched)
            let data = Data("synthetic signing message".utf8)
            let algorithm: SigningAlgorithm = isRSA ? .rsaPKCS1SHA256Message : .ecdsaX962SHA256Message
            let verification: SecKeyAlgorithm = isRSA ? .rsaSignatureMessagePKCS1v15SHA256 : .ecdsaSignatureMessageX962SHA256
            let signature = try capability.sign(data: data, algorithm: algorithm)
            XCTAssertTrue(SecKeyVerifySignature(publicKey, verification, data as CFData, signature as CFData, nil))
            let digest = Data(CertificateDigest.sha256(data))
            let digestAlgorithm: SigningAlgorithm = isRSA ? .rsaPKCS1SHA256Digest : .ecdsaX962SHA256Digest
            let digestVerification: SecKeyAlgorithm = isRSA ? .rsaSignatureDigestPKCS1v15SHA256 : .ecdsaSignatureDigestX962SHA256
            let digestSignature = try capability.sign(data: digest, algorithm: digestAlgorithm)
            XCTAssertTrue(SecKeyVerifySignature(publicKey, digestVerification, digest as CFData, digestSignature as CFData, nil))
            XCTAssertFalse(SecKeyVerifySignature(publicKey, verification, Data("changed".utf8) as CFData, signature as CFData, nil))

            XCTAssertEqual(SecItemDelete(deleteQuery as CFDictionary), errSecSuccess)
            XCTAssertFalse(capability.isAvailable)
            XCTAssertEqual(try store.identity(withID: id)?.keyAvailability, .unavailable)
            XCTAssertThrowsError(try capability.sign(data: data, algorithm: algorithm)) { error in
                XCTAssertEqual((error as? ZynSignError)?.identityFailure, .privateKeyUnavailable)
            }
        }
    }

    func testMismatchedKeyCannotBeRegistered() throws {
        let (_, reference, _) = try makeStoredKey(isRSA: false)
        let store = SecureIdentityStore(registry: MemoryIdentityRegistry(), resolver: AppleSigningKeyResolver())
        // Existing fixture's public key is unrelated to this runtime key.
        XCTAssertThrowsError(try store.register(certificateDER: CertificateFixtures.ecDER, keyReference: reference)) { error in
            XCTAssertEqual((error as? ZynSignError)?.identityFailure, .certificateKeyMismatch)
        }
    }

    func testPublicKeyComparisonRejectsPrivateHandlesAndUnsupportedCharacteristics() throws {
        let (key, _, _) = try makeStoredKey(isRSA: false)
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let info = PublicKeyInfo(algorithm: .ec, keySizeInBits: 256)
        XCTAssertNoThrow(try ApplePublicKeyAssociation.validate(certificatePublicKey: publicKey,
            signingPublicKey: publicKey, expected: info))
        XCTAssertThrowsError(try ApplePublicKeyAssociation.validate(certificatePublicKey: publicKey,
            signingPublicKey: key, expected: info)) { error in
            XCTAssertEqual((error as? ZynSignError)?.identityFailure, .unsupportedKeyType)
        }
        XCTAssertThrowsError(try ApplePublicKeyAssociation.validate(certificatePublicKey: publicKey,
            signingPublicKey: publicKey, expected: PublicKeyInfo(algorithm: .unknown("test"))))
        XCTAssertThrowsError(try ApplePublicKeyAssociation.validate(certificatePublicKey: publicKey,
            signingPublicKey: publicKey, expected: PublicKeyInfo(algorithm: .rsa, keySizeInBits: 1024)))
    }

    private func makeStoredKey(isRSA: Bool) throws -> (SecKey, Data, [String: Any]) {
        let tag = Data(("ZynSign.IdentityTests." + UUID().uuidString).utf8)
        let keyType = isRSA ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom
        let query: [String: Any] = [kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag, kSecAttrKeyType as String: keyType,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        addTeardownBlock {
            let status = SecItemDelete(query as CFDictionary)
            XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound, "Disposable key cleanup failed.")
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: keyType,
            kSecAttrKeySizeInBits as String: isRSA ? 2048 : 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                kSecAttrSynchronizable as String: false,
                kSecAttrIsExtractable as String: false
            ]
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil) else {
            throw ZynSignError.identity(.platformRestriction)
        }
        var lookup = query
        lookup[kSecReturnPersistentRef as String] = true
        var result: CFTypeRef?
        try IdentityKeychainAccess.check(SecItemCopyMatching(lookup as CFDictionary, &result))
        let reference = try XCTUnwrap(result as? Data)
        return (key, reference, query)
    }

    /// Replace only public SPKI bytes in a synthetic public certificate.
    /// Its issuer signature is intentionally invalid after replacement. These
    /// tests establish key association, NOT certificate validity or trust.
    private func certificateContaining(publicKey: SecKey, isRSA: Bool) throws -> Data {
        var der = isRSA ? CertificateFixtures.validDER : CertificateFixtures.ecDER
        let original = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        let originalPublicKey = try XCTUnwrap(SecCertificateCopyKey(original))
        let oldBytes = try XCTUnwrap(SecKeyCopyExternalRepresentation(originalPublicKey, nil) as Data?)
        let newBytes = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        XCTAssertEqual(oldBytes.count, newBytes.count)
        let range = try XCTUnwrap(der.range(of: oldBytes))
        der.replaceSubrange(range, with: newBytes)
        return der
    }
}
#endif
