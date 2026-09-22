import XCTest
@testable import ZynSign

final class ValidationResultTests: XCTestCase {

    private func errorFinding(
        code: ValidationIssueCode = .missingApplicationBundle,
        location: ArchivePath? = nil
    ) -> ValidationFinding {
        ValidationFinding(
            severity: .error,
            code: code,
            detail: "synthetic error detail",
            location: location
        )
    }

    private func warningFinding(code: ValidationIssueCode = .unsupportedArchiveFeature) -> ValidationFinding {
        ValidationFinding(
            severity: .warning,
            code: code,
            detail: "synthetic warning detail"
        )
    }

    func testValidResultIsCleanAndConsistent() {
        let result = ValidationResult.valid()
        XCTAssertEqual(result.classification, .valid)
        XCTAssertTrue(result.findings.isEmpty)
        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertTrue(result.isConsistent)
    }

    func testValidWithWarningsKeepsObservationsWithoutRejecting() {
        let result = ValidationResult.validWithWarnings(findings: [warningFinding()])
        XCTAssertEqual(result.classification, .valid)
        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.isConsistent)
    }

    func testRejectingFactoriesRecordClassificationAndFindings() {
        let findings = [errorFinding()]
        let cases: [(ValidationResult, ValidationClassification)] = [
            (ValidationResult.invalid(findings: findings), .invalid),
            (ValidationResult.unsupported(findings: findings), .unsupported),
            (ValidationResult.ambiguous(findings: findings), .ambiguous),
        ]
        for (result, classification) in cases {
            XCTAssertEqual(result.classification, classification)
            XCTAssertFalse(result.isValid)
            XCTAssertEqual(result.findings.count, 1)
            XCTAssertEqual(result.errors.count, 1)
            XCTAssertTrue(result.isConsistent)
        }
    }

    func testErrorsAndWarningsFilterBySeverityInOrder() {
        let first = errorFinding(code: .missingExecutable)
        let second = warningFinding()
        let result = ValidationResult(classification: .invalid, findings: [first, second])
        XCTAssertEqual(result.errors, [first])
        XCTAssertEqual(result.warnings, [second])
    }

    func testConsistencyDetectsValidResultWithErrors() {
        let result = ValidationResult(classification: .valid, findings: [errorFinding()])
        XCTAssertFalse(result.isConsistent)
    }

    func testConsistencyDetectsRejectingResultWithoutErrors() {
        for classification in [ValidationClassification.invalid, .unsupported, .ambiguous] {
            XCTAssertFalse(ValidationResult(classification: classification, findings: []).isConsistent)
            XCTAssertFalse(
                ValidationResult(classification: classification, findings: [warningFinding()]).isConsistent
            )
        }
    }

    func testSeverityRejectionRule() {
        XCTAssertTrue(ValidationSeverity.error.rejectsArtifact)
        XCTAssertFalse(ValidationSeverity.warning.rejectsArtifact)
        XCTAssertTrue(errorFinding().isRejecting)
        XCTAssertFalse(warningFinding().isRejecting)
    }

    func testSeverityRawValuesAreStable() {
        XCTAssertEqual(ValidationSeverity.error.rawValue, "error")
        XCTAssertEqual(ValidationSeverity.warning.rawValue, "warning")
    }

    func testFindingDefaultsToWholeArtifactLocation() throws {
        XCTAssertNil(errorFinding().location)
        let entry = try XCTUnwrap(ArchivePath(rawValue: "Payload/Example.app/Info.plist"))
        XCTAssertEqual(errorFinding(location: entry).location, entry)
    }

    func testFindingCategoryFollowsIssueCode() {
        XCTAssertEqual(errorFinding(code: .missingApplicationBundle).category, .invalidInput)
        XCTAssertEqual(errorFinding(code: .multipleApplicationBundles).category, .ambiguousInput)
        XCTAssertEqual(warningFinding(code: .unsupportedArchiveFeature).category, .unsupportedInput)
    }

    func testIssueCodeCategoriesKeepHonestDistinctions() {
        for code in ValidationIssueCode.allCases {
            switch code {
            case .multipleApplicationBundles:
                XCTAssertEqual(code.category, .ambiguousInput)
            case .unsupportedArchiveFeature, .resourceLimitExceeded, .unsupportedMetadataFormat:
                XCTAssertEqual(code.category, .unsupportedInput)
            default:
                XCTAssertEqual(code.category, .invalidInput, "\(code.rawValue) must report invalid input.")
            }
        }
    }

    func testIssueCodesAreStable() {
        XCTAssertEqual(ValidationIssueCode.allCases.count, 15)
        XCTAssertEqual(
            Set(ValidationIssueCode.allCases.map(\.rawValue)),
            [
                "unreadableArchive",
                "unsafePath",
                "conflictingPaths",
                "missingPayloadDirectory",
                "missingApplicationBundle",
                "multipleApplicationBundles",
                "missingInfoPlist",
                "unreadableInfoPlist",
                "malformedMetadata",
                "missingRequiredMetadata",
                "unsupportedMetadataFormat",
                "inconsistentMetadata",
                "missingExecutable",
                "unsupportedArchiveFeature",
                "resourceLimitExceeded",
            ]
        )
    }

    func testFindingsWithSameValuesAreEqual() {
        XCTAssertEqual(errorFinding(), errorFinding())
        XCTAssertNotEqual(errorFinding(), warningFinding(code: .missingApplicationBundle))
    }
}
