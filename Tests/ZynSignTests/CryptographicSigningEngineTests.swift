import XCTest
@testable import ZynSign

final class CryptographicSigningEngineTests: XCTestCase {

    private let engine = CapabilitySigningEngine()

    private func rsaCapability(
        id: SigningIdentityIdentifier = SigningIdentityIdentifier(),
        available: Bool = true,
        supported: Set<SigningAlgorithm> = Set(SigningAlgorithm.allCases)
    ) -> RecordingSigningCapability {
        let capability = RecordingSigningCapability()
        capability.identityID = id
        capability.publicKeyAlgorithm = .rsa
        capability.isAvailable = available
        capability.supportedAlgorithms = supported
        return capability
    }

    // MARK: - Valid operations

    func testSignsAMessageThroughTheCapability() throws {
        let capability = rsaCapability()
        let message = Data("synthetic signing message".utf8)
        let request = SigningRequest(
            identityID: capability.identityID,
            algorithm: .rsaPKCS1SHA256Message,
            input: .message(message),
            context: SigningOperationContext(label: "test")
        )

        let result = try engine.sign(request, capability: capability)

        // The signature is the capability's output, nothing else.
        XCTAssertEqual(result.signature, capability.signatureBytes)
        XCTAssertEqual(result.algorithm, .rsaPKCS1SHA256Message)
        XCTAssertEqual(result.digestAlgorithm, .sha256)
        XCTAssertEqual(result.identityID, capability.identityID)
        XCTAssertEqual(result.publicKeyAlgorithm, .rsa)
        XCTAssertNil(result.signedDigest)
        XCTAssertNil(result.certificateFingerprint)
        XCTAssertEqual(result.context?.label, "test")

        // The capability received exactly the message, under the operation.
        XCTAssertEqual(capability.signCallCount, 1)
        XCTAssertEqual(capability.signedCalls.first?.data, message)
        XCTAssertEqual(capability.signedCalls.first?.algorithm, .rsaPKCS1SHA256Message)
    }

    func testSignsADigestThroughTheCapability() throws {
        let capability = rsaCapability()
        let digest = Digest(algorithm: .sha256, bytes: Data(repeating: 0x42, count: 32))!
        let request = SigningRequest(
            identityID: capability.identityID,
            algorithm: .ecdsaX962SHA256Digest,
            input: .digest(digest)
        )
        // The request names an EC operation; the capability must match.
        capability.publicKeyAlgorithm = .ec

        let result = try engine.sign(request, capability: capability)

        XCTAssertEqual(result.signedDigest, digest)
        XCTAssertEqual(result.algorithm, .ecdsaX962SHA256Digest)
        XCTAssertEqual(result.publicKeyAlgorithm, .ec)
        // The capability received the digest bytes, not the Digest wrapper.
        XCTAssertEqual(capability.signedCalls.first?.data, digest.bytes)
        XCTAssertEqual(capability.signedCalls.first?.algorithm, .ecdsaX962SHA256Digest)
    }

    func testRepeatedSigningIsDeterministicThroughTheEngine() throws {
        let capability = rsaCapability()
        let request = SigningRequest(
            identityID: capability.identityID,
            algorithm: .rsaPKCS1SHA256Message,
            input: .message(Data("same".utf8))
        )
        let first = try engine.sign(request, capability: capability)
        let second = try engine.sign(request, capability: capability)
        XCTAssertEqual(first, second)
    }

    // MARK: - Incompatible key and algorithm combinations

    func testRSARequestAgainstAnECCapabilityIsIncompatible() {
        let capability = rsaCapability()
        capability.publicKeyAlgorithm = .ec
        let request = SigningRequest(
            identityID: capability.identityID,
            algorithm: .rsaPKCS1SHA256Message,
            input: .message(Data("x".utf8))
        )
        XCTAssertThrowsError(try engine.sign(request, capability: capability)) { error in
            XCTAssertEqual((error as? ZynSignError)?.cryptoFailure, .incompatibleKey)
        }
        XCTAssertEqual(capability.signCallCount, 0)
    }

    func testECRequestAgainstAnRSACapabilityIsIncompatible() {
        let capability = rsaCapability()
        let request = SigningRequest(
            identityID: capability.identityID,
            algorithm: .ecdsaX962SHA256Message,
            input: .message(Data("x".utf8))
        )
        XCTAssertThrowsError(try engine.sign(request, capability: capability)) { error in
            XCTAssertEqual((error as? ZynSignError)?.cryptoFailure, .incompatibleKey)
        }
    }

    func testRequestAgainstAnUnknownKeyFamilyIsIncompatible() {
        let capability = rsaCapability()
        capability.publicKeyAlgorithm = .unknown("1.3.101.112")
        let request = SigningRequest(
            identityID: capability.identityID,
            algorithm: .rsaPKCS1SHA256Message,
            input: .message(Data("x".utf8))
        )
        XCTAssertThrowsError(try engine.sign(request, capability: capability)) { error in
            XCTAssertEqual((error as? ZynSignError)?.cryptoFailure, .incompatibleKey)
        }
    }

    func testOperationTheCapabilityDoesNotSupportIsRejectedNotSubstituted() {
        let capability = rsaCapability(
            supported: [.rsaPKCS1SHA256Message]
        )
        let request = SigningRequest(
            identityID: capability.identityID,
            algorithm: .rsaPKCS1SHA256Digest,
            input: .digest(Digest(algorithm: .sha256, bytes: Data(repeating: 0, count: 32))!)
        )
        XCTAssertThrowsError(try engine.sign(request, capability: capability)) { error in
            XCTAssertEqual((error as? ZynSignError)?.cryptoFailure, .unsupportedAlgorithm)
        }
        // No other operation was attempted in its place.
        XCTAssertEqual(capability.signCallCount, 0)
    }

    // MARK: - Capability state

    func testUnavailableCapabilityIsRejectedWithoutAskingForASignature() {
        let capability = rsaCapability(available: false)
        let request = SigningRequest(
            identityID: capability.identityID,
            algorithm: .rsaPKCS1SHA256Message,
            input: .message(Data("x".utf8))
        )
        XCTAssertThrowsError(try engine.sign(request, capability: capability)) { error in
            XCTAssertEqual((error as? ZynSignError)?.cryptoFailure, .capabilityUnavailable)
        }
        XCTAssertEqual(capability.signCallCount, 0)
    }

    // MARK: - Invalid input

    func testIncoherentRequestFailsBeforeTheCapabilityIsConsulted() {
        let capability = rsaCapability()
        let request = SigningRequest(
            identityID: capability.identityID,
            algorithm: .rsaPKCS1SHA256Digest,
            input: .message(Data("not a digest".utf8))
        )
        XCTAssertThrowsError(try engine.sign(request, capability: capability)) { error in
            XCTAssertEqual((error as? ZynSignError)?.cryptoFailure, .invalidInput)
        }
        XCTAssertEqual(capability.signCallCount, 0)
    }

    // MARK: - Capability failures

    func testStructuredCapabilityFailureKeepsItsOwnVocabulary() {
        let capability = rsaCapability()
        capability.signingError = ZynSignError.identity(.signingFailure)
        let request = SigningRequest(
            identityID: capability.identityID,
            algorithm: .rsaPKCS1SHA256Message,
            input: .message(Data("x".utf8))
        )
        XCTAssertThrowsError(try engine.sign(request, capability: capability)) { error in
            // The protected-key failure is the identity boundary's fact and
            // keeps its own reason when it crosses the engine.
            XCTAssertEqual((error as? ZynSignError)?.identityFailure, .signingFailure)
            XCTAssertNil((error as? ZynSignError)?.cryptoFailure)
        }
    }

    func testForeignCapabilityFailureIsReducedWithoutRetainingItsText() {
        let capability = rsaCapability()
        capability.signingError = NSError(
            domain: "private provider",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "private key bytes must never appear here"]
        )
        let request = SigningRequest(
            identityID: capability.identityID,
            algorithm: .rsaPKCS1SHA256Message,
            input: .message(Data("x".utf8))
        )
        XCTAssertThrowsError(try engine.sign(request, capability: capability)) { error in
            let zynSignError = try XCTUnwrap(error as? ZynSignError)
            XCTAssertEqual(zynSignError.cryptoFailure, .signingFailure)
            // The foreign description is not carried anywhere.
            XCTAssertFalse(zynSignError.userMessage.contains("private key bytes"))
            XCTAssertFalse(zynSignError.debugDescription.contains("private key bytes"))
            XCTAssertNil(zynSignError.underlyingError)
        }
    }

    func testAuthorizationFailureFromTheCapabilityKeepsItsVocabulary() {
        let capability = rsaCapability()
        capability.signingError = ZynSignError.identity(.authorizationFailure)
        let request = SigningRequest(
            identityID: capability.identityID,
            algorithm: .rsaPKCS1SHA256Message,
            input: .message(Data("x".utf8))
        )
        XCTAssertThrowsError(try engine.sign(request, capability: capability)) { error in
            XCTAssertEqual((error as? ZynSignError)?.identityFailure, .authorizationFailure)
        }
    }

    // MARK: - Output checks

    func testEmptySignatureFromTheCapabilityIsMalformed() {
        let capability = rsaCapability()
        capability.signatureBytes = Data()
        let request = SigningRequest(
            identityID: capability.identityID,
            algorithm: .rsaPKCS1SHA256Message,
            input: .message(Data("x".utf8))
        )
        XCTAssertThrowsError(try engine.sign(request, capability: capability)) { error in
            XCTAssertEqual((error as? ZynSignError)?.cryptoFailure, .malformedSignature)
        }
    }
}
