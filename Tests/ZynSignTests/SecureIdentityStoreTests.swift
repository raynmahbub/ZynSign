import XCTest
@testable import ZynSign

final class SecureIdentityStoreTests: XCTestCase {
    private let registry = MemoryIdentityRegistry()
    private let resolver = TestIdentityResolver()
    private var store: SecureIdentityStore {
        SecureIdentityStore(registry: registry, resolver: resolver)
    }

    private func register(_ der: Data = CertificateFixtures.validDER) throws -> SigningIdentityIdentifier {
        try store.register(certificateDER: der, keyReference: SigningIdentityFixtures.reference)
    }

    private func expect(_ reason: SigningIdentityFailure, file: StaticString = #filePath, line: UInt = #line,
                        _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual((error as? ZynSignError)?.identityFailure, reason, file: file, line: line)
        }
    }

    func testStableIdentityAcrossStoreReconstructionAndMetadataProjection() throws {
        let id = try register()
        let first = try XCTUnwrap(store.identity(withID: id))
        let reconstructed = SecureIdentityStore(registry: registry, resolver: resolver)
        XCTAssertEqual(try reconstructed.identity(withID: id), first)
        XCTAssertEqual(try reconstructed.metadata(for: id), SigningIdentityMetadata(identity: first))
        XCTAssertEqual(first.association, .matched)
        XCTAssertEqual(first.storage, .keychain)
        XCTAssertEqual(first.fingerprint.hexDigest, CertificateFixtures.validFingerprintHex)
        XCTAssertTrue(first.isUsableForSigning)
        XCTAssertTrue(resolver.signedInputs.isEmpty) // Resolution never signs a challenge.
    }

    func testEnumerationUsesStableIdentifierOrder() throws {
        let first = try register()
        let second = try register(CertificateFixtures.ecDER)
        registry.stored.reverse()
        XCTAssertEqual(try store.listIdentities().map(\.id), [first, second].sorted { $0.rawValue < $1.rawValue })
    }

    func testUnknownIdentityIsNilButCapabilityIsStructuredFailure() throws {
        let id = SigningIdentityIdentifier()
        XCTAssertNil(try store.identity(withID: id))
        XCTAssertNil(try store.metadata(for: id))
        expect(.identityNotFound) { _ = try store.signingCapability(for: id) }
    }

    func testMissingCertificateAndMalformedCertificateWriteNothing() {
        expect(.certificateUnavailable) { _ = try register(Data()) }
        expect(.malformedStoredIdentity) { _ = try register(CertificateFixtures.malformedDER) }
        XCTAssertTrue(registry.stored.isEmpty)
        XCTAssertEqual(resolver.resolutions, 0)
    }

    func testRegistrationRejectsMissingMismatchedAndUnsupportedKeysBeforeWriting() {
        for reason in [SigningIdentityFailure.privateKeyUnavailable, .certificateKeyMismatch,
                       .unsupportedKeyType, .platformRestriction, .authorizationFailure] {
            resolver.failure = ZynSignError.identity(reason)
            expect(reason) { _ = try register() }
            XCTAssertTrue(registry.stored.isEmpty)
        }
    }

    func testUnavailableCapabilityCannotBeRegistered() {
        resolver.available = false
        expect(.capabilityUnavailable) { _ = try register() }
        XCTAssertTrue(registry.stored.isEmpty)
    }

    func testDuplicateRejectedWithoutReplacingStableIdentifier() throws {
        let id = try register()
        expect(.duplicateIdentity) { _ = try register() }
        XCTAssertEqual(try store.listIdentities().map(\.id), [id])
    }

    func testIdentityStatusTracksMissingMismatchAuthorizationAndRecovery() throws {
        let id = try register()
        resolver.failure = ZynSignError.identity(.privateKeyUnavailable)
        let missing = try XCTUnwrap(store.identity(withID: id))
        XCTAssertEqual(missing.keyAvailability, .unavailable)
        XCTAssertEqual(missing.association, .unknown)
        XCTAssertFalse(missing.isUsableForSigning)
        resolver.failure = ZynSignError.identity(.certificateKeyMismatch)
        XCTAssertEqual(try store.identity(withID: id)?.association, .mismatched)
        resolver.failure = ZynSignError.identity(.authorizationFailure)
        XCTAssertEqual(try store.identity(withID: id)?.capabilityState, .authorizationRequired)
        resolver.failure = ZynSignError.identity(.unsupportedKeyType)
        XCTAssertEqual(try store.identity(withID: id)?.capabilityState, .unsupported)
        resolver.failure = nil
        XCTAssertEqual(try store.identity(withID: id)?.capabilityState, .ready)
    }

    func testSigningForwardsExactInputAndExplicitAlgorithmToMock() throws {
        let id = try register()
        let capability = try store.signingCapability(for: id)
        let message = Data("test message".utf8)
        let digest = Data(repeating: 0x17, count: 32)
        XCTAssertEqual(try capability.sign(data: message, algorithm: .rsaPKCS1SHA256Message), resolver.signature)
        XCTAssertEqual(try capability.sign(data: digest, algorithm: .rsaPKCS1SHA256Digest), resolver.signature)
        XCTAssertEqual(resolver.signedInputs.map { $0.0 }, [message, digest])
        XCTAssertEqual(resolver.signedInputs.map { $0.1 }, [.rsaPKCS1SHA256Message, .rsaPKCS1SHA256Digest])
    }

    func testUnsupportedAlgorithmAndWrongDigestLengthNeverReachSigner() throws {
        let capability = try store.signingCapability(for: register())
        expect(.unsupportedSigningAlgorithm) {
            _ = try capability.sign(data: Data(), algorithm: .ecdsaX962SHA256Message)
        }
        expect(.invalidSigningInput) {
            _ = try capability.sign(data: Data(repeating: 0, count: 31), algorithm: .rsaPKCS1SHA256Digest)
        }
        resolver.supported = [.rsaPKCS1SHA256Message]
        expect(.unsupportedSigningAlgorithm) {
            _ = try capability.sign(data: Data(repeating: 0, count: 32), algorithm: .rsaPKCS1SHA256Digest)
        }
        XCTAssertTrue(resolver.signedInputs.isEmpty)
    }

    func testExistingCapabilityRechecksLockKeyLossAndSigningFailure() throws {
        let capability = try store.signingCapability(for: register())
        for reason in [SigningIdentityFailure.authorizationFailure, .privateKeyUnavailable] {
            resolver.failure = ZynSignError.identity(reason)
            XCTAssertFalse(capability.isAvailable)
            XCTAssertTrue(capability.supportedAlgorithms.isEmpty)
            expect(reason) { _ = try capability.sign(data: Data(), algorithm: .rsaPKCS1SHA256Message) }
        }
        resolver.failure = nil
        resolver.signingFailure = ZynSignError.identity(.signingFailure)
        expect(.signingFailure) { _ = try capability.sign(data: Data(), algorithm: .rsaPKCS1SHA256Message) }
    }

    func testRemovalRevokesIssuedCapabilityButDoesNotRemoveBorrowedKey() throws {
        let id = try register()
        let capability = try store.signingCapability(for: id)
        try store.removeRegistration(id)
        try store.removeRegistration(id) // Idempotent.
        XCTAssertTrue(try store.listIdentities().isEmpty)
        XCTAssertFalse(capability.isAvailable)
        expect(.identityNotFound) { _ = try capability.sign(data: Data(), algorithm: .rsaPKCS1SHA256Message) }
        XCTAssertTrue(resolver.available)
        XCTAssertNotEqual(try register(), id)
    }

    func testMalformedRegistryIsNotSilentlySkippedOrRepaired() throws {
        registry.stored = [Data("not a registry record".utf8)]
        expect(.malformedStoredIdentity) { _ = try store.listIdentities() }
        expect(.malformedStoredIdentity) { _ = try register() }
        XCTAssertEqual(registry.stored.count, 1)
    }

    func testDuplicateStoredIdentifiersFailClosed() throws {
        let id = SigningIdentityIdentifier()
        registry.stored = [try SigningIdentityFixtures.record(id: id).encoded(),
                           try SigningIdentityFixtures.record(id: id, der: CertificateFixtures.ecDER).encoded()]
        expect(.malformedStoredIdentity) { _ = try store.listIdentities() }
    }

    func testForeignErrorsAreSanitizedNotLoggedOrRetained() throws {
        let marker = "synthetic-sensitive-diagnostic"
        let foreign = NSError(domain: marker, code: 1, userInfo: [NSLocalizedDescriptionKey: marker])
        registry.failure = foreign
        do {
            _ = try store.listIdentities()
            XCTFail("Expected failure")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.identityFailure, .unexpectedSecurityFailure)
            XCTAssertNil(error.underlyingError)
            XCTAssertFalse(String(reflecting: error).contains(marker))
            XCTAssertFalse(error.userMessage.contains(marker))
        }
        registry.failure = nil
        let capability = try store.signingCapability(for: register())
        resolver.signingFailure = ZynSignError(category: .internalFailure, userMessage: marker,
            diagnosticDetail: marker, underlyingError: foreign, identityFailure: .signingFailure)
        do {
            _ = try capability.sign(data: Data(), algorithm: .rsaPKCS1SHA256Message)
            XCTFail("Expected failure")
        } catch let error as ZynSignError {
            XCTAssertEqual(error.identityFailure, .signingFailure)
            XCTAssertNil(error.underlyingError)
            XCTAssertFalse(String(reflecting: error).contains(marker))
            XCTAssertFalse(error.description.contains(marker))
        }
    }

    func testRegistryAccessFailureIsNotAnEmptyList() {
        registry.failure = ZynSignError.identity(.keychainAccessFailure)
        expect(.keychainAccessFailure) { _ = try store.listIdentities() }
    }
}
