import XCTest
@testable import ZynSign

final class CryptographicSigningUseCaseTests: XCTestCase {

    private var store: InMemorySigningIdentityStore!
    private var capability: RecordingSigningCapability!
    private var identity: SigningIdentity!
    private var useCase: CryptographicSigningUseCase!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = InMemorySigningIdentityStore()
        capability = RecordingSigningCapability()
        identity = try Self.makeIdentity()
        let id = identity.id
        capability.identityID = id
        capability.publicKeyAlgorithm = .rsa
        store.entries[id] = .init(identity: identity, capability: capability)
        useCase = CryptographicSigningUseCase(identityStore: store)
    }

    private static func makeIdentity() throws -> SigningIdentity {
        let metadata = try AppleCertificateParser().parseCertificate(derData: CertificateFixtures.validDER)
        return SigningIdentity(
            certificate: metadata,
            keyAvailability: .available,
            association: .matched,
            capabilityState: .ready
        )
    }

    // MARK: - Successful signing

    func testSignsThroughTheStoreCapabilityAndAttachesTheCertificateReference() throws {
        let message = Data("synthetic use-case message".utf8)
        let request = SigningRequest(
            identityID: identity.id,
            algorithm: .rsaPKCS1SHA256Message,
            input: .message(message)
        )

        let result = try useCase.sign(request)

        XCTAssertEqual(result.signature, capability.signatureBytes)
        XCTAssertEqual(result.algorithm, .rsaPKCS1SHA256Message)
        XCTAssertEqual(result.digestAlgorithm, .sha256)
        XCTAssertEqual(result.identityID, identity.id)
        XCTAssertEqual(result.publicKeyAlgorithm, .rsa)
        // The application layer attached the certificate reference the
        // engine could not know.
        XCTAssertEqual(result.certificateFingerprint, identity.certificate.sha256Fingerprint)
        XCTAssertNil(result.signedDigest)

        // The store was asked once for the capability and once for the
        // metadata — and for nothing else.
        XCTAssertEqual(store.capabilityRequests, [identity.id])
        XCTAssertEqual(store.metadataRequests, [identity.id])
        // The capability signed exactly once, with the message.
        XCTAssertEqual(capability.signCallCount, 1)
        XCTAssertEqual(capability.signedCalls.first?.data, message)
        XCTAssertEqual(capability.signedCalls.first?.algorithm, .rsaPKCS1SHA256Message)
    }

    func testDigestRequestSignsTheDigestBytes() throws {
        let digest = Digest(algorithm: .sha256, bytes: Data(repeating: 0x77, count: 32))!
        let request = SigningRequest(
            identityID: identity.id,
            algorithm: .rsaPKCS1SHA256Digest,
            input: .digest(digest)
        )

        let result = try useCase.sign(request)

        XCTAssertEqual(result.signedDigest, digest)
        XCTAssertEqual(capability.signedCalls.first?.data, digest.bytes)
        XCTAssertEqual(capability.signedCalls.first?.algorithm, .rsaPKCS1SHA256Digest)
    }

    // MARK: - Request validation happens before the store is touched

    func testIncoherentRequestFailsBeforeTheStoreIsConsulted() {
        let request = SigningRequest(
            identityID: identity.id,
            algorithm: .rsaPKCS1SHA256Digest,
            input: .message(Data("a message, not a digest".utf8))
        )
        XCTAssertThrowsError(try useCase.sign(request)) { error in
            XCTAssertEqual((error as? ZynSignError)?.cryptoFailure, .invalidInput)
        }
        XCTAssertEqual(store.capabilityRequests, [])
        XCTAssertEqual(store.metadataRequests, [])
        XCTAssertEqual(capability.signCallCount, 0)
    }

    // MARK: - Identity boundary failures keep their own vocabulary

    func testUnknownIdentityThrowsTheIdentityBoundaryReason() {
        let request = SigningRequest(
            identityID: SigningIdentityIdentifier(),
            algorithm: .rsaPKCS1SHA256Message,
            input: .message(Data("x".utf8))
        )
        XCTAssertThrowsError(try useCase.sign(request)) { error in
            XCTAssertEqual((error as? ZynSignError)?.identityFailure, .identityNotFound)
        }
    }

    func testUnavailableKeyThrowsTheIdentityBoundaryReason() {
        store.capabilityFailure = ZynSignError.identity(.privateKeyUnavailable)
        let request = SigningRequest(
            identityID: identity.id,
            algorithm: .rsaPKCS1SHA256Message,
            input: .message(Data("x".utf8))
        )
        XCTAssertThrowsError(try useCase.sign(request)) { error in
            XCTAssertEqual((error as? ZynSignError)?.identityFailure, .privateKeyUnavailable)
        }
        XCTAssertEqual(capability.signCallCount, 0)
    }

    func testProtectionFailureFromTheCapabilityKeepsItsReason() {
        capability.signingError = ZynSignError.identity(.platformRestriction)
        let request = SigningRequest(
            identityID: identity.id,
            algorithm: .rsaPKCS1SHA256Message,
            input: .message(Data("x".utf8))
        )
        XCTAssertThrowsError(try useCase.sign(request)) { error in
            XCTAssertEqual((error as? ZynSignError)?.identityFailure, .platformRestriction)
        }
    }

    // MARK: - Reference attachment is best-effort

    func testUnreadableMetadataDoesNotFailACompletedSignature() throws {
        store.metadataFailure = NSError(domain: "store", code: 1)
        let request = SigningRequest(
            identityID: identity.id,
            algorithm: .rsaPKCS1SHA256Message,
            input: .message(Data("x".utf8))
        )

        let result = try useCase.sign(request)

        // The signature exists; the reference is simply absent.
        XCTAssertEqual(result.signature, capability.signatureBytes)
        XCTAssertNil(result.certificateFingerprint)
    }

    // MARK: - Engine substitution

    func testEngineIsSubstitutableThroughThePort() throws {
        // A recording engine proves the use case signs through the port,
        // not through a concrete implementation.
        final class StubEngine: CryptographicSigningEngine {
            var requests: [SigningRequest] = []
            func sign(_ request: SigningRequest, capability: any SigningCapability) throws -> SigningResult {
                requests.append(request)
                _ = capability
                let signature = Data("stub".utf8)
                return SigningResult(
                    signature: signature,
                    algorithm: request.algorithm,
                    digestAlgorithm: request.algorithm.digestAlgorithm,
                    identityID: request.identityID,
                    publicKeyAlgorithm: capability.publicKeyAlgorithm
                )
            }
        }
        let engine = StubEngine()
        let useCase = CryptographicSigningUseCase(identityStore: store, engine: engine)
        let request = SigningRequest(
            identityID: identity.id,
            algorithm: .rsaPKCS1SHA256Message,
            input: .message(Data("x".utf8))
        )

        let result = try useCase.sign(request)

        XCTAssertEqual(engine.requests, [request])
        XCTAssertEqual(result.signature, Data("stub".utf8))
    }
}
