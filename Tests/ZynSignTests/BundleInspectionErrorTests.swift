import XCTest
@testable import ZynSign

final class BundleInspectionErrorTests: XCTestCase {

    private func makeCause() -> NSError {
        NSError(
            domain: "com.zynsign.synthetic.tests",
            code: 41,
            userInfo: [NSLocalizedDescriptionKey: "synthetic bundle inspection failure"]
        )
    }

    private func allFactories(cause: (any Error)? = nil) -> [ZynSignError] {
        let detail = cause == nil ? nil : "synthetic diagnostic detail"
        return [
            ZynSignError.bundleArtifactMissing(diagnosticDetail: detail, underlyingError: cause),
            ZynSignError.bundleArtifactInconsistent(diagnosticDetail: detail, underlyingError: cause),
            ZynSignError.bundleInspectionFailure(diagnosticDetail: detail, underlyingError: cause),
        ]
    }

    func testBundleInspectionErrorsMapToHonestCategories() {
        XCTAssertEqual(ZynSignError.bundleArtifactMissing().category, .storageFailure)
        XCTAssertEqual(ZynSignError.bundleArtifactInconsistent().category, .storageFailure)
        XCTAssertEqual(ZynSignError.bundleInspectionFailure().category, .internalFailure)
    }

    func testBundleInspectionErrorMessagesAreDistinctAndNonEmpty() {
        let messages = allFactories().map { $0.userMessage }
        XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(messages).count, messages.count)
    }

    func testBundleInspectionErrorMessagesExcludeDetailAndCause() {
        let cause = makeCause()
        for error in allFactories(cause: cause) {
            XCTAssertFalse(error.userMessage.contains("synthetic"))
            XCTAssertNil(error.errorDescription?.range(of: "synthetic"))
            XCTAssertEqual(error.errorDescription, error.userMessage)
        }
    }

    func testBundleInspectionErrorsPreserveDetailAndCause() {
        let cause = makeCause()
        for error in allFactories(cause: cause) {
            XCTAssertEqual(error.diagnosticDetail, "synthetic diagnostic detail")
            XCTAssertNotNil(error.underlyingError)
        }
        for error in allFactories() {
            XCTAssertNil(error.diagnosticDetail)
            XCTAssertNil(error.underlyingError)
        }
    }

    func testBundleInspectionErrorMessagesMakeNoTrustOrSigningClaims() {
        for error in allFactories() {
            let message = error.userMessage.lowercased()
            XCTAssertFalse(message.contains("signed"))
            XCTAssertFalse(message.contains("trust"))
            XCTAssertFalse(message.contains("certificate"))
            XCTAssertFalse(message.contains("install"))
        }
    }

    func testBundleInspectionErrorMessagesNameNoLocations() {
        for error in allFactories() {
            XCTAssertFalse(error.userMessage.contains("/"))
            XCTAssertFalse(error.userMessage.contains(".ipa"))
        }
    }
}
