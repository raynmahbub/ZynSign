import XCTest
@testable import ZynSign

final class LibraryErrorTests: XCTestCase {

    private func makeCause() -> NSError {
        NSError(
            domain: "com.zynsign.synthetic.tests",
            code: 31,
            userInfo: [NSLocalizedDescriptionKey: "synthetic library failure"]
        )
    }

    private func allFactories(cause: (any Error)? = nil) -> [ZynSignError] {
        let detail = cause == nil ? nil : "synthetic diagnostic detail"
        return [
            ZynSignError.libraryStorageFailure(diagnosticDetail: detail, underlyingError: cause),
            ZynSignError.libraryCatalogUnreadable(diagnosticDetail: detail, underlyingError: cause),
            ZynSignError.libraryCatalogUnsupported(diagnosticDetail: detail, underlyingError: cause),
            ZynSignError.libraryRecordNotFound(diagnosticDetail: detail, underlyingError: cause),
            ZynSignError.libraryRecordConflict(diagnosticDetail: detail, underlyingError: cause),
            ZynSignError.unrecordableArtifact(diagnosticDetail: detail, underlyingError: cause),
        ]
    }

    func testLibraryErrorsMapToHonestCategories() {
        XCTAssertEqual(ZynSignError.libraryStorageFailure().category, .storageFailure)
        XCTAssertEqual(ZynSignError.libraryCatalogUnreadable().category, .storageFailure)
        XCTAssertEqual(ZynSignError.libraryCatalogUnsupported().category, .capabilityUnavailable)
        XCTAssertEqual(ZynSignError.libraryRecordNotFound().category, .storageFailure)
        XCTAssertEqual(ZynSignError.libraryRecordConflict().category, .internalFailure)
        XCTAssertEqual(ZynSignError.unrecordableArtifact().category, .internalFailure)
    }

    func testLibraryErrorMessagesAreDistinctAndNonEmpty() {
        let messages = allFactories().map { $0.userMessage }
        XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(messages).count, messages.count)
    }

    func testLibraryErrorMessagesExcludeDetailAndCause() {
        let cause = makeCause()
        for error in allFactories(cause: cause) {
            XCTAssertFalse(error.userMessage.contains("synthetic"))
            XCTAssertNil(error.errorDescription?.range(of: "synthetic"))
            XCTAssertEqual(error.errorDescription, error.userMessage)
        }
    }

    func testLibraryErrorsPreserveDetailAndCause() {
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

    func testLibraryErrorMessagesMakeNoTrustOrSigningClaims() {
        for error in allFactories() {
            let message = error.userMessage.lowercased()
            XCTAssertFalse(message.contains("signed"))
            XCTAssertFalse(message.contains("trust"))
            XCTAssertFalse(message.contains("certificate"))
            XCTAssertFalse(message.contains("install"))
        }
    }
}
