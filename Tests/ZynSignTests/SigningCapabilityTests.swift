import XCTest
@testable import ZynSign

final class SigningCapabilityTests: XCTestCase {
    func testEachAlgorithmMakesKeyFamilyAndInputSemanticsExplicit() throws {
        for algorithm in SigningAlgorithm.allCases {
            let input = Data(repeating: 0x23, count: algorithm.digestLength ?? 7)
            XCTAssertNoThrow(try algorithm.validate(data: input, keyAlgorithm: algorithm.publicKeyAlgorithm))
            let other: PublicKeyAlgorithm = algorithm.publicKeyAlgorithm == .rsa ? .ec : .rsa
            XCTAssertThrowsError(try algorithm.validate(data: input, keyAlgorithm: other)) { error in
                XCTAssertEqual((error as? ZynSignError)?.identityFailure, .unsupportedSigningAlgorithm)
            }
            XCTAssertThrowsError(try algorithm.validate(data: input, keyAlgorithm: .unknown("test")))
        }
    }

    func testDigestLengthIsExactAndMessagesAreNotTreatedAsDigests() throws {
        for count in [0, 1, 20, 31, 33, 48, 64] {
            let data = Data(repeating: 0, count: count)
            XCTAssertThrowsError(try SigningAlgorithm.rsaPKCS1SHA256Digest.validate(data: data, keyAlgorithm: .rsa))
            XCTAssertThrowsError(try SigningAlgorithm.ecdsaX962SHA256Digest.validate(data: data, keyAlgorithm: .ec))
            XCTAssertNoThrow(try SigningAlgorithm.rsaPKCS1SHA256Message.validate(data: data, keyAlgorithm: .rsa))
        }
    }

    func testIdentityFailureReasonsAreDistinctStructuredAndPayloadFree() {
        var messages = Set<String>()
        for reason in SigningIdentityFailure.allCases {
            let error = ZynSignError.identity(reason)
            XCTAssertEqual(error.identityFailure, reason)
            XCTAssertEqual(error.category, reason.category)
            XCTAssertEqual(error.diagnosticDetail, reason.rawValue)
            XCTAssertNil(error.underlyingError)
            XCTAssertFalse(error.userMessage.isEmpty)
            XCTAssertTrue(messages.insert(error.userMessage).inserted)
        }
    }
}
