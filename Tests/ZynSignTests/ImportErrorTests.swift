import XCTest
@testable import ZynSign

final class ImportErrorTests: XCTestCase {

    private func makeCause() -> NSError {
        NSError(
            domain: "com.zynsign.synthetic.tests",
            code: 21,
            userInfo: [NSLocalizedDescriptionKey: "synthetic intake failure"]
        )
    }

    private func allFactories(cause: (any Error)? = nil) -> [ZynSignError] {
        let detail = cause == nil ? nil : "synthetic diagnostic detail"
        return [
            ZynSignError.importCancelled(diagnosticDetail: detail, underlyingError: cause),
            ZynSignError.unsupportedImportFile(diagnosticDetail: detail, underlyingError: cause),
            ZynSignError.selectedFileUnavailable(diagnosticDetail: detail, underlyingError: cause),
            ZynSignError.selectedFileAccessDenied(diagnosticDetail: detail, underlyingError: cause),
            ZynSignError.importTemporaryStorageFailure(diagnosticDetail: detail, underlyingError: cause),
            ZynSignError.importCopyFailure(diagnosticDetail: detail, underlyingError: cause),
            ZynSignError.importUnexpectedFailure(diagnosticDetail: detail, underlyingError: cause),
        ]
    }

    func testImportErrorsMapToHonestCategories() {
        XCTAssertEqual(ZynSignError.importCancelled().category, .cancelled)
        XCTAssertEqual(ZynSignError.unsupportedImportFile().category, .unsupportedInput)
        XCTAssertEqual(ZynSignError.selectedFileUnavailable().category, .storageFailure)
        XCTAssertEqual(ZynSignError.selectedFileAccessDenied().category, .storageFailure)
        XCTAssertEqual(ZynSignError.importTemporaryStorageFailure().category, .storageFailure)
        XCTAssertEqual(ZynSignError.importCopyFailure().category, .storageFailure)
        XCTAssertEqual(ZynSignError.importUnexpectedFailure().category, .internalFailure)
    }

    func testImportErrorMessagesAreDistinctAndNonEmpty() {
        let messages = allFactories().map { $0.userMessage }
        XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(messages).count, messages.count)
    }

    func testImportErrorMessagesExcludeDetailAndCause() {
        let cause = makeCause()
        for error in allFactories(cause: cause) {
            XCTAssertFalse(error.userMessage.contains("synthetic"))
            XCTAssertFalse(error.userMessage.contains("intake"))
            XCTAssertNil(error.errorDescription?.range(of: "synthetic"))
            XCTAssertEqual(error.errorDescription, error.userMessage)
        }
    }

    func testImportErrorsPreserveDetailAndCause() {
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
}
