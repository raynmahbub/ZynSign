import XCTest
@testable import ZynSign

final class ZynSignErrorTests: XCTestCase {

    private func makeUnderlyingCause() -> NSError {
        NSError(
            domain: "com.zynsign.synthetic.tests",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "synthetic underlying cause"]
        )
    }

    func testErrorDescriptionIsTheUserMessage() {
        let error = ZynSignError(category: .invalidInput, userMessage: "The input is not valid.")
        XCTAssertEqual(error.errorDescription, "The input is not valid.")
    }

    func testUserMessageExcludesUnderlyingCause() {
        let cause = makeUnderlyingCause()
        let error = ZynSignError(
            category: .storageFailure,
            userMessage: "The operation could not be completed.",
            underlyingError: cause
        )
        XCTAssertEqual(error.errorDescription, "The operation could not be completed.")
        let userText = error.errorDescription ?? ""
        XCTAssertFalse(userText.contains("synthetic underlying cause"))
    }

    func testPreservesUnderlyingCause() {
        let cause = makeUnderlyingCause()
        let error = ZynSignError(
            category: .storageFailure,
            userMessage: "The operation could not be completed.",
            underlyingError: cause
        )
        let preserved = error.underlyingError as? NSError
        XCTAssertNotNil(preserved)
        XCTAssertEqual(preserved?.domain, "com.zynsign.synthetic.tests")
        XCTAssertEqual(preserved?.code, 7)
    }

    func testShortDescriptionIsLogSafeAndExcludesCause() {
        let error = ZynSignError(
            category: .capabilityUnavailable,
            userMessage: "This capability is not available.",
            diagnosticDetail: "synthetic diagnostic detail",
            underlyingError: makeUnderlyingCause()
        )
        let text = error.description
        XCTAssertTrue(text.contains("capabilityUnavailable"))
        XCTAssertTrue(text.contains("This capability is not available."))
        XCTAssertFalse(text.contains("synthetic diagnostic detail"))
        XCTAssertFalse(text.contains("synthetic underlying cause"))
    }

    func testDebugDescriptionIncludesCategoryDetailAndCause() {
        let error = ZynSignError(
            category: .capabilityUnavailable,
            userMessage: "This capability is not available.",
            diagnosticDetail: "synthetic diagnostic detail",
            underlyingError: makeUnderlyingCause()
        )
        let text = error.debugDescription
        XCTAssertTrue(text.contains("capabilityUnavailable"))
        XCTAssertTrue(text.contains("synthetic diagnostic detail"))
        XCTAssertTrue(text.contains("synthetic underlying cause"))
    }

    func testEveryCategoryHasAStableRawValue() {
        XCTAssertEqual(DiagnosticCategory.allCases.count, 7)
        XCTAssertEqual(
            Set(DiagnosticCategory.allCases.map(\.rawValue)),
            [
                "invalidInput",
                "unsupportedInput",
                "ambiguousInput",
                "capabilityUnavailable",
                "cancelled",
                "storageFailure",
                "internalFailure",
            ]
        )
    }
}
