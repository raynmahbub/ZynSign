import XCTest
@testable import ZynSign

final class SigningRequestTests: XCTestCase {

    // MARK: - Coherent requests

    func testMessageOperationsAcceptMessageInput() throws {
        let data = Data("synthetic message".utf8)
        for algorithm in [SigningAlgorithm.rsaPKCS1SHA256Message,
                          SigningAlgorithm.ecdsaX962SHA256Message] {
            let request = SigningRequest(
                identityID: SigningIdentityIdentifier(),
                algorithm: algorithm,
                input: .message(data)
            )
            XCTAssertNoThrow(try request.validate())
        }
    }

    func testDigestOperationsAcceptMatchingDigestInput() throws {
        let digest = Digest(algorithm: .sha256, bytes: Data(repeating: 0x23, count: 32))!
        for algorithm in [SigningAlgorithm.rsaPKCS1SHA256Digest,
                          SigningAlgorithm.ecdsaX962SHA256Digest] {
            let request = SigningRequest(
                identityID: SigningIdentityIdentifier(),
                algorithm: algorithm,
                input: .digest(digest)
            )
            XCTAssertNoThrow(try request.validate())
        }
    }

    func testEmptyMessageIsACoherentInput() throws {
        // Signing an empty message is a well-defined cryptographic
        // operation; the primitive does not invent a refusal for it.
        let request = SigningRequest(
            identityID: SigningIdentityIdentifier(),
            algorithm: .rsaPKCS1SHA256Message,
            input: .message(Data())
        )
        XCTAssertNoThrow(try request.validate())
    }

    // MARK: - Incoherent requests

    func testMessageInputOnADigestOperationIsInvalid() {
        let request = SigningRequest(
            identityID: SigningIdentityIdentifier(),
            algorithm: .rsaPKCS1SHA256Digest,
            input: .message(Data(repeating: 0x01, count: 32))
        )
        XCTAssertThrowsError(try request.validate()) { error in
            XCTAssertEqual((error as? ZynSignError)?.cryptoFailure, .invalidInput)
        }
    }

    func testDigestInputOnAMessageOperationIsInvalid() {
        let digest = Digest(algorithm: .sha256, bytes: Data(repeating: 0x01, count: 32))!
        let request = SigningRequest(
            identityID: SigningIdentityIdentifier(),
            algorithm: .rsaPKCS1SHA256Message,
            input: .digest(digest)
        )
        // A 32-byte digest is never silently re-read as a 32-byte message.
        XCTAssertThrowsError(try request.validate()) { error in
            XCTAssertEqual((error as? ZynSignError)?.cryptoFailure, .invalidInput)
        }
    }

    func testDigestOfADifferentAlgorithmIsRejectedNotSubstituted() {
        let digest = Digest(algorithm: .sha384, bytes: Data(repeating: 0x01, count: 48))!
        let request = SigningRequest(
            identityID: SigningIdentityIdentifier(),
            algorithm: .ecdsaX962SHA256Digest,
            input: .digest(digest)
        )
        XCTAssertThrowsError(try request.validate()) { error in
            XCTAssertEqual((error as? ZynSignError)?.cryptoFailure, .invalidInput)
        }
    }

    // MARK: - The algorithm model keeps its parts distinct

    func testSigningAlgorithmNamesKeyFamilyDigestAndInputSemantics() {
        XCTAssertEqual(SigningAlgorithm.rsaPKCS1SHA256Message.publicKeyAlgorithm, .rsa)
        XCTAssertEqual(SigningAlgorithm.ecdsaX962SHA256Digest.publicKeyAlgorithm, .ec)
        for algorithm in SigningAlgorithm.allCases {
            XCTAssertEqual(algorithm.digestAlgorithm, .sha256)
        }
        XCTAssertEqual(SigningAlgorithm.rsaPKCS1SHA256Digest.digestLength, 32)
        XCTAssertNil(SigningAlgorithm.rsaPKCS1SHA256Message.digestLength)
    }

    // MARK: - Operation context

    func testOperationContextIsBounded() {
        XCTAssertNotNil(SigningOperationContext(label: "codeDirectory"))
        XCTAssertNotNil(SigningOperationContext(label: String(repeating: "a", count: 128)))
        XCTAssertNil(SigningOperationContext(label: ""))
        XCTAssertNil(SigningOperationContext(label: String(repeating: "a", count: 129)))
        XCTAssertNil(SigningOperationContext(label: "line\nbreak"))
    }
}
