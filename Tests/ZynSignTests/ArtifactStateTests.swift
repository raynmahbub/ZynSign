import XCTest
@testable import ZynSign

final class ArtifactStateTests: XCTestCase {

    func testStateRawValuesAreStable() {
        XCTAssertEqual(ArtifactState.imported.rawValue, "imported")
        XCTAssertEqual(ArtifactState.inspected.rawValue, "inspected")
        XCTAssertEqual(ArtifactState.invalid.rawValue, "invalid")
    }

    func testStateSetIsMinimal() {
        XCTAssertEqual(ArtifactState.allCases.count, 3)
    }

    func testDisplayNamesAreDistinctAndNonEmpty() {
        let names = ArtifactState.allCases.map(\.displayName)
        XCTAssertTrue(names.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testOnlyRejectedArtifactsAreTerminal() {
        XCTAssertFalse(ArtifactState.imported.isTerminal)
        XCTAssertFalse(ArtifactState.inspected.isTerminal)
        XCTAssertTrue(ArtifactState.invalid.isTerminal)
    }

    func testImportedTransitionsToStructuralExaminationOutcomesOnly() {
        XCTAssertTrue(ArtifactState.imported.canTransition(to: .inspected))
        XCTAssertTrue(ArtifactState.imported.canTransition(to: .invalid))
        XCTAssertFalse(ArtifactState.imported.canTransition(to: .imported))
    }

    func testInspectedTransitionsToMetadataExaminationOutcomesOnly() {
        XCTAssertTrue(ArtifactState.inspected.canTransition(to: .inspected))
        XCTAssertTrue(ArtifactState.inspected.canTransition(to: .invalid))
        XCTAssertFalse(ArtifactState.inspected.canTransition(to: .imported))
    }

    func testRejectedArtifactsTransitionNowhere() {
        for state in ArtifactState.allCases {
            XCTAssertFalse(ArtifactState.invalid.canTransition(to: state))
        }
    }

    func testStateDerivationFollowsClassification() {
        XCTAssertEqual(ArtifactState.state(following: .valid), .inspected)
        XCTAssertEqual(ArtifactState.state(following: .invalid), .invalid)
        XCTAssertEqual(ArtifactState.state(following: .unsupported), .invalid)
        XCTAssertEqual(ArtifactState.state(following: .ambiguous), .invalid)
    }
}
