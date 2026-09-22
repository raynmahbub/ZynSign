import XCTest
@testable import ZynSign

final class WorkflowStageTests: XCTestCase {

    func testStagesAppearInPipelineOrder() {
        XCTAssertEqual(
            WorkflowStage.allCases,
            [.inspection, .signing, .verification, .packaging, .installation]
        )
    }

    func testDisplayNamesAreDistinctAndNonEmpty() {
        let names = WorkflowStage.allCases.map(\.displayName)
        XCTAssertTrue(names.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testStageRawValuesAreStable() {
        XCTAssertEqual(WorkflowStage.inspection.rawValue, "inspection")
        XCTAssertEqual(WorkflowStage.signing.rawValue, "signing")
        XCTAssertEqual(WorkflowStage.verification.rawValue, "verification")
        XCTAssertEqual(WorkflowStage.packaging.rawValue, "packaging")
        XCTAssertEqual(WorkflowStage.installation.rawValue, "installation")
    }
}
