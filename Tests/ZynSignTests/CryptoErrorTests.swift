import XCTest
@testable import ZynSign

final class CryptoErrorTests: XCTestCase {

    func testEveryReasonIsStructuredWithACategoryAndASafeMessage() {
        var messages = Set<String>()
        for reason in CryptoFailure.allCases {
            let error = ZynSignError.crypto(reason)
            XCTAssertEqual(error.cryptoFailure, reason)
            XCTAssertEqual(error.category, reason.category)
            XCTAssertEqual(error.diagnosticDetail, reason.rawValue)
            XCTAssertNil(error.underlyingError)
            XCTAssertFalse(error.userMessage.isEmpty)
            // One safe message per reason; no two reasons share one.
            XCTAssertTrue(messages.insert(error.userMessage).inserted)
        }
    }

    func testReasonsCoverTheRequiredDistinctions() {
        // Unsupported algorithm, incompatible key, invalid input, signing
        // failure, verification failure, malformed signature, unavailable
        // capability, and platform limitation are all distinguishable.
        let reasons: Set<CryptoFailure> = [
            .unsupportedAlgorithm, .incompatibleKey, .invalidInput,
            .signingFailure, .verificationFailure, .malformedSignature,
            .capabilityUnavailable, .platformLimitation,
        ]
        for reason in reasons {
            let error = ZynSignError.crypto(reason)
            XCTAssertEqual(error.cryptoFailure, reason)
        }
        XCTAssertEqual(reasons.count, 8)
    }

    func testCategoriesAreHonest() {
        XCTAssertEqual(ZynSignError.crypto(.invalidInput).category, .invalidInput)
        XCTAssertEqual(ZynSignError.crypto(.malformedSignature).category, .invalidInput)
        XCTAssertEqual(ZynSignError.crypto(.certificateUnavailable).category, .invalidInput)
        XCTAssertEqual(ZynSignError.crypto(.unsupportedAlgorithm).category, .unsupportedInput)
        XCTAssertEqual(ZynSignError.crypto(.incompatibleKey).category, .unsupportedInput)
        XCTAssertEqual(ZynSignError.crypto(.capabilityUnavailable).category, .capabilityUnavailable)
        // A platform limitation is reported as a limitation, never as a
        // defect in the user's input.
        XCTAssertEqual(ZynSignError.crypto(.platformLimitation).category, .capabilityUnavailable)
        XCTAssertEqual(ZynSignError.crypto(.signingFailure).category, .internalFailure)
        XCTAssertEqual(ZynSignError.crypto(.verificationFailure).category, .internalFailure)
        XCTAssertEqual(ZynSignError.crypto(.unexpectedFailure).category, .internalFailure)
    }

    func testDiagnosticDetailIsAcceptedButNeverReachesTheUserMessage() {
        let detail = "operation rsaPKCS1SHA256Digest rejected at the key boundary"
        let error = ZynSignError.crypto(.unsupportedAlgorithm, diagnosticDetail: detail)
        XCTAssertEqual(error.diagnosticDetail, detail)
        XCTAssertFalse(error.userMessage.contains("rsaPKCS1SHA256Digest"))
        XCTAssertFalse(error.userMessage.contains("key boundary"))
        // The log-safe summary stays free of detail.
        XCTAssertFalse(error.description.contains(detail))
        // The debug rendering is where the detail belongs.
        XCTAssertTrue(error.debugDescription.contains(detail))
    }

    func testDebugDescriptionCarriesTheReason() {
        let error = ZynSignError.crypto(.incompatibleKey)
        XCTAssertTrue(error.debugDescription.contains("reason: incompatibleKey"))
        XCTAssertEqual(error.description, "zynsign.error(unsupportedInput): \(CryptoFailure.incompatibleKey.userMessage)")
    }

    func testSanitizationPreservesKnownReasonsAndDropsForeignText() {
        // A crypto reason passes through unchanged.
        let crypto = ZynSignError.crypto(.malformedSignature)
        let cryptoPassthrough = ZynSignError.sanitizedCryptoFailure(crypto)
        XCTAssertEqual(cryptoPassthrough.cryptoFailure, .malformedSignature)
        XCTAssertEqual(cryptoPassthrough.category, crypto.category)
        XCTAssertEqual(cryptoPassthrough.diagnosticDetail, crypto.diagnosticDetail)

        // An identity-boundary reason passes through unchanged when it
        // crosses the engine.
        let identity = ZynSignError.identity(.privateKeyUnavailable)
        let identityPassthrough = ZynSignError.sanitizedCryptoFailure(identity)
        XCTAssertEqual(identityPassthrough.identityFailure, .privateKeyUnavailable)
        XCTAssertNil(identityPassthrough.cryptoFailure)

        // A foreign error is reduced to a reason; its text is never kept.
        let foreign = NSError(
            domain: "private provider",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "key material and credentials live here"]
        )
        let sanitized = ZynSignError.sanitizedCryptoFailure(foreign)
        XCTAssertEqual(sanitized.cryptoFailure, .unexpectedFailure)
        XCTAssertNil(sanitized.underlyingError)
        XCTAssertFalse(sanitized.debugDescription.contains("key material"))
        XCTAssertFalse(sanitized.debugDescription.contains("private provider"))
    }
}
