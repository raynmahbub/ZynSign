import XCTest
@testable import ZynSign

final class ArtifactErrorTests: XCTestCase {

    private func makeCause() -> NSError {
        NSError(
            domain: "com.zynsign.synthetic.tests",
            code: 11,
            userInfo: [NSLocalizedDescriptionKey: "synthetic parser failure"]
        )
    }

    private func allFactories(cause: (any Error)? = nil) -> [ZynSignError] {
        let detail = cause == nil ? nil : "synthetic diagnostic detail"
        return [
            ZynSignError.invalidArtifact(diagnosticDetail: detail, underlyingError: cause),
            ZynSignError.unsupportedArtifact(diagnosticDetail: detail, underlyingError: cause),
            ZynSignError.ambiguousArtifact(diagnosticDetail: detail, underlyingError: cause),
            ZynSignError.missingApplicationBundle(diagnosticDetail: detail, underlyingError: cause),
            ZynSignError.malformedArtifactMetadata(diagnosticDetail: detail, underlyingError: cause),
            ZynSignError.inconsistentArtifactMetadata(diagnosticDetail: detail, underlyingError: cause),
            ZynSignError.artifactStorageFailure(diagnosticDetail: detail, underlyingError: cause),
        ]
    }

    func testArtifactErrorsMapToHonestCategories() {
        XCTAssertEqual(ZynSignError.invalidArtifact().category, .invalidInput)
        XCTAssertEqual(ZynSignError.unsupportedArtifact().category, .unsupportedInput)
        XCTAssertEqual(ZynSignError.ambiguousArtifact().category, .ambiguousInput)
        XCTAssertEqual(ZynSignError.missingApplicationBundle().category, .invalidInput)
        XCTAssertEqual(ZynSignError.malformedArtifactMetadata().category, .invalidInput)
        XCTAssertEqual(ZynSignError.inconsistentArtifactMetadata().category, .invalidInput)
        XCTAssertEqual(ZynSignError.artifactStorageFailure().category, .storageFailure)
    }

    func testArtifactErrorMessagesAreDistinctAndNonEmpty() {
        let messages = allFactories().map { $0.userMessage }
        XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(messages).count, messages.count)
    }

    func testArtifactErrorMessagesExcludeDetailAndCause() {
        for error in allFactories(cause: makeCause()) {
            XCTAssertFalse(error.userMessage.contains("synthetic parser failure"))
            XCTAssertFalse(error.userMessage.contains("synthetic diagnostic detail"))
        }
    }

    func testArtifactErrorsPreserveDetailAndCause() {
        let error = ZynSignError.invalidArtifact(
            diagnosticDetail: "synthetic diagnostic detail",
            underlyingError: makeCause()
        )
        XCTAssertEqual(error.diagnosticDetail, "synthetic diagnostic detail")
        let preserved = error.underlyingError as? NSError
        XCTAssertEqual(preserved?.domain, "com.zynsign.synthetic.tests")
        XCTAssertEqual(preserved?.code, 11)
    }
}
