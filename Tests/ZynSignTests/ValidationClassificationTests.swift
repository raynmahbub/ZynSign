import XCTest
@testable import ZynSign

final class ValidationClassificationTests: XCTestCase {

    func testOnlyValidClassificationPermitsLaterStages() {
        for classification in ValidationClassification.allCases {
            XCTAssertEqual(
                classification.permitsLaterStages,
                classification == .valid,
                "\(classification.displayName) must not proceed to later stages."
            )
        }
    }

    func testDisplayNamesAreDistinctAndNonEmpty() {
        let names = ValidationClassification.allCases.map(\.displayName)
        XCTAssertTrue(names.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(names).count, names.count)
    }
}
