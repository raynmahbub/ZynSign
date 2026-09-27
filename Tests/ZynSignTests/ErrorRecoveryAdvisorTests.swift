import XCTest
@testable import ZynSign

/// The error-recovery audit, in the only form that can be enforced: every
/// failure must answer what happened, what was verified, and what to do next.
final class ErrorRecoveryAdvisorTests: XCTestCase {

    // MARK: - The three answers

    func testEveryCategoryProducesAllThreeAnswers() {
        for category in DiagnosticCategory.allCases {
            let advice = ErrorRecoveryAdvisor.categoryAdvice(
                category,
                message: "Something went wrong."
            )
            XCTAssertFalse(advice.whatHappened.isEmpty, "\(category) says nothing about what happened")
            XCTAssertFalse(advice.whatWasVerified.isEmpty, "\(category) says nothing about what was verified")
            XCTAssertFalse(advice.nextSteps.isEmpty, "\(category) offers nothing to do next")
        }
    }

    func testEveryIdentityFailureProducesAllThreeAnswers() {
        for reason in SigningIdentityFailure.allCases {
            let advice = ErrorRecoveryAdvisor.advice(for: ZynSignError.identity(reason))
            XCTAssertFalse(advice.whatHappened.isEmpty, "\(reason.rawValue)")
            XCTAssertFalse(advice.whatWasVerified.isEmpty, "\(reason.rawValue)")
            XCTAssertFalse(advice.nextSteps.isEmpty, "\(reason.rawValue)")
        }
    }

    func testEveryProfileFailureProducesAllThreeAnswers() {
        for reason in ProvisioningProfileFailure.allCases {
            let advice = ErrorRecoveryAdvisor.advice(for: ZynSignError.provisioningProfile(reason))
            XCTAssertFalse(advice.whatHappened.isEmpty, "\(reason.rawValue)")
            XCTAssertFalse(advice.whatWasVerified.isEmpty, "\(reason.rawValue)")
            XCTAssertFalse(advice.nextSteps.isEmpty, "\(reason.rawValue)")
        }
    }

    func testEveryCMSFailureProducesAllThreeAnswers() {
        for reason in CMSFailure.allCases {
            let advice = ErrorRecoveryAdvisor.advice(for: ZynSignError.cms(reason))
            XCTAssertFalse(advice.whatHappened.isEmpty, "\(reason.rawValue)")
            XCTAssertFalse(advice.whatWasVerified.isEmpty, "\(reason.rawValue)")
            XCTAssertFalse(advice.nextSteps.isEmpty, "\(reason.rawValue)")
        }
    }

    func testEveryCryptoFailureProducesAllThreeAnswers() {
        for reason in CryptoFailure.allCases {
            let advice = ErrorRecoveryAdvisor.advice(for: ZynSignError.crypto(reason))
            XCTAssertFalse(advice.whatHappened.isEmpty, "\(reason.rawValue)")
            XCTAssertFalse(advice.whatWasVerified.isEmpty, "\(reason.rawValue)")
            XCTAssertFalse(advice.nextSteps.isEmpty, "\(reason.rawValue)")
        }
    }

    // MARK: - Retryability

    func testAFailureThatWillRepeatOnTheSameInputIsNotRetryable() {
        let advice = ErrorRecoveryAdvisor.advice(
            for: ZynSignError.identity(.certificateKeyMismatch)
        )
        XCTAssertFalse(advice.canRetry, "A key that does not match will not match on a second attempt")
    }

    func testAStorageFailureIsRetryable() {
        let advice = ErrorRecoveryAdvisor.advice(
            for: ZynSignError(
                category: .storageFailure,
                userMessage: "ZynSign could not write to its workspace.",
                diagnosticDetail: nil
            )
        )
        XCTAssertTrue(advice.canRetry)
    }

    func testACancellationIsRetryableAndChangesNothing() {
        let advice = ErrorRecoveryAdvisor.advice(for: CancellationError())
        XCTAssertTrue(advice.canRetry)
        XCTAssertTrue(advice.whatWasVerified.contains("Nothing was changed"))
    }

    func testAnUntypedTransportFailureStillProducesAnAnswer() {
        let advice = ErrorRecoveryAdvisor.advice(
            for: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorNotConnectedToInternet,
                userInfo: nil
            )
        )
        XCTAssertTrue(advice.whatHappened.contains("offline"))
        XCTAssertTrue(advice.canRetry)
        XCTAssertFalse(advice.nextSteps.isEmpty)
    }

    func testAnUnrecognisedFailureStillProducesAnAnswer() {
        struct Unrecognised: Error {}
        let advice = ErrorRecoveryAdvisor.advice(for: Unrecognised())
        XCTAssertFalse(advice.whatHappened.isEmpty)
        XCTAssertFalse(advice.whatWasVerified.isEmpty)
        XCTAssertFalse(advice.nextSteps.isEmpty)
    }

    // MARK: - Honesty

    func testTheAdviceNeverRestatesTheDiagnosticDetail() {
        // The user message and the advice are for the user; the diagnostic
        // detail is for a report the user chooses to share.
        let error = ZynSignError(
            category: .internalFailure,
            userMessage: "ZynSign could not finish that.",
            diagnosticDetail: "redacted-detail-that-must-not-leak"
        )
        let advice = ErrorRecoveryAdvisor.advice(for: error)
        let rendered = advice.whatHappened + advice.whatWasVerified + advice.nextSteps.joined()
        XCTAssertFalse(rendered.contains("redacted-detail-that-must-not-leak"))
    }

    func testANetworkFailureNamesTheFailureNotTheHost() {
        // A platform error's own text can carry a host name; the advice names
        // the kind of failure instead.
        let advice = ErrorRecoveryAdvisor.advice(
            for: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCannotFindHost,
                userInfo: [NSLocalizedDescriptionKey: "A server with the hostname example.invalid could not be found."]
            )
        )
        XCTAssertFalse(advice.whatHappened.contains("example.invalid"))
        XCTAssertTrue(advice.whatHappened.contains("host not found"))
    }
}
